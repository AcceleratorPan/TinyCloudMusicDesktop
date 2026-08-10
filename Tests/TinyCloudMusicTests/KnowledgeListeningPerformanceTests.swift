import AppKit
import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import SwiftUI
import Testing
@testable import TinyCloudMusic

private final class MusicSheetFixtureProtocol: URLProtocol, @unchecked Sendable {
    struct Stub: Sendable {
        let status: Int
        let headers: [String: String]
        let body: Data
        let blocked: Bool
        let redirectURL: URL?

        init(
            status: Int = 200,
            headers: [String: String] = [:],
            body: Data,
            blocked: Bool = false,
            redirectURL: URL? = nil
        ) {
            self.status = status
            self.headers = headers
            self.body = body
            self.blocked = blocked
            self.redirectURL = redirectURL
        }
    }

    typealias Handler = @Sendable (URLRequest, Int) -> Stub

    private static let lock = NSLock()
    nonisolated(unsafe) private static var handler: Handler = { _, _ in Stub(body: Data()) }
    nonisolated(unsafe) private static var requests: [URLRequest] = []
    nonisolated(unsafe) private static var pending: [@Sendable () -> Void] = []
    nonisolated(unsafe) private static var stopCount = 0

    static func reset(handler: @escaping Handler) {
        lock.withLock {
            self.handler = handler
            requests = []
            pending = []
            stopCount = 0
        }
    }

    static var requestCount: Int { lock.withLock { requests.count } }
    static func requestCount(path: String) -> Int {
        lock.withLock { requests.count(where: { $0.url?.path == path }) }
    }
    static var cancellationCount: Int { lock.withLock { stopCount } }

    static func releaseAll() {
        let callbacks = lock.withLock {
            let callbacks = pending
            pending = []
            return callbacks
        }
        callbacks.forEach { $0() }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let (stub, index) = Self.lock.withLock {
            Self.requests.append(request)
            let index = Self.requests.count
            return (Self.handler(request, index), index)
        }
        let respond: @Sendable () -> Void = { [self] in
            if let redirectURL = stub.redirectURL {
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 302,
                    httpVersion: nil,
                    headerFields: ["Location": redirectURL.absoluteString]
                )!
                client?.urlProtocol(
                    self,
                    wasRedirectedTo: URLRequest(url: redirectURL),
                    redirectResponse: response
                )
                client?.urlProtocol(self, didFailWithError: URLError(.cancelled))
                return
            }
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: stub.status,
                httpVersion: nil,
                headerFields: stub.headers
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: stub.body)
            client?.urlProtocolDidFinishLoading(self)
        }
        if stub.blocked {
            Self.lock.withLock { Self.pending.append(respond) }
        } else {
            _ = index
            respond()
        }
    }

    override func stopLoading() {
        Self.lock.withLock { Self.stopCount += 1 }
    }
}

private actor CancellationProbe {
    private var entered = false
    private var cancelled = false

    func markEntered() { entered = true }
    func markCancelled() { cancelled = true }
    func hasEntered() -> Bool { entered }
    func wasCancelled() -> Bool { cancelled }
}

private final class HeavyWorkThreadProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var observations: [Bool] = []

    func record() { lock.withLock { observations.append(Thread.isMainThread) } }
    var snapshot: [Bool] { lock.withLock { observations } }
}

private enum KnowledgeFixtureError: Error {
    case wiki
    case brief
}

@Suite("Knowledge, sheet, and listening performance", .serialized)
struct KnowledgeListeningPerformanceTests {
    @Test("Image sheets stream 1, 50, and 100 pages in order")
    func imageSheetPageCounts() async throws {
        let oddImage = try fixturePNG(width: 3, height: 5)
        let evenImage = try fixturePNG(width: 4, height: 7)
        for pageCount in [1, 50, 100] {
            MusicSheetFixtureProtocol.reset { _, requestIndex in
                .init(body: requestIndex.isMultiple(of: 2) ? evenImage : oddImage)
            }
            let root = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let worker = fixtureWorker(temporaryRoot: root.appending(path: "temporary"))
            let urls = (0..<pageCount).map {
                URL(string: "https://p1.music.126.net/sheet/page-\($0).png")!
            }

            let file = try await worker.preparePDF(
                sheetID: Int64(pageCount),
                preview: .images(urls),
                cacheRoot: root
            )
            let document = try #require(PDFDocument(url: file))
            #expect(document.pageCount == pageCount)
            #expect(MusicSheetFixtureProtocol.requestCount == pageCount)
            for pageIndex in 0..<pageCount {
                let box = try #require(document.page(at: pageIndex)?.bounds(for: .mediaBox))
                let isEvenRequest = (pageIndex + 1).isMultiple(of: 2)
                #expect(box.width == (isEvenRequest ? 4 : 3))
                #expect(box.height == (isEvenRequest ? 7 : 5))
            }
        }
    }

    @Test("Default pixel budget accepts an A4 300-dpi sample and constrains worst-case pages")
    func realisticSheetPixelBudget() async throws {
        var a4Pixels = 0
        for _ in 0..<MusicSheetWorker.maximumPageCount {
            a4Pixels = try MusicSheetWorker.validatedCumulativePixelCount(
                width: 2_480,
                height: 3_508,
                currentTotal: a4Pixels
            )
        }
        #expect(a4Pixels == 869_984_000)
        #expect(a4Pixels < MusicSheetWorker.maximumCumulativeDecodedPixels)

        var worstCasePixels = 0
        for _ in 0..<36 {
            worstCasePixels = try MusicSheetWorker.validatedCumulativePixelCount(
                width: 5_000,
                height: 5_000,
                currentTotal: worstCasePixels
            )
        }
        #expect(worstCasePixels == MusicSheetWorker.maximumCumulativeDecodedPixels)
        do {
            _ = try MusicSheetWorker.validatedCumulativePixelCount(
                width: 5_000,
                height: 5_000,
                currentTotal: worstCasePixels
            )
            Issue.record("Default cumulative pixel budget did not reject excess work")
        } catch EAPIError.invalidResponse {
        } catch {
            Issue.record("Default cumulative pixel budget returned the wrong error: \(error)")
        }

        let image = try fixturePNG(width: 2_480, height: 3_508)
        MusicSheetFixtureProtocol.reset { _, _ in .init(body: image) }
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let worker = fixtureWorker(temporaryRoot: root.appending(path: "temporary"))
        let file = try await worker.preparePDF(
            sheetID: 100,
            preview: .images([URL(string: "https://p1.music.126.net/sheet/a4-300dpi.png")!]),
            cacheRoot: root
        )
        let box = try #require(PDFDocument(url: file)?.page(at: 0)?.bounds(for: .mediaBox))
        #expect(box.width == 2_480)
        #expect(box.height == 3_508)
    }

    @MainActor
    @Test("Sheet generation leaves MainActor before ImageIO and PDF work")
    func sheetGenerationLeavesMainActor() async throws {
        let image = try fixturePNG(width: 2, height: 2)
        MusicSheetFixtureProtocol.reset { _, _ in .init(body: image) }
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let probe = HeavyWorkThreadProbe()
        let worker = fixtureWorker(
            temporaryRoot: root.appending(path: "temporary"),
            heavyWorkStarted: { probe.record() }
        )

        _ = try await worker.preparePDF(
            sheetID: 101,
            preview: .images([URL(string: "https://p1.music.126.net/sheet/actor.png")!]),
            cacheRoot: root
        )

        #expect(probe.snapshot.count == 3)
        #expect(probe.snapshot.allSatisfy { !$0 })
    }

