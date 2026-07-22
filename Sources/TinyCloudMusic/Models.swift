import Foundation

enum Accent: String, Codable, Hashable, Sendable {
    case red, orange, green, cyan, blue, pink
}

struct Artwork: Hashable, Sendable {
    let symbol: String
    let accent: Accent
    var remoteURL: URL? = nil
}

enum ArtworkURLPolicy {
    static func highResolutionURL(for url: URL) -> URL {
        guard let host = url.host?.lowercased(),
              host == "music.126.net" || host.hasSuffix(".music.126.net")
                || host == "music.163.com" || host.hasSuffix(".music.163.com"),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return url }

        var queryItems = components.queryItems ?? []
        queryItems.removeAll { $0.name == "param" }
        components.queryItems = queryItems.isEmpty ? nil : queryItems
        return components.url ?? url
    }
}

struct ArtistSummary: Identifiable, Hashable, Sendable {
    let id: Int64
    let name: String
}

struct AlbumSummary: Identifiable, Hashable, Sendable {
    let id: Int64
    let name: String
    let artwork: Artwork
}

struct Song: Identifiable, Hashable, Sendable {
    let id: Int64
    let name: String
    let primaryName: String
    let translatedName: String?
    let aliasName: String?
    let artists: [ArtistSummary]
    let album: AlbumSummary
    let duration: Duration

    init(
        id: Int64,
        name: String,
        artists: [ArtistSummary],
        album: AlbumSummary,
        duration: Duration,
        translatedName: String? = nil,
        aliasName: String? = nil
    ) {
        self.id = id
        self.primaryName = name
        self.translatedName = translatedName
        self.aliasName = aliasName
        let metadata = [translatedName, aliasName]
            .compactMap { $0 }
            .map { "(\($0))" }
            .joined(separator: " ")
        self.name = name + (metadata.isEmpty ? "" : " \(metadata)")
        self.artists = artists
        self.album = album
        self.duration = duration
    }

    var titleMetadata: String {
        [translatedName, aliasName]
            .compactMap { $0 }
            .map { "(\($0))" }
            .joined(separator: " ")
    }

    var artistsDisplay: String { artists.map(\.name).joined(separator: " / ") }

    var durationText: String {
        let seconds = duration.components.seconds
        return String(format: "%lld:%02lld", seconds / 60, seconds % 60)
    }
}

struct Artist: Identifiable, Hashable, Sendable {
    let id: Int64
    let name: String
    let biography: String
    let artwork: Artwork
    var isFollowed = false
}

struct Album: Identifiable, Hashable, Sendable {
    let id: Int64
    let name: String
    let artist: ArtistSummary
    let description: String
    let artwork: Artwork
    var isSubscribed = false
    var subscriberCount: Int64 = 0
}

struct Playlist: Identifiable, Hashable, Sendable {
    let id: Int64
    let name: String
    let creator: String
    let description: String
    let artwork: Artwork
    var trackCount = 0
    var isSubscribed = false
    var creatorID: Int64 = 0
    var tags: [String] = []
    var subscriberCount: Int64 = 0
    var specialType = 0
    var privacy = 0
    var isReadOnly = false

    func isUserEditable(by userID: Int64?) -> Bool {
        userID != nil && creatorID == userID && specialType == 0 && !isReadOnly
    }

    var isPrivate: Bool { privacy != 0 }
}

enum PlaylistMetadataChange: Equatable, Sendable {
    case name(String)
    case description(String)
    case tags([String])

    func isReflected(in playlist: Playlist) -> Bool {
        switch self {
        case let .name(name): playlist.name == name
        case let .description(description): playlist.description == description
        case let .tags(tags): playlist.tags == tags
        }
    }
}

struct PlaylistMetadataDraft: Equatable, Sendable {
    var name: String
    var description: String
    var tags: [String]

    init(playlist: Playlist) {
        name = playlist.name
        description = playlist.description
        tags = playlist.tags + Array(repeating: "", count: max(0, 3 - playlist.tags.count))
    }

    var normalizedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var normalizedTags: [String] {
        Self.normalizeTags(tags)
    }

    static func normalizeTags(_ tags: [String]) -> [String] {
        var seen = Set<String>()
        var output: [String] = []
        for rawTag in tags {
            let tag = rawTag.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !tag.isEmpty, seen.insert(tag).inserted else { continue }
            output.append(tag)
            if output.count == 3 { break }
        }
        return output
    }

