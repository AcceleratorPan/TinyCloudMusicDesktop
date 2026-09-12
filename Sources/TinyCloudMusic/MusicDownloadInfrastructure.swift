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
    var restoredState: MusicDownloadState? = nil
}

struct MusicDownloadVideoRecovery: Equatable, Sendable {
    let request: VideoDownloadRequest
    let resumeData: Data?
    let resolution: Int?
    let sourceURL: URL?
    let sourceExpiresAt: Date?
    let savedAt: Date
    var restoredState: MusicDownloadState? = nil
}

struct MusicDownloadRecoveryResult: Sendable {
    let downloads: [MusicDownloadRecovery]
    let videos: [MusicDownloadVideoRecovery]
    let failureDescription: String?
}

struct MusicDownloadResumeEntry: Sendable {
    let request: MusicDownloadRequest
    let resumeData: Data?
    var isPaused = false
    var completion: MusicDownloadResult? = nil
}

struct MusicDownloadVideoResumeEntry: Sendable {
    let request: VideoDownloadRequest
    let resumeData: Data?
    let resolution: Int?
    let sourceURL: URL?
    let sourceExpiresAt: Date?
    var isPaused = false
    var completion: MusicDownloadResult? = nil
}

enum MusicDownloadPersistenceError: LocalizedError, Equatable, Sendable {
    case flushTimedOut

    var errorDescription: String? {
        switch self {
        case .flushTimedOut: "等待下载恢复记录落盘超时"
        }
    }
}

final class MusicDownloadResumeStore: @unchecked Sendable {
    typealias FailureHandler = @Sendable (String) -> Void

    private struct StoredRequest: Codable {
        private enum Source: Codable, Equatable {
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
            let scoped = request.destination.startAccessingSecurityScopedResource()
            defer { if scoped { request.destination.stopAccessingSecurityScopedResource() } }
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

        func matches(_ other: StoredRequest) -> Bool {
            songID == other.songID
                && songName == other.songName
                && artists == other.artists
                && destinationPath == other.destinationPath
                && quality == other.quality
                && includeLyrics == other.includeLyrics
                && source == other.source
                && expectedBytes == other.expectedBytes
        }
    }

    private struct Record: Codable {
        let signature: String
        let request: StoredRequest?
        let videoRequest: StoredVideoRequest?
        let resumeData: Data?
        let resolution: Int?
        let sourceURL: URL?
        let sourceExpiresAt: Date?
        let savedAt: Date
        let updatedAt: Date?
        let isPaused: Bool?
        let completion: MusicDownloadResult?

        init(
            signature: String,
            request: StoredRequest? = nil,
            videoRequest: StoredVideoRequest? = nil,
            resumeData: Data?,
            resolution: Int? = nil,
            sourceURL: URL? = nil,
            sourceExpiresAt: Date? = nil,
            savedAt: Date,
            updatedAt: Date?,
            isPaused: Bool = false,
            completion: MusicDownloadResult? = nil
        ) {
            self.signature = signature
            self.request = request
            self.videoRequest = videoRequest
            self.resumeData = resumeData
            self.resolution = resolution
            self.sourceURL = sourceURL
            self.sourceExpiresAt = sourceExpiresAt
            self.savedAt = savedAt
            self.updatedAt = updatedAt
            self.isPaused = isPaused
            self.completion = completion
        }
    }

    private struct StoredVideoRequest: Codable {
        enum Resource: Codable, Equatable {
            case mv(Int64)
            case video(String)
        }

        let resource: Resource
        let title: String
        let creator: String
        let destinationBookmark: Data?
        let destinationPath: String
        let quality: VideoQuality
        let availableResolutions: [Int]

        init(_ request: VideoDownloadRequest) {
            let scoped = request.destination.startAccessingSecurityScopedResource()
            defer { if scoped { request.destination.stopAccessingSecurityScopedResource() } }
            resource = switch request.resource {
            case let .mv(id): .mv(id)
            case let .video(id): .video(id)
            }
            title = request.title
            creator = request.creator
            destinationBookmark = try? request.destination.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            destinationPath = request.destination.standardizedFileURL.path
            quality = request.quality
            availableResolutions = request.availableResolutions
        }

        func restored() -> VideoDownloadRequest? {
            guard let destination = Self.restoredDestination(
                bookmark: destinationBookmark,
                path: destinationPath
            ) else { return nil }
            let resource: VideoPageResource = switch resource {
            case let .mv(id): .mv(id)
            case let .video(id): .video(id)
            }
            return VideoDownloadRequest(
                resource: resource,
                title: title,
                creator: creator,
                destination: destination,
                quality: quality,
                availableResolutions: availableResolutions
            )
        }

