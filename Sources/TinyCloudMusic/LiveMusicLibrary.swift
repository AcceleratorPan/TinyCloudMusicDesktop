import Foundation

struct LiveMusicLibrary: Sendable {
    private static let interfaceHost = "https://interface3.music.163.com"
    private static let eapiHost = "https://interface.music.163.com"
    static let cloudLyricEndpoint = EAPIEndpoint("/eapi/cloud/lyric/get", signing: "/api/cloud/lyric/get")
    static let cloudDownloadEndpoint = EAPIEndpoint("/eapi/cloud/dowonload", signing: "/api/cloud/dowonload")
    let transport: EAPITransport

    init(transport: EAPITransport = EAPITransport()) {
        self.transport = transport
    }

    func loginState() async throws -> MusicLibraryLoginState {
        let endpoint = EAPIEndpoint("/eapi/v1/user/info", signing: "/api/v1/user/info")
        let root = try rawObject(try await transport.request(endpoint, json: Data()))
        guard (200..<300).contains(root.int("code")) else { return .loggedOut }
        let userID = root.object("userPoint").int64("userId")
        guard userID != 0 else { return .loggedOut }

        return .loggedIn(try await userInfo(userID: userID))
    }

    func userInfo(userID: Int64) async throws -> MusicLibraryUser {
        guard userID > 0 else { throw EAPIError.invalidPayload }
        let root = try await call(
            EAPIEndpoint("/eapi/v1/user/detail", signing: "/api/v1/user/detail/\(userID)"),
            json: Data()
        )
        guard let user = MusicLibraryDecoder.user(root.object("profile"), root: root) else {
            throw EAPIError.missingData("profile")
        }
        return user
    }

    func dailyRecommendations() async throws -> [Song] {
        let root = try await call(
            EAPIEndpoint(
                "/api/v3/discovery/recommend/songs",
                signing: "/api/v3/discovery/recommend/songs"
            ),
            json: Data()
        )
        return root.object("data").array("dailySongs").compactMap(songDecoder.decodeLiveSong)
    }

    func userPlaylists(userID: Int64) async throws -> [Playlist] {
        guard userID > 0 else { throw EAPIError.invalidPayload }
        let root = try await call(
            EAPIEndpoint("/eapi/user/playlist", signing: "/api/user/playlist"),
            payload: ["uid": userID, "offset": 0, "limit": 1_000],
            cache: .playlistSummaries
        )
        return root.array("playlist").compactMap(songDecoder.decodeLivePlaylist)
    }

    func recommendationHistoryDates() async throws -> [RecommendationHistoryDate] {
        decodeRecommendationHistoryDates(
            try decodedJSONObject(try await transport.requestRecommendationHistory())
        )
    }

    func decodeRecommendationHistoryDates(_ root: [String: Any]) -> [RecommendationHistoryDate] {
        RecommendationMemoryDecoder.historyDates(root)
    }

    func historicalDailyRecommendations(
        on date: RecommendationHistoryDate,
        availableDates: [RecommendationHistoryDate]
    ) async throws -> [Song] {
        guard availableDates.contains(date) else { throw EAPIError.invalidPayload }
        return decodeHistoricalDailyRecommendations(
            try decodedJSONObject(try await transport.requestRecommendationHistory(date: date.value))
        )
    }

    func decodeHistoricalDailyRecommendations(_ root: [String: Any]) -> [Song] {
        root.object("data").array("songs").compactMap(songDecoder.decodeLiveSong)
    }

    func recentlyPlayedSongs(limit: Int = 100) async throws -> [Song] {
        decodeRecentlyPlayedSongs(try await recentPlaybackRoot(.song, limit: limit))
    }

    func decodeRecentlyPlayedSongs(_ root: [String: Any]) -> [Song] {
        decodeRecentResources(root, kind: .song, decode: songDecoder.decodeLiveSong, title: \.name)
    }

    func recentlyPlayedAlbums(limit: Int = 100) async throws -> [Album] {
        decodeRecentlyPlayedAlbums(try await recentPlaybackRoot(.album, limit: limit))
    }

    func decodeRecentlyPlayedAlbums(_ root: [String: Any]) -> [Album] {
        decodeRecentResources(root, kind: .album, decode: songDecoder.decodeLiveAlbum, title: \.name)
    }

