import AppKit
import Foundation
import SwiftUI
import Testing
@testable import TinyCloudMusic

@Suite("Audio, FM, and video lifecycle", .serialized)
struct MediaLifecyclePerformanceTests {
    @Test("Only active media trees load and on-demand sections stay lazy")
    func viewStructure() throws {
        let audio = try source("AudioContentViews.swift")
        let audioHome = try slice(audio, from: "struct AudioContentView", to: "private struct PodcastDiscoveryView")
        let podcastDiscovery = try slice(
            audio,
            from: "private struct PodcastDiscoveryView",
            to: "private struct BroadcastDiscoveryView"
        )
        let podcastDetail = try slice(
            audio,
            from: "struct PodcastDetailView",
            to: "struct PodcastEpisodeDetailView"
        )
        let podcastSubscriptions = try slice(
            audio,
            from: "struct PodcastSubscriptionsView",
            to: "private struct PodcastRow"
        )
        let episodeDetail = try slice(audio, from: "struct PodcastEpisodeDetailView", to: "private struct PodcastLyricsSection")
        let episodeRow = try slice(audio, from: "struct EpisodeRow", to: "private struct BroadcastRow")
        let video = try source("VideoViews.swift")
        let detailLoad = try slice(video, from: "private func startLoad()", to: "private func startRelatedLoad")
        let fm = try source("PersonalFMView.swift")

        #expect(audioHome.contains("switch selectedTab"))
        #expect(!audioHome.contains("ZStack"))
        #expect(audioHome.contains("podcastState"))
        #expect(audioHome.contains("broadcastState"))
        #expect(podcastDiscovery.contains("podcastSubscriptionRevision"))
        #expect(podcastDiscovery.contains("displayedPodcasts"))
        #expect(podcastDiscovery.contains("state.loadedAccountID == model.currentUserID"))
        #expect(podcastDetail.contains("podcastSubscriptionRevision"))
        #expect(!podcastDetail.contains("model.setPodcastSubscribed"))
        #expect(podcastDetail.contains("library.setPodcastSubscribed"))
        #expect(podcastDetail.contains("writeTask"))
        #expect(podcastDetail.contains("cancelWrite()"))
        #expect(podcastDetail.contains(".disabled(writeTask != nil)"))
        #expect(podcastDetail.contains("loadedAccountID == model.currentUserID"))
        #expect(podcastSubscriptions.contains("podcastSubscriptionRevision"))
        #expect(podcastSubscriptions.contains("displayedPage"))
        #expect(!podcastSubscriptions.contains("podcastSubscriptionInsertions"))
        #expect(podcastSubscriptions.contains("loadedAccountID != model.currentUserID"))
        #expect(audio.contains("private struct PodcastLyricsSection"))
        #expect(!episodeDetail.contains("player.position"))
        #expect(audio.contains("if lyricTaskID == taskID"))
        #expect(episodeRow.contains(".exclusively(before:"))
        #expect(episodeRow.contains("podcast-episode-content-"))
        #expect(episodeRow.contains("podcast-episode-play-"))
        #expect(!episodeRow.contains(".onTapGesture"))

        #expect(video.contains("[.featured, .page(0)]"))
        #expect(video.contains("recommendationNextOffset = 8"))
        #expect(video.contains("relatedPhase == .notRequested"))
        #expect(video.contains(".onChange(of: selectedSection)"))
        #expect(!detailLoad.contains("startRelatedLoad"))
        #expect(video.contains("playbackTaskID == taskID"))
        #expect(video.contains("subscriptionRevision > loadedSubscriptionRevision"))
        #expect(!video.contains("subscriptionRevision > 0"))

        #expect(fm.contains("withObservationTracking"))
        #expect(fm.contains("queueIdentity"))
        #expect(fm.contains("requestTaskID == taskID"))
        #expect(fm.contains("trashTaskID == taskID"))
        #expect(!fm.contains("Task.sleep"))
        #expect(!fm.contains("while !Task.isCancelled"))
    }