    func changes(from playlist: Playlist) -> [PlaylistMetadataChange] {
        var changes: [PlaylistMetadataChange] = []
        if normalizedName != playlist.name { changes.append(.name(normalizedName)) }
        if description != playlist.description { changes.append(.description(description)) }
        if normalizedTags != playlist.tags { changes.append(.tags(normalizedTags)) }
        return changes
    }
}

struct UserProfile: Identifiable, Hashable, Sendable {
    let id: Int64
    let nickname: String
    let signature: String
    let artwork: Artwork
    var isFollowed = false
    var gender = 0
    var detailDescription = ""
    var level = 0
    var listenSongs: Int64 = 0
    var followerCount: Int64 = 0
    var followingCount: Int64 = 0
    var followsCurrentUser = false
}

enum SearchScope: String, CaseIterable, Codable, Hashable, Sendable {
    case songs = "歌曲"
    case artists = "歌手"
    case albums = "专辑"
    case playlists = "歌单"
    case users = "用户"

    var symbol: String {
        switch self {
        case .songs: "music.note"
        case .artists: "music.mic"
        case .albums: "square.stack"
        case .playlists: "music.note.list"
        case .users: "person.2"
        }
    }
}

struct SearchState: Hashable, Sendable {
    var query = ""
    var scope: SearchScope = .songs
    var offset = 0
    var selectedID: Int64?
}

enum Route: Hashable, Sendable {
    case home
    case search(SearchState)
    case cloudMusic
    case artist(Int64)
    case album(Int64)
    case playlist(Int64)
    case user(Int64)
    case comments(Int64)
    case similarSongs(Int64)
    case recommendationHistory
}

enum SearchItem: Identifiable, Hashable, Sendable {
    case song(Song)
    case artist(Artist)
    case album(Album)
    case playlist(Playlist)
    case user(UserProfile)

    var id: String {
        switch self {
        case let .song(value): "song-\(value.id)"
        case let .artist(value): "artist-\(value.id)"
        case let .album(value): "album-\(value.id)"
        case let .playlist(value): "playlist-\(value.id)"
        case let .user(value): "user-\(value.id)"
        }
    }

    var numericID: Int64 {
        switch self {
        case let .song(value): value.id
        case let .artist(value): value.id
        case let .album(value): value.id
        case let .playlist(value): value.id
        case let .user(value): value.id
        }
    }

    var title: String {
        switch self {
        case let .song(value): value.name
        case let .artist(value): value.name
        case let .album(value): value.name
        case let .playlist(value): value.name
        case let .user(value): value.nickname
        }
    }

    var subtitle: String {
        switch self {
        case let .song(value): "\(value.artistsDisplay) · \(value.album.name)"
        case let .artist(value): value.biography
        case let .album(value): value.artist.name
        case let .playlist(value): "by \(value.creator)"
        case let .user(value): value.signature
        }
    }

    var artwork: Artwork {
        switch self {
        case let .song(value): value.album.artwork
        case let .artist(value): value.artwork
        case let .album(value): value.artwork
        case let .playlist(value): value.artwork
        case let .user(value): value.artwork
        }
    }

    var route: Route? {
        switch self {
        case .song: nil
        case let .artist(value): .artist(value.id)
        case let .album(value): .album(value.id)
        case let .playlist(value): .playlist(value.id)
        case let .user(value): .user(value.id)
        }
    }
}

struct SearchPage: Equatable, Sendable {
    let items: [SearchItem]
    let offset: Int
    let hasMore: Bool

    func appending(_ page: SearchPage) -> SearchPage {
        let existingIDs = Set(items.map(\.id))
        return SearchPage(
            items: items + page.items.filter { !existingIDs.contains($0.id) },
            offset: page.offset,
            hasMore: page.hasMore
        )
    }
}

struct HomeSectionDescriptor: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
}

enum HomeItem: Identifiable, Hashable, Sendable {
    case song(Song, subtitle: String?)
    case destination(id: Int64, title: String, subtitle: String, artwork: Artwork, route: Route)

    var id: String {
        switch self {
        case let .song(song, _): "song-\(song.id)"
        case let .destination(id, _, _, _, route): "\(route)-\(id)"
        }
    }

    var title: String {
        switch self {
        case let .song(song, _): song.name
        case let .destination(_, title, _, _, _): title
        }
    }

    var subtitle: String {
        switch self {
        case let .song(song, subtitle): subtitle.flatMap { $0.isEmpty ? nil : $0 } ?? song.artistsDisplay
        case let .destination(_, _, subtitle, _, _): subtitle
        }
    }

