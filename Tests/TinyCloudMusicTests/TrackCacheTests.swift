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
    guard cache.readyFile(for: 42, quality: "standard") == nil else { throw TrackCacheCheckError.failed }
    try Data("not audio".utf8).write(to: finalURL)
    guard cache.readyFile(for: 42, quality: "standard") == nil else { throw TrackCacheCheckError.failed }
    try FileManager.default.removeItem(at: finalURL)

    let download = root.appending(path: "download.tmp")
    try Data("ID3".utf8).write(to: download)
    guard try cache.finalize(download, for: 42, quality: "standard") == finalURL,
          cache.readyFile(for: 42, quality: "standard") == finalURL,
          !FileManager.default.fileExists(atPath: finalURL.appendingPathExtension("part").path)
    else { throw TrackCacheCheckError.failed }

    let losslessDownload = root.appending(path: "lossless.tmp")
    try Data("fLaC".utf8).write(to: losslessDownload)
    guard try cache.finalize(losslessDownload, for: 42, quality: "lossless") == losslessURL,
          losslessURL != finalURL,
          try Data(contentsOf: finalURL) == Data("ID3".utf8),
          try Data(contentsOf: losslessURL) == Data("fLaC".utf8)
    else { throw TrackCacheCheckError.failed }

    let counter = TrackCacheDownloadCounter(root: root)
    let coalescingCache = TrackCache(directory: root) { request in
        try await counter.download(request)
    }
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
        _ = try cache.finalize(invalidDirectory, for: 45)
    } catch TrackCacheError.emptyDownload {
        rejectedDirectory = true
    }
    guard rejectedDirectory else { throw TrackCacheCheckError.failed }

    for (index, response) in [
        (0, (status: 200, contentType: "text/html")),
        (1, (status: 200, contentType: "application/json")),
        (2, (status: 503, contentType: "audio/mpeg"))
    ] {
        let invalidRoot = root.appending(path: "invalid-response-\(index)", directoryHint: .isDirectory)
        let invalidCache = TrackCache(directory: invalidRoot) { request in
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
        }
        var rejected = false
        do {
            _ = try await invalidCache.cache(songID: Int64(50 + index), from: URL(string: "https://example.com")!)
        } catch TrackCacheError.invalidResponse {
            rejected = true
        }
        guard rejected else { throw TrackCacheCheckError.failed }
    }

    let truncatedRoot = root.appending(path: "truncated", directoryHint: .isDirectory)
    let truncatedCache = TrackCache(directory: truncatedRoot) { request in
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
    }
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
        maximumConcurrentDownloads: 2
    ) { request in
        try await concurrencyCounter.download(request)
    }
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
    let cancellationCache = TrackCache(directory: cancellationRoot) { request in
        try await cancellationCounter.download(request)
    }
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
    guard cancellationCache.readyFile(for: 71) == nil else { throw TrackCacheCheckError.failed }

    let evictionRoot = root.appending(path: "eviction", directoryHint: .isDirectory)
    let evictionCache = TrackCache(directory: evictionRoot, byteLimit: 6, maximumConcurrentDownloads: 1) { request in
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
    _ = try await evictionCache.cache(songID: 80, from: URL(string: "https://example.com/80.mp3")!)
    try await Task.sleep(for: .milliseconds(20))
    _ = try await evictionCache.cache(songID: 81, from: URL(string: "https://example.com/81.mp3")!)
    try await Task.sleep(for: .milliseconds(20))
    _ = try await evictionCache.cache(songID: 80, from: URL(string: "https://example.com/80.mp3")!)
    try await Task.sleep(for: .milliseconds(20))
    _ = try await evictionCache.cache(songID: 82, from: URL(string: "https://example.com/82.mp3")!)
    guard evictionCache.readyFile(for: 80) != nil,
          evictionCache.readyFile(for: 81) == nil,
          evictionCache.readyFile(for: 82) != nil
    else { throw TrackCacheCheckError.failed }

    let oversizedRoot = root.appending(path: "oversized", directoryHint: .isDirectory)
    let oversizedCache = TrackCache(directory: oversizedRoot, byteLimit: 2) { request in
        try FileManager.default.createDirectory(at: oversizedRoot, withIntermediateDirectories: true)
        let temporary = oversizedRoot.appending(path: UUID().uuidString)
        try Data("ID3".utf8).write(to: temporary)
        return (
            temporary,
            HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        )
    }
    let oversized = try await oversizedCache.cache(songID: 90, from: URL(string: "https://example.com/90.mp3")!)
    guard FileManager.default.fileExists(atPath: oversized.path) else { throw TrackCacheCheckError.failed }
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
}
#endif