    @MainActor
    @Test("Episode row sibling hit regions dispatch exactly one action")
    func episodeRowHitRegions() async throws {
        let song = Song(
            id: 301,
            name: "Episode audio",
            artists: [ArtistSummary(id: 1, name: "Host")],
            album: AlbumSummary(
                id: 2,
                name: "Podcast",
                artwork: Artwork(symbol: "waveform", accent: .red)
            ),
            duration: .seconds(90)
        )
        let episode = PodcastEpisode(
            id: 201,
            podcastID: 101,
            title: "Episode",
            coverURL: nil,
            durationMilliseconds: 90_000,
            publishedAt: nil,
            song: song
        )
        let actions = MediaActionRecorder()
        let hosting = NSHostingView(rootView: EpisodeRow(
            episode: episode,
            open: { actions.openCount += 1 },
            play: { actions.playCount += 1 }
        ))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 80),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = hosting
        window.orderFrontRegardless()
        hosting.layoutSubtreeIfNeeded()
        let contentPoint = hosting.convert(
            NSPoint(x: 120, y: hosting.bounds.midY),
            to: nil
        )

        mediaClick(window: window, location: contentPoint, clickCount: 1)
        try #require(await eventually(attempts: 1_000) {
            actions.openCount == 1 && actions.playCount == 0
        })
        #expect(actions.openCount == 1)
        #expect(actions.playCount == 0)

        actions.reset()
        mediaClick(window: window, location: contentPoint, clickCount: 1)
        mediaClick(window: window, location: contentPoint, clickCount: 2)
        try #require(await eventually(attempts: 1_000) {
            actions.openCount == 0 && actions.playCount == 1
        })
        #expect(actions.openCount == 0)
        #expect(actions.playCount == 1)

        actions.reset()
        let playButton = try #require(mediaSubviews(NSButton.self, in: hosting).last)
        #expect(!playButton.convert(playButton.bounds, to: hosting).contains(
            hosting.convert(contentPoint, from: nil)
        ))
        playButton.performClick(nil)
        #expect(actions.openCount == 0)
        #expect(actions.playCount == 1)
        window.isReleasedWhenClosed = false
        window.close()
    }

    @MainActor
    @Test("Podcast subscription requests cancel on disappearance and account change")
    func podcastSubscriptionLifecycle() async throws {
        let mutationPath = "/weapi/djradio/sub"

        MediaFixtureProtocol.reset(blockingPaths: [mutationPath])
        let firstSnapshot = CredentialSnapshot(.authenticated(try credentials("podcast-disappear")))
        let firstLibrary = LiveAudioContentLibrary(transport: fixtureTransport(snapshot: firstSnapshot))
        let firstSuite = "TinyCloudMusicTests.\(UUID())"
        let firstDefaults = UserDefaults(suiteName: firstSuite)!
        defer { firstDefaults.removePersistentDomain(forName: firstSuite) }
        let firstCacheRoot = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: firstCacheRoot) }
        let firstModel = AppModel(repository: FixtureMusicRepository(), defaults: firstDefaults)
        firstModel.currentUserID = 7
        let firstPlayer = PlayerController(
            repository: MediaBlockingRepository(),
            cacheRoot: firstCacheRoot,
            crossfadeDuration: 0
        )
        let firstHost = NSHostingView(rootView: PodcastDetailView(
            podcastID: 101,
            library: firstLibrary,
            model: firstModel,
            player: firstPlayer
        ))
        let firstWindow = mediaWindow(hosting: firstHost)
        #expect(await eventually { mediaSubviews(NSButton.self, in: firstHost).count == 1 })
        let firstButton = try #require(mediaSubviews(NSButton.self, in: firstHost).first)
        firstButton.performClick(nil)
        #expect(await eventually { MediaFixtureProtocol.requestCount(path: mutationPath) == 1 })
        firstWindow.contentView = NSView()
        #expect(await eventually { MediaFixtureProtocol.cancellationCount(path: mutationPath) == 1 })
        firstWindow.close()

        MediaFixtureProtocol.reset(blockingPaths: [mutationPath])
        let secondSnapshot = CredentialSnapshot(.authenticated(try credentials("podcast-account")))
        let secondLibrary = LiveAudioContentLibrary(transport: fixtureTransport(snapshot: secondSnapshot))
        let secondSuite = "TinyCloudMusicTests.\(UUID())"
        let secondDefaults = UserDefaults(suiteName: secondSuite)!
        defer { secondDefaults.removePersistentDomain(forName: secondSuite) }
        let secondCacheRoot = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: secondCacheRoot) }
        let secondModel = AppModel(repository: FixtureMusicRepository(), defaults: secondDefaults)
        secondModel.currentUserID = 7
        let secondPlayer = PlayerController(
            repository: MediaBlockingRepository(),
            cacheRoot: secondCacheRoot,
            crossfadeDuration: 0
        )
        let secondHost = NSHostingView(rootView: PodcastDetailView(
            podcastID: 101,
            library: secondLibrary,
            model: secondModel,
            player: secondPlayer
        ))
        let secondWindow = mediaWindow(hosting: secondHost)
        #expect(await eventually { mediaSubviews(NSButton.self, in: secondHost).count == 1 })
        let secondButton = try #require(mediaSubviews(NSButton.self, in: secondHost).first)
        secondButton.performClick(nil)
        #expect(await eventually { MediaFixtureProtocol.requestCount(path: mutationPath) == 1 })
        secondModel.currentUserID = 8
        secondHost.layoutSubtreeIfNeeded()
        #expect(await eventually { MediaFixtureProtocol.cancellationCount(path: mutationPath) == 1 })
        secondWindow.close()
    }

    @Test("Podcast fallback accepts only compatibility failures")
    func podcastFallbackClassification() async throws {
        let fallbackEpisode = PodcastEpisode(
            id: 7,
            podcastID: 8,
            title: "Fallback",
            coverURL: nil,
            durationMilliseconds: 1_000,
            publishedAt: nil,
            song: nil
        )

        for error in [EAPIError.http(401), .http(500), .invalidResponse, .missingData("data")] {
            var fallbackCalls = 0
            do {
                _ = try await PodcastEpisodeEndpointFallback.load(
                    primary: { throw error },
                    fallback: {
                        fallbackCalls += 1
                        return fallbackEpisode
                    }
                )
                Issue.record("Non-compatibility error used the fallback endpoint")
            } catch let thrown as EAPIError {
                #expect(thrown == error)
            }
            #expect(fallbackCalls == 0)
        }

        var cancellationFallbackCalls = 0
        do {
            _ = try await PodcastEpisodeEndpointFallback.load(
                primary: { throw CancellationError() },
                fallback: {
                    cancellationFallbackCalls += 1
                    return fallbackEpisode
                }
            )
            Issue.record("Cancellation used the fallback endpoint")
        } catch is CancellationError {
        }
        #expect(cancellationFallbackCalls == 0)

        for compatibilityError in [
            EAPIError.http(404), .http(410), .service(code: 404, message: "missing"),
            .service(code: 410, message: "gone"), .missingData("program")
        ] {
            var fallbackCalls = 0
            let loaded = try await PodcastEpisodeEndpointFallback.load(
                primary: { throw compatibilityError },
                fallback: {
                    fallbackCalls += 1
                    return fallbackEpisode
                }
            )
            #expect(loaded == fallbackEpisode)
            #expect(fallbackCalls == 1)
        }
    }

    @MainActor
    @Test("Internal cache invalidation retries once while real cancellation stays cancellation")
    func cancellationAndRefreshClassification() async throws {
        let cache = EAPIResponseCache()
        let calls = MediaCounter()
        let key = EAPIResponseCache.Key(account: "media", request: "loading", group: .detail)
        let loading = Task {
            try await cache.value(for: key, ttl: 60, staleIfError: 60) {
                if await calls.next() == 1 { try await Task.sleep(for: .seconds(60)) }
                return Data("loaded".utf8)
            }
        }
        #expect(await eventually { await calls.value == 1 })
        await cache.invalidate(account: "media", groups: [.detail])
        #expect(try await loading.value == Data("loaded".utf8))
        #expect(await calls.value == 2)

        let cancellationCalls = MediaCounter()
        let cancelled = Task {
            try await cache.value(
                for: EAPIResponseCache.Key(account: "media", request: "cancelled", group: .lyrics),
                ttl: 60,
                staleIfError: 60
            ) {
                _ = await cancellationCalls.next()
                try await Task.sleep(for: .seconds(60))
                return Data()
            }
        }
        #expect(await eventually { await cancellationCalls.value == 1 })
        cancelled.cancel()
        do {
            _ = try await cancelled.value
            Issue.record("Real cancellation was swallowed")
        } catch is CancellationError {
        }
        #expect(await cancellationCalls.value == 1)

        let refreshKey = EAPIResponseCache.Key(account: "media", request: "refresh", group: .library)
        _ = try await cache.value(for: refreshKey, ttl: 60, staleIfError: 60) { Data("A".utf8) }
        let refreshed = try await cache.value(
            for: refreshKey,
            ttl: 60,
            staleIfError: 60,
            refresh: true
        ) { Data("B".utf8) }
        let regular = try await cache.value(for: refreshKey, ttl: 60, staleIfError: 60) {
            Issue.record("Regular read fell back behind the refreshed value")
            return Data("C".utf8)
        }
        #expect(refreshed == Data("B".utf8))
        #expect(regular == Data("B".utf8))
    }

    @Test("Domain mutations keep unrelated cached reads")
    func directedMutationInvalidation() async throws {
        let snapshot = CredentialSnapshot(.authenticated(try credentials("directed")))
        MediaFixtureProtocol.reset()
        let transport = fixtureTransport(snapshot: snapshot)
        let cached = EAPIEndpoint(
            "/domain-cache",
            host: "https://music.163.com",
            responseEncoding: .json
        )

        _ = try await transport.request(cached, json: Data(), cache: .search)
        let revision = snapshot.load().revision
        try await LiveAudioContentLibrary(transport: transport).setPodcastSubscribed(
            1,
            subscribed: true,
            expectedCredentialRevision: revision
        )
        try await LiveAudioContentLibrary(transport: transport).setBroadcastCollected(
            "2",
            collected: true,
            expectedCredentialRevision: revision
        )
        try await LiveVideoLibrary(transport: transport).setMVSubscribed(
            3,
            subscribed: true,
            expectedCredentialRevision: revision
        )
        try await LiveVideoLibrary(transport: transport).setVideoSubscribed(
            "video-4",
            subscribed: true,
            expectedCredentialRevision: revision
        )
        _ = try await transport.request(cached, json: Data(), cache: .search)

        #expect(MediaFixtureProtocol.requestCount(path: "/domain-cache") == 1)
        #expect(MediaFixtureProtocol.requestCount(path: "/weapi/djradio/sub") == 1)
        #expect(MediaFixtureProtocol.requestCount(path: "/eapi/content/interact/collect") == 1)
        #expect(MediaFixtureProtocol.requestCount(path: "/weapi/mv/sub") == 1)
        #expect(MediaFixtureProtocol.requestCount(path: "/weapi/cloudvideo/video/sub") == 1)
    }

    @Test("Video subscription refresh is consumed after one forced replacement")
    func videoSubscriptionRefreshCount() async throws {
        let snapshot = CredentialSnapshot(.authenticated(try credentials("video-subscriptions")))
        MediaFixtureProtocol.reset()
        let library = LiveVideoLibrary(transport: fixtureTransport(snapshot: snapshot))
        let revision = snapshot.load().revision

        _ = try await library.subscriptions(expectedCredentialRevision: revision)
        _ = try await library.subscriptions(
            refreshCache: true,
            expectedCredentialRevision: revision
        )
        _ = try await library.subscriptions(expectedCredentialRevision: revision)

        #expect(MediaFixtureProtocol.requestCount(
            path: "/weapi/cloudvideo/allvideo/sublist"
        ) == 2)
    }

    @MainActor
    @Test("FM continues off-screen only while its queue session remains active")
    func fmEventDrivenLifecycle() async throws {
        let snapshot = CredentialSnapshot(.authenticated(try credentials("fm-session")))
        MediaFixtureProtocol.reset()
        let cacheRoot = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: cacheRoot) }
        let player = PlayerController(
            repository: MediaBlockingRepository(),
            cacheRoot: cacheRoot,
            crossfadeDuration: 0
        )
        let controller = PersonalFMController(
            library: LiveMusicLibrary(transport: fixtureTransport(snapshot: snapshot)),
            player: player,
            onTrashSucceeded: {}
        )

        controller.setAccount(7)
        controller.start(userID: 7)
        #expect(await eventually {
            controller.tracks.count == 3 && player.queueIdentity?.sessionID != nil
        })
        #expect(controller.tracks.count == 3)
        #expect(player.queue.count == 3)
        #expect(player.currentIndex == 0)
        #expect(MediaFixtureProtocol.requestCount(path: "/eapi/v1/radio/get") == 1)

        try await Task.sleep(for: .milliseconds(50))
        #expect(controller.tracks.count == 3)
        #expect(player.queue.count == 3)
        #expect(player.currentIndex == 0)
        #expect(MediaFixtureProtocol.requestCount(path: "/eapi/v1/radio/get") == 1)

        player.next()
        #expect(await eventually {
            controller.tracks.count == 6
                && MediaFixtureProtocol.requestCount(path: "/eapi/v1/radio/get") == 2
        })

        let ordinarySongs = controller.tracks.map(\.song)
        let currentSong = try #require(player.currentSong)
        player.play(currentSong, in: ordinarySongs)
        #expect(await eventually { controller.tracks.isEmpty })
        #expect(player.queueIdentity?.sessionID == nil)
        let stoppedRequestCount = MediaFixtureProtocol.requestCount(path: "/eapi/v1/radio/get")
        try await Task.sleep(for: .milliseconds(50))
        #expect(MediaFixtureProtocol.requestCount(path: "/eapi/v1/radio/get") == stoppedRequestCount)

        controller.setAccount(nil)
        #expect(controller.tracks.isEmpty)
    }

    @MainActor
    @Test("An ordinary queue replacement wins before the first FM batch returns")
    func fmPreinstallQueueReplacement() async throws {
        let snapshot = CredentialSnapshot(.authenticated(try credentials("fm-preinstall")))
        let fmPath = "/eapi/v1/radio/get"
        MediaFixtureProtocol.reset(blockingPaths: [fmPath])
        let cacheRoot = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: cacheRoot) }
        let player = PlayerController(
            repository: MediaBlockingRepository(),
            cacheRoot: cacheRoot,
            crossfadeDuration: 0
        )
        let controller = PersonalFMController(
            library: LiveMusicLibrary(
                transport: fixtureTransport(snapshot: snapshot)
            ),
            player: player,
            onTrashSucceeded: {}
        )

        controller.setAccount(8)
        controller.start(userID: 8)
        #expect(await eventually { MediaFixtureProtocol.requestCount(path: fmPath) == 1 })
        let songs = (11...13).map { id in
            Song(
                id: Int64(id),
                name: "Ordinary \(id)",
                artists: [ArtistSummary(id: 1, name: "Artist")],
                album: AlbumSummary(
                    id: 1,
                    name: "Album",
                    artwork: Artwork(symbol: "music.note", accent: .blue)
                ),
                duration: .seconds(180)
            )
        }
        player.play(songs[0], in: songs)
        #expect(await eventually {
            !controller.isLoading && MediaFixtureProtocol.cancellationCount(path: fmPath) == 1
        })

        #expect(controller.tracks.isEmpty)
        #expect(player.queue.map(\.id) == songs.map(\.id))
        #expect(player.queueIdentity?.sessionID == nil)
        #expect(MediaFixtureProtocol.requestCount(path: fmPath) == 1)
    }

    @MainActor
    @Test("Old-account FM and mutation intents stop before sending")
    func credentialRevisionFences() async throws {
        let snapshot = CredentialSnapshot(.authenticated(try credentials("account-a")))
        let revisionA = snapshot.load().revision
        let mutationGate = MediaGate()
        MediaFixtureProtocol.reset()
        let mutationTransport = fixtureTransport(snapshot: snapshot) { await mutationGate.wait() }
        let mutation = Task {
            try await LiveAudioContentLibrary(transport: mutationTransport).setPodcastSubscribed(
                1,
                subscribed: true,
                expectedCredentialRevision: revisionA
            )
        }
        #expect(await eventually { await mutationGate.hasEntered })
        _ = snapshot.store(.authenticated(try credentials("account-b")))
        await mutationGate.release()
        do {
            try await mutation.value
            Issue.record("Old-account mutation was sent")
        } catch is CredentialRevisionMismatch {
        }
        #expect(MediaFixtureProtocol.requestCount == 0)

        let fmGate = MediaGate()
        MediaFixtureProtocol.reset()
        let fmTransport = fixtureTransport(snapshot: snapshot) { await fmGate.wait() }
        let cacheRoot = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: cacheRoot) }
        let player = PlayerController(
            repository: FixtureMusicRepository(),
            cacheRoot: cacheRoot,
            crossfadeDuration: 0
        )
        let controller = PersonalFMController(
            library: LiveMusicLibrary(transport: fmTransport),
            player: player,
            onTrashSucceeded: {}
        )
        controller.setAccount(2)
        controller.start(userID: 2)
        #expect(await eventually { await fmGate.hasEntered })
        _ = snapshot.store(.authenticated(try credentials("account-c")))
        controller.setAccount(3)
        await fmGate.release()
        #expect(await eventually { !controller.isLoading })
        #expect(controller.tracks.isEmpty)
        #expect(player.queue.isEmpty)
        #expect(MediaFixtureProtocol.requestCount == 0)
    }

    @Test("FM provenance and retained state stay bounded")
    func fmBoundsAndProvenance() {
        let session = UUID()
        let sameIDs = [Int64(1), 2, 3]
        let fmIdentity = PlayerQueueIdentity(
            displaySongIDs: sameIDs,
            randomSongIDs: sameIDs,
            sourcePlaylistID: nil,
            sessionID: session
        )
        let ordinaryIdentity = PlayerQueueIdentity(
            displaySongIDs: sameIDs,
            randomSongIDs: sameIDs,
            sourcePlaylistID: nil,
            sessionID: nil
        )
        #expect(PersonalFMRetention.isActive(sessionID: session, queueIdentity: fmIdentity))
        #expect(!PersonalFMRetention.isActive(sessionID: session, queueIdentity: ordinaryIdentity))

        var recent = PersonalFMRecentIDs(limit: PersonalFMRetention.recentIDLimit)
        for id in 0..<10_000 { _ = recent.insert(Int64(id)) }
        #expect(recent.values.count == PersonalFMRetention.recentIDLimit)
        #expect(!recent.values.contains(0))
        #expect(recent.values.contains(9_999))

        let queue = (0..<10_000).map { PlaybackQueueItem(id: Int64($0), song: nil) }
        let stale = PersonalFMRetention.staleConsumedSongIDs(queue: queue, currentIndex: 9_999)
        #expect(stale.count == 9_997)
        #expect(queue.count - stale.count == PersonalFMRetention.consumedTrackLimit + 1)
    }

    @Test("Every lyric tick performs one lookup")
    func lyricLookupCount() {
        let lines = (0..<1_000).map {
            LyricLine(timestampMilliseconds: Int64($0 * 1_000), text: "Line \($0)")
        }
        var lookups = 0
        for tick in 0..<100 {
            let id = PodcastLyricLocator.currentLineID(
                in: lines,
                at: Int64(tick * 1_000),
                lookup: { lines, milliseconds in
                    lookups += 1
                    return LRCParser.currentLineIndex(in: lines, at: milliseconds)
                }
            )
            #expect(id == Int64(tick * 1_000))
        }
        #expect(lookups == 100)
    }

    @Test("All media pages stop on unique-content no-progress")
    func paginationNoProgress() {
        let podcast = Podcast(
            id: 1,
            name: "Podcast",
            hostName: "Host",
            coverURL: nil,
            categoryName: "Category",
            isSubscribed: false
        )
        let podcasts = PodcastPage(podcasts: [podcast], nextOffset: 1, hasMore: true)
            .appending(PodcastPage(podcasts: [podcast], nextOffset: 2, hasMore: true))
        #expect(podcasts.podcasts.count == 1)
        #expect(!podcasts.hasMore)

        let episode = PodcastEpisode(
            id: 2,
            podcastID: 1,
            title: "Episode",
            coverURL: nil,
            durationMilliseconds: 1_000,
            publishedAt: nil,
            song: nil
        )
        let episodes = PodcastEpisodePage(episodes: [episode], nextOffset: 1, hasMore: true)
            .appending(PodcastEpisodePage(episodes: [episode], nextOffset: 2, hasMore: true))
        #expect(episodes.episodes.count == 1)
        #expect(!episodes.hasMore)

        let channel = BroadcastChannel(
            id: "1",
            name: "Channel",
            regionName: "",
            coverURL: nil,
            isCollected: false
        )
        let cursorA = BroadcastCursor(lastID: "a", score: "1")
        let cursorB = BroadcastCursor(lastID: "b", score: "2")
        let first = BroadcastChannelPage(channels: [channel], nextCursor: cursorA, hasMore: true)
        let second = BroadcastChannelPage(
            channels: [channel.settingCollected(true)],
            nextCursor: cursorB,
            hasMore: true
        )
        #expect(!first.appending(second).hasMore)

        let item = VideoRecommendation.mv(MVSummary(
            id: 3,
            title: "MV",
            artistName: "Artist",
            coverURL: nil,
            durationMilliseconds: 1_000
        ))
        let videos = VideoSubscriptionPage(items: [item], nextOffset: 1, hasMore: true)
            .appending(VideoSubscriptionPage(items: [item], nextOffset: 2, hasMore: true))
        #expect(videos.items.count == 1)
        #expect(!videos.hasMore)

        let videoSource = try? source("VideoViews.swift")
        #expect(videoSource?.contains("var seen = Set(reset ? [] : comments.map(\\.id))") == true)
        #expect(videoSource?.contains("!additions.isEmpty") == true)
    }

    private func source(_ name: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Sources/TinyCloudMusic")
        return try String(contentsOf: root.appending(path: name), encoding: .utf8)
    }

    private func slice(_ value: String, from start: String, to end: String) throws -> String {
        let lower = try #require(value.range(of: start)?.lowerBound)
        let upper = try #require(value.range(of: end, range: lower..<value.endIndex)?.lowerBound)
        return String(value[lower..<upper])
    }

    private func fixtureTransport(
        snapshot: CredentialSnapshot,
        beforeSendingRequest: (@Sendable () async -> Void)? = nil
    ) -> EAPITransport {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MediaFixtureProtocol.self]
        return EAPITransport(
            session: URLSession(configuration: configuration),
            credentialSnapshot: snapshot,
            beforeSendingRequest: beforeSendingRequest
        )
    }

    private func credentials(_ token: String) throws -> SessionCredentials {
        try SessionCredentials(
            cookie: "MUSIC_U=\(token); __csrf=fixture",
            musicU: "fixture-\(token)",
            deviceID: "0123456789abcdef0123456789abcdef"
        )
    }

    @MainActor
    private func eventually(attempts: Int = 200, _ condition: () async -> Bool) async -> Bool {
        for _ in 0..<attempts {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return false
    }
}

