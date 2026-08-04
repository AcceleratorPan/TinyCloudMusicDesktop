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

enum SessionOperationError: LocalizedError, Equatable, Sendable {
    case superseded

    var errorDescription: String? { "会话操作已被更新的操作取代" }
}

@MainActor
@Observable
final class SessionController {
    typealias Validator = @Sendable (SessionCredentials) async throws -> Bool
    typealias VIPValidator = @Sendable (String) async throws -> Bool
    typealias BeforeLogout = @MainActor @Sendable () async -> Void
    typealias PersistCredentials = @Sendable (SessionCredentials?) throws -> Void
    typealias GuestRegistrar = @Sendable () async throws -> NeteaseAuthenticationContext

    private struct QRFlow {
        let key: String
        let operation: UInt64
        let context: NeteaseAuthenticationContext
    }

    private(set) var state: SessionState = .guest
    private(set) var isVIPVerified = false
    var credentialRevision: UInt64 { credentialSnapshot.load().revision }
    var credentials: SessionCredentials? {
        guard case let .authenticated(credentials) = credentialSnapshot.load().state else { return nil }
        return credentials
    }

    @ObservationIgnored let credentialSnapshot: CredentialSnapshot
    @ObservationIgnored private let transport: EAPITransport
    @ObservationIgnored private let validator: Validator
    @ObservationIgnored private let vipValidator: VIPValidator
    @ObservationIgnored private let persistCredentials: PersistCredentials
    @ObservationIgnored private let guestRegistrar: GuestRegistrar
    @ObservationIgnored private var operationGeneration: UInt64 = 0
    @ObservationIgnored private var qrFlow: QRFlow?
    @ObservationIgnored var beforeLogout: BeforeLogout?

    init(
        store: CredentialStore,
        credentialSnapshot: CredentialSnapshot? = nil,
        transport: EAPITransport = EAPITransport(),
        validator: @escaping Validator,
        vipValidator: @escaping VIPValidator,
        persistCredentials: PersistCredentials? = nil,
        guestRegistrar: GuestRegistrar? = nil
    ) {
        self.transport = transport
        self.credentialSnapshot = credentialSnapshot ?? transport.credentialSnapshot
        self.validator = validator
        self.vipValidator = vipValidator
        self.persistCredentials = persistCredentials ?? { credentials in
            if let credentials {
                try store.save(credentials)
            } else {
                try store.delete()
            }
        }
        self.guestRegistrar = guestRegistrar ?? { try await transport.registerAnonymous() }
        state = Self.sessionState(for: self.credentialSnapshot.load().state)
    }

    func restore() async {
        let operation = beginOperation()
        let initial = credentialSnapshot.load()
        var vipVerified = false

        do {
            switch initial.state {
            case .unavailable:
                state = .error
                return
            case .guest:
                let guest = try await registerGuest(musicU: "")
                try requireCurrent(operation)
                _ = try commit(guest, state: .guest, vipVerified: false)
                return
            case let .authenticated(stored):
                var current = stored
                if current.deviceID.isEmpty {
                    current = try SessionCredentials(
                        cookie: current.cookie,
                        musicU: current.musicU,
                        deviceID: XEAPICodec.generateDeviceID()
                    )
                }

                if !current.musicU.isEmpty {
                    let validationResult: Bool?
                    do {
                        validationResult = try await vipValidator(current.musicU)
                    } catch {
                        validationResult = nil
                    }
                    try requireCurrent(operation)
                    if validationResult == false {
                        if current.cookie.isEmpty {
                            let guest = try await registerGuest(musicU: "")
                            try requireCurrent(operation)
                            _ = try commit(guest, state: .guest, vipVerified: false)
                            return
                        }
                        current = try credentialsRemovingMusicU(from: current)
                    } else if validationResult == true {
                        vipVerified = true
                    }
                }

                if current.cookie.isEmpty {
                    let guest = try await registerGuest(musicU: current.musicU)
                    try requireCurrent(operation)
                    _ = try commit(guest, state: .guest, vipVerified: vipVerified)
                    return
                }
                if NeteaseCookieHeader.isGuest(current.cookie) {
                    if current != stored {
                        _ = try commit(current, state: .guest, vipVerified: vipVerified)
                    } else {
                        state = .guest
                        isVIPVerified = vipVerified
                    }
                    return
                }

                let isValid = try await validator(current)
                try requireCurrent(operation)
                if !isValid {
                    let guest = try await registerGuest(musicU: current.musicU)
                    try requireCurrent(operation)
                    _ = try commit(guest, state: .guest, vipVerified: vipVerified)
                } else if current != stored {
                    _ = try commit(current, state: .authenticated, vipVerified: vipVerified)
                } else {
                    state = .authenticated
                    isVIPVerified = vipVerified
                }
            }
        } catch SessionOperationError.superseded {
        } catch is CancellationError {
        } catch {
            guard isCurrent(operation) else { return }
            state = .error
            isVIPVerified = vipVerified
        }
    }

