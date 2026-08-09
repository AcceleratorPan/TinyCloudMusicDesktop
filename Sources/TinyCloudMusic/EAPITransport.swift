import CommonCrypto
import CryptoKit
import Foundation
import Security
import zlib

enum EAPIResponseEncoding: UInt8, Sendable {
    case automatic
    case json
    case encrypted
}

struct EAPIEndpoint: Sendable {
    let physicalURL: URL
    let logicalPath: String
    let responseEncoding: EAPIResponseEncoding

    init(
        _ physicalPath: String,
        signing logicalPath: String? = nil,
        host: String = "https://music.163.com",
        responseEncoding: EAPIResponseEncoding = .automatic
    ) {
        physicalURL = URL(string: host + physicalPath)!
        self.logicalPath = logicalPath ?? physicalPath.replacingOccurrences(of: "/eapi/", with: "/api/")
        self.responseEncoding = responseEncoding
    }
}

enum EAPIReadCache: Hashable, Sendable {
    case search
    case searchHints
    case detail
    case library
    case playlistSummaries
    case comments
    case lyrics
    case listeningHistory

    fileprivate var policy: EAPIRequestCachePolicy {
        switch self {
        case .search: .read(ttl: 2 * 60, staleIfError: 10 * 60)
        case .searchHints: .read(ttl: 5 * 60, staleIfError: 30 * 60)
        case .detail: .read(ttl: 5 * 60, staleIfError: 30 * 60)
        case .library: .read(ttl: 90, staleIfError: 15 * 60)
        case .playlistSummaries: .read(ttl: 0, staleIfError: 15 * 60)
        case .comments: .read(ttl: 30, staleIfError: 2 * 60)
        case .lyrics: .read(ttl: 60 * 60, staleIfError: 24 * 60 * 60)
        case .listeningHistory: .read(ttl: 30, staleIfError: 5 * 60)
        }
    }
}

enum EAPIRequestCachePolicy: Sendable {
    case none
    case read(ttl: TimeInterval, staleIfError: TimeInterval)
    case invalidateAccount
}

struct EAPIHTTPResponse: @unchecked Sendable {
    let data: Data
    let object: [String: Any]
    let statusCode: Int
    let headers: [String: String]
    let cookies: [HTTPCookie]
}

struct EAPIParsedResponse: @unchecked Sendable {
    let data: Data
    let object: [String: Any]?
}

enum SensitiveHeaderRedirectPolicy {
    static func allows(originalURL: URL, redirectedURL: URL) -> Bool {
        originalURL.scheme?.lowercased() == "https"
            && redirectedURL.scheme?.lowercased() == "https"
            && redirectedURL.user == nil
            && redirectedURL.password == nil
            && (originalURL.port ?? 443) == (redirectedURL.port ?? 443)
            && redirectedURL.host?.lowercased() == originalURL.host?.lowercased()
    }

    static func requiresProtection(_ request: URLRequest) -> Bool {
        request.allHTTPHeaderFields?.keys.contains {
            let name = $0.lowercased()
            return name == "cookie" || name == "authorization" || name == "music_u" || name == "x-nos-token"
        } == true
    }
}

private final class SensitiveHeaderRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let originalURL: URL

    init(originalURL: URL) { self.originalURL = originalURL }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let url = request.url,
              SensitiveHeaderRedirectPolicy.allows(originalURL: originalURL, redirectedURL: url)
        else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}

struct NeteaseAuthenticationContext: Sendable {
    let cookie: String
    let deviceID: String
}

enum EAPIError: LocalizedError, Equatable {
    case invalidPayload
    case invalidCiphertext
    case invalidPadding
    case invalidResponse
    case http(Int)
    case service(code: Int, message: String)
    case missingData(String)

    var errorDescription: String? {
        switch self {
        case .invalidPayload: "请求数据无效"
        case .invalidCiphertext: "加密响应无效"
        case .invalidPadding: "响应填充校验失败"
        case .invalidResponse: "服务返回了无法识别的数据"
        case let .http(status): "网络请求失败（HTTP \(status)）"
        case let .service(_, message): message.isEmpty ? "服务暂时不可用" : message
        case let .missingData(name): "响应缺少 \(name)"
        }
    }
}

extension EAPIParsedResponse {
    static func businessError(in object: [String: Any]) -> EAPIError? {
        guard let value = object["code"] else { return nil }
        guard let code = (value as? NSNumber)?.intValue ?? (value as? String).flatMap(Int.init) else {
            return .invalidResponse
        }
        guard code != 0, !(200..<300).contains(code) else { return nil }
        let message = object.string("message")
        return .service(code: code, message: message.isEmpty ? object.string("msg") : message)
    }

    var businessError: EAPIError? { object.flatMap { Self.businessError(in: $0) } }
}

struct CredentialUnavailable: LocalizedError, Equatable, Sendable {
    var errorDescription: String? { "凭据尚未完成恢复" }
}

struct CredentialRevisionMismatch: LocalizedError, Equatable, Sendable {
    let expected: UInt64
    let actual: UInt64

    var errorDescription: String? { "凭据已改变，请重试当前操作" }
}

enum SessionCredentialIssue: String, Sendable {
    case cookie
    case musicU

    static func detect(in data: Data, vip: Bool, musicU: String) -> Self? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return detect(in: object, vip: vip, musicU: musicU)
    }

    static func detect(in object: [String: Any], vip: Bool, musicU: String) -> Self? {
        let code = (object["code"] as? NSNumber)?.intValue
            ?? (object["code"] as? String).flatMap(Int.init)
        guard let code, (300..<400).contains(code) || code == 401 || code == 403 else { return nil }
        return vip && !musicU.isEmpty ? .musicU : .cookie
    }

    static func isAuthenticationFailure(_ error: Error) -> Bool {
        guard let error = error as? EAPIError else { return false }
        let code: Int
        switch error {
        case let .http(value), let .service(value, _): code = value
        default: return false
        }
        return (300..<400).contains(code) || code == 401 || code == 403
    }
}

struct SessionCredentialIssueEvent: Equatable, Sendable {
    let issue: SessionCredentialIssue
    let credentialRevision: UInt64
}

extension Notification.Name {
    static let neteaseCredentialIssue = Notification.Name("TinyCloudMusic.credentialIssue")
}

enum EAPICodec {
    struct DecodedResponse {
        let data: Data
        let object: Any
    }

    private static let separator = "36cd479b6b5"
    private static let eapiKey = Data("e82ckenh8dichen8".utf8)
    private static let cacheKey = Data(")(13daqP@ssw0rd~".utf8)

    static func envelope(path: String, json: Data) throws -> Data {
        guard let jsonText = String(data: json, encoding: .utf8) else { throw EAPIError.invalidPayload }
        let digestSource = Data("nobody\(path)use\(jsonText)md5forencrypt".utf8)
        let digest = Insecure.MD5.hash(data: digestSource).map { String(format: "%02x", $0) }.joined()
        return Data("\(path)-\(separator)-\(jsonText)-\(separator)-\(digest)".utf8)
    }

    static func requestBody(path: String, json: Data) throws -> Data {
        let cipher = try crypt(try envelope(path: path, json: json), key: eapiKey, operation: CCOperation(kCCEncrypt))
        return Data(("params=" + cipher.map { String(format: "%02X", $0) }.joined()).utf8)
    }

    static func albumCacheKey(id: Int64) throws -> String {
        try crypt(Data("id=\(id)".utf8), key: cacheKey, operation: CCOperation(kCCEncrypt)).base64EncodedString()
    }

    static func decrypt(_ data: Data) throws -> Data {
        guard !data.isEmpty, data.count.isMultiple(of: kCCBlockSizeAES128) else {
            throw EAPIError.invalidCiphertext
        }
        do {
            return try crypt(data, key: eapiKey, operation: CCOperation(kCCDecrypt))
        } catch let error as EAPIError {
            throw error
        } catch {
            throw EAPIError.invalidPadding
        }
    }

    static func responseData(_ data: Data, encoding: EAPIResponseEncoding = .automatic) throws -> Data {
        try decodedResponse(data, encoding: encoding).data
    }

    static func decodedResponse(
        _ data: Data,
        encoding: EAPIResponseEncoding = .automatic
    ) throws -> DecodedResponse {
        guard !data.isEmpty else { throw EAPIError.invalidResponse }
        switch encoding {
        case .json:
            return try decodedJSON(data)
        case .encrypted:
            return try decodedJSON(decrypt(data))
        case .automatic:
            if let object = try? JSONSerialization.jsonObject(with: data) {
                return DecodedResponse(data: data, object: object)
            }
            return try decodedJSON(decrypt(data))
        }
    }

    private static func decodedJSON(_ data: Data) throws -> DecodedResponse {
        guard let object = try? JSONSerialization.jsonObject(with: data) else {
            throw EAPIError.invalidResponse
        }
        return DecodedResponse(data: data, object: object)
    }

    fileprivate static func crypt(_ input: Data, key: Data, operation: CCOperation) throws -> Data {
        var output = Data(count: input.count + kCCBlockSizeAES128)
        let outputCapacity = output.count
        var outputLength = 0
        let status = output.withUnsafeMutableBytes { outputBytes in
            input.withUnsafeBytes { inputBytes in
                key.withUnsafeBytes { keyBytes in
                    CCCrypt(
                        operation,
                        CCAlgorithm(kCCAlgorithmAES),
                        CCOptions(kCCOptionECBMode | kCCOptionPKCS7Padding),
                        keyBytes.baseAddress,
                        key.count,
                        nil,
                        inputBytes.baseAddress,
                        input.count,
                        outputBytes.baseAddress,
                        outputCapacity,
                        &outputLength
                    )
                }
            }
        }
        guard status == kCCSuccess else {
            throw operation == CCOperation(kCCDecrypt) ? EAPIError.invalidPadding : EAPIError.invalidPayload
        }
        output.removeSubrange(outputLength..<output.count)
        return output
    }
}

enum WEAPICodec {
    private static let iv = Data("0102030405060708".utf8)
    private static let presetKey = Data("0CoJUm6Qyw8W8jud".utf8)
    private static let alphabet = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789".utf8)
    private static let publicKeyDER = Data(base64Encoded: "MIGJAoGBAOC1CfYlnfhkLbw1ZikBR33yJnfsFStf9orOYVu3tyUVKzqxeodq6opap20uQXYp7E7jQfVhNfzPaVKAEE4DEuy9qSVXyThwEUr2ydBcT38MNoW3pGvuJVkyV1zOELQk2BPP5IddPoIEe5fd71J0HVRrjiidxpNbPs4EYtsKIrjnAgMBAAE=")!

    static func requestBody(json: Data, secretKey: String = randomSecretKey()) throws -> Data {
        let fields = try encryptedFields(json: json, secretKey: secretKey)
        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(name: "params", value: fields.params),
            URLQueryItem(name: "encSecKey", value: fields.encSecKey)
        ]
        guard let query = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B") else {
            throw EAPIError.invalidPayload
        }
        return Data(query.utf8)
    }

    static func encryptedFields(json: Data, secretKey: String) throws -> (params: String, encSecKey: String) {
        let secret = Data(secretKey.utf8)
        guard secret.count == kCCKeySizeAES128 else { throw EAPIError.invalidPayload }
        let first = try aesCBC(json, key: presetKey).base64EncodedString()
        let params = try aesCBC(Data(first.utf8), key: secret).base64EncodedString()
        return (params, try rsaEncrypt(String(secretKey.reversed())))
    }

    static func csrfToken(in cookie: String) -> String {
        cookie.split(separator: ";").lazy.compactMap { part -> String? in
            let pair = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2,
                  pair[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "__csrf"
            else { return nil }
            return String(pair[1]).trimmingCharacters(in: .whitespacesAndNewlines)
        }.first ?? ""
    }

    private static func randomSecretKey() -> String {
        var generator = SystemRandomNumberGenerator()
        return String(decoding: (0..<16).map { _ in alphabet.randomElement(using: &generator)! }, as: UTF8.self)
    }

    private static func aesCBC(_ input: Data, key: Data) throws -> Data {
        var output = Data(count: input.count + kCCBlockSizeAES128)
        let capacity = output.count
        var length = 0
        let status = output.withUnsafeMutableBytes { outputBytes in
            input.withUnsafeBytes { inputBytes in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(
                            CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding), keyBytes.baseAddress, key.count,
                            ivBytes.baseAddress, inputBytes.baseAddress, input.count,
                            outputBytes.baseAddress, capacity, &length
                        )
                    }
                }
            }
        }
        guard status == kCCSuccess else { throw EAPIError.invalidPayload }
        output.removeSubrange(length..<output.count)
        return output
    }

    private static func rsaEncrypt(_ value: String) throws -> String {
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass: kSecAttrKeyClassPublic,
            kSecAttrKeySizeInBits: 1_024
        ]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(publicKeyDER as CFData, attributes as CFDictionary, &error) else {
            throw EAPIError.invalidPayload
        }
        let message = Data(value.utf8)
        let blockSize = SecKeyGetBlockSize(key)
        guard message.count <= blockSize else { throw EAPIError.invalidPayload }
        var input = Data(repeating: 0, count: blockSize)
        input.replaceSubrange((blockSize - message.count)..<blockSize, with: message)
        guard let encrypted = SecKeyCreateEncryptedData(key, .rsaEncryptionRaw, input as CFData, &error) as Data? else {
            throw EAPIError.invalidPayload
        }
        return encrypted.map { String(format: "%02x", $0) }.joined()
    }
}

