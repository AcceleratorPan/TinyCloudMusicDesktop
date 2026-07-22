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

final actor TrackCache {
    typealias Download = @Sendable (URLRequest) async throws -> (URL, URLResponse)

    private struct Key: Hashable {
        let songID: Int64
        let quality: String
    }

    nonisolated let directory: URL
    private let download: Download
    private var inFlight: [Key: (id: UUID, task: Task<URL, Error>)] = [:]

    init(
        directory: URL? = nil,
        download: @escaping Download = { try await URLSession.shared.download(for: $0) }
    ) {
        self.directory = directory
            ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appending(path: "TinyCloudMusic", directoryHint: .isDirectory)
                .appending(path: "StreamCache", directoryHint: .isDirectory)
        self.download = download
    }

    deinit {
        inFlight.values.forEach { $0.task.cancel() }
    }

    nonisolated func fileURL(for songID: Int64, quality: String = "standard") -> URL {
        let quality = Self.cacheComponent(quality)
        return directory
            .appending(path: quality, directoryHint: .isDirectory)
            .appending(path: "\(songID).\(Self.fileExtension(for: quality))", directoryHint: .notDirectory)
    }

    nonisolated func readyFile(for songID: Int64, quality: String = "standard") -> URL? {
        let url = fileURL(for: songID, quality: quality)
        guard (try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]))
            .map({ $0.isRegularFile == true && ($0.fileSize ?? 0) > 0 }) == true
        else { return nil }
        return url
    }

    func cache(songID: Int64, quality: String = "standard", from source: URL) async throws -> URL {
        if let ready = readyFile(for: songID, quality: quality) { return ready }
        let key = Key(songID: songID, quality: Self.cacheComponent(quality))

        let entry: (id: UUID, task: Task<URL, Error>)
        if let existing = inFlight[key] {
            entry = existing
        } else {
            let id = UUID()
            let directory = directory
            let download = download
            // ponytail: a shared cache fill survives one waiter cancellation; add waiter counts only if queue churn wastes traffic.
            let task = Task {
                try await Self.download(
                    songID: songID,
                    quality: key.quality,
                    source: source,
                    directory: directory,
                    download: download
                )
            }
            entry = (id, task)
            inFlight[key] = entry
        }

        defer {
            if inFlight[key]?.id == entry.id { inFlight[key] = nil }
        }
        let result = try await entry.task.value
        try Task.checkCancellation()
        return result
    }

    nonisolated func finalize(
        _ downloadedFile: URL,
        for songID: Int64,
        quality: String = "standard"
    ) throws -> URL {
        try Self.finalize(downloadedFile, for: songID, quality: quality, directory: directory)
    }

    private static func download(
        songID: Int64,
        quality: String,
        source: URL,
        directory: URL,
        download: Download
    ) async throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var request = URLRequest(url: source)
        request.timeoutInterval = 60
        let (temporaryURL, response) = try await download(request)
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
            throw TrackCacheError.invalidResponse
        }
        try Task.checkCancellation()
        return try finalize(temporaryURL, for: songID, quality: quality, directory: directory)
    }

    private static func finalize(
        _ downloadedFile: URL,
        for songID: Int64,
        quality: String,
        directory: URL
    ) throws -> URL {
        let fileManager = FileManager.default
        let quality = cacheComponent(quality)
        let finalURL = directory
            .appending(path: quality, directoryHint: .isDirectory)
            .appending(path: "\(songID).\(fileExtension(for: quality))", directoryHint: .notDirectory)
        let partURL = finalURL.appendingPathExtension("\(UUID().uuidString).part")

        try fileManager.createDirectory(at: finalURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fileManager.removeItem(at: partURL)
        defer { try? fileManager.removeItem(at: partURL) }

        try fileManager.moveItem(at: downloadedFile, to: partURL)
        guard (try partURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) > 0 else {
            throw TrackCacheError.emptyDownload
        }

        try? fileManager.removeItem(at: finalURL)
        try fileManager.moveItem(at: partURL, to: finalURL)
        return finalURL
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
}
