import AVFoundation
import Observation

enum PlaybackState: Equatable {
    case idle
    case preparing(songID: Int64)
    case playing(songID: Int64)
    case paused(songID: Int64)
    case failed(songID: Int64, message: String)
}

enum PlayerControlTrigger: Equatable, Sendable {
    case user
    case automaticEnd
    case playbackFailure
    case crossfade
}

enum PlayerSongTransition: Equatable, Sendable {
    case goTo
    case next
    case previous
}

enum PlayerPlayIntent: Equatable, Sendable {
    case play(songID: Int64, progress: TimeInterval)
    case pause(songID: Int64, progress: TimeInterval)
    case seek(songID: Int64, progress: TimeInterval, playing: Bool)
    case transition(
        PlayerSongTransition,
        formerSongID: Int64?,
        targetSongID: Int64,
        progress: TimeInterval,
        playing: Bool
    )
}

struct PlayerQueueOrder: Equatable, Sendable {
    let displaySongIDs: [Int64]
    let randomSongIDs: [Int64]
    let anchorSongID: Int64?
}

struct PlayerQueueIdentity: Equatable, Sendable {
    let displaySongIDs: [Int64]
    let randomSongIDs: [Int64]
    let sourcePlaylistID: Int64?
    let sessionID: UUID?
}

struct PlayerControlIntent: Equatable, Sendable {
    let trigger: PlayerControlTrigger
    let play: PlayerPlayIntent?
    let queue: PlayerQueueOrder?
}

@MainActor
@Observable
final class PlayerController {
    private static let maximumPendingPlaybackReports = 8
    private static let maximumVisibleQueueResolutionCount = 20
    typealias ControlInterceptor = @MainActor @Sendable (
        _ intent: PlayerControlIntent,
        _ commit: @escaping @MainActor @Sendable () -> Void
    ) -> Bool

    private struct PinnedCacheReference {
        let cache: TrackCache
        var count: Int
    }

    private struct RoutedPlayback {
        let item: AVPlayerItem
        let availability: PlaybackAvailability
        let pinnedURL: URL?
    }

    private struct ActiveRangeFallback {
        let itemID: ObjectIdentifier
        let generation: Int
        let songID: Int64
        let position: TimeInterval
        let initialWantsPlayback: Bool
    }

    private static let maximumCrossfadeDuration: TimeInterval = 12
    private static let prefetchWindow: TimeInterval = 10
    private static let heartModeReplenishThreshold = 3
    private static let standbyHandoffLead: TimeInterval = 0.05

    private(set) var queue: [PlaybackQueueItem] = []
    private(set) var context: PlaybackContext?
    private(set) var currentIndex: Int?
    private(set) var state: PlaybackState = .idle
    private(set) var position: TimeInterval = 0
    private(set) var pendingSeekPosition: TimeInterval?
    var displayedPosition: TimeInterval { pendingSeekPosition ?? position }
    private(set) var playbackPositionRevision: UInt64 = 0
    private(set) var lyrics: [LyricLine] = []
    private(set) var currentLyricIndex: Int?
    private(set) var isLoadingLyrics = false
    private(set) var lyricErrorMessage: String?
    private(set) var mediaDuration: TimeInterval = 0
    private(set) var playbackAvailability: PlaybackAvailability?
    private(set) var alternativeSongs: [Song] = []
    private(set) var selectedPlaybackLevel: String?
    private(set) var isSwitchingPlaybackQuality = false
    private(set) var playbackQualityErrorMessage: String?
    private(set) var playbackQualityConfirmationMessage: String?
    var volume: Double = 0.78 {
        didSet {
            if volume > 0 { lastAudibleVolume = min(volume, 1) }
            applyVolume()
        }
    }
    private(set) var crossfadeDuration: TimeInterval
    private(set) var playbackControlFadeEnabled: Bool
    private(set) var repeatMode: PlaybackRepeatMode = .off
    private(set) var isShuffleEnabled = false
    private(set) var isLinearQueueMode = false
    private(set) var isHeartModeEnabled = false
    private(set) var isLoadingHeartMode = false
    private(set) var heartModeErrorMessage: String?
    private(set) var sourcePlaylistID: Int64?
    private(set) var queueIdentity: PlayerQueueIdentity?
    private(set) var playbackHistoryEvent: PlaybackHistoryEvent?
    private(set) var playbackReportErrorMessage: String?
    private(set) var isControlInteractionLocked = false
    private(set) var isSharedControlActive = false

    @ObservationIgnored private let repository: any MusicRepository
    @ObservationIgnored private var cache: TrackCache
    @ObservationIgnored private var rangeCache: TrackRangeCache
    @ObservationIgnored private var playbackQuality: AudioQuality
    @ObservationIgnored private var avPlayer = AVPlayer()
    @ObservationIgnored private var standbyPlayer = AVPlayer()
    @ObservationIgnored private var activeSongID: Int64?
    @ObservationIgnored private var playbackGeneration = 0
    @ObservationIgnored private var wantsPlayback = false
    @ObservationIgnored private var seekInProgress = false
    @ObservationIgnored private var seekInFlightTarget: TimeInterval?
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var loadTaskID: UUID?
    @ObservationIgnored private var prefetchTask: Task<Void, Never>?
    @ObservationIgnored private var prefetchTaskID: UUID?
    @ObservationIgnored private var songResolutionTask: Task<Void, Never>?
    @ObservationIgnored private var songResolutionTaskID: UUID?
    @ObservationIgnored private var visibleQueueResolutionTask: Task<Void, Never>?
    @ObservationIgnored private var visibleQueueResolutionTaskID: UUID?
    @ObservationIgnored private var visibleQueueResolutionIDs: Set<Int64> = []
    @ObservationIgnored private var pendingVisibleQueueSongID: Int64?
    @ObservationIgnored private var lyricTask: Task<Void, Never>?
    @ObservationIgnored private var lyricTaskID: UUID?
    @ObservationIgnored private var heartModeTask: Task<Void, Never>?
    @ObservationIgnored private var heartModeSeedSongID: Int64?
    @ObservationIgnored private var heartModeHasRecommendations = false
    @ObservationIgnored private var heartModeExhausted = false
    @ObservationIgnored private var heartModeOriginalQueue: [PlaybackQueueItem]?
    @ObservationIgnored private var heartModeOriginalIndex: Int?
    @ObservationIgnored private var qualitySwitchTask: Task<Void, Never>?
    @ObservationIgnored private var qualitySwitchRevision = 0
    @ObservationIgnored private var standbyPreparationRevision = 0
    @ObservationIgnored private var standbyHandoffTask: Task<Void, Never>?
    @ObservationIgnored private var rangeFallbackAttempts: Set<ObjectIdentifier> = []
    @ObservationIgnored private var rangeFallbackTasks: [ObjectIdentifier: Task<Void, Never>] = [:]
    @ObservationIgnored private var activeRangeFallback: ActiveRangeFallback?
    @ObservationIgnored private var fadeTask: Task<Void, Never>?
    @ObservationIgnored private var fadeProgress: Double?
    @ObservationIgnored private var playbackFadeTask: Task<Void, Never>?
    @ObservationIgnored private var playbackFadeGain = 1.0
    @ObservationIgnored private var pendingPlaybackFadeIn = false
    @ObservationIgnored private var standbySeekPosition: TimeInterval?
    @ObservationIgnored private var standbyTransitionDuration: TimeInterval?
    @ObservationIgnored private var standbyPlaybackAvailability: PlaybackAvailability?
    @ObservationIgnored private var qualityBeforeSwitch: String?
    @ObservationIgnored private var reportedPodcastPlaybackGeneration = -1
    @ObservationIgnored private var timedPlaybackSongID: Int64?
    @ObservationIgnored private var timedPlaybackSourceID: Int64?
    @ObservationIgnored private var timedPlaybackTotalSeconds: Int?
    @ObservationIgnored private var timedPlaybackCredentialRevision: UInt64?
    @ObservationIgnored private var playbackStartReportTask: Task<Bool, Never>?
    @ObservationIgnored private var playbackReportTasks: [UUID: Task<Bool, Never>] = [:]
    @ObservationIgnored private var playbackReportOrder: [UUID] = []
    @ObservationIgnored private var accountCredentialRevision: UInt64 = 0
    @ObservationIgnored private var playbackHistorySequence: UInt64 = 0
    @ObservationIgnored private var playbackTimingStartedAt: ContinuousClock.Instant?
    @ObservationIgnored private var listenedDuration: Duration = .zero
    @ObservationIgnored private var lastAudibleVolume = 0.78
    @ObservationIgnored private var shuffleOrder: [Int] = []
    @ObservationIgnored private var shuffleCursor = 0
    @ObservationIgnored private var savedQueueMode: (shuffle: Bool, repeatMode: PlaybackRepeatMode)?
    @ObservationIgnored private var prefetchTriggered = false
    @ObservationIgnored private var crossfadeTriggered = false
    @ObservationIgnored private var prefetchedSongID: Int64?
    @ObservationIgnored private var prefetchedSource: PlaybackSource?
    @ObservationIgnored private var cacheGeneration = 0
    @ObservationIgnored private var cacheConfigurationTask: Task<Void, Never>?
    @ObservationIgnored private var pinnedCaches: [String: PinnedCacheReference] = [:]
    @ObservationIgnored private var queueSessionID: UUID?
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var playerStateObservation: NSKeyValueObservation?
    @ObservationIgnored private var standbyStatusObservation: NSKeyValueObservation?
    @ObservationIgnored private var itemStatusObservation: NSKeyValueObservation?
    @ObservationIgnored private var itemDurationObservation: NSKeyValueObservation?
    @ObservationIgnored private var itemEndObserver: NSObjectProtocol?
    @ObservationIgnored private var itemFailureObserver: NSObjectProtocol?
    @ObservationIgnored var controlInterceptor: ControlInterceptor? {
        didSet {
            isSharedControlActive = controlInterceptor != nil
            if isSharedControlActive {
                if isHeartModeEnabled { stopHeartMode() }
                repeatMode = .off
                resetTransitionPreparation()
            } else {
                pendingAutomaticControlGeneration = nil
                pendingAutomaticControlTrigger = nil
                crossfadeTriggered = false
            }
        }
    }
    @ObservationIgnored private var authoritativeApplyDepth = 0
    @ObservationIgnored private var pendingAutomaticControlGeneration: Int?
    @ObservationIgnored private var pendingAutomaticControlTrigger: PlayerControlTrigger?

    init(
        repository: any MusicRepository,
        playbackQuality: AudioQuality = .standard,
        cacheRoot: URL? = nil,
        cache: TrackCache? = nil,
        crossfadeDuration: TimeInterval = 3,
        playbackControlFadeEnabled: Bool = false,
        rangeCache: TrackRangeCache? = nil
    ) {
        self.repository = repository
        self.playbackQuality = playbackQuality
        self.crossfadeDuration = min(max(crossfadeDuration, 0), Self.maximumCrossfadeDuration)
        self.playbackControlFadeEnabled = playbackControlFadeEnabled
        let cache = cache ?? Self.makeCache(root: cacheRoot)
        self.cache = cache
        self.rangeCache = rangeCache ?? TrackRangeCache.shared(trackCache: cache)
        avPlayer.automaticallyWaitsToMinimizeStalling = false
        standbyPlayer.automaticallyWaitsToMinimizeStalling = false
        applyVolume()
        installPlayerObservers()
    }

    func configure(playbackQuality: AudioQuality, cacheRoot: URL) {
        cancelStandbyHandoff()
        let isRecoveringActiveRange = avPlayer.currentItem.map {
            rangeFallbackAttempts.contains(ObjectIdentifier($0))
        } ?? false
        let pendingIndex = loadTask == nil && !isRecoveringActiveRange ? nil : currentIndex
        let previousConfiguration = cacheConfigurationTask
        previousConfiguration?.cancel()
        let prefetch = prefetchTask
        prefetch?.cancel()
        qualitySwitchTask?.cancel()
        qualitySwitchTask = nil
        qualitySwitchRevision += 1
        finishCrossfade()
        isSwitchingPlaybackQuality = false
        qualityBeforeSwitch = nil
        self.playbackQuality = playbackQuality
        selectedPlaybackLevel = nil
        cacheGeneration += 1
        let cacheGeneration = cacheGeneration
        resetTransitionPreparation()
        if previousConfiguration == nil, prefetch == nil {
            let cache = Self.makeCache(root: cacheRoot)
            self.cache = cache
            rangeCache = TrackRangeCache.shared(trackCache: cache)
            if let pendingIndex {
                activate(index: pendingIndex, preservingShuffleOrder: true)
            }
            return
        }
        cacheConfigurationTask = Task { @MainActor [weak self] in
            _ = await previousConfiguration?.result
            _ = await prefetch?.result
            guard !Task.isCancelled,
                  let self,
                  self.cacheGeneration == cacheGeneration
            else { return }
            self.resetTransitionPreparation()
            let cache = Self.makeCache(root: cacheRoot)
            self.cache = cache
            self.rangeCache = TrackRangeCache.shared(trackCache: cache)
            self.cacheConfigurationTask = nil
            if let pendingIndex,
               self.currentIndex == pendingIndex {
                self.activate(index: pendingIndex, preservingShuffleOrder: true)
            }
        }
    }

    func clearCache() async throws {
        cancelStandbyHandoff()
        var rangeCaches: [ObjectIdentifier: TrackRangeCache] = [ObjectIdentifier(rangeCache): rangeCache]
        for item in [avPlayer.currentItem, standbyPlayer.currentItem] {
            guard let item = item as? RangeCachingPlayerItem else { continue }
            rangeCaches[ObjectIdentifier(item.rangeCache)] = item.rangeCache
        }
        var trackCaches: [ObjectIdentifier: TrackCache] = [ObjectIdentifier(cache): cache]
        for rangeCache in rangeCaches.values {
            trackCaches[ObjectIdentifier(rangeCache.trackCache)] = rangeCache.trackCache
        }
        for reference in pinnedCaches.values {
            trackCaches[ObjectIdentifier(reference.cache)] = reference.cache
        }

        cancelPendingQualitySwitch()
        _ = await cacheConfigurationTask?.result
        let task = prefetchTask
        task?.cancel()
        _ = await task?.result
        resetTransitionPreparation()

        rangeCaches[ObjectIdentifier(rangeCache)] = rangeCache
        for item in [avPlayer.currentItem, standbyPlayer.currentItem] {
            guard let item = item as? RangeCachingPlayerItem else { continue }
            rangeCaches[ObjectIdentifier(item.rangeCache)] = item.rangeCache
        }
        var firstError: Error?
        for rangeCache in rangeCaches.values {
            do {
                try await rangeCache.clear()
            } catch {
                if firstError == nil { firstError = error }
            }
            trackCaches[ObjectIdentifier(rangeCache.trackCache)] = rangeCache.trackCache
        }

        trackCaches[ObjectIdentifier(cache)] = cache
        for reference in pinnedCaches.values {
            trackCaches[ObjectIdentifier(reference.cache)] = reference.cache
        }
        for cache in trackCaches.values {
            do {
                try await cache.clear()
            } catch {
                if firstError == nil { firstError = error }
            }
        }
        if let firstError { throw firstError }
    }

