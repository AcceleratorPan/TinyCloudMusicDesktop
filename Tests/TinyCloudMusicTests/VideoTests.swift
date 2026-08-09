import Foundation

#if !VIDEO_CHECK && canImport(Testing)
import AppKit
import AVKit
import SwiftUI
import Testing
@testable import TinyCloudMusic

private struct NativeVideoPlayerHostingHarness: View {
    let player: AVPlayer?

    var body: some View {
        Group {
            if let player {
                NativeVideoPlayerView(player: player)
            } else {
                Color.black
            }
        }
        .frame(width: 640, height: 360)
    }
}

@MainActor
private func containsAVPlayerView(_ view: NSView) -> Bool {
    view is AVPlayerView || view.subviews.contains(where: containsAVPlayerView)
}
#endif

private enum VideoCheckError: Error {
    case failed
}

private func verifyVideoFixtures() throws {
    let mv = VideoDecoder.mvDetail([
        "subed": true,
        "data": [
            "id": 42,
            "name": "MV",
            "artistName": "Artist",
            "cover": "https://p1.music.126.net/mv.jpg",
            "desc": "MV description",
            "publishTime": "2026-07-28",
            "playCount": 123,
            "duration": 12_000,
            "brs": ["1080": "url", "480": "url"]
        ]
    ])
    let video = VideoDecoder.videoDetail([
        "subscribed": true,
        "data": [
            "vid": "00042",
            "title": "Video",
            "creator": ["nickname": "Creator"],
            "coverUrl": "https://p1.music.126.net/video.jpg",
            "description": "Video description",
            "publishTime": "2026-07-27",
            "playTime": 456,
            "durationms": 34_000,
            "resolutions": [["resolution": 720], ["resolution": 480]]
        ]
    ])
    let mvWithArrayResolutions = VideoDecoder.mvDetail([
        "data": [
            "id": 44,
            "name": "New MV",
            "brs": [["br": 1_500_000], ["r": 720], ["resolution": 480]]
        ]
    ])
    let mvWithoutBitrates = VideoDecoder.mvDetail(["data": ["id": 45, "name": "Fallback MV"]])
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
    let personalized = VideoDecoder.personalizedMVs(["result": [[
        "id": 43,
        "name": "Featured MV",
        "artistName": "Featured Artist",
        "picUrl": "https://p1.music.126.net/featured.jpg"
    ]]])
    let firstSubscriptions = VideoDecoder.subscriptions([
        "count": 5,
        "hasMore": true,
        "data": [
            [
                "type": 0,
                "vid": "4201",
                "title": "Saved MV",
                "creator": [["userName": "Saved Artist"]]
            ],
            [
                "type": 1,
                "vid": "saved-video",
                "title": "Saved Video",
                "creator": [["userName": "Saved Creator"]]
            ],
            ["type": 99, "vid": "unsupported"]
        ]
    ], offset: 0, limit: 3)
    let subscriptions = firstSubscriptions.appending(VideoDecoder.subscriptions([
        "count": 5,
        "hasMore": false,
        "data": [
            ["type": 1, "vid": "saved-video", "title": "Duplicate"],
            ["type": 0, "vid": "4202", "title": "Another MV"]
        ]
    ], offset: firstSubscriptions.nextOffset, limit: 3))
    guard mv?.id == 42,
          mv?.isSubscribed == true,
          mv?.description == "MV description",
          mv?.publishTime == "2026-07-28",
          mv?.playCount == 123,
          mv?.availableResolutions == [1080, 480],
          mvWithArrayResolutions?.availableResolutions == [720, 480],
          mvWithoutBitrates?.availableResolutions == [1080, 720, 480, 240],
          video?.id == "00042",
          video?.isSubscribed == true,
          video?.creatorName == "Creator",
          video?.description == "Video description",
          video?.publishTime == "2026-07-27",
          video?.playCount == 456,
          video?.availableResolutions == [720, 480],
          mixed.map(\.id) == ["mv-42", "video-00042"],
          personalized.map(\.id) == ["mv-43"],
          firstSubscriptions.items.map(\.id) == ["mv-4201", "video-saved-video"],
          firstSubscriptions.nextOffset == 3,
          firstSubscriptions.hasMore,
          subscriptions.items.map(\.id) == ["mv-4201", "video-saved-video", "mv-4202"],
          subscriptions.nextOffset == 5,
          !subscriptions.hasMore,
          firstSubscriptions.items.first.map({ item in
              guard case let .mv(value) = item else { return "" }
              return value.artistName
          }) == "Saved Artist",
          mixed.map({ item in
              switch item {
              case let .mv(value): value.artistName
              case let .video(value): value.creatorName
              }
          }) == ["Artist", "Creator"]
    else { throw VideoCheckError.failed }
}