    @Test("Same-sheet waiters share work and cancellation is waiter-scoped")
    func sameSheetSingleFlight() async throws {
        let image = try fixturePNG(width: 2, height: 2)
        MusicSheetFixtureProtocol.reset { _, _ in .init(body: image, blocked: true) }
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let worker = fixtureWorker(temporaryRoot: root.appending(path: "temporary"))
        let preview = MusicSheetPreview.images([
            URL(string: "https://p1.music.126.net/sheet/shared.png")!
        ])

        let first = Task { try await worker.preparePDF(sheetID: 7, preview: preview, cacheRoot: root) }
        let second = Task { try await worker.preparePDF(sheetID: 7, preview: preview, cacheRoot: root) }
        #expect(await eventually { MusicSheetFixtureProtocol.requestCount == 1 })
        first.cancel()
        do {
            _ = try await first.value
            Issue.record("Cancelled waiter unexpectedly succeeded")
        } catch is CancellationError {
        }
        #expect(MusicSheetFixtureProtocol.requestCount == 1)

        MusicSheetFixtureProtocol.releaseAll()
        let secondURL = try await second.value
        #expect(await worker.cachedPDF(sheetID: 7, cacheRoot: root) == secondURL)
    }

    @Test("Cancelling page N stops later pages and removes temporary files")
    func cancellationStopsPages() async throws {
        let image = try fixturePNG(width: 2, height: 2)
        MusicSheetFixtureProtocol.reset { _, index in
            .init(body: image, blocked: index == 3)
        }
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let temporaryRoot = root.appending(path: "temporary")
        let worker = fixtureWorker(temporaryRoot: temporaryRoot)
        let existingPDF = root.appending(path: "existing.pdf")
        let existingBytes = Data("%PDF-1.7\nexisting\n%%EOF".utf8)
        try existingBytes.write(to: existingPDF)
        let cached = try await worker.cachePDF(at: existingPDF, sheetID: 7, cacheRoot: root)
        let song = annualSong(88, name: "Existing", complete: true)
        let sheet = MusicSheetSummary(id: 7, title: "Existing", instrument: nil, pageCount: 1)
        let userDirectory = root.appending(path: "user")
        let saved = try await worker.savePDF(at: existingPDF, song: song, sheet: sheet, to: userDirectory)
        let urls = (0..<10).map {
            URL(string: "https://p1.music.126.net/sheet/cancel-\($0).png")!
        }
        let task = Task {
            try await worker.preparePDF(sheetID: 8, preview: .images(urls), cacheRoot: root)
        }

        #expect(await eventually { MusicSheetFixtureProtocol.requestCount == 3 })
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("Cancelled sheet generation unexpectedly succeeded")
        } catch is CancellationError {
        }
        #expect(MusicSheetFixtureProtocol.requestCount == 3)
        #expect(await eventually { MusicSheetFixtureProtocol.cancellationCount > 0 })
        #expect(temporaryFiles(at: temporaryRoot).isEmpty)
        #expect(await worker.cachedPDF(sheetID: 8, cacheRoot: root) == nil)
        #expect(try Data(contentsOf: cached) == existingBytes)
        #expect(try Data(contentsOf: saved.url) == existingBytes)
    }

    @Test("Clear is a custom-root barrier and generated files cannot reappear")
    func clearCacheBarrier() async throws {
        let pdf = Data("%PDF-1.7\nfixture\n%%EOF".utf8)
        MusicSheetFixtureProtocol.reset { _, _ in .init(body: pdf, blocked: true) }
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let worker = fixtureWorker(temporaryRoot: root.appending(path: "temporary"))
        let preview = MusicSheetPreview.pdf(
            URL(string: "https://p1.music.126.net/sheet/blocked.pdf")!
        )
        let generation = Task {
            try await worker.preparePDF(sheetID: 9, preview: preview, cacheRoot: root)
        }
        #expect(await eventually { MusicSheetFixtureProtocol.requestCount == 1 })

        async let firstClear: Void = worker.clearCache(at: root)
        async let secondClear: Void = worker.clearCache(at: root)
        _ = try await (firstClear, secondClear)
        do {
            _ = try await generation.value
            Issue.record("Clear did not cancel in-use sheet generation")
        } catch MusicSheetFileError.cacheClearing {
        } catch {
            Issue.record("Clear returned the wrong generation error: \(error)")
        }
        #expect(await worker.cachedPDF(sheetID: 9, cacheRoot: root) == nil)
        #expect(!FileManager.default.fileExists(
            atPath: root.appending(path: "DownloadCache/Sheets").path
        ))
    }

    @Test("PDF and pixel limits reject malformed or overflowing input")
    func resourceLimits() async throws {
        #expect(try MusicSheetWorker.validatedCumulativePixelCount(
            width: 3,
            height: 5,
            currentTotal: 7
        ) == 22)
        expectPixelFailure(width: 0, height: 1)
        expectPixelFailure(width: Int.max, height: 2)
        expectPixelFailure(width: MusicSheetWorker.maximumDecodedPixels, height: 2)
        #expect(try MusicSheetWorker.validatedCumulativePixelCount(
            width: MusicSheetWorker.maximumDecodedPixels,
            height: 1,
            currentTotal: 0
        ) == MusicSheetWorker.maximumDecodedPixels)

        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let decodeProbe = HeavyWorkThreadProbe()
        let worker = fixtureWorker(
            temporaryRoot: root.appending(path: "temporary"),
            imageDecodeStarted: { decodeProbe.record() }
        )
        let url = URL(string: "https://p1.music.126.net/sheet/invalid.pdf")!

        MusicSheetFixtureProtocol.reset { _, _ in .init(body: Data("%PDF-no-eof".utf8)) }
        do {
            _ = try await worker.preparePDF(sheetID: 10, preview: .pdf(url), cacheRoot: root)
            Issue.record("PDF without EOF was installed")
        } catch {
        }

        MusicSheetFixtureProtocol.reset { _, _ in .init(body: Data("not-pdf%%EOF".utf8)) }
        do {
            _ = try await worker.preparePDF(sheetID: 12, preview: .pdf(url), cacheRoot: root)
            Issue.record("File without PDF magic was installed")
        } catch {
        }

        MusicSheetFixtureProtocol.reset { _, _ in
            .init(
                headers: ["Content-Length": "\(MusicSheetWorker.maximumPDFBytes + 1)"],
                body: Data("%PDF-1.7\n%%EOF".utf8)
            )
        }
        do {
            _ = try await worker.preparePDF(sheetID: 11, preview: .pdf(url), cacheRoot: root)
            Issue.record("Oversized Content-Length was installed")
        } catch {
        }

        let oversizedBody = Data("%PDF-1.7\n".utf8)
            + Data(count: MusicSheetWorker.maximumPDFBytes)
            + Data("\n%%EOF".utf8)
        MusicSheetFixtureProtocol.reset { _, _ in .init(body: oversizedBody) }
        do {
            _ = try await worker.preparePDF(sheetID: 15, preview: .pdf(url), cacheRoot: root)
            Issue.record("Oversized response without Content-Length was installed")
        } catch {
        }

        let delegateSession = URLSession(configuration: .ephemeral)
        defer { delegateSession.invalidateAndCancel() }
        let delegateTask = delegateSession.downloadTask(with: url)
        let delegate = MusicSheetDownloadDelegate(
            maximumBytes: Int64(MusicSheetWorker.maximumPDFBytes)
        )
        delegate.urlSession(
            delegateSession,
            downloadTask: delegateTask,
            didWriteData: 1,
            totalBytesWritten: Int64(MusicSheetWorker.maximumPDFBytes),
            totalBytesExpectedToWrite: -1
        )
        #expect(!delegate.exceededLimit)
        #expect(delegateTask.state == .suspended)
        delegate.urlSession(
            delegateSession,
            downloadTask: delegateTask,
            didWriteData: 1,
            totalBytesWritten: Int64(MusicSheetWorker.maximumPDFBytes + 1),
            totalBytesExpectedToWrite: -1
        )
        #expect(delegate.exceededLimit)
        #expect(delegateTask.state == .canceling)

        let oversizedImage = try fixturePNG(width: 5_121, height: 5_120)
        let oversizedSource = try #require(CGImageSourceCreateWithData(oversizedImage as CFData, nil))
        let oversizedProperties = try #require(
            CGImageSourceCopyPropertiesAtIndex(oversizedSource, 0, nil) as? [CFString: Any]
        )
        #expect((oversizedProperties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue
            == 5_121)
        #expect((oversizedProperties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue
            == 5_120)
        MusicSheetFixtureProtocol.reset { _, _ in .init(body: oversizedImage) }
        do {
            _ = try await worker.preparePDF(
                sheetID: 16,
                preview: .images([URL(string: "https://p1.music.126.net/sheet/oversized.png")!]),
                cacheRoot: root
            )
            Issue.record("Oversized image dimensions were decoded")
        } catch {
        }
        #expect(decodeProbe.snapshot.isEmpty)

        let cumulativeDecodeProbe = HeavyWorkThreadProbe()
        let cumulativeWorker = fixtureWorker(
            temporaryRoot: root.appending(path: "cumulative-temporary"),
            maximumCumulativePixels: 4,
            imageDecodeStarted: { cumulativeDecodeProbe.record() }
        )
        let smallImage = try fixturePNG(width: 2, height: 2)
        MusicSheetFixtureProtocol.reset { _, _ in .init(body: smallImage) }
        do {
            _ = try await cumulativeWorker.preparePDF(
                sheetID: 18,
                preview: .images([
                    URL(string: "https://p1.music.126.net/sheet/cumulative-1.png")!,
                    URL(string: "https://p1.music.126.net/sheet/cumulative-2.png")!
                ]),
                cacheRoot: root
            )
            Issue.record("Cumulative decoded-pixel limit was ignored")
        } catch {
        }
        #expect(MusicSheetFixtureProtocol.requestCount == 2)
        #expect(cumulativeDecodeProbe.snapshot.count == 1)

        let paddedImage = try {
            var data = try fixturePNG(width: 2, height: 2)
            data.append(Data(count: MusicSheetWorker.maximumImageBytes - data.count))
            return data
        }()
        MusicSheetFixtureProtocol.reset { _, _ in .init(body: paddedImage) }
        do {
            _ = try await worker.preparePDF(
                sheetID: 17,
                preview: .images((0..<5).map {
                    URL(string: "https://p1.music.126.net/sheet/compressed-\($0).png")!
                }),
                cacheRoot: root
            )
            Issue.record("Cumulative compressed image limit was ignored")
        } catch {
        }
        #expect(MusicSheetFixtureProtocol.requestCount == 5)
        let deniedURL = URL(string: "https://example.com/sheet.pdf")!
        MusicSheetFixtureProtocol.reset { _, _ in .init(body: Data("%PDF-1.7\n%%EOF".utf8)) }
        do {
            _ = try await worker.preparePDF(sheetID: 13, preview: .pdf(deniedURL), cacheRoot: root)
            Issue.record("Disallowed host reached the sheet downloader")
        } catch EAPIError.invalidPayload {
        } catch {
            Issue.record("Disallowed host returned the wrong error: \(error)")
        }
        #expect(MusicSheetFixtureProtocol.requestCount == 0)

        MusicSheetFixtureProtocol.reset { _, _ in
            .init(body: Data(), redirectURL: deniedURL)
        }
        let redirectClock = ContinuousClock()
        let redirectStart = redirectClock.now
        do {
            _ = try await worker.preparePDF(sheetID: 14, preview: .pdf(url), cacheRoot: root)
            Issue.record("Disallowed redirect was installed")
        } catch {
        }
        #expect(redirectStart.duration(to: redirectClock.now) < .seconds(2))
        #expect(!MusicSheetURLPolicy.isAllowed(deniedURL))
        #expect(MusicSheetFixtureProtocol.requestCount == 1)
        #expect(await worker.cachedPDF(sheetID: 10, cacheRoot: root) == nil)
        #expect(await worker.cachedPDF(sheetID: 11, cacheRoot: root) == nil)
        #expect(await worker.cachedPDF(sheetID: 12, cacheRoot: root) == nil)
        #expect(await worker.cachedPDF(sheetID: 13, cacheRoot: root) == nil)
        #expect(await worker.cachedPDF(sheetID: 14, cacheRoot: root) == nil)
        #expect(await worker.cachedPDF(sheetID: 15, cacheRoot: root) == nil)
        #expect(await worker.cachedPDF(sheetID: 16, cacheRoot: root) == nil)
        #expect(await worker.cachedPDF(sheetID: 17, cacheRoot: root) == nil)
        #expect(await worker.cachedPDF(sheetID: 18, cacheRoot: root) == nil)
    }

    @Test("Style pagination stops cursor loops and duplicate-only pages")
    func stylePaginationProgress() {
        let first = MusicStylePage(items: [styleSong(1)], nextCursor: "A")
        let second = first.appending(MusicStylePage(items: [styleSong(2)], nextCursor: "B"))
        let loop = second.appending(MusicStylePage(items: [styleSong(3)], nextCursor: "A"))
        let duplicate = first.appending(MusicStylePage(items: [styleSong(1)], nextCursor: "B"))
        let empty = first.appending(MusicStylePage(items: [], nextCursor: "B"))

        #expect(second.items.map(\.id) == ["song-1", "song-2"])
        #expect(second.nextCursor == "B")
        #expect(loop.items.map(\.id) == ["song-1", "song-2", "song-3"])
        #expect(loop.nextCursor == nil)
        #expect(duplicate.nextCursor == nil)
        #expect(empty.nextCursor == nil)
    }

    @MainActor
    @Test("Style resource tasks re-enter after initial and load-more cancellation")
    func styleResourceTaskReentry() async throws {
        try await verifyStyleTaskReentry(firstSongResponse: nil, requestsBeforeSwitch: 1)
        try await verifyStyleTaskReentry(
            firstSongResponse: Data(#"{"code":200,"data":{"cursor":"next","songs":[{"id":1,"name":"Song","ar":[{"id":2,"name":"Artist"}],"al":{"id":3,"name":"Album"},"dt":1000}]}}"#.utf8),
            requestsBeforeSwitch: 2
        )
    }

    @Test("Song knowledge is concurrent, ordered, partial-success, and cancellation-safe")
    func combinedKnowledge() async throws {
        let wiki = [MusicKnowledgeBlock.text(id: "wiki", title: "Wiki", body: "W")]
        let brief = [MusicKnowledgeBlock.text(id: "brief", title: "Brief", body: "B")]
        let both = try await LiveMusicKnowledgeLibrary.combinedSongKnowledge(
            wiki: { wiki },
            brief: { brief }
        )
        #expect(both.map(\.id) == ["wiki", "brief"])

        let wikiOnly = try await LiveMusicKnowledgeLibrary.combinedSongKnowledge(
            wiki: { wiki },
            brief: { throw KnowledgeFixtureError.brief }
        )
        #expect(wikiOnly.map(\.id) == ["wiki"])

        let briefOnly = try await LiveMusicKnowledgeLibrary.combinedSongKnowledge(
            wiki: { throw KnowledgeFixtureError.wiki },
            brief: { brief }
        )
        #expect(briefOnly.map(\.id) == ["brief"])

        do {
            _ = try await LiveMusicKnowledgeLibrary.combinedSongKnowledge(
                wiki: { throw KnowledgeFixtureError.wiki },
                brief: { throw KnowledgeFixtureError.brief }
            )
            Issue.record("Two failed knowledge requests unexpectedly succeeded")
        } catch KnowledgeFixtureError.wiki {
        }

        let probe = CancellationProbe()
        do {
            _ = try await LiveMusicKnowledgeLibrary.combinedSongKnowledge(
                wiki: {
                    while !(await probe.hasEntered()) { await Task.yield() }
                    throw CancellationError()
                },
                brief: {
                    await probe.markEntered()
                    do {
                        try await Task.sleep(for: .seconds(60))
                        return brief
                    } catch {
                        await probe.markCancelled()
                        throw error
                    }
                }
            )
            Issue.record("Knowledge cancellation unexpectedly succeeded")
        } catch is CancellationError {
        }
        #expect(await eventually { await probe.wasCancelled() })
    }

    @Test("Annual report caps top lists and keeps one entry per month")
    func annualReportSemanticBounds() throws {
        let songs: [[String: Any]] = (1...8).map {
            ["songId": $0, "name": "Song \($0)"]
        }
        let singers: [[String: Any]] = (1...8).map {
            ["artistId": $0, "artistName": "Artist \($0)"]
        }
        let months: [[String: Any]] = (1...12).flatMap { month in
            [
                ["monthIndex": month, "playTime": -1],
                ["monthIndex": month, "playTime": month * 60],
                ["monthIndex": month, "playTime": month * 120]
            ]
        }
        let moods: [[String: Any]] = (1...12).flatMap { month in
            [
                ["playMonth": month, "moodTag": "空窗期"],
                ["playMonth": month, "moodTag": "Mood \(month)"],
                ["playMonth": month, "moodTag": "Duplicate \(month)"]
            ]
        }
        let root: [String: Any] = [
            "data": [
                "annualSinger": [
                    "singerName": "Annual Artist",
                    "artistId": 99,
                    "top5Songs": songs
                ],
                "newDiscoveryDTO": ["top5SingerDetails": singers],
                "monthListenDTO": ["monthListenItemList": months],
                "spiritDto": ["spiritItems": moods]
            ]
        ]

        let report = LiveMusicLibrary().decodeAnnualListeningReport(root, year: 2024)
        let annualSinger = try #require(report.sections.first { $0.id == "annual-singer" })
        let discoveries = try #require(report.sections.first { $0.id == "discoveries" })
        let monthlyListening = try #require(report.sections.first { $0.id == "months" })
        let monthlyMoods = try #require(report.sections.first { $0.id == "monthly-moods" })

        #expect(annualSinger.tracks.count == 5)
        #expect(discoveries.items.count == 5)
        #expect(monthlyListening.items.count == 12)
        #expect(Set(monthlyListening.items.map(\.id)).count == 12)
        #expect(monthlyMoods.items.count == 12)
        #expect(Set(monthlyMoods.items.map(\.id)).count == 12)
    }

    @MainActor
    @Test("Production footprint tasks cancel and stale finalizers cannot clear replacements")
    func footprintCancellationAndIdentity() async throws {
        let cursor = try #require(ListeningReport(
            period: .week,
            title: "Fixture",
            metrics: [],
            topSongs: [],
            previousEndTime: 1
        ).previousCursor)
        for reason in FootprintCancellationReason.allCases {
            let owner = FootprintLoadOwner()
            let context = FootprintTestContext(accountID: 7, credentialRevision: 11)
            let state = FootprintTestState()
            let gate = AsyncValueGate<FootprintPage>()
            state.begin(cursor: cursor)
            let task = startFootprintTask(
                owner: owner,
                context: context,
                state: state,
                gate: gate,
                cursor: cursor
            )
            await gate.waitUntilEntered()
            #expect(state.value.isLoading)
            #expect(state.value.pendingCursor == cursor)

            var parent: Task<Void, Never>?
            switch reason {
            case .parent:
                var parentStarted = false
                parent = Task { @MainActor in
                    parentStarted = true
                    await waitForFootprintLoad(task)
                }
                while !parentStarted { await Task.yield() }
                parent?.cancel()
            case .disappear, .account:
                owner.cancelAll()
                state.cancel()
            case .period:
                #expect(owner.cancel(.week))
                state.cancel()
            case .invalidation:
                owner.invalidate(.week)
                state.cancel()
            }
            await gate.release(footprintPage("cancelled"))
            await parent?.value
            await task.value
            #expect(!state.value.isLoading)
            #expect(state.value.pendingCursor == nil)
            #expect(state.acceptedTitles.isEmpty)
            #expect(!owner.hasTask(for: .week))
            #expect(await gate.observedCancellation)
        }

        let owner = FootprintLoadOwner()
        let context = FootprintTestContext(accountID: 7, credentialRevision: 11)
        let state = FootprintTestState()
        let oldestGate = AsyncValueGate<FootprintPage>()
        state.begin(cursor: nil)
        let oldest = startFootprintTask(owner: owner, context: context, state: state, gate: oldestGate)
        let oldestParent = Task { @MainActor in await waitForFootprintLoad(oldest) }
        await oldestGate.waitUntilEntered()

        context.accountID = 8
        let accountBGate = AsyncValueGate<FootprintPage>()
        state.begin(cursor: nil)
        let accountB = startFootprintTask(owner: owner, context: context, state: state, gate: accountBGate)
        await accountBGate.waitUntilEntered()

        context.accountID = 7
        let latestGate = AsyncValueGate<FootprintPage>()
        state.begin(cursor: nil)
        let latest = startFootprintTask(owner: owner, context: context, state: state, gate: latestGate)
        await latestGate.waitUntilEntered()

        oldestParent.cancel()
        await oldestGate.release(footprintPage("oldest-a"))
        await accountBGate.release(footprintPage("account-b"))
        await oldestParent.value
        await oldest.value
        await accountB.value
        #expect(owner.hasTask(for: .week))
        #expect(state.value.isLoading)
        #expect(state.acceptedTitles.isEmpty)

        await latestGate.release(footprintPage("latest-a"))
        await latest.value
        #expect(state.acceptedTitles == ["latest-a"])
        #expect(!state.value.isLoading)
        #expect(!owner.hasTask(for: .week))
    }

    @MainActor
    @Test("Footprint credential rotation fences success and failure before one replacement")
    func footprintCredentialRevisionFence() async {
        for oldResult in [FootprintLoadResult.success(footprintPage("stale")), .failure] {
            let owner = FootprintLoadOwner()
            let context = FootprintTestContext(accountID: 7, credentialRevision: 11)
            let state = FootprintTestState()
            let oldGate = AsyncValueGate<FootprintLoadResult>()
            state.begin(cursor: nil)
            let old = startFootprintTask(
                owner: owner,
                context: context,
                state: state,
                load: {
                    state.requestCount += 1
                    return try await oldGate.wait().get()
                }
            )
            await oldGate.waitUntilEntered()

            context.credentialRevision = 12
            await oldGate.release(oldResult)
            await old.value
            #expect(state.requestCount == 1)
            #expect(state.acceptedTitles.isEmpty)
            #expect(state.value.error == nil)
            #expect(!state.value.isLoading)
            #expect(!owner.hasTask(for: .week))

            let replacementGate = AsyncValueGate<FootprintLoadResult>()
            state.begin(cursor: nil)
            let replacement = startFootprintTask(
                owner: owner,
                context: context,
                state: state,
                load: {
                    state.requestCount += 1
                    return try await replacementGate.wait().get()
                }
            )
            await replacementGate.waitUntilEntered()
            await replacementGate.release(.success(footprintPage("current")))
            await replacement.value
            #expect(state.requestCount == 2)
            #expect(state.acceptedTitles == ["current"])
            #expect(!state.value.isLoading)
            #expect(!owner.hasTask(for: .week))
        }
    }

    @MainActor
    @Test("Visible and hidden history events use production task ownership for one follow-up")
    func footprintHistoryEventMerge() async throws {
        for period in [ListeningReportPeriod.week, .month] {
            let gate = AsyncTestGate()
            let probe = FootprintRequestProbe(period: period, gate: gate)
            let viewPeriod = period == .week ? FootprintPeriod.week : .month
            let owner = FootprintLoadOwner()
            let context = FootprintTestContext(accountID: 7, credentialRevision: 9)
            let state = FootprintHistoryTestState()
            state.refresh.setVisible(true)
            state.refresh.consume(
                PlaybackHistoryEvent(sequence: 1, credentialRevision: 9, kind: .song),
                credentialRevision: 9,
                hasAccount: true
            )
            let firstSequence = try #require(state.refresh.nextSequence(
                for: viewPeriod,
                isLoading: false,
                hasAccount: true
            ))
            state.period.begin(cursor: nil)
            let first = owner.start(
                period: viewPeriod,
                accountID: context.accountID,
                credentialRevision: context.credentialRevision,
                currentAccountID: { context.accountID },
                currentCredentialRevision: { context.credentialRevision },
                load: { try await probe.load().page },
                success: { _, _ in state.refresh.settle(viewPeriod, sequence: firstSequence) },
                failure: { _, _ in state.refresh.settle(viewPeriod, sequence: firstSequence) },
                finish: { _ in state.period.cancel() }
            )
            #expect(await eventually { await probe.counts == RequestCounts(report: 1, rank: 1, realtime: 1) })

            state.refresh.consume(
                PlaybackHistoryEvent(sequence: 2, credentialRevision: 9, kind: .song),
                credentialRevision: 9,
                hasAccount: true
            )
            state.refresh.consume(
                PlaybackHistoryEvent(sequence: 3, credentialRevision: 9, kind: .podcast),
                credentialRevision: 9,
                hasAccount: true
            )
            #expect(state.refresh.nextSequence(
                for: viewPeriod,
                isLoading: state.period.isLoading,
                hasAccount: true
            ) == nil)
            await gate.release()
            await first.value

            let latest = try #require(state.refresh.nextSequence(
                for: viewPeriod,
                isLoading: false,
                hasAccount: true
            ))
            #expect(latest == 3)
            state.period.begin(cursor: nil)
            let second = owner.start(
                period: viewPeriod,
                accountID: context.accountID,
                credentialRevision: context.credentialRevision,
                currentAccountID: { context.accountID },
                currentCredentialRevision: { context.credentialRevision },
                load: { try await probe.load().page },
                success: { _, _ in state.refresh.settle(viewPeriod, sequence: latest) },
                failure: { _, _ in state.refresh.settle(viewPeriod, sequence: latest) },
                finish: { _ in state.period.cancel() }
            )
            await second.value
            #expect(await probe.counts == RequestCounts(report: 2, rank: 2, realtime: 2))
            #expect(!state.period.isLoading)
            #expect(!owner.hasTask(for: viewPeriod))
        }

        let hiddenGate = AsyncTestGate()
        let hiddenProbe = FootprintRequestProbe(period: .week, gate: hiddenGate)
        let hiddenOwner = FootprintLoadOwner()
        let hiddenContext = FootprintTestContext(accountID: 7, credentialRevision: 2)
        let hiddenState = FootprintHistoryTestState()
        hiddenState.refresh.consume(
            PlaybackHistoryEvent(sequence: 4, credentialRevision: 2, kind: .song),
            credentialRevision: 2,
            hasAccount: true
        )
        hiddenState.refresh.consume(
            PlaybackHistoryEvent(sequence: 5, credentialRevision: 2, kind: .song),
            credentialRevision: 2,
            hasAccount: true
        )
        #expect(hiddenState.refresh.nextSequence(for: .week, isLoading: false, hasAccount: true) == nil)
        hiddenState.refresh.setVisible(true)
        let hiddenSequence = try #require(hiddenState.refresh.nextSequence(
            for: .week,
            isLoading: false,
            hasAccount: true
        ))
        #expect(hiddenSequence == 5)
        hiddenState.period.begin(cursor: nil)
        let hiddenTask = hiddenOwner.start(
            period: .week,
            accountID: hiddenContext.accountID,
            credentialRevision: hiddenContext.credentialRevision,
            currentAccountID: { hiddenContext.accountID },
            currentCredentialRevision: { hiddenContext.credentialRevision },
            load: { try await hiddenProbe.load().page },
            success: { _, _ in hiddenState.refresh.settle(.week, sequence: hiddenSequence) },
            failure: { _, _ in hiddenState.refresh.settle(.week, sequence: hiddenSequence) },
            finish: { _ in hiddenState.period.cancel() }
        )
        #expect(await eventually {
            await hiddenProbe.counts == RequestCounts(report: 1, rank: 1, realtime: 1)
        })
        await hiddenGate.release()
        await hiddenTask.value
        #expect(await hiddenProbe.counts == RequestCounts(report: 1, rank: 1, realtime: 1))

        let mismatchProbe = FootprintRequestProbe(period: .week, gate: AsyncTestGate())
        let mismatched = FootprintHistoryTestState()
        mismatched.refresh.setVisible(true)
        mismatched.refresh.consume(
            PlaybackHistoryEvent(sequence: 1, credentialRevision: 8, kind: .song),
            credentialRevision: 9,
            hasAccount: true
        )
        #expect(mismatched.refresh.nextSequence(for: .week, isLoading: false, hasAccount: true) == nil)
        #expect(await mismatchProbe.counts == RequestCounts())
    }

    @MainActor
    @Test("Annual production loader publishes base before enrichment and fences replacements")
    func annualReportPhases() async throws {
        let footprints = [
            YearListeningFootprint(year: 2025, playCount: 10, durationSeconds: 20),
            YearListeningFootprint(year: 2024, playCount: 9, durationSeconds: 18)
        ]
        #expect(AnnualReportSelection.defaultYear(current: nil, footprints: footprints) == 2025)
        #expect(AnnualReportSelection.defaultYear(
            current: nil,
            footprints: Array(footprints.reversed())
        ) == 2025)
        #expect(!AnnualListeningReportDecoder.supportedYears.contains(2025))

        let counts = AnnualRequestCounts()
        let loader = AnnualReportLoader()
        let credential = AnnualCredentialContext()
        let unsupported = loader.start(
            year: 2025,
            accountID: 1,
            credentialRevision: credential.revision,
            reload: 0,
            canLoad: false,
            currentYear: { 2025 },
            currentAccountID: { 1 },
            currentCredentialRevision: { credential.revision },
            report: { year, force in
                await counts.recordReport(year: year, force: force)
                return annualReport(year: year, song: annualSong(1, name: "unsupported"))
            },
            songs: { ids in
                await counts.recordSongs(ids)
                return []
            }
        )
        #expect(unsupported == nil)
        #expect(!loader.state.isLoading)
        #expect(await counts.reportRequests.isEmpty)
        #expect(await counts.songRequests.isEmpty)

        let context = AnnualCredentialContext()
        let contextLoader = AnnualReportLoader()
        let yearGate = AsyncValueGate<AnnualListeningReport>()
        let yearTask = contextLoader.start(
            year: 2024,
            accountID: 1,
            credentialRevision: context.revision,
            reload: 0,
            canLoad: true,
            currentYear: { context.year },
            currentAccountID: { context.accountID },
            currentCredentialRevision: { context.revision },
            report: { _, _ in await yearGate.wait() },
            songs: { _ in [] }
        )
        let staleYear = try #require(yearTask)
        await yearGate.waitUntilEntered()
        context.year = 2023
        await yearGate.release(annualReport(
            year: 2024,
            song: annualSong(12, name: "year-stale", complete: true)
        ))
        await staleYear.value
        #expect(contextLoader.state.report == nil)
        #expect(!contextLoader.state.isLoading)
        #expect(!contextLoader.hasTask)

        context.year = 2024
        let accountGate = AsyncValueGate<AnnualListeningReport>()
        let accountTask = contextLoader.start(
            year: 2024,
            accountID: 1,
            credentialRevision: context.revision,
            reload: 0,
            canLoad: true,
            currentYear: { context.year },
            currentAccountID: { context.accountID },
            currentCredentialRevision: { context.revision },
            report: { _, _ in await accountGate.wait() },
            songs: { _ in [] }
        )
        let staleAccount = try #require(accountTask)
        await accountGate.waitUntilEntered()
        context.accountID = 2
        await accountGate.release(annualReport(
            year: 2024,
            song: annualSong(13, name: "account-stale", complete: true)
        ))
        await staleAccount.value
        #expect(contextLoader.state.report == nil)
        #expect(!contextLoader.state.isLoading)
        #expect(!contextLoader.hasTask)

        let base = annualReport(year: 2024, song: annualSong(1, name: "base"))
        let songGate = AsyncValueGate<[Song]>()
        let firstTask = loader.start(
            year: 2024,
            accountID: 1,
            credentialRevision: credential.revision,
            reload: 0,
            canLoad: true,
            currentYear: { 2024 },
            currentAccountID: { 1 },
            currentCredentialRevision: { credential.revision },
            report: { year, force in
                await counts.recordReport(year: year, force: force)
                return base
            },
            songs: { ids in
                await counts.recordSongs(ids)
                return await songGate.wait()
            }
        )
        let first = try #require(firstTask)
        await songGate.waitUntilEntered()
        #expect(loader.state.report == base)
        #expect(!loader.state.isLoading)
        #expect(loader.hasTask)
        #expect(await counts.reportRequests == [AnnualReportRequest(year: 2024, force: false)])
        #expect(await counts.songRequests == [[1]])

        await songGate.release([annualSong(1, name: "enriched", complete: true)])
        await first.value
        #expect(loader.state.report?.sections.first?.tracks.first?.song.name == "enriched")
        #expect(!loader.hasTask)

        let refreshFailure = loader.start(
            year: 2024,
            accountID: 1,
            credentialRevision: credential.revision,
            reload: 1,
            canLoad: true,
            currentYear: { 2024 },
            currentAccountID: { 1 },
            currentCredentialRevision: { credential.revision },
            report: { _, _ in throw KnowledgeFixtureError.wiki },
            songs: { _ in [] }
        )
        await refreshFailure?.value
        #expect(loader.state.report?.sections.first?.tracks.first?.song.name == "enriched")
        #expect(loader.state.error != nil)
        #expect(!loader.state.isLoading)

        let failureBase = annualReport(year: 2024, song: annualSong(2, name: "failure-base"))
        let failedTask = loader.start(
            year: 2024,
            accountID: 1,
            credentialRevision: credential.revision,
            reload: 2,
            canLoad: true,
            currentYear: { 2024 },
            currentAccountID: { 1 },
            currentCredentialRevision: { credential.revision },
            report: { _, _ in failureBase },
            songs: { _ in throw KnowledgeFixtureError.brief }
        )
        let failed = try #require(failedTask)
        await failed.value
        #expect(loader.state.report == failureBase)
        #expect(loader.state.error == nil)
        #expect(loader.state.enrichmentError != nil)

        let staleGate = AsyncValueGate<[Song]>()
        let staleBase = annualReport(year: 2024, song: annualSong(3, name: "stale"))
        let staleTask = loader.start(
            year: 2024,
            accountID: 1,
            credentialRevision: credential.revision,
            reload: 3,
            canLoad: true,
            currentYear: { 2024 },
            currentAccountID: { 1 },
            currentCredentialRevision: { credential.revision },
            report: { _, _ in staleBase },
            songs: { _ in await staleGate.wait() }
        )
        let stale = try #require(staleTask)
        await staleGate.waitUntilEntered()
        let replacementGate = AsyncValueGate<[Song]>()
        let current = annualReport(year: 2023, song: annualSong(4, name: "current"))
        let replacementTask = loader.start(
            year: 2023,
            accountID: 1,
            credentialRevision: credential.revision,
            reload: 3,
            canLoad: true,
            currentYear: { 2023 },
            currentAccountID: { 1 },
            currentCredentialRevision: { credential.revision },
            report: { _, _ in current },
            songs: { _ in await replacementGate.wait() }
        )
        let replacement = try #require(replacementTask)
        await replacementGate.waitUntilEntered()
        #expect(loader.state.report == current)
        #expect(loader.hasTask)

        await staleGate.release([annualSong(3, name: "late", complete: true)])
        await stale.value
        #expect(loader.state.report == current)
        #expect(!loader.state.isLoading)
        #expect(loader.hasTask)

        await replacementGate.release([annualSong(4, name: "current-enriched", complete: true)])
        await replacement.value
        #expect(loader.state.report?.sections.first?.tracks.first?.song.name == "current-enriched")
        #expect(!loader.hasTask)

        let accountStaleGate = AsyncValueGate<[Song]>()
        let accountStaleTask = loader.start(
            year: 2023,
            accountID: 1,
            credentialRevision: credential.revision,
            reload: 3,
            canLoad: true,
            currentYear: { 2023 },
            currentAccountID: { 1 },
            currentCredentialRevision: { credential.revision },
            report: { _, _ in annualReport(year: 2023, song: annualSong(8, name: "account-stale")) },
            songs: { _ in await accountStaleGate.wait() }
        )
        let accountStale = try #require(accountStaleTask)
        await accountStaleGate.waitUntilEntered()
        let accountCurrentGate = AsyncValueGate<[Song]>()
        let accountCurrent = annualReport(year: 2023, song: annualSong(9, name: "account-current"))
        let accountReplacementTask = loader.start(
            year: 2023,
            accountID: 2,
            credentialRevision: credential.revision,
            reload: 2,
            canLoad: true,
            currentYear: { 2023 },
            currentAccountID: { 2 },
            currentCredentialRevision: { credential.revision },
            report: { _, _ in accountCurrent },
            songs: { _ in await accountCurrentGate.wait() }
        )
        let accountReplacement = try #require(accountReplacementTask)
        await accountCurrentGate.waitUntilEntered()

        await accountStaleGate.release([annualSong(8, name: "account-late", complete: true)])
        await accountStale.value
        #expect(loader.state.report == accountCurrent)
        #expect(loader.hasTask)

        await accountCurrentGate.release([annualSong(9, name: "account-enriched", complete: true)])
        await accountReplacement.value
        #expect(loader.state.report?.sections.first?.tracks.first?.song.name == "account-enriched")
        #expect(!loader.hasTask)

        let reloadStaleGate = AsyncValueGate<[Song]>()
        let reloadStaleTask = loader.start(
            year: 2023,
            accountID: 2,
            credentialRevision: credential.revision,
            reload: 4,
            canLoad: true,
            currentYear: { 2023 },
            currentAccountID: { 2 },
            currentCredentialRevision: { credential.revision },
            report: { _, _ in annualReport(year: 2023, song: annualSong(5, name: "reload-stale")) },
            songs: { _ in await reloadStaleGate.wait() }
        )
        let reloadStale = try #require(reloadStaleTask)
        await reloadStaleGate.waitUntilEntered()

        let reloadCurrentGate = AsyncValueGate<[Song]>()
        let reloadCurrent = annualReport(year: 2023, song: annualSong(6, name: "reload-current"))
        let reloadCurrentTask = loader.start(
            year: 2023,
            accountID: 2,
            credentialRevision: credential.revision,
            reload: 5,
            canLoad: true,
            currentYear: { 2023 },
            currentAccountID: { 2 },
            currentCredentialRevision: { credential.revision },
            report: { _, _ in reloadCurrent },
            songs: { _ in await reloadCurrentGate.wait() }
        )
        let currentReload = try #require(reloadCurrentTask)
        await reloadCurrentGate.waitUntilEntered()

        await reloadStaleGate.release([annualSong(5, name: "reload-late", complete: true)])
        await reloadStale.value
        #expect(loader.state.report == reloadCurrent)
        #expect(loader.hasTask)

        await reloadCurrentGate.release([annualSong(6, name: "reload-enriched", complete: true)])
        await currentReload.value
        #expect(loader.state.report?.sections.first?.tracks.first?.song.name == "reload-enriched")
        #expect(!loader.hasTask)

        let staleRevisionGate = AsyncValueGate<AnnualListeningReport>()
        let staleRevisionReport = annualReport(
            year: 2023,
            song: annualSong(10, name: "revision-stale", complete: true)
        )
        let staleRevisionOptional = loader.start(
            year: 2023,
            accountID: 2,
            credentialRevision: credential.revision,
            reload: 5,
            canLoad: true,
            currentYear: { 2023 },
            currentAccountID: { 2 },
            currentCredentialRevision: { credential.revision },
            report: { _, _ in await staleRevisionGate.wait() },
            songs: { _ in [] }
        )
        let staleRevisionTask = try #require(staleRevisionOptional)
        await staleRevisionGate.waitUntilEntered()
        credential.revision &+= 1
        await staleRevisionGate.release(staleRevisionReport)
        await staleRevisionTask.value
        #expect(loader.state.report?.sections.first?.tracks.first?.song.name == "reload-enriched")
        #expect(!loader.state.isLoading)
        #expect(!loader.hasTask)

        let currentRevisionReport = annualReport(
            year: 2023,
            song: annualSong(11, name: "revision-current", complete: true)
        )
        let currentRevisionOptional = loader.start(
            year: 2023,
            accountID: 2,
            credentialRevision: credential.revision,
            reload: 5,
            canLoad: true,
            currentYear: { 2023 },
            currentAccountID: { 2 },
            currentCredentialRevision: { credential.revision },
            report: { _, _ in currentRevisionReport },
            songs: { _ in [] }
        )
        let currentRevisionTask = try #require(currentRevisionOptional)
        await currentRevisionTask.value
        #expect(loader.state.report == currentRevisionReport)
        #expect(!loader.state.isLoading)

        let cancellationGate = AsyncValueGate<[Song]>()
        let cancellationBase = annualReport(year: 2024, song: annualSong(7, name: "cancel-base"))
        let cancelledTask = loader.start(
            year: 2024,
            accountID: 2,
            credentialRevision: credential.revision,
            reload: 6,
            canLoad: true,
            currentYear: { 2024 },
            currentAccountID: { 2 },
            currentCredentialRevision: { credential.revision },
            report: { _, _ in cancellationBase },
            songs: { _ in await cancellationGate.wait() }
        )
        let cancelled = try #require(cancelledTask)
        await cancellationGate.waitUntilEntered()
        loader.cancel()
        await cancellationGate.release([annualSong(7, name: "late-cancel", complete: true)])
        await cancelled.value
        #expect(loader.state.report == cancellationBase)
        #expect(loader.state.error == nil)
        #expect(!loader.state.isLoading)
        #expect(!loader.hasTask)
        #expect(await cancellationGate.observedCancellation)
    }
}