enum XEAPICodec {
    struct PublicKeyState: Sendable {
        let publicKey: String
        let version: String
        let secret: String
    }

    private static let staticKey = Data(
        [
            0xab, 0x1d, 0x5a, 0x43, 0x0f, 0x6b, 0xb0, 0x4a,
            0x3f, 0x01, 0xe8, 0x1d, 0xdd, 0x72, 0xbd, 0x91,
            0x6d, 0x5c, 0xe5, 0x91, 0x24, 0x8a, 0xc1, 0x28,
            0x71, 0x48, 0x06, 0xd7, 0xf8, 0xfb, 0x1b, 0x84
        ]
    )
    private static let signKey = Data(
        "mUHCwVNWJbunMqAHf5MImuirT6plvs6VSFW62MGHstFQxhBGdEoIhLItH3djc4+FB/OKty3+lL2rGeoFBpVe5g==".utf8
    )
    private static let eapiKey = Data("e82ckenh8dichen8".utf8)
    private static let idXORKey = Array("3go8&$8*3*3h0k(2)2".utf8)
    private static let androidUserAgent =
        "NeteaseMusic/9.1.65.240927161425(9001065);Dalvik/2.1.0 (Linux; U; Android 14; 23013RK75C Build/UKQ1.230804.001)"

    static func generateDeviceID() throws -> String {
        try randomData(count: 26).map { String(format: "%02X", $0) }.joined()
    }

    static func publicKeyRequest(deviceID: String) throws -> (request: URLRequest, nonce: String) {
        let nonce = try randomDigits(count: 16)
        let timestamp = String(Int64(Date().timeIntervalSince1970 * 1_000))
        let body = try formEncoded([
            ("appVersion", "9.1.65"),
            ("currentKeyVersion", ""),
            ("deviceId", deviceID),
            ("nonce", nonce),
            ("os", "android"),
            ("requestType", "active"),
            ("signature", signature(timestamp: timestamp, nonce: nonce)),
            ("t1", ""),
            ("t2", ""),
            ("timestamp", timestamp),
            ("uid", "")
        ])
        var request = URLRequest(
            url: URL(string: "https://interface.music.163.com/api/gorilla/anti/crawler/security/key/get")!,
            timeoutInterval: 15
        )
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/x-www-form-urlencoded;charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue(androidUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("deviceId=\(deviceID)", forHTTPHeaderField: "Cookie")
        return (request, nonce)
    }

    static func decodePublicKey(_ data: Data, nonce: String) throws -> PublicKeyState {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              root.int("code") == 200
        else { throw EAPIError.invalidResponse }
        let payload = root.object("data")
        let timestamp = payload.string("timestamp")
        guard !timestamp.isEmpty,
              payload.string("signature") == signature(timestamp: timestamp, nonce: nonce),
              let encrypted = Data(base64Encoded: payload.string("encryptedData"))
        else { throw EAPIError.invalidResponse }
        let decrypted = try EAPICodec.crypt(encrypted, key: staticKey, operation: CCOperation(kCCDecrypt))
        guard let state = try JSONSerialization.jsonObject(with: decrypted) as? [String: Any] else {
            throw EAPIError.invalidResponse
        }
        let publicKey = state.string("publicKey")
        let version = state.string("version")
        let secret = state.string("sk")
        guard !publicKey.isEmpty, !version.isEmpty, !secret.isEmpty else {
            throw EAPIError.invalidResponse
        }
        return PublicKeyState(publicKey: publicKey, version: version, secret: secret)
    }

    static func anonymousRequest(deviceID: String, publicKey: PublicKeyState) throws -> URLRequest {
        let timestamp = Int64(Date().timeIntervalSince1970 * 1_000)
        let buildVersion = String(timestamp).prefix(10)
        let nuid = try randomData(count: 32).map { String(format: "%02x", $0) }.joined()
        let nmtid = try randomData(count: 16).map { String(format: "%02x", $0) }.joined()
        let wnmcid = try randomLowercase(count: 6) + ".\(timestamp).01.0"
        let processedCookie: [(String, String)] = [
            ("__remember_me", "true"),
            ("ntes_kaola_ad", "1"),
            ("_ntes_nuid", nuid),
            ("_ntes_nnid", "\(nuid),\(timestamp)"),
            ("WNMCID", wnmcid),
            ("WEVNSM", "1.0.0"),
            ("osver", "16"),
            ("deviceId", deviceID),
            ("os", "android"),
            ("channel", "netease"),
            ("appver", "9.1.65"),
            ("MUSIC_A", ""),
            ("NMTID", nmtid),
            ("buildver", String(buildVersion)),
            ("sDeviceId", deviceID)
        ]
        let username = anonymousUsername(deviceID: deviceID)
        let body = try encryptedFields(username: username, publicKey: publicKey)
        var request = URLRequest(
            url: URL(string: "https://interface3.music.163.com/xeapi/register/anonimous")!,
            timeoutInterval: 15
        )
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/x-www-form-urlencoded;charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue(androidUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("ENCRYPTED", forHTTPHeaderField: "X-Client-Enc-State")
        request.setValue("true", forHTTPHeaderField: "x-aeapi")
        request.setValue(deviceID, forHTTPHeaderField: "x-deviceid")
        request.setValue("android", forHTTPHeaderField: "x-os")
        request.setValue("16", forHTTPHeaderField: "x-osver")
        request.setValue("9.1.65", forHTTPHeaderField: "x-appver")
        request.setValue(deviceID, forHTTPHeaderField: "x-sdeviceid")
        request.setValue(String(buildVersion), forHTTPHeaderField: "x-buildver")
        request.setValue(try encodedCookie(processedCookie), forHTTPHeaderField: "Cookie")
        return request
    }

    static func decodeResponse(_ data: Data) throws -> Data {
        if (try? JSONSerialization.jsonObject(with: data)) != nil { return data }
        let decrypted = try EAPICodec.crypt(data, key: eapiKey, operation: CCOperation(kCCDecrypt))
        if decrypted.starts(with: [0x1f, 0x8b]) { return try gunzip(decrypted) }
        return decrypted
    }

    private static func encryptedFields(username: String, publicKey: PublicKeyState) throws -> Data {
        let usernameForm = try formEncoded([("username", username)])
        let plaintext = try JSONSerialization.data(
            withJSONObject: [
                "body": usernameForm.base64EncodedString(),
                "queryString": "e_r=true"
            ],
            options: [.sortedKeys]
        )
        let dynamicKey = try randomData(count: 16)
        let inner = try EAPICodec.crypt(plaintext, key: staticKey, operation: CCOperation(kCCEncrypt))
        let random = try randomData(count: 16)
        let xored = Data(inner.enumerated().map { $0.element ^ random[$0.offset & 0x0f] })
        let base64 = Data(xored.base64EncodedString().utf8)
        let rotation = base64.isEmpty ? 0 : Int(random[0] & 0x0f) % base64.count
        let transformed = random + base64[rotation...] + base64[..<rotation]
        let b = try EAPICodec.crypt(transformed, key: dynamicKey, operation: CCOperation(kCCEncrypt))

        guard let peerData = Data(base64Encoded: publicKey.publicKey) else { throw EAPIError.invalidResponse }
        let peer = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerData)
        let ephemeral = Curve25519.KeyAgreement.PrivateKey()
        let ephemeralPublic = ephemeral.publicKey.rawRepresentation
        let shared = try ephemeral.sharedSecretFromKeyAgreement(with: peer)
        let sharedData = shared.withUnsafeBytes { Data($0) }
        let prk = Data(HMAC<SHA256>.authenticationCode(
            for: sharedData.isEmpty ? Data(repeating: 0, count: 32) : sharedData,
            using: SymmetricKey(data: Data(repeating: 0, count: 32))
        ))
        let agreementKey = Data(HMAC<SHA256>.authenticationCode(
            for: ephemeralPublic + [1],
            using: SymmetricKey(data: prk)
        )).prefix(16)
        let nonce = AES.GCM.Nonce()
        let nonceData = nonce.withUnsafeBytes { Data($0) }
        let sealed = try AES.GCM.seal(
            Data("\(dynamicKey.base64EncodedString())|android|\(publicKey.secret)".utf8),
            using: SymmetricKey(data: agreementKey),
            nonce: nonce
        )
        let s = ephemeralPublic + nonceData + sealed.ciphertext + sealed.tag
        let r = try EAPICodec.crypt(
            Data("\(publicKey.version)|".utf8),
            key: staticKey,
            operation: CCOperation(kCCEncrypt)
        )
        return try formEncoded([
            ("B", b.base64EncodedString()),
            ("S", s.base64EncodedString()),
            ("R", r.base64EncodedString())
        ])
    }

    private static func anonymousUsername(deviceID: String) -> String {
        let bytes = Array(deviceID.utf8)
        let xored = Data(bytes.enumerated().map { $0.element ^ idXORKey[$0.offset % idXORKey.count] })
        let digest = Data(Insecure.MD5.hash(data: xored)).base64EncodedString()
        return Data("\(deviceID) \(digest)".utf8).base64EncodedString()
    }

    private static func signature(timestamp: String, nonce: String) -> String {
        Data(HMAC<SHA256>.authenticationCode(
            for: Data((timestamp + nonce).utf8),
            using: SymmetricKey(data: signKey)
        )).base64EncodedString()
    }

    fileprivate static func formEncoded(_ fields: [(String, String)]) throws -> Data {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "*-._"))
        let text = try fields.map { key, value in
            guard let key = key.addingPercentEncoding(withAllowedCharacters: allowed),
                  let value = value.addingPercentEncoding(withAllowedCharacters: allowed)
            else { throw EAPIError.invalidPayload }
            return "\(key)=\(value)"
        }.joined(separator: "&")
        return Data(text.utf8)
    }

    fileprivate static func encodedCookie(_ fields: [(String, String)]) throws -> String {
        String(decoding: try formEncoded(fields), as: UTF8.self).replacingOccurrences(of: "&", with: "; ")
    }

    private static func randomData(count: Int) throws -> Data {
        var data = Data(count: count)
        let status = data.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!)
        }
        guard status == errSecSuccess else { throw EAPIError.invalidPayload }
        return data
    }

    private static func randomDigits(count: Int) throws -> String {
        try randomData(count: count).map { String($0 % 10) }.joined()
    }

    private static func randomLowercase(count: Int) throws -> String {
        String(decoding: try randomData(count: count).map { 97 + ($0 % 26) }, as: UTF8.self)
    }

    private static func gunzip(_ data: Data) throws -> Data {
        var stream = z_stream()
        guard inflateInit2_(&stream, 15 + 32, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw EAPIError.invalidResponse
        }
        defer { inflateEnd(&stream) }
        return try data.withUnsafeBytes { input in
            stream.next_in = UnsafeMutablePointer<Bytef>(mutating: input.bindMemory(to: Bytef.self).baseAddress)
            stream.avail_in = uInt(input.count)
            var output = Data()
            var status: Int32 = Z_OK
            repeat {
                var buffer = [UInt8](repeating: 0, count: 16_384)
                status = buffer.withUnsafeMutableBytes { bytes in
                    stream.next_out = bytes.bindMemory(to: Bytef.self).baseAddress
                    stream.avail_out = uInt(bytes.count)
                    return inflate(&stream, Z_NO_FLUSH)
                }
                guard status == Z_OK || status == Z_STREAM_END else { throw EAPIError.invalidResponse }
                output.append(buffer, count: buffer.count - Int(stream.avail_out))
            } while status != Z_STREAM_END
            return output
        }
    }
}

enum NCBLPlaybackEvent: Sendable {
    case start
    case play(seconds: Int)

    fileprivate var action: String {
        switch self {
        case .start: "_plv"
        case .play: "_pld"
        }
    }
}

