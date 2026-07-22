import SwiftUI

struct PlaybackControls: View {
    @Bindable var player: PlayerController
    var showsQueueOptions = true
    var isDislikePending = false
    var onDislike: (() -> Void)? = nil
    @State private var isScrubbing = false
    @State private var scrubPosition: TimeInterval = 0

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                if showsQueueOptions {
                    PlayerIconButton(
                        symbol: "shuffle",
                        label: player.isShuffleEnabled ? "关闭随机播放" : "随机播放",
                        isActive: player.isShuffleEnabled,
                        isDisabled: player.isLinearQueueMode
                    ) {
                        player.toggleShuffle()
                    }
                }

                PlayerIconButton(
                    symbol: "backward.fill",
                    label: player.position > 3 ? "从头播放" : "上一首",
                    isDisabled: !player.canGoPrevious
                ) {
                    player.previous()
                }

                Button {
                    player.togglePlayback()
                } label: {
                    Group {
                        if player.isPreparing, player.isPlaybackRequested {
                            ProgressView()
                                .controlSize(.small)
                                .tint(.white)
                        } else {
                            Image(systemName: player.isPlaybackRequested ? "pause.fill" : "play.fill")
                                .font(.system(size: 15, weight: .bold))
                                .offset(x: player.isPlaybackRequested ? 0 : 1)
                        }
                    }
                    .foregroundStyle(.white)
                    .frame(width: 42, height: 42)
                    .background(.red, in: Circle())
                    .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(player.currentSong == nil)
                .help(playbackButtonLabel)
                .accessibilityLabel(playbackButtonLabel)

                PlayerIconButton(
                    symbol: "forward.fill",
                    label: "下一首",
                    isDisabled: !player.canGoNext
                ) {
                    player.next()
                }

                if let onDislike {
                    Button(action: onDislike) {
                        Group {
                            if isDislikePending {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Image(systemName: "hand.thumbsdown")
                            }
                        }
                        .frame(width: 32, height: 32)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
                    .disabled(isDislikePending)
                    .help("对此歌曲不感兴趣")
                    .accessibilityLabel("对此歌曲不感兴趣")
                    .accessibilityHint("移出播放队列并播放下一首")
                    .accessibilityValue(isDislikePending ? "处理中" : "")
                }

                if showsQueueOptions {
                    PlayerIconButton(
                        symbol: player.repeatMode.symbol,
                        label: player.repeatMode.actionLabel,
                        isActive: player.repeatMode != .off,
                        isDisabled: player.isLinearQueueMode
                    ) {
                        player.cycleRepeatMode()
                    }
                }
            }

            HStack(spacing: 10) {
                Text(timeText(displayedPosition))
                    .frame(width: 38, alignment: .trailing)
                Slider(
                    value: positionBinding,
                    in: 0...max(player.duration, 1),
                    onEditingChanged: updateScrubbing
                )
                .disabled(player.currentSong == nil)
                Text(timeText(player.duration))
                    .frame(width: 38, alignment: .leading)
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .onChange(of: player.currentSong?.id) { _, _ in
            isScrubbing = false
            scrubPosition = 0
        }
    }

    private var playbackButtonLabel: String {
        if case .failed = player.state { return "重试播放" }
        return player.isPlaybackRequested ? "暂停" : "播放"
    }

    private var displayedPosition: TimeInterval {
        isScrubbing ? scrubPosition : player.position
    }

    private var positionBinding: Binding<Double> {
        Binding(
            get: { displayedPosition },
            set: {
                scrubPosition = $0
                if !isScrubbing { player.seek(to: $0) }
            }
        )
    }

    private func updateScrubbing(_ editing: Bool) {
        if editing {
            scrubPosition = player.position
            isScrubbing = true
        } else {
            player.seek(to: scrubPosition)
            isScrubbing = false
        }
    }

    private func timeText(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let value = Int(seconds)
        return String(format: "%d:%02d", value / 60, value % 60)
    }
}

struct NowPlayingDetailView: View {
    @Bindable var model: AppModel
    @Bindable var player: PlayerController
    let close: () -> Void

    @State private var showingQueue = false

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            if let song = player.currentSong {
                song.album.artwork.accent.color.opacity(0.055)
            }

