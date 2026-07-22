import Foundation

struct MusicDownloadHTTPError: LocalizedError, Equatable, Sendable {
    let statusCode: Int
    let retryAfter: TimeInterval?

    var errorDescription: String? {
        switch statusCode {
        case 401, 403: "下载地址已失效，重新获取后仍无法下载"
        case 404, 410: "下载文件已失效或不存在"
        case 429: "下载请求过于频繁，请稍后重试"
        default: "下载请求失败（HTTP \(statusCode)）"
        }
    }
}

struct MusicDownloadRetryPolicy: Equatable, Sendable {
    static let standard = MusicDownloadRetryPolicy()

    let maximumAttempts: Int
    let baseDelay: TimeInterval
    let maximumDelay: TimeInterval

    init(maximumAttempts: Int = 4, baseDelay: TimeInterval = 0.75, maximumDelay: TimeInterval = 8) {
        self.maximumAttempts = max(1, maximumAttempts)
        self.baseDelay = max(0, baseDelay)
        self.maximumDelay = max(0, maximumDelay)
    }

    var maximumRetryCount: Int { max(0, maximumAttempts - 1) }

    func delay(forRetry retry: Int, retryAfter: TimeInterval? = nil) -> TimeInterval {
        if let retryAfter, retryAfter >= 0 {
            return min(retryAfter, 60)
        }
        let exponent = max(0, retry - 1)
        return min(baseDelay * pow(2, Double(exponent)), maximumDelay)
    }

    func shouldRetry(_ error: Error) -> Bool {
        if error is CancellationError { return false }
        if let error = error as? MusicDownloadHTTPError {
            return [401, 403, 404, 408, 410, 425, 429].contains(error.statusCode)
                || (500...599).contains(error.statusCode)
        }
        if let error = error as? MusicDownloadError, error == .invalidResponse { return true }
        if let error = error as? URLError {
            switch error.code {
            case .timedOut, .cannotFindHost, .cannotConnectToHost, .networkConnectionLost,
                 .dnsLookupFailed, .notConnectedToInternet, .resourceUnavailable,
                 .internationalRoamingOff, .callIsActive, .dataNotAllowed,
                 .secureConnectionFailed, .cannotLoadFromNetwork, .backgroundSessionWasDisconnected:
                return true
            default:
                return false
            }
        }
        if let error = error as? EAPIError {
            switch error {
            case let .http(status):
                return status == 408 || status == 429 || (500...599).contains(status)
            case let .service(code, _):
                return code == 408 || code == 429 || code >= 500
            case .invalidResponse:
                return true
            default:
                return false
            }
        }
        return false
    }

    func shouldRefreshSource(after error: Error) -> Bool {
        if let error = error as? MusicDownloadHTTPError {
            return [401, 403, 404, 410].contains(error.statusCode)
        }
        return false
    }

    func retryAfter(from response: HTTPURLResponse) -> TimeInterval? {
        guard let rawValue = response.value(forHTTPHeaderField: "Retry-After")?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !rawValue.isEmpty
        else { return nil }
        if let seconds = TimeInterval(rawValue), seconds >= 0 { return seconds }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"
        guard let date = formatter.date(from: rawValue) else { return nil }
        return max(0, date.timeIntervalSinceNow)
    }

    func resumeData(from error: Error) -> Data? {
        let error = error as NSError
        return error.userInfo[NSURLSessionDownloadTaskResumeData] as? Data
    }
}

enum MusicDownloadUpdate: Sendable {
    case metadata(level: String?, expectedBytes: Int64?)
    case progress(Double)
    case retrying(
        attempt: Int,
        total: Int,
        progress: Double?,
        resumeData: Data?,
        discardsResumeData: Bool
    )
}

struct MusicDownloadFailure: LocalizedError, @unchecked Sendable {
    let underlying: Error
    let resumeData: Data?
    let attempts: Int

    var errorDescription: String? {
        let message = (underlying as? LocalizedError)?.errorDescription ?? underlying.localizedDescription
        return attempts > 1 ? "已重试 \(attempts - 1) 次：\(message)" : message
    }
}

actor MusicDownloadTargetAllocator {
    static let shared = MusicDownloadTargetAllocator()

    private var reservedAudioPaths: Set<String> = []

    func reserve(
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
            let audioPath = audioFinal.standardizedFileURL.path
            if !reservedAudioPaths.contains(audioPath),
               [audioFinal, lyricFinal].allSatisfy({ !fileManager.fileExists(atPath: $0.path) }) {
                reservedAudioPaths.insert(audioPath)
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

    func release(_ targets: MusicDownloadTargets) {
        reservedAudioPaths.remove(targets.audioFinal.standardizedFileURL.path)
    }
}

final class MusicDownloadResumeStore: @unchecked Sendable {
    private struct Record: Codable {
        let signature: String
        let resumeData: Data
        let savedAt: Date
    }

    static let shared = MusicDownloadResumeStore()

    private let directory: URL
    private let lock = NSLock()
    private let maximumAge: TimeInterval = 7 * 24 * 60 * 60

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: "TinyCloudMusic", directoryHint: .isDirectory)
            .appending(path: "DownloadResume", directoryHint: .isDirectory)
    }

    func load(for request: MusicDownloadRequest) -> Data? {
        lock.withLock {
            let url = recordURL(songID: request.songID)
            guard let data = try? Data(contentsOf: url),
                  let record = try? PropertyListDecoder().decode(Record.self, from: data),
                  record.signature == signature(for: request),
                  Date().timeIntervalSince(record.savedAt) <= maximumAge
            else {
                try? FileManager.default.removeItem(at: url)
                return nil
            }
            return record.resumeData
        }
    }

    func save(_ resumeData: Data, for request: MusicDownloadRequest) {
        guard !resumeData.isEmpty else { return }
        lock.withLock {
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let record = Record(
                    signature: signature(for: request),
                    resumeData: resumeData,
                    savedAt: Date()
                )
                let data = try PropertyListEncoder().encode(record)
                try data.write(to: recordURL(songID: request.songID), options: .atomic)
            } catch {
                // Resume persistence is best-effort; the in-memory retry path remains available.
            }
        }
    }

    func remove(songID: Int64) {
        lock.withLock {
            try? FileManager.default.removeItem(at: recordURL(songID: songID))
        }
    }

    private func recordURL(songID: Int64) -> URL {
        directory.appending(path: "\(songID).resume.plist", directoryHint: .notDirectory)
    }

    private func signature(for request: MusicDownloadRequest) -> String {
        let source: String = switch request.source {
        case .catalog: "catalog"
        case let .cloud(userID, fileName): "cloud:\(userID):\(fileName)"
        }
        return [
            String(request.songID), request.quality.rawValue, source,
            request.destination.standardizedFileURL.path,
            request.includeLyrics ? "lyrics" : "audio"
        ].joined(separator: "|")
    }
}