private func verifyVideoValidation() async throws {
    guard try CommentResource.mv(42).threadID() == "R_MV_5_42",
          try CommentResource.video(" 00042 ").threadID() == "R_VI_62_00042",
          try CommentResource.video("a/b").encodedThreadID() == "R_VI_62_a%2Fb",
          VideoResolutionPolicy.preferred(1080, available: [720, 480]) == 720,
          VideoResolutionPolicy.preferred(.lowest, available: [1080, 720, 480]) == 480,
          VideoResolutionPolicy.preferred(.highest, available: [720, 480]) == 720,
          VideoResolutionPolicy.downloadCandidates(
              for: .high,
              available: [1080, 720, 480, 240]
          ) == [720, 480, 240],
          VideoResolutionPolicy.downloadCandidates(
              for: .standard,
              available: [1080, 240]
          ) == [480, 240],
          VideoResolutionPolicy.downloadCandidates(
              for: .highest,
              available: []
          ) == [1080, 720, 480, 240],
          VideoPlaybackURLPolicy.isAllowed(URL(string: "https://vodkgeyttp9.vod.126.net/file.mp4")!),
          !VideoPlaybackURLPolicy.isAllowed(URL(string: "http://vodkgeyttp9.vod.126.net/file.mp4")!),
          !VideoPlaybackURLPolicy.isAllowed(URL(string: "https://vod.126.net.evil.test/file.mp4")!)
    else { throw VideoCheckError.failed }

    let upgraded = try VideoPlaybackURLPolicy.validate(
        "http://vodkgeyttp9.vod.126.net/file.mp4"
    )
    guard upgraded.scheme == "https",
          upgraded.host == "vodkgeyttp9.vod.126.net"
    else { throw VideoCheckError.failed }

    let preflightConfiguration = URLSessionConfiguration.ephemeral
    preflightConfiguration.protocolClasses = [VideoPreflightProtocol.self]
    let resolved = try await VideoPlaybackURLResolver.resolve(
        URL(string: "https://vod.126.net/preflight.mp4")!,
        configuration: preflightConfiguration
    )
    guard resolved.host == "vod.126.net",
          VideoPreflightProtocol.rangeHeader() == "bytes=0-0"
    else { throw VideoCheckError.failed }

    do {
        _ = try await VideoPlaybackURLResolver.resolve(
            URL(string: "https://vod.126.net/preflight-403.mp4")!,
            configuration: preflightConfiguration
        )
        throw VideoCheckError.failed
    } catch let VideoLibraryError.unavailable(message) {
        guard message.contains("HTTP 403") else { throw VideoCheckError.failed }
    }

    let redirectDelegate = VideoPlaybackRedirectDelegate()
    let redirectSession = URLSession(configuration: .ephemeral)
    defer { redirectSession.invalidateAndCancel() }
    let redirectTask = redirectSession.dataTask(with: URL(string: "https://vod.126.net/source.mp4")!)
    let redirectResponse = HTTPURLResponse(
        url: redirectTask.originalRequest!.url!,
        statusCode: 302,
        httpVersion: "HTTP/1.1",
        headerFields: nil
    )!
    var acceptedRedirect: URLRequest?
    redirectDelegate.urlSession(
        redirectSession,
        task: redirectTask,
        willPerformHTTPRedirection: redirectResponse,
        newRequest: URLRequest(url: URL(string: "https://cdn.example/escaped.mp4")!)
    ) { acceptedRedirect = $0 }
    guard acceptedRedirect == nil, redirectDelegate.rejectedUnsafeRedirect else {
        throw VideoCheckError.failed
    }

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
                "validityTime": 1_200
            ]
        ]
    ], requestedResolution: 720, now: now)
    guard source.resolution == 720,
          source.url.lastPathComponent == "file.mp4",
          source.expiresAt == Date(timeIntervalSince1970: 2_200)
    else { throw VideoCheckError.failed }

    let nestedSource = try VideoDecoder.mvPlaybackSource([
        "data": [
            "urlInfo": [
                "url": "https://vod.126.net/nested.mp4",
                "r": 480,
                "validityTime": 60
            ]
        ]
    ], requestedResolution: 720, now: now)
    guard nestedSource.resolution == 480,
          nestedSource.url.lastPathComponent == "nested.mp4",
          nestedSource.expiresAt == Date(timeIntervalSince1970: 1_060)
    else { throw VideoCheckError.failed }

    for root in [
        ["data": ["url": "http://vod.126.net:8080/file.mp4"]],
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

    let library = LiveVideoLibrary(transport: EAPITransport(cookie: "", musicU: ""))
    var attempts: [Int] = []
    let fallbackSource = try await library.playbackSource(
        1080,
        available: [1080, 720, 480, 240]
    ) { resolution, _ in
        attempts.append(resolution)
        if resolution > 240 { throw VideoLibraryError.unavailable("unavailable") }
        return VideoPlaybackSource(
            url: URL(string: "https://vod.126.net/file.mp4")!,
            resolution: resolution,
            expiresAt: nil
        )
    }
    guard attempts == [1080, 720, 480, 240], fallbackSource.resolution == 240 else {
        throw VideoCheckError.failed
    }

    attempts = []
    let sourceWithoutDetailResolutions = try await library.playbackSource(720, available: []) {
        resolution, _ in
        attempts.append(resolution)
        return VideoPlaybackSource(
            url: URL(string: "https://vod.126.net/default.mp4")!,
            resolution: 480,
            expiresAt: nil
        )
    }
    guard attempts == [720], sourceWithoutDetailResolutions.resolution == 480 else {
        throw VideoCheckError.failed
    }

    attempts = []
    do {
        _ = try await library.playbackSource(720, available: [720, 480]) { resolution, _ in
            attempts.append(resolution)
            throw EAPIError.http(500)
        }
        throw VideoCheckError.failed
    } catch let EAPIError.http(status) where status == 500 {
        guard attempts == [720] else { throw VideoCheckError.failed }
    }

}

