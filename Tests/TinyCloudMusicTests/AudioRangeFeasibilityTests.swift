import AVFoundation
import Foundation
import Testing
import UniformTypeIdentifiers

@testable import TinyCloudMusic

private let feasibilityHTTPBlockSize = 512 * 1_024
private let feasibilityResponseChunkSize = 256 * 1_024
private let feasibilityETag = #""tcm-w00-flac""#

private enum FeasibilityStage: String {
    case generateFLAC = "generate_flac"
    case fileReady = "file_ready"
    case fileDuration = "file_duration"
    case fileSeek = "file_seek"
    case fixtureStart = "fixture_start"
    case ready
    case duration
    case seek
    case preroll
    case rangeLimit = "range_limit"
    case rangeRequestCoverage = "range_request_coverage"
    case nonRangeHead = "non_range_head"
    case nonRangeGet = "non_range_get"
    case nonRangeOther = "non_range_other"
    case contentLength = "content_length"
    case responseLimit = "response_limit"
    case payloadBudget = "payload_budget"
    case performanceBatch = "performance_batch_failed"
}

private struct FeasibilityFailure: Error, CustomStringConvertible {
    let stage: FeasibilityStage
    let bytes: Int
    let rangeCount: Int

    var description: String {
        "stage=\(stage.rawValue) bytes=\(bytes) ranges=\(rangeCount)"
    }
}

private final class FeasibilityCompletion<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: Value?

    func finish(_ value: Value) {
        lock.withLock {
            if storedValue == nil { storedValue = value }
        }
    }

    var value: Value? { lock.withLock { storedValue } }
}

private final class FeasibilityLoadingContext: @unchecked Sendable {
    let loadingRequest: AVAssetResourceLoadingRequest
    let identifier: ObjectIdentifier
    let endOffset: Int64?
    let needsData: Bool
    var offset: Int64
    var task: URLSessionDataTask?

    init?(_ loadingRequest: AVAssetResourceLoadingRequest) {
        self.loadingRequest = loadingRequest
        identifier = ObjectIdentifier(loadingRequest)

        guard let dataRequest = loadingRequest.dataRequest else {
            offset = 0
            endOffset = 1
            needsData = false
            return
        }

        offset = max(dataRequest.requestedOffset, dataRequest.currentOffset)
        needsData = true
        guard offset >= 0 else { return nil }

        if dataRequest.requestsAllDataToEndOfResource {
            endOffset = nil
        } else {
            let (end, overflow) = dataRequest.requestedOffset.addingReportingOverflow(
                Int64(dataRequest.requestedLength)
            )
            guard !overflow, end >= offset else { return nil }
            endOffset = end
        }
    }
}

private struct FeasibilityLoaderMetrics {
    var largestRequest = 0
    var largestHTTPResponse = 0
    var largestDataResponse = 0
    var completeLength: Int64?
}

private struct FeasibilityHTTPResult: @unchecked Sendable {
    let data: Data?
    let response: URLResponse?
    let error: Error?
}

