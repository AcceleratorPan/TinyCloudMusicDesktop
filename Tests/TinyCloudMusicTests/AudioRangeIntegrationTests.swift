import AVFoundation
import CryptoKit
import Foundation
import Testing

@testable import TinyCloudMusic

private enum AudioRangeIntegrationStage: String {
    case fixtureStart = "fixture_start"
    case generateFLAC = "generate_flac"
    case ready
    case play
    case activeStart = "active_start"
    case activeClock = "active_clock"
    case activeProgress = "active_progress"
    case seek
    case preroll
    case qualitySwitch = "quality_switch"
    case fallback
    case requestValidation = "request_validation"
    case platformLimit = "platform_limit"
}

private struct AudioRangeIntegrationFailure: Error, CustomStringConvertible {
    let stage: AudioRangeIntegrationStage
    let requestCount: Int
    let rangeCount: Int
    let payloadBytes: Int

    var description: String {
        "stage=\(stage.rawValue) requests=\(requestCount) ranges=\(rangeCount) bytes=\(payloadBytes)"
    }
}

private final class AudioRangeLockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) { self.value = value }

    func withValue<Result>(_ body: (inout Value) -> Result) -> Result {
        lock.withLock { body(&value) }
    }
}

private final class AudioRangeWeakBox<Value: AnyObject> {
    weak let value: Value?

    init(_ value: Value) { self.value = value }
}

private actor AudioRangeResponseGate {
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

private enum AudioRangeHTTPMethod: Sendable {
    case get
    case head
    case other
}

private struct AudioRangeHTTPRequestMetric: Sendable {
    let method: AudioRangeHTTPMethod
    let range: Range<Int>?
    let hadRangeHeader: Bool
    let acceptsIdentity: Bool
    let endpointID: Int
    let hasIfRange: Bool
}

private struct AudioRangeHTTPMetricsSnapshot: Sendable {
    let requests: [AudioRangeHTTPRequestMetric]
    let incompleteTransportCount: Int

    var rangeCount: Int { requests.count { $0.range != nil } }
    var invalidRangeCount: Int { requests.count { $0.hadRangeHeader && $0.range == nil } }
    var uniqueRangeCount: Int { Set(requests.compactMap { $0.range }).count }
    var duplicateRangeCount: Int { rangeCount - uniqueRangeCount }
    var overlappingRangeCount: Int {
        let ranges = requests.compactMap { $0.range }
        guard ranges.count > 1 else { return 0 }
        var count = 0
        for first in ranges.indices {
            for second in ranges.index(after: first)..<ranges.endIndex {
                if max(ranges[first].lowerBound, ranges[second].lowerBound)
                    < min(ranges[first].upperBound, ranges[second].upperBound)
                {
                    count += 1
                }
            }
        }
        return count
    }
    var alignedBlockCount: Int {
        Set(requests.compactMap { $0.range?.lowerBound }.map { $0 / audioRangeBlockSize }).count
    }
    var duplicateAlignedBlockCount: Int { rangeCount - alignedBlockCount }
    var hasNonFirstBlock: Bool {
        requests.contains { ($0.range?.lowerBound ?? 0) >= audioRangeBlockSize }
    }
    var uniqueRangePayloadBytes: Int {
        let ranges = requests.compactMap { $0.range }.sorted {
            $0.lowerBound == $1.lowerBound
                ? $0.upperBound < $1.upperBound
                : $0.lowerBound < $1.lowerBound
        }
        guard var current = ranges.first else { return 0 }
        var total = 0
        for range in ranges.dropFirst() {
            if range.lowerBound <= current.upperBound {
                current = current.lowerBound..<max(current.upperBound, range.upperBound)
            } else {
                total += current.count
                current = range
            }
        }
        return total + current.count
    }

    func duplicatePayloadBytes(fixturePayloadBytes: Int) -> Int {
        max(0, fixturePayloadBytes - uniqueRangePayloadBytes)
    }
}

private struct AudioRangeGateState: Sendable {
    var isEnabled = false
    var didGate = false
    var gatedRange: Range<Int>?
}

private final class AudioRangeHTTPMetrics: @unchecked Sendable {
    private let requests = AudioRangeLockedBox<[AudioRangeHTTPRequestMetric]>([])
    private let incompleteTransportCount = AudioRangeLockedBox(0)

    func record(_ request: AudioRangeHTTPRequestMetric) {
        requests.withValue { $0.append(request) }
    }

    func recordIncompleteTransport() {
        incompleteTransportCount.withValue { $0 += 1 }
    }

    func reset() {
        requests.withValue { $0.removeAll() }
        incompleteTransportCount.withValue { $0 = 0 }
    }

    func snapshot() -> AudioRangeHTTPMetricsSnapshot {
        AudioRangeHTTPMetricsSnapshot(
            requests: requests.withValue { $0 },
            incompleteTransportCount: incompleteTransportCount.withValue { $0 }
        )
    }
}

@MainActor
private func waitForAudioRangeCondition(
    stage: AudioRangeIntegrationStage,
    timeout: Duration = .seconds(15),
    fixture: LocalHTTPFixture? = nil,
    metrics: AudioRangeHTTPMetrics? = nil,
    _ predicate: @escaping @MainActor () async -> Bool
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if await predicate() { return }
        do {
            try await Task.sleep(for: .milliseconds(10))
        } catch {
            break
        }
    }
    let snapshot = metrics?.snapshot()
    throw AudioRangeIntegrationFailure(
        stage: stage,
        requestCount: snapshot?.requests.count ?? 0,
        rangeCount: snapshot?.rangeCount ?? 0,
        payloadBytes: fixture?.responsePayloadBytes ?? 0
    )
}

private func parseAudioByteRange(_ value: String, length: Int) -> Range<Int>? {
    guard length > 0,
          value.lowercased().hasPrefix("bytes="),
          !value.contains(",")
    else { return nil }
    let bounds = value.dropFirst("bytes=".count).split(
        separator: "-",
        maxSplits: 1,
        omittingEmptySubsequences: false
    )
    guard bounds.count == 2 else { return nil }
    if bounds[0].isEmpty, let suffix = Int(bounds[1]), suffix > 0 {
        return max(0, length - suffix)..<length
    }
    guard let lower = Int(bounds[0]), lower >= 0, lower < length else { return nil }
    let upper: Int
    if bounds[1].isEmpty {
        upper = length - 1
    } else if let requestedUpper = Int(bounds[1]), requestedUpper >= lower {
        upper = min(requestedUpper, length - 1)
    } else {
        return nil
    }
    return lower..<(upper + 1)
}

private func audioRangeHTTPResponse(
    for request: Data,
    body: Data,
    contentType: String,
    metrics: AudioRangeHTTPMetrics,
    endpointID: Int = 0,
    strongETag: String? = nil
) -> Data {
    guard request.range(of: Data("\r\n\r\n".utf8)) != nil else {
        metrics.recordIncompleteTransport()
        return fixtureHTTPResponse("400 Bad Request")
    }
    let lines = String(decoding: request, as: UTF8.self).components(separatedBy: "\r\n")
    let method: AudioRangeHTTPMethod = switch lines.first?.split(separator: " ").first {
    case "GET": .get
    case "HEAD": .head
    default: .other
    }
    func header(_ name: String) -> String? {
        let prefix = name.lowercased() + ":"
        return lines.first { $0.lowercased().hasPrefix(prefix) }?
            .dropFirst(prefix.count)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    let rangeHeader = header("Range")
    let range = rangeHeader.flatMap { parseAudioByteRange($0, length: body.count) }
    metrics.record(AudioRangeHTTPRequestMetric(
        method: method,
        range: range,
        hadRangeHeader: rangeHeader != nil,
        acceptsIdentity: header("Accept-Encoding")?.lowercased() == "identity",
        endpointID: endpointID,
        hasIfRange: header("If-Range") != nil
    ))
    var common = ["Accept-Ranges": "bytes", "Content-Type": contentType]
    if let strongETag { common["ETag"] = strongETag }
    if method == .head {
        return fixtureHTTPResponse(
            "200 OK",
            headers: common.merging(["Content-Length": String(body.count)]) { current, _ in current }
        )
    }
    guard method == .get else { return fixtureHTTPResponse("405 Method Not Allowed") }
    guard let rangeHeader else { return fixtureHTTPResponse("200 OK", headers: common, body: body) }
    guard let range else {
        return fixtureHTTPResponse(
            "416 Range Not Satisfiable",
            headers: common.merging(["Content-Range": "bytes */\(body.count)"]) { current, _ in current }
        )
    }
    _ = rangeHeader
    return fixtureHTTPResponse(
        "206 Partial Content",
        headers: common.merging([
            "Content-Range": "bytes \(range.lowerBound)-\(range.upperBound - 1)/\(body.count)",
        ]) { current, _ in current },
        body: body.subdata(in: range)
    )
}

private func audioRangeEndpointID(for request: Data, secondPath: String) -> Int {
    let line = String(decoding: request, as: UTF8.self)
        .components(separatedBy: "\r\n")
        .first
    guard let target = line?.split(separator: " ").dropFirst().first else { return 0 }
    return target.hasPrefix(secondPath) ? 2 : 1
}

@MainActor
private func waitForAudioRangeMetricsToStabilize(
    fixture: LocalHTTPFixture,
    metrics: AudioRangeHTTPMetrics
) async throws {
    let state = AudioRangeLockedBox((last: [Int](), matches: 0))
    try await waitForAudioRangeCondition(
        stage: .requestValidation,
        fixture: fixture,
        metrics: metrics
    ) {
        let snapshot = metrics.snapshot()
        let current = [
            snapshot.requests.count,
            snapshot.incompleteTransportCount,
            fixture.responseCount,
            fixture.responsePayloadBytes,
        ]
        return state.withValue {
            if $0.last == current {
                $0.matches += 1
            } else {
                $0.last = current
                $0.matches = 0
            }
            return $0.matches >= 35
        }
    }
}

private func firstAudioRangeUntouchedBlock(
    in snapshot: AudioRangeHTTPMetricsSnapshot,
    length: Int
) -> Int? {
    guard length > 0 else { return nil }
    let ranges = snapshot.requests.compactMap { $0.range }
    for lower in stride(from: 0, to: length, by: audioRangeBlockSize) {
        let block = lower..<min(length, lower + audioRangeBlockSize)
        let isCovered = ranges.contains {
            max($0.lowerBound, block.lowerBound) < min($0.upperBound, block.upperBound)
        }
        if !isCovered { return lower }
    }
    return nil
}

private func audioRangeBodyCount(in root: URL) -> Int {
    guard FileManager.default.fileExists(atPath: root.path),
          let enumerator = FileManager.default.enumerator(
        at: root,
        includingPropertiesForKeys: nil
    ) else { return -1 }
    return enumerator.compactMap { $0 as? URL }.count { $0.pathExtension == "range" }
}

private let audioRangeBlockSize = 512 * 1_024

private struct GeneratedAudio: Sendable {
    let flacURL: URL
    let flacData: Data
    let wavData: Data
    let duration: TimeInterval
    let sampleRate: Double
}

private func appendAudioRangeLittleEndian<Value: FixedWidthInteger>(
    _ value: Value,
    to data: inout Data
) {
    var value = value.littleEndian
    withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
}

private func audioRangeWAV(seconds: UInt32 = 8, sampleRate: UInt32 = 44_100) -> Data {
    let channels: UInt32 = 2
    let bytesPerSample: UInt32 = 2
    let dataSize = sampleRate * seconds * channels * bytesPerSample
    var data = Data("RIFF".utf8)
    appendAudioRangeLittleEndian(36 + dataSize, to: &data)
    data.append(Data("WAVEfmt ".utf8))
    appendAudioRangeLittleEndian(UInt32(16), to: &data)
    appendAudioRangeLittleEndian(UInt16(1), to: &data)
    appendAudioRangeLittleEndian(UInt16(channels), to: &data)
    appendAudioRangeLittleEndian(sampleRate, to: &data)
    appendAudioRangeLittleEndian(sampleRate * channels * bytesPerSample, to: &data)
    appendAudioRangeLittleEndian(UInt16(channels * bytesPerSample), to: &data)
    appendAudioRangeLittleEndian(UInt16(bytesPerSample * 8), to: &data)
    data.append(Data("data".utf8))
    appendAudioRangeLittleEndian(dataSize, to: &data)
    data.append(Data(repeating: 0, count: Int(dataSize)))
    return data
}

private func generateAudio(in root: URL) throws -> GeneratedAudio {
    let sampleRate = 44_100.0
    let duration = 12.0
    let frameCount = Int64(sampleRate * duration)
    let flacURL = root.appending(path: "integration.flac")
    let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatFLAC,
        AVSampleRateKey: sampleRate,
        AVNumberOfChannelsKey: 2,
    ]

    do {
        try autoreleasepool {
            let file = try AVAudioFile(forWriting: flacURL, settings: settings)
            let capacity: AVAudioFrameCount = 8_192
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: file.processingFormat,
                frameCapacity: capacity
            ), let channels = buffer.floatChannelData else {
                throw AudioRangeIntegrationFailure(
                    stage: .generateFLAC,
                    requestCount: 0,
                    rangeCount: 0,
                    payloadBytes: 0
                )
            }

            var generated: Int64 = 0
            var randomState: UInt32 = 0xC0FFEE
            while generated < frameCount {
                let frames = min(Int64(capacity), frameCount - generated)
                buffer.frameLength = AVAudioFrameCount(frames)
                for frame in 0..<Int(frames) {
                    let sampleIndex = generated + Int64(frame)
                    let tone = Float(
                        sin(2 * Double.pi * 440 * Double(sampleIndex) / sampleRate) * 0.08
                    )
                    for channel in 0..<2 {
                        randomState = randomState &* 1_664_525 &+ 1_013_904_223
                        let noise = Float(Int32(bitPattern: randomState)) / Float(Int32.max) * 0.35
                        channels[channel][frame * buffer.stride] = tone + noise
                    }
                }
                try file.write(from: buffer)
                generated += frames
            }
        }
    } catch is AudioRangeIntegrationFailure {
        throw AudioRangeIntegrationFailure(
            stage: .generateFLAC,
            requestCount: 0,
            rangeCount: 0,
            payloadBytes: 0
        )
    } catch {
        throw AudioRangeIntegrationFailure(
            stage: .generateFLAC,
            requestCount: 0,
            rangeCount: 0,
            payloadBytes: 0
        )
    }

    let flacData: Data
    do {
        flacData = try Data(contentsOf: flacURL)
    } catch {
        throw AudioRangeIntegrationFailure(
            stage: .generateFLAC,
            requestCount: 0,
            rangeCount: 0,
            payloadBytes: 0
        )
    }
    guard flacData.count > audioRangeBlockSize,
          flacData.starts(with: Data("fLaC".utf8))
    else {
        throw AudioRangeIntegrationFailure(
            stage: .generateFLAC,
            requestCount: 0,
            rangeCount: 0,
            payloadBytes: flacData.count
        )
    }
    return GeneratedAudio(
        flacURL: flacURL,
        flacData: flacData,
        wavData: audioRangeWAV(),
        duration: duration,
        sampleRate: sampleRate
    )
}