private func verifyVideoCredentialFallback() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [VideoPlaybackCredentialProtocol.self]
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }

    let accountCookie = "QR_SESSION=qr-session; MUSIC_U=qr-token; __csrf=test-csrf"
    func library(cookie: String = accountCookie, musicU: String = "vip-token") -> LiveVideoLibrary {
        LiveVideoLibrary(transport: EAPITransport(
            session: session,
            cookie: cookie,
            musicU: musicU,
            weapiSecretKey: "0123456789abcdef"
        ))
    }

    let unavailableLibrary = LiveVideoLibrary(transport: EAPITransport(
        credentialSnapshot: CredentialSnapshot()
    ))
    var unavailableLoadCount = 0
    do {
        _ = try await unavailableLibrary.playbackSource(720, available: [720]) { _, _ in
            unavailableLoadCount += 1
            throw VideoCheckError.failed
        }
        throw VideoCheckError.failed
    } catch is CredentialUnavailable {
    }
    guard unavailableLoadCount == 0 else { throw VideoCheckError.failed }

    VideoPlaybackCredentialProtocol.reset(vip: [.success(720, "from-vip.mp4")])
    let directVIP = try await library().mvPlaybackSource(
        id: 42,
        preferredResolution: 720,
        availableResolutions: [720]
    )
    guard directVIP.url.lastPathComponent == "from-vip.mp4",
          VideoPlaybackCredentialProtocol.attempts() == [
              "vip:/weapi/song/enhance/play/mv/url"
          ],
          VideoPlaybackCredentialProtocol.vipRequestsAreIsolated()
    else { throw VideoCheckError.failed }

    VideoPlaybackCredentialProtocol.reset(
        vip: [.empty],
        cookie: [.success(720, "from-cookie.mp4")]
    )
    let mv = try await library(musicU: "vip-token").mvPlaybackSource(
        id: 42,
        preferredResolution: 720,
        availableResolutions: [720]
    )
    guard mv.url.lastPathComponent == "from-cookie.mp4",
          VideoPlaybackCredentialProtocol.attempts() == [
              "vip:/weapi/song/enhance/play/mv/url",
              "cookie:/weapi/song/enhance/play/mv/url"
          ],
          VideoPlaybackCredentialProtocol.cookieFallbacksUseIPhoneProfile()
    else { throw VideoCheckError.failed }

    for response in [VideoPlaybackStubResponse.http(401), .service(301), .service(403)] {
        VideoPlaybackCredentialProtocol.reset(
            vip: [response],
            cookie: [.success(720, "authenticated-cookie.mp4")]
        )
        let source = try await library().videoPlaybackSource(
            id: "video-id",
            preferredResolution: 720,
            availableResolutions: [720]
        )
        guard source.url.lastPathComponent == "authenticated-cookie.mp4",
              VideoPlaybackCredentialProtocol.attempts() == [
                  "vip:/weapi/cloudvideo/playurl",
                  "cookie:/weapi/cloudvideo/playurl"
              ]
        else { throw VideoCheckError.failed }
    }

    VideoPlaybackCredentialProtocol.reset(
        vip: [.unsafe],
        cookie: [.success(720, "safe-cookie.mp4")]
    )
    let safeCookieSource = try await library().mvPlaybackSource(
        id: 42,
        preferredResolution: 720,
        availableResolutions: [720]
    )
    guard safeCookieSource.url.lastPathComponent == "safe-cookie.mp4",
          VideoPlaybackCredentialProtocol.attempts() == [
              "vip:/weapi/song/enhance/play/mv/url",
              "cookie:/weapi/song/enhance/play/mv/url"
          ],
          VideoPlaybackCredentialProtocol.cookieFallbacksUseIPhoneProfile()
    else { throw VideoCheckError.failed }

    VideoPlaybackCredentialProtocol.reset(
        vip: Array(repeating: .http(500), count: 3),
        cookie: [.success(720, "must-not-be-requested.mp4")]
    )
    do {
        _ = try await library().mvPlaybackSource(
            id: 42,
            preferredResolution: 720,
            availableResolutions: [720]
        )
        throw VideoCheckError.failed
    } catch {
        guard VideoPlaybackCredentialProtocol.attempts() == Array(
            repeating: "vip:/weapi/song/enhance/play/mv/url",
            count: 3
        ) else { throw VideoCheckError.failed }
    }

    VideoPlaybackCredentialProtocol.reset(
        vip: Array(repeating: .invalidJSON, count: 3),
        cookie: [.success(720, "must-not-be-requested.mp4")]
    )
    do {
        _ = try await library().mvPlaybackSource(
            id: 42,
            preferredResolution: 720,
            availableResolutions: [720]
        )
        throw VideoCheckError.failed
    } catch {
        guard VideoPlaybackCredentialProtocol.attempts() == Array(
            repeating: "vip:/weapi/song/enhance/play/mv/url",
            count: 3
        ) else { throw VideoCheckError.failed }
    }

    for cookie in ["", "MUSIC_A=guest-token"] {
        VideoPlaybackCredentialProtocol.reset(vip: [.empty])
        do {
            _ = try await library(cookie: cookie).mvPlaybackSource(
                id: 42,
                preferredResolution: 720,
                availableResolutions: [720]
            )
            throw VideoCheckError.failed
        } catch let VideoLibraryError.unavailable(message) {
            guard !message.isEmpty,
                  VideoPlaybackCredentialProtocol.attempts() == [
                      "vip:/weapi/song/enhance/play/mv/url"
                  ]
            else { throw VideoCheckError.failed }
        }
    }

    VideoPlaybackCredentialProtocol.reset(cookie: [.success(720, "cookie-only.mp4")])
    let cookieOnly = try await library(musicU: "").mvPlaybackSource(
        id: 42,
        preferredResolution: 720,
        availableResolutions: [720]
    )
    guard cookieOnly.url.lastPathComponent == "cookie-only.mp4",
          VideoPlaybackCredentialProtocol.attempts() == [
              "cookie:/weapi/song/enhance/play/mv/url"
          ],
          VideoPlaybackCredentialProtocol.cookieFallbacksUseIPhoneProfile()
    else { throw VideoCheckError.failed }

    VideoPlaybackCredentialProtocol.reset(
        vip: [.empty, .success(480, "vip-480.mp4")],
        cookie: [.empty]
    )
    let resolutionFallback = try await library().mvPlaybackSource(
        id: 42,
        preferredResolution: 720,
        availableResolutions: [720, 480]
    )
    guard resolutionFallback.resolution == 480,
          VideoPlaybackCredentialProtocol.attempts() == [
              "vip:/weapi/song/enhance/play/mv/url",
              "cookie:/weapi/song/enhance/play/mv/url",
              "vip:/weapi/song/enhance/play/mv/url"
          ]
    else { throw VideoCheckError.failed }

    VideoPlaybackCredentialProtocol.reset(
        vip: [.service(301)],
        cookie: [.empty, .success(480, "cookie-480.mp4")]
    )
    let invalidVIPFallback = try await library().mvPlaybackSource(
        id: 42,
        preferredResolution: 720,
        availableResolutions: [720, 480]
    )
    guard invalidVIPFallback.resolution == 480,
          VideoPlaybackCredentialProtocol.attempts() == [
              "vip:/weapi/song/enhance/play/mv/url",
              "cookie:/weapi/song/enhance/play/mv/url",
              "cookie:/weapi/song/enhance/play/mv/url"
          ]
    else { throw VideoCheckError.failed }

    VideoPlaybackCredentialProtocol.reset(vip: [.empty], cookie: [.http(401)])
    do {
        _ = try await library().mvPlaybackSource(
            id: 42,
            preferredResolution: 720,
            availableResolutions: [720, 480]
        )
        throw VideoCheckError.failed
    } catch let EAPIError.http(status) where status == 401 {
        guard VideoPlaybackCredentialProtocol.attempts() == [
            "vip:/weapi/song/enhance/play/mv/url",
            "cookie:/weapi/song/enhance/play/mv/url"
        ] else { throw VideoCheckError.failed }
    }

    VideoPlaybackCredentialProtocol.reset(vip: [.http(403)], cookie: [.success(720, "fallback.mp4")])
    _ = try await library(musicU: "vip-token").mvPlaybackSource(
        id: 42,
        preferredResolution: 720,
        availableResolutions: [720]
    )
    guard VideoPlaybackCredentialProtocol.attempts() == [
        "vip:/weapi/song/enhance/play/mv/url",
        "cookie:/weapi/song/enhance/play/mv/url"
    ] else { throw VideoCheckError.failed }
}

