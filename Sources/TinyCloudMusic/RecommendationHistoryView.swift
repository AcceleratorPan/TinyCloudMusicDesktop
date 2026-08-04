import Observation
import SwiftUI

@MainActor
@Observable
final class RecommendationHistoryLoader {
    private(set) var dates: [RecommendationHistoryDate] = []
    var selectedDate: RecommendationHistoryDate? {
        get { requestState.selectedDate }
        set { requestState.selectedDate = newValue }
    }
    private(set) var songs: [Song] = []
    private(set) var acceptedDatesRevision = 0
    private(set) var isLoadingDates = true
    private(set) var isLoadingSongs = false
    private(set) var datesError: String?
    private(set) var songsError: String?

    private var requestState = RecommendationHistoryRequestState()
    @ObservationIgnored private var loadedAccountID: Int64?
    @ObservationIgnored private var loadedCredentialRevision: UInt64?
    @ObservationIgnored private var datesRequest = LatestRecommendationRequest()
    @ObservationIgnored private var songsRequest = LatestRecommendationRequest()
    @ObservationIgnored private var datesTask: Task<Void, Never>?
    @ObservationIgnored private var songsTask: Task<Void, Never>?
    @ObservationIgnored private var datesTaskID: UUID?
    @ObservationIgnored private var songsTaskID: UUID?

    var hasDatesTask: Bool { datesTask != nil }
    var hasSongsTask: Bool { songsTask != nil }

    isolated deinit {
        datesTask?.cancel()
        songsTask?.cancel()
    }

    @discardableResult
    func startDates(
        accountID: Int64?,
        credentialRevision: UInt64,
        reload: Int,
        currentAccountID: @escaping @MainActor @Sendable () -> Int64?,
        currentCredentialRevision: @escaping @MainActor @Sendable () -> UInt64,
        load: @escaping @MainActor @Sendable (Bool) async throws -> [RecommendationHistoryDate]
    ) -> Task<Void, Never>? {
        datesTask?.cancel()
        datesTask = nil
        datesTaskID = nil
        songsTask?.cancel()
        songsTask = nil
        songsTaskID = nil
        _ = songsRequest.begin()

        let generation = datesRequest.begin()
        let force = requestState.beginDates(reload: reload)
        songs = []
        songsError = nil
        isLoadingSongs = false
        if loadedAccountID != accountID || loadedCredentialRevision != credentialRevision {
            loadedAccountID = accountID
            loadedCredentialRevision = credentialRevision
            dates = []
        }
        datesError = nil
        guard let accountID else {
            isLoadingDates = false
            return nil
        }

        isLoadingDates = true
        let taskID = UUID()
        datesTaskID = taskID
        datesTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.datesTaskID == taskID {
                    self.datesTask = nil
                    self.datesTaskID = nil
                    self.isLoadingDates = false
                }
            }
            do {
                let loaded = try await load(force)
                try Task.checkCancellation()
                guard self.datesRequest.accepts(
                    generation,
                    accountID: accountID,
                    credentialRevision: credentialRevision,
                    currentAccountID: currentAccountID(),
                    currentCredentialRevision: currentCredentialRevision()
                ) else { return }
                self.dates = loaded
                self.requestState.acceptDates(loaded, force: force)
                self.acceptedDatesRevision &+= 1
            } catch is CancellationError {
            } catch {
                guard self.datesRequest.accepts(
                    generation,
                    accountID: accountID,
                    credentialRevision: credentialRevision,
                    currentAccountID: currentAccountID(),
                    currentCredentialRevision: currentCredentialRevision()
                ) else { return }
                self.datesError = error.localizedDescription
            }
        }
        return datesTask
    }

    @discardableResult
    func startSongs(
        accountID: Int64?,
        credentialRevision: UInt64,
        currentAccountID: @escaping @MainActor @Sendable () -> Int64?,
        currentCredentialRevision: @escaping @MainActor @Sendable () -> UInt64,
        load: @escaping @MainActor @Sendable (
            RecommendationHistoryDate,
            [RecommendationHistoryDate],
            Bool
        ) async throws -> [Song]
    ) -> Task<Void, Never>? {
        songsTask?.cancel()
        songsTask = nil
        songsTaskID = nil
        let generation = songsRequest.begin()
        guard let date = requestState.selectedDate,
              let accountID,
              loadedAccountID == accountID,
              loadedCredentialRevision == credentialRevision
        else {
            songs = []
            songsError = nil
            isLoadingSongs = false
            return nil
        }

        let availableDates = dates
        let force = requestState.consumeDetailForce(for: date)
        songs = []
        songsError = nil
        isLoadingSongs = true
        let taskID = UUID()
        songsTaskID = taskID
        songsTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.songsTaskID == taskID {
                    self.songsTask = nil
                    self.songsTaskID = nil
                    self.isLoadingSongs = false
                }
            }
            do {
                let loaded = try await load(date, availableDates, force)
                try Task.checkCancellation()
                guard self.songsRequest.accepts(
                    generation,
                    accountID: accountID,
                    credentialRevision: credentialRevision,
                    currentAccountID: currentAccountID(),
                    currentCredentialRevision: currentCredentialRevision()
                ), self.requestState.selectedDate == date else { return }
                self.songs = loaded
            } catch is CancellationError {
            } catch {
                guard self.songsRequest.accepts(
                    generation,
                    accountID: accountID,
                    credentialRevision: credentialRevision,
                    currentAccountID: currentAccountID(),
                    currentCredentialRevision: currentCredentialRevision()
                ), self.requestState.selectedDate == date else { return }
                self.songsError = error.localizedDescription
            }
        }
        return songsTask
    }

    func cancel() {
        _ = datesRequest.begin()
        _ = songsRequest.begin()
        datesTask?.cancel()
        songsTask?.cancel()
        datesTask = nil
        songsTask = nil
        datesTaskID = nil
        songsTaskID = nil
        isLoadingDates = false
        isLoadingSongs = false
    }

}

