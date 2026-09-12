import Foundation

enum MusicLibraryLoginState: Equatable, Sendable {
    case loggedOut
    case loggedIn(MusicLibraryUser)
}

struct MusicLibraryUser: Identifiable, Equatable, Sendable {
    let id: Int64
    let nickname: String
    let signature: String
    let detail: String
    let avatarURL: URL?
    let gender: Int
    let level: Int
    let listenedSongCount: Int
    let followerCount: Int
    let followingCount: Int
    let isFollowed: Bool
    let followsCurrentUser: Bool
}

struct ValidatedMusicLibraryAccount: Equatable, Sendable {
    let user: MusicLibraryUser
    let credentialRevision: UInt64
}

enum RecentPlaybackKind: String, CaseIterable, Sendable {
    case song, album, playlist, video, voice, podcast

    var title: String {
        switch self {
        case .song: "歌曲"
        case .album: "专辑"
        case .playlist: "歌单"
        case .video: "视频"
        case .voice: "声音"
        case .podcast: "播客"
        }
    }

    var symbol: String {
        switch self {
        case .song: "music.note"
        case .album: "square.stack"
        case .playlist: "music.note.list"
        case .video: "play.rectangle"
        case .voice: "waveform"
        case .podcast: "dot.radiowaves.left.and.right"
        }
    }
}

enum RecentVideoKind: String, Equatable, Sendable {
    case mv, video
}

struct RecentMediaSummary: Identifiable, Equatable, Sendable {
    let id: String
    let resourceID: String
    let videoKind: RecentVideoKind?
    let title: String
    let subtitle: String
    let artworkURL: URL?
    let playedAt: Date?
}

enum RecentPlaybackContent: Equatable, Sendable {
    case songs([Song])
    case albums([Album])
    case playlists([Playlist])
    case media([RecentMediaSummary])
}

enum RecentPlaybackLoad: Equatable, Sendable {
    case idle
    case loading
    case loaded(RecentPlaybackContent)
    case failed(String)

    var isLoading: Bool { self == .loading }
}

struct RecentPlaybackState: Sendable {
    private(set) var accountID: Int64?
    private(set) var generation = 0
    private var loads: [RecentPlaybackKind: RecentPlaybackLoad] = [:]

    func load(for kind: RecentPlaybackKind) -> RecentPlaybackLoad {
        loads[kind] ?? .idle
    }

    mutating func reset(accountID: Int64?) {
        generation &+= 1
        self.accountID = accountID
        loads.removeAll()
    }

    mutating func setLoading(_ kind: RecentPlaybackKind) {
        loads[kind] = .loading
    }

    @discardableResult
    mutating func accept(
        _ load: RecentPlaybackLoad,
        for kind: RecentPlaybackKind,
        generation: Int,
        accountID: Int64
    ) -> Bool {
        guard self.generation == generation, self.accountID == accountID else { return false }
        loads[kind] = load
        return true
    }
}

enum MusicListeningPeriod: Int, CaseIterable, Sendable {
    case week = 1
    case allTime = 0

    var title: String { self == .week ? "本周" : "全部" }
    var responseKey: String { self == .week ? "weekData" : "allData" }
}

struct MusicListeningRecord: Identifiable, Equatable, Sendable {
    var id: Int64 { song.id }
    let song: Song
    let playCount: Int
    let score: Int
}

enum PersonalFMScene: String, CaseIterable, Equatable, Sendable {
    case exercise = "EXERCISE"
    case focus = "FOCUS"
    case night = "NIGHT_EMO"

    var title: String {
        switch self {
        case .exercise: "运动"
        case .focus: "专注"
        case .night: "夜晚"
        }
    }
}

enum PersonalFMMode: Equatable, Sendable {
    case standard
    case familiar
    case explore
    case scene(PersonalFMScene)

    var title: String {
        switch self {
        case .standard: "默认推荐"
        case .familiar: "熟悉歌曲"
        case .explore: "探索新歌"
        case let .scene(scene): scene.title
        }
    }

    var requestValues: (mode: String, subMode: String) {
        switch self {
        case .standard: ("DEFAULT", "")
        case .familiar: ("FAMILIAR", "")
        case .explore: ("EXPLORE", "")
        case let .scene(scene): ("SCENE_RCMD", scene.rawValue)
        }
    }
}

