import AppKit
import AVFoundation
import CryptoKit
import Foundation
import Observation
import SwiftUI
import Testing
@testable import TinyCloudMusic

@Suite("Player queue and bounded work", .serialized)
struct PlayerCachePerformanceTests {
    @Test("Now Playing isolates progress observation and has no fixed root height")
    func nowPlayingStructure() throws {
        let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let sourceRoot = tests
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Sources/TinyCloudMusic")
        let text = try String(
            contentsOf: sourceRoot.appending(path: "NowPlayingDetailView.swift"),
            encoding: .utf8
        )
        let playerText = try String(
            contentsOf: sourceRoot.appending(path: "PlayerController.swift"),
            encoding: .utf8
        )

        #expect(text.contains("private struct PlaybackProgress: View"))
        #expect(!text.contains(".frame(height: 720)"))
        let controls = try #require(text.range(of: "struct PlaybackControls: View"))
        let progress = try #require(text.range(of: "private struct PlaybackProgress: View"))
        let detail = try #require(text.range(of: "struct NowPlayingDetailView: View"))
        let queue = try #require(text.range(of: "private struct PlaybackQueueView: View"))
        let lyrics = try #require(text.range(of: "private struct LyricsPane: View"))
        let queueText = text[queue.lowerBound..<lyrics.lowerBound]
        #expect(!text[controls.lowerBound..<progress.lowerBound].contains("player.position"))
        #expect(text[progress.lowerBound..<detail.lowerBound].contains("player.displayedPosition"))
        #expect(text.contains("let playbackMilliseconds = isCurrent ? Int64(player.position * 1_000) : 0"))
        #expect(text.contains("player.resolveQueueSongs(visibleAround: item.id)"))
        #expect(queueText.contains("LazyVStack"))
        #expect(!queueText.contains("List("))
        #expect(!playerText.contains("cache.cache("))
        #expect(!playerText.contains("selectedQualityCacheTasks"))
        #expect(!playerText.contains("fillSelectedQualityCache"))
        #expect(!playerText.contains("cancelSelectedQualityCacheFills"))
        let qualitySwitch = try #require(playerText.range(of: "func selectPlaybackQuality"))
        let prefetch = try #require(playerText.range(of: "private func prefetchNext"))
        let synchronization = try #require(playerText.range(of: "private func startSynchronizedStandbyPlayback"))
        let pausedSynchronization = try #require(playerText.range(of: "private func promotePausedQualitySwitch"))
        #expect(prefetch.lowerBound > qualitySwitch.lowerBound)
        #expect(!playerText.contains("pendingCacheFill"))
        #expect(playerText.contains("AVURLAssetPreferPreciseDurationAndTimingKey"))
        let rangeItem = try #require(playerText.range(of: "private func makeRangePlayerItem"))
        let rangeFormat = try #require(playerText.range(of: "private static func rangeFormat"))
        #expect(playerText[rangeItem.lowerBound..<rangeFormat.lowerBound].contains(
            "preferPreciseTiming: format == \"flac\""
        ))
        let directItem = try #require(playerText.range(of: "private static func makePlayerItem"))
        let directFallback = try #require(playerText.range(of: "private static func validatedDirectFallback"))
        let directItemText = playerText[directItem.lowerBound..<directFallback.lowerBound]
        #expect(directItemText.contains("sourceURL.pathExtension.lowercased() == \"flac\""))
        #expect(directItemText.contains("format?.lowercased() == \"flac\""))
        #expect(playerText.contains("futureHostTime = CMTimeAdd(hostTime, lead)"))
        #expect(playerText.contains("private static let standbyHandoffLead: TimeInterval = 0.05"))
        #expect(playerText.contains("CMSyncConvertTime(futureHostTime, from: hostClock, to: $0)"))
        #expect(playerText.contains(
            "standbyPlayer.setRate(1, time: itemTime, atHostTime: futureHostTime)"
        ))
        #expect(playerText.contains("transitionDuration: 0.2"))
        #expect(playerText.contains("avPlayer.automaticallyWaitsToMinimizeStalling = false"))
        #expect(playerText.contains("standbyPlayer.automaticallyWaitsToMinimizeStalling = false"))
        #expect(!playerText.contains("automaticallyWaitsToMinimizeStalling = true"))
        #expect(playerText[synchronization.lowerBound..<pausedSynchronization.lowerBound].contains(
            "standbyHandoffTask = Task"
        ))
        #expect(playerText.contains("if wantsPlayback, avPlayer.timeControlStatus != .playing { avPlayer.play() }"))
        #expect(!playerText.contains("新的音频流无法保持同步"))
        #expect(playerText.components(separatedBy: "self.avPlayer.currentItem === item").count >= 3)
        #expect(playerText.contains("self.avPlayer === seekingPlayer"))
        #expect(playerText.contains("seekingPlayer.currentItem === seekingItem"))
        let seekRequest = try #require(playerText.range(of: "private func seekLocally"))
        let seekChasing = try #require(playerText.range(of: "private func startPendingSeekIfPossible"))
        let seekTolerance = try #require(playerText.range(of: "private func seekTolerance"))
        #expect(!playerText[seekRequest.lowerBound..<seekChasing.lowerBound].contains("cancelPendingSeeks"))
        #expect(playerText[seekChasing.lowerBound..<seekTolerance.lowerBound].contains("guard !seekInProgress"))
        #expect(!playerText[seekChasing.lowerBound..<seekTolerance.lowerBound].contains("toleranceBefore: .zero"))
        #expect(playerText.contains("self.avPlayer === observedPlayer"))
        #expect(playerText.contains("self.avPlayer === player"))
        #expect(!playerText[synchronization.lowerBound..<pausedSynchronization.lowerBound].contains("avPlayer.pause()"))
        let promotion = try #require(playerText.range(of: "private func promoteStandby"))
        #expect(!playerText[pausedSynchronization.lowerBound..<promotion.lowerBound].contains(
            "toleranceBefore: .zero"
        ))
        #expect(!playerText[pausedSynchronization.lowerBound..<promotion.lowerBound].contains(
            "toleranceAfter: .zero"
        ))
        let standbyStatus = try #require(playerText.range(of: "private func updateStandbyStatus"))
        let standbyPreroll = try #require(playerText.range(of: "private func beginStandbyPreroll"))
        let statusGuard = playerText[standbyStatus.lowerBound..<standbyPreroll.lowerBound]
        let statusSwitch = try #require(statusGuard.range(of: "switch status"))
        #expect(!statusGuard[..<statusSwitch.lowerBound].contains("preparationRevision"))
        #expect(playerText.contains("preparationRevision == self.standbyPreparationRevision"))
        let handoffCancel = try #require(playerText.range(of: "private func cancelStandbyHandoff"))
        let handoffInvalidate = try #require(playerText.range(of: "private func invalidateStandbyPreparation"))
        let cancelText = playerText[handoffCancel.lowerBound..<handoffInvalidate.lowerBound]
        #expect(cancelText.contains("standbyHandoffTask?.cancel()"))
        #expect(cancelText.contains("standbyHandoffTask = nil"))
        #expect(cancelText.contains("standbyPlayer.pause()"))
    }

    @Test("Pending seek position stays confined to progress display bindings")
    func seekDisplaySourceBoundaries() throws {
        let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let root = tests.deletingLastPathComponent().deletingLastPathComponent()
        func source(_ path: String) throws -> String {
            try String(contentsOf: root.appending(path: path), encoding: .utf8)
        }

        let macText = try source("Sources/TinyCloudMusic/NowPlayingDetailView.swift")
        let macProgressStart = try #require(macText.range(of: "private struct PlaybackProgress: View"))
        let macProgressEnd = try #require(macText.range(of: "struct NowPlayingLikeButton: View"))
        let macProgress = macText[macProgressStart.lowerBound..<macProgressEnd.lowerBound]
        #expect(macProgress.contains("isScrubbing ? scrubPosition : player.displayedPosition"))
        #expect(macProgress.contains("get: { displayedPosition }"))
        #expect(macProgress.contains("scrubPosition = player.displayedPosition"))
        #expect(macProgress.contains("Text(timeText(displayedPosition))"))
        #expect(!macProgress.contains("player.position"))
        let macReleaseStart = try #require(macProgress.range(of: "private func updateScrubbing"))
        let macReleaseEnd = try #require(macProgress.range(of: "private func timeText"))
        let macRelease = String(macProgress[macReleaseStart.lowerBound..<macReleaseEnd.lowerBound])
        #expect(macRelease.components(separatedBy: "player.seek(to: scrubPosition)").count == 2)

        let iosText = try source("iOS/TinyCloudMusicIOS/UI/Player/IOSPlayerViews.swift")
        let iosProgressStart = try #require(iosText.range(of: "private struct IOSPlaybackProgress: View"))
        let iosProgressEnd = try #require(iosText.range(of: "enum IOSDownloadAction: Equatable"))
        let iosProgress = iosText[iosProgressStart.lowerBound..<iosProgressEnd.lowerBound]
        #expect(iosProgress.contains("get: { isScrubbing ? scrubPosition : player.displayedPosition }"))
        #expect(iosProgress.contains("scrubPosition = player.displayedPosition"))
        #expect(iosProgress.contains(
            "Text(IOSDurationText.format(isScrubbing ? scrubPosition : player.displayedPosition))"
        ))
        let iosAccessibilityStart = try #require(iosProgress.range(of: ".accessibilityValue("))
        let iosTimeLabelStart = try #require(iosProgress.range(of: "HStack {"))
        let iosAccessibility = iosProgress[iosAccessibilityStart.lowerBound..<iosTimeLabelStart.lowerBound]
        #expect(iosAccessibility.contains("isScrubbing ? scrubPosition : player.displayedPosition"))
        #expect(!iosProgress.contains("player.position"))

        let macLyricsStart = try #require(macText.range(of: "private struct LyricsPane: View"))
        let macLyricsEnd = try #require(macText.range(of: "private struct LyricFillStyle"))
        let macLyrics = macText[macLyricsStart.lowerBound..<macLyricsEnd.lowerBound]
        #expect(macLyrics.contains("player.seek(to: TimeInterval(line.timestampMilliseconds) / 1_000)"))
        #expect(macLyrics.contains("Int64(player.position * 1_000)"))
        #expect(!macLyrics.contains("displayedPosition"))

        let iosLyricsStart = try #require(iosText.range(of: "private struct IOSLyricsView: View"))
        let iosLyricsEnd = try #require(iosText.range(of: "private struct IOSLyricFillStyle"))
        let iosLyrics = iosText[iosLyricsStart.lowerBound..<iosLyricsEnd.lowerBound]
        #expect(iosLyrics.contains("player.seek(to: TimeInterval(line.timestampMilliseconds) / 1_000)"))
        #expect(iosLyrics.contains("Int64(player.position * 1_000)"))
        #expect(!iosLyrics.contains("displayedPosition"))

        let playerText = try source("Sources/TinyCloudMusic/PlayerController.swift")
        let reportStart = try #require(playerText.range(of: "private func submitPlaybackIfNeeded"))
        let reportEnd = try #require(playerText.range(of: "private func launchPlaybackReport"))
        let report = playerText[reportStart.lowerBound..<reportEnd.lowerBound]
        #expect(report.contains("let positionMilliseconds = Int(position * 1_000)"))
        #expect(report.contains("let completed = duration > 0 && position >= duration - 1"))
        #expect(!report.contains("displayedPosition"))
        let lyricLookupStart = try #require(playerText.range(of: "private func updateCurrentLyricIndex"))
        let lyricLookupEnd = try #require(playerText.range(of: "private func isCurrent(generation:"))
        let lyricLookup = playerText[lyricLookupStart.lowerBound..<lyricLookupEnd.lowerBound]
        #expect(lyricLookup.contains("LRCParser.currentLineIndex(in: lyrics, at: Int64(position * 1_000))"))
        #expect(!lyricLookup.contains("displayedPosition"))

        let audioSessionText = try source("iOS/TinyCloudMusicIOS/Platform/IOSAudioSessionCoordinator.swift")
        let nowPlayingStart = try #require(audioSessionText.range(of: "private func syncNowPlaying"))
        let artworkStart = try #require(audioSessionText.range(of: "guard metadataSongID != song.id"))
        let nowPlaying = audioSessionText[nowPlayingStart.lowerBound..<artworkStart.lowerBound]
        #expect(nowPlaying.contains("MPNowPlayingInfoPropertyElapsedPlaybackTime] = player.position"))
        #expect(!nowPlaying.contains("displayedPosition"))

        let personalFMText = try source("Sources/TinyCloudMusic/PersonalFMView.swift")
        let trashStart = try #require(personalFMText.range(of: "func trashCurrent()"))
        let trashEnd = try #require(personalFMText.range(of: "private func beginSession"))
        let trash = personalFMText[trashStart.lowerBound..<trashEnd.lowerBound]
        #expect(trash.contains("player.position.isFinite ? max(1, Int(player.position)) : 25"))
        #expect(!trash.contains("displayedPosition"))

        let togetherText = try source("Sources/TinyCloudMusic/ListenTogetherController.swift")
        let hostReportStart = try #require(togetherText.range(of: "private func reportHostSnapshot"))
        let hostReportEnd = try #require(togetherText.range(of: "private func sendHostSnapshot"))
        let hostReport = togetherText[hostReportStart.lowerBound..<hostReportEnd.lowerBound]
        #expect(hostReport.contains("PlayerPlayIntent.play(songID: songID, progress: player.position)"))
        #expect(hostReport.contains("progress: player.position"))
        #expect(!hostReport.contains("displayedPosition"))
        let driftStart = try #require(togetherText.range(of: "private func applyPlayback"))
        let driftEnd = try #require(togetherText.range(of: "private func canApply"))
        let drift = togetherText[driftStart.lowerBound..<driftEnd.lowerBound]
        #expect(drift.contains("abs(player.position - progress)"))
        #expect(drift.contains("abs(self.player.position - expectedProgress)"))
        #expect(!drift.contains("displayedPosition"))
        let heartbeatStart = try #require(togetherText.range(of: "private func heartbeatLoop"))
        let heartbeatEnd = try #require(togetherText.range(of: "private func exitRoom"))
        let heartbeat = togetherText[heartbeatStart.lowerBound..<heartbeatEnd.lowerBound]
        #expect(heartbeat.contains("progress: milliseconds(player.position)"))
        #expect(!heartbeat.contains("displayedPosition"))
    }

    @MainActor
    @Test("Now Playing controls remain in bounds without overlap at supported heights")
    func nowPlayingHostingLayout() async {
        let suiteName = "TinyCloudMusicTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let root = performanceCacheRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = FixtureMusicRepository()
        let model = AppModel(repository: repository, defaults: defaults)
        let player = PlayerController(repository: repository, cacheRoot: root, crossfadeDuration: 0)
        let song = Song(
            id: 1,
            name: "A title long enough to exercise the two-line song heading",
            artists: [ArtistSummary(id: 1, name: "Artist")],
            album: AlbumSummary(
                id: 1,
                name: "Album",
                artwork: Artwork(symbol: "music.note", accent: .red)
            ),
            duration: .seconds(180)
        )
        player.play(song, in: [song])
        await waitUntil { player.currentSong?.id == song.id }
        #expect(player.currentSong?.id == song.id)
        let hosting = NSHostingView(rootView: NowPlayingDetailView(
            model: model,
            player: player,
            close: {}
        ))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 940, height: 720),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.orderFrontRegardless()
        var lyricsHeights: [CGFloat] = []

        for height in [CGFloat(720), 900, 1_100] {
            window.setContentSize(NSSize(width: 940, height: height))
            hosting.layoutSubtreeIfNeeded()
            hosting.displayIfNeeded()
            let allViews = playerSubviews(NSView.self, in: hosting)
            let controls = (
                allViews.filter { String(describing: type(of: $0)) == "KeyViewProxy" }
                    + playerSubviews(NSSlider.self, in: hosting).map { $0 as NSView }
            ).filter(playerIsVisible)
            #expect(controls.count >= 10)
            let frames = controls.map { $0.convert($0.bounds, to: hosting) }
            let bounds = hosting.bounds.insetBy(dx: -1, dy: -1)
            #expect(frames.allSatisfy(bounds.contains))
            for first in frames.indices {
                for second in frames.indices where second > first {
                    #expect(frames[first].intersection(frames[second]).isEmpty)
                }
            }
            let contentFrames = allViews
                .filter { $0 !== hosting && playerIsVisible($0) }
                .map { $0.convert($0.bounds, to: hosting) }
            let lyricHeight = contentFrames
                .filter { abs($0.width - hosting.bounds.width) < 1 && $0.minY >= 55 && $0.height > 100 }
                .map(\.height)
                .max() ?? 0
            #expect(lyricHeight > 0)
            lyricsHeights.append(lyricHeight)
        }

        #expect(lyricsHeights[0] < lyricsHeights[1])
        #expect(lyricsHeights[1] < lyricsHeights[2])
        window.close()
    }

    @MainActor
    @Test("Now Playing like is disabled while pending and restored after completion or account reset")
    func nowPlayingLikeMutationLifecycle() async throws {
        PlayerMutationProtocol.reset()
        let suiteName = "TinyCloudMusicTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let snapshot = CredentialSnapshot(.authenticated(try playerCredentials("account-a")))
        let revisionA = snapshot.load().revision
        let gate = PlayerReportGate(blocking: [.start])
        let blockAccountB = ObservationChangeCounter()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PlayerMutationProtocol.self]
        let transport = EAPITransport(
            session: URLSession(configuration: configuration),
            credentialSnapshot: snapshot,
            beforeSendingRequest: {
                let revision = snapshot.load().revision
                guard revision == revisionA || blockAccountB.value > 0 else { return }
                try? await gate.run(.start, revision: revision)
            }
        )
        let model = AppModel(
            repository: FixtureMusicRepository(),
            library: LiveMusicLibrary(transport: transport),
            extras: LiveMusicExtras(transport: transport),
            defaults: defaults
        )
        model.installConfirmedAccount(userID: 7, credentialRevision: revisionA)
        let clickRenderedButton = {
            let hosting = NSHostingView(rootView: NowPlayingLikeButton(model: model, songID: 42))
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 80, height: 60),
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false
            window.contentView = hosting
            window.orderFrontRegardless()
            defer { window.close() }
            hosting.layoutSubtreeIfNeeded()
            hosting.displayIfNeeded()
            guard let button = playerSubviews(NSView.self, in: hosting).first(where: {
                String(describing: type(of: $0)) == "KeyViewProxy"
            }) else { return false }
            let location = button.convert(
                NSPoint(x: button.bounds.midX, y: button.bounds.midY),
                to: nil
            )
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                guard let event = NSEvent.mouseEvent(
                    with: type,
                    location: location,
                    modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber,
                    context: nil,
                    eventNumber: 1,
                    clickCount: 1,
                    pressure: 1
                ) else { return false }
                window.sendEvent(event)
            }
            return true
        }
        #expect(clickRenderedButton())
        await waitUntil {
            await gate.invocationCount(.start, revision: revisionA) == 1
                && model.pendingMutations == [.songLike(42)]
        }
        #expect(model.pendingMutations == [.songLike(42)])

        #expect(!clickRenderedButton())
        await Task.yield()
        #expect(await gate.invocationCount(.start, revision: revisionA) == 1)

        await gate.release(revision: revisionA)
        await waitUntil {
            model.pendingMutations.isEmpty
                && model.likedSongIDs.contains(42)
        }
        #expect(PlayerMutationProtocol.count("/eapi/song/like") == 1)

        await Task.yield()
        #expect(clickRenderedButton())
        await waitUntil {
            await gate.invocationCount(.start, revision: revisionA) == 2
                && model.pendingMutations == [.songLike(42)]
        }
        #expect(await gate.invocationCount(.start, revision: revisionA) == 2)
        #expect(model.pendingMutations == [.songLike(42)])
        let revisionB = snapshot.store(.authenticated(try playerCredentials("account-b"))).revision
        await model.refreshAccountState()
        #expect(model.currentUserID == 8)
        #expect(model.pendingMutations.isEmpty)

        await gate.release(revision: revisionA)
        await waitUntil { await gate.cancellationCount(.start, revision: revisionA) == 1 }
        #expect(await gate.cancellationCount(.start, revision: revisionA) == 1)
        #expect(PlayerMutationProtocol.count("/eapi/song/like") == 1)

        blockAccountB.increment()
        #expect(clickRenderedButton())
        await waitUntil { await gate.invocationCount(.start, revision: revisionB) == 1 }
        #expect(await gate.invocationCount(.start, revision: revisionB) == 1)
        #expect(model.pendingMutations == [.songLike(42)])
        await gate.release(revision: revisionB)
        await waitUntil {
            PlayerMutationProtocol.count("/eapi/song/like") == 2
                && model.pendingMutations.isEmpty
                && model.likedSongIDs.contains(42)
        }
        #expect(model.likedSongIDs.contains(42))
    }

    @MainActor
    @Test("One hundred displayed seek updates invalidate progress but not non-progress controls")
    func positionObservationBoundary() async throws {
        let root = performanceCacheRoot()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "ticks.wav")
        try performanceWAV().write(to: source)
        let song = performanceSong(1)
        let player = PlayerController(
            repository: PlayerPerformanceRepository(songs: [song], sourceURL: source),
            cacheRoot: root.appending(path: "cache"),
            crossfadeDuration: 0
        )
        player.play(song, in: [song])
        await waitUntil { player.hasCurrentPlayerItem && !player.isLoadingLyrics && !player.isPreparing }

        let systemPosition = ObservationChangeCounter()
        let revision = player.playbackPositionRevision
        withObservationTracking {
            _ = player.playbackPositionRevision
        } onChange: {
            systemPosition.increment()
        }
        player.updatePosition(0.25)
        #expect(player.playbackPositionRevision == revision)
        #expect(systemPosition.value == 0)
        player.seek(to: 0.5)
        #expect(player.playbackPositionRevision == revision + 1)
        #expect(systemPosition.value == 1)

        player.setPlayback(false)
        player.seek(to: 0)

        let controls = ObservationChangeCounter()
        let progress = ObservationChangeCounter()
        for tick in 0..<100 {
            withObservationTracking {
                _ = player.isShuffleEnabled
                _ = player.isLinearQueueMode
                _ = player.currentSong
                _ = player.isLoadingHeartMode
                _ = player.isSharedControlActive
                _ = player.canGoPrevious
                _ = player.isPreparing
                _ = player.isPlaybackRequested
                _ = player.canGoNext
                _ = player.repeatMode
                _ = player.isControlInteractionLocked
            } onChange: {
                controls.increment()
            }
            withObservationTracking {
                _ = player.displayedPosition
            } onChange: {
                progress.increment()
            }
            player.seek(to: tick.isMultiple(of: 2) ? 0.25 : 0.5)
        }

        #expect(controls.value == 0)
        #expect(progress.value == 100)
        player.seek(to: 1.25)
        player.updatePosition(0.25)
        #expect(player.position == 0.25)
        #expect(player.displayedPosition == 1.25)
        #expect(player.currentLyric?.text == "first")
        await waitUntil { player.pendingSeekPosition == nil }
        #expect(abs(player.position - 1.25) <= 0.15)
        #expect(player.currentLyric?.text == "second")
    }

    @MainActor
    @Test("Playback resumes only after a current-item stall while intent remains active")
    func playbackStallRecovery() async throws {
        let root = performanceCacheRoot()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "stall-recovery.wav")
        try performanceWAV(seconds: 4).write(to: source)
        let song = performanceSong(1)
        let player = PlayerController(
            repository: PlayerPerformanceRepository(songs: [song], sourceURL: source),
            cacheRoot: root.appending(path: "cache"),
            crossfadeDuration: 0
        )
        player.play(song, in: [song])
        await waitUntil { player.isPlaying && player.position > 0.05 }
        let active = try #require(performanceAVPlayer(player, named: "avPlayer"))
        let stalledItem = try #require(active.currentItem)

        active.pause()
        await waitUntil { active.timeControlStatus == .paused }
        try await Task.sleep(for: .milliseconds(100))
        #expect(active.rate == 0)
        #expect(player.isPlaybackRequested)

        let stalledPosition = player.position
        NotificationCenter.default.post(name: .AVPlayerItemPlaybackStalled, object: stalledItem)
        await waitUntil { player.isPlaying && player.position > stalledPosition + 0.05 }
        #expect(active.rate > 0)

        player.setPlayback(false)
        await waitUntil { active.timeControlStatus == .paused }
        NotificationCenter.default.post(name: .AVPlayerItemPlaybackStalled, object: stalledItem)
        try await Task.sleep(for: .milliseconds(100))
        #expect(!player.isPlaybackRequested)
        #expect(active.rate == 0)
    }

    @MainActor
    @Test("Active seeks chase only the latest of twenty targets")
    func activeSeekChasing() async throws {
        let root = performanceCacheRoot()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "seek-chasing.wav")
        try performanceWAV().write(to: source)
        let song = performanceSong(1)
        let player = PlayerController(
            repository: PlayerPerformanceRepository(songs: [song], sourceURL: source),
            cacheRoot: root.appending(path: "cache"),
            crossfadeDuration: 0
        )
        player.play(song, in: [song])
        await waitUntil { player.hasCurrentPlayerItem && player.duration > 1.9 && !player.isPreparing }
        player.setPlayback(false)

        let revision = player.playbackPositionRevision
        let targets = (0..<20).map { 0.2 + Double($0) * 0.05 }
        for target in targets { player.seek(to: target) }

        let finalTarget = try #require(targets.last)
        #expect(player.playbackPositionRevision == revision + 20)
        #expect(player.pendingSeekPosition == finalTarget)
        #expect(player.displayedPosition == finalTarget)
        await waitUntil { player.pendingSeekPosition == nil }
        #expect(abs(player.position - finalTarget) <= 0.15)
        #expect(player.currentLyric?.text == "second")

        player.seek(to: 0)
        await waitUntil { player.pendingSeekPosition == nil }
        #expect(player.position >= 0 && player.position <= 0.15)

        let nearEnd = max(0, player.duration - 0.02)
        player.seek(to: nearEnd)
        await waitUntil { player.pendingSeekPosition == nil }
        #expect(player.position <= player.duration)
        #expect(abs(player.position - nearEnd) <= 0.15)
    }

    @MainActor
    @Test("A seek requested before item readiness is retained and executed")
    func pendingSeekUntilReady() async throws {
        let root = performanceCacheRoot()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "pending-seek.wav")
        try performanceWAV().write(to: source)
        let song = performanceSong(1)
        let sourceGate = PlayerPrefetchGate(songID: song.id)
        let repository = PlayerPerformanceRepository(
            songs: [song],
            sourceURL: source,
            prefetchGate: sourceGate
        )
        let player = PlayerController(
            repository: repository,
            cacheRoot: root.appending(path: "cache"),
            crossfadeDuration: 0
        )
        player.play(song, in: [song])
        await waitUntil { await sourceGate.invocationCount == 1 }

        player.seek(to: 0.75)
        #expect(player.pendingSeekPosition == 0.75)
        #expect(player.displayedPosition == 0.75)
        #expect(player.position == 0)

        await sourceGate.release(
            1,
            with: .success(PlaybackSource(url: source, availability: .playable(level: "standard")))
        )
        await waitUntil { player.hasCurrentPlayerItem && player.pendingSeekPosition == nil }
        #expect(abs(player.position - 0.75) <= 0.15)
    }

    @MainActor
    @Test("Same queue identity sends only play and FM sessions stay distinct")
    func queueIdentity() async {
        let songs = [performanceSong(1), performanceSong(2)]
        let repository = PlayerPerformanceRepository(songs: songs)
        let root = performanceCacheRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let player = PlayerController(repository: repository, cacheRoot: root, crossfadeDuration: 0)
        let firstSession = UUID()
        player.play(songs[0], in: songs, playlistID: 7, queueSessionID: firstSession)
        let originalIdentity = player.queueIdentity
        let intents = IntentRecorder()
        player.controlInterceptor = { intent, commit in
            intents.values.append(intent)
            commit()
            return true
        }

        player.play(songs[1], in: songs, playlistID: 7, queueSessionID: firstSession)

        #expect(intents.values.count == 1)
        #expect(intents.values[0].queue == nil)
        #expect(player.queueIdentity == originalIdentity)
        #expect(player.currentSongID == songs[1].id)

        player.play(songs[0], in: songs, playlistID: 7, queueSessionID: UUID())
        #expect(intents.values.last?.queue != nil)
        #expect(player.queueIdentity != originalIdentity)

        player.play(songs[1], in: songs, playlistID: 7)
        #expect(intents.values.last?.queue != nil)
        #expect(player.queueIdentity?.sessionID == nil)
    }

    @MainActor
    @Test("A 10000 item queue resolves only the selected missing song")
    func boundedSongResolution() async {
        let first = performanceSong(1)
        let repository = PlayerPerformanceRepository(songs: [first])
        let root = performanceCacheRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let player = PlayerController(repository: repository, cacheRoot: root, crossfadeDuration: 0)
        let ids = (1...10_000).map(Int64.init)

        player.play(first, in: [first], allSongIDs: ids)
        #expect(player.queue.count == ids.count)
        #expect(await repository.songRequests().isEmpty)

        player.playQueuedSong(10_000)
        await waitUntil { await repository.songRequests().count == 1 }

        #expect(await repository.songRequests() == [[10_000]])
        #expect(!player.isPreparing)
    }

    @MainActor
    @Test("A visible window resolves metadata without hydrating a 10000 item queue")
    func visibleQueueResolution() async throws {
        let songs = (1...10_000).map { performanceSong(Int64($0)) }
        let root = performanceCacheRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appending(path: "visible-queue.wav")
        try performanceWAV().write(to: source)
        let repository = PlayerPerformanceRepository(songs: songs, sourceURL: source)
        let player = PlayerController(repository: repository, cacheRoot: root, crossfadeDuration: 0)

        player.play(songs[0], in: [songs[0]], allSongIDs: songs.map(\.id))
        await waitUntil { player.hasCurrentPlayerItem && !player.isPreparing }
        player.setPlayback(false)
        player.resolveQueueSongs(visibleAround: 5_000)
        await waitUntil { player.queue[4_999].song != nil }

        let requests = await repository.songRequests()
        #expect(requests.count == 1)
        #expect(requests[0].count == 20)
        #expect(requests[0].contains(5_000))
        #expect(player.queue[4_999].song?.name == "Song 5000")
        #expect(player.queue[4_999].song?.artistsDisplay == "Artist")
        #expect(player.queue[4_999].song?.durationText == "2:00")
        #expect(player.queue.compactMap(\.song).count == 21)
    }

    @MainActor
    @Test("A replaced song resolution settles cancellation and the new target")
    func songResolutionCancellation() async {
        let first = performanceSong(1)
        let repository = PlayerPerformanceRepository(songs: [first], delayedSongID: 2)
        let root = performanceCacheRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let player = PlayerController(repository: repository, cacheRoot: root, crossfadeDuration: 0)

        player.play(first, in: [first], allSongIDs: [1, 2, 3])
        player.playQueuedSong(2)
        await waitUntil { await repository.songRequests() == [[2]] }
        player.playQueuedSong(3)
        await waitUntil {
            guard !player.isPreparing else { return false }
            return await repository.songResolutionCancellationCount() == 1
        }

        #expect(player.currentSongID == 3)
        #expect(!player.isPreparing)
        #expect(await repository.songRequests() == [[2], [3]])
    }

    @MainActor
    @Test("Selecting an unresolved target clears old audio before resolution fails")
    func unresolvedTargetStopsOldAudio() async throws {
        let first = performanceSong(1)
        let root = performanceCacheRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appending(path: "unresolved-target.wav")
        try performanceWAV().write(to: source)
        let repository = PlayerPerformanceRepository(songs: [first], sourceURL: source)
        let player = PlayerController(repository: repository, cacheRoot: root, crossfadeDuration: 0)

        player.play(first, in: [first], allSongIDs: [1, 2])
        await waitUntil { player.hasCurrentPlayerItem && !player.isPreparing }
        player.setPlayback(false)
        #expect(player.hasCurrentPlayerItem)

        player.playQueuedSong(2)
        #expect(!player.hasCurrentPlayerItem)
        await waitUntil { !player.isPreparing }

        #expect(!player.hasCurrentPlayerItem)
        if case let .failed(songID, _) = player.state {
            #expect(songID == 2)
        } else {
            Issue.record("Unresolved target did not settle as failed")
        }
    }

    @MainActor
    @Test("Player leaves network retry ownership to the transport")
    func noMultiplicativeRetry() async {
        let song = performanceSong(1)
        let repository = PlayerPerformanceRepository(songs: [song], sourceFails: true)
        let root = performanceCacheRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let player = PlayerController(repository: repository, cacheRoot: root, crossfadeDuration: 0)

        player.play(song, in: [song])
        await waitUntil { !player.isPreparing }

        #expect(await repository.sourceRequestCount() == 1)
    }

    @MainActor
    @Test("Player cache clearing is async and isolated to its configured root")
    func clearCache() async throws {
        let root = performanceCacheRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let player = PlayerController(
            repository: PlayerPerformanceRepository(songs: []),
            cacheRoot: root,
            crossfadeDuration: 0
        )

        try await player.clearCache()
    }

    @MainActor
    @Test("Clear unions old Range owners and pinned full-file owners after configure")
    func clearCacheOwnerUnion() async throws {
        let root = performanceCacheRoot()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        do {
            let audio = performanceWAV(seconds: 32, sampleRate: 44_100)
            let server = try LocalHTTPFixture(rangedBody: audio, contentType: "audio/wav")
            let port = try await server.start()
            defer { server.stop() }
            let source = performancePlaybackSource(
                url: URL(string: "http://127.0.0.1:\(port)/old-range.wav")!,
                level: "standard",
                format: "wav",
                representationData: audio
            )
            let key = TrackRangeCacheKey(songID: 1, quality: "standard")
            let oldTrackCache = TrackCache(directory: root.appending(path: "old-range-cache"))
            let oldRangeCache = TrackRangeCache(trackCache: oldTrackCache) { request in
                try await URLSession.shared.download(for: request)
            }
            try await seedPerformancePartial(key: key, source: source, rangeCache: oldRangeCache)
            let song = performanceSong(1)
            let player = PlayerController(
                repository: PlayerPerformanceRepository(songs: [song], levelSource: source),
                cache: oldTrackCache,
                crossfadeDuration: 0,
                rangeCache: oldRangeCache
            )
            player.play(song, in: [song])
            await waitUntil {
                performanceAVPlayer(player, named: "avPlayer")?.currentItem is RangeCachingPlayerItem
            }
            player.setPlayback(false)

            player.configure(
                playbackQuality: .standard,
                cacheRoot: root.appending(path: "new-range-root")
            )
            try await player.clearCache()

            #expect(await oldRangeCache.descriptor(for: key) == nil)
        }

        do {
            let audio = performanceWAV()
            let source = root.appending(path: "old-full-source.wav")
            try audio.write(to: source)
            let oldCache = TrackCache(directory: root.appending(path: "old-full-cache"))
            let cached = try await oldCache.storeCopy(
                of: source,
                for: 2,
                quality: "standard",
                fileExtension: "wav"
            )
            let song = performanceSong(2)
            do {
                let player = PlayerController(
                    repository: PlayerPerformanceRepository(songs: [song], sourceURL: source),
                    cache: oldCache,
                    crossfadeDuration: 0,
                    rangeCache: TrackRangeCache(trackCache: oldCache)
                )
                player.play(song, in: [song])
                await waitUntil {
                    performanceAVPlayer(player, named: "avPlayer")?.currentItem != nil
                }
                player.setPlayback(false)
                player.configure(
                    playbackQuality: .standard,
                    cacheRoot: root.appending(path: "new-full-root")
                )
                try await player.clearCache()

                #expect(await oldCache.readyFile(for: song.id, quality: "standard") == nil)
                #expect(FileManager.default.fileExists(atPath: cached.url.path))
            }

            await waitUntil {
                !FileManager.default.fileExists(atPath: cached.url.path)
            }
            #expect(
                !FileManager.default.fileExists(atPath: cached.url.path)
            )
        }
    }

    @MainActor
    @Test("Player routes exact full hits before repository and best hits by actual level")
    func fullAndBestCacheRouting() async throws {
        let root = performanceCacheRoot()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let audio = performanceWAV()
        let source = root.appending(path: "full.wav")
        try audio.write(to: source)

        do {
            let trackDownloads = ObservationChangeCounter()
            let rangeDownloads = ObservationChangeCounter()
            let cache = TrackCache(directory: root.appending(path: "exact-cache"), download: { _ in
                trackDownloads.increment()
                throw URLError(.unsupportedURL)
            })
            let cached = try await cache.storeCopy(
                of: source,
                for: 1,
                quality: "standard",
                fileExtension: "wav"
            )
            let rangeCache = TrackRangeCache(trackCache: cache) { _ in
                rangeDownloads.increment()
                throw URLError(.unsupportedURL)
            }
            let song = performanceSong(1)
            let repository = PlayerPerformanceRepository(songs: [song], sourceURL: source)
            let player = PlayerController(
                repository: repository,
                cache: cache,
                crossfadeDuration: 0,
                rangeCache: rangeCache
            )

            player.play(song, in: [song])
            await waitUntil { player.hasCurrentPlayerItem }
            player.setPlayback(false)

            let active = try #require(performanceAVPlayer(player, named: "avPlayer"))
            let asset = try #require(active.currentItem?.asset as? AVURLAsset)
            #expect(asset.url.standardizedFileURL == cached.url.standardizedFileURL)
            #expect(await repository.sourceRequestCount() == 0)
            #expect(rangeDownloads.value == 0)
            #expect(trackDownloads.value == 0)
        }

        do {
            let cache = TrackCache(directory: root.appending(path: "best-cache"))
            let cached = try await cache.storeCopy(
                of: source,
                for: 2,
                quality: "lossless",
                fileExtension: "wav"
            )
            let rangeDownloads = ObservationChangeCounter()
            let rangeCache = TrackRangeCache(trackCache: cache) { _ in
                rangeDownloads.increment()
                throw URLError(.unsupportedURL)
            }
            let song = performanceSong(2)
            let repository = PlayerPerformanceRepository(
                songs: [song],
                qualitySource: PlaybackSource(
                    url: URL(string: "http://127.0.0.1:9/best.wav")!,
                    availability: .playable(level: "lossless"),
                    format: "wav"
                )
            )
            let player = PlayerController(
                repository: repository,
                playbackQuality: .best,
                cache: cache,
                crossfadeDuration: 0,
                rangeCache: rangeCache
            )

            player.play(song, in: [song])
            await waitUntil { player.hasCurrentPlayerItem }
            player.setPlayback(false)

            let active = try #require(performanceAVPlayer(player, named: "avPlayer"))
            let asset = try #require(active.currentItem?.asset as? AVURLAsset)
            #expect(asset.url.standardizedFileURL == cached.url.standardizedFileURL)
            #expect(await repository.qualityRequests() == [.best])
            #expect(await repository.levelRequests().isEmpty)
            #expect(rangeDownloads.value == 0)
        }
    }

    @MainActor
    @Test("A cold partial descriptor defers the exact provider until a missing seek range")
    func partialDescriptorRouting() async throws {
        let root = performanceCacheRoot()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let audio = try performanceFLAC(in: root)
        let server = try LocalHTTPFixture(rangedBody: audio, contentType: "audio/flac")
        let port = try await server.start()
        defer { server.stop() }
        let source = performancePlaybackSource(
            url: URL(string: "http://127.0.0.1:\(port)/partial.flac")!,
            level: "standard",
            format: "flac",
            representationData: audio
        )
        let key = TrackRangeCacheKey(songID: 1, quality: "standard")
        let trackDownloads = ObservationChangeCounter()
        let trackCache = TrackCache(directory: root.appending(path: "StreamCache"), download: { _ in
            trackDownloads.increment()
            throw URLError(.unsupportedURL)
        })
        let rangeDownloads = ObservationChangeCounter()
        let rangeCache = TrackRangeCache(trackCache: trackCache) { request in
            rangeDownloads.increment()
            return try await URLSession.shared.download(for: request)
        }
        try await seedPerformancePartial(
            key: key,
            source: source,
            rangeCache: rangeCache,
            leadingBlocks: 8
        )
        let seedDownloadCount = rangeDownloads.value
        let song = performanceSong(1)
        let repository = PlayerPerformanceRepository(songs: [song], levelSource: source)
        let player = PlayerController(
            repository: repository,
            cache: trackCache,
            crossfadeDuration: 0,
            rangeCache: rangeCache
        )

        player.play(song, in: [song])
        player.setPlayback(false)
        for _ in 0..<300 {
            if performanceAVPlayer(player, named: "avPlayer")?.currentItem is RangeCachingPlayerItem {
                break
            }
            await Task.yield()
        }
        let active = try #require(performanceAVPlayer(player, named: "avPlayer"))
        let item = try #require(active.currentItem as? RangeCachingPlayerItem)

        #expect(await repository.sourceRequestCount() == 0)
        #expect(rangeDownloads.value == seedDownloadCount)

        player.seek(to: 18)
        await waitUntil { await repository.levelRequests() == ["standard"] }
        await waitUntil { item.status != .unknown }
        await waitUntil { player.pendingSeekPosition == nil }

        #expect(item.status == .readyToPlay)
        #expect(await repository.sourceRequestCount() == 1)
        #expect(await repository.levelRequests() == ["standard"])
        #expect(rangeDownloads.value > seedDownloadCount)
        #expect(trackDownloads.value == 0)
        #expect(active.currentItem === item)
    }

    @MainActor
    @Test("Only supported remote playable formats use Range items")
    func remoteRouteBoundaries() async throws {
        let root = performanceCacheRoot()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let localAIFF = root.appending(path: "local.aiff")
        try performanceWAV().write(to: localAIFF)
        let remote = URL(string: "http://127.0.0.1:9")!
        let cases: [(String, PlaybackSource, Bool)] = [
            (
                "trial",
                PlaybackSource(
                    url: remote.appending(path: "trial.flac"),
                    availability: .trial(level: "standard", endSeconds: 17),
                    format: "flac"
                ),
                false
            ),
            (
                "local-aiff",
                PlaybackSource(
                    url: localAIFF,
                    availability: .playable(level: "standard"),
                    format: "aiff"
                ),
                false
            ),
            (
                "remote-aiff",
                PlaybackSource(
                    url: remote.appending(path: "audio.aiff"),
                    availability: .playable(level: "standard"),
                    format: "aiff"
                ),
                false
            ),
            (
                "extensionless",
                PlaybackSource(
                    url: remote.appending(path: "extensionless"),
                    availability: .playable(level: "standard")
                ),
                false
            ),
            (
                "format-flac",
                PlaybackSource(
                    url: remote.appending(path: "format-only"),
                    availability: .playable(level: "standard"),
                    format: "flac"
                ),
                true
            ),
        ]

        for (index, route) in cases.enumerated() {
            let (name, source, expectsRange) = route
            let song = performanceSong(Int64(index + 1))
            let gate = AsyncGate()
            let trackDownloads = ObservationChangeCounter()
            let cache = TrackCache(
                directory: root.appending(path: "route-\(name)"),
                download: { _ in
                    trackDownloads.increment()
                    throw URLError(.unsupportedURL)
                }
            )
            let rangeCache = TrackRangeCache(trackCache: cache) { _ in
                await gate.wait()
                try Task.checkCancellation()
                throw URLError(.timedOut)
            }
            let repository = PlayerPerformanceRepository(songs: [song], levelSource: source)
            let player = PlayerController(
                repository: repository,
                cache: cache,
                crossfadeDuration: 0,
                rangeCache: rangeCache
            )

            player.play(song, in: [song])
            await waitUntil { performanceAVPlayer(player, named: "avPlayer")?.currentItem != nil }
            player.setPlayback(false)
            let active = try #require(performanceAVPlayer(player, named: "avPlayer"))
            let item = try #require(active.currentItem)
            #expect((item is RangeCachingPlayerItem) == expectsRange, "Case: \(name)")
            #expect(player.playbackAvailability == source.availability, "Case: \(name)")
            #expect(trackDownloads.value == 0, "Case: \(name)")
            let asset = try #require(item.asset as? AVURLAsset)
            if expectsRange {
                #expect(asset.url.scheme == "tcm-audio-cache", "Case: \(name)")
            } else {
                #expect(asset.url == source.url, "Case: \(name)")
            }
            await gate.release()
        }
    }

    @MainActor
    @Test("Invalid direct fallback URLs fail before ordinary item installation")
    func invalidDirectFallbackStopsBeforeInstallation() async throws {
        let root = performanceCacheRoot()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var missingHost = URLComponents()
        missingHost.scheme = "http"
        missingHost.path = "/direct.wav"
        let invalidURL = try #require(missingHost.url)
        let song = performanceSong(1)
        let sources = PlayerPrefetchGate(songID: song.id)
        let repository = PlayerPerformanceRepository(
            songs: [song],
            qualityGate: sources,
            qualityGateLevel: "standard"
        )
        let cache = TrackCache(directory: root.appending(path: "invalid"))
        let downloadGate = AsyncGate()
        let rangeCache = TrackRangeCache(trackCache: cache) { _ in
            await downloadGate.wait()
            throw URLError(.cancelled)
        }
        let player = PlayerController(
            repository: repository,
            cache: cache,
            crossfadeDuration: 0,
            rangeCache: rangeCache
        )

        player.play(song, in: [song])
        await waitUntil { await sources.invocationCount == 1 }
        await sources.release(1, with: .success(PlaybackSource(
            url: URL(string: "http://127.0.0.1:9/range.wav")!,
            availability: .playable(level: "standard"),
            format: "wav"
        )))
        await waitUntil {
            performanceAVPlayer(player, named: "avPlayer")?.currentItem is RangeCachingPlayerItem
        }
        let active = try #require(performanceAVPlayer(player, named: "avPlayer"))
        let rangeItem = try #require(active.currentItem as? RangeCachingPlayerItem)

        NotificationCenter.default.post(
            name: .AVPlayerItemFailedToPlayToEndTime,
            object: rangeItem
        )
        await waitUntil { await sources.invocationCount == 2 }
        await sources.release(2, with: .success(PlaybackSource(
            url: invalidURL,
            availability: .playable(level: "standard"),
            format: "wav"
        )))
        await waitUntil {
            if case .failed = player.state { return true }
            return false
        }
        await downloadGate.release()
        try await Task.sleep(for: .milliseconds(50))

        #expect(active.currentItem === rangeItem)
        #expect(await sources.invocationCount == 2)
        #expect(await repository.levelRequests() == ["standard", "standard"])
    }

    @MainActor
    @Test("An unverifiable Range item falls back to exact direct only once")
    func unverifiableRangeFallsBackOnce() async throws {
        let root = performanceCacheRoot()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let audio = performanceWAV()
        let rangeServer = try LocalHTTPFixture(rangedBody: audio, contentType: "audio/wav")
        let rangePort = try await rangeServer.start()
        defer { rangeServer.stop() }
        let directServer = try LocalHTTPFixture(response: fixtureHTTPResponse(
            "200 OK",
            headers: ["Content-Type": "text/html"],
            body: Data("not audio".utf8)
        ))
        let directPort = try await directServer.start()
        defer { directServer.stop() }

        let song = performanceSong(1)
        let sources = PlayerPrefetchGate(songID: song.id)
        let repository = PlayerPerformanceRepository(
            songs: [song],
            qualityGate: sources,
            qualityGateLevel: "standard"
        )
        let trackDownloads = ObservationChangeCounter()
        let cache = TrackCache(directory: root.appending(path: "fallback-cache"), download: { _ in
            trackDownloads.increment()
            throw URLError(.unsupportedURL)
        })
        let rangeDownloads = ObservationChangeCounter()
        let rangeCache = TrackRangeCache(trackCache: cache) { request in
            rangeDownloads.increment()
            return try await URLSession.shared.download(for: request)
        }
        let player = PlayerController(
            repository: repository,
            cache: cache,
            crossfadeDuration: 0,
            rangeCache: rangeCache
        )

        player.play(song, in: [song])
        await waitUntil { await sources.invocationCount == 1 }
        await sources.release(1, with: .success(PlaybackSource(
            url: URL(string: "http://127.0.0.1:\(rangePort)/unverifiable.wav")!,
            availability: .playable(level: "standard"),
            format: "wav"
        )))
        await waitUntil { await sources.invocationCount == 2 }

        let active = try #require(performanceAVPlayer(player, named: "avPlayer"))
        #expect(active.timeControlStatus != .playing)
        #expect(active.volume == 0)
        await sources.release(2, with: .success(PlaybackSource(
            url: URL(string: "http://127.0.0.1:\(directPort)/direct.wav")!,
            availability: .playable(level: "standard"),
            format: "wav"
        )))
        await waitUntil {
            if case .failed = player.state { return true }
            return false
        }
        try await Task.sleep(for: .milliseconds(100))

        #expect(await sources.invocationCount == 2)
        #expect(await repository.levelRequests() == ["standard", "standard"])
        #expect(rangeDownloads.value == 1)
        #expect(trackDownloads.value == 0)
        #expect(await rangeCache.descriptor(
            for: TrackRangeCacheKey(songID: song.id, quality: "standard")
        ) == nil)
        #expect(!(active.currentItem is RangeCachingPlayerItem))
        #expect(performanceAVPlayers(player).allSatisfy {
            !$0.automaticallyWaitsToMinimizeStalling
        })
    }

    @MainActor
    @Test("A quality promotion uses Range bytes without a second TrackCache download")
    func selectedQualityUsesSingleDownloadPath() async throws {
        let root = performanceCacheRoot()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let audio = performanceWAV()
        let source = root.appending(path: "current.wav")
        try audio.write(to: source)
        let server = try LocalHTTPFixture(rangedBody: audio, contentType: "audio/wav")
        let port = try await server.start()
        defer { server.stop() }
        let song = performanceSong(1)
        let masterSource = performancePlaybackSource(
            url: URL(string: "http://127.0.0.1:\(port)/selected-quality.wav")!,
            level: "jymaster",
            format: "wav",
            representationData: audio
        )
        let repository = PlayerPerformanceRepository(
            songs: [song],
            sourceURL: source,
            levelSource: masterSource
        )
        let downloads = ObservationChangeCounter()
        let cache = TrackCache(directory: root.appending(path: "StreamCache"), download: { _ in
            downloads.increment()
            throw URLError(.unsupportedURL)
        })
        let rangeDownloads = ObservationChangeCounter()
        let rangeCache = TrackRangeCache(trackCache: cache) { request in
            rangeDownloads.increment()
            return try await URLSession.shared.download(for: request)
        }
        let standard = SongQualityDetail(
            id: "standard",
            bitrate: 128_000,
            size: Int64(audio.count),
            sampleRate: 44_100,
            isAvailable: true
        )
        let master = SongQualityDetail(
            id: "jymaster",
            bitrate: 24_000_000,
            size: Int64(audio.count),
            sampleRate: 192_000,
            isAvailable: true
        )
        _ = try await cache.storeCopy(
            of: source,
            for: song.id,
            quality: standard.id,
            fileExtension: "wav"
        )
        let player = PlayerController(
            repository: repository,
            cacheRoot: root,
            cache: cache,
            crossfadeDuration: 0,
            rangeCache: rangeCache
        )

        player.play(song, in: [song])
        await waitUntil { player.isPlaying }
        player.selectPlaybackQuality(master)
        await waitUntil {
            player.currentPlaybackLevel == master.id && !player.isSwitchingPlaybackQuality
        }

        #expect(player.currentPlaybackLevel == master.id)
        #expect(!player.isSwitchingPlaybackQuality)
        #expect(downloads.value == 0)
        #expect(rangeDownloads.value > 0)
        let players = performanceAVPlayers(player)
        #expect(players.count == 2)
        #expect(players.allSatisfy { !$0.automaticallyWaitsToMinimizeStalling })

        await waitUntil { await cache.readyFile(for: song.id, quality: master.id) != nil }
        player.selectPlaybackQuality(standard)
        await waitUntil { player.currentPlaybackLevel == standard.id && !player.isSwitchingPlaybackQuality }
        player.selectPlaybackQuality(master)
        await waitUntil { player.currentPlaybackLevel == master.id && !player.isSwitchingPlaybackQuality }

        let requests = await repository.levelRequests()
        #expect(requests == [master.id])
        #expect(downloads.value == 0)
        #expect(performanceAVPlayers(player).allSatisfy {
            !$0.automaticallyWaitsToMinimizeStalling
        })
    }

    @MainActor
    @Test("Ten seeks during quality resolution keep one repository request")
    func seekDuringPendingQualityResolution() async throws {
        let root = performanceCacheRoot()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "pending-quality-seek.wav")
        try performanceWAV(seconds: 8).write(to: source)
        let song = performanceSong(1)
        let qualityGate = PlayerPrefetchGate(songID: song.id)
        let repository = PlayerPerformanceRepository(
            songs: [song],
            sourceURL: source,
            qualityGate: qualityGate,
            qualityGateLevel: "jymaster"
        )
        let player = PlayerController(
            repository: repository,
            cacheRoot: root.appending(path: "cache"),
            crossfadeDuration: 0
        )
        let master = SongQualityDetail(
            id: "jymaster",
            bitrate: 24_000_000,
            size: 1,
            sampleRate: 192_000,
            isAvailable: true
        )

        player.play(song, in: [song])
        await waitUntil { player.isPlaying && player.duration > 2 }
        player.selectPlaybackQuality(master)
        await waitUntil { await qualityGate.invocationCount == 1 }

        let targets = (0..<10).map { 0.3 + Double($0) * 0.08 }
        for target in targets { player.seek(to: target) }
        await waitUntil { player.pendingSeekPosition == nil }
        player.setPlayback(false)
        let confirmedPosition = player.position

        #expect(await qualityGate.invocationCount == 1)
        #expect(await qualityGate.wasCancelled(1) == nil)
        #expect(player.isSwitchingPlaybackQuality)
        await qualityGate.release(
            1,
            with: .success(PlaybackSource(
                url: source,
                availability: .playable(level: master.id),
                format: "wav"
            ))
        )
        await waitUntil {
            player.currentPlaybackLevel == master.id && !player.isSwitchingPlaybackQuality
        }

        #expect(await qualityGate.invocationCount == 1)
        #expect(await qualityGate.wasCancelled(1) == false)
        #expect(await repository.levelRequests() == ["standard", master.id])
        #expect(!player.isPlaybackRequested)
        #expect(abs(player.position - confirmedPosition) <= 0.15)
        #expect(performanceAVPlayers(player).allSatisfy {
            !$0.automaticallyWaitsToMinimizeStalling
        })
    }

    @MainActor
    @Test("A ready callback survives ten preparation revisions on one Range item")
    func standbyReadyRetargetKeepsRangeItem() async throws {
        let root = performanceCacheRoot()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let activeSource = root.appending(path: "active-before-range.wav")
        try performanceWAV(seconds: 8).write(to: activeSource)
        let rangeAudio = performanceWAV(seconds: 32, sampleRate: 44_100)
        let server = try LocalHTTPFixture(rangedBody: rangeAudio, contentType: "audio/wav")
        let port = try await server.start()
        defer { server.stop() }
        let qualitySource = performancePlaybackSource(
            url: URL(string: "http://127.0.0.1:\(port)/retarget.wav")!,
            level: "lossless",
            format: "wav",
            representationData: rangeAudio
        )
        let song = performanceSong(1)
        let qualityGate = PlayerPrefetchGate(songID: song.id)
        let repository = PlayerPerformanceRepository(
            songs: [song],
            sourceURL: activeSource,
            qualityGate: qualityGate,
            qualityGateLevel: "lossless"
        )
        let cache = TrackCache(directory: root.appending(path: "range-cache"))
        let firstOriginRequest = AsyncGate()
        defer { Task { await firstOriginRequest.release() } }
        let originRequests = ObservationChangeCounter()
        let rangeCache = TrackRangeCache(trackCache: cache) { request in
            if originRequests.increment() == 1 { await firstOriginRequest.wait() }
            try Task.checkCancellation()
            return try await URLSession.shared.download(for: request)
        }
        let player = PlayerController(
            repository: repository,
            cache: cache,
            crossfadeDuration: 0,
            rangeCache: rangeCache
        )
        let lossless = SongQualityDetail(
            id: "lossless",
            bitrate: 999_000,
            size: 1,
            sampleRate: 44_100,
            isAvailable: true
        )

        player.play(song, in: [song])
        await waitUntil { player.isPlaying && player.duration > 2 }
        player.selectPlaybackQuality(lossless)
        await waitUntil { await qualityGate.invocationCount == 1 }
        await qualityGate.release(1, with: .success(qualitySource))
        await waitUntil {
            guard performanceAVPlayer(player, named: "standbyPlayer")?.currentItem
                    is RangeCachingPlayerItem
            else { return false }
            return await firstOriginRequest.hasEntered()
        }
        let standby = try #require(performanceAVPlayer(player, named: "standbyPlayer"))
        let rangeItem = try #require(standby.currentItem as? RangeCachingPlayerItem)
        let revisionBeforeSeeks = try #require(performancePrivateInt(
            player,
            named: "standbyPreparationRevision"
        ))

        let targets = (0..<10).map { 0.4 + Double($0) * 0.08 }
        for target in targets { player.seek(to: target) }
        await waitUntil { player.pendingSeekPosition == nil }
        player.setPlayback(false)
        let confirmedPosition = player.position

        #expect(originRequests.value == 1)
        #expect(standby.currentItem === rangeItem)
        let revisionAfterSeeks = try #require(performancePrivateInt(
            player,
            named: "standbyPreparationRevision"
        ))
        #expect(revisionAfterSeeks >= revisionBeforeSeeks + 10)
        #expect(await repository.levelRequests() == ["standard", lossless.id])

        await firstOriginRequest.release()
        await waitUntil {
            player.currentPlaybackLevel == lossless.id && !player.isSwitchingPlaybackQuality
        }
        let active = try #require(performanceAVPlayer(player, named: "avPlayer"))

        #expect(active.currentItem === rangeItem)
        #expect(await repository.levelRequests() == ["standard", lossless.id])
        #expect(!player.isPlaybackRequested)
        #expect(abs(player.position - confirmedPosition) <= 0.15)
        let hasPartial = await rangeCache.descriptor(for: rangeItem.key) != nil
        let hasFull = await cache.readyFile(
            for: rangeItem.key.songID,
            quality: rangeItem.key.quality
        ) != nil
        #expect(hasPartial || hasFull)
    }

    @MainActor
    @Test("Pausing in the future handoff window retargets once and promotes silently")
    func pauseDuringStandbyHandoff() async throws {
        let root = performanceCacheRoot()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "pause-handoff.wav")
        try performanceWAV(seconds: 8).write(to: source)
        let song = performanceSong(1)
        let repository = PlayerPerformanceRepository(
            songs: [song],
            sourceURL: source,
            levelSourceURL: source
        )
        let player = PlayerController(
            repository: repository,
            cacheRoot: root.appending(path: "cache"),
            crossfadeDuration: 0
        )
        let lossless = SongQualityDetail(
            id: "lossless",
            bitrate: 999_000,
            size: 1,
            sampleRate: 44_100,
            isAvailable: true
        )

        player.play(song, in: [song])
        await waitUntil { player.isPlaying && player.duration > 2 }
        player.selectPlaybackQuality(lossless)
        await waitUntil { performanceHasPrivateOptional(player, named: "standbyHandoffTask") }
        try #require(performanceHasPrivateOptional(player, named: "standbyHandoffTask"))
        let standby = try #require(performanceAVPlayer(player, named: "standbyPlayer"))
        let scheduledItem = try #require(standby.currentItem)
        let oldActive = try #require(performanceAVPlayer(player, named: "avPlayer"))
        let revision = try #require(performancePrivateInt(
            player,
            named: "standbyPreparationRevision"
        ))

        #expect(oldActive.rate > 0)
        #expect(standby.volume == 0)
        #expect(player.isSwitchingPlaybackQuality)

        player.setPlayback(false)
        let pausedPosition = player.position

        #expect(!performanceHasPrivateOptional(player, named: "standbyHandoffTask"))
        let pausedRevision = try #require(performancePrivateInt(
            player,
            named: "standbyPreparationRevision"
        ))
        #expect(pausedRevision == revision + 1)
        #expect(performanceAVPlayers(player).allSatisfy { $0.rate == 0 })
        await waitUntil {
            player.currentPlaybackLevel == lossless.id && !player.isSwitchingPlaybackQuality
        }
        let active = try #require(performanceAVPlayer(player, named: "avPlayer"))

        #expect(active.currentItem === scheduledItem)
        #expect(!player.isPlaybackRequested)
        #expect(player.state == .paused(songID: song.id))
        #expect(abs(player.position - pausedPosition) <= 0.15)
        #expect(performanceAVPlayers(player).allSatisfy {
            $0.rate == 0 && !$0.automaticallyWaitsToMinimizeStalling
        })
    }

    @MainActor
    @Test("A real standby failure preserves the active item and playback intent")
    func failedQualityStandbyKeepsActivePlayback() async throws {
        let root = performanceCacheRoot()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "active-after-quality-failure.wav")
        try performanceWAV(seconds: 8).write(to: source)
        let song = performanceSong(1)
        let qualityGate = PlayerPrefetchGate(songID: song.id)
        let repository = PlayerPerformanceRepository(
            songs: [song],
            sourceURL: source,
            qualityGate: qualityGate,
            qualityGateLevel: "lossless"
        )
        let player = PlayerController(
            repository: repository,
            cacheRoot: root.appending(path: "cache"),
            crossfadeDuration: 0
        )
        let lossless = SongQualityDetail(
            id: "lossless",
            bitrate: 999_000,
            size: 1,
            sampleRate: 44_100,
            isAvailable: true
        )

        player.play(song, in: [song])
        await waitUntil { player.isPlaying && player.duration > 2 }
        let active = try #require(performanceAVPlayer(player, named: "avPlayer"))
        let activeItem = try #require(active.currentItem)
        let positionBeforeSwitch = player.position
        player.selectPlaybackQuality(lossless)
        await waitUntil { await qualityGate.invocationCount == 1 }
        await qualityGate.release(
            1,
            with: .success(PlaybackSource(
                url: root.appending(path: "missing-lossless.wav"),
                availability: .playable(level: lossless.id),
                format: "wav"
            ))
        )
        await waitUntil {
            player.playbackQualityErrorMessage != nil && !player.isSwitchingPlaybackQuality
        }

        #expect(active.currentItem === activeItem)
        #expect(player.isPlaybackRequested)
        #expect(player.isPlaying)
        #expect(player.position >= positionBeforeSwitch)
        #expect(player.selectedPlaybackLevel == nil)
        #expect(performanceAVPlayers(player).allSatisfy {
            !$0.automaticallyWaitsToMinimizeStalling
        })
    }

    @MainActor
    @Test("Seek, quality, track, failure, and deinit cancel a future handoff")
    func standbyHandoffCancellationWindows() async throws {
        let root = performanceCacheRoot()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "handoff-cancel.wav")
        try performanceWAV(seconds: 8).write(to: source)
        let lossless = SongQualityDetail(
            id: "lossless",
            bitrate: 999_000,
            size: 1,
            sampleRate: 44_100,
            isAvailable: true
        )
        let master = SongQualityDetail(
            id: "jymaster",
            bitrate: 24_000_000,
            size: 1,
            sampleRate: 192_000,
            isAvailable: true
        )

        do {
            let song = performanceSong(1)
            let repository = PlayerPerformanceRepository(
                songs: [song],
                sourceURL: source,
                levelSourceURL: source
            )
            let player = PlayerController(
                repository: repository,
                cacheRoot: root.appending(path: "seek-cache"),
                crossfadeDuration: 0
            )
            player.play(song, in: [song])
            await waitUntil { player.isPlaying && player.duration > 2 }
            player.selectPlaybackQuality(lossless)
            await waitUntil { performanceHasPrivateOptional(player, named: "standbyHandoffTask") }
            try #require(performanceHasPrivateOptional(player, named: "standbyHandoffTask"))
            let active = try #require(performanceAVPlayer(player, named: "avPlayer"))
            let originalItem = try #require(active.currentItem)
            let standby = try #require(performanceAVPlayer(player, named: "standbyPlayer"))
            let qualityItem = try #require(standby.currentItem)
            let revision = try #require(performancePrivateInt(
                player,
                named: "standbyPreparationRevision"
            ))

            player.seek(to: 1.2)

            #expect(!performanceHasPrivateOptional(player, named: "standbyHandoffTask"))
            #expect(active.currentItem === originalItem)
            #expect(standby.currentItem === qualityItem)
            #expect(standby.rate == 0)
            await waitUntil {
                guard player.pendingSeekPosition == nil,
                      performanceHasPrivateOptional(player, named: "standbyHandoffTask")
                else { return false }
                return (performancePrivateInt(
                    player,
                    named: "standbyPreparationRevision"
                ) ?? revision) > revision
            }
            await waitUntil { !player.isSwitchingPlaybackQuality }

            let promotedActive = try #require(performanceAVPlayer(player, named: "avPlayer"))
            #expect(promotedActive.currentItem === qualityItem)
            #expect(player.currentPlaybackLevel == lossless.id)
            #expect(abs(player.position - 1.2) <= 0.15)
            #expect(await repository.levelRequests() == ["standard", lossless.id])
        }

        do {
            let song = performanceSong(2)
            let repository = PlayerPerformanceRepository(
                songs: [song],
                sourceURL: source,
                levelSourceURL: source
            )
            let player = PlayerController(
                repository: repository,
                cacheRoot: root.appending(path: "quality-cache"),
                crossfadeDuration: 0
            )
            player.play(song, in: [song])
            await waitUntil { player.isPlaying && player.duration > 2 }
            player.selectPlaybackQuality(lossless)
            await waitUntil { performanceHasPrivateOptional(player, named: "standbyHandoffTask") }
            try #require(performanceHasPrivateOptional(player, named: "standbyHandoffTask"))
            let standby = try #require(performanceAVPlayer(player, named: "standbyPlayer"))
            let replacedItem = try #require(standby.currentItem)

            player.selectPlaybackQuality(master)

            #expect(!performanceHasPrivateOptional(player, named: "standbyHandoffTask"))
            #expect(standby.rate == 0)
            #expect(standby.currentItem !== replacedItem)
            await waitUntil {
                player.currentPlaybackLevel == master.id && !player.isSwitchingPlaybackQuality
            }
            let active = try #require(performanceAVPlayer(player, named: "avPlayer"))
            #expect(active.currentItem !== replacedItem)
            #expect(await repository.levelRequests() == ["standard", lossless.id, master.id])
        }

        do {
            let first = performanceSong(3)
            let second = performanceSong(4)
            let repository = PlayerPerformanceRepository(
                songs: [first, second],
                sourceURL: source,
                levelSourceURL: source
            )
            let player = PlayerController(
                repository: repository,
                cacheRoot: root.appending(path: "track-cache"),
                crossfadeDuration: 0
            )
            player.play(first, in: [first, second])
            await waitUntil { player.isPlaying && player.duration > 2 }
            player.selectPlaybackQuality(lossless)
            await waitUntil { performanceHasPrivateOptional(player, named: "standbyHandoffTask") }
            try #require(performanceHasPrivateOptional(player, named: "standbyHandoffTask"))
            let standby = try #require(performanceAVPlayer(player, named: "standbyPlayer"))
            let replacedItem = try #require(standby.currentItem)

            player.next()

            #expect(!performanceHasPrivateOptional(player, named: "standbyHandoffTask"))
            #expect(standby.rate == 0)
            await waitUntil { player.currentSongID == second.id && player.isPlaying }
            let active = try #require(performanceAVPlayer(player, named: "avPlayer"))
            #expect(active.currentItem !== replacedItem)
            #expect(!player.isSwitchingPlaybackQuality)
        }

        do {
            let song = performanceSong(5)
            let repository = PlayerPerformanceRepository(
                songs: [song],
                sourceURL: source,
                levelSourceURL: source
            )
            let player = PlayerController(
                repository: repository,
                cacheRoot: root.appending(path: "failure-cache"),
                crossfadeDuration: 0
            )
            player.play(song, in: [song])
            await waitUntil { player.isPlaying && player.duration > 2 }
            player.selectPlaybackQuality(lossless)
            await waitUntil { performanceHasPrivateOptional(player, named: "standbyHandoffTask") }
            try #require(performanceHasPrivateOptional(player, named: "standbyHandoffTask"))
            let active = try #require(performanceAVPlayer(player, named: "avPlayer"))
            let activeItem = try #require(active.currentItem)
            let standby = try #require(performanceAVPlayer(player, named: "standbyPlayer"))
            let positionAtFailure = player.position

            player.failQualitySwitch("fixture failure")

            #expect(!performanceHasPrivateOptional(player, named: "standbyHandoffTask"))
            #expect(standby.rate == 0)
            #expect(active.currentItem === activeItem)
            #expect(!player.isSwitchingPlaybackQuality)
            #expect(player.playbackQualityErrorMessage == "fixture failure")
            await waitUntil { player.position >= positionAtFailure + 0.12 }
            #expect(player.position >= positionAtFailure + 0.12)

            #expect(active.currentItem === activeItem)
            #expect(player.currentPlaybackLevel == "standard")
            #expect(player.isPlaybackRequested)
            #expect(player.isPlaying)
        }

        do {
            let song = performanceSong(6)
            let repository = PlayerPerformanceRepository(
                songs: [song],
                sourceURL: source,
                levelSourceURL: source
            )
            var player: PlayerController? = PlayerController(
                repository: repository,
                cacheRoot: root.appending(path: "deinit-cache"),
                crossfadeDuration: 0
            )
            weak let weakPlayer = player
            player?.play(song, in: [song])
            await waitUntil { player?.isPlaying == true && (player?.duration ?? 0) > 2 }
            player?.selectPlaybackQuality(lossless)
            await waitUntil {
                guard let player else { return false }
                return performanceHasPrivateOptional(player, named: "standbyHandoffTask")
            }
            try #require(player.map {
                performanceHasPrivateOptional($0, named: "standbyHandoffTask")
            } == true)
            let scheduledPlayer = try #require(player.flatMap {
                performanceAVPlayer($0, named: "standbyPlayer")
            })

            player = nil
            await waitUntil { weakPlayer == nil }

            #expect(weakPlayer == nil)
            #expect(scheduledPlayer.rate == 0)
        }
    }

    @MainActor
    @Test("Clearing cache fences a pending quality promotion")
    func clearCacheCancelsPendingQualitySwitch() async throws {
        let root = performanceCacheRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "pending-quality.wav")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try performanceWAV().write(to: source)
        let song = performanceSong(1)
        let qualityGate = PlayerPrefetchGate(songID: song.id)
        let repository = PlayerPerformanceRepository(
            songs: [song],
            sourceURL: source,
            qualityGate: qualityGate,
            qualityGateLevel: "jymaster"
        )
        let player = PlayerController(repository: repository, cacheRoot: root, crossfadeDuration: 0)
        let master = SongQualityDetail(
            id: "jymaster",
            bitrate: 24_000_000,
            size: 1,
            sampleRate: 192_000,
            isAvailable: true
        )

        player.play(song, in: [song])
        await waitUntil { player.isPlaying }
        player.selectPlaybackQuality(master)
        await waitUntil { await qualityGate.invocationCount == 1 }
        try await player.clearCache()
        await qualityGate.release(
            1,
            with: .success(PlaybackSource(url: source, availability: .playable(level: master.id)))
        )
        await waitUntil { await qualityGate.wasCancelled(1) == true }

        #expect(player.currentPlaybackLevel == "standard")
        #expect(!player.isSwitchingPlaybackQuality)
        let requests = await repository.levelRequests()
        #expect(requests == ["standard", master.id])
    }

    @MainActor
    @Test("Quality switch confirms only after standby promotion")
    func qualitySwitchConfirmation() async throws {
        let root = performanceCacheRoot()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "quality-switch.wav")
        try performanceWAV().write(to: source)
        let song = performanceSong(1)
        let player = PlayerController(
            repository: PlayerPerformanceRepository(
                songs: [song],
                sourceURL: source,
                levelSourceURL: source
            ),
            cacheRoot: root.appending(path: "cache"),
            crossfadeDuration: 0
        )
        let lossless = SongQualityDetail(
            id: "lossless",
            bitrate: 999_000,
            size: 1,
            sampleRate: 44_100,
            isAvailable: true
        )

        player.play(song, in: [song])
        await waitUntil { player.isPlaying }
        player.selectPlaybackQuality(lossless)
        #expect(player.playbackQualityConfirmationMessage == nil)
        await waitUntil { player.playbackQualityConfirmationMessage != nil }

        #expect(player.currentPlaybackLevel == lossless.id)
        #expect(player.playbackQualityConfirmationMessage == "已切换为无损音质")
        #expect(player.isPlaying)

        player.setPlayback(false)
        let pausedPosition = player.position
        let standard = SongQualityDetail(
            id: "standard",
            bitrate: 128_000,
            size: 1,
            sampleRate: 44_100,
            isAvailable: true
        )
        player.selectPlaybackQuality(standard)
        await waitUntil { player.currentPlaybackLevel == standard.id }

        #expect(!player.isPlaybackRequested)
        #expect(player.playbackQualityErrorMessage == nil)
        #expect(abs(player.position - pausedPosition) < 0.1)
    }

    @MainActor
    @Test("Only the latest rapid quality selection can be promoted")
    func latestQualitySwitchWins() async throws {
        let root = performanceCacheRoot()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "rapid-quality-switch.wav")
        try performanceWAV().write(to: source)
        let song = performanceSong(1)
        let repository = PlayerPerformanceRepository(
            songs: [song],
            sourceURL: source,
            levelSourceURL: source
        )
        let player = PlayerController(
            repository: repository,
            cacheRoot: root.appending(path: "cache"),
            crossfadeDuration: 0
        )
        let lossless = SongQualityDetail(
            id: "lossless",
            bitrate: 999_000,
            size: 1,
            sampleRate: 44_100,
            isAvailable: true
        )
        let master = SongQualityDetail(
            id: "jymaster",
            bitrate: 24_000_000,
            size: 1,
            sampleRate: 192_000,
            isAvailable: true
        )
        let standard = SongQualityDetail(
            id: "standard",
            bitrate: 128_000,
            size: 1,
            sampleRate: 44_100,
            isAvailable: true
        )

        player.play(song, in: [song])
        await waitUntil { player.isPlaying }
        player.selectPlaybackQuality(lossless)
        player.selectPlaybackQuality(standard)
        #expect(!player.isSwitchingPlaybackQuality)
        #expect(player.currentPlaybackLevel == standard.id)
        #expect(player.selectedPlaybackLevel == standard.id)

        player.selectPlaybackQuality(lossless)
        player.seek(to: 0.5)
        await waitUntil {
            player.currentPlaybackLevel == lossless.id && !player.isSwitchingPlaybackQuality
        }
        #expect(player.selectedPlaybackLevel == lossless.id)
        #expect(abs(player.position - 0.5) <= 0.15)

        player.selectPlaybackQuality(lossless)
        player.selectPlaybackQuality(master)
        await waitUntil { player.playbackQualityConfirmationMessage != nil }

        #expect(player.currentPlaybackLevel == master.id)
        #expect(player.selectedPlaybackLevel == master.id)
        #expect(player.playbackQualityConfirmationMessage == "已切换为超清母带音质")
        let requests = await repository.levelRequests()
        #expect(requests == ["standard", lossless.id, master.id])
    }

    @MainActor
    @Test("Paused tail seeks and in-flight seeks do not advance the queue")
    func pausedTailSeekKeepsQueue() async throws {
        let root = performanceCacheRoot()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "tail-seek.wav")
        try performanceWAV(seconds: 8).write(to: source)
        let songs = [performanceSong(1), performanceSong(2)]
        let player = PlayerController(
            repository: PlayerPerformanceRepository(songs: songs, sourceURL: source),
            cacheRoot: root.appending(path: "cache"),
            crossfadeDuration: 3
        )
        player.play(songs[0], in: songs)
        await waitUntil { player.isPlaying && player.duration < 10 }
        try #require(player.isPlaying)
        player.setPlayback(false)
        let target = player.duration - 1
        player.seek(to: target)
        player.updatePosition(target)
        #expect(player.currentSongID == songs[0].id)
        #expect(!player.isPlaybackRequested)
        await waitUntil { player.pendingSeekPosition == nil }
        player.updatePosition(target)
        #expect(player.currentSongID == songs[0].id)
        #expect(!player.isPlaybackRequested)

        player.seek(to: 0)
        await waitUntil { player.pendingSeekPosition == nil }
        player.setPlayback(true)
        await waitUntil { player.isPlaying }
        player.seek(to: 1)
        // Simulate a tail callback from the old position before the seek confirms.
        player.updatePosition(target)
        #expect(player.currentSongID == songs[0].id)
        await waitUntil {
            player.pendingSeekPosition == nil
                && performanceAVPlayer(player, named: "avPlayer")?.timeControlStatus == .playing
        }
        player.updatePosition(target)
        #expect(player.currentSongID == songs[1].id)
        player.setPlayback(false)
    }

    @MainActor
    @Test("Queue replacement settles the outgoing media identity", arguments: [true, false])
    func playbackSettlementKeepsOutgoingIdentity(outgoingIsPodcast: Bool) async throws {
        let root = performanceCacheRoot()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "settlement.wav")
        try performanceWAV(seconds: 8).write(to: source)
        let outgoing = performanceSong(1, podcastEpisodeID: outgoingIsPodcast ? 101 : nil)
        let incoming = performanceSong(2, podcastEpisodeID: 202)
        let repository = PlayerPerformanceRepository(songs: [outgoing, incoming], sourceURL: source)
        let player = PlayerController(
            repository: repository,
            cacheRoot: root.appending(path: "cache"),
            crossfadeDuration: 0
        )
        player.play(outgoing, in: [outgoing])
        await waitUntil { player.isPlaying && player.position >= 1.2 }
        try #require(player.position >= 1.2)
        player.setPlayback(false)
        let settledPosition = Int(player.position * 1_000)
        player.play(incoming, in: [incoming])
        player.setPlayback(false)
        await waitUntil { player.pendingPlaybackReportCount == 0 }
        try #require(player.pendingPlaybackReportCount == 0)
        let reports = await repository.podcastPlaybackReports
        if outgoingIsPodcast {
            #expect(reports.count == 2)
            #expect(reports.last?.episodeID == 101)
            #expect(reports.last?.positionMilliseconds == settledPosition)
            #expect(reports.last?.completed == false)
            #expect(reports.allSatisfy { $0.episodeID == 101 })
            #expect(await repository.settledSongIDs.isEmpty)
        } else {
            #expect(reports.isEmpty)
            #expect(await repository.settledSongIDs == [outgoing.id])
        }
    }

    @MainActor
    @Test("A corrupt full cache recovers once for active and standby items", arguments: [false, true])
    func corruptFullCacheRecoversOnce(useStandby: Bool) async throws {
        let root = performanceCacheRoot()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let audio = performanceWAV(seconds: 8)
        let source = root.appending(path: "current.wav")
        try audio.write(to: source)
        let server = try LocalHTTPFixture(rangedBody: audio, contentType: "audio/wav")
        let port = try await server.start()
        defer { server.stop() }
        let directURL = URL(string: "http://127.0.0.1:\(port)/recovered.wav")!
        let first = performanceSong(1)
        let damaged = performanceSong(2)
        let sources = PlayerPrefetchGate(songID: damaged.id)
        let repository = PlayerPerformanceRepository(
            songs: [first, damaged],
            sourceURL: source,
            prefetchGate: sources
        )
        let cache = TrackCache(directory: root.appending(path: "cache"))
        let badSource = root.appending(path: "damaged.tmp")
        try Data("ID3broken-cache".utf8).write(to: badSource)
        let badCache = try await cache.finalize(badSource, for: damaged.id)
        #expect(await cache.readyFile(for: damaged.id) == badCache)
        let player = PlayerController(
            repository: repository,
            cache: cache,
            crossfadeDuration: useStandby ? 0.5 : 0
        )
        if useStandby {
            player.play(first, in: [first, damaged])
            await waitUntil { player.isPlaying }
            try #require(player.isPlaying)
            player.next()
        } else {
            player.play(damaged, in: [damaged])
        }
        await waitUntil { await sources.invocationCount == 1 }
        try #require(await sources.invocationCount == 1)
        #expect(await cache.readyFile(for: damaged.id) == nil)
        if !useStandby { player.setPlayback(false) }
        await sources.release(1, with: .success(PlaybackSource(
            url: directURL,
            availability: .playable(level: "standard"),
            format: "wav"
        )))
        await waitUntil {
            guard let active = performanceAVPlayer(player, named: "avPlayer"),
                  let item = active.currentItem,
                  (item.asset as? AVURLAsset)?.url == directURL,
                  item.status == .readyToPlay
            else { return false }
            return useStandby ? player.isPlaying : player.state == .paused(songID: damaged.id)
        }
        let active = try #require(performanceAVPlayer(player, named: "avPlayer"))
        let recovered = try #require(active.currentItem)
        try #require(recovered.status == .readyToPlay)
        if useStandby {
            try #require(player.isPlaying)
            try #require(active.timeControlStatus == .playing)
        } else {
            try #require(player.state == .paused(songID: damaged.id))
            try #require(active.timeControlStatus == .paused)
        }
        #expect((recovered.asset as? AVURLAsset)?.url == directURL)
        #expect(player.isPlaybackRequested == useStandby)
        #expect(player.currentSongID == damaged.id)
        await waitUntil { !FileManager.default.fileExists(atPath: badCache.path) }
        #expect(!FileManager.default.fileExists(atPath: badCache.path))

        let message = "fixture direct recovery failure"
        NotificationCenter.default.post(
            name: .AVPlayerItemFailedToPlayToEndTime,
            object: recovered,
            userInfo: [AVPlayerItemFailedToPlayToEndTimeErrorKey: NSError(
                domain: "TinyCloudMusicTests",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: message]
            )]
        )
        let failedState = PlaybackState.failed(songID: damaged.id, message: message)
        await waitUntil { player.state == failedState }
        try #require(player.state == failedState)
        // Drain the asynchronous pause/status callbacks caused by the failure.
        try await Task.sleep(for: .milliseconds(100))
        #expect(await sources.invocationCount == 1)
        #expect(await cache.readyFile(for: damaged.id) == nil)
        #expect(player.state == failedState)
        #expect(!player.isPlaybackRequested)
        #expect(active.timeControlStatus == .paused)

        if useStandby {
            player.play(first, in: [first])
        } else {
            player.retryPlayback()
            await waitUntil { await sources.invocationCount == 2 }
            try #require(await sources.invocationCount == 2)
            await sources.release(2, with: .success(PlaybackSource(
                url: source,
                availability: .playable(level: "standard"),
                format: "wav"
            )))
        }
        let resumedSongID = useStandby ? first.id : damaged.id
        await waitUntil { player.currentSongID == resumedSongID && player.isPlaying }
        #expect(player.currentSongID == resumedSongID)
        #expect(player.isPlaying)
        player.setPlayback(false)
    }

    @MainActor
    @Test("Playback controls fade only while the setting is enabled")
    func playbackControlFadeToggle() async throws {
        let root = performanceCacheRoot()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "fade.wav")
        try performanceWAV().write(to: source)
        let song = performanceSong(1)
        let repository = PlayerPerformanceRepository(songs: [song], sourceURL: source)
        let player = PlayerController(
            repository: repository,
            cacheRoot: root.appending(path: "cache"),
            crossfadeDuration: 0.6,
            playbackControlFadeEnabled: true
        )

        player.play(song, in: [song])
        await waitUntil { player.isPlaying }
        #expect(player.isPlaying)

        player.togglePlayback()
        #expect(player.hasPendingPlaybackFade)
        try await Task.sleep(for: .milliseconds(100))
        player.togglePlayback()
        #expect(player.hasPendingPlaybackFade)

        player.setPlaybackControlFadeEnabled(false)
        #expect(!player.hasPendingPlaybackFade)
        player.togglePlayback()
        #expect(!player.isPlaybackRequested)
        #expect(!player.hasPendingPlaybackFade)
    }

    @MainActor
    @Test("Playback history events and report tasks are fenced by account revision")
    func playbackReportRevision() async throws {
        let root = performanceCacheRoot()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "report.wav")
        try performanceWAV().write(to: source)
        let song = performanceSong(1)
        let snapshot = CredentialSnapshot(.guest)
        _ = snapshot.store(.authenticated(try SessionCredentials(
            cookie: "MUSIC_U=revision-fixture",
            musicU: "",
            deviceID: String(repeating: "R", count: 52)
        )))
        let transport = EAPITransport(credentialSnapshot: snapshot)
        let session = SessionController(
            store: CredentialStore(service: "TinyCloudMusicTests.\(UUID())"),
            credentialSnapshot: snapshot,
            transport: transport,
            validator: { _ in true },
            vipValidator: { _ in true }
        )

        do {
            let repository = PlayerPerformanceRepository(songs: [song], sourceURL: source)
            let player = PlayerController(
                repository: repository,
                cacheRoot: root.appending(path: "successful-cache"),
                crossfadeDuration: 0
            )
            player.setAccountCredentialRevision(session.credentialRevision)
            player.play(song, in: [song])
            await waitUntil { player.playbackHistoryEvent != nil }

            #expect(player.playbackHistoryEvent?.sequence == 1)
            #expect(session.credentialRevision == transport.credentialSnapshotValue().revision)
            #expect(player.playbackHistoryEvent?.credentialRevision == session.credentialRevision)
            #expect(player.playbackHistoryEvent?.kind == .song)
            player.togglePlayback()
        }

        let repository = PlayerPerformanceRepository(
            songs: [song],
            sourceURL: source,
            blocksStartReport: true
        )
        let player = PlayerController(
            repository: repository,
            cacheRoot: root.appending(path: "cancelled-cache"),
            crossfadeDuration: 0
        )
        player.setAccountCredentialRevision(41)
        player.play(song, in: [song])
        await waitUntil { await repository.startReportRevisions() == [41] }
        player.setAccountCredentialRevision(42)
        await waitUntil { await repository.startReportCancellationCount() == 1 }

        let revisions = await repository.startReportRevisions()
        #expect(revisions == [41])
        #expect(await repository.startReportCancellationCount() == 1)
        #expect(player.playbackHistoryEvent == nil)
    }

    @MainActor
    @Test("Startup revision interleaving advances Player and clears the stale account")
    func startupRevisionInterleaving() async throws {
        PlayerMutationProtocol.reset()
        let root = performanceCacheRoot()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "startup-revision.wav")
        try performanceWAV().write(to: source)
        let song = performanceSong(1)
        let snapshot = CredentialSnapshot(.authenticated(try playerCredentials("startup-a")))
        let revisionA = snapshot.load().revision
        let requestCount = ObservationChangeCounter()
        let accountGate = PlayerReportGate(blocking: [.start])
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PlayerMutationProtocol.self]
        let transport = EAPITransport(
            session: URLSession(configuration: configuration),
            credentialSnapshot: snapshot,
            beforeSendingRequest: {
                let call = requestCount.increment()
                guard call == 3 || call == 4 else { return }
                try? await accountGate.run(.start, revision: UInt64(call))
            }
        )
        let model = AppModel(
            repository: FixtureMusicRepository(),
            library: LiveMusicLibrary(transport: transport),
            extras: LiveMusicExtras(transport: transport)
        )
        let playerRepository = PlayerPerformanceRepository(
            songs: [song],
            sourceURL: source,
            blocksStartReport: true
        )
        let player = PlayerController(
            repository: playerRepository,
            cacheRoot: root.appending(path: "cache"),
            crossfadeDuration: 0
        )
        player.setAccountCredentialRevision(revisionA)
        player.play(song, in: [song])
        await waitUntil { await playerRepository.startReportRevisions() == [revisionA] }

        let staleRefresh = Task { @MainActor in await model.refreshAccountState() }
        await waitUntil { await accountGate.invocationCount(.start, revision: 3) == 1 }
        #expect(model.currentUserID == 8)
        #expect(model.confirmedAccountCredentialRevision == revisionA)

        model.toggleSongLiked(42)
        await waitUntil {
            await accountGate.invocationCount(.start, revision: 4) == 1
                && model.pendingMutations == [.songLike(42)]
        }

        let revisionB = snapshot.store(.authenticated(try playerCredentials("startup-b"))).revision
        player.setAccountCredentialRevision(revisionB)
        model.invalidateAccountDomainIfNeeded(forCredentialRevision: revisionB)
        await waitUntil { await playerRepository.startReportCancellationCount() == 1 }

        #expect(model.currentUserID == nil)
        #expect(model.confirmedAccountCredentialRevision == nil)
        #expect(model.pendingMutations.isEmpty)
        #expect(await playerRepository.startReportCancellationCount() == 1)

        await accountGate.release(revision: 3)
        await accountGate.release(revision: 4)
        await staleRefresh.value
        await model.refreshAccountState()

        #expect(model.currentUserID == 8)
        #expect(model.confirmedAccountCredentialRevision == revisionB)
    }

    @MainActor
    @Test("Settlement keeps a blocked start report owned across account reset")
    func settlementKeepsStartOwned() async throws {
        let root = performanceCacheRoot()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "settlement.wav")
        try performanceWAV().write(to: source)
        let first = performanceSong(1)
        let second = performanceSong(2, podcastEpisodeID: 202)
        let reports = PlayerReportGate(blocking: [.start])
        let repository = PlayerPerformanceRepository(
            songs: [first, second],
            sourceURL: source,
            reportGate: reports
        )
        let player = PlayerController(
            repository: repository,
            cacheRoot: root.appending(path: "cache"),
            crossfadeDuration: 0
        )
        player.setAccountCredentialRevision(70)
        player.play(first, in: [first, second])
        await waitUntil { await reports.invocationCount(.start, revision: 70) == 1 }
        try await Task.sleep(for: .milliseconds(1_100))

        player.play(second, in: [first, second])
        player.setAccountCredentialRevision(71)
        await reports.release(revision: 70)
        await waitUntil { await reports.cancellationCount(.start, revision: 70) == 1 }

        #expect(await reports.invocationCount(.settlement, revision: 70) == 0)
        #expect(player.playbackHistoryEvent == nil)
        #expect(player.playbackReportErrorMessage == nil)
    }

    @MainActor
    @Test("New account reports progress while cancelled old calls stay blocked")
    func podcastReportOwnership() async throws {
        let root = performanceCacheRoot()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "podcast.wav")
        try performanceWAV().write(to: source)
        let first = performanceSong(1, podcastEpisodeID: 201)
        let second = performanceSong(2, podcastEpisodeID: 202)
        let third = performanceSong(3, podcastEpisodeID: 203)
        let songs = [first, second, third]
        let reports = PlayerReportGate(blocking: [.podcast])
        let repository = PlayerPerformanceRepository(
            songs: songs,
            sourceURL: source,
            reportGate: reports
        )
        let player = PlayerController(
            repository: repository,
            cacheRoot: root.appending(path: "cache"),
            crossfadeDuration: 0
        )
        player.setAccountCredentialRevision(80)
        player.play(first, in: songs)
        await waitUntil { await reports.invocationCount(.podcast, revision: 80) == 1 }
        player.play(second, in: songs)
        await waitUntil { await reports.invocationCount(.podcast, revision: 80) == 2 }

        player.setAccountCredentialRevision(81)
        player.play(third, in: songs)
        await waitUntil { await reports.invocationCount(.podcast, revision: 81) == 1 }

        #expect(player.pendingPlaybackReportCount == 1)
        #expect(await reports.waiterCount(revision: 80) == 2)
        #expect(await reports.cancellationCount(.podcast, revision: 80) == 0)
        await reports.release(revision: 81)
        await waitUntil { player.playbackHistoryEvent?.credentialRevision == 81 }

        #expect(player.playbackHistoryEvent?.kind == .podcast)
        #expect(player.playbackReportErrorMessage == nil)

        await reports.release(revision: 80)
        await waitUntil { await reports.cancellationCount(.podcast, revision: 80) == 2 }
        #expect(await reports.cancellationCount(.podcast, revision: 80) == 2)
    }

    @MainActor
    @Test("Settlement success preserves a failed start report error")
    func settlementPreservesStartFailure() async throws {
        let root = performanceCacheRoot()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "failed-start.wav")
        try performanceWAV().write(to: source)
        let first = performanceSong(1)
        let second = performanceSong(2, podcastEpisodeID: 202)
        let reports = PlayerReportGate(blocking: [], failing: [.start])
        let player = PlayerController(
            repository: PlayerPerformanceRepository(
                songs: [first, second],
                sourceURL: source,
                reportGate: reports
            ),
            cacheRoot: root.appending(path: "cache"),
            crossfadeDuration: 0
        )
        player.setAccountCredentialRevision(85)
        player.play(first, in: [first, second])
        await waitUntil { player.playbackReportErrorMessage != nil }
        try await Task.sleep(for: .milliseconds(1_100))

        player.play(second, in: [first, second])
        await waitUntil { player.playbackHistoryEvent?.sequence == 1 }

        #expect(await reports.invocationCount(.start, revision: 85) == 1)
        #expect(await reports.invocationCount(.settlement, revision: 85) == 1)
        #expect(player.playbackReportErrorMessage != nil)
    }

    @MainActor
    @Test("Playback report ownership stays bounded under a blocked network")
    func playbackReportCapacity() async throws {
        let root = performanceCacheRoot()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "bounded-reports.wav")
        try performanceWAV().write(to: source)
        let songs = (1...10).map {
            performanceSong(Int64($0), podcastEpisodeID: Int64(300 + $0))
        }
        let reports = PlayerReportGate(blocking: [.podcast])
        let player = PlayerController(
            repository: PlayerPerformanceRepository(
                songs: songs,
                sourceURL: source,
                reportGate: reports
            ),
            cacheRoot: root.appending(path: "cache"),
            crossfadeDuration: 0
        )
        player.setAccountCredentialRevision(90)

        for (index, song) in songs.enumerated() {
            player.play(song, in: songs)
            await waitUntil {
                await reports.invocationCount(.podcast, revision: 90) == index + 1
            }
            #expect(player.pendingPlaybackReportCount == min(index + 1, 8))
        }

        await reports.release(revision: 90)
        await waitUntil {
            await reports.cancellationCount(.podcast, revision: 90) == 2
                && player.pendingPlaybackReportCount == 0
        }
        #expect(await reports.cancellationCount(.podcast, revision: 90) == 2)
        #expect(player.pendingPlaybackReportCount == 0)
    }

    @MainActor
    @Test("Prefetch preserves representation across a concurrent full-cache race")
    func prefetchedRepresentationSurvivesFullRace() async throws {
        let root = performanceCacheRoot()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let currentAudio = performanceWAV()
        let currentSource = root.appending(path: "prefetch-current.wav")
        try currentAudio.write(to: currentSource)
        let remoteAudio = performanceWAV(seconds: 32, sampleRate: 44_100)
        let remoteFile = root.appending(path: "prefetch-remote.wav")
        try remoteAudio.write(to: remoteFile)
        let server = try LocalHTTPFixture(rangedBody: remoteAudio, contentType: "audio/wav")
        let port = try await server.start()
        defer { server.stop() }

        let first = performanceSong(1)
        let second = performanceSong(2)
        let prefetches = PlayerPrefetchGate(songID: second.id)
        let repository = PlayerPerformanceRepository(
            songs: [first, second],
            sourceURL: currentSource,
            prefetchGate: prefetches
        )
        let trackDownloads = ObservationChangeCounter()
        let cache = TrackCache(directory: root.appending(path: "prefetch-cache"), download: { _ in
            trackDownloads.increment()
            throw URLError(.unsupportedURL)
        })
        let laterRangeDownloads = AsyncGate()
        defer { Task { await laterRangeDownloads.release() } }
        let rangeDownloads = ObservationChangeCounter()
        let rangeCache = TrackRangeCache(trackCache: cache) { request in
            if rangeDownloads.increment() > 1 {
                await laterRangeDownloads.wait()
                try Task.checkCancellation()
            }
            return try await URLSession.shared.download(for: request)
        }
        let player = PlayerController(
            repository: repository,
            cache: cache,
            crossfadeDuration: 0,
            rangeCache: rangeCache
        )

        player.play(first, in: [first, second])
        await waitUntil { player.hasCurrentPlayerItem && !player.isPreparing }
        player.updatePosition(max(0, player.duration - 0.5))
        await waitUntil { await prefetches.invocationCount == 1 }

        let racedFull = try await cache.storeCopy(
            of: remoteFile,
            for: second.id,
            quality: "standard",
            fileExtension: "wav"
        )
        let prefetchedSource = performancePlaybackSource(
            url: URL(string: "http://127.0.0.1:\(port)/prefetched")!,
            level: "standard",
            format: "wav",
            representationData: remoteAudio
        )
        await prefetches.release(1, with: .success(prefetchedSource))
        await waitUntil { !player.hasPendingPrefetch }
        await cache.invalidateCachedFile(racedFull.url)
        #expect(await cache.readyFile(for: second.id, quality: "standard") == nil)

        player.next()
        await waitUntil {
            performanceAVPlayer(player, named: "avPlayer")?.currentItem is RangeCachingPlayerItem
        }
        player.setPlayback(false)
        let key = TrackRangeCacheKey(songID: second.id, quality: "standard")
        await waitUntil { await rangeCache.descriptor(for: key) != nil }

        #expect(await prefetches.invocationCount == 1)
        #expect(await repository.sourceRequestCount() == 2)
        #expect(await repository.levelRequests() == ["standard", "standard"])
        #expect(await rangeCache.descriptor(for: key) != nil)
        #expect(rangeDownloads.value >= 1)
        #expect(trackDownloads.value == 0)
        await laterRangeDownloads.release()
    }

    @MainActor
    @Test("Cache reconfiguration waits for the cancelled prefetch before replacement")
    func prefetchIdentity() async throws {
        let root = performanceCacheRoot()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "prefetch.wav")
        try performanceWAV().write(to: source)
        let first = performanceSong(1)
        let second = performanceSong(2)
        let prefetches = PlayerPrefetchGate(songID: second.id)
        let repository = PlayerPerformanceRepository(
            songs: [first, second],
            sourceURL: source,
            prefetchGate: prefetches
        )
        let player = PlayerController(
            repository: repository,
            cacheRoot: root.appending(path: "cache-1"),
            crossfadeDuration: 0
        )
        player.play(first, in: [first, second])
        await waitUntil { await prefetches.invocationCount == 1 }

        player.configure(playbackQuality: .standard, cacheRoot: root.appending(path: "cache-2"))
        for _ in 0..<4 { await Task.yield() }
        #expect(await prefetches.invocationCount == 1)
        await prefetches.release(1, with: .failure(URLError(.timedOut)))
        await waitUntil { await prefetches.wasCancelled(1) == true }
        await waitUntil { await prefetches.invocationCount == 2 }
        #expect(player.hasPendingPrefetch)

        player.configure(playbackQuality: .standard, cacheRoot: root.appending(path: "cache-3"))
        for _ in 0..<4 { await Task.yield() }
        #expect(await prefetches.invocationCount == 2)
        await prefetches.release(
            2,
            with: .success(PlaybackSource(url: source, availability: .playable(level: "lossless")))
        )
        await waitUntil { await prefetches.wasCancelled(2) == true }
        await waitUntil { await prefetches.invocationCount == 3 }
        await prefetches.release(
            3,
            with: .success(PlaybackSource(url: source, availability: .playable(level: "standard")))
        )
        await waitUntil { !player.hasPendingPrefetch }

        player.next()
        await waitUntil { player.currentSongID == second.id && !player.isPreparing }
        #expect(player.playbackAvailability == .playable(level: "standard"))
        #expect(await prefetches.invocationCount == 3)
    }
}

