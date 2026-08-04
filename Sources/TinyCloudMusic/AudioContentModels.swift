import Foundation

struct PodcastCategory: Identifiable, Equatable, Sendable {
    let id: Int64
    let name: String
}

struct Podcast: Identifiable, Equatable, Sendable {
    let id: Int64
    let name: String
    let hostName: String
    let coverURL: URL?
    let categoryName: String
    let isSubscribed: Bool
    let description: String
    let episodeCount: Int
    let coverImageID: Int64
    let categoryID: Int64
    let secondCategoryID: Int64
    let isPrivate: Bool

    init(
        id: Int64,
        name: String,
        hostName: String,
        coverURL: URL?,
        categoryName: String,
        isSubscribed: Bool,
        description: String = "",
        episodeCount: Int = 0,
        coverImageID: Int64 = 0,
        categoryID: Int64 = 0,
        secondCategoryID: Int64 = 0,
        isPrivate: Bool = false
    ) {
        self.id = id
        self.name = name
        self.hostName = hostName
        self.coverURL = coverURL
        self.categoryName = categoryName
        self.isSubscribed = isSubscribed
        self.description = description
        self.episodeCount = episodeCount
        self.coverImageID = coverImageID
        self.categoryID = categoryID
        self.secondCategoryID = secondCategoryID
        self.isPrivate = isPrivate
    }

    func settingSubscribed(_ subscribed: Bool) -> Self {
        Self(
            id: id,
            name: name,
            hostName: hostName,
            coverURL: coverURL,
            categoryName: categoryName,
            isSubscribed: subscribed,
            description: description,
            episodeCount: episodeCount,
            coverImageID: coverImageID,
            categoryID: categoryID,
            secondCategoryID: secondCategoryID,
            isPrivate: isPrivate
        )
    }
}

struct PodcastEpisode: Identifiable, Equatable, Sendable {
    let id: Int64
    let podcastID: Int64
    let title: String
    let coverURL: URL?
    let durationMilliseconds: Int64
    let publishedAt: Date?
    let song: Song?
    let podcastName: String
    let hostName: String
    let description: String
    let unavailableReason: String?

    init(
        id: Int64,
        podcastID: Int64,
        title: String,
        coverURL: URL?,
        durationMilliseconds: Int64,
        publishedAt: Date?,
        song: Song?,
        podcastName: String = "",
        hostName: String = "",
        description: String = "",
        unavailableReason: String? = nil
    ) {
        self.id = id
        self.podcastID = podcastID
        self.title = title
        self.coverURL = coverURL
        self.durationMilliseconds = durationMilliseconds
        self.publishedAt = publishedAt
        self.song = song.map {
            var song = $0
            song.podcastEpisodeID = id
            return song
        }
        self.podcastName = podcastName
        self.hostName = hostName
        self.description = description
        self.unavailableReason = unavailableReason
    }

    var durationText: String {
        let seconds = max(0, durationMilliseconds / 1_000)
        return String(format: "%lld:%02lld", seconds / 60, seconds % 60)
    }
}

struct PodcastPage: Equatable, Sendable {
    let podcasts: [Podcast]
    let nextOffset: Int
    let hasMore: Bool

    func appending(_ next: Self) -> Self {
        var ids = Set(podcasts.map(\.id))
        let additions = next.podcasts.filter { ids.insert($0.id).inserted }
        let progressed = next.nextOffset > nextOffset
        return Self(
            podcasts: podcasts + additions,
            nextOffset: max(nextOffset, next.nextOffset),
            hasMore: next.hasMore && progressed && !additions.isEmpty
        )
    }
}

struct PodcastEpisodePage: Equatable, Sendable {
    let episodes: [PodcastEpisode]
    let nextOffset: Int
    let hasMore: Bool

    func appending(_ next: Self) -> Self {
        var ids = Set(episodes.map(\.id))
        let additions = next.episodes.filter { ids.insert($0.id).inserted }
        let progressed = next.nextOffset > nextOffset
        return Self(
            episodes: episodes + additions,
            nextOffset: max(nextOffset, next.nextOffset),
            hasMore: next.hasMore && progressed && !additions.isEmpty
        )
    }
}

