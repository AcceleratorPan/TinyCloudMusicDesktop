import SwiftUI

struct RecommendationHistoryView: View {
    @Bindable var model: AppModel
    let library: LiveMusicLibrary
    @Bindable var player: PlayerController

    @State private var dates: [RecommendationHistoryDate] = []
    @State private var selectedDate: RecommendationHistoryDate?
    @State private var songs: [Song] = []
    @State private var isLoadingDates = true
    @State private var isLoadingSongs = false
    @State private var datesError: String?
    @State private var songsError: String?
    @State private var reload = 0
    @State private var datesRequest = LatestRecommendationRequest()
    @State private var songsRequest = LatestRecommendationRequest()

    var body: some View {
        Group {
            if isLoadingDates {
                loading("正在加载历史日期…")
            } else if let datesError {
                unavailable("历史日期加载失败", message: datesError)
            } else if dates.isEmpty {
                ContentUnavailableView("暂无历史日推", systemImage: "calendar.badge.exclamationmark")
            } else {
                VStack(spacing: 0) {
                    HStack(spacing: 12) {
                        Picker("推荐日期", selection: $selectedDate) {
                            ForEach(dates) { date in
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
        .task(id: HistoryDatesTaskID(accountID: model.currentUserID, reload: reload)) {
            await loadDates(force: reload > 0)
        }
        .task(id: HistoryDetailTaskID(
            accountID: model.currentUserID,
            date: selectedDate?.value,
            reload: reload
        )) {
            await loadSongs()
        }
        .navigationTitle("历史日推")
    }

    @ViewBuilder
    private var detail: some View {
        if isLoadingSongs {
            loading("正在加载推荐歌曲…")
        } else if let songsError {
            unavailable("历史日推不可用", message: songsError)
        } else if let selectedDate, songs.isEmpty {
            ContentUnavailableView(
                "当天暂无推荐",
                systemImage: "music.note",
                description: Text(selectedDate.value)
            )
        } else if let selectedDate {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("\(selectedDate.value) 每日推荐")
                        .font(.title2.weight(.semibold))
                    SongList(songs: songs, model: model, player: player, showsHeading: false)
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 22)
            }
        }
    }

    @MainActor
    private func loadDates(force: Bool) async {
        let accountID = model.currentUserID
        let generation = datesRequest.begin()
        dates = []
        selectedDate = nil
        songs = []
        datesError = nil
        songsError = nil
        guard accountID != nil else { return }
        isLoadingDates = true
        defer { if datesRequest.accepts(generation) { isLoadingDates = false } }
        do {
            if force { await library.invalidateCachedResponses(in: [.library]) }
            let loaded = try await library.recommendationHistoryDates()
            try Task.checkCancellation()
            guard datesRequest.accepts(generation), model.currentUserID == accountID else { return }
            dates = loaded
            selectedDate = loaded.first
        } catch is CancellationError {
        } catch {
            guard datesRequest.accepts(generation), model.currentUserID == accountID else { return }
            datesError = error.localizedDescription
        }
    }

    @MainActor
    private func loadSongs() async {
        guard let date = selectedDate, let accountID = model.currentUserID else { return }
        let generation = songsRequest.begin()
        songs = []
        songsError = nil
        isLoadingSongs = true
        defer { if songsRequest.accepts(generation) { isLoadingSongs = false } }
        do {
            let loaded = try await library.historicalDailyRecommendations(on: date, availableDates: dates)
            try Task.checkCancellation()
            guard songsRequest.accepts(generation), model.currentUserID == accountID, selectedDate == date else { return }
            songs = loaded
        } catch is CancellationError {
        } catch {
            guard songsRequest.accepts(generation), model.currentUserID == accountID, selectedDate == date else { return }
            songsError = error.localizedDescription
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
}

private struct HistoryDatesTaskID: Hashable {
    let accountID: Int64?
    let reload: Int
}

private struct HistoryDetailTaskID: Hashable {
    let accountID: Int64?
    let date: String?
    let reload: Int
}
