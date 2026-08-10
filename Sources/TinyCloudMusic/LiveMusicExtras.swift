import Foundation

struct LiveMusicExtras: Sendable {
    private static let interfaceHost = "https://interface3.music.163.com"
    let transport: EAPITransport

    init(transport: EAPITransport = EAPITransport()) {
        self.transport = transport
    }

    func defaultSearchKeywords(limit: Int = 6) async throws -> [MusicSearchKeyword] {
        guard limit > 0 else { throw EAPIError.invalidPayload }
        let root = try await call(
            EAPIEndpoint(
                "/eapi/search/default/keyword/list",
                signing: "/api/search/default/keyword/list",
                host: Self.interfaceHost
            ),
            payload: ["limit": limit, "positionCode": "homepage_default_word", "e_r": true],
            cache: .searchHints
        )
        return MusicExtraDecoder.searchKeywords(root)
    }

    func searchSuggestions(for keyword: String) async throws -> [MusicSearchSuggestion] {
        guard !keyword.isEmpty else { return [] }
        let root = try await call(
            EAPIEndpoint(
                "/eapi/search/suggest/keyword/get",
                signing: "/api/search/suggest/keyword/get",
                host: Self.interfaceHost
            ),
            payload: [
                "keyword": keyword,
                "e_r": true,
                "verifyId": 1,
                "header": [String: Any]()
            ],
            cache: .searchHints
        )
        return MusicExtraDecoder.searchSuggestions(root)
    }

    func hotSearch() async throws -> [HotSearchItem] {
        let root = try await call(
            EAPIEndpoint(
                "/eapi/hotsearchlist/get",
                signing: "/api/hotsearchlist/get",
                host: Self.interfaceHost
            ),
            payload: [:],
            cache: .searchHints
        )
        return MusicExtraDecoder.hotSearch(root)
    }

    func searchDirectMatches(for keyword: String) async throws -> [SearchDirectMatch] {
        guard !keyword.isEmpty else { return [] }
        let root = try await call(
            EAPIEndpoint(
                "/eapi/search/suggest/multimatch",
                signing: "/api/search/suggest/multimatch",
                host: Self.interfaceHost
            ),
            payload: ["type": 1, "s": keyword],
            cache: .searchHints
        )
        return MusicExtraDecoder.searchDirectMatches(root, repository: repository)
    }

    func userPlaylists(
        userID: Int64,
        offset: Int = 0,
        limit: Int = 20,
        expectedCredentialRevision: UInt64? = nil
    ) async throws -> MusicPlaylistPage {
        guard userID > 0, offset >= 0, limit > 0 else { throw EAPIError.invalidPayload }
        let root = try await userPlaylistResponse(
            userID: userID,
            offset: offset,
            limit: limit,
            expectedCredentialRevision: expectedCredentialRevision
        )
        return MusicPlaylistPage(
            playlists: root.array("playlist").compactMap(repository.decodeLivePlaylist),
            offset: offset,
            hasMore: root.bool("more")
        )
    }

    func favoriteSongIDs(
        userID: Int64,
        expectedCredentialRevision: UInt64
    ) async throws -> [Int64] {
        guard userID > 0 else { throw EAPIError.invalidPayload }
        let playlists = try await LiveMusicLibrary(transport: transport).userPlaylists(
            userID: userID,
            expectedCredentialRevision: expectedCredentialRevision
        )
        return try await favoriteSongIDs(
            userID: userID,
            playlists: playlists,
            expectedCredentialRevision: expectedCredentialRevision
        )
    }

    func favoriteSongIDs(
        userID: Int64,
        playlists: [Playlist],
        expectedCredentialRevision: UInt64
    ) async throws -> [Int64] {
        guard userID > 0 else { throw EAPIError.invalidPayload }
        guard let favoriteID = playlists.first(where: { $0.specialType == 5 })?.id else { return [] }

        let root = try await call(
            EAPIEndpoint(
                "/eapi/v6/playlist/detail",
                signing: "/api/v6/playlist/detail",
                host: Self.interfaceHost
            ),
            payload: [
                "id": favoriteID,
                "newStyle": "true",
                "verifyId": 1,
                "newDetailPage": true,
                "e_r": true,
                "n": "300",
                "s": "5"
            ],
            cache: .playlistSummaries,
            expectedCredentialRevision: expectedCredentialRevision
        )
        return MusicExtraDecoder.trackIDs(root.object("playlist"))
    }

    func artistAlbums(
        artistID: Int64,
        offset: Int = 0,
        limit: Int = 20,
        expectedCredentialRevision: UInt64
    ) async throws -> MusicArtistAlbumPage {
        guard artistID > 0, offset >= 0, limit > 0 else { throw EAPIError.invalidPayload }
        let root = try await call(
            EAPIEndpoint(
                "/eapi/artist/albums/\(artistID)",
                signing: "/api/artist/albums/\(artistID)",
                host: Self.interfaceHost
            ),
            payload: ["offset": offset, "limit": String(limit), "verifyId": 1, "e_r": true],
            expectedCredentialRevision: expectedCredentialRevision
        )
        let albums = root.array("hotAlbums").compactMap { value -> MusicArtistAlbum? in
            guard let album = repository.decodeLiveAlbum(value) else { return nil }
            return MusicArtistAlbum(album: album, isSubscribed: value.bool("isSub"))
        }
        return MusicArtistAlbumPage(albums: albums, offset: offset, hasMore: root.bool("more"))
    }

