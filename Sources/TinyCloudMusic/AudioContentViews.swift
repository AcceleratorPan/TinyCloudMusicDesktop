import AVFoundation
import Observation
import SwiftUI

private enum AudioContentTab: String, CaseIterable {
    case podcasts = "播客"
    case broadcasts = "广播"
}

private enum AudioContentPhase<Value> {
    case loading
    case loaded(Value)
    case failed(String)
}

enum PodcastSubscriptionProjection {
    static func podcast(_ podcast: Podcast, override: Bool?) -> Podcast {
        guard let override, override != podcast.isSubscribed else { return podcast }
        return podcast.settingSubscribed(override)
    }

    static func podcasts(
        _ podcasts: [Podcast],
        subscribedOnly: Bool,
        override: (Int64) -> Bool?
    ) -> [Podcast] {
        podcasts.compactMap { podcast in
            let projected = Self.podcast(podcast, override: override(podcast.id))
            return subscribedOnly && !projected.isSubscribed ? nil : projected
        }
    }

    static func page(
        _ page: PodcastPage,
        override: (Int64) -> Bool?
    ) -> PodcastPage {
        PodcastPage(
            podcasts: podcasts(
                page.podcasts,
                subscribedOnly: true,
                override: override
            ),
            nextOffset: page.nextOffset,
            hasMore: page.hasMore
        )
    }
}

@MainActor
@Observable
private final class PodcastDiscoveryState {
    var categories: [PodcastCategory] = []
    var selectedCategoryID: Int64?
    var showsSubscriptions = false
    var phase: AudioContentPhase<[Podcast]> = .loading
    var categoryGeneration = 0
    var loadGeneration = 0
    var loadedCategoryID: Int64?
    var loadedSubscriptions = false
    var loadedAccountID: Int64?
    var loadedCredentialRevision: UInt64?
    var loadedSubscriptionRevision: UInt64 = 0
    var loadedUploadRevision = 0
    var hasLoaded = false
    var retryRevision = 0
}

@MainActor
@Observable
private final class BroadcastDiscoveryState {
    var filters = BroadcastFilters(categories: [], regions: [])
    var categoryID = "0"
    var regionID = "0"
    var phase: AudioContentPhase<BroadcastChannelPage> = .loading
    var isLoadingMore = false
    var loadGeneration = 0
    var loadedCategoryID = ""
    var loadedRegionID = ""
    var loadedAccountID: Int64?
    var hasLoaded = false
    var filterGeneration = 0
    var retryRevision = 0
    @ObservationIgnored var loadMoreTask: Task<Void, Never>?
}

struct AudioContentView: View {
    let library: LiveAudioContentLibrary
    @Bindable var model: AppModel
    @Bindable var player: PlayerController

    @State private var selectedTab = AudioContentTab.podcasts
    @State private var showsPodcastUploads = false
    @State private var podcastState = PodcastDiscoveryState()
    @State private var broadcastState = BroadcastDiscoveryState()

    var body: some View {
        VStack(spacing: 0) {
            Picker("音频类型", selection: $selectedTab) {
                ForEach(AudioContentTab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 260)
            .padding(16)

            Divider()

            switch selectedTab {
            case .podcasts:
                PodcastDiscoveryView(
                    library: library,
                    model: model,
                    player: player,
                    state: podcastState
                )
            case .broadcasts:
                BroadcastDiscoveryView(library: library, model: model, state: broadcastState)
            }
        }
        .navigationTitle("播客与广播")
        .toolbar {
            if selectedTab == .podcasts, model.currentUserID != nil, model.uploads != nil {
                ToolbarItem {
                    Button { showsPodcastUploads = true } label: { Image(systemName: "mic.badge.plus") }
                        .help("上传播客声音")
                        .accessibilityLabel("上传播客声音")
                }
            }
        }
        .sheet(isPresented: $showsPodcastUploads) {
            if let uploads = model.uploads, let accountID = model.currentUserID {
                MyPodcastUploadView(
                    library: library,
                    manager: uploads,
                    model: model,
                    accountID: accountID
                )
            }
        }
    }
}

private struct PodcastDiscoveryView: View {
    let library: LiveAudioContentLibrary
    @Bindable var model: AppModel
    @Bindable var player: PlayerController
    @Bindable var state: PodcastDiscoveryState

    private var subscriptionCredentialRevision: UInt64 {
        state.showsSubscriptions ? library.transport.credentialSnapshotValue().revision : 0
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                if !state.showsSubscriptions {
                    Picker("分类", selection: $state.selectedCategoryID) {
                        ForEach(state.categories) { Text($0.name).tag(Optional($0.id)) }
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: 220, alignment: .leading)
                } else {
                    Text("已订阅的播客")
                        .font(.headline)
                }
                Spacer()
                Button {
                    guard model.currentUserID != nil else {
                        model.selectSidebar(.session)
                        return
                    }
                    state.showsSubscriptions.toggle()
                } label: {
                    Image(systemName: state.showsSubscriptions ? "star.fill" : "star")
                }
                .help(state.showsSubscriptions ? "浏览分类推荐" : "查看订阅")
                .accessibilityLabel(state.showsSubscriptions ? "浏览分类推荐" : "查看订阅")
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 12)

