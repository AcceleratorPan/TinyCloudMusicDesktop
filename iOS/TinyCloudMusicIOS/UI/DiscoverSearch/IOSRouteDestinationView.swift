import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct IOSRouteDestinationView: View {
    let route: Route
    @Bindable var model: AppModel
    @Bindable var player: PlayerController

    @ViewBuilder
    var body: some View {
        switch route {
        case .home:
            IOSDiscoverView(model: model, player: player)
        case .search:
            IOSSearchView(model: model, player: player)
        case .artist, .album, .playlist, .user:
            IOSBasicDetailView(route: route, model: model, player: player)
        case .cloudMusic,
             .comments,
             .similarSongs,
             .recommendationHistory,
             .listeningFootprints,
             .mv,
             .video,
             .podcast,
             .podcastEpisode,
             .broadcast,
             .podcastSubscriptions,
             .musicStyles,
             .musicStyle:
            IOSLibraryMediaRouteView(route: route, model: model, player: player)
        }
    }
}

private struct IOSBasicDetailView: View {
    let route: Route
    @Bindable var model: AppModel
    @Bindable var player: PlayerController

    var body: some View {
        Group {
            switch model.detailLoads[route] ?? .idle {
            case .idle, .loading:
                VStack(spacing: 12) {
                    ProgressView()
                    Text("正在载入详情")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case let .failed(message):
                ContentUnavailableView {
                    Label("无法打开详情", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                } actions: {
                    Button("重试") { model.loadDetail(route, reload: true) }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                }
            case let .loaded(detail):
                IOSDetailContentView(detail: detail, model: model, player: player)
                    .refreshable { model.loadDetail(route, reload: true) }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .task(id: route) { model.loadDetail(route) }
    }
}

private struct IOSDetailContentView: View {
    let detail: DetailContent
    @Bindable var model: AppModel
    @Bindable var player: PlayerController

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                switch detail {
                case let .artist(artist, songs):
                    IOSArtistDetail(artist: artist, songs: songs, model: model, player: player)
                case let .album(album, songs):
                    IOSAlbumDetail(album: album, songs: songs, model: model, player: player)
                case let .playlist(playlist, songs, trackIDs, loadedTrackCount):
                    IOSPlaylistDetail(
                        playlist: playlist,
                        songs: songs,
                        trackIDs: trackIDs,
                        loadedTrackCount: loadedTrackCount,
                        model: model,
                        player: player
                    )
                case let .user(user, playlists):
                    IOSUserDetail(user: user, playlists: playlists, model: model)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 20)
        }
    }
}

private enum IOSDetailPhase<Value> {
    case loading
    case loaded(Value)
    case failed(String)
}

private enum IOSArtistDetailSection: String, CaseIterable {
    case songs = "歌曲"
    case albums = "专辑"
    case similarArtists = "相似歌手"
    case knowledge = "百科"
}

private struct IOSArtistDetail: View {
    let artist: Artist
    let songs: [Song]
    @Bindable var model: AppModel
    @Bindable var player: PlayerController
    @State private var section = IOSArtistDetailSection.songs
    @State private var albumsPhase: IOSDetailPhase<[MusicArtistAlbum]> = .loading
    @State private var similarArtistsPhase: IOSDetailPhase<[MusicLibraryArtist]> = .loading
    @State private var albumsRetryID = 0
    @State private var similarArtistsRetryID = 0
    @State private var loadedArtistID: Int64?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            IOSDetailHeader(
                title: artist.name,
                category: "歌手",
                symbol: "music.mic",
                description: artist.biography,
                metadata: artistMetadata,
                artwork: artist.artwork,
                circularArtwork: true,
                saveArtwork: saveArtwork
            )
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 132), spacing: 8)], spacing: 8) {
                if let first = songs.first {
                    IOSDetailActionButton(
                        title: "播放热门歌曲",
                        symbol: "play.fill",
                        prominent: true
                    ) {
                        player.play(first, in: songs)
                    }
                }
                let followed = model.artistFollowOverrides[artist.id] ?? artist.isFollowed
                let isUpdatingFollow = model.pendingMutations.contains(.artistFollow(artist.id))
                IOSDetailActionButton(
                    title: followed ? "取消关注" : "关注",
                    symbol: followed ? "person.badge.minus" : "person.badge.plus",
                    showsProgress: isUpdatingFollow,
                    disabled: model.currentUserID == nil || isUpdatingFollow
                ) {
                    model.setArtistFollowed(artist.id, followed: !followed)
                }
            }
            .controlSize(.large)

            Picker("歌手详情", selection: $section) {
                ForEach(IOSArtistDetailSection.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)

            sectionContent
        }
        .task(id: selectedLoadID) { await loadSelectedSection() }
    }

    @ViewBuilder
    private var sectionContent: some View {
        switch section {
        case .songs:
            IOSDetailSectionHeader(title: "热门歌曲", count: songs.count)
            if songs.isEmpty {
                IOSDetailEmptyState(title: "暂无热门歌曲", symbol: "music.note")
            } else {
                IOSSongList(songs: songs, model: model, player: player)
            }
        case .albums:
            IOSDetailCollection(
                title: "专辑",
                emptyTitle: "暂无专辑",
                emptySymbol: "square.stack",
                phase: albumsPhase,
                retry: { albumsRetryID += 1 }
            ) { item in
                IOSDetailNavigationRow(
                    title: item.album.name,
                    subtitle: item.isSubscribed ? "\(item.album.artist.name) · 已收藏" : item.album.artist.name,
                    imageURL: item.album.artwork.remoteURL,
                    symbol: "square.stack"
                ) { model.open(.album(item.album.id)) }
            }
        case .similarArtists:
            IOSDetailCollection(
                title: "相似歌手",
                emptyTitle: "暂无相似歌手",
                emptySymbol: "music.mic",
                phase: similarArtistsPhase,
                retry: { similarArtistsRetryID += 1 }
            ) { item in
                IOSDetailNavigationRow(
                    title: item.name,
                    subtitle: item.isFollowed ? "已关注" : "歌手",
                    imageURL: item.imageURL,
                    symbol: "music.mic",
                    circularArtwork: true
                ) { model.open(.artist(item.id)) }
            }
        case .knowledge:
            IOSKnowledgeDetailSection(
                resource: .artist(artist.id),
                title: artist.name,
                fallbackText: artist.biography,
                model: model
            )
        }
    }

    private var selectedLoadID: String {
        let retryID = section == .albums ? albumsRetryID : similarArtistsRetryID
        return "\(artist.id):\(section.rawValue):\(retryID)"
    }

    private var saveArtwork: (() -> Void)? {
        artist.artwork.remoteURL.map { url in
            { model.saveArtwork(from: ArtworkURLPolicy.highResolutionURL(for: url), title: artist.name) }
        }
    }

    private var artistMetadata: [String] {
        if let songCount = artist.songCount {
            ["\(songCount.formatted()) 首歌曲"]
        } else if !songs.isEmpty {
            ["\(songs.count.formatted()) 首热门歌曲"]
        } else {
            []
        }
    }

    @MainActor
    private func loadSelectedSection() async {
        if loadedArtistID != artist.id {
            loadedArtistID = artist.id
            albumsPhase = .loading
            similarArtistsPhase = .loading
        }
        switch section {
        case .songs, .knowledge:
            return
        case .albums:
            if case .loaded = albumsPhase { return }
            guard let extras = model.extras else {
                albumsPhase = .failed("歌手专辑服务不可用")
                return
            }
            albumsPhase = .loading
            let revision = extras.transport.credentialSnapshotValue().revision
            do {
                let page = try await extras.artistAlbums(
                    artistID: artist.id,
                    expectedCredentialRevision: revision
                )
                try Task.checkCancellation()
                guard extras.transport.credentialSnapshotValue().revision == revision else { return }
                albumsPhase = .loaded(page.albums)
            } catch is CancellationError {
            } catch {
                albumsPhase = .failed(error.localizedDescription)
            }
        case .similarArtists:
            if case .loaded = similarArtistsPhase { return }
            guard let library = model.library else {
                similarArtistsPhase = .failed("相似歌手服务不可用")
                return
            }
            similarArtistsPhase = .loading
            let revision = library.transport.credentialSnapshotValue().revision
            do {
                let values = try await library.similarArtists(
                    to: artist.id,
                    expectedCredentialRevision: revision
                )
                try Task.checkCancellation()
                guard library.transport.credentialSnapshotValue().revision == revision else { return }
                similarArtistsPhase = .loaded(values)
            } catch is CancellationError {
            } catch {
                similarArtistsPhase = .failed(error.localizedDescription)
            }
        }
    }
}