@MainActor
private final class IntentRecorder {
    var values: [PlayerControlIntent] = []
}

private final class ObservationChangeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int { lock.withLock { count } }

    @discardableResult
    func increment() -> Int {
        lock.withLock {
            count += 1
            return count
        }
    }
}

private final class PlayerMutationProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var counts: [String: Int] = [:]

    static func reset() { lock.withLock { counts = [:] } }
    static func count(_ path: String) -> Int { lock.withLock { counts[path, default: 0] } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let path = request.url?.path ?? ""
        Self.lock.withLock { Self.counts[path, default: 0] += 1 }
        let body = switch path {
        case "/eapi/v1/user/info":
            #"{"code":200,"userPoint":{"userId":8}}"#
        case "/eapi/v1/user/detail":
            #"{"code":200,"profile":{"userId":8,"nickname":"fixture"}}"#
        case "/eapi/user/playlist":
            #"{"code":200,"playlist":[],"more":false}"#
        default:
            #"{"code":200}"#
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private actor PlayerReportGate {
    enum Kind: Hashable, Sendable {
        case start
        case settlement
        case podcast
    }

    private struct Waiter {
        let kind: Kind
        let revision: UInt64
        let continuation: CheckedContinuation<Void, Never>
    }

    private let blocking: Set<Kind>
    private let failing: Set<Kind>
    private var invocations: [(Kind, UInt64)] = []
    private var cancellations: [(Kind, UInt64)] = []
    private var waiters: [UUID: Waiter] = [:]

    init(blocking: Set<Kind>, failing: Set<Kind> = []) {
        self.blocking = blocking
        self.failing = failing
    }

    func run(_ kind: Kind, revision: UInt64) async throws {
        invocations.append((kind, revision))
        if blocking.contains(kind) {
            let id = UUID()
            await withCheckedContinuation { continuation in
                waiters[id] = Waiter(kind: kind, revision: revision, continuation: continuation)
            }
        }
        if Task.isCancelled {
            cancellations.append((kind, revision))
            throw CancellationError()
        }
        if failing.contains(kind) { throw URLError(.badServerResponse) }
    }

    func release(revision: UInt64) {
        let matches = waiters.filter { $0.value.revision == revision }
        for (id, waiter) in matches {
            waiters[id] = nil
            waiter.continuation.resume()
        }
    }

    func invocationCount(_ kind: Kind, revision: UInt64) -> Int {
        invocations.count { $0.0 == kind && $0.1 == revision }
    }

    func cancellationCount(_ kind: Kind, revision: UInt64) -> Int {
        cancellations.count { $0.0 == kind && $0.1 == revision }
    }

    func waiterCount(revision: UInt64) -> Int {
        waiters.values.count { $0.revision == revision }
    }
}

private actor PlayerPrefetchGate {
    nonisolated let songID: Int64

    private var continuations: [Int: CheckedContinuation<PlaybackSource, Error>] = [:]
    private var cancellations: [Int: Bool] = [:]
    private(set) var invocationCount = 0
    private(set) var completionCount = 0

    init(songID: Int64) {
        self.songID = songID
    }

    func source() async throws -> PlaybackSource {
        invocationCount += 1
        let invocation = invocationCount
        let source: PlaybackSource
        do {
            source = try await withCheckedThrowingContinuation {
                continuations[invocation] = $0
            }
        } catch {
            cancellations[invocation] = Task.isCancelled
            completionCount += 1
            throw error
        }
        cancellations[invocation] = Task.isCancelled
        completionCount += 1
        if Task.isCancelled { throw CancellationError() }
        return source
    }

    func release(_ invocation: Int, with result: Result<PlaybackSource, Error>) {
        continuations.removeValue(forKey: invocation)?.resume(with: result)
    }

    func wasCancelled(_ invocation: Int) -> Bool? {
        cancellations[invocation]
    }
}

private actor PlayerPerformanceRepository: MusicRepository {
    nonisolated let homeDescriptors: [HomeSectionDescriptor] = []
    private let songsByID: [Int64: Song]
    private let sourceFails: Bool
    private let sourceURL: URL
    private let levelSourceURL: URL?
    private let qualitySource: PlaybackSource?
    private let levelSource: PlaybackSource?
    private let delayedSongID: Int64?
    private let blocksStartReport: Bool
    private let reportGate: PlayerReportGate?
    private let prefetchGate: PlayerPrefetchGate?
    private let qualityGate: PlayerPrefetchGate?
    private let qualityGateLevel: String?
    private var requestedSongIDs: [[Int64]] = []
    private var sourceRequests = 0
    private var requestedQualities: [AudioQuality] = []
    private var requestedLevels: [String] = []
    private var songResolutionCancellations = 0
    private var reportRevisions: [UInt64] = []
    private var startReportCancellations = 0
    private(set) var settledSongIDs: [Int64] = []
    private(set) var podcastPlaybackReports: [
        (episodeID: Int64, positionMilliseconds: Int, completed: Bool)
    ] = []

    init(
        songs: [Song],
        sourceFails: Bool = false,
        sourceURL: URL = URL(fileURLWithPath: "/dev/null"),
        levelSourceURL: URL? = nil,
        qualitySource: PlaybackSource? = nil,
        levelSource: PlaybackSource? = nil,
        delayedSongID: Int64? = nil,
        blocksStartReport: Bool = false,
        reportGate: PlayerReportGate? = nil,
        prefetchGate: PlayerPrefetchGate? = nil,
        qualityGate: PlayerPrefetchGate? = nil,
        qualityGateLevel: String? = nil
    ) {
        songsByID = Dictionary(uniqueKeysWithValues: songs.map { ($0.id, $0) })
        self.sourceFails = sourceFails
        self.sourceURL = sourceURL
        self.levelSourceURL = levelSourceURL
        self.qualitySource = qualitySource
        self.levelSource = levelSource
        self.delayedSongID = delayedSongID
        self.blocksStartReport = blocksStartReport
        self.reportGate = reportGate
        self.prefetchGate = prefetchGate
        self.qualityGate = qualityGate
        self.qualityGateLevel = qualityGateLevel
    }

    func songs(ids: [Int64]) async throws -> [Song] {
        requestedSongIDs.append(ids)
        if let delayedSongID, ids == [delayedSongID] {
            do {
                try await Task.sleep(for: .seconds(60))
            } catch {
                songResolutionCancellations += 1
                throw error
            }
        }
        return ids.compactMap { songsByID[$0] }
    }

    func playbackSource(for songID: Int64, quality: AudioQuality) async throws -> PlaybackSource {
        sourceRequests += 1
        requestedQualities.append(quality)
        if let prefetchGate, songID == prefetchGate.songID {
            return try await prefetchGate.source()
        }
        if sourceFails { throw URLError(.timedOut) }
        if let qualitySource { return qualitySource }
        return PlaybackSource(
            url: sourceURL,
            availability: .playable(level: quality.cacheComponent)
        )
    }

    func playbackSource(for songID: Int64, level: String) async throws -> PlaybackSource {
        sourceRequests += 1
        requestedLevels.append(level)
        if let prefetchGate, songID == prefetchGate.songID {
            return try await prefetchGate.source()
        }
        if let qualityGate, qualityGateLevel == nil || qualityGateLevel == level {
            return try await qualityGate.source()
        }
        if sourceFails { throw URLError(.timedOut) }
        if let levelSource { return levelSource }
        return PlaybackSource(
            url: levelSourceURL ?? sourceURL,
            availability: .playable(level: level)
        )
    }

    func songRequests() -> [[Int64]] { requestedSongIDs }
    func songResolutionCancellationCount() -> Int { songResolutionCancellations }
    func sourceRequestCount() -> Int { sourceRequests }
    func qualityRequests() -> [AudioQuality] { requestedQualities }
    func levelRequests() -> [String] { requestedLevels }
    func startReportRevisions() -> [UInt64] { reportRevisions }
    func startReportCancellationCount() -> Int { startReportCancellations }
    func lyrics(for songID: Int64) async throws -> SongLyrics {
        SongLyrics(lineLyrics: "[00:00.00]first\n[00:01.00]second")
    }
    func songQualityDetails(for songID: Int64) async throws -> [SongQualityDetail] { [] }
    func recordPlaybackStart(
        for songID: Int64,
        sourceID: Int64,
        totalSeconds: Int,
        expectedCredentialRevision: UInt64
    ) async throws {
        reportRevisions.append(expectedCredentialRevision)
        if let reportGate {
            try await reportGate.run(.start, revision: expectedCredentialRevision)
            return
        }
        guard blocksStartReport else { return }
        do {
            try await Task.sleep(for: .seconds(60))
        } catch {
            startReportCancellations += 1
            throw error
        }
    }
    func recordPlayback(
        for songID: Int64,
        sourceID: Int64,
        playedSeconds: Int,
        totalSeconds: Int,
        expectedCredentialRevision: UInt64
    ) async throws {
        settledSongIDs.append(songID)
        try await reportGate?.run(.settlement, revision: expectedCredentialRevision)
    }
    func recordPodcastPlayback(
        for episodeID: Int64,
        positionMilliseconds: Int,
        completed: Bool,
        expectedCredentialRevision: UInt64
    ) async throws {
        podcastPlaybackReports.append((episodeID, positionMilliseconds, completed))
        try await reportGate?.run(.podcast, revision: expectedCredentialRevision)
    }
    func homeSection(
        id: String,
        expectedCredentialRevision: UInt64
    ) async throws -> HomeSection { throw AppError.invalidRoute }
    func search(query: String, scope: SearchScope, offset: Int, limit: Int) async throws -> SearchPage {
        throw AppError.invalidRoute
    }
    func detail(
        for route: Route,
        expectedCredentialRevision: UInt64?
    ) async throws -> DetailContent { throw AppError.invalidRoute }
}

@MainActor
private func playerSubviews<View: NSView>(_ type: View.Type, in root: NSView) -> [View] {
    var matches: [View] = []
    if let match = root as? View { matches.append(match) }
    for child in root.subviews {
        matches.append(contentsOf: playerSubviews(type, in: child))
    }
    return matches
}

@MainActor
private func playerIsVisible(_ view: NSView) -> Bool {
    guard !view.isHidden, view.alphaValue > 0, view.bounds.width > 1, view.bounds.height > 1 else {
        return false
    }
    var ancestor = view.superview
    while let current = ancestor {
        if current.isHidden || current.alphaValue == 0 { return false }
        ancestor = current.superview
    }
    return true
}

@MainActor
private func performanceAVPlayer(_ controller: PlayerController, named name: String) -> AVPlayer? {
    Mirror(reflecting: controller).children.first {
        $0.label == name || $0.label == "_\(name)"
    }?.value as? AVPlayer
}

@MainActor
private func performanceAVPlayers(_ controller: PlayerController) -> [AVPlayer] {
    ["avPlayer", "standbyPlayer"].compactMap {
        performanceAVPlayer(controller, named: $0)
    }
}

@MainActor
private func performancePrivateInt(_ controller: PlayerController, named name: String) -> Int? {
    Mirror(reflecting: controller).children.first {
        $0.label == name || $0.label == "_\(name)"
    }?.value as? Int
}

@MainActor
private func performanceHasPrivateOptional(_ controller: PlayerController, named name: String) -> Bool {
    guard let value = Mirror(reflecting: controller).children.first(where: {
        $0.label == name || $0.label == "_\(name)"
    })?.value else { return false }
    let optional = Mirror(reflecting: value)
    return optional.displayStyle == .optional && !optional.children.isEmpty
}

@MainActor
private func waitUntil(_ predicate: @escaping @MainActor () async -> Bool) async {
    for _ in 0..<300 {
        if await predicate() { return }
        try? await Task.sleep(for: .milliseconds(10))
    }
}

private func performanceSong(_ id: Int64, podcastEpisodeID: Int64? = nil) -> Song {
    Song(
        id: id,
        name: "Song \(id)",
        artists: [ArtistSummary(id: 1, name: "Artist")],
        album: AlbumSummary(id: 1, name: "Album", artwork: Artwork(symbol: "music.note", accent: .red)),
        duration: .seconds(120),
        podcastEpisodeID: podcastEpisodeID
    )
}

private func performanceCacheRoot() -> URL {
    FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
}

private func performancePlaybackSource(
    url: URL,
    level: String,
    format: String?,
    representationData: Data? = nil,
    availability: PlaybackAvailability? = nil
) -> PlaybackSource {
    PlaybackSource(
        url: url,
        availability: availability ?? .playable(level: level),
        format: format,
        representation: representationData.map {
            PlaybackRepresentation(
                contentLength: Int64($0.count),
                contentMD5: Insecure.MD5.hash(data: $0).map { String(format: "%02x", $0) }.joined()
            )!
        }
    )
}

private func seedPerformancePartial(
    key: TrackRangeCacheKey,
    source: PlaybackSource,
    rangeCache: TrackRangeCache,
    leadingBlocks: Int = 1
) async throws {
    let session = try await rangeCache.open(
        key: key,
        format: source.format ?? "wav",
        initialSource: source,
        sourceProvider: { source }
    )
    do {
        let info = try await rangeCache.contentInfo(for: session)
        for block in 0..<leadingBlocks {
            let offset = Int64(block) * 512 * 1_024
            guard offset < info.contentLength else { break }
            _ = try await rangeCache.read(session: session, offset: offset, maximumLength: 1)
        }
        _ = try await rangeCache.read(
            session: session,
            offset: info.contentLength - 1,
            maximumLength: 1
        )
        await rangeCache.close(session)
        #expect(await rangeCache.descriptor(for: key) != nil)
    } catch {
        await rangeCache.close(session)
        throw error
    }
}

private func playerCredentials(_ token: String) throws -> SessionCredentials {
    try SessionCredentials(
        cookie: "MUSIC_U=fixture-\(token); __csrf=fixture",
        musicU: "vip-fixture-\(token)",
        deviceID: String(repeating: "D", count: 52)
    )
}

private func performanceWAV(seconds: UInt32 = 2, sampleRate: UInt32 = 8_000) -> Data {
    let sampleCount: UInt32 = sampleRate * seconds
    let dataSize = sampleCount * 2
    var data = Data("RIFF".utf8)
    appendLittleEndian(36 + dataSize, to: &data)
    data.append(Data("WAVEfmt ".utf8))
    appendLittleEndian(UInt32(16), to: &data)
    appendLittleEndian(UInt16(1), to: &data)
    appendLittleEndian(UInt16(1), to: &data)
    appendLittleEndian(sampleRate, to: &data)
    appendLittleEndian(sampleRate * 2, to: &data)
    appendLittleEndian(UInt16(2), to: &data)
    appendLittleEndian(UInt16(16), to: &data)
    data.append(Data("data".utf8))
    appendLittleEndian(dataSize, to: &data)
    data.append(Data(repeating: 0, count: Int(dataSize)))
    return data
}

private func performanceFLAC(in root: URL) throws -> Data {
    let sampleRate = 44_100.0
    let frameCount = Int64(sampleRate * 24)
    let url = root.appending(path: "performance.flac")
    let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatFLAC,
        AVSampleRateKey: sampleRate,
        AVNumberOfChannelsKey: 2,
    ]

    try autoreleasepool {
        let file = try AVAudioFile(forWriting: url, settings: settings)
        let capacity: AVAudioFrameCount = 8_192
        let buffer = try #require(AVAudioPCMBuffer(
            pcmFormat: file.processingFormat,
            frameCapacity: capacity
        ))
        let channels = try #require(buffer.floatChannelData)
        var generated: Int64 = 0
        var state: UInt32 = 0xC0FFEE
        while generated < frameCount {
            let frames = min(Int64(capacity), frameCount - generated)
            buffer.frameLength = AVAudioFrameCount(frames)
            for frame in 0..<Int(frames) {
                for channel in 0..<2 {
                    state = state &* 1_664_525 &+ 1_013_904_223
                    channels[channel][frame * buffer.stride] =
                        Float(Int32(bitPattern: state)) / Float(Int32.max) * 0.35
                }
            }
            try file.write(from: buffer)
            generated += frames
        }
    }

    let data = try Data(contentsOf: url)
    try #require(data.count > 10 * 512 * 1_024)
    try #require(data.starts(with: Data("fLaC".utf8)))
    return data
}

private func appendLittleEndian<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
    var value = value.littleEndian
    withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
}