private struct RequestCounts: Equatable, Sendable {
    var report = 0
    var rank = 0
    var realtime = 0
}

private actor AsyncTestGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        isOpen = true
        let current = waiters
        waiters = []
        current.forEach { $0.resume() }
    }
}

private actor FootprintRequestProbe {
    private let period: ListeningReportPeriod
    private let gate: AsyncTestGate
    private(set) var counts = RequestCounts()

    init(period: ListeningReportPeriod, gate: AsyncTestGate) {
        self.period = period
        self.gate = gate
    }

    func load() async throws -> FootprintSources {
        try await loadFootprintSources(
            cursor: nil,
            report: { await self.report() },
            ranks: { await self.ranks() },
            realtime: { await self.realtime() }
        )
    }

    private func report() async -> ListeningReport {
        counts.report += 1
        await gate.wait()
        return ListeningReport(period: period, title: "Fixture", metrics: [], topSongs: [], previousEndTime: nil)
    }

    private func ranks() async -> [ListeningRankEntry] {
        counts.rank += 1
        await gate.wait()
        return []
    }

    private func realtime() async -> ListeningReport {
        counts.realtime += 1
        await gate.wait()
        return ListeningReport(period: period, title: "Realtime", metrics: [], topSongs: [], previousEndTime: nil)
    }
}

