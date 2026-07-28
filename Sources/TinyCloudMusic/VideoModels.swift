import Foundation

struct MVDetail: Identifiable, Equatable, Sendable {
    let id: Int64
    let title: String
    let artistName: String
    let description: String
    let publishTime: String
    let playCount: Int64
    let coverURL: URL?
    let durationMilliseconds: Int64
    let isSubscribed: Bool
    let availableResolutions: [Int]

    func settingSubscribed(_ subscribed: Bool) -> Self {
        Self(
            id: id,
            title: title,
            artistName: artistName,
            description: description,
            publishTime: publishTime,
            playCount: playCount,
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
    let description: String
    let publishTime: String
    let playCount: Int64
    let coverURL: URL?
    let durationMilliseconds: Int64
    let isSubscribed: Bool
    let availableResolutions: [Int]

    func settingSubscribed(_ subscribed: Bool) -> Self {
        Self(
            id: id,
            title: title,
            creatorName: creatorName,
            description: description,
            publishTime: publishTime,
            playCount: playCount,
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

struct VideoSubscriptionPage: Equatable, Sendable {
    let items: [VideoRecommendation]
    let nextOffset: Int
    let hasMore: Bool

    func appending(_ next: Self) -> Self {
        var ids = Set(items.map(\.id))
        let values = items + next.items.filter { ids.insert($0.id).inserted }
        let progressed = next.nextOffset > nextOffset
        return Self(
            items: values,
            nextOffset: max(nextOffset, next.nextOffset),
            hasMore: next.hasMore && progressed
        )
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
    private let lock = NSLock()
    private var rejectedRedirect = false

    var rejectedUnsafeRedirect: Bool { lock.withLock { rejectedRedirect } }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard request.url.map(VideoPlaybackURLPolicy.isAllowed) == true else {
            lock.withLock { rejectedRedirect = true }
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}

enum VideoPlaybackURLResolver {
    static func resolve(
        _ url: URL,
        configuration: URLSessionConfiguration = .ephemeral
    ) async throws -> URL {
        guard let url = VideoPlaybackURLPolicy.normalized(url) else {
            throw VideoLibraryError.unsafePlaybackURL
        }
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 15
        let delegate = VideoPlaybackRedirectDelegate()
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        request.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse,
                  let finalURL = http.url,
                  !delegate.rejectedUnsafeRedirect,
                  VideoPlaybackURLPolicy.isAllowed(finalURL)
            else { throw VideoLibraryError.unsafePlaybackURL }
            guard http.statusCode == 200 || http.statusCode == 206 else {
                throw VideoLibraryError.unavailable("播放地址暂不可用（HTTP \(http.statusCode)）")
            }
            guard try await bytes.first(where: { _ in true }) != nil else {
                throw VideoLibraryError.unavailable("播放地址未返回有效内容")
            }
            return finalURL
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled && Task.isCancelled {
            throw CancellationError()
        } catch let error as VideoLibraryError {
            throw error
        } catch {
            if delegate.rejectedUnsafeRedirect { throw VideoLibraryError.unsafePlaybackURL }
            throw VideoLibraryError.unavailable("无法连接播放地址，请稍后重试")
        }
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
    static func personalizedMVs(_ root: [String: Any]) -> [VideoRecommendation] {
        var seen = Set<String>()
        return root.array("result").compactMap { value in
            guard let summary = mvSummary(value), seen.insert(String(summary.id)).inserted else { return nil }
            return .mv(summary)
        }
    }

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

    static func subscriptions(
        _ root: [String: Any],
        offset: Int,
        limit: Int
    ) -> VideoSubscriptionPage {
        let values = root.array("data")
        let nextOffset = offset + values.count
        let total = root.int("count")
        let hasMore = if root["hasMore"] != nil {
            root.bool("hasMore")
        } else if total > 0 {
            nextOffset < total
        } else {
            values.count == limit
        }
        return VideoSubscriptionPage(
            items: recommendations(root),
            nextOffset: nextOffset,
            hasMore: hasMore && nextOffset > offset
        )
    }

    static func mvDetail(_ root: [String: Any]) -> MVDetail? {
        let value = root.object("data")
        guard let summary = mvSummary(value) else { return nil }
        let resolutionCandidates = ((value["brs"] as? [String: Any])?.keys.compactMap(Int.init) ?? [])
            + value.array("brs").compactMap { value in
                ["resolution", "r"].lazy.map { value.int($0) }.first { $0 > 0 }
            }
        let resolutions = VideoResolutionPolicy.normalized(
            resolutionCandidates.filter { [1080, 720, 480, 240].contains($0) }
        )
        return MVDetail(
            id: summary.id,
            title: summary.title,
            artistName: summary.artistName,
            description: firstString(value, keys: ["desc", "briefDesc"]),
            publishTime: publishTime(value),
            playCount: value.int64("playCount"),
            coverURL: summary.coverURL,
            durationMilliseconds: summary.durationMilliseconds,
            isSubscribed: value.bool("subed") || value.bool("subscribed"),
            availableResolutions: resolutions.isEmpty ? [1080, 720, 480, 240] : resolutions
        )
    }

    static func videoDetail(_ root: [String: Any]) -> VideoDetail? {
        let value = root.object("data")
        guard let summary = videoSummary(value) else { return nil }
        return VideoDetail(
            id: summary.id,
            title: summary.title,
            creatorName: summary.creatorName,
            description: firstString(value, keys: ["description", "desc"]),
            publishTime: publishTime(value),
            playCount: value.int64("playTime"),
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

    static func mvSummary(_ value: [String: Any]) -> MVSummary? {
        var id: Int64 = 0
        for key in ["id", "mvId", "vid"] where id == 0 {
            id = value.int64(key)
        }
        guard id > 0 else { return nil }
        let artists = value.array("artists")
        let creators = artists.isEmpty ? value.array("creator") : artists
        return MVSummary(
            id: id,
            title: firstString(value, keys: ["name", "title"]),
            artistName: firstString(value, keys: ["artistName", "creatorName"])
                .nilIfEmpty
                ?? creators.map { firstString($0, keys: ["name", "userName", "nickname"]) }
                    .filter { !$0.isEmpty }
                    .joined(separator: " / "),
            coverURL: firstURL(value, keys: ["cover", "coverUrl", "coverImgUrl", "imgurl16v9", "picUrl"]),
            durationMilliseconds: firstInt64(value, keys: ["duration", "durationms", "durationMillis"])
        )
    }

    static func videoSummary(_ value: [String: Any]) -> VideoSummary? {
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
        let urlInfo = value.object("urlInfo")
        let rawURL = firstString(value, keys: ["url"]).nilIfEmpty
            ?? firstString(urlInfo, keys: ["url"])
        guard !rawURL.isEmpty else {
            let message = value.bool("needPay") || urlInfo.bool("needPay")
                ? "该视频需要登录或开通权益后播放"
                : "该视频暂无可用播放地址"
            throw VideoLibraryError.unavailable(message)
        }
        let keys = ["expi", "validity", "validityTime"]
        let validity = keys.lazy.map { value.int($0) }.first { $0 > 0 }
            ?? keys.lazy.map { urlInfo.int($0) }.first { $0 > 0 }
        let returnedResolution = value.int("r") > 0 ? value.int("r") : urlInfo.int("r")
        return VideoPlaybackSource(
            url: try VideoPlaybackURLPolicy.validate(rawURL),
            resolution: returnedResolution > 0 ? returnedResolution : requestedResolution,
            expiresAt: validity.map { now.addingTimeInterval(TimeInterval($0)) }
        )
    }

    private static func firstString(_ value: [String: Any], keys: [String]) -> String {
        keys.lazy.map { value.string($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? ""
    }

    private static func publishTime(_ value: [String: Any]) -> String {
        let raw = value.string("publishTime").trimmingCharacters(in: .whitespacesAndNewlines)
        guard let milliseconds = Int64(raw), milliseconds > 0 else { return raw }
        return Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1_000)
            .formatted(date: .numeric, time: .omitted)
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
