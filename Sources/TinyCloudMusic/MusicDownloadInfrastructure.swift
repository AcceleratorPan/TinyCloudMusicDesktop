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
        let exponent = max(0, retry - 1)
        let exponential = min(baseDelay * pow(2, Double(exponent)), maximumDelay)
        guard let retryAfter, retryAfter >= 0 else { return exponential }
        return max(exponential, min(retryAfter, 300))
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
                return code == 408 || code == 429 || (500...599).contains(code)
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
        if let error = error as? MusicDownloadTransferPaused { return error.resumeData }
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

    private var reservedPaths: Set<String> = []
    private var cleanedDirectories: Set<String> = []

    func reserve(
        in directory: URL,
        stem: String,
        audioExtension: String,
        fileManager: FileManager = .default
    ) -> MusicDownloadTargets {
        let directoryPath = directory.standardizedFileURL.path
        if cleanedDirectories.insert(directoryPath).inserted {
            MusicDownloadPartialFiles.removeStale(in: directory, fileManager: fileManager)
        }
        var index = 1
        while true {
            let suffix = index == 1 ? "" : " (\(index))"
            let base = stem + suffix
            let audioFinal = directory.appending(path: base).appendingPathExtension(audioExtension)
            let lyricFinal = directory.appending(path: base).appendingPathExtension("lrc")
            let paths = Set([audioFinal, lyricFinal].map { $0.standardizedFileURL.path })
            if reservedPaths.isDisjoint(with: paths),
               [audioFinal, lyricFinal].allSatisfy({ !fileManager.fileExists(atPath: $0.path) }) {
                reservedPaths.formUnion(paths)
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
        reservedPaths.subtract(
            [targets.audioFinal, targets.lyricFinal].map { $0.standardizedFileURL.path }
        )
    }
}

enum MusicDownloadPartialFiles {
    private static let defaultMaximumAge: TimeInterval = 24 * 60 * 60

    @discardableResult
    static func removeStale(
        in directory: URL,
        olderThan maximumAge: TimeInterval = defaultMaximumAge,
        now: Date = Date(),
        fileManager: FileManager = .default
    ) -> Int {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .creationDateKey, .isRegularFileKey]
        guard let urls = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var removed = 0
        for url in urls where url.pathExtension == "part"
            && UUID(uuidString: url.deletingPathExtension().pathExtension) != nil {
            guard let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true,
                  let modifiedAt = values.contentModificationDate ?? values.creationDate,
                  now.timeIntervalSince(modifiedAt) > max(0, maximumAge)
            else { continue }
            do {
                try fileManager.removeItem(at: url)
                removed += 1
            } catch {
                // Cleanup is best-effort; a failed deletion must not block a download.
            }
        }
        return removed
    }
}

struct MusicDownloadRecovery: Equatable, Sendable {
    let request: MusicDownloadRequest
    let resumeData: Data?
    let savedAt: Date
}

final class MusicDownloadResumeStore: @unchecked Sendable {
    private struct StoredRequest: Codable {
        private enum Source: Codable {
            case catalog
            case cloud(userID: Int64, fileName: String)
        }

        let songID: Int64
        let songName: String
        let artists: String
        let destinationBookmark: Data?
        let destinationPath: String
        let quality: AudioQuality
        let includeLyrics: Bool
        private let source: Source
        let expectedBytes: Int64?

        init(_ request: MusicDownloadRequest) {
            songID = request.songID
            songName = request.songName
            artists = request.artists
            destinationBookmark = try? request.destination.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            destinationPath = request.destination.standardizedFileURL.path
            quality = request.quality
            includeLyrics = request.includeLyrics
            source = switch request.source {
            case .catalog: .catalog
            case let .cloud(userID, fileName): .cloud(userID: userID, fileName: fileName)
            }
            expectedBytes = request.expectedBytes
        }

