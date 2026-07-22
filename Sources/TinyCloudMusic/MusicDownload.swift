import Foundation
import Observation

@MainActor
@Observable
final class MusicDownloadManager {
    private struct ActiveDownloadTask {
        let songID: Int64
        let task: Task<Void, Never>
    }

    private(set) var states: [Int64: MusicDownloadState] = [:]
    private(set) var items: [Int64: MusicDownloadItem] = [:]
    private(set) var itemOrder: [Int64] = []
    private(set) var retryAttempts: [Int64: Int] = [:]
    private(set) var maximumConcurrentDownloads: Int

    @ObservationIgnored private let transport: EAPITransport
    @ObservationIgnored private let session: URLSession
    @ObservationIgnored private let retryPolicy: MusicDownloadRetryPolicy
    @ObservationIgnored private let resumeStore: MusicDownloadResumeStore
    @ObservationIgnored private let targetAllocator: MusicDownloadTargetAllocator
    @ObservationIgnored private var pendingRequests: [Int64: MusicDownloadRequest] = [:]
    @ObservationIgnored private var pendingOrder: [Int64] = []
    @ObservationIgnored private var activeTasks: [UUID: ActiveDownloadTask] = [:]
    @ObservationIgnored private var requestsBySongID: [Int64: MusicDownloadRequest] = [:]
    @ObservationIgnored private var resumeDataBySongID: [Int64: Data] = [:]
    @ObservationIgnored private var jobIDs: [Int64: UUID] = [:]
    @ObservationIgnored private var cloudSongIDs: Set<Int64> = []
    @ObservationIgnored private var requestedQualities: [Int64: AudioQuality] = [:]

    init(
        transport: EAPITransport = EAPITransport(),
        session: URLSession = .shared,
        maximumConcurrentDownloads: Int = 3,
        retryPolicy: MusicDownloadRetryPolicy = .standard,
        resumeStore: MusicDownloadResumeStore = .shared,
        targetAllocator: MusicDownloadTargetAllocator = .shared
    ) {
        self.transport = transport
        self.session = session
        self.maximumConcurrentDownloads = Self.clampedConcurrency(maximumConcurrentDownloads)
        self.retryPolicy = retryPolicy
        self.resumeStore = resumeStore
        self.targetAllocator = targetAllocator
    }

    isolated deinit {
        activeTasks.values.forEach { $0.task.cancel() }
    }

    @discardableResult
    func enqueue(
        song: Song,
        to destination: URL,
        quality: AudioQuality = .standard,
        includeLyrics: Bool = true
    ) -> Bool {
        enqueue(MusicDownloadRequest(
            songID: song.id,
            songName: song.name,
            artists: song.artistsDisplay,
            destination: destination,
            quality: quality,
            includeLyrics: includeLyrics,
            source: .catalog,
            expectedBytes: nil
        ))
    }

    @discardableResult
    func enqueue(
        cloudSong: CloudSong,
        userID: Int64,
        to destination: URL,
        includeLyrics: Bool = true
    ) -> Bool {
        guard userID > 0 else { return false }
        return enqueue(MusicDownloadRequest(
            songID: cloudSong.id,
            songName: cloudSong.name,
            artists: cloudSong.artist,
            destination: destination,
            quality: .standard,
            includeLyrics: includeLyrics,
            source: .cloud(userID: userID, fileName: cloudSong.fileName),
            expectedBytes: cloudSong.fileSize > 0 ? cloudSong.fileSize : nil
        ))
    }

    @discardableResult
    private func enqueue(_ request: MusicDownloadRequest) -> Bool {
        let songID = request.songID
        if requestedQualities[songID] == request.quality {
            switch states[songID] {
            case .queued, .running:
                return false
            case let .completed(audioURL, _) where FileManager.default.fileExists(atPath: audioURL.path):
                return false
            default:
                break
            }
        }
        if isActive(songID: songID) {
            pendingRequests.removeValue(forKey: songID)
            pendingOrder.removeAll { $0 == songID }
            activeTasks.values
                .filter { $0.songID == songID }
                .forEach { $0.task.cancel() }
            jobIDs.removeValue(forKey: songID)
            cloudSongIDs.remove(songID)
            discardResumeData(songID: songID)
        }
        if let previous = requestsBySongID[songID], previous != request {
            discardResumeData(songID: songID)
        }
        requestsBySongID[songID] = request
        requestedQualities[songID] = request.quality
        let quality = switch request.source {
        case .catalog: request.quality.rawValue
        case .cloud: "原文件"
        }
        items[songID] = MusicDownloadItem(
            id: songID,
            title: request.songName,
            artist: request.artists,
            quality: quality,
            expectedBytes: request.expectedBytes
        )
        itemOrder.removeAll { $0 == songID }
        itemOrder.insert(songID, at: 0)
        let jobID = UUID()
        jobIDs[songID] = jobID
        if case .cloud = request.source { cloudSongIDs.insert(songID) } else { cloudSongIDs.remove(songID) }
        retryAttempts[songID] = 0
        states[songID] = .queued
        pendingRequests[songID] = request
        pendingOrder.append(songID)
        schedulePendingDownloads()
        return true
    }

