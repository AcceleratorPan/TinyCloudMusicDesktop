import Foundation
import Observation

enum SessionState: Equatable, Sendable {
    case guest
    case authenticated
    case invalid
    case error
}

enum QRLoginStatus: Equatable, Sendable {
    case expired
    case waitingScan
    case waitingConfirmation
    case succeeded

    init?(code: Int) {
        switch code {
        case 800: self = .expired
        case 801: self = .waitingScan
        case 802: self = .waitingConfirmation
        case 803: self = .succeeded
        default: return nil
        }
    }
}

@MainActor
@Observable
final class SessionController {
    typealias Validator = @Sendable (SessionCredentials) async throws -> Bool
    typealias VIPValidator = @Sendable (String) async throws -> Bool

    private(set) var state: SessionState = .guest
    private(set) var isVIPVerified = false
    private(set) var credentialRevision = 0
    @ObservationIgnored private(set) var credentials: SessionCredentials?
    @ObservationIgnored private let store: CredentialStore
    @ObservationIgnored private let transport: EAPITransport
    @ObservationIgnored private let validator: Validator
    @ObservationIgnored private let vipValidator: VIPValidator
    @ObservationIgnored private var generation = 0

    init(
        store: CredentialStore = CredentialStore(),
        transport: EAPITransport = EAPITransport(),
        validator: @escaping Validator,
        vipValidator: @escaping VIPValidator
    ) {
        self.store = store
        self.transport = transport
        self.validator = validator
        self.vipValidator = vipValidator
    }

    func restore() async {
        generation += 1
        let currentGeneration = generation
        var vipVerified = false
        do {
            guard var credentials = try store.load() else {
                let guest = try await registerGuest(musicU: "")
                guard currentGeneration == generation else { return }
                try store.save(guest)
                self.credentials = guest
                state = .guest
                isVIPVerified = false
                credentialRevision &+= 1
                return
            }
            if credentials.deviceID.isEmpty {
                credentials = try SessionCredentials(
                    cookie: credentials.cookie,
                    musicU: credentials.musicU,
                    deviceID: XEAPICodec.generateDeviceID()
                )
                try store.save(credentials)
            }

            if !credentials.musicU.isEmpty {
                let validationResult: Bool?
                do {
                    validationResult = try await vipValidator(credentials.musicU)
                } catch {
                    validationResult = nil
                }
                guard currentGeneration == generation else { return }
                if validationResult == false {
                    guard let updated = try removingMusicU(from: credentials) else {
                        let guest = try await registerGuest(musicU: "")
                        guard currentGeneration == generation else { return }
                        try store.save(guest)
                        self.credentials = guest
                        state = .guest
                        isVIPVerified = false
                        credentialRevision &+= 1
                        return
                    }
                    credentials = updated
                } else if validationResult == true {
                    vipVerified = true
                }
            }

            guard !credentials.cookie.isEmpty else {
                let guest = try await registerGuest(musicU: credentials.musicU)
                guard currentGeneration == generation else { return }
                try store.save(guest)
                self.credentials = guest
                state = .guest
                isVIPVerified = vipVerified
                credentialRevision &+= 1
                return
            }
            if NeteaseCookieHeader.isGuest(credentials.cookie) {
                self.credentials = credentials
                state = .guest
                isVIPVerified = vipVerified
                return
            }
            let isValid = try await validator(credentials)
            guard currentGeneration == generation else { return }
            if !isValid {
                let guest = try await registerGuest(musicU: credentials.musicU)
                guard currentGeneration == generation else { return }
                try store.save(guest)
                self.credentials = guest
                state = .guest
                isVIPVerified = vipVerified
                credentialRevision &+= 1
                return
            }
            self.credentials = credentials
            state = .authenticated
            isVIPVerified = vipVerified
        } catch {
            guard currentGeneration == generation else { return }
            credentials = nil
            state = .error
            isVIPVerified = vipVerified
        }
    }

    @discardableResult
    func save(cookie: String) async -> Bool {
        generation += 1
        let currentGeneration = generation
        let previousCredentials = credentials ?? (try? store.load())
        let previousState = state
        do {
            let deviceID = try previousCredentials?.deviceID.isEmpty == false
                ? previousCredentials!.deviceID
                : XEAPICodec.generateDeviceID()
            let loginCredentials = try SessionCredentials(cookie: cookie, musicU: "", deviceID: deviceID)
            let isValid = try await validator(loginCredentials)
            try Task.checkCancellation()
            guard currentGeneration == generation, isValid else { return false }
            let musicU = try (credentials?.musicU ?? store.load()?.musicU ?? "")
            let updated = try SessionCredentials(
                cookie: loginCredentials.cookie,
                musicU: musicU,
                deviceID: deviceID
            )
            try store.save(updated)
            credentials = updated
            state = .authenticated
            isVIPVerified = isVIPVerified && !musicU.isEmpty
            credentialRevision &+= 1
            await transport.invalidateAllCachedResponses()
            return true
        } catch CredentialStoreError.emptyCredentials {
            return false
        } catch {
            guard currentGeneration == generation else { return false }
            credentials = previousCredentials
            state = previousCredentials == nil ? .error : previousState
            return false
        }
    }