@MainActor
private final class MediaActionRecorder {
    var openCount = 0
    var playCount = 0

    func reset() {
        openCount = 0
        playCount = 0
    }
}

@MainActor
private func mediaSubviews<View: NSView>(_ type: View.Type, in root: NSView) -> [View] {
    var matches: [View] = []
    if let match = root as? View { matches.append(match) }
    for child in root.subviews {
        matches.append(contentsOf: mediaSubviews(type, in: child))
    }
    return matches
}

@MainActor
private func mediaWindow<Content: View>(hosting: NSHostingView<Content>) -> NSWindow {
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 720, height: 560),
        styleMask: [.borderless],
        backing: .buffered,
        defer: false
    )
    window.isReleasedWhenClosed = false
    window.contentView = hosting
    window.orderFrontRegardless()
    hosting.layoutSubtreeIfNeeded()
    return window
}

@MainActor
private func mediaClick(window: NSWindow, location: NSPoint, clickCount: Int) {
    let timestamp = ProcessInfo.processInfo.systemUptime
    let down = NSEvent.mouseEvent(
        with: .leftMouseDown,
        location: location,
        modifierFlags: [],
        timestamp: timestamp,
        windowNumber: window.windowNumber,
        context: nil,
        eventNumber: clickCount * 2 - 1,
        clickCount: clickCount,
        pressure: 1
    )!
    let up = NSEvent.mouseEvent(
        with: .leftMouseUp,
        location: location,
        modifierFlags: [],
        timestamp: timestamp + 0.01,
        windowNumber: window.windowNumber,
        context: nil,
        eventNumber: clickCount * 2,
        clickCount: clickCount,
        pressure: 0
    )!
    window.sendEvent(down)
    window.sendEvent(up)
}

