import AVFoundation
import MediaPlayer
import Observation
import UIKit

@MainActor
final class IOSAudioSessionCoordinator {
    weak var player: PlayerController?

    private var interruptionObserver: NSObjectProtocol?
    private var routeObserver: NSObjectProtocol?
    private var remoteCommandTargets: [(MPRemoteCommand, Any)] = []
    private var shouldResumeAfterInterruption = false
    private var metadataSongID: Int64?
    private var artworkTask: Task<Void, Never>?

    func activate() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default)
        try session.setActive(true)
        installAudioObservers(for: session)
        installRemoteCommands()
        syncNowPlaying()
        observePlayer()
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
            shouldResumeAfterInterruption = player?.isPlaybackRequested == true
            player?.setPlayback(false)
        case .ended:
            let mayResume = AVAudioSession.InterruptionOptions(rawValue: rawOptions).contains(.shouldResume)
            guard shouldResumeAfterInterruption, mayResume else {
                shouldResumeAfterInterruption = false
                return
            }
            shouldResumeAfterInterruption = false
            try? session.setActive(true)
            player?.setPlayback(true)
        @unknown default:
            shouldResumeAfterInterruption = false
        }
    }

    private func handleRouteChange(reason value: UInt?) {
        guard let value,
              AVAudioSession.RouteChangeReason(rawValue: value) == .oldDeviceUnavailable
        else { return }
        player?.setPlayback(false)
    }

    private func installRemoteCommands() {
        guard remoteCommandTargets.isEmpty else { return }
        let center = MPRemoteCommandCenter.shared()

        addTarget(to: center.playCommand) { $0.player?.setPlayback(true) }
        addTarget(to: center.pauseCommand) { $0.player?.setPlayback(false) }
        addTarget(to: center.togglePlayPauseCommand) { $0.player?.togglePlayback() }
        addTarget(to: center.nextTrackCommand) { $0.player?.next() }
        addTarget(to: center.previousTrackCommand) { $0.player?.previous() }

        let positionTarget = center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            Task { @MainActor in self?.player?.seek(to: event.positionTime) }
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
