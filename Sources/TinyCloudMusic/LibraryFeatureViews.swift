import AppKit
import SwiftUI

struct PlaybackHistoryRefreshTracker<Key: Equatable> {
    private(set) var lastSequence: UInt64 = 0
    private var pending: [(key: Key, sequence: UInt64)] = []

    @discardableResult
    mutating func record(
        _ event: PlaybackHistoryEvent,
        credentialRevision: UInt64,
        keys: [Key]
    ) -> Bool {
        guard event.credentialRevision == credentialRevision,
              event.sequence > lastSequence
        else { return false }
        lastSequence = event.sequence
        for key in keys {
            if let index = pending.firstIndex(where: { $0.key == key }) {
                pending[index].sequence = event.sequence
            } else {
                pending.append((key, event.sequence))
            }
        }
        return true
    }

    func pendingSequence(for key: Key) -> UInt64? {
        pending.first(where: { $0.key == key })?.sequence
    }

    @discardableResult
    mutating func settle(_ key: Key, sequence: UInt64) -> Bool {
        guard let index = pending.firstIndex(where: {
            $0.key == key && $0.sequence == sequence
        }) else { return false }
        pending.remove(at: index)
        return true
    }

    mutating func reset() {
        lastSequence = 0
        pending.removeAll()
    }
}

struct SessionView: View {
    @Bindable private var controller: SessionController
    let showSuccess: (String) -> Void

    init(controller: SessionController, showSuccess: @escaping (String) -> Void) {
        self.controller = controller
        self.showSuccess = showSuccess
    }

    var body: AnyView {
        AnyView(Form {
            SessionSettingsSections(controller: controller, showSuccess: showSuccess)
        }
        .formStyle(.grouped)
        .frame(maxWidth: 680)
        .padding(24))
    }
}

struct SessionSettingsSections: View {
    @Bindable private var controller: SessionController
    let showSuccess: (String) -> Void
    @State private var showingQRLogin = false
    @State private var showingWebLogin = false
    @State private var showClearConfirmation = false
    @State private var isRefreshing = false
    @State private var isLoggingOut = false
    @State private var sessionMessage: String?

    init(controller: SessionController, showSuccess: @escaping (String) -> Void) {
        self.controller = controller
        self.showSuccess = showSuccess
    }

