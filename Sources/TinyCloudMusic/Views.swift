import AppKit
import SwiftUI
import UniformTypeIdentifiers

extension Accent {
    var color: Color {
        switch self {
        case .red: .red
        case .orange: .orange
        case .green: .green
        case .cyan: .cyan
        case .blue: .blue
        case .pink: .pink
        }
    }
}

extension Appearance {
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

struct SongTitleText: View {
    let song: Song
    var primaryColor = Color(nsColor: .labelColor)

    var body: Text {
        var title = AttributedString(song.primaryName)
        title.foregroundColor = primaryColor
        guard !song.titleMetadata.isEmpty else { return Text(title) }

        var metadata = AttributedString(" \(song.titleMetadata)")
        metadata.foregroundColor = Color(nsColor: .tertiaryLabelColor)
        title.append(metadata)
        return Text(title)
    }
}

struct SongMetadataLink: View {
    let title: String
    let help: String
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .foregroundStyle(isHovered ? Color.red : Color.secondary)
                .underline(isHovered, color: .red)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(help)
        .accessibilityAddTraits(.isLink)
        .accessibilityHint(help)
    }
}

struct SongArtistLinks: View {
    let artists: [ArtistSummary]
    let action: (ArtistSummary) -> Void

    @ViewBuilder
    var body: some View {
        if !artists.isEmpty {
            ViewThatFits(in: .horizontal) {
                SongArtistLinkRow(artists: artists, isTruncated: false, action: action)
                if artists.count > 1 {
                    ForEach(Array(stride(from: artists.count - 1, through: 1, by: -1)), id: \.self) { count in
                        SongArtistLinkRow(
                            artists: Array(artists.prefix(count)),
                            isTruncated: true,
                            action: action
                        )
                    }
                }
                Text("...")
                    .foregroundStyle(.secondary)
            }
            .help(artists.map(\.name).joined(separator: " / "))
        }
    }
}

struct SongMetadataLinks: View {
    let song: Song
    let onOpenRoute: (Route) -> Void

    var body: some View {
        HStack(spacing: 4) {
            SongArtistLinks(artists: song.artists) { artist in
                onOpenRoute(.artist(artist.id))
            }
            Text("·")
                .foregroundStyle(.tertiary)
            SongMetadataLink(title: song.album.name, help: "打开专辑 \(song.album.name)") {
                onOpenRoute(.album(song.album.id))
            }
        }
        .font(.caption)
        .lineLimit(1)
    }
}

private struct SongArtistLinkRow: View {
    let artists: [ArtistSummary]
    let isTruncated: Bool
    let action: (ArtistSummary) -> Void

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(artists.enumerated()), id: \.offset) { index, artist in
                if index > 0 {
                    Text(" / ")
                        .foregroundStyle(.tertiary)
                }
                SongMetadataLink(title: artist.name, help: "打开歌手 \(artist.name)") {
                    action(artist)
                }
            }
            if isTruncated {
                Text(" / ...")
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }
}

private struct SessionChangeIdentity: Equatable {
    let state: SessionState
    let credentialRevision: Int
}

struct RootView: View {
    @Bindable var model: AppModel
    @Bindable var player: PlayerController
    let openNowPlaying: () -> Void
    @State private var isStarting = true

    // ponytail: type erasure bounds clean-build module emission; remove only if render profiling warrants it.
    var body: AnyView { AnyView(content) }

    private var content: AnyView {
        AnyView(VStack(spacing: 0) {
            NavigationSplitView {
                SidebarView(model: model)
            } detail: {
                NavigationStack(path: $model.path) {
                    PrimaryContentView(model: model, player: player)
                        .navigationDestination(for: Route.self) { route in
                            RouteDestinationView(route: route, model: model, player: player)
                        }
                }
            }
            Divider()
            PlayerBar(model: model, player: player, openNowPlaying: openNowPlaying)
                .frame(height: 92)
        }
        .tint(.red)
        .preferredColorScheme(model.settings.appearance.colorScheme)
        .task {
            if let session = model.session {
                await session.restore()
                await model.refreshAccountState()
            }
            if model.homeSlots.allSatisfy({ $0.load == .idle }) {
                model.loadHome()
            }
            isStarting = false
        }
        .onChange(of: sessionChangeIdentity) { _, identity in
            guard !isStarting else { return }
            Task {
                await model.refreshAccountState()
                guard sessionChangeIdentity == identity else { return }
                model.loadHome()
            }
        }
        .onChange(of: listenTogetherPhase) { _, phase in
            guard let phase, case .recoveryAvailable = phase else { return }
            model.isListenTogetherPresented = true
        }
        .onChange(of: model.settings.playbackQuality) { _, quality in
            player.configure(playbackQuality: quality, cacheRoot: model.cacheFolderURL)
        }
        .onChange(of: model.settings.cacheBookmark) { _, _ in
            player.configure(playbackQuality: model.settings.playbackQuality, cacheRoot: model.cacheFolderURL)
            ArtworkPipeline.shared.configure(cacheRoot: model.cacheFolderURL)
        }
        .onChange(of: model.settings.crossfadeDuration) { _, duration in
            player.setCrossfadeDuration(duration)
        }
        .onChange(of: player.playbackReportErrorMessage) { _, message in
            guard let message else { return }
            NSAccessibility.post(
                element: NSApplication.shared,
                notification: .announcementRequested,
                userInfo: [
                    .announcement: message,
                    .priority: NSAccessibilityPriorityLevel.high.rawValue
                ]
            )
        }
        .overlay(alignment: .top) {
            InteractionToast(message: model.interactionMessage)
                .padding(.top, 12)
        }
        .sheet(item: $model.playlistPickerSong) { song in
            if let userID = model.currentUserID,
               let extras = model.extras,
               let library = model.library {
                AddSongToPlaylistView(
                    song: song,
                    userID: userID,
                    extras: extras,
                    library: library,
                    onFinished: { playlistID, isFavoritePlaylist in
                        model.songPlaylistMembershipDidChange(
                            song.id,
                            playlistID: playlistID,
                            isFavoritePlaylist: isFavoritePlaylist,
                            containsSong: true
                        )
                        model.playlistPickerSong = nil
                        model.showToast("已加入歌单")
                    }
                )
            } else {
                ContentUnavailableView(
                    "需要登录",
                    systemImage: "person.crop.circle.badge.exclamationmark"
                )
                .frame(width: 420, height: 240)
            }
        }
        .sheet(isPresented: $model.isListenTogetherPresented) {
            if let controller = model.listenTogether {
                ListenTogetherView(controller: controller, player: player)
            } else {
                ContentUnavailableView(
                    "一起听不可用",
                    systemImage: "person.2.slash"
                )
                .frame(width: 420, height: 240)
            }
        }
        .alert("操作失败", isPresented: libraryMessagePresented) {
            Button("好") { model.libraryMessage = nil }
        } message: {
            Text(model.libraryMessage ?? "")
        })
    }

    private var sessionChangeIdentity: SessionChangeIdentity? {
        model.session.map {
            SessionChangeIdentity(state: $0.state, credentialRevision: $0.credentialRevision)
        }
    }

    private var listenTogetherPhase: ListenTogetherPhase? {
        model.listenTogether?.phase
    }

    private var libraryMessagePresented: Binding<Bool> {
        Binding(
            get: { model.libraryMessage != nil },
            set: { if !$0 { model.libraryMessage = nil } }
        )
    }
}

private struct PrimaryContentView: View {
    @Bindable var model: AppModel
    @Bindable var player: PlayerController

    @ViewBuilder
    var body: some View {
        switch model.sidebar {
        case .home:
            HomeView(model: model, player: player)
        case .search:
            SearchView(model: model, player: player)
        case .videos:
            if let library = model.videoLibrary {
                VideoRecommendationsView(
                    library: library,
                    currentUserID: model.currentUserID,
                    subscriptionOverrides: model.videoSubscriptionOverrides,
                    subscriptionRevision: model.videoSubscriptionRevision,
                    onOpenRoute: model.open,
                    onLogin: { model.selectSidebar(.session) },
                    onSubscriptionsLoaded: model.recordVideoSubscriptions
                )
            } else {
                ContentUnavailableView("视频不可用", systemImage: "play.rectangle")
            }
        case .audio:
            if let library = model.audioLibrary {
                AudioContentView(library: library, model: model, player: player)
            } else {
                ContentUnavailableView("播客与广播不可用", systemImage: "radio")
            }
        case .personalFM:
            if let userID = model.currentUserID, let personalFM = model.personalFM {
                PersonalFMView(controller: personalFM, userID: userID)
            } else {
                ContentUnavailableView(
                    "需要登录",
                    systemImage: "person.crop.circle.badge.exclamationmark",
                    description: Text("扫码登录后收听私人 FM。")
                )
            }
        case .library:
            if let library = model.library, let extras = model.extras {
                MusicLibraryView(
                    model: model,
                    library: library,
                    extras: extras,
                    player: player,
                    onOpenRoute: { model.open($0) }
                )
            } else {
                ContentUnavailableView("音乐库不可用", systemImage: "music.note.list")
            }
        case .history:
            if let library = model.library {
                ListeningHistoryView(model: model, library: library, player: player)
            } else {
                ContentUnavailableView("播放历史不可用", systemImage: "clock.arrow.circlepath")
            }
        case .downloads:
            if let downloads = model.downloads {
                DownloadsView(manager: downloads)
            } else {
                ContentUnavailableView("下载不可用", systemImage: "arrow.down.circle")
            }
        case .session:
            if let session = model.session {
                SessionView(controller: session, showSuccess: model.showToast)
            } else {
                ContentUnavailableView("会话设置不可用", systemImage: "person.crop.circle")
            }
        }
    }
}

private struct RouteDestinationView: View {
    let route: Route
    @Bindable var model: AppModel
    @Bindable var player: PlayerController

