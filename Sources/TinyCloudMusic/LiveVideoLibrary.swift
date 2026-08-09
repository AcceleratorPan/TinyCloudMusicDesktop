import Foundation

struct LiveVideoLibrary: Sendable {
    let transport: EAPITransport

    init(transport: EAPITransport = EAPITransport()) {
        self.transport = transport
    }

    func recommendations(
        offset: Int = 0,
        refreshCache: Bool = false,
        expectedCredentialRevision: UInt64
    ) async throws -> [VideoRecommendation] {
        guard offset >= 0 else { throw EAPIError.invalidPayload }
        let root = try await request(
            path: "/weapi/videotimeline/get",
            payload: [
                "offset": offset,
                "filterLives": "[]",
                "withProgramInfo": "true",
                "needUrl": "1",
                "resolution": "480"
            ],
            cache: .detail,
            refreshCache: refreshCache,
            expectedCredentialRevision: expectedCredentialRevision
        )
        return VideoDecoder.recommendations(root)
    }

    func personalizedMVs(
        refreshCache: Bool = false,
        expectedCredentialRevision: UInt64
    ) async throws -> [VideoRecommendation] {
        VideoDecoder.personalizedMVs(try await request(
            path: "/weapi/personalized/mv",
            payload: [:],
            cache: .detail,
            refreshCache: refreshCache,
            expectedCredentialRevision: expectedCredentialRevision
        ))
    }

    func subscriptions(
        offset: Int = 0,
        limit: Int = 25,
        refreshCache: Bool = false,
        expectedCredentialRevision: UInt64
    ) async throws -> VideoSubscriptionPage {
        guard offset >= 0, (1...100).contains(limit) else { throw EAPIError.invalidPayload }
        return VideoDecoder.subscriptions(
            try await request(
                path: "/weapi/cloudvideo/allvideo/sublist",
                payload: ["limit": limit, "offset": offset, "total": true],
                cache: .library,
                refreshCache: refreshCache,
                expectedCredentialRevision: expectedCredentialRevision
            ),
            offset: offset,
            limit: limit
        )
    }

    func mvDetail(
        id: Int64,
        refreshCache: Bool = false,
        expectedCredentialRevision: UInt64? = nil
    ) async throws -> MVDetail {
        guard id > 0 else { throw EAPIError.invalidPayload }
        guard let detail = VideoDecoder.mvDetail(try await request(
            path: "/weapi/v1/mv/detail",
            payload: ["id": id],
            cache: .detail,
            refreshCache: refreshCache,
            expectedCredentialRevision: expectedCredentialRevision
        )) else { throw EAPIError.missingData("data") }
        return detail
    }

    func videoDetail(
        id rawID: String,
        refreshCache: Bool = false,
        expectedCredentialRevision: UInt64? = nil
    ) async throws -> VideoDetail {
        let id = try videoID(rawID)
        guard let detail = VideoDecoder.videoDetail(try await request(
            path: "/weapi/cloudvideo/v1/video/detail",
            payload: ["id": id],
            cache: .detail,
            refreshCache: refreshCache,
            expectedCredentialRevision: expectedCredentialRevision
        )) else { throw EAPIError.missingData("data") }
        return detail
    }

    func mvPlaybackSource(
        id: Int64,
        preferredResolution: Int,
        availableResolutions: [Int]
    ) async throws -> VideoPlaybackSource {
        guard id > 0 else { throw EAPIError.invalidPayload }
        let credentialRevision = transport.credentialSnapshotValue().revision
        return try await playbackSource(preferredResolution, available: availableResolutions) {
            resolution, credential in
            try VideoDecoder.mvPlaybackSource(
                await request(
                    path: "/weapi/song/enhance/play/mv/url",
                    payload: ["id": id, "r": resolution],
                    expectedCredentialRevision: credentialRevision,
                    vipCredential: credential,
                    restrictsRedirects: true
                ),
                requestedResolution: resolution
            )
        }
    }

    func videoPlaybackSource(
        id rawID: String,
        preferredResolution: Int,
        availableResolutions: [Int]
    ) async throws -> VideoPlaybackSource {
        let id = try videoID(rawID)
        let ids = try jsonString([id])
        let credentialRevision = transport.credentialSnapshotValue().revision
        return try await playbackSource(preferredResolution, available: availableResolutions) {
            resolution, credential in
            try VideoDecoder.videoPlaybackSource(
                await request(
                    path: "/weapi/cloudvideo/playurl",
                    payload: ["ids": ids, "resolution": resolution],
                    expectedCredentialRevision: credentialRevision,
                    vipCredential: credential,
                    restrictsRedirects: true
                ),
                requestedResolution: resolution
            )
        }
    }

    func setMVSubscribed(
        _ id: Int64,
        subscribed: Bool,
        expectedCredentialRevision: UInt64
    ) async throws {
        guard id > 0 else { throw EAPIError.invalidPayload }
        let action = subscribed ? "sub" : "unsub"
        _ = try await request(
            path: "/weapi/mv/\(action)",
            payload: ["mvId": id, "mvIds": try jsonString([String(id)])],
            expectedCredentialRevision: expectedCredentialRevision,
            retryable: false
        )
    }

