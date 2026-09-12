import SwiftUI
import UIKit

enum IOSMainTab: String, CaseIterable, Identifiable {
    case discover
    case search
    case library
    case media
    case account

    var id: Self { self }

    var title: String {
        switch self {
        case .discover: "发现"
        case .search: "搜索"
        case .library: "音乐库"
        case .media: "媒体"
        case .account: "我的"
        }
    }

    var symbol: String {
        switch self {
        case .discover: "sparkles"
        case .search: "magnifyingglass"
        case .library: "music.note.list"
        case .media: "play.rectangle.on.rectangle"
        case .account: "person.crop.circle"
        }
    }
}

struct IOSRootView: View {
    @Bindable var container: IOSAppContainer
    @Environment(\.dynamicTypeSize) private var systemDynamicTypeSize
    @State private var selection = IOSMainTab.discover
    @State private var tabPaths: [IOSMainTab: [Route]] = [:]
    @State private var showingNowPlaying = false

    private var model: AppModel { container.model }
    private var player: PlayerController { container.player }

    var body: some View {
        @Bindable var model = container.model
        TabView(selection: $selection) {
            navigationStack(for: .discover) {
                IOSDiscoverView(model: model, player: player)
            }
            .tag(IOSMainTab.discover)
            .tabItem { Label(IOSMainTab.discover.title, systemImage: IOSMainTab.discover.symbol) }

            navigationStack(for: .search) {
                IOSSearchView(model: model, player: player)
            }
            .tag(IOSMainTab.search)
            .tabItem { Label(IOSMainTab.search.title, systemImage: IOSMainTab.search.symbol) }

            navigationStack(for: .library) {
                IOSLibraryView(container: container)
            }
            .tag(IOSMainTab.library)
            .tabItem { Label(IOSMainTab.library.title, systemImage: IOSMainTab.library.symbol) }

            navigationStack(for: .media) {
                IOSMediaView(container: container)
            }
            .tag(IOSMainTab.media)
            .tabItem { Label(IOSMainTab.media.title, systemImage: IOSMainTab.media.symbol) }

            navigationStack(for: .account) {
                IOSAccountView(container: container)
            }
            .tag(IOSMainTab.account)
            .tabItem { Label(IOSMainTab.account.title, systemImage: IOSMainTab.account.symbol) }
        }
        .tint(.red)
        .preferredColorScheme(model.settings.appearance.iosColorScheme)
        .overlay(alignment: .top) {
            if container.isStarting {
                ProgressView("正在准备音乐库")
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.top, 44)
                    .safeAreaPadding(.top, 8)
            } else {
                IOSInteractionToast(message: model.interactionMessage)
                    .padding(.top, 44)
                    .safeAreaPadding(.top, 8)
            }
        }
        .fullScreenCover(isPresented: $showingNowPlaying) {
            IOSNowPlayingView(model: model, player: player) { route in
                showingNowPlaying = false
                model.open(route)
            }
            .sheet(item: $model.playlistPickerSong) { playlistPicker(for: $0) }
            .environment(\.dynamicTypeSize, systemDynamicTypeSize)
        }
        .sheet(item: rootPlaylistPickerSong) { playlistPicker(for: $0) }
        .sheet(isPresented: $model.isListenTogetherPresented) {
            if let controller = model.listenTogether {
                IOSListenTogetherView(controller: controller, player: player)
            } else {
                ContentUnavailableView("一起听不可用", systemImage: "person.2.slash")
                    .presentationDetents([.medium])
                    .presentationDragIndicator(.visible)
            }
        }
        .task { await container.start() }
        .onChange(of: sessionIdentity) { _, identity in
            guard !container.isStarting else { return }
            tabPaths.removeAll()
            if !model.path.isEmpty { model.path.removeAll() }
            if let identity {
                player.setAccountCredentialRevision(identity.credentialRevision)
                model.invalidateAccountDomainIfNeeded(forCredentialRevision: identity.credentialRevision)
            }
            Task {
                await model.refreshAccountState {
                    guard sessionIdentity == identity else { return }
                    model.loadHome()
                }
            }
        }
        .onChange(of: model.path) { _, path in
            guard tabPaths[selection, default: []] != path else { return }
            tabPaths[selection] = path
        }
        .onChange(of: selection) { _, tab in
            let path = tabPaths[tab, default: []]
            if model.path != path { model.path = path }
        }
        .onChange(of: cacheConfiguration, initial: true) { _, configuration in
            player.configure(playbackQuality: configuration.quality, cacheRoot: configuration.root)
            ArtworkPipeline.shared.configure(cacheRoot: configuration.root)
        }
        .onChange(of: model.settings.crossfadeDuration) { _, value in
            player.setCrossfadeDuration(value)
        }
        .onChange(of: model.settings.playbackControlFadeEnabled) { _, enabled in
            player.setPlaybackControlFadeEnabled(enabled)
        }
        .onChange(of: listenTogetherPhase) { _, phase in
            guard let phase, case .recoveryAvailable = phase else { return }
            model.isListenTogetherPresented = true
        }
        .onChange(of: player.playbackReportErrorMessage) { _, message in
            guard let message else { return }
            UIAccessibility.post(notification: .announcement, argument: message)
        }
        .onChange(of: player.playbackQualityConfirmationMessage) { _, message in
            guard let message else { return }
            model.showToast(message)
            UIAccessibility.post(notification: .announcement, argument: message)
        }
        .alert("启动失败", isPresented: startupErrorPresented) {
            if container.canRetryAudioSession {
                Button("重试音频") { container.retryAudioSession() }
            }
            Button("关闭") { container.dismissStartupError() }
        } message: {
            Text(container.startupError ?? "")
        }
        .alert("操作失败", isPresented: libraryErrorPresented) {
            Button("好") { model.libraryMessage = nil }
        } message: {
            Text(model.libraryMessage ?? "")
        }
        .alert("设置失败", isPresented: settingsErrorPresented) {
            Button("好") { model.settingsMessage = nil }
        } message: {
            Text(model.settingsMessage ?? "")
        }
    }

    private func navigationStack<Content: View>(
        for tab: IOSMainTab,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(spacing: 0) {
            NavigationStack(path: pathBinding(for: tab)) {
                content()
                    .navigationDestination(for: Route.self) {
                        IOSRouteDestinationView(route: $0, model: model, player: player)
                    }
            }
            IOSMiniPlayer(player: player) { showingNowPlaying = true }
        }
    }

    private func pathBinding(for tab: IOSMainTab) -> Binding<[Route]> {
        Binding(
            get: { tabPaths[tab, default: []] },
            set: { path in
                tabPaths[tab] = path
                if selection == tab, model.path != path { model.path = path }
            }
        )
    }

    private var rootPlaylistPickerSong: Binding<Song?> {
        Binding(
            get: { showingNowPlaying ? nil : model.playlistPickerSong },
            set: { model.playlistPickerSong = $0 }
        )
    }

    @ViewBuilder
    private func playlistPicker(for song: Song) -> some View {
        if let userID = model.currentUserID,
           let extras = model.extras,
           let library = model.library {
            IOSAddSongToPlaylistView(
                song: song,
                userID: userID,
                extras: extras,
                library: library,
                model: model
            )
        } else {
            ContentUnavailableView("需要登录", systemImage: "person.crop.circle.badge.exclamationmark")
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
        }
    }

    private var sessionIdentity: IOSSessionIdentity? {
        model.session.map { IOSSessionIdentity(state: $0.state, credentialRevision: $0.credentialRevision) }
    }

    private var cacheConfiguration: IOSCacheConfiguration {
        IOSCacheConfiguration(
            quality: model.settings.playbackQuality,
            root: model.cacheFolderURL.standardizedFileURL
        )
    }

    private var listenTogetherPhase: ListenTogetherPhase? { model.listenTogether?.phase }

    private var startupErrorPresented: Binding<Bool> {
        Binding(
            get: { container.startupError != nil },
            set: { if !$0 { container.dismissStartupError() } }
        )
    }

    private var libraryErrorPresented: Binding<Bool> {
        Binding(get: { model.libraryMessage != nil }, set: { if !$0 { model.libraryMessage = nil } })
    }

    private var settingsErrorPresented: Binding<Bool> {
        Binding(get: { model.settingsMessage != nil }, set: { if !$0 { model.settingsMessage = nil } })
    }
}

