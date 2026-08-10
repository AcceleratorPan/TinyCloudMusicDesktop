import Foundation

struct LiveMusicLibrary: Sendable {
    private static let interfaceHost = "https://interface3.music.163.com"
    private static let eapiHost = "https://interfacepc.music.163.com"
    static let cloudLyricEndpoint = EAPIEndpoint("/eapi/cloud/lyric/get", signing: "/api/cloud/lyric/get")
    static let cloudDownloadEndpoint = EAPIEndpoint("/eapi/cloud/dowonload", signing: "/api/cloud/dowonload")
    let transport: EAPITransport

    init(transport: EAPITransport = EAPITransport()) {
        self.transport = transport
    }

    func loginState(
        forceRefresh: Bool = false,
        expectedCredentialRevision: UInt64? = nil
    ) async throws -> MusicLibraryLoginState {
        let endpoint = EAPIEndpoint("/eapi/v1/user/info", signing: "/api/v1/user/info")
        let root = try await transport.requestJSONObject(
            endpoint,
            json: Data(),
            cache: .library,
            refreshCache: forceRefresh,
            expectedCredentialRevision: expectedCredentialRevision,
            allowsDomainBusinessCodes: true
        )
        guard (200..<300).contains(root.int("code")) else { return .loggedOut }
        let userID = root.object("userPoint").int64("userId")
        guard userID != 0 else { return .loggedOut }

        return .loggedIn(try await userInfo(
            userID: userID,
            forceRefresh: forceRefresh,
            expectedCredentialRevision: expectedCredentialRevision
        ))
    }

    func userInfo(
        userID: Int64,
        forceRefresh: Bool = false,
        expectedCredentialRevision: UInt64? = nil
    ) async throws -> MusicLibraryUser {
        guard userID > 0 else { throw EAPIError.invalidPayload }
        let root = try await call(
            EAPIEndpoint("/eapi/v1/user/detail", signing: "/api/v1/user/detail/\(userID)"),
            json: Data(),
            refreshCache: forceRefresh,
            expectedCredentialRevision: expectedCredentialRevision
        )
        guard let user = MusicLibraryDecoder.user(root.object("profile"), root: root) else {
            throw EAPIError.missingData("profile")
        }
        return user
    }

    func dailyRecommendations(
        forceRefresh: Bool = false,
        expectedCredentialRevision: UInt64
    ) async throws -> [Song] {
        let root = try await call(
            EAPIEndpoint(
                "/api/v3/discovery/recommend/songs",
                signing: "/api/v3/discovery/recommend/songs"
            ),
            json: Data(),
            refreshCache: forceRefresh,
            expectedCredentialRevision: expectedCredentialRevision
        )
        return root.object("data").array("dailySongs").compactMap(songDecoder.decodeLiveSong)
    }

    func userPlaylists(
        userID: Int64,
        forceRefresh: Bool = false,
        expectedCredentialRevision: UInt64,
        onUpdate: (@MainActor @Sendable ([Playlist]) -> Void)? = nil
    ) async throws -> [Playlist] {
        guard userID > 0 else { throw EAPIError.invalidPayload }
        let endpoint = EAPIEndpoint("/eapi/user/playlist", signing: "/api/user/playlist")
        var playlists: [Playlist] = []
        var seen = Set<Int64>()
        var offset = 0
        while true {
            let limit = 100
            let root = try await call(
                endpoint,
                payload: ["uid": userID, "offset": offset, "limit": limit],
                cache: .playlistSummaries,
                refreshCache: forceRefresh,
                expectedCredentialRevision: expectedCredentialRevision
            )
            try Task.checkCancellation()
            let raw = Array(root.array("playlist").prefix(limit))
            let page = raw.compactMap(songDecoder.decodeLivePlaylist)
            let added = page.filter { seen.insert($0.id).inserted }
            playlists.append(contentsOf: added)
            if !added.isEmpty { await onUpdate?(playlists) }
            let nextOffset = offset + raw.count
            guard root.bool("more"), !raw.isEmpty, !added.isEmpty,
                  nextOffset > offset
            else { break }
            offset = nextOffset
        }
        return playlists
    }

    func recommendationHistoryDates(
        forceRefresh: Bool = false,
        expectedCredentialRevision: UInt64
    ) async throws -> [RecommendationHistoryDate] {
        decodeRecommendationHistoryDates(
            try await transport.requestRecommendationHistory(
                refreshCache: forceRefresh,
                expectedCredentialRevision: expectedCredentialRevision
            )
        )
    }

    func decodeRecommendationHistoryDates(_ root: [String: Any]) -> [RecommendationHistoryDate] {
        RecommendationMemoryDecoder.historyDates(root)
    }

    func historicalDailyRecommendations(
        on date: RecommendationHistoryDate,
        availableDates: [RecommendationHistoryDate],
        forceRefresh: Bool = false,
        expectedCredentialRevision: UInt64
    ) async throws -> [Song] {
        guard availableDates.contains(date) else { throw EAPIError.invalidPayload }
        return decodeHistoricalDailyRecommendations(
            try await transport.requestRecommendationHistory(
                date: date.value,
                refreshCache: forceRefresh,
                expectedCredentialRevision: expectedCredentialRevision
            )
        )
    }

    func decodeHistoricalDailyRecommendations(_ root: [String: Any]) -> [Song] {
        root.object("data").array("songs").compactMap(songDecoder.decodeLiveSong)
    }

    func recentlyPlayedSongs(
        limit: Int = 100,
        forceRefresh: Bool = false,
        expectedCredentialRevision: UInt64
    ) async throws -> [Song] {
        decodeRecentlyPlayedSongs(
            try await recentPlaybackRoot(
                .song,
                limit: limit,
                forceRefresh: forceRefresh,
                expectedCredentialRevision: expectedCredentialRevision
            )
        )
    }

    func decodeRecentlyPlayedSongs(_ root: [String: Any]) -> [Song] {
        decodeRecentResources(root, kind: .song, decode: songDecoder.decodeLiveSong, title: \.name)
    }

    func recentlyPlayedAlbums(
        limit: Int = 100,
        forceRefresh: Bool = false,
        expectedCredentialRevision: UInt64
    ) async throws -> [Album] {
        decodeRecentlyPlayedAlbums(
            try await recentPlaybackRoot(
                .album,
                limit: limit,
                forceRefresh: forceRefresh,
                expectedCredentialRevision: expectedCredentialRevision
            )
        )
    }

