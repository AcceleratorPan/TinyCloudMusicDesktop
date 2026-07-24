import Foundation

struct MVSummary: Identifiable, Equatable, Sendable {
    let id: Int64
    let title: String
    let artistName: String
    let coverURL: URL?
    let durationMilliseconds: Int64
}

struct VideoSummary: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let creatorName: String
    let coverURL: URL?
    let durationMilliseconds: Int64
}

struct MVDetail: Identifiable, Equatable, Sendable {
    let id: Int64
    let title: String
    let artistName: String
    let coverURL: URL?
    let durationMilliseconds: Int64
    let isSubscribed: Bool
    let availableResolutions: [Int]

    func settingSubscribed(_ subscribed: Bool) -> Self {
        Self(
            id: id,
            title: title,
            artistName: artistName,
            coverURL: coverURL,
            durationMilliseconds: durationMilliseconds,
            isSubscribed: subscribed,
            availableResolutions: availableResolutions
        )
    }
}

struct VideoDetail: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let creatorName: String
    let coverURL: URL?
    let durationMilliseconds: Int64
    let isSubscribed: Bool
    let availableResolutions: [Int]

    func settingSubscribed(_ subscribed: Bool) -> Self {
        Self(
            id: id,
            title: title,
            creatorName: creatorName,
            coverURL: coverURL,
            durationMilliseconds: durationMilliseconds,
            isSubscribed: subscribed,
            availableResolutions: availableResolutions
        )
    }
}

enum VideoRecommendation: Identifiable, Equatable, Sendable {
    case mv(MVSummary)
    case video(VideoSummary)

    var id: String {
        switch self {
        case let .mv(value): "mv-\(value.id)"
        case let .video(value): "video-\(value.id)"
        }
    }

    var route: Route {
        switch self {
        case let .mv(value): .mv(value.id)
        case let .video(value): .video(value.id)
        }
    }
}

struct VideoPlaybackSource: Equatable, Sendable {
    let url: URL
    let resolution: Int
    let expiresAt: Date?
}

struct VideoCommentPage: Equatable, Sendable {
    let comments: [MusicComment]
    let totalCount: Int
    let hasMore: Bool
    let nextOffset: Int
    let beforeTime: Int64
}

enum VideoLibraryError: LocalizedError, Equatable, Sendable {
    case unavailable(String)
    case unsafePlaybackURL

    var errorDescription: String? {
        switch self {
        case let .unavailable(message): message
        case .unsafePlaybackURL: "播放地址未通过安全校验"
        }
    }
}

enum VideoPlaybackURLPolicy {
    static func validate(_ value: String) throws -> URL {
        guard let url = URL(string: value), let normalizedURL = normalized(url) else {
            throw VideoLibraryError.unsafePlaybackURL
        }
        return normalizedURL
    }

    static func normalized(_ url: URL) -> URL? {
        if isAllowed(url) { return url }
        guard url.scheme?.lowercased() == "http", url.port == nil || url.port == 80,
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return nil }
        components.scheme = "https"
        components.port = nil
        guard let upgraded = components.url, isAllowed(upgraded) else { return nil }
        return upgraded
    }

    static func isAllowed(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https",
              url.user == nil,
              url.password == nil,
              url.port == nil || url.port == 443,
              let host = url.host?.lowercased()
        else { return false }
        return host == "vod.126.net" || host.hasSuffix(".vod.126.net")
            || host == "music.126.net" || host.hasSuffix(".music.126.net")
    }
}

final class VideoPlaybackRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(request.url.map(VideoPlaybackURLPolicy.isAllowed) == true ? request : nil)
    }
}

enum VideoPlaybackURLResolver {
    static func resolve(_ url: URL) async throws -> URL {
        guard VideoPlaybackURLPolicy.isAllowed(url) else { throw VideoLibraryError.unsafePlaybackURL }
        let session = URLSession(
            configuration: .ephemeral,
            delegate: VideoPlaybackRedirectDelegate(),
            delegateQueue: nil
        )
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = "HEAD"
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let finalURL = http.url,
              VideoPlaybackURLPolicy.isAllowed(finalURL)
        else { throw VideoLibraryError.unsafePlaybackURL }
        return finalURL
    }
}

enum VideoResolutionPolicy {
    static func preferred(_ requested: Int, available: [Int]) -> Int? {
        let values = normalized(available)
        if values.contains(requested) { return requested }
        return values.first(where: { $0 < requested }) ?? values.last
    }

    static func fallback(below resolution: Int, available: [Int]) -> Int? {
        normalized(available).first { $0 < resolution }
    }

    static func normalized(_ values: [Int]) -> [Int] {
        Array(Set(values.filter { $0 > 0 })).sorted(by: >)
    }
}

enum VideoDecoder {
    static func recommendations(_ root: [String: Any]) -> [VideoRecommendation] {
        let values = root.array("datas").isEmpty ? root.array("data") : root.array("datas")
        var seen = Set<String>()
        return values.compactMap { item in
            let value = item.object("data").isEmpty ? item : item.object("data")
            let recommendation: VideoRecommendation?
            let threadID = value.string("threadId")
            if threadID.hasPrefix("R_MV_5_") {
                recommendation = mvSummary(value).map(VideoRecommendation.mv)
            } else if threadID.hasPrefix("R_VI_62_") {
                recommendation = videoSummary(value).map(VideoRecommendation.video)
            } else if item["type"] != nil || value["type"] != nil {
                let type = item["type"] != nil ? item.int("type") : value.int("type")
                recommendation = switch type {
                case 0: mvSummary(value).map(VideoRecommendation.mv)
                case 1: videoSummary(value).map(VideoRecommendation.video)
                default: nil
                }
            } else if value["vid"] != nil || value["videoId"] != nil {
                recommendation = videoSummary(value).map(VideoRecommendation.video)
            } else {
                recommendation = mvSummary(value).map(VideoRecommendation.mv)
            }
            guard let recommendation, seen.insert(recommendation.id).inserted else { return nil }
            return recommendation
        }
    }

