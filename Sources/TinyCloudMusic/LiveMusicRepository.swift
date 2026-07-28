import Foundation

struct LiveMusicRepository: MusicRepository {
    private static let interfaceHost = "https://interface.music.163.com"

    let transport: EAPITransport

    let homeDescriptors = [
        HomeSectionDescriptor(id: "PAGE_RECOMMEND_MY_SHEET", title: "我的歌单"),
        HomeSectionDescriptor(id: "PAGE_RECOMMEND_PRIVATE_RCMD_SONG", title: "私人推荐"),
        HomeSectionDescriptor(id: "PAGE_RECOMMEND_RADAR", title: "雷达歌单"),
        HomeSectionDescriptor(id: "PAGE_RECOMMEND_FEELING_PLAYLIST_LOCATION", title: "氛围歌单"),
        HomeSectionDescriptor(id: "PAGE_RECOMMEND_SCENE_PLAYLIST_LOCATION", title: "场景歌单"),
        HomeSectionDescriptor(id: "PAGE_RECOMMEND_RANK", title: "排行榜"),
        HomeSectionDescriptor(id: "PAGE_RECOMMEND_ARTIST_TREND", title: "艺人最新动向"),
        HomeSectionDescriptor(id: "PAGE_RECOMMEND_STYLE_PLAYLIST_1", title: "根据你的听歌风格推荐"),
        HomeSectionDescriptor(id: "PAGE_RECOMMEND_SPECIAL_CLOUD_VILLAGE_PLAYLIST", title: "推荐歌单"),
        HomeSectionDescriptor(id: "PAGE_RECOMMEND_FIRM_PLAYLIST", title: "影视原声音乐"),
        HomeSectionDescriptor(id: "PAGE_RECOMMEND_NEW_SONG_AND_ALBUM", title: "每周新热趋势"),
        HomeSectionDescriptor(id: "PAGE_RECOMMEND_SPECIAL_ORIGIN_SONG_LOCATION", title: "原创歌曲"),
        HomeSectionDescriptor(id: "PAGE_RECOMMEND_LBS", title: "地方特色"),
        HomeSectionDescriptor(id: "PAGE_RECOMMEND_RED_SIMILAR_SONG", title: "根据你喜爱的歌曲推荐")
    ]

    init(transport: EAPITransport = EAPITransport()) {
        self.transport = transport
    }

    func lyrics(for songID: Int64) async throws -> SongLyrics {
        do {
            let data = try await request(
                EAPIEndpoint(
                    "/eapi/song/lyric/v1",
                    signing: "/api/song/lyric/v1",
                    host: "https://interface.music.163.com"
                ),
                payload: [
                    "id": songID, "cp": false, "tv": 0, "lv": 0, "rv": 0,
                    "kv": 0, "yv": 0, "ytv": 0, "yrv": 0
                ],
                cache: .lyrics
            )
            return try decodeLyrics(data)
        } catch is CancellationError {
            throw CancellationError()
        } catch where Self.isLyricCompatibilityError(error) {
            let data = try await request(
                EAPIEndpoint("/eapi/song/lyric"),
                payload: ["id": songID, "lv": -1, "kv": -1, "tv": -1, "yv": -1],
                cache: .lyrics
            )
            return try decodeLyrics(data)
        }
    }

    func playbackSource(for songID: Int64, quality: AudioQuality) async throws -> PlaybackSource {
        let level = try await playbackLevel(for: songID, quality: quality)
        return try await playbackSource(for: songID, level: level, requiresExactLevel: false)
    }

    func playbackSource(for songID: Int64, level: String) async throws -> PlaybackSource {
        try await playbackSource(for: songID, level: level, requiresExactLevel: true)
    }

    private func playbackSource(
        for songID: Int64,
        level: String,
        requiresExactLevel: Bool
    ) async throws -> PlaybackSource {
        guard SongQualityDetail.orderedLevels.contains(level) else { throw EAPIError.invalidPayload }
        do {
            return try await transport.withVIPRequesterFallback(
                fallbackOn: { $0 is PlaybackUnavailableError }
            ) { credential in
                let data = try await request(
                    EAPIEndpoint(
                        "/eapi/song/enhance/player/url/v1",
                        signing: "/api/song/enhance/player/url/v1",
                        host: Self.interfaceHost,
                        responseEncoding: .automatic
                    ),
                    payload: Self.playbackSourcePayload(songID: songID, level: level),
                    vipCredential: credential,
                    iPhoneClient: true
                )
                return try Self.decodePlaybackSource(
                    data,
                    expectedSongID: songID,
                    requestedLevel: level,
                    requiresExactLevel: requiresExactLevel
                )
            }
        } catch let error as PlaybackUnavailableError {
            let alternatives: [Song]
            do {
                alternatives = try await copyrightAlternatives(for: songID)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                alternatives = []
            }
            throw PlaybackUnavailableError(reason: error.reason, alternatives: alternatives)
        }
    }