            Divider()
            phaseContent
        }
        .task(id: state.retryRevision) { await loadCategories() }
        .task(id: "\(state.selectedCategoryID ?? 0):\(state.showsSubscriptions):\(model.currentUserID ?? 0):\(subscriptionCredentialRevision):\(model.podcastSubscriptionRevision):\(model.uploads?.podcastCompletionRevision ?? 0):\(state.retryRevision)") {
            await loadPodcasts()
        }
        .onDisappear {
            state.categoryGeneration += 1
            state.loadGeneration += 1
        }
    }

    @ViewBuilder
    private var phaseContent: some View {
        switch state.phase {
        case .loading:
            ProgressView("正在加载播客")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case let .failed(message):
            ContentUnavailableView {
                Label("播客加载失败", systemImage: "wifi.exclamationmark")
            } description: {
                Text(message)
            } actions: {
                Button("重试") { state.retryRevision += 1 }
            }
        case let .loaded(podcasts):
            let podcasts = displayedPodcasts(podcasts)
            if podcasts.isEmpty {
                ContentUnavailableView("暂无播客", systemImage: "dot.radiowaves.left.and.right")
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(podcasts) { podcast in
                            Button { model.open(.podcast(podcast.id)) } label: {
                                PodcastRow(podcast: podcast)
                            }
                            .buttonStyle(.plain)
                            Divider().padding(.leading, 76)
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 8)
                }
            }
        }
    }

    private func displayedPodcasts(_ podcasts: [Podcast]) -> [Podcast] {
        _ = model.podcastSubscriptionRevision
        guard state.loadedAccountID == model.currentUserID else { return [] }
        return PodcastSubscriptionProjection.podcasts(
            podcasts,
            subscribedOnly: state.showsSubscriptions,
            override: model.podcastSubscriptionOverride
        )
    }

    @MainActor
    private func loadCategories() async {
        guard state.categories.isEmpty else { return }
        state.categoryGeneration += 1
        let generation = state.categoryGeneration
        do {
            let values = try await library.podcastCategories()
            try Task.checkCancellation()
            guard state.categoryGeneration == generation else { return }
            state.categories = values
            if state.selectedCategoryID == nil { state.selectedCategoryID = values.first?.id }
        } catch is CancellationError {
        } catch {
            guard state.categoryGeneration == generation else { return }
            state.phase = .failed(error.localizedDescription)
        }
    }

    @MainActor
    private func loadPodcasts() async {
        let categoryID = state.selectedCategoryID
        let subscriptions = state.showsSubscriptions
        let accountID = model.currentUserID
        let credentialRevision = library.transport.credentialSnapshotValue().revision
        let subscriptionRevision = model.podcastSubscriptionRevision
        let uploadRevision = model.uploads?.podcastCompletionRevision ?? 0
        if !subscriptions, categoryID == nil { return }
        if subscriptions, accountID == nil {
            state.phase = .loaded([])
            return
        }
        if state.hasLoaded,
           state.loadedCategoryID == categoryID,
           state.loadedSubscriptions == subscriptions,
           state.loadedAccountID == accountID,
           (!subscriptions || state.loadedCredentialRevision == credentialRevision),
           state.loadedUploadRevision == uploadRevision,
           (!subscriptions || state.loadedSubscriptionRevision == subscriptionRevision) {
            return
        }
        state.loadGeneration += 1
        let generation = state.loadGeneration
        state.phase = .loading
        do {
            let values = if subscriptions {
                try await library.subscribedPodcasts(
                    refreshCache: true,
                    expectedCredentialRevision: credentialRevision
                ).podcasts
            } else {
                try await library.recommendedPodcasts(
                    categoryID: categoryID ?? 0,
                    refreshCache: state.hasLoaded && state.loadedUploadRevision != uploadRevision
                )
            }
            try Task.checkCancellation()
            guard state.loadGeneration == generation,
                  subscriptions == state.showsSubscriptions,
                  categoryID == state.selectedCategoryID,
                  accountID == model.currentUserID,
                  (!subscriptions || library.transport.credentialSnapshotValue().revision == credentialRevision)
            else { return }
            state.loadedCategoryID = categoryID
            state.loadedSubscriptions = subscriptions
            state.loadedAccountID = accountID
            state.loadedCredentialRevision = subscriptions ? credentialRevision : nil
            state.loadedSubscriptionRevision = subscriptionRevision
            state.loadedUploadRevision = uploadRevision
            state.hasLoaded = true
            state.phase = .loaded(values)
        } catch is CancellationError {
        } catch {
            guard state.loadGeneration == generation,
                  subscriptions == state.showsSubscriptions,
                  categoryID == state.selectedCategoryID,
                  accountID == model.currentUserID,
                  (!subscriptions || library.transport.credentialSnapshotValue().revision == credentialRevision)
            else { return }
            state.phase = .failed(error.localizedDescription)
        }
    }
}

