import AppKit
import Foundation
import Observation
import SwiftUI
import Testing
@testable import TinyCloudMusic

@Suite("Player queue and bounded work")
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
        #expect(text[progress.lowerBound..<detail.lowerBound].contains("player.position"))
        #expect(text.contains("let playbackMilliseconds = isCurrent ? Int64(player.position * 1_000) : 0"))
        #expect(text.contains("player.resolveQueueSongs(visibleAround: item.id)"))
        #expect(queueText.contains("LazyVStack"))
        #expect(!queueText.contains("List("))
        #expect(playerText.components(separatedBy: "cache.cache(").count == 3)
        let qualitySwitch = try #require(playerText.range(of: "func selectPlaybackQuality"))
        let cacheCall = try #require(playerText.range(of: "cache.cache("))
        let prefetch = try #require(playerText.range(of: "private func prefetchNext"))
        #expect(cacheCall.lowerBound > qualitySwitch.lowerBound)
        #expect(cacheCall.lowerBound < prefetch.lowerBound)
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
    @Test("One hundred position ticks invalidate progress but not non-progress controls")
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
        await waitUntil { player.hasCurrentPlayerItem && !player.isLoadingLyrics }

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
                _ = player.position
            } onChange: {
                progress.increment()
            }
            player.seek(to: tick.isMultiple(of: 2) ? 0.25 : 0.5)
        }

        #expect(controls.value == 0)
        #expect(progress.value == 100)
        player.seek(to: 1.25)
        player.updatePosition(0.25)
        #expect(player.position == 1.25)
        #expect(player.currentLyric?.text == "second")
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
    func visibleQueueResolution() async {
        let songs = (1...10_000).map { performanceSong(Int64($0)) }
        let repository = PlayerPerformanceRepository(songs: songs)
        let root = performanceCacheRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let player = PlayerController(repository: repository, cacheRoot: root, crossfadeDuration: 0)

        player.play(songs[0], in: [songs[0]], allSongIDs: songs.map(\.id))
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
    func unresolvedTargetStopsOldAudio() async {
        let first = performanceSong(1)
        let repository = PlayerPerformanceRepository(songs: [first])
        let root = performanceCacheRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let player = PlayerController(repository: repository, cacheRoot: root, crossfadeDuration: 0)

        player.play(first, in: [first], allSongIDs: [1, 2])
        await waitUntil { player.hasCurrentPlayerItem }
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
    @Test("A manually selected quality is cached for the next switch")
    func selectedQualityCache() async throws {
        let root = performanceCacheRoot()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "current.wav")
        try performanceWAV().write(to: source)
        let song = performanceSong(1)
        let repository = PlayerPerformanceRepository(
            songs: [song],
            sourceURL: source,
            levelSourceURL: URL(string: "tinycloudmusic-test://selected-quality")!
        )
        let cache = TrackCache(directory: root.appending(path: "StreamCache"), download: { request in
            let downloaded = root.appending(path: "selected-quality.wav")
            try performanceWAV().write(to: downloaded)
            return (
                downloaded,
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "audio/wav"]
                )!
            )
        })
        let player = PlayerController(
            repository: repository,
            cacheRoot: root,
            cache: cache,
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
        await waitUntil { player.hasCurrentPlayerItem }
        player.selectPlaybackQuality(master)
        await waitUntil { await cache.readyFile(for: song.id, quality: master.id) != nil }

        #expect(await cache.readyFile(for: song.id, quality: master.id) != nil)
        #expect(await repository.levelRequests() == [master.id])
        player.selectPlaybackQuality(master)
        await waitUntil { !player.isSwitchingPlaybackQuality }
        #expect(await repository.levelRequests() == [master.id])
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

        #expect(await repository.startReportRevisions() == [41])
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
            with: .success(PlaybackSource(url: source, availability: .playable(level: "exhigh")))
        )
        await waitUntil { !player.hasPendingPrefetch }

        player.next()
        await waitUntil { player.currentSongID == second.id && !player.isPreparing }
        #expect(player.playbackAvailability == .playable(level: "exhigh"))
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
    private let delayedSongID: Int64?
    private let blocksStartReport: Bool
    private let reportGate: PlayerReportGate?
    private let prefetchGate: PlayerPrefetchGate?
    private var requestedSongIDs: [[Int64]] = []
    private var sourceRequests = 0
    private var requestedLevels: [String] = []
    private var songResolutionCancellations = 0
    private var reportRevisions: [UInt64] = []
    private var startReportCancellations = 0

    init(
        songs: [Song],
        sourceFails: Bool = false,
        sourceURL: URL = URL(fileURLWithPath: "/dev/null"),
        levelSourceURL: URL? = nil,
        delayedSongID: Int64? = nil,
        blocksStartReport: Bool = false,
        reportGate: PlayerReportGate? = nil,
        prefetchGate: PlayerPrefetchGate? = nil
    ) {
        songsByID = Dictionary(uniqueKeysWithValues: songs.map { ($0.id, $0) })
        self.sourceFails = sourceFails
        self.sourceURL = sourceURL
        self.levelSourceURL = levelSourceURL
        self.delayedSongID = delayedSongID
        self.blocksStartReport = blocksStartReport
        self.reportGate = reportGate
        self.prefetchGate = prefetchGate
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
        if let prefetchGate, songID == prefetchGate.songID {
            return try await prefetchGate.source()
        }
        if sourceFails { throw URLError(.timedOut) }
        return PlaybackSource(
            url: sourceURL,
            availability: .playable(level: quality.cacheComponent)
        )
    }

    func playbackSource(for songID: Int64, level: String) async throws -> PlaybackSource {
        sourceRequests += 1
        requestedLevels.append(level)
        if sourceFails { throw URLError(.timedOut) }
        return PlaybackSource(
            url: levelSourceURL ?? sourceURL,
            availability: .playable(level: level)
        )
    }

    func songRequests() -> [[Int64]] { requestedSongIDs }
    func songResolutionCancellationCount() -> Int { songResolutionCancellations }
    func sourceRequestCount() -> Int { sourceRequests }
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
        try await reportGate?.run(.settlement, revision: expectedCredentialRevision)
    }
    func recordPodcastPlayback(
        for episodeID: Int64,
        positionMilliseconds: Int,
        completed: Bool,
        expectedCredentialRevision: UInt64
    ) async throws {
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

private func playerCredentials(_ token: String) throws -> SessionCredentials {
    try SessionCredentials(
        cookie: "MUSIC_U=fixture-\(token); __csrf=fixture",
        musicU: "vip-fixture-\(token)",
        deviceID: String(repeating: "D", count: 52)
    )
}

private func performanceWAV() -> Data {
    let sampleRate: UInt32 = 8_000
    let sampleCount: UInt32 = sampleRate * 2
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

private func appendLittleEndian<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
    var value = value.littleEndian
    withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
}
