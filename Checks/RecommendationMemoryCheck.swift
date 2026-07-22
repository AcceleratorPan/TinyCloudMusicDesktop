import Foundation

@main
enum RecommendationMemoryCheck {
    static func main() async throws {
        let library = LiveMusicLibrary()
        let dates = library.decodeRecommendationHistoryDates([
            "data": ["dates": ["2024-02-29", "2024-02-30", "2024-02-29", "2024-01-03"]]
        ])
        precondition(dates.map(\.value) == ["2024-02-29", "2024-01-03"])

        do {
            _ = try await library.historicalDailyRecommendations(
                on: dates[0],
                availableDates: []
            )
            preconditionFailure("An unavailable history date reached the network layer")
        } catch EAPIError.invalidPayload {
        }

        let songs = library.decodeHistoricalDailyRecommendations([
            "data": ["songs": [[
                "id": 41,
                "name": "First",
                "ar": [["id": 7, "name": "Artist"]],
                "al": ["id": 8, "name": "Album"],
                "dt": 180_000
            ]]]
        ])
        precondition(songs.map(\.id) == [41] && songs[0].duration == .seconds(180))

        var request = LatestRecommendationRequest()
        let old = request.begin()
        let latest = request.begin()
        precondition(!request.accepts(old) && request.accepts(latest))
        print("Recommendation memory check passed")
    }
}
