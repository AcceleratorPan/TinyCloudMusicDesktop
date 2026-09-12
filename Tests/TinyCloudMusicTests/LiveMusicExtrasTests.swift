import Foundation

#if !LIVE_MUSIC_EXTRAS_CHECK && canImport(Testing)
import Testing
@testable import TinyCloudMusic

private final class ArtistSongsProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let isArtistSongs = request.url?.path == "/eapi/v1/artist/songs"
        let isAvailablePlaylists = request.url?.path == "/eapi/user/playlist/v1s"
        let body = if isArtistSongs {
            #"{"code":200,"songs":[{"id":1,"name":"Song","ar":[{"id":2,"name":"Artist"}],"al":{"id":3,"name":"Album"},"dt":120000}],"more":true,"total":321}"#
        } else if isAvailablePlaylists {
            #"{"code":200,"playlist":[{"name":"invalid"},{"id":7,"name":"valid","containsTracks":false}],"more":true}"#
        } else {
            #"{"code":404}"#
        }
        let isSuccess = isArtistSongs || isAvailablePlaylists
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: isSuccess ? 200 : 404,
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

        let page = try await LiveMusicExtras(transport: transport).artistSongs(
            artistID: 2,
            expectedCredentialRevision: transport.credentialSnapshotValue().revision
        )

        #expect(page.songs.map(\.id) == [1])
        #expect(page.offset == 0)
        #expect(page.hasMore)
        #expect(page.total == 321)
    }

    @Test("Available-playlist offset advances by raw rows when one row is malformed")
    func availablePlaylistOffset() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ArtistSongsProtocol.self]
        let transport = EAPITransport(
            session: URLSession(configuration: configuration),
            cookie: "",
            musicU: ""
        )

        let page = try await LiveMusicExtras(transport: transport).availablePlaylists(
            userID: 1,
            trackID: 2,
            offset: 20,
            expectedCredentialRevision: transport.credentialSnapshotValue().revision
        )

        #expect(page.playlists.map(\.id) == [7])
        #expect(page.offset == 22)
        #expect(page.hasMore)
    }

    @Test("Available-playlist pages preserve order, raw cursor, and all stop conditions")
    func availablePlaylistAppending() {
        let first = MusicAvailablePlaylistPage(
            playlists: [availablePlaylist(1), availablePlaylist(2)],
            offset: 20,
            hasMore: true
        )
        let merged = first.appending(MusicAvailablePlaylistPage(
            playlists: [availablePlaylist(2), availablePlaylist(3), availablePlaylist(3)],
            offset: 24,
            hasMore: true
        ))

        #expect(merged.playlists.map(\.id) == [1, 2, 3])
        #expect(merged.offset == 24)
        #expect(merged.hasMore)
        #expect(!first.appending(.init(playlists: [], offset: 20, hasMore: true)).hasMore)
        #expect(!first.appending(.init(
            playlists: [availablePlaylist(2)],
            offset: 21,
            hasMore: true
        )).hasMore)
        #expect(!first.appending(.init(
            playlists: [availablePlaylist(3)],
            offset: 20,
            hasMore: true
        )).hasMore)
        #expect(!first.appending(.init(
            playlists: [availablePlaylist(3)],
            offset: 21,
            hasMore: false
        )).hasMore)
    }

    @Test("Available-playlist picker loads one page and scopes retry to the failed cursor")
    func availablePlaylistPickerLoadsOnePageAndStopsOnNoProgress() throws {
        let view = try iosAddSongToPlaylistSource()
        let body = try slice(view, from: "var body: some View {", to: "private var credentialRevision:")
        let footer = try slice(view, from: "private var loadMoreFooter:", to: "private func loadInitialPage(")
        let initial = try slice(view, from: "private func loadInitialPage(", to: "private func loadNextPage(")
        let loadMore = try slice(view, from: "private func loadNextPage(", to: "private func add(")

        #expect(!view.contains("while true"))
        #expect(initial.components(separatedBy: "extras.availablePlaylists(").count == 2)
        #expect(initial.contains("offset: 0"))
        #expect(view.contains("case loaded(MusicAvailablePlaylistPage)"))
        #expect(body.contains("let initialTaskIdentity = initialLoadIdentity"))
        #expect(body.contains(".task(id: initialTaskIdentity)"))
        #expect(body.contains("await loadInitialPage(initialTaskIdentity)"))
        #expect(footer.contains("let loadMoreTaskIdentity = loadMoreIdentity"))
        #expect(footer.contains(".task(id: loadMoreTaskIdentity)"))
        #expect(footer.contains("await loadNextPage(loadMoreTaskIdentity)"))
        #expect(view.components(separatedBy: "loadNextPage(").count == 3)
        #expect(view.contains("@State private var loadMoreOwner: LoadMoreIdentity?"))
        #expect(view.contains("private var isLoadingMore: Bool { loadMoreOwner != nil }"))
        #expect(view.contains("@State private var loadMoreError: String?"))
        #expect(view.contains("IOSInlineRetry(message: loadMoreError)"))
        #expect(view.contains(".refreshable { retryRevision &+= 1 }"))
        #expect(view.contains("_ = session.state"))
        #expect(view.contains("return session.credentialRevision"))
        #expect(view.contains("let userID: Int64"))
        #expect(view.contains("let trackID: Int64"))
        #expect(view.contains("let credentialRevision: UInt64"))
        #expect(initial.contains("phase = .loading"))
        #expect(initial.contains("loadMoreOwner = nil"))
        #expect(initial.contains("loadMoreError = nil"))
        #expect(initial.contains("MusicAvailablePlaylistPage(playlists: [], offset: 0, hasMore: true).appending(page)"))
        #expect(loadMore.contains("loadMoreOwner != identity"))
        #expect(loadMore.contains("loadMoreOwner = identity"))
        #expect(loadMore.contains("if loadMoreOwner == identity { loadMoreOwner = nil }"))
        #expect(loadMore.components(separatedBy: "loadMoreOwner == identity").count == 4)
        #expect(loadMore.contains("let offset = page.offset"))
        #expect(loadMore.contains("offset: offset"))
        #expect(loadMore.contains("current.offset == offset"))
        #expect(loadMore.contains("phase = .loaded(current.appending(next))"))
        #expect(loadMore.contains("loadMoreError = error.localizedDescription"))
        #expect(!loadMore.contains("phase = .failed"))
        #expect(initial.contains("Task.checkCancellation()"))
        #expect(loadMore.contains("Task.checkCancellation()"))
        #expect(initial.contains("!Task.isCancelled"))
        #expect(loadMore.contains("!Task.isCancelled"))
    }

    private func availablePlaylist(_ id: Int64) -> MusicAvailablePlaylist {
        MusicAvailablePlaylist(
            playlist: MusicLibraryPlaylist(
                id: id,
                name: "Playlist \(id)",
                creatorID: 1,
                creatorName: "Creator",
                description: "",
                coverURL: nil,
                trackCount: 0,
                playCount: 0,
                isSubscribed: false,
                subscriberCount: 0
            ),
            containsTrack: false
        )
    }

    private func iosAddSongToPlaylistSource() throws -> String {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appending(path: "iOS/TinyCloudMusicIOS/UI/IOSRootView.swift"),
            encoding: .utf8
        )
        let start = try #require(source.range(of: "private struct IOSAddSongToPlaylistView:")?.lowerBound)
        return String(source[start...])
    }

    private func slice(_ source: String, from start: String, to end: String) throws -> String {
        let lower = try #require(source.range(of: start)?.lowerBound)
        let upper = try #require(source.range(of: end, range: lower..<source.endIndex)?.lowerBound)
        return String(source[lower..<upper])
    }
}
#endif
