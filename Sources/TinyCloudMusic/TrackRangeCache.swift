import CryptoKit
import Foundation

struct TrackRangeCacheKey: Hashable, Codable, Sendable {
    let songID: Int64
    let quality: String
}

enum TrackRangeCacheError: LocalizedError, Equatable, Sendable {
    case invalidSource
    case sourceLevelMismatch(expected: String, actual: String?)
    case rejectedResponse
    case unverifiableRepresentation
    case inconsistentRepresentation
    case sourceExpired

    var errorDescription: String? {
        switch self {
        case .invalidSource: "Invalid playback source"
        case .sourceLevelMismatch: "Playback source quality does not match"
        case .rejectedResponse: "Range response was rejected"
        case .unverifiableRepresentation: "Playback representation could not be verified"
        case .inconsistentRepresentation: "Playback representation changed"
        case .sourceExpired: "Playback source expired"
        }
    }
}

private struct RangeCacheMetadata: Codable {
    let schemaVersion: Int
    let entryID: UUID
    let songID: Int64
    let quality: String
    let format: String
    let mimeType: String?
    let contentLength: Int64
    let contentMD5: String
    let coveredRanges: [StoredByteRange]
}

private final class TrackRangeCacheRegistry: @unchecked Sendable {
    private final class WeakCache {
        weak var value: TrackRangeCache?

        init(_ value: TrackRangeCache) {
            self.value = value
        }
    }

    private let lock = NSLock()
    private var caches: [ObjectIdentifier: WeakCache] = [:]

    func cache(for trackCache: TrackCache) -> TrackRangeCache {
        let key = ObjectIdentifier(trackCache)
        return lock.withLock {
            if let cache = caches[key]?.value { return cache }
            let cache = TrackRangeCache(trackCache: trackCache)
            caches[key] = WeakCache(cache)
            return cache
        }
    }
}