@MainActor
private final class FootprintTestContext {
    var accountID: Int64
    var credentialRevision: UInt64

    init(accountID: Int64, credentialRevision: UInt64) {
        self.accountID = accountID
        self.credentialRevision = credentialRevision
    }
}

@MainActor
private final class AnnualCredentialContext {
    var year: Int? = 2024
    var accountID: Int64? = 1
    var revision: UInt64 = 1
}

@MainActor
private final class FootprintTestState {
    var value = FootprintPeriodState()
    var acceptedTitles: [String] = []
    var requestCount = 0

    func begin(cursor: ListeningReportCursor?) { value.begin(cursor: cursor) }
    func cancel() { value.cancel() }

    func accept(_ page: FootprintPage) {
        acceptedTitles.append(page.title)
        value.pages = [page]
        value.cancel()
        value.error = nil
    }

    func fail(_ error: Error) {
        value.fail(cursor: value.pendingCursor, message: error.localizedDescription)
    }
}

@MainActor
private final class FootprintHistoryTestState {
    var period = FootprintPeriodState()
    var refresh = FootprintHistoryRefreshState()
}

private enum FootprintCancellationReason: CaseIterable {
    case parent
    case disappear
    case period
    case account
    case invalidation
}

private enum FootprintLoadResult: Sendable {
    case success(FootprintPage)
    case failure

