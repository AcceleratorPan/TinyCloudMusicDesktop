import Foundation

#if !LIVE_MUSIC_LIBRARY_CHECK && canImport(Testing)
import Testing
@testable import TinyCloudMusic
#endif

private enum LiveMusicLibraryCheckError: Error {
    case failed
}

private func verifyLibraryDecoders() throws {
    let recentSongs = LiveMusicLibrary().decodeRecentlyPlayedSongs([
        "data": ["list": [[
            "data": [
                "id": 42,
                "name": "recent",
                "ar": [["id": 7, "name": "artist"]],
                "al": ["id": 8, "name": "album", "picUrl": "https://example.com/cover.jpg"],
                "dt": 123_000
            ]
        ]]]
    ])
    guard recentSongs.count == 1,
          recentSongs[0].id == 42,
          recentSongs[0].artists.first?.id == 7,
          recentSongs[0].album.id == 8,
          recentSongs[0].duration == .seconds(123)
    else { throw LiveMusicLibraryCheckError.failed }

    let recentAlbums = LiveMusicLibrary().decodeRecentlyPlayedAlbums([
        "data": ["list": [
            ["album": [
                "id": 51,
                "name": "recent album",
                "artist": ["id": 7, "name": "artist"],
                "picUrl": "https://example.com/album.jpg"
            ]],
            ["data": [
                "id": 51,
                "name": "duplicate album",
                "artist": ["id": 7, "name": "artist"]
            ]]
        ]]
    ])
    guard recentAlbums.map(\.id) == [51], recentAlbums[0].name == "recent album"
    else { throw LiveMusicLibraryCheckError.failed }

    let recentPlaylists = LiveMusicLibrary().decodeRecentlyPlayedPlaylists([
        "data": ["list": [
            ["playlist": [
                "id": 61,
                "name": "recent playlist",
                "creator": ["userId": 8, "nickname": "creator"],
                "coverImgUrl": "https://example.com/playlist.jpg"
            ]],
            ["data": [
                "id": 61,
                "name": "duplicate playlist",
                "creator": ["userId": 8, "nickname": "creator"]
            ]]
        ]]
    ])
    guard recentPlaylists.map(\.id) == [61], recentPlaylists[0].name == "recent playlist"
    else { throw LiveMusicLibraryCheckError.failed }

    let recentVideos = LiveMusicLibrary().decodeRecentlyPlayedMedia([
        "data": ["list": [
            [
                "resourceId": "wrong-outer-video-id",
                "playTime": 1_700_000_000_000,
                "data": [
                    "id": 999,
                    "uuid": "A1B2-video",
                    "threadId": "R_VI_62_A1B2-video",
                    "title": "recent video",
                    "coverUrl": "https://example.com/video.jpg",
                    "creator": [["userName": "video creator"]]
                ]
            ],
            [
                "resourceId": "different-duplicate-id",
                "data": ["vid": "A1B2-video", "type": 1, "title": "duplicate video"]
            ],
            [
                "resourceId": "wrong-outer-mv-id",
                "data": ["id": 42, "uuid": "wrong-mv-uuid", "isMV": true, "title": "recent MV"]
            ],
            [
                "resourceId": "wrong-outer-numeric-video-id",
                "data": ["vid": "00042", "isMV": false, "title": "numeric video"]
            ],
            ["resourceType": "MLOG", "data": ["id": "typed-video", "title": "typed video"]],
            ["resourceType": "VIDEO", "data": ["id": "video-alias", "title": "typed video alias"]],
            ["resourceType": "MV", "data": ["id": 45, "title": "typed MV"]],
            ["resourceType": 5, "data": ["id": "numeric-video", "title": "numeric typed video"]],
            ["resourceType": 1, "data": ["id": 46, "title": "numeric typed MV"]],
            ["resourceId": "wrong-mv-vid", "data": ["vid": "47", "type": 0, "title": "MV using vid"]],
            ["resourceId": "wrong-thread-mv", "data": ["threadId": "R_MV_5_48", "title": "thread MV"]],
            ["resourceId": "wrong-thread-video", "data": ["threadId": "R_VI_62_thread-video", "title": "thread video"]],
            ["data": ["vid": "12345", "title": "video identified by vid"]],
            ["data": ["mvId": 43, "title": "MV identified by mvId"]],
            ["data": ["id": 44, "title": "ambiguous resource"]],
            ["video": ["vid": "missing-title"]]
        ]]
    ], kind: .video)
    guard recentVideos.map(\.resourceID) == [
        "A1B2-video", "42", "00042", "typed-video", "video-alias", "45", "numeric-video", "46",
        "47", "48", "thread-video", "12345", "43", "44"
    ], recentVideos.map(\.videoKind) == [
        .video, .mv, .video, .video, .video, .mv, .video, .mv, .mv, .mv, .video, .video,
        .mv, nil
    ],
          recentVideos[0].subtitle == "video creator",
          recentVideos[0].playedAt?.timeIntervalSince1970 == 1_700_000_000
    else { throw LiveMusicLibraryCheckError.failed }

    let recentVoices = LiveMusicLibrary().decodeRecentlyPlayedMedia([
        "data": ["list": [[
            "voice": [
                "voiceId": 71,
                "name": "recent voice",
                "coverUrl": "https://example.com/voice.jpg",
                "dj": ["nickname": "voice creator"]
            ]
        ]]]
    ], kind: .voice)
    guard recentVoices.map(\.resourceID) == ["71"],
          recentVoices[0].subtitle == "voice creator"
    else { throw LiveMusicLibraryCheckError.failed }

    let recentPodcasts = LiveMusicLibrary().decodeRecentlyPlayedMedia([
        "data": ["list": [[
            "djRadio": [
                "id": 81,
                "name": "recent podcast",
                "picUrl": "https://example.com/podcast.jpg",
                "dj": ["nickname": "podcast creator"]
            ]
        ]]]
    ], kind: .podcast)
    guard recentPodcasts.map(\.resourceID) == ["81"],
          recentPodcasts[0].title == "recent podcast"
    else { throw LiveMusicLibraryCheckError.failed }

    let listeningRecords = LiveMusicLibrary().decodeListeningRecords([
        "weekData": [[
            "playCount": 6,
            "score": 98,
            "song": [
                "id": 43,
                "name": "weekly",
                "ar": [["id": 9, "name": "artist"]],
                "al": ["id": 10, "name": "album"],
                "dt": 180_000
            ]
        ]]
    ], period: .week)
    guard listeningRecords.count == 1,
          listeningRecords[0].song.id == 43,
          listeningRecords[0].playCount == 6,
          listeningRecords[0].score == 98
    else { throw LiveMusicLibraryCheckError.failed }

    let totalListeningDuration = try LiveMusicLibrary().decodeTotalListeningDuration([
        "code": 200,
        "data": ["totalDuration": 1_219_210]
    ])
    guard totalListeningDuration == 1_219_210 else {
        throw LiveMusicLibraryCheckError.failed
    }

    let fmTracks = LiveMusicLibrary().decodePersonalFM([
        "data": [
            [
                "id": 44,
                "name": "fm",
                "alg": "itembased",
                "ar": [["id": 9, "name": "artist"]],
                "al": ["id": 10, "name": "album"],
                "dt": 180_000
            ],
            [
                "id": 45,
                "name": "fallback",
                "ar": [["id": 9, "name": "artist"]],
                "al": ["id": 10, "name": "album"],
                "dt": 180_000
            ]
        ]
    ])
    guard fmTracks.map(\.id) == [44, 45],
          fmTracks.map(\.algorithm) == ["itembased", "RT"]
    else { throw LiveMusicLibraryCheckError.failed }

    let page = MusicLibraryDecoder.commentPage(
        [
            "data": [
                "cursor": "next",
                "hasMore": true,
                "sortType": 2,
                "totalCount": 1,
                "comments": [[
                    "commentId": 99,
                    "user": ["userId": 7, "nickname": "listener"],
                    "content": "hello",
                    "timeStr": "today",
                    "likedCount": 0,
                    "liked": true,
                    "replyCount": 1
                ]]
            ]
        ],
        songID: 42
    )
    guard page.cursor == "next", page.hasMore, page.comments.first?.id == 99,
          page.comments.first?.songID == 42, page.comments.first?.userID == 7,
          page.comments.first?.nickname == "listener", page.comments.first?.isLiked == true,
          page.comments.first?.settingLiked(false).likedCount == 0,
          page.comments.first?.settingLiked(false).settingLiked(true).likedCount == 1,
          page.comments.first?.addingReply().replyCount == 2
    else { throw LiveMusicLibraryCheckError.failed }

    let writtenComment = MusicLibraryDecoder.writtenComment([
        "data": ["comment": [
            "commentId": 101,
            "user": ["userId": 7, "nickname": "listener"],
            "content": "written"
        ]]
    ], songID: 42)
    guard writtenComment?.id == 101, writtenComment?.content == "written" else {
        throw LiveMusicLibraryCheckError.failed
    }

    let count = MusicLibraryDecoder.commentCount(
        ["data": [[
            "resourceId": 42,
            "commentCount": 10_234_567,
            "commentCountDesc": "999w+"
        ]]],
        songID: 42
    )
    guard count == MusicCommentCount(count: 10_234_567, displayText: "999w+") else {
        throw LiveMusicLibraryCheckError.failed
    }

    let floor = MusicLibraryDecoder.commentFloorPage(
        ["data": [
            "cursor": "floor-next",
            "time": 123,
            "hasMore": true,
            "comments": [
                [
                    "commentId": 100,
                    "user": ["userId": 8, "nickname": "replier"],
                    "content": "reply",
                    "beReplied": [[
                        "beRepliedCommentId": 99,
                        "user": ["nickname": "owner"]
                    ]]
                ],
                [
                    "commentId": 101,
                    "user": ["userId": 9, "nickname": "nested"],
                    "content": "nested reply",
                    "beReplied": [[
                        "beRepliedCommentId": 100,
                        "user": ["nickname": "replier"]
                    ]]
                ]
            ]
        ]],
        songID: 42,
        parentCommentID: 99
    )
    guard floor.cursor == "floor-next", floor.time == 123, floor.hasMore,
          floor.comments.first?.userID == 8,
          floor.comments.first?.replyToNickname == nil,
          floor.comments.last?.displayContent == "回复replier：nested reply"
    else { throw LiveMusicLibraryCheckError.failed }

    let emojiPictureIDs = MusicLibraryDecoder.commentEmojiPictureIDs([
        "data": ["emojis": [
            ["emojiName": "爆笑", "picId": 123],
            ["emojiName": "重复", "picId": 1],
            ["emojiName": "重复", "picId": 2],
            ["emojiName": "", "picId": 3],
            ["emojiName": "无图片", "picId": 0]
        ]]
    ])
    guard emojiPictureIDs == ["[爆笑]": "123", "[重复]": "2"] else {
        throw LiveMusicLibraryCheckError.failed
    }

    let playlist = MusicLibraryDecoder.playlist([
        "playlist": ["id": 8, "name": "mix", "playCount": 12]
    ])
    guard playlist?.id == 8, playlist?.name == "mix", playlist?.playCount == 12 else {
        throw LiveMusicLibraryCheckError.failed
    }

    let userFollow = MusicLibraryDecoder.mixedFollow([
        "type": 1,
        "followDay": "8天",
        "userProfile": [
            "userId": 9,
            "nickname": "listener",
            "avatarUrl": "https://example.com/user.jpg"
        ]
    ])
    let artistFollow = MusicLibraryDecoder.mixedFollow([
        "type": 3,
        "artistInfo": [
            "id": 10,
            "name": "artist",
            "picUrl": "https://example.com/artist.jpg"
        ]
    ])
    guard userFollow?.kind == .user,
          userFollow?.imageURL?.absoluteString == "https://example.com/user.jpg",
          artistFollow?.kind == .artist,
          artistFollow?.imageURL?.absoluteString == "https://example.com/artist.jpg"
    else { throw LiveMusicLibraryCheckError.failed }
}

