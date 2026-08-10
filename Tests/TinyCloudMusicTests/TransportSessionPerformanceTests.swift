import Foundation
import Network
import Testing
@testable import TinyCloudMusic

private final class TransportFixtureProtocol: URLProtocol, @unchecked Sendable {
    struct Stub: Sendable {
        let status: Int
        let headers: [String: String]
        let body: Data
        let blocksResponse: Bool

        init(status: Int = 200, headers: [String: String] = [:], body: String, blocksResponse: Bool = false) {
            self.status = status
            self.headers = headers
            self.body = Data(body.utf8)
            self.blocksResponse = blocksResponse
        }
    }

    typealias Handler = @Sendable (URLRequest, Int) -> Stub

    private static let lock = NSLock()
    nonisolated(unsafe) private static var handler: Handler = { _, _ in Stub(body: #"{"code":200}"#) }
    nonisolated(unsafe) private static var requests: [URLRequest] = []
    nonisolated(unsafe) private static var responses: [URLRequest] = []
    nonisolated(unsafe) private static var pending: [@Sendable () -> Void] = []
    nonisolated(unsafe) private static var blocksResponses = false

    static func reset(blocksResponses: Bool = false, handler: @escaping Handler) {
        lock.withLock {
            self.handler = handler
            requests = []
            responses = []
            pending = []
            self.blocksResponses = blocksResponses
        }
    }

    static var requestCount: Int { lock.withLock { requests.count } }

    static func requestCount(path: String) -> Int {
        lock.withLock { requests.count { $0.url?.path == path } }
    }

    static func requests(path: String) -> [URLRequest] {
        lock.withLock { requests.filter { $0.url?.path == path } }
    }

    static func responseCount(path: String) -> Int {
        lock.withLock { responses.count { $0.url?.path == path } }
    }

    static func releaseResponses() {
        let callbacks = lock.withLock {
            let callbacks = pending
            pending = []
            blocksResponses = false
            return callbacks
        }
        callbacks.forEach { $0() }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var capturedRequest = request
        if capturedRequest.httpBody == nil, capturedRequest.httpBodyStream != nil {
            capturedRequest.httpBody = requestBody(capturedRequest)
        }
        let (stub, shouldBlock) = Self.lock.withLock {
            Self.requests.append(capturedRequest)
            let stub = Self.handler(capturedRequest, Self.requests.count)
            return (stub, Self.blocksResponses || stub.blocksResponse)
        }
        let recordedRequest = capturedRequest
        let respond: @Sendable () -> Void = { [self] in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: stub.status,
                httpVersion: nil,
                headerFields: stub.headers
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: stub.body)
            client?.urlProtocolDidFinishLoading(self)
            Self.lock.withLock { Self.responses.append(recordedRequest) }
        }
        if shouldBlock {
            Self.lock.withLock { Self.pending.append(respond) }
        } else {
            respond()
        }
    }

    override func stopLoading() {}

    private func requestBody(_ request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var body = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            body.append(buffer, count: count)
        }
        return body
    }
}

private final class LocalHTTPFixture: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "TinyCloudMusicTests.LocalHTTPFixture")
    private let response: Data
    private let lock = NSLock()
    private var startContinuation: CheckedContinuation<UInt16, Error>?
    private var capturedRequests: [String] = []

    init(response: Data) throws {
        listener = try NWListener(using: .tcp, on: .any)
        self.response = response
    }

    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            lock.withLock { startContinuation = continuation }
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    guard let port = self.listener.port?.rawValue else {
                        self.finishStart(.failure(URLError(.badServerResponse)))
                        return
                    }
                    self.finishStart(.success(port))
                case let .failed(error):
                    self.finishStart(.failure(error))
                case .cancelled:
                    self.finishStart(.failure(CancellationError()))
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.receive(on: connection, accumulated: Data())
            }
            listener.start(queue: queue)
        }
    }

    func stop() { listener.cancel() }
    func resetRequests() { lock.withLock { capturedRequests = [] } }
    var requests: [String] { lock.withLock { capturedRequests } }

    private func finishStart(_ result: Result<UInt16, Error>) {
        let continuation = lock.withLock {
            let continuation = startContinuation
            startContinuation = nil
            return continuation
        }
        continuation?.resume(with: result)
    }

    private func receive(on connection: NWConnection, accumulated: Data) {
        connection.start(queue: queue)
        receiveNext(on: connection, accumulated: accumulated)
    }

    private func receiveNext(on connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1_024) { [weak self] data, _, complete, error in
            guard let self else { return }
            var request = accumulated
            if let data { request.append(data) }
            if request.range(of: Data("\r\n\r\n".utf8)) != nil || complete {
                self.lock.withLock {
                    self.capturedRequests.append(String(decoding: request, as: UTF8.self))
                }
                connection.send(content: self.response, completion: .contentProcessed { _ in connection.cancel() })
            } else if error == nil, request.count < 64 * 1_024 {
                self.receiveNext(on: connection, accumulated: request)
            } else {
                connection.cancel()
            }
        }
    }
}

private func fixtureHTTPResponse(
    _ status: String,
    headers: [String: String] = [:],
    body: Data = Data()
) -> Data {
    let fields = headers.merging(["Content-Length": String(body.count), "Connection": "close"]) { current, _ in current }
    let head = (["HTTP/1.1 \(status)"] + fields.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" } + ["", ""])
        .joined(separator: "\r\n")
    return Data(head.utf8) + body
}

private actor AsyncGate {
    private var entered = false
    private var released = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        entered = true
        guard !released else { return }
        await withCheckedContinuation { continuations.append($0) }
    }

    func release() {
        released = true
        continuations.forEach { $0.resume() }
        continuations.removeAll()
    }

    func hasEntered() -> Bool { entered }
}

private actor CallCounter {
    private var count = 0

    func next() -> Int {
        count += 1
        return count
    }

    func value() -> Int { count }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() { lock.withLock { value += 1 } }
    var count: Int { lock.withLock { value } }
}

private extension EAPIResponseCache {
    func blockActor(entered: LockedCounter, release: DispatchSemaphore) {
        entered.increment()
        release.wait()
    }
}

private final class IssueBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: SessionCredentialIssueEvent?

    func store(_ value: SessionCredentialIssueEvent) { lock.withLock { self.value = value } }
    func load() -> SessionCredentialIssueEvent? { lock.withLock { value } }
}

private final class CredentialsBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: SessionCredentials?

    func store(_ value: SessionCredentials?) { lock.withLock { self.value = value } }
    func load() -> SessionCredentials? { lock.withLock { value } }
}

private struct PersistenceFixtureError: Error {}

private struct UserPlaylistPage: Sendable {
    let ids: [Int64]
    let more: Bool
}

private func eapiPayload(_ request: URLRequest) -> [String: Any]? {
    guard let body = request.httpBody,
          let text = String(data: body, encoding: .utf8),
          text.hasPrefix("params=")
    else { return nil }
    let hex = text.dropFirst("params=".count)
    var encrypted = Data(capacity: hex.count / 2)
    var index = hex.startIndex
    while index < hex.endIndex {
        guard let next = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex),
              let byte = UInt8(hex[index..<next], radix: 16)
        else { return nil }
        encrypted.append(byte)
        index = next
    }
    guard let envelope = try? EAPICodec.decrypt(encrypted),
          let text = String(data: envelope, encoding: .utf8)
    else { return nil }
    let parts = text.components(separatedBy: "-36cd479b6b5-")
    guard parts.count == 3,
          let data = parts[1].data(using: .utf8),
          let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return nil }
    return payload
}

