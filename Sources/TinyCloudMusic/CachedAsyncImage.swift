import Nuke
import NukeUI
import Observation
import OSLog
import SwiftUI

enum CachedAsyncImagePhase {
    case empty
    case success(Image)
    case failure

    var image: Image? {
        guard case let .success(image) = self else { return nil }
        return image
    }
}

@MainActor
@Observable
final class ArtworkPipeline {
    static let memoryCostLimit = 256 * 1_024 * 1_024
    static let diskCostLimit = 512 * 1_024 * 1_024
    static let maximumResponseSize = 25 * 1_024 * 1_024
    static let diskTTL: TimeInterval = 24 * 60 * 60
    static let shared = ArtworkPipeline()

    private static let logger = Logger(subsystem: "TinyCloudMusic", category: "ArtworkCache")

    private(set) var pipeline: ImagePipeline
    private(set) var generation = 0
    private(set) var failureRefreshGeneration = 0
    private(set) var cacheDirectory: URL

    private init() {
        let root = Self.defaultCacheRoot
        let result = Self.makePipeline(cacheRoot: root)
        pipeline = result.pipeline
        cacheDirectory = result.cacheDirectory
    }

    func configure(cacheRoot: URL) {
        let requestedRoot = cacheRoot.standardizedFileURL
        let requestedDirectory = Self.artworkDirectory(in: requestedRoot)
        guard requestedDirectory != cacheDirectory.standardizedFileURL else { return }

        let oldPipeline = pipeline
        let result = Self.makePipeline(cacheRoot: requestedRoot)
        pipeline = result.pipeline
        cacheDirectory = result.cacheDirectory
        generation &+= 1
        oldPipeline.invalidate()
    }

    func retryFailedImages() {
        failureRefreshGeneration &+= 1
    }

    func loadImage(for request: ImageRequest, maximumRetryCount: Int = 2) async throws -> PlatformImage {
        var retryCount = 0
        while true {
            try Task.checkCancellation()
            do {
                return try await pipeline.image(for: request)
            } catch {
                if case .cancelled = error { throw CancellationError() }
                if Task.isCancelled { throw CancellationError() }
                guard retryCount < maximumRetryCount, Self.isTransient(error) else { throw error }
                try await Task.sleep(for: .milliseconds(400 << retryCount))
                retryCount += 1
            }
        }
    }

    func loadData(for url: URL) async throws -> Data {
        guard let request = Self.originalRequest(for: url) else { throw URLError(.badURL) }
        return try await pipeline.data(for: request).0
    }

    static func request(
        for url: URL?,
        size: CGSize,
        displayScale: CGFloat = 1,
        now: Date = Date()
    ) -> ImageRequest? {
        guard var request = originalRequest(for: url, now: now),
              size.width.isFinite, size.height.isFinite,
              size.width > 0, size.height > 0,
              displayScale.isFinite, displayScale > 0
        else { return nil }

        let scale = max(1, displayScale)
        let edge = bucketedEdge(for: size) * scale
        request.scale = Float(scale)
        request.thumbnail = .init(
            size: CGSize(width: edge, height: edge),
            unit: .pixels,
            contentMode: .aspectFill
        )
        return request
    }

    static func bucketedEdge(for size: CGSize) -> CGFloat {
        ceil(max(size.width, size.height) / 32) * 32
    }

    private static func originalRequest(for url: URL?, now: Date = Date()) -> ImageRequest? {
        guard let sourceURL = url else { return nil }
        let url = ArtworkURLPolicy.secureURL(for: sourceURL)
        guard
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http"
        else { return nil }

        let epoch = Int(now.timeIntervalSince1970 / diskTTL)
        var request = ImageRequest(url: url)
        // The epoch is part of both memory and disk identity. This bounds same-URL
        // artwork staleness without defeating Nuke's original-data sharing or LRU.
        request.imageID = "\(url.absoluteString)#artwork-v2-\(epoch)"
        return request
    }

    static func isTransient(_ error: any Error) -> Bool {
        guard let error = error as? ImagePipeline.Error else {
            return isTransientLoadingError(error)
        }
        switch error {
        case let .dataLoadingFailed(underlying):
            return isTransientLoadingError(underlying)
        case .dataIsEmpty, .pipelineInvalidated:
            return true
        case .dataMissingInCache, .decoderNotRegistered, .decodingFailed,
             .processingFailed, .imageRequestMissing, .dataDownloadExceededMaximumSize,
             .cancelled:
            return false
        }
    }

    private static func isTransientLoadingError(_ error: any Error) -> Bool {
        if let error = error as? DataLoader.Error {
            switch error {
            case let .statusCodeUnacceptable(status):
                return status == 408 || status == 429 || status >= 500
            }
        }
        if let error = error as? URLError {
            return switch error.code {
            case .timedOut, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed,
                 .networkConnectionLost, .notConnectedToInternet, .internationalRoamingOff,
                 .callIsActive, .dataNotAllowed, .resourceUnavailable:
                true
            default:
                false
            }
        }
        return false
    }

