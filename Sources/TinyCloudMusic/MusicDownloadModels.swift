import Foundation

enum MusicDownloadState: Equatable, Sendable {
    case queued
    case running(progress: Double?)
    case paused(progress: Double?)
    case completed(audioURL: URL, lyricURL: URL?)
    case failed(String)
    case cancelled
}

struct MusicDownloadItem: Identifiable, Equatable, Sendable {
    let id: Int64
    let title: String
    let artist: String
    let quality: String
    let expectedBytes: Int64?
}

struct MusicDownloadRequest: Equatable, Sendable {
    let songID: Int64
    let songName: String
    let artists: String
    let destination: URL
    let quality: AudioQuality
    let includeLyrics: Bool
    let source: MusicDownloadSource
    let expectedBytes: Int64?
}

enum MusicDownloadSource: Equatable, Sendable {
    case catalog
    case cloud(userID: Int64, fileName: String)
}

struct MusicDownloadResult: Sendable {
    let audioURL: URL
    let lyricURL: URL?
}

enum MusicDownloadError: LocalizedError, Equatable, Sendable {
    case unavailable
    case qualityMismatch
    case invalidResponse
    case emptyFile
    case insufficientSpace
    case destinationExists

    var errorDescription: String? {
        switch self {
        case .unavailable: "这首歌暂时无法下载"
        case .qualityMismatch: "服务端未返回要求的最高音质，已取消下载以避免降质"
        case .invalidResponse: "音频下载请求失败"
        case .emptyFile: "下载文件为空"
        case .insufficientSpace: "下载目录可用空间不足"
        case .destinationExists: "下载目标已存在"
        }
    }
}

struct MusicDownloadTargets: Sendable {
    let audioFinal: URL
    let audioPart: URL
    let lyricFinal: URL
    let lyricPart: URL
}

enum MusicDownloadFiles {
    private static let invalidCharacters = CharacterSet(charactersIn: "\\/:*?\"<>|")
        .union(.controlCharacters)

    static func sanitizedFileName(_ value: String) -> String {
        let cleaned = value.unicodeScalars
            .filter { !invalidCharacters.contains($0) }
            .map(String.init)
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned == "." || cleaned == ".." ? "" : cleaned
    }

    static func availableTargets(
        in directory: URL,
        stem: String,
        audioExtension: String,
        fileManager: FileManager = .default
    ) -> MusicDownloadTargets {
        var index = 1
        while true {
            let suffix = index == 1 ? "" : " (\(index))"
            let base = stem + suffix
            let audioFinal = directory.appending(path: base).appendingPathExtension(audioExtension)
            let lyricFinal = directory.appending(path: base).appendingPathExtension("lrc")
            if [audioFinal, lyricFinal].allSatisfy({ !fileManager.fileExists(atPath: $0.path) }) {
                let token = UUID().uuidString
                return MusicDownloadTargets(
                    audioFinal: audioFinal,
                    audioPart: audioFinal.appendingPathExtension("\(token).part"),
                    lyricFinal: lyricFinal,
                    lyricPart: lyricFinal.appendingPathExtension("\(token).part")
                )
            }
            index += 1
        }
    }

    static func existingDownload(
        in directory: URL,
        stem: String,
        audioExtension: String,
        matchingAudio source: URL? = nil,
        fileManager: FileManager = .default
    ) -> MusicDownloadResult? {
        let audioURL = directory.appending(path: stem).appendingPathExtension(audioExtension)
        guard fileManager.fileExists(atPath: audioURL.path),
              (try? validatedAudioFileSize(at: audioURL)) != nil,
              source.map({ fileManager.contentsEqual(atPath: audioURL.path, andPath: $0.path) }) ?? true
        else { return nil }
        let lyricURL = directory.appending(path: stem).appendingPathExtension("lrc")
        return MusicDownloadResult(
            audioURL: audioURL,
            lyricURL: fileManager.fileExists(atPath: lyricURL.path) ? lyricURL : nil
        )
    }

    static func stageDownloadedFile(
        _ source: URL,
        at partURL: URL,
        fileManager: FileManager = .default
    ) throws {
        try? fileManager.removeItem(at: partURL)
        do {
            try fileManager.moveItem(at: source, to: partURL)
            guard try fileSize(at: partURL) > 0 else { throw MusicDownloadError.emptyFile }
        } catch {
            try? fileManager.removeItem(at: partURL)
            throw error
        }
    }

