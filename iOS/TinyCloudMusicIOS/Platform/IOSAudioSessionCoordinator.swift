import AVFoundation
import MediaPlayer
import Observation
import UIKit

enum IOSExternalPlaybackState: Equatable {
    case idle, loading, playing, paused
    case failed(String)
}

@MainActor
@Observable
final class IOSAudioSessionCoordinator {
    weak var player: PlayerController?
    private(set) var externalPlayer: AVPlayer?
    private(set) var ownsExternalPlayback = false
    private(set) var externalState: IOSExternalPlaybackState = .idle

    @ObservationIgnored private var externalStatusObserver: NSKeyValueObservation?
    @ObservationIgnored private var externalItemObserver: NSKeyValueObservation?
    @ObservationIgnored private var externalTimeObserver: Any?
    @ObservationIgnored private var externalTitle = ""
    @ObservationIgnored private var externalCreator = ""
    @ObservationIgnored private var externalIsLive = false
    @ObservationIgnored private var interruptedExternalID: ObjectIdentifier?

    private var interruptionObserver: NSObjectProtocol?
    private var routeObserver: NSObjectProtocol?
    private var remoteCommandTargets: [(MPRemoteCommand, Any)] = []
    private var shouldResumeAfterInterruption = false
    private var metadataSongID: Int64?
    private var artworkTask: Task<Void, Never>?
    private var isConfigured = false
    private var isActive = false

