import Foundation

enum PlaybackAvailability: Equatable, Sendable {
    case playable(level: String)
    case trial(level: String, endSeconds: Int?)
    case unavailable(reason: String)

    var level: String? {
        switch self {
        case let .playable(level), let .trial(level, _): level
        case .unavailable: nil
        }
    }
}

struct PlaybackSource: Equatable, Sendable {
    let url: URL
    let availability: PlaybackAvailability
}

struct SongQualityDetail: Identifiable, Equatable, Sendable {
    static let orderedLevels = [
        "standard", "higher", "exhigh", "lossless", "hires",
        "jyeffect", "dolby", "sky", "jymaster"
    ]

    let id: String
    let bitrate: Int
    let size: Int64
    let sampleRate: Int
    let isAvailable: Bool

    var rank: Int { Self.orderedLevels.firstIndex(of: id) ?? -1 }

    static func highestAvailableLevel(in qualities: [Self]) -> String? {
        qualities
            .filter(\.isAvailable)
            .max { $0.rank < $1.rank }?
            .id
    }

    static func displayName(for id: String) -> String {
        switch id {
        case "standard": "标准"
        case "higher": "较高"
        case "exhigh": "极高"
        case "lossless": "无损"
        case "hires": "Hi-Res"
        case "jyeffect": "高清环绕声"
        case "sky": "沉浸环绕声"
        case "dolby": "杜比全景声"
        case "jymaster": "超清母带"
        default: id
        }
    }

    var name: String { Self.displayName(for: id) }
}

struct PlaybackUnavailableError: LocalizedError, Equatable, Sendable {
    let reason: String
    let alternatives: [Song]

    var errorDescription: String? { reason }
}

enum PlaybackHistoryKind: Equatable, Sendable {
    case song
    case podcast
}

struct PlaybackHistoryEvent: Equatable, Sendable {
    let sequence: UInt64
    let credentialRevision: UInt64
    let kind: PlaybackHistoryKind
}

protocol MusicRepository: Sendable {
    var homeDescriptors: [HomeSectionDescriptor] { get }
    var currentCredentialRevision: UInt64 { get }
    func homeSection(
        id: String,
        expectedCredentialRevision: UInt64
    ) async throws -> HomeSection
    func search(query: String, scope: SearchScope, offset: Int, limit: Int) async throws -> SearchPage
    func detail(
        for route: Route,
        expectedCredentialRevision: UInt64?
    ) async throws -> DetailContent
    func songs(ids: [Int64]) async throws -> [Song]
    func lyrics(for songID: Int64) async throws -> SongLyrics
    func playbackSource(for songID: Int64, quality: AudioQuality) async throws -> PlaybackSource
    func playbackSource(for songID: Int64, level: String) async throws -> PlaybackSource
    func songQualityDetails(for songID: Int64) async throws -> [SongQualityDetail]
    func heartModeSongs(seedSongID: Int64, playlistID: Int64?, startSongID: Int64) async throws -> [Song]
    func recordPlaybackStart(
        for songID: Int64,
        sourceID: Int64,
        totalSeconds: Int,
        expectedCredentialRevision: UInt64
    ) async throws
    func recordPlayback(
        for songID: Int64,
        sourceID: Int64,
        playedSeconds: Int,
        totalSeconds: Int,
        expectedCredentialRevision: UInt64
    ) async throws
    func recordPodcastPlayback(
        for episodeID: Int64,
        positionMilliseconds: Int,
        completed: Bool,
        expectedCredentialRevision: UInt64
    ) async throws
}

extension MusicRepository {
    var currentCredentialRevision: UInt64 { 0 }

    func detail(for route: Route) async throws -> DetailContent {
        try await detail(for: route, expectedCredentialRevision: nil)
    }

    func audioURL(for songID: Int64, quality: AudioQuality) async throws -> URL {
        try await playbackSource(for: songID, quality: quality).url
    }

    func audioURL(for songID: Int64) async throws -> URL {
        try await audioURL(for: songID, quality: .standard)
    }

    func heartModeSongs(seedSongID: Int64, playlistID: Int64?, startSongID: Int64) async throws -> [Song] {
        throw AppError.unavailable("心动模式暂时不可用")
    }
}

