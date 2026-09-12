import Foundation
import Observation

@MainActor
@Observable
final class MusicDownloadManager {
    private struct CloudAccountContext: Equatable {
        let userID: Int64
        let credentialRevision: UInt64
    }

    private enum DownloadKey: Hashable, Sendable {
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

    private struct CompletedFileValidation {
        let id: UUID
        let task: Task<Void, Never>
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

    private struct VideoDownloadFailure: LocalizedError, @unchecked Sendable {
        let underlying: Error
        let resumeData: Data?
        let resolution: Int?
        let sourceURL: URL?
        let sourceExpiresAt: Date?

        var errorDescription: String? { underlying.localizedDescription }
    }

    private(set) var states: [Int64: MusicDownloadState] = [:]
    private(set) var items: [Int64: MusicDownloadItem] = [:]
    private(set) var itemOrder: [Int64] = []
    private(set) var retryAttempts: [Int64: Int] = [:]
    private(set) var videoStates: [String: MusicDownloadState] = [:]
    private(set) var videoItems: [String: VideoDownloadItem] = [:]
    private(set) var videoItemOrder: [String] = []
    private(set) var maximumConcurrentDownloads: Int
    private(set) var persistenceError: String?

    @ObservationIgnored private let transport: EAPITransport
    @ObservationIgnored private let session: URLSession
    @ObservationIgnored private let retryPolicy: MusicDownloadRetryPolicy
    @ObservationIgnored private let resumeStore: MusicDownloadResumeStore
    @ObservationIgnored private let targetAllocator: MusicDownloadTargetAllocator
    @ObservationIgnored private let videoTransfer: VideoFileDownload.Transfer?
    @ObservationIgnored private let audioFileValidator: @Sendable (URL) -> Bool
    @ObservationIgnored private let videoFileValidator: @Sendable (URL) -> Bool
    @ObservationIgnored private let cacheGeneration: MusicDownloadCacheGeneration
    @ObservationIgnored private let cacheActivity = MusicDownloadCacheActivity()
    @ObservationIgnored private var cacheRoot: URL?
    @ObservationIgnored private var audioCache: TrackCache?
    @ObservationIgnored private var pendingRequests: [Int64: MusicDownloadRequest] = [:]
    @ObservationIgnored private var pendingVideoRequests: [String: VideoDownloadRequest] = [:]
    @ObservationIgnored private var pendingOrder: [PendingDownload] = []
    @ObservationIgnored private var pendingHead = 0
    @ObservationIgnored private var activeTasks: [UUID: ActiveDownloadTask] = [:]
    @ObservationIgnored private var completedFileValidations: [DownloadKey: CompletedFileValidation] = [:]
    @ObservationIgnored private var requestsBySongID: [Int64: MusicDownloadRequest] = [:]
    @ObservationIgnored private var resumeDataBySongID: [Int64: Data] = [:]
    @ObservationIgnored private var jobIDs: [Int64: UUID] = [:]
    @ObservationIgnored private var videoRequests: [String: VideoDownloadRequest] = [:]
    @ObservationIgnored private var videoRecoveryByID: [String: MusicDownloadVideoRecovery] = [:]
    @ObservationIgnored private var videoJobIDs: [String: UUID] = [:]
    @ObservationIgnored private var pausingSongIDs: Set<Int64> = []
    @ObservationIgnored private var resumeAfterPauseSongIDs: Set<Int64> = []
    @ObservationIgnored private var pausingVideoIDs: Set<String> = []
    @ObservationIgnored private var resumeAfterPauseVideoIDs: Set<String> = []
    @ObservationIgnored private var bufferedProgress: [Int64: (jobID: UUID, value: Double)] = [:]
    @ObservationIgnored private var bufferedVideoProgress: [String: (jobID: UUID, value: Double)] = [:]
    @ObservationIgnored private var progressFlushTask: Task<Void, Never>?
    @ObservationIgnored private var recoveryTask: Task<Void, Never>?
    @ObservationIgnored private var cloudAccountContext: CloudAccountContext?
    @ObservationIgnored private var hasEstablishedCloudAccountContext = false
    @ObservationIgnored private var deferredCloudRecoveries: [MusicDownloadRecovery] = []
    @ObservationIgnored private var batchPausingSongIDs: Set<Int64> = []
    @ObservationIgnored private var batchPausingVideoIDs: Set<String> = []
    @ObservationIgnored private var isPausingAll = false

    init(
        transport: EAPITransport = EAPITransport(),
        session: URLSession = MusicDownloadSession.defaultSession(),
        maximumConcurrentDownloads: Int = 3,
        retryPolicy: MusicDownloadRetryPolicy = .standard,
        resumeStore: MusicDownloadResumeStore = .shared,
        targetAllocator: MusicDownloadTargetAllocator = .shared,
        cacheRoot: URL? = nil,
        audioCache: TrackCache? = nil,
        videoTransfer: VideoFileDownload.Transfer? = nil,
        audioFileValidator: @escaping @Sendable (URL) -> Bool = {
            (try? MusicDownloadFiles.validatedAudioFileSize(at: $0)) != nil
        },
        videoFileValidator: @escaping @Sendable (URL) -> Bool = {
            FileManager.default.fileExists(atPath: $0.path)
        }
    ) {
        self.transport = transport
        self.session = session
        self.maximumConcurrentDownloads = Self.clampedConcurrency(maximumConcurrentDownloads)
        self.retryPolicy = retryPolicy
        self.resumeStore = resumeStore
        self.targetAllocator = targetAllocator
        self.videoTransfer = videoTransfer
        self.audioFileValidator = audioFileValidator
        self.videoFileValidator = videoFileValidator
        cacheGeneration = MusicDownloadCacheGeneration(root: cacheRoot)
        self.cacheRoot = cacheRoot
        self.audioCache = audioCache ?? cacheRoot.map(Self.makeAudioCache)
        recoveryTask = Task { @MainActor [weak self, resumeStore] in
            let result = await resumeStore.recoverableDownloadsAsync()
            guard !Task.isCancelled else { return }
            self?.applyRecovery(result)
        }
    }

    isolated deinit {
        activeTasks.values.forEach { $0.task.cancel() }
        completedFileValidations.values.forEach { $0.task.cancel() }
        progressFlushTask?.cancel()
        recoveryTask?.cancel()
    }

    func configure(cacheRoot: URL) {
        guard self.cacheRoot?.standardizedFileURL != cacheRoot.standardizedFileURL else { return }
        self.cacheRoot = cacheRoot
        _ = cacheGeneration.configure(root: cacheRoot)
        audioCache = Self.makeAudioCache(cacheRoot)
    }