    func cancel(songID: Int64) {
        var foundTask = false
        if pendingRequests.removeValue(forKey: songID) != nil {
            pendingOrder.removeAll { $0 == songID }
            foundTask = true
        }
        let runningTasks = activeTasks.values.filter { $0.songID == songID }
        foundTask = foundTask || !runningTasks.isEmpty
        guard foundTask else { return }
        jobIDs.removeValue(forKey: songID)
        cloudSongIDs.remove(songID)
        retryAttempts[songID] = 0
        discardResumeData(songID: songID)
        states[songID] = .cancelled
        runningTasks.forEach { $0.task.cancel() }
        schedulePendingDownloads()
    }

    func cancelAll() {
        let affectedIDs = Set(pendingOrder + activeTasks.values.map(\.songID))
        pendingOrder.removeAll()
        pendingRequests.removeAll()
        jobIDs.removeAll()
        cloudSongIDs.removeAll()
        for songID in affectedIDs {
            retryAttempts[songID] = 0
            discardResumeData(songID: songID)
            states[songID] = .cancelled
        }
        activeTasks.values.forEach { $0.task.cancel() }
    }

    func cancelCloudDownloads() {
        for songID in Array(cloudSongIDs) {
            cancel(songID: songID)
        }
    }

    func retry(songID: Int64) {
        guard !isActive(songID: songID), let request = requestsBySongID[songID] else { return }
        _ = enqueue(request)
    }

    func setMaximumConcurrentDownloads(_ count: Int) {
        maximumConcurrentDownloads = Self.clampedConcurrency(count)
        schedulePendingDownloads()
    }

    func isActive(songID: Int64) -> Bool {
        pendingRequests[songID] != nil || activeTasks.values.contains { $0.songID == songID }
    }

    var runningDownloadCount: Int { activeTasks.count }
    var queuedDownloadCount: Int { pendingRequests.count }
    var maximumRetryCount: Int { retryPolicy.maximumRetryCount }

    private static func clampedConcurrency(_ count: Int) -> Int {
        min(max(count, 1), 5)
    }

    private func schedulePendingDownloads() {
        while activeTasks.count < maximumConcurrentDownloads, !pendingOrder.isEmpty {
            guard let pendingIndex = pendingOrder.firstIndex(where: { songID in
                !activeTasks.values.contains { $0.songID == songID }
            }) else { break }
            let songID = pendingOrder.remove(at: pendingIndex)
            guard let request = pendingRequests.removeValue(forKey: songID),
                  let jobID = jobIDs[songID]
            else { continue }
            start(request, songID: songID, jobID: jobID)
        }
    }

    private func start(_ request: MusicDownloadRequest, songID: Int64, jobID: UUID) {
        states[songID] = .running(progress: nil)
        let initialResumeData = resumeDataBySongID[songID] ?? resumeStore.load(for: request)
        if let initialResumeData { resumeDataBySongID[songID] = initialResumeData }
        let transport = transport
        let session = session
        let retryPolicy = retryPolicy
        let targetAllocator = targetAllocator
        let task = Task { @MainActor [self] in
            defer { self.finish(songID: songID, jobID: jobID) }
            do {
                let result = try await Self.perform(
                    request,
                    transport: transport,
                    session: session,
                    initialResumeData: initialResumeData,
                    retryPolicy: retryPolicy,
                    targetAllocator: targetAllocator,
                    update: { update in
                        Task { @MainActor in
                            self.apply(update, songID: songID, jobID: jobID, request: request)
                        }
                    }
                )
                guard self.jobIDs[songID] == jobID else { return }
                self.discardResumeData(songID: songID)
                self.retryAttempts[songID] = 0
                self.states[songID] = .completed(audioURL: result.audioURL, lyricURL: result.lyricURL)
            } catch {
                guard self.jobIDs[songID] == jobID else { return }
                if Task.isCancelled || Self.isCancellation(error) {
                    self.discardResumeData(songID: songID)
                    self.retryAttempts[songID] = 0
                    self.states[songID] = .cancelled
                } else {
                    let failure = error as? MusicDownloadFailure
                    if let resumeData = failure?.resumeData {
                        self.resumeDataBySongID[songID] = resumeData
                        self.resumeStore.save(resumeData, for: request)
                    }
                    self.states[songID] = .failed(failure?.localizedDescription ?? error.localizedDescription)
                }
            }
        }
        activeTasks[jobID] = ActiveDownloadTask(songID: songID, task: task)
    }