            if let song = player.currentSong {
                HStack(alignment: .top, spacing: 44) {
                    songDetails(song)
                        .frame(width: 308)

                    LyricsPane(player: player)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .padding(.horizontal, 40)
                .padding(.vertical, 32)
            } else {
                ContentUnavailableView(
                    "尚未播放",
                    systemImage: "music.note",
                    description: Text("从发现、搜索或资料库中选择一首歌曲")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .tint(.red)
        .preferredColorScheme(model.settings.appearance.colorScheme)
        .safeAreaInset(edge: .top, spacing: 0) {
            header
        }
        .overlay(alignment: .top) {
            ArtworkSaveToast(message: model.artworkSaveMessage)
                .padding(.top, 66)
        }
        .frame(minWidth: 780, idealWidth: 940)
        .frame(height: 720)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Button {
                showingQueue.toggle()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "music.note.list")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.red)
                    Text("播放列表")
                        .font(.subheadline.weight(.semibold))
                    if let currentIndex = player.currentIndex, !player.queue.isEmpty {
                        Text("\(currentIndex + 1) / \(player.queue.count)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 10)
                .frame(height: 34)
            }
            .buttonStyle(NowPlayingToolbarButtonStyle())
            .help("播放队列")
            .accessibilityLabel("播放队列")
            .accessibilityValue(queuePositionText)
            .popover(isPresented: $showingQueue) {
                PlaybackQueueView(player: player)
            }

            Spacer()

            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 34, height: 34)
            }
            .buttonStyle(NowPlayingToolbarButtonStyle())
            .help("关闭")
            .accessibilityLabel("关闭")
        }
        .padding(.horizontal, 20)
        .frame(height: 56)
        .background(.ultraThinMaterial)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color(nsColor: .separatorColor).opacity(0.55))
                .frame(height: 1)
        }
    }

    private var queuePositionText: String {
        guard let currentIndex = player.currentIndex, !player.queue.isEmpty else { return "队列为空" }
        return "第 \(currentIndex + 1) 首，共 \(player.queue.count) 首"
    }

    private func songDetails(_ song: Song) -> some View {
        VStack(spacing: 20) {
            ArtworkView(
                artwork: song.album.artwork,
                highResolution: true,
                saveTitle: song.album.name,
                saveAction: model.saveArtwork
            )
                .frame(width: 288, height: 288)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(.primary.opacity(0.1), lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.16), radius: 20, y: 10)
                .accessibilityLabel("\(song.name) 专辑封面")

            VStack(spacing: 5) {
                SongTitleText(song: song)
                    .font(.title2.weight(.bold))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .help(song.name)
                Text(song.artistsDisplay)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .help(song.artistsDisplay)
                Text(song.album.name)
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .help(song.album.name)
            }
            .accessibilityElement(children: .combine)

            playbackStatus

            Spacer(minLength: 0)

            HStack(spacing: 10) {
                PlayerIconButton(
                    symbol: model.likedSongIDs.contains(song.id) ? "heart.fill" : "heart",
                    label: model.likedSongIDs.contains(song.id) ? "取消喜欢" : "喜欢",
                    isActive: model.likedSongIDs.contains(song.id)
                ) {
                    model.toggleSongLiked(song.id)
                }
                CommentButton(songID: song.id, library: model.library) {
                    close()
                    model.open(.comments(song.id))
                }
                PlaybackQualityButton(songID: song.id, repository: model.repository, player: player)
                    .id(song.id)
                if let downloads = model.downloads {
                    DownloadControl(manager: downloads, song: song) { model.download(song) }
                }
            }

            PlaybackControls(player: player)
                .frame(maxWidth: 304)
        }
    }

    @ViewBuilder
    private var playbackStatus: some View {
        VStack(spacing: 8) {
            if case let .trial(_, endSeconds) = player.playbackAvailability {
                Label(trialText(endSeconds), systemImage: "timer")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
            }

            switch player.state {
            case .preparing:
                Label("正在缓冲", systemImage: "waveform")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case let .failed(_, message):
                VStack(spacing: 8) {
                    Label("播放失败", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("重试播放") { player.retryPlayback() }
                        .frame(minHeight: 44)
                    if !player.alternativeSongs.isEmpty {
                        alternativeSongs
                    }
                }
            case .idle, .playing, .paused:
                EmptyView()
            }
        }
    }

    private var alternativeSongs: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("可用版本")
                .font(.caption.weight(.semibold))
            ForEach(player.alternativeSongs) { song in
                Button {
                    player.play(song, in: player.alternativeSongs)
                } label: {
                    HStack(spacing: 8) {
                        ArtworkView(artwork: song.album.artwork)
                            .frame(width: 32, height: 32)
                        VStack(alignment: .leading, spacing: 1) {
                            SongTitleText(song: song)
                                .font(.caption.weight(.medium))
                                .lineLimit(1)
                            Text(song.artistsDisplay)
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
                .accessibilityLabel("播放可用版本 \(song.name)")
                .accessibilityHint("使用这个版本替换当前歌曲")
            }
        }
        .frame(maxWidth: 304, alignment: .leading)
    }

    private func trialText(_ endSeconds: Int?) -> String {
        guard let endSeconds else { return "试听" }
        return String(format: "试听至 %d:%02d", endSeconds / 60, endSeconds % 60)
    }
}

private struct NowPlayingToolbarButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                Color.primary.opacity(configuration.isPressed ? 0.12 : 0.055),
                in: RoundedRectangle(cornerRadius: 7)
            )
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