    func artistSongs(
        artistID: Int64,
        offset: Int = 0,
        limit: Int = 100,
        expectedCredentialRevision: UInt64
    ) async throws -> MusicArtistSongPage {
        guard artistID > 0, offset >= 0, (1...100).contains(limit) else { throw EAPIError.invalidPayload }
        let root = try await call(
            EAPIEndpoint(
                "/eapi/v1/artist/songs",
                signing: "/api/v1/artist/songs",
                host: Self.interfaceHost
            ),
            payload: [
                "id": artistID,
                "private_cloud": "true",
                "work_type": 1,
                "order": "hot",
                "offset": offset,
                "limit": limit
            ],
            expectedCredentialRevision: expectedCredentialRevision
        )
        return MusicArtistSongPage(
            songs: root.array("songs").compactMap(repository.decodeLiveSong),
            offset: offset,
            hasMore: root.bool("more"),
            total: root.keys.contains("total") ? root.int("total") : nil
        )
    }

    func albumSubscription(
        albumID: Int64,
        expectedCredentialRevision: UInt64
    ) async throws -> MusicAlbumSubscription {
        guard albumID > 0 else { throw EAPIError.invalidPayload }
        let root = try await call(
            EAPIEndpoint(
                "/eapi/album/detail/dynamic",
                signing: "/api/album/detail/dynamic",
                host: Self.interfaceHost
            ),
            payload: ["id": String(albumID), "e_r": true, "verifyId": 1],
            expectedCredentialRevision: expectedCredentialRevision
        )
        return MusicExtraDecoder.albumSubscription(root)
    }

    func artistFollowStatus(
        artistID: Int64,
        expectedCredentialRevision: UInt64
    ) async throws -> MusicArtistFollowStatus {
        guard artistID > 0 else { throw EAPIError.invalidPayload }
        let root = try await call(
            EAPIEndpoint(
                "/eapi/artist/follow/count/get",
                signing: "/api/artist/follow/count/get",
                host: Self.interfaceHost
            ),
            payload: ["id": String(artistID), "verifyId": 1, "e_r": true],
            expectedCredentialRevision: expectedCredentialRevision
        )
        return MusicExtraDecoder.artistFollowStatus(root)
    }

    func availablePlaylists(
        userID: Int64,
        trackID: Int64,
        offset: Int = 0,
        expectedCredentialRevision: UInt64
    ) async throws -> MusicAvailablePlaylistPage {
        guard userID > 0, trackID > 0, offset >= 0 else { throw EAPIError.invalidPayload }
        let root = try await call(
            EAPIEndpoint(
                "/eapi/user/playlist/v1s",
                signing: "/api/user/playlist/v1",
                host: Self.interfaceHost
            ),
            payload: [
                "includeShareStatus": true,
                "includeVideo": false,
                "os": "iOS",
                "uid": userID,
                "offset": String(offset),
                "verifyId": 1,
                "trackIds": String(trackID),
                "e_r": true
            ],
            cache: .library,
            expectedCredentialRevision: expectedCredentialRevision
        )
        let raw = root.array("playlist")
        let nextOffset = offset.addingReportingOverflow(raw.count)
        guard !nextOffset.overflow else { throw EAPIError.invalidResponse }
        let playlists = raw.compactMap { value -> MusicAvailablePlaylist? in
            guard let playlist = MusicLibraryDecoder.playlist(value) else { return nil }
            return MusicAvailablePlaylist(playlist: playlist, containsTrack: value.bool("containsTracks"))
        }
        return MusicAvailablePlaylistPage(
            playlists: playlists,
            offset: nextOffset.partialValue,
            hasMore: root.bool("more")
        )
    }

    func recommendedUsers(expectedCredentialRevision: UInt64) async throws -> [MusicRecommendedUser] {
        let root = try await call(
            EAPIEndpoint(
                "/eapi/user/unfollow/recommend/v1",
                signing: "/api/user/unfollow/recommend/v1",
                host: Self.interfaceHost
            ),
            payload: [
                "scene": 1,
                "verifyId": 1,
                "e_r": true,
                "addressPermission": false
            ],
            cache: .library,
            expectedCredentialRevision: expectedCredentialRevision
        )
        return root.array("users").compactMap(MusicExtraDecoder.recommendedUser)
    }

    private var repository: LiveMusicRepository {
        LiveMusicRepository(transport: transport)
    }

    private func userPlaylistResponse(
        userID: Int64,
        offset: Int,
        limit: Int,
        expectedCredentialRevision: UInt64? = nil
    ) async throws -> [String: Any] {
        try await call(
            EAPIEndpoint("/eapi/user/playlist", signing: "/api/user/playlist"),
            payload: ["uid": userID, "offset": offset, "limit": limit],
            cache: .playlistSummaries,
            expectedCredentialRevision: expectedCredentialRevision
        )
    }

    private func call(
        _ endpoint: EAPIEndpoint,
        payload: [String: Any],
        cache: EAPIReadCache = .detail,
        expectedCredentialRevision: UInt64? = nil
    ) async throws -> [String: Any] {
        try await transport.requestJSONObject(
            endpoint,
            json: compactJSON(payload),
            cache: cache,
            expectedCredentialRevision: expectedCredentialRevision
        )
    }
}
