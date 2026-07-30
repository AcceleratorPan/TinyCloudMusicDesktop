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

struct PlayerControlIntent: Equatable, Sendable {
    let trigger: PlayerControlTrigger
    let play: PlayerPlayIntent?
    let queue: PlayerQueueOrder?
}

@MainActor
@Observable
final class PlayerController {
    typealias ControlInterceptor = @MainActor @Sendable (
        _ intent: PlayerControlIntent,
        _ commit: @escaping @MainActor @Sendable () -> Void
    ) -> Bool

    private static let maximumStreamAttempts = 3
    private static let maximumCrossfadeDuration: TimeInterval = 12
    private static let prefetchWindow: TimeInterval = 10
    private static let heartModeReplenishThreshold = 3

    private(set) var queue: [PlaybackQueueItem] = []
    private(set) var context: PlaybackContext?
    private(set) var currentIndex: Int?
    private(set) var state: PlaybackState = .idle
    private(set) var position: TimeInterval = 0
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
    var volume: Double = 0.78 {
        didSet {
            if volume > 0 { lastAudibleVolume = min(volume, 1) }
            applyVolume()
        }
    }
    private(set) var crossfadeDuration: TimeInterval
    private(set) var repeatMode: PlaybackRepeatMode = .off
    private(set) var isShuffleEnabled = false
    private(set) var isLinearQueueMode = false
    private(set) var isHeartModeEnabled = false
    private(set) var isLoadingHeartMode = false
    private(set) var heartModeErrorMessage: String?
    private(set) var sourcePlaylistID: Int64?
    private(set) var playbackReportRevision = 0
    private(set) var lastPlaybackReportWasPodcast = false
    private(set) var playbackReportErrorMessage: String?
    private(set) var isControlInteractionLocked = false
    private(set) var isSharedControlActive = false