        func restored() -> MusicDownloadRequest? {
            let destination: URL
            var bookmarkIsStale = false
            if let destinationBookmark,
               let bookmarkedURL = try? URL(
                   resolvingBookmarkData: destinationBookmark,
                   options: .withSecurityScope,
                   relativeTo: nil,
                   bookmarkDataIsStale: &bookmarkIsStale
               ), bookmarkedURL.isFileURL {
                destination = bookmarkedURL
            } else {
                guard destinationPath.hasPrefix("/") else { return nil }
                destination = URL(fileURLWithPath: destinationPath, isDirectory: true)
            }
            let source: MusicDownloadSource = switch source {
            case .catalog: .catalog
            case let .cloud(userID, fileName): .cloud(userID: userID, fileName: fileName)
            }
            return MusicDownloadRequest(
                songID: songID,
                songName: songName,
                artists: artists,
                destination: destination,
                quality: quality,
                includeLyrics: includeLyrics,
                source: source,
                expectedBytes: expectedBytes
            )
        }
    }

    private struct Record: Codable {
        let signature: String
        let request: StoredRequest?
        let resumeData: Data?
        let savedAt: Date
        let updatedAt: Date?
    }

    static let shared = MusicDownloadResumeStore()

    private let directory: URL
    private let lock = NSLock()
    private let maximumAge: TimeInterval

    init(directory: URL? = nil, maximumAge: TimeInterval = 7 * 24 * 60 * 60) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "TinyCloudMusic", directoryHint: .isDirectory)
            .appending(path: "DownloadResume", directoryHint: .isDirectory)
        self.maximumAge = max(0, maximumAge)
    }

    func load(for request: MusicDownloadRequest) -> Data? {
        lock.withLock {
            let url = recordURL(songID: request.songID)
            guard let record = record(at: url),
                  record.signature == signature(for: request),
                  !isExpired(record, now: Date())
            else {
                try? FileManager.default.removeItem(at: url)
                return nil
            }
            return record.resumeData
        }
    }

    func save(_ resumeData: Data, for request: MusicDownloadRequest) {
        guard !resumeData.isEmpty else { return }
        saveRecord(request, resumeData: resumeData)
    }

    func save(_ request: MusicDownloadRequest, resumeData: Data? = nil) {
        saveRecord(request, resumeData: resumeData.flatMap { $0.isEmpty ? nil : $0 })
    }

    func recoverableDownloads(now: Date = Date()) -> [MusicDownloadRecovery] {
        lock.withLock {
            records(now: now).compactMap { record in
                guard let request = record.request?.restored() else { return nil }
                return MusicDownloadRecovery(
                    request: request,
                    resumeData: record.resumeData,
                    savedAt: record.savedAt
                )
            }.sorted {
                ($0.savedAt, $0.request.songID) < ($1.savedAt, $1.request.songID)
            }
        }
    }

    @discardableResult
    func prune(now: Date = Date()) -> Int {
        lock.withLock {
            let urls = recordURLs()
            let retained = records(now: now).count
            return urls.count - retained
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

    private func saveRecord(_ request: MusicDownloadRequest, resumeData: Data?) {
        lock.withLock {
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let signature = signature(for: request)
                let now = Date()
                let existing = record(at: recordURL(songID: request.songID))
                let record = Record(
                    signature: signature,
                    request: StoredRequest(request),
                    resumeData: resumeData,
                    savedAt: existing?.signature == signature ? existing?.savedAt ?? now : now,
                    updatedAt: now
                )
                let data = try PropertyListEncoder().encode(record)
                try data.write(to: recordURL(songID: request.songID), options: .atomic)
            } catch {
                // Resume persistence is best-effort; the in-memory retry path remains available.
            }
        }
    }

    private func record(at url: URL) -> Record? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? PropertyListDecoder().decode(Record.self, from: data)
    }

    private func recordURLs() -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []).filter { $0.lastPathComponent.hasSuffix(".resume.plist") }
    }

    private func records(now: Date) -> [Record] {
        recordURLs().compactMap { url in
            guard let record = record(at: url), !isExpired(record, now: now) else {
                try? FileManager.default.removeItem(at: url)
                return nil
            }
            return record
        }
    }

    private func isExpired(_ record: Record, now: Date) -> Bool {
        now.timeIntervalSince(record.updatedAt ?? record.savedAt) > maximumAge
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
