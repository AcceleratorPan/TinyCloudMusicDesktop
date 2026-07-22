import Foundation
import Testing
@testable import TinyCloudMusic

@Suite("Recommendation history")
struct RecommendationMemoryTests {
    @Test("History dates are strict, ordered, and unique")
    func historyDates() {
        let dates = LiveMusicLibrary().decodeRecommendationHistoryDates([
            "data": [
                "dates": [
                    "2024-02-29", "2024-02-30", "2024-02-29",
                    "2024-01-03", "03-01-2024", "2025-1-02"
                ]
            ]
        ])
        #expect(dates.map(\.value) == ["2024-02-29", "2024-01-03"])
    }

    @Test("History detail rejects dates not returned by the server")
    func rejectsUnknownHistoryDate() async {
        let dates = LiveMusicLibrary().decodeRecommendationHistoryDates([
            "data": ["dates": ["2024-01-01", "2024-01-02"]]
        ])
        do {
            _ = try await LiveMusicLibrary().historicalDailyRecommendations(
                on: dates[1],
                availableDates: [dates[0]]
            )
            Issue.record("An unavailable date reached the network layer")
        } catch EAPIError.invalidPayload {
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("History songs reuse the shared song decoder and form a queue")
    func historySongs() {
        let songs = LiveMusicLibrary().decodeHistoricalDailyRecommendations([
            "data": [
                "songs": [
                    [
                        "id": 41,
                        "name": "First",
                        "ar": [["id": 7, "name": "Artist"]],
                        "al": ["id": 8, "name": "Album", "picUrl": "https://example.com/1.jpg"],
                        "dt": 180_000
                    ],
                    [
                        "id": 42,
                        "name": "Second",
                        "ar": [["id": 9, "name": "Artist 2"]],
                        "al": ["id": 10, "name": "Album 2"],
                        "dt": 200_000
                    ]
                ]
            ]
        ])
        let queue = PlaybackQueuePlan.make(
            selectedSongID: 42,
            visibleSongIDs: songs.map(\.id),
            allSongIDs: nil
        )
        #expect(songs.map(\.id) == [41, 42])
        #expect(songs.first?.duration == .seconds(180))
        #expect(queue == PlaybackQueuePlan(songIDs: [41, 42], startIndex: 1))
    }

    @Test("Only the latest selector request can update state")
    func latestRequestWins() {
        var request = LatestRecommendationRequest()
        let old = request.begin()
        let latest = request.begin()
        #expect(!request.accepts(old))
        #expect(request.accepts(latest))
    }
}