    private func apply(
        _ update: MusicDownloadUpdate,
        songID: Int64,
        jobID: UUID,
        request: MusicDownloadRequest
    ) {
        guard jobIDs[songID] == jobID, activeTasks[jobID] != nil else { return }
        if case .cancelled? = states[songID] { return }
        switch update {
        case let .metadata(level, expectedBytes):
            guard let item = items[songID] else { return }
            let updated = MusicDownloadItem(
                id: item.id,
                title: item.title,
                artist: item.artist,
                quality: level.map(Self.qualityLabel) ?? item.quality,
                expectedBytes: expectedBytes ?? item.expectedBytes
            )
            if updated != item { items[songID] = updated }
        case let .progress(value):
            let value = min(max(value, 0), 1)
            let current: Double? = if case let .running(progress)? = states[songID] { progress } else { nil }
            if let current, value <= current { return }
            states[songID] = .running(progress: current.map { max($0, value) } ?? value)
        case let .retrying(attempt, _, progress, resumeData, discardsResumeData):
            retryAttempts[songID] = attempt
            if discardsResumeData {
                discardResumeData(songID: songID)
            } else if let resumeData {
                resumeDataBySongID[songID] = resumeData
                resumeStore.save(resumeData, for: request)
            }
            let current: Double? = if case let .running(value)? = states[songID] { value } else { nil }
            let nextProgress = if let current, let progress {
                max(current, progress)
            } else {
                current ?? progress
            }
            states[songID] = .running(progress: nextProgress)
        }
    }

    private func discardResumeData(songID: Int64) {
        resumeDataBySongID.removeValue(forKey: songID)
        resumeStore.remove(songID: songID)
    }

    private nonisolated static func isCancellation(_ error: Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled
    }

    private func finish(songID: Int64, jobID: UUID) {
        activeTasks.removeValue(forKey: jobID)
        if jobIDs[songID] == jobID {
            jobIDs.removeValue(forKey: songID)
            cloudSongIDs.remove(songID)
        }
        schedulePendingDownloads()
    }

