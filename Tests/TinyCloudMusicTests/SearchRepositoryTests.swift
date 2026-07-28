import Foundation
import Testing
@testable import TinyCloudMusic

private final class SearchRepositoryProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var responseData = Data()
    nonisolated(unsafe) private static var capturedURL: URL?
    nonisolated(unsafe) private static var capturedBody = Data()

    static func reset(response: String) {
        lock.withLock {
            responseData = Data(response.utf8)
            capturedURL = nil
            capturedBody = Data()
        }
    }

    static func capturedRequest() -> (url: URL?, body: Data) {
        lock.withLock { (capturedURL, capturedBody) }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body = requestBody(request)
        let responseData = Self.lock.withLock {
            Self.capturedURL = request.url
            Self.capturedBody = body
            return Self.responseData
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: responseData)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private func requestBody(_ request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var body = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            body.append(buffer, count: count)
        }
        return body
    }
}

@Suite("Live search decoding")
struct SearchRepositoryTests {
    private let repository = LiveMusicRepository()

    @Test("New and old song response shapes keep aliases, artwork, and paging")
    func songResponseCompatibility() throws {
        let newPage = repository.decodeSearchPage(
            [
                "data": [
                    "resources": [
                        [
                            "resourceType": "song",
                            "baseInfo": [
                                "simpleSongData": [
                                    "id": 11,
                                    "name": "Song",
                                    "ar": [["id": 21, "name": "Artist"]],
                                    "al": ["id": 31, "name": "Album", "picUrl": "https://img.test/new.jpg"],
                                    "dt": 123_000,
                                    "tns": ["译名"],
                                    "alia": ["别名"]
                                ]
                            ]
                        ],
                        ["resourceType": "mv", "id": 99]
                    ],
                    "totalCount": 3,
                    "hasMore": true
                ]
            ],
            scope: .songs,
            offset: 0
        )
        let oldPage = repository.decodeSearchPage(
            [
                "result": [
                    "songs": [[
                        "id": 12,
                        "name": "Old Song",
                        "artists": [["id": 22, "name": "Old Artist"]],
                        "album": ["id": 32, "name": "Old Album", "picUrl": "https://img.test/old.jpg"],
                        "duration": 62_000,
                        "transNames": ["Old Translation"],
                        "alias": ["Old Alias"]
                    ]],
                    "songCount": 1,
                    "hasMore": false
                ]
            ],
            scope: .songs,
            offset: 0
        )

        #expect(newPage.items.count == 1)
        guard case let .song(newSong) = try #require(newPage.items.first) else {
            Issue.record("Expected a song")
            return
        }
        #expect(newSong.name == "Song (译名) (别名)")
        #expect(newSong.titleMetadata == "(译名) (别名)")
        #expect(newSong.translatedName == "译名")
        #expect(newSong.aliasName == "别名")
        #expect(newSong.album.artwork.remoteURL == URL(string: "https://img.test/new.jpg"))
        #expect(newPage.hasMore)

