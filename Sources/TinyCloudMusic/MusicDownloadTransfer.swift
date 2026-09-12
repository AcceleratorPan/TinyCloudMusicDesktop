import Foundation

enum MusicDownloadSession {
    static func defaultSession() -> URLSession {
#if os(iOS)
        let configuration = URLSessionConfiguration.background(
            withIdentifier: "com.tinycloudmusic.downloads"
        )
        configuration.sessionSendsLaunchEvents = true
        configuration.waitsForConnectivity = true
        configuration.allowsExpensiveNetworkAccess = true
        configuration.allowsConstrainedNetworkAccess = false
        configuration.isDiscretionary = false
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 24 * 60 * 60
        return URLSession(configuration: configuration)
#else
        return .shared
#endif
    }

    static func identifier(for songID: Int64) -> String {
        "com.tinycloudmusic.downloads.audio.\(songID)"
    }

    static func identifier(forVideo identity: String) -> String {
        let encoded = Data(identity.utf8).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")
        return "com.tinycloudmusic.downloads.video.\(encoded)"
    }

    static func configuration(
        from seed: URLSessionConfiguration,
        identifier: String?
    ) -> URLSessionConfiguration {
#if os(iOS)
        guard let baseIdentifier = seed.identifier ?? identifier else { return seed }
        let configuration = URLSessionConfiguration.background(
            withIdentifier: identifier ?? "\(baseIdentifier).\(UUID().uuidString)"
        )
        configuration.sessionSendsLaunchEvents = true
        configuration.waitsForConnectivity = true
        configuration.allowsExpensiveNetworkAccess = true
        configuration.allowsConstrainedNetworkAccess = false
        configuration.isDiscretionary = false
        configuration.timeoutIntervalForRequest = seed.timeoutIntervalForRequest
        configuration.timeoutIntervalForResource = seed.timeoutIntervalForResource
        return configuration
#else
        _ = identifier
        return seed
#endif
    }

    static func isBackground(_ session: URLSession) -> Bool {
#if os(iOS)
        session.configuration.identifier != nil
#else
        _ = session
        return false
#endif
    }
}

private final class MusicDownloadBackgroundEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var completionHandlers: [String: () -> Void] = [:]

    func store(identifier: String, completionHandler: @escaping () -> Void) {
        lock.withLock { completionHandlers[identifier] = completionHandler }
    }

    func finish(identifier: String) {
        let completion = lock.withLock { completionHandlers.removeValue(forKey: identifier) }
        completion?()
    }
}

struct MusicDownloadTransferResult: Sendable {
    let temporaryURL: URL
    let response: URLResponse
}

struct MusicDownloadTransferPaused: Error, Sendable {
    let resumeData: Data?
}

