import Foundation
import Testing
@testable import TinyCloudMusic

private final class AuthenticationProtocol: URLProtocol, @unchecked Sendable {
    struct Stub: Sendable {
        let status: Int
        let headers: [String: String]
        let body: Data
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var stubs: [String: Stub] = [:]
    nonisolated(unsafe) private static var paths: [String] = []

    static func reset(_ stubs: [String: Stub]) {
        lock.withLock {
            self.stubs = stubs
            paths = []
        }
    }

    static func requestCount(for path: String) -> Int {
        lock.withLock { paths.count(where: { $0 == path }) }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let path = request.url?.path ?? ""
        let stub = Self.lock.withLock {
            Self.paths.append(path)
            return Self.stubs[path]
        } ?? Stub(status: 404, headers: [:], body: Data(#"{"code":404}"#.utf8))
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

    override func stopLoading() {}
}

@Suite("Native QR login lifecycle", .serialized)
@MainActor
struct QRLoginLifecycleTests {
    private static let deviceID = String(repeating: "A", count: 52)

    @Test("QR URL is strictly encoded and Core Image produces pixels")
    func qrImage() throws {
        let url = try NativeQRCode.loginURL(
            key: "a+b=c/& ?中文",
            chainID: "v1_unknown-1_web_login_2"
        )
        #expect(
            url.absoluteString
                == "https://music.163.com/login?codekey=a%2Bb%3Dc%2F%26%20%3F%E4%B8%AD%E6%96%87&chainId=v1_unknown-1_web_login_2"
        )
        let image = try NativeQRCode.image(key: "test-key", chainID: "v1_unknown-1_web_login_2")
        #expect(image.size == NSSize(width: 300, height: 300))
        #expect(image.tiffRepresentation?.isEmpty == false)
    }

    @Test("QR business states map exactly")
    func statusMapping() {
        #expect(QRLoginStatus(code: 800) == .expired)
        #expect(QRLoginStatus(code: 801) == .waitingScan)
        #expect(QRLoginStatus(code: 802) == .waitingConfirmation)
        #expect(QRLoginStatus(code: 803) == .succeeded)
        #expect(QRLoginStatus(code: 200) == nil)
    }

    @Test("Refresh merges returned cookies and preserves the independent MUSIC_U")
    func refreshMerge() async throws {
        let store = CredentialStore(service: "TinyCloudMusicTests.\(UUID())")
        defer { try? store.delete() }
        try store.save(try SessionCredentials(
            cookie: "keep=value=1; token=old",
            musicU: "vip-token",
            deviceID: Self.deviceID
        ))
        AuthenticationProtocol.reset([
            "/eapi/login/token/refresh": .init(
                status: 200,
                headers: ["Set-Cookie": "token=new=value; Domain=.163.com; Path=/; Secure"],
                body: Data(#"{"code":200}"#.utf8)
            )
        ])
        let controller = SessionController(
            store: store,
            transport: transport(),
            validator: { $0.cookie == "keep=value=1; token=new=value" },
            vipValidator: { _ in true }
        )

        #expect(try await controller.refresh())
        #expect(try store.load() == SessionCredentials(
            cookie: "keep=value=1; token=new=value",
            musicU: "vip-token",
            deviceID: Self.deviceID
        ))
    }

    @Test("Remote logout failure still clears the local cookie")
    func logoutFailureClearsLocally() async throws {
        let store = CredentialStore(service: "TinyCloudMusicTests.\(UUID())")
        defer { try? store.delete() }
        try store.save(try SessionCredentials(
            cookie: "MUSIC_U=session",
            musicU: "vip-token",
            deviceID: Self.deviceID
        ))
        AuthenticationProtocol.reset([
            "/eapi/logout": .init(status: 500, headers: [:], body: Data(#"{"code":500}"#.utf8))
        ])
        let controller = SessionController(
            store: store,
            transport: transport(),
            validator: { _ in true },
            vipValidator: { _ in true }
        )

        #expect(await controller.logout() != nil)
        #expect(try store.load() == SessionCredentials(
            cookie: "",
            musicU: "vip-token",
            deviceID: Self.deviceID
        ))
        #expect(controller.state == .guest)
        #expect(AuthenticationProtocol.requestCount(for: "/eapi/logout") == 1)
    }

    @Test("Successful authorization stops polling and failed validation stays unauthenticated")
    func successfulAndRejectedAuthorization() async throws {
        let successStore = CredentialStore(service: "TinyCloudMusicTests.\(UUID())")
        defer { try? successStore.delete() }
        try successStore.save(guestCredentials())
        AuthenticationProtocol.reset(qrStubs(status: 803, setCookie: true))
        let successSession = SessionController(
            store: successStore,
            transport: transport(),
            validator: { !$0.cookie.isEmpty },
            vipValidator: { _ in true }
        )
        let success = QRLoginController(session: successSession, pollingInterval: .zero)
        success.start()
        await wait { success.phase == .succeeded }
        #expect(success.phase == .succeeded)
        #expect(!success.isPolling)

        let rejectedStore = CredentialStore(service: "TinyCloudMusicTests.\(UUID())")
        defer { try? rejectedStore.delete() }
        try rejectedStore.save(guestCredentials())
        AuthenticationProtocol.reset(qrStubs(status: 803, setCookie: true))
        let rejectedSession = SessionController(
            store: rejectedStore,
            transport: transport(),
            validator: { _ in false },
            vipValidator: { _ in true }
        )
        let rejected = QRLoginController(session: rejectedSession, pollingInterval: .zero)
        rejected.start()
        await wait { rejected.phase == .failed }
        #expect(rejectedSession.state != .authenticated)
        #expect(NeteaseCookieHeader.isGuest(try #require(rejectedStore.load()).cookie))
    }

    @Test("Closing the sheet cancels an active polling task")
    func cancellation() async throws {
        let store = CredentialStore(service: "TinyCloudMusicTests.\(UUID())")
        defer { try? store.delete() }
        try store.save(guestCredentials())
        AuthenticationProtocol.reset(qrStubs(status: 801, setCookie: false))
        let session = SessionController(
            store: store,
            transport: transport(),
            validator: { _ in true },
            vipValidator: { _ in true }
        )
        let controller = QRLoginController(session: session, pollingInterval: .seconds(60))
        controller.start()
        await wait { controller.phase == .waitingScan }
        #expect(controller.isPolling)
        controller.cancel()
        #expect(!controller.isPolling)
    }

    private func transport() -> EAPITransport {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AuthenticationProtocol.self]
        return EAPITransport(session: URLSession(configuration: configuration), cookie: "", musicU: "")
    }

    private func guestCredentials() throws -> SessionCredentials {
        try SessionCredentials(
            cookie: "MUSIC_A=guest-token",
            musicU: "",
            deviceID: Self.deviceID
        )
    }

    private func qrStubs(status: Int, setCookie: Bool) -> [String: AuthenticationProtocol.Stub] {
        [
            "/eapi/login/qrcode/unikey": .init(
                status: 200,
                headers: [:],
                body: Data(#"{"code":200,"unikey":"test-key"}"#.utf8)
            ),
            "/eapi/login/qrcode/client/login": .init(
                status: 200,
                headers: setCookie
                    ? ["Set-Cookie": "MUSIC_U=qr-session; Domain=.163.com; Path=/; Secure"]
                    : [:],
                body: Data("{\"code\":\(status)}".utf8)
            )
        ]
    }

    private func wait(until condition: () -> Bool) async {
        for _ in 0..<200 where !condition() {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}
