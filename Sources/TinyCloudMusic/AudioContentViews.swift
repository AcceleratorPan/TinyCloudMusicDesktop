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

struct AudioContentView: View {
    let library: LiveAudioContentLibrary
    @Bindable var model: AppModel
    @Bindable var player: PlayerController

    @State private var selectedTab = AudioContentTab.podcasts

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

            ZStack {
                PodcastDiscoveryView(library: library, model: model, player: player)
                    .opacity(selectedTab == .podcasts ? 1 : 0)
                    .allowsHitTesting(selectedTab == .podcasts)
                    .accessibilityHidden(selectedTab != .podcasts)
                BroadcastDiscoveryView(library: library, model: model)
                    .opacity(selectedTab == .broadcasts ? 1 : 0)
                    .allowsHitTesting(selectedTab == .broadcasts)
                    .accessibilityHidden(selectedTab != .broadcasts)
            }
        }
        .navigationTitle("播客与广播")
    }
}

private struct PodcastDiscoveryView: View {
    let library: LiveAudioContentLibrary
    @Bindable var model: AppModel
    @Bindable var player: PlayerController

    @State private var categories: [PodcastCategory] = []
    @State private var selectedCategoryID: Int64?
    @State private var showsSubscriptions = false
    @State private var phase: AudioContentPhase<[Podcast]> = .loading

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                if !showsSubscriptions {
                    Picker("分类", selection: $selectedCategoryID) {
                        ForEach(categories) { Text($0.name).tag(Optional($0.id)) }
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
                    showsSubscriptions.toggle()
                } label: {
                    Image(systemName: showsSubscriptions ? "star.fill" : "star")
                }
                .help(showsSubscriptions ? "浏览分类推荐" : "查看订阅")
                .accessibilityLabel(showsSubscriptions ? "浏览分类推荐" : "查看订阅")
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 12)