    var body: AnyView {
        return AnyView(Group {
            Section("会话状态") {
                Label(stateTitle, systemImage: stateSymbol)
                    .foregroundStyle(controller.state == .invalid || controller.state == .error ? .red : .primary)
                    .accessibilityLabel("会话状态：\(stateTitle)")
                if controller.state == .invalid {
                    Text("会话无效，请重新扫码登录。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else if controller.state == .error {
                    Text("无法验证会话，请检查网络后重试。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            Section("账号登录") {
                HStack(spacing: 12) {
                    Button {
                        showingQRLogin = true
                    } label: {
                        Label("二维码登录", systemImage: "qrcode")
                    }
                    .buttonStyle(.borderedProminent)
                    .help("使用网易云音乐客户端扫码登录")
                    .disabled(controller.state == .authenticated || isRefreshing || isLoggingOut)

                    Button {
                        showingWebLogin = true
                    } label: {
                        Label("备用网页登录", systemImage: "safari")
                    }
                    .help("打开网易云音乐官方登录页并自动保存 Cookie")
                    .disabled(controller.state == .authenticated || isRefreshing || isLoggingOut)
                }
                .controlSize(.large)

                HStack(spacing: 12) {
                    Button(action: refreshSession) {
                        Label("刷新登录", systemImage: "arrow.clockwise")
                            .opacity(isRefreshing ? 0 : 1)
                            .overlay {
                                if isRefreshing { ProgressView().controlSize(.small) }
                            }
                    }
                    .accessibilityLabel(isRefreshing ? "正在刷新登录" : "刷新登录")
                    .disabled(controller.state != .authenticated || isRefreshing || isLoggingOut)

                    Button(role: .destructive) {
                        showClearConfirmation = true
                    } label: {
                        Label("退出登录", systemImage: "rectangle.portrait.and.arrow.right")
                            .opacity(isLoggingOut ? 0 : 1)
                            .overlay {
                                if isLoggingOut { ProgressView().controlSize(.small) }
                            }
                    }
                    .accessibilityLabel(isLoggingOut ? "正在退出登录" : "退出登录")
                    .disabled(controller.state == .guest || isRefreshing || isLoggingOut)
                }
                .controlSize(.large)
            }
        }
        .confirmationDialog("确定退出登录？", isPresented: $showClearConfirmation) {
            Button("退出", role: .destructive) {
                isLoggingOut = true
                Task { @MainActor in
                    if let warning = await controller.logout() {
                        sessionMessage = warning
                    } else {
                        showSuccess("已退出登录")
                    }
                    isLoggingOut = false
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("服务器退出完成后会清除本地登录 Cookie；单独保存的 MUSIC_U 不受影响。")
        }
        .sheet(isPresented: $showingQRLogin) {
            NativeQRLoginView(session: controller) { showSuccess("登录成功") }
        }
        .sheet(isPresented: $showingWebLogin) {
            NeteaseWebLoginView(controller: controller) { showSuccess("登录成功") }
        }
        .alert("会话提示", isPresented: sessionMessagePresented) {
            Button("好") { sessionMessage = nil }
        } message: {
            Text(sessionMessage ?? "")
        })
    }

    private var stateTitle: String {
        switch controller.state {
        case .guest: "访客模式"
        case .authenticated: "已验证"
        case .invalid: "凭据无效"
        case .error: "验证失败"
        }
    }

    private var stateSymbol: String {
        switch controller.state {
        case .guest: "person.crop.circle.badge.questionmark"
        case .authenticated: "checkmark.shield.fill"
        case .invalid: "person.crop.circle.badge.exclamationmark"
        case .error: "wifi.exclamationmark"
        }
    }

    private var sessionMessagePresented: Binding<Bool> {
        Binding(
            get: { sessionMessage != nil },
            set: { if !$0 { sessionMessage = nil } }
        )
    }

    private func refreshSession() {
        guard !isRefreshing else { return }
        isRefreshing = true
        Task { @MainActor in
            defer { isRefreshing = false }
            do {
                if try await controller.refresh() {
                    showSuccess("登录已刷新")
                } else {
                    sessionMessage = "返回的会话凭据未通过验证，原登录保持不变。"
                }
            } catch {
                sessionMessage = error.localizedDescription
            }
        }
    }

}

struct MusicLibraryLoadTrigger: Hashable, Sendable {
    let accountID: Int64?
    let credentialRevision: UInt64
    let reloadRevision: UInt64
}

struct MusicLibraryLoadIdentity: Equatable, Sendable {
    let generation: UInt64
    let accountID: Int64?
    let credentialRevision: UInt64
}

struct MusicLibraryLoadState: Sendable {
    private(set) var generation: UInt64 = 0
    private var consumedReloadRevision: UInt64 = 0

    mutating func begin(_ trigger: MusicLibraryLoadTrigger) -> (MusicLibraryLoadIdentity, force: Bool) {
        generation &+= 1
        let force = trigger.reloadRevision != consumedReloadRevision
        consumedReloadRevision = trigger.reloadRevision
        return (identity(for: trigger), force)
    }

    func identity(for trigger: MusicLibraryLoadTrigger) -> MusicLibraryLoadIdentity {
        MusicLibraryLoadIdentity(
            generation: generation,
            accountID: trigger.accountID,
            credentialRevision: trigger.credentialRevision
        )
    }

    func accepts(
        _ identity: MusicLibraryLoadIdentity,
        accountID: Int64?,
        credentialRevision: UInt64
    ) -> Bool {
        identity.generation == generation
            && identity.accountID == accountID
            && identity.credentialRevision == credentialRevision
    }
}

struct MusicLibraryView: View {
    @Bindable var model: AppModel
    let library: LiveMusicLibrary
    let extras: LiveMusicExtras
    @Bindable private var player: PlayerController
    let onOpenRoute: (Route) -> Void

    @State private var phase: LibraryPhase = .idle
    @State private var playlistName = ""
    @State private var privatePlaylist = false
    @State private var isCreatingPlaylist = false
    @State private var creationError: String?
    @State private var playlistToDelete: Playlist?
    @State private var showDeleteConfirmation = false
    @State private var deletingPlaylistID: Int64?
    @State private var playlistError: String?
    @State private var showingPlaylistOrder = false
    @State private var visibleRecommendationCount = 20
    @State private var selectedSection = MusicLibrarySection.recommendations
    @State private var selectedListeningPeriod = MusicListeningPeriod.week
    @State private var weeklyListeningRecords: [MusicListeningRecord] = []
    @State private var allTimeListeningRecords: [MusicListeningRecord] = []
    @State private var recentPlayedSong: Song?
    @State private var totalListeningSeconds: Int64?
    @State private var listeningPhase: LibraryPhase = .idle
    @State private var listeningTask: Task<Void, Never>?
    @State private var listeningTaskID: UUID?
    @State private var listeningCredentialRevision: UInt64?
    @State private var historyRefreshes = PlaybackHistoryRefreshTracker<PlaybackHistoryKind>()
    @State private var isVisible = false
    @State private var libraryLoadState = MusicLibraryLoadState()
    @State private var libraryReloadRevision: UInt64 = 0
    @State private var progressiveSnapshot: LibrarySnapshot?

    init(
        model: AppModel,
        library: LiveMusicLibrary,
        extras: LiveMusicExtras,
        player: PlayerController,
        onOpenRoute: @escaping (Route) -> Void
    ) {
        self.model = model
        self.library = library
        self.extras = extras
        self.player = player
        self.onOpenRoute = onOpenRoute
    }

    var body: AnyView { AnyView(content) }
    private var libraryLoadTrigger: MusicLibraryLoadTrigger {
        MusicLibraryLoadTrigger(
            accountID: model.currentUserID,
            credentialRevision: library.transport.credentialSnapshotValue().revision,
            reloadRevision: libraryReloadRevision
        )
    }

    private var content: AnyView {
        let loadTrigger = libraryLoadTrigger
        let playlistRefreshID = "\(model.librarySnapshot?.user.id ?? 0):\(loadTrigger.credentialRevision):\(model.playlistContentRevision)"
        return AnyView(Group {
            if let snapshot = progressiveSnapshot ?? model.librarySnapshot {
                libraryContent(snapshot)
            } else {
                switch phase {
                case .idle, .loading, .loaded:
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("正在加载音乐库…")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .loggedOut:
                    ContentUnavailableView(
                        "需要登录",
                        systemImage: "person.crop.circle.badge.exclamationmark",
                        description: Text("扫码登录后再打开音乐库。")
                    )
                case let .failed(message):
                    ContentUnavailableView {
                        Label("音乐库加载失败", systemImage: "wifi.exclamationmark")
                    } description: {
                        Text(message)
                    } actions: {
                        Button("重试", action: reloadLibrary)
                    }
                }
            }
        }
        .navigationTitle("我的")
        .task(id: loadTrigger) {
            let (identity, force) = libraryLoadState.begin(loadTrigger)
            await load(identity: identity, force: force)
        }
        .task(id: playlistRefreshID) { await refreshPlaylistsIfNeeded(trigger: loadTrigger) }
        .onAppear {
            isVisible = true
            consumeHistoryEvent(player.playbackHistoryEvent)
        }
        .onDisappear {
            isVisible = false
            listeningTask?.cancel()
            listeningTask = nil
            listeningTaskID = nil
            listeningCredentialRevision = nil
        }
        .onChange(of: player.playbackHistoryEvent) { _, event in
            consumeHistoryEvent(event)
        }
        .onChange(of: selectedSection) { _, section in
            guard section == .listening else { return }
            drainListeningRefresh()
        }
        .alert(
            "删除歌单？",
            isPresented: $showDeleteConfirmation,
            presenting: playlistToDelete
        ) { playlist in
            Button("删除", role: .destructive) { deletePlaylist(playlist) }
            Button("取消", role: .cancel) {}
        } message: { playlist in
            Text("“\(playlist.name)”将从账号中删除，此操作不可撤销。")
        }
        .sheet(isPresented: $showingPlaylistOrder) {
            if let snapshot = model.librarySnapshot {
                PlaylistOrderEditor(
                    playlists: snapshot.playlists.filter { $0.isUserEditable(by: snapshot.user.id) },
                    library: library,
                    reload: { await loadForced() },
                    onSaved: { model.showToast("歌单顺序已保存") }
                )
            }
        }
        .onChange(of: model.currentUserID) { _, _ in
            showingPlaylistOrder = false
            progressiveSnapshot = nil
            historyRefreshes.reset()
            listeningTask?.cancel()
            listeningTask = nil
            listeningTaskID = nil
        })
    }

    private func libraryContent(_ snapshot: LibrarySnapshot) -> AnyView {
        AnyView(ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                HStack(spacing: 14) {
                    LibraryRemoteImage(url: snapshot.user.avatarURL, symbol: "person.crop.circle.fill", size: 64)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(snapshot.user.nickname)
                            .font(.title2.weight(.semibold))
                        if !snapshot.user.signature.isEmpty {
                            Text(snapshot.user.signature)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Text(profileSummary(snapshot))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Button {
                        onOpenRoute(.cloudMusic)
                    } label: {
                        Label("音乐云盘", systemImage: "externaldrive")
                    }
                    .frame(minHeight: 44)
                    Button("查看主页") { onOpenRoute(.user(snapshot.user.id)) }
                    Button {
                        reloadLibrary()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .help("刷新音乐库")
                    .accessibilityLabel("刷新音乐库")
                    .frame(minWidth: 44, minHeight: 44)
                }

                Divider()
                Picker("音乐库内容", selection: $selectedSection) {
                    ForEach(MusicLibrarySection.allCases, id: \.self) { section in
                        Label(section.rawValue, systemImage: section.symbol)
                            .tag(section)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 680)

                switch selectedSection {
                case .recommendations:
                    recommendations(snapshot)
                case .listening:
                    listening
                case .playlists:
                    playlists(snapshot)
                    Divider()
                    createPlaylistForm
                case .following:
                    following(snapshot)
                case .recommendedUsers:
                    recommendedUsers(snapshot)
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 24)
        })
    }

    private func profileSummary(_ snapshot: LibrarySnapshot) -> String {
        var values = [
            "Level \(snapshot.user.level)",
            "听过 \(snapshot.user.listenedSongCount.formatted()) 首"
        ]
        if case .loaded = listeningPhase, !weeklyListeningRecords.isEmpty {
            values.append("本周 \(weeklyListeningRecords.reduce(0) { $0 + $1.playCount }.formatted()) 次")
        }
        if let totalListeningSeconds {
            values.append("累计 \(listeningDurationText(totalListeningSeconds))")
        }
        return values
            .map { $0.map(String.init).joined(separator: "\u{2060}") }
            .joined(separator: " ")
    }

    private func recommendations(_ snapshot: LibrarySnapshot) -> AnyView {
        AnyView(LazyVStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Text("今日推荐")
                    .font(.title3.weight(.semibold))
                Spacer()
                Button { onOpenRoute(.recommendationHistory) } label: {
                    Label("历史日推", systemImage: "calendar")
                }
            }
            if snapshot.songs.isEmpty {
                EmptyLibrarySection(title: "今天暂无推荐", symbol: "music.note")
            } else {
                ForEach(snapshot.songs.prefix(visibleRecommendationCount)) { song in
                    HStack(spacing: 12) {
                        LibraryRemoteImage(url: song.album.artwork.remoteURL, symbol: "music.note", size: 42)
                        VStack(alignment: .leading, spacing: 2) {
                            SongTitleText(song: song)
                                .lineLimit(1)
                            SongMetadataLinks(song: song, onOpenRoute: onOpenRoute)
                        }
                        Spacer()
                        Text(song.durationText)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Button {
                            player.play(song, in: snapshot.songs)
                        } label: {
                            Image(systemName: "play.fill")
                        }
                        .buttonStyle(.borderless)
                        .help("播放 \(song.name)")
                        .accessibilityLabel("播放 \(song.name)")
                        .frame(width: 44, height: 44)
                    }
                    .frame(minHeight: 48)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { player.play(song, in: snapshot.songs) }
                    .contextMenu {
                        SongContextMenu(song: song, songs: snapshot.songs, model: model, player: player)
                    }
                }
                if visibleRecommendationCount < snapshot.songs.count {
                    LoadMoreTrigger(title: "正在显示更多…") {
                        visibleRecommendationCount = min(visibleRecommendationCount + 20, snapshot.songs.count)
                    }
                    .id(visibleRecommendationCount)
                }
            }
        })
    }

    private var listening: AnyView {
        let records = selectedListeningPeriod == .week ? weeklyListeningRecords : allTimeListeningRecords
        let songs = records.map(\.song)
        let playCount = records.reduce(0) { $0 + $1.playCount }

        return AnyView(VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Picker("统计周期", selection: $selectedListeningPeriod) {
                    ForEach(MusicListeningPeriod.allCases, id: \.self) { period in
                        Text(period.title).tag(period)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 180)

                if case .loaded = listeningPhase {
                    Text("榜单收录 \(records.count) 首 · \(playCount.formatted()) 次播放")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Spacer()
                Button { onOpenRoute(.listeningFootprints) } label: {
                    Label("完整足迹", systemImage: "chart.line.uptrend.xyaxis")
                }
                .help("查看今日、周、月和年度听歌足迹")
            }

            if let recentPlayedSong {
                HStack(spacing: 12) {
                    Label("最近播放", systemImage: "clock.arrow.circlepath")
                        .font(.callout.weight(.medium))
                        .frame(width: 88, alignment: .leading)
                    LibraryRemoteImage(
                        url: recentPlayedSong.album.artwork.remoteURL,
                        symbol: "music.note",
                        size: 38
                    )
                    VStack(alignment: .leading, spacing: 2) {
                        SongTitleText(song: recentPlayedSong).lineLimit(1)
                        SongMetadataLinks(song: recentPlayedSong, onOpenRoute: onOpenRoute)
                    }
                    Spacer()
                    Button {
                        player.play(recentPlayedSong, in: [recentPlayedSong])
                    } label: {
                        Image(systemName: "play.fill")
                    }
                    .buttonStyle(.borderless)
                    .help("播放 \(recentPlayedSong.name)")
                    .accessibilityLabel("播放 \(recentPlayedSong.name)")
                    .frame(width: 44, height: 44)
                }
                .frame(minHeight: 48)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { player.play(recentPlayedSong, in: [recentPlayedSong]) }
                .contextMenu {
                    SongContextMenu(song: recentPlayedSong, songs: [recentPlayedSong], model: model, player: player)
                }
                Divider()
            }

            switch listeningPhase {
            case .idle, .loading:
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("正在加载听歌排行…").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 96)
            case let .failed(message):
                VStack(spacing: 10) {
                    Label("听歌排行加载失败", systemImage: "wifi.exclamationmark")
                    Text(message).font(.caption).foregroundStyle(.secondary)
                    Button("重试") {
                        guard let userID = model.librarySnapshot?.user.id else { return }
                        startListeningLoad(userID: userID)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 120)
            case .loggedOut:
                EmptyLibrarySection(title: "登录后查看听歌排行", symbol: "chart.bar")
            case .loaded:
                if records.isEmpty {
                    EmptyLibrarySection(title: "暂无听歌排行", symbol: "chart.bar")
                } else {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(records.enumerated()), id: \.element.id) { index, record in
                            HStack(spacing: 12) {
                                Text("\(index + 1)")
                                    .font(.callout.monospacedDigit())
                                    .foregroundStyle(index < 3 ? .primary : .secondary)
                                    .frame(width: 28, alignment: .trailing)
                                LibraryRemoteImage(
                                    url: record.song.album.artwork.remoteURL,
                                    symbol: "music.note",
                                    size: 42
                                )
                                VStack(alignment: .leading, spacing: 2) {
                                    SongTitleText(song: record.song).lineLimit(1)
                                    SongMetadataLinks(song: record.song, onOpenRoute: onOpenRoute)
                                }
                                Spacer()
                                Text("\(record.playCount.formatted()) 次")
                                    .font(.callout.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                    .frame(minWidth: 64, alignment: .trailing)
                                Button {
                                    player.play(record.song, in: songs)
                                } label: {
                                    Image(systemName: "play.fill")
                                }
                                .buttonStyle(.borderless)
                                .help("播放 \(record.song.name)")
                                .accessibilityLabel("播放 \(record.song.name)")
                                .frame(width: 44, height: 44)
                            }
                            .frame(minHeight: 48)
                            .contentShape(Rectangle())
                            .onTapGesture(count: 2) { player.play(record.song, in: songs) }
                            .contextMenu {
                                SongContextMenu(song: record.song, songs: songs, model: model, player: player)
                            }
                        }
                    }
                }
            }
        })
    }

    private func playlists(_ snapshot: LibrarySnapshot) -> AnyView {
        AnyView(VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("我的歌单")
                    .font(.title3.weight(.semibold))
                Spacer()
                Button {
                    showingPlaylistOrder = true
                } label: {
                    Label("排序", systemImage: "arrow.up.arrow.down")
                }
                .disabled(
                    progressiveSnapshot != nil
                        || snapshot.playlists.filter { $0.isUserEditable(by: snapshot.user.id) }.count < 2
                )
            }
            if let playlistError {
                Label(playlistError, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.red)
            }
            if snapshot.playlists.isEmpty {
                EmptyLibrarySection(title: "还没有歌单", symbol: "music.note.list")
            } else {
                ForEach(snapshot.playlists) { playlist in
                    Button {
                        onOpenRoute(.playlist(playlist.id))
                    } label: {
                        HStack(spacing: 12) {
                            LibraryRemoteImage(url: playlist.artwork.remoteURL, symbol: "music.note.list", size: 42)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(playlist.name)
                                    .foregroundStyle(.primary)
                                Text(playlist.creator)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text("\(playlist.trackCount) 首歌曲")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                            Spacer()
                            if deletingPlaylistID == playlist.id {
                                ProgressView()
                                    .controlSize(.small)
                                    .accessibilityLabel("正在删除 \(playlist.name)")
                            } else {
                                Image(systemName: "chevron.right")
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .frame(minHeight: 48)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("打开歌单详情")
                    .contextMenu {
                        Button(role: .destructive) {
                            playlistToDelete = playlist
                            showDeleteConfirmation = true
                        } label: {
                            Label("删除歌单", systemImage: "trash")
                        }
                        .disabled(deletingPlaylistID != nil)
                    }
                }
            }
        })
    }

    private func following(_ snapshot: LibrarySnapshot) -> AnyView {
        AnyView(VStack(alignment: .leading, spacing: 10) {
            if snapshot.following.isEmpty {
                EmptyLibrarySection(title: "暂无关注", symbol: "person.2")
            } else {
                ForEach(snapshot.following) { item in
                    let kindTitle = item.kind == .user ? "用户" : "歌手"
                    Button {
                        switch item.kind {
                        case .user: onOpenRoute(.user(item.resourceID))
                        case .artist: onOpenRoute(.artist(item.resourceID))
                        }
                    } label: {
                        HStack(spacing: 12) {
                            LibraryRemoteImage(
                                url: item.imageURL,
                                symbol: item.kind == .user ? "person.crop.circle" : "music.mic",
                                size: 42
                            )
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 8) {
                                    Text(item.name)
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                    Text(kindTitle)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(.quaternary, in: Capsule())
                                        .fixedSize()
                                }
                                if !item.followDay.isEmpty {
                                    Text(item.followDay)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .foregroundStyle(.tertiary)
                        }
                        .frame(minHeight: 48)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("打开\(kindTitle)详情")
                }
            }
        })
    }

    private func recommendedUsers(_ snapshot: LibrarySnapshot) -> AnyView {
        AnyView(VStack(alignment: .leading, spacing: 10) {
            if snapshot.recommendedUsers.isEmpty {
                EmptyLibrarySection(title: "暂无推荐用户", symbol: "person.badge.plus")
            } else {
                ForEach(snapshot.recommendedUsers) { user in
                    Button { onOpenRoute(.user(user.id)) } label: {
                        HStack(spacing: 12) {
                            LibraryRemoteImage(url: user.avatarURL, symbol: "person.crop.circle", size: 42)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(user.nickname).foregroundStyle(.primary)
                                Text(user.signature.isEmpty ? user.description : user.signature)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                        }
                        .frame(minHeight: 48)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("打开用户详情")
                }
            }
        })
    }

    private var createPlaylistForm: AnyView {
        AnyView(VStack(alignment: .leading, spacing: 12) {
            Text("新建歌单")
                .font(.title3.weight(.semibold))
            LabeledContent("名称") {
                TextField("输入歌单名称", text: $playlistName)
                    .textFieldStyle(.roundedBorder)
            }
            Toggle("设为私密歌单", isOn: $privatePlaylist)
            HStack {
                Button {
                    createPlaylist()
                } label: {
                    HStack(spacing: 6) {
                        if isCreatingPlaylist {
                            ProgressView()
                                .controlSize(.small)
                            Text("创建中")
                        } else {
                            Label("创建歌单", systemImage: "plus")
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isCreatingPlaylist || playlistName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if let creationError {
                    Label(creationError, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.red)
                }
            }
        }
        .frame(maxWidth: 560, alignment: .leading))
    }

    @MainActor
    private func reloadLibrary() {
        libraryReloadRevision &+= 1
    }

    @MainActor
    private func loadForced() async {
        let (identity, _) = libraryLoadState.begin(libraryLoadTrigger)
        await load(identity: identity, force: true)
    }

    @MainActor
    private func load(identity: MusicLibraryLoadIdentity, force: Bool) async {
        let playlistRevision = model.playlistContentRevision
        guard acceptsLibraryLoad(identity) else { return }
        if !force, let snapshot = model.librarySnapshot {
            progressiveSnapshot = nil
            phase = .loaded
            startListeningLoad(userID: snapshot.user.id)
            return
        }
        playlistError = nil
        visibleRecommendationCount = 20
        progressiveSnapshot = nil
        phase = .loading
        do {
            let login = try await library.loginState(
                forceRefresh: force,
                expectedCredentialRevision: identity.credentialRevision
            )
            try Task.checkCancellation()
            guard acceptsLibraryLoad(identity) else { return }
            guard case let .loggedIn(user) = login else {
                progressiveSnapshot = nil
                model.librarySnapshot = nil
                phase = .loggedOut
                return
            }
            async let songs = library.dailyRecommendations(
                forceRefresh: force,
                expectedCredentialRevision: identity.credentialRevision
            )
            async let following = library.myFollowing(
                forceRefresh: force,
                expectedCredentialRevision: identity.credentialRevision,
                onUpdate: { values in
                    publishLibraryProgress(
                        user: user,
                        identity: identity,
                        playlistRevision: playlistRevision,
                        following: values
                    )
                }
            )
            let loadedPlaylists: [Playlist]
            if force {
                loadedPlaylists = try await library.userPlaylists(
                    userID: user.id,
                    forceRefresh: true,
                    expectedCredentialRevision: identity.credentialRevision,
                    onUpdate: { values in
                        publishLibraryProgress(
                            user: user,
                            identity: identity,
                            playlistRevision: playlistRevision,
                            playlists: values
                        )
                    }
                )
            } else {
                loadedPlaylists = try await model.accountPlaylists(
                    userID: user.id,
                    credentialRevision: identity.credentialRevision,
                    onUpdate: { values in
                        publishLibraryProgress(
                            user: user,
                            identity: identity,
                            playlistRevision: playlistRevision,
                            playlists: values
                        )
                    }
                )
            }
            let (loadedSongs, loadedFollowing) = try await (songs, following)
            let loadedRecommendedUsers = (try? await extras.recommendedUsers(
                expectedCredentialRevision: identity.credentialRevision
            )) ?? []
            try Task.checkCancellation()
            guard acceptsLibraryLoad(identity) else { return }
            model.storeLibrarySnapshot(LibrarySnapshot(
                user: user,
                songs: loadedSongs,
                playlists: loadedPlaylists,
                following: loadedFollowing,
                recommendedUsers: loadedRecommendedUsers
            ), playlistRevision: playlistRevision)
            progressiveSnapshot = nil
            phase = .loaded
            startListeningLoad(userID: user.id)
        } catch is CancellationError {
            guard !Task.isCancelled else { return }
            guard acceptsLibraryLoad(identity) else { return }
            await load(identity: identity, force: force)
        } catch {
            guard acceptsLibraryLoad(identity) else { return }
            progressiveSnapshot = nil
            phase = .failed(error.localizedDescription)
        }
    }

    private func acceptsLibraryLoad(_ identity: MusicLibraryLoadIdentity) -> Bool {
        libraryLoadState.accepts(
            identity,
            accountID: model.currentUserID,
            credentialRevision: library.transport.credentialSnapshotValue().revision
        )
    }

    @MainActor
    private func publishLibraryProgress(
        user: MusicLibraryUser,
        identity: MusicLibraryLoadIdentity,
        playlistRevision: Int,
        playlists: [Playlist]? = nil,
        following: [MusicLibraryFollow]? = nil
    ) {
        guard acceptsLibraryLoad(identity), playlistRevision == model.playlistContentRevision else { return }
        let current = progressiveSnapshot?.user.id == user.id
            ? progressiveSnapshot
            : (model.librarySnapshot?.user.id == user.id ? model.librarySnapshot : nil)
        progressiveSnapshot = LibrarySnapshot(
            user: user,
            songs: current?.songs ?? [],
            playlists: playlists ?? current?.playlists ?? [],
            following: following ?? current?.following ?? [],
            recommendedUsers: current?.recommendedUsers ?? []
        )
    }

    @MainActor
    private func refreshPlaylistsIfNeeded(trigger: MusicLibraryLoadTrigger) async {
        guard let snapshot = model.librarySnapshot, !model.cachedPlaylistsAreFresh() else { return }
        let identity = libraryLoadState.identity(for: trigger)
        let revision = model.playlistContentRevision
        do {
            try await Task.sleep(for: .milliseconds(200))
            let playlists = try await library.userPlaylists(
                userID: snapshot.user.id,
                expectedCredentialRevision: identity.credentialRevision
            )
            try Task.checkCancellation()
            guard acceptsPlaylistRefresh(identity, userID: snapshot.user.id) else { return }
            if model.storeCachedPlaylists(playlists, playlistRevision: revision) {
                playlistError = nil
            }
        } catch is CancellationError {
            guard !Task.isCancelled,
                  acceptsPlaylistRefresh(identity, userID: snapshot.user.id)
            else { return }
            await refreshPlaylistsIfNeeded(trigger: trigger)
        } catch {
            guard acceptsPlaylistRefresh(identity, userID: snapshot.user.id) else { return }
            playlistError = error.localizedDescription
        }
    }

    private func acceptsPlaylistRefresh(_ identity: MusicLibraryLoadIdentity, userID: Int64) -> Bool {
        acceptsLibraryLoad(identity) && model.librarySnapshot?.user.id == userID
    }

    @MainActor
    private func startListeningLoad(
        userID: Int64,
        forceRefresh: Bool = false,
        refreshUser: Bool = false,
        eventSequence: UInt64? = nil
    ) {
        let credentialRevision = library.transport.credentialSnapshotValue().revision
        if listeningTask != nil, listeningCredentialRevision != credentialRevision {
            listeningTask?.cancel()
            listeningTask = nil
            listeningTaskID = nil
        }
        guard listeningTask == nil else { return }
        let taskID = UUID()
        listeningTaskID = taskID
        listeningCredentialRevision = credentialRevision
        listeningTask = Task { @MainActor in
            await loadListening(
                userID: userID,
                credentialRevision: credentialRevision,
                forceRefresh: forceRefresh,
                refreshUser: refreshUser,
                eventSequence: eventSequence,
                taskID: taskID
            )
        }
    }

    @MainActor
    private func loadListening(
        userID: Int64,
        credentialRevision: UInt64,
        forceRefresh: Bool,
        refreshUser: Bool,
        eventSequence: UInt64?,
        taskID: UUID
    ) async {
        listeningPhase = .loading
        totalListeningSeconds = nil
        var settlesEvent = false
        var discardsEvent = false
        do {
            async let weekly = library.listeningRecords(
                userID: userID,
                period: .week,
                forceRefresh: forceRefresh,
                expectedCredentialRevision: credentialRevision
            )
            async let allTime = library.listeningRecords(
                userID: userID,
                period: .allTime,
                forceRefresh: forceRefresh,
                expectedCredentialRevision: credentialRevision
            )
            async let recent = library.recentlyPlayedSongs(
                limit: 1,
                forceRefresh: forceRefresh,
                expectedCredentialRevision: credentialRevision
            )
            async let totalDuration = try? library.totalListeningDuration(
                forceRefresh: forceRefresh,
                expectedCredentialRevision: credentialRevision
            )
            let (loadedWeekly, loadedAllTime, loadedRecent, loadedTotalDuration) = try await (
                weekly,
                allTime,
                recent,
                totalDuration
            )
            try Task.checkCancellation()
            guard listeningTaskID == taskID,
                  model.currentUserID == userID,
                  library.transport.credentialSnapshotValue().revision == credentialRevision
            else {
                discardsEvent = true
                throw CancellationError()
            }
            weeklyListeningRecords = loadedWeekly
            allTimeListeningRecords = loadedAllTime
            recentPlayedSong = loadedRecent.first
            totalListeningSeconds = loadedTotalDuration
            listeningPhase = .loaded
            settlesEvent = true

            if refreshUser,
               let user = try? await library.userInfo(
                   userID: userID,
                   forceRefresh: forceRefresh,
                   expectedCredentialRevision: credentialRevision
               ),
               library.transport.credentialSnapshotValue().revision == credentialRevision,
               let snapshot = model.librarySnapshot {
                model.librarySnapshot = LibrarySnapshot(
                    user: user,
                    songs: snapshot.songs,
                    playlists: snapshot.playlists,
                    following: snapshot.following,
                    recommendedUsers: snapshot.recommendedUsers
                )
            }
        } catch is CancellationError {
        } catch {
            if model.currentUserID != userID
                || library.transport.credentialSnapshotValue().revision != credentialRevision {
                discardsEvent = true
            } else {
                listeningPhase = .failed(error.localizedDescription)
                settlesEvent = true
            }
        }
        guard listeningTaskID == taskID else { return }
        if (settlesEvent || discardsEvent), let eventSequence {
            historyRefreshes.settle(.song, sequence: eventSequence)
        }
        listeningTask = nil
        listeningTaskID = nil
        listeningCredentialRevision = nil
        drainListeningRefresh()
    }

    private func consumeHistoryEvent(_ event: PlaybackHistoryEvent?) {
        guard let event, event.kind == .song,
              historyRefreshes.record(
                  event,
                  credentialRevision: library.transport.credentialSnapshotValue().revision,
                  keys: [.song]
              )
        else { return }
        drainListeningRefresh()
    }

    private func drainListeningRefresh() {
        guard isVisible,
              selectedSection == .listening,
              listeningTask == nil,
              let userID = model.librarySnapshot?.user.id,
              let sequence = historyRefreshes.pendingSequence(for: .song)
        else { return }
        startListeningLoad(
            userID: userID,
            forceRefresh: true,
            refreshUser: true,
            eventSequence: sequence
        )
    }

    private func listeningDurationText(_ seconds: Int64) -> String {
        let totalMinutes = max(0, seconds) / 60
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if hours == 0 { return minutes == 0 ? "不足 1 分钟" : "\(minutes) 分钟" }
        if minutes == 0 { return "\(hours) 小时" }
        return "\(hours) 小时 \(minutes) 分钟"
    }

    private func createPlaylist() {
        let name = playlistName
        let credentialRevision = library.transport.credentialSnapshotValue().revision
        creationError = nil
        isCreatingPlaylist = true
        Task { @MainActor in
            do {
                _ = try await library.createPlaylist(
                    name: name,
                    privacy: privatePlaylist ? .privatePlaylist : .publicPlaylist,
                    expectedCredentialRevision: credentialRevision
                )
                try Task.checkCancellation()
                guard library.transport.credentialSnapshotValue().revision == credentialRevision else {
                    throw CancellationError()
                }
                playlistName = ""
                privatePlaylist = false
                isCreatingPlaylist = false
                model.showToast("歌单已创建")
                await loadForced()
            } catch is CancellationError {
                isCreatingPlaylist = false
            } catch {
                guard library.transport.credentialSnapshotValue().revision == credentialRevision else {
                    isCreatingPlaylist = false
                    return
                }
                creationError = error.localizedDescription
                isCreatingPlaylist = false
            }
        }
    }

    private func deletePlaylist(_ playlist: Playlist) {
        let credentialRevision = library.transport.credentialSnapshotValue().revision
        playlistError = nil
        deletingPlaylistID = playlist.id
        Task { @MainActor in
            do {
                try await library.deletePlaylist(
                    playlist.id,
                    expectedCredentialRevision: credentialRevision
                )
                try Task.checkCancellation()
                guard library.transport.credentialSnapshotValue().revision == credentialRevision else {
                    throw CancellationError()
                }
                playlistToDelete = nil
                deletingPlaylistID = nil
                model.showToast("歌单已删除")
                await loadForced()
            } catch is CancellationError {
                deletingPlaylistID = nil
            } catch {
                guard library.transport.credentialSnapshotValue().revision == credentialRevision else {
                    deletingPlaylistID = nil
                    return
                }
                playlistError = error.localizedDescription
                deletingPlaylistID = nil
            }
        }
    }
}

private struct PlaylistOrderEditor: View {
    let original: [Playlist]
    let library: LiveMusicLibrary
    let reload: () async -> Void
    let onSaved: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var draft: [Playlist]
    @State private var errorMessage: String?
    @State private var isSaving = false
    @State private var saveTask: Task<Void, Never>?

    init(
        playlists: [Playlist],
        library: LiveMusicLibrary,
        reload: @escaping () async -> Void,
        onSaved: @escaping () -> Void
    ) {
        original = playlists
        self.library = library
        self.reload = reload
        self.onSaved = onSaved
        _draft = State(initialValue: playlists)
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(draft) { playlist in
                    HStack(spacing: 12) {
                        LibraryRemoteImage(
                            url: playlist.artwork.remoteURL,
                            symbol: "music.note.list",
                            size: 38
                        )
                        Text(playlist.name).lineLimit(1)
                    }
                    .frame(minHeight: 44)
                }
                .onMove { source, destination in
                    guard !isSaving else { return }
                    draft.move(fromOffsets: source, toOffset: destination)
                }
            }
            .navigationTitle("歌单排序")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                        .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(action: save) {
                        if isSaving {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("保存")
                        }
                    }
                    .disabled(isSaving || draft.map(\.id) == original.map(\.id))
                }
            }
            .safeAreaInset(edge: .bottom) {
                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                        .background(.bar)
                }
            }
        }
        .frame(minWidth: 480, minHeight: 520)
        .interactiveDismissDisabled(isSaving)
        .onDisappear { saveTask?.cancel() }
    }

    private func save() {
        guard !isSaving, draft.map(\.id) != original.map(\.id) else { return }
        let credentialRevision = library.transport.credentialSnapshotValue().revision
        errorMessage = nil
        isSaving = true
        saveTask = Task { @MainActor in
            do {
                try await library.updatePlaylistOrder(
                    draft.map(\.id),
                    expectedCredentialRevision: credentialRevision
                )
                try Task.checkCancellation()
                guard library.transport.credentialSnapshotValue().revision == credentialRevision else {
                    throw CancellationError()
                }
                await reload()
                guard library.transport.credentialSnapshotValue().revision == credentialRevision else {
                    throw CancellationError()
                }
                onSaved()
                dismiss()
            } catch is CancellationError {
                isSaving = false
                saveTask = nil
            } catch {
                guard library.transport.credentialSnapshotValue().revision == credentialRevision else {
                    isSaving = false
                    saveTask = nil
                    return
                }
                errorMessage = error.localizedDescription
                isSaving = false
                saveTask = nil
            }
        }
    }
}

struct ListeningHistoryView: View {
    @Bindable var model: AppModel
    let library: LiveMusicLibrary
    @Bindable var player: PlayerController

    @State private var selectedKind = RecentPlaybackKind.song
    @State private var history = RecentPlaybackState()
    @State private var tasks: [RecentPlaybackKind: Task<Void, Never>] = [:]
    @State private var taskIDs: [RecentPlaybackKind: UUID] = [:]
    @State private var fallbackLoads: [RecentPlaybackKind: RecentPlaybackLoad] = [:]
    @State private var historyRefreshes = PlaybackHistoryRefreshTracker<RecentPlaybackKind>()
    @State private var isVisible = false
    @FocusState private var isKindPickerFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            if model.currentUserID == nil {
                ContentUnavailableView(
                    "需要登录",
                    systemImage: "person.crop.circle.badge.exclamationmark",
                    description: Text("扫码登录后查看最近播放。")
                )
            } else {
                kindPicker
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                Divider()
                playbackContent(selectedKind)
                    .id(selectedKind)
            }
        }
        .navigationTitle("最近播放")
        .toolbar {
            ToolbarItem {
                Button { startLoad(selectedKind, force: true) } label: {
                    if tasks[selectedKind] != nil {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .help("刷新播放历史")
                .accessibilityLabel(tasks[selectedKind] == nil ? "刷新播放历史" : "正在刷新播放历史")
                .disabled(model.currentUserID == nil || tasks[selectedKind] != nil)
            }
        }
        .task(id: "\(model.currentUserID ?? 0):\(playerAccountCredentialRevision)") {
            reset(accountID: model.currentUserID)
        }
        .onAppear {
            isVisible = true
            consumeHistoryEvent(player.playbackHistoryEvent)
            drainRefresh(for: selectedKind)
        }
        .onDisappear {
            isVisible = false
            for kind in Array(tasks.keys) { cancelLoad(kind) }
        }
        .onChange(of: selectedKind) { oldKind, kind in
            cancelLoad(oldKind)
            drainRefresh(for: kind)
            if tasks[kind] == nil { startLoad(kind) }
            restorePickerFocus(for: kind)
        }
        .onChange(of: player.playbackHistoryEvent) { _, event in
            consumeHistoryEvent(event)
        }
    }

    @MainActor
    private var kindPicker: some View {
        ViewThatFits(in: .horizontal) {
            Picker("播放类型", selection: $selectedKind) {
                ForEach(RecentPlaybackKind.allCases, id: \.self) { kind in
                    Text(kind.title).tag(kind)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(minWidth: 560, maxWidth: 680)
            .focused($isKindPickerFocused)

            Picker("播放类型", selection: $selectedKind) {
                ForEach(RecentPlaybackKind.allCases, id: \.self) { kind in
                    Label(kind.title, systemImage: kind.symbol).tag(kind)
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: .infinity, alignment: .leading)
            .focused($isKindPickerFocused)
        }
    }

    private func playbackContent(_ kind: RecentPlaybackKind) -> AnyView {
        switch history.load(for: kind) {
        case .idle, .loading:
            AnyView(VStack(spacing: 12) {
                ProgressView()
                Text("正在加载\(kind.title)记录…")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity))
        case let .failed(message):
            AnyView(ContentUnavailableView {
                Label("\(kind.title)记录加载失败", systemImage: "wifi.exclamationmark")
            } description: {
                Text(message)
            } actions: {
                Button("重试") { startLoad(kind) }
            })
        case let .loaded(content):
            loadedContent(content, kind: kind)
        }
    }

    private func loadedContent(_ content: RecentPlaybackContent, kind: RecentPlaybackKind) -> AnyView {
        switch content {
        case let .songs(songs) where !songs.isEmpty:
            AnyView(ScrollView {
                SongList(songs: songs, model: model, player: player, showsHeading: false)
                    .padding(.horizontal, 28)
                    .padding(.vertical, 20)
            })
        case let .albums(albums) where !albums.isEmpty:
            AnyView(destinationList(albums.map(SearchItem.album)))
        case let .playlists(playlists) where !playlists.isEmpty:
            AnyView(destinationList(playlists.map(SearchItem.playlist)))
        case let .media(items) where !items.isEmpty:
            AnyView(ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(items) { item in
                        RecentMediaRow(
                            item: item,
                            symbol: kind.symbol,
                            open: recentRoute(for: kind, item: item).map { route in
                                { model.open(route) }
                            }
                        )
                        Divider().padding(.leading, 64)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 8)
            })
        default:
            AnyView(ContentUnavailableView(
                "暂无\(kind.title)记录",
                systemImage: kind.symbol,
                description: Text("账号最近播放的\(kind.title)会显示在这里。")
            ))
        }
    }

    private func destinationList(_ items: [SearchItem]) -> some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(items) { item in
                    SearchResultRow(item: item, onOpenRoute: model.open) {
                        if let route = item.route { model.open(route) }
                    }
                    Divider().padding(.leading, 76)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
        }
    }

    private func recentRoute(for kind: RecentPlaybackKind, item: RecentMediaSummary) -> Route? {
        switch kind {
        case .video:
            switch item.videoKind {
            case .mv:
                guard let id = Int64(item.resourceID), id > 0 else { return nil }
                return .mv(id)
            case .video:
                return .video(item.resourceID)
            case nil:
                return nil
            }
        case .voice:
            return Int64(item.resourceID).map(Route.podcastEpisode)
        case .podcast:
            return Int64(item.resourceID).map(Route.podcast)
        case .song, .album, .playlist:
            return nil
        }
    }

    @MainActor
    private func reset(accountID: Int64?) {
        tasks.values.forEach { $0.cancel() }
        tasks.removeAll()
        taskIDs.removeAll()
        fallbackLoads.removeAll()
        historyRefreshes.reset()
        history.reset(accountID: accountID)
        selectedKind = .song
        if accountID != nil {
            consumeHistoryEvent(player.playbackHistoryEvent)
            if tasks[.song] == nil { startLoad(.song) }
        }
    }

    @MainActor
    private func startLoad(
        _ kind: RecentPlaybackKind,
        force: Bool = false,
        eventSequence: UInt64? = nil
    ) {
        guard let accountID = model.currentUserID else { return }
        guard tasks[kind] == nil else { return }
        if !force {
            switch history.load(for: kind) {
            case .loading, .loaded: return
            case .idle, .failed: break
            }
        }

        let generation = history.generation
        let previousLoad = history.load(for: kind)
        fallbackLoads[kind] = previousLoad
        if case .loaded = previousLoad, force {
        } else {
            history.setLoading(kind)
        }
        let taskID = UUID()
        let credentialRevision = playerAccountCredentialRevision
        taskIDs[kind] = taskID
        tasks[kind] = Task { @MainActor in
            defer {
                if taskIDs[kind] == taskID {
                    tasks[kind] = nil
                    taskIDs[kind] = nil
                    fallbackLoads[kind] = nil
                    drainRefresh(for: kind)
                }
            }
            do {
                let content = try await load(
                    kind,
                    forceRefresh: force,
                    expectedCredentialRevision: credentialRevision
                )
                try Task.checkCancellation()
                guard taskIDs[kind] == taskID, model.currentUserID == accountID else { return }
                guard library.transport.credentialSnapshotValue().revision == credentialRevision else {
                    if let eventSequence { historyRefreshes.settle(kind, sequence: eventSequence) }
                    return
                }
                guard history.accept(
                    .loaded(content),
                    for: kind,
                    generation: generation,
                    accountID: accountID
                ) else { return }
                if let eventSequence { historyRefreshes.settle(kind, sequence: eventSequence) }
            } catch is CancellationError {
                guard taskIDs[kind] == taskID,
                      model.currentUserID == accountID,
                      history.accept(
                          previousLoad,
                          for: kind,
                          generation: generation,
                          accountID: accountID
                      )
                else { return }
            } catch {
                guard taskIDs[kind] == taskID, model.currentUserID == accountID else { return }
                guard library.transport.credentialSnapshotValue().revision == credentialRevision else {
                    if let eventSequence { historyRefreshes.settle(kind, sequence: eventSequence) }
                    _ = history.accept(
                        previousLoad,
                        for: kind,
                        generation: generation,
                        accountID: accountID
                    )
                    return
                }
                guard history.accept(
                    .failed(error.localizedDescription),
                    for: kind,
                    generation: generation,
                    accountID: accountID
                ) else { return }
                if let eventSequence { historyRefreshes.settle(kind, sequence: eventSequence) }
            }
        }
    }

    private var playerAccountCredentialRevision: UInt64 {
        library.transport.credentialSnapshotValue().revision
    }

    private func load(
        _ kind: RecentPlaybackKind,
        forceRefresh: Bool,
        expectedCredentialRevision: UInt64
    ) async throws -> RecentPlaybackContent {
        switch kind {
        case .song:
            .songs(try await library.recentlyPlayedSongs(
                forceRefresh: forceRefresh,
                expectedCredentialRevision: expectedCredentialRevision
            ))
        case .album:
            .albums(try await library.recentlyPlayedAlbums(
                forceRefresh: forceRefresh,
                expectedCredentialRevision: expectedCredentialRevision
            ))
        case .playlist:
            .playlists(try await library.recentlyPlayedPlaylists(
                forceRefresh: forceRefresh,
                expectedCredentialRevision: expectedCredentialRevision
            ))
        case .video:
            .media(try await library.recentlyPlayedVideos(
                forceRefresh: forceRefresh,
                expectedCredentialRevision: expectedCredentialRevision
            ))
        case .voice:
            .media(try await library.recentlyPlayedVoices(
                forceRefresh: forceRefresh,
                expectedCredentialRevision: expectedCredentialRevision
            ))
        case .podcast:
            .media(try await library.recentlyPlayedPodcasts(
                forceRefresh: forceRefresh,
                expectedCredentialRevision: expectedCredentialRevision
            ))
        }
    }

    @MainActor
    private func cancelLoad(_ kind: RecentPlaybackKind) {
        tasks[kind]?.cancel()
        tasks[kind] = nil
        taskIDs[kind] = nil
        guard let fallback = fallbackLoads.removeValue(forKey: kind),
              let accountID = model.currentUserID
        else { return }
        _ = history.accept(
            fallback,
            for: kind,
            generation: history.generation,
            accountID: accountID
        )
    }

    @MainActor
    private func consumeHistoryEvent(_ event: PlaybackHistoryEvent?) {
        guard let event else { return }
        let kinds: [RecentPlaybackKind] = switch event.kind {
        case .song: [.song]
        case .podcast: [.voice, .podcast]
        }
        guard historyRefreshes.record(
            event,
            credentialRevision: playerAccountCredentialRevision,
            keys: kinds
        ) else { return }
        drainRefresh(for: selectedKind)
    }

    @MainActor
    private func drainRefresh(for kind: RecentPlaybackKind) {
        guard isVisible,
              selectedKind == kind,
              tasks[kind] == nil,
              let sequence = historyRefreshes.pendingSequence(for: kind)
        else { return }
        startLoad(kind, force: true, eventSequence: sequence)
    }

    private func restorePickerFocus(for kind: RecentPlaybackKind) {
        Task { @MainActor in
            await Task.yield()
            guard isVisible, selectedKind == kind else { return }
            isKindPickerFocused = true
        }
    }
}

private struct RecentMediaRow: View {
    let item: RecentMediaSummary
    let symbol: String
    let open: (() -> Void)?

    var body: some View {
        Group {
            if let open {
                Button(action: open) { row }
                    .buttonStyle(.plain)
                    .help("打开 \(item.title)")
            } else {
                row
            }
        }
    }

    private var row: some View {
        HStack(spacing: 12) {
            LibraryRemoteImage(url: item.artworkURL, symbol: symbol, size: 52)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                if !item.subtitle.isEmpty {
                    Text(item.subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            if let playedAt = item.playedAt {
                Text(playedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
        }
        .frame(minHeight: 60)
        .accessibilityElement(children: .combine)
    }
}

private enum MusicLibrarySection: String, CaseIterable {
    case recommendations = "每日推荐"
    case listening = "听歌足迹"
    case playlists = "我的歌单"
    case following = "我的关注"
    case recommendedUsers = "推荐用户"

    var symbol: String {
        switch self {
        case .recommendations: "sparkles"
        case .listening: "chart.bar"
        case .playlists: "music.note.list"
        case .following: "person.2"
        case .recommendedUsers: "person.badge.plus"
        }
    }
}

private func confirmedComment(
    _ serverComment: MusicComment?,
    songID: Int64,
    userID: Int64,
    nickname: String,
    content: String,
    replyToNickname: String? = nil
) -> MusicComment {
    MusicComment(
        id: serverComment?.id ?? -Int64.random(in: 1...Int64.max),
        songID: songID,
        userID: serverComment?.userID == 0 ? userID : serverComment?.userID ?? userID,
        nickname: serverComment.flatMap { $0.nickname.isEmpty ? nil : $0.nickname } ?? nickname,
        content: serverComment.flatMap { $0.content.isEmpty ? nil : $0.content } ?? content,
        timeText: serverComment.flatMap { $0.timeText.isEmpty ? nil : $0.timeText } ?? "刚刚",
        likedCount: serverComment?.likedCount ?? 0,
        isLiked: serverComment?.isLiked ?? false,
        replyCount: serverComment?.replyCount ?? 0,
        replyToNickname: serverComment?.replyToNickname ?? replyToNickname
    )
}

struct CommentsView: View {
    let songID: Int64
    let library: LiveMusicLibrary
    let currentUserID: Int64?
    let currentUserNickname: String
    let onOpenUser: (Int64) -> Void
    let onLogin: () -> Void

    @State private var comments: [MusicComment] = []
    @State private var cursor = "0"
    @State private var pageNumber = 1
    @State private var sortType = 0
    @State private var hasMore = false
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var emojiPictureIDs: [String: String] = [:]
    @State private var commentText = ""
    @State private var isSubmitting = false
    @State private var writeMessage: String?
    @State private var successMessage: String?
    @State private var loadGeneration = 0
    @State private var loadTask: Task<Void, Never>?
    @State private var writeTask: Task<Void, Never>?
    @State private var successTask: Task<Void, Never>?

    var body: AnyView { AnyView(content) }

    private var content: AnyView {
        AnyView(VStack(spacing: 0) {
            composer
            Divider()
            commentList
        }
        .navigationTitle("评论")
        .task(id: songID) { startLoad(reset: true) }
        .task { emojiPictureIDs = (try? await library.commentEmojiPictureIDs()) ?? [:] }
        .onDisappear {
            loadTask?.cancel()
            writeTask?.cancel()
            successTask?.cancel()
        }
        .overlay(alignment: .top) {
            InteractionToast(message: successMessage)
                .padding(.top, 12)
        }
        .alert("发表评论失败", isPresented: writeMessagePresented) {
            Button("好") { writeMessage = nil }
        } message: {
            Text(writeMessage ?? "")
        })
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                TextField("发表评论", text: $commentText, axis: .vertical)
                    .lineLimit(1...4)
                    .disabled(currentUserID == nil || isSubmitting)
                    .onSubmit(submitComment)
                Button(action: submitComment) {
                    if isSubmitting {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "paperplane.fill")
                    }
                }
                .frame(width: 30, height: 30)
                .disabled(currentUserID == nil || trimmedComment.isEmpty || isSubmitting)
                .help("发表评论")
                .accessibilityLabel("发表评论")
            }
            if currentUserID == nil {
                HStack(spacing: 6) {
                    Text("登录后可发表评论和参与互动")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("去登录", action: onLogin)
                        .buttonStyle(.link)
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
    }

    @ViewBuilder
    private var commentList: some View {
        Group {
            if isLoading && comments.isEmpty {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("正在加载评论…")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage, comments.isEmpty {
                ContentUnavailableView {
                    Label("评论加载失败", systemImage: "wifi.exclamationmark")
                } description: {
                    Text(errorMessage)
                } actions: {
                    Button("重试") { startLoad(reset: true) }
                }
            } else if comments.isEmpty {
                ContentUnavailableView(
                    "暂无评论",
                    systemImage: "bubble.left",
                    description: Text("这首歌还没有可显示的评论。")
                )
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(comments) { comment in
                            CommentThreadRow(
                                comment: comment,
                                library: library,
                                currentUserID: currentUserID,
                                currentUserNickname: currentUserNickname,
                                emojiPictureIDs: emojiPictureIDs,
                                onOpenUser: onOpenUser,
                                onLogin: onLogin,
                                onCommentChanged: updateComment,
                                onCommentDeleted: removeComment,
                                onMainListRefresh: { startLoad(reset: true) },
                                onWriteSucceeded: showSuccess
                            )
                            Divider()
                        }
                        if let errorMessage {
                            InlineRetry(message: errorMessage) { startLoad(reset: false) }
                                .padding(.vertical, 8)
                        } else if hasMore {
                            LoadMoreTrigger { startLoad(reset: false) }
                                .id(pageNumber)
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var trimmedComment: String {
        commentText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var writeMessagePresented: Binding<Bool> {
        Binding(
            get: { writeMessage != nil },
            set: { if !$0 { writeMessage = nil } }
        )
    }

    private func submitComment() {
        let content = trimmedComment
        guard currentUserID != nil, !content.isEmpty, !isSubmitting else { return }
        let credentialRevision = library.transport.credentialSnapshotValue().revision
        isSubmitting = true
        writeTask = Task { @MainActor in
            defer {
                isSubmitting = false
                writeTask = nil
            }
            do {
                let serverComment = try await library.addComment(
                    songID: songID,
                    content: content,
                    expectedCredentialRevision: credentialRevision
                )
                try Task.checkCancellation()
                guard library.transport.credentialSnapshotValue().revision == credentialRevision else {
                    throw CancellationError()
                }
                commentText = ""
                let comment = confirmedComment(
                    serverComment,
                    songID: songID,
                    userID: currentUserID ?? 0,
                    nickname: currentUserNickname,
                    content: content
                )
                comments.removeAll { $0.id == comment.id }
                comments.insert(comment, at: 0)
                showSuccess("评论成功")
            } catch is CancellationError {
            } catch {
                writeMessage = error.localizedDescription
            }
        }
    }

    private func updateComment(_ updated: MusicComment) {
        comments = comments.map { $0.id == updated.id ? updated : $0 }
    }

    private func removeComment(_ commentID: Int64) {
        comments.removeAll { $0.id == commentID }
        startLoad(reset: true)
    }

    private func showSuccess(_ message: String) {
        successTask?.cancel()
        successMessage = message
        successTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .seconds(2))
                successMessage = nil
            } catch {
            }
        }
    }

    @MainActor
    private func startLoad(reset: Bool) {
        guard reset || loadTask == nil else { return }
        if reset {
            loadGeneration += 1
            loadTask?.cancel()
        }
        let generation = loadGeneration
        loadTask = Task { @MainActor in
            await load(reset: reset, generation: generation)
        }
    }

    @MainActor
    private func load(reset: Bool, generation: Int) async {
        isLoading = true
        errorMessage = nil
        let requestCursor = reset ? "0" : cursor
        let requestPage = reset ? 1 : pageNumber
        do {
            let page = try await library.comments(
                songID: songID,
                cursor: requestCursor,
                pageNumber: requestPage,
                pageSize: 20,
                sortType: sortType
            )
            try Task.checkCancellation()
            guard generation == loadGeneration else { return }
            if reset {
                comments = page.comments
            } else {
                let existing = Set(comments.map(\.id))
                comments += page.comments.filter { !existing.contains($0.id) }
            }
            cursor = page.cursor
            pageNumber = requestPage + 1
            sortType = page.sortType
            hasMore = page.hasMore
            isLoading = false
            loadTask = nil
        } catch is CancellationError {
            guard generation == loadGeneration else { return }
            isLoading = false
            loadTask = nil
        } catch {
            guard generation == loadGeneration else { return }
            errorMessage = error.localizedDescription
            isLoading = false
            loadTask = nil
        }
    }
}

struct DownloadsView: View {
    @Bindable private var manager: MusicDownloadManager

    init(manager: MusicDownloadManager) {
        self.manager = manager
    }

    var body: AnyView { AnyView(content) }

    private var content: AnyView {
        AnyView(VStack(spacing: 0) {
            HStack(spacing: 12) {
                Label(summaryText, systemImage: "arrow.down.circle")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                Button { Task { await manager.pauseAll() } } label: {
                    Label("暂停全部", systemImage: "pause.circle")
                }
                .disabled(!hasActiveDownloads)
                .help(hasActiveDownloads ? "暂停所有等待中和下载中的任务" : "没有可暂停的任务")
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 12)
            Divider()

            if manager.states.isEmpty, manager.videoStates.isEmpty {
                ContentUnavailableView(
                    "暂无下载任务",
                    systemImage: "arrow.down.circle",
                    description: Text("下载歌曲或视频后，这里会显示媒体信息和实时进度。")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(orderedSongIDs, id: \.self) { songID in
                            if let state = manager.states[songID], let item = manager.items[songID] {
                                DownloadRow(
                                    item: item,
                                    state: state,
                                    retryAttempt: manager.retryAttempts[songID] ?? 0,
                                    maximumRetryCount: manager.maximumRetryCount,
                                    pause: { manager.pause(songID: songID) },
                                    cancel: { manager.cancel(songID: songID) },
                                    retry: { manager.retry(songID: songID) }
                                )
                                Divider().padding(.leading, 36)
                            }
                        }
                        ForEach(orderedVideoIDs, id: \.self) { id in
                            if let state = manager.videoStates[id], let item = manager.videoItems[id] {
                                DownloadRow(
                                    item: item,
                                    state: state,
                                    pause: { manager.pauseVideo(id: id) },
                                    cancel: { manager.cancelVideo(id: id) },
                                    retry: { manager.retryVideo(id: id) }
                                )
                                Divider().padding(.leading, 36)
                            }
                        }
                    }
                    .padding(.horizontal, 28)
                    .padding(.vertical, 8)
                }
            }
        }
        .navigationTitle("下载"))
    }

    private var orderedSongIDs: [Int64] {
        let knownIDs = Set(manager.itemOrder)
        return manager.itemOrder.reversed().filter { manager.states[$0] != nil }
            + manager.states.keys.filter { !knownIDs.contains($0) }.sorted(by: >)
    }

    private var orderedVideoIDs: [String] {
        let knownIDs = Set(manager.videoItemOrder)
        return manager.videoItemOrder.reversed().filter { manager.videoStates[$0] != nil }
            + manager.videoStates.keys.filter { !knownIDs.contains($0) }.sorted(by: >)
    }

    private var summaryText: String {
        let allStates = Array(manager.states.values) + manager.videoStates.values
        let completed = allStates.filter(\.isCompletedDownload).count
        let paused = allStates.reduce(into: 0) { count, state in
            if case .paused = state { count += 1 }
        }
        let running = allStates.reduce(into: 0) { count, state in
            if case .running = state { count += 1 }
        }
        let queued = allStates.filter { $0 == .queued }.count
        let active = running + queued
        var parts: [String] = []
        if running > 0 { parts.append("\(running)/\(active) 个下载中") }
        if queued > 0 { parts.append("\(queued) 个等待") }
        if paused > 0 { parts.append("\(paused) 个已暂停") }
        if completed > 0 { parts.append("\(completed) 个已完成") }
        return parts.isEmpty ? "下载任务与文件状态" : parts.joined(separator: " · ")
    }

    private var hasActiveDownloads: Bool {
        manager.runningDownloadCount > 0 || manager.queuedDownloadCount > 0
    }
}

private extension MusicDownloadState {
    var isCompletedDownload: Bool {
        if case .completed = self { true } else { false }
    }
}

private enum LibraryPhase: Equatable {
    case idle
    case loading
    case loggedOut
    case loaded
    case failed(String)
}

struct LibrarySnapshot {
    let user: MusicLibraryUser
    let songs: [Song]
    var playlists: [Playlist]
    let following: [MusicLibraryFollow]
    let recommendedUsers: [MusicRecommendedUser]
}

private struct LibraryRemoteImage: View {
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

private struct EmptyLibrarySection: View {
    let title: String
    let symbol: String

    var body: some View {
        Label(title, systemImage: symbol)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
    }
}

struct InlineRetry: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        HStack {
            Label(message, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.secondary)
            Spacer()
            Button("重试", action: retry)
        }
        .frame(minHeight: 44)
    }
}

private struct CommentRow: View {
    let comment: MusicComment
    let canOpenReplies: Bool
    let repliesExpanded: Bool
    let currentUserID: Int64?
    let isWriting: Bool
    let emojiPictureIDs: [String: String]
    var showsActions = true
    let onOpenUser: (Int64) -> Void
    let showReplies: () -> Void
    let reply: () -> Void
    let toggleLike: () -> Void
    let delete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Button(comment.nickname) { onOpenUser(comment.userID) }
                    .buttonStyle(.plain)
                    .font(.subheadline.weight(.semibold))
                    .disabled(comment.userID <= 0)
                    .help("打开 \(comment.nickname) 的用户主页")
                    .accessibilityLabel("打开 \(comment.nickname) 的用户主页")
                Spacer()
                Text(comment.timeText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            CommentEmojiText(content: comment.displayContent, remotePictureIDs: emojiPictureIDs)
            if showsActions {
                HStack(spacing: 12) {
                Button(action: toggleLike) {
                    HStack(spacing: 4) {
                        if isWriting {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: comment.isLiked ? "hand.thumbsup.fill" : "hand.thumbsup")
                        }
                        Text("\(comment.likedCount)")
                    }
                    .frame(minWidth: 38, minHeight: 22)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(comment.isLiked ? Color.red : Color.secondary)
                .disabled(currentUserID == nil || isWriting)
                .help(comment.isLiked ? "取消点赞" : "点赞")
                .accessibilityLabel(comment.isLiked ? "取消点赞" : "点赞")

                Button(action: reply) {
                    Image(systemName: "arrowshape.turn.up.left")
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .disabled(currentUserID == nil || isWriting)
                .help("回复")
                .accessibilityLabel("回复")

                if canOpenReplies && comment.replyCount > 0 {
                    Button(action: showReplies) {
                        Label(
                            repliesExpanded ? "收起回复" : "\(comment.replyCount) 条回复",
                            systemImage: repliesExpanded ? "chevron.up" : "bubble.left"
                        )
                    }
                    .buttonStyle(.borderless)
                    .help(repliesExpanded ? "收起回复" : "查看回复")
                    .accessibilityValue(Text(repliesExpanded ? "已展开" : "已折叠"))
                }

                if currentUserID == comment.userID {
                    Button(action: delete) {
                        Image(systemName: "trash")
                            .frame(width: 22, height: 22)
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.red)
                    .disabled(isWriting)
                    .help("删除评论")
                    .accessibilityLabel("删除评论")
                }
                }
            }
        }
        .padding(.vertical, 12)
    }
}

struct ReadOnlyCommentRow: View {
    let comment: MusicComment
    let emojiPictureIDs: [String: String]
    let onOpenUser: (Int64) -> Void

    var body: some View {
        CommentRow(
            comment: comment,
            canOpenReplies: false,
            repliesExpanded: false,
            currentUserID: nil,
            isWriting: false,
            emojiPictureIDs: emojiPictureIDs,
            showsActions: false,
            onOpenUser: onOpenUser,
            showReplies: {},
            reply: {},
            toggleLike: {},
            delete: {}
        )
    }
}

private struct CommentThreadRow: View {
    let comment: MusicComment
    let library: LiveMusicLibrary
    let currentUserID: Int64?
    let currentUserNickname: String
    let emojiPictureIDs: [String: String]
    let onOpenUser: (Int64) -> Void
    let onLogin: () -> Void
    let onCommentChanged: (MusicComment) -> Void
    let onCommentDeleted: (Int64) -> Void
    let onMainListRefresh: () -> Void
    let onWriteSucceeded: (String) -> Void

    @State private var isExpanded = false
    @State private var replies: [MusicComment] = []
    @State private var cursor = ""
    @State private var time: Int64 = -1
    @State private var hasMore = false
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var writeMessage: String?
    @State private var replyTarget: MusicComment?
    @State private var deleteTarget: MusicComment?
    @State private var floorGeneration = 0
    @State private var floorTask: Task<Void, Never>?
    @State private var writeTasks: [Int64: Task<Void, Never>] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CommentRow(
                comment: comment,
                canOpenReplies: true,
                repliesExpanded: isExpanded,
                currentUserID: currentUserID,
                isWriting: writeTasks[comment.id] != nil,
                emojiPictureIDs: emojiPictureIDs,
                onOpenUser: onOpenUser,
                showReplies: toggleReplies,
                reply: { openReply(comment) },
                toggleLike: { toggleLiked(comment) },
                delete: { deleteTarget = comment }
            )
            if isExpanded {
                repliesContent
                    .padding(.leading, 28)
            }
        }
        .sheet(item: $replyTarget) { target in
            CommentReplySheet(
                comment: target,
                emojiPictureIDs: emojiPictureIDs,
                currentCredentialRevision: { library.transport.credentialSnapshotValue().revision }
            ) { content, credentialRevision in
                let serverComment = try await library.replyToComment(
                    songID: comment.songID,
                    commentID: target.id,
                    content: content,
                    expectedCredentialRevision: credentialRevision
                )
                try Task.checkCancellation()
                guard library.transport.credentialSnapshotValue().revision == credentialRevision else {
                    throw CancellationError()
                }
                let reply = confirmedComment(
                    serverComment,
                    songID: comment.songID,
                    userID: currentUserID ?? 0,
                    nickname: currentUserNickname,
                    content: content,
                    replyToNickname: target.id == comment.id ? nil : target.nickname
                )
                insert(reply, after: target)
                isExpanded = true
                onCommentChanged(comment.addingReply())
                onWriteSucceeded("回复成功")
            }
        }
        .confirmationDialog(
            "删除这条评论？",
            isPresented: deletePresented,
            titleVisibility: .visible,
            presenting: deleteTarget
        ) { target in
            Button("删除", role: .destructive) { deleteComment(target) }
            Button("取消", role: .cancel) { deleteTarget = nil }
        }
        .alert("评论操作失败", isPresented: writeMessagePresented) {
            Button("好") { writeMessage = nil }
        } message: {
            Text(writeMessage ?? "")
        }
        .onDisappear {
            floorTask?.cancel()
            writeTasks.values.forEach { $0.cancel() }
        }
    }

    @ViewBuilder
    private var repliesContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            if isLoading && replies.isEmpty {
                ProgressView("正在加载回复…")
                    .frame(maxWidth: .infinity, minHeight: 52)
            } else if let errorMessage, replies.isEmpty {
                InlineRetry(message: errorMessage) { startFloorLoad(reset: true) }
            } else {
                if replies.isEmpty {
                    EmptyLibrarySection(title: "暂无回复", symbol: "bubble.left")
                } else {
                    ForEach(replies) { reply in
                        CommentRow(
                            comment: reply,
                            canOpenReplies: false,
                            repliesExpanded: false,
                            currentUserID: currentUserID,
                            isWriting: writeTasks[reply.id] != nil,
                            emojiPictureIDs: emojiPictureIDs,
                            onOpenUser: onOpenUser,
                            showReplies: {},
                            reply: { openReply(reply) },
                            toggleLike: { toggleLiked(reply) },
                            delete: { deleteTarget = reply }
                        )
                        Divider()
                    }
                }
                if let errorMessage {
                    InlineRetry(message: errorMessage) { startFloorLoad(reset: false) }
                } else if hasMore {
                    Button { startFloorLoad(reset: false) } label: {
                        HStack(spacing: 6) {
                            if isLoading { ProgressView().controlSize(.small) }
                            Text(isLoading ? "加载中" : "查看更多")
                        }
                    }
                    .buttonStyle(.borderless)
                    .disabled(isLoading)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                }
            }
        }
    }

    private func toggleReplies() {
        isExpanded.toggle()
        if isExpanded && replies.isEmpty && !isLoading {
            startFloorLoad(reset: true)
        } else if !isExpanded {
            floorTask?.cancel()
        }
    }

    private func openReply(_ target: MusicComment) {
        guard currentUserID != nil else {
            onLogin()
            return
        }
        replyTarget = target
    }

    private func insert(_ reply: MusicComment, after target: MusicComment) {
        replies.removeAll { $0.id == reply.id }
        if target.id == comment.id {
            replies.insert(reply, at: 0)
        } else if let index = replies.firstIndex(where: { $0.id == target.id }) {
            replies.insert(reply, at: index + 1)
        } else {
            replies.append(reply)
        }
    }

    private var deletePresented: Binding<Bool> {
        Binding(
            get: { deleteTarget != nil },
            set: { if !$0 { deleteTarget = nil } }
        )
    }

    private var writeMessagePresented: Binding<Bool> {
        Binding(
            get: { writeMessage != nil },
            set: { if !$0 { writeMessage = nil } }
        )
    }

    @MainActor
    private func toggleLiked(_ target: MusicComment) {
        guard currentUserID != nil, writeTasks[target.id] == nil else { return }
        let liked = !target.isLiked
        let credentialRevision = library.transport.credentialSnapshotValue().revision
        writeTasks[target.id] = Task { @MainActor in
            defer { writeTasks[target.id] = nil }
            do {
                try await library.setCommentLiked(
                    songID: comment.songID,
                    commentID: target.id,
                    liked: liked,
                    expectedCredentialRevision: credentialRevision
                )
                try Task.checkCancellation()
                guard library.transport.credentialSnapshotValue().revision == credentialRevision else {
                    throw CancellationError()
                }
                let updated = target.settingLiked(liked)
                if target.id == comment.id {
                    onCommentChanged(updated)
                } else {
                    replies = replies.map { $0.id == target.id ? updated : $0 }
                }
                onWriteSucceeded(liked ? "评论已点赞" : "已取消评论点赞")
            } catch is CancellationError {
            } catch {
                writeMessage = error.localizedDescription
            }
        }
    }

    @MainActor
    private func deleteComment(_ target: MusicComment) {
        guard currentUserID == target.userID, writeTasks[target.id] == nil else { return }
        deleteTarget = nil
        let credentialRevision = library.transport.credentialSnapshotValue().revision
        writeTasks[target.id] = Task { @MainActor in
            defer { writeTasks[target.id] = nil }
            do {
                try await library.deleteComment(
                    songID: comment.songID,
                    commentID: target.id,
                    expectedCredentialRevision: credentialRevision
                )
                try Task.checkCancellation()
                guard library.transport.credentialSnapshotValue().revision == credentialRevision else {
                    throw CancellationError()
                }
                onWriteSucceeded("评论已删除")
                if target.id == comment.id {
                    onCommentDeleted(target.id)
                } else {
                    replies.removeAll { $0.id == target.id }
                    startFloorLoad(reset: true)
                    onMainListRefresh()
                }
            } catch is CancellationError {
            } catch {
                writeMessage = error.localizedDescription
            }
        }
    }

    @MainActor
    private func startFloorLoad(reset: Bool) {
        guard reset || floorTask == nil else { return }
        if reset {
            floorGeneration += 1
            floorTask?.cancel()
        }
        let generation = floorGeneration
        floorTask = Task { @MainActor in
            await load(reset: reset, generation: generation)
        }
    }

    @MainActor
    private func load(reset: Bool, generation: Int) async {
        isLoading = true
        errorMessage = nil
        do {
            let page = try await library.commentFloor(
                songID: comment.songID,
                parentCommentID: comment.id,
                time: reset ? -1 : time,
                cursor: reset ? "" : cursor,
                limit: 10
            )
            try Task.checkCancellation()
            guard generation == floorGeneration else { return }
            if reset {
                replies = page.comments
            } else {
                let existing = Set(replies.map(\.id))
                replies += page.comments.filter { !existing.contains($0.id) }
            }
            cursor = page.cursor
            time = page.time
            hasMore = page.hasMore
            isLoading = false
            floorTask = nil
        } catch is CancellationError {
            guard generation == floorGeneration else { return }
            isLoading = false
            floorTask = nil
        } catch {
            guard generation == floorGeneration else { return }
            errorMessage = error.localizedDescription
            isLoading = false
            floorTask = nil
        }
    }
}

private struct CommentReplySheet: View {
    let comment: MusicComment
    let emojiPictureIDs: [String: String]
    let currentCredentialRevision: () -> UInt64
    let submit: (String, UInt64) async throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var content = ""
    @State private var isSubmitting = false
    @State private var errorMessage: String?
    @State private var task: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("回复 \(comment.nickname)")
                .font(.headline)
            CommentEmojiText(content: comment.displayContent, remotePictureIDs: emojiPictureIDs)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
            TextEditor(text: $content)
                .font(.body)
                .frame(minHeight: 96)
                .padding(4)
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color(nsColor: .separatorColor))
                }
            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .disabled(isSubmitting)
                Button("回复", action: submitReply)
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmedContent.isEmpty || isSubmitting)
            }
        }
        .padding(20)
        .frame(width: 420, height: 320)
        .interactiveDismissDisabled(isSubmitting)
        .onDisappear { task?.cancel() }
    }

    private var trimmedContent: String {
        content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func submitReply() {
        let value = trimmedContent
        guard !value.isEmpty, !isSubmitting else { return }
        let credentialRevision = currentCredentialRevision()
        isSubmitting = true
        errorMessage = nil
        task = Task { @MainActor in
            defer {
                isSubmitting = false
                task = nil
            }
            do {
                try await submit(value, credentialRevision)
                dismiss()
            } catch is CancellationError {
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

private struct DownloadRow: View {
    let title: String
    let subtitle: String
    let metadata: String
    let state: MusicDownloadState
    let retryAttempt: Int
    let maximumRetryCount: Int
    let pause: () -> Void
    let cancel: () -> Void
    let retry: () -> Void

    init(
        item: MusicDownloadItem,
        state: MusicDownloadState,
        retryAttempt: Int,
        maximumRetryCount: Int,
        pause: @escaping () -> Void,
        cancel: @escaping () -> Void,
        retry: @escaping () -> Void
    ) {
        title = item.title
        subtitle = item.artist.isEmpty ? "未知歌手" : item.artist
        let size = item.expectedBytes.map {
            ByteCountFormatter.string(fromByteCount: $0, countStyle: .file)
        }
        metadata = [item.quality, size].compactMap { $0 }.joined(separator: " · ")
        self.state = state
        self.retryAttempt = retryAttempt
        self.maximumRetryCount = maximumRetryCount
        self.pause = pause
        self.cancel = cancel
        self.retry = retry
    }

    init(
        item: VideoDownloadItem,
        state: MusicDownloadState,
        pause: @escaping () -> Void,
        cancel: @escaping () -> Void,
        retry: @escaping () -> Void
    ) {
        title = item.title
        subtitle = item.creator.isEmpty ? "视频" : item.creator
        metadata = "视频 · \(item.quality)"
        self.state = state
        retryAttempt = 0
        maximumRetryCount = 0
        self.pause = pause
        self.cancel = cancel
        self.retry = retry
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .foregroundStyle(stateColor)
                .frame(width: 24)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(metadata)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                stateDetail
            }

            Spacer(minLength: 12)
            stateAction
        }
        .padding(.vertical, 8)
        .frame(minHeight: 64)
        .accessibilityElement(children: .contain)
    }

    private var symbol: String {
        switch state {
        case .queued: "clock"
        case .running: "arrow.down.circle"
        case .paused: "pause.circle"
        case .completed: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle"
        case .cancelled: "xmark.circle"
        }
    }

    private var stateColor: Color {
        switch state {
        case .failed: .red
        case .completed: .green
        case .running: .accentColor
        case .queued, .paused, .cancelled: .secondary
        }
    }

    @ViewBuilder
    private var stateDetail: some View {
        switch state {
        case .queued, .cancelled:
            Text(state == .queued ? "等待下载" : "已取消")
                .font(.caption)
                .foregroundStyle(.secondary)
        case let .running(progress):
            if retryAttempt > 0 {
                Text("重试 \(retryAttempt)/\(maximumRetryCount) · 正在从断点继续")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if let progress {
                HStack(spacing: 8) {
                    ProgressView(value: progress)
                        .frame(maxWidth: 240)
                    Text("\(Int(progress * 100))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 38, alignment: .trailing)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("下载进度 \(Int(progress * 100))%")
            } else {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("正在下载")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        case let .paused(progress):
            Text("已暂停")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let progress {
                HStack(spacing: 8) {
                    ProgressView(value: progress)
                        .frame(maxWidth: 240)
                    Text("\(Int(progress * 100))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 38, alignment: .trailing)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("下载已暂停，进度 \(Int(progress * 100))%")
            }
        case let .completed(audioURL, lyricURL):
            Text(lyricURL == nil ? audioURL.lastPathComponent : "\(audioURL.lastPathComponent) · 含歌词")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        case let .failed(message):
            Text("下载失败：\(message)")
                .font(.caption)
                .foregroundStyle(.red)
                .lineLimit(1)
        }
    }

    @ViewBuilder
    private var stateAction: some View {
        switch state {
        case .queued, .running:
            HStack(spacing: 0) {
                Button(action: pause) {
                    Image(systemName: "pause.fill")
                }
                .buttonStyle(.borderless)
                .help("暂停下载")
                .accessibilityLabel("暂停 \(title) 的下载")
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())

                Button(action: cancel) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .help("取消下载")
                .accessibilityLabel("取消 \(title) 的下载")
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
            }
        case .paused:
            HStack(spacing: 0) {
                Button(action: retry) {
                    Image(systemName: "play.fill")
                }
                .buttonStyle(.borderless)
                .help("继续下载")
                .accessibilityLabel("继续 \(title) 的下载")
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())

                Button(action: cancel) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .help("取消下载")
                .accessibilityLabel("取消 \(title) 的下载")
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
            }
        case let .completed(audioURL, _):
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([audioURL])
            } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(.borderless)
            .help("在 Finder 中显示")
            .accessibilityLabel("在 Finder 中显示 \(title)")
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
        case .failed, .cancelled:
            Button(action: retry) {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("重新下载")
            .accessibilityLabel("重新下载 \(title)")
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
        }
    }
}