    func get() throws -> FootprintPage {
        switch self {
        case let .success(page): page
        case .failure: throw FootprintTestError.failed
        }
    }
}

private enum FootprintTestError: Error {
    case failed
}

@MainActor
private func startFootprintTask(
    owner: FootprintLoadOwner,
    context: FootprintTestContext,
    state: FootprintTestState,
    gate: AsyncValueGate<FootprintPage>,
    cursor: ListeningReportCursor? = nil
) -> Task<Void, Never> {
    startFootprintTask(
        owner: owner,
        context: context,
        state: state,
        load: { await gate.wait() }
    )
}

@MainActor
private func startFootprintTask(
    owner: FootprintLoadOwner,
    context: FootprintTestContext,
    state: FootprintTestState,
    load: @escaping @MainActor @Sendable () async throws -> FootprintPage
) -> Task<Void, Never> {
    owner.start(
        period: .week,
        accountID: context.accountID,
        credentialRevision: context.credentialRevision,
        currentAccountID: { context.accountID },
        currentCredentialRevision: { context.credentialRevision },
        load: load,
        success: { page, _ in state.accept(page) },
        failure: { error, _ in state.fail(error) },
        finish: { _ in state.cancel() }
    )
}

private actor AsyncValueGate<Value: Sendable> {
    private var entered = false
    private(set) var observedCancellation = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var valueWaiters: [CheckedContinuation<Value, Never>] = []
    private var releasedValue: Value?

    func wait() async -> Value {
        entered = true
        let enteredWaiters = entryWaiters
        entryWaiters = []
        enteredWaiters.forEach { $0.resume() }
        let value = if let releasedValue {
            releasedValue
        } else {
            await withCheckedContinuation { valueWaiters.append($0) }
        }
        observedCancellation = Task.isCancelled
        return value
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }

    func release(_ value: Value) {
        releasedValue = value
        let waiters = valueWaiters
        valueWaiters = []
        waiters.forEach { $0.resume(returning: value) }
    }
}