private func verifyRecentPlaybackState() throws {
    var state = RecentPlaybackState()
    state.reset(accountID: 1)
    let oldGeneration = state.generation
    guard state.accept(
        .loaded(.albums([])),
        for: .album,
        generation: oldGeneration,
        accountID: 1
    ), state.load(for: .album) == .loaded(.albums([])),
       state.load(for: .song) == .idle
    else { throw LiveMusicLibraryCheckError.failed }

    state.reset(accountID: 2)
    guard !state.accept(
        .loaded(.songs([])),
        for: .song,
        generation: oldGeneration,
        accountID: 1
    ), state.load(for: .song) == .idle
    else { throw LiveMusicLibraryCheckError.failed }
}

private func verifyRecentPlaybackLimit() async throws {
    let library = LiveMusicLibrary()
    let credentialRevision = library.transport.credentialSnapshotValue().revision
    for limit in [0, 101] {
        do {
            _ = try await library.recentlyPlayedPodcasts(
                limit: limit,
                expectedCredentialRevision: credentialRevision
            )
            throw LiveMusicLibraryCheckError.failed
        } catch EAPIError.invalidPayload {
        }
    }
}

#if LIVE_MUSIC_LIBRARY_CHECK
@main
private enum LiveMusicLibraryCheck {
    static func main() async throws {
        try verifyLibraryDecoders()
        try verifyRecentPlaybackState()
        try await verifyRecentPlaybackLimit()
        print("Live music library decoder check passed")
    }
}
#elseif canImport(Testing)
@Suite("Live music library")
struct LiveMusicLibraryTests {
    @Test("Comment and playlist fixtures decode")
    func fixtureDecoders() throws {
        try verifyLibraryDecoders()
        try verifyRecentPlaybackState()
    }

    @Test("Recent playback limit is checked before networking")
    func recentPlaybackLimit() async throws {
        try await verifyRecentPlaybackLimit()
    }
}
#endif