struct BroadcastFilter: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
}

struct BroadcastFilters: Equatable, Sendable {
    let categories: [BroadcastFilter]
    let regions: [BroadcastFilter]
}

struct BroadcastChannel: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let regionName: String
    let coverURL: URL?
    let isCollected: Bool
    let description: String

    init(
        id: String,
        name: String,
        regionName: String,
        coverURL: URL?,
        isCollected: Bool,
        description: String = ""
    ) {
        self.id = id
        self.name = name
        self.regionName = regionName
        self.coverURL = coverURL
        self.isCollected = isCollected
        self.description = description
    }

    func settingCollected(_ collected: Bool) -> Self {
        Self(
            id: id,
            name: name,
            regionName: regionName,
            coverURL: coverURL,
            isCollected: collected,
            description: description
        )
    }
}

struct BroadcastCursor: Hashable, Sendable {
    static let initial = Self(lastID: "0", score: "-1")

    let lastID: String
    let score: String
}

struct BroadcastChannelPage: Equatable, Sendable {
    let channels: [BroadcastChannel]
    let nextCursor: BroadcastCursor
    let hasMore: Bool
    private let seenCursors: Set<BroadcastCursor>

    init(
        channels: [BroadcastChannel],
        nextCursor: BroadcastCursor,
        hasMore: Bool,
        seenCursors: Set<BroadcastCursor> = []
    ) {
        self.channels = channels
        self.nextCursor = nextCursor
        self.hasMore = hasMore
        self.seenCursors = seenCursors.union([nextCursor])
    }

    func appending(_ next: Self) -> Self {
        var ids = Set(channels.map(\.id))
        let additions = next.channels.filter { ids.insert($0.id).inserted }
        let progressed = next.nextCursor != nextCursor
        let cycles = seenCursors.contains(next.nextCursor)
        return Self(
            channels: channels + additions,
            nextCursor: progressed && !cycles ? next.nextCursor : nextCursor,
            hasMore: next.hasMore && progressed && !cycles && !additions.isEmpty,
            seenCursors: seenCursors.union(next.seenCursors)
        )
    }
}

enum PodcastEpisodeEndpointFallback {
    static func shouldFallback(after error: Error) -> Bool {
        guard let error = error as? EAPIError else { return false }
        switch error {
        case .http(404), .http(410), .service(code: 404, _), .service(code: 410, _):
            return true
        case .missingData("program"):
            return true
        default:
            return false
        }
    }

    static func load(
        primary: () async throws -> PodcastEpisode,
        fallback: () async throws -> PodcastEpisode
    ) async throws -> PodcastEpisode {
        do {
            return try await primary()
        } catch {
            guard shouldFallback(after: error) else { throw error }
            return try await fallback()
        }
    }
}

enum PodcastLyricLocator {
    static func currentLineID(
        in lines: [LyricLine],
        at milliseconds: Int64,
        lookup: ([LyricLine], Int64) -> Int? = { LRCParser.currentLineIndex(in: $0, at: $1) }
    ) -> Int64? {
        guard let index = lookup(lines, milliseconds), lines.indices.contains(index) else { return nil }
        return lines[index].id
    }
}

struct BroadcastCurrentInfo: Equatable, Sendable {
    let channel: BroadcastChannel
    let currentProgramTitle: String
    let currentProgramDescription: String
    let streamURL: URL?
}

enum AudioContentError: LocalizedError, Equatable, Sendable {
    case unavailable(String)
    case unsafeStreamURL

    var errorDescription: String? {
        switch self {
        case let .unavailable(message): message
        case .unsafeStreamURL: "直播地址未通过安全校验"
        }
    }
}

