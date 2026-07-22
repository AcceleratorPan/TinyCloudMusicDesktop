import Foundation

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    precondition(condition(), message)
}

let context = PlaybackContext(songIDs: [1, 2, 3], startIndex: 1)
expect(context != PlaybackContext(songIDs: [1, 3, 2], startIndex: 1), "Queue order must be significant")
let fullPlaylistIDs = (1...658).map(Int64.init)
let playbackPlan = PlaybackQueuePlan.make(
    selectedSongID: 1,
    visibleSongIDs: Array(fullPlaylistIDs.prefix(200)),
    allSongIDs: fullPlaylistIDs
)
expect(
    playbackPlan?.songIDs.count == 658 && playbackPlan?.startIndex == 0,
    "Playlist playback must use every track ID before UI pagination finishes"
)
expect(
    PlaybackNavigation.nextIndex(currentIndex: 199, count: 658, repeatMode: .off, automatic: true) == 200,
    "Sequential playback must continue from song 200 to song 201"
)
let shuffledPlaylist = PlaybackNavigation.shuffledOrder(currentIndex: 0, count: 658)
expect(
    shuffledPlaylist.first == 0 && shuffledPlaylist.count == 658 && Set(shuffledPlaylist).count == 658,
    "Shuffle playback must include all 658 songs exactly once"
)
expect(
    PlaybackSelectionAction.decide(
        currentSongID: 2,
        isPlaying: true,
        currentContext: context,
        selectedSongID: 2,
        newContext: context
    ) == .keepPlaying,
    "The same song in the same queue must not restart"
)
expect(
    PlaybackSelectionAction.decide(
        currentSongID: 1,
        isPlaying: true,
        currentContext: context,
        selectedSongID: 2,
        newContext: context
    ) == .replaceTrackAtZero,
    "A different song must start at zero"
)