    var artwork: Artwork {
        switch self {
        case let .song(song, _): song.album.artwork
        case let .destination(_, _, _, artwork, _): artwork
        }
    }

    var song: Song? {
        guard case let .song(song, _) = self else { return nil }
        return song
    }

    var route: Route? {
        guard case let .destination(_, _, _, _, route) = self else { return nil }
        return route
    }
}

struct HomeSection: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let subtitle: String
    let items: [HomeItem]
}

enum DetailContent: Equatable, Sendable {
    case artist(Artist, songs: [Song])
    case album(Album, songs: [Song])
    case playlist(Playlist, songs: [Song], trackIDs: [Int64], loadedTrackCount: Int)
    case user(UserProfile, playlists: [Playlist])
}

enum PlaylistSongPaging {
    static let initialCount = 200
    static let pageCount = 100

    static func initialRange(total: Int) -> Range<Int> {
        0..<min(initialCount, max(0, total))
    }

    static func nextRange(total: Int, loaded: Int) -> Range<Int>? {
        let start = min(max(0, loaded), max(0, total))
        guard start < total else { return nil }
        return start..<min(start + pageCount, total)
    }
}

struct PlaybackContext: Equatable, Sendable {
    let songIDs: [Int64]
    let startIndex: Int
}

struct PlaybackQueuePlan: Equatable, Sendable {
    let songIDs: [Int64]
    let startIndex: Int

    static func make(selectedSongID: Int64, visibleSongIDs: [Int64], allSongIDs: [Int64]?) -> Self? {
        let songIDs = allSongIDs.flatMap { $0.contains(selectedSongID) ? $0 : nil } ?? visibleSongIDs
        guard let startIndex = songIDs.firstIndex(of: selectedSongID) else { return nil }
        return Self(songIDs: songIDs, startIndex: startIndex)
    }
}

struct PlaybackQueueItem: Identifiable, Equatable, Sendable {
    let id: Int64
    var song: Song?
}

enum PlaybackRepeatMode: CaseIterable, Sendable {
    case off
    case all
    case one

    var next: Self {
        switch self {
        case .off: .all
        case .all: .one
        case .one: .off
        }
    }
}

enum PlaybackNavigation {
    static func shuffledOrder(currentIndex: Int, count: Int) -> [Int] {
        guard count > 0, (0..<count).contains(currentIndex) else { return [] }
        return [currentIndex] + (0..<count).filter { $0 != currentIndex }.shuffled()
    }

    static func nextIndex(
        currentIndex: Int,
        count: Int,
        repeatMode: PlaybackRepeatMode,
        automatic: Bool
    ) -> Int? {
        guard count > 0, (0..<count).contains(currentIndex) else { return nil }
        if automatic, repeatMode == .one { return currentIndex }
        if currentIndex + 1 < count { return currentIndex + 1 }
        return repeatMode == .all ? 0 : nil
    }

    static func previousIndex(currentIndex: Int, count: Int, repeatMode: PlaybackRepeatMode) -> Int? {
        guard count > 0, (0..<count).contains(currentIndex) else { return nil }
        if currentIndex > 0 { return currentIndex - 1 }
        return repeatMode == .all ? count - 1 : nil
    }
}

enum PlaybackSelectionAction: Equatable, Sendable {
    case keepPlaying
    case resume
    case switchQueue(resume: Bool)
    case replaceTrackAtZero

    static func decide(
        currentSongID: Int64?,
        isPlaying: Bool,
        currentContext: PlaybackContext?,
        selectedSongID: Int64,
        newContext: PlaybackContext
    ) -> Self {
        guard currentSongID == selectedSongID else { return .replaceTrackAtZero }
        guard currentContext == newContext else { return .switchQueue(resume: !isPlaying) }
        return isPlaying ? .keepPlaying : .resume
    }
}

struct SongLyrics: Equatable, Sendable {
    let lineLyrics: String
    let translatedLyrics: String?
    let romanizedLyrics: String?
    let wordLyrics: String?
    let translatedWordLyrics: String?
    let romanizedWordLyrics: String?

