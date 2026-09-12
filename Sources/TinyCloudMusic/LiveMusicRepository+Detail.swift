import Foundation

extension LiveMusicRepository {
    func detail(
        for route: Route,
        expectedCredentialRevision: UInt64?
    ) async throws -> DetailContent {
        try await detail(
            for: route,
            expectedCredentialRevision: expectedCredentialRevision,
            forceRefresh: false
        )
    }

    func detail(
        for route: Route,
        expectedCredentialRevision: UInt64?,
        forceRefresh: Bool
    ) async throws -> DetailContent {
        switch route {
        case let .artist(id):
            return try await artistDetail(id: id)
        case let .album(id):
            return try await albumDetail(
                id: id,
                expectedCredentialRevision: expectedCredentialRevision
            )
        case let .playlist(id):
            return try await playlistDetail(
                id: id,
                expectedCredentialRevision: expectedCredentialRevision,
                forceRefresh: forceRefresh
            )
        case let .user(id):
            return try await userDetail(
                id: id,
                expectedCredentialRevision: expectedCredentialRevision
            )
        case .home, .search, .cloudMusic, .comments, .similarSongs, .recommendationHistory, .listeningFootprints,
             .mv, .video, .podcast, .podcastEpisode, .broadcast, .podcastSubscriptions,
             .musicStyles, .musicStyle:
            throw AppError.invalidRoute
        }
    }

    private func artistDetail(id: Int64) async throws -> DetailContent {
        async let homepageData = request(
            EAPIEndpoint(
                "/eapi/artist/head/info/get",
                signing: "/api/artist/head/info/get",
                host: "https://interface3.music.163.com"
            ),
            payload: ["id": String(id), "e_r": true, "verifyId": 1],
            cache: .detail
        )
        async let hotSongsData = request(
            EAPIEndpoint(
                "/eapi/v1/artist/top/song",
                signing: "/api/v1/artist/top/song",
                host: "https://interface3.music.163.com"
            ),
            payload: [
                "id": String(id),
                "order": "hot",
                "top": 50,
                "e_r": true,
                "verifyId": 1,
                "work_type": "5"
            ],
            cache: .detail
        )
        let (homepageResponse, hotSongsResponse) = try await (homepageData, hotSongsData)
        let artistValue = homepageResponse.object("data").object("artist")
        guard let artist = decodeLiveArtist(artistValue) else {
            throw EAPIError.missingData("data.artist")
        }
        let songs = hotSongsResponse.array("songs").compactMap(decodeLiveSong)
        return .artist(artist, songs: songs)
    }

    private func albumDetail(
        id: Int64,
        expectedCredentialRevision: UInt64?
    ) async throws -> DetailContent {
        async let albumData = request(
            EAPIEndpoint("/eapi/album/v3/detail", signing: "/api/album/v3/detail"),
            payload: ["id": id, "cache_key": try EAPICodec.albumCacheKey(id: id)],
            cache: .detail,
            expectedCredentialRevision: expectedCredentialRevision
        )
        async let subscription: MusicAlbumSubscription? = if let expectedCredentialRevision {
            try? await LiveMusicExtras(transport: transport).albumSubscription(
                albumID: id,
                expectedCredentialRevision: expectedCredentialRevision
            )
        } else {
            nil
        }
        let (root, subscriptionStatus) = try await (albumData, subscription)
        guard var album = decodeLiveAlbum(root.object("album")) else {
            throw EAPIError.missingData("album")
        }
        if let subscriptionStatus {
            album.isSubscribed = subscriptionStatus.isSubscribed
            album.subscriberCount = subscriptionStatus.subscriberCount
        }
        return .album(album, songs: root.array("songs").compactMap(decodeLiveSong))
    }

