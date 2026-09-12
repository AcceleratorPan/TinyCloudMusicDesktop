import Foundation

enum VideoFileDownload {
    typealias Transfer = @Sendable (
        _ request: URLRequest,
        _ resumeData: Data?,
        _ progress: @escaping @Sendable (Int64, Int64, Int64) -> Void
    ) async throws -> MusicDownloadTransferResult

    static func download(
        _ url: URL,
        title: String,
        resolution: Int,
        to directory: URL,
        cacheIdentity: String? = nil,
        cacheRoot: URL? = nil,
        resumeData: Data? = nil,
        targetAllocator: MusicDownloadTargetAllocator = .shared,
        cacheContext: MusicDownloadCacheContext? = nil,
        cacheGeneration: MusicDownloadCacheGeneration? = nil,
        cacheActivity: MusicDownloadCacheActivity? = nil,
        transferDownload: Transfer? = nil,
        configuration: URLSessionConfiguration = .ephemeral,
        backgroundIdentifier: String? = nil,
        progress: @escaping @Sendable (Double?) -> Void
    ) async throws -> URL {
        guard VideoPlaybackURLPolicy.isAllowed(url), resolution > 0 else {
            throw VideoLibraryError.unsafePlaybackURL
        }

        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 24 * 60 * 60
        let reporter = MusicDownloadProgressReporter { progress($0) }

        let result: MusicDownloadTransferResult
        do {
            let request = URLRequest(url: url, timeoutInterval: 60)
            if let transferDownload {
                result = try await transferDownload(request, resumeData) { written, expected, responseExpected in
                    reporter.update(
                        totalBytesWritten: written,
                        totalBytesExpectedToWrite: expected,
                        responseExpectedContentLength: responseExpected
                    )
                }
            } else {
                let seedSession = URLSession(configuration: configuration)
                defer { seedSession.invalidateAndCancel() }
                let transfer = MusicDownloadTransfer(
                    session: seedSession,
                    progress: { written, expected, responseExpected in
                        reporter.update(
                            totalBytesWritten: written,
                            totalBytesExpectedToWrite: expected,
                            responseExpectedContentLength: responseExpected
                        )
                    },
                    allowsRequest: { $0.url.map(VideoPlaybackURLPolicy.isAllowed) == true },
                    backgroundIdentifier: backgroundIdentifier
                )
                defer { transfer.invalidate() }
                result = try await transfer.download(request: request, resumeData: resumeData)
            }
        } catch {
            reporter.flush()
            throw error
        }
        defer { try? FileManager.default.removeItem(at: result.temporaryURL) }
        guard let response = result.response as? HTTPURLResponse else {
            throw EAPIError.invalidResponse
        }
        guard (200..<300).contains(response.statusCode) else {
            throw MusicDownloadHTTPError(statusCode: response.statusCode, retryAfter: nil)
        }
        guard response.url.map(VideoPlaybackURLPolicy.isAllowed) == true else {
            throw VideoLibraryError.unsafePlaybackURL
        }
        try Task.checkCancellation()
        guard let size = try? validatedMP4FileSize(at: result.temporaryURL),
              resumeData != nil || response.expectedContentLength <= 0 || size == response.expectedContentLength
        else {
            throw VideoLibraryError.unavailable("视频下载响应无效")
        }

        if let cacheIdentity, let cacheRoot {
            _ = try? storeCachedFile(
                result.temporaryURL,
                identity: cacheIdentity,
                resolution: resolution,
                cacheRoot: cacheRoot,
                context: cacheContext,
                generation: cacheGeneration,
                activity: cacheActivity
            )
        }
        let saved = try await materialize(
            result.temporaryURL,
            title: title,
            resolution: resolution,
            to: directory,
            targetAllocator: targetAllocator
        )
        reporter.finish()
        return saved
    }

    static func copyCachedFile(
        identity: String,
        title: String,
        resolution: Int,
        cacheRoot: URL,
        to directory: URL,
        targetAllocator: MusicDownloadTargetAllocator = .shared,
        cacheContext: MusicDownloadCacheContext? = nil,
        cacheGeneration: MusicDownloadCacheGeneration? = nil,
        cacheActivity: MusicDownloadCacheActivity? = nil
    ) async throws -> URL? {
        cacheActivity?.begin()
        defer { cacheActivity?.end() }
        guard let cached = cachedFile(
            identity: identity,
            resolution: resolution,
            cacheRoot: cacheRoot,
            context: cacheContext,
            generation: cacheGeneration
        ) else {
            return nil
        }
        return try await materialize(
            cached,
            title: title,
            resolution: resolution,
            to: directory,
            targetAllocator: targetAllocator
        )
    }

