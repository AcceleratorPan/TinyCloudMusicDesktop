import Foundation

#if !TRACK_CACHE_CHECK && canImport(Testing)
import Testing
@testable import TinyCloudMusic
#endif

private enum TrackCacheCheckError: Error {
    case failed
}

private actor TrackCacheDownloadCounter {
    private(set) var count = 0
    private(set) var active = 0
    private(set) var peak = 0
    private(set) var cancellations = 0
    let root: URL
    let delay: Duration

    init(root: URL, delay: Duration = .milliseconds(50)) {
        self.root = root
        self.delay = delay
    }

    func download(_ request: URLRequest) async throws -> (URL, URLResponse) {
        count += 1
        active += 1
        peak = max(peak, active)
        do {
            try await Task.sleep(for: delay)
        } catch {
            active -= 1
            cancellations += 1
            throw error
        }
        active -= 1
        let url = root.appending(path: UUID().uuidString)
        try Data("ID3".utf8).write(to: url)
        return (
            url,
            HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "audio/mpeg"]
            )!
        )
    }
}

private actor TrackCacheLookupGate {
    private var entered = false
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        entered = true
        guard !released else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilEntered() async {
        while !entered { await Task.yield() }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

private func waitUntil(_ predicate: () async -> Bool) async throws {
    for _ in 0..<100 {
        if await predicate() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw TrackCacheCheckError.failed
}

private func verifyTrackCache() async throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let cache = TrackCache(directory: root)
    let finalURL = cache.fileURL(for: 42, quality: "standard")
    let losslessURL = cache.fileURL(for: 42, quality: "lossless")
    guard finalURL.pathExtension == "mp3",
          losslessURL.pathExtension == "flac",
          cache.fileURL(for: 42, quality: "../lossless").deletingLastPathComponent().lastPathComponent == "unknown"
    else { throw TrackCacheCheckError.failed }

    try FileManager.default.createDirectory(
        at: finalURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try Data().write(to: finalURL)
    guard await cache.readyFile(for: 42, quality: "standard") == nil else { throw TrackCacheCheckError.failed }
    try Data("not audio".utf8).write(to: finalURL)
    guard await cache.readyFile(for: 42, quality: "standard") == nil else { throw TrackCacheCheckError.failed }
    try FileManager.default.removeItem(at: finalURL)

    let download = root.appending(path: "download.tmp")
    try Data("ID3".utf8).write(to: download)
    guard try await cache.finalize(download, for: 42, quality: "standard") == finalURL,
          await cache.readyFile(for: 42, quality: "standard") == finalURL,
          !FileManager.default.fileExists(atPath: finalURL.appendingPathExtension("part").path)
    else { throw TrackCacheCheckError.failed }

    try Data("ID3-corrupted-size".utf8).write(to: finalURL)
    guard await cache.readyFile(for: 42, quality: "standard") == nil else { throw TrackCacheCheckError.failed }
    let repaired = root.appending(path: "repaired.tmp")
    try Data("ID3".utf8).write(to: repaired)
    _ = try await cache.finalize(repaired, for: 42, quality: "standard")

    let actualFLAC = root.appending(path: "actual-flac.tmp")
    try Data("fLaC".utf8).write(to: actualFLAC)
    let stored = try await cache.storeCopy(
        of: actualFLAC,
        for: 46,
        quality: "standard",
        fileExtension: "flac"
    )
    guard stored.url.pathExtension == "flac",
          stored.fileExtension == "flac",
          stored.size == 4
    else { throw TrackCacheCheckError.failed }

    let legacyURL = cache.fileURL(for: 47, quality: "standard")
    try Data("ID3-legacy".utf8).write(to: legacyURL)
    async let firstLegacy = cache.readyCachedFile(for: 47, quality: "standard")
    async let secondLegacy = cache.readyCachedFile(for: 47, quality: "standard")
    let legacyHits = await [firstLegacy, secondLegacy]
    guard legacyHits.allSatisfy({ $0?.url == legacyURL }),
          await cache.migrationCount == 1,
          FileManager.default.fileExists(atPath: legacyURL.appendingPathExtension("metadata.plist").path)
    else { throw TrackCacheCheckError.failed }

    let losslessDownload = root.appending(path: "lossless.tmp")
    try Data("fLaC".utf8).write(to: losslessDownload)
    guard try await cache.finalize(losslessDownload, for: 42, quality: "lossless") == losslessURL,
          losslessURL != finalURL,
          try Data(contentsOf: finalURL) == Data("ID3".utf8),
          try Data(contentsOf: losslessURL) == Data("fLaC".utf8)
    else { throw TrackCacheCheckError.failed }

    let counter = TrackCacheDownloadCounter(root: root)
    let coalescingCache = TrackCache(directory: root, download: { request in
        try await counter.download(request)
    })
    async let first = coalescingCache.cache(songID: 43, from: URL(string: "https://example.com/43.mp3")!)
    async let second = coalescingCache.cache(songID: 43, from: URL(string: "https://example.com/43.mp3")!)
    let urls = try await [first, second]
    async let standard = coalescingCache.cache(
        songID: 44,
        quality: "standard",
        from: URL(string: "https://example.com/44-standard.mp3")!
    )
    async let lossless = coalescingCache.cache(
        songID: 44,
        quality: "lossless",
        from: URL(string: "https://example.com/44-lossless.mp3")!
    )
    let qualityURLs = try await [standard, lossless]
    let leftovers = (FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? [])
        .filter { $0.pathExtension == "part" }
    guard urls[0] == urls[1],
          qualityURLs[0] != qualityURLs[1],
          await counter.count == 3,
          leftovers.isEmpty
    else {
        throw TrackCacheCheckError.failed
    }

    let invalidDirectory = root.appending(path: "not-a-file", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: invalidDirectory, withIntermediateDirectories: true)
    var rejectedDirectory = false
    do {
        _ = try await cache.finalize(invalidDirectory, for: 45)
    } catch TrackCacheError.emptyDownload {
        rejectedDirectory = true
    }
    guard rejectedDirectory else { throw TrackCacheCheckError.failed }

    let signatureRoot = root.appending(path: "signatures", directoryHint: .isDirectory)
    let signatureCache = TrackCache(directory: signatureRoot)
    let wavSource = root.appending(path: "audio-riff.tmp")
    try (Data("RIFF".utf8) + Data(repeating: 0, count: 4) + Data("WAVE".utf8)).write(to: wavSource)
    let wav = try await signatureCache.finalize(wavSource, for: 48)
    let m4aSource = root.appending(path: "audio-m4a.tmp")
    try (Data([0, 0, 0, 16]) + Data("ftypM4A ".utf8) + Data(repeating: 0, count: 4)).write(to: m4aSource)
    let m4a = try await signatureCache.finalize(m4aSource, for: 49)
    guard wav.pathExtension == "wav", m4a.pathExtension == "m4a" else {
        throw TrackCacheCheckError.failed
    }
    for (songID, bytes) in [
        (Int64(50), Data("RIFF".utf8) + Data(repeating: 0, count: 4) + Data("AVI ".utf8)),
        (Int64(51), Data([0, 0, 0, 16]) + Data("ftypisom".utf8) + Data(repeating: 0, count: 4))
    ] {
        let source = root.appending(path: "invalid-signature-\(songID).tmp")
        try bytes.write(to: source)
        do {
            _ = try await signatureCache.finalize(source, for: songID)
            throw TrackCacheCheckError.failed
        } catch TrackCacheError.emptyDownload {
        }
    }

    for (index, response) in [
        (0, (status: 200, contentType: "text/html")),
        (1, (status: 200, contentType: "application/json")),
        (2, (status: 503, contentType: "audio/mpeg"))
    ] {
        let invalidRoot = root.appending(path: "invalid-response-\(index)", directoryHint: .isDirectory)
        let invalidCache = TrackCache(directory: invalidRoot, download: { request in
            try FileManager.default.createDirectory(at: invalidRoot, withIntermediateDirectories: true)
            let temporary = invalidRoot.appending(path: UUID().uuidString)
            try Data([1]).write(to: temporary)
            return (
                temporary,
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: response.status,
                    httpVersion: nil,
                    headerFields: ["Content-Type": response.contentType]
                )!
            )
        })
        var rejected = false
        do {
            _ = try await invalidCache.cache(songID: Int64(50 + index), from: URL(string: "https://example.com")!)
        } catch TrackCacheError.invalidResponse {
            rejected = true
        }
        guard rejected else { throw TrackCacheCheckError.failed }
    }

    let truncatedRoot = root.appending(path: "truncated", directoryHint: .isDirectory)
    let truncatedCache = TrackCache(directory: truncatedRoot, download: { request in
        try FileManager.default.createDirectory(at: truncatedRoot, withIntermediateDirectories: true)
        let temporary = truncatedRoot.appending(path: UUID().uuidString)
        try Data("ID3".utf8).write(to: temporary)
        return (
            temporary,
            HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "audio/mpeg", "Content-Length": "10"]
            )!
        )
    })
    do {
        _ = try await truncatedCache.cache(songID: 59, from: URL(string: "https://example.com/59.mp3")!)
        throw TrackCacheCheckError.failed
    } catch TrackCacheError.invalidResponse {
    }

    let concurrencyRoot = root.appending(path: "concurrency", directoryHint: .isDirectory)
    let concurrencyCounter = TrackCacheDownloadCounter(root: concurrencyRoot, delay: .milliseconds(60))
    let limitedCache = TrackCache(
        directory: concurrencyRoot,
        byteLimit: 1_000,
        maximumConcurrentDownloads: 2,
        download: { request in
            try await concurrencyCounter.download(request)
        }
    )
    try await withThrowingTaskGroup(of: Void.self) { group in
        for id in Int64(60)...65 {
            group.addTask {
                _ = try await limitedCache.cache(
                    songID: id,
                    from: URL(string: "https://example.com/\(id).mp3")!
                )
            }
        }
        try await group.waitForAll()
    }
    guard await concurrencyCounter.count == 6,
          await concurrencyCounter.peak == 2
    else { throw TrackCacheCheckError.failed }

    let cancellationRoot = root.appending(path: "cancellation", directoryHint: .isDirectory)
    let cancellationCounter = TrackCacheDownloadCounter(root: cancellationRoot, delay: .milliseconds(300))
    let cancellationCache = TrackCache(directory: cancellationRoot, download: { request in
        try await cancellationCounter.download(request)
    })
    let firstWaiter = Task {
        try await cancellationCache.cache(songID: 70, from: URL(string: "https://example.com/70.mp3")!)
    }
    let secondWaiter = Task {
        try await cancellationCache.cache(songID: 70, from: URL(string: "https://example.com/70.mp3")!)
    }
    try await waitUntil { await cancellationCounter.count == 1 }
    try await Task.sleep(for: .milliseconds(30))
    firstWaiter.cancel()
    do {
        _ = try await firstWaiter.value
        throw TrackCacheCheckError.failed
    } catch is CancellationError {
    }
    let sharedURL = try await secondWaiter.value
    guard FileManager.default.fileExists(atPath: sharedURL.path),
          await cancellationCounter.count == 1,
          await cancellationCounter.cancellations == 0
    else { throw TrackCacheCheckError.failed }

    let lastWaiter = Task {
        try await cancellationCache.cache(songID: 71, from: URL(string: "https://example.com/71.mp3")!)
    }
    try await waitUntil { await cancellationCounter.count == 2 }
    lastWaiter.cancel()
    do {
        _ = try await lastWaiter.value
        throw TrackCacheCheckError.failed
    } catch is CancellationError {
    }
    try await waitUntil { await cancellationCounter.cancellations == 1 }
    guard await cancellationCache.readyFile(for: 71) == nil else { throw TrackCacheCheckError.failed }

    let evictionRoot = root.appending(path: "eviction", directoryHint: .isDirectory)
    let evictionCache = TrackCache(
        directory: evictionRoot,
        byteLimit: 6,
        maximumConcurrentDownloads: 1,
        minimumTrimInterval: 0,
        download: { request in
            try FileManager.default.createDirectory(at: evictionRoot, withIntermediateDirectories: true)
            let temporary = evictionRoot.appending(path: UUID().uuidString)
            try Data("ID3".utf8).write(to: temporary)
            return (
                temporary,
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "audio/mpeg"]
                )!
            )
        }
    )
    _ = try await evictionCache.cache(songID: 80, from: URL(string: "https://example.com/80.mp3")!)
    try await Task.sleep(for: .milliseconds(20))
    _ = try await evictionCache.cache(songID: 81, from: URL(string: "https://example.com/81.mp3")!)
    try await Task.sleep(for: .milliseconds(20))
    _ = try await evictionCache.cache(songID: 80, from: URL(string: "https://example.com/80.mp3")!)
    try await Task.sleep(for: .milliseconds(20))
    _ = try await evictionCache.cache(songID: 82, from: URL(string: "https://example.com/82.mp3")!)
    guard await evictionCache.readyFile(for: 80) != nil,
          await evictionCache.readyFile(for: 81) == nil,
          await evictionCache.readyFile(for: 82) != nil
    else { throw TrackCacheCheckError.failed }

    let oversizedRoot = root.appending(path: "oversized", directoryHint: .isDirectory)
    let oversizedCache = TrackCache(directory: oversizedRoot, byteLimit: 2, download: { request in
        try FileManager.default.createDirectory(at: oversizedRoot, withIntermediateDirectories: true)
        let temporary = oversizedRoot.appending(path: UUID().uuidString)
        try Data("ID3".utf8).write(to: temporary)
        return (
            temporary,
            HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        )
    })
    let oversized = try await oversizedCache.cache(songID: 90, from: URL(string: "https://example.com/90.mp3")!)
    guard FileManager.default.fileExists(atPath: oversized.path) else { throw TrackCacheCheckError.failed }

    let trimRoot = root.appending(path: "trim", directoryHint: .isDirectory)
    let trimCache = TrackCache(directory: trimRoot, minimumTrimInterval: 3_600)
    for songID in Int64(100)...101 {
        let source = root.appending(path: "trim-\(songID).tmp")
        try Data("ID3".utf8).write(to: source)
        _ = try await trimCache.finalize(source, for: songID)
    }
    guard await trimCache.trimRunCount == 1 else { throw TrackCacheCheckError.failed }

    let hitRoot = root.appending(path: "hit-trim", directoryHint: .isDirectory)
    let hitCache = TrackCache(directory: hitRoot, minimumTrimInterval: 0)
    let hitSource = root.appending(path: "hit-trim.tmp")
    try Data("ID3".utf8).write(to: hitSource)
    _ = try await hitCache.finalize(hitSource, for: 102)
    for _ in 0..<3 where await hitCache.readyFile(for: 102) == nil {
        throw TrackCacheCheckError.failed
    }
    guard await hitCache.trimRunCount == 1 else { throw TrackCacheCheckError.failed }

    let copyRoot = root.appending(path: "copy-budget", directoryHint: .isDirectory)
    let copyCache = TrackCache(directory: copyRoot, byteLimit: 3, minimumTrimInterval: 0)
    let firstCopy = root.appending(path: "copy-1.tmp")
    let secondCopy = root.appending(path: "copy-2.tmp")
    try Data("ID3".utf8).write(to: firstCopy)
    try Data("ID3".utf8).write(to: secondCopy)
    _ = try await copyCache.storeCopy(of: firstCopy, for: 110, quality: "standard", fileExtension: "mp3")
    _ = try await copyCache.storeCopy(of: secondCopy, for: 111, quality: "standard", fileExtension: "mp3")
    guard await copyCache.readyFile(for: 110) == nil,
          await copyCache.readyFile(for: 111) != nil
    else { throw TrackCacheCheckError.failed }

    let pinRoot = root.appending(path: "pin", directoryHint: .isDirectory)
    let pinCache = TrackCache(directory: pinRoot)
    let pinSource = root.appending(path: "pin.tmp")
    try Data("ID3".utf8).write(to: pinSource)
    _ = try await pinCache.finalize(pinSource, for: 120)
    guard let pinned = await pinCache.readyPinnedFile(for: 120) else {
        throw TrackCacheCheckError.failed
    }
    try await pinCache.clear()
    try await pinCache.clear()
    guard await pinCache.readyFile(for: 120) == nil,
          FileManager.default.fileExists(atPath: pinned.path)
    else { throw TrackCacheCheckError.failed }
    await pinCache.unpin(pinned)
    guard !FileManager.default.fileExists(atPath: pinned.path),
          !FileManager.default.fileExists(atPath: pinned.appendingPathExtension("metadata.plist").path)
    else { throw TrackCacheCheckError.failed }

    let raceRoot = root.appending(path: "lookup-clear-race", directoryHint: .isDirectory)
    let lookupGate = TrackCacheLookupGate()
    let raceCache = TrackCache(directory: raceRoot, beforeReadyLookup: { await lookupGate.wait() })
    let raceSource = root.appending(path: "lookup-clear-race.tmp")
    try Data("ID3".utf8).write(to: raceSource)
    let racedURL = try await raceCache.finalize(raceSource, for: 121)
    let lookup = Task { await raceCache.readyPinnedFile(for: 121) }
    await lookupGate.waitUntilEntered()
    try await raceCache.clear()
    await lookupGate.release()
    guard await lookup.value == nil,
          !FileManager.default.fileExists(atPath: racedURL.path)
    else { throw TrackCacheCheckError.failed }
}

