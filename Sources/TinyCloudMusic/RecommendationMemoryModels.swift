import Foundation

struct RecommendationHistoryDate: Identifiable, Equatable, Hashable, Sendable {
    var id: String { value }
    let value: String

    fileprivate init(value: String) {
        self.value = value
    }
}

struct LatestRecommendationRequest: Sendable {
    private(set) var generation = 0

    mutating func begin() -> Int {
        generation &+= 1
        return generation
    }

    func accepts(_ generation: Int) -> Bool {
        self.generation == generation
    }
}

enum RecommendationMemoryDecoder {
    static func historyDates(_ root: [String: Any]) -> [RecommendationHistoryDate] {
        let data = root.object("data")
        let values = (data["dates"] as? [String]) ?? (root["dates"] as? [String]) ?? []
        var seen = Set<String>()
        return values.compactMap { value in
            guard isValidDate(value), seen.insert(value).inserted else { return nil }
            return RecommendationHistoryDate(value: value)
        }
    }

    private static func isValidDate(_ value: String) -> Bool {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        guard let date = formatter.date(from: value) else { return false }
        return formatter.string(from: date) == value
    }

}