    func setVideoSubscribed(
        _ rawID: String,
        subscribed: Bool,
        expectedCredentialRevision: UInt64
    ) async throws {
        let id = try videoID(rawID)
        let action = subscribed ? "sub" : "unsub"
        _ = try await request(
            path: "/weapi/cloudvideo/video/\(action)",
            payload: ["id": id],
            expectedCredentialRevision: expectedCredentialRevision,
            retryable: false
        )
    }

    func comments(
        for resource: CommentResource,
        offset: Int = 0,
        limit: Int = 20,
        beforeTime: Int64 = 0
    ) async throws -> VideoCommentPage {
        guard offset >= 0, limit > 0, beforeTime >= 0 else { throw EAPIError.invalidPayload }
        let root = try await request(
            path: "/weapi/v1/resource/comments/\(try resource.encodedThreadID())",
            payload: [
                "rid": try resource.requestID(),
                "limit": limit,
                "offset": offset,
                "beforeTime": beforeTime
            ],
            cache: .comments
        )
        return MusicLibraryDecoder.readOnlyCommentPage(
            root,
            resource: resource,
            offset: offset,
            limit: limit
        )
    }

    func related(toMV id: Int64) async throws -> [VideoRecommendation] {
        guard id > 0 else { throw EAPIError.invalidPayload }
        return VideoDecoder.recommendations(try await request(
            path: "/weapi/cloudvideo/v1/allvideo/rcmd",
            payload: ["id": String(id), "type": 0],
            cache: .detail
        ))
    }

    func related(toVideo rawID: String) async throws -> [VideoRecommendation] {
        let id = try videoID(rawID)
        return VideoDecoder.recommendations(try await request(
            path: "/weapi/cloudvideo/v1/allvideo/rcmd",
            payload: ["id": id, "type": 1],
            cache: .detail
        ))
    }

    func commentEmojiPictureIDs() async throws -> [String: String] {
        try await LiveMusicLibrary(transport: transport).commentEmojiPictureIDs()
    }

    private func request(
        path: String,
        payload: [String: Any],
        cache: EAPIReadCache? = nil,
        refreshCache: Bool = false,
        expectedCredentialRevision: UInt64? = nil,
        vipCredential: VIPRequesterCredential? = nil,
        retryable: Bool = true,
        restrictsRedirects: Bool = false
    ) async throws -> [String: Any] {
        try await transport.requestWEAPIJSONObject(
            path: path,
            payload: payload,
            cache: cache,
            refreshCache: refreshCache,
            expectedCredentialRevision: expectedCredentialRevision,
            invalidatesAccountCache: false,
            vip: vipCredential != nil,
            useStoredCookieForVIP: vipCredential == .storedCookie,
            retryable: retryable,
            restrictsRedirects: restrictsRedirects
        )
    }

    func playbackSource(
        _ preferredResolution: Int,
        available: [Int],
        load: (Int, VIPRequesterCredential) async throws -> VideoPlaybackSource
    ) async throws -> VideoPlaybackSource {
        let resolutions = VideoResolutionPolicy.playbackCandidates(
            startingAt: preferredResolution,
            available: available
        )
        let credentials = try transport.credentials()
        let hasVIPRequester = !credentials.musicU.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let cookie = credentials.cookie.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasAccountCookie = !cookie.isEmpty && !NeteaseCookieHeader.isGuest(cookie)
        var vipAuthenticationFailed = false
        var lastUnavailable: VideoLibraryError?

        for resolution in resolutions {
            if hasVIPRequester, !vipAuthenticationFailed {
                do {
                    return try await load(resolution, .independentMusicU)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    try Task.checkCancellation()
                    if SessionCredentialIssue.isAuthenticationFailure(error) {
                        vipAuthenticationFailed = true
                        guard hasAccountCookie else { throw error }
                    } else if let playbackError = error as? VideoLibraryError {
                        switch playbackError {
                        case .unavailable:
                            lastUnavailable = playbackError
                            guard hasAccountCookie else { continue }
                        case .unsafePlaybackURL:
                            guard hasAccountCookie else { throw playbackError }
                        }
                    } else {
                        throw error
                    }
                }
            }

            do {
                return try await load(resolution, .storedCookie)
            } catch is CancellationError {
                throw CancellationError()
            } catch let unavailable as VideoLibraryError {
                try Task.checkCancellation()
                guard case .unavailable = unavailable else { throw unavailable }
                lastUnavailable = unavailable
            }
        }
        throw lastUnavailable ?? VideoLibraryError.unavailable("服务未返回可用播放地址")
    }

    private func videoID(_ rawID: String) throws -> String {
        try CommentResource.video(rawID).requestID()
    }

    private func jsonString(_ value: Any) throws -> String {
        guard JSONSerialization.isValidJSONObject(value) else { throw EAPIError.invalidPayload }
        let data = try JSONSerialization.data(withJSONObject: value)
        guard let text = String(data: data, encoding: .utf8) else { throw EAPIError.invalidPayload }
        return text
    }
}