private func audioRangeMD5(_ data: Data) -> String {
    Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func audioRangePlaybackSource(
    url: URL,
    level: String,
    format: String,
    data: Data
) throws -> PlaybackSource {
    guard let representation = PlaybackRepresentation(
        contentLength: Int64(data.count),
        contentMD5: audioRangeMD5(data)
    ) else {
        throw AudioRangeIntegrationFailure(
            stage: .requestValidation,
            requestCount: 0,
            rangeCount: 0,
            payloadBytes: data.count
        )
    }
    return PlaybackSource(
        url: url,
        availability: .playable(level: level),
        format: format,
        representation: representation
    )
}

private func audioRangeURLSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    configuration.urlCache = nil
    configuration.httpCookieStorage = nil
    return URLSession(configuration: configuration)
}

@MainActor
private func expectAudioRangeError(
    _ expected: TrackRangeCacheError,
    _ operation: () async throws -> Void
) async {
    do {
        try await operation()
        Issue.record("Expected range cache error")
    } catch let error as TrackRangeCacheError {
        #expect(error == expected)
    } catch {
        Issue.record("Unexpected range cache error type")
    }
}

@MainActor
private func expectAudioRangeCancellation(
    _ operation: () async throws -> Void
) async {
    do {
        try await operation()
        Issue.record("Expected cancellation")
    } catch is CancellationError {
    } catch {
        Issue.record("Unexpected cancellation error type")
    }
}

private final class AudioRangeBoolCompletion: @unchecked Sendable {
    private let valueBox = AudioRangeLockedBox<Bool?>(nil)

    func finish(_ value: Bool) {
        valueBox.withValue {
            if $0 == nil { $0 = value }
        }
    }

    var value: Bool? { valueBox.withValue { $0 } }
}

private func startAudioRangeFixture(_ fixture: LocalHTTPFixture) async throws -> UInt16 {
    try await withThrowingTaskGroup(of: UInt16.self) { group in
        group.addTask { try await fixture.start() }
        group.addTask {
            try await Task.sleep(for: .seconds(5))
            fixture.stop()
            throw AudioRangeIntegrationFailure(
                stage: .fixtureStart,
                requestCount: 0,
                rangeCount: 0,
                payloadBytes: 0
            )
        }
        defer { group.cancelAll() }
        guard let port = try await group.next() else {
            throw AudioRangeIntegrationFailure(
                stage: .fixtureStart,
                requestCount: 0,
                rangeCount: 0,
                payloadBytes: 0
            )
        }
        return port
    }
}

@MainActor
private func waitForAudioRangeReady(
    _ item: AVPlayerItem,
    fixture: LocalHTTPFixture? = nil,
    metrics: AudioRangeHTTPMetrics? = nil
) async throws {
    try await waitForAudioRangeCondition(
        stage: .ready,
        fixture: fixture,
        metrics: metrics
    ) { item.status != .unknown }
    guard item.status == .readyToPlay else {
        let snapshot = metrics?.snapshot()
        throw AudioRangeIntegrationFailure(
            stage: .ready,
            requestCount: snapshot?.requests.count ?? 0,
            rangeCount: snapshot?.rangeCount ?? 0,
            payloadBytes: fixture?.responsePayloadBytes ?? 0
        )
    }
}

@MainActor
private func seekAudioRangePlayer(
    _ player: AVPlayer,
    to target: TimeInterval,
    fixture: LocalHTTPFixture? = nil,
    metrics: AudioRangeHTTPMetrics? = nil
) async throws -> TimeInterval {
    let completion = AudioRangeBoolCompletion()
    player.seek(
        to: CMTime(seconds: target, preferredTimescale: 44_100),
        toleranceBefore: CMTime(seconds: 0.1, preferredTimescale: 1_000),
        toleranceAfter: CMTime(seconds: 0.1, preferredTimescale: 1_000)
    ) { completion.finish($0) }
    try await waitForAudioRangeCondition(
        stage: .seek,
        fixture: fixture,
        metrics: metrics
    ) { completion.value != nil }
    guard completion.value == true else {
        let snapshot = metrics?.snapshot()
        throw AudioRangeIntegrationFailure(
            stage: .seek,
            requestCount: snapshot?.requests.count ?? 0,
            rangeCount: snapshot?.rangeCount ?? 0,
            payloadBytes: fixture?.responsePayloadBytes ?? 0
        )
    }
    return player.currentTime().seconds
}

@MainActor
private func prerollAudioRangePlayer(
    _ player: AVPlayer,
    fixture: LocalHTTPFixture? = nil,
    metrics: AudioRangeHTTPMetrics? = nil
) async throws {
    let completion = AudioRangeBoolCompletion()
    player.preroll(atRate: 1) { completion.finish($0) }
    try await waitForAudioRangeCondition(
        stage: .preroll,
        fixture: fixture,
        metrics: metrics
    ) { completion.value != nil }
    guard completion.value == true else {
        let snapshot = metrics?.snapshot()
        throw AudioRangeIntegrationFailure(
            stage: .preroll,
            requestCount: snapshot?.requests.count ?? 0,
            rangeCount: snapshot?.rangeCount ?? 0,
            payloadBytes: fixture?.responsePayloadBytes ?? 0
        )
    }
}

@MainActor
private func tearDownAudioRangePlayer(
    _ player: AVPlayer,
    rangeItem: RangeCachingPlayerItem? = nil
) {
    rangeItem?.cancelRangeLoading()
    player.pause()
    player.replaceCurrentItem(with: nil)
}

private enum AudioRangeFLACBranch: String, CaseIterable, Hashable, Sendable {
    case directPrecise = "direct-precise-true"
    case customPrecise = "custom-precise-true"
    case customDiagnostic = "custom-precise-false"

    var usesRangeCache: Bool { self != .directPrecise }
    var precise: Bool { self != .customDiagnostic }
}

private enum AudioRangeIgnoreRangeBranch: String, CaseIterable, Sendable {
    case matchingIdentity = "matching-identity"
    case mismatchedIdentity = "mismatched-identity"
    case transientPublished = "transient-published"
}

private struct AudioRangeFLACRunMetric: Sendable {
    let branch: AudioRangeFLACBranch
    let readySeconds: Double
    let readyPayloadBytes: Int
    let seekSeconds: Double
    let seekPayloadBytes: Int
    let seekError: Double
    let prerollSeconds: Double
    let prerollPayloadBytes: Int
    let durationError: Double
    let requestCount: Int
    let uniqueRangeCount: Int
    let duplicateRangeCount: Int
    let overlappingRangeCount: Int
    let uniqueAlignedBlockCount: Int
    let duplicateAlignedBlockCount: Int
    let uniqueRangePayloadBytes: Int
    let duplicatePayloadBytes: Int
    let incompleteTransportCount: Int

    var totalSeconds: Double { readySeconds + seekSeconds + prerollSeconds }
    var totalPayloadBytes: Int {
        readyPayloadBytes + seekPayloadBytes + prerollPayloadBytes
    }
}

private let audioRangeSongID = AudioRangeLockedBox<Int64>(22_000)

private func audioRangeDurationSeconds(_ duration: Duration) -> Double {
    let components = duration.components
    return Double(components.seconds)
        + Double(components.attoseconds) / 1_000_000_000_000_000_000
}

@MainActor
private func audioRangeFLACBaseline(_ audio: GeneratedAudio) async throws -> Double {
    let asset = AVURLAsset(
        url: audio.flacURL,
        options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
    )
    let item = AVPlayerItem(asset: asset)
    let player = AVPlayer(playerItem: item)
    player.automaticallyWaitsToMinimizeStalling = false
    defer { tearDownAudioRangePlayer(player) }

    try await waitForAudioRangeReady(item)
    let duration = item.duration.seconds
    guard duration.isFinite, duration > 0 else {
        throw AudioRangeIntegrationFailure(
            stage: .ready,
            requestCount: 0,
            rangeCount: 0,
            payloadBytes: audio.flacData.count
        )
    }
    let durationIsExact = abs(duration - audio.duration) <= 0.05
    #expect(durationIsExact)
    let target = duration * 0.65
    let actual = try await seekAudioRangePlayer(player, to: target)
    let seekIsExact = actual.isFinite && abs(actual - target) <= 0.15
    #expect(seekIsExact)
    return duration
}