private enum IOSAlbumDetailSection: String, CaseIterable {
    case songs = "歌曲"
    case knowledge = "百科"
}

private struct IOSAlbumDetail: View {
    let album: Album
    let songs: [Song]
    @Bindable var model: AppModel
    @Bindable var player: PlayerController
    @State private var section = IOSAlbumDetailSection.songs

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            IOSDetailHeader(
                title: album.name,
                category: "专辑",
                symbol: "square.stack",
                description: album.description,
                metadata: albumMetadata,
                artwork: album.artwork,
                saveArtwork: saveArtwork
            )
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 132), spacing: 8)], spacing: 8) {
                if let first = songs.first {
                    IOSDetailActionButton(title: "播放", symbol: "play.fill", prominent: true) {
                        player.play(first, in: songs)
                    }
                }
                let subscribed = model.albumSubscriptionOverrides[album.id] ?? album.isSubscribed
                let isUpdatingSubscription = model.pendingMutations.contains(.albumSubscription(album.id))
                IOSDetailActionButton(
                    title: subscribed ? "取消收藏" : "收藏",
                    symbol: subscribed ? "star.slash" : "star",
                    showsProgress: isUpdatingSubscription,
                    disabled: model.currentUserID == nil || isUpdatingSubscription
                ) {
                    model.setAlbumSubscribed(album.id, subscribed: !subscribed)
                }
            }
            .controlSize(.large)

            Picker("专辑详情", selection: $section) {
                ForEach(IOSAlbumDetailSection.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)

            switch section {
            case .songs:
                IOSDetailSectionHeader(title: "歌曲", count: songs.count)
                if songs.isEmpty {
                    IOSDetailEmptyState(title: "专辑暂无歌曲", symbol: "music.note")
                } else {
                    IOSSongList(songs: songs, model: model, player: player)
                }
            case .knowledge:
                IOSKnowledgeDetailSection(
                    resource: .album(album.id),
                    title: album.name,
                    fallbackText: album.description,
                    model: model
                )
            }
        }
    }

    private var saveArtwork: (() -> Void)? {
        album.artwork.remoteURL.map { url in
            { model.saveArtwork(from: ArtworkURLPolicy.highResolutionURL(for: url), title: album.name) }
        }
    }

    private var albumMetadata: [String] {
        var values = [album.artist.name, "\(songs.count.formatted()) 首歌曲"]
        if album.subscriberCount > 0 { values.append("\(album.subscriberCount.formatted()) 人收藏") }
        return values
    }
}

private enum IOSPlaylistDetailSection: String, CaseIterable {
    case songs = "歌曲"
    case similarPlaylists = "相似歌单"
}

private struct IOSPlaylistDetail: View {
    let playlist: Playlist
    let songs: [Song]
    let trackIDs: [Int64]
    let loadedTrackCount: Int
    @Bindable var model: AppModel
    @Bindable var player: PlayerController
    @State private var section = IOSPlaylistDetailSection.songs
    @State private var similarPlaylistsPhase: IOSDetailPhase<[MusicLibraryPlaylist]> = .loading
    @State private var similarPlaylistsRetryID = 0
    @State private var loadedPlaylistID: Int64?
    @State private var removingSong: Song?
    @State private var showsDownloadOptions = false
    @State private var downloadQuality = AudioQuality.standard
    @State private var isAddingDownloads = false
    @State private var downloadTask: Task<Void, Never>?
    @State private var confirmsFavoriteAll = false
    @State private var isFavoritingAll = false
    @State private var favoriteTask: Task<Void, Never>?
    @State private var showsMetadataEditor = false
    @State private var showsSongOrder = false
    @State private var choosesCover = false
    @State private var isPreparingCover = false
    @State private var coverTask: Task<Void, Never>?
    @State private var preparedCover: IOSPreparedPlaylistCover?
    @State private var confirmsPublish = false
    @State private var isPublishing = false
    @State private var publishTask: Task<Void, Never>?
    @State private var managementError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            IOSDetailHeader(
                title: playlist.name,
                category: "歌单",
                symbol: "music.note.list",
                description: playlist.description,
                metadata: playlistMetadata,
                artwork: playlist.artwork,
                saveArtwork: saveArtwork
            )
            actions