private func verifyVideoFileDownload() async throws {
    VideoDownloadProtocol.reset()
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [VideoDownloadProtocol.self]
    let directory = FileManager.default.temporaryDirectory.appending(
        path: "TinyCloudMusicVideoTests-\(UUID().uuidString)",
        directoryHint: .isDirectory
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    let cacheRoot = directory.appending(path: "cache", directoryHint: .isDirectory)
    let progress = VideoDownloadProgress()
    let savedURL = try await VideoFileDownload.download(
        URL(string: "https://vod.126.net/test.mp4")!,
        title: "Test / Video",
        resolution: 720,
        to: directory,
        cacheIdentity: "video-test-id",
        cacheRoot: cacheRoot,
        configuration: configuration
    ) { progress.record($0) }
    guard savedURL.pathExtension == "mp4",
          savedURL.lastPathComponent == "【720P】Test  Video.mp4",
          try Data(contentsOf: savedURL) == VideoDownloadProtocol.payload,
          progress.completed
    else { throw VideoCheckError.failed }

    let duplicateURL = try await VideoFileDownload.copyCachedFile(
        identity: "video-test-id",
        title: "Test / Video",
        resolution: 720,
        cacheRoot: cacheRoot,
        to: directory
    )
    guard duplicateURL == savedURL,
          VideoDownloadProtocol.requestCount == 1,
          try Data(contentsOf: savedURL) == VideoDownloadProtocol.payload
    else { throw VideoCheckError.failed }

    for name in [
        "audio.mp4",
        "short-box.mp4",
        "oversized-box.mp4",
        "embedded-ftyp.mp4",
        "extended-box.mp4"
    ] {
        do {
            _ = try await VideoFileDownload.download(
                URL(string: "https://vod.126.net/\(name)")!,
                title: "Invalid Video \(name)",
                resolution: 720,
                to: directory,
                configuration: configuration
            ) { _ in }
            throw VideoCheckError.failed
        } catch let VideoLibraryError.unavailable(message) {
            guard message == "视频下载响应无效" else { throw VideoCheckError.failed }
        }
    }
    let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
    guard files.allSatisfy({ !$0.lastPathComponent.contains("Invalid Video") && $0.pathExtension != "part" })
    else { throw VideoCheckError.failed }
}

@MainActor
private func verifyManagedVideoDownloadFallback() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [VideoPlaybackCredentialProtocol.self]
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    let root = FileManager.default.temporaryDirectory.appending(
        path: "TinyCloudMusicManagedVideoTests-\(UUID().uuidString)",
        directoryHint: .isDirectory
    )
    defer { try? FileManager.default.removeItem(at: root) }
    VideoPlaybackCredentialProtocol.reset(cookie: [
        .empty,
        .empty,
        .success(240, "fallback-240.mp4")
    ])
    let transport = EAPITransport(
        session: session,
        cookie: "QR_SESSION=qr-session; __csrf=test-csrf",
        musicU: ""
    )
    let manager = MusicDownloadManager(
        transport: transport,
        session: session,
        maximumConcurrentDownloads: 1,
        resumeStore: MusicDownloadResumeStore(directory: root.appending(path: "resume")),
        targetAllocator: MusicDownloadTargetAllocator(),
        cacheRoot: root.appending(path: "cache")
    )
    guard manager.enqueue(
        video: .mv(42),
        title: "Fallback video",
        creator: "Artist",
        availableResolutions: [720, 480, 240],
        to: root,
        quality: .high
    ) else { throw VideoCheckError.failed }

    for _ in 0..<500 {
        if case .completed? = manager.videoStates["mv-42"] { break }
        if case .failed? = manager.videoStates["mv-42"] { throw VideoCheckError.failed }
        try await Task.sleep(for: .milliseconds(10))
    }
    guard case let .completed(fileURL, nil)? = manager.videoStates["mv-42"],
          manager.videoItems["mv-42"]?.quality == "240P",
          fileURL.lastPathComponent == "【240P】Artist - Fallback video.mp4",
          try Data(contentsOf: fileURL) == VideoDownloadProtocol.payload,
          VideoPlaybackCredentialProtocol.attempts() == [
              "cookie:/weapi/song/enhance/play/mv/url",
              "cookie:/weapi/song/enhance/play/mv/url",
              "cookie:/weapi/song/enhance/play/mv/url"
          ]
    else { throw VideoCheckError.failed }

    VideoPlaybackCredentialProtocol.reset(cookie: [.success(720, "video-720.mp4")])
    guard manager.enqueue(
        video: .video("video-id"),
        title: "Plain video",
        creator: "Ignored creator",
        availableResolutions: [720],
        to: root,
        quality: .high
    ) else { throw VideoCheckError.failed }
    for _ in 0..<500 {
        if case .completed? = manager.videoStates["video-video-id"] { break }
        if case .failed? = manager.videoStates["video-video-id"] { throw VideoCheckError.failed }
        try await Task.sleep(for: .milliseconds(10))
    }
    guard case let .completed(videoURL, nil)? = manager.videoStates["video-video-id"],
          videoURL.lastPathComponent == "【720P】Plain video.mp4"
    else { throw VideoCheckError.failed }
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
    static func main() async throws {
        try verifyVideoFixtures()
        try await verifyVideoValidation()
        try await verifyVideoCredentialFallback()
        try await verifyVideoFileDownload()
        try await verifyManagedVideoDownloadFallback()
        try verifyVideoCommentPage()
        print("MV and video check passed")
    }
}
#elseif canImport(Testing)
@Suite("MV and video", .serialized)
struct VideoTests {
    @Test("MV and video fixtures retain distinct ID types")
    func fixtureDecoding() throws { try verifyVideoFixtures() }