    func setAccountCredentialRevision(_ revision: UInt64) {
        guard revision != accountCredentialRevision else { return }
        accountCredentialRevision = revision
        cancelPlaybackReports()
        playbackTimingStartedAt = nil
        listenedDuration = .zero
        // Keep the song ID so a delayed .playing callback cannot report it under the new account.
        timedPlaybackSourceID = nil
        timedPlaybackTotalSeconds = nil
        timedPlaybackCredentialRevision = nil
    }

    func setCrossfadeDuration(_ seconds: TimeInterval) {
        crossfadeDuration = min(max(seconds, 0), Self.maximumCrossfadeDuration)
        if crossfadeDuration == 0, fadeProgress != nil { finishCrossfade() }
        if crossfadeDuration == 0, playbackFadeTask != nil || pendingPlaybackFadeIn {
            finishPlaybackControlFade()
        }
    }

    func setPlaybackControlFadeEnabled(_ enabled: Bool) {
        guard playbackControlFadeEnabled != enabled else { return }
        playbackControlFadeEnabled = enabled
        if !enabled { finishPlaybackControlFade() }
    }

    func setControlInteractionLocked(_ locked: Bool) {
        isControlInteractionLocked = locked
    }

    isolated deinit {
        cancelStandbyHandoff()
        standbyPreparationRevision &+= 1
        standbyPlayer.cancelPendingPrerolls()
        standbyPlayer.currentItem?.cancelPendingSeeks()
        resetActiveSeek()
        loadTask?.cancel()
        prefetchTask?.cancel()
        cacheConfigurationTask?.cancel()
        songResolutionTask?.cancel()
        visibleQueueResolutionTask?.cancel()
        lyricTask?.cancel()
        heartModeTask?.cancel()
        qualitySwitchTask?.cancel()
        rangeFallbackTasks.values.forEach { $0.cancel() }
        (avPlayer.currentItem as? RangeCachingPlayerItem)?.cancelRangeLoading()
        (standbyPlayer.currentItem as? RangeCachingPlayerItem)?.cancelRangeLoading()
        fadeTask?.cancel()
        playbackFadeTask?.cancel()
        playbackReportTasks.values.forEach { $0.cancel() }
        for (path, reference) in pinnedCaches {
            for _ in 0..<reference.count {
                Task { await reference.cache.unpin(URL(fileURLWithPath: path)) }
            }
        }
        playerStateObservation?.invalidate()
        standbyStatusObservation?.invalidate()
        itemStatusObservation?.invalidate()
        itemDurationObservation?.invalidate()
        if let itemEndObserver { NotificationCenter.default.removeObserver(itemEndObserver) }
        if let itemFailureObserver { NotificationCenter.default.removeObserver(itemFailureObserver) }
        if let timeObserver { avPlayer.removeTimeObserver(timeObserver) }
    }

    var currentSong: Song? {
        guard let currentIndex, queue.indices.contains(currentIndex) else { return nil }
        return queue[currentIndex].song
    }

    var currentSongID: Int64? {
        guard let currentIndex, queue.indices.contains(currentIndex) else { return nil }
        return queue[currentIndex].id
    }

    var currentPlaybackLevel: String? {
        playbackAvailability?.level ?? selectedPlaybackLevel
    }

    var isPlaying: Bool {
        guard case .playing = state else { return false }
        return true
    }

    var isPreparing: Bool {
        guard case .preparing = state else { return false }
        return true
    }

    var isPlaybackRequested: Bool { wantsPlayback }

    var hasCurrentPlayerItem: Bool { avPlayer.currentItem != nil }

    var hasPendingPrefetch: Bool { prefetchTask != nil }

    var hasPendingPlaybackFade: Bool { playbackFadeTask != nil || pendingPlaybackFadeIn }

    var pendingPlaybackReportCount: Int { playbackReportTasks.count }

    var canGoPrevious: Bool { currentSong != nil }

    var canGoNext: Bool {
        guard currentIndex != nil else { return false }
        if isShuffleEnabled {
            return shuffleCursor + 1 < shuffleOrder.count || repeatMode == .all
        }
        return PlaybackNavigation.nextIndex(
            currentIndex: currentIndex ?? 0,
            count: queue.count,
            repeatMode: repeatMode,
            automatic: false
        ) != nil
    }

    var duration: TimeInterval {
        mediaDuration > 0 ? mediaDuration : TimeInterval(currentSong?.duration.components.seconds ?? 0)
    }

    var currentLyric: LyricLine? {
        guard let currentLyricIndex, lyrics.indices.contains(currentLyricIndex) else { return nil }
        return lyrics[currentLyricIndex]
    }

    var currentQueueOrder: PlayerQueueOrder {
        let displaySongIDs = queue.map(\.id)
        return PlayerQueueOrder(
            displaySongIDs: displaySongIDs,
            randomSongIDs: randomSongIDs(for: displaySongIDs),
            anchorSongID: currentSongID
        )
    }

    func applyAuthoritatively<Result>(_ body: () throws -> Result) rethrows -> Result {
        authoritativeApplyDepth += 1
        defer { authoritativeApplyDepth -= 1 }
        return try body()
    }

    @discardableResult
    func replaceQueueAuthoritatively(_ order: PlayerQueueOrder) -> Bool {
        guard Self.isValidQueueOrder(order) else { return false }
        let anchorSongID = order.anchorSongID
            ?? currentSongID.flatMap { order.displaySongIDs.contains($0) ? $0 : nil }
            ?? order.displaySongIDs.first
        guard let anchorSongID,
              let anchorIndex = order.displaySongIDs.firstIndex(of: anchorSongID)
        else { return false }

        let knownSongs = queue.compactMap(\.song)
        return applyAuthoritatively {
            if isHeartModeEnabled {
                stopHeartMode(restoringQueue: false)
            } else {
                restoreQueueMode()
            }
            heartModeErrorMessage = nil
            isLinearQueueMode = false
            savedQueueMode = nil
            sourcePlaylistID = nil
            queueSessionID = nil
            installQueue(
                songIDs: order.displaySongIDs,
                knownSongs: knownSongs,
                currentIndex: anchorIndex
            )
            installPlaybackOrder(
                order,
                shuffleEnabled: order.randomSongIDs != order.displaySongIDs
            )
            return true
        }
    }

    func play(
        _ song: Song,
        in visibleSongs: [Song],
        allSongIDs: [Int64]? = nil,
        playlistID: Int64? = nil,
        queueSessionID: UUID? = nil
    ) {
        guard let plan = PlaybackQueuePlan.make(
            selectedSongID: song.id,
            visibleSongIDs: visibleSongs.map(\.id),
            allSongIDs: allSongIDs
        ) else { return }
        let songIDs = plan.songIDs
        let index = plan.startIndex
        let newContext = PlaybackContext(songIDs: songIDs, startIndex: index)
        let sameQueueSource = queueIdentity?.displaySongIDs == songIDs
            && queueIdentity?.sourcePlaylistID == playlistID
            && queueIdentity?.sessionID == queueSessionID
        let shuffleEnabled = savedQueueMode?.shuffle ?? isShuffleEnabled
        let randomSongIDs = if sameQueueSource, let queueIdentity {
            queueIdentity.randomSongIDs
        } else if shuffleEnabled {
            Self.shuffledSongIDs(currentSongID: song.id, displaySongIDs: songIDs)
        } else {
            songIDs
        }
        let identity = PlayerQueueIdentity(
            displaySongIDs: songIDs,
            randomSongIDs: randomSongIDs,
            sourcePlaylistID: playlistID,
            sessionID: queueSessionID
        )
        let isSameQueue = queueIdentity == identity
        let action: PlaybackSelectionAction = if !isSameQueue, currentSong?.id == song.id {
            .switchQueue(resume: !isPlaying)
        } else {
            PlaybackSelectionAction.decide(
                currentSongID: currentSong?.id,
                isPlaying: isPlaying,
                currentContext: context,
                selectedSongID: song.id,
                newContext: newContext
            )
        }
        let queueOrder = PlayerQueueOrder(
            displaySongIDs: songIDs,
            randomSongIDs: randomSongIDs,
            anchorSongID: song.id
        )
        let playIntent: PlayerPlayIntent? = switch action {
        case .keepPlaying: nil
        case .resume:
            .play(songID: song.id, progress: resumeProgress)
        case let .switchQueue(shouldResume):
            shouldResume ? .play(songID: song.id, progress: resumeProgress) : nil
        case .replaceTrackAtZero:
            .transition(
                .goTo,
                formerSongID: currentSongID,
                targetSongID: song.id,
                progress: 0,
                playing: true
            )
        }
        let queueIntent = isSameQueue ? nil : queueOrder
        let commit: @MainActor @Sendable () -> Void = { [weak self] in
            guard let self else { return }
            self.playLocally(
                song: song,
                visibleSongs: visibleSongs,
                playlistID: playlistID,
                queueSessionID: queueSessionID,
                songIDs: songIDs,
                index: index,
                action: action,
                queueOrder: queueOrder,
                shuffleEnabled: shuffleEnabled,
                isSameQueue: isSameQueue
            )
        }
        guard playIntent != nil || queueIntent != nil else {
            commit()
            return
        }
        requestControl(
            PlayerControlIntent(trigger: .user, play: playIntent, queue: queueIntent),
            commit: commit
        )
    }

    func appendToQueue(_ songs: [Song]) {
        var ids = Set(queue.map(\.id))
        let additions = songs.filter { ids.insert($0.id).inserted }
        guard !additions.isEmpty else { return }
        let displaySongIDs = queue.map(\.id) + additions.map(\.id)
        let randomSongIDs = isShuffleEnabled
            ? currentQueueOrder.randomSongIDs + additions.map(\.id)
            : displaySongIDs
        let order = PlayerQueueOrder(
            displaySongIDs: displaySongIDs,
            randomSongIDs: randomSongIDs,
            anchorSongID: currentSongID
        )
        requestControl(
            PlayerControlIntent(trigger: .user, play: nil, queue: order)
        ) { [weak self] in
            self?.appendToQueueLocally(additions, order: order)
        }
    }

    @discardableResult
    func removeFromQueue(_ songID: Int64) -> Bool {
        guard let removalIndex = queue.firstIndex(where: { $0.id == songID }),
              let currentIndex,
              removalIndex != currentIndex
        else { return false }
        let anchorSongID = queue[currentIndex].id
        let displaySongIDs = queue.map(\.id).filter { $0 != songID }
        let order = PlayerQueueOrder(
            displaySongIDs: displaySongIDs,
            randomSongIDs: isShuffleEnabled
                ? currentQueueOrder.randomSongIDs.filter { $0 != songID }
                : displaySongIDs,
            anchorSongID: anchorSongID
        )
        return requestControl(
            PlayerControlIntent(trigger: .user, play: nil, queue: order)
        ) { [weak self] in
            self?.removeFromQueueLocally(songID, order: order)
        }
    }

    func useLinearQueueMode() {
        if savedQueueMode == nil {
            savedQueueMode = (isShuffleEnabled, repeatMode)
        }
        isLinearQueueMode = true
        isShuffleEnabled = false
        repeatMode = .off
        rebuildShuffleOrder(keeping: currentIndex)
        updateQueueIdentity()
        resetTransitionPreparation()
    }

    func playQueuedSong(_ songID: Int64) {
        guard let index = queue.firstIndex(where: { $0.id == songID }) else { return }
        if currentIndex == index, activeSongID == songID {
            if !wantsPlayback { setPlayback(true) }
            return
        }
        requestSongTransition(to: index, trigger: .user)
    }

    func resolveQueueSongs(visibleAround songID: Int64) {
        guard let index = queue.firstIndex(where: { $0.id == songID }),
              queue[index].song == nil,
              !visibleQueueResolutionIDs.contains(songID)
        else { return }
        pendingVisibleQueueSongID = songID
        startVisibleQueueResolutionIfNeeded()
    }

    func togglePlayback() {
        setPlayback(!wantsPlayback)
    }

    func setPlayback(_ shouldPlay: Bool) {
        guard let songID = currentSongID, shouldPlay != wantsPlayback else { return }
        let playIntent: PlayerPlayIntent
        if shouldPlay, case .failed = state {
            playIntent = .transition(
                .goTo,
                formerSongID: songID,
                targetSongID: songID,
                progress: 0,
                playing: true
            )
        } else if shouldPlay {
            playIntent = .play(songID: songID, progress: resumeProgress)
        } else {
            playIntent = .pause(songID: songID, progress: position)
        }
        requestControl(
            PlayerControlIntent(trigger: .user, play: playIntent, queue: nil)
        ) { [weak self] in
            if shouldPlay {
                self?.resumeLocally()
            } else {
                self?.pauseLocally()
            }
        }
    }

    func pauseForVideo() {
        if wantsPlayback { setPlayback(false) }
    }

    func previous() {
        guard let currentIndex else { return }
        if position > 3 {
            requestSeek(to: 0, trigger: .user)
            return
        }

        let target: Int?
        if isShuffleEnabled {
            target = shuffleCursor > 0 ? shuffleOrder[shuffleCursor - 1] : nil
        } else {
            target = PlaybackNavigation.previousIndex(
                currentIndex: currentIndex,
                count: queue.count,
                repeatMode: repeatMode
            )
        }

        if let target, target != currentIndex {
            requestSongTransition(to: target, trigger: .user, transition: .previous)
        } else {
            requestSeek(to: 0, trigger: .user)
        }
    }

    func next() {
        advance(trigger: .user)
    }

    func toggleHeartMode() {
        guard !isSharedControlActive else { return }
        if isHeartModeEnabled {
            stopHeartMode()
            return
        }
        guard let songID = currentSongID else { return }
        heartModeOriginalQueue = queue
        heartModeOriginalIndex = currentIndex
        heartModeSeedSongID = songID
        heartModeHasRecommendations = false
        heartModeExhausted = false
        heartModeErrorMessage = nil
        useLinearQueueMode()
        isHeartModeEnabled = true
        loadHeartModeSongs(startSongID: songID, replacingTail: true)
    }

    func toggleShuffle() {
        guard !isLinearQueueMode else { return }
        let enabled = !isShuffleEnabled
        let displaySongIDs = queue.map(\.id)
        guard let currentSongID, !displaySongIDs.isEmpty else {
            isShuffleEnabled = enabled
            rebuildShuffleOrder(keeping: currentIndex)
            updateQueueIdentity()
            resetTransitionPreparation()
            return
        }
        let order = PlayerQueueOrder(
            displaySongIDs: displaySongIDs,
            randomSongIDs: enabled
                ? Self.shuffledSongIDs(currentSongID: currentSongID, displaySongIDs: displaySongIDs)
                : displaySongIDs,
            anchorSongID: currentSongID
        )
        requestControl(
            PlayerControlIntent(trigger: .user, play: nil, queue: order)
        ) { [weak self] in
            self?.installPlaybackOrder(order, shuffleEnabled: enabled)
        }
    }

    func cycleRepeatMode() {
        guard !isLinearQueueMode, !isSharedControlActive else { return }
        repeatMode = repeatMode.next
        resetTransitionPreparation()
    }

    func toggleMute() {
        volume = volume > 0 ? 0 : max(lastAudibleVolume, 0.1)
    }

    func retryPlayback() {
        guard let currentIndex, let songID = currentSongID else { return }
        requestControl(
            PlayerControlIntent(
                trigger: .user,
                play: .transition(
                    .goTo,
                    formerSongID: songID,
                    targetSongID: songID,
                    progress: 0,
                    playing: true
                ),
                queue: nil
            )
        ) { [weak self] in
            self?.retryPlaybackLocally(index: currentIndex)
        }
    }

