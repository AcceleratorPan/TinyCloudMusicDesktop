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
                availableDates: [dates[0]],
                expectedCredentialRevision: 0
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

    @Test("A reload clears stale selection and forces dates and final detail once")
    func reloadIsConsumedOnce() {
        let dates = LiveMusicLibrary().decodeRecommendationHistoryDates([
            "data": ["dates": ["2025-07-31", "2025-07-30"]]
        ])
        var state = RecommendationHistoryRequestState()

        let initialForce = state.beginDates(reload: 0)
        #expect(!initialForce)
        state.acceptDates(dates, force: false)
        #expect(state.selectedDate == dates[0])
        let initialDetailForce = state.consumeDetailForce(for: dates[0])
        #expect(!initialDetailForce)

        let reloadForce = state.beginDates(reload: 1)
        #expect(reloadForce)
        #expect(state.selectedDate == nil)
        state.acceptDates(dates, force: true)
        let detailForce = state.consumeDetailForce(for: dates[0])
        let repeatedDetailForce = state.consumeDetailForce(for: dates[0])
        let repeatedReloadForce = state.beginDates(reload: 1)
        #expect(detailForce)
        #expect(!repeatedDetailForce)
        #expect(!repeatedReloadForce)
    }

    @Test("Delayed account requests cannot update the current account")
    func accountRace() {
        var request = LatestRecommendationRequest()
        let accountA = request.begin()
        let accountB = request.begin()

        #expect(!request.accepts(
            accountA,
            accountID: 1,
            credentialRevision: 1,
            currentAccountID: 2,
            currentCredentialRevision: 2
        ))
        #expect(request.accepts(
            accountB,
            accountID: 2,
            credentialRevision: 2,
            currentAccountID: 2,
            currentCredentialRevision: 2
        ))
        var accountBLoading = true
        var accountBSongs = [42]
        if request.accepts(
            accountA,
            accountID: 1,
            credentialRevision: 1,
            currentAccountID: 2,
            currentCredentialRevision: 2
        ) {
            accountBLoading = false
            accountBSongs = [1]
        }
        #expect(accountBLoading)
        #expect(accountBSongs == [42])

        let accountAAgain = request.begin()
        #expect(!request.accepts(
            accountB,
            accountID: 2,
            credentialRevision: 2,
            currentAccountID: 1,
            currentCredentialRevision: 3
        ))
        #expect(request.accepts(
            accountAAgain,
            accountID: 1,
            credentialRevision: 3,
            currentAccountID: 1,
            currentCredentialRevision: 3
        ))
        #expect(!request.accepts(
            accountAAgain,
            accountID: 1,
            credentialRevision: 3,
            currentAccountID: 1,
            currentCredentialRevision: 4
        ))
    }

    @MainActor
    @Test("Production loader consumes initial and reload force once")
    func productionLoaderForceSequence() async throws {
        let dates = fixtureDates("2025-07-31", "2025-07-30")
        let probe = RecommendationLoaderProbe(dates: dates)
        let reloadGate = RecommendationGate<[RecommendationHistoryDate]>()
        let loader = RecommendationHistoryLoader()
        let credential = RecommendationCredentialContext()

        let initialDates = try #require(loader.startDates(
            accountID: 1,
            credentialRevision: credential.revision,
            reload: 0,
            currentAccountID: { 1 },
            currentCredentialRevision: { credential.revision }
        ) { force in
            await probe.loadDates(force: force)
        })
        await initialDates.value
        let initialSongs = try #require(loader.startSongs(
            accountID: 1,
            credentialRevision: credential.revision,
            currentAccountID: { 1 },
            currentCredentialRevision: { credential.revision }
        ) { date, available, force in
            await probe.loadSongs(date: date, availableDates: available, force: force)
        })
        await initialSongs.value

        let reloadedDates = try #require(loader.startDates(
            accountID: 1,
            credentialRevision: credential.revision,
            reload: 1,
            currentAccountID: { 1 },
            currentCredentialRevision: { credential.revision }
        ) { force in
            await probe.recordDates(force: force)
            return await reloadGate.wait()
        })
        await reloadGate.waitUntilEntered()
        let prematureDetail = loader.startSongs(
            accountID: 1,
            credentialRevision: credential.revision,
            currentAccountID: { 1 },
            currentCredentialRevision: { credential.revision }
        ) { date, available, force in
            await probe.loadSongs(date: date, availableDates: available, force: force)
        }
        #expect(prematureDetail == nil)
        #expect(await probe.detailForces == [false])
        await reloadGate.release(dates)
        await reloadedDates.value
        let reloadedSongs = try #require(loader.startSongs(
            accountID: 1,
            credentialRevision: credential.revision,
            currentAccountID: { 1 },
            currentCredentialRevision: { credential.revision }
        ) { date, available, force in
            await probe.loadSongs(date: date, availableDates: available, force: force)
        })
        await reloadedSongs.value

        let recomputedDates = try #require(loader.startDates(
            accountID: 1,
            credentialRevision: credential.revision,
            reload: 1,
            currentAccountID: { 1 },
            currentCredentialRevision: { credential.revision }
        ) { force in
            await probe.loadDates(force: force)
        })
        await recomputedDates.value
        let recomputedSongs = try #require(loader.startSongs(
            accountID: 1,
            credentialRevision: credential.revision,
            currentAccountID: { 1 },
            currentCredentialRevision: { credential.revision }
        ) { date, available, force in
            await probe.loadSongs(date: date, availableDates: available, force: force)
        })
        await recomputedSongs.value

        #expect(await probe.datesForces == [false, true, false])
        #expect(await probe.detailForces == [false, true, false])
        #expect(loader.selectedDate == dates[0])
        #expect(loader.songs.map(\.id) == [42])
        #expect(loader.acceptedDatesRevision == 3)
        #expect(!loader.isLoadingDates)
        #expect(!loader.isLoadingSongs)
        #expect(!loader.hasDatesTask)
        #expect(!loader.hasSongsTask)
    }

    @MainActor
    @Test("Old account dates and detail cannot commit or finish replacement tasks")
    func productionLoaderAccountRace() async throws {
        let accountADates = fixtureDates("2024-01-01")
        let accountBDates = fixtureDates("2025-01-01")
        let datesGate = RecommendationGate<[RecommendationHistoryDate]>()
        let currentDatesGate = RecommendationGate<[RecommendationHistoryDate]>()
        let detailGate = RecommendationGate<[Song]>()
        let currentDetailGate = RecommendationGate<[Song]>()
        let loader = RecommendationHistoryLoader()
        let credential = RecommendationCredentialContext()

        let oldDates = try #require(loader.startDates(
            accountID: 1,
            credentialRevision: credential.revision,
            reload: 0,
            currentAccountID: { 1 },
            currentCredentialRevision: { credential.revision }
        ) { _ in
            await datesGate.wait()
        })
        await datesGate.waitUntilEntered()
        let currentDates = try #require(loader.startDates(
            accountID: 2,
            credentialRevision: credential.revision,
            reload: 0,
            currentAccountID: { 2 },
            currentCredentialRevision: { credential.revision }
        ) { _ in
            await currentDatesGate.wait()
        })
        await currentDatesGate.waitUntilEntered()

        await datesGate.release(accountADates)
        await oldDates.value
        #expect(loader.dates.isEmpty)
        #expect(loader.datesError == nil)
        #expect(loader.isLoadingDates)
        #expect(loader.hasDatesTask)

        await currentDatesGate.release(accountBDates)
        await currentDates.value
        #expect(loader.dates == accountBDates)
        #expect(!loader.hasDatesTask)

        let resetDates = try #require(loader.startDates(
            accountID: 1,
            credentialRevision: credential.revision,
            reload: 0,
            currentAccountID: { 1 },
            currentCredentialRevision: { credential.revision }
        ) { _ in accountADates })
        await resetDates.value
        let oldDetail = try #require(loader.startSongs(
            accountID: 1,
            credentialRevision: credential.revision,
            currentAccountID: { 1 },
            currentCredentialRevision: { credential.revision }
        ) { _, _, _ in
            await detailGate.wait()
        })
        await detailGate.waitUntilEntered()
        let latestDates = try #require(loader.startDates(
            accountID: 2,
            credentialRevision: credential.revision,
            reload: 0,
            currentAccountID: { 2 },
            currentCredentialRevision: { credential.revision }
        ) { _ in accountBDates })
        await latestDates.value
        let currentDetail = try #require(loader.startSongs(
            accountID: 2,
            credentialRevision: credential.revision,
            currentAccountID: { 2 },
            currentCredentialRevision: { credential.revision }
        ) { _, _, _ in
            await currentDetailGate.wait()
        })
        await currentDetailGate.waitUntilEntered()

        await detailGate.release([fixtureSong(1)])
        await oldDetail.value
        #expect(loader.dates == accountBDates)
        #expect(loader.songs.isEmpty)
        #expect(loader.songsError == nil)
        #expect(loader.isLoadingSongs)
        #expect(loader.hasSongsTask)

        await currentDetailGate.release([fixtureSong(42)])
        await currentDetail.value
        #expect(loader.songs.map(\.id) == [42])
        #expect(!loader.isLoadingSongs)
        #expect(!loader.hasSongsTask)
    }

    @MainActor
    @Test("Current account and credential changes fence dates and detail commits")
    func productionLoaderCredentialRace() async throws {
        let dates = fixtureDates("2025-07-31")
        let accountGate = RecommendationGate<[RecommendationHistoryDate]>()
        let datesGate = RecommendationGate<[RecommendationHistoryDate]>()
        let detailGate = RecommendationGate<[Song]>()
        let credential = RecommendationCredentialContext()
        let loader = RecommendationHistoryLoader()

        let staleAccountDates = try #require(loader.startDates(
            accountID: 1,
            credentialRevision: credential.revision,
            reload: 0,
            currentAccountID: { credential.accountID },
            currentCredentialRevision: { credential.revision }
        ) { _ in await accountGate.wait() })
        await accountGate.waitUntilEntered()
        credential.accountID = 2
        await accountGate.release(fixtureDates("2024-01-01"))
        await staleAccountDates.value
        #expect(loader.dates.isEmpty)
        #expect(!loader.isLoadingDates)
        #expect(!loader.hasDatesTask)
        credential.accountID = 1

        let staleDates = try #require(loader.startDates(
            accountID: 1,
            credentialRevision: credential.revision,
            reload: 0,
            currentAccountID: { credential.accountID },
            currentCredentialRevision: { credential.revision }
        ) { _ in await datesGate.wait() })
        await datesGate.waitUntilEntered()
        credential.revision &+= 1
        await datesGate.release(dates)
        await staleDates.value
        #expect(loader.dates.isEmpty)
        #expect(loader.selectedDate == nil)
        #expect(loader.datesError == nil)

        let currentDates = try #require(loader.startDates(
            accountID: 1,
            credentialRevision: credential.revision,
            reload: 0,
            currentAccountID: { credential.accountID },
            currentCredentialRevision: { credential.revision }
        ) { _ in dates })
        await currentDates.value
        let staleDetail = try #require(loader.startSongs(
            accountID: 1,
            credentialRevision: credential.revision,
            currentAccountID: { credential.accountID },
            currentCredentialRevision: { credential.revision }
        ) { _, _, _ in await detailGate.wait() })
        await detailGate.waitUntilEntered()
        credential.revision &+= 1
        await detailGate.release([fixtureSong(42)])
        await staleDetail.value

        #expect(loader.songs.isEmpty)
        #expect(loader.songsError == nil)
        #expect(!loader.isLoadingDates)
        #expect(!loader.isLoadingSongs)
        #expect(!loader.hasDatesTask)
        #expect(!loader.hasSongsTask)
    }
}