struct RecommendationHistoryView: View {
    @Bindable var model: AppModel
    let library: LiveMusicLibrary
    @Bindable var player: PlayerController

    @State private var loader = RecommendationHistoryLoader()
    @State private var reload = 0

    var body: some View {
        @Bindable var loader = loader
        let revision = credentialRevision
        let datesIdentity = HistoryDatesTaskID(
            accountID: model.currentUserID,
            credentialRevision: revision,
            reload: reload
        )
        let detailIdentity = HistoryDetailTaskID(
            accountID: model.currentUserID,
            credentialRevision: revision,
            acceptedDatesRevision: loader.acceptedDatesRevision,
            date: loader.selectedDate?.value
        )
        Group {
            if loader.isLoadingDates {
                loading("正在加载历史日期…")
            } else if let datesError = loader.datesError {
                unavailable("历史日期加载失败", message: datesError)
            } else if loader.dates.isEmpty {
                ContentUnavailableView("暂无历史日推", systemImage: "calendar.badge.exclamationmark")
            } else {
                VStack(spacing: 0) {
                    HStack(spacing: 12) {
                        Picker("推荐日期", selection: $loader.selectedDate) {
                            ForEach(loader.dates) { date in
                                Text(date.value).tag(Optional(date))
                            }
                        }
                        .frame(maxWidth: 240)

                        Spacer()

                        Button { reload &+= 1 } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .help("刷新历史日推")
                        .accessibilityLabel("刷新历史日推")
                        .frame(minWidth: 44, minHeight: 44)
                    }
                    .padding(.horizontal, 28)
                    .padding(.vertical, 14)

                    Divider()

                    detail
                }
            }
        }
        .task(id: datesIdentity) {
            guard let task = loader.startDates(
                accountID: datesIdentity.accountID,
                credentialRevision: datesIdentity.credentialRevision,
                reload: datesIdentity.reload,
                currentAccountID: { model.currentUserID },
                currentCredentialRevision: { library.transport.credentialSnapshotValue().revision },
                load: { force in
                    try await library.recommendationHistoryDates(
                        forceRefresh: force,
                        expectedCredentialRevision: datesIdentity.credentialRevision
                    )
                }
            ) else { return }
            await withTaskCancellationHandler {
                await task.value
            } onCancel: {
                task.cancel()
            }
        }
        .task(id: detailIdentity) {
            guard let task = loader.startSongs(
                accountID: detailIdentity.accountID,
                credentialRevision: detailIdentity.credentialRevision,
                currentAccountID: { model.currentUserID },
                currentCredentialRevision: { library.transport.credentialSnapshotValue().revision },
                load: { date, dates, force in
                    try await library.historicalDailyRecommendations(
                        on: date,
                        availableDates: dates,
                        forceRefresh: force,
                        expectedCredentialRevision: detailIdentity.credentialRevision
                    )
                }
            ) else { return }
            await withTaskCancellationHandler {
                await task.value
            } onCancel: {
                task.cancel()
            }
        }
        .onDisappear { loader.cancel() }
        .navigationTitle("历史日推")
    }

    @ViewBuilder
    private var detail: some View {
        if loader.isLoadingSongs {
            loading("正在加载推荐歌曲…")
        } else if let songsError = loader.songsError {
            unavailable("历史日推不可用", message: songsError)
        } else if let selectedDate = loader.selectedDate, loader.songs.isEmpty {
            ContentUnavailableView(
                "当天暂无推荐",
                systemImage: "music.note",
                description: Text(selectedDate.value)
            )
        } else if let selectedDate = loader.selectedDate {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("\(selectedDate.value) 每日推荐")
                        .font(.title2.weight(.semibold))
                    SongList(songs: loader.songs, model: model, player: player, showsHeading: false)
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 22)
            }
        }
    }

    private func loading(_ title: String) -> some View {
        VStack(spacing: 12) {
            ProgressView()
            Text(title).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func unavailable(_ title: String, message: String) -> some View {
        ContentUnavailableView {
            Label(title, systemImage: "wifi.exclamationmark")
        } description: {
            Text(message)
        } actions: {
            Button("重试") { reload &+= 1 }
        }
    }

    private var credentialRevision: UInt64 {
        if let session = model.session {
            _ = session.state // Credential commits publish state with the snapshot revision.
            return session.credentialRevision
        }
        return library.transport.credentialSnapshotValue().revision
    }
}

private struct HistoryDatesTaskID: Hashable {
    let accountID: Int64?
    let credentialRevision: UInt64
    let reload: Int
}

private struct HistoryDetailTaskID: Hashable {
    let accountID: Int64?
    let credentialRevision: UInt64
    let acceptedDatesRevision: Int
    let date: String?
}