    func retryLyrics() {
        guard let songID = currentSong?.id else { return }
        lyricTask?.cancel()
        isLoadingLyrics = true
        lyricErrorMessage = nil
        loadLyrics(generation: playbackGeneration, songID: songID)
    }

    func selectPlaybackQuality(_ quality: SongQualityDetail) {
        guard quality.isAvailable, SongQualityDetail.orderedLevels.contains(quality.id) else { return }
        let activeLevel = currentPlaybackLevel
        let previousSelection = isSwitchingPlaybackQuality ? qualityBeforeSwitch : selectedPlaybackLevel
        if isSwitchingPlaybackQuality { cancelStandbyHandoff() }
        selectedPlaybackLevel = quality.id
        playbackQualityErrorMessage = nil
        playbackQualityConfirmationMessage = nil
        resetTransitionPreparation()
        if isSwitchingPlaybackQuality, activeLevel == quality.id {
            cancelPendingQualitySwitch(restoringSelection: false)
            return
        }
        guard activeLevel != quality.id,
              let songID = currentSongID,
              avPlayer.currentItem != nil
        else { return }

        finishCrossfade()
        if wantsPlayback { avPlayer.play() }
        qualitySwitchTask?.cancel()
        qualitySwitchRevision += 1
        let revision = qualitySwitchRevision
        let cacheGeneration = cacheGeneration
        qualityBeforeSwitch = previousSelection
        isSwitchingPlaybackQuality = true
        let cache = cache
        let rangeCache = rangeCache
        qualitySwitchTask = Task { @MainActor [weak self] in
            var routed: RoutedPlayback?
            do {
                try Task.checkCancellation()
                let result = try await self?.routedPlayback(
                    songID: songID,
                    exactLevel: quality.id,
                    quality: nil,
                    prefetchedSource: nil,
                    cache: cache,
                    rangeCache: rangeCache,
                    isValid: { [weak self] in
                        guard let self else { return false }
                        return self.cacheGeneration == cacheGeneration
                            && self.qualitySwitchRevision == revision
                            && self.currentSongID == songID
                    }
                )
                guard let result else { throw CancellationError() }
                routed = result
                guard let self,
                      self.cacheGeneration == cacheGeneration,
                      self.qualitySwitchRevision == revision,
                      self.currentSongID == songID
                else {
                    (result.item as? RangeCachingPlayerItem)?.cancelRangeLoading()
                    if let pinnedURL = result.pinnedURL { await cache.unpin(pinnedURL) }
                    return
                }

                self.qualitySwitchTask = nil
                self.selectedPlaybackLevel = result.availability.level ?? quality.id
                self.finishCrossfade()
                if let pinnedURL = result.pinnedURL {
                    self.registerPinned(pinnedURL, cache: cache)
                    routed = nil
                }
                self.prepareCrossfade(
                    result.item,
                    generation: self.playbackGeneration,
                    songID: songID,
                    seekPosition: self.position,
                    transitionDuration: 0.2,
                    playbackAvailability: result.availability,
                    qualityRevision: revision
                )
            } catch is CancellationError {
                if let pinnedURL = routed?.pinnedURL { await cache.unpin(pinnedURL) }
            } catch {
                if let pinnedURL = routed?.pinnedURL { await cache.unpin(pinnedURL) }
                guard let self,
                      self.qualitySwitchRevision == revision,
                      self.currentSongID == songID
                else { return }
                self.qualitySwitchTask = nil
                self.selectedPlaybackLevel = previousSelection
                self.isSwitchingPlaybackQuality = false
                self.qualityBeforeSwitch = nil
                self.playbackQualityErrorMessage = error.localizedDescription
            }
        }
    }

    func seek(to seconds: TimeInterval) {
        guard currentSong != nil else { return }
        let target = min(max(0, seconds), duration)
        requestSeek(to: target, trigger: .user)
    }

    @discardableResult
    private func requestControl(
        _ intent: PlayerControlIntent,
        commit: @escaping @MainActor @Sendable () -> Void
    ) -> Bool {
        guard beginControlRequest(trigger: intent.trigger) else { return false }
        guard authoritativeApplyDepth == 0, let controlInterceptor else {
            commit()
            return true
        }
        return controlInterceptor(intent, commit)
    }

    private func playLocally(
        song: Song,
        visibleSongs: [Song],
        playlistID: Int64?,
        queueSessionID: UUID?,
        songIDs: [Int64],
        index: Int,
        action: PlaybackSelectionAction,
        queueOrder: PlayerQueueOrder,
        shuffleEnabled: Bool,
        isSameQueue: Bool
    ) {
        if isHeartModeEnabled {
            stopHeartMode(restoringQueue: false)
        } else {
            restoreQueueMode()
        }
        heartModeErrorMessage = nil
        sourcePlaylistID = playlistID
        self.queueSessionID = queueSessionID

        switch action {
        case .keepPlaying:
            mergeKnownSongs(visibleSongs)
        case .resume:
            mergeKnownSongs(visibleSongs)
            resumeLocally()
        case let .switchQueue(shouldResume):
            installQueue(songIDs: songIDs, knownSongs: visibleSongs, currentIndex: index)
            installPlaybackOrder(queueOrder, shuffleEnabled: shuffleEnabled)
            if shouldResume { resumeLocally() }
        case .replaceTrackAtZero:
            if isSameQueue {
                mergeKnownSongs(visibleSongs)
            } else {
                installQueue(songIDs: songIDs, knownSongs: visibleSongs, currentIndex: index)
                installPlaybackOrder(queueOrder, shuffleEnabled: shuffleEnabled)
            }
            activate(index: index, preservingShuffleOrder: true)
        }
    }

    private func appendToQueueLocally(_ additions: [Song], order: PlayerQueueOrder) {
        queue.append(contentsOf: additions.map { PlaybackQueueItem(id: $0.id, song: $0) })
        if let currentIndex {
            context = PlaybackContext(songIDs: queue.map(\.id), startIndex: currentIndex)
        }
        installPlaybackOrder(order, shuffleEnabled: isShuffleEnabled)
    }

    private func removeFromQueueLocally(_ songID: Int64, order: PlayerQueueOrder) {
        guard let removalIndex = queue.firstIndex(where: { $0.id == songID }),
              let anchorSongID = order.anchorSongID
        else { return }
        queue.remove(at: removalIndex)
        currentIndex = queue.firstIndex { $0.id == anchorSongID }
        if let currentIndex {
            context = PlaybackContext(songIDs: queue.map(\.id), startIndex: currentIndex)
        }
        installPlaybackOrder(order, shuffleEnabled: isShuffleEnabled)
    }

    private func requestSeek(to seconds: TimeInterval, trigger: PlayerControlTrigger) {
        guard let songID = currentSongID else { return }
        let target = min(max(0, seconds), duration)
        requestControl(
            PlayerControlIntent(
                trigger: trigger,
                play: .seek(songID: songID, progress: target, playing: wantsPlayback),
                queue: nil
            )
        ) { [weak self] in
            self?.seekLocally(to: target)
        }
    }

    private func requestRestartCurrentTrack(trigger: PlayerControlTrigger) {
        guard let songID = currentSongID else { return }
        requestControl(
            PlayerControlIntent(
                trigger: trigger,
                play: .seek(songID: songID, progress: 0, playing: true),
                queue: nil
            )
        ) { [weak self] in
            self?.restartCurrentTrackLocally()
        }
    }

    private func seekLocally(to seconds: TimeInterval) {
        guard currentSongID != nil, currentSong != nil else { return }
        if isSwitchingPlaybackQuality, standbyPlayer.currentItem != nil {
            invalidateStandbyPreparation()
        }
        if fadeProgress != nil { finishCrossfade() }
        let target = min(max(0, seconds), duration)
        playbackPositionRevision &+= 1
        pendingSeekPosition = target
        startPendingSeekIfPossible()
    }

    private func startPendingSeekIfPossible() {
        guard !seekInProgress,
              let target = pendingSeekPosition,
              let songID = currentSongID,
              activeSongID == songID,
              avPlayer.currentItem?.status == .readyToPlay
        else { return }
        let generation = playbackGeneration
        let seekingPlayer = avPlayer
        guard let seekingItem = seekingPlayer.currentItem else { return }
        let tolerance = seekTolerance(for: target)
        seekInProgress = true
        seekInFlightTarget = target
        seekingPlayer.seek(
            to: CMTime(seconds: target, preferredTimescale: 600),
            toleranceBefore: tolerance.before,
            toleranceAfter: tolerance.after
        ) { [weak self] finished in
            Task { @MainActor [weak self] in
                guard let self,
                      self.isCurrent(generation: generation, songID: songID),
                      self.avPlayer === seekingPlayer,
                      seekingPlayer.currentItem === seekingItem,
                      self.seekInProgress,
                      self.seekInFlightTarget == target
                else { return }

                self.seekInProgress = false
                self.seekInFlightTarget = nil
                if let pendingTarget = self.pendingSeekPosition, pendingTarget != target {
                    self.startPendingSeekIfPossible()
                    return
                }

                let actualPosition = seekingPlayer.currentTime().seconds
                if actualPosition.isFinite, actualPosition >= 0 {
                    self.position = actualPosition
                }
                if self.pendingSeekPosition == target {
                    self.pendingSeekPosition = nil
                }
                self.updateCurrentLyricIndex()
                if self.completeActiveRangeFallback(
                    item: seekingItem,
                    target: target,
                    finished: finished,
                    actualPosition: actualPosition
                ) {
                    return
                }
                if !finished { self.syncPositionFromActivePlayer() }
                self.resumeStandbyPreparationAfterActiveSeek()
            }
        }
    }

    private func completeActiveRangeFallback(
        item: AVPlayerItem,
        target: TimeInterval,
        finished: Bool,
        actualPosition: TimeInterval
    ) -> Bool {
        guard let fallback = activeRangeFallback,
              fallback.itemID == ObjectIdentifier(item)
        else { return false }
        guard fallback.generation == playbackGeneration,
              fallback.songID == currentSongID,
              finished,
              actualPosition.isFinite,
              actualPosition >= 0,
              abs(actualPosition - target) <= 0.15
        else {
            activeRangeFallback = nil
            failAndAdvance(
                generation: fallback.generation,
                songID: fallback.songID,
                message: "无法恢复音频流位置"
            )
            return true
        }

        activeRangeFallback = nil
        applyVolume()
        if wantsPlayback {
            state = .preparing(songID: fallback.songID)
            avPlayer.play()
        } else {
            avPlayer.pause()
            state = .paused(songID: fallback.songID)
        }
        return true
    }

    private func seekTolerance(for target: TimeInterval) -> (before: CMTime, after: CMTime) {
        let maximum = 0.1
        let before = min(maximum, max(0, target))
        let after = duration.isFinite && duration > 0
            ? min(maximum, max(0, duration - target))
            : maximum
        return (
            CMTime(seconds: before, preferredTimescale: 600),
            CMTime(seconds: after, preferredTimescale: 600)
        )
    }

    private func resetActiveSeek(preservingPendingPosition: Bool = false) {
        if seekInProgress { avPlayer.currentItem?.cancelPendingSeeks() }
        seekInProgress = false
        seekInFlightTarget = nil
        if !preservingPendingPosition { pendingSeekPosition = nil }
    }

    private func resumeStandbyPreparationAfterActiveSeek() {
        guard isSwitchingPlaybackQuality,
              pendingSeekPosition == nil,
              let item = standbyPlayer.currentItem,
              let songID = currentSongID
        else { return }
        let confirmedPosition = max(0, position)
        standbySeekPosition = confirmedPosition
        guard item.status == .readyToPlay,
              standbyStatusObservation == nil
        else { return }
        startStandbyPreparation(
            item,
            generation: playbackGeneration,
            songID: songID,
            qualityRevision: qualitySwitchRevision,
            preparationRevision: standbyPreparationRevision,
            seekPosition: confirmedPosition
        )
    }

    @discardableResult
    private func requestSongTransition(
        to index: Int,
        trigger: PlayerControlTrigger,
        transition: PlayerSongTransition = .goTo
    ) -> Bool {
        guard queue.indices.contains(index) else { return false }
        let targetSongID = queue[index].id
        return requestControl(
            PlayerControlIntent(
                trigger: trigger,
                play: .transition(
                    transition,
                    formerSongID: activeSongID ?? currentSongID,
                    targetSongID: targetSongID,
                    progress: 0,
                    playing: true
                ),
                queue: nil
            )
        ) { [weak self] in
            self?.activate(index: index, preservingShuffleOrder: true)
        }
    }

    private func retryPlaybackLocally(index: Int) {
        activate(
            index: index,
            preservingShuffleOrder: true,
            preservingPlaybackQualityOverride: true
        )
    }

    private var resumeProgress: TimeInterval {
        duration > 0 && position >= duration - 0.1 ? 0 : position
    }

    private func beginControlRequest(trigger: PlayerControlTrigger) -> Bool {
        guard trigger != .user, authoritativeApplyDepth == 0 else { return true }
        guard pendingAutomaticControlGeneration != playbackGeneration else { return false }
        pendingAutomaticControlGeneration = playbackGeneration
        pendingAutomaticControlTrigger = trigger
        return true
    }

    private func activate(
        index: Int,
        preservingShuffleOrder: Bool = false,
        preservingPlaybackQualityOverride: Bool = false
    ) {
        guard queue.indices.contains(index) else { return }
        submitPlaybackIfNeeded()
        finishCrossfade()

        if isShuffleEnabled {
            if preservingShuffleOrder, let position = shuffleOrder.firstIndex(of: index) {
                shuffleCursor = position
            } else {
                rebuildShuffleOrder(keeping: index)
            }
        }

        let item = queue[index]
        if !preservingPlaybackQualityOverride {
            selectedPlaybackLevel = nil
        }
        guard let song = item.song else {
            let generation = beginTransition(index: index, songID: item.id, crossfade: false)
            resolveAndActivate(
                songID: item.id,
                index: index,
                generation: generation,
                preservingShuffleOrder: true
            )
            return
        }
        let shouldCrossfade = crossfadeDuration > 0
            && wantsPlayback
            && activeSongID != nil
            && activeSongID != song.id
            && avPlayer.timeControlStatus == .playing
        let usesPrefetch = prefetchedSongID == song.id
        let prefetchedSource = usesPrefetch ? self.prefetchedSource : nil
        let generation = beginTransition(index: index, songID: song.id, crossfade: shouldCrossfade)

        loadTrack(
            generation: generation,
            songID: song.id,
            prefetchedSource: prefetchedSource,
            crossfade: shouldCrossfade
        )
        loadLyrics(generation: generation, songID: song.id)
        replenishHeartModeIfNeeded()
    }

