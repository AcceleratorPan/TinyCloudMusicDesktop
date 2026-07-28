import CoreFoundation
import Foundation

enum ListeningReportPeriod: String, CaseIterable, Sendable {
    case week, month, year

    var title: String {
        switch self {
        case .week: "本周"
        case .month: "本月"
        case .year: "年度"
        }
    }
}

struct ListeningReportCursor: Hashable, Sendable {
    let endTime: Int64

    fileprivate init(endTime: Int64) {
        self.endTime = endTime
    }
}

enum ListeningMetricKind: String, CaseIterable, Sendable {
    case duration, songs, plays, artists, albums, days

    var title: String {
        switch self {
        case .duration: "收听时长"
        case .songs: "歌曲"
        case .plays: "播放"
        case .artists: "歌手"
        case .albums: "专辑"
        case .days: "收听天数"
        }
    }
}

enum ListeningMetricValue: Equatable, Sendable {
    case number(Int64)
    case text(String)
}

struct ListeningMetric: Identifiable, Equatable, Sendable {
    let kind: ListeningMetricKind
    let value: ListeningMetricValue
    var id: ListeningMetricKind { kind }
}

struct ListeningRankEntry: Identifiable, Equatable, Sendable {
    let song: Song
    let playCount: Int
    let durationSeconds: Int64?
    var id: Int64 { song.id }
}

struct ListeningReport: Equatable, Sendable {
    let period: ListeningReportPeriod
    let title: String
    let metrics: [ListeningMetric]
    let topSongs: [ListeningRankEntry]
    let previousEndTime: Int64?

    var previousCursor: ListeningReportCursor? {
        previousEndTime.map { ListeningReportCursor(endTime: $0) }
    }
}

struct YearListeningFootprint: Identifiable, Equatable, Sendable {
    let year: Int
    let playCount: Int64
    let durationSeconds: Int64
    var id: Int { year }
}

struct AnnualListeningReport: Equatable, Sendable {
    let year: Int
    let overviewMetrics: [ListeningMetric]
    let sections: [AnnualReportSection]
}

struct AnnualReportSection: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let subtitle: String?
    let artworkURL: URL?
    let metrics: [AnnualReportMetric]
    let details: [String]
    let items: [AnnualReportItem]
    let tracks: [AnnualReportTrack]
}

enum AnnualReportItem: Identifiable, Equatable, Sendable {
    case genre(name: String, percent: Int64)
    case artist(id: Int64, name: String, imageURL: URL?, note: String)
    case month(month: Int, durationSeconds: Int64, artistID: Int64?, artistName: String?, imageURL: URL?)
    case mood(month: Int, name: String, genre: String?)

    var id: String {
        switch self {
        case let .genre(name, _): "genre-\(name)"
        case let .artist(id, name, _, note): "artist-\(id)-\(name)-\(note)"
        case let .month(month, _, _, _, _): "month-\(month)"
        case let .mood(month, _, _): "mood-\(month)"
        }
    }
}

struct AnnualReportMetric: Identifiable, Equatable, Sendable {
    let label: String
    let value: AnnualReportMetricValue
    var id: String { label }
}

enum AnnualReportMetricValue: Equatable, Sendable {
    case number(Int64, suffix: String)
    case duration(Int64)
    case date(Int64)
    case text(String)
}

struct AnnualReportTrack: Identifiable, Equatable, Sendable {
    let id: String
    let song: Song
    let caption: String?
    let playCount: Int64?
}

struct FirstListenMemory: Equatable, Sendable {
    let listenedAt: Date?
    let text: String?
}

enum ListeningReportDecoder {
    typealias SongDecoder = ([String: Any]) -> Song?

    static func rankEntries(
        _ root: [String: Any],
        decodeSong: SongDecoder
    ) -> [ListeningRankEntry] {
        for values in rankArrays(in: root) {
            var seen = Set<Int64>()
            let entries = values.compactMap { value -> ListeningRankEntry? in
                guard let song = song(in: value, decodeSong: decodeSong),
                      song.id > 0,
                      seen.insert(song.id).inserted
                else { return nil }
                return ListeningRankEntry(
                    song: song,
                    playCount: max(0, int64(in: value, keys: ["playCount", "listenCount", "count"]).map(Int.init) ?? 0),
                    durationSeconds: durationSeconds(in: value)
                )
            }
            if !entries.isEmpty { return entries.prefix(20).map { $0 } }
        }
        return []
    }

    static func report(
        _ root: [String: Any],
        period: ListeningReportPeriod,
        defaultTitle: String,
        decodeSong: SongDecoder
    ) -> ListeningReport {
        let data = root.object("data").isEmpty ? root : root.object("data")
        let title = shortText(value(in: data, keys: ["title", "reportTitle", "dateDesc", "timeRange"]))
            ?? defaultTitle
        return ListeningReport(
            period: period,
            title: title,
            metrics: metrics(in: data),
            topSongs: rankEntries(data, decodeSong: decodeSong),
            previousEndTime: previousCursor(in: data)?.endTime
        )
    }