struct PersonalFMTrack: Identifiable, Equatable, Sendable {
    var id: Int64 { song.id }
    let song: Song
    let algorithm: String
}

struct MusicLibraryPlaylist: Identifiable, Equatable, Sendable {
    let id: Int64
    let name: String
    let creatorID: Int64
    let creatorName: String
    let description: String
    let coverURL: URL?
    let trackCount: Int
    let playCount: Int64
    let isSubscribed: Bool
    let subscriberCount: Int64
    var privacy = 0
    var specialType = 0
    var isReadOnly = false
}

struct MusicLibraryArtist: Identifiable, Equatable, Sendable {
    let id: Int64
    let name: String
    let imageURL: URL?
    let isFollowed: Bool
}

enum MusicLibraryFollowKind: Equatable, Sendable {
    case user
    case artist
}

struct MusicLibraryFollow: Identifiable, Equatable, Sendable {
    var id: String { "\(kind)-\(resourceID)" }
    let resourceID: Int64
    let kind: MusicLibraryFollowKind
    let name: String
    let imageURL: URL?
    let followDay: String
    let gender: Int
}

enum MusicPlaylistPrivacy: Int, Sendable {
    case publicPlaylist = 0
    case privatePlaylist = 10
}

enum CommentResource: Hashable, Sendable {
    case song(Int64)
    case mv(Int64)
    case video(String)

    func threadID() throws -> String {
        switch self {
        case let .song(id):
            guard id > 0 else { throw EAPIError.invalidPayload }
            return "R_SO_4_\(id)"
        case let .mv(id):
            guard id > 0 else { throw EAPIError.invalidPayload }
            return "R_MV_5_\(id)"
        case .video:
            return "R_VI_62_\(try requestID())"
        }
    }

    func requestID() throws -> String {
        switch self {
        case let .song(id), let .mv(id):
            guard id > 0 else { throw EAPIError.invalidPayload }
            return String(id)
        case let .video(rawID):
            let id = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty,
                  !id.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
                  URLComponents(string: id)?.scheme == nil
            else { throw EAPIError.invalidPayload }
            return id
        }
    }

    func encodedThreadID() throws -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        guard let value = try threadID().addingPercentEncoding(withAllowedCharacters: allowed) else {
            throw EAPIError.invalidPayload
        }
        return value
    }
}

struct MusicComment: Identifiable, Equatable, Sendable {
    let id: Int64
    let songID: Int64
    let userID: Int64
    let nickname: String
    let content: String
    let timeText: String
    let likedCount: Int
    let isLiked: Bool
    let replyCount: Int
    let replyToNickname: String?

    var displayContent: String {
        replyToNickname.map { "回复\($0)：\(content)" } ?? content
    }

    func settingLiked(_ liked: Bool) -> Self {
        MusicComment(
            id: id,
            songID: songID,
            userID: userID,
            nickname: nickname,
            content: content,
            timeText: timeText,
            likedCount: max(0, likedCount + (liked == isLiked ? 0 : liked ? 1 : -1)),
            isLiked: liked,
            replyCount: replyCount,
            replyToNickname: replyToNickname
        )
    }

    func addingReply() -> Self {
        MusicComment(
            id: id,
            songID: songID,
            userID: userID,
            nickname: nickname,
            content: content,
            timeText: timeText,
            likedCount: likedCount,
            isLiked: isLiked,
            replyCount: replyCount + 1,
            replyToNickname: replyToNickname
        )
    }
}

struct MusicCommentPage: Equatable, Sendable {
    let comments: [MusicComment]
    let cursor: String
    let hasMore: Bool
    let sortType: Int
    let totalCount: Int
}

struct MusicCommentCount: Equatable, Sendable {
    let count: Int
    let displayText: String
}

struct MusicCommentFloorPage: Equatable, Sendable {
    let ownerContent: String
    let comments: [MusicComment]
    let cursor: String
    let time: Int64
    let hasMore: Bool
}

enum MusicLibraryDecoder {
    static func recentResources(
        _ root: [String: Any],
        kind: RecentPlaybackKind
    ) -> [[String: Any]] {
        recentRecordPairs(root, kind: kind).map(\.resource)
    }