            Divider()
            phaseContent
        }
        .task { await loadCategories() }
        .task(id: "\(selectedCategoryID ?? 0):\(showsSubscriptions):\(model.currentUserID ?? 0)") {
            await loadPodcasts()
        }
    }

    @ViewBuilder
    private var phaseContent: some View {
        switch phase {
        case .loading:
            ProgressView("正在加载播客")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case let .failed(message):
            ContentUnavailableView {
                Label("播客加载失败", systemImage: "wifi.exclamationmark")
            } description: {
                Text(message)
            } actions: {
                Button("重试") { Task { await loadPodcasts() } }
            }
        case let .loaded(podcasts) where podcasts.isEmpty:
            ContentUnavailableView("暂无播客", systemImage: "dot.radiowaves.left.and.right")
        case let .loaded(podcasts):
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

    @MainActor
    private func loadCategories() async {
        do {
            let values = try await library.podcastCategories()
            try Task.checkCancellation()
            categories = values
            if selectedCategoryID == nil { selectedCategoryID = values.first?.id }
        } catch is CancellationError {
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    @MainActor
    private func loadPodcasts() async {
        let categoryID = selectedCategoryID
        let subscriptions = showsSubscriptions
        let accountID = model.currentUserID
        if !subscriptions, categoryID == nil { return }
        if subscriptions, accountID == nil {
            phase = .loaded([])
            return
        }
        phase = .loading
        do {
            let values = if subscriptions {
                try await library.subscribedPodcasts().podcasts
            } else {
                try await library.recommendedPodcasts(categoryID: categoryID ?? 0)
            }
            try Task.checkCancellation()
            guard subscriptions == showsSubscriptions,
                  categoryID == selectedCategoryID,
                  accountID == model.currentUserID
            else { return }
            phase = .loaded(values)
        } catch is CancellationError {
        } catch {
            guard subscriptions == showsSubscriptions,
                  categoryID == selectedCategoryID,
                  accountID == model.currentUserID
            else { return }
            phase = .failed(error.localizedDescription)
        }
    }
}

private struct BroadcastDiscoveryView: View {
    let library: LiveAudioContentLibrary
    @Bindable var model: AppModel

    @State private var filters = BroadcastFilters(categories: [], regions: [])
    @State private var categoryID = "0"
    @State private var regionID = "0"
    @State private var phase: AudioContentPhase<BroadcastChannelPage> = .loading
    @State private var isLoadingMore = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Picker("分类", selection: $categoryID) {
                    Text("全部分类").tag("0")
                    ForEach(filters.categories) { Text($0.name).tag($0.id) }
                }
                .pickerStyle(.menu)
                Picker("地区", selection: $regionID) {
                    Text("全部地区").tag("0")
                    ForEach(filters.regions) { Text($0.name).tag($0.id) }
                }
                .pickerStyle(.menu)
                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 12)

            Divider()
            phaseContent
        }
        .task { await loadFilters() }
        .task(id: "\(categoryID):\(regionID):\(model.currentUserID ?? 0)") { await loadChannels() }
    }

    @ViewBuilder
    private var phaseContent: some View {
        switch phase {
        case .loading:
            ProgressView("正在加载广播频道")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case let .failed(message):
            ContentUnavailableView {
                Label("广播加载失败", systemImage: "wifi.exclamationmark")
            } description: {
                Text(message)
            } actions: {
                Button("重试") { Task { await loadChannels() } }
            }
        case let .loaded(page) where page.channels.isEmpty:
            ContentUnavailableView("暂无广播频道", systemImage: "radio")
        case let .loaded(page):
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(page.channels) { channel in
                        Button { model.open(.broadcast(channel.id)) } label: {
                            BroadcastRow(channel: channel)
                        }
                        .buttonStyle(.plain)
                        Divider().padding(.leading, 76)
                    }
                    if page.hasMore {
                        LoadMoreTrigger(title: isLoadingMore ? "正在加载更多…" : "继续加载") {
                            Task { await loadMore(page) }
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
        do {
            filters = try await library.broadcastFilters()
        } catch is CancellationError {
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    @MainActor
    private func loadChannels() async {
        let category = categoryID
        let region = regionID
        let accountID = model.currentUserID
        phase = .loading
        do {
            let page = try await library.broadcastChannels(categoryID: category, regionID: region)
            try Task.checkCancellation()
            guard category == categoryID, region == regionID, accountID == model.currentUserID else { return }
            phase = .loaded(page)
        } catch is CancellationError {
        } catch {
            guard category == categoryID, region == regionID, accountID == model.currentUserID else { return }
            phase = .failed(error.localizedDescription)
        }
    }

    @MainActor
    private func loadMore(_ current: BroadcastChannelPage) async {
        guard !isLoadingMore else { return }
        let category = categoryID
        let region = regionID
        let accountID = model.currentUserID
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let next = try await library.broadcastChannels(
                categoryID: category,
                regionID: region,
                cursor: current.nextCursor
            )
            try Task.checkCancellation()
            guard category == categoryID, region == regionID, accountID == model.currentUserID else { return }
            phase = .loaded(current.appending(next))
        } catch is CancellationError {
        } catch {
            guard category == categoryID, region == regionID, accountID == model.currentUserID else { return }
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
    @State private var isWriting = false
    @State private var isLoadingMore = false

    var body: some View {
        Group {
            if let podcast, let page {
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
                                    Task { await loadMore(page) }
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
                    Button("重试") { Task { await load() } }
                }
            } else {
                ProgressView("正在加载播客")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(podcast?.name ?? "播客")
        .task(id: "\(podcastID):\(model.currentUserID ?? 0)") { await load() }
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
                    subscribe(!podcast.isSubscribed)
                } label: {
                    Label(
                        podcast.isSubscribed ? "取消订阅" : "订阅",
                        systemImage: podcast.isSubscribed ? "star.fill" : "star"
                    )
                }
                .disabled(isWriting)
            }
            Spacer()
        }
    }

    @MainActor
    private func load() async {
        podcast = nil
        page = nil
        errorMessage = nil
        do {
            async let podcast = library.podcast(id: podcastID)
            async let episodes = library.podcastEpisodes(podcastID: podcastID)
            self.podcast = try await podcast
            page = try await episodes
        } catch is CancellationError {
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func loadMore(_ current: PodcastEpisodePage) async {
        guard !isLoadingMore else { return }
        let accountID = model.currentUserID
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let next = try await library.podcastEpisodes(
                podcastID: podcastID,
                offset: current.nextOffset
            )
            guard accountID == model.currentUserID else { return }
            page = current.appending(next)
        } catch is CancellationError {
        } catch {
            model.libraryMessage = error.localizedDescription
        }
    }

    private func play(_ episode: PodcastEpisode, in episodes: [PodcastEpisode]) {
        guard let song = episode.song else { return }
        player.play(song, in: episodes.compactMap(\.song))
    }

    private func subscribe(_ subscribed: Bool) {
        guard model.currentUserID != nil else {
            model.selectSidebar(.session)
            return
        }
        guard !isWriting else { return }
        let accountID = model.currentUserID
        isWriting = true
        Task { @MainActor in
            defer { isWriting = false }
            do {
                try await library.setPodcastSubscribed(podcastID, subscribed: subscribed)
                guard accountID == model.currentUserID else { return }
                podcast = podcast?.settingSubscribed(subscribed)
            } catch {
                guard accountID == model.currentUserID else { return }
                await library.invalidateCachedResponses(in: [.detail, .library])
                if let confirmed = try? await library.podcast(id: podcastID),
                   confirmed.isSubscribed == subscribed {
                    podcast = confirmed
                    return
                }
                model.libraryMessage = error.localizedDescription
            }
        }
    }
}

struct PodcastEpisodeDetailView: View {
    let episodeID: Int64
    let library: LiveAudioContentLibrary
    @Bindable var model: AppModel
    @Bindable var player: PlayerController

    @State private var episode: PodcastEpisode?
    @State private var lyrics: [LyricLine] = []
    @State private var errorMessage: String?

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
                        if lyrics.isEmpty {
                            ContentUnavailableView("暂无歌词", systemImage: "quote.bubble")
                                .frame(maxWidth: .infinity, minHeight: 180)
                        } else {
                            LazyVStack(alignment: .leading, spacing: 12) {
                                ForEach(lyrics) { line in
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(line.text)
                                        if let translation = line.translation {
                                            Text(translation).font(.callout).foregroundStyle(.secondary)
                                        }
                                    }
                                    .fontWeight(isCurrent(line, episode: episode) ? .semibold : .regular)
                                    .foregroundStyle(isCurrent(line, episode: episode) ? Color.red : Color.primary)
                                }
                            }
                        }
                    }
                    .padding(28)
                }
            } else if let errorMessage {
                ContentUnavailableView("节目加载失败", systemImage: "wifi.exclamationmark", description: Text(errorMessage))
            } else {
                ProgressView("正在加载节目")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(episode?.title ?? "节目")
        .task(id: episodeID) { await load() }
    }

    @MainActor
    private func load() async {
        episode = nil
        lyrics = []
        errorMessage = nil
        do {
            do {
                episode = try await library.podcastEpisode(id: episodeID)
            } catch {
                episode = try await library.voiceDetail(id: episodeID)
            }
            let source = try? await library.voiceLyrics(programID: episodeID)
            lyrics = source.map(LRCParser.parse) ?? []
        } catch is CancellationError {
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func isCurrent(_ line: LyricLine, episode: PodcastEpisode) -> Bool {
        guard let songID = episode.song?.id,
              player.currentSongID == songID,
              let index = LRCParser.currentLineIndex(in: lyrics, at: Int64(player.position * 1_000))
        else { return false }
        return lyrics[index].id == line.id
    }
}

struct BroadcastChannelDetailView: View {
    let channelID: String
    let library: LiveAudioContentLibrary
    @Bindable var model: AppModel
    @Bindable var songPlayer: PlayerController

    @State private var info: BroadcastCurrentInfo?
    @State private var errorMessage: String?
    @State private var isWriting = false
    @State private var streamPlayer = BroadcastPagePlayer()
    @State private var playbackTask: Task<Void, Never>?

    private var isStreamActive: Bool {
        playbackTask != nil || streamPlayer.isLoading || streamPlayer.isPlaying
    }

    var body: some View {
        Group {
            if let info {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        HStack(alignment: .top, spacing: 20) {
                            AudioArtwork(url: info.channel.coverURL, symbol: "radio", size: 150)
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
                                    Button { collect(!info.channel.isCollected) } label: {
                                        Image(systemName: info.channel.isCollected ? "star.fill" : "star")
                                    }
                                    .help(info.channel.isCollected ? "取消收藏" : "收藏")
                                    .accessibilityLabel(info.channel.isCollected ? "取消收藏" : "收藏")
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
                ContentUnavailableView("广播加载失败", systemImage: "wifi.exclamationmark", description: Text(errorMessage))
            } else {
                ProgressView("正在加载广播")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(info?.channel.name ?? "广播")
        .task(id: "\(channelID):\(model.currentUserID ?? 0)") { await load() }
        .onDisappear(perform: stopPlayback)
    }

    @MainActor
    private func load() async {
        stopPlayback()
        info = nil
        errorMessage = nil
        do {
            info = withoutStream(try await library.broadcastCurrentInfo(channelID: channelID))
        } catch is CancellationError {
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func startPlayback() {
        stopPlayback()
        playbackTask = Task { @MainActor in
            do {
                let current = try await library.broadcastCurrentInfo(channelID: channelID)
                try Task.checkCancellation()
                guard let streamURL = current.streamURL else {
                    throw AudioContentError.unavailable("当前频道暂无可用直播流")
                }
                let url = try await BroadcastStreamURLPolicy.playableURL(streamURL.absoluteString)
                songPlayer.pauseForVideo()
                info = withoutStream(current)
                streamPlayer.play(url)
                playbackTask = nil
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled else { return }
                playbackTask = nil
                streamPlayer.fail(error.localizedDescription)
            }
        }
    }

    private func stopPlayback() {
        playbackTask?.cancel()
        playbackTask = nil
        streamPlayer.stop()
    }

    private func collect(_ collected: Bool) {
        guard model.currentUserID != nil else {
            model.selectSidebar(.session)
            return
        }
        guard !isWriting else { return }
        let accountID = model.currentUserID
        isWriting = true
        Task { @MainActor in
            defer { isWriting = false }
            do {
                try await library.setBroadcastCollected(channelID, collected: collected)
                guard accountID == model.currentUserID else { return }
                if let current = info {
                    info = BroadcastCurrentInfo(
                        channel: current.channel.settingCollected(collected),
                        currentProgramTitle: current.currentProgramTitle,
                        currentProgramDescription: current.currentProgramDescription,
                        streamURL: nil
                    )
                }
            } catch {
                guard accountID == model.currentUserID else { return }
                if let confirmed = try? await library.broadcastCurrentInfo(channelID: channelID),
                   confirmed.channel.isCollected == collected {
                    info = withoutStream(confirmed)
                    return
                }
                model.libraryMessage = error.localizedDescription
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
}

struct PodcastSubscriptionsView: View {
    let library: LiveAudioContentLibrary
    @Bindable var model: AppModel

    @State private var phase: AudioContentPhase<PodcastPage> = .loading
    @State private var isLoadingMore = false

    var body: some View {
        Group {
            if model.currentUserID == nil {
                ContentUnavailableView("需要登录", systemImage: "person.crop.circle.badge.exclamationmark")
            } else {
                content
            }
        }
        .navigationTitle("订阅的播客")
        .task(id: model.currentUserID) { if model.currentUserID != nil { await load() } }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .loading:
            ProgressView("正在加载订阅")
        case let .failed(message):
            ContentUnavailableView("订阅加载失败", systemImage: "wifi.exclamationmark", description: Text(message))
        case let .loaded(page) where page.podcasts.isEmpty:
            ContentUnavailableView("暂无订阅播客", systemImage: "star")
        case let .loaded(page):
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(page.podcasts) { podcast in
                        Button { model.open(.podcast(podcast.id)) } label: { PodcastRow(podcast: podcast) }
                            .buttonStyle(.plain)
                        Divider().padding(.leading, 76)
                    }
                    if page.hasMore {
                        LoadMoreTrigger(title: isLoadingMore ? "正在加载更多…" : "继续加载") {
                            Task { await loadMore(page) }
                        }
                        .id(page.nextOffset)
                    }
                }
                .padding(24)
            }
        }
    }

    @MainActor
    private func load() async {
        phase = .loading
        do { phase = .loaded(try await library.subscribedPodcasts()) }
        catch is CancellationError {}
        catch { phase = .failed(error.localizedDescription) }
    }

    @MainActor
    private func loadMore(_ current: PodcastPage) async {
        guard !isLoadingMore else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        do { phase = .loaded(current.appending(try await library.subscribedPodcasts(offset: current.nextOffset))) }
        catch is CancellationError {}
        catch { model.libraryMessage = error.localizedDescription }
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

private struct EpisodeRow: View {
    let episode: PodcastEpisode
    let open: () -> Void
    let play: () -> Void

    var body: some View {
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
            Button(action: play) { Image(systemName: episode.song == nil ? "play.slash" : "play.fill") }
                .buttonStyle(.borderless)
                .disabled(episode.song == nil)
                .help(episode.unavailableReason ?? (episode.song == nil ? "暂无可播放来源" : "播放"))
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: play)
        .onTapGesture(perform: open)
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

private struct AudioArtwork: View {
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