@MainActor
private final class RecommendationCredentialContext {
    var accountID: Int64? = 1
    var revision: UInt64 = 1
}

private actor RecommendationLoaderProbe {
    private let dates: [RecommendationHistoryDate]
    private(set) var datesForces: [Bool] = []
    private(set) var detailForces: [Bool] = []

    init(dates: [RecommendationHistoryDate]) { self.dates = dates }

    func loadDates(force: Bool) -> [RecommendationHistoryDate] {
        recordDates(force: force)
        return dates
    }

    func recordDates(force: Bool) { datesForces.append(force) }

    func loadSongs(
        date: RecommendationHistoryDate,
        availableDates: [RecommendationHistoryDate],
        force: Bool
    ) -> [Song] {
        detailForces.append(force)
        return availableDates.contains(date) ? [fixtureSong(42)] : []
    }
}

private actor RecommendationGate<Value: Sendable> {
    private var entered = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var valueWaiters: [CheckedContinuation<Value, Never>] = []
    private var releasedValue: Value?

    func wait() async -> Value {
        entered = true
        let waiters = entryWaiters
        entryWaiters = []
        waiters.forEach { $0.resume() }
        if let releasedValue { return releasedValue }
        return await withCheckedContinuation { valueWaiters.append($0) }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }

    func release(_ value: Value) {
        releasedValue = value
        let waiters = valueWaiters
        valueWaiters = []
        waiters.forEach { $0.resume(returning: value) }
    }
}

private func fixtureDates(_ values: String...) -> [RecommendationHistoryDate] {
    LiveMusicLibrary().decodeRecommendationHistoryDates(["data": ["dates": values]])
}

private func fixtureSong(_ id: Int64) -> Song {
    Song(
        id: id,
        name: "Song \(id)",
        artists: [],
        album: AlbumSummary(id: 0, name: "", artwork: Artwork(symbol: "music.note", accent: .red)),
        duration: .seconds(1)
    )
}
