import Foundation
import Observation

@MainActor
@Observable
final class MusicDownloadManager {
    private(set) var states: [Int64: MusicDownloadState] = [:]

    @ObservationIgnored private let transport: EAPITransport
    @ObservationIgnored private let session: URLSession
    @ObservationIgnored private var tasks: [Int64: Task<Void, Never>] = [:]
    @ObservationIgnored private var jobIDs: [Int64: UUID] = [:]
    @ObservationIgnored private var cloudSongIDs: Set<Int64> = []

    init(transport: EAPITransport = EAPITransport(), session: URLSession = .shared) {
        self.transport = transport
        self.session = session
    }

    isolated deinit {
        tasks.values.forEach { $0.cancel() }
    }

    func enqueue(
        song: Song,
        to destination: URL,
        quality: AudioQuality = .standard,
        includeLyrics: Bool = true
    ) {
        enqueue(MusicDownloadRequest(
            songID: song.id,
            songName: song.name,
            artists: song.artistsDisplay,
            destination: destination,
            quality: quality,
            includeLyrics: includeLyrics,
            source: .catalog
        ))
    }

    func enqueue(
        cloudSong: CloudSong,
        userID: Int64,
        to destination: URL,
        includeLyrics: Bool = true
    ) {
        guard userID > 0 else { return }
        enqueue(MusicDownloadRequest(
            songID: cloudSong.id,
            songName: cloudSong.name,
            artists: cloudSong.artist,
            destination: destination,
            quality: .standard,
            includeLyrics: includeLyrics,
            source: .cloud(userID: userID, fileName: cloudSong.fileName)
        ))
    }

    private func enqueue(_ request: MusicDownloadRequest) {
        let songID = request.songID
        tasks[songID]?.cancel()
        let jobID = UUID()
        jobIDs[songID] = jobID
        if case .cloud = request.source { cloudSongIDs.insert(songID) } else { cloudSongIDs.remove(songID) }
        states[songID] = .queued
        tasks[songID] = Task { @MainActor [weak self, transport, session] in
            guard let self, self.jobIDs[songID] == jobID else { return }
            self.states[songID] = .running(progress: 0)
            do {
                let result = try await Self.perform(
                    request,
                    transport: transport,
                    session: session,
                    progress: { value in
                        Task { @MainActor [weak self] in
                            guard let self, self.jobIDs[songID] == jobID else { return }
                            self.states[songID] = .running(progress: min(max(value, 0), 1))
                        }
                    }
                )
                guard self.jobIDs[songID] == jobID else { return }
                self.finish(songID: songID, jobID: jobID)
                self.states[songID] = .completed(audioURL: result.audioURL, lyricURL: result.lyricURL)
            } catch is CancellationError {
                guard self.jobIDs[songID] == jobID else { return }
                self.finish(songID: songID, jobID: jobID)
                self.states[songID] = .cancelled
            } catch {
                guard self.jobIDs[songID] == jobID else { return }
                self.finish(songID: songID, jobID: jobID)
                self.states[songID] = .failed(error.localizedDescription)
            }
        }
    }

    func cancel(songID: Int64) {
        guard let task = tasks.removeValue(forKey: songID) else { return }
        jobIDs.removeValue(forKey: songID)
        cloudSongIDs.remove(songID)
        task.cancel()
        states[songID] = .cancelled
    }

    func cancelAll() {
        let activeIDs = Array(tasks.keys)
        tasks.values.forEach { $0.cancel() }
        tasks.removeAll()
        jobIDs.removeAll()
        cloudSongIDs.removeAll()
        for id in activeIDs { states[id] = .cancelled }
    }

    func cancelCloudDownloads() {
        for songID in cloudSongIDs {
            tasks.removeValue(forKey: songID)?.cancel()
            jobIDs.removeValue(forKey: songID)
            states[songID] = .cancelled
        }
        cloudSongIDs.removeAll()
    }

    private func finish(songID: Int64, jobID: UUID) {
        guard jobIDs[songID] == jobID else { return }
        tasks.removeValue(forKey: songID)
        jobIDs.removeValue(forKey: songID)
        cloudSongIDs.remove(songID)
    }