    static func playbackSourcePayload(songID: Int64, level: String) -> [String: Any] {
        var payload: [String: Any] = [
            "ids": "[\"\(songID)\"]",
            "level": level,
            "encodeType": "flac"
        ]
        if level == "sky" { payload["immerseType"] = "c51" }
        return payload
    }

    func songQualityDetails(for songID: Int64) async throws -> [SongQualityDetail] {
        try await transport.withVIPRequesterFallback { credential in
            async let qualityData = request(
                EAPIEndpoint(
                    "/eapi/song/music/detail/get",
                    signing: "/api/song/music/detail/get",
                    host: Self.interfaceHost,
                    responseEncoding: .automatic
                ),
                payload: ["songId": songID],
                vipCredential: credential,
                cache: .detail
            )
            async let privilegeData = request(
                EAPIEndpoint("/eapi/v3/song/detail"),
                payload: ["c": "[{\"id\":\(songID)}]"],
                vipCredential: credential,
                cache: .detail
            )
            let result = try await (qualityData, privilegeData)
            return try Self.decodeSongQualityDetails(result.0, privileges: result.1)
        }
    }

    func copyrightAlternatives(for songID: Int64) async throws -> [Song] {
        let data = try await request(
            EAPIEndpoint(
                "/eapi/song/copyright/rcmd",
                signing: "/api/song/copyright/rcmd",
                host: Self.interfaceHost,
                responseEncoding: .automatic
            ),
            payload: ["songid": songID],
            cache: .detail
        )
        return try decodeCopyrightAlternatives(data)
    }

    func heartModeSongs(seedSongID: Int64, playlistID: Int64?, startSongID: Int64) async throws -> [Song] {
        guard seedSongID > 0, startSongID > 0 else { throw EAPIError.invalidPayload }
        if let playlistID {
            guard playlistID > 0 else { throw EAPIError.invalidPayload }
            do {
                let data = try await request(
                    EAPIEndpoint(
                        "/eapi/playmode/intelligence/list",
                        signing: "/api/playmode/intelligence/list",
                        host: Self.interfaceHost
                    ),
                    payload: [
                        "songId": seedSongID,
                        "type": "fromPlayOne",
                        "playlistId": playlistID,
                        "startMusicId": startSongID,
                        "count": 1
                    ]
                )
                let songs = try decodeHeartModeSongs(data)
                if !songs.isEmpty { return songs }
            } catch is CancellationError {
                throw CancellationError()
            } catch {}
        }

        return try await LiveMusicLibrary(transport: transport).similarSongs(to: startSongID)
    }

    func decodeHeartModeSongs(_ data: Data) throws -> [Song] {
        let root = try decodedJSONObject(data)
        let values = root.array("data").isEmpty ? root.object("data").array("songs") : root.array("data")
        return values.compactMap { item in
            var songInfo = item.object("songInfo")
            if songInfo.isEmpty { songInfo = item }
            if songInfo.int64("id") == 0 { songInfo["id"] = item["id"] }
            return decodeSong(songInfo)
        }
    }

    func recordPlaybackStart(for songID: Int64) async throws {
        guard songID > 0 else { throw EAPIError.invalidPayload }
        try await recordPlaybackLog([
            "action": "startplay",
            "json": [
                "id": songID,
                "type": "song",
                "mainsite": "1",
                "mainsiteWeb": "1",
                "content": "id=0"
            ]
        ])
    }

    func recordPlayback(for songID: Int64, playedSeconds: Int) async throws {
        guard songID > 0, playedSeconds > 0 else { throw EAPIError.invalidPayload }
        try await recordPlaybackLog([
            "action": "play",
            "json": [
                "download": 0,
                "end": "playend",
                "id": songID,
                "sourceId": "0",
                "time": playedSeconds,
                "type": "song",
                "wifi": 0,
                "source": "list",
                "mainsite": "1",
                "mainsiteWeb": "1",
                "content": "id=0"
            ]
        ])
    }