private final class FeasibilityResourceLoaderDelegate: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "TinyCloudMusicTests.FeasibilityResourceLoader")

    private let sourceURL: URL
    private let session: URLSession
    private var contexts: [ObjectIdentifier: FeasibilityLoadingContext] = [:]
    private var expectedETag: String?
    private var metrics = FeasibilityLoaderMetrics()

    init(sourceURL: URL) {
        self.sourceURL = sourceURL
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        session = URLSession(configuration: configuration)
        super.init()
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        guard let context = FeasibilityLoadingContext(loadingRequest) else { return false }
        contexts[context.identifier] = context
        requestNextBlock(for: context)
        return true
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        didCancel loadingRequest: AVAssetResourceLoadingRequest
    ) {
        let identifier = ObjectIdentifier(loadingRequest)
        contexts.removeValue(forKey: identifier)?.task?.cancel()
    }

    func snapshot() -> FeasibilityLoaderMetrics { queue.sync { metrics } }

    func stop() {
        queue.sync {
            contexts.values.forEach { $0.task?.cancel() }
            contexts.removeAll()
        }
        session.invalidateAndCancel()
    }

    private func requestNextBlock(for context: FeasibilityLoadingContext) {
        guard contexts[context.identifier] === context else { return }
        if let endOffset = context.endOffset, context.offset >= endOffset {
            finish(context)
            return
        }
        if let completeLength = metrics.completeLength, context.offset >= completeLength {
            finish(context)
            return
        }

        let requestedCount = min(
            Int64(feasibilityHTTPBlockSize),
            context.endOffset.map { $0 - context.offset } ?? Int64(feasibilityHTTPBlockSize)
        )
        guard requestedCount > 0 else {
            finish(context)
            return
        }

        metrics.largestRequest = max(metrics.largestRequest, Int(requestedCount))
        var request = URLRequest(url: sourceURL)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 10
        request.setValue(
            "bytes=\(context.offset)-\(context.offset + requestedCount - 1)",
            forHTTPHeaderField: "Range"
        )
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")

        let task = session.dataTask(with: request) { [weak self, context] data, response, error in
            guard let self else { return }
            let result = FeasibilityHTTPResult(data: data, response: response, error: error)
            self.queue.async {
                self.handle(result, for: context)
            }
        }
        context.task = task
        task.resume()
    }

    private func handle(_ result: FeasibilityHTTPResult, for context: FeasibilityLoadingContext) {
        guard contexts[context.identifier] === context else { return }
        context.task = nil
        guard result.error == nil,
              let response = result.response as? HTTPURLResponse,
              let data = result.data
        else {
            fail(context)
            return
        }

        if response.statusCode == 416,
           case let .unsatisfied(completeLength)? = response
            .value(forHTTPHeaderField: "Content-Range")
            .flatMap(HTTPContentRange.init),
           context.offset >= completeLength,
           accept(completeLength: completeLength)
        {
            guard setContentInformation(for: context, completeLength: completeLength) else { return }
            finish(context)
            return
        }

        guard response.statusCode == 206,
              data.count <= feasibilityHTTPBlockSize,
              case let .bytes(range, completeLength)? = response
                .value(forHTTPHeaderField: "Content-Range")
                .flatMap(HTTPContentRange.init),
              range.lowerBound == context.offset,
              range.upperBound - range.lowerBound == Int64(data.count),
              accept(completeLength: completeLength),
              accept(etag: response.value(forHTTPHeaderField: "ETag"))
        else {
            fail(context)
            return
        }

        metrics.largestHTTPResponse = max(metrics.largestHTTPResponse, data.count)
        guard setContentInformation(for: context, completeLength: completeLength) else { return }
        guard context.needsData, let dataRequest = context.loadingRequest.dataRequest else {
            finish(context)
            return
        }

        for lowerBound in stride(from: 0, to: data.count, by: feasibilityResponseChunkSize) {
            let upperBound = min(data.count, lowerBound + feasibilityResponseChunkSize)
            let chunk = data.subdata(in: lowerBound..<upperBound)
            metrics.largestDataResponse = max(metrics.largestDataResponse, chunk.count)
            dataRequest.respond(with: chunk)
        }
        context.offset = dataRequest.currentOffset
        requestNextBlock(for: context)
    }

    private func setContentInformation(
        for context: FeasibilityLoadingContext,
        completeLength: Int64
    ) -> Bool {
        guard let information = context.loadingRequest.contentInformationRequest else { return true }
        let candidate = UTType(filenameExtension: "flac")
        let allowed = information.allowedContentTypes ?? []
        if allowed.isEmpty {
            information.contentType = candidate?.identifier ?? "org.xiph.flac"
        } else if let candidate,
                  let selected = allowed.first(where: { identifier in
                      candidate.identifier == identifier
                          || UTType(identifier).map { candidate.conforms(to: $0) } == true
                  })
        {
            information.contentType = selected
        } else {
            fail(context)
            return false
        }
        information.contentLength = completeLength
        information.isByteRangeAccessSupported = true
        return true
    }

    private func accept(completeLength: Int64) -> Bool {
        guard completeLength > 0 else { return false }
        if let existing = metrics.completeLength { return existing == completeLength }
        metrics.completeLength = completeLength
        return true
    }

    private func accept(etag: String?) -> Bool {
        guard let etag, Self.isStrongETag(etag) else { return false }
        if let expectedETag { return expectedETag == etag }
        expectedETag = etag
        return true
    }

    private static func isStrongETag(_ value: String) -> Bool {
        let bytes = Array(value.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
        guard bytes.count >= 2, bytes.first == 0x22, bytes.last == 0x22 else { return false }
        return bytes.dropFirst().dropLast().allSatisfy {
            $0 == 0x21 || (0x23...0x7E).contains($0) || $0 >= 0x80
        }
    }

    private func finish(_ context: FeasibilityLoadingContext) {
        guard contexts.removeValue(forKey: context.identifier) != nil else { return }
        context.loadingRequest.finishLoading()
    }

    private func fail(_ context: FeasibilityLoadingContext) {
        guard contexts.removeValue(forKey: context.identifier) != nil else { return }
        context.task?.cancel()
        context.loadingRequest.finishLoading(with: NSError(
            domain: "TinyCloudMusicTests.AudioRangeFeasibility",
            code: 1
        ))
    }
}

