import AVFoundation
import CryptoKit
import Foundation
import Testing
import UniformTypeIdentifiers

@testable import TinyCloudMusic

private enum LoaderTestError: Error {
    case invalidFixture
    case injected
    case timeout(String)
}

private final class LoaderStatusProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var rawValue = AVPlayerItem.Status.unknown.rawValue

    func record(_ value: Int) { lock.withLock { rawValue = value } }
    var value: Int { lock.withLock { rawValue } }
}

private final class LoaderCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: Bool?

    func finish(_ value: Bool = true) {
        lock.withLock {
            if storedValue == nil { storedValue = value }
        }
    }

    var value: Bool? { lock.withLock { storedValue } }
}

private actor LoaderCounter {
    private(set) var value = 0

    func increment() { value += 1 }
}

private actor LoaderResponseGate {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }

    private var entered = false
    private var released = false
    private var waiters: [Waiter] = []
    private(set) var cancellations = 0

    func wait() async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                entered = true
                if released {
                    continuation.resume()
                } else if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiters.append(Waiter(id: id, continuation: continuation))
                }
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    func hasEntered() -> Bool { entered }

    func release() {
        released = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.continuation.resume() }
    }

    private func cancel(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        cancellations += 1
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }
}

private struct LoaderDownloadSnapshot: Sendable {
    let ranges: [Range<Int>]
    let responseBytes: Int
    let cancellations: Int
}

