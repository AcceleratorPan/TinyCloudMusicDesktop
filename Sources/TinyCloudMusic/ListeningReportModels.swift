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