            if model.library != nil {
                Picker("歌单详情", selection: $section) {
                    ForEach(IOSPlaylistDetailSection.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
            }

            switch section {
            case .songs:
                IOSDetailSectionHeader(title: "歌曲", count: trackIDs.count)
                if songs.isEmpty && trackIDs.isEmpty {
                    IOSDetailEmptyState(title: "歌单暂无歌曲", symbol: "music.note.list")
                } else {
                    IOSManagedPlaylistSongList(
                        songs: songs,
                        trackIDs: trackIDs,
                        playlist: playlist,
                        model: model,
                        player: player,
                        allowsRemoval: allowsSongRemoval,
                        remove: { removingSong = $0 },
                        hasMore: loadedTrackCount < trackIDs.count,
                        isLoadingMore: model.loadingPlaylistIDs.contains(playlist.id),
                        loadMoreError: model.playlistLoadMoreErrors[playlist.id],
                        onLoadMore: { model.loadMorePlaylistSongs(playlist.id) }
                    )
                }
            case .similarPlaylists:
                IOSDetailCollection(
                    title: "相似歌单",
                    emptyTitle: "暂无相似歌单",
                    emptySymbol: "music.note.list",
                    phase: similarPlaylistsPhase,
                    retry: { similarPlaylistsRetryID += 1 }
                ) { item in
                    IOSDetailNavigationRow(
                        title: item.name,
                        subtitle: item.creatorName.isEmpty ? "歌单" : item.creatorName,
                        imageURL: item.coverURL,
                        symbol: "music.note.list"
                    ) { model.open(.playlist(item.id)) }
                }
            }
        }
        .task(id: "\(playlist.id):\(section.rawValue):\(similarPlaylistsRetryID)") {
            await loadSimilarPlaylistsIfNeeded()
        }
        .sheet(isPresented: $showsDownloadOptions) { downloadOptions }
        .sheet(isPresented: $showsMetadataEditor) {
            if let context = mutationContext, let library = model.library {
                IOSPlaylistMetadataSheet(
                    playlist: playlist,
                    library: library,
                    model: model,
                    context: context
                )
            }
        }
        .sheet(isPresented: $showsSongOrder) {
            if let context = mutationContext, let library = model.library {
                IOSPlaylistSongOrderSheet(
                    playlistID: playlist.id,
                    trackIDs: trackIDs,
                    loadedSongs: songs,
                    repository: model.repository,
                    library: library,
                    model: model,
                    context: context
                )
            }
        }
        .sheet(item: $preparedCover) { item in
            if let library = model.library {
                IOSPlaylistCoverUpdateSheet(
                    playlistName: playlist.name,
                    item: item,
                    save: { try await updateCover(item, library: library) }
                )
            }
        }
        .fileImporter(
            isPresented: $choosesCover,
            allowedContentTypes: [.image],
            allowsMultipleSelection: false,
            onCompletion: prepareCover
        )
        .confirmationDialog("从歌单移除歌曲？", isPresented: Binding(
            get: { removingSong != nil },
            set: { if !$0 { removingSong = nil } }
        )) {
            Button("移除", role: .destructive) {
                guard let song = removingSong else { return }
                model.removeSongFromPlaylist(
                    song.id,
                    playlistID: playlist.id,
                    isFavoritePlaylist: playlist.specialType == 5
                )
                removingSong = nil
            }
            Button("取消", role: .cancel) { removingSong = nil }
        } message: {
            Text(removingSong.map { "将“\($0.primaryName)”从此歌单移除。" } ?? "")
        }
        .confirmationDialog("收藏全部歌曲？", isPresented: $confirmsFavoriteAll) {
            Button("全部收藏", action: favoriteAll)
            Button("取消", role: .cancel) {}
        } message: {
            Text("将收藏尚未收藏的 \(unlikedSongCount) 首歌曲。")
        }
        .confirmationDialog("将歌单设为公开？", isPresented: $confirmsPublish) {
            Button("设为公开", role: .destructive, action: makePublic)
            Button("取消", role: .cancel) {}
        } message: {
            Text("公开后，本功能不能将它改回私密歌单。")
        }
        .alert("歌单操作失败", isPresented: Binding(
            get: { managementError != nil },
            set: { if !$0 { managementError = nil } }
        )) {
            Button("好") { managementError = nil }
        } message: {
            Text(managementError ?? "")
        }
        .onDisappear {
            downloadTask?.cancel()
            favoriteTask?.cancel()
            coverTask?.cancel()
            publishTask?.cancel()
        }
    }

