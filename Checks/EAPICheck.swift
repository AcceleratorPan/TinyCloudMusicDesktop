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
        let ncblBody = Data("1700000000\u{1}_plv\u{1}{\"id\":\"1\"}".utf8)
        let zstandardFrame = NCBLPlaybackReport.zstandardFrame(ncblBody)
        precondition(
            zstandardFrame == hexData(
                "28b52ffd201ad1000031373030303030303030015f706c76017b226964223a2231227d"
            )
        )
        for size in [0, 256, 128 * 1_024 + 1] {
            let input = Data(repeating: 0x5a, count: size)
            try verifyZstandardInterop(
                NCBLPlaybackReport.zstandardFrame(input),
                expectedByte: 0x5a,
                expectedCount: size
            )
        }
        let ncblPayload = try NCBLPlaybackReport.encryptedPayload(
            meta: Data(#"{"os":"pc"}"#.utf8),
            body: ncblBody,
            keyA: hexData("000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"),
            uuid: hexData("00112233445566778899aabbccddeeff"),
            baseSequence: 0x12345678
        )
        precondition(
            ncblPayload == hexData(
                "4e43424c03000000550000112233445566778899aabbccddeeffdda20437ce173c34273cb03bffb85db8f3ce53bc2f1334a752303d26890094af78563412785634122900000043430b007549f8dc25e4fea71f7441230078563412c8506c01fee16ea36607ffbdd22e20bfe97bd690631c9442c707e4e11ef43367dcec14"
            )
        )
        let plv = try playbackRecord(
            try NCBLPlaybackReport.plaintextRecord(
                cookie: "MUSIC_U=test; appver=3.1.35; versioncode=205293",
                songID: 17,
                sourceID: 23,
                totalSeconds: 300,
                event: .start,
                timestampSeconds: 1_700_000_000,
                eventMilliseconds: 1_700_000_000_000
            )
        )
        precondition(
            plv.action == "_plv"
                && plv.json.string("id") == "17"
                && plv.json.string("sourceId") == "23"
                && plv.json.int("resource_time") == 300
                && plv.json.int("app_mode") == 2
        )
        let pld = try playbackRecord(
            try NCBLPlaybackReport.plaintextRecord(
                cookie: "MUSIC_U=test; appver=3.1.35; versioncode=205293",
                songID: 17,
                sourceID: 23,
                totalSeconds: 300,
                event: .play(seconds: 42),
                timestampSeconds: 1_700_000_000,
                eventMilliseconds: 1_700_000_000_000
            )
        )
        precondition(
            pld.action == "_pld"
                && pld.json.int("time") == 42
                && pld.json.int("realtime") == 42
                && pld.json.string("end") == "interrupt"
                && pld.json.int("app_mode") == 1
        )
        try NCBLPlaybackReport.validateResponse(
            Data(#"{"code":200,"data":{"successfiles":["op_test"]},"message":""}"#.utf8),
            fileName: "op_test"
        )
        do {
            try NCBLPlaybackReport.validateResponse(
                Data(#"{"code":200,"data":{"successfiles":[]},"message":""}"#.utf8),
                fileName: "op_test"
            )
            preconditionFailure("NCBL responses must confirm the uploaded file")
        } catch EAPIError.service(200, _) {
        }
        do {
            try NCBLPlaybackReport.validateResponse(
                Data(#"{"code":201,"data":{"successfiles":["op_test"]}}"#.utf8),
                fileName: "op_test"
            )
            preconditionFailure("NCBL responses must use the exact success code")
        } catch EAPIError.service(201, _) {
        }
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
            cookie: "QR_SESSION=qr-session; __csrf=csrf; MUSIC_U=embedded-token; os=pc",
            musicU: "vip-token",
            vip: true,
            buildVersion: 123,
            requestID: "request",
            iPhoneClient: true
        )
        precondition(iPhoneVIPCookie.contains("os=iPhone OS; appver=9.0.90"))
        precondition(iPhoneVIPCookie.contains("MUSIC_U=vip-token"))
        precondition(!iPhoneVIPCookie.contains("embedded-token"))
        precondition(!iPhoneVIPCookie.contains("QR_SESSION="))
        precondition(!iPhoneVIPCookie.contains("__csrf="))
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
        let defaultCredentials = try EAPITransport().credentials()
        precondition(defaultCredentials.cookie.isEmpty && defaultCredentials.musicU.isEmpty)
        let storedCredentials = try SessionCredentials(
            cookie: "MUSIC_U=stored-token",
            musicU: "stored-vip-token",
            deviceID: "stored-device"
        )
        let storedTransport = EAPITransport(loadStoredCredentials: { storedCredentials })
        let injectedCredentials = try storedTransport.credentials()
        precondition(injectedCredentials.cookie == "MUSIC_U=stored-token")
        precondition(injectedCredentials.musicU == "stored-vip-token")
        let credentialRevision = storedTransport.credentialSnapshotValue().revision
        let playbackCredentials = try storedTransport.playbackCredentials(
            expectedCredentialRevision: credentialRevision
        )
        precondition(playbackCredentials.deviceID == "stored-device")
        let repeatedPlaybackCredentials = try storedTransport.playbackCredentials(
            expectedCredentialRevision: credentialRevision
        )
        precondition(playbackCredentials.clientID == repeatedPlaybackCredentials.clientID)
        let playbackUpload = try NCBLPlaybackReport.upload(
            cookie: playbackCredentials.cookie,
            deviceID: playbackCredentials.deviceID,
            clientID: playbackCredentials.clientID,
            songID: 17,
            sourceID: 23,
            totalSeconds: 300,
            event: .start
        )
        let playbackCookie = playbackUpload.request.value(forHTTPHeaderField: "Cookie") ?? ""
        precondition(NeteaseCookieHeader.value(named: "deviceId", in: playbackCookie) == "stored-device")
        precondition(
            NeteaseCookieHeader.value(named: "WNMCID", in: playbackCookie)
                == playbackCredentials.clientID
        )
        let explicitCredentials = try EAPITransport(
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

    private static func playbackRecord(_ data: Data) throws -> (action: String, json: [String: Any]) {
        let fields = String(decoding: data, as: UTF8.self)
            .split(separator: "\u{1}", maxSplits: 2, omittingEmptySubsequences: false)
        guard fields.count == 3,
              let json = try JSONSerialization.jsonObject(with: Data(fields[2].utf8)) as? [String: Any]
        else { throw EAPIError.invalidPayload }
        return (String(fields[1]), json)
    }

    private static func verifyZstandardInterop(
        _ frame: Data,
        expectedByte: UInt8,
        expectedCount: Int
    ) throws {
        let process = Process()
        let input = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            "node", "-e",
            """
            const fs = require('node:fs'), zlib = require('node:zlib')
            if (typeof zlib.zstdDecompressSync !== 'function') process.exit(2)
            const decoded = zlib.zstdDecompressSync(fs.readFileSync(0))
            const byte = Number(process.argv[1]), count = Number(process.argv[2])
            process.exit(decoded.length === count && decoded.every(value => value === byte) ? 0 : 1)
            """,
            String(expectedByte), String(expectedCount)
        ]
        process.standardInput = input
        try process.run()
        input.fileHandleForWriting.write(frame)
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        precondition(
            process.terminationStatus == 0,
            "Node zstdDecompressSync must decode the Swift Zstandard frame"
        )
    }
}