    @Test("IDs, playback URLs, and resolutions are validated")
    func validation() async throws { try await verifyVideoValidation() }

    @Test("Playback URLs fall back from independent MUSIC_U to the QR cookie")
    func credentialFallback() async throws { try await verifyVideoCredentialFallback() }

    @Test("Playback URLs download through the validated CDN path")
    func fileDownload() async throws { try await verifyVideoFileDownload() }

    @Test("Managed video downloads share the queue and try every lower resolution")
    @MainActor
    func managedDownloadFallback() async throws { try await verifyManagedVideoDownloadFallback() }

    @Test("Read-only comments keep pagination metadata")
    func commentPage() throws { try verifyVideoCommentPage() }

    @Test("Native player replaces artwork without crashing")
    @MainActor
    func nativePlayerHostingTransition() {
        let hostingView = NSHostingView(
            rootView: NativeVideoPlayerHostingHarness(player: nil)
        )
        hostingView.frame = NSRect(x: 0, y: 0, width: 640, height: 360)
        hostingView.layoutSubtreeIfNeeded()
        #expect(!containsAVPlayerView(hostingView))

        hostingView.rootView = NativeVideoPlayerHostingHarness(player: AVPlayer())
        hostingView.layoutSubtreeIfNeeded()
        hostingView.displayIfNeeded()

        #expect(containsAVPlayerView(hostingView))
    }

