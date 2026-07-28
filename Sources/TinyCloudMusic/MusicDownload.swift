import Foundation
import Observation

@MainActor
@Observable
final class MusicDownloadManager {
    private enum DownloadKey: Hashable {
        case music(Int64)
        case video(String)
    }

    private struct ActiveDownloadTask {
        let key: DownloadKey
        let task: Task<Void, Never>

        var songID: Int64? {
            if case let .music(id) = key { id } else { nil }
        }
    }

    private enum PendingDownload {
        case music(songID: Int64, jobID: UUID)
        case video(id: String, jobID: UUID)

        var key: DownloadKey {
            switch self {
            case let .music(songID, _): .music(songID)
            case let .video(id, _): .video(id)
            }
        }

    }

    private struct ResolvedSource: Sendable {
        let url: URL
        let type: String
        let level: String?
        let expectedBytes: Int64?
    }

    private struct DownloadedAudio: Sendable {
        let temporaryURL: URL
        let source: ResolvedSource
        let isCached: Bool
    }

    private(set) var states: [Int64: MusicDownloadState] = [:]
    private(set) var items: [Int64: MusicDownloadItem] = [:]
    private(set) var itemOrder: [Int64] = []
    private(set) var retryAttempts: [Int64: Int] = [:]
    private(set) var videoStates: [String: MusicDownloadState] = [:]
    private(set) var videoItems: [String: VideoDownloadItem] = [:]
    private(set) var videoItemOrder: [String] = []
    private(set) var maximumConcurrentDownloads: Int

    @ObservationIgnored private let transport: EAPITransport
    @ObservationIgnored private let session: URLSession
    @ObservationIgnored private let retryPolicy: MusicDownloadRetryPolicy
    @ObservationIgnored private let resumeStore: MusicDownloadResumeStore
    @ObservationIgnored private let targetAllocator: MusicDownloadTargetAllocator
    @ObservationIgnored private var cacheRoot: URL?
    @ObservationIgnored private var audioCache: TrackCache?
    @ObservationIgnored private var pendingRequests: [Int64: MusicDownloadRequest] = [:]
    @ObservationIgnored private var pendingVideoRequests: [String: VideoDownloadRequest] = [:]
    @ObservationIgnored private var pendingOrder: [PendingDownload] = []
    @ObservationIgnored private var pendingHead = 0
    @ObservationIgnored private var activeTasks: [UUID: ActiveDownloadTask] = [:]
    @ObservationIgnored private var requestsBySongID: [Int64: MusicDownloadRequest] = [:]
    @ObservationIgnored private var resumeDataBySongID: [Int64: Data] = [:]
    @ObservationIgnored private var jobIDs: [Int64: UUID] = [:]
    @ObservationIgnored private var videoRequests: [String: VideoDownloadRequest] = [:]
    @ObservationIgnored private var videoJobIDs: [String: UUID] = [:]
    @ObservationIgnored private var pausingSongIDs: Set<Int64> = []
    @ObservationIgnored private var resumeAfterPauseSongIDs: Set<Int64> = []
    @ObservationIgnored private var pausingVideoIDs: Set<String> = []
    @ObservationIgnored private var resumeAfterPauseVideoIDs: Set<String> = []
    @ObservationIgnored private var bufferedProgress: [Int64: (jobID: UUID, value: Double)] = [:]
    @ObservationIgnored private var bufferedVideoProgress: [String: (jobID: UUID, value: Double)] = [:]
    @ObservationIgnored private var progressFlushTask: Task<Void, Never>?

    init(
        transport: EAPITransport = EAPITransport(),
        session: URLSession = .shared,
        maximumConcurrentDownloads: Int = 3,
        retryPolicy: MusicDownloadRetryPolicy = .standard,
        resumeStore: MusicDownloadResumeStore = .shared,
        targetAllocator: MusicDownloadTargetAllocator = .shared,
        cacheRoot: URL? = nil
    ) {
        self.transport = transport
        self.session = session
        self.maximumConcurrentDownloads = Self.clampedConcurrency(maximumConcurrentDownloads)
        self.retryPolicy = retryPolicy
        self.resumeStore = resumeStore
        self.targetAllocator = targetAllocator
        self.cacheRoot = cacheRoot
        audioCache = cacheRoot.map(Self.makeAudioCache)

        for recovery in resumeStore.recoverableDownloads() {
            if let resumeData = recovery.resumeData {
                resumeDataBySongID[recovery.request.songID] = resumeData
            }
            _ = enqueue(recovery.request, persist: false)
        }
    }

    isolated deinit {
        activeTasks.values.forEach { $0.task.cancel() }
        progressFlushTask?.cancel()
    }

