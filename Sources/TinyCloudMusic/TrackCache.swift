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

    nonisolated let directory: URL
    private let download: Download
    private let byteLimit: Int64
    private let limiter: TrackCacheDownloadLimiter
    private var inFlight: [Key: InFlight] = [:]

    init(
        directory: URL? = nil,
        byteLimit: Int64 = 2 * 1_024 * 1_024 * 1_024,
        maximumConcurrentDownloads: Int = 2,
        download: @escaping Download = { try await URLSession.shared.download(for: $0) }
    ) {
        self.directory = directory
            ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appending(path: "TinyCloudMusic", directoryHint: .isDirectory)
                .appending(path: "StreamCache", directoryHint: .isDirectory)
        self.byteLimit = max(0, byteLimit)
        limiter = TrackCacheDownloadLimiter(limit: maximumConcurrentDownloads)
        self.download = download
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

    nonisolated func readyFile(for songID: Int64, quality: String = "standard") -> URL? {
        readyCachedFile(for: songID, quality: quality)?.url
    }

    nonisolated func readyCachedFile(for songID: Int64, quality: String = "standard") -> CachedFile? {
        let url = fileURL(for: songID, quality: quality)
        guard Self.isValidAudioFile(url),
              let data = try? Data(contentsOf: Self.metadataURL(for: url)),
              let metadata = try? PropertyListDecoder().decode(Metadata.self, from: data),
              metadata.size > 0,
              (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) == metadata.size
        else { return nil }
        return CachedFile(url: url, fileExtension: metadata.fileExtension, size: metadata.size)
    }

    func cache(songID: Int64, quality: String = "standard", from source: URL) async throws -> URL {
        try Task.checkCancellation()
        if let ready = readyFile(for: songID, quality: quality) {
            touch(ready)
            trimCache(keeping: protectedPaths(including: ready))
            return ready
        }
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
                    songID: songID,
                    quality: key.quality,
                    source: source,
                    directory: directory,
                    limiter: limiter,
                    download: download
                )
            }
            inFlight[key] = InFlight(id: id, task: task)
            requestID = id
            Task { [weak self, task] in
                let result = await task.result
                await self?.complete(result, for: key, requestID: id)
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

    nonisolated func finalize(
        _ downloadedFile: URL,
        for songID: Int64,
        quality: String = "standard",
        storedExtension: String? = nil
    ) throws -> URL {
        try Self.finalize(
            downloadedFile,
            for: songID,
            quality: quality,
            storedExtension: storedExtension,
            directory: directory
        )
    }

    func storeCopy(
        of source: URL,
        for songID: Int64,
        quality: String,
        fileExtension: String
    ) throws -> CachedFile {
        if let cached = readyCachedFile(for: songID, quality: quality) { return cached }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let staged = directory.appending(path: "\(UUID().uuidString).cache-part")
        defer { try? FileManager.default.removeItem(at: staged) }
        try FileManager.default.copyItem(at: source, to: staged)
        _ = try Self.finalize(
            staged,
            for: songID,
            quality: quality,
            storedExtension: fileExtension,
            directory: directory
        )
        guard let cached = readyCachedFile(for: songID, quality: quality) else {
            throw TrackCacheError.emptyDownload
        }
        return cached
    }

    private static func download(
        songID: Int64,
        quality: String,
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
            defer { try? FileManager.default.removeItem(at: temporaryURL) }
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
            let result = try finalize(
                temporaryURL,
                for: songID,
                quality: quality,
                storedExtension: nil,
                directory: directory
            )
            try Task.checkCancellation()
            await limiter.release()
            return result
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
        guard isValidAudioFile(downloadedFile) else { throw TrackCacheError.emptyDownload }
        let quality = cacheComponent(quality)
        let finalURL = directory
            .appending(path: quality, directoryHint: .isDirectory)
            .appending(path: "\(songID).\(fileExtension(for: quality))", directoryHint: .notDirectory)
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
                fileExtension: normalizedExtension(storedExtension ?? finalURL.pathExtension),
                size: Int64(stagedValues.fileSize ?? 0)
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
        guard let request = inFlight[key], request.id == requestID else { return }
        inFlight[key] = nil
        if case let .success(url) = result {
            touch(url)
            trimCache(keeping: protectedPaths(including: url))
        }
        request.waiters.values.forEach { $0.resume(with: result) }
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

    private func protectedPaths(including url: URL) -> Set<String> {
        Set(inFlight.keys.map { fileURL(for: $0.songID, quality: $0.quality).standardizedFileURL.path })
            .union([url.standardizedFileURL.path])
    }

    private func touch(_ url: URL) {
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
    }

    private func trimCache(keeping protectedPaths: Set<String>) {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [
                .isRegularFileKey, .fileSizeKey, .contentAccessDateKey, .contentModificationDateKey
            ],
            options: [.skipsHiddenFiles]
        ) else { return }

        // ponytail: scan on completed fills; add a persistent index only if cache size makes this measurable.
        let files = enumerator.compactMap { value -> CacheFile? in
            guard let url = value as? URL,
                  ["mp3", "flac"].contains(url.pathExtension.lowercased()),
                  let values = try? url.resourceValues(forKeys: [
                      .isRegularFileKey, .fileSizeKey, .contentAccessDateKey, .contentModificationDateKey
                  ]),
                  values.isRegularFile == true,
                  let size = values.fileSize,
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

    private nonisolated static func isValidAudioFile(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true,
              (values.fileSize ?? 0) >= 2,
              let handle = try? FileHandle(forReadingFrom: url)
        else { return false }
        defer { try? handle.close() }
        guard let bytes = try? handle.read(upToCount: 16).map({ [UInt8]($0) }) else { return false }

        func matches(_ value: String, at offset: Int = 0) -> Bool {
            let pattern = Array(value.utf8)
            guard bytes.count >= offset + pattern.count else { return false }
            return bytes[offset..<(offset + pattern.count)].elementsEqual(pattern)
        }
        return matches("ID3")
            || matches("fLaC")
            || matches("OggS")
            || matches("RIFF")
            || matches("ftyp", at: 4)
            || (bytes[0] == 0xff && bytes[1] & 0xe0 == 0xe0)
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

    private nonisolated static func normalizedExtension(_ value: String) -> String {
        let value = value.lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
        return value.isEmpty ? "mp3" : String(value.prefix(10))
    }
}
