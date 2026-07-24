import Foundation

@main
enum EAPICheck {
    static func main() throws {
        let path = "/api/search/song/list/page"
        let json = Data(#"{"keyword":"Jay","limit":20}"#.utf8)
        let expectedEnvelope = #"/api/search/song/list/page-36cd479b6b5-{"keyword":"Jay","limit":20}-36cd479b6b5-20141daa18b47b5a257341675323cde5"#
        let envelope = try EAPICodec.envelope(path: path, json: json)
        precondition(String(decoding: envelope, as: UTF8.self) == expectedEnvelope)

        let expectedCipher = "74A595527B7A1647174ADDB4F261E92F180F42F921F98E9D338C60DB20AF499CEA90E95FB2FDA117A0B5D8175C2F21E526B15AF6D028297F4287F4DFA7898137564EB3B19846AC50AB05A9242E72C170FF8E303646DE796F2DF32538AD098FB18196B028974173E253935B19CEF651366AA3B102FBE7296AB0DB9EA5C46AD12B"
        let requestBody = try EAPICodec.requestBody(path: path, json: json)
        let albumCacheKey = try EAPICodec.albumCacheKey(id: 123)
        precondition(String(decoding: requestBody, as: UTF8.self) == "params=\(expectedCipher)")
        precondition(albumCacheKey == "S2WmfZU6gkrjEY6XtcnFjA==")
        let weapiJSON = Data(#"{"alg":"RT","csrf_token":"","songId":11,"time":42}"#.utf8)
        let weapi = try WEAPICodec.encryptedFields(
            json: weapiJSON,
            secretKey: "abcdefghijklmnop"
        )
        precondition(
            weapi.params
                == "7wnCcDyzX3v9v3tWHDaCBP2iegEftxGjGvVOz+ZfaMnSmErqyc8j4R5uyJwIg0sVyXjdtB4fuYfdNa+p8VHOCaXtEa37KXfizVB8O1bGQiPf8jF3g1TCEXgWk3UNSGZl"
        )
        precondition(
            weapi.encSecKey
                == "d15a1683c992095d0c234c19966605c5c5964911268bbeda8cb8d08d834913e59d53b32358903a121b5fca784c1f5ae44951fd02524df58ecc98e52cc7cf8689b42c2e93ddf05b0592512d87f5960467e2f086c018849d76014d323500e30f13ef4cafbb0cf5a66731a3f1776c75ca35d0062dac70a3e33245afabcf47938487"
        )
        let weapiBody = try WEAPICodec.requestBody(json: weapiJSON, secretKey: "abcdefghijklmnop")
        precondition(String(decoding: weapiBody, as: UTF8.self).contains("%2B"))
        precondition(!String(decoding: weapiBody, as: UTF8.self).contains("+"))
        let plainResponse = Data(#"{"code":200,"data":{"value":"plain"}}"#.utf8)
        let decodedPlainResponse = try EAPICodec.responseData(plainResponse)
        precondition(decodedPlainResponse == plainResponse)
        let encryptedResponse = hexData(
            "DCC52B3013E9B66C038F8E027E580ECEB05FC53B1F6993CE36C0C7ECDAB365A762DAEBC2218FE30386E1CF0BDB6F38EA"
        )
        let decodedEncryptedResponse = try EAPICodec.responseData(encryptedResponse)
        precondition(decodedEncryptedResponse == Data(#"{"code":200,"data":{"value":"encrypted"}}"#.utf8))
        let fallbackCookie = EAPICookieHeader.value(
            cookie: "MUSIC_A=session; __csrf=csrf",
            musicU: "",
            vip: true,
            buildVersion: 123,
            requestID: "request"
        )
        precondition(fallbackCookie.contains("MUSIC_A=session; __csrf=csrf"))
        precondition(fallbackCookie.contains("os=iPhone OS; appver=9.0.90"))
        precondition(!fallbackCookie.contains("os=Android"))
        let vipCookie = EAPICookieHeader.value(
            cookie: "MUSIC_A=session; __csrf=csrf",
            musicU: "vip-token",
            vip: true,
            buildVersion: 123,
            requestID: "request"
        )
        precondition(vipCookie.contains("appver=8.9.70; buildver=123"))
        precondition(vipCookie.contains("MUSIC_U=vip-token"))
        precondition(vipCookie.hasSuffix("requestId=request"))
        let iPhoneVIPCookie = EAPICookieHeader.value(
            cookie: "__csrf=csrf; MUSIC_U=embedded-token; os=pc",
            musicU: "vip-token",
            vip: true,
            buildVersion: 123,
            requestID: "request",
            iPhoneClient: true
        )
        precondition(iPhoneVIPCookie.contains("os=iPhone OS; appver=9.0.90"))
        precondition(iPhoneVIPCookie.contains("MUSIC_U=vip-token"))
        precondition(!iPhoneVIPCookie.contains("embedded-token"))
        precondition(!iPhoneVIPCookie.contains("os=pc"))
        let embeddedFallbackCookie = EAPICookieHeader.value(
            cookie: "__csrf=csrf; MUSIC_U=embedded-token",
            musicU: "",
            vip: true,
            buildVersion: 123,
            requestID: "request"
        )
        precondition(embeddedFallbackCookie.contains("MUSIC_U=embedded-token"))
        precondition(embeddedFallbackCookie.contains("os=iPhone OS; appver=9.0.90"))
        let normalCookie = EAPICookieHeader.value(
            cookie: "__csrf=csrf",
            musicU: "music-token",
            vip: false,
            buildVersion: 123,
            requestID: "request"
        )
        precondition(normalCookie.contains("os=iPhone OS; appver=9.0.90"))
        precondition(!normalCookie.contains("MUSIC_U=music-token"))
        precondition(normalCookie.hasSuffix("requestId=request"))
        precondition(!normalCookie.contains("deviceId="))
        precondition(
            SessionCredentialIssue.detect(
                in: Data(#"{"code":301}"#.utf8),
                vip: false,
                musicU: ""
            ) == .cookie
        )
        precondition(
            SessionCredentialIssue.detect(
                in: Data(#"{"code":301}"#.utf8),
                vip: true,
                musicU: "vip-token"
            ) == .musicU
        )
        precondition(
            SessionCredentialIssue.detect(
                in: Data(#"{"code":400}"#.utf8),
                vip: true,
                musicU: "vip-token"
            ) == nil
        )
        let defaultCredentials = EAPITransport().credentials()
        precondition(defaultCredentials.cookie.isEmpty && defaultCredentials.musicU.isEmpty)
        let storedCredentials = try SessionCredentials(cookie: "stored=value", musicU: "stored-token")
        let injectedCredentials = EAPITransport(loadStoredCredentials: { storedCredentials }).credentials()
        precondition(injectedCredentials.cookie == "stored=value")
        precondition(injectedCredentials.musicU == "stored-token")
        let explicitCredentials = EAPITransport(
            cookie: "",
            musicU: nil,
            loadStoredCredentials: { preconditionFailure("Explicit credentials must bypass storage") }
        ).credentials()
        precondition(explicitCredentials.cookie.isEmpty && explicitCredentials.musicU.isEmpty)
        let throttled = HTTPURLResponse(
            url: URL(string: "https://example.com")!,
            statusCode: 429,
            httpVersion: nil,
            headerFields: ["Retry-After": "12.5"]
        )!
        precondition(EAPITransport.retryAfter(from: throttled) == 12.5)
        do {
            _ = try decodedJSONObject(Data(#"{"code":"400","msg":"bad request"}"#.utf8))
            preconditionFailure("String service codes must be rejected")
        } catch EAPIError.service(400, "bad request") {
        }
        print("EAPI golden checks passed")
    }

    private static func hexData(_ value: String) -> Data {
        Data(stride(from: 0, to: value.count, by: 2).map { offset in
            UInt8(value.dropFirst(offset).prefix(2), radix: 16)!
        })
    }
}