    func decodeRecentlyPlayedAlbums(_ root: [String: Any]) -> [Album] {
        decodeRecentResources(root, kind: .album, decode: songDecoder.decodeLiveAlbum, title: \.name)
    }

    func recentlyPlayedPlaylists(
        limit: Int = 100,
        forceRefresh: Bool = false,
        expectedCredentialRevision: UInt64
    ) async throws -> [Playlist] {
        decodeRecentlyPlayedPlaylists(
            try await recentPlaybackRoot(
                .playlist,
                limit: limit,
                forceRefresh: forceRefresh,
                expectedCredentialRevision: expectedCredentialRevision
            )
        )
    }

    func decodeRecentlyPlayedPlaylists(_ root: [String: Any]) -> [Playlist] {
        decodeRecentResources(root, kind: .playlist, decode: songDecoder.decodeLivePlaylist, title: \.name)
    }

    func recentlyPlayedVideos(
        limit: Int = 100,
        forceRefresh: Bool = false,
        expectedCredentialRevision: UInt64
    ) async throws -> [RecentMediaSummary] {
        try await recentlyPlayedMedia(
            .video,
            limit: limit,
            forceRefresh: forceRefresh,
            expectedCredentialRevision: expectedCredentialRevision
        )
    }

    func recentlyPlayedVoices(
        limit: Int = 100,
        forceRefresh: Bool = false,
        expectedCredentialRevision: UInt64
    ) async throws -> [RecentMediaSummary] {
        try await recentlyPlayedMedia(
            .voice,
            limit: limit,
            forceRefresh: forceRefresh,
            expectedCredentialRevision: expectedCredentialRevision
        )
    }

    func recentlyPlayedPodcasts(
        limit: Int = 100,
        forceRefresh: Bool = false,
        expectedCredentialRevision: UInt64
    ) async throws -> [RecentMediaSummary] {
        try await recentlyPlayedMedia(
            .podcast,
            limit: limit,
            forceRefresh: forceRefresh,
            expectedCredentialRevision: expectedCredentialRevision
        )
    }

    func decodeRecentlyPlayedMedia(
        _ root: [String: Any],
        kind: RecentPlaybackKind
    ) -> [RecentMediaSummary] {
        MusicLibraryDecoder.recentMedia(root, kind: kind)
    }

    func listeningRecords(
        userID: Int64,
        period: MusicListeningPeriod,
        forceRefresh: Bool = false,
        expectedCredentialRevision: UInt64
    ) async throws -> [MusicListeningRecord] {
        guard userID > 0 else { throw EAPIError.invalidPayload }
        let root = try await call(
            EAPIEndpoint("/eapi/v1/play/record", signing: "/api/v1/play/record"),
            payload: ["uid": String(userID), "type": period.rawValue],
            cache: .listeningHistory,
            refreshCache: forceRefresh,
            expectedCredentialRevision: expectedCredentialRevision
        )
        return decodeListeningRecords(root, period: period)
    }

    func decodeListeningRecords(
        _ root: [String: Any],
        period: MusicListeningPeriod
    ) -> [MusicListeningRecord] {
        root.array(period.responseKey).compactMap { value in
            guard let song = songDecoder.decodeLiveSong(value.object("song")) else { return nil }
            return MusicListeningRecord(
                song: song,
                playCount: value.int("playCount"),
                score: value.int("score")
            )
        }
    }

    func totalListeningDuration(
        forceRefresh: Bool = false,
        expectedCredentialRevision: UInt64
    ) async throws -> Int64 {
        // This endpoint rejects the VIP requester and must use the account's original cookie.
        let root = try await call(
            EAPIEndpoint(
                "/eapi/content/activity/listen/data/total",
                signing: "/api/content/activity/listen/data/total",
                host: Self.eapiHost
            ),
            payload: [:],
            cache: .listeningHistory,
            refreshCache: forceRefresh,
            expectedCredentialRevision: expectedCredentialRevision,
            includesClientHeader: true
        )
        try requireSuccess(root)
        return try decodeTotalListeningDuration(root)
    }

    func decodeTotalListeningDuration(_ root: [String: Any]) throws -> Int64 {
        let data = root.object("data")
        guard let value = data["totalDuration"] else {
            throw EAPIError.missingData("data.totalDuration")
        }
        let duration: Int64? = if let value = value as? NSNumber {
            value.int64Value
        } else if let value = value as? String {
            Int64(value)
        } else {
            nil
        }
        guard let duration else { throw EAPIError.invalidResponse }
        guard duration >= 0 else { throw EAPIError.invalidResponse }
        return duration
    }

    func todayListeningRank(
        forceRefresh: Bool = false,
        expectedCredentialRevision: UInt64
    ) async throws -> [ListeningRankEntry] {
        let root = try await call(
            EAPIEndpoint(
                "/eapi/content/activity/listen/data/today/song/play/rank",
                signing: "/api/content/activity/listen/data/today/song/play/rank",
                host: Self.eapiHost
            ),
            payload: [:],
            cache: .listeningHistory,
            refreshCache: forceRefresh,
            expectedCredentialRevision: expectedCredentialRevision,
            includesClientHeader: true
        )
        try requireSuccess(root)
        return decodeListeningRank(root)
    }

    func listeningSongRank(
        period: ListeningReportPeriod,
        cursor: ListeningReportCursor? = nil,
        forceRefresh: Bool = false,
        expectedCredentialRevision: UInt64
    ) async throws -> [ListeningRankEntry] {
        guard period != .year else { throw EAPIError.invalidPayload }
        let root = try await call(
            EAPIEndpoint(
                "/eapi/content/activity/listen/data/song/play/rank",
                signing: "/api/content/activity/listen/data/song/play/rank",
                host: Self.eapiHost
            ),
            payload: listeningPayload(period: period, cursor: cursor),
            cache: .listeningHistory,
            refreshCache: forceRefresh,
            expectedCredentialRevision: expectedCredentialRevision,
            includesClientHeader: true
        )
        try requireSuccess(root)
        return decodeListeningRank(root)
    }

    func realtimeListeningReport(
        period: ListeningReportPeriod,
        forceRefresh: Bool = false,
        expectedCredentialRevision: UInt64
    ) async throws -> ListeningReport {
        guard period != .year else { throw EAPIError.invalidPayload }
        let root = try await call(
            EAPIEndpoint(
                "/eapi/content/activity/listen/data/realtime/report",
                signing: "/api/content/activity/listen/data/realtime/report",
                host: Self.eapiHost
            ),
            payload: ["type": period.rawValue],
            cache: .listeningHistory,
            refreshCache: forceRefresh,
            expectedCredentialRevision: expectedCredentialRevision,
            includesClientHeader: true
        )
        try requireSuccess(root)
        return decodeRealtimeListeningReport(root, period: period)
    }

