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
        let localRepository = LocalPlaybackRepository(sourceURL: soundURL)
        let crossfadePlayer = PlayerController(
            repository: localRepository,
            playbackQuality: .lossless,
            cacheRoot: FileManager.default.temporaryDirectory,
            crossfadeDuration: 0.2
        )
        let crossfadeSongs = Array(songs.prefix(2))
        crossfadePlayer.play(crossfadeSongs[0], in: crossfadeSongs)
        try await waitUntil { crossfadePlayer.isPlaying && crossfadePlayer.currentSongID == crossfadeSongs[0].id }
        crossfadePlayer.selectPlaybackQuality(SongQualityDetail(
            id: "jymaster",
            bitrate: 1_900_000,
            size: 19_000,
            sampleRate: 192_000,
            isAvailable: true
        ))
        try await waitUntil {
            crossfadePlayer.currentPlaybackLevel == "jymaster"
                && !crossfadePlayer.isSwitchingPlaybackQuality
        }

        crossfadePlayer.next()
        precondition(crossfadePlayer.selectedPlaybackLevel == nil)
        try await waitUntil { crossfadePlayer.isPlaying && crossfadePlayer.currentSongID == crossfadeSongs[1].id }
        let requests = await localRepository.requests()
        precondition(requests.contains("\(crossfadeSongs[1].id):quality:lossless"))
        precondition(!requests.contains("\(crossfadeSongs[1].id):level:jymaster"))
        print("Player queue and crossfade checks passed")
    }
}

@MainActor
private func waitUntil(_ condition: @escaping @MainActor () -> Bool) async throws {
    for _ in 0..<100 {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(50))
    }
    preconditionFailure("Timed out waiting for playback state")
}

private actor LocalPlaybackRepository: MusicRepository {
    let sourceURL: URL
    nonisolated let homeDescriptors: [HomeSectionDescriptor] = []
    private var sourceRequests: [String] = []

    init(sourceURL: URL) {
        self.sourceURL = sourceURL
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

    func songs(ids: [Int64]) async throws -> [Song] { [] }
    func lyrics(for songID: Int64) async throws -> SongLyrics { SongLyrics(lineLyrics: "") }
    func songQualityDetails(for songID: Int64) async throws -> [SongQualityDetail] { [] }
    func recordPlaybackStart(for songID: Int64) async throws {}
    func recordPlayback(for songID: Int64, playedSeconds: Int) async throws {}
    func homeSection(id: String) async throws -> HomeSection { throw AppError.invalidRoute }
    func search(query: String, scope: SearchScope, offset: Int, limit: Int) async throws -> SearchPage {
        throw AppError.invalidRoute
    }
    func detail(for route: Route) async throws -> DetailContent { throw AppError.invalidRoute }
}