    @discardableResult
    func save(cookie: String) async -> Bool {
        let operation = beginOperation()
        let previousState = state
        let previousVIP = isVIPVerified
        do {
            return try await commitLogin(cookie: cookie, operation: operation)
        } catch CredentialStoreError.emptyCredentials {
            return false
        } catch SessionOperationError.superseded {
            return false
        } catch is CancellationError {
            return false
        } catch {
            guard isCurrent(operation) else { return false }
            state = credentialSnapshot.load().state == .unavailable ? .error : previousState
            isVIPVerified = previousVIP
            return false
        }
    }

    func requestQRLoginKey() async throws -> String {
        let operation = beginOperation()
        let context = try await authenticationContext(operation: operation)
        try requireCurrent(operation)
        let response = try await transport.requestAuthentication(
            EAPIEndpoint(
                "/eapi/login/qrcode/unikey",
                signing: "/api/login/qrcode/unikey",
                host: "https://interface.music.163.com"
            ),
            payload: ["type": 3],
            context: context
        )
        try requireCurrent(operation)
        let root = try decodedJSONObject(response.object)
        let nestedKey = root.object("data").string("unikey")
        let key = nestedKey.isEmpty ? root.string("unikey") : nestedKey
        guard !key.isEmpty else { throw EAPIError.missingData("unikey") }
        qrFlow = QRFlow(key: key, operation: operation, context: context)
        return key
    }

    func checkQRLogin(key: String) async throws -> QRLoginStatus {
        guard !key.isEmpty else { throw EAPIError.invalidPayload }
        guard let flow = qrFlow, flow.key == key, isCurrent(flow.operation) else {
            throw SessionOperationError.superseded
        }
        let response = try await transport.requestAuthentication(
            EAPIEndpoint(
                "/eapi/login/qrcode/client/login",
                signing: "/api/login/qrcode/client/login",
                host: "https://interface.music.163.com"
            ),
            payload: ["key": key, "type": 3],
            context: flow.context,
            userAgent: "pc"
        )
        try requireCurrent(flow)
        let root = response.object
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
        let merged = NeteaseCookieHeader.merging(flow.context.cookie, with: response.cookies)
        qrFlow = nil
        do {
            guard try await commitLogin(cookie: merged, operation: flow.operation) else {
                throw EAPIError.service(code: code, message: "登录凭据验证或保存失败")
            }
        } catch {
            if isCurrent(flow.operation) { state = .error }
            throw error
        }
        return .succeeded
    }

    @discardableResult
    func refresh() async throws -> Bool {
        let operation = beginOperation()
        guard let current = credentials,
              !current.cookie.isEmpty,
              !NeteaseCookieHeader.isGuest(current.cookie)
        else {
            throw EAPIError.service(code: 301, message: "请先登录")
        }
        let context = authenticationContext(for: current)
        let response = try await transport.requestAuthentication(
            EAPIEndpoint(
                "/eapi/login/token/refresh",
                signing: "/api/login/token/refresh",
                host: "https://interface.music.163.com"
            ),
            payload: [:],
            context: context
        )
        try requireCurrent(operation)
        _ = try decodedJSONObject(response.object)
        guard response.cookies.contains(where: {
            NeteaseCookieHeader.accepts($0) && !NeteaseCookieHeader.isExpired($0)
        }) else {
            throw EAPIError.missingData("新的会话 Cookie")
        }
        return try await commitLogin(
            cookie: NeteaseCookieHeader.merging(current.cookie, with: response.cookies),
            operation: operation,
            deviceID: current.deviceID
        )
    }

