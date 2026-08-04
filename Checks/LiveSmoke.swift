import Foundation

@main
enum LiveSmoke {
    static func main() async throws {
        let repository = LiveMusicRepository()
        let page = try await repository.search(query: "周杰伦", scope: .songs, offset: 0, limit: 20)
        guard let song = page.items.compactMap({ item -> Song? in
            guard case let .song(song) = item else { return nil }
            return song
        }).first else {
            throw AppError.unavailable("Live search returned no songs")
        }

        let lyric = try await repository.lyrics(for: song.id)
        let home = try await repository.homeSection(
            id: "PAGE_RECOMMEND_SPECIAL_CLOUD_VILLAGE_PLAYLIST",
            expectedCredentialRevision: repository.currentCredentialRevision
        )
        let candidates = page.items.compactMap { item -> Song? in
            guard case let .song(song) = item else { return nil }
            return song
        }
        let playableAudioURL: URL? = await withTaskGroup(of: URL?.self) { group in
            for candidate in candidates.prefix(10) {
                group.addTask { try? await repository.audioURL(for: candidate.id) }
            }
            for await url in group {
                if let url {
                    group.cancelAll()
                    return url
                }
            }
            return nil
        }
        guard let playableAudioURL else { throw AppError.unavailable("No playable audio URL") }
        var audioRequest = URLRequest(url: playableAudioURL)
        audioRequest.setValue("bytes=0-4095", forHTTPHeaderField: "Range")
        let (audioData, response) = try await URLSession.shared.data(for: audioRequest)
        guard let response = response as? HTTPURLResponse,
              [200, 206].contains(response.statusCode), !audioData.isEmpty
        else { throw AppError.unavailable("Playable audio returned no bytes") }
        print("Live smoke passed: search=\(page.items.count), lyric=\(!lyric.lineLyrics.isEmpty), audio=true, home=\(home.items.count)")
    }
}