    init(
        lineLyrics: String,
        translatedLyrics: String? = nil,
        romanizedLyrics: String? = nil,
        wordLyrics: String? = nil,
        translatedWordLyrics: String? = nil,
        romanizedWordLyrics: String? = nil
    ) {
        self.lineLyrics = lineLyrics
        self.translatedLyrics = translatedLyrics
        self.romanizedLyrics = romanizedLyrics
        self.wordLyrics = wordLyrics
        self.translatedWordLyrics = translatedWordLyrics
        self.romanizedWordLyrics = romanizedWordLyrics
    }
}

struct LyricWord: Identifiable, Equatable, Sendable {
    var id: String { "\(startMilliseconds):\(sequence)" }
    let startMilliseconds: Int64
    let durationMilliseconds: Int64
    let text: String
    let sequence: Int

    init(startMilliseconds: Int64, durationMilliseconds: Int64, text: String, sequence: Int = 0) {
        self.startMilliseconds = startMilliseconds
        self.durationMilliseconds = durationMilliseconds
        self.text = text
        self.sequence = sequence
    }
}

struct LyricLine: Identifiable, Equatable, Sendable {
    var id: Int64 { timestampMilliseconds }
    let timestampMilliseconds: Int64
    let durationMilliseconds: Int64
    let text: String
    let translation: String?
    let romanization: String?
    let words: [LyricWord]

    init(
        timestampMilliseconds: Int64,
        durationMilliseconds: Int64 = 0,
        text: String,
        translation: String? = nil,
        romanization: String? = nil,
        words: [LyricWord] = []
    ) {
        self.timestampMilliseconds = timestampMilliseconds
        self.durationMilliseconds = durationMilliseconds
        self.text = text
        self.translation = translation
        self.romanization = romanization
        self.words = words
    }
}

enum LRCParser {
    private static let wordLineMatchToleranceMilliseconds: Int64 = 750

    private struct WordLine {
        var durationMilliseconds: Int64
        var words: [LyricWord]
    }

