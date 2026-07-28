import SwiftUI

struct ListeningFootprintsView: View {
    @Bindable var model: AppModel
    let library: LiveMusicLibrary
    @Bindable var player: PlayerController

    @State private var selectedPeriod = FootprintPeriod.week
    @State private var states = Dictionary(
        uniqueKeysWithValues: FootprintPeriod.allCases.map { ($0, FootprintPeriodState()) }
    )
    @State private var generations: [FootprintPeriod: Int] = [:]
    @State private var tasks: [FootprintPeriod: Task<Void, Never>] = [:]

    var body: some View {
        Group {
            if model.currentUserID == nil {
                ContentUnavailableView(
                    "需要登录",
                    systemImage: "person.crop.circle.badge.exclamationmark",
                    description: Text("扫码登录后查看听歌足迹。")
                )
            } else {
                VStack(spacing: 0) {
                    periodPicker
                    Divider()
                    periodContent
                }
            }
        }
        .navigationTitle("听歌足迹")
        .toolbar {
            ToolbarItem {
                Button { refresh() } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("刷新听歌足迹")
                .accessibilityLabel("刷新听歌足迹")
                .frame(minWidth: 44, minHeight: 44)
                .disabled(model.currentUserID == nil || activeState.isLoading)
            }
        }
        .task(id: model.currentUserID) { reset(accountID: model.currentUserID) }
        .onChange(of: selectedPeriod) { _, period in loadIfNeeded(period) }
        .onChange(of: player.playbackReportRevision) { oldValue, newValue in
            guard newValue > oldValue, !activeState.pages.isEmpty else { return }
            refresh()
        }
        .onDisappear { tasks.values.forEach { $0.cancel() } }
    }

