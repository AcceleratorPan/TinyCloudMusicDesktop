import Foundation
import Testing
@testable import TinyCloudMusic

private final class SearchAssistanceProtocol: URLProtocol, @unchecked Sendable {
    enum Mode { case success, failAssistance }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var mode: Mode = .success
    nonisolated(unsafe) private static var paths: [String] = []

    static func reset(mode: Mode = .success) {
        lock.withLock {
            self.mode = mode
            paths = []
        }
    }

    static func requestCount(containing value: String) -> Int {
        lock.withLock { paths.count(where: { $0.contains(value) }) }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let path = request.url?.path ?? ""
        let mode = Self.lock.withLock {
            Self.paths.append(path)
            return Self.mode
        }
        let failed = mode == .failAssistance && path.contains("/search/suggest/")
        let status = failed ? 400 : 200
        let body: String
        switch path {
        case "/eapi/hotsearchlist/get":
            body = #"{"code":200,"data":[{"searchWord":"Hot","content":"Rising","score":99}]}"#
        case "/eapi/search/default/keyword/list":
            body = #"{"code":200,"data":{"keywords":[{"showKeyword":"Hot","realkeyword":"Hot"}]}}"#
        case "/eapi/search/suggest/keyword/get":
            body = failed ? #"{"code":400}"# : #"{"code":200,"data":{"suggests":[{"keyword":"Latest"}]}}"#
        case "/eapi/search/suggest/multimatch":
            body = failed
                ? #"{"code":400}"#
                : #"{"code":200,"result":{"orders":["artist"],"artist":[{"id":2,"name":"Latest Artist"}]}}"#
        default:
            body = #"{"code":404}"#
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite("Search assistance", .serialized)
@MainActor
struct SearchAssistanceTests {
    @Test("Single characters skip multimatch and rapid input accepts only the latest query")
    func debounceAndLatestQuery() async throws {
        let model = makeModel()
        SearchAssistanceProtocol.reset()

        model.updateSearchQuery("周")
        try await Task.sleep(for: .milliseconds(400))
        #expect(SearchAssistanceProtocol.requestCount(containing: "multimatch") == 0)

        SearchAssistanceProtocol.reset()
        model.updateSearchQuery("周杰")
        try await Task.sleep(for: .milliseconds(100))
        model.updateSearchQuery("周杰伦")
        try await Task.sleep(for: .milliseconds(500))

        #expect(SearchAssistanceProtocol.requestCount(containing: "multimatch") == 1)
        #expect(model.searchDirectMatches.first?.item.title == "Latest Artist")
    }

    @Test("Auxiliary failures do not replace ordinary search state")
    func failureIsolation() async throws {
        let model = makeModel()
        SearchAssistanceProtocol.reset(mode: .failAssistance)

        model.updateSearchQuery("missing")
        model.search(offset: 0)
        try await Task.sleep(for: .milliseconds(650))

        guard case let .loaded(page) = model.searchLoad else {
            Issue.record("Ordinary search was replaced by an auxiliary failure")
            return
        }
        #expect(page.offset == 0)
        #expect(model.searchDirectMatches.isEmpty)
    }

    @Test("Hot words load and submit an offset-zero search")
    func hotWordSelection() async throws {
        let model = makeModel()
        SearchAssistanceProtocol.reset()

        model.loadSearchHints()
        try await Task.sleep(for: .milliseconds(100))
        let item = try #require(model.hotSearchItems.first)
        model.selectSearchHint(item.keyword)

        #expect(model.searchState.query == "Hot")
        #expect(model.searchState.offset == 0)
        try await Task.sleep(for: .milliseconds(350))
        guard case let .loaded(page) = model.searchLoad else {
            Issue.record("Hot-word selection did not submit a search")
            return
        }
        #expect(page.offset == 0)
    }

    private func makeModel() -> AppModel {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SearchAssistanceProtocol.self]
        let transport = EAPITransport(
            session: URLSession(configuration: configuration),
            cookie: "",
            musicU: ""
        )
        return AppModel(
            repository: FixtureMusicRepository(),
            extras: LiveMusicExtras(transport: transport),
            defaults: UserDefaults(suiteName: UUID().uuidString)!
        )
    }
}