    func recentlyPlayedPlaylists(limit: Int = 100) async throws -> [Playlist] {
        decodeRecentlyPlayedPlaylists(try await recentPlaybackRoot(.playlist, limit: limit))
    }

    func decodeRecentlyPlayedPlaylists(_ root: [String: Any]) -> [Playlist] {
        decodeRecentResources(root, kind: .playlist, decode: songDecoder.decodeLivePlaylist, title: \.name)
    }

    func recentlyPlayedVideos(limit: Int = 100) async throws -> [RecentMediaSummary] {
        try await recentlyPlayedMedia(.video, limit: limit)
    }

    func recentlyPlayedVoices(limit: Int = 100) async throws -> [RecentMediaSummary] {
        try await recentlyPlayedMedia(.voice, limit: limit)
    }

    func recentlyPlayedPodcasts(limit: Int = 100) async throws -> [RecentMediaSummary] {
        try await recentlyPlayedMedia(.podcast, limit: limit)
    }

    func decodeRecentlyPlayedMedia(
        _ root: [String: Any],
        kind: RecentPlaybackKind
    ) -> [RecentMediaSummary] {
        MusicLibraryDecoder.recentMedia(root, kind: kind)
    }

    func listeningRecords(userID: Int64, period: MusicListeningPeriod) async throws -> [MusicListeningRecord] {
        guard userID > 0 else { throw EAPIError.invalidPayload }
        let root = try await call(
            EAPIEndpoint("/eapi/v1/play/record", signing: "/api/v1/play/record"),
            payload: ["uid": String(userID), "type": period.rawValue]
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

    func totalListeningDuration() async throws -> Int64 {
        // This endpoint rejects the VIP requester and must use the account's original cookie.
        let root = try await call(
            EAPIEndpoint(
                "/eapi/content/activity/listen/data/total",
                signing: "/api/content/activity/listen/data/total"
            ),
            payload: [:],
            cache: nil
        )
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

    func personalFM(mode: PersonalFMMode, limit: Int = 3) async throws -> [PersonalFMTrack] {
        guard (1...10).contains(limit) else { throw EAPIError.invalidPayload }
        let values = mode.requestValues
        let root = try await call(
            EAPIEndpoint(
                "/eapi/v1/radio/get",
                signing: "/api/v1/radio/get",
                host: Self.eapiHost
            ),
            payload: ["mode": values.mode, "subMode": values.subMode, "limit": limit],
            cache: nil
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

    func trashPersonalFMTrack(_ track: PersonalFMTrack, playedSeconds: Int) async throws {
        _ = try decodedJSONObject(
            try await transport.requestFMTrash(
                songID: track.id,
                algorithm: track.algorithm,
                playedSeconds: max(1, playedSeconds)
            )
        )
    }

    func hasActiveVIP() async throws -> Bool {
        let root = try decodedJSONObject(
            try await transport.request(
                EAPIEndpoint(
                    "/eapi/music-vip-membership/client/vip/info",
                    signing: "/api/music-vip-membership/client/vip/info",
                    host: Self.interfaceHost
                ),
                json: compactJSON(["verifyId": 1, "e_r": true, "os": "iOS"]),
                vip: true
            )
        )
        let data = root.object("data")
        return data.int64("now") < data.object("musicPackage").int64("expireTime")
    }

    func setSongLiked(_ songID: Int64, liked: Bool) async throws {
        guard songID > 0 else { throw EAPIError.invalidPayload }
        _ = try await mutate(
            EAPIEndpoint("/eapi/song/like", signing: "/api/song/like"),
            payload: ["trackId": songID, "like": liked]
        )
    }

    func setPlaylistSubscribed(_ playlistID: Int64, subscribed: Bool) async throws {
        guard playlistID > 0 else { throw EAPIError.invalidPayload }
        let action = subscribed ? "subscribe" : "unsubscribe"
        _ = try await mutate(
            EAPIEndpoint(
                "/eapi/playlist/\(action)",
                signing: "/api/playlist/\(action)",
                host: Self.interfaceHost
            ),
            payload: ["id": playlistID, "e_r": true, "verifyId": 1]
        )
    }

    func setAlbumSubscribed(_ albumID: Int64, subscribed: Bool) async throws {
        guard albumID > 0 else { throw EAPIError.invalidPayload }
        let action = subscribed ? "sub" : "unsub"
        _ = try await mutate(
            EAPIEndpoint(
                "/eapi/album/\(action)",
                signing: "/api/album/\(action)",
                host: Self.interfaceHost
            ),
            payload: ["id": String(albumID), "e_r": true, "verifyId": 1]
        )
    }

    func setArtistFollowed(_ artistID: Int64, followed: Bool) async throws {
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
        _ = try await mutate(endpoint, payload: payload)
    }

    func setUserFollowed(_ userID: Int64, followed: Bool) async throws {
        guard userID > 0 else { throw EAPIError.invalidPayload }
        let action = followed ? "follow" : "delfollow"
        _ = try await mutate(
            EAPIEndpoint(
                "/eapi/user/\(action)/\(userID)",
                signing: "/api/user/\(action)/\(userID)",
                host: Self.interfaceHost
            ),
            payload: ["verifyId": 1, "e_r": true]
        )
    }

    func createPlaylist(name: String, privacy: MusicPlaylistPrivacy = .publicPlaylist) async throws -> Int64 {
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
            ]
        )
        let id = root.int64("id")
        guard id != 0 else { throw EAPIError.missingData("id") }
        return id
    }

    func deletePlaylist(_ playlistID: Int64) async throws {
        guard playlistID > 0 else { throw EAPIError.invalidPayload }
        _ = try await mutate(
            EAPIEndpoint(
                "/eapi/playlist/delete",
                signing: "/api/playlist/delete",
                host: Self.interfaceHost
            ),
            payload: ["os": "iOS", "verifyId": 1, "pid": playlistID, "e_r": true]
        )
    }

    func updatePlaylistName(_ playlistID: Int64, name: String) async throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard playlistID > 0, !name.isEmpty else { throw EAPIError.invalidPayload }
        _ = try await mutate(
            EAPIEndpoint(
                "/eapi/playlist/update/name",
                signing: "/api/playlist/update/name",
                host: "https://interface.music.163.com"
            ),
            payload: ["id": playlistID, "name": name]
        )
    }

    func updatePlaylistDescription(_ playlistID: Int64, description: String) async throws {
        guard playlistID > 0 else { throw EAPIError.invalidPayload }
        _ = try await mutate(
            EAPIEndpoint(
                "/eapi/playlist/desc/update",
                signing: "/api/playlist/desc/update",
                host: "https://interface.music.163.com"
            ),
            payload: ["id": playlistID, "desc": description]
        )
    }

    func updatePlaylistTags(_ playlistID: Int64, tags: [String]) async throws {
        guard playlistID > 0 else { throw EAPIError.invalidPayload }
        let tags = PlaylistMetadataDraft.normalizeTags(tags)
        _ = try await mutate(
            EAPIEndpoint(
                "/eapi/playlist/tags/update",
                signing: "/api/playlist/tags/update",
                host: "https://interface.music.163.com"
            ),
            payload: ["id": playlistID, "tags": tags.joined(separator: ";")]
        )
    }

    func updatePlaylistCover(
        _ playlistID: Int64,
        cover: ProcessedPlaylistCover
    ) async throws {
        guard playlistID > 0 else { throw EAPIError.invalidPayload }
        try await PlaylistImageUpload(transport: transport).updateCover(
            playlistID: playlistID,
            cover: cover
        )
    }

    func updatePlaylistOrder(_ playlistIDs: [Int64]) async throws {
        guard !playlistIDs.isEmpty,
              playlistIDs.allSatisfy({ $0 > 0 }),
              Set(playlistIDs).count == playlistIDs.count
        else { throw EAPIError.invalidPayload }
        let root = try decodedJSONObject(
            try await transport.requestWEAPI(
                path: "/weapi/playlist/order/update",
                payload: ["ids": try jsonString(playlistIDs.map(String.init))]
            )
        )
        try requireSuccess(root)
    }

    func updatePlaylistSongOrder(_ playlistID: Int64, trackIDs: [Int64]) async throws {
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
            ]
        )
    }

