import Foundation
import AVFoundation
import OSLog
import SwiftUI
import UIKit
import XCTest
@testable import TinyCloudMusic

final class IOSNavigationTests: XCTestCase {
    @MainActor
    func testCloudPaginationKeepsAllSongsAcrossFourPages() {
        var result: CloudSongPage?
        var offsets: [Int] = []
        for pageIndex in 0..<4 {
            let offset = IOSCloudMusicView.nextOffset(after: result)
            offsets.append(offset)
            let page = CloudSongPage(
                songs: (offset..<(offset + IOSCloudMusicView.pageSize)).map { id in
                    CloudSong(
                        id: Int64(id), song: nil, name: "Track \(id)", artist: "", album: "",
                        fileName: "", fileSize: 0, addedAt: nil
                    )
                },
                offset: offset,
                hasMore: pageIndex < 3,
                totalCount: 120
            )
            result = result?.appending(page) ?? page
        }
        XCTAssertEqual(offsets, [0, 30, 60, 90])
        XCTAssertEqual(result?.songs.map(\.id), (0..<120).map(Int64.init))
        XCTAssertEqual(result?.hasMore, false)
    }

    @MainActor
    func testPersonalFMRowAndMenusKeepQueueSession() throws {
        let suite = "TinyCloudMusicTests.FMSelection.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let repository = FixtureMusicRepository()
        let model = AppModel(repository: repository, defaults: defaults, bookmarkResolver: { _ in nil })
        let cacheRoot = FileManager.default.temporaryDirectory.appending(path: suite)
        defer { try? FileManager.default.removeItem(at: cacheRoot) }
        let player = PlayerController(repository: repository, cacheRoot: cacheRoot, crossfadeDuration: 0)
        let album = AlbumSummary(id: 1, name: "FM", artwork: Artwork(symbol: "radio", accent: .red))
        let songs = (1...2).map {
            Song(id: Int64($0), name: "Track \($0)", artists: [], album: album, duration: .seconds(180))
        }
        let sessionID = UUID()
        player.play(songs[0], in: songs, queueSessionID: sessionID)
        player.useLinearQueueMode()
        for song in songs {
            let row = IOSSongRow(
                song: song,
                songs: songs,
                onPlay: { player.playQueuedSong(song.id) },
                model: model,
                player: player
            )
            row.play()
            XCTAssertEqual(player.currentSongID, song.id)
            XCTAssertEqual(player.queueIdentity?.sessionID, sessionID)
            row.actionsMenu.play()
            XCTAssertEqual(player.currentSongID, song.id)
            XCTAssertEqual(player.queueIdentity?.sessionID, sessionID)
        }
    }

    @MainActor
    func testMediaMutationContextRejectsOldAccountsAndCredentialRevisions() throws {
        let suite = "TinyCloudMusicTests.Audit.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let snapshot = CredentialSnapshot(.guest)
        let transport = EAPITransport(credentialSnapshot: snapshot)
        let model = AppModel(repository: FixtureMusicRepository(), defaults: defaults)
        model.installConfirmedAccount(userID: 7, credentialRevision: 0)
        XCTAssertTrue(model.accountContextIsCurrent(userID: 7, credentialRevision: 0, transport: transport))
        model.installConfirmedAccount(userID: 8, credentialRevision: 0)
        XCTAssertFalse(model.accountContextIsCurrent(userID: 7, credentialRevision: 0, transport: transport))
        snapshot.store(.guest)
        XCTAssertFalse(model.accountContextIsCurrent(userID: 8, credentialRevision: 0, transport: transport))
    }

    @MainActor
    func testExternalPlaybackOwnershipRejectsStaleCleanup() {
        let coordinator = IOSAudioSessionCoordinator()
        let first = AVPlayer()
        let second = AVPlayer()
        coordinator.setExternalPlayer(first, title: "video", creator: "audit")
        XCTAssertTrue(coordinator.ownsExternalPlayback)
        coordinator.musicPlaybackWillStart()
        XCTAssertFalse(coordinator.ownsExternalPlayback)
        coordinator.setExternalPlayer(second, title: "broadcast", creator: "audit", isLive: true)
        coordinator.endExternalPlayback(first)
        XCTAssertTrue(coordinator.externalPlayer === second)
        XCTAssertTrue(coordinator.ownsExternalPlayback)
        coordinator.endExternalPlayback(second)
        XCTAssertNil(coordinator.externalPlayer)
        XCTAssertEqual(coordinator.externalState, .idle)
    }

    func testPlaylistPagingUsesPhoneSizedBatches() {
        XCTAssertEqual(PlaylistSongPaging.initialRange(total: 2_000), 0..<50)
        XCTAssertEqual(PlaylistSongPaging.nextRange(total: 2_000, loaded: 50), 50..<100)
    }

    func testMainTabsRemainUniqueAndBounded() {
        XCTAssertEqual(IOSMainTab.allCases.count, 5)
        XCTAssertEqual(Set(IOSMainTab.allCases.map(\.title)).count, 5)
        XCTAssertEqual(Set(IOSMainTab.allCases.map(\.symbol)).count, 5)
    }

    func testTopTabsStartAtTopAndRestorePreviousOffset() {
        let positions = TopTabScrollPositions(selection: "overview")

        XCTAssertEqual(positions.target(for: "daily", currentOffset: 240), 0)
        XCTAssertEqual(positions.target(for: "playlists", currentOffset: 80), 0)
        XCTAssertEqual(positions.target(for: "overview", currentOffset: 55), 240)
        XCTAssertEqual(positions.target(for: "daily", currentOffset: 240), 80)

        let clamped = TopTabScrollPositions(selection: "first")
        XCTAssertEqual(clamped.target(for: "second", currentOffset: -20), 0)
        XCTAssertEqual(clamped.target(for: "first", currentOffset: 10), 0)
    }

    func testTopTabsRecordOldSelectionBeforeSelectingNewTab() {
        let positions = TopTabScrollPositions(selection: "overview")

        positions.record(240, for: positions.selection)
        XCTAssertEqual(positions.select("daily"), 0)
        positions.record(-20, for: positions.selection)
        XCTAssertEqual(positions.select("playlists"), 0)
        positions.record(80, for: positions.selection)
        XCTAssertEqual(positions.select("overview"), 240)
        positions.record(55, for: positions.selection)
        XCTAssertEqual(positions.select("playlists"), 80)
        XCTAssertEqual(positions.offset(for: "daily"), 0)
    }

    func testListeningReportPeriodsKeepIndependentScrollOffsets() {
        let positions = TopTabScrollPositions(selection: FootprintPeriod.week)

        XCTAssertEqual(positions.target(for: .month, currentOffset: 360), 0)
        XCTAssertEqual(positions.target(for: .week, currentOffset: 120), 360)
        XCTAssertEqual(positions.target(for: .month, currentOffset: 360), 120)
        XCTAssertEqual(positions.target(for: .year, currentOffset: 120), 0)
    }

    func testEmptySimilarPlaylistsHideTheirTab() {
        XCTAssertEqual(IOSPlaylistDetailSection.visible(hasSimilarPlaylists: false), [.songs])
        XCTAssertEqual(
            IOSPlaylistDetailSection.visible(hasSimilarPlaylists: true),
            [.songs, .similarPlaylists]
        )
    }

    @MainActor
    func testDetailTitleUsesGreedyMultilineSizing() {
        let label = IOSGreedyTitle.makeLabel()
        IOSGreedyTitle.configure(label, text: "寻声广州 ｜戴上耳机 漫游广东")
        let size = IOSGreedyTitle.fittingSize(of: label, width: 242)

        XCTAssertTrue(label.lineBreakStrategy.isEmpty)
        XCTAssertEqual(size.width, 242)
        XCTAssertGreaterThan(size.height, label.font.lineHeight)
    }

    func testNowPlayingDownloadActionsMatchTransferState() {
        XCTAssertEqual(IOSDownloadAction(state: nil), .start)
        XCTAssertEqual(IOSDownloadAction(state: .queued), .pause)
        XCTAssertEqual(IOSDownloadAction(state: .running(progress: 0.5)), .pause)
        XCTAssertEqual(IOSDownloadAction(state: .paused(progress: 0.5)), .retry)
        XCTAssertEqual(IOSDownloadAction(state: .failed("offline")), .retry)
        XCTAssertEqual(IOSDownloadAction(state: .cancelled), .start)
        XCTAssertEqual(
            IOSDownloadAction(
                state: .completed(audioURL: URL(fileURLWithPath: "/tmp/song.mp3"), lyricURL: nil)
            ),
            .none
        )
    }

    func testNowPlayingMarqueeScrollsOnlyAfterOverflowAndDelay() {
        XCTAssertEqual(IOSMarquee.offset(elapsed: 2, textWidth: 40, viewportWidth: 40, gap: 32), 0)
        XCTAssertEqual(IOSMarquee.offset(elapsed: 1.2, textWidth: 80, viewportWidth: 40, gap: 32), 0)
        XCTAssertEqual(
            IOSMarquee.offset(elapsed: 2.2, textWidth: 80, viewportWidth: 40, gap: 32),
            -28,
            accuracy: 0.000_001
        )
    }

    func testFirstListenMemoryIsVisibleOnlyWithUsableContent() {
        XCTAssertTrue(FirstListenMemory(listenedAt: nil, text: nil).isEmpty)
        XCTAssertTrue(FirstListenMemory(listenedAt: nil, text: "").isEmpty)
        XCTAssertFalse(FirstListenMemory(listenedAt: Date(timeIntervalSince1970: 1), text: nil).isEmpty)
        XCTAssertFalse(FirstListenMemory(listenedAt: nil, text: "来自每日推荐").isEmpty)
    }

