import SwiftUI

struct IOSMiniPlayer: View {
    @Bindable var player: PlayerController
    let openNowPlaying: () -> Void

    var body: some View {
        if let song = player.currentSong {
            HStack(spacing: 12) {
                Button(action: openNowPlaying) {
                    HStack(spacing: 10) {
                        IOSArtworkView(artwork: song.album.artwork, cornerRadius: 6)
                            .frame(width: 44, height: 44)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(song.primaryName)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            Text(song.artistsDisplay)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("正在播放，\(song.name)，\(song.artistsDisplay)")
                .accessibilityHint("打开正在播放")

                Button {
                    player.togglePlayback()
                } label: {
                    Group {
                        if player.isPreparing, player.isPlaybackRequested {
                            ProgressView()
                        } else {
                            Image(systemName: player.isPlaybackRequested ? "pause.fill" : "play.fill")
                        }
                    }
                    .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(player.isPlaybackRequested ? "暂停" : "播放")

                Button {
                    player.next()
                } label: {
                    Image(systemName: "forward.fill")
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .disabled(!player.canGoNext)
                .accessibilityLabel("下一首")
            }
            .padding(.leading, 8)
            .padding(.trailing, 4)
            .frame(minHeight: 60)
            .background(.regularMaterial)
            .overlay(alignment: .top) { Divider() }
        }
    }
}

struct IOSNowPlayingView: View {
    @Bindable var model: AppModel
    @Bindable var player: PlayerController
    let openRoute: (Route) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var page = Page.artwork
    @State private var showingQueue = false
    @State private var showingTogether = false

    private enum Page: String, CaseIterable, Identifiable {
        case artwork = "歌曲"
        case lyrics = "歌词"
        var id: Self { self }
    }

    var body: some View {
        NavigationStack {
            Group {
                if let song = player.currentSong {
                    VStack(spacing: 0) {
                        Picker("正在播放视图", selection: $page) {
                            ForEach(Page.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 8)

                        TabView(selection: $page) {
                            IOSNowPlayingArtworkPage(
                                model: model,
                                player: player,
                                song: song,
                                openRoute: openRoute
                            )
                                .tag(Page.artwork)
                            IOSLyricsView(player: player, isVisible: page == .lyrics)
                                .tag(Page.lyrics)
                        }
                        .tabViewStyle(.page(indexDisplayMode: .never))

                        IOSPlaybackControls(player: player)
                            .padding(.horizontal, 20)
                            .padding(.bottom, 14)
                    }
                } else {
                    ContentUnavailableView("尚未播放", systemImage: "music.note")
                }
            }
            .background {
                ZStack {
                    Color(uiColor: .systemBackground)
                    if let song = player.currentSong {
                        song.album.artwork.accent.iosColor.opacity(0.055)
                    }
                }
                .ignoresSafeArea()
            }
            .navigationTitle("正在播放")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭", systemImage: "chevron.down") { dismiss() }
                }
                ToolbarItem(placement: .principal) {
                    if let song = player.currentSong {
                        VStack(spacing: 0) {
                            if !song.primaryName.isEmpty {
                                Text(song.primaryName)
                                    .font(.subheadline.weight(.semibold))
                                    .lineLimit(1)
                            }
                            if let subtitle = nowPlayingSubtitle(for: song) {
                                Text(subtitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                            }
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    Button { showingTogether = true } label: {
                        Image(systemName: model.listenTogether?.room == nil ? "person.2" : "person.2.fill")
                            .foregroundStyle(model.listenTogether?.room == nil ? Color.primary : Color.red)
                    }
                        .accessibilityLabel("一起听")
                        .accessibilityValue(model.listenTogether?.room == nil ? "" : "已连接")
                        .disabled(model.currentUserID == nil || model.listenTogether == nil)
                    Button("播放队列", systemImage: "music.note.list") { showingQueue = true }
                        .accessibilityValue(queuePositionText)
                }
            }
            .sheet(isPresented: $showingQueue) {
                IOSPlaybackQueueView(player: player)
            }
            .sheet(isPresented: $showingTogether) {
                if let controller = model.listenTogether {
                    IOSListenTogetherView(controller: controller, player: player)
                }
            }
            .overlay(alignment: .top) {
                IOSInteractionToast(message: model.interactionMessage)
                    .padding(.top, 8)
            }
        }
        .tint(.red)
        .preferredColorScheme(model.settings.appearance.iosColorScheme)
    }

    private var queuePositionText: String {
        guard let currentIndex = player.currentIndex, !player.queue.isEmpty else { return "队列为空" }
        return "第 \(currentIndex + 1) 首，共 \(player.queue.count) 首"
    }

    private func nowPlayingSubtitle(for song: Song) -> String? {
        let artists = song.artists.map(\.name).filter { !$0.isEmpty }
        let artist = artists.first.map { $0 + (artists.count > 1 ? " / ..." : "") }
        let album = song.album.name.isEmpty ? nil : song.album.name
        let subtitle = [artist, album].compactMap { $0 }.joined(separator: " - ")
        return subtitle.isEmpty ? nil : subtitle
    }
}

private struct IOSNowPlayingArtworkPage: View {
    @Bindable var model: AppModel
    @Bindable var player: PlayerController
    let song: Song
    let openRoute: (Route) -> Void
    @State private var showingQuality = false
    @State private var showingSheets = false
    @State private var showingMoreActions = false
    @State private var hasSheets = false
    @State private var knowledgeMetadata: [String] = []
    @State private var commentCount: MusicCommentCount?

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(spacing: 20) {
                    IOSArtworkView(artwork: song.album.artwork, highResolution: true)
                        .frame(width: artworkEdge(proxy.size), height: artworkEdge(proxy.size))
                        .shadow(color: .black.opacity(0.16), radius: 16, y: 8)
                        .accessibilityLabel("\(song.primaryName) 专辑封面")

                    VStack(spacing: 5) {
                        VStack(spacing: 5) {
                            IOSMarqueeText(
                                song.primaryName,
                                width: max(0, proxy.size.width - 40)
                            )
                                .font(.title2.weight(.bold))
                                .id(song.id)
                            Text(song.artistsDisplay)
                                .font(.headline)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .lineLimit(2)
                            Text(song.album.name)
                                .font(.subheadline)
                                .foregroundStyle(.tertiary)
                                .lineLimit(2)
                            if !knowledgeMetadata.isEmpty {
                                Text(knowledgeMetadata.joined(separator: " · "))
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.center)
                                    .lineLimit(2)
                                    .accessibilityLabel("歌曲百科，\(knowledgeMetadata.joined(separator: "，"))")
                            }
                        }
                        .accessibilityElement(children: .combine)

                        if let userID = model.currentUserID, let library = model.library {
                            IOSFirstListenMemoryView(
                                songID: song.id,
                                userID: userID,
                                credentialRevision: model.session?.credentialRevision
                                    ?? library.transport.credentialSnapshotValue().revision,
                                library: library
                            )
                        }
                    }

                    playbackStatus

                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                actionControls
                    .padding(.horizontal, 20)
                    .padding(.vertical, 4)
            }
        }
        .sheet(isPresented: $showingQuality) {
            IOSPlaybackQualityView(songID: song.id, repository: model.repository, player: player)
        }
        .sheet(isPresented: $showingSheets) {
            NavigationStack {
                IOSMusicSheetsView(song: song, model: model)
                    .toolbar { Button("完成") { showingSheets = false } }
            }
        }
        .confirmationDialog("更多操作", isPresented: $showingMoreActions) {
            if !song.isPodcastEpisode {
                Button {
                    player.toggleHeartMode()
                } label: {
                    Label(heartModeLabel, systemImage: "waveform.path.ecg")
                }
                .disabled(player.isLoadingHeartMode || player.isSharedControlActive)
            }
            if hasSheets {
                Button { showingSheets = true } label: {
                    Label("乐谱", systemImage: "music.quarternote.3")
                }
            }
            Button {
                model.showAddToPlaylist(for: song)
            } label: {
                Label("添加到歌单", systemImage: "text.badge.plus")
            }
            .disabled(model.currentUserID == nil)
            if let url = song.album.artwork.remoteURL {
                Button {
                    model.saveArtwork(
                        from: ArtworkURLPolicy.highResolutionURL(for: url),
                        title: song.album.name
                    )
                } label: {
                    Label("保存封面", systemImage: "photo.badge.arrow.down")
                }
            }
            Button {
                player.toggleMute()
            } label: {
                Label(
                    player.volume == 0 ? "取消静音" : "静音",
                    systemImage: player.volume == 0 ? "speaker.wave.2" : "speaker.slash"
                )
            }
        }
        .task(id: song.id) { await loadKnowledgeAvailability() }
        .task(id: "comment-\(song.id)") { await loadCommentCount() }
        .onChange(of: song.id) { _, _ in
            showingSheets = false
            showingMoreActions = false
        }
    }

    private var isLikePending: Bool {
        model.pendingMutations.contains(.songLike(song.id))
    }

    private var likeLabel: String {
        if isLikePending { return "正在更新喜欢状态" }
        return model.likedSongIDs.contains(song.id) ? "取消喜欢" : "喜欢"
    }

    private var commentLabel: String {
        guard let commentCount else { return "评论" }
        let count = commentCount.displayText.isEmpty
            ? commentCount.count.formatted(.number)
            : commentCount.displayText
        return "评论，\(count) 条"
    }

    private var actionControls: some View {
        HStack(spacing: 14) {
            if !song.isPodcastEpisode {
                Button {
                    model.toggleSongLiked(song.id)
                } label: {
                    Group {
                        if isLikePending {
                            ProgressView()
                        } else {
                            Image(systemName: model.likedSongIDs.contains(song.id) ? "heart.fill" : "heart")
                        }
                    }
                    .foregroundStyle(model.likedSongIDs.contains(song.id) ? Color.red : Color.primary)
                    .frame(width: 44, height: 44)
                }
                .buttonStyle(IOSPressedButtonStyle())
                .disabled(isLikePending)
                .accessibilityLabel(likeLabel)

                Button {
                    openRoute(.comments(song.id))
                } label: {
                    Image(systemName: "bubble.left")
                        .foregroundStyle(.primary)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(IOSPressedButtonStyle())
                .accessibilityLabel(commentLabel)
            }

            if let downloads = model.downloads {
                IOSDownloadControl(manager: downloads, song: song) { model.download(song) }
            }

            Button { showingQuality = true } label: {
                Image(systemName: "waveform.badge.magnifyingglass")
                    .foregroundStyle(player.isSwitchingPlaybackQuality ? Color.red : Color.primary)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(IOSPressedButtonStyle())
            .disabled(player.isControlInteractionLocked)
            .accessibilityLabel(player.isSwitchingPlaybackQuality ? "正在切换音质" : "音质")
            .accessibilityValue(player.isSwitchingPlaybackQuality ? "处理中" : "")
            .accessibilityHint(player.isControlInteractionLocked ? "一起听控制已锁定" : "")

            Button { showingMoreActions = true } label: {
                Image(systemName: "ellipsis.circle")
                    .foregroundStyle(.primary)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(IOSPressedButtonStyle())
            .accessibilityLabel("更多")
        }
    }

    @MainActor
    private func loadKnowledgeAvailability() async {
        hasSheets = false
        knowledgeMetadata = []
        guard let library = model.knowledgeLibrary else { return }
        let songID = song.id
        async let sheets = try? library.sheets(songID: songID)
        async let wiki = try? library.songWiki(songID: songID)
        let (loadedSheets, loadedWiki) = await (sheets, wiki)
        guard !Task.isCancelled, player.currentSong?.id == songID else { return }
        hasSheets = loadedSheets?.isEmpty == false
        knowledgeMetadata = (loadedWiki ?? []).flatMap(\.metadataItems)
    }

    @MainActor
    private func loadCommentCount() async {
        commentCount = nil
        guard !song.isPodcastEpisode, let library = model.library else { return }
        do {
            let loaded = try await library.commentCount(songID: song.id)
            try Task.checkCancellation()
            guard player.currentSong?.id == song.id else { return }
            commentCount = loaded
        } catch {}
    }

    private func artworkEdge(_ size: CGSize) -> CGFloat {
        min(size.width - 56, size.height * 0.58, 340)
    }

    @ViewBuilder
    private var playbackStatus: some View {
        VStack(spacing: 8) {
            if case let .trial(_, endSeconds) = player.playbackAvailability {
                Label(trialText(endSeconds), systemImage: "timer")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
            }
            if case .preparing = player.state {
                Label("正在缓冲", systemImage: "waveform")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if player.isSharedControlActive {
                Label("一起听期间不可开启心动模式", systemImage: "person.2.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if player.isLoadingHeartMode {
                ProgressView("正在开启心动模式").font(.caption)
            } else if let message = player.heartModeErrorMessage {
                Button("心动模式失败，重试") { player.toggleHeartMode() }
                    .font(.caption)
                    .frame(minHeight: 44)
                    .accessibilityHint(message)
            }
            if case let .failed(_, message) = player.state {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                Button("重试播放") { player.retryPlayback() }
                    .buttonStyle(.bordered)
                    .frame(minHeight: 44)
                if !player.alternativeSongs.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("可用版本").font(.caption.weight(.semibold))
                        ForEach(player.alternativeSongs) { alternative in
                            Button {
                                player.play(alternative, in: player.alternativeSongs)
                            } label: {
                                HStack(spacing: 8) {
                                    IOSArtworkView(artwork: alternative.album.artwork)
                                        .frame(width: 32, height: 32)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(alternative.name)
                                            .font(.caption.weight(.medium))
                                            .lineLimit(1)
                                        Text(alternative.artistsDisplay)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                    Spacer(minLength: 8)
                                    Image(systemName: "play.fill")
                                        .foregroundStyle(.red)
                                        .accessibilityHidden(true)
                                }
                                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(player.isControlInteractionLocked)
                            .accessibilityLabel("播放可用版本 \(alternative.name)，\(alternative.artistsDisplay)")
                        }
                    }
                }
            }
        }
    }

    private var heartModeLabel: String {
        if player.isSharedControlActive { return "一起听期间不可开启心动模式" }
        if player.isLoadingHeartMode { return "正在开启心动模式" }
        if player.isHeartModeEnabled { return "关闭心动模式" }
        if let message = player.heartModeErrorMessage { return "心动模式失败：\(message)，点按重试" }
        return "开启心动模式"
    }

    private func trialText(_ endSeconds: Int?) -> String {
        guard let endSeconds else { return "试听" }
        return String(format: "试听至 %d:%02d", endSeconds / 60, endSeconds % 60)
    }
}

struct IOSPlaybackControls: View {
    @Bindable var player: PlayerController

    var body: some View {
        VStack(spacing: 0) {
            IOSPlaybackProgress(player: player)

            HStack(spacing: 12) {
                IOSPlayerControlButton(
                    symbol: "shuffle",
                    label: player.isShuffleEnabled ? "关闭随机播放" : "随机播放",
                    active: player.isShuffleEnabled,
                    disabled: player.isLinearQueueMode
                ) { player.toggleShuffle() }

                IOSPlayerControlButton(symbol: "backward.fill", label: "上一首", disabled: !player.canGoPrevious) {
                    player.previous()
                }

                Button {
                    player.togglePlayback()
                } label: {
                    Group {
                        if player.isPreparing, player.isPlaybackRequested {
                            ProgressView().tint(.white)
                        } else {
                            Image(systemName: player.isPlaybackRequested ? "pause.fill" : "play.fill")
                                .font(.title2.weight(.bold))
                                .offset(x: player.isPlaybackRequested ? 0 : 2)
                        }
                    }
                    .foregroundStyle(.white)
                    .frame(width: 60, height: 60)
                    .background(.red, in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(player.currentSong == nil)
                .accessibilityLabel(playbackButtonLabel)

                IOSPlayerControlButton(symbol: "forward.fill", label: "下一首", disabled: !player.canGoNext) {
                    player.next()
                }

                IOSPlayerControlButton(
                    symbol: player.repeatMode.iosSymbol,
                    label: repeatModeLabel,
                    active: player.repeatMode != .off,
                    disabled: player.isLinearQueueMode || player.isSharedControlActive
                ) { player.cycleRepeatMode() }
            }
            .disabled(player.isControlInteractionLocked)
        }
    }

    private var playbackButtonLabel: String {
        if case .failed = player.state { return "重试播放" }
        return player.isPlaybackRequested ? "暂停" : "播放"
    }

    private var repeatModeLabel: String {
        if player.isSharedControlActive { return "一起听期间不可切换循环模式" }
        if player.isLinearQueueMode { return "当前队列模式不可切换循环模式" }
        return player.repeatMode.iosActionLabel
    }
}

private struct IOSPlaybackProgress: View {
    @Bindable var player: PlayerController
    @State private var isScrubbing = false
    @State private var scrubPosition: TimeInterval = 0

    var body: some View {
        VStack(spacing: 0) {
            Slider(
                value: Binding(
                    get: { isScrubbing ? scrubPosition : player.position },
                    set: { scrubPosition = $0 }
                ),
                in: 0...max(player.duration, 1),
                onEditingChanged: { editing in
                    if editing {
                        scrubPosition = player.position
                        isScrubbing = true
                    } else {
                        player.seek(to: scrubPosition)
                        isScrubbing = false
                    }
                }
            )
            .disabled(player.currentSong == nil || player.isControlInteractionLocked)
            .accessibilityLabel("播放进度")
            .accessibilityValue(
                "\(IOSDurationText.format(isScrubbing ? scrubPosition : player.position))，总时长 \(IOSDurationText.format(player.duration))"
            )

            HStack {
                Text(IOSDurationText.format(isScrubbing ? scrubPosition : player.position))
                Spacer()
                Text(IOSDurationText.format(player.duration))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .onChange(of: player.currentSong?.id) { _, _ in
            isScrubbing = false
            scrubPosition = 0
        }
    }
}

enum IOSDownloadAction: Equatable {
    case start
    case pause
    case retry
    case none

    init(state: MusicDownloadState?) {
        switch state {
        case .queued, .running: self = .pause
        case .paused, .failed: self = .retry
        case .completed: self = .none
        case .cancelled, .none: self = .start
        }
    }
}

private struct IOSDownloadControl: View {
    @Bindable var manager: MusicDownloadManager
    let song: Song
    let start: () -> Void

    var body: some View {
        Button {
            switch action {
            case .start: start()
            case .pause: manager.pause(songID: song.id)
            case .retry: manager.retry(songID: song.id)
            case .none: break
            }
        } label: {
            Group {
                switch state {
                case let .running(progress):
                    if let progress {
                        ProgressView(value: progress)
                            .frame(width: 24)
                    } else {
                        ProgressView()
                    }
                case .completed:
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.red)
                case .failed:
                    Image(systemName: "arrow.clockwise.circle")
                case .queued:
                    ProgressView()
                case .paused:
                    Image(systemName: "play.circle")
                case .cancelled, .none:
                    Image(systemName: "arrow.down.circle")
                }
            }
            .frame(width: 44, height: 44)
        }
        .buttonStyle(IOSPressedButtonStyle())
        .disabled(action == .none)
        .accessibilityLabel(downloadLabel)
    }

    private var state: MusicDownloadState? { manager.states[song.id] }
    private var action: IOSDownloadAction { IOSDownloadAction(state: state) }

    private var downloadLabel: String {
        switch state {
        case let .running(progress):
            return progress.map { "暂停下载，已完成 \(Int($0 * 100))%" } ?? "暂停下载"
        case let .paused(progress):
            return progress.map { "继续下载，已完成 \(Int($0 * 100))%" } ?? "继续下载"
        case .completed: return "已下载"
        case let .failed(message): return "下载失败：\(message)，点按重试"
        case .queued: return "暂停等待中的下载"
        case .cancelled, .none: return "下载"
        }
    }
}

private struct IOSFirstListenMemoryView: View {
    let songID: Int64
    let userID: Int64
    let credentialRevision: UInt64
    let library: LiveMusicLibrary
    @State private var memory: FirstListenMemory?

    var body: some View {
        VStack(spacing: 0) {
            if let memory, !memory.isEmpty {
                VStack(spacing: 3) {
                    if let date = memory.listenedAt {
                        Label(
                            "初听于 \(date.formatted(date: .abbreviated, time: .omitted))",
                            systemImage: "clock.arrow.circlepath"
                        )
                    }
                    if let text = memory.text { Text(text).lineLimit(2) }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .accessibilityElement(children: .combine)
            }
        }
        .task(id: IOSFirstListenTaskID(
            songID: songID,
            userID: userID,
            credentialRevision: credentialRevision
        )) {
            memory = nil
            do {
                let loaded = try await library.firstListenMemory(
                    songID: songID,
                    expectedCredentialRevision: credentialRevision
                )
                try Task.checkCancellation()
                guard library.transport.credentialSnapshotValue().revision == credentialRevision else {
                    throw CancellationError()
                }
                memory = loaded.isEmpty ? nil : loaded
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled else { return }
                memory = nil
            }
        }
    }
}

private struct IOSFirstListenTaskID: Hashable {
    let songID: Int64
    let userID: Int64
    let credentialRevision: UInt64
}

private struct IOSPlaybackQualityView: View {
    let songID: Int64
    let repository: any MusicRepository
    @Bindable var player: PlayerController
    @Environment(\.dismiss) private var dismiss
    @State private var phase = Phase.loading
    @State private var retryRevision = 0

    var body: some View {
        NavigationStack {
            Group {
                switch phase {
                case .loading:
                    ProgressView("正在加载音质信息")
                case let .failed(message):
                    ContentUnavailableView {
                        Label("音质信息加载失败", systemImage: "wifi.exclamationmark")
                    } description: {
                        Text(message)
                    } actions: {
                        Button("重试") { retryRevision += 1 }
                    }
                case let .loaded(qualities):
                    if qualities.isEmpty {
                        ContentUnavailableView("暂无音质信息", systemImage: "waveform.slash")
                    } else {
                        List(qualities.sorted { $0.rank > $1.rank }) { quality in
                            Button {
                                player.selectPlaybackQuality(quality)
                            } label: {
                                HStack(spacing: 12) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(quality.name).foregroundStyle(.primary)
                                        Text(description(for: quality))
                                            .font(.caption.monospacedDigit())
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if !quality.isAvailable {
                                        Image(systemName: "lock.fill")
                                    } else if player.isSwitchingPlaybackQuality,
                                              player.selectedPlaybackLevel == quality.id {
                                        ProgressView()
                                    } else if player.currentPlaybackLevel == quality.id {
                                        Image(systemName: "checkmark").foregroundStyle(.red)
                                    }
                                }
                                .frame(minHeight: 44)
                            }
                            .disabled(
                                !quality.isAvailable
                                    || player.currentPlaybackLevel == quality.id
                                    || (player.isSwitchingPlaybackQuality && player.selectedPlaybackLevel == quality.id)
                                    || player.isControlInteractionLocked
                            )
                        }
                    }
                }
            }
            .navigationTitle("播放音质")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("完成") { dismiss() } }
            .safeAreaInset(edge: .bottom) {
                if let message = player.playbackQualityErrorMessage {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .padding()
                        .frame(maxWidth: .infinity)
                        .background(.bar)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .task(id: retryRevision) { await load() }
    }

    private func load() async {
        phase = .loading
        do {
            let qualities = try await repository.songQualityDetails(for: songID)
            try Task.checkCancellation()
            phase = .loaded(qualities)
        } catch is CancellationError {
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private func description(for quality: SongQualityDetail) -> String {
        let rate = (Double(quality.sampleRate) / 1_000)
            .formatted(.number.precision(.fractionLength(0...1)))
        let size = ByteCountFormatter.string(fromByteCount: quality.size, countStyle: .file)
        return "\(quality.bitrate / 1_000) kbps · \(rate) kHz · \(size)"
    }

    private enum Phase {
        case loading
        case loaded([SongQualityDetail])
        case failed(String)
    }
}

private struct IOSPlayerControlButton: View {
    let symbol: String
    let label: String
    var active = false
    var disabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.body.weight(.semibold))
                .foregroundStyle(active ? Color.red : Color.primary)
                .frame(maxWidth: .infinity, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .accessibilityLabel(label)
    }
}

private struct IOSLyricsView: View {
    @Bindable var player: PlayerController
    let isVisible: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        if player.isLoadingLyrics {
                            ProgressView("正在加载歌词")
                                .frame(maxWidth: .infinity, minHeight: 180)
                        } else if let message = player.lyricErrorMessage {
                            ContentUnavailableView {
                                Label("歌词加载失败", systemImage: "exclamationmark.triangle")
                            } description: {
                                Text(message)
                            } actions: {
                                Button("重试") { player.retryLyrics() }
                            }
                        } else if player.lyrics.isEmpty {
                            ContentUnavailableView("暂无歌词", systemImage: "quote.bubble")
                        } else {
                            ForEach(Array(player.lyrics.enumerated()), id: \.element.id) { index, line in
                                let isCurrent = index == player.currentLyricIndex
                                Button {
                                    player.seek(to: TimeInterval(line.timestampMilliseconds) / 1_000)
                                } label: {
                                    VStack(alignment: .leading, spacing: 5) {
                                        IOSPrimaryLyric(
                                            player: player,
                                            line: line,
                                            isCurrent: isCurrent,
                                            reduceMotion: reduceMotion
                                        )
                                        .font(.title3.weight(.semibold))
                                        if let romanization = line.romanization, !romanization.isEmpty {
                                            Text(romanization)
                                                .font(.subheadline)
                                                .foregroundStyle(
                                                    isCurrent ? Color.secondary : Color.secondary.opacity(0.72)
                                                )
                                        }
                                        if let translation = line.translation, !translation.isEmpty {
                                            Text(translation)
                                                .font(.subheadline)
                                                .foregroundStyle(
                                                    isCurrent ? Color.secondary : Color.secondary.opacity(0.72)
                                                )
                                        }
                                    }
                                    .foregroundStyle(isCurrent ? Color.primary : Color.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .padding(.leading, 15)
                                    .overlay(alignment: .leading) {
                                        Capsule()
                                            .fill(.red)
                                            .frame(width: 3)
                                            .opacity(isCurrent ? 1 : 0)
                                            .accessibilityHidden(true)
                                    }
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 10)
                                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                    .background(
                                        isCurrent ? Color.red.opacity(0.075) : .clear,
                                        in: RoundedRectangle(cornerRadius: 6)
                                    )
                                    .contentShape(Rectangle())
                                    .scaleEffect(isCurrent ? 1 : 0.97, anchor: .leading)
                                    .opacity(isCurrent ? 1 : 0.72)
                                }
                                .buttonStyle(.plain)
                                .disabled(player.isControlInteractionLocked)
                                .id(line.id)
                                .accessibilityLabel(lyricLabel(line))
                                .accessibilityValue(
                                    isCurrent ? "当前歌词" : timeText(line.timestampMilliseconds)
                                )
                                .accessibilityHint(
                                    player.isControlInteractionLocked ? "一起听控制已锁定" : "跳转到此句"
                                )
                                .animation(reduceMotion ? nil : .smooth(duration: 0.22), value: isCurrent)
                            }
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, player.lyrics.isEmpty ? 20 : max(96, geometry.size.height * 0.42))
                }
                .onAppear { centerCurrentLyric(using: proxy) }
                .onChange(of: isVisible) { _, visible in
                    if visible { centerCurrentLyric(using: proxy) }
                }
                .onChange(of: player.lyrics.count) { _, _ in centerCurrentLyric(using: proxy) }
                .onChange(of: player.currentLyricIndex) { _, _ in centerCurrentLyric(using: proxy) }
            }
        }
    }

    private func centerCurrentLyric(using proxy: ScrollViewProxy) {
        guard isVisible,
              let index = player.currentLyricIndex,
              player.lyrics.indices.contains(index)
        else { return }
        if reduceMotion {
            proxy.scrollTo(player.lyrics[index].id, anchor: .center)
        } else {
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo(player.lyrics[index].id, anchor: .center)
            }
        }
    }

    private func lyricLabel(_ line: LyricLine) -> String {
        [line.text, line.romanization, line.translation]
            .compactMap { value in
                guard let value, !value.isEmpty else { return nil }
                return value
            }
            .joined(separator: "，")
    }

    private func timeText(_ milliseconds: Int64) -> String {
        let seconds = milliseconds / 1_000
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

private struct IOSPrimaryLyric: View {
    @Bindable var player: PlayerController
    let line: LyricLine
    let isCurrent: Bool
    let reduceMotion: Bool

    @ViewBuilder var body: some View {
        if line.words.isEmpty {
            Text(line.text.isEmpty ? "…" : line.text)
        } else {
            let playbackMilliseconds = isCurrent ? Int64(player.position * 1_000) : 0
            IOSLyricWordFlowLayout {
                ForEach(line.words) { word in
                    let progress = isCurrent
                        ? LRCParser.wordProgress(for: word, at: playbackMilliseconds)
                        : 0
                    Text(word.text)
                        .modifier(IOSLyricFillStyle(isCurrent: isCurrent, progress: progress))
                        .animation(reduceMotion ? nil : .linear(duration: 0.1), value: progress)
                }
            }
        }
    }
}

private struct IOSLyricFillStyle: AnimatableModifier {
    let isCurrent: Bool
    var progress: Double

    nonisolated var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        let location = CGFloat(min(max(progress, 0), 1))
        let filled = isCurrent ? Color.primary : Color.secondary
        content.foregroundStyle(LinearGradient(
            stops: [
                .init(color: filled, location: location),
                .init(color: .secondary, location: location)
            ],
            startPoint: .leading,
            endPoint: .trailing
        ))
    }
}

private struct IOSLyricWordFlowLayout: Layout {
    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        layout(subviews: subviews, width: proposal.width ?? .infinity).size
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let result = layout(subviews: subviews, width: bounds.width)
        for (index, subview) in subviews.enumerated() {
            subview.place(
                at: CGPoint(
                    x: bounds.minX + result.points[index].x,
                    y: bounds.minY + result.points[index].y
                ),
                anchor: .topLeading,
                proposal: ProposedViewSize(
                    width: result.sizes[index].width,
                    height: result.sizes[index].height
                )
            )
        }
    }

    private func layout(
        subviews: Subviews,
        width: CGFloat
    ) -> (size: CGSize, points: [CGPoint], sizes: [CGSize]) {
        var points: [CGPoint] = []
        var sizes: [CGSize] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var contentWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(
                width.isFinite ? ProposedViewSize(width: width, height: nil) : .unspecified
            )
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight
                rowHeight = 0
            }
            points.append(CGPoint(x: x, y: y))
            sizes.append(size)
            x += size.width
            rowHeight = max(rowHeight, size.height)
            contentWidth = max(contentWidth, x)
        }
        return (
            CGSize(width: width.isFinite ? width : contentWidth, height: y + rowHeight),
            points,
            sizes
        )
    }
}

enum IOSMarquee {
    private static let speed: CGFloat = 28
    static let delay: TimeInterval = 1.2

    static func offset(elapsed: TimeInterval, textWidth: CGFloat, viewportWidth: CGFloat, gap: CGFloat) -> CGFloat {
        guard textWidth > viewportWidth, elapsed > delay else { return 0 }
        let distance = textWidth + gap
        return -(CGFloat(elapsed - delay) * speed).truncatingRemainder(dividingBy: distance)
    }
}

private struct IOSMarqueeText: View {
    let text: String
    let width: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var textWidth: CGFloat = 0
    @State private var startedAt = Date.now

    private let gap: CGFloat = 32

    init(_ text: String, width: CGFloat) {
        self.text = text
        self.width = width
    }

    private var shouldScroll: Bool {
        !reduceMotion && width > 0 && textWidth > width
    }

    var body: some View {
        Text(text)
            .lineLimit(1)
            .frame(width: width)
            .hidden()
            .overlay(alignment: .leading) {
                if shouldScroll {
                    TimelineView(.animation(minimumInterval: 1 / 60)) { timeline in
                        HStack(spacing: gap) {
                            Text(text)
                            Text(text)
                        }
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .offset(x: IOSMarquee.offset(
                            elapsed: timeline.date.timeIntervalSince(startedAt),
                            textWidth: textWidth,
                            viewportWidth: width,
                            gap: gap
                        ))
                    }
                } else {
                    Text(text)
                        .lineLimit(1)
                        .frame(width: width)
                }
            }
            .background {
                Text(text)
                    .fixedSize(horizontal: true, vertical: false)
                    .hidden()
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
                        guard width != textWidth else { return }
                        textWidth = width
                        startedAt = .now
                    }
            }
            .onChange(of: width) { _, _ in startedAt = .now }
            .onChange(of: text) { _, _ in startedAt = .now }
            .onChange(of: reduceMotion) { _, _ in startedAt = .now }
            .clipped()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(text)
    }
}

private struct IOSPlaybackQueueView: View {
    @Bindable var player: PlayerController
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List {
                    ForEach(player.queue) { item in
                        Button {
                            player.playQueuedSong(item.id)
                        } label: {
                            HStack(spacing: 12) {
                                Image(
                                    systemName: item.id == player.currentSongID
                                        ? "speaker.wave.2.fill"
                                        : "music.note"
                                )
                                .foregroundStyle(item.id == player.currentSongID ? Color.red : Color.secondary)
                                .frame(width: 24)
                                if let song = item.song {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(song.name)
                                            .foregroundStyle(.primary)
                                            .lineLimit(1)
                                        Text(song.artistsDisplay)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                    Spacer(minLength: 8)
                                    Text(song.durationText)
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.tertiary)
                                } else {
                                    Text("正在加载歌曲")
                                        .foregroundStyle(.secondary)
                                    Spacer(minLength: 0)
                                }
                            }
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(player.isControlInteractionLocked)
                        .id(item.id)
                        .swipeActions {
                            if item.id != player.currentSongID, !player.isControlInteractionLocked {
                                Button("移出", role: .destructive) { _ = player.removeFromQueue(item.id) }
                            }
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(
                            item.song.map { "\($0.name)，\($0.artistsDisplay)" } ?? "正在加载歌曲"
                        )
                        .accessibilityValue(
                            [item.id == player.currentSongID ? "当前歌曲" : nil, item.song?.durationText]
                                .compactMap { $0 }
                                .joined(separator: "，")
                        )
                        .onAppear { player.resolveQueueSongs(visibleAround: item.id) }
                    }
                }
                .task(id: player.currentSongID) {
                    guard let id = player.currentSongID else { return }
                    proxy.scrollTo(id, anchor: .center)
                }
            }
            .navigationTitle("播放队列 · \(player.queue.count) 首")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("完成") { dismiss() } }
        }
        .presentationDetents([.medium, .large])
    }
}

private extension PlaybackRepeatMode {
    var iosSymbol: String { self == .one ? "repeat.1" : "repeat" }

    var iosActionLabel: String {
        switch self {
        case .off: "开启列表循环"
        case .all: "开启单曲循环"
        case .one: "关闭循环"
        }
    }
}