enum BroadcastStreamURLPolicy {
    static func playableURL(_ value: String) async throws -> URL {
        let url = preferredPlaybackURL(try validate(value))
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        request.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        do {
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            guard let response = response as? HTTPURLResponse,
                  isPlayableResponse(statusCode: response.statusCode, mimeType: response.mimeType),
                  try await bytes.first(where: { _ in true }) != nil
            else { throw AudioContentError.unavailable("当前频道直播源不可用") }
            return url
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled && Task.isCancelled {
            throw CancellationError()
        } catch let error as AudioContentError {
            throw error
        } catch {
            throw AudioContentError.unavailable("无法连接直播源，请稍后重试")
        }
    }

    static func isPlayableResponse(statusCode: Int, mimeType: String?) -> Bool {
        (200..<300).contains(statusCode) && mimeType?.lowercased() != "text/html"
    }

    static func preferredPlaybackURL(_ url: URL) -> URL {
        guard url.host?.lowercased() == "ls-open.qingting.fm",
              url.pathExtension.lowercased() == "m3u8",
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return url }
        components.host = "lhttp.qtfm.cn"
        components.path = String(components.path.dropLast(4)) + "mp3"
        return components.url ?? url
    }

    static func validate(_ value: String) throws -> URL {
        guard var components = URLComponents(string: value),
              components.user == nil,
              components.password == nil,
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              isTrustedHost(components.host)
        else {
            throw AudioContentError.unsafeStreamURL
        }
        components.scheme = "https"
        guard let url = components.url, isAllowed(url) else {
            throw AudioContentError.unsafeStreamURL
        }
        return url
    }

    static func isAllowed(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https",
              url.user == nil,
              url.password == nil,
              isTrustedHost(url.host)
        else { return false }
        return true
    }

    private static func isTrustedHost(_ value: String?) -> Bool {
        guard let host = value?.lowercased() else { return false }
        return host == "music.126.net" || host.hasSuffix(".music.126.net")
            || host == "music.163.com" || host.hasSuffix(".music.163.com")
            || host == "qtfm.cn" || host.hasSuffix(".qtfm.cn")
            || host == "qingting.fm" || host.hasSuffix(".qingting.fm")
    }
}

enum AudioContentDecoder {
    static func podcastCategories(_ root: [String: Any]) -> [PodcastCategory] {
        let data = root.object("data")
        let values = firstArray(in: [root, data], keys: ["categories", "categoryList", "list"])
        var ids = Set<Int64>()
        return values.compactMap { value in
            let id = firstInt64(value, keys: ["id", "categoryId", "cateId"])
            let name = firstString(value, keys: ["name", "categoryName"])
            guard id > 0, !name.isEmpty, ids.insert(id).inserted else { return nil }
            return PodcastCategory(id: id, name: name)
        }
    }

    static func podcasts(_ root: [String: Any]) -> [Podcast] {
        let data = root.object("data")
        return firstArray(in: [root, data], keys: ["djRadios", "radios", "podcasts", "voiceLists", "voicelists", "list"])
            .compactMap(decodePodcast)
    }

    static func podcast(_ root: [String: Any]) -> Podcast? {
        let data = root.object("data")
        for value in [
            root.object("djRadio"), root.object("radio"), root.object("voiceList"),
            data.object("djRadio"), data.object("radio"), data.object("voiceList"), data
        ] {
            if let result = decodePodcast(value) { return result }
        }
        return nil
    }

    static func episodePage(
        _ root: [String: Any],
        podcastID: Int64,
        offset: Int,
        limit: Int,
        decodeSong: ([String: Any]) -> Song?
    ) -> PodcastEpisodePage {
        let data = root.object("data")
        let values = firstArray(in: [root, data], keys: ["programs", "episodes", "list"])
        let episodes = values.compactMap {
            decodeEpisode($0, podcastID: podcastID, decodeSong: decodeSong)
        }
        let uniqueEpisodes = deduplicated(episodes)
        let explicitMore = firstBool(in: [root, data], keys: ["more", "hasMore"])
        return PodcastEpisodePage(
            episodes: uniqueEpisodes,
            nextOffset: offset + values.count,
            hasMore: (explicitMore ?? (values.count == limit)) && !uniqueEpisodes.isEmpty
        )
    }

    static func podcastPage(_ root: [String: Any], offset: Int, limit: Int) -> PodcastPage {
        let data = root.object("data")
        let values = firstArray(in: [root, data], keys: ["djRadios", "radios", "podcasts", "voiceLists", "voicelists", "list"])
        let decoded = values.compactMap(decodePodcast)
        let uniquePodcasts = deduplicated(decoded)
        let explicitMore = firstBool(in: [root, data], keys: ["more", "hasMore"])
        return PodcastPage(
            podcasts: uniquePodcasts,
            nextOffset: offset + values.count,
            hasMore: (explicitMore ?? (values.count == limit)) && !uniquePodcasts.isEmpty
        )
    }