private actor MediaGate {
    private(set) var hasEntered = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        hasEntered = true
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

private actor MediaCounter {
    private var count = 0

    var value: Int { count }

    func next() -> Int {
        count += 1
        return count
    }
}

private struct MediaBlockingRepository: MusicRepository {
    private let fixture = FixtureMusicRepository()

    var homeDescriptors: [HomeSectionDescriptor] { fixture.homeDescriptors }
    func homeSection(
        id: String,
        expectedCredentialRevision: UInt64
    ) async throws -> HomeSection {
        try await fixture.homeSection(
            id: id,
            expectedCredentialRevision: expectedCredentialRevision
        )
    }
    func search(query: String, scope: SearchScope, offset: Int, limit: Int) async throws -> SearchPage {
        try await fixture.search(query: query, scope: scope, offset: offset, limit: limit)
    }
    func detail(
        for route: Route,
        expectedCredentialRevision: UInt64?
    ) async throws -> DetailContent {
        try await fixture.detail(
            for: route,
            expectedCredentialRevision: expectedCredentialRevision
        )
    }
    func songs(ids: [Int64]) async throws -> [Song] { try await fixture.songs(ids: ids) }
    func lyrics(for songID: Int64) async throws -> SongLyrics { try await fixture.lyrics(for: songID) }
    func playbackSource(for songID: Int64, quality: AudioQuality) async throws -> PlaybackSource {
        try await Task.sleep(for: .seconds(60))
        throw CancellationError()
    }
    func playbackSource(for songID: Int64, level: String) async throws -> PlaybackSource {
        try await Task.sleep(for: .seconds(60))
        throw CancellationError()
    }
    func songQualityDetails(for songID: Int64) async throws -> [SongQualityDetail] { [] }
    func recordPlaybackStart(
        for songID: Int64,
        sourceID: Int64,
        totalSeconds: Int,
        expectedCredentialRevision: UInt64
    ) async throws {}
    func recordPlayback(
        for songID: Int64,
        sourceID: Int64,
        playedSeconds: Int,
        totalSeconds: Int,
        expectedCredentialRevision: UInt64
    ) async throws {}
    func recordPodcastPlayback(
        for episodeID: Int64,
        positionMilliseconds: Int,
        completed: Bool,
        expectedCredentialRevision: UInt64
    ) async throws {}
}

private final class MediaFixtureState: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [String: Int] = [:]
    private var cancellationCounts: [String: Int] = [:]
    private var blockingPaths: Set<String> = []

    func reset(blockingPaths: Set<String>) {
        lock.withLock {
            counts = [:]
            cancellationCounts = [:]
            self.blockingPaths = blockingPaths
        }
    }

    func record(_ path: String) -> Int {
        lock.withLock {
            counts[path, default: 0] += 1
            return counts[path, default: 0]
        }
    }

    var count: Int { lock.withLock { counts.values.reduce(0, +) } }

    func count(path: String) -> Int { lock.withLock { counts[path, default: 0] } }
    func isBlocked(path: String) -> Bool { lock.withLock { blockingPaths.contains(path) } }
    func recordCancellation(path: String) {
        lock.withLock { cancellationCounts[path, default: 0] += 1 }
    }
    func cancellationCount(path: String) -> Int {
        lock.withLock { cancellationCounts[path, default: 0] }
    }
}