    private var actions: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 132), spacing: 8)], spacing: 8) {
            if let first = songs.first {
                IOSDetailActionButton(title: "播放全部", symbol: "play.fill", prominent: true) {
                    player.play(first, in: songs, allSongIDs: trackIDs, playlistID: playlist.id)
                }
            }
            if model.downloads != nil {
                IOSDetailActionButton(
                    title: isAddingDownloads ? "正在加入" : "全部下载",
                    symbol: "arrow.down.circle",
                    showsProgress: isAddingDownloads,
                    disabled: trackIDs.isEmpty || isAddingDownloads
                ) {
                    downloadQuality = model.settings.quality
                    showsDownloadOptions = true
                }
            }
            if playlist.specialType != 5, unlikedSongCount > 0 {
                IOSDetailActionButton(
                    title: isFavoritingAll ? "正在收藏" : "全部收藏",
                    symbol: "heart",
                    showsProgress: isFavoritingAll,
                    disabled: mutationContext == nil || isFavoritingAll
                ) { confirmsFavoriteAll = true }
            }
            if model.currentUserID != playlist.creatorID {
                let subscribed = model.playlistSubscriptionOverrides[playlist.id] ?? playlist.isSubscribed
                IOSDetailActionButton(
                    title: subscribed ? "取消收藏歌单" : "收藏歌单",
                    symbol: subscribed ? "star.slash" : "star",
                    disabled: model.currentUserID == nil
                        || model.pendingMutations.contains(.playlistSubscription(playlist.id))
                ) { model.setPlaylistSubscribed(playlist.id, subscribed: !subscribed) }
            }
            if playlist.creatorID > 0 {
                IOSDetailActionButton(title: "查看创建者", symbol: "person.crop.circle") {
                    model.open(.user(playlist.creatorID))
                }
            }
            if canManagePlaylist {
                Menu {
                    Button("编辑歌单", systemImage: "pencil") { showsMetadataEditor = true }
                    Button("更新封面", systemImage: "photo") { choosesCover = true }
                    Button("歌曲排序", systemImage: "arrow.up.arrow.down") { showsSongOrder = true }
                        .disabled(trackIDs.count < 2)
                    if playlist.isPrivate {
                        Divider()
                        Button("设为公开", systemImage: "lock.open", role: .destructive) {
                            confirmsPublish = true
                        }
                    }
                } label: {
                    HStack(spacing: 7) {
                        if isPreparingCover || isPublishing { ProgressView().controlSize(.small) }
                        else { Image(systemName: "ellipsis.circle") }
                        Text("管理歌单")
                    }
                    .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
                .disabled(isPreparingCover || isPublishing)
                .accessibilityLabel(isPreparingCover ? "正在准备封面" : isPublishing ? "正在设为公开" : "管理歌单")
            }
        }
        .controlSize(.large)
    }

    private var downloadOptions: some View {
        NavigationStack {
            Form {
                Section("下载设置") {
                    Picker("音质", selection: $downloadQuality) {
                        ForEach(AudioQuality.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    LabeledContent("歌曲", value: "\(trackIDs.count.formatted()) 首")
                }
            }
            .navigationTitle("全部下载")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { showsDownloadOptions = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("加入队列") {
                        showsDownloadOptions = false
                        downloadAll()
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }

    private var mutationContext: IOSPlaylistMutationContext? {
        guard let library = model.library,
              let userID = model.currentUserID,
              let revision = model.confirmedAccountCredentialRevision
        else { return nil }
        let context = IOSPlaylistMutationContext(userID: userID, credentialRevision: revision)
        return context.matches(model: model, library: library) ? context : nil
    }

    private var canManagePlaylist: Bool {
        playlist.isUserEditable(by: model.currentUserID) && mutationContext != nil
    }

    private var allowsSongRemoval: Bool {
        playlist.creatorID == model.currentUserID && !playlist.isReadOnly && mutationContext != nil
    }

    private var unlikedSongCount: Int {
        trackIDs.filter { !model.likedSongIDs.contains($0) }.count
    }

    private var saveArtwork: (() -> Void)? {
        playlist.artwork.remoteURL.map { url in
            { model.saveArtwork(from: ArtworkURLPolicy.highResolutionURL(for: url), title: playlist.name) }
        }
    }

    private var playlistMetadata: [String] {
        var values = [playlist.creator, "\(trackIDs.count.formatted()) 首歌曲"]
        if playlist.isPrivate { values.append("私密歌单") }
        if !playlist.tags.isEmpty { values.append(playlist.tags.joined(separator: " · ")) }
        if playlist.subscriberCount > 0 { values.append("\(playlist.subscriberCount.formatted()) 人收藏") }
        return values.filter { !$0.isEmpty }
    }

    @MainActor
    private func loadSimilarPlaylistsIfNeeded() async {
        if loadedPlaylistID != playlist.id {
            loadedPlaylistID = playlist.id
            similarPlaylistsPhase = .loading
        }
        guard section == .similarPlaylists else { return }
        if case .loaded = similarPlaylistsPhase { return }
        guard let library = model.library else {
            similarPlaylistsPhase = .failed("相似歌单服务不可用")
            return
        }
        similarPlaylistsPhase = .loading
        let revision = library.transport.credentialSnapshotValue().revision
        do {
            let values = try await library.similarPlaylists(to: playlist.id)
            try Task.checkCancellation()
            guard library.transport.credentialSnapshotValue().revision == revision else { return }
            similarPlaylistsPhase = .loaded(values)
        } catch is CancellationError {
        } catch {
            similarPlaylistsPhase = .failed(error.localizedDescription)
        }
    }

    private func downloadAll() {
        guard !isAddingDownloads else { return }
        isAddingDownloads = true
        downloadTask = Task { @MainActor in
            defer {
                isAddingDownloads = false
                downloadTask = nil
            }
            do {
                let count = try await model.downloadPlaylist(
                    loadedSongs: songs,
                    trackIDs: trackIDs,
                    quality: downloadQuality
                )
                try Task.checkCancellation()
                model.showToast(count == 0 ? "没有需要加入的歌曲" : "已加入 \(count) 首歌曲")
            } catch is CancellationError {
            } catch {
                managementError = "加入下载队列失败：\(error.localizedDescription)"
            }
        }
    }

    private func favoriteAll() {
        guard !isFavoritingAll,
              let context = mutationContext,
              let library = model.library
        else { return }
        isFavoritingAll = true
        favoriteTask = Task { @MainActor in
            defer {
                isFavoritingAll = false
                favoriteTask = nil
            }
            do {
                let count = try await model.favoriteSongs(trackIDs)
                try Task.checkCancellation()
                guard context.matches(model: model, library: library) else { return }
                model.showToast(count == 0 ? "歌曲均已收藏" : "已收藏 \(count) 首歌曲")
            } catch is CancellationError {
            } catch {
                guard context.matches(model: model, library: library) else { return }
                managementError = "部分歌曲收藏失败：\(error.localizedDescription)"
            }
        }
    }

    private func prepareCover(_ result: Result<[URL], any Error>) {
        guard let context = mutationContext else { return }
        guard case let .success(urls) = result, let url = urls.first else {
            if case let .failure(error) = result { managementError = error.localizedDescription }
            return
        }
        coverTask?.cancel()
        isPreparingCover = true
        coverTask = Task { @MainActor in
            defer {
                isPreparingCover = false
                coverTask = nil
            }
            let worker = Task.detached(priority: .userInitiated) {
                try PlaylistCoverProcessor.process(url: url)
            }
            do {
                let cover = try await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: {
                    worker.cancel()
                }
                try Task.checkCancellation()
                guard let library = model.library, context.matches(model: model, library: library) else {
                    throw CancellationError()
                }
                preparedCover = IOSPreparedPlaylistCover(cover: cover, context: context)
            } catch is CancellationError {
            } catch {
                managementError = error.localizedDescription
            }
        }
    }

    @MainActor
    private func updateCover(_ item: IOSPreparedPlaylistCover, library: LiveMusicLibrary) async throws {
        guard item.context.matches(model: model, library: library) else { throw CancellationError() }
        try await library.updatePlaylistCover(
            playlist.id,
            cover: item.cover,
            expectedCredentialRevision: item.context.credentialRevision
        )
        try Task.checkCancellation()
        guard item.context.matches(model: model, library: library) else { throw CancellationError() }
        do {
            _ = try await model.reloadPlaylist(playlist.id)
            model.showToast("歌单封面已更新")
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw IOSDetailOperationError(message: "封面已更新，但重新读取失败：\(error.localizedDescription)")
        }
    }

    private func makePublic() {
        guard !isPublishing,
              playlist.isPrivate,
              let context = mutationContext,
              let library = model.library,
              playlist.isUserEditable(by: context.userID)
        else { return }
        isPublishing = true
        publishTask = Task { @MainActor in
            defer {
                isPublishing = false
                publishTask = nil
            }
            do {
                guard context.matches(model: model, library: library) else { throw CancellationError() }
                try await library.makePlaylistPublic(
                    playlist.id,
                    expectedCredentialRevision: context.credentialRevision
                )
                try Task.checkCancellation()
                guard context.matches(model: model, library: library) else { throw CancellationError() }
                do {
                    _ = try await model.reloadPlaylist(playlist.id)
                    model.showToast("歌单已设为公开")
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    managementError = "歌单已设为公开，但重新读取失败：\(error.localizedDescription)"
                }
            } catch is CancellationError {
            } catch {
                managementError = error.localizedDescription
            }
        }
    }
}

private enum IOSUserDetailSection: String, CaseIterable {
    case playlists = "公开歌单"
    case users = "关注用户"
    case artists = "关注歌手"
}

private struct IOSUserDetail: View {
    let user: UserProfile
    let playlists: [Playlist]
    @Bindable var model: AppModel
    @State private var section = IOSUserDetailSection.playlists
    @State private var usersPhase: IOSDetailPhase<[MusicLibraryUser]> = .loading
    @State private var artistsPhase: IOSDetailPhase<[MusicLibraryArtist]> = .loading
    @State private var usersRetryID = 0
    @State private var artistsRetryID = 0
    @State private var loadedUserID: Int64?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            IOSDetailHeader(
                title: user.nickname,
                category: "用户",
                symbol: "person.crop.circle",
                description: profileDescription,
                metadata: userMetadata,
                artwork: user.artwork,
                circularArtwork: true,
                saveArtwork: saveArtwork
            )
            if model.currentUserID != user.id {
                let followed = model.userFollowOverrides[user.id] ?? user.isFollowed
                Button { model.setUserFollowed(user.id, followed: !followed) } label: {
                    Label(
                        followed ? "取消关注" : "关注用户",
                        systemImage: followed ? "person.badge.minus" : "person.badge.plus"
                    )
                    .frame(minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .controlSize(.large)
                .disabled(model.currentUserID == nil || model.pendingMutations.contains(.userFollow(user.id)))
            }

            Picker("用户详情", selection: $section) {
                ForEach(IOSUserDetailSection.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)

            sectionContent
        }
        .task(id: selectedLoadID) { await loadSelectedSection() }
    }

    @ViewBuilder
    private var sectionContent: some View {
        switch section {
        case .playlists:
            IOSDetailSectionHeader(title: "公开歌单", count: playlists.count)
            if playlists.isEmpty {
                IOSDetailEmptyState(title: "暂无公开歌单", symbol: "music.note.list")
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(playlists) { playlist in
                        IOSDetailNavigationRow(
                            title: playlist.name,
                            subtitle: "\(playlist.trackCount.formatted()) 首歌曲",
                            imageURL: playlist.artwork.remoteURL,
                            symbol: "music.note.list"
                        ) { model.open(.playlist(playlist.id)) }
                    }
                }
            }
        case .users:
            IOSDetailCollection(
                title: "关注用户",
                emptyTitle: "暂无公开关注用户",
                emptySymbol: "person.2",
                phase: usersPhase,
                retry: { usersRetryID += 1 }
            ) { item in
                IOSDetailNavigationRow(
                    title: item.nickname,
                    subtitle: item.signature.isEmpty ? "用户" : item.signature,
                    imageURL: item.avatarURL,
                    symbol: "person.crop.circle",
                    circularArtwork: true
                ) { model.open(.user(item.id)) }
            }
        case .artists:
            IOSDetailCollection(
                title: "关注歌手",
                emptyTitle: "暂无公开关注歌手",
                emptySymbol: "music.mic",
                phase: artistsPhase,
                retry: { artistsRetryID += 1 }
            ) { item in
                IOSDetailNavigationRow(
                    title: item.name,
                    subtitle: item.isFollowed ? "已关注" : "歌手",
                    imageURL: item.imageURL,
                    symbol: "music.mic",
                    circularArtwork: true
                ) { model.open(.artist(item.id)) }
            }
        }
    }

    private var selectedLoadID: String {
        let retryID = section == .users ? usersRetryID : artistsRetryID
        return "\(user.id):\(section.rawValue):\(retryID)"
    }

    private var saveArtwork: (() -> Void)? {
        user.artwork.remoteURL.map { url in
            { model.saveArtwork(from: ArtworkURLPolicy.highResolutionURL(for: url), title: user.nickname) }
        }
    }

    private var profileDescription: String {
        [user.signature, user.detailDescription].filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    private var userMetadata: [String] {
        var values: [String] = []
        if user.level > 0 { values.append("Level \(user.level)") }
        if user.listenSongs > 0 { values.append("听过 \(user.listenSongs.formatted()) 首") }
        if user.followerCount > 0 { values.append("\(user.followerCount.formatted()) 位关注者") }
        if user.followingCount > 0 { values.append("关注 \(user.followingCount.formatted()) 人") }
        if user.followsCurrentUser { values.append("关注了你") }
        return values
    }

    @MainActor
    private func loadSelectedSection() async {
        if loadedUserID != user.id {
            loadedUserID = user.id
            usersPhase = .loading
            artistsPhase = .loading
        }
        guard section != .playlists else { return }
        guard let library = model.library else {
            if section == .users { usersPhase = .failed("关注关系服务不可用") }
            else { artistsPhase = .failed("关注关系服务不可用") }
            return
        }
        let revision = library.transport.credentialSnapshotValue().revision
        do {
            switch section {
            case .playlists:
                return
            case .users:
                if case .loaded = usersPhase { return }
                usersPhase = .loading
                let values = try await library.followingUsers(userID: user.id)
                try Task.checkCancellation()
                guard library.transport.credentialSnapshotValue().revision == revision else { return }
                usersPhase = .loaded(values)
            case .artists:
                if case .loaded = artistsPhase { return }
                artistsPhase = .loading
                let values = try await library.followedArtists(userID: user.id)
                try Task.checkCancellation()
                guard library.transport.credentialSnapshotValue().revision == revision else { return }
                artistsPhase = .loaded(values)
            }
        } catch is CancellationError {
        } catch {
            let message = error.localizedDescription
            if section == .users { usersPhase = .failed(message) }
            else if section == .artists { artistsPhase = .failed(message) }
        }
    }
}

private struct IOSDetailHeader: View {
    let title: String
    let category: String
    let symbol: String
    let description: String
    let metadata: [String]
    let artwork: Artwork
    var circularArtwork = false
    var saveArtwork: (() -> Void)? = nil

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 16) {
                cover(size: 116)
                identity
            }
            VStack(alignment: .leading, spacing: 14) {
                cover(size: 176)
                identity
            }
        }
        if !description.isEmpty {
            Text(description)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        Divider()
    }

    private var identity: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(category, systemImage: symbol)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.red)
            Text(title)
                .font(.title2.bold())
                .fixedSize(horizontal: false, vertical: true)
            if !metadata.isEmpty {
                Text(metadata.joined(separator: " · "))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func cover(size: CGFloat) -> some View {
        ZStack(alignment: .bottomTrailing) {
            IOSArtworkView(artwork: artwork)
                .clipShape(
                    circularArtwork
                        ? AnyShape(Circle())
                        : AnyShape(RoundedRectangle(cornerRadius: 8))
                )
                .accessibilityLabel("\(title)封面")
            if let saveArtwork {
                Button(action: saveArtwork) {
                    Image(systemName: "square.and.arrow.down")
                        .frame(width: 44, height: 44)
                        .background(.regularMaterial, in: Circle())
                }
                .buttonStyle(IOSPressedButtonStyle())
                .padding(4)
                .accessibilityLabel("保存\(title)封面")
            }
        }
        .frame(width: size, height: size)
    }
}

private struct IOSDetailSectionHeader: View {
    let title: String
    let count: Int

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.headline)
            Spacer()
            Text(count.formatted())
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }
}

private struct IOSDetailEmptyState: View {
    let title: String
    let symbol: String

    var body: some View {
        Label(title, systemImage: symbol)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 112)
    }
}