struct NCBLPlaybackUpload: Sendable {
    let request: URLRequest
    let fileName: String
}

enum NCBLPlaybackReport {
    private static let rsaPublicKeyDER = Data([
        0x30, 0x28, 0x02, 0x21, 0x00,
        0xfd, 0x90, 0xbd, 0x46, 0x6f, 0xf9, 0xbc, 0x8a,
        0x3f, 0xec, 0x2f, 0xbc, 0xf2, 0x63, 0xb9, 0x0d,
        0x5c, 0x56, 0x48, 0x79, 0xfa, 0x5d, 0x7a, 0xab,
        0x89, 0xb3, 0x1c, 0x1d, 0x5c, 0xb4, 0x13, 0x9d,
        0x02, 0x03, 0x01, 0x00, 0x01
    ])
    private static let frameSize = 0x8000
    private static let windowsSystemVersion = "Microsoft-Windows-10-Professional-build-19045-64bit"

    static func upload(
        cookie: String,
        deviceID: String,
        clientID: String,
        songID: Int64,
        sourceID: Int64,
        totalSeconds: Int,
        event: NCBLPlaybackEvent,
        now: Date = Date()
    ) throws -> NCBLPlaybackUpload {
        guard songID > 0, sourceID > 0, totalSeconds > 0 else { throw EAPIError.invalidPayload }
        if case let .play(seconds) = event, seconds <= 0 { throw EAPIError.invalidPayload }

        let context = try Context(
            cookie: cookie,
            deviceID: deviceID,
            clientID: clientID,
            now: now
        )
        let record = try plaintextRecord(
            context: context,
            songID: songID,
            sourceID: sourceID,
            totalSeconds: totalSeconds,
            event: event,
            timestampSeconds: Int64(now.timeIntervalSince1970),
            eventMilliseconds: Int64(now.timeIntervalSince1970 * 1_000)
        )
        let payload = try encryptedPayload(meta: context.metaJSON, body: record)
        let boundary = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let fileName = "op_\(Int.random(in: 10_000...99_999))_0_\(UInt32.random(in: 1...UInt32.max))"
        let prefix = "--\(boundary)\r\n"
            + "Content-Disposition: form-data; name=\"file\"; filename=\"\(fileName)\"\r\n"
            + "Content-Type: multipart/form-data\r\n\r\n"
        var body = Data(prefix.utf8)
        body.append(payload)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))

        var request = URLRequest(
            url: URL(string: "https://clientlog3.music.163.com/api/clientlog/encrypt/upload?multiupload=true")!,
            timeoutInterval: 15
        )
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("https://music.163.com/di", forHTTPHeaderField: "Referer")
        request.setValue(
            "Mozilla/5.0 (Windows NT 10.0; WOW64) AppleWebKit/537.36 (KHTML, like Gecko) Safari/537.36 Chrome/91.0.4472.164 NeteaseMusicDesktop/\(context.version)",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("gzip,deflate", forHTTPHeaderField: "Accept-Encoding")
        request.setValue("zh-CN,zh;q=0.8", forHTTPHeaderField: "Accept-Language")
        request.setValue(context.cookieHeader, forHTTPHeaderField: "Cookie")
        return NCBLPlaybackUpload(request: request, fileName: fileName)
    }

    static func validateResponse(_ data: Data, fileName: String) throws {
        let root = try decodedJSONObject(data)
        guard root.int("code") == 200,
              (root.object("data")["successfiles"] as? [String])?.contains(fileName) == true
        else {
            let message = root.string("message")
            throw EAPIError.service(
                code: root.int("code"),
                message: message.isEmpty ? "播放记录未被服务器接收" : message
            )
        }
    }

    static func plaintextRecord(
        cookie: String,
        songID: Int64,
        sourceID: Int64,
        totalSeconds: Int,
        event: NCBLPlaybackEvent,
        timestampSeconds: Int64,
        eventMilliseconds: Int64
    ) throws -> Data {
        try plaintextRecord(
            context: Context(cookie: cookie, now: Date(timeIntervalSince1970: TimeInterval(timestampSeconds))),
            songID: songID,
            sourceID: sourceID,
            totalSeconds: totalSeconds,
            event: event,
            timestampSeconds: timestampSeconds,
            eventMilliseconds: eventMilliseconds
        )
    }

    static func encryptedPayload(
        meta: Data,
        body: Data,
        keyA suppliedKey: Data? = nil,
        uuid suppliedUUID: Data? = nil,
        baseSequence suppliedBaseSequence: UInt32? = nil
    ) throws -> Data {
        var keyA = try suppliedKey ?? randomData(count: 32)
        guard keyA.count == 32 else { throw EAPIError.invalidPayload }
        if keyA[0] >= 0xa3 { keyA[0] = 0xa2 }
        let keyB = try rsaWrap(keyA)

        var uuid = try suppliedUUID ?? randomData(count: 16)
        guard uuid.count == 16 else { throw EAPIError.invalidPayload }
        if suppliedUUID == nil {
            uuid[6] = (uuid[6] & 0x0f) | 0x40
            uuid[8] = (uuid[8] & 0x3f) | 0x80
        }
        let nonce = Data(uuid.prefix(12))
        let counter = readUInt32LE(uuid, offset: 12) >> 2
        let baseSequence = try suppliedBaseSequence ?? UInt32(randomUInt16())
        let metaCipher = try chacha20(key: keyB, counter: counter, nonce: nonce, input: meta)
        guard metaCipher.count <= Int(UInt16.max),
              74 + metaCipher.count <= Int(UInt16.max)
        else { throw EAPIError.invalidPayload }

        var metaBlock = Data()
        metaBlock.appendLittleEndian(UInt16(0x4343))
        metaBlock.appendLittleEndian(UInt16(metaCipher.count))
        metaBlock.append(metaCipher)

        let compressed = zstandardFrame(body)
        var trailing = Data()
        var sequence = baseSequence
        var offset = 0
        repeat {
            let end = min(offset + frameSize, compressed.count)
            let frame = Data(compressed[offset..<end])
            let cipher = try chacha20(key: keyA, counter: counter, nonce: nonce, input: frame)
            guard cipher.count <= Int(UInt16.max) else { throw EAPIError.invalidPayload }
            trailing.appendLittleEndian(UInt16(cipher.count))
            trailing.appendLittleEndian(sequence)
            trailing.append(cipher)
            sequence &+= 1
            offset = end
        } while offset < compressed.count
        guard trailing.count <= Int(UInt32.max) else { throw EAPIError.invalidPayload }

        var header = Data("NCBL".utf8)
        header.appendLittleEndian(UInt32(3))
        header.appendLittleEndian(UInt16(70 + metaBlock.count))
        header.append(uuid)
        header.append(keyB)
        header.appendLittleEndian(baseSequence)
        header.appendLittleEndian(sequence &- 1)
        header.appendLittleEndian(UInt32(trailing.count))
        guard header.count == 70 else { throw EAPIError.invalidPayload }
        return header + metaBlock + trailing
    }

    static func zstandardFrame(_ input: Data) -> Data {
        // ponytail: playback records are tiny; raw Zstandard blocks avoid shipping a codec.
        var output = Data([0x28, 0xb5, 0x2f, 0xfd])
        let contentSize = UInt64(input.count)
        switch contentSize {
        case ..<256:
            output.append(0x20)
            output.append(UInt8(contentSize))
        case ..<65_792:
            output.append(0x60)
            output.appendLittleEndian(UInt16(contentSize - 256))
        case ...UInt64(UInt32.max):
            output.append(0xa0)
            output.appendLittleEndian(UInt32(contentSize))
        default:
            output.append(0xe0)
            output.appendLittleEndian(contentSize)
        }

        let maximumBlockSize = 128 * 1_024
        var offset = 0
        repeat {
            let count = min(maximumBlockSize, input.count - offset)
            let isLast = offset + count == input.count
            let blockHeader = (UInt32(count) << 3) | (isLast ? 1 : 0)
            output.append(UInt8(truncatingIfNeeded: blockHeader))
            output.append(UInt8(truncatingIfNeeded: blockHeader >> 8))
            output.append(UInt8(truncatingIfNeeded: blockHeader >> 16))
            if count > 0 {
                let start = input.index(input.startIndex, offsetBy: offset)
                output.append(contentsOf: input[start..<input.index(start, offsetBy: count)])
            }
            offset += count
        } while offset < input.count
        return output
    }

    private static func plaintextRecord(
        context: Context,
        songID: Int64,
        sourceID: Int64,
        totalSeconds: Int,
        event: NCBLPlaybackEvent,
        timestampSeconds: Int64,
        eventMilliseconds: Int64
    ) throws -> Data {
        let source = String(sourceID)
        let common: [String: Any] = [
            "mode": "circulation", "download": 0, "alg": "", "status": "front",
            "id": String(songID), "type": "song", "is_listentogether": 0,
            "source": "list", "is_heart": 0, "resource_ratio": "",
            "resource_time": totalSeconds, "bitrate": 320, "bitrate_level": "exhigh",
            "vipType": context.vipType, "file": 4, "rightSource": 0,
            "sourceId": source, "sourcetype": "track", "libra_abt": "",
            "channel": context.channel, "curStartChannel": ""
        ]
        var json = common
        switch event {
        case .start:
            json["musiceffect_id"] = ""
            json["app_mode"] = 2
            json["fee"] = 1
            json["_addrefer"] = "[F:63][\(eventMilliseconds)#933#\(context.version)#\(context.versionCode)#c9156c3][e][2][23][cell_pc_songlist_song:2|page_pc_songlist_songflow|page_mine_like_music][\(songID):song:x:x|:::|\(source):list::]"
            json["_multirefers"] = [
                "[F:26][s][18][_ai]", "[F:26][s][12][_ai]",
                "[F:63][\(eventMilliseconds)#933#\(context.version)#\(context.versionCode)#c9156c3][e][2][8][cell_pc_main_tab_entrance:6|page_pc_main_tab][我喜欢的音乐:spm::|:::]",
                "[F:26][s][5][_ai]", "[F:26][s][0][_ai]"
            ]
        case let .play(seconds):
            let played = min(seconds, totalSeconds)
            json["time"] = played
            json["realtime"] = played
            json["musiceffect_id"] = "1001"
            json["app_mode"] = 1
            json["lyriceffect"] = "default"
            json["displayMode"] = "classic"
            json["fee"] = 8
            json["end"] = "interrupt"
            json["_addrefer"] = "[F:63][\(eventMilliseconds)#616#\(context.version)#\(context.versionCode)#c9156c3][e][2][92][btn_pc_cover_play|cell_pc_songlist_song:6|page_pc_songlist_songflow|page_mine_like_music][:::|\(songID):song:x:x|:::|\(source):list::]"
            json["_multirefers"] = [
                "[F:26][s][87][_ai]", "[F:26][s][81][_ai]", "[F:26][s][75][_ai]",
                "[F:26][s][69][_ai]", "[F:26][s][63][_ai]"
            ]
        }
        let jsonData = try compactJSON(json)
        guard let jsonString = String(data: jsonData, encoding: .utf8) else {
            throw EAPIError.invalidPayload
        }
        return Data("\(timestampSeconds)\u{1}\(event.action)\u{1}\(jsonString)".utf8)
    }

    private static func rsaWrap(_ keyA: Data) throws -> Data {
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass: kSecAttrKeyClassPublic,
            kSecAttrKeySizeInBits: 256
        ]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(
            rsaPublicKeyDER as CFData,
            attributes as CFDictionary,
            &error
        ), SecKeyIsAlgorithmSupported(key, .encrypt, .rsaEncryptionRaw),
              let wrapped = SecKeyCreateEncryptedData(
                  key,
                  .rsaEncryptionRaw,
                  keyA as CFData,
                  &error
              ) as Data?, wrapped.count == 32
        else { throw EAPIError.invalidPayload }
        return wrapped
    }

    private static func chacha20(
        key: Data,
        counter: UInt32,
        nonce: Data,
        input: Data
    ) throws -> Data {
        guard key.count == 32, nonce.count == 12 else { throw EAPIError.invalidPayload }
        let key = [UInt8](key)
        let nonce = [UInt8](nonce)
        let input = [UInt8](input)
        var output = input
        for offset in stride(from: 0, to: input.count, by: 64) {
            var state: [UInt32] = [0x61707865, 0x3320646e, 0x79622d32, 0x6b206574]
            for index in 0..<8 { state.append(readUInt32LE(key, offset: index * 4)) }
            state.append(counter &+ UInt32(offset / 64))
            for index in 0..<3 { state.append(readUInt32LE(nonce, offset: index * 4)) }
            var work = state
            for _ in 0..<10 {
                quarterRound(&work, 0, 4, 8, 12)
                quarterRound(&work, 1, 5, 9, 13)
                quarterRound(&work, 2, 6, 10, 14)
                quarterRound(&work, 3, 7, 11, 15)
                quarterRound(&work, 0, 5, 10, 15)
                quarterRound(&work, 1, 6, 11, 12)
                quarterRound(&work, 2, 7, 8, 13)
                quarterRound(&work, 3, 4, 9, 14)
            }
            var stream = [UInt8]()
            stream.reserveCapacity(64)
            for index in 0..<16 {
                let word = work[index] &+ state[index]
                stream += [
                    UInt8(truncatingIfNeeded: word), UInt8(truncatingIfNeeded: word >> 8),
                    UInt8(truncatingIfNeeded: word >> 16), UInt8(truncatingIfNeeded: word >> 24)
                ]
            }
            for index in offset..<min(offset + 64, input.count) {
                output[index] ^= stream[index - offset]
            }
        }
        return Data(output)
    }

    private static func quarterRound(
        _ state: inout [UInt32],
        _ a: Int,
        _ b: Int,
        _ c: Int,
        _ d: Int
    ) {
        state[a] &+= state[b]
        state[d] = (state[d] ^ state[a]).rotatedLeft(16)
        state[c] &+= state[d]
        state[b] = (state[b] ^ state[c]).rotatedLeft(12)
        state[a] &+= state[b]
        state[d] = (state[d] ^ state[a]).rotatedLeft(8)
        state[c] &+= state[d]
        state[b] = (state[b] ^ state[c]).rotatedLeft(7)
    }

    private static func randomData(count: Int) throws -> Data {
        var data = Data(count: count)
        let status = data.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!)
        }
        guard status == errSecSuccess else { throw EAPIError.invalidPayload }
        return data
    }

    private static func randomUInt16() throws -> UInt16 {
        readUInt16LE(try randomData(count: 2), offset: 0)
    }

    private static func randomHex(bytes: Int) throws -> String {
        try randomData(count: bytes).map { String(format: "%02x", $0) }.joined()
    }

    private static func readUInt16LE(_ data: Data, offset: Int) -> UInt16 {
        let bytes = [UInt8](data)
        return UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
    }

    private static func readUInt32LE(_ data: Data, offset: Int) -> UInt32 {
        readUInt32LE([UInt8](data), offset: offset)
    }

    private static func readUInt32LE(_ bytes: [UInt8], offset: Int) -> UInt32 {
        UInt32(bytes[offset])
            | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16)
            | (UInt32(bytes[offset + 3]) << 24)
    }

    private struct Context {
        let version: String
        let versionCode: String
        let channel: String
        let vipType: String
        let metaJSON: Data
        let cookieHeader: String

        init(
            cookie: String,
            deviceID suppliedDeviceID: String = "",
            clientID suppliedClientID: String = "",
            now: Date
        ) throws {
            func value(_ name: String, fallback: String = "") -> String {
                let result = NeteaseCookieHeader.value(named: name, in: cookie)
                return result.isEmpty ? fallback : result
            }

            let token = value("MUSIC_U")
            guard !token.isEmpty else {
                throw EAPIError.service(code: 401, message: "播放记录上报缺少登录凭据")
            }
            let version = value("appver", fallback: "3.1.35")
            let versionCode = value("versioncode", fallback: "205293")
            let nsm = value("WEVNSM", fallback: "1.0.0")
            let cid = try value("WNMCID").isEmpty
                ? (suppliedClientID.isEmpty
                    ? "\(NCBLPlaybackReport.randomHex(bytes: 3)).\(Int64(now.timeIntervalSince1970 * 1_000)).01.0"
                    : suppliedClientID)
                : value("WNMCID")
            let channel = value("channel", fallback: "netease")
            let sessionID = value("JSESSIONID-WYYY")
            let nmtid = value("NMTID")
            let csrf = value("__csrf")
            let nnid = value("_ntes_nnid", fallback: ",")
            let nuid = value("_ntes_nuid")
            let clientSign = value("clientSign")
            let deviceID = value(
                "deviceId",
                fallback: value("sDeviceId", fallback: suppliedDeviceID)
            )
            let model = value("mode", fallback: value("mobilename"))
            let systemVersion = value("osver", fallback: NCBLPlaybackReport.windowsSystemVersion)
            let appVersion = "\(version).\(versionCode)"
            let fields = [
                ("JSESSIONID-WYYY", sessionID), ("MUSIC_U", token), ("NMTID", nmtid),
                ("WEVNSM", nsm), ("WNMCID", cid), ("__csrf", csrf),
                ("__remember_me", "true"), ("_iuqxldmzr_", "33"), ("_ntes_nnid", nnid),
                ("_ntes_nuid", nuid), ("appver", appVersion), ("channel", channel),
                ("clientSign", clientSign), ("deviceId", deviceID), ("mode", model),
                ("ntes_kaola_ad", "1"), ("os", "pc"), ("osver", systemVersion)
            ]
            self.version = version
            self.versionCode = versionCode
            self.channel = channel
            vipType = value("vipType")
            cookieHeader = fields.map { "\($0.0)=\($0.1)" }.joined(separator: "; ")
            metaJSON = try compactJSON(Dictionary(uniqueKeysWithValues: fields.filter { $0.0 != "__remember_me" }))
        }
    }
}