private struct PlaybackQueueView: View {
    @Bindable var player: PlayerController

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("播放队列")
                    .font(.headline)
                Spacer()
                Text("\(player.queue.count) 首")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(16)

            Divider()

            ScrollViewReader { proxy in
                List(player.queue) { item in
                    Button {
                        player.playQueuedSong(item.id)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: player.currentSongID == item.id ? "speaker.wave.2.fill" : "music.note")
                                .frame(width: 18)
                                .foregroundStyle(player.currentSongID == item.id ? .red : .secondary)
                            if let song = item.song {
                                VStack(alignment: .leading, spacing: 2) {
                                    SongTitleText(song: song)
                                        .lineLimit(1)
                                    Text(song.artistsDisplay)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer(minLength: 0)
                                Text(song.durationText)
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.tertiary)
                            } else {
                                Text("正在加载歌曲…")
                                    .foregroundStyle(.secondary)
                                Spacer(minLength: 0)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .id(item.id)
                    .accessibilityLabel(item.song.map { "\($0.name)，\($0.artistsDisplay)" } ?? "正在加载歌曲")
                    .accessibilityValue(player.currentSongID == item.id ? "当前歌曲" : item.song?.durationText ?? "")
                }
                .listStyle(.inset)
                .onAppear { scrollToCurrent(using: proxy) }
                .onChange(of: player.currentSongID) { _, _ in scrollToCurrent(using: proxy) }
            }
        }
        .frame(width: 360, height: 420)
    }

    private func scrollToCurrent(using proxy: ScrollViewProxy) {
        guard let id = player.currentSongID else { return }
        proxy.scrollTo(id, anchor: .center)
    }
}