private struct IOSDetailCollection<Item: Identifiable, Row: View>: View {
    let title: String
    let emptyTitle: String
    let emptySymbol: String
    let phase: IOSDetailPhase<[Item]>
    let retry: () -> Void
    @ViewBuilder let row: (Item) -> Row

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.headline)
                Spacer()
                if case let .loaded(items) = phase {
                    Text(items.count.formatted())
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            switch phase {
            case .loading:
                ProgressView("正在载入\(title)")
                    .frame(maxWidth: .infinity, minHeight: 112)
            case let .failed(message):
                ContentUnavailableView {
                    Label("无法载入\(title)", systemImage: "wifi.exclamationmark")
                } description: {
                    Text(message)
                } actions: {
                    Button("重试", action: retry)
                        .buttonStyle(.bordered)
                }
                .frame(maxWidth: .infinity, minHeight: 152)
            case let .loaded(items):
                if items.isEmpty {
                    IOSDetailEmptyState(title: emptyTitle, symbol: emptySymbol)
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(items) { item in
                            row(item)
                            Divider().padding(.leading, 64)
                        }
                    }
                }
            }
        }
    }
}

private struct IOSDetailNavigationRow: View {
    let title: String
    let subtitle: String
    let imageURL: URL?
    let symbol: String
    var circularArtwork = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                IOSArtworkView(
                    artwork: Artwork(symbol: symbol, accent: .red, remoteURL: imageURL)
                )
                .clipShape(
                    circularArtwork
                        ? AnyShape(Circle())
                        : AnyShape(RoundedRectangle(cornerRadius: 8))
                )
                .frame(width: 52, height: 52)
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.body.weight(.medium))
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    if !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity, minHeight: 68, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(IOSPressedButtonStyle())
        .accessibilityLabel(subtitle.isEmpty ? title : "\(title)，\(subtitle)")
        .accessibilityHint("打开详情")
    }
}