    private func playlistDetail(
        id: Int64,
        expectedCredentialRevision: UInt64?,
        forceRefresh: Bool
    ) async throws -> DetailContent {
        let root = try await request(
            EAPIEndpoint(
                "/eapi/v6/playlist/detail",
                signing: "/api/v6/playlist/detail",
                host: "https://interface3.music.163.com"
            ),
            payload: [
                "id": id,
                "newStyle": "true",
                "verifyId": 1,
                "newDetailPage": true,
                "e_r": true,
                "n": String(PlaylistSongPaging.initialCount),
                "s": "5"
            ],
            cache: .detail,
            refreshCache: forceRefresh,
            expectedCredentialRevision: expectedCredentialRevision
        )
        let value = root.object("playlist")
        guard let playlist = decodeLivePlaylist(value) else {
            throw EAPIError.missingData("playlist")
        }

        let embeddedSongs = value.array("tracks").compactMap(decodeLiveSong)
        let listedTrackIDs = value.array("trackIds").map { $0.int64("id") }.filter { $0 != 0 }
        let trackIDs = listedTrackIDs.isEmpty ? embeddedSongs.map(\.id) : listedTrackIDs
        let initialRange = PlaylistSongPaging.initialRange(total: trackIDs.count)
        let initialIDs = Array(trackIDs[initialRange])
        var songsByID = Dictionary(embeddedSongs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let missingIDs = initialIDs.filter { songsByID[$0] == nil }
        if !missingIDs.isEmpty {
            for song in try await songs(
                ids: missingIDs,
                expectedCredentialRevision: expectedCredentialRevision
            ) {
                songsByID[song.id] = song
            }
        }
        let songs = initialIDs.compactMap { songsByID[$0] }
        return .playlist(
            playlist,
            songs: songs,
            trackIDs: trackIDs,
            loadedTrackCount: initialRange.count
        )
    }

    private func userDetail(
        id: Int64,
        expectedCredentialRevision: UInt64?
    ) async throws -> DetailContent {
        async let profileData = request(
            EAPIEndpoint("/eapi/v1/user/detail", signing: "/api/v1/user/detail/\(id)"),
            payload: [:],
            cache: .detail,
            expectedCredentialRevision: expectedCredentialRevision
        )
        async let playlistsTask = userPlaylists(
            id: id,
            expectedCredentialRevision: expectedCredentialRevision
        )
        let (profileResponse, playlistPage) = try await (profileData, playlistsTask)
        guard let profile = decodeLiveUserDetail(profileResponse) else {
            throw EAPIError.missingData("profile")
        }
        return .user(
            profile,
            playlists: playlistPage.playlists,
            hasMore: playlistPage.hasMore
        )
    }

    private func userPlaylists(
        id: Int64,
        expectedCredentialRevision: UInt64?
    ) async throws -> (playlists: [Playlist], hasMore: Bool) {
#if os(iOS)
        let pageSize = 50
#else
        let pageSize = 100
#endif
        var offset = 0
        var playlists: [Playlist] = []
        var seen = Set<Int64>()
        var hasMore = false

        while true {
            try Task.checkCancellation()
            let root = try await request(
                EAPIEndpoint("/eapi/user/playlist", signing: "/api/user/playlist"),
                payload: ["uid": id, "offset": offset, "limit": pageSize],
                cache: .detail,
                expectedCredentialRevision: expectedCredentialRevision
            )
            let values = root.array("playlist")
            guard !values.isEmpty else { break }

            let count = playlists.count
            for playlist in values.compactMap(decodeLivePlaylist) where seen.insert(playlist.id).inserted {
                playlists.append(playlist)
            }
            guard playlists.count > count else { break }

            let (nextOffset, overflow) = offset.addingReportingOverflow(values.count)
            guard !overflow, nextOffset > offset else { break }
            hasMore = root["more"] != nil
                ? root.bool("more")
                : root["hasMore"] != nil ? root.bool("hasMore") : values.count == pageSize
#if os(iOS)
            break
#else
            guard hasMore else { break }
            offset = nextOffset
#endif
        }
        return (playlists, hasMore)
    }

    func songs(ids: [Int64]) async throws -> [Song] {
        try await songs(ids: ids, expectedCredentialRevision: nil)
    }

    private func songs(
        ids: [Int64],
        expectedCredentialRevision: UInt64?
    ) async throws -> [Song] {
        var songs: [Song] = []
        for start in stride(from: 0, to: ids.count, by: 100) {
            try Task.checkCancellation()
            let block = ids[start..<min(start + 100, ids.count)]
            let c = "[" + block.map { "{\"id\":\($0)}" }.joined(separator: ",") + "]"
            let root = try await request(
                EAPIEndpoint(
                    "/eapi/v3/song/detail",
                    signing: "/api/v3/song/detail",
                    host: "https://interface3.music.163.com"
                ),
                payload: [
                    "trialMode": 12,
                    "e_r": true,
                    "verifyId": 1,
                    "source": "",
                    "c": c
                ],
                cache: .detail,
                expectedCredentialRevision: expectedCredentialRevision
            )
            let page = root.array("songs").compactMap(decodeLiveSong)
            let songsByID = Dictionary(page.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            songs += block.compactMap { songsByID[$0] }
        }
        return songs
    }
}