struct AuthorizedTransportRequest: Sendable {
    let url: URL
    let method: String
    let headers: [String: String]
    let body: Data?
}

struct AuthorizedTransportResponse: Sendable {
    let statusCode: Int
    let headers: [String: String]
    let body: Data
}

// A live implementation belongs behind the documented authorization and security gate.
protocol AuthorizedMusicTransport: Sendable {
    func send(_ request: AuthorizedTransportRequest) async throws -> AuthorizedTransportResponse
}

struct FixtureMusicRepository: MusicRepository {
    let homeDescriptors = [
        HomeSectionDescriptor(id: "daily", title: "今日推荐"),
        HomeSectionDescriptor(id: "moods", title: "心情与场景"),
        HomeSectionDescriptor(id: "new", title: "新鲜发行")
    ]

    func homeSection(
        id: String,
        expectedCredentialRevision: UInt64
    ) async throws -> HomeSection {
        try await Task.sleep(for: .milliseconds(id == "daily" ? 140 : id == "moods" ? 260 : 380))
        switch id {
        case "daily":
            return HomeSection(
                id: id,
                title: "今日推荐",
                subtitle: "从熟悉的旋律开始",
                items: Fixture.songs.prefix(6).map { .song($0, subtitle: nil) }
            )
        case "moods":
            return HomeSection(
                id: id,
                title: "心情与场景",
                subtitle: "工作、夜晚和远行",
                items: Fixture.playlists.map {
                    .destination(
                        id: $0.id,
                        title: $0.name,
                        subtitle: $0.creator,
                        artwork: $0.artwork,
                        route: .playlist($0.id)
                    )
                }
            )
        case "new":
            return HomeSection(
                id: id,
                title: "新鲜发行",
                subtitle: "本周值得完整听完的作品",
                items: Fixture.albums.map {
                    .destination(
                        id: $0.id,
                        title: $0.name,
                        subtitle: $0.artist.name,
                        artwork: $0.artwork,
                        route: .album($0.id)
                    )
                }
            )
        default:
            throw AppError.unavailable("这个栏目暂时不可用")
        }
    }

    func search(query: String, scope: SearchScope, offset: Int, limit: Int) async throws -> SearchPage {
        try await Task.sleep(for: .milliseconds(240))
        let matches: [SearchItem]
        switch scope {
        case .songs:
            matches = Fixture.songs.filter {
                $0.name.localizedCaseInsensitiveContains(query)
                    || $0.artistsDisplay.localizedCaseInsensitiveContains(query)
                    || $0.album.name.localizedCaseInsensitiveContains(query)
            }.map(SearchItem.song)
        case .artists:
            matches = Fixture.artists.filter {
                $0.name.localizedCaseInsensitiveContains(query)
                    || $0.biography.localizedCaseInsensitiveContains(query)
            }.map(SearchItem.artist)
        case .albums:
            matches = Fixture.albums.filter {
                $0.name.localizedCaseInsensitiveContains(query)
                    || $0.artist.name.localizedCaseInsensitiveContains(query)
            }.map(SearchItem.album)
        case .playlists:
            matches = Fixture.playlists.filter {
                $0.name.localizedCaseInsensitiveContains(query)
                    || $0.description.localizedCaseInsensitiveContains(query)
            }.map(SearchItem.playlist)
        case .users:
            matches = Fixture.users.filter {
                $0.nickname.localizedCaseInsensitiveContains(query)
                    || $0.signature.localizedCaseInsensitiveContains(query)
            }.map(SearchItem.user)
        case .mvs, .videos:
            matches = []
        }

        let start = min(offset, matches.count)
        let end = min(start + limit, matches.count)
        return SearchPage(items: Array(matches[start..<end]), offset: start, hasMore: end < matches.count)
    }