    func clearCache() async throws {
        let clearing = cacheGeneration.beginClear()
        defer { cacheGeneration.endClear(clearing) }
        if let root = clearing.root { audioCache = Self.makeAudioCache(root) }
        await cacheActivity.waitUntilIdle()
        guard let root = clearing.root else { return }
        try await Self.clearOwnedDownloadCache(at: root)
    }

    private func applyRecovery(_ result: MusicDownloadRecoveryResult) {
        recoveryTask = nil
        if let failureDescription = result.failureDescription {
            persistenceError = failureDescription
        }
        let downloads = result.downloads.filter {
            requestsBySongID[$0.request.songID] == nil && items[$0.request.songID] == nil
        }
        var ready: [MusicDownloadRecovery] = []
        for recovery in downloads {
            guard case let .cloud(userID, _) = recovery.request.source else {
                ready.append(recovery)
                continue
            }
            guard hasEstablishedCloudAccountContext else {
                deferredCloudRecoveries.append(recovery)
                continue
            }
            guard let context = cloudAccountContext, context.userID == userID else {
                if recovery.restoredState == nil {
                    resumeStore.remove(songID: recovery.request.songID, onFailure: persistenceFailureHandler)
                } else {
                    deferredCloudRecoveries.append(recovery)
                }
                continue
            }
            ready.append(MusicDownloadRecovery(
                request: recovery.request.bindingCloudCredentialRevision(context.credentialRevision),
                resumeData: recovery.resumeData,
                savedAt: recovery.savedAt,
                restoredState: recovery.restoredState
            ))
        }
        restoreAudioDownloads(ready)
        enqueueRecoveredVideos(result.videos)
    }

    private func restoreAudioDownloads(_ recoveries: [MusicDownloadRecovery]) {
        var queued: [MusicDownloadRequest] = []
        for recovery in recoveries {
            let request = recovery.request
            guard requestsBySongID[request.songID] == nil, items[request.songID] == nil else { continue }
            if let resumeData = recovery.resumeData {
                resumeDataBySongID[request.songID] = resumeData
            }
            guard let state = recovery.restoredState else {
                queued.append(request)
                continue
            }
            requestsBySongID[request.songID] = request
            states[request.songID] = state
            items[request.songID] = MusicDownloadItem(
                id: request.songID,
                title: request.songName,
                artist: request.artists,
                quality: request.source == .catalog ? request.quality.rawValue : "原文件",
                expectedBytes: request.expectedBytes
            )
            itemOrder.append(request.songID)
        }
        _ = enqueue(queued, persist: false)
    }

    private func enqueueRecoveredVideos(_ recoveries: [MusicDownloadVideoRecovery]) {
        var nextStates = videoStates
        var nextItems = videoItems
        var nextOrder = videoItemOrder
        var pendings: [PendingDownload] = []
        var processed: Set<String> = []

        for recovery in recoveries {
            let id = recovery.request.resource.identity
            guard processed.insert(id).inserted,
                  videoRequests[id] == nil,
                  videoItems[id] == nil
            else { continue }
            videoRecoveryByID[id] = recovery
            videoRequests[id] = recovery.request
            nextItems[id] = VideoDownloadItem(
                id: id,
                title: recovery.request.title,
                creator: recovery.request.creator,
                quality: recovery.request.quality.rawValue
            )
            nextOrder.append(id)
            if let state = recovery.restoredState {
                nextStates[id] = state
                continue
            }
            let jobID = UUID()
            videoJobIDs[id] = jobID
            nextStates[id] = .queued
            pendingVideoRequests[id] = recovery.request
            pendings.append(.video(id: id, jobID: jobID))
        }
        guard !processed.isEmpty else { return }
        videoItemOrder = nextOrder
        videoStates = nextStates
        videoItems = nextItems
        pendingOrder.append(contentsOf: pendings)
        schedulePendingDownloads()
    }

    @discardableResult
    func enqueue(
        song: Song,
        to destination: URL,
        quality: AudioQuality = .standard,
        includeLyrics: Bool = true
    ) -> Bool {
        enqueue(songs: [song], to: destination, quality: quality, includeLyrics: includeLyrics) == 1
    }

    @discardableResult
    func enqueue(
        songs: [Song],
        to destination: URL,
        quality: AudioQuality,
        includeLyrics: Bool
    ) -> Int {
        enqueue(songs.map {
            MusicDownloadRequest(
                songID: $0.id,
                songName: $0.name,
                artists: $0.artistsDisplay,
                destination: destination,
                quality: quality,
                includeLyrics: includeLyrics,
                source: .catalog,
                expectedBytes: nil
            )
        })
    }

    @discardableResult
    func enqueue(
        cloudSong: CloudSong,
        userID: Int64,
        expectedCredentialRevision: UInt64,
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
            expectedBytes: cloudSong.fileSize > 0 ? cloudSong.fileSize : nil,
            expectedCredentialRevision: expectedCredentialRevision
        ))
    }