private final class FeasibilityCustomAsset {
    let asset: AVURLAsset
    let loaderDelegate: FeasibilityResourceLoaderDelegate

    init(sourceURL: URL, precise: Bool) {
        loaderDelegate = FeasibilityResourceLoaderDelegate(sourceURL: sourceURL)
        let customURL = URL(string: "tcm-feasibility://resource/\(UUID().uuidString).flac")!
        asset = AVURLAsset(
            url: customURL,
            options: [AVURLAssetPreferPreciseDurationAndTimingKey: precise]
        )
        asset.resourceLoader.setDelegate(loaderDelegate, queue: loaderDelegate.queue)
    }
}

private struct GeneratedFLAC: Sendable {
    let url: URL
    let data: Data
    let expectedDuration: Double
}

private func generateFLAC(in root: URL) throws -> GeneratedFLAC {
    let sampleRate = 44_100.0
    let duration = 12.0
    let frameCount = Int64(sampleRate * duration)
    let url = root.appendingPathComponent("feasibility.flac")
    let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatFLAC,
        AVSampleRateKey: sampleRate,
        AVNumberOfChannelsKey: 2,
    ]

    try autoreleasepool {
        let file = try AVAudioFile(forWriting: url, settings: settings)
        let capacity: AVAudioFrameCount = 8_192
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat,
            frameCapacity: capacity
        ), let channels = buffer.floatChannelData else {
            throw FeasibilityFailure(stage: .generateFLAC, bytes: 0, rangeCount: 0)
        }

        var generated: Int64 = 0
        var randomState: UInt32 = 0xC0FFEE
        while generated < frameCount {
            let frames = min(Int64(capacity), frameCount - generated)
            buffer.frameLength = AVAudioFrameCount(frames)
            for frame in 0..<Int(frames) {
                let sampleIndex = generated + Int64(frame)
                let tone = Float(sin(2 * Double.pi * 440 * Double(sampleIndex) / sampleRate) * 0.08)
                for channel in 0..<2 {
                    randomState = randomState &* 1_664_525 &+ 1_013_904_223
                    let noise = Float(Int32(bitPattern: randomState)) / Float(Int32.max) * 0.35
                    channels[channel][frame * buffer.stride] = tone + noise
                }
            }
            try file.write(from: buffer)
            generated += frames
        }
    }

    let data = try Data(contentsOf: url)
    guard data.count > feasibilityHTTPBlockSize,
          data.starts(with: Data("fLaC".utf8))
    else {
        throw FeasibilityFailure(stage: .generateFLAC, bytes: data.count, rangeCount: 0)
    }
    return GeneratedFLAC(url: url, data: data, expectedDuration: duration)
}

private enum FeasibilityBranch: String, CaseIterable, Hashable {
    case directPrecise = "direct-precise-true"
    case customPrecise = "custom-precise-true"
    case customDiagnostic = "custom-precise-false"

    var usesCustomLoader: Bool { self != .directPrecise }
    var precise: Bool { self != .customDiagnostic }
}