    func recordPodcastPlayback(
        for episodeID: Int64,
        positionMilliseconds: Int,
        completed: Bool
    ) async throws {
        guard episodeID > 0, positionMilliseconds > 0 else { throw EAPIError.invalidPayload }
        _ = try decodedJSONObject(
            try await transport.request(
                EAPIEndpoint(
                    "/eapi/dj/playrecord/upload",
                    signing: "/api/dj/playrecord/upload"
                ),
                json: try compactJSON([
                    "programId": String(episodeID),
                    "listenLocation": String(positionMilliseconds),
                    "isListened": String(completed)
                ]),
                invalidatesAccountCache: true,
                retryable: false
            )
        )
    }

    private func recordPlaybackLog(_ log: [String: Any]) async throws {
        let logsJSON = String(
            decoding: try JSONSerialization.data(withJSONObject: [log], options: [.sortedKeys]),
            as: UTF8.self
        )
        _ = try decodedJSONObject(
            try await transport.request(
                EAPIEndpoint(
                    "/eapi/feedback/weblog",
                    signing: "/api/feedback/weblog",
                    host: "https://clientlog.music.163.com"
                ),
                json: try compactJSON(["logs": logsJSON]),
                invalidatesAccountCache: true,
                macOSClient: true,
                includesClientHeader: true,
                retryable: false
            )
        )
    }

    private func playbackLevel(for songID: Int64, quality: AudioQuality) async throws -> String {
        switch quality {
        case .standard:
            return "standard"
        case .lossless:
            return "lossless"
        case .best:
            do {
                let qualities = try await songQualityDetails(for: songID)
                return SongQualityDetail.highestAvailableLevel(in: qualities) ?? "standard"
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                return "standard"
            }
        }
    }

    func request(
        _ endpoint: EAPIEndpoint,
        payload: [String: Any],
        vipCredential: VIPRequesterCredential? = nil,
        iPhoneClient: Bool = false,
        cache: EAPIReadCache? = nil
    ) async throws -> Data {
        try await transport.request(
            endpoint,
            json: compactJSON(payload),
            vip: vipCredential != nil,
            useStoredCookieForVIP: vipCredential == .storedCookie,
            cache: cache,
            iPhoneClient: iPhoneClient
        )
    }

    private func decodeLyrics(_ data: Data) throws -> SongLyrics {
        let root = try decodedJSONObject(data)
        func lyric(_ key: String) -> String? {
            let value = root.object(key).string("lyric")
            return value.isEmpty ? nil : value
        }
        return SongLyrics(
            lineLyrics: lyric("lrc") ?? "",
            translatedLyrics: lyric("tlyric"),
            romanizedLyrics: lyric("romalrc"),
            wordLyrics: lyric("yrc"),
            translatedWordLyrics: lyric("ytlrc"),
            romanizedWordLyrics: lyric("yromalrc")
        )
    }

    private static func isLyricCompatibilityError(_ error: Error) -> Bool {
        guard let error = error as? EAPIError else { return false }
        switch error {
        case .invalidCiphertext, .invalidPadding, .invalidResponse:
            return true
        case let .http(status), let .service(status, _):
            return [400, 404, 405, 415].contains(status)
        case .invalidPayload, .missingData:
            return false
        }
    }

    static func decodePlaybackSource(
        _ data: Data,
        expectedSongID: Int64,
        requestedLevel: String,
        requiresExactLevel: Bool = false
    ) throws -> PlaybackSource {
        guard let item = try decodedJSONObject(data).array("data").first else {
            throw EAPIError.missingData("data[0]")
        }
        let songID = item.int64("id")
        guard songID == expectedSongID else { throw EAPIError.missingData("data[0].id") }

        let value = item.string("url")
        let code = item.int("code")
        let level = item.string("level").isEmpty ? requestedLevel : item.string("level")
        _ = item.string("type")
        let fee = item.int("fee")
        let payed = item.int("payed")
        let message = safePlaybackMessage(item.string("message"))
        let trial = item["freeTrialInfo"] as? [String: Any]

        if let sourceURL = URL(string: value), !value.isEmpty, (200..<300).contains(code) {
            guard let url = CloudMusicDecoder.normalizedDownloadURL(sourceURL) else {
                throw EAPIError.invalidResponse
            }
            guard !requiresExactLevel || level == requestedLevel else {
                throw AppError.unavailable("服务端未返回所选音质，已保留当前音质")
            }
            let end = trial?.int("end") ?? 0
            let availability: PlaybackAvailability = trial == nil
                ? .playable(level: level)
                : .trial(level: level, endSeconds: end > 0 ? end : nil)
            return PlaybackSource(url: url, availability: availability)
        }

        let cannotListenReason = item.object("freeTrialPrivilege").int("cannotListenReason")
        let reason: String
        if let message {
            reason = message
        } else if fee == 4, payed == 0 {
            reason = "这首歌需要购买数字专辑后播放"
        } else if code == 404 || cannotListenReason != 0 {
            reason = "这首歌因版权或地区限制暂时无法播放"
        } else if fee == 1, payed == 0 {
            reason = "当前账号暂无这首歌的播放权益"
        } else {
            reason = "这首歌暂时无法播放"
        }
        throw PlaybackUnavailableError(reason: reason, alternatives: [])
    }

