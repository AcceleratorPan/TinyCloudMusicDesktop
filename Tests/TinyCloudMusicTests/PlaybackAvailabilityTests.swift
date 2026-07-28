import Foundation
import Testing
@testable import TinyCloudMusic

@Suite("Playback availability")
struct PlaybackAvailabilityTests {
    @Test("Playable, trial, and unavailable entries map to stable states")
    func playbackMappings() throws {
        let playable = try LiveMusicRepository.decodePlaybackSource(
            Data(#"{"code":200,"data":[{"id":1,"url":"https://m1.music.126.net/1.mp3","code":200,"level":"exhigh","type":"mp3","fee":0,"payed":0,"message":null,"freeTrialInfo":null}]}"#.utf8),
            expectedSongID: 1,
            requestedLevel: "standard"
        )
        #expect(playable.availability == .playable(level: "exhigh"))

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
            if requests.contains("2:quality:lossless") { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        let requests = await repository.requests()
        #expect(requests.contains("2:quality:lossless"))
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
    func recordPlaybackStart(for songID: Int64, sourceID: Int64, totalSeconds: Int) async throws {}
    func recordPlayback(
        for songID: Int64,
        sourceID: Int64,
        playedSeconds: Int,
        totalSeconds: Int
    ) async throws {}
    func homeSection(id: String) async throws -> HomeSection { throw AppError.invalidRoute }
    func search(query: String, scope: SearchScope, offset: Int, limit: Int) async throws -> SearchPage {
        throw AppError.invalidRoute
    }
    func detail(for route: Route) async throws -> DetailContent { throw AppError.invalidRoute }
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
    func recordPlaybackStart(for songID: Int64, sourceID: Int64, totalSeconds: Int) async throws {}
    func recordPlayback(
        for songID: Int64,
        sourceID: Int64,
        playedSeconds: Int,
        totalSeconds: Int
    ) async throws {}
    func homeSection(id: String) async throws -> HomeSection { throw AppError.invalidRoute }
    func search(query: String, scope: SearchScope, offset: Int, limit: Int) async throws -> SearchPage {
        throw AppError.invalidRoute
    }
    func detail(for route: Route) async throws -> DetailContent { throw AppError.invalidRoute }
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