private extension UInt32 {
    func rotatedLeft(_ count: UInt32) -> UInt32 {
        (self << count) | (self >> (32 - count))
    }
}

private extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var value = value.littleEndian
        Swift.withUnsafeBytes(of: &value) { append(contentsOf: $0) }
    }
}

enum VIPRequesterCredential: Equatable, Sendable {
    case independentMusicU
    case storedCookie
}

struct EAPITransport: Sendable {
    private let session: URLSession
    private let authenticationSession: URLSession
    private let cookieOverride: String?
    private let musicUOverride: String?
    let credentialSnapshot: CredentialSnapshot
    private let weapiSecretKeyOverride: String?
    private let responseCache: EAPIResponseCache
    private let playbackClientID: String
    private let beforeSendingRequest: (@Sendable () async -> Void)?

    init(
        session: URLSession? = nil,
        cookie: String? = nil,
        musicU: String? = nil,
        credentialSnapshot: CredentialSnapshot? = nil,
        loadStoredCredentials: (@Sendable () -> SessionCredentials?)? = nil,
        weapiSecretKey: String? = nil,
        responseCache: EAPIResponseCache = EAPIResponseCache(),
        beforeSendingRequest: (@Sendable () async -> Void)? = nil
    ) {
        if let session {
            self.session = session
            authenticationSession = session
        } else {
            let configuration = URLSessionConfiguration.default
            configuration.httpMaximumConnectionsPerHost = 8
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.timeoutIntervalForRequest = 15
            configuration.timeoutIntervalForResource = 60
            self.session = URLSession(configuration: configuration)

            let authenticationConfiguration = URLSessionConfiguration.ephemeral
            authenticationConfiguration.requestCachePolicy = .reloadIgnoringLocalCacheData
            authenticationConfiguration.timeoutIntervalForRequest = 15
            authenticationConfiguration.timeoutIntervalForResource = 30
            authenticationSession = URLSession(configuration: authenticationConfiguration)
        }
        cookieOverride = cookie
        musicUOverride = musicU
        if let credentialSnapshot {
            self.credentialSnapshot = credentialSnapshot
        } else if cookie != nil || musicU != nil {
            let cookie = cookie ?? ""
            let musicU = musicU ?? ""
            self.credentialSnapshot = CredentialSnapshot(
                (try? SessionCredentials(
                    cookie: cookie,
                    musicU: musicU,
                    deviceID: NeteaseCookieHeader.value(named: "deviceId", in: cookie)
                )).map(CredentialSnapshotState.authenticated)
                    ?? .guest
            )
        } else if let credentials = loadStoredCredentials?() {
            self.credentialSnapshot = CredentialSnapshot(.authenticated(credentials))
        } else {
            self.credentialSnapshot = CredentialSnapshot(.guest)
        }
        weapiSecretKeyOverride = weapiSecretKey
        self.responseCache = responseCache
        self.beforeSendingRequest = beforeSendingRequest
        playbackClientID = "\(UUID().uuidString.prefix(6).lowercased()).\(Int64(Date().timeIntervalSince1970 * 1_000)).01.0"
    }