        func matches(_ other: StoredVideoRequest) -> Bool {
            resource == other.resource
                && title == other.title
                && creator == other.creator
                && destinationPath == other.destinationPath
                && quality == other.quality
                && availableResolutions == other.availableResolutions
        }

        private static func restoredDestination(bookmark: Data?, path: String) -> URL? {
            var bookmarkIsStale = false
            if let bookmark,
               let bookmarkedURL = try? URL(
                   resolvingBookmarkData: bookmark,
                   options: .withSecurityScope,
                   relativeTo: nil,
                   bookmarkDataIsStale: &bookmarkIsStale
               ), bookmarkedURL.isFileURL {
                return bookmarkedURL
            }
            guard path.hasPrefix("/") else { return nil }
            return URL(fileURLWithPath: path, isDirectory: true)
        }
    }

    private final class BlockingBox<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Value?

        func set(_ value: Value) { lock.withLock { self.value = value } }
        func get() -> Value? { lock.withLock { value } }
    }

    private final class FlushGate: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, Error>?

        init(_ continuation: CheckedContinuation<Void, Error>) {
            self.continuation = continuation
        }

        func finish(_ result: Result<Void, Error>) {
            let continuation = lock.withLock {
                let value = self.continuation
                self.continuation = nil
                return value
            }
            continuation?.resume(with: result)
        }
    }

    private enum PendingCommand: Sendable {
        case save(
            audio: [MusicDownloadResumeEntry],
            videos: [MusicDownloadVideoResumeEntry],
            onFailure: FailureHandler?
        )
        case remove(songIDs: [Int64], videoIDs: [String], onFailure: FailureHandler?)

        var onFailure: FailureHandler? {
            switch self {
            case let .save(_, _, onFailure), let .remove(_, _, onFailure): onFailure
            }
        }
    }

    static let shared = MusicDownloadResumeStore()

    private let directory: URL
    private let queue = DispatchQueue(label: "com.tinycloudmusic.download-resume-store")
    private let maximumAge: TimeInterval
    private var pendingCommands: [PendingCommand] = []

    init(directory: URL? = nil, maximumAge: TimeInterval = 7 * 24 * 60 * 60) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "TinyCloudMusic", directoryHint: .isDirectory)
            .appending(path: "DownloadResume", directoryHint: .isDirectory)
        self.maximumAge = max(0, maximumAge)
    }

    func load(for request: MusicDownloadRequest) async throws -> Data? {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    let url = self.recordURL(songID: request.songID)
                    guard FileManager.default.fileExists(atPath: url.path) else {
                        continuation.resume(returning: nil)
                        return
                    }
                    let record = try self.record(at: url)
                    let movedDestinationMatches = record.request?.restored()?.destination.resolvingSymlinksInPath()
                        == request.destination.resolvingSymlinksInPath()
                    let signatureMatches = record.signature == self.signature(for: request)
                        || (movedDestinationMatches && record.signature == self.signature(
                            for: request, destinationPath: record.request?.destinationPath
                        ))
                    guard signatureMatches,
                          !self.isExpired(record, now: Date())
                    else {
                        try FileManager.default.removeItem(at: url)
                        continuation.resume(returning: nil)
                        return
                    }
                    continuation.resume(returning: record.resumeData)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func save(
        _ resumeData: Data,
        for request: MusicDownloadRequest,
        onFailure: FailureHandler? = nil
    ) {
        guard !resumeData.isEmpty else { return }
        save(request, resumeData: resumeData, onFailure: onFailure)
    }

    func save(
        _ request: MusicDownloadRequest,
        resumeData: Data? = nil,
        isPaused: Bool = false,
        completion: MusicDownloadResult? = nil,
        onFailure: FailureHandler? = nil
    ) {
        save(
            [MusicDownloadResumeEntry(request: request, resumeData: resumeData, isPaused: isPaused, completion: completion)],
            onFailure: onFailure
        )
    }

    func save(_ entries: [MusicDownloadResumeEntry], onFailure: FailureHandler? = nil) {
        save(audio: entries, videos: [], onFailure: onFailure)
    }

    func save(_ entry: MusicDownloadVideoResumeEntry, onFailure: FailureHandler? = nil) {
        save(audio: [], videos: [entry], onFailure: onFailure)
    }

    func save(
        audio: [MusicDownloadResumeEntry],
        videos: [MusicDownloadVideoResumeEntry],
        onFailure: FailureHandler? = nil
    ) {
        guard !audio.isEmpty || !videos.isEmpty else { return }
        queue.async {
            let shouldDrain = self.pendingCommands.isEmpty
            self.pendingCommands.append(.save(
                audio: audio,
                videos: videos,
                onFailure: onFailure
            ))
            if shouldDrain { _ = self.drainPendingCommands() }
        }
    }

    // Kept for synchronous test consumers; production recovery uses the async API below.
    func recoverableDownloads(now: Date = Date()) -> [MusicDownloadRecovery] {
        let box = BlockingBox<MusicDownloadRecoveryResult>()
        let semaphore = DispatchSemaphore(value: 0)
        queue.async {
            box.set(self.recoveryResult(now: now))
            semaphore.signal()
        }
        semaphore.wait()
        return box.get()?.downloads ?? []
    }

    func recoverableDownloadsAsync(now: Date = Date()) async -> MusicDownloadRecoveryResult {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: self.recoveryResult(now: now))
            }
        }
    }

    @discardableResult
    func prune(now: Date = Date()) async -> Int {
        await withCheckedContinuation { continuation in
            queue.async {
                let urls = (try? self.recordURLs()) ?? []
                let result = self.recoveryResult(now: now)
                continuation.resume(returning: urls.count - result.downloads.count - result.videos.count)
            }
        }
    }

    func remove(songID: Int64, onFailure: FailureHandler? = nil) {
        remove(songIDs: [songID], videoIDs: [], onFailure: onFailure)
    }

    func remove(videoID: String, onFailure: FailureHandler? = nil) {
        remove(songIDs: [], videoIDs: [videoID], onFailure: onFailure)
    }

    func remove(
        songIDs: some Sequence<Int64> & Sendable,
        videoIDs: some Sequence<String> & Sendable,
        onFailure: FailureHandler? = nil
    ) {
        let songIDs = Array(songIDs)
        let videoIDs = Array(videoIDs)
        guard !songIDs.isEmpty || !videoIDs.isEmpty else { return }
        queue.async {
            let shouldDrain = self.pendingCommands.isEmpty
            self.pendingCommands.append(.remove(
                songIDs: songIDs,
                videoIDs: videoIDs,
                onFailure: onFailure
            ))
            if shouldDrain { _ = self.drainPendingCommands() }
        }
    }

    func flush(timeout: Duration = .seconds(10)) async throws {
        try await withCheckedThrowingContinuation { continuation in
            let gate = FlushGate(continuation)
            queue.async {
                if let error = self.drainPendingCommands() {
                    gate.finish(.failure(error))
                } else {
                    gate.finish(.success(()))
                }
            }
            Task<Void, Never> {
                try? await Task.sleep(for: timeout)
                gate.finish(.failure(MusicDownloadPersistenceError.flushTimedOut))
            }
        }
    }

    private func drainPendingCommands() -> Error? {
        while let command = pendingCommands.first {
            do {
                try perform(command)
                pendingCommands.removeFirst()
            } catch {
                command.onFailure?(error.localizedDescription)
                return error
            }
        }
        return nil
    }

    private func perform(_ command: PendingCommand) throws {
        switch command {
        case let .save(audio, videos, _):
            for entry in audio { try saveRecord(entry) }
            for entry in videos { try saveRecord(entry) }
        case let .remove(songIDs, videoIDs, _):
            for songID in songIDs {
                let url = recordURL(songID: songID)
                if FileManager.default.fileExists(atPath: url.path) {
                    try FileManager.default.removeItem(at: url)
                }
            }
            for videoID in videoIDs {
                let url = recordURL(videoID: videoID)
                if FileManager.default.fileExists(atPath: url.path) {
                    try FileManager.default.removeItem(at: url)
                }
            }
        }
    }

    private func recordURL(songID: Int64) -> URL {
        directory.appending(path: "\(songID).resume.plist", directoryHint: .notDirectory)
    }

    private func recordURL(videoID: String) -> URL {
        let key = Data(videoID.utf8).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")
        return directory.appending(path: "video-\(key).resume.plist", directoryHint: .notDirectory)
    }

    private func saveRecord(_ entry: MusicDownloadResumeEntry) throws {
        let request = entry.request
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let signature = signature(for: request)
        let storedRequest = StoredRequest(request)
        let resumeData = entry.resumeData.flatMap { $0.isEmpty ? nil : $0 }
        let now = Date()
        let url = recordURL(songID: request.songID)
        let existing = try? record(at: url)
        if existing?.signature == signature,
           existing?.request?.matches(storedRequest) == true,
           existing?.resumeData == resumeData,
           existing?.isPaused == entry.isPaused,
           existing?.completion == entry.completion {
            return
        }
        let record = Record(
            signature: signature,
            request: storedRequest,
            resumeData: resumeData,
            savedAt: existing?.signature == signature ? existing?.savedAt ?? now : now,
            updatedAt: now,
            isPaused: entry.isPaused,
            completion: entry.completion
        )
        try PropertyListEncoder().encode(record).write(to: url, options: .atomic)
    }

    private func saveRecord(_ entry: MusicDownloadVideoResumeEntry) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let signature = signature(for: entry.request)
        let storedRequest = StoredVideoRequest(entry.request)
        let resumeData = entry.resumeData.flatMap { $0.isEmpty ? nil : $0 }
        let now = Date()
        let url = recordURL(videoID: entry.request.resource.identity)
        let existing = try? record(at: url)
        if existing?.signature == signature,
           existing?.videoRequest?.matches(storedRequest) == true,
           existing?.resumeData == resumeData,
           existing?.resolution == entry.resolution,
           existing?.sourceURL == entry.sourceURL,
           existing?.sourceExpiresAt == entry.sourceExpiresAt,
           existing?.isPaused == entry.isPaused,
           existing?.completion == entry.completion {
            return
        }
        let record = Record(
            signature: signature,
            videoRequest: storedRequest,
            resumeData: resumeData,
            resolution: entry.resolution,
            sourceURL: entry.sourceURL,
            sourceExpiresAt: entry.sourceExpiresAt,
            savedAt: existing?.signature == signature ? existing?.savedAt ?? now : now,
            updatedAt: now,
            isPaused: entry.isPaused,
            completion: entry.completion
        )
        try PropertyListEncoder().encode(record).write(to: url, options: .atomic)
    }

    private func record(at url: URL) throws -> Record {
        try PropertyListDecoder().decode(Record.self, from: Data(contentsOf: url))
    }

    private func recordURLs() throws -> [URL] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ).filter { $0.lastPathComponent.hasSuffix(".resume.plist") }
    }

    private func recoveryResult(now: Date) -> MusicDownloadRecoveryResult {
        var downloads: [MusicDownloadRecovery] = []
        var videos: [MusicDownloadVideoRecovery] = []
        var failures: [String] = []
        let urls: [URL]
        do {
            urls = try recordURLs()
        } catch {
            return MusicDownloadRecoveryResult(
                downloads: [],
                videos: [],
                failureDescription: "\(directory.lastPathComponent): \(error.localizedDescription)"
            )
        }
        for url in urls {
            do {
                let record = try record(at: url)
                guard !isExpired(record, now: now) else {
                    try FileManager.default.removeItem(at: url)
                    continue
                }
                if let request = record.request?.restored() {
                    guard record.signature == signature(for: request, destinationPath: record.request?.destinationPath) else {
                        throw DecodingError.dataCorrupted(.init(
                            codingPath: [],
                            debugDescription: "Download request signature mismatch"
                        ))
                    }
                    downloads.append(MusicDownloadRecovery(
                        request: request,
                        resumeData: record.resumeData,
                        savedAt: record.savedAt,
                        restoredState: restoredState(record, in: request.destination)
                    ))
                } else if let request = record.videoRequest?.restored() {
                    guard record.signature == signature(for: request, destinationPath: record.videoRequest?.destinationPath) else {
                        throw DecodingError.dataCorrupted(.init(
                            codingPath: [],
                            debugDescription: "Video request signature mismatch"
                        ))
                    }
                    videos.append(MusicDownloadVideoRecovery(
                        request: request,
                        resumeData: record.resumeData,
                        resolution: record.resolution,
                        sourceURL: record.sourceURL,
                        sourceExpiresAt: record.sourceExpiresAt,
                        savedAt: record.savedAt,
                        restoredState: restoredState(record, in: request.destination)
                    ))
                } else {
                    throw DecodingError.dataCorrupted(.init(
                        codingPath: [],
                        debugDescription: "Missing download request"
                    ))
                }
            } catch {
                failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
                try? FileManager.default.removeItem(at: url)
            }
        }
        downloads.sort { ($0.savedAt, $0.request.songID) < ($1.savedAt, $1.request.songID) }
        videos.sort { ($0.savedAt, $0.request.resource.identity) < ($1.savedAt, $1.request.resource.identity) }
        return MusicDownloadRecoveryResult(
            downloads: downloads,
            videos: videos,
            failureDescription: failures.isEmpty ? nil : failures.joined(separator: "\n")
        )
    }

    private func isExpired(_ record: Record, now: Date) -> Bool {
        record.completion == nil && record.isPaused == false
            && now.timeIntervalSince(record.updatedAt ?? record.savedAt) > maximumAge
    }

    private func restoredState(_ record: Record, in directory: URL) -> MusicDownloadState? {
        guard let completion = record.completion else {
            // Legacy records did not store user intent; require an explicit resume after migration.
            return record.isPaused != false ? .paused(progress: nil) : nil
        }
        let scoped = directory.startAccessingSecurityScopedResource()
        defer { if scoped { directory.stopAccessingSecurityScopedResource() } }
        // Rebase file names onto the restored bookmark; the app's sandbox path can change.
        let audioURL = directory.appending(path: completion.audioURL.lastPathComponent)
        guard FileManager.default.fileExists(atPath: audioURL.path) else {
            return .failed("已下载文件已移动、删除或无法访问，可重新下载")
        }
        let lyricURL = completion.lyricURL
            .map { directory.appending(path: $0.lastPathComponent) }
            .flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
        return .completed(audioURL: audioURL, lyricURL: lyricURL)
    }

    private func signature(for request: MusicDownloadRequest, destinationPath: String? = nil) -> String {
        let source: String = switch request.source {
        case .catalog: "catalog"
        case let .cloud(userID, fileName): "cloud:\(userID):\(fileName)"
        }
        return [
            String(request.songID), request.quality.rawValue, source,
            destinationPath ?? request.destination.standardizedFileURL.path,
            request.includeLyrics ? "lyrics" : "audio"
        ].joined(separator: "|")
    }

    private func signature(for request: VideoDownloadRequest, destinationPath: String? = nil) -> String {
        [
            request.resource.identity,
            request.quality.rawValue,
            destinationPath ?? request.destination.standardizedFileURL.path,
            request.availableResolutions.map(String.init).joined(separator: ",")
        ].joined(separator: "|")
    }
}