    @ViewBuilder
    var body: some View {
        switch route {
        case .home:
            HomeView(model: model, player: player)
        case .search:
            SearchView(model: model, player: player)
        case .cloudMusic:
            if let library = model.library {
                CloudMusicView(model: model, library: library)
            } else {
                ContentUnavailableView("音乐云盘不可用", systemImage: "externaldrive")
            }
        case .artist, .album, .playlist, .user:
            DetailView(route: route, model: model, player: player)
        case let .comments(songID):
            if let library = model.library {
                CommentsView(
                    songID: songID,
                    library: library,
                    currentUserID: model.currentUserID,
                    currentUserNickname: model.librarySnapshot?.user.nickname ?? "我",
                    onOpenUser: { model.open(.user($0)) },
                    onLogin: { model.selectSidebar(.session) }
                )
            } else {
                ContentUnavailableView("评论不可用", systemImage: "bubble.left")
            }
        case let .similarSongs(song):
            if let library = model.library {
                SimilarSongsView(sourceSong: song, model: model, library: library, player: player)
            } else {
                ContentUnavailableView("相似歌曲不可用", systemImage: "music.note")
            }
        case .recommendationHistory:
            if model.currentUserID != nil, let library = model.library {
                RecommendationHistoryView(
                    model: model,
                    library: library,
                    player: player
                )
            } else {
                ContentUnavailableView(
                    "需要登录",
                    systemImage: "person.crop.circle.badge.exclamationmark"
                )
            }
        case .listeningFootprints:
            if model.currentUserID != nil, let library = model.library {
                ListeningFootprintsView(model: model, library: library, player: player)
            } else {
                ContentUnavailableView(
                    "需要登录",
                    systemImage: "person.crop.circle.badge.exclamationmark"
                )
            }
        case let .mv(id):
            if let library = model.videoLibrary, let downloads = model.downloads {
                VideoDetailView(
                    resource: .mv(id),
                    library: library,
                    knowledgeLibrary: model.knowledgeLibrary,
                    songPlayer: player,
                    currentUserID: model.currentUserID,
                    downloadManager: downloads,
                    downloadDirectory: model.videoDownloadFolderURL,
                    playbackQuality: model.settings.videoPlaybackQuality,
                    downloadQuality: model.settings.videoDownloadQuality,
                    subscriptionOverride: model.videoSubscriptionOverrides[.mv(id)],
                    onOpenUser: { model.open(.user($0)) },
                    onOpenRelated: { model.replaceCurrentRoute(with: $0) },
                    onLogin: { model.selectSidebar(.session) },
                    onDownloadQueued: { model.showToast("视频已加入下载队列") },
                    onSubscriptionChanged: model.videoSubscriptionDidChange
                )
            } else {
                ContentUnavailableView("MV 不可用", systemImage: "play.rectangle")
            }
        case let .video(id):
            if let library = model.videoLibrary, let downloads = model.downloads {
                VideoDetailView(
                    resource: .video(id),
                    library: library,
                    knowledgeLibrary: model.knowledgeLibrary,
                    songPlayer: player,
                    currentUserID: model.currentUserID,
                    downloadManager: downloads,
                    downloadDirectory: model.videoDownloadFolderURL,
                    playbackQuality: model.settings.videoPlaybackQuality,
                    downloadQuality: model.settings.videoDownloadQuality,
                    subscriptionOverride: model.videoSubscriptionOverrides[.video(id)],
                    onOpenUser: { model.open(.user($0)) },
                    onOpenRelated: { model.replaceCurrentRoute(with: $0) },
                    onLogin: { model.selectSidebar(.session) },
                    onDownloadQueued: { model.showToast("视频已加入下载队列") },
                    onSubscriptionChanged: model.videoSubscriptionDidChange
                )
            } else {
                ContentUnavailableView("视频不可用", systemImage: "play.rectangle")
            }
        case let .podcast(id):
            if let library = model.audioLibrary {
                PodcastDetailView(podcastID: id, library: library, model: model, player: player)
            } else {
                ContentUnavailableView("播客不可用", systemImage: "dot.radiowaves.left.and.right")
            }
        case let .podcastEpisode(id):
            if let library = model.audioLibrary {
                PodcastEpisodeDetailView(episodeID: id, library: library, model: model, player: player)
            } else {
                ContentUnavailableView("节目不可用", systemImage: "waveform")
            }
        case let .broadcast(id, coverURL):
            if let library = model.audioLibrary {
                BroadcastChannelDetailView(
                    channelID: id,
                    coverURL: coverURL,
                    library: library,
                    model: model,
                    songPlayer: player
                )
            } else {
                ContentUnavailableView("广播不可用", systemImage: "radio")
            }
        case .podcastSubscriptions:
            if let library = model.audioLibrary {
                PodcastSubscriptionsView(library: library, model: model)
            } else {
                ContentUnavailableView("播客订阅不可用", systemImage: "star")
            }
        case .musicStyles:
            if let library = model.knowledgeLibrary {
                MusicStylesView(
                    library: library,
                    accountID: model.currentUserID,
                    onOpenRoute: model.open
                )
            } else {
                ContentUnavailableView("曲风不可用", systemImage: "guitars")
            }
        case let .musicStyle(id, name):
            if let library = model.knowledgeLibrary {
                MusicStyleDetailView(
                    styleID: id,
                    styleName: name,
                    library: library,
                    player: player,
                    onOpenRoute: model.open
                )
            } else {
                ContentUnavailableView("曲风不可用", systemImage: "guitars")
            }
        }
    }
}

private struct SidebarView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "music.note")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(.red, in: RoundedRectangle(cornerRadius: 7))
                VStack(alignment: .leading, spacing: 1) {
                    Text("小云音乐")
                        .font(.headline)
                    Text("Tiny Cloud Music")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(14)

            List(selection: sidebarSelection) {
                Label("发现", systemImage: "sparkles")
                    .tag(SidebarItem.home)
                Label("搜索", systemImage: "magnifyingglass")
                    .tag(SidebarItem.search)
                Label("MV 与视频", systemImage: "play.rectangle")
                    .tag(SidebarItem.videos)
                Label("播客与广播", systemImage: "radio")
                    .tag(SidebarItem.audio)
                Label("私人 FM", systemImage: "radio")
                    .tag(SidebarItem.personalFM)
                Section("资料库") {
                    Label("我的音乐", systemImage: "music.note.list")
                        .tag(SidebarItem.library)
                    Label("最近播放", systemImage: "clock.arrow.circlepath")
                        .tag(SidebarItem.history)
                    Label("下载", systemImage: "arrow.down.circle")
                        .tag(SidebarItem.downloads)
                }
                Section("应用") {
                    Label("登录与会话", systemImage: "person.crop.circle")
                        .tag(SidebarItem.session)
                }
            }
            .listStyle(.sidebar)
        }
        .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 250)
    }

    private var sidebarSelection: Binding<SidebarItem?> {
        Binding(
            get: { model.sidebar },
            set: { if let item = $0 { model.selectSidebar(item) } }
        )
    }
}

private struct HomeView: View {
    @Bindable var model: AppModel
    @Bindable var player: PlayerController

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 34) {
                HStack(spacing: 12) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 38, height: 38)
                        .background(.red, in: Circle())
                        .shadow(color: .red.opacity(0.22), radius: 10, y: 4)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("发现音乐")
                            .font(.system(size: 28, weight: .bold))
                        Text("为今天挑一些合适的声音")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { model.open(.musicStyles) } label: {
                        Label("曲风", systemImage: "guitars")
                    }
                    .buttonStyle(.bordered)
                }

                ForEach(model.homeSlots) { slot in
                    HomeSectionView(slot: slot, model: model, player: player)
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 24)
        }
        .navigationTitle("发现")
        .toolbar {
            ToolbarItem {
                Button {
                    model.loadHome()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("刷新首页")
                .accessibilityLabel("刷新首页")
            }
        }
    }
}

private struct HomeSectionView: View {
    let slot: HomeSlot
    @Bindable var model: AppModel
    @Bindable var player: PlayerController

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch slot.load {
            case .idle, .loading:
                HomeSectionTitle(title: slot.title)
                HStack(spacing: 14) {
                    ForEach(0..<5, id: \.self) { _ in
                        VStack(alignment: .leading, spacing: 8) {
                            RoundedRectangle(cornerRadius: 6)
                                .fill(.quaternary)
                                .frame(width: 142, height: 142)
                            RoundedRectangle(cornerRadius: 2)
                                .fill(.quaternary)
                                .frame(height: 12)
                            RoundedRectangle(cornerRadius: 2)
                                .fill(.quaternary)
                                .frame(width: 92, height: 10)
                        }
                        .frame(width: 154, height: 194, alignment: .topLeading)
                    }
                }
                .redacted(reason: .placeholder)
            case let .failed(message):
                HStack {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                    Button("重试") { model.retryHomeSection(id: slot.id) }
                }
                .frame(maxWidth: .infinity, minHeight: 90, alignment: .leading)
            case let .loaded(section):
                HomeSectionTitle(title: section.title, subtitle: section.subtitle)

                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 14) {
                        let visibleSongs = section.items.compactMap(\.song)
                        ForEach(section.items) { item in
                            Button {
                                if let song = item.song {
                                    player.play(song, in: visibleSongs)
                                } else if let route = item.route {
                                    model.open(route)
                                }
                            } label: {
                                HomeItemView(item: item)
                            }
                            .buttonStyle(HomeCardButtonStyle())
                            .accessibilityLabel(item.title)
                            .accessibilityHint(item.song == nil ? "打开详情" : "播放")
                            .contextMenu {
                                if let song = item.song {
                                    SongContextMenu(song: song, songs: visibleSongs, model: model, player: player)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 8)
                }
            }
        }
    }
}

private struct HomeSectionTitle: View {
    let title: String
    var subtitle: String?

    var body: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 2)
                .fill(.red)
                .frame(width: 3, height: subtitle == nil ? 18 : 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.title3.weight(.semibold))
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct HomeItemView: View {
    let item: HomeItem
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ArtworkView(artwork: item.artwork)
                .frame(width: 142, height: 142)
                .clipShape(RoundedRectangle(cornerRadius: 7))
                .overlay {
                    RoundedRectangle(cornerRadius: 7)
                        .stroke(.white.opacity(isHovered ? 0.28 : 0.12), lineWidth: 1)
                }
                .scaleEffect(isHovered && !reduceMotion ? 1.015 : 1)
                .shadow(
                    color: .black.opacity(isHovered ? 0.2 : 0.07),
                    radius: isHovered ? 14 : 4,
                    y: isHovered ? 8 : 2
                )
                .overlay(alignment: .bottomTrailing) {
                    if item.song != nil {
                        Image(systemName: "play.fill")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.white)
                            .frame(width: 32, height: 32)
                            .background(.red, in: Circle())
                            .shadow(color: .black.opacity(0.2), radius: 6, y: 3)
                            .scaleEffect(isHovered && !reduceMotion ? 1.06 : 1)
                            .padding(8)
                    }
                }
            Group {
                if let song = item.song {
                    SongTitleText(song: song)
                } else {
                    Text(item.title)
                }
            }
            .font(.subheadline.weight(.medium))
            .lineLimit(1)
            Text(item.subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(width: 154, height: 194, alignment: .topLeading)
        .offset(y: isHovered && !reduceMotion ? -4 : 0)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: isHovered)
    }
}

private struct HomeCardButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.975 : 1)
            .offset(y: configuration.isPressed && !reduceMotion ? 2 : 0)
            .brightness(configuration.isPressed ? -0.025 : 0)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