    @MainActor
    func testHomeLoadsOnlyRequestedSections() async throws {
        let suiteName = "IOSNavigationTests.home.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(["daily", "moods", "new"], forKey: "homeSectionIDs")
        let model = AppModel(
            repository: FixtureMusicRepository(),
            defaults: defaults,
            bookmarkResolver: { _ in nil }
        )

        model.loadHome()
        try await Task.sleep(for: .milliseconds(450))
        XCTAssertFalse(model.homeSlots.contains { if case .loaded = $0.load { true } else { false } })

        model.loadHomeSectionIfNeeded(id: "daily")
        for _ in 0..<20 {
            if case .loaded = model.homeSlots.first(where: { $0.id == "daily" })?.load { break }
            try await Task.sleep(for: .milliseconds(50))
        }

        guard case .loaded = model.homeSlots.first(where: { $0.id == "daily" })?.load else {
            return XCTFail("The requested home section did not load")
        }
        XCTAssertFalse(model.homeSlots.dropFirst().contains {
            if case .loaded = $0.load { true } else { false }
        })
    }

    func testPhoneLoginUsesExpectedWEAPIContract() throws {
        XCTAssertEqual(IOSPhoneLoginRequest.normalizedPhone("+86 138-0013-8000"), "13800138000")
        XCTAssertNil(IOSPhoneLoginRequest.normalizedPhone("1380013800x"))
        XCTAssertNil(IOSPhoneLoginRequest.normalizedPhone("12800138000"))
        XCTAssertEqual(IOSPhoneLoginRequest.normalizedCode(" 1234 "), "1234")
        XCTAssertNil(IOSPhoneLoginRequest.normalizedCode("12ab"))

        let captcha = try IOSPhoneLoginRequest.captchaPayload(phone: "13800138000")
        XCTAssertEqual(captcha["ctcode"] as? String, "86")
        XCTAssertEqual(captcha["cellphone"] as? String, "13800138000")
        XCTAssertEqual(captcha["secrete"] as? String, "music_middleuser_pclogin")

        let login = try IOSPhoneLoginRequest.loginPayload(phone: "13800138000", code: "1234")
        XCTAssertEqual(login["countrycode"] as? String, "86")
        XCTAssertEqual(login["captcha"] as? String, "1234")
        XCTAssertEqual(login["remember"] as? String, "true")

        let cookie = IOSPhoneLoginRequest.cookieHeader(
            baseCookie: "MUSIC_A=guest-token",
            deviceID: "test-device",
            now: Date(timeIntervalSince1970: 1_700_000_000)
        )
        XCTAssertTrue(cookie.contains("deviceId=test-device"))
        XCTAssertTrue(cookie.contains("MUSIC_A=guest-token"))
        XCTAssertTrue(cookie.contains("os=pc"))
    }

    func testMultipartXMLIsStableAndEscaped() {
        let body = NOSMultipartXML.body(parts: [
            AudioUploadPart(number: 2, etag: "second"),
            AudioUploadPart(number: 1, etag: "<&>\"'")
        ])

        XCTAssertEqual(
            String(decoding: body, as: UTF8.self),
            "<CompleteMultipartUpload>"
                + "<Part><PartNumber>1</PartNumber><ETag>&lt;&amp;&gt;&quot;&apos;</ETag></Part>"
                + "<Part><PartNumber>2</PartNumber><ETag>second</ETag></Part>"
                + "</CompleteMultipartUpload>"
        )
    }

    func testNIMChatroomMessageAdapterPreservesAttachmentAndGeneration() {
        let raw = #"{"content":{"type":20002,"content":{}}}"#

        XCTAssertEqual(
            IOSNIMChatroomMessageAdapter.event(
                rawAttachContent: raw,
                remoteExtension: nil,
                text: nil,
                generation: 17
            ),
            .message(raw: raw, generation: 17)
        )
    }

    func testNIMChatroomMessageAdapterFallsBackToServerExtension() throws {
        let event = try XCTUnwrap(IOSNIMChatroomMessageAdapter.event(
            rawAttachContent: "not-json",
            remoteExtension: [
                "serverExt": ["type": 20_003, "content": ["reason": "ROOM_EMPTY"]]
            ],
            text: nil,
            generation: 4
        ))
        guard case let .message(raw, generation) = event else {
            return XCTFail("Expected a message event")
        }

        XCTAssertEqual(generation, 4)
        XCTAssertEqual(
            try ListenTogetherResponseDecoder.remoteEvent(from: raw),
            .roomEnded(reason: "ROOM_EMPTY")
        )
    }

    func testNIMChatroomMessageAdapterRejectsInvalidAndOversizedPayloads() {
        XCTAssertNil(IOSNIMChatroomMessageAdapter.event(
            rawAttachContent: "[]",
            remoteExtension: nil,
            text: "plain text",
            generation: 1
        ))
        XCTAssertNil(IOSNIMChatroomMessageAdapter.event(
            rawAttachContent: #"{"value":""# + String(repeating: "x", count: 65_537) + #""}"#,
            remoteExtension: nil,
            text: nil,
            generation: 1
        ))
    }
}

final class IOSTransportCachePagingMeasurementTests: XCTestCase {
    @MainActor
    func testPERFB03LargeResponseRetentionProfilingFixture() async throws {
        let playlistID: Int64 = 9_003
        let trackCount = 10_000
        let path = "/eapi/v6/playlist/detail"
        let responseData = try IOSMeasurementSignposts.interval("PERF-B03.RawData") {
            try makeMeasurementPlaylistResponse(
                playlistID: playlistID,
                trackCount: trackCount,
                includesTracks: true
            )
        }
        let parsedObject = try IOSMeasurementSignposts.interval("PERF-B03.FoundationObject") {
            try XCTUnwrap(JSONSerialization.jsonObject(with: responseData) as? [String: Any])
        }
        let parsedPlaylist = try XCTUnwrap(parsedObject["playlist"] as? [String: Any])
        XCTAssertEqual((parsedPlaylist["tracks"] as? [[String: Any]])?.count, trackCount)
        XCTAssertEqual((parsedPlaylist["trackIds"] as? [[String: Any]])?.count, trackCount)

        IOSMeasurementURLProtocol.install(responseData, for: path)
        defer { IOSMeasurementURLProtocol.remove(path: path) }
        let responseCache = EAPIResponseCache()
        let (transport, session) = makeMeasurementTransport(responseCache: responseCache)
        defer { session.invalidateAndCancel() }
        let repository = LiveMusicRepository(transport: transport)
        let endpoint = EAPIEndpoint(
            path,
            signing: "/api/v6/playlist/detail",
            host: "https://interface3.music.163.com"
        )
        let requestJSON = try compactJSON([
            "id": playlistID,
            "newStyle": "true",
            "verifyId": 1,
            "newDetailPage": true,
            "e_r": true,
            "n": String(PlaylistSongPaging.initialCount),
            "s": "5",
        ])

        let cachedRoot = try await IOSMeasurementSignposts.asyncInterval("PERF-B03.EAPICacheFill") {
            try await transport.requestJSONObject(endpoint, json: requestJSON, cache: .detail)
        }
        XCTAssertEqual(cachedRoot.object("playlist").array("trackIds").count, trackCount)
        XCTAssertEqual(IOSMeasurementURLProtocol.requestCount(for: path), 1)

        let typedDetail = try await IOSMeasurementSignposts.asyncInterval("PERF-B03.TypedDetail") {
            try await repository.detail(for: .playlist(playlistID))
        }
        assertMeasurementPlaylistDetail(typedDetail, trackCount: trackCount)
        XCTAssertEqual(IOSMeasurementURLProtocol.requestCount(for: path), 1)

        let suiteName = "IOSTransportCachePagingMeasurementTests.B03"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = AppModel(
            repository: repository,
            defaults: defaults,
            bookmarkResolver: { _ in nil }
        )
        let route = Route.playlist(playlistID)
        model.path = [route]
        model.loadDetail(route)
        let modelDetail = try await waitForMeasurementDetail(route, in: model)
        assertMeasurementPlaylistDetail(modelDetail, trackCount: trackCount)
        XCTAssertEqual(IOSMeasurementURLProtocol.requestCount(for: path), 1)

        IOSMeasurementSignposts.interval("PERF-B03.MemoryWarning") {
            NotificationCenter.default.post(
                name: UIApplication.didReceiveMemoryWarningNotification,
                object: nil
            )
        }
        let postWarningDetail = try await IOSMeasurementSignposts.asyncInterval(
            "PERF-B03.PostWarningCacheRead"
        ) {
            try await repository.detail(for: route)
        }
        assertMeasurementPlaylistDetail(postWarningDetail, trackCount: trackCount)
        XCTAssertEqual(IOSMeasurementURLProtocol.requestCount(for: path), 1)

        await IOSMeasurementSignposts.asyncInterval("PERF-B03.Invalidate") {
            await transport.invalidateAllCachedResponses()
        }
        let reloadedDetail = try await IOSMeasurementSignposts.asyncInterval(
            "PERF-B03.ReloadAfterInvalidation"
        ) {
            try await repository.detail(for: route)
        }
        assertMeasurementPlaylistDetail(reloadedDetail, trackCount: trackCount)
        XCTAssertEqual(IOSMeasurementURLProtocol.requestCount(for: path), 2)

        _ = IOSMeasurementSignposts.interval("PERF-B03.AccountReset") {
            model.installConfirmedAccount(userID: 42, credentialRevision: 1)
        }
        XCTAssertTrue(model.detailLoads.isEmpty)
        XCTAssertTrue(model.path.isEmpty)
        XCTAssertEqual((parsedObject["code"] as? NSNumber)?.intValue, 200)
    }

