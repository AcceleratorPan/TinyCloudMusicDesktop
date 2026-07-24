import Foundation

#if !VIDEO_CHECK && canImport(Testing)
import Testing
@testable import TinyCloudMusic
#endif

private enum VideoCheckError: Error {
    case failed
}

private func verifyVideoFixtures() throws {
    let mv = VideoDecoder.mvDetail([
        "data": [
            "id": 42,
            "name": "MV",
            "artistName": "Artist",
            "cover": "https://p1.music.126.net/mv.jpg",
            "duration": 12_000,
            "subed": true,
            "brs": ["1080": "url", "480": "url"]
        ]
    ])
    let video = VideoDecoder.videoDetail([
        "data": [
            "vid": "00042",
            "title": "Video",
            "creator": ["nickname": "Creator"],
            "coverUrl": "https://p1.music.126.net/video.jpg",
            "durationms": 34_000,
            "resolutions": [["resolution": 720], ["resolution": 480]]
        ]
    ])
    let mixed = VideoDecoder.recommendations(["code": 200, "data": [
        [
            "type": 0,
            "id": 42,
            "title": "MV",
            "artists": [["name": "Artist"]]
        ],
        [
            "type": 1,
            "vid": "00042",
            "title": "Video",
            "creator": [["userName": "Creator"]]
        ],
        ["type": 99, "id": "ignored", "title": "Unsupported"]
    ]])
    guard mv?.id == 42,
          mv?.availableResolutions == [1080, 480],
          video?.id == "00042",
          video?.creatorName == "Creator",
          video?.availableResolutions == [720, 480],
          mixed.map(\.id) == ["mv-42", "video-00042"],
          mixed.map({ item in
              switch item {
              case let .mv(value): value.artistName
              case let .video(value): value.creatorName
              }
          }) == ["Artist", "Creator"]
    else { throw VideoCheckError.failed }
}

private func verifyVideoValidation() throws {
    guard try CommentResource.mv(42).threadID() == "R_MV_5_42",
          try CommentResource.video(" 00042 ").threadID() == "R_VI_62_00042",
          try CommentResource.video("a/b").encodedThreadID() == "R_VI_62_a%2Fb",
          VideoResolutionPolicy.preferred(1080, available: [720, 480]) == 720,
          VideoResolutionPolicy.fallback(below: 720, available: [1080, 720, 480]) == 480,
          VideoPlaybackURLPolicy.isAllowed(URL(string: "https://vodkgeyttp9.vod.126.net/file.mp4")!),
          !VideoPlaybackURLPolicy.isAllowed(URL(string: "http://vodkgeyttp9.vod.126.net/file.mp4")!),
          try VideoPlaybackURLPolicy.validate("http://vodkgeyttp9.vod.126.net/file.mp4").scheme == "https",
          !VideoPlaybackURLPolicy.isAllowed(URL(string: "https://vod.126.net.evil.test/file.mp4")!)
    else { throw VideoCheckError.failed }

    for resource in [CommentResource.mv(0), .video(" \n "), .video("https://example.com/video")] {
        do {
            _ = try resource.threadID()
            throw VideoCheckError.failed
        } catch EAPIError.invalidPayload {
        }
    }

    let now = Date(timeIntervalSince1970: 1_000)
    let source = try VideoDecoder.videoPlaybackSource([
        "urls": [
            ["url": "https://vodkgeyttp9.vod.126.net/low.mp4", "r": 480],
            [
                "url": "https://vodkgeyttp9.vod.126.net/file.mp4",
                "r": 720,
                "validity": 1_200
            ]
        ]
    ], requestedResolution: 720, now: now)
    guard source.resolution == 720,
          source.url.lastPathComponent == "file.mp4",
          source.expiresAt == Date(timeIntervalSince1970: 2_200)
    else { throw VideoCheckError.failed }

    for root in [
        ["data": ["url": "http://unknown.example/file.mp4"]],
        ["data": ["url": "https://unknown.example/file.mp4"]],
        ["data": ["url": ""]]
    ] {
        do {
            _ = try VideoDecoder.mvPlaybackSource(root, requestedResolution: 480)
            throw VideoCheckError.failed
        } catch is VideoLibraryError {
        }
    }
}

private func verifyVideoCommentPage() throws {
    let page = MusicLibraryDecoder.readOnlyCommentPage(
        [
            "total": 41,
            "more": true,
            "comments": [[
                "commentId": 7,
                "user": ["userId": 8, "nickname": "Listener"],
                "content": "Nice",
                "time": 123
            ]]
        ],
        resource: .video("video-id"),
        offset: 20,
        limit: 20
    )
    guard page.comments.map(\.id) == [7],
          page.totalCount == 41,
          page.nextOffset == 40,
          page.beforeTime == 123,
          page.hasMore
    else { throw VideoCheckError.failed }
}

#if VIDEO_CHECK
@main
private enum VideoCheck {
    static func main() throws {
        try verifyVideoFixtures()
        try verifyVideoValidation()
        try verifyVideoCommentPage()
        print("MV and video check passed")
    }
}
#elseif canImport(Testing)
@Suite("MV and video")
struct VideoTests {
    @Test("MV and video fixtures retain distinct ID types")
    func fixtureDecoding() throws { try verifyVideoFixtures() }

    @Test("IDs, playback URLs, and resolutions are validated")
    func validation() throws { try verifyVideoValidation() }

    @Test("Read-only comments keep pagination metadata")
    func commentPage() throws { try verifyVideoCommentPage() }
}
#endif