private final class MediaFixtureProtocol: URLProtocol, @unchecked Sendable {
    private static let state = MediaFixtureState()

    static var requestCount: Int { state.count }
    static func requestCount(path: String) -> Int { state.count(path: path) }
    static func cancellationCount(path: String) -> Int { state.cancellationCount(path: path) }
    static func reset(blockingPaths: Set<String> = []) { state.reset(blockingPaths: blockingPaths) }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let path = request.url?.path ?? ""
        let requestNumber = Self.state.record(path)
        if Self.state.isBlocked(path: path) { return }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let body = if path == "/eapi/v1/radio/get" {
            Data("""
            {"code":200,"data":[
              {"id":\(requestNumber * 10 + 1),"name":"FM 1","ar":[{"id":1,"name":"Artist"}],"al":{"id":1,"name":"Album"},"dt":180000},
              {"id":\(requestNumber * 10 + 2),"name":"FM 2","ar":[{"id":1,"name":"Artist"}],"al":{"id":1,"name":"Album"},"dt":180000},
              {"id":\(requestNumber * 10 + 3),"name":"FM 3","ar":[{"id":1,"name":"Artist"}],"al":{"id":1,"name":"Album"},"dt":180000}
            ]}
            """.utf8)
        } else if path == "/weapi/djradio/v2/get" {
            Data(#"{"code":200,"data":{"id":101,"name":"Podcast","dj":{"nickname":"Host"},"category":"Category","subed":false}}"#.utf8)
        } else if path == "/weapi/dj/program/byradio" {
            Data(#"{"code":200,"programs":[],"more":false}"#.utf8)
        } else {
            Data(#"{"code":200}"#.utf8)
        }
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {
        let path = request.url?.path ?? ""
        if Self.state.isBlocked(path: path) {
            Self.state.recordCancellation(path: path)
        }
    }
}
