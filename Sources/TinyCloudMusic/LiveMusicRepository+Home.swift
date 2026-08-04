import Foundation

extension LiveMusicRepository {
    func homeSection(
        id: String,
        expectedCredentialRevision: UInt64
    ) async throws -> HomeSection {
        guard HomeBlockDecoder.supports(id) else {
            throw AppError.unavailable("不支持的首页栏目：\(id)")
        }

        let blockList = "[\"\(id)\"]"
        let root = try await request(
            EAPIEndpoint(
                "/eapi/link/page/rcmd/resource/show",
                signing: "/api/link/page/rcmd/resource/show",
                host: "https://interface3.music.163.com"
            ),
            payload: [
                "refresh": 1,
                "callbackParameters": "{\"likePosition\":1}",
                "pageStyleType": "noCutBlock",
                "blockCodeOrderList": blockList,
                "verifyId": 1,
                "cursor": 1,
                "pageCode": "HOME_RECOMMEND_PAGE",
                "e_r": true,
                "clientCacheBlockCode": "[]",
                "isFirstScreen": false
            ],
            expectedCredentialRevision: expectedCredentialRevision
        )

        let blocks = root.object("data").array("blocks")
        guard let block = blocks.first(where: { $0.string("bizCode") == id }) else {
            throw EAPIError.missingData("data.blocks[\(id)]")
        }

        let draft = try HomeBlockDecoder.decode(block: block, requestedID: id, decodeSong: decodeSong)
        let missingIDs = draft.resources.compactMap { resource in
            resource.kind == .song && resource.song == nil ? resource.id : nil
        }
        let detailedSongs = try await songDetails(
            ids: missingIDs,
            expectedCredentialRevision: expectedCredentialRevision
        )
        let songsByID = Dictionary(detailedSongs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        let items = draft.resources.compactMap { resource -> HomeItem? in
            switch resource.kind {
            case .playlist:
                return .destination(
                    id: resource.id,
                    title: resource.title,
                    subtitle: resource.subtitle,
                    artwork: resource.artwork,
                    route: .playlist(resource.id)
                )
            case .album:
                return .destination(
                    id: resource.id,
                    title: resource.title,
                    subtitle: resource.subtitle,
                    artwork: resource.artwork,
                    route: .album(resource.id)
                )
            case .song:
                guard let song = resource.song ?? songsByID[resource.id] else { return nil }
                return .song(resource.applyingPresentation(to: song), subtitle: resource.subtitle)
            }
        }
        guard !items.isEmpty else {
            throw AppError.unavailable("首页栏目 \(id) 没有可显示的资源")
        }
        return HomeSection(id: id, title: draft.title, subtitle: draft.subtitle, items: items)
    }

    private func songDetails(
        ids: [Int64],
        expectedCredentialRevision: UInt64
    ) async throws -> [Song] {
        let ids = Array(Set(ids)).sorted()
        guard !ids.isEmpty else { return [] }
        let c = "[" + ids.map { "{\"id\":\($0)}" }.joined(separator: ",") + "]"
        let root = try await request(
            EAPIEndpoint(
                "/eapi/v3/song/detail",
                signing: "/api/v3/song/detail",
                host: "https://interface3.music.163.com"
            ),
            payload: ["trialMode": 12, "e_r": true, "verifyId": 1, "source": "", "c": c],
            expectedCredentialRevision: expectedCredentialRevision
        )
        return root.array("songs").compactMap(decodeSong)
    }
}

enum HomeResourceKind: Sendable {
    case playlist
    case album
    case song
}

struct HomeBlockResource: Sendable {
    let kind: HomeResourceKind
    let id: Int64
    let title: String
    let subtitle: String
    let artwork: Artwork
    let song: Song?