private struct BroadcastDiscoveryView: View {
    let library: LiveAudioContentLibrary
    @Bindable var model: AppModel
    @Bindable var state: BroadcastDiscoveryState

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Picker("分类", selection: $state.categoryID) {
                    Text("全部分类").tag("0")
                    ForEach(state.filters.categories) { Text($0.name).tag($0.id) }
                }
                .pickerStyle(.menu)
                Picker("地区", selection: $state.regionID) {
                    Text("全部地区").tag("0")
                    ForEach(state.filters.regions) { Text($0.name).tag($0.id) }
                }
                .pickerStyle(.menu)
                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 12)

            Divider()
            phaseContent
        }
        .task(id: state.retryRevision) { await loadFilters() }
        .task(id: "\(state.categoryID):\(state.regionID):\(model.currentUserID ?? 0):\(state.retryRevision)") {
            await loadChannels()
        }
        .onDisappear {
            state.filterGeneration += 1
            state.loadGeneration += 1
            state.loadMoreTask?.cancel()
            state.loadMoreTask = nil
            state.isLoadingMore = false
        }
    }

    @ViewBuilder
    private var phaseContent: some View {
        switch state.phase {
        case .loading:
            ProgressView("正在加载广播频道")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case let .failed(message):
            ContentUnavailableView {
                Label("广播加载失败", systemImage: "wifi.exclamationmark")
            } description: {
                Text(message)
            } actions: {
                Button("重试") { state.retryRevision += 1 }
            }
        case let .loaded(page) where page.channels.isEmpty:
            ContentUnavailableView("暂无广播频道", systemImage: "radio")
        case let .loaded(page):
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(page.channels) { value in
                        let channel = value.settingCollected(
                            model.broadcastCollectionOverrides[value.id] ?? value.isCollected
                        )
                        Button {
                            model.broadcastCollectionOverrides[channel.id] = channel.isCollected
                            model.open(.broadcast(channel.id, channel.coverURL))
                        } label: {
                            BroadcastRow(channel: channel)
                        }
                        .buttonStyle(.plain)
                        Divider().padding(.leading, 76)
                    }
                    if page.hasMore {
                        LoadMoreTrigger(title: state.isLoadingMore ? "正在加载更多…" : "继续加载") {
                            startLoadMore(page)
                        }
                        .id(page.channels.count)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 8)
            }
        }
    }

    @MainActor
    private func loadFilters() async {
        guard state.filters.categories.isEmpty, state.filters.regions.isEmpty else { return }
        state.filterGeneration += 1
        let generation = state.filterGeneration
        do {
            let filters = try await library.broadcastFilters()
            try Task.checkCancellation()
            guard state.filterGeneration == generation else { return }
            state.filters = filters
        } catch is CancellationError {
        } catch {
            guard state.filterGeneration == generation else { return }
            state.phase = .failed(error.localizedDescription)
        }
    }

    @MainActor
    private func startLoadMore(_ current: BroadcastChannelPage) {
        guard state.loadMoreTask == nil else { return }
        let generation = state.loadGeneration
        state.loadMoreTask = Task { @MainActor in
            await loadMore(current)
            if state.loadGeneration == generation { state.loadMoreTask = nil }
        }
    }

    @MainActor
    private func loadChannels() async {
        let category = state.categoryID
        let region = state.regionID
        let accountID = model.currentUserID
        if state.hasLoaded,
           state.loadedCategoryID == category,
           state.loadedRegionID == region,
           state.loadedAccountID == accountID {
            return
        }
        state.loadGeneration += 1
        let generation = state.loadGeneration
        state.loadMoreTask?.cancel()
        state.loadMoreTask = nil
        state.isLoadingMore = false
        state.phase = .loading
        do {
            let page = try await library.broadcastChannels(categoryID: category, regionID: region)
            try Task.checkCancellation()
            guard state.loadGeneration == generation,
                  category == state.categoryID,
                  region == state.regionID,
                  accountID == model.currentUserID
            else { return }
            state.loadedCategoryID = category
            state.loadedRegionID = region
            state.loadedAccountID = accountID
            state.hasLoaded = true
            state.phase = .loaded(page)
        } catch is CancellationError {
        } catch {
            guard state.loadGeneration == generation,
                  category == state.categoryID,
                  region == state.regionID,
                  accountID == model.currentUserID
            else { return }
            state.phase = .failed(error.localizedDescription)
        }
    }

    @MainActor
    private func loadMore(_ current: BroadcastChannelPage) async {
        guard !state.isLoadingMore else { return }
        let category = state.categoryID
        let region = state.regionID
        let accountID = model.currentUserID
        let generation = state.loadGeneration
        state.isLoadingMore = true
        defer {
            if state.loadGeneration == generation { state.isLoadingMore = false }
        }
        do {
            let next = try await library.broadcastChannels(
                categoryID: category,
                regionID: region,
                cursor: current.nextCursor
            )
            try Task.checkCancellation()
            guard state.loadGeneration == generation,
                  category == state.categoryID,
                  region == state.regionID,
                  accountID == model.currentUserID
            else { return }
            state.phase = .loaded(current.appending(next))
        } catch is CancellationError {
        } catch {
            guard state.loadGeneration == generation,
                  category == state.categoryID,
                  region == state.regionID,
                  accountID == model.currentUserID
            else { return }
            model.libraryMessage = error.localizedDescription
        }
    }
}

struct PodcastDetailView: View {
    let podcastID: Int64
    let library: LiveAudioContentLibrary
    @Bindable var model: AppModel
    @Bindable var player: PlayerController

    @State private var podcast: Podcast?
    @State private var page: PodcastEpisodePage?
    @State private var errorMessage: String?
    @State private var loadedAccountID: Int64?
    @State private var isLoadingMore = false
    @State private var loadGeneration = 0
    @State private var loadMoreGeneration = 0
    @State private var retryRevision = 0
    @State private var loadMoreTask: Task<Void, Never>?
    @State private var writeTask: Task<Void, Never>?
    @State private var writeTaskID: UUID?
    @State private var pendingSubscription: Bool?

    var body: some View {
        Group {
            if let podcast = displayedPodcast, let page {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        podcastHeader(podcast)
                        Divider()
                        Text("节目").font(.title2.weight(.semibold))
                        LazyVStack(spacing: 0) {
                            ForEach(page.episodes) { episode in
                                EpisodeRow(
                                    episode: episode,
                                    open: { model.open(.podcastEpisode(episode.id)) },
                                    play: { play(episode, in: page.episodes) }
                                )
                                Divider().padding(.leading, 64)
                            }
                            if page.hasMore {
                                LoadMoreTrigger(title: isLoadingMore ? "正在加载更多…" : "继续加载") {
                                    startLoadMore(page)
                                }
                                .id(page.nextOffset)
                            }
                        }
                    }
                    .padding(28)
                }
            } else if let errorMessage {
                ContentUnavailableView {
                    Label("播客加载失败", systemImage: "wifi.exclamationmark")
                } description: {
                    Text(errorMessage)
                } actions: {
                    Button("重试") { retryRevision += 1 }
                }
            } else {
                ProgressView("正在加载播客")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(displayedPodcast?.name ?? "播客")
        .task(id: "\(podcastID):\(model.currentUserID ?? 0):\(model.uploads?.podcastCompletionRevision ?? 0):\(retryRevision)") {
            await load()
        }
        .onDisappear {
            loadGeneration += 1
            loadMoreGeneration += 1
            loadMoreTask?.cancel()
            loadMoreTask = nil
            isLoadingMore = false
            cancelWrite()
        }
    }