    static func realtimeReport(
        _ root: [String: Any],
        period: ListeningReportPeriod,
        defaultTitle: String
    ) -> ListeningReport {
        let data = root.object("data").isEmpty ? root : root.object("data")
        let distribution = data.object("listenTimeDistributionBlock")
        var metrics: [ListeningMetric] = []
        if let duration = secondsFromMinutes(distribution["playDuration"]) {
            metrics.append(ListeningMetric(kind: .duration, value: .number(duration)))
        }
        if let days = int64Value(distribution["listenDays"]), days >= 0 {
            metrics.append(ListeningMetric(kind: .days, value: .number(days)))
        }
        return ListeningReport(
            period: period,
            title: shortText(value(in: data, keys: ["title", "reportTitle", "dateDesc", "timeRange"]))
                ?? defaultTitle,
            metrics: metrics,
            topSongs: [],
            previousEndTime: nil
        )
    }

    static func yearFootprints(_ root: [String: Any]) -> [YearListeningFootprint] {
        let data = root.object("data").isEmpty ? root : root.object("data")
        guard let rawItems = data["yearItems"] as? [Any] else { return [] }
        var seen = Set<Int>()
        return rawItems.compactMap { raw -> YearListeningFootprint? in
            guard let item = raw as? [String: Any],
                  let rawYear = int64(in: item, keys: ["year"]),
                  let year = Int(exactly: rawYear), (2000...2100).contains(year),
                  let playCount = int64(in: item, keys: ["playNum"]), playCount >= 0,
                  let duration = int64(in: item, keys: ["playDuration"]), duration >= 0,
                  playCount > 0 || duration > 0,
                  seen.insert(year).inserted
            else { return nil }
            return YearListeningFootprint(year: year, playCount: playCount, durationSeconds: duration)
        }
    }

    static func firstListenMemory(_ root: [String: Any], now: Date = Date()) -> FirstListenMemory {
        let data = root.object("data").isEmpty ? root : root.object("data")
        let listenedAt = timestamp(
            value(
                in: data,
                keys: ["firstListenTime", "firstListenTimestamp", "listenTime", "listenedAt", "time"]
            ),
            now: now
        )
        let text = memoryText(value(
            in: data,
            keys: ["firstListenText", "sceneText", "listenDesc", "text", "desc", "description"]
        ))
        return FirstListenMemory(listenedAt: listenedAt, text: text)
    }

    private static let metricKeys: [(ListeningMetricKind, [String])] = [
        (.songs, ["songCount", "totalSongCount", "totalSongs", "listenSongCount", "musicCount"]),
        (.plays, ["playCount", "totalPlayCount", "listenCount"]),
        (.artists, ["artistCount", "totalArtistCount"]),
        (.albums, ["albumCount", "totalAlbumCount"]),
        (.days, ["dayCount", "listenDays"])
    ]
    private static let rankContainerKeys = Set(["songDTOs", "songItems", "topSongBlock", "topSongs", "songs"])

    private static func metrics(in root: [String: Any]) -> [ListeningMetric] {
        var result: [ListeningMetric] = []
        if let value = realtimeDurationValue(in: root)
            ?? metricValue(value(in: root, keys: ["totalDuration", "listenDuration"])) {
            result.append(ListeningMetric(kind: .duration, value: value))
        }
        result += metricKeys.compactMap { kind, keys in
            guard let value = metricValue(value(in: root, keys: keys)) else { return nil }
            return ListeningMetric(kind: kind, value: value)
        }
        return result
    }

    private static func realtimeDurationValue(in root: [String: Any]) -> ListeningMetricValue? {
        secondsFromMinutes(root.object("listenTimeDistributionBlock")["playDuration"])
            .map(ListeningMetricValue.number)
    }

    private static func metricValue(_ raw: Any?) -> ListeningMetricValue? {
        if let number = number(raw), number >= 0 { return .number(number) }
        if let object = raw as? [String: Any] {
            for key in ["value", "count", "duration", "text", "desc"] {
                if let value = metricValue(object[key]) { return value }
            }
        }
        return shortText(raw).map(ListeningMetricValue.text)
    }

    private static func song(in value: [String: Any], decodeSong: SongDecoder) -> Song? {
        for key in ["song", "songInfo", "track", "resource"] {
            let nested = value.object(key)
            if !nested.isEmpty, let song = decodeSong(nested) { return song }
        }
        if let song = decodeSong(value), song.id > 0 { return song }

        guard let songID = int64(in: value, keys: ["songId", "resourceId"]), songID > 0 else { return nil }
        let album = value.object("album")
        let albumID = int64(in: value, keys: ["albumId"])
            ?? int64(in: album, keys: ["id", "albumId"])
            ?? 0
        let albumName = shortText(value["albumName"])
            ?? shortText(album["name"])
            ?? ""
        let pictureURL = shortText(value["picUrl"])
            ?? shortText(value["coverUrl"])
            ?? shortText(album["picUrl"])
            ?? ""
        let normalized: [String: Any] = [
            "id": songID,
            "name": shortText(value["songName"]) ?? shortText(value["name"]) ?? "",
            "ar": normalizedArtists(value["artists"] ?? value["artist"]),
            "al": ["id": albumID, "name": albumName, "picUrl": pictureURL],
            "dt": int64(in: value, keys: ["durationMillis", "dt"]) ?? 0
        ]
        return decodeSong(normalized)
    }