let lyrics = LRCParser.parse(
    primary: "[00:03.1]一\n[00:03.10]二\n[00:03.12]三\n[1:02]四",
    translation: "[00:03.100]One\n[01:02.000]Four"
)
expect(lyrics.map(\.timestampMilliseconds) == [3_100, 3_120, 62_000], "LRC fractions must normalize")
expect(lyrics[0].text == "一 / 二" && lyrics[0].translation == "One", "Lyrics must merge by timestamp")
expect(LRCParser.currentLine(in: lyrics, at: 3_119)?.text == "一 / 二", "Current lyric lookup must use the latest prior line")
expect(LRCParser.currentLineIndex(in: lyrics, at: 3_120) == 1, "Current lyric index must match the latest prior line")
let wordLyrics = LRCParser.parse(
    SongLyrics(
        lineLyrics: "[00:16.210]fallback\n[00:20.000]line fallback",
        translatedLyrics: "[00:16.210]translation",
        romanizedLyrics: "[00:16.210]romanization",
        wordLyrics: "{\"t\":0}\n[16210,3460](16210,670,0)还(16880,410,0)没\n[20000,1000](bad,200,0)坏"
    )
)
expect(wordLyrics.count == 2, "Word lyric metadata and bad fragments must not discard fallback lines")
expect(
    wordLyrics[0].text == "还没"
        && wordLyrics[0].durationMilliseconds == 3_460
        && wordLyrics[0].words.map(\.text) == ["还", "没"]
        && wordLyrics[0].translation == "translation"
        && wordLyrics[0].romanization == "romanization",
    "Word lyrics must parse and merge exact-time annotations"
)
expect(wordLyrics[1].text == "line fallback", "Invalid word timing must fall back to LRC")
expect(LRCParser.currentWordIndex(in: wordLyrics[0].words, at: 16_210) == 0, "Word start must highlight the word")
expect(LRCParser.currentWordIndex(in: wordLyrics[0].words, at: 16_880) == 1, "The next word boundary must advance")
expect(LRCParser.currentWordIndex(in: wordLyrics[0].words, at: 17_290) == 1, "Word gaps must keep the previous highlight")
expect(
    abs(LRCParser.wordProgress(for: wordLyrics[0].words[0], at: 16_545) - 0.5) < 0.000_001,
    "Word progress must advance continuously within a character"
)
let offsetWordLyrics = LRCParser.parse(
    SongLyrics(
        lineLyrics: "[00:01.000]one\n[00:03.000]two\n[00:05.000]fallback",
        wordLyrics: "[1120,1000](1120,1000,0)one\n[3180,1000](3180,1000,0)two"
    )
)
expect(
    offsetWordLyrics.map(\.timestampMilliseconds) == [1_120, 3_180, 5_000],
    "Near-aligned LRC and word lyrics must not render duplicate lines"
)
let activeOffsetWordLyrics = LRCParser.parse(
    SongLyrics(
        lineLyrics: "[00:16.310]因为也许就再也见不到你\n[00:24.240]fallback",
        wordLyrics: "[14950,6490](14950,2400,0)因为也许(17350,460,0)（就）(17810,3630,0)再也见不到你"
    )
)
expect(
    activeOffsetWordLyrics.map(\.timestampMilliseconds) == [14_950, 24_240]
        && activeOffsetWordLyrics[0].text == "因为也许（就）再也见不到你"
        && LRCParser.currentLine(in: activeOffsetWordLyrics, at: 16_310)?.words.isEmpty == false,
    "An LRC timestamp inside an active word line must not interrupt word animation"
)
let shiftedWordLyrics = LRCParser.parse(
    SongLyrics(
        lineLyrics: "[00:58.750]doing the wrong thing\n[01:09.880]I couldn't lie, couldn't lie, couldn't lie",
        translatedLyrics: "[00:58.750]旧翻译\n[01:09.880]我无法自欺欺人",
        wordLyrics: "[59160,2790](59160,2790,0)doing the wrong thing\n[71070,2760](71070,2760,0)I couldn't lie, couldn't lie, couldn't lie",
        translatedWordLyrics: "[00:59.160]当我做着错误的事"
    )
)
expect(
    shiftedWordLyrics.map(\.timestampMilliseconds) == [59_160, 71_070]
        && shiftedWordLyrics.map(\.translation) == ["当我做着错误的事", "我无法自欺欺人"],
    "Shifted word lyrics must keep LRC-form translations without duplicate lines"
)
expect(
    PlaybackNavigation.nextIndex(currentIndex: 2, count: 3, repeatMode: .all, automatic: true) == 0,
    "Repeat-all must wrap the queue"
)
expect(
    PlaybackNavigation.nextIndex(currentIndex: 1, count: 3, repeatMode: .one, automatic: true) == 1,
    "Repeat-one must keep the current track on automatic advance"
)
expect(PlaylistSongPaging.initialRange(total: 500) == 0..<200, "Playlist detail must initially load 200 songs")
expect(PlaylistSongPaging.nextRange(total: 500, loaded: 200) == 200..<300, "Playlist paging must add 100 songs")
expect(PlaylistSongPaging.nextRange(total: 250, loaded: 200) == 200..<250, "Playlist paging must clamp the final page")
let editablePlaylist = Playlist(
    id: 1,
    name: "Original",
    creator: "Owner",
    description: "Old",
    artwork: Artwork(symbol: "music.note.list", accent: .green),
    creatorID: 7,
    tags: ["Rock"]
)
var metadataDraft = PlaylistMetadataDraft(playlist: editablePlaylist)
metadataDraft.name = "  New  "
metadataDraft.description = ""
metadataDraft.tags = [" Rock ", "", "Study", "Rock", "Chinese", "Extra"]
expect(
    metadataDraft.changes(from: editablePlaylist) == [
        .name("New"),
        .description(""),
        .tags(["Rock", "Study", "Chinese"])
    ],
    "Playlist metadata changes must normalize tags and preserve request order"
)
expect(editablePlaylist.isUserEditable(by: 7), "An owned ordinary playlist must be editable")
expect(PlaylistMetadataChange.tags(["Rock"]).isReflected(in: editablePlaylist), "Saved tags must match server state")
expect(!PlaylistMetadataChange.tags(["Study"]).isReflected(in: editablePlaylist), "Rejected tags must be detected")
var specialPlaylist = editablePlaylist
specialPlaylist.specialType = 5
expect(!specialPlaylist.isUserEditable(by: 7), "A special playlist must not be editable")
var readOnlyPlaylist = editablePlaylist
readOnlyPlaylist.isReadOnly = true
expect(!readOnlyPlaylist.isUserEditable(by: 7), "A read-only playlist must not be editable")
var privatePlaylist = editablePlaylist
privatePlaylist.privacy = 10
expect(privatePlaylist.isPrivate, "Privacy metadata must identify a private playlist")
expect(
    AudioQuality.allCases.map(\.cacheComponent) == ["standard", "lossless", "best"],
    "Audio qualities must use stable cache components"
)

let settings = AppSettings(
    appearance: .system,
    quality: .lossless,
    playbackQuality: .best,
    crossfadeDuration: 3,
    homeSectionIDs: ["home"],
    downloadBookmark: nil,
    imageBookmark: nil,
    cacheBookmark: nil
)
expect(settings.quality == .lossless && settings.playbackQuality == .best, "Playback and download qualities must be independent")
expect(settings.crossfadeDuration == 3, "Crossfade duration must persist in app settings")
expect(settings.preferredImageBookmark == settings.downloadBookmark, "Images must follow the song folder by default")
let lowResolutionArtworkURL = URL(string: "https://p1.music.126.net/cover.jpg?foo=bar&param=64y64")!
let highResolutionArtworkURL = ArtworkURLPolicy.highResolutionURL(for: lowResolutionArtworkURL)
let artworkQueryItems = URLComponents(url: highResolutionArtworkURL, resolvingAgainstBaseURL: false)!.queryItems!
expect(
    !artworkQueryItems.contains { $0.name == "param" },
    "Detail artwork must remove NetEase resizing parameters"
)
expect(
    artworkQueryItems.contains(URLQueryItem(name: "foo", value: "bar")),
    "Detail artwork must preserve unrelated query items"
)
expect(
    CrossfadeTransition.shouldStart(position: 97, duration: 100, crossfadeDuration: 3),
    "Crossfade must start inside its configured window"
)
let middleGains = CrossfadeTransition.gains(progress: 0.5)
expect(
    abs(middleGains.incoming * middleGains.incoming + middleGains.outgoing * middleGains.outgoing - 1) < 0.000_001,
    "Crossfade gains must keep constant power"
)

print("Core checks passed")