    private static func safePlaybackMessage(_ value: String) -> String? {
        let message = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercase = message.lowercased()
        guard !message.isEmpty,
              message.count <= 200,
              !lowercase.contains("http://"),
              !lowercase.contains("https://"),
              !lowercase.contains("cookie"),
              !lowercase.contains("music_u"),
              message.range(of: #"-\d{3,}"#, options: .regularExpression) == nil
        else { return nil }
        return message
    }

    static func decodeSongQualityDetails(_ data: Data, privileges privilegeData: Data) throws -> [SongQualityDetail] {
        let values = try decodedJSONObject(data).object("data")
        let privilege = try decodedJSONObject(privilegeData).array("privileges").first ?? [:]
        let levelRanks = [
            "standard": 0, "higher": 1, "exhigh": 2, "lossless": 3, "hires": 4,
            "jyeffect": 5, "dolby": 6, "sky": 6, "jymaster": 6
        ]
        let maximumAvailableRank = ["plLevel", "flLevel"]
            .compactMap { levelRanks[privilege.string($0)] }
            .max()
        let qualities = [
            ("jm", "jymaster"), ("sk", "sky"), ("db", "dolby"), ("je", "jyeffect"),
            ("hr", "hires"), ("sq", "lossless"), ("h", "exhigh"), ("m", "higher"), ("l", "standard")
        ]

        return qualities.compactMap { key, level in
            let value = values.object(key)
            let bitrate = value.int("br")
            let size = value.int64("size")
            let sampleRate = value.int("sr")
            guard bitrate > 0, size > 0, sampleRate > 0 else { return nil }
            return SongQualityDetail(
                id: level,
                bitrate: bitrate,
                size: size,
                sampleRate: sampleRate,
                isAvailable: maximumAvailableRank.map { (levelRanks[level] ?? .max) <= $0 } ?? false
            )
        }
    }

    func decodeCopyrightAlternatives(_ data: Data) throws -> [Song] {
        let recommendation = try decodedJSONObject(data).object("data").object("rcmd")
        return decodeSong(recommendation).map { [$0] } ?? []
    }
}

extension LiveMusicRepository {
    func decodeSong(_ source: [String: Any]) -> Song? {
        let baseInfo = source.object("baseInfo")
        let value = !baseInfo.object("simpleSongData").isEmpty
            ? baseInfo.object("simpleSongData")
            : (!source.object("simpleSongData").isEmpty ? source.object("simpleSongData") : source)
        let id = value.int64("id")
        guard id != 0 else { return nil }

        let artistValues = value.array("ar").isEmpty ? value.array("artists") : value.array("ar")
        let artists = artistValues.compactMap { artist -> ArtistSummary? in
            let artistID = artist.int64("id")
            guard artistID != 0 else { return nil }
            return ArtistSummary(id: artistID, name: artist.string("name"))
        }
        let albumValue = value.object("al").isEmpty ? value.object("album") : value.object("al")
        let translatedName = (value["tns"] as? [String])?.first(where: { !$0.isEmpty })
            ?? (value["transNames"] as? [String])?.first(where: { !$0.isEmpty })
        let aliasName = (value["alia"] as? [String])?.first(where: { !$0.isEmpty })
            ?? (value["alias"] as? [String])?.first(where: { !$0.isEmpty })
        return Song(
            id: id,
            name: value.string("name"),
            artists: artists,
            album: AlbumSummary(
                id: albumValue.int64("id"),
                name: albumValue.string("name"),
                artwork: Artwork(symbol: "music.note", accent: .red, remoteURL: URL(string: albumValue.string("picUrl")))
            ),
            duration: .milliseconds(value.int64("dt") != 0 ? value.int64("dt") : value.int64("duration")),
            translatedName: translatedName,
            aliasName: aliasName
        )
    }
}