private struct SearchView: View {
    @Bindable var model: AppModel
    @Bindable var player: PlayerController
    @State private var isSearchPresented = false

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading) {
                Picker("搜索范围", selection: scopeBinding) {
                    ForEach(SearchScope.allCases, id: \.self) { scope in
                        Label(scope.rawValue, systemImage: scope.symbol)
                            .tag(scope)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 720)
            }
            .padding(.horizontal, 28)
            .padding(.top, 22)
            .padding(.bottom, 16)

            Divider()
            searchContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("搜索")
        .searchable(
            text: queryBinding,
            isPresented: $isSearchPresented,
            placement: .toolbar,
            prompt: "搜索歌曲、歌手、专辑、歌单、用户、MV 或视频"
        )
        .searchSuggestions {
            if !model.searchHints.isEmpty {
                Section(searchSuggestionTitle) {
                    ForEach(Array(model.searchHints.enumerated()), id: \.element) { index, hint in
                        Button {
                            model.selectSearchHint(hint)
                            isSearchPresented = false
                        } label: {
                            Label(hint, systemImage: searchSuggestionSymbol)
                                .lineLimit(1)
                        }
                        .keyboardShortcut(index == 0 && model.path.isEmpty ? .defaultAction : nil)
                    }
                }
            }
        }
        .onSubmit(of: .search) {
            model.search(offset: 0)
            isSearchPresented = false
        }
        .task {
            model.loadSearchHints()
        }
    }

    private var searchSuggestionTitle: String {
        model.searchState.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "推荐搜索"
            : "搜索建议"
    }

    private var searchSuggestionSymbol: String {
        model.searchState.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "sparkles"
            : "magnifyingglass"
    }

    @ViewBuilder
    private var searchContent: some View {
        if model.searchState.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            hotSearchContent
        } else {
            switch model.searchLoad {
            case .idle:
                if model.searchDirectMatches.isEmpty {
                    ContentUnavailableView(
                        "搜索音乐",
                        systemImage: "music.note.list",
                        description: Text("输入关键词并选择内容类型")
                    )
                } else {
                    searchResults(SearchPage(items: [], offset: 0, hasMore: false))
                }
            case .loading:
                VStack(spacing: 12) {
                    ProgressView()
                    Text("正在搜索…")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case let .failed(message):
                ContentUnavailableView {
                    Label("搜索失败", systemImage: "wifi.exclamationmark")
                } description: {
                    Text(message)
                } actions: {
                    Button("重试") { model.search() }
                }
            case let .loaded(page):
                if page.items.isEmpty && model.searchDirectMatches.isEmpty {
                    ContentUnavailableView(
                        "没有找到结果",
                        systemImage: "magnifyingglass",
                        description: Text("换一个关键词试试")
                    )
                } else {
                    searchResults(page)
                }
            }
        }
    }

    @ViewBuilder
    private var hotSearchContent: some View {
        if model.hotSearchItems.isEmpty && !model.isHotSearchLoading {
            ContentUnavailableView(
                "搜索音乐",
                systemImage: "music.note.list",
                description: Text("输入关键词并选择内容类型")
            )
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    HStack {
                        Text("热搜")
                            .font(.headline)
                        Spacer()
                        if model.isHotSearchLoading {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)

                    ForEach(Array(model.hotSearchItems.enumerated()), id: \.element.id) { index, item in
                        Button {
                            model.selectSearchHint(item.keyword)
                            isSearchPresented = false
                        } label: {
                            HStack(spacing: 12) {
                                Text("\(index + 1)")
                                    .font(.callout.monospacedDigit().weight(index < 3 ? .semibold : .regular))
                                    .foregroundStyle(index < 3 ? .red : .secondary)
                                    .frame(width: 28, alignment: .trailing)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(item.keyword)
                                        .font(.body.weight(.medium))
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                    if !item.detail.isEmpty {
                                        Text(item.detail)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                HStack(spacing: 6) {
                                    if let iconURL = item.iconURL {
                                        CachedAsyncImage(url: iconURL) { phase in
                                            switch phase {
                                            case let .success(image):
                                                image
                                                    .resizable()
                                                    .interpolation(.high)
                                                    .scaledToFit()
                                            case .empty, .failure:
                                                Color.clear
                                            @unknown default:
                                                Color.clear
                                            }
                                        }
                                        .frame(width: 14, height: 14)
                                        .accessibilityHidden(true)
                                    }
                                    if item.score > 0 {
                                        Text(item.score.formatted())
                                            .font(.caption2.monospacedDigit())
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .frame(width: 80, alignment: .trailing)
                            }
                            .frame(maxWidth: .infinity, minHeight: 52)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(hotSearchAccessibilityLabel(item, rank: index + 1))
                        Divider().padding(.leading, 52)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
            }
        }
    }

    private func searchResults(_ page: SearchPage) -> some View {
        let visibleSongs = page.items.compactMap { item -> Song? in
            guard case let .song(song) = item else { return nil }
            return song
        }
        let directSongs = model.searchDirectMatches.compactMap { match -> Song? in
            guard case let .song(song) = match.item else { return nil }
            return song
        }
        return ScrollView {
            LazyVStack(spacing: 0) {
                if !model.searchDirectMatches.isEmpty {
                    HStack {
                        Text("最佳匹配")
                            .font(.headline)
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    ForEach(model.searchDirectMatches) { match in
                        searchResultRow(match.item, songs: directSongs)
                        Divider().padding(.leading, 76)
                    }
                }
                ForEach(page.items) { item in
                    searchResultRow(item, songs: visibleSongs)
                    Divider().padding(.leading, 76)
                }
                if let message = model.searchLoadMoreError {
                    InlineRetry(message: message) { model.loadMoreSearchResults() }
                } else if page.hasMore {
                    LoadMoreTrigger { model.loadMoreSearchResults() }
                        .id(page.offset)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
        }
    }

    private func searchResultRow(_ item: SearchItem, songs: [Song]) -> some View {
        SearchResultRow(item: item, onOpenRoute: { model.open($0) }) {
            if case let .song(song) = item {
                player.play(song, in: songs)
            } else if let route = item.route {
                model.searchState.selectedID = item.numericID
                model.open(route)
            }
        }
        .contextMenu {
            if case let .song(song) = item {
                SongContextMenu(song: song, songs: songs, model: model, player: player)
            }
        }
    }

    private func hotSearchAccessibilityLabel(_ item: HotSearchItem, rank: Int) -> String {
        ["第 \(rank) 名", item.keyword, item.detail, item.score > 0 ? "热度 \(item.score)" : ""]
            .filter { !$0.isEmpty }
            .joined(separator: "，")
    }

    private var queryBinding: Binding<String> {
        Binding(get: { model.searchState.query }, set: {
            guard isSearchPresented || !$0.isEmpty else { return }
            model.updateSearchQuery($0)
        })
    }

    private var scopeBinding: Binding<SearchScope> {
        Binding(get: { model.searchState.scope }, set: { model.setSearchScope($0) })
    }
}

struct SearchResultRow: View {
    let item: SearchItem
    let onOpenRoute: (Route) -> Void
    let action: () -> Void

    @ViewBuilder
    var body: some View {
        if case let .song(song) = item {
            HStack(spacing: 14) {
                ArtworkView(artwork: item.artwork)
                    .frame(width: 52, height: 52)
                Button(action: action) {
                    Image(systemName: "play.fill")
                        .foregroundStyle(.red)
                        .frame(width: 24)
                }
                .buttonStyle(.plain)
                .frame(width: 44, height: 44)
                .help("播放 \(song.name)")
                .accessibilityLabel("播放 \(song.name)")
                VStack(alignment: .leading, spacing: 4) {
                    SongTitleText(song: song)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                    SongArtistLinks(artists: song.artists) { artist in
                        onOpenRoute(.artist(artist.id))
                    }
                    .font(.subheadline)
                    .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                SongMetadataLink(title: song.album.name, help: "打开专辑 \(song.album.name)") {
                    onOpenRoute(.album(song.album.id))
                }
                .font(.subheadline)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: 180, alignment: .leading)
                Text(song.durationText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 42, alignment: .trailing)
            }
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .onTapGesture(count: 2, perform: action)
        } else {
            Button(action: action) {
                HStack(spacing: 14) {
                    ArtworkView(artwork: item.artwork)
                        .frame(width: 52, height: 52)
                    VStack(alignment: .leading, spacing: 4) {
                        Group {
                            if case let .user(user) = item {
                                GenderedName(name: user.nickname, gender: user.gender)
                            } else {
                                Text(item.title)
                            }
                        }
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                        Text(item.subtitle)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        if case let .playlist(playlist) = item {
                            Text("\(playlist.trackCount) 首歌曲")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .foregroundStyle(.secondary)
                        .frame(width: 24)
                }
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }
}

struct SongContextMenu: View {
    let song: Song
    let songs: [Song]
    var allSongIDs: [Int64]? = nil
    var playlistID: Int64? = nil
    @Bindable var model: AppModel
    @Bindable var player: PlayerController

    var body: some View {
        Button { player.play(song, in: songs, allSongIDs: allSongIDs, playlistID: playlistID) } label: {
            Label("播放", systemImage: "play.fill")
        }
        if !song.artists.isEmpty {
            Menu {
                ForEach(Array(song.artists.enumerated()), id: \.offset) { _, artist in
                    Button { model.open(.artist(artist.id)) } label: {
                        Label(artist.name, systemImage: "music.mic")
                    }
                }
            } label: {
                Label("歌手", systemImage: "music.mic")
            }
        }
        Button { model.toggleSongLiked(song.id) } label: {
            Label(
                model.likedSongIDs.contains(song.id) ? "取消喜欢" : "喜欢",
                systemImage: model.likedSongIDs.contains(song.id) ? "heart.slash" : "heart"
            )
        }
        Button { model.download(song) } label: {
            Label("下载", systemImage: "arrow.down.circle")
        }
        Button { model.showAddToPlaylist(for: song) } label: {
            Label("添加到歌单", systemImage: "text.badge.plus")
        }
        .disabled(model.currentUserID == nil)
        Button { model.open(.similarSongs(song)) } label: {
            Label("相似歌曲", systemImage: "waveform.badge.magnifyingglass")
        }
        Button { model.open(.comments(song.id)) } label: {
            Label("评论", systemImage: "bubble.left")
        }
    }
}

private struct GenderedName: View {
    let name: String
    let gender: Int

    var body: some View {
        HStack(spacing: 3) {
            Text(name)
            if gender == 1 {
                Text("♂").foregroundStyle(.cyan)
            } else if gender == 2 {
                Text("♀").foregroundStyle(.pink)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(name + (gender == 1 ? "，男" : gender == 2 ? "，女" : ""))
    }
}

private struct DetailView: View {
    let route: Route
    @Bindable var model: AppModel
    @Bindable var player: PlayerController

    var body: some View {
        Group {
            switch model.detailLoads[route] ?? .idle {
            case .idle, .loading:
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case let .failed(message):
                ContentUnavailableView {
                    Label("无法打开详情", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                } actions: {
                    Button("重试") { model.loadDetail(route, reload: true) }
                }
            case let .loaded(detail):
                DetailContentView(detail: detail, model: model, player: player)
            }
        }
        .task(id: route) { model.loadDetail(route) }
    }
}

private struct DetailContentView: View {
    let detail: DetailContent
    @Bindable var model: AppModel
    @Bindable var player: PlayerController

    @ViewBuilder
    var body: some View {
        ScrollView {
            Group {
                switch detail {
                case let .artist(artist, songs):
                    ArtistDetailContent(artist: artist, songs: songs, model: model, player: player)
                case let .album(album, songs):
                    AlbumDetailContent(album: album, songs: songs, model: model, player: player)
                case let .playlist(playlist, songs, trackIDs, loadedTrackCount):
                    PlaylistDetailContent(
                        playlist: playlist,
                        songs: songs,
                        trackIDs: trackIDs,
                        loadedTrackCount: loadedTrackCount,
                        model: model,
                        player: player
                    )
                case let .user(user, playlists):
                    UserDetailContent(user: user, playlists: playlists, model: model)
                }
            }
            .frame(maxWidth: 1_120, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(28)
        }
    }
}

private struct ArtistDetailContent: View {
    let artist: Artist
    let songs: [Song]
    @Bindable var model: AppModel
    @Bindable var player: PlayerController

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            DetailHeader(
                title: artist.name,
                eyebrow: "歌手",
                symbol: "music.mic",
                description: artist.biography,
                artwork: artist.artwork,
                saveArtwork: model.saveArtwork,
                metadata: songs.isEmpty ? [] : ["\(songs.count.formatted()) 首热门歌曲"],
                circularArtwork: true,
                actions: playAction
            )
            if let extras = model.extras, let library = model.library {
                ArtistExtrasView(
                    artistID: artist.id,
                    extras: extras,
                    library: library,
                    knowledgeSection: model.knowledgeLibrary.map { knowledge in
                        AnyView(MusicKnowledgeSection(
                            resource: .artist(artist.id),
                            library: knowledge,
                            fallbackText: artist.biography,
                            showsTitle: false,
                            onOpenRoute: model.open
                        ))
                    },
                    onOpenRoute: { model.open($0) },
                    onFollowChanged: {
                        model.showToast($0 ? "已关注歌手" : "已取消关注歌手")
                    },
                    songList: AnyView(
                        ArtistSongList(
                            artistID: artist.id,
                            hotSongs: songs,
                            totalSongCount: artist.songCount,
                            extras: extras,
                            model: model,
                            player: player
                        )
                        .id(artist.id)
                    )
                )
            } else {
                SongList(songs: songs, model: model, player: player)
            }
        }
    }

    private var playAction: AnyView? {
        guard let firstSong = songs.first else { return nil }
        return AnyView(
            Button { player.play(firstSong, in: songs) } label: {
                Label("播放", systemImage: "play.fill")
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
        )
    }
}

private struct AlbumDetailContent: View {
    let album: Album
    let songs: [Song]
    @Bindable var model: AppModel
    @Bindable var player: PlayerController
    @State private var selectedSection = AlbumDetailSection.songs

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            DetailHeader(
                title: album.name,
                eyebrow: "专辑",
                symbol: "square.stack",
                description: album.description,
                artwork: album.artwork,
                saveArtwork: model.saveArtwork,
                metadata: albumMetadata,
                actions: headerActions
            )
            HStack {
                Picker("专辑内容", selection: $selectedSection) {
                    ForEach(AlbumDetailSection.allCases, id: \.self) { section in
                        Label(section.rawValue, systemImage: section.symbol)
                            .tag(section)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 360)
                Spacer()
            }
            switch selectedSection {
            case .songs:
                SongList(songs: songs, model: model, player: player, showsHeading: false)
            case .knowledge:
                if let knowledge = model.knowledgeLibrary {
                    MusicKnowledgeSection(
                        resource: .album(album.id),
                        library: knowledge,
                        fallbackText: album.description,
                        showsTitle: false,
                        onOpenRoute: model.open
                    )
                } else {
                    ContentUnavailableView("百科不可用", systemImage: "text.book.closed")
                        .frame(maxWidth: .infinity, minHeight: 160)
                }
            }
        }
        .onChange(of: album.id) { _, _ in selectedSection = .songs }
    }

    private var isSubscribed: Bool {
        model.albumSubscriptionOverrides[album.id] ?? album.isSubscribed
    }

    private var subscriberCount: Int64 {
        let delta: Int64 = isSubscribed == album.isSubscribed ? 0 : (isSubscribed ? 1 : -1)
        return max(0, album.subscriberCount + delta)
    }

    private var subscriptionTitle: String {
        isSubscribed ? "取消收藏" : "收藏专辑"
    }

    private var albumMetadata: [String] {
        [
            album.artist.name,
            "\(songs.count.formatted()) 首歌曲",
            subscriberCount > 0 ? "\(subscriberCount.formatted()) 人收藏" : nil
        ].compactMap { $0 }
    }

    private var headerActions: AnyView {
        AnyView(HStack(spacing: 10) {
            if let firstSong = songs.first {
                Button { player.play(firstSong, in: songs) } label: {
                    Label("播放", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            }
            Button { model.setAlbumSubscribed(album.id, subscribed: !isSubscribed) } label: {
                Label(subscriptionTitle, systemImage: isSubscribed ? "star.slash" : "star")
            }
            .buttonStyle(.bordered)
        })
    }
}

private enum AlbumDetailSection: String, CaseIterable {
    case songs = "歌曲"
    case knowledge = "百科"

    var symbol: String {
        switch self {
        case .songs: "music.note"
        case .knowledge: "text.book.closed"
        }
    }
}

private struct PlaylistDetailContent: View {
    let playlist: Playlist
    let songs: [Song]
    let trackIDs: [Int64]
    let loadedTrackCount: Int
    @Bindable var model: AppModel
    @Bindable var player: PlayerController
    @State private var selectedSection = PlaylistDetailSection.songs
    @State private var similarPlaylistsPhase: DetailExtrasPhase<[MusicLibraryPlaylist]> = .loading
    @State private var similarPlaylistsReloadID = 0
    @State private var showingMetadataEditor = false
    @State private var showingSongOrder = false
    @State private var choosingCover = false
    @State private var showingCoverPreview = false
    @State private var coverDraft: ProcessedPlaylistCover?
    @State private var coverPreparationTask: Task<Void, Never>?
    @State private var coverProcessingWorker: Task<ProcessedPlaylistCover, Error>?
    @State private var isPreparingCover = false
    @State private var showingPrivacyConfirmation = false
    @State private var isPublishing = false
    @State private var publishTask: Task<Void, Never>?
    @State private var managementError: String?
    @State private var showingDownloadConfirmation = false
    @State private var downloadQuality = AudioQuality.standard
    @State private var isAddingDownloads = false
    @State private var showingFavoriteConfirmation = false
    @State private var isFavoritingAll = false

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 24, pinnedViews: [.sectionHeaders]) {
            DetailHeader(
                title: playlist.name,
                eyebrow: "歌单",
                symbol: "music.note.list",
                description: playlist.description,
                artwork: playlist.artwork,
                saveArtwork: model.saveArtwork,
                metadata: playlistMetadata,
                actions: headerActions
            )

            Section {
                switch selectedSection {
                case .songs:
                    SongList(
                        songs: songs,
                        allSongIDs: trackIDs,
                        playlistID: playlist.id,
                        playlistIsFavorite: playlist.specialType == 5,
                        allowsSongRemoval: playlist.creatorID == model.currentUserID && !playlist.isReadOnly,
                        model: model,
                        player: player,
                        hasMore: loadedTrackCount < trackIDs.count,
                        isLoadingMore: model.loadingPlaylistIDs.contains(playlist.id),
                        loadMoreError: model.playlistLoadMoreErrors[playlist.id],
                        onLoadMore: { model.loadMorePlaylistSongs(playlist.id) }
                    )
                case .similarPlaylists:
                    if model.library != nil {
                        PlaylistExtrasView(
                            phase: similarPlaylistsPhase,
                            onRetry: { similarPlaylistsReloadID += 1 },
                            onOpenRoute: { model.open($0) }
                        )
                    } else {
                        ContentUnavailableView("相似歌单不可用", systemImage: "music.note.list")
                            .frame(maxWidth: .infinity, minHeight: 120)
                    }
                }
            } header: {
                if visibleSections.count > 1 {
                    HStack {
                        Picker("歌单内容", selection: $selectedSection) {
                            ForEach(visibleSections, id: \.self) { section in
                                Label(section.rawValue, systemImage: section.symbol)
                                    .tag(section)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(maxWidth: 360)
                        Spacer()
                    }
                    .padding(.vertical, 8)
                    .background(Color(nsColor: .windowBackgroundColor))
                }
            }
        }
        .task(id: "\(playlist.id):\(similarPlaylistsReloadID):\(model.library != nil)") {
            await loadSimilarPlaylists()
        }
        .sheet(isPresented: $showingMetadataEditor) {
            if let library = model.library {
                PlaylistMetadataEditor(
                    playlist: playlist,
                    library: library,
                    reloadPlaylist: { try await model.reloadPlaylist(playlist.id) },
                    onSaved: {
                        showingMetadataEditor = false
                        model.showToast("歌单信息已保存")
                    },
                    onCancelDuringSave: {
                        guard playlist.isUserEditable(by: model.currentUserID) else { return }
                        Task { _ = try? await model.reloadPlaylist(playlist.id) }
                    }
                )
            }
        }
        .sheet(isPresented: $showingDownloadConfirmation) {
            VStack(alignment: .leading, spacing: 20) {
                Text("全部下载")
                    .font(.title2.weight(.semibold))
                Text("将歌单中的 \(trackIDs.count.formatted()) 首歌曲加入下载队列；已下载相同音质的歌曲会自动跳过。")
                    .foregroundStyle(.secondary)
                Picker("下载音质", selection: $downloadQuality) {
                    ForEach(AudioQuality.allCases, id: \.self) { quality in
                        Text(quality.rawValue).tag(quality)
                    }
                }
                .pickerStyle(.radioGroup)
                HStack {
                    Spacer()
                    Button("取消", role: .cancel) { showingDownloadConfirmation = false }
                    Button("确认下载", action: downloadAll)
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(24)
            .frame(width: 420)
            .onAppear { downloadQuality = model.settings.quality }
        }
        .sheet(isPresented: $showingSongOrder) {
            if let library = model.library {
                PlaylistSongOrderEditor(
                    playlistID: playlist.id,
                    trackIDs: trackIDs,
                    loadedSongs: songs,
                    repository: model.repository,
                    library: library,
                    reload: { _ = try await model.reloadPlaylist(playlist.id) },
                    onSaved: { model.showToast("歌曲顺序已保存") }
                )
            }
        }
        .sheet(isPresented: $showingCoverPreview, onDismiss: { coverDraft = nil }) {
            if let coverDraft, let library = model.library {
                PlaylistCoverConfirmation(
                    playlistID: playlist.id,
                    cover: coverDraft,
                    library: library,
                    reload: { _ = try await model.reloadPlaylist(playlist.id) },
                    onSaved: { model.showToast("歌单封面已更新") }
                )
            }
        }
        .fileImporter(
            isPresented: $choosingCover,
            allowedContentTypes: [.image],
            allowsMultipleSelection: false,
            onCompletion: prepareCover
        )
        .confirmationDialog("将歌单设为公开？", isPresented: $showingPrivacyConfirmation) {
            Button("设为公开", role: .destructive, action: makePublic)
            Button("取消", role: .cancel) {}
        } message: {
            Text("公开后，本功能不能将它改回私密歌单。")
        }
        .confirmationDialog("收藏歌单中的全部歌曲？", isPresented: $showingFavoriteConfirmation) {
            Button("全部收藏", action: favoriteAll)
            Button("取消", role: .cancel) {}
        } message: {
            Text("将收藏尚未收藏的 \(unlikedSongCount) 首歌曲。")
        }
        .alert("歌单操作失败", isPresented: managementErrorPresented) {
            Button("好") { managementError = nil }
        } message: {
            Text(managementError ?? "")
        }
        .onChange(of: model.currentUserID) { _, userID in
            guard !playlist.isUserEditable(by: userID) else { return }
            coverPreparationTask?.cancel()
            coverProcessingWorker?.cancel()
            publishTask?.cancel()
            showingMetadataEditor = false
            showingSongOrder = false
            showingCoverPreview = false
            coverDraft = nil
        }
        .onDisappear {
            coverPreparationTask?.cancel()
            coverProcessingWorker?.cancel()
            publishTask?.cancel()
        }
    }

    private var isSubscribed: Bool {
        model.playlistSubscriptionOverrides[playlist.id] ?? playlist.isSubscribed
    }

    private var visibleSections: [PlaylistDetailSection] {
        let hasSimilarPlaylists = switch similarPlaylistsPhase {
        case let .loaded(playlists): !playlists.isEmpty
        case .failed: true
        case .loading: false
        }
        return PlaylistDetailSection.visible(hasSimilarPlaylists: model.library == nil || hasSimilarPlaylists)
    }

    @MainActor
    private func loadSimilarPlaylists() async {
        guard let library = model.library else { return }
        selectedSection = .songs
        similarPlaylistsPhase = .loading
        do {
            let playlists = try await library.similarPlaylists(to: playlist.id)
            try Task.checkCancellation()
            similarPlaylistsPhase = .loaded(playlists)
        } catch is CancellationError {
        } catch {
            similarPlaylistsPhase = .failed(error.localizedDescription)
        }
    }

    private var subscriberCount: Int64 {
        let delta: Int64 = isSubscribed == playlist.isSubscribed ? 0 : (isSubscribed ? 1 : -1)
        return max(0, playlist.subscriberCount + delta)
    }

    private var subscriptionTitle: String {
        isSubscribed ? "取消收藏" : "收藏歌单"
    }

    private var playlistMetadata: [String] {
        [
            playlist.creator.isEmpty ? nil : "创建者 \(playlist.creator)",
            "\(max(playlist.trackCount, trackIDs.count).formatted()) 首歌曲",
            playlist.isPrivate ? "私密歌单" : nil,
            playlist.tags.isEmpty ? nil : playlist.tags.joined(separator: " · "),
            subscriberCount > 0 ? "\(subscriberCount.formatted()) 人收藏" : nil
        ].compactMap { $0 }
    }

    private var headerActions: AnyView {
        AnyView(HStack(spacing: 10) {
            if let firstSong = songs.first {
                Button {
                    player.play(firstSong, in: songs, allSongIDs: trackIDs, playlistID: playlist.id)
                } label: {
                    Label("播放", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            }
            if model.downloads != nil {
                Button {
                    showingDownloadConfirmation = true
                } label: {
                    if isAddingDownloads {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("全部下载", systemImage: "arrow.down.circle")
                    }
                }
                .buttonStyle(.bordered)
                .disabled(trackIDs.isEmpty || isAddingDownloads)
                .accessibilityLabel(isAddingDownloads ? "正在加入下载队列" : "全部下载")
            }
            if playlist.specialType != 5, model.library != nil, unlikedSongCount > 0 {
                Button { showingFavoriteConfirmation = true } label: {
                    if isFavoritingAll {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("全部收藏", systemImage: "heart")
                    }
                }
                .buttonStyle(.bordered)
                .disabled(isFavoritingAll)
                .help("收藏尚未收藏的 \(unlikedSongCount) 首歌曲")
                .accessibilityLabel(isFavoritingAll ? "正在全部收藏" : "全部收藏")
            }
            if playlist.creatorID != 0 {
                Button { model.open(.user(playlist.creatorID)) } label: {
                    Image(systemName: "person.crop.circle")
                }
                .buttonStyle(.bordered)
                .help("查看创建者 \(playlist.creator)")
                .accessibilityLabel("查看创建者 \(playlist.creator)")
                .accessibilityHint("打开创建者主页")
            }
            if model.currentUserID != playlist.creatorID {
                Button { model.setPlaylistSubscribed(playlist.id, subscribed: !isSubscribed) } label: {
                    Label(subscriptionTitle, systemImage: isSubscribed ? "star.slash" : "star")
                }
                .buttonStyle(.bordered)
            }
            if playlist.isUserEditable(by: model.currentUserID), model.library != nil {
                Menu {
                    Button { showingMetadataEditor = true } label: {
                        Label("编辑歌单", systemImage: "pencil")
                    }
                    Button { choosingCover = true } label: {
                        Label("更新封面", systemImage: "photo")
                    }
                    Button { showingSongOrder = true } label: {
                        Label("歌曲排序", systemImage: "arrow.up.arrow.down")
                    }
                    .disabled(trackIDs.count < 2)
                    if playlist.isPrivate {
                        Divider()
                        Button(role: .destructive) { showingPrivacyConfirmation = true } label: {
                            Label("设为公开", systemImage: "lock.open")
                        }
                    }
                } label: {
                    if isPublishing || isPreparingCover {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "ellipsis")
                    }
                }
                .disabled(isPublishing || isPreparingCover)
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 44, height: 44)
                .help("更多")
                .accessibilityLabel("歌单操作")
            }
        })
    }

    private var managementErrorPresented: Binding<Bool> {
        Binding(
            get: { managementError != nil },
            set: { if !$0 { managementError = nil } }
        )
    }

    private var unlikedSongCount: Int {
        trackIDs.filter { !model.likedSongIDs.contains($0) }.count
    }

    private func downloadAll() {
        showingDownloadConfirmation = false
        isAddingDownloads = true
        Task { @MainActor in
            do {
                _ = try await model.downloadPlaylist(
                    loadedSongs: songs,
                    trackIDs: trackIDs,
                    quality: downloadQuality
                )
            } catch is CancellationError {
            } catch {
                managementError = "加入下载队列失败：\(error.localizedDescription)"
            }
            isAddingDownloads = false
        }
    }

    private func favoriteAll() {
        isFavoritingAll = true
        Task { @MainActor in
            do {
                let count = try await model.favoriteSongs(trackIDs)
                model.showToast("已收藏 \(count) 首歌曲")
            } catch is CancellationError {
            } catch {
                managementError = "部分歌曲收藏失败：\(error.localizedDescription)"
            }
            isFavoritingAll = false
        }
    }

    private func prepareCover(_ result: Result<[URL], Error>) {
        guard case let .success(urls) = result, let url = urls.first else {
            if case let .failure(error) = result { managementError = error.localizedDescription }
            return
        }
        coverPreparationTask?.cancel()
        coverProcessingWorker?.cancel()
        isPreparingCover = true
        managementError = nil
        coverPreparationTask = Task { @MainActor in
            do {
                let worker = Task.detached(priority: .userInitiated) {
                    try PlaylistCoverProcessor.process(url: url)
                }
                coverProcessingWorker = worker
                let cover = try await worker.value
                try Task.checkCancellation()
                coverDraft = cover
                showingCoverPreview = true
            } catch is CancellationError {
            } catch {
                managementError = error.localizedDescription
            }
            isPreparingCover = false
            coverProcessingWorker = nil
            coverPreparationTask = nil
        }
    }

    private func makePublic() {
        guard let library = model.library, !isPublishing, playlist.isPrivate else { return }
        isPublishing = true
        managementError = nil
        publishTask = Task { @MainActor in
            do {
                try await library.makePlaylistPublic(playlist.id)
                model.showToast("歌单已设为公开")
                do {
                    _ = try await model.reloadPlaylist(playlist.id)
                } catch {
                    managementError = "歌单已设为公开，但重新读取失败：\(error.localizedDescription)"
                }
            } catch is CancellationError {
            } catch {
                managementError = error.localizedDescription
            }
            isPublishing = false
            publishTask = nil
        }
    }
}

enum PlaylistDetailSection: String, CaseIterable {
    case songs = "歌曲"
    case similarPlaylists = "相似歌单"

    var symbol: String {
        switch self {
        case .songs: "music.note"
        case .similarPlaylists: "rectangle.stack"
        }
    }

    static func visible(hasSimilarPlaylists: Bool) -> [Self] {
        hasSimilarPlaylists ? allCases : [.songs]
    }
}

private struct PlaylistMetadataEditor: View {
    let playlist: Playlist
    let library: LiveMusicLibrary
    let reloadPlaylist: () async throws -> Playlist
    let onSaved: () -> Void
    let onCancelDuringSave: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var draft: PlaylistMetadataDraft
    @State private var errorMessage: String?
    @State private var isSaving = false
    @State private var saveTask: Task<Void, Never>?
    @State private var requestedDismissReload = false

    init(
        playlist: Playlist,
        library: LiveMusicLibrary,
        reloadPlaylist: @escaping () async throws -> Playlist,
        onSaved: @escaping () -> Void,
        onCancelDuringSave: @escaping () -> Void
    ) {
        self.playlist = playlist
        self.library = library
        self.reloadPlaylist = reloadPlaylist
        self.onSaved = onSaved
        self.onCancelDuringSave = onCancelDuringSave
        _draft = State(initialValue: PlaylistMetadataDraft(playlist: playlist))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("基本信息") {
                    TextField("名称", text: $draft.name)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("描述")
                        TextEditor(text: $draft.description)
                            .frame(minHeight: 110)
                    }
                }
                Section("网易云官方标签") {
                    HStack(spacing: 10) {
                        ForEach(draft.tags.indices, id: \.self) { index in
                            VStack(alignment: .leading, spacing: 5) {
                                Text("标签 \(index + 1)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                TextField("", text: $draft.tags[index])
                                    .textFieldStyle(.roundedBorder)
                                    .labelsHidden()
                                    .accessibilityLabel("标签 \(index + 1)")
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("编辑歌单")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消", action: cancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(action: save) {
                        Group {
                            if isSaving {
                                ProgressView().controlSize(.small)
                            } else {
                                Text("保存")
                            }
                        }
                        .frame(minWidth: 36)
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
                    .accessibilityLabel(isSaving ? "正在保存" : "保存")
                }
            }
        }
        .frame(minWidth: 520, minHeight: 410)
        .interactiveDismissDisabled(isSaving)
        .onDisappear {
            let needsReload = isSaving && !requestedDismissReload
            saveTask?.cancel()
            if needsReload { onCancelDuringSave() }
        }
    }

    private var canSave: Bool {
        !isSaving && !draft.normalizedName.isEmpty && !draft.changes(from: playlist).isEmpty
    }

    private func save() {
        let changes = draft.changes(from: playlist)
        guard !changes.isEmpty, !draft.normalizedName.isEmpty, !isSaving else { return }
        errorMessage = nil
        isSaving = true
        saveTask = Task { @MainActor in
            var completed = 0
            do {
                for change in changes {
                    try Task.checkCancellation()
                    switch change {
                    case let .name(name):
                        try await library.updatePlaylistName(playlist.id, name: name)
                    case let .description(description):
                        try await library.updatePlaylistDescription(playlist.id, description: description)
                    case let .tags(tags):
                        try await library.updatePlaylistTags(playlist.id, tags: tags)
                    }
                    completed += 1
                }
            } catch is CancellationError {
                return
            } catch {
                await recover(from: error, completed: completed)
                return
            }

            do {
                let refreshed = try await reloadPlaylist()
                let rejected = changes.filter { !$0.isReflected(in: refreshed) }
                guard rejected.isEmpty else {
                    draft = PlaylistMetadataDraft(playlist: refreshed)
                    errorMessage = rejected.contains(where: {
                        if case .tags = $0 { true } else { false }
                    })
                        ? "标签未保存。网易云只接受官方歌单标签，例如“学习”“华语”“流行”。"
                        : "部分内容未被服务器保存，已重新读取当前歌单。"
                    isSaving = false
                    saveTask = nil
                    return
                }
                draft = PlaylistMetadataDraft(playlist: refreshed)
                isSaving = false
                saveTask = nil
                onSaved()
            } catch is CancellationError {
            } catch {
                errorMessage = "内容已保存，但重新读取失败：\(error.localizedDescription)"
                isSaving = false
                saveTask = nil
            }
        }
    }

    @MainActor
    private func recover(from saveError: Error, completed: Int) async {
        do {
            draft = PlaylistMetadataDraft(playlist: try await reloadPlaylist())
            errorMessage = completed > 0
                ? "部分内容可能已保存，已重新读取当前歌单。\n\(saveError.localizedDescription)"
                : saveError.localizedDescription
        } catch is CancellationError {
            return
        } catch {
            errorMessage = completed > 0
                ? "部分内容可能已保存，重新读取失败：\(error.localizedDescription)"
                : "\(saveError.localizedDescription)\n重新读取失败：\(error.localizedDescription)"
        }
        isSaving = false
        saveTask = nil
    }

    private func cancel() {
        if isSaving {
            requestedDismissReload = true
        }
        saveTask?.cancel()
        if requestedDismissReload { onCancelDuringSave() }
        dismiss()
    }
}

private struct PlaylistCoverConfirmation: View {
    let playlistID: Int64
    let cover: ProcessedPlaylistCover
    let library: LiveMusicLibrary
    let reload: () async throws -> Void
    let onSaved: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var errorMessage: String?
    @State private var isSaving = false
    @State private var uploadCompleted = false
    @State private var saveTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                if let image = NSImage(data: cover.jpegData) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 300, height: 300)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .accessibilityLabel("新歌单封面预览")
                }
                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(28)
            .navigationTitle("确认新封面")
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
                            Text(uploadCompleted ? "重新读取" : "上传")
                        }
                    }
                    .disabled(isSaving)
                }
            }
        }
        .frame(minWidth: 440, minHeight: 460)
        .interactiveDismissDisabled(isSaving)
        .onDisappear { saveTask?.cancel() }
    }

    private func save() {
        guard !isSaving else { return }
        isSaving = true
        errorMessage = nil
        saveTask = Task { @MainActor in
            do {
                if !uploadCompleted {
                    try await library.updatePlaylistCover(playlistID, cover: cover)
                    uploadCompleted = true
                }
                try await reload()
                onSaved()
                dismiss()
            } catch is CancellationError {
            } catch {
                errorMessage = uploadCompleted
                    ? "封面已更新，但重新读取失败：\(error.localizedDescription)"
                    : error.localizedDescription
                isSaving = false
                saveTask = nil
            }
        }
    }
}

private struct PlaylistSongOrderEditor: View {
    let playlistID: Int64
    let original: [Int64]
    let repository: any MusicRepository
    let library: LiveMusicLibrary
    let reload: () async throws -> Void
    let onSaved: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var draft: [Int64]
    @State private var songsByID: [Int64: Song]
    @State private var isLoading = true
    @State private var loadID = 0
    @State private var loadError: String?
    @State private var isSaving = false
    @State private var writeCompleted = false
    @State private var saveError: String?
    @State private var saveTask: Task<Void, Never>?

    init(
        playlistID: Int64,
        trackIDs: [Int64],
        loadedSongs: [Song],
        repository: any MusicRepository,
        library: LiveMusicLibrary,
        reload: @escaping () async throws -> Void,
        onSaved: @escaping () -> Void
    ) {
        self.playlistID = playlistID
        original = trackIDs
        self.repository = repository
        self.library = library
        self.reload = reload
        self.onSaved = onSaved
        _draft = State(initialValue: trackIDs)
        _songsByID = State(initialValue: Dictionary(
            loadedSongs.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        ))
    }

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView("正在加载完整歌单…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let loadError {
                    ContentUnavailableView {
                        Label("歌曲加载失败", systemImage: "wifi.exclamationmark")
                    } description: {
                        Text(loadError)
                    } actions: {
                        Button("重试") { loadID += 1 }
                    }
                } else {
                    List {
                        ForEach(draft, id: \.self) { trackID in
                            HStack(spacing: 12) {
                                Image(systemName: "music.note")
                                    .foregroundStyle(.secondary)
                                    .frame(width: 24)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(songsByID[trackID]?.name ?? "歌曲 \(trackID)")
                                        .lineLimit(1)
                                    if let artists = songsByID[trackID]?.artistsDisplay, !artists.isEmpty {
                                        Text(artists)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                }
                            }
                            .frame(minHeight: 44)
                        }
                        .onMove { source, destination in
                            guard !isSaving else { return }
                            draft.move(fromOffsets: source, toOffset: destination)
                        }
                    }
                }
            }
            .navigationTitle("歌曲排序")
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
                            Text(writeCompleted ? "重新读取" : "保存")
                        }
                    }
                    .disabled(isSaving || isLoading || loadError != nil || (!writeCompleted && draft == original))
                }
            }
            .safeAreaInset(edge: .bottom) {
                if let saveError {
                    Label(saveError, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                        .background(.bar)
                }
            }
        }
        .frame(minWidth: 560, minHeight: 620)
        .interactiveDismissDisabled(isSaving)
        .task(id: loadID) { await loadSongs() }
        .onDisappear { saveTask?.cancel() }
    }

    @MainActor
    private func loadSongs() async {
        isLoading = true
        loadError = nil
        do {
            let songs = try await repository.songs(ids: original)
            try Task.checkCancellation()
            songsByID.merge(songs.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
            isLoading = false
        } catch is CancellationError {
        } catch {
            loadError = error.localizedDescription
            isLoading = false
        }
    }

    private func save() {
        guard !isSaving, writeCompleted || draft != original else { return }
        isSaving = true
        saveError = nil
        saveTask = Task { @MainActor in
            do {
                if !writeCompleted {
                    try await library.updatePlaylistSongOrder(playlistID, trackIDs: draft)
                    writeCompleted = true
                }
                try await reload()
                onSaved()
                dismiss()
            } catch is CancellationError {
            } catch {
                saveError = writeCompleted
                    ? "顺序已保存，但重新读取失败：\(error.localizedDescription)"
                    : error.localizedDescription
                isSaving = false
                saveTask = nil
            }
        }
    }
}

private struct UserDetailContent: View {
    let user: UserProfile
    let playlists: [Playlist]
    @Bindable var model: AppModel
    @State private var selectedSection = UserDetailSection.playlists

    var body: some View {
        let followed = model.userFollowOverrides[user.id] ?? user.isFollowed
        VStack(alignment: .leading, spacing: 24) {
            DetailHeader(
                title: user.nickname,
                gender: user.gender,
                eyebrow: "用户",
                symbol: "person.crop.circle",
                description: profileDescription,
                artwork: user.artwork,
                saveArtwork: model.saveArtwork,
                metadata: userMetadata,
                circularArtwork: true,
                actions: followAction(followed: followed)
            )

            Picker("用户主页内容", selection: $selectedSection) {
                ForEach(UserDetailSection.allCases, id: \.self) { section in
                    Label(section.rawValue, systemImage: section.symbol)
                        .tag(section)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 560)

            if selectedSection == .playlists {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 16)], spacing: 16) {
                    ForEach(playlists) { playlist in
                        Button { model.open(.playlist(playlist.id)) } label: {
                            HStack(spacing: 12) {
                                ArtworkView(artwork: playlist.artwork).frame(width: 54, height: 54)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(playlist.name).font(.subheadline.weight(.medium))
                                    Text(playlist.creator).font(.caption).foregroundStyle(.secondary)
                                    Text("\(playlist.trackCount) 首歌曲").font(.caption2).foregroundStyle(.tertiary)
                                }
                                Spacer()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            } else if let library = model.library, let relationSection = selectedSection.relationSection {
                UserRelationsView(
                    userID: user.id,
                    library: library,
                    section: relationSection,
                    onOpenRoute: { model.open($0) }
                )
            }
        }
    }

    private var profileDescription: String {
        let parts: [String?] = [
            user.signature.isEmpty ? nil : "个性签名：\(user.signature)",
            user.detailDescription.isEmpty ? nil : "简介：\(user.detailDescription)"
        ]
        return parts.compactMap { $0 }.joined(separator: "\n\n")
    }

    private var userMetadata: [String] {
        var values: [String] = []
        if user.level > 0 { values.append("Level \(user.level)") }
        if user.listenSongs > 0 { values.append("听过 \(user.listenSongs.formatted()) 首歌") }
        if user.followerCount > 0 { values.append("\(user.followerCount.formatted()) 位关注者") }
        if user.followingCount > 0 { values.append("关注 \(user.followingCount.formatted()) 人") }
        if model.currentUserID != nil, model.currentUserID != user.id, user.followsCurrentUser {
            values.append("关注了你")
        }
        return values
    }

    private func followAction(followed: Bool) -> AnyView? {
        guard model.currentUserID != user.id else { return nil }
        return AnyView(
            Button { model.setUserFollowed(user.id, followed: !followed) } label: {
                Label(followed ? "取消关注" : "关注用户", systemImage: followed ? "person.badge.minus" : "person.badge.plus")
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
        )
    }
}

private enum UserDetailSection: String, CaseIterable {
    case playlists = "公开歌单"
    case users = "关注用户"
    case artists = "关注歌手"

    var symbol: String {
        switch self {
        case .playlists: "music.note.list"
        case .users: "person.2"
        case .artists: "music.mic"
        }
    }

    var relationSection: UserRelationSection? {
        switch self {
        case .playlists: nil
        case .users: .users
        case .artists: .artists
        }
    }
}

private struct DetailHeader: View {
    let title: String
    var gender = 0
    let eyebrow: String
    let symbol: String
    let description: String
    let artwork: Artwork
    let saveArtwork: (URL, String) -> Void
    var metadata: [String] = []
    var circularArtwork = false
    var actions: AnyView?

    var body: some View {
        HStack(alignment: .center, spacing: 28) {
            ArtworkView(
                artwork: artwork,
                highResolution: true,
                saveTitle: title,
                saveAction: saveArtwork
            )
                .frame(width: 192, height: 192)
                .clipShape(RoundedRectangle(cornerRadius: circularArtwork ? 96 : 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: circularArtwork ? 96 : 8, style: .continuous)
                        .stroke(.white.opacity(0.16), lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.18), radius: 16, y: 8)
                .accessibilityLabel("\(title)封面")
            VStack(alignment: .leading, spacing: 11) {
                Label(eyebrow, systemImage: symbol)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .symbolRenderingMode(.hierarchical)
                GenderedName(name: title, gender: gender)
                    .font(.system(size: 34, weight: .bold))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                if !metadata.isEmpty {
                    Text(metadata.joined(separator: "   ·   "))
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ExpandableDescription(text: description)
                    .id(description)
                if let actions {
                    actions
                        .controlSize(.large)
                        .padding(.top, 3)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 24)
        .overlay(alignment: .bottom) { Divider() }
    }
}

private struct ExpandableDescription: View {
    let text: String

    @State private var isExpanded = false
    @State private var fullHeight: CGFloat = 0
    @State private var collapsedHeight: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if !text.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text(text)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(isExpanded ? nil : 3)
                    .fixedSize(horizontal: false, vertical: true)
                    .background {
                        Text(text)
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                            .hidden()
                            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { fullHeight = $0 }
                    }
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                        if !isExpanded { collapsedHeight = $0 }
                    }
                if isExpanded || fullHeight > collapsedHeight + 1 {
                    Button {
                        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                            isExpanded.toggle()
                        }
                    } label: {
                        Label(isExpanded ? "收起" : "展开", systemImage: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.caption.weight(.medium))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                    .accessibilityLabel(isExpanded ? "收起描述" : "展开完整描述")
                    .accessibilityValue(isExpanded ? "已展开" : "已收起")
                }
            }
            .frame(maxWidth: 720, alignment: .leading)
        }
    }
}

struct SongList: View {
    let songs: [Song]
    let allSongIDs: [Int64]?
    let playlistID: Int64?
    let playlistIsFavorite: Bool
    let allowsSongRemoval: Bool
    @Bindable var model: AppModel
    @Bindable var player: PlayerController
    let showsHeading: Bool
    let hasMore: Bool
    let isLoadingMore: Bool
    let loadMoreError: String?
    let onLoadMore: () -> Void

    init(
        songs: [Song],
        allSongIDs: [Int64]? = nil,
        playlistID: Int64? = nil,
        playlistIsFavorite: Bool = false,
        allowsSongRemoval: Bool = false,
        model: AppModel,
        player: PlayerController,
        showsHeading: Bool = true,
        hasMore: Bool = false,
        isLoadingMore: Bool = false,
        loadMoreError: String? = nil,
        onLoadMore: @escaping () -> Void = {}
    ) {
        self.songs = songs
        self.allSongIDs = allSongIDs
        self.playlistID = playlistID
        self.playlistIsFavorite = playlistIsFavorite
        self.allowsSongRemoval = allowsSongRemoval
        self.model = model
        self.player = player
        self.showsHeading = showsHeading
        self.hasMore = hasMore
        self.isLoadingMore = isLoadingMore
        self.loadMoreError = loadMoreError
        self.onLoadMore = onLoadMore
    }

    var body: some View {
        if !songs.isEmpty || hasMore {
            LazyVStack(alignment: .leading, spacing: 8) {
                if showsHeading {
                    Text("歌曲")
                        .font(.title3.weight(.semibold))
                }
                ForEach(Array(songs.enumerated()), id: \.element.id) { index, song in
                    HStack(spacing: 12) {
                        Text("\(index + 1)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.tertiary)
                            .frame(width: 24, alignment: .trailing)
                        Button {
                            player.play(song, in: songs, allSongIDs: allSongIDs, playlistID: playlistID)
                        } label: {
                            Image(systemName: player.currentSong?.id == song.id && player.isPlaying ? "speaker.wave.2.fill" : "play.fill")
                                .frame(width: 20)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(player.currentSong?.id == song.id ? .red : .secondary)
                        .help("播放")
                        VStack(alignment: .leading, spacing: 2) {
                            SongTitleText(
                                song: song,
                                primaryColor: player.currentSong?.id == song.id
                                    ? .red
                                    : Color(nsColor: .labelColor)
                            )
                                .font(.body.weight(.medium))
                            SongArtistLinks(artists: song.artists) { artist in
                                model.open(.artist(artist.id))
                            }
                            .font(.caption)
                        }
                        Spacer()
                        SongMetadataLink(title: song.album.name, help: "打开专辑 \(song.album.name)") {
                            model.open(.album(song.album.id))
                        }
                        .lineLimit(1)
                        Text(song.durationText)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 42, alignment: .trailing)
                    }
                    .frame(height: 50)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) {
                        player.play(song, in: songs, allSongIDs: allSongIDs, playlistID: playlistID)
                    }
                    .contextMenu {
                        SongContextMenu(
                            song: song,
                            songs: songs,
                            allSongIDs: allSongIDs,
                            playlistID: playlistID,
                            model: model,
                            player: player
                        )
                        if allowsSongRemoval, let playlistID, let library = model.library {
                            Divider()
                            RemoveSongFromPlaylistButton(
                                songID: song.id,
                                playlistID: playlistID,
                                library: library,
                                onRemoved: {
                                    model.songPlaylistMembershipDidChange(
                                        song.id,
                                        playlistID: playlistID,
                                        isFavoritePlaylist: playlistIsFavorite,
                                        containsSong: false
                                    )
                                    model.showToast("已从歌单移除")
                                },
                                onFailed: { model.libraryMessage = "移除失败：\($0)" }
                            )
                        }
                    }
                    Divider().padding(.leading, 36)
                }
                if hasMore {
                    if let loadMoreError {
                        HStack {
                            Label(loadMoreError, systemImage: "exclamationmark.triangle")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Button("重试", action: onLoadMore)
                        }
                        .frame(maxWidth: .infinity, minHeight: 48)
                    } else {
                        LoadMoreTrigger(title: isLoadingMore ? "正在加载更多…" : "继续加载") {
                            onLoadMore()
                        }
                        .id(songs.count)
                    }
                }
            }
        }
    }
}

struct LoadMoreTrigger: View {
    var title = "正在加载更多…"
    let action: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 48)
        .onAppear(perform: action)
    }
}

struct SettingsView: View {
    @Bindable var model: AppModel
    @State private var choosingDownloadFolder = false
    @State private var choosingVideoDownloadFolder = false
    @State private var choosingImageFolder = false
    @State private var choosingSheetFolder = false
    @State private var choosingCacheFolder = false
    @State private var showingClearCacheConfirmation = false
    @State private var musicU = ""
    @State private var isVerifyingMusicU = false
    @State private var musicUError: String?

    var body: AnyView { AnyView(content) }

    private var content: AnyView {
        AnyView(Form {
            if let session = model.session {
                SessionSettingsSections(controller: session, showSuccess: model.showToast)
            }

            Section("外观") {
                Picker("主题", selection: appearanceBinding) {
                    ForEach(Appearance.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 360)
            }

            Section("音质") {
                Picker("默认播放音质", selection: playbackQualityBinding) {
                    ForEach(AudioQuality.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                Picker("视频播放清晰度", selection: videoPlaybackQualityBinding) {
                    ForEach(VideoQuality.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
            }

            Section("下载") {
                Picker("下载音质", selection: downloadQualityBinding) {
                    ForEach(AudioQuality.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                Picker("视频下载清晰度", selection: videoDownloadQualityBinding) {
                    ForEach(VideoQuality.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                LabeledContent("同时下载") {
                    Picker("同时下载", selection: downloadConcurrencyBinding) {
                        ForEach(1...5, id: \.self) { count in
                            Text("\(count) 个任务").tag(count)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 132, alignment: .trailing)
                    .accessibilityLabel("同时进行的下载任务数")
                    .accessibilityValue("\(model.settings.downloadConcurrency) 个任务")
                }
                Text("建议保持 2–3 个任务；较高并发会占用更多带宽，并可能触发服务端限流。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("播放") {
                LabeledContent("歌曲过渡") {
                    HStack(spacing: 10) {
                        Slider(value: crossfadeDurationBinding, in: 0...12, step: 1)
                            .frame(width: 220)
                        Text(model.settings.crossfadeDuration == 0
                             ? "关闭"
                             : "\(Int(model.settings.crossfadeDuration)) 秒")
                            .monospacedDigit()
                            .frame(width: 48, alignment: .trailing)
                    }
                }
            }

            Section("存储") {
                LabeledContent("音频下载位置") {
                    folderControls(path: model.downloadPath, url: model.downloadFolderURL) {
                        choosingDownloadFolder = true
                    }
                }
                LabeledContent("视频下载位置") {
                    folderControls(path: model.videoDownloadPath, url: model.videoDownloadFolderURL) {
                        choosingVideoDownloadFolder = true
                    }
                }
                LabeledContent("图片保存位置") {
                    folderControls(path: model.imagePath, url: model.imageFolderURL) {
                        choosingImageFolder = true
                    }
                }
                LabeledContent("琴谱保存位置") {
                    folderControls(path: model.sheetPath, url: model.sheetFolderURL) {
                        choosingSheetFolder = true
                    }
                }
                LabeledContent("缓存位置") {
                    folderControls(path: model.cachePath, url: model.cacheFolderURL) {
                        choosingCacheFolder = true
                    }
                }
                LabeledContent("缓存") {
                    Button(role: .destructive) {
                        showingClearCacheConfirmation = true
                    } label: {
                        Label("清除缓存", systemImage: "trash")
                    }
                    .accessibilityLabel("清除缓存")
                }
            }

            Section("首页栏目") {
                ForEach(model.homeDescriptors) { descriptor in
                    Toggle(descriptor.title, isOn: sectionBinding(descriptor.id))
                }
            }

            if let session = model.session {
                Section("高级设置") {
                    LabeledContent("MUSIC_U") {
                        SecureField("MUSIC_U", text: $musicU, prompt: Text("输入 MUSIC_U"))
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 420)
                            .disabled(isVerifyingMusicU)
                    }
                    HStack(spacing: 10) {
                        Button {
                            verifyMusicU(with: session)
                        } label: {
                            Label("验证并保存", systemImage: "checkmark.shield")
                        }
                        .disabled(musicU.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isVerifyingMusicU)

                        Button(role: .destructive) {
                            if session.clearMusicU() {
                                musicU = ""
                                musicUError = nil
                                model.showToast("MUSIC_U 已清除")
                            } else {
                                musicUError = "MUSIC_U 清除失败，请重试。"
                            }
                        } label: {
                            Label("清除", systemImage: "trash")
                        }
                        .disabled(isVerifyingMusicU)

                        if isVerifyingMusicU {
                            ProgressView()
                                .controlSize(.small)
                        } else if session.isVIPVerified {
                            Label("已验证", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        }
                    }
                    if let musicUError {
                        Text(musicUError)
                            .font(.callout)
                            .foregroundStyle(.red)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .defaultScrollAnchor(.top)
        .frame(maxWidth: 860)
        .padding(.horizontal, 20)
        .tint(.red)
        .preferredColorScheme(model.settings.appearance.colorScheme)
        .fileImporter(
            isPresented: $choosingDownloadFolder,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            handleFolderSelection(result, apply: model.setDownloadFolder)
        }
        .fileImporter(
            isPresented: $choosingVideoDownloadFolder,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            handleFolderSelection(result, apply: model.setVideoDownloadFolder)
        }
        .fileImporter(
            isPresented: $choosingImageFolder,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            handleFolderSelection(result, apply: model.setImageFolder)
        }
        .fileImporter(
            isPresented: $choosingSheetFolder,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            handleFolderSelection(result, apply: model.setSheetFolder)
        }
        .fileImporter(
            isPresented: $choosingCacheFolder,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            handleFolderSelection(result, apply: model.setCacheFolder)
        }
        .confirmationDialog("清除缓存？", isPresented: $showingClearCacheConfirmation) {
            Button("清除", role: .destructive, action: clearCache)
            Button("取消", role: .cancel) {}
        } message: {
            Text("将删除缓存的音频、视频和封面图片，不会删除已下载的媒体文件。")
        }
        .alert("设置", isPresented: messagePresented) {
            Button("好") { model.settingsMessage = nil }
        } message: {
            Text(model.settingsMessage ?? "")
        })
    }

    private var appearanceBinding: Binding<Appearance> {
        Binding(get: { model.settings.appearance }, set: { model.setAppearance($0) })
    }

    private var downloadQualityBinding: Binding<AudioQuality> {
        Binding(get: { model.settings.quality }, set: { model.setQuality($0) })
    }

    private var downloadConcurrencyBinding: Binding<Int> {
        Binding(
            get: { model.settings.downloadConcurrency },
            set: { model.setDownloadConcurrency($0) }
        )
    }

    private var playbackQualityBinding: Binding<AudioQuality> {
        Binding(get: { model.settings.playbackQuality }, set: { model.setPlaybackQuality($0) })
    }

    private var videoPlaybackQualityBinding: Binding<VideoQuality> {
        Binding(
            get: { model.settings.videoPlaybackQuality },
            set: { model.setVideoPlaybackQuality($0) }
        )
    }

    private var videoDownloadQualityBinding: Binding<VideoQuality> {
        Binding(
            get: { model.settings.videoDownloadQuality },
            set: { model.setVideoDownloadQuality($0) }
        )
    }

    private var crossfadeDurationBinding: Binding<TimeInterval> {
        Binding(get: { model.settings.crossfadeDuration }, set: { model.setCrossfadeDuration($0) })
    }

    private func folderControls(path: String, url: URL, choose: @escaping () -> Void) -> AnyView {
        AnyView(HStack(spacing: 8) {
            Text(path)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .help(path)
            Button {
                openFolder(url)
            } label: {
                Image(systemName: "folder")
            }
            .help("在 Finder 中打开")
            .accessibilityLabel("在 Finder 中打开")
            Button(action: choose) {
                Label("选择…", systemImage: "folder.badge.plus")
            }
        })
    }

    private func handleFolderSelection(
        _ result: Result<[URL], Error>,
        apply: (URL) -> Void
    ) {
        switch result {
        case let .success(urls):
            if let url = urls.first { apply(url) }
        case let .failure(error):
            model.settingsMessage = error.localizedDescription
        }
    }

    private func verifyMusicU(with session: SessionController) {
        musicUError = nil
        isVerifyingMusicU = true
        Task { @MainActor in
            do {
                if try await session.verifyAndSaveMusicU(musicU) {
                    musicU = ""
                    model.showToast("MUSIC_U 已验证并保存")
                } else {
                    musicUError = session.isVIPVerified
                        ? "新 MUSIC_U 验证失败，已保留原来有效的 MUSIC_U。"
                        : "MUSIC_U 无效或对应账号没有有效的音乐包权益。"
                }
            } catch {
                musicUError = session.isVIPVerified
                    ? "验证失败，已保留原来有效的 MUSIC_U：\(error.localizedDescription)"
                    : "验证失败：\(error.localizedDescription)"
            }
            isVerifyingMusicU = false
        }
    }

    private func openFolder(_ url: URL) {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.open(url)
    }

    private func clearCache() {
        ArtworkPipeline.shared.pipeline.cache.removeAll()
        let caches = ["StreamCache", "DownloadCache"].map {
            model.cacheFolderURL.appending(path: $0, directoryHint: .isDirectory)
        }
        do {
            for cache in caches where FileManager.default.fileExists(atPath: cache.path) {
                try FileManager.default.removeItem(at: cache)
            }
            model.showToast("缓存已清除")
        } catch {
            model.settingsMessage = "清除缓存失败：\(error.localizedDescription)"
        }
    }

    private func sectionBinding(_ id: String) -> Binding<Bool> {
        Binding(
            get: { model.settings.homeSectionIDs.contains(id) },
            set: { model.setHomeSection(id, enabled: $0) }
        )
    }

    private var messagePresented: Binding<Bool> {
        Binding(
            get: { model.settingsMessage != nil },
            set: { if !$0 { model.settingsMessage = nil } }
        )
    }
}

private struct PlayerBar: View {
    @Bindable var model: AppModel
    @Bindable var player: PlayerController
    let openNowPlaying: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 12) {
            Button(action: openNowPlaying) {
                HStack(spacing: 10) {
                    ArtworkView(
                        artwork: player.currentSong?.album.artwork ?? Artwork(symbol: "music.note", accent: .red),
                        highResolution: true
                    )
                        .frame(width: 56, height: 56)
                    VStack(alignment: .leading, spacing: 3) {
                        currentSongTitle
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        Text(player.currentSong?.artistsDisplay ?? "从发现或搜索中选择歌曲")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.up")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)
            .disabled(player.currentSong == nil)
            .frame(width: 210)
            .contentShape(Rectangle())
            .help("打开歌曲详情")
            .accessibilityLabel("打开歌曲详情")

            PlaybackControls(player: player)
                .frame(minWidth: 230, idealWidth: 320, maxWidth: 380)

            currentLyric
                .frame(minWidth: 0, idealWidth: 220, maxWidth: 300)

            HStack(spacing: 0) {
                if let song = player.currentSong {
                    if !song.isPodcastEpisode {
                        PlayerIconButton(
                            symbol: model.likedSongIDs.contains(song.id) ? "heart.fill" : "heart",
                            label: model.likedSongIDs.contains(song.id) ? "取消喜欢" : "喜欢",
                            isActive: model.likedSongIDs.contains(song.id)
                        ) {
                            model.toggleSongLiked(song.id)
                        }

                        CommentButton(songID: song.id, library: model.library) {
                            model.open(.comments(song.id))
                        }
                    }

                    PlayerIconButton(
                        symbol: "text.badge.plus",
                        label: "添加到歌单",
                        isDisabled: model.currentUserID == nil
                    ) {
                        model.showAddToPlaylist(for: song)
                    }

                    if let downloads = model.downloads {
                        DownloadControl(manager: downloads, song: song) { model.download(song) }
                    }
                }
                PlayerIconButton(
                    symbol: "person.2.fill",
                    label: model.listenTogether?.isConnected == true ? "一起听，已连接" : "一起听",
                    isActive: model.listenTogether?.room != nil,
                    isDisabled: model.currentUserID == nil || model.listenTogether == nil
                ) {
                    model.isListenTogetherPresented = true
                }
                PlayerIconButton(
                    symbol: player.volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill",
                    label: player.volume == 0 ? "取消静音" : "静音"
                ) {
                    player.toggleMute()
                }
                Slider(value: $player.volume, in: 0...1)
                    .frame(width: 72)
                    .accessibilityLabel("音量")
            }
            .padding(.leading, 6)
            .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
    }

    @ViewBuilder
    private var currentSongTitle: some View {
        if let song = player.currentSong {
            SongTitleText(song: song)
        } else {
            Text("尚未播放")
        }
    }

    @ViewBuilder
    private var currentLyric: some View {
        ZStack {
            if case let .failed(_, message) = player.state {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline)
                    .foregroundStyle(.red)
                    .lineLimit(2)
                    .help(message)
                    .id("playback-error")
            } else if let message = player.playbackReportErrorMessage {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .help(message)
                    .accessibilityLabel(message)
                    .id("playback-report-error")
            } else if let line = player.currentLyric ?? player.lyrics.first {
                VStack(spacing: 2) {
                    Text(line.text)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(2)
                    if let translation = line.translation {
                        Text(translation)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .multilineTextAlignment(.center)
                .help([line.text, line.translation].compactMap { $0 }.joined(separator: "\n"))
                .id(line.id)
                .transition(.opacity)
            } else if player.isLoadingLyrics {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("正在加载歌词")
                    .id("lyric-loading")
            } else {
                Text(player.currentSong == nil ? "尚未播放" : "暂无歌词")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .id("lyric-empty")
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: player.currentLyric?.id)
    }
}

struct DownloadControl: View {
    @Bindable var manager: MusicDownloadManager
    let songID: Int64
    let start: () -> Void

    init(manager: MusicDownloadManager, song: Song, start: @escaping () -> Void) {
        self.manager = manager
        songID = song.id
        self.start = start
    }

    init(manager: MusicDownloadManager, songID: Int64, start: @escaping () -> Void) {
        self.manager = manager
        self.songID = songID
        self.start = start
    }

    var body: some View {
        Button {
            switch manager.states[songID] {
            case .queued, .running:
                manager.pause(songID: songID)
            case .paused:
                manager.retry(songID: songID)
            default:
                start()
            }
        } label: {
            switch manager.states[songID] {
            case let .running(progress):
                if let progress {
                    ProgressView(value: progress)
                        .frame(width: 22)
                } else {
                    ProgressView()
                        .controlSize(.small)
                }
            case .completed:
                Image(systemName: "checkmark.circle.fill")
            case .failed:
                Image(systemName: "exclamationmark.circle")
            case .queued:
                ProgressView()
                    .controlSize(.small)
            case .paused:
                Image(systemName: "play.circle")
            case .cancelled, .none:
                Image(systemName: "arrow.down.circle")
            }
        }
        .buttonStyle(.plain)
        .frame(width: 32, height: 32)
        .contentShape(Rectangle())
        .help(downloadHelp)
        .accessibilityLabel(downloadHelp)
    }

    private var downloadHelp: String {
        switch manager.states[songID] {
        case .running:
            (manager.retryAttempts[songID] ?? 0) > 0 ? "暂停正在重试的下载" : "暂停下载"
        case let .paused(progress):
            progress.map { "继续下载，已完成 \(Int($0 * 100))%" } ?? "继续下载"
        case .completed: "已下载"
        case let .failed(message): "下载失败：\(message)"
        case .queued: "暂停等待中的下载"
        case .cancelled, .none: "下载"
        }
    }
}

struct PlayerIconButton: View {
    let symbol: String
    let label: String
    var isActive = false
    var isDisabled = false
    var badge: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .topTrailing) {
                Image(systemName: symbol)
                    .frame(width: 32, height: 32)
                    .background(isActive ? Color.red.opacity(0.12) : .clear, in: Circle())
                if let badge {
                    Text(badge)
                        .font(.system(size: 9, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4)
                        .frame(minWidth: 14, minHeight: 14)
                        .background(Color.red, in: Capsule())
                        .fixedSize()
                        .offset(x: 3, y: -2)
                }
            }
            .frame(width: badge == nil ? 32 : 42, height: 34)
        }
        .buttonStyle(.plain)
        .foregroundStyle(isActive ? Color.red : Color.secondary)
        .contentShape(Rectangle())
        .disabled(isDisabled)
        .help(label)
        .accessibilityLabel(label)
        .accessibilityValue(isActive ? "已开启" : "")
    }
}

struct CommentButton: View {
    let songID: Int64
    let library: LiveMusicLibrary?
    let action: () -> Void

    @State private var commentCount: MusicCommentCount?

    var body: some View {
        PlayerIconButton(
            symbol: "bubble.left",
            label: commentCount.map { "查看评论，共\($0.count)条" } ?? "查看评论",
            badge: commentCount.map {
                $0.displayText.isEmpty ? CommentCountFormatter.string($0.count) : $0.displayText
            }
        ) {
            action()
        }
        .task(id: songID) {
            commentCount = nil
            guard let library else { return }
            commentCount = try? await library.commentCount(songID: songID)
        }
    }
}

enum CommentCountFormatter {
    static func string(_ count: Int) -> String {
        count < 10_000 ? String(count) : "\(count / 10_000)w+"
    }
}

struct ArtworkView: View {
    let artwork: Artwork
    var highResolution = false
    var saveTitle: String?
    var saveAction: ((URL, String) -> Void)?

    var body: some View {
        Group {
            if let url = imageURL {
                CachedAsyncImage(url: url) { phase in
                    switch phase {
                    case let .success(image):
                        image.resizable().scaledToFill()
                    case .empty, .failure:
                        placeholder
                    }
                }
            } else {
                placeholder
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .clipped()
        .contextMenu {
            if let url = imageURL, let saveTitle, let saveAction {
                Button {
                    saveAction(url, saveTitle)
                } label: {
                    Label("保存图片", systemImage: "square.and.arrow.down")
                }
            }
        }
    }

    private var imageURL: URL? {
        guard let url = artwork.remoteURL else { return nil }
        return highResolution ? ArtworkURLPolicy.highResolutionURL(for: url) : url
    }

    private var placeholder: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7)
                .fill(
                    LinearGradient(
                        colors: [artwork.accent.color.opacity(0.78), artwork.accent.color.opacity(0.28)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            Image(systemName: artwork.symbol)
                .font(.system(size: 32, weight: .medium))
                .foregroundStyle(.white.opacity(0.92))
        }
    }
}

struct InteractionToast: View {
    let message: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if let message {
                Label(message, systemImage: "checkmark.circle.fill")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 16)
                    .frame(height: 38)
                    .background(.regularMaterial, in: Capsule())
                    .overlay { Capsule().stroke(.primary.opacity(0.1), lineWidth: 1) }
                    .shadow(color: .black.opacity(0.16), radius: 10, y: 4)
                    .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: message)
        .allowsHitTesting(false)
    }
}
