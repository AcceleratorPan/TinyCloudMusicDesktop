import CoreGraphics
import Foundation
import ImageIO

actor MusicSheetWorker {
    static let shared = MusicSheetWorker()

    static let maximumPDFBytes = 50 * 1_024 * 1_024
    static let maximumImageBytes = 25 * 1_024 * 1_024
    static let maximumDocumentBytes = 100 * 1_024 * 1_024
    static let maximumPageCount = 100
    static let maximumDecodedPixels = maximumDocumentBytes / 4
    // 100 A4 pages at 300 dpi are 869,984,000 pixels; keep modest dimension headroom.
    static let maximumCumulativeDecodedPixels = 900_000_000

    private struct JobKey: Hashable {
        let rootPath: String
        let sheetID: Int64
    }

    private struct Job {
        let id: UUID
        let task: Task<URL, Error>
        var waiters: [UUID: CheckedContinuation<URL, any Error>]
        var cancelledWaiters: Set<UUID>
    }

    private let temporaryRoot: URL
    private let sessionConfiguration: URLSessionConfiguration
    private let maximumCumulativePixels: Int
    private let heavyWorkStarted: (@Sendable () -> Void)?
    private let imageDecodeStarted: (@Sendable () -> Void)?
    private var jobs: [JobKey: Job] = [:]
    private var rootGenerations: [String: UInt64] = [:]
    private var clearingRoots = Set<String>()
    private var clearTasks: [String: Task<Void, Error>] = [:]

    init(
        temporaryRoot: URL? = nil,
        sessionConfiguration: URLSessionConfiguration? = nil,
        maximumCumulativePixels: Int? = nil,
        heavyWorkStarted: (@Sendable () -> Void)? = nil,
        imageDecodeStarted: (@Sendable () -> Void)? = nil
    ) {
        self.temporaryRoot = temporaryRoot ?? FileManager.default.temporaryDirectory.appending(
            path: "TinyCloudMusicSheetPreviews",
            directoryHint: .isDirectory
        )
        if let sessionConfiguration {
            self.sessionConfiguration = sessionConfiguration
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 20
            configuration.timeoutIntervalForResource = 60
            self.sessionConfiguration = configuration
        }
        self.maximumCumulativePixels = maximumCumulativePixels
            ?? Self.maximumCumulativeDecodedPixels
        self.heavyWorkStarted = heavyWorkStarted
        self.imageDecodeStarted = imageDecodeStarted
    }

    func existingPDF(song: Song, sheet: MusicSheetSummary, in directory: URL) -> URL? {
        let hasSecurityScope = directory.startAccessingSecurityScopedResource()
        defer { if hasSecurityScope { directory.stopAccessingSecurityScopedResource() } }
        let url = directory.appending(path: MusicSheetFiles.fileName(song: song, sheet: sheet))
        return Self.isValidPDF(at: url) ? url : nil
    }

    func cachedPDF(sheetID: Int64, cacheRoot: URL) -> URL? {
        guard sheetID > 0, !clearingRoots.contains(Self.rootPath(cacheRoot)) else { return nil }
        let hasSecurityScope = cacheRoot.startAccessingSecurityScopedResource()
        defer { if hasSecurityScope { cacheRoot.stopAccessingSecurityScopedResource() } }
        let url = Self.cacheURL(sheetID: sheetID, root: cacheRoot)
        return Self.isValidPDF(at: url, maximumBytes: Self.maximumDocumentBytes) ? url : nil
    }

    func preparePDF(
        sheetID: Int64,
        preview: MusicSheetPreview,
        cacheRoot: URL
    ) async throws -> URL {
        try Task.checkCancellation()
        guard sheetID > 0 else { throw EAPIError.invalidPayload }
        let rootPath = Self.rootPath(cacheRoot)
        guard !clearingRoots.contains(rootPath) else { throw MusicSheetFileError.cacheClearing }
        if let cached = cachedPDF(sheetID: sheetID, cacheRoot: cacheRoot) { return cached }
        let key = JobKey(rootPath: rootPath, sheetID: sheetID)
        let waiterID = UUID()

        do {
            let url = try await withTaskCancellationHandler {
                try await waitForJob(
                    key: key,
                    waiterID: waiterID,
                    sheetID: sheetID,
                    preview: preview,
                    cacheRoot: cacheRoot,
                    rootPath: rootPath
                )
            } onCancel: {
                Task { await self.cancelWaiter(waiterID, for: key) }
            }
            try Task.checkCancellation()
            return url
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
    }

    func cachePDF(at source: URL, sheetID: Int64, cacheRoot: URL) throws -> URL {
        try Task.checkCancellation()
        guard sheetID > 0 else { throw MusicSheetFileError.invalidPDF }
        guard !clearingRoots.contains(Self.rootPath(cacheRoot)) else {
            throw MusicSheetFileError.cacheClearing
        }
        guard Self.isValidPDF(at: source, maximumBytes: Self.maximumDocumentBytes) else {
            throw MusicSheetFileError.invalidPDF
        }
        let hasSecurityScope = cacheRoot.startAccessingSecurityScopedResource()
        defer { if hasSecurityScope { cacheRoot.stopAccessingSecurityScopedResource() } }
        return try Self.installPDF(
            at: source,
            to: Self.cacheURL(sheetID: sheetID, root: cacheRoot),
            maximumBytes: Self.maximumDocumentBytes
        )
    }

    func cacheExistingPDF(
        song: Song,
        sheet: MusicSheetSummary,
        in directory: URL,
        cacheRoot: URL
    ) throws -> URL? {
        let hasSecurityScope = directory.startAccessingSecurityScopedResource()
        defer { if hasSecurityScope { directory.stopAccessingSecurityScopedResource() } }
        let source = directory.appending(path: MusicSheetFiles.fileName(song: song, sheet: sheet))
        guard Self.isValidPDF(at: source) else { return nil }
        let size = (try? Self.fileSize(at: source)) ?? Int.max
        guard size <= Self.maximumDocumentBytes else { return source }
        return try cachePDF(at: source, sheetID: sheet.id, cacheRoot: cacheRoot)
    }

    func savePDF(
        at source: URL,
        song: Song,
        sheet: MusicSheetSummary,
        to directory: URL
    ) throws -> MusicSheetSaveResult {
        try Task.checkCancellation()
        let hasSecurityScope = directory.startAccessingSecurityScopedResource()
        defer { if hasSecurityScope { directory.stopAccessingSecurityScopedResource() } }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let destination = directory.appending(path: MusicSheetFiles.fileName(song: song, sheet: sheet))
        if Self.isValidPDF(at: destination) {
            return MusicSheetSaveResult(url: destination, saved: false)
        }
        guard Self.isValidPDF(at: source) else { throw MusicSheetFileError.invalidPDF }
        _ = try Self.installPDF(at: source, to: destination, maximumBytes: nil)
        return MusicSheetSaveResult(url: destination, saved: true)
    }

    func cleanupExpired() async {
        cleanupExpired(now: Date())
    }

    func cleanupExpired(now: Date) {
        let manager = FileManager.default
        guard let files = try? manager.contentsOfDirectory(
            at: temporaryRoot,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        for file in files {
            let date = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            if date.map({ now.timeIntervalSince($0) > 24 * 60 * 60 }) != false {
                try? manager.removeItem(at: file)
            }
        }
    }

    func clearCache(at cacheRoot: URL) async throws {
        let rootPath = Self.rootPath(cacheRoot)
        if let task = clearTasks[rootPath] {
            return try await task.value
        }
        clearingRoots.insert(rootPath)
        rootGenerations[rootPath, default: 0] += 1
        let matching = jobs.filter { $0.key.rootPath == rootPath }
        matching.values.forEach { $0.task.cancel() }
        let task = Task {
            for (key, job) in matching {
                _ = await job.task.result
                self.completeJob(
                    key,
                    id: job.id,
                    result: .failure(MusicSheetFileError.cacheClearing)
                )
            }
            try self.removeCacheDirectory(at: cacheRoot)
        }
        clearTasks[rootPath] = task
        do {
            try await task.value
            clearTasks.removeValue(forKey: rootPath)
            clearingRoots.remove(rootPath)
        } catch {
            clearTasks.removeValue(forKey: rootPath)
            clearingRoots.remove(rootPath)
            throw error
        }
    }

    static func validatedCumulativePixelCount(
        width: Int,
        height: Int,
        currentTotal: Int,
        maximumTotal: Int? = nil
    ) throws -> Int {
        guard width > 0, height > 0, currentTotal >= 0,
              width <= maximumDecodedPixels, height <= maximumDecodedPixels
        else { throw EAPIError.invalidResponse }
        let pixels = width.multipliedReportingOverflow(by: height)
        let decodedBytes = pixels.partialValue.multipliedReportingOverflow(by: 4)
        let cumulative = currentTotal.addingReportingOverflow(pixels.partialValue)
        let maximumCumulative = maximumTotal ?? maximumCumulativeDecodedPixels
        guard !pixels.overflow, !decodedBytes.overflow, !cumulative.overflow,
              maximumCumulative > 0,
              decodedBytes.partialValue <= maximumDocumentBytes,
              cumulative.partialValue <= maximumCumulative
        else { throw EAPIError.invalidResponse }
        return cumulative.partialValue
    }

    private func buildAndCache(
        sheetID: Int64,
        preview: MusicSheetPreview,
        cacheRoot: URL,
        rootPath: String,
        generation: UInt64
    ) async throws -> URL {
        let temporary: URL
        switch preview {
        case let .images(urls):
            temporary = try await makePDF(from: urls)
        case let .pdf(url):
            temporary = try await download(url, maximumBytes: Self.maximumPDFBytes, fileExtension: "pdf")
        case .unsupported:
            throw EAPIError.invalidPayload
        }
        defer { removeTemporary(temporary) }
        try Task.checkCancellation()
        guard rootGenerations[rootPath, default: 0] == generation,
              !clearingRoots.contains(rootPath)
        else { throw CancellationError() }
        return try cachePDF(at: temporary, sheetID: sheetID, cacheRoot: cacheRoot)
    }

    private func makePDF(from urls: [URL]) async throws -> URL {
        guard !urls.isEmpty, urls.count <= Self.maximumPageCount,
              urls.allSatisfy(MusicSheetURLPolicy.isAllowed)
        else { throw EAPIError.invalidPayload }
        let maximumCumulativePixels = maximumCumulativePixels
        let heavyWorkStarted = heavyWorkStarted
        let imageDecodeStarted = imageDecodeStarted
        let output = try temporaryURL(fileExtension: "pdf")
        var succeeded = false
        defer { if !succeeded { removeTemporary(output) } }
        guard let consumer = CGDataConsumer(url: output as CFURL),
              let context = CGContext(consumer: consumer, mediaBox: nil, nil)
        else { throw EAPIError.invalidResponse }
        var totalCompressedBytes = 0
        var totalPixels = 0
        var closed = false
        let session = URLSession(configuration: sessionConfiguration)
        defer {
            session.finishTasksAndInvalidate()
            if !closed {
                heavyWorkStarted?()
                context.closePDF()
            }
        }

        for url in urls {
            try Task.checkCancellation()
            let imageFile = try await download(
                url,
                maximumBytes: Self.maximumImageBytes,
                fileExtension: url.pathExtension.isEmpty ? "image" : url.pathExtension,
                session: session
            )
            do {
                defer { removeTemporary(imageFile) }
                try Task.checkCancellation()

                let imageBytes = try Self.fileSize(at: imageFile)
                let compressed = totalCompressedBytes.addingReportingOverflow(imageBytes)
                guard !compressed.overflow, compressed.partialValue <= Self.maximumDocumentBytes else {
                    throw EAPIError.invalidResponse
                }
                totalPixels = try autoreleasepool {
                    heavyWorkStarted?()
                    guard let source = CGImageSourceCreateWithURL(imageFile as CFURL, nil),
                          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                          let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
                          let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue
                    else { throw EAPIError.invalidResponse }
                    let nextPixels = try Self.validatedCumulativePixelCount(
                        width: width,
                        height: height,
                        currentTotal: totalPixels,
                        maximumTotal: maximumCumulativePixels
                    )
                    try Task.checkCancellation()
                    heavyWorkStarted?()
                    imageDecodeStarted?()
                    guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                        throw EAPIError.invalidResponse
                    }
                    try Task.checkCancellation()
                    var box = CGRect(x: 0, y: 0, width: image.width, height: image.height)
                    let boxData = withUnsafeBytes(of: &box) { Data($0) }
                    context.beginPDFPage([
                        kCGPDFContextMediaBox as String: boxData
                    ] as CFDictionary)
                    context.draw(image, in: box)
                    context.endPDFPage()
                    return nextPixels
                }
                totalCompressedBytes = compressed.partialValue
                if try Self.fileSize(at: output) > Self.maximumDocumentBytes {
                    throw EAPIError.invalidResponse
                }
            }
            try Task.checkCancellation()
        }
        heavyWorkStarted?()
        context.closePDF()
        closed = true
        try Task.checkCancellation()
        let outputSize = try Self.fileSize(at: output)
        guard outputSize <= Self.maximumDocumentBytes,
              Self.isValidPDF(at: output)
        else { throw EAPIError.invalidResponse }
        succeeded = true
        return output
    }

    private func download(
        _ url: URL,
        maximumBytes: Int,
        fileExtension: String,
        session suppliedSession: URLSession? = nil
    ) async throws -> URL {
        guard MusicSheetURLPolicy.isAllowed(url) else { throw EAPIError.invalidPayload }
        let delegate = MusicSheetDownloadDelegate(maximumBytes: Int64(maximumBytes))
        let session = suppliedSession ?? URLSession(configuration: sessionConfiguration)
        defer { if suppliedSession == nil { session.finishTasksAndInvalidate() } }

        let downloaded: URL
        let response: URLResponse
        do {
            (downloaded, response) = try await session.download(for: URLRequest(url: url), delegate: delegate)
        } catch {
            if delegate.exceededLimit { throw EAPIError.invalidResponse }
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
        try Task.checkCancellation()
        let downloadedSize = try Self.fileSize(at: downloaded)
        let expectedLength = response.expectedContentLength
        guard !delegate.exceededLimit,
              Self.valid(response),
              expectedLength < 0 || expectedLength <= maximumBytes,
              downloadedSize <= maximumBytes
        else { throw EAPIError.invalidResponse }

        let destination = try temporaryURL(fileExtension: fileExtension)
        do {
            try FileManager.default.copyItem(at: downloaded, to: destination)
            return destination
        } catch {
            removeTemporary(destination)
            throw error
        }
    }

    private func temporaryURL(fileExtension: String) throws -> URL {
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
        return temporaryRoot.appending(path: "\(UUID().uuidString).\(fileExtension)")
    }

    private func removeTemporary(_ url: URL?) {
        guard let url,
              url.deletingLastPathComponent().standardizedFileURL == temporaryRoot.standardizedFileURL
        else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private func waitForJob(
        key: JobKey,
        waiterID: UUID,
        sheetID: Int64,
        preview: MusicSheetPreview,
        cacheRoot: URL,
        rootPath: String
    ) async throws -> URL {
        if let job = jobs[key],
           !job.cancelledWaiters.isEmpty,
           job.cancelledWaiters.count == job.waiters.count {
            let generation = rootGenerations[rootPath, default: 0]
            let result = await job.task.result
            completeJob(key, id: job.id, result: result)
            try Task.checkCancellation()
            guard rootGenerations[rootPath, default: 0] == generation,
                  !clearingRoots.contains(rootPath)
            else {
                throw MusicSheetFileError.cacheClearing
            }
            if case let .success(url) = result { return url }
        }
        return try await withCheckedThrowingContinuation { continuation in
            guard !Task.isCancelled else {
                continuation.resume(throwing: CancellationError())
                return
            }
            if var job = jobs[key] {
                job.waiters[waiterID] = continuation
                jobs[key] = job
                return
            }

            let generation = rootGenerations[rootPath, default: 0]
            let jobID = UUID()
            let task = Task {
                try await self.buildAndCache(
                    sheetID: sheetID,
                    preview: preview,
                    cacheRoot: cacheRoot,
                    rootPath: rootPath,
                    generation: generation
                )
            }
            jobs[key] = Job(
                id: jobID,
                task: task,
                waiters: [waiterID: continuation],
                cancelledWaiters: []
            )
            Task {
                let result = await task.result
                self.completeJob(key, id: jobID, result: result)
            }
        }
    }

    private func completeJob(
        _ key: JobKey,
        id: UUID,
        result: Result<URL, any Error>
    ) {
        guard let job = jobs[key], job.id == id else { return }
        jobs.removeValue(forKey: key)
        let effectiveResult: Result<URL, any Error> = clearingRoots.contains(key.rootPath)
            ? .failure(MusicSheetFileError.cacheClearing)
            : result
        for (waiterID, continuation) in job.waiters {
            if job.cancelledWaiters.contains(waiterID) {
                continuation.resume(throwing: CancellationError())
                continue
            }
            switch effectiveResult {
            case let .success(url): continuation.resume(returning: url)
            case let .failure(error): continuation.resume(throwing: error)
            }
        }
    }

    private func cancelWaiter(_ waiterID: UUID, for key: JobKey) {
        guard var job = jobs[key], let continuation = job.waiters[waiterID] else {
            return
        }
        if job.waiters.count == 1 {
            job.cancelledWaiters.insert(waiterID)
            job.task.cancel()
            jobs[key] = job
            return
        }
        job.waiters.removeValue(forKey: waiterID)
        jobs[key] = job
        continuation.resume(throwing: CancellationError())
    }

    private static func installPDF(
        at source: URL,
        to destination: URL,
        maximumBytes: Int?
    ) throws -> URL {
        if isValidPDF(at: destination, maximumBytes: maximumBytes) { return destination }
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let part = destination.appendingPathExtension("\(UUID().uuidString).part")
        defer { try? FileManager.default.removeItem(at: part) }
        try FileManager.default.copyItem(at: source, to: part)
        try Task.checkCancellation()
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: part)
        } else {
            try FileManager.default.moveItem(at: part, to: destination)
        }
        return destination
    }

    private static func valid(_ response: URLResponse) -> Bool {
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              response.url.map(MusicSheetURLPolicy.isAllowed) == true
        else { return false }
        return true
    }

    private static func fileSize(at url: URL) throws -> Int {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? -1
        guard size >= 0 else { throw EAPIError.invalidResponse }
        return size
    }

    private static func isValidPDF(at url: URL, maximumBytes: Int? = nil) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        do {
            let size = try handle.seekToEnd()
            guard size >= 9,
                  maximumBytes.map({ size <= UInt64($0) }) != false
            else { return false }
            try handle.seek(toOffset: 0)
            guard try handle.read(upToCount: 4)?.starts(with: Data("%PDF".utf8)) == true else {
                return false
            }
            try handle.seek(toOffset: size - min(size, 1_024))
            return try handle.readToEnd()?.range(of: Data("%%EOF".utf8)) != nil
        } catch {
            return false
        }
    }

    private static func cacheURL(sheetID: Int64, root: URL) -> URL {
        sheetsDirectory(root: root).appending(path: "\(sheetID).pdf", directoryHint: .notDirectory)
    }

    private static func sheetsDirectory(root: URL) -> URL {
        root.appending(path: "DownloadCache", directoryHint: .isDirectory)
            .appending(path: "Sheets", directoryHint: .isDirectory)
    }

    private static func rootPath(_ root: URL) -> String {
        root.standardizedFileURL.resolvingSymlinksInPath().path
    }

    private func removeCacheDirectory(at cacheRoot: URL) throws {
        let hasSecurityScope = cacheRoot.startAccessingSecurityScopedResource()
        defer { if hasSecurityScope { cacheRoot.stopAccessingSecurityScopedResource() } }
        let sheets = Self.sheetsDirectory(root: cacheRoot)
        if FileManager.default.fileExists(atPath: sheets.path) {
            try FileManager.default.removeItem(at: sheets)
        }
    }
}

final class MusicSheetDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let maximumBytes: Int64
    private let lock = NSLock()
    private var limitExceeded = false

    init(maximumBytes: Int64) {
        self.maximumBytes = maximumBytes
    }

    var exceededLimit: Bool {
        lock.lock()
        defer { lock.unlock() }
        return limitExceeded
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {}

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesWritten > maximumBytes
                || totalBytesExpectedToWrite > maximumBytes
                || (downloadTask.response?.expectedContentLength ?? -1) > maximumBytes
        else { return }
        lock.lock()
        limitExceeded = true
        lock.unlock()
        downloadTask.cancel()
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(request.url.map(MusicSheetURLPolicy.isAllowed) == true ? request : nil)
    }
}