private struct AnnualReportRequest: Equatable, Sendable {
    let year: Int
    let force: Bool
}

private actor AnnualRequestCounts {
    private(set) var reportRequests: [AnnualReportRequest] = []
    private(set) var songRequests: [[Int64]] = []

    func recordReport(year: Int, force: Bool) {
        reportRequests.append(AnnualReportRequest(year: year, force: force))
    }

    func recordSongs(_ ids: [Int64]) { songRequests.append(ids) }
}

private func footprintPage(_ title: String) -> FootprintPage {
    FootprintPage(
        cursor: nil,
        title: title,
        metrics: [],
        ranks: [],
        yearFootprints: [],
        previousCursor: nil
    )
}

private extension FootprintSources {
    var page: FootprintPage {
        FootprintPage(
            cursor: nil,
            title: report.title,
            metrics: report.metrics,
            ranks: ranks,
            yearFootprints: [],
            previousCursor: report.previousCursor
        )
    }
}

private func annualReport(year: Int, song: Song) -> AnnualListeningReport {
    AnnualListeningReport(
        year: year,
        overviewMetrics: [ListeningMetric(kind: .plays, value: .number(song.id))],
        sections: [AnnualReportSection(
            id: "fixture",
            title: "Fixture",
            subtitle: nil,
            artworkURL: nil,
            metrics: [],
            details: [],
            items: [],
            tracks: [AnnualReportTrack(id: "song-\(song.id)", song: song, caption: nil, playCount: nil)]
        )]
    )
}

