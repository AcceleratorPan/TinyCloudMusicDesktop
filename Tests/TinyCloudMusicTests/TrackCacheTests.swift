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
    let root: URL

    init(root: URL) {
        self.root = root
    }

    func download(_ request: URLRequest) async throws -> (URL, URLResponse) {
        count += 1
        try await Task.sleep(for: .milliseconds(50))
        let url = root.appending(path: UUID().uuidString)
        try Data([1, 2, 3]).write(to: url)
        return (
            url,
            HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        )
    }
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

    let download = root.appending(path: "download.tmp")
    try Data([1, 2, 3]).write(to: download)
    guard try cache.finalize(download, for: 42, quality: "standard") == finalURL,
          cache.readyFile(for: 42, quality: "standard") == finalURL,
          !FileManager.default.fileExists(atPath: finalURL.appendingPathExtension("part").path)
    else { throw TrackCacheCheckError.failed }

    let losslessDownload = root.appending(path: "lossless.tmp")
    try Data([4, 5, 6]).write(to: losslessDownload)
    guard try cache.finalize(losslessDownload, for: 42, quality: "lossless") == losslessURL,
          losslessURL != finalURL,
          try Data(contentsOf: finalURL) == Data([1, 2, 3]),
          try Data(contentsOf: losslessURL) == Data([4, 5, 6])
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