final class MusicDownloadTransfer: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private struct Pending {
        let id: UUID
        let taskIdentifier: Int
        let continuation: CheckedContinuation<MusicDownloadTransferResult, Error>
        var pauseRequested = false
        var stagedResult: Result<MusicDownloadTransferResult, Error>?
    }

    private struct Completion {
        let continuation: CheckedContinuation<MusicDownloadTransferResult, Error>
        let result: Result<MusicDownloadTransferResult, Error>
        let temporaryURLToRemove: URL?
    }

    private final class CleanupGate: @unchecked Sendable {
        private let lock = NSLock()
        private var didRun = false

        func run(_ cleanup: () -> Void) {
            let shouldRun = lock.withLock {
                guard !didRun else { return false }
                didRun = true
                return true
            }
            if shouldRun { cleanup() }
        }
    }

    private let progress: @Sendable (Int64, Int64, Int64) -> Void
    private let allowsRequest: @Sendable (URLRequest) -> Bool
    private let lock = NSLock()
    private var pending: Pending?
    private var currentTask: URLSessionDownloadTask?
    private var startingID: UUID?
    private var cancelledStartingID: UUID?
    private var transferSession: URLSession!

    init(
        session: URLSession,
        progress: @escaping @Sendable (Int64, Int64, Int64) -> Void,
        allowsRequest: @escaping @Sendable (URLRequest) -> Bool = { _ in true },
        backgroundIdentifier: String? = nil
    ) {
        let configuration = MusicDownloadSession.configuration(
            from: session.configuration,
            identifier: backgroundIdentifier
        )
        self.progress = progress
        self.allowsRequest = allowsRequest
        super.init()
        transferSession = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    deinit {
        currentTask?.cancel()
        transferSession?.invalidateAndCancel()
    }

    func download(request: URLRequest, resumeData: Data?) async throws -> MusicDownloadTransferResult {
        try Task.checkCancellation()
        let id = UUID()
        let reserved = lock.withLock {
            guard pending == nil, startingID == nil else { return false }
            startingID = id
            return true
        }
        guard reserved else { throw URLError(.cannotCreateFile) }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                var immediateError: Error?
                let task: URLSessionDownloadTask? = lock.withLock {
                    guard startingID == id else {
                        immediateError = MusicDownloadTransferPaused(resumeData: resumeData)
                        return nil
                    }
                    if cancelledStartingID == id {
                        startingID = nil
                        cancelledStartingID = nil
                        immediateError = MusicDownloadTransferPaused(resumeData: resumeData)
                        return nil
                    }

                    let task = if let resumeData, !resumeData.isEmpty {
                        transferSession.downloadTask(withResumeData: resumeData)
                    } else {
                        transferSession.downloadTask(with: request)
                    }
                    pending = Pending(
                        id: id,
                        taskIdentifier: task.taskIdentifier,
                        continuation: continuation
                    )
                    currentTask = task
                    startingID = nil
                    return task
                }

                if let task {
                    task.resume()
                } else {
                    continuation.resume(throwing: immediateError ?? MusicDownloadError.invalidResponse)
                }
            }
        } onCancel: {
            self.pause(id: id)
        }
    }

    func invalidate() {
        let invalidated: (URLSessionDownloadTask?, Completion?) = lock.withLock {
            if let startingID {
                cancelledStartingID = startingID
            }
            let task = currentTask
            guard let pending else {
                currentTask = nil
                return (task, nil)
            }
            self.pending = nil
            currentTask = nil
            return (
                task,
                Completion(
                    continuation: pending.continuation,
                    result: .failure(MusicDownloadTransferPaused(resumeData: nil)),
                    temporaryURLToRemove: Self.temporaryURL(from: pending.stagedResult)
                )
            )
        }
        invalidated.0?.cancel()
        transferSession.invalidateAndCancel()
        Self.resume(invalidated.1)
    }

    static func registerBackgroundEvents(
        identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        backgroundEvents.store(identifier: identifier, completionHandler: completionHandler)
    }

    private static let backgroundEvents = MusicDownloadBackgroundEvents()

    private func pause(id: UUID) {
        var shouldFinishWithoutTask = false
        let task: URLSessionDownloadTask? = lock.withLock {
            if startingID == id {
                cancelledStartingID = id
                return nil
            }
            guard var pending, pending.id == id, !pending.pauseRequested else { return nil }
            pending.pauseRequested = true
            self.pending = pending
            shouldFinishWithoutTask = currentTask == nil
            return currentTask
        }
        if let task {
            task.cancel(byProducingResumeData: { data in
                self.completePause(id: id, resumeData: data)
            })
        } else if shouldFinishWithoutTask {
            completePause(id: id, resumeData: nil)
        }
    }

    private func completePause(id: UUID, resumeData: Data?) {
        let completion: Completion? = lock.withLock {
            guard let pending, pending.id == id else { return nil }
            self.pending = nil
            currentTask = nil
            return Completion(
                continuation: pending.continuation,
                result: .failure(MusicDownloadTransferPaused(resumeData: resumeData)),
                temporaryURLToRemove: Self.temporaryURL(from: pending.stagedResult)
            )
        }
        Self.resume(completion)
    }

    private static func stage(location: URL, response: URLResponse?) -> Result<MusicDownloadTransferResult, Error> {
        guard let response else { return .failure(MusicDownloadError.invalidResponse) }
        do {
            try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
            cleanupGate.run { removeStaleFiles(in: temporaryDirectory) }
            let temporaryURL = temporaryDirectory.appending(
                path: UUID().uuidString,
                directoryHint: .notDirectory
            )
            try FileManager.default.moveItem(at: location, to: temporaryURL)
            return .success(MusicDownloadTransferResult(temporaryURL: temporaryURL, response: response))
        } catch {
            return .failure(error)
        }
    }

    private static func temporaryURL(
        from result: Result<MusicDownloadTransferResult, Error>?
    ) -> URL? {
        guard case let .success(value)? = result else { return nil }
        return value.temporaryURL
    }

    private static func resume(_ completion: Completion?) {
        guard let completion else { return }
        if let url = completion.temporaryURLToRemove {
            try? FileManager.default.removeItem(at: url)
        }
        completion.continuation.resume(with: completion.result)
    }

    private static let temporaryDirectory = FileManager.default.temporaryDirectory
        .appending(path: "TinyCloudMusicTransfers", directoryHint: .isDirectory)
    private static let cleanupGate = CleanupGate()

    private static func removeStaleFiles(in directory: URL) {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: .skipsHiddenFiles
        ) else { return }
        let cutoff = Date().addingTimeInterval(-24 * 60 * 60)
        for file in files where (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate.map({ $0 < cutoff }) == true {
            try? FileManager.default.removeItem(at: file)
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let isCurrent = lock.withLock {
            pending?.taskIdentifier == downloadTask.taskIdentifier
        }
        guard isCurrent else { return }
        progress(totalBytesWritten, totalBytesExpectedToWrite, downloadTask.response?.expectedContentLength ?? -1)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        let result = Self.stage(location: location, response: downloadTask.response)
        let orphanedURL: URL? = lock.withLock {
            guard var pending, pending.taskIdentifier == downloadTask.taskIdentifier else {
                return Self.temporaryURL(from: result)
            }
            pending.stagedResult = result
            self.pending = pending
            return nil
        }
        if let orphanedURL {
            try? FileManager.default.removeItem(at: orphanedURL)
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        var temporaryURLToRemove: URL?
        let completion: Completion? = lock.withLock {
            guard let pending, pending.taskIdentifier == task.taskIdentifier else { return nil }

            let result: Result<MusicDownloadTransferResult, Error>
            if pending.pauseRequested {
                temporaryURLToRemove = Self.temporaryURL(from: pending.stagedResult)
                result = .failure(MusicDownloadTransferPaused(resumeData: Self.resumeData(from: error)))
            } else if let error {
                temporaryURLToRemove = Self.temporaryURL(from: pending.stagedResult)
                result = .failure(error)
            } else {
                result = pending.stagedResult ?? .failure(MusicDownloadError.invalidResponse)
            }
            self.pending = nil
            currentTask = nil
            return Completion(
                continuation: pending.continuation,
                result: result,
                temporaryURLToRemove: temporaryURLToRemove
            )
        }
        Self.resume(completion)
    }

    private static func resumeData(from error: Error?) -> Data? {
        (error as NSError?)?.userInfo[NSURLSessionDownloadTaskResumeData] as? Data
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(allowsRequest(request) ? request : nil)
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        guard let identifier = session.configuration.identifier else { return }
        Self.backgroundEvents.finish(identifier: identifier)
    }
}