    static func episode(
        _ root: [String: Any],
        podcastID: Int64 = 0,
        decodeSong: ([String: Any]) -> Song?
    ) -> PodcastEpisode? {
        let data = root.object("data")
        for value in [root.object("program"), data.object("program"), data.object("voice"), data] {
            if let result = decodeEpisode(value, podcastID: podcastID, decodeSong: decodeSong) { return result }
        }
        return nil
    }

    static func voiceLyrics(_ root: [String: Any]) -> SongLyrics {
        let data = root.object("data")
        return SongLyrics(
            lineLyrics: firstLyric(in: [data, root], keys: ["lrc", "lyric", "yrc"]),
            translatedLyrics: nonempty(firstLyric(in: [data, root], keys: ["tlyric", "translatedLyric"])),
            romanizedLyrics: nonempty(firstLyric(in: [data, root], keys: ["romalrc", "romanizedLyric"])),
            wordLyrics: nonempty(firstLyric(in: [data, root], keys: ["yrc"])),
            translatedWordLyrics: nonempty(firstLyric(in: [data, root], keys: ["ytlrc"])),
            romanizedWordLyrics: nonempty(firstLyric(in: [data, root], keys: ["yromalrc"]))
        )
    }

    static func broadcastFilters(_ root: [String: Any]) -> BroadcastFilters {
        let data = root.object("data")
        return BroadcastFilters(
            categories: broadcastFilters(in: [root, data], keys: ["categories", "categoryList", "category"]),
            regions: broadcastFilters(in: [root, data], keys: ["regions", "regionList", "region"])
        )
    }

    static func broadcastChannelPage(
        _ root: [String: Any],
        currentCursor: BroadcastCursor,
        limit: Int
    ) -> BroadcastChannelPage {
        let data = root.object("data")
        let page = data.object("page")
        let values = firstArray(in: [root, data], keys: ["channels", "channelList", "list"])
        let channels = values.compactMap(broadcastChannel)
        let next = BroadcastCursor(
            lastID: firstString(in: [page, data, root], keys: ["lastId", "lastID"]),
            score: firstString(in: [page, data, root], keys: ["score"])
        )
        let hasServerCursor = !next.lastID.isEmpty && !next.score.isEmpty && next != currentCursor
        let explicitMore = firstBool(in: [page, data, root], keys: ["more", "hasMore"])
        return BroadcastChannelPage(
            channels: deduplicated(channels),
            nextCursor: hasServerCursor ? next : currentCursor,
            hasMore: hasServerCursor && (explicitMore ?? (values.count == limit)),
            seenCursors: [currentCursor]
        )
    }

    static func broadcastCurrentInfo(
        _ root: [String: Any],
        channelID: String
    ) throws -> BroadcastCurrentInfo {
        let data = root.object("data")
        let current = data.object("currentInfo").isEmpty ? data : data.object("currentInfo")
        let channel = broadcastChannel(current.object("channel"))
            ?? broadcastChannel(data.object("channel"))
            ?? broadcastChannel(current)
            ?? BroadcastChannel(id: channelID, name: "广播频道", regionName: "", coverURL: nil, isCollected: false)
        let program = [current.object("program"), current.object("currentProgram"), data.object("program")]
            .first { !$0.isEmpty } ?? [:]
        let rawURL = firstString(in: [current.object("playInfo"), current, data, root], keys: [
            "playUrl", "streamUrl", "liveUrl", "url"
        ])
        return BroadcastCurrentInfo(
            channel: channel,
            currentProgramTitle: firstString(in: [program, current], keys: ["title", "name", "programName"]),
            currentProgramDescription: firstString(in: [program, current], keys: ["description", "desc", "introduction"]),
            streamURL: rawURL.isEmpty ? nil : URL(string: rawURL)
        )
    }