    func listeningReport(
        period: ListeningReportPeriod,
        cursor: ListeningReportCursor? = nil,
        forceRefresh: Bool = false,
        expectedCredentialRevision: UInt64
    ) async throws -> ListeningReport {
        let root = try await call(
            EAPIEndpoint(
                "/eapi/content/activity/listen/data/report",
                signing: "/api/content/activity/listen/data/report",
                host: Self.eapiHost
            ),
            payload: listeningPayload(period: period, cursor: cursor),
            cache: .listeningHistory,
            refreshCache: forceRefresh,
            expectedCredentialRevision: expectedCredentialRevision,
            includesClientHeader: true
        )
        try requireSuccess(root)
        return decodeListeningReport(root, period: period, defaultTitle: "\(period.title)听歌报告")
    }

    func yearListeningFootprints(
        forceRefresh: Bool = false,
        expectedCredentialRevision: UInt64
    ) async throws -> [YearListeningFootprint] {
        let root = try await call(
            EAPIEndpoint(
                "/eapi/content/activity/listen/data/year/report",
                signing: "/api/content/activity/listen/data/year/report",
                host: Self.eapiHost
            ),
            payload: [:],
            cache: .listeningHistory,
            refreshCache: forceRefresh,
            expectedCredentialRevision: expectedCredentialRevision,
            includesClientHeader: true
        )
        try requireSuccess(root)
        return decodeYearListeningFootprints(root)
    }

    func annualListeningReport(
        year: Int,
        forceRefresh: Bool = false,
        expectedCredentialRevision: UInt64
    ) async throws -> AnnualListeningReport {
        guard AnnualListeningReportDecoder.supportedYears.contains(year) else {
            throw EAPIError.invalidPayload
        }
        let key = year <= 2019 ? "userdata" : "data"
        let path = "/api/activity/summary/annual/\(year)/\(key)"
        let root = try await call(
            EAPIEndpoint(
                path.replacingOccurrences(of: "/api/", with: "/eapi/"),
                signing: path,
                host: Self.eapiHost
            ),
            payload: [:],
            cache: .listeningHistory,
            refreshCache: forceRefresh,
            expectedCredentialRevision: expectedCredentialRevision,
            includesClientHeader: true
        )
        try requireSuccess(root)
        return decodeAnnualListeningReport(root, year: year)
    }

    func firstListenMemory(
        songID: Int64,
        forceRefresh: Bool = false,
        expectedCredentialRevision: UInt64
    ) async throws -> FirstListenMemory {
        guard songID > 0 else { throw EAPIError.invalidPayload }
        let root = try await call(
            EAPIEndpoint(
                "/eapi/content/activity/music/first/listen/info",
                signing: "/api/content/activity/music/first/listen/info",
                host: Self.eapiHost
            ),
            payload: ["songId": songID],
            cache: .detail,
            refreshCache: forceRefresh,
            expectedCredentialRevision: expectedCredentialRevision,
            includesClientHeader: true
        )
        try requireSuccess(root)
        return decodeFirstListenMemory(root)
    }

    func decodeListeningRank(_ root: [String: Any]) -> [ListeningRankEntry] {
        ListeningReportDecoder.rankEntries(root, decodeSong: songDecoder.decodeLiveSong)
    }

    func decodeListeningReport(
        _ root: [String: Any],
        period: ListeningReportPeriod,
        defaultTitle: String? = nil
    ) -> ListeningReport {
        ListeningReportDecoder.report(
            root,
            period: period,
            defaultTitle: defaultTitle ?? "\(period.title)听歌报告",
            decodeSong: songDecoder.decodeLiveSong
        )
    }

    func decodeRealtimeListeningReport(
        _ root: [String: Any],
        period: ListeningReportPeriod
    ) -> ListeningReport {
        ListeningReportDecoder.realtimeReport(
            root,
            period: period,
            defaultTitle: "\(period.title)实时摘要"
        )
    }

    func decodeYearListeningFootprints(_ root: [String: Any]) -> [YearListeningFootprint] {
        ListeningReportDecoder.yearFootprints(root)
    }

    func decodeAnnualListeningReport(_ root: [String: Any], year: Int) -> AnnualListeningReport {
        AnnualListeningReportDecoder.report(root, year: year, decodeSong: songDecoder.decodeLiveSong)
    }

    func decodeFirstListenMemory(_ root: [String: Any], now: Date = Date()) -> FirstListenMemory {
        ListeningReportDecoder.firstListenMemory(root, now: now)
    }

    func personalFM(
        mode: PersonalFMMode,
        limit: Int = 3,
        expectedCredentialRevision: UInt64
    ) async throws -> [PersonalFMTrack] {
        guard (1...10).contains(limit) else { throw EAPIError.invalidPayload }
        let values = mode.requestValues
        let root = try await call(
            EAPIEndpoint(
                "/eapi/v1/radio/get",
                signing: "/api/v1/radio/get",
                host: Self.eapiHost
            ),
            payload: ["mode": values.mode, "subMode": values.subMode, "limit": limit],
            cache: nil,
            expectedCredentialRevision: expectedCredentialRevision
        )
        return decodePersonalFM(root)
    }

    func decodePersonalFM(_ root: [String: Any]) -> [PersonalFMTrack] {
        root.array("data").compactMap { value in
            guard let song = songDecoder.decodeLiveSong(value) else { return nil }
            let algorithm = value.string("alg")
            return PersonalFMTrack(song: song, algorithm: algorithm.isEmpty ? "RT" : algorithm)
        }
    }

    func trashPersonalFMTrack(
        _ track: PersonalFMTrack,
        playedSeconds: Int,
        expectedCredentialRevision: UInt64
    ) async throws {
        _ = try await transport.requestFMTrash(
            songID: track.id,
            algorithm: track.algorithm,
            playedSeconds: max(1, playedSeconds),
            expectedCredentialRevision: expectedCredentialRevision
        )
    }

    func hasActiveVIP() async throws -> Bool {
        let root = try await transport.requestJSONObject(
            EAPIEndpoint(
                "/eapi/music-vip-membership/client/vip/info",
                signing: "/api/music-vip-membership/client/vip/info",
                host: Self.interfaceHost
            ),
            json: compactJSON(["verifyId": 1, "e_r": true, "os": "iOS"]),
            vip: true
        )
        let data = root.object("data")
        return data.int64("now") < data.object("musicPackage").int64("expireTime")
    }

