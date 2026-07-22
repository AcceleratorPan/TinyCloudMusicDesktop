import Foundation

#if canImport(Testing)
import Testing
@testable import TinyCloudMusic

@Suite("Music download transfer")
struct MusicDownloadTransferTests {
    @Test("Delegate download reports progress and preserves the temporary file")
    func delegateDownloadSucceeds() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ScriptedDownloadProtocol.self]
        let seedSession = URLSession(configuration: configuration)
        let progress = TransferProgressRecorder()
        let transfer = MusicDownloadTransfer(session: seedSession) { written, expected, responseExpected in
            progress.record(written: written, expected: expected, responseExpected: responseExpected)
        }
        defer {
            transfer.invalidate()
            seedSession.invalidateAndCancel()
        }

        let result = try await transfer.download(
            request: URLRequest(url: URL(string: "https://download.test/success")!),
            resumeData: nil
        )
        defer { try? FileManager.default.removeItem(at: result.temporaryURL) }

        #expect(try Data(contentsOf: result.temporaryURL) == ScriptedDownloadProtocol.payload)
        #expect(progress.didReportProgress)
        #expect((result.response as? HTTPURLResponse)?.statusCode == 200)
    }

    @Test("Cancelling an active transfer returns paused without hanging")
    func cancellationReturnsPaused() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ScriptedDownloadProtocol.self]
        let seedSession = URLSession(configuration: configuration)
        let progress = TransferProgressRecorder()
        let transfer = MusicDownloadTransfer(session: seedSession) { written, expected, responseExpected in
            progress.record(written: written, expected: expected, responseExpected: responseExpected)
        }
        defer {
            transfer.invalidate()
            seedSession.invalidateAndCancel()
        }

        let outcome = TransferPauseOutcome()
        let task = Task {
            do {
                _ = try await transfer.download(
                    request: URLRequest(url: URL(string: "https://download.test/blocked")!),
                    resumeData: nil
                )
                await outcome.finish(paused: false)
            } catch {
                await outcome.finish(paused: error is MusicDownloadTransferPaused)
            }
        }

        for _ in 0..<100 where !progress.didReportProgress {
            try await Task.sleep(for: .milliseconds(10))
        }
        task.cancel()

        for _ in 0..<200 {
            if await outcome.finished { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let finishedWithoutFallback = await outcome.finished
        let paused = await outcome.paused
        if !finishedWithoutFallback {
            transfer.invalidate()
        }
        await task.value

        #expect(progress.didReportProgress)
        #expect(finishedWithoutFallback)
        #expect(paused)
    }
}

private final class ScriptedDownloadProtocol: URLProtocol, @unchecked Sendable {
    static let payload = Data("delegate-backed download".utf8)

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let isBlocked = request.url?.path == "/blocked"
        let expectedLength = isBlocked ? 1_048_576 : Self.payload.count
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Length": String(expectedLength)]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(
            self,
            didLoad: isBlocked ? Data(repeating: 0x5A, count: 16_384) : Self.payload
        )
        if !isBlocked {
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}

private final class TransferProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var didReportProgress: Bool {
        lock.withLock { count > 0 }
    }

    func record(written: Int64, expected: Int64, responseExpected: Int64) {
        lock.withLock { count += 1 }
    }
}

private actor TransferPauseOutcome {
    private(set) var finished = false
    private(set) var paused = false

    func finish(paused: Bool) {
        finished = true
        self.paused = paused
    }
}
#endif