    func detail(
        for route: Route,
        expectedCredentialRevision: UInt64?
    ) async throws -> DetailContent {
        try await Task.sleep(for: .milliseconds(180))
        switch route {
        case let .artist(id):
            guard let artist = Fixture.artists.first(where: { $0.id == id }) else { throw AppError.invalidRoute }
            return .artist(artist, songs: Fixture.songs.filter { $0.artists.contains { $0.id == id } })
        case let .album(id):
            guard let album = Fixture.albums.first(where: { $0.id == id }) else { throw AppError.invalidRoute }
            return .album(album, songs: Fixture.songs.filter { $0.album.id == id })
        case let .playlist(id):
            guard let playlist = Fixture.playlists.first(where: { $0.id == id }) else { throw AppError.invalidRoute }
            let start = Int(id % Int64(max(Fixture.songs.count - 4, 1)))
            let songs = Array(Fixture.songs[start..<min(start + 5, Fixture.songs.count)])
            return .playlist(playlist, songs: songs, trackIDs: songs.map(\.id), loadedTrackCount: songs.count)
        case let .user(id):
            guard let user = Fixture.users.first(where: { $0.id == id }) else { throw AppError.invalidRoute }
            return .user(user, playlists: Array(Fixture.playlists.prefix(3)), hasMore: false)
        case .home, .search, .cloudMusic, .comments, .similarSongs, .recommendationHistory, .listeningFootprints,
             .mv, .video, .podcast, .podcastEpisode, .broadcast, .podcastSubscriptions,
             .musicStyles, .musicStyle:
            throw AppError.invalidRoute
        }
    }

    func songs(ids: [Int64]) async throws -> [Song] {
        let songsByID = Dictionary(uniqueKeysWithValues: Fixture.songs.map { ($0.id, $0) })
        return ids.compactMap { songsByID[$0] }
    }

    func lyrics(for songID: Int64) async throws -> SongLyrics {
        try await Task.sleep(for: .milliseconds(120))
        let title = Fixture.songs.first(where: { $0.id == songID })?.name ?? "这一首歌"
        return SongLyrics(
            lineLyrics: "[00:00.00]\(title)\n[00:08.5]风从城市的边缘经过\n[00:16.25]灯火把夜色写成河\n[00:24.125]我们在旋律里重逢",
            translatedLyrics: "[00:08.500]The wind passes the edge of town\n[00:16.250]Lights turn the night into a river"
        )
    }

    func playbackSource(for songID: Int64, quality: AudioQuality) async throws -> PlaybackSource {
        throw AppError.unavailable("演示数据不包含音频")
    }

    func playbackSource(for songID: Int64, level: String) async throws -> PlaybackSource {
        throw AppError.unavailable("演示数据不包含音频")
    }

    func songQualityDetails(for songID: Int64) async throws -> [SongQualityDetail] {
        throw AppError.unavailable("演示数据不包含音质信息")
    }

    func recordPlaybackStart(
        for songID: Int64,
        sourceID: Int64,
        totalSeconds: Int,
        expectedCredentialRevision: UInt64
    ) async throws {}

    func recordPlayback(
        for songID: Int64,
        sourceID: Int64,
        playedSeconds: Int,
        totalSeconds: Int,
        expectedCredentialRevision: UInt64
    ) async throws {}

    func recordPodcastPlayback(
        for episodeID: Int64,
        positionMilliseconds: Int,
        completed: Bool,
        expectedCredentialRevision: UInt64
    ) async throws {}
}

private enum Fixture {
    static let artistSummaries = [
        ArtistSummary(id: 101, name: "林屿"),
        ArtistSummary(id: 102, name: "北岸乐队"),
        ArtistSummary(id: 103, name: "周末电台"),
        ArtistSummary(id: 104, name: "雾岚")
    ]

    static let albums = [
        Album(id: 201, name: "夜航手册", artist: artistSummaries[0], description: "一张写给夜路、海风和未读消息的城市民谣专辑。", artwork: Artwork(symbol: "moon.stars.fill", accent: .blue)),
        Album(id: 202, name: "候鸟来信", artist: artistSummaries[1], description: "从公路摇滚到安静尾奏，记录一次向北的远行。", artwork: Artwork(symbol: "bird.fill", accent: .orange)),
        Album(id: 203, name: "星期六频率", artist: artistSummaries[2], description: "轻盈合成器与松弛节拍组成的周末播放清单。", artwork: Artwork(symbol: "radio.fill", accent: .pink)),
        Album(id: 204, name: "山中回声", artist: artistSummaries[3], description: "采样自然环境声，把山谷、雨水和呼吸写进音乐。", artwork: Artwork(symbol: "mountain.2.fill", accent: .green))
    ]