    private func beginTransition(index: Int, songID: Int64, crossfade: Bool) -> Int {
        cancelStandbyHandoff()
        finishPlaybackControlFade()
        resetActiveSeek()
        playbackGeneration += 1
        let generation = playbackGeneration
        loadTask?.cancel()
        loadTask = nil
        loadTaskID = nil
        songResolutionTask?.cancel()
        songResolutionTask = nil
        songResolutionTaskID = nil
        qualitySwitchTask?.cancel()
        qualitySwitchTask = nil
        qualitySwitchRevision += 1
        prefetchTask?.cancel()
        prefetchTask = nil
        prefetchTaskID = nil
        prefetchedSongID = nil
        prefetchedSource = nil
        lyricTask?.cancel()
        lyricTask = nil
        lyricTaskID = nil
        standbyStatusObservation?.invalidate()
        standbyStatusObservation = nil
        standbyPlayer.pause()
        releaseCurrentItem(from: standbyPlayer)
        removeItemObservers()
        if !crossfade {
            avPlayer.pause()
            releaseCurrentItem(from: avPlayer)
            activeSongID = nil
        }

        currentIndex = index
        context = PlaybackContext(songIDs: queue.map(\.id), startIndex: index)
        position = 0
        mediaDuration = 0
        lyrics = []
        currentLyricIndex = nil
        isLoadingLyrics = true
        lyricErrorMessage = nil
        playbackAvailability = nil
        alternativeSongs = []
        isSwitchingPlaybackQuality = false
        playbackQualityErrorMessage = nil
        qualityBeforeSwitch = nil
        wantsPlayback = true
        prefetchTriggered = false
        crossfadeTriggered = false
        state = .preparing(songID: songID)
        return generation
    }