    @Test("Native player intercepts scroll only inside its visible region")
    @MainActor
    func nativePlayerScrollRegion() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let content = NSView(frame: window.contentLayoutRect)
        let playerView = AVPlayerView(frame: NSRect(x: 0, y: 120, width: 640, height: 360))
        window.contentView = content
        content.addSubview(playerView)

        #expect(NativeVideoPlayerView.containsScrollLocation(
            NSPoint(x: 320, y: 300), window: window, in: playerView
        ))
        #expect(!NativeVideoPlayerView.containsScrollLocation(
            NSPoint(x: 800, y: 300), window: window, in: playerView
        ))
        #expect(!NativeVideoPlayerView.containsScrollLocation(
            NSPoint(x: 320, y: 300), window: NSWindow(), in: playerView
        ))
    }

    @Test("Player scroll routing stays latched through momentum")
    func nativePlayerScrollGestureRouting() {
        var state = VideoPlayerScrollGestureState()
        let routed = [
            state.shouldRouteToPage(phase: .began, momentumPhase: [], pointerInsidePlayer: true),
            state.shouldRouteToPage(phase: .changed, momentumPhase: [], pointerInsidePlayer: false),
            state.shouldRouteToPage(phase: .ended, momentumPhase: [], pointerInsidePlayer: false),
            state.shouldRouteToPage(phase: [], momentumPhase: .began, pointerInsidePlayer: false),
            state.shouldRouteToPage(phase: [], momentumPhase: .ended, pointerInsidePlayer: false),
            state.shouldRouteToPage(phase: .began, momentumPhase: [], pointerInsidePlayer: false),
            state.shouldRouteToPage(phase: .changed, momentumPhase: [], pointerInsidePlayer: true),
            state.shouldRouteToPage(phase: [], momentumPhase: [], pointerInsidePlayer: true),
            state.shouldRouteToPage(phase: [], momentumPhase: [], pointerInsidePlayer: false)
        ]
        #expect(routed == [true, true, true, true, true, false, true, true, false])
    }
}
#endif