    private func podcastHeader(_ podcast: Podcast) -> some View {
        HStack(alignment: .top, spacing: 20) {
            AudioArtwork(url: podcast.coverURL, symbol: "dot.radiowaves.left.and.right", size: 150)
            VStack(alignment: .leading, spacing: 10) {
                Text(podcast.name).font(.title.weight(.bold))
                if !podcast.hostName.isEmpty { Text(podcast.hostName).foregroundStyle(.secondary) }
                if !podcast.categoryName.isEmpty { Text(podcast.categoryName).font(.caption).foregroundStyle(.secondary) }
                if !podcast.description.isEmpty { Text(podcast.description).textSelection(.enabled) }
                Button {
                    subscribe(podcast, subscribed: !podcast.isSubscribed)
                } label: {
                    if let pendingSubscription {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text(pendingSubscription ? "正在订阅" : "正在取消订阅")
                        }
                    } else {
                        Label(
                            podcast.isSubscribed ? "取消订阅" : "订阅",
                            systemImage: podcast.isSubscribed ? "star.fill" : "star"
                        )
                    }
                }
                .disabled(writeTask != nil)
                .accessibilityLabel(subscriptionButtonLabel(for: podcast))
            }
            Spacer()
        }
    }

    @MainActor
    private func load() async {
        loadGeneration += 1
        let generation = loadGeneration
        let accountID = model.currentUserID
        if loadedAccountID != nil, loadedAccountID != accountID { cancelWrite() }
        loadMoreGeneration += 1
        loadMoreTask?.cancel()
        loadMoreTask = nil
        isLoadingMore = false
        podcast = nil
        page = nil
        errorMessage = nil
        do {
            async let podcast = library.podcast(id: podcastID, refreshCache: true)
            async let episodes = library.podcastEpisodes(
                podcastID: podcastID,
                refreshCache: true
            )
            let loaded = try await (podcast, episodes)
            try Task.checkCancellation()
            guard loadGeneration == generation, model.currentUserID == accountID else { return }
            self.podcast = loaded.0
            loadedAccountID = accountID
            page = loaded.1
        } catch is CancellationError {
        } catch {
            guard loadGeneration == generation, model.currentUserID == accountID else { return }
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func startLoadMore(_ current: PodcastEpisodePage) {
        guard loadMoreTask == nil, !isLoadingMore else { return }
        let generation = loadMoreGeneration + 1
        loadMoreTask = Task { @MainActor in
            await loadMore(current)
            if loadMoreGeneration == generation { loadMoreTask = nil }
        }
    }

    @MainActor
    private func loadMore(_ current: PodcastEpisodePage) async {
        guard !isLoadingMore else { return }
        let accountID = model.currentUserID
        loadMoreGeneration += 1
        let generation = loadMoreGeneration
        isLoadingMore = true
        defer {
            if loadMoreGeneration == generation { isLoadingMore = false }
        }
        do {
            let next = try await library.podcastEpisodes(
                podcastID: podcastID,
                offset: current.nextOffset
            )
            try Task.checkCancellation()
            guard loadMoreGeneration == generation, accountID == model.currentUserID else { return }
            page = current.appending(next)
        } catch is CancellationError {
        } catch {
            guard loadMoreGeneration == generation, accountID == model.currentUserID else { return }
            model.libraryMessage = error.localizedDescription
        }
    }

    private func play(_ episode: PodcastEpisode, in episodes: [PodcastEpisode]) {
        guard let song = episode.song else { return }
        player.play(song, in: episodes.compactMap(\.song))
    }

    private var displayedPodcast: Podcast? {
        _ = model.podcastSubscriptionRevision
        guard loadedAccountID == model.currentUserID else { return nil }
        return podcast.map {
            PodcastSubscriptionProjection.podcast(
                $0,
                override: model.podcastSubscriptionOverride(for: $0.id)
            )
        }
    }

    @MainActor
    private func subscribe(_ podcast: Podcast, subscribed: Bool) {
        guard let accountID = model.currentUserID else {
            model.selectSidebar(.session)
            return
        }
        guard writeTask == nil, podcast.isSubscribed != subscribed else { return }
        guard let credentialRevision = model.confirmedAccountCredentialRevision,
              library.transport.credentialSnapshotValue().revision == credentialRevision
        else { return }
        let taskID = UUID()
        pendingSubscription = subscribed
        writeTaskID = taskID
        writeTask = Task { @MainActor in
            defer { finishWrite(taskID) }
            do {
                try Task.checkCancellation()
                guard model.currentUserID == accountID,
                      model.confirmedAccountCredentialRevision == credentialRevision,
                      library.transport.credentialSnapshotValue().revision == credentialRevision
                else { return }
                try await library.setPodcastSubscribed(
                    podcast.id,
                    subscribed: subscribed,
                    expectedCredentialRevision: credentialRevision
                )
                try Task.checkCancellation()
                guard writeTaskID == taskID,
                      model.currentUserID == accountID,
                      model.confirmedAccountCredentialRevision == credentialRevision,
                      library.transport.credentialSnapshotValue().revision == credentialRevision
                else { return }
                model.commitPodcastSubscription(id: podcast.id, subscribed: subscribed)
            } catch is CancellationError {
            } catch {
                guard writeTaskID == taskID,
                      model.currentUserID == accountID,
                      model.confirmedAccountCredentialRevision == credentialRevision,
                      library.transport.credentialSnapshotValue().revision == credentialRevision
                else { return }
                model.libraryMessage = error.localizedDescription
            }
        }
    }

    @MainActor
    private func cancelWrite() {
        writeTask?.cancel()
        writeTask = nil
        writeTaskID = nil
        pendingSubscription = nil
    }

    @MainActor
    private func finishWrite(_ taskID: UUID) {
        guard writeTaskID == taskID else { return }
        writeTask = nil
        writeTaskID = nil
        pendingSubscription = nil
    }

    private func subscriptionButtonLabel(for podcast: Podcast) -> String {
        if let pendingSubscription {
            return pendingSubscription ? "正在订阅播客" : "正在取消订阅播客"
        }
        return podcast.isSubscribed ? "取消订阅播客" : "订阅播客"
    }
}

struct PodcastEpisodeDetailView: View {
    let episodeID: Int64
    let library: LiveAudioContentLibrary
    @Bindable var model: AppModel
    @Bindable var player: PlayerController

    @State private var episode: PodcastEpisode?
    @State private var lyricsPhase: AudioContentPhase<[LyricLine]> = .loading
    @State private var errorMessage: String?
    @State private var loadGeneration = 0
    @State private var lyricGeneration = 0
    @State private var lyricTask: Task<Void, Never>?
    @State private var lyricTaskID: UUID?
    @State private var retryRevision = 0

    var body: some View {
        Group {
            if let episode {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        HStack(alignment: .top, spacing: 18) {
                            AudioArtwork(url: episode.coverURL, symbol: "waveform", size: 132)
                            VStack(alignment: .leading, spacing: 10) {
                                Text(episode.title).font(.title.weight(.bold))
                                let context = [episode.podcastName, episode.hostName].filter { !$0.isEmpty }
                                if !context.isEmpty {
                                    Text(context.joined(separator: " · ")).foregroundStyle(.secondary)
                                }
                                Text(episode.durationText).foregroundStyle(.secondary)
                                if let publishedAt = episode.publishedAt {
                                    Text(publishedAt.formatted(date: .abbreviated, time: .omitted))
                                        .foregroundStyle(.secondary)
                                }
                                if let song = episode.song {
                                    Button { player.play(song, in: [song]) } label: {
                                        Label("播放", systemImage: "play.fill")
                                    }
                                } else {
                                    Label(
                                        episode.unavailableReason ?? "暂无可播放的歌曲来源",
                                        systemImage: "play.slash"
                                    )
                                    .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                        }
                        if !episode.description.isEmpty {
                            Text(episode.description).textSelection(.enabled)
                        }
                        Divider()
                        Text("声音歌词").font(.title2.weight(.semibold))
                        PodcastLyricsSection(
                            phase: lyricsPhase,
                            songID: episode.song?.id,
                            player: player,
                            retry: startLyricLoad
                        )
                    }
                    .padding(28)
                }
            } else if let errorMessage {
                ContentUnavailableView {
                    Label("节目加载失败", systemImage: "wifi.exclamationmark")
                } description: {
                    Text(errorMessage)
                } actions: {
                    Button("重试") { retryRevision += 1 }
                }
            } else {
                ProgressView("正在加载节目")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(episode?.title ?? "节目")
        .task(id: "\(episodeID):\(retryRevision)") { await load() }
        .onDisappear {
            loadGeneration += 1
            lyricGeneration += 1
            lyricTask?.cancel()
            lyricTask = nil
            lyricTaskID = nil
        }
    }

    @MainActor
    private func load() async {
        loadGeneration += 1
        let generation = loadGeneration
        episode = nil
        lyricsPhase = .loading
        errorMessage = nil
        do {
            let loaded = try await library.resolvedPodcastEpisode(id: episodeID)
            try Task.checkCancellation()
            guard loadGeneration == generation else { return }
            episode = loaded
            await loadLyrics(generation: generation)
        } catch is CancellationError {
        } catch {
            guard loadGeneration == generation else { return }
            errorMessage = error.localizedDescription
        }
    }

    private func startLyricLoad() {
        let generation = loadGeneration
        let taskID = UUID()
        lyricTask?.cancel()
        lyricTaskID = taskID
        lyricTask = Task { @MainActor in
            defer {
                if lyricTaskID == taskID {
                    lyricTask = nil
                    lyricTaskID = nil
                }
            }
            await loadLyrics(generation: generation)
        }
    }

    @MainActor
    private func loadLyrics(generation: Int) async {
        lyricGeneration += 1
        let requestGeneration = lyricGeneration
        lyricsPhase = .loading
        do {
            let source = try await library.voiceLyrics(programID: episodeID)
            try Task.checkCancellation()
            guard loadGeneration == generation, lyricGeneration == requestGeneration else { return }
            lyricsPhase = .loaded(LRCParser.parse(source))
        } catch is CancellationError {
        } catch {
            guard loadGeneration == generation, lyricGeneration == requestGeneration else { return }
            lyricsPhase = .failed(error.localizedDescription)
        }
    }
}

private struct PodcastLyricsSection: View {
    let phase: AudioContentPhase<[LyricLine]>
    let songID: Int64?
    @Bindable var player: PlayerController
    let retry: () -> Void

    @ViewBuilder
    var body: some View {
        switch phase {
        case .loading:
            ProgressView("正在加载歌词…")
                .frame(maxWidth: .infinity, minHeight: 96)
        case let .failed(message):
            ContentUnavailableView {
                Label("歌词加载失败", systemImage: "wifi.exclamationmark")
            } description: {
                Text(message)
            } actions: {
                Button("重试", action: retry)
            }
            .frame(maxWidth: .infinity, minHeight: 180)
        case let .loaded(lyrics) where lyrics.isEmpty:
            ContentUnavailableView("暂无歌词", systemImage: "quote.bubble")
                .frame(maxWidth: .infinity, minHeight: 180)
        case let .loaded(lyrics):
            let currentLineID = songID == player.currentSongID
                ? PodcastLyricLocator.currentLineID(
                    in: lyrics,
                    at: Int64(player.position * 1_000)
                )
                : nil
            LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(lyrics) { line in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(line.text)
                        if let translation = line.translation {
                            Text(translation).font(.callout).foregroundStyle(.secondary)
                        }
                    }
                    .fontWeight(currentLineID == line.id ? .semibold : .regular)
                    .foregroundStyle(currentLineID == line.id ? Color.red : Color.primary)
                }
            }
        }
    }
}

struct BroadcastChannelDetailView: View {
    let channelID: String
    let coverURL: URL?
    let library: LiveAudioContentLibrary
    @Bindable var model: AppModel
    @Bindable var songPlayer: PlayerController

    @State private var info: BroadcastCurrentInfo?
    @State private var errorMessage: String?
    @State private var isWriting = false
    @State private var streamPlayer = BroadcastPagePlayer()
    @State private var playbackTask: Task<Void, Never>?
    @State private var playbackTaskID: UUID?
    @State private var writeTask: Task<Void, Never>?
    @State private var writeTaskID: UUID?
    @State private var loadGeneration = 0
    @State private var retryRevision = 0

    private var isStreamActive: Bool {
        playbackTask != nil || streamPlayer.isLoading || streamPlayer.isPlaying
    }

    private var isCollected: Bool {
        guard let info else { return false }
        return model.broadcastCollectionOverrides[channelID] ?? info.channel.isCollected
    }

    var body: some View {
        Group {
            if let info {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        HStack(alignment: .top, spacing: 20) {
                            AudioArtwork(url: coverURL ?? info.channel.coverURL, symbol: "radio", size: 150)
                            VStack(alignment: .leading, spacing: 10) {
                                Text(info.channel.name).font(.title.weight(.bold))
                                if !info.channel.regionName.isEmpty {
                                    Text(info.channel.regionName).foregroundStyle(.secondary)
                                }
                                if !info.currentProgramTitle.isEmpty {
                                    Text(info.currentProgramTitle).font(.headline)
                                }
                                if !info.currentProgramDescription.isEmpty {
                                    Text(info.currentProgramDescription).foregroundStyle(.secondary)
                                }
                                HStack(spacing: 12) {
                                    Button {
                                        isStreamActive ? stopPlayback() : startPlayback()
                                    } label: {
                                        Label(
                                            playbackTask != nil || streamPlayer.isLoading
                                                ? "连接中"
                                                : streamPlayer.isPlaying ? "停止" : "播放",
                                            systemImage: isStreamActive ? "stop.fill" : "play.fill"
                                        )
                                    }
                                    Button { collect(!isCollected) } label: {
                                        Image(systemName: isCollected ? "star.fill" : "star")
                                    }
                                    .help(isCollected ? "取消收藏" : "收藏")
                                    .accessibilityLabel(isCollected ? "取消收藏" : "收藏")
                                    .disabled(isWriting)
                                }
                            }
                            Spacer()
                        }
                        if !info.channel.description.isEmpty {
                            Text(info.channel.description).textSelection(.enabled)
                        }
                        if let message = streamPlayer.errorMessage {
                            Label(message, systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.red)
                        }
                    }
                    .padding(28)
                }
            } else if let errorMessage {
                ContentUnavailableView {
                    Label("广播加载失败", systemImage: "wifi.exclamationmark")
                } description: {
                    Text(errorMessage)
                } actions: {
                    Button("重试") { retryRevision += 1 }
                }
            } else {
                ProgressView("正在加载广播")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(info?.channel.name ?? "广播")
        .task(id: "\(channelID):\(broadcastAccountIdentity):\(retryRevision)") { await load() }
        .onDisappear {
            loadGeneration += 1
            stopPlayback()
            writeTask?.cancel()
            writeTask = nil
            writeTaskID = nil
            isWriting = false
        }
    }

    @MainActor
    private func load() async {
        loadGeneration += 1
        let generation = loadGeneration
        let accountID = model.currentUserID
        let credentialRevision = broadcastCredentialRevision
        stopPlayback()
        writeTask?.cancel()
        writeTask = nil
        writeTaskID = nil
        isWriting = false
        info = nil
        errorMessage = nil
        do {
            let loaded = try await library.broadcastCurrentInfo(
                channelID: channelID,
                expectedCredentialRevision: credentialRevision
            )
            try Task.checkCancellation()
            guard loadGeneration == generation,
                  broadcastAccountMatches(accountID, credentialRevision)
            else { return }
            info = withoutStream(loaded)
        } catch is CancellationError {
        } catch {
            guard loadGeneration == generation,
                  broadcastAccountMatches(accountID, credentialRevision)
            else { return }
            errorMessage = error.localizedDescription
        }
    }

    private func startPlayback() {
        stopPlayback()
        let taskID = UUID()
        let generation = loadGeneration
        let accountID = model.currentUserID
        let credentialRevision = broadcastCredentialRevision
        playbackTaskID = taskID
        playbackTask = Task { @MainActor in
            defer {
                if playbackTaskID == taskID {
                    playbackTask = nil
                    playbackTaskID = nil
                }
            }
            do {
                let current = try await library.broadcastCurrentInfo(
                    channelID: channelID,
                    expectedCredentialRevision: credentialRevision
                )
                try Task.checkCancellation()
                guard loadGeneration == generation,
                      playbackTaskID == taskID,
                      broadcastAccountMatches(accountID, credentialRevision)
                else { return }
                guard let streamURL = current.streamURL else {
                    throw AudioContentError.unavailable("当前频道暂无可用直播流")
                }
                let url = try await BroadcastStreamURLPolicy.playableURL(streamURL.absoluteString)
                try Task.checkCancellation()
                guard loadGeneration == generation,
                      playbackTaskID == taskID,
                      broadcastAccountMatches(accountID, credentialRevision)
                else { return }
                songPlayer.pauseForVideo()
                info = withoutStream(current)
                streamPlayer.play(url)
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled,
                      loadGeneration == generation,
                      playbackTaskID == taskID,
                      broadcastAccountMatches(accountID, credentialRevision)
                else { return }
                streamPlayer.fail(error.localizedDescription)
            }
        }
    }

    private func stopPlayback() {
        playbackTask?.cancel()
        playbackTask = nil
        playbackTaskID = nil
        streamPlayer.stop()
    }

    private func collect(_ collected: Bool) {
        guard let accountID = model.currentUserID else {
            model.selectSidebar(.session)
            return
        }
        guard !isWriting else { return }
        guard let credentialRevision = model.confirmedAccountCredentialRevision,
              library.transport.credentialSnapshotValue().revision == credentialRevision
        else { return }
        let taskID = UUID()
        writeTaskID = taskID
        isWriting = true
        writeTask = Task { @MainActor in
            defer {
                if writeTaskID == taskID {
                    isWriting = false
                    writeTask = nil
                    writeTaskID = nil
                }
            }
            do {
                guard broadcastMutationAccountMatches(accountID, credentialRevision) else { return }
                try await library.setBroadcastCollected(
                    channelID,
                    collected: collected,
                    expectedCredentialRevision: credentialRevision
                )
                try Task.checkCancellation()
                guard writeTaskID == taskID,
                      broadcastMutationAccountMatches(accountID, credentialRevision)
                else { return }
                model.broadcastCollectionOverrides[channelID] = collected
                if let current = info {
                    info = BroadcastCurrentInfo(
                        channel: current.channel.settingCollected(collected),
                        currentProgramTitle: current.currentProgramTitle,
                        currentProgramDescription: current.currentProgramDescription,
                        streamURL: nil
                    )
                }
            } catch is CancellationError {
            } catch {
                guard writeTaskID == taskID,
                      broadcastMutationAccountMatches(accountID, credentialRevision)
                else { return }
                let mutationError = error
                do {
                    let confirmed = try await library.broadcastCurrentInfo(
                        channelID: channelID,
                        expectedCredentialRevision: credentialRevision
                    )
                    try Task.checkCancellation()
                    guard writeTaskID == taskID,
                          broadcastMutationAccountMatches(accountID, credentialRevision)
                    else { return }
                    if confirmed.channel.isCollected == collected {
                        model.broadcastCollectionOverrides[channelID] = collected
                        info = withoutStream(confirmed)
                        return
                    }
                } catch is CancellationError {
                    return
                } catch {
                }
                model.libraryMessage = mutationError.localizedDescription
            }
        }
    }

    private func withoutStream(_ value: BroadcastCurrentInfo) -> BroadcastCurrentInfo {
        BroadcastCurrentInfo(
            channel: value.channel,
            currentProgramTitle: value.currentProgramTitle,
            currentProgramDescription: value.currentProgramDescription,
            streamURL: nil
        )
    }

    private var broadcastCredentialRevision: UInt64? {
        model.currentUserID.map { _ in library.transport.credentialSnapshotValue().revision }
    }

    private var broadcastAccountIdentity: String {
        "\(model.currentUserID ?? 0):\(broadcastCredentialRevision ?? 0)"
    }

    private func broadcastAccountMatches(_ accountID: Int64?, _ credentialRevision: UInt64?) -> Bool {
        model.currentUserID == accountID
            && credentialRevision.map {
                library.transport.credentialSnapshotValue().revision == $0
            } != false
    }

    private func broadcastMutationAccountMatches(_ accountID: Int64, _ credentialRevision: UInt64) -> Bool {
        model.confirmedAccountCredentialRevision == credentialRevision
            && broadcastAccountMatches(accountID, credentialRevision)
    }
}

struct PodcastSubscriptionsView: View {
    let library: LiveAudioContentLibrary
    @Bindable var model: AppModel

    @State private var phase: AudioContentPhase<PodcastPage> = .loading
    @State private var isLoadingMore = false
    @State private var generation = 0
    @State private var retryRevision = 0
    @State private var loadMoreTask: Task<Void, Never>?
    @State private var loadedAccountID: Int64?
    @State private var loadedCredentialRevision: UInt64?

    private var credentialRevision: UInt64 {
        library.transport.credentialSnapshotValue().revision
    }

    var body: some View {
        Group {
            if model.currentUserID == nil {
                ContentUnavailableView("需要登录", systemImage: "person.crop.circle.badge.exclamationmark")
            } else {
                content
            }
        }
        .navigationTitle("订阅的播客")
        .task(id: "\(model.currentUserID ?? 0):\(credentialRevision):\(model.podcastSubscriptionRevision):\(model.uploads?.podcastCompletionRevision ?? 0):\(retryRevision)") {
            await load()
        }
        .onDisappear {
            generation += 1
            loadMoreTask?.cancel()
            loadMoreTask = nil
            isLoadingMore = false
        }
    }

    @ViewBuilder
    private var content: some View {
        if loadedAccountID != model.currentUserID || loadedCredentialRevision != credentialRevision {
            ProgressView("正在加载订阅")
        } else {
            switch phase {
            case .loading:
                ProgressView("正在加载订阅")
            case let .failed(message):
                ContentUnavailableView {
                    Label("订阅加载失败", systemImage: "wifi.exclamationmark")
                } description: {
                    Text(message)
                } actions: {
                    Button("重试") { retryRevision += 1 }
                }
            case let .loaded(page):
                let displayedPage = displayedPage(page)
                if displayedPage.podcasts.isEmpty, !displayedPage.hasMore {
                    ContentUnavailableView("暂无订阅播客", systemImage: "star")
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(displayedPage.podcasts) { podcast in
                                Button { model.open(.podcast(podcast.id)) } label: { PodcastRow(podcast: podcast) }
                                    .buttonStyle(.plain)
                                Divider().padding(.leading, 76)
                            }
                            if displayedPage.hasMore {
                                LoadMoreTrigger(title: isLoadingMore ? "正在加载更多…" : "继续加载") {
                                    startLoadMore(page)
                                }
                                .id(displayedPage.nextOffset)
                            }
                        }
                        .padding(24)
                    }
                }
            }
        }
    }

    private func displayedPage(_ page: PodcastPage) -> PodcastPage {
        _ = model.podcastSubscriptionRevision
        return PodcastSubscriptionProjection.page(
            page,
            override: model.podcastSubscriptionOverride
        )
    }

    @MainActor
    private func load() async {
        generation += 1
        let requestGeneration = generation
        let accountID = model.currentUserID
        let credentialRevision = credentialRevision
        loadMoreTask?.cancel()
        loadMoreTask = nil
        isLoadingMore = false
        guard accountID != nil else {
            loadedAccountID = nil
            loadedCredentialRevision = nil
            return
        }
        loadedAccountID = accountID
        loadedCredentialRevision = credentialRevision
        phase = .loading
        do {
            let loaded = try await library.subscribedPodcasts(
                refreshCache: true,
                expectedCredentialRevision: credentialRevision
            )
            try Task.checkCancellation()
            guard generation == requestGeneration,
                  model.currentUserID == accountID,
                  self.credentialRevision == credentialRevision
            else { return }
            phase = .loaded(loaded)
        }
        catch is CancellationError {}
        catch {
            guard generation == requestGeneration,
                  model.currentUserID == accountID,
                  self.credentialRevision == credentialRevision
            else { return }
            phase = .failed(error.localizedDescription)
        }
    }

    @MainActor
    private func startLoadMore(_ current: PodcastPage) {
        guard loadMoreTask == nil else { return }
        let requestGeneration = generation
        loadMoreTask = Task { @MainActor in
            await loadMore(current)
            if generation == requestGeneration { loadMoreTask = nil }
        }
    }

    @MainActor
    private func loadMore(_ current: PodcastPage) async {
        guard !isLoadingMore else { return }
        let requestGeneration = generation
        let accountID = model.currentUserID
        let credentialRevision = credentialRevision
        isLoadingMore = true
        defer {
            if generation == requestGeneration { isLoadingMore = false }
        }
        do {
            let next = try await library.subscribedPodcasts(
                offset: current.nextOffset,
                expectedCredentialRevision: credentialRevision
            )
            try Task.checkCancellation()
            guard generation == requestGeneration,
                  model.currentUserID == accountID,
                  self.credentialRevision == credentialRevision
            else { return }
            phase = .loaded(current.appending(next))
        }
        catch is CancellationError {}
        catch {
            guard generation == requestGeneration,
                  model.currentUserID == accountID,
                  self.credentialRevision == credentialRevision
            else { return }
            model.libraryMessage = error.localizedDescription
        }
    }
}