    static func mvDetail(_ root: [String: Any]) -> MVDetail? {
        let value = root.object("data")
        guard let summary = mvSummary(value) else { return nil }
        let bitrates = (value["brs"] as? [String: Any])?.keys.compactMap(Int.init) ?? []
        return MVDetail(
            id: summary.id,
            title: summary.title,
            artistName: summary.artistName,
            coverURL: summary.coverURL,
            durationMilliseconds: summary.durationMilliseconds,
            isSubscribed: value.bool("subed") || value.bool("subscribed"),
            availableResolutions: VideoResolutionPolicy.normalized(bitrates)
        )
    }

    static func videoDetail(_ root: [String: Any]) -> VideoDetail? {
        let value = root.object("data")
        guard let summary = videoSummary(value) else { return nil }
        return VideoDetail(
            id: summary.id,
            title: summary.title,
            creatorName: summary.creatorName,
            coverURL: summary.coverURL,
            durationMilliseconds: summary.durationMilliseconds,
            isSubscribed: value.bool("subscribed") || value.bool("subed"),
            availableResolutions: VideoResolutionPolicy.normalized(
                value.array("resolutions").map { $0.int("resolution") }
            )
        )
    }

    static func mvPlaybackSource(
        _ root: [String: Any],
        requestedResolution: Int,
        now: Date = Date()
    ) throws -> VideoPlaybackSource {
        try playbackSource(root.object("data"), requestedResolution: requestedResolution, now: now)
    }

    static func videoPlaybackSource(
        _ root: [String: Any],
        requestedResolution: Int,
        now: Date = Date()
    ) throws -> VideoPlaybackSource {
        let values = root.array("urls").isEmpty ? root.array("data") : root.array("urls")
        guard let value = values.first(where: { $0.int("r") == requestedResolution }) ?? values.first else {
            throw VideoLibraryError.unavailable("该视频暂无可用播放地址")
        }
        return try playbackSource(value, requestedResolution: requestedResolution, now: now)
    }

    private static func mvSummary(_ value: [String: Any]) -> MVSummary? {
        var id: Int64 = 0
        for key in ["id", "mvId", "vid"] where id == 0 {
            id = value.int64(key)
        }
        guard id > 0 else { return nil }
        return MVSummary(
            id: id,
            title: firstString(value, keys: ["name", "title"]),
            artistName: firstString(value, keys: ["artistName", "creatorName"])
                .nilIfEmpty ?? value.array("artists").map { $0.string("name") }.filter { !$0.isEmpty }.joined(separator: " / "),
            coverURL: firstURL(value, keys: ["cover", "coverUrl", "coverImgUrl", "imgurl16v9"]),
            durationMilliseconds: firstInt64(value, keys: ["duration", "durationms", "durationMillis"])
        )
    }

    private static func videoSummary(_ value: [String: Any]) -> VideoSummary? {
        let id = ["vid", "videoId", "id"].lazy
            .map { value.string($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? ""
        guard !id.isEmpty else { return nil }
        let creator = value.object("creator")
        let arrayCreator = value.array("creator").first ?? [:]
        return VideoSummary(
            id: id,
            title: firstString(value, keys: ["title", "name"]),
            creatorName: firstString(value, keys: ["creatorName", "artistName"])
                .nilIfEmpty
                ?? firstString(creator, keys: ["nickname", "userName", "name"]).nilIfEmpty
                ?? firstString(arrayCreator, keys: ["nickname", "userName", "name"]),
            coverURL: firstURL(value, keys: ["coverUrl", "cover", "coverImgUrl", "imageUrl"]),
            durationMilliseconds: firstInt64(value, keys: ["durationms", "duration", "durationMillis"])
        )
    }

    private static func playbackSource(
        _ value: [String: Any],
        requestedResolution: Int,
        now: Date
    ) throws -> VideoPlaybackSource {
        let rawURL = value.string("url").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawURL.isEmpty else {
            let message = value.bool("needPay") ? "该视频需要登录或开通权益后播放" : "该视频暂无可用播放地址"
            throw VideoLibraryError.unavailable(message)
        }
        let validity = ["expi", "validity"].lazy.map { value.int($0) }.first { $0 > 0 }
        return VideoPlaybackSource(
            url: try VideoPlaybackURLPolicy.validate(rawURL),
            resolution: value.int("r") > 0 ? value.int("r") : requestedResolution,
            expiresAt: validity.map { now.addingTimeInterval(TimeInterval($0)) }
        )
    }

    private static func firstString(_ value: [String: Any], keys: [String]) -> String {
        keys.lazy.map { value.string($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? ""
    }

    private static func firstInt64(_ value: [String: Any], keys: [String]) -> Int64 {
        keys.lazy.map { value.int64($0) }.first { $0 > 0 } ?? 0
    }

    private static func firstURL(_ value: [String: Any], keys: [String]) -> URL? {
        keys.lazy.compactMap { URL(string: value.string($0)) }.first
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