@MainActor
private func runFLACTrial(
    branch: AudioRangeFLACBranch,
    audio: GeneratedAudio,
    baselineDuration: Double
) async throws -> AudioRangeFLACRunMetric {
    let root = FileManager.default.temporaryDirectory.appending(
        path: "TinyCloudMusic-W11-I02-\(UUID().uuidString)",
        directoryHint: .isDirectory
    )
    do {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    } catch {
        throw AudioRangeIntegrationFailure(
            stage: .fixtureStart,
            requestCount: 0,
            rangeCount: 0,
            payloadBytes: 0
        )
    }

    let metrics = AudioRangeHTTPMetrics()
    let fixture = try LocalHTTPFixture(
        response: { request in
            audioRangeHTTPResponse(
                for: request,
                body: audio.flacData,
                contentType: "audio/flac",
                metrics: metrics
            )
        },
        initialResponseDelay: .milliseconds(150),
        sendChunkSize: 64 * 1_024,
        sendChunkDelay: .milliseconds(12)
    )
    var loaderSession: URLSession?
    var rangeItem: RangeCachingPlayerItem?
    var player: AVPlayer?
    defer {
        if let player { tearDownAudioRangePlayer(player, rangeItem: rangeItem) }
        loaderSession?.invalidateAndCancel()
        fixture.stop()
        try? FileManager.default.removeItem(at: root)
    }

    let port = try await startAudioRangeFixture(fixture)
    guard let origin = URL(string: "http://127.0.0.1:\(port)/i02.flac") else {
        throw AudioRangeIntegrationFailure(
            stage: .fixtureStart,
            requestCount: 0,
            rangeCount: 0,
            payloadBytes: 0
        )
    }

    let item: AVPlayerItem
    if branch.usesRangeCache {
        let source = try audioRangePlaybackSource(
            url: origin,
            level: "lossless",
            format: "flac",
            data: audio.flacData
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        let session = URLSession(configuration: configuration)
        loaderSession = session
        let trackCache = TrackCache(directory: root.appending(path: "StreamCache"))
        let rangeCache = TrackRangeCache(trackCache: trackCache) { request in
            try await session.download(for: request)
        }
        let providerCalls = AudioRangeLockedBox(0)
        let songID = audioRangeSongID.withValue {
            $0 += 1
            return $0
        }
        let customItem = RangeCachingPlayerItem(
            key: TrackRangeCacheKey(songID: songID, quality: "lossless"),
            format: "flac",
            initialSource: source,
            sourceProvider: {
                providerCalls.withValue { $0 += 1 }
                return source
            },
            rangeCache: rangeCache,
            preferPreciseTiming: branch.precise
        )
        let representationIsExact = source.representation.map {
            $0.contentLength == Int64(audio.flacData.count)
                && $0.contentMD5 == audioRangeMD5(audio.flacData)
        } == true
        #expect(representationIsExact)
        #expect(providerCalls.withValue { $0 } == 0)
        rangeItem = customItem
        item = customItem
    } else {
        item = AVPlayerItem(asset: AVURLAsset(
            url: origin,
            options: [AVURLAssetPreferPreciseDurationAndTimingKey: branch.precise]
        ))
    }

    let avPlayer = AVPlayer(playerItem: item)
    avPlayer.automaticallyWaitsToMinimizeStalling = false
    player = avPlayer
    let clock = ContinuousClock()
    let readyStart = clock.now
    try await waitForAudioRangeReady(item, fixture: fixture, metrics: metrics)
    let readySeconds = audioRangeDurationSeconds(readyStart.duration(to: clock.now))
    let readyPayload = fixture.responsePayloadBytes
    let duration = item.duration.seconds
    guard duration.isFinite, duration > 0 else {
        let snapshot = metrics.snapshot()
        throw AudioRangeIntegrationFailure(
            stage: .ready,
            requestCount: snapshot.requests.count,
            rangeCount: snapshot.rangeCount,
            payloadBytes: readyPayload
        )
    }
    let durationError = abs(duration - baselineDuration)
    #expect(durationError <= 0.05)

    let target = baselineDuration * 0.65
    let seekStartPayload = fixture.responsePayloadBytes
    let seekStart = clock.now
    let actual = try await seekAudioRangePlayer(
        avPlayer,
        to: target,
        fixture: fixture,
        metrics: metrics
    )
    let seekSeconds = audioRangeDurationSeconds(seekStart.duration(to: clock.now))
    let seekPayload = fixture.responsePayloadBytes - seekStartPayload
    let seekError = abs(actual - target)
    #expect(actual.isFinite && seekError <= 0.15)

    let prerollStartPayload = fixture.responsePayloadBytes
    let prerollStart = clock.now
    try await prerollAudioRangePlayer(avPlayer, fixture: fixture, metrics: metrics)
    let prerollSeconds = audioRangeDurationSeconds(prerollStart.duration(to: clock.now))
    let prerollPayload = fixture.responsePayloadBytes - prerollStartPayload
    let snapshot = metrics.snapshot()
    let duplicatePayloadBytes = snapshot.duplicatePayloadBytes(
        fixturePayloadBytes: fixture.responsePayloadBytes
    )

    if branch.usesRangeCache {
        #expect(snapshot.invalidRangeCount == 0)
        #expect(snapshot.rangeCount == snapshot.requests.count)
        #expect(snapshot.requests.allSatisfy { $0.method == .get && $0.acceptsIdentity })
        #expect(snapshot.hasNonFirstBlock)
        #expect(duplicatePayloadBytes < audioRangeBlockSize)
    }
    return AudioRangeFLACRunMetric(
        branch: branch,
        readySeconds: readySeconds,
        readyPayloadBytes: readyPayload,
        seekSeconds: seekSeconds,
        seekPayloadBytes: seekPayload,
        seekError: seekError,
        prerollSeconds: prerollSeconds,
        prerollPayloadBytes: prerollPayload,
        durationError: durationError,
        requestCount: snapshot.requests.count,
        uniqueRangeCount: snapshot.uniqueRangeCount,
        duplicateRangeCount: snapshot.duplicateRangeCount,
        overlappingRangeCount: snapshot.overlappingRangeCount,
        uniqueAlignedBlockCount: snapshot.alignedBlockCount,
        duplicateAlignedBlockCount: snapshot.duplicateAlignedBlockCount,
        uniqueRangePayloadBytes: snapshot.uniqueRangePayloadBytes,
        duplicatePayloadBytes: duplicatePayloadBytes,
        incompleteTransportCount: snapshot.incompleteTransportCount
    )
}

private func audioRangeMedian(_ values: [Double]) -> Double {
    values.sorted()[values.count / 2]
}

private func audioRangeMedian(_ values: [Int]) -> Double {
    audioRangeMedian(values.map(Double.init))
}

private func audioRangeMetricRange(_ values: [Double], scale: Double = 1) -> String {
    let values = values.map { $0 * scale }
    return String(format: "%.1f...%.1f", values.min() ?? 0, values.max() ?? 0)
}

private func audioRangeMetricRange(_ values: [Int]) -> String {
    "\(values.min() ?? 0)...\(values.max() ?? 0)"
}

private func printAudioRangeFLACSummary(_ runs: [AudioRangeFLACRunMetric]) {
    guard let branch = runs.first?.branch else { return }
    let ready = runs.map(\.readySeconds)
    let seek = runs.map(\.seekSeconds)
    let preroll = runs.map(\.prerollSeconds)
    let total = runs.map(\.totalSeconds)
    let readyBytes = runs.map(\.readyPayloadBytes)
    let seekBytes = runs.map(\.seekPayloadBytes)
    let prerollBytes = runs.map(\.prerollPayloadBytes)
    let totalBytes = runs.map(\.totalPayloadBytes)
    let durationErrors = runs.map(\.durationError)
    let seekErrors = runs.map(\.seekError)
    print(
        "W11 I02 branch=\(branch.rawValue) runs=\(runs.count) "
            + String(format: "readyMedianMs=%.1f ", audioRangeMedian(ready) * 1_000)
            + "readyRangeMs=\(audioRangeMetricRange(ready, scale: 1_000)) "
            + String(format: "seekMedianMs=%.1f ", audioRangeMedian(seek) * 1_000)
            + "seekRangeMs=\(audioRangeMetricRange(seek, scale: 1_000)) "
            + String(format: "prerollMedianMs=%.1f ", audioRangeMedian(preroll) * 1_000)
            + "prerollRangeMs=\(audioRangeMetricRange(preroll, scale: 1_000)) "
            + String(format: "totalMedianMs=%.1f ", audioRangeMedian(total) * 1_000)
            + "totalRangeMs=\(audioRangeMetricRange(total, scale: 1_000)) "
            + "readyBytesMedian=\(Int(audioRangeMedian(readyBytes))) "
            + "readyBytesRange=\(audioRangeMetricRange(readyBytes)) "
            + "seekBytesMedian=\(Int(audioRangeMedian(seekBytes))) "
            + "seekBytesRange=\(audioRangeMetricRange(seekBytes)) "
            + "prerollBytesMedian=\(Int(audioRangeMedian(prerollBytes))) "
            + "prerollBytesRange=\(audioRangeMetricRange(prerollBytes)) "
            + "totalBytesMedian=\(Int(audioRangeMedian(totalBytes))) "
            + "totalBytesRange=\(audioRangeMetricRange(totalBytes)) "
            + String(
                format: "durationErrorMedianMs=%.1f ",
                audioRangeMedian(durationErrors) * 1_000
            )
            + "durationErrorRangeMs=\(audioRangeMetricRange(durationErrors, scale: 1_000)) "
            + String(format: "seekErrorMedianMs=%.1f ", audioRangeMedian(seekErrors) * 1_000)
            + "seekErrorRangeMs=\(audioRangeMetricRange(seekErrors, scale: 1_000)) "
            + "requestsRange=\(audioRangeMetricRange(runs.map(\.requestCount))) "
            + "uniqueRangesRange=\(audioRangeMetricRange(runs.map(\.uniqueRangeCount))) "
            + "exactDuplicateRangesRange=\(audioRangeMetricRange(runs.map(\.duplicateRangeCount))) "
            + "overlappingRangesRange=\(audioRangeMetricRange(runs.map(\.overlappingRangeCount))) "
            + "uniqueBlocksRange=\(audioRangeMetricRange(runs.map(\.uniqueAlignedBlockCount))) "
            + "duplicateBlocksRange=\(audioRangeMetricRange(runs.map(\.duplicateAlignedBlockCount))) "
            + "uniqueRangeBytesRange=\(audioRangeMetricRange(runs.map(\.uniqueRangePayloadBytes))) "
            + "duplicatePayloadBytesMedian=\(Int(audioRangeMedian(runs.map(\.duplicatePayloadBytes)))) "
            + "duplicatePayloadBytesRange=\(audioRangeMetricRange(runs.map(\.duplicatePayloadBytes))) "
            + "incompleteTransportRange=\(audioRangeMetricRange(runs.map(\.incompleteTransportCount)))"
    )
}

private actor AudioRangePlayerRepository: MusicRepository {
    nonisolated let homeDescriptors: [HomeSectionDescriptor] = []

    private let song: Song
    private let levelSources: [String: [PlaybackSource]]
    private var sourceIndices: [String: Int] = [:]
    private var requestedLevels: [String] = []

    init(song: Song, levelSources: [String: [PlaybackSource]]) {
        self.song = song
        self.levelSources = levelSources
    }

    func songs(ids: [Int64]) async throws -> [Song] {
        ids.contains(song.id) ? [song] : []
    }

    func lyrics(for songID: Int64) async throws -> SongLyrics {
        SongLyrics(lineLyrics: "[00:00.00]first\n[00:01.00]second")
    }

    func playbackSource(for songID: Int64, quality: AudioQuality) async throws -> PlaybackSource {
        try nextSource(level: quality.cacheComponent)
    }

    func playbackSource(for songID: Int64, level: String) async throws -> PlaybackSource {
        requestedLevels.append(level)
        return try nextSource(level: level)
    }

    func songQualityDetails(for songID: Int64) async throws -> [SongQualityDetail] { [] }
    func levelRequests() -> [String] { requestedLevels }

    private func nextSource(level: String) throws -> PlaybackSource {
        guard let sources = levelSources[level], !sources.isEmpty else {
            throw TrackRangeCacheError.invalidSource
        }
        let index = sourceIndices[level, default: 0]
        sourceIndices[level] = index + 1
        return sources[min(index, sources.count - 1)]
    }

    func homeSection(
        id: String,
        expectedCredentialRevision: UInt64
    ) async throws -> HomeSection { throw AppError.invalidRoute }

    func search(query: String, scope: SearchScope, offset: Int, limit: Int) async throws -> SearchPage {
        throw AppError.invalidRoute
    }

    func detail(
        for route: Route,
        expectedCredentialRevision: UInt64?
    ) async throws -> DetailContent { throw AppError.invalidRoute }

    func recordPlaybackStart(
        for songID: Int64,
        sourceID: Int64,
        totalSeconds: Int,
        expectedCredentialRevision: UInt64
    ) async throws {}

    func recordPlayback(
        for songID: Int64,
        sourceID: Int64,
        playedSeconds: Int,
        totalSeconds: Int,
        expectedCredentialRevision: UInt64
    ) async throws {}

    func recordPodcastPlayback(
        for episodeID: Int64,
        positionMilliseconds: Int,
        completed: Bool,
        expectedCredentialRevision: UInt64
    ) async throws {}
}

private func audioRangeSong(_ id: Int64, duration: TimeInterval) -> Song {
    Song(
        id: id,
        name: "Audio range integration",
        artists: [ArtistSummary(id: 1, name: "Fixture")],
        album: AlbumSummary(
            id: 1,
            name: "Fixture",
            artwork: Artwork(symbol: "music.note", accent: .red)
        ),
        duration: .seconds(Int64(duration.rounded()))
    )
}

@MainActor
private func audioRangeAVPlayer(_ controller: PlayerController, named name: String) -> AVPlayer? {
    Mirror(reflecting: controller).children.first {
        $0.label == name || $0.label == "_\(name)"
    }?.value as? AVPlayer
}

@MainActor
private func audioRangeAVPlayers(_ controller: PlayerController) -> [AVPlayer] {
    ["avPlayer", "standbyPlayer"].compactMap {
        audioRangeAVPlayer(controller, named: $0)
    }
}

@MainActor
private func audioRangePrivateInt(_ controller: PlayerController, named name: String) -> Int? {
    Mirror(reflecting: controller).children.first {
        $0.label == name || $0.label == "_\(name)"
    }?.value as? Int
}

@MainActor
private func audioRangeHasPrivateOptional(_ controller: PlayerController, named name: String) -> Bool {
    guard let value = Mirror(reflecting: controller).children.first(where: {
        $0.label == name || $0.label == "_\(name)"
    })?.value else { return false }
    let optional = Mirror(reflecting: value)
    return optional.displayStyle == .optional && !optional.children.isEmpty
}

private struct AudioRangeFallbackSnapshot {
    let position: TimeInterval
    let wantsPlayback: Bool
}

@MainActor
private func audioRangeActiveFallbackSnapshot(
    _ controller: PlayerController
) -> AudioRangeFallbackSnapshot? {
    guard let value = Mirror(reflecting: controller).children.first(where: {
        $0.label == "activeRangeFallback" || $0.label == "_activeRangeFallback"
    })?.value,
          let fallback = Mirror(reflecting: value).children.first?.value
    else { return nil }
    let fields = Mirror(reflecting: fallback).children
    guard let position = fields.first(where: { $0.label == "position" })?.value as? TimeInterval,
          let wantsPlayback = fields.first(where: { $0.label == "initialWantsPlayback" })?.value
            as? Bool
    else { return nil }
    return AudioRangeFallbackSnapshot(position: position, wantsPlayback: wantsPlayback)
}

enum AudioRangeFallbackScenario: String, CaseIterable, Sendable {
    case playing
    case paused
    case changesWhileWaiting

    var songID: Int64 {
        switch self {
        case .playing: 120_001
        case .paused: 120_002
        case .changesWhileWaiting: 120_003
        }
    }
}

private enum AudioRangeQualityBranch: String, CaseIterable, Sendable {
    case direct
    case custom
}

private struct AudioRangeQualityMilestone: Sendable {
    let originPayloadBytes: Int
    let uniqueBlockCount: Int
}

private func audioRangeQualityMilestone(
    fixture: LocalHTTPFixture,
    metrics: AudioRangeHTTPMetrics
) -> AudioRangeQualityMilestone {
    AudioRangeQualityMilestone(
        originPayloadBytes: fixture.responsePayloadBytes,
        uniqueBlockCount: metrics.snapshot().alignedBlockCount
    )
}

private struct AudioRangeQualityMetric: Sendable {
    let branch: AudioRangeQualityBranch
    let promoteSeconds: Double
    let readyPayloadBytes: Int
    let readyUniqueBlockCount: Int
    let seekPayloadBytes: Int
    let seekUniqueBlockCount: Int
    let prerollPayloadBytes: Int
    let prerollUniqueBlockCount: Int
    let promotePayloadBytes: Int
    let promoteUniqueBlockCount: Int
    let requestCount: Int
    let duplicatePayloadBytes: Int
    let positionError: Double
    let crossfadeSeconds: Double
}

@MainActor
private func runAudioRangeQualitySwitchTrial(
    branch: AudioRangeQualityBranch,
    audio: GeneratedAudio,
    origin: URL,
    fixture: LocalHTTPFixture,
    metrics: AudioRangeHTTPMetrics,
    run: Int,
    gatedSeeks: Bool = false
) async throws -> AudioRangeQualityMetric {
    let root = FileManager.default.temporaryDirectory.appending(
        path: "TinyCloudMusic-W11-I08-\(branch.rawValue)-\(run)-\(UUID().uuidString)",
        directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let activeURL = root.appending(path: "active.wav")
    try audio.wavData.write(to: activeURL)
    let song = audioRangeSong(80_000 + Int64(run), duration: 8)
    let activeSource = PlaybackSource(
        url: activeURL,
        availability: .playable(level: "standard"),
        format: "wav"
    )
    let qualitySource: PlaybackSource
    switch branch {
    case .direct:
        qualitySource = PlaybackSource(
            url: origin,
            availability: .trial(level: "lossless", endSeconds: nil),
            format: "flac"
        )
    case .custom:
        qualitySource = try audioRangePlaybackSource(
            url: origin,
            level: "lossless",
            format: "flac",
            data: audio.flacData
        )
    }
    let repository = AudioRangePlayerRepository(
        song: song,
        levelSources: ["standard": [activeSource], "lossless": [qualitySource]]
    )
    let wholeFileDownloads = AudioRangeLockedBox(0)
    let trackCache = TrackCache(directory: root.appending(path: "StreamCache"), download: { _ in
        wholeFileDownloads.withValue { $0 += 1 }
        throw URLError(.unsupportedURL)
    })
    let session = audioRangeURLSession()
    let gate = gatedSeeks ? AudioRangeResponseGate() : nil
    let rangeCache = TrackRangeCache(trackCache: trackCache) { request in
        let downloaded = try await session.download(for: request)
        if let gate { try await gate.wait() }
        return downloaded
    }
    let player = PlayerController(
        repository: repository,
        cache: trackCache,
        crossfadeDuration: 0,
        rangeCache: rangeCache
    )
    defer {
        if let gate { Task { await gate.release() } }
        for avPlayer in audioRangeAVPlayers(player) {
            (avPlayer.currentItem as? RangeCachingPlayerItem)?.cancelRangeLoading()
            avPlayer.pause()
            avPlayer.replaceCurrentItem(with: nil)
        }
        session.invalidateAndCancel()
        try? FileManager.default.removeItem(at: root)
    }

    player.play(song, in: [song])
    try await waitForAudioRangeCondition(stage: .activeStart, fixture: fixture, metrics: metrics) {
        guard let active = audioRangeAVPlayer(player, named: "avPlayer"),
              let item = active.currentItem
        else { return false }
        let current = active.currentTime().seconds
        let itemDuration = item.duration.seconds
        return player.isPlaying
            && active.rate > 0
            && active.timeControlStatus == .playing
            && item.status == .readyToPlay
            && current.isFinite
            && itemDuration.isFinite
            && itemDuration > 2
    }
    let originalActive = try #require(audioRangeAVPlayer(player, named: "avPlayer"))
    let originalItem = try #require(originalActive.currentItem)
    let standbySeekFloor: TimeInterval = 0.25
    try await waitForAudioRangeCondition(
        stage: .activeProgress,
        fixture: fixture,
        metrics: metrics
    ) {
        let current = originalActive.currentTime().seconds
        return current.isFinite
            && current >= standbySeekFloor * 2
            && player.position >= standbySeekFloor * 2
    }
    let quality = SongQualityDetail(
        id: "lossless",
        bitrate: 999_000,
        size: Int64(audio.flacData.count),
        sampleRate: Int(audio.sampleRate),
        isAvailable: true
    )
    let clock = ContinuousClock()
    let started = clock.now
    let seekMilestones = AudioRangeLockedBox<[ObjectIdentifier: AudioRangeQualityMilestone]>([:])
    let timeJumpObserver = NotificationCenter.default.addObserver(
        forName: .AVPlayerItemTimeJumped,
        object: nil,
        queue: nil
    ) { notification in
        guard let item = notification.object as? AVPlayerItem else { return }
        let itemTime = item.currentTime().seconds
        guard itemTime.isFinite, itemTime >= standbySeekFloor else { return }
        seekMilestones.withValue { milestones in
            let itemID = ObjectIdentifier(item)
            guard milestones[itemID] == nil else { return }
            milestones[itemID] = audioRangeQualityMilestone(fixture: fixture, metrics: metrics)
        }
    }
    defer { NotificationCenter.default.removeObserver(timeJumpObserver) }
    player.selectPlaybackQuality(quality)
    try await waitForAudioRangeCondition(
        stage: .qualitySwitch,
        fixture: fixture,
        metrics: metrics
    ) {
        audioRangeAVPlayer(player, named: "standbyPlayer")?.currentItem != nil
    }
    let standby = try #require(audioRangeAVPlayer(player, named: "standbyPlayer"))
    let qualityItem = try #require(standby.currentItem)
    #expect((qualityItem is RangeCachingPlayerItem) == (branch == .custom))

    if let gate {
        try await waitForAudioRangeCondition(
            stage: .qualitySwitch,
            fixture: fixture,
            metrics: metrics
        ) { await gate.hasEntered() }
        try await waitForAudioRangeCondition(
            stage: .activeClock,
            fixture: fixture,
            metrics: metrics
        ) {
            let current = originalActive.currentTime().seconds
            return originalActive.currentItem === originalItem
                && originalActive.rate > 0
                && originalActive.timeControlStatus == .playing
                && current.isFinite
        }
        let activeStart = originalActive.currentTime().seconds
        try await waitForAudioRangeCondition(
            stage: .activeProgress,
            fixture: fixture,
            metrics: metrics
        ) {
            let current = originalActive.currentTime().seconds
            return originalActive.currentItem === originalItem
                && originalActive.rate > 0
                && originalActive.timeControlStatus == .playing
                && current.isFinite
                && current >= activeStart + 0.05
        }
        let revision = try #require(audioRangePrivateInt(
            player,
            named: "standbyPreparationRevision"
        ))
        for target in [1.1, 1.5, 1.9] {
            player.seek(to: target)
            #expect(player.displayedPosition == target)
            await Task.yield()
        }
        try await waitForAudioRangeCondition(stage: .seek, fixture: fixture, metrics: metrics) {
            player.pendingSeekPosition == nil
                && abs(originalActive.currentTime().seconds - 1.9) <= 0.15
        }
        #expect(originalActive.currentItem === originalItem)
        #expect(standby.currentItem === qualityItem)
        #expect((audioRangePrivateInt(
            player,
            named: "standbyPreparationRevision"
        ) ?? revision) >= revision + 3)
        #expect(await repository.levelRequests() == ["standard", "lossless"])
        await gate.release()
    }

    try await waitForAudioRangeReady(qualityItem, fixture: fixture, metrics: metrics)
    let readyMilestone = audioRangeQualityMilestone(fixture: fixture, metrics: metrics)
    let qualityItemID = ObjectIdentifier(qualityItem)
    try await waitForAudioRangeCondition(
        stage: .seek,
        fixture: fixture,
        metrics: metrics
    ) {
        seekMilestones.withValue { $0[qualityItemID] != nil }
    }
    let seekMilestone = try #require(seekMilestones.withValue { $0[qualityItemID] })
    try await waitForAudioRangeCondition(
        stage: .preroll,
        fixture: fixture,
        metrics: metrics
    ) {
        audioRangeHasPrivateOptional(player, named: "standbyHandoffTask")
            || !player.isSwitchingPlaybackQuality
    }
    guard audioRangeHasPrivateOptional(player, named: "standbyHandoffTask") else {
        throw AudioRangeIntegrationFailure(
            stage: .platformLimit,
            requestCount: metrics.snapshot().requests.count,
            rangeCount: metrics.snapshot().rangeCount,
            payloadBytes: fixture.responsePayloadBytes
        )
    }
    let prerollMilestone = audioRangeQualityMilestone(fixture: fixture, metrics: metrics)
    #expect(originalActive.currentItem === originalItem)
    #expect(originalActive.rate > 0)
    #expect(standby.currentItem === qualityItem)
    #expect(standby.volume == 0)

    try await waitForAudioRangeCondition(
        stage: .qualitySwitch,
        fixture: fixture,
        metrics: metrics
    ) {
        player.currentPlaybackLevel == "lossless" && !player.isSwitchingPlaybackQuality
    }
    let promoteSeconds = audioRangeDurationSeconds(started.duration(to: clock.now))
    let promoteMilestone = audioRangeQualityMilestone(fixture: fixture, metrics: metrics)
    let promoted = try #require(audioRangeAVPlayer(player, named: "avPlayer"))
    #expect(promoted.currentItem === qualityItem)
    let actualPosition = promoted.currentTime().seconds
    let positionError = abs(player.position - actualPosition)
    #expect(actualPosition.isFinite && positionError <= 0.15)
    #expect(player.displayedPosition == player.position)
    #expect(await repository.levelRequests() == ["standard", "lossless"])
    #expect(wholeFileDownloads.withValue { $0 } == 0)
    #expect(readyMilestone.originPayloadBytes <= seekMilestone.originPayloadBytes)
    #expect(seekMilestone.originPayloadBytes <= prerollMilestone.originPayloadBytes)
    #expect(prerollMilestone.originPayloadBytes <= promoteMilestone.originPayloadBytes)
    #expect(readyMilestone.uniqueBlockCount <= seekMilestone.uniqueBlockCount)
    #expect(seekMilestone.uniqueBlockCount <= prerollMilestone.uniqueBlockCount)
    #expect(prerollMilestone.uniqueBlockCount <= promoteMilestone.uniqueBlockCount)

    let crossfadeStart = clock.now
    let outgoing = try #require(audioRangeAVPlayer(player, named: "standbyPlayer"))
    #expect(outgoing.currentItem === originalItem)
    try await waitForAudioRangeCondition(stage: .qualitySwitch) {
        outgoing.currentItem == nil
    }
    let crossfadeSeconds = audioRangeDurationSeconds(crossfadeStart.duration(to: clock.now))
    #expect(crossfadeSeconds >= 0.05 && crossfadeSeconds <= 0.5)

    player.setPlayback(false)
    for avPlayer in audioRangeAVPlayers(player) {
        (avPlayer.currentItem as? RangeCachingPlayerItem)?.cancelRangeLoading()
        avPlayer.pause()
        avPlayer.replaceCurrentItem(with: nil)
    }
    try await waitForAudioRangeMetricsToStabilize(fixture: fixture, metrics: metrics)
    let snapshot = metrics.snapshot()
    let duplicatePayloadBytes = snapshot.duplicatePayloadBytes(
        fixturePayloadBytes: fixture.responsePayloadBytes
    )
    if branch == .custom {
        #expect(snapshot.invalidRangeCount == 0)
        #expect(snapshot.rangeCount == snapshot.requests.count)
        #expect(snapshot.requests.allSatisfy { $0.method == .get && $0.acceptsIdentity })
        #expect(duplicatePayloadBytes < audioRangeBlockSize)
    }
    return AudioRangeQualityMetric(
        branch: branch,
        promoteSeconds: promoteSeconds,
        readyPayloadBytes: readyMilestone.originPayloadBytes,
        readyUniqueBlockCount: readyMilestone.uniqueBlockCount,
        seekPayloadBytes: seekMilestone.originPayloadBytes,
        seekUniqueBlockCount: seekMilestone.uniqueBlockCount,
        prerollPayloadBytes: prerollMilestone.originPayloadBytes,
        prerollUniqueBlockCount: prerollMilestone.uniqueBlockCount,
        promotePayloadBytes: promoteMilestone.originPayloadBytes,
        promoteUniqueBlockCount: promoteMilestone.uniqueBlockCount,
        requestCount: snapshot.requests.count,
        duplicatePayloadBytes: branch == .custom ? duplicatePayloadBytes : 0,
        positionError: positionError,
        crossfadeSeconds: crossfadeSeconds
    )
}