    static let songs: [Song] = [
        Song(id: 1, name: "夜航", artists: [artistSummaries[0]], album: summary(albums[0]), duration: .seconds(224)),
        Song(id: 2, name: "凌晨四点的桥", artists: [artistSummaries[0]], album: summary(albums[0]), duration: .seconds(196)),
        Song(id: 3, name: "候鸟来信", artists: [artistSummaries[1]], album: summary(albums[1]), duration: .seconds(247)),
        Song(id: 4, name: "向北十公里", artists: [artistSummaries[1]], album: summary(albums[1]), duration: .seconds(213)),
        Song(id: 5, name: "周末气象", artists: [artistSummaries[2]], album: summary(albums[2]), duration: .seconds(188)),
        Song(id: 6, name: "关掉闹钟", artists: [artistSummaries[2]], album: summary(albums[2]), duration: .seconds(205)),
        Song(id: 7, name: "雾起时", artists: [artistSummaries[3]], album: summary(albums[3]), duration: .seconds(231)),
        Song(id: 8, name: "松林回声", artists: [artistSummaries[3]], album: summary(albums[3]), duration: .seconds(258)),
        Song(id: 9, name: "沿海公路", artists: [artistSummaries[0], artistSummaries[1]], album: summary(albums[1]), duration: .seconds(239))
    ]

    static let artists = [
        Artist(id: 101, name: "林屿", biography: "城市民谣 · 细腻的人声与吉他", artwork: Artwork(symbol: "guitars.fill", accent: .blue)),
        Artist(id: 102, name: "北岸乐队", biography: "独立摇滚 · 公路感与宽阔编曲", artwork: Artwork(symbol: "wave.3.right", accent: .orange)),
        Artist(id: 103, name: "周末电台", biography: "电子流行 · 松弛而明亮的节拍", artwork: Artwork(symbol: "dot.radiowaves.left.and.right", accent: .pink)),
        Artist(id: 104, name: "雾岚", biography: "氛围音乐 · 自然采样与钢琴", artwork: Artwork(symbol: "cloud.fog.fill", accent: .green))
    ]

    static let playlists = [
        Playlist(id: 301, name: "深夜仍然清醒", creator: "听风的人", description: "适合独自工作和深夜阅读的安静旋律。", artwork: Artwork(symbol: "sparkles", accent: .blue), trackCount: 5),
        Playlist(id: 302, name: "沿海公路", creator: "北纬 31°", description: "开窗、海风，以及保持匀速前进的鼓点。", artwork: Artwork(symbol: "car.side.fill", accent: .cyan), trackCount: 5),
        Playlist(id: 303, name: "周末慢半拍", creator: "小云音乐编辑部", description: "不赶时间的午后，从一杯咖啡开始。", artwork: Artwork(symbol: "cup.and.saucer.fill", accent: .orange), trackCount: 5),
        Playlist(id: 304, name: "雨落松林", creator: "山野收音机", description: "低饱和的钢琴、雨声和漫长尾奏。", artwork: Artwork(symbol: "cloud.rain.fill", accent: .green), trackCount: 5)
    ]

    static let users = [
        UserProfile(id: 401, nickname: "听风的人", signature: "收藏每一首适合走夜路的歌。", artwork: Artwork(symbol: "person.crop.circle.fill", accent: .blue)),
        UserProfile(id: 402, nickname: "山野收音机", signature: "每周更新自然与氛围音乐。", artwork: Artwork(symbol: "person.crop.circle.fill", accent: .green)),
        UserProfile(id: 403, nickname: "北纬 31°", signature: "公路、海岸与摇滚乐。", artwork: Artwork(symbol: "person.crop.circle.fill", accent: .orange))
    ]

    private static func summary(_ album: Album) -> AlbumSummary {
        AlbumSummary(id: album.id, name: album.name, artwork: album.artwork)
    }
}
