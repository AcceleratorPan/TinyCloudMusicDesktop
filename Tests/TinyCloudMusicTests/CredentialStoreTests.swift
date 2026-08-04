import Foundation

#if !CREDENTIAL_STORE_CHECK && canImport(Testing)
import Testing
@testable import TinyCloudMusic
#endif

private enum CredentialCheckError: Error {
    case failed
}

private func verifyCredentialValidation() throws {
    let credentials = try SessionCredentials(
        cookie: "  cookie=value  ",
        musicU: "  token  ",
        deviceID: "  DEVICE  "
    )
    guard credentials.cookie == "cookie=value",
          credentials.musicU == "token",
          credentials.deviceID == "DEVICE"
    else {
        throw CredentialCheckError.failed
    }
    let musicUOnly = try SessionCredentials(cookie: "", musicU: credentials.musicU)
    guard musicUOnly.cookie.isEmpty, musicUOnly.musicU == "token" else {
        throw CredentialCheckError.failed
    }

    do {
        _ = try SessionCredentials(cookie: " \n ", musicU: "\t")
        throw CredentialCheckError.failed
    } catch CredentialStoreError.emptyCredentials {
    }

    let cookies = [
        cookie(name: "NMTID", value: "device", domain: ".music.163.com"),
        cookie(name: "__csrf", value: "csrf", domain: ".163.com"),
        cookie(name: "MUSIC_U", value: "music-token", domain: ".163.com"),
        cookie(name: "MUSIC_U", value: "foreign-token", domain: ".example.com")
    ]
    guard let webCredentials = NeteaseWebCookieExtractor.credentials(from: cookies),
          webCredentials.cookie == "MUSIC_U=music-token; NMTID=device; __csrf=csrf",
          webCredentials.musicU.isEmpty,
          let cookieOnlyCredentials = NeteaseWebCookieExtractor.credentials(from: Array(cookies.prefix(2))),
          cookieOnlyCredentials.cookie == "NMTID=device; __csrf=csrf",
          cookieOnlyCredentials.musicU.isEmpty,
          NeteaseWebCookieExtractor.credentials(from: [cookies.last!]) == nil
    else { throw CredentialCheckError.failed }

    let now = Date()
    let merged = NeteaseCookieHeader.merging(
        "TOKEN=upper; deleted=old; maxAgeDeleted=old; keep=value=with=equals; token=old",
        with: [
            cookie(name: "token", value: "new=value", domain: ".163.com"),
            cookie(name: "deleted", value: "", domain: ".music.163.com", expires: now.addingTimeInterval(-1)),
            cookie(name: "maxAgeDeleted", value: "", domain: ".163.com", maximumAge: 0),
            cookie(name: "foreign", value: "ignored", domain: ".example.com")
        ],
        now: now.addingTimeInterval(1)
    )
    guard merged == "TOKEN=upper; keep=value=with=equals; token=new=value" else {
        throw CredentialCheckError.failed
    }
}

private func cookie(
    name: String,
    value: String,
    domain: String,
    expires: Date? = nil,
    maximumAge: Int? = nil
) -> HTTPCookie {
    var properties: [HTTPCookiePropertyKey: Any] = [
        .domain: domain,
        .path: "/",
        .name: name,
        .value: value,
        .secure: "TRUE"
    ]
    if let expires { properties[.expires] = expires }
    if let maximumAge { properties[.maximumAge] = String(maximumAge) }
    return HTTPCookie(properties: properties)!
}

#if CREDENTIAL_STORE_CHECK
@main
private enum CredentialStoreCheck {
    static func main() throws {
        try verifyCredentialValidation()
        print("Credential validation check passed")
    }
}
#elseif canImport(Testing)
@Suite("Session credentials")
struct CredentialStoreTests {
    @Test("Credentials validate and web login only accepts NetEase cookies")
    func validation() throws {
        try verifyCredentialValidation()
    }

    @Test("An isolated missing item maps to guest without folding other store errors")
    func missingItemSnapshotState() throws {
        let store = CredentialStore(service: "TinyCloudMusicTests.\(UUID())")
        defer { try? store.delete() }
        #expect(try store.loadSnapshotState() == .guest)

        let credentials = try SessionCredentials(cookie: "MUSIC_A=test", musicU: "", deviceID: "DEVICE")
        try store.save(credentials)
        #expect(try store.loadSnapshotState() == .authenticated(credentials))
    }
}
#endif