        guard case let .song(oldSong) = try #require(oldPage.items.first) else {
            Issue.record("Expected a song")
            return
        }
        #expect(oldSong.name == "Old Song (Old Translation) (Old Alias)")
        #expect(oldSong.artistsDisplay == "Old Artist")
        #expect(oldSong.duration == .milliseconds(62_000))
        #expect(!oldPage.hasMore)
    }

    @Test("Artist, album, playlist, and user fields map to live models")
    func typedResults() throws {
        let fixtures: [(SearchScope, String, [String: Any])] = [
            (.artists, "artists", ["id": 1, "name": "Singer", "trans": "歌手", "picUrl": "https://img.test/a.jpg"]),
            (.albums, "albums", ["id": 2, "name": "Record", "artist": ["id": 1, "name": "Singer"], "picUrl": "https://img.test/b.jpg", "subCount": 12]),
            (.playlists, "playlists", ["id": 3, "name": "List", "creator": ["userId": 9, "nickname": "Owner"], "description": "Desc", "coverImgUrl": "https://img.test/c.jpg", "trackCount": 42, "tags": ["摇滚", "现场"], "subscribedCount": 34, "specialType": 5]),
            (.users, "userprofiles", ["userId": 4, "nickname": "User", "signature": "Hi", "avatarUrl": "https://img.test/d.jpg"])
        ]

        for (scope, key, value) in fixtures {
            let page = repository.decodeSearchPage(
                ["result": [key: [value], "hasMore": false]],
                scope: scope,
                offset: 20
            )
            #expect(page.items.count == 1)
            #expect(page.items[0].artwork.remoteURL != nil)
            if case let .album(album) = page.items[0] {
                #expect(album.subscriberCount == 12)
            }
            if case let .playlist(playlist) = page.items[0] {
                #expect(playlist.trackCount == 42)
                #expect(playlist.creatorID == 9)
                #expect(playlist.tags == ["摇滚", "现场"])
                #expect(playlist.subscriberCount == 34)
                #expect(playlist.specialType == 5)
            }
            #expect(!page.hasMore)
        }

        #expect(repository.decodeLivePlaylist([
            "id": 5,
            "cover": "https://img.test/style.jpg"
        ])?.artwork.remoteURL == URL(string: "https://img.test/style.jpg"))
    }

    @Test("User detail keeps the information shown by the Qt app")
    func userDetailFields() throws {
        let profile = try #require(repository.decodeLiveUserDetail([
            "level": 10,
            "listenSongs": 12_345,
            "profile": [
                "userId": 4,
                "nickname": "User",
                "signature": "Signature",
                "gender": 2,
                "detailDescription": "Biography",
                "followeds": 20,
                "follows": 30,
                "followMe": true
            ]
        ]))

        #expect(profile.level == 10)
        #expect(profile.listenSongs == 12_345)
        #expect(profile.gender == 2)
        #expect(profile.detailDescription == "Biography")
        #expect(profile.followerCount == 20)
        #expect(profile.followingCount == 30)
        #expect(profile.followsCurrentUser)
    }

    @Test("Search pages append without duplicate rows")
    func appendingPages() {
        let first = repository.decodeSearchPage(
            ["result": ["artists": [["id": 1, "name": "First"]], "hasMore": true]],
            scope: .artists,
            offset: 0
        )
        let second = repository.decodeSearchPage(
            ["result": ["artists": [["id": 1, "name": "First"], ["id": 2, "name": "Second"]], "hasMore": false]],
            scope: .artists,
            offset: 20
        )

        let combined = first.appending(second)
        #expect(combined.items.map(\.numericID) == [1, 2])
        #expect(combined.offset == 20)
        #expect(!combined.hasMore)
    }

    @Test("MV and video search use cloudsearch and preserve typed routes")
    func videoSearch() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SearchRepositoryProtocol.self]
        let repository = LiveMusicRepository(transport: EAPITransport(
            session: URLSession(configuration: configuration),
            cookie: "",
            musicU: ""
        ))

        SearchRepositoryProtocol.reset(response: #"{"code":200,"result":{"mvs":[{"id":42,"name":"MV","artistName":"Artist","cover":"https://img.test/mv.jpg","duration":120000}],"mvCount":2}}"#)
        let mvPage = try await repository.search(query: "MV Query", scope: .mvs, offset: 0, limit: 20)
        let mvRequest = SearchRepositoryProtocol.capturedRequest()
        #expect(mvRequest.url?.host == "interface3.music.163.com")
        #expect(mvRequest.url?.path == "/eapi/cloudsearch/pc")
        let expectedMVBody = try EAPICodec.requestBody(
            path: "/api/cloudsearch/pc",
            json: compactJSON(["s": "MV Query", "type": 1004, "limit": 20, "offset": 0, "total": true])
        )
        #expect(mvRequest.body == expectedMVBody)
        guard case let .mv(mv) = try #require(mvPage.items.first) else {
            Issue.record("Expected an MV")
            return
        }
        #expect(mv.id == 42)
        #expect(mvPage.items.first?.route == .mv(42))
        #expect(mvPage.hasMore)

        SearchRepositoryProtocol.reset(response: #"{"code":200,"result":{"videos":[{"vid":"22780368","type":0,"title":"MV in video results","creator":[{"userName":"MV Artist"}]},{"vid":"00042-video","type":1,"title":"Video","creator":[{"userName":"Creator"}],"coverUrl":"https://img.test/video.jpg","durationms":34000},{"vid":"ignored","type":99,"title":"Unknown"},{"vid":"missing-type","title":"Ambiguous"}],"videoCount":4}}"#)
        let videoPage = try await repository.search(query: "Video Query", scope: .videos, offset: 0, limit: 20)
        let videoRequest = SearchRepositoryProtocol.capturedRequest()
        #expect(videoRequest.url?.path == "/eapi/cloudsearch/pc")
        let expectedVideoBody = try EAPICodec.requestBody(
            path: "/api/cloudsearch/pc",
            json: compactJSON(["s": "Video Query", "type": 1014, "limit": 20, "offset": 0, "total": true])
        )
        #expect(videoRequest.body == expectedVideoBody)
        #expect(videoPage.items.count == 2)
        guard case let .mv(mvFromVideoSearch) = videoPage.items[0] else {
            Issue.record("Expected a typed MV")
            return
        }
        #expect(mvFromVideoSearch.id == 22_780_368)
        #expect(videoPage.items[0].route == .mv(22_780_368))
        guard case let .video(video) = videoPage.items[1] else {
            Issue.record("Expected a video")
            return
        }
        #expect(video.id == "00042-video")
        #expect(videoPage.items[1].numericID == nil)
        #expect(videoPage.items[1].route == .video("00042-video"))
        #expect(!videoPage.hasMore)
    }
}
