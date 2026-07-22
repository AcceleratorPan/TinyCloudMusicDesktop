import Foundation

struct CloudSong: Identifiable, Equatable, Sendable {
    let id: Int64
    let song: Song?
    let name: String
    let artist: String
    let album: String
    let fileName: String
    let fileSize: Int64
    let addedAt: Date?

    var isMatched: Bool { song != nil }
}

struct CloudSongPage: Equatable, Sendable {
    let songs: [CloudSong]
    let offset: Int
    let hasMore: Bool
    let totalCount: Int

    func appending(_ page: CloudSongPage) -> CloudSongPage {
        var seen = Set(songs.map(\.id))
        let appended = songs + page.songs.filter { seen.insert($0.id).inserted }
        return CloudSongPage(
            songs: appended,
            offset: page.offset,
            hasMore: page.hasMore,
            totalCount: max(totalCount, page.totalCount, appended.count)
        )
    }
}

struct CloudDownloadSource: Equatable, Sendable {
    let url: URL
    let type: String
}

enum CloudMusicDecoder {
    static func page(
        _ root: [String: Any],
        offset: Int,
        decodeSong: ([String: Any]) -> Song?
    ) -> CloudSongPage {
        let songs = root.array("data").compactMap { song($0, decodeSong: decodeSong) }
        let totalCount = max(root.int("count"), offset + songs.count)
        let hasMore = root.keys.contains("hasMore")
            ? root.bool("hasMore")
            : root.keys.contains("more")
                ? root.bool("more")
                : offset + songs.count < totalCount
        return CloudSongPage(songs: songs, offset: offset, hasMore: hasMore, totalCount: totalCount)
    }

    static func songs(
        _ root: [String: Any],
        decodeSong: ([String: Any]) -> Song?
    ) -> [CloudSong] {
        root.array("data").compactMap { song($0, decodeSong: decodeSong) }
    }

    static func song(
        _ source: [String: Any],
        decodeSong: ([String: Any]) -> Song?
    ) -> CloudSong? {
        let simple = source.object("simpleSong").isEmpty
            ? source.object("simpleSongData")
            : source.object("simpleSong")
        let matchedSong = simple.isEmpty ? nil : decodeSong(simple)
        let id = source.int64("songId") != 0
            ? source.int64("songId")
            : (source.int64("songID") != 0 ? source.int64("songID") : simple.int64("id"))
        guard id > 0 else { return nil }

        let fileName = source.string("fileName")
        return CloudSong(
            id: id,
            song: matchedSong,
            name: firstNonempty(source.string("songName"), matchedSong?.primaryName, fileNameStem(fileName)),
            artist: firstNonempty(source.string("artist"), matchedSong?.artistsDisplay),
            album: firstNonempty(source.string("album"), matchedSong?.album.name),
            fileName: fileName,
            fileSize: max(0, source.int64("fileSize")),
            addedAt: date(milliseconds: source.int64("addTime"))
        )
    }

    static func lyrics(_ root: [String: Any]) -> SongLyrics {
        let value = root.object("data").isEmpty ? root : root.object("data")
        return SongLyrics(
            lineLyrics: value.object("lrc").string("lyric"),
            translatedLyrics: nonempty(value.object("tlyric").string("lyric"))
        )
    }

    static func downloadSource(_ root: [String: Any]) throws -> CloudDownloadSource {
        let code = root.int("code")
        guard code == 0 || (200..<300).contains(code) else {
            throw EAPIError.service(code: code, message: root.string("message"))
        }
        let value = root.object("data").isEmpty ? root : root.object("data")
        let rawURL = value.string("url")
        guard !rawURL.isEmpty, let url = URL(string: rawURL), isAllowedDownloadURL(url) else {
            throw MusicDownloadError.invalidResponse
        }
        return CloudDownloadSource(url: url, type: value.string("type"))
    }

    static func isAllowedDownloadURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https",
              url.user == nil,
              url.password == nil,
              url.port == nil || url.port == 443,
              let host = url.host?.lowercased()
        else { return false }
        return host == "music.163.com" || host.hasSuffix(".music.163.com")
            || host == "126.net" || host.hasSuffix(".126.net")
    }

    private static func date(milliseconds: Int64) -> Date? {
        guard milliseconds > 0 else { return nil }
        let seconds = milliseconds > 10_000_000_000 ? TimeInterval(milliseconds) / 1_000 : TimeInterval(milliseconds)
        return Date(timeIntervalSince1970: seconds)
    }

    private static func fileNameStem(_ value: String) -> String {
        URL(fileURLWithPath: value).deletingPathExtension().lastPathComponent
    }

    private static func firstNonempty(_ values: String?...) -> String {
        values.compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty }) ?? ""
    }

    private static func nonempty(_ value: String) -> String? { value.isEmpty ? nil : value }
}