private struct IOSDetailActionButton: View {
    let title: String
    let symbol: String
    var prominent = false
    var showsProgress = false
    var disabled = false
    let action: () -> Void

    @ViewBuilder
    var body: some View {
        if prominent {
            button
                .buttonStyle(.borderedProminent)
                .tint(.red)
        } else {
            button.buttonStyle(.bordered)
        }
    }

    private var button: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                if showsProgress {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: symbol)
                }
                Text(title)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, minHeight: 44)
        }
        .disabled(disabled)
        .accessibilityLabel(showsProgress ? "\(title)，处理中" : title)
    }
}

private struct IOSManagedPlaylistSongList: View {
    let songs: [Song]
    let trackIDs: [Int64]
    let playlist: Playlist
    @Bindable var model: AppModel
    @Bindable var player: PlayerController
    let allowsRemoval: Bool
    let remove: (Song) -> Void
    let hasMore: Bool
    let isLoadingMore: Bool
    let loadMoreError: String?
    let onLoadMore: () -> Void

    var body: some View {
        LazyVStack(spacing: 0) {
            ForEach(songs) { song in
                IOSManagedPlaylistSongRow(
                    song: song,
                    songs: songs,
                    trackIDs: trackIDs,
                    playlist: playlist,
                    model: model,
                    player: player,
                    allowsRemoval: allowsRemoval,
                    remove: { remove(song) }
                )
                Divider().padding(.leading, 64)
            }
            if let loadMoreError {
                IOSInlineRetry(message: loadMoreError, action: onLoadMore)
            } else if hasMore {
                HStack(spacing: 10) {
                    if isLoadingMore {
                        ProgressView()
                        Text("正在载入更多歌曲").foregroundStyle(.secondary)
                    } else {
                        Button("载入更多", action: onLoadMore)
                            .buttonStyle(.bordered)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 60)
                .onAppear {
                    if !isLoadingMore { onLoadMore() }
                }
            }
        }
    }
}

private struct IOSManagedPlaylistSongRow: View {
    let song: Song
    let songs: [Song]
    let trackIDs: [Int64]
    let playlist: Playlist
    @Bindable var model: AppModel
    @Bindable var player: PlayerController
    let allowsRemoval: Bool
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: play) {
                HStack(spacing: 12) {
                    IOSArtworkView(artwork: song.album.artwork)
                        .frame(width: 52, height: 52)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(song.name)
                            .font(.body.weight(.medium))
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                            .multilineTextAlignment(.leading)
                        Text(song.artistsDisplay)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                        Text(song.album.name)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Text(song.durationText)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(IOSPressedButtonStyle())
            .accessibilityLabel("播放\(song.name)，\(song.artistsDisplay)")

            Menu {
                menuActions
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("\(song.name)的更多操作")
        }
        .frame(minHeight: 68)
        .contextMenu { menuActions }
    }

    @ViewBuilder
    private var menuActions: some View {
        IOSSongActionsMenu(
            song: song,
            songs: songs,
            allSongIDs: trackIDs,
            playlistID: playlist.id,
            model: model,
            player: player
        )
        if allowsRemoval {
            Divider()
            Button("从歌单移除", systemImage: "trash", role: .destructive, action: remove)
                .disabled(model.pendingMutations.contains(
                    .playlistSong(playlistID: playlist.id, songID: song.id)
                ))
        }
    }

    private func play() {
        player.play(song, in: songs, allSongIDs: trackIDs, playlistID: playlist.id)
    }
}

private struct IOSKnowledgeDetailSection: View {
    let resource: MusicKnowledgeResource
    let title: String
    let fallbackText: String
    @Bindable var model: AppModel
    @State private var phase: IOSDetailPhase<[MusicKnowledgeBlock]> = .loading
    @State private var retryID = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("音乐百科").font(.headline)
            switch phase {
            case .loading:
                ProgressView("正在载入百科")
                    .frame(maxWidth: .infinity, minHeight: 144)
            case let .failed(message):
                if fallbackBlocks.isEmpty {
                    ContentUnavailableView {
                        Label("百科载入失败", systemImage: "wifi.exclamationmark")
                    } description: {
                        Text(message)
                    } actions: {
                        Button("重试") { retryID += 1 }
                            .buttonStyle(.bordered)
                    }
                    .frame(maxWidth: .infinity, minHeight: 160)
                } else {
                    knowledgeContent(fallbackBlocks)
                    IOSInlineRetry(message: "扩展百科载入失败：\(message)") { retryID += 1 }
                }
            case let .loaded(blocks):
                knowledgeContent(blocks.isEmpty ? fallbackBlocks : blocks)
            }
        }
        .task(id: "\(resource):\(retryID)") { await load() }
    }

    private var fallbackBlocks: [MusicKnowledgeBlock] {
        let text = fallbackText.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? [] : [.text(id: "fallback", title: "简介", body: text)]
    }

    @ViewBuilder
    private func knowledgeContent(_ blocks: [MusicKnowledgeBlock]) -> some View {
        if blocks.isEmpty {
            ContentUnavailableView(
                "暂无百科资料",
                systemImage: "text.book.closed",
                description: Text("\(title)暂时没有可显示的百科内容。")
            )
            .frame(maxWidth: .infinity, minHeight: 144)
        } else {
            LazyVStack(alignment: .leading, spacing: 24) {
                ForEach(blocks) { block in
                    knowledgeBlock(block)
                }
            }
        }
    }

    @ViewBuilder
    private func knowledgeBlock(_ block: MusicKnowledgeBlock) -> some View {
        switch block {
        case let .text(_, heading, body):
            VStack(alignment: .leading, spacing: 8) {
                Text(heading).font(.title3.weight(.semibold))
                Text(body)
                    .font(.body)
                    .lineSpacing(5)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case let .image(_, url, caption):
            VStack(alignment: .leading, spacing: 8) {
                CachedAsyncImage(url: url) { phase in
                    switch phase {
                    case let .success(image):
                        image.resizable().scaledToFit()
                    case .empty:
                        ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                    case .failure:
                        ContentUnavailableView("图片载入失败", systemImage: "photo")
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 216)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .accessibilityLabel(caption.isEmpty ? "百科图片" : caption)
                if !caption.isEmpty {
                    Text(caption).font(.caption).foregroundStyle(.secondary)
                }
            }
        case let .metric(_, heading, value):
            VStack(alignment: .leading, spacing: 4) {
                Text(heading).font(.caption).foregroundStyle(.secondary)
                Text(value).font(.body).fixedSize(horizontal: false, vertical: true)
            }
        case let .resource(_, resourceTitle, route):
            Button { model.open(route) } label: {
                Label(resourceTitle, systemImage: "arrow.up.right.square")
                    .frame(minHeight: 44)
            }
            .buttonStyle(.bordered)
        }
    }

    @MainActor
    private func load() async {
        guard let library = model.knowledgeLibrary else {
            phase = .loaded([])
            return
        }
        phase = .loading
        let revision = library.transport.credentialSnapshotValue().revision
        do {
            let blocks = try await library.knowledge(for: resource)
            try Task.checkCancellation()
            guard library.transport.credentialSnapshotValue().revision == revision else { return }
            phase = .loaded(blocks)
        } catch is CancellationError {
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }
}

private struct IOSPlaylistMutationContext: Equatable, Sendable {
    let userID: Int64
    let credentialRevision: UInt64

    @MainActor
    func matches(model: AppModel, library: LiveMusicLibrary) -> Bool {
        userID == model.currentUserID
            && credentialRevision == model.confirmedAccountCredentialRevision
            && credentialRevision == library.transport.credentialSnapshotValue().revision
    }
}

private struct IOSPreparedPlaylistCover: Identifiable {
    let id = UUID()
    let cover: ProcessedPlaylistCover
    let context: IOSPlaylistMutationContext
}

private struct IOSDetailOperationError: LocalizedError, Sendable {
    let message: String
    var errorDescription: String? { message }
}

private struct IOSPlaylistMetadataSheet: View {
    let playlist: Playlist
    let library: LiveMusicLibrary
    @Bindable var model: AppModel
    let context: IOSPlaylistMutationContext

    @Environment(\.dismiss) private var dismiss
    @State private var baseline: Playlist
    @State private var draft: PlaylistMetadataDraft
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var confirmsDiscard = false
    @State private var saveTask: Task<Void, Never>?

    init(
        playlist: Playlist,
        library: LiveMusicLibrary,
        model: AppModel,
        context: IOSPlaylistMutationContext
    ) {
        self.playlist = playlist
        self.library = library
        self.model = model
        self.context = context
        _baseline = State(initialValue: playlist)
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
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .navigationTitle("编辑歌单")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消", action: requestDismiss)
                        .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(action: submit) {
                        if isSaving {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("保存")
                        }
                    }
                    .disabled(!canSave)
                    .accessibilityLabel(isSaving ? "正在保存歌单信息" : "保存歌单信息")
                }
            }
            .confirmationDialog("放弃未保存的修改？", isPresented: $confirmsDiscard) {
                Button("放弃修改", role: .destructive) { dismiss() }
                Button("继续编辑", role: .cancel) {}
            }
        }
        .interactiveDismissDisabled(isSaving || hasChanges)
        .onDisappear { saveTask?.cancel() }
        .onChange(of: model.currentUserID) { _, _ in dismissIfContextChanged() }
        .onChange(of: model.confirmedAccountCredentialRevision) { _, _ in dismissIfContextChanged() }
    }

    private var changes: [PlaylistMetadataChange] { draft.changes(from: baseline) }
    private var hasChanges: Bool { !changes.isEmpty }
    private var canSave: Bool {
        !isSaving
            && !draft.normalizedName.isEmpty
            && hasChanges
            && context.matches(model: model, library: library)
    }

    private func requestDismiss() {
        if hasChanges { confirmsDiscard = true }
        else { dismiss() }
    }

    private func dismissIfContextChanged() {
        guard !context.matches(model: model, library: library) else { return }
        saveTask?.cancel()
        dismiss()
    }

    private func submit() {
        let pendingChanges = changes
        guard !pendingChanges.isEmpty, canSave else { return }
        errorMessage = nil
        isSaving = true
        saveTask = Task { @MainActor in
            var completedCount = 0
            defer {
                isSaving = false
                saveTask = nil
            }
            do {
                for change in pendingChanges {
                    try Task.checkCancellation()
                    guard context.matches(model: model, library: library) else {
                        throw CancellationError()
                    }
                    switch change {
                    case let .name(name):
                        try await library.updatePlaylistName(
                            playlist.id,
                            name: name,
                            expectedCredentialRevision: context.credentialRevision
                        )
                    case let .description(description):
                        try await library.updatePlaylistDescription(
                            playlist.id,
                            description: description,
                            expectedCredentialRevision: context.credentialRevision
                        )
                    case let .tags(tags):
                        try await library.updatePlaylistTags(
                            playlist.id,
                            tags: tags,
                            expectedCredentialRevision: context.credentialRevision
                        )
                    }
                    guard context.matches(model: model, library: library) else {
                        throw CancellationError()
                    }
                    completedCount += 1
                }

                let refreshed = try await model.reloadPlaylist(playlist.id)
                try Task.checkCancellation()
                guard context.matches(model: model, library: library) else {
                    throw CancellationError()
                }
                let rejected = pendingChanges.filter { !$0.isReflected(in: refreshed) }
                baseline = refreshed
                draft = PlaylistMetadataDraft(playlist: refreshed)
                guard rejected.isEmpty else {
                    errorMessage = rejected.contains(where: {
                        if case .tags = $0 { true } else { false }
                    })
                        ? "标签未保存。请使用网易云支持的官方歌单标签。"
                        : "部分内容未被服务器保存，已显示重新读取的结果。"
                    return
                }
                model.showToast("歌单信息已保存")
                dismiss()
            } catch is CancellationError {
                if !context.matches(model: model, library: library) { dismiss() }
            } catch {
                guard context.matches(model: model, library: library) else {
                    dismiss()
                    return
                }
                if completedCount > 0,
                   let refreshed = try? await model.reloadPlaylist(playlist.id),
                   context.matches(model: model, library: library) {
                    baseline = refreshed
                    draft = PlaylistMetadataDraft(playlist: refreshed)
                }
                errorMessage = completedCount > 0
                    ? "部分内容可能已保存，已尝试重新读取：\(error.localizedDescription)"
                    : error.localizedDescription
            }
        }
    }
}