    static func recentMedia(
        _ root: [String: Any],
        kind: RecentPlaybackKind
    ) -> [RecentMediaSummary] {
        var seen = Set<String>()
        return recentRecordPairs(root, kind: kind).compactMap { record, resource in
            let videoKind = kind == .video ? recentVideoKind(record: record, resource: resource) : nil
            let internalID = kind == .video
                ? recentVideoResourceID(record: record, resource: resource, kind: videoKind)
                : firstString(resource, keys: recentIDKeys[kind] ?? ["id"])
            let externalID = firstString(record, keys: ["resourceId", "resourceID"])
            let resourceID = kind == .video ? internalID ?? externalID : externalID ?? internalID
            let title = firstString(resource, keys: ["name", "title"])
            guard let resourceID, let title else { return nil }
            let identity = videoKind.map { "\($0.rawValue)-\(resourceID)" } ?? resourceID
            guard seen.insert(identity).inserted else { return nil }
            return RecentMediaSummary(
                id: identity,
                resourceID: resourceID,
                videoKind: videoKind,
                title: title,
                subtitle: recentSubtitle(resource),
                artworkURL: firstString(
                    resource,
                    keys: ["coverUrl", "coverImgUrl", "picUrl", "imageUrl", "avatarUrl"]
                ).flatMap(URL.init(string:)),
                playedAt: milliseconds(record["playTime"] ?? record["playedAt"])
                    .map { Date(timeIntervalSince1970: TimeInterval($0) / 1_000) }
            )
        }
    }

    static func user(_ profile: [String: Any], root: [String: Any] = [:]) -> MusicLibraryUser? {
        let id = int64(profile, "userId") != 0 ? int64(profile, "userId") : int64(profile, "id")
        guard id != 0 else { return nil }
        return MusicLibraryUser(
            id: id,
            nickname: string(profile, "nickname"),
            signature: string(profile, "signature"),
            detail: string(profile, "detailDescription"),
            avatarURL: URL(string: string(profile, "avatarUrl")),
            gender: int(profile, "gender"),
            level: int(root, "level"),
            listenedSongCount: int(root, "listenSongs"),
            followerCount: int(profile, "followeds"),
            followingCount: int(profile, "follows"),
            isFollowed: bool(profile, "followed"),
            followsCurrentUser: bool(profile, "followMe")
        )
    }

    static func playlist(_ source: [String: Any]) -> MusicLibraryPlaylist? {
        let value = object(source, "playlist").isEmpty ? source : object(source, "playlist")
        let id = int64(value, "id")
        guard id != 0 else { return nil }
        let creator = object(value, "creator")
        return MusicLibraryPlaylist(
            id: id,
            name: string(value, "name"),
            creatorID: int64(creator, "userId"),
            creatorName: string(creator, "nickname"),
            description: string(value, "description"),
            coverURL: URL(string: string(value, "coverImgUrl")),
            trackCount: int(value, "trackCount"),
            playCount: int64(value, "playCount"),
            isSubscribed: bool(value, "subscribed"),
            subscriberCount: int64(value, "subscribedCount"),
            privacy: int(value, "privacy"),
            specialType: int(value, "specialType"),
            isReadOnly: bool(value, "readOnly")
                || bool(value, "isReadOnly")
                || (value["canEdit"] != nil && !bool(value, "canEdit"))
        )
    }

    static func artist(_ value: [String: Any]) -> MusicLibraryArtist? {
        let id = int64(value, "id")
        guard id != 0 else { return nil }
        let translated = string(value, "trans").isEmpty
            ? ((value["transNames"] as? [String])?.first ?? "")
            : string(value, "trans")
        return MusicLibraryArtist(
            id: id,
            name: string(value, "name") + (translated.isEmpty ? "" : "(\(translated))"),
            imageURL: ["cover", "picUrl", "img1v1Url"].lazy
                .compactMap { URL(string: string(value, $0)) }
                .first,
            isFollowed: bool(value, "followed")
        )
    }

    static func mixedFollow(_ value: [String: Any]) -> MusicLibraryFollow? {
        let type = int(value, "type")
        let isUser = type == 1
        let profile = object(value, isUser ? "userProfile" : "artistInfo")
        let id = int64(profile, isUser ? "userId" : "id")
        guard id != 0 else { return nil }
        let imageKeys = isUser ? ["avatarUrl"] : ["cover", "picUrl", "img1v1Url"]
        return MusicLibraryFollow(
            resourceID: id,
            kind: isUser ? .user : .artist,
            name: string(profile, isUser ? "nickname" : "name"),
            imageURL: imageKeys.lazy.compactMap { URL(string: string(profile, $0)) }.first,
            followDay: string(value, "followDay"),
            gender: isUser ? int(profile, "gender") : 0
        )
    }