struct MusicDownloadCacheContext: Equatable, Sendable {
    let root: URL?
    let generation: UInt64
}

final class MusicDownloadCacheGeneration: @unchecked Sendable {
    private let lock = NSLock()
    private var root: URL?
    private var generation: UInt64 = 0
    private var clearing = false

    init(root: URL?) { self.root = root?.standardizedFileURL }

    func configure(root: URL?) -> MusicDownloadCacheContext {
        lock.withLock {
            generation += 1
            self.root = root?.standardizedFileURL
            clearing = false
            return MusicDownloadCacheContext(root: self.root, generation: generation)
        }
    }

    func context() -> MusicDownloadCacheContext {
        lock.withLock { MusicDownloadCacheContext(root: root, generation: generation) }
    }

    func isCurrent(_ context: MusicDownloadCacheContext) -> Bool {
        lock.withLock { !clearing && context.generation == generation && context.root == root }
    }

    func withCurrent<Value>(_ context: MusicDownloadCacheContext, _ body: () throws -> Value) rethrows -> Value? {
        try lock.withLock {
            guard !clearing, context.generation == generation, context.root == root else { return nil }
            return try body()
        }
    }

    func beginClear() -> MusicDownloadCacheContext {
        lock.withLock {
            generation += 1
            clearing = true
            return MusicDownloadCacheContext(root: root, generation: generation)
        }
    }

    func endClear(_ context: MusicDownloadCacheContext) {
        lock.withLock {
            guard generation == context.generation, root == context.root else { return }
            generation += 1
            clearing = false
        }
    }
}

final class MusicDownloadCacheActivity: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func begin() { lock.withLock { count += 1 } }

    func end() {
        let waiters: [CheckedContinuation<Void, Never>] = lock.withLock {
            count = max(0, count - 1)
            guard count == 0 else { return [] }
            defer { self.waiters.removeAll() }
            return self.waiters
        }
        waiters.forEach { $0.resume() }
    }

    func waitUntilIdle() async {
        await withCheckedContinuation { continuation in
            let resumeNow = lock.withLock {
                guard count > 0 else { return true }
                waiters.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }
}