private struct AudioRangeThroughputMetric: Sendable {
    let elapsedSeconds: Double
    let payloadBytes: Int
    let requestCount: Int

    var bytesPerSecond: Double { Double(payloadBytes) / elapsedSeconds }
}

@MainActor
private func runAudioRangeThroughputTrial(
    audio: GeneratedAudio,
    run: Int
) async throws -> AudioRangeThroughputMetric {
    let root = FileManager.default.temporaryDirectory.appending(
        path: "TinyCloudMusic-W11-I11-\(UUID().uuidString)",
        directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let metrics = AudioRangeHTTPMetrics()
    let fixture = try LocalHTTPFixture(
        response: { request in
            audioRangeHTTPResponse(
                for: request,
                body: audio.flacData,
                contentType: "audio/flac",
                metrics: metrics
            )
        },
        initialResponseDelay: .milliseconds(150),
        sendChunkSize: 64 * 1_024,
        sendChunkDelay: .milliseconds(12)
    )
    let networkSession = audioRangeURLSession()
    let trackCache = TrackCache(directory: root.appending(path: "StreamCache"))
    let rangeCache = TrackRangeCache(trackCache: trackCache) { request in
        try await networkSession.download(for: request)
    }
    defer {
        networkSession.invalidateAndCancel()
        fixture.stop()
        try? FileManager.default.removeItem(at: root)
    }

    let port = try await startAudioRangeFixture(fixture)
    guard let origin = URL(string: "http://127.0.0.1:\(port)/i11.flac") else {
        throw AudioRangeIntegrationFailure(
            stage: .fixtureStart,
            requestCount: 0,
            rangeCount: 0,
            payloadBytes: 0
        )
    }
    let source = try audioRangePlaybackSource(
        url: origin,
        level: "lossless",
        format: "flac",
        data: audio.flacData
    )
    let key = TrackRangeCacheKey(songID: 110_000 + Int64(run), quality: "lossless")
    let rangeSession = try await rangeCache.open(
        key: key,
        format: "flac",
        initialSource: source,
        sourceProvider: { source }
    )
    let targetBytes = min(4 * 1_024 * 1_024, audio.flacData.count)
    let clock = ContinuousClock()
    let started = clock.now
    var offset = 0
    while offset < targetBytes {
        let data = try await rangeCache.read(
            session: rangeSession,
            offset: Int64(offset),
            maximumLength: min(256 * 1_024, targetBytes - offset)
        )
        guard !data.isEmpty else {
            throw AudioRangeIntegrationFailure(
                stage: .requestValidation,
                requestCount: metrics.snapshot().requests.count,
                rangeCount: metrics.snapshot().rangeCount,
                payloadBytes: fixture.responsePayloadBytes
            )
        }
        offset += data.count
    }
    let elapsed = audioRangeDurationSeconds(started.duration(to: clock.now))
    try await waitForAudioRangeMetricsToStabilize(fixture: fixture, metrics: metrics)
    let snapshot = metrics.snapshot()
    #expect(offset == targetBytes)
    #expect(elapsed > 0)
    #expect(snapshot.invalidRangeCount == 0)
    #expect(snapshot.rangeCount == snapshot.requests.count)
    #expect(snapshot.duplicatePayloadBytes(
        fixturePayloadBytes: fixture.responsePayloadBytes
    ) == 0)
    #expect(fixture.responsePayloadBytes == targetBytes)
    await rangeCache.close(rangeSession)
    return AudioRangeThroughputMetric(
        elapsedSeconds: elapsed,
        payloadBytes: targetBytes,
        requestCount: snapshot.requests.count
    )
}