    func setSongLiked(
        _ songID: Int64,
        liked: Bool,
        expectedCredentialRevision: UInt64
    ) async throws {
        guard songID > 0 else { throw EAPIError.invalidPayload }
        _ = try await mutate(
            EAPIEndpoint("/eapi/song/like", signing: "/api/song/like"),
            payload: ["trackId": songID, "like": liked],
            expectedCredentialRevision: expectedCredentialRevision
        )
    }

    func setPlaylistSubscribed(
        _ playlistID: Int64,
        subscribed: Bool,
        expectedCredentialRevision: UInt64
    ) async throws {
        guard playlistID > 0 else { throw EAPIError.invalidPayload }
        let action = subscribed ? "subscribe" : "unsubscribe"
        _ = try await mutate(
            EAPIEndpoint(
                "/eapi/playlist/\(action)",
                signing: "/api/playlist/\(action)",
                host: Self.interfaceHost
            ),
            payload: ["id": playlistID, "e_r": true, "verifyId": 1],
            expectedCredentialRevision: expectedCredentialRevision
        )
    }

    func setAlbumSubscribed(
        _ albumID: Int64,
        subscribed: Bool,
        expectedCredentialRevision: UInt64
    ) async throws {
        guard albumID > 0 else { throw EAPIError.invalidPayload }
        let action = subscribed ? "sub" : "unsub"
        _ = try await mutate(
            EAPIEndpoint(
                "/eapi/album/\(action)",
                signing: "/api/album/\(action)",
                host: Self.interfaceHost
            ),
            payload: ["id": String(albumID), "e_r": true, "verifyId": 1],
            expectedCredentialRevision: expectedCredentialRevision
        )
    }

    func setArtistFollowed(
        _ artistID: Int64,
        followed: Bool,
        expectedCredentialRevision: UInt64
    ) async throws {
        guard artistID > 0 else { throw EAPIError.invalidPayload }
        let endpoint = followed
            ? EAPIEndpoint(
                "/eapi/v1/artist/sub",
                signing: "/api/v1/artist/sub",
                host: Self.interfaceHost
            )
            : EAPIEndpoint(
                "/eapi/artist/unsub",
                signing: "/api/artist/unsub",
                host: Self.interfaceHost
            )
        let payload: [String: Any] = followed
            ? ["artistId": String(artistID), "e_r": true]
            : ["artistIds": try jsonString([artistID]), "e_r": true]
        _ = try await mutate(
            endpoint,
            payload: payload,
            expectedCredentialRevision: expectedCredentialRevision
        )
    }

    func setUserFollowed(
        _ userID: Int64,
        followed: Bool,
        expectedCredentialRevision: UInt64
    ) async throws {
        guard userID > 0 else { throw EAPIError.invalidPayload }
        let action = followed ? "follow" : "delfollow"
        _ = try await mutate(
            EAPIEndpoint(
                "/eapi/user/\(action)/\(userID)",
                signing: "/api/user/\(action)/\(userID)",
                host: Self.interfaceHost
            ),
            payload: ["verifyId": 1, "e_r": true],
            expectedCredentialRevision: expectedCredentialRevision
        )
    }

