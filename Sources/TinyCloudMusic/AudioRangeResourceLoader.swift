import AVFoundation
import Foundation
import UniformTypeIdentifiers

func resolvedAudioContentTypeIdentifier(
    mimeType: String?,
    format: String,
    allowedContentTypes: [String]
) throws -> String {
    let normalizedMIME = mimeType?
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
    let mimeCandidate = normalizedMIME.flatMap { value -> UTType? in
        guard !value.isEmpty, value != "application/octet-stream",
              let type = UTType(mimeType: value), type != .data, !type.isDynamic
        else { return nil }
        return type
    }
    guard let candidate = mimeCandidate ?? UTType(filenameExtension: format.lowercased()),
          candidate != .data,
          !candidate.isDynamic
    else { throw TrackRangeCacheError.rejectedResponse }

    if allowedContentTypes.isEmpty { return candidate.identifier }
    for identifier in allowedContentTypes {
        if candidate.identifier == identifier { return identifier }
        if let allowed = UTType(identifier), candidate.conforms(to: allowed) {
            return identifier
        }
    }
    throw TrackRangeCacheError.rejectedResponse
}

@MainActor
final class RangeCachingPlayerItem: AVPlayerItem {
    let key: TrackRangeCacheKey
    let rangeCache: TrackRangeCache

    private let loaderDelegate: AudioRangeResourceLoaderDelegate

    init(
        key: TrackRangeCacheKey,
        format: String,
        initialSource: PlaybackSource?,
        sourceProvider: @escaping TrackRangeCache.SourceProvider,
        rangeCache: TrackRangeCache,
        preferPreciseTiming: Bool
    ) {
        let normalizedFormat = format.lowercased()
        precondition(["mp3", "flac", "ogg", "wav", "m4a"].contains(normalizedFormat))
        let delegate = AudioRangeResourceLoaderDelegate(
            key: key,
            format: normalizedFormat,
            initialSource: initialSource,
            sourceProvider: sourceProvider,
            rangeCache: rangeCache
        )
        let url = URL(
            string: "tcm-audio-cache://resource/\(UUID().uuidString).\(normalizedFormat)"
        )!
        let asset = AVURLAsset(url: url, options: [
            AVURLAssetPreferPreciseDurationAndTimingKey: preferPreciseTiming,
        ])

        self.key = key
        self.rangeCache = rangeCache
        loaderDelegate = delegate
        asset.resourceLoader.setDelegate(delegate, queue: delegate.queue)
        super.init(asset: asset, automaticallyLoadedAssetKeys: nil)
    }

    func cancelRangeLoading() {
        loaderDelegate.cancel()
    }
}

private final class LoadingRequestContext: @unchecked Sendable {
    // The delegate queue is the sole owner of all mutable state and loadingRequest access.
    let loadingRequest: AVAssetResourceLoadingRequest
    let identifier: ObjectIdentifier
    var task: Task<Void, Never>?
    var isFinished = false

    init(_ loadingRequest: AVAssetResourceLoadingRequest) {
        self.loadingRequest = loadingRequest
        identifier = ObjectIdentifier(loadingRequest)
    }
}

private struct LoaderFailure: @unchecked Sendable {
    let error: Error
}

