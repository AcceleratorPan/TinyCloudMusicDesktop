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

    func accepts(
        _ generation: Int,
        accountID: Int64,
        credentialRevision: UInt64,
        currentAccountID: Int64?,
        currentCredentialRevision: UInt64
    ) -> Bool {
        accepts(generation)
            && accountID == currentAccountID
            && credentialRevision == currentCredentialRevision
    }
}

struct RecommendationHistoryRequestState: Sendable {
    var selectedDate: RecommendationHistoryDate?
    private var consumedReload = 0
    private var forcedDetailDate: RecommendationHistoryDate?

    mutating func beginDates(reload: Int) -> Bool {
        let force = reload != consumedReload
        consumedReload = reload
        selectedDate = nil
        forcedDetailDate = nil
        return force
    }

    mutating func acceptDates(_ dates: [RecommendationHistoryDate], force: Bool) {
        selectedDate = dates.first
        forcedDetailDate = force ? selectedDate : nil
    }

    mutating func consumeDetailForce(for date: RecommendationHistoryDate) -> Bool {
        guard forcedDetailDate == date else { return false }
        forcedDetailDate = nil
        return true
    }
}

enum RecommendationMemoryDecoder {
    static func historyDates(_ root: [String: Any]) -> [RecommendationHistoryDate] {
        let data = root.object("data")
        let values = (data["dates"] as? [String]) ?? (root["dates"] as? [String]) ?? []
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        var seen = Set<String>()
        return values.compactMap { value in
            guard isValidDate(value, formatter: formatter), seen.insert(value).inserted else {
                return nil
            }
            return RecommendationHistoryDate(value: value)
        }
    }

    private static func isValidDate(_ value: String, formatter: DateFormatter) -> Bool {
        guard let date = formatter.date(from: value) else { return false }
        return formatter.string(from: date) == value
    }

}