    func createPlaylist(
        name: String,
        privacy: MusicPlaylistPrivacy = .publicPlaylist,
        expectedCredentialRevision: UInt64
    ) async throws -> Int64 {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw EAPIError.invalidPayload }
        let root = try await mutate(
            EAPIEndpoint(
                "/eapi/playlist/create",
                signing: "/api/playlist/create",
                host: Self.interfaceHost
            ),
            payload: [
                "os": "iOS",
                "verifyId": 1,
                "privacy": privacy.rawValue,
                "type": "NORMAL",
                "name": name,
                "e_r": true
            ],
            expectedCredentialRevision: expectedCredentialRevision,
            invalidatesGroups: [.playlistSummaries]
        )
        let id = root.int64("id")
        guard id != 0 else { throw EAPIError.missingData("id") }
        return id
    }

    func deletePlaylist(_ playlistID: Int64, expectedCredentialRevision: UInt64) async throws {
        guard playlistID > 0 else { throw EAPIError.invalidPayload }
        _ = try await mutate(
            EAPIEndpoint(
                "/eapi/playlist/delete",
                signing: "/api/playlist/delete",
                host: Self.interfaceHost
            ),
            payload: ["os": "iOS", "verifyId": 1, "pid": playlistID, "e_r": true],
            expectedCredentialRevision: expectedCredentialRevision,
            invalidatesGroups: [.playlistSummaries]
        )
    }

    func updatePlaylistName(
        _ playlistID: Int64,
        name: String,
        expectedCredentialRevision: UInt64
    ) async throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard playlistID > 0, !name.isEmpty else { throw EAPIError.invalidPayload }
        _ = try await mutate(
            EAPIEndpoint(
                "/eapi/playlist/update/name",
                signing: "/api/playlist/update/name",
                host: "https://interface.music.163.com"
            ),
            payload: ["id": playlistID, "name": name],
            expectedCredentialRevision: expectedCredentialRevision
        )
    }

    func updatePlaylistDescription(
        _ playlistID: Int64,
        description: String,
        expectedCredentialRevision: UInt64
    ) async throws {
        guard playlistID > 0 else { throw EAPIError.invalidPayload }
        _ = try await mutate(
            EAPIEndpoint(
                "/eapi/playlist/desc/update",
                signing: "/api/playlist/desc/update",
                host: "https://interface.music.163.com"
            ),
            payload: ["id": playlistID, "desc": description],
            expectedCredentialRevision: expectedCredentialRevision
        )
    }

    func updatePlaylistTags(
        _ playlistID: Int64,
        tags: [String],
        expectedCredentialRevision: UInt64
    ) async throws {
        guard playlistID > 0 else { throw EAPIError.invalidPayload }
        let tags = PlaylistMetadataDraft.normalizeTags(tags)
        _ = try await mutate(
            EAPIEndpoint(
                "/eapi/playlist/tags/update",
                signing: "/api/playlist/tags/update",
                host: "https://interface.music.163.com"
            ),
            payload: ["id": playlistID, "tags": tags.joined(separator: ";")],
            expectedCredentialRevision: expectedCredentialRevision
        )
    }

    func updatePlaylistCover(
        _ playlistID: Int64,
        cover: ProcessedPlaylistCover,
        expectedCredentialRevision: UInt64
    ) async throws {
        guard playlistID > 0 else { throw EAPIError.invalidPayload }
        try await PlaylistImageUpload(transport: transport).updateCover(
            playlistID: playlistID,
            cover: cover,
            expectedCredentialRevision: expectedCredentialRevision
        )
    }

    func updatePlaylistOrder(
        _ playlistIDs: [Int64],
        expectedCredentialRevision: UInt64
    ) async throws {
        guard !playlistIDs.isEmpty,
              playlistIDs.allSatisfy({ $0 > 0 }),
              Set(playlistIDs).count == playlistIDs.count
        else { throw EAPIError.invalidPayload }
        let root = try await transport.requestWEAPIJSONObject(
            path: "/weapi/playlist/order/update",
            payload: ["ids": try jsonString(playlistIDs.map(String.init))],
            expectedCredentialRevision: expectedCredentialRevision,
            invalidatesGroups: [.playlistSummaries],
            invalidatesAccountCache: false,
            retryable: false
        )
        try requireSuccess(root)
    }

    func updatePlaylistSongOrder(
        _ playlistID: Int64,
        trackIDs: [Int64],
        expectedCredentialRevision: UInt64
    ) async throws {
        guard playlistID > 0,
              !trackIDs.isEmpty,
              trackIDs.allSatisfy({ $0 > 0 }),
              Set(trackIDs).count == trackIDs.count
        else { throw EAPIError.invalidPayload }
        _ = try await mutate(
            EAPIEndpoint(
                "/eapi/playlist/manipulate/tracks",
                signing: "/api/playlist/manipulate/tracks"
            ),
            payload: [
                "pid": String(playlistID),
                "trackIds": try jsonString(trackIDs.map(String.init)),
                "op": "update"
            ],
            expectedCredentialRevision: expectedCredentialRevision
        )
    }

    func makePlaylistPublic(
        _ playlistID: Int64,
        expectedCredentialRevision: UInt64
    ) async throws {
        guard playlistID > 0 else { throw EAPIError.invalidPayload }
        _ = try await mutate(
            EAPIEndpoint(
                "/eapi/playlist/update/privacy",
                signing: "/api/playlist/update/privacy"
            ),
            payload: ["id": playlistID, "privacy": 0],
            expectedCredentialRevision: expectedCredentialRevision
        )
    }

    func addSongs(
        _ songIDs: [Int64],
        to playlistID: Int64,
        expectedCredentialRevision: UInt64
    ) async throws {
        try await manipulateSongs(
            songIDs,
            playlistID: playlistID,
            operation: "add",
            expectedCredentialRevision: expectedCredentialRevision
        )
    }

    func removeSongs(
        _ songIDs: [Int64],
        from playlistID: Int64,
        expectedCredentialRevision: UInt64
    ) async throws {
        try await manipulateSongs(
            songIDs,
            playlistID: playlistID,
            operation: "del",
            expectedCredentialRevision: expectedCredentialRevision
        )
    }

    func commentCount(songID: Int64) async throws -> MusicCommentCount {
        guard songID > 0 else { throw EAPIError.invalidPayload }
        let root = try await call(
            EAPIEndpoint(
                "/eapi/resource/commentInfo/list",
                signing: "/api/resource/commentInfo/list",
                host: "https://interface.music.163.com"
            ),
            payload: [
                "resourceType": "4",
                "resourceIds": try jsonString([String(songID)])
            ],
            cache: .comments
        )
        guard let count = MusicLibraryDecoder.commentCount(root, songID: songID) else {
            throw EAPIError.missingData("commentCount")
        }
        return count
    }

    func commentEmojiPictureIDs() async throws -> [String: String] {
        let root = try await call(
            EAPIEndpoint(
                "/eapi/social/emoji/bff/home/all",
                signing: "/api/social/emoji/bff/home/all",
                host: Self.interfaceHost
            ),
            payload: ["os": "Android", "e_r": true],
            cache: .detail
        )
        return MusicLibraryDecoder.commentEmojiPictureIDs(root)
    }

    func comments(
        songID: Int64,
        cursor: String = "0",
        pageNumber: Int = 1,
        pageSize: Int = 20,
        sortType: Int = 0
    ) async throws -> MusicCommentPage {
        guard songID > 0, pageNumber > 0, pageSize > 0 else { throw EAPIError.invalidPayload }
        let key = "/api/v2/resource/comments"
        let nested = try jsonString([
            "cursor": cursor,
            "pageNo": String(pageNumber),
            "scene": "SONG_COMMENT",
            "pageSize": String(pageSize),
            "preloadExpGroupName": "t1",
            "sortType": String(sortType),
            "showInner": "0",
            "threadId": try CommentResource.song(songID).threadID()
        ])
        let root = try await call(
            EAPIEndpoint("/eapi/batch", signing: "/batch", host: Self.interfaceHost),
            payload: [key: nested, "os": "iOS", "verifyId": 1, "e_r": true],
            cache: .comments
        )
        let response = try nestedObject(root[key])
        try requireSuccess(response)
        return MusicLibraryDecoder.commentPage(response, songID: songID)
    }

    func commentFloor(
        songID: Int64,
        parentCommentID: Int64,
        time: Int64 = -1,
        cursor: String = "",
        limit: Int = 20
    ) async throws -> MusicCommentFloorPage {
        guard songID > 0, parentCommentID > 0, limit > 0 else { throw EAPIError.invalidPayload }
        let root = try await call(
            EAPIEndpoint(
                "/eapi/v2/resource/comment/floor/get",
                signing: "/api/v2/resource/comment/floor/get",
                host: Self.interfaceHost
            ),
            payload: [
                "source": "",
                "threadId": "R_SO_4_\(songID)",
                "parentCommentId": String(parentCommentID),
                "limit": limit,
                "order": 0,
                "scene": "SONG_COMMENT",
                "time": time,
                "verifyId": 1,
                "os": "iOS",
                "cursor": cursor,
                "e_r": true
            ],
            cache: .comments
        )
        return MusicLibraryDecoder.commentFloorPage(
            root,
            songID: songID,
            parentCommentID: parentCommentID
        )
    }

    func addComment(
        songID: Int64,
        content: String,
        expectedCredentialRevision: UInt64
    ) async throws -> MusicComment? {
        try await writeComment(
            songID: songID,
            action: "add",
            content: content,
            expectedCredentialRevision: expectedCredentialRevision
        )
    }

    func replyToComment(
        songID: Int64,
        commentID: Int64,
        content: String,
        expectedCredentialRevision: UInt64
    ) async throws -> MusicComment? {
        try await writeComment(
            songID: songID,
            action: "reply",
            commentID: commentID,
            content: content,
            expectedCredentialRevision: expectedCredentialRevision
        )
    }

    func deleteComment(
        songID: Int64,
        commentID: Int64,
        expectedCredentialRevision: UInt64
    ) async throws {
        _ = try await writeComment(
            songID: songID,
            action: "delete",
            commentID: commentID,
            expectedCredentialRevision: expectedCredentialRevision
        )
    }

    func setCommentLiked(
        songID: Int64,
        commentID: Int64,
        liked: Bool,
        expectedCredentialRevision: UInt64
    ) async throws {
        guard songID > 0, commentID > 0 else { throw EAPIError.invalidPayload }
        _ = try await transport.requestCommentLike(
            threadID: "R_SO_4_\(songID)",
            commentID: commentID,
            liked: liked,
            expectedCredentialRevision: expectedCredentialRevision
        )
    }

    func similarSongs(to songID: Int64) async throws -> [Song] {
        guard songID > 0 else { throw EAPIError.invalidPayload }
        let root = try await transport.requestWEAPIJSONObject(
            path: "/weapi/v1/discovery/simiSong",
            payload: ["songid": songID, "limit": 50, "offset": 0],
            cache: .library,
            invalidatesAccountCache: false
        )
        return root.array("songs").compactMap(songDecoder.decodeLiveSong)
    }

    func similarPlaylists(to playlistID: Int64) async throws -> [MusicLibraryPlaylist] {
        guard playlistID > 0 else { throw EAPIError.invalidPayload }
        let root = try await call(
            EAPIEndpoint(
                "/eapi/playlist/detail/rcmd/get",
                signing: "/api/playlist/detail/rcmd/get",
                host: Self.interfaceHost
            ),
            payload: [
                "playlistId": playlistID,
                "e_r": true,
                "verifyId": 1,
                "newStyle": true,
                "scene": "playlist_tail"
            ]
        )
        return root.object("data").array("recPlaylist").compactMap(MusicLibraryDecoder.playlist)
    }

    func similarArtists(
        to artistID: Int64,
        expectedCredentialRevision: UInt64
    ) async throws -> [MusicLibraryArtist] {
        guard artistID > 0 else { throw EAPIError.invalidPayload }
        let root = try await call(
            EAPIEndpoint(
                "/eapi/v1/similar/artist/get",
                signing: "/api/v1/similar/artist/get",
                host: Self.interfaceHost
            ),
            payload: ["id": String(artistID), "verifyId": 1, "e_r": true],
            expectedCredentialRevision: expectedCredentialRevision
        )
        return root.array("artists").compactMap(MusicLibraryDecoder.artist)
    }

    func myFollowing(
        size: Int? = nil,
        forceRefresh: Bool = false,
        expectedCredentialRevision: UInt64,
        onUpdate: (@MainActor @Sendable ([MusicLibraryFollow]) -> Void)? = nil
    ) async throws -> [MusicLibraryFollow] {
        guard size.map({ $0 > 0 }) ?? true else { throw EAPIError.invalidPayload }
        let endpoint = EAPIEndpoint(
            "/eapi/user/follow/users/mixed/get/v2",
            signing: "/api/user/follow/users/mixed/get/v2",
            host: Self.interfaceHost
        )
        var cursor = ""
        var consumed = 0
        var seenCursors = Set<String>()
        var seen = Set<String>()
        var values: [MusicLibraryFollow] = []
        while size.map({ consumed < $0 }) ?? true {
            let pageSize = min(100, size.map { $0 - consumed } ?? 100)
            var page: [String: Any] = ["size": String(pageSize)]
            if !cursor.isEmpty { page["cursor"] = cursor }
            let root = try await call(
                endpoint,
                payload: [
                    "scene": 0,
                    "authority": true,
                    "page": try jsonString(page),
                    "e_r": true,
                    "verifyId": 1
                ],
                refreshCache: forceRefresh,
                expectedCredentialRevision: expectedCredentialRevision
            )
            try Task.checkCancellation()
            let data = root.object("data")
            let records = Array(data.array("records").prefix(pageSize))
            let decoded = records.compactMap(MusicLibraryDecoder.mixedFollow)
            let added = decoded.filter { seen.insert($0.id).inserted }
            values.append(contentsOf: added)
            if !added.isEmpty { await onUpdate?(values) }
            consumed += records.count
            let nextCursor = data.string("nextCursor").isEmpty
                ? data.string("cursor")
                : data.string("nextCursor")
            let hasMore = data.bool("hasMore") || data.bool("more") || records.count == pageSize
            guard size.map({ consumed < $0 }) ?? true,
                  hasMore, !records.isEmpty, !added.isEmpty, !nextCursor.isEmpty,
                  nextCursor != cursor, seenCursors.insert(nextCursor).inserted
            else { break }
            cursor = nextCursor
        }
        return values
    }

    func followingUsers(
        userID: Int64,
        size: Int? = nil,
        onUpdate: (@MainActor @Sendable ([MusicLibraryUser]) -> Void)? = nil
    ) async throws -> [MusicLibraryUser] {
        guard userID > 0, size.map({ $0 > 0 }) ?? true else { throw EAPIError.invalidPayload }
        let endpoint = EAPIEndpoint(
            "/eapi/user/v3/follows/get",
            signing: "/api/user/v3/follows/get",
            host: Self.interfaceHost
        )
        var cursor = ""
        var consumed = 0
        var seenCursors = Set<String>()
        var seen = Set<Int64>()
        var values: [MusicLibraryUser] = []
        while size.map({ consumed < $0 }) ?? true {
            let pageSize = min(100, size.map { $0 - consumed } ?? 100)
            let root = try await call(
                endpoint,
                payload: [
                    "page": try jsonString(["size": String(pageSize), "cursor": cursor]),
                    "userId": String(userID),
                    "verifyId": 1,
                    "e_r": true
                ]
            )
            try Task.checkCancellation()
            let data = root.object("data")
            let records = Array(data.array("records").prefix(pageSize))
            let decoded = records.compactMap { MusicLibraryDecoder.user($0.object("userProfile")) }
            let added = decoded.filter { seen.insert($0.id).inserted }
            values.append(contentsOf: added)
            if !added.isEmpty { await onUpdate?(values) }
            consumed += records.count
            let nextCursor = data.string("nextCursor").isEmpty
                ? data.string("cursor")
                : data.string("nextCursor")
            let hasMore = data.bool("hasMore") || data.bool("more") || records.count == pageSize
            guard size.map({ consumed < $0 }) ?? true,
                  hasMore, !records.isEmpty, !added.isEmpty, !nextCursor.isEmpty,
                  nextCursor != cursor, seenCursors.insert(nextCursor).inserted
            else { break }
            cursor = nextCursor
        }
        return values
    }

    func followedArtists(
        userID: Int64,
        offset: Int = 0,
        limit: Int? = nil,
        onUpdate: (@MainActor @Sendable ([MusicLibraryArtist]) -> Void)? = nil
    ) async throws -> [MusicLibraryArtist] {
        guard userID > 0, offset >= 0, limit.map({ $0 > 0 }) ?? true else {
            throw EAPIError.invalidPayload
        }
        let endpoint = EAPIEndpoint(
            "/eapi/user/sub/artist/get",
            signing: "/api/user/sub/artist/get",
            host: Self.interfaceHost
        )
        var nextOffset = offset
        var consumed = 0
        var seen = Set<Int64>()
        var values: [MusicLibraryArtist] = []
        while limit.map({ consumed < $0 }) ?? true {
            let pageSize = min(100, limit.map { $0 - consumed } ?? 100)
            let root = try await call(
                endpoint,
                payload: [
                    "offset": String(nextOffset),
                    "limit": String(pageSize),
                    "id": String(userID),
                    "verifyId": 1,
                    "e_r": true
                ]
            )
            try Task.checkCancellation()
            let data = root.object("data")
            let raw = Array(data.array("artists").prefix(pageSize))
            let decoded = raw.compactMap(MusicLibraryDecoder.artist)
            let added = decoded.filter { seen.insert($0.id).inserted }
            values.append(contentsOf: added)
            if !added.isEmpty { await onUpdate?(values) }
            consumed += raw.count
            let candidate = nextOffset + raw.count
            let hasMore = data.bool("hasMore") || root.bool("more") || raw.count == pageSize
            guard limit.map({ consumed < $0 }) ?? true,
                  hasMore, !raw.isEmpty, !added.isEmpty, candidate > nextOffset
            else { break }
            nextOffset = candidate
        }
        return values
    }

    func cloudSongs(
        offset: Int = 0,
        limit: Int = 30,
        forceRefresh: Bool = false,
        expectedCredentialRevision: UInt64
    ) async throws -> CloudSongPage {
        guard offset >= 0, (1...100).contains(limit) else { throw EAPIError.invalidPayload }
        return CloudMusicDecoder.page(
            try await transport.requestWEAPIJSONObject(
                path: "/weapi/v1/cloud/get",
                payload: ["offset": offset, "limit": limit],
                cache: .library,
                refreshCache: forceRefresh,
                expectedCredentialRevision: expectedCredentialRevision,
                invalidatesAccountCache: false
            ),
            offset: offset,
            decodeSong: songDecoder.decodeLiveSong
        )
    }

    func cloudSongDetails(
        ids: [Int64],
        expectedCredentialRevision: UInt64
    ) async throws -> [CloudSong] {
        guard ids.allSatisfy({ $0 > 0 }) else { throw EAPIError.invalidPayload }
        guard !ids.isEmpty else { return [] }

        var songsByID: [Int64: CloudSong] = [:]
        for start in stride(from: 0, to: ids.count, by: 50) {
            try Task.checkCancellation()
            let batch = Array(ids[start..<min(start + 50, ids.count)])
            let root = try await transport.requestCloudSongDetails(
                ids: batch,
                expectedCredentialRevision: expectedCredentialRevision
            )
            for song in CloudMusicDecoder.songs(root, decodeSong: songDecoder.decodeLiveSong) {
                songsByID[song.id] = song
            }
        }
        return ids.compactMap { songsByID[$0] }
    }

    func cloudLyrics(
        userID: Int64,
        songID: Int64,
        expectedCredentialRevision: UInt64
    ) async throws -> SongLyrics {
        guard userID > 0, songID > 0 else { throw EAPIError.invalidPayload }
        let revision = try cloudCredentialRevision(expected: expectedCredentialRevision)
        let root = try await call(
            Self.cloudLyricEndpoint,
            payload: ["userId": userID, "songId": songID, "lv": -1, "kv": -1],
            cache: .lyrics,
            expectedCredentialRevision: revision
        )
        guard root["code"] != nil else { throw EAPIError.invalidResponse }
        let code = root.int("code")
        guard code == 0 || (200..<300).contains(code) else {
            throw EAPIError.service(code: code, message: root.string("message"))
        }
        return CloudMusicDecoder.lyrics(root)
    }

    func cloudDownloadSource(
        userID: Int64,
        songID: Int64,
        expectedCredentialRevision: UInt64
    ) async throws -> CloudDownloadSource {
        guard userID > 0, songID > 0 else { throw EAPIError.invalidPayload }
        let revision = try cloudCredentialRevision(expected: expectedCredentialRevision)
        let root = try await call(
            Self.cloudDownloadEndpoint,
            payload: ["songId": songID],
            cache: nil,
            expectedCredentialRevision: revision
        )
        return try CloudMusicDecoder.downloadSource(root, expectedSongID: songID)
    }

    private func cloudCredentialRevision(expected: UInt64) throws -> UInt64 {
        let snapshot = transport.credentialSnapshotValue()
        guard snapshot.revision == expected else {
            throw CredentialRevisionMismatch(expected: expected, actual: snapshot.revision)
        }
        guard case let .authenticated(credentials) = snapshot.state,
              !credentials.cookie.isEmpty,
              !NeteaseCookieHeader.isGuest(credentials.cookie)
        else {
            throw EAPIError.service(code: 403, message: "只能读取当前账号的云盘歌词")
        }
        return expected
    }

    private var songDecoder: LiveMusicRepository {
        LiveMusicRepository(transport: transport)
    }

    private func recentPlaybackRoot(
        _ kind: RecentPlaybackKind,
        limit: Int,
        forceRefresh: Bool,
        expectedCredentialRevision: UInt64
    ) async throws -> [String: Any] {
        return try await transport.requestRecentPlayback(
            path: kind.recentPlaybackPath,
            limit: limit,
            refreshCache: forceRefresh,
            expectedCredentialRevision: expectedCredentialRevision
        )
    }

    private func recentlyPlayedMedia(
        _ kind: RecentPlaybackKind,
        limit: Int,
        forceRefresh: Bool,
        expectedCredentialRevision: UInt64
    ) async throws -> [RecentMediaSummary] {
        decodeRecentlyPlayedMedia(
            try await recentPlaybackRoot(
                kind,
                limit: limit,
                forceRefresh: forceRefresh,
                expectedCredentialRevision: expectedCredentialRevision
            ),
            kind: kind
        )
    }

    private func decodeRecentResources<Value: Identifiable>(
        _ root: [String: Any],
        kind: RecentPlaybackKind,
        decode: ([String: Any]) -> Value?,
        title: KeyPath<Value, String>
    ) -> [Value] where Value.ID: Hashable {
        var seen = Set<Value.ID>()
        return MusicLibraryDecoder.recentResources(root, kind: kind).compactMap { resource in
            guard let value = decode(resource),
                  !value[keyPath: title].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  seen.insert(value.id).inserted
            else { return nil }
            return value
        }
    }

    private func listeningPayload(
        period: ListeningReportPeriod,
        cursor: ListeningReportCursor?
    ) -> [String: Any] {
        var payload: [String: Any] = ["type": period.rawValue]
        if let cursor { payload["endTime"] = cursor.endTime }
        return payload
    }

    private func manipulateSongs(
        _ songIDs: [Int64],
        playlistID: Int64,
        operation: String,
        expectedCredentialRevision: UInt64
    ) async throws {
        guard playlistID > 0, !songIDs.isEmpty, songIDs.allSatisfy({ $0 > 0 }) else {
            throw EAPIError.invalidPayload
        }
        let pid: Any = operation == "add" ? String(playlistID) : playlistID
        _ = try await mutate(
            EAPIEndpoint(
                "/eapi/v1/playlist/manipulate/tracks",
                signing: "/api/v1/playlist/manipulate/tracks",
                host: Self.interfaceHost
            ),
            payload: [
                "os": "iOS",
                "verifyId": 1,
                "pid": pid,
                "trackIds": try jsonString(songIDs.map(String.init)),
                "op": operation,
                "e_r": true
            ],
            expectedCredentialRevision: expectedCredentialRevision
        )
    }

    private func writeComment(
        songID: Int64,
        action: String,
        commentID: Int64? = nil,
        content: String? = nil,
        expectedCredentialRevision: UInt64
    ) async throws -> MusicComment? {
        let content = content?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard songID > 0,
              action == "delete" || content?.isEmpty == false,
              action == "add" || (commentID ?? 0) > 0
        else { throw EAPIError.invalidPayload }
        var payload: [String: Any] = ["threadId": "R_SO_4_\(songID)"]
        if let commentID { payload["commentId"] = String(commentID) }
        if let content { payload["content"] = content }
        let root = try await mutate(
            EAPIEndpoint(
                "/eapi/resource/comments/\(action)",
                signing: "/api/resource/comments/\(action)",
                host: "https://interface.music.163.com"
            ),
            payload: payload,
            expectedCredentialRevision: expectedCredentialRevision
        )
        return MusicLibraryDecoder.writtenComment(root, songID: songID)
    }

    func invalidateAllCachedResponses() async {
        await transport.invalidateAllCachedResponses()
    }

    func invalidateCachedResponses(in groups: Set<EAPIReadCache>) async {
        await transport.invalidateCachedResponses(in: groups)
    }

    func refreshPlaylistDetail(
        _ playlistID: Int64,
        expectedCredentialRevision: UInt64
    ) async throws {
        guard playlistID > 0 else { throw EAPIError.invalidPayload }
        _ = try await call(
            EAPIEndpoint(
                "/eapi/v6/playlist/detail",
                signing: "/api/v6/playlist/detail",
                host: Self.interfaceHost
            ),
            payload: [
                "id": playlistID,
                "newStyle": "true",
                "verifyId": 1,
                "newDetailPage": true,
                "e_r": true,
                "n": "300",
                "s": "5"
            ],
            cache: .detail,
            refreshCache: true,
            expectedCredentialRevision: expectedCredentialRevision
        )
    }

    private func call(
        _ endpoint: EAPIEndpoint,
        payload: [String: Any],
        cache: EAPIReadCache? = .library,
        refreshCache: Bool = false,
        expectedCredentialRevision: UInt64? = nil,
        includesClientHeader: Bool = false
    ) async throws -> [String: Any] {
        try await call(
            endpoint,
            json: compactJSON(payload),
            cache: cache,
            refreshCache: refreshCache,
            expectedCredentialRevision: expectedCredentialRevision,
            includesClientHeader: includesClientHeader
        )
    }

    private func call(
        _ endpoint: EAPIEndpoint,
        json: Data,
        cache: EAPIReadCache? = .library,
        refreshCache: Bool = false,
        expectedCredentialRevision: UInt64? = nil,
        includesClientHeader: Bool = false
    ) async throws -> [String: Any] {
        try await transport.requestJSONObject(
            endpoint,
            json: json,
            cache: cache,
            refreshCache: refreshCache,
            expectedCredentialRevision: expectedCredentialRevision,
            includesClientHeader: includesClientHeader
        )
    }

    private func mutate(
        _ endpoint: EAPIEndpoint,
        payload: [String: Any],
        expectedCredentialRevision: UInt64,
        invalidatesGroups: Set<EAPIReadCache> = []
    ) async throws -> [String: Any] {
        return try await transport.requestJSONObject(
            endpoint,
            json: compactJSON(payload),
            expectedCredentialRevision: expectedCredentialRevision,
            invalidatesGroups: invalidatesGroups,
            retryable: false
        )
    }

    private func rawObject(_ data: Data) throws -> [String: Any] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw EAPIError.invalidResponse
        }
        return root
    }

    private func nestedObject(_ value: Any?) throws -> [String: Any] {
        if let value = value as? [String: Any] { return value }
        if let value = value as? String, let data = value.data(using: .utf8) {
            return try rawObject(data)
        }
        throw EAPIError.missingData("/api/v2/resource/comments")
    }

    private func requireSuccess(_ root: [String: Any]) throws {
        let code = root.int("code")
        guard (200..<300).contains(code) else {
            throw EAPIError.service(code: code, message: root.string("message"))
        }
    }

    private func jsonString(_ value: Any) throws -> String {
        guard JSONSerialization.isValidJSONObject(value) else { throw EAPIError.invalidPayload }
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        guard let text = String(data: data, encoding: .utf8) else { throw EAPIError.invalidPayload }
        return text
    }
}

private extension RecentPlaybackKind {
    var recentPlaybackPath: String {
        switch self {
        case .song: "/api/play-record/song/list"
        case .album: "/api/play-record/album/list"
        case .playlist: "/api/play-record/playlist/list"
        case .video: "/api/play-record/newvideo/list"
        case .voice: "/api/play-record/voice/list"
        case .podcast: "/api/play-record/djradio/list"
        }
    }
}
