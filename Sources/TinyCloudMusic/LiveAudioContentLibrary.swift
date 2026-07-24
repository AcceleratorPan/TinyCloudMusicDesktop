import Foundation

struct LiveAudioContentLibrary: Sendable {
    private static let eapiHost = "https://interface.music.163.com"

    let transport: EAPITransport

    init(transport: EAPITransport = EAPITransport()) {
        self.transport = transport
    }

    func podcastCategories() async throws -> [PodcastCategory] {
        AudioContentDecoder.podcastCategories(try await weapi(
            "/weapi/djradio/category/get",
            payload: [:],
            cache: .detail
        ))
    }

    func recommendedPodcasts(categoryID: Int64) async throws -> [Podcast] {
        guard categoryID > 0 else { throw EAPIError.invalidPayload }
        return AudioContentDecoder.podcasts(try await weapi(
            "/weapi/djradio/recommend",
            payload: ["cateId": categoryID],
            cache: .detail
        ))
    }

    func podcast(id: Int64) async throws -> Podcast {
        guard id > 0 else { throw EAPIError.invalidPayload }
        guard let podcast = AudioContentDecoder.podcast(try await weapi(
            "/weapi/djradio/v2/get",
            payload: ["id": id],
            cache: .detail
        )) else { throw EAPIError.missingData("data") }
        return podcast
    }

    func podcastEpisodes(
        podcastID: Int64,
        offset: Int = 0,
        limit: Int = 30,
        ascending: Bool = false
    ) async throws -> PodcastEpisodePage {
        guard podcastID > 0, offset >= 0, (1...100).contains(limit) else {
            throw EAPIError.invalidPayload
        }
        return AudioContentDecoder.episodePage(
            try await weapi(
                "/weapi/dj/program/byradio",
                payload: [
                    "radioId": podcastID,
                    "limit": limit,
                    "offset": offset,
                    "asc": ascending
                ],
                cache: .detail
            ),
            podcastID: podcastID,
            offset: offset,
            limit: limit,
            decodeSong: songDecoder.decodeLiveSong
        )
    }

    func podcastEpisode(id: Int64) async throws -> PodcastEpisode {
        guard id > 0 else { throw EAPIError.invalidPayload }
        guard let episode = AudioContentDecoder.episode(
            try await weapi(
                "/weapi/dj/program/detail",
                payload: ["id": id],
                cache: .detail
            ),
            decodeSong: songDecoder.decodeLiveSong
        ) else { throw EAPIError.missingData("program") }
        return episode
    }

    func subscribedPodcasts(offset: Int = 0, limit: Int = 30) async throws -> PodcastPage {
        guard offset >= 0, (1...100).contains(limit) else { throw EAPIError.invalidPayload }
        return AudioContentDecoder.podcastPage(
            try await weapi(
                "/weapi/djradio/get/subed",
                payload: ["limit": limit, "offset": offset, "total": true],
                cache: .library
            ),
            offset: offset,
            limit: limit
        )
    }

    func setPodcastSubscribed(_ id: Int64, subscribed: Bool) async throws {
        guard id > 0 else { throw EAPIError.invalidPayload }
        _ = try decodedJSONObject(try await transport.requestWEAPI(
            path: subscribed ? "/weapi/djradio/sub" : "/weapi/djradio/unsub",
            payload: ["id": id]
        ))
    }

    func voiceDetail(id: Int64) async throws -> PodcastEpisode {
        guard id > 0 else { throw EAPIError.invalidPayload }
        guard let episode = AudioContentDecoder.episode(
            try await eapi(
                "/eapi/voice/workbench/voice/detail",
                signing: "/api/voice/workbench/voice/detail",
                payload: ["id": id],
                cache: .detail
            ),
            decodeSong: songDecoder.decodeLiveSong
        ) else { throw EAPIError.missingData("data") }
        return episode
    }

    func voiceLyrics(programID: Int64) async throws -> SongLyrics {
        guard programID > 0 else { throw EAPIError.invalidPayload }
        return AudioContentDecoder.voiceLyrics(try await eapi(
            "/eapi/voice/lyric/get",
            signing: "/api/voice/lyric/get",
            payload: ["programId": programID],
            cache: .lyrics
        ))
    }

    func broadcastFilters() async throws -> BroadcastFilters {
        AudioContentDecoder.broadcastFilters(try await eapi(
            "/eapi/voice/broadcast/category/region/get",
            signing: "/api/voice/broadcast/category/region/get",
            payload: [:],
            cache: .detail
        ))
    }

    func broadcastChannels(
        categoryID: String = "0",
        regionID: String = "0",
        limit: Int = 20,
        cursor: BroadcastCursor = .initial
    ) async throws -> BroadcastChannelPage {
        guard !categoryID.isEmpty,
              !regionID.isEmpty,
              (1...100).contains(limit),
              !cursor.lastID.isEmpty,
              !cursor.score.isEmpty
        else { throw EAPIError.invalidPayload }
        return AudioContentDecoder.broadcastChannelPage(
            try await eapi(
                "/eapi/voice/broadcast/channel/list",
                signing: "/api/voice/broadcast/channel/list",
                payload: [
                    "categoryId": categoryID,
                    "regionId": regionID,
                    "limit": limit,
                    "lastId": cursor.lastID,
                    "score": cursor.score
                ],
                cache: .detail
            ),
            currentCursor: cursor,
            limit: limit
        )
    }

    func broadcastCurrentInfo(channelID rawID: String) async throws -> BroadcastCurrentInfo {
        let id = try resourceID(rawID)
        return try AudioContentDecoder.broadcastCurrentInfo(
            await eapi(
                "/eapi/voice/broadcast/channel/currentinfo",
                signing: "/api/voice/broadcast/channel/currentinfo",
                payload: ["channelId": id]
            ),
            channelID: id
        )
    }

    func setBroadcastCollected(_ rawID: String, collected: Bool) async throws {
        let id = try resourceID(rawID)
        _ = try await eapi(
            "/eapi/content/interact/collect",
            signing: "/api/content/interact/collect",
            payload: [
                "contentType": "BROADCAST",
                "contentId": id,
                "cancelCollect": collected ? "false" : "true"
            ],
            invalidatesAccountCache: true,
            retryable: false
        )
    }

    func invalidateCachedResponses(in groups: Set<EAPIReadCache>) async {
        await transport.invalidateCachedResponses(in: groups)
    }

    private var songDecoder: LiveMusicRepository {
        LiveMusicRepository(transport: transport)
    }

    private func weapi(
        _ path: String,
        payload: [String: Any],
        cache: EAPIReadCache
    ) async throws -> [String: Any] {
        try decodedJSONObject(try await transport.requestWEAPI(
            path: path,
            payload: payload,
            cache: cache,
            invalidatesAccountCache: false
        ))
    }

    private func eapi(
        _ physicalPath: String,
        signing logicalPath: String,
        payload: [String: Any],
        cache: EAPIReadCache? = nil,
        invalidatesAccountCache: Bool = false,
        retryable: Bool = true
    ) async throws -> [String: Any] {
        try decodedJSONObject(try await transport.request(
            EAPIEndpoint(physicalPath, signing: logicalPath, host: Self.eapiHost),
            json: compactJSON(payload),
            cache: cache,
            invalidatesAccountCache: invalidatesAccountCache,
            retryable: retryable
        ))
    }

    private func resourceID(_ rawID: String) throws -> String {
        let id = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { throw EAPIError.invalidPayload }
        return id
    }
}
