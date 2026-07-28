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
    @State private var selectedAnnualYear: Int?
    @State private var annualReport: AnnualListeningReport?
    @State private var annualReportError: String?
    @State private var isLoadingAnnualReport = false
    @State private var annualReportGeneration = 0
    @State private var annualReportReload = 0
    @State private var consumedAnnualReportReload = 0

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
        .task(id: AnnualReportTaskID(
            accountID: model.currentUserID,
            period: selectedPeriod,
            year: selectedAnnualYear,
            reload: annualReportReload
        )) { await loadAnnualReport() }
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
        HStack(spacing: 16) {
            Label("年度报告", systemImage: "calendar")
                .font(.headline)
                .foregroundStyle(.primary)
            Spacer(minLength: 16)
            Text("报告年份")
                .font(.caption)
                .foregroundStyle(.secondary)
            Picker("报告年份", selection: $selectedAnnualYear) {
                ForEach(years, id: \.self) { year in
                    Text("\(year) 年").tag(Optional(year))
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 52)
        .background(.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(.primary.opacity(0.07), lineWidth: 1)
        }
    }

    private func annualHero(year: Int, metrics: [ListeningMetric]) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            annualHeroTitle(year: year)
            if let songCount = listeningMetric(.plays, in: metrics) {
                Text("今年你一共听过 \(songCount.formatted()) 首歌")
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
                .font(.system(size: 42, weight: .bold))
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
        } else if isLoadingAnnualReport {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("正在加载年度报告…").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 120)
        } else if let annualReportError {
            HStack(spacing: 12) {
                Label("年度报告不可用", systemImage: "wifi.exclamationmark")
                Text(annualReportError)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer()
                Button("重试") { annualReportReload &+= 1 }
            }
            .padding(16)
            .background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
        } else if let annualReport, annualReport.year == selectedAnnualYear {
            if annualReport.sections.isEmpty {
                ContentUnavailableView("该年度暂无报告内容", systemImage: "doc.text")
                    .frame(maxWidth: .infinity, minHeight: 180)
            } else {
                let hasDiscoveries = annualReport.sections.contains { $0.id == "discoveries" }
                let sections = annualReport.sections.filter { $0.id != "genres" || !hasDiscoveries }
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
            }
        }
    }

    private func annualSection(_ section: AnnualReportSection) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            annualSectionIdentity(section)
            if ["annual-song", "annual-singer", "favorite-album"].contains(section.id),
               let artworkURL = annualArtworkURL(section) {
                ArtworkView(artwork: Artwork(symbol: "music.note", accent: .red, remoteURL: artworkURL))
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
            } else if section.id.hasPrefix("keyword-") {
                annualKeyword(section)
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
                    .font(.system(size: 32, weight: .bold))
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
                if shares.count <= 5 {
                    AnnualGenrePieChart(shares: shares, colors: annualGenreColors)
                        .frame(width: 190, height: 190)
                        .frame(maxWidth: .infinity)
                    VStack(alignment: .leading, spacing: 9) {
                        ForEach(Array(shares.enumerated()), id: \.element.id) { index, share in
                            HStack(spacing: 9) {
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(annualGenreColors[index % annualGenreColors.count])
                                    .frame(width: 14, height: 14)
                                Text(share.name)
                                    .foregroundStyle(.primary)
                                Spacer(minLength: 12)
                                Text("\(share.percent)%")
                                    .font(.callout.weight(.semibold).monospacedDigit())
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                } else {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(Array(shares.enumerated()), id: \.element.id) { index, share in
                            VStack(alignment: .leading, spacing: 5) {
                                HStack {
                                    Text(share.name)
                                    Spacer(minLength: 12)
                                    Text("\(share.percent)%")
                                        .font(.callout.weight(.semibold).monospacedDigit())
                                }
                                ProgressView(value: Double(share.percent), total: 100)
                                    .tint(annualGenreColors[index % annualGenreColors.count])
                            }
                            .accessibilityElement(children: .combine)
                        }
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
            .buttonStyle(.plain)
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
            ArtworkView(artwork: Artwork(symbol: "music.mic", accent: .cyan, remoteURL: imageURL))
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
            .buttonStyle(.plain)
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
            Text("\(month)")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 26, alignment: .trailing)
            ArtworkView(artwork: Artwork(symbol: "music.mic", accent: .blue, remoteURL: imageURL))
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
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 190, maximum: 320), spacing: 10)], spacing: 10) {
            ForEach(items) { item in
                if case let .mood(month, name, genre) = item {
                    HStack(spacing: 12) {
                        Text("\(month) 月")
                            .font(.callout.weight(.bold).monospacedDigit())
                            .foregroundStyle(.white)
                            .frame(width: 48, height: 36)
                            .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 6))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(name).font(.headline).foregroundStyle(.primary)
                            if let genre { Text(genre).font(.caption).foregroundStyle(.secondary) }
                        }
                        Spacer(minLength: 4)
                    }
                    .frame(maxWidth: .infinity, minHeight: 62, alignment: .leading)
                    .padding(.horizontal, 12)
                    .background(Color.accentColor.opacity(0.13), in: RoundedRectangle(cornerRadius: 7))
                    .overlay {
                        RoundedRectangle(cornerRadius: 7)
                            .stroke(Color.accentColor.opacity(0.28), lineWidth: 1)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    private func annualKeyword(_ section: AnnualReportSection) -> some View {
        HStack(alignment: .lastTextBaseline, spacing: 16) {
            Text(section.subtitle ?? "")
                .font(.system(size: 48, weight: .bold))
                .lineLimit(2)
                .minimumScaleFactor(0.65)
                .layoutPriority(1)
            Spacer(minLength: 8)
            if let count = annualNumber("出现次数", in: section.metrics) {
                Text("出现 \(count.formatted()) 次")
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 72, alignment: .bottomLeading)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func annualTracks(_ section: AnnualReportSection) -> some View {
        if !section.tracks.isEmpty {
            let songs = section.tracks.map(\.song)
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(section.tracks.enumerated()), id: \.element.id) { index, track in
                    annualTrackRow(track, number: index + 1, songs: songs)
                }
            }
        }
    }

    private func annualMetrics(_ values: [AnnualReportMetric]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 142, maximum: 240), spacing: 12)], spacing: 12) {
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

    private func annualTrackRow(_ track: AnnualReportTrack, number: Int, songs: [Song]) -> some View {
        HStack(spacing: 12) {
            Text("\(number)")
                .font(.callout.monospacedDigit())
                .foregroundStyle(number <= 3 ? Color.accentColor : Color.secondary)
                .frame(width: 26, alignment: .trailing)
            ArtworkView(artwork: track.song.album.artwork)
                .frame(width: 46, height: 46)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .accessibilityLabel("\(track.song.name)封面")
            VStack(alignment: .leading, spacing: 3) {
                SongTitleText(song: track.song).font(.body.weight(.medium)).lineLimit(1)
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
            SongContextMenu(song: track.song, songs: songs, model: model, player: player)
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
        annualReportGeneration &+= 1
        selectedAnnualYear = nil
        annualReport = nil
        annualReportError = nil
        isLoadingAnnualReport = false
        annualReportReload = 0
        consumedAnnualReportReload = 0
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
    private func loadAnnualReport() async {
        annualReportGeneration &+= 1
        let generation = annualReportGeneration
        annualReport = nil
        annualReportError = nil
        isLoadingAnnualReport = false
        guard selectedPeriod == .year,
              let year = selectedAnnualYear,
              AnnualListeningReportDecoder.supportedYears.contains(year),
              let accountID = model.currentUserID
        else { return }

        let forceRefresh = annualReportReload != consumedAnnualReportReload
        consumedAnnualReportReload = annualReportReload
        isLoadingAnnualReport = true
        defer {
            if annualReportGeneration == generation { isLoadingAnnualReport = false }
        }
        do {
            let loaded = try await library.annualListeningReport(
                year: year,
                forceRefresh: forceRefresh
            )
            let songIDs = Set(loaded.sections.flatMap { section in
                section.tracks.compactMap { track in
                    track.song.album.artwork.remoteURL == nil || track.song.artists.isEmpty ? track.song.id : nil
                }
            }).sorted()
            let detailedSongs = songIDs.isEmpty
                ? []
                : (try? await model.repository.songs(ids: songIDs)) ?? []
            let report = replacingSongs(in: loaded, with: detailedSongs)
            try Task.checkCancellation()
            guard annualReportGeneration == generation,
                  selectedAnnualYear == year,
                  model.currentUserID == accountID
            else { return }
            annualReport = report
        } catch is CancellationError {
        } catch {
            guard annualReportGeneration == generation,
                  selectedAnnualYear == year,
                  model.currentUserID == accountID
            else { return }
            annualReportError = error.localizedDescription
        }
    }

    @MainActor
    private func refresh() {
        if selectedPeriod == .year, activeState.pages.last?.cursor == nil {
            annualReportReload &+= 1
        }
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
            let footprints = try await library.yearListeningFootprints(forceRefresh: force)
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
        if period == .year, page.cursor == nil {
            let years = annualYears(page.yearFootprints)
            if selectedAnnualYear.map({ years.contains($0) }) != true {
                selectedAnnualYear = page.yearFootprints.first?.year
                    ?? years.first(where: AnnualListeningReportDecoder.supportedYears.contains)
            }
        }
    }

    private func annualYears(_ footprints: [YearListeningFootprint]) -> [Int] {
        footprints.map(\.year).sorted(by: >)
    }

    private func annualSummaryMetrics(
        year: Int,
        footprints: [YearListeningFootprint]
    ) -> [ListeningMetric] {
        if annualReport?.year == year { return annualReport?.overviewMetrics ?? [] }
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

    private func replacingSongs(
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

private struct AnnualGenreShare: Identifiable {
    let name: String
    let percent: Int64
    var id: String { name }
}

private struct AnnualGenrePieChart: View {
    let shares: [AnnualGenreShare]
    let colors: [Color]

    var body: some View {
        Canvas { context, size in
            let total = max(1, shares.reduce(Int64(0)) { $0 + $1.percent })
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let radius = min(size.width, size.height) / 2
            var start = -Double.pi / 2
            for (index, share) in shares.enumerated() {
                let end = start + Double(share.percent) / Double(total) * 2 * Double.pi
                var path = Path()
                path.move(to: center)
                path.addArc(
                    center: center,
                    radius: radius,
                    startAngle: Angle(radians: start),
                    endAngle: Angle(radians: end),
                    clockwise: false
                )
                path.closeSubpath()
                context.fill(path, with: .color(colors[index % colors.count]))
                start = end
            }
        }
        .overlay { Circle().stroke(.background, lineWidth: 2) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(shares.map { "\($0.name) \($0.percent)%" }.joined(separator: "，"))
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

private struct AnnualReportTaskID: Hashable {
    let accountID: Int64?
    let period: FootprintPeriod
    let year: Int?
    let reload: Int
}