    func makePlaylistPublic(_ playlistID: Int64) async throws {
        guard playlistID > 0 else { throw EAPIError.invalidPayload }
        _ = try await mutate(
            EAPIEndpoint(
                "/eapi/playlist/update/privacy",
                signing: "/api/playlist/update/privacy"
            ),
            payload: ["id": playlistID, "privacy": 0]
        )
    }

    func addSongs(_ songIDs: [Int64], to playlistID: Int64) async throws {
        try await manipulateSongs(songIDs, playlistID: playlistID, operation: "add")
    }

    func removeSongs(_ songIDs: [Int64], from playlistID: Int64) async throws {
        try await manipulateSongs(songIDs, playlistID: playlistID, operation: "del")
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
            "threadId": "R_SO_4_\(songID)"
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

    func addComment(songID: Int64, content: String) async throws -> MusicComment? {
        try await writeComment(songID: songID, action: "add", content: content)
    }

    func replyToComment(songID: Int64, commentID: Int64, content: String) async throws -> MusicComment? {
        try await writeComment(songID: songID, action: "reply", commentID: commentID, content: content)
    }

    func deleteComment(songID: Int64, commentID: Int64) async throws {
        _ = try await writeComment(songID: songID, action: "delete", commentID: commentID)
    }

    func setCommentLiked(songID: Int64, commentID: Int64, liked: Bool) async throws {
        guard songID > 0, commentID > 0 else { throw EAPIError.invalidPayload }
        _ = try decodedJSONObject(
            try await transport.requestCommentLike(
                threadID: "R_SO_4_\(songID)",
                commentID: commentID,
                liked: liked
            )
        )
    }

    func similarSongs(to songID: Int64) async throws -> [Song] {
        guard songID > 0 else { throw EAPIError.invalidPayload }
        let root = try decodedJSONObject(
            try await transport.requestWEAPI(
                path: "/weapi/v1/discovery/simiSong",
                payload: ["songid": songID, "limit": 50, "offset": 0],
                cache: .library,
                invalidatesAccountCache: false
            )
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

    func similarArtists(to artistID: Int64) async throws -> [MusicLibraryArtist] {
        guard artistID > 0 else { throw EAPIError.invalidPayload }
        let root = try await call(
            EAPIEndpoint(
                "/eapi/v1/similar/artist/get",
                signing: "/api/v1/similar/artist/get",
                host: Self.interfaceHost
            ),
            payload: ["id": String(artistID), "verifyId": 1, "e_r": true]
        )
        return root.array("artists").compactMap(MusicLibraryDecoder.artist)
    }

    func myFollowing(size: Int = 1_000) async throws -> [MusicLibraryFollow] {
        guard size > 0 else { throw EAPIError.invalidPayload }
        let root = try await call(
            EAPIEndpoint(
                "/eapi/user/follow/users/mixed/get/v2",
                signing: "/api/user/follow/users/mixed/get/v2",
                host: Self.interfaceHost
            ),
            payload: [
                "scene": 0,
                "authority": true,
                "page": try jsonString(["size": String(size)]),
                "e_r": true,
                "verifyId": 1
            ]
        )
        return root.object("data").array("records").compactMap(MusicLibraryDecoder.mixedFollow)
    }

    func followingUsers(userID: Int64, size: Int = 1_000) async throws -> [MusicLibraryUser] {
        guard userID > 0, size > 0 else { throw EAPIError.invalidPayload }
        let root = try await call(
            EAPIEndpoint(
                "/eapi/user/v3/follows/get",
                signing: "/api/user/v3/follows/get",
                host: Self.interfaceHost
            ),
            payload: [
                "page": try jsonString(["size": String(size), "cursor": ""]),
                "userId": String(userID),
                "verifyId": 1,
                "e_r": true
            ]
        )
        return root.object("data").array("records").compactMap {
            MusicLibraryDecoder.user($0.object("userProfile"))
        }
    }

    func followedArtists(userID: Int64, offset: Int = 0, limit: Int = 1_000) async throws -> [MusicLibraryArtist] {
        guard userID > 0, offset >= 0, limit > 0 else { throw EAPIError.invalidPayload }
        let root = try await call(
            EAPIEndpoint(
                "/eapi/user/sub/artist/get",
                signing: "/api/user/sub/artist/get",
                host: Self.interfaceHost
            ),
            payload: [
                "offset": String(offset),
                "limit": String(limit),
                "id": String(userID),
                "verifyId": 1,
                "e_r": true
            ]
        )
        return root.object("data").array("artists").compactMap(MusicLibraryDecoder.artist)
    }

    func cloudSongs(offset: Int = 0, limit: Int = 30) async throws -> CloudSongPage {
        guard offset >= 0, (1...100).contains(limit) else { throw EAPIError.invalidPayload }
        return CloudMusicDecoder.page(
            try decodedJSONObject(try await transport.requestCloudSongs(offset: offset, limit: limit)),
            offset: offset,
            decodeSong: songDecoder.decodeLiveSong
        )
    }

    func cloudSongDetails(ids: [Int64]) async throws -> [CloudSong] {
        guard ids.allSatisfy({ $0 > 0 }) else { throw EAPIError.invalidPayload }
        guard !ids.isEmpty else { return [] }

        var songsByID: [Int64: CloudSong] = [:]
        for start in stride(from: 0, to: ids.count, by: 50) {
            try Task.checkCancellation()
            let batch = Array(ids[start..<min(start + 50, ids.count)])
            let root = try decodedJSONObject(try await transport.requestCloudSongDetails(ids: batch))
            for song in CloudMusicDecoder.songs(root, decodeSong: songDecoder.decodeLiveSong) {
                songsByID[song.id] = song
            }
        }
        return ids.compactMap { songsByID[$0] }
    }

    func cloudLyrics(userID: Int64, songID: Int64) async throws -> SongLyrics {
        guard userID > 0, songID > 0 else { throw EAPIError.invalidPayload }
        guard case let .loggedIn(user) = try await loginState(), user.id == userID else {
            throw EAPIError.service(code: 403, message: "只能读取当前账号的云盘歌词")
        }
        let root = try await call(
            Self.cloudLyricEndpoint,
            payload: ["userId": userID, "songId": songID, "lv": -1, "kv": -1],
            cache: .lyrics
        )
        return CloudMusicDecoder.lyrics(root)
    }

    func cloudDownloadSource(songID: Int64) async throws -> CloudDownloadSource {
        guard songID > 0 else { throw EAPIError.invalidPayload }
        let root = try await call(
            Self.cloudDownloadEndpoint,
            payload: ["songId": songID],
            cache: nil
        )
        return try CloudMusicDecoder.downloadSource(root, expectedSongID: songID)
    }

    private var songDecoder: LiveMusicRepository {
        LiveMusicRepository(transport: transport)
    }

    private func recentPlaybackRoot(
        _ kind: RecentPlaybackKind,
        limit: Int
    ) async throws -> [String: Any] {
        try decodedJSONObject(
            try await transport.requestRecentPlayback(
                path: kind.recentPlaybackPath,
                limit: limit
            )
        )
    }

    private func recentlyPlayedMedia(
        _ kind: RecentPlaybackKind,
        limit: Int
    ) async throws -> [RecentMediaSummary] {
        decodeRecentlyPlayedMedia(try await recentPlaybackRoot(kind, limit: limit), kind: kind)
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

    private func manipulateSongs(_ songIDs: [Int64], playlistID: Int64, operation: String) async throws {
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
            ]
        )
    }

    private func writeComment(
        songID: Int64,
        action: String,
        commentID: Int64? = nil,
        content: String? = nil
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
            payload: payload
        )
        return MusicLibraryDecoder.writtenComment(root, songID: songID)
    }

    func invalidateAllCachedResponses() async {
        await transport.invalidateAllCachedResponses()
    }

    func invalidateCachedResponses(in groups: Set<EAPIReadCache>) async {
        await transport.invalidateCachedResponses(in: groups)
    }

    private func call(
        _ endpoint: EAPIEndpoint,
        payload: [String: Any],
        cache: EAPIReadCache? = .library
    ) async throws -> [String: Any] {
        try await call(endpoint, json: compactJSON(payload), cache: cache)
    }

    private func call(
        _ endpoint: EAPIEndpoint,
        json: Data,
        cache: EAPIReadCache? = .library
    ) async throws -> [String: Any] {
        try decodedJSONObject(try await transport.request(endpoint, json: json, cache: cache))
    }

    private func mutate(_ endpoint: EAPIEndpoint, payload: [String: Any]) async throws -> [String: Any] {
        try decodedJSONObject(
            try await transport.request(
                endpoint,
                json: compactJSON(payload),
                invalidatesAccountCache: true
            )
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