    func setExternalPlayer(_ external: AVPlayer, title: String, creator: String, isLive: Bool = false, shouldPlay: Bool = true) {
        if shouldPlay { try? activateForPlayback() }
        let keepsOwnership = ownsExternalPlayback
        endExternalPlayback(externalPlayer)
        externalPlayer = external
        externalTitle = title
        externalCreator = creator
        externalIsLive = isLive
        ownsExternalPlayback = shouldPlay || keepsOwnership
        if ownsExternalPlayback { player?.pauseForVideo() }
        externalState = shouldPlay ? .loading : .paused
        externalStatusObserver = external.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in self?.updateExternalState() }
        }
        externalItemObserver = external.currentItem?.observe(\.status, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in self?.updateExternalState() }
        }
        externalTimeObserver = external.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 1, preferredTimescale: 600), queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.updateExternalState() }
        }
        if shouldPlay { external.play() }
        updateExternalState()
    }

    func endExternalPlayback(_ external: AVPlayer?) {
        guard let external, external === externalPlayer else { return }
        external.pause()
        externalStatusObserver = nil
        externalItemObserver = nil
        if let externalTimeObserver { external.removeTimeObserver(externalTimeObserver) }
        externalTimeObserver = nil
        externalPlayer = nil
        ownsExternalPlayback = false
        externalState = .idle
        metadataSongID = nil
        syncNowPlaying()
    }

    func musicPlaybackWillStart() {
        try? activateForPlayback()
        ownsExternalPlayback = false
        externalPlayer?.pause()
        if externalPlayer != nil { externalState = .paused }
        metadataSongID = nil
    }

    func state(for external: AVPlayer?) -> IOSExternalPlaybackState {
        guard let external, external === externalPlayer else { return .idle }
        return externalState
    }

    private func updateExternalState() {
        guard let external = externalPlayer else { return }
        if external.currentItem?.status == .failed {
            externalState = .failed(external.currentItem?.error?.localizedDescription ?? "无法播放，请重试")
        } else {
            switch external.timeControlStatus {
            case .playing: externalState = .playing
            case .waitingToPlayAtSpecifiedRate: externalState = .loading
            case .paused: externalState = .paused
            @unknown default: externalState = .paused
            }
            if external.timeControlStatus != .paused, !ownsExternalPlayback {
                ownsExternalPlayback = true
                player?.pauseForVideo()
            }
        }
        if ownsExternalPlayback { syncNowPlaying() }
    }

    private func setPlayback(_ shouldPlay: Bool) {
        if ownsExternalPlayback, let externalPlayer {
            if shouldPlay { externalPlayer.play() } else { externalPlayer.pause() }
        } else {
            player?.setPlayback(shouldPlay)
        }
    }

    private var isPlaybackRequested: Bool {
        ownsExternalPlayback ? externalPlayer?.timeControlStatus != .paused : player?.isPlaybackRequested == true
    }

    func activate() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default)
        guard !isConfigured else { return }
        isConfigured = true
        installAudioObservers(for: session)
        installRemoteCommands()
        syncNowPlaying()
        observePlayer()
    }

    func activateForPlayback() throws {
        try activate()
        guard !isActive else { return }
        try AVAudioSession.sharedInstance().setActive(true)
        isActive = true
    }

    private func installAudioObservers(for session: AVAudioSession) {
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: session,
            queue: .main
        ) { [weak self] notification in
            let type = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let options = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            Task { @MainActor in self?.handleInterruption(type: type, options: options, session: session) }
        }
        routeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: session,
            queue: .main
        ) { [weak self] notification in
            let reason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            Task { @MainActor in self?.handleRouteChange(reason: reason) }
        }
    }

    private func handleInterruption(type value: UInt?, options rawOptions: UInt, session: AVAudioSession) {
        guard let value,
              let type = AVAudioSession.InterruptionType(rawValue: value)
        else { return }

        switch type {
        case .began:
            shouldResumeAfterInterruption = isPlaybackRequested
            interruptedExternalID = ownsExternalPlayback ? externalPlayer.map(ObjectIdentifier.init) : nil
            setPlayback(false)
        case .ended:
            let mayResume = AVAudioSession.InterruptionOptions(rawValue: rawOptions).contains(.shouldResume)
            guard shouldResumeAfterInterruption, mayResume else {
                shouldResumeAfterInterruption = false
                return
            }
            shouldResumeAfterInterruption = false
            if let interruptedExternalID {
                guard ownsExternalPlayback, externalPlayer.map(ObjectIdentifier.init) == interruptedExternalID else { return }
            } else if ownsExternalPlayback { return }
            try? session.setActive(true)
            isActive = true
            setPlayback(true)
        @unknown default:
            shouldResumeAfterInterruption = false
        }
    }

    private func handleRouteChange(reason value: UInt?) {
        guard let value,
              AVAudioSession.RouteChangeReason(rawValue: value) == .oldDeviceUnavailable
        else { return }
        setPlayback(false)
    }

    private func installRemoteCommands() {
        guard remoteCommandTargets.isEmpty else { return }
        let center = MPRemoteCommandCenter.shared()

        addTarget(to: center.playCommand) { $0.setPlayback(true) }
        addTarget(to: center.pauseCommand) { $0.setPlayback(false) }
        addTarget(to: center.togglePlayPauseCommand) { $0.setPlayback(!$0.isPlaybackRequested) }
        addTarget(to: center.nextTrackCommand) { if !$0.ownsExternalPlayback { $0.player?.next() } }
        addTarget(to: center.previousTrackCommand) { if !$0.ownsExternalPlayback { $0.player?.previous() } }

        let positionTarget = center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let position = event.positionTime
            Task { @MainActor in
                guard let self else { return }
                if self.ownsExternalPlayback, !self.externalIsLive {
                    self.externalPlayer?.seek(to: CMTime(seconds: position, preferredTimescale: 600))
                } else if !self.ownsExternalPlayback { self.player?.seek(to: position) }
            }
            return .success
        }
        remoteCommandTargets.append((center.changePlaybackPositionCommand, positionTarget))
    }

    private func addTarget(to command: MPRemoteCommand, action: @escaping @MainActor (IOSAudioSessionCoordinator) -> Void) {
        let target = command.addTarget { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                action(self)
            }
            return .success
        }
        remoteCommandTargets.append((command, target))
    }

    private func observePlayer() {
        guard let player else { return }
        withObservationTracking {
            _ = player.currentSong
            _ = player.duration
            _ = player.state
            _ = player.playbackPositionRevision
            _ = player.canGoPrevious
            _ = player.canGoNext
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.syncNowPlaying()
                self?.observePlayer()
            }
        }
    }

    private func syncNowPlaying() {
        if ownsExternalPlayback, let externalPlayer {
            artworkTask?.cancel()
            artworkTask = nil
            metadataSongID = nil
            var info: [String: Any] = [
                MPMediaItemPropertyTitle: externalTitle,
                MPMediaItemPropertyArtist: externalCreator,
                MPNowPlayingInfoPropertyIsLiveStream: externalIsLive,
                MPNowPlayingInfoPropertyPlaybackRate: externalPlayer.rate
            ]
            let duration = externalPlayer.currentItem?.duration.seconds ?? 0
            let position = externalPlayer.currentTime().seconds
            if duration.isFinite, duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = duration }
            if position.isFinite { info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = position }
            let center = MPNowPlayingInfoCenter.default()
            center.nowPlayingInfo = info
            center.playbackState = externalState == .playing ? .playing : .paused
            let commands = MPRemoteCommandCenter.shared()
            let failed: Bool = if case .failed = externalState { true } else { false }
            commands.playCommand.isEnabled = !isPlaybackRequested && !failed
            commands.pauseCommand.isEnabled = isPlaybackRequested
            commands.togglePlayPauseCommand.isEnabled = !failed
            commands.nextTrackCommand.isEnabled = false
            commands.previousTrackCommand.isEnabled = false
            commands.changePlaybackPositionCommand.isEnabled = !externalIsLive && duration.isFinite && duration > 0
            return
        }
        guard let player, let song = player.currentSong else {
            metadataSongID = nil
            artworkTask?.cancel()
            artworkTask = nil
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            MPNowPlayingInfoCenter.default().playbackState = .stopped
            return
        }

        let center = MPNowPlayingInfoCenter.default()
        var info = metadataSongID == song.id ? center.nowPlayingInfo ?? [:] : [
            MPMediaItemPropertyTitle: song.primaryName,
            MPMediaItemPropertyArtist: song.artistsDisplay,
            MPMediaItemPropertyAlbumTitle: song.album.name
        ]
        info[MPMediaItemPropertyPlaybackDuration] = player.duration
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = player.position
        info[MPNowPlayingInfoPropertyPlaybackRate] = player.isPlaying ? 1 : 0
        center.nowPlayingInfo = info
        center.playbackState = player.isPlaying ? .playing : .paused

        let commands = MPRemoteCommandCenter.shared()
        commands.playCommand.isEnabled = !player.isPlaybackRequested
        commands.pauseCommand.isEnabled = player.isPlaybackRequested
        commands.togglePlayPauseCommand.isEnabled = true
        commands.previousTrackCommand.isEnabled = player.canGoPrevious
        commands.nextTrackCommand.isEnabled = player.canGoNext
        commands.changePlaybackPositionCommand.isEnabled = player.duration > 0

        guard metadataSongID != song.id else { return }
        metadataSongID = song.id
        artworkTask?.cancel()
        guard let request = ArtworkPipeline.request(
            for: song.album.artwork.remoteURL,
            size: CGSize(width: 512, height: 512),
            displayScale: 2
        ) else { return }
        artworkTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let image = try await ArtworkPipeline.shared.loadImage(for: request)
                try Task.checkCancellation()
                guard self.metadataSongID == song.id else { return }
                var updated = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
                updated[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size) { @Sendable _ in image }
                MPNowPlayingInfoCenter.default().nowPlayingInfo = updated
            } catch {
                return
            }
        }
    }
}
