import CoreGraphics
import Foundation
import Testing
@testable import TinyCloudMusic

private actor CacheLoadCounter {
    private var value = 0

    func increment() -> Int {
        value += 1
        return value
    }

    func count() -> Int { value }
}

private actor MutablePlaylistRepository: MusicRepository {
    nonisolated let homeDescriptors: [HomeSectionDescriptor] = []
    private var detailValue: DetailContent
    private var requestCount = 0
    private var cancellationsRemaining = 0

    init(detail: DetailContent) {
        detailValue = detail
    }

    func replaceDetail(_ detail: DetailContent) { detailValue = detail }
    func cancelNextDetailRequest() { cancellationsRemaining += 1 }
    func detailRequestCount() -> Int { requestCount }

    func detail(
        for route: Route,
        expectedCredentialRevision: UInt64?
    ) async throws -> DetailContent {
        requestCount += 1
        if cancellationsRemaining > 0 {
            cancellationsRemaining -= 1
            throw CancellationError()
        }
        return detailValue
    }

    func homeSection(
        id: String,
        expectedCredentialRevision: UInt64
    ) async throws -> HomeSection { throw AppError.invalidRoute }
    func search(query: String, scope: SearchScope, offset: Int, limit: Int) async throws -> SearchPage {
        throw AppError.invalidRoute
    }
    func songs(ids: [Int64]) async throws -> [Song] { [] }
    func lyrics(for songID: Int64) async throws -> SongLyrics { throw AppError.invalidRoute }
    func playbackSource(for songID: Int64, quality: AudioQuality) async throws -> PlaybackSource {
        throw AppError.invalidRoute
    }
    func playbackSource(for songID: Int64, level: String) async throws -> PlaybackSource {
        throw AppError.invalidRoute
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

@MainActor
private final class PlayerIntentRecorder {
    var intents: [PlayerControlIntent] = []
}

@MainActor
private func waitForPlaylistTrackCount(
    _ expected: Int,
    route: Route,
    model: AppModel
) async throws {
    for _ in 0..<100 {
        if case let .loaded(.playlist(playlist, _, _, _))? = model.detailLoads[route],
           playlist.trackCount == expected {
            return
        }
        try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("Timed out waiting for playlist track count \(expected)")
}

@Suite("Phase 0 core behavior")
struct CoreTests {
    @Test("EAPI request and album cache-key golden vectors")
    func eapiGoldenVectors() throws {
        let path = "/api/search/song/list/page"
        let json = Data(#"{"keyword":"Jay","limit":20}"#.utf8)
        let envelope = try EAPICodec.envelope(path: path, json: json)
        #expect(
            String(decoding: envelope, as: UTF8.self)
                == #"/api/search/song/list/page-36cd479b6b5-{"keyword":"Jay","limit":20}-36cd479b6b5-20141daa18b47b5a257341675323cde5"#
        )

        let expectedCipher = "74A595527B7A1647174ADDB4F261E92F180F42F921F98E9D338C60DB20AF499CEA90E95FB2FDA117A0B5D8175C2F21E526B15AF6D028297F4287F4DFA7898137564EB3B19846AC50AB05A9242E72C170FF8E303646DE796F2DF32538AD098FB18196B028974173E253935B19CEF651366AA3B102FBE7296AB0DB9EA5C46AD12B"
        #expect(String(decoding: try EAPICodec.requestBody(path: path, json: json), as: UTF8.self) == "params=\(expectedCipher)")
        #expect(try EAPICodec.albumCacheKey(id: 123) == "S2WmfZU6gkrjEY6XtcnFjA==")
        let weapiJSON = try compactJSON([
            "commentId": "99",
            "csrf_token": "csrf",
            "threadId": "R_SO_4_42"
        ])
        let weapi = try WEAPICodec.encryptedFields(json: weapiJSON, secretKey: "0123456789abcdef")
        #expect(
            weapi.params
                == "pVK6Mnsrq666FN3FThBqUPU0TlykSKttLnlfWS6reol9Yyr7N8FGFyxNEsFAQfxrP3qqZ/GA0EMuiNAzz+6/XyIRhxIWTB3wIfpA00WGhsWejBS/ZMua/hSQc9Q4LDZj"
        )
        #expect(
            weapi.encSecKey
                == "35701388baf89fed412e11269b9c76625d095ecaf17f03fa018abe19ea2d38b949debf242ee39a71ca1f6cda71b1b86a45aa909ee27f7e78e267d34e732f0de948206c3340a788d0003372183e2f753c1f78b66ac23d134ac1fc9b993156520ea826b8aa89a962d4491b4b8d7e08738e1da9b07aa39bf4a7ef0b1c210728cd52"
        )
        #expect(WEAPICodec.csrfToken(in: "MUSIC_U=session; __csrf=csrf=value; os=pc") == "csrf=value")
        let fallbackCookie = EAPICookieHeader.value(
            cookie: "MUSIC_A=session; __csrf=csrf",
            musicU: "",
            vip: true,
            buildVersion: 123,
            requestID: "request"
        )
        #expect(fallbackCookie.contains("MUSIC_A=session; __csrf=csrf"))
        #expect(fallbackCookie.contains("os=iPhone OS; appver=9.0.90"))
        #expect(!fallbackCookie.contains("os=Android"))
        let vipCookie = EAPICookieHeader.value(
            cookie: "MUSIC_A=session; __csrf=csrf",
            musicU: "vip-token",
            vip: true,
            buildVersion: 123,
            requestID: "request"
        )
        #expect(vipCookie.contains("MUSIC_U=vip-token"))
        #expect(vipCookie.hasSuffix("requestId=request"))
        let iPhoneVIPCookie = EAPICookieHeader.value(
            cookie: "QR_SESSION=qr-session; __csrf=csrf; MUSIC_U=embedded-token",
            musicU: "vip-token",
            vip: true,
            buildVersion: 123,
            requestID: "request",
            iPhoneClient: true
        )
        #expect(iPhoneVIPCookie.contains("MUSIC_U=vip-token"))
        #expect(!iPhoneVIPCookie.contains("QR_SESSION="))
        #expect(!iPhoneVIPCookie.contains("__csrf="))
        #expect(!iPhoneVIPCookie.contains("embedded-token"))
        let embeddedFallbackCookie = EAPICookieHeader.value(
            cookie: "__csrf=csrf; MUSIC_U=embedded-token",
            musicU: "",
            vip: true,
            buildVersion: 123,
            requestID: "request"
        )
        #expect(embeddedFallbackCookie.contains("MUSIC_U=embedded-token"))
        #expect(embeddedFallbackCookie.contains("os=iPhone OS; appver=9.0.90"))
        let normalCookie = EAPICookieHeader.value(
            cookie: "__csrf=csrf",
            musicU: "music-token",
            vip: false,
            buildVersion: 123,
            requestID: "request"
        )
        #expect(normalCookie.contains("os=iPhone OS; appver=9.0.90"))
        #expect(!normalCookie.contains("MUSIC_U=music-token"))
        #expect(normalCookie.hasSuffix("requestId=request"))
        #expect(!normalCookie.contains("deviceId="))
        #expect(
            SessionCredentialIssue.detect(
                in: Data(#"{"code":301}"#.utf8),
                vip: false,
                musicU: ""
            ) == .cookie
        )
        #expect(
            SessionCredentialIssue.detect(
                in: Data(#"{"code":301}"#.utf8),
                vip: true,
                musicU: "vip-token"
            ) == .musicU
        )
    }

    @Test("WEAPI fixed-key golden vector")
    func weapiGoldenVector() throws {
        let json = Data(#"{"alg":"RT","csrf_token":"","songId":11,"time":42}"#.utf8)
        let fields = try WEAPICodec.encryptedFields(json: json, secretKey: "abcdefghijklmnop")
        #expect(
            fields.params
                == "7wnCcDyzX3v9v3tWHDaCBP2iegEftxGjGvVOz+ZfaMnSmErqyc8j4R5uyJwIg0sVyXjdtB4fuYfdNa+p8VHOCaXtEa37KXfizVB8O1bGQiPf8jF3g1TCEXgWk3UNSGZl"
        )
        #expect(
            fields.encSecKey
                == "d15a1683c992095d0c234c19966605c5c5964911268bbeda8cb8d08d834913e59d53b32358903a121b5fca784c1f5ae44951fd02524df58ecc98e52cc7cf8689b42c2e93ddf05b0592512d87f5960467e2f086c018849d76014d323500e30f13ef4cafbb0cf5a66731a3f1776c75ca35d0062dac70a3e33245afabcf47938487"
        )
    }

    @Test("Queue context and selection rules")
    func queueContextAndSelectionRules() {
        let original = PlaybackContext(songIDs: [1, 2, 3], startIndex: 1)
        #expect(original == PlaybackContext(songIDs: [1, 2, 3], startIndex: 1))
        #expect(original != PlaybackContext(songIDs: [1, 2], startIndex: 1))
        #expect(original != PlaybackContext(songIDs: [1, 3, 2], startIndex: 1))
        #expect(original != PlaybackContext(songIDs: [1, 2, 3], startIndex: 0))

        #expect(
            PlaybackSelectionAction.decide(
                currentSongID: 2,
                isPlaying: true,
                currentContext: original,
                selectedSongID: 2,
                newContext: original
            ) == .keepPlaying
        )
        #expect(
            PlaybackSelectionAction.decide(
                currentSongID: 2,
                isPlaying: false,
                currentContext: original,
                selectedSongID: 2,
                newContext: original
            ) == .resume
        )
        #expect(
            PlaybackSelectionAction.decide(
                currentSongID: 2,
                isPlaying: false,
                currentContext: original,
                selectedSongID: 2,
                newContext: PlaybackContext(songIDs: [3, 2, 1], startIndex: 1)
            ) == .switchQueue(resume: true)
        )
        #expect(
            PlaybackSelectionAction.decide(
                currentSongID: 1,
                isPlaying: true,
                currentContext: original,
                selectedSongID: 2,
                newContext: original
            ) == .replaceTrackAtZero
        )

        #expect(PlaybackNavigation.nextIndex(currentIndex: 1, count: 3, repeatMode: .off, automatic: true) == 2)
        #expect(PlaybackNavigation.nextIndex(currentIndex: 2, count: 3, repeatMode: .all, automatic: true) == 0)
        #expect(PlaybackNavigation.nextIndex(currentIndex: 1, count: 3, repeatMode: .one, automatic: true) == 1)
        #expect(PlaybackNavigation.nextIndex(currentIndex: 1, count: 3, repeatMode: .one, automatic: false) == 2)
        #expect(PlaybackNavigation.previousIndex(currentIndex: 0, count: 3, repeatMode: .all) == 2)
    }

    @Test("Playlist playback uses every track ID before UI pagination finishes")
    @MainActor
    func fullPlaylistPlaybackQueue() async throws {
        let repository = FixtureMusicRepository()
        guard case let .playlist(_, songs, _, _) = try await repository.detail(for: .playlist(301)),
              let firstSong = songs.first
        else {
            Issue.record("Fixture playlist is empty")
            return
        }
        let trackIDs = [firstSong.id] + (1...657).map { Int64(1_000_000 + $0) }
        let player = PlayerController(repository: repository, crossfadeDuration: 0)

        player.play(firstSong, in: songs, allSongIDs: trackIDs)

        #expect(player.queue.count == 658)
        #expect(player.context?.songIDs == trackIDs)
        #expect(player.currentIndex == 0)
        player.toggleShuffle()
        #expect(player.canGoNext)
        let shuffledOrder = PlaybackNavigation.shuffledOrder(currentIndex: 0, count: trackIDs.count)
        #expect(shuffledOrder.first == 0)
        #expect(Set(shuffledOrder).count == trackIDs.count)
    }

    @Test("FM batches deduplicate stably and queue append preserves playback")
    @MainActor
    func personalFMQueueAppend() async throws {
        let repository = FixtureMusicRepository()
        guard case let .playlist(_, songs, _, _) = try await repository.detail(for: .playlist(301)),
              songs.count >= 3
        else {
            Issue.record("Fixture playlist is too small")
            return
        }
        let tracks = songs.prefix(3).map { PersonalFMTrack(song: $0, algorithm: "RT") }
        var requestedIDs: Set<Int64> = [tracks[0].id]
        let additions = PersonalFMController.newTracks(
            from: [tracks[0], tracks[1], tracks[1], tracks[2]],
            requestedIDs: &requestedIDs
        )
        #expect(additions.map(\.id) == [tracks[1].id, tracks[2].id])
        #expect(requestedIDs == Set(tracks.map(\.id)))
        #expect(
            !PersonalFMController.acceptsResponse(
                requestGeneration: 1,
                currentGeneration: 2,
                requestMode: .standard,
                currentMode: .explore,
                isCancelled: false
            )
        )

        let player = PlayerController(repository: repository, crossfadeDuration: 0)
        player.play(songs[0], in: Array(songs.prefix(2)))
        let currentID = player.currentSongID
        player.appendToQueue([songs[1], songs[2]])
        #expect(player.queue.map(\.id) == songs.prefix(3).map(\.id))
        #expect(player.currentSongID == currentID)
        #expect(player.currentIndex == 0)

        let removalPlayer = PlayerController(repository: repository, crossfadeDuration: 0)
        removalPlayer.play(songs[1], in: Array(songs.prefix(3)))
        removalPlayer.next()
        #expect(removalPlayer.removeFromQueue(songs[1].id))
        #expect(removalPlayer.queue.map(\.id) == [songs[0].id, songs[2].id])
        #expect(removalPlayer.currentSongID == songs[2].id)
        removalPlayer.previous()
        #expect(removalPlayer.currentSongID == songs[0].id)

        player.toggleShuffle()
        player.cycleRepeatMode()
        player.useLinearQueueMode()
        #expect(!player.isShuffleEnabled && player.repeatMode == .off)
        player.play(songs[2], in: Array(songs.prefix(3)))
        #expect(player.isShuffleEnabled && player.repeatMode == .all)
    }

    @Test("Shared playback disables local-only heart and repeat modes")
    @MainActor
    func sharedPlaybackModes() async throws {
        let repository = FixtureMusicRepository()
        guard case let .playlist(_, songs, _, _) = try await repository.detail(for: .playlist(301)),
              let song = songs.first
        else {
            Issue.record("Fixture playlist is empty")
            return
        }
        let player = PlayerController(repository: repository, crossfadeDuration: 0)
        player.play(song, in: songs)
        player.cycleRepeatMode()
        player.toggleHeartMode()

        player.controlInterceptor = { _, commit in
            commit()
            return true
        }

        #expect(player.isSharedControlActive)
        #expect(!player.isHeartModeEnabled)
        #expect(player.repeatMode == .off)
        player.toggleHeartMode()
        player.cycleRepeatMode()
        #expect(!player.isHeartModeEnabled)
        #expect(player.repeatMode == .off)

        player.controlInterceptor = nil
        #expect(!player.isSharedControlActive)
    }

    @Test("Previous and next preserve their shared-playback command types")
    @MainActor
    func sharedPlaybackTransitionTypes() async throws {
        let repository = FixtureMusicRepository()
        guard case let .playlist(_, songs, _, _) = try await repository.detail(for: .playlist(301)),
              songs.count >= 3
        else {
            Issue.record("Fixture playlist is too small")
            return
        }
        let player = PlayerController(repository: repository, crossfadeDuration: 0)
        player.play(songs[1], in: songs)
        let recorder = PlayerIntentRecorder()
        player.controlInterceptor = { intent, commit in
            recorder.intents.append(intent)
            commit()
            return true
        }

        player.next()
        player.previous()

        #expect(recorder.intents.count == 2)
        if case let .transition(kind, _, _, _, _) = recorder.intents.first?.play {
            #expect(kind == .next)
        } else {
            Issue.record("Next did not produce a transition intent")
        }
        if case let .transition(kind, _, _, _, _) = recorder.intents.last?.play {
            #expect(kind == .previous)
        } else {
            Issue.record("Previous did not produce a transition intent")
        }
    }

    @Test("Navigation rejects adjacent duplicates without flattening real history")
    @MainActor
    func navigationHistory() {
        let model = AppModel(repository: FixtureMusicRepository())
        let artist = Route.artist(101)
        let album = Route.album(201)

        model.open(artist)
        model.open(artist)
        #expect(model.path == [artist])

        model.open(album)
        model.open(artist)
        model.open(artist)
        #expect(model.path == [artist, album, artist])

        model.selectSidebar(.search)
        #expect(model.sidebar == .search)
        #expect(model.path.isEmpty)
        #expect(model.detailLoads.isEmpty)

        model.updateSearchQuery("周杰伦")
        model.open(artist)
        model.updateSearchQuery("")
        #expect(model.searchState.query == "周杰伦")
        model.path.removeAll()
        model.updateSearchQuery("")
        #expect(model.searchState.query.isEmpty)
    }

    @Test("Video playback and download qualities persist independently")
    @MainActor
    func videoQualitySettings() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let model = AppModel(repository: FixtureMusicRepository(), defaults: defaults)
        #expect(model.settings.videoPlaybackQuality == .high)
        #expect(model.settings.videoDownloadQuality == .high)
        #expect(model.downloadFolderURL.lastPathComponent == "歌曲")
        #expect(model.videoDownloadFolderURL.lastPathComponent == "视频")
        #expect(model.downloadFolderURL != model.videoDownloadFolderURL)

        model.setVideoPlaybackQuality(.lowest)
        model.setVideoDownloadQuality(.highest)
        let restored = AppModel(repository: FixtureMusicRepository(), defaults: defaults)
        #expect(restored.settings.videoPlaybackQuality == .lowest)
        #expect(restored.settings.videoDownloadQuality == .highest)
    }

    @Test("Playlist mutation keeps stale detail visible and revalidates it")
    @MainActor
    func playlistMutationRevalidation() async throws {
        let route = Route.playlist(901)
        var playlist = Playlist(
            id: 901,
            name: "Cached",
            creator: "Owner",
            description: "",
            artwork: Artwork(symbol: "music.note.list", accent: .green),
            trackCount: 1,
            specialType: 5
        )
        let repository = MutablePlaylistRepository(
            detail: .playlist(playlist, songs: [], trackIDs: [1], loadedTrackCount: 1)
        )
        let model = AppModel(
            repository: repository,
            defaults: UserDefaults(suiteName: UUID().uuidString)!
        )

        model.path = [route]
        model.loadDetail(route)
        try await waitForPlaylistTrackCount(1, route: route, model: model)
        var requestCount = await repository.detailRequestCount()
        #expect(requestCount == 1)

        model.path = []
        model.path = [route]
        model.loadDetail(route)
        requestCount = await repository.detailRequestCount()
        #expect(requestCount == 1)

        playlist.trackCount = 2
        await repository.replaceDetail(
            .playlist(playlist, songs: [], trackIDs: [1, 2], loadedTrackCount: 2)
        )
        await repository.cancelNextDetailRequest()
        model.playlistContentsDidChange(playlist.id)
        guard case let .loaded(.playlist(stale, _, _, _))? = model.detailLoads[route] else {
            Issue.record("Cached playlist disappeared during revalidation")
            return
        }
        #expect(stale.trackCount == 1)

        try await waitForPlaylistTrackCount(2, route: route, model: model)
        requestCount = await repository.detailRequestCount()
        #expect(requestCount == 3)
    }

    @Test("Favorite playlist mutations update liked song state")
    @MainActor
    func favoritePlaylistMutationUpdatesLikedSongs() {
        let model = AppModel(
            repository: FixtureMusicRepository(),
            defaults: UserDefaults(suiteName: UUID().uuidString)!
        )

        model.songPlaylistMembershipDidChange(
            1,
            playlistID: 901,
            isFavoritePlaylist: true,
            containsSong: true
        )
        #expect(model.likedSongIDs.contains(1))

        model.songPlaylistMembershipDidChange(
            1,
            playlistID: 901,
            isFavoritePlaylist: true,
            containsSong: false
        )
        #expect(!model.likedSongIDs.contains(1))

        model.songPlaylistMembershipDidChange(
            2,
            playlistID: 902,
            isFavoritePlaylist: false,
            containsSong: true
        )
        #expect(!model.likedSongIDs.contains(2))
    }

    @Test("Video subscription mutations update detail state and list revision")
    @MainActor
    func videoSubscriptionMutationUpdatesSharedState() {
        let model = AppModel(
            repository: FixtureMusicRepository(),
            defaults: UserDefaults(suiteName: UUID().uuidString)!
        )
        let mv = VideoPageResource.mv(42)
        let video = VideoPageResource.video("video-42")

        model.recordVideoSubscriptions([mv, video])
        #expect(model.videoSubscriptionOverrides[mv] == true)
        #expect(model.videoSubscriptionOverrides[video] == true)

        model.videoSubscriptionDidChange(video, subscribed: false)
        #expect(model.videoSubscriptionOverrides[video] == false)
        #expect(model.videoSubscriptionRevision == 1)
        #expect(model.loadedVideoSubscriptionRevision == 0)

        model.recordVideoSubscriptions([video])
        #expect(model.videoSubscriptionOverrides[video] == false)
        #expect(model.loadedVideoSubscriptionRevision == 1)
    }

    @Test("Playlist summaries expire by TTL and reject stale refreshes")
    @MainActor
    func playlistSummaryFreshness() {
        let model = AppModel(
            repository: FixtureMusicRepository(),
            defaults: UserDefaults(suiteName: UUID().uuidString)!
        )
        let loadedAt = Date(timeIntervalSince1970: 1_000)
        let original = Playlist(
            id: 902,
            name: "Liked",
            creator: "Owner",
            description: "",
            artwork: Artwork(symbol: "music.note.list", accent: .green),
            trackCount: 1,
            specialType: 5
        )
        let user = MusicLibraryUser(
            id: 1,
            nickname: "Owner",
            signature: "",
            detail: "",
            avatarURL: nil,
            gender: 0,
            level: 0,
            listenedSongCount: 0,
            followerCount: 0,
            followingCount: 0,
            isFollowed: false,
            followsCurrentUser: false
        )
        model.storeLibrarySnapshot(
            LibrarySnapshot(
                user: user,
                songs: [],
                playlists: [original],
                following: [],
                recommendedUsers: []
            ),
            playlistRevision: model.playlistContentRevision,
            loadedAt: loadedAt
        )
        #expect(model.cachedPlaylistsAreFresh(at: loadedAt.addingTimeInterval(89)))
        #expect(!model.cachedPlaylistsAreFresh(at: loadedAt.addingTimeInterval(90)))

        let staleRevision = model.playlistContentRevision
        model.playlistSummariesDidChange()
        var updated = original
        updated.trackCount = 2
        #expect(!model.storeCachedPlaylists([updated], playlistRevision: staleRevision))
        #expect(model.librarySnapshot?.playlists.first?.trackCount == 1)
        #expect(model.storeCachedPlaylists([updated], playlistRevision: model.playlistContentRevision))
        #expect(model.librarySnapshot?.playlists.first?.trackCount == 2)
    }

    @Test("Large playlists load 200 songs, then 100 at a time")
    func playlistSongPaging() {
        #expect(PlaylistSongPaging.initialRange(total: 50) == 0..<50)
        #expect(PlaylistSongPaging.initialRange(total: 500) == 0..<200)
        #expect(PlaylistSongPaging.nextRange(total: 500, loaded: 200) == 200..<300)
        #expect(PlaylistSongPaging.nextRange(total: 450, loaded: 400) == 400..<450)
        #expect(PlaylistSongPaging.nextRange(total: 450, loaded: 450) == nil)
    }

    @Test("Playlist detail hides empty similar recommendations")
    func playlistDetailSections() {
        #expect(PlaylistDetailSection.visible(hasSimilarPlaylists: false) == [.songs])
        #expect(PlaylistDetailSection.visible(hasSimilarPlaylists: true) == [.songs, .similarPlaylists])
    }

    @Test("Playlist metadata normalizes tags and plans only ordered changes")
    func playlistMetadataChanges() {
        let playlist = Playlist(
            id: 1,
            name: "原名",
            creator: "我",
            description: "旧描述",
            artwork: Artwork(symbol: "music.note.list", accent: .green),
            creatorID: 7,
            tags: ["摇滚"]
        )
        var draft = PlaylistMetadataDraft(playlist: playlist)
        #expect(draft.changes(from: playlist).isEmpty)

        draft.name = "  新名字  "
        draft.description = ""
        draft.tags = [" 摇滚 ", "", "学习", "摇滚", "华语", "超出"]
        #expect(draft.normalizedTags == ["摇滚", "学习", "华语"])
        #expect(draft.changes(from: playlist) == [
            .name("新名字"),
            .description(""),
            .tags(["摇滚", "学习", "华语"])
        ])

        draft = PlaylistMetadataDraft(playlist: playlist)
        draft.description = "新描述"
        #expect(draft.changes(from: playlist) == [.description("新描述")])
    }

    @Test("Only owned ordinary playlists are editable")
    func playlistMetadataEditability() {
        let playlist = Playlist(
            id: 1,
            name: "普通歌单",
            creator: "我",
            description: "",
            artwork: Artwork(symbol: "music.note.list", accent: .green),
            creatorID: 7
        )
        #expect(playlist.isUserEditable(by: 7))
        #expect(!playlist.isUserEditable(by: 8))
        #expect(!playlist.isUserEditable(by: nil))

        var special = playlist
        special.specialType = 5
        #expect(!special.isUserEditable(by: 7))

        var readOnly = playlist
        readOnly.isReadOnly = true
        #expect(!readOnly.isUserEditable(by: 7))

        var privatePlaylist = playlist
        privatePlaylist.privacy = 10
        #expect(privatePlaylist.isPrivate)
    }

    @Test("Crossfade trigger and equal-power gains")
    func crossfadeMath() {
        #expect(!CrossfadeTransition.shouldStart(position: 96, duration: 100, crossfadeDuration: 3))
        #expect(CrossfadeTransition.shouldStart(position: 97, duration: 100, crossfadeDuration: 3))
        #expect(!CrossfadeTransition.shouldStart(position: 100, duration: 100, crossfadeDuration: 0))

        let start = CrossfadeTransition.gains(progress: 0)
        let middle = CrossfadeTransition.gains(progress: 0.5)
        let end = CrossfadeTransition.gains(progress: 1)
        #expect(start.incoming == 0 && start.outgoing == 1)
        #expect(abs(middle.incoming * middle.incoming + middle.outgoing * middle.outgoing - 1) < 0.000_001)
        #expect(end.incoming == 1 && end.outgoing == 0)
    }

    @Test("Artwork requests are bounded, bucketed thumbnails")
    @MainActor
    func artworkRequestPolicy() throws {
        let url = try #require(URL(string: "https://example.com/artwork.png"))
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let small = try #require(ArtworkPipeline.request(for: url, size: CGSize(width: 44, height: 44), now: now))
        let nearby = try #require(ArtworkPipeline.request(for: url, size: CGSize(width: 56, height: 56), now: now))
        let retina = try #require(
            ArtworkPipeline.request(for: url, size: CGSize(width: 56, height: 56), displayScale: 2, now: now)
        )
        let expired = try #require(
            ArtworkPipeline.request(
                for: url,
                size: CGSize(width: 44, height: 44),
                now: now.addingTimeInterval(ArtworkPipeline.diskTTL)
            )
        )

        #expect(small.thumbnail == nearby.thumbnail)
        #expect(small.imageID == nearby.imageID)
        #expect(small.imageID != expired.imageID)
        #expect(retina.thumbnail != nearby.thumbnail)
        #expect(retina.scale == 2)
        #expect(ArtworkPipeline.request(for: URL(fileURLWithPath: "/tmp/image"), size: CGSize(width: 44, height: 44)) == nil)
        #expect(ArtworkPipeline.memoryCostLimit == 256 * 1_024 * 1_024)
        #expect(ArtworkPipeline.diskCostLimit == 512 * 1_024 * 1_024)
        #expect(ArtworkPipeline.maximumResponseSize == 25 * 1_024 * 1_024)
        #expect(ArtworkPipeline.isTransient(URLError(.timedOut)))
        #expect(!ArtworkPipeline.isTransient(URLError(.badURL)))

        let insecureNetease = try #require(URL(string: "http://p1.music.126.net/cover.jpg"))
        let secureRequest = try #require(
            ArtworkPipeline.request(for: insecureNetease, size: CGSize(width: 44, height: 44), now: now)
        )
        #expect(secureRequest.url?.scheme == "https")
        #expect(secureRequest.imageID?.hasPrefix("https://") == true)
        let protocolRelative = try #require(URL(string: "//p1.music.126.net/cover.jpg"))
        let protocolRelativeRequest = try #require(
            ArtworkPipeline.request(for: protocolRelative, size: CGSize(width: 44, height: 44), now: now)
        )
        #expect(protocolRelativeRequest.url?.absoluteString == "https://p1.music.126.net/cover.jpg")

        let watermarked = try #require(
            URL(string: "http://p1.music.126.net/cover.jpg?enlarge=1%7CimageView=1&image=dGVzdA==")
        )
        let secureWatermarked = ArtworkURLPolicy.secureURL(for: watermarked)
        #expect(
            secureWatermarked.absoluteString
                == "https://p1.music.126.net/cover.jpg?enlarge=1%7CimageView=1&image=dGVzdA=="
        )
        #expect(ArtworkURLPolicy.highResolutionURL(for: secureWatermarked) == secureWatermarked)

        let lowResolution = try #require(URL(string: "https://p1.music.126.net/cover.jpg?foo=bar&param=64y64"))
        let highResolution = ArtworkURLPolicy.highResolutionURL(for: lowResolution)
        let queryItems = try #require(URLComponents(url: highResolution, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(!queryItems.contains { $0.name == "param" })
        #expect(queryItems.contains(URLQueryItem(name: "foo", value: "bar")))
        #expect(ArtworkURLPolicy.highResolutionURL(for: url) == url)
    }

    @Test("Response cache coalesces reads and isolates accounts")
    func responseCacheCoalescingAndAccountIsolation() async throws {
        let cache = EAPIResponseCache()
        let counter = CacheLoadCounter()
        let accountA = EAPIResponseCache.Key(account: "a", request: "request")
        let accountB = EAPIResponseCache.Key(account: "b", request: "request")

        async let first = cache.value(for: accountA, ttl: 60, staleIfError: 60) {
            let count = await counter.increment()
            try await Task.sleep(for: .milliseconds(30))
            return Data("{\"code\":200,\"value\":\(count)}".utf8)
        }
        async let second = cache.value(for: accountA, ttl: 60, staleIfError: 60) {
            let count = await counter.increment()
            return Data("{\"code\":200,\"value\":\(count)}".utf8)
        }
        let (firstValue, secondValue) = try await (first, second)
        #expect(firstValue == secondValue)
        let coalescedCount = await counter.count()
        #expect(coalescedCount == 1)

        _ = try await cache.value(for: accountB, ttl: 60, staleIfError: 60) {
            let count = await counter.increment()
            return Data("{\"code\":200,\"value\":\(count)}".utf8)
        }
        let isolatedCount = await counter.count()
        #expect(isolatedCount == 2)

        await cache.invalidate(account: "a")
        _ = try await cache.value(for: accountA, ttl: 60, staleIfError: 60) {
            let count = await counter.increment()
            return Data("{\"code\":200,\"value\":\(count)}".utf8)
        }
        _ = try await cache.value(for: accountB, ttl: 60, staleIfError: 60) {
            let count = await counter.increment()
            return Data("{\"code\":200,\"value\":\(count)}".utf8)
        }
        let invalidatedCount = await counter.count()
        #expect(invalidatedCount == 3)
    }

    @Test("Response cache uses stale data only for transient failures")
    func responseCacheStaleIfError() async throws {
        let cache = EAPIResponseCache()
        let key = EAPIResponseCache.Key(account: "account", request: "request")
        let original = Data(#"{"code":200,"value":"cached"}"#.utf8)

        _ = try await cache.value(for: key, ttl: 0, staleIfError: 60) { original }
        let fallback = try await cache.value(for: key, ttl: 0, staleIfError: 60) {
            throw URLError(.timedOut)
        }
        #expect(fallback == original)

        do {
            _ = try await cache.value(for: key, ttl: 0, staleIfError: 60) {
                throw EAPIError.http(404)
            }
            Issue.record("Permanent HTTP errors must not use stale data")
        } catch let error as EAPIError {
            #expect(error == .http(404))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("LRC fractions, merge, and current line")
    func lrcFractionsMergeAndCurrentLine() {
        let lines = LRCParser.parse(
            primary: "[00:03.1]一\n[00:03.10]二\n[00:03.12]三\n[00:03.123]四\n[1:02]五",
            translation: "[00:03.100]One\n[01:02.000]Five"
        )

        #expect(lines.map(\.timestampMilliseconds) == [3_100, 3_120, 3_123, 62_000])
        #expect(lines[0].text == "一 / 二")
        #expect(lines[0].translation == "One")
        #expect(LRCParser.currentLine(in: lines, at: 3_099) == nil)
        #expect(LRCParser.currentLineIndex(in: lines, at: 3_122) == 1)
        #expect(LRCParser.currentLine(in: lines, at: 3_122)?.text == "三")
        #expect(LRCParser.currentLine(in: lines, at: 99_000)?.text == "五")
    }

    @Test("Menu bar lyrics animate only when wider than the viewport")
    func menuBarLyricMarquee() {
        #expect(MenuBarMarquee.duration(textWidth: 40, viewportWidth: 40, gap: 14) == nil)
        #expect(MenuBarMarquee.duration(textWidth: 56, viewportWidth: 40, gap: 14) == 2.5)
        #expect(MenuBarMarquee.offset(elapsed: 1.2, distance: 70) == 0)
        #expect(abs(MenuBarMarquee.offset(elapsed: 2.2, distance: 70) + 28) < 0.000_001)
        #expect(abs(MenuBarMarquee.offset(elapsed: 3.7, distance: 70)) < 0.000_001)
    }

    @Test("Word lyrics parse safely and merge exact-time annotations")
    func wordLyricsParsingAndMerge() throws {
        let lines = LRCParser.parse(
            SongLyrics(
                lineLyrics: "[00:16.210]普通回退\n[00:20.000]下一行",
                translatedLyrics: "[00:16.210]Not yet",
                romanizedLyrics: "[00:16.210]hai mei",
                wordLyrics: "{\"t\":0}\n[16210,3460](16210,670,0)还(16210,410,0)没\n[20000,1000](bad,300,0)坏(20200,300,0)好"
            )
        )

        #expect(lines.map(\.timestampMilliseconds) == [16_210, 20_000])
        let first = try #require(lines.first)
        #expect(first.durationMilliseconds == 3_460)
        #expect(first.text == "还没")
        #expect(first.translation == "Not yet")
        #expect(first.romanization == "hai mei")
        #expect(first.words.map(\.startMilliseconds) == [16_210, 16_210])
        #expect(first.words.map(\.durationMilliseconds) == [670, 410])
        #expect(first.words.map(\.text) == ["还", "没"])
        #expect(Set(first.words.map(\.id)).count == first.words.count)
        #expect(lines[1].text == "好")
    }

    @Test("Missing or unusable word timing falls back to LRC")
    func wordLyricsFallback() {
        let source = SongLyrics(
            lineLyrics: "[00:01.000]一\n[00:02.000]二",
            translatedLyrics: "[00:01.000]One",
            wordLyrics: "[1000,500](bad,200,0)坏"
        )
        #expect(LRCParser.parse(source) == LRCParser.parse(primary: source.lineLyrics, translation: source.translatedLyrics))
    }

    @Test("Near-aligned LRC and word lyrics render once")
    func nearAlignedWordLyricsDeduplicate() {
        let lines = LRCParser.parse(
            SongLyrics(
                lineLyrics: "[00:01.000]第一行\n[00:03.000]第二行\n[00:05.000]普通回退",
                wordLyrics: "[1120,1000](1120,1000,0)第一行\n[3180,1000](3180,1000,0)第二行"
            )
        )
        #expect(lines.map(\.timestampMilliseconds) == [1_120, 3_180, 5_000])
        #expect(lines.map(\.text) == ["第一行", "第二行", "普通回退"])
    }

    @Test("Current word keeps the previous highlight through timing gaps")
    func currentWordBoundaries() {
        let words = [
            LyricWord(startMilliseconds: 1_000, durationMilliseconds: 200, text: "一", sequence: 0),
            LyricWord(startMilliseconds: 1_500, durationMilliseconds: 100, text: "二", sequence: 1)
        ]
        #expect(LRCParser.currentWordIndex(in: words, at: 999) == nil)
        #expect(LRCParser.currentWordIndex(in: words, at: 1_000) == 0)
        #expect(LRCParser.currentWordIndex(in: words, at: 1_199) == 0)
        #expect(LRCParser.currentWordIndex(in: words, at: 1_200) == 0)
        #expect(LRCParser.currentWordIndex(in: words, at: 1_499) == 0)
        #expect(LRCParser.currentWordIndex(in: words, at: 1_500) == 1)
        #expect(LRCParser.currentWordIndex(in: words, at: 1_600) == 1)
        #expect(LRCParser.wordProgress(for: words[0], at: 999) == 0)
        #expect(abs(LRCParser.wordProgress(for: words[0], at: 1_100) - 0.5) < 0.000_001)
        #expect(LRCParser.wordProgress(for: words[0], at: 1_200) == 1)
        #expect(LRCParser.wordProgress(for: words[0], at: 1_499) == 1)
        #expect(LRCParser.wordProgress(for: words[1], at: 1_499) == 0)
        #expect(abs(LRCParser.wordProgress(for: words[1], at: 1_550) - 0.5) < 0.000_001)
        #expect(LRCParser.wordProgress(for: words[1], at: 1_600) == 1)
    }

    @Test("评论数量角标分档")
    func commentCountBadge() {
        #expect(CommentCountFormatter.string(9_999) == "9999")
        #expect(CommentCountFormatter.string(10_000) == "1w+")
        #expect(CommentCountFormatter.string(123_456) == "12w+")
    }
}