private struct FeasibilityRunMetrics {
    let branch: FeasibilityBranch
    let readySeconds: Double
    let readyPayload: Int
    let seekSeconds: Double
    let seekError: Double
    let seekPayload: Int
    let prerollSeconds: Double
    let prerollPayload: Int
    let durationError: Double
    let requestCount: Int
    let uniqueRanges: Int
    let duplicateRanges: Int
    let incompleteTransportCount: Int

    var totalSeconds: Double { readySeconds + seekSeconds + prerollSeconds }
    var totalPayload: Int { readyPayload + seekPayload + prerollPayload }
}

private struct FeasibilityRequestMetrics {
    let requestCount: Int
    let rangeCount: Int
    let uniqueRanges: Int
    let duplicateRanges: Int
    let nonRangeHEADCount: Int
    let nonRangeGETCount: Int
    let nonRangeOtherCount: Int
    let incompleteTransportCount: Int
}

private func requestMetrics(_ requests: [String]) -> FeasibilityRequestMetrics {
    let completeRequests = requests.filter { $0.contains("\r\n\r\n") }
    let ranges = completeRequests.compactMap { request in
        request.components(separatedBy: "\r\n")
            .first(where: { $0.lowercased().hasPrefix("range:") })?
            .dropFirst("range:".count)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    let nonRangeMethods = completeRequests.compactMap { request -> String? in
        guard !request.components(separatedBy: "\r\n")
            .contains(where: { $0.lowercased().hasPrefix("range:") })
        else { return nil }
        return request.split(separator: " ", maxSplits: 1).first.map(String.init)
    }
    let uniqueRanges = Set(ranges).count
    return FeasibilityRequestMetrics(
        requestCount: completeRequests.count,
        rangeCount: ranges.count,
        uniqueRanges: uniqueRanges,
        duplicateRanges: ranges.count - uniqueRanges,
        nonRangeHEADCount: nonRangeMethods.count { $0 == "HEAD" },
        nonRangeGETCount: nonRangeMethods.count { $0 == "GET" },
        nonRangeOtherCount: nonRangeMethods.count { $0 != "HEAD" && $0 != "GET" },
        incompleteTransportCount: requests.count - completeRequests.count
    )
}

private func flacResponse(for request: Data, body: Data) -> Data {
    let text = String(decoding: request, as: UTF8.self)
    let commonHeaders = [
        "Accept-Ranges": "bytes",
        "Content-Type": "audio/flac",
        "ETag": feasibilityETag,
    ]
    if text.hasPrefix("HEAD ") {
        return fixtureHTTPResponse(
            "200 OK",
            headers: commonHeaders.merging(["Content-Length": String(body.count)]) { current, _ in current }
        )
    }

    guard let header = text.components(separatedBy: "\r\n")
        .first(where: { $0.lowercased().hasPrefix("range:") })
    else {
        return fixtureHTTPResponse("200 OK", headers: commonHeaders, body: body)
    }
    let value = header.dropFirst("range:".count).trimmingCharacters(in: .whitespacesAndNewlines)
    guard let range = parsedRange(value, length: body.count) else {
        return fixtureHTTPResponse(
            "416 Range Not Satisfiable",
            headers: commonHeaders.merging(["Content-Range": "bytes */\(body.count)"]) { current, _ in current }
        )
    }
    return fixtureHTTPResponse(
        "206 Partial Content",
        headers: commonHeaders.merging([
            "Content-Range": "bytes \(range.lowerBound)-\(range.upperBound - 1)/\(body.count)",
        ]) { current, _ in current },
        body: body.subdata(in: range)
    )
}

private func parsedRange(_ header: String, length: Int) -> Range<Int>? {
    guard length > 0, header.lowercased().hasPrefix("bytes="), !header.contains(",") else { return nil }
    let bounds = header.dropFirst("bytes=".count).split(
        separator: "-",
        maxSplits: 1,
        omittingEmptySubsequences: false
    )
    guard bounds.count == 2 else { return nil }

    if bounds[0].isEmpty, let suffix = Int(bounds[1]), suffix > 0 {
        return max(0, length - suffix)..<length
    }
    guard let lower = Int(bounds[0]), lower >= 0, lower < length else { return nil }
    let upper: Int
    if bounds[1].isEmpty {
        upper = length - 1
    } else if let requestedUpper = Int(bounds[1]), requestedUpper >= lower {
        upper = min(requestedUpper, length - 1)
    } else {
        return nil
    }
    return lower..<(upper + 1)
}

private func durationSeconds(_ duration: Duration) -> Double {
    let components = duration.components
    return Double(components.seconds) + Double(components.attoseconds) / 1_000_000_000_000_000_000
}

@MainActor
private func waitUntilReady(
    _ item: AVPlayerItem,
    stage: FeasibilityStage,
    fixture: LocalHTTPFixture?
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(15))
    while item.status == .unknown, clock.now < deadline {
        do {
            try await Task.sleep(for: .milliseconds(10))
        } catch {
            throw FeasibilityFailure(
                stage: stage,
                bytes: fixture?.responsePayloadBytes ?? 0,
                rangeCount: fixture.map { requestMetrics($0.requests).rangeCount } ?? 0
            )
        }
    }
    guard item.status == .readyToPlay else {
        let requests = fixture.map { requestMetrics($0.requests) }
        throw FeasibilityFailure(
            stage: stage,
            bytes: fixture?.responsePayloadBytes ?? 0,
            rangeCount: requests?.rangeCount ?? 0
        )
    }
}

