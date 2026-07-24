import Foundation

#if !LIVE_MUSIC_EXTRAS_CHECK && canImport(Testing)
import Testing
@testable import TinyCloudMusic

private final class ArtistSongsProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let isArtistSongs = request.url?.path == "/eapi/v1/artist/songs"
        let body = isArtistSongs
            ? #"{"code":200,"songs":[{"id":1,"name":"Song","ar":[{"id":2,"name":"Artist"}],"al":{"id":3,"name":"Album"},"dt":120000}],"more":true,"total":321}"#
            : #"{"code":404}"#
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: isArtistSongs ? 200 : 404,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
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

    let artist: [String: Any] = ["id": 2, "name": "Artist", "musicSize": 321]
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
    guard directMatches.map(\.id) == ["artist-2", "song-1", "album-3", "playlist-4", "user-5"],
          LiveMusicRepository().decodeLiveArtist(artist)?.songCount == 321
    else {
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

    @Test("Artist songs use the paginated all-songs endpoint")
    func artistSongs() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ArtistSongsProtocol.self]
        let transport = EAPITransport(
            session: URLSession(configuration: configuration),
            cookie: "",
            musicU: ""
        )

        let page = try await LiveMusicExtras(transport: transport).artistSongs(artistID: 2)

        #expect(page.songs.map(\.id) == [1])
        #expect(page.offset == 0)
        #expect(page.hasMore)
        #expect(page.total == 321)
    }
}
#endif