    func logout() async -> String? {
        let operation = beginOperation()
        let previous = credentials

        do {
            if let previous, !previous.musicU.isEmpty {
                let retained = try SessionCredentials(
                    cookie: "",
                    musicU: previous.musicU,
                    deviceID: previous.deviceID
                )
                _ = try commit(retained, state: .guest, vipVerified: isVIPVerified)
            } else {
                _ = try commitGuest(state: .guest)
            }
        } catch {
            state = .error
            return "本地会话清理失败，请重试。"
        }

        await transport.invalidateAllCachedResponses()
        guard isCurrent(operation) else { return nil }
        await beforeLogout?()
        guard isCurrent(operation) else { return nil }
        var warning: String?
        if let previous, !previous.cookie.isEmpty, !NeteaseCookieHeader.isGuest(previous.cookie) {
            do {
                let response = try await transport.requestAuthentication(
                    EAPIEndpoint(
                        "/eapi/logout",
                        signing: "/api/logout",
                        host: "https://interface.music.163.com"
                    ),
                    payload: [:],
                    context: authenticationContext(for: previous)
                )
                _ = try decodedJSONObject(response.object)
            } catch {
                warning = "服务器退出失败：\(error.localizedDescription)"
            }
        }
        guard isCurrent(operation) else { return warning }
        do {
            _ = try await authenticationContext(operation: operation)
        } catch {
            return warning ?? "游客登录失败：\(error.localizedDescription)"
        }
        return warning
    }

    @discardableResult
    func verifyAndSaveMusicU(_ value: String) async throws -> Bool {
        let operation = beginOperation()
        let musicU = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !musicU.isEmpty else { return false }
        let current = credentials

        let isValid = try await vipValidator(musicU)
        try requireCurrent(operation)
        guard isValid else { return false }
        let cookie = current?.cookie ?? ""
        let deviceID = try current?.deviceID.isEmpty == false
            ? current!.deviceID
            : XEAPICodec.generateDeviceID()
        let updated = try SessionCredentials(cookie: cookie, musicU: musicU, deviceID: deviceID)
        _ = try commit(updated, state: Self.sessionState(for: .authenticated(updated)), vipVerified: true)
        return true
    }

    @discardableResult
    func invalidate(_ event: SessionCredentialIssueEvent) -> Bool {
        guard event.credentialRevision == credentialRevision else { return false }
        _ = beginOperation()
        do {
            guard let current = credentials else { return false }
            switch event.issue {
            case .cookie:
                guard !current.cookie.isEmpty else { return false }
                if current.musicU.isEmpty {
                    _ = try commitGuest(state: .invalid)
                } else {
                    let updated = try SessionCredentials(
                        cookie: "",
                        musicU: current.musicU,
                        deviceID: current.deviceID
                    )
                    _ = try commit(updated, state: .invalid, vipVerified: isVIPVerified)
                }
            case .musicU:
                guard !current.musicU.isEmpty else { return false }
                if current.cookie.isEmpty {
                    _ = try commitGuest(state: .guest)
                } else {
                    let updated = try credentialsRemovingMusicU(from: current)
                    _ = try commit(
                        updated,
                        state: Self.sessionState(for: .authenticated(updated)),
                        vipVerified: false
                    )
                }
            }
            return true
        } catch {
            state = .error
            isVIPVerified = false
            return true
        }
    }

    @discardableResult
    func invalidate(_ issue: SessionCredentialIssue) -> Bool {
        invalidate(SessionCredentialIssueEvent(issue: issue, credentialRevision: credentialRevision))
    }

    @discardableResult
    func clearMusicU() -> Bool {
        _ = beginOperation()
        do {
            guard let current = credentials, !current.musicU.isEmpty else {
                isVIPVerified = false
                return true
            }
            if current.cookie.isEmpty {
                _ = try commitGuest(state: .guest)
            } else {
                let updated = try credentialsRemovingMusicU(from: current)
                _ = try commit(
                    updated,
                    state: Self.sessionState(for: .authenticated(updated)),
                    vipVerified: false
                )
            }
            return true
        } catch {
            state = .error
            return false
        }
    }

