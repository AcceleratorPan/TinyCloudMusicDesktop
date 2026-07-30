import Foundation

@main
private enum ListenTogetherFixtureRedactionCheck {
    static func main() {
        let raw = Data(#"{"data":{"creatorId":42,"creatorUid":42,"acceptUid":42,"roomInfo":{"roomId":"real-room","roomUsers":[{"userId":42,"nickname":"secret-name","avatarUrl":"https://secret"}]}},"commandType":"GOTO","message":"secret-message"}"#.utf8)
        guard let root = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
              let value = sanitize(root),
              let data = try? JSONSerialization.data(withJSONObject: value),
              let text = String(data: data, encoding: .utf8)
        else { exit(1) }
        let safe = !text.contains("real-room")
            && !text.contains("secret-name")
            && !text.contains("https://secret")
            && !text.contains("secret-message")
            && text.contains("GOTO")
        print(safe ? "Listen together fixture redaction check passed" : "Listen together fixture redaction check failed")
        exit(safe ? 0 : 1)
    }

    private static func sanitize(_ value: Any, key: String = "") -> Any? {
        if let object = value as? [String: Any] {
            return object.reduce(into: [String: Any]()) { result, field in
                result[field.key] = sanitize(field.value, key: field.key)
            }
        }
        if let values = value as? [Any] { return values.compactMap { sanitize($0, key: key) } }
        let key = key.lowercased()
        if let text = value as? String {
            if key == "commandtype" { return text }
            return "<string>"
        }
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue }
            return key.hasSuffix("id") ? 1_001 : number
        }
        return NSNull()
    }
}
