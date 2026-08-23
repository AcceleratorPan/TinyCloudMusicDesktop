import CryptoKit
import Foundation
import Testing
@testable import TinyCloudMusic

private enum RangeFixtureError: Error {
    case exhausted
}

private actor RangeResponseGate {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }

    private var entered = false
    private var released = false
    private var waiters: [Waiter] = []
    private(set) var cancellations = 0

    func wait() async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                entered = true
                if released {
                    continuation.resume()
                } else if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiters.append(Waiter(id: id, continuation: continuation))
                }
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    func waitIgnoringCancellation() async throws {
        let id = UUID()
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            entered = true
            if released {
                continuation.resume()
            } else {
                waiters.append(Waiter(id: id, continuation: continuation))
            }
        }
    }

    func hasEntered() -> Bool { entered }

    func waiterCount() -> Int { waiters.count }

    func release() {
        released = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.continuation.resume() }
    }

    private func cancel(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        cancellations += 1
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }
}

private actor RangeLookupGate {
    private var entered = false
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var calls = 0

    func wait() async {
        calls += 1
        guard calls == 1 else { return }
        entered = true
        guard !released else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func hasEntered() -> Bool { entered }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

private actor RangeCounter {
    private(set) var value = 0

    func increment() { value += 1 }
}

private actor RangeFlag {
    private(set) var value = false

    func set() { value = true }
}

private actor RangeSourceFixture {
    private var sources: [PlaybackSource]
    private let gate: RangeResponseGate?
    private(set) var calls = 0

    init(_ sources: [PlaybackSource], gate: RangeResponseGate? = nil) {
        self.sources = sources
        self.gate = gate
    }

    func next() async throws -> PlaybackSource {
        calls += 1
        try await gate?.wait()
        guard !sources.isEmpty else { throw RangeFixtureError.exhausted }
        return sources.removeFirst()
    }
}

private struct RangeRequestRecord: Equatable, Sendable {
    let range: String?
    let ifRange: String?
    let acceptsIdentity: Bool
    let reloadsIgnoringCache: Bool
    let sourceID: Int
}

private struct RangeResponseStep: Sendable {
    let status: Int
    let body: Data
    let headers: [String: String]
    let effectiveURL: URL?
    let gate: RangeResponseGate?
    let ignoresCancellation: Bool

    init(
        status: Int,
        body: Data = Data(),
        headers: [String: String] = [:],
        effectiveURL: URL? = nil,
        gate: RangeResponseGate? = nil,
        ignoresCancellation: Bool = false
    ) {
        self.status = status
        self.body = body
        self.headers = headers
        self.effectiveURL = effectiveURL
        self.gate = gate
        self.ignoresCancellation = ignoresCancellation
    }

    static func partial(
        _ body: Data,
        range: Range<Int>,
        total: Int,
        etag: String? = nil,
        contentType: String = "audio/mpeg",
        encoding: String? = nil,
        effectiveURL: URL? = nil,
        acceptRanges: Bool = false,
        gate: RangeResponseGate? = nil,
        ignoresCancellation: Bool = false
    ) -> Self {
        var headers = [
            "Content-Range": "bytes \(range.lowerBound)-\(range.upperBound - 1)/\(total)",
            "Content-Type": contentType,
        ]
        if let etag { headers["ETag"] = etag }
        if let encoding { headers["Content-Encoding"] = encoding }
        if acceptRanges { headers["Accept-Ranges"] = "bytes" }
        return Self(
            status: 206,
            body: body,
            headers: headers,
            effectiveURL: effectiveURL,
            gate: gate,
            ignoresCancellation: ignoresCancellation
        )
    }

    static func complete(
        _ body: Data,
        contentType: String = "audio/mpeg",
        effectiveURL: URL? = nil,
        gate: RangeResponseGate? = nil
    ) -> Self {
        Self(
            status: 200,
            body: body,
            headers: [
                "Content-Length": "\(body.count)",
                "Content-Type": contentType,
            ],
            effectiveURL: effectiveURL,
            gate: gate
        )
    }

    static func unsatisfied(length: Int) -> Self {
        Self(status: 416, headers: ["Content-Range": "bytes */\(length)"])
    }
}

private actor RangeDownloadFixture {
    private let root: URL
    private let sourceIDs: [URL: Int]
    private var steps: [RangeResponseStep]
    private(set) var requests: [RangeRequestRecord] = []
    private(set) var cancellations = 0
    private(set) var completions = 0

    init(root: URL, sourceIDs: [URL: Int], steps: [RangeResponseStep]) {
        self.root = root
        self.sourceIDs = sourceIDs
        self.steps = steps
    }

    func download(_ request: URLRequest) async throws -> (URL, URLResponse) {
        guard !steps.isEmpty else { throw RangeFixtureError.exhausted }
        let step = steps.removeFirst()
        requests.append(RangeRequestRecord(
            range: request.value(forHTTPHeaderField: "Range"),
            ifRange: request.value(forHTTPHeaderField: "If-Range"),
            acceptsIdentity: request.value(forHTTPHeaderField: "Accept-Encoding") == "identity",
            reloadsIgnoringCache: request.cachePolicy == .reloadIgnoringLocalCacheData,
            sourceID: request.url.flatMap { sourceIDs[$0] } ?? -1
        ))
        do {
            if step.ignoresCancellation {
                try await step.gate?.waitIgnoringCancellation()
            } else {
                try await step.gate?.wait()
                try Task.checkCancellation()
            }
        } catch {
            cancellations += 1
            throw error
        }

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let temporaryURL = root.appending(path: UUID().uuidString)
        try step.body.write(to: temporaryURL)
        let response = HTTPURLResponse(
            url: step.effectiveURL ?? request.url!,
            statusCode: step.status,
            httpVersion: nil,
            headerFields: step.headers
        )!
        completions += 1
        return (temporaryURL, response)
    }

    func callCount() -> Int { requests.count }
}

private let rangeBlockSize = 512 * 1_024
private let rangeSequentialWindowSize = 4 * rangeBlockSize
private let rangeKey = TrackRangeCacheKey(songID: 7_001, quality: "standard")

private func rangeAudio(count: Int, fill: UInt8 = 0x41) -> Data {
    var data = Data("ID3".utf8)
    if count > data.count { data.append(Data(repeating: fill, count: count - data.count)) }
    return data
}

private func rangeMD5(_ data: Data) -> String {
    Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func exactPlistInteger(_ value: Any?) -> Int64? {
    guard let number = value as? NSNumber,
          CFGetTypeID(number) != CFBooleanGetTypeID(),
          !["f", "d"].contains(String(cString: number.objCType)),
          let integer = Int64(number.stringValue),
          number.compare(NSNumber(value: integer)) == .orderedSame
    else { return nil }
    return integer
}

private func rangeSource(
    _ url: URL,
    data: Data? = nil,
    level: String = "standard",
    availability: PlaybackAvailability? = nil
) -> PlaybackSource {
    PlaybackSource(
        url: url,
        availability: availability ?? .playable(level: level),
        format: "mp3",
        representation: data.flatMap {
            PlaybackRepresentation(contentLength: Int64($0.count), contentMD5: rangeMD5($0))
        }
    )
}

private func rangeFiles(in root: URL, withExtension fileExtension: String) -> [URL] {
    let values = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?.allObjects
        as? [URL] ?? []
    return values.filter { $0.pathExtension == fileExtension }
}

private func waitForRangeCondition(_ predicate: () async -> Bool) async throws {
    for _ in 0..<500 {
        if await predicate() { return }
        try await Task.sleep(for: .milliseconds(2))
    }
    throw RangeFixtureError.exhausted
}

private func expectRangeError(
    _ expected: TrackRangeCacheError,
    _ operation: () async throws -> Void
) async {
    do {
        try await operation()
        Issue.record("Expected range cache error")
    } catch let error as TrackRangeCacheError {
        #expect(error == expected)
    } catch {
        Issue.record("Unexpected error type")
    }
}

private func expectCancellation(_ operation: () async throws -> Void) async {
    do {
        try await operation()
        Issue.record("Expected cancellation")
    } catch is CancellationError {
    } catch {
        Issue.record("Unexpected cancellation error type")
    }
}

@Suite("Track range cache")
struct TrackRangeCacheTests {
    @Test("Open validates key, format, URL, and exact playable level")
    func validation() async {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = TrackRangeCache(trackCache: TrackCache(directory: root))
        let validURL = URL(string: "https://example.com/audio")!
        let valid = rangeSource(validURL, data: rangeAudio(count: 600_000))

        for (key, format, source, expected) in [
            (TrackRangeCacheKey(songID: 0, quality: "standard"), "mp3", valid, TrackRangeCacheError.invalidSource),
            (TrackRangeCacheKey(songID: 1, quality: "unknown"), "mp3", valid, .invalidSource),
            (rangeKey, "../mp3", valid, .invalidSource),
            (rangeKey, "aac", valid, .invalidSource),
            (rangeKey, "mp3", PlaybackSource(url: URL(fileURLWithPath: "/tmp/audio"), availability: .playable(level: "standard"), format: "mp3"), .invalidSource),
            (rangeKey, "mp3", rangeSource(validURL, availability: .trial(level: "standard", endSeconds: 1)), .sourceLevelMismatch(expected: "standard", actual: "standard")),
            (rangeKey, "mp3", rangeSource(validURL, level: "higher"), .sourceLevelMismatch(expected: "standard", actual: "higher")),
        ] {
            await expectRangeError(expected) {
                _ = try await cache.open(key: key, format: format, initialSource: source) { source }
            }
        }
    }

    @Test("API identity partial persists without ETag and cold descriptor avoids provider and network")
    func persistentPartialAndColdDescriptor() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let body = rangeAudio(count: 700_000)
        let firstBlock = body.subdata(in: 0..<rangeBlockSize)
        let origin = URL(string: "https://marker-origin.example/audio?marker-query=secret")!
        let source = rangeSource(origin, data: body)
        let fixture = RangeDownloadFixture(
            root: root.appending(path: "responses"),
            sourceIDs: [origin: 1],
            steps: [RangeResponseStep(
                status: 206,
                body: firstBlock,
                headers: [
                    "Content-Range": "bytes 0-\(rangeBlockSize - 1)/\(body.count)",
                    "Content-Type": "audio/mpeg",
                    "ETag": "\"marker-etag\"",
                    "X-Marker-Token": "marker-token",
                    "Authorization": "marker-authorization",
                    "Cookie": "marker-cookie",
                    "Last-Modified": "marker-last-modified",
                ]
            )]
        )
        let trackCache = TrackCache(directory: root.appending(path: "StreamCache"))
        let cache = TrackRangeCache(trackCache: trackCache) { try await fixture.download($0) }
        let session = try await cache.open(key: rangeKey, format: "mp3", initialSource: source) { source }

        #expect(try await cache.read(session: session, offset: 100, maximumLength: 64) == body.subdata(in: 100..<164))
        #expect(await fixture.requests == [RangeRequestRecord(
            range: "bytes=0-\(rangeBlockSize - 1)",
            ifRange: nil,
            acceptsIdentity: true,
            reloadsIgnoringCache: true,
            sourceID: 1
        )])
        await cache.close(session)
        try await waitForRangeCondition { rangeFiles(in: root, withExtension: "plist").count == 1 }

        let metadataURL = try #require(rangeFiles(in: root, withExtension: "plist").first)
        let metadata = try Data(contentsOf: metadataURL)
        let rawPlist = try PropertyListSerialization.propertyList(
            from: metadata,
            options: [],
            format: nil
        )
        let plist = try #require(rawPlist as? [String: Any])
        #expect(Set(plist.keys) == Set([
            "schemaVersion", "entryID", "songID", "quality", "format", "mimeType",
            "contentLength", "contentMD5", "coveredRanges",
        ]))
        #expect(exactPlistInteger(plist["schemaVersion"]) == 1)
        #expect(exactPlistInteger(plist["songID"]) == rangeKey.songID)
        #expect(plist["quality"] as? String == rangeKey.quality)
        #expect(plist["format"] as? String == "mp3")
        #expect(plist["mimeType"] as? String == "audio/mpeg")
        #expect(exactPlistInteger(plist["contentLength"]) == Int64(body.count))
        #expect(plist["contentMD5"] as? String == rangeMD5(body))
        let entryID = try #require(plist["entryID"] as? String)
        #expect(metadataURL.lastPathComponent == "\(rangeKey.songID)-\(entryID).range.metadata.plist")
        let coveredRanges = try #require(plist["coveredRanges"] as? [[String: Any]])
        #expect(coveredRanges.count == 1)
        #expect(Set(coveredRanges[0].keys) == Set(["lowerBound", "upperBound"]))
        #expect(exactPlistInteger(coveredRanges[0]["lowerBound"]) == 0)
        #expect(exactPlistInteger(coveredRanges[0]["upperBound"]) == Int64(rangeBlockSize))
        let metadataText = String(decoding: metadata, as: UTF8.self)
        #expect(metadataText.contains(rangeMD5(body)))
        for forbidden in [
            "marker-origin", "marker-query", "marker-etag", "marker-token", "X-Marker-Token",
            "marker-authorization", "marker-cookie", "marker-last-modified",
            "sourceURL", "Authorization", "Cookie", "Last-Modified",
        ] {
            #expect(!metadataText.contains(forbidden))
        }

        let provider = RangeSourceFixture([])
        let noNetwork = RangeDownloadFixture(root: root, sourceIDs: [:], steps: [])
        let rebuilt = TrackRangeCache(trackCache: trackCache) { try await noNetwork.download($0) }
        #expect(await rebuilt.descriptor(for: rangeKey) == TrackRangeCache.Descriptor(
            format: "mp3",
            mimeType: "audio/mpeg",
            contentLength: Int64(body.count)
        ))
        let rebuiltSession = try await rebuilt.open(
            key: rangeKey,
            format: "mp3",
            initialSource: nil,
            sourceProvider: { try await provider.next() }
        )
        #expect(try await rebuilt.contentInfo(for: rebuiltSession).contentLength == Int64(body.count))
        #expect(try await rebuilt.read(session: rebuiltSession, offset: 120, maximumLength: 32) == body.subdata(in: 120..<152))
        #expect(await provider.calls == 0)
        #expect(await noNetwork.callCount() == 0)
        await rebuilt.close(rebuiltSession)
    }

    @Test("Sequential demand widens one request while random gaps stay block-sized")
    func sequentialDemandWindow() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let body = rangeAudio(count: rangeBlockSize * 8)
        let origin = URL(string: "https://example.com/sequential")!
        let source = rangeSource(origin, data: body)
        let forwardGate = RangeResponseGate()
        let firstRange = 0..<rangeBlockSize
        let forwardRange = rangeBlockSize..<(rangeBlockSize + rangeSequentialWindowSize)
        let clippedRange = (rangeBlockSize * 5)..<(rangeBlockSize * 6)
        let randomRange = (rangeBlockSize * 6)..<(rangeBlockSize * 7)
        let fixture = RangeDownloadFixture(
            root: root.appending(path: "responses"),
            sourceIDs: [origin: 1],
            steps: [
                .partial(body.subdata(in: firstRange), range: firstRange, total: body.count),
                .partial(
                    body.subdata(in: forwardRange),
                    range: forwardRange,
                    total: body.count,
                    gate: forwardGate
                ),
                .partial(body.subdata(in: randomRange), range: randomRange, total: body.count),
                .partial(body.subdata(in: clippedRange), range: clippedRange, total: body.count),
            ]
        )
        let cache = TrackRangeCache(trackCache: TrackCache(directory: root)) {
            try await fixture.download($0)
        }
        let session = try await cache.open(
            key: rangeKey,
            format: "mp3",
            initialSource: source,
            sourceProvider: { source }
        )

        #expect(try await cache.read(
            session: session,
            offset: 0,
            maximumLength: 1
        ) == body.subdata(in: 0..<1))
        let forward = Task {
            try await cache.read(
                session: session,
                offset: Int64(rangeBlockSize),
                maximumLength: 1
            )
        }
        try await waitForRangeCondition { await forwardGate.hasEntered() }
        let overlapping = Task {
            try await cache.read(
                session: session,
                offset: Int64(rangeBlockSize * 2),
                maximumLength: 1
            )
        }
        await forwardGate.release()
        #expect(try await forward.value == body.subdata(in: rangeBlockSize..<(rangeBlockSize + 1)))
        #expect(try await overlapping.value == body.subdata(
            in: (rangeBlockSize * 2)..<(rangeBlockSize * 2 + 1)
        ))
        #expect(try await cache.read(
            session: session,
            offset: Int64(randomRange.lowerBound),
            maximumLength: 1
        ) == body.subdata(in: randomRange.lowerBound..<(randomRange.lowerBound + 1)))
        #expect(try await cache.read(
            session: session,
            offset: Int64(clippedRange.lowerBound),
            maximumLength: 1
        ) == body.subdata(in: clippedRange.lowerBound..<(clippedRange.lowerBound + 1)))
        #expect(await fixture.requests.map(\.range) == [
            "bytes=0-\(rangeBlockSize - 1)",
            "bytes=\(rangeBlockSize)-\(forwardRange.upperBound - 1)",
            "bytes=\(randomRange.lowerBound)-\(randomRange.upperBound - 1)",
            "bytes=\(clippedRange.lowerBound)-\(clippedRange.upperBound - 1)",
        ])
        await cache.close(session)
    }

    @Test("Sequential demand stops before an earlier random in-flight request")
    func sequentialDemandAvoidsEarlierRandomFlight() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let body = rangeAudio(count: rangeBlockSize * 8)
        let origin = URL(string: "https://example.com/reverse-sequential")!
        let source = rangeSource(origin, data: body)
        let randomGate = RangeResponseGate()
        let firstRange = 0..<rangeBlockSize
        let randomRange = (rangeBlockSize * 2)..<(rangeBlockSize * 3)
        let fixture = RangeDownloadFixture(
            root: root.appending(path: "responses"),
            sourceIDs: [origin: 1],
            steps: [
                .partial(body.subdata(in: firstRange), range: firstRange, total: body.count),
                .complete(body, gate: randomGate),
            ]
        )
        let trackCache = TrackCache(directory: root)
        let cache = TrackRangeCache(trackCache: trackCache) {
            try await fixture.download($0)
        }
        let session = try await cache.open(
            key: rangeKey,
            format: "mp3",
            initialSource: source,
            sourceProvider: { source }
        )

        #expect(try await cache.read(
            session: session,
            offset: 0,
            maximumLength: 1
        ) == body.subdata(in: 0..<1))
        let random = Task {
            try await cache.read(
                session: session,
                offset: Int64(randomRange.lowerBound),
                maximumLength: 1
            )
        }
        try await waitForRangeCondition { await randomGate.hasEntered() }
        let forward = Task {
            try await cache.read(
                session: session,
                offset: Int64(rangeBlockSize),
                maximumLength: 1
            )
        }
        await randomGate.release()
        #expect(try await random.value == body.subdata(
            in: randomRange.lowerBound..<(randomRange.lowerBound + 1)
        ))
        #expect(try await forward.value == body.subdata(
            in: rangeBlockSize..<(rangeBlockSize + 1)
        ))
        #expect(await fixture.requests.map(\.range) == [
            "bytes=0-\(rangeBlockSize - 1)",
            "bytes=\(randomRange.lowerBound)-\(randomRange.upperBound - 1)",
        ])
        #expect(await trackCache.readyFile(for: rangeKey.songID, quality: rangeKey.quality) != nil)
        await cache.close(session)
    }

    @Test("Malformed metadata, truncated body, overflow range, and schema mismatch are removed")
    func coldValidationRemovesDamage() async throws {
        enum Damage: CaseIterable { case metadata, body, range, schema }

        for damage in Damage.allCases {
            let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let qualityRoot = root.appending(path: "RangeCache/standard")
            try FileManager.default.createDirectory(at: qualityRoot, withIntermediateDirectories: true)
            let id = UUID()
            let bodyURL = qualityRoot.appending(path: "\(rangeKey.songID)-\(id.uuidString).range")
            let metadataURL = bodyURL.appendingPathExtension("metadata.plist")
            try Data(repeating: 1, count: damage == .body ? 50 : 100).write(to: bodyURL)
            let plist: [String: Any] = [
                "schemaVersion": damage == .schema ? 2 : 1,
                "entryID": id.uuidString,
                "songID": rangeKey.songID,
                "quality": rangeKey.quality,
                "format": "mp3",
                "mimeType": "audio/mpeg",
                "contentLength": 100,
                "contentMD5": String(repeating: "a", count: 32),
                "coveredRanges": [[
                    "lowerBound": 0,
                    "upperBound": damage == .range ? 101 : 100,
                ]],
            ]
            if damage == .metadata {
                try Data([0, 1, 2]).write(to: metadataURL)
            } else {
                try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
                    .write(to: metadataURL)
            }

            let cache = TrackRangeCache(trackCache: TrackCache(directory: root))
            #expect(await cache.descriptor(for: rangeKey) == nil)
            #expect(!FileManager.default.fileExists(atPath: bodyURL.path))
            #expect(!FileManager.default.fileExists(atPath: metadataURL.path))
        }
    }

    @Test("Transient first 206 requires direct URL and one valid strong ETag")
    func transientValidation() async throws {
        let sourceURL = URL(string: "https://example.com/audio")!
        let redirectedURL = URL(string: "https://example.com/redirected")!
        let body = rangeAudio(count: 1_000)
        let invalid: [(String?, URL?)] = [
            (nil, nil),
            ("W/\"weak\"", nil),
            ("\"unterminated", nil),
            ("\"one\", \"two\"", nil),
            ("\"strong\"", redirectedURL),
        ]

        for (etag, effectiveURL) in invalid {
            let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let fixture = RangeDownloadFixture(
                root: root,
                sourceIDs: [sourceURL: 1],
                steps: [.partial(
                    body.subdata(in: 0..<100),
                    range: 0..<100,
                    total: body.count,
                    etag: etag,
                    effectiveURL: effectiveURL
                )]
            )
            let cache = TrackRangeCache(trackCache: TrackCache(directory: root)) {
                try await fixture.download($0)
            }
            let source = rangeSource(sourceURL)
            let session = try await cache.open(key: rangeKey, format: "mp3", initialSource: source) { source }
            await expectRangeError(.unverifiableRepresentation) {
                _ = try await cache.read(session: session, offset: 0, maximumLength: 1)
            }
            #expect(await cache.descriptor(for: rangeKey) == nil)
            #expect(rangeFiles(in: root, withExtension: "plist").isEmpty)
            await cache.close(session)
            try await waitForRangeCondition { rangeFiles(in: root, withExtension: "range").isEmpty }
        }
    }

    @Test("Valid transient stays session-local and ETag comparison is case-sensitive")
    func transientLifecycleAndETag() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = URL(string: "https://example.com/audio")!
        let body = rangeAudio(count: 1_000)
        let fixture = RangeDownloadFixture(
            root: root,
            sourceIDs: [sourceURL: 1],
            steps: [
                .partial(body.subdata(in: 0..<64), range: 0..<64, total: body.count, etag: "\"Case,one\""),
                .partial(body.subdata(in: 64..<128), range: 64..<128, total: body.count, etag: "\"case,one\""),
            ]
        )
        let cache = TrackRangeCache(trackCache: TrackCache(directory: root)) {
            try await fixture.download($0)
        }
        let source = rangeSource(sourceURL)
        let session = try await cache.open(key: rangeKey, format: "mp3", initialSource: source) { source }
        #expect(try await cache.read(session: session, offset: 0, maximumLength: 8) == body.subdata(in: 0..<8))
        #expect(await cache.descriptor(for: rangeKey) == nil)
        #expect(rangeFiles(in: root, withExtension: "plist").isEmpty)
        await expectRangeError(.inconsistentRepresentation) {
            _ = try await cache.read(session: session, offset: 100, maximumLength: 8)
        }
        #expect(await fixture.requests.map(\.ifRange) == [nil, "\"Case,one\""])
        await cache.close(session)
        try await waitForRangeCondition { rangeFiles(in: root, withExtension: "range").isEmpty }
    }

    @Test("Transient empty-range 403 fails before refresh and same ETag never crosses URLs")
    func transientRefreshAndCrossURLBoundaries() async throws {
        let sourceA = URL(string: "https://example.com/a")!
        let sourceB = URL(string: "https://example.com/b")!
        let body = rangeAudio(count: 1_000)

        let expiredRoot = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: expiredRoot) }
        let expiredProvider = RangeSourceFixture([rangeSource(sourceB)])
        let expiredFixture = RangeDownloadFixture(
            root: expiredRoot,
            sourceIDs: [sourceA: 1, sourceB: 2],
            steps: [RangeResponseStep(status: 403)]
        )
        let expired = TrackRangeCache(trackCache: TrackCache(directory: expiredRoot)) {
            try await expiredFixture.download($0)
        }
        let expiredSession = try await expired.open(
            key: rangeKey,
            format: "mp3",
            initialSource: rangeSource(sourceA),
            sourceProvider: { try await expiredProvider.next() }
        )
        await expectRangeError(.inconsistentRepresentation) {
            _ = try await expired.read(session: expiredSession, offset: 0, maximumLength: 1)
        }
        #expect(await expiredProvider.calls == 0)
        #expect(await expiredFixture.requests.map(\.sourceID) == [1])
        #expect(await expired.descriptor(for: rangeKey) == nil)
        await expired.close(expiredSession)

        let isolatedRoot = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: isolatedRoot) }
        let isolatedFixture = RangeDownloadFixture(
            root: isolatedRoot,
            sourceIDs: [sourceA: 1, sourceB: 2],
            steps: [
                .partial(body.subdata(in: 0..<64), range: 0..<64, total: body.count, etag: "\"same\""),
                .partial(body.subdata(in: 0..<64), range: 0..<64, total: body.count, etag: "\"same\""),
            ]
        )
        let isolated = TrackRangeCache(trackCache: TrackCache(directory: isolatedRoot)) {
            try await isolatedFixture.download($0)
        }
        let sessionA = try await isolated.open(
            key: rangeKey,
            format: "mp3",
            initialSource: rangeSource(sourceA),
            sourceProvider: { rangeSource(sourceA) }
        )
        #expect(try await isolated.read(session: sessionA, offset: 0, maximumLength: 1) == body.subdata(in: 0..<1))
        let sessionB = try await isolated.open(
            key: rangeKey,
            format: "mp3",
            initialSource: rangeSource(sourceB),
            sourceProvider: { rangeSource(sourceB) }
        )
        #expect(try await isolated.read(session: sessionB, offset: 0, maximumLength: 1) == body.subdata(in: 0..<1))
        #expect(await isolatedFixture.requests.map(\.sourceID) == [1, 2])
        #expect(rangeFiles(in: isolatedRoot, withExtension: "range").count == 2)
        #expect(await isolated.descriptor(for: rangeKey) == nil)
        await isolated.close(sessionA)
        await isolated.close(sessionB)
        try await waitForRangeCondition { rangeFiles(in: isolatedRoot, withExtension: "range").isEmpty }
    }

    @Test("Short 206 responses advance Range lower and a non-covering response fails finitely")
    func shortPartialProgress() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = URL(string: "https://example.com/audio")!
        let body = rangeAudio(count: 1_000)
        let source = rangeSource(sourceURL, data: body)
        let fixture = RangeDownloadFixture(
            root: root,
            sourceIDs: [sourceURL: 1],
            steps: [
                .partial(body.subdata(in: 0..<64), range: 0..<64, total: body.count),
                .partial(body.subdata(in: 64..<128), range: 64..<128, total: body.count),
                .partial(body.subdata(in: 128..<192), range: 128..<192, total: body.count),
            ]
        )
        let cache = TrackRangeCache(trackCache: TrackCache(directory: root)) {
            try await fixture.download($0)
        }
        let session = try await cache.open(key: rangeKey, format: "mp3", initialSource: source) { source }
        #expect(try await cache.read(session: session, offset: 150, maximumLength: 8) == body.subdata(in: 150..<158))
        #expect(await fixture.requests.map(\.range) == [
            "bytes=0-999", "bytes=64-999", "bytes=128-999",
        ])
        await cache.close(session)

        let failedRoot = root.appending(path: "failed")
        let failedFixture = RangeDownloadFixture(
            root: failedRoot,
            sourceIDs: [sourceURL: 1],
            steps: [
                .partial(body.subdata(in: 0..<64), range: 0..<64, total: body.count),
                .partial(body.subdata(in: 0..<64), range: 0..<64, total: body.count),
            ]
        )
        let failed = TrackRangeCache(trackCache: TrackCache(directory: failedRoot)) {
            try await failedFixture.download($0)
        }
        let failedSession = try await failed.open(key: rangeKey, format: "mp3", initialSource: source) { source }
        await expectRangeError(.rejectedResponse) {
            _ = try await failed.read(session: failedSession, offset: 100, maximumLength: 1)
        }
        #expect(await failedFixture.callCount() == 2)
        await failed.close(failedSession)
    }

    @Test("Ten readers coalesce and one cancelled waiter does not cancel upstream")
    func coalescingAndSingleCancellation() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = RangeResponseGate()
        let sourceURL = URL(string: "https://example.com/audio")!
        let body = rangeAudio(count: 700_000)
        let source = rangeSource(sourceURL, data: body)
        let fixture = RangeDownloadFixture(
            root: root,
            sourceIDs: [sourceURL: 1],
            steps: [.partial(
                body.subdata(in: 0..<rangeBlockSize),
                range: 0..<rangeBlockSize,
                total: body.count,
                gate: gate
            )]
        )
        let cache = TrackRangeCache(trackCache: TrackCache(directory: root)) {
            try await fixture.download($0)
        }
        let session = try await cache.open(key: rangeKey, format: "mp3", initialSource: source) { source }
        var readers: [Task<Data, Error>] = (0..<10).map { _ in
            Task { try await cache.read(session: session, offset: 100, maximumLength: 16) }
        }
        try await waitForRangeCondition { await gate.hasEntered() }
        readers[0].cancel()
        await gate.release()
        await expectCancellation { _ = try await readers.removeFirst().value }
        for reader in readers {
            #expect(try await reader.value == body.subdata(in: 100..<116))
        }
        #expect(await fixture.callCount() == 1)
        #expect(await fixture.cancellations == 0)
        await cache.close(session)
    }

    @Test("Cancelling the final waiter cancels upstream and commits no range")
    func finalWaiterCancellation() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = RangeResponseGate()
        let sourceURL = URL(string: "https://example.com/audio")!
        let body = rangeAudio(count: 700_000)
        let source = rangeSource(sourceURL, data: body)
        let fixture = RangeDownloadFixture(
            root: root,
            sourceIDs: [sourceURL: 1],
            steps: [.partial(
                body.subdata(in: 0..<rangeBlockSize),
                range: 0..<rangeBlockSize,
                total: body.count,
                gate: gate
            )]
        )
        let cache = TrackRangeCache(trackCache: TrackCache(directory: root)) {
            try await fixture.download($0)
        }
        let session = try await cache.open(key: rangeKey, format: "mp3", initialSource: source) { source }
        let reader = Task { try await cache.read(session: session, offset: 100, maximumLength: 16) }
        try await waitForRangeCondition { await gate.hasEntered() }
        reader.cancel()
        await expectCancellation { _ = try await reader.value }
        try await waitForRangeCondition { await fixture.cancellations == 1 }
        #expect(await cache.descriptor(for: rangeKey) == nil)
        #expect(rangeFiles(in: root, withExtension: "plist").isEmpty)
        await cache.close(session)
    }

    @Test("206 rejects encoding, document MIME, wrong slice size, and wrong total")
    func partialResponseValidation() async throws {
        let sourceURL = URL(string: "https://example.com/audio")!
        let body = rangeAudio(count: 1_000)
        let source = rangeSource(sourceURL, data: body)
        let invalid: [(RangeResponseStep, TrackRangeCacheError)] = [
            (
                .partial(body.subdata(in: 0..<100), range: 0..<100, total: body.count, encoding: "gzip"),
                .rejectedResponse
            ),
            (
                .partial(body.subdata(in: 0..<100), range: 0..<100, total: body.count, contentType: "text/html"),
                .rejectedResponse
            ),
            (.partial(body.subdata(in: 0..<99), range: 0..<100, total: body.count), .rejectedResponse),
            (
                .partial(body.subdata(in: 0..<100), range: 0..<100, total: body.count + 1),
                .inconsistentRepresentation
            ),
        ]
        for (step, expectedError) in invalid {
            let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let fixture = RangeDownloadFixture(root: root, sourceIDs: [sourceURL: 1], steps: [step])
            let cache = TrackRangeCache(trackCache: TrackCache(directory: root)) {
                try await fixture.download($0)
            }
            let session = try await cache.open(key: rangeKey, format: "mp3", initialSource: source) { source }
            await expectRangeError(expectedError) {
                _ = try await cache.read(session: session, offset: 0, maximumLength: 1)
            }
            #expect(rangeFiles(in: root, withExtension: "plist").isEmpty)
            await cache.close(session)
        }
    }

    @Test("A 200 matching API identity installs one full body for published session")
    func completeResponseWithIdentity() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = URL(string: "https://example.com/audio")!
        let body = rangeAudio(count: 1_000)
        let source = rangeSource(sourceURL, data: body)
        let fixture = RangeDownloadFixture(
            root: root.appending(path: "responses"),
            sourceIDs: [sourceURL: 1],
            steps: [.complete(body)]
        )
        let trackCache = TrackCache(directory: root.appending(path: "StreamCache"))
        let cache = TrackRangeCache(trackCache: trackCache) { try await fixture.download($0) }
        let session = try await cache.open(key: rangeKey, format: "mp3", initialSource: source) { source }
        _ = try await cache.contentInfo(for: session)
        #expect(try await cache.read(session: session, offset: 100, maximumLength: 16) == body.subdata(in: 100..<116))
        #expect(await fixture.callCount() == 1)
        #expect(await trackCache.readyFile(for: rangeKey.songID, quality: rangeKey.quality) != nil)
        #expect(rangeFiles(in: root, withExtension: "plist").count == 1)
        await cache.close(session)
    }

    @Test("A 200 API digest mismatch never enters storeCopy")
    func completeDigestMismatch() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = URL(string: "https://example.com/audio")!
        let expected = rangeAudio(count: 1_000, fill: 1)
        let received = rangeAudio(count: 1_000, fill: 2)
        let source = rangeSource(sourceURL, data: expected)
        let fixture = RangeDownloadFixture(root: root, sourceIDs: [sourceURL: 1], steps: [.complete(received)])
        let lookups = RangeCounter()
        let trackCache = TrackCache(directory: root, beforeReadyLookup: { await lookups.increment() })
        let cache = TrackRangeCache(trackCache: trackCache) { try await fixture.download($0) }
        let session = try await cache.open(key: rangeKey, format: "mp3", initialSource: source) { source }
        await expectRangeError(.inconsistentRepresentation) {
            _ = try await cache.read(session: session, offset: 0, maximumLength: 1)
        }
        #expect(await lookups.value == 0)
        #expect(await cache.descriptor(for: rangeKey) == nil)
        #expect(await trackCache.readyFile(for: rangeKey.songID) == nil)
        await cache.close(session)
    }

    @Test("A 200 without API identity continues only before session publication")
    func completeWithoutIdentity() async throws {
        let sourceURL = URL(string: "https://example.com/audio")!
        let body = rangeAudio(count: 1_000)
        let source = rangeSource(sourceURL)

        let freshRoot = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: freshRoot) }
        let freshFixture = RangeDownloadFixture(root: freshRoot, sourceIDs: [sourceURL: 1], steps: [.complete(body)])
        let freshTrack = TrackCache(directory: freshRoot)
        let fresh = TrackRangeCache(trackCache: freshTrack) { try await freshFixture.download($0) }
        let freshSession = try await fresh.open(key: rangeKey, format: "mp3", initialSource: source) { source }
        #expect(try await fresh.read(session: freshSession, offset: 0, maximumLength: 8) == body.subdata(in: 0..<8))
        #expect(await freshTrack.readyFile(for: rangeKey.songID) != nil)
        await fresh.close(freshSession)

        let publishedRoot = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: publishedRoot) }
        let publishedFixture = RangeDownloadFixture(
            root: publishedRoot,
            sourceIDs: [sourceURL: 1],
            steps: [
                .partial(body.subdata(in: 0..<64), range: 0..<64, total: body.count, etag: "\"v1\""),
                .complete(body),
            ]
        )
        let publishedTrack = TrackCache(directory: publishedRoot)
        let published = TrackRangeCache(trackCache: publishedTrack) { try await publishedFixture.download($0) }
        let publishedSession = try await published.open(key: rangeKey, format: "mp3", initialSource: source) { source }
        #expect(try await published.read(session: publishedSession, offset: 0, maximumLength: 8) == body.subdata(in: 0..<8))
        await expectRangeError(.inconsistentRepresentation) {
            _ = try await published.read(session: publishedSession, offset: 100, maximumLength: 8)
        }
        #expect(await publishedTrack.readyFile(for: rangeKey.songID) != nil)
        await published.close(publishedSession)
    }

    @Test("416 checks known length before EOF and unresolved length refreshes at most once")
    func unsatisfiedResponses() async throws {
        let sourceURL = URL(string: "https://example.com/audio")!
        let knownBody = rangeAudio(count: 1_000)
        let known = rangeSource(sourceURL, data: knownBody)
        let mismatchRoot = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: mismatchRoot) }
        let mismatchFixture = RangeDownloadFixture(
            root: mismatchRoot,
            sourceIDs: [sourceURL: 1],
            steps: [.unsatisfied(length: 800)]
        )
        let mismatch = TrackRangeCache(trackCache: TrackCache(directory: mismatchRoot)) {
            try await mismatchFixture.download($0)
        }
        let mismatchSession = try await mismatch.open(key: rangeKey, format: "mp3", initialSource: known) { known }
        await expectRangeError(.inconsistentRepresentation) {
            _ = try await mismatch.read(session: mismatchSession, offset: 900, maximumLength: 1)
        }
        await mismatch.close(mismatchSession)

        let unresolvedRoot = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: unresolvedRoot) }
        let unresolved = rangeSource(sourceURL)
        let provider = RangeSourceFixture([unresolved])
        let unresolvedFixture = RangeDownloadFixture(
            root: unresolvedRoot,
            sourceIDs: [sourceURL: 1],
            steps: [.unsatisfied(length: 800), .unsatisfied(length: 800)]
        )
        let cache = TrackRangeCache(trackCache: TrackCache(directory: unresolvedRoot)) {
            try await unresolvedFixture.download($0)
        }
        let session = try await cache.open(
            key: rangeKey,
            format: "mp3",
            initialSource: unresolved,
            sourceProvider: { try await provider.next() }
        )
        await expectRangeError(.rejectedResponse) {
            _ = try await cache.read(session: session, offset: 100, maximumLength: 1)
        }
        #expect(await provider.calls == 1)
        #expect(await unresolvedFixture.callCount() == 2)
        await cache.close(session)
    }

    @Test("416 records normal EOF and a published offset below length never refreshes")
    func unsatisfiedEOFBoundaries() async throws {
        let sourceURL = URL(string: "https://example.com/audio")!

        let eofRoot = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: eofRoot) }
        let unresolved = rangeSource(sourceURL)
        let eofProvider = RangeSourceFixture([])
        let eofFixture = RangeDownloadFixture(
            root: eofRoot,
            sourceIDs: [sourceURL: 1],
            steps: [.unsatisfied(length: 800)]
        )
        let eofCache = TrackRangeCache(trackCache: TrackCache(directory: eofRoot)) {
            try await eofFixture.download($0)
        }
        let eofSession = try await eofCache.open(
            key: rangeKey,
            format: "mp3",
            initialSource: unresolved,
            sourceProvider: { try await eofProvider.next() }
        )
        #expect(try await eofCache.read(session: eofSession, offset: 900, maximumLength: 1).isEmpty)
        #expect(await eofProvider.calls == 0)
        #expect(await eofFixture.callCount() == 1)
        await eofCache.close(eofSession)

        let publishedRoot = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: publishedRoot) }
        let body = rangeAudio(count: 1_000)
        let known = rangeSource(sourceURL, data: body)
        let publishedProvider = RangeSourceFixture([known])
        let publishedFixture = RangeDownloadFixture(
            root: publishedRoot,
            sourceIDs: [sourceURL: 1],
            steps: [.unsatisfied(length: body.count)]
        )
        let publishedCache = TrackRangeCache(trackCache: TrackCache(directory: publishedRoot)) {
            try await publishedFixture.download($0)
        }
        let publishedSession = try await publishedCache.open(
            key: rangeKey,
            format: "mp3",
            initialSource: known,
            sourceProvider: { try await publishedProvider.next() }
        )
        _ = try await publishedCache.contentInfo(for: publishedSession)
        await expectRangeError(.inconsistentRepresentation) {
            _ = try await publishedCache.read(session: publishedSession, offset: 100, maximumLength: 1)
        }
        #expect(await publishedProvider.calls == 0)
        #expect(await publishedFixture.callCount() == 1)
        await publishedCache.close(publishedSession)
    }

    @Test("Concurrent 403 readers share one exact-identity refresh and both continue")
    func sourceRefreshAndIfRangeScope() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceA = URL(string: "https://m1.music.126.net/a")!
        let sourceB = URL(string: "https://m2.music.126.net/b")!
        let body = rangeAudio(count: rangeBlockSize * 2 + 1_000)
        let first = rangeSource(sourceA, data: body)
        let refreshed = rangeSource(sourceB, data: body)
        let expiryGate = RangeResponseGate()
        let providerGate = RangeResponseGate()
        let retryGate = RangeResponseGate()
        let provider = RangeSourceFixture([refreshed], gate: providerGate)
        let retryRange = 64..<(rangeBlockSize * 2)
        let retryBody = body.subdata(in: retryRange)
        let fixture = RangeDownloadFixture(
            root: root,
            sourceIDs: [sourceA: 1, sourceB: 2],
            steps: [
                .partial(body.subdata(in: 0..<64), range: 0..<64, total: body.count, etag: "\"old\""),
                RangeResponseStep(status: 403, gate: expiryGate),
                RangeResponseStep(status: 403, gate: expiryGate),
                .partial(retryBody, range: retryRange, total: body.count, gate: retryGate),
            ]
        )
        let cache = TrackRangeCache(trackCache: TrackCache(directory: root)) {
            try await fixture.download($0)
        }
        let session = try await cache.open(
            key: rangeKey,
            format: "mp3",
            initialSource: first,
            sourceProvider: { try await provider.next() }
        )
        #expect(try await cache.read(session: session, offset: 0, maximumLength: 8) == body.subdata(in: 0..<8))
        let firstReader = Task {
            try await cache.read(session: session, offset: 100, maximumLength: 8)
        }
        try await waitForRangeCondition { await expiryGate.waiterCount() == 1 }
        let secondOffset = rangeBlockSize + 100
        let secondReader = Task {
            try await cache.read(session: session, offset: Int64(secondOffset), maximumLength: 8)
        }
        try await waitForRangeCondition { await expiryGate.waiterCount() == 2 }
        await expiryGate.release()
        try await waitForRangeCondition { await providerGate.hasEntered() }
        #expect(await provider.calls == 1)
        await providerGate.release()
        try await waitForRangeCondition { await retryGate.waiterCount() == 1 }
        await retryGate.release()
        #expect(try await firstReader.value == body.subdata(in: 100..<108))
        #expect(try await secondReader.value == body.subdata(in: secondOffset..<(secondOffset + 8)))
        #expect(await provider.calls == 1)
        #expect(await fixture.requests.map(\.sourceID) == [1, 1, 1, 2])
        #expect(await fixture.requests.map(\.ifRange) == [nil, "\"old\"", "\"old\"", nil])
        await cache.close(session)
    }

    @Test("A full response supersedes a blocked refresh without calling the provider again")
    func fullResponseSupersedesRefresh() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = URL(string: "https://example.com/audio")!
        let body = rangeAudio(count: rangeBlockSize * 2 + 1_000)
        let source = rangeSource(sourceURL, data: body)
        let expiryGate = RangeResponseGate()
        let completeGate = RangeResponseGate()
        let providerGate = RangeResponseGate()
        let provider = RangeSourceFixture([source], gate: providerGate)
        let fixture = RangeDownloadFixture(
            root: root.appending(path: "responses"),
            sourceIDs: [sourceURL: 1],
            steps: [
                .partial(body.subdata(in: 0..<64), range: 0..<64, total: body.count),
                RangeResponseStep(status: 403, gate: expiryGate),
                .complete(body, gate: completeGate),
            ]
        )
        let trackCache = TrackCache(directory: root.appending(path: "StreamCache"))
        let cache = TrackRangeCache(trackCache: trackCache) { try await fixture.download($0) }
        let session = try await cache.open(
            key: rangeKey,
            format: "mp3",
            initialSource: source,
            sourceProvider: { try await provider.next() }
        )
        _ = try await cache.read(session: session, offset: 0, maximumLength: 1)

        let refreshing = Task {
            try await cache.read(session: session, offset: 100, maximumLength: 8)
        }
        try await waitForRangeCondition { await expiryGate.hasEntered() }
        let completingOffset = rangeBlockSize + 100
        let completing = Task {
            try await cache.read(
                session: session,
                offset: Int64(completingOffset),
                maximumLength: 8
            )
        }
        try await waitForRangeCondition { await completeGate.hasEntered() }
        await expiryGate.release()
        try await waitForRangeCondition { await providerGate.hasEntered() }
        await completeGate.release()
        try await waitForRangeCondition { await providerGate.cancellations == 1 }
        await providerGate.release()

        #expect(try await refreshing.value == body.subdata(in: 100..<108))
        #expect(try await completing.value == body.subdata(
            in: completingOffset..<(completingOffset + 8)
        ))
        #expect(await provider.calls == 1)
        #expect(await fixture.callCount() == 3)
        #expect(await trackCache.readyFile(for: rangeKey.songID, quality: rangeKey.quality) != nil)
        await cache.close(session)
    }

    @Test("Explicit source supersedes and wakes a blocked provider flight")
    func explicitSourceSupersedesProvider() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceA = URL(string: "https://m1.music.126.net/a")!
        let sourceB = URL(string: "https://m2.music.126.net/b")!
        let body = rangeAudio(count: 1_000)
        let firstFixture = RangeDownloadFixture(
            root: root.appending(path: "first-responses"),
            sourceIDs: [sourceA: 1],
            steps: [.partial(body.subdata(in: 0..<64), range: 0..<64, total: body.count)]
        )
        let trackCache = TrackCache(directory: root.appending(path: "StreamCache"))
        let first = TrackRangeCache(trackCache: trackCache) { try await firstFixture.download($0) }
        let firstSource = rangeSource(sourceA, data: body)
        let firstSession = try await first.open(
            key: rangeKey,
            format: "mp3",
            initialSource: firstSource,
            sourceProvider: { firstSource }
        )
        _ = try await first.read(session: firstSession, offset: 0, maximumLength: 1)
        await first.close(firstSession)

        let providerGate = RangeResponseGate()
        let provider = RangeSourceFixture([firstSource], gate: providerGate)
        let secondFixture = RangeDownloadFixture(
            root: root.appending(path: "second-responses"),
            sourceIDs: [sourceB: 2],
            steps: [.partial(body.subdata(in: 64..<128), range: 64..<128, total: body.count)]
        )
        let rebuilt = TrackRangeCache(trackCache: trackCache) { try await secondFixture.download($0) }
        #expect(await rebuilt.descriptor(for: rangeKey) != nil)
        let waitingSession = try await rebuilt.open(
            key: rangeKey,
            format: "mp3",
            initialSource: nil,
            sourceProvider: { try await provider.next() }
        )
        let waitingRead = Task {
            try await rebuilt.read(session: waitingSession, offset: 100, maximumLength: 8)
        }
        try await waitForRangeCondition { await providerGate.hasEntered() }
        let replacement = rangeSource(sourceB, data: body)
        let replacementSession = try await rebuilt.open(
            key: rangeKey,
            format: "mp3",
            initialSource: replacement,
            sourceProvider: { replacement }
        )
        #expect(try await waitingRead.value == body.subdata(in: 100..<108))
        #expect(await provider.calls == 1)
        try await waitForRangeCondition { await providerGate.cancellations == 1 }
        #expect(await providerGate.cancellations == 1)
        #expect(await secondFixture.requests.map(\.sourceID) == [2])
        await rebuilt.close(waitingSession)
        await rebuilt.close(replacementSession)
    }

    @Test("Refresh same URL, repeated expiry, and level mismatch stop without loops")
    func sourceRefreshFailures() async throws {
        let sourceA = URL(string: "https://example.com/a")!
        let sourceB = URL(string: "https://example.com/b")!
        let body = rangeAudio(count: 1_000)
        let initial = rangeSource(sourceA, data: body)
        let scenarios: [([RangeResponseStep], PlaybackSource, TrackRangeCacheError, Int)] = [
            ([RangeResponseStep(status: 403)], initial, .sourceExpired, 1),
            ([RangeResponseStep(status: 403), RangeResponseStep(status: 403)], rangeSource(sourceB, data: body), .sourceExpired, 2),
            ([RangeResponseStep(status: 403)], rangeSource(sourceB, data: body, level: "higher"), .sourceLevelMismatch(expected: "standard", actual: "higher"), 1),
        ]

        for (steps, nextSource, expected, expectedDownloads) in scenarios {
            let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let provider = RangeSourceFixture([nextSource])
            let fixture = RangeDownloadFixture(root: root, sourceIDs: [sourceA: 1, sourceB: 2], steps: steps)
            let cache = TrackRangeCache(trackCache: TrackCache(directory: root)) {
                try await fixture.download($0)
            }
            let session = try await cache.open(
                key: rangeKey,
                format: "mp3",
                initialSource: initial,
                sourceProvider: { try await provider.next() }
            )
            await expectRangeError(expected) {
                _ = try await cache.read(session: session, offset: 0, maximumLength: 1)
            }
            #expect(await provider.calls == 1)
            #expect(await fixture.callCount() == expectedDownloads)
            await cache.close(session)
        }
    }

    @Test("Redirected persistent response never scopes its ETag to the original URL")
    func redirectIfRangeScope() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = URL(string: "https://m1.music.126.net/a")!
        let effectiveURL = URL(string: "https://m2.music.126.net/b")!
        let body = rangeAudio(count: 1_000)
        let source = rangeSource(sourceURL, data: body)
        let fixture = RangeDownloadFixture(
            root: root,
            sourceIDs: [sourceURL: 1],
            steps: [
                .partial(body.subdata(in: 0..<64), range: 0..<64, total: body.count, etag: "\"edge\"", effectiveURL: effectiveURL),
                .partial(body.subdata(in: 64..<128), range: 64..<128, total: body.count, etag: "\"edge\"", effectiveURL: effectiveURL),
            ]
        )
        let cache = TrackRangeCache(trackCache: TrackCache(directory: root)) {
            try await fixture.download($0)
        }
        let session = try await cache.open(key: rangeKey, format: "mp3", initialSource: source) { source }
        _ = try await cache.read(session: session, offset: 0, maximumLength: 1)
        _ = try await cache.read(session: session, offset: 100, maximumLength: 1)
        #expect(await fixture.requests.map(\.ifRange) == [nil, nil])
        await cache.close(session)
    }

    @Test("Redirect policy and If-Range validator boundaries are exact")
    func redirectAndValidatorBoundaries() async throws {
        let body = rangeAudio(count: 1_000)
        let sourceURL = URL(string: "https://example.com/audio")!

        let forbiddenRoot = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: forbiddenRoot) }
        let forbiddenFixture = RangeDownloadFixture(
            root: forbiddenRoot,
            sourceIDs: [sourceURL: 1],
            steps: [.partial(
                body.subdata(in: 0..<64),
                range: 0..<64,
                total: body.count,
                effectiveURL: URL(string: "https://other.example.net/audio")!
            )]
        )
        let forbidden = TrackRangeCache(trackCache: TrackCache(directory: forbiddenRoot)) {
            try await forbiddenFixture.download($0)
        }
        let forbiddenSession = try await forbidden.open(
            key: rangeKey,
            format: "mp3",
            initialSource: rangeSource(sourceURL, data: body),
            sourceProvider: { rangeSource(sourceURL, data: body) }
        )
        await expectRangeError(.rejectedResponse) {
            _ = try await forbidden.read(session: forbiddenSession, offset: 0, maximumLength: 1)
        }
        #expect(rangeFiles(in: forbiddenRoot, withExtension: "plist").isEmpty)
        await forbidden.close(forbiddenSession)

        let weakRoot = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: weakRoot) }
        let weakFixture = RangeDownloadFixture(
            root: weakRoot,
            sourceIDs: [sourceURL: 1],
            steps: [
                RangeResponseStep(
                    status: 206,
                    body: body.subdata(in: 0..<64),
                    headers: [
                        "Content-Range": "bytes 0-63/\(body.count)",
                        "Content-Type": "audio/mpeg",
                        "ETag": "W/\"weak\"",
                        "Last-Modified": "Wed, 21 Oct 2015 07:28:00 GMT",
                    ]
                ),
                .partial(body.subdata(in: 64..<128), range: 64..<128, total: body.count),
            ]
        )
        let weak = TrackRangeCache(trackCache: TrackCache(directory: weakRoot)) {
            try await weakFixture.download($0)
        }
        let weakSession = try await weak.open(
            key: rangeKey,
            format: "mp3",
            initialSource: rangeSource(sourceURL, data: body),
            sourceProvider: { rangeSource(sourceURL, data: body) }
        )
        _ = try await weak.read(session: weakSession, offset: 0, maximumLength: 1)
        _ = try await weak.read(session: weakSession, offset: 100, maximumLength: 1)
        #expect(await weakFixture.requests.map(\.ifRange) == [nil, nil])
        await weak.close(weakSession)

        let strongRoot = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: strongRoot) }
        let strongFixture = RangeDownloadFixture(
            root: strongRoot,
            sourceIDs: [sourceURL: 1],
            steps: [
                .partial(body.subdata(in: 0..<64), range: 0..<64, total: body.count, etag: "\"v1\""),
                .partial(body.subdata(in: 64..<128), range: 64..<128, total: body.count),
            ]
        )
        let strong = TrackRangeCache(trackCache: TrackCache(directory: strongRoot)) {
            try await strongFixture.download($0)
        }
        let strongSession = try await strong.open(
            key: rangeKey,
            format: "mp3",
            initialSource: rangeSource(sourceURL, data: body),
            sourceProvider: { rangeSource(sourceURL, data: body) }
        )
        _ = try await strong.read(session: strongSession, offset: 0, maximumLength: 1)
        #expect(try await strong.read(session: strongSession, offset: 100, maximumLength: 1) == body.subdata(in: 100..<101))
        #expect(await strongFixture.requests.map(\.ifRange) == [nil, "\"v1\""])
        await strong.close(strongSession)
    }

    @Test("Representation change fences a late non-cooperative old-epoch response")
    func representationEpochFencesLateResponse() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceA = URL(string: "https://m1.music.126.net/a")!
        let sourceB = URL(string: "https://m2.music.126.net/b")!
        let oldBody = rangeAudio(count: rangeBlockSize * 2, fill: 1)
        let newBody = rangeAudio(count: oldBody.count, fill: 2)
        let oldSource = rangeSource(sourceA, data: oldBody)
        let provider = RangeSourceFixture([rangeSource(sourceB, data: newBody)])
        let lateGate = RangeResponseGate()
        let fixture = RangeDownloadFixture(
            root: root.appending(path: "responses"),
            sourceIDs: [sourceA: 1, sourceB: 2],
            steps: [
                .partial(
                    oldBody.subdata(in: 0..<64),
                    range: 0..<64,
                    total: oldBody.count
                ),
                .partial(
                    oldBody.subdata(in: 64..<rangeBlockSize),
                    range: 64..<rangeBlockSize,
                    total: oldBody.count,
                    gate: lateGate,
                    ignoresCancellation: true
                ),
                RangeResponseStep(status: 403),
            ]
        )
        let trackCache = TrackCache(directory: root.appending(path: "StreamCache"))
        let cache = TrackRangeCache(trackCache: trackCache) { try await fixture.download($0) }
        let first = try await cache.open(
            key: rangeKey,
            format: "mp3",
            initialSource: oldSource,
            sourceProvider: { try await provider.next() }
        )
        #expect(try await cache.read(session: first, offset: 0, maximumLength: 1) == oldBody.subdata(in: 0..<1))
        let second = try await cache.open(
            key: rangeKey,
            format: "mp3",
            initialSource: oldSource,
            sourceProvider: { try await provider.next() }
        )
        let oldBodyURL = try #require(rangeFiles(in: root, withExtension: "range").first)
        let lateReader = Task {
            try await cache.read(session: first, offset: 100, maximumLength: 1)
        }
        try await waitForRangeCondition { await lateGate.hasEntered() }
        let mismatchReader = Task {
            try await cache.read(
                session: second,
                offset: Int64(rangeBlockSize + 100),
                maximumLength: 1
            )
        }
        await expectRangeError(.inconsistentRepresentation) {
            _ = try await mismatchReader.value
        }
        await expectRangeError(.inconsistentRepresentation) {
            _ = try await lateReader.value
        }
        #expect(await provider.calls == 1)
        #expect(await cache.descriptor(for: rangeKey) == nil)
        #expect(rangeFiles(in: root, withExtension: "plist").isEmpty)

        await lateGate.release()
        try await waitForRangeCondition { await fixture.completions == 3 }
        try await waitForRangeCondition {
            rangeFiles(in: root.appending(path: "responses"), withExtension: "").isEmpty
        }
        #expect(await cache.descriptor(for: rangeKey) == nil)
        #expect(rangeFiles(in: root, withExtension: "plist").isEmpty)
        #expect(FileManager.default.fileExists(atPath: oldBodyURL.path))
        #expect((try? oldBodyURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) == 64)
        #expect(try Data(contentsOf: oldBodyURL) == oldBody.subdata(in: 0..<64))

        let replacement = try await cache.open(
            key: rangeKey,
            format: "mp3",
            initialSource: rangeSource(sourceB, data: newBody),
            sourceProvider: { rangeSource(sourceB, data: newBody) }
        )
        let bodyURLs = rangeFiles(in: root, withExtension: "range")
        #expect(bodyURLs.count == 2)
        #expect(bodyURLs.contains(oldBodyURL))
        await cache.close(first)
        await cache.close(second)
        await cache.close(replacement)
        try await cache.clear()
        try await waitForRangeCondition { rangeFiles(in: root, withExtension: "range").isEmpty }
    }

    @Test("Full sparse body verifies MD5 before storeCopy and mismatch never looks up ready file")
    func fullSparseDigestGate() async throws {
        for matches in [true, false] {
            let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let sourceURL = URL(string: "https://example.com/audio")!
            let body = rangeAudio(count: 1_000, fill: 1)
            let identityBody = matches ? body : rangeAudio(count: body.count, fill: 2)
            let source = rangeSource(sourceURL, data: identityBody)
            let fixture = RangeDownloadFixture(
                root: root.appending(path: "responses"),
                sourceIDs: [sourceURL: 1],
                steps: [.partial(body, range: 0..<body.count, total: body.count)]
            )
            let lookups = RangeCounter()
            let trackCache = TrackCache(
                directory: root.appending(path: "StreamCache"),
                beforeReadyLookup: { await lookups.increment() }
            )
            let cache = TrackRangeCache(trackCache: trackCache) { try await fixture.download($0) }
            let session = try await cache.open(key: rangeKey, format: "mp3", initialSource: source) { source }
            if matches {
                #expect(try await cache.read(session: session, offset: 0, maximumLength: 8) == body.subdata(in: 0..<8))
                #expect(await lookups.value == 1)
                #expect(await trackCache.readyFile(for: rangeKey.songID) != nil)
            } else {
                await expectRangeError(.inconsistentRepresentation) {
                    _ = try await cache.read(session: session, offset: 0, maximumLength: 8)
                }
                #expect(await lookups.value == 0)
                #expect(await trackCache.readyFile(for: rangeKey.songID) == nil)
            }
            await cache.close(session)
        }
    }

    @Test("Install CocoaError is propagated without retrying the entry")
    func installErrorIsTerminal() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = URL(string: "https://example.com/audio")!
        let body = rangeAudio(count: 1_000)
        let source = rangeSource(sourceURL, data: body)
        let lookups = RangeCounter()
        let trackCache = TrackCache(directory: root, beforeReadyLookup: { await lookups.increment() })
        let blocker = trackCache.fileURL(for: rangeKey.songID, quality: rangeKey.quality)
        try FileManager.default.createDirectory(
            at: blocker.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data([0, 1]).write(to: blocker)
        #expect(await trackCache.pin(blocker))
        let fixture = RangeDownloadFixture(
            root: root.appending(path: "responses"),
            sourceIDs: [sourceURL: 1],
            steps: [.partial(body, range: 0..<body.count, total: body.count)]
        )
        let cache = TrackRangeCache(trackCache: trackCache) { try await fixture.download($0) }
        let session = try await cache.open(
            key: rangeKey,
            format: "mp3",
            initialSource: source,
            sourceProvider: { source }
        )

        for _ in 0..<2 {
            do {
                _ = try await cache.read(session: session, offset: 0, maximumLength: 8)
                Issue.record("Expected install error")
            } catch let error as CocoaError {
                #expect(error.code == .fileWriteFileExists)
            } catch {
                Issue.record("Unexpected install error type")
            }
        }
        #expect(await lookups.value == 1)
        #expect(await fixture.callCount() == 1)
        await cache.close(session)
        await trackCache.unpin(blocker)
    }

    @Test("A digest error after pin releases the full-file pin")
    func postPinDigestErrorReleasesFullPin() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = URL(string: "https://example.com/audio")!
        let body = rangeAudio(count: 1_000)
        let source = rangeSource(sourceURL, data: body)
        let fullPinGate = RangeLookupGate()
        let trackCache = TrackCache(directory: root)
        let fixture = RangeDownloadFixture(
            root: root.appending(path: "responses"),
            sourceIDs: [sourceURL: 1],
            steps: [.partial(body, range: 0..<body.count, total: body.count)]
        )
        let cache = TrackRangeCache(
            trackCache: trackCache,
            download: { try await fixture.download($0) },
            afterPinForTesting: { url in
                if url.pathExtension != "range" { await fullPinGate.wait() }
            }
        )
        let session = try await cache.open(
            key: rangeKey,
            format: "mp3",
            initialSource: source,
            sourceProvider: { source }
        )
        let reader = Task {
            try await cache.read(session: session, offset: 0, maximumLength: 8)
        }
        try await waitForRangeCondition { await fullPinGate.hasEntered() }

        let fullURL = trackCache.fileURL(for: rangeKey.songID, quality: rangeKey.quality)
        try FileManager.default.removeItem(at: fullURL)
        await fullPinGate.release()
        do {
            _ = try await reader.value
            Issue.record("Expected post-pin digest error")
        } catch is CocoaError {
        } catch {
            Issue.record("Unexpected post-pin digest error type")
        }
        #expect(await fixture.callCount() == 1)

        try body.write(to: fullURL)
        await trackCache.invalidateCachedFile(fullURL)
        #expect(!FileManager.default.fileExists(atPath: fullURL.path))
        await cache.close(session)
    }

    @Test("Existing full mismatch preserves verified sparse bytes for current session")
    func existingFullMismatch() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = URL(string: "https://example.com/audio")!
        let body = rangeAudio(count: 1_000, fill: 1)
        let existing = rangeAudio(count: body.count, fill: 2)
        let source = rangeSource(sourceURL, data: body)
        let gate = RangeLookupGate()
        let trackCache = TrackCache(directory: root, beforeReadyLookup: { await gate.wait() })
        let fixture = RangeDownloadFixture(
            root: root.appending(path: "responses"),
            sourceIDs: [sourceURL: 1],
            steps: [.partial(body, range: 0..<body.count, total: body.count)]
        )
        let cache = TrackRangeCache(trackCache: trackCache) { try await fixture.download($0) }
        let session = try await cache.open(key: rangeKey, format: "mp3", initialSource: source) { source }
        let reader = Task { try await cache.read(session: session, offset: 100, maximumLength: 16) }
        try await waitForRangeCondition { await gate.hasEntered() }
        let existingURL = root.appending(path: "existing.tmp")
        try existing.write(to: existingURL)
        _ = try await trackCache.finalize(existingURL, for: rangeKey.songID, quality: rangeKey.quality)
        await gate.release()

        #expect(try await reader.value == body.subdata(in: 100..<116))
        let ready = try #require(await trackCache.readyFile(for: rangeKey.songID, quality: rangeKey.quality))
        #expect(try Data(contentsOf: ready) == existing)
        #expect(await cache.descriptor(for: rangeKey) == nil)
        await cache.close(session)
        try await waitForRangeCondition { rangeFiles(in: root, withExtension: "range").isEmpty }
        #expect(FileManager.default.fileExists(atPath: ready.path))
    }

    @Test("A new identity after install hides the full file without breaking the old session")
    func installedIdentityReplacement() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = URL(string: "https://example.com/audio")!
        let oldBody = rangeAudio(count: 1_000, fill: 1)
        let newBody = rangeAudio(count: oldBody.count, fill: 2)
        let oldSource = rangeSource(sourceURL, data: oldBody)
        let newSource = rangeSource(sourceURL, data: newBody)
        let gate = RangeLookupGate()
        let installWaitGate = RangeLookupGate()
        let trackCache = TrackCache(
            directory: root.appending(path: "StreamCache"),
            beforeReadyLookup: { await gate.wait() }
        )
        let fixture = RangeDownloadFixture(
            root: root.appending(path: "responses"),
            sourceIDs: [sourceURL: 1],
            steps: [.partial(oldBody, range: 0..<oldBody.count, total: oldBody.count)]
        )
        let cache = TrackRangeCache(
            trackCache: trackCache,
            download: { try await fixture.download($0) },
            beforeInstallWaitForTesting: { await installWaitGate.wait() }
        )
        let oldSession = try await cache.open(
            key: rangeKey,
            format: "mp3",
            initialSource: oldSource,
            sourceProvider: { oldSource }
        )
        let oldRead = Task {
            try await cache.read(session: oldSession, offset: 100, maximumLength: 16)
        }
        try await waitForRangeCondition { await gate.hasEntered() }
        let oldRangeBody = try #require(rangeFiles(in: root, withExtension: "range").first)

        let replacementOpen = Task {
            try await cache.open(
                key: rangeKey,
                format: "mp3",
                initialSource: newSource,
                sourceProvider: { newSource }
            )
        }
        try await waitForRangeCondition { await installWaitGate.hasEntered() }
        await installWaitGate.release()
        await gate.release()
        let replacementSession = try await replacementOpen.value

        #expect(try await oldRead.value == oldBody.subdata(in: 100..<116))
        #expect(try await cache.read(
            session: oldSession,
            offset: 200,
            maximumLength: 8
        ) == oldBody.subdata(in: 200..<208))
        let fullURL = trackCache.fileURL(for: rangeKey.songID, quality: rangeKey.quality)
        #expect(await trackCache.readyFile(for: rangeKey.songID, quality: rangeKey.quality) == nil)
        #expect(FileManager.default.fileExists(atPath: fullURL.path))
        #expect(await cache.descriptor(for: rangeKey) == nil)
        #expect(try await cache.contentInfo(for: replacementSession).contentLength == Int64(newBody.count))
        let replacementBodies = rangeFiles(in: root, withExtension: "range")
        #expect(replacementBodies.count == 1)
        #expect(!replacementBodies.contains(oldRangeBody))

        await cache.close(oldSession)
        try await waitForRangeCondition { !FileManager.default.fileExists(atPath: fullURL.path) }
        await cache.close(replacementSession)
        try await waitForRangeCondition { rangeFiles(in: root, withExtension: "range").isEmpty }
    }

    @Test("Clear retires active entry, removes inactive entries, and late 206 cannot republish metadata")
    func clearLifecycleAndLatePartial() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = RangeResponseGate()
        let sourceURL = URL(string: "https://example.com/audio")!
        let body = rangeAudio(count: 700_000)
        let source = rangeSource(sourceURL, data: body)
        let fixture = RangeDownloadFixture(
            root: root,
            sourceIDs: [sourceURL: 1],
            steps: [.partial(
                body.subdata(in: 0..<rangeBlockSize),
                range: 0..<rangeBlockSize,
                total: body.count,
                gate: gate
            )]
        )
        let cache = TrackRangeCache(trackCache: TrackCache(directory: root)) {
            try await fixture.download($0)
        }
        let session = try await cache.open(key: rangeKey, format: "mp3", initialSource: source) { source }
        let reader = Task { try await cache.read(session: session, offset: 100, maximumLength: 16) }
        try await waitForRangeCondition { await gate.hasEntered() }
        try await cache.clear()
        #expect(await cache.descriptor(for: rangeKey) == nil)
        await gate.release()
        #expect(try await reader.value == body.subdata(in: 100..<116))
        #expect(rangeFiles(in: root, withExtension: "plist").isEmpty)
        #expect(try await cache.read(session: session, offset: 120, maximumLength: 8) == body.subdata(in: 120..<128))
        await cache.close(session)
        try await waitForRangeCondition { rangeFiles(in: root, withExtension: "range").isEmpty }

        let inactiveRoot = root.appending(path: "inactive")
        let inactiveFixture = RangeDownloadFixture(
            root: inactiveRoot,
            sourceIDs: [sourceURL: 1],
            steps: [.partial(body.subdata(in: 0..<100), range: 0..<100, total: body.count)]
        )
        let inactive = TrackRangeCache(trackCache: TrackCache(directory: inactiveRoot)) {
            try await inactiveFixture.download($0)
        }
        let inactiveSession = try await inactive.open(key: rangeKey, format: "mp3", initialSource: source) { source }
        _ = try await inactive.read(session: inactiveSession, offset: 0, maximumLength: 1)
        await inactive.close(inactiveSession)
        try await waitForRangeCondition { !rangeFiles(in: inactiveRoot, withExtension: "plist").isEmpty }
        try await inactive.clear()
        #expect(rangeFiles(in: inactiveRoot, withExtension: "range").isEmpty)
        #expect(rangeFiles(in: inactiveRoot, withExtension: "plist").isEmpty)
    }

    @Test("Clear after metadata fences late matching 200 and full-coverage 206 installs")
    func clearFencesLateCompleteResponses() async throws {
        let sourceURL = URL(string: "https://example.com/audio")!
        let body = rangeAudio(count: 1_000)
        let source = rangeSource(sourceURL, data: body)

        for lateStatus in [200, 206] {
            let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let gate = RangeResponseGate()
            let lookups = RangeCounter()
            let trackCache = TrackCache(directory: root, beforeReadyLookup: { await lookups.increment() })
            let lateStep = lateStatus == 200
                ? RangeResponseStep.complete(body, gate: gate)
                : RangeResponseStep.partial(
                    body,
                    range: 0..<body.count,
                    total: body.count,
                    gate: gate
                )
            let fixture = RangeDownloadFixture(
                root: root.appending(path: "responses"),
                sourceIDs: [sourceURL: 1],
                steps: [
                    .partial(body.subdata(in: 0..<64), range: 0..<64, total: body.count),
                    lateStep,
                ]
            )
            let cache = TrackRangeCache(trackCache: trackCache) { try await fixture.download($0) }
            let session = try await cache.open(
                key: rangeKey,
                format: "mp3",
                initialSource: source,
                sourceProvider: { source }
            )
            #expect(try await cache.read(session: session, offset: 0, maximumLength: 1) == body.subdata(in: 0..<1))
            try await waitForRangeCondition { rangeFiles(in: root, withExtension: "plist").count == 1 }

            let reader = Task {
                try await cache.read(session: session, offset: 100, maximumLength: 8)
            }
            try await waitForRangeCondition { await gate.hasEntered() }
            try await cache.clear()
            #expect(await cache.descriptor(for: rangeKey) == nil)
            #expect(rangeFiles(in: root, withExtension: "plist").isEmpty)
            await gate.release()

            #expect(try await reader.value == body.subdata(in: 100..<108))
            #expect(await lookups.value == 0)
            #expect(await trackCache.readyFile(for: rangeKey.songID, quality: rangeKey.quality) == nil)
            #expect(rangeFiles(in: root, withExtension: "plist").isEmpty)
            #expect(await cache.descriptor(for: rangeKey) == nil)
            await cache.close(session)
            try await waitForRangeCondition { rangeFiles(in: root, withExtension: "range").isEmpty }
        }
    }

    @Test("Clear waits for install already inside storeCopy and outer clear removes its result")
    func clearWaitsForStoreCopy() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = URL(string: "https://example.com/audio")!
        let body = rangeAudio(count: 1_000)
        let source = rangeSource(sourceURL, data: body)
        let gate = RangeLookupGate()
        let flag = RangeFlag()
        let trackCache = TrackCache(directory: root, beforeReadyLookup: { await gate.wait() })
        let fixture = RangeDownloadFixture(
            root: root.appending(path: "responses"),
            sourceIDs: [sourceURL: 1],
            steps: [.partial(body, range: 0..<body.count, total: body.count)]
        )
        let cache = TrackRangeCache(trackCache: trackCache) { try await fixture.download($0) }
        let session = try await cache.open(key: rangeKey, format: "mp3", initialSource: source) { source }
        let reader = Task { try await cache.read(session: session, offset: 0, maximumLength: 8) }
        try await waitForRangeCondition { await gate.hasEntered() }
        let clearing = Task {
            try await cache.clear()
            await flag.set()
        }
        for _ in 0..<10 { await Task.yield() }
        #expect(await flag.value == false)
        await gate.release()
        try await clearing.value
        #expect(await flag.value)
        #expect(try await reader.value == body.subdata(in: 0..<8))
        try await trackCache.clear()
        #expect(await trackCache.readyFile(for: rangeKey.songID) == nil)
        #expect(await cache.descriptor(for: rangeKey) == nil)
        await cache.close(session)
        try await waitForRangeCondition { rangeFiles(in: root, withExtension: "range").isEmpty }
    }

    @Test("Open cancellation after body creation rolls back mapping, pin, and body")
    func openCancellationRollback() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = URL(string: "https://example.com/audio")!
        let body = rangeAudio(count: 700_000)
        let source = rangeSource(sourceURL, data: body)
        let pinGate = RangeLookupGate()
        let cache = TrackRangeCache(
            trackCache: TrackCache(directory: root),
            afterPinForTesting: { url in
                if url.pathExtension == "range" { await pinGate.wait() }
            }
        )
        let opening = Task {
            try await cache.open(key: rangeKey, format: "mp3", initialSource: source) { source }
        }
        try await waitForRangeCondition { await pinGate.hasEntered() }
        #expect(rangeFiles(in: root, withExtension: "range").count == 1)
        opening.cancel()
        await pinGate.release()
        await expectCancellation { _ = try await opening.value }
        try await waitForRangeCondition { rangeFiles(in: root, withExtension: "range").isEmpty }
        #expect(await cache.descriptor(for: rangeKey) == nil)
        try await cache.clear()
        #expect(rangeFiles(in: root, withExtension: "range").isEmpty)
    }

    @Test("Cancelling the first concurrent opener preserves its sibling session")
    func concurrentOpenCancellationPreservesSibling() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = URL(string: "https://example.com/audio")!
        let body = rangeAudio(count: 700_000)
        let source = rangeSource(sourceURL, data: body)
        let cache = TrackRangeCache(trackCache: TrackCache(directory: root))
        let first = Task(priority: .background) {
            try await cache.open(
                key: rangeKey,
                format: "mp3",
                initialSource: source,
                sourceProvider: { source }
            )
        }
        var createdBody = false
        for _ in 0..<10_000 {
            if !rangeFiles(in: root, withExtension: "range").isEmpty {
                createdBody = true
                break
            }
            await Task.yield()
        }
        #expect(createdBody)
        let originalBody = try #require(rangeFiles(in: root, withExtension: "range").first)
        let sibling = Task(priority: .high) {
            try await cache.open(
                key: rangeKey,
                format: "mp3",
                initialSource: source,
                sourceProvider: { source }
            )
        }
        let siblingSession = try await sibling.value
        first.cancel()
        do {
            let firstSession = try await first.value
            await cache.close(firstSession)
        } catch is CancellationError {
        }
        #expect(rangeFiles(in: root, withExtension: "range") == [originalBody])
        #expect(try await cache.contentInfo(for: siblingSession).contentLength == Int64(body.count))
        await cache.close(siblingSession)
        try await cache.clear()
        #expect(rangeFiles(in: root, withExtension: "range").isEmpty)
    }
}