private struct IOSPlaylistSongOrderSheet: View {
    let playlistID: Int64
    let original: [Int64]
    let repository: any MusicRepository
    let library: LiveMusicLibrary
    @Bindable var model: AppModel
    let context: IOSPlaylistMutationContext

    @Environment(\.dismiss) private var dismiss
    @State private var draft: [Int64]
    @State private var songsByID: [Int64: Song]
    @State private var isLoading = true
    @State private var loadID = 0
    @State private var loadError: String?
    @State private var isSaving = false
    @State private var writeCompleted = false
    @State private var saveError: String?
    @State private var confirmsDiscard = false
    @State private var saveTask: Task<Void, Never>?

    init(
        playlistID: Int64,
        trackIDs: [Int64],
        loadedSongs: [Song],
        repository: any MusicRepository,
        library: LiveMusicLibrary,
        model: AppModel,
        context: IOSPlaylistMutationContext
    ) {
        self.playlistID = playlistID
        original = trackIDs
        self.repository = repository
        self.library = library
        self.model = model
        self.context = context
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
                    ProgressView("正在载入完整歌单")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let loadError {
                    ContentUnavailableView {
                        Label("歌曲载入失败", systemImage: "wifi.exclamationmark")
                    } description: {
                        Text(loadError)
                    } actions: {
                        Button("重试") { loadID += 1 }
                            .buttonStyle(.bordered)
                    }
                } else {
                    List {
                        ForEach(draft, id: \.self) { trackID in
                            HStack(spacing: 12) {
                                Image(systemName: "music.note")
                                    .foregroundStyle(.secondary)
                                    .frame(width: 24)
                                    .accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(songsByID[trackID]?.name ?? "歌曲 \(trackID)")
                                        .fixedSize(horizontal: false, vertical: true)
                                    if let artists = songsByID[trackID]?.artistsDisplay, !artists.isEmpty {
                                        Text(artists)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(2)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .frame(minHeight: 44)
                        }
                        .onMove { source, destination in
                            guard !isSaving else { return }
                            draft.move(fromOffsets: source, toOffset: destination)
                            saveError = nil
                        }
                    }
                    .environment(\.editMode, .constant(.active))
                }
            }
            .navigationTitle("歌曲排序")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消", action: requestDismiss)
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
                    .disabled(!canSave)
                    .accessibilityLabel(isSaving ? "正在保存歌曲顺序" : "保存歌曲顺序")
                }
            }
            .safeAreaInset(edge: .bottom) {
                if let saveError {
                    Label(saveError, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                        .background(.bar)
                }
            }
            .confirmationDialog("放弃未保存的排序？", isPresented: $confirmsDiscard) {
                Button("放弃排序", role: .destructive) { dismiss() }
                Button("继续排序", role: .cancel) {}
            }
        }
        .presentationDetents([.large])
        .interactiveDismissDisabled(isSaving || (!writeCompleted && draft != original))
        .task(id: loadID) { await loadSongs() }
        .onDisappear { saveTask?.cancel() }
        .onChange(of: model.currentUserID) { _, _ in dismissIfContextChanged() }
        .onChange(of: model.confirmedAccountCredentialRevision) { _, _ in dismissIfContextChanged() }
    }

    private var canSave: Bool {
        !isSaving
            && !isLoading
            && loadError == nil
            && (writeCompleted || draft != original)
            && context.matches(model: model, library: library)
    }

    private func requestDismiss() {
        if !writeCompleted, draft != original { confirmsDiscard = true }
        else { dismiss() }
    }

    private func dismissIfContextChanged() {
        guard !context.matches(model: model, library: library) else { return }
        saveTask?.cancel()
        dismiss()
    }

    @MainActor
    private func loadSongs() async {
        guard context.matches(model: model, library: library) else {
            dismiss()
            return
        }
        isLoading = true
        loadError = nil
        do {
            let songs = try await repository.songs(ids: original)
            try Task.checkCancellation()
            guard context.matches(model: model, library: library) else {
                throw CancellationError()
            }
            songsByID.merge(songs.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
            isLoading = false
        } catch is CancellationError {
        } catch {
            guard context.matches(model: model, library: library) else {
                dismiss()
                return
            }
            loadError = error.localizedDescription
            isLoading = false
        }
    }

    private func save() {
        guard canSave else { return }
        isSaving = true
        saveError = nil
        saveTask = Task { @MainActor in
            defer {
                isSaving = false
                saveTask = nil
            }
            do {
                guard context.matches(model: model, library: library) else {
                    throw CancellationError()
                }
                if !writeCompleted {
                    try await library.updatePlaylistSongOrder(
                        playlistID,
                        trackIDs: draft,
                        expectedCredentialRevision: context.credentialRevision
                    )
                    try Task.checkCancellation()
                    guard context.matches(model: model, library: library) else {
                        throw CancellationError()
                    }
                    writeCompleted = true
                }
                _ = try await model.reloadPlaylist(playlistID)
                try Task.checkCancellation()
                guard context.matches(model: model, library: library) else {
                    throw CancellationError()
                }
                model.showToast("歌曲顺序已保存")
                dismiss()
            } catch is CancellationError {
                if !context.matches(model: model, library: library) { dismiss() }
            } catch {
                guard context.matches(model: model, library: library) else {
                    dismiss()
                    return
                }
                saveError = writeCompleted
                    ? "顺序已保存，但重新读取失败：\(error.localizedDescription)"
                    : error.localizedDescription
            }
        }
    }
}