private struct IOSSessionIdentity: Equatable {
    let state: SessionState
    let credentialRevision: UInt64
}

private struct IOSCacheConfiguration: Equatable {
    let quality: AudioQuality
    let root: URL
}

private struct IOSAddSongToPlaylistView: View {
    let song: Song
    let userID: Int64
    let extras: LiveMusicExtras
    let library: LiveMusicLibrary
    @Bindable var model: AppModel

    @Environment(\.dismiss) private var dismiss
    @State private var phase = Phase.loading
    @State private var retryRevision = 0
    @State private var loadMoreRetryRevision = 0
    @State private var loadMoreOwner: LoadMoreIdentity?
    @State private var loadMoreError: String?
    @State private var operationError: String?

    var body: some View {
        let initialTaskIdentity = initialLoadIdentity
        NavigationStack {
            Group {
                switch phase {
                case .loading:
                    ProgressView("正在加载可用歌单")
                case let .failed(message):
                    ContentUnavailableView {
                        Label("歌单加载失败", systemImage: "wifi.exclamationmark")
                    } description: {
                        Text(message)
                    } actions: {
                        Button("重试") { retryRevision += 1 }
                    }
                case let .loaded(page):
                    if page.playlists.isEmpty {
                        ContentUnavailableView(
                            "没有可用歌单",
                            systemImage: "music.note.list",
                            description: Text("创建歌单后可将这首歌添加进去")
                        )
                    } else {
                        List {
                            ForEach(page.playlists) { item in
                                Button { add(to: item) } label: {
                                    HStack(spacing: 12) {
                                        IOSArtworkView(
                                            artwork: Artwork(
                                                symbol: "music.note.list",
                                                accent: .red,
                                                remoteURL: item.playlist.coverURL
                                            ),
                                            cornerRadius: 6
                                        )
                                        .frame(width: 44, height: 44)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(item.playlist.name).foregroundStyle(.primary).lineLimit(1)
                                            Text("\(item.playlist.trackCount) 首 · \(item.playlist.creatorName)")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                        }
                                        Spacer()
                                        Image(systemName: item.containsTrack ? "checkmark.circle.fill" : "plus.circle")
                                            .foregroundStyle(item.containsTrack ? Color.secondary : Color.red)
                                    }
                                    .frame(minHeight: 52)
                                }
                                .disabled(item.containsTrack || isAdding)
                                .accessibilityLabel(item.containsTrack ? "\(item.playlist.name)，已包含" : "添加到\(item.playlist.name)")
                            }
                            if page.hasMore { loadMoreFooter }
                        }
                        .refreshable { retryRevision &+= 1 }
                    }
                }
            }
            .navigationTitle("添加到歌单")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("取消") { dismiss() }.disabled(isAdding) }
            .safeAreaInset(edge: .bottom) {
                if let operationError {
                    Label(operationError, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .padding()
                        .frame(maxWidth: .infinity)
                        .background(.bar)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .task(id: initialTaskIdentity) {
            await loadInitialPage(initialTaskIdentity)
        }
    }

    private var credentialRevision: UInt64 {
        if let session = model.session {
            _ = session.state
            return session.credentialRevision
        }
        return library.transport.credentialSnapshotValue().revision
    }

    private var isAdding: Bool {
        model.pendingMutations.contains {
            guard case let .playlistSong(_, songID) = $0 else { return false }
            return songID == song.id
        }
    }

    private var initialLoadIdentity: LoadIdentity {
        LoadIdentity(
            userID: userID,
            trackID: song.id,
            credentialRevision: credentialRevision,
            retryRevision: retryRevision
        )
    }

    private var loadMoreIdentity: LoadMoreIdentity {
        LoadMoreIdentity(load: initialLoadIdentity, retryRevision: loadMoreRetryRevision)
    }

    private var isLoadingMore: Bool { loadMoreOwner != nil }

    private var loadMoreFooter: some View {
        let loadMoreTaskIdentity = loadMoreIdentity
        return VStack(spacing: 8) {
            if let loadMoreError {
                IOSInlineRetry(message: loadMoreError) { loadMoreRetryRevision &+= 1 }
            } else if isLoadingMore {
                ProgressView("正在加载更多歌单")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 60)
            } else {
                Button {
                    loadMoreRetryRevision &+= 1
                } label: {
                    Label("加载更多歌单", systemImage: "arrow.down.circle")
                }
                .frame(maxWidth: .infinity, minHeight: 60)
            }
        }
        .task(id: loadMoreTaskIdentity) {
            await loadNextPage(loadMoreTaskIdentity)
        }
    }

    private func loadInitialPage(_ identity: LoadIdentity) async {
        guard identity == initialLoadIdentity, model.currentUserID == identity.userID else { return }
        phase = .loading
        loadMoreOwner = nil
        loadMoreError = nil
        do {
            let page = try await extras.availablePlaylists(
                userID: identity.userID,
                trackID: identity.trackID,
                offset: 0,
                expectedCredentialRevision: identity.credentialRevision
            )
            try Task.checkCancellation()
            guard identity == initialLoadIdentity, model.currentUserID == identity.userID else { return }
            phase = .loaded(
                MusicAvailablePlaylistPage(playlists: [], offset: 0, hasMore: true).appending(page)
            )
        } catch is CancellationError {
        } catch {
            guard !Task.isCancelled,
                  identity == initialLoadIdentity,
                  model.currentUserID == identity.userID
            else { return }
            phase = .failed(error.localizedDescription)
        }
    }

    private func loadNextPage(_ identity: LoadMoreIdentity) async {
        guard identity == loadMoreIdentity,
              model.currentUserID == identity.load.userID,
              case let .loaded(page) = phase,
              page.hasMore,
              loadMoreOwner != identity
        else { return }
        let offset = page.offset
        loadMoreOwner = identity
        loadMoreError = nil
        defer {
            if loadMoreOwner == identity { loadMoreOwner = nil }
        }
        do {
            let next = try await extras.availablePlaylists(
                userID: identity.load.userID,
                trackID: identity.load.trackID,
                offset: offset,
                expectedCredentialRevision: identity.load.credentialRevision
            )
            try Task.checkCancellation()
            guard loadMoreOwner == identity,
                  identity == loadMoreIdentity,
                  model.currentUserID == identity.load.userID,
                  case let .loaded(current) = phase,
                  current.offset == offset
            else { return }
            phase = .loaded(current.appending(next))
        } catch is CancellationError {
        } catch {
            guard !Task.isCancelled,
                  loadMoreOwner == identity,
                  identity == loadMoreIdentity,
                  model.currentUserID == identity.load.userID,
                  case let .loaded(current) = phase,
                  current.offset == offset
            else { return }
            loadMoreError = error.localizedDescription
        }
    }

    private func add(to item: MusicAvailablePlaylist) {
        operationError = nil
        model.addSongToPlaylist(
            song.id,
            playlistID: item.id,
            isFavoritePlaylist: item.playlist.specialType == 5,
            onFailure: { operationError = $0 }
        )
    }

    private enum Phase: Equatable {
        case loading
        case loaded(MusicAvailablePlaylistPage)
        case failed(String)
    }

    private struct LoadIdentity: Equatable {
        let userID: Int64
        let trackID: Int64
        let credentialRevision: UInt64
        let retryRevision: Int
    }

    private struct LoadMoreIdentity: Equatable {
        let load: LoadIdentity
        let retryRevision: Int
    }
}