    private func commitLogin(
        cookie: String,
        operation: UInt64,
        deviceID suppliedDeviceID: String? = nil
    ) async throws -> Bool {
        let previous = credentials
        let deviceID = try suppliedDeviceID?.isEmpty == false
            ? suppliedDeviceID!
            : (previous?.deviceID.isEmpty == false ? previous!.deviceID : XEAPICodec.generateDeviceID())
        let loginCredentials = try SessionCredentials(cookie: cookie, musicU: "", deviceID: deviceID)
        let isValid = try await validator(loginCredentials)
        try Task.checkCancellation()
        try requireCurrent(operation)
        guard isValid else { return false }
        let musicU = previous?.musicU ?? ""
        let updated = try SessionCredentials(
            cookie: loginCredentials.cookie,
            musicU: musicU,
            deviceID: deviceID
        )
        _ = try commit(updated, state: .authenticated, vipVerified: isVIPVerified && !musicU.isEmpty)
        await transport.invalidateAllCachedResponses()
        try requireCurrent(operation)
        return true
    }

    private func authenticationContext(operation: UInt64) async throws -> NeteaseAuthenticationContext {
        switch credentialSnapshot.load().state {
        case .unavailable:
            throw CredentialUnavailable()
        case .guest:
            let guest = try await registerGuest(musicU: "")
            try requireCurrent(operation)
            _ = try commit(guest, state: .guest, vipVerified: false)
            return authenticationContext(for: guest)
        case let .authenticated(current):
            if !current.cookie.isEmpty {
                if !current.deviceID.isEmpty { return authenticationContext(for: current) }
                let updated = try SessionCredentials(
                    cookie: current.cookie,
                    musicU: current.musicU,
                    deviceID: XEAPICodec.generateDeviceID()
                )
                _ = try commit(
                    updated,
                    state: Self.sessionState(for: .authenticated(updated)),
                    vipVerified: isVIPVerified
                )
                return authenticationContext(for: updated)
            }
            let guest = try await registerGuest(musicU: current.musicU)
            try requireCurrent(operation)
            _ = try commit(guest, state: .guest, vipVerified: isVIPVerified)
            return authenticationContext(for: guest)
        }
    }

    private func authenticationContext(for credentials: SessionCredentials) -> NeteaseAuthenticationContext {
        NeteaseAuthenticationContext(
            cookie: credentials.cookie,
            deviceID: credentials.deviceID.isEmpty ? (try? XEAPICodec.generateDeviceID()) ?? "" : credentials.deviceID
        )
    }

    private func registerGuest(musicU: String) async throws -> SessionCredentials {
        let guest = try await guestRegistrar()
        return try SessionCredentials(cookie: guest.cookie, musicU: musicU, deviceID: guest.deviceID)
    }

    private func credentialsRemovingMusicU(from credentials: SessionCredentials) throws -> SessionCredentials {
        try SessionCredentials(cookie: credentials.cookie, musicU: "", deviceID: credentials.deviceID)
    }

    @discardableResult
    private func commit(
        _ credentials: SessionCredentials,
        state: SessionState,
        vipVerified: Bool
    ) throws -> CredentialSnapshotValue {
        try persistCredentials(credentials)
        let value = credentialSnapshot.store(.authenticated(credentials))
        self.state = state
        isVIPVerified = vipVerified && !credentials.musicU.isEmpty
        return value
    }

    @discardableResult
    private func commitGuest(state: SessionState) throws -> CredentialSnapshotValue {
        try persistCredentials(nil)
        let value = credentialSnapshot.store(.guest)
        self.state = state
        isVIPVerified = false
        return value
    }

    private func beginOperation() -> UInt64 {
        operationGeneration += 1
        qrFlow = nil
        return operationGeneration
    }

    private func isCurrent(_ operation: UInt64) -> Bool {
        operation == operationGeneration
    }

    private func requireCurrent(_ operation: UInt64) throws {
        guard isCurrent(operation) else { throw SessionOperationError.superseded }
    }

    private func requireCurrent(_ flow: QRFlow) throws {
        guard isCurrent(flow.operation), qrFlow?.key == flow.key, qrFlow?.operation == flow.operation else {
            throw SessionOperationError.superseded
        }
    }

    private static func sessionState(for state: CredentialSnapshotState) -> SessionState {
        switch state {
        case .unavailable: .error
        case .guest: .guest
        case let .authenticated(credentials):
            credentials.cookie.isEmpty || NeteaseCookieHeader.isGuest(credentials.cookie) ? .guest : .authenticated
        }
    }
}
