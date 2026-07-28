import Foundation

struct LiveVideoLibrary: Sendable {
    let transport: EAPITransport

    init(transport: EAPITransport = EAPITransport()) {
        self.transport = transport
    }

    func recommendations(offset: Int = 0) async throws -> [VideoRecommendation] {
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
            cache: .detail
        )
        return VideoDecoder.recommendations(root)
    }

    func mvDetail(id: Int64) async throws -> MVDetail {
        guard id > 0 else { throw EAPIError.invalidPayload }
        guard let detail = VideoDecoder.mvDetail(try await request(
            path: "/weapi/v1/mv/detail",
            payload: ["id": id],
            cache: .detail
        )) else { throw EAPIError.missingData("data") }
        return detail
    }

    func videoDetail(id rawID: String) async throws -> VideoDetail {
        let id = try videoID(rawID)
        guard let detail = VideoDecoder.videoDetail(try await request(
            path: "/weapi/cloudvideo/v1/video/detail",
            payload: ["id": id],
            cache: .detail
        )) else { throw EAPIError.missingData("data") }
        return detail
    }

    func mvPlaybackSource(
        id: Int64,
        preferredResolution: Int,
        availableResolutions: [Int]
    ) async throws -> VideoPlaybackSource {
        guard id > 0 else { throw EAPIError.invalidPayload }
        return try await playbackSource(preferredResolution, available: availableResolutions) { resolution in
            try VideoDecoder.mvPlaybackSource(
                await request(
                    path: "/weapi/song/enhance/play/mv/url",
                    payload: ["id": id, "r": resolution]
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
        return try await playbackSource(preferredResolution, available: availableResolutions) { resolution in
            try VideoDecoder.videoPlaybackSource(
                await request(
                    path: "/weapi/cloudvideo/playurl",
                    payload: ["ids": ids, "resolution": resolution]
                ),
                requestedResolution: resolution
            )
        }
    }

    func setMVSubscribed(_ id: Int64, subscribed: Bool) async throws {
        guard id > 0 else { throw EAPIError.invalidPayload }
        let action = subscribed ? "sub" : "unsub"
        _ = try await request(
            path: "/weapi/mv/\(action)",
            payload: ["mvId": id, "mvIds": try jsonString([String(id)])]
        )
        await transport.invalidateCachedResponses(in: [.detail, .library])
    }

    func setVideoSubscribed(_ rawID: String, subscribed: Bool) async throws {
        let id = try videoID(rawID)
        let action = subscribed ? "sub" : "unsub"
        _ = try await request(
            path: "/weapi/cloudvideo/video/\(action)",
            payload: ["id": id]
        )
        await transport.invalidateCachedResponses(in: [.detail, .library])
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

    func invalidateCachedResponses(in groups: Set<EAPIReadCache>) async {
        await transport.invalidateCachedResponses(in: groups)
    }

    private func request(
        path: String,
        payload: [String: Any],
        cache: EAPIReadCache? = nil
    ) async throws -> [String: Any] {
        try decodedJSONObject(try await transport.requestWEAPI(
            path: path,
            payload: payload,
            cache: cache,
            invalidatesAccountCache: false
        ))
    }

    func playbackSource(
        _ preferredResolution: Int,
        available: [Int],
        load: (Int) async throws -> VideoPlaybackSource
    ) async throws -> VideoPlaybackSource {
        guard let resolution = VideoResolutionPolicy.preferred(preferredResolution, available: available) else {
            throw VideoLibraryError.unavailable("服务未返回可用清晰度")
        }
        do {
            return try await load(resolution)
        } catch let error as VideoLibraryError {
            try Task.checkCancellation()
            guard case .unavailable = error,
                  let fallback = VideoResolutionPolicy.fallback(below: resolution, available: available)
            else {
                throw error
            }
            return try await load(fallback)
        }
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
