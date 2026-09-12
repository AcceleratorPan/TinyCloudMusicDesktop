import Foundation

#if !TRACK_CACHE_CHECK && canImport(Testing)
import Testing
@testable import TinyCloudMusic
#endif

private enum TrackCacheCheckError: Error {
    case failed
    case failedAt(String)
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
    private let blockingInvocation: Int
    private var invocations = 0
    private var entered = false
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?

    init(blockingInvocation: Int = 1) {
        self.blockingInvocation = blockingInvocation
    }

    func wait() async {
        invocations += 1
        guard invocations == blockingInvocation else { return }
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

private actor TrackCacheDownloadGate {
    private var started = false
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var completedURL: URL?
    let root: URL

    init(root: URL) {
        self.root = root
    }

    func download(_ request: URLRequest) async throws -> (URL, URLResponse) {
        started = true
        if !released {
            await withCheckedContinuation { waiters.append($0) }
        }
        let url = root.appending(path: UUID().uuidString)
        try Data("ID3".utf8).write(to: url)
        completedURL = url
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

    func hasStarted() -> Bool { started }

    func release() {
        released = true
        let pending = waiters
        waiters = []
        pending.forEach { $0.resume() }
    }
}

private func waitUntil(_ predicate: () async -> Bool) async throws {
    for _ in 0..<100 {
        if await predicate() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw TrackCacheCheckError.failed
}

private func allocatedSize(of url: URL) throws -> Int64 {
    let values = try URL(fileURLWithPath: url.path)
        .resourceValues(forKeys: [.fileAllocatedSizeKey, .fileSizeKey])
    guard let size = values.fileAllocatedSize ?? values.fileSize else {
        throw TrackCacheCheckError.failed
    }
    return Int64(size)
}

private func verifyCanonicalOwnership(
    cache: TrackCache,
    root: URL,
    finalURL: URL
) async throws {
    let lateDownload = root.appending(path: "late-download.tmp")
    try Data("ID3-late".utf8).write(to: lateDownload)
    guard try await cache.finalize(lateDownload, for: 42, quality: "standard") == finalURL,
          try Data(contentsOf: finalURL) == Data("ID3".utf8),
          !FileManager.default.fileExists(atPath: lateDownload.path)
    else { throw TrackCacheCheckError.failedAt("existing canonical file is immutable") }

    let lateRoot = root.appending(path: "late-completion", directoryHint: .isDirectory)
    let lateGate = TrackCacheDownloadGate(root: lateRoot)
    let lateCache = TrackCache(directory: lateRoot, download: { try await lateGate.download($0) })
    let lateWrite = Task {
        try await lateCache.cache(songID: 126, from: URL(string: "https://example.com/126.mp3")!)
    }
    try await waitUntil { await lateGate.hasStarted() }
    let canonicalSource = root.appending(path: "canonical-before-completion.tmp")
    let canonicalBody = Data("ID3-canonical".utf8)
    try canonicalBody.write(to: canonicalSource)
    let canonicalURL = try await lateCache.finalize(canonicalSource, for: 126)
    await lateGate.release()
    guard try await lateWrite.value == canonicalURL,
          try Data(contentsOf: canonicalURL) == canonicalBody
    else { throw TrackCacheCheckError.failedAt("late completion preserves canonical file") }
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

    try await verifyCanonicalOwnership(cache: cache, root: root, finalURL: finalURL)

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

    try await verifyPartialAccounting(root: root)
    try await verifyTrackCacheLifecycle(root: root)
}

private func verifyPartialAccounting(root: URL) async throws {
    let rangeMissRoot = root.appending(path: "partial-miss", directoryHint: .isDirectory)
    let rangeMissCache = TrackCache(directory: rangeMissRoot)
    let disguisedRange = rangeMissRoot
        .appending(path: "standard", directoryHint: .isDirectory)
        .appending(path: "130.range")
    try FileManager.default.createDirectory(
        at: disguisedRange.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try Data("fLaC".utf8).write(to: disguisedRange)
    guard await rangeMissCache.readyFile(for: 130) == nil,
          FileManager.default.fileExists(atPath: disguisedRange.path)
    else { throw TrackCacheCheckError.failedAt("partial ready-file miss") }

    let partialTrimRoot = root.appending(path: "partial-trim", directoryHint: .isDirectory)
    let partialTrimDirectory = partialTrimRoot
        .appending(path: "RangeCache", directoryHint: .isDirectory)
        .appending(path: "standard", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: partialTrimDirectory, withIntermediateDirectories: true)
    let olderPartial = partialTrimDirectory.appending(path: "older.range")
    let newerPartial = partialTrimDirectory.appending(path: "newer.range")
    try Data(repeating: 0xa5, count: 4_096).write(to: olderPartial)
    try await Task.sleep(for: .milliseconds(20))
    try Data(repeating: 0x5a, count: 4_096).write(to: newerPartial)
    let olderPartialSize = try allocatedSize(of: olderPartial)
    let newerPartialSize = try allocatedSize(of: newerPartial)
    let partialTrimLimit = max(olderPartialSize, newerPartialSize)
    guard olderPartialSize > 0,
          newerPartialSize > 0,
          olderPartialSize + newerPartialSize > partialTrimLimit
    else { throw TrackCacheCheckError.failedAt("partial trim precondition") }
    let partialTrimCache = TrackCache(
        directory: partialTrimRoot,
        byteLimit: partialTrimLimit,
        minimumTrimInterval: 0
    )
    await partialTrimCache.recordPartialFileAccess(newerPartial)
    guard !FileManager.default.fileExists(atPath: olderPartial.path),
          FileManager.default.fileExists(atPath: newerPartial.path)
    else { throw TrackCacheCheckError.failedAt("partial trim result") }

    let sparseRoot = root.appending(path: "partial-sparse", directoryHint: .isDirectory)
    let sparseDirectory = sparseRoot
        .appending(path: "RangeCache", directoryHint: .isDirectory)
        .appending(path: "standard", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: sparseDirectory, withIntermediateDirectories: true)
    let sparsePartial = sparseDirectory.appending(path: "tail-only.range")
    let sparseTrigger = sparseDirectory.appending(path: "trigger.range")
    try Data().write(to: sparsePartial)
    let logicalSize: UInt64 = 64 * 1_024 * 1_024
    let sparseHandle = try FileHandle(forWritingTo: sparsePartial)
    try sparseHandle.seek(toOffset: logicalSize - 4)
    try sparseHandle.write(contentsOf: Data([1, 2, 3, 4]))
    try sparseHandle.close()
    try Data([5]).write(to: sparseTrigger)
    let sparseLogicalSize = Int64(
        try sparsePartial.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
    )
    let sparseAllocatedSize = try allocatedSize(of: sparsePartial)
    let sparseTriggerSize = try allocatedSize(of: sparseTrigger)
    let initialAllocatedSize = sparseAllocatedSize + sparseTriggerSize
    guard sparseLogicalSize == Int64(logicalSize),
          sparseLogicalSize > initialAllocatedSize + 16_384
    else { throw TrackCacheCheckError.failedAt("sparse allocation precondition") }
    let sparseLimit = initialAllocatedSize + 8_192
    let sparseCache = TrackCache(
        directory: sparseRoot,
        byteLimit: sparseLimit,
        minimumTrimInterval: 0
    )
    await sparseCache.recordPartialFileAccess(sparseTrigger)
    guard FileManager.default.fileExists(atPath: sparsePartial.path),
          FileManager.default.fileExists(atPath: sparseTrigger.path)
    else { throw TrackCacheCheckError.failedAt("sparse below-limit result") }
    try Data(repeating: 0x3c, count: Int(sparseLimit + 8_192)).write(to: sparseTrigger)
    let expandedTriggerSize = try allocatedSize(of: sparseTrigger)
    guard sparseAllocatedSize + expandedTriggerSize > sparseLimit else {
        throw TrackCacheCheckError.failedAt("sparse expansion precondition")
    }
    await sparseCache.recordPartialFileAccess(sparseTrigger)
    guard !FileManager.default.fileExists(atPath: sparsePartial.path),
          FileManager.default.fileExists(atPath: sparseTrigger.path)
    else { throw TrackCacheCheckError.failedAt("sparse over-limit result") }

    let partialPinRoot = root.appending(path: "partial-pin-trim", directoryHint: .isDirectory)
    let partialPinDirectory = partialPinRoot
        .appending(path: "RangeCache", directoryHint: .isDirectory)
        .appending(path: "standard", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: partialPinDirectory, withIntermediateDirectories: true)
    let pinnedPartial = partialPinDirectory.appending(path: "pinned.range")
    let pinTrimTrigger = partialPinDirectory.appending(path: "trigger.range")
    try Data(repeating: 0x17, count: 4_096).write(to: pinnedPartial)
    try Data(repeating: 0x71, count: 4_096).write(to: pinTrimTrigger)
    let pinnedPartialSize = try allocatedSize(of: pinnedPartial)
    let pinTrimTriggerSize = try allocatedSize(of: pinTrimTrigger)
    let partialPinLimit = max(pinnedPartialSize, pinTrimTriggerSize)
    guard pinnedPartialSize > 0,
          pinTrimTriggerSize > 0,
          pinnedPartialSize + pinTrimTriggerSize > partialPinLimit
    else { throw TrackCacheCheckError.failedAt("partial pin precondition") }
    let partialPinCache = TrackCache(
        directory: partialPinRoot,
        byteLimit: partialPinLimit,
        minimumTrimInterval: 0
    )
    guard await partialPinCache.pin(pinnedPartial) else {
        throw TrackCacheCheckError.failedAt("partial pin")
    }
    await partialPinCache.recordPartialFileAccess(pinTrimTrigger)
    guard FileManager.default.fileExists(atPath: pinnedPartial.path),
          FileManager.default.fileExists(atPath: pinTrimTrigger.path)
    else { throw TrackCacheCheckError.failedAt("partial pinned trim result") }
    await partialPinCache.unpin(pinnedPartial)

    let partialClearRoot = root.appending(path: "partial-clear", directoryHint: .isDirectory)
    let partialClearBody = partialClearRoot
        .appending(path: "RangeCache", directoryHint: .isDirectory)
        .appending(path: "standard", directoryHint: .isDirectory)
        .appending(path: "clear.range")
    let partialClearMetadata = partialClearBody.appendingPathExtension("metadata.plist")
    try FileManager.default.createDirectory(
        at: partialClearBody.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try Data([1]).write(to: partialClearBody)
    try Data([2]).write(to: partialClearMetadata)
    let partialClearCache = TrackCache(directory: partialClearRoot, minimumTrimInterval: 0)
    guard await partialClearCache.pin(partialClearBody) else {
        throw TrackCacheCheckError.failedAt("partial clear pin")
    }
    try await partialClearCache.clear()
    guard FileManager.default.fileExists(atPath: partialClearBody.path),
          !FileManager.default.fileExists(atPath: partialClearMetadata.path)
    else { throw TrackCacheCheckError.failedAt("partial pinned clear result") }
    let trimCountAfterClear = await partialClearCache.trimRunCount
    await partialClearCache.recordPartialFileAccess(partialClearBody)
    guard await partialClearCache.trimRunCount == trimCountAfterClear else {
        throw TrackCacheCheckError.failedAt("partial pending-delete access")
    }
    await partialClearCache.unpin(partialClearBody)
    guard !FileManager.default.fileExists(atPath: partialClearBody.path),
          !FileManager.default.fileExists(atPath: partialClearMetadata.path)
    else { throw TrackCacheCheckError.failedAt("partial clear unpin result") }

    let partialValidationRoot = root.appending(path: "partial-validation", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: partialValidationRoot, withIntermediateDirectories: true)
    let partialValidationCache = TrackCache(directory: partialValidationRoot, minimumTrimInterval: 0)
    let outsidePartial = root.appending(path: "outside.range")
    let nonRangeFile = partialValidationRoot.appending(path: "inside.mp3")
    let missingPartial = partialValidationRoot.appending(path: "missing.range")
    let directoryPartial = partialValidationRoot.appending(path: "directory.range", directoryHint: .isDirectory)
    try Data([1]).write(to: outsidePartial)
    try Data([1]).write(to: nonRangeFile)
    try FileManager.default.createDirectory(at: directoryPartial, withIntermediateDirectories: true)
    await partialValidationCache.recordPartialFileAccess(outsidePartial)
    await partialValidationCache.recordPartialFileAccess(nonRangeFile)
    await partialValidationCache.recordPartialFileAccess(missingPartial)
    await partialValidationCache.recordPartialFileAccess(directoryPartial)
    guard await partialValidationCache.trimRunCount == 0,
          FileManager.default.fileExists(atPath: outsidePartial.path),
          FileManager.default.fileExists(atPath: nonRangeFile.path),
          !FileManager.default.fileExists(atPath: missingPartial.path)
    else { throw TrackCacheCheckError.failedAt("partial access validation") }
}

private func verifyTrackCacheLifecycle(root: URL) async throws {
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

    try await verifyInvalidation(root: root)
    try await verifyTrackCacheRaces(root: root)
}

private func verifyInvalidation(root: URL) async throws {
    let invalidateRoot = root.appending(path: "invalidate", directoryHint: .isDirectory)
    let invalidateCache = TrackCache(directory: invalidateRoot)
    let unpinnedSource = root.appending(path: "invalidate-unpinned.tmp")
    try Data("ID3-unpinned".utf8).write(to: unpinnedSource)
    let unpinnedURL = try await invalidateCache.finalize(unpinnedSource, for: 127)
    await invalidateCache.invalidateCachedFile(unpinnedURL)
    guard await invalidateCache.readyFile(for: 127) == nil,
          !FileManager.default.fileExists(atPath: unpinnedURL.path)
    else { throw TrackCacheCheckError.failedAt("invalidate unpinned full") }

    let pinnedSource = root.appending(path: "invalidate-pinned.tmp")
    try Data("ID3-pinned".utf8).write(to: pinnedSource)
    _ = try await invalidateCache.finalize(pinnedSource, for: 128)
    guard let invalidatedPinned = await invalidateCache.readyPinnedFile(for: 128) else {
        throw TrackCacheCheckError.failedAt("invalidate full pin")
    }
    // A decode failure can include a damaged header after the file was pinned.
    try Data("broken-header".utf8).write(to: invalidatedPinned)
    await invalidateCache.invalidateCachedFile(invalidatedPinned)
    guard await invalidateCache.readyFile(for: 128) == nil,
          FileManager.default.fileExists(atPath: invalidatedPinned.path)
    else { throw TrackCacheCheckError.failedAt("invalidate pinned full") }
    await invalidateCache.unpin(invalidatedPinned)
    guard !FileManager.default.fileExists(atPath: invalidatedPinned.path) else {
        throw TrackCacheCheckError.failedAt("invalidate pinned full unpin")
    }

    let invalidatedDownloadRoot = root.appending(
        path: "invalidate-late-download",
        directoryHint: .isDirectory
    )
    let invalidatedDownloadGate = TrackCacheDownloadGate(root: invalidatedDownloadRoot)
    let invalidatedDownloadCache = TrackCache(
        directory: invalidatedDownloadRoot,
        download: { try await invalidatedDownloadGate.download($0) }
    )
    let invalidatedDownload = Task {
        try await invalidatedDownloadCache.cache(
            songID: 129,
            from: URL(string: "https://example.com/129.mp3")!
        )
    }
    try await waitUntil { await invalidatedDownloadGate.hasStarted() }
    let invalidatedCanonicalSource = root.appending(path: "invalidate-late-canonical.tmp")
    try Data("ID3-canonical".utf8).write(to: invalidatedCanonicalSource)
    let invalidatedCanonical = try await invalidatedDownloadCache.finalize(
        invalidatedCanonicalSource,
        for: 129
    )
    await invalidatedDownloadCache.invalidateCachedFile(invalidatedCanonical)
    do {
        _ = try await invalidatedDownload.value
        throw TrackCacheCheckError.failedAt("invalidate in-flight cancellation")
    } catch is CancellationError {
    }
    await invalidatedDownloadGate.release()
    try await waitUntil {
        guard let completedURL = await invalidatedDownloadGate.completedURL else { return false }
        return !FileManager.default.fileExists(atPath: completedURL.path)
    }
    guard await invalidatedDownloadCache.readyFile(for: 129) == nil,
          !FileManager.default.fileExists(atPath: invalidatedCanonical.path)
    else { throw TrackCacheCheckError.failedAt("invalidate late completion fence") }
}

private func verifyTrackCacheRaces(root: URL) async throws {
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

    let sharedRoot = root.appending(path: "shared-owner", directoryHint: .isDirectory)
    guard TrackCache.shared(directory: sharedRoot)
        === TrackCache.shared(directory: sharedRoot.appending(path: "..", directoryHint: .isDirectory)
            .appending(path: "shared-owner", directoryHint: .isDirectory))
    else { throw TrackCacheCheckError.failed }

    let clearRoot = root.appending(path: "write-clear-race", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: clearRoot, withIntermediateDirectories: true)
    let downloadGate = TrackCacheDownloadGate(root: clearRoot)
    let clearCache = TrackCache(directory: clearRoot, download: { request in
        try await downloadGate.download(request)
    })
    let oldWrite = Task {
        try await clearCache.cache(songID: 122, from: URL(string: "https://example.com/122.mp3")!)
    }
    try await waitUntil { await downloadGate.hasStarted() }
    let clearing = Task { try await clearCache.clear() }
    try await waitUntil { await clearCache.isClearing }
    do {
        _ = try await clearCache.cache(songID: 123, from: URL(string: "https://example.com/123.mp3")!)
        throw TrackCacheCheckError.failed
    } catch is CancellationError {
    }
    await downloadGate.release()
    do {
        _ = try await oldWrite.value
        throw TrackCacheCheckError.failed
    } catch is CancellationError {
    }
    try await clearing.value
    guard await clearCache.readyFile(for: 122) == nil,
          await clearCache.readyFile(for: 123) == nil
    else { throw TrackCacheCheckError.failed }

    let pendingRoot = root.appending(path: "pre-clear-lookup", directoryHint: .isDirectory)
    let pendingLookup = TrackCacheLookupGate()
    let pendingDownloads = TrackCacheDownloadCounter(root: pendingRoot)
    let pendingCache = TrackCache(
        directory: pendingRoot,
        beforeReadyLookup: { await pendingLookup.wait() },
        download: { try await pendingDownloads.download($0) }
    )
    let pendingWrite = Task {
        try await pendingCache.cache(songID: 124, from: URL(string: "https://example.com/124.mp3")!)
    }
    await pendingLookup.waitUntilEntered()
    try await pendingCache.clear()
    await pendingLookup.release()
    do {
        _ = try await pendingWrite.value
        throw TrackCacheCheckError.failed
    } catch is CancellationError {
    }
    guard await pendingDownloads.count == 0 else { throw TrackCacheCheckError.failed }

    let pendingCopyRoot = root.appending(path: "pre-clear-copy", directoryHint: .isDirectory)
    let copyLookup = TrackCacheLookupGate()
    let pendingCopyCache = TrackCache(
        directory: pendingCopyRoot,
        beforeReadyLookup: { await copyLookup.wait() }
    )
    let copySource = root.appending(path: "pre-clear-copy.tmp")
    try Data("ID3".utf8).write(to: copySource)
    let pendingCopy = Task {
        try await pendingCopyCache.storeCopy(
            of: copySource,
            for: 125,
            quality: "standard",
            fileExtension: "mp3"
        )
    }
    await copyLookup.waitUntilEntered()
    try await pendingCopyCache.clear()
    await copyLookup.release()
    do {
        _ = try await pendingCopy.value
        throw TrackCacheCheckError.failed
    } catch is CancellationError {
    }
    guard await pendingCopyCache.readyFile(for: 125) == nil else { throw TrackCacheCheckError.failed }
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
private final class TrackCacheOwnerDownloadProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let path = request.url?.path
        let status: Int
        let contentType: String
        let body: Data
        switch path {
        case "/eapi/song/enhance/player/url/v1":
            status = 200
            contentType = "application/json"
            body = Data(
                #"{"code":200,"data":[{"id":901,"code":200,"url":"https://m1.music.126.net/owner-cache-audio","type":"mp3","level":"standard"}]}"#.utf8
            )
        case "/owner-cache-audio":
            status = 200
            contentType = "audio/mpeg"
            body = Data("ID3-owner-cache".utf8)
        default:
            status = 404
            contentType = "application/json"
            body = Data(#"{"code":404}"#.utf8)
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: nil,
            headerFields: ["Content-Type": contentType]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

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
        #expect(downloads.contains("await audioCache.invalidateCachedFile(stored.url)"))
        #expect(!downloads.contains("removeItem(at: stored.url)"))
    }

    @MainActor
    @Test("Player clear fences an in-flight Download owner cache write")
    func sharedProductionOwnersCoordinateClearAndWrite() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = TrackCacheLookupGate(blockingInvocation: 3)
        let cache = TrackCache(
            directory: root.appending(path: "StreamCache", directoryHint: .isDirectory),
            beforeReadyLookup: { await gate.wait() }
        )
        let player = PlayerController(
            repository: FixtureMusicRepository(),
            cacheRoot: root,
            cache: cache,
            crossfadeDuration: 0
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TrackCacheOwnerDownloadProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let downloads = MusicDownloadManager(
            transport: EAPITransport(session: session, cookie: "", musicU: ""),
            session: session,
            maximumConcurrentDownloads: 1,
            retryPolicy: MusicDownloadRetryPolicy(maximumAttempts: 1, baseDelay: 0, maximumDelay: 0),
            resumeStore: MusicDownloadResumeStore(directory: root.appending(path: "Resume")),
            targetAllocator: MusicDownloadTargetAllocator(),
            cacheRoot: root,
            audioCache: cache
        )
        let song = Song(
            id: 901,
            name: "Owner cache fence",
            artists: [ArtistSummary(id: 1, name: "Fixture")],
            album: AlbumSummary(
                id: 1,
                name: "Fixture",
                artwork: Artwork(symbol: "music.note", accent: .blue)
            ),
            duration: .seconds(1)
        )

        #expect(downloads.enqueue(
            song: song,
            to: root.appending(path: "Downloads"),
            quality: .standard,
            includeLyrics: false
        ))
        await gate.waitUntilEntered()
        try await player.clearCache()
        await gate.release()
        for _ in 0..<100 {
            switch downloads.states[song.id] {
            case .completed, .failed, .cancelled: break
            default:
                try await Task.sleep(for: .milliseconds(10))
                continue
            }
            break
        }

        guard case .completed = downloads.states[song.id] else {
            throw TrackCacheCheckError.failed
        }
        #expect(await cache.readyFile(for: song.id) == nil)
    }
}
#endif
