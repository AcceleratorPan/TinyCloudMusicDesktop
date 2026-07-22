import CommonCrypto
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

private final class RequestCaptureProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var captured: URLRequest?
    nonisolated(unsafe) private static var capturedRequests: [URLRequest] = []
    nonisolated(unsafe) private static var count = 0
    nonisolated(unsafe) private static var responses: [String: (statusCode: Int, body: Data)] = [:]

    static func reset(responses: [String: (statusCode: Int, body: Data)] = [:]) {
        lock.lock()
        captured = nil
        capturedRequests = []
        count = 0
        self.responses = responses
        lock.unlock()
    }

    static func request() -> URLRequest? {
        lock.lock()
        defer { lock.unlock() }
        return captured
    }

    static func requestCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    static func requests() -> [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return capturedRequests
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var capturedRequest = request
        if capturedRequest.httpBody == nil, let stream = capturedRequest.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var body = Data()
            var buffer = [UInt8](repeating: 0, count: 4_096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                body.append(buffer, count: count)
            }
            capturedRequest.httpBody = body
        }
        Self.lock.lock()
        Self.captured = capturedRequest
        Self.capturedRequests.append(capturedRequest)
        Self.count += 1
        let stub = Self.responses[request.url?.path ?? ""]
        Self.lock.unlock()
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: stub?.statusCode ?? 400,
            httpVersion: nil,
            headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: stub?.body ?? Data())
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@main
enum WriteAPIContractCheck {
    static func main() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RequestCaptureProtocol.self]
        let transport = EAPITransport(
            session: URLSession(configuration: configuration),
            cookie: "MUSIC_U=test; __csrf=csrf",
            musicU: "",
            weapiSecretKey: "0123456789abcdef"
        )
        let reportingTransport = EAPITransport(
            session: URLSession(configuration: configuration),
            cookie: "MUSIC_U=test; os=pc; osver=old; appver=old; channel=old",
            musicU: ""
        )
        let library = LiveMusicLibrary(transport: transport)
        let originalCookieLibrary = LiveMusicLibrary(transport: EAPITransport(
            session: URLSession(configuration: configuration),
            cookie: "MUSIC_U=original-cookie",
            musicU: "vip-requester-cookie"
        ))
        let repository = LiveMusicRepository(transport: reportingTransport)
        let authenticationContext = NeteaseAuthenticationContext(
            cookie: "MUSIC_A=guest-token",
            deviceID: String(repeating: "A", count: 52)
        )
        let macOSCookieMatches: (String) -> Bool = {
            $0.contains("MUSIC_U=test")
                && $0.contains("os=osx")
                && $0.contains("appver=3.1.10.5100")
                && !$0.contains("os=pc")
                && !$0.contains("appver=old")
        }
        var count = 0

        try verifyCoverProcessing()
        try await verifyPlaybackQualityPrivilegeProfile()
        count += 2

        try await verify("/eapi/song/like", signing: "/api/song/like", call: {
            try await library.setSongLiked(11, liked: true)
        }) { $0.int64("trackId") == 11 && $0.bool("like") }
        count += 1

        for subscribed in [true, false] {
            let action = subscribed ? "subscribe" : "unsubscribe"
            try await verify("/eapi/playlist/\(action)", signing: "/api/playlist/\(action)", call: {
                try await library.setPlaylistSubscribed(12, subscribed: subscribed)
            }) { $0.int64("id") == 12 }
            count += 1
        }
        for subscribed in [true, false] {
            let action = subscribed ? "sub" : "unsub"
            try await verify("/eapi/album/\(action)", signing: "/api/album/\(action)", call: {
                try await library.setAlbumSubscribed(13, subscribed: subscribed)
            }) { $0.string("id") == "13" }
            count += 1
        }

        try await verify("/eapi/v1/artist/sub", signing: "/api/v1/artist/sub", call: {
            try await library.setArtistFollowed(14, followed: true)
        }) { $0.string("artistId") == "14" }
        count += 1
        try await verify("/eapi/artist/unsub", signing: "/api/artist/unsub", call: {
            try await library.setArtistFollowed(14, followed: false)
        }) { $0.string("artistIds") == "[14]" }
        count += 1

        for followed in [true, false] {
            let action = followed ? "follow" : "delfollow"
            try await verify("/eapi/user/\(action)/15", signing: "/api/user/\(action)/15", call: {
                try await library.setUserFollowed(15, followed: followed)
            }) { $0.int("verifyId") == 1 }
            count += 1
        }

        try await verify("/eapi/playlist/create", signing: "/api/playlist/create", call: {
            _ = try await library.createPlaylist(name: "API check", privacy: .privatePlaylist)
        }) { $0.string("name") == "API check" && $0.int("privacy") == 10 && $0.string("type") == "NORMAL" }
        count += 1
        try await verify("/eapi/playlist/delete", signing: "/api/playlist/delete", call: {
            try await library.deletePlaylist(16)
        }) { $0.int64("pid") == 16 }
        count += 1

        try await verify(
            "/eapi/playlist/update/name",
            signing: "/api/playlist/update/name",
            host: "interface.music.163.com",
            call: { try await library.updatePlaylistName(16, name: "中文 \"mix\" 🎵") }
        ) { $0.int64("id") == 16 && $0.string("name") == "中文 \"mix\" 🎵" }
        count += 1

        try await verify(
            "/eapi/playlist/desc/update",
            signing: "/api/playlist/desc/update",
            host: "interface.music.163.com",
            call: { try await library.updatePlaylistDescription(16, description: "line 1\nline 2") }
        ) { $0.int64("id") == 16 && $0.string("desc") == "line 1\nline 2" }
        count += 1

        try await verify(
            "/eapi/playlist/tags/update",
            signing: "/api/playlist/tags/update",
            host: "interface.music.163.com",
            call: { try await library.updatePlaylistTags(16, tags: ["学习", "华语"]) }
        ) { $0.int64("id") == 16 && $0.string("tags") == "学习;华语" }
        count += 1

        try await verifyWEAPI("/weapi/playlist/order/update", call: {
            try await library.updatePlaylistOrder([31, 29, 30])
        }) {
            $0.string("ids") == #"["31","29","30"]"#
                && $0.string("csrf_token") == "csrf"
        }
        count += 1

        try await verify(
            "/eapi/playlist/manipulate/tracks",
            signing: "/api/playlist/manipulate/tracks",
            call: { try await library.updatePlaylistSongOrder(16, trackIDs: [13, 11, 12]) }
        ) {
            $0.string("pid") == "16"
                && $0.string("trackIds") == #"["13","11","12"]"#
                && $0.string("op") == "update"
        }
        count += 1

        try await verify(
            "/eapi/playlist/update/privacy",
            signing: "/api/playlist/update/privacy",
            call: { try await library.makePlaylistPublic(16) }
        ) { $0.int64("id") == 16 && $0.int("privacy") == 0 }
        count += 1

        try await verifyCoverUpload(library: library)
        try await verifyCoverFailureStops(library: library)
        count += 3

        try await verify("/eapi/v1/playlist/manipulate/tracks", signing: "/api/v1/playlist/manipulate/tracks", call: {
            try await library.addSongs([11, 12], to: 16)
        }) { $0.string("pid") == "16" && $0.string("trackIds") == #"["11","12"]"# && $0.string("op") == "add" }
        count += 1
        try await verify("/eapi/v1/playlist/manipulate/tracks", signing: "/api/v1/playlist/manipulate/tracks", call: {
            try await library.removeSongs([11, 12], from: 16)
        }) { $0.int64("pid") == 16 && $0.string("trackIds") == #"["11","12"]"# && $0.string("op") == "del" }
        count += 1

        try await verify("/eapi/resource/commentInfo/list", signing: "/api/resource/commentInfo/list", call: {
            _ = try await library.commentCount(songID: 26_060_065)
        }) {
            $0.string("resourceType") == "4" && $0.string("resourceIds") == #"["26060065"]"#
        }
        count += 1

        try await verify(
            "/eapi/resource/comments/add",
            signing: "/api/resource/comments/add",
            host: "interface.music.163.com",
            call: {
                _ = try await library.addComment(songID: 42, content: " hello ")
            }
        ) { $0.string("threadId") == "R_SO_4_42" && $0.string("content") == "hello" }
        count += 1

        try await verify(
            "/eapi/resource/comments/reply",
            signing: "/api/resource/comments/reply",
            host: "interface.music.163.com",
            call: {
                _ = try await library.replyToComment(songID: 42, commentID: 99, content: " reply ")
            }
        ) {
            $0.string("threadId") == "R_SO_4_42"
                && $0.string("commentId") == "99"
                && $0.string("content") == "reply"
        }
        count += 1

        try await verify(
            "/eapi/resource/comments/delete",
            signing: "/api/resource/comments/delete",
            host: "interface.music.163.com",
            call: {
                try await library.deleteComment(songID: 42, commentID: 99)
            }
        ) { $0.string("threadId") == "R_SO_4_42" && $0.string("commentId") == "99" }
        count += 1

        for liked in [true, false] {
            let action = liked ? "like" : "unlike"
            try await verifyWEAPI("/weapi/v1/comment/\(action)", call: {
                try await library.setCommentLiked(songID: 42, commentID: 99, liked: liked)
            }) {
                $0.string("threadId") == "R_SO_4_42"
                    && $0.string("commentId") == "99"
                    && $0.string("csrf_token") == "csrf"
            }
            count += 1
        }

        try await verifyWEAPI("/weapi/radio/trash/add", call: {
            _ = try await transport.requestFMTrash(songID: 42, algorithm: "itembased", playedSeconds: 7)
        }) {
            $0.int64("songId") == 42
                && $0.string("alg") == "itembased"
                && $0.int("time") == 7
                && $0.string("csrf_token") == "csrf"
        }
        count += 1

        let recentPlaybackRequests: [(String, () async throws -> Void)] = [
            ("/weapi/play-record/song/list", { _ = try await library.recentlyPlayedSongs(limit: 37) }),
            ("/weapi/play-record/album/list", { _ = try await library.recentlyPlayedAlbums(limit: 37) }),
            ("/weapi/play-record/playlist/list", { _ = try await library.recentlyPlayedPlaylists(limit: 37) }),
            ("/weapi/play-record/newvideo/list", { _ = try await library.recentlyPlayedVideos(limit: 37) }),
            ("/weapi/play-record/voice/list", { _ = try await library.recentlyPlayedVoices(limit: 37) }),
            ("/weapi/play-record/djradio/list", { _ = try await library.recentlyPlayedPodcasts(limit: 37) })
        ]
        for (path, call) in recentPlaybackRequests {
            try await verifyWEAPI(path, call: call) {
                $0.int("limit") == 37 && $0.string("csrf_token") == "csrf"
            }
            count += 1
        }

        RequestCaptureProtocol.reset()
        do {
            _ = try await library.addComment(songID: 42, content: " \n ")
            preconditionFailure("Whitespace-only comments must fail before the network")
        } catch EAPIError.invalidPayload {
        }
        precondition(RequestCaptureProtocol.requestCount() == 0)

        RequestCaptureProtocol.reset(responses: [
            "/weapi/response/check": (
                200,
                hexData("DCC52B3013E9B66C038F8E027E580ECEB05FC53B1F6993CE36C0C7ECDAB365A762DAEBC2218FE30386E1CF0BDB6F38EA")
            )
        ])
        let weapiResponse = try decodedJSONObject(
            try await transport.requestWEAPI(
                path: "/weapi/response/check",
                payload: [:],
                invalidatesAccountCache: false
            )
        )
        precondition(weapiResponse.object("data").string("value") == "encrypted")
        count += 1

        RequestCaptureProtocol.reset()
        do {
            try await library.updatePlaylistOrder([])
            preconditionFailure("An empty playlist order must fail before the network")
        } catch EAPIError.invalidPayload {
        }
        precondition(RequestCaptureProtocol.requestCount() == 0)

        for period in MusicListeningPeriod.allCases {
            try await verify("/eapi/v1/play/record", signing: "/api/v1/play/record", call: {
                _ = try await library.listeningRecords(userID: 17, period: period)
            }) {
                $0.string("uid") == "17" && $0.int("type") == period.rawValue
            }
            count += 1
        }

        try await verify(
            "/eapi/content/activity/listen/data/total",
            signing: "/api/content/activity/listen/data/total",
            cookieMatches: {
                $0.contains("MUSIC_U=original-cookie") && !$0.contains("vip-requester-cookie")
            },
            call: { _ = try await originalCookieLibrary.totalListeningDuration() }
        ) { $0.isEmpty }
        count += 1

        try await verify(
            "/eapi/feedback/weblog",
            signing: "/api/feedback/weblog",
            host: "clientlog.music.163.com",
            cookieMatches: macOSCookieMatches,
            call: { try await repository.recordPlaybackStart(for: 17) }
        ) { payload in
            guard let log = playbackLog(in: payload) else { return false }
            let json = log.object("json")
            return log.string("action") == "startplay"
                && json.int64("id") == 17
                && json.string("type") == "song"
        }
        count += 1

        try await verify(
            "/eapi/feedback/weblog",
            signing: "/api/feedback/weblog",
            host: "clientlog.music.163.com",
            cookieMatches: macOSCookieMatches,
            call: { try await repository.recordPlayback(for: 17, playedSeconds: 42) }
        ) { payload in
            guard let log = playbackLog(in: payload) else { return false }
            let json = log.object("json")
            return log.string("action") == "play"
                && json.int64("id") == 17
                && json.int("time") == 42
                && json.string("end") == "playend"
        }
        count += 1

        try await verifyAuthentication(
            transport: transport,
            context: authenticationContext,
            payload: ["type": 3],
            physicalPath: "/eapi/login/qrcode/unikey",
            signing: "/api/login/qrcode/unikey",
            expectedUserAgent: "NeteaseMusic 9.0.90/5038 (iPhone; iOS 16.2; zh_CN)"
        ) { $0.int("type") == 3 }
        count += 1

        try await verifyAuthentication(
            transport: transport,
            context: authenticationContext,
            payload: ["key": "qr-key", "type": 3],
            physicalPath: "/eapi/login/qrcode/client/login",
            signing: "/api/login/qrcode/client/login",
            userAgent: "pc",
            expectedUserAgent: "pc"
        ) { $0.string("key") == "qr-key" && $0.int("type") == 3 }
        count += 1

        try await verifyAuthentication(
            transport: transport,
            context: authenticationContext,
            payload: [:],
            physicalPath: "/eapi/login/token/refresh",
            signing: "/api/login/token/refresh",
            expectedUserAgent: "NeteaseMusic 9.0.90/5038 (iPhone; iOS 16.2; zh_CN)"
        ) { $0.isEmpty }
        count += 1

        try await verifyAuthentication(
            transport: transport,
            context: authenticationContext,
            payload: [:],
            physicalPath: "/eapi/logout",
            signing: "/api/logout",
            expectedUserAgent: "NeteaseMusic 9.0.90/5038 (iPhone; iOS 16.2; zh_CN)"
        ) { $0.isEmpty }
        count += 1

        print("Write API contract checks passed: \(count) requests captured locally")
    }

    private static func verifyPlaybackQualityPrivilegeProfile() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RequestCaptureProtocol.self]
        let repository = LiveMusicRepository(transport: EAPITransport(
            session: URLSession(configuration: configuration),
            cookie: "MUSIC_A=guest-token",
            musicU: "vip-token"
        ))
        RequestCaptureProtocol.reset(responses: [
            "/eapi/song/music/detail/get": (
                200,
                Data(#"{"code":200,"data":{"l":{"br":128000,"size":1000,"sr":44100}}}"#.utf8)
            ),
            "/eapi/v3/song/detail": (
                200,
                Data(#"{"code":200,"privileges":[{"plLevel":"standard","flLevel":"standard"}]}"#.utf8)
            )
        ])

        let qualities = try await repository.songQualityDetails(for: 17)
        let requests = RequestCaptureProtocol.requests()
        let privilegeCookie = requests.first { $0.url?.path == "/eapi/v3/song/detail" }?
            .value(forHTTPHeaderField: "Cookie") ?? ""
        precondition(qualities.count == 1 && qualities[0].isAvailable)
        precondition(Set(requests.compactMap(\.url?.path)) == [
            "/eapi/song/music/detail/get", "/eapi/v3/song/detail"
        ])
        precondition(privilegeCookie.contains("MUSIC_A=guest-token"))
        precondition(privilegeCookie.contains("MUSIC_U=vip-token"))
        precondition(privilegeCookie.contains("os=iPhone OS"))
    }

    private static func verifyCoverProcessing() throws {
        for (width, height) in [(1_600, 900), (900, 1_600)] {
            let cover = try PlaylistCoverProcessor.process(
                data: try jpeg(width: width, height: height),
                filename: "unsafe/name"
            )
            precondition(cover.width == 1_000 && cover.height == 1_000)
            precondition(cover.filename == "unsafe_name.jpg")
            guard let source = CGImageSourceCreateWithData(cover.jpegData as CFData, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
            else { preconditionFailure("Processed cover is not a JPEG") }
            precondition((properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue == 1_000)
            precondition((properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue == 1_000)
        }
        do {
            _ = try PlaylistCoverProcessor.process(
                data: Data(count: PlaylistCoverProcessor.maxSourceBytes + 1),
                filename: "large"
            )
            preconditionFailure("Oversized covers must fail before decoding")
        } catch PlaylistCoverError.sourceTooLarge {
        }
    }

    private static func verifyCoverUpload(library: LiveMusicLibrary) async throws {
        RequestCaptureProtocol.reset(responses: [
            "/weapi/nos/token/alloc": (200, Data(#"{"code":200,"result":{"objectKey":"object-key.jpg","token":"nos-token","docId":"987654"}}"#.utf8)),
            "/yyimgs/object-key.jpg": (200, Data()),
            "/weapi/playlist/cover/update": (200, Data(#"{"code":200}"#.utf8))
        ])
        try await library.updatePlaylistCover(
            16,
            cover: ProcessedPlaylistCover(
                jpegData: Data([1, 2, 3]),
                filename: "cover.jpg",
                width: 1_000,
                height: 1_000
            )
        )
        let requests = RequestCaptureProtocol.requests()
        guard requests.count == 3,
              let allocationBody = requests[0].httpBody,
              let allocation = try decodeWEAPI(body: allocationBody, secretKey: "0123456789abcdef"),
              allocation.payload.string("bucket") == "yyimgs",
              allocation.payload.string("ext") == "jpg",
              allocation.payload.string("filename") == "cover.jpg",
              allocation.payload.bool("local") == false,
              allocation.payload.int("nos_product") == 0,
              allocation.payload.string("return_body") == #"{"code":200,"size":"$(ObjectSize)"}"#,
              allocation.payload.string("type") == "other"
        else { preconditionFailure("NOS allocation contract mismatch") }

        let upload = requests[1]
        let uploadQuery = Dictionary(uniqueKeysWithValues: (URLComponents(
            url: upload.url!,
            resolvingAgainstBaseURL: false
        )?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        precondition(upload.url?.host == "nosup-hz1.127.net")
        precondition(upload.url?.path == "/yyimgs/object-key.jpg")
        precondition(uploadQuery == ["offset": "0", "complete": "true", "version": "1.0"])
        precondition(upload.value(forHTTPHeaderField: "x-nos-token") == "nos-token")
        precondition(upload.value(forHTTPHeaderField: "Content-Type") == "image/jpeg")
        precondition(upload.httpBody == Data([1, 2, 3]))

        guard let updateBody = requests[2].httpBody,
              let update = try decodeWEAPI(body: updateBody, secretKey: "0123456789abcdef"),
              update.payload.int64("id") == 16,
              update.payload.string("coverImgId") == "987654"
        else { preconditionFailure("Playlist cover update contract mismatch") }
    }

    private static func verifyCoverFailureStops(library: LiveMusicLibrary) async throws {
        let allocation = Data(#"{"code":200,"result":{"objectKey":"object-key.jpg","token":"nos-token","docId":"987654"}}"#.utf8)
        let cover = ProcessedPlaylistCover(
            jpegData: Data([1, 2, 3]),
            filename: "cover.jpg",
            width: 1_000,
            height: 1_000
        )
        let cases: [([String: (statusCode: Int, body: Data)], Int)] = [
            (["/weapi/nos/token/alloc": (500, Data())], 1),
            ([
                "/weapi/nos/token/alloc": (200, allocation),
                "/yyimgs/object-key.jpg": (500, Data())
            ], 2),
            ([
                "/weapi/nos/token/alloc": (200, allocation),
                "/yyimgs/object-key.jpg": (200, Data()),
                "/weapi/playlist/cover/update": (500, Data())
            ], 3)
        ]
        for (responses, expectedCount) in cases {
            RequestCaptureProtocol.reset(responses: responses)
            do {
                try await library.updatePlaylistCover(16, cover: cover)
                preconditionFailure("A failed cover stage must stop the upload")
            } catch EAPIError.http(500) {
            }
            precondition(RequestCaptureProtocol.requestCount() == expectedCount)
        }
    }

    private static func jpeg(width: Int, height: Int) throws -> Data {
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw EAPIError.invalidPayload }
        context.setFillColor(red: 0.8, green: 0.2, blue: 0.1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else { throw EAPIError.invalidPayload }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else { throw EAPIError.invalidPayload }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw EAPIError.invalidPayload }
        return data as Data
    }

    private static func verify(
        _ physicalPath: String,
        signing logicalPath: String,
        host: String? = nil,
        cookieMatches: (String) -> Bool = { _ in true },
        call: () async throws -> Void,
        payloadMatches: ([String: Any]) -> Bool
    ) async throws {
        RequestCaptureProtocol.reset()
        do {
            try await call()
            preconditionFailure("Expected the local HTTP 400 response")
        } catch EAPIError.http(400) {
        }
        guard let request = RequestCaptureProtocol.request(),
              request.url?.path == physicalPath,
              RequestCaptureProtocol.requestCount() == 1,
              (host == nil || request.url?.host == host),
              cookieMatches(request.value(forHTTPHeaderField: "Cookie") ?? ""),
              let body = request.httpBody,
              let decoded = try decode(body: body),
              decoded.path == logicalPath,
              payloadMatches(decoded.payload)
        else { preconditionFailure("Request contract mismatch for \(physicalPath)") }
    }

    private static func verifyAuthentication(
        transport: EAPITransport,
        context: NeteaseAuthenticationContext,
        payload: [String: Any],
        physicalPath: String,
        signing logicalPath: String,
        userAgent: String? = nil,
        expectedUserAgent: String,
        payloadMatches: ([String: Any]) -> Bool
    ) async throws {
        RequestCaptureProtocol.reset()
        do {
            _ = try await transport.requestAuthentication(
                EAPIEndpoint(physicalPath, signing: logicalPath, host: "https://interface.music.163.com"),
                payload: payload,
                context: context,
                userAgent: userAgent
            )
            preconditionFailure("Expected the local HTTP 400 response")
        } catch EAPIError.http(400) {
        }
        guard let request = RequestCaptureProtocol.request(),
              request.url?.path == physicalPath,
              request.url?.host == "interface.music.163.com",
              request.value(forHTTPHeaderField: "User-Agent") == expectedUserAgent,
              RequestCaptureProtocol.requestCount() == 1,
              let body = request.httpBody,
              let decoded = try decode(body: body),
              decoded.path == logicalPath,
              decoded.payload["e_r"] as? Bool == false,
              payloadMatches(decoded.payload.filter { $0.key != "e_r" && $0.key != "header" }),
              authenticationContextMatches(
                  header: decoded.payload.object("header"),
                  cookie: request.value(forHTTPHeaderField: "Cookie") ?? "",
                  deviceID: context.deviceID
              )
        else { preconditionFailure("Authentication contract mismatch for \(physicalPath)") }
    }

    private static func authenticationContextMatches(
        header: [String: Any],
        cookie: String,
        deviceID: String
    ) -> Bool {
        let expected: [String: String] = [
            "os": "pc",
            "appver": "3.1.17.204416",
            "osver": "Microsoft-Windows-10-Professional-build-19045-64bit",
            "channel": "netease",
            "versioncode": "140",
            "resolution": "1920x1080",
            "deviceId": deviceID,
            "MUSIC_A": "guest-token"
        ]
        guard expected.allSatisfy({ header.string($0.key) == $0.value }),
              header.string("mobilename").isEmpty,
              header.string("__csrf").isEmpty,
              header.string("buildver").count == 10,
              header.string("buildver").allSatisfy(\.isNumber),
              header.string("requestId").split(separator: "_").count == 2
        else { return false }

        let cookieFields = cookie.split(separator: ";").reduce(into: [String: String]()) { result, field in
            let pair = field.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2 else { return }
            let name = String(pair[0]).trimmingCharacters(in: .whitespaces).removingPercentEncoding
            let value = String(pair[1]).trimmingCharacters(in: .whitespaces).removingPercentEncoding
            if let name, let value { result[name] = value }
        }
        let headerFields = header.reduce(into: [String: String]()) { result, field in
            result[field.key] = field.value as? String ?? String(describing: field.value)
        }
        return cookieFields == headerFields
    }

    private static func verifyWEAPI(
        _ physicalPath: String,
        call: () async throws -> Void,
        payloadMatches: ([String: Any]) -> Bool
    ) async throws {
        RequestCaptureProtocol.reset()
        do {
            try await call()
            preconditionFailure("Expected the local HTTP 400 response")
        } catch EAPIError.http(400) {
        }
        guard let request = RequestCaptureProtocol.request(),
              request.url?.path == physicalPath,
              request.url?.host == "music.163.com",
              RequestCaptureProtocol.requestCount() == 1,
              request.value(forHTTPHeaderField: "Referer") == "https://music.163.com/",
              request.value(forHTTPHeaderField: "Cookie")?.contains("__csrf=csrf") == true,
              let body = request.httpBody,
              let decoded = try decodeWEAPI(body: body, secretKey: "0123456789abcdef"),
              decoded.encSecKey == "35701388baf89fed412e11269b9c76625d095ecaf17f03fa018abe19ea2d38b949debf242ee39a71ca1f6cda71b1b86a45aa909ee27f7e78e267d34e732f0de948206c3340a788d0003372183e2f753c1f78b66ac23d134ac1fc9b993156520ea826b8aa89a962d4491b4b8d7e08738e1da9b07aa39bf4a7ef0b1c210728cd52",
              decoded.payload["e_r"] as? Bool == false,
              payloadMatches(decoded.payload)
        else { preconditionFailure("Request contract mismatch for \(physicalPath)") }
    }

    private static func playbackLog(in payload: [String: Any]) -> [String: Any]? {
        guard let text = payload["logs"] as? String,
              let data = text.data(using: .utf8),
              let logs = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return nil }
        return logs.first
    }

    private static func decode(body: Data) throws -> (path: String, payload: [String: Any])? {
        let text = String(decoding: body, as: UTF8.self)
        guard text.hasPrefix("params=") else { return nil }
        let hex = text.dropFirst(7)
        guard hex.count.isMultiple(of: 2) else { return nil }
        let cipher = hexData(String(hex))
        let plain = try decrypt(cipher)
        let components = String(decoding: plain, as: UTF8.self).components(separatedBy: "-36cd479b6b5-")
        guard components.count == 3,
              let json = components[1].data(using: .utf8),
              let payload = try JSONSerialization.jsonObject(with: json) as? [String: Any]
        else { return nil }
        return (components[0], payload)
    }

    private static func hexData(_ value: String) -> Data {
        Data(stride(from: 0, to: value.count, by: 2).compactMap { offset in
            UInt8(value.dropFirst(offset).prefix(2), radix: 16)
        })
    }

    private static func decrypt(_ input: Data) throws -> Data {
        let key = Data("e82ckenh8dichen8".utf8)
        var output = Data(count: input.count + kCCBlockSizeAES128)
        let capacity = output.count
        var length = 0
        let status = output.withUnsafeMutableBytes { outputBytes in
            input.withUnsafeBytes { inputBytes in
                key.withUnsafeBytes { keyBytes in
                    CCCrypt(
                        CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES),
                        CCOptions(kCCOptionECBMode | kCCOptionPKCS7Padding),
                        keyBytes.baseAddress, key.count, nil,
                        inputBytes.baseAddress, input.count,
                        outputBytes.baseAddress, capacity, &length
                    )
                }
            }
        }
        guard status == kCCSuccess else { throw EAPIError.invalidCiphertext }
        output.removeSubrange(length..<output.count)
        return output
    }

    private static func decodeWEAPI(
        body: Data,
        secretKey: String
    ) throws -> (payload: [String: Any], encSecKey: String)? {
        var components = URLComponents()
        components.percentEncodedQuery = String(decoding: body, as: UTF8.self)
        let values = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        guard let params = values["params"], let encSecKey = values["encSecKey"],
              let secondCipher = Data(base64Encoded: params),
              let firstBase64 = String(data: try decryptCBC(secondCipher, key: secretKey), encoding: .utf8),
              let firstCipher = Data(base64Encoded: firstBase64),
              let json = try? decryptCBC(firstCipher, key: "0CoJUm6Qyw8W8jud"),
              let payload = try? JSONSerialization.jsonObject(with: json) as? [String: Any]
        else { return nil }
        return (payload, encSecKey)
    }

    private static func decryptCBC(_ input: Data, key: String) throws -> Data {
        let keyData = Data(key.utf8)
        let iv = Data("0102030405060708".utf8)
        var output = Data(count: input.count + kCCBlockSizeAES128)
        let capacity = output.count
        var length = 0
        let status = output.withUnsafeMutableBytes { outputBytes in
            input.withUnsafeBytes { inputBytes in
                keyData.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(
                            CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding), keyBytes.baseAddress, keyData.count,
                            ivBytes.baseAddress, inputBytes.baseAddress, input.count,
                            outputBytes.baseAddress, capacity, &length
                        )
                    }
                }
            }
        }
        guard status == kCCSuccess else { throw EAPIError.invalidCiphertext }
        output.removeSubrange(length..<output.count)
        return output
    }
}