    private func installQueue(songIDs: [Int64], knownSongs: [Song], currentIndex: Int) {
        songResolutionTask?.cancel()
        songResolutionTask = nil
        songResolutionTaskID = nil
        cancelVisibleQueueResolution()
        let knownByID = Dictionary(knownSongs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        queue = songIDs.map { PlaybackQueueItem(id: $0, song: knownByID[$0]) }
        self.currentIndex = currentIndex
        context = PlaybackContext(songIDs: songIDs, startIndex: currentIndex)
    }

    private func installPlaybackOrder(_ order: PlayerQueueOrder, shuffleEnabled: Bool) {
        guard Self.isValidQueueOrder(order), order.displaySongIDs == queue.map(\.id) else { return }
        let indexes = Dictionary(
            uniqueKeysWithValues: order.displaySongIDs.enumerated().map { ($0.element, $0.offset) }
        )
        isShuffleEnabled = shuffleEnabled
        if shuffleEnabled {
            shuffleOrder = order.randomSongIDs.compactMap { indexes[$0] }
            shuffleCursor = currentIndex.flatMap { shuffleOrder.firstIndex(of: $0) } ?? 0
        } else {
            shuffleOrder = []
            shuffleCursor = 0
        }
        updateQueueIdentity()
        resetTransitionPreparation()
    }

    private func updateQueueIdentity() {
        let displaySongIDs = queue.map(\.id)
        guard !displaySongIDs.isEmpty else {
            queueIdentity = nil
            return
        }
        queueIdentity = PlayerQueueIdentity(
            displaySongIDs: displaySongIDs,
            randomSongIDs: randomSongIDs(for: displaySongIDs),
            sourcePlaylistID: sourcePlaylistID,
            sessionID: queueSessionID
        )
    }

    private func randomSongIDs(for displaySongIDs: [Int64]) -> [Int64] {
        guard isShuffleEnabled else { return displaySongIDs }
        var seen: Set<Int64> = []
        var values = shuffleOrder.compactMap { index -> Int64? in
            guard queue.indices.contains(index) else { return nil }
            let songID = queue[index].id
            return seen.insert(songID).inserted ? songID : nil
        }
        values.append(contentsOf: displaySongIDs.filter { seen.insert($0).inserted })
        return values
    }

    private static func shuffledSongIDs(currentSongID: Int64, displaySongIDs: [Int64]) -> [Int64] {
        guard displaySongIDs.contains(currentSongID) else { return displaySongIDs }
        return [currentSongID] + displaySongIDs.filter { $0 != currentSongID }.shuffled()
    }

    private static func isValidQueueOrder(_ order: PlayerQueueOrder) -> Bool {
        let displaySet = Set(order.displaySongIDs)
        return !order.displaySongIDs.isEmpty
            && displaySet.count == order.displaySongIDs.count
            && order.randomSongIDs.count == order.displaySongIDs.count
            && Set(order.randomSongIDs) == displaySet
            && order.displaySongIDs.allSatisfy { $0 > 0 }
            && (order.anchorSongID.map(displaySet.contains) ?? true)
    }

    private func restoreQueueMode() {
        guard let savedQueueMode else { return }
        isShuffleEnabled = savedQueueMode.shuffle
        repeatMode = savedQueueMode.repeatMode
        isLinearQueueMode = false
        self.savedQueueMode = nil
        rebuildShuffleOrder(keeping: currentIndex)
        updateQueueIdentity()
        resetTransitionPreparation()
    }

    private func stopHeartMode(restoringQueue: Bool = true) {
        let originalQueue = heartModeOriginalQueue
        let originalIndex = heartModeOriginalIndex
        let activeSongID = currentSongID
        heartModeTask?.cancel()
        heartModeTask = nil
        isHeartModeEnabled = false
        isLoadingHeartMode = false
        heartModeErrorMessage = nil
        heartModeSeedSongID = nil
        heartModeHasRecommendations = false
        heartModeExhausted = false
        heartModeOriginalQueue = nil
        heartModeOriginalIndex = nil

        if restoringQueue, let originalQueue, !originalQueue.isEmpty {
            let index = originalQueue.firstIndex { $0.id == activeSongID }
                ?? min(originalIndex ?? 0, originalQueue.count - 1)
            let shouldRestart = originalQueue[index].id != activeSongID
            queue = originalQueue
            currentIndex = index
            context = PlaybackContext(songIDs: originalQueue.map(\.id), startIndex: index)
            restoreQueueMode()
            if shouldRestart { activate(index: index) }
            return
        }
        restoreQueueMode()
    }

    private func loadHeartModeSongs(startSongID: Int64, replacingTail: Bool) {
        guard isHeartModeEnabled,
              !isLoadingHeartMode,
              let seedSongID = heartModeSeedSongID
        else { return }
        let playlistID = sourcePlaylistID
        isLoadingHeartMode = true
        heartModeTask = Task { @MainActor [weak self, repository] in
            do {
                let songs = try await repository.heartModeSongs(
                    seedSongID: seedSongID,
                    playlistID: playlistID,
                    startSongID: startSongID
                )
                try Task.checkCancellation()
                guard let self,
                      self.isHeartModeEnabled,
                      self.heartModeSeedSongID == seedSongID,
                      self.sourcePlaylistID == playlistID
                else { return }
                self.heartModeTask = nil
                self.isLoadingHeartMode = false
                let added = self.installHeartModeSongs(songs, replacingTail: replacingTail)
                if !added, replacingTail {
                    self.failHeartMode("暂无相似推荐")
                } else if !added {
                    self.heartModeExhausted = true
                }
            } catch is CancellationError {
            } catch {
                guard let self,
                      self.isHeartModeEnabled,
                      self.heartModeSeedSongID == seedSongID,
                      self.sourcePlaylistID == playlistID
                else { return }
                self.failHeartMode(error.localizedDescription)
            }
        }
    }

    private func installHeartModeSongs(_ songs: [Song], replacingTail: Bool) -> Bool {
        guard let currentIndex, queue.indices.contains(currentIndex) else { return false }
        let retained = replacingTail ? Array(queue.prefix(currentIndex + 1)) : queue
        var ids = Set(retained.map(\.id))
        let additions = songs.filter { ids.insert($0.id).inserted }
        guard !additions.isEmpty else { return false }
        queue = retained + additions.map { PlaybackQueueItem(id: $0.id, song: $0) }
        context = PlaybackContext(songIDs: queue.map(\.id), startIndex: currentIndex)
        updateQueueIdentity()
        heartModeHasRecommendations = true
        resetTransitionPreparation()
        return true
    }

    private func replenishHeartModeIfNeeded() {
        guard isHeartModeEnabled,
              heartModeHasRecommendations,
              !isLoadingHeartMode,
              !heartModeExhausted,
              let currentIndex,
              queue.count - currentIndex <= Self.heartModeReplenishThreshold,
              let lastSongID = queue.last?.id
        else { return }
        loadHeartModeSongs(startSongID: lastSongID, replacingTail: false)
    }

    private func failHeartMode(_ message: String) {
        stopHeartMode()
        heartModeErrorMessage = message
    }

    private func mergeKnownSongs(_ songs: [Song]) {
        let songsByID = Dictionary(songs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for index in queue.indices where queue[index].song == nil {
            guard let song = songsByID[queue[index].id] else { continue }
            queue[index].song = song
        }
    }

    private func startVisibleQueueResolutionIfNeeded() {
        guard visibleQueueResolutionTask == nil,
              let songID = pendingVisibleQueueSongID
        else { return }
        pendingVisibleQueueSongID = nil
        guard let index = queue.firstIndex(where: { $0.id == songID }),
              queue[index].song == nil
        else { return }

        let limit = Self.maximumVisibleQueueResolutionCount
        let lowerBound = min(max(0, index - limit / 2), max(0, queue.count - limit))
        let upperBound = min(queue.count, lowerBound + limit)
        let ids = queue[lowerBound..<upperBound].compactMap { item in
            item.song == nil ? item.id : nil
        }
        guard !ids.isEmpty else { return }

        let taskID = UUID()
        visibleQueueResolutionTaskID = taskID
        visibleQueueResolutionIDs = Set(ids)
        visibleQueueResolutionTask = Task { @MainActor [weak self, repository] in
            defer {
                if let self, self.visibleQueueResolutionTaskID == taskID {
                    self.visibleQueueResolutionTask = nil
                    self.visibleQueueResolutionTaskID = nil
                    self.visibleQueueResolutionIDs = []
                    self.startVisibleQueueResolutionIfNeeded()
                }
            }
            do {
                let songs = try await Self.fetchQueueSongs(ids, repository: repository)
                try Task.checkCancellation()
                guard let self, self.visibleQueueResolutionTaskID == taskID else { return }
                self.mergeKnownSongs(songs)
            } catch {}
        }
    }

    private func cancelVisibleQueueResolution() {
        visibleQueueResolutionTask?.cancel()
        visibleQueueResolutionTask = nil
        visibleQueueResolutionTaskID = nil
        visibleQueueResolutionIDs = []
        pendingVisibleQueueSongID = nil
    }

    private static func fetchQueueSongs(
        _ ids: [Int64],
        repository: any MusicRepository
    ) async throws -> [Song] {
        try await repository.songs(ids: Array(ids.prefix(maximumVisibleQueueResolutionCount)))
    }

    private func resolveAndActivate(
        songID: Int64,
        index: Int,
        generation: Int,
        preservingShuffleOrder: Bool
    ) {
        songResolutionTask?.cancel()
        let taskID = UUID()
        songResolutionTaskID = taskID
        songResolutionTask = Task { @MainActor [weak self, repository] in
            var settled = false
            defer {
                if let self, self.songResolutionTaskID == taskID {
                    self.songResolutionTask = nil
                    self.songResolutionTaskID = nil
                    if !settled,
                       self.playbackGeneration == generation,
                       self.currentSongID == songID,
                       case .preparing = self.state {
                        self.wantsPlayback = false
                        self.isLoadingLyrics = false
                        self.state = .failed(songID: songID, message: "歌曲信息加载已取消")
                    }
                }
            }
            do {
                guard let song = try await Self.fetchQueueSongs([songID], repository: repository).first else {
                    throw AppError.unavailable("无法加载歌曲信息")
                }
                try Task.checkCancellation()
                guard let self,
                      self.playbackGeneration == generation,
                      self.currentIndex == index,
                      self.queue.indices.contains(index),
                      self.queue[index].id == songID
                else {
                    settled = true
                    return
                }
                let shouldPlay = self.wantsPlayback
                self.queue[index].song = song
                self.songResolutionTask = nil
                self.songResolutionTaskID = nil
                settled = true
                self.activate(index: index, preservingShuffleOrder: preservingShuffleOrder)
                if !shouldPlay { self.pauseLocally() }
            } catch is CancellationError {
            } catch {
                guard let self,
                      self.playbackGeneration == generation,
                      self.currentIndex == index,
                      self.queue.indices.contains(index),
                      self.queue[index].id == songID
                else {
                    settled = true
                    return
                }
                settled = true
                self.wantsPlayback = false
                self.isLoadingLyrics = false
                self.state = .failed(songID: songID, message: error.localizedDescription)
            }
        }
    }

    private func pauseLocally() {
        guard let songID = currentSongID else { return }
        let retargetsStandbyHandoff = isSwitchingPlaybackQuality
            && standbyHandoffTask != nil
            && standbyPlayer.currentItem != nil
        if retargetsStandbyHandoff {
            invalidateStandbyPreparation()
        } else {
            cancelStandbyHandoff()
        }
        wantsPlayback = false
        stopPlaybackTiming()
        if retargetsStandbyHandoff {
            avPlayer.pause()
            standbyPlayer.pause()
            finishPlaybackControlFade()
            state = .paused(songID: songID)
            resumeStandbyPreparationAfterActiveSeek()
            return
        }
        if fadeProgress != nil { finishCrossfade() }
        state = .paused(songID: songID)
        guard playbackControlFadeEnabled,
              crossfadeDuration > 0,
              avPlayer.currentItem != nil,
              avPlayer.timeControlStatus != .paused
        else {
            finishPlaybackControlFade()
            return
        }
        startPlaybackControlFade(to: 0)
    }

    private func resumeLocally() {
        guard let songID = currentSongID else { return }
        guard let song = currentSong else {
            finishPlaybackControlFade()
            wantsPlayback = true
            state = .preparing(songID: songID)
            if songResolutionTask == nil, let currentIndex {
                let generation = beginTransition(index: currentIndex, songID: songID, crossfade: false)
                resolveAndActivate(
                    songID: songID,
                    index: currentIndex,
                    generation: generation,
                    preservingShuffleOrder: true
                )
            }
            return
        }
        if case .failed = state {
            finishPlaybackControlFade()
            retryPlaybackLocally(index: currentIndex ?? 0)
            return
        }
        let shouldFadeIn = playbackControlFadeEnabled
            && crossfadeDuration > 0
            && state == .paused(songID: songID)
        let wasPlaying = avPlayer.timeControlStatus == .playing
        wantsPlayback = true
        if shouldFadeIn {
            playbackFadeTask?.cancel()
            playbackFadeTask = nil
            if !wasPlaying {
                playbackFadeGain = 0
                applyVolume()
            }
            pendingPlaybackFadeIn = true
        } else {
            finishPlaybackControlFade()
        }
        if activeRangeFallback != nil {
            state = .preparing(songID: song.id)
            return
        }
        if isSwitchingPlaybackQuality, standbyPlayer.currentItem?.status == .readyToPlay {
            state = .preparing(songID: song.id)
            avPlayer.play()
            return
        }
        if activeSongID != song.id {
            avPlayer.play()
            state = .preparing(songID: song.id)
        } else if avPlayer.currentItem != nil {
            if duration > 0, position >= duration - 0.1 {
                seekLocally(to: 0)
            }
            state = .preparing(songID: song.id)
            avPlayer.play()
            if wasPlaying {
                updatePlaybackState(rawValue: AVPlayer.TimeControlStatus.playing.rawValue)
            }
        } else if loadTask != nil {
            state = .preparing(songID: song.id)
        } else {
            activate(index: currentIndex ?? 0)
        }
    }

    private func loadTrack(
        generation: Int,
        songID: Int64,
        prefetchedSource: PlaybackSource? = nil,
        crossfade: Bool = false
    ) {
        let quality = playbackQuality
        let selectedLevel = selectedPlaybackLevel
        let expectedLevel = selectedLevel ?? (quality == .best ? nil : quality.cacheComponent)
        let cacheGeneration = cacheGeneration
        let cache = cache
        let rangeCache = rangeCache
        let taskID = UUID()
        loadTaskID = taskID
        loadTask = Task { @MainActor [weak self] in
            var settled = false
            var routed: RoutedPlayback?
            defer {
                if let self, self.loadTaskID == taskID {
                    self.loadTask = nil
                    self.loadTaskID = nil
                    if !settled,
                       self.isCurrent(generation: generation, songID: songID),
                       case .preparing = self.state {
                        self.wantsPlayback = false
                        self.isLoadingLyrics = false
                        self.state = .failed(songID: songID, message: "播放加载已取消")
                    }
                }
            }
            do {
                guard let self else { throw CancellationError() }
                let result = try await self.routedPlayback(
                    songID: songID,
                    exactLevel: expectedLevel,
                    quality: expectedLevel == nil ? quality : nil,
                    prefetchedSource: prefetchedSource,
                    cache: cache,
                    rangeCache: rangeCache,
                    isValid: { [weak self] in
                        guard let self else { return false }
                        return self.loadTaskID == taskID
                            && self.cacheGeneration == cacheGeneration
                            && self.isCurrent(generation: generation, songID: songID)
                    }
                )
                routed = result
                guard self.loadTaskID == taskID,
                      self.cacheGeneration == cacheGeneration,
                      self.isCurrent(generation: generation, songID: songID)
                else {
                    (result.item as? RangeCachingPlayerItem)?.cancelRangeLoading()
                    if let pinnedURL = result.pinnedURL { await cache.unpin(pinnedURL) }
                    settled = true
                    return
                }
                if let pinnedURL = result.pinnedURL {
                    self.registerPinned(pinnedURL, cache: cache)
                    routed = nil
                }
                self.playbackAvailability = result.availability
                self.prepare(
                    result.item,
                    generation: generation,
                    songID: songID,
                    crossfade: crossfade
                )
                settled = true
            } catch is CancellationError {
                if let pinnedURL = routed?.pinnedURL { await cache.unpin(pinnedURL) }
            } catch let error as PlaybackUnavailableError {
                if let pinnedURL = routed?.pinnedURL { await cache.unpin(pinnedURL) }
                guard !Task.isCancelled,
                      let self,
                      self.isCurrent(generation: generation, songID: songID)
                else {
                    settled = true
                    return
                }
                settled = true
                self.failUnavailable(generation: generation, songID: songID, error: error)
            } catch {
                if let pinnedURL = routed?.pinnedURL { await cache.unpin(pinnedURL) }
                guard let self, self.isCurrent(generation: generation, songID: songID) else {
                    settled = true
                    return
                }
                settled = true
                self.failAndAdvance(
                    generation: generation,
                    songID: songID,
                    message: error.localizedDescription
                )
            }
        }
    }

    private func routedPlayback(
        songID: Int64,
        exactLevel: String?,
        quality: AudioQuality?,
        prefetchedSource: PlaybackSource?,
        cache: TrackCache,
        rangeCache: TrackRangeCache,
        isValid: @escaping @MainActor () -> Bool
    ) async throws -> RoutedPlayback {
        if let exactLevel {
            guard SongQualityDetail.orderedLevels.contains(exactLevel) else {
                throw TrackRangeCacheError.invalidSource
            }
            if let ready = await cache.readyPinnedFile(for: songID, quality: exactLevel) {
                guard isValid() else {
                    await cache.unpin(ready)
                    throw CancellationError()
                }
                return RoutedPlayback(
                    item: Self.makePlayerItem(for: ready, format: ready.pathExtension),
                    availability: .playable(level: exactLevel),
                    pinnedURL: ready
                )
            }
            guard isValid() else { throw CancellationError() }
            let key = TrackRangeCacheKey(songID: songID, quality: exactLevel)
            if let descriptor = await rangeCache.descriptor(for: key) {
                guard isValid() else { throw CancellationError() }
                return RoutedPlayback(
                    item: makeRangePlayerItem(
                        key: key,
                        format: descriptor.format,
                        initialSource: nil,
                        rangeCache: rangeCache
                    ),
                    availability: .playable(level: exactLevel),
                    pinnedURL: nil
                )
            }
            guard isValid() else { throw CancellationError() }
        }

        let source: PlaybackSource
        if let prefetchedSource,
           !prefetchedSource.url.isFileURL || !cache.manages(prefetchedSource.url) {
            source = prefetchedSource
        } else if let exactLevel {
            source = try await repository.playbackSource(for: songID, level: exactLevel)
            guard isValid() else { throw CancellationError() }
        } else if let quality {
            source = try await repository.playbackSource(for: songID, quality: quality)
            guard isValid() else { throw CancellationError() }
        } else {
            throw TrackRangeCacheError.invalidSource
        }

        let actualLevel: String
        switch source.availability {
        case let .playable(level), let .trial(level, _):
            actualLevel = level
        case let .unavailable(reason):
            throw PlaybackUnavailableError(reason: reason, alternatives: [])
        }
        guard SongQualityDetail.orderedLevels.contains(actualLevel) else {
            throw TrackRangeCacheError.sourceLevelMismatch(expected: exactLevel ?? "best", actual: actualLevel)
        }
        if let exactLevel, actualLevel != exactLevel {
            throw TrackRangeCacheError.sourceLevelMismatch(expected: exactLevel, actual: actualLevel)
        }

        if case .playable = source.availability {
            if let ready = await cache.readyPinnedFile(for: songID, quality: actualLevel) {
                guard isValid() else {
                    await cache.unpin(ready)
                    throw CancellationError()
                }
                return RoutedPlayback(
                    item: Self.makePlayerItem(for: ready, format: ready.pathExtension),
                    availability: source.availability,
                    pinnedURL: ready
                )
            }
            guard isValid() else { throw CancellationError() }
            let key = TrackRangeCacheKey(songID: songID, quality: actualLevel)
            if let descriptor = await rangeCache.descriptor(for: key) {
                guard isValid() else { throw CancellationError() }
                return RoutedPlayback(
                    item: makeRangePlayerItem(
                        key: key,
                        format: descriptor.format,
                        initialSource: nil,
                        rangeCache: rangeCache
                    ),
                    availability: source.availability,
                    pinnedURL: nil
                )
            }
            guard isValid() else { throw CancellationError() }
        }

        if source.url.isFileURL {
            var pinnedURL: URL?
            if cache.manages(source.url) {
                guard await cache.pin(source.url) else { throw URLError(.fileDoesNotExist) }
                pinnedURL = source.url
                guard isValid() else {
                    await cache.unpin(source.url)
                    throw CancellationError()
                }
            }
            return RoutedPlayback(
                item: Self.makePlayerItem(for: source.url, format: source.format),
                availability: source.availability,
                pinnedURL: pinnedURL
            )
        }

        if case let .playable(level) = source.availability,
           let format = Self.rangeFormat(for: source) {
            let key = TrackRangeCacheKey(songID: songID, quality: level)
            return RoutedPlayback(
                item: makeRangePlayerItem(
                    key: key,
                    format: format,
                    initialSource: source,
                    rangeCache: rangeCache
                ),
                availability: source.availability,
                pinnedURL: nil
            )
        }
        return RoutedPlayback(
            item: Self.makePlayerItem(for: source.url, format: source.format),
            availability: source.availability,
            pinnedURL: nil
        )
    }

    private func makeRangePlayerItem(
        key: TrackRangeCacheKey,
        format: String,
        initialSource: PlaybackSource?,
        rangeCache: TrackRangeCache
    ) -> RangeCachingPlayerItem {
        let repository = repository
        return RangeCachingPlayerItem(
            key: key,
            format: format,
            initialSource: initialSource,
            sourceProvider: {
                try await repository.playbackSource(for: key.songID, level: key.quality)
            },
            rangeCache: rangeCache,
            preferPreciseTiming: format == "flac"
        )
    }

    private static func rangeFormat(for source: PlaybackSource) -> String? {
        guard case .playable = source.availability,
              let scheme = source.url.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else { return nil }
        let supported = Set(["mp3", "flac", "ogg", "wav", "m4a"])
        if let format = source.format?.lowercased(), supported.contains(format) { return format }
        let pathExtension = source.url.pathExtension.lowercased()
        return supported.contains(pathExtension) ? pathExtension : nil
    }

    private static func makeCache(root: URL?) -> TrackCache {
        let root = root ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: "TinyCloudMusic", directoryHint: .isDirectory)
        return TrackCache.shared(directory: root.appending(path: "StreamCache", directoryHint: .isDirectory))
    }

    private func registerPinned(_ url: URL, cache: TrackCache) {
        let path = url.standardizedFileURL.path
        if var reference = pinnedCaches[path] {
            reference.count += 1
            pinnedCaches[path] = reference
        } else {
            pinnedCaches[path] = PinnedCacheReference(cache: cache, count: 1)
        }
    }

    private func cancelStandbyHandoff() {
        standbyHandoffTask?.cancel()
        standbyHandoffTask = nil
        standbyPlayer.pause()
    }

    private func invalidateStandbyPreparation() {
        standbyPreparationRevision &+= 1
        cancelStandbyHandoff()
        standbyPlayer.cancelPendingPrerolls()
        standbyPlayer.currentItem?.cancelPendingSeeks()
    }

    private func releaseCurrentItem(
        from player: AVPlayer,
        preservingPendingSeek: Bool = false
    ) {
        if player === standbyPlayer {
            invalidateStandbyPreparation()
        } else {
            cancelStandbyHandoff()
        }
        guard let item = player.currentItem else { return }
        if player === avPlayer {
            resetActiveSeek(preservingPendingPosition: preservingPendingSeek)
            if activeRangeFallback?.itemID == ObjectIdentifier(item) {
                activeRangeFallback = nil
            }
        }
        let itemID = ObjectIdentifier(item)
        rangeFallbackTasks.removeValue(forKey: itemID)?.cancel()
        rangeFallbackAttempts.remove(itemID)
        (item as? RangeCachingPlayerItem)?.cancelRangeLoading()
        let sourceURL = (item.asset as? AVURLAsset)?.url
        player.replaceCurrentItem(with: nil)
        guard let sourceURL, sourceURL.isFileURL else { return }
        let path = sourceURL.standardizedFileURL.path
        guard var reference = pinnedCaches[path] else { return }
        if reference.count > 1 {
            reference.count -= 1
            pinnedCaches[path] = reference
        } else {
            pinnedCaches[path] = nil
        }
        Task { await reference.cache.unpin(sourceURL) }
    }

    private static func makePlayerItem(for sourceURL: URL, format: String? = nil) -> AVPlayerItem {
        let asset = AVURLAsset(url: sourceURL, options: [
            AVURLAssetPreferPreciseDurationAndTimingKey: sourceURL.pathExtension.lowercased() == "flac"
                || format?.lowercased() == "flac"
        ])
        return AVPlayerItem(asset: asset)
    }

    private static func validatedDirectFallback(
        _ source: PlaybackSource,
        key: TrackRangeCacheKey
    ) throws -> PlaybackSource {
        guard case let .playable(level) = source.availability,
              level == key.quality,
              let scheme = source.url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = source.url.host,
              !host.isEmpty,
              source.url.user == nil,
              source.url.password == nil
        else {
            throw TrackRangeCacheError.sourceLevelMismatch(
                expected: key.quality,
                actual: source.availability.level
            )
        }
        return source
    }

    private func handleActiveItemFailure(
        _ item: AVPlayerItem,
        generation: Int,
        songID: Int64,
        message: String
    ) {
        guard isCurrent(generation: generation, songID: songID),
              avPlayer.currentItem === item
        else { return }
        if let item = item as? RangeCachingPlayerItem {
            startActiveRangeFallback(item, generation: generation, songID: songID)
            return
        }
        if case .failed = state { return }
        activeRangeFallback = nil
        failAndAdvance(generation: generation, songID: songID, message: message)
    }

    private func startActiveRangeFallback(
        _ failedItem: RangeCachingPlayerItem,
        generation: Int,
        songID: Int64
    ) {
        let failedItemID = ObjectIdentifier(failedItem)
        guard rangeFallbackAttempts.insert(failedItemID).inserted else { return }
        if isSwitchingPlaybackQuality { cancelPendingQualitySwitch() }
        let qualityRevision = qualitySwitchRevision
        let currentTime = avPlayer.currentTime().seconds
        let confirmedPosition = currentTime.isFinite && currentTime >= 0 ? currentTime : position
        let initialWantsPlayback = wantsPlayback
        let cache = failedItem.rangeCache.trackCache
        let key = failedItem.key
        avPlayer.pause()
        avPlayer.volume = 0

        let task = Task { @MainActor [weak self, repository] in
            defer { self?.rangeFallbackTasks[failedItemID] = nil }
            var pinnedURL: URL?
            do {
                let directItem: AVPlayerItem
                if let ready = await cache.readyPinnedFile(for: key.songID, quality: key.quality) {
                    pinnedURL = ready
                    guard let self,
                          self.isCurrentActiveRangeFallback(
                              failedItem,
                              generation: generation,
                              songID: songID,
                              qualityRevision: qualityRevision
                          )
                    else {
                        await cache.unpin(ready)
                        return
                    }
                    directItem = Self.makePlayerItem(for: ready, format: ready.pathExtension)
                } else {
                    guard let self,
                          self.isCurrentActiveRangeFallback(
                              failedItem,
                              generation: generation,
                              songID: songID,
                              qualityRevision: qualityRevision
                          )
                    else { return }
                    let resolvedSource = try await repository.playbackSource(
                        for: key.songID,
                        level: key.quality
                    )
                    guard self.isCurrentActiveRangeFallback(
                        failedItem,
                        generation: generation,
                        songID: songID,
                        qualityRevision: qualityRevision
                    ) else { return }
                    let source = try Self.validatedDirectFallback(resolvedSource, key: key)
                    directItem = Self.makePlayerItem(for: source.url, format: source.format)
                }

                guard let self,
                      self.isCurrentActiveRangeFallback(
                          failedItem,
                          generation: generation,
                          songID: songID,
                          qualityRevision: qualityRevision
                      )
                else {
                    if let pinnedURL { await cache.unpin(pinnedURL) }
                    return
                }
                self.rangeFallbackTasks[failedItemID] = nil
                if let pinnedURL { self.registerPinned(pinnedURL, cache: cache) }
                self.installActiveRangeFallback(
                    directItem,
                    generation: generation,
                    songID: songID,
                    position: confirmedPosition,
                    initialWantsPlayback: initialWantsPlayback
                )
            } catch is CancellationError {
                if let pinnedURL { await cache.unpin(pinnedURL) }
            } catch {
                if let pinnedURL { await cache.unpin(pinnedURL) }
                guard let self,
                      self.isCurrentActiveRangeFallback(
                          failedItem,
                          generation: generation,
                          songID: songID,
                          qualityRevision: qualityRevision
                      )
                else { return }
                self.rangeFallbackTasks[failedItemID] = nil
                self.failAndAdvance(
                    generation: generation,
                    songID: songID,
                    message: error.localizedDescription
                )
            }
        }
        rangeFallbackTasks[failedItemID] = task
    }

    private func isCurrentActiveRangeFallback(
        _ item: RangeCachingPlayerItem,
        generation: Int,
        songID: Int64,
        qualityRevision: Int
    ) -> Bool {
        !Task.isCancelled
            && isCurrent(generation: generation, songID: songID)
            && self.qualitySwitchRevision == qualityRevision
            && avPlayer.currentItem === item
    }

    private func installActiveRangeFallback(
        _ item: AVPlayerItem,
        generation: Int,
        songID: Int64,
        position: TimeInterval,
        initialWantsPlayback: Bool
    ) {
        removeItemObservers()
        releaseCurrentItem(from: avPlayer, preservingPendingSeek: true)
        avPlayer.pause()
        avPlayer.volume = 0
        avPlayer.replaceCurrentItem(with: item)
        activeRangeFallback = ActiveRangeFallback(
            itemID: ObjectIdentifier(item),
            generation: generation,
            songID: songID,
            position: position,
            initialWantsPlayback: initialWantsPlayback
        )
        installItemObservers(item, generation: generation, songID: songID)
        state = .preparing(songID: songID)
    }

    private func startStandbyRangeFallback(
        _ failedItem: RangeCachingPlayerItem,
        generation: Int,
        songID: Int64,
        qualityRevision: Int?
    ) {
        let failedItemID = ObjectIdentifier(failedItem)
        guard rangeFallbackAttempts.insert(failedItemID).inserted else { return }
        let cache = failedItem.rangeCache.trackCache
        let key = failedItem.key
        let seekPosition = standbySeekPosition
        let transitionDuration = standbyTransitionDuration
        let availability = standbyPlaybackAvailability
        standbyPlayer.pause()
        standbyPlayer.volume = 0

        let task = Task { @MainActor [weak self, repository] in
            defer { self?.rangeFallbackTasks[failedItemID] = nil }
            var pinnedURL: URL?
            do {
                let directItem: AVPlayerItem
                if let ready = await cache.readyPinnedFile(for: key.songID, quality: key.quality) {
                    pinnedURL = ready
                    guard let self,
                          self.isCurrentStandbyRangeFallback(
                              failedItem,
                              generation: generation,
                              songID: songID,
                              qualityRevision: qualityRevision
                          )
                    else {
                        await cache.unpin(ready)
                        return
                    }
                    directItem = Self.makePlayerItem(for: ready, format: ready.pathExtension)
                } else {
                    guard let self,
                          self.isCurrentStandbyRangeFallback(
                              failedItem,
                              generation: generation,
                              songID: songID,
                              qualityRevision: qualityRevision
                          )
                    else { return }
                    let resolvedSource = try await repository.playbackSource(
                        for: key.songID,
                        level: key.quality
                    )
                    guard self.isCurrentStandbyRangeFallback(
                        failedItem,
                        generation: generation,
                        songID: songID,
                        qualityRevision: qualityRevision
                    ) else { return }
                    let source = try Self.validatedDirectFallback(resolvedSource, key: key)
                    directItem = Self.makePlayerItem(for: source.url, format: source.format)
                }

                guard let self,
                      self.isCurrentStandbyRangeFallback(
                          failedItem,
                          generation: generation,
                          songID: songID,
                          qualityRevision: qualityRevision
                      )
                else {
                    if let pinnedURL { await cache.unpin(pinnedURL) }
                    return
                }
                self.rangeFallbackTasks[failedItemID] = nil
                if let pinnedURL { self.registerPinned(pinnedURL, cache: cache) }
                self.prepareCrossfade(
                    directItem,
                    generation: generation,
                    songID: songID,
                    seekPosition: self.standbySeekPosition ?? seekPosition,
                    transitionDuration: transitionDuration,
                    playbackAvailability: availability,
                    qualityRevision: qualityRevision
                )
            } catch is CancellationError {
                if let pinnedURL { await cache.unpin(pinnedURL) }
            } catch {
                if let pinnedURL { await cache.unpin(pinnedURL) }
                guard let self,
                      self.isCurrentStandbyRangeFallback(
                          failedItem,
                          generation: generation,
                          songID: songID,
                          qualityRevision: qualityRevision
                      )
                else { return }
                self.rangeFallbackTasks[failedItemID] = nil
                self.releaseCurrentItem(from: self.standbyPlayer)
                if transitionDuration != nil {
                    self.failQualitySwitch(error.localizedDescription)
                } else {
                    self.failAndAdvance(
                        generation: generation,
                        songID: songID,
                        message: error.localizedDescription
                    )
                }
            }
        }
        rangeFallbackTasks[failedItemID] = task
    }

    private func isCurrentStandbyRangeFallback(
        _ item: RangeCachingPlayerItem,
        generation: Int,
        songID: Int64,
        qualityRevision: Int?
    ) -> Bool {
        !Task.isCancelled
            && isCurrent(generation: generation, songID: songID)
            && (qualityRevision == nil || qualityRevision == self.qualitySwitchRevision)
            && standbyPlayer.currentItem === item
    }

    private func prepare(
        _ item: AVPlayerItem,
        generation: Int,
        songID: Int64,
        crossfade: Bool
    ) {
        guard isCurrent(generation: generation, songID: songID) else { return }
        if crossfade, avPlayer.currentItem != nil, avPlayer.timeControlStatus == .playing {
            prepareCrossfade(item, generation: generation, songID: songID)
            return
        }

        activeSongID = songID
        installItemObservers(item, generation: generation, songID: songID)
        state = .preparing(songID: songID)
        releaseCurrentItem(from: avPlayer)
        avPlayer.replaceCurrentItem(with: item)
        applyVolume()
        if wantsPlayback { avPlayer.play() }
    }

    private func prepareCrossfade(
        _ item: AVPlayerItem,
        generation: Int,
        songID: Int64,
        seekPosition: TimeInterval? = nil,
        transitionDuration: TimeInterval? = nil,
        playbackAvailability: PlaybackAvailability? = nil,
        qualityRevision: Int? = nil
    ) {
        cancelStandbyHandoff()
        standbyStatusObservation?.invalidate()
        standbyStatusObservation = nil
        releaseCurrentItem(from: standbyPlayer)
        standbyPreparationRevision &+= 1
        standbySeekPosition = seekPosition
        standbyTransitionDuration = transitionDuration
        standbyPlaybackAvailability = playbackAvailability
        standbyPlayer.volume = 0
        standbyPlayer.replaceCurrentItem(with: item)
        standbyStatusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            let rawValue = item.status.rawValue
            Task { @MainActor [weak self] in
                self?.updateStandbyStatus(
                    rawValue: rawValue,
                    item: item,
                    generation: generation,
                    songID: songID,
                    qualityRevision: qualityRevision
                )
            }
        }
    }

