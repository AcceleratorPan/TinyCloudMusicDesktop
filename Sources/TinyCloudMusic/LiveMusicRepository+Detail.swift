import Foundation

extension LiveMusicRepository {
    func detail(for route: Route) async throws -> DetailContent {
        switch route {
        case let .artist(id):
            return try await artistDetail(id: id)
        case let .album(id):
            return try await albumDetail(id: id)
        case let .playlist(id):
            return try await playlistDetail(id: id)
        case let .user(id):
            return try await userDetail(id: id)
        case .home, .search, .cloudMusic, .comments, .similarSongs, .recommendationHistory:
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
        let artistValue = try decodedJSONObject(homepageResponse).object("data").object("artist")
        guard let artist = decodeLiveArtist(artistValue) else {
            throw EAPIError.missingData("data.artist")
        }
        let songs = try decodedJSONObject(hotSongsResponse).array("songs").compactMap(decodeLiveSong)
        return .artist(artist, songs: songs)
    }

    private func albumDetail(id: Int64) async throws -> DetailContent {
        async let albumData = request(
            EAPIEndpoint("/eapi/album/v3/detail", signing: "/api/album/v3/detail"),
            payload: ["id": id, "cache_key": try EAPICodec.albumCacheKey(id: id)],
            cache: .detail
        )
        async let subscription = try? LiveMusicExtras(transport: transport).albumSubscription(albumID: id)
        let (data, subscriptionStatus) = try await (albumData, subscription)
        let root = try decodedJSONObject(data)
        guard var album = decodeLiveAlbum(root.object("album")) else {
            throw EAPIError.missingData("album")
        }
        if let subscriptionStatus {
            album.isSubscribed = subscriptionStatus.isSubscribed
            album.subscriberCount = subscriptionStatus.subscriberCount
        }
        return .album(album, songs: root.array("songs").compactMap(decodeLiveSong))
    }

    private func playlistDetail(id: Int64) async throws -> DetailContent {
        let data = try await request(
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
                "n": "300",
                "s": "5"
            ],
            cache: .detail
        )
        let value = try decodedJSONObject(data).object("playlist")
        guard let playlist = decodeLivePlaylist(value) else {
            throw EAPIError.missingData("playlist")
        }

        let embeddedSongs = value.array("tracks").compactMap(decodeLiveSong)
        let listedTrackIDs = value.array("trackIds").map { $0.int64("id") }.filter { $0 != 0 }
        let trackIDs = listedTrackIDs.isEmpty ? embeddedSongs.map(\.id) : listedTrackIDs
        let initialRange = PlaylistSongPaging.initialRange(total: trackIDs.count)
        let songs = listedTrackIDs.isEmpty
            ? Array(embeddedSongs.prefix(initialRange.count))
            : try await songs(ids: Array(trackIDs[initialRange]))
        return .playlist(
            playlist,
            songs: songs,
            trackIDs: trackIDs,
            loadedTrackCount: initialRange.count
        )
    }

    private func userDetail(id: Int64) async throws -> DetailContent {
        async let profileData = request(
            EAPIEndpoint("/eapi/v1/user/detail", signing: "/api/v1/user/detail/\(id)"),
            payload: [:],
            cache: .detail
        )
        async let playlistsData = request(
            EAPIEndpoint("/eapi/user/playlist", signing: "/api/user/playlist"),
            payload: ["uid": id, "offset": 0, "limit": 1_000],
            cache: .detail
        )
        let (profileResponse, playlistsResponse) = try await (profileData, playlistsData)
        guard let profile = decodeLiveUserDetail(try decodedJSONObject(profileResponse)) else {
            throw EAPIError.missingData("profile")
        }
        let playlists = try decodedJSONObject(playlistsResponse).array("playlist").compactMap(decodeLivePlaylist)
        return .user(profile, playlists: playlists)
    }

    func songs(ids: [Int64]) async throws -> [Song] {
        var songs: [Song] = []
        for start in stride(from: 0, to: ids.count, by: 100) {
            try Task.checkCancellation()
            let block = ids[start..<min(start + 100, ids.count)]
            let c = "[" + block.map { "{\"id\":\($0)}" }.joined(separator: ",") + "]"
            let data = try await request(
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
                cache: .detail
            )
            let page = try decodedJSONObject(data).array("songs").compactMap(decodeLiveSong)
            let songsByID = Dictionary(page.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            songs += block.compactMap { songsByID[$0] }
        }
        return songs
    }
}