    func applyingPresentation(to song: Song) -> Song {
        Song(
            id: song.id,
            name: title.isEmpty || title == song.name ? song.primaryName : title,
            artists: song.artists.isEmpty && !subtitle.isEmpty
                ? [ArtistSummary(id: 0, name: subtitle)]
                : song.artists,
            album: AlbumSummary(
                id: song.album.id,
                name: song.album.name,
                artwork: artwork.remoteURL == nil ? song.album.artwork : artwork
            ),
            duration: song.duration,
            translatedName: song.translatedName,
            aliasName: song.aliasName
        )
    }
}

struct HomeBlockDraft: Sendable {
    let title: String
    let subtitle: String
    let resources: [HomeBlockResource]
}

enum HomeBlockDecoder {
    private static let supportedIDs: Set<String> = [
        "PAGE_RECOMMEND_COMBINATION",
        "PAGE_RECOMMEND_FEELING_PLAYLIST_LOCATION",
        "PAGE_RECOMMEND_RADAR",
        "PAGE_RECOMMEND_SPECIAL_CLOUD_VILLAGE_PLAYLIST",
        "PAGE_RECOMMEND_RANK",
        "PAGE_RECOMMEND_STYLE_PLAYLIST_1",
        "PAGE_RECOMMEND_FIRM_PLAYLIST",
        "PAGE_RECOMMEND_MONTH_YEAR_PLAYLIST",
        "PAGE_RECOMMEND_LBS",
        "PAGE_RECOMMEND_MY_SHEET",
        "PAGE_RECOMMEND_PRIVATE_RCMD_SONG",
        "PAGE_RECOMMEND_RED_SIMILAR_SONG",
        "PAGE_RECOMMEND_SCENE_PLAYLIST_LOCATION",
        "PAGE_RECOMMEND_NEW_SONG_AND_ALBUM",
        "PAGE_RECOMMEND_ARTIST_TREND",
        "PAGE_RECOMMEND_SPECIAL_ORIGIN_SONG_LOCATION"
    ]

    static func supports(_ id: String) -> Bool { supportedIDs.contains(id) }

    static func decode(
        block: [String: Any],
        requestedID: String,
        decodeSong: ([String: Any]) -> Song?
    ) throws -> HomeBlockDraft {
        guard supports(requestedID), block.string("bizCode") == requestedID else {
            throw AppError.unavailable("不支持或不匹配的首页栏目：\(requestedID)")
        }

        let dslData = block.object("dslData")
        guard !dslData.isEmpty else { throw EAPIError.missingData("dslData") }
        let module = preferredModule(in: dslData, for: requestedID) ?? dslData
        let titleSource: Any = requestedID == "PAGE_RECOMMEND_ARTIST_TREND"
            ? (findValue(in: dslData, keyPrefix: "home_artist_new_trends_title") ?? module)
            : module
        let title = sectionText(in: titleSource, keys: ["blockTitle", "title"])
            ?? sectionText(in: module, keys: ["title", "blockTitle"])
            ?? defaultTitle(for: requestedID)
        let subtitle = sectionText(in: module, keys: ["subTitle", "subtitle", "description"]) ?? ""

        var seen = Set<String>()
        let resources = resourceObjects(in: module).flatMap { source -> [HomeBlockResource] in
            if requestedID == "PAGE_RECOMMEND_LBS", source.string("resourceType").lowercased() == "citystylecharts" {
                let action = source.object("playBtn").object("playAction")
                let chart = source.string("name")
                let detail = resourceSubtitle(source)
                let subtitle = [chart, detail].filter { !$0.isEmpty }.joined(separator: " · ")
                let cover = source.string("coverImg").nonEmpty ?? source.string("coverUrl").nonEmpty
                // ponytail: flatten city charts into one playable section; add a collection route if grouping matters.
                return allIDs(in: action["songIds"]).compactMap { id in
                    guard seen.insert("song-\(id)").inserted else { return nil }
                    return HomeBlockResource(
                        kind: .song,
                        id: id,
                        title: "",
                        subtitle: subtitle,
                        artwork: Artwork(symbol: "music.note", accent: .red, remoteURL: cover.flatMap(URL.init(string:))),
                        song: nil
                    )
                }
            }
            guard let kind = kind(for: source.string("resourceType"), blockID: requestedID) else { return [] }
            let song = kind == .song ? inlineSong(in: source, decodeSong: decodeSong) : nil
            let id = resourceID(in: source, kind: kind, song: song)
            guard id != 0 else { return [] }
            let key = "\(kind)-\(id)"
            guard seen.insert(key).inserted else { return [] }

            let rawTitle = source.string("title").nonEmpty ?? source.string("name").nonEmpty
            let title = rawTitle ?? song?.name ?? "\(id)"
            let subtitle = resourceSubtitle(source)
            let cover = source.string("coverImg").nonEmpty
                ?? source.string("coverUrl").nonEmpty
                ?? source.string("picUrl").nonEmpty
                ?? source.object("uiElement").object("image").string("imageUrl").nonEmpty
            return [HomeBlockResource(
                kind: kind,
                id: id,
                title: title,
                subtitle: subtitle,
                artwork: Artwork(symbol: kind == .album ? "square.stack" : "music.note", accent: .red, remoteURL: cover.flatMap(URL.init(string:))),
                song: song
            )]
        }
        guard !resources.isEmpty else {
            throw AppError.unavailable("首页栏目 \(requestedID) 的资源为空或格式不受支持")
        }
        return HomeBlockDraft(title: title, subtitle: subtitle, resources: resources)
    }