    static func commentPage(_ root: [String: Any], songID: Int64) -> MusicCommentPage {
        let data = object(root, "data")
        return MusicCommentPage(
            comments: array(data, "comments").compactMap { comment($0, songID: songID) },
            cursor: string(data, "cursor"),
            hasMore: bool(data, "hasMore"),
            sortType: int(data, "sortType"),
            totalCount: int(data, "totalCount")
        )
    }

    static func readOnlyCommentPage(
        _ root: [String: Any],
        resource: CommentResource,
        offset: Int,
        limit: Int
    ) -> VideoCommentPage {
        let values = array(root, "comments")
        let songID: Int64 = if case let .song(id) = resource { id } else { 0 }
        let totalCount = max(0, int(root, "total"))
        return VideoCommentPage(
            comments: values.compactMap { comment($0, songID: songID) },
            totalCount: totalCount,
            hasMore: bool(root, "more") || bool(root, "hasMore") || offset + values.count < totalCount,
            nextOffset: offset + limit,
            beforeTime: values.last.map { int64($0, "time") } ?? 0
        )
    }

    static func commentCount(_ root: [String: Any], songID: Int64) -> MusicCommentCount? {
        guard let value = array(root, "data").first(where: { int64($0, "resourceId") == songID }) else {
            return nil
        }
        return MusicCommentCount(
            count: max(0, int(value, "commentCount")),
            displayText: string(value, "commentCountDesc")
        )
    }

    static func commentFloorPage(
        _ root: [String: Any],
        songID: Int64,
        parentCommentID: Int64
    ) -> MusicCommentFloorPage {
        let data = object(root, "data")
        return MusicCommentFloorPage(
            ownerContent: string(object(data, "ownerComment"), "content"),
            comments: array(data, "comments").compactMap {
                comment($0, songID: songID, parentCommentID: parentCommentID)
            },
            cursor: string(data, "cursor"),
            time: int64(data, "time"),
            hasMore: bool(data, "hasMore")
        )
    }

    static func commentEmojiPictureIDs(_ root: [String: Any]) -> [String: String] {
        array(object(root, "data"), "emojis").reduce(into: [:]) { result, value in
            let name = string(value, "emojiName")
            let pictureID = string(value, "picId")
            guard !name.isEmpty, pictureID != "0", !pictureID.isEmpty else { return }
            result["[\(name)]"] = pictureID
        }
    }

    static func writtenComment(_ root: [String: Any], songID: Int64) -> MusicComment? {
        let data = object(root, "data")
        return [object(root, "comment"), object(data, "comment"), data]
            .lazy.compactMap { comment($0, songID: songID) }.first
    }

    private static func comment(
        _ value: [String: Any],
        songID: Int64,
        parentCommentID: Int64? = nil
    ) -> MusicComment? {
        let id = int64(value, "commentId")
        guard id != 0 else { return nil }
        let user = object(value, "user")
        let replied = array(value, "beReplied").first ?? [:]
        let repliedID = int64(replied, "beRepliedCommentId") != 0
            ? int64(replied, "beRepliedCommentId")
            : int64(replied, "commentId")
        let repliedNickname = string(object(replied, "user"), "nickname")
        return MusicComment(
            id: id,
            songID: songID,
            userID: int64(user, "userId"),
            nickname: string(user, "nickname"),
            content: string(value, "content"),
            timeText: string(value, "timeStr"),
            likedCount: int(value, "likedCount"),
            isLiked: bool(value, "liked"),
            replyCount: int(value, "replyCount"),
            replyToNickname: parentCommentID != nil
                && repliedID != 0
                && repliedID != parentCommentID
                && !repliedNickname.isEmpty ? repliedNickname : nil
        )
    }

    private static let recentObjectKeys: [RecentPlaybackKind: [String]] = [
        .song: ["song"],
        .album: ["album"],
        .playlist: ["playlist"],
        .video: ["video", "newVideo"],
        .voice: ["voice", "program"],
        .podcast: ["djRadio", "radio", "podcast"]
    ]