    @MainActor
    func testPERFB05PagingGrowthProfilingFixture() {
        for pageCount in [1, 10, 50, 100] {
            IOSMeasurementSignposts.markPagingScale(pageCount)
            XCTContext.runActivity(named: "PERF-B05 pages=\(pageCount)") { _ in
                let search = IOSMeasurementSignposts.interval("PERF-B05.SearchMerge") {
                    runMeasurementSearchPaging(pageCount: pageCount, width: 20)
                }
                assertMeasurementPaging(
                    search,
                    pageCount: pageCount,
                    width: 20,
                    prefix: "video-search-",
                    expectedPosition: (pageCount - 1) * 20
                )

                let podcasts = IOSMeasurementSignposts.interval("PERF-B05.PodcastMerge") {
                    runMeasurementPodcastPaging(pageCount: pageCount, width: 30)
                }
                assertMeasurementPaging(
                    podcasts,
                    pageCount: pageCount,
                    width: 30,
                    prefix: "podcast-",
                    expectedPosition: pageCount * 30
                )

                let episodes = IOSMeasurementSignposts.interval("PERF-B05.EpisodeMerge") {
                    runMeasurementEpisodePaging(pageCount: pageCount, width: 30)
                }
                assertMeasurementPaging(
                    episodes,
                    pageCount: pageCount,
                    width: 30,
                    prefix: "episode-",
                    expectedPosition: pageCount * 30
                )

                let broadcasts = IOSMeasurementSignposts.interval("PERF-B05.BroadcastMerge") {
                    runMeasurementBroadcastPaging(pageCount: pageCount, width: 20)
                }
                assertMeasurementPaging(
                    broadcasts,
                    pageCount: pageCount,
                    width: 20,
                    prefix: "broadcast-",
                    expectedPosition: pageCount
                )

                let videos = IOSMeasurementSignposts.interval("PERF-B05.VideoMerge") {
                    runMeasurementVideoPaging(pageCount: pageCount, width: 25)
                }
                assertMeasurementPaging(
                    videos,
                    pageCount: pageCount,
                    width: 25,
                    prefix: "video-subscription-",
                    expectedPosition: pageCount * 25
                )
            }
        }
    }

    @MainActor
    func testPERFB06OneThousandTrackDetailCacheProfilingFixture() async throws {
        try await runMeasurementCacheFixture(trackCount: 1_000)
    }

    @MainActor
    func testPERFB06TenThousandTrackDetailCacheProfilingFixture() async throws {
        try await runMeasurementCacheFixture(trackCount: 10_000)
    }

    @MainActor
    func testPERFB12IsolatedCredentialStoreProfilingFixture() throws {
        let store = CredentialStore(service: "TinyCloudMusicTests.\(UUID())")
        let credentials = try SessionCredentials(
            cookie: "MUSIC_U=fixture-keychain; __csrf=fixture",
            musicU: "vip-fixture-keychain",
            deviceID: String(repeating: "D", count: 52)
        )
        defer { try? store.delete() }

        let initial = try IOSMeasurementSignposts.interval("PERF-B12.LoadEmpty") {
            try store.load()
        }
        XCTAssertNil(initial)

        try IOSMeasurementSignposts.interval("PERF-B12.Save") {
            try store.save(credentials)
        }
        let loaded = try IOSMeasurementSignposts.interval("PERF-B12.Load") {
            try store.load()
        }
        XCTAssertEqual(loaded, credentials)

        try IOSMeasurementSignposts.interval("PERF-B12.Delete") {
            try store.delete()
        }
        XCTAssertNil(try store.load())
    }

    @MainActor
    func testPERFB14OneThousandRouteGrowthProfilingFixture() throws {
        try runMeasurementRouteGrowthFixture(
            routeCount: 1_000,
            signpost: "PERF-B14.RouteGrowth.1000"
        )
    }

    @MainActor
    func testPERFB14TenThousandRouteGrowthProfilingFixture() throws {
        try runMeasurementRouteGrowthFixture(
            routeCount: 10_000,
            signpost: "PERF-B14.RouteGrowth.10000"
        )
    }

    @MainActor
    func testPERFB15RepeatedEAPIRequestProfilingFixture() async throws {
        let path = "/eapi/profile/repeated-request"
        let responseData = Data(#"{"code":200,"fixture":"eapi"}"#.utf8)
        IOSMeasurementURLProtocol.install(responseData, for: path)
        defer { IOSMeasurementURLProtocol.remove(path: path) }
        let (transport, session) = makeMeasurementTransport()
        defer { session.invalidateAndCancel() }
        let payload: [String: Any] = [
            "items": (0..<256).map { ["id": $0, "name": "fixture-\($0)"] },
            "limit": 256,
            "offset": 0,
        ]

        let expectedJSON = try compactJSON(payload)
        var encodedJSON = Data()
        try IOSMeasurementSignposts.interval("PERF-B15.JSONReencode") {
            for _ in 0..<64 { encodedJSON = try compactJSON(payload) }
        }
        XCTAssertEqual(encodedJSON, expectedJSON)

        let logicalPath = "/api/profile/repeated-request"
        let expectedBody = try EAPICodec.requestBody(path: logicalPath, json: expectedJSON)
        var encodedBody = Data()
        try IOSMeasurementSignposts.interval("PERF-B15.EAPICodec") {
            for _ in 0..<64 {
                encodedBody = try EAPICodec.requestBody(path: logicalPath, json: expectedJSON)
            }
        }
        XCTAssertEqual(encodedBody, expectedBody)

        let endpoint = EAPIEndpoint(
            path,
            signing: logicalPath,
            host: "https://fixture.invalid",
            responseEncoding: .json
        )
        _ = try await transport.request(endpoint, json: expectedJSON, cache: .search, retryable: false)
        let cachedResponse = try await IOSMeasurementSignposts.asyncInterval(
            "PERF-B15.EAPIFingerprintSHA"
        ) {
            var result = Data()
            for _ in 0..<128 {
                result = try await transport.request(
                    endpoint,
                    json: expectedJSON,
                    cache: .search,
                    retryable: false
                )
            }
            return result
        }
        XCTAssertEqual(cachedResponse, responseData)
        XCTAssertEqual(IOSMeasurementURLProtocol.requestCount(for: path), 1)
    }

    @MainActor
    func testPERFB15RepeatedWEAPICacheMissProfilingFixture() async throws {
        let path = "/weapi/profile/cache-miss"
        let secretKey = "abcdefghijklmnop"
        let responseData = Data(#"{"code":200,"fixture":"weapi"}"#.utf8)
        IOSMeasurementURLProtocol.install(responseData, for: path)
        defer { IOSMeasurementURLProtocol.remove(path: path) }
        let (transport, session) = makeMeasurementTransport(weapiSecretKey: secretKey)
        defer { session.invalidateAndCancel() }

        let codecJSON = Data(#"{"alg":"RT","csrf_token":"","songId":11,"time":42}"#.utf8)
        let expectedFields = try WEAPICodec.encryptedFields(json: codecJSON, secretKey: secretKey)
        var encodedFields = expectedFields
        try IOSMeasurementSignposts.interval("PERF-B15.WEAPICodec") {
            for _ in 0..<32 {
                encodedFields = try WEAPICodec.encryptedFields(json: codecJSON, secretKey: secretKey)
            }
        }
        XCTAssertEqual(encodedFields.params, expectedFields.params)
        XCTAssertEqual(encodedFields.encSecKey, expectedFields.encSecKey)

        let lastResponse = try await IOSMeasurementSignposts.asyncInterval(
            "PERF-B15.WEAPICacheMiss"
        ) {
            try await runMeasurementWEAPICacheMisses(transport: transport, path: path)
        }
        XCTAssertEqual(lastResponse, responseData)
        XCTAssertEqual(IOSMeasurementURLProtocol.requestCount(for: path), 32)
    }

    @MainActor
    private func runMeasurementRouteGrowthFixture(
        routeCount: Int,
        signpost: StaticString
    ) throws {
        let suiteName = "IOSTransportCachePagingMeasurementTests.B14.\(routeCount)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = AppModel(
            repository: FixtureMusicRepository(),
            defaults: defaults,
            bookmarkResolver: { _ in nil }
        )
        defer { model.path.removeAll() }
        let routes = (1...routeCount).map { Route.playlist(Int64($0)) }

        IOSMeasurementSignposts.interval(signpost) {
            for route in routes {
                model.path = [route]
                model.loadDetail(route)
            }
        }

        let generations = try XCTUnwrap(
            Mirror(reflecting: model).children.first {
                $0.label == "detailGenerations"
            }?.value as? [Route: Int]
        )
        XCTAssertEqual(routes.count, routeCount)
        XCTAssertEqual(model.path.count, 1)
        XCTAssertEqual(model.detailLoads.count, 1)
        XCTAssertEqual(generations.count, routeCount)
        XCTAssertTrue(generations.values.allSatisfy { $0 == 1 })
        XCTAssertEqual(model.path.last, routes.last)
    }

    @MainActor
    private func runMeasurementCacheFixture(trackCount: Int) async throws {
        let path = "/eapi/profile/cache-\(trackCount)"
        let responseData = try makeMeasurementPlaylistResponse(
            playlistID: 6_000 + Int64(trackCount),
            trackCount: trackCount,
            includesTracks: false
        )
        IOSMeasurementURLProtocol.install(responseData, for: path)
        defer { IOSMeasurementURLProtocol.remove(path: path) }
        let responseCache = EAPIResponseCache()
        let (transport, session) = makeMeasurementTransport(responseCache: responseCache)
        defer { session.invalidateAndCancel() }
        let endpoint = EAPIEndpoint(
            path,
            signing: "/api/profile/cache",
            host: "https://fixture.invalid",
            responseEncoding: .json
        )
        let requestJSONs = try (1...12).map { try compactJSON(["id": $0, "tracks": trackCount]) }

        try await IOSMeasurementSignposts.asyncInterval("PERF-B06.TransportCachePopulate") {
            for requestJSON in requestJSONs {
                _ = try await transport.request(
                    endpoint,
                    json: requestJSON,
                    cache: .detail,
                    retryable: false
                )
            }
        }
        XCTAssertEqual(IOSMeasurementURLProtocol.requestCount(for: path), 12)
        try await IOSMeasurementSignposts.asyncInterval("PERF-B06.TransportCacheHit") {
            for requestJSON in requestJSONs {
                _ = try await transport.request(
                    endpoint,
                    json: requestJSON,
                    cache: .detail,
                    retryable: false
                )
            }
        }
        XCTAssertEqual(IOSMeasurementURLProtocol.requestCount(for: path), 12)
        try await IOSMeasurementSignposts.asyncInterval("PERF-B06.TransportCacheInvalidate") {
            await transport.invalidateAllCachedResponses()
            _ = try await transport.request(
                endpoint,
                json: requestJSONs[0],
                cache: .detail,
                retryable: false
            )
            await transport.invalidateAllCachedResponses()
        }
        XCTAssertEqual(IOSMeasurementURLProtocol.requestCount(for: path), 13)

        let suiteName = "IOSTransportCachePagingMeasurementTests.B06.\(trackCount)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = AppModel(
            repository: IOSGeneratedDetailRepository(trackCount: trackCount),
            defaults: defaults,
            bookmarkResolver: { _ in nil }
        )
        let routes = (1...13).map { Route.playlist(Int64($0)) }

        try await IOSMeasurementSignposts.asyncInterval("PERF-B06.DetailCachePopulate") {
            for route in routes.prefix(12) {
                model.path = [route]
                model.loadDetail(route)
                _ = try await waitForMeasurementDetail(route, in: model)
            }
        }
        XCTAssertEqual(model.detailLoads.count, 12)
        for route in routes.prefix(12) {
            assertMeasurementPlaylistDetail(
                try XCTUnwrap(model.detailLoads[route]?.measurementContent),
                trackCount: trackCount
            )
        }

        model.path = [routes[0]]
        try await IOSMeasurementSignposts.asyncInterval("PERF-B06.DetailCacheTouch") {
            _ = try await model.reloadPlaylist(1)
        }
        try await IOSMeasurementSignposts.asyncInterval("PERF-B06.DetailCacheEvict") {
            model.path = [routes[12]]
            model.loadDetail(routes[12])
            _ = try await waitForMeasurementDetail(routes[12], in: model)
        }
        XCTAssertEqual(model.detailLoads.count, 12)
        XCTAssertNotNil(model.detailLoads[routes[0]])
        XCTAssertNil(model.detailLoads[routes[1]])
        assertMeasurementPlaylistDetail(
            try XCTUnwrap(model.detailLoads[routes[12]]?.measurementContent),
            trackCount: trackCount
        )

        _ = IOSMeasurementSignposts.interval("PERF-B06.AccountReset") {
            model.installConfirmedAccount(userID: 84, credentialRevision: 2)
        }
        XCTAssertTrue(model.detailLoads.isEmpty)
        XCTAssertTrue(model.path.isEmpty)
    }
}

// W5-FX2B-BEGIN
final class IOSDownloadHistoryMeasurementTests: XCTestCase {
    @MainActor
    func testPERFB07HostedDownloadHistoryUIProfilingFixture() async throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "TinyCloudMusicTests.\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [IOSDownloadMeasurementProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        IOSDownloadMeasurementProtocol.reset()
        let gate = IOSDownloadMeasurementGate()
        let manager = MusicDownloadManager(
            transport: EAPITransport(session: session, cookie: "", musicU: ""),
            session: session,
            maximumConcurrentDownloads: 5,
            resumeStore: MusicDownloadResumeStore(directory: root.appending(path: "resume")),
            targetAllocator: MusicDownloadTargetAllocator(),
            videoTransfer: { _, _, progress in
                await gate.waitForProgressRelease()
                try Task.checkCancellation()
                progress(50, 100, 100)
                await gate.holdAfterProgress()
                throw CancellationError()
            }
        )

