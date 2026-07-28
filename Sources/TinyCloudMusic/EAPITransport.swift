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

    fileprivate var policy: EAPIRequestCachePolicy {
        switch self {
        case .search: .read(ttl: 2 * 60, staleIfError: 10 * 60)
        case .searchHints: .read(ttl: 5 * 60, staleIfError: 30 * 60)
        case .detail: .read(ttl: 5 * 60, staleIfError: 30 * 60)
        case .library: .read(ttl: 90, staleIfError: 15 * 60)
        case .playlistSummaries: .read(ttl: 0, staleIfError: 15 * 60)
        case .comments: .read(ttl: 30, staleIfError: 2 * 60)
        case .lyrics: .read(ttl: 60 * 60, staleIfError: 24 * 60 * 60)
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
    let statusCode: Int
    let headers: [String: String]
    let cookies: [HTTPCookie]
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

enum SessionCredentialIssue: String, Sendable {
    case cookie
    case musicU

    static func detect(in data: Data, vip: Bool, musicU: String) -> Self? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let code = (object["code"] as? NSNumber)?.intValue
            ?? (object["code"] as? String).flatMap(Int.init)
        guard let code, (300..<400).contains(code) || code == 401 || code == 403 else { return nil }
        return vip && !musicU.isEmpty ? .musicU : .cookie
    }
}

extension Notification.Name {
    static let neteaseCredentialIssue = Notification.Name("TinyCloudMusic.credentialIssue")
}

enum EAPICodec {
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
        guard !data.isEmpty else { throw EAPIError.invalidResponse }
        switch encoding {
        case .json:
            guard isJSON(data) else { throw EAPIError.invalidResponse }
            return data
        case .encrypted:
            return try decryptedJSON(data)
        case .automatic:
            return isJSON(data) ? data : try decryptedJSON(data)
        }
    }

    private static func decryptedJSON(_ data: Data) throws -> Data {
        let decrypted = try decrypt(data)
        guard isJSON(decrypted) else { throw EAPIError.invalidResponse }
        return decrypted
    }

    private static func isJSON(_ data: Data) -> Bool {
        (try? JSONSerialization.jsonObject(with: data)) != nil
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

struct EAPITransport: Sendable {
    private let session: URLSession
    private let authenticationSession: URLSession
    private let authenticationCookieStorage: HTTPCookieStorage?
    private let cookieOverride: String?
    private let musicUOverride: String?
    private let loadStoredCredentials: @Sendable () -> SessionCredentials?
    private let weapiSecretKeyOverride: String?
    private let responseCache: EAPIResponseCache

    init(
        session: URLSession? = nil,
        cookie: String? = nil,
        musicU: String? = nil,
        loadStoredCredentials: @escaping @Sendable () -> SessionCredentials? = { nil },
        weapiSecretKey: String? = nil,
        responseCache: EAPIResponseCache = EAPIResponseCache()
    ) {
        if let session {
            self.session = session
            authenticationSession = session
            authenticationCookieStorage = session.configuration.httpCookieStorage
        } else {
            let configuration = URLSessionConfiguration.default
            configuration.httpMaximumConnectionsPerHost = 8
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.timeoutIntervalForRequest = 15
            configuration.timeoutIntervalForResource = 60
            configuration.waitsForConnectivity = true
            self.session = URLSession(configuration: configuration)

            let authenticationConfiguration = URLSessionConfiguration.ephemeral
            authenticationConfiguration.requestCachePolicy = .reloadIgnoringLocalCacheData
            authenticationConfiguration.timeoutIntervalForRequest = 15
            authenticationConfiguration.timeoutIntervalForResource = 30
            authenticationSession = URLSession(configuration: authenticationConfiguration)
            authenticationCookieStorage = authenticationConfiguration.httpCookieStorage
        }
        cookieOverride = cookie
        musicUOverride = musicU
        self.loadStoredCredentials = loadStoredCredentials
        weapiSecretKeyOverride = weapiSecretKey
        self.responseCache = responseCache
    }

    func registerAnonymous() async throws -> NeteaseAuthenticationContext {
        authenticationCookieStorage?.removeCookies(since: .distantPast)
        defer { authenticationCookieStorage?.removeCookies(since: .distantPast) }
        let deviceID = try XEAPICodec.generateDeviceID()
        let keyRequest = try XEAPICodec.publicKeyRequest(deviceID: deviceID)
        let (keyData, keyResponse) = try await authenticationSession.data(for: keyRequest.request)
        guard let keyHTTP = keyResponse as? HTTPURLResponse,
              (200..<300).contains(keyHTTP.statusCode)
        else { throw EAPIError.invalidResponse }
        let publicKey = try XEAPICodec.decodePublicKey(keyData, nonce: keyRequest.nonce)

        let request = try XEAPICodec.anonymousRequest(deviceID: deviceID, publicKey: publicKey)
        let (responseData, response) = try await authenticationSession.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode)
        else { throw EAPIError.invalidResponse }
        _ = try decodedJSONObject(XEAPICodec.decodeResponse(responseData))
        let headers = http.allHeaderFields.reduce(into: [String: String]()) { result, field in
            result[String(describing: field.key)] = String(describing: field.value)
        }
        let cookie = NeteaseCookieHeader.merging(
            "",
            with: (authenticationCookieStorage?.cookies(for: request.url!) ?? [])
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
        authenticationCookieStorage?.removeCookies(since: .distantPast)
        defer { authenticationCookieStorage?.removeCookies(since: .distantPast) }
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
            session: authenticationSession,
            cookieStorage: authenticationCookieStorage,
            cookieHeaderOverride: try XEAPICodec.encodedCookie(headerFields),
            userAgentOverride: userAgent
        )
    }

    func requestHTTP(
        _ endpoint: EAPIEndpoint,
        json: Data,
        cookie: String? = nil,
        musicU: String? = nil
    ) async throws -> EAPIHTTPResponse {
        let stored = credentials()
        authenticationCookieStorage?.removeCookies(since: .distantPast)
        defer { authenticationCookieStorage?.removeCookies(since: .distantPast) }
        return try await performHTTPRequest(
            endpoint,
            body: EAPICodec.requestBody(path: endpoint.logicalPath, json: json),
            cookie: cookie ?? stored.cookie,
            musicU: musicU ?? stored.musicU,
            vip: false,
            macOSClient: false,
            iPhoneClient: false,
            retryable: false,
            session: authenticationSession,
            cookieStorage: authenticationCookieStorage,
            cookieHeaderOverride: nil,
            userAgentOverride: nil
        )
    }

    func request(
        _ endpoint: EAPIEndpoint,
        json: Data,
        vip: Bool = false,
        cache: EAPIReadCache? = nil,
        invalidatesAccountCache: Bool = false,
        macOSClient: Bool = false,
        iPhoneClient: Bool = false,
        includesClientHeader: Bool = false,
        retryable: Bool = true
    ) async throws -> Data {
        let credentials = resolvedCredentials()
        let cookie = credentials.cookie
        let musicU = credentials.musicU
        let clientHeaderFields = includesClientHeader
            ? Self.eapiClientHeaderFields(cookie: cookie, deviceID: credentials.deviceID)
            : nil
        let requestJSON = try clientHeaderFields.map {
            try Self.addingEAPIClientHeader(to: json, fields: $0)
        } ?? json
        let clientCookie = try clientHeaderFields.map(XEAPICodec.encodedCookie)
        let body = try EAPICodec.requestBody(path: endpoint.logicalPath, json: requestJSON)
        let account = Self.accountFingerprint(cookie: cookie, musicU: musicU)
        let policy: EAPIRequestCachePolicy = invalidatesAccountCache
            ? .invalidateAccount
            : cache?.policy ?? .none

        switch policy {
        case .none:
            return try await performRequest(
                endpoint,
                body: body,
                cookie: cookie,
                musicU: musicU,
                vip: vip,
                macOSClient: macOSClient,
                iPhoneClient: iPhoneClient,
                cookieHeaderOverride: clientCookie,
                retryable: retryable && !invalidatesAccountCache
            )
        case let .read(ttl, staleIfError):
            let key = EAPIResponseCache.Key(
                account: account,
                request: Self.requestFingerprint(
                    endpoint: endpoint,
                    json: json,
                    vip: vip,
                    macOSClient: macOSClient,
                    iPhoneClient: iPhoneClient,
                    includesClientHeader: includesClientHeader
                ),
                group: cache ?? .detail
            )
            return try await responseCache.value(
                for: key,
                ttl: ttl,
                staleIfError: staleIfError
            ) { [self] in
                try await performRequest(
                    endpoint,
                    body: body,
                    cookie: cookie,
                    musicU: musicU,
                    vip: vip,
                    macOSClient: macOSClient,
                    iPhoneClient: iPhoneClient,
                    cookieHeaderOverride: clientCookie,
                    retryable: retryable
                )
            }
        case .invalidateAccount:
            let data = try await performRequest(
                endpoint,
                body: body,
                cookie: cookie,
                musicU: musicU,
                vip: vip,
                macOSClient: macOSClient,
                iPhoneClient: iPhoneClient,
                cookieHeaderOverride: clientCookie,
                retryable: false
            )
            if EAPIResponseCache.isSuccessfulResponse(data) {
                await responseCache.invalidate(account: account)
            }
            return data
        }
    }

    func invalidateAllCachedResponses() async {
        await responseCache.invalidateAll()
    }

    func invalidateCachedResponses(in groups: Set<EAPIReadCache>) async {
        guard !groups.isEmpty else { return }
        let (cookie, musicU) = credentials()
        await responseCache.invalidate(
            account: Self.accountFingerprint(cookie: cookie, musicU: musicU),
            groups: groups
        )
    }

    func requestCommentLike(threadID: String, commentID: Int64, liked: Bool) async throws -> Data {
        let action = liked ? "like" : "unlike"
        return try await requestWEAPI(
            path: "/weapi/v1/comment/\(action)",
            payload: ["threadId": threadID, "commentId": String(commentID)]
        )
    }

    func requestFMTrash(songID: Int64, algorithm: String, playedSeconds: Int) async throws -> Data {
        guard songID > 0, playedSeconds > 0 else { throw EAPIError.invalidPayload }
        return try await requestWEAPI(
            path: "/weapi/radio/trash/add",
            payload: [
                "songId": songID,
                "alg": algorithm.isEmpty ? "RT" : algorithm,
                "time": playedSeconds
            ]
        )
    }

    func requestRecentPlayback(path: String, limit: Int) async throws -> Data {
        let paths = [
            "/api/play-record/song/list",
            "/api/play-record/album/list",
            "/api/play-record/playlist/list",
            "/api/play-record/newvideo/list",
            "/api/play-record/voice/list",
            "/api/play-record/djradio/list"
        ]
        guard paths.contains(path), (1...100).contains(limit) else { throw EAPIError.invalidPayload }
        return try await requestWEAPI(
            path: path.replacingOccurrences(of: "/api/", with: "/weapi/"),
            payload: ["limit": limit],
            cache: .library
        )
    }

    func requestCloudSongs(offset: Int, limit: Int) async throws -> Data {
        guard offset >= 0, (1...100).contains(limit) else { throw EAPIError.invalidPayload }
        return try await requestWEAPI(
            path: "/weapi/v1/cloud/get",
            payload: ["offset": offset, "limit": limit],
            cache: .library,
            invalidatesAccountCache: false
        )
    }

    func requestCloudSongDetails(ids: [Int64]) async throws -> Data {
        guard !ids.isEmpty, ids.count <= 50, ids.allSatisfy({ $0 > 0 }) else {
            throw EAPIError.invalidPayload
        }
        return try await requestWEAPI(
            path: "/weapi/v1/cloud/get/byids",
            payload: ["songIds": ids],
            cache: .detail,
            invalidatesAccountCache: false
        )
    }

    func requestRecommendationHistory(date: String? = nil) async throws -> Data {
        let path = date == nil
            ? "/weapi/discovery/recommend/songs/history/recent"
            : "/weapi/discovery/recommend/songs/history/detail"
        return try await requestWEAPI(
            path: path,
            payload: date.map { ["date": $0] } ?? [:],
            cache: .library,
            invalidatesAccountCache: false
        )
    }

    func requestWEAPI(
        path: String,
        payload: [String: Any],
        cache: EAPIReadCache? = nil,
        invalidatesAccountCache: Bool = true
    ) async throws -> Data {
        let (cookie, musicU) = credentials()
        var payload = payload
        payload["csrf_token"] = WEAPICodec.csrfToken(in: cookie)
        payload["e_r"] = false
        let json = try compactJSON(payload)
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
        if !cookie.isEmpty { request.setValue(cookie, forHTTPHeaderField: "Cookie") }
        let preparedRequest = request

        if let cache, case let .read(ttl, staleIfError) = cache.policy {
            let key = EAPIResponseCache.Key(
                account: Self.accountFingerprint(cookie: cookie, musicU: musicU),
                request: Self.requestFingerprint(
                    endpoint: EAPIEndpoint(path, signing: path, responseEncoding: .json),
                    json: json,
                    vip: false,
                    macOSClient: true,
                    iPhoneClient: false
                ),
                group: cache
            )
            return try await responseCache.value(for: key, ttl: ttl, staleIfError: staleIfError) {
                try await performWEAPIRequest(preparedRequest, musicU: musicU)
            }
        }

        let data = try await performWEAPIRequest(preparedRequest, musicU: musicU)
        if invalidatesAccountCache, EAPIResponseCache.isSuccessfulResponse(data) {
            await responseCache.invalidate(account: Self.accountFingerprint(cookie: cookie, musicU: musicU))
        }
        return data
    }

    func requestRaw(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw EAPIError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw EAPIError.http(http.statusCode) }
        return data
    }

    private func performWEAPIRequest(_ request: URLRequest, musicU: String) async throws -> Data {
        let (responseData, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw EAPIError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401 || http.statusCode == 403 { reportCredentialIssue(.cookie) }
            throw EAPIError.http(http.statusCode)
        }
        let data = try EAPICodec.responseData(responseData)
        if let issue = SessionCredentialIssue.detect(in: data, vip: false, musicU: musicU) {
            reportCredentialIssue(issue)
        }
        return data
    }

    func credentials() -> (cookie: String, musicU: String) {
        let credentials = resolvedCredentials()
        return (credentials.cookie, credentials.musicU)
    }

    private func resolvedCredentials() -> (cookie: String, musicU: String, deviceID: String) {
        let cookie = cookieOverride
        let musicU = musicUOverride
        if cookie != nil || musicU != nil {
            let cookie = cookie ?? ""
            return (cookie, musicU ?? "", NeteaseCookieHeader.value(named: "deviceId", in: cookie))
        }
        let stored = loadStoredCredentials()
        return (stored?.cookie ?? "", stored?.musicU ?? "", stored?.deviceID ?? "")
    }

    private func performRequest(
        _ endpoint: EAPIEndpoint,
        body: Data,
        cookie: String,
        musicU: String,
        vip: Bool,
        macOSClient: Bool,
        iPhoneClient: Bool,
        cookieHeaderOverride: String?,
        retryable: Bool
    ) async throws -> Data {
        try await performHTTPRequest(
            endpoint,
            body: body,
            cookie: cookie,
            musicU: musicU,
            vip: vip,
            macOSClient: macOSClient,
            iPhoneClient: iPhoneClient,
            retryable: retryable,
            session: session,
            cookieStorage: nil,
            cookieHeaderOverride: cookieHeaderOverride,
            userAgentOverride: nil
        ).data
    }

    private func performHTTPRequest(
        _ endpoint: EAPIEndpoint,
        body: Data,
        cookie: String,
        musicU: String,
        vip: Bool,
        macOSClient: Bool,
        iPhoneClient: Bool,
        retryable: Bool,
        session: URLSession,
        cookieStorage: HTTPCookieStorage?,
        cookieHeaderOverride: String?,
        userAgentOverride: String?
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
            request.httpMethod = "POST"
            request.httpBody = body
            request.setValue(
                "application/x-www-form-urlencoded;charset=utf-8",
                forHTTPHeaderField: "Content-Type"
            )
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

            do {
                let (responseData, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else { throw EAPIError.invalidResponse }
                let decodedData = try? EAPICodec.responseData(
                    responseData,
                    encoding: endpoint.responseEncoding
                )
                guard (200..<300).contains(http.statusCode) else {
                    retryAfter = Self.retryAfter(from: http)
                    if let decodedData,
                       let issue = SessionCredentialIssue.detect(in: decodedData, vip: vip, musicU: musicU) {
                        reportCredentialIssue(issue)
                    } else if http.statusCode == 401 || http.statusCode == 403 {
                        reportCredentialIssue(vip && !musicU.isEmpty ? .musicU : .cookie)
                    }
                    throw EAPIError.http(http.statusCode)
                }
                let data = try EAPICodec.responseData(responseData, encoding: endpoint.responseEncoding)
                if let issue = SessionCredentialIssue.detect(in: data, vip: vip, musicU: musicU) {
                    reportCredentialIssue(issue)
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
                    data: data,
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
        deviceID: String? = nil
    ) -> [(String, String)] {
        let timestamp = Int64(Date().timeIntervalSince1970 * 1_000)
        let cookieValue: (String, String) -> String = { name, fallback in
            let value = NeteaseCookieHeader.value(named: name, in: cookie)
            return value.isEmpty ? fallback : value
        }
        let profile = authenticationProfile(cookie: cookie)
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

    private static func accountFingerprint(cookie: String, musicU: String) -> String {
        sha256(Data("account\u{0}\(cookie)\u{0}\(musicU)".utf8))
    }

    private static func requestFingerprint(
        endpoint: EAPIEndpoint,
        json: Data,
        vip: Bool,
        macOSClient: Bool,
        iPhoneClient: Bool,
        includesClientHeader: Bool = false
    ) -> String {
        var source = Data(endpoint.physicalURL.absoluteString.utf8)
        source.append(0)
        source.append(contentsOf: endpoint.logicalPath.utf8)
        source.append(0)
        source.append(vip ? 1 : 0)
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
            case let .http(status): return status == 408 || status == 429 || status >= 500
            case .invalidCiphertext, .invalidPadding, .invalidResponse: return true
            case .invalidPayload, .service, .missingData: return false
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

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func reportCredentialIssue(_ issue: SessionCredentialIssue) {
        guard cookieOverride == nil, musicUOverride == nil else { return }
        NotificationCenter.default.post(name: .neteaseCredentialIssue, object: issue.rawValue)
    }
}

actor EAPIResponseCache {
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
        let data: Data
        let expiresAt: Date
        let staleUntil: Date
        var lastAccess: Date
    }

    private struct InFlight {
        let id: UUID
        let accountGeneration: Int
        let task: Task<Data, Error>
        let ttl: TimeInterval
        let staleIfError: TimeInterval
        var waiters: [UUID: CheckedContinuation<Data, Error>] = [:]
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
        loader: @escaping @Sendable () async throws -> Data
    ) async throws -> Data {
        try Task.checkCancellation()
        let now = Date()
        removeExpired(before: now)
        if var entry = entries[key], entry.expiresAt > now {
            entry.lastAccess = now
            entries[key] = entry
            return entry.data
        }

        let requestID: UUID
        if let existing = inFlight[key] {
            requestID = existing.id
        } else {
            let id = UUID()
            let task = Task { try await loader() }
            inFlight[key] = InFlight(
                id: id,
                accountGeneration: accountGenerations[key.account, default: 0],
                task: task,
                ttl: ttl,
                staleIfError: staleIfError
            )
            requestID = id
            Task { [weak self, task] in
                let result = await task.result
                await self?.complete(result, for: key, requestID: id)
            }
        }

        let waiterID = UUID()
        let data = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
                guard var request = inFlight[key], request.id == requestID else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                request.waiters[waiterID] = continuation
                inFlight[key] = request
            }
        } onCancel: {
            Task { await self.cancelWaiter(waiterID, for: key, requestID: requestID) }
        }
        try Task.checkCancellation()
        return data
    }

    func invalidate(account: String) {
        invalidate(account: account, groups: nil)
    }

    func invalidate(account: String, groups: Set<EAPIReadCache>?) {
        accountGenerations[account, default: 0] &+= 1
        let keys = entries.keys.filter {
            $0.account == account && (groups == nil || groups?.contains($0.group) == true)
        }
        for key in keys { removeValue(for: key) }
        let tasks = inFlight.filter {
            $0.key.account == account && (groups == nil || groups?.contains($0.key.group) == true)
        }
        for (key, request) in tasks {
            inFlight[key] = nil
            cancel(request)
        }
    }

    func invalidateAll() {
        entries.removeAll(keepingCapacity: false)
        totalCost = 0
        for request in inFlight.values { cancel(request) }
        inFlight.removeAll(keepingCapacity: false)
        accountGenerations.removeAll(keepingCapacity: false)
    }

    private func complete(_ result: Result<Data, Error>, for key: Key, requestID: UUID) {
        guard let request = inFlight[key], request.id == requestID else { return }
        inFlight[key] = nil
        let response: Result<Data, Error>
        switch result {
        case let .success(data):
            if request.accountGeneration == accountGenerations[key.account, default: 0],
               Self.isSuccessfulResponse(data) {
                let storedAt = Date()
                store(
                    data,
                    for: key,
                    expiresAt: storedAt.addingTimeInterval(max(0, request.ttl)),
                    staleUntil: storedAt.addingTimeInterval(max(0, request.ttl + request.staleIfError))
                )
            }
            response = .success(data)
        case let .failure(error):
            if Self.canUseStale(after: error), var entry = entries[key], entry.staleUntil > Date() {
                entry.lastAccess = Date()
                entries[key] = entry
                response = .success(entry.data)
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

    private func cancel(_ request: InFlight) {
        request.task.cancel()
        request.waiters.values.forEach { $0.resume(throwing: CancellationError()) }
    }

    private func store(_ data: Data, for key: Key, expiresAt: Date, staleUntil: Date) {
        if let previous = entries[key] { totalCost -= previous.data.count }
        entries[key] = Entry(data: data, expiresAt: expiresAt, staleUntil: staleUntil, lastAccess: Date())
        totalCost += data.count
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
        totalCost -= removed.data.count
    }

    static func isSuccessfulResponse(_ data: Data) -> Bool {
        guard !data.isEmpty,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }
        guard let value = root["code"] else { return true }
        let code = (value as? NSNumber)?.intValue ?? (value as? String).flatMap(Int.init) ?? 0
        return (200..<300).contains(code)
    }

    private static func canUseStale(after error: Error) -> Bool {
        if error is CancellationError { return false }
        if let error = error as? EAPIError {
            switch error {
            case let .http(status):
                return status == 408 || status == 429 || status >= 500
            case .invalidCiphertext, .invalidPadding, .invalidResponse:
                return true
            case .invalidPayload, .service, .missingData:
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
        var parts = cookie.split(separator: ";").map {
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
    if object["code"] != nil {
        let code = object.int("code")
        guard code != 0 else { throw EAPIError.invalidResponse }
        if !(200..<300).contains(code) {
            let message = object.string("message")
            throw EAPIError.service(code: code, message: message.isEmpty ? object.string("msg") : message)
        }
    }
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