    private func startStandbyPreparation(
        _ item: AVPlayerItem,
        generation: Int,
        songID: Int64,
        qualityRevision: Int?,
        preparationRevision: Int,
        seekPosition: TimeInterval?
    ) {
        guard isCurrent(generation: generation, songID: songID),
              qualityRevision == nil || qualityRevision == self.qualitySwitchRevision,
              preparationRevision == standbyPreparationRevision,
              standbyPlayer.currentItem === item,
              item.status == .readyToPlay
        else { return }
        guard let seekPosition else {
            beginStandbyPreroll(
                item,
                generation: generation,
                songID: songID,
                qualityRevision: qualityRevision,
                preparationRevision: preparationRevision
            )
            return
        }

        standbySeekPosition = seekPosition
        let tolerance = seekTolerance(for: seekPosition)
        standbyPlayer.seek(
            to: CMTime(seconds: seekPosition, preferredTimescale: 600),
            toleranceBefore: tolerance.before,
            toleranceAfter: tolerance.after
        ) { [weak self] finished in
            Task { @MainActor [weak self] in
                guard let self,
                      self.isCurrent(generation: generation, songID: songID),
                      qualityRevision == nil || qualityRevision == self.qualitySwitchRevision,
                      preparationRevision == self.standbyPreparationRevision,
                      self.standbyPlayer.currentItem === item
                else { return }
                if finished {
                    self.beginStandbyPreroll(
                        item,
                        generation: generation,
                        songID: songID,
                        qualityRevision: qualityRevision,
                        preparationRevision: preparationRevision
                    )
                } else if let item = item as? RangeCachingPlayerItem {
                    self.startStandbyRangeFallback(
                        item,
                        generation: generation,
                        songID: songID,
                        qualityRevision: qualityRevision
                    )
                } else {
                    self.failQualitySwitch("无法定位新的音频流")
                }
            }
        }
    }

    private func updateStandbyStatus(
        rawValue: Int,
        item: AVPlayerItem,
        generation: Int,
        songID: Int64,
        qualityRevision: Int?
    ) {
        guard isCurrent(generation: generation, songID: songID),
              qualityRevision == nil || qualityRevision == self.qualitySwitchRevision,
              standbyPlayer.currentItem === item,
              let status = AVPlayerItem.Status(rawValue: rawValue)
        else { return }

        switch status {
        case .readyToPlay:
            standbyStatusObservation?.invalidate()
            standbyStatusObservation = nil
            if qualityRevision != nil, pendingSeekPosition != nil { return }
            let seekPosition = standbySeekPosition.map { fallbackSeekPosition in
                let currentPosition = avPlayer.currentTime().seconds
                return currentPosition.isFinite && currentPosition >= 0
                    ? currentPosition
                    : fallbackSeekPosition
            }
            startStandbyPreparation(
                item,
                generation: generation,
                songID: songID,
                qualityRevision: qualityRevision,
                preparationRevision: standbyPreparationRevision,
                seekPosition: seekPosition
            )
        case .failed:
            standbyStatusObservation?.invalidate()
            standbyStatusObservation = nil
            if let item = item as? RangeCachingPlayerItem {
                startStandbyRangeFallback(
                    item,
                    generation: generation,
                    songID: songID,
                    qualityRevision: qualityRevision
                )
                return
            }
            let message = item.error?.localizedDescription ?? "音频流预缓冲失败"
            if standbyTransitionDuration != nil {
                releaseCurrentItem(from: standbyPlayer)
                failQualitySwitch(message)
            } else if let sourceURL = (item.asset as? AVURLAsset)?.url {
                releaseCurrentItem(from: standbyPlayer)
                finishCrossfade()
                prepare(
                    Self.makePlayerItem(for: sourceURL),
                    generation: generation,
                    songID: songID,
                    crossfade: false
                )
            } else {
                releaseCurrentItem(from: standbyPlayer)
                failAndAdvance(generation: generation, songID: songID, message: message)
            }
        case .unknown:
            break
        @unknown default:
            break
        }
    }

    private func beginStandbyPreroll(
        _ item: AVPlayerItem,
        generation: Int,
        songID: Int64,
        qualityRevision: Int?,
        preparationRevision: Int
    ) {
        standbyPlayer.preroll(atRate: 1) { [weak self] ready in
            Task { @MainActor [weak self] in
                guard let self,
                      self.isCurrent(generation: generation, songID: songID),
                      qualityRevision == nil || qualityRevision == self.qualitySwitchRevision,
                      preparationRevision == self.standbyPreparationRevision,
                      self.standbyPlayer.currentItem === item
                else { return }
                if ready {
                    if let qualityRevision {
                        if self.wantsPlayback {
                            guard self.startSynchronizedStandbyPlayback(
                                item,
                                generation: generation,
                                songID: songID,
                                qualityRevision: qualityRevision,
                                preparationRevision: preparationRevision
                            ) else {
                                self.failQualitySwitch("新的音频流尚未准备好")
                                return
                            }
                        } else {
                            self.promotePausedQualitySwitch(
                                item,
                                generation: generation,
                                songID: songID,
                                qualityRevision: qualityRevision,
                                preparationRevision: preparationRevision
                            )
                        }
                    } else {
                        self.promoteStandby(
                            item,
                            generation: generation,
                            songID: songID,
                            qualityRevision: nil,
                            preparationRevision: preparationRevision
                        )
                    }
                } else {
                    let message = item.error?.localizedDescription ?? "音频流预缓冲失败"
                    if let item = item as? RangeCachingPlayerItem {
                        self.startStandbyRangeFallback(
                            item,
                            generation: generation,
                            songID: songID,
                            qualityRevision: qualityRevision
                        )
                    } else if let qualityRevision, !self.wantsPlayback, item.error == nil {
                        self.promotePausedQualitySwitch(
                            item,
                            generation: generation,
                            songID: songID,
                            qualityRevision: qualityRevision,
                            preparationRevision: preparationRevision
                        )
                    } else if self.standbyTransitionDuration != nil {
                        self.releaseCurrentItem(from: self.standbyPlayer)
                        self.failQualitySwitch(message)
                    } else if let sourceURL = (item.asset as? AVURLAsset)?.url {
                        self.releaseCurrentItem(from: self.standbyPlayer)
                        self.finishCrossfade()
                        self.prepare(
                            Self.makePlayerItem(for: sourceURL),
                            generation: generation,
                            songID: songID,
                            crossfade: false
                        )
                    } else {
                        self.releaseCurrentItem(from: self.standbyPlayer)
                        self.failAndAdvance(generation: generation, songID: songID, message: message)
                    }
                }
            }
        }
    }

