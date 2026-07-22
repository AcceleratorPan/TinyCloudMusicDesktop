import Foundation

struct MusicSearchKeyword: Identifiable, Equatable, Sendable {
    var id: String { "\(display)-\(query)" }
    let display: String
    let query: String
}

struct MusicSearchSuggestion: Identifiable, Equatable, Sendable {
    var id: String { keyword }
    let keyword: String
    let tagURL: URL?
}

struct HotSearchItem: Identifiable, Equatable, Sendable {
    var id: String { keyword }
    let keyword: String
    let detail: String
    let score: Int
    let iconURL: URL?
    let iconType: Int
    let algorithm: String
}

struct SearchDirectMatch: Identifiable, Equatable, Sendable {
    var id: String { item.id }
    let item: SearchItem
}

struct MusicPlaylistPage: Equatable, Sendable {
    let playlists: [MusicLibraryPlaylist]
    let offset: Int
    let hasMore: Bool
}

struct MusicArtistAlbum: Identifiable, Equatable, Sendable {
    var id: Int64 { album.id }
    let album: Album
    let isSubscribed: Bool
}

struct MusicArtistAlbumPage: Equatable, Sendable {
    let albums: [MusicArtistAlbum]
    let offset: Int
    let hasMore: Bool
}

struct MusicAlbumSubscription: Equatable, Sendable {
    let isSubscribed: Bool
    let subscriberCount: Int64
}

struct MusicArtistFollowStatus: Equatable, Sendable {
    let isFollowed: Bool
    let followerCount: Int64
    let followDay: String
}

struct MusicAvailablePlaylist: Identifiable, Equatable, Sendable {
    var id: Int64 { playlist.id }
    let playlist: MusicLibraryPlaylist
    let containsTrack: Bool
}

struct MusicAvailablePlaylistPage: Equatable, Sendable {
    let playlists: [MusicAvailablePlaylist]
    let offset: Int
    let hasMore: Bool
}

struct MusicRecommendedUser: Identifiable, Equatable, Sendable {
    let id: Int64
    let nickname: String
    let signature: String
    let description: String
    let avatarURL: URL?
    let gender: Int
    let isFollowed: Bool
}

enum MusicExtraDecoder {
    static func searchKeywords(_ root: [String: Any]) -> [MusicSearchKeyword] {
        array(object(root, "data"), "keywords").compactMap { value in
            let display = string(value, "showKeyword")
            let query = string(value, "realkeyword")
            guard !display.isEmpty, !query.isEmpty else { return nil }
            return MusicSearchKeyword(display: display, query: query)
        }
    }

    static func searchSuggestions(_ root: [String: Any]) -> [MusicSearchSuggestion] {
        array(object(root, "data"), "suggests").compactMap { value in
            let keyword = string(value, "keyword")
            guard !keyword.isEmpty else { return nil }
            return MusicSearchSuggestion(keyword: keyword, tagURL: url(value, "tagUrl"))
        }
    }

    static func hotSearch(_ root: [String: Any]) -> [HotSearchItem] {
        array(root, "data").compactMap { value in
            let keyword = string(value, "searchWord").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !keyword.isEmpty else { return nil }
            let iconURL = url(value, "iconUrl")
            return HotSearchItem(
                keyword: keyword,
                detail: string(value, "content"),
                score: int(value, "score"),
                iconURL: iconURL?.scheme?.lowercased() == "https" ? iconURL : nil,
                iconType: int(value, "iconType"),
                algorithm: string(value, "alg")
            )
        }
    }

