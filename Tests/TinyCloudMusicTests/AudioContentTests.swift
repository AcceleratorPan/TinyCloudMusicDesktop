import Foundation

#if !AUDIO_CONTENT_CHECK && canImport(Testing)
import Testing
@testable import TinyCloudMusic
#endif

private enum AudioContentCheckError: Error {
    case failed
}

private func audioFixture() throws -> [String: Any] {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appending(path: "Fixtures/audio-content.json")
    guard let value = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else {
        throw AudioContentCheckError.failed
    }
    return value
}

private func fixtureObject(_ value: [String: Any], _ key: String) throws -> [String: Any] {
    guard let object = value[key] as? [String: Any] else { throw AudioContentCheckError.failed }
    return object
}

private func verifyAudioFixtureDecoding() throws {
    let fixture = try audioFixture()
    let categories = AudioContentDecoder.podcastCategories(try fixtureObject(fixture, "categories"))
    let podcasts = AudioContentDecoder.podcasts(try fixtureObject(fixture, "podcasts"))
    let episodes = AudioContentDecoder.episodePage(
        try fixtureObject(fixture, "episodes"),
        podcastID: 101,
        offset: 0,
        limit: 3,
        decodeSong: LiveMusicRepository().decodeLiveSong
    )
    let broadcasts = AudioContentDecoder.broadcastChannelPage(
        try fixtureObject(fixture, "broadcasts"),
        currentCursor: .initial,
        limit: 3
    )
    guard categories.map(\.id) == [10001, 11],
          podcasts.map(\.id) == [101, 102],
          episodes.episodes.map(\.id) == [201, 202],
          episodes.episodes[0].song?.id == 301,
          episodes.episodes[0].song?.album.artwork.remoteURL?.absoluteString == "https://p1.music.126.net/episode.jpg",
          episodes.episodes[0].song?.isPodcastEpisode == true,
          episodes.episodes[0].song?.podcastEpisodeID == 201,
          episodes.episodes[0].podcastName == "夜间节目",
          episodes.episodes[0].hostName == "主播",
          episodes.episodes[1].song == nil,
          broadcasts.channels.map(\.id) == ["0007", "8"],
          broadcasts.nextCursor == BroadcastCursor(lastID: "0008", score: "12")
    else { throw AudioContentCheckError.failed }
}

private func verifyAudioPagination() throws {
    let episode = PodcastEpisode(
        id: 1,
        podcastID: 2,
        title: "Episode",
        coverURL: nil,
        durationMilliseconds: 1_000,
        publishedAt: nil,
        song: nil
    )
    let first = PodcastEpisodePage(episodes: [episode], nextOffset: 1, hasMore: true)
    let repeated = PodcastEpisodePage(episodes: [episode], nextOffset: 1, hasMore: true)
    let channel = BroadcastChannel(
        id: "7",
        name: "Channel",
        regionName: "",
        coverURL: nil,
        isCollected: false
    )
    let cursor = BroadcastCursor(lastID: "7", score: "1")
    let page = BroadcastChannelPage(channels: [channel], nextCursor: cursor, hasMore: true)
    guard first.appending(repeated).episodes.count == 1,
          !first.appending(repeated).hasMore,
          page.appending(page).channels.count == 1,
          !page.appending(page).hasMore
    else { throw AudioContentCheckError.failed }
}

private func verifyEmptyVoiceLyrics() throws {
    let lyrics = AudioContentDecoder.voiceLyrics(
        try fixtureObject(try audioFixture(), "emptyLyrics")
    )
    guard lyrics.lineLyrics.isEmpty, LRCParser.parse(lyrics).isEmpty else {
        throw AudioContentCheckError.failed
    }
}

private func verifyBroadcastStreamPolicy() throws {
    guard BroadcastStreamURLPolicy.isAllowed(URL(string: "https://m7.music.126.net/live.aac")!),
          BroadcastStreamURLPolicy.isAllowed(URL(string: "https://lhttp.qtfm.cn/live.aac")!),
          BroadcastStreamURLPolicy.isAllowed(URL(string: "https://lhttp-hw.qtfm.cn/live.aac")!),
          BroadcastStreamURLPolicy.isAllowed(URL(string: "https://lhttp.qingting.fm/live.aac")!),
          !BroadcastStreamURLPolicy.isAllowed(URL(string: "http://m7.music.126.net/live.aac")!),
          !BroadcastStreamURLPolicy.isAllowed(URL(string: "https://qtfm.cn.evil.test/live.aac")!),
          !BroadcastStreamURLPolicy.isAllowed(URL(string: "https://music.126.net.evil.test/live.aac")!)
    else { throw AudioContentCheckError.failed }

    guard BroadcastStreamURLPolicy.isPlayableResponse(statusCode: 200, mimeType: "audio/mpeg"),
          BroadcastStreamURLPolicy.isPlayableResponse(statusCode: 206, mimeType: nil),
          !BroadcastStreamURLPolicy.isPlayableResponse(statusCode: 404, mimeType: "text/html"),
          !BroadcastStreamURLPolicy.isPlayableResponse(statusCode: 200, mimeType: "text/html")
    else { throw AudioContentCheckError.failed }

    guard try BroadcastStreamURLPolicy.validate("http://lhttp-hw.qtfm.cn/live.aac").absoluteString
        == "https://lhttp-hw.qtfm.cn/live.aac"
    else { throw AudioContentCheckError.failed }

    let current = try AudioContentDecoder.broadcastCurrentInfo([
        "data": [
            "channelId": "7",
            "channelName": "Channel",
            "streamUrl": "https://example.test/live.aac"
        ]
    ], channelID: "7")
    guard current.streamURL?.host == "example.test" else { throw AudioContentCheckError.failed }
    do {
        _ = try BroadcastStreamURLPolicy.validate(current.streamURL!.absoluteString)
        throw AudioContentCheckError.failed
    } catch AudioContentError.unsafeStreamURL {
    }
}

#if AUDIO_CONTENT_CHECK
@main
private enum AudioContentCheck {
    static func main() throws {
        try verifyAudioFixtureDecoding()
        try verifyAudioPagination()
        try verifyEmptyVoiceLyrics()
        try verifyBroadcastStreamPolicy()
        print("Podcast and broadcast audio check passed")
    }
}
#elseif canImport(Testing)
@Suite("Podcast and broadcast audio")
struct AudioContentTests {
    @Test("Fixtures tolerate missing optional fields and preserve ID types")
    func fixtureDecoding() throws { try verifyAudioFixtureDecoding() }

    @Test("Offset and cursor pages deduplicate and stop without progress")
    func paginationProgress() throws { try verifyAudioPagination() }

    @Test("Empty voice lyrics remain valid")
    func emptyLyrics() throws { try verifyEmptyVoiceLyrics() }

    @Test("Broadcast streams require an official HTTPS CDN")
    func streamPolicy() throws { try verifyBroadcastStreamPolicy() }
}
#endif