@MainActor
private func waitForCompletion(
    _ completion: FeasibilityCompletion<Bool>,
    stage: FeasibilityStage,
    fixture: LocalHTTPFixture?
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(15))
    while completion.value == nil, clock.now < deadline {
        do {
            try await Task.sleep(for: .milliseconds(10))
        } catch {
            throw FeasibilityFailure(
                stage: stage,
                bytes: fixture?.responsePayloadBytes ?? 0,
                rangeCount: fixture.map { requestMetrics($0.requests).rangeCount } ?? 0
            )
        }
    }
    guard completion.value == true else {
        let requests = fixture.map { requestMetrics($0.requests) }
        throw FeasibilityFailure(
            stage: stage,
            bytes: fixture?.responsePayloadBytes ?? 0,
            rangeCount: requests?.rangeCount ?? 0
        )
    }
}

private func startFixture(_ fixture: LocalHTTPFixture) async throws -> UInt16 {
    try await withThrowingTaskGroup(of: UInt16.self) { group in
        group.addTask { try await fixture.start() }
        group.addTask {
            try await Task.sleep(for: .seconds(5))
            fixture.stop()
            throw FeasibilityFailure(stage: .fixtureStart, bytes: 0, rangeCount: 0)
        }
        defer { group.cancelAll() }
        guard let port = try await group.next() else {
            throw FeasibilityFailure(stage: .fixtureStart, bytes: 0, rangeCount: 0)
        }
        return port
    }
}

@MainActor
private func verifyFileBaseline(_ flac: GeneratedFLAC) async throws -> Double {
    let asset = AVURLAsset(
        url: flac.url,
        options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
    )
    let item = AVPlayerItem(asset: asset)
    let player = AVPlayer(playerItem: item)
    player.automaticallyWaitsToMinimizeStalling = false
    defer {
        player.pause()
        player.replaceCurrentItem(with: nil)
    }

    try await waitUntilReady(item, stage: .fileReady, fixture: nil)
    let duration = item.duration.seconds
    guard duration.isFinite, duration > 0, abs(duration - flac.expectedDuration) <= 0.05 else {
        throw FeasibilityFailure(stage: .fileDuration, bytes: flac.data.count, rangeCount: 0)
    }

    let target = duration * 0.65
    let completion = FeasibilityCompletion<Bool>()
    player.seek(
        to: CMTime(seconds: target, preferredTimescale: 44_100),
        toleranceBefore: .zero,
        toleranceAfter: .zero
    ) { completion.finish($0) }
    try await waitForCompletion(completion, stage: .fileSeek, fixture: nil)
    guard abs(player.currentTime().seconds - target) <= 0.15 else {
        throw FeasibilityFailure(stage: .fileSeek, bytes: flac.data.count, rangeCount: 0)
    }
    return duration
}