    private func startSynchronizedStandbyPlayback(
        _ item: AVPlayerItem,
        generation: Int,
        songID: Int64,
        qualityRevision: Int,
        preparationRevision: Int
    ) -> Bool {
        guard wantsPlayback,
              isCurrent(generation: generation, songID: songID),
              qualityRevision == self.qualitySwitchRevision,
              preparationRevision == standbyPreparationRevision,
              let activeItem = avPlayer.currentItem,
              activeItem.status == .readyToPlay,
              standbyPlayer.status == .readyToPlay,
              standbyPlayer.currentItem === item,
              item.status == .readyToPlay
        else { return false }
        cancelStandbyHandoff()
        let hostClock = CMClockGetHostTimeClock()
        let hostTime = CMClockGetTime(hostClock)
        let lead = CMTime(
            seconds: Self.standbyHandoffLead,
            preferredTimescale: 1_000_000_000
        )
        let futureHostTime = CMTimeAdd(hostTime, lead)
        let mappedItemTime = activeItem.timebase.map {
            CMSyncConvertTime(futureHostTime, from: hostClock, to: $0)
        }
        let itemTime = if let mappedItemTime, mappedItemTime.isNumeric {
            mappedItemTime
        } else {
            CMTime(
                seconds: max(0, position + Self.standbyHandoffLead),
                preferredTimescale: 600
            )
        }
        standbyPlayer.automaticallyWaitsToMinimizeStalling = false
        standbyPlayer.volume = 0
        standbyPlayer.setRate(1, time: itemTime, atHostTime: futureHostTime)
        standbyHandoffTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(50))
            } catch {
                return
            }
            guard let self else { return }
            let samePreparation = self.isCurrent(generation: generation, songID: songID)
                && qualityRevision == self.qualitySwitchRevision
                && preparationRevision == self.standbyPreparationRevision
                && self.avPlayer.currentItem === activeItem
                && self.standbyPlayer.currentItem === item
            guard samePreparation else {
                self.cancelStandbyHandoff()
                return
            }
            guard self.wantsPlayback,
                  activeItem.status == .readyToPlay,
                  item.status == .readyToPlay,
                  self.standbyPlayer.status == .readyToPlay
            else {
                self.cancelStandbyHandoff()
                return
            }
            self.standbyHandoffTask = nil
            self.promoteStandby(
                item,
                generation: generation,
                songID: songID,
                qualityRevision: qualityRevision,
                preparationRevision: preparationRevision
            )
        }
        return true
    }

    private func promotePausedQualitySwitch(
        _ item: AVPlayerItem,
        generation: Int,
        songID: Int64,
        qualityRevision: Int,
        preparationRevision: Int
    ) {
        guard isCurrent(generation: generation, songID: songID),
              qualityRevision == self.qualitySwitchRevision,
              preparationRevision == standbyPreparationRevision,
              standbyPlayer.currentItem === item,
              !wantsPlayback
        else { return }
        cancelStandbyHandoff()
        avPlayer.pause()
        standbyPlayer.pause()
        promoteStandby(
            item,
            generation: generation,
            songID: songID,
            qualityRevision: qualityRevision,
            preparationRevision: preparationRevision
        )
    }

    private func promoteStandby(
        _ item: AVPlayerItem,
        generation: Int,
        songID: Int64,
        qualityRevision: Int?,
        preparationRevision: Int
    ) {
        guard isCurrent(generation: generation, songID: songID),
              qualityRevision == nil || qualityRevision == self.qualitySwitchRevision,
              preparationRevision == standbyPreparationRevision,
              standbyPlayer.currentItem === item
        else { return }
        let transitionDuration = standbyTransitionDuration
        let isQualitySwitch = transitionDuration != nil
        let switchedAvailability = standbyPlaybackAvailability

        resetActiveSeek()
        standbyPreparationRevision &+= 1
        removePlayerObservers()
        swap(&avPlayer, &standbyPlayer)
        activeSongID = songID
        installPlayerObservers()
        installItemObservers(item, generation: generation, songID: songID)
        position = max(0, avPlayer.currentTime().seconds)
        updateCurrentLyricIndex()
        state = .preparing(songID: songID)
        standbySeekPosition = nil
        standbyTransitionDuration = nil
        standbyPlaybackAvailability = nil
        if isQualitySwitch {
            playbackAvailability = switchedAvailability
            isSwitchingPlaybackQuality = false
            playbackQualityErrorMessage = nil
            qualityBeforeSwitch = nil
            playbackQualityConfirmationMessage = currentPlaybackLevel.map {
                "已切换为\(SongQualityDetail.displayName(for: $0))音质"
            }
        }

        guard wantsPlayback else {
            avPlayer.pause()
            standbyPlayer.pause()
            releaseCurrentItem(from: standbyPlayer)
            applyVolume()
            state = .paused(songID: songID)
            return
        }

        if isQualitySwitch {
            standbyPlayer.play()
        } else {
            avPlayer.play()
        }
        startCrossfade(generation: generation, durationOverride: transitionDuration)
        updatePlaybackState(rawValue: avPlayer.timeControlStatus.rawValue)
    }

    private func startCrossfade(generation: Int, durationOverride: TimeInterval? = nil) {
        let configuredDuration = durationOverride ?? crossfadeDuration
        let outgoingDuration = standbyPlayer.currentItem?.duration.seconds ?? 0
        let outgoingRemaining = outgoingDuration - standbyPlayer.currentTime().seconds
        let duration = outgoingRemaining.isFinite && outgoingRemaining > 0
            ? min(configuredDuration, outgoingRemaining)
            : configuredDuration
        guard duration > 0 else {
            finishCrossfade()
            return
        }

        let steps = max(Int(duration * 30), 1)
        fadeProgress = 0
        applyVolume()
        fadeTask = Task { @MainActor [weak self] in
            for step in 1...steps {
                try? await Task.sleep(for: .milliseconds(33))
                guard !Task.isCancelled,
                      let self,
                      self.playbackGeneration == generation
                else { return }
                self.fadeProgress = Double(step) / Double(steps)
                self.applyVolume()
            }
            self?.finishCrossfade()
        }
    }

    private func finishCrossfade() {
        cancelStandbyHandoff()
        fadeTask?.cancel()
        fadeTask = nil
        fadeProgress = nil
        standbyStatusObservation?.invalidate()
        standbyStatusObservation = nil
        standbyPlayer.cancelPendingPrerolls()
        standbyPlayer.currentItem?.cancelPendingSeeks()
        standbyPlayer.pause()
        releaseCurrentItem(from: standbyPlayer)
        if wantsPlayback, avPlayer.timeControlStatus != .playing { avPlayer.play() }
        standbySeekPosition = nil
        standbyTransitionDuration = nil
        standbyPlaybackAvailability = nil
        applyVolume()
    }

    func failQualitySwitch(_ message: String) {
        cancelStandbyHandoff()
        finishCrossfade()
        selectedPlaybackLevel = qualityBeforeSwitch
        qualityBeforeSwitch = nil
        isSwitchingPlaybackQuality = false
        playbackQualityErrorMessage = message
        if wantsPlayback { avPlayer.play() }
    }

    private func cancelPendingQualitySwitch(restoringSelection: Bool = true) {
        guard isSwitchingPlaybackQuality else { return }
        cancelStandbyHandoff()
        qualitySwitchTask?.cancel()
        qualitySwitchTask = nil
        qualitySwitchRevision += 1
        finishCrossfade()
        if restoringSelection { selectedPlaybackLevel = qualityBeforeSwitch }
        qualityBeforeSwitch = nil
        isSwitchingPlaybackQuality = false
    }

    private func applyVolume() {
        let level = min(max(volume, 0), 1) * playbackFadeGain
        if let fallback = activeRangeFallback,
           avPlayer.currentItem.map({ ObjectIdentifier($0) }) == fallback.itemID {
            avPlayer.volume = 0
            standbyPlayer.volume = 0
            return
        }
        guard let fadeProgress else {
            avPlayer.volume = Float(level)
            standbyPlayer.volume = 0
            return
        }

        let gains = CrossfadeTransition.gains(progress: fadeProgress)
        avPlayer.volume = Float(level * gains.incoming)
        standbyPlayer.volume = Float(level * gains.outgoing)
    }

    private func startPlaybackControlFade(to targetGain: Double) {
        playbackFadeTask?.cancel()
        playbackFadeTask = nil
        pendingPlaybackFadeIn = false
        let targetGain = min(max(targetGain, 0), 1)
        let startGain = playbackFadeGain
        let duration = crossfadeDuration * abs(targetGain - startGain)
        guard duration > 0 else {
            playbackFadeGain = targetGain
            applyVolume()
            if targetGain == 0, !wantsPlayback {
                avPlayer.pause()
                standbyPlayer.pause()
                syncPositionFromActivePlayer()
            }
            return
        }

        let generation = playbackGeneration
        let steps = max(Int(duration * 30), 1)
        playbackFadeTask = Task { @MainActor [weak self] in
            for step in 1...steps {
                try? await Task.sleep(for: .milliseconds(33))
                guard !Task.isCancelled,
                      let self,
                      self.playbackGeneration == generation,
                      self.wantsPlayback == (targetGain > 0)
                else { return }
                let progress = Double(step) / Double(steps)
                self.playbackFadeGain = startGain + ((targetGain - startGain) * progress)
                self.applyVolume()
            }
            guard let self else { return }
            self.playbackFadeTask = nil
            if targetGain == 0, !self.wantsPlayback {
                self.avPlayer.pause()
                self.standbyPlayer.pause()
                self.syncPositionFromActivePlayer()
            }
        }
    }

    private func finishPlaybackControlFade() {
        playbackFadeTask?.cancel()
        playbackFadeTask = nil
        pendingPlaybackFadeIn = false
        playbackFadeGain = 1
        if !wantsPlayback {
            avPlayer.pause()
            standbyPlayer.pause()
            syncPositionFromActivePlayer()
        }
        applyVolume()
    }

    private func syncPositionFromActivePlayer() {
        guard activeRangeFallback == nil else { return }
        let seconds = avPlayer.currentTime().seconds
        guard seconds.isFinite,
              seconds >= 0,
              avPlayer.currentItem != nil,
              activeSongID == currentSong?.id
        else { return }
        position = seconds
        updateCurrentLyricIndex()
    }

    private func loadLyrics(generation: Int, songID: Int64) {
        let taskID = UUID()
        lyricTaskID = taskID
        lyricTask = Task { @MainActor [weak self, repository] in
            defer {
                if let self, self.lyricTaskID == taskID {
                    self.lyricTask = nil
                    self.lyricTaskID = nil
                    if self.isCurrent(generation: generation, songID: songID) {
                        self.isLoadingLyrics = false
                    }
                }
            }
            do {
                let source = try await repository.lyrics(for: songID)
                try Task.checkCancellation()
                guard let self, self.isCurrent(generation: generation, songID: songID) else { return }
                self.lyrics = LRCParser.parse(source)
                self.isLoadingLyrics = false
                self.lyricErrorMessage = nil
                self.updateCurrentLyricIndex()
            } catch is CancellationError {
            } catch {
                guard let self, self.isCurrent(generation: generation, songID: songID) else { return }
                self.lyrics = []
                self.currentLyricIndex = nil
                self.isLoadingLyrics = false
                self.lyricErrorMessage = error.localizedDescription
            }
        }
    }

    private func installPlayerObservers() {
        let observedPlayer = avPlayer
        timeObserver = observedPlayer.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.1, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, self.avPlayer === observedPlayer else { return }
                self.updatePosition(time.seconds)
            }
        }

        playerStateObservation = observedPlayer.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            let rawValue = player.timeControlStatus.rawValue
            Task { @MainActor [weak self] in
                guard let self, self.avPlayer === player else { return }
                self.updatePlaybackState(rawValue: rawValue)
            }
        }
    }

    private func removePlayerObservers() {
        playerStateObservation?.invalidate()
        playerStateObservation = nil
        if let timeObserver {
            avPlayer.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
    }

    private func installItemObservers(_ item: AVPlayerItem, generation: Int, songID: Int64) {
        removeItemObservers()
        itemStatusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            let rawValue = item.status.rawValue
            Task { @MainActor [weak self] in
                guard let self, self.avPlayer.currentItem === item else { return }
                self.updateItemStatus(
                    rawValue: rawValue,
                    item: item,
                    generation: generation,
                    songID: songID
                )
            }
        }
        itemDurationObservation = item.observe(\.duration, options: [.initial, .new]) { [weak self] item, _ in
            let seconds = item.duration.seconds
            Task { @MainActor [weak self] in
                guard let self, self.avPlayer.currentItem === item else { return }
                self.updateDuration(seconds, generation: generation, songID: songID)
            }
        }
        itemEndObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
#if os(iOS)
            Task { @MainActor [weak self] in
                guard let self, self.avPlayer.currentItem === item else { return }
                self.didReachEnd(generation: generation, songID: songID)
            }
#else
            MainActor.assumeIsolated {
                guard let self, self.avPlayer.currentItem === item else { return }
                self.didReachEnd(generation: generation, songID: songID)
            }
#endif
        }
        itemFailureObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] notification in
            let message = (notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error)?.localizedDescription
                ?? "本地缓存播放失败"
#if os(iOS)
            Task { @MainActor [weak self] in
                guard let self, self.avPlayer.currentItem === item else { return }
                self.handleActiveItemFailure(
                    item,
                    generation: generation,
                    songID: songID,
                    message: message
                )
            }
#else
            MainActor.assumeIsolated {
                guard let self, self.avPlayer.currentItem === item else { return }
                self.handleActiveItemFailure(
                    item,
                    generation: generation,
                    songID: songID,
                    message: message
                )
            }