    private static func decodePodcast(_ source: [String: Any]) -> Podcast? {
        let value = if !source.object("djRadio").isEmpty {
            source.object("djRadio")
        } else if !source.object("voiceList").isEmpty {
            source.object("voiceList")
        } else {
            source
        }
        let id = firstInt64(value, keys: ["id", "radioId", "djRadioId"])
        guard id > 0 else { return nil }
        let host = [value.object("dj"), value.object("creator"), value.object("host")]
            .first { !$0.isEmpty } ?? [:]
        return Podcast(
            id: id,
            name: firstString(value, keys: ["name", "title"]),
            hostName: firstString(in: [host, value], keys: ["nickname", "name", "hostName"]),
            coverURL: firstURL(value, keys: ["picUrl", "coverUrl", "coverImgUrl"]),
            categoryName: firstString(value, keys: ["category", "categoryName", "secondCategory"]),
            isSubscribed: bool(value, keys: ["subed", "subscribed", "isSubscribed"]),
            description: firstString(value, keys: ["desc", "description"]),
            episodeCount: firstInt(value, keys: ["programCount", "episodeCount", "count"]),
            coverImageID: firstInt64(value, keys: ["picId", "coverImgId", "coverImageId"]),
            categoryID: firstInt64(value, keys: ["categoryId", "categoryID", "cateId"]),
            secondCategoryID: firstInt64(value, keys: ["secondCategoryId", "secondCategoryID", "secondCateId"]),
            isPrivate: bool(value, keys: ["privacy", "private", "isPrivate"])
        )
    }

    private static func decodeEpisode(
        _ source: [String: Any],
        podcastID: Int64,
        decodeSong: ([String: Any]) -> Song?
    ) -> PodcastEpisode? {
        let value = source.object("program").isEmpty ? source : source.object("program")
        let id = firstInt64(value, keys: ["id", "programId", "voiceId"])
        guard id > 0 else { return nil }
        let radio = [value.object("radio"), value.object("djRadio"), value.object("podcast")]
            .first { !$0.isEmpty } ?? [:]
        let songValue = [value.object("mainSong"), value.object("song")].first { !$0.isEmpty } ?? [:]
        let host = [value.object("dj"), radio.object("dj"), radio.object("creator"), songValue.array("ar").first ?? [:]]
            .first { !$0.isEmpty } ?? [:]
        let decodedSong = songValue.isEmpty ? nil : decodeSong(songValue)
        let coverURL = firstURL(value, keys: ["coverUrl", "coverImgUrl", "blurCoverUrl"])
            ?? firstURL(radio, keys: ["picUrl", "coverUrl"])
            ?? decodedSong?.album.artwork.remoteURL
        let song = decodedSong.map { song in
            guard let coverURL, song.album.artwork.remoteURL != coverURL else { return song }
            return Song(
                id: song.id,
                name: song.primaryName,
                artists: song.artists,
                album: AlbumSummary(
                    id: song.album.id,
                    name: song.album.name,
                    artwork: Artwork(
                        symbol: song.album.artwork.symbol,
                        accent: song.album.artwork.accent,
                        remoteURL: coverURL
                    )
                ),
                duration: song.duration,
                translatedName: song.translatedName,
                aliasName: song.aliasName
            )
        }
        let reason = firstString(value, keys: ["reason", "unavailableReason", "message"])
        return PodcastEpisode(
            id: id,
            podcastID: firstInt64(radio, keys: ["id", "radioId"]).nonzero ?? podcastID,
            title: firstString(value, keys: ["name", "title"]),
            coverURL: coverURL,
            durationMilliseconds: firstInt64(value, keys: ["duration", "durationMilliseconds", "durationMs"])
                .nonzero ?? firstInt64(songValue, keys: ["dt", "duration"]),
            publishedAt: millisecondsDate(value, keys: ["createTime", "publishTime", "publishedAt"]),
            song: song,
            podcastName: firstString(in: [radio, songValue.object("al")], keys: ["name", "title"]),
            hostName: firstString(in: [host, value], keys: ["nickname", "name", "hostName"]),
            description: firstString(value, keys: ["description", "desc", "introduction"]),
            unavailableReason: nonempty(reason)
        )
    }