private func annualSong(_ id: Int64, name: String, complete: Bool = false) -> Song {
    Song(
        id: id,
        name: name,
        artists: complete ? [ArtistSummary(id: id, name: "Artist")] : [],
        album: AlbumSummary(
            id: id,
            name: "Album",
            artwork: Artwork(
                symbol: "music.note",
                accent: .red,
                remoteURL: complete ? URL(string: "https://p1.music.126.net/fixture.jpg") : nil
            )
        ),
        duration: .seconds(1)
    )
}

private func fixtureWorker(
    temporaryRoot: URL,
    maximumCumulativePixels: Int? = nil,
    heavyWorkStarted: (@Sendable () -> Void)? = nil,
    imageDecodeStarted: (@Sendable () -> Void)? = nil
) -> MusicSheetWorker {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [MusicSheetFixtureProtocol.self]
    return MusicSheetWorker(
        temporaryRoot: temporaryRoot,
        sessionConfiguration: configuration,
        maximumCumulativePixels: maximumCumulativePixels,
        heavyWorkStarted: heavyWorkStarted,
        imageDecodeStarted: imageDecodeStarted
    )
}

private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(
        path: "TinyCloudMusicTests.\(UUID().uuidString)",
        directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func temporaryFiles(at root: URL) -> [URL] {
    (try? FileManager.default.contentsOfDirectory(
        at: root,
        includingPropertiesForKeys: nil
    )) ?? []
}

private func fixturePNG(width: Int, height: Int) throws -> Data {
    guard let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ), let image = context.makeImage()
    else { throw KnowledgeFixtureError.brief }
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(
        data,
        "public.png" as CFString,
        1,
        nil
    ) else { throw KnowledgeFixtureError.brief }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw KnowledgeFixtureError.brief }
    return data as Data
}