@Suite("AudioRangeIntegrationTests", .serialized)
@MainActor
struct AudioRangeIntegrationTests {
    @Test("I01 206 WAV Range item becomes ready and advances")
    func wavRangeReadyAndPlay() async throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "TinyCloudMusic-W11-I01-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        } catch {
            throw AudioRangeIntegrationFailure(
                stage: .fixtureStart,
                requestCount: 0,
                rangeCount: 0,
                payloadBytes: 0
            )
        }

        let wav = audioRangeWAV()
        let metrics = AudioRangeHTTPMetrics()
        let fixture = try LocalHTTPFixture(response: { request in
            audioRangeHTTPResponse(
                for: request,
                body: wav,
                contentType: "audio/wav",
                metrics: metrics
            )
        })
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        let session = URLSession(configuration: configuration)
        let trackCache = TrackCache(directory: root.appending(path: "StreamCache"))
        let rangeCache = TrackRangeCache(trackCache: trackCache) { request in
            try await session.download(for: request)
        }
        let providerCalls = AudioRangeLockedBox(0)
        var player: AVPlayer?
        var rangeItem: RangeCachingPlayerItem?
        defer {
            if let player { tearDownAudioRangePlayer(player, rangeItem: rangeItem) }
            session.invalidateAndCancel()
            fixture.stop()
            try? FileManager.default.removeItem(at: root)
        }

        let port = try await startAudioRangeFixture(fixture)
        guard let origin = URL(string: "http://127.0.0.1:\(port)/i01.wav") else {
            throw AudioRangeIntegrationFailure(
                stage: .fixtureStart,
                requestCount: 0,
                rangeCount: 0,
                payloadBytes: 0
            )
        }
        let source = try audioRangePlaybackSource(
            url: origin,
            level: "standard",
            format: "wav",
            data: wav
        )
        let item = RangeCachingPlayerItem(
            key: TrackRangeCacheKey(songID: 11_001, quality: "standard"),
            format: "wav",
            initialSource: source,
            sourceProvider: {
                providerCalls.withValue { $0 += 1 }
                return source
            },
            rangeCache: rangeCache,
            preferPreciseTiming: false
        )
        rangeItem = item
        let avPlayer = AVPlayer(playerItem: item)
        avPlayer.automaticallyWaitsToMinimizeStalling = false
        player = avPlayer

        try await waitForAudioRangeReady(item, fixture: fixture, metrics: metrics)
        let initialPosition = avPlayer.currentTime().seconds
        avPlayer.play()
        try await waitForAudioRangeCondition(
            stage: .play,
            fixture: fixture,
            metrics: metrics
        ) {
            let current = avPlayer.currentTime().seconds
            return current.isFinite && current >= initialPosition + 0.15
        }
        avPlayer.pause()

        let snapshot = metrics.snapshot()
        let identityIsExact = source.representation.map {
            $0.contentLength == Int64(wav.count) && $0.contentMD5 == audioRangeMD5(wav)
        } == true
        #expect(item.status == .readyToPlay)
        #expect(identityIsExact)
        #expect(providerCalls.withValue { $0 } == 0)
        #expect(!snapshot.requests.isEmpty)
        #expect(snapshot.invalidRangeCount == 0)
        #expect(snapshot.rangeCount == snapshot.requests.count)
        #expect(snapshot.requests.allSatisfy { $0.method == .get })
        #expect(snapshot.requests.allSatisfy { $0.acceptsIdentity })
        #expect(fixture.responsePayloadBytes > 0)
        #expect(fixture.responsePayloadBytes <= wav.count)
    }

    @Test("I02 real FLAC direct and Range ready, seek, and preroll A/B")
    func flacDirectAndRangeAB() async throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "TinyCloudMusic-W11-I02-media-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        } catch {
            throw AudioRangeIntegrationFailure(
                stage: .generateFLAC,
                requestCount: 0,
                rangeCount: 0,
                payloadBytes: 0
            )
        }
        defer { try? FileManager.default.removeItem(at: root) }

        let audio = try generateAudio(in: root)
        let baselineDuration = try await audioRangeFLACBaseline(audio)
        var runs: [AudioRangeFLACBranch: [AudioRangeFLACRunMetric]] = [:]
        for branch in AudioRangeFLACBranch.allCases {
            _ = try await runFLACTrial(
                branch: branch,
                audio: audio,
                baselineDuration: baselineDuration
            )
            for _ in 0..<5 {
                runs[branch, default: []].append(try await runFLACTrial(
                    branch: branch,
                    audio: audio,
                    baselineDuration: baselineDuration
                ))
            }
        }

        for branch in AudioRangeFLACBranch.allCases {
            #expect(runs[branch]?.count == 5)
        }
        guard let direct = runs[.directPrecise], direct.count == 5 else {
            throw AudioRangeIntegrationFailure(
                stage: .requestValidation,
                requestCount: 0,
                rangeCount: 0,
                payloadBytes: 0
            )
        }
        for branch in [AudioRangeFLACBranch.customPrecise, .customDiagnostic] {
            guard let custom = runs[branch], custom.count == direct.count else {
                throw AudioRangeIntegrationFailure(
                    stage: .requestValidation,
                    requestCount: 0,
                    rangeCount: 0,
                    payloadBytes: 0
                )
            }
            for (customRun, directRun) in zip(custom, direct) {
                let payloadIsBounded = customRun.totalPayloadBytes
                    <= directRun.totalPayloadBytes + audioRangeBlockSize
                #expect(payloadIsBounded)
            }
        }

        #if DEBUG
        print("W11 I02 configuration=debug correctnessMetrics=recorded performance=diagnostic-only")
        #else
        for branch in AudioRangeFLACBranch.allCases {
            printAudioRangeFLACSummary(runs[branch] ?? [])
        }
        print("W11 I02 releaseBaseline=RECORDED promoteGate=I08")
        #endif
    }

    @Test("I03 warm API identity survives a signed URL change")
    func warmAPIIdentityAcrossURLs() async throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "TinyCloudMusic-W11-I03-digest-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let wav = audioRangeWAV(seconds: 60)
        let metrics = AudioRangeHTTPMetrics()
        let secondPath = "/i03-b.wav"
        let fixture = try LocalHTTPFixture(response: { request in
            let endpointID = audioRangeEndpointID(for: request, secondPath: secondPath)
            return audioRangeHTTPResponse(
                for: request,
                body: wav,
                contentType: "audio/wav",
                metrics: metrics,
                endpointID: endpointID,
                strongETag: endpointID == 2 ? "\"i03-b\"" : "\"i03-a\""
            )
        })
        let session = audioRangeURLSession()
        let trackCache = TrackCache(directory: root.appending(path: "StreamCache"))
        defer {
            session.invalidateAndCancel()
            fixture.stop()
            try? FileManager.default.removeItem(at: root)
        }

        let port = try await startAudioRangeFixture(fixture)
        guard let originA = URL(string: "http://127.0.0.1:\(port)/i03-a.wav"),
              let originB = URL(string: "http://127.0.0.1:\(port)\(secondPath)")
        else {
            throw AudioRangeIntegrationFailure(
                stage: .fixtureStart,
                requestCount: 0,
                rangeCount: 0,
                payloadBytes: 0
            )
        }
        let sourceA = try audioRangePlaybackSource(
            url: originA,
            level: "lossless",
            format: "wav",
            data: wav
        )
        let sourceB = try audioRangePlaybackSource(
            url: originB,
            level: "lossless",
            format: "wav",
            data: wav
        )
        let key = TrackRangeCacheKey(songID: 33_001, quality: "lossless")
        let targetOffset = wav.count * 65 / 100
        var firstCacheReference: AudioRangeWeakBox<TrackRangeCache>?

        do {
            let firstRangeCache = TrackRangeCache(trackCache: trackCache) { request in
                try await session.download(for: request)
            }
            firstCacheReference = AudioRangeWeakBox(firstRangeCache)
            let providerCalls = AudioRangeLockedBox(0)
            let rangeSession = try await firstRangeCache.open(
                key: key,
                format: "wav",
                initialSource: sourceA,
                sourceProvider: {
                    providerCalls.withValue { $0 += 1 }
                    return sourceA
                }
            )
            let information = try await firstRangeCache.contentInfo(for: rangeSession)
            let header = try await firstRangeCache.read(
                session: rangeSession,
                offset: 0,
                maximumLength: 1
            )
            let target = try await firstRangeCache.read(
                session: rangeSession,
                offset: Int64(targetOffset),
                maximumLength: 1
            )
            #expect(information.contentLength == Int64(wav.count))
            #expect(header == wav.prefix(1))
            #expect(target == wav.subdata(in: targetOffset..<(targetOffset + 1)))
            #expect(providerCalls.withValue { $0 } == 0)
            await firstRangeCache.close(rangeSession)
        }

        try await waitForAudioRangeMetricsToStabilize(fixture: fixture, metrics: metrics)
        try await waitForAudioRangeCondition(
            stage: .requestValidation,
            fixture: fixture,
            metrics: metrics
        ) { firstCacheReference?.value == nil }
        let firstSnapshot = metrics.snapshot()
        guard let gapOffset = firstAudioRangeUntouchedBlock(in: firstSnapshot, length: wav.count),
              await trackCache.readyCachedFile(for: key.songID, quality: key.quality) == nil
        else {
            throw AudioRangeIntegrationFailure(
                stage: .platformLimit,
                requestCount: firstSnapshot.requests.count,
                rangeCount: firstSnapshot.rangeCount,
                payloadBytes: fixture.responsePayloadBytes
            )
        }

        fixture.resetRequests()
        metrics.reset()
        let secondRangeCache = TrackRangeCache(trackCache: trackCache) { request in
            try await session.download(for: request)
        }
        #expect(await secondRangeCache.descriptor(for: key) != nil)
        let providerCalls = AudioRangeLockedBox(0)
        let provider: TrackRangeCache.SourceProvider = {
            providerCalls.withValue { $0 += 1 }
            return sourceB
        }
        let rangeSession = try await secondRangeCache.open(
            key: key,
            format: "wav",
            initialSource: nil,
            sourceProvider: provider
        )
        let information = try await secondRangeCache.contentInfo(for: rangeSession)
        let header = try await secondRangeCache.read(
            session: rangeSession,
            offset: 0,
            maximumLength: 1
        )
        let target = try await secondRangeCache.read(
            session: rangeSession,
            offset: Int64(targetOffset),
            maximumLength: 1
        )
        #expect(information.contentLength == Int64(wav.count))
        #expect(header == wav.prefix(1))
        #expect(target == wav.subdata(in: targetOffset..<(targetOffset + 1)))
        #expect(providerCalls.withValue { $0 } == 0)
        #expect(metrics.snapshot().requests.isEmpty)
        #expect(fixture.responsePayloadBytes == 0)

        let gapData = try await secondRangeCache.read(
            session: rangeSession,
            offset: Int64(gapOffset),
            maximumLength: 1
        )
        await secondRangeCache.close(rangeSession)
        #expect(gapData == wav.subdata(in: gapOffset..<(gapOffset + 1)))
        try await waitForAudioRangeMetricsToStabilize(fixture: fixture, metrics: metrics)

        let gapSnapshot = metrics.snapshot()
        let oldRanges = firstSnapshot.requests.compactMap(\.range)
        let retransmittedOldRange = gapSnapshot.requests.compactMap(\.range).contains { fresh in
            oldRanges.contains {
                max($0.lowerBound, fresh.lowerBound) < min($0.upperBound, fresh.upperBound)
            }
        }
        #expect(providerCalls.withValue { $0 } == 1)
        #expect(!gapSnapshot.requests.isEmpty)
        #expect(gapSnapshot.invalidRangeCount == 0)
        #expect(gapSnapshot.rangeCount == gapSnapshot.requests.count)
        #expect(gapSnapshot.requests.allSatisfy { $0.endpointID == 2 })
        #expect(gapSnapshot.requests.allSatisfy { !$0.hasIfRange })
        #expect(!retransmittedOldRange)
        #expect(fixture.responsePayloadBytes > 0)
    }

    @Test("I03 no-digest partial and strong ETag remain URL scoped")
    func transientStrongETagDoesNotCrossURLs() async throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "TinyCloudMusic-W11-I03-transient-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let wav = audioRangeWAV(seconds: 60)
        let metrics = AudioRangeHTTPMetrics()
        let secondPath = "/i03-transient-b.wav"
        let fixture = try LocalHTTPFixture(response: { request in
            let endpointID = audioRangeEndpointID(for: request, secondPath: secondPath)
            return audioRangeHTTPResponse(
                for: request,
                body: wav,
                contentType: "audio/wav",
                metrics: metrics,
                endpointID: endpointID,
                strongETag: "\"i03-shared\""
            )
        })
        let session = audioRangeURLSession()
        let trackCache = TrackCache(directory: root.appending(path: "StreamCache"))
        let rangeCache = TrackRangeCache(trackCache: trackCache) { request in
            try await session.download(for: request)
        }
        defer {
            session.invalidateAndCancel()
            fixture.stop()
            try? FileManager.default.removeItem(at: root)
        }

        let port = try await startAudioRangeFixture(fixture)
        guard let originA = URL(string: "http://127.0.0.1:\(port)/i03-transient-a.wav"),
              let originB = URL(string: "http://127.0.0.1:\(port)\(secondPath)")
        else {
            throw AudioRangeIntegrationFailure(
                stage: .fixtureStart,
                requestCount: 0,
                rangeCount: 0,
                payloadBytes: 0
            )
        }
        let sourceA = PlaybackSource(
            url: originA,
            availability: .playable(level: "lossless"),
            format: "wav"
        )
        let sourceB = PlaybackSource(
            url: originB,
            availability: .playable(level: "lossless"),
            format: "wav"
        )
        let key = TrackRangeCacheKey(songID: 33_002, quality: "lossless")
        let firstProviderCalls = AudioRangeLockedBox(0)
        let firstSession = try await rangeCache.open(
            key: key,
            format: "wav",
            initialSource: sourceA,
            sourceProvider: {
                firstProviderCalls.withValue { $0 += 1 }
                return sourceA
            }
        )
        _ = try await rangeCache.contentInfo(for: firstSession)
        let firstByte = try await rangeCache.read(
            session: firstSession,
            offset: 0,
            maximumLength: 1
        )
        try await waitForAudioRangeMetricsToStabilize(fixture: fixture, metrics: metrics)
        let firstSnapshot = metrics.snapshot()
        #expect(firstByte == wav.prefix(1))
        #expect(firstProviderCalls.withValue { $0 } == 0)
        #expect(!firstSnapshot.requests.isEmpty)
        #expect(firstSnapshot.requests.allSatisfy { $0.endpointID == 1 })
        #expect(firstSnapshot.requests.first?.hasIfRange == false)
        #expect(await rangeCache.descriptor(for: key) == nil)
        guard await trackCache.readyCachedFile(for: key.songID, quality: key.quality) == nil,
              audioRangeBodyCount(in: root) > 0
        else {
            throw AudioRangeIntegrationFailure(
                stage: .platformLimit,
                requestCount: firstSnapshot.requests.count,
                rangeCount: firstSnapshot.rangeCount,
                payloadBytes: fixture.responsePayloadBytes
            )
        }
        await rangeCache.close(firstSession)

        try await waitForAudioRangeCondition(
            stage: .requestValidation,
            fixture: fixture,
            metrics: metrics
        ) { audioRangeBodyCount(in: root) == 0 }
        #expect(await rangeCache.descriptor(for: key) == nil)
        fixture.resetRequests()
        metrics.reset()

        let providerCalls = AudioRangeLockedBox(0)
        let secondSession = try await rangeCache.open(
            key: key,
            format: "wav",
            initialSource: nil,
            sourceProvider: {
                providerCalls.withValue { $0 += 1 }
                return sourceB
            }
        )
        _ = try await rangeCache.contentInfo(for: secondSession)
        let secondByte = try await rangeCache.read(
            session: secondSession,
            offset: 0,
            maximumLength: 1
        )
        await rangeCache.close(secondSession)
        try await waitForAudioRangeMetricsToStabilize(fixture: fixture, metrics: metrics)
        let secondSnapshot = metrics.snapshot()
        #expect(secondByte == wav.prefix(1))
        #expect(providerCalls.withValue { $0 } == 1)
        #expect(!secondSnapshot.requests.isEmpty)
        #expect(secondSnapshot.requests.allSatisfy { $0.endpointID == 2 })
        #expect(secondSnapshot.requests.first?.hasIfRange == false)
        #expect(fixture.responsePayloadBytes > 0)
        #expect(await rangeCache.descriptor(for: key) == nil)
    }

    @Test("I04 cached bytes survive one exact-identity URL refresh")
    func partialSurvivesExpiredURLRefresh() async throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "TinyCloudMusic-W11-I04-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let audio = try generateAudio(in: root)
        let metrics = AudioRangeHTTPMetrics()
        let requestNumber = AudioRangeLockedBox(0)
        let secondPath = "/i04-b.flac"
        let fixture = try LocalHTTPFixture(response: { request in
            let endpointID = audioRangeEndpointID(for: request, secondPath: secondPath)
            let number = requestNumber.withValue {
                $0 += 1
                return $0
            }
            if endpointID == 1, number > 1 {
                _ = audioRangeHTTPResponse(
                    for: request,
                    body: audio.flacData,
                    contentType: "audio/flac",
                    metrics: metrics,
                    endpointID: endpointID,
                    strongETag: "\"i04-a\""
                )
                return fixtureHTTPResponse("403 Forbidden")
            }
            return audioRangeHTTPResponse(
                for: request,
                body: audio.flacData,
                contentType: "audio/flac",
                metrics: metrics,
                endpointID: endpointID,
                strongETag: endpointID == 2 ? "\"i04-b\"" : "\"i04-a\""
            )
        })
        let session = audioRangeURLSession()
        let trackCache = TrackCache(directory: root.appending(path: "StreamCache"))
        let rangeCache = TrackRangeCache(trackCache: trackCache) { request in
            try await session.download(for: request)
        }
        var player: AVPlayer?
        var rangeItem: RangeCachingPlayerItem?
        defer {
            if let player { tearDownAudioRangePlayer(player, rangeItem: rangeItem) }
            session.invalidateAndCancel()
            fixture.stop()
            try? FileManager.default.removeItem(at: root)
        }

        let port = try await startAudioRangeFixture(fixture)
        guard let originA = URL(string: "http://127.0.0.1:\(port)/i04-a.flac"),
              let originB = URL(string: "http://127.0.0.1:\(port)\(secondPath)")
        else {
            throw AudioRangeIntegrationFailure(
                stage: .fixtureStart,
                requestCount: 0,
                rangeCount: 0,
                payloadBytes: 0
            )
        }
        let sourceA = try audioRangePlaybackSource(
            url: originA,
            level: "lossless",
            format: "flac",
            data: audio.flacData
        )
        let sourceB = try audioRangePlaybackSource(
            url: originB,
            level: "lossless",
            format: "flac",
            data: audio.flacData
        )
        let key = TrackRangeCacheKey(songID: 44_001, quality: "lossless")
        let seedSession = try await rangeCache.open(
            key: key,
            format: "flac",
            initialSource: sourceA,
            sourceProvider: { sourceA }
        )
        let seed = try await rangeCache.read(session: seedSession, offset: 0, maximumLength: 1)
        #expect(seed == audio.flacData.prefix(1))
        try await waitForAudioRangeMetricsToStabilize(fixture: fixture, metrics: metrics)
        let seedSnapshot = metrics.snapshot()
        #expect(seedSnapshot.requests.count == 1)
        #expect(await rangeCache.descriptor(for: key) != nil)

        fixture.resetRequests()
        metrics.reset()
        let providerCalls = AudioRangeLockedBox(0)
        let item = RangeCachingPlayerItem(
            key: key,
            format: "flac",
            initialSource: nil,
            sourceProvider: {
                providerCalls.withValue { $0 += 1 }
                return sourceB
            },
            rangeCache: rangeCache,
            preferPreciseTiming: true
        )
        rangeItem = item
        let avPlayer = AVPlayer(playerItem: item)
        avPlayer.automaticallyWaitsToMinimizeStalling = false
        player = avPlayer

        try await waitForAudioRangeReady(item, fixture: fixture, metrics: metrics)
        let target = audio.duration * 0.65
        let actual = try await seekAudioRangePlayer(
            avPlayer,
            to: target,
            fixture: fixture,
            metrics: metrics
        )
        #expect(actual.isFinite && abs(actual - target) <= 0.15)
        try await waitForAudioRangeMetricsToStabilize(fixture: fixture, metrics: metrics)

        let snapshot = metrics.snapshot()
        let oldRanges = seedSnapshot.requests.compactMap(\.range)
        let refreshedRanges = snapshot.requests.filter { $0.endpointID == 2 }.compactMap(\.range)
        let retransmittedSeed = refreshedRanges.contains { fresh in
            oldRanges.contains {
                max($0.lowerBound, fresh.lowerBound) < min($0.upperBound, fresh.upperBound)
            }
        }
        #expect(item.status == .readyToPlay)
        #expect(providerCalls.withValue { $0 } == 1)
        #expect(snapshot.requests.first?.endpointID == 1)
        #expect(snapshot.requests.contains { $0.endpointID == 2 })
        #expect(snapshot.requests.first(where: { $0.endpointID == 2 })?.hasIfRange == false)
        #expect(!retransmittedSeed)
        await rangeCache.close(seedSession)
    }

    @Test("I05 a complete 200 never splices into published partial bytes")
    func completeResponseBranches() async throws {
        let mediaRoot = FileManager.default.temporaryDirectory.appending(
            path: "TinyCloudMusic-W11-I05-media-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: mediaRoot, withIntermediateDirectories: true)
        let audio = try generateAudio(in: mediaRoot)
        defer { try? FileManager.default.removeItem(at: mediaRoot) }

        for (index, branch) in AudioRangeIgnoreRangeBranch.allCases.enumerated() {
            let root = mediaRoot.appending(
                path: branch.rawValue,
                directoryHint: .isDirectory
            )
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let completeBody: Data = {
                var body = audio.flacData
                if branch == .mismatchedIdentity {
                    let changedIndex = body.index(
                        body.startIndex,
                        offsetBy: body.count / 2
                    )
                    body[changedIndex] ^= 1
                }
                return body
            }()

            let metrics = AudioRangeHTTPMetrics()
            let requestNumber = AudioRangeLockedBox(0)
            let completeResponses = AudioRangeLockedBox(0)
            let fixture = try LocalHTTPFixture(response: { request in
                let number = requestNumber.withValue {
                    $0 += 1
                    return $0
                }
                if number == 1 {
                    return audioRangeHTTPResponse(
                        for: request,
                        body: audio.flacData,
                        contentType: "audio/flac",
                        metrics: metrics,
                        strongETag: branch == .transientPublished ? "\"i05-v1\"" : nil
                    )
                }
                _ = audioRangeHTTPResponse(
                    for: request,
                    body: audio.flacData,
                    contentType: "audio/flac",
                    metrics: metrics
                )
                completeResponses.withValue { $0 += 1 }
                return fixtureHTTPResponse(
                    "200 OK",
                    headers: ["Content-Type": "audio/flac"],
                    body: completeBody
                )
            })
            let session = audioRangeURLSession()
            let trackCache = TrackCache(directory: root.appending(path: "StreamCache"))
            let rangeCache = TrackRangeCache(trackCache: trackCache) { request in
                try await session.download(for: request)
            }
            var player: AVPlayer?
            var rangeItem: RangeCachingPlayerItem?
            defer {
                if let player { tearDownAudioRangePlayer(player, rangeItem: rangeItem) }
                session.invalidateAndCancel()
                fixture.stop()
            }

            let port = try await startAudioRangeFixture(fixture)
            guard let origin = URL(string: "http://127.0.0.1:\(port)/i05.flac") else {
                throw AudioRangeIntegrationFailure(
                    stage: .fixtureStart,
                    requestCount: 0,
                    rangeCount: 0,
                    payloadBytes: 0
                )
            }
            let source: PlaybackSource
            if branch == .transientPublished {
                source = PlaybackSource(
                    url: origin,
                    availability: .playable(level: "lossless"),
                    format: "flac"
                )
            } else {
                source = try audioRangePlaybackSource(
                    url: origin,
                    level: "lossless",
                    format: "flac",
                    data: audio.flacData
                )
            }
            let key = TrackRangeCacheKey(
                songID: 55_001 + Int64(index),
                quality: "lossless"
            )
            let providerCalls = AudioRangeLockedBox(0)
            let item = RangeCachingPlayerItem(
                key: key,
                format: "flac",
                initialSource: source,
                sourceProvider: {
                    providerCalls.withValue { $0 += 1 }
                    return source
                },
                rangeCache: rangeCache,
                preferPreciseTiming: true
            )
            rangeItem = item
            let avPlayer = AVPlayer(playerItem: item)
            avPlayer.automaticallyWaitsToMinimizeStalling = false
            player = avPlayer
            let target = audio.duration * 0.65

            if branch == .matchingIdentity {
                try await waitForAudioRangeReady(item, fixture: fixture, metrics: metrics)
                let actual = try await seekAudioRangePlayer(
                    avPlayer,
                    to: target,
                    fixture: fixture,
                    metrics: metrics
                )
                #expect(actual.isFinite && abs(actual - target) <= 0.15)
            } else {
                try await waitForAudioRangeCondition(
                    stage: .ready,
                    fixture: fixture,
                    metrics: metrics
                ) { item.status != .unknown }
                if item.status == .readyToPlay {
                    let completion = AudioRangeBoolCompletion()
                    avPlayer.seek(
                        to: CMTime(seconds: target, preferredTimescale: 44_100),
                        toleranceBefore: CMTime(seconds: 0.1, preferredTimescale: 1_000),
                        toleranceAfter: CMTime(seconds: 0.1, preferredTimescale: 1_000)
                    ) { completion.finish($0) }
                    try await waitForAudioRangeCondition(
                        stage: .seek,
                        fixture: fixture,
                        metrics: metrics
                    ) { item.status == .failed }
                }
                #expect(item.status == .failed)
            }

            try await waitForAudioRangeMetricsToStabilize(fixture: fixture, metrics: metrics)
            let snapshot = metrics.snapshot()
            #expect(providerCalls.withValue { $0 } == 0)
            #expect(completeResponses.withValue { $0 } == 1)
            #expect(snapshot.requests.count == 2)
            #expect(fixture.responsePayloadBytes >= audio.flacData.count)
            #expect(fixture.responsePayloadBytes <= audio.flacData.count + audioRangeBlockSize)

            let full = await trackCache.readyCachedFile(
                for: key.songID,
                quality: key.quality
            )
            if branch == .mismatchedIdentity {
                #expect(full == nil)
                #expect(await rangeCache.descriptor(for: key) == nil)
                continue
            }

            let fullURL = try #require(full?.url)
            tearDownAudioRangePlayer(avPlayer, rangeItem: item)
            player = nil
            rangeItem = nil
            try await waitForAudioRangeMetricsToStabilize(fixture: fixture, metrics: metrics)
            fixture.resetRequests()
            metrics.reset()

            let directItem = AVPlayerItem(asset: AVURLAsset(
                url: fullURL,
                options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
            ))
            let directPlayer = AVPlayer(playerItem: directItem)
            directPlayer.automaticallyWaitsToMinimizeStalling = false
            player = directPlayer
            try await waitForAudioRangeReady(directItem)
            let actual = try await seekAudioRangePlayer(directPlayer, to: target)
            #expect(actual.isFinite && abs(actual - target) <= 0.15)
            try await waitForAudioRangeMetricsToStabilize(fixture: fixture, metrics: metrics)
            #expect(metrics.snapshot().requests.isEmpty)
            #expect(fixture.responsePayloadBytes == 0)
            if branch == .transientPublished {
                #expect(await rangeCache.descriptor(for: key) == nil)
            }
        }
    }

    @Test("I06 416 records EOF once and rejects a stale known length")
    func unsatisfiedRangeBoundaries() async throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "TinyCloudMusic-W11-I06-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let audio = try generateAudio(in: root)
        defer { try? FileManager.default.removeItem(at: root) }

        do {
            let metrics = AudioRangeHTTPMetrics()
            let fixture = try LocalHTTPFixture(response: { request in
                _ = audioRangeHTTPResponse(
                    for: request,
                    body: audio.flacData,
                    contentType: "audio/flac",
                    metrics: metrics
                )
                return fixtureHTTPResponse(
                    "416 Range Not Satisfiable",
                    headers: ["Content-Range": "bytes */\(audio.flacData.count)"]
                )
            })
            let session = audioRangeURLSession()
            defer {
                session.invalidateAndCancel()
                fixture.stop()
            }
            let port = try await startAudioRangeFixture(fixture)
            guard let origin = URL(string: "http://127.0.0.1:\(port)/i06-eof.flac") else {
                throw AudioRangeIntegrationFailure(
                    stage: .fixtureStart,
                    requestCount: 0,
                    rangeCount: 0,
                    payloadBytes: 0
                )
            }
            let source = PlaybackSource(
                url: origin,
                availability: .playable(level: "lossless"),
                format: "flac"
            )
            let cache = TrackRangeCache(
                trackCache: TrackCache(directory: root.appending(path: "EOFCache"))
            ) { request in
                try await session.download(for: request)
            }
            let key = TrackRangeCacheKey(songID: 66_001, quality: "lossless")
            let rangeSession = try await cache.open(
                key: key,
                format: "flac",
                initialSource: source,
                sourceProvider: { source }
            )
            let offset = Int64(audio.flacData.count + 100)
            #expect(try await cache.read(
                session: rangeSession,
                offset: offset,
                maximumLength: 1
            ).isEmpty)
            #expect(try await cache.read(
                session: rangeSession,
                offset: offset,
                maximumLength: 1
            ).isEmpty)
            try await waitForAudioRangeMetricsToStabilize(fixture: fixture, metrics: metrics)
            #expect(metrics.snapshot().requests.count == 1)
            #expect(metrics.snapshot().rangeCount == 1)
            await cache.close(rangeSession)
        }

        do {
            let advertisedBody = audio.flacData
            let actualBody = Data(advertisedBody.dropLast())
            let metrics = AudioRangeHTTPMetrics()
            let fixture = try LocalHTTPFixture(response: { request in
                audioRangeHTTPResponse(
                    for: request,
                    body: actualBody,
                    contentType: "audio/flac",
                    metrics: metrics
                )
            })
            let session = audioRangeURLSession()
            defer {
                session.invalidateAndCancel()
                fixture.stop()
            }
            let port = try await startAudioRangeFixture(fixture)
            guard let origin = URL(string: "http://127.0.0.1:\(port)/i06-mismatch.flac") else {
                throw AudioRangeIntegrationFailure(
                    stage: .fixtureStart,
                    requestCount: 0,
                    rangeCount: 0,
                    payloadBytes: 0
                )
            }
            let source = try audioRangePlaybackSource(
                url: origin,
                level: "lossless",
                format: "flac",
                data: advertisedBody
            )
            let cache = TrackRangeCache(
                trackCache: TrackCache(directory: root.appending(path: "MismatchCache"))
            ) { request in
                try await session.download(for: request)
            }
            let key = TrackRangeCacheKey(songID: 66_002, quality: "lossless")
            let rangeSession = try await cache.open(
                key: key,
                format: "flac",
                initialSource: source,
                sourceProvider: { source }
            )
            let offset = Int64(actualBody.count)
            await expectAudioRangeError(.inconsistentRepresentation) {
                _ = try await cache.read(
                    session: rangeSession,
                    offset: offset,
                    maximumLength: 1
                )
            }
            await expectAudioRangeError(.inconsistentRepresentation) {
                _ = try await cache.read(
                    session: rangeSession,
                    offset: offset,
                    maximumLength: 1
                )
            }
            try await waitForAudioRangeMetricsToStabilize(fixture: fixture, metrics: metrics)
            #expect(metrics.snapshot().requests.count == 1)
            #expect(await cache.descriptor(for: key) == nil)
            await cache.close(rangeSession)
        }
    }

    @Test("I07 a newer seek cancels the old uncommitted Range response")
    func cancelledSeekDoesNotPublishOldRange() async throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "TinyCloudMusic-W11-I07-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let audio = try generateAudio(in: root)
        let metrics = AudioRangeHTTPMetrics()
        let fixture = try LocalHTTPFixture(response: { request in
            audioRangeHTTPResponse(
                for: request,
                body: audio.flacData,
                contentType: "audio/flac",
                metrics: metrics
            )
        })
        let session = audioRangeURLSession()
        let gate = AudioRangeResponseGate()
        let gateState = AudioRangeLockedBox(AudioRangeGateState())
        let trackCache = TrackCache(directory: root.appending(path: "StreamCache"))
        let rangeCache = TrackRangeCache(trackCache: trackCache) { request in
            let downloaded = try await session.download(for: request)
            let requestedRange = request.value(forHTTPHeaderField: "Range")
                .flatMap { parseAudioByteRange($0, length: audio.flacData.count) }
            let shouldGate = gateState.withValue {
                guard $0.isEnabled, !$0.didGate else { return false }
                $0.didGate = true
                $0.gatedRange = requestedRange
                return true
            }
            if shouldGate { try await gate.wait() }
            return downloaded
        }
        let providerCalls = AudioRangeLockedBox(0)
        defer {
            session.invalidateAndCancel()
            fixture.stop()
            try? FileManager.default.removeItem(at: root)
        }

        let port = try await startAudioRangeFixture(fixture)
        guard let origin = URL(string: "http://127.0.0.1:\(port)/i07.flac") else {
            throw AudioRangeIntegrationFailure(
                stage: .fixtureStart,
                requestCount: 0,
                rangeCount: 0,
                payloadBytes: 0
            )
        }
        let source = try audioRangePlaybackSource(
            url: origin,
            level: "lossless",
            format: "flac",
            data: audio.flacData
        )
        let key = TrackRangeCacheKey(songID: 77_001, quality: "lossless")
        let rangeSession = try await rangeCache.open(
            key: key,
            format: "flac",
            initialSource: source,
            sourceProvider: {
                providerCalls.withValue { $0 += 1 }
                return source
            }
        )
        #expect(try await rangeCache.read(
            session: rangeSession,
            offset: 0,
            maximumLength: 1
        ) == audio.flacData.prefix(1))
        try await waitForAudioRangeMetricsToStabilize(fixture: fixture, metrics: metrics)
        fixture.resetRequests()
        metrics.reset()
        gateState.withValue { $0.isEnabled = true }

        let oldOffset = audioRangeBlockSize + 1_024
        let newOffset = audioRangeBlockSize * 3 + 1_024
        let oldRead = Task {
            try await rangeCache.read(
                session: rangeSession,
                offset: Int64(oldOffset),
                maximumLength: 1
            )
        }
        try await waitForAudioRangeCondition(
            stage: .seek,
            fixture: fixture,
            metrics: metrics
        ) { await gate.hasEntered() }

        oldRead.cancel()
        try await waitForAudioRangeCondition(
            stage: .seek,
            fixture: fixture,
            metrics: metrics
        ) { await gate.cancellations == 1 }
        await expectAudioRangeCancellation { _ = try await oldRead.value }
        await gate.release()
        let newData = try await rangeCache.read(
            session: rangeSession,
            offset: Int64(newOffset),
            maximumLength: 1
        )
        #expect(newData == audio.flacData.subdata(in: newOffset..<(newOffset + 1)))
        #expect(providerCalls.withValue { $0 } == 0)
        try await waitForAudioRangeMetricsToStabilize(fixture: fixture, metrics: metrics)

        guard let gatedRange = gateState.withValue({ $0.gatedRange }) else {
            throw AudioRangeIntegrationFailure(
                stage: .requestValidation,
                requestCount: metrics.snapshot().requests.count,
                rangeCount: metrics.snapshot().rangeCount,
                payloadBytes: fixture.responsePayloadBytes
            )
        }
        fixture.resetRequests()
        metrics.reset()
        let verifiedByte = try await rangeCache.read(
            session: rangeSession,
            offset: Int64(gatedRange.lowerBound),
            maximumLength: 1
        )
        #expect(verifiedByte == audio.flacData.subdata(
            in: gatedRange.lowerBound..<(gatedRange.lowerBound + 1)
        ))
        try await waitForAudioRangeMetricsToStabilize(fixture: fixture, metrics: metrics)
        #expect(!metrics.snapshot().requests.isEmpty)
        #expect(fixture.responsePayloadBytes > 0)
        await rangeCache.close(rangeSession)
    }

    @Test("I08 seeks during a FLAC quality switch reuse one standby and one origin path")
    func seekDuringQualitySwitch() async throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "TinyCloudMusic-W11-I08-media-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let audio = try generateAudio(in: root)
        let metrics = AudioRangeHTTPMetrics()
        let fixture = try LocalHTTPFixture(
            response: { request in
                audioRangeHTTPResponse(
                    for: request,
                    body: audio.flacData,
                    contentType: "audio/flac",
                    metrics: metrics
                )
            },
            initialResponseDelay: .milliseconds(150),
            sendChunkSize: 64 * 1_024,
            sendChunkDelay: .milliseconds(12)
        )
        defer {
            fixture.stop()
            try? FileManager.default.removeItem(at: root)
        }
        let port = try await startAudioRangeFixture(fixture)
        guard let origin = URL(string: "http://127.0.0.1:\(port)/i08.flac") else {
            throw AudioRangeIntegrationFailure(
                stage: .fixtureStart,
                requestCount: 0,
                rangeCount: 0,
                payloadBytes: 0
            )
        }

        let gated = try await runAudioRangeQualitySwitchTrial(
            branch: .custom,
            audio: audio,
            origin: origin,
            fixture: fixture,
            metrics: metrics,
            run: 0,
            gatedSeeks: true
        )
        #expect(gated.readyPayloadBytes <= gated.seekPayloadBytes)
        #expect(gated.seekPayloadBytes <= gated.prerollPayloadBytes)
        #expect(gated.prerollPayloadBytes <= gated.promotePayloadBytes)
        #expect(gated.positionError <= 0.15)
        fixture.resetRequests()
        metrics.reset()

        var runs: [AudioRangeQualityBranch: [AudioRangeQualityMetric]] = [:]
        var runID = 1
        for branch in AudioRangeQualityBranch.allCases {
            _ = try await runAudioRangeQualitySwitchTrial(
                branch: branch,
                audio: audio,
                origin: origin,
                fixture: fixture,
                metrics: metrics,
                run: runID
            )
            runID += 1
            fixture.resetRequests()
            metrics.reset()
            for _ in 0..<5 {
                runs[branch, default: []].append(try await runAudioRangeQualitySwitchTrial(
                    branch: branch,
                    audio: audio,
                    origin: origin,
                    fixture: fixture,
                    metrics: metrics,
                    run: runID
                ))
                runID += 1
                fixture.resetRequests()
                metrics.reset()
            }
        }

        let direct = try #require(runs[.direct])
        let custom = try #require(runs[.custom])
        #expect(direct.count == 5)
        #expect(custom.count == 5)
        for (directRun, customRun) in zip(direct, custom) {
            #expect(customRun.promotePayloadBytes <= directRun.promotePayloadBytes + audioRangeBlockSize)
            #expect(customRun.duplicatePayloadBytes < audioRangeBlockSize)
            #expect(customRun.positionError <= 0.15)
        }
        let directMedian = audioRangeMedian(direct.map(\.promoteSeconds))
        let customMedian = audioRangeMedian(custom.map(\.promoteSeconds))
        #if DEBUG
        print(
            "W11 I08 configuration=debug runs=5 "
                + String(format: "directMedianMs=%.1f ", directMedian * 1_000)
                + String(format: "customMedianMs=%.1f ", customMedian * 1_000)
                + "directBytesRange=\(audioRangeMetricRange(direct.map(\.promotePayloadBytes))) "
                + "customBytesRange=\(audioRangeMetricRange(custom.map(\.promotePayloadBytes)))"
        )
        #else
        print(
            "W11 I08 configuration=release runs=5 "
                + String(format: "directMedianMs=%.1f ", directMedian * 1_000)
                + String(format: "customMedianMs=%.1f ", customMedian * 1_000)
                + "directRangeMs=\(audioRangeMetricRange(direct.map(\.promoteSeconds), scale: 1_000)) "
                + "customRangeMs=\(audioRangeMetricRange(custom.map(\.promoteSeconds), scale: 1_000))"
        )
        #expect(customMedian - directMedian <= max(0.25, directMedian * 0.25))
        #endif
    }

    @Test("I09 clear retires active bytes and a new root stays isolated")
    func clearAndConfigureRoots() async throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "TinyCloudMusic-W11-I09-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let audio = try generateAudio(in: root)
        let metrics = AudioRangeHTTPMetrics()
        let fixture = try LocalHTTPFixture(response: { request in
            audioRangeHTTPResponse(
                for: request,
                body: audio.flacData,
                contentType: "audio/flac",
                metrics: metrics
            )
        })
        let networkSession = audioRangeURLSession()
        defer {
            networkSession.invalidateAndCancel()
            fixture.stop()
            try? FileManager.default.removeItem(at: root)
        }

        let port = try await startAudioRangeFixture(fixture)
        guard let origin = URL(string: "http://127.0.0.1:\(port)/i09.flac") else {
            throw AudioRangeIntegrationFailure(
                stage: .fixtureStart,
                requestCount: 0,
                rangeCount: 0,
                payloadBytes: 0
            )
        }
        let source = try audioRangePlaybackSource(
            url: origin,
            level: "lossless",
            format: "flac",
            data: audio.flacData
        )
        let key = TrackRangeCacheKey(songID: 99_001, quality: "lossless")
        let oldRoot = root.appending(path: "OldStreamCache")
        let oldCache = TrackRangeCache(trackCache: TrackCache(directory: oldRoot)) { request in
            try await networkSession.download(for: request)
        }
        let activeSession = try await oldCache.open(
            key: key,
            format: "flac",
            initialSource: source,
            sourceProvider: { source }
        )
        let firstByte = try await oldCache.read(
            session: activeSession,
            offset: 0,
            maximumLength: 1
        )
        #expect(firstByte == audio.flacData.prefix(1))
        try await waitForAudioRangeMetricsToStabilize(fixture: fixture, metrics: metrics)
        let bytesBeforeClear = fixture.responsePayloadBytes
        #expect(await oldCache.descriptor(for: key) != nil)
        #expect(audioRangeBodyCount(in: oldRoot) == 1)

        try await oldCache.clear()
        #expect(await oldCache.descriptor(for: key) == nil)
        #expect(try await oldCache.read(
            session: activeSession,
            offset: 0,
            maximumLength: 1
        ) == firstByte)
        #expect(fixture.responsePayloadBytes == bytesBeforeClear)
        #expect(audioRangeBodyCount(in: oldRoot) == 1)
        await oldCache.close(activeSession)
        try await waitForAudioRangeCondition(
            stage: .requestValidation,
            fixture: fixture,
            metrics: metrics
        ) { audioRangeBodyCount(in: oldRoot) == 0 }

        let newRoot = root.appending(path: "NewStreamCache")
        let newCache = TrackRangeCache(trackCache: TrackCache(directory: newRoot)) { request in
            try await networkSession.download(for: request)
        }
        let newSession = try await newCache.open(
            key: key,
            format: "flac",
            initialSource: source,
            sourceProvider: { source }
        )
        #expect(try await newCache.read(
            session: newSession,
            offset: 0,
            maximumLength: 1
        ) == firstByte)
        #expect(audioRangeBodyCount(in: oldRoot) == 0)
        #expect(audioRangeBodyCount(in: newRoot) == 1)
        await newCache.close(newSession)

        let controllerOldRoot = root.appending(path: "ControllerOldStreamCache")
        let controllerTrackCache = TrackCache(directory: controllerOldRoot)
        let controllerRangeCache = TrackRangeCache(trackCache: controllerTrackCache) { request in
            try await networkSession.download(for: request)
        }
        let controllerSource = try audioRangePlaybackSource(
            url: origin,
            level: "standard",
            format: "flac",
            data: audio.flacData
        )
        let song = audioRangeSong(99_002, duration: audio.duration)
        let repository = AudioRangePlayerRepository(
            song: song,
            levelSources: ["standard": [controllerSource]]
        )
        let controller = PlayerController(
            repository: repository,
            cache: controllerTrackCache,
            crossfadeDuration: 0,
            rangeCache: controllerRangeCache
        )
        func isOwned(_ item: AVPlayerItem?, by cache: TrackCache) -> Bool {
            guard let item else { return false }
            if let item = item as? RangeCachingPlayerItem {
                return item.rangeCache.trackCache === cache
            }
            guard let url = (item.asset as? AVURLAsset)?.url, url.isFileURL else { return false }
            return cache.manages(url)
        }
        controller.play(song, in: [song])
        try await waitForAudioRangeCondition(
            stage: .ready,
            fixture: fixture,
            metrics: metrics
        ) {
            let item = audioRangeAVPlayer(controller, named: "avPlayer")?.currentItem
            return item?.status == .readyToPlay && isOwned(item, by: controllerTrackCache)
        }
        let activePlayer = try #require(audioRangeAVPlayer(controller, named: "avPlayer"))
        #expect(isOwned(activePlayer.currentItem, by: controllerTrackCache))
        #expect(await repository.levelRequests() == ["standard"])
        controller.setPlayback(false)
        let controllerNewRoot = root.appending(path: "ControllerNewRoot")
        let controllerNewTrackCache = TrackCache.shared(
            directory: controllerNewRoot.appending(path: "StreamCache")
        )
        controller.configure(playbackQuality: .standard, cacheRoot: controllerNewRoot)
        try await controller.clearCache()
        try await waitForAudioRangeCondition(
            stage: .ready,
            fixture: fixture,
            metrics: metrics
        ) {
            let item = activePlayer.currentItem
            return item?.status == .readyToPlay
                && (isOwned(item, by: controllerTrackCache)
                    || isOwned(item, by: controllerNewTrackCache))
        }
        #expect(await controllerTrackCache.readyFile(
            for: song.id,
            quality: "standard"
        ) == nil)
        #expect(await controllerRangeCache.descriptor(for: TrackRangeCacheKey(
            songID: song.id,
            quality: "standard"
        )) == nil)

        if !isOwned(activePlayer.currentItem, by: controllerNewTrackCache) {
            controller.retryPlayback()
        }
        try await waitForAudioRangeCondition(
            stage: .ready,
            fixture: fixture,
            metrics: metrics
        ) {
            let item = activePlayer.currentItem
            return item?.status == .readyToPlay && isOwned(item, by: controllerNewTrackCache)
        }
        #expect(isOwned(activePlayer.currentItem, by: controllerNewTrackCache))
        #expect(await repository.levelRequests() == ["standard", "standard"])
        controller.setPlayback(false)
        for avPlayer in audioRangeAVPlayers(controller) {
            (avPlayer.currentItem as? RangeCachingPlayerItem)?.cancelRangeLoading()
            avPlayer.pause()
            avPlayer.replaceCurrentItem(with: nil)
        }
    }

    @Test("I10 sequential completion has no independent whole-file download")
    func sequentialCompletionUsesOneOriginRepresentation() async throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "TinyCloudMusic-W11-I10-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let audio = try generateAudio(in: root)
        let metrics = AudioRangeHTTPMetrics()
        let fixture = try LocalHTTPFixture(response: { request in
            audioRangeHTTPResponse(
                for: request,
                body: audio.flacData,
                contentType: "audio/flac",
                metrics: metrics
            )
        })
        let networkSession = audioRangeURLSession()
        let wholeFileDownloads = AudioRangeLockedBox(0)
        let trackCache = TrackCache(directory: root.appending(path: "StreamCache"), download: { _ in
            wholeFileDownloads.withValue { $0 += 1 }
            throw URLError(.unsupportedURL)
        })
        let rangeCache = TrackRangeCache(trackCache: trackCache) { request in
            try await networkSession.download(for: request)
        }
        defer {
            networkSession.invalidateAndCancel()
            fixture.stop()
            try? FileManager.default.removeItem(at: root)
        }

        let port = try await startAudioRangeFixture(fixture)
        guard let origin = URL(string: "http://127.0.0.1:\(port)/i10.flac") else {
            throw AudioRangeIntegrationFailure(
                stage: .fixtureStart,
                requestCount: 0,
                rangeCount: 0,
                payloadBytes: 0
            )
        }
        let source = try audioRangePlaybackSource(
            url: origin,
            level: "lossless",
            format: "flac",
            data: audio.flacData
        )
        let key = TrackRangeCacheKey(songID: 100_001, quality: "lossless")
        let rangeSession = try await rangeCache.open(
            key: key,
            format: "flac",
            initialSource: source,
            sourceProvider: { source }
        )
        var offset = 0
        while offset < audio.flacData.count {
            let data = try await rangeCache.read(
                session: rangeSession,
                offset: Int64(offset),
                maximumLength: 256 * 1_024
            )
            guard !data.isEmpty else {
                throw AudioRangeIntegrationFailure(
                    stage: .requestValidation,
                    requestCount: metrics.snapshot().requests.count,
                    rangeCount: metrics.snapshot().rangeCount,
                    payloadBytes: fixture.responsePayloadBytes
                )
            }
            offset += data.count
        }
        #expect(offset == audio.flacData.count)
        try await waitForAudioRangeCondition(
            stage: .requestValidation,
            fixture: fixture,
            metrics: metrics
        ) {
            await trackCache.readyCachedFile(for: key.songID, quality: key.quality) != nil
        }
        try await waitForAudioRangeMetricsToStabilize(fixture: fixture, metrics: metrics)
        let snapshot = metrics.snapshot()
        #expect(snapshot.invalidRangeCount == 0)
        #expect(snapshot.rangeCount == snapshot.requests.count)
        #expect(snapshot.duplicatePayloadBytes(
            fixturePayloadBytes: fixture.responsePayloadBytes
        ) == 0)
        #expect(snapshot.uniqueRangePayloadBytes == audio.flacData.count)
        #expect(fixture.responsePayloadBytes == audio.flacData.count)
        #expect(wholeFileDownloads.withValue { $0 } == 0)
        let settledRequests = snapshot.requests.count
        let settledBytes = fixture.responsePayloadBytes
        try await waitForAudioRangeMetricsToStabilize(fixture: fixture, metrics: metrics)
        #expect(metrics.snapshot().requests.count == settledRequests)
        #expect(fixture.responsePayloadBytes == settledBytes)
        await rangeCache.close(rangeSession)
    }

    @Test("I11 serialized 150ms RTT throughput stays above the Release gate")
    func serializedRTTThroughput() async throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "TinyCloudMusic-W11-I11-media-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let audio = try generateAudio(in: root)
        defer { try? FileManager.default.removeItem(at: root) }

        _ = try await runAudioRangeThroughputTrial(audio: audio, run: 0)
        var runs: [AudioRangeThroughputMetric] = []
        for run in 1...5 {
            runs.append(try await runAudioRangeThroughputTrial(audio: audio, run: run))
        }
        let throughputs = runs.map(\.bytesPerSecond)
        let median = audioRangeMedian(throughputs)
        #if DEBUG
        print(
            "W11 I11 configuration=debug runs=5 medianMiBps="
                + String(format: "%.3f", median / Double(1_024 * 1_024))
                + " payloadBytes=\(runs.first?.payloadBytes ?? 0)"
                + " requestRange=\(audioRangeMetricRange(runs.map(\.requestCount)))"
        )
        #else
        print(
            "W11 I11 configuration=release runs=5 medianMiBps="
                + String(format: "%.3f", median / Double(1_024 * 1_024))
                + " throughputRangeMiBps="
                + audioRangeMetricRange(
                    throughputs.map { $0 / Double(1_024 * 1_024) }
                )
                + " payloadBytes=\(runs.first?.payloadBytes ?? 0)"
                + " requestRange=\(audioRangeMetricRange(runs.map(\.requestCount)))"
        )
        #expect(median >= Double(2 * 1_024 * 1_024))
        #endif
    }

    @Test(
        "I12 an active Range failure resumes once through exact direct playback",
        arguments: AudioRangeFallbackScenario.allCases
    )
    func activeRangeFallbackResumesPosition(
        _ scenario: AudioRangeFallbackScenario
    ) async throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "TinyCloudMusic-W11-I12-\(scenario.rawValue)-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let duration = 60.0
        let wav = audioRangeWAV(seconds: 60)
        let metrics = AudioRangeHTTPMetrics()
        let failureGate = AudioRangeResponseGate()
        let failureLowerBound = audioRangeBlockSize * 16
        let firstHighRangeSeen = AudioRangeLockedBox(false)
        let directPath = "/i12-direct.wav"
        let fixture = try LocalHTTPFixture(
            response: { request in
                audioRangeHTTPResponse(
                    for: request,
                    body: wav,
                    contentType: "audio/wav",
                    metrics: metrics,
                    endpointID: audioRangeEndpointID(for: request, secondPath: directPath)
                )
            },
            initialResponseDelay: .milliseconds(150),
            sendChunkSize: 64 * 1_024,
            sendChunkDelay: .milliseconds(12)
        )
        let session = audioRangeURLSession()
        var player: PlayerController?
        defer {
            if let player {
                for avPlayer in audioRangeAVPlayers(player) {
                    (avPlayer.currentItem as? RangeCachingPlayerItem)?.cancelRangeLoading()
                    avPlayer.pause()
                    avPlayer.replaceCurrentItem(with: nil)
                }
            }
            session.invalidateAndCancel()
            fixture.stop()
            try? FileManager.default.removeItem(at: root)
        }
        let port = try await startAudioRangeFixture(fixture)
        guard let rangeURL = URL(string: "http://127.0.0.1:\(port)/i12-range.wav"),
              let directURL = URL(string: "http://127.0.0.1:\(port)\(directPath)")
        else {
            throw AudioRangeIntegrationFailure(
                stage: .fixtureStart,
                requestCount: 0,
                rangeCount: 0,
                payloadBytes: 0
            )
        }
        let rangeSource = try audioRangePlaybackSource(
            url: rangeURL,
            level: "standard",
            format: "wav",
            data: wav
        )
        let directSource = PlaybackSource(
            url: directURL,
            availability: .playable(level: "standard"),
            format: "wav"
        )
        let song = audioRangeSong(scenario.songID, duration: duration)
        let repository = AudioRangePlayerRepository(
            song: song,
            levelSources: ["standard": [rangeSource, directSource]]
        )
        let wholeFileDownloads = AudioRangeLockedBox(0)
        let trackCache = TrackCache(directory: root.appending(path: "StreamCache"), download: { _ in
            wholeFileDownloads.withValue { $0 += 1 }
            throw URLError(.unsupportedURL)
        })
        let failedRangeDownloads = AudioRangeLockedBox(0)
        let rangeCache = TrackRangeCache(trackCache: trackCache) { request in
            if let header = request.value(forHTTPHeaderField: "Range"),
               let range = parseAudioByteRange(header, length: wav.count),
               range.lowerBound >= failureLowerBound,
               firstHighRangeSeen.withValue({ seen in
                   defer { seen = true }
                   return seen
               })
            {
                try await failureGate.wait()
                failedRangeDownloads.withValue { $0 += 1 }
                throw URLError(.timedOut)
            }
            return try await session.download(for: request)
        }
        let controller = PlayerController(
            repository: repository,
            cache: trackCache,
            crossfadeDuration: 0,
            rangeCache: rangeCache
        )
        player = controller

        controller.play(song, in: [song])
        try await waitForAudioRangeCondition(
            stage: .play,
            fixture: fixture,
            metrics: metrics
        ) {
            controller.isPlaying
                && audioRangeAVPlayer(controller, named: "avPlayer")?.currentItem
                    is RangeCachingPlayerItem
        }
        let active = try #require(audioRangeAVPlayer(controller, named: "avPlayer"))
        let rangeItem = try #require(active.currentItem as? RangeCachingPlayerItem)
        let middle = duration * 0.25
        controller.seek(to: middle)
        try await waitForAudioRangeCondition(stage: .seek, fixture: fixture, metrics: metrics) {
            controller.pendingSeekPosition == nil
                && abs(active.currentTime().seconds - middle) <= 0.15
        }
        try await waitForAudioRangeCondition(
            stage: .requestValidation,
            fixture: fixture,
            metrics: metrics
        ) { await failureGate.hasEntered() }
        guard await trackCache.readyFile(for: song.id, quality: "standard") == nil else {
            throw AudioRangeIntegrationFailure(
                stage: .platformLimit,
                requestCount: metrics.snapshot().requests.count,
                rangeCount: metrics.snapshot().rangeCount,
                payloadBytes: fixture.responsePayloadBytes
            )
        }

        if scenario == .paused {
            controller.setPlayback(false)
            try await waitForAudioRangeCondition(
                stage: .play,
                fixture: fixture,
                metrics: metrics
            ) {
                !controller.isPlaybackRequested
                    && audioRangeAVPlayers(controller).allSatisfy { $0.rate == 0 }
            }
        }
        active.seek(
            to: CMTime(seconds: duration * 0.9, preferredTimescale: 600),
            toleranceBefore: CMTime(seconds: 0.1, preferredTimescale: 600),
            toleranceAfter: CMTime(seconds: 0.1, preferredTimescale: 600),
            completionHandler: { _ in }
        )
        #expect(controller.pendingSeekPosition == nil)
        await failureGate.release()
        try await waitForAudioRangeCondition(
            stage: .fallback,
            fixture: fixture,
            metrics: metrics
        ) {
            failedRangeDownloads.withValue { $0 } > 0
        }
        #expect(active.currentItem === rangeItem)
        NotificationCenter.default.post(
            name: .AVPlayerItemFailedToPlayToEndTime,
            object: rangeItem,
            userInfo: [AVPlayerItemFailedToPlayToEndTimeErrorKey: URLError(.timedOut)]
        )
        try await waitForAudioRangeCondition(
            stage: .fallback,
            fixture: fixture,
            metrics: metrics
        ) { await repository.levelRequests().count == 2 }
        try await waitForAudioRangeCondition(
            stage: .fallback,
            fixture: fixture,
            metrics: metrics
        ) {
            guard let item = active.currentItem else { return false }
            return item !== rangeItem && !(item is RangeCachingPlayerItem)
        }
        let directItem = try #require(active.currentItem)
        let fallback = try #require(audioRangeActiveFallbackSnapshot(controller))
        let changedTarget = duration * 0.75
        #expect(active.rate == 0)
        #expect(active.volume == 0)
        #expect(fallback.wantsPlayback == (scenario != .paused))
        if scenario == .changesWhileWaiting {
            controller.seek(to: changedTarget)
            controller.setPlayback(false)
        }
        let expectedPosition = scenario == .changesWhileWaiting
            ? changedTarget
            : fallback.position
        let expectsPlayback = scenario == .playing
        try await waitForAudioRangeCondition(
            stage: .fallback,
            fixture: fixture,
            metrics: metrics
        ) {
            directItem.status == .readyToPlay
                && controller.pendingSeekPosition == nil
                && abs(active.currentTime().seconds - expectedPosition) <= 0.15
                && !controller.isPreparing
                && controller.isPlaybackRequested == expectsPlayback
                && (!expectsPlayback || controller.isPlaying)
        }
        #expect(active.currentItem === directItem)
        #expect(!(directItem is RangeCachingPlayerItem))
        #expect(controller.isPlaybackRequested == expectsPlayback)
        if expectsPlayback {
            #expect(controller.state == .playing(songID: song.id))
            #expect(active.rate > 0)
            #expect(abs(active.volume - Float(controller.volume)) < 0.001)
        } else {
            #expect(controller.state == .paused(songID: song.id))
            #expect(audioRangeAVPlayers(controller).allSatisfy { $0.rate == 0 })
        }
        #expect(abs(controller.position - expectedPosition) <= 0.15)
        #expect(abs(controller.position - active.currentTime().seconds) <= 0.15)
        #expect(controller.displayedPosition == controller.position)
        #expect(controller.currentLyricIndex == 1)
        #expect(await repository.levelRequests() == ["standard", "standard"])
        #expect(wholeFileDownloads.withValue { $0 } == 0)
        try await waitForAudioRangeMetricsToStabilize(fixture: fixture, metrics: metrics)
        let finalSnapshot = metrics.snapshot()
        #expect(finalSnapshot.requests.contains { $0.endpointID == 2 })
        let settledRequests = finalSnapshot.requests.count
        let settledBytes = fixture.responsePayloadBytes
        try await waitForAudioRangeMetricsToStabilize(fixture: fixture, metrics: metrics)
        #expect(metrics.snapshot().requests.count == settledRequests)
        #expect(fixture.responsePayloadBytes == settledBytes)
    }

    @Test("I13 redirects never export ETag scope across the source URL")
    func redirectETagScope() async throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "TinyCloudMusic-W11-I13-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let audio = try generateAudio(in: root)
        defer { try? FileManager.default.removeItem(at: root) }

        for hasIdentity in [true, false] {
            let metrics = AudioRangeHTTPMetrics()
            let secondPath = hasIdentity ? "/i13-digest-b.flac" : "/i13-transient-b.flac"
            let fixture = try LocalHTTPFixture(response: { request in
                let endpointID = audioRangeEndpointID(for: request, secondPath: secondPath)
                if endpointID == 1 {
                    _ = audioRangeHTTPResponse(
                        for: request,
                        body: audio.flacData,
                        contentType: "audio/flac",
                        metrics: metrics,
                        endpointID: endpointID
                    )
                    return fixtureHTTPResponse(
                        "307 Temporary Redirect",
                        headers: ["Location": secondPath]
                    )
                }
                return audioRangeHTTPResponse(
                    for: request,
                    body: audio.flacData,
                    contentType: "audio/flac",
                    metrics: metrics,
                    endpointID: endpointID,
                    strongETag: "\"i13-edge\""
                )
            })
            let networkSession = audioRangeURLSession()
            defer {
                networkSession.invalidateAndCancel()
                fixture.stop()
            }
            let port = try await startAudioRangeFixture(fixture)
            let firstPath = hasIdentity ? "/i13-digest-a.flac" : "/i13-transient-a.flac"
            guard let origin = URL(string: "http://127.0.0.1:\(port)\(firstPath)") else {
                throw AudioRangeIntegrationFailure(
                    stage: .fixtureStart,
                    requestCount: 0,
                    rangeCount: 0,
                    payloadBytes: 0
                )
            }
            let source: PlaybackSource
            if hasIdentity {
                source = try audioRangePlaybackSource(
                    url: origin,
                    level: "lossless",
                    format: "flac",
                    data: audio.flacData
                )
            } else {
                source = PlaybackSource(
                    url: origin,
                    availability: .playable(level: "lossless"),
                    format: "flac"
                )
            }
            let key = TrackRangeCacheKey(
                songID: hasIdentity ? 130_001 : 130_002,
                quality: "lossless"
            )
            let cacheRoot = root.appending(path: hasIdentity ? "DigestCache" : "TransientCache")
            let rangeCache = TrackRangeCache(trackCache: TrackCache(directory: cacheRoot)) { request in
                try await networkSession.download(for: request)
            }
            let rangeSession = try await rangeCache.open(
                key: key,
                format: "flac",
                initialSource: source,
                sourceProvider: { source }
            )

            if hasIdentity {
                let first = try await rangeCache.read(
                    session: rangeSession,
                    offset: 0,
                    maximumLength: 1
                )
                let secondOffset = audioRangeBlockSize + 1_024
                let second = try await rangeCache.read(
                    session: rangeSession,
                    offset: Int64(secondOffset),
                    maximumLength: 1
                )
                #expect(first == audio.flacData.prefix(1))
                #expect(second == audio.flacData.subdata(in: secondOffset..<(secondOffset + 1)))
                #expect(await rangeCache.descriptor(for: key) != nil)
            } else {
                await expectAudioRangeError(.unverifiableRepresentation) {
                    _ = try await rangeCache.read(
                        session: rangeSession,
                        offset: 0,
                        maximumLength: 1
                    )
                }
                #expect(await rangeCache.descriptor(for: key) == nil)
            }

            try await waitForAudioRangeMetricsToStabilize(fixture: fixture, metrics: metrics)
            let snapshot = metrics.snapshot()
            let sourceRequests = snapshot.requests.filter { $0.endpointID == 1 }
            #expect(!sourceRequests.isEmpty)
            #expect(sourceRequests.allSatisfy { !$0.hasIfRange })
            #expect(snapshot.requests.contains { $0.endpointID == 2 })
            await rangeCache.close(rangeSession)
            if !hasIdentity {
                try await waitForAudioRangeCondition(
                    stage: .requestValidation,
                    fixture: fixture,
                    metrics: metrics
                ) { audioRangeBodyCount(in: cacheRoot) == 0 }
            }
        }
    }
}