    private static func normalizedArtists(_ raw: Any?) -> [[String: Any]] {
        let values: [[String: Any]]
        if let raw = raw as? [[String: Any]] {
            values = raw
        } else if let raw = raw as? [String: Any] {
            values = [raw]
        } else {
            return []
        }
        return values.compactMap { artist in
            guard let id = int64(in: artist, keys: ["id", "artistId"]), id > 0 else { return nil }
            return ["id": id, "name": shortText(artist["name"] ?? artist["artistName"]) ?? ""]
        }
    }

    private static func rankArrays(in root: [String: Any]) -> [[[String: Any]]] {
        findArrays(in: root, keys: ["songDTOs", "songItems", "topSongs", "songs", "items"])
    }

    private static func durationSeconds(in value: [String: Any]) -> Int64? {
        guard var duration = int64(
            in: value,
            keys: ["durationSeconds", "listenDuration", "playDuration"]
        ), duration >= 0 else { return nil }
        if duration > 10 * 365 * 24 * 60 * 60 { duration /= 1_000 }
        return duration
    }

    private static func previousCursor(in root: [String: Any]) -> ListeningReportCursor? {
        guard let value = int64Value(value(
            in: root,
            keys: ["previousEndTime", "prevEndTime", "preEndTime", "preReportEndTime"]
        )) else { return nil }
        let oldest = Int64(Date(timeIntervalSince1970: 946_684_800).timeIntervalSince1970 * 1_000)
        let newest = Int64(Date().addingTimeInterval(366 * 24 * 60 * 60).timeIntervalSince1970 * 1_000)
        guard (oldest...newest).contains(value) else { return nil }
        return ListeningReportCursor(endTime: value)
    }

    private static func timestamp(_ raw: Any?, now: Date) -> Date? {
        guard let value = int64Value(raw), value > 0 else { return nil }
        let seconds = value > 10_000_000_000 ? TimeInterval(value) / 1_000 : TimeInterval(value)
        let date = Date(timeIntervalSince1970: seconds)
        let oldest = Date(timeIntervalSince1970: 946_684_800)
        guard date >= oldest, date <= now.addingTimeInterval(24 * 60 * 60) else { return nil }
        return date
    }

    private static func findArrays(
        in raw: Any,
        keys: [String],
        depth: Int = 0
    ) -> [[[String: Any]]] {
        guard depth < 5 else { return [] }
        var result: [[[String: Any]]] = []
        if let object = raw as? [String: Any] {
            for key in keys {
                if let values = object[key] as? [[String: Any]], !values.isEmpty { result.append(values) }
            }
            for child in object.values {
                result += findArrays(in: child, keys: keys, depth: depth + 1)
            }
        } else if let array = raw as? [Any] {
            for child in array {
                result += findArrays(in: child, keys: keys, depth: depth + 1)
            }
        }
        return result
    }

    private static func value(
        in raw: Any,
        keys: [String],
        depth: Int = 0
    ) -> Any? {
        guard depth < 5 else { return nil }
        if let object = raw as? [String: Any] {
            guard !isRankEntry(object) else { return nil }
            for key in keys where object[key] != nil { return object[key] }
            for (key, child) in object where !rankContainerKeys.contains(key) {
                if let found = value(in: child, keys: keys, depth: depth + 1) { return found }
            }
        } else if let array = raw as? [Any] {
            for child in array {
                if let found = value(in: child, keys: keys, depth: depth + 1) { return found }
            }
        }
        return nil
    }

    private static func isRankEntry(_ object: [String: Any]) -> Bool {
        object["songId"] != nil
            || object["resourceId"] != nil
            || ["song", "songInfo", "track"].contains { !object.object($0).isEmpty }
    }

    private static func int64(in object: [String: Any], keys: [String]) -> Int64? {
        for key in keys {
            if let value = int64Value(object[key]) { return value }
        }
        return nil
    }

    private static func number(_ raw: Any?) -> Int64? {
        int64Value(raw)
    }

    private static func secondsFromMinutes(_ raw: Any?) -> Int64? {
        guard let minutes = int64Value(raw), minutes >= 0 else { return nil }
        let (seconds, overflow) = minutes.multipliedReportingOverflow(by: 60)
        return overflow ? nil : seconds
    }