    func setCloudDownloadAccount(userID: Int64?, credentialRevision: UInt64?) {
        hasEstablishedCloudAccountContext = true
        cloudAccountContext = if let userID, let credentialRevision {
            CloudAccountContext(userID: userID, credentialRevision: credentialRevision)
        } else {
            nil
        }

        let staleIDs = requestsBySongID.compactMap { songID, request -> Int64? in
            guard case let .cloud(ownerID, _) = request.source else { return nil }
            guard let context = cloudAccountContext,
                  ownerID == context.userID,
                  request.expectedCredentialRevision == context.credentialRevision
            else { return songID }
            return nil
        }
        for songID in staleIDs {
            if case .completed? = states[songID], let request = requestsBySongID[songID] {
                deferredCloudRecoveries.append(MusicDownloadRecovery(
                    request: request, resumeData: nil, savedAt: Date(), restoredState: states[songID]
                ))
                cancelCompletedFileValidation(for: .music(songID))
                requestsBySongID.removeValue(forKey: songID)
                states.removeValue(forKey: songID)
                items.removeValue(forKey: songID)
                itemOrder.removeAll { $0 == songID }
            } else {
                cancel(songID: songID)
            }
        }

        let recoveries = deferredCloudRecoveries
        deferredCloudRecoveries.removeAll()
        guard let context = cloudAccountContext else {
            deferredCloudRecoveries = recoveries.filter { $0.restoredState != nil }
            recoveries.filter { $0.restoredState == nil }.forEach {
                resumeStore.remove(songID: $0.request.songID, onFailure: persistenceFailureHandler)
            }
            return
        }

        let matching = recoveries.compactMap { recovery -> MusicDownloadRecovery? in
            guard case let .cloud(ownerID, _) = recovery.request.source,
                  ownerID == context.userID
            else {
                if recovery.restoredState == nil {
                    resumeStore.remove(songID: recovery.request.songID, onFailure: persistenceFailureHandler)
                } else {
                    deferredCloudRecoveries.append(recovery)
                }
                return nil
            }
            return MusicDownloadRecovery(
                request: recovery.request.bindingCloudCredentialRevision(context.credentialRevision),
                resumeData: recovery.resumeData,
                savedAt: recovery.savedAt,
                restoredState: recovery.restoredState
            )
        }
        restoreAudioDownloads(matching)
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
    private func enqueue(
        _ request: VideoDownloadRequest,
        persist: Bool = true,
        validatesCompletedFile: Bool = true
    ) -> Bool {
        let id = request.resource.identity
        let key = DownloadKey.video(id)
        let wasKnown = videoItems[id] != nil
        if videoRequests[id] == request {
            switch videoStates[id] {
            case .queued, .running:
                return false
            case let .completed(fileURL, _) where validatesCompletedFile:
                validateCompletedVideo(request, fileURL: fileURL)
                return false
            default:
                break
            }
        }
        cancelCompletedFileValidation(for: key)
        if isVideoActive(id: id) {
            pausingVideoIDs.remove(id)
            resumeAfterPauseVideoIDs.remove(id)
            pendingVideoRequests.removeValue(forKey: id)
            activeTasks.values
                .filter { $0.key == .video(id) }
                .forEach { $0.task.cancel() }
            videoJobIDs.removeValue(forKey: id)
        }
        if let previous = videoRequests[id], previous != request {
            videoRecoveryByID.removeValue(forKey: id)
            resumeStore.remove(videoID: id, onFailure: persistenceFailureHandler)
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
        if persist {
            resumeStore.save(
                videoResumeEntry(for: request, id: id),
                onFailure: persistenceFailureHandler
            )
        }
        schedulePendingDownloads()
        return true
    }

    @discardableResult
    private func enqueue(_ request: MusicDownloadRequest, persist: Bool = true) -> Bool {
        enqueue([request], persist: persist) == 1
    }

    @discardableResult
    private func enqueue(
        _ requests: [MusicDownloadRequest],
        persist: Bool = true,
        validatesCompletedFiles: Bool = true
    ) -> Int {
        guard !requests.isEmpty else { return 0 }
        var nextStates = states
        var nextItems = items
        var nextRetryAttempts = retryAttempts
        var accepted: [MusicDownloadResumeEntry] = []
        var pendings: [PendingDownload] = []
        var acceptedIDs: [Int64] = []
        var processed: Set<Int64> = []

        for request in requests where processed.insert(request.songID).inserted {
            let songID = request.songID
            let key = DownloadKey.music(songID)
            if requestsBySongID[songID] == request {
                switch nextStates[songID] {
                case .queued, .running:
                    continue
                case let .completed(audioURL, lyricURL) where validatesCompletedFiles:
                    validateCompletedAudio(request, audioURL: audioURL, lyricURL: lyricURL)
                    continue
                default:
                    break
                }
            }
            cancelCompletedFileValidation(for: key)
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
            nextItems[songID] = MusicDownloadItem(
                id: songID,
                title: request.songName,
                artist: request.artists,
                quality: quality,
                expectedBytes: request.expectedBytes
            )
            let jobID = UUID()
            jobIDs[songID] = jobID
            nextRetryAttempts[songID] = 0
            nextStates[songID] = .queued
            pendingRequests[songID] = request
            pendings.append(.music(songID: songID, jobID: jobID))
            acceptedIDs.append(songID)
            accepted.append(MusicDownloadResumeEntry(
                request: request,
                resumeData: resumeDataBySongID[songID]
            ))
        }
        guard !accepted.isEmpty else { return 0 }

        let acceptedSet = Set(acceptedIDs)
        var nextItemOrder = itemOrder
        nextItemOrder.removeAll { acceptedSet.contains($0) }
        nextItemOrder.append(contentsOf: acceptedIDs)
        itemOrder = nextItemOrder
        states = nextStates
        items = nextItems
        retryAttempts = nextRetryAttempts
        pendingOrder.append(contentsOf: pendings)
        if persist { resumeStore.save(accepted, onFailure: persistenceFailureHandler) }
        schedulePendingDownloads()
        return accepted.count
    }

    private func validateCompletedAudio(
        _ request: MusicDownloadRequest,
        audioURL: URL,
        lyricURL: URL?
    ) {
        let key = DownloadKey.music(request.songID)
        guard completedFileValidations[key] == nil else { return }
        let id = UUID()
        let validator = audioFileValidator
        let task = Task.detached(priority: .utility) { [weak self] in
            let isValid = validator(audioURL)
            guard !Task.isCancelled else { return }
            await self?.finishCompletedAudioValidation(
                isValid: isValid,
                id: id,
                request: request,
                audioURL: audioURL,
                lyricURL: lyricURL
            )
        }
        completedFileValidations[key] = CompletedFileValidation(id: id, task: task)
    }

    private func validateCompletedVideo(_ request: VideoDownloadRequest, fileURL: URL) {
        let key = DownloadKey.video(request.resource.identity)
        guard completedFileValidations[key] == nil else { return }
        let id = UUID()
        let validator = videoFileValidator
        let task = Task.detached(priority: .utility) { [weak self] in
            let isValid = validator(fileURL)
            guard !Task.isCancelled else { return }
            await self?.finishCompletedVideoValidation(
                isValid: isValid,
                id: id,
                request: request,
                fileURL: fileURL
            )
        }
        completedFileValidations[key] = CompletedFileValidation(id: id, task: task)
    }

    private func finishCompletedAudioValidation(
        isValid: Bool,
        id: UUID,
        request: MusicDownloadRequest,
        audioURL: URL,
        lyricURL: URL?
    ) {
        let key = DownloadKey.music(request.songID)
        guard completedFileValidations[key]?.id == id else { return }
        completedFileValidations.removeValue(forKey: key)
        guard !isValid,
              requestsBySongID[request.songID] == request,
              states[request.songID] == .completed(audioURL: audioURL, lyricURL: lyricURL)
        else { return }
        _ = enqueue([request], validatesCompletedFiles: false)
    }

    private func finishCompletedVideoValidation(
        isValid: Bool,
        id: UUID,
        request: VideoDownloadRequest,
        fileURL: URL
    ) {
        let key = DownloadKey.video(request.resource.identity)
        guard completedFileValidations[key]?.id == id else { return }
        completedFileValidations.removeValue(forKey: key)
        guard !isValid,
              videoRequests[request.resource.identity] == request,
              videoStates[request.resource.identity] == .completed(audioURL: fileURL, lyricURL: nil)
        else { return }
        _ = enqueue(request, validatesCompletedFile: false)
    }

    private func cancelCompletedFileValidation(for key: DownloadKey) {
        completedFileValidations.removeValue(forKey: key)?.task.cancel()
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
            discardResumeData(songID: songID, persist: false)
            states[songID] = .cancelled
        }
        for id in affectedVideoIDs {
            videoRecoveryByID.removeValue(forKey: id)
            videoStates[id] = .cancelled
        }
        resumeStore.remove(
            songIDs: affectedIDs,
            videoIDs: affectedVideoIDs,
            onFailure: persistenceFailureHandler
        )
        activeTasks.values.forEach { $0.task.cancel() }
        trimHistory()
        trimVideoHistory()
    }

    func pause(songID: Int64) {
        pause(songID: songID, persist: true)
    }

    private func pause(songID: Int64, persist: Bool) {
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
        if persist {
            resumeStore.save(
                request,
                resumeData: resumeDataBySongID[songID],
                isPaused: true,
                onFailure: persistenceFailureHandler
            )
        } else {
            batchPausingSongIDs.insert(songID)
        }
        if runningTasks.isEmpty {
            jobIDs.removeValue(forKey: songID)
        } else {
            pausingSongIDs.insert(songID)
            runningTasks.forEach { $0.task.cancel() }
        }
        schedulePendingDownloads()
    }

    func pauseAll(resumesOnLaunch: Bool = false) async {
        if let recoveryTask { await recoveryTask.value }
        isPausingAll = true
        let affected = Set(pendingRequests.keys).union(activeTasks.values.compactMap(\.songID))
        let tasks = activeTasks.values.map(\.task)
        let ordered = itemOrder.filter(affected.contains)
            + affected.subtracting(itemOrder).sorted()
        for songID in ordered {
            pause(songID: songID, persist: false)
        }
        let affectedVideos = Set(pendingVideoRequests.keys).union(activeTasks.values.compactMap { active in
            if case let .video(id) = active.key { id } else { nil }
        })
        let orderedVideos = videoItemOrder.filter(affectedVideos.contains)
            + affectedVideos.subtracting(videoItemOrder).sorted()
        for id in orderedVideos { pauseVideo(id: id, persist: false) }
        for task in tasks { await task.value }

        let audio = ordered.compactMap { songID -> MusicDownloadResumeEntry? in
            guard let request = requestsBySongID[songID] else { return nil }
            return MusicDownloadResumeEntry(
                request: request, resumeData: resumeDataBySongID[songID], isPaused: !resumesOnLaunch
            )
        }
        let videos = orderedVideos.compactMap { id -> MusicDownloadVideoResumeEntry? in
            guard let request = videoRequests[id] else { return nil }
            var entry = videoResumeEntry(for: request, id: id)
            entry.isPaused = !resumesOnLaunch
            return entry
        }
        resumeStore.save(
            audio: audio,
            videos: videos,
            onFailure: persistenceFailureHandler
        )
        batchPausingSongIDs.subtract(affected)
        batchPausingVideoIDs.subtract(affectedVideos)
        isPausingAll = false
        schedulePendingDownloads()
        do {
            try await flushPersistence()
        } catch {
            // `persistenceError` is observable; the compatibility shutdown caller remains non-throwing.
        }
    }

    func flushPersistence(timeout: Duration = .seconds(10)) async throws {
        do {
            try await resumeStore.flush(timeout: timeout)
            persistenceError = nil
        } catch {
            persistenceError = error.localizedDescription
            throw error
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
        videoRecoveryByID.removeValue(forKey: id)
        resumeStore.remove(videoID: id, onFailure: persistenceFailureHandler)
        videoStates[id] = .cancelled
        runningTasks.forEach { $0.task.cancel() }
        schedulePendingDownloads()
        trimVideoHistory()
    }

    func pauseVideo(id: String) {
        pauseVideo(id: id, persist: true)
    }

    private func pauseVideo(id: String, persist: Bool) {
        guard let request = videoRequests[id] else { return }
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
        if persist {
            resumeStore.save(
                videoResumeEntry(for: request, id: id),
                onFailure: persistenceFailureHandler
            )
        } else {
            batchPausingVideoIDs.insert(id)
        }
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
        guard !isPausingAll else { return }
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
        let initialResumeData = resumeDataBySongID[songID]
        if let initialResumeData { resumeDataBySongID[songID] = initialResumeData }
        let transport = transport
        let session = session
        let retryPolicy = retryPolicy
        let targetAllocator = targetAllocator
        let cacheRoot = cacheRoot
        let audioCache = audioCache
        let cacheContext = cacheGeneration.context()
        let cacheGeneration = cacheGeneration
        let cacheActivity = cacheActivity
        let expectedCredentialRevision = request.expectedCredentialRevision
            ?? transport.credentialSnapshotValue().revision
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
                    cacheContext: cacheContext,
                    cacheGeneration: cacheGeneration,
                    cacheActivity: cacheActivity,
                    expectedCredentialRevision: expectedCredentialRevision,
                    isCurrent: { [weak self] in
                        self?.jobIDs[songID] == jobID
                            && self?.requestsBySongID[songID] == request
                            && Self.credentialContextIsCurrent(request, transport: transport)
                    },
                    update: { [weak self] update in
                        Task { @MainActor [weak self] in
                            self?.apply(update, songID: songID, jobID: jobID, request: request)
                        }
                    }
                )
                if Self.credentialContextIsCurrent(request, transport: transport) {
                    self?.complete(result, songID: songID, jobID: jobID)
                } else {
                    self?.fail(CancellationError(), request: request, songID: songID, jobID: jobID)
                }
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
        let retryPolicy = retryPolicy
        let targetAllocator = targetAllocator
        let recovery = videoRecoveryByID[id]
        let videoTransfer = videoTransfer
        let cacheContext = cacheGeneration.context()
        let cacheGeneration = cacheGeneration
        let cacheActivity = cacheActivity
        let task = Task { @MainActor [weak self] in
            do {
                let result = try await Self.performVideo(
                    request,
                    transport: transport,
                    configuration: configuration,
                    cacheRoot: cacheRoot,
                    recovery: recovery,
                    retryPolicy: retryPolicy,
                    targetAllocator: targetAllocator,
                    transferDownload: videoTransfer,
                    cacheContext: cacheContext,
                    cacheGeneration: cacheGeneration,
                    cacheActivity: cacheActivity,
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
        discardResumeData(songID: songID, persist: false)
        if let request = requestsBySongID[songID] {
            resumeStore.save(request, completion: result, onFailure: persistenceFailureHandler)
        }
        retryAttempts[songID] = 0
        states[songID] = .completed(audioURL: result.audioURL, lyricURL: result.lyricURL)
        trimHistory()
    }

    private func completeVideo(_ url: URL, id: String, jobID: UUID) {
        guard videoJobIDs[id] == jobID else { return }
        pausingVideoIDs.remove(id)
        resumeAfterPauseVideoIDs.remove(id)
        videoRecoveryByID.removeValue(forKey: id)
        if let request = videoRequests[id] {
            resumeStore.save(
                MusicDownloadVideoResumeEntry(
                    request: request, resumeData: nil, resolution: nil, sourceURL: nil, sourceExpiresAt: nil,
                    completion: MusicDownloadResult(audioURL: url, lyricURL: nil)
                ),
                onFailure: persistenceFailureHandler
            )
        }
        videoStates[id] = .completed(audioURL: url, lyricURL: nil)
        trimVideoHistory()
    }

    private func fail(_ error: Error, request: MusicDownloadRequest, songID: Int64, jobID: UUID) {
        guard jobIDs[songID] == jobID else { return }
        let failure = error as? MusicDownloadFailure
        if pausingSongIDs.remove(songID) != nil {
            let resumeData = failure?.resumeData ?? resumeDataBySongID[songID]
            if let resumeData { resumeDataBySongID[songID] = resumeData }
            if !batchPausingSongIDs.contains(songID) {
                resumeStore.save(
                    request,
                    resumeData: resumeData,
                    isPaused: true,
                    onFailure: persistenceFailureHandler
                )
            }
            retryAttempts[songID] = 0
            return
        }
        if !Self.credentialContextIsCurrent(request, transport: transport)
            || Task.isCancelled || Self.isCancellation(error) {
            discardResumeData(songID: songID)
            retryAttempts[songID] = 0
            states[songID] = .cancelled
            trimHistory()
            return
        }

        if let resumeData = failure?.resumeData {
            resumeDataBySongID[songID] = resumeData
            resumeStore.save(
                request,
                resumeData: resumeData,
                onFailure: persistenceFailureHandler
            )
        } else {
            discardResumeData(songID: songID)
        }
        states[songID] = .failed(failure?.localizedDescription ?? error.localizedDescription)
        trimHistory()
    }

    private func failVideo(_ error: Error, id: String, jobID: UUID) {
        guard videoJobIDs[id] == jobID else { return }
        let failure = error as? VideoDownloadFailure
        if let request = videoRequests[id] {
            let previous = videoRecoveryByID[id]
            let recovery = MusicDownloadVideoRecovery(
                request: request,
                resumeData: failure == nil ? previous?.resumeData : failure?.resumeData,
                resolution: failure == nil ? previous?.resolution : failure?.resolution,
                sourceURL: failure == nil ? previous?.sourceURL : failure?.sourceURL,
                sourceExpiresAt: failure == nil ? previous?.sourceExpiresAt : failure?.sourceExpiresAt,
                savedAt: Date()
            )
            videoRecoveryByID[id] = recovery
        }
        if pausingVideoIDs.remove(id) != nil {
            if !batchPausingVideoIDs.contains(id), let request = videoRequests[id] {
                resumeStore.save(
                    videoResumeEntry(for: request, id: id),
                    onFailure: persistenceFailureHandler
                )
            }
            return
        }
        if Task.isCancelled || Self.isCancellation(error) {
            videoRecoveryByID.removeValue(forKey: id)
            resumeStore.remove(videoID: id, onFailure: persistenceFailureHandler)
            videoStates[id] = .cancelled
        } else {
            if let request = videoRequests[id] {
                resumeStore.save(
                    videoResumeEntry(for: request, id: id),
                    onFailure: persistenceFailureHandler
                )
            }
            videoStates[id] = .failed(failure?.localizedDescription ?? error.localizedDescription)
        }
        trimVideoHistory()
    }

    private func apply(
        _ update: MusicDownloadUpdate,
        songID: Int64,
        jobID: UUID,
        request: MusicDownloadRequest
    ) {
        guard jobIDs[songID] == jobID,
              activeTasks[jobID] != nil,
              Self.credentialContextIsCurrent(request, transport: transport)
        else { return }
        guard case .running? = states[songID] else { return }
        switch update {
        case let .metadata(level, expectedBytes):
            guard let item = items[songID] else { return }
            let updated = MusicDownloadItem(
                id: item.id,
                title: item.title,
                artist: item.artist,
                quality: level.map(MusicDownloadFiles.qualityLabel) ?? item.quality,
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
                resumeStore.save(request, onFailure: persistenceFailureHandler)
            } else if let resumeData {
                resumeDataBySongID[songID] = resumeData
                resumeStore.save(
                    request,
                    resumeData: resumeData,
                    onFailure: persistenceFailureHandler
                )
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

    private func discardResumeData(songID: Int64, persist: Bool = true) {
        resumeDataBySongID.removeValue(forKey: songID)
        if persist {
            resumeStore.remove(songID: songID, onFailure: persistenceFailureHandler)
        }
    }

    private var persistenceFailureHandler: MusicDownloadResumeStore.FailureHandler {
        { [weak self] message in
            Task { @MainActor [weak self] in self?.persistenceError = message }
        }
    }

    private func videoResumeEntry(for request: VideoDownloadRequest, id: String) -> MusicDownloadVideoResumeEntry {
        let recovery = videoRecoveryByID[id]
        let isPaused: Bool = if case .paused? = videoStates[id] { true } else { false }
        return MusicDownloadVideoResumeEntry(
            request: request,
            resumeData: recovery?.resumeData,
            resolution: recovery?.resolution,
            sourceURL: recovery?.sourceURL,
            sourceExpiresAt: recovery?.sourceExpiresAt,
            isPaused: isPaused
        )
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
        // ponytail: completed entries retain export URLs in memory; paginate if large libraries need it.
        let excess = itemOrder.count - limit
        guard excess > 0 else { return }
        let victims = itemOrder.lazy.filter { songID in
            guard !self.isActive(songID: songID), let state = self.states[songID] else { return false }
            switch state {
            case .failed, .cancelled: return true
            case .completed, .queued, .running, .paused: return false
            }
        }.prefix(excess)
        let victimIDs = Set(victims)
        guard !victimIDs.isEmpty else { return }
        itemOrder.removeAll { victimIDs.contains($0) }
        for songID in victimIDs {
            cancelCompletedFileValidation(for: .music(songID))
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
            case .failed, .cancelled: return true
            case .completed, .queued, .running, .paused: return false
            }
        }.prefix(excess)
        let victimIDs = Set(victims)
        videoItemOrder.removeAll { victimIDs.contains($0) }
        for id in victimIDs {
            cancelCompletedFileValidation(for: .video(id))
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
        recovery: MusicDownloadVideoRecovery?,
        retryPolicy: MusicDownloadRetryPolicy,
        targetAllocator: MusicDownloadTargetAllocator,
        transferDownload: VideoFileDownload.Transfer?,
        cacheContext: MusicDownloadCacheContext,
        cacheGeneration: MusicDownloadCacheGeneration,
        cacheActivity: MusicDownloadCacheActivity,
        update: @escaping @Sendable (_ resolution: Int?, _ progress: Double?) -> Void
    ) async throws -> URL {
        var lastError: Error = VideoLibraryError.unavailable("全部清晰度均不可用")
        let library = LiveVideoLibrary(transport: transport)
        let fileTitle = switch request.resource {
        case .mv: request.creator.isEmpty ? request.title : "\(request.creator) - \(request.title)"
        case .video: request.title
        }
        var candidates = VideoResolutionPolicy.downloadCandidates(
            for: request.quality,
            available: request.availableResolutions
        )
        if let resolution = recovery?.resolution,
           candidates.contains(resolution),
           recovery?.sourceExpiresAt.map({ $0 > Date() }) ?? true {
            candidates.removeAll { $0 == resolution }
            candidates.insert(resolution, at: 0)
        }
        for resolution in candidates {
            do {
                try Task.checkCancellation()
                update(resolution, nil)
                if let cacheRoot,
                   let cached = try await VideoFileDownload.copyCachedFile(
                       identity: request.resource.identity,
                       title: fileTitle,
                       resolution: resolution,
                       cacheRoot: cacheRoot,
                       to: request.destination,
                       targetAllocator: targetAllocator,
                       cacheContext: cacheContext,
                       cacheGeneration: cacheGeneration,
                       cacheActivity: cacheActivity
                   ) {
                    update(nil, 1)
                    return cached
                }

                var source: VideoPlaybackSource
                var resumeData: Data?
                if recovery?.resolution == resolution,
                   let sourceURL = recovery?.sourceURL,
                   VideoPlaybackURLPolicy.isAllowed(sourceURL),
                   recovery?.sourceExpiresAt.map({ $0 > Date() }) ?? true {
                    source = VideoPlaybackSource(
                        url: sourceURL,
                        resolution: resolution,
                        expiresAt: recovery?.sourceExpiresAt
                    )
                    resumeData = recovery?.resumeData
                } else {
                    source = try await resolvedVideoSource(
                        request,
                        resolution: resolution,
                        library: library
                    )
                }
                update(source.resolution, nil)
                if let cacheRoot,
                   let cached = try await VideoFileDownload.copyCachedFile(
                       identity: request.resource.identity,
                       title: fileTitle,
                       resolution: source.resolution,
                       cacheRoot: cacheRoot,
                       to: request.destination,
                       targetAllocator: targetAllocator,
                       cacheContext: cacheContext,
                       cacheGeneration: cacheGeneration,
                       cacheActivity: cacheActivity
                   ) {
                    update(nil, 1)
                    return cached
                }

                var didRefreshSource = false
                for attempt in 1...retryPolicy.maximumAttempts {
                    do {
                        return try await VideoFileDownload.download(
                            source.url,
                            title: fileTitle,
                            resolution: source.resolution,
                            to: request.destination,
                            cacheIdentity: request.resource.identity,
                            cacheRoot: cacheRoot,
                            resumeData: resumeData,
                            targetAllocator: targetAllocator,
                            cacheContext: cacheContext,
                            cacheGeneration: cacheGeneration,
                            cacheActivity: cacheActivity,
                            transferDownload: transferDownload,
                            configuration: configuration,
                            backgroundIdentifier: configuration.identifier.map {
                                _ in MusicDownloadSession.identifier(forVideo: request.resource.identity)
                            }
                        ) { update(nil, $0) }
                    } catch {
                        let recoveredResumeData = retryPolicy.resumeData(from: error) ?? resumeData
                        if Task.isCancelled || isCancellation(error) {
                            throw VideoDownloadFailure(
                                underlying: error,
                                resumeData: recoveredResumeData,
                                resolution: source.resolution,
                                sourceURL: source.url,
                                sourceExpiresAt: source.expiresAt
                            )
                        }
                        let needsSourceRefresh = retryPolicy.shouldRefreshSource(after: error)
                        if needsSourceRefresh, !didRefreshSource,
                           attempt < retryPolicy.maximumAttempts {
                            source = try await resolvedVideoSource(
                                request,
                                resolution: resolution,
                                library: library
                            )
                            didRefreshSource = true
                            resumeData = nil
                            continue
                        }
                        if !needsSourceRefresh, retryPolicy.shouldRetry(error),
                           attempt < retryPolicy.maximumAttempts {
                            resumeData = recoveredResumeData
                            let delay = retryDelay(after: error, retry: attempt, policy: retryPolicy)
                            if delay > 0 {
                                do {
                                    try await Task.sleep(for: .seconds(delay))
                                } catch {
                                    throw VideoDownloadFailure(
                                        underlying: error,
                                        resumeData: resumeData,
                                        resolution: source.resolution,
                                        sourceURL: source.url,
                                        sourceExpiresAt: source.expiresAt
                                    )
                                }
                            }
                            continue
                        }
                        throw VideoDownloadFailure(
                            underlying: error,
                            resumeData: recoveredResumeData,
                            resolution: source.resolution,
                            sourceURL: source.url,
                            sourceExpiresAt: source.expiresAt
                        )
                    }
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as URLError where error.code == .cancelled && Task.isCancelled {
                throw CancellationError()
            } catch let failure as VideoDownloadFailure {
                guard shouldFallbackVideo(after: failure.underlying) else { throw failure }
                lastError = failure
            } catch {
                guard shouldFallbackVideo(after: error) else { throw error }
                lastError = error
            }
        }
        throw lastError
    }

    private nonisolated static func resolvedVideoSource(
        _ request: VideoDownloadRequest,
        resolution: Int,
        library: LiveVideoLibrary
    ) async throws -> VideoPlaybackSource {
        switch request.resource {
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
    }

    nonisolated static func shouldFallbackVideo(after error: Error) -> Bool {
        if case let VideoLibraryError.unavailable(message) = error {
            return message.contains("暂无可用播放地址")
                || [
                    "该视频需要登录或开通权益后播放",
                    "服务未返回可用播放地址",
                    "全部清晰度均不可用"
                ].contains(message)
        }
        if let error = error as? MusicDownloadError { return error == .unavailable }
        if let error = error as? MusicDownloadHTTPError { return [404, 410].contains(error.statusCode) }
        if let error = error as? EAPIError {
            switch error {
            case let .http(status): return [404, 410].contains(status)
            case let .service(code, _): return [404, 410].contains(code)
            default: return false
            }
        }
        return false
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
        cacheContext: MusicDownloadCacheContext,
        cacheGeneration: MusicDownloadCacheGeneration,
        cacheActivity: MusicDownloadCacheActivity,
        expectedCredentialRevision: UInt64,
        isCurrent: @escaping @MainActor @Sendable () -> Bool,
        update: @escaping @Sendable (MusicDownloadUpdate) -> Void
    ) async throws -> MusicDownloadResult {
        try Task.checkCancellation()
        guard await isCurrent() else { throw CancellationError() }
        let hasCacheSecurityScope = cacheRoot?.startAccessingSecurityScopedResource() == true
        defer { if hasCacheSecurityScope { cacheRoot?.stopAccessingSecurityScopedResource() } }
        let hasSecurityScope = request.destination.startAccessingSecurityScopedResource()
        defer { if hasSecurityScope { request.destination.stopAccessingSecurityScopedResource() } }
        try FileManager.default.createDirectory(at: request.destination, withIntermediateDirectories: true)

        if let existing = MusicDownloadFiles.managedDownload(for: request) {
            var lyricURL = existing.lyricURL
            if request.includeLyrics, lyricURL == nil,
               let lyrics = try await downloadableLyrics(
                   for: request,
                   transport: transport,
                   cacheRoot: cacheRoot,
                   cacheContext: cacheContext,
                   cacheGeneration: cacheGeneration,
                   cacheActivity: cacheActivity,
                   expectedCredentialRevision: expectedCredentialRevision
               ) {
                try Task.checkCancellation()
                guard await isCurrent() else { throw CancellationError() }
                let destination = existing.audioURL.deletingPathExtension().appendingPathExtension("lrc")
                try Data(lyrics.utf8).write(to: destination, options: .atomic)
                lyricURL = destination
            }
            try Task.checkCancellation()
            guard await isCurrent() else { throw CancellationError() }
            update(.progress(1))
            return MusicDownloadResult(audioURL: existing.audioURL, lyricURL: lyricURL)
        }

        let concreteLevel: String? = switch request.source {
        case .catalog: try await downloadLevel(for: request, transport: transport)
        case .cloud: nil
        }
        update(.metadata(level: concreteLevel, expectedBytes: nil))

        let audioProgressWeight = request.includeLyrics ? 0.99 : 1
        async let lyrics = downloadableLyrics(
            for: request,
            transport: transport,
            cacheRoot: cacheRoot,
            cacheContext: cacheContext,
            cacheGeneration: cacheGeneration,
            cacheActivity: cacheActivity,
            expectedCredentialRevision: expectedCredentialRevision
        )
        let desiredCacheQuality = cacheQuality(for: request, level: concreteLevel)
        var holdsCacheRead = false
        defer { if holdsCacheRead { cacheActivity.end() } }
        func cachedAudio(quality: String, level: String?) async throws -> DownloadedAudio? {
            guard await isCurrent() else { throw CancellationError() }
            guard let audioCache, cacheGeneration.isCurrent(cacheContext) else { return nil }
            cacheActivity.begin()
            var keepActivity = false
            defer { if !keepActivity { cacheActivity.end() } }
            try Task.checkCancellation()
            guard cacheGeneration.isCurrent(cacheContext) else { return nil }
            let cached = await audioCache.readyCachedFile(for: request.songID, quality: quality)
            try Task.checkCancellation()
            guard await isCurrent() else { throw CancellationError() }
            guard cacheGeneration.isCurrent(cacheContext), let cached else { return nil }
            keepActivity = true
            holdsCacheRead = true
            return DownloadedAudio(
                temporaryURL: cached.url,
                source: ResolvedSource(
                    url: cached.url,
                    type: cached.fileExtension,
                    level: level,
                    expectedBytes: cached.size
                ),
                isCached: true
            )
        }
        let audio: DownloadedAudio
        if let cached = try await cachedAudio(quality: desiredCacheQuality, level: concreteLevel) {
            audio = cached
        } else {
            let initialSource = try await resolvedSourceOnce(
                for: request,
                transport: transport,
                expectedCredentialRevision: expectedCredentialRevision,
                update: update
            )
            let actualQuality = cacheQuality(for: request, level: initialSource.level)
            if let cached = try await cachedAudio(quality: actualQuality, level: initialSource.level) {
                audio = cached
            } else {
                audio = try await downloadAudio(
                    request: request,
                    initialSource: initialSource,
                    transport: transport,
                    session: session,
                    expectedCredentialRevision: expectedCredentialRevision,
                    initialResumeData: initialResumeData,
                    retryPolicy: retryPolicy,
                    audioProgressWeight: audioProgressWeight,
                    update: update
                )
                if let audioCache {
                    let downloadedQuality = cacheQuality(for: request, level: audio.source.level)
                    cacheActivity.begin()
                    if cacheGeneration.isCurrent(cacheContext) {
                        let stored = try? await audioCache.storeCopy(
                            of: audio.temporaryURL,
                            for: request.songID,
                            quality: downloadedQuality,
                            fileExtension: audio.source.type
                        )
                        if let stored, !cacheGeneration.isCurrent(cacheContext) {
                            await audioCache.invalidateCachedFile(stored.url)
                        }
                    }
                    cacheActivity.end()
                }
            }
        }
        try Task.checkCancellation()
        guard await isCurrent() else { throw CancellationError() }

        let identity = fileIdentity(for: request, source: audio.source)
        let downloadedLyrics = try await lyrics
        try Task.checkCancellation()
        guard await isCurrent() else { throw CancellationError() }
        if let existing = MusicDownloadFiles.existingDownload(
            in: request.destination,
            stem: identity.stem,
            audioExtension: identity.audioExtension,
            matchingAudio: audio.temporaryURL
        ) {
            if !audio.isCached { try? FileManager.default.removeItem(at: audio.temporaryURL) }
            try MusicDownloadFiles.writeManagedIdentity(for: request, audioURL: existing.audioURL)
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
                    MusicDownloadFiles.removeManagedIdentity(for: url)
                }
            }
        }

        do {
            try Task.checkCancellation()
            guard await isCurrent() else { throw CancellationError() }
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
            try MusicDownloadFiles.writeManagedIdentity(for: request, audioURL: targets.audioFinal)
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

    private nonisolated static func credentialContextIsCurrent(
        _ request: MusicDownloadRequest,
        transport: EAPITransport
    ) -> Bool {
        guard case .cloud = request.source else { return true }
        guard let expected = request.expectedCredentialRevision else { return false }
        return transport.credentialSnapshotValue().revision == expected
    }

    private nonisolated static func downloadAudio(
        request: MusicDownloadRequest,
        initialSource: ResolvedSource,
        transport: EAPITransport,
        session: URLSession,
        expectedCredentialRevision: UInt64,
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
        let reporter = MusicDownloadProgressReporter(weight: audioProgressWeight) {
            update(.progress($0))
        }
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
            },
            backgroundIdentifier: session.configuration.identifier.map {
                _ in MusicDownloadSession.identifier(for: request.songID)
            }
        )
        defer { transfer.invalidate() }

        for attempt in 1...retryPolicy.maximumAttempts {
            do {
                try Task.checkCancellation()
                if needsFreshSource {
                    source = try await resolvedSourceOnce(
                        for: request,
                        transport: transport,
                        expectedCredentialRevision: expectedCredentialRevision,
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
                if refreshesSource {
                    resumeData = nil
                    needsFreshSource = true
                    didRefreshSource = true
                } else {
                    resumeData = recoveredResumeData
                }

                guard attempt < retryPolicy.maximumAttempts, retryable || refreshesSource else {
                    throw MusicDownloadFailure(underlying: error, resumeData: resumeData, attempts: attempt)
                }

                let retry = attempt
                update(.retrying(
                    attempt: retry,
                    total: retryPolicy.maximumRetryCount,
                    progress: nil,
                    resumeData: resumeData,
                    discardsResumeData: refreshesSource
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

    private nonisolated static func resolvedSourceOnce(
        for request: MusicDownloadRequest,
        transport: EAPITransport,
        expectedCredentialRevision: UInt64,
        update: @escaping @Sendable (MusicDownloadUpdate) -> Void
    ) async throws -> ResolvedSource {
        try Task.checkCancellation()
        let source = try await resolvedSource(
            for: request,
            transport: transport,
            expectedCredentialRevision: expectedCredentialRevision
        )
        update(.metadata(level: source.level, expectedBytes: source.expectedBytes))
        return source
    }

    private nonisolated static func resolvedSource(
        for request: MusicDownloadRequest,
        transport: EAPITransport,
        expectedCredentialRevision: UInt64
    ) async throws -> ResolvedSource {
        if case let .cloud(userID, _) = request.source {
            let source = try await LiveMusicLibrary(transport: transport).cloudDownloadSource(
                userID: userID,
                songID: request.songID,
                expectedCredentialRevision: expectedCredentialRevision
            )
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
            fallbackOn: { ($0 as? MusicDownloadError) == .unavailable }
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
        let root = try await apiRequest(
            EAPIEndpoint("/eapi/song/enhance/player/url/v1"),
            payload: audioSourcePayload(songID: songID, level: level),
            transport: transport,
            vipCredential: credential,
            iPhoneClient: true
        )
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
        let fallbackExtension = if case let .cloud(_, fileName) = request.source {
            URL(fileURLWithPath: fileName).pathExtension
        } else {
            ""
        }
        return (
            MusicDownloadFiles.downloadStem(for: request, level: source.level),
            MusicDownloadFiles.sanitizedAudioExtension(source.type.nonEmpty ?? fallbackExtension)
        )
    }

    private nonisolated static func ensureAvailableCapacity(for expectedBytes: Int64?, at directory: URL) throws {
        guard let expectedBytes, expectedBytes > 0,
              let values = try? directory.resourceValues(forKeys: [
                  .volumeAvailableCapacityForImportantUsageKey,
                  .volumeAvailableCapacityKey
              ]),
              let available = values.volumeAvailableCapacityForImportantUsage.flatMap({ $0 > 0 ? $0 : nil })
                ?? values.volumeAvailableCapacity.map(Int64.init)
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
        cacheRoot: URL?,
        cacheContext: MusicDownloadCacheContext,
        cacheGeneration: MusicDownloadCacheGeneration,
        cacheActivity: MusicDownloadCacheActivity,
        expectedCredentialRevision: UInt64
    ) async throws -> String? {
        guard request.includeLyrics else { return nil }
        if let cacheRoot, let cached = MusicDownloadFiles.cachedLyrics(
            for: request,
            cacheRoot: cacheRoot,
            context: cacheContext,
            generation: cacheGeneration
        ) {
            return cached
        }
        do {
            let lyrics = try await mergedLyrics(
                for: request,
                transport: transport,
                expectedCredentialRevision: expectedCredentialRevision
            ).nonEmpty
            if let cacheRoot, let lyrics {
                try? MusicDownloadFiles.cacheLyrics(
                    lyrics,
                    for: request,
                    cacheRoot: cacheRoot,
                    context: cacheContext,
                    generation: cacheGeneration,
                    activity: cacheActivity
                )
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
        transport: EAPITransport,
        expectedCredentialRevision: UInt64
    ) async throws -> String {
        let lyrics: SongLyrics
        switch request.source {
        case .catalog:
            let root = try await apiRequest(
                EAPIEndpoint("/eapi/song/lyric"),
                payload: ["id": request.songID, "lv": -1, "kv": -1, "tv": -1, "yv": -1],
                transport: transport,
                cache: .lyrics
            )
            lyrics = CloudMusicDecoder.lyrics(root)
        case let .cloud(userID, _):
            lyrics = try await LiveMusicLibrary(transport: transport).cloudLyrics(
                userID: userID,
                songID: request.songID,
                expectedCredentialRevision: expectedCredentialRevision
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
    ) async throws -> [String: Any] {
        try await transport.requestJSONObject(
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

    private nonisolated static func cacheQuality(for request: MusicDownloadRequest, level: String?) -> String {
        switch request.source {
        case .catalog: level ?? "standard"
        case let .cloud(userID, _): "cloud-\(userID)"
        }
    }

    private nonisolated static func makeAudioCache(_ root: URL) -> TrackCache {
        TrackCache.shared(directory: root.appending(path: "StreamCache", directoryHint: .isDirectory))
    }

    private nonisolated static func clearOwnedDownloadCache(at root: URL) async throws {
        let hasSecurityScope = root.startAccessingSecurityScopedResource()
        defer { if hasSecurityScope { root.stopAccessingSecurityScopedResource() } }
        let downloadCache = root.appending(path: "DownloadCache", directoryHint: .isDirectory)
        for name in ["Lyrics", "Videos"] {
            let directory = downloadCache.appending(path: name, directoryHint: .isDirectory)
            if FileManager.default.fileExists(atPath: directory.path) {
                try FileManager.default.removeItem(at: directory)
            }
        }
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
