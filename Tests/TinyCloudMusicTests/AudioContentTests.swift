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
    let invalidRows: [[String: Any]] = [[:]]
    let undecodableEpisodes = AudioContentDecoder.episodePage(
        ["programs": invalidRows, "more": true],
        podcastID: 2,
        offset: 0,
        limit: 1,
        decodeSong: { _ in nil }
    )
    let undecodablePodcasts = AudioContentDecoder.podcastPage(
        ["djRadios": invalidRows, "hasMore": true],
        offset: 0,
        limit: 1
    )
    guard first.appending(repeated).episodes.count == 1,
          !first.appending(repeated).hasMore,
          page.appending(page).channels.count == 1,
          !page.appending(page).hasMore,
          undecodableEpisodes.episodes.isEmpty,
          undecodableEpisodes.nextOffset == 1,
          !undecodableEpisodes.hasMore,
          undecodablePodcasts.podcasts.isEmpty,
          undecodablePodcasts.nextOffset == 1,
          !undecodablePodcasts.hasMore
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

    let qingtingHLS = URL(string: "https://ls-open.qingting.fm/live/1161/64k.m3u8")!
    guard BroadcastStreamURLPolicy.preferredPlaybackURL(qingtingHLS).absoluteString
        == "https://lhttp.qtfm.cn/live/1161/64k.mp3",
        BroadcastStreamURLPolicy.preferredPlaybackURL(URL(string: "https://m7.music.126.net/live.m3u8")!)
            .absoluteString == "https://m7.music.126.net/live.m3u8"
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

    @Test("Podcast subscription overrides project only server-provided rows")
    func podcastSubscriptionProjection() {
        let unsubscribed = podcast(id: 1, subscribed: false)
        let subscribed = podcast(id: 2, subscribed: true)
        let overrides: [Int64: Bool] = [1: true]

        let detail = PodcastSubscriptionProjection.podcast(unsubscribed, override: overrides[1])
        let discovery = PodcastSubscriptionProjection.podcasts(
            [unsubscribed, subscribed],
            subscribedOnly: false,
            override: { overrides[$0] }
        )
        let subscriptions = PodcastSubscriptionProjection.page(
            PodcastPage(podcasts: [subscribed], nextOffset: 2, hasMore: true),
            override: { overrides[$0] }
        )

        #expect(detail.isSubscribed)
        #expect(discovery.map(\.isSubscribed) == [true, true])
        #expect(subscriptions.podcasts.map(\.id) == [2])
        #expect(subscriptions.podcasts.allSatisfy { $0.isSubscribed })
        #expect(subscriptions.nextOffset == 2)
        #expect(subscriptions.hasMore)
        #expect(!PodcastSubscriptionProjection.podcast(unsubscribed, override: nil).isSubscribed)
    }

    @Test("Podcast unsubscription removes one loaded row and preserves order and pagination")
    func podcastUnsubscriptionProjection() {
        let page = PodcastPage(
            podcasts: [
                podcast(id: 1, subscribed: true),
                podcast(id: 2, subscribed: true),
                podcast(id: 3, subscribed: true)
            ],
            nextOffset: 40,
            hasMore: true
        )
        let projected = PodcastSubscriptionProjection.page(page) { $0 == 2 ? false : nil }

        #expect(projected.podcasts.map(\.id) == [1, 3])
        #expect(projected.nextOffset == 40)
        #expect(projected.hasMore)
    }

    private func podcast(id: Int64, subscribed: Bool) -> Podcast {
        Podcast(
            id: id,
            name: "Podcast \(id)",
            hostName: "Host",
            coverURL: nil,
            categoryName: "Category",
            isSubscribed: subscribed
        )
    }
}
#endif
