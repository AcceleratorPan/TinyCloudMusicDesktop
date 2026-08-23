import Foundation

enum TrackCacheError: LocalizedError {
    case invalidResponse
    case emptyDownload

    var errorDescription: String? {
        switch self {
        case .invalidResponse: "音频下载请求失败"
        case .emptyDownload: "音频缓存为空"
        }
    }
}

private actor TrackCacheDownloadLimiter {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }

    private let limit: Int
    private var active = 0
    // ponytail: Player normally queues current + prefetch; switch to a deque only if bulk prefetch is added.
    private var waiters: [Waiter] = []

    init(limit: Int) {
        self.limit = min(max(limit, 1), 4)
    }

    func acquire() async throws {
        try Task.checkCancellation()
        guard active >= limit else {
            active += 1
            return
        }

        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiters.append(Waiter(id: id, continuation: continuation))
                }
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    func release() {
        if waiters.isEmpty {
            active = max(0, active - 1)
        } else {
            waiters.removeFirst().continuation.resume()
        }
    }

    private func cancel(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }
}

private final class TrackCacheRegistry: @unchecked Sendable {
    private final class WeakCache {
        weak var value: TrackCache?

        init(_ value: TrackCache) {
            self.value = value
        }
    }

    private let lock = NSLock()
    private var caches: [String: WeakCache] = [:]

    func cache(for directory: URL) -> TrackCache {
        let directory = directory.standardizedFileURL
        return lock.withLock {
            if let cache = caches[directory.path]?.value { return cache }
            let cache = TrackCache(directory: directory)
            caches[directory.path] = WeakCache(cache)
            return cache
        }
    }
}