    static func searchDirectMatches(
        _ root: [String: Any],
        repository: LiveMusicRepository,
        limit: Int = 5
    ) -> [SearchDirectMatch] {
        guard limit > 0 else { return [] }
        let result = object(root, "result")
        let supported = ["song", "artist", "album", "playlist", "user"]
        let requestedOrder = (result["orders"] as? [String] ?? []).map(canonicalSearchType)
        var seenTypes = Set<String>()
        var seenIDs = Set<String>()
        var matches: [SearchDirectMatch] = []

        for type in requestedOrder + supported where supported.contains(type) && seenTypes.insert(type).inserted {
            let value = searchValues(result, type: type).first
            let item: SearchItem? = switch type {
            case "song": value.flatMap(repository.decodeLiveSong).map(SearchItem.song)
            case "artist": value.flatMap(repository.decodeLiveArtist).map(SearchItem.artist)
            case "album": value.flatMap(repository.decodeLiveAlbum).map(SearchItem.album)
            case "playlist": value.flatMap(repository.decodeLivePlaylist).map(SearchItem.playlist)
            case "user": value.flatMap(repository.decodeLiveUser).map(SearchItem.user)
            default: nil
            }
            guard let item, seenIDs.insert(item.id).inserted else { continue }
            matches.append(SearchDirectMatch(item: item))
            if matches.count == limit { break }
        }
        return matches
    }

    static func favoritePlaylistID(_ root: [String: Any]) -> Int64? {
        array(root, "playlist").first(where: { int($0, "specialType") == 5 }).map { int64($0, "id") }
    }

    static func trackIDs(_ playlist: [String: Any]) -> [Int64] {
        array(playlist, "trackIds").map { int64($0, "id") }.filter { $0 != 0 }
    }

    static func albumSubscription(_ root: [String: Any]) -> MusicAlbumSubscription {
        MusicAlbumSubscription(
            isSubscribed: bool(root, "isSub"),
            subscriberCount: int64(root, "subCount")
        )
    }

    static func artistFollowStatus(_ root: [String: Any]) -> MusicArtistFollowStatus {
        let data = object(root, "data")
        return MusicArtistFollowStatus(
            isFollowed: bool(data, "follow"),
            followerCount: int64(data, "fansCnt"),
            followDay: string(data, "followDay")
        )
    }

    static func recommendedUser(_ value: [String: Any]) -> MusicRecommendedUser? {
        let id = int64(value, "userId")
        guard id != 0 else { return nil }
        return MusicRecommendedUser(
            id: id,
            nickname: string(value, "nickname"),
            signature: string(value, "signature"),
            description: string(value, "description"),
            avatarURL: url(value, "avatarUrl"),
            gender: int(value, "gender"),
            isFollowed: bool(value, "followed")
        )
    }

    private static func object(_ value: [String: Any], _ key: String) -> [String: Any] {
        value[key] as? [String: Any] ?? [:]
    }

    private static func array(_ value: [String: Any], _ key: String) -> [[String: Any]] {
        value[key] as? [[String: Any]] ?? []
    }

    private static func canonicalSearchType(_ value: String) -> String {
        switch value {
        case "songs": "song"
        case "artists": "artist"
        case "albums": "album"
        case "playlists": "playlist"
        case "users", "userprofiles": "user"
        default: value
        }
    }

    private static func searchValues(_ result: [String: Any], type: String) -> [[String: Any]] {
        let keys: [String] = switch type {
        case "song": ["song", "songs"]
        case "artist": ["artist", "artists"]
        case "album": ["album", "albums"]
        case "playlist": ["playlist", "playlists"]
        case "user": ["user", "users", "userprofiles"]
        default: []
        }
        return keys.lazy.map { array(result, $0) }.first(where: { !$0.isEmpty }) ?? []
    }

    private static func string(_ value: [String: Any], _ key: String) -> String {
        if let text = value[key] as? String { return text }
        return (value[key] as? NSNumber)?.stringValue ?? ""
    }

    private static func int64(_ value: [String: Any], _ key: String) -> Int64 {
        (value[key] as? NSNumber)?.int64Value ?? Int64(string(value, key)) ?? 0
    }

    private static func int(_ value: [String: Any], _ key: String) -> Int {
        (value[key] as? NSNumber)?.intValue ?? Int(string(value, key)) ?? 0
    }

    private static func bool(_ value: [String: Any], _ key: String) -> Bool {
        (value[key] as? NSNumber)?.boolValue ?? false
    }

    private static func url(_ value: [String: Any], _ key: String) -> URL? {
        let text = string(value, key)
        return text.isEmpty ? nil : URL(string: text)
    }
}
