import Foundation

@main
enum PersonalFMQueueCheck {
    @MainActor
    static func main() async throws {
        let repository = FixtureMusicRepository()
        guard case let .playlist(_, songs, _, _) = try await repository.detail(for: .playlist(301)),
              songs.count >= 3
        else { preconditionFailure("Fixture playlist is too small") }

        let player = PlayerController(repository: repository, crossfadeDuration: 0)
        player.play(songs[1], in: Array(songs.prefix(3)))
        player.next()
        precondition(player.currentSongID == songs[2].id)
        precondition(player.removeFromQueue(songs[1].id))
        precondition(player.queue.map(\.id) == [songs[0].id, songs[2].id])
        player.previous()
        precondition(player.currentSongID == songs[0].id)

        let soundURL = URL(fileURLWithPath: "/System/Library/Sounds/Glass.aiff")
        precondition(FileManager.default.fileExists(atPath: soundURL.path))
        let heartRepository = LocalPlaybackRepository(
            sourceURL: soundURL,
            heartModeRecommendations: [songs[2]]
        )
        let heartPlayer = PlayerController(
            repository: heartRepository,
            cacheRoot: FileManager.default.temporaryDirectory,
            crossfadeDuration: 0
        )
        heartPlayer.play(songs[0], in: Array(songs.prefix(2)), playlistID: 301)
        try await waitUntil("heart playback start") { await heartRepository.playbackStarts().count >= 1 }
        let heartPlaybackStarts = await heartRepository.playbackStarts()
        precondition(heartPlaybackStarts == ["\(songs[0].id):301"])
        heartPlayer.toggleHeartMode()
        try await waitUntil("heart mode load") { !heartPlayer.isLoadingHeartMode }
        precondition(heartPlayer.isHeartModeEnabled)
        precondition(heartPlayer.queue.map(\.id) == [songs[0].id, songs[2].id])
        let heartRequest = await heartRepository.heartModeRequests().first
        precondition(heartRequest?.seedSongID == songs[0].id)
        precondition(heartRequest?.playlistID == 301)
        precondition(heartRequest?.startSongID == songs[0].id)
        heartPlayer.next()
        precondition(heartPlayer.currentSongID == songs[2].id)
        heartPlayer.toggleHeartMode()
        precondition(!heartPlayer.isHeartModeEnabled)
        precondition(heartPlayer.queue.map(\.id) == songs.prefix(2).map(\.id))
        precondition(heartPlayer.currentSongID == songs[0].id)

        let localRepository = LocalPlaybackRepository(sourceURL: soundURL)
        let crossfadePlayer = PlayerController(
            repository: localRepository,
            playbackQuality: .lossless,
            cacheRoot: FileManager.default.temporaryDirectory,
            crossfadeDuration: 0.2
        )
        let crossfadeSongs = Array(songs.prefix(2))
        crossfadePlayer.play(crossfadeSongs[0], in: crossfadeSongs)
        try await waitUntil("first crossfade song") {
            crossfadePlayer.isPlaying && crossfadePlayer.currentSongID == crossfadeSongs[0].id
        }
        try await waitUntil("first crossfade report") { await localRepository.playbackStarts().count >= 1 }
        crossfadePlayer.selectPlaybackQuality(SongQualityDetail(
            id: "jymaster",
            bitrate: 1_900_000,
            size: 19_000,
            sampleRate: 192_000,
            isAvailable: true
        ))
        try await waitUntil("quality switch") {
            crossfadePlayer.currentPlaybackLevel == "jymaster"
                && !crossfadePlayer.isSwitchingPlaybackQuality
        }

        crossfadePlayer.next()
        precondition(crossfadePlayer.selectedPlaybackLevel == nil)
        try await waitUntil("second crossfade song") {
            crossfadePlayer.isPlaying && crossfadePlayer.currentSongID == crossfadeSongs[1].id
        }
        try await waitUntil("second crossfade report") { await localRepository.playbackStarts().count >= 2 }
        let requests = await localRepository.requests()
        precondition(requests.contains("\(crossfadeSongs[1].id):quality:lossless"))
        precondition(!requests.contains("\(crossfadeSongs[1].id):level:jymaster"))
        let playbackStarts = await localRepository.playbackStarts()
        precondition(playbackStarts == crossfadeSongs.map { "\($0.id):\($0.id)" })

        let failedStartRepository = LocalPlaybackRepository(
            sourceURL: soundURL,
            playbackStartFails: true
        )
        let failedStartPlayer = PlayerController(
            repository: failedStartRepository,
            cacheRoot: FileManager.default.temporaryDirectory,
            crossfadeDuration: 0
        )
        failedStartPlayer.play(songs[0], in: [songs[0]])
        try await waitUntil("failed playback reports") {
            await failedStartRepository.playbackEvents().count >= 1
                && failedStartPlayer.playbackReportErrorMessage != nil
        }
        let failedStartEvents = await failedStartRepository.playbackEvents()
        precondition(failedStartEvents == ["pld"])
        precondition(failedStartPlayer.playbackReportErrorMessage?.contains("clientlog3.music.163.com") == true)

        let repeatRepository = LocalPlaybackRepository(sourceURL: soundURL, playbackStartDelay: .seconds(2))
        let repeatPlayer = PlayerController(
            repository: repeatRepository,
            cacheRoot: FileManager.default.temporaryDirectory,
            crossfadeDuration: 0
        )
        repeatPlayer.cycleRepeatMode()
        repeatPlayer.cycleRepeatMode()
        repeatPlayer.play(songs[0], in: [songs[0]])
        try await waitUntil("repeat playback reports") {
            await repeatRepository.playbackEvents().count >= 3
        }
        let repeatEvents = await repeatRepository.playbackEvents()
        precondition(Array(repeatEvents.prefix(3)) == ["plv", "pld", "plv"])
        print("Player queue and crossfade checks passed")
    }
}