private actor LoaderDownloadFixture {
    private let root: URL
    private let audio: Data
    private let mimeType: String
    private let etag: String?
    private let gate: LoaderResponseGate?
    private var ranges: [Range<Int>] = []
    private var responseBytes = 0
    private var cancellations = 0

    init(
        root: URL,
        audio: Data,
        mimeType: String = "audio/wav",
        etag: String? = nil,
        gate: LoaderResponseGate? = nil
    ) {
        self.root = root
        self.audio = audio
        self.mimeType = mimeType
        self.etag = etag
        self.gate = gate
    }

    func download(_ request: URLRequest) async throws -> (URL, URLResponse) {
        let requested = try Self.requestedRange(request, length: audio.count)
        ranges.append(requested)
        do {
            try await gate?.wait()
            try Task.checkCancellation()
        } catch {
            cancellations += 1
            throw error
        }

        let body = audio.subdata(in: requested)
        responseBytes += body.count
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let temporaryURL = root.appending(path: UUID().uuidString)
        try body.write(to: temporaryURL)
        var headers = [
            "Content-Length": "\(body.count)",
            "Content-Range": "bytes \(requested.lowerBound)-\(requested.upperBound - 1)/\(audio.count)",
            "Content-Type": mimeType,
        ]
        if let etag { headers["ETag"] = etag }
        guard let url = request.url,
              let response = HTTPURLResponse(
                  url: url,
                  statusCode: 206,
                  httpVersion: nil,
                  headerFields: headers
              )
        else { throw LoaderTestError.invalidFixture }
        return (temporaryURL, response)
    }

    func snapshot() -> LoaderDownloadSnapshot {
        LoaderDownloadSnapshot(
            ranges: ranges,
            responseBytes: responseBytes,
            cancellations: cancellations
        )
    }

    private static func requestedRange(_ request: URLRequest, length: Int) throws -> Range<Int> {
        guard let value = request.value(forHTTPHeaderField: "Range"),
              value.hasPrefix("bytes="),
              !value.contains(",")
        else { throw LoaderTestError.invalidFixture }
        let bounds = value.dropFirst("bytes=".count).split(
            separator: "-",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        guard bounds.count == 2,
              let lower = Int(bounds[0]),
              let requestedUpper = Int(bounds[1]),
              lower >= 0,
              lower < length,
              requestedUpper >= lower
        else { throw LoaderTestError.invalidFixture }
        return lower..<(min(requestedUpper, length - 1) + 1)
    }
}

private let loaderKey = TrackRangeCacheKey(songID: 7_701_234_567_890_123, quality: "standard")
private let loaderSourceURL = URL(string: "https://m1.music.126.net/origin-marker.wav")!
private let loaderNetworkBlockSize = 512 * 1_024

private func loaderRangeFiles(in root: URL) -> [URL] {
    let values = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?
        .allObjects as? [URL] ?? []
    return values.filter {
        $0.pathExtension == "range"
            && (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
    }
}

private func loaderWAV() -> Data {
    let sampleRate: UInt32 = 96_000
    let channels: UInt16 = 2
    let seconds: UInt32 = 2
    let bytesPerSample: UInt16 = 2
    let dataSize = sampleRate * seconds * UInt32(channels) * UInt32(bytesPerSample)
    var data = Data("RIFF".utf8)
    appendLoaderLittleEndian(36 + dataSize, to: &data)
    data.append(Data("WAVEfmt ".utf8))
    appendLoaderLittleEndian(UInt32(16), to: &data)
    appendLoaderLittleEndian(UInt16(1), to: &data)
    appendLoaderLittleEndian(channels, to: &data)
    appendLoaderLittleEndian(sampleRate, to: &data)
    appendLoaderLittleEndian(sampleRate * UInt32(channels) * UInt32(bytesPerSample), to: &data)
    appendLoaderLittleEndian(channels * bytesPerSample, to: &data)
    appendLoaderLittleEndian(bytesPerSample * 8, to: &data)
    data.append(Data("data".utf8))
    appendLoaderLittleEndian(dataSize, to: &data)
    data.append(Data(repeating: 0, count: Int(dataSize)))
    return data
}

private func appendLoaderLittleEndian<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
    var value = value.littleEndian
    withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
}

private func loaderMD5(_ data: Data) -> String {
    Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func loaderSource(_ data: Data, representation: Bool = true) -> PlaybackSource {
    PlaybackSource(
        url: loaderSourceURL,
        availability: .playable(level: loaderKey.quality),
        format: "wav",
        representation: representation
            ? PlaybackRepresentation(contentLength: Int64(data.count), contentMD5: loaderMD5(data))
            : nil
    )
}

@MainActor
private func waitForLoaderCondition(
    timeout: Duration = .seconds(8),
    stage: String = "condition",
    _ predicate: @escaping @MainActor () async -> Bool
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if await predicate() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw LoaderTestError.timeout(stage)
}

@MainActor
private func waitForLoaderStatus(_ item: AVPlayerItem) async throws -> AVPlayerItem.Status {
    let probe = LoaderStatusProbe()
    let observation = item.observe(\.status, options: [.initial, .new]) { item, _ in
        probe.record(item.status.rawValue)
    }
    defer { observation.invalidate() }
    try await waitForLoaderCondition { probe.value != AVPlayerItem.Status.unknown.rawValue }
    return item.status
}

private func expectLoaderRejected(_ operation: () throws -> String) {
    do {
        _ = try operation()
        Issue.record("Expected rejected content type")
    } catch let error as TrackRangeCacheError {
        #expect(error == .rejectedResponse)
    } catch {
        Issue.record("Unexpected content type error")
    }
}

@Suite("AudioRangeResourceLoaderTests", .serialized)
@MainActor
struct AudioRangeResourceLoaderTests {
    @Test("Content type resolver preserves allowed identifiers and conformance direction")
    func contentTypeResolver() throws {
        let flac = try #require(UTType(filenameExtension: "flac"))
        let mpeg = try #require(UTType(mimeType: "audio/mpeg"))
        let xml = try #require(UTType(filenameExtension: "xml"))
        let svg = try #require(UTType(filenameExtension: "svg"))
        let xmlMIME = try #require(xml.preferredMIMEType)

        #expect(try resolvedAudioContentTypeIdentifier(
            mimeType: nil,
            format: "flac",
            allowedContentTypes: []
        ) == flac.identifier)
        #expect(try resolvedAudioContentTypeIdentifier(
            mimeType: "audio/mpeg",
            format: "flac",
            allowedContentTypes: [mpeg.identifier]
        ) == mpeg.identifier)
        #expect(try resolvedAudioContentTypeIdentifier(
            mimeType: nil,
            format: "flac",
            allowedContentTypes: [UTType.data.identifier, UTType.audio.identifier]
        ) == UTType.data.identifier)

        #expect(svg.conforms(to: xml))
        #expect(!xml.conforms(to: svg))
        #expect(try resolvedAudioContentTypeIdentifier(
            mimeType: xmlMIME,
            format: "xml",
            allowedContentTypes: []
        ) == xml.identifier)
        expectLoaderRejected {
            try resolvedAudioContentTypeIdentifier(
                mimeType: xmlMIME,
                format: "xml",
                allowedContentTypes: [svg.identifier]
            )
        }
        expectLoaderRejected {
            try resolvedAudioContentTypeIdentifier(
                mimeType: "audio/mpeg",
                format: "mp3",
                allowedContentTypes: [UTType.pdf.identifier]
            )
        }
        expectLoaderRejected {
            try resolvedAudioContentTypeIdentifier(
                mimeType: "audio/mpeg",
                format: "mp3",
                allowedContentTypes: ["not a uti"]
            )
        }
        expectLoaderRejected {
            try resolvedAudioContentTypeIdentifier(
                mimeType: nil,
                format: "not-a-format",
                allowedContentTypes: []
            )
        }

        #expect(try resolvedAudioContentTypeIdentifier(
            mimeType: "application/octet-stream",
            format: "flac",
            allowedContentTypes: [flac.identifier]
        ) == flac.identifier)
        #expect(try resolvedAudioContentTypeIdentifier(
            mimeType: UTType.data.identifier,
            format: "flac",
            allowedContentTypes: [flac.identifier]
        ) == flac.identifier)
    }

    @Test("Custom item stays alive, plays WAV to EOF, and closes its session")
    func playbackAndOwnership() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let audio = loaderWAV()
        let source = loaderSource(audio)
        let trackCache = TrackCache(directory: root.appending(path: "cache"))
        let fixture = LoaderDownloadFixture(
            root: root.appending(path: "responses"),
            audio: audio
        )
        let rangeCache = TrackRangeCache(trackCache: trackCache) {
            try await fixture.download($0)
        }
        let player = AVPlayer()
        player.automaticallyWaitsToMinimizeStalling = false
        do {
            let scopedItem = RangeCachingPlayerItem(
                key: loaderKey,
                format: "WAV",
                initialSource: source,
                sourceProvider: { source },
                rangeCache: rangeCache,
                preferPreciseTiming: false
            )
            #expect(scopedItem.key == loaderKey)
            #expect(scopedItem.rangeCache === rangeCache)
            let asset = try #require(scopedItem.asset as? AVURLAsset)
            #expect(asset.url.scheme == "tcm-audio-cache")
            #expect(asset.url.host == "resource")
            #expect(asset.url.pathExtension == "wav")
            #expect(UUID(uuidString: asset.url.deletingPathExtension().lastPathComponent) != nil)
            #expect(!asset.url.absoluteString.contains(String(loaderKey.songID)))
            #expect(!asset.url.absoluteString.contains(loaderKey.quality))
            #expect(!asset.url.absoluteString.contains("origin-marker"))
            player.replaceCurrentItem(with: scopedItem)
        }

        weak let weakItem = player.currentItem
        var installedURL: URL?
        do {
            let item = try #require(player.currentItem as? RangeCachingPlayerItem)
            #expect(try await waitForLoaderStatus(item) == .readyToPlay)
            let duration = item.duration.seconds
            #expect(duration.isFinite)
            #expect(abs(duration - 2) <= 0.05)

            let seek = LoaderCompletion()
            player.seek(
                to: CMTime(seconds: max(0, duration - 0.15), preferredTimescale: 96_000),
                toleranceBefore: .zero,
                toleranceAfter: .zero
            ) { seek.finish($0) }
            try await waitForLoaderCondition { seek.value != nil }
            #expect(seek.value == true)

            let ended = LoaderCompletion()
            let endObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: item,
                queue: .main
            ) { _ in ended.finish() }
            defer {
                player.pause()
                NotificationCenter.default.removeObserver(endObserver)
            }
            player.play()
            try await waitForLoaderCondition(timeout: .seconds(5)) {
                ended.value == true || item.status == .failed
            }
            #expect(ended.value == true)

            try await waitForLoaderCondition {
                await trackCache.readyFile(
                    for: loaderKey.songID,
                    quality: loaderKey.quality
                ) != nil
            }
            installedURL = await trackCache.readyFile(
                for: loaderKey.songID,
                quality: loaderKey.quality
            )
            let cached = try #require(installedURL)
            await trackCache.invalidateCachedFile(cached)
            #expect(FileManager.default.fileExists(atPath: cached.path))
        }

        let snapshot = await fixture.snapshot()
        #expect(!snapshot.ranges.isEmpty)
        #expect(snapshot.ranges.allSatisfy { $0.count <= loaderNetworkBlockSize })
        #expect(snapshot.ranges.contains { $0.upperBound == audio.count })
        #expect(snapshot.responseBytes <= audio.count + loaderNetworkBlockSize)

        player.replaceCurrentItem(with: nil)
        let cached = try #require(installedURL)
        try await waitForLoaderCondition {
            weakItem == nil && !FileManager.default.fileExists(atPath: cached.path)
        }
        try await rangeCache.clear()
    }

    @Test("Concurrent asset requests share one session and one range flight")
    func sharedSessionAndRangeFlight() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let audio = loaderWAV()
        let source = loaderSource(audio)
        let gate = LoaderResponseGate()
        let sourceCalls = LoaderCounter()
        let fixture = LoaderDownloadFixture(
            root: root.appending(path: "responses"),
            audio: audio,
            etag: #""loader-strong""#,
            gate: gate
        )
        let trackCache = TrackCache(directory: root.appending(path: "cache"))
        let rangeCache = TrackRangeCache(trackCache: trackCache) {
            try await fixture.download($0)
        }
        do {
            let item = RangeCachingPlayerItem(
                key: loaderKey,
                format: "wav",
                initialSource: nil,
                sourceProvider: {
                    await sourceCalls.increment()
                    return source
                },
                rangeCache: rangeCache,
                preferPreciseTiming: false
            )
            let player = AVPlayer(playerItem: item)
            player.automaticallyWaitsToMinimizeStalling = false
            let asset = item.asset
            let durationTask = Task { @MainActor in try await asset.load(.duration) }
            let playableTask = Task { @MainActor in try await asset.load(.isPlayable) }

            try await waitForLoaderCondition { await gate.hasEntered() }
            #expect(await sourceCalls.value == 1)
            let blockedSnapshot = await fixture.snapshot()
            #expect(blockedSnapshot.ranges.count == 1)
            await gate.release()
            _ = try await durationTask.value
            #expect(try await playableTask.value)
            #expect(try await waitForLoaderStatus(item) == .readyToPlay)
            player.replaceCurrentItem(with: nil)
        }
        let snapshot = await fixture.snapshot()
        #expect(await sourceCalls.value == 1)
        #expect(snapshot.ranges.allSatisfy { $0.count <= loaderNetworkBlockSize })
        try await rangeCache.clear()
    }

    @Test("Explicit terminal cancellation stops a delayed range request")
    func replacementCancellation() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cacheRoot = root.appending(path: "cache")
        let audio = loaderWAV()
        let source = loaderSource(audio)
        let gate = LoaderResponseGate()
        let fixture = LoaderDownloadFixture(
            root: root.appending(path: "responses"),
            audio: audio,
            gate: gate
        )
        let rangeCache = TrackRangeCache(
            trackCache: TrackCache(directory: cacheRoot)
        ) {
            try await fixture.download($0)
        }
        var player: AVPlayer? = AVPlayer()
        var item: RangeCachingPlayerItem? = RangeCachingPlayerItem(
            key: loaderKey,
            format: "wav",
            initialSource: source,
            sourceProvider: { source },
            rangeCache: rangeCache,
            preferPreciseTiming: false
        )
        player?.replaceCurrentItem(with: item)
        try await waitForLoaderCondition(stage: "a05-started") { await gate.hasEntered() }

        item?.cancelRangeLoading()
        item?.cancelRangeLoading()
        #expect(item != nil)
        #expect(player?.currentItem === item)
        try await waitForLoaderCondition(stage: "a05-cancelled") {
            let snapshot = await fixture.snapshot()
            let gateCancellations = await gate.cancellations
            return snapshot.cancellations == 1 && gateCancellations == 1
        }
        try await waitForLoaderCondition(stage: "a05-closed") {
            loaderRangeFiles(in: cacheRoot).isEmpty
        }
        #expect(await gate.cancellations == 1)

        player?.replaceCurrentItem(with: nil)
        player = nil
        item = nil
        try await rangeCache.clear()
    }

    @Test("Cancellation while opening rolls back the pinned range body")
    func openCancellationRollback() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cacheRoot = root.appending(path: "cache")
        let audio = loaderWAV()
        let source = loaderSource(audio)
        let pinGate = LoaderResponseGate()
        let downloadCalls = LoaderCounter()
        let trackCache = TrackCache(directory: cacheRoot)
        let rangeCache = TrackRangeCache(
            trackCache: trackCache,
            download: { _ in
                await downloadCalls.increment()
                throw LoaderTestError.injected
            },
            afterPinForTesting: { _ in
                try? await pinGate.wait()
            }
        )
        var player: AVPlayer? = AVPlayer()
        var item: RangeCachingPlayerItem? = RangeCachingPlayerItem(
            key: loaderKey,
            format: "wav",
            initialSource: source,
            sourceProvider: { source },
            rangeCache: rangeCache,
            preferPreciseTiming: false
        )
        player?.replaceCurrentItem(with: item)

        try await waitForLoaderCondition(stage: "a09-started") {
            guard await pinGate.hasEntered() else { return false }
            return loaderRangeFiles(in: cacheRoot).count == 1
        }
        let bodyFiles = loaderRangeFiles(in: cacheRoot)
        #expect(bodyFiles.count == 1)
        let bodyURL = try #require(bodyFiles.first)
        #expect(await downloadCalls.value == 0)

        item?.cancelRangeLoading()
        item?.cancelRangeLoading()
        #expect(item != nil)
        #expect(player?.currentItem === item)
        try await waitForLoaderCondition(stage: "a09-cancelled") {
            await pinGate.cancellations == 1
        }
        await pinGate.release()
        try await waitForLoaderCondition(stage: "a09-rollback") {
            !FileManager.default.fileExists(atPath: bodyURL.path)
        }
        #expect(await downloadCalls.value == 0)
        #expect(await rangeCache.descriptor(for: loaderKey) == nil)

        try Data("range-pin-check".utf8).write(to: bodyURL)
        #expect(FileManager.default.fileExists(atPath: bodyURL.path))
        try await trackCache.clear()
        #expect(!FileManager.default.fileExists(atPath: bodyURL.path))

        player?.replaceCurrentItem(with: nil)
        player = nil
        item = nil
        try await rangeCache.clear()
    }

    @Test("Provider and download failures fail the item")
    func failurePaths() async throws {
        let audio = loaderWAV()

        do {
            let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let providerCalls = LoaderCounter()
            let rangeCache = TrackRangeCache(
                trackCache: TrackCache(directory: root.appending(path: "cache"))
            ) { _ in
                throw LoaderTestError.injected
            }
            do {
                let item = RangeCachingPlayerItem(
                    key: loaderKey,
                    format: "wav",
                    initialSource: nil,
                    sourceProvider: {
                        await providerCalls.increment()
                        throw LoaderTestError.injected
                    },
                    rangeCache: rangeCache,
                    preferPreciseTiming: false
                )
                let player = AVPlayer(playerItem: item)
                #expect(try await waitForLoaderStatus(item) == .failed)
                player.replaceCurrentItem(with: nil)
            }
            #expect(await providerCalls.value == 1)
            try await rangeCache.clear()
        }

        do {
            let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let source = loaderSource(audio, representation: false)
            let downloadCalls = LoaderCounter()
            let rangeCache = TrackRangeCache(
                trackCache: TrackCache(directory: root.appending(path: "cache"))
            ) { _ in
                await downloadCalls.increment()
                throw URLError(.cannotLoadFromNetwork)
            }
            do {
                let item = RangeCachingPlayerItem(
                    key: loaderKey,
                    format: "wav",
                    initialSource: source,
                    sourceProvider: { source },
                    rangeCache: rangeCache,
                    preferPreciseTiming: false
                )
                let player = AVPlayer(playerItem: item)
                #expect(try await waitForLoaderStatus(item) == .failed)
                player.replaceCurrentItem(with: nil)
            }
            #expect(await downloadCalls.value == 1)
            try await rangeCache.clear()
        }
    }
}
