import Foundation
import Testing
@testable import TinyCloudMusic

@Suite("Playback availability")
struct PlaybackAvailabilityTests {
    @Test("Playback representation accepts exact ASCII hex and preserves source compatibility")
    func playbackRepresentationAcceptsASCIIHex() {
        let lowercase = PlaybackRepresentation(
            contentLength: 1,
            contentMD5: "0123456789abcdef0123456789abcdef"
        )
        #expect(lowercase?.contentLength == 1)
        #expect(lowercase?.contentMD5 == "0123456789abcdef0123456789abcdef")

        let mixedCase = PlaybackRepresentation(
            contentLength: Int64.max,
            contentMD5: "0123456789aBcDeF0123456789ABCDEF"
        )
        #expect(mixedCase?.contentLength == Int64.max)
        #expect(mixedCase?.contentMD5 == "0123456789abcdef0123456789abcdef")

        let legacySource = PlaybackSource(
            url: URL(fileURLWithPath: "/dev/null"),
            availability: .playable(level: "standard"),
            format: "flac"
        )
        #expect(legacySource.representation == nil)
    }

    @Test("Playback representation rejects malformed lengths and non-ASCII hex")
    func playbackRepresentationRejectsMalformedIdentity() {
        let validMD5 = "0123456789abcdef0123456789abcdef"
        #expect(PlaybackRepresentation(contentLength: 0, contentMD5: validMD5) == nil)
        #expect(PlaybackRepresentation(contentLength: -1, contentMD5: validMD5) == nil)

        let invalidMD5s = [
            "",
            String(repeating: "a", count: 31),
            String(repeating: "a", count: 33),
            " " + validMD5,
            validMD5 + " ",
            "0x" + String(repeating: "a", count: 30),
            String(repeating: "a", count: 15) + "-" + String(repeating: "b", count: 16),
            String(repeating: "a", count: 15) + ":" + String(repeating: "b", count: 16),
            String(repeating: "a", count: 31) + "g",
            String(repeating: "a", count: 31) + "\n",
            String(repeating: "Ａ", count: 32),
            String(repeating: "０", count: 32),
            String(repeating: "α", count: 32)
        ]
        for contentMD5 in invalidMD5s {
            #expect(PlaybackRepresentation(contentLength: 1, contentMD5: contentMD5) == nil)
        }
    }

    @Test("Playable source decodes representation only from its verified response item")
    func playableRepresentationUsesVerifiedItemOnly() throws {
        let source = try LiveMusicRepository.decodePlaybackSource(
            Data(#"{"code":200,"data":[{"id":1,"url":"https://m1.music.126.net/audio","code":200,"level":"lossless","size":123456,"md5":"0123456789aBcDeF0123456789ABCDEF"}]}"#.utf8),
            expectedSongID: 1,
            requestedLevel: "lossless"
        )
        #expect(source.availability == .playable(level: "lossless"))
        #expect(source.representation == PlaybackRepresentation(
            contentLength: 123_456,
            contentMD5: "0123456789abcdef0123456789abcdef"
        ))

