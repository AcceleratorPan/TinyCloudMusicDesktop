import Foundation

enum MusicDownloadState: Equatable, Sendable {
    case queued
    case running(progress: Double?)
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
    case destinationExists

    var errorDescription: String? {
        switch self {
        case .unavailable: "这首歌暂时无法下载"
        case .qualityMismatch: "服务端未返回要求的最高音质，已取消下载以避免降质"
        case .invalidResponse: "音频下载请求失败"
        case .emptyFile: "下载文件为空"
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
        fileManager: FileManager = .default
    ) -> MusicDownloadResult? {
        let audioURL = directory.appending(path: stem).appendingPathExtension(audioExtension)
        guard fileManager.fileExists(atPath: audioURL.path),
              ((try? fileSize(at: audioURL)) ?? 0) > 0
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

    private static func fileSize(at url: URL) throws -> Int {
        try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
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