    func requestQRLoginKey() async throws -> String {
        let context = try await authenticationContext()
        let response = try await transport.requestAuthentication(
            EAPIEndpoint(
                "/eapi/login/qrcode/unikey",
                signing: "/api/login/qrcode/unikey",
                host: "https://interface.music.163.com"
            ),
            payload: ["type": 3],
            context: context
        )
        let root = try decodedJSONObject(response.data)
        let nestedKey = root.object("data").string("unikey")
        let key = nestedKey.isEmpty ? root.string("unikey") : nestedKey
        guard !key.isEmpty else { throw EAPIError.missingData("unikey") }
        return key
    }

    func checkQRLogin(key: String) async throws -> QRLoginStatus {
        guard !key.isEmpty else { throw EAPIError.invalidPayload }
        let context = try await authenticationContext()
        let response = try await transport.requestAuthentication(
            EAPIEndpoint(
                "/eapi/login/qrcode/client/login",
                signing: "/api/login/qrcode/client/login",
                host: "https://interface.music.163.com"
            ),
            payload: ["key": key, "type": 3],
            context: context,
            userAgent: "pc"
        )
        guard let root = try JSONSerialization.jsonObject(with: response.data) as? [String: Any] else {
            throw EAPIError.invalidResponse
        }
        let code = root.int("code")
        guard let status = QRLoginStatus(code: code) else {
            let message = root.string("message")
            throw EAPIError.service(code: code, message: message.isEmpty ? root.string("msg") : message)
        }
        guard status == .succeeded else { return status }
        guard response.cookies.contains(where: {
            NeteaseCookieHeader.accepts($0) && !NeteaseCookieHeader.isExpired($0)
        }) else {
            throw EAPIError.missingData("Set-Cookie")
        }
        let merged = NeteaseCookieHeader.merging(context.cookie, with: response.cookies)
        guard await save(cookie: merged) else {
            throw EAPIError.service(code: code, message: "登录凭据验证或保存失败")
        }
        return .succeeded
    }

    @discardableResult
    func refresh() async throws -> Bool {
        guard let current = try storedCredentials(),
              !current.cookie.isEmpty,
              !NeteaseCookieHeader.isGuest(current.cookie)
        else {
            throw EAPIError.service(code: 301, message: "请先登录")
        }
        let context = try authenticationContext(for: current)
        let response = try await transport.requestAuthentication(
            EAPIEndpoint(
                "/eapi/login/token/refresh",
                signing: "/api/login/token/refresh",
                host: "https://interface.music.163.com"
            ),
            payload: [:],
            context: context
        )
        _ = try decodedJSONObject(response.data)
        guard response.cookies.contains(where: {
            NeteaseCookieHeader.accepts($0) && !NeteaseCookieHeader.isExpired($0)
        }) else {
            throw EAPIError.missingData("新的会话 Cookie")
        }
        return await save(cookie: NeteaseCookieHeader.merging(current.cookie, with: response.cookies))
    }

    func logout() async -> String? {
        var warning: String?
        let current = try? storedCredentials()
        if let current, !current.cookie.isEmpty, !NeteaseCookieHeader.isGuest(current.cookie) {
            do {
                let response = try await transport.requestAuthentication(
                    EAPIEndpoint(
                        "/eapi/logout",
                        signing: "/api/logout",
                        host: "https://interface.music.163.com"
                    ),
                    payload: [:],
                    context: try authenticationContext(for: current)
                )
                _ = try decodedJSONObject(response.data)
            } catch {
                warning = "服务器退出失败：\(error.localizedDescription)"
            }
        }
        clear()
        await transport.invalidateAllCachedResponses()
        if state == .error { return "本地会话清理失败，请重试。" }
        do {
            _ = try await authenticationContext()
        } catch {
            return warning ?? "游客登录失败：\(error.localizedDescription)"
        }
        return warning
    }