private struct PodcastRow: View {
    let podcast: Podcast

    var body: some View {
        HStack(spacing: 12) {
            AudioArtwork(url: podcast.coverURL, symbol: "dot.radiowaves.left.and.right", size: 52)
            VStack(alignment: .leading, spacing: 4) {
                Text(podcast.name).font(.body.weight(.medium)).lineLimit(1)
                Text([podcast.hostName, podcast.categoryName].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if podcast.isSubscribed { Image(systemName: "star.fill").foregroundStyle(.yellow) }
        }
        .frame(minHeight: 60)
        .contentShape(Rectangle())
    }
}

struct EpisodeRow: View {
    let episode: PodcastEpisode
    let open: () -> Void
    let play: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 12) {
                AudioArtwork(url: episode.coverURL, symbol: "waveform", size: 46)
                VStack(alignment: .leading, spacing: 4) {
                    Text(episode.title).lineLimit(1)
                    HStack(spacing: 8) {
                        Text(episode.durationText)
                        if let date = episode.publishedAt {
                            Text(date.formatted(date: .abbreviated, time: .omitted))
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .gesture(
                TapGesture(count: 2)
                    .exclusively(before: TapGesture(count: 1))
                    .onEnded { result in
                        switch result {
                        case .first: play()
                        case .second: open()
                        }
                    }
            )
            .accessibilityIdentifier("podcast-episode-content-\(episode.id)")

            Button(action: play) { Image(systemName: episode.song == nil ? "play.slash" : "play.fill") }
                .buttonStyle(.borderless)
                .disabled(episode.song == nil)
                .help(episode.unavailableReason ?? (episode.song == nil ? "暂无可播放来源" : "播放"))
                .accessibilityIdentifier("podcast-episode-play-\(episode.id)")
        }
        .padding(.vertical, 8)
    }
}

private struct BroadcastRow: View {
    let channel: BroadcastChannel

    var body: some View {
        HStack(spacing: 12) {
            AudioArtwork(url: channel.coverURL, symbol: "radio", size: 52)
            VStack(alignment: .leading, spacing: 4) {
                Text(channel.name).font(.body.weight(.medium)).lineLimit(1)
                if !channel.regionName.isEmpty {
                    Text(channel.regionName).font(.subheadline).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if channel.isCollected { Image(systemName: "star.fill").foregroundStyle(.yellow) }
        }
        .frame(minHeight: 60)
        .contentShape(Rectangle())
    }
}

struct AudioArtwork: View {
    let url: URL?
    let symbol: String
    let size: CGFloat

    var body: some View {
        CachedAsyncImage(url: url) { phase in
            if let image = phase.image {
                image.resizable().scaledToFill()
            } else {
                Image(systemName: symbol)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.quaternary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .accessibilityHidden(true)
    }
}

@MainActor
@Observable
private final class BroadcastPagePlayer {
    private(set) var isPlaying = false
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    @ObservationIgnored private let player = AVPlayer()
    @ObservationIgnored private var statusObservation: NSKeyValueObservation?
    @ObservationIgnored private var timeoutTask: Task<Void, Never>?

    func play(_ url: URL) {
        errorMessage = nil
        isLoading = true
        let item = AVPlayerItem(url: url)
        statusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            let status = item.status
            let message = item.error?.localizedDescription
            Task { @MainActor [weak self] in
                switch status {
                case .readyToPlay:
                    self?.timeoutTask?.cancel()
                    self?.timeoutTask = nil
                    self?.isLoading = false
                    self?.isPlaying = true
                case .failed:
                    self?.fail(message ?? "直播流播放失败")
                case .unknown:
                    break
                @unknown default:
                    self?.fail("直播流状态无法识别")
                }
            }
        }
        player.replaceCurrentItem(with: item)
        player.play()
        timeoutTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(12)) } catch { return }
            guard self?.isLoading == true else { return }
            self?.fail("连接直播流超时，请稍后重试")
        }
    }

    func stop() {
        statusObservation?.invalidate()
        statusObservation = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
        isPlaying = false
        isLoading = false
    }

    func fail(_ message: String) {
        stop()
        errorMessage = message
    }
}