final actor TrackCache {
    typealias Download = @Sendable (URLRequest) async throws -> (URL, URLResponse)

    struct CachedFile: Sendable {
        let url: URL
        let fileExtension: String
        let size: Int64
    }

    private struct Key: Hashable {
        let songID: Int64
        let quality: String
    }

    private struct InFlight {
        let id: UUID
        let task: Task<URL, Error>
        let generation: UInt64
        var waiters: [UUID: CheckedContinuation<URL, Error>] = [:]
    }

    private struct CacheFile {
        let url: URL
        let size: Int64
        let lastUsed: Date
    }

    private struct Metadata: Codable {
        let fileExtension: String
        let size: Int64
    }

    private struct AudioFileInfo {
        let fileExtension: String
        let size: Int64
    }

    private static let supportedExtensions = ["mp3", "flac", "ogg", "wav", "m4a"]
    private static let quotaExtensions = Set(supportedExtensions + ["range"])
    private nonisolated static let registry = TrackCacheRegistry()

    nonisolated let directory: URL
    private let download: Download
    private let byteLimit: Int64
    private let limiter: TrackCacheDownloadLimiter
    private let minimumTrimInterval: TimeInterval
    private let beforeReadyLookup: (@Sendable () async -> Void)?
    private var inFlight: [Key: InFlight] = [:]
    private var pins: [String: Int] = [:]
    private var pendingDeletePaths: Set<String> = []
    private var cacheGeneration: UInt64 = 0
    private var clearDepth = 0
    private var lastTrimAt: Date?
    private(set) var trimRunCount = 0
    private(set) var migrationCount = 0
    var isClearing: Bool { clearDepth > 0 }

    init(
        directory: URL? = nil,
        byteLimit: Int64 = 2 * 1_024 * 1_024 * 1_024,
        maximumConcurrentDownloads: Int = 2,
        minimumTrimInterval: TimeInterval = 30,
        beforeReadyLookup: (@Sendable () async -> Void)? = nil,
        download: @escaping Download = { try await URLSession.shared.download(for: $0) }
    ) {
        self.directory = directory
            ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appending(path: "TinyCloudMusic", directoryHint: .isDirectory)
                .appending(path: "StreamCache", directoryHint: .isDirectory)
        self.byteLimit = max(0, byteLimit)
        self.minimumTrimInterval = max(0, minimumTrimInterval)
        self.beforeReadyLookup = beforeReadyLookup
        limiter = TrackCacheDownloadLimiter(limit: maximumConcurrentDownloads)
        self.download = download
    }

    nonisolated static func shared(directory: URL) -> TrackCache {
        registry.cache(for: directory)
    }

    deinit {
        for request in inFlight.values {
            request.task.cancel()
            request.waiters.values.forEach { $0.resume(throwing: CancellationError()) }
        }
    }

    nonisolated func fileURL(for songID: Int64, quality: String = "standard") -> URL {
        let quality = Self.cacheComponent(quality)
        return directory
            .appending(path: quality, directoryHint: .isDirectory)
            .appending(path: "\(songID).\(Self.fileExtension(for: quality))", directoryHint: .notDirectory)
    }

    nonisolated func manages(_ url: URL) -> Bool {
        url.standardizedFileURL.path.hasPrefix(directory.standardizedFileURL.path + "/")
    }

    func readyFile(for songID: Int64, quality: String = "standard") async -> URL? {
        await readyCachedFile(for: songID, quality: quality)?.url
    }

    func readyPinnedFile(for songID: Int64, quality: String = "standard") async -> URL? {
        if let beforeReadyLookup { await beforeReadyLookup() }
        guard clearDepth == 0,
              !Task.isCancelled,
              let url = readyCachedFileNow(for: songID, quality: quality)?.url,
              pin(url)
        else { return nil }
        return url
    }

    func readyCachedFile(for songID: Int64, quality: String = "standard") async -> CachedFile? {
        if let beforeReadyLookup { await beforeReadyLookup() }
        guard clearDepth == 0, !Task.isCancelled else { return nil }
        return readyCachedFileNow(for: songID, quality: quality)
    }

    private func readyCachedFileNow(for songID: Int64, quality: String) -> CachedFile? {
        let quality = Self.cacheComponent(quality)
        for url in candidateURLs(for: songID, quality: quality) {
            let path = url.standardizedFileURL.path
            guard !pendingDeletePaths.contains(path),
                  let info = Self.audioFileInfo(at: url)
            else { continue }

            let metadataURL = Self.metadataURL(for: url)
            let hasMetadata = FileManager.default.fileExists(atPath: metadataURL.path)
            if hasMetadata {
                guard let data = try? Data(contentsOf: metadataURL),
                      let metadata = try? PropertyListDecoder().decode(Metadata.self, from: data),
                      metadata.size == info.size,
                      metadata.fileExtension == info.fileExtension
                else { continue }
            }
            guard let cached = migrateIfNeeded(
                url,
                songID: songID,
                quality: quality,
                info: info,
                needsMetadata: !hasMetadata
            ) else { continue }
            touch(cached.url)
            return cached
        }
        return nil
    }

    func cache(songID: Int64, quality: String = "standard", from source: URL) async throws -> URL {
        try Task.checkCancellation()
        let generation = cacheGeneration
        if let ready = await readyFile(for: songID, quality: quality) {
            return ready
        }
        try Task.checkCancellation()
        guard clearDepth == 0, generation == cacheGeneration else { throw CancellationError() }
        let key = Key(songID: songID, quality: Self.cacheComponent(quality))

        let requestID: UUID
        if let existing = inFlight[key] {
            requestID = existing.id
        } else {
            let id = UUID()
            let directory = directory
            let download = download
            let limiter = limiter
            let task = Task {
                try await Self.download(
                    source: source,
                    directory: directory,
                    limiter: limiter,
                    download: download
                )
            }
            inFlight[key] = InFlight(id: id, task: task, generation: generation)
            requestID = id
            Task { [weak self, task] in
                let result = await task.result
                if let self {
                    await self.complete(result, for: key, requestID: id)
                } else if case let .success(temporaryURL) = result {
                    try? FileManager.default.removeItem(at: temporaryURL)
                }
            }
        }

        let waiterID = UUID()
        let result = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
                guard var request = inFlight[key], request.id == requestID else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                guard !Task.isCancelled else {
                    if request.waiters.isEmpty {
                        inFlight[key] = nil
                        request.task.cancel()
                    }
                    continuation.resume(throwing: CancellationError())
                    return
                }
                request.waiters[waiterID] = continuation
                inFlight[key] = request
            }
        } onCancel: {
            Task { await self.cancelWaiter(waiterID, for: key, requestID: requestID) }
        }
        try Task.checkCancellation()
        return result
    }

    func finalize(
        _ downloadedFile: URL,
        for songID: Int64,
        quality: String = "standard",
        storedExtension: String? = nil
    ) throws -> URL {
        guard clearDepth == 0 else { throw CancellationError() }
        if let cached = try existingCachedFile(for: songID, quality: quality) {
            if downloadedFile.standardizedFileURL != cached.url.standardizedFileURL {
                try? FileManager.default.removeItem(at: downloadedFile)
            }
            return cached.url
        }
        let url = try Self.finalize(
            downloadedFile,
            for: songID,
            quality: quality,
            storedExtension: storedExtension,
            directory: directory
        )
        finalizeInstall(url)
        return url
    }

    func storeCopy(
        of source: URL,
        for songID: Int64,
        quality: String,
        fileExtension: String
    ) async throws -> CachedFile {
        try Task.checkCancellation()
        let generation = cacheGeneration
        if let cached = await readyCachedFile(for: songID, quality: quality) { return cached }
        try Task.checkCancellation()
        guard clearDepth == 0, generation == cacheGeneration else { throw CancellationError() }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let staged = directory.appending(path: "\(UUID().uuidString).cache-part")
        defer { try? FileManager.default.removeItem(at: staged) }
        try FileManager.default.copyItem(at: source, to: staged)
        try Task.checkCancellation()
        if let cached = try existingCachedFile(
            for: songID,
            quality: quality,
            returningProtected: source.pathExtension.lowercased() == "range"
        ) { return cached }
        _ = try Self.finalize(
            staged,
            for: songID,
            quality: quality,
            storedExtension: fileExtension,
            directory: directory
        )
        guard let cached = readyCachedFileNow(for: songID, quality: quality) else {
            throw TrackCacheError.emptyDownload
        }
        finalizeInstall(cached.url)
        return cached
    }

    func recordPartialFileAccess(_ url: URL) {
        let url = url.standardizedFileURL
        let path = url.path
        guard manages(url),
              url.pathExtension.lowercased() == "range",
              !pendingDeletePaths.contains(path),
              (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        else { return }
        finalizeInstall(url)
    }

    func invalidateCachedFile(_ url: URL) {
        let url = url.standardizedFileURL
        let path = url.path
        guard manages(url),
              Self.supportedExtensions.contains(url.pathExtension.lowercased()),
              Self.audioFileInfo(at: url) != nil
        else {
            return
        }
        let matchingKeys = inFlight.keys.filter { key in
            candidateURLs(for: key.songID, quality: key.quality)
                .contains { $0.standardizedFileURL.path == path }
        }
        for key in matchingKeys {
            guard let request = inFlight.removeValue(forKey: key) else { continue }
            request.task.cancel()
            request.waiters.values.forEach { $0.resume(throwing: CancellationError()) }
        }
        try? FileManager.default.removeItem(at: Self.metadataURL(for: url))
        if pins[path] != nil {
            pendingDeletePaths.insert(path)
        } else {
            try? FileManager.default.removeItem(at: url)
        }
    }

    @discardableResult
    func pin(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(directory.standardizedFileURL.path + "/"),
              !pendingDeletePaths.contains(path),
              FileManager.default.fileExists(atPath: path)
        else { return false }
        pins[path, default: 0] += 1
        return true
    }

    func unpin(_ url: URL) {
        let path = url.standardizedFileURL.path
        guard let count = pins[path] else { return }
        if count > 1 {
            pins[path] = count - 1
            return
        }
        pins[path] = nil
        guard pendingDeletePaths.remove(path) != nil else { return }
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: Self.metadataURL(for: url))
    }

    func clear() async throws {
        cacheGeneration &+= 1
        clearDepth += 1
        defer { clearDepth -= 1 }
        let tasks = inFlight.values.map(\.task)
        tasks.forEach { $0.cancel() }
        for task in tasks { _ = await task.result }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        let files = enumerator.compactMap { value -> URL? in
            guard let url = value as? URL,
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
            else { return nil }
            return url
        }
        for url in files {
            let path = url.standardizedFileURL.path
            if pins[path] != nil {
                pendingDeletePaths.insert(path)
                try? FileManager.default.removeItem(at: Self.metadataURL(for: url))
                continue
            }
            if url.pathExtension == "plist" {
                let audioPath = url.deletingPathExtension().standardizedFileURL.path
                if pins[audioPath] != nil {
                    pendingDeletePaths.insert(audioPath)
                }
            }
            if FileManager.default.fileExists(atPath: path) {
                try FileManager.default.removeItem(at: url)
            }
        }
        lastTrimAt = nil
    }

    private static func download(
        source: URL,
        directory: URL,
        limiter: TrackCacheDownloadLimiter,
        download: Download
    ) async throws -> URL {
        try await limiter.acquire()
        do {
            try Task.checkCancellation()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var request = URLRequest(url: source)
            request.timeoutInterval = 60
            let (temporaryURL, response) = try await download(request)
            do {
                guard let response = response as? HTTPURLResponse,
                      (200..<300).contains(response.statusCode),
                      !isRejectedContentType(response.mimeType)
                else { throw TrackCacheError.invalidResponse }
                if response.expectedContentLength > 0 {
                    let size = try temporaryURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                    guard Int64(size) == response.expectedContentLength else {
                        throw TrackCacheError.invalidResponse
                    }
                }
                try Task.checkCancellation()
            } catch {
                try? FileManager.default.removeItem(at: temporaryURL)
                throw error
            }
            await limiter.release()
            return temporaryURL
        } catch {
            await limiter.release()
            throw error
        }
    }

    private static func finalize(
        _ downloadedFile: URL,
        for songID: Int64,
        quality: String,
        storedExtension: String?,
        directory: URL
    ) throws -> URL {
        let fileManager = FileManager.default
        guard let info = audioFileInfo(at: downloadedFile) else { throw TrackCacheError.emptyDownload }
        let quality = cacheComponent(quality)
        let finalURL = directory
            .appending(path: quality, directoryHint: .isDirectory)
            .appending(path: "\(songID).\(info.fileExtension)", directoryHint: .notDirectory)
        let partURL = finalURL.appendingPathExtension("\(UUID().uuidString).part")

        try fileManager.createDirectory(at: finalURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fileManager.removeItem(at: partURL)
        defer { try? fileManager.removeItem(at: partURL) }

        try fileManager.moveItem(at: downloadedFile, to: partURL)
        let stagedValues = try partURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard stagedValues.isRegularFile == true, (stagedValues.fileSize ?? 0) > 0 else {
            throw TrackCacheError.emptyDownload
        }

        let metadataURL = metadataURL(for: finalURL)
        try? fileManager.removeItem(at: finalURL)
        try? fileManager.removeItem(at: metadataURL)
        do {
            try fileManager.moveItem(at: partURL, to: finalURL)
            let metadata = Metadata(
                fileExtension: info.fileExtension,
                size: info.size
            )
            try PropertyListEncoder().encode(metadata).write(to: metadataURL, options: .atomic)
        } catch {
            try? fileManager.removeItem(at: finalURL)
            try? fileManager.removeItem(at: metadataURL)
            throw error
        }
        return finalURL
    }

    private func complete(_ result: Result<URL, Error>, for key: Key, requestID: UUID) {
        guard let request = inFlight[key], request.id == requestID else {
            if case let .success(temporaryURL) = result {
                try? FileManager.default.removeItem(at: temporaryURL)
            }
            return
        }
        inFlight[key] = nil
        let settled: Result<URL, Error>
        switch result {
        case let .success(temporaryURL):
            defer { try? FileManager.default.removeItem(at: temporaryURL) }
            guard clearDepth == 0, request.generation == cacheGeneration else {
                request.waiters.values.forEach { $0.resume(throwing: CancellationError()) }
                return
            }
            do {
                let url: URL
                if let cached = try existingCachedFile(
                    for: key.songID,
                    quality: key.quality
                ) {
                    url = cached.url
                } else {
                    url = try Self.finalize(
                        temporaryURL,
                        for: key.songID,
                        quality: key.quality,
                        storedExtension: nil,
                        directory: directory
                    )
                }
                finalizeInstall(url)
                settled = .success(url)
            } catch {
                settled = .failure(error)
            }
        case let .failure(error):
            settled = .failure(error)
        }
        request.waiters.values.forEach { $0.resume(with: settled) }
    }

    private func cancelWaiter(_ waiterID: UUID, for key: Key, requestID: UUID) {
        guard var request = inFlight[key], request.id == requestID,
              let continuation = request.waiters.removeValue(forKey: waiterID)
        else { return }
        if request.waiters.isEmpty {
            inFlight[key] = nil
            request.task.cancel()
        } else {
            inFlight[key] = request
        }
        continuation.resume(throwing: CancellationError())
    }

    private func candidateURLs(for songID: Int64, quality: String) -> [URL] {
        let preferred = fileURL(for: songID, quality: quality)
        return [preferred] + Self.supportedExtensions
            .filter { $0 != preferred.pathExtension }
            .map { preferred.deletingPathExtension().appendingPathExtension($0) }
    }

    private func migrateIfNeeded(
        _ url: URL,
        songID: Int64,
        quality: String,
        info: AudioFileInfo,
        needsMetadata: Bool
    ) -> CachedFile? {
        let target = directory
            .appending(path: quality, directoryHint: .isDirectory)
            .appending(path: "\(songID).\(info.fileExtension)", directoryHint: .notDirectory)
        let requiresMove = url.standardizedFileURL != target.standardizedFileURL
        guard !pendingDeletePaths.contains(target.standardizedFileURL.path) else { return nil }
        if !requiresMove, !needsMetadata {
            return CachedFile(url: url, fileExtension: info.fileExtension, size: info.size)
        }

        let fileManager = FileManager.default
        let oldMetadataURL = Self.metadataURL(for: url)
        do {
            if requiresMove {
                guard !fileManager.fileExists(atPath: target.path) else { return nil }
                try fileManager.moveItem(at: url, to: target)
            }
            let metadata = Metadata(fileExtension: info.fileExtension, size: info.size)
            try PropertyListEncoder().encode(metadata).write(
                to: Self.metadataURL(for: target),
                options: .atomic
            )
            if requiresMove { try? fileManager.removeItem(at: oldMetadataURL) }
            migrationCount += 1
            return CachedFile(url: target, fileExtension: info.fileExtension, size: info.size)
        } catch {
            if requiresMove,
               fileManager.fileExists(atPath: target.path),
               !fileManager.fileExists(atPath: url.path) {
                try? fileManager.moveItem(at: target, to: url)
            }
            return nil
        }
    }

    private func protectedPaths(including url: URL) -> Set<String> {
        Set(inFlight.keys.flatMap { key in
            candidateURLs(for: key.songID, quality: key.quality).map(\.standardizedFileURL.path)
        })
            .union(pins.keys)
            .union([url.standardizedFileURL.path])
    }

    private func existingCachedFile(
        for songID: Int64,
        quality: String,
        returningProtected: Bool = false
    ) throws -> CachedFile? {
        if let cached = readyCachedFileNow(for: songID, quality: quality) { return cached }
        var protectedFileExists = false
        for url in candidateURLs(for: songID, quality: Self.cacheComponent(quality)) {
            let path = url.standardizedFileURL.path
            guard FileManager.default.fileExists(atPath: path),
                  pins[path] != nil || pendingDeletePaths.contains(path)
            else { continue }
            protectedFileExists = true
            if returningProtected, let info = Self.audioFileInfo(at: url) {
                return CachedFile(url: url, fileExtension: info.fileExtension, size: info.size)
            }
        }
        guard !protectedFileExists else { throw CocoaError(.fileWriteFileExists) }
        return nil
    }

    private func finalizeInstall(_ url: URL) {
        touch(url)
        trimCacheIfNeeded(keeping: protectedPaths(including: url))
    }

    private func touch(_ url: URL) {
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
    }

    private func trimCacheIfNeeded(keeping protectedPaths: Set<String>) {
        let now = Date()
        guard lastTrimAt.map({ now.timeIntervalSince($0) >= minimumTrimInterval }) ?? true else { return }
        lastTrimAt = now
        trimRunCount += 1
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [
                .isRegularFileKey, .fileSizeKey, .fileAllocatedSizeKey,
                .contentAccessDateKey, .contentModificationDateKey
            ],
            options: [.skipsHiddenFiles]
        ) else { return }

        // ponytail: scan on completed fills; add a persistent index only if cache size makes this measurable.
        let files = enumerator.compactMap { value -> CacheFile? in
            guard let url = value as? URL else { return nil }
            let fileExtension = url.pathExtension.lowercased()
            guard Self.quotaExtensions.contains(fileExtension),
                  let values = try? url.resourceValues(forKeys: [
                      .isRegularFileKey, .fileSizeKey, .fileAllocatedSizeKey,
                      .contentAccessDateKey, .contentModificationDateKey
                  ]),
                  values.isRegularFile == true
            else { return nil }
            let size = fileExtension == "range"
                ? (values.fileAllocatedSize ?? values.fileSize)
                : values.fileSize
            guard let size,
                  size > 0
            else { return nil }
            return CacheFile(
                url: url,
                size: Int64(size),
                lastUsed: max(values.contentAccessDate ?? .distantPast, values.contentModificationDate ?? .distantPast)
            )
        }
        var total = files.reduce(Int64(0)) { $0 + $1.size }
        guard total > byteLimit else { return }
        for file in files.sorted(by: { $0.lastUsed < $1.lastUsed })
        where total > byteLimit && !protectedPaths.contains(file.url.standardizedFileURL.path) {
            guard (try? FileManager.default.removeItem(at: file.url)) != nil else { continue }
            try? FileManager.default.removeItem(at: Self.metadataURL(for: file.url))
            total -= file.size
        }
    }

    private nonisolated static func isRejectedContentType(_ mimeType: String?) -> Bool {
        guard let mimeType = mimeType?.lowercased() else { return false }
        return mimeType == "text/html"
            || mimeType == "application/xhtml+xml"
            || mimeType == "application/json"
            || mimeType == "text/json"
            || mimeType.hasSuffix("+json")
    }

    private nonisolated static func audioFileInfo(at url: URL) -> AudioFileInfo? {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true,
              let fileSize = values.fileSize,
              fileSize >= 2,
              let handle = try? FileHandle(forReadingFrom: url)
        else { return nil }
        defer { try? handle.close() }
        guard let bytes = try? handle.read(upToCount: 16).map({ [UInt8]($0) }) else { return nil }

        func matches(_ value: String, at offset: Int = 0) -> Bool {
            let pattern = Array(value.utf8)
            guard bytes.count >= offset + pattern.count else { return false }
            return bytes[offset..<(offset + pattern.count)].elementsEqual(pattern)
        }
        if matches("fLaC") {
            return AudioFileInfo(fileExtension: "flac", size: Int64(fileSize))
        }
        if matches("ID3") || (bytes[0] == 0xff && bytes[1] & 0xe0 == 0xe0) {
            return AudioFileInfo(fileExtension: "mp3", size: Int64(fileSize))
        }
        if matches("OggS") {
            return AudioFileInfo(fileExtension: "ogg", size: Int64(fileSize))
        }
        if matches("RIFF"), matches("WAVE", at: 8) {
            return AudioFileInfo(fileExtension: "wav", size: Int64(fileSize))
        }
        if matches("ftyp", at: 4), ["M4A ", "M4B ", "M4P "].contains(where: { matches($0, at: 8) }) {
            return AudioFileInfo(fileExtension: "m4a", size: Int64(fileSize))
        }
        return nil
    }

    private nonisolated static func cacheComponent(_ quality: String) -> String {
        quality.range(of: #"^[A-Za-z0-9_-]{1,32}$"#, options: .regularExpression) == nil
            ? "unknown"
            : quality.lowercased()
    }

    private nonisolated static func fileExtension(for quality: String) -> String {
        switch quality {
        case "lossless", "hires", "jyeffect", "dolby", "sky", "jymaster": "flac"
        default: "mp3"
        }
    }

    private nonisolated static func metadataURL(for url: URL) -> URL {
        url.appendingPathExtension("metadata.plist")
    }

}
