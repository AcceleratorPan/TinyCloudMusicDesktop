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
                            IOSLyricsView(player: player)
                                .tag(Page.lyrics)
                        }
                        .tabViewStyle(.page(indexDisplayMode: .never))

                        IOSPlaybackControls(player: player)
                            .padding(.horizontal, 20)
                            .padding(.top, 10)
                            .padding(.bottom, 14)
                    }
                } else {
                    ContentUnavailableView("尚未播放", systemImage: "music.note")
                }
            }
            .navigationTitle("正在播放")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭", systemImage: "chevron.down") { dismiss() }
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    Button("一起听", systemImage: "person.2") { showingTogether = true }
                        .disabled(model.currentUserID == nil || model.listenTogether == nil)
                    Button("播放队列", systemImage: "music.note.list") { showingQueue = true }
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
        }
        .tint(.red)
        .preferredColorScheme(model.settings.appearance.iosColorScheme)
    }
}

private struct IOSNowPlayingArtworkPage: View {
    @Bindable var model: AppModel
    @Bindable var player: PlayerController
    let song: Song
    let openRoute: (Route) -> Void
    @State private var showingQuality = false

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(spacing: 20) {
                    IOSArtworkView(artwork: song.album.artwork)
                        .frame(width: artworkEdge(proxy.size), height: artworkEdge(proxy.size))
                        .shadow(color: .black.opacity(0.16), radius: 16, y: 8)
                        .accessibilityLabel("\(song.name) 专辑封面")

                    VStack(spacing: 5) {
                        Text(song.primaryName)
                            .font(.title2.weight(.bold))
                            .multilineTextAlignment(.center)
                        if !song.titleMetadata.isEmpty {
                            Text(song.titleMetadata)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        Text(song.artistsDisplay)
                            .font(.headline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        Text(song.album.name)
                            .font(.subheadline)
                            .foregroundStyle(.tertiary)
                            .lineLimit(2)
                    }

                    if let userID = model.currentUserID, let library = model.library {
                        IOSFirstListenMemoryView(
                            songID: song.id,
                            userID: userID,
                            credentialRevision: model.session?.credentialRevision
                                ?? library.transport.credentialSnapshotValue().revision,
                            library: library
                        )
                    }

                    playbackStatus

                    HStack(spacing: 14) {
                        Button {
                            model.toggleSongLiked(song.id)
                        } label: {
                            Label(
                                model.likedSongIDs.contains(song.id) ? "已喜欢" : "喜欢",
                                systemImage: model.likedSongIDs.contains(song.id) ? "heart.fill" : "heart"
                            )
                            .foregroundStyle(model.likedSongIDs.contains(song.id) ? Color.red : Color.primary)
                            .frame(width: 44, height: 44)
                        }
                        .buttonStyle(IOSPressedButtonStyle())
                        .disabled(model.pendingMutations.contains(.songLike(song.id)))

                        Button {
                            openRoute(.comments(song.id))
                        } label: {
                            Label("评论", systemImage: "bubble.left")
                                .foregroundStyle(.primary)
                                .frame(width: 44, height: 44)
                        }
                        .buttonStyle(IOSPressedButtonStyle())

                        Button {
                            model.download(song)
                        } label: {
                            Label("下载", systemImage: "arrow.down.circle")
                                .foregroundStyle(.primary)
                                .frame(width: 44, height: 44)
                        }
                        .buttonStyle(IOSPressedButtonStyle())

                        Button { showingQuality = true } label: {
                            Label("音质", systemImage: "waveform.badge.magnifyingglass")
                                .foregroundStyle(.primary)
                                .frame(width: 44, height: 44)
                        }
                        .buttonStyle(IOSPressedButtonStyle())

                        Menu {
                            if !song.isPodcastEpisode {
                                Button {
                                    player.toggleHeartMode()
                                } label: {
                                    Label(heartModeLabel, systemImage: "waveform.path.ecg")
                                }
                                .disabled(player.isLoadingHeartMode || player.isSharedControlActive)
                            }
                            Button {
                                model.showAddToPlaylist(for: song)
                            } label: {
                                Label("添加到歌单", systemImage: "text.badge.plus")
                            }
                            .disabled(model.currentUserID == nil)
                            Button {
                                player.toggleMute()
                            } label: {
                                Label(player.volume == 0 ? "取消静音" : "静音", systemImage: player.volume == 0 ? "speaker.wave.2" : "speaker.slash")
                            }
                        } label: {
                            Label("更多", systemImage: "ellipsis.circle")
                                .foregroundStyle(.primary)
                                .frame(width: 44, height: 44)
                        }
                        .buttonStyle(.plain)
                    }
                    .labelStyle(.iconOnly)
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
            }
        }
        .sheet(isPresented: $showingQuality) {
            IOSPlaybackQualityView(songID: song.id, repository: model.repository, player: player)
        }
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
            if player.isLoadingHeartMode {
                ProgressView("正在开启心动模式").font(.caption)
            } else if let message = player.heartModeErrorMessage {
                Button("心动模式失败，重试") { player.toggleHeartMode() }
                    .font(.caption)
                    .accessibilityHint(message)
            }
            if case let .failed(_, message) = player.state {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                Button("重试播放") { player.retryPlayback() }
                    .buttonStyle(.bordered)
                if !player.alternativeSongs.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("可用版本").font(.caption.weight(.semibold))
                        ForEach(player.alternativeSongs) { alternative in
                            Button {
                                player.play(alternative, in: player.alternativeSongs)
                            } label: {
                                Label(
                                    "\(alternative.primaryName) · \(alternative.artistsDisplay)",
                                    systemImage: "play.fill"
                                )
                                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    private var heartModeLabel: String {
        if player.isHeartModeEnabled { return "关闭心动模式" }
        if let message = player.heartModeErrorMessage { return "重试心动模式：\(message)" }
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
        VStack(spacing: 10) {
            IOSPlaybackProgress(player: player)

            HStack(spacing: 10) {
                Button {
                    player.toggleMute()
                } label: {
                    Image(systemName: player.volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(player.volume == 0 ? "取消静音" : "静音")
                Slider(value: $player.volume, in: 0...1)
                    .accessibilityLabel("音量")
                Text(player.volume, format: .percent.precision(.fractionLength(0)))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 38, alignment: .trailing)
            }

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
                .accessibilityLabel(player.isPlaybackRequested ? "暂停" : "播放")

                IOSPlayerControlButton(symbol: "forward.fill", label: "下一首", disabled: !player.canGoNext) {
                    player.next()
                }

                IOSPlayerControlButton(
                    symbol: player.repeatMode.iosSymbol,
                    label: player.repeatMode.iosActionLabel,
                    active: player.repeatMode != .off,
                    disabled: player.isLinearQueueMode || player.isSharedControlActive
                ) { player.cycleRepeatMode() }
            }
            .disabled(player.isControlInteractionLocked)
        }
    }
}

private struct IOSPlaybackProgress: View {
    @Bindable var player: PlayerController
    @State private var isScrubbing = false
    @State private var scrubPosition: TimeInterval = 0

    var body: some View {
        VStack(spacing: 10) {
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
            .disabled(player.currentSong == nil)
            .accessibilityLabel("播放进度")

            HStack {
                Text(IOSDurationText.format(isScrubbing ? scrubPosition : player.position))
                Spacer()
                Text(IOSDurationText.format(player.duration))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }
}

private struct IOSFirstListenMemoryView: View {
    let songID: Int64
    let userID: Int64
    let credentialRevision: UInt64
    let library: LiveMusicLibrary
    @State private var phase = Phase.loading
    @State private var retryRevision = 0

    var body: some View {
        Group {
            switch phase {
            case .loading:
                ProgressView("正在加载初听记录")
                    .controlSize(.small)
                    .font(.caption)
            case .empty:
                Label("暂无初听记录", systemImage: "clock.badge.questionmark")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case let .failed(message):
                Button("初听记录加载失败，重试") { retryRevision += 1 }
                    .font(.caption)
                    .accessibilityHint(message)
            case let .loaded(memory):
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
        .task(id: "\(songID):\(userID):\(credentialRevision):\(retryRevision)") {
            phase = .loading
            do {
                let loaded = try await library.firstListenMemory(
                    songID: songID,
                    expectedCredentialRevision: credentialRevision
                )
                try Task.checkCancellation()
                guard library.transport.credentialSnapshotValue().revision == credentialRevision else { return }
                phase = loaded.listenedAt == nil && loaded.text == nil ? .empty : .loaded(loaded)
            } catch is CancellationError {
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    private enum Phase {
        case loading
        case empty
        case loaded(FirstListenMemory)
        case failed(String)
    }
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
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
                                    .font(isCurrent ? .title3.weight(.bold) : .body)
                                    if let translation = line.translation, !translation.isEmpty {
                                        Text(translation).font(.subheadline)
                                    }
                                    if let romanization = line.romanization, !romanization.isEmpty {
                                        Text(romanization).font(.caption)
                                    }
                                }
                                .foregroundStyle(isCurrent ? Color.primary : Color.secondary)
                                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .id(line.id)
                        }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 20)
            }
            .onChange(of: player.currentLyricIndex) { _, index in
                guard let index, player.lyrics.indices.contains(index) else { return }
                if reduceMotion {
                    proxy.scrollTo(player.lyrics[index].id, anchor: .center)
                } else {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(player.lyrics[index].id, anchor: .center)
                    }
                }
            }
        }
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

private struct IOSPlaybackQueueView: View {
    @Bindable var player: PlayerController
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(player.queue) { item in
                    Button {
                        player.playQueuedSong(item.id)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: item.id == player.currentSongID ? "speaker.wave.2.fill" : "music.note")
                                .foregroundStyle(item.id == player.currentSongID ? Color.red : Color.secondary)
                                .frame(width: 24)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.song?.primaryName ?? "歌曲 \(item.id)")
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                if let artists = item.song?.artistsDisplay, !artists.isEmpty {
                                    Text(artists).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                        }
                        .frame(minHeight: 44)
                    }
                    .swipeActions {
                        if item.id != player.currentSongID {
                            Button("移出", role: .destructive) { _ = player.removeFromQueue(item.id) }
                        }
                    }
                    .onAppear { player.resolveQueueSongs(visibleAround: item.id) }
                }
            }
            .navigationTitle("播放队列")
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