    private static func int64Value(_ raw: Any?) -> Int64? {
        if let value = raw as? NSNumber {
            guard CFGetTypeID(value) != CFBooleanGetTypeID() else { return nil }
            let number = value.doubleValue
            guard number.isFinite,
                  number.rounded() == number
            else { return nil }
            return Int64(exactly: number)
        }
        if let value = raw as? String { return Int64(value.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return nil
    }

    private static func shortText(_ raw: Any?) -> String? {
        guard let raw = raw as? String else { return nil }
        let text = raw.split(whereSeparator: \Character.isWhitespace).joined(separator: " ")
        guard !text.isEmpty, text.count <= 80 else { return nil }
        return text
    }

    private static func memoryText(_ raw: Any?) -> String? {
        guard let text = shortText(raw) else { return nil }
        let lowered = text.lowercased()
        guard !lowered.contains("http://"),
              !lowered.contains("https://"),
              !lowered.contains("cookie"),
              !lowered.contains("music_u")
        else { return nil }
        return text
    }
}

enum AnnualListeningReportDecoder {
    typealias SongDecoder = ([String: Any]) -> Song?

    static let supportedYears = 2017...2024

    static func report(
        _ root: [String: Any],
        year: Int,
        decodeSong: SongDecoder
    ) -> AnnualListeningReport {
        let data = root.object("data")
        let overview = data.object("meetTimeOverview")
        var overviewMetrics: [ListeningMetric] = []
        if let duration = int64(overview, ["playTime"]), duration >= 0 {
            overviewMetrics.append(ListeningMetric(kind: .duration, value: .number(duration)))
        }
        if let count = int64(overview, ["playCount"]), count >= 0 {
            overviewMetrics.append(ListeningMetric(kind: .plays, value: .number(count)))
        }

        var sections = [
            listeningMethods(data),
            annualSong(data, decodeSong: decodeSong),
            annualSinger(data, decodeSong: decodeSong),
            favoriteAlbum(data, decodeSong: decodeSong),
            annualPlaylist(data, decodeSong: decodeSong),
            genrePreferences(data),
            discoveries(data),
            seasons(data, decodeSong: decodeSong),
            monthlyListening(data),
            listeningTimes(data),
            lateListening(data, decodeSong: decodeSong),
            loopSong(data, decodeSong: decodeSong),
            crowdMemory(data, decodeSong: decodeSong),
            monthlyMoods(data),
            listenTogether(data),
            singerComparison(data)
        ].compactMap { $0 }
        sections += keywordSections(data, decodeSong: decodeSong)
        return AnnualListeningReport(year: year, overviewMetrics: overviewMetrics, sections: sections)
    }

    private static func listeningMethods(_ data: [String: Any]) -> AnnualReportSection? {
        let value = data.object("meetTimeOverview")
        var metrics: [AnnualReportMetric] = []
        for (key, label) in [
            ("pcTerminalPlayTime", "电脑端"),
            ("carTerminalPlayTime", "车载"),
            ("homeTerminalPlayTime", "家庭设备"),
            ("podcastPlayTime", "播客")
        ] {
            if let seconds = int64(value, [key]), seconds > 0 {
                metrics.append(AnnualReportMetric(label: label, value: .duration(seconds)))
            }
        }
        if let timestamp = timestamp(value, ["regTime"]) {
            metrics.append(AnnualReportMetric(label: "相遇日期", value: .date(timestamp)))
        }
        guard !metrics.isEmpty else { return nil }
        return section(
            id: "listening-methods",
            title: "聆听方式",
            artworkURL: firstURL(value["albumCoverUrl"]),
            metrics: metrics
        )
    }

    private static func annualSong(_ data: [String: Any], decodeSong: SongDecoder) -> AnnualReportSection? {
        let value = data.object("annualSong")
        guard let track = track(
            value,
            id: "annual-song",
            artistNameKeys: ["artistNameList"],
            pictureKeys: ["songPicUrl"],
            playCountKeys: ["playCnt"],
            decodeSong: decodeSong
        ) else { return nil }
        var metrics = numberMetrics(value, [
            ("playCnt", "播放次数", "次"),
            ("playDays", "收听天数", "天"),
            ("userCountOfThisAnnualSong", "年度听众", "人")
        ])
        if let timestamp = timestamp(value, ["firstDate"]) {
            metrics.append(AnnualReportMetric(label: "初次收听", value: .date(timestamp)))
        }
        return section(
            id: "annual-song",
            title: "年度歌曲",
            artworkURL: track.song.album.artwork.remoteURL,
            metrics: metrics,
            tracks: [track]
        )
    }

    private static func annualSinger(_ data: [String: Any], decodeSong: SongDecoder) -> AnnualReportSection? {
        let value = data.object("annualSinger")
        guard let name = text(value["singerName"]) else { return nil }
        let artistID = text(value["artistId"]) ?? ""
        let tracks = value.array("top5Songs").enumerated().compactMap { index, raw -> AnnualReportTrack? in
            var item = raw
            item["songName"] = raw["name"]
            item["artistId"] = artistID
            item["artistName"] = name
            return track(
                item,
                id: "annual-singer-\(index)",
                playCountKeys: ["playCount"],
                decodeSong: decodeSong
            )
        }
        var details: [String] = []
        let honor = value.object("musicNobleDTOS")
        if let name = text(honor["honourName"]) { details.append(name) }
        return section(
            id: "annual-singer",
            title: "年度歌手",
            subtitle: name,
            artworkURL: firstURL(value["singerPicUrl"]),
            metrics: numberMetrics(value, [
                ("playCount", "播放次数", "次"),
                ("singerPlayDays", "相伴天数", "天")
            ]),
            details: details,
            tracks: tracks
        )
    }

    private static func favoriteAlbum(_ data: [String: Any], decodeSong: SongDecoder) -> AnnualReportSection? {
        let value = data.object("annualPlaylistAlbum").object("favoriteAlbum")
        guard let track = track(
            value,
            id: "favorite-album",
            pictureKeys: ["albumPicUrl"],
            albumIDKeys: ["albumId"],
            albumNameKeys: ["albumName"],
            playCountKeys: ["playCount"],
            decodeSong: decodeSong
        ) else { return nil }
        return section(
            id: "favorite-album",
            title: "年度专辑",
            subtitle: text(value["albumName"]),
            artworkURL: firstURL(value["albumPicUrl"]),
            metrics: numberMetrics(value, [
                ("playCount", "播放次数", "次"),
                ("playDays", "收听天数", "天")
            ]),
            tracks: [track]
        )
    }

    private static func annualPlaylist(_ data: [String: Any], decodeSong: SongDecoder) -> AnnualReportSection? {
        let tracks = data.object("annualPlaylist").array("items").enumerated().compactMap { index, value in
            track(
                value,
                id: "annual-top-\(index)",
                pictureKeys: ["picUrl"],
                playCountKeys: ["playCount"],
                decodeSong: decodeSong
            )
        }
        guard !tracks.isEmpty else { return nil }
        return section(id: "annual-playlist", title: "年度 Top 歌曲", tracks: tracks)
    }

    private static func genrePreferences(_ data: [String: Any]) -> AnnualReportSection? {
        let value = data.object("genrePlayRank")
        var metrics: [AnnualReportMetric] = []
        if let age = int64(value, ["musicAge"]), age > 0 {
            metrics.append(AnnualReportMetric(label: "音乐年龄", value: .number(age, suffix: "岁")))
        }
        let items = value.array("genreRank").compactMap { item -> AnnualReportItem? in
            guard let name = text(item["genreTagName"]),
                  let percent = int64(item, ["percent"]), percent >= 0
            else { return nil }
            return .genre(name: name, percent: min(percent, 100))
        }
        let subtitle = text(value["word"])
        guard !metrics.isEmpty || !items.isEmpty || subtitle != nil else { return nil }
        return section(
            id: "genres",
            title: "音乐偏好",
            subtitle: subtitle,
            metrics: metrics,
            items: items
        )
    }

    private static func discoveries(_ data: [String: Any]) -> AnnualReportSection? {
        let value = data.object("newDiscoveryDTO")
        let metrics = numberMetrics(value, [
            ("totalArtistCount", "听过歌手", "位"),
            ("newArtistCount", "新遇见歌手", "位"),
            ("totalGenreCount", "听过曲风", "种"),
            ("newGenreCount", "新曲风", "种")
        ], includesZero: true)
        var details: [String] = []
        if let genres = value["specialGenre"] as? [String] {
            let names = genres.compactMap { text($0) }
            if !names.isEmpty { details.append("特别曲风：\(names.joined(separator: "、"))") }
        }
        let singer = value.object("newSingerDetailDto")
        var items: [AnnualReportItem] = []
        if let artist = artistItem(singer, defaultNote: "新遇见") { items.append(artist) }
        items += value.array("top5SingerDetails").compactMap {
            artistItem($0, defaultNote: "常听歌手")
        }
        guard !metrics.isEmpty || !details.isEmpty || !items.isEmpty else { return nil }
        return section(id: "discoveries", title: "新的相遇", metrics: metrics, details: details, items: items)
    }

    private static func seasons(_ data: [String: Any], decodeSong: SongDecoder) -> AnnualReportSection? {
        let value = data.object("seasonsListen")
        let seasons = [("spring", "春日"), ("summer", "夏日"), ("autumn", "秋日"), ("winter", "冬日")]
        let tracks = seasons.enumerated().compactMap { index, season -> AnnualReportTrack? in
            let item = value.object(season.0)
            return track(
                item,
                id: "season-\(index)",
                pictureKeys: ["picUrl"],
                playCountKeys: ["playNum"],
                captionPrefix: season.1,
                decodeSong: decodeSong
            )
        }
        guard !tracks.isEmpty else { return nil }
        return section(id: "seasons", title: "四季循环", tracks: tracks)
    }

    private static func monthlyListening(_ data: [String: Any]) -> AnnualReportSection? {
        let items = data.object("monthListenDTO").array("monthListenItemList")
        let months = items.compactMap { item -> AnnualReportItem? in
            guard let month = int64(item, ["monthIndex"]), (1...12).contains(month),
                  let seconds = int64(item, ["playTime"]), seconds >= 0
            else { return nil }
            let artistID = int64(item, ["artistId", "singerId", "id"]).flatMap { $0 > 0 ? $0 : nil }
            return .month(
                month: Int(month),
                durationSeconds: seconds,
                artistID: artistID,
                artistName: firstText(item, ["artistName", "singerName", "name"]),
                imageURL: firstURL(item, [
                    "artistPicUrl", "singerPicUrl", "img1v1Url", "songCoverPicUrl", "albumCoverUrl", "picUrl"
                ])
            )
        }
        guard !months.isEmpty else { return nil }
        return section(id: "months", title: "月度足迹", items: months)
    }

    private static func listeningTimes(_ data: [String: Any]) -> AnnualReportSection? {
        let value = data.object("listenTimePeriod")
        var metrics: [AnnualReportMetric] = []
        if let period = text(value["maxTimePeriod"]) {
            metrics.append(AnnualReportMetric(label: "最常出现", value: .text(periodTitle(period))))
        }
        if let count = int64(value, ["totalMaxPlayCount"]), count > 0 {
            metrics.append(AnnualReportMetric(label: "时段峰值", value: .number(count, suffix: "次")))
        }
        let details = value.array("distributions").compactMap { item -> String? in
            guard let month = int64(item, ["month"]), (1...12).contains(month),
                  let hour = int64(item, ["hour"]), (0...23).contains(hour),
                  let peak = int64(item, ["peak"]), peak >= 0
            else { return nil }
            return "\(month) 月 · \(String(format: "%02lld:00", hour)) · \(peak) 次"
        }
        guard !metrics.isEmpty || !details.isEmpty else { return nil }
        return section(id: "listening-times", title: "聆听时刻", metrics: metrics, details: details)
    }

    private static func lateListening(_ data: [String: Any], decodeSong: SongDecoder) -> AnnualReportSection? {
        let value = data.object("latePlayDTO")
        guard let track = track(
            value,
            id: "late-listening",
            pictureKeys: ["songPicUrl"],
            decodeSong: decodeSong
        ) else { return nil }
        var metrics: [AnnualReportMetric] = []
        if let timestamp = timestamp(value, ["datetime"]) {
            metrics.append(AnnualReportMetric(label: "最晚收听", value: .date(timestamp)))
        }
        return section(
            id: "late-listening",
            title: "深夜留声",
            artworkURL: track.song.album.artwork.remoteURL,
            metrics: metrics,
            tracks: [track]
        )
    }

    private static func loopSong(_ data: [String: Any], decodeSong: SongDecoder) -> AnnualReportSection? {
        var value = data.object("loopSongDTO")
        value["artistId"] = value["singerId"]
        value["artistName"] = value["singerName"]
        guard let track = track(
            value,
            id: "loop-song",
            pictureKeys: ["songPicUrl"],
            playCountKeys: ["playCount"],
            decodeSong: decodeSong
        ) else { return nil }
        var metrics: [AnnualReportMetric] = []
        if let timestamp = timestamp(value, ["playDate"]) {
            metrics.append(AnnualReportMetric(label: "循环日期", value: .date(timestamp)))
        }
        return section(
            id: "loop-song",
            title: "单曲循环",
            artworkURL: track.song.album.artwork.remoteURL,
            metrics: metrics,
            tracks: [track]
        )
    }

    private static func crowdMemory(_ data: [String: Any], decodeSong: SongDecoder) -> AnnualReportSection? {
        var value = data.object("minorMassDTO")
        var metrics: [AnnualReportMetric] = []
        var details: [String] = []
        var tracks: [AnnualReportTrack] = []
        if let name = text(value["massSongName"]) {
            let artist = text(value["massSingerName"]).map { " · \($0)" } ?? ""
            details.append("很多人也在听：\(name)\(artist)")
            if let count = int64(value, ["massFindUserCount"]), count > 0 {
                metrics.append(AnnualReportMetric(label: "共同听众", value: .number(count, suffix: "人")))
            }
        }
        if int64(value, ["minoritySongId"]).map({ $0 > 0 }) == true {
            value["songId"] = value["minoritySongId"]
            value["songName"] = value["minoritySongName"]
            value["artistName"] = value["minoritySingerName"]
            value["songPicUrl"] = value["minoritySongCoverUrl"]
            if let item = track(
                value,
                id: "minority-song",
                pictureKeys: ["minoritySongCoverUrl"],
                playCountKeys: ["minoritySongPlayCount"],
                captionPrefix: "小众珍藏",
                decodeSong: decodeSong
            ) { tracks.append(item) }
        }
        guard !metrics.isEmpty || !details.isEmpty || !tracks.isEmpty else { return nil }
        return section(
            id: "crowd-memory",
            title: "听众坐标",
            artworkURL: firstURL(value["massSongCoverUrl"]) ?? firstURL(value["minorityCoverUrl"]),
            metrics: metrics,
            details: details,
            tracks: tracks
        )
    }

    private static func keywordSections(
        _ data: [String: Any],
        decodeSong: SongDecoder
    ) -> [AnnualReportSection] {
        let value = data.object("keyWord")
        return [("firstKeyWord", "年度关键词"), ("secondKeyWord", "另一种表达"), ("loveKeyword", "藏在歌词里的爱")]
            .compactMap { key, title -> AnnualReportSection? in
                let keyword = value.object(key)
                guard let word = text(keyword["keyword"]) else { return nil }
                let tracks = keyword.array("lyricList").enumerated().compactMap { index, item in
                    let lyric = text(item["lyric"], limit: 160)
                    return track(
                        item,
                        id: "keyword-\(key)-\(index)",
                        playCountKeys: ["effectivePlayCntStd"],
                        captionPrefix: lyric,
                        decodeSong: decodeSong
                    )
                }
                var metrics: [AnnualReportMetric] = []
                if let count = int64(keyword, ["lyricCnt"]), count > 0 {
                    metrics.append(AnnualReportMetric(label: "出现次数", value: .number(count, suffix: "次")))
                }
                return section(
                    id: "keyword-\(key)",
                    title: title,
                    subtitle: word,
                    metrics: metrics,
                    tracks: tracks
                )
            }
    }

    private static func monthlyMoods(_ data: [String: Any]) -> AnnualReportSection? {
        let items = data.object("spiritDto").array("spiritItems").compactMap { item -> AnnualReportItem? in
            guard let month = int64(item, ["playMonth"]), (1...12).contains(month),
                  let mood = text(item["moodTag"]), mood != "空窗期"
            else { return nil }
            return .mood(month: Int(month), name: mood, genre: text(item["genreTagName"]))
        }
        guard !items.isEmpty else { return nil }
        return section(id: "monthly-moods", title: "十二个月的心情", items: items)
    }

    private static func listenTogether(_ data: [String: Any]) -> AnnualReportSection? {
        let value = data.object("listenTogetherBizPage")
        guard let seconds = int64(value, ["listenTogetherDuration"]), seconds > 0 else { return nil }
        var metrics = [AnnualReportMetric(label: "一起听", value: .duration(seconds))]
        if let timestamp = timestamp(value, ["listenTogetherLongestCreateDate"]) {
            metrics.append(AnnualReportMetric(label: "最长一次", value: .date(timestamp)))
        }
        return section(id: "listen-together", title: "一起听的时间", metrics: metrics)
    }

    private static func singerComparison(_ data: [String: Any]) -> AnnualReportSection? {
        let details = data.object("annualSingerComparePage").array("singers").compactMap { item -> String? in
            guard let year = int64(item, ["year"]), year > 0,
                  let name = text(item["singerName"])
            else { return nil }
            return "\(year) · \(name)"
        }
        guard !details.isEmpty else { return nil }
        return section(id: "singer-comparison", title: "年度歌手变迁", details: details)
    }

    private static func section(
        id: String,
        title: String,
        subtitle: String? = nil,
        artworkURL: URL? = nil,
        metrics: [AnnualReportMetric] = [],
        details: [String] = [],
        items: [AnnualReportItem] = [],
        tracks: [AnnualReportTrack] = []
    ) -> AnnualReportSection {
        AnnualReportSection(
            id: id,
            title: title,
            subtitle: subtitle,
            artworkURL: artworkURL,
            metrics: metrics,
            details: details,
            items: items,
            tracks: tracks
        )
    }

    private static func artistItem(
        _ value: [String: Any],
        defaultNote: String
    ) -> AnnualReportItem? {
        guard let name = firstText(value, ["artistName", "singerName", "name"]) else { return nil }
        let id = int64(value, ["artistId", "singerId", "id"]) ?? 0
        let note = int64(value, ["songCount"]).map { "\(defaultNote) · \($0) 首歌" } ?? defaultNote
        return .artist(
            id: id,
            name: name,
            imageURL: firstURL(value, [
                "artistPicUrl", "singerPicUrl", "picUrl", "img1v1Url", "avatarUrl", "cover"
            ]),
            note: note
        )
    }

    private static func numberMetrics(
        _ value: [String: Any],
        _ definitions: [(key: String, label: String, suffix: String)],
        includesZero: Bool = false
    ) -> [AnnualReportMetric] {
        definitions.compactMap { definition in
            guard let number = int64(value, [definition.key]),
                  includesZero ? number >= 0 : number > 0
            else { return nil }
            return AnnualReportMetric(
                label: definition.label,
                value: .number(number, suffix: definition.suffix)
            )
        }
    }

    private static func track(
        _ value: [String: Any],
        id: String,
        songIDKeys: [String] = ["songId"],
        songNameKeys: [String] = ["songName"],
        artistIDKeys: [String] = ["artistId"],
        artistNameKeys: [String] = ["artistName"],
        pictureKeys: [String] = ["picUrl", "songPicUrl", "songCoverPicUrl"],
        albumIDKeys: [String] = ["albumId"],
        albumNameKeys: [String] = ["albumName"],
        playCountKeys: [String] = [],
        captionPrefix: String? = nil,
        decodeSong: SongDecoder
    ) -> AnnualReportTrack? {
        guard let songID = int64(value, songIDKeys), songID > 0,
              let songName = firstText(value, songNameKeys)
        else { return nil }
        let artistNames = artistNameKeys.lazy.map { stringList(value[$0]) }.first { !$0.isEmpty } ?? []
        let artistIDs = artistIDKeys.lazy.map { idList(value[$0]) }.first { !$0.isEmpty } ?? []
        let artists: [[String: Any]] = artistIDs.enumerated().map { index, artistID in
            ["id": artistID, "name": index < artistNames.count ? artistNames[index] : ""]
        }
        let pictureURL = pictureKeys.lazy.compactMap { firstURL(value[$0]) }.first?.absoluteString ?? ""
        let normalized: [String: Any] = [
            "id": songID,
            "name": songName,
            "ar": artists,
            "al": [
                "id": int64(value, albumIDKeys) ?? 0,
                "name": firstText(value, albumNameKeys) ?? "",
                "picUrl": pictureURL
            ],
            "dt": 0
        ]
        guard let song = decodeSong(normalized) else { return nil }
        let artistCaption = artistNames.isEmpty ? nil : artistNames.joined(separator: " / ")
        let caption = [captionPrefix, artistCaption].compactMap { $0 }.joined(separator: " · ")
        return AnnualReportTrack(
            id: id,
            song: song,
            caption: caption.isEmpty ? nil : caption,
            playCount: int64(value, playCountKeys).flatMap { $0 >= 0 ? $0 : nil }
        )
    }

    private static func periodTitle(_ value: String) -> String {
        switch value.uppercased() {
        case "MORNING": "清晨"
        case "DAY", "DAYTIME", "AFTERNOON": "白天"
        case "EVENING": "傍晚"
        case "NIGHT", "MIDNIGHT": "夜晚"
        default: value
        }
    }

    private static func split(_ value: String?) -> [String] {
        guard let value else { return [] }
        return value.split { [",", "/", "、"].contains($0) }
            .compactMap { text(String($0)) }
    }

    private static func stringList(_ raw: Any?) -> [String] {
        if let values = raw as? [Any] { return values.compactMap { text($0) } }
        return split(text(raw))
    }

    private static func idList(_ raw: Any?) -> [Int64] {
        if let values = raw as? [Any] {
            return values.flatMap(idList)
        }
        if let number = raw as? NSNumber,
           CFGetTypeID(number) != CFBooleanGetTypeID(),
           let exact = Int64(exactly: number.doubleValue) {
            return [exact]
        }
        return split(text(raw)).compactMap(Int64.init)
    }

    private static func firstText(_ value: [String: Any], _ keys: [String]) -> String? {
        keys.lazy.compactMap { text(value[$0]) }.first
    }

    private static func int64(_ value: [String: Any], _ keys: [String]) -> Int64? {
        for key in keys {
            if let number = value[key] as? NSNumber,
               CFGetTypeID(number) != CFBooleanGetTypeID(),
               let exact = Int64(exactly: number.doubleValue), number.doubleValue.isFinite {
                return exact
            }
            if let string = value[key] as? String,
               let number = Int64(string.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return number
            }
        }
        return nil
    }

    private static func timestamp(_ value: [String: Any], _ keys: [String]) -> Int64? {
        guard var milliseconds = int64(value, keys), milliseconds > 0 else { return nil }
        if milliseconds < 10_000_000_000 {
            let converted = milliseconds.multipliedReportingOverflow(by: 1_000)
            guard !converted.overflow else { return nil }
            milliseconds = converted.partialValue
        }
        let date = Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1_000)
        guard date >= Date(timeIntervalSince1970: 946_684_800),
              date <= Date().addingTimeInterval(366 * 24 * 60 * 60)
        else { return nil }
        return milliseconds
    }

    private static func text(_ raw: Any?, limit: Int = 240) -> String? {
        guard let raw = raw as? String else { return nil }
        let value = raw.split(whereSeparator: \Character.isWhitespace).joined(separator: " ")
        guard !value.isEmpty, value.count <= limit else { return nil }
        return value
    }

    private static func firstURL(_ raw: Any?) -> URL? {
        if let values = raw as? [Any] {
            return values.lazy.compactMap(firstURL).first
        }
        if let value = raw as? [String: Any] {
            return firstURL(value, ["url", "picUrl", "imageUrl", "coverUrl"])
        }
        guard let value = raw as? String, !value.isEmpty, let url = URL(string: value) else { return nil }
        let secure = ArtworkURLPolicy.secureURL(for: url)
        return secure.scheme?.lowercased() == "https" ? secure : nil
    }

    private static func firstURL(_ value: [String: Any], _ keys: [String]) -> URL? {
        keys.lazy.compactMap { firstURL(value[$0]) }.first
    }
}
