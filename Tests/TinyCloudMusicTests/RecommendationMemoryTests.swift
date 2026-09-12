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

    @Test("Library bootstrap reuses confirmed user and playlists for liked songs")
    func libraryBootstrapReusesConfirmedUserAndPlaylists() throws {
        let load = try sourceSlice(
            iosLibrarySource(),
            from: "private func load(force: Bool) async {\n        guard let library, let extras",
            to: "private func publishLibraryProgress("
        )
        let store = try #require(load.range(of: "model.storeLibrarySnapshot(snapshot"))
        let likedSongs = try #require(load.range(of: "await model.refreshLikedSongIDs("))

        #expect(load.contains("let snapshot = LibrarySnapshot("))
        #expect(store.lowerBound < likedSongs.lowerBound)
        #expect(load.contains("userID: snapshot.user.id"))
        #expect(load.contains("playlists: snapshot.playlists"))
        #expect(load.contains("credentialRevision: revision"))
        #expect(!load.contains("refreshAccountState"))
    }

    @Test("iOS history tasks have separate identities, retries, and terminal states")
    func historyTaskIdentitiesAndTerminalStates() throws {
        let source = try iosLibrarySource()
        let identities = try sourceSlice(
            source,
            from: "private struct IOSRecommendationDatesTaskIdentity",
            to: "struct IOSRecommendationHistoryView"
        )
        let history = try sourceSlice(
            source,
            from: "struct IOSRecommendationHistoryView",
            to: "struct IOSListeningFootprintsView"
        )
        let picker = try sourceSlice(history, from: "Picker(\"日期\"", to: ".pickerStyle(.menu)")
        let loadDates = try sourceSlice(
            history,
            from: "private func loadDates(",
            to: "private func loadSongs("
        )
        let loadSongs = try sourceSlice(
            history,
            from: "private func loadSongs(",
            to: "private func acceptsDates("
        )

        #expect(identities.contains("let accountID: Int64?"))
        #expect(identities.components(separatedBy: "let credentialRevision: UInt64").count == 3)
        #expect(identities.contains("let reloadRevision: Int"))
        #expect(identities.contains("let acceptedDatesRevision: Int"))
        #expect(identities.contains("let selectedDate: RecommendationHistoryDate?"))
        #expect(identities.contains("let detailRetryRevision: Int"))
        #expect(history.contains(".task(id: datesIdentity)"))
        #expect(history.contains(".task(id: songsIdentity)"))
        #expect(history.components(separatedBy: ".task(id:").count == 3)
        #expect(!picker.contains("Task {"))
        #expect(!history.contains("Task {"))
        #expect(!loadDates.contains("loadSongs("))
        #expect(loadDates.contains("requestState.beginDates(reload:"))
        #expect(loadDates.contains("decodeRecommendationHistoryDates(root)"))
        #expect(loadDates.contains("requestState.acceptDates(values, force: force)"))
        #expect(loadDates.contains("acceptedDatesRevision &+= 1"))
        #expect(loadDates.components(separatedBy: "guard acceptsDates(identity, generation: generation)").count == 3)
        #expect(loadSongs.contains("requestState.consumeDetailForce(for: selectedDate)"))
        #expect(loadSongs.contains("decodeHistoricalDailyRecommendations(root)"))
        #expect(loadSongs.components(separatedBy: "guard acceptsSongs(identity, generation: generation)").count == 3)
        #expect(history.contains("datesReloadRevision &+= 1"))
        #expect(history.contains("detailRetryRevision &+= 1"))
        #expect(history.contains("IOSLibraryEmptyState(title: \"暂无历史日推\""))
        #expect(history.components(separatedBy: "catch is CancellationError").count == 3)
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

    @MainActor
    @Test("Selector replacement cancels the old historical request")
    func selectorReplacementCancelsHistoricalRequest() async throws {
        let dates = fixtureDates("2025-07-31", "2025-07-30")
        let loader = RecommendationHistoryLoader()
        let credential = RecommendationCredentialContext()
        let cancellation = RecommendationCancellationProbe()
        let oldGate = RecommendationGate<Void>()
        let currentGate = RecommendationGate<[Song]>()

        let initialDates = try #require(loader.startDates(
            accountID: 1,
            credentialRevision: credential.revision,
            reload: 0,
            currentAccountID: { 1 },
            currentCredentialRevision: { credential.revision }
        ) { _ in dates })
        await initialDates.value

        loader.selectedDate = dates[0]
        let old = try #require(loader.startSongs(
            accountID: 1,
            credentialRevision: credential.revision,
            currentAccountID: { 1 },
            currentCredentialRevision: { credential.revision }
        ) { date, _, _ in
            #expect(date == dates[0])
            return try await cancellation.load(after: oldGate)
        })
        await oldGate.waitUntilEntered()

        loader.selectedDate = dates[1]
        let current = try #require(loader.startSongs(
            accountID: 1,
            credentialRevision: credential.revision,
            currentAccountID: { 1 },
            currentCredentialRevision: { credential.revision }
        ) { date, _, _ in
            #expect(date == dates[1])
            return await currentGate.wait()
        })
        await cancellation.waitUntilCancelled()
        await oldGate.release(())
        await currentGate.waitUntilEntered()
        await old.value

        let oldSnapshot = await cancellation.snapshot()
        #expect(oldSnapshot.cancellations == 1)
        #expect(oldSnapshot.parses == 0)
        #expect(loader.songs.isEmpty)
        #expect(loader.songsError == nil)
        #expect(loader.isLoadingSongs)
        #expect(loader.hasSongsTask)

        await currentGate.release([fixtureSong(42)])
        await current.value
        #expect(loader.songs.map(\.id) == [42])
        #expect(loader.songsError == nil)
        #expect(!loader.isLoadingSongs)
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

private actor RecommendationCancellationProbe {
    private var cancellations = 0
    private var parses = 0
    private var cancellationWaiters: [CheckedContinuation<Void, Never>] = []

    func load(after gate: RecommendationGate<Void>) async throws -> [Song] {
        try await withTaskCancellationHandler {
            await gate.wait()
            try Task.checkCancellation()
            parses += 1
            return [fixtureSong(1)]
        } onCancel: {
            Task { await self.recordCancellation() }
        }
    }

    func waitUntilCancelled() async {
        guard cancellations == 0 else { return }
        await withCheckedContinuation { cancellationWaiters.append($0) }
    }

    func snapshot() -> (cancellations: Int, parses: Int) {
        (cancellations, parses)
    }

    private func recordCancellation() {
        cancellations += 1
        let waiters = cancellationWaiters
        cancellationWaiters = []
        waiters.forEach { $0.resume() }
    }
}

private func iosLibrarySource() throws -> String {
    let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    return try String(
        contentsOf: repositoryRoot.appending(path: "iOS/TinyCloudMusicIOS/UI/LibraryMedia/IOSLibraryView.swift"),
        encoding: .utf8
    )
}

private func sourceSlice(_ source: String, from start: String, to end: String) throws -> String {
    let lower = try #require(source.range(of: start)?.lowerBound)
    let upper = try #require(source.range(of: end, range: lower..<source.endIndex)?.lowerBound)
    return String(source[lower..<upper])
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