    private static let recentIDKeys: [RecentPlaybackKind: [String]] = [
        .song: ["id"],
        .album: ["id"],
        .playlist: ["id"],
        .video: ["vid", "videoId", "uuid", "mvId", "id"],
        .voice: ["voiceId", "programId", "id"],
        .podcast: ["radioId", "djRadioId", "id"]
    ]

    private static func recentRecordPairs(
        _ root: [String: Any],
        kind: RecentPlaybackKind
    ) -> [(record: [String: Any], resource: [String: Any])] {
        array(object(root, "data"), "list").compactMap { record in
            let data = object(record, "data")
            if !data.isEmpty { return (record, data) }
            for key in recentObjectKeys[kind] ?? [] {
                let value = object(record, key)
                if !value.isEmpty { return (record, value) }
            }
            return nil
        }
    }

    private static func recentVideoKind(
        record: [String: Any],
        resource: [String: Any]
    ) -> RecentVideoKind? {
        for value in [resource, record] {
            guard let threadID = firstString(value, keys: ["threadId", "threadID"]) else { continue }
            if threadID.hasPrefix("R_MV_5_") { return .mv }
            if threadID.hasPrefix("R_VI_62_") { return .video }
        }
        for value in [resource, record] {
            for key in ["isMV", "isMv"] where value[key] != nil {
                return bool(value, key) ? .mv : .video
            }
        }
        for value in [resource, record] {
            switch firstString(value, keys: ["type"])?.lowercased() {
            case "0", "mv": return .mv
            case "1", "video", "mlog", "newvideo": return .video
            default: break
            }
            switch firstString(value, keys: ["resourceType"])?.lowercased() {
            case "1", "mv": return .mv
            case "5", "video", "mlog", "newvideo": return .video
            default: break
            }
        }
        for value in [resource, record] {
            if value["mvId"] != nil { return .mv }
            if ["vid", "videoId", "uuid"].contains(where: { value[$0] != nil }) { return .video }
        }
        return nil
    }

    private static func recentVideoResourceID(
        record: [String: Any],
        resource: [String: Any],
        kind: RecentVideoKind?
    ) -> String? {
        let explicitKeys: [String] = switch kind {
        case .mv: ["mvId", "vid"]
        case .video: ["vid", "videoId", "uuid"]
        case nil: recentIDKeys[.video] ?? []
        }
        if let id = firstString(resource, keys: explicitKeys) { return id }

        let prefix = switch kind {
        case .mv: "R_MV_5_"
        case .video: "R_VI_62_"
        case nil: ""
        }
        if !prefix.isEmpty {
            for value in [resource, record] {
                guard let threadID = firstString(value, keys: ["threadId", "threadID"]),
                      threadID.hasPrefix(prefix)
                else { continue }
                let id = String(threadID.dropFirst(prefix.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !id.isEmpty { return id }
            }
        }
        return firstString(resource, keys: ["id"])
    }

    private static func recentSubtitle(_ value: [String: Any]) -> String {
        if let direct = firstString(value, keys: ["creatorName", "artistName", "nickname"]) {
            return direct
        }
        for key in ["creator", "dj", "radio", "artist", "user"] {
            if let nested = firstString(object(value, key), keys: ["nickname", "name", "userName"]) {
                return nested
            }
        }
        for key in ["creators", "creator", "artists"] {
            if let nested = array(value, key).lazy.compactMap({
                firstString($0, keys: ["nickname", "name", "userName"])
            }).first {
                return nested
            }
        }
        return ""
    }

    private static func firstString(_ value: [String: Any], keys: [String]) -> String? {
        keys.lazy
            .map { string(value, $0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }

    private static func milliseconds(_ value: Any?) -> Int64? {
        let result = (value as? NSNumber)?.int64Value ?? (value as? String).flatMap(Int64.init)
        return result.flatMap { $0 > 0 ? $0 : nil }
    }

    private static func object(_ value: [String: Any], _ key: String) -> [String: Any] {
        value[key] as? [String: Any] ?? [:]
    }

    private static func array(_ value: [String: Any], _ key: String) -> [[String: Any]] {
        value[key] as? [[String: Any]] ?? []
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
}