        let trial = try LiveMusicRepository.decodePlaybackSource(
            Data(#"{"code":200,"data":[{"id":2,"url":"https://m1.music.126.net/audio","code":200,"level":"standard","size":123456,"md5":"0123456789abcdef0123456789abcdef","freeTrialInfo":{"start":0,"end":30}}]}"#.utf8),
            expectedSongID: 2,
            requestedLevel: "standard"
        )
        #expect(trial.availability == .trial(level: "standard", endSeconds: 30))
        #expect(trial.representation == nil)

        let urlOnly = try LiveMusicRepository.decodePlaybackSource(
            Data(#"{"code":200,"data":[{"id":3,"url":"https://m1.music.126.net/0123456789abcdef0123456789abcdef.flac?md5=0123456789abcdef0123456789abcdef","code":200,"level":"lossless","size":123456}]}"#.utf8),
            expectedSongID: 3,
            requestedLevel: "lossless"
        )
        #expect(urlOnly.representation == nil)

        let otherItemOnly = try LiveMusicRepository.decodePlaybackSource(
            Data(#"{"code":200,"data":[{"id":4,"url":"https://m1.music.126.net/audio","code":200,"level":"lossless"},{"id":5,"size":123456,"md5":"0123456789abcdef0123456789abcdef"}]}"#.utf8),
            expectedSongID: 4,
            requestedLevel: "lossless"
        )
        #expect(otherItemOnly.representation == nil)
    }

    @Test("Playable source ignores incomplete or malformed representation fields")
    func playableRepresentationRejectsMalformedFields() throws {
        func decode(size: Any? = nil, md5: Any? = nil) throws -> PlaybackSource {
            var item: [String: Any] = [
                "id": 1,
                "url": "https://m1.music.126.net/audio",
                "code": 200,
                "level": "lossless"
            ]
            if let size { item["size"] = size }
            if let md5 { item["md5"] = md5 }
            return try LiveMusicRepository.decodePlaybackSource(
                ["data": [item]],
                expectedSongID: 1,
                requestedLevel: "lossless"
            )
        }

        let validMD5 = "0123456789abcdef0123456789abcdef"
        let cases: [(String, Any?, Any?)] = [
            ("both fields missing", nil, nil),
            ("md5 missing", NSNumber(value: 123), nil),
            ("size missing", nil, validMD5),
            ("md5 is not a string", NSNumber(value: 123), NSNumber(value: 123)),
            ("size is a string", "123", validMD5),
            ("size is a boolean", true, validMD5),
            ("size is fractional", NSNumber(value: 123.5), validMD5),
            ("size is NaN", NSNumber(value: Double.nan), validMD5),
            ("size is infinite", NSNumber(value: Double.infinity), validMD5),
            ("size overflows Int64", NSNumber(value: UInt64.max), validMD5),
            ("size is zero", NSNumber(value: 0), validMD5),
            ("size is negative", NSNumber(value: -1), validMD5),
            ("md5 is not hex", NSNumber(value: 123), String(repeating: "g", count: 32))
        ]

        for (name, size, md5) in cases {
            let source = try decode(size: size, md5: md5)
            #expect(source.availability == .playable(level: "lossless"), "Case: \(name)")
            #expect(source.representation == nil, "Case: \(name)")
        }
    }

    @Test("Playback URL policy matches the existing download boundary")
    func playbackURLPolicyMatchesDownloadPolicy() throws {
        let allowed = [
            "https://music.163.com/audio",
            "https://m1.music.163.com/audio",
            "https://126.net/audio",
            "https://m1.music.126.net/audio",
            "HTTPS://M1.MUSIC.126.NET:443/audio"
        ]
        let rejected = [
            "https://evil126.net/audio",
            "https://126.net.example.com/audio",
            "https://music.163.com.example.org/audio",
            "http://m1.music.126.net/audio",
            "https://m1.music.126.net:444/audio",
            "https://user@m1.music.126.net/audio",
            "https://user:password@m1.music.126.net/audio",
            "https://:password@m1.music.126.net/audio",
            "https:/audio",
            "https://127.0.0.1/audio",
            "https://[::1]/audio"
        ]

        for rawValue in allowed {
            let url = try #require(URL(string: rawValue))
            #expect(PlaybackSourceURLPolicy.isAllowedRemote(url), "URL: \(rawValue)")
            #expect(
                PlaybackSourceURLPolicy.isAllowedRemote(url)
                    == CloudMusicDecoder.isAllowedDownloadURL(url),
                "URL: \(rawValue)"
            )
        }
        for rawValue in rejected {
            let url = try #require(URL(string: rawValue))
            #expect(!PlaybackSourceURLPolicy.isAllowedRemote(url), "URL: \(rawValue)")
            #expect(
                PlaybackSourceURLPolicy.isAllowedRemote(url)
                    == CloudMusicDecoder.isAllowedDownloadURL(url),
                "URL: \(rawValue)"
            )
        }

        let upgradeCandidate = try #require(URL(string: "http://m1.music.126.net:80/audio"))
        let upgraded = try #require(CloudMusicDecoder.normalizedDownloadURL(upgradeCandidate))
        #expect(upgraded.scheme == "https")
        #expect(upgraded.port == nil)
        let suffixAttack = try #require(URL(string: "http://evil126.net:80/audio"))
        #expect(CloudMusicDecoder.normalizedDownloadURL(suffixAttack) == nil)
    }