@MainActor
private func runFeasibilityTrial(
    branch: FeasibilityBranch,
    flac: GeneratedFLAC,
    baselineDuration: Double
) async throws -> FeasibilityRunMetrics {
    let fixture: LocalHTTPFixture
    do {
        fixture = try LocalHTTPFixture(
            response: { flacResponse(for: $0, body: flac.data) },
            initialResponseDelay: .milliseconds(150),
            sendChunkSize: 64 * 1_024,
            sendChunkDelay: .milliseconds(12)
        )
    } catch {
        throw FeasibilityFailure(stage: .fixtureStart, bytes: 0, rangeCount: 0)
    }
    defer { fixture.stop() }

    let port: UInt16
    do {
        port = try await startFixture(fixture)
    } catch {
        throw FeasibilityFailure(stage: .fixtureStart, bytes: 0, rangeCount: 0)
    }
    let sourceURL = URL(string: "http://127.0.0.1:\(port)/feasibility.flac")!
    let customAsset = branch.usesCustomLoader
        ? FeasibilityCustomAsset(sourceURL: sourceURL, precise: branch.precise)
        : nil
    let asset = customAsset?.asset ?? AVURLAsset(
        url: sourceURL,
        options: [AVURLAssetPreferPreciseDurationAndTimingKey: branch.precise]
    )
    let item = AVPlayerItem(asset: asset)
    let player = AVPlayer(playerItem: item)
    player.automaticallyWaitsToMinimizeStalling = false
    defer {
        player.pause()
        player.replaceCurrentItem(with: nil)
        customAsset?.loaderDelegate.stop()
    }

    let clock = ContinuousClock()
    let readyStart = clock.now
    try await waitUntilReady(item, stage: .ready, fixture: fixture)
    let readySeconds = durationSeconds(readyStart.duration(to: clock.now))
    let readyPayload = fixture.responsePayloadBytes

    let duration = item.duration.seconds
    let durationError = abs(duration - baselineDuration)
    guard duration.isFinite, duration > 0, durationError <= 0.05 else {
        let requests = requestMetrics(fixture.requests)
        throw FeasibilityFailure(stage: .duration, bytes: readyPayload, rangeCount: requests.rangeCount)
    }

    let target = baselineDuration * 0.65
    let seekStartPayload = fixture.responsePayloadBytes
    let seekStart = clock.now
    let seekCompletion = FeasibilityCompletion<Bool>()
    player.seek(
        to: CMTime(seconds: target, preferredTimescale: 44_100),
        toleranceBefore: .zero,
        toleranceAfter: .zero
    ) { seekCompletion.finish($0) }
    try await waitForCompletion(seekCompletion, stage: .seek, fixture: fixture)
    let seekSeconds = durationSeconds(seekStart.duration(to: clock.now))
    let seekPayload = fixture.responsePayloadBytes - seekStartPayload
    let seekError = abs(player.currentTime().seconds - target)
    guard seekError <= 0.15 else {
        let requests = requestMetrics(fixture.requests)
        throw FeasibilityFailure(
            stage: .seek,
            bytes: fixture.responsePayloadBytes,
            rangeCount: requests.rangeCount
        )
    }

    let prerollStartPayload = fixture.responsePayloadBytes
    let prerollStart = clock.now
    let prerollCompletion = FeasibilityCompletion<Bool>()
    player.preroll(atRate: 1) { prerollCompletion.finish($0) }
    try await waitForCompletion(prerollCompletion, stage: .preroll, fixture: fixture)
    let prerollSeconds = durationSeconds(prerollStart.duration(to: clock.now))
    let prerollPayload = fixture.responsePayloadBytes - prerollStartPayload
    let requests = requestMetrics(fixture.requests)

    if let loaderMetrics = customAsset?.loaderDelegate.snapshot() {
        guard loaderMetrics.largestRequest <= feasibilityHTTPBlockSize else {
            throw FeasibilityFailure(
                stage: .rangeLimit,
                bytes: loaderMetrics.largestRequest,
                rangeCount: requests.rangeCount
            )
        }
        guard requests.rangeCount == requests.requestCount else {
            let stage: FeasibilityStage
            if requests.nonRangeHEADCount > 0 {
                stage = .nonRangeHead
            } else if requests.nonRangeGETCount > 0 {
                stage = .nonRangeGet
            } else if requests.nonRangeOtherCount > 0 {
                stage = .nonRangeOther
            } else {
                stage = .rangeRequestCoverage
            }
            throw FeasibilityFailure(
                stage: stage,
                bytes: requests.requestCount,
                rangeCount: requests.rangeCount
            )
        }
        guard loaderMetrics.completeLength == Int64(flac.data.count) else {
            throw FeasibilityFailure(
                stage: .contentLength,
                bytes: Int(loaderMetrics.completeLength ?? 0),
                rangeCount: requests.rangeCount
            )
        }
        guard loaderMetrics.largestHTTPResponse <= feasibilityHTTPBlockSize,
              loaderMetrics.largestDataResponse <= feasibilityResponseChunkSize
        else {
            throw FeasibilityFailure(
                stage: .responseLimit,
                bytes: fixture.responsePayloadBytes,
                rangeCount: requests.rangeCount
            )
        }
    }

    return FeasibilityRunMetrics(
        branch: branch,
        readySeconds: readySeconds,
        readyPayload: readyPayload,
        seekSeconds: seekSeconds,
        seekError: seekError,
        seekPayload: seekPayload,
        prerollSeconds: prerollSeconds,
        prerollPayload: prerollPayload,
        durationError: durationError,
        requestCount: requests.requestCount,
        uniqueRanges: requests.uniqueRanges,
        duplicateRanges: requests.duplicateRanges,
        incompleteTransportCount: requests.incompleteTransportCount
    )
}