    static func stageCachedFile(
        _ source: URL,
        at partURL: URL,
        fileManager: FileManager = .default
    ) throws {
        try? fileManager.removeItem(at: partURL)
        do {
            try fileManager.copyItem(at: source, to: partURL)
            guard try fileSize(at: partURL) > 0 else { throw MusicDownloadError.emptyFile }
        } catch {
            try? fileManager.removeItem(at: partURL)
            throw error
        }
    }

    static func cachedLyrics(for request: MusicDownloadRequest, cacheRoot: URL) -> String? {
        let root = lyricCacheURL(for: request, cacheRoot: cacheRoot)
        let hasSecurityScope = cacheRoot.startAccessingSecurityScopedResource()
        defer { if hasSecurityScope { cacheRoot.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: root),
              !data.isEmpty,
              let lyrics = String(data: data, encoding: .utf8),
              !lyrics.isEmpty
        else { return nil }
        return lyrics
    }

    static func cacheLyrics(_ lyrics: String, for request: MusicDownloadRequest, cacheRoot: URL) throws {
        guard !lyrics.isEmpty else { return }
        let url = lyricCacheURL(for: request, cacheRoot: cacheRoot)
        let hasSecurityScope = cacheRoot.startAccessingSecurityScopedResource()
        defer { if hasSecurityScope { cacheRoot.stopAccessingSecurityScopedResource() } }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(lyrics.utf8).write(to: url, options: .atomic)
    }

    static func stageData(
        _ data: Data,
        at partURL: URL,
        fileManager: FileManager = .default
    ) throws {
        guard !data.isEmpty else { throw MusicDownloadError.emptyFile }
        try? fileManager.removeItem(at: partURL)
        do {
            try data.write(to: partURL, options: .atomic)
            guard try fileSize(at: partURL) > 0 else { throw MusicDownloadError.emptyFile }
        } catch {
            try? fileManager.removeItem(at: partURL)
            throw error
        }
    }

    static func commit(
        partURL: URL,
        finalURL: URL,
        fileManager: FileManager = .default
    ) throws {
        guard try fileSize(at: partURL) > 0 else { throw MusicDownloadError.emptyFile }
        guard !fileManager.fileExists(atPath: finalURL.path) else { throw MusicDownloadError.destinationExists }
        try fileManager.moveItem(at: partURL, to: finalURL)
    }

    static func validatedAudioFileSize(at url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        let size = Int64(values.fileSize ?? 0)
        guard values.isRegularFile == true, size > 0 else { throw MusicDownloadError.invalidResponse }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let bytes = [UInt8](try handle.read(upToCount: 16) ?? Data())
        guard looksLikeAudio(bytes) else { throw MusicDownloadError.invalidResponse }
        return size
    }

    private static func looksLikeAudio(_ bytes: [UInt8]) -> Bool {
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
            || (bytes.count >= 2 && bytes[0] == 0xff && bytes[1] & 0xe0 == 0xe0)
    }

    private static func fileSize(at url: URL) throws -> Int {
        try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
    }

    private static func lyricCacheURL(for request: MusicDownloadRequest, cacheRoot: URL) -> URL {
        let source = switch request.source {
        case .catalog: "catalog"
        case let .cloud(userID, _): "cloud-\(userID)"
        }
        return cacheRoot
            .appending(path: "DownloadCache", directoryHint: .isDirectory)
            .appending(path: "Lyrics", directoryHint: .isDirectory)
            .appending(path: source, directoryHint: .isDirectory)
            .appending(path: "\(request.songID).lrc", directoryHint: .notDirectory)
    }
}

struct MusicDownloadProgressThrottle {
    private let minimumInterval: TimeInterval
    private var lastProgress: Double?
    private var lastUpdateTime: TimeInterval?

    init(minimumInterval: TimeInterval = 0.1) {
        self.minimumInterval = max(0, minimumInterval)
    }

    mutating func update(
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64,
        responseExpectedContentLength: Int64 = NSURLSessionTransferSizeUnknown,
        now: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> Double? {
        let expectedBytes = responseExpectedContentLength > 0
            ? responseExpectedContentLength
            : totalBytesExpectedToWrite
        guard expectedBytes > 0 else { return nil }
        let value = min(max(Double(totalBytesWritten) / Double(expectedBytes), 0), 1)
        guard lastProgress.map({ value > $0 }) ?? true,
              value == 1 || lastUpdateTime.map({ now - $0 >= minimumInterval }) ?? true
        else { return nil }
        lastProgress = value
        lastUpdateTime = now
        return value
    }
}
