import Foundation
import Testing
@testable import TinyCloudMusic

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
}