    private static let lrcRegex = try! NSRegularExpression(
        pattern: #"\[(\d+):(\d{2})(?:\.(\d{1,3}))?\]"#
    )
    private static let wordLineRegex = try! NSRegularExpression(pattern: #"^\[(\d+),(\d+)\]"#)
    private static let wordRegex = try! NSRegularExpression(pattern: #"\(([^,)]*,[^,)]*,[^)]*)\)"#)

    static func parse(primary: String, translation: String? = nil) -> [LyricLine] {
        parse(SongLyrics(lineLyrics: primary, translatedLyrics: translation))
    }

    static func parse(_ source: SongLyrics) -> [LyricLine] {
        let lines = timedLines(source.lineLyrics)
        let wordLines = wordLines(source.wordLyrics)
        let translations = preferredTimedLines(
            wordTimed: source.translatedWordLyrics,
            lineTimed: source.translatedLyrics
        )
        let romanizations = preferredTimedLines(
            wordTimed: source.romanizedWordLyrics,
            lineTimed: source.romanizedLyrics
        )
        let lineMatches = matchedLineTimestamps(lines, wordLines: wordLines)
        let primaryTimestamps = wordLines.isEmpty
            ? Set(lines.keys)
            : Set(wordLines.keys).union(Set(lines.keys).subtracting(lineMatches.values))
        let timestamps = primaryTimestamps.isEmpty
            ? Set(translations.keys).union(romanizations.keys)
            : primaryTimestamps

        return timestamps.sorted().compactMap { timestamp in
            let wordLine = wordLines[timestamp]
            let primary = wordLine?.words.map(\.text).joined() ?? lines[timestamp]
            let lineTimestamp = lineMatches[timestamp]
            let translation = translations[timestamp] ?? lineTimestamp.flatMap { translations[$0] }
            let romanization = romanizations[timestamp] ?? lineTimestamp.flatMap { romanizations[$0] }
            guard let text = primary ?? translation ?? romanization, !text.isEmpty else { return nil }
            return LyricLine(
                timestampMilliseconds: timestamp,
                durationMilliseconds: wordLine?.durationMilliseconds ?? 0,
                text: text,
                translation: primary == nil ? nil : translation,
                romanization: romanization == text ? nil : romanization,
                words: wordLine?.words ?? []
            )
        }
    }

    static func currentWordIndex(in words: [LyricWord], at milliseconds: Int64) -> Int? {
        var previous: Int?
        for (index, word) in words.enumerated() {
            guard milliseconds >= word.startMilliseconds else { return previous }
            if word.durationMilliseconds > milliseconds - word.startMilliseconds { return index }
            previous = index
        }
        return previous
    }

    static func wordProgress(for word: LyricWord, at milliseconds: Int64) -> Double {
        guard milliseconds >= word.startMilliseconds else { return 0 }
        guard word.durationMilliseconds > 0 else { return 1 }
        return min(Double(milliseconds - word.startMilliseconds) / Double(word.durationMilliseconds), 1)
    }

    static func currentLine(in lines: [LyricLine], at milliseconds: Int64) -> LyricLine? {
        guard let index = currentLineIndex(in: lines, at: milliseconds) else { return nil }
        return lines[index]
    }

    static func currentLineIndex(in lines: [LyricLine], at milliseconds: Int64) -> Int? {
        var lower = 0
        var upper = lines.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if lines[middle].timestampMilliseconds <= milliseconds {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        return lower == 0 ? nil : lower - 1
    }

    private static func timedLines(_ source: String?) -> [Int64: String] {
        guard let source else { return [:] }
        var values: [Int64: String] = [:]
        for line in source.split(whereSeparator: \.isNewline) {
            let text = String(line)
            let range = NSRange(text.startIndex..., in: text)
            let matches = lrcRegex.matches(in: text, range: range)
            guard let last = matches.last,
                  let contentRange = Range(
                    NSRange(location: NSMaxRange(last.range), length: range.length - NSMaxRange(last.range)),
                    in: text
                  )
            else { continue }
            let content = text[contentRange].trimmingCharacters(in: .whitespaces)
            guard !content.isEmpty else { continue }

            for match in matches {
                guard let minutesRange = Range(match.range(at: 1), in: text),
                      let secondsRange = Range(match.range(at: 2), in: text),
                      let minutes = Int64(text[minutesRange]),
                      let seconds = Int64(text[secondsRange])
                else { continue }
                var milliseconds: Int64 = 0
                if match.range(at: 3).location != NSNotFound,
                   let fractionRange = Range(match.range(at: 3), in: text) {
                    let fraction = String(text[fractionRange])
                    guard let value = Int64(fraction) else { continue }
                    milliseconds = value * [100, 10, 1][fraction.count - 1]
                }
                merge(content, at: (minutes * 60 + seconds) * 1_000 + milliseconds, into: &values)
            }
        }
        return values
    }

    private static func wordLines(_ source: String?) -> [Int64: WordLine] {
        guard let source else { return [:] }
        var values: [Int64: WordLine] = [:]
        for rawLine in source.split(whereSeparator: \.isNewline) {
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("{"),
               let data = trimmed.data(using: .utf8),
               (try? JSONSerialization.jsonObject(with: data)) != nil {
                continue
            }
            let range = NSRange(line.startIndex..., in: line)
            guard let header = wordLineRegex.firstMatch(in: line, range: range),
                  let startRange = Range(header.range(at: 1), in: line),
                  let durationRange = Range(header.range(at: 2), in: line),
                  let start = Int64(line[startRange]),
                  let duration = Int64(line[durationRange])
            else { continue }

            let matches = wordRegex.matches(in: line, range: range)
            var parsed: [(start: Int64, duration: Int64, text: String)] = []
            for (index, match) in matches.enumerated() {
                guard let valuesRange = Range(match.range(at: 1), in: line) else { continue }
                let values = line[valuesRange].split(separator: ",", omittingEmptySubsequences: false)
                guard values.count == 3,
                      let wordStart = Int64(values[0]),
                      let wordDuration = Int64(values[1]),
                      wordStart >= 0,
                      wordDuration >= 0
                else { continue }
                let end = index + 1 < matches.count ? matches[index + 1].range.location : range.length
                guard let textRange = Range(
                    NSRange(location: NSMaxRange(match.range), length: end - NSMaxRange(match.range)),
                    in: line
                ) else { continue }
                let text = String(line[textRange])
                if !text.isEmpty { parsed.append((wordStart, wordDuration, text)) }
            }
            guard !parsed.isEmpty else { continue }

            let existing = values[start]?.words ?? []
            var combined = existing.map { ($0.startMilliseconds, $0.durationMilliseconds, $0.text) }
            if !combined.isEmpty {
                combined.append((parsed[0].start, 0, " / "))
            }
            combined.append(contentsOf: parsed)
            values[start] = WordLine(
                durationMilliseconds: max(values[start]?.durationMilliseconds ?? 0, duration),
                words: combined.enumerated().map { index, word in
                    LyricWord(
                        startMilliseconds: word.0,
                        durationMilliseconds: word.1,
                        text: word.2,
                        sequence: index
                    )
                }
            )
        }
        return values
    }

    private static func preferredTimedLines(wordTimed: String?, lineTimed: String?) -> [Int64: String] {
        var values = timedLines(lineTimed)
        for (timestamp, line) in timedLines(wordTimed) {
            values[timestamp] = line
        }
        for (timestamp, line) in wordLines(wordTimed) {
            values[timestamp] = line.words.map(\.text).joined()
        }
        guard let wordTimed else { return values }
        for rawLine in wordTimed.split(whereSeparator: \.isNewline) {
            let line = String(rawLine)
            let range = NSRange(line.startIndex..., in: line)
            guard wordRegex.firstMatch(in: line, range: range) == nil,
                  let header = wordLineRegex.firstMatch(in: line, range: range),
                  let startRange = Range(header.range(at: 1), in: line),
                  let start = Int64(line[startRange]),
                  let textRange = Range(
                    NSRange(location: NSMaxRange(header.range), length: range.length - NSMaxRange(header.range)),
                    in: line
                  )
            else { continue }
            let text = line[textRange].trimmingCharacters(in: .whitespaces)
            if !text.isEmpty { values[start] = text }
        }
        return values
    }

    private static func matchedLineTimestamps(
        _ lines: [Int64: String],
        wordLines: [Int64: WordLine]
    ) -> [Int64: Int64] {
        var remaining = Set(lines.keys)
        var matches: [Int64: Int64] = [:]
        // ponytail: O(n^2) pairing is fine for song-sized inputs; use a two-pointer merge for long transcripts.
        for wordTimestamp in wordLines.keys.sorted() {
            guard let wordLine = wordLines[wordTimestamp] else { continue }
            let wordText = wordLine.words.map(\.text).joined()
            let textMatches = remaining.filter { lines[$0] == wordText }
            let timingMatches = remaining.filter { timestamp in
                distance(timestamp, wordTimestamp) <= wordLineMatchToleranceMilliseconds
                    || (timestamp >= wordTimestamp
                        && timestamp - wordTimestamp < wordLine.durationMilliseconds)
            }
            let candidates = textMatches.isEmpty ? Set(timingMatches) : Set(textMatches)
            guard let match = candidates.min(by: { lhs, rhs in
                let left = distance(lhs, wordTimestamp)
                let right = distance(rhs, wordTimestamp)
                return left == right ? lhs < rhs : left < right
            }) else { continue }
            matches[wordTimestamp] = match
            remaining.remove(match)
        }
        return matches
    }

    private static func distance(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        lhs >= rhs ? lhs - rhs : rhs - lhs
    }

    private static func merge(_ text: String, at timestamp: Int64, into values: inout [Int64: String]) {
        values[timestamp] = values[timestamp].map { "\($0) / \(text)" } ?? text
    }
}

enum Appearance: String, CaseIterable, Codable, Sendable {
    case system = "跟随系统"
    case light = "浅色"
    case dark = "深色"
}

enum AudioQuality: String, CaseIterable, Codable, Sendable {
    case standard = "标准"
    case lossless = "无损"
    case best = "最高可用"

    var cacheComponent: String {
        switch self {
        case .standard: "standard"
        case .lossless: "lossless"
        case .best: "best"
        }
    }
}

struct AppSettings: Equatable, Sendable {
    var appearance: Appearance
    var quality: AudioQuality
    var playbackQuality: AudioQuality
    var crossfadeDuration: TimeInterval
    var homeSectionIDs: [String]
    var downloadBookmark: Data?
    var imageBookmark: Data?
    var cacheBookmark: Data?

    var preferredImageBookmark: Data? { imageBookmark ?? downloadBookmark }
}

enum CrossfadeTransition {
    static func gains(progress: Double) -> (incoming: Double, outgoing: Double) {
        let progress = min(max(progress, 0), 1)
        return (progress.squareRoot(), (1 - progress).squareRoot())
    }

    static func shouldStart(
        position: TimeInterval,
        duration: TimeInterval,
        crossfadeDuration: TimeInterval
    ) -> Bool {
        duration > 0
            && crossfadeDuration > 0
            && max(0, duration - position) <= crossfadeDuration
    }
}

enum AppError: LocalizedError, Equatable, Sendable {
    case unavailable(String)
    case invalidRoute

    var errorDescription: String? {
        switch self {
        case let .unavailable(message): message
        case .invalidRoute: "该页面暂不可用"
        }
    }
}