actor TrackRangeCache {
    nonisolated let trackCache: TrackCache

    struct Session: Hashable, Sendable {
        fileprivate let id: UUID
    }

    struct Descriptor: Equatable, Sendable {
        let format: String
        let mimeType: String?
        let contentLength: Int64
    }

    struct ContentInfo: Equatable, Sendable {
        let format: String
        let mimeType: String?
        let contentLength: Int64
        let isComplete: Bool
    }

    typealias SourceProvider = @Sendable () async throws -> PlaybackSource
    typealias Download = @Sendable (URLRequest) async throws -> (URL, URLResponse)

    private struct Publication {
        var contentInfo = false
        var data = false

        var hasPublished: Bool { contentInfo || data }
    }

    private struct ETagScope {
        let requestURL: URL
        let effectiveURL: URL
        let value: String
    }

    private struct SourceFlight {
        let id: UUID
        let task: Task<PlaybackSource, Error>
        var waiters: [UUID: CheckedContinuation<PlaybackSource, Error>] = [:]
        var isSuperseded = false
    }

    private struct RequestContext: Sendable {
        let entryID: UUID
        let epoch: UInt64
        let blockLower: Int64
        let requestedRange: Range<Int64>
        let targetOffset: Int64
        let requestURL: URL
        let sentIfRange: Bool
        let lengthWasKnown: Bool
        let rangesBefore: StreamingByteRangeSet
    }

    private struct DownloadedResponse: @unchecked Sendable {
        let temporaryURL: URL
        let response: HTTPURLResponse
        let context: RequestContext
    }

    private struct InFlight {
        let id: UUID
        let epoch: UInt64
        let requestedRange: Range<Int64>
        let task: Task<DownloadedResponse, Error>
        var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]
        var isSuperseded = false
    }

    private struct Install {
        let id: UUID
        let task: Task<Void, Never>
        var enteredStoreCopy = false
    }

    private struct Entry {
        let id: UUID
        let key: TrackRangeCacheKey
        let bodyURL: URL
        let metadataURL: URL
        var format: String
        var mimeType: String?
        var contentLength: Int64?
        var representation: PlaybackRepresentation?
        var ranges: StreamingByteRangeSet
        var publications: [Session: Publication] = [:]
        var source: PlaybackSource?
        var sourceProvider: SourceProvider?
        var sourceFlight: SourceFlight?
        var rangeValidatedURL: URL?
        var etagScope: ETagScope?
        var transientURL: URL?
        var inFlight: [Int64: InFlight] = [:]
        var install: Install?
        var installAttempted = false
        var installError: Error?
        var fullURL: URL?
        var transientMD5: String?
        var bodyPinned = false
        var fullPinned = false
        var epoch: UInt64 = 0
        var isTransient: Bool
        var isProvisional = false
        var isRetired = false
        var failure: TrackRangeCacheError?
        var installForFutureOnly = false
    }

    private enum ControlError: Error {
        case expired(URL)
        case unresolvedRange(URL)
        case localComplete
    }

    private static let supportedFormats = Set(["mp3", "flac", "ogg", "wav", "m4a"])
    private static let networkBlockSize: Int64 = 512 * 1_024
    private static let sequentialNetworkWindowSize: Int64 = 4 * networkBlockSize
    private static let responseChunkSize = 256 * 1_024
    private static let discoveryFlightKey: Int64 = -1
    private static let registry = TrackRangeCacheRegistry()

    private let download: Download
    private let afterPinForTesting: (@Sendable (URL) async -> Void)?
    private let beforeInstallWaitForTesting: (@Sendable () async -> Void)?
    private var entriesByID: [UUID: Entry] = [:]
    private var currentEntryByKey: [TrackRangeCacheKey: UUID] = [:]
    private var sessionEntry: [Session: UUID] = [:]
    private var clearDepth = 0

    init(
        trackCache: TrackCache,
        download: @escaping Download = {
            try await URLSession.shared.download(for: $0)
        },
        afterPinForTesting: (@Sendable (URL) async -> Void)? = nil,
        beforeInstallWaitForTesting: (@Sendable () async -> Void)? = nil
    ) {
        self.trackCache = trackCache
        self.afterPinForTesting = afterPinForTesting
        self.beforeInstallWaitForTesting = beforeInstallWaitForTesting
        self.download = download
    }

    nonisolated static func shared(trackCache: TrackCache) -> TrackRangeCache {
        registry.cache(for: trackCache)
    }

    deinit {
        for entry in entriesByID.values {
            if let flight = entry.sourceFlight {
                flight.task.cancel()
                flight.waiters.values.forEach { $0.resume(throwing: CancellationError()) }
            }
            entry.install?.task.cancel()
            entry.inFlight.values.forEach { request in
                request.task.cancel()
                request.waiters.values.forEach { $0.resume(throwing: CancellationError()) }
            }
        }
    }

    func descriptor(for key: TrackRangeCacheKey) -> Descriptor? {
        guard clearDepth == 0, Self.isValid(key) else { return nil }
        if let entryID = currentEntryByKey[key],
           let entry = entriesByID[entryID],
           !entry.isRetired,
           !entry.isProvisional,
           !entry.isTransient,
           entry.failure == nil,
           let length = entry.contentLength,
           loadEntry(metadataURL: entry.metadataURL, expectedKey: key) != nil {
            return Descriptor(format: entry.format, mimeType: entry.mimeType, contentLength: length)
        }
        if let entryID = currentEntryByKey[key],
           let entry = entriesByID[entryID],
           !entry.isProvisional,
           FileManager.default.fileExists(atPath: entry.metadataURL.path),
           loadEntry(metadataURL: entry.metadataURL, expectedKey: key) == nil {
            removeDamagedEntry(metadataURL: entry.metadataURL)
        }

        let directory = rangeDirectory(for: key.quality)
        guard let candidates = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        let prefix = "\(key.songID)-"
        let metadataURLs = candidates.filter {
            $0.lastPathComponent.hasPrefix(prefix)
                && $0.lastPathComponent.hasSuffix(".range.metadata.plist")
        }
        var valid: [(entry: Entry, date: Date)] = []
        for metadataURL in metadataURLs {
            if let entry = loadEntry(metadataURL: metadataURL, expectedKey: key) {
                let date = (try? metadataURL.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                valid.append((entry, date))
            } else {
                removeDamagedEntry(metadataURL: metadataURL)
            }
        }
        guard let newest = valid.max(by: { $0.date < $1.date })?.entry,
              let length = newest.contentLength
        else { return nil }
        entriesByID[newest.id] = newest
        currentEntryByKey[key] = newest.id
        return Descriptor(format: newest.format, mimeType: newest.mimeType, contentLength: length)
    }

    func open(
        key: TrackRangeCacheKey,
        format: String,
        initialSource: PlaybackSource?,
        sourceProvider: @escaping SourceProvider
    ) async throws -> Session {
        guard clearDepth == 0, Self.isValid(key), Self.isValid(format: format) else {
            throw TrackRangeCacheError.invalidSource
        }
        if let initialSource {
            try Self.validate(initialSource, for: key)
        }
        try Task.checkCancellation()

        var reusableEntryID: UUID?
        if let initialSource, let currentID = currentEntryByKey[key] {
            if let install = entriesByID[currentID]?.install {
                await beforeInstallWaitForTesting?()
                try Task.checkCancellation()
                await install.task.value
                try Task.checkCancellation()
                guard clearDepth == 0 else { throw CancellationError() }
                if let installError = entriesByID[currentID]?.installError { throw installError }
            }
            if let installed = entriesByID[currentID], let fullURL = installed.fullURL {
                let hasSameIdentity = if let representation = installed.representation {
                    initialSource.representation == representation
                } else {
                    initialSource.representation == nil && installed.source?.url == initialSource.url
                }
                if hasSameIdentity {
                    reusableEntryID = currentID
                } else {
                    retireInstalledEntryForReplacement(entryID: currentID)
                    await trackCache.invalidateCachedFile(fullURL)
                    try Task.checkCancellation()
                }
            }
        }

        let entryID: UUID
        if let currentID = reusableEntryID ?? currentEntryByKey[key],
           var current = entriesByID[currentID],
           !current.isRetired,
           current.failure == nil {
            guard current.format == format else { throw TrackRangeCacheError.invalidSource }
            if let initialSource {
                try reconcile(initialSource, with: &current)
                let sourceWaiters = takeSourceWaiters(in: &current)
                current.source = initialSource
                entriesByID[currentID] = current
                sourceWaiters.forEach { $0.resume(returning: initialSource) }
            }
            current.sourceProvider = sourceProvider
            entriesByID[currentID] = current
            entryID = currentID
        } else {
            let id = UUID()
            let bodyURL = bodyURL(for: key, entryID: id)
            try FileManager.default.createDirectory(
                at: bodyURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            guard FileManager.default.createFile(atPath: bodyURL.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown)
            }
            let representation = initialSource?.representation
            let entry = Entry(
                id: id,
                key: key,
                bodyURL: bodyURL,
                metadataURL: Self.metadataURL(for: bodyURL),
                format: format,
                mimeType: nil,
                contentLength: representation?.contentLength,
                representation: representation,
                ranges: StreamingByteRangeSet(),
                source: initialSource,
                sourceProvider: sourceProvider,
                isTransient: representation == nil,
                isProvisional: true
            )
            entriesByID[id] = entry
            if representation != nil { currentEntryByKey[key] = id }
            entryID = id
        }

        let session = Session(id: UUID())
        if var entry = entriesByID[entryID] {
            entry.publications[session] = Publication()
            entriesByID[entryID] = entry
        }
        do {
            guard let entry = entriesByID[entryID], !entry.isRetired else {
                throw CancellationError()
            }
            if !entry.bodyPinned && entry.fullURL == nil {
                let pinEpoch = entry.epoch
                guard await trackCache.pin(entry.bodyURL) else {
                    throw CocoaError(.fileNoSuchFile)
                }
                await afterPinForTesting?(entry.bodyURL)
                guard var current = entriesByID[entryID],
                      current.epoch == pinEpoch,
                      !current.isRetired
                else {
                    await trackCache.unpin(entry.bodyURL)
                    throw CancellationError()
                }
                if current.bodyPinned {
                    await trackCache.unpin(entry.bodyURL)
                } else {
                    current.bodyPinned = true
                    entriesByID[entryID] = current
                }
            }
            try Task.checkCancellation()
            guard var current = entriesByID[entryID],
                  !current.isRetired,
                  current.publications[session] != nil
            else {
                throw CancellationError()
            }
            current.isProvisional = false
            entriesByID[entryID] = current
            sessionEntry[session] = entryID
            return session
        } catch {
            sessionEntry[session] = nil
            var bodyToUnpin: URL?
            var shouldDiscard = false
            if var entry = entriesByID[entryID] {
                entry.publications[session] = nil
                let releasePin = entry.publications.isEmpty && entry.bodyPinned
                if releasePin {
                    entry.bodyPinned = false
                    bodyToUnpin = entry.bodyURL
                }
                shouldDiscard = entry.publications.isEmpty
                if entry.isProvisional && shouldDiscard {
                    entry.isRetired = true
                    if currentEntryByKey[entry.key] == entryID { currentEntryByKey[entry.key] = nil }
                }
                entriesByID[entryID] = entry
            }
            if let bodyToUnpin { await trackCache.unpin(bodyToUnpin) }
            if shouldDiscard { await discardUnusedEntry(entryID) }
            throw error
        }
    }

    func contentInfo(for session: Session) async throws -> ContentInfo {
        let entryID = try entryID(for: session)
        try await ensureLength(entryID: entryID, targetOffset: 0)
        try Task.checkCancellation()
        guard var entry = entriesByID[entryID],
              var publication = entry.publications[session],
              let length = entry.contentLength
        else { throw TrackRangeCacheError.invalidSource }
        if let failure = entry.failure { throw failure }
        publication.contentInfo = true
        entry.publications[session] = publication
        entriesByID[entryID] = entry
        return ContentInfo(
            format: entry.format,
            mimeType: entry.mimeType,
            contentLength: length,
            isComplete: entry.fullURL != nil || entry.ranges.covers(length: length)
        )
    }

    func read(
        session: Session,
        offset: Int64,
        maximumLength: Int
    ) async throws -> Data {
        guard offset >= 0, maximumLength > 0 else { throw TrackRangeCacheError.invalidSource }
        let entryID = try entryID(for: session)
        try await ensureLength(entryID: entryID, targetOffset: offset)

        while true {
            try Task.checkCancellation()
            guard let entry = entriesByID[entryID],
                  entry.publications[session] != nil,
                  let length = entry.contentLength
            else { throw TrackRangeCacheError.invalidSource }
            if let failure = entry.failure { throw failure }
            if offset >= length { return Data() }

            if let url = entry.fullURL {
                return try publishRead(
                    session: session,
                    entryID: entryID,
                    url: url,
                    offset: offset,
                    count: min(maximumLength, Self.responseChunkSize, Int(length - offset))
                )
            }
            if let coveredUpper = entry.ranges.contiguousUpperBound(from: offset) {
                return try publishRead(
                    session: session,
                    entryID: entryID,
                    url: entry.bodyURL,
                    offset: offset,
                    count: min(
                        maximumLength,
                        Self.responseChunkSize,
                        Int(min(coveredUpper, length) - offset)
                    )
                )
            }
            try await fetchUntilProgress(entryID: entryID, targetOffset: offset)
        }
    }

    func close(_ session: Session) {
        guard let entryID = sessionEntry.removeValue(forKey: session),
              var entry = entriesByID[entryID]
        else { return }
        entry.publications[session] = nil
        entriesByID[entryID] = entry
        guard entry.publications.isEmpty else { return }
        Task { await self.discardUnusedEntry(entryID) }
    }

    func clear() async throws {
        clearDepth += 1
        defer { clearDepth -= 1 }
        currentEntryByKey.removeAll()
        var installTasks: [Task<Void, Never>] = []

        for entryID in Array(entriesByID.keys) {
            guard var entry = entriesByID[entryID] else { continue }
            entry.isRetired = true
            try? FileManager.default.removeItem(at: entry.metadataURL)
            if let install = entry.install {
                if !install.enteredStoreCopy { install.task.cancel() }
                installTasks.append(install.task)
            }
            if entry.publications.isEmpty {
                cancelFlights(in: &entry, error: CancellationError())
                settleSourceFlight(in: &entry, with: .failure(CancellationError()))
            }
            entriesByID[entryID] = entry
        }

        for task in installTasks { await task.value }
        for entryID in Array(entriesByID.keys)
        where entriesByID[entryID]?.publications.isEmpty == true {
            await discardUnusedEntry(entryID)
        }

        let protectedBodies = Set(entriesByID.values.compactMap {
            $0.publications.isEmpty ? nil : $0.bodyURL.standardizedFileURL.path
        })
        let rangeRoot = trackCache.directory.appending(path: "RangeCache", directoryHint: .isDirectory)
        if let enumerator = FileManager.default.enumerator(
            at: rangeRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) {
            let urls = enumerator.compactMap { $0 as? URL }
            for url in urls {
                guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                    continue
                }
                if url.pathExtension == "plist"
                    || (url.pathExtension == "range"
                        && !protectedBodies.contains(url.standardizedFileURL.path)) {
                    try FileManager.default.removeItem(at: url)
                }
            }
        }
    }

    private func entryID(for session: Session) throws -> UUID {
        guard let entryID = sessionEntry[session], entriesByID[entryID] != nil else {
            throw TrackRangeCacheError.invalidSource
        }
        return entryID
    }

    private func ensureLength(entryID: UUID, targetOffset: Int64) async throws {
        guard let entry = entriesByID[entryID] else { throw TrackRangeCacheError.invalidSource }
        if let failure = entry.failure { throw failure }
        if let installError = entry.installError { throw installError }
        if let length = entry.contentLength {
            if entry.fullURL == nil,
               entry.ranges.covers(length: length),
               let install = startInstall(entryID: entryID) {
                await install.value
            }
            if let failure = entriesByID[entryID]?.failure { throw failure }
            if let installError = entriesByID[entryID]?.installError { throw installError }
            return
        }
        try await fetchUntilProgress(entryID: entryID, targetOffset: targetOffset)
        guard let current = entriesByID[entryID], current.contentLength != nil else {
            throw TrackRangeCacheError.rejectedResponse
        }
    }

    private func fetchUntilProgress(entryID: UUID, targetOffset: Int64) async throws {
        var expiryRefreshes = 0
        var rangeRefreshes = 0
        while true {
            do {
                try await fetchOnce(entryID: entryID, targetOffset: targetOffset)
                return
            } catch let ControlError.expired(expiredURL) {
                guard expiryRefreshes == 0 else {
                    invalidateRepresentation(entryID: entryID, error: .sourceExpired)
                    throw TrackRangeCacheError.sourceExpired
                }
                try await refreshSource(entryID: entryID, replacing: expiredURL, allowSameURL: false)
                expiryRefreshes += 1
            } catch let ControlError.unresolvedRange(sourceURL) {
                guard rangeRefreshes == 0 else { throw TrackRangeCacheError.rejectedResponse }
                try await refreshSource(entryID: entryID, replacing: sourceURL, allowSameURL: true)
                rangeRefreshes += 1
            } catch ControlError.localComplete {
                return
            }
        }
    }

    private func fetchOnce(entryID: UUID, targetOffset: Int64) async throws {
        guard let initial = entriesByID[entryID],
              !initial.isRetired || !initial.publications.isEmpty
        else { throw CancellationError() }
        if let failure = initial.failure { throw failure }
        if let length = initial.contentLength, targetOffset >= length { return }
        if initial.ranges.contiguousUpperBound(from: targetOffset) != nil || initial.fullURL != nil {
            return
        }

        let source = try await source(for: entryID)
        try Task.checkCancellation()
        guard let entry = entriesByID[entryID], !entry.isRetired || !entry.publications.isEmpty else {
            throw CancellationError()
        }
        if let failure = entry.failure { throw failure }
        if let length = entry.contentLength, targetOffset >= length { return }
        if entry.ranges.contiguousUpperBound(from: targetOffset) != nil || entry.fullURL != nil { return }

        let blockLower = entry.contentLength == nil
            ? 0
            : targetOffset / Self.networkBlockSize * Self.networkBlockSize
        let flightKey = entry.rangeValidatedURL == source.url
            ? blockLower
            : Self.discoveryFlightKey
        if let existingKey = entry.inFlight.first(where: {
            $0.value.requestedRange.contains(targetOffset)
        })?.key {
            try await waitForRequest(entryID: entryID, blockLower: existingKey)
            return
        }
        if entry.inFlight[flightKey] != nil {
            try await waitForRequest(entryID: entryID, blockLower: flightKey)
            return
        }

        let continuesCoveredRange = targetOffset > 0
            && entry.ranges.contains((targetOffset - 1)..<targetOffset)
        let windowSize = continuesCoveredRange
            ? Self.sequentialNetworkWindowSize
            : Self.networkBlockSize
        let blockUpper = if let length = entry.contentLength {
            blockLower + min(windowSize, length - blockLower)
        } else {
            Self.networkBlockSize
        }
        if continuesCoveredRange,
           let existingKey = entry.inFlight.first(where: {
               $0.value.requestedRange.lowerBound > targetOffset
                   && $0.value.requestedRange.lowerBound < blockUpper
           })?.key {
            try await waitForRequest(entryID: entryID, blockLower: existingKey)
            return
        }
        let requestLower = Self.firstMissing(
            in: entry.ranges,
            from: blockLower,
            through: targetOffset
        )
        let requestUpper = entry.ranges.ranges.first {
            $0.lowerBound > targetOffset && $0.lowerBound < blockUpper
        }?.lowerBound ?? blockUpper
        guard requestLower < requestUpper else { throw TrackRangeCacheError.rejectedResponse }
        let requestRange = requestLower..<requestUpper
        var request = URLRequest(url: source.url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 60
        request.setValue("bytes=\(requestRange.lowerBound)-\(requestRange.upperBound - 1)", forHTTPHeaderField: "Range")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        var sentIfRange = false
        if let etag = entry.etagScope,
           etag.requestURL == etag.effectiveURL,
           etag.requestURL == source.url {
            request.setValue(etag.value, forHTTPHeaderField: "If-Range")
            sentIfRange = true
        }

        let context = RequestContext(
            entryID: entryID,
            epoch: entry.epoch,
            blockLower: flightKey,
            requestedRange: requestRange,
            targetOffset: targetOffset,
            requestURL: source.url,
            sentIfRange: sentIfRange,
            lengthWasKnown: entry.contentLength != nil,
            rangesBefore: entry.ranges
        )
        let requestID = UUID()
        let download = download
        let task = Task<DownloadedResponse, Error> {
            let (temporaryURL, response) = try await download(request)
            guard let response = response as? HTTPURLResponse else {
                try? FileManager.default.removeItem(at: temporaryURL)
                throw TrackRangeCacheError.rejectedResponse
            }
            return DownloadedResponse(temporaryURL: temporaryURL, response: response, context: context)
        }
        var updated = entry
        updated.inFlight[flightKey] = InFlight(
            id: requestID,
            epoch: entry.epoch,
            requestedRange: requestRange,
            task: task
        )
        entriesByID[entryID] = updated
        Task { [task] in
            let result = await task.result
            await self.completeDownload(
                result,
                entryID: entryID,
                blockLower: flightKey,
                requestID: requestID
            )
        }
        try await waitForRequest(entryID: entryID, blockLower: flightKey)
    }

    private func waitForRequest(entryID: UUID, blockLower: Int64) async throws {
        guard let requestID = entriesByID[entryID]?.inFlight[blockLower]?.id else {
            throw CancellationError()
        }
        let waiterID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                guard var entry = entriesByID[entryID],
                      var request = entry.inFlight[blockLower],
                      request.id == requestID
                else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                guard !Task.isCancelled else {
                    if request.waiters.isEmpty {
                        entry.inFlight[blockLower] = nil
                        request.task.cancel()
                        entriesByID[entryID] = entry
                    }
                    continuation.resume(throwing: CancellationError())
                    return
                }
                request.waiters[waiterID] = continuation
                entry.inFlight[blockLower] = request
                entriesByID[entryID] = entry
            }
        } onCancel: {
            Task {
                await self.cancelWaiter(
                    waiterID,
                    entryID: entryID,
                    blockLower: blockLower,
                    requestID: requestID
                )
            }
        }
        try Task.checkCancellation()
    }

    private func cancelWaiter(
        _ waiterID: UUID,
        entryID: UUID,
        blockLower: Int64,
        requestID: UUID
    ) {
        guard var entry = entriesByID[entryID],
              var request = entry.inFlight[blockLower],
              request.id == requestID,
              let continuation = request.waiters.removeValue(forKey: waiterID)
        else { return }
        if request.waiters.isEmpty {
            entry.inFlight[blockLower] = nil
            request.task.cancel()
        } else {
            entry.inFlight[blockLower] = request
        }
        entriesByID[entryID] = entry
        continuation.resume(throwing: CancellationError())
    }

    private func completeDownload(
        _ result: Result<DownloadedResponse, Error>,
        entryID: UUID,
        blockLower: Int64,
        requestID: UUID
    ) async {
        guard let entry = entriesByID[entryID],
              let request = entry.inFlight[blockLower],
              request.id == requestID
        else {
            if case let .success(downloaded) = result {
                try? FileManager.default.removeItem(at: downloaded.temporaryURL)
            }
            return
        }
        if request.isSuperseded {
            if case let .success(downloaded) = result {
                try? FileManager.default.removeItem(at: downloaded.temporaryURL)
            }
            return
        }

        let settled: Result<Void, Error>
        switch result {
        case let .failure(error):
            settled = .failure(error)
        case let .success(downloaded):
            defer { try? FileManager.default.removeItem(at: downloaded.temporaryURL) }
            guard downloaded.context.epoch == entry.epoch else {
                settled = .failure(TrackRangeCacheError.inconsistentRepresentation)
                break
            }
            do {
                try await process(downloaded)
                settled = .success(())
            } catch {
                settled = .failure(error)
            }
        }
        settleDownload(
            entryID: entryID,
            blockLower: blockLower,
            requestID: requestID,
            with: settled
        )
    }

    private func process(_ downloaded: DownloadedResponse) async throws {
        let response = downloaded.response
        let context = downloaded.context
        guard let effectiveURL = response.url,
              Self.isValidHTTPURL(effectiveURL),
              Self.redirectIsAllowed(from: context.requestURL, to: effectiveURL)
        else { throw TrackRangeCacheError.rejectedResponse }

        switch response.statusCode {
        case 206:
            try await processPartial(downloaded, effectiveURL: effectiveURL)
        case 200:
            try await processComplete(downloaded, effectiveURL: effectiveURL)
        case 416:
            try processUnsatisfied(downloaded)
        case 401, 403, 404, 410:
            throw ControlError.expired(context.requestURL)
        default:
            throw TrackRangeCacheError.rejectedResponse
        }
    }

    private func processPartial(_ downloaded: DownloadedResponse, effectiveURL: URL) async throws {
        let response = downloaded.response
        let context = downloaded.context
        try Self.validatePayloadHeaders(response)
        guard let header = response.value(forHTTPHeaderField: "Content-Range"),
              case let .bytes(responseRange, completeLength) = HTTPContentRange(header),
              responseRange.contains(context.requestedRange.lowerBound),
              Self.fileSize(at: downloaded.temporaryURL) == Int64(responseRange.count)
        else { throw TrackRangeCacheError.rejectedResponse }

        guard var entry = entriesByID[context.entryID], entry.epoch == context.epoch else {
            throw TrackRangeCacheError.inconsistentRepresentation
        }
        if let known = entry.contentLength, known != completeLength {
            invalidateRepresentation(entryID: entry.id)
            throw TrackRangeCacheError.inconsistentRepresentation
        }
        if let representation = entry.representation, representation.contentLength != completeLength {
            invalidateRepresentation(entryID: entry.id)
            throw TrackRangeCacheError.inconsistentRepresentation
        }

        let strongETag = Self.strongETag(response.value(forHTTPHeaderField: "ETag"))
        if entry.isTransient {
            guard context.requestURL == effectiveURL else {
                invalidateRepresentation(entryID: entry.id, error: .unverifiableRepresentation)
                throw TrackRangeCacheError.unverifiableRepresentation
            }
            if let transientURL = entry.transientURL,
               transientURL != context.requestURL {
                invalidateRepresentation(entryID: entry.id)
                throw TrackRangeCacheError.inconsistentRepresentation
            }
            if let previous = entry.etagScope?.value {
                if let strongETag, previous != strongETag {
                    invalidateRepresentation(entryID: entry.id)
                    throw TrackRangeCacheError.inconsistentRepresentation
                }
                guard strongETag != nil || context.sentIfRange else {
                    invalidateRepresentation(entryID: entry.id, error: .unverifiableRepresentation)
                    throw TrackRangeCacheError.unverifiableRepresentation
                }
            } else {
                guard strongETag != nil else {
                    invalidateRepresentation(entryID: entry.id, error: .unverifiableRepresentation)
                    throw TrackRangeCacheError.unverifiableRepresentation
                }
            }
            entry.transientURL = context.requestURL
            if let value = strongETag ?? entry.etagScope?.value {
                entry.etagScope = ETagScope(
                    requestURL: context.requestURL,
                    effectiveURL: effectiveURL,
                    value: value
                )
            }
        } else {
            if entry.source?.url == context.requestURL {
                if let previous = entry.etagScope,
                   previous.requestURL == context.requestURL,
                   previous.effectiveURL == effectiveURL,
                   let strongETag,
                   strongETag != previous.value {
                    invalidateRepresentation(entryID: entry.id)
                    throw TrackRangeCacheError.inconsistentRepresentation
                }
                if let strongETag {
                    entry.etagScope = ETagScope(
                        requestURL: context.requestURL,
                        effectiveURL: effectiveURL,
                        value: strongETag
                    )
                } else if !(context.sentIfRange && context.requestURL == effectiveURL) {
                    entry.etagScope = nil
                }
            }
        }

        try Self.write(
            downloaded.temporaryURL,
            to: entry.bodyURL,
            at: responseRange.lowerBound,
            expectedCount: Int64(responseRange.count)
        )
        entry.contentLength = completeLength
        entry.mimeType = Self.mimeType(response) ?? entry.mimeType
        if entry.source?.url == context.requestURL {
            entry.rangeValidatedURL = context.requestURL
        }
        entry.ranges.insert(responseRange)
        let previousUpper = context.rangesBefore.contiguousUpperBound(
            from: context.requestedRange.lowerBound
        ) ?? context.requestedRange.lowerBound
        let currentUpper = entry.ranges.contiguousUpperBound(
            from: context.requestedRange.lowerBound
        ) ?? context.requestedRange.lowerBound
        guard currentUpper > previousUpper else {
            throw TrackRangeCacheError.rejectedResponse
        }
        if entry.ranges.covers(length: completeLength) {
            supersedeFlights(in: &entry, excluding: context.blockLower)
            supersedeSourceFlight(in: &entry)
        }
        entriesByID[entry.id] = entry

        do {
            if !entry.isTransient && !entry.isRetired {
                try persist(entry)
            }
            if !entry.isRetired { await trackCache.recordPartialFileAccess(entry.bodyURL) }
            guard let current = entriesByID[entry.id], current.epoch == entry.epoch else {
                throw TrackRangeCacheError.inconsistentRepresentation
            }
            if current.ranges.covers(length: completeLength) {
                if let install = startInstall(entryID: entry.id) { await install.value }
                if let failure = entriesByID[entry.id]?.failure { throw failure }
                if let installError = entriesByID[entry.id]?.installError { throw installError }
            }
            settleSupersededFlights(entryID: entry.id, with: .success(()))
            settleSupersededSourceFlight(entryID: entry.id, error: ControlError.localComplete)
        } catch {
            settleSupersededFlights(entryID: entry.id, with: .failure(error))
            settleSupersededSourceFlight(entryID: entry.id, error: error)
            throw error
        }
    }

    private func processComplete(_ downloaded: DownloadedResponse, effectiveURL: URL) async throws {
        let response = downloaded.response
        let context = downloaded.context
        try Self.validatePayloadHeaders(response)
        guard let explicitLength = Self.explicitContentLength(response),
              explicitLength > 0,
              Self.fileSize(at: downloaded.temporaryURL) == explicitLength
        else { throw TrackRangeCacheError.rejectedResponse }
        guard var entry = entriesByID[context.entryID], entry.epoch == context.epoch else {
            throw TrackRangeCacheError.inconsistentRepresentation
        }
        _ = effectiveURL

        if entry.isRetired, entry.representation == nil {
            entry.epoch &+= 1
            entry.failure = .inconsistentRepresentation
            settleFlights(in: &entry, with: .failure(TrackRangeCacheError.inconsistentRepresentation))
            entriesByID[entry.id] = entry
            throw TrackRangeCacheError.inconsistentRepresentation
        }
        if let representation = entry.representation {
            guard explicitLength == representation.contentLength,
                  try Self.digest(of: downloaded.temporaryURL).md5 == representation.contentMD5
            else {
                invalidateRepresentation(entryID: entry.id)
                throw TrackRangeCacheError.inconsistentRepresentation
            }
        }

        let conflictsWithPublishedSession = entry.representation == nil
            && entry.publications.values.contains(where: \.hasPublished)
        let transientMD5 = entry.representation == nil
            ? try Self.digest(of: downloaded.temporaryURL).md5
            : nil
        try Self.replaceBody(
            at: entry.bodyURL,
            with: downloaded.temporaryURL,
            removing: entry.metadataURL
        )

        entry.contentLength = explicitLength
        entry.mimeType = Self.mimeType(response) ?? entry.mimeType
        entry.ranges = StreamingByteRangeSet([
            StoredByteRange(lowerBound: 0, upperBound: explicitLength)
        ])
        entry.transientMD5 = transientMD5
        entry.epoch &+= 1
        supersedeFlights(in: &entry, excluding: context.blockLower)
        supersedeSourceFlight(in: &entry)
        if conflictsWithPublishedSession {
            entry.installForFutureOnly = true
            entry.failure = .inconsistentRepresentation
            if currentEntryByKey[entry.key] == entry.id { currentEntryByKey[entry.key] = nil }
        }
        entriesByID[entry.id] = entry

        do {
            if entry.isRetired {
                if let failure = entry.failure { throw failure }
            } else {
                if let install = startInstall(entryID: entry.id) { await install.value }
                if let failure = entriesByID[entry.id]?.failure { throw failure }
                if let installError = entriesByID[entry.id]?.installError { throw installError }
            }
            settleSupersededFlights(entryID: entry.id, with: .success(()))
            settleSupersededSourceFlight(entryID: entry.id, error: ControlError.localComplete)
        } catch {
            settleSupersededFlights(entryID: entry.id, with: .failure(error))
            settleSupersededSourceFlight(entryID: entry.id, error: error)
            throw error
        }
    }

    private func processUnsatisfied(_ downloaded: DownloadedResponse) throws {
        let context = downloaded.context
        guard let value = downloaded.response.value(forHTTPHeaderField: "Content-Range"),
              case let .unsatisfied(completeLength) = HTTPContentRange(value),
              var entry = entriesByID[context.entryID],
              entry.epoch == context.epoch
        else { throw TrackRangeCacheError.rejectedResponse }

        if let known = entry.contentLength, known != completeLength {
            invalidateRepresentation(entryID: entry.id)
            throw TrackRangeCacheError.inconsistentRepresentation
        }
        if context.targetOffset >= completeLength {
            entry.contentLength = completeLength
            entriesByID[entry.id] = entry
            return
        }
        guard !context.lengthWasKnown,
              !entry.publications.values.contains(where: \.hasPublished)
        else {
            invalidateRepresentation(entryID: entry.id)
            throw TrackRangeCacheError.inconsistentRepresentation
        }
        throw ControlError.unresolvedRange(context.requestURL)
    }

    private func source(for entryID: UUID) async throws -> PlaybackSource {
        guard let entry = entriesByID[entryID] else { throw TrackRangeCacheError.invalidSource }
        if let failure = entry.failure { throw failure }
        if let source = entry.source { return source }
        guard let provider = entry.sourceProvider else { throw TrackRangeCacheError.invalidSource }

        let flightID: UUID
        if let existing = entry.sourceFlight {
            flightID = existing.id
        } else {
            let key = entry.key
            let createdID = UUID()
            let created = SourceFlight(id: createdID, task: Task {
                let source = try await provider()
                try Self.validate(source, for: key)
                return source
            })
            var updated = entry
            updated.sourceFlight = created
            entriesByID[entryID] = updated
            flightID = createdID
            Task { [task = created.task, flightID = createdID] in
                self.completeSource(
                    await task.result,
                    entryID: entryID,
                    flightID: flightID
                )
            }
        }
        let waiterID = UUID()
        let source = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<PlaybackSource, Error>) in
                guard var current = entriesByID[entryID],
                      var flight = current.sourceFlight,
                      flight.id == flightID
                else {
                    if let current = entriesByID[entryID], let source = current.source {
                        continuation.resume(returning: source)
                    } else {
                        continuation.resume(throwing: CancellationError())
                    }
                    return
                }
                guard !Task.isCancelled else {
                    if flight.waiters.isEmpty {
                        current.sourceFlight = nil
                        flight.task.cancel()
                        entriesByID[entryID] = current
                    }
                    continuation.resume(throwing: CancellationError())
                    return
                }
                flight.waiters[waiterID] = continuation
                current.sourceFlight = flight
                entriesByID[entryID] = current
            }
        } onCancel: {
            Task { await self.cancelSourceWaiter(waiterID, entryID: entryID, flightID: flightID) }
        }
        try Task.checkCancellation()
        return source
    }

    private func completeSource(
        _ result: Result<PlaybackSource, Error>,
        entryID: UUID,
        flightID: UUID
    ) {
        guard var entry = entriesByID[entryID],
              let flight = entry.sourceFlight,
              flight.id == flightID
        else { return }
        if flight.isSuperseded { return }
        entry.sourceFlight = nil
        entriesByID[entryID] = entry
        let settled: Result<PlaybackSource, Error>
        switch result {
        case let .success(source):
            do {
                try reconcile(source, with: &entry)
                entry.source = source
                entriesByID[entryID] = entry
                settled = .success(source)
            } catch {
                settled = .failure(error)
            }
        case let .failure(error):
            entriesByID[entryID] = entry
            settled = .failure(error)
        }
        flight.waiters.values.forEach { $0.resume(with: settled) }
    }

    private func cancelSourceWaiter(_ waiterID: UUID, entryID: UUID, flightID: UUID) {
        guard var entry = entriesByID[entryID],
              var flight = entry.sourceFlight,
              flight.id == flightID,
              let continuation = flight.waiters.removeValue(forKey: waiterID)
        else { return }
        if flight.waiters.isEmpty {
            entry.sourceFlight = nil
            flight.task.cancel()
        } else {
            entry.sourceFlight = flight
        }
        entriesByID[entryID] = entry
        continuation.resume(throwing: CancellationError())
    }

    private func refreshSource(
        entryID: UUID,
        replacing expiredURL: URL,
        allowSameURL: Bool
    ) async throws {
        guard var entry = entriesByID[entryID] else { throw TrackRangeCacheError.invalidSource }
        if let current = entry.source, current.url != expiredURL { return }
        if entry.isTransient, !allowSameURL {
            invalidateRepresentation(entryID: entryID)
            throw TrackRangeCacheError.inconsistentRepresentation
        }
        entry.source = nil
        entry.rangeValidatedURL = nil
        entry.etagScope = nil
        entriesByID[entryID] = entry
        do {
            let refreshed = try await source(for: entryID)
            if !allowSameURL, refreshed.url == expiredURL {
                invalidateRepresentation(entryID: entryID, error: .sourceExpired)
                throw TrackRangeCacheError.sourceExpired
            }
        } catch ControlError.localComplete {
            return
        } catch let error as TrackRangeCacheError {
            if error == .sourceExpired { throw error }
            if case .sourceLevelMismatch = error {
                invalidateRepresentation(entryID: entryID, error: error)
            }
            throw error
        }
    }

    private func reconcile(_ source: PlaybackSource, with entry: inout Entry) throws {
        if let expected = entry.representation {
            guard source.representation == expected else {
                invalidateRepresentation(entryID: entry.id)
                throw TrackRangeCacheError.inconsistentRepresentation
            }
        } else if let representation = source.representation {
            guard entry.ranges.ranges.isEmpty else {
                invalidateRepresentation(entryID: entry.id)
                throw TrackRangeCacheError.inconsistentRepresentation
            }
            entry.representation = representation
            entry.contentLength = representation.contentLength
            entry.isTransient = false
            if !entry.isRetired { currentEntryByKey[entry.key] = entry.id }
        }
        if let oldURL = entry.source?.url, oldURL != source.url {
            if entry.isTransient {
                invalidateRepresentation(entryID: entry.id)
                throw TrackRangeCacheError.inconsistentRepresentation
            }
            entry.rangeValidatedURL = nil
            entry.etagScope = nil
        }
    }

    private func publishRead(
        session: Session,
        entryID: UUID,
        url: URL,
        offset: Int64,
        count: Int
    ) throws -> Data {
        guard count > 0 else { return Data() }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(offset))
        guard let data = try handle.read(upToCount: count), data.count == count else {
            throw CocoaError(.fileReadCorruptFile)
        }
        guard var entry = entriesByID[entryID],
              var publication = entry.publications[session]
        else { throw TrackRangeCacheError.invalidSource }
        publication.data = true
        entry.publications[session] = publication
        entriesByID[entryID] = entry
        return data
    }

    @discardableResult
    private func startInstall(entryID: UUID) -> Task<Void, Never>? {
        guard var entry = entriesByID[entryID] else { return nil }
        guard entry.install == nil,
              !entry.installAttempted,
              !entry.isRetired,
              let length = entry.contentLength,
              entry.ranges.covers(length: length)
        else { return entry.install?.task }
        let id = UUID()
        let epoch = entry.epoch
        let task = Task<Void, Never> {
            await self.performInstall(entryID: entryID, epoch: epoch, installID: id)
            await self.finishInstall(entryID: entryID, installID: id)
        }
        entry.installAttempted = true
        entry.install = Install(id: id, task: task)
        entriesByID[entryID] = entry
        return task
    }

    private func performInstall(entryID: UUID, epoch: UInt64, installID: UUID) async {
        do {
            guard var entry = entriesByID[entryID],
                  entry.epoch == epoch,
                  entry.install?.id == installID,
                  !entry.isRetired,
                  let length = entry.contentLength
            else { return }
            let localDigest = try Self.digest(of: entry.bodyURL)
            guard localDigest.length == length else {
                invalidateRepresentation(entryID: entryID)
                return
            }
            if let representation = entry.representation {
                guard localDigest.md5 == representation.contentMD5 else {
                    invalidateRepresentation(entryID: entryID)
                    return
                }
            } else {
                entry.transientMD5 = localDigest.md5
                entriesByID[entryID] = entry
            }

            try Task.checkCancellation()
            guard var beforeStore = entriesByID[entryID],
                  beforeStore.epoch == epoch,
                  var install = beforeStore.install,
                  install.id == installID,
                  !beforeStore.isRetired
            else { return }
            install.enteredStoreCopy = true
            beforeStore.install = install
            entriesByID[entryID] = beforeStore

            let cached = try await trackCache.storeCopy(
                of: beforeStore.bodyURL,
                for: beforeStore.key.songID,
                quality: beforeStore.key.quality,
                fileExtension: beforeStore.format
            )
            guard var afterStore = entriesByID[entryID],
                  afterStore.epoch == epoch,
                  afterStore.install?.id == installID
            else { return }
            if afterStore.isRetired {
                return
            }

            let cachedDigest = try Self.digest(of: cached.url)
            let expectedMD5 = afterStore.representation?.contentMD5 ?? localDigest.md5
            guard cached.size == length,
                  cachedDigest.length == length,
                  cachedDigest.md5 == expectedMD5
            else {
                if currentEntryByKey[afterStore.key] == entryID {
                    currentEntryByKey[afterStore.key] = nil
                }
                try? FileManager.default.removeItem(at: afterStore.metadataURL)
                afterStore.isRetired = true
                entriesByID[entryID] = afterStore
                return
            }

            guard await trackCache.pin(cached.url) else {
                throw CocoaError(.fileNoSuchFile)
            }
            let pinnedDigest: (length: Int64, md5: String)
            do {
                await afterPinForTesting?(cached.url)
                try Task.checkCancellation()
                pinnedDigest = try Self.digest(of: cached.url)
            } catch {
                await trackCache.unpin(cached.url)
                throw error
            }
            guard pinnedDigest.length == length, pinnedDigest.md5 == expectedMD5 else {
                await trackCache.unpin(cached.url)
                guard var current = entriesByID[entryID], current.install?.id == installID else {
                    return
                }
                if currentEntryByKey[current.key] == entryID { currentEntryByKey[current.key] = nil }
                try? FileManager.default.removeItem(at: current.metadataURL)
                current.isRetired = true
                entriesByID[entryID] = current
                return
            }
            guard var installed = entriesByID[entryID],
                  installed.epoch == epoch,
                  !installed.isRetired,
                  installed.install?.id == installID
            else {
                await trackCache.unpin(cached.url)
                return
            }
            installed.fullURL = cached.url
            installed.fullPinned = true
            installed.failure = installed.installForFutureOnly ? .inconsistentRepresentation : nil
            try? FileManager.default.removeItem(at: installed.metadataURL)
            let bodyToUnpin = installed.bodyPinned ? installed.bodyURL : nil
            installed.bodyPinned = false
            entriesByID[entryID] = installed
            if let bodyToUnpin {
                await trackCache.unpin(bodyToUnpin)
            }
            try? FileManager.default.removeItem(at: installed.bodyURL)
        } catch {
            guard var entry = entriesByID[entryID],
                  entry.epoch == epoch,
                  entry.install?.id == installID,
                  !entry.isRetired,
                  entry.failure == nil
            else { return }
            entry.installError = error
            entry.isRetired = true
            if currentEntryByKey[entry.key] == entryID { currentEntryByKey[entry.key] = nil }
            try? FileManager.default.removeItem(at: entry.metadataURL)
            entriesByID[entryID] = entry
        }
    }

    private func finishInstall(entryID: UUID, installID: UUID) async {
        if var entry = entriesByID[entryID], entry.install?.id == installID {
            entry.install = nil
            entriesByID[entryID] = entry
        }
        if entriesByID[entryID]?.publications.isEmpty == true {
            await discardUnusedEntry(entryID)
        }
    }

    private func retireInstalledEntryForReplacement(entryID: UUID) {
        guard var entry = entriesByID[entryID], entry.fullURL != nil else { return }
        if currentEntryByKey[entry.key] == entryID { currentEntryByKey[entry.key] = nil }
        try? FileManager.default.removeItem(at: entry.metadataURL)
        entry.epoch &+= 1
        entry.isRetired = true
        settleSourceFlight(in: &entry, with: .failure(ControlError.localComplete))
        settleFlights(in: &entry, with: .success(()))
        entriesByID[entryID] = entry
        if entry.publications.isEmpty {
            Task { await self.discardUnusedEntry(entryID) }
        }
    }

    private func invalidateRepresentation(
        entryID: UUID,
        error: TrackRangeCacheError = .inconsistentRepresentation
    ) {
        guard var entry = entriesByID[entryID] else { return }
        if currentEntryByKey[entry.key] == entryID {
            currentEntryByKey[entry.key] = nil
        }
        try? FileManager.default.removeItem(at: entry.metadataURL)
        entry.epoch &+= 1
        entry.isRetired = true
        entry.failure = error
        settleSourceFlight(in: &entry, with: .failure(error))
        cancelFlights(in: &entry, error: error)
        entry.install?.task.cancel()
        entriesByID[entryID] = entry
        if entry.publications.isEmpty {
            Task { await self.discardUnusedEntry(entryID) }
        }
    }

    private func cancelFlights(in entry: inout Entry, error: Error) {
        settleFlights(in: &entry, with: .failure(error))
    }

    private func settleFlights(in entry: inout Entry, with result: Result<Void, Error>) {
        for request in entry.inFlight.values {
            request.task.cancel()
            request.waiters.values.forEach { $0.resume(with: result) }
        }
        entry.inFlight.removeAll()
    }

    private func takeSourceWaiters(
        in entry: inout Entry
    ) -> [CheckedContinuation<PlaybackSource, Error>] {
        guard let flight = entry.sourceFlight else { return [] }
        flight.task.cancel()
        entry.sourceFlight = nil
        return Array(flight.waiters.values)
    }

    private func settleSourceFlight(
        in entry: inout Entry,
        with result: Result<PlaybackSource, Error>
    ) {
        takeSourceWaiters(in: &entry).forEach { $0.resume(with: result) }
    }

    private func supersedeSourceFlight(in entry: inout Entry) {
        guard var flight = entry.sourceFlight else { return }
        flight.isSuperseded = true
        flight.task.cancel()
        entry.sourceFlight = flight
    }

    private func settleSupersededSourceFlight(entryID: UUID, error: Error) {
        guard var entry = entriesByID[entryID],
              let flight = entry.sourceFlight,
              flight.isSuperseded
        else { return }
        entry.sourceFlight = nil
        entriesByID[entryID] = entry
        flight.waiters.values.forEach { $0.resume(throwing: error) }
    }

    private func settleDownload(
        entryID: UUID,
        blockLower: Int64,
        requestID: UUID,
        with result: Result<Void, Error>
    ) {
        guard var entry = entriesByID[entryID],
              let request = entry.inFlight[blockLower],
              request.id == requestID
        else { return }
        entry.inFlight[blockLower] = nil
        entriesByID[entryID] = entry
        request.waiters.values.forEach { $0.resume(with: result) }
    }

    private func supersedeFlights(
        in entry: inout Entry,
        excluding blockLower: Int64
    ) {
        for flightKey in Array(entry.inFlight.keys) where flightKey != blockLower {
            guard var flight = entry.inFlight[flightKey] else { continue }
            flight.isSuperseded = true
            flight.task.cancel()
            entry.inFlight[flightKey] = flight
        }
    }

    private func settleSupersededFlights(entryID: UUID, with result: Result<Void, Error>) {
        guard var entry = entriesByID[entryID] else { return }
        let flightKeys = entry.inFlight.compactMap { $0.value.isSuperseded ? $0.key : nil }
        let flights = flightKeys.compactMap { entry.inFlight.removeValue(forKey: $0) }
        entriesByID[entryID] = entry
        flights.flatMap { $0.waiters.values }.forEach { $0.resume(with: result) }
    }

    private func discardUnusedEntry(_ entryID: UUID) async {
        guard var entry = entriesByID[entryID], entry.publications.isEmpty else { return }
        cancelFlights(in: &entry, error: CancellationError())
        settleSourceFlight(in: &entry, with: .failure(CancellationError()))
        if let install = entry.install {
            if !install.enteredStoreCopy { install.task.cancel() }
            entriesByID[entryID] = entry
            await install.task.value
            guard let refreshed = entriesByID[entryID], refreshed.publications.isEmpty else { return }
            entry = refreshed
        }
        if !entry.isRetired,
           !entry.isTransient,
           entry.fullURL == nil,
           entry.failure == nil,
           FileManager.default.fileExists(atPath: entry.metadataURL.path) {
            entriesByID[entryID] = nil
            if currentEntryByKey[entry.key] == entryID { currentEntryByKey[entry.key] = nil }
            if entry.bodyPinned { await trackCache.unpin(entry.bodyURL) }
            return
        }
        entriesByID[entryID] = nil
        if currentEntryByKey[entry.key] == entryID { currentEntryByKey[entry.key] = nil }
        sessionEntry = sessionEntry.filter { $0.value != entryID }
        try? FileManager.default.removeItem(at: entry.metadataURL)
        if entry.bodyPinned { await trackCache.unpin(entry.bodyURL) }
        if entry.fullPinned, let fullURL = entry.fullURL { await trackCache.unpin(fullURL) }
        try? FileManager.default.removeItem(at: entry.bodyURL)
    }

    private func persist(_ entry: Entry) throws {
        guard let representation = entry.representation,
              let contentLength = entry.contentLength,
              !entry.isTransient,
              !entry.isRetired
        else { return }
        let metadata = RangeCacheMetadata(
            schemaVersion: 1,
            entryID: entry.id,
            songID: entry.key.songID,
            quality: entry.key.quality,
            format: entry.format,
            mimeType: entry.mimeType,
            contentLength: contentLength,
            contentMD5: representation.contentMD5,
            coveredRanges: entry.ranges.storedRanges
        )
        try PropertyListEncoder().encode(metadata).write(to: entry.metadataURL, options: .atomic)
    }

    private func loadEntry(metadataURL: URL, expectedKey: TrackRangeCacheKey) -> Entry? {
        guard let data = try? Data(contentsOf: metadataURL),
              let metadata = try? PropertyListDecoder().decode(RangeCacheMetadata.self, from: data),
              metadata.schemaVersion == 1,
              metadata.songID == expectedKey.songID,
              metadata.quality == expectedKey.quality,
              Self.isValid(format: metadata.format),
              let representation = PlaybackRepresentation(
                contentLength: metadata.contentLength,
                contentMD5: metadata.contentMD5
              ),
              representation.contentMD5 == metadata.contentMD5,
              metadataURL.lastPathComponent == "\(metadata.songID)-\(metadata.entryID.uuidString).range.metadata.plist"
        else { return nil }
        let bodyURL = metadataURL.deletingPathExtension().deletingPathExtension()
        guard bodyURL.deletingLastPathComponent().lastPathComponent == expectedKey.quality,
              let values = try? bodyURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true,
              let size = values.fileSize,
              size <= metadata.contentLength
        else { return nil }

        let ranges = StreamingByteRangeSet(metadata.coveredRanges)
        guard ranges.storedRanges == metadata.coveredRanges,
              metadata.coveredRanges.allSatisfy({
                  $0.lowerBound >= 0
                      && $0.lowerBound < $0.upperBound
                      && $0.upperBound <= metadata.contentLength
              }),
              Int64(size) >= (metadata.coveredRanges.map(\.upperBound).max() ?? 0),
              Self.canReadBoundaries(metadata.coveredRanges, from: bodyURL)
        else { return nil }

        return Entry(
            id: metadata.entryID,
            key: expectedKey,
            bodyURL: bodyURL,
            metadataURL: metadataURL,
            format: metadata.format,
            mimeType: metadata.mimeType,
            contentLength: metadata.contentLength,
            representation: representation,
            ranges: ranges,
            isTransient: false
        )
    }

    private func removeDamagedEntry(metadataURL: URL) {
        let bodyURL = metadataURL.deletingPathExtension().deletingPathExtension()
        try? FileManager.default.removeItem(at: metadataURL)
        if let entryID = entriesByID.first(where: {
            $0.value.bodyURL == bodyURL && $0.value.bodyPinned
        })?.key,
           var entry = entriesByID[entryID] {
            entry.isRetired = true
            if let install = entry.install, !install.enteredStoreCopy { install.task.cancel() }
            entriesByID[entryID] = entry
            if currentEntryByKey[entry.key] == entryID { currentEntryByKey[entry.key] = nil }
            return
        }
        try? FileManager.default.removeItem(at: bodyURL)
    }

    private nonisolated static func isValid(_ key: TrackRangeCacheKey) -> Bool {
        key.songID > 0 && SongQualityDetail.orderedLevels.contains(key.quality)
    }

    private nonisolated static func isValid(format: String) -> Bool {
        supportedFormats.contains(format)
            && !format.contains("/")
            && !format.contains(".")
    }

    private nonisolated static func validate(
        _ source: PlaybackSource,
        for key: TrackRangeCacheKey
    ) throws {
        guard isValidHTTPURL(source.url) else { throw TrackRangeCacheError.invalidSource }
        guard case let .playable(level) = source.availability, level == key.quality else {
            throw TrackRangeCacheError.sourceLevelMismatch(
                expected: key.quality,
                actual: source.availability.level
            )
        }
    }

    private nonisolated static func isValidHTTPURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host != nil,
              url.user == nil,
              url.password == nil
        else { return false }
        return true
    }

    private nonisolated static func firstMissing(
        in ranges: StreamingByteRangeSet,
        from lowerBound: Int64,
        through target: Int64
    ) -> Int64 {
        var cursor = lowerBound
        while cursor <= target, let upper = ranges.contiguousUpperBound(from: cursor) {
            cursor = upper
        }
        return cursor
    }

    private nonisolated static func validatePayloadHeaders(_ response: HTTPURLResponse) throws {
        if let encoding = response.value(forHTTPHeaderField: "Content-Encoding")?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !encoding.isEmpty,
           encoding.caseInsensitiveCompare("identity") != .orderedSame {
            throw TrackRangeCacheError.rejectedResponse
        }
        if let mimeType = mimeType(response),
           mimeType == "text/html"
            || mimeType == "application/xhtml+xml"
            || mimeType == "application/json"
            || mimeType == "text/json"
            || mimeType.hasSuffix("+json") {
            throw TrackRangeCacheError.rejectedResponse
        }
    }

    private nonisolated static func mimeType(_ response: HTTPURLResponse) -> String? {
        let raw = response.value(forHTTPHeaderField: "Content-Type") ?? response.mimeType
        guard let value = raw?.split(separator: ";", maxSplits: 1).first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
              !value.isEmpty
        else { return nil }
        return value
    }

    private nonisolated static func explicitContentLength(_ response: HTTPURLResponse) -> Int64? {
        guard let value = response.value(forHTTPHeaderField: "Content-Length")?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty,
              value.utf8.allSatisfy({ (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) })
        else { return nil }
        return Int64(value)
    }

    private nonisolated static func strongETag(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty,
              !value.lowercased().hasPrefix("w/"),
              value.first == "\"",
              value.last == "\"",
              value.count >= 2,
              !value.dropFirst().dropLast().contains("\""),
              value.dropFirst().dropLast().unicodeScalars.allSatisfy({
                  $0.value == 0x21
                      || (0x23...0x7e).contains($0.value)
                      || (0x80...0xff).contains($0.value)
              })
        else { return nil }
        return value
    }

    private nonisolated static func redirectIsAllowed(from requestURL: URL, to responseURL: URL) -> Bool {
        sameOrigin(requestURL, responseURL)
            || (PlaybackSourceURLPolicy.isAllowedRemote(requestURL)
                && PlaybackSourceURLPolicy.isAllowedRemote(responseURL))
    }

    private nonisolated static func sameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.scheme?.lowercased() == rhs.scheme?.lowercased()
            && lhs.host?.lowercased() == rhs.host?.lowercased()
            && normalizedPort(lhs) == normalizedPort(rhs)
    }

    private nonisolated static func normalizedPort(_ url: URL) -> Int? {
        if let port = url.port { return port }
        switch url.scheme?.lowercased() {
        case "http": return 80
        case "https": return 443
        default: return nil
        }
    }

    private nonisolated static func fileSize(at url: URL) -> Int64? {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return nil }
        return Int64(size)
    }

    private nonisolated static func write(
        _ source: URL,
        to destination: URL,
        at offset: Int64,
        expectedCount: Int64
    ) throws {
        let reader = try FileHandle(forReadingFrom: source)
        let writer = try FileHandle(forWritingTo: destination)
        defer {
            try? reader.close()
            try? writer.close()
        }
        try writer.seek(toOffset: UInt64(offset))
        var written: Int64 = 0
        while let data = try reader.read(upToCount: responseChunkSize), !data.isEmpty {
            try writer.write(contentsOf: data)
            written += Int64(data.count)
        }
        guard written == expectedCount else { throw TrackRangeCacheError.rejectedResponse }
        try writer.synchronize()
    }

    private nonisolated static func replaceBody(
        at destination: URL,
        with source: URL,
        removing metadataURL: URL
    ) throws {
        let fileManager = FileManager.default
        let staged = destination.appendingPathExtension("\(UUID().uuidString).complete-part")
        defer { try? fileManager.removeItem(at: staged) }
        try fileManager.copyItem(at: source, to: staged)
        let handle = try FileHandle(forWritingTo: staged)
        do {
            try handle.synchronize()
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }
        if fileManager.fileExists(atPath: metadataURL.path) {
            try fileManager.removeItem(at: metadataURL)
        }
        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: staged)
        } else {
            try fileManager.moveItem(at: staged, to: destination)
        }
    }

    private nonisolated static func digest(of url: URL) throws -> (length: Int64, md5: String) {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = Insecure.MD5()
        var length: Int64 = 0
        while let data = try handle.read(upToCount: responseChunkSize), !data.isEmpty {
            hasher.update(data: data)
            length += Int64(data.count)
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return (length, digest)
    }

    private nonisolated static func canReadBoundaries(
        _ ranges: [StoredByteRange],
        from url: URL
    ) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        for range in ranges {
            do {
                try handle.seek(toOffset: UInt64(range.lowerBound))
                guard try handle.read(upToCount: 1)?.count == 1 else { return false }
                try handle.seek(toOffset: UInt64(range.upperBound - 1))
                guard try handle.read(upToCount: 1)?.count == 1 else { return false }
            } catch {
                return false
            }
        }
        return true
    }

    private nonisolated func rangeDirectory(for quality: String) -> URL {
        trackCache.directory
            .appending(path: "RangeCache", directoryHint: .isDirectory)
            .appending(path: quality, directoryHint: .isDirectory)
    }

    private nonisolated func bodyURL(for key: TrackRangeCacheKey, entryID: UUID) -> URL {
        rangeDirectory(for: key.quality)
            .appending(path: "\(key.songID)-\(entryID.uuidString).range", directoryHint: .notDirectory)
    }

    private nonisolated static func metadataURL(for bodyURL: URL) -> URL {
        bodyURL.appendingPathExtension("metadata.plist")
    }
}
