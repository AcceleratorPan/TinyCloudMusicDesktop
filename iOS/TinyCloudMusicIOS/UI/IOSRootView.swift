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
        .safeAreaInset(edge: .bottom, spacing: 0) {
            IOSMiniPlayer(player: player) { showingNowPlaying = true }
        }
        .tint(.red)
        .preferredColorScheme(model.settings.appearance.iosColorScheme)
        .overlay(alignment: .top) {
            if container.isStarting {
                ProgressView("正在准备音乐库")
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.top, 8)
            } else if let message = model.interactionMessage {
                Text(message)
                    .font(.callout.weight(.medium))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.top, 8)
                    .accessibilityLabel(message)
            }
        }
        .fullScreenCover(isPresented: $showingNowPlaying) {
            IOSNowPlayingView(model: model, player: player) { route in
                showingNowPlaying = false
                model.open(route)
            }
        }
        .sheet(item: $model.playlistPickerSong) { song in
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
            }
        }
        .sheet(isPresented: $model.isListenTogetherPresented) {
            if let controller = model.listenTogether {
                IOSListenTogetherView(controller: controller, player: player)
            } else {
                ContentUnavailableView("一起听不可用", systemImage: "person.2.slash")
                    .presentationDetents([.medium])
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
                await model.refreshAccountState()
                guard sessionIdentity == identity else { return }
                model.loadHome()
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
        .onChange(of: listenTogetherPhase) { _, phase in
            guard let phase, case .recoveryAvailable = phase else { return }
            model.isListenTogetherPresented = true
        }
        .onChange(of: player.playbackReportErrorMessage) { _, message in
            guard let message else { return }
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
        NavigationStack(path: pathBinding(for: tab)) {
            content()
                .navigationDestination(for: Route.self) {
                    IOSRouteDestinationView(route: $0, model: model, player: player)
                }
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

    private var sessionIdentity: IOSSessionIdentity? {
        model.session.map { IOSSessionIdentity(state: $0.state, credentialRevision: $0.credentialRevision) }
    }

    private var cacheConfiguration: IOSCacheConfiguration {
        IOSCacheConfiguration(
            quality: model.settings.playbackQuality,
            root: model.cacheFolderURL.standardizedFileURL,
            revision: model.cacheConfigurationRevision
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
    let revision: UInt64
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
    @State private var operationError: String?

    var body: some View {
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
                case let .loaded(playlists):
                    if playlists.isEmpty {
                        ContentUnavailableView(
                            "没有可用歌单",
                            systemImage: "music.note.list",
                            description: Text("创建歌单后可将这首歌添加进去")
                        )
                    } else {
                        List(playlists) { item in
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
        .task(id: retryRevision) { await load() }
    }

    private var credentialRevision: UInt64 { library.transport.credentialSnapshotValue().revision }

    private var isAdding: Bool {
        model.pendingMutations.contains {
            guard case let .playlistSong(_, songID) = $0 else { return false }
            return songID == song.id
        }
    }

    private func load() async {
        let revision = credentialRevision
        guard model.currentUserID == userID else { return }
        phase = .loading
        do {
            var offset = 0
            var values: [MusicAvailablePlaylist] = []
            var seen = Set<Int64>()
            while true {
                let page = try await extras.availablePlaylists(
                    userID: userID,
                    trackID: song.id,
                    offset: offset,
                    expectedCredentialRevision: revision
                )
                try Task.checkCancellation()
                guard model.currentUserID == userID, credentialRevision == revision else { return }
                let fresh = page.playlists.filter { seen.insert($0.id).inserted }
                values.append(contentsOf: fresh)
                phase = .loaded(values)
                guard page.hasMore, page.offset > offset, !fresh.isEmpty else { return }
                offset = page.offset
            }
        } catch is CancellationError {
        } catch {
            guard model.currentUserID == userID, credentialRevision == revision else { return }
            phase = .failed(error.localizedDescription)
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
        case loaded([MusicAvailablePlaylist])
        case failed(String)
    }
}
