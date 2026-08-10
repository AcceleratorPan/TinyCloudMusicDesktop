import Observation
import SwiftUI
#if os(macOS)
import AppKit
#endif

final class TopTabScrollPositions<Selection: Hashable> {
    private(set) var selection: Selection
    private var offsets: [Selection: CGFloat] = [:]

    init(selection: Selection) {
        self.selection = selection
    }

    func record(_ currentOffset: CGFloat, for selection: Selection) {
        offsets[selection] = max(0, currentOffset)
    }

    func offset(for selection: Selection) -> CGFloat {
        offsets[selection] ?? 0
    }

    @discardableResult
    func select(_ newSelection: Selection) -> CGFloat {
        selection = newSelection
        return offset(for: newSelection)
    }

    func target(for newSelection: Selection, currentOffset: CGFloat) -> CGFloat {
        record(currentOffset, for: selection)
        return select(newSelection)
    }
}

struct ListeningFootprintsView: View {
    @Bindable var model: AppModel
    let library: LiveMusicLibrary
    @Bindable var player: PlayerController

    @State private var selectedPeriod = FootprintPeriod.week
    @State private var states = Dictionary(
        uniqueKeysWithValues: FootprintPeriod.allCases.map { ($0, FootprintPeriodState()) }
    )
    @State private var loadOwner = FootprintLoadOwner()
    @State private var selectedAnnualYear: Int?
    @State private var annualLoader = AnnualReportLoader()
    @State private var annualReportReload = 0
    @State private var loadedRootIdentity: FootprintRootTaskID?
    @State private var historyRefresh = FootprintHistoryRefreshState()
#if os(macOS)
    @State private var macScrollPositions = TopTabScrollPositions(selection: FootprintPeriod.week)
#endif
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .largeTitle) private var annualKeywordFontSize = 56.0

    var body: some View {
        let rootIdentity = FootprintRootTaskID(
            accountID: model.currentUserID,
            credentialRevision: credentialRevision
        )
        let annualIdentity = AnnualReportTaskID(
            accountID: model.currentUserID,
            credentialRevision: credentialRevision,
            period: selectedPeriod,
            year: selectedAnnualYear,
            reload: annualReportReload
        )
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
#if os(iOS)
                        .modifier(IOSTopTabScrollPositionModifier(selection: selectedPeriod))
#endif
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
        .task(id: rootIdentity) {
            await waitForFootprintLoad(reset(identity: rootIdentity))
        }
        .task(id: annualIdentity) { await loadAnnualReport(identity: annualIdentity) }
        .onChange(of: selectedPeriod) { oldPeriod, period in
            switchPeriod(from: oldPeriod, to: period)
        }
        .onChange(of: player.playbackHistoryEvent) { _, event in
            consumeHistoryEvent(event)
        }
        .onAppear {
            historyRefresh.setVisible(true)
            guard loadedRootIdentity == rootIdentity else { return }
            consumeHistoryEvent(player.playbackHistoryEvent)
            drainHistoryRefresh()
            loadIfNeeded(selectedPeriod)
        }
        .onDisappear { suspendLoads() }
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
        .padding(.horizontal, periodPickerHorizontalPadding)
        .padding(.vertical, 14)
    }

    @ViewBuilder
    private var periodContent: some View {
        if let page = activeState.pages.last {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    if selectedPeriod != .year || page.cursor != nil { reportHeader(page) }
                    if let error = activeState.error {
                        inlineError(error, cursor: activeState.failedCursor)
                    }
                    if selectedPeriod == .year, page.cursor == nil {
                        annualContent(page.yearFootprints)
                    } else {
                        if !page.metrics.isEmpty { metrics(page.metrics) }
                        rankList(page.ranks)
                    }
                }
                .padding(.horizontal, contentHorizontalPadding)
                .padding(.vertical, 22)
#if os(macOS)
                .background {
                    MacTopTabScrollPositionAccessor(
                        selection: selectedPeriod,
                        positions: macScrollPositions
                    )
                }
#endif
            }
#if os(iOS)
            .refreshable { await waitForFootprintLoad(refresh()) }
#endif
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
#if os(iOS)
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                reportTitle(page)
                Spacer()
                if activeState.isLoading {
                    ProgressView().controlSize(.small)
                        .accessibilityLabel("正在加载")
                }
            }
            if page.cursor != nil || canLoadPrevious(page) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        reportNavigationButtons(page)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        reportNavigationButtons(page)
                    }
                }
                .buttonStyle(.bordered)
            }
        }