#endif
        }
    }

    private func removeItemObservers() {
        itemStatusObservation?.invalidate()
        itemStatusObservation = nil
        itemDurationObservation?.invalidate()
        itemDurationObservation = nil
        if let itemEndObserver { NotificationCenter.default.removeObserver(itemEndObserver) }
        itemEndObserver = nil
        if let itemFailureObserver { NotificationCenter.default.removeObserver(itemFailureObserver) }
        itemFailureObserver = nil
    }

    func updatePosition(_ seconds: TimeInterval) {
        guard seconds.isFinite,
              seconds >= 0,
              activeRangeFallback == nil,
              avPlayer.currentItem != nil,
              activeSongID == currentSong?.id
        else { return }
        if pendingAutomaticControlTrigger == .automaticEnd, seconds < 1 {
            pendingAutomaticControlGeneration = nil
            pendingAutomaticControlTrigger = nil
        }
        position = seconds
        updateCurrentLyricIndex()
        reportPodcastPlaybackIfNeeded(at: seconds)
        replenishHeartModeIfNeeded()
        prepareNextTransitionIfNeeded(position: seconds)
    }

    private func prepareNextTransitionIfNeeded(position: TimeInterval) {
        guard repeatMode != .one,
              let nextIndex = upcomingIndex(),
              duration > 0
        else { return }

        let remaining = max(0, duration - position)
        let prefetchAt = max(Self.prefetchWindow, crossfadeDuration + 5)
        if !prefetchTriggered, remaining <= prefetchAt {
            prefetchTriggered = true
            prefetchNext(generation: playbackGeneration, index: nextIndex)
        }

        if !crossfadeTriggered,
           CrossfadeTransition.shouldStart(
               position: position,
               duration: duration,
               crossfadeDuration: crossfadeDuration
        ) {
            crossfadeTriggered = true
            requestSongTransition(to: nextIndex, trigger: .crossfade, transition: .next)
        }
    }

    private func prefetchNext(generation: Int, index: Int) {
        guard cacheConfigurationTask == nil, queue.indices.contains(index) else { return }
        let songID = queue[index].id
        let quality = playbackQuality
        let expectedLevel = quality == .best ? nil : quality.cacheComponent
        let cacheGeneration = cacheGeneration
        let cache = cache
        let rangeCache = rangeCache
        let taskID = UUID()
        prefetchTaskID = taskID
        prefetchTask = Task { @MainActor [weak self, repository] in
            defer {
                if let self, self.prefetchTaskID == taskID {
                    self.prefetchTask = nil
                    self.prefetchTaskID = nil
                }
            }
            do {
                if let expectedLevel {
                    if let ready = await cache.readyFile(for: songID, quality: expectedLevel) {
                        guard let self,
                              self.isCurrentPrefetch(
                                  taskID: taskID,
                                  generation: generation,
                                  cacheGeneration: cacheGeneration,
                                  songID: songID,
                                  index: index
                              )
                        else { return }
                        self.prefetchedSongID = songID
                        self.prefetchedSource = PlaybackSource(
                            url: ready,
                            availability: .playable(level: expectedLevel),
                            format: ready.pathExtension
                        )
                        return
                    }
                    guard let self,
                          self.isCurrentPrefetch(
                              taskID: taskID,
                              generation: generation,
                              cacheGeneration: cacheGeneration,
                              songID: songID,
                              index: index
                          )
                    else { return }
                    if await rangeCache.descriptor(
                        for: TrackRangeCacheKey(songID: songID, quality: expectedLevel)
                    ) != nil {
                        guard self.isCurrentPrefetch(
                            taskID: taskID,
                            generation: generation,
                            cacheGeneration: cacheGeneration,
                            songID: songID,
                            index: index
                        ) else { return }
                        self.prefetchedSongID = songID
                        self.prefetchedSource = nil
                        return
                    }
                    guard self.isCurrentPrefetch(
                        taskID: taskID,
                        generation: generation,
                        cacheGeneration: cacheGeneration,
                        songID: songID,
                        index: index
                    ) else { return }
                }

                let source = if let expectedLevel {
                    try await repository.playbackSource(for: songID, level: expectedLevel)
                } else {
                    try await repository.playbackSource(for: songID, quality: quality)
                }
                guard let self,
                      self.isCurrentPrefetch(
                          taskID: taskID,
                          generation: generation,
                          cacheGeneration: cacheGeneration,
                          songID: songID,
                          index: index
                      )
                else { return }
                guard let level = source.availability.level,
                      SongQualityDetail.orderedLevels.contains(level),
                      expectedLevel == nil || expectedLevel == level
                else { return }

                self.prefetchedSongID = songID
                self.prefetchedSource = source
            } catch {}
        }
    }

    private func isCurrentPrefetch(
        taskID: UUID,
        generation: Int,
        cacheGeneration: Int,
        songID: Int64,
        index: Int
    ) -> Bool {
        prefetchTaskID == taskID
            && self.cacheGeneration == cacheGeneration
            && playbackGeneration == generation
            && queue.indices.contains(index)
            && queue[index].id == songID
    }

    private func updateDuration(_ seconds: TimeInterval, generation: Int, songID: Int64) {
        guard isCurrent(generation: generation, songID: songID), seconds.isFinite, seconds > 0 else { return }
        guard abs(mediaDuration - seconds) > 0.05 else { return }
        mediaDuration = seconds
    }

    private func updateItemStatus(
        rawValue: Int,
        item: AVPlayerItem,
        generation: Int,
        songID: Int64
    ) {
        guard isCurrent(generation: generation, songID: songID),
              avPlayer.currentItem === item,
              let status = AVPlayerItem.Status(rawValue: rawValue)
        else { return }

        switch status {
        case .readyToPlay:
            updateDuration(item.duration.seconds, generation: generation, songID: songID)
            if let fallback = activeRangeFallback,
               fallback.itemID == ObjectIdentifier(item) {
                if pendingSeekPosition == nil {
                    pendingSeekPosition = min(max(0, fallback.position), duration)
                }
                startPendingSeekIfPossible()
                return
            }
            startPendingSeekIfPossible()
            if wantsPlayback {
                avPlayer.play()
            } else {
                state = .paused(songID: songID)
            }
        case .failed:
            handleActiveItemFailure(
                item,
                generation: generation,
                songID: songID,
                message: item.error?.localizedDescription ?? "本地缓存播放失败"
            )
        case .unknown:
            state = .preparing(songID: songID)
        @unknown default:
            state = .preparing(songID: songID)
        }
    }

    private func updatePlaybackState(rawValue: Int) {
        guard let songID = currentSong?.id, avPlayer.currentItem != nil,
              activeSongID == songID,
              avPlayer.timeControlStatus.rawValue == rawValue,
              let status = AVPlayer.TimeControlStatus(rawValue: rawValue)
        else { return }

        switch status {
        case .playing:
            if pendingPlaybackFadeIn { startPlaybackControlFade(to: 1) }
            state = .playing(songID: songID)
            let startedNewSession = startPlaybackTiming(for: songID)
            if currentSong?.podcastEpisodeID == nil,
               startedNewSession,
               let sourceID = timedPlaybackSourceID,
               let totalSeconds = timedPlaybackTotalSeconds {
                let revision = accountCredentialRevision
                playbackStartReportTask = launchPlaybackReport(revision: revision) { [repository] in
                    try await repository.recordPlaybackStart(
                        for: songID,
                        sourceID: sourceID,
                        totalSeconds: totalSeconds,
                        expectedCredentialRevision: revision
                    )
                    return .song
                }
            }
        case .waitingToPlayAtSpecifiedRate:
            stopPlaybackTiming()
            if wantsPlayback { state = .preparing(songID: songID) }
        case .paused:
            stopPlaybackTiming()
            if !wantsPlayback { state = .paused(songID: songID) }
        @unknown default:
            break
        }
    }

    private func didReachEnd(generation: Int, songID: Int64) {
        guard isCurrent(generation: generation, songID: songID) else { return }
        position = duration
        updateCurrentLyricIndex()
        submitPlaybackIfNeeded()
        guard wantsPlayback else { return }
        guard !crossfadeTriggered else { return }
        advance(trigger: .automaticEnd)
    }

    private func failAndAdvance(generation: Int, songID: Int64, message: String) {
        guard isCurrent(generation: generation, songID: songID), let currentIndex else { return }
        submitPlaybackIfNeeded()
        finishCrossfade()
        wantsPlayback = false
        avPlayer.pause()
        state = .failed(songID: songID, message: message)
        guard !isSharedControlActive else { return }
        let target = isShuffleEnabled
            ? (shuffleCursor + 1 < shuffleOrder.count ? shuffleOrder[shuffleCursor + 1] : nil)
            : (currentIndex + 1 < queue.count ? currentIndex + 1 : nil)
        if let target {
            requestSongTransition(to: target, trigger: .playbackFailure, transition: .next)
        } else {
            requestControl(
                PlayerControlIntent(
                    trigger: .playbackFailure,
                    play: .pause(songID: songID, progress: position),
                    queue: nil
                ),
                commit: {}
            )
        }
    }

    private func failUnavailable(generation: Int, songID: Int64, error: PlaybackUnavailableError) {
        guard isCurrent(generation: generation, songID: songID) else { return }
        finishCrossfade()
        wantsPlayback = false
        avPlayer.pause()
        playbackAvailability = .unavailable(reason: error.reason)
        alternativeSongs = error.alternatives
        state = .failed(songID: songID, message: error.reason)
        guard !isSharedControlActive else { return }
        requestControl(
            PlayerControlIntent(
                trigger: .playbackFailure,
                play: .pause(songID: songID, progress: position),
                queue: nil
            ),
            commit: {}
        )
    }

    private func advance(trigger: PlayerControlTrigger) {
        guard let currentIndex else { return }

        if trigger == .automaticEnd, repeatMode == .one {
            requestRestartCurrentTrack(trigger: trigger)
            return
        }

        if let target = upcomingIndex() {
            if target == currentIndex {
                requestRestartCurrentTrack(trigger: trigger)
            } else {
                requestSongTransition(to: target, trigger: trigger, transition: .next)
            }
            return
        }

        if isShuffleEnabled, repeatMode == .all {
            let displaySongIDs = queue.map(\.id)
            let randomSongIDs = Self.shuffledSongIDs(
                currentSongID: queue[currentIndex].id,
                displaySongIDs: displaySongIDs
            )
            guard randomSongIDs.count > 1,
                  let target = queue.firstIndex(where: { $0.id == randomSongIDs[1] })
            else {
                requestRestartCurrentTrack(trigger: trigger)
                return
            }
            let order = PlayerQueueOrder(
                displaySongIDs: displaySongIDs,
                randomSongIDs: randomSongIDs,
                anchorSongID: queue[target].id
            )
            requestControl(
                PlayerControlIntent(
                    trigger: trigger,
                    play: .transition(
                        .next,
                        formerSongID: currentSongID,
                        targetSongID: queue[target].id,
                        progress: 0,
                        playing: true
                    ),
                    queue: order
                )
            ) { [weak self] in
                guard let self else { return }
                self.installPlaybackOrder(order, shuffleEnabled: true)
                self.activate(index: target, preservingShuffleOrder: true)
            }
            return
        }

        guard let songID = currentSongID else { return }
        requestControl(
            PlayerControlIntent(
                trigger: trigger,
                play: .pause(songID: songID, progress: position),
                queue: nil
            )
        ) { [weak self] in
            guard let self else { return }
            self.wantsPlayback = false
            self.submitPlaybackIfNeeded()
            self.avPlayer.pause()
            self.state = .idle
        }
    }

    private func restartCurrentTrackLocally() {
        guard let song = currentSong else { return }
        seekLocally(to: 0)
        if wantsPlayback {
            state = .preparing(songID: song.id)
            avPlayer.play()
        } else {
            state = .paused(songID: song.id)
        }
    }

    @discardableResult
    private func startPlaybackTiming(for songID: Int64) -> Bool {
        let startedNewSession = timedPlaybackSongID != songID
        if timedPlaybackSongID != songID {
            submitPlaybackIfNeeded()
            timedPlaybackSongID = songID
            timedPlaybackSourceID = currentPlaybackSourceID
            timedPlaybackTotalSeconds = max(1, Int(duration))
            timedPlaybackCredentialRevision = accountCredentialRevision
        }
        if playbackTimingStartedAt == nil { playbackTimingStartedAt = ContinuousClock.now }
        return startedNewSession
    }

    private func stopPlaybackTiming() {
        guard let startedAt = playbackTimingStartedAt else { return }
        listenedDuration += startedAt.duration(to: ContinuousClock.now)
        playbackTimingStartedAt = nil
    }

    private func submitPlaybackIfNeeded() {
        stopPlaybackTiming()
        let songID = timedPlaybackSongID
        let sourceID = timedPlaybackSourceID
        let totalSeconds = timedPlaybackTotalSeconds
        let revision = timedPlaybackCredentialRevision
        let startReportTask = playbackStartReportTask
        let seconds = Int(listenedDuration.components.seconds)
        let podcastEpisodeID = currentSong?.podcastEpisodeID
        let positionMilliseconds = Int(position * 1_000)
        let completed = duration > 0 && position >= duration - 1
        timedPlaybackSongID = nil
        timedPlaybackSourceID = nil
        timedPlaybackTotalSeconds = nil
        timedPlaybackCredentialRevision = nil
        playbackStartReportTask = nil
        listenedDuration = .zero
        guard let songID, let revision, seconds > 0 else { return }
        launchPlaybackReport(
            revision: revision,
            preservingFailureOf: startReportTask
        ) { [repository] in
            if let podcastEpisodeID, positionMilliseconds > 0 {
                try await repository.recordPodcastPlayback(
                    for: podcastEpisodeID,
                    positionMilliseconds: positionMilliseconds,
                    completed: completed,
                    expectedCredentialRevision: revision
                )
                return .podcast
            }
            guard let sourceID, let totalSeconds else { return nil }
            try await repository.recordPlayback(
                for: songID,
                sourceID: sourceID,
                playedSeconds: seconds,
                totalSeconds: totalSeconds,
                expectedCredentialRevision: revision
            )
            return .song
        }
    }

    @discardableResult
    private func launchPlaybackReport(
        revision: UInt64,
        preservingFailureOf prerequisite: Task<Bool, Never>? = nil,
        operation: @escaping @Sendable () async throws -> PlaybackHistoryKind?
    ) -> Task<Bool, Never> {
        let taskID = UUID()
        let task = Task { @MainActor [weak self] in
            defer {
                self?.playbackReportTasks[taskID] = nil
                self?.playbackReportOrder.removeAll { $0 == taskID }
            }
            do {
                let prerequisiteSucceeded = await prerequisite?.value
                try Task.checkCancellation()
                guard let kind = try await operation() else { return false }
                try Task.checkCancellation()
                guard let self,
                      self.accountCredentialRevision == revision,
                      self.playbackReportTasks[taskID] != nil
                else { return false }
                self.publishPlaybackHistory(
                    kind,
                    revision: revision,
                    clearsPreviousError: prerequisiteSucceeded != false
                )
                return true
            } catch is CancellationError {
                return false
            } catch {
                guard let self,
                      self.accountCredentialRevision == revision,
                      self.playbackReportTasks[taskID] != nil
                else { return false }
                self.playbackReportErrorMessage = Self.playbackReportMessage(for: error)
                return false
            }
        }
        if playbackReportOrder.count == Self.maximumPendingPlaybackReports {
            let oldest = playbackReportOrder.removeFirst()
            playbackReportTasks.removeValue(forKey: oldest)?.cancel()
        }
        playbackReportOrder.append(taskID)
        playbackReportTasks[taskID] = task
        return task
    }

    private func cancelPlaybackReports() {
        playbackReportTasks.values.forEach { $0.cancel() }
        playbackReportTasks.removeAll()
        playbackReportOrder.removeAll()
        playbackStartReportTask = nil
    }

    private func publishPlaybackHistory(
        _ kind: PlaybackHistoryKind,
        revision: UInt64,
        clearsPreviousError: Bool
    ) {
        guard accountCredentialRevision == revision else { return }
        playbackHistorySequence += 1
        playbackHistoryEvent = PlaybackHistoryEvent(
            sequence: playbackHistorySequence,
            credentialRevision: revision,
            kind: kind
        )
        if clearsPreviousError { playbackReportErrorMessage = nil }
    }

    private static func playbackReportMessage(for error: Error) -> String {
        if let error = error as? URLError,
           error.code == .timedOut || error.code == .cannotFindHost || error.code == .dnsLookupFailed {
            return "无法同步播放记录：请在 Karing、DNS 或代理中放行 clientlog3.music.163.com"
        }
        return "播放记录同步失败：\(error.localizedDescription)"
    }

    private var currentPlaybackSourceID: Int64? {
        if let sourcePlaylistID, sourcePlaylistID > 0 { return sourcePlaylistID }
        guard let songID = currentSong?.id, songID > 0 else { return nil }
        return songID
    }

    private func reportPodcastPlaybackIfNeeded(at seconds: TimeInterval) {
        guard reportedPodcastPlaybackGeneration != playbackGeneration,
              let episodeID = currentSong?.podcastEpisodeID,
              seconds >= 1
        else { return }
        reportedPodcastPlaybackGeneration = playbackGeneration
        let revision = accountCredentialRevision
        launchPlaybackReport(revision: revision) { [repository] in
            try await repository.recordPodcastPlayback(
                for: episodeID,
                positionMilliseconds: Int(seconds * 1_000),
                completed: false,
                expectedCredentialRevision: revision
            )
            return .podcast
        }
    }

    private func upcomingIndex() -> Int? {
        guard let currentIndex else { return nil }
        if isShuffleEnabled {
            return shuffleCursor + 1 < shuffleOrder.count ? shuffleOrder[shuffleCursor + 1] : nil
        }
        return PlaybackNavigation.nextIndex(
            currentIndex: currentIndex,
            count: queue.count,
            repeatMode: repeatMode,
            automatic: false
        )
    }

    private func rebuildShuffleOrder(keeping index: Int?) {
        guard isShuffleEnabled, let index, queue.indices.contains(index) else {
            shuffleOrder = []
            shuffleCursor = 0
            return
        }
        shuffleOrder = PlaybackNavigation.shuffledOrder(currentIndex: index, count: queue.count)
        shuffleCursor = 0
    }

    private func resetTransitionPreparation() {
        prefetchTask?.cancel()
        prefetchTask = nil
        prefetchTaskID = nil
        prefetchedSongID = nil
        prefetchedSource = nil
        prefetchTriggered = false
        crossfadeTriggered = false
    }

    private func updateCurrentLyricIndex() {
        let next = LRCParser.currentLineIndex(in: lyrics, at: Int64(position * 1_000))
        guard next != currentLyricIndex else { return }
        currentLyricIndex = next
    }

    private func isCurrent(generation: Int, songID: Int64) -> Bool {
        playbackGeneration == generation && currentSong?.id == songID
    }
}
