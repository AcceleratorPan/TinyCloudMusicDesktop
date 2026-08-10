import SwiftUI
import UIKit
import UniformTypeIdentifiers

private enum IOSLibraryPhase: Equatable {
    case loading
    case loggedOut
    case loaded
    case failed(String)
}

private enum IOSLibrarySection: String, CaseIterable, Identifiable {
    case overview = "概览"
    case dailyRecommendations = "每日推荐"
    case playlists = "歌单"
    case following = "关注"

    var id: Self { self }
}

struct IOSLibraryView: View {
    @Bindable private var model: AppModel
    @Bindable private var player: PlayerController
    private let library: LiveMusicLibrary?
    private let extras: LiveMusicExtras?
    @State private var phase: IOSLibraryPhase = .loading
    @State private var progressiveSnapshot: LibrarySnapshot?
    @State private var section = IOSLibrarySection.overview

    init(container: IOSAppContainer) {
        model = container.model
        player = container.player
        library = container.model.library
        extras = container.model.extras
    }

    var body: some View {
        Group {
            if let snapshot = progressiveSnapshot ?? model.librarySnapshot {
                libraryList(snapshot)
            } else {
                phaseContent
            }
        }
        .navigationTitle("音乐库")
        .task(id: loadIdentity) { await load(force: false) }
    }

    private var loadIdentity: String {
        let revision = library?.transport.credentialSnapshotValue().revision ?? 0
        return "\(model.currentUserID ?? 0):\(revision)"
    }

    @ViewBuilder
    private var phaseContent: some View {
        switch phase {
        case .loading, .loaded:
            IOSLibraryLoadingView(title: "正在载入音乐库")
        case .loggedOut:
            ContentUnavailableView(
                "登录后查看音乐库",
                systemImage: "person.crop.circle.badge.exclamationmark",
                description: Text("请前往“我的”完成登录。")
            )
        case let .failed(message):
            IOSLibraryFailureView(title: "无法载入音乐库", message: message) {
                Task { await load(force: true) }
            }
        }
    }