    private var periodPicker: some View {
        Picker("统计周期", selection: $selectedPeriod) {
            ForEach(FootprintPeriod.allCases, id: \.self) { period in
                Text(period.title).tag(period)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(maxWidth: 520)
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
    }

    @ViewBuilder
    private var periodContent: some View {
        if let page = activeState.pages.last {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    reportHeader(page)
                    if let error = activeState.error {
                        inlineError(error, cursor: activeState.failedCursor)
                    }
                    if !page.metrics.isEmpty {
                        metrics(page.metrics)
                    }
                    if !page.yearFootprints.isEmpty {
                        yearlyFootprints(page.yearFootprints)
                    }
                    if selectedPeriod != .year || !page.ranks.isEmpty {
                        rankList(page.ranks)
                    } else if page.metrics.isEmpty, page.yearFootprints.isEmpty {
                        ContentUnavailableView("暂无年度听歌足迹", systemImage: "calendar")
                            .frame(maxWidth: .infinity, minHeight: 220)
                    }
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 22)
            }
        } else if activeState.isLoading {
            VStack(spacing: 12) {
                ProgressView()
                Text("正在加载听歌足迹…").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = activeState.error {
            ContentUnavailableView {
                Label("听歌足迹加载失败", systemImage: "wifi.exclamationmark")
            } description: {
                Text(error)
            } actions: {
                Button("重试") { startLoad(selectedPeriod, cursor: nil) }
            }
        } else {
            ContentUnavailableView("暂无听歌足迹", systemImage: "chart.line.uptrend.xyaxis")
        }
    }

    private func reportHeader(_ page: FootprintPage) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(page.title)
                    .font(.title2.weight(.semibold))
                if page.cursor != nil {
                    Text("历史周期")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if page.cursor != nil {
                Button {
                    returnToCurrent()
                } label: {
                    Label("返回当前期", systemImage: "arrow.uturn.backward")
                }
                .disabled(activeState.isLoading)
            }
            if canLoadPrevious(page) {
                Button {
                    guard let cursor = page.previousCursor else { return }
                    startLoad(selectedPeriod, cursor: cursor)
                } label: {
                    Label("上一期", systemImage: "chevron.backward")
                }
                .disabled(activeState.isLoading)
            }
            if activeState.isLoading {
                ProgressView().controlSize(.small)
                    .accessibilityLabel("正在加载")
            }
        }
    }

    private func metrics(_ values: [ListeningMetric]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 132, maximum: 220), spacing: 12)], spacing: 12) {
            ForEach(values) { metric in
                VStack(alignment: .leading, spacing: 5) {
                    Text(metric.kind.title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(metricText(metric))
                        .font(.title3.weight(.semibold).monospacedDigit())
                        .lineLimit(2)
                }
                .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
                .padding(12)
                .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
                .accessibilityElement(children: .combine)
            }
        }
    }

    private func yearlyFootprints(_ values: [YearListeningFootprint]) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            ForEach(values) { footprint in
                VStack(alignment: .leading, spacing: 10) {
                    Text("\(footprint.year) 年")
                        .font(.title3.weight(.semibold).monospacedDigit())
                    metrics([
                        ListeningMetric(kind: .duration, value: .number(footprint.durationSeconds)),
                        ListeningMetric(kind: .songs, value: .number(footprint.playCount))
                    ])
                }
            }
        }
    }

    @ViewBuilder
    private func rankList(_ ranks: [ListeningRankEntry]) -> some View {
        if ranks.isEmpty {
            ContentUnavailableView("本期暂无听歌记录", systemImage: "music.note")
                .frame(maxWidth: .infinity, minHeight: 220)
        } else {
            let songs = ranks.map(\.song)
            VStack(alignment: .leading, spacing: 8) {
                Text("Top 歌曲")
                    .font(.title3.weight(.semibold))
                ForEach(Array(ranks.enumerated()), id: \.element.id) { index, entry in
                    rankRow(entry, number: index + 1, songs: songs)
                    if index < ranks.count - 1 { Divider().padding(.leading, 94) }
                }
            }
        }
    }

    private func rankRow(_ entry: ListeningRankEntry, number: Int, songs: [Song]) -> some View {
        HStack(spacing: 12) {
            Text("\(number)")
                .font(.callout.monospacedDigit())
                .foregroundStyle(number <= 3 ? .primary : .secondary)
                .frame(width: 26, alignment: .trailing)
            ArtworkView(artwork: entry.song.album.artwork)
                .frame(width: 46, height: 46)
            VStack(alignment: .leading, spacing: 3) {
                SongTitleText(song: entry.song)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                songMetadata(entry.song)
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 3) {
                Text("\(entry.playCount.formatted()) 次")
                    .font(.callout.monospacedDigit())
                if let duration = entry.durationSeconds {
                    Text(durationText(duration))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            Button {
                player.play(entry.song, in: songs)
            } label: {
                Image(systemName: "play.fill")
            }
            .buttonStyle(.plain)
            .frame(width: 44, height: 44)
            .help("播放 \(entry.song.name)")
            .accessibilityLabel("播放 \(entry.song.name)")
        }
        .frame(minHeight: 58)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { player.play(entry.song, in: songs) }
        .contextMenu {
            SongContextMenu(song: entry.song, songs: songs, model: model, player: player)
        }
    }

    @ViewBuilder
    private func songMetadata(_ song: Song) -> some View {
        if !song.artists.isEmpty, song.album.id > 0 {
            SongMetadataLinks(song: song, onOpenRoute: model.open)
        } else {
            Text([song.artistsDisplay, song.album.name].filter { !$0.isEmpty }.joined(separator: " · "))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private func inlineError(_ message: String, cursor: ListeningReportCursor?) -> some View {
        HStack(spacing: 10) {
            Label("刷新失败", systemImage: "wifi.exclamationmark")
            Text(message).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            Spacer()
            Button("重试") { startLoad(selectedPeriod, cursor: cursor, force: true) }
        }
        .padding(.vertical, 8)
    }

    private var activeState: FootprintPeriodState {
        states[selectedPeriod] ?? FootprintPeriodState()
    }

    @MainActor
    private func reset(accountID: Int64?) {
        tasks.values.forEach { $0.cancel() }
        tasks = [:]
        generations = [:]
        states = Dictionary(uniqueKeysWithValues: FootprintPeriod.allCases.map { ($0, FootprintPeriodState()) })
        guard accountID != nil else { return }
        startLoad(selectedPeriod, cursor: nil)
    }

    @MainActor
    private func loadIfNeeded(_ period: FootprintPeriod) {
        guard model.currentUserID != nil,
              states[period]?.pages.isEmpty != false,
              states[period]?.isLoading != true
        else { return }
        startLoad(period, cursor: nil)
    }

    @MainActor
    private func refresh() {
        startLoad(selectedPeriod, cursor: activeState.pages.last?.cursor, force: true)
    }

    @MainActor
    private func returnToCurrent() {
        guard var state = states[selectedPeriod], let first = state.pages.first else { return }
        tasks[selectedPeriod]?.cancel()
        generations[selectedPeriod, default: 0] &+= 1
        state.pages = [first]
        state.isLoading = false
        state.failedCursor = nil
        state.error = nil
        states[selectedPeriod] = state
    }

    private func canLoadPrevious(_ page: FootprintPage) -> Bool {
        guard let cursor = page.previousCursor else { return false }
        return !activeState.pages.contains { $0.cursor == cursor }
    }

    @MainActor
    private func startLoad(
        _ period: FootprintPeriod,
        cursor: ListeningReportCursor?,
        force: Bool = false
    ) {
        guard let accountID = model.currentUserID else { return }
        var state = states[period] ?? FootprintPeriodState()
        guard !state.isLoading || state.pendingCursor != cursor else { return }
        tasks[period]?.cancel()
        generations[period, default: 0] &+= 1
        let generation = generations[period, default: 0]
        state.isLoading = true
        state.pendingCursor = cursor
        state.failedCursor = nil
        state.error = nil
        states[period] = state

        tasks[period] = Task { @MainActor in
            do {
                let page = try await loadPage(period, cursor: cursor, force: force)
                try Task.checkCancellation()
                guard generations[period] == generation, model.currentUserID == accountID else { return }
                accept(page, for: period)
            } catch is CancellationError {
            } catch {
                guard generations[period] == generation, model.currentUserID == accountID else { return }
                var failed = states[period] ?? FootprintPeriodState()
                failed.isLoading = false
                failed.pendingCursor = nil
                failed.failedCursor = cursor
                failed.error = error.localizedDescription
                states[period] = failed
            }
        }
    }

    private func loadPage(
        _ period: FootprintPeriod,
        cursor: ListeningReportCursor?,
        force: Bool
    ) async throws -> FootprintPage {
        switch period {
        case .today:
            return FootprintPage(
                cursor: nil,
                title: "今日听歌",
                metrics: [],
                ranks: try await library.todayListeningRank(forceRefresh: force),
                yearFootprints: [],
                previousCursor: nil
            )
        case .week, .month:
            let reportPeriod = period.reportPeriod!
            async let report = library.listeningReport(
                period: reportPeriod,
                cursor: cursor,
                forceRefresh: force
            )
            async let ranks = library.listeningSongRank(
                period: reportPeriod,
                cursor: cursor,
                forceRefresh: force
            )
            let realtime: ListeningReport? = if cursor == nil {
                try await library.realtimeListeningReport(period: reportPeriod, forceRefresh: force)
            } else {
                nil
            }
            let (loadedReport, loadedRanks) = try await (report, ranks)
            return FootprintPage(
                cursor: cursor,
                title: loadedReport.title,
                metrics: mergedMetrics(realtime?.metrics ?? [], loadedReport.metrics),
                ranks: loadedRanks.isEmpty ? loadedReport.topSongs : loadedRanks,
                yearFootprints: [],
                previousCursor: loadedReport.previousCursor
            )
        case .year:
            if cursor != nil {
                let report = try await library.listeningReport(period: .year, cursor: cursor, forceRefresh: force)
                return FootprintPage(
                    cursor: cursor,
                    title: report.title,
                    metrics: report.metrics,
                    ranks: report.topSongs,
                    yearFootprints: [],
                    previousCursor: report.previousCursor
                )
            }
            async let report = try? library.listeningReport(period: .year, forceRefresh: force)
            let footprints = try await library.yearListeningFootprints(forceRefresh: force)
            let loadedReport = await report
            return FootprintPage(
                cursor: nil,
                title: "年度听歌足迹",
                metrics: footprints.isEmpty ? loadedReport?.metrics ?? [] : [],
                ranks: loadedReport?.topSongs ?? [],
                yearFootprints: footprints,
                previousCursor: loadedReport?.previousCursor
            )
        }
    }

    @MainActor
    private func accept(_ page: FootprintPage, for period: FootprintPeriod) {
        var state = states[period] ?? FootprintPeriodState()
        if let index = state.pages.firstIndex(where: { $0.cursor == page.cursor }) {
            state.pages = Array(state.pages.prefix(index)) + [page]
        } else if page.cursor == nil || state.pages.last?.previousCursor == page.cursor {
            state.pages.append(page)
        } else {
            return
        }
        state.isLoading = false
        state.pendingCursor = nil
        state.failedCursor = nil
        state.error = nil
        states[period] = state
        tasks[period] = nil
    }

    private func mergedMetrics(_ first: [ListeningMetric], _ second: [ListeningMetric]) -> [ListeningMetric] {
        var seen = Set<ListeningMetricKind>()
        return (first + second).filter { seen.insert($0.kind).inserted }
    }

    private func metricText(_ metric: ListeningMetric) -> String {
        switch metric.value {
        case let .text(value): value
        case let .number(value):
            switch metric.kind {
            case .duration: durationText(value)
            case .songs: "\(value.formatted()) 首"
            case .plays: "\(value.formatted()) 次"
            case .artists: "\(value.formatted()) 位"
            case .albums: "\(value.formatted()) 张"
            case .days: "\(value.formatted()) 天"
            }
        }
    }

    private func durationText(_ rawSeconds: Int64) -> String {
        let seconds = max(0, rawSeconds)
        if seconds == 0 { return "0 分钟" }
        let minutes = seconds / 60
        let hours = minutes / 60
        let remainder = minutes % 60
        if hours == 0 { return remainder == 0 ? "不足 1 分钟" : "\(remainder) 分钟" }
        return remainder == 0 ? "\(hours) 小时" : "\(hours) 小时 \(remainder) 分钟"
    }
}

private enum FootprintPeriod: String, CaseIterable {
    case today, week, month, year

    var title: String {
        switch self {
        case .today: "今日"
        case .week: "本周"
        case .month: "本月"
        case .year: "年度"
        }
    }

    var reportPeriod: ListeningReportPeriod? {
        switch self {
        case .today: nil
        case .week: .week
        case .month: .month
        case .year: .year
        }
    }
}

private struct FootprintPage {
    let cursor: ListeningReportCursor?
    let title: String
    let metrics: [ListeningMetric]
    let ranks: [ListeningRankEntry]
    let yearFootprints: [YearListeningFootprint]
    let previousCursor: ListeningReportCursor?
}

private struct FootprintPeriodState {
    var pages: [FootprintPage] = []
    var pendingCursor: ListeningReportCursor?
    var failedCursor: ListeningReportCursor?
    var isLoading = false
    var error: String?
}