private enum VideoPlaybackStubResponse: Sendable {
    case success(Int, String)
    case empty
    case unsafe
    case http(Int)
    case service(Int)
    case invalidJSON
}

private final class VideoPlaybackCredentialState: @unchecked Sendable {
    private let lock = NSLock()
    private var vipResponses: [VideoPlaybackStubResponse] = []
    private var cookieResponses: [VideoPlaybackStubResponse] = []
    private var capturedAttempts: [String] = []
    private var isolatedVIPCookies = true
    private var iPhoneCookieFallbacks = true

    func reset(vip: [VideoPlaybackStubResponse], cookie: [VideoPlaybackStubResponse]) {
        lock.withLock {
            vipResponses = vip
            cookieResponses = cookie
            capturedAttempts = []
            isolatedVIPCookies = true
            iPhoneCookieFallbacks = true
        }
    }

    func record(profile: String, path: String, cookieHeader: String) -> VideoPlaybackStubResponse {
        lock.withLock {
            capturedAttempts.append("\(profile):\(path)")
            if profile == "vip" {
                isolatedVIPCookies = isolatedVIPCookies
                    && !cookieHeader.contains("QR_SESSION=")
                    && !cookieHeader.contains("__csrf=")
            } else {
                iPhoneCookieFallbacks = iPhoneCookieFallbacks
                    && cookieHeader.contains("QR_SESSION=qr-session")
                    && cookieHeader.contains("os=iPhone OS")
                    && !cookieHeader.contains("os=Android")
            }
            if profile == "vip" {
                return vipResponses.isEmpty ? .http(599) : vipResponses.removeFirst()
            }
            return cookieResponses.isEmpty ? .http(599) : cookieResponses.removeFirst()
        }
    }

    func attempts() -> [String] { lock.withLock { capturedAttempts } }
    func vipRequestsAreIsolated() -> Bool { lock.withLock { isolatedVIPCookies } }
    func cookieFallbacksUseIPhoneProfile() -> Bool { lock.withLock { iPhoneCookieFallbacks } }
}

private final class VideoPlaybackCredentialProtocol: URLProtocol, @unchecked Sendable {
    private static let state = VideoPlaybackCredentialState()