@MainActor
private func waitUntil(
    _ label: String,
    _ condition: @escaping @MainActor () async -> Bool
) async throws {
    for _ in 0..<200 {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(50))
    }
    preconditionFailure("Timed out waiting for \(label)")
}

private actor LocalPlaybackRepository: MusicRepository {
    let sourceURL: URL
    nonisolated let homeDescriptors: [HomeSectionDescriptor] = []
    private let heartModeRecommendations: [Song]
    private let playbackStartDelay: Duration
    private let playbackStartFails: Bool
    private var sourceRequests: [String] = []
    private var recordedHeartModeRequests: [HeartModeRequest] = []
    private var recordedPlaybackStarts: [String] = []
    private var recordedPlaybackEvents: [String] = []

    init(
        sourceURL: URL,
        heartModeRecommendations: [Song] = [],
        playbackStartDelay: Duration = .zero,
        playbackStartFails: Bool = false
    ) {
        self.sourceURL = sourceURL
        self.heartModeRecommendations = heartModeRecommendations
        self.playbackStartDelay = playbackStartDelay
        self.playbackStartFails = playbackStartFails
    }

    func playbackSource(for songID: Int64, quality: AudioQuality) async throws -> PlaybackSource {
        sourceRequests.append("\(songID):quality:\(quality.cacheComponent)")
        return PlaybackSource(url: sourceURL, availability: .playable(level: "standard"))
    }

    func playbackSource(for songID: Int64, level: String) async throws -> PlaybackSource {
        sourceRequests.append("\(songID):level:\(level)")
        return PlaybackSource(url: sourceURL, availability: .playable(level: level))
    }

    func requests() -> [String] { sourceRequests }

    func heartModeSongs(seedSongID: Int64, playlistID: Int64?, startSongID: Int64) async throws -> [Song] {
        recordedHeartModeRequests.append(HeartModeRequest(
            seedSongID: seedSongID,
            playlistID: playlistID,
            startSongID: startSongID
        ))
        return heartModeRecommendations
    }

    func heartModeRequests() -> [HeartModeRequest] { recordedHeartModeRequests }
    func playbackStarts() -> [String] { recordedPlaybackStarts }
    func playbackEvents() -> [String] { recordedPlaybackEvents }

    func songs(ids: [Int64]) async throws -> [Song] { [] }
    func lyrics(for songID: Int64) async throws -> SongLyrics { SongLyrics(lineLyrics: "") }
    func songQualityDetails(for songID: Int64) async throws -> [SongQualityDetail] { [] }
    func recordPlaybackStart(
        for songID: Int64,
        sourceID: Int64,
        totalSeconds: Int,
        expectedCredentialRevision: UInt64
    ) async throws {
        if playbackStartFails { throw URLError(.timedOut) }
        try await Task.sleep(for: playbackStartDelay)
        recordedPlaybackStarts.append("\(songID):\(sourceID)")
        recordedPlaybackEvents.append("plv")
    }
    func recordPlayback(
        for songID: Int64,
        sourceID: Int64,
        playedSeconds: Int,
        totalSeconds: Int,
        expectedCredentialRevision: UInt64
    ) async throws {
        recordedPlaybackEvents.append("pld")
    }
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

private struct HeartModeRequest: Sendable {
    let seedSongID: Int64
    let playlistID: Int64?
    let startSongID: Int64
}