    private func libraryList(_ snapshot: LibrarySnapshot) -> some View {
        VStack(spacing: 0) {
            Picker("音乐库内容", selection: $section) {
                ForEach(IOSLibrarySection.allCases) { section in
                    Text(section.rawValue).tag(section)
                }
            }
            .pickerStyle(.segmented)
            .padding()

            Divider()

            TabView(selection: $section) {
                ForEach(IOSLibrarySection.allCases) { section in
                    libraryPage(snapshot, section: section)
                        .tag(section)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
        }
    }

    private func libraryPage(_ snapshot: LibrarySnapshot, section: IOSLibrarySection) -> some View {
        List {
            switch section {
            case .overview:
                profileSection(snapshot)
                commonFeaturesSection(snapshot)
            case .dailyRecommendations:
                dailyRecommendationsSection(snapshot)
            case .playlists:
                playlistsSection(snapshot)
            case .following:
                if snapshot.following.isEmpty && snapshot.recommendedUsers.isEmpty {
                    Section {
                        IOSLibraryEmptyRow(title: "暂无关注内容", symbol: "person.2")
                    }
                } else {
                    followingSection(snapshot)
                    recommendedUsersSection(snapshot)
                }
            }
        }
        .listStyle(.insetGrouped)
        .refreshable { await load(force: true) }
    }

    private func profileSection(_ snapshot: LibrarySnapshot) -> some View {
        Section {
            HStack(spacing: 14) {
                IOSRemoteArtwork(url: snapshot.user.avatarURL, symbol: "person.crop.circle.fill", circular: true)
                    .frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 4) {
                    Text(snapshot.user.nickname)
                        .font(.title3.weight(.semibold))
                    if !snapshot.user.signature.isEmpty {
                        Text(snapshot.user.signature)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    Text("Level \(snapshot.user.level) · 听过 \(snapshot.user.listenedSongCount.formatted()) 首")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 6)

            NavigationLink(value: Route.user(snapshot.user.id)) {
                Label("个人主页", systemImage: "person.crop.circle")
            }
        }
    }

    private func commonFeaturesSection(_ snapshot: LibrarySnapshot) -> some View {
        Section("常用功能") {
            if let favorites = snapshot.playlists.first(where: { $0.specialType == 5 }) {
                NavigationLink(value: Route.playlist(favorites.id)) {
                    Label("我喜欢的音乐", systemImage: "heart.fill")
                }
            }
            NavigationLink {
                IOSSubscribedAlbumsView(model: model)
            } label: {
                Label("已收藏专辑", systemImage: "square.stack.fill")
            }
            NavigationLink(value: Route.cloudMusic) {
                Label("音乐云盘", systemImage: "externaldrive")
            }
            NavigationLink(value: Route.recommendationHistory) {
                Label("历史日推", systemImage: "calendar")
            }
            NavigationLink(value: Route.listeningFootprints) {
                Label("听歌足迹", systemImage: "chart.line.uptrend.xyaxis")
            }
            NavigationLink {
                IOSRecentPlaybackView(model: model, player: player)
            } label: {
                Label("最近播放", systemImage: "clock.arrow.circlepath")
            }
            if let downloads = model.downloads {
                NavigationLink {
                    IOSDownloadsView(manager: downloads)
                } label: {
                    Label("下载管理", systemImage: "arrow.down.circle")
                }
            }
            if let songID = player.currentSong?.id {
                NavigationLink(value: Route.comments(songID)) {
                    Label("当前歌曲评论", systemImage: "bubble.left")
                }
            }
            Button {
                model.isListenTogetherPresented = true
            } label: {
                Label("一起听", systemImage: "person.2.wave.2")
            }
            .disabled(model.currentUserID == nil || model.listenTogether == nil)
        }
    }

    private func dailyRecommendationsSection(_ snapshot: LibrarySnapshot) -> some View {
        Section {
            if snapshot.songs.isEmpty {
                IOSLibraryEmptyRow(title: "今天暂无推荐", symbol: "music.note")
            } else {
                Button {
                    guard let first = snapshot.songs.first else { return }
                    player.play(first, in: snapshot.songs)
                } label: {
                    Label("播放全部", systemImage: "play.fill")
                }
                .tint(.red)
                ForEach(snapshot.songs) { song in
                    IOSSongRow(song: song, songs: snapshot.songs, model: model, player: player)
                }
            }
        } header: {
            HStack {
                Text("今日推荐")
                Spacer()
                Text(snapshot.songs.count.formatted())
            }
        }
    }

    private func playlistsSection(_ snapshot: LibrarySnapshot) -> some View {
        Section {
            NavigationLink {
                IOSPlaylistManagerView(model: model, library: library, userID: snapshot.user.id)
            } label: {
                Label("管理我的歌单", systemImage: "slider.horizontal.3")
            }
            if snapshot.playlists.isEmpty {
                IOSLibraryEmptyRow(title: "暂无歌单", symbol: "music.note.list")
            } else {
                ForEach(snapshot.playlists) { playlist in
                    NavigationLink(value: Route.playlist(playlist.id)) {
                        IOSPlaylistLabel(playlist: playlist)
                    }
                }
            }
        } header: {
            Text("歌单")
        }
    }

    @ViewBuilder
    private func followingSection(_ snapshot: LibrarySnapshot) -> some View {
        if !snapshot.following.isEmpty {
            Section("关注") {
                ForEach(snapshot.following) { follow in
                    IOSFollowingRow(follow: follow)
                }
            }
        }
    }

    @ViewBuilder
    private func recommendedUsersSection(_ snapshot: LibrarySnapshot) -> some View {
        if !snapshot.recommendedUsers.isEmpty {
            Section("推荐关注") {
                ForEach(snapshot.recommendedUsers) { user in
                    IOSRecommendedUserRow(user: user)
                }
            }
        }
    }

    @MainActor
    private func load(force: Bool) async {
        guard let library, let extras else {
            phase = .failed("音乐库服务不可用")
            return
        }
        let revision = library.transport.credentialSnapshotValue().revision
        if !force, let snapshot = model.librarySnapshot, snapshot.user.id == model.currentUserID {
            progressiveSnapshot = nil
            phase = .loaded
            return
        }
        let playlistRevision = model.playlistContentRevision
        progressiveSnapshot = nil
        if model.librarySnapshot == nil { phase = .loading }
        do {
            let login = try await library.loginState(
                forceRefresh: force,
                expectedCredentialRevision: revision
            )
            try Task.checkCancellation()
            guard case let .loggedIn(user) = login else {
                model.librarySnapshot = nil
                phase = .loggedOut
                return
            }
            async let songs = library.dailyRecommendations(
                forceRefresh: force,
                expectedCredentialRevision: revision
            )
            async let following = library.myFollowing(
                forceRefresh: force,
                expectedCredentialRevision: revision,
                onUpdate: { values in
                    publishLibraryProgress(
                        user: user,
                        revision: revision,
                        playlistRevision: playlistRevision,
                        following: values
                    )
                }
            )
            let playlists: [Playlist]
            if force {
                playlists = try await library.userPlaylists(
                    userID: user.id,
                    forceRefresh: true,
                    expectedCredentialRevision: revision,
                    onUpdate: { values in
                        publishLibraryProgress(
                            user: user,
                            revision: revision,
                            playlistRevision: playlistRevision,
                            playlists: values
                        )
                    }
                )
            } else {
                playlists = try await model.accountPlaylists(
                    userID: user.id,
                    credentialRevision: revision,
                    onUpdate: { values in
                        publishLibraryProgress(
                            user: user,
                            revision: revision,
                            playlistRevision: playlistRevision,
                            playlists: values
                        )
                    }
                )
            }
            let (loadedSongs, loadedFollowing) = try await (songs, following)
            let recommendedUsers = (try? await extras.recommendedUsers(expectedCredentialRevision: revision)) ?? []
            try Task.checkCancellation()
            guard library.transport.credentialSnapshotValue().revision == revision else { return }
            model.storeLibrarySnapshot(
                LibrarySnapshot(
                    user: user,
                    songs: loadedSongs,
                    playlists: playlists,
                    following: loadedFollowing,
                    recommendedUsers: recommendedUsers
                ),
                playlistRevision: playlistRevision
            )
            progressiveSnapshot = nil
            phase = .loaded
            await model.refreshAccountState()
        } catch is CancellationError {
        } catch {
            phase = progressiveSnapshot == nil ? .failed(error.localizedDescription) : .loaded
        }
    }

    @MainActor
    private func publishLibraryProgress(
        user: MusicLibraryUser,
        revision: UInt64,
        playlistRevision: Int,
        playlists: [Playlist]? = nil,
        following: [MusicLibraryFollow]? = nil
    ) {
        guard model.currentUserID == user.id,
              library?.transport.credentialSnapshotValue().revision == revision,
              model.playlistContentRevision == playlistRevision
        else { return }
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
}

private struct IOSFollowingRow: View {
    let follow: MusicLibraryFollow

    private var route: Route {
        follow.kind == .artist ? .artist(follow.resourceID) : .user(follow.resourceID)
    }

    private var symbol: String {
        follow.kind == .artist ? "music.mic" : "person.fill"
    }

    var body: some View {
        NavigationLink(value: route) {
            HStack(spacing: 12) {
                IOSRemoteArtwork(url: follow.imageURL, symbol: symbol, circular: true)
                    .frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 3) {
                    Text(follow.name)
                    if !follow.followDay.isEmpty {
                        Text(follow.followDay)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

private struct IOSRecommendedUserRow: View {
    let user: MusicRecommendedUser

    var body: some View {
        NavigationLink(value: Route.user(user.id)) {
            HStack(spacing: 12) {
                IOSRemoteArtwork(url: user.avatarURL, symbol: "person.fill", circular: true)
                    .frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 3) {
                    Text(user.nickname)
                    Text(user.signature.isEmpty ? user.description : user.signature)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
    }
}

private struct IOSPlaylistLabel: View {
    let playlist: Playlist

    var body: some View {
        HStack(spacing: 12) {
            IOSArtworkView(artwork: playlist.artwork)
                .frame(width: 48, height: 48)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(playlist.name)
                        .lineLimit(2)
                    if playlist.specialType == 5 {
                        Image(systemName: "heart.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                            .accessibilityLabel("我喜欢的音乐")
                    }
                    if playlist.isPrivate {
                        Image(systemName: "lock.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("私密歌单")
                    }
                }
                Text("\(playlist.trackCount.formatted()) 首 · \(playlist.creator)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(minHeight: 56)
    }
}

private struct IOSSubscribedAlbumsView: View {
    @Bindable var model: AppModel
    @State private var albums: [Album] = []
    @State private var offset = 0
    @State private var hasMore = false
    @State private var isLoading = false
    @State private var isLoadingMore = false
    @State private var errorMessage: String?
    @State private var loadGeneration = 0

    var body: some View {
        Group {
            if model.currentUserID == nil {
                IOSLibraryEmptyState(title: "登录后查看已收藏专辑", symbol: "square.stack")
            } else if isLoading && albums.isEmpty {
                IOSLibraryLoadingView(title: "正在载入已收藏专辑")
            } else if albums.isEmpty, let errorMessage {
                IOSLibraryFailureView(title: "无法载入已收藏专辑", message: errorMessage) {
                    Task { await load(reset: true, force: true) }
                }
            } else {
                albumList
            }
        }
        .navigationTitle("已收藏专辑")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: "\(model.currentUserID ?? 0):\(revision ?? 0)") {
            await load(reset: true, force: false)
        }
    }

    private var revision: UInt64? {
        guard let library = model.library, model.currentUserID != nil else { return nil }
        let value = library.transport.credentialSnapshotValue().revision
        return model.confirmedAccountCredentialRevision == value ? value : nil
    }

    private var visibleAlbums: [Album] {
        albums.filter { model.albumSubscriptionOverrides[$0.id] != false }
    }

    private var albumList: some View {
        List {
            Section {
                if visibleAlbums.isEmpty {
                    IOSLibraryEmptyRow(title: "暂无已收藏专辑", symbol: "square.stack")
                } else {
                    ForEach(visibleAlbums) { album in
                        NavigationLink(value: Route.album(album.id)) {
                            IOSMediaListLabel(
                                title: album.name,
                                subtitle: album.artist.name,
                                artwork: album.artwork
                            )
                        }
                    }
                }
            } header: {
                Text("共 \(albums.count.formatted()) 张")
            }

            if let errorMessage, !albums.isEmpty {
                Section {
                    IOSInlineRetry(message: errorMessage) {
                        Task { await load(reset: false, force: false) }
                    }
                }
            } else if hasMore {
                Section {
                    Button {
                        Task { await load(reset: false, force: false) }
                    } label: {
                        HStack {
                            Spacer()
                            if isLoadingMore { ProgressView() }
                            Text(isLoadingMore ? "正在载入" : "载入更多")
                            Spacer()
                        }
                        .frame(minHeight: 44)
                    }
                    .disabled(isLoadingMore)
                }
            }
        }
        .listStyle(.insetGrouped)
        .refreshable { await load(reset: true, force: true) }
    }

    @MainActor
    private func load(reset: Bool, force: Bool) async {
        guard let library = model.library, let revision else {
            isLoading = false
            isLoadingMore = false
            return
        }
        if reset {
            loadGeneration &+= 1
            isLoading = true
            isLoadingMore = false
            errorMessage = nil
        } else {
            guard !isLoading, !isLoadingMore, hasMore else { return }
            isLoadingMore = true
        }
        let generation = loadGeneration
        let requestOffset = reset ? 0 : offset
        defer {
            if loadGeneration == generation, self.revision == revision {
                if reset { isLoading = false } else { isLoadingMore = false }
            }
        }
        do {
            let page = try await library.iosSubscribedAlbums(
                offset: requestOffset,
                forceRefresh: force,
                expectedCredentialRevision: revision
            )
            try Task.checkCancellation()
            guard loadGeneration == generation,
                  self.revision == revision,
                  reset || offset == requestOffset
            else { return }
            if reset {
                albums = page.albums
            } else {
                let existing = Set(albums.map(\.id))
                albums += page.albums.filter { !existing.contains($0.id) }
            }
            offset = requestOffset + page.albums.count
            hasMore = page.hasMore && !page.albums.isEmpty
            errorMessage = nil
        } catch is CancellationError {
        } catch {
            guard loadGeneration == generation, self.revision == revision else { return }
            errorMessage = error.localizedDescription
        }
    }
}

private struct IOSPlaylistManagerView: View {
    @Bindable var model: AppModel
    let library: LiveMusicLibrary?
    let userID: Int64
    @State private var playlists: [Playlist] = []
    @State private var isLoading = true
    @State private var isCreating = false
    @State private var name = ""
    @State private var isPrivate = false
    @State private var editing: Playlist?
    @State private var deleting: Playlist?
    @State private var errorMessage: String?

    var body: some View {
        List {
            Section("新建歌单") {
                TextField("歌单名称", text: $name)
                    .textInputAutocapitalization(.never)
                Toggle("私密歌单", isOn: $isPrivate)
                Button {
                    Task { await create() }
                } label: {
                    if isCreating {
                        HStack { ProgressView(); Text("正在创建") }
                    } else {
                        Label("创建歌单", systemImage: "plus")
                    }
                }
                .disabled(isCreating || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            Section("我的歌单") {
                if isLoading && playlists.isEmpty {
                    HStack { ProgressView(); Text("正在载入歌单").foregroundStyle(.secondary) }
                } else if playlists.isEmpty {
                    IOSLibraryEmptyRow(title: "暂无可管理的歌单", symbol: "music.note.list")
                } else {
                    ForEach(playlists) { playlist in
                        NavigationLink(value: Route.playlist(playlist.id)) {
                            IOSPlaylistLabel(playlist: playlist)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) { deleting = playlist } label: {
                                Label("删除", systemImage: "trash")
                            }
                            Button { editing = playlist } label: {
                                Label("编辑", systemImage: "pencil")
                            }
                            .tint(.blue)
                        }
                    }
                    .onMove(perform: move)
                }
            }
        }
        .navigationTitle("歌单管理")
        .toolbar { EditButton() }
        .task { await reload(force: false) }
        .refreshable { await reload(force: true) }
        .sheet(item: $editing) { playlist in
            IOSPlaylistEditorSheet(playlist: playlist) { draft in
                try await save(playlist, draft: draft)
            }
        }
        .alert("删除歌单？", isPresented: Binding(
            get: { deleting != nil },
            set: { if !$0 { deleting = nil } }
        )) {
            Button("删除", role: .destructive) {
                guard let deleting else { return }
                Task { await delete(deleting) }
            }
            Button("取消", role: .cancel) { deleting = nil }
        } message: {
            Text(deleting.map { "“\($0.name)”将被永久删除。" } ?? "")
        }
        .alert("操作失败", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("好") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var revision: UInt64? {
        guard let library else { return nil }
        let current = library.transport.credentialSnapshotValue().revision
        guard model.currentUserID == userID,
              model.confirmedAccountCredentialRevision == current
        else { return nil }
        return current
    }

    @MainActor
    private func reload(force: Bool) async {
        guard let library, let revision else {
            isLoading = false
            errorMessage = "当前登录状态已变化，请返回后重试。"
            return
        }
        isLoading = true
        do {
            let values = try await library.userPlaylists(
                userID: userID,
                forceRefresh: force,
                expectedCredentialRevision: revision
            )
            try Task.checkCancellation()
            guard self.revision == revision else { return }
            playlists = values.filter { $0.isUserEditable(by: userID) }
            publish(values)
            isLoading = false
        } catch is CancellationError {
        } catch {
            isLoading = false
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func create() async {
        guard let library, let revision else { return }
        let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        isCreating = true
        do {
            _ = try await library.createPlaylist(
                name: value,
                privacy: isPrivate ? .privatePlaylist : .publicPlaylist,
                expectedCredentialRevision: revision
            )
            guard self.revision == revision else { return }
            name = ""
            isPrivate = false
            model.showToast("歌单已创建")
            await reload(force: true)
        } catch {
            errorMessage = error.localizedDescription
        }
        isCreating = false
    }

    @MainActor
    private func delete(_ playlist: Playlist) async {
        defer { deleting = nil }
        guard let library, let revision else { return }
        do {
            try await library.deletePlaylist(playlist.id, expectedCredentialRevision: revision)
            guard self.revision == revision else { return }
            model.showToast("歌单已删除")
            await reload(force: true)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func save(_ playlist: Playlist, draft: PlaylistMetadataDraft) async throws {
        guard let library, let revision else { throw EAPIError.invalidPayload }
        if draft.normalizedName != playlist.name {
            try await library.updatePlaylistName(
                playlist.id,
                name: draft.normalizedName,
                expectedCredentialRevision: revision
            )
        }
        if draft.description != playlist.description {
            try await library.updatePlaylistDescription(
                playlist.id,
                description: draft.description,
                expectedCredentialRevision: revision
            )
        }
        if draft.normalizedTags != playlist.tags {
            try await library.updatePlaylistTags(
                playlist.id,
                tags: draft.normalizedTags,
                expectedCredentialRevision: revision
            )
        }
        guard self.revision == revision else { throw CancellationError() }
        model.showToast("歌单信息已保存")
        await reload(force: true)
    }

    private func move(from source: IndexSet, to destination: Int) {
        let previous = playlists
        playlists.move(fromOffsets: source, toOffset: destination)
        let ordered = playlists
        Task { @MainActor in
            guard let library, let revision else {
                playlists = previous
                return
            }
            do {
                try await library.updatePlaylistOrder(
                    ordered.map(\.id),
                    expectedCredentialRevision: revision
                )
                guard self.revision == revision else { return }
                publish(ordered)
                model.showToast("歌单顺序已保存")
            } catch {
                playlists = previous
                errorMessage = error.localizedDescription
            }
        }
    }

    private func publish(_ values: [Playlist]) {
        model.playlistSummariesDidChange()
        guard var snapshot = model.librarySnapshot, snapshot.user.id == userID else { return }
        if values.allSatisfy({ $0.isUserEditable(by: userID) }) {
            let unmanaged = snapshot.playlists.filter { !$0.isUserEditable(by: userID) }
            snapshot.playlists = unmanaged + values
        } else {
            snapshot.playlists = values
        }
        model.storeLibrarySnapshot(snapshot, playlistRevision: model.playlistContentRevision)
    }
}

private struct IOSPlaylistEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    let playlist: Playlist
    let save: (PlaylistMetadataDraft) async throws -> Void
    @State private var draft: PlaylistMetadataDraft
    @State private var isSaving = false
    @State private var errorMessage: String?

    init(playlist: Playlist, save: @escaping (PlaylistMetadataDraft) async throws -> Void) {
        self.playlist = playlist
        self.save = save
        _draft = State(initialValue: PlaylistMetadataDraft(playlist: playlist))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("基本信息") {
                    TextField("名称", text: $draft.name)
                    TextField("简介", text: $draft.description, axis: .vertical)
                        .lineLimit(3...8)
                }
                Section("标签（最多三个）") {
                    ForEach(draft.tags.indices, id: \.self) { index in
                        TextField("标签 \(index + 1)", text: $draft.tags[index])
                    }
                }
                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("编辑歌单")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        Task { await submit() }
                    }
                    .disabled(isSaving || draft.normalizedName.isEmpty)
                }
            }
            .interactiveDismissDisabled(isSaving)
        }
    }

    @MainActor
    private func submit() async {
        isSaving = true
        do {
            try await save(draft)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
        isSaving = false
    }
}

struct IOSRecentPlaybackView: View {
    @Bindable var model: AppModel
    @Bindable var player: PlayerController
    @State private var kind = RecentPlaybackKind.song
    @State private var history = RecentPlaybackState()
    @State private var historyRevision: UInt64?

    var body: some View {
        VStack(spacing: 0) {
            Picker("类型", selection: $kind) {
                ForEach(RecentPlaybackKind.allCases, id: \.self) { kind in
                    Text(kind.title).tag(kind)
                }
            }
            .pickerStyle(.segmented)
            .padding()

            TabView(selection: $kind) {
                ForEach(RecentPlaybackKind.allCases, id: \.self) { kind in
                    content(for: kind)
                        .tag(kind)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
        }
        .navigationTitle("最近播放")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: "\(kind.rawValue):\(revision)") { await load(force: false) }
        .toolbar {
            ToolbarItem {
                Button {
                    Task { await load(force: true) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .accessibilityLabel("刷新最近播放")
                .disabled(history.load(for: kind).isLoading)
            }
        }
    }

    private var revision: UInt64 {
        model.library?.transport.credentialSnapshotValue().revision ?? 0
    }

    @ViewBuilder
    private func content(for kind: RecentPlaybackKind) -> some View {
        switch history.load(for: kind) {
        case .idle, .loading:
            IOSLibraryLoadingView(title: "正在载入最近播放")
        case let .failed(message):
            IOSLibraryFailureView(title: "无法载入最近播放", message: message) {
                Task { await load(force: true) }
            }
        case let .loaded(value):
            recentList(value, kind: kind)
        }
    }

    @ViewBuilder
    private func recentList(_ value: RecentPlaybackContent, kind: RecentPlaybackKind) -> some View {
        switch value {
        case let .songs(songs):
            if songs.isEmpty {
                IOSLibraryEmptyState(title: "暂无最近播放的歌曲", symbol: kind.symbol)
            } else {
                List(songs) { song in
                    IOSSongRow(song: song, songs: songs, model: model, player: player)
                }
                .listStyle(.plain)
            }
        case let .albums(albums):
            if albums.isEmpty {
                IOSLibraryEmptyState(title: "暂无最近播放的专辑", symbol: kind.symbol)
            } else {
                List(albums) { album in
                    NavigationLink(value: Route.album(album.id)) {
                        IOSMediaListLabel(title: album.name, subtitle: album.artist.name, artwork: album.artwork)
                    }
                }
                .listStyle(.plain)
            }
        case let .playlists(playlists):
            if playlists.isEmpty {
                IOSLibraryEmptyState(title: "暂无最近播放的歌单", symbol: kind.symbol)
            } else {
                List(playlists) { playlist in
                    NavigationLink(value: Route.playlist(playlist.id)) {
                        IOSPlaylistLabel(playlist: playlist)
                    }
                }
                .listStyle(.plain)
            }
        case let .media(items):
            if items.isEmpty {
                IOSLibraryEmptyState(title: "暂无最近播放的\(kind.title)", symbol: kind.symbol)
            } else {
                List(items) { item in
                    if let route = route(for: item, kind: kind) {
                        NavigationLink(value: route) { IOSRecentMediaLabel(item: item) }
                    } else {
                        IOSRecentMediaLabel(item: item)
                    }
                }
                .listStyle(.plain)
            }
        }
    }

    private func route(for item: RecentMediaSummary, kind: RecentPlaybackKind) -> Route? {
        switch kind {
        case .video:
            if item.videoKind == .mv, let id = Int64(item.resourceID) { return .mv(id) }
            return .video(item.resourceID)
        case .voice:
            return Int64(item.resourceID).map(Route.podcastEpisode)
        case .podcast:
            return Int64(item.resourceID).map(Route.podcast)
        case .song, .album, .playlist:
            return nil
        }
    }

    @MainActor
    private func load(force: Bool) async {
        guard let library = model.library, let accountID = model.currentUserID else { return }
        let revision = revision
        if history.accountID != accountID || historyRevision != revision {
            history.reset(accountID: accountID)
            historyRevision = revision
        }
        let requestedKind = kind
        let previousLoad = history.load(for: requestedKind)
        if !force, case .loaded = previousLoad { return }
        let generation = history.generation
        history.setLoading(requestedKind)
        do {
            let content: RecentPlaybackContent = switch requestedKind {
            case .song:
                .songs(try await library.recentlyPlayedSongs(forceRefresh: force, expectedCredentialRevision: revision))
            case .album:
                .albums(try await library.recentlyPlayedAlbums(forceRefresh: force, expectedCredentialRevision: revision))
            case .playlist:
                .playlists(try await library.recentlyPlayedPlaylists(forceRefresh: force, expectedCredentialRevision: revision))
            case .video:
                .media(try await library.recentlyPlayedVideos(forceRefresh: force, expectedCredentialRevision: revision))
            case .voice:
                .media(try await library.recentlyPlayedVoices(forceRefresh: force, expectedCredentialRevision: revision))
            case .podcast:
                .media(try await library.recentlyPlayedPodcasts(forceRefresh: force, expectedCredentialRevision: revision))
            }
            try Task.checkCancellation()
            guard self.revision == revision else { return }
            history.accept(.loaded(content), for: requestedKind, generation: generation, accountID: accountID)
        } catch is CancellationError {
            history.accept(previousLoad, for: requestedKind, generation: generation, accountID: accountID)
        } catch {
            history.accept(
                .failed(error.localizedDescription),
                for: requestedKind,
                generation: generation,
                accountID: accountID
            )
        }
    }
}

private struct IOSRecentMediaLabel: View {
    let item: RecentMediaSummary

    var body: some View {
        HStack(spacing: 12) {
            IOSRemoteArtwork(url: item.artworkURL, symbol: "play.rectangle")
                .frame(width: 52, height: 52)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title).lineLimit(2)
                Text(item.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let playedAt = item.playedAt {
                    Text(playedAt, format: .dateTime.month().day().hour().minute())
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .frame(minHeight: 60)
    }
}

struct IOSCloudMusicView: View {
    @Bindable var model: AppModel
    @Bindable var player: PlayerController
    @State private var page: CloudSongPage?
    @State private var isLoading = false
    @State private var isLoadingMore = false
    @State private var errorMessage: String?
    @State private var isImporting = false
    @State private var showsUploads = false
    @State private var uploadError: String?

    var body: some View {
        Group {
            if model.currentUserID == nil {
                IOSLibraryEmptyState(title: "登录后查看音乐云盘", symbol: "externaldrive")
            } else if isLoading && page == nil {
                IOSLibraryLoadingView(title: "正在载入音乐云盘")
            } else if let errorMessage, page == nil {
                IOSLibraryFailureView(title: "无法载入音乐云盘", message: errorMessage) {
                    Task { await load(reset: true, force: true) }
                }
            } else if page?.songs.isEmpty == true {
                IOSLibraryEmptyState(title: "音乐云盘为空", symbol: "externaldrive")
            } else {
                cloudList
            }
        }
        .navigationTitle("音乐云盘")
        .task(id: "\(model.currentUserID ?? 0):\(revision)") { await load(reset: true, force: false) }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if model.uploads != nil, model.currentUserID != nil {
                    Button { isImporting = true } label: { Image(systemName: "arrow.up.circle") }
                        .accessibilityLabel("上传音频")
                    Button { showsUploads = true } label: { Image(systemName: "tray.full") }
                        .accessibilityLabel("上传任务")
                }
                Button {
                    Task { await load(reset: true, force: true) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .accessibilityLabel("刷新音乐云盘")
                .disabled(isLoading)
            }
        }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.audio]) { result in
            switch result {
            case let .success(url):
                guard model.uploads?.prepareCloudFile(url) != nil else {
                    uploadError = "当前账号无法创建上传任务。"
                    return
                }
                showsUploads = true
            case let .failure(error):
                uploadError = error.localizedDescription
            }
        }
        .sheet(isPresented: $showsUploads) {
            if let uploads = model.uploads { IOSUploadTasksView(manager: uploads) }
        }
        .alert("上传失败", isPresented: Binding(
            get: { uploadError != nil },
            set: { if !$0 { uploadError = nil } }
        )) {
            Button("好") { uploadError = nil }
        } message: {
            Text(uploadError ?? "")
        }
    }

    private var revision: UInt64 {
        model.library?.transport.credentialSnapshotValue().revision ?? 0
    }

    private var cloudList: some View {
        List {
            Section {
                ForEach(page?.songs ?? []) { cloud in
                    HStack(spacing: 12) {
                        NavigationLink {
                            IOSCloudSongDetailView(cloud: cloud, model: model, player: player)
                        } label: {
                            HStack(spacing: 12) {
                                IOSRemoteArtwork(url: cloud.song?.album.artwork.remoteURL, symbol: "music.note")
                                    .frame(width: 48, height: 48)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(cloud.name.isEmpty ? cloud.fileName : cloud.name)
                                        .lineLimit(2)
                                    Text([cloud.artist, cloud.album].filter { !$0.isEmpty }.joined(separator: " · "))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                    Text(ByteCountFormatter.string(fromByteCount: cloud.fileSize, countStyle: .file))
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .buttonStyle(.plain)
                        if let song = cloud.song {
                            Button { player.play(song, in: [song]) } label: {
                                Image(systemName: "play.fill")
                                    .frame(width: 44, height: 44)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("播放\(cloud.name)")
                        }
                        if model.downloads != nil {
                            Button { model.download(cloud) } label: {
                                Image(systemName: "arrow.down.circle")
                                    .frame(width: 44, height: 44)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("下载\(cloud.name)")
                        }
                    }
                    .frame(minHeight: 64)
                }
            } header: {
                Text("共 \((page?.totalCount ?? 0).formatted()) 首")
            }

            if let errorMessage, page != nil {
                Section {
                    IOSInlineRetry(message: errorMessage) {
                        Task { await load(reset: false, force: false) }
                    }
                }
            } else if page?.hasMore == true {
                Section {
                    Button {
                        Task { await load(reset: false, force: false) }
                    } label: {
                        HStack {
                            Spacer()
                            if isLoadingMore { ProgressView() }
                            Text(isLoadingMore ? "正在载入" : "载入更多")
                            Spacer()
                        }
                        .frame(minHeight: 44)
                    }
                    .disabled(isLoadingMore)
                }
            }
        }
        .listStyle(.plain)
        .refreshable { await load(reset: true, force: true) }
    }

    @MainActor
    private func load(reset: Bool, force: Bool) async {
        guard let library = model.library, model.currentUserID != nil else {
            page = nil
            return
        }
        if reset {
            isLoading = true
            errorMessage = nil
        } else {
            guard !isLoadingMore else { return }
            isLoadingMore = true
        }
        let revision = revision
        let offset = reset ? 0 : (page.map { $0.offset + $0.songs.count } ?? 0)
        do {
            let value = try await library.cloudSongs(
                offset: offset,
                forceRefresh: force,
                expectedCredentialRevision: revision
            )
            try Task.checkCancellation()
            guard self.revision == revision else { return }
            page = reset ? value : page?.appending(value) ?? value
            errorMessage = nil
        } catch is CancellationError {
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
        isLoadingMore = false
    }
}

private struct IOSCloudSongDetailView: View {
    let cloud: CloudSong
    @Bindable var model: AppModel
    @Bindable var player: PlayerController
    @State private var detail: CloudSong?
    @State private var lyrics: SongLyrics?
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        List {
            Section {
                HStack(spacing: 14) {
                    IOSRemoteArtwork(url: current.song?.album.artwork.remoteURL, symbol: "music.note")
                        .frame(width: 72, height: 72)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(current.name.isEmpty ? current.fileName : current.name)
                            .font(.headline)
                        Text(current.artist.isEmpty ? "未知歌手" : current.artist)
                            .foregroundStyle(.secondary)
                        if !current.album.isEmpty {
                            Text(current.album)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.vertical, 6)

                if let song = current.song {
                    Button {
                        player.play(song, in: [song])
                    } label: {
                        Label("播放", systemImage: "play.fill")
                    }
                    .tint(.red)
                }
                if model.downloads != nil {
                    Button {
                        model.download(current)
                    } label: {
                        Label("下载", systemImage: "arrow.down.circle")
                    }
                }
            }

            Section("云盘详情") {
                LabeledContent("文件名", value: current.fileName.isEmpty ? "未知" : current.fileName)
                LabeledContent(
                    "文件大小",
                    value: ByteCountFormatter.string(fromByteCount: current.fileSize, countStyle: .file)
                )
                LabeledContent("匹配状态", value: current.isMatched ? "已匹配" : "未匹配")
                LabeledContent(
                    "加入时间",
                    value: current.addedAt?.formatted(date: .abbreviated, time: .shortened) ?? "未知"
                )
            }

            Section("歌词") {
                if isLoading, lyrics == nil {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("正在载入详情与歌词")
                            .foregroundStyle(.secondary)
                    }
                    .frame(minHeight: 44)
                }
                if let errorMessage {
                    IOSInlineRetry(message: errorMessage) {
                        Task { await load() }
                    }
                }
                if let lyrics {
                    lyricContent(lyrics)
                } else if !isLoading, errorMessage == nil {
                    IOSLibraryEmptyRow(title: "暂无歌词", symbol: "text.quote")
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("云盘歌曲")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: "\(cloud.id):\(revision ?? 0)") { await load() }
    }

    private var current: CloudSong { detail ?? cloud }

    private var revision: UInt64? {
        guard let library = model.library, model.currentUserID != nil else { return nil }
        let value = library.transport.credentialSnapshotValue().revision
        return model.confirmedAccountCredentialRevision == value ? value : nil
    }

    @ViewBuilder
    private func lyricContent(_ lyrics: SongLyrics) -> some View {
        let lines = LRCParser.parse(lyrics)
        if lines.isEmpty {
            if lyrics.lineLyrics.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                IOSLibraryEmptyRow(title: "暂无歌词", symbol: "text.quote")
            } else {
                Text(lyrics.lineLyrics)
                    .textSelection(.enabled)
            }
        } else {
            ForEach(lines) { line in
                VStack(alignment: .leading, spacing: 3) {
                    Text(line.text)
                    if let translation = line.translation, !translation.isEmpty {
                        Text(translation)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let romanization = line.romanization, !romanization.isEmpty {
                        Text(romanization)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.vertical, 3)
            }
        }
    }

    @MainActor
    private func load() async {
        guard let library = model.library,
              let userID = model.currentUserID,
              let revision
        else {
            isLoading = false
            errorMessage = "当前登录状态已变化，请返回后重试。"
            return
        }
        isLoading = true
        errorMessage = nil
        var failures: [String] = []
        do {
            let value = try await library.cloudSongDetails(
                ids: [cloud.id],
                expectedCredentialRevision: revision
            ).first
            try Task.checkCancellation()
            guard self.revision == revision else { return }
            detail = value
        } catch is CancellationError {
            return
        } catch {
            failures.append("详情：\(error.localizedDescription)")
        }
        do {
            let value = try await library.cloudLyrics(
                userID: userID,
                songID: cloud.id,
                expectedCredentialRevision: revision
            )
            try Task.checkCancellation()
            guard self.revision == revision else { return }
            lyrics = value
        } catch is CancellationError {
            return
        } catch {
            failures.append("歌词：\(error.localizedDescription)")
        }
        errorMessage = failures.isEmpty ? nil : failures.joined(separator: "\n")
        isLoading = false
    }
}

struct IOSRecommendationHistoryView: View {
    @Bindable var model: AppModel
    @Bindable var player: PlayerController
    @State private var dates: [RecommendationHistoryDate] = []
    @State private var selected: RecommendationHistoryDate?
    @State private var songs: [Song] = []
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if model.currentUserID == nil {
                IOSLibraryEmptyState(title: "登录后查看历史日推", symbol: "calendar")
            } else if isLoading && dates.isEmpty {
                IOSLibraryLoadingView(title: "正在载入历史日推")
            } else if let errorMessage, dates.isEmpty {
                IOSLibraryFailureView(title: "无法载入历史日推", message: errorMessage) {
                    Task { await loadDates(force: true) }
                }
            } else {
                VStack(spacing: 0) {
                    Picker("日期", selection: Binding(
                        get: { selected },
                        set: { value in
                            selected = value
                            Task { await loadSongs(force: false) }
                        }
                    )) {
                        ForEach(dates) { date in
                            Text(date.value).tag(Optional(date))
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .frame(minHeight: 52)
                    Divider()
                    if isLoading {
                        IOSLibraryLoadingView(title: "正在载入推荐歌曲")
                    } else if let errorMessage {
                        IOSLibraryFailureView(title: "无法载入推荐歌曲", message: errorMessage) {
                            Task { await loadSongs(force: true) }
                        }
                    } else if songs.isEmpty {
                        IOSLibraryEmptyState(title: "当天暂无推荐", symbol: "music.note")
                    } else {
                        List(songs) { song in
                            IOSSongRow(song: song, songs: songs, model: model, player: player)
                        }
                        .listStyle(.plain)
                    }
                }
            }
        }
        .navigationTitle("历史日推")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: "\(model.currentUserID ?? 0):\(revision)") { await loadDates(force: false) }
    }

    private var revision: UInt64 {
        model.library?.transport.credentialSnapshotValue().revision ?? 0
    }

    @MainActor
    private func loadDates(force: Bool) async {
        guard let library = model.library, model.currentUserID != nil else { return }
        isLoading = true
        errorMessage = nil
        let revision = revision
        do {
            let values = try await library.recommendationHistoryDates(
                forceRefresh: force,
                expectedCredentialRevision: revision
            )
            try Task.checkCancellation()
            guard self.revision == revision else { return }
            dates = values
            selected = values.first
            await loadSongs(force: force)
        } catch is CancellationError {
        } catch {
            isLoading = false
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func loadSongs(force: Bool) async {
        guard let library = model.library, let selected else {
            songs = []
            isLoading = false
            return
        }
        isLoading = true
        errorMessage = nil
        let revision = revision
        do {
            let values = try await library.historicalDailyRecommendations(
                on: selected,
                availableDates: dates,
                forceRefresh: force,
                expectedCredentialRevision: revision
            )
            try Task.checkCancellation()
            guard self.selected == selected, self.revision == revision else { return }
            songs = values
            isLoading = false
        } catch is CancellationError {
        } catch {
            guard self.selected == selected, self.revision == revision else { return }
            isLoading = false
            errorMessage = error.localizedDescription
        }
    }
}

struct IOSListeningFootprintsView: View {
    @Bindable var model: AppModel
    @Bindable var player: PlayerController

    @ViewBuilder
    var body: some View {
        if let library = model.library {
            ListeningFootprintsView(model: model, library: library, player: player)
                .navigationBarTitleDisplayMode(.inline)
        } else {
            ContentUnavailableView("听歌足迹暂不可用", systemImage: "chart.line.uptrend.xyaxis")
        }
    }
}

private enum IOSCommentReportReason: String, CaseIterable, Identifiable {
    case personalAttack = "人身攻击"
    case pornography = "色情低俗"
    case spam = "垃圾广告"
    case illegal = "违法违规"
    case other = "其他"

    var id: String { rawValue }
}

struct IOSCommentsView: View {
    let songID: Int64
    @Bindable var model: AppModel
    @State private var comments: [MusicComment] = []
    @State private var emojiPictureIDs: [String: String] = [:]
    @State private var pageNumber = 1
    @State private var cursor = "0"
    @State private var sortType = 0
    @State private var hasMore = false
    @State private var text = ""
    @State private var isLoading = false
    @State private var isWriting = false
    @State private var mutatingIDs: Set<Int64> = []
    @State private var reportedIDs: Set<Int64> = []
    @State private var errorMessage: String?
    @State private var mutationErrorMessage: String?
    @State private var replyingTo: MusicComment?
    @State private var deleting: MusicComment?
    @State private var reporting: MusicComment?

    var body: some View {
        List {
            Section {
                TextField("发表评论", text: $text, axis: .vertical)
                    .lineLimit(1...4)
                    .disabled(revision == nil || isWriting)
                Button {
                    Task { await submit() }
                } label: {
                    if isWriting {
                        HStack(spacing: 8) { ProgressView(); Text("正在发表") }
                    } else {
                        Label("发表", systemImage: "paperplane.fill")
                    }
                }
                .disabled(revision == nil || isWriting || trimmedText.isEmpty)
                if revision == nil {
                    Text("登录后可发表评论和参与互动。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("评论") {
                if isLoading && comments.isEmpty {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("正在载入评论").foregroundStyle(.secondary)
                    }
                    .frame(minHeight: 44)
                } else if comments.isEmpty, let errorMessage {
                    IOSInlineRetry(message: errorMessage) { Task { await load(reset: true) } }
                } else if comments.isEmpty {
                    IOSLibraryEmptyRow(title: "暂无评论", symbol: "bubble.left")
                } else {
                    ForEach(comments) { comment in
                        VStack(alignment: .leading, spacing: 0) {
                            IOSCommentRow(
                                comment: comment,
                                emojiPictureIDs: emojiPictureIDs,
                                canInteract: revision != nil,
                                isMutating: mutatingIDs.contains(comment.id),
                                openUser: { model.open(.user(comment.userID)) },
                                like: { Task { await setLiked(comment, liked: !comment.isLiked) } },
                                reply: { replyingTo = comment },
                                report: reportAction(for: comment),
                                delete: deleteAction(for: comment)
                            )
                            if comment.replyCount > 0 {
                                NavigationLink {
                                    IOSCommentFloorView(
                                        root: comment,
                                        model: model,
                                        emojiPictureIDs: emojiPictureIDs,
                                        onRootChanged: update,
                                        onRootDeleted: remove
                                    )
                                } label: {
                                    Label("查看 \(comment.replyCount.formatted()) 条回复", systemImage: "bubble.left")
                                        .font(.subheadline)
                                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                }
                            }
                        }
                    }
                    if let errorMessage {
                        IOSInlineRetry(message: errorMessage) { Task { await load(reset: false) } }
                    } else if hasMore {
                        Button {
                            Task { await load(reset: false) }
                        } label: {
                            HStack(spacing: 8) {
                                if isLoading { ProgressView() }
                                Text(isLoading ? "正在载入" : "载入更多")
                            }
                            .frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .disabled(isLoading)
                    }
                }
            }
        }
        .navigationTitle("评论")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: songID) { await load(reset: true) }
        .task(id: "emoji-\(songID)") { await loadEmojiCatalog() }
        .refreshable { await load(reset: true) }
        .sheet(item: $replyingTo) { comment in
            IOSCommentReplySheet(comment: comment, emojiPictureIDs: emojiPictureIDs) { content in
                try await reply(to: comment, content: content)
            }
        }
        .alert("删除评论？", isPresented: Binding(
            get: { deleting != nil },
            set: { if !$0 { deleting = nil } }
        )) {
            Button("删除", role: .destructive) {
                guard let deleting else { return }
                Task { await delete(deleting) }
            }
            Button("取消", role: .cancel) { deleting = nil }
        } message: {
            Text("此操作不可撤销。")
        }
        .alert(
            "举报评论",
            isPresented: Binding(
                get: { reporting != nil },
                set: { if !$0 { reporting = nil } }
            )
        ) {
            ForEach(IOSCommentReportReason.allCases) { reason in
                Button(reason.rawValue) {
                    guard let reporting else { return }
                    Task { await report(reporting, reason: reason) }
                }
            }
            Button("取消", role: .cancel) { reporting = nil }
        } message: {
            Text("请选择举报理由。")
        }
        .alert("评论操作失败", isPresented: Binding(
            get: { mutationErrorMessage != nil },
            set: { if !$0 { mutationErrorMessage = nil } }
        )) {
            Button("好") { mutationErrorMessage = nil }
        } message: {
            Text(mutationErrorMessage ?? "")
        }
    }

    private var trimmedText: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var revision: UInt64? {
        guard let library = model.library, model.currentUserID != nil else { return nil }
        let value = library.transport.credentialSnapshotValue().revision
        return model.confirmedAccountCredentialRevision == value ? value : nil
    }

    private func reportAction(for comment: MusicComment) -> (() -> Void)? {
        guard comment.userID != model.currentUserID, !reportedIDs.contains(comment.id) else { return nil }
        return { reporting = comment }
    }

    private func deleteAction(for comment: MusicComment) -> (() -> Void)? {
        guard comment.userID == model.currentUserID else { return nil }
        return { deleting = comment }
    }

    private func update(_ comment: MusicComment) {
        comments = comments.map { $0.id == comment.id ? comment : $0 }
    }

    private func remove(_ commentID: Int64) {
        comments.removeAll { $0.id == commentID }
    }

    @MainActor
    private func loadEmojiCatalog() async {
        guard let library = model.library else { return }
        emojiPictureIDs = (try? await library.commentEmojiPictureIDs()) ?? [:]
    }

    @MainActor
    private func load(reset: Bool) async {
        guard let library = model.library, !isLoading else { return }
        isLoading = true
        if reset {
            comments = []
            cursor = "0"
            pageNumber = 1
            hasMore = false
        }
        errorMessage = nil
        do {
            let page = try await library.comments(
                songID: songID,
                cursor: cursor,
                pageNumber: pageNumber,
                pageSize: 20,
                sortType: sortType
            )
            try Task.checkCancellation()
            if reset {
                comments = page.comments
            } else {
                let existing = Set(comments.map(\.id))
                comments += page.comments.filter { !existing.contains($0.id) }
            }
            cursor = page.cursor
            pageNumber += 1
            sortType = page.sortType
            hasMore = page.hasMore
        } catch is CancellationError {
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    @MainActor
    private func submit() async {
        guard let library = model.library, let revision, !trimmedText.isEmpty else { return }
        isWriting = true
        do {
            _ = try await library.addComment(
                songID: songID,
                content: trimmedText,
                expectedCredentialRevision: revision
            )
            text = ""
            isWriting = false
            await load(reset: true)
            model.showToast("评论成功")
        } catch {
            isWriting = false
            mutationErrorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func reply(to comment: MusicComment, content: String) async throws {
        guard let library = model.library, let revision else { throw EAPIError.invalidPayload }
        _ = try await library.replyToComment(
            songID: songID,
            commentID: comment.id,
            content: content,
            expectedCredentialRevision: revision
        )
        await load(reset: true)
        model.showToast("回复成功")
    }

    @MainActor
    private func delete(_ comment: MusicComment) async {
        deleting = nil
        guard let library = model.library, let revision, mutatingIDs.insert(comment.id).inserted else { return }
        defer { mutatingIDs.remove(comment.id) }
        do {
            try await library.deleteComment(
                songID: songID,
                commentID: comment.id,
                expectedCredentialRevision: revision
            )
            guard self.revision == revision else { return }
            remove(comment.id)
            model.showToast("评论已删除")
        } catch {
            mutationErrorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func setLiked(_ comment: MusicComment, liked: Bool) async {
        guard let library = model.library, let revision, mutatingIDs.insert(comment.id).inserted else { return }
        defer { mutatingIDs.remove(comment.id) }
        do {
            try await library.setCommentLiked(
                songID: songID,
                commentID: comment.id,
                liked: liked,
                expectedCredentialRevision: revision
            )
            guard self.revision == revision else { return }
            update(comment.settingLiked(liked))
        } catch {
            mutationErrorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func report(_ comment: MusicComment, reason: IOSCommentReportReason) async {
        reporting = nil
        guard let library = model.library, let revision, mutatingIDs.insert(comment.id).inserted else { return }
        defer { mutatingIDs.remove(comment.id) }
        do {
            try await library.iosReportComment(
                songID: songID,
                commentID: comment.id,
                reason: reason.rawValue,
                expectedCredentialRevision: revision
            )
            guard self.revision == revision else { return }
            reportedIDs.insert(comment.id)
            model.showToast("举报已提交")
        } catch {
            mutationErrorMessage = error.localizedDescription
        }
    }
}

private struct IOSCommentFloorView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: AppModel
    let emojiPictureIDs: [String: String]
    let onRootChanged: (MusicComment) -> Void
    let onRootDeleted: (Int64) -> Void
    @State private var owner: MusicComment
    @State private var replies: [MusicComment] = []
    @State private var cursor = ""
    @State private var time: Int64 = -1
    @State private var hasMore = false
    @State private var isLoading = false
    @State private var mutatingIDs: Set<Int64> = []
    @State private var reportedIDs: Set<Int64> = []
    @State private var errorMessage: String?
    @State private var mutationErrorMessage: String?
    @State private var replyingTo: MusicComment?
    @State private var deleting: MusicComment?
    @State private var reporting: MusicComment?

    init(
        root: MusicComment,
        model: AppModel,
        emojiPictureIDs: [String: String],
        onRootChanged: @escaping (MusicComment) -> Void,
        onRootDeleted: @escaping (Int64) -> Void
    ) {
        _model = Bindable(model)
        self.emojiPictureIDs = emojiPictureIDs
        self.onRootChanged = onRootChanged
        self.onRootDeleted = onRootDeleted
        _owner = State(initialValue: root)
    }

    var body: some View {
        List {
            Section("主评论") {
                IOSCommentRow(
                    comment: owner,
                    emojiPictureIDs: emojiPictureIDs,
                    canInteract: revision != nil,
                    isMutating: mutatingIDs.contains(owner.id),
                    openUser: { model.open(.user(owner.userID)) },
                    like: { Task { await setLiked(owner, liked: !owner.isLiked) } },
                    reply: { replyingTo = owner },
                    report: reportAction(for: owner),
                    delete: deleteAction(for: owner)
                )
            }

            Section("楼层回复") {
                if isLoading && replies.isEmpty {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("正在载入回复").foregroundStyle(.secondary)
                    }
                    .frame(minHeight: 44)
                } else if replies.isEmpty, let errorMessage {
                    IOSInlineRetry(message: errorMessage) { Task { await load(reset: true) } }
                } else if replies.isEmpty {
                    IOSLibraryEmptyRow(title: "暂无回复", symbol: "bubble.left")
                } else {
                    ForEach(replies) { reply in
                        IOSCommentRow(
                            comment: reply,
                            emojiPictureIDs: emojiPictureIDs,
                            canInteract: revision != nil,
                            isMutating: mutatingIDs.contains(reply.id),
                            openUser: { model.open(.user(reply.userID)) },
                            like: { Task { await setLiked(reply, liked: !reply.isLiked) } },
                            reply: { replyingTo = reply },
                            report: reportAction(for: reply),
                            delete: deleteAction(for: reply)
                        )
                    }
                    if let errorMessage {
                        IOSInlineRetry(message: errorMessage) { Task { await load(reset: false) } }
                    } else if hasMore {
                        Button {
                            Task { await load(reset: false) }
                        } label: {
                            HStack(spacing: 8) {
                                if isLoading { ProgressView() }
                                Text(isLoading ? "正在载入" : "载入更多")
                            }
                            .frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .disabled(isLoading)
                    }
                }
            }
        }
        .navigationTitle("评论回复")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: owner.id) { await load(reset: true) }
        .refreshable { await load(reset: true) }
        .sheet(item: $replyingTo) { comment in
            IOSCommentReplySheet(comment: comment, emojiPictureIDs: emojiPictureIDs) { content in
                try await reply(to: comment, content: content)
            }
        }
        .alert("删除评论？", isPresented: Binding(
            get: { deleting != nil },
            set: { if !$0 { deleting = nil } }
        )) {
            Button("删除", role: .destructive) {
                guard let deleting else { return }
                Task { await delete(deleting) }
            }
            Button("取消", role: .cancel) { deleting = nil }
        } message: {
            Text("此操作不可撤销。")
        }
        .alert(
            "举报评论",
            isPresented: Binding(
                get: { reporting != nil },
                set: { if !$0 { reporting = nil } }
            )
        ) {
            ForEach(IOSCommentReportReason.allCases) { reason in
                Button(reason.rawValue) {
                    guard let reporting else { return }
                    Task { await report(reporting, reason: reason) }
                }
            }
            Button("取消", role: .cancel) { reporting = nil }
        } message: {
            Text("请选择举报理由。")
        }
        .alert("评论操作失败", isPresented: Binding(
            get: { mutationErrorMessage != nil },
            set: { if !$0 { mutationErrorMessage = nil } }
        )) {
            Button("好") { mutationErrorMessage = nil }
        } message: {
            Text(mutationErrorMessage ?? "")
        }
    }

    private var revision: UInt64? {
        guard let library = model.library, model.currentUserID != nil else { return nil }
        let value = library.transport.credentialSnapshotValue().revision
        return model.confirmedAccountCredentialRevision == value ? value : nil
    }

    private func reportAction(for comment: MusicComment) -> (() -> Void)? {
        guard comment.userID != model.currentUserID, !reportedIDs.contains(comment.id) else { return nil }
        return { reporting = comment }
    }

    private func deleteAction(for comment: MusicComment) -> (() -> Void)? {
        guard comment.userID == model.currentUserID else { return nil }
        return { deleting = comment }
    }

    @MainActor
    private func load(reset: Bool) async {
        guard let library = model.library, !isLoading else { return }
        isLoading = true
        if reset {
            replies = []
            cursor = ""
            time = -1
            hasMore = false
        }
        errorMessage = nil
        do {
            let page = try await library.commentFloor(
                songID: owner.songID,
                parentCommentID: owner.id,
                time: time,
                cursor: cursor,
                limit: 20
            )
            try Task.checkCancellation()
            if reset {
                replies = page.comments
            } else {
                let existing = Set(replies.map(\.id))
                replies += page.comments.filter { !existing.contains($0.id) }
            }
            cursor = page.cursor
            time = page.time
            hasMore = page.hasMore
        } catch is CancellationError {
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    @MainActor
    private func reply(to comment: MusicComment, content: String) async throws {
        guard let library = model.library, let revision else { throw EAPIError.invalidPayload }
        _ = try await library.replyToComment(
            songID: owner.songID,
            commentID: comment.id,
            content: content,
            expectedCredentialRevision: revision
        )
        guard self.revision == revision else { throw CancellationError() }
        owner = owner.addingReply()
        onRootChanged(owner)
        await load(reset: true)
        model.showToast("回复成功")
    }

    @MainActor
    private func setLiked(_ comment: MusicComment, liked: Bool) async {
        guard let library = model.library, let revision, mutatingIDs.insert(comment.id).inserted else { return }
        defer { mutatingIDs.remove(comment.id) }
        do {
            try await library.setCommentLiked(
                songID: owner.songID,
                commentID: comment.id,
                liked: liked,
                expectedCredentialRevision: revision
            )
            guard self.revision == revision else { return }
            let updated = comment.settingLiked(liked)
            if comment.id == owner.id {
                owner = updated
                onRootChanged(updated)
            } else {
                replies = replies.map { $0.id == comment.id ? updated : $0 }
            }
        } catch {
            mutationErrorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func delete(_ comment: MusicComment) async {
        deleting = nil
        guard let library = model.library, let revision, mutatingIDs.insert(comment.id).inserted else { return }
        defer { mutatingIDs.remove(comment.id) }
        do {
            try await library.deleteComment(
                songID: owner.songID,
                commentID: comment.id,
                expectedCredentialRevision: revision
            )
            guard self.revision == revision else { return }
            model.showToast("评论已删除")
            if comment.id == owner.id {
                onRootDeleted(owner.id)
                dismiss()
            } else {
                replies.removeAll { $0.id == comment.id }
                await load(reset: true)
            }
        } catch {
            mutationErrorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func report(_ comment: MusicComment, reason: IOSCommentReportReason) async {
        reporting = nil
        guard let library = model.library, let revision, mutatingIDs.insert(comment.id).inserted else { return }
        defer { mutatingIDs.remove(comment.id) }
        do {
            try await library.iosReportComment(
                songID: owner.songID,
                commentID: comment.id,
                reason: reason.rawValue,
                expectedCredentialRevision: revision
            )
            guard self.revision == revision else { return }
            reportedIDs.insert(comment.id)
            model.showToast("举报已提交")
        } catch {
            mutationErrorMessage = error.localizedDescription
        }
    }
}

private struct IOSCommentRow: View {
    let comment: MusicComment
    let emojiPictureIDs: [String: String]
    let canInteract: Bool
    let isMutating: Bool
    let openUser: () -> Void
    let like: () -> Void
    let reply: () -> Void
    let report: (() -> Void)?
    let delete: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Button(action: openUser) {
                    Text(comment.nickname)
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.plain)
                .disabled(comment.userID <= 0)
                Spacer()
                Text(comment.timeText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            CommentEmojiText(content: comment.displayContent, remotePictureIDs: emojiPictureIDs)
            HStack(spacing: 8) {
                Button(action: like) {
                    if isMutating {
                        ProgressView().frame(minWidth: 44, minHeight: 44)
                    } else {
                        Label(
                            comment.likedCount.formatted(),
                            systemImage: comment.isLiked ? "hand.thumbsup.fill" : "hand.thumbsup"
                        )
                        .frame(minWidth: 44, minHeight: 44)
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(comment.isLiked ? Color.red : Color.primary)
                .disabled(!canInteract || isMutating)
                .accessibilityLabel(comment.isLiked ? "取消点赞" : "点赞")

                Button(action: reply) {
                    Label("回复", systemImage: "arrowshape.turn.up.left")
                        .frame(minHeight: 44)
                }
                .buttonStyle(.plain)
                .disabled(!canInteract || isMutating)

                Spacer(minLength: 4)

                if report != nil || delete != nil {
                    Menu {
                        if let report {
                            Button("举报", systemImage: "exclamationmark.bubble", action: report)
                        }
                        if let delete {
                            Button("删除", systemImage: "trash", role: .destructive, action: delete)
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .frame(width: 44, height: 44)
                    }
                    .disabled(!canInteract || isMutating)
                    .accessibilityLabel("更多评论操作")
                }
            }
        }
        .padding(.vertical, 6)
    }
}

private struct IOSCommentReplySheet: View {
    @Environment(\.dismiss) private var dismiss
    let comment: MusicComment
    let emojiPictureIDs: [String: String]
    let submit: (String) async throws -> Void
    @State private var text = ""
    @State private var isSubmitting = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("回复 \(comment.nickname)") {
                    CommentEmojiText(content: comment.displayContent, remotePictureIDs: emojiPictureIDs)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    TextField("回复内容", text: $text, axis: .vertical)
                        .lineLimit(2...6)
                        .disabled(isSubmitting)
                }
                if let errorMessage {
                    Section { Text(errorMessage).foregroundStyle(.red) }
                }
            }
            .navigationTitle("回复评论")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                        .disabled(isSubmitting)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await send() }
                    } label: {
                        if isSubmitting { ProgressView() } else { Text("发送") }
                    }
                    .disabled(isSubmitting || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    @MainActor
    private func send() async {
        isSubmitting = true
        errorMessage = nil
        do {
            try await submit(text.trimmingCharacters(in: .whitespacesAndNewlines))
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
        isSubmitting = false
    }
}

struct IOSSimilarSongsView: View {
    let source: Song
    @Bindable var model: AppModel
    @Bindable var player: PlayerController
    @State private var songs: [Song] = []
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if isLoading {
                IOSLibraryLoadingView(title: "正在寻找相似歌曲")
            } else if let errorMessage {
                IOSLibraryFailureView(title: "无法载入相似歌曲", message: errorMessage) {
                    Task { await load() }
                }
            } else if songs.isEmpty {
                IOSLibraryEmptyState(title: "暂无相似歌曲", symbol: "waveform.badge.magnifyingglass")
            } else {
                List(songs) { song in
                    IOSSongRow(song: song, songs: songs, model: model, player: player)
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("相似歌曲")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: source.id) { await load() }
    }

    @MainActor
    private func load() async {
        guard let library = model.library else {
            isLoading = false
            errorMessage = "相似歌曲服务不可用"
            return
        }
        isLoading = true
        errorMessage = nil
        do {
            songs = try await library.similarSongs(to: source.id)
            isLoading = false
        } catch is CancellationError {
        } catch {
            isLoading = false
            errorMessage = error.localizedDescription
        }
    }
}

struct IOSDownloadsView: View {
    @Bindable var manager: MusicDownloadManager

    var body: some View {
        List {
            if manager.states.isEmpty && manager.videoStates.isEmpty {
                IOSLibraryEmptyRow(title: "暂无下载任务", symbol: "arrow.down.circle")
            } else {
                if !orderedSongIDs.isEmpty {
                    Section("歌曲") {
                        ForEach(orderedSongIDs, id: \.self) { id in
                            if let item = manager.items[id], let state = manager.states[id] {
                                IOSDownloadRow(
                                    title: item.title,
                                    subtitle: item.artist,
                                    detail: item.quality,
                                    state: state,
                                    pause: { manager.pause(songID: id) },
                                    retry: { manager.retry(songID: id) },
                                    cancel: { manager.cancel(songID: id) }
                                )
                            }
                        }
                    }
                }
                if !orderedVideoIDs.isEmpty {
                    Section("视频") {
                        ForEach(orderedVideoIDs, id: \.self) { id in
                            if let item = manager.videoItems[id], let state = manager.videoStates[id] {
                                IOSDownloadRow(
                                    title: item.title,
                                    subtitle: item.creator,
                                    detail: item.quality,
                                    state: state,
                                    pause: { manager.pauseVideo(id: id) },
                                    retry: { manager.retryVideo(id: id) },
                                    cancel: { manager.cancelVideo(id: id) }
                                )
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("下载管理")
        .toolbar {
            ToolbarItem {
                Button { Task { await manager.pauseAll() } } label: {
                    Label("暂停全部", systemImage: "pause.circle")
                }
                .disabled(manager.states.values.allSatisfy { state in
                    if case .running = state { false } else { state != .queued }
                } && manager.videoStates.values.allSatisfy { state in
                    if case .running = state { false } else { state != .queued }
                })
            }
        }
    }

    private var orderedSongIDs: [Int64] {
        let known = Set(manager.itemOrder)
        return manager.itemOrder.reversed().filter { manager.states[$0] != nil }
            + manager.states.keys.filter { !known.contains($0) }.sorted(by: >)
    }

    private var orderedVideoIDs: [String] {
        let known = Set(manager.videoItemOrder)
        return manager.videoItemOrder.reversed().filter { manager.videoStates[$0] != nil }
            + manager.videoStates.keys.filter { !known.contains($0) }.sorted(by: >)
    }
}

private struct IOSDownloadRow: View {
    let title: String
    let subtitle: String
    let detail: String
    let state: MusicDownloadState
    let pause: () -> Void
    let retry: () -> Void
    let cancel: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            stateIcon
                .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).lineLimit(2)
                Text([subtitle, detail].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(stateText)
                    .font(.caption2)
                    .foregroundStyle(stateIsError ? .red : .secondary)
            }
            Spacer(minLength: 4)
            Menu {
                switch state {
                case .queued, .running:
                    Button("暂停", systemImage: "pause", action: pause)
                case .paused, .failed:
                    Button("继续", systemImage: "play", action: retry)
                case let .completed(audioURL, lyricURL):
                    ShareLink(item: audioURL) {
                        Label("分享或导出音频", systemImage: "square.and.arrow.up")
                    }
                    if let lyricURL {
                        ShareLink(item: lyricURL) {
                            Label("分享或导出歌词", systemImage: "doc.text")
                        }
                    }
                case .cancelled:
                    EmptyView()
                }
                if !isCompleted {
                    Button("取消", systemImage: "xmark", role: .destructive, action: cancel)
                }
            } label: {
                Image(systemName: "ellipsis").frame(width: 44, height: 44)
            }
            .accessibilityLabel("\(title)下载操作")
        }
        .frame(minHeight: 64)
    }

    @ViewBuilder
    private var stateIcon: some View {
        switch state {
        case let .running(progress), let .paused(progress):
            if let progress { ProgressView(value: progress) } else { ProgressView() }
        case .queued: Image(systemName: "clock").foregroundStyle(.secondary)
        case .completed: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
        case .cancelled: Image(systemName: "xmark.circle").foregroundStyle(.secondary)
        }
    }

    private var stateText: String {
        switch state {
        case .queued: "等待下载"
        case let .running(progress): progress.map { "已完成 \(Int($0 * 100))%" } ?? "正在下载"
        case let .paused(progress): progress.map { "已暂停 · \(Int($0 * 100))%" } ?? "已暂停"
        case let .completed(url, _): "已保存到 \(url.lastPathComponent)"
        case let .failed(message): message
        case .cancelled: "已取消"
        }
    }

    private var stateIsError: Bool {
        if case .failed = state { true } else { false }
    }

    private var isCompleted: Bool {
        if case .completed = state { true } else { false }
    }
}

struct IOSRemoteArtwork: View {
    let url: URL?
    let symbol: String
    var circular = false

    var body: some View {
        ZStack {
            Rectangle().fill(.quaternary)
            CachedAsyncImage(url: url.map(ArtworkURLPolicy.secureURL)) { phase in
                switch phase {
                case let .success(image): image.resizable().scaledToFill()
                case .empty: ProgressView().controlSize(.small)
                case .failure: Image(systemName: symbol).foregroundStyle(.secondary)
                }
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(circular ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: 6)))
        .accessibilityHidden(true)
    }
}

struct IOSMediaListLabel: View {
    let title: String
    let subtitle: String
    let artwork: Artwork

    var body: some View {
        HStack(spacing: 12) {
            IOSArtworkView(artwork: artwork)
                .frame(width: 52, height: 52)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).lineLimit(2)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .frame(minHeight: 60)
    }
}

struct IOSLibraryLoadingView: View {
    let title: String

    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text(title).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct IOSLibraryFailureView: View {
    let title: String
    let message: String
    let retry: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        } actions: {
            Button("重试", action: retry)
                .buttonStyle(.borderedProminent)
                .tint(.red)
        }
    }
}

struct IOSLibraryEmptyState: View {
    let title: String
    let symbol: String

    var body: some View {
        ContentUnavailableView(title, systemImage: symbol)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct IOSLibraryEmptyRow: View {
    let title: String
    let symbol: String

    var body: some View {
        Label(title, systemImage: symbol)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 52, alignment: .center)
    }
}

private struct IOSSubscribedAlbumPage {
    let albums: [Album]
    let hasMore: Bool
}

private extension LiveMusicLibrary {
    func iosSubscribedAlbums(
        offset: Int,
        limit: Int = 25,
        forceRefresh: Bool,
        expectedCredentialRevision: UInt64
    ) async throws -> IOSSubscribedAlbumPage {
        guard offset >= 0, (1...100).contains(limit) else { throw EAPIError.invalidPayload }
        let root = try await transport.requestWEAPIJSONObject(
            path: "/weapi/album/sublist",
            payload: ["limit": limit, "offset": offset, "total": true],
            cache: .library,
            refreshCache: forceRefresh,
            expectedCredentialRevision: expectedCredentialRevision,
            invalidatesAccountCache: false
        )
        let decoder = LiveMusicRepository(transport: transport)
        let albums = root.array("data").compactMap(decoder.decodeLiveAlbum)
        let totalCount = max(root.int("count"), offset + albums.count)
        let hasMore = root.keys.contains("hasMore")
            ? root.bool("hasMore")
            : offset + albums.count < totalCount
        return IOSSubscribedAlbumPage(albums: albums, hasMore: hasMore)
    }

    func iosReportComment(
        songID: Int64,
        commentID: Int64,
        reason: String,
        expectedCredentialRevision: UInt64
    ) async throws {
        let value = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard songID > 0, commentID > 0, !value.isEmpty else { throw EAPIError.invalidPayload }
        _ = try await transport.requestJSONObject(
            EAPIEndpoint(
                "/eapi/report/reportcomment",
                signing: "/api/report/reportcomment",
                host: "https://interfacepc.music.163.com"
            ),
            json: compactJSON([
                "threadId": "R_SO_4_\(songID)",
                "commentId": commentID,
                "reason": value
            ]),
            expectedCredentialRevision: expectedCredentialRevision,
            retryable: false
        )
    }
}