    private static func preferredModule(in dslData: [String: Any], for id: String) -> Any? {
        let prefix: String?
        switch id {
        case "PAGE_RECOMMEND_RADAR": prefix = "home_radar_playlist_module"
        case "PAGE_RECOMMEND_SPECIAL_CLOUD_VILLAGE_PLAYLIST", "PAGE_RECOMMEND_FIRM_PLAYLIST", "PAGE_RECOMMEND_NEW_SONG_AND_ALBUM":
            prefix = "home_page_common_playlist_module"
        case "PAGE_RECOMMEND_RANK": prefix = "rcmd_rank_module"
        case "PAGE_RECOMMEND_MONTH_YEAR_PLAYLIST": prefix = "rcmd_annual_and_monthly_playlist_list_module"
        case "PAGE_RECOMMEND_LBS": prefix = "home_position_rank_module"
        case "PAGE_RECOMMEND_PRIVATE_RCMD_SONG", "PAGE_RECOMMEND_RED_SIMILAR_SONG": prefix = "home_common_rcmd_songs_module"
        case "PAGE_RECOMMEND_SCENE_PLAYLIST_LOCATION", "PAGE_RECOMMEND_SPECIAL_ORIGIN_SONG_LOCATION":
            prefix = "home_page_scene_playlist_module"
        case "PAGE_RECOMMEND_ARTIST_TREND": prefix = "artist_new_trends_list"
        default: prefix = nil
        }
        return prefix.flatMap { findValue(in: dslData, keyPrefix: $0) } ?? dslData["blockResource"]
    }

    private static func findValue(in value: Any, keyPrefix: String) -> Any? {
        if let array = value as? [Any] {
            return array.lazy.compactMap { findValue(in: $0, keyPrefix: keyPrefix) }.first
        }
        guard let object = value as? [String: Any] else { return nil }
        if let match = object.first(where: { $0.key.hasPrefix(keyPrefix) }) { return match.value }
        return object.values.lazy.compactMap { findValue(in: $0, keyPrefix: keyPrefix) }.first
    }

    private static func sectionText(in value: Any, keys: [String]) -> String? {
        if let array = value as? [Any] {
            return array.lazy.compactMap { sectionText(in: $0, keys: keys) }.first
        }
        guard let object = value as? [String: Any] else { return nil }
        for key in keys {
            if let text = object.string(key).nonEmpty { return text }
        }
        if let header = object["header"], let text = sectionText(in: header, keys: keys) { return text }
        for key in ["blockResourceVO", "blockResource", "content"] {
            if let nested = object[key], let text = sectionText(in: nested, keys: keys) { return text }
        }
        return nil
    }

    private static func resourceObjects(in value: Any) -> [[String: Any]] {
        if let array = value as? [Any] { return array.flatMap(resourceObjects) }
        guard let object = value as? [String: Any] else { return [] }
        if !object.string("resourceType").isEmpty { return [object] }

        var result: [[String: Any]] = []
        for key in ["blockResourceVO", "content", "blockResource", "resources", "items"] {
            if let nested = object[key] { result += resourceObjects(in: nested) }
        }
        if result.isEmpty {
            result = object.values.flatMap(resourceObjects)
        }
        return result
    }

    private static func kind(for type: String, blockID: String) -> HomeResourceKind? {
        let type = type.lowercased()
        switch blockID {
        case "PAGE_RECOMMEND_PRIVATE_RCMD_SONG", "PAGE_RECOMMEND_RED_SIMILAR_SONG":
            return type == "song" ? .song : nil
        case "PAGE_RECOMMEND_ARTIST_TREND":
            if type == "song" { return .song }
            return type == "album" ? .album : nil
        case "PAGE_RECOMMEND_RANK":
            return ["playlist", "toplist"].contains(type) ? .playlist : nil
        case "PAGE_RECOMMEND_LBS":
            return type == "citystylecharts" ? .playlist : nil
        default:
            return type == "playlist" ? .playlist : nil
        }
    }