    private nonisolated static func perform(
        _ request: MusicDownloadRequest,
        transport: EAPITransport,
        session: URLSession,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> MusicDownloadResult {
        try Task.checkCancellation()
        let source = try await resolvedSource(for: request, transport: transport)
        try FileManager.default.createDirectory(at: request.destination, withIntermediateDirectories: true)

        let prefix = request.artists.isEmpty ? request.songName : "\(request.artists) - \(request.songName)"
        let label = source.level.map { "【\(qualityLabel($0))】" } ?? ""
        let cleaned = MusicDownloadFiles.sanitizedFileName(label + prefix)
        let stem = cleaned.isEmpty ? String(request.songID) : cleaned
        let fallbackExtension = if case let .cloud(_, fileName) = request.source {
            URL(fileURLWithPath: fileName).pathExtension
        } else {
            ""
        }
        let fileExtension = sanitizedExtension(source.type.nonEmpty ?? fallbackExtension)
        let targets = MusicDownloadFiles.availableTargets(
            in: request.destination,
            stem: stem,
            audioExtension: fileExtension
        )
        var committed: [URL] = []
        var succeeded = false
        defer {
            if !succeeded {
                for url in [targets.audioPart, targets.lyricPart] + committed {
                    try? FileManager.default.removeItem(at: url)
                }
            }
        }

        var urlRequest = URLRequest(url: source.url, timeoutInterval: 60)
        urlRequest.setValue("TinyCloudMusic/1.0 macOS", forHTTPHeaderField: "User-Agent")
        let isCloud = if case .cloud = request.source { true } else { false }
        let delegate = MusicDownloadProgressDelegate(progress: progress) { request in
            !isCloud || request.url.map(CloudMusicDecoder.isAllowedDownloadURL) == true
        }
        let (temporaryURL, response) = try await session.download(for: urlRequest, delegate: delegate)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw MusicDownloadError.invalidResponse
        }
        try Task.checkCancellation()
        try MusicDownloadFiles.stageDownloadedFile(temporaryURL, at: targets.audioPart)

        var hasLyrics = false
        if request.includeLyrics {
            do {
                let lyrics = try await mergedLyrics(for: request, transport: transport)
                try Task.checkCancellation()
                if !lyrics.isEmpty {
                    try MusicDownloadFiles.stageData(Data(lyrics.utf8), at: targets.lyricPart)
                    hasLyrics = true
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try? FileManager.default.removeItem(at: targets.lyricPart)
            }
        }

        try Task.checkCancellation()
        try MusicDownloadFiles.commit(partURL: targets.audioPart, finalURL: targets.audioFinal)
        committed.append(targets.audioFinal)
        if hasLyrics {
            try MusicDownloadFiles.commit(partURL: targets.lyricPart, finalURL: targets.lyricFinal)
            committed.append(targets.lyricFinal)
        }
        succeeded = true
        progress(1)
        return MusicDownloadResult(
            audioURL: targets.audioFinal,
            lyricURL: hasLyrics ? targets.lyricFinal : nil
        )
    }

    private nonisolated static func resolvedSource(
        for request: MusicDownloadRequest,
        transport: EAPITransport
    ) async throws -> (url: URL, type: String, level: String?) {
        if case .cloud = request.source {
            let source = try await LiveMusicLibrary(transport: transport).cloudDownloadSource(songID: request.songID)
            return (source.url, source.type, nil)
        }

        let level = try await downloadLevel(for: request, transport: transport)
        do {
            let source = try await audioSource(
                songID: request.songID,
                level: level,
                requiresExactLevel: request.quality == .best,
                transport: transport
            )
            return (source.url, source.type, source.level)
        } catch {
            guard request.quality == .best,
                  shouldRetryAtLowerLevel(after: error),
                  let fallbackLevel = nextLowerLevel(after: level)
            else { throw error }
            let source = try await audioSource(
                songID: request.songID,
                level: fallbackLevel,
                requiresExactLevel: true,
                transport: transport
            )
            return (source.url, source.type, source.level)
        }
    }

    nonisolated static func downloadLevel(
        for request: MusicDownloadRequest,
        transport: EAPITransport
    ) async throws -> String {
        switch request.quality {
        case .standard: return "standard"
        case .lossless: return "lossless"
        case .best:
            async let qualityData = apiRequest(
                EAPIEndpoint(
                    "/eapi/song/music/detail/get",
                    signing: "/api/song/music/detail/get",
                    host: "https://interface.music.163.com",
                    responseEncoding: .automatic
                ),
                payload: ["songId": request.songID],
                transport: transport,
                cache: .detail
            )
            async let privilegeData = apiRequest(
                EAPIEndpoint("/eapi/v3/song/detail"),
                payload: ["c": "[{\"id\":\(request.songID)}]"],
                transport: transport,
                vip: true,
                iPhoneClient: true,
                cache: .detail
            )
            let result = try await (qualityData, privilegeData)
            let qualities = try LiveMusicRepository.decodeSongQualityDetails(
                result.0,
                privileges: result.1
            )
            guard let level = SongQualityDetail.highestAvailableLevel(in: qualities) else {
                throw EAPIError.missingData("highestAvailableQuality")
            }
            return level
        }
    }

    nonisolated static func audioSource(
        songID: Int64,
        level: String,
        requiresExactLevel: Bool,
        transport: EAPITransport
    ) async throws -> (url: URL, type: String, level: String) {
        let data = try await apiRequest(
            EAPIEndpoint("/eapi/song/enhance/player/url/v1"),
            payload: audioSourcePayload(songID: songID, level: level),
            transport: transport,
            vip: true,
            iPhoneClient: true
        )
        let root = try decodedJSONObject(data)
        let value = root.array("data").first ?? root.object("data")
        let actualLevel = value.string("level")
        guard !requiresExactLevel || actualLevel == level else {
            throw MusicDownloadError.qualityMismatch
        }
        guard let url = URL(string: value.string("url")), !value.string("url").isEmpty else {
            throw MusicDownloadError.unavailable
        }
        return (url, value.string("type"), actualLevel.nonEmpty ?? level)
    }

    nonisolated static func audioSourcePayload(songID: Int64, level: String) -> [String: Any] {
        LiveMusicRepository.playbackSourcePayload(songID: songID, level: level)
    }

    nonisolated static func nextLowerLevel(after level: String) -> String? {
        switch level {
        case "jymaster": "sky"
        case "sky": "jyeffect"
        case "jyeffect": "hires"
        case "hires": "lossless"
        case "lossless": "exhigh"
        case "exhigh": "higher"
        case "higher": "standard"
        default: nil
        }
    }

    private nonisolated static func shouldRetryAtLowerLevel(after error: Error) -> Bool {
        if let error = error as? MusicDownloadError {
            return error == .unavailable || error == .qualityMismatch
        }
        guard let error = error as? EAPIError else { return false }
        switch error {
        case let .http(status): return status >= 500
        case let .service(code, _): return code >= 500
        default: return false
        }
    }

    private nonisolated static func mergedLyrics(
        for request: MusicDownloadRequest,
        transport: EAPITransport
    ) async throws -> String {
        let lyrics: SongLyrics
        switch request.source {
        case .catalog:
            let data = try await apiRequest(
                EAPIEndpoint("/eapi/song/lyric"),
                payload: ["id": request.songID, "lv": -1, "kv": -1, "tv": -1, "yv": -1],
                transport: transport,
                cache: .lyrics
            )
            lyrics = CloudMusicDecoder.lyrics(try decodedJSONObject(data))
        case let .cloud(userID, _):
            lyrics = try await LiveMusicLibrary(transport: transport).cloudLyrics(
                userID: userID,
                songID: request.songID
            )
        }
        let lines = LRCParser.parse(
            primary: lyrics.lineLyrics,
            translation: lyrics.translatedLyrics
        )
        return lines.flatMap { line -> [String] in
            let timestamp = lrcTimestamp(line.timestampMilliseconds)
            return ["\(timestamp)\(line.text)"]
                + (line.translation.map { ["\(timestamp)\($0)"] } ?? [])
        }.joined(separator: "\n") + (lines.isEmpty ? "" : "\n")
    }

    private nonisolated static func apiRequest(
        _ endpoint: EAPIEndpoint,
        payload: [String: Any],
        transport: EAPITransport,
        vip: Bool = false,
        iPhoneClient: Bool = false,
        cache: EAPIReadCache? = nil
    ) async throws -> Data {
        try await transport.request(
            endpoint,
            json: compactJSON(payload),
            vip: vip,
            cache: cache,
            iPhoneClient: iPhoneClient
        )
    }

    private nonisolated static func lrcTimestamp(_ milliseconds: Int64) -> String {
        String(
            format: "[%02lld:%02lld.%03lld]",
            milliseconds / 60_000,
            milliseconds % 60_000 / 1_000,
            milliseconds % 1_000
        )
    }

    private nonisolated static func sanitizedExtension(_ value: String) -> String {
        let result = value.lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
        return result.isEmpty ? "mp3" : result
    }

    private nonisolated static func qualityLabel(_ level: String) -> String {
        switch level {
        case "lossless": "无损"
        case "higher": "极高"
        case "standard": "标准"
        case "hires": "高解析度无损"
        case "jyeffect": "高清环绕声"
        case "sky": "沉浸环绕声"
        case "jymaster": "超清母带"
        case "dolby": "杜比"
        default: level
        }
    }
}

private final class MusicDownloadProgressDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let progress: @Sendable (Double) -> Void
    let allowsRequest: @Sendable (URLRequest) -> Bool
    private let lock = NSLock()
    private var throttle = MusicDownloadProgressThrottle()

    init(
        progress: @escaping @Sendable (Double) -> Void,
        allowsRequest: @escaping @Sendable (URLRequest) -> Bool = { _ in true }
    ) {
        self.progress = progress
        self.allowsRequest = allowsRequest
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        lock.lock()
        let value = throttle.update(
            totalBytesWritten: totalBytesWritten,
            totalBytesExpectedToWrite: totalBytesExpectedToWrite
        )
        lock.unlock()
        if let value { progress(value) }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {}

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(allowsRequest(request) ? request : nil)
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
