import Foundation

private final class FailureProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var calls = 0

    static func reset() {
        lock.lock()
        calls = 0
        lock.unlock()
    }

    static func callCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.calls += 1
        Self.lock.unlock()
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 500,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"code":500}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private actor LoadCounter {
    private var value = 0

    func increment() -> Int {
        value += 1
        return value
    }

    func count() -> Int { value }
}

@main
private enum CacheCheck {
    static func main() async throws {
        let cache = EAPIResponseCache()
        let counter = LoadCounter()
        let accountA = EAPIResponseCache.Key(account: "account-a", request: "request")
        let accountB = EAPIResponseCache.Key(account: "account-b", request: "request")

        async let first = cache.value(for: accountA, ttl: 60, staleIfError: 60) {
            let count = await counter.increment()
            try await Task.sleep(for: .milliseconds(25))
            return Data("{\"code\":200,\"value\":\(count)}".utf8)
        }
        async let second = cache.value(for: accountA, ttl: 60, staleIfError: 60) {
            let count = await counter.increment()
            return Data("{\"code\":200,\"value\":\(count)}".utf8)
        }
        let (firstValue, secondValue) = try await (first, second)
        precondition(firstValue == secondValue, "Concurrent reads were not coalesced")
        let coalescedCount = await counter.count()
        precondition(coalescedCount == 1, "Concurrent reads invoked more than one loader")

        _ = try await cache.value(for: accountB, ttl: 60, staleIfError: 60) {
            let count = await counter.increment()
            return Data("{\"code\":200,\"value\":\(count)}".utf8)
        }
        let isolatedCount = await counter.count()
        precondition(isolatedCount == 2, "Account cache identities were not isolated")

        let staleKey = EAPIResponseCache.Key(account: "account-a", request: "stale")
        let original = Data(#"{"code":200,"value":"cached"}"#.utf8)
        _ = try await cache.value(for: staleKey, ttl: 0, staleIfError: 60) { original }
        let fallback = try await cache.value(for: staleKey, ttl: 0, staleIfError: 60) {
            throw URLError(.timedOut)
        }
        precondition(fallback == original, "Transient failure did not use valid stale data")

        do {
            _ = try await cache.value(for: staleKey, ttl: 0, staleIfError: 60) {
                throw EAPIError.http(404)
            }
            preconditionFailure("Permanent HTTP failure incorrectly used stale data")
        } catch EAPIError.http(404) {
        }

        await cache.invalidate(account: "account-a")
        _ = try await cache.value(for: accountA, ttl: 60, staleIfError: 60) {
            let count = await counter.increment()
            return Data("{\"code\":200,\"value\":\(count)}".utf8)
        }
        let invalidatedCount = await counter.count()
        precondition(invalidatedCount == 3, "Account invalidation did not force a reload")

        let cancellationCounter = LoadCounter()
        let cancellationKey = EAPIResponseCache.Key(account: "account-a", request: "cancellation")
        let survivor = Task {
            try await cache.value(for: cancellationKey, ttl: 60, staleIfError: 0) {
                _ = await cancellationCounter.increment()
                try await Task.sleep(for: .milliseconds(300))
                return Data(#"{"code":200,"value":"survivor"}"#.utf8)
            }
        }
        try await Task.sleep(for: .milliseconds(20))
        let cancelled = Task {
            try await cache.value(for: cancellationKey, ttl: 60, staleIfError: 0) {
                preconditionFailure("A coalesced waiter started a second loader")
            }
        }
        try await Task.sleep(for: .milliseconds(20))
        let cancelledAt = ContinuousClock.now
        cancelled.cancel()
        do {
            _ = try await cancelled.value
            preconditionFailure("A cancelled waiter returned data")
        } catch is CancellationError {
            precondition(
                cancelledAt.duration(to: .now) < .milliseconds(100),
                "A cancelled waiter remained blocked on the shared request"
            )
        }
        let survivorValue = try await survivor.value
        precondition(
            survivorValue == Data(#"{"code":200,"value":"survivor"}"#.utf8),
            "Cancelling one waiter cancelled the shared request"
        )
        let cancellationCount = await cancellationCounter.count()
        precondition(cancellationCount == 1, "Cancellation broke request coalescing")

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FailureProtocol.self]
        let transport = EAPITransport(
            session: URLSession(configuration: configuration),
            cookie: "test=1",
            musicU: ""
        )
        FailureProtocol.reset()
        do {
            _ = try await transport.request(
                EAPIEndpoint("/eapi/write", signing: "/api/write"),
                json: Data(#"{"id":1}"#.utf8),
                invalidatesAccountCache: true
            )
            preconditionFailure("The local HTTP 500 response must fail")
        } catch EAPIError.http(500) {
        }
        precondition(FailureProtocol.callCount() == 1, "A mutating request was retried")
        print("Cache checks passed")
    }
}
