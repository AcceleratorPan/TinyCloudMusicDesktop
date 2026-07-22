import Foundation

@main
enum LiveAuthenticationCheck {
    static func main() async throws {
        let transport = EAPITransport(cookie: "", musicU: "")
        let guest: NeteaseAuthenticationContext
        do {
            guest = try await transport.registerAnonymous()
        } catch {
            diagnose(stage: "guest-registration", error: error)
            throw error
        }
        let hasGuestCookie = !NeteaseCookieHeader.value(named: "MUSIC_A", in: guest.cookie).isEmpty
        let hasValidDeviceID = guest.deviceID.count == 52

        let keyResponse: EAPIHTTPResponse
        do {
            keyResponse = try await transport.requestAuthentication(
                EAPIEndpoint(
                    "/eapi/login/qrcode/unikey",
                    signing: "/api/login/qrcode/unikey",
                    host: "https://interface.music.163.com"
                ),
                payload: ["type": 3],
                context: guest
            )
        } catch {
            diagnose(stage: "qr-key", error: error)
            throw error
        }
        let keyRoot = try JSONSerialization.jsonObject(with: keyResponse.data) as? [String: Any]
        let nestedKey = keyRoot?.object("data").string("unikey") ?? ""
        let key = nestedKey.isEmpty ? keyRoot?.string("unikey") ?? "" : nestedKey
        guard hasGuestCookie, hasValidDeviceID, !key.isEmpty else {
            throw EAPIError.invalidResponse
        }

        let checkResponse: EAPIHTTPResponse
        do {
            checkResponse = try await transport.requestAuthentication(
                EAPIEndpoint(
                    "/eapi/login/qrcode/client/login",
                    signing: "/api/login/qrcode/client/login",
                    host: "https://interface.music.163.com"
                ),
                payload: ["key": key, "type": 3],
                context: guest,
                userAgent: "pc"
            )
        } catch {
            diagnose(stage: "qr-check", error: error)
            throw error
        }
        guard let checkRoot = try JSONSerialization.jsonObject(with: checkResponse.data) as? [String: Any]
        else { throw EAPIError.invalidResponse }
        let status = checkRoot.int("code")
        guard status == 801 else {
            throw EAPIError.service(code: status, message: "fresh QR code did not enter waiting-scan state")
        }
        print("Live authentication check passed: guest=true deviceID52=true qrStatus=801")
    }

    private static func diagnose(stage: String, error: Error) {
        let line = "Live authentication check failed: stage=\(stage) error=\(error.localizedDescription)\n"
        try? FileHandle.standardError.write(contentsOf: Data(line.utf8))
    }
}