private struct IOSPlaylistCoverUpdateSheet: View {
    let playlistName: String
    let item: IOSPreparedPlaylistCover
    let save: @MainActor () async throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var saveTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let image = UIImage(data: item.cover.jpegData) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: 280)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay {
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(.primary.opacity(0.08), lineWidth: 0.5)
                            }
                            .frame(maxWidth: .infinity)
                            .accessibilityLabel("\(playlistName)的新封面预览")
                    } else {
                        ContentUnavailableView("无法预览封面", systemImage: "photo")
                            .frame(maxWidth: .infinity, minHeight: 240)
                    }
                    LabeledContent(
                        "图片尺寸",
                        value: "\(item.cover.width) × \(item.cover.height)"
                    )
                    if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(16)
            }
            .navigationTitle("更新歌单封面")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                        .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(action: submit) {
                        if isSaving {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("更新")
                        }
                    }
                    .disabled(isSaving)
                    .accessibilityLabel(isSaving ? "正在更新歌单封面" : "更新歌单封面")
                }
            }
        }
        .presentationDetents([.large])
        .interactiveDismissDisabled(isSaving)
        .onDisappear { saveTask?.cancel() }
    }

    private func submit() {
        guard !isSaving else { return }
        isSaving = true
        errorMessage = nil
        saveTask = Task { @MainActor in
            defer {
                isSaving = false
                saveTask = nil
            }
            do {
                try await save()
                try Task.checkCancellation()
                dismiss()
            } catch is CancellationError {
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