    private static var defaultCacheRoot: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: "TinyCloudMusic", directoryHint: .isDirectory)
    }

    private static func artworkDirectory(in root: URL) -> URL {
        root.appending(path: "ArtworkCache.v2", directoryHint: .isDirectory).standardizedFileURL
    }

    private static func makePipeline(cacheRoot: URL) -> (pipeline: ImagePipeline, cacheDirectory: URL) {
        let requestedDirectory = artworkDirectory(in: cacheRoot)
        do {
            return (makePipeline(dataCache: try makeDataCache(at: requestedDirectory)), requestedDirectory)
        } catch {
            logger.error("Unable to create artwork cache at \(requestedDirectory.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }

        let fallbackDirectory = artworkDirectory(in: defaultCacheRoot)
        if fallbackDirectory != requestedDirectory {
            do {
                logger.notice("Falling back to the standard artwork cache directory")
                return (makePipeline(dataCache: try makeDataCache(at: fallbackDirectory)), fallbackDirectory)
            } catch {
                logger.error("Unable to create fallback artwork cache: \(error.localizedDescription, privacy: .public)")
            }
        }

        logger.fault("Artwork disk cache is disabled for this process")
        return (makePipeline(dataCache: nil), fallbackDirectory)
    }

    private static func makeDataCache(at directory: URL) throws -> DataCache {
        let cache = try DataCache(path: directory)
        cache.sizeLimit = diskCostLimit
        cache.sweepInterval = 30 * 60
        return cache
    }

    private static func makePipeline(dataCache: DataCache?) -> ImagePipeline {
        let session = URLSessionConfiguration.default
        session.urlCache = nil
        session.requestCachePolicy = .reloadIgnoringLocalCacheData
        session.httpShouldSetCookies = false
        session.httpMaximumConnectionsPerHost = 6
        session.timeoutIntervalForRequest = 20
        session.timeoutIntervalForResource = 60

        let memory = ImageCache(costLimit: memoryCostLimit, countLimit: 2_000)
        memory.ttl = diskTTL

        var configuration = ImagePipeline.Configuration(dataLoader: DataLoader(configuration: session))
        configuration.imageCache = memory
        configuration.dataCache = dataCache
        configuration.dataCachePolicy = .storeOriginalData
        configuration.isDecompressionEnabled = true
        configuration.isTaskCoalescingEnabled = true
        configuration.isRateLimiterEnabled = true
        configuration.isResumableDataEnabled = true
        configuration.maximumResponseDataSize = maximumResponseSize
#if DEBUG
        ImagePipeline.Configuration.isSignpostLoggingEnabled = true
#endif
        return ImagePipeline(configuration: configuration)
    }
}

@MainActor
struct CachedAsyncImage<Content: View>: View {
    let url: URL?
    @ViewBuilder let content: (CachedAsyncImagePhase) -> Content

    @Environment(\.displayScale) private var displayScale
    @State private var retryCount = 0
    @State private var requestNonce = 0
    @State private var lastFailureWasTransient = false
    @State private var retryTask: Task<Void, Never>?

    init(url: URL?, @ViewBuilder content: @escaping (CachedAsyncImagePhase) -> Content) {
        self.url = url
        self.content = content
    }

    var body: some View {
        GeometryReader { proxy in
            image(size: proxy.size)
        }
        .onChange(of: ArtworkPipeline.shared.failureRefreshGeneration) { _, _ in
            guard lastFailureWasTransient else { return }
            retryTask?.cancel()
            retryTask = nil
            retryCount = 0
            requestNonce &+= 1
            lastFailureWasTransient = false
        }
        .onChange(of: url) { _, _ in resetRetryState() }
        .onAppear { scheduleRetryIfNeeded() }
        .onDisappear {
            retryTask?.cancel()
            retryTask = nil
        }
    }

    @ViewBuilder
    private func image(size: CGSize) -> some View {
        let controller = ArtworkPipeline.shared
        let pixelEdge = ArtworkPipeline.bucketedEdge(for: size) * max(1, displayScale)
        if let request = ArtworkPipeline.request(for: url, size: size, displayScale: displayScale) {
            LazyImage(request: request) { state in
                if let image = state.image {
                    content(.success(image))
                } else if state.error != nil {
                    content(.failure)
                } else {
                    content(.empty)
                }
            }
            .pipeline(controller.pipeline)
            .onCompletion(handleCompletion)
            .onDisappear(.lowerPriority)
            // NukeUI 13 omits thumbnail from LazyImageContext equality.
            .id("\(url?.absoluteString ?? ""):\(pixelEdge):\(controller.generation):\(requestNonce)")
        } else {
            content(.empty)
        }
    }

    private func handleCompletion(_ result: Result<ImageResponse, any Error>) {
        switch result {
        case .success:
            retryTask?.cancel()
            retryTask = nil
            retryCount = 0
            lastFailureWasTransient = false
        case let .failure(error):
            let transient = ArtworkPipeline.isTransient(error)
            lastFailureWasTransient = transient
            scheduleRetryIfNeeded()
        }
    }

    private func scheduleRetryIfNeeded() {
        guard lastFailureWasTransient, retryCount < 2, retryTask == nil else { return }
        let delay = Duration.milliseconds(400 << retryCount)
        retryTask = Task { @MainActor in
            do {
                try await Task.sleep(for: delay)
                try Task.checkCancellation()
                retryTask = nil
                retryCount += 1
                requestNonce &+= 1
            } catch {
                retryTask = nil
            }
        }
    }

    private func resetRetryState() {
        retryTask?.cancel()
        retryTask = nil
        retryCount = 0
        requestNonce &+= 1
        lastFailureWasTransient = false
    }
}