private final class AudioRangeResourceLoaderDelegate: NSObject,
    AVAssetResourceLoaderDelegate,
    @unchecked Sendable
{
    let queue = DispatchQueue(label: "com.tinycloudmusic.audio-range-resource-loader")

    private static let responseChunkSize = 256 * 1_024

    private let queueKey = DispatchSpecificKey<UInt8>()
    private let rangeCache: TrackRangeCache
    private let sessionOpener: @Sendable () async throws -> TrackRangeCache.Session
    private var contexts: [ObjectIdentifier: LoadingRequestContext] = [:]
    private var sessionOpenTask: Task<TrackRangeCache.Session, Error>?
    private var isInvalidated = false

    init(
        key: TrackRangeCacheKey,
        format: String,
        initialSource: PlaybackSource?,
        sourceProvider: @escaping TrackRangeCache.SourceProvider,
        rangeCache: TrackRangeCache
    ) {
        self.rangeCache = rangeCache
        sessionOpener = {
            try await rangeCache.open(
                key: key,
                format: format,
                initialSource: initialSource,
                sourceProvider: sourceProvider
            )
        }
        super.init()
        queue.setSpecific(key: queueKey, value: 1)
    }

    deinit {
        cancel()
    }

    func cancel() {
        let openTask = if DispatchQueue.getSpecific(key: queueKey) != nil {
            invalidate()
        } else {
            queue.sync { invalidate() }
        }
        if let openTask {
            let rangeCache = rangeCache
            Task {
                guard let session = try? await openTask.value else { return }
                await rangeCache.close(session)
            }
        }
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        guard !isInvalidated else { return false }
        let context = LoadingRequestContext(loadingRequest)
        guard contexts[context.identifier] == nil else { return false }
        contexts[context.identifier] = context
        loadContentInformation(for: context)
        return true
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        didCancel loadingRequest: AVAssetResourceLoadingRequest
    ) {
        let identifier = ObjectIdentifier(loadingRequest)
        guard let context = contexts.removeValue(forKey: identifier), !context.isFinished else {
            return
        }
        context.isFinished = true
        let task = context.task
        context.task = nil
        task?.cancel()
    }

    private func sharedSessionTask() -> Task<TrackRangeCache.Session, Error> {
        if let sessionOpenTask { return sessionOpenTask }
        let opener = sessionOpener
        let task = Task { try await opener() }
        sessionOpenTask = task
        return task
    }

    private func loadContentInformation(for context: LoadingRequestContext) {
        let openTask = sharedSessionTask()
        let rangeCache = rangeCache
        let queue = queue
        context.task = Task {
            do {
                let session = try await openTask.value
                try Task.checkCancellation()
                let information = try await rangeCache.contentInfo(for: session)
                try Task.checkCancellation()
                queue.async { [weak self, context] in
                    self?.accept(information, for: context)
                }
            } catch {
                let failure = LoaderFailure(error: error)
                queue.async { [weak self, context] in
                    self?.finish(context, error: failure.error)
                }
            }
        }
    }

    private func accept(
        _ information: TrackRangeCache.ContentInfo,
        for context: LoadingRequestContext
    ) {
        guard isActive(context) else { return }
        context.task = nil
        do {
            let contentRequest = context.loadingRequest.contentInformationRequest
            let contentType = try resolvedAudioContentTypeIdentifier(
                mimeType: information.mimeType,
                format: information.format,
                allowedContentTypes: contentRequest?.allowedContentTypes ?? []
            )
            if let contentRequest {
                contentRequest.contentType = contentType
                contentRequest.contentLength = information.contentLength
                contentRequest.isByteRangeAccessSupported = true
            }
            readNextChunk(for: context)
        } catch {
            finish(context, error: error)
        }
    }

    private func readNextChunk(for context: LoadingRequestContext) {
        guard isActive(context) else { return }
        guard let dataRequest = context.loadingRequest.dataRequest else {
            finish(context)
            return
        }

        let offset = max(dataRequest.requestedOffset, dataRequest.currentOffset)
        guard offset >= 0 else {
            finish(context, error: TrackRangeCacheError.rejectedResponse)
            return
        }

        let maximumLength: Int
        if dataRequest.requestsAllDataToEndOfResource {
            maximumLength = Self.responseChunkSize
        } else {
            let (endOffset, overflow) = dataRequest.requestedOffset.addingReportingOverflow(
                Int64(dataRequest.requestedLength)
            )
            guard !overflow, endOffset >= dataRequest.requestedOffset else {
                finish(context, error: TrackRangeCacheError.rejectedResponse)
                return
            }
            guard offset < endOffset else {
                finish(context)
                return
            }
            maximumLength = Int(min(Int64(Self.responseChunkSize), endOffset - offset))
        }

        let openTask = sharedSessionTask()
        let rangeCache = rangeCache
        let queue = queue
        context.task = Task {
            do {
                let session = try await openTask.value
                try Task.checkCancellation()
                let data = try await rangeCache.read(
                    session: session,
                    offset: offset,
                    maximumLength: maximumLength
                )
                try Task.checkCancellation()
                queue.async { [weak self, context] in
                    self?.accept(data, maximumLength: maximumLength, for: context)
                }
            } catch {
                let failure = LoaderFailure(error: error)
                queue.async { [weak self, context] in
                    self?.finish(context, error: failure.error)
                }
            }
        }
    }

    private func accept(
        _ data: Data,
        maximumLength: Int,
        for context: LoadingRequestContext
    ) {
        guard isActive(context) else { return }
        context.task = nil
        guard data.count <= maximumLength else {
            finish(context, error: TrackRangeCacheError.rejectedResponse)
            return
        }
        guard !data.isEmpty else {
            finish(context)
            return
        }
        guard let dataRequest = context.loadingRequest.dataRequest else {
            finish(context)
            return
        }
        dataRequest.respond(with: data)
        readNextChunk(for: context)
    }

    private func isActive(_ context: LoadingRequestContext) -> Bool {
        !context.isFinished && contexts[context.identifier] === context
    }

    private func finish(_ context: LoadingRequestContext, error: Error? = nil) {
        guard isActive(context), contexts.removeValue(forKey: context.identifier) != nil else {
            return
        }
        context.isFinished = true
        context.task = nil
        if let error {
            context.loadingRequest.finishLoading(with: error)
        } else {
            context.loadingRequest.finishLoading()
        }
    }

    private func invalidate() -> Task<TrackRangeCache.Session, Error>? {
        guard !isInvalidated else { return nil }
        isInvalidated = true
        for context in contexts.values {
            context.isFinished = true
            context.task?.cancel()
            context.task = nil
        }
        contexts.removeAll()
        let openTask = sessionOpenTask
        sessionOpenTask = nil
        openTask?.cancel()
        return openTask
    }
}