private struct LyricsPane: View {
    @Bindable var player: PlayerController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        lyricContent
    }

    @ViewBuilder
    private var lyricContent: some View {
        if player.isLoadingLyrics, player.lyrics.isEmpty {
            ProgressView("正在加载歌词")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let message = player.lyricErrorMessage, player.lyrics.isEmpty {
            ContentUnavailableView {
                Label("歌词加载失败", systemImage: "exclamationmark.bubble")
            } description: {
                Text(message)
            } actions: {
                Button("重试") { player.retryLyrics() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if player.lyrics.isEmpty {
            ContentUnavailableView(
                "暂无歌词",
                systemImage: "quote.bubble",
                description: Text("当前歌曲没有可显示的歌词")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            GeometryReader { geometry in
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(player.lyrics) { line in
                                LyricRow(
                                    line: line,
                                    isCurrent: player.currentLyric?.id == line.id,
                                    player: player
                                ) {
                                    player.seek(to: TimeInterval(line.timestampMilliseconds) / 1_000)
                                }
                                .id(line.id)
                            }
                        }
                        .padding(.vertical, max(96, geometry.size.height * 0.42))
                    }
                    .scrollIndicators(.hidden)
                    .onAppear { centerCurrentLyric(using: proxy) }
                    .onChange(of: player.currentLyric?.id) { _, _ in
                        centerCurrentLyric(using: proxy)
                    }
                }
            }
        }
    }

    private func centerCurrentLyric(using proxy: ScrollViewProxy) {
        guard let id = player.currentLyric?.id else { return }
        if reduceMotion {
            proxy.scrollTo(id, anchor: .center)
        } else {
            withAnimation(.smooth(duration: 0.38)) {
                proxy.scrollTo(id, anchor: .center)
            }
        }
    }
}

private struct LyricRow: View {
    let line: LyricLine
    let isCurrent: Bool
    @Bindable var player: PlayerController
    let seek: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: seek) {
            HStack(alignment: .top, spacing: 12) {
                Capsule()
                    .fill(.red)
                    .frame(width: 3, height: 38)
                    .opacity(isCurrent ? 1 : 0)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 5) {
                    primaryLyric
                        .font(.title3.weight(.semibold))
                    if let romanization = line.romanization, !romanization.isEmpty {
                        Text(romanization)
                            .font(.subheadline)
                            .foregroundStyle(isCurrent ? Color.secondary : Color.secondary.opacity(0.72))
                    }
                    if let translation = line.translation, !translation.isEmpty {
                        Text(translation)
                            .font(.subheadline)
                            .foregroundStyle(isCurrent ? Color.secondary : Color.secondary.opacity(0.72))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 10)
            .background(isCurrent ? Color.red.opacity(0.075) : .clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
            .scaleEffect(isCurrent ? 1 : 0.97, anchor: .leading)
            .opacity(isCurrent ? 1 : 0.72)
        }
        .buttonStyle(.plain)
        .help("跳转到 \(timeText(line.timestampMilliseconds))")
        .accessibilityLabel(
            [line.text, line.romanization, line.translation].compactMap { $0 }.joined(separator: "，")
        )
        .accessibilityValue(isCurrent ? "当前歌词" : timeText(line.timestampMilliseconds))
        .animation(reduceMotion ? nil : .smooth(duration: 0.22), value: isCurrent)
    }

    @ViewBuilder
    private var primaryLyric: some View {
        if line.words.isEmpty {
            Text(line.text)
                .foregroundStyle(isCurrent ? Color.primary : Color.secondary)
        } else {
            let playbackMilliseconds = isCurrent ? Int64(player.position * 1_000) : 0
            LyricWordFlowLayout {
                ForEach(line.words) { word in
                    let progress = isCurrent
                        ? LRCParser.wordProgress(for: word, at: playbackMilliseconds)
                        : 0
                    Text(word.text)
                        .modifier(LyricFillStyle(isCurrent: isCurrent, progress: progress))
                        .animation(reduceMotion ? nil : .linear(duration: 0.1), value: progress)
                }
            }
        }
    }

    private func timeText(_ milliseconds: Int64) -> String {
        let seconds = milliseconds / 1_000
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

private struct LyricFillStyle: @MainActor AnimatableModifier {
    let isCurrent: Bool
    var progress: Double

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        content.foregroundStyle(style)
    }

    private var style: LinearGradient {
        let location = CGFloat(min(max(progress, 0), 1))
        let filledColor = isCurrent ? Color.primary : Color.secondary
        return LinearGradient(
            stops: [
                .init(color: filledColor, location: location),
                .init(color: .secondary, location: location)
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
    }
}

private struct LyricWordFlowLayout: Layout {
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
            let point = result.points[index]
            let size = result.sizes[index]
            subview.place(
                at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: size.width, height: size.height)
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
        let measuredWidth = width.isFinite ? width : contentWidth
        return (CGSize(width: measuredWidth, height: y + rowHeight), points, sizes)
    }
}

private extension PlaybackRepeatMode {
    var symbol: String {
        self == .one ? "repeat.1" : "repeat"
    }

    var actionLabel: String {
        switch self {
        case .off: "开启列表循环"
        case .all: "开启单曲循环"
        case .one: "关闭循环"
        }
    }
}