#else
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            reportTitle(page)
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
#endif
    }

    private func reportTitle(_ page: FootprintPage) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(page.title)
                .font(.title2.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            if page.cursor != nil {
                Text("历史周期")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func reportNavigationButtons(_ page: FootprintPage) -> some View {
        if page.cursor != nil {
            Button("返回当前期", systemImage: "arrow.uturn.backward") { returnToCurrent() }
                .frame(minHeight: 44)
                .disabled(activeState.isLoading)
        }
        if canLoadPrevious(page) {
            Button("上一期", systemImage: "chevron.backward") {
                guard let cursor = page.previousCursor else { return }
                startLoad(selectedPeriod, cursor: cursor)
            }
            .frame(minHeight: 44)
            .disabled(activeState.isLoading)
        }
    }

    private func metrics(_ values: [ListeningMetric]) -> some View {
        LazyVGrid(columns: metricColumns(minimum: 132, maximum: 220), spacing: 12) {
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

    @ViewBuilder
    private func annualContent(_ footprints: [YearListeningFootprint]) -> some View {
        let years = annualYears(footprints)
        if years.isEmpty {
            ContentUnavailableView("暂无年度听歌足迹", systemImage: "calendar")
                .frame(maxWidth: .infinity, minHeight: 220)
        } else {
            VStack(alignment: .leading, spacing: 28) {
                annualYearControl(years)
                if let year = selectedAnnualYear {
                    annualHero(
                        year: year,
                        metrics: annualSummaryMetrics(year: year, footprints: footprints)
                    )
                }
                annualReportContent
            }
            .frame(maxWidth: 1_080, alignment: .leading)
        }
    }

    private func annualYearControl(_ years: [Int]) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) {
                annualYearLabel
                Spacer(minLength: 16)
#if os(macOS)
                Text("报告年份")
                    .font(.caption)
                    .foregroundStyle(.secondary)
#endif
                annualYearPicker(years)
            }
            VStack(alignment: .leading, spacing: 8) {
                annualYearLabel
                annualYearPicker(years)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
        .frame(minHeight: 52)
        .background(.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(.primary.opacity(0.07), lineWidth: 1)
        }
    }

    private var annualYearLabel: some View {
        Label("年度报告", systemImage: "calendar")
            .font(.headline)
            .foregroundStyle(.primary)
    }

    private func annualYearPicker(_ years: [Int]) -> some View {
        Picker("报告年份", selection: $selectedAnnualYear) {
            ForEach(years, id: \.self) { year in
                Text("\(year) 年").tag(Optional(year))
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .fixedSize()
        .frame(minHeight: 44)
    }

    private func annualHero(year: Int, metrics: [ListeningMetric]) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            annualHeroTitle(year: year)
            if let playCount = listeningMetric(.plays, in: metrics) {
                Text("今年你共播放 \(playCount.formatted()) 次")
                    .font(.title2.weight(.semibold))
            }
            if let seconds = listeningMetric(.duration, in: metrics) {
                Text("今年你的听歌时长\n\(compactDurationText(seconds))")
                    .font(.title3.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
    }

    private func annualHeroTitle(year: Int) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Label("年度回顾", systemImage: "waveform")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.accentColor)
                .symbolRenderingMode(.hierarchical)
            Text("\(year)")
                .font(annualYearFont)
                .monospacedDigit()
            Text("年度听歌报告")
                .font(.title3.weight(.medium))
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var annualReportContent: some View {
        if let year = selectedAnnualYear,
           !AnnualListeningReportDecoder.supportedYears.contains(year) {
            ContentUnavailableView(
                "该年度暂无详细报告",
                systemImage: "doc.text.magnifyingglass",
                description: Text("当前仅提供年度听歌足迹摘要。")
            )
            .frame(maxWidth: .infinity, minHeight: 180)
        } else if showsAnnualLoadingPlaceholder {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("正在加载年度报告…").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 120)
        } else if let annualReportError = annualLoader.state.error {
            VStack(alignment: .leading, spacing: 8) {
                Label("年度报告不可用", systemImage: "wifi.exclamationmark")
                Text(annualReportError)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("重试") { annualReportReload &+= 1 }
                    .frame(minHeight: 44)
            }
            .padding(16)
            .background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
        } else if let annualReport = annualLoader.state.report, annualReport.year == selectedAnnualYear {
            if annualReport.sections.isEmpty {
                ContentUnavailableView("该年度暂无报告内容", systemImage: "doc.text")
                    .frame(maxWidth: .infinity, minHeight: 180)
            } else {
                let hasDiscoveries = annualReport.sections.contains { $0.id == "discoveries" }
                let sections = annualReport.sections.filter { $0.id != "genres" || !hasDiscoveries }
                VStack(alignment: .leading, spacing: 16) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(sections.enumerated()), id: \.element.id) { index, section in
                            if section.id == "discoveries" {
                                annualDiscoverySection(
                                    section,
                                    genres: annualReport.sections.first(where: { $0.id == "genres" })
                                )
                            } else {
                                annualSection(section)
                            }
                            if index < sections.count - 1 {
                                Divider().padding(.vertical, 28)
                            }
                        }
                    }
                    if let annualEnrichmentError = annualLoader.state.enrichmentError {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("部分歌曲信息未补全", systemImage: "info.circle")
                            Text(annualEnrichmentError)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Button("重试") { annualReportReload &+= 1 }
                                .frame(minHeight: 44)
                        }
                        .padding(.vertical, 8)
                    }
                }
            }
        }
    }

    private var showsAnnualLoadingPlaceholder: Bool {
#if os(iOS)
        annualLoader.state.isLoading && annualLoader.state.report?.year != selectedAnnualYear
#else
        annualLoader.state.isLoading
#endif
    }

    private func annualSection(_ section: AnnualReportSection) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            annualSectionIdentity(section)
            if ["annual-song", "annual-singer", "favorite-album"].contains(section.id),
               let artworkURL = annualArtworkURL(section) {
                footprintArtwork(Artwork(symbol: "music.note", accent: .red, remoteURL: artworkURL))
                    .frame(width: 152, height: 152)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .accessibilityLabel("\(section.title)封面")
            }
            annualSectionBody(section)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func annualSectionIdentity(_ section: AnnualReportSection) -> some View {
        HStack(alignment: .center, spacing: 12) {
            annualSectionIcon(section)
            annualSectionTitle(section)
        }
    }

    private func annualSectionIcon(_ section: AnnualReportSection) -> some View {
        Image(systemName: annualSectionSymbol(section.id))
            .font(.body.weight(.semibold))
            .foregroundStyle(Color.accentColor)
            .frame(width: 32, height: 32)
            .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 7))
            .accessibilityHidden(true)
    }

    private func annualSectionTitle(_ section: AnnualReportSection) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(section.title)
                .font(.title3.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            if let subtitle = section.subtitle, !section.id.hasPrefix("keyword-") {
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func annualSectionBody(_ section: AnnualReportSection) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            if section.id == "listening-methods" {
                annualEncounter(section)
            } else if section.id == "months" {
                annualMonthList(section.items)
            } else if section.id == "monthly-moods" {
                annualMoodList(section.items)
            } else if section.id == "genres" {
                annualGenrePreference(section)
            } else if section.id == "singer-comparison" {
                annualSingerTimeline(section.details)
            } else if section.id.hasPrefix("keyword-") {
                annualKeyword(section)
            } else if [
                "listening-times", "late-listening", "loop-song", "crowd-memory", "listen-together"
            ].contains(section.id) {
                annualEditorialSummary(section)
            } else {
                if !section.metrics.isEmpty { annualMetrics(section.metrics) }
                if !section.details.isEmpty { annualDetails(section.details) }
            }
            annualTracks(section)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func annualEncounter(_ section: AnnualReportSection) -> some View {
        let timestamp = section.metrics.lazy.compactMap { metric -> Int64? in
            if case let .date(value) = metric.value { value } else { nil }
        }.first
        let otherMetrics = section.metrics.filter {
            if case .date = $0.value { false } else { true }
        }
        if let timestamp {
            let date = Date(timeIntervalSince1970: TimeInterval(timestamp) / 1_000)
            let days = elapsedDays(since: date)
            VStack(alignment: .leading, spacing: 5) {
                Text(chineseDate(date))
                    .font(annualDateFont)
                    .monospacedDigit()
                Text("我们第一次相遇")
                    .font(.title3.weight(.semibold))
                Text("转眼过去\(days)天")
                    .font(.headline.monospacedDigit())
                Text("已经快\(max(1, (days + 364) / 365))年。")
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
        }
        if !otherMetrics.isEmpty { annualMetrics(otherMetrics) }
    }

    private func annualDiscoverySection(
        _ discoveries: AnnualReportSection,
        genres: AnnualReportSection?
    ) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            annualSectionIdentity(discoveries)
            VStack(alignment: .leading, spacing: 7) {
                if let count = annualNumber("听过歌手", in: discoveries.metrics) {
                    Text("一共听了\(count.formatted())位歌手")
                }
                if let count = annualNumber("新遇见歌手", in: discoveries.metrics) {
                    Text("其中邂逅与重逢了\(count.formatted())位新歌手")
                }
                if let count = annualNumber("听过曲风", in: discoveries.metrics) {
                    Text("你听过\(count.formatted())种曲风")
                }
                if let count = annualNumber("新曲风", in: discoveries.metrics) {
                    Text("其中\(count.formatted())种全新探索")
                }
                Text("它们陪你走过无数个「此刻」。")
            }
            .font(.title3.weight(.medium))
            .fixedSize(horizontal: false, vertical: true)
            if !discoveries.details.isEmpty { annualDetails(discoveries.details) }
            annualArtistList(discoveries.items)
            if let genres {
                Divider().padding(.vertical, 4)
                annualSectionIdentity(genres)
                annualGenrePreference(genres)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func annualGenrePreference(_ section: AnnualReportSection) -> some View {
        let shares = section.items.compactMap { item -> AnnualGenreShare? in
            guard case let .genre(name, percent) = item else { return nil }
            return AnnualGenreShare(name: name, percent: percent)
        }
        return VStack(alignment: .leading, spacing: 16) {
            if let slogan = section.subtitle {
                Text(slogan)
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }
            if let age = annualNumber("音乐年龄", in: section.metrics) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("音乐年龄")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("\(age.formatted()) 岁")
                        .font(.title2.weight(.bold).monospacedDigit())
                }
                .accessibilityElement(children: .combine)
            }
            if !shares.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(shares.enumerated()), id: \.element.id) { index, share in
#if os(iOS)
                        VStack(alignment: .leading, spacing: 7) {
                            HStack(spacing: 12) {
                                Text(share.name)
                                    .font(.body.weight(.medium))
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 8)
                                Text("\(share.percent)%")
                                    .font(.callout.weight(.semibold).monospacedDigit())
                            }
                            GeometryReader { proxy in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(.quaternary)
                                    Capsule()
                                        .fill(annualGenreColors[index % annualGenreColors.count])
                                        .frame(width: max(4, proxy.size.width * CGFloat(share.percent) / 100))
                                }
                            }
                            .frame(height: 8)
                        }
                        .accessibilityElement(children: .combine)
#else
                        HStack(spacing: 12) {
                            Text(share.name)
                                .frame(width: 110, alignment: .leading)
                                .lineLimit(2)
                            GeometryReader { proxy in
                                let maximumWidth = max(1, proxy.size.width - 52)
                                HStack(spacing: 8) {
                                    RoundedRectangle(cornerRadius: 3)
                                        .fill(annualGenreColors[index % annualGenreColors.count])
                                        .frame(
                                            width: max(4, maximumWidth * CGFloat(share.percent) / 100),
                                            height: 18
                                        )
                                    Text("\(share.percent)%")
                                        .font(.callout.weight(.semibold).monospacedDigit())
                                        .lineLimit(1)
                                    Spacer(minLength: 0)
                                }
                            }
                            .frame(height: 22)
                        }
                        .accessibilityElement(children: .combine)
#endif
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func annualArtistList(_ items: [AnnualReportItem]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(items) { item in
                if case let .artist(id, name, imageURL, note) = item {
                    annualArtistRow(id: id, name: name, imageURL: imageURL, note: note)
                }
            }
        }
    }

    @ViewBuilder
    private func annualArtistRow(id: Int64, name: String, imageURL: URL?, note: String) -> some View {
        if id > 0 {
            Button { model.open(.artist(id)) } label: {
                annualArtistRowLabel(name: name, imageURL: imageURL, note: note, showsChevron: true)
            }
#if os(iOS)
            .buttonStyle(IOSPressedButtonStyle())
#else
            .buttonStyle(.plain)
#endif
            .accessibilityHint("打开歌手详情")
        } else {
            annualArtistRowLabel(name: name, imageURL: imageURL, note: note, showsChevron: false)
        }
    }

    private func annualArtistRowLabel(
        name: String,
        imageURL: URL?,
        note: String,
        showsChevron: Bool
    ) -> some View {
        HStack(spacing: 12) {
            footprintArtwork(Artwork(symbol: "music.mic", accent: .cyan, remoteURL: imageURL))
                .frame(width: 46, height: 46)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 3) {
                Text(name).font(.body.weight(.semibold)).foregroundStyle(.primary).lineLimit(1)
                Text(note).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            if showsChevron {
                Image(systemName: "chevron.right").foregroundStyle(.tertiary).accessibilityHidden(true)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
        .padding(.horizontal, 12)
        .background(.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
        .contentShape(Rectangle())
    }

    private func annualMonthList(_ items: [AnnualReportItem]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(items) { item in
                if case let .month(month, seconds, artistID, artistName, imageURL) = item {
                    annualMonthRow(
                        month: month,
                        seconds: seconds,
                        artistID: artistID,
                        artistName: artistName,
                        imageURL: imageURL
                    )
                }
            }
        }
    }

    @ViewBuilder
    private func annualMonthRow(
        month: Int,
        seconds: Int64,
        artistID: Int64?,
        artistName: String?,
        imageURL: URL?
    ) -> some View {
        if let artistID {
            Button { model.open(.artist(artistID)) } label: {
                annualMonthRowLabel(
                    month: month,
                    seconds: seconds,
                    artistName: artistName,
                    imageURL: imageURL,
                    showsChevron: true
                )
            }
#if os(iOS)
            .buttonStyle(IOSPressedButtonStyle())
#else
            .buttonStyle(.plain)
#endif
            .accessibilityHint("打开歌手详情")
        } else {
            annualMonthRowLabel(
                month: month,
                seconds: seconds,
                artistName: artistName,
                imageURL: imageURL,
                showsChevron: false
            )
        }
    }

    private func annualMonthRowLabel(
        month: Int,
        seconds: Int64,
        artistName: String?,
        imageURL: URL?,
        showsChevron: Bool
    ) -> some View {
        HStack(spacing: 12) {
            Text("\(month)月")
                .font(.title3.weight(.bold).monospacedDigit())
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .frame(width: 52, alignment: .trailing)
            footprintArtwork(Artwork(symbol: "music.mic", accent: .blue, remoteURL: imageURL))
                .frame(width: 46, height: 46)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 3) {
                Text(artistName ?? "本月足迹").font(.body.weight(.semibold)).foregroundStyle(.primary).lineLimit(1)
                Text("\(month) 月常听").font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Text(compactDurationText(seconds))
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if showsChevron {
                Image(systemName: "chevron.right").foregroundStyle(.tertiary).accessibilityHidden(true)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
        .contentShape(Rectangle())
    }

    private func annualMoodList(_ items: [AnnualReportItem]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                if case let .mood(month, name, genre) = item {
                    let accent = annualMoodColors[index % annualMoodColors.count]
                    HStack(alignment: .center, spacing: 16) {
                        VStack(spacing: 0) {
                            Text("\(month)")
                                .font(.system(.title2, design: .serif, weight: .bold).monospacedDigit())
                            Text("月")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(width: 48)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(name)
                                .font(.title3.weight(.semibold))
                                .foregroundStyle(.primary)
                                .fixedSize(horizontal: false, vertical: true)
                            if let genre {
                                Text(genre)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer(minLength: 4)
                    }
                    .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(accent.opacity(0.11), in: RoundedRectangle(cornerRadius: 7))
                    .overlay {
                        RoundedRectangle(cornerRadius: 7)
                            .stroke(accent.opacity(0.32), lineWidth: 1)
                    }
                    .overlay(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(accent)
                            .frame(width: 4)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    private func annualKeyword(_ section: AnnualReportSection) -> some View {
        let accent = annualEditorialAccent(section.id)
        return VStack(spacing: 20) {
            HStack(spacing: 10) {
                Rectangle().fill(accent.opacity(0.45)).frame(height: 1)
                Image(systemName: "sparkles")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(accent)
                    .accessibilityHidden(true)
                Rectangle().fill(accent.opacity(0.45)).frame(height: 1)
            }
            Text("「\(section.subtitle ?? "")」")
                .font(.system(size: annualKeywordFontSize, weight: .semibold, design: .serif))
                .lineLimit(2)
                .minimumScaleFactor(0.6)
                .multilineTextAlignment(.center)
                .layoutPriority(1)
                .frame(maxWidth: .infinity, minHeight: 84)
            HStack {
                Spacer(minLength: 8)
                if let count = annualNumber("出现次数", in: section.metrics) {
                    Text("出现 \(count.formatted()) 次")
                        .font(.callout.weight(.medium).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(24)
        .background(accent.opacity(0.075), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(accent.opacity(0.38), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
    }

    private func annualEditorialSummary(_ section: AnnualReportSection) -> some View {
        let accent = annualEditorialAccent(section.id)
        return VStack(alignment: .leading, spacing: 20) {
            ForEach(section.metrics) { metric in
                VStack(alignment: .leading, spacing: 7) {
                    Text(metric.label)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(annualMetricText(metric.value))
                        .font(.title2.weight(.semibold).monospacedDigit())
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 16)
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(accent.opacity(0.72))
                        .frame(width: 2)
                }
                .accessibilityElement(children: .combine)
            }
            if !section.details.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(section.details.enumerated()), id: \.offset) { index, detail in
                        HStack(alignment: .top, spacing: 12) {
                            Circle()
                                .fill(accent)
                                .frame(width: 7, height: 7)
                                .padding(.top, 7)
                                .accessibilityHidden(true)
                            Text(detail)
                                .font(.body)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.vertical, 10)
                        .accessibilityElement(children: .combine)
                        if index < section.details.count - 1 {
                            Divider().padding(.leading, 19)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func annualSingerTimeline(_ details: [String]) -> some View {
        let accent = annualEditorialAccent("singer-comparison")
        return VStack(alignment: .leading, spacing: 18) {
            ForEach(Array(details.enumerated()), id: \.offset) { _, detail in
                HStack(alignment: .top, spacing: 14) {
                    Circle()
                        .fill(accent)
                        .frame(width: 10, height: 10)
                        .padding(.top, 6)
                    Text(detail)
                        .font(.system(.title3, design: .serif, weight: .semibold).monospacedDigit())
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .padding(.leading, 4)
        .background(alignment: .leading) {
            if details.count > 1 {
                Rectangle()
                    .fill(accent.opacity(0.3))
                    .frame(width: 1)
                    .padding(.leading, 4.5)
                    .padding(.vertical, 11)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func annualTracks(_ section: AnnualReportSection) -> some View {
        if !section.tracks.isEmpty {
            let songs = section.tracks.map(\.song)
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(section.tracks.enumerated()), id: \.element.id) { index, track in
                    annualTrackRow(
                        track,
                        number: index + 1,
                        songs: songs,
                        season: annualSeasonMarker(sectionID: section.id, trackID: track.id)
                    )
                }
            }
        }
    }

    private func annualMetrics(_ values: [AnnualReportMetric]) -> some View {
        LazyVGrid(columns: metricColumns(minimum: 142, maximum: 240), spacing: 12) {
            ForEach(values) { metric in
                VStack(alignment: .leading, spacing: 5) {
                    Text(metric.label)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    Text(annualMetricText(metric.value))
                        .font(.title3.weight(.semibold).monospacedDigit())
                        .lineLimit(2)
                }
                .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
                .padding(12)
                .background(.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
                .overlay {
                    RoundedRectangle(cornerRadius: 7)
                        .stroke(.primary.opacity(0.06), lineWidth: 1)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    private func annualDetails(_ details: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(details.enumerated()), id: \.offset) { _, detail in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "circle.fill")
                        .font(.system(size: 5))
                        .foregroundStyle(Color.accentColor)
                        .padding(.top, 7)
                        .accessibilityHidden(true)
                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func annualTrackRow(
        _ track: AnnualReportTrack,
        number: Int,
        songs: [Song],
        season: (name: String, color: Color)?
    ) -> some View {
#if os(iOS)
        iosFootprintSongRow(
            song: track.song,
            songs: songs,
            marker: season?.name ?? "\(number)",
            markerColor: season?.color ?? (number <= 3 ? Color.accentColor : Color.secondary),
            subtitle: track.caption ?? songMetadataText(track.song),
            detail: track.playCount.map { "播放 \($0.formatted()) 次" }
        )
#else
        HStack(spacing: 12) {
            if let season {
                Text(season.name)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(season.color)
                    .frame(width: 32, alignment: .trailing)
            } else {
                Text("\(number)")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(number <= 3 ? Color.accentColor : Color.secondary)
                    .frame(width: 26, alignment: .trailing)
            }
            footprintArtwork(track.song.album.artwork)
                .frame(width: 46, height: 46)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .accessibilityLabel("\(track.song.name)封面")
            VStack(alignment: .leading, spacing: 3) {
                footprintSongTitle(track.song).font(.body.weight(.medium)).lineLimit(1)
                if let caption = track.caption {
                    Text(caption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                } else {
                    songMetadata(track.song)
                }
            }
            .layoutPriority(1)
            Spacer(minLength: 8)
            if let playCount = track.playCount {
                Text("\(playCount.formatted()) 次")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Button {
                player.play(track.song, in: songs)
            } label: {
                Image(systemName: "play.fill")
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
            .frame(width: 44, height: 44)
            .help("播放 \(track.song.name)")
            .accessibilityLabel("播放 \(track.song.name)")
        }
        .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(.secondary.opacity(0.045), in: RoundedRectangle(cornerRadius: 7))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { player.play(track.song, in: songs) }
        .contextMenu {
            footprintSongMenu(track.song, songs: songs)
        }
#endif
    }

    private func annualSeasonMarker(
        sectionID: String,
        trackID: String
    ) -> (name: String, color: Color)? {
        guard sectionID == "seasons" else { return nil }
        return switch trackID {
        case "season-0": ("春", .green)
        case "season-1": ("夏", .orange)
        case "season-2": ("秋", .brown)
        case "season-3": ("冬", .cyan)
        default: nil
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
#if os(iOS)
        iosFootprintSongRow(
            song: entry.song,
            songs: songs,
            marker: "\(number)",
            markerColor: number <= 3 ? Color.accentColor : Color.secondary,
            subtitle: songMetadataText(entry.song),
            detail: (["播放 \(entry.playCount.formatted()) 次"] + (entry.durationSeconds.map {
                [durationText($0)]
            } ?? [])).joined(separator: " · ")
        )
#else
        HStack(spacing: 12) {
            Text("\(number)")
                .font(.callout.monospacedDigit())
                .foregroundStyle(number <= 3 ? .primary : .secondary)
                .frame(width: 26, alignment: .trailing)
            footprintArtwork(entry.song.album.artwork)
                .frame(width: 46, height: 46)
            VStack(alignment: .leading, spacing: 3) {
                footprintSongTitle(entry.song)
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
            footprintSongMenu(entry.song, songs: songs)
        }
#endif
    }

#if os(iOS)
    private func iosFootprintSongRow(
        song: Song,
        songs: [Song],
        marker: String,
        markerColor: Color,
        subtitle: String,
        detail: String?
    ) -> some View {
        HStack(spacing: 8) {
            Button {
                player.play(song, in: songs)
            } label: {
                HStack(spacing: 12) {
                    Text(marker)
                        .font(.callout.weight(.semibold).monospacedDigit())
                        .foregroundStyle(markerColor)
                        .frame(width: 32, alignment: .trailing)
                    if !dynamicTypeSize.isAccessibilitySize {
                        IOSArtworkView(artwork: song.album.artwork, cornerRadius: 6)
                            .frame(width: 46, height: 46)
                            .accessibilityHidden(true)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(song.name)
                            .font(.body.weight(.medium))
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                        if !subtitle.isEmpty {
                            Text(subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        if let detail {
                            Text(detail)
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(IOSPressedButtonStyle())
            .accessibilityLabel("播放 \(song.name)，\(song.artistsDisplay)")
            .accessibilityHint([subtitle, detail].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "，"))

            Menu {
                footprintSongMenu(song, songs: songs)
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("\(song.name)的更多操作")
        }
        .frame(maxWidth: .infinity, minHeight: 68, alignment: .leading)
        .contextMenu { footprintSongMenu(song, songs: songs) }
    }
#endif

    @ViewBuilder
    private func songMetadata(_ song: Song) -> some View {
#if os(iOS)
        Text(songMetadataText(song))
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
#else
        if !song.artists.isEmpty, song.album.id > 0 {
            SongMetadataLinks(song: song, onOpenRoute: model.open)
        } else {
            Text([song.artistsDisplay, song.album.name].filter { !$0.isEmpty }.joined(separator: " · "))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
#endif
    }

    private func songMetadataText(_ song: Song) -> String {
        [song.artistsDisplay, song.album.name].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    @ViewBuilder
    private func footprintArtwork(_ artwork: Artwork) -> some View {
#if os(iOS)
        IOSArtworkView(artwork: artwork, cornerRadius: 6)
#else
        ArtworkView(artwork: artwork)
#endif
    }

    @ViewBuilder
    private func footprintSongTitle(_ song: Song) -> some View {
#if os(iOS)
        Text(song.name)
#else
        SongTitleText(song: song)
#endif
    }

    @ViewBuilder
    private func footprintSongMenu(_ song: Song, songs: [Song]) -> some View {
#if os(iOS)
        IOSSongActionsMenu(song: song, songs: songs, model: model, player: player)
#else
        SongContextMenu(song: song, songs: songs, model: model, player: player)
#endif
    }

    private func inlineError(_ message: String, cursor: ListeningReportCursor?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("刷新失败", systemImage: "wifi.exclamationmark")
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("重试") { startLoad(selectedPeriod, cursor: cursor, force: true) }
                .frame(minHeight: 44)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
    }

    private var activeState: FootprintPeriodState {
        states[selectedPeriod] ?? FootprintPeriodState()
    }

    private var credentialRevision: UInt64 {
        if let session = model.session {
            _ = session.state // Credential commits publish state with the snapshot revision.
            return session.credentialRevision
        }
        return library.transport.credentialSnapshotValue().revision
    }

    @MainActor
    @discardableResult
    private func reset(identity: FootprintRootTaskID) -> Task<Void, Never>? {
        guard loadedRootIdentity != identity else {
            let historyTask = consumeHistoryEvent(player.playbackHistoryEvent)
            if historyRefresh.pendingSequence(for: selectedPeriod) == nil {
                return historyTask ?? loadIfNeeded(selectedPeriod)
            } else {
                return historyTask ?? drainHistoryRefresh()
            }
        }
        loadedRootIdentity = identity
        loadOwner.cancelAll()
        states = Dictionary(uniqueKeysWithValues: FootprintPeriod.allCases.map { ($0, FootprintPeriodState()) })
        selectedAnnualYear = nil
        annualLoader.reset()
        annualReportReload = 0
        historyRefresh.resetEvents()
        guard identity.accountID != nil else { return nil }
        let historyTask = consumeHistoryEvent(player.playbackHistoryEvent)
        if historyRefresh.pendingSequence(for: selectedPeriod) == nil {
            return historyTask ?? startLoad(selectedPeriod, cursor: nil)
        } else {
            return historyTask ?? drainHistoryRefresh()
        }
    }

    @MainActor
    @discardableResult
    private func loadIfNeeded(_ period: FootprintPeriod) -> Task<Void, Never>? {
        if historyRefresh.pendingSequence(for: period) != nil {
            return drainHistoryRefresh()
        }
        guard model.currentUserID != nil,
              states[period]?.pages.isEmpty != false,
              states[period]?.isLoading != true
        else { return nil }
        return startLoad(period, cursor: nil)
    }

    @MainActor
    private func loadAnnualReport(identity: AnnualReportTaskID) async {
        guard let task = annualLoader.start(
            year: identity.year,
            accountID: identity.accountID,
            credentialRevision: identity.credentialRevision,
            reload: identity.reload,
            canLoad: identity.period == .year
                && identity.year.map { AnnualListeningReportDecoder.supportedYears.contains($0) } == true,
            currentYear: { selectedAnnualYear },
            currentAccountID: { model.currentUserID },
            currentCredentialRevision: { library.transport.credentialSnapshotValue().revision },
            report: { year, forceRefresh in
                try await library.annualListeningReport(
                    year: year,
                    forceRefresh: forceRefresh,
                    expectedCredentialRevision: identity.credentialRevision
                )
            },
            songs: { ids in try await model.repository.songs(ids: ids) }
        ) else { return }
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    @MainActor
    @discardableResult
    private func refresh() -> Task<Void, Never>? {
        if selectedPeriod == .year, activeState.pages.last?.cursor == nil {
            annualReportReload &+= 1
        }
        return startLoad(selectedPeriod, cursor: activeState.pages.last?.cursor, force: true)
    }

    @MainActor
    private func returnToCurrent() {
        guard var state = states[selectedPeriod], let first = state.pages.first else { return }
        loadOwner.invalidate(selectedPeriod)
        state.pages = [first]
        state.seenCursors = []
        state.isLoading = false
        state.pendingCursor = nil
        state.failedCursor = nil
        state.error = nil
        states[selectedPeriod] = state
    }

    private func canLoadPrevious(_ page: FootprintPage) -> Bool {
        guard let cursor = page.previousCursor else { return false }
        return !activeState.seenCursors.contains(cursor)
    }

    @MainActor
    @discardableResult
    private func startLoad(
        _ period: FootprintPeriod,
        cursor: ListeningReportCursor?,
        force: Bool = false,
        historyEventSequence: UInt64? = nil
    ) -> Task<Void, Never>? {
        guard let accountID = model.currentUserID else { return nil }
        let credentialRevision = library.transport.credentialSnapshotValue().revision
        var state = states[period] ?? FootprintPeriodState()
        guard !state.isLoading || state.pendingCursor != cursor else { return nil }
        state.begin(cursor: cursor)
        states[period] = state

        return loadOwner.start(
            period: period,
            accountID: accountID,
            credentialRevision: credentialRevision,
            currentAccountID: { model.currentUserID },
            currentCredentialRevision: { library.transport.credentialSnapshotValue().revision },
            load: {
                try await loadPage(
                    period,
                    cursor: cursor,
                    force: force,
                    expectedCredentialRevision: credentialRevision
                )
            },
            success: { page, _ in
                accept(page, for: period)
                settleHistoryEvent(period, sequence: historyEventSequence)
            },
            failure: { error, _ in
                var failed = states[period] ?? FootprintPeriodState()
                failed.fail(cursor: cursor, message: error.localizedDescription)
                states[period] = failed
                settleHistoryEvent(period, sequence: historyEventSequence)
            },
            finish: { identity in
                var finished = states[identity.period] ?? FootprintPeriodState()
                finished.cancel()
                states[identity.period] = finished
                if identity.period == selectedPeriod { drainHistoryRefresh() }
            }
        )
    }

    @MainActor
    @discardableResult
    private func consumeHistoryEvent(_ event: PlaybackHistoryEvent?) -> Task<Void, Never>? {
        historyRefresh.consume(
            event,
            credentialRevision: library.transport.credentialSnapshotValue().revision,
            hasAccount: model.currentUserID != nil
        )
        return drainHistoryRefresh()
    }

    @MainActor
    @discardableResult
    private func drainHistoryRefresh() -> Task<Void, Never>? {
        guard let sequence = historyRefresh.nextSequence(
            for: selectedPeriod,
            isLoading: activeState.isLoading,
            hasAccount: model.currentUserID != nil
        ) else { return nil }
        if selectedPeriod == .year, activeState.pages.last?.cursor == nil {
            annualReportReload &+= 1
        }
        return startLoad(
            selectedPeriod,
            cursor: activeState.pages.last?.cursor,
            force: true,
            historyEventSequence: sequence
        )
    }

    @MainActor
    private func settleHistoryEvent(_ period: FootprintPeriod, sequence: UInt64?) {
        guard let sequence else { return }
        historyRefresh.settle(period, sequence: sequence)
    }

    @MainActor
    private func suspendLoads() {
        historyRefresh.setVisible(false)
        annualLoader.cancel()
        for period in loadOwner.cancelAll() {
            var state = states[period] ?? FootprintPeriodState()
            state.cancel()
            states[period] = state
        }
    }

    @MainActor
    private func switchPeriod(from oldPeriod: FootprintPeriod, to period: FootprintPeriod) {
        if loadOwner.cancel(oldPeriod) {
            var state = states[oldPeriod] ?? FootprintPeriodState()
            state.cancel()
            states[oldPeriod] = state
        }
        loadIfNeeded(period)
    }

    private func loadPage(
        _ period: FootprintPeriod,
        cursor: ListeningReportCursor?,
        force: Bool,
        expectedCredentialRevision: UInt64
    ) async throws -> FootprintPage {
        switch period {
        case .today:
            return FootprintPage(
                cursor: nil,
                title: "今日听歌",
                metrics: [],
                ranks: try await library.todayListeningRank(
                    forceRefresh: force,
                    expectedCredentialRevision: expectedCredentialRevision
                ),
                yearFootprints: [],
                previousCursor: nil
            )
        case .week, .month:
            let reportPeriod = period.reportPeriod!
            let sources = try await loadFootprintSources(
                cursor: cursor,
                report: {
                    try await library.listeningReport(
                        period: reportPeriod,
                        cursor: cursor,
                        forceRefresh: force,
                        expectedCredentialRevision: expectedCredentialRevision
                    )
                },
                ranks: {
                    try await library.listeningSongRank(
                        period: reportPeriod,
                        cursor: cursor,
                        forceRefresh: force,
                        expectedCredentialRevision: expectedCredentialRevision
                    )
                },
                realtime: {
                    try await library.realtimeListeningReport(
                        period: reportPeriod,
                        forceRefresh: force,
                        expectedCredentialRevision: expectedCredentialRevision
                    )
                }
            )
            return FootprintPage(
                cursor: cursor,
                title: sources.report.title,
                metrics: mergedMetrics(sources.realtime?.metrics ?? [], sources.report.metrics),
                ranks: sources.ranks.isEmpty ? sources.report.topSongs : sources.ranks,
                yearFootprints: [],
                previousCursor: sources.report.previousCursor
            )
        case .year:
            if cursor != nil {
                let report = try await library.listeningReport(
                    period: .year,
                    cursor: cursor,
                    forceRefresh: force,
                    expectedCredentialRevision: expectedCredentialRevision
                )
                return FootprintPage(
                    cursor: cursor,
                    title: report.title,
                    metrics: report.metrics,
                    ranks: report.topSongs,
                    yearFootprints: [],
                    previousCursor: report.previousCursor
                )
            }
            let footprints = try await library.yearListeningFootprints(
                forceRefresh: force,
                expectedCredentialRevision: expectedCredentialRevision
            )
            return FootprintPage(
                cursor: nil,
                title: "年度听歌足迹",
                metrics: [],
                ranks: [],
                yearFootprints: footprints,
                previousCursor: nil
            )
        }
    }

    @MainActor
    private func accept(_ page: FootprintPage, for period: FootprintPeriod) {
        var state = states[period] ?? FootprintPeriodState()
        if page.cursor == nil {
            state.pages = [page]
            state.seenCursors = []
        } else if state.pages.last?.cursor == page.cursor {
            state.pages[state.pages.count - 1] = page
        } else if let cursor = page.cursor,
                  state.pages.last?.previousCursor == cursor,
                  state.seenCursors.insert(cursor).inserted {
            state.pages = [state.pages.first, page].compactMap { $0 }
        } else {
            return
        }
        state.isLoading = false
        state.pendingCursor = nil
        state.failedCursor = nil
        state.error = nil
        states[period] = state
        if period == .year, page.cursor == nil {
            let years = annualYears(page.yearFootprints)
            selectedAnnualYear = AnnualReportSelection.defaultYear(
                current: selectedAnnualYear,
                footprints: page.yearFootprints,
                sortedYears: years
            )
        }
    }

    private func annualYears(_ footprints: [YearListeningFootprint]) -> [Int] {
        footprints.map(\.year).sorted(by: >)
    }

    private func annualSummaryMetrics(
        year: Int,
        footprints: [YearListeningFootprint]
    ) -> [ListeningMetric] {
        if annualLoader.state.report?.year == year {
            return annualLoader.state.report?.overviewMetrics ?? []
        }
        guard let footprint = footprints.first(where: { $0.year == year }) else {
            return []
        }
        return [
            ListeningMetric(kind: .duration, value: .number(footprint.durationSeconds)),
            ListeningMetric(kind: .plays, value: .number(footprint.playCount))
        ]
    }

    private func annualArtworkURL(_ section: AnnualReportSection) -> URL? {
        section.artworkURL ?? section.tracks.lazy.compactMap { $0.song.album.artwork.remoteURL }.first
    }

    private func listeningMetric(_ kind: ListeningMetricKind, in metrics: [ListeningMetric]) -> Int64? {
        guard let metric = metrics.first(where: { $0.kind == kind }),
              case let .number(value) = metric.value
        else { return nil }
        return value
    }

    private func annualNumber(_ label: String, in metrics: [AnnualReportMetric]) -> Int64? {
        guard let metric = metrics.first(where: { $0.label == label }),
              case let .number(value, _) = metric.value
        else { return nil }
        return value
    }

    private func chineseDate(_ date: Date) -> String {
        let parts = Calendar.autoupdatingCurrent.dateComponents([.year, .month, .day], from: date)
        return "\(parts.year ?? 0)年\(parts.month ?? 0)月\(parts.day ?? 0)日"
    }

    private func elapsedDays(since date: Date, now: Date = Date()) -> Int {
        let calendar = Calendar.autoupdatingCurrent
        return max(0, calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: date),
            to: calendar.startOfDay(for: now)
        ).day ?? 0)
    }

    private func compactDurationText(_ rawSeconds: Int64) -> String {
        let minutes = max(0, rawSeconds) / 60
        let hours = minutes / 60
        return hours == 0 ? "\(minutes)分" : "\(hours)小时\(minutes % 60)分"
    }

    private var annualGenreColors: [Color] {
        [
            Color(red: 0.00, green: 0.48, blue: 1.00),
            Color(red: 1.00, green: 0.34, blue: 0.13),
            Color(red: 0.00, green: 0.64, blue: 0.44),
            Color(red: 0.69, green: 0.20, blue: 0.83),
            Color(red: 0.95, green: 0.68, blue: 0.00),
            Color(red: 0.84, green: 0.10, blue: 0.39)
        ]
    }

    private var contentHorizontalPadding: CGFloat {
#if os(iOS)
        16
#else
        28
#endif
    }

    private var periodPickerHorizontalPadding: CGFloat {
#if os(iOS)
        16
#else
        24
#endif
    }

    private var annualYearFont: Font {
#if os(iOS)
        .largeTitle.bold()
#else
        .system(size: 42, weight: .bold)
#endif
    }

    private var annualDateFont: Font {
#if os(iOS)
        .largeTitle.bold()
#else
        .system(size: 32, weight: .bold)
#endif
    }

    private func metricColumns(minimum: CGFloat, maximum: CGFloat) -> [GridItem] {
        dynamicTypeSize.isAccessibilitySize
            ? [GridItem(.flexible())]
            : [GridItem(.adaptive(minimum: minimum, maximum: maximum), spacing: 12)]
    }

    private var annualMoodColors: [Color] {
        [.pink, .orange, .teal, .indigo, .purple, .cyan]
    }

    private func annualEditorialAccent(_ id: String) -> Color {
        switch id {
        case "listening-times": .orange
        case "late-listening": .indigo
        case "loop-song": .pink
        case "crowd-memory": .teal
        case "listen-together": .blue
        case "singer-comparison": .purple
        case "keyword-firstKeyWord": Color(red: 0.58, green: 0.10, blue: 0.25)
        case "keyword-secondKeyWord": Color(red: 0.00, green: 0.46, blue: 0.43)
        case "keyword-loveKeyword": Color(red: 0.72, green: 0.48, blue: 0.08)
        default: Color.accentColor
        }
    }

    private func annualSectionSymbol(_ id: String) -> String {
        if id.hasPrefix("keyword-") { return "text.quote" }
        return switch id {
        case "listening-methods": "headphones"
        case "annual-song": "music.note"
        case "annual-singer": "music.mic"
        case "favorite-album": "square.stack.fill"
        case "annual-playlist": "list.number"
        case "genres": "waveform"
        case "discoveries": "sparkles"
        case "seasons": "leaf.fill"
        case "months": "calendar"
        case "listening-times": "clock.fill"
        case "late-listening": "moon.stars.fill"
        case "loop-song": "repeat"
        case "crowd-memory": "person.3.fill"
        case "monthly-moods": "heart.fill"
        case "listen-together": "person.2.fill"
        case "singer-comparison": "chart.line.uptrend.xyaxis"
        default: "music.note.list"
        }
    }

    private func mergedMetrics(_ first: [ListeningMetric], _ second: [ListeningMetric]) -> [ListeningMetric] {
        var seen = Set<ListeningMetricKind>()
        return (first + second).filter { seen.insert($0.kind).inserted }
    }

    private func annualMetricText(_ value: AnnualReportMetricValue) -> String {
        switch value {
        case let .number(number, suffix): "\(number.formatted()) \(suffix)"
        case let .duration(seconds): durationText(seconds)
        case let .date(milliseconds):
            Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1_000)
                .formatted(date: .abbreviated, time: .omitted)
        case let .text(text): text
        }
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

#if os(macOS)
private struct MacTopTabScrollPositionAccessor<Selection: Hashable>: NSViewRepresentable {
    let selection: Selection
    let positions: TopTabScrollPositions<Selection>

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> MacScrollPositionMarkerView {
        let view = MacScrollPositionMarkerView()
        view.onLayout = { [weak coordinator = context.coordinator] view in
            coordinator?.restoreIfNeeded(from: view)
        }
        return view
    }

    func updateNSView(_ view: MacScrollPositionMarkerView, context: Context) {
        context.coordinator.update(selection: selection, positions: positions, from: view)
        view.needsLayout = true
    }

    static func dismantleNSView(_ view: MacScrollPositionMarkerView, coordinator: Coordinator) {
        coordinator.save()
        view.onLayout = nil
    }

    @MainActor
    final class Coordinator {
        private var selection: Selection?
        private var positions: TopTabScrollPositions<Selection>?
        private weak var scrollView: NSScrollView?
        private var needsRestore = true

        func update(
            selection: Selection,
            positions: TopTabScrollPositions<Selection>,
            from view: NSView
        ) {
            if let previous = self.selection, previous != selection { save() }
            if self.selection != selection || self.positions !== positions { needsRestore = true }
            self.selection = selection
            self.positions = positions
            positions.select(selection)
            connect(to: view)
        }

        func restoreIfNeeded(from view: NSView) {
            connect(to: view)
            guard needsRestore,
                  let selection,
                  let positions,
                  let scrollView
            else { return }
            let clipView = scrollView.contentView
            clipView.scroll(to: NSPoint(x: clipView.bounds.origin.x, y: positions.offset(for: selection)))
            scrollView.reflectScrolledClipView(clipView)
            needsRestore = false
        }

        func save() {
            guard let selection, let positions, let scrollView else { return }
            positions.record(scrollView.contentView.bounds.origin.y, for: selection)
        }

        private func connect(to view: NSView) {
            guard let enclosingScrollView = view.enclosingScrollView else { return }
            if scrollView !== enclosingScrollView {
                save()
                scrollView = enclosingScrollView
                needsRestore = true
            }
        }
    }
}

@MainActor
private final class MacScrollPositionMarkerView: NSView {
    var onLayout: ((NSView) -> Void)?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        onLayout?(self)
    }
}
#endif

private struct AnnualGenreShare: Identifiable {
    let name: String
    let percent: Int64
    var id: String { name }
}

enum FootprintPeriod: String, CaseIterable, Sendable {
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

struct FootprintPage {
    let cursor: ListeningReportCursor?
    let title: String
    let metrics: [ListeningMetric]
    let ranks: [ListeningRankEntry]
    let yearFootprints: [YearListeningFootprint]
    let previousCursor: ListeningReportCursor?
}

struct FootprintPeriodState {
    var pages: [FootprintPage] = []
    var seenCursors = Set<ListeningReportCursor>()
    var pendingCursor: ListeningReportCursor?
    var failedCursor: ListeningReportCursor?
    var isLoading = false
    var error: String?

    mutating func begin(cursor: ListeningReportCursor?) {
        isLoading = true
        pendingCursor = cursor
        failedCursor = nil
        error = nil
    }

    mutating func cancel() {
        isLoading = false
        pendingCursor = nil
    }

    mutating func fail(cursor: ListeningReportCursor?, message: String) {
        cancel()
        failedCursor = cursor
        error = message
    }
}

struct FootprintLoadIdentity: Equatable, Sendable {
    let period: FootprintPeriod
    let generation: Int
    let accountID: Int64
    let credentialRevision: UInt64

    func isCurrent(generation: Int?, accountID: Int64?, credentialRevision: UInt64) -> Bool {
        self.generation == generation
            && self.accountID == accountID
            && self.credentialRevision == credentialRevision
    }
}

private struct FootprintRootTaskID: Hashable {
    let accountID: Int64?
    let credentialRevision: UInt64
}

@MainActor
final class FootprintLoadOwner {
    private var generations: [FootprintPeriod: Int] = [:]
    private var tasks: [FootprintPeriod: Task<Void, Never>] = [:]
    private var taskIDs: [FootprintPeriod: UUID] = [:]

    isolated deinit { tasks.values.forEach { $0.cancel() } }

    func hasTask(for period: FootprintPeriod) -> Bool { tasks[period] != nil }

    @discardableResult
    func start(
        period: FootprintPeriod,
        accountID: Int64,
        credentialRevision: UInt64,
        currentAccountID: @escaping @MainActor @Sendable () -> Int64?,
        currentCredentialRevision: @escaping @MainActor @Sendable () -> UInt64,
        load: @escaping @MainActor @Sendable () async throws -> FootprintPage,
        success: @escaping @MainActor @Sendable (FootprintPage, FootprintLoadIdentity) -> Void,
        failure: @escaping @MainActor @Sendable (Error, FootprintLoadIdentity) -> Void,
        finish: @escaping @MainActor @Sendable (FootprintLoadIdentity) -> Void
    ) -> Task<Void, Never> {
        tasks[period]?.cancel()
        generations[period, default: 0] &+= 1
        let identity = FootprintLoadIdentity(
            period: period,
            generation: generations[period, default: 0],
            accountID: accountID,
            credentialRevision: credentialRevision
        )
        let taskID = UUID()
        taskIDs[period] = taskID
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.taskIDs[period] == taskID,
                   self.generations[period] == identity.generation {
                    self.tasks[period] = nil
                    self.taskIDs[period] = nil
                    finish(identity)
                }
            }
            do {
                let page = try await load()
                try Task.checkCancellation()
                guard self.accepts(
                    identity,
                    currentAccountID: currentAccountID(),
                    currentCredentialRevision: currentCredentialRevision()
                ) else { return }
                success(page, identity)
            } catch is CancellationError {
            } catch {
                guard self.accepts(
                    identity,
                    currentAccountID: currentAccountID(),
                    currentCredentialRevision: currentCredentialRevision()
                ) else { return }
                failure(error, identity)
            }
        }
        tasks[period] = task
        return task
    }

    @discardableResult
    func cancel(_ period: FootprintPeriod) -> Bool {
        guard let task = tasks.removeValue(forKey: period) else { return false }
        task.cancel()
        taskIDs[period] = nil
        generations[period, default: 0] &+= 1
        return true
    }

    func invalidate(_ period: FootprintPeriod) {
        tasks.removeValue(forKey: period)?.cancel()
        taskIDs[period] = nil
        generations[period, default: 0] &+= 1
    }

    @discardableResult
    func cancelAll() -> Set<FootprintPeriod> {
        let active = Set(tasks.keys)
        tasks.values.forEach { $0.cancel() }
        tasks = [:]
        taskIDs = [:]
        FootprintPeriod.allCases.forEach { generations[$0, default: 0] &+= 1 }
        return active
    }

    private func accepts(
        _ identity: FootprintLoadIdentity,
        currentAccountID: Int64?,
        currentCredentialRevision: UInt64
    ) -> Bool {
        identity.isCurrent(
            generation: generations[identity.period],
            accountID: currentAccountID,
            credentialRevision: currentCredentialRevision
        )
    }
}

@MainActor
func waitForFootprintLoad(_ task: Task<Void, Never>?) async {
    guard let task else { return }
    await withTaskCancellationHandler {
        await task.value
    } onCancel: {
        task.cancel()
    }
}

struct FootprintHistoryRefreshState: Sendable {
    private var isVisible = false
    private var lastSequence: UInt64?
    private var pendingSequences: [FootprintPeriod: UInt64] = [:]

    mutating func setVisible(_ visible: Bool) {
        isVisible = visible
    }

    mutating func resetEvents() {
        lastSequence = nil
        pendingSequences = [:]
    }

    mutating func consume(
        _ event: PlaybackHistoryEvent?,
        credentialRevision: UInt64,
        hasAccount: Bool
    ) {
        guard let event, event.sequence > (lastSequence ?? 0) else { return }
        lastSequence = event.sequence
        guard event.credentialRevision == credentialRevision, hasAccount else { return }
        for period in FootprintPeriod.allCases {
            pendingSequences[period] = event.sequence
        }
    }

    func pendingSequence(for period: FootprintPeriod) -> UInt64? {
        pendingSequences[period]
    }

    func nextSequence(for period: FootprintPeriod, isLoading: Bool, hasAccount: Bool) -> UInt64? {
        guard isVisible, hasAccount, !isLoading else { return nil }
        return pendingSequences[period]
    }

    mutating func settle(_ period: FootprintPeriod, sequence: UInt64) {
        guard pendingSequences[period] == sequence else { return }
        pendingSequences.removeValue(forKey: period)
    }
}

struct FootprintSources: Sendable {
    let report: ListeningReport
    let ranks: [ListeningRankEntry]
    let realtime: ListeningReport?
}

func loadFootprintSources(
    cursor: ListeningReportCursor?,
    report: @escaping @Sendable () async throws -> ListeningReport,
    ranks: @escaping @Sendable () async throws -> [ListeningRankEntry],
    realtime: @escaping @Sendable () async throws -> ListeningReport
) async throws -> FootprintSources {
    async let loadedReport = report()
    async let loadedRanks = ranks()
    let loadedRealtime: ListeningReport? = if cursor == nil { try await realtime() } else { nil }
    let (reportValue, rankValues) = try await (loadedReport, loadedRanks)
    return FootprintSources(report: reportValue, ranks: rankValues, realtime: loadedRealtime)
}

struct AnnualReportSelection {
    static func defaultYear(
        current: Int?,
        footprints: [YearListeningFootprint],
        sortedYears: [Int]? = nil
    ) -> Int? {
        let years = sortedYears ?? footprints.map(\.year).sorted(by: >)
        if current.map({ years.contains($0) }) == true { return current }
        return years.first
    }
}

struct AnnualReportLoadIdentity: Equatable, Sendable {
    let generation: Int
    let year: Int
    let accountID: Int64
    let credentialRevision: UInt64
}

struct AnnualReportPhaseState: Sendable {
    private(set) var report: AnnualListeningReport?
    private(set) var error: String?
    private(set) var enrichmentError: String?
    private(set) var isLoading = false
    private(set) var generation = 0
    private var consumedReload = 0

    mutating func reset() {
        generation &+= 1
        report = nil
        error = nil
        enrichmentError = nil
        isLoading = false
        consumedReload = 0
    }

    mutating func cancel() {
        generation &+= 1
        isLoading = false
    }

    mutating func begin(
        year: Int?,
        accountID: Int64?,
        credentialRevision: UInt64,
        reload: Int,
        canLoad: Bool
    ) -> (AnnualReportLoadIdentity, forceRefresh: Bool)? {
        generation &+= 1
        error = nil
        enrichmentError = nil
        isLoading = false
        guard canLoad, let year, let accountID else { return nil }
        if report?.year != year { report = nil }
        let forceRefresh = reload != consumedReload
        consumedReload = reload
        isLoading = true
        return (AnnualReportLoadIdentity(
            generation: generation,
            year: year,
            accountID: accountID,
            credentialRevision: credentialRevision
        ), forceRefresh)
    }

    @discardableResult
    mutating func commitBase(
        _ report: AnnualListeningReport,
        identity: AnnualReportLoadIdentity,
        currentYear: Int?,
        currentAccountID: Int64?,
        currentCredentialRevision: UInt64
    ) -> Bool {
        guard accepts(
            identity,
            currentYear: currentYear,
            currentAccountID: currentAccountID,
            currentCredentialRevision: currentCredentialRevision
        ) else {
            return false
        }
        self.report = report
        isLoading = false
        return true
    }

    mutating func commitEnrichment(
        _ report: AnnualListeningReport,
        identity: AnnualReportLoadIdentity,
        currentYear: Int?,
        currentAccountID: Int64?,
        currentCredentialRevision: UInt64
    ) {
        guard accepts(
            identity,
            currentYear: currentYear,
            currentAccountID: currentAccountID,
            currentCredentialRevision: currentCredentialRevision
        ) else { return }
        self.report = report
    }

    mutating func commitEnrichmentFailure(
        _ message: String,
        identity: AnnualReportLoadIdentity,
        currentYear: Int?,
        currentAccountID: Int64?,
        currentCredentialRevision: UInt64
    ) {
        guard accepts(
            identity,
            currentYear: currentYear,
            currentAccountID: currentAccountID,
            currentCredentialRevision: currentCredentialRevision
        ) else { return }
        enrichmentError = message
    }

    mutating func commitFailure(
        _ message: String,
        identity: AnnualReportLoadIdentity,
        currentYear: Int?,
        currentAccountID: Int64?,
        currentCredentialRevision: UInt64
    ) {
        guard accepts(
            identity,
            currentYear: currentYear,
            currentAccountID: currentAccountID,
            currentCredentialRevision: currentCredentialRevision
        ) else { return }
        error = message
    }

    mutating func finish(
        _ identity: AnnualReportLoadIdentity
    ) {
        guard generation == identity.generation else { return }
        isLoading = false
    }

    private func accepts(
        _ identity: AnnualReportLoadIdentity,
        currentYear: Int?,
        currentAccountID: Int64?,
        currentCredentialRevision: UInt64
    ) -> Bool {
        generation == identity.generation
            && currentYear == identity.year
            && currentAccountID == identity.accountID
            && currentCredentialRevision == identity.credentialRevision
    }
}

@MainActor
@Observable
final class AnnualReportLoader {
    private(set) var state = AnnualReportPhaseState()

    @ObservationIgnored private var currentYear: Int?
    @ObservationIgnored private var currentAccountID: Int64?
    @ObservationIgnored private var loadedCredentialRevision: UInt64?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var taskID: UUID?

    var hasTask: Bool { task != nil }

    isolated deinit { task?.cancel() }

    @discardableResult
    func start(
        year: Int?,
        accountID: Int64?,
        credentialRevision: UInt64,
        reload: Int,
        canLoad: Bool,
        currentYear: @escaping @MainActor @Sendable () -> Int?,
        currentAccountID: @escaping @MainActor @Sendable () -> Int64?,
        currentCredentialRevision: @escaping @MainActor @Sendable () -> UInt64,
        report: @escaping @MainActor @Sendable (Int, Bool) async throws -> AnnualListeningReport,
        songs: @escaping @MainActor @Sendable ([Int64]) async throws -> [Song]
    ) -> Task<Void, Never>? {
        task?.cancel()
        task = nil
        taskID = nil
        if self.currentAccountID != accountID || loadedCredentialRevision != credentialRevision { state.reset() }
        self.currentYear = year
        self.currentAccountID = accountID
        loadedCredentialRevision = credentialRevision
        guard let (identity, forceRefresh) = state.begin(
            year: year,
            accountID: accountID,
            credentialRevision: credentialRevision,
            reload: reload,
            canLoad: canLoad
        ) else { return nil }

        let taskID = UUID()
        self.taskID = taskID
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.taskID == taskID {
                    self.state.finish(
                        identity
                    )
                    self.task = nil
                    self.taskID = nil
                }
            }
            do {
                let loaded = try await report(identity.year, forceRefresh)
                try Task.checkCancellation()
                guard self.state.commitBase(
                    loaded,
                    identity: identity,
                    currentYear: currentYear(),
                    currentAccountID: currentAccountID(),
                    currentCredentialRevision: currentCredentialRevision()
                ) else { return }

                let songIDs = Set(loaded.sections.flatMap { section in
                    section.tracks.compactMap { track in
                        track.song.album.artwork.remoteURL == nil || track.song.artists.isEmpty
                            ? track.song.id
                            : nil
                    }
                }).sorted()
                guard !songIDs.isEmpty else { return }
                let detailedSongs: [Song]
                do {
                    detailedSongs = try await songs(songIDs)
                } catch is CancellationError {
                    return
                } catch {
                    self.state.commitEnrichmentFailure(
                        error.localizedDescription,
                        identity: identity,
                        currentYear: currentYear(),
                        currentAccountID: currentAccountID(),
                        currentCredentialRevision: currentCredentialRevision()
                    )
                    return
                }
                try Task.checkCancellation()
                self.state.commitEnrichment(
                    replacingAnnualReportSongs(in: loaded, with: detailedSongs),
                    identity: identity,
                    currentYear: currentYear(),
                    currentAccountID: currentAccountID(),
                    currentCredentialRevision: currentCredentialRevision()
                )
            } catch is CancellationError {
            } catch {
                self.state.commitFailure(
                    error.localizedDescription,
                    identity: identity,
                    currentYear: currentYear(),
                    currentAccountID: currentAccountID(),
                    currentCredentialRevision: currentCredentialRevision()
                )
            }
        }
        self.task = task
        return task
    }

    func cancel() {
        task?.cancel()
        task = nil
        taskID = nil
        state.cancel()
    }

    func reset() {
        task?.cancel()
        task = nil
        taskID = nil
        currentYear = nil
        currentAccountID = nil
        loadedCredentialRevision = nil
        state.reset()
    }
}

func replacingAnnualReportSongs(
    in report: AnnualListeningReport,
    with songs: [Song]
) -> AnnualListeningReport {
    let songsByID = Dictionary(songs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    guard !songsByID.isEmpty else { return report }
    return AnnualListeningReport(
        year: report.year,
        overviewMetrics: report.overviewMetrics,
        sections: report.sections.map { section in
            AnnualReportSection(
                id: section.id,
                title: section.title,
                subtitle: section.subtitle,
                artworkURL: section.artworkURL,
                metrics: section.metrics,
                details: section.details,
                items: section.items,
                tracks: section.tracks.map { track in
                    AnnualReportTrack(
                        id: track.id,
                        song: songsByID[track.song.id] ?? track.song,
                        caption: track.caption,
                        playCount: track.playCount
                    )
                }
            )
        }
    )
}

private struct AnnualReportTaskID: Hashable {
    let accountID: Int64?
    let credentialRevision: UInt64
    let period: FootprintPeriod
    let year: Int?
    let reload: Int
}