    private nonisolated static func perform(
        _ request: MusicDownloadRequest,
        transport: EAPITransport,
        session: URLSession,
        initialResumeData: Data?,
        retryPolicy: MusicDownloadRetryPolicy,
        targetAllocator: MusicDownloadTargetAllocator,
        update: @escaping @Sendable (MusicDownloadUpdate) -> Void
    ) async throws -> MusicDownloadResult {
        try Task.checkCancellation()
        let source = try await resolvedSource(for: request, transport: transport)
        update(.metadata(level: source.level, expectedBytes: source.expectedBytes))
        let hasSecurityScope = request.destination.startAccessingSecurityScopedResource()
        defer { if hasSecurityScope { request.destination.stopAccessingSecurityScopedResource() } }
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
        if let existing = MusicDownloadFiles.existingDownload(
            in: request.destination,
            stem: stem,
            audioExtension: fileExtension
        ) {
            update(.progress(1))
            return existing
        }
        let lyrics = try await downloadableLyrics(for: request, transport: transport)
        let audioProgressWeight = lyrics == nil ? 1.0 : 0.99
        let targets = await targetAllocator.reserve(
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

        do {
            let (temporaryURL, _) = try await downloadAudio(
                request: request,
                initialSource: source,
                transport: transport,
                session: session,
                initialResumeData: initialResumeData,
                retryPolicy: retryPolicy,
                audioProgressWeight: audioProgressWeight,
                update: update
            )
            try Task.checkCancellation()
            try MusicDownloadFiles.stageDownloadedFile(temporaryURL, at: targets.audioPart)
            update(.progress(audioProgressWeight))

            var hasLyrics = false
            if let lyrics {
                do {
                    try Task.checkCancellation()
                    try MusicDownloadFiles.stageData(Data(lyrics.utf8), at: targets.lyricPart)
                    hasLyrics = true
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
                do {
                    try MusicDownloadFiles.commit(partURL: targets.lyricPart, finalURL: targets.lyricFinal)
                    committed.append(targets.lyricFinal)
                } catch {
                    try? FileManager.default.removeItem(at: targets.lyricPart)
                    hasLyrics = false
                }
            }
            succeeded = true
            update(.progress(1))
            let result = MusicDownloadResult(
                audioURL: targets.audioFinal,
                lyricURL: hasLyrics ? targets.lyricFinal : nil
            )
            await targetAllocator.release(targets)
            return result
        } catch {
            await targetAllocator.release(targets)
            throw error
        }
    }

    private nonisolated static func downloadAudio(
        request: MusicDownloadRequest,
        initialSource: (url: URL, type: String, level: String?, expectedBytes: Int64?),
        transport: EAPITransport,
        session: URLSession,
        initialResumeData: Data?,
        retryPolicy: MusicDownloadRetryPolicy,
        audioProgressWeight: Double,
        update: @escaping @Sendable (MusicDownloadUpdate) -> Void
    ) async throws -> (URL, URLResponse) {
        var source = initialSource
        var resumeData = initialResumeData
        var needsFreshSource = false
        var lastError: Error = MusicDownloadError.invalidResponse

        for attempt in 1...retryPolicy.maximumAttempts {
            do {
                try Task.checkCancellation()
                if needsFreshSource {
                    source = try await resolvedSource(for: request, transport: transport)
                    update(.metadata(level: source.level, expectedBytes: source.expectedBytes))
                    needsFreshSource = false
                }

                let isCloud = if case .cloud = request.source { true } else { false }
                let delegate = MusicDownloadProgressDelegate(
                    progress: { update(.progress(overallProgress(audioProgress: $0, weight: audioProgressWeight))) },
                    expectedContentLength: source.expectedBytes
                ) { redirectedRequest in
                    !isCloud || redirectedRequest.url.map(CloudMusicDecoder.isAllowedDownloadURL) == true
                }

                let result: (URL, URLResponse)
                if let resumeData, !resumeData.isEmpty {
                    result = try await session.download(resumeFrom: resumeData, delegate: delegate)
                } else {
                    var urlRequest = URLRequest(url: source.url, timeoutInterval: 60)
                    urlRequest.setValue("TinyCloudMusic/1.0 macOS", forHTTPHeaderField: "User-Agent")
                    result = try await session.download(for: urlRequest, delegate: delegate)
                }

                guard let response = result.1 as? HTTPURLResponse else {
                    throw MusicDownloadError.invalidResponse
                }
                guard (200..<300).contains(response.statusCode) else {
                    throw MusicDownloadHTTPError(
                        statusCode: response.statusCode,
                        retryAfter: retryPolicy.retryAfter(from: response)
                    )
                }
                return result
            } catch {
                if Task.isCancelled || isCancellation(error) { throw CancellationError() }
                lastError = error
                let recoveredResumeData = retryPolicy.resumeData(from: error) ?? resumeData
                let retryable = retryPolicy.shouldRetry(error)
                let discardsResumeData = retryPolicy.shouldRefreshSource(after: error)
                    || (!retryable && resumeData != nil)
                if discardsResumeData {
                    resumeData = nil
                    needsFreshSource = true
                } else {
                    resumeData = recoveredResumeData
                }

                guard attempt < retryPolicy.maximumAttempts, retryable || discardsResumeData else {
                    throw MusicDownloadFailure(underlying: error, resumeData: resumeData, attempts: attempt)
                }

                let retry = attempt
                update(.retrying(
                    attempt: retry,
                    total: retryPolicy.maximumRetryCount,
                    progress: nil,
                    resumeData: resumeData,
                    discardsResumeData: discardsResumeData
                ))
                let retryAfter = (error as? MusicDownloadHTTPError)?.retryAfter
                let baseDelay = retryPolicy.delay(forRetry: retry, retryAfter: retryAfter)
                let delay = retryAfter == nil ? baseDelay * Double.random(in: 0.9...1.1) : baseDelay
                if delay > 0 { try await Task.sleep(for: .seconds(delay)) }
            }
        }
        throw MusicDownloadFailure(
            underlying: lastError,
            resumeData: resumeData,
            attempts: retryPolicy.maximumAttempts
        )
    }

    nonisolated static func overallProgress(audioProgress: Double, weight: Double) -> Double {
        min(max(audioProgress, 0), 1) * min(max(weight, 0), 1)
    }

    private nonisolated static func resolvedSource(
        for request: MusicDownloadRequest,
        transport: EAPITransport
    ) async throws -> (url: URL, type: String, level: String?, expectedBytes: Int64?) {
        if case .cloud = request.source {
            let source = try await LiveMusicLibrary(transport: transport).cloudDownloadSource(songID: request.songID)
            return (source.url, source.type, nil, request.expectedBytes)
        }

        let selection = try await downloadSelection(for: request, transport: transport)
        do {
            let source = try await audioSource(
                songID: request.songID,
                level: selection.level,
                requiresExactLevel: request.quality == .best,
                transport: transport
            )
            return (
                source.url,
                source.type,
                source.level,
                selection.sizes[source.level] ?? source.expectedBytes
            )
        } catch {
            guard request.quality == .best,
                  shouldRetryAtLowerLevel(after: error),
                  let fallbackLevel = nextLowerLevel(after: selection.level)
            else { throw error }
            let source = try await audioSource(
                songID: request.songID,
                level: fallbackLevel,
                requiresExactLevel: true,
                transport: transport
            )
            return (
                source.url,
                source.type,
                source.level,
                selection.sizes[source.level] ?? source.expectedBytes
            )
        }
    }

    nonisolated static func downloadLevel(
        for request: MusicDownloadRequest,
        transport: EAPITransport
    ) async throws -> String {
        try await downloadSelection(for: request, transport: transport).level
    }

    private nonisolated static func downloadSelection(
        for request: MusicDownloadRequest,
        transport: EAPITransport
    ) async throws -> (level: String, sizes: [String: Int64]) {
        let requestedLevel: String = switch request.quality {
        case .standard: "standard"
        case .lossless: "lossless"
        case .best: ""
        }
        let qualities: [SongQualityDetail]
        do {
            qualities = try await LiveMusicRepository(transport: transport)
                .songQualityDetails(for: request.songID)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if request.quality == .best { throw error }
            return (requestedLevel, [:])
        }
        let level = request.quality == .best
            ? SongQualityDetail.highestAvailableLevel(in: qualities)
            : requestedLevel
        guard let level, !level.isEmpty else {
            throw EAPIError.missingData("highestAvailableQuality")
        }
        return (level, Dictionary(uniqueKeysWithValues: qualities.map { ($0.id, $0.size) }))
    }

    nonisolated static func audioSource(
        songID: Int64,
        level: String,
        requiresExactLevel: Bool,
        transport: EAPITransport
    ) async throws -> (url: URL, type: String, level: String, expectedBytes: Int64?) {
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
        let size = value.int64("size")
        return (url, value.string("type"), actualLevel.nonEmpty ?? level, size > 0 ? size : nil)
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

    private nonisolated static func downloadableLyrics(
        for request: MusicDownloadRequest,
        transport: EAPITransport
    ) async throws -> String? {
        guard request.includeLyrics else { return nil }
        do {
            return try await mergedLyrics(for: request, transport: transport).nonEmpty
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return nil
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
        case "standard": "标准"
        case "higher": "较高"
        case "exhigh": "极高"
        case "lossless": "无损"
        case "hires": "Hi-Res"
        case "jyeffect": "高清环绕声"
        case "sky": "沉浸环绕声"
        case "jymaster": "超清母带"
        case "dolby": "杜比全景声"
        default: level
        }
    }
}

private final class MusicDownloadProgressDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let progress: @Sendable (Double) -> Void
    let allowsRequest: @Sendable (URLRequest) -> Bool
    let expectedContentLength: Int64?
    private let lock = NSLock()
    private var throttle = MusicDownloadProgressThrottle()

    init(
        progress: @escaping @Sendable (Double) -> Void,
        expectedContentLength: Int64? = nil,
        allowsRequest: @escaping @Sendable (URLRequest) -> Bool = { _ in true }
    ) {
        self.progress = progress
        self.expectedContentLength = expectedContentLength
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
            totalBytesExpectedToWrite: totalBytesExpectedToWrite,
            responseExpectedContentLength: expectedContentLength
                ?? downloadTask.response?.expectedContentLength
                ?? NSURLSessionTransferSizeUnknown
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