    @discardableResult
    func verifyAndSaveMusicU(_ value: String) async throws -> Bool {
        generation += 1
        let currentGeneration = generation
        let musicU = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !musicU.isEmpty else { return false }

        do {
            let isValid = try await vipValidator(musicU)
            guard currentGeneration == generation else { return false }
            guard isValid else { return false }

            let current = try credentials ?? store.load()
            let cookie = current?.cookie ?? ""
            let deviceID = try current?.deviceID.isEmpty == false
                ? current!.deviceID
                : XEAPICodec.generateDeviceID()
            let updated = try SessionCredentials(cookie: cookie, musicU: musicU, deviceID: deviceID)
            try store.save(updated)
            credentials = updated
            isVIPVerified = true
            credentialRevision &+= 1
            return true
        } catch {
            guard currentGeneration == generation else { return false }
            throw error
        }
    }

    private func clear() {
        generation += 1
        let vipWasVerified = isVIPVerified
        do {
            let current = try credentials ?? store.load()
            let musicU = current?.musicU ?? ""
            let deviceID = current?.deviceID ?? ""
            if musicU.isEmpty {
                try store.delete()
                credentials = nil
            } else {
                let updated = try SessionCredentials(cookie: "", musicU: musicU, deviceID: deviceID)
                try store.save(updated)
                credentials = updated
            }
            state = .guest
            isVIPVerified = vipWasVerified && !musicU.isEmpty
            credentialRevision &+= 1
        } catch {
            credentials = nil
            state = .error
            isVIPVerified = false
            credentialRevision &+= 1
        }
    }

    @discardableResult
    func invalidate(_ issue: SessionCredentialIssue) -> Bool {
        generation += 1
        do {
            guard let current = try (credentials ?? store.load()) else { return false }
            switch issue {
            case .cookie:
                guard !current.cookie.isEmpty else { return false }
                if current.musicU.isEmpty {
                    try store.delete()
                    credentials = nil
                } else {
                    let updated = try SessionCredentials(
                        cookie: "",
                        musicU: current.musicU,
                        deviceID: current.deviceID
                    )
                    try store.save(updated)
                    credentials = updated
                }
                state = .invalid
            case .musicU:
                guard !current.musicU.isEmpty else { return false }
                credentials = try removingMusicU(from: current)
                isVIPVerified = false
            }
            credentialRevision &+= 1
            return true
        } catch {
            state = .error
            isVIPVerified = false
            credentialRevision &+= 1
            return true
        }
    }

    @discardableResult
    func clearMusicU() -> Bool {
        generation += 1
        do {
            guard let current = try (credentials ?? store.load()) else {
                isVIPVerified = false
                credentialRevision &+= 1
                return true
            }
            credentials = try removingMusicU(from: current)
            isVIPVerified = false
            credentialRevision &+= 1
            return true
        } catch {
            state = .error
            credentialRevision &+= 1
            return false
        }
    }

    private func removingMusicU(from credentials: SessionCredentials) throws -> SessionCredentials? {
        guard !credentials.cookie.isEmpty else {
            try store.delete()
            return nil
        }
        let updated = try SessionCredentials(
            cookie: credentials.cookie,
            musicU: "",
            deviceID: credentials.deviceID
        )
        try store.save(updated)
        return updated
    }

    private func authenticationContext() async throws -> NeteaseAuthenticationContext {
        let current = try storedCredentials()
        if let current,
           !current.cookie.isEmpty,
           state == .authenticated || NeteaseCookieHeader.isGuest(current.cookie) {
            return try authenticationContext(for: current)
        }
        let guest = try await registerGuest(musicU: current?.musicU ?? "")
        try Task.checkCancellation()
        try store.save(guest)
        credentials = guest
        state = .guest
        credentialRevision &+= 1
        return try authenticationContext(for: guest)
    }

    private func authenticationContext(
        for credentials: SessionCredentials
    ) throws -> NeteaseAuthenticationContext {
        if !credentials.deviceID.isEmpty {
            return NeteaseAuthenticationContext(cookie: credentials.cookie, deviceID: credentials.deviceID)
        }
        let updated = try SessionCredentials(
            cookie: credentials.cookie,
            musicU: credentials.musicU,
            deviceID: XEAPICodec.generateDeviceID()
        )
        try store.save(updated)
        self.credentials = updated
        return NeteaseAuthenticationContext(cookie: updated.cookie, deviceID: updated.deviceID)
    }

    private func registerGuest(musicU: String) async throws -> SessionCredentials {
        let guest = try await transport.registerAnonymous()
        let updated = try SessionCredentials(
            cookie: guest.cookie,
            musicU: musicU,
            deviceID: guest.deviceID
        )
        return updated
    }

    private func storedCredentials() throws -> SessionCredentials? {
        if let credentials { return credentials }
        return try store.load()
    }
}