    func configure(cacheRoot: URL) {
        guard self.cacheRoot?.standardizedFileURL != cacheRoot.standardizedFileURL else { return }
        self.cacheRoot = cacheRoot
        audioCache = Self.makeAudioCache(cacheRoot)
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
    func enqueue(
        video resource: VideoPageResource,
        title: String,
        creator: String,
        availableResolutions: [Int],
        to destination: URL,
        quality: VideoQuality
    ) -> Bool {
        enqueue(VideoDownloadRequest(
            resource: resource,
            title: title,
            creator: creator,
            destination: destination,
            quality: quality,
            availableResolutions: availableResolutions
        ))
    }

    @discardableResult
    private func enqueue(_ request: VideoDownloadRequest) -> Bool {
        let id = request.resource.identity
        let wasKnown = videoItems[id] != nil
        if videoRequests[id] == request {
            switch videoStates[id] {
            case .queued, .running:
                return false
            case let .completed(fileURL, _) where FileManager.default.fileExists(atPath: fileURL.path):
                return false
            default:
                break
            }
        }
        if isVideoActive(id: id) {
            pausingVideoIDs.remove(id)
            resumeAfterPauseVideoIDs.remove(id)
            pendingVideoRequests.removeValue(forKey: id)
            activeTasks.values
                .filter { $0.key == .video(id) }
                .forEach { $0.task.cancel() }
            videoJobIDs.removeValue(forKey: id)
        }
        resumeAfterPauseVideoIDs.remove(id)
        videoRequests[id] = request
        videoItems[id] = VideoDownloadItem(
            id: id,
            title: request.title,
            creator: request.creator,
            quality: request.quality.rawValue
        )
        if wasKnown { videoItemOrder.removeAll { $0 == id } }
        videoItemOrder.append(id)
        let jobID = UUID()
        videoJobIDs[id] = jobID
        videoStates[id] = .queued
        pendingVideoRequests[id] = request
        pendingOrder.append(.video(id: id, jobID: jobID))
        schedulePendingDownloads()
        return true
    }

    @discardableResult
    private func enqueue(_ request: MusicDownloadRequest, persist: Bool = true) -> Bool {
        let songID = request.songID
        let wasKnown = items[songID] != nil
        if requestsBySongID[songID] == request {
            switch states[songID] {
            case .queued, .running:
                return false
            case let .completed(audioURL, _) where (try? MusicDownloadFiles.validatedAudioFileSize(at: audioURL)) != nil:
                return false
            default:
                break
            }
        }
        if isActive(songID: songID) {
            pausingSongIDs.remove(songID)
            resumeAfterPauseSongIDs.remove(songID)
            pendingRequests.removeValue(forKey: songID)
            activeTasks.values
                .filter { $0.songID == songID }
                .forEach { $0.task.cancel() }
            jobIDs.removeValue(forKey: songID)
            discardResumeData(songID: songID)
        }
        if let previous = requestsBySongID[songID], previous != request {
            discardResumeData(songID: songID)
        }
        resumeAfterPauseSongIDs.remove(songID)
        requestsBySongID[songID] = request
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
        if wasKnown { itemOrder.removeAll { $0 == songID } }
        itemOrder.append(songID)
        let jobID = UUID()
        jobIDs[songID] = jobID
        retryAttempts[songID] = 0
        states[songID] = .queued
        pendingRequests[songID] = request
        pendingOrder.append(.music(songID: songID, jobID: jobID))
        if persist {
            resumeStore.save(request, resumeData: resumeDataBySongID[songID])
        }
        schedulePendingDownloads()
        return true
    }

    func cancel(songID: Int64) {
        var foundTask = switch states[songID] {
        case .paused?, .failed?: true
        default: false
        }
        if pendingRequests.removeValue(forKey: songID) != nil {
            foundTask = true
        }
        let runningTasks = activeTasks.values.filter { $0.songID == songID }
        foundTask = foundTask || !runningTasks.isEmpty
        guard foundTask else { return }
        pausingSongIDs.remove(songID)
        resumeAfterPauseSongIDs.remove(songID)
        jobIDs.removeValue(forKey: songID)
        bufferedProgress.removeValue(forKey: songID)
        retryAttempts[songID] = 0
        discardResumeData(songID: songID)
        states[songID] = .cancelled
        runningTasks.forEach { $0.task.cancel() }
        schedulePendingDownloads()
        trimHistory()
    }

    func cancelAll() {
        let pausedIDs = states.compactMap { songID, state in
            if case .paused = state { songID } else { nil }
        }
        let affectedIDs = Set(pendingRequests.keys)
            .union(activeTasks.values.compactMap(\.songID))
            .union(pausedIDs)
        let pausedVideoIDs = videoStates.compactMap { id, state in
            if case .paused = state { id } else { nil }
        }
        let affectedVideoIDs = Set(pendingVideoRequests.keys)
            .union(activeTasks.values.compactMap { active in
                if case let .video(id) = active.key { id } else { nil }
            })
            .union(pausedVideoIDs)
        pendingOrder.removeAll()
        pendingHead = 0
        pendingRequests.removeAll()
        pendingVideoRequests.removeAll()
        jobIDs.removeAll()
        videoJobIDs.removeAll()
        pausingSongIDs.removeAll()
        resumeAfterPauseSongIDs.removeAll()
        pausingVideoIDs.removeAll()
        resumeAfterPauseVideoIDs.removeAll()
        bufferedProgress.removeAll()
        bufferedVideoProgress.removeAll()
        for songID in affectedIDs {
            retryAttempts[songID] = 0
            discardResumeData(songID: songID)
            states[songID] = .cancelled
        }
        for id in affectedVideoIDs { videoStates[id] = .cancelled }
        activeTasks.values.forEach { $0.task.cancel() }
        trimHistory()
        trimVideoHistory()
    }

    func pause(songID: Int64) {
        guard let request = requestsBySongID[songID] else { return }
        resumeAfterPauseSongIDs.remove(songID)
        let wasPending = pendingRequests.removeValue(forKey: songID) != nil
        let currentJobID = jobIDs[songID]
        let runningTasks = activeTasks.compactMap { jobID, active in
            jobID == currentJobID && active.songID == songID ? active : nil
        }
        guard wasPending || !runningTasks.isEmpty else { return }
        let currentProgress: Double? = switch states[songID] {
        case let .running(progress), let .paused(progress): progress
        default: nil
        }
        let progress = max(
            currentProgress ?? 0,
            bufferedProgress.removeValue(forKey: songID)?.value ?? 0
        )
        states[songID] = .paused(progress: progress > 0 ? progress : nil)
        retryAttempts[songID] = 0
        resumeStore.save(request, resumeData: resumeDataBySongID[songID])
        if runningTasks.isEmpty {
            jobIDs.removeValue(forKey: songID)
        } else {
            pausingSongIDs.insert(songID)
            runningTasks.forEach { $0.task.cancel() }
        }
        schedulePendingDownloads()
    }

    func pauseAll() async {
        let affected = Set(pendingRequests.keys).union(activeTasks.values.compactMap(\.songID))
        let ordered = itemOrder.filter(affected.contains)
            + affected.subtracting(itemOrder).sorted()
        for songID in ordered {
            pause(songID: songID)
        }
        let affectedVideos = Set(pendingVideoRequests.keys).union(activeTasks.values.compactMap { active in
            if case let .video(id) = active.key { id } else { nil }
        })
        let orderedVideos = videoItemOrder.filter(affectedVideos.contains)
            + affectedVideos.subtracting(videoItemOrder).sorted()
        for id in orderedVideos { pauseVideo(id: id) }
        // ponytail: manifests are already durable; bound native callback wait so app termination cannot hang forever.
        for _ in 0..<100 where !activeTasks.isEmpty {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    func cancelCloudDownloads(exceptUserID: Int64? = nil) {
        for (songID, request) in requestsBySongID {
            guard case let .cloud(userID, _) = request.source,
                  userID != exceptUserID
            else { continue }
            cancel(songID: songID)
        }
    }

    func retry(songID: Int64) {
        guard let request = requestsBySongID[songID] else { return }
        if case .paused? = states[songID], isActive(songID: songID) {
            resumeAfterPauseSongIDs.insert(songID)
            return
        }
        guard !isActive(songID: songID) else { return }
        _ = enqueue(request)
    }

    func cancelVideo(id: String) {
        var foundTask = switch videoStates[id] {
        case .paused?, .failed?: true
        default: false
        }
        if pendingVideoRequests.removeValue(forKey: id) != nil { foundTask = true }
        let runningTasks = activeTasks.values.filter { $0.key == .video(id) }
        foundTask = foundTask || !runningTasks.isEmpty
        guard foundTask else { return }
        pausingVideoIDs.remove(id)
        resumeAfterPauseVideoIDs.remove(id)
        videoJobIDs.removeValue(forKey: id)
        bufferedVideoProgress.removeValue(forKey: id)
        videoStates[id] = .cancelled
        runningTasks.forEach { $0.task.cancel() }
        schedulePendingDownloads()
        trimVideoHistory()
    }

    func pauseVideo(id: String) {
        guard videoRequests[id] != nil else { return }
        resumeAfterPauseVideoIDs.remove(id)
        let wasPending = pendingVideoRequests.removeValue(forKey: id) != nil
        let currentJobID = videoJobIDs[id]
        let runningTasks = activeTasks.compactMap { jobID, active in
            jobID == currentJobID && active.key == .video(id) ? active : nil
        }
        guard wasPending || !runningTasks.isEmpty else { return }
        let currentProgress: Double? = switch videoStates[id] {
        case let .running(progress), let .paused(progress): progress
        default: nil
        }
        let progress = max(
            currentProgress ?? 0,
            bufferedVideoProgress.removeValue(forKey: id)?.value ?? 0
        )
        videoStates[id] = .paused(progress: progress > 0 ? progress : nil)
        if runningTasks.isEmpty {
            videoJobIDs.removeValue(forKey: id)
        } else {
            pausingVideoIDs.insert(id)
            runningTasks.forEach { $0.task.cancel() }
        }
        schedulePendingDownloads()
    }

    func retryVideo(id: String) {
        guard let request = videoRequests[id] else { return }
        if case .paused? = videoStates[id], isVideoActive(id: id) {
            resumeAfterPauseVideoIDs.insert(id)
            return
        }
        guard !isVideoActive(id: id) else { return }
        _ = enqueue(request)
    }

    func setMaximumConcurrentDownloads(_ count: Int) {
        maximumConcurrentDownloads = Self.clampedConcurrency(count)
        schedulePendingDownloads()
    }

    func isActive(songID: Int64) -> Bool {
        pendingRequests[songID] != nil || activeTasks.values.contains { $0.key == .music(songID) }
    }

    func isVideoActive(id: String) -> Bool {
        pendingVideoRequests[id] != nil || activeTasks.values.contains { $0.key == .video(id) }
    }

    var runningDownloadCount: Int { activeTasks.count }
    var queuedDownloadCount: Int { pendingRequests.count + pendingVideoRequests.count }
    var maximumRetryCount: Int { retryPolicy.maximumRetryCount }

    private static func clampedConcurrency(_ count: Int) -> Int {
        min(max(count, 1), 5)
    }

    private func schedulePendingDownloads() {
        while activeTasks.count < maximumConcurrentDownloads, pendingHead < pendingOrder.count {
            while pendingHead < pendingOrder.count {
                let pending = pendingOrder[pendingHead]
                if isCurrent(pending) { break }
                pendingHead += 1
            }
            guard pendingHead < pendingOrder.count else { break }

            let index = (pendingHead..<pendingOrder.count).first { index in
                let candidate = pendingOrder[index]
                return isCurrent(candidate)
                    && !activeTasks.values.contains(where: { $0.key == candidate.key })
            }
            guard let index else { break }
            if index != pendingHead { pendingOrder.swapAt(index, pendingHead) }

            let pending = pendingOrder[pendingHead]
            pendingHead += 1
            switch pending {
            case let .music(songID, jobID):
                guard let request = pendingRequests.removeValue(forKey: songID),
                      jobIDs[songID] == jobID
                else { continue }
                start(request, songID: songID, jobID: jobID)
            case let .video(id, jobID):
                guard let request = pendingVideoRequests.removeValue(forKey: id),
                      videoJobIDs[id] == jobID
                else { continue }
                start(request, id: id, jobID: jobID)
            }
        }
        if pendingHead == pendingOrder.count {
            pendingOrder.removeAll(keepingCapacity: true)
            pendingHead = 0
        } else if pendingHead >= 1_024, pendingHead * 2 >= pendingOrder.count {
            pendingOrder.removeFirst(pendingHead)
            pendingHead = 0
        }
    }

    private func isCurrent(_ pending: PendingDownload) -> Bool {
        switch pending {
        case let .music(songID, jobID): jobIDs[songID] == jobID
        case let .video(id, jobID): videoJobIDs[id] == jobID
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
        let cacheRoot = cacheRoot
        let audioCache = audioCache
        let task = Task { @MainActor [weak self] in
            do {
                let result = try await Self.perform(
                    request,
                    transport: transport,
                    session: session,
                    initialResumeData: initialResumeData,
                    retryPolicy: retryPolicy,
                    targetAllocator: targetAllocator,
                    cacheRoot: cacheRoot,
                    audioCache: audioCache,
                    update: { [weak self] update in
                        Task { @MainActor [weak self] in
                            self?.apply(update, songID: songID, jobID: jobID, request: request)
                        }
                    }
                )
                self?.complete(result, songID: songID, jobID: jobID)
            } catch {
                self?.fail(error, request: request, songID: songID, jobID: jobID)
            }
            self?.finish(songID: songID, jobID: jobID)
        }
        activeTasks[jobID] = ActiveDownloadTask(key: .music(songID), task: task)
    }

    private func start(_ request: VideoDownloadRequest, id: String, jobID: UUID) {
        videoStates[id] = .running(progress: nil)
        let transport = transport
        let configuration = session.configuration
        let cacheRoot = cacheRoot
        let task = Task { @MainActor [weak self] in
            do {
                let result = try await Self.performVideo(
                    request,
                    transport: transport,
                    configuration: configuration,
                    cacheRoot: cacheRoot,
                    update: { [weak self] resolution, progress in
                        Task { @MainActor [weak self] in
                            self?.applyVideo(
                                resolution: resolution,
                                progress: progress,
                                id: id,
                                jobID: jobID
                            )
                        }
                    }
                )
                self?.completeVideo(result, id: id, jobID: jobID)
            } catch {
                self?.failVideo(error, id: id, jobID: jobID)
            }
            self?.finishVideo(id: id, jobID: jobID)
        }
        activeTasks[jobID] = ActiveDownloadTask(key: .video(id), task: task)
    }

    private func complete(_ result: MusicDownloadResult, songID: Int64, jobID: UUID) {
        guard jobIDs[songID] == jobID else { return }
        pausingSongIDs.remove(songID)
        resumeAfterPauseSongIDs.remove(songID)
        discardResumeData(songID: songID)
        retryAttempts[songID] = 0
        states[songID] = .completed(audioURL: result.audioURL, lyricURL: result.lyricURL)
        trimHistory()
    }

    private func completeVideo(_ url: URL, id: String, jobID: UUID) {
        guard videoJobIDs[id] == jobID else { return }
        pausingVideoIDs.remove(id)
        resumeAfterPauseVideoIDs.remove(id)
        videoStates[id] = .completed(audioURL: url, lyricURL: nil)
        trimVideoHistory()
    }

    private func fail(_ error: Error, request: MusicDownloadRequest, songID: Int64, jobID: UUID) {
        guard jobIDs[songID] == jobID else { return }
        let failure = error as? MusicDownloadFailure
        if pausingSongIDs.remove(songID) != nil {
            let resumeData = failure?.resumeData ?? resumeDataBySongID[songID]
            if let resumeData { resumeDataBySongID[songID] = resumeData }
            resumeStore.save(request, resumeData: resumeData)
            retryAttempts[songID] = 0
            return
        }
        if Task.isCancelled || Self.isCancellation(error) {
            discardResumeData(songID: songID)
            retryAttempts[songID] = 0
            states[songID] = .cancelled
            trimHistory()
            return
        }

        if let resumeData = failure?.resumeData {
            resumeDataBySongID[songID] = resumeData
            resumeStore.save(request, resumeData: resumeData)
        } else {
            discardResumeData(songID: songID)
        }
        states[songID] = .failed(failure?.localizedDescription ?? error.localizedDescription)
        trimHistory()
    }

    private func failVideo(_ error: Error, id: String, jobID: UUID) {
        guard videoJobIDs[id] == jobID else { return }
        if pausingVideoIDs.remove(id) != nil { return }
        if Task.isCancelled || Self.isCancellation(error) {
            videoStates[id] = .cancelled
        } else {
            videoStates[id] = .failed(error.localizedDescription)
        }
        trimVideoHistory()
    }

    private func apply(
        _ update: MusicDownloadUpdate,
        songID: Int64,
        jobID: UUID,
        request: MusicDownloadRequest
    ) {
        guard jobIDs[songID] == jobID, activeTasks[jobID] != nil else { return }
        guard case .running? = states[songID] else { return }
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
            if updated.expectedBytes != nil, case .running(progress: nil)? = states[songID] {
                states[songID] = .running(progress: 0)
            }
        case let .progress(value):
            let value = min(max(value, 0), 1)
            if value > (bufferedProgress[songID]?.value ?? -1) {
                bufferedProgress[songID] = (jobID, value)
                scheduleProgressFlush()
            }
        case let .retrying(attempt, _, progress, resumeData, discardsResumeData):
            retryAttempts[songID] = attempt
            if discardsResumeData {
                resumeDataBySongID.removeValue(forKey: songID)
                resumeStore.save(request)
            } else if let resumeData {
                resumeDataBySongID[songID] = resumeData
                resumeStore.save(request, resumeData: resumeData)
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

    private func applyVideo(resolution: Int?, progress: Double?, id: String, jobID: UUID) {
        guard videoJobIDs[id] == jobID,
              activeTasks[jobID] != nil,
              case .running? = videoStates[id]
        else { return }
        if let resolution, let item = videoItems[id] {
            videoItems[id] = VideoDownloadItem(
                id: item.id,
                title: item.title,
                creator: item.creator,
                quality: "\(resolution)P"
            )
        }
        if let progress {
            let value = min(max(progress, 0), 1)
            if value > (bufferedVideoProgress[id]?.value ?? -1) {
                bufferedVideoProgress[id] = (jobID, value)
                scheduleProgressFlush()
            }
        }
    }

    private func scheduleProgressFlush() {
        guard progressFlushTask == nil else { return }
        progressFlushTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(100))
                self?.flushProgress()
            } catch {
            }
        }
    }

    private func flushProgress() {
        progressFlushTask = nil
        let updates = bufferedProgress
        bufferedProgress.removeAll(keepingCapacity: true)
        var validUpdates: [Int64: Double] = [:]
        for (songID, update) in updates {
            guard jobIDs[songID] == update.jobID,
                  activeTasks[update.jobID] != nil
            else { continue }
            validUpdates[songID] = update.value
        }
        let nextStates = Self.mergingProgress(validUpdates, into: states)
        if nextStates != states { states = nextStates }
        let videoUpdates = bufferedVideoProgress
        bufferedVideoProgress.removeAll(keepingCapacity: true)
        for (id, update) in videoUpdates {
            guard videoJobIDs[id] == update.jobID,
                  activeTasks[update.jobID] != nil,
                  case let .running(current)? = videoStates[id],
                  current.map({ update.value > $0 }) ?? true
            else { continue }
            videoStates[id] = .running(progress: update.value)
        }
    }

    nonisolated static func mergingProgress(
        _ updates: [Int64: Double],
        into states: [Int64: MusicDownloadState]
    ) -> [Int64: MusicDownloadState] {
        var result = states
        for (songID, value) in updates {
            guard case let .running(current)? = result[songID],
                  current.map({ value > $0 }) ?? true
            else { continue }
            result[songID] = .running(progress: value)
        }
        return result
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
        let shouldResume = resumeAfterPauseSongIDs.contains(songID)
            && !activeTasks.values.contains(where: { $0.songID == songID })
            && states[songID].map({ state in
                if case .paused = state { true } else { false }
            }) == true
        if shouldResume { resumeAfterPauseSongIDs.remove(songID) }
        if jobIDs[songID] == jobID {
            pausingSongIDs.remove(songID)
            jobIDs.removeValue(forKey: songID)
        }
        if shouldResume, let request = requestsBySongID[songID] {
            _ = enqueue(request)
            trimHistory()
            return
        }
        schedulePendingDownloads()
        trimHistory()
    }

    private func finishVideo(id: String, jobID: UUID) {
        activeTasks.removeValue(forKey: jobID)
        let shouldResume = resumeAfterPauseVideoIDs.contains(id)
            && !activeTasks.values.contains(where: { $0.key == .video(id) })
            && videoStates[id].map({ state in
                if case .paused = state { true } else { false }
            }) == true
        if shouldResume { resumeAfterPauseVideoIDs.remove(id) }
        if videoJobIDs[id] == jobID {
            pausingVideoIDs.remove(id)
            videoJobIDs.removeValue(forKey: id)
        }
        if shouldResume, let request = videoRequests[id] {
            _ = enqueue(request)
            trimVideoHistory()
            return
        }
        schedulePendingDownloads()
        trimVideoHistory()
    }

    private func trimHistory(limit: Int = 500) {
        let excess = itemOrder.count - limit
        guard excess > 0 else { return }
        let victims = itemOrder.lazy.filter { songID in
            guard !self.isActive(songID: songID), let state = self.states[songID] else { return false }
            switch state {
            case .completed, .failed, .cancelled: return true
            case .queued, .running, .paused: return false
            }
        }.prefix(excess)
        let victimIDs = Set(victims)
        guard !victimIDs.isEmpty else { return }
        itemOrder.removeAll { victimIDs.contains($0) }
        for songID in victimIDs {
            states.removeValue(forKey: songID)
            items.removeValue(forKey: songID)
            retryAttempts.removeValue(forKey: songID)
            requestsBySongID.removeValue(forKey: songID)
            discardResumeData(songID: songID)
        }
    }

    private func trimVideoHistory(limit: Int = 500) {
        let excess = videoItemOrder.count - limit
        guard excess > 0 else { return }
        let victims = videoItemOrder.lazy.filter { id in
            guard !self.isVideoActive(id: id), let state = self.videoStates[id] else { return false }
            switch state {
            case .completed, .failed, .cancelled: return true
            case .queued, .running, .paused: return false
            }
        }.prefix(excess)
        let victimIDs = Set(victims)
        videoItemOrder.removeAll { victimIDs.contains($0) }
        for id in victimIDs {
            videoStates.removeValue(forKey: id)
            videoItems.removeValue(forKey: id)
            videoRequests.removeValue(forKey: id)
        }
    }

    private nonisolated static func performVideo(
        _ request: VideoDownloadRequest,
        transport: EAPITransport,
        configuration: URLSessionConfiguration,
        cacheRoot: URL?,
        update: @escaping @Sendable (_ resolution: Int?, _ progress: Double?) -> Void
    ) async throws -> URL {
        var lastError: Error = VideoLibraryError.unavailable("全部清晰度均不可用")
        let library = LiveVideoLibrary(transport: transport)
        let fileTitle = switch request.resource {
        case .mv: request.creator.isEmpty ? request.title : "\(request.creator) - \(request.title)"
        case .video: request.title
        }
        for resolution in VideoResolutionPolicy.downloadCandidates(
            for: request.quality,
            available: request.availableResolutions
        ) {
            do {
                try Task.checkCancellation()
                update(resolution, nil)
                if let cacheRoot,
                   let cached = try await VideoFileDownload.copyCachedFile(
                       identity: request.resource.identity,
                       title: fileTitle,
                       resolution: resolution,
                       cacheRoot: cacheRoot,
                       to: request.destination
                   ) {
                    update(nil, 1)
                    return cached
                }

                let source = switch request.resource {
                case let .mv(id):
                    try await library.mvPlaybackSource(
                        id: id,
                        preferredResolution: resolution,
                        availableResolutions: [resolution]
                    )
                case let .video(id):
                    try await library.videoPlaybackSource(
                        id: id,
                        preferredResolution: resolution,
                        availableResolutions: [resolution]
                    )
                }
                update(source.resolution, nil)
                if let cacheRoot,
                   let cached = try await VideoFileDownload.copyCachedFile(
                       identity: request.resource.identity,
                       title: fileTitle,
                       resolution: source.resolution,
                       cacheRoot: cacheRoot,
                       to: request.destination
                   ) {
                    update(nil, 1)
                    return cached
                }
                return try await VideoFileDownload.download(
                    source.url,
                    title: fileTitle,
                    resolution: source.resolution,
                    to: request.destination,
                    cacheIdentity: request.resource.identity,
                    cacheRoot: cacheRoot,
                    configuration: configuration
                ) { update(nil, $0) }
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as URLError where error.code == .cancelled && Task.isCancelled {
                throw CancellationError()
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    private nonisolated static func perform(
        _ request: MusicDownloadRequest,
        transport: EAPITransport,
        session: URLSession,
        initialResumeData: Data?,
        retryPolicy: MusicDownloadRetryPolicy,
        targetAllocator: MusicDownloadTargetAllocator,
        cacheRoot: URL?,
        audioCache: TrackCache?,
        update: @escaping @Sendable (MusicDownloadUpdate) -> Void
    ) async throws -> MusicDownloadResult {
        try Task.checkCancellation()
        let concreteLevel: String? = switch request.source {
        case .catalog: try await downloadLevel(for: request, transport: transport)
        case .cloud: nil
        }
        update(.metadata(level: concreteLevel, expectedBytes: nil))

        let hasCacheSecurityScope = cacheRoot?.startAccessingSecurityScopedResource() == true
        defer { if hasCacheSecurityScope { cacheRoot?.stopAccessingSecurityScopedResource() } }
        let hasSecurityScope = request.destination.startAccessingSecurityScopedResource()
        defer { if hasSecurityScope { request.destination.stopAccessingSecurityScopedResource() } }
        try FileManager.default.createDirectory(at: request.destination, withIntermediateDirectories: true)

        let audioProgressWeight = request.includeLyrics ? 0.99 : 1
        async let lyrics = downloadableLyrics(for: request, transport: transport, cacheRoot: cacheRoot)
        let desiredCacheQuality = cacheQuality(for: request, level: concreteLevel)
        let audio: DownloadedAudio
        if let cached = audioCache?.readyCachedFile(for: request.songID, quality: desiredCacheQuality) {
            audio = DownloadedAudio(
                temporaryURL: cached.url,
                source: ResolvedSource(
                    url: cached.url,
                    type: cached.fileExtension,
                    level: concreteLevel,
                    expectedBytes: cached.size
                ),
                isCached: true
            )
        } else {
            let initialSource = try await resolvedSourceWithRetry(
                for: request,
                transport: transport,
                retryPolicy: retryPolicy,
                update: update
            )
            let actualQuality = cacheQuality(for: request, level: initialSource.level)
            if let cached = audioCache?.readyCachedFile(for: request.songID, quality: actualQuality) {
                audio = DownloadedAudio(
                    temporaryURL: cached.url,
                    source: ResolvedSource(
                        url: cached.url,
                        type: cached.fileExtension,
                        level: initialSource.level,
                        expectedBytes: cached.size
                    ),
                    isCached: true
                )
            } else {
                audio = try await downloadAudio(
                    request: request,
                    initialSource: initialSource,
                    transport: transport,
                    session: session,
                    initialResumeData: initialResumeData,
                    retryPolicy: retryPolicy,
                    audioProgressWeight: audioProgressWeight,
                    update: update
                )
                if let audioCache {
                    let downloadedQuality = cacheQuality(for: request, level: audio.source.level)
                    _ = try? await audioCache.storeCopy(
                        of: audio.temporaryURL,
                        for: request.songID,
                        quality: downloadedQuality,
                        fileExtension: audio.source.type
                    )
                }
            }
        }
        try Task.checkCancellation()

        let identity = fileIdentity(for: request, source: audio.source)
        let downloadedLyrics = try await lyrics
        if let existing = MusicDownloadFiles.existingDownload(
            in: request.destination,
            stem: identity.stem,
            audioExtension: identity.audioExtension,
            matchingAudio: audio.temporaryURL
        ) {
            if !audio.isCached { try? FileManager.default.removeItem(at: audio.temporaryURL) }
            var lyricURL = existing.lyricURL
            if lyricURL == nil, let downloadedLyrics {
                let destination = request.destination
                    .appending(path: identity.stem)
                    .appendingPathExtension("lrc")
                if (try? Data(downloadedLyrics.utf8).write(to: destination, options: .atomic)) != nil {
                    lyricURL = destination
                }
            }
            update(.progress(1))
            return MusicDownloadResult(audioURL: existing.audioURL, lyricURL: lyricURL)
        }
        let targets = await targetAllocator.reserve(
            in: request.destination,
            stem: identity.stem,
            audioExtension: identity.audioExtension
        )
        var committed: [URL] = []
        var succeeded = false
        defer {
            if !succeeded {
                let temporaryAudio = audio.isCached ? [] : [audio.temporaryURL]
                for url in temporaryAudio + [targets.audioPart, targets.lyricPart] + committed {
                    try? FileManager.default.removeItem(at: url)
                }
            }
        }

        do {
            if audio.isCached {
                try MusicDownloadFiles.stageCachedFile(audio.temporaryURL, at: targets.audioPart)
            } else {
                try MusicDownloadFiles.stageDownloadedFile(audio.temporaryURL, at: targets.audioPart)
            }
            update(.progress(audioProgressWeight))

            var hasLyrics = false
            if let lyrics = downloadedLyrics {
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
        initialSource: ResolvedSource,
        transport: EAPITransport,
        session: URLSession,
        initialResumeData: Data?,
        retryPolicy: MusicDownloadRetryPolicy,
        audioProgressWeight: Double,
        update: @escaping @Sendable (MusicDownloadUpdate) -> Void
    ) async throws -> DownloadedAudio {
        var source = initialSource
        var resumeData = initialResumeData
        var needsFreshSource = false
        var didRefreshSource = false
        var lastError: Error = MusicDownloadError.invalidResponse
        let reporter = MusicDownloadProgressReporter(weight: audioProgressWeight, update: update)
        let transfer = MusicDownloadTransfer(
            session: session,
            progress: { written, expected, responseExpected in
                reporter.update(
                    totalBytesWritten: written,
                    totalBytesExpectedToWrite: expected,
                    responseExpectedContentLength: responseExpected
                )
            },
            allowsRequest: { redirectedRequest in
                redirectedRequest.url.map(CloudMusicDecoder.isAllowedDownloadURL) == true
            }
        )
        defer { transfer.invalidate() }

        for attempt in 1...retryPolicy.maximumAttempts {
            do {
                try Task.checkCancellation()
                if needsFreshSource {
                    source = try await resolvedSourceWithRetry(
                        for: request,
                        transport: transport,
                        retryPolicy: retryPolicy,
                        update: update
                    )
                    needsFreshSource = false
                }
                try ensureAvailableCapacity(for: source.expectedBytes, at: request.destination)
                reporter.setExpectedBytes(source.expectedBytes)

                var urlRequest = URLRequest(url: source.url, timeoutInterval: 60)
                urlRequest.setValue("TinyCloudMusic/1.0 macOS", forHTTPHeaderField: "User-Agent")
                let result = try await transfer.download(request: urlRequest, resumeData: resumeData)
                do {
                    guard let response = result.response as? HTTPURLResponse else {
                        throw MusicDownloadError.invalidResponse
                    }
                    guard (200..<300).contains(response.statusCode) else {
                        throw MusicDownloadHTTPError(
                            statusCode: response.statusCode,
                            retryAfter: retryPolicy.retryAfter(from: response)
                        )
                    }
                    try validateDownloadedAudio(
                        at: result.temporaryURL,
                        response: response,
                        expectedBytes: source.expectedBytes
                    )
                } catch {
                    try? FileManager.default.removeItem(at: result.temporaryURL)
                    throw error
                }
                return DownloadedAudio(temporaryURL: result.temporaryURL, source: source, isCached: false)
            } catch {
                if let failure = error as? MusicDownloadFailure { throw failure }
                let recoveredResumeData = (error as? MusicDownloadTransferPaused)?.resumeData
                    ?? retryPolicy.resumeData(from: error)
                    ?? resumeData
                if Task.isCancelled || isCancellation(error) {
                    throw MusicDownloadFailure(
                        underlying: error,
                        resumeData: recoveredResumeData,
                        attempts: attempt
                    )
                }
                lastError = error
                let invalidPayload = (error as? MusicDownloadError) == .invalidResponse
                let sourceNeedsRefresh = retryPolicy.shouldRefreshSource(after: error) || invalidPayload
                let refreshesSource = sourceNeedsRefresh && !didRefreshSource
                let retryable = retryPolicy.shouldRetry(error) && !sourceNeedsRefresh
                let discardsResumeData = refreshesSource || (!retryable && resumeData != nil)
                if discardsResumeData {
                    resumeData = nil
                    needsFreshSource = true
                    didRefreshSource = didRefreshSource || refreshesSource
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
                let delay = retryDelay(after: error, retry: retry, policy: retryPolicy)
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

    private nonisolated static func resolvedSourceWithRetry(
        for request: MusicDownloadRequest,
        transport: EAPITransport,
        retryPolicy: MusicDownloadRetryPolicy,
        update: @escaping @Sendable (MusicDownloadUpdate) -> Void
    ) async throws -> ResolvedSource {
        var lastError: Error = MusicDownloadError.invalidResponse
        for attempt in 1...retryPolicy.maximumAttempts {
            do {
                try Task.checkCancellation()
                let source = try await resolvedSource(for: request, transport: transport)
                update(.metadata(level: source.level, expectedBytes: source.expectedBytes))
                return source
            } catch {
                if Task.isCancelled || isCancellation(error) { throw CancellationError() }
                lastError = error
                guard attempt < retryPolicy.maximumAttempts, retryPolicy.shouldRetry(error) else {
                    throw MusicDownloadFailure(underlying: error, resumeData: nil, attempts: attempt)
                }
                update(.retrying(
                    attempt: attempt,
                    total: retryPolicy.maximumRetryCount,
                    progress: nil,
                    resumeData: nil,
                    discardsResumeData: false
                ))
                let delay = retryDelay(after: error, retry: attempt, policy: retryPolicy)
                if delay > 0 { try await Task.sleep(for: .seconds(delay)) }
            }
        }
        throw MusicDownloadFailure(
            underlying: lastError,
            resumeData: nil,
            attempts: retryPolicy.maximumAttempts
        )
    }

    private nonisolated static func resolvedSource(
        for request: MusicDownloadRequest,
        transport: EAPITransport
    ) async throws -> ResolvedSource {
        if case .cloud = request.source {
            let source = try await LiveMusicLibrary(transport: transport).cloudDownloadSource(songID: request.songID)
            return ResolvedSource(
                url: source.url,
                type: source.type,
                level: nil,
                expectedBytes: request.expectedBytes
            )
        }

        let selection = try await downloadSelection(for: request, transport: transport)
        var lastError: Error = MusicDownloadError.unavailable
        for level in selection.levels {
            do {
                let source = try await audioSource(
                    songID: request.songID,
                    level: level,
                    requiresExactLevel: true,
                    transport: transport
                )
                return ResolvedSource(
                    url: source.url,
                    type: source.type,
                    level: source.level,
                    expectedBytes: source.expectedBytes ?? selection.sizes[source.level]
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                guard request.quality == .best, shouldFallbackQuality(after: error) else { throw error }
                lastError = error
            }
        }
        throw lastError
    }

    nonisolated static func downloadLevel(
        for request: MusicDownloadRequest,
        transport: EAPITransport
    ) async throws -> String {
        guard let level = try await downloadSelection(for: request, transport: transport).levels.first else {
            throw EAPIError.missingData("highestAvailableQuality")
        }
        return level
    }

    private nonisolated static func downloadSelection(
        for request: MusicDownloadRequest,
        transport: EAPITransport
    ) async throws -> (levels: [String], sizes: [String: Int64]) {
        switch request.quality {
        case .standard:
            return (["standard"], [:])
        case .lossless:
            return (["lossless"], [:])
        case .best:
            break
        }

        let qualities = try await LiveMusicRepository(transport: transport)
            .songQualityDetails(for: request.songID)
        let available = qualities.filter(\.isAvailable).sorted { $0.rank > $1.rank }
        guard !available.isEmpty else {
            throw EAPIError.missingData("highestAvailableQuality")
        }
        return (
            available.map(\.id),
            Dictionary(uniqueKeysWithValues: available.map { ($0.id, $0.size) })
        )
    }

    nonisolated static func audioSource(
        songID: Int64,
        level: String,
        requiresExactLevel: Bool,
        transport: EAPITransport
    ) async throws -> (url: URL, type: String, level: String, expectedBytes: Int64?) {
        try await transport.withVIPRequesterFallback(
            fallbackOn: { $0 is MusicDownloadError }
        ) { credential in
            try await audioSource(
                songID: songID,
                level: level,
                requiresExactLevel: requiresExactLevel,
                transport: transport,
                credential: credential
            )
        }
    }

    private nonisolated static func audioSource(
        songID: Int64,
        level: String,
        requiresExactLevel: Bool,
        transport: EAPITransport,
        credential: VIPRequesterCredential
    ) async throws -> (url: URL, type: String, level: String, expectedBytes: Int64?) {
        let data = try await apiRequest(
            EAPIEndpoint("/eapi/song/enhance/player/url/v1"),
            payload: audioSourcePayload(songID: songID, level: level),
            transport: transport,
            vipCredential: credential,
            iPhoneClient: true
        )
        let root = try decodedJSONObject(data)
        guard root["code"] != nil else { throw MusicDownloadError.invalidResponse }
        let rootCode = root.int("code")
        guard rootCode == 0 || (200..<300).contains(rootCode) else {
            if rootCode == 404 { throw MusicDownloadError.unavailable }
            throw EAPIError.service(code: rootCode, message: root.string("message"))
        }
        let value = root.array("data").first ?? root.object("data")
        guard !value.isEmpty, value.int64("id") == songID else {
            throw MusicDownloadError.invalidResponse
        }
        guard value["code"] != nil else { throw MusicDownloadError.invalidResponse }
        let itemCode = value.int("code")
        guard itemCode == 0 || (200..<300).contains(itemCode) else {
            if itemCode == 404 { throw MusicDownloadError.unavailable }
            throw EAPIError.service(code: itemCode, message: value.string("message"))
        }
        let actualLevel = value.string("level")
        guard !requiresExactLevel || actualLevel == level else {
            throw MusicDownloadError.qualityMismatch
        }
        let rawURL = value.string("url")
        guard !rawURL.isEmpty, let sourceURL = URL(string: rawURL) else {
            throw MusicDownloadError.unavailable
        }
        guard let url = CloudMusicDecoder.normalizedDownloadURL(sourceURL) else {
            throw MusicDownloadError.invalidResponse
        }
        let size = value.int64("size")
        return (url, value.string("type"), actualLevel.nonEmpty ?? level, size > 0 ? size : nil)
    }

    nonisolated static func audioSourcePayload(songID: Int64, level: String) -> [String: Any] {
        LiveMusicRepository.playbackSourcePayload(songID: songID, level: level)
    }

    nonisolated static func nextLowerLevel(after level: String) -> String? {
        guard let index = SongQualityDetail.orderedLevels.firstIndex(of: level), index > 0 else { return nil }
        return SongQualityDetail.orderedLevels[index - 1]
    }

    private nonisolated static func shouldFallbackQuality(after error: Error) -> Bool {
        guard let error = error as? MusicDownloadError else { return false }
        return error == .unavailable || error == .qualityMismatch
    }

    nonisolated static func retryDelay(
        after error: Error,
        retry: Int,
        policy: MusicDownloadRetryPolicy
    ) -> TimeInterval {
        let retryAfter = (error as? MusicDownloadHTTPError)?.retryAfter
        let base = policy.delay(forRetry: retry, retryAfter: retryAfter)
        guard retryAfter != nil else { return base * Double.random(in: 0.9...1.1) }
        guard base > 0 else { return 0 }
        return base + Double.random(in: 0...min(max(base * 0.1, 0.05), 1))
    }

    private nonisolated static func fileIdentity(
        for request: MusicDownloadRequest,
        source: ResolvedSource
    ) -> (stem: String, audioExtension: String) {
        let prefix = request.artists.isEmpty ? request.songName : "\(request.artists) - \(request.songName)"
        let label = source.level.map { "【\(qualityLabel($0))】" } ?? ""
        let cleaned = MusicDownloadFiles.sanitizedFileName(label + prefix)
        var usedBytes = 0
        let shortened = cleaned.prefix { character in
            let count = String(character).utf8.count
            guard usedBytes + count <= 180 else { return false }
            usedBytes += count
            return true
        }
        let stem = shortened.isEmpty ? "歌曲" : String(shortened)
        let fallbackExtension = if case let .cloud(_, fileName) = request.source {
            URL(fileURLWithPath: fileName).pathExtension
        } else {
            ""
        }
        return (stem, sanitizedExtension(source.type.nonEmpty ?? fallbackExtension))
    }

    private nonisolated static func ensureAvailableCapacity(for expectedBytes: Int64?, at directory: URL) throws {
        guard let expectedBytes, expectedBytes > 0,
              let available = try? directory.resourceValues(
                  forKeys: [.volumeAvailableCapacityForImportantUsageKey]
              ).volumeAvailableCapacityForImportantUsage
        else { return }
        let reserve = min(max(expectedBytes / 20, 1_048_576), 32 * 1_048_576)
        let required = expectedBytes.addingReportingOverflow(reserve)
        guard !required.overflow, available >= required.partialValue else {
            throw MusicDownloadError.insufficientSpace
        }
    }

    private nonisolated static func validateDownloadedAudio(
        at url: URL,
        response: HTTPURLResponse,
        expectedBytes: Int64?
    ) throws {
        let size = try MusicDownloadFiles.validatedAudioFileSize(at: url)

        if let mimeType = response.mimeType?.lowercased(),
           mimeType.hasPrefix("text/")
            || mimeType.hasPrefix("image/")
            || mimeType == "application/json"
            || mimeType.hasSuffix("+json")
            || mimeType == "application/xml"
            || mimeType.hasSuffix("+xml") {
            throw MusicDownloadError.invalidResponse
        }
        if let expectedBytes, expectedBytes > 0 {
            guard size == expectedBytes else { throw MusicDownloadError.invalidResponse }
        }
        if response.expectedContentLength > 0 {
            guard size == response.expectedContentLength else { throw MusicDownloadError.invalidResponse }
        }
    }

    private nonisolated static func downloadableLyrics(
        for request: MusicDownloadRequest,
        transport: EAPITransport,
        cacheRoot: URL?
    ) async throws -> String? {
        guard request.includeLyrics else { return nil }
        if let cacheRoot, let cached = MusicDownloadFiles.cachedLyrics(for: request, cacheRoot: cacheRoot) {
            return cached
        }
        do {
            let lyrics = try await mergedLyrics(for: request, transport: transport).nonEmpty
            if let cacheRoot, let lyrics {
                try? MusicDownloadFiles.cacheLyrics(lyrics, for: request, cacheRoot: cacheRoot)
            }
            return lyrics
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
        vipCredential: VIPRequesterCredential? = nil,
        iPhoneClient: Bool = false,
        cache: EAPIReadCache? = nil
    ) async throws -> Data {
        try await transport.request(
            endpoint,
            json: compactJSON(payload),
            vip: vipCredential != nil,
            useStoredCookieForVIP: vipCredential == .storedCookie,
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
        return result.isEmpty ? "mp3" : String(result.prefix(10))
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

    private nonisolated static func cacheQuality(for request: MusicDownloadRequest, level: String?) -> String {
        switch request.source {
        case .catalog: level ?? "standard"
        case let .cloud(userID, _): "cloud-\(userID)"
        }
    }

    private nonisolated static func makeAudioCache(_ root: URL) -> TrackCache {
        TrackCache(directory: root.appending(path: "StreamCache", directoryHint: .isDirectory))
    }
}

private final class MusicDownloadProgressReporter: @unchecked Sendable {
    private let weight: Double
    private let updateProgress: @Sendable (MusicDownloadUpdate) -> Void
    private let lock = NSLock()
    private var throttle = MusicDownloadProgressThrottle()
    private var expectedBytes: Int64?

    init(
        weight: Double,
        update: @escaping @Sendable (MusicDownloadUpdate) -> Void
    ) {
        self.weight = weight
        updateProgress = update
    }

    func setExpectedBytes(_ value: Int64?) {
        lock.withLock { expectedBytes = value }
    }

    func update(
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64,
        responseExpectedContentLength: Int64
    ) {
        let value = lock.withLock {
            throttle.update(
                totalBytesWritten: totalBytesWritten,
                totalBytesExpectedToWrite: totalBytesExpectedToWrite,
                responseExpectedContentLength: expectedBytes ?? responseExpectedContentLength
            )
        }
        if let value {
            updateProgress(.progress(MusicDownloadManager.overallProgress(audioProgress: value, weight: weight)))
        }
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