        let songs = (1...500).map {
            measurementAnnualSong(id: Int64($0), name: "download-song-\($0)")
        }
        let songIDs = songs.map(\.id)
        XCTAssertEqual(manager.enqueue(
            songs: songs,
            to: root.appending(path: "songs"),
            quality: .standard,
            includeLyrics: false
        ), 500)
        for _ in 0..<500 {
            if manager.runningDownloadCount == 5 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(manager.runningDownloadCount, 5)

        let terminalVideos = (1...500).map {
            VideoPageResource.mv(Int64(10_000 + $0))
        }
        var acceptedVideoCount = 0
        for resource in terminalVideos {
            if manager.enqueue(
                video: resource,
                title: resource.identity,
                creator: "Fixture",
                availableResolutions: [720],
                to: root.appending(path: "videos"),
                quality: .high
            ) {
                acceptedVideoCount += 1
            }
        }
        XCTAssertEqual(acceptedVideoCount, 500)
        let terminalVideoIDs = terminalVideos.map(\.identity)
        terminalVideoIDs.forEach { manager.cancelVideo(id: $0) }
        songIDs.forEach { manager.cancel(songID: $0) }
        for _ in 0..<500 {
            if manager.runningDownloadCount == 0 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(manager.runningDownloadCount, 0)

        let activeVideos = (1...5).map { VideoPageResource.mv(Int64(20_000 + $0)) }
        for resource in activeVideos {
            XCTAssertTrue(manager.enqueue(
                video: resource,
                title: resource.identity,
                creator: "Fixture",
                availableResolutions: [720],
                to: root.appending(path: "active-videos"),
                quality: .high
            ))
        }
        let activeVideoIDs = activeVideos.map(\.identity)
        for _ in 0..<500 {
            if await gate.progressReadyCount == 5 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let progressReadyCount = await gate.progressReadyCount
        XCTAssertEqual(progressReadyCount, 5)
        XCTAssertEqual(IOSDownloadMeasurementProtocol.playbackRequestCount, 5)

        let stableSongOrder = manager.itemOrder
        let stableVideoOrder = manager.videoItemOrder
        XCTAssertEqual(stableSongOrder, songIDs)
        XCTAssertEqual(stableVideoOrder, terminalVideoIDs + activeVideoIDs)
        XCTAssertEqual(manager.states.count, 500)
        XCTAssertEqual(manager.videoStates.count, 505)
        XCTAssertEqual(manager.states.values.count { state in
            if case .cancelled = state { return true }
            return false
        }, 500)
        XCTAssertEqual(manager.videoStates.values.count { state in
            if case .cancelled = state { return true }
            return false
        }, 500)
        XCTAssertEqual(manager.videoStates.values.count { state in
            if case .running = state { return true }
            return false
        }, 5)
        XCTAssertEqual(Array(stableSongOrder.reversed()), Array(songIDs.reversed()))
        XCTAssertEqual(
            Array(stableVideoOrder.reversed()),
            Array((terminalVideoIDs + activeVideoIDs).reversed())
        )

        let initialProjection = IOSMeasurementSignposts.interval("PERF-B07.UIProjectionOrder.Initial") {
            IOSDownloadsView(manager: manager).body
        }
        withExtendedLifetime(initialProjection) {}
        let host = UIHostingController(rootView: IOSDownloadsView(manager: manager))
        host.loadViewIfNeeded()
        host.view.frame = CGRect(origin: .zero, size: IOSMeasurementLayout.viewport)
        IOSMeasurementSignposts.interval("PERF-B07.LayoutComplete.Initial") {
            host.view.layoutIfNeeded()
        }
        XCTAssertEqual(host.view.bounds.size, IOSMeasurementLayout.viewport)
        XCTAssertFalse(host.view.hasAmbiguousLayout)

        try await IOSMeasurementSignposts.asyncInterval("PERF-B07.RootViewInvalidation.Progress") {
            await gate.releaseProgress()
            for _ in 0..<500 {
                if await gate.completedProgressCount == 5,
                   activeVideoIDs.allSatisfy({ manager.videoStates[$0] == .running(progress: 0.5) }) {
                    break
                }
                try await Task.sleep(for: .milliseconds(5))
            }
        }
        let completedProgressCount = await gate.completedProgressCount
        XCTAssertEqual(completedProgressCount, 5)
        XCTAssertTrue(activeVideoIDs.allSatisfy {
            manager.videoStates[$0] == .running(progress: 0.5)
        })
        XCTAssertEqual(manager.itemOrder, stableSongOrder)
        XCTAssertEqual(manager.videoItemOrder, stableVideoOrder)
        XCTAssertEqual(manager.states.count, 500)
        XCTAssertEqual(manager.videoStates.count, 505)

        let updatedProjection = IOSMeasurementSignposts.interval("PERF-B07.UIProjectionOrder.Progress") {
            IOSDownloadsView(manager: manager).body
        }
        withExtendedLifetime(updatedProjection) {}
        IOSMeasurementSignposts.interval("PERF-B07.RootViewUpdate.Progress") {
            host.rootView = IOSDownloadsView(manager: manager)
            host.view.setNeedsLayout()
        }
        IOSMeasurementSignposts.interval("PERF-B07.LayoutComplete.Progress") {
            host.view.layoutIfNeeded()
        }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: IOSMeasurementLayout.viewport, format: format)
        let rendered = IOSMeasurementSignposts.interval("PERF-B07.RenderComplete.Progress") {
            renderer.image { context in
                host.view.layer.render(in: context.cgContext)
            }
        }
        XCTAssertEqual(host.view.bounds.size, IOSMeasurementLayout.viewport)
        XCTAssertFalse(host.view.hasAmbiguousLayout)
        XCTAssertEqual(rendered.cgImage?.width, Int(IOSMeasurementLayout.viewport.width))
        XCTAssertEqual(rendered.cgImage?.height, Int(IOSMeasurementLayout.viewport.height))
        XCTAssertEqual(manager.itemOrder, stableSongOrder)
        XCTAssertEqual(manager.videoItemOrder, stableVideoOrder)

        manager.cancelAll()
        await gate.releaseAll()
        for _ in 0..<500 {
            if manager.runningDownloadCount == 0 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        await manager.pauseAll()
    }
}

private actor IOSDownloadMeasurementGate {
    private(set) var progressReadyCount = 0
    private(set) var completedProgressCount = 0
    private var progressReleased = false
    private var finishReleased = false
    private var progressWaiters: [CheckedContinuation<Void, Never>] = []
    private var finishWaiters: [CheckedContinuation<Void, Never>] = []

    func waitForProgressRelease() async {
        progressReadyCount += 1
        guard !progressReleased else { return }
        await withCheckedContinuation { progressWaiters.append($0) }
    }

    func releaseProgress() {
        progressReleased = true
        let waiters = progressWaiters
        progressWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func holdAfterProgress() async {
        completedProgressCount += 1
        guard !finishReleased else { return }
        await withCheckedContinuation { finishWaiters.append($0) }
    }

    func releaseAll() {
        releaseProgress()
        finishReleased = true
        let waiters = finishWaiters
        finishWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}

private final class IOSDownloadMeasurementProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var playbackRequests = 0

    static var playbackRequestCount: Int { lock.withLock { playbackRequests } }
    static func reset() { lock.withLock { playbackRequests = 0 } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard request.url?.path == "/weapi/song/enhance/play/mv/url" else { return }
        Self.lock.withLock { Self.playbackRequests += 1 }
        let body = Data(
            #"{"code":200,"data":{"url":"https://fixture.vod.126.net/perf-b07.mp4","r":720}}"#.utf8
        )
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json", "Content-Length": String(body.count)]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
// W5-FX2B-END
final class IOSUITextReportMeasurementTests: XCTestCase {
    @MainActor
    func testPERFB08OneThousandTrackPlaylistBodyProfilingFixture() async throws {
        try await runPlaylistBodyFixture(trackCount: 1_000)
    }

    @MainActor
    func testPERFB08TenThousandTrackPlaylistBodyProfilingFixture() async throws {
        try await runPlaylistBodyFixture(trackCount: 10_000)
    }

    @MainActor
    func testPERFB08EmptyTrackPlaylistBodyControlFixture() async throws {
        try await runPlaylistBodyFixture(trackCount: 0)
    }

    @MainActor
    func testPERFB09OrdinaryAndEmojiDenseCommentListProfilingFixture() {
        let rowCount = 256
        let tokens = ["[汗]", "[怒]", "[呆]", "[亲]", "[色]", "[弱]", "[强]", "[晕]"]
        let denseContent = Array(repeating: tokens, count: 16).flatMap { $0 }.joined()
        let ordinaryContent = String(repeating: "文", count: denseContent.count)
        let ordinaryComments = Array(repeating: ordinaryContent, count: rowCount)
        let denseComments = Array(repeating: denseContent, count: rowCount)

        XCTAssertEqual(ordinaryComments.count, denseComments.count)
        XCTAssertEqual(ordinaryContent.count, denseContent.count)

        let ordinaryParts = IOSMeasurementSignposts.interval("PERF-B09.Tokenize.Ordinary") {
            ordinaryComments.map { CommentEmojiCatalog.parts(in: $0) }
        }
        let denseParts = IOSMeasurementSignposts.interval("PERF-B09.Tokenize.EmojiDense") {
            denseComments.map { CommentEmojiCatalog.parts(in: $0) }
        }
        let expectedTokens = Array(repeating: tokens, count: 16).flatMap { $0 }
        XCTAssertEqual(ordinaryParts.count, rowCount)
        XCTAssertEqual(denseParts.count, rowCount)
        XCTAssertTrue(ordinaryParts.allSatisfy { $0 == [.text(ordinaryContent)] })
        XCTAssertEqual(denseParts.first?.compactMap { measurementEmojiToken($0) }, expectedTokens)
        XCTAssertTrue(denseParts.allSatisfy { $0.count == expectedTokens.count })

        let sourceImage = measurementSolidImage(edge: 24, scale: 2)
        let finalImages = IOSMeasurementSignposts.interval("PERF-B09.Render18pt") {
            Dictionary(uniqueKeysWithValues: tokens.map {
                ($0, measurementRedrawnImage(sourceImage, edge: 18, scale: 2))
            })
        }
        XCTAssertEqual(finalImages.count, tokens.count)
        XCTAssertTrue(finalImages.values.allSatisfy { $0.size == CGSize(width: 18, height: 18) })

        let ordinaryDictionaries = IOSMeasurementSignposts.interval("PERF-B09.Redraw18pt.Ordinary") {
            measurementRedrawnEmojiDictionaries(parts: ordinaryParts, sourceImage: sourceImage)
        }
        let denseDictionaries = IOSMeasurementSignposts.interval("PERF-B09.Redraw18pt.EmojiDense") {
            measurementRedrawnEmojiDictionaries(parts: denseParts, sourceImage: sourceImage)
        }
        XCTAssertTrue(ordinaryDictionaries.allSatisfy(\.isEmpty))
        XCTAssertTrue(denseDictionaries.allSatisfy { $0.count == tokens.count })

        let ordinaryHits = IOSMeasurementSignposts.interval("PERF-B09.DictionaryLookup.Ordinary") {
            measurementEmojiDictionaryHits(parts: ordinaryParts, images: ordinaryDictionaries)
        }
        let denseHits = IOSMeasurementSignposts.interval("PERF-B09.DictionaryLookup.EmojiDense") {
            measurementEmojiDictionaryHits(parts: denseParts, images: denseDictionaries)
        }
        XCTAssertEqual(ordinaryHits, 0)
        XCTAssertEqual(denseHits, rowCount * expectedTokens.count)

        let ordinaryLayout = layoutMeasurementView(
            IOSMeasurementEmojiList(parts: ordinaryParts, images: ordinaryDictionaries),
            signpost: "PERF-B09.ListLayout.Ordinary"
        )
        let denseLayout = layoutMeasurementView(
            IOSMeasurementEmojiList(parts: denseParts, images: denseDictionaries),
            signpost: "PERF-B09.ListLayout.EmojiDense"
        )
        XCTAssertEqual(ordinaryLayout, IOSMeasurementLayout.viewport)
        XCTAssertEqual(denseLayout, IOSMeasurementLayout.viewport)
    }

    @MainActor
    func testPERFB10ShortLongAndPairedLyricsProfilingFixture() {
        let short = IOSMeasurementSignposts.interval("PERF-B10.ShortLRCParse") {
            LRCParser.parse(
                primary: "[00:01.000]alpha\n[00:02.250]beta\n[00:03.500]gamma",
                translation: "[00:01.000]A\n[00:02.250]B\n[00:03.500]C"
            )
        }
        XCTAssertEqual(short.map(\.timestampMilliseconds), [1_000, 2_250, 3_500])
        XCTAssertEqual(short.map(\.text), ["alpha", "beta", "gamma"])
        XCTAssertEqual(short.map(\.translation), ["A", "B", "C"])

        let podcastLineCount = 10_000
        let podcastLyrics = measurementLRC(lineCount: podcastLineCount, prefix: "podcast")
        let podcast = IOSMeasurementSignposts.interval("PERF-B10.LongPodcastParse") {
            LRCParser.parse(primary: podcastLyrics)
        }
        XCTAssertEqual(podcast.count, podcastLineCount)
        XCTAssertEqual(podcast.first?.timestampMilliseconds, 0)
        XCTAssertEqual(podcast.last?.timestampMilliseconds, Int64(podcastLineCount - 1) * 1_000)
        XCTAssertEqual(podcast.first?.text, "podcast-00000")
        XCTAssertEqual(podcast.last?.text, "podcast-09999")

        let pairedLineCount = 2_000
        let pairedSource = measurementPairedLyrics(lineCount: pairedLineCount)
        let wordOnly = IOSMeasurementSignposts.interval("PERF-B10.WordTimingParse") {
            LRCParser.parse(SongLyrics(lineLyrics: "", wordLyrics: pairedSource.word))
        }
        let lineOnly = IOSMeasurementSignposts.interval("PERF-B10.PairingLineParse") {
            LRCParser.parse(primary: pairedSource.line)
        }
        let paired = IOSMeasurementSignposts.interval("PERF-B10.WordLinePair") {
            LRCParser.parse(SongLyrics(lineLyrics: pairedSource.line, wordLyrics: pairedSource.word))
        }
        XCTAssertEqual(wordOnly.count, pairedLineCount)
        XCTAssertEqual(lineOnly.count, pairedLineCount)
        XCTAssertEqual(paired.count, pairedLineCount)
        XCTAssertEqual(paired.map(\.timestampMilliseconds), wordOnly.map(\.timestampMilliseconds))
        XCTAssertEqual(paired.map(\.text), lineOnly.map(\.text))
        XCTAssertEqual(paired.first?.timestampMilliseconds, 120)
        XCTAssertEqual(paired.last?.timestampMilliseconds, Int64(pairedLineCount - 1) * 2_000 + 120)
        XCTAssertTrue(paired.allSatisfy { $0.words.count == 1 })
    }

    @MainActor
    func testPERFB11LargeAnnualDecodeAndEnrichmentProfilingFixture() throws {
        let trackCount = 10_000
        let root = measurementAnnualPayload(trackCount: trackCount)
        let repository = LiveMusicRepository()
        let report = IOSMeasurementSignposts.interval("PERF-B11.Decode.Large") {
            AnnualListeningReportDecoder.report(root, year: 2024, decodeSong: repository.decodeSong)
        }
        let tracks = try XCTUnwrap(report.sections.first { $0.id == "annual-playlist" }?.tracks)
        let expectedIDs = (1...trackCount).map(Int64.init) + [2, 1]
        XCTAssertEqual(report.year, 2024)
        XCTAssertEqual(tracks.count, trackCount + 2)
        XCTAssertEqual(tracks.map(\.song.id), expectedIDs)
        XCTAssertEqual(tracks.first?.id, "annual-top-0")
        XCTAssertEqual(tracks.last?.id, "annual-top-10001")

        let enrichmentIDs = IOSMeasurementSignposts.interval("PERF-B11.EnrichmentSetSort") {
            Set(report.sections.flatMap { section in
                section.tracks.compactMap { track in
                    track.song.album.artwork.remoteURL == nil || track.song.artists.isEmpty
                        ? track.song.id
                        : nil
                }
            }).sorted()
        }
        let expectedEnrichmentIDs = (1...trackCount)
            .map(Int64.init)
            .filter { !$0.isMultiple(of: 4) }
        XCTAssertEqual(enrichmentIDs, expectedEnrichmentIDs)

        let omittedID = try XCTUnwrap(enrichmentIDs.last)
        var replacements = enrichmentIDs.dropLast().reversed().map {
            measurementAnnualSong(id: $0, name: "enriched-\($0)")
        }
        replacements.insert(
            measurementAnnualSong(id: 1, name: "enriched-first"),
            at: 0
        )
        replacements.append(
            measurementAnnualSong(id: 1, name: "ignored-duplicate")
        )
        let rebuilt = IOSMeasurementSignposts.interval("PERF-B11.RebuildReport") {
            replacingAnnualReportSongs(in: report, with: replacements)
        }
        let rebuiltTracks = try XCTUnwrap(rebuilt.sections.first { $0.id == "annual-playlist" }?.tracks)
        XCTAssertEqual(rebuilt.year, report.year)
        XCTAssertEqual(rebuiltTracks.map(\.id), tracks.map(\.id))
        XCTAssertEqual(rebuiltTracks.filter { $0.song.id == 1 }.map(\.song.name), [
            "enriched-first", "enriched-first",
        ])
        XCTAssertEqual(rebuiltTracks.first { $0.song.id == 2 }?.song.name, "enriched-2")
        XCTAssertEqual(rebuiltTracks.first { $0.song.id == 4 }?.song.name, "annual-00004")
        XCTAssertEqual(rebuiltTracks.first { $0.song.id == omittedID }?.song.name, "annual-09999")

        let small = IOSMeasurementSignposts.interval("PERF-B11.Decode.SmallControl") {
            AnnualListeningReportDecoder.report(
                measurementAnnualControlPayload(ids: [3, 1, 2]),
                year: 2017,
                decodeSong: repository.decodeSong
            )
        }
        let missingItems: [[String: Any]] = [["songId": 7], ["songName": "missing"]]
        let missing = AnnualListeningReportDecoder.report(
            ["data": ["annualPlaylist": ["items": missingItems]]],
            year: 2024,
            decodeSong: repository.decodeSong
        )
        XCTAssertEqual(small.sections.first?.tracks.map(\.song.id), [3, 1, 2])
        XCTAssertTrue(missing.sections.isEmpty)
        XCTAssertTrue(AnnualListeningReportDecoder.supportedYears.contains(2017))
        XCTAssertTrue(AnnualListeningReportDecoder.supportedYears.contains(2024))
        XCTAssertFalse(AnnualListeningReportDecoder.supportedYears.contains(2016))
        XCTAssertFalse(AnnualListeningReportDecoder.supportedYears.contains(2025))

        let retainedReports = [report, rebuilt, small]
        let retainedTrackCount = IOSMeasurementSignposts.interval("PERF-B11.RetainedObjectGraph") {
            retainedReports.reduce(0) { count, report in
                count + report.sections.reduce(0) { $0 + $1.tracks.count }
            }
        }
        let rssChecksum = IOSMeasurementSignposts.interval("PERF-B11.RSSSampleWindow") {
            withExtendedLifetime((root, retainedReports, replacements)) {
                retainedTrackCount + enrichmentIDs.count + replacements.count
            }
        }
        XCTAssertEqual(retainedTrackCount, (trackCount + 2) * 2 + 3)
        XCTAssertEqual(rssChecksum, retainedTrackCount + enrichmentIDs.count + replacements.count)
    }

    @MainActor
    private func runPlaylistBodyFixture(trackCount: Int) async throws {
        let suiteName = "IOSUITextReportMeasurementTests.B08.\(trackCount)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let repository = IOSGeneratedDetailRepository(trackCount: trackCount)
        let model = AppModel(
            repository: repository,
            defaults: defaults,
            bookmarkResolver: { _ in nil }
        )
        let player = PlayerController(repository: repository, crossfadeDuration: 0)
        let route = Route.playlist(80_000 + Int64(trackCount))
        model.path = [route]
        model.loadDetail(route)
        let detail = try await waitForMeasurementDetail(route, in: model)
        guard case let .playlist(_, songs, trackIDs, loadedTrackCount) = detail else {
            return XCTFail("Expected playlist detail")
        }
        XCTAssertEqual(trackIDs.count, trackCount)
        XCTAssertEqual(Set(trackIDs).count, trackCount)
        XCTAssertEqual(songs.count, trackCount)
        XCTAssertEqual(loadedTrackCount, trackCount)

        let host = UIHostingController(rootView: IOSRouteDestinationView(
            route: route,
            model: model,
            player: player
        ))
        host.loadViewIfNeeded()
        host.view.frame = CGRect(origin: .zero, size: IOSMeasurementLayout.viewport)

        switch trackCount {
        case 0:
            runPlaylistLikedState(
                name: "empty track list",
                trackIDs: trackIDs,
                liked: [],
                expectedUnliked: 0,
                model: model,
                player: player,
                route: route,
                host: host,
                membershipSignpost: "PERF-B08.Membership.EmptyTrack",
                scanSignpost: "PERF-B08.RepeatedScan.EmptyTrack",
                invalidationSignpost: "PERF-B08.BodyInvalidation.EmptyTrack",
                layoutSignpost: "PERF-B08.LayoutComplete.EmptyTrack"
            )
        case 1_000, 10_000:
            let partial = Set(trackIDs.enumerated().compactMap { index, id in
                index.isMultiple(of: 2) ? id : nil
            })
            let scales: (StaticString, StaticString, StaticString, StaticString) = trackCount == 1_000
                ? (
                    "PERF-B08.Membership.1000",
                    "PERF-B08.RepeatedScan.1000",
                    "PERF-B08.BodyInvalidation.1000",
                    "PERF-B08.LayoutComplete.1000"
                )
                : (
                    "PERF-B08.Membership.10000",
                    "PERF-B08.RepeatedScan.10000",
                    "PERF-B08.BodyInvalidation.10000",
                    "PERF-B08.LayoutComplete.10000"
                )
            runPlaylistLikedState(
                name: "empty liked set",
                trackIDs: trackIDs,
                liked: [],
                expectedUnliked: trackCount,
                model: model,
                player: player,
                route: route,
                host: host,
                membershipSignpost: scales.0,
                scanSignpost: scales.1,
                invalidationSignpost: scales.2,
                layoutSignpost: scales.3
            )
            runPlaylistLikedState(
                name: "partial liked set",
                trackIDs: trackIDs,
                liked: partial,
                expectedUnliked: trackCount / 2,
                model: model,
                player: player,
                route: route,
                host: host,
                membershipSignpost: scales.0,
                scanSignpost: scales.1,
                invalidationSignpost: scales.2,
                layoutSignpost: scales.3
            )
            runPlaylistLikedState(
                name: "full liked set",
                trackIDs: trackIDs,
                liked: Set(trackIDs),
                expectedUnliked: 0,
                model: model,
                player: player,
                route: route,
                host: host,
                membershipSignpost: scales.0,
                scanSignpost: scales.1,
                invalidationSignpost: scales.2,
                layoutSignpost: scales.3
            )
        default:
            XCTFail("Unsupported PERF-B08 fixture scale")
        }

        XCTAssertEqual(host.view.bounds.size, IOSMeasurementLayout.viewport)
        XCTAssertFalse(host.view.hasAmbiguousLayout)
        withExtendedLifetime((host, model, player)) {}
    }

    @MainActor
    private func runPlaylistLikedState(
        name: String,
        trackIDs: [Int64],
        liked: Set<Int64>,
        expectedUnliked: Int,
        model: AppModel,
        player: PlayerController,
        route: Route,
        host: UIHostingController<IOSRouteDestinationView>,
        membershipSignpost: StaticString,
        scanSignpost: StaticString,
        invalidationSignpost: StaticString,
        layoutSignpost: StaticString
    ) {
        XCTContext.runActivity(named: "PERF-B08 \(name)") { _ in
            let membershipHits = IOSMeasurementSignposts.interval(membershipSignpost) {
                trackIDs.reduce(into: 0) { count, id in
                    if liked.contains(id) { count += 1 }
                }
            }
            let scanCounts = IOSMeasurementSignposts.interval(scanSignpost) {
                (
                    trackIDs.filter { !liked.contains($0) }.count,
                    trackIDs.filter { !liked.contains($0) }.count
                )
            }
            XCTAssertEqual(membershipHits, trackIDs.count - expectedUnliked)
            XCTAssertEqual(scanCounts.0, expectedUnliked)
            XCTAssertEqual(scanCounts.1, expectedUnliked)

            IOSMeasurementSignposts.interval(invalidationSignpost) {
                model.likedSongIDs = liked
                host.rootView = IOSRouteDestinationView(route: route, model: model, player: player)
                host.view.setNeedsLayout()
            }
            IOSMeasurementSignposts.interval(layoutSignpost) {
                host.view.layoutIfNeeded()
            }
            XCTAssertEqual(host.view.bounds.size, IOSMeasurementLayout.viewport)
        }
    }
}

private enum IOSMeasurementLayout {
    static let viewport = CGSize(width: 390, height: 844)
}

@MainActor
private struct IOSMeasurementEmojiList: View {
    let parts: [[CommentEmojiPart]]
    let images: [[String: UIImage]]

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(parts.indices, id: \.self) { index in
                    renderedText(parts[index], images: images[index])
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(16)
        }
    }

    private func renderedText(_ parts: [CommentEmojiPart], images: [String: UIImage]) -> Text {
        parts.reduce(Text("")) { result, part in
            switch part {
            case let .text(text):
                result + Text(text)
            case let .emoji(token, _):
                if let image = images[token] {
                    result + Text(Image(uiImage: image)).baselineOffset(-3)
                } else {
                    result + Text(token)
                }
            }
        }
    }
}

@MainActor
private func measurementEmojiToken(_ part: CommentEmojiPart) -> String? {
    guard case let .emoji(token, _) = part else { return nil }
    return token
}

@MainActor
private func measurementSolidImage(edge: CGFloat, scale: CGFloat) -> UIImage {
    let format = UIGraphicsImageRendererFormat()
    format.scale = scale
    return UIGraphicsImageRenderer(size: CGSize(width: edge, height: edge), format: format).image { context in
        context.cgContext.setFillColor(UIColor.systemRed.cgColor)
        context.cgContext.fill(CGRect(x: 0, y: 0, width: edge, height: edge))
    }
}

@MainActor
private func measurementRedrawnImage(_ image: UIImage, edge: CGFloat, scale: CGFloat) -> UIImage {
    let format = UIGraphicsImageRendererFormat()
    format.scale = scale
    return UIGraphicsImageRenderer(size: CGSize(width: edge, height: edge), format: format).image { _ in
        image.draw(in: CGRect(x: 0, y: 0, width: edge, height: edge))
    }
}

@MainActor
private func measurementRedrawnEmojiDictionaries(
    parts: [[CommentEmojiPart]],
    sourceImage: UIImage
) -> [[String: UIImage]] {
    parts.map { row in
        var images: [String: UIImage] = [:]
        for part in row {
            guard let token = measurementEmojiToken(part), images[token] == nil else { continue }
            images[token] = measurementRedrawnImage(sourceImage, edge: 18, scale: 2)
        }
        return images
    }
}

@MainActor
private func measurementEmojiDictionaryHits(
    parts: [[CommentEmojiPart]],
    images: [[String: UIImage]]
) -> Int {
    zip(parts, images).reduce(into: 0) { count, row in
        for part in row.0 {
            guard let token = measurementEmojiToken(part), row.1[token] != nil else { continue }
            count += 1
        }
    }
}

@MainActor
private func layoutMeasurementView<Content: View>(
    _ content: Content,
    signpost: StaticString
) -> CGSize {
    let host = UIHostingController(rootView: content)
    IOSMeasurementSignposts.interval(signpost) {
        host.loadViewIfNeeded()
        host.view.frame = CGRect(origin: .zero, size: IOSMeasurementLayout.viewport)
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
    }
    let size = host.view.bounds.size
    XCTAssertFalse(host.view.hasAmbiguousLayout)
    withExtendedLifetime(host) {}
    return size
}

private func measurementLRC(lineCount: Int, prefix: String) -> String {
    (0..<lineCount).map { index in
        measurementLRCLine(
            timestamp: Int64(index) * 1_000,
            text: "\(prefix)-\(String(format: "%05d", index))"
        )
    }.joined(separator: "\n")
}

private func measurementPairedLyrics(lineCount: Int) -> (line: String, word: String) {
    var lineLyrics: [String] = []
    var wordLyrics: [String] = []
    lineLyrics.reserveCapacity(lineCount)
    wordLyrics.reserveCapacity(lineCount)
    for index in 0..<lineCount {
        let lineTimestamp = Int64(index) * 2_000
        let wordTimestamp = lineTimestamp + 120
        let text = "paired-\(String(format: "%04d", index))"
        lineLyrics.append(measurementLRCLine(timestamp: lineTimestamp, text: text))
        wordLyrics.append("[\(wordTimestamp),1000](\(wordTimestamp),1000,0)\(text)")
    }
    return (lineLyrics.joined(separator: "\n"), wordLyrics.joined(separator: "\n"))
}

private func measurementLRCLine(timestamp: Int64, text: String) -> String {
    let minutes = timestamp / 60_000
    let seconds = timestamp / 1_000 % 60
    let milliseconds = timestamp % 1_000
    return String(format: "[%lld:%02lld.%03lld]%@", minutes, seconds, milliseconds, text)
}

private func measurementAnnualPayload(trackCount: Int) -> [String: Any] {
    var items = (1...trackCount).map { id in
        measurementAnnualItem(id: Int64(id), name: "annual-\(String(format: "%05d", id))")
    }
    items.append(measurementAnnualItem(id: 2, name: "duplicate-2"))
    items.append(measurementAnnualItem(id: 1, name: "duplicate-1"))
    items.append(["songId": Int64(trackCount + 1)])
    items.append(["songId": 0, "songName": "invalid-zero"])
    return [
        "data": [
            "meetTimeOverview": ["playTime": 3_600, "playCount": trackCount],
            "annualPlaylist": ["items": items],
        ],
    ]
}

private func measurementAnnualControlPayload(ids: [Int64]) -> [String: Any] {
    [
        "data": [
            "annualPlaylist": [
                "items": ids.map { measurementAnnualItem(id: $0, name: "control-\($0)") },
            ],
        ],
    ]
}

private func measurementAnnualItem(id: Int64, name: String) -> [String: Any] {
    var item: [String: Any] = [
        "songId": id,
        "songName": name,
        "playCount": id,
    ]
    if id.isMultiple(of: 4) {
        item["artistId"] = id
        item["artistName"] = "artist-\(id)"
        item["picUrl"] = "https://fixture.invalid/artwork/\(id).jpg"
    }
    return item
}

private func measurementAnnualSong(id: Int64, name: String) -> Song {
    Song(
        id: id,
        name: name,
        artists: [ArtistSummary(id: id, name: "artist-\(id)")],
        album: AlbumSummary(
            id: id,
            name: "album-\(id)",
            artwork: Artwork(
                symbol: "music.note",
                accent: .red,
                remoteURL: URL(string: "https://fixture.invalid/artwork/\(id).jpg")
            )
        ),
        duration: .seconds(1)
    )
}

private enum IOSMeasurementSignposts {
    private static let signposter = OSSignposter(
        subsystem: "com.tinycloudmusic.app.tests",
        category: "W5-FX1A"
    )

    static func interval<T>(_ name: StaticString, _ operation: () throws -> T) rethrows -> T {
        let state = signposter.beginInterval(name)
        defer { signposter.endInterval(name, state) }
        return try operation()
    }

    @MainActor
    static func asyncInterval<T>(
        _ name: StaticString,
        _ operation: () async throws -> T
    ) async rethrows -> T {
        let state = signposter.beginInterval(name)
        defer { signposter.endInterval(name, state) }
        return try await operation()
    }

    static func markPagingScale(_ pageCount: Int) {
        switch pageCount {
        case 1: signposter.emitEvent("PERF-B05.Scale.1")
        case 10: signposter.emitEvent("PERF-B05.Scale.10")
        case 50: signposter.emitEvent("PERF-B05.Scale.50")
        case 100: signposter.emitEvent("PERF-B05.Scale.100")
        default: preconditionFailure("Unsupported paging fixture scale")
        }
    }
}

private final class IOSMeasurementURLProtocol: URLProtocol, @unchecked Sendable {
    private struct Stub: Sendable {
        let statusCode: Int
        let body: Data
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var stubs: [String: Stub] = [:]
    nonisolated(unsafe) private static var requestCounts: [String: Int] = [:]

    static func install(_ body: Data, for path: String) {
        lock.withLock {
            stubs[path] = Stub(statusCode: 200, body: body)
            requestCounts[path] = 0
        }
    }

    static func remove(path: String) {
        lock.withLock {
            stubs[path] = nil
            requestCounts[path] = nil
        }
    }

    static func requestCount(for path: String) -> Int {
        lock.withLock { requestCounts[path, default: 0] }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let path = request.url?.path ?? ""
        let stub = Self.lock.withLock {
            Self.requestCounts[path, default: 0] += 1
            return Self.stubs[path] ?? Stub(
                statusCode: 500,
                body: Data(#"{"code":500,"message":"unexpected fixture route"}"#.utf8)
            )
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: stub.statusCode,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: stub.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private struct IOSMeasurementPagingResult {
    let ids: [String]
    let operationCount: Int
    let inputCount: Int
    let position: Int
    let hasMore: Bool
}

private struct IOSGeneratedDetailRepository: MusicRepository {
    let trackCount: Int
    private let base = FixtureMusicRepository()

    var homeDescriptors: [HomeSectionDescriptor] { base.homeDescriptors }

    func homeSection(
        id: String,
        expectedCredentialRevision: UInt64
    ) async throws -> HomeSection {
        try await base.homeSection(id: id, expectedCredentialRevision: expectedCredentialRevision)
    }

    func search(query: String, scope: SearchScope, offset: Int, limit: Int) async throws -> SearchPage {
        try await base.search(query: query, scope: scope, offset: offset, limit: limit)
    }

    func detail(
        for route: Route,
        expectedCredentialRevision: UInt64?
    ) async throws -> DetailContent {
        guard case let .playlist(playlistID) = route else {
            return try await base.detail(
                for: route,
                expectedCredentialRevision: expectedCredentialRevision
            )
        }
        let artist = ArtistSummary(id: 1, name: "Fixture Artist")
        let album = AlbumSummary(
            id: playlistID,
            name: "Fixture Album \(playlistID)",
            artwork: Artwork(symbol: "opticaldisc", accent: .blue)
        )
        let firstID = playlistID * 100_000
        let songs = (0..<trackCount).map { index in
            Song(
                id: firstID + Int64(index),
                name: "Fixture Track \(index)",
                artists: [artist],
                album: album,
                duration: .seconds(180)
            )
        }
        let playlist = Playlist(
            id: playlistID,
            name: "Fixture Playlist \(playlistID)",
            creator: "Fixture Owner",
            description: "",
            artwork: Artwork(symbol: "music.note.list", accent: .green),
            trackCount: trackCount
        )
        return .playlist(
            playlist,
            songs: songs,
            trackIDs: songs.map(\.id),
            loadedTrackCount: songs.count
        )
    }

    func songs(ids: [Int64]) async throws -> [Song] { try await base.songs(ids: ids) }
    func lyrics(for songID: Int64) async throws -> SongLyrics { try await base.lyrics(for: songID) }

    func playbackSource(for songID: Int64, quality: AudioQuality) async throws -> PlaybackSource {
        try await base.playbackSource(for: songID, quality: quality)
    }

    func playbackSource(for songID: Int64, level: String) async throws -> PlaybackSource {
        try await base.playbackSource(for: songID, level: level)
    }

    func songQualityDetails(for songID: Int64) async throws -> [SongQualityDetail] {
        try await base.songQualityDetails(for: songID)
    }

    func recordPlaybackStart(
        for songID: Int64,
        sourceID: Int64,
        totalSeconds: Int,
        expectedCredentialRevision: UInt64
    ) async throws {
        try await base.recordPlaybackStart(
            for: songID,
            sourceID: sourceID,
            totalSeconds: totalSeconds,
            expectedCredentialRevision: expectedCredentialRevision
        )
    }

    func recordPlayback(
        for songID: Int64,
        sourceID: Int64,
        playedSeconds: Int,
        totalSeconds: Int,
        expectedCredentialRevision: UInt64
    ) async throws {
        try await base.recordPlayback(
            for: songID,
            sourceID: sourceID,
            playedSeconds: playedSeconds,
            totalSeconds: totalSeconds,
            expectedCredentialRevision: expectedCredentialRevision
        )
    }

    func recordPodcastPlayback(
        for episodeID: Int64,
        positionMilliseconds: Int,
        completed: Bool,
        expectedCredentialRevision: UInt64
    ) async throws {
        try await base.recordPodcastPlayback(
            for: episodeID,
            positionMilliseconds: positionMilliseconds,
            completed: completed,
            expectedCredentialRevision: expectedCredentialRevision
        )
    }
}

private extension DetailLoad {
    var measurementContent: DetailContent? {
        guard case let .loaded(content) = self else { return nil }
        return content
    }
}

private enum IOSMeasurementError: Error {
    case detailFailed(String)
    case timedOut
}

private func makeMeasurementTransport(
    responseCache: EAPIResponseCache = EAPIResponseCache(),
    weapiSecretKey: String? = nil
) -> (EAPITransport, URLSession) {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [IOSMeasurementURLProtocol.self]
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    configuration.urlCache = nil
    let session = URLSession(configuration: configuration)
    return (
        EAPITransport(
            session: session,
            cookie: "MUSIC_A=offline-fixture",
            musicU: "",
            weapiSecretKey: weapiSecretKey,
            responseCache: responseCache
        ),
        session
    )
}

private func runMeasurementWEAPICacheMisses(
    transport: EAPITransport,
    path: String
) async throws -> Data {
    var result = Data()
    for iteration in 0..<32 {
        result = try await transport.requestWEAPI(
            path: path,
            payload: [
                "iteration": iteration,
                "items": (0..<64).map { ["id": $0, "name": "fixture-\($0)"] },
            ],
            cache: .search,
            invalidatesAccountCache: false,
            retryable: false
        )
    }
    return result
}

private func makeMeasurementPlaylistResponse(
    playlistID: Int64,
    trackCount: Int,
    includesTracks: Bool
) throws -> Data {
    let firstID = playlistID * 100_000
    let ids = (0..<trackCount).map { firstID + Int64($0) }
    var playlist: [String: Any] = [
        "id": playlistID,
        "name": "Fixture Playlist \(playlistID)",
        "trackCount": trackCount,
        "creator": ["userId": 1, "nickname": "Fixture Owner"],
        "trackIds": ids.map { ["id": $0] },
    ]
    playlist["tracks"] = includesTracks ? ids.enumerated().map { index, id in
        [
            "id": id,
            "name": "Fixture Track \(index)",
            "ar": [["id": 1, "name": "Fixture Artist"]],
            "al": ["id": playlistID, "name": "Fixture Album"],
            "dt": 180_000,
        ] as [String: Any]
    } : []
    return try JSONSerialization.data(
        withJSONObject: ["code": 200, "playlist": playlist],
        options: [.sortedKeys]
    )
}

@MainActor
private func waitForMeasurementDetail(_ route: Route, in model: AppModel) async throws -> DetailContent {
    for _ in 0..<200 {
        switch model.detailLoads[route] {
        case let .loaded(content): return content
        case let .failed(message): throw IOSMeasurementError.detailFailed(message)
        default: try await Task.sleep(for: .milliseconds(1))
        }
    }
    throw IOSMeasurementError.timedOut
}

private func assertMeasurementPlaylistDetail(
    _ detail: DetailContent,
    trackCount: Int,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    guard case let .playlist(playlist, songs, trackIDs, loadedTrackCount) = detail else {
        return XCTFail("Expected a playlist detail", file: file, line: line)
    }
    XCTAssertEqual(playlist.trackCount, trackCount, file: file, line: line)
    XCTAssertEqual(trackIDs.count, trackCount, file: file, line: line)
    XCTAssertEqual(Set(trackIDs).count, trackCount, file: file, line: line)
    XCTAssertEqual(loadedTrackCount, songs.count, file: file, line: line)
}

private func measurementPageIDs(pageIndex: Int, width: Int) -> [Int] {
    let first = pageIndex * width
    let fresh = Array(first..<(first + width))
    let overlap = pageIndex == 0 ? first : first - 1
    return fresh + [overlap, first]
}

@MainActor
private func runMeasurementSearchPaging(pageCount: Int, width: Int) -> IOSMeasurementPagingResult {
    var result: SearchPage?
    var inputCount = 0
    for pageIndex in 0..<pageCount {
        let ids = measurementPageIDs(pageIndex: pageIndex, width: width)
        inputCount += ids.count
        let page = SearchPage(
            items: ids.map {
                .video(VideoSummary(
                    id: "search-\($0)",
                    title: "Fixture Video \($0)",
                    creatorName: "Fixture Creator",
                    coverURL: nil,
                    durationMilliseconds: 1_000
                ))
            },
            offset: pageIndex * width,
            hasMore: pageIndex + 1 < pageCount
        )
        result = AppModel.mergedSearchPage(result, page)
    }
    return IOSMeasurementPagingResult(
        ids: result?.items.map(\.id) ?? [],
        operationCount: pageCount,
        inputCount: inputCount,
        position: result?.offset ?? -1,
        hasMore: result?.hasMore ?? true
    )
}

private func runMeasurementPodcastPaging(pageCount: Int, width: Int) -> IOSMeasurementPagingResult {
    var result = PodcastPage(podcasts: [], nextOffset: 0, hasMore: true)
    var inputCount = 0
    for pageIndex in 0..<pageCount {
        let ids = measurementPageIDs(pageIndex: pageIndex, width: width)
        inputCount += ids.count
        result = result.appending(PodcastPage(
            podcasts: ids.map {
                Podcast(
                    id: Int64($0),
                    name: "Fixture Podcast \($0)",
                    hostName: "Fixture Host",
                    coverURL: nil,
                    categoryName: "Fixture",
                    isSubscribed: false
                )
            },
            nextOffset: (pageIndex + 1) * width,
            hasMore: pageIndex + 1 < pageCount
        ))
    }
    return IOSMeasurementPagingResult(
        ids: result.podcasts.map { "podcast-\($0.id)" },
        operationCount: pageCount,
        inputCount: inputCount,
        position: result.nextOffset,
        hasMore: result.hasMore
    )
}

private func runMeasurementEpisodePaging(pageCount: Int, width: Int) -> IOSMeasurementPagingResult {
    var result = PodcastEpisodePage(episodes: [], nextOffset: 0, hasMore: true)
    var inputCount = 0
    for pageIndex in 0..<pageCount {
        let ids = measurementPageIDs(pageIndex: pageIndex, width: width)
        inputCount += ids.count
        result = result.appending(PodcastEpisodePage(
            episodes: ids.map {
                PodcastEpisode(
                    id: Int64($0),
                    podcastID: 1,
                    title: "Fixture Episode \($0)",
                    coverURL: nil,
                    durationMilliseconds: 1_000,
                    publishedAt: nil,
                    song: nil
                )
            },
            nextOffset: (pageIndex + 1) * width,
            hasMore: pageIndex + 1 < pageCount
        ))
    }
    return IOSMeasurementPagingResult(
        ids: result.episodes.map { "episode-\($0.id)" },
        operationCount: pageCount,
        inputCount: inputCount,
        position: result.nextOffset,
        hasMore: result.hasMore
    )
}

private func runMeasurementBroadcastPaging(pageCount: Int, width: Int) -> IOSMeasurementPagingResult {
    var result = BroadcastChannelPage(channels: [], nextCursor: .initial, hasMore: true)
    var inputCount = 0
    for pageIndex in 0..<pageCount {
        let ids = measurementPageIDs(pageIndex: pageIndex, width: width)
        inputCount += ids.count
        result = result.appending(BroadcastChannelPage(
            channels: ids.map {
                BroadcastChannel(
                    id: "broadcast-\($0)",
                    name: "Fixture Broadcast \($0)",
                    regionName: "Fixture",
                    coverURL: nil,
                    isCollected: false
                )
            },
            nextCursor: BroadcastCursor(lastID: String(pageIndex + 1), score: String(pageIndex)),
            hasMore: pageIndex + 1 < pageCount
        ))
    }
    return IOSMeasurementPagingResult(
        ids: result.channels.map(\.id),
        operationCount: pageCount,
        inputCount: inputCount,
        position: Int(result.nextCursor.lastID) ?? -1,
        hasMore: result.hasMore
    )
}

private func runMeasurementVideoPaging(pageCount: Int, width: Int) -> IOSMeasurementPagingResult {
    var result = VideoSubscriptionPage(items: [], nextOffset: 0, hasMore: true)
    var inputCount = 0
    for pageIndex in 0..<pageCount {
        let ids = measurementPageIDs(pageIndex: pageIndex, width: width)
        inputCount += ids.count
        result = result.appending(VideoSubscriptionPage(
            items: ids.map {
                .video(VideoSummary(
                    id: "subscription-\($0)",
                    title: "Fixture Subscription \($0)",
                    creatorName: "Fixture Creator",
                    coverURL: nil,
                    durationMilliseconds: 1_000
                ))
            },
            nextOffset: (pageIndex + 1) * width,
            hasMore: pageIndex + 1 < pageCount
        ))
    }
    return IOSMeasurementPagingResult(
        ids: result.items.map(\.id),
        operationCount: pageCount,
        inputCount: inputCount,
        position: result.nextOffset,
        hasMore: result.hasMore
    )
}

private func assertMeasurementPaging(
    _ result: IOSMeasurementPagingResult,
    pageCount: Int,
    width: Int,
    prefix: String,
    expectedPosition: Int,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    let expectedIDs = (0..<(pageCount * width)).map { "\(prefix)\($0)" }
    XCTAssertEqual(result.ids, expectedIDs, file: file, line: line)
    XCTAssertEqual(Set(result.ids).count, result.ids.count, file: file, line: line)
    XCTAssertEqual(result.operationCount, pageCount, file: file, line: line)
    XCTAssertEqual(result.inputCount, pageCount * (width + 2), file: file, line: line)
    XCTAssertEqual(result.position, expectedPosition, file: file, line: line)
    XCTAssertFalse(result.hasMore, file: file, line: line)
}