private func median<T: BinaryInteger>(_ values: [T]) -> Double {
    let sorted = values.map { Double($0) }.sorted()
    return sorted[sorted.count / 2]
}

private func median(_ values: [Double]) -> Double {
    let sorted = values.sorted()
    return sorted[sorted.count / 2]
}

private func metricRange(_ values: [Double], scale: Double = 1) -> String {
    let values = values.map { $0 * scale }
    return String(format: "%.1f...%.1f", values.min() ?? 0, values.max() ?? 0)
}

private func metricRange<T: BinaryInteger>(_ values: [T]) -> String {
    "\(values.min() ?? 0)...\(values.max() ?? 0)"
}

private func printSummary(_ runs: [FeasibilityRunMetrics]) {
    guard let branch = runs.first?.branch else { return }
    let readyTimes = runs.map(\.readySeconds)
    let seekTimes = runs.map(\.seekSeconds)
    let prerollTimes = runs.map(\.prerollSeconds)
    let durationErrors = runs.map(\.durationError)
    let seekErrors = runs.map(\.seekError)
    let totalTimes = runs.map(\.totalSeconds)
    let totalPayload = runs.map(\.totalPayload)
    print(
        "W00 branch=\(branch.rawValue) runs=\(runs.count) "
            + String(format: "readyMedianMs=%.1f ", median(readyTimes) * 1_000)
            + "readyRangeMs=\(metricRange(readyTimes, scale: 1_000)) "
            + String(format: "seekMedianMs=%.1f ", median(seekTimes) * 1_000)
            + "seekRangeMs=\(metricRange(seekTimes, scale: 1_000)) "
            + String(format: "prerollMedianMs=%.1f ", median(prerollTimes) * 1_000)
            + "prerollRangeMs=\(metricRange(prerollTimes, scale: 1_000)) "
            + String(format: "totalMedianMs=%.1f ", median(totalTimes) * 1_000)
            + "totalRangeMs=\(metricRange(totalTimes, scale: 1_000)) "
            + "readyBytesMedian=\(Int(median(runs.map(\.readyPayload)))) "
            + "readyBytesRange=\(metricRange(runs.map(\.readyPayload))) "
            + "seekBytesMedian=\(Int(median(runs.map(\.seekPayload)))) "
            + "seekBytesRange=\(metricRange(runs.map(\.seekPayload))) "
            + "prerollBytesMedian=\(Int(median(runs.map(\.prerollPayload)))) "
            + "prerollBytesRange=\(metricRange(runs.map(\.prerollPayload))) "
            + "totalBytesMedian=\(Int(median(totalPayload))) "
            + "totalBytesRange=\(metricRange(totalPayload)) "
            + String(format: "durationErrorMedianMs=%.1f ", median(durationErrors) * 1_000)
            + "durationErrorRangeMs=\(metricRange(durationErrors, scale: 1_000)) "
            + String(format: "seekErrorMedianMs=%.1f ", median(seekErrors) * 1_000)
            + "seekErrorRangeMs=\(metricRange(seekErrors, scale: 1_000)) "
            + "requestsRange=\(metricRange(runs.map(\.requestCount))) "
            + "uniqueRangesRange=\(metricRange(runs.map(\.uniqueRanges))) "
            + "duplicateRangesRange=\(metricRange(runs.map(\.duplicateRanges))) "
            + "incompleteTransportRange=\(metricRange(runs.map(\.incompleteTransportCount)))"
    )
}

