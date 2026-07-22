import Foundation

#if !LIVE_MUSIC_EXTRAS_CHECK && canImport(Testing)
import Testing
@testable import TinyCloudMusic
#endif

private enum LiveMusicExtrasCheckError: Error {
    case failed
}

private func verifyExtraDecoders() throws {
    let playlists: [String: Any] = [
        "playlist": [
            ["id": 1, "specialType": 0],
            ["id": 9, "specialType": 5]
        ]
    ]
    guard MusicExtraDecoder.favoritePlaylistID(playlists) == 9 else {
        throw LiveMusicExtrasCheckError.failed
    }

    let ids = MusicExtraDecoder.trackIDs(["trackIds": [["id": 7], ["id": 8]]])
    let keywords = MusicExtraDecoder.searchKeywords([
        "data": ["keywords": [["showKeyword": "Shown", "realkeyword": "Query"]]]
    ])
    guard ids == [7, 8], keywords.first?.display == "Shown", keywords.first?.query == "Query" else {
        throw LiveMusicExtrasCheckError.failed
    }

    let hotSearch = MusicExtraDecoder.hotSearch([
        "data": [
            [
                "searchWord": "First",
                "content": "Rising",
                "score": 12,
                "iconUrl": "https://example.com/hot.png",
                "iconType": 4,
                "alg": "featured"
            ],
            ["searchWord": "  "],
            ["searchWord": "Second", "iconUrl": "http://example.com/insecure.png"]
        ]
    ])
    guard hotSearch.map(\.keyword) == ["First", "Second"],
          hotSearch.first?.detail == "Rising",
          hotSearch.first?.iconURL?.scheme == "https",
          hotSearch.first?.iconType == 4,
          hotSearch.first?.algorithm == "featured",
          hotSearch.last?.iconURL == nil
    else { throw LiveMusicExtrasCheckError.failed }

    let artist: [String: Any] = ["id": 2, "name": "Artist"]
    let directMatches = MusicExtraDecoder.searchDirectMatches(
        [
            "result": [
                "orders": ["artists", "songs", "albums", "playlists", "userprofiles", "artist"],
                "artists": [artist],
                "songs": [[
                    "id": 1,
                    "name": "Song",
                    "artists": [artist],
                    "album": ["id": 3, "name": "Album"]
                ]],
                "albums": [["id": 3, "name": "Album", "artist": artist]],
                "playlists": [["id": 4, "name": "Playlist", "creator": ["userId": 9, "nickname": "Creator"]]],
                "userprofiles": [["userId": 5, "nickname": "User"]]
            ]
        ],
        repository: LiveMusicRepository()
    )
    guard directMatches.map(\.id) == ["artist-2", "song-1", "album-3", "playlist-4", "user-5"] else {
        throw LiveMusicExtrasCheckError.failed
    }
}

#if LIVE_MUSIC_EXTRAS_CHECK
@main
private enum LiveMusicExtrasCheck {
    static func main() throws {
        try verifyExtraDecoders()
        print("Live music extras decoder check passed")
    }
}
#elseif canImport(Testing)
@Suite("Live music extras")
struct LiveMusicExtrasTests {
    @Test("Extra search fixtures decode and deduplicate")
    func fixtureDecoders() throws {
        try verifyExtraDecoders()
    }
}
#endif