    static func cachedFile(
        identity: String,
        resolution: Int,
        cacheRoot: URL,
        context: MusicDownloadCacheContext? = nil,
        generation: MusicDownloadCacheGeneration? = nil
    ) -> URL? {
        guard !identity.isEmpty, resolution > 0 else { return nil }
        if let context, let generation, !generation.isCurrent(context) { return nil }
        let hasSecurityScope = cacheRoot.startAccessingSecurityScopedResource()
        defer { if hasSecurityScope { cacheRoot.stopAccessingSecurityScopedResource() } }
        let url = cacheURL(identity: identity, resolution: resolution, root: cacheRoot)
        let metadataURL = url.appendingPathExtension("size")
        guard let size = try? validatedMP4FileSize(at: url),
              let data = try? Data(contentsOf: metadataURL),
              let expected = Int64(String(decoding: data, as: UTF8.self)),
              size == expected
        else {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: metadataURL)
            return nil
        }
        return url
    }

    private static func materialize(
        _ source: URL,
        title: String,
        resolution: Int,
        to directory: URL,
        targetAllocator: MusicDownloadTargetAllocator
    ) async throws -> URL {
        let hasSecurityScope = directory.startAccessingSecurityScopedResource()
        defer { if hasSecurityScope { directory.stopAccessingSecurityScopedResource() } }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let safeTitle = MusicDownloadFiles.sanitizedFileName(title)
        let stem = "【\(resolution)P】\(safeTitle.isEmpty ? "视频" : safeTitle)"
        if let existing = MusicDownloadFiles.existingDownload(
            in: directory,
            stem: stem,
            audioExtension: "mp4",
            matchingAudio: source
        ) {
            return existing.audioURL
        }
        let targets = await targetAllocator.reserve(
            in: directory,
            stem: stem,
            audioExtension: "mp4"
        )
        do {
            try MusicDownloadFiles.stageCachedFile(source, at: targets.audioPart)
            try Task.checkCancellation()
            try MusicDownloadFiles.commit(partURL: targets.audioPart, finalURL: targets.audioFinal)
            await targetAllocator.release(targets)
        } catch {
            try? FileManager.default.removeItem(at: targets.audioPart)
            await targetAllocator.release(targets)
            throw error
        }
        return targets.audioFinal
    }

    private static func storeCachedFile(
        _ source: URL,
        identity: String,
        resolution: Int,
        cacheRoot: URL,
        context: MusicDownloadCacheContext?,
        generation: MusicDownloadCacheGeneration?,
        activity: MusicDownloadCacheActivity?
    ) throws -> URL? {
        activity?.begin()
        defer { activity?.end() }
        if let cached = cachedFile(
            identity: identity,
            resolution: resolution,
            cacheRoot: cacheRoot,
            context: context,
            generation: generation
        ) {
            return cached
        }
        if let context, let generation, !generation.isCurrent(context) { return nil }
        let hasSecurityScope = cacheRoot.startAccessingSecurityScopedResource()
        defer { if hasSecurityScope { cacheRoot.stopAccessingSecurityScopedResource() } }
        let destination = cacheURL(identity: identity, resolution: resolution, root: cacheRoot)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let part = destination.appendingPathExtension("\(UUID().uuidString).part")
        defer { try? FileManager.default.removeItem(at: part) }
        try FileManager.default.copyItem(at: source, to: part)
        let size = try validatedMP4FileSize(at: part)
        let install = {
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: part)
            } else {
                try FileManager.default.moveItem(at: part, to: destination)
            }
            do {
                try Data(String(size).utf8).write(
                    to: destination.appendingPathExtension("size"),
                    options: .atomic
                )
            } catch {
                try? FileManager.default.removeItem(at: destination)
                throw error
            }
        }
        if let context, let generation {
            guard try generation.withCurrent(context, install) != nil else { return nil }
        } else {
            try install()
        }
        return destination
    }

    private static func cacheURL(identity: String, resolution: Int, root: URL) -> URL {
        let key = Data(identity.utf8).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")
        return root.appending(path: "DownloadCache", directoryHint: .isDirectory)
            .appending(path: "Videos", directoryHint: .isDirectory)
            .appending(path: key, directoryHint: .isDirectory)
            .appending(path: "\(resolution).mp4", directoryHint: .notDirectory)
    }

    private static func validatedMP4FileSize(at url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        let size = Int64(values.fileSize ?? 0)
        guard values.isRegularFile == true, size >= 16 else {
            throw MusicDownloadError.invalidResponse
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let header = [UInt8](try handle.read(upToCount: 16) ?? Data())
        let boxSize = header.prefix(4).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        guard header.count == 16,
              header[4..<8].elementsEqual("ftyp".utf8),
              boxSize >= 16,
              boxSize <= UInt64(size),
              boxSize.isMultiple(of: 4)
        else { throw MusicDownloadError.invalidResponse }
        return size
    }
}