    @ObservationIgnored private let repository: any MusicRepository
    @ObservationIgnored private var cache: TrackCache
    @ObservationIgnored private var playbackQuality: AudioQuality
    @ObservationIgnored private var avPlayer = AVPlayer()
    @ObservationIgnored private var standbyPlayer = AVPlayer()
    @ObservationIgnored private var activeSongID: Int64?
    @ObservationIgnored private var playbackGeneration = 0
    @ObservationIgnored private var wantsPlayback = false
    @ObservationIgnored private var pendingSeek: TimeInterval?
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var cacheTask: Task<Void, Never>?
    @ObservationIgnored private var prefetchTask: Task<Void, Never>?
    @ObservationIgnored private var queueHydrationTask: Task<Void, Never>?
    @ObservationIgnored private var songResolutionTask: Task<Void, Never>?
    @ObservationIgnored private var lyricTask: Task<Void, Never>?
    @ObservationIgnored private var heartModeTask: Task<Void, Never>?
    @ObservationIgnored private var heartModeSeedSongID: Int64?
    @ObservationIgnored private var heartModeHasRecommendations = false
    @ObservationIgnored private var heartModeExhausted = false
    @ObservationIgnored private var heartModeOriginalQueue: [PlaybackQueueItem]?
    @ObservationIgnored private var heartModeOriginalIndex: Int?
    @ObservationIgnored private var qualitySwitchTask: Task<Void, Never>?
    @ObservationIgnored private var qualitySwitchRevision = 0
    @ObservationIgnored private var fadeTask: Task<Void, Never>?
    @ObservationIgnored private var fadeProgress: Double?
    @ObservationIgnored private var standbySeekPosition: TimeInterval?
    @ObservationIgnored private var standbyTransitionDuration: TimeInterval?
    @ObservationIgnored private var standbyPlaybackAvailability: PlaybackAvailability?
    @ObservationIgnored private var qualityBeforeSwitch: String?
    @ObservationIgnored private var reportedPodcastPlaybackGeneration = -1
    @ObservationIgnored private var timedPlaybackSongID: Int64?
    @ObservationIgnored private var timedPlaybackSourceID: Int64?
    @ObservationIgnored private var timedPlaybackTotalSeconds: Int?
    @ObservationIgnored private var playbackStartReportTask: Task<Bool, Never>?
    @ObservationIgnored private var playbackTimingStartedAt: ContinuousClock.Instant?
    @ObservationIgnored private var listenedDuration: Duration = .zero
    @ObservationIgnored private var lastAudibleVolume = 0.78
    @ObservationIgnored private var shuffleOrder: [Int] = []
    @ObservationIgnored private var shuffleCursor = 0
    @ObservationIgnored private var savedQueueMode: (shuffle: Bool, repeatMode: PlaybackRepeatMode)?
    @ObservationIgnored private var prefetchTriggered = false
    @ObservationIgnored private var crossfadeTriggered = false
    @ObservationIgnored private var prefetchedSongID: Int64?
    @ObservationIgnored private var prefetchedSourceURL: URL?
    @ObservationIgnored private var prefetchedAvailability: PlaybackAvailability?
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
        crossfadeDuration: TimeInterval = 3
    ) {
        self.repository = repository
        self.playbackQuality = playbackQuality
        self.crossfadeDuration = min(max(crossfadeDuration, 0), Self.maximumCrossfadeDuration)
        cache = Self.makeCache(root: cacheRoot)
        applyVolume()
        installPlayerObservers()
    }

    func configure(playbackQuality: AudioQuality, cacheRoot: URL) {
        self.playbackQuality = playbackQuality
        selectedPlaybackLevel = nil
        cache = Self.makeCache(root: cacheRoot)
    }

    func setCrossfadeDuration(_ seconds: TimeInterval) {
        crossfadeDuration = min(max(seconds, 0), Self.maximumCrossfadeDuration)
        if crossfadeDuration == 0, fadeProgress != nil { finishCrossfade() }
    }

    func setControlInteractionLocked(_ locked: Bool) {
        isControlInteractionLocked = locked
    }

    isolated deinit {
        loadTask?.cancel()
        cacheTask?.cancel()
        prefetchTask?.cancel()
        queueHydrationTask?.cancel()
        songResolutionTask?.cancel()
        lyricTask?.cancel()
        heartModeTask?.cancel()
        qualitySwitchTask?.cancel()
        fadeTask?.cancel()
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
        playlistID: Int64? = nil
    ) {
        guard let plan = PlaybackQueuePlan.make(
            selectedSongID: song.id,
            visibleSongIDs: visibleSongs.map(\.id),
            allSongIDs: allSongIDs
        ) else { return }
        let songIDs = plan.songIDs
        let index = plan.startIndex
        let newContext = PlaybackContext(songIDs: songIDs, startIndex: index)
        let sourceChanged = sourcePlaylistID != playlistID
        let action: PlaybackSelectionAction = if sourceChanged, currentSong?.id == song.id {
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
        let shuffleEnabled = savedQueueMode?.shuffle ?? isShuffleEnabled
        let queueOrder = PlayerQueueOrder(
            displaySongIDs: songIDs,
            randomSongIDs: shuffleEnabled
                ? Self.shuffledSongIDs(currentSongID: song.id, displaySongIDs: songIDs)
                : songIDs,
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
        let queueIntent: PlayerQueueOrder? = switch action {
        case .switchQueue, .replaceTrackAtZero: queueOrder
        case .keepPlaying, .resume: nil
        }
        let commit: @MainActor @Sendable () -> Void = { [weak self] in
            guard let self else { return }
            self.playLocally(
                song: song,
                visibleSongs: visibleSongs,
                playlistID: playlistID,
                songIDs: songIDs,
                index: index,
                action: action,
                queueOrder: queueOrder,
                shuffleEnabled: shuffleEnabled
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
        selectedPlaybackLevel = quality.id
        playbackQualityErrorMessage = nil
        resetTransitionPreparation()
        guard activeLevel != quality.id,
              let songID = currentSongID,
              avPlayer.currentItem != nil
        else { return }

        finishCrossfade()
        if wantsPlayback { avPlayer.play() }
        qualitySwitchTask?.cancel()
        qualitySwitchRevision += 1
        let revision = qualitySwitchRevision
        qualityBeforeSwitch = previousSelection
        isSwitchingPlaybackQuality = true
        let cache = cache
        qualitySwitchTask = Task { @MainActor [weak self, repository] in
            do {
                let source = if let ready = cache.readyFile(for: songID, quality: quality.id) {
                    PlaybackSource(url: ready, availability: .playable(level: quality.id))
                } else {
                    try await repository.playbackSource(for: songID, level: quality.id)
                }
                try Task.checkCancellation()
                let level = source.availability.level ?? quality.id
                let sourceURL = cache.readyFile(for: songID, quality: level) ?? source.url
                guard let self,
                      self.qualitySwitchRevision == revision,
                      self.currentSongID == songID
                else { return }

                self.qualitySwitchTask = nil
                self.selectedPlaybackLevel = level
                self.finishCrossfade()
                self.prepareCrossfade(
                    Self.makePlayerItem(for: sourceURL),
                    generation: self.playbackGeneration,
                    songID: songID,
                    seekPosition: self.position,
                    transitionDuration: 0.2,
                    playbackAvailability: source.availability,
                    qualityRevision: revision
                )

                let isTrial = if case .trial = source.availability { true } else { false }
                if !sourceURL.isFileURL && !isTrial {
                    self.cacheTask = Task {
                        _ = try? await cache.cache(songID: songID, quality: level, from: sourceURL)
                    }
                }
            } catch is CancellationError {
            } catch {
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
        songIDs: [Int64],
        index: Int,
        action: PlaybackSelectionAction,
        queueOrder: PlayerQueueOrder,
        shuffleEnabled: Bool
    ) {
        if isHeartModeEnabled {
            stopHeartMode(restoringQueue: false)
        } else {
            restoreQueueMode()
        }
        heartModeErrorMessage = nil
        sourcePlaylistID = playlistID

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
            installQueue(songIDs: songIDs, knownSongs: visibleSongs, currentIndex: index)
            installPlaybackOrder(queueOrder, shuffleEnabled: shuffleEnabled)
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
        guard currentSong != nil else { return }
        let target = min(max(0, seconds), duration)
        position = target
        updateCurrentLyricIndex()
        guard activeSongID == currentSong?.id, avPlayer.currentItem?.status == .readyToPlay else {
            pendingSeek = target
            return
        }
        avPlayer.seek(
            to: CMTime(seconds: target, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
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
            resolveAndActivate(songID: item.id, index: index, preservingShuffleOrder: true)
            return
        }
        let shouldCrossfade = crossfadeDuration > 0
            && wantsPlayback
            && activeSongID != nil
            && activeSongID != song.id
            && avPlayer.timeControlStatus == .playing
        let usesPrefetch = prefetchedSongID == song.id
        let prefetchedURL = usesPrefetch ? prefetchedSourceURL : nil
        let prefetchedAvailability = usesPrefetch ? self.prefetchedAvailability : nil
        let cacheAlreadyRunning = usesPrefetch && prefetchTask != nil

        playbackGeneration += 1
        let generation = playbackGeneration

        loadTask?.cancel()
        cacheTask?.cancel()
        qualitySwitchTask?.cancel()
        qualitySwitchTask = nil
        qualitySwitchRevision += 1
        if usesPrefetch {
            cacheTask = prefetchTask
        } else {
            prefetchTask?.cancel()
        }
        prefetchTask = nil
        prefetchedSongID = nil
        prefetchedSourceURL = nil
        self.prefetchedAvailability = nil
        lyricTask?.cancel()
        standbyStatusObservation?.invalidate()
        standbyStatusObservation = nil
        standbyPlayer.pause()
        standbyPlayer.replaceCurrentItem(with: nil)
        removeItemObservers()
        if !shouldCrossfade {
            avPlayer.pause()
            avPlayer.replaceCurrentItem(with: nil)
            activeSongID = nil
        }

        currentIndex = index
        context = PlaybackContext(songIDs: queue.map(\.id), startIndex: index)
        position = 0
        mediaDuration = 0
        pendingSeek = nil
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
        state = .preparing(songID: song.id)

        loadTrack(
            generation: generation,
            songID: song.id,
            prefetchedURL: prefetchedURL,
            prefetchedAvailability: prefetchedAvailability,
            cacheAlreadyRunning: cacheAlreadyRunning,
            crossfade: shouldCrossfade
        )
        loadLyrics(generation: generation, songID: song.id)
        replenishHeartModeIfNeeded()
    }

    private func installQueue(songIDs: [Int64], knownSongs: [Song], currentIndex: Int) {
        queueHydrationTask?.cancel()
        songResolutionTask?.cancel()
        let knownByID = Dictionary(knownSongs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        queue = songIDs.map { PlaybackQueueItem(id: $0, song: knownByID[$0]) }
        self.currentIndex = currentIndex
        context = PlaybackContext(songIDs: songIDs, startIndex: currentIndex)
        hydrateQueue()
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
        resetTransitionPreparation()
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
            hydrateQueue()
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
        if queueHydrationTask == nil { hydrateQueue() }
    }

    private func hydrateQueue() {
        let songIDs = queue.map(\.id)
        let missingIDs = queue.compactMap { $0.song == nil ? $0.id : nil }
        guard !missingIDs.isEmpty else { return }

        queueHydrationTask = Task { @MainActor [weak self, repository] in
            do {
                let songs = try await repository.songs(ids: missingIDs)
                try Task.checkCancellation()
                guard let self, self.queue.map(\.id) == songIDs else { return }
                self.mergeKnownSongs(songs)
                self.queueHydrationTask = nil
            } catch is CancellationError {
            } catch {
                guard let self, self.queue.map(\.id) == songIDs else { return }
                self.queueHydrationTask = nil
            }
        }
    }

    private func resolveAndActivate(songID: Int64, index: Int, preservingShuffleOrder: Bool) {
        songResolutionTask?.cancel()
        currentIndex = index
        context = PlaybackContext(songIDs: queue.map(\.id), startIndex: index)
        position = 0
        mediaDuration = 0
        wantsPlayback = true
        state = .preparing(songID: songID)

        songResolutionTask = Task { @MainActor [weak self, repository] in
            do {
                guard let song = try await repository.songs(ids: [songID]).first else {
                    throw AppError.unavailable("无法加载歌曲信息")
                }
                try Task.checkCancellation()
                guard let self,
                      self.currentIndex == index,
                      self.queue.indices.contains(index),
                      self.queue[index].id == songID
                else { return }
                let shouldPlay = self.wantsPlayback
                self.queue[index].song = song
                self.songResolutionTask = nil
                self.activate(index: index, preservingShuffleOrder: preservingShuffleOrder)
                if !shouldPlay { self.pauseLocally() }
            } catch is CancellationError {
            } catch {
                guard let self,
                      self.currentIndex == index,
                      self.queue.indices.contains(index),
                      self.queue[index].id == songID
                else { return }
                self.songResolutionTask = nil
                self.wantsPlayback = false
                self.state = .failed(songID: songID, message: error.localizedDescription)
            }
        }
    }

    private func pauseLocally() {
        guard let songID = currentSongID else { return }
        wantsPlayback = false
        stopPlaybackTiming()
        if fadeProgress != nil { finishCrossfade() }
        avPlayer.pause()
        standbyPlayer.pause()
        state = .paused(songID: songID)
    }

    private func resumeLocally() {
        guard let songID = currentSongID else { return }
        guard let song = currentSong else {
            wantsPlayback = true
            state = .preparing(songID: songID)
            if songResolutionTask == nil, let currentIndex {
                resolveAndActivate(songID: songID, index: currentIndex, preservingShuffleOrder: true)
            }
            return
        }
        if case .failed = state {
            retryPlaybackLocally(index: currentIndex ?? 0)
            return
        }
        wantsPlayback = true
        if isSwitchingPlaybackQuality, standbyPlayer.currentItem?.status == .readyToPlay {
            state = .preparing(songID: song.id)
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
        } else if loadTask != nil {
            state = .preparing(songID: song.id)
        } else {
            activate(index: currentIndex ?? 0)
        }
    }

    private func loadTrack(
        generation: Int,
        songID: Int64,
        prefetchedURL: URL? = nil,
        prefetchedAvailability: PlaybackAvailability? = nil,
        cacheAlreadyRunning: Bool = false,
        crossfade: Bool = false
    ) {
        let quality = playbackQuality
        let selectedLevel = selectedPlaybackLevel
        let expectedLevel = selectedLevel ?? (quality == .best ? nil : quality.cacheComponent)
        loadTask = Task { @MainActor [weak self, repository, cache] in
            var lastError: Error?
            var sourceURL = prefetchedURL
                ?? expectedLevel.flatMap { cache.readyFile(for: songID, quality: $0) }
            var availability = prefetchedAvailability
                ?? (sourceURL == nil ? nil : expectedLevel.map { .playable(level: $0) })
            var cacheLevel = availability?.level ?? expectedLevel

            if sourceURL == nil {
                for _ in 0..<Self.maximumStreamAttempts {
                    do {
                        let source = if let selectedLevel {
                            try await repository.playbackSource(for: songID, level: selectedLevel)
                        } else {
                            try await repository.playbackSource(for: songID, quality: quality)
                        }
                        availability = source.availability
                        cacheLevel = source.availability.level ?? expectedLevel
                        sourceURL = cacheLevel.flatMap { cache.readyFile(for: songID, quality: $0) } ?? source.url
                        break
                    } catch is CancellationError {
                        return
                    } catch let error as PlaybackUnavailableError {
                        lastError = error
                        break
                    } catch {
                        lastError = error
                    }
                }
            }

            do {
                try Task.checkCancellation()
                guard let sourceURL,
                      let self,
                      self.isCurrent(generation: generation, songID: songID)
                else {
                    if Task.isCancelled { return }
                    throw lastError ?? URLError(.badURL)
                }

                self.loadTask = nil
                self.playbackAvailability = availability
                self.prepare(sourceURL, generation: generation, songID: songID, crossfade: crossfade)
                let isTrial = if case .trial? = availability { true } else { false }
                if let cacheLevel, !sourceURL.isFileURL && !cacheAlreadyRunning && !isTrial {
                    self.cacheTask = Task {
                        _ = try? await cache.cache(songID: songID, quality: cacheLevel, from: sourceURL)
                    }
                }
            } catch is CancellationError {
            } catch let error as PlaybackUnavailableError {
                guard !Task.isCancelled,
                      let self,
                      self.isCurrent(generation: generation, songID: songID)
                else { return }
                self.loadTask = nil
                self.failUnavailable(generation: generation, songID: songID, error: error)
            } catch {
                guard let self, self.isCurrent(generation: generation, songID: songID) else { return }
                self.loadTask = nil
                self.failAndAdvance(
                    generation: generation,
                    songID: songID,
                    message: lastError?.localizedDescription ?? "这首歌需要订阅数字专辑才能播放、下载哦~"
                )
            }
        }
    }

    private static func makeCache(root: URL?) -> TrackCache {
        let root = root ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: "TinyCloudMusic", directoryHint: .isDirectory)
        return TrackCache(directory: root.appending(path: "StreamCache", directoryHint: .isDirectory))
    }

    private static func makePlayerItem(for sourceURL: URL) -> AVPlayerItem {
        let asset = AVURLAsset(url: sourceURL, options: [
            AVURLAssetPreferPreciseDurationAndTimingKey: sourceURL.pathExtension.lowercased() == "flac"
        ])
        return AVPlayerItem(asset: asset)
    }

    private func prepare(_ sourceURL: URL, generation: Int, songID: Int64, crossfade: Bool) {
        guard isCurrent(generation: generation, songID: songID) else { return }
        let item = Self.makePlayerItem(for: sourceURL)
        if crossfade, avPlayer.currentItem != nil, avPlayer.timeControlStatus == .playing {
            prepareCrossfade(item, generation: generation, songID: songID)
            return
        }

        activeSongID = songID
        installItemObservers(item, generation: generation, songID: songID)
        state = .preparing(songID: songID)
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
        standbySeekPosition = seekPosition
        standbyTransitionDuration = transitionDuration
        standbyPlaybackAvailability = playbackAvailability
        standbyPlayer.pause()
        standbyPlayer.volume = 0
        standbyStatusObservation?.invalidate()
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

    private func updateStandbyStatus(
        rawValue: Int,
        item: AVPlayerItem,
        generation: Int,
        songID: Int64,
        qualityRevision: Int?
    ) {
        guard isCurrent(generation: generation, songID: songID),
              qualityRevision == nil || qualityRevision == self.qualitySwitchRevision,
              let status = AVPlayerItem.Status(rawValue: rawValue)
        else { return }

        switch status {
        case .readyToPlay:
            standbyStatusObservation?.invalidate()
            standbyStatusObservation = nil
            if let fallbackSeekPosition = standbySeekPosition {
                // Freeze the outgoing clock while the replacement stream seeks and prerolls.
                if wantsPlayback { avPlayer.pause() }
                let currentPosition = avPlayer.currentTime().seconds
                let seekPosition = currentPosition.isFinite && currentPosition >= 0
                    ? currentPosition
                    : fallbackSeekPosition
                position = seekPosition
                updateCurrentLyricIndex()
                standbyPlayer.seek(
                    to: CMTime(seconds: seekPosition, preferredTimescale: 600),
                    toleranceBefore: .zero,
                    toleranceAfter: .zero
                ) { [weak self] finished in
                    Task { @MainActor [weak self] in
                        guard let self,
                              self.isCurrent(generation: generation, songID: songID),
                              qualityRevision == nil || qualityRevision == self.qualitySwitchRevision
                        else { return }
                        if finished {
                            self.beginStandbyPreroll(
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
            } else {
                beginStandbyPreroll(
                    item,
                    generation: generation,
                    songID: songID,
                    qualityRevision: qualityRevision
                )
            }
        case .failed:
            standbyStatusObservation?.invalidate()
            standbyStatusObservation = nil
            let message = item.error?.localizedDescription ?? "音频流预缓冲失败"
            standbyPlayer.replaceCurrentItem(with: nil)
            if standbyTransitionDuration != nil {
                failQualitySwitch(message)
            } else if let sourceURL = (item.asset as? AVURLAsset)?.url {
                finishCrossfade()
                prepare(sourceURL, generation: generation, songID: songID, crossfade: false)
            } else {
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
        qualityRevision: Int?
    ) {
        standbyPlayer.preroll(atRate: 1) { [weak self] ready in
            Task { @MainActor [weak self] in
                guard let self,
                      self.isCurrent(generation: generation, songID: songID),
                      qualityRevision == nil || qualityRevision == self.qualitySwitchRevision
                else { return }
                if ready {
                    self.promoteStandby(
                        item,
                        generation: generation,
                        songID: songID,
                        qualityRevision: qualityRevision
                    )
                } else {
                    self.standbyPlayer.replaceCurrentItem(with: nil)
                    let message = item.error?.localizedDescription ?? "音频流预缓冲失败"
                    if self.standbyTransitionDuration != nil {
                        self.failQualitySwitch(message)
                    } else if let sourceURL = (item.asset as? AVURLAsset)?.url {
                        self.finishCrossfade()
                        self.prepare(sourceURL, generation: generation, songID: songID, crossfade: false)
                    } else {
                        self.failAndAdvance(generation: generation, songID: songID, message: message)
                    }
                }
            }
        }
    }

    private func promoteStandby(
        _ item: AVPlayerItem,
        generation: Int,
        songID: Int64,
        qualityRevision: Int?
    ) {
        guard isCurrent(generation: generation, songID: songID),
              qualityRevision == nil || qualityRevision == self.qualitySwitchRevision
        else { return }
        let transitionDuration = standbyTransitionDuration
        let isQualitySwitch = transitionDuration != nil
        let switchedAvailability = standbyPlaybackAvailability

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
        }

        guard wantsPlayback else {
            avPlayer.pause()
            standbyPlayer.pause()
            standbyPlayer.replaceCurrentItem(with: nil)
            applyVolume()
            state = .paused(songID: songID)
            return
        }

        if isQualitySwitch { standbyPlayer.play() }
        avPlayer.play()
        startCrossfade(generation: generation, durationOverride: transitionDuration)
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
        fadeTask?.cancel()
        fadeTask = nil
        fadeProgress = nil
        standbyStatusObservation?.invalidate()
        standbyStatusObservation = nil
        standbyPlayer.pause()
        standbyPlayer.replaceCurrentItem(with: nil)
        standbySeekPosition = nil
        standbyTransitionDuration = nil
        standbyPlaybackAvailability = nil
        applyVolume()
    }

    private func failQualitySwitch(_ message: String) {
        standbyStatusObservation?.invalidate()
        standbyStatusObservation = nil
        standbyPlayer.pause()
        standbyPlayer.replaceCurrentItem(with: nil)
        standbySeekPosition = nil
        standbyTransitionDuration = nil
        standbyPlaybackAvailability = nil
        selectedPlaybackLevel = qualityBeforeSwitch
        qualityBeforeSwitch = nil
        isSwitchingPlaybackQuality = false
        playbackQualityErrorMessage = message
        applyVolume()
        if wantsPlayback { avPlayer.play() }
    }

    private func applyVolume() {
        let level = min(max(volume, 0), 1)
        guard let fadeProgress else {
            avPlayer.volume = Float(level)
            standbyPlayer.volume = 0
            return
        }

        let gains = CrossfadeTransition.gains(progress: fadeProgress)
        avPlayer.volume = Float(level * gains.incoming)
        standbyPlayer.volume = Float(level * gains.outgoing)
    }

    private func loadLyrics(generation: Int, songID: Int64) {
        lyricTask = Task { @MainActor [weak self, repository] in
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
        timeObserver = avPlayer.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.1, preferredTimescale: 600),
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.updatePosition(self.avPlayer.currentTime().seconds)
            }
        }

        playerStateObservation = avPlayer.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            let rawValue = player.timeControlStatus.rawValue
            Task { @MainActor [weak self] in self?.updatePlaybackState(rawValue: rawValue) }
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
                self?.updateItemStatus(rawValue: rawValue, generation: generation, songID: songID)
            }
        }
        itemDurationObservation = item.observe(\.duration, options: [.initial, .new]) { [weak self] item, _ in
            let seconds = item.duration.seconds
            Task { @MainActor [weak self] in
                self?.updateDuration(seconds, generation: generation, songID: songID)
            }
        }
        itemEndObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.didReachEnd(generation: generation, songID: songID) }
        }
        itemFailureObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] notification in
            let message = (notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error)?.localizedDescription
                ?? "本地缓存播放失败"
            MainActor.assumeIsolated {
                self?.failAndAdvance(generation: generation, songID: songID, message: message)
            }
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

    private func updatePosition(_ seconds: TimeInterval) {
        guard seconds.isFinite,
              seconds >= 0,
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
        guard queue.indices.contains(index) else { return }
        let songID = queue[index].id
        let quality = playbackQuality
        let expectedLevel = quality == .best ? nil : quality.cacheComponent
        if let expectedLevel, let ready = cache.readyFile(for: songID, quality: expectedLevel) {
            prefetchedSongID = songID
            prefetchedSourceURL = ready
            prefetchedAvailability = .playable(level: expectedLevel)
            return
        }

        prefetchTask = Task { @MainActor [weak self, repository, cache] in
            do {
                let source = try await repository.playbackSource(for: songID, quality: quality)
                try Task.checkCancellation()
                let level = source.availability.level ?? expectedLevel ?? "standard"
                let sourceURL = cache.readyFile(for: songID, quality: level) ?? source.url
                guard let self,
                      self.playbackGeneration == generation,
                      self.queue.indices.contains(index),
                      self.queue[index].id == songID
                else { return }
                self.prefetchedSongID = songID
                self.prefetchedSourceURL = sourceURL
                self.prefetchedAvailability = source.availability
                let isTrial = if case .trial = source.availability { true } else { false }
                if !sourceURL.isFileURL && !isTrial,
                   let cached = try? await cache.cache(songID: songID, quality: level, from: sourceURL) {
                    guard self.playbackGeneration == generation else { return }
                    self.prefetchedSourceURL = cached
                }
                guard self.playbackGeneration == generation else { return }
                self.prefetchTask = nil
            } catch {
                guard let self, self.playbackGeneration == generation else { return }
                self.prefetchTask = nil
            }
        }
    }

    private func updateDuration(_ seconds: TimeInterval, generation: Int, songID: Int64) {
        guard isCurrent(generation: generation, songID: songID), seconds.isFinite, seconds > 0 else { return }
        guard abs(mediaDuration - seconds) > 0.05 else { return }
        mediaDuration = seconds
    }

    private func updateItemStatus(rawValue: Int, generation: Int, songID: Int64) {
        guard isCurrent(generation: generation, songID: songID),
              let status = AVPlayerItem.Status(rawValue: rawValue)
        else { return }

        switch status {
        case .readyToPlay:
            updateDuration(avPlayer.currentItem?.duration.seconds ?? 0, generation: generation, songID: songID)
            if let pendingSeek {
                self.pendingSeek = nil
                seekLocally(to: pendingSeek)
            }
            if wantsPlayback {
                avPlayer.play()
            } else {
                state = .paused(songID: songID)
            }
        case .failed:
            failAndAdvance(
                generation: generation,
                songID: songID,
                message: avPlayer.currentItem?.error?.localizedDescription ?? "本地缓存播放失败"
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
            state = .playing(songID: songID)
            let startedNewSession = startPlaybackTiming(for: songID)
            if currentSong?.podcastEpisodeID == nil,
               startedNewSession,
               let sourceID = timedPlaybackSourceID,
               let totalSeconds = timedPlaybackTotalSeconds {
                playbackStartReportTask = Task { @MainActor [weak self, repository] in
                    do {
                        try await repository.recordPlaybackStart(
                            for: songID,
                            sourceID: sourceID,
                            totalSeconds: totalSeconds
                        )
                        self?.lastPlaybackReportWasPodcast = false
                        self?.playbackReportErrorMessage = nil
                        self?.playbackReportRevision += 1
                        return true
                    } catch {
                        self?.playbackReportErrorMessage = Self.playbackReportMessage(for: error)
                        return false
                    }
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
        position = 0
        updateCurrentLyricIndex()
        avPlayer.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
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
        let startReportTask = playbackStartReportTask
        let seconds = Int(listenedDuration.components.seconds)
        let podcastEpisodeID = currentSong?.podcastEpisodeID
        let positionMilliseconds = Int(position * 1_000)
        let completed = duration > 0 && position >= duration - 1
        timedPlaybackSongID = nil
        timedPlaybackSourceID = nil
        timedPlaybackTotalSeconds = nil
        playbackStartReportTask = nil
        listenedDuration = .zero
        guard let songID, seconds > 0 else { return }
        Task { @MainActor [weak self, repository] in
            do {
                if let podcastEpisodeID, positionMilliseconds > 0 {
                    try await repository.recordPodcastPlayback(
                        for: podcastEpisodeID,
                        positionMilliseconds: positionMilliseconds,
                        completed: completed
                    )
                    self?.lastPlaybackReportWasPodcast = true
                    self?.playbackReportErrorMessage = nil
                } else {
                    guard let sourceID, let totalSeconds else { return }
                    let startSucceeded = await startReportTask?.value
                    try await repository.recordPlayback(
                        for: songID,
                        sourceID: sourceID,
                        playedSeconds: seconds,
                        totalSeconds: totalSeconds
                    )
                    self?.lastPlaybackReportWasPodcast = false
                    if startSucceeded != false { self?.playbackReportErrorMessage = nil }
                }
                self?.playbackReportRevision += 1
            } catch {
                self?.playbackReportErrorMessage = Self.playbackReportMessage(for: error)
            }
        }
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
        Task { @MainActor [weak self, repository] in
            do {
                try await repository.recordPodcastPlayback(
                    for: episodeID,
                    positionMilliseconds: Int(seconds * 1_000),
                    completed: false
                )
                self?.lastPlaybackReportWasPodcast = true
                self?.playbackReportErrorMessage = nil
                self?.playbackReportRevision += 1
            } catch {
                self?.playbackReportErrorMessage = Self.playbackReportMessage(for: error)
            }
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
        prefetchedSongID = nil
        prefetchedSourceURL = nil
        prefetchedAvailability = nil
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
