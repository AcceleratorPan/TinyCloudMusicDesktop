import Foundation
import Security

struct SessionCredentials: Equatable, Sendable {
    let cookie: String
    let musicU: String
    let deviceID: String

    init(cookie: String, musicU: String, deviceID: String = "") throws {
        let cookie = cookie.trimmingCharacters(in: .whitespacesAndNewlines)
        let musicU = musicU.trimmingCharacters(in: .whitespacesAndNewlines)
        let deviceID = deviceID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cookie.isEmpty || !musicU.isEmpty else {
            throw CredentialStoreError.emptyCredentials
        }
        self.cookie = cookie
        self.musicU = musicU
        self.deviceID = deviceID
    }
}

enum NeteaseCookieHeader {
    static func merging(_ current: String, with responseCookies: [HTTPCookie], now: Date = Date()) -> String {
        var values = current.split(separator: ";").reduce(into: [String: String]()) { result, part in
            let pair = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let name = pair.first.map(String.init)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !name.isEmpty, pair.count == 2 else { return }
            result[name] = String(pair[1]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        for cookie in responseCookies where accepts(cookie) && !cookie.name.isEmpty {
            if isExpired(cookie, now: now) {
                values[cookie.name] = nil
            } else {
                values[cookie.name] = cookie.value
            }
        }
        return values.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: "; ")
    }

    static func accepts(_ cookie: HTTPCookie) -> Bool {
        let domain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return domain == "163.com" || domain.hasSuffix(".163.com")
    }

    static func isExpired(_ cookie: HTTPCookie, now: Date = Date()) -> Bool {
        if let expiresDate = cookie.expiresDate, expiresDate <= now { return true }
        let maximumAge = cookie.properties?[.maximumAge]
        if let value = maximumAge as? NSNumber { return value.intValue <= 0 }
        if let value = maximumAge as? String, let seconds = Int(value) { return seconds <= 0 }
        return false
    }

    static func value(named name: String, in header: String) -> String {
        header.split(separator: ";").lazy.compactMap { part -> String? in
            let pair = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2,
                  pair[0].trimmingCharacters(in: .whitespacesAndNewlines) == name
            else { return nil }
            return String(pair[1]).trimmingCharacters(in: .whitespacesAndNewlines)
        }.first ?? ""
    }

    static func isGuest(_ header: String) -> Bool {
        !value(named: "MUSIC_A", in: header).isEmpty && value(named: "MUSIC_U", in: header).isEmpty
    }
}

enum NeteaseWebCookieExtractor {
    static func credentials(from cookies: [HTTPCookie]) -> SessionCredentials? {
        let cookie = NeteaseCookieHeader.merging("", with: cookies)
        guard !cookie.isEmpty else { return nil }
        return try? SessionCredentials(cookie: cookie, musicU: "")
    }
}

enum CredentialStoreError: LocalizedError, Equatable, Sendable {
    case emptyCredentials
    case invalidStoredData
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .emptyCredentials: "Cookie 和 MUSIC_U 不能同时为空"
        case .invalidStoredData: "保存的会话数据无效"
        case let .keychain(status): "Keychain 操作失败（\(status)）"
        }
    }
}

struct CredentialStore: Sendable {
    static let productionService = "com.tinycloudmusic.app.session"

    private let service: String
    private let account = "credentials"

    init(service: String) {
        self.service = service
    }

    func save(_ credentials: SessionCredentials) throws {
        let credentials = try SessionCredentials(
            cookie: credentials.cookie,
            musicU: credentials.musicU,
            deviceID: credentials.deviceID
        )
        let data = try JSONEncoder().encode(StoredCredentials(credentials))
        let query = baseQuery
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            try requireSuccess(SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil))
        } else {
            try requireSuccess(status)
        }
    }

    func load() throws -> SessionCredentials? {
        var query = baseQuery
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true
        var value: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &value)
        if status == errSecItemNotFound { return nil }
        try requireSuccess(status)
        guard let data = value as? Data,
              let stored = try? JSONDecoder().decode(StoredCredentials.self, from: data)
        else { throw CredentialStoreError.invalidStoredData }
        return try SessionCredentials(
            cookie: stored.cookie,
            musicU: stored.musicU,
            deviceID: stored.deviceID ?? ""
        )
    }

    func loadSnapshotState() throws -> CredentialSnapshotState {
        try load().map(CredentialSnapshotState.authenticated) ?? .guest
    }

    func delete() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CredentialStoreError.keychain(status)
        }
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    private func requireSuccess(_ status: OSStatus) throws {
        guard status == errSecSuccess else { throw CredentialStoreError.keychain(status) }
    }
}

private struct StoredCredentials: Codable {
    let cookie: String
    let musicU: String
    let deviceID: String?

    init(_ credentials: SessionCredentials) {
        cookie = credentials.cookie
        musicU = credentials.musicU
        deviceID = credentials.deviceID
    }
}