@Suite("AudioRangeFeasibilityTests", .serialized)
@MainActor
struct AudioRangeFeasibilityTests {
    @Test("Real FLAC direct and custom loader ready, seek, and preroll A/B")
    func realFLACCustomLoaderAB() async throws {
        guard parsedRange("bytes=2-3", length: 10) == 2..<4,
              parsedRange("bytes=-3", length: 10) == 7..<10
        else {
            throw FeasibilityFailure(stage: .rangeLimit, bytes: 0, rangeCount: 0)
        }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TinyCloudMusic-W00-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        } catch {
            throw FeasibilityFailure(stage: .generateFLAC, bytes: 0, rangeCount: 0)
        }
        defer { try? FileManager.default.removeItem(at: root) }

        let flac: GeneratedFLAC
        do {
            flac = try generateFLAC(in: root)
        } catch {
            throw FeasibilityFailure(stage: .generateFLAC, bytes: 0, rangeCount: 0)
        }
        let baselineDuration = try await verifyFileBaseline(flac)
        var runs: [FeasibilityBranch: [FeasibilityRunMetrics]] = [:]
        for branch in FeasibilityBranch.allCases {
            _ = try await runFeasibilityTrial(
                branch: branch,
                flac: flac,
                baselineDuration: baselineDuration
            )
        }
        for _ in 0..<5 {
            for branch in FeasibilityBranch.allCases {
                runs[branch, default: []].append(try await runFeasibilityTrial(
                    branch: branch,
                    flac: flac,
                    baselineDuration: baselineDuration
                ))
            }
        }

        let direct = runs[.directPrecise]!
        for branch in [FeasibilityBranch.customPrecise, .customDiagnostic] {
            for (custom, baseline) in zip(runs[branch]!, direct) {
                guard custom.totalPayload <= baseline.totalPayload + feasibilityHTTPBlockSize else {
                    throw FeasibilityFailure(
                        stage: .payloadBudget,
                        bytes: custom.totalPayload,
                        rangeCount: custom.uniqueRanges + custom.duplicateRanges
                    )
                }
            }
        }

        #if DEBUG
        print("W00 configuration=debug correctness=PASS performance=diagnostic-only")
        #else
        for branch in FeasibilityBranch.allCases {
            printSummary(runs[branch] ?? [])
        }
        let directMedian = median(direct.map(\.totalSeconds))
        let custom = runs[.customPrecise]!
        let customMedian = median(custom.map(\.totalSeconds))
        let allowedRegression = max(0.5, directMedian * 0.5)
        guard customMedian - directMedian <= allowedRegression else {
            print("W00 releaseBatch=FAIL coordinatorMustApplyThreeBatchVote=true")
            throw FeasibilityFailure(
                stage: .performanceBatch,
                bytes: Int(median(custom.map(\.totalPayload))),
                rangeCount: Int(median(custom.map { $0.uniqueRanges + $0.duplicateRanges }))
            )
        }
        print("W00 releaseBatch=PASS")
        #endif
    }
}