    @Test("Playable, trial, and unavailable entries map to stable states")
    func playbackMappings() throws {
        let playable = try LiveMusicRepository.decodePlaybackSource(
            Data(#"{"code":200,"data":[{"id":1,"url":"https://m1.music.126.net/1.mp3","code":200,"level":"exhigh","type":"mp3","fee":0,"payed":0,"message":null,"freeTrialInfo":null}]}"#.utf8),
            expectedSongID: 1,
            requestedLevel: "standard"
        )
        #expect(playable.availability == .playable(level: "exhigh"))
        #expect(playable.format == "mp3")

        let extensionlessFLAC = try LiveMusicRepository.decodePlaybackSource(
            Data(#"{"code":200,"data":[{"id":4,"url":"https://m1.music.126.net/audio","code":200,"level":"lossless","type":"FLAC"}]}"#.utf8),
            expectedSongID: 4,
            requestedLevel: "lossless"
        )
        #expect(extensionlessFLAC.format == "flac")

        do {
            _ = try LiveMusicRepository.decodePlaybackSource(
                Data(#"{"code":200,"data":[{"id":1,"url":"https://example.com/1.mp3","code":200,"level":"standard"}]}"#.utf8),
                expectedSongID: 1,
                requestedLevel: "standard"
            )
            Issue.record("Untrusted playback hosts must be rejected")
        } catch EAPIError.invalidResponse {
        }

        do {
            _ = try LiveMusicRepository.decodePlaybackSource(
                Data(#"{"code":200,"data":[{"id":1,"url":"https://m1.music.126.net/1.flac","code":200,"level":"lossless"}]}"#.utf8),
                expectedSongID: 1,
                requestedLevel: "jyeffect",
                requiresExactLevel: true
            )
            Issue.record("Explicit quality selection must reject a downgraded source")
        } catch let error as AppError {
            #expect(error == .unavailable("服务端未返回所选音质，已保留当前音质"))
        }

        let trial = try LiveMusicRepository.decodePlaybackSource(
            Data(#"{"code":200,"data":[{"id":2,"url":"https://m1.music.126.net/2.mp3","code":200,"level":"standard","type":"mp3","fee":1,"payed":0,"message":null,"freeTrialInfo":{"start":0,"end":30}}]}"#.utf8),
            expectedSongID: 2,
            requestedLevel: "standard"
        )
        #expect(trial.availability == .trial(level: "standard", endSeconds: 30))

        do {
            _ = try LiveMusicRepository.decodePlaybackSource(
                Data(#"{"code":200,"data":[{"id":3,"url":null,"code":404,"level":null,"type":null,"fee":0,"payed":0,"message":null,"freeTrialInfo":null,"freeTrialPrivilege":{"cannotListenReason":1}}]}"#.utf8),
                expectedSongID: 3,
                requestedLevel: "standard"
            )
            Issue.record("Unavailable entries must throw PlaybackUnavailableError")
        } catch let error as PlaybackUnavailableError {
            #expect(error.reason == "这首歌因版权或地区限制暂时无法播放")
        }
    }

    @Test("Top-level failures remain network errors")
    func topLevelFailure() {
        do {
            _ = try LiveMusicRepository.decodePlaybackSource(
                Data(#"{"code":503,"message":"temporary"}"#.utf8),
                expectedSongID: 1,
                requestedLevel: "standard"
            )
            Issue.record("Top-level service failures must not become copyright errors")
        } catch let error as EAPIError {
            #expect(error == .service(code: 503, message: "temporary"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("Quality decoder keeps valid known entries and applies account limits")
    func qualityDetails() throws {
        let quality = Data(#"{"code":200,"data":{"l":{"br":128000,"size":1000,"sr":44100},"m":{"br":0,"size":2000,"sr":44100},"h":{"br":320000,"size":3000,"sr":48000},"sq":{"br":900000,"size":9000,"sr":96000},"vi":{"br":1,"size":1,"sr":1},"future":{"br":2,"size":2,"sr":2}}}"#.utf8)
        let privilege = Data(#"{"code":200,"privileges":[{"maxBrLevel":"lossless","playMaxBrLevel":"lossless","plLevel":"exhigh","dlLevel":"lossless","flLevel":"none"}]}"#.utf8)

        let values = try LiveMusicRepository.decodeSongQualityDetails(quality, privileges: privilege)

        #expect(values.map(\.id) == ["lossless", "exhigh", "standard"])
        #expect(values.map(\.isAvailable) == [false, true, true])

        let premium = try LiveMusicRepository.decodeSongQualityDetails(
            Data(#"{"code":200,"data":{"jm":{"br":1900000,"size":19000,"sr":192000},"sk":{"br":900000,"size":9000,"sr":48000}}}"#.utf8),
            privileges: Data(#"{"code":200,"privileges":[{"plLevel":"sky","flLevel":"exhigh"}]}"#.utf8)
        )
        #expect(premium.map(\.id) == ["jymaster", "sky"])
        #expect(premium.allSatisfy { $0.isAvailable })
        #expect(SongQualityDetail.highestAvailableLevel(in: premium) == "jymaster")
    }

    @Test("Copyright decoder accepts empty and recommended song results")
    func copyrightRecommendations() throws {
        let repository = LiveMusicRepository()
        let empty = try repository.decodeCopyrightAlternatives(
            Data(#"{"code":200,"data":{"rcmd":null}}"#.utf8)
        )
        #expect(empty.isEmpty)

        let songs = try repository.decodeCopyrightAlternatives(
            Data(#"{"code":200,"data":{"rcmd":{"id":9,"name":"替代版本","ar":[{"id":8,"name":"歌手"}],"al":{"id":7,"name":"专辑","picUrl":"https://example.com/cover.jpg"},"dt":120000}}}"#.utf8)
        )
        #expect(songs.map(\.id) == [9])
    }

    @MainActor
    @Test("A previous song cannot publish late alternatives")
    func staleAlternativesAreIgnored() async {
        let original = testSong(id: 1, name: "原曲")
        let current = testSong(id: 2, name: "当前歌曲")
        let alternative = testSong(id: 3, name: "可用版本")
        let repository = SwitchingPlaybackRepository(songs: [original, current, alternative])
        let player = PlayerController(
            repository: repository,
            cacheRoot: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString),
            crossfadeDuration: 0
        )

        player.play(original, in: [original])
        await repository.waitForFirstRequest()
        player.play(current, in: [current])
        await repository.releaseFirst(with: alternative)
        try? await Task.sleep(for: .milliseconds(50))

        #expect(player.currentSong?.id == current.id)
        #expect(player.alternativeSongs.isEmpty)
    }

    @MainActor
    @Test("A per-song quality override does not carry into the next song")
    func qualityOverrideIsResetForNextSong() async {
        let first = testSong(id: 1, name: "第一首")
        let second = testSong(id: 2, name: "第二首")
        let repository = QualityRecordingRepository(songs: [first, second])
        let player = PlayerController(
            repository: repository,
            playbackQuality: .lossless,
            cacheRoot: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString),
            crossfadeDuration: 0
        )
        let master = SongQualityDetail(
            id: "jymaster",
            bitrate: 1_900_000,
            size: 19_000,
            sampleRate: 192_000,
            isAvailable: true
        )

        player.play(first, in: [first, second])
        player.selectPlaybackQuality(master)
        #expect(player.selectedPlaybackLevel == "jymaster")

        player.next()
        #expect(player.currentSongID == second.id)
        #expect(player.selectedPlaybackLevel == nil)

        for _ in 0..<20 {
            let requests = await repository.requests()
            if requests.contains("2:level:lossless") { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        let requests = await repository.requests()
        #expect(requests.contains("2:level:lossless"))
        #expect(!requests.contains("2:level:jymaster"))
    }
}

private actor SwitchingPlaybackRepository: MusicRepository {
    nonisolated let homeDescriptors: [HomeSectionDescriptor] = []

    private let songsByID: [Int64: Song]
    private var firstContinuation: CheckedContinuation<PlaybackSource, any Error>?
    private var firstWaiters: [CheckedContinuation<Void, Never>] = []

    init(songs: [Song]) {
        songsByID = Dictionary(uniqueKeysWithValues: songs.map { ($0.id, $0) })
    }

    func playbackSource(for songID: Int64, quality: AudioQuality) async throws -> PlaybackSource {
        if songID == 1 {
            return try await withCheckedThrowingContinuation { continuation in
                firstContinuation = continuation
                firstWaiters.forEach { $0.resume() }
                firstWaiters = []
            }
        }
        return PlaybackSource(url: URL(fileURLWithPath: "/dev/null"), availability: .playable(level: "standard"))
    }

    func playbackSource(for songID: Int64, level: String) async throws -> PlaybackSource {
        try await playbackSource(for: songID, quality: .standard)
    }

    func waitForFirstRequest() async {
        guard firstContinuation == nil else { return }
        await withCheckedContinuation { firstWaiters.append($0) }
    }

    func releaseFirst(with alternative: Song) {
        firstContinuation?.resume(
            throwing: PlaybackUnavailableError(reason: "不可播放", alternatives: [alternative])
        )
        firstContinuation = nil
    }

    func songs(ids: [Int64]) async throws -> [Song] { ids.compactMap { songsByID[$0] } }
    func songQualityDetails(for songID: Int64) async throws -> [SongQualityDetail] { [] }
    func lyrics(for songID: Int64) async throws -> SongLyrics { SongLyrics(lineLyrics: "") }
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
    func homeSection(
        id: String,
        expectedCredentialRevision: UInt64
    ) async throws -> HomeSection { throw AppError.invalidRoute }
    func search(query: String, scope: SearchScope, offset: Int, limit: Int) async throws -> SearchPage {
        throw AppError.invalidRoute
    }
    func detail(
        for route: Route,
        expectedCredentialRevision: UInt64?
    ) async throws -> DetailContent { throw AppError.invalidRoute }
}

private actor QualityRecordingRepository: MusicRepository {
    nonisolated let homeDescriptors: [HomeSectionDescriptor] = []

    private let songsByID: [Int64: Song]
    private var sourceRequests: [String] = []

    init(songs: [Song]) {
        songsByID = Dictionary(uniqueKeysWithValues: songs.map { ($0.id, $0) })
    }

    func playbackSource(for songID: Int64, quality: AudioQuality) async throws -> PlaybackSource {
        sourceRequests.append("\(songID):quality:\(quality.cacheComponent)")
        return PlaybackSource(
            url: URL(fileURLWithPath: "/dev/null"),
            availability: .playable(level: quality.cacheComponent)
        )
    }

    func playbackSource(for songID: Int64, level: String) async throws -> PlaybackSource {
        sourceRequests.append("\(songID):level:\(level)")
        return PlaybackSource(
            url: URL(fileURLWithPath: "/dev/null"),
            availability: .playable(level: level)
        )
    }

    func requests() -> [String] { sourceRequests }
    func songs(ids: [Int64]) async throws -> [Song] { ids.compactMap { songsByID[$0] } }
    func songQualityDetails(for songID: Int64) async throws -> [SongQualityDetail] { [] }
    func lyrics(for songID: Int64) async throws -> SongLyrics { SongLyrics(lineLyrics: "") }
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
    func homeSection(
        id: String,
        expectedCredentialRevision: UInt64
    ) async throws -> HomeSection { throw AppError.invalidRoute }
    func search(query: String, scope: SearchScope, offset: Int, limit: Int) async throws -> SearchPage {
        throw AppError.invalidRoute
    }
    func detail(
        for route: Route,
        expectedCredentialRevision: UInt64?
    ) async throws -> DetailContent { throw AppError.invalidRoute }
}

private func testSong(id: Int64, name: String) -> Song {
    Song(
        id: id,
        name: name,
        artists: [ArtistSummary(id: 1, name: "歌手")],
        album: AlbumSummary(id: 1, name: "专辑", artwork: Artwork(symbol: "music.note", accent: .red)),
        duration: .seconds(120)
    )
}