    private static func resourceID(in source: [String: Any], kind: HomeResourceKind, song: Song?) -> Int64 {
        if let song { return song.id }
        for key in ["resourceId", "id", kind == .album ? "albumId" : "playlistId"] {
            let id = source.int64(key)
            if id != 0 { return id }
        }
        if kind == .song {
            let action = source.object("playBtn").object("playAction")
            if let id = firstID(in: action["songIds"]) { return id }
            return action.int64("songId")
        }
        let nested = source.object(kind == .album ? "album" : "playlist")
        return nested.int64("id")
    }

    private static func firstID(in value: Any?) -> Int64? {
        guard let value else { return nil }
        if let number = value as? NSNumber { return number.int64Value }
        if let string = value as? String { return Int64(string) }
        if let object = value as? [String: Any] {
            let id = object.int64("id")
            return id == 0 ? nil : id
        }
        if let array = value as? [Any] { return array.lazy.compactMap(firstID).first }
        return nil
    }

    private static func allIDs(in value: Any?) -> [Int64] {
        guard let value else { return [] }
        if let number = value as? NSNumber { return [number.int64Value] }
        if let string = value as? String, let id = Int64(string) { return [id] }
        if let object = value as? [String: Any] {
            let id = object.int64("id")
            return id == 0 ? [] : [id]
        }
        if let array = value as? [Any] { return array.flatMap(allIDs) }
        return []
    }

    private static func inlineSong(
        in source: [String: Any],
        decodeSong: ([String: Any]) -> Song?
    ) -> Song? {
        let candidates = [
            source,
            source.object("simpleSongData"),
            source.object("baseInfo"),
            source.object("song"),
            source.object("songInfo")
        ]
        return candidates.lazy.compactMap(decodeSong).first(where: { !$0.name.isEmpty })
    }

    private static func resourceSubtitle(_ source: [String: Any]) -> String {
        var parts = ["subTitle", "artistName", "description", "recReason"]
            .compactMap { source.string($0).nonEmpty }
        let playCount = source.object("resourceInteractInfo").string("playCount").nonEmpty
            ?? source.string("playCount").nonEmpty
        if let playCount { parts.append("(\(playCount))") }
        var seen = Set<String>()
        return parts.filter { seen.insert($0).inserted }.joined(separator: " · ")
    }

    private static func defaultTitle(for id: String) -> String {
        switch id {
        case "PAGE_RECOMMEND_COMBINATION": "精选推荐"
        case "PAGE_RECOMMEND_FEELING_PLAYLIST_LOCATION": "氛围歌单"
        case "PAGE_RECOMMEND_RADAR": "雷达歌单"
        case "PAGE_RECOMMEND_SPECIAL_CLOUD_VILLAGE_PLAYLIST": "推荐歌单"
        case "PAGE_RECOMMEND_RANK": "排行榜"
        case "PAGE_RECOMMEND_STYLE_PLAYLIST_1": "根据你的听歌风格推荐"
        case "PAGE_RECOMMEND_FIRM_PLAYLIST": "影视原声音乐"
        case "PAGE_RECOMMEND_MONTH_YEAR_PLAYLIST": "年度与月度歌单"
        case "PAGE_RECOMMEND_LBS": "地方特色"
        case "PAGE_RECOMMEND_MY_SHEET": "我的歌单"
        case "PAGE_RECOMMEND_PRIVATE_RCMD_SONG": "私人推荐"
        case "PAGE_RECOMMEND_RED_SIMILAR_SONG": "根据你喜爱的歌曲推荐"
        case "PAGE_RECOMMEND_SCENE_PLAYLIST_LOCATION": "场景歌单"
        case "PAGE_RECOMMEND_NEW_SONG_AND_ALBUM": "每周新热趋势"
        case "PAGE_RECOMMEND_ARTIST_TREND": "艺人的最新动向"
        case "PAGE_RECOMMEND_SPECIAL_ORIGIN_SONG_LOCATION": "原创歌曲"
        default: id
        }
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