    func registerAnonymous() async throws -> NeteaseAuthenticationContext {
        let flow = authenticationFlow()
        defer { flow.session.finishTasksAndInvalidate() }
        let deviceID = try XEAPICodec.generateDeviceID()
        let keyRequest = try XEAPICodec.publicKeyRequest(deviceID: deviceID)
        let (keyData, keyResponse) = try await flow.session.data(for: keyRequest.request)
        guard let keyHTTP = keyResponse as? HTTPURLResponse,
              (200..<300).contains(keyHTTP.statusCode)
        else { throw EAPIError.invalidResponse }
        let publicKey = try XEAPICodec.decodePublicKey(keyData, nonce: keyRequest.nonce)

        let request = try XEAPICodec.anonymousRequest(deviceID: deviceID, publicKey: publicKey)
        let (responseData, response) = try await flow.session.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode)
        else { throw EAPIError.invalidResponse }
        let decodedResponse = try EAPICodec.decodedResponse(XEAPICodec.decodeResponse(responseData))
        guard let responseObject = decodedResponse.object as? [String: Any] else {
            throw EAPIError.invalidResponse
        }
        _ = try decodedJSONObject(responseObject)
        let headers = http.allHeaderFields.reduce(into: [String: String]()) { result, field in
            result[String(describing: field.key)] = String(describing: field.value)
        }
        let cookie = NeteaseCookieHeader.merging(
            "",
            with: (flow.cookieStorage?.cookies(for: request.url!) ?? [])
                + HTTPCookie.cookies(withResponseHeaderFields: headers, for: request.url!)
        )
        guard !NeteaseCookieHeader.value(named: "MUSIC_A", in: cookie).isEmpty else {
            throw EAPIError.missingData("MUSIC_A")
        }
        return NeteaseAuthenticationContext(cookie: cookie, deviceID: deviceID)
    }

    func requestAuthentication(
        _ endpoint: EAPIEndpoint,
        payload: [String: Any],
        context: NeteaseAuthenticationContext,
        userAgent: String? = nil
    ) async throws -> EAPIHTTPResponse {
        let flow = authenticationFlow()
        defer { flow.session.finishTasksAndInvalidate() }
        let headerFields = Self.eapiClientHeaderFields(cookie: context.cookie, deviceID: context.deviceID)
        let isMacOS = headerFields.first { $0.0 == "os" }?.1.lowercased() == "osx"
        var json = payload
        json["e_r"] = false
        json["header"] = Dictionary(uniqueKeysWithValues: headerFields)
        let body = try EAPICodec.requestBody(path: endpoint.logicalPath, json: compactJSON(json))
        return try await performHTTPRequest(
            endpoint,
            body: body,
            cookie: context.cookie,
            musicU: "",
            vip: false,
            macOSClient: isMacOS,
            iPhoneClient: false,
            retryable: false,
            session: flow.session,
            cookieStorage: flow.cookieStorage,
            cookieHeaderOverride: try XEAPICodec.encodedCookie(headerFields),
            userAgentOverride: userAgent,
            validatesBusinessResponse: false
        )
    }

    func requestHTTP(
        _ endpoint: EAPIEndpoint,
        json: Data,
        cookie: String? = nil,
        musicU: String? = nil
    ) async throws -> EAPIHTTPResponse {
        let stored = try resolvedCredentials()
        return try await performHTTPRequest(
            endpoint,
            body: EAPICodec.requestBody(path: endpoint.logicalPath, json: json),
            cookie: cookie ?? stored.cookie,
            musicU: musicU ?? stored.musicU,
            vip: false,
            macOSClient: false,
            iPhoneClient: false,
            retryable: false,
            session: session,
            cookieStorage: nil,
            cookieHeaderOverride: nil,
            userAgentOverride: nil
        )
    }

    func requestQuery(
        path: String,
        fields: [(String, String)],
        host: String,
        expectedCredentialRevision: UInt64
    ) async throws -> Data {
        try await requestQueryResponse(
            path: path,
            fields: fields,
            host: host,
            expectedCredentialRevision: expectedCredentialRevision
        ).data
    }

    func requestQueryJSONObject(
        path: String,
        fields: [(String, String)],
        host: String,
        expectedCredentialRevision: UInt64
    ) async throws -> [String: Any] {
        try await requestQueryResponse(
            path: path,
            fields: fields,
            host: host,
            expectedCredentialRevision: expectedCredentialRevision
        ).object
    }

    private func requestQueryResponse(
        path: String,
        fields: [(String, String)],
        host: String,
        expectedCredentialRevision: UInt64
    ) async throws -> EAPIHTTPResponse {
        guard path.hasPrefix("/"), !path.hasPrefix("//") else { throw EAPIError.invalidPayload }
        var components = URLComponents()
        components.queryItems = fields.map { URLQueryItem(name: $0.0, value: $0.1) }
        guard let query = components.percentEncodedQuery else { throw EAPIError.invalidPayload }
        let snapshot = try resolvedCredentialSnapshot()
        guard snapshot.value.revision == expectedCredentialRevision else {
            throw CredentialRevisionMismatch(
                expected: expectedCredentialRevision,
                actual: snapshot.value.revision
            )
        }
        try validateExpectedCredentialRevision(expectedCredentialRevision)
        return try await performHTTPRequest(
            EAPIEndpoint("\(path)?\(query)", signing: path, host: host, responseEncoding: .json),
            body: Data(),
            cookie: snapshot.credentials.cookie,
            musicU: "",
            credentialRevision: snapshot.value.revision,
            expectedCredentialRevision: expectedCredentialRevision,
            vip: false,
            macOSClient: true,
            iPhoneClient: false,
            retryable: false,
            session: session,
            cookieStorage: nil,
            cookieHeaderOverride: nil,
            userAgentOverride: "",
            method: "GET"
        )
    }

    func request(
        _ endpoint: EAPIEndpoint,
        json: Data,
        vip: Bool = false,
        useStoredCookieForVIP: Bool = false,
        cache: EAPIReadCache? = nil,
        refreshCache: Bool = false,
        expectedCredentialRevision: UInt64? = nil,
        invalidatesGroups: Set<EAPIReadCache> = [],
        invalidatesAccountCache: Bool = false,
        macOSClient: Bool = false,
        iPhoneClient: Bool = false,
        includesClientHeader: Bool = false,
        retryable: Bool = true,
        additionalHeaders: [String: String] = [:]
    ) async throws -> Data {
        try await requestParsed(
            endpoint,
            json: json,
            vip: vip,
            useStoredCookieForVIP: useStoredCookieForVIP,
            cache: cache,
            refreshCache: refreshCache,
            expectedCredentialRevision: expectedCredentialRevision,
            invalidatesGroups: invalidatesGroups,
            invalidatesAccountCache: invalidatesAccountCache,
            macOSClient: macOSClient,
            iPhoneClient: iPhoneClient,
            includesClientHeader: includesClientHeader,
            retryable: retryable,
            additionalHeaders: additionalHeaders
        ).data
    }

    func requestJSONObject(
        _ endpoint: EAPIEndpoint,
        json: Data,
        vip: Bool = false,
        useStoredCookieForVIP: Bool = false,
        cache: EAPIReadCache? = nil,
        refreshCache: Bool = false,
        expectedCredentialRevision: UInt64? = nil,
        invalidatesGroups: Set<EAPIReadCache> = [],
        invalidatesAccountCache: Bool = false,
        macOSClient: Bool = false,
        iPhoneClient: Bool = false,
        includesClientHeader: Bool = false,
        retryable: Bool = true,
        additionalHeaders: [String: String] = [:],
        allowsDomainBusinessCodes: Bool = false
    ) async throws -> [String: Any] {
        let response = try await requestParsed(
            endpoint,
            json: json,
            vip: vip,
            useStoredCookieForVIP: useStoredCookieForVIP,
            cache: cache,
            refreshCache: refreshCache,
            expectedCredentialRevision: expectedCredentialRevision,
            invalidatesGroups: invalidatesGroups,
            invalidatesAccountCache: invalidatesAccountCache,
            macOSClient: macOSClient,
            iPhoneClient: iPhoneClient,
            includesClientHeader: includesClientHeader,
            retryable: retryable,
            additionalHeaders: additionalHeaders,
            allowsDomainBusinessCodes: allowsDomainBusinessCodes
        )
        guard let object = response.object else { throw EAPIError.invalidResponse }
        return object
    }

    private func requestParsed(
        _ endpoint: EAPIEndpoint,
        json: Data,
        vip: Bool = false,
        useStoredCookieForVIP: Bool = false,
        cache: EAPIReadCache? = nil,
        refreshCache: Bool = false,
        expectedCredentialRevision: UInt64? = nil,
        invalidatesGroups: Set<EAPIReadCache> = [],
        invalidatesAccountCache: Bool = false,
        macOSClient: Bool = false,
        iPhoneClient: Bool = false,
        includesClientHeader: Bool = false,
        retryable: Bool = true,
        additionalHeaders: [String: String] = [:],
        allowsDomainBusinessCodes: Bool = false
    ) async throws -> EAPIParsedResponse {
        guard !refreshCache || cache != nil,
              cache == nil || invalidatesGroups.isEmpty
        else { throw EAPIError.invalidPayload }
        let snapshot = try resolvedCredentialSnapshot()
        try validateExpectedCredentialRevision(expectedCredentialRevision)
        let credentials = snapshot.credentials
        let cookie = credentials.cookie
        let musicU = vip && useStoredCookieForVIP ? "" : credentials.musicU
        let account = Self.accountFingerprint(
            cookie: cookie,
            musicU: credentials.musicU,
            revision: snapshot.value.revision
        )
        let policy: EAPIRequestCachePolicy = invalidatesAccountCache
            ? .invalidateAccount
            : cache?.policy ?? .none
        let loader: @Sendable () async throws -> EAPIParsedResponse = { [self] in
            try validateExpectedCredentialRevision(expectedCredentialRevision)
            let clientHeaderFields = includesClientHeader
                ? Self.eapiClientHeaderFields(
                    cookie: cookie,
                    deviceID: credentials.deviceID,
                    macOSClient: macOSClient
                )
                : nil
            let requestJSON = try clientHeaderFields.map {
                try Self.addingEAPIClientHeader(to: json, fields: $0)
            } ?? json
            let clientCookie = try clientHeaderFields.map(XEAPICodec.encodedCookie)
            let body = try EAPICodec.requestBody(path: endpoint.logicalPath, json: requestJSON)
            return try await performRequest(
                endpoint,
                body: body,
                cookie: cookie,
                musicU: musicU,
                credentialRevision: snapshot.value.revision,
                expectedCredentialRevision: expectedCredentialRevision ?? snapshot.value.revision,
                vip: vip,
                macOSClient: macOSClient,
                iPhoneClient: iPhoneClient,
                cookieHeaderOverride: clientCookie,
                retryable: retryable
                    && invalidatesGroups.isEmpty
                    && !invalidatesAccountCache,
                additionalHeaders: additionalHeaders
            )
        }

        let response: EAPIParsedResponse
        switch policy {
        case .none:
            response = try await loader()
            if response.businessError == nil, !invalidatesGroups.isEmpty {
                await responseCache.invalidate(account: account, groups: invalidatesGroups)
            }
        case let .read(ttl, staleIfError):
            let key = EAPIResponseCache.Key(
                account: account,
                request: Self.requestFingerprint(
                    endpoint: endpoint,
                    json: json,
                    vip: vip,
                    useStoredCookieForVIP: useStoredCookieForVIP,
                    macOSClient: macOSClient,
                    iPhoneClient: iPhoneClient,
                    includesClientHeader: includesClientHeader
                ),
                group: cache ?? .detail
            )
            response = try await responseCache.parsedValue(
                for: key,
                ttl: ttl,
                staleIfError: staleIfError,
                refresh: refreshCache,
                loader: loader
            )
        case .invalidateAccount:
            response = try await loader()
            if response.businessError == nil { await responseCache.invalidate(account: account) }
        }
        if !allowsDomainBusinessCodes, let error = response.businessError { throw error }
        return response
    }

    func invalidateAllCachedResponses() async {
        await responseCache.invalidateAll()
    }

    func invalidateCachedResponses(in groups: Set<EAPIReadCache>) async {
        guard !groups.isEmpty else { return }
        guard let snapshot = try? resolvedCredentialSnapshot() else { return }
        await responseCache.invalidate(
            account: Self.accountFingerprint(
                cookie: snapshot.credentials.cookie,
                musicU: snapshot.credentials.musicU,
                revision: snapshot.value.revision
            ),
            groups: groups
        )
    }

    func requestCommentLike(threadID: String, commentID: Int64, liked: Bool) async throws -> [String: Any] {
        try await requestCommentLike(
            threadID: threadID,
            commentID: commentID,
            liked: liked,
            expectedCredentialRevision: credentialSnapshot.load().revision
        )
    }

    func requestCommentLike(
        threadID: String,
        commentID: Int64,
        liked: Bool,
        expectedCredentialRevision: UInt64
    ) async throws -> [String: Any] {
        let action = liked ? "like" : "unlike"
        return try await requestWEAPIJSONObject(
            path: "/weapi/v1/comment/\(action)",
            payload: ["threadId": threadID, "commentId": String(commentID)],
            expectedCredentialRevision: expectedCredentialRevision,
            invalidatesGroups: [.comments],
            invalidatesAccountCache: false,
            retryable: false
        )
    }

    func requestFMTrash(songID: Int64, algorithm: String, playedSeconds: Int) async throws -> [String: Any] {
        try await requestFMTrash(
            songID: songID,
            algorithm: algorithm,
            playedSeconds: playedSeconds,
            expectedCredentialRevision: credentialSnapshot.load().revision
        )
    }

    func requestFMTrash(
        songID: Int64,
        algorithm: String,
        playedSeconds: Int,
        expectedCredentialRevision: UInt64
    ) async throws -> [String: Any] {
        guard songID > 0, playedSeconds > 0 else { throw EAPIError.invalidPayload }
        return try await requestWEAPIJSONObject(
            path: "/weapi/radio/trash/add",
            payload: [
                "songId": songID,
                "alg": algorithm.isEmpty ? "RT" : algorithm,
                "time": playedSeconds
            ],
            expectedCredentialRevision: expectedCredentialRevision,
            invalidatesGroups: [.listeningHistory],
            invalidatesAccountCache: false,
            retryable: false
        )
    }

    func requestRecentPlayback(
        path: String,
        limit: Int,
        refreshCache: Bool = false,
        expectedCredentialRevision: UInt64
    ) async throws -> [String: Any] {
        let paths = [
            "/api/play-record/song/list",
            "/api/play-record/album/list",
            "/api/play-record/playlist/list",
            "/api/play-record/newvideo/list",
            "/api/play-record/voice/list",
            "/api/play-record/djradio/list"
        ]
        guard paths.contains(path), (1...100).contains(limit) else { throw EAPIError.invalidPayload }
        return try await requestWEAPIJSONObject(
            path: path.replacingOccurrences(of: "/api/", with: "/weapi/"),
            payload: ["limit": limit],
            cache: .listeningHistory,
            refreshCache: refreshCache,
            expectedCredentialRevision: expectedCredentialRevision
        )
    }

    func requestCloudSongs(
        offset: Int,
        limit: Int,
        expectedCredentialRevision: UInt64
    ) async throws -> [String: Any] {
        guard offset >= 0, (1...100).contains(limit) else { throw EAPIError.invalidPayload }
        return try await requestWEAPIJSONObject(
            path: "/weapi/v1/cloud/get",
            payload: ["offset": offset, "limit": limit],
            cache: .library,
            expectedCredentialRevision: expectedCredentialRevision,
            invalidatesAccountCache: false
        )
    }

    func requestCloudSongDetails(
        ids: [Int64],
        expectedCredentialRevision: UInt64
    ) async throws -> [String: Any] {
        guard !ids.isEmpty, ids.count <= 50, ids.allSatisfy({ $0 > 0 }) else {
            throw EAPIError.invalidPayload
        }
        return try await requestWEAPIJSONObject(
            path: "/weapi/v1/cloud/get/byids",
            payload: ["songIds": ids],
            cache: .detail,
            expectedCredentialRevision: expectedCredentialRevision,
            invalidatesAccountCache: false
        )
    }

    func requestRecommendationHistory(
        date: String? = nil,
        refreshCache: Bool = false,
        expectedCredentialRevision: UInt64
    ) async throws -> [String: Any] {
        let path = date == nil
            ? "/weapi/discovery/recommend/songs/history/recent"
            : "/weapi/discovery/recommend/songs/history/detail"
        return try await requestWEAPIJSONObject(
            path: path,
            payload: date.map { ["date": $0] } ?? [:],
            cache: .library,
            refreshCache: refreshCache,
            expectedCredentialRevision: expectedCredentialRevision,
            invalidatesAccountCache: false
        )
    }

    func requestWEAPI(
        path: String,
        payload: [String: Any],
        cache: EAPIReadCache? = nil,
        refreshCache: Bool = false,
        expectedCredentialRevision: UInt64? = nil,
        invalidatesGroups: Set<EAPIReadCache> = [],
        invalidatesAccountCache: Bool = true,
        vip: Bool = false,
        useStoredCookieForVIP: Bool = false,
        retryable: Bool = true,
        additionalHeaders: [String: String] = [:],
        restrictsRedirects: Bool = false
    ) async throws -> Data {
        try await requestWEAPIParsed(
            path: path,
            payload: payload,
            cache: cache,
            refreshCache: refreshCache,
            expectedCredentialRevision: expectedCredentialRevision,
            invalidatesGroups: invalidatesGroups,
            invalidatesAccountCache: invalidatesAccountCache,
            vip: vip,
            useStoredCookieForVIP: useStoredCookieForVIP,
            retryable: retryable,
            additionalHeaders: additionalHeaders,
            restrictsRedirects: restrictsRedirects
        ).data
    }

    func requestWEAPIJSONObject(
        path: String,
        payload: [String: Any],
        cache: EAPIReadCache? = nil,
        refreshCache: Bool = false,
        expectedCredentialRevision: UInt64? = nil,
        invalidatesGroups: Set<EAPIReadCache> = [],
        invalidatesAccountCache: Bool = true,
        vip: Bool = false,
        useStoredCookieForVIP: Bool = false,
        retryable: Bool = true,
        additionalHeaders: [String: String] = [:],
        restrictsRedirects: Bool = false,
        allowsDomainBusinessCodes: Bool = false
    ) async throws -> [String: Any] {
        let response = try await requestWEAPIParsed(
            path: path,
            payload: payload,
            cache: cache,
            refreshCache: refreshCache,
            expectedCredentialRevision: expectedCredentialRevision,
            invalidatesGroups: invalidatesGroups,
            invalidatesAccountCache: invalidatesAccountCache,
            vip: vip,
            useStoredCookieForVIP: useStoredCookieForVIP,
            retryable: retryable,
            additionalHeaders: additionalHeaders,
            restrictsRedirects: restrictsRedirects,
            allowsDomainBusinessCodes: allowsDomainBusinessCodes
        )
        guard let object = response.object else { throw EAPIError.invalidResponse }
        return object
    }

    private func requestWEAPIParsed(
        path: String,
        payload: [String: Any],
        cache: EAPIReadCache? = nil,
        refreshCache: Bool = false,
        expectedCredentialRevision: UInt64? = nil,
        invalidatesGroups: Set<EAPIReadCache> = [],
        invalidatesAccountCache: Bool = true,
        vip: Bool = false,
        useStoredCookieForVIP: Bool = false,
        retryable: Bool = true,
        additionalHeaders: [String: String] = [:],
        restrictsRedirects: Bool = false,
        allowsDomainBusinessCodes: Bool = false
    ) async throws -> EAPIParsedResponse {
        guard !refreshCache || cache != nil,
              cache == nil || invalidatesGroups.isEmpty
        else { throw EAPIError.invalidPayload }
        let snapshot = try resolvedCredentialSnapshot()
        try validateExpectedCredentialRevision(expectedCredentialRevision)
        let cookie = snapshot.credentials.cookie
        let musicU = snapshot.credentials.musicU
        let requesterMusicU = useStoredCookieForVIP ? "" : musicU
        let rawJSON = try compactJSON(payload)
        let account = Self.accountFingerprint(
            cookie: cookie,
            musicU: musicU,
            revision: snapshot.value.revision
        )
        let loader: @Sendable () async throws -> EAPIParsedResponse = { [self] in
            try validateExpectedCredentialRevision(expectedCredentialRevision)
            let timestamp = Date().timeIntervalSince1970
            let requestCookie = vip ? EAPICookieHeader.value(
                cookie: cookie,
                musicU: requesterMusicU,
                vip: true,
                buildVersion: Int(timestamp),
                requestID: "\(Int(timestamp * 1_000))_\(String(format: "%04d", Int.random(in: 0..<10_000)))"
            ) : cookie
            guard var requestPayload = try JSONSerialization.jsonObject(with: rawJSON) as? [String: Any] else {
                throw EAPIError.invalidPayload
            }
            requestPayload["csrf_token"] = WEAPICodec.csrfToken(in: requestCookie)
            requestPayload["e_r"] = false
            let json = try compactJSON(requestPayload)
            let body = if let weapiSecretKeyOverride {
                try WEAPICodec.requestBody(json: json, secretKey: weapiSecretKeyOverride)
            } else {
                try WEAPICodec.requestBody(json: json)
            }
            var request = URLRequest(
                url: URL(string: "https://music.163.com\(path)")!,
                timeoutInterval: 15
            )
            request.httpMethod = "POST"
            request.httpBody = body
            request.setValue("application/x-www-form-urlencoded;charset=utf-8", forHTTPHeaderField: "Content-Type")
            request.setValue("https://music.163.com/", forHTTPHeaderField: "Referer")
            request.setValue(
                "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36",
                forHTTPHeaderField: "User-Agent"
            )
            if !requestCookie.isEmpty { request.setValue(requestCookie, forHTTPHeaderField: "Cookie") }
            for (name, value) in additionalHeaders { request.setValue(value, forHTTPHeaderField: name) }
            return try await performWEAPIRequest(
                request,
                musicU: requesterMusicU,
                credentialRevision: snapshot.value.revision,
                expectedCredentialRevision: expectedCredentialRevision ?? snapshot.value.revision,
                vip: vip,
                retryable: retryable
                    && (cache != nil || (!invalidatesAccountCache && invalidatesGroups.isEmpty)),
                restrictsRedirects: restrictsRedirects || !requestCookie.isEmpty || !additionalHeaders.isEmpty
            )
        }

        let response: EAPIParsedResponse
        if let cache, case let .read(ttl, staleIfError) = cache.policy {
            let key = EAPIResponseCache.Key(
                account: account,
                request: Self.requestFingerprint(
                    endpoint: EAPIEndpoint(path, signing: path, responseEncoding: .json),
                    json: rawJSON,
                    vip: vip,
                    useStoredCookieForVIP: useStoredCookieForVIP,
                    macOSClient: true,
                    iPhoneClient: false
                ),
                group: cache
            )
            response = try await responseCache.parsedValue(
                for: key,
                ttl: ttl,
                staleIfError: staleIfError,
                refresh: refreshCache,
                loader: loader
            )
        } else {
            response = try await loader()
            if response.businessError == nil {
                if invalidatesAccountCache {
                    await responseCache.invalidate(account: account)
                } else if !invalidatesGroups.isEmpty {
                    await responseCache.invalidate(account: account, groups: invalidatesGroups)
                }
            }
        }
        if !allowsDomainBusinessCodes, let error = response.businessError { throw error }
        return response
    }

    func requestRaw(
        _ request: URLRequest,
        restrictsRedirects: Bool = false,
        expectedCredentialRevision: UInt64? = nil,
        validateResponse: @Sendable (Data) throws -> Void = { _ in },
        invalidatesGroups: Set<EAPIReadCache> = []
    ) async throws -> Data {
        let snapshot = try resolvedCredentialSnapshot()
        let delegate = restrictsRedirects || SensitiveHeaderRedirectPolicy.requiresProtection(request)
            ? SensitiveHeaderRedirectDelegate(originalURL: request.url!)
            : nil
        if expectedCredentialRevision != nil { await beforeSendingRequest?() }
        try validateExpectedCredentialRevision(expectedCredentialRevision)
        let (data, response) = try await session.data(for: request, delegate: delegate)
        guard let http = response as? HTTPURLResponse else { throw EAPIError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw EAPIError.http(http.statusCode) }
        try validateResponse(data)
        if !invalidatesGroups.isEmpty {
            await responseCache.invalidate(
                account: Self.accountFingerprint(
                    cookie: snapshot.credentials.cookie,
                    musicU: snapshot.credentials.musicU,
                    revision: snapshot.value.revision
                ),
                groups: invalidatesGroups
            )
        }
        return data
    }

    private func performWEAPIRequest(
        _ request: URLRequest,
        musicU: String,
        credentialRevision: UInt64,
        expectedCredentialRevision: UInt64?,
        vip: Bool,
        retryable: Bool,
        restrictsRedirects: Bool = false
    ) async throws -> EAPIParsedResponse {
        let delegate = restrictsRedirects ? SensitiveHeaderRedirectDelegate(originalURL: request.url!) : nil
        var lastError: Error = EAPIError.invalidResponse
        let attemptCount = retryable ? 3 : 1
        for attempt in 0..<attemptCount {
            try Task.checkCancellation()
            if attempt > 0 {
                try await Task.sleep(for: .milliseconds(250 << (attempt - 1)))
            }
            do {
                if expectedCredentialRevision != nil { await beforeSendingRequest?() }
                try validateExpectedCredentialRevision(expectedCredentialRevision)
                let (responseData, response) = try await session.data(for: request, delegate: delegate)
                guard let http = response as? HTTPURLResponse else { throw EAPIError.invalidResponse }
                guard (200..<300).contains(http.statusCode) else {
                    if http.statusCode == 401 || http.statusCode == 403 {
                        reportCredentialIssue(
                            vip && !musicU.isEmpty ? .musicU : .cookie,
                            credentialRevision: credentialRevision
                        )
                    }
                    throw EAPIError.http(http.statusCode)
                }
                let decoded = try EAPICodec.decodedResponse(responseData)
                guard let object = decoded.object as? [String: Any] else {
                    throw EAPIError.invalidResponse
                }
                try validateBusinessResponse(
                    object,
                    vip: vip,
                    musicU: musicU,
                    credentialRevision: credentialRevision
                )
                return EAPIParsedResponse(data: decoded.data, object: object)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if let error = error as? URLError, error.code == .cancelled, Task.isCancelled {
                    throw CancellationError()
                }
                lastError = error
                guard attempt + 1 < attemptCount, Self.isTransient(error) else { throw error }
            }
        }
        throw lastError
    }

    func credentials() throws -> (cookie: String, musicU: String) {
        let credentials = try resolvedCredentials()
        return (credentials.cookie, credentials.musicU)
    }

    func playbackCredentials(
        expectedCredentialRevision: UInt64
    ) throws -> (cookie: String, deviceID: String, clientID: String) {
        let snapshot = try resolvedCredentialSnapshot()
        guard snapshot.value.revision == expectedCredentialRevision else {
            throw CredentialRevisionMismatch(
                expected: expectedCredentialRevision,
                actual: snapshot.value.revision
            )
        }
        try validateExpectedCredentialRevision(expectedCredentialRevision)
        return (snapshot.credentials.cookie, snapshot.credentials.deviceID, playbackClientID)
    }

    func credentialSnapshotValue() -> CredentialSnapshotValue { credentialSnapshot.load() }

    func withVIPRequesterFallback<Value>(
        fallbackOn: (Error) -> Bool = { _ in false },
        operation: (VIPRequesterCredential) async throws -> Value
    ) async throws -> Value {
        let credentials = try credentials()
        guard !credentials.musicU.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return try await operation(.storedCookie)
        }

        do {
            return try await operation(.independentMusicU)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            let cookie = credentials.cookie.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cookie.isEmpty,
                  !NeteaseCookieHeader.isGuest(cookie),
                  SessionCredentialIssue.isAuthenticationFailure(error) || fallbackOn(error)
            else { throw error }
            return try await operation(.storedCookie)
        }
    }

    private func resolvedCredentialSnapshot() throws -> (
        value: CredentialSnapshotValue,
        credentials: (cookie: String, musicU: String, deviceID: String)
    ) {
        let value = credentialSnapshot.load()
        let stored: (cookie: String, musicU: String, deviceID: String)
        switch value.state {
        case .unavailable:
            guard cookieOverride != nil || musicUOverride != nil else {
                throw CredentialUnavailable()
            }
            stored = ("", "", "")
        case .guest:
            stored = ("", "", "")
        case let .authenticated(credentials):
            stored = (credentials.cookie, credentials.musicU, credentials.deviceID)
        }
        let cookie = cookieOverride ?? stored.cookie
        let overriddenDeviceID = cookieOverride.map {
            NeteaseCookieHeader.value(named: "deviceId", in: $0)
        } ?? ""
        return (
            value,
            (cookie, musicUOverride ?? stored.musicU, overriddenDeviceID.isEmpty ? stored.deviceID : overriddenDeviceID)
        )
    }

    private func resolvedCredentials() throws -> (cookie: String, musicU: String, deviceID: String) {
        try resolvedCredentialSnapshot().credentials
    }

    private func validateExpectedCredentialRevision(_ expected: UInt64?) throws {
        guard let expected else { return }
        let actual = credentialSnapshot.load().revision
        guard expected == actual else {
            throw CredentialRevisionMismatch(expected: expected, actual: actual)
        }
    }

    private func performRequest(
        _ endpoint: EAPIEndpoint,
        body: Data,
        cookie: String,
        musicU: String,
        credentialRevision: UInt64,
        expectedCredentialRevision: UInt64?,
        vip: Bool,
        macOSClient: Bool,
        iPhoneClient: Bool,
        cookieHeaderOverride: String?,
        retryable: Bool,
        additionalHeaders: [String: String] = [:],
        validatesBusinessResponse: Bool = true
    ) async throws -> EAPIParsedResponse {
        let response = try await performHTTPRequest(
            endpoint,
            body: body,
            cookie: cookie,
            musicU: musicU,
            credentialRevision: credentialRevision,
            expectedCredentialRevision: expectedCredentialRevision,
            vip: vip,
            macOSClient: macOSClient,
            iPhoneClient: iPhoneClient,
            retryable: retryable,
            session: session,
            cookieStorage: nil,
            cookieHeaderOverride: cookieHeaderOverride,
            userAgentOverride: nil,
            additionalHeaders: additionalHeaders,
            validatesBusinessResponse: validatesBusinessResponse,
            allowsDomainBusinessCodes: true
        )
        return EAPIParsedResponse(data: response.data, object: response.object)
    }

    private func performHTTPRequest(
        _ endpoint: EAPIEndpoint,
        body: Data,
        cookie: String,
        musicU: String,
        credentialRevision: UInt64 = 0,
        expectedCredentialRevision: UInt64? = nil,
        vip: Bool,
        macOSClient: Bool,
        iPhoneClient: Bool,
        retryable: Bool,
        session: URLSession,
        cookieStorage: HTTPCookieStorage?,
        cookieHeaderOverride: String?,
        userAgentOverride: String?,
        additionalHeaders: [String: String] = [:],
        method: String = "POST",
        validatesBusinessResponse: Bool = true,
        allowsDomainBusinessCodes: Bool = false
    ) async throws -> EAPIHTTPResponse {
        var lastError: Error = EAPIError.invalidResponse
        let attemptCount = retryable ? 3 : 1
        var retryAfter: TimeInterval?

        for attempt in 0..<attemptCount {
            try Task.checkCancellation()
            if attempt > 0 {
                let backoff = TimeInterval(250 << (attempt - 1)) / 1_000
                let delay = max(backoff, retryAfter ?? 0) + Double.random(in: 0...0.25)
                retryAfter = nil
                try await Task.sleep(for: .seconds(delay))
            }

            var request = URLRequest(url: endpoint.physicalURL, timeoutInterval: 15)
            request.httpMethod = method
            if method == "POST" {
                request.httpBody = body
                request.setValue(
                    "application/x-www-form-urlencoded;charset=utf-8",
                    forHTTPHeaderField: "Content-Type"
                )
            }
            request.setValue(
                userAgentOverride ?? (macOSClient
                    ? "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"
                    : "NeteaseMusic 9.0.90/5038 (iPhone; iOS 16.2; zh_CN)"),
                forHTTPHeaderField: "User-Agent"
            )
            request.setValue("zh-CN,zh;q=0.9", forHTTPHeaderField: "Accept-Language")
            let timestamp = Date().timeIntervalSince1970
            let sessionCookie = cookieHeaderOverride ?? EAPICookieHeader.value(
                    cookie: cookie,
                    musicU: musicU,
                    vip: vip,
                    buildVersion: Int(timestamp),
                    requestID: "\(Int(timestamp * 1_000))_\(String(format: "%04d", Int.random(in: 0..<10_000)))",
                    macOSClient: macOSClient,
                    iPhoneClient: iPhoneClient
                )
            if !sessionCookie.isEmpty { request.setValue(sessionCookie, forHTTPHeaderField: "Cookie") }
            for (name, value) in additionalHeaders { request.setValue(value, forHTTPHeaderField: name) }

            do {
                if expectedCredentialRevision != nil { await beforeSendingRequest?() }
                try validateExpectedCredentialRevision(expectedCredentialRevision)
                let delegate = !sessionCookie.isEmpty || vip || !additionalHeaders.isEmpty
                    ? SensitiveHeaderRedirectDelegate(originalURL: request.url!)
                    : nil
                let (responseData, response) = try await session.data(for: request, delegate: delegate)
                guard let http = response as? HTTPURLResponse else { throw EAPIError.invalidResponse }
                guard (200..<300).contains(http.statusCode) else {
                    retryAfter = Self.retryAfter(from: http)
                    let decoded = try? EAPICodec.decodedResponse(
                        responseData,
                        encoding: endpoint.responseEncoding
                    )
                    if let object = decoded?.object as? [String: Any],
                       let issue = SessionCredentialIssue.detect(in: object, vip: vip, musicU: musicU) {
                        reportCredentialIssue(issue, credentialRevision: credentialRevision)
                    } else if http.statusCode == 401 || http.statusCode == 403 {
                        reportCredentialIssue(
                            vip && !musicU.isEmpty ? .musicU : .cookie,
                            credentialRevision: credentialRevision
                        )
                    }
                    throw EAPIError.http(http.statusCode)
                }
                let decoded = try EAPICodec.decodedResponse(responseData, encoding: endpoint.responseEncoding)
                guard let object = decoded.object as? [String: Any] else {
                    throw EAPIError.invalidResponse
                }
                if validatesBusinessResponse {
                    try validateBusinessResponse(
                        object,
                        vip: vip,
                        musicU: musicU,
                        credentialRevision: credentialRevision
                    )
                    if !allowsDomainBusinessCodes,
                       let error = EAPIParsedResponse.businessError(in: object) {
                        throw error
                    }
                }
                let headers = http.allHeaderFields.reduce(into: [String: String]()) { result, field in
                    result[String(describing: field.key)] = String(describing: field.value)
                }
                let storedCookies = cookieStorage?.cookies ?? []
                let headerCookies = HTTPCookie.cookies(
                    withResponseHeaderFields: headers,
                    for: endpoint.physicalURL
                )
                return EAPIHTTPResponse(
                    data: decoded.data,
                    object: object,
                    statusCode: http.statusCode,
                    headers: headers,
                    cookies: storedCookies + headerCookies
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if let error = error as? URLError, error.code == .cancelled, Task.isCancelled {
                    throw CancellationError()
                }
                lastError = error
                guard attempt + 1 < attemptCount, Self.isTransient(error) else { throw error }
            }
        }
        throw lastError
    }

    static func retryAfter(from response: HTTPURLResponse) -> TimeInterval? {
        guard let value = response.value(forHTTPHeaderField: "Retry-After")?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty
        else { return nil }
        if let seconds = TimeInterval(value), seconds >= 0 { return min(seconds, 300) }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"
        return formatter.date(from: value).map { min(max(0, $0.timeIntervalSinceNow), 300) }
    }

    private static func authenticationProfile(
        cookie: String
    ) -> (os: String, appVersion: String, osVersion: String, channel: String) {
        switch NeteaseCookieHeader.value(named: "os", in: cookie) {
        case "linux": ("linux", "1.2.1.0428", "Deepin 20.9", "netease")
        case "android": ("android", "8.20.20.231215173437", "14", "xiaomi")
        case "iPhone OS": ("iPhone OS", "9.0.90", "16.2", "distribution")
        case "osx": ("osx", "3.1.10.5100", "15.5", "netease")
        default: ("pc", "3.1.17.204416", "Microsoft-Windows-10-Professional-build-19045-64bit", "netease")
        }
    }

    private static func addingEAPIClientHeader(
        to json: Data,
        fields: [(String, String)]
    ) throws -> Data {
        guard var payload = try JSONSerialization.jsonObject(with: json) as? [String: Any] else {
            throw EAPIError.invalidPayload
        }
        payload["e_r"] = false
        payload["header"] = Dictionary(uniqueKeysWithValues: fields)
        return try compactJSON(payload)
    }

    private static func eapiClientHeaderFields(
        cookie: String,
        deviceID: String? = nil,
        macOSClient: Bool = false
    ) -> [(String, String)] {
        let timestamp = Int64(Date().timeIntervalSince1970 * 1_000)
        let cookieValue: (String, String) -> String = { name, fallback in
            if macOSClient, ["os", "osver", "appver", "channel"].contains(name) { return fallback }
            let value = NeteaseCookieHeader.value(named: name, in: cookie)
            return value.isEmpty ? fallback : value
        }
        let profile = authenticationProfile(cookie: macOSClient ? "os=osx" : cookie)
        let fields = [
            ("osver", cookieValue("osver", profile.osVersion)),
            ("deviceId", deviceID ?? cookieValue("deviceId", "")),
            ("os", cookieValue("os", profile.os)),
            ("appver", cookieValue("appver", profile.appVersion)),
            ("versioncode", cookieValue("versioncode", "140")),
            ("mobilename", NeteaseCookieHeader.value(named: "mobilename", in: cookie)),
            ("buildver", cookieValue("buildver", String(timestamp).prefix(10).description)),
            ("resolution", cookieValue("resolution", "1920x1080")),
            ("__csrf", NeteaseCookieHeader.value(named: "__csrf", in: cookie)),
            ("channel", cookieValue("channel", profile.channel)),
            ("requestId", "\(timestamp)_\(String(format: "%04d", Int.random(in: 0..<1_000)))")
        ]
        return fields + ["MUSIC_U", "MUSIC_A"].compactMap { name in
            let value = NeteaseCookieHeader.value(named: name, in: cookie)
            return value.isEmpty ? nil : (name, value)
        }
    }

    private func responseCookies(
        _ response: HTTPURLResponse,
        url: URL,
        storage: HTTPCookieStorage?
    ) -> [HTTPCookie] {
        let headers = response.allHeaderFields.reduce(into: [String: String]()) { result, field in
            result[String(describing: field.key)] = String(describing: field.value)
        }
        return (storage?.cookies ?? []) + HTTPCookie.cookies(withResponseHeaderFields: headers, for: url)
    }

    private func authenticationFlow() -> (session: URLSession, cookieStorage: HTTPCookieStorage?) {
        let configuration = authenticationSession.configuration
        configuration.httpCookieStorage = URLSessionConfiguration.ephemeral.httpCookieStorage
        let session = URLSession(configuration: configuration)
        return (session, configuration.httpCookieStorage)
    }

    private func validateBusinessResponse(
        _ object: [String: Any],
        vip: Bool,
        musicU: String,
        credentialRevision: UInt64
    ) throws {
        if let issue = SessionCredentialIssue.detect(in: object, vip: vip, musicU: musicU) {
            reportCredentialIssue(issue, credentialRevision: credentialRevision)
        }
        guard let error = EAPIParsedResponse.businessError(in: object) else { return }
        switch error {
        case .invalidResponse:
            throw error
        case let .service(code, _) where Self.isTransientStatus(code):
            throw error
        default:
            return
        }
    }

    private static func accountFingerprint(cookie: String, musicU: String, revision: UInt64 = 0) -> String {
        sha256(Data("account\u{0}\(revision)\u{0}\(cookie)\u{0}\(musicU)".utf8))
    }

    private static func requestFingerprint(
        endpoint: EAPIEndpoint,
        json: Data,
        vip: Bool,
        useStoredCookieForVIP: Bool = false,
        macOSClient: Bool,
        iPhoneClient: Bool,
        includesClientHeader: Bool = false
    ) -> String {
        var source = Data(endpoint.physicalURL.absoluteString.utf8)
        source.append(0)
        source.append(contentsOf: endpoint.logicalPath.utf8)
        source.append(0)
        source.append(vip ? 1 : 0)
        source.append(vip && useStoredCookieForVIP ? 1 : 0)
        source.append(macOSClient ? 1 : 0)
        source.append(iPhoneClient ? 1 : 0)
        source.append(includesClientHeader ? 1 : 0)
        source.append(endpoint.responseEncoding.rawValue)
        source.append(json)
        return sha256(source)
    }

    fileprivate static func isTransient(_ error: Error) -> Bool {
        if error is CancellationError { return false }
        if let error = error as? EAPIError {
            switch error {
            case let .http(status): return isTransientStatus(status)
            case let .service(status, _): return isTransientStatus(status)
            case .invalidCiphertext, .invalidPadding, .invalidResponse: return true
            case .invalidPayload, .missingData: return false
            }
        } else if let error = error as? URLError {
            switch error.code {
            case .timedOut, .cannotFindHost, .cannotConnectToHost, .networkConnectionLost,
                 .dnsLookupFailed, .notConnectedToInternet, .resourceUnavailable,
                 .internationalRoamingOff, .callIsActive, .dataNotAllowed:
                return true
            default:
                return false
            }
        } else {
            return false
        }
    }

    fileprivate static func isTransientStatus(_ status: Int) -> Bool {
        status == 408 || status == 429 || (500..<600).contains(status)
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func reportCredentialIssue(_ issue: SessionCredentialIssue, credentialRevision: UInt64) {
        guard cookieOverride == nil, musicUOverride == nil else { return }
        NotificationCenter.default.post(
            name: .neteaseCredentialIssue,
            object: SessionCredentialIssueEvent(issue: issue, credentialRevision: credentialRevision)
        )
    }
}

actor EAPIResponseCache {
    private struct CacheInvalidated: Error {}

    struct Key: Hashable, Sendable {
        let account: String
        let request: String
        let group: EAPIReadCache

        init(account: String, request: String, group: EAPIReadCache = .detail) {
            self.account = account
            self.request = request
            self.group = group
        }
    }

    private struct Entry: Sendable {
        let response: EAPIParsedResponse
        let expiresAt: Date
        let staleUntil: Date
        var lastAccess: Date
    }

    private struct InFlight {
        let id: UUID
        let accountGeneration: Int
        let task: Task<EAPIParsedResponse, Error>
        let ttl: TimeInterval
        let staleIfError: TimeInterval
        let refresh: Bool
        var waiters: [UUID: CheckedContinuation<EAPIParsedResponse, Error>] = [:]
    }

    private let countLimit: Int
    private let costLimit: Int
    private var entries: [Key: Entry] = [:]
    private var inFlight: [Key: InFlight] = [:]
    private var accountGenerations: [String: Int] = [:]
    private var totalCost = 0

    init(countLimit: Int = 512, costLimit: Int = 64 * 1_024 * 1_024) {
        self.countLimit = countLimit
        self.costLimit = costLimit
    }

    func waiterCount(for key: Key) -> Int {
        inFlight[key]?.waiters.count ?? 0
    }

    deinit {
        for request in inFlight.values {
            request.task.cancel()
            request.waiters.values.forEach { $0.resume(throwing: CancellationError()) }
        }
    }

    func value(
        for key: Key,
        ttl: TimeInterval,
        staleIfError: TimeInterval,
        refresh: Bool = false,
        loader: @escaping @Sendable () async throws -> Data
    ) async throws -> Data {
        try await parsedValue(
            for: key,
            ttl: ttl,
            staleIfError: staleIfError,
            refresh: refresh
        ) {
            EAPIParsedResponse(data: try await loader(), object: nil)
        }.data
    }

    func parsedValue(
        for key: Key,
        ttl: TimeInterval,
        staleIfError: TimeInterval,
        refresh: Bool = false,
        loader: @escaping @Sendable () async throws -> EAPIParsedResponse
    ) async throws -> EAPIParsedResponse {
        var invalidationRetries = 0
        while true {
            do {
                return try await valueOnce(
                    for: key,
                    ttl: ttl,
                    staleIfError: staleIfError,
                    refresh: refresh,
                    loader: loader
                )
            } catch is CacheInvalidated {
                try Task.checkCancellation()
                guard invalidationRetries == 0 else { throw CacheInvalidated() }
                invalidationRetries += 1
            }
        }
    }

    private func valueOnce(
        for key: Key,
        ttl: TimeInterval,
        staleIfError: TimeInterval,
        refresh: Bool,
        loader: @escaping @Sendable () async throws -> EAPIParsedResponse
    ) async throws -> EAPIParsedResponse {
        try Task.checkCancellation()
        let now = Date()
        removeExpired(before: now)
        if !refresh, inFlight[key]?.refresh != true, var entry = entries[key], entry.expiresAt > now {
            entry.lastAccess = now
            entries[key] = entry
            return entry.response
        }

        let requestID: UUID
        if let existing = inFlight[key], !refresh || existing.refresh {
            requestID = existing.id
        } else {
            if let existing = inFlight.removeValue(forKey: key) {
                cancel(existing, with: CacheInvalidated())
            }
            let id = UUID()
            let task = Task { try await loader() }
            inFlight[key] = InFlight(
                id: id,
                accountGeneration: accountGenerations[key.account, default: 0],
                task: task,
                ttl: ttl,
                staleIfError: staleIfError,
                refresh: refresh
            )
            requestID = id
            Task { [weak self, task] in
                let result = await task.result
                await self?.complete(result, for: key, requestID: id)
            }
        }

        let waiterID = UUID()
        let response = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<EAPIParsedResponse, Error>) in
                guard var request = inFlight[key], request.id == requestID else {
                    continuation.resume(throwing: CacheInvalidated())
                    return
                }
                request.waiters[waiterID] = continuation
                inFlight[key] = request
            }
        } onCancel: {
            Task { await self.cancelWaiter(waiterID, for: key, requestID: requestID) }
        }
        try Task.checkCancellation()
        return response
    }

    func invalidate(account: String) {
        invalidate(account: account, groups: nil)
    }

    func invalidate(account: String, groups: Set<EAPIReadCache>?) {
        if groups == nil { accountGenerations[account, default: 0] += 1 }
        let keys = entries.keys.filter {
            $0.account == account && (groups == nil || groups?.contains($0.group) == true)
        }
        for key in keys { removeValue(for: key) }
        let tasks = inFlight.filter {
            $0.key.account == account && (groups == nil || groups?.contains($0.key.group) == true)
        }
        for (key, request) in tasks {
            inFlight[key] = nil
            cancel(request, with: CacheInvalidated())
        }
    }

    func invalidateAll() {
        entries.removeAll(keepingCapacity: false)
        totalCost = 0
        for request in inFlight.values { cancel(request, with: CacheInvalidated()) }
        inFlight.removeAll(keepingCapacity: false)
        accountGenerations.removeAll(keepingCapacity: false)
    }

    private func complete(_ result: Result<EAPIParsedResponse, Error>, for key: Key, requestID: UUID) {
        guard let request = inFlight[key], request.id == requestID else { return }
        inFlight[key] = nil
        let response: Result<EAPIParsedResponse, Error>
        switch result {
        case let .success(value):
            if value.businessError == nil,
               request.accountGeneration == accountGenerations[key.account, default: 0] {
                let storedAt = Date()
                store(
                    value,
                    for: key,
                    expiresAt: storedAt.addingTimeInterval(max(0, request.ttl)),
                    staleUntil: storedAt.addingTimeInterval(max(0, request.ttl + request.staleIfError))
                )
            }
            response = .success(value)
        case let .failure(error):
            if !request.refresh,
               Self.canUseStale(after: error),
               var entry = entries[key],
               entry.staleUntil > Date() {
                entry.lastAccess = Date()
                entries[key] = entry
                response = .success(entry.response)
            } else {
                response = .failure(error)
            }
        }
        request.waiters.values.forEach { $0.resume(with: response) }
    }

    private func cancelWaiter(_ waiterID: UUID, for key: Key, requestID: UUID) {
        guard var request = inFlight[key], request.id == requestID,
              let continuation = request.waiters.removeValue(forKey: waiterID)
        else { return }
        if request.waiters.isEmpty {
            inFlight[key] = nil
            request.task.cancel()
        } else {
            inFlight[key] = request
        }
        continuation.resume(throwing: CancellationError())
    }

    private func cancel(_ request: InFlight, with error: Error) {
        request.task.cancel()
        request.waiters.values.forEach { $0.resume(throwing: error) }
    }

    private func store(_ response: EAPIParsedResponse, for key: Key, expiresAt: Date, staleUntil: Date) {
        if let previous = entries[key] { totalCost -= previous.response.data.count }
        entries[key] = Entry(response: response, expiresAt: expiresAt, staleUntil: staleUntil, lastAccess: Date())
        totalCost += response.data.count
        trimIfNeeded()
    }

    private func removeExpired(before date: Date) {
        let keys = entries.compactMap { $0.value.staleUntil <= date ? $0.key : nil }
        for key in keys { removeValue(for: key) }
    }

    private func trimIfNeeded() {
        guard entries.count > countLimit || totalCost > costLimit else { return }
        let oldest = entries.sorted { $0.value.lastAccess < $1.value.lastAccess }
        for (key, _) in oldest {
            removeValue(for: key)
            if entries.count <= countLimit, totalCost <= costLimit { break }
        }
    }

    private func removeValue(for key: Key) {
        guard let removed = entries.removeValue(forKey: key) else { return }
        totalCost -= removed.response.data.count
    }

    private static func canUseStale(after error: Error) -> Bool {
        if error is CancellationError || error is CacheInvalidated || error is CredentialRevisionMismatch {
            return false
        }
        if let error = error as? EAPIError {
            switch error {
            case let .http(status):
                return EAPITransport.isTransientStatus(status)
            case let .service(status, _):
                return EAPITransport.isTransientStatus(status)
            case .invalidCiphertext, .invalidPadding, .invalidResponse:
                return true
            case .invalidPayload, .missingData:
                return false
            }
        }
        if let error = error as? URLError { return error.code != .cancelled }
        return true
    }
}