#if TRACK_CACHE_CHECK
@main
private enum TrackCacheCheck {
    static func main() async throws {
        try await verifyTrackCache()
        print("Track cache check passed")
    }
}
#elseif canImport(Testing)
@Suite("Track cache")
struct TrackCacheTests {
    @Test("Only a non-empty finalized file is a cache hit")
    func finalizationAndHitValidation() async throws {
        try await verifyTrackCache()
    }

    @Test("Ready lookup is actor-isolated through the download bridge")
    func asyncReadyLookupBoundary() throws {
        let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let sources = tests
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Sources/TinyCloudMusic")
        let cache = try String(
            contentsOf: sources.appending(path: "TrackCache.swift"),
            encoding: .utf8
        )
        let downloads = try String(
            contentsOf: sources.appending(path: "MusicDownload.swift"),
            encoding: .utf8
        )
        let lookupStart = try #require(downloads.range(of: "func cachedAudio"))
        let lookupEnd = try #require(downloads.range(of: "let audio: DownloadedAudio", range: lookupStart.upperBound..<downloads.endIndex))
        let lookup = downloads[lookupStart.lowerBound..<lookupEnd.lowerBound]

        #expect(cache.contains("func readyCachedFile(for songID: Int64, quality: String = \"standard\") async"))
        #expect(!cache.contains("nonisolated func readyCachedFile"))
        #expect(!cache.contains("readyCachedFileAsync"))
        #expect(lookup.contains("await audioCache.readyCachedFile"))
        #expect(!lookup.contains("Data(contentsOf:"))
        #expect(!lookup.contains("resourceValues"))
    }
}
#endif
