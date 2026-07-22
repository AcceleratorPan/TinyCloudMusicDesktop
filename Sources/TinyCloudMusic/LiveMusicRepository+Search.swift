import Foundation

extension LiveMusicRepository {
    func search(query: String, scope: SearchScope, offset: Int, limit: Int) async throws -> SearchPage {
        let endpoint: EAPIEndpoint
        let payload: [String: Any]

        switch scope {
        case .songs:
            endpoint = EAPIEndpoint(
                "/eapi/search/song/list/page",
                signing: "/api/search/song/list/page",
                host: "https://interface3.music.163.com"
            )
            payload = [
                "keyword": query,
                "needCorrect": "1",
                "scene": "normal",
                "verifyId": 1,
                "offset": offset,
                "limit": limit,
                "e_r": true
            ]
        case .artists, .albums, .playlists, .users:
            let kind = switch scope {
            case .artists: "artist"
            case .albums: "album"
            case .playlists: "playlist"
            case .users: "user"
            case .songs: fatalError("handled above")
            }
            endpoint = EAPIEndpoint(
                "/eapi/v1/search/\(kind)/get",
                signing: "/api/v1/search/\(kind)/get",
                host: "https://interface3.music.163.com"
            )
            payload = [
                "s": query,
                "limit": limit,
                "offset": offset,
                "e_r": true,
                "queryCorrect": true,
                "q_scene": "defaultquery"
            ]
        }

        let root = try decodedJSONObject(try await request(endpoint, payload: payload, cache: .search))
        try Task.checkCancellation()
        return decodeSearchPage(root, scope: scope, offset: offset)
    }

    func decodeSearchPage(_ root: [String: Any], scope: SearchScope, offset: Int) -> SearchPage {
        let result = root.object("result")
        let values: [[String: Any]]
        let items: [SearchItem]
        let countKey: String
        let page: [String: Any]

        switch scope {
        case .songs:
            let data = root.object("data")
            let usesNewResponse = data.keys.contains("resources")
            page = usesNewResponse ? data : result
            values = usesNewResponse ? data.array("resources") : result.array("songs")
            countKey = usesNewResponse ? "totalCount" : "songCount"
            items = values.compactMap { value in
                guard value["resourceType"] == nil || value.string("resourceType") == "song",
                      let song = decodeLiveSong(value)
                else { return nil }
                return .song(song)
            }
        case .artists:
            page = result
            values = result.array("artists")
            countKey = "artistCount"
            items = values.compactMap(decodeLiveArtist).map(SearchItem.artist)
        case .albums:
            page = result
            values = result.array("albums")
            countKey = "albumCount"
            items = values.compactMap(decodeLiveAlbum).map(SearchItem.album)
        case .playlists:
            page = result
            values = result.array("playlists")
            countKey = "playlistCount"
            items = values.compactMap(decodeLivePlaylist).map(SearchItem.playlist)
        case .users:
            page = result
            values = result.array("userprofiles")
            countKey = "userprofileCount"
            items = values.compactMap(decodeLiveUser).map(SearchItem.user)
        }

        let hasMore = page.keys.contains("hasMore")
            ? page.bool("hasMore")
            : offset + values.count < page.int(countKey)
        return SearchPage(items: items, offset: offset, hasMore: hasMore)
    }

    func decodeLiveSong(_ source: [String: Any]) -> Song? {
        decodeSong(source)
    }

    func decodeLiveArtist(_ value: [String: Any]) -> Artist? {
        let id = value.int64("id")
        guard id != 0 else { return nil }
        var name = value.string("name")
        if let translated = nonempty(value.string("trans")) ?? firstText(value["transNames"]) {
            name += "(\(translated))"
        }
        return Artist(
            id: id,
            name: name,
            biography: value.string("briefDesc"),
            artwork: Artwork(
                symbol: "music.mic",
                accent: .red,
                remoteURL: firstURL(value, keys: ["cover", "picUrl", "img1v1Url"])
            ),
            isFollowed: value.bool("followed")
        )
    }

    func decodeLiveAlbum(_ value: [String: Any]) -> Album? {
        let id = value.int64("id")
        let artistValue = !value.object("artist").isEmpty
            ? value.object("artist")
            : (value.array("artists").first ?? [:])
        let artistID = artistValue.int64("id")
        guard id != 0, artistID != 0 else { return nil }
        return Album(
            id: id,
            name: value.string("name"),
            artist: ArtistSummary(id: artistID, name: artistValue.string("name")),
            description: value.string("description"),
            artwork: Artwork(
                symbol: "square.stack",
                accent: .orange,
                remoteURL: firstURL(value, keys: ["picUrl", "blurPicUrl"])
            ),
            isSubscribed: value.bool("isSub"),
            subscriberCount: value.int64("subCount")
        )
    }

    func decodeLivePlaylist(_ value: [String: Any]) -> Playlist? {
        let id = value.int64("id")
        guard id != 0 else { return nil }
        return Playlist(
            id: id,
            name: value.string("name"),
            creator: value.object("creator").string("nickname"),
            description: value.string("description"),
            artwork: Artwork(
                symbol: "music.note.list",
                accent: .green,
                remoteURL: firstURL(value, keys: ["coverImgUrl", "coverUrl"])
            ),
            trackCount: value.int("trackCount"),
            isSubscribed: value.bool("subscribed"),
            creatorID: value.object("creator").int64("userId"),
            tags: value["tags"] as? [String] ?? [],
            subscriberCount: value.int64("subscribedCount"),
            specialType: value.int("specialType"),
            privacy: value.int("privacy"),
            isReadOnly: value.bool("readOnly")
                || value.bool("isReadOnly")
                || (value["canEdit"] != nil && !value.bool("canEdit"))
        )
    }

    func decodeLiveUser(_ value: [String: Any]) -> UserProfile? {
        let id = value.int64("userId") != 0 ? value.int64("userId") : value.int64("id")
        guard id != 0 else { return nil }
        return UserProfile(
            id: id,
            nickname: value.string("nickname"),
            signature: value.string("signature"),
            artwork: Artwork(
                symbol: "person.crop.circle.fill",
                accent: .blue,
                remoteURL: firstURL(value, keys: ["avatarUrl"])
            ),
            isFollowed: value.bool("followed"),
            gender: value.int("gender"),
            detailDescription: value.string("detailDescription"),
            followerCount: value.int64("followeds"),
            followingCount: value.int64("follows"),
            followsCurrentUser: value.bool("followMe")
        )
    }

    func decodeLiveUserDetail(_ root: [String: Any]) -> UserProfile? {
        guard var profile = decodeLiveUser(root.object("profile")) else { return nil }
        profile.level = root.int("level")
        profile.listenSongs = root.int64("listenSongs")
        return profile
    }

    private func firstText(_ value: Any?) -> String? {
        (value as? [Any])?.compactMap { nonempty($0 as? String ?? "") }.first
    }

    private func nonempty(_ value: String) -> String? {
        value.isEmpty ? nil : value
    }

    private func firstURL(_ value: [String: Any], keys: [String]) -> URL? {
        keys.lazy.compactMap { nonempty(value.string($0)).flatMap(URL.init(string:)) }.first
    }
}