    static func reset(
        vip: [VideoPlaybackStubResponse] = [],
        cookie: [VideoPlaybackStubResponse] = []
    ) {
        state.reset(vip: vip, cookie: cookie)
    }

    static func attempts() -> [String] { state.attempts() }
    static func vipRequestsAreIsolated() -> Bool { state.vipRequestsAreIsolated() }
    static func cookieFallbacksUseIPhoneProfile() -> Bool { state.cookieFallbacksUseIPhoneProfile() }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let path = request.url?.path ?? ""
        if request.url?.host == "vod.126.net" {
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: [
                    "Content-Length": String(VideoDownloadProtocol.payload.count),
                    "Content-Type": "video/mp4"
                ]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: VideoDownloadProtocol.payload)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        let cookie = request.value(forHTTPHeaderField: "Cookie") ?? ""
        let profile = cookie.contains("os=Android") ? "vip" : "cookie"
        let stub = Self.state.record(profile: profile, path: path, cookieHeader: cookie)
        let body: Data
        let statusCode: Int
        switch stub {
        case let .success(resolution, file):
            statusCode = 200
            if path == "/weapi/cloudvideo/playurl" {
                body = Data(
                    "{\"code\":200,\"urls\":[{\"url\":\"https://vod.126.net/\(file)\",\"r\":\(resolution)}]}".utf8
                )
            } else {
                body = Data(
                    "{\"code\":200,\"data\":{\"url\":\"https://vod.126.net/\(file)\",\"r\":\(resolution)}}".utf8
                )
            }
        case .empty:
            statusCode = 200
            body = Data(#"{"code":200,"data":{"url":null},"urls":[]}"#.utf8)
        case .unsafe:
            statusCode = 200
            body = Data(#"{"code":200,"data":{"url":"https://invalid.example/file.mp4","r":720},"urls":[{"url":"https://invalid.example/file.mp4","r":720}]}"#.utf8)
        case let .http(status):
            statusCode = status
            body = Data("{\"code\":\(status)}".utf8)
        case let .service(code):
            statusCode = 200
            body = Data("{\"code\":\(code),\"message\":\"authentication failed\"}".utf8)
        case .invalidJSON:
            statusCode = 200
            body = Data("{".utf8)
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class VideoDownloadProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var requests = 0
    static let payload = Data([0, 0, 0, 16])
        + Data("ftypisom".utf8)
        + Data(repeating: 0, count: 4)

    static var requestCount: Int { lock.withLock { requests } }
    static func reset() { lock.withLock { requests = 0 } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.withLock { Self.requests += 1 }
        let payload = Self.payload(for: request.url?.lastPathComponent ?? "")
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: [
                "Content-Length": String(payload.count),
                "Content-Type": request.url?.lastPathComponent == "audio.mp4" ? "audio/mpeg" : "video/mp4"
            ]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: payload)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func payload(for name: String) -> Data {
        switch name {
        case "audio.mp4":
            Data("ID3-not-a-video".utf8)
        case "short-box.mp4":
            Data([0, 0, 0, 12]) + Data("ftypisom".utf8)
        case "oversized-box.mp4":
            Data([0, 0, 0, 32]) + Data("ftypisom".utf8) + Data(repeating: 0, count: 4)
        case "embedded-ftyp.mp4":
            Data("<html>ftyp</html>".utf8)
        case "extended-box.mp4":
            Data([0, 0, 0, 1]) + Data("ftyp".utf8) + Data(repeating: 0, count: 16)
        default:
            Self.payload
        }
    }
}

private final class VideoPreflightProtocol: URLProtocol, @unchecked Sendable {
    private static let capturedRange = VideoHeaderCapture()

    static func rangeHeader() -> String? { capturedRange.value }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.capturedRange.value = request.value(forHTTPHeaderField: "Range")
        let statusCode = request.url?.lastPathComponent == "preflight-403.mp4" ? 403 : 206
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: statusCode == 206 ? ["Content-Range": "bytes 0-0/16"] : nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if statusCode == 206 { client?.urlProtocol(self, didLoad: Data([0])) }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class VideoHeaderCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: String?

    var value: String? {
        get { lock.withLock { storage } }
        set { lock.withLock { storage = newValue } }
    }
}

private final class VideoDownloadProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Double?

    var completed: Bool { lock.withLock { value == 1 } }

    func record(_ progress: Double?) {
        lock.withLock { value = progress }
    }
}
