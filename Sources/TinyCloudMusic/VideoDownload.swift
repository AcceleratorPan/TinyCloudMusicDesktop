import Foundation

enum VideoFileDownload {
    static func download(
        _ url: URL,
        title: String,
        resolution: Int,
        to directory: URL,
        configuration: URLSessionConfiguration = .ephemeral,
        progress: @escaping @Sendable (Double?) -> Void
    ) async throws -> URL {
        guard VideoPlaybackURLPolicy.isAllowed(url), resolution > 0 else {
            throw VideoLibraryError.unsafePlaybackURL
        }

        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 24 * 60 * 60
        let seedSession = URLSession(configuration: configuration)
        defer { seedSession.invalidateAndCancel() }
        let transfer = MusicDownloadTransfer(
            session: seedSession,
            progress: { written, expected, responseExpected in
                let total = max(expected, responseExpected)
                progress(total > 0 ? min(1, max(0, Double(written) / Double(total))) : nil)
            },
            allowsRequest: { $0.url.map(VideoPlaybackURLPolicy.isAllowed) == true }
        )
        defer { transfer.invalidate() }

        let result: MusicDownloadTransferResult
        do {
            result = try await transfer.download(
                request: URLRequest(url: url, timeoutInterval: 60),
                resumeData: nil
            )
        } catch is MusicDownloadTransferPaused {
            throw CancellationError()
        }
        defer { try? FileManager.default.removeItem(at: result.temporaryURL) }
        guard let response = result.response as? HTTPURLResponse else {
            throw EAPIError.invalidResponse
        }
        guard (200..<300).contains(response.statusCode) else {
            throw EAPIError.http(response.statusCode)
        }
        guard response.url.map(VideoPlaybackURLPolicy.isAllowed) == true else {
            throw VideoLibraryError.unsafePlaybackURL
        }
        try Task.checkCancellation()
        guard (try? validatedMP4FileSize(at: result.temporaryURL)) != nil else {
            throw VideoLibraryError.unavailable("视频下载响应无效")
        }

        let hasSecurityScope = directory.startAccessingSecurityScopedResource()
        defer { if hasSecurityScope { directory.stopAccessingSecurityScopedResource() } }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let safeTitle = MusicDownloadFiles.sanitizedFileName(title)
        let targets = MusicDownloadFiles.availableTargets(
            in: directory,
            stem: "\(safeTitle.isEmpty ? "视频" : safeTitle) - \(resolution)P",
            audioExtension: "mp4"
        )
        do {
            try MusicDownloadFiles.stageDownloadedFile(result.temporaryURL, at: targets.audioPart)
            try Task.checkCancellation()
            try MusicDownloadFiles.commit(partURL: targets.audioPart, finalURL: targets.audioFinal)
        } catch {
            try? FileManager.default.removeItem(at: targets.audioPart)
            throw error
        }
        progress(1)
        return targets.audioFinal
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