private func userPlaylistResponse(_ page: UserPlaylistPage) -> String {
    let playlists = page.ids.map { #"{"id":\#($0),"name":"P\#($0)"}"# }.joined(separator: ",")
    return #"{"code":200,"more":\#(page.more),"playlist":[\#(playlists)]}"#
}

@Suite("Transport, credential snapshot, and response cache", .serialized)
@MainActor
struct TransportSessionPerformanceTests {
    private static let deviceID = String(repeating: "D", count: 52)

    @Test("Unavailable credentials fail locally and snapshot revision is the only epoch")
    func unavailableSnapshot() async throws {
        let snapshot = CredentialSnapshot()
        #expect(snapshot.load() == CredentialSnapshotValue(state: .unavailable, revision: 0))
        #expect(snapshot.store(.guest).revision == 1)
        let credentials = try fakeCredentials("account-a")
        #expect(snapshot.store(.authenticated(credentials)).revision == 2)

        let unavailable = CredentialSnapshot()
        TransportFixtureProtocol.reset { _, _ in .init(body: #"{"code":200}"#) }
        let transport = fixtureTransport(snapshot: unavailable)
        do {
            _ = try await transport.request(
                endpoint("/unavailable"),
                json: compactJSON(["id": 1]),
                cache: .search
            )
            Issue.record("An unavailable snapshot sent a guest request")
        } catch is CredentialUnavailable {
        }
        #expect(TransportFixtureProtocol.requestCount == 0)
    }

    @Test("Explicit transport overrides stay outside the session snapshot and persistence")
    func transportOverridesAreSessionIsolated() throws {
        let stored = try fakeCredentials("stored-account")
        let override = try fakeCredentials("transport-override")
        let snapshot = CredentialSnapshot(.authenticated(stored))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TransportFixtureProtocol.self]
        let transport = EAPITransport(
            session: URLSession(configuration: configuration),
            cookie: override.cookie,
            musicU: override.musicU,
            credentialSnapshot: snapshot
        )

        let resolved = try transport.credentials()
        #expect(resolved.cookie == override.cookie)
        #expect(resolved.musicU == override.musicU)

        let persisted = CredentialsBox()
        let session = SessionController(
            store: CredentialStore(service: "TinyCloudMusicTests.\(UUID())"),
            credentialSnapshot: snapshot,
            transport: transport,
            validator: { _ in true },
            vipValidator: { _ in true },
            persistCredentials: { persisted.store($0) }
        )
        #expect(session.credentials == stored)
        #expect(session.clearMusicU())
        #expect(persisted.load()?.cookie == stored.cookie)
        #expect(persisted.load()?.musicU.isEmpty == true)
    }

    @Test("Automatic response decoding does not mistake encrypted leading braces for JSON")
    func encryptedLeadingBrace() throws {
        let encrypted = try #require(Data(base64Encoded: "e7IaTRn1cdx6OAdxpNvcLV+FIKRml0a/7Oni+EqkryY="))
        #expect(try EAPICodec.responseData(encrypted) == Data(#"{"n":272,"code":200}"#.utf8))
    }

    @Test("Account invalidation cannot resend a cached read with captured old credentials")
    func accountInvalidationDoesNotResendOldRead() async throws {
        let snapshot = CredentialSnapshot(.authenticated(try fakeCredentials("account-a")))
        let revisionA = snapshot.load().revision
        TransportFixtureProtocol.reset(blocksResponses: true) { _, _ in
            .init(body: #"{"code":200}"#)
        }
        defer { TransportFixtureProtocol.releaseResponses() }
        let transport = fixtureTransport(snapshot: snapshot)
        let read = Task {
            try await transport.request(
                endpoint("/old-account-read"),
                json: compactJSON(["id": 1]),
                cache: .search
            )
        }
        #expect(await eventually { TransportFixtureProtocol.requestCount == 1 })

        _ = snapshot.store(.authenticated(try fakeCredentials("account-b")))
        await transport.invalidateAllCachedResponses()
        do {
            _ = try await read.value
            Issue.record("The invalidated A read was resent after switching to B")
        } catch let error as CredentialRevisionMismatch {
            #expect(error.expected == revisionA)
            #expect(error.actual == snapshot.load().revision)
        }
        #expect(TransportFixtureProtocol.requestCount == 1)
        let cookie = TransportFixtureProtocol.requests(path: "/old-account-read").first?
            .value(forHTTPHeaderField: "Cookie") ?? ""
        #expect(cookie.contains("MUSIC_U=account-a"))
        #expect(!cookie.contains("MUSIC_U=account-b"))
    }

    @Test("Cache internal invalidation retries once while parent cancellation stays cancellation")
    func invalidationAndCancellation() async throws {
        let cache = EAPIResponseCache()
        let key = EAPIResponseCache.Key(account: "account", request: "search", group: .search)
        let calls = CallCounter()
        let task = Task {
            try await cache.value(for: key, ttl: 60, staleIfError: 60) {
                if await calls.next() == 1 { try await Task.sleep(for: .seconds(60)) }
                return Data("B".utf8)
            }
        }
        #expect(await eventually { await calls.value() == 1 })
        await cache.invalidate(account: "account", groups: [.search])
        #expect(try await task.value == Data("B".utf8))
        #expect(await calls.value() == 2)

        let retryLimitCalls = CallCounter()
        let retryLimited = Task {
            try await cache.value(
                for: EAPIResponseCache.Key(account: "account", request: "retry-limit", group: .search),
                ttl: 60,
                staleIfError: 60
            ) {
                _ = await retryLimitCalls.next()
                try await Task.sleep(for: .seconds(60))
                return Data()
            }
        }
        #expect(await eventually { await retryLimitCalls.value() == 1 })
        await cache.invalidate(account: "account", groups: [.search])
        #expect(await eventually { await retryLimitCalls.value() == 2 })
        await cache.invalidate(account: "account", groups: [.search])
        do {
            _ = try await retryLimited.value
            Issue.record("Cache invalidation retried more than once")
        } catch {
            #expect(!(error is CancellationError))
        }
        #expect(await retryLimitCalls.value() == 2)

        let cancelCalls = CallCounter()
        let cancelled = Task {
            try await cache.value(
                for: EAPIResponseCache.Key(account: "account", request: "cancel", group: .detail),
                ttl: 60,
                staleIfError: 60
            ) {
                _ = await cancelCalls.next()
                try await Task.sleep(for: .seconds(60))
                return Data()
            }
        }
        #expect(await eventually { await cancelCalls.value() == 1 })
        cancelled.cancel()
        do {
            _ = try await cancelled.value
            Issue.record("Parent cancellation was swallowed")
        } catch is CancellationError {
        }
        #expect(await cancelCalls.value() == 1)
    }

    @Test("Group invalidation leaves another blocked group cacheable")
    func groupInvalidation() async throws {
        let cache = EAPIResponseCache()
        let key = EAPIResponseCache.Key(account: "account", request: "detail", group: .detail)
        let gate = AsyncGate()
        let loading = Task {
            try await cache.value(for: key, ttl: 60, staleIfError: 60) {
                await gate.wait()
                return Data("detail".utf8)
            }
        }
        #expect(await eventually { await gate.hasEntered() })
        await cache.invalidate(account: "account", groups: [.search])
        await gate.release()
        #expect(try await loading.value == Data("detail".utf8))
        let cached = try await cache.value(for: key, ttl: 60, staleIfError: 60) {
            Issue.record("Unrelated detail response lost cache eligibility")
            return Data("wrong".utf8)
        }
        #expect(cached == Data("detail".utf8))
    }

    @Test("Refresh supersedes regular loading, coalesces, and replaces the entry")
    func refreshCache() async throws {
        let cache = EAPIResponseCache()
        let key = EAPIResponseCache.Key(account: "account", request: "cached", group: .library)
        #expect(try await cache.value(for: key, ttl: 60, staleIfError: 60) { Data("A".utf8) } == Data("A".utf8))
        #expect(try await cache.value(
            for: key,
            ttl: 60,
            staleIfError: 60,
            refresh: true
        ) { Data("B".utf8) } == Data("B".utf8))
        #expect(try await cache.value(for: key, ttl: 60, staleIfError: 60) {
            Issue.record("The refreshed entry was not installed")
            return Data("wrong".utf8)
        } == Data("B".utf8))

        let blockedKey = EAPIResponseCache.Key(account: "account", request: "blocked", group: .library)
        let regularCalls = CallCounter()
        let regular = Task {
            try await cache.value(for: blockedKey, ttl: 60, staleIfError: 60) {
                _ = await regularCalls.next()
                try await Task.sleep(for: .seconds(60))
                return Data("A".utf8)
            }
        }
        #expect(await eventually { await regularCalls.value() == 1 })
        let forceCalls = CallCounter()
        let forceGate = AsyncGate()
        let firstForce = Task {
            try await cache.value(
                for: blockedKey,
                ttl: 60,
                staleIfError: 60,
                refresh: true
            ) {
                _ = await forceCalls.next()
                await forceGate.wait()
                return Data("B".utf8)
            }
        }
        #expect(await eventually { await forceCalls.value() == 1 })
        let secondForce = Task {
            try await cache.value(
                for: blockedKey,
                ttl: 60,
                staleIfError: 60,
                refresh: true
            ) {
                _ = await forceCalls.next()
                return Data("wrong".utf8)
            }
        }
        #expect(await eventually { await cache.waiterCount(for: blockedKey) == 3 })
        await forceGate.release()
        let results = try await (firstForce.value, secondForce.value, regular.value)
        #expect(results.0 == Data("B".utf8))
        #expect(results.1 == Data("B".utf8))
        #expect(results.2 == Data("B".utf8))
        #expect(await forceCalls.value() == 1)
    }

    @Test("Cache hit does not call HTTP or the legacy provider again")
    func cacheHitAvoidsHotPathProvider() async throws {
        let providerCalls = LockedCounter()
        let credentials = try fakeCredentials("provider")
        TransportFixtureProtocol.reset { _, _ in .init(body: #"{"code":200,"value":"cached"}"#) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TransportFixtureProtocol.self]
        let transport = EAPITransport(
            session: URLSession(configuration: configuration),
            loadStoredCredentials: {
                providerCalls.increment()
                return credentials
            }
        )
        let request = endpoint("/cache-hit")
        _ = try await transport.request(request, json: compactJSON(["id": 1]), cache: .search)
        _ = try await transport.request(request, json: compactJSON(["id": 1]), cache: .search)
        #expect(providerCalls.count == 1)
        #expect(TransportFixtureProtocol.requestCount == 1)
    }

    @Test("Read-cache and mutation side-effect options cannot be combined")
    func rejectsAmbiguousCachePolicy() async throws {
        let snapshot = CredentialSnapshot(.authenticated(try fakeCredentials("policy")))
        TransportFixtureProtocol.reset { _, _ in .init(body: #"{"code":200}"#) }
        let transport = fixtureTransport(snapshot: snapshot)

        do {
            _ = try await transport.request(
                endpoint("/ambiguous"),
                json: compactJSON(["id": 1]),
                cache: .search,
                invalidatesGroups: [.listeningHistory]
            )
            Issue.record("A cached read accepted mutation side effects")
        } catch let error as EAPIError {
            #expect(error == .invalidPayload)
        }
        do {
            _ = try await transport.requestWEAPI(
                path: "/weapi/refresh-without-cache",
                payload: [:],
                refreshCache: true
            )
            Issue.record("Refresh without a cache key was accepted")
        } catch let error as EAPIError {
            #expect(error == .invalidPayload)
        }
        #expect(TransportFixtureProtocol.requestCount == 0)
    }

    @Test("Revision-fenced reads retry transient failures while mutations send once")
    func businessRetryPolicy() async throws {
        let cache = EAPIResponseCache()
        let staleKey = EAPIResponseCache.Key(account: "account", request: "stale", group: .search)
        _ = try await cache.value(for: staleKey, ttl: 0, staleIfError: 60) { Data("A".utf8) }
        let stale = try await cache.value(for: staleKey, ttl: 0, staleIfError: 60) {
            throw EAPIError.service(code: 503, message: "temporary")
        }
        #expect(stale == Data("A".utf8))

        let snapshot = CredentialSnapshot(.authenticated(try fakeCredentials("retry")))
        let revision = snapshot.load().revision
        let transport = fixtureTransport(snapshot: snapshot)

        TransportFixtureProtocol.reset { _, index in
            .init(body: index == 1 ? #"{"code":503,"message":"temporary"}"# : #"{"code":200}"#)
        }
        _ = try await transport.request(
            endpoint("/eapi-revision-business-retry"),
            json: compactJSON(["id": 1]),
            cache: .search,
            expectedCredentialRevision: revision
        )
        #expect(TransportFixtureProtocol.requestCount == 2)

        TransportFixtureProtocol.reset { _, index in
            .init(status: index == 1 ? 503 : 200, body: #"{"code":200}"#)
        }
        _ = try await transport.request(
            endpoint("/eapi-revision-http-retry"),
            json: compactJSON(["id": 1]),
            cache: .detail,
            expectedCredentialRevision: revision
        )
        #expect(TransportFixtureProtocol.requestCount == 2)

        TransportFixtureProtocol.reset { _, index in
            .init(body: index == 1 ? #"{"code":503,"message":"temporary"}"# : #"{"code":200}"#)
        }
        _ = try await transport.requestWEAPI(
            path: "/weapi/revision-business-retry",
            payload: ["id": 1],
            cache: .searchHints,
            expectedCredentialRevision: revision,
            invalidatesAccountCache: false
        )
        #expect(TransportFixtureProtocol.requestCount == 2)

        TransportFixtureProtocol.reset { _, index in
            .init(status: index == 1 ? 503 : 200, body: #"{"code":200}"#)
        }
        _ = try await transport.requestWEAPI(
            path: "/weapi/revision-http-retry",
            payload: ["id": 1],
            cache: .library,
            expectedCredentialRevision: revision,
            invalidatesAccountCache: false
        )
        #expect(TransportFixtureProtocol.requestCount == 2)

        TransportFixtureProtocol.reset { _, _ in
            .init(body: #"{"code":503,"message":"temporary"}"#)
        }
        do {
            try await LiveMusicLibrary(transport: transport).setSongLiked(
                1,
                liked: true,
                expectedCredentialRevision: revision
            )
            Issue.record("EAPI mutation business 503 was accepted")
        } catch let error as EAPIError {
            #expect(error == .service(code: 503, message: "temporary"))
        }
        #expect(TransportFixtureProtocol.requestCount == 1)

        TransportFixtureProtocol.reset { _, _ in
            .init(body: #"{"code":503,"message":"temporary"}"#)
        }
        do {
            try await LiveVideoLibrary(transport: transport).setMVSubscribed(
                1,
                subscribed: true,
                expectedCredentialRevision: revision
            )
            Issue.record("WEAPI mutation business 503 was accepted")
        } catch let error as EAPIError {
            #expect(error == .service(code: 503, message: "temporary"))
        }
        #expect(TransportFixtureProtocol.requestCount == 1)
    }

    @Test("Listen-together retries only proven reads")
    func listenTogetherReadRetryPolicy() async throws {
        let snapshot = CredentialSnapshot(.authenticated(try fakeCredentials("listen-retry")))
        let revision = snapshot.load().revision
        let service = LiveListenTogetherService(transport: fixtureTransport(snapshot: snapshot))
        let transientFailures: [TransportFixtureProtocol.Stub] = [
            .init(status: 503, body: #"{"code":200}"#),
            .init(body: #"{"code":503,"message":"temporary"}"#)
        ]

        for failure in transientFailures {
            TransportFixtureProtocol.reset { _, index in
                index == 1 ? failure : .init(body: #"{"code":200}"#)
            }
            _ = try await service.checkRoom(
                roomID: "room-1",
                expectedCredentialRevision: revision
            )
            #expect(TransportFixtureProtocol.requestCount(
                path: "/eapi/listen/together/room/check"
            ) == 2)
        }

        for failure in transientFailures {
            TransportFixtureProtocol.reset { _, index in
                index == 1 ? failure : .init(body: #"{"code":200}"#)
            }
            _ = try await service.playlist(
                roomID: "room-1",
                displaySongIDs: [1],
                randomSongIDs: [1],
                anchorSongID: 1,
                expectedCredentialRevision: revision
            )
            #expect(TransportFixtureProtocol.requestCount(
                path: "/eapi/listen/together/sync/playlist/get"
            ) == 2)
        }

        for failure in transientFailures {
            TransportFixtureProtocol.reset { _, index in
                index == 1 ? failure : .init(body: #"{"code":200}"#)
            }
            _ = try await service.status(expectedCredentialRevision: revision)
            #expect(TransportFixtureProtocol.requestCount(
                path: "/weapi/listen/together/status/get"
            ) == 2)
        }

        TransportFixtureProtocol.reset { _, _ in
            .init(status: 503, body: #"{"code":200}"#)
        }
        do {
            _ = try await service.createRoom(expectedCredentialRevision: revision)
            Issue.record("The listen-together mutation retried a transient failure")
        } catch let error as EAPIError {
            #expect(error == .http(503))
        } catch {
            Issue.record("The listen-together mutation failed with \(error)")
        }
        #expect(TransportFixtureProtocol.requestCount(
            path: "/eapi/listen/together/room/create"
        ) == 1)
    }

    @Test("Listen-together read retry rejects a revision change before attempt two")
    func listenTogetherRetryRevisionFence() async throws {
        let snapshot = CredentialSnapshot(.authenticated(try fakeCredentials("listen-retry-a")))
        let revision = snapshot.load().revision
        let replacement = try fakeCredentials("listen-retry-b")
        let attempts = CallCounter()
        let service = LiveListenTogetherService(transport: fixtureTransport(
            snapshot: snapshot,
            beforeSendingRequest: {
                if await attempts.next() == 2 {
                    _ = snapshot.store(.authenticated(replacement))
                }
            }
        ))
        TransportFixtureProtocol.reset { _, index in
            .init(status: index == 1 ? 503 : 200, body: #"{"code":200}"#)
        }

        do {
            _ = try await service.checkRoom(
                roomID: "room-1",
                expectedCredentialRevision: revision
            )
            Issue.record("The stale read sent retry attempt two")
        } catch let error as CredentialRevisionMismatch {
            #expect(error.expected == revision)
            #expect(error.actual == snapshot.load().revision)
        } catch {
            Issue.record("The stale read failed with \(error)")
        }
        #expect(await attempts.value() == 2)
        #expect(TransportFixtureProtocol.requestCount(
            path: "/eapi/listen/together/room/check"
        ) == 1)

        let playlistSnapshot = CredentialSnapshot(.authenticated(try fakeCredentials("listen-playlist-a")))
        let playlistRevision = playlistSnapshot.load().revision
        let playlistReplacement = try fakeCredentials("listen-playlist-b")
        let playlistAttempts = CallCounter()
        let playlistService = LiveListenTogetherService(transport: fixtureTransport(
            snapshot: playlistSnapshot,
            beforeSendingRequest: {
                if await playlistAttempts.next() == 2 {
                    _ = playlistSnapshot.store(.authenticated(playlistReplacement))
                }
            }
        ))
        TransportFixtureProtocol.reset { _, index in
            .init(status: index == 1 ? 503 : 200, body: #"{"code":200}"#)
        }

        do {
            _ = try await playlistService.playlist(
                roomID: "room-1",
                displaySongIDs: [1],
                randomSongIDs: [1],
                anchorSongID: 1,
                expectedCredentialRevision: playlistRevision
            )
            Issue.record("The stale playlist read sent retry attempt two")
        } catch let error as CredentialRevisionMismatch {
            #expect(error.expected == playlistRevision)
            #expect(error.actual == playlistSnapshot.load().revision)
        } catch {
            Issue.record("The stale playlist read failed with \(error)")
        }
        #expect(await playlistAttempts.value() == 2)
        #expect(TransportFixtureProtocol.requestCount(
            path: "/eapi/listen/together/sync/playlist/get"
        ) == 1)

        let statusSnapshot = CredentialSnapshot(.authenticated(try fakeCredentials("listen-status-a")))
        let statusRevision = statusSnapshot.load().revision
        let statusReplacement = try fakeCredentials("listen-status-b")
        let statusAttempts = CallCounter()
        let statusService = LiveListenTogetherService(transport: fixtureTransport(
            snapshot: statusSnapshot,
            beforeSendingRequest: {
                if await statusAttempts.next() == 2 {
                    _ = statusSnapshot.store(.authenticated(statusReplacement))
                }
            }
        ))
        TransportFixtureProtocol.reset { _, index in
            .init(status: index == 1 ? 503 : 200, body: #"{"code":200}"#)
        }

        do {
            _ = try await statusService.status(expectedCredentialRevision: statusRevision)
            Issue.record("The stale status read sent retry attempt two")
        } catch let error as CredentialRevisionMismatch {
            #expect(error.expected == statusRevision)
            #expect(error.actual == statusSnapshot.load().revision)
        } catch {
            Issue.record("The stale status read failed with \(error)")
        }
        #expect(await statusAttempts.value() == 2)
        #expect(TransportFixtureProtocol.requestCount(
            path: "/weapi/listen/together/status/get"
        ) == 1)
    }

    @Test("Listen-together token GET sends once on HTTP and business 503")
    func listenTogetherTokenIsOneShot() async throws {
        let snapshot = CredentialSnapshot(.authenticated(try fakeCredentials("listen-token")))
        let revision = snapshot.load().revision
        let service = LiveListenTogetherService(transport: fixtureTransport(snapshot: snapshot))
        let failures: [(TransportFixtureProtocol.Stub, EAPIError)] = [
            (.init(status: 503, body: #"{"code":200}"#), .http(503)),
            (.init(body: #"{"code":503,"message":"temporary"}"#), .service(code: 503, message: "temporary"))
        ]

        for (stub, expectedError) in failures {
            TransportFixtureProtocol.reset { _, _ in stub }
            do {
                _ = try await service.realtimeCredentials(expectedCredentialRevision: revision)
                Issue.record("The token GET accepted \(expectedError)")
            } catch let error as EAPIError {
                #expect(error == expectedError)
            } catch {
                Issue.record("The token GET failed with \(error)")
            }
            let requests = TransportFixtureProtocol.requests(path: "/api/middle/im/token/get")
            #expect(requests.count == 1)
            #expect(requests.first?.httpMethod == "GET")
        }
    }

    @Test("Remaining listen-together mutations send once on business 503")
    func listenTogetherMutationsAreOneShot() async throws {
        let snapshot = CredentialSnapshot(.authenticated(try fakeCredentials("listen-mutation")))
        let revision = snapshot.load().revision
        let service = LiveListenTogetherService(transport: fixtureTransport(snapshot: snapshot))
        let playCommand = try ListenTogetherPlayCommand(
            commandType: .play,
            progress: 0,
            playStatus: .playing,
            formerSongID: 1,
            targetSongID: 1,
            clientSequence: 1
        )
        let playlistCommand = try ListenTogetherPlaylistCommand(
            commandType: .replace,
            userID: 42,
            version: 1,
            anchorSongID: 1,
            anchorPosition: 0,
            randomList: [1],
            displayList: [1]
        )
        let mutations: [(path: String, send: @Sendable () async throws -> Void)] = [
            ("/eapi/listen/together/play/invitation/accept", {
                _ = try await service.acceptInvitation(
                    roomID: "room-1",
                    inviterID: 42,
                    expectedCredentialRevision: revision
                )
            }),
            ("/eapi/listen/together/heartbeat", {
                _ = try await service.heartbeat(
                    roomID: "room-1",
                    songID: 1,
                    playStatus: .playing,
                    progress: 0,
                    expectedCredentialRevision: revision
                )
            }),
            ("/eapi/listen/together/play/command/report", {
                _ = try await service.reportPlayCommand(
                    roomID: "room-1",
                    command: playCommand,
                    expectedCredentialRevision: revision
                )
            }),
            ("/eapi/listen/together/sync/list/command/report", {
                _ = try await service.reportPlaylistCommand(
                    roomID: "room-1",
                    command: playlistCommand,
                    expectedCredentialRevision: revision
                )
            }),
            ("/eapi/listen/together/end/v2", {
                _ = try await service.endRoom(
                    roomID: "room-1",
                    expectedCredentialRevision: revision
                )
            })
        ]

        for mutation in mutations {
            TransportFixtureProtocol.reset { _, _ in
                .init(body: #"{"code":503,"message":"temporary"}"#)
            }
            do {
                try await mutation.send()
                Issue.record("\(mutation.path) accepted business 503")
            } catch let error as EAPIError {
                #expect(error == .service(code: 503, message: "temporary"))
            } catch {
                Issue.record("\(mutation.path) failed with \(error)")
            }
            #expect(TransportFixtureProtocol.requestCount(path: mutation.path) == 1)
        }
    }

    @Test("Domain business codes stay visible without failed cache side effects")
    func unsuccessfulBusinessCodesStayOutsideCacheSideEffects() async throws {
        let snapshot = CredentialSnapshot(.authenticated(try fakeCredentials("domain-codes")))
        let issueBox = IssueBox()
        let observer = NotificationCenter.default.addObserver(
            forName: .neteaseCredentialIssue,
            object: nil,
            queue: nil
        ) { notification in
            if let event = notification.object as? SessionCredentialIssueEvent { issueBox.store(event) }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        TransportFixtureProtocol.reset { request, _ in
            switch request.url?.path {
            case "/eapi/v1/user/info": .init(body: #"{"code":301,"message":"expired"}"#)
            case "/business-zero": .init(body: #"{"code":0,"data":{"accepted":true}}"#)
            case "/failed-mutation": .init(body: #"{"code":400,"message":"rejected"}"#)
            case "/cached-target": .init(body: #"{"code":200,"value":"cached"}"#)
            default: .init(body: #"{"code":600,"data":{"accepted":true}}"#)
            }
        }
        let transport = fixtureTransport(snapshot: snapshot)

        for _ in 0..<2 {
            #expect(try await LiveMusicLibrary(transport: transport).loginState() == .loggedOut)
        }
        #expect(TransportFixtureProtocol.requestCount(path: "/eapi/v1/user/info") == 2)
        #expect(issueBox.load() == SessionCredentialIssueEvent(
            issue: .cookie,
            credentialRevision: snapshot.load().revision
        ))
        for _ in 0..<2 {
            let root = try await transport.requestJSONObject(
                endpoint("/business-600"),
                json: compactJSON(["id": 1]),
                cache: .search,
                retryable: false,
                allowsDomainBusinessCodes: true
            )
            #expect(root.int("code") == 600)
        }
        for _ in 0..<2 {
            let root = try await transport.requestJSONObject(
                endpoint("/business-zero"),
                json: compactJSON(["id": 1]),
                cache: .searchHints,
                retryable: false
            )
            #expect(root.object("data").bool("accepted"))
        }

        _ = try await transport.request(
            endpoint("/cached-target"),
            json: compactJSON(["id": 1]),
            cache: .detail
        )
        do {
            _ = try await transport.request(
                endpoint("/failed-mutation"),
                json: compactJSON(["id": 1]),
                expectedCredentialRevision: snapshot.load().revision,
                invalidatesGroups: [.detail],
                retryable: false
            )
            Issue.record("An unsuccessful mutation was accepted")
        } catch let error as EAPIError {
            #expect(error == .service(code: 400, message: "rejected"))
        }
        _ = try await transport.request(
            endpoint("/cached-target"),
            json: compactJSON(["id": 1]),
            cache: .detail
        )

        #expect(TransportFixtureProtocol.requestCount(path: "/business-600") == 2)
        #expect(TransportFixtureProtocol.requestCount(path: "/business-zero") == 1)
        #expect(TransportFixtureProtocol.requestCount(path: "/cached-target") == 1)
        #expect(TransportFixtureProtocol.requestCount(path: "/failed-mutation") == 1)
    }

    @Test("WEAPI cache lookup precedes encryption and uses the same read-only retry policy")
    func weapiCacheAndRetry() async throws {
        let snapshot = CredentialSnapshot(.authenticated(try fakeCredentials("weapi")))
        TransportFixtureProtocol.reset { _, index in
            .init(body: index == 1 ? #"{"code":503}"# : #"{"code":200,"value":"B"}"#)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TransportFixtureProtocol.self]
        let transport = EAPITransport(
            session: URLSession(configuration: configuration),
            credentialSnapshot: snapshot,
            weapiSecretKey: "0123456789abcdef"
        )
        _ = try await transport.requestWEAPI(
            path: "/weapi/read",
            payload: ["id": 1],
            cache: .search,
            invalidatesAccountCache: false
        )
        _ = try await transport.requestWEAPI(
            path: "/weapi/read",
            payload: ["id": 1],
            cache: .search,
            invalidatesAccountCache: false
        )
        #expect(TransportFixtureProtocol.requestCount == 2)
    }

    @Test("Mutation checks credential revision immediately before sending")
    func mutationRevisionFence() async throws {
        let snapshot = CredentialSnapshot(.authenticated(try fakeCredentials("account-a")))
        let expected = snapshot.load().revision
        let gate = AsyncGate()
        TransportFixtureProtocol.reset { _, _ in .init(body: #"{"code":200}"#) }
        let transport = fixtureTransport(snapshot: snapshot, beforeSendingRequest: { await gate.wait() })
        let task = Task {
            try await transport.request(
                endpoint("/fenced-mutation"),
                json: compactJSON(["id": 1]),
                expectedCredentialRevision: expected
            )
        }
        #expect(await eventually { await gate.hasEntered() })
        _ = snapshot.store(.authenticated(try fakeCredentials("account-b")))
        await gate.release()
        do {
            _ = try await task.value
            Issue.record("The A mutation was sent with B credentials")
        } catch let error as CredentialRevisionMismatch {
            #expect(error.expected == expected)
            #expect(error.actual == snapshot.load().revision)
        }
        #expect(TransportFixtureProtocol.requestCount == 0)
    }

    @Test("Query keeps A credentials fenced until the actual send")
    func queryRevisionFence() async throws {
        let snapshot = CredentialSnapshot(.authenticated(try fakeCredentials("query-a")))
        let expected = snapshot.load().revision
        let gate = AsyncGate()
        TransportFixtureProtocol.reset { _, _ in .init(body: #"{"code":200}"#) }
        let transport = fixtureTransport(snapshot: snapshot, beforeSendingRequest: { await gate.wait() })
        let task = Task {
            try await transport.requestQuery(
                path: "/api/middle/im/token/get",
                fields: [("bizName", "music_listenTogether")],
                host: "https://interface3.music.163.com",
                expectedCredentialRevision: expected
            )
        }
        #expect(await eventually { await gate.hasEntered() })
        _ = snapshot.store(.authenticated(try fakeCredentials("query-b")))
        await gate.release()
        do {
            _ = try await task.value
            Issue.record("The A query was sent after switching to B")
        } catch let error as CredentialRevisionMismatch {
            #expect(error.expected == expected)
            #expect(error.actual == snapshot.load().revision)
        }
        #expect(TransportFixtureProtocol.requestCount == 0)
        #expect(TransportFixtureProtocol.requests(path: "/api/middle/im/token/get").isEmpty)
    }

    @Test("Account reads preserve their captured credential revision until send")
    func accountReadRevisionFence() async throws {
        enum Read: CaseIterable {
            case home, albumDetail, playlistDetail, userDetail
            case dailyRecommendations, following, recommendedUsers
            case artistAlbums, artistSongs, albumSubscription, artistFollowStatus, similarArtists
            case availablePlaylists, preferredStyles, createdPodcasts, uploadPodcast
            case broadcastConfirmation, mvConfirmation, videoConfirmation
            case listeningRecords, recentPlayback, rawRecentPlayback, totalListeningDuration, favoriteDetails
            case cloudSongs, cloudDetails, cloudLyrics, cloudDownload
            case podcastSubscriptions, videoSubscriptions, videoRecommendations, personalizedMVs
            case playlists, historyDates, historyDetail, todayRank, periodRank
            case realtimeReport, periodReport, yearFootprints, annualReport, firstListen
        }

        for read in Read.allCases {
            let snapshot = CredentialSnapshot(.authenticated(try fakeCredentials("read-a")))
            let expected = snapshot.load().revision
            let gate = AsyncGate()
            TransportFixtureProtocol.reset { _, _ in .init(body: #"{"code":200}"#) }
            let library = LiveMusicLibrary(
                transport: fixtureTransport(snapshot: snapshot, beforeSendingRequest: { await gate.wait() })
            )
            let extras = LiveMusicExtras(transport: library.transport)
            let audio = LiveAudioContentLibrary(transport: library.transport)
            let video = LiveVideoLibrary(transport: library.transport)
            let repository = LiveMusicRepository(transport: library.transport)
            let knowledge = LiveMusicKnowledgeLibrary(transport: library.transport)
            let date = try #require(library.decodeRecommendationHistoryDates([
                "data": ["dates": ["2026-07-30"]]
            ]).first)
            let task = Task {
                switch read {
                case .home:
                    _ = try await repository.homeSection(
                        id: "PAGE_RECOMMEND_SPECIAL_CLOUD_VILLAGE_PLAYLIST",
                        expectedCredentialRevision: expected
                    )
                case .albumDetail:
                    _ = try await repository.detail(
                        for: .album(1),
                        expectedCredentialRevision: expected
                    )
                case .playlistDetail:
                    _ = try await repository.detail(
                        for: .playlist(1),
                        expectedCredentialRevision: expected
                    )
                case .userDetail:
                    _ = try await repository.detail(
                        for: .user(1),
                        expectedCredentialRevision: expected
                    )
                case .dailyRecommendations:
                    _ = try await library.dailyRecommendations(
                        expectedCredentialRevision: expected
                    )
                case .following:
                    _ = try await library.myFollowing(
                        expectedCredentialRevision: expected
                    )
                case .recommendedUsers:
                    _ = try await extras.recommendedUsers(
                        expectedCredentialRevision: expected
                    )
                case .artistAlbums:
                    _ = try await extras.artistAlbums(
                        artistID: 1,
                        expectedCredentialRevision: expected
                    )
                case .artistSongs:
                    _ = try await extras.artistSongs(
                        artistID: 1,
                        expectedCredentialRevision: expected
                    )
                case .albumSubscription:
                    _ = try await extras.albumSubscription(
                        albumID: 1,
                        expectedCredentialRevision: expected
                    )
                case .artistFollowStatus:
                    _ = try await extras.artistFollowStatus(
                        artistID: 1,
                        expectedCredentialRevision: expected
                    )
                case .similarArtists:
                    _ = try await library.similarArtists(
                        to: 1,
                        expectedCredentialRevision: expected
                    )
                case .availablePlaylists:
                    _ = try await extras.availablePlaylists(
                        userID: 7,
                        trackID: 1,
                        expectedCredentialRevision: expected
                    )
                case .preferredStyles:
                    _ = try await knowledge.preferredStyleIDs(
                        expectedCredentialRevision: expected
                    )
                case .createdPodcasts:
                    _ = try await audio.myCreatedPodcasts(
                        expectedCredentialRevision: expected
                    )
                case .uploadPodcast:
                    _ = try await audio.uploadPodcast(
                        id: 1,
                        expectedCredentialRevision: expected
                    )
                case .broadcastConfirmation:
                    _ = try await audio.broadcastCurrentInfo(
                        channelID: "1",
                        expectedCredentialRevision: expected
                    )
                case .mvConfirmation:
                    _ = try await video.mvDetail(
                        id: 1,
                        expectedCredentialRevision: expected
                    )
                case .videoConfirmation:
                    _ = try await video.videoDetail(
                        id: "1",
                        expectedCredentialRevision: expected
                    )
                case .listeningRecords:
                    _ = try await library.listeningRecords(
                        userID: 7,
                        period: .week,
                        expectedCredentialRevision: expected
                    )
                case .recentPlayback:
                    _ = try await library.recentlyPlayedSongs(
                        expectedCredentialRevision: expected
                    )
                case .rawRecentPlayback:
                    _ = try await library.transport.requestRecentPlayback(
                        path: "/api/play-record/song/list",
                        limit: 10,
                        expectedCredentialRevision: expected
                    )
                case .totalListeningDuration:
                    _ = try await library.totalListeningDuration(
                        expectedCredentialRevision: expected
                    )
                case .favoriteDetails:
                    var favorite = Playlist(
                        id: 1,
                        name: "Favorite",
                        creator: "Owner",
                        description: "",
                        artwork: Artwork(symbol: "music.note", accent: .red)
                    )
                    favorite.specialType = 5
                    _ = try await extras.favoriteSongIDs(
                        userID: 7,
                        playlists: [favorite],
                        expectedCredentialRevision: expected
                    )
                case .cloudSongs:
                    _ = try await library.cloudSongs(
                        expectedCredentialRevision: expected
                    )
                case .cloudDetails:
                    _ = try await library.cloudSongDetails(
                        ids: [1],
                        expectedCredentialRevision: expected
                    )
                case .cloudLyrics:
                    _ = try await library.cloudLyrics(
                        userID: 7,
                        songID: 1,
                        expectedCredentialRevision: expected
                    )
                case .cloudDownload:
                    _ = try await library.cloudDownloadSource(
                        userID: 7,
                        songID: 1,
                        expectedCredentialRevision: expected
                    )
                case .podcastSubscriptions:
                    _ = try await audio.subscribedPodcasts(
                        expectedCredentialRevision: expected
                    )
                case .videoSubscriptions:
                    _ = try await video.subscriptions(
                        expectedCredentialRevision: expected
                    )
                case .videoRecommendations:
                    _ = try await video.recommendations(
                        expectedCredentialRevision: expected
                    )
                case .personalizedMVs:
                    _ = try await video.personalizedMVs(
                        expectedCredentialRevision: expected
                    )
                case .playlists:
                    _ = try await library.userPlaylists(
                        userID: 7,
                        expectedCredentialRevision: expected
                    )
                case .historyDates:
                    _ = try await library.recommendationHistoryDates(
                        expectedCredentialRevision: expected
                    )
                case .historyDetail:
                    _ = try await library.historicalDailyRecommendations(
                        on: date,
                        availableDates: [date],
                        expectedCredentialRevision: expected
                    )
                case .todayRank:
                    _ = try await library.todayListeningRank(
                        expectedCredentialRevision: expected
                    )
                case .periodRank:
                    _ = try await library.listeningSongRank(
                        period: .week,
                        expectedCredentialRevision: expected
                    )
                case .realtimeReport:
                    _ = try await library.realtimeListeningReport(
                        period: .week,
                        expectedCredentialRevision: expected
                    )
                case .periodReport:
                    _ = try await library.listeningReport(
                        period: .week,
                        expectedCredentialRevision: expected
                    )
                case .yearFootprints:
                    _ = try await library.yearListeningFootprints(
                        expectedCredentialRevision: expected
                    )
                case .annualReport:
                    _ = try await library.annualListeningReport(
                        year: 2024,
                        expectedCredentialRevision: expected
                    )
                case .firstListen:
                    _ = try await library.firstListenMemory(
                        songID: 1,
                        expectedCredentialRevision: expected
                    )
                }
            }

            #expect(await eventually { await gate.hasEntered() })
            _ = snapshot.store(.authenticated(try fakeCredentials("read-b")))
            await gate.release()
            do {
                try await task.value
                Issue.record("\(read) sent after its credential revision changed")
            } catch let error as CredentialRevisionMismatch {
                #expect(error.expected == expected)
                #expect(error.actual == snapshot.load().revision)
            }
            #expect(TransportFixtureProtocol.requestCount == 0)
        }
    }

    @Test("Matching query sends once with stable encoding and protected A headers")
    func matchingQuery() async throws {
        let snapshot = CredentialSnapshot(.authenticated(try fakeCredentials("query-a")))
        TransportFixtureProtocol.reset { _, _ in .init(body: #"{"code":200,"data":{}}"#) }
        let transport = fixtureTransport(snapshot: snapshot)
        _ = try await transport.requestQuery(
            path: "/api/middle/im/token/get",
            fields: [("bizName", "music_listenTogether"), ("label", "a b&c")],
            host: "https://interface3.music.163.com",
            expectedCredentialRevision: snapshot.load().revision
        )

        let requests = TransportFixtureProtocol.requests(path: "/api/middle/im/token/get")
        let request = try #require(requests.first)
        #expect(requests.count == 1)
        #expect(request.httpMethod == "GET")
        #expect(request.url?.absoluteString == "https://interface3.music.163.com/api/middle/im/token/get?bizName=music_listenTogether&label=a%20b%26c")
        #expect(request.value(forHTTPHeaderField: "Cookie")?.contains("MUSIC_U=query-a") == true)
        #expect(SensitiveHeaderRedirectPolicy.requiresProtection(request))
        #expect(!SensitiveHeaderRedirectPolicy.allows(
            originalURL: try #require(request.url),
            redirectedURL: URL(string: "https://music.163.com/api/middle/im/token/get")!
        ))
    }

    @Test("All playback report kinds reject a revision change before HTTP")
    func playbackReportRevisionFence() async throws {
        enum ReportKind: CaseIterable { case start, settlement, podcast }

        for kind in ReportKind.allCases {
            let snapshot = CredentialSnapshot(.authenticated(try fakeCredentials("report-a")))
            let expected = snapshot.load().revision
            let gate = AsyncGate()
            TransportFixtureProtocol.reset { _, _ in .init(body: #"{"code":200}"#) }
            let repository = LiveMusicRepository(
                transport: fixtureTransport(snapshot: snapshot, beforeSendingRequest: { await gate.wait() })
            )
            let task = Task {
                switch kind {
                case .start:
                    try await repository.recordPlaybackStart(
                        for: 1,
                        sourceID: 2,
                        totalSeconds: 120,
                        expectedCredentialRevision: expected
                    )
                case .settlement:
                    try await repository.recordPlayback(
                        for: 1,
                        sourceID: 2,
                        playedSeconds: 60,
                        totalSeconds: 120,
                        expectedCredentialRevision: expected
                    )
                case .podcast:
                    try await repository.recordPodcastPlayback(
                        for: 3,
                        positionMilliseconds: 1_000,
                        completed: false,
                        expectedCredentialRevision: expected
                    )
                }
            }
            #expect(await eventually { await gate.hasEntered() })
            _ = snapshot.store(.authenticated(try fakeCredentials("report-b")))
            await gate.release()
            do {
                try await task.value
                Issue.record("A playback report was sent after switching to B")
            } catch let error as CredentialRevisionMismatch {
                #expect(error.expected == expected)
                #expect(error.actual == snapshot.load().revision)
            }
            #expect(TransportFixtureProtocol.requestCount == 0)
        }
    }

    @Test("Credential revision fences cached responses before lookup")
    func cachedRevisionFence() async throws {
        let snapshot = CredentialSnapshot(.authenticated(try fakeCredentials("account-a")))
        let expected = snapshot.load().revision
        _ = snapshot.store(.authenticated(try fakeCredentials("account-b")))
        TransportFixtureProtocol.reset { _, _ in .init(body: #"{"code":200}"#) }
        let transport = fixtureTransport(snapshot: snapshot)
        let cached = endpoint("/cached-fence")

        _ = try await transport.request(cached, json: Data(), cache: .search)
        do {
            _ = try await transport.request(
                cached,
                json: Data(),
                cache: .search,
                expectedCredentialRevision: expected
            )
            Issue.record("The stale credential intent consumed the new account cache")
        } catch let error as CredentialRevisionMismatch {
            #expect(error.expected == expected)
            #expect(error.actual == snapshot.load().revision)
        }
        #expect(TransportFixtureProtocol.requestCount == 1)
    }

    @Test("Successful mutation invalidates only its declared cache group")
    func orderedGroupInvalidation() async throws {
        let snapshot = CredentialSnapshot(.authenticated(try fakeCredentials("groups")))
        TransportFixtureProtocol.reset { request, index in
            .init(body: #"{"code":200,"path":"\#(request.url?.path ?? "")","index":\#(index)}"#)
        }
        let responseCache = EAPIResponseCache()
        let transport = fixtureTransport(snapshot: snapshot, responseCache: responseCache)
        let search = endpoint("/cached-search")
        _ = try await transport.request(search, json: compactJSON(["id": 1]), cache: .search)
        _ = try await transport.requestRecentPlayback(
            path: "/api/play-record/song/list",
            limit: 10,
            expectedCredentialRevision: snapshot.load().revision
        )
        let actorEntered = LockedCounter()
        let releaseActor = DispatchSemaphore(value: 0)
        let actorBlocker = Task.detached {
            await responseCache.blockActor(entered: actorEntered, release: releaseActor)
        }
        defer { releaseActor.signal() }
        #expect(await eventually { actorEntered.count == 1 })
        let mutationReturned = LockedCounter()
        let mutation = Task(priority: .high) {
            let data = try await transport.request(
                endpoint("/history-mutation"),
                json: compactJSON(["id": 1]),
                expectedCredentialRevision: snapshot.load().revision,
                invalidatesGroups: [.listeningHistory],
                retryable: false
            )
            mutationReturned.increment()
            return data
        }
        #expect(await eventually {
            TransportFixtureProtocol.responseCount(path: "/history-mutation") == 1
        })
        try await Task.sleep(for: .milliseconds(25))
        #expect(mutationReturned.count == 0)
        let concurrentHistory = Task(priority: .low) {
            _ = try await transport.requestRecentPlayback(
                path: "/api/play-record/song/list",
                limit: 10,
                expectedCredentialRevision: snapshot.load().revision
            )
        }
        #expect(TransportFixtureProtocol.requestCount(path: "/weapi/play-record/song/list") == 1)

        releaseActor.signal()
        await actorBlocker.value
        _ = try await mutation.value
        try await concurrentHistory.value
        #expect(mutationReturned.count == 1)
        _ = try await transport.request(search, json: compactJSON(["id": 1]), cache: .search)
        _ = try await transport.requestRecentPlayback(
            path: "/api/play-record/song/list",
            limit: 10,
            expectedCredentialRevision: snapshot.load().revision
        )
        #expect(TransportFixtureProtocol.requestCount(path: "/cached-search") == 1)
        #expect(TransportFixtureProtocol.requestCount(path: "/weapi/play-record/song/list") == 2)
        #expect(TransportFixtureProtocol.requestCount(path: "/history-mutation") == 1)
    }

    @Test("Playback history invalidation preserves cached first-listen detail")
    func firstListenCacheIsolation() async throws {
        let snapshot = CredentialSnapshot(.authenticated(try fakeCredentials("first-listen")))
        TransportFixtureProtocol.reset { request, _ in
            if request.url?.path == "/eapi/content/activity/music/first/listen/info" {
                return .init(body: #"{"code":200,"data":{"musicFirstListenDto":{"timestamp":"1702310333313","season":"初冬","period":"深夜"}}}"#)
            }
            return .init(body: #"{"code":200}"#)
        }
        let transport = fixtureTransport(snapshot: snapshot)
        let library = LiveMusicLibrary(transport: transport)
        let revision = snapshot.load().revision

        let first = try await library.firstListenMemory(songID: 42, expectedCredentialRevision: revision)
        _ = try await transport.request(
            endpoint("/history-mutation"),
            json: compactJSON(["id": 42]),
            expectedCredentialRevision: revision,
            invalidatesGroups: [.listeningHistory],
            retryable: false
        )
        let second = try await library.firstListenMemory(songID: 42, expectedCredentialRevision: revision)

        #expect(first == second)
        #expect(TransportFixtureProtocol.requestCount(
            path: "/eapi/content/activity/music/first/listen/info"
        ) == 1)
    }

    @Test("A response after switching accounts cannot invalidate B cache")
    func sentMutationKeepsNewAccountCache() async throws {
        let snapshot = CredentialSnapshot(.authenticated(try fakeCredentials("account-a")))
        let revisionA = snapshot.load().revision
        let transport = fixtureTransport(snapshot: snapshot)
        TransportFixtureProtocol.reset { request, _ in
            .init(
                body: #"{"code":200,"path":"\#(request.url?.path ?? "")"}"#,
                blocksResponse: request.url?.path == "/account-a-mutation"
            )
        }

        let mutation = Task {
            try await transport.request(
                endpoint("/account-a-mutation"),
                json: compactJSON(["id": 1]),
                expectedCredentialRevision: revisionA,
                invalidatesGroups: [.listeningHistory],
                retryable: false
            )
        }
        #expect(await eventually {
            TransportFixtureProtocol.requestCount(path: "/account-a-mutation") == 1
        })

        _ = snapshot.store(.authenticated(try fakeCredentials("account-b")))
        let history = endpoint("/account-b-history")
        _ = try await transport.request(history, json: compactJSON(["id": 1]), cache: .listeningHistory)
        TransportFixtureProtocol.releaseResponses()
        _ = try await mutation.value
        _ = try await transport.request(history, json: compactJSON(["id": 1]), cache: .listeningHistory)
        #expect(TransportFixtureProtocol.requestCount(path: "/account-b-history") == 1)
    }

    @Test("Raw mutation invalidates only after business validation succeeds")
    func rawMutationValidation() async throws {
        let snapshot = CredentialSnapshot(.authenticated(try fakeCredentials("raw-mutation")))
        TransportFixtureProtocol.reset { request, index in
            .init(body: #"{"code":200,"path":"\#(request.url?.path ?? "")","index":\#(index)}"#)
        }
        let transport = fixtureTransport(snapshot: snapshot)
        let history = endpoint("/raw-history")
        _ = try await transport.request(history, json: compactJSON(["id": 1]), cache: .listeningHistory)

        var raw = URLRequest(url: URL(string: "https://music.163.com/raw-mutation")!)
        raw.httpMethod = "POST"
        do {
            _ = try await transport.requestRaw(
                raw,
                expectedCredentialRevision: snapshot.load().revision,
                validateResponse: { _ in throw EAPIError.service(code: 500, message: "rejected") },
                invalidatesGroups: [.listeningHistory]
            )
            Issue.record("Rejected raw mutation invalidated cache as success")
        } catch let error as EAPIError {
            #expect(error == .service(code: 500, message: "rejected"))
        }
        _ = try await transport.request(history, json: compactJSON(["id": 1]), cache: .listeningHistory)
        #expect(TransportFixtureProtocol.requestCount(path: "/raw-history") == 1)

        _ = try await transport.requestRaw(
            raw,
            expectedCredentialRevision: snapshot.load().revision,
            invalidatesGroups: [.listeningHistory]
        )
        _ = try await transport.request(history, json: compactJSON(["id": 1]), cache: .listeningHistory)
        #expect(TransportFixtureProtocol.requestCount(path: "/raw-history") == 2)
    }

    @Test("Playlist detail reuses embedded songs and fetches only missing IDs")
    func playlistEmbeddedSongs() async throws {
        let snapshot = CredentialSnapshot(.authenticated(try fakeCredentials("playlist")))
        TransportFixtureProtocol.reset { request, _ in
            if request.url?.path == "/eapi/v6/playlist/detail" {
                return .init(body: #"""
                {
                    "code":200,
                    "playlist":{
                        "id":9,"name":"List","trackCount":2,
                        "creator":{"userId":1,"nickname":"Owner"},
                        "trackIds":[{"id":1},{"id":2}],
                        "tracks":[{"id":1,"name":"Embedded","ar":[],"al":{"id":10,"name":"Album"},"dt":1000}]
                    }
                }
                """#)
            }
            return .init(body: #"""
            {
                "code":200,
                "songs":[{"id":2,"name":"Missing","ar":[],"al":{"id":10,"name":"Album"},"dt":1000}]
            }
            """#)
        }
        let repository = LiveMusicRepository(transport: fixtureTransport(snapshot: snapshot))
        let detail = try await repository.detail(for: .playlist(9))
        guard case let .playlist(_, songs, trackIDs, loadedTrackCount) = detail else {
            Issue.record("Playlist detail decoded as another route")
            return
        }
        #expect(songs.map(\.id) == [1, 2])
        #expect(trackIDs == [1, 2])
        #expect(loadedTrackCount == 2)
        #expect(TransportFixtureProtocol.requestCount(path: "/eapi/v3/song/detail") == 1)
    }

    @Test("User playlists page by 100 without changing order or total")
    func userPlaylistPagination() async throws {
        try await verifyUserPlaylists(
            pages: [0: UserPlaylistPage(ids: [], more: false)],
            expectedIDs: [],
            expectedOffsets: [0]
        )
        try await verifyUserPlaylists(
            pages: [0: UserPlaylistPage(ids: [11, 12], more: false)],
            expectedIDs: [11, 12],
            expectedOffsets: [0]
        )
        try await verifyUserPlaylists(
            pages: [
                0: UserPlaylistPage(ids: [21, 22], more: true),
                2: UserPlaylistPage(ids: [23], more: true),
                3: UserPlaylistPage(ids: [24, 25], more: false)
            ],
            expectedIDs: [21, 22, 23, 24, 25],
            expectedOffsets: [0, 2, 3]
        )
    }

    @Test("Empty, duplicate, and undecodable pages terminate without progress")
    func userPlaylistNoProgress() async throws {
        try await verifyUserPlaylists(
            pages: [
                0: UserPlaylistPage(ids: [31], more: true),
                1: UserPlaylistPage(ids: [], more: true)
            ],
            expectedIDs: [31],
            expectedOffsets: [0, 1]
        )
        try await verifyUserPlaylists(
            pages: [
                0: UserPlaylistPage(ids: [41, 42], more: true),
                2: UserPlaylistPage(ids: [41, 42], more: true)
            ],
            expectedIDs: [41, 42],
            expectedOffsets: [0, 2]
        )
        try await verifyUserPlaylists(
            pages: [
                0: UserPlaylistPage(ids: [51], more: true),
                1: UserPlaylistPage(ids: [0], more: true)
            ],
            expectedIDs: [51],
            expectedOffsets: [0, 1]
        )
    }

    @Test("Credential issue retains A revision after snapshot changes to B")
    func credentialIssueRevision() async throws {
        let service = "TinyCloudMusicTests.\(UUID())"
        let store = CredentialStore(service: service)
        defer { try? store.delete() }
        let accountA = try fakeCredentials("account-a")
        try store.save(accountA)
        let snapshot = CredentialSnapshot(.authenticated(accountA))
        let revisionA = snapshot.load().revision
        let issueBox = IssueBox()
        let observer = NotificationCenter.default.addObserver(
            forName: .neteaseCredentialIssue,
            object: nil,
            queue: nil
        ) { notification in
            if let event = notification.object as? SessionCredentialIssueEvent { issueBox.store(event) }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        TransportFixtureProtocol.reset(blocksResponses: true) { _, _ in
            .init(body: #"{"code":301,"message":"expired"}"#)
        }
        let transport = fixtureTransport(snapshot: snapshot)
        let request = Task {
            try await transport.request(
                endpoint("/delayed-issue"),
                json: compactJSON(["id": 1]),
                retryable: false
            )
        }
        #expect(await eventually { TransportFixtureProtocol.requestCount == 1 })
        let accountB = try fakeCredentials("account-b")
        try store.save(accountB)
        _ = snapshot.store(.authenticated(accountB))
        let session = SessionController(
            store: store,
            credentialSnapshot: snapshot,
            transport: transport,
            validator: { _ in true },
            vipValidator: { _ in true }
        )
        TransportFixtureProtocol.releaseResponses()
        do {
            _ = try await request.value
            Issue.record("An expired credential response was accepted")
        } catch let error as EAPIError {
            #expect(error == .service(code: 301, message: "expired"))
        }
        let event = try #require(issueBox.load())
        #expect(event.credentialRevision == revisionA)
        #expect(!session.invalidate(event))
        #expect(snapshot.load().state == .authenticated(accountB))
    }

    @Test("Persistence failure preserves the last-good snapshot and shared revision")
    func persistenceFailureKeepsLastGoodSnapshot() async throws {
        let store = CredentialStore(service: "TinyCloudMusicTests.\(UUID())")
        defer { try? store.delete() }
        let accountA = try fakeCredentials("persisted-a")
        try store.save(accountA)
        let snapshot = CredentialSnapshot(.authenticated(accountA))
        let initial = snapshot.load()
        let transport = fixtureTransport(snapshot: snapshot)
        let session = SessionController(
            store: store,
            credentialSnapshot: snapshot,
            transport: transport,
            validator: { _ in true },
            vipValidator: { _ in true },
            persistCredentials: { _ in throw PersistenceFixtureError() }
        )

        #expect(!(await session.save(cookie: "MUSIC_U=account-b")))
        #expect(snapshot.load() == initial)
        #expect(session.credentials == accountA)
        #expect(session.state == .authenticated)
        #expect(session.credentialRevision == transport.credentialSnapshotValue().revision)
        #expect(try store.load() == accountA)
    }

    @Test("An in-flight old QR 803 cannot commit after a newer login")
    func inFlightQRSuccessCannotOverwriteNewLogin() async throws {
        let store = CredentialStore(service: "TinyCloudMusicTests.\(UUID())")
        defer { try? store.delete() }
        let accountA = try fakeCredentials("qr-a")
        try store.save(accountA)
        let snapshot = CredentialSnapshot(.authenticated(accountA))
        let transport = fixtureTransport(snapshot: snapshot)
        let session = SessionController(
            store: store,
            credentialSnapshot: snapshot,
            transport: transport,
            validator: { _ in true },
            vipValidator: { _ in true }
        )
        TransportFixtureProtocol.reset { _, _ in
            .init(body: #"{"code":200,"unikey":"old-key"}"#)
        }
        let key = try await session.requestQRLoginKey()

        TransportFixtureProtocol.reset(blocksResponses: true) { _, _ in
            .init(
                headers: ["Set-Cookie": "MUSIC_U=old-qr; Domain=.163.com; Path=/; Secure"],
                body: #"{"code":803}"#
            )
        }
        let oldPoll = Task { try await session.checkQRLogin(key: key) }
        #expect(await eventually {
            TransportFixtureProtocol.requestCount(path: "/eapi/login/qrcode/client/login") == 1
        })
        #expect(await session.save(cookie: "MUSIC_U=new-login"))
        let newLogin = snapshot.load()
        TransportFixtureProtocol.releaseResponses()
        do {
            _ = try await oldPoll.value
            Issue.record("The old in-flight QR response committed after the newer login")
        } catch let error as SessionOperationError {
            #expect(error == .superseded)
        }

        #expect(snapshot.load() == newLogin)
        #expect(session.credentials?.cookie.contains("MUSIC_U=new-login") == true)
        #expect(session.credentials?.cookie.contains("old-qr") == false)
        #expect(try store.load() == session.credentials)
    }

    @Test("An in-flight guest registration cannot overwrite a newer login")
    func guestLoginInterleaving() async throws {
        let store = CredentialStore(service: "TinyCloudMusicTests.\(UUID())")
        defer { try? store.delete() }
        let snapshot = CredentialSnapshot(.guest)
        let guestGate = AsyncGate()
        let transport = fixtureTransport(snapshot: snapshot)
        let deviceID = Self.deviceID
        let session = SessionController(
            store: store,
            credentialSnapshot: snapshot,
            transport: transport,
            validator: { _ in true },
            vipValidator: { _ in true },
            guestRegistrar: {
                await guestGate.wait()
                return NeteaseAuthenticationContext(
                    cookie: "MUSIC_A=stale-guest",
                    deviceID: deviceID
                )
            }
        )

        let restore = Task { await session.restore() }
        #expect(await eventually { await guestGate.hasEntered() })
        #expect(await session.save(cookie: "MUSIC_U=new-login"))
        let newLogin = snapshot.load()
        await guestGate.release()
        await restore.value

        #expect(snapshot.load() == newLogin)
        #expect(newLogin.revision == 1)
        #expect(session.state == .authenticated)
        #expect(session.credentials?.cookie.contains("MUSIC_U=new-login") == true)
        #expect(session.credentials?.cookie.contains("stale-guest") == false)
        #expect(try store.load() == session.credentials)
    }

    @Test("Delayed logout and refresh cannot overwrite a newer login")
    func sessionOperationGeneration() async throws {
        let store = CredentialStore(service: "TinyCloudMusicTests.\(UUID())")
        defer { try? store.delete() }
        let accountA = try fakeCredentials("account-a")
        try store.save(accountA)
        let snapshot = CredentialSnapshot(.authenticated(accountA))
        TransportFixtureProtocol.reset(blocksResponses: true) { request, _ in
            request.url?.path == "/eapi/login/token/refresh"
                ? .init(
                    headers: ["Set-Cookie": "MUSIC_U=refreshed-a; Domain=.163.com; Path=/; Secure"],
                    body: #"{"code":200}"#
                )
                : .init(body: #"{"code":200}"#)
        }
        let transport = fixtureTransport(snapshot: snapshot)
        let session = SessionController(
            store: store,
            credentialSnapshot: snapshot,
            transport: transport,
            validator: { _ in true },
            vipValidator: { _ in true }
        )

        let refresh = Task { try await session.refresh() }
        #expect(await eventually {
            TransportFixtureProtocol.requestCount(path: "/eapi/login/token/refresh") == 1
        })
        let logout = Task { await session.logout() }
        #expect(await eventually { TransportFixtureProtocol.requestCount(path: "/eapi/logout") == 1 })
        #expect(await session.save(cookie: "MUSIC_U=account-b"))
        TransportFixtureProtocol.releaseResponses()
        do {
            _ = try await refresh.value
            Issue.record("The superseded refresh completed")
        } catch let error as SessionOperationError {
            #expect(error == .superseded)
        }
        _ = await logout.value
        let final = try #require(session.credentials)
        #expect(final.cookie.contains("MUSIC_U=account-b"))
        #expect(session.state == .authenticated)
        #expect(session.credentialRevision == snapshot.load().revision)
    }

    @Test("Logout commits local guest state before waiting for owner cleanup")
    func logoutCommitsBeforeOwnerCleanup() async throws {
        let store = CredentialStore(service: "TinyCloudMusicTests.\(UUID())")
        defer { try? store.delete() }
        let account = try fakeCredentials("logout-order")
        try store.save(account)
        let snapshot = CredentialSnapshot(.authenticated(account))
        let cleanupGate = AsyncGate()
        let deviceID = Self.deviceID
        TransportFixtureProtocol.reset { _, _ in .init(body: #"{"code":200}"#) }
        let session = SessionController(
            store: store,
            credentialSnapshot: snapshot,
            transport: fixtureTransport(snapshot: snapshot),
            validator: { _ in true },
            vipValidator: { _ in true },
            guestRegistrar: {
                NeteaseAuthenticationContext(cookie: "MUSIC_A=guest", deviceID: deviceID)
            }
        )
        session.beforeLogout = { await cleanupGate.wait() }

        let logout = Task { await session.logout() }
        #expect(await eventually { await cleanupGate.hasEntered() })

        #expect(session.state == .guest)
        #expect(session.credentials?.cookie.isEmpty == true)
        #expect(session.credentials?.musicU == account.musicU)
        #expect(snapshot.load().revision == 1)
        #expect(try store.load() == session.credentials)
        #expect(TransportFixtureProtocol.requestCount(path: "/eapi/logout") == 0)

        await cleanupGate.release()
        _ = await logout.value
        #expect(TransportFixtureProtocol.requestCount(path: "/eapi/logout") == 1)
    }

    @Test("Restore device migration advances the shared snapshot timeline only")
    func restoreDeviceMigration() async throws {
        let store = CredentialStore(service: "TinyCloudMusicTests.\(UUID())")
        defer { try? store.delete() }
        let stored = try SessionCredentials(cookie: "MUSIC_U=account", musicU: "vip-account")
        try store.save(stored)
        let snapshot = CredentialSnapshot(.authenticated(stored))
        let transport = fixtureTransport(snapshot: snapshot)
        let session = SessionController(
            store: store,
            credentialSnapshot: snapshot,
            transport: transport,
            validator: { _ in true },
            vipValidator: { _ in true }
        )

        await session.restore()
        let migrated = try #require(session.credentials)
        #expect(!migrated.deviceID.isEmpty)
        #expect(try store.load() == migrated)
        #expect(session.credentialRevision == snapshot.load().revision)
        #expect(transport.credentialSnapshotValue().revision == session.credentialRevision)
    }

    @Test("Concurrent authentication requests keep response cookies isolated")
    func authenticationCookieIsolation() async throws {
        let snapshot = CredentialSnapshot(.authenticated(try fakeCredentials("auth")))
        TransportFixtureProtocol.reset { _, index in
            .init(
                headers: ["Set-Cookie": "FLOW_\(index)=value; Domain=.163.com; Path=/; Secure"],
                body: #"{"code":200}"#
            )
        }
        let transport = fixtureTransport(snapshot: snapshot)
        let endpoint = endpoint("/auth-flow")
        async let first = transport.requestAuthentication(
            endpoint,
            payload: ["flow": 1],
            context: NeteaseAuthenticationContext(cookie: "", deviceID: Self.deviceID)
        )
        async let second = transport.requestAuthentication(
            endpoint,
            payload: ["flow": 2],
            context: NeteaseAuthenticationContext(cookie: "", deviceID: Self.deviceID)
        )
        let responses = try await [first, second]
        let names = responses.map { Set($0.cookies.map(\.name).filter { $0.hasPrefix("FLOW_") }) }
        #expect(names.allSatisfy { $0.count == 1 })
        #expect(names[0] != names[1])
    }

    @Test("Sensitive redirects remain same-origin HTTPS only")
    func redirectPolicy() {
        let original = URL(string: "https://music.163.com/eapi/test")!
        #expect(SensitiveHeaderRedirectPolicy.allows(
            originalURL: original,
            redirectedURL: URL(string: "https://music.163.com/eapi/next")!
        ))
        #expect(!SensitiveHeaderRedirectPolicy.allows(
            originalURL: original,
            redirectedURL: URL(string: "https://interface.music.163.com/eapi/next")!
        ))
        #expect(!SensitiveHeaderRedirectPolicy.allows(
            originalURL: original,
            redirectedURL: URL(string: "http://music.163.com/eapi/next")!
        ))
        #expect(!SensitiveHeaderRedirectPolicy.allows(
            originalURL: URL(string: "http://music.163.com/eapi/test")!,
            redirectedURL: URL(string: "https://music.163.com/eapi/next")!
        ))
        #expect(!SensitiveHeaderRedirectPolicy.allows(
            originalURL: URL(string: "https://music.163.com:8443/eapi/test")!,
            redirectedURL: URL(string: "https://music.163.com/eapi/next")!
        ))

        var upload = URLRequest(url: original)
        upload.setValue("fixture-token", forHTTPHeaderField: "x-nos-token")
        #expect(SensitiveHeaderRedirectPolicy.requiresProtection(upload))
    }

    @Test("URLSession control follows redirect but sensitive headers never cross origin")
    func sensitiveRedirectIntegration() async throws {
        let snapshot = CredentialSnapshot(.authenticated(try fakeCredentials("redirect")))
        let target = try LocalHTTPFixture(
            response: fixtureHTTPResponse(
                "200 OK",
                headers: ["Content-Type": "application/json"],
                body: Data(#"{"code":200}"#.utf8)
            )
        )
        let targetPort = try await target.start()
        defer { target.stop() }
        let destination = "http://127.0.0.1:\(targetPort)/cross-origin"
        let origin = try LocalHTTPFixture(
            response: fixtureHTTPResponse("302 Found", headers: ["Location": destination])
        )
        let originPort = try await origin.start()
        defer { origin.stop() }
        let originURL = URL(string: "http://127.0.0.1:\(originPort)/redirect")!

        let controlSession = URLSession(configuration: .ephemeral)
        _ = try await controlSession.data(from: originURL)
        #expect(origin.requests.count == 1)
        #expect(target.requests.count == 1)
        origin.resetRequests()
        target.resetRequests()

        let transport = EAPITransport(
            session: URLSession(configuration: .ephemeral),
            credentialSnapshot: snapshot
        )
        do {
            _ = try await transport.request(
                EAPIEndpoint(
                    "/redirect",
                    host: "http://127.0.0.1:\(originPort)",
                    responseEncoding: .json
                ),
                json: compactJSON(["id": 2]),
                retryable: false
            )
        } catch {
            // Cancelling a redirect may surface either the original 302 or a Foundation URL error.
        }
        #expect(origin.requests.count == 1)
        #expect(origin.requests[0].contains("MUSIC_U=redirect"))
        #expect(target.requests.isEmpty)

        origin.resetRequests()
        var sensitive = URLRequest(url: originURL)
        sensitive.setValue("fixture-cookie", forHTTPHeaderField: "Cookie")
        sensitive.setValue("fixture-music-u", forHTTPHeaderField: "MUSIC_U")
        sensitive.setValue("Bearer fixture", forHTTPHeaderField: "Authorization")
        sensitive.setValue("fixture-nos-token", forHTTPHeaderField: "x-nos-token")
        do {
            _ = try await transport.requestRaw(sensitive)
        } catch {
        }
        #expect(origin.requests.count == 1)
        #expect(origin.requests[0].contains("fixture-cookie"))
        #expect(origin.requests[0].contains("fixture-music-u"))
        #expect(origin.requests[0].contains("Bearer fixture"))
        #expect(origin.requests[0].contains("fixture-nos-token"))
        #expect(target.requests.isEmpty)
    }

    private func fixtureTransport(
        snapshot: CredentialSnapshot,
        responseCache: EAPIResponseCache = EAPIResponseCache(),
        beforeSendingRequest: (@Sendable () async -> Void)? = nil
    ) -> EAPITransport {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TransportFixtureProtocol.self]
        return EAPITransport(
            session: URLSession(configuration: configuration),
            credentialSnapshot: snapshot,
            responseCache: responseCache,
            beforeSendingRequest: beforeSendingRequest
        )
    }

    private func verifyUserPlaylists(
        pages: [Int: UserPlaylistPage],
        expectedIDs: [Int64],
        expectedOffsets: [Int]
    ) async throws {
        let snapshot = CredentialSnapshot(.authenticated(try fakeCredentials("user-playlists")))
        TransportFixtureProtocol.reset { request, _ in
            if request.url?.path == "/eapi/v1/user/detail" {
                return .init(body: #"{"code":200,"profile":{"userId":7,"nickname":"User"}}"#)
            }
            let offset = eapiPayload(request)?["offset"] as? NSNumber
            return .init(body: userPlaylistResponse(pages[offset?.intValue ?? -1] ?? .init(ids: [], more: false)))
        }
        let repository = LiveMusicRepository(transport: fixtureTransport(snapshot: snapshot))
        let detail = try await repository.detail(for: .user(7))
        guard case let .user(_, playlists, _) = detail else {
            Issue.record("User detail decoded as another route")
            return
        }

        let requests = TransportFixtureProtocol.requests(path: "/eapi/user/playlist")
        let payloads = requests.compactMap(eapiPayload)
        let offsets = payloads.compactMap { ($0["offset"] as? NSNumber)?.intValue }
        let limits = payloads.compactMap { ($0["limit"] as? NSNumber)?.intValue }
        #expect(playlists.map(\.id) == expectedIDs)
        #expect(requests.count == expectedOffsets.count)
        #expect(payloads.count == requests.count)
        #expect(offsets == expectedOffsets)
        #expect(limits.allSatisfy { (1...100).contains($0) })
        #expect(zip(offsets, offsets.dropFirst()).allSatisfy(<))
    }

    private func endpoint(_ path: String) -> EAPIEndpoint {
        EAPIEndpoint(path, host: "https://music.163.com", responseEncoding: .json)
    }

    private func fakeCredentials(_ token: String) throws -> SessionCredentials {
        try SessionCredentials(
            cookie: "MUSIC_U=\(token); __csrf=test",
            musicU: "vip-\(token)",
            deviceID: Self.deviceID
        )
    }

    private func eventually(_ condition: () async -> Bool) async -> Bool {
        for _ in 0..<200 {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return false
    }
}