private func styleSong(_ id: Int64) -> MusicStyleResource {
    .song(Song(
        id: id,
        name: "Song \(id)",
        artists: [],
        album: AlbumSummary(
            id: 1,
            name: "Album",
            artwork: Artwork(symbol: "music.note", accent: .red)
        ),
        duration: .seconds(1)
    ))
}

@MainActor
private func verifyStyleTaskReentry(
    firstSongResponse: Data?,
    requestsBeforeSwitch: Int
) async throws {
    let sequence = MusicStyleResponseSequence()
    let empty = Data(#"{"code":200,"data":{}}"#.utf8)
    MusicSheetFixtureProtocol.reset { request, _ in
        switch request.url?.path {
        case "/weapi/style-tag/home/song":
            let index = sequence.next()
            if index == 1, let firstSongResponse { return .init(body: firstSongResponse) }
            return .init(body: empty, blocked: true)
        case "/weapi/style-tag/home/album":
            return .init(body: empty)
        default:
            return .init(body: empty)
        }
    }
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [MusicSheetFixtureProtocol.self]
    let session = URLSession(configuration: configuration)
    let cacheRoot = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let player = PlayerController(
        repository: FixtureMusicRepository(),
        cacheRoot: cacheRoot,
        crossfadeDuration: 0
    )
    let hosting = NSHostingView(rootView: MusicStyleDetailView(
        styleID: 1,
        styleName: "Style",
        library: LiveMusicKnowledgeLibrary(transport: EAPITransport(session: session)),
        player: player,
        onOpenRoute: { _ in }
    ))
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
        styleMask: [.titled],
        backing: .buffered,
        defer: false
    )
    window.isReleasedWhenClosed = false
    window.contentView = hosting
    window.orderFrontRegardless()
    hosting.layoutSubtreeIfNeeded()
    defer {
        MusicSheetFixtureProtocol.releaseAll()
        window.close()
        session.invalidateAndCancel()
        try? FileManager.default.removeItem(at: cacheRoot)
    }

    #expect(await eventually {
        MusicSheetFixtureProtocol.requestCount(path: "/weapi/style-tag/home/song") == requestsBeforeSwitch
    })
    let picker = try #require(musicKnowledgeSubview(NSSegmentedControl.self, in: hosting))
    try selectMusicStyleSegment(1, in: picker)
    #expect(await eventually {
        MusicSheetFixtureProtocol.requestCount(path: "/weapi/style-tag/home/album") == 1
    })
    try selectMusicStyleSegment(0, in: picker)
    #expect(await eventually {
        MusicSheetFixtureProtocol.requestCount(path: "/weapi/style-tag/home/song") == requestsBeforeSwitch + 1
    })
}

private final class MusicStyleResponseSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func next() -> Int {
        lock.withLock {
            count += 1
            return count
        }
    }
}

@MainActor
private func selectMusicStyleSegment(_ segment: Int, in control: NSSegmentedControl) throws {
    let target = try #require(control.target)
    let action = try #require(control.action)
    control.selectedSegment = segment
    #expect(NSApp.sendAction(action, to: target, from: control))
}

@MainActor
private func musicKnowledgeSubview<View: NSView>(_ type: View.Type, in root: NSView) -> View? {
    if let match = root as? View { return match }
    for child in root.subviews {
        if let match = musicKnowledgeSubview(type, in: child) { return match }
    }
    return nil
}

private func expectPixelFailure(width: Int, height: Int) {
    do {
        _ = try MusicSheetWorker.validatedCumulativePixelCount(
            width: width,
            height: height,
            currentTotal: 0
        )
        Issue.record("Invalid pixel dimensions were accepted")
    } catch {
    }
}

private func eventually(
    timeout: Duration = .seconds(2),
    condition: @escaping @Sendable () async -> Bool
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
}