enum EAPICookieHeader {
    static func value(
        cookie: String,
        musicU: String,
        vip: Bool,
        buildVersion: Int,
        requestID: String,
        macOSClient: Bool = false,
        iPhoneClient: Bool = false
    ) -> String {
        if vip, !musicU.isEmpty, !iPhoneClient {
            return "appver=8.9.70; buildver=\(buildVersion); resulution=1920x1080; os=Android; NMTID=00Olq-ZjX3Zh6UjokPQs695eltgPzwAAAGWXOtzdw; MUSIC_U=\(musicU); deviceId=9CC2C781CEEC4408333573ACF975B764BB3D6492A63544CD059A; channel=distribution; requestId=\(requestID)"
        }
        let usesIPhoneClient = iPhoneClient || (vip && musicU.isEmpty)
        var overriddenKeys = Set(["os", "osver", "appver", "channel"])
        if usesIPhoneClient, !musicU.isEmpty { overriddenKeys.insert("music_u") }
        let sourceCookie = vip && !musicU.isEmpty ? "" : cookie
        var parts = sourceCookie.split(separator: ";").map {
            String($0).trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter {
            !(macOSClient || usesIPhoneClient)
                || !overriddenKeys.contains($0.split(separator: "=", maxSplits: 1).first?.lowercased() ?? "")
        }
        parts += macOSClient
            ? ["osver=15.5", "os=osx", "appver=3.1.10.5100", "channel=netease"]
            : ["osver=16.2", "os=iPhone OS", "appver=9.0.90", "channel=distribution"]
        if usesIPhoneClient, !musicU.isEmpty { parts.append("MUSIC_U=\(musicU)") }
        parts += [
            "versioncode=140", "buildver=\(buildVersion)", "resolution=1920x1080",
            "requestId=\(requestID)"
        ]
        return parts.filter { !$0.isEmpty }.joined(separator: "; ")
    }
}

func compactJSON(_ object: [String: Any]) throws -> Data {
    guard JSONSerialization.isValidJSONObject(object) else { throw EAPIError.invalidPayload }
    return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
}

func decodedJSONObject(_ data: Data) throws -> [String: Any] {
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw EAPIError.invalidResponse
    }
    return try decodedJSONObject(object)
}

func decodedJSONObject(_ object: [String: Any]) throws -> [String: Any] {
    if let error = EAPIParsedResponse.businessError(in: object) { throw error }
    return object
}

extension Dictionary where Key == String, Value == Any {
    func object(_ key: String) -> [String: Any] { self[key] as? [String: Any] ?? [:] }
    func array(_ key: String) -> [[String: Any]] { self[key] as? [[String: Any]] ?? [] }
    func string(_ key: String) -> String {
        if let value = self[key] as? String { return value }
        if let value = self[key] as? NSNumber { return value.stringValue }
        return ""
    }
    func int64(_ key: String) -> Int64 {
        if let value = self[key] as? NSNumber { return value.int64Value }
        return Int64(string(key)) ?? 0
    }
    func int(_ key: String) -> Int { (self[key] as? NSNumber)?.intValue ?? Int(string(key)) ?? 0 }
    func bool(_ key: String) -> Bool { (self[key] as? NSNumber)?.boolValue ?? false }
}