    private static func broadcastChannel(_ source: [String: Any]) -> BroadcastChannel? {
        let value = source.object("channel").isEmpty ? source : source.object("channel")
        let id = firstString(value, keys: ["channelId", "id"])
        guard !id.isEmpty else { return nil }
        let region = value.object("region")
        return BroadcastChannel(
            id: id,
            name: firstString(value, keys: ["channelName", "name", "title"]),
            regionName: firstString(in: [region, value], keys: ["regionName", "name"]),
            coverURL: firstURL(value, keys: ["coverUrl", "coverImgUrl", "picUrl"]),
            isCollected: bool(value, keys: ["collected", "isCollected", "subed"]),
            description: firstString(value, keys: ["description", "desc"])
        )
    }

    private static func broadcastFilters(in objects: [[String: Any]], keys: [String]) -> [BroadcastFilter] {
        var ids = Set<String>()
        return firstArray(in: objects, keys: keys).compactMap { value in
            let id = firstString(value, keys: ["id", "categoryId", "regionId", "value"])
            let name = firstString(value, keys: ["name", "categoryName", "regionName", "label"])
            guard !id.isEmpty, !name.isEmpty, ids.insert(id).inserted else { return nil }
            return BroadcastFilter(id: id, name: name)
        }
    }

    private static func firstArray(in objects: [[String: Any]], keys: [String]) -> [[String: Any]] {
        for object in objects {
            for key in keys {
                let values = object.array(key)
                if !values.isEmpty { return values }
            }
        }
        return []
    }

    private static func firstString(in objects: [[String: Any]], keys: [String]) -> String {
        objects.lazy.map { firstString($0, keys: keys) }.first { !$0.isEmpty } ?? ""
    }

    private static func firstString(_ value: [String: Any], keys: [String]) -> String {
        keys.lazy.map { value.string($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? ""
    }

    private static func firstInt64(_ value: [String: Any], keys: [String]) -> Int64 {
        keys.lazy.map { value.int64($0) }.first { $0 != 0 } ?? 0
    }

    private static func firstInt(_ value: [String: Any], keys: [String]) -> Int {
        keys.lazy.map { value.int($0) }.first { $0 != 0 } ?? 0
    }

    private static func firstURL(_ value: [String: Any], keys: [String]) -> URL? {
        keys.lazy.compactMap { key in
            guard let rawURL = URL(string: value.string(key)) else { return nil }
            let url = ArtworkURLPolicy.secureURL(for: rawURL)
            return isAllowedArtwork(url) ? url : nil
        }.first
    }

    private static func isAllowedArtwork(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased() else { return false }
        return host == "music.126.net" || host.hasSuffix(".music.126.net")
            || host == "music.163.com" || host.hasSuffix(".music.163.com")
    }

    private static func bool(_ value: [String: Any], keys: [String]) -> Bool {
        for key in keys where value[key] != nil {
            if let string = value[key] as? String {
                return ["1", "true", "yes"].contains(string.lowercased())
            }
            return value.bool(key)
        }
        return false
    }

    private static func firstBool(in objects: [[String: Any]], keys: [String]) -> Bool? {
        for object in objects {
            for key in keys where object[key] != nil {
                if let string = object[key] as? String {
                    return ["1", "true", "yes"].contains(string.lowercased())
                }
                return object.bool(key)
            }
        }
        return nil
    }

    private static func firstLyric(in objects: [[String: Any]], keys: [String]) -> String {
        for object in objects {
            for key in keys {
                let nested = object.object(key).string("lyric")
                if !nested.isEmpty { return nested }
                let direct = object.string(key)
                if !direct.isEmpty { return direct }
            }
        }
        return ""
    }

    private static func millisecondsDate(_ value: [String: Any], keys: [String]) -> Date? {
        let milliseconds = firstInt64(value, keys: keys)
        return milliseconds > 0 ? Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1_000) : nil
    }

    private static func nonempty(_ value: String) -> String? { value.isEmpty ? nil : value }

    private static func deduplicated<T: Identifiable>(_ values: [T]) -> [T] where T.ID: Hashable {
        var ids = Set<T.ID>()
        return values.filter { ids.insert($0.id).inserted }
    }
}

private extension Int64 {
    var nonzero: Self? { self == 0 ? nil : self }
}
