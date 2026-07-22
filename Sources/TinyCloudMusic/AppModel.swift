import Foundation
import Observation

enum SidebarItem: Hashable {
    case home, search, personalFM, library, history, downloads, session
}

enum HomeSectionLoad: Equatable {
    case idle
    case loading
    case loaded(HomeSection)
    case failed(String)
}

struct HomeSlot: Identifiable, Equatable {
    let id: String
    let title: String
    var load: HomeSectionLoad
}

enum SearchLoad: Equatable {
    case idle
    case loading
    case loaded(SearchPage)
    case failed(String)
}

private extension SearchLoad {
    var page: SearchPage? {
        guard case let .loaded(page) = self else { return nil }
        return page
    }
}

enum DetailLoad: Equatable {
    case idle
    case loading
    case loaded(DetailContent)
    case failed(String)
}

private struct HomeTaskEntry {
    let id: UUID
    let task: Task<Void, Never>
}

private struct DetailCacheEntry {
    let content: DetailContent
    let loadedAt: Date
    var lastAccess: Date
}

private struct SearchHintCacheEntry {
    let values: [String]
    let expiresAt: Date
    var lastAccess: Date
}

@MainActor
@Observable
final class AppModel {
    var sidebar: SidebarItem = .home
    var path: [Route] = [] {
        didSet { discardInactiveDetails() }
    }
    var homeSlots: [HomeSlot] = []
    var searchState = SearchState()
    var searchLoad: SearchLoad = .idle
    var isSearchLoadingMore = false
    var searchLoadMoreError: String?
    var searchHints: [String] = []
    var hotSearchItems: [HotSearchItem] = []
    var isHotSearchLoading = false
    var searchDirectMatches: [SearchDirectMatch] = []
    private(set) var detailLoads: [Route: DetailLoad] = [:]
    private(set) var loadingPlaylistIDs: Set<Int64> = []
    private(set) var playlistLoadMoreErrors: [Int64: String] = [:]
    private(set) var playlistContentRevision = 0
    var settings: AppSettings
    var settingsMessage: String?
    var libraryMessage: String?
    var interactionMessage: String?
    var likedSongIDs: Set<Int64> = []
    var playlistSubscriptionOverrides: [Int64: Bool] = [:]
    var albumSubscriptionOverrides: [Int64: Bool] = [:]
    var artistFollowOverrides: [Int64: Bool] = [:]
    var userFollowOverrides: [Int64: Bool] = [:]
    var currentUserID: Int64?
    var playlistPickerSong: Song?
    var librarySnapshot: LibrarySnapshot?
    var personalFM: PersonalFMController?

    let repository: any MusicRepository
    let library: LiveMusicLibrary?
    let extras: LiveMusicExtras?
    let downloads: MusicDownloadManager?
    let session: SessionController?
    let homeDescriptors: [HomeSectionDescriptor]

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var homeGeneration = 0
    @ObservationIgnored private var searchGeneration = 0
    @ObservationIgnored private var searchHintGeneration = 0
    @ObservationIgnored private var hotSearchGeneration = 0
    @ObservationIgnored private var accountRefreshGeneration = 0
    @ObservationIgnored private var detailGenerations: [Route: Int] = [:]
    @ObservationIgnored private var homeCache: [String: HomeSection] = [:]
    @ObservationIgnored private var homeTasks: [String: HomeTaskEntry] = [:]
    @ObservationIgnored private var detailCache: [Route: DetailCacheEntry] = [:]
    @ObservationIgnored private var staleDetailRoutes: Set<Route> = []
    @ObservationIgnored private var cachedPlaylistRevision = -1
    @ObservationIgnored private var cachedPlaylistsLoadedAt: Date?
    @ObservationIgnored private var searchHintCache: [String: SearchHintCacheEntry] = [:]
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var searchHintTask: Task<Void, Never>?
    @ObservationIgnored private var hotSearchTask: Task<Void, Never>?
    @ObservationIgnored private var searchDirectMatchTask: Task<Void, Never>?
    @ObservationIgnored private var detailTasks: [Route: Task<Void, Never>] = [:]
    @ObservationIgnored private var playlistLoadMoreTasks: [Int64: Task<Void, Never>] = [:]
    @ObservationIgnored private var interactionMessageTask: Task<Void, Never>?

    init(
        repository: any MusicRepository,
        library: LiveMusicLibrary? = nil,
        extras: LiveMusicExtras? = nil,
        downloads: MusicDownloadManager? = nil,
        session: SessionController? = nil,
        defaults: UserDefaults = .standard
    ) {
        self.repository = repository
        self.library = library
        self.extras = extras
        self.downloads = downloads
        self.session = session
        self.defaults = defaults
        homeDescriptors = repository.homeDescriptors

        let validSectionIDs = Set(homeDescriptors.map(\.id))
        let storedSections = (defaults.array(forKey: "homeSectionIDs") as? [String])?.filter(validSectionIDs.contains) ?? []
        let qtDefaultSection = "PAGE_RECOMMEND_SPECIAL_CLOUD_VILLAGE_PLAYLIST"
        let defaultSections = validSectionIDs.contains(qtDefaultSection)
            ? [qtDefaultSection]
            : homeDescriptors.first.map { [$0.id] } ?? []
        let storedCrossfadeDuration = defaults.object(forKey: "crossfadeDuration") == nil
            ? 3
            : defaults.double(forKey: "crossfadeDuration")
        let storedDownloadConcurrency = defaults.object(forKey: "downloadConcurrency") == nil
            ? 3
            : defaults.integer(forKey: "downloadConcurrency")
        settings = AppSettings(
            appearance: Appearance(rawValue: defaults.string(forKey: "appearance") ?? "") ?? .system,
            quality: AudioQuality(rawValue: defaults.string(forKey: "quality") ?? "") ?? .standard,
            downloadConcurrency: min(max(storedDownloadConcurrency, 1), 5),
            playbackQuality: AudioQuality(rawValue: defaults.string(forKey: "playbackQuality") ?? "") ?? .standard,
            crossfadeDuration: min(max(storedCrossfadeDuration, 0), 12),
            homeSectionIDs: storedSections.isEmpty ? defaultSections : storedSections,
            downloadBookmark: defaults.data(forKey: "downloadBookmark"),
            imageBookmark: defaults.data(forKey: "imageBookmark"),
            cacheBookmark: defaults.data(forKey: "cacheBookmark")
        )
        downloads?.setMaximumConcurrentDownloads(settings.downloadConcurrency)
        rebuildHomeSlots()
    }

    func selectSidebar(_ item: SidebarItem) {
        guard sidebar != item || !path.isEmpty else { return }
        sidebar = item
        path.removeAll()
    }

    func open(_ route: Route) {
        guard path.last != route else { return }
        path.append(route)
    }

    func loadHome() {
        homeGeneration += 1
        let generation = homeGeneration
        homeTasks.values.forEach { $0.task.cancel() }
        homeTasks.removeAll()
        rebuildHomeSlots(load: .loading)
        ArtworkPipeline.shared.retryFailedImages()

        for slot in homeSlots {
            startHomeTask(id: slot.id, generation: generation)
        }
    }

    func retryHomeSection(id: String) {
        guard homeSlots.contains(where: { $0.id == id }) else { return }
        let generation = homeGeneration
        homeTasks[id]?.task.cancel()
        updateHomeSlot(id: id, load: .loading)
        ArtworkPipeline.shared.retryFailedImages()
        startHomeTask(id: id, generation: generation)
    }

    func updateSearchQuery(_ query: String) {
        guard path.isEmpty || !query.isEmpty else { return }
        guard searchState.query != query else { return }
        searchState.query = query
        searchState.offset = 0
        searchGeneration += 1
        searchTask?.cancel()
        searchLoad = .idle
        isSearchLoadingMore = false
        searchLoadMoreError = nil
        loadSearchHints()
    }

    func setSearchScope(_ scope: SearchScope) {
        guard searchState.scope != scope else { return }
        searchState.scope = scope
        searchState.offset = 0
        search()
    }

    func loadSearchHints() {
        guard let extras else { return }
        searchHintGeneration += 1
        let generation = searchHintGeneration
        let query = searchState.query.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = query.precomposedStringWithCompatibilityMapping.lowercased()
        let staleHints = searchHintCache[key]?.values
        searchHintTask?.cancel()
        searchDirectMatchTask?.cancel()
        if query.isEmpty {
            searchDirectMatches = []
            loadHotSearch(using: extras)
        } else {
            cancelHotSearchLoad()
            searchDirectMatches = []
            if query.count >= 2 {
                loadSearchDirectMatches(for: query, generation: generation, using: extras)
            }
        }
        if var cached = searchHintCache[key], cached.expiresAt > Date() {
            cached.lastAccess = Date()
            searchHintCache[key] = cached
            if searchHints != cached.values { searchHints = cached.values }
            return
        }
        searchHintTask = Task { @MainActor [weak self, extras] in
            do {
                let hints: [String]
                if query.isEmpty {
                    hints = try await extras.defaultSearchKeywords().map(\.query)
                } else {
                    try await Task.sleep(for: .milliseconds(250))
                    hints = try await extras.searchSuggestions(for: query).map(\.keyword)
                }
                try Task.checkCancellation()
                guard let self, self.searchHintGeneration == generation else { return }
                self.storeSearchHints(hints, for: key)
                if self.searchHints != hints { self.searchHints = hints }
            } catch is CancellationError {
            } catch {
                guard let self, self.searchHintGeneration == generation else { return }
                let fallback = staleHints ?? []
                if self.searchHints != fallback { self.searchHints = fallback }
            }
        }
    }

    private func loadHotSearch(using extras: LiveMusicExtras) {
        guard hotSearchItems.isEmpty, !isHotSearchLoading else { return }
        hotSearchGeneration &+= 1
        let generation = hotSearchGeneration
        isHotSearchLoading = true
        hotSearchTask = Task { @MainActor [weak self, extras] in
            do {
                let items = try await extras.hotSearch()
                try Task.checkCancellation()
                guard let self, self.hotSearchGeneration == generation else { return }
                self.hotSearchItems = items
                self.isHotSearchLoading = false
                self.hotSearchTask = nil
            } catch is CancellationError {
            } catch {
                guard let self, self.hotSearchGeneration == generation else { return }
                self.isHotSearchLoading = false
                self.hotSearchTask = nil
            }
        }
    }

    private func cancelHotSearchLoad() {
        guard hotSearchTask != nil || isHotSearchLoading else { return }
        hotSearchGeneration &+= 1
        hotSearchTask?.cancel()
        hotSearchTask = nil
        isHotSearchLoading = false
    }

    private func loadSearchDirectMatches(
        for query: String,
        generation: Int,
        using extras: LiveMusicExtras
    ) {
        searchDirectMatchTask = Task { @MainActor [weak self, extras] in
            do {
                try await Task.sleep(for: .milliseconds(250))
                let matches = try await extras.searchDirectMatches(for: query)
                try Task.checkCancellation()
                guard let self, self.searchHintGeneration == generation else { return }
                self.searchDirectMatches = matches
                self.searchDirectMatchTask = nil
            } catch is CancellationError {
            } catch {
                guard let self, self.searchHintGeneration == generation else { return }
                self.searchDirectMatches = []
                self.searchDirectMatchTask = nil
            }
        }
    }

    func selectSearchHint(_ value: String) {
        updateSearchQuery(value)
        search(offset: 0)
    }

    func refreshAccountState() async {
        guard let library, let extras else { return }
        accountRefreshGeneration += 1
        let generation = accountRefreshGeneration
        if let session, session.state != .authenticated {
            if currentUserID != nil {
                await library.invalidateAllCachedResponses()
                guard accountRefreshGeneration == generation else { return }
                resetAccountScopedState(userID: nil)
            }
            return
        }
        do {
            let login = try await library.loginState()
            try Task.checkCancellation()
            guard accountRefreshGeneration == generation else { return }
            guard case let .loggedIn(user) = login else {
                if currentUserID != nil {
                    await library.invalidateAllCachedResponses()
                    guard accountRefreshGeneration == generation else { return }
                    resetAccountScopedState(userID: nil)
                } else {
                    likedSongIDs = []
                }
                return
            }
            if currentUserID != user.id {
                await library.invalidateAllCachedResponses()
                guard accountRefreshGeneration == generation else { return }
                resetAccountScopedState(userID: user.id)
            }
            let favorites = try await extras.favoriteSongIDs(userID: user.id)
            try Task.checkCancellation()
            guard accountRefreshGeneration == generation, currentUserID == user.id else { return }
            likedSongIDs = Set(favorites)
            libraryMessage = nil
        } catch is CancellationError {
        } catch {
            guard accountRefreshGeneration == generation else { return }
            libraryMessage = error.localizedDescription
        }
    }

    func showAddToPlaylist(for song: Song) {
        playlistPickerSong = song
    }

    func search(offset: Int? = nil) {
        let query = searchState.query.precomposedStringWithCompatibilityMapping
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            searchLoad = .idle
            isSearchLoadingMore = false
            searchLoadMoreError = nil
            return
        }

        if let offset { searchState.offset = max(0, offset) }
        searchGeneration += 1
        let generation = searchGeneration
        let scope = searchState.scope
        let requestOffset = searchState.offset
        let previousPage = requestOffset > 0 ? searchLoad.page : nil
        searchTask?.cancel()
        searchLoadMoreError = nil
        isSearchLoadingMore = previousPage != nil
        if previousPage == nil { searchLoad = .loading }

        searchTask = Task { @MainActor [weak self, repository] in
            do {
                let page = try await repository.search(query: query, scope: scope, offset: requestOffset, limit: 20)
                try Task.checkCancellation()
                guard let self, self.searchGeneration == generation,
                      self.searchState.scope == scope,
                      self.searchState.offset == requestOffset
                else { return }
                self.searchLoad = .loaded(previousPage?.appending(page) ?? page)
                self.isSearchLoadingMore = false
            } catch is CancellationError {
            } catch {
                guard let self, self.searchGeneration == generation else { return }
                if previousPage != nil {
                    self.searchLoadMoreError = error.localizedDescription
                    self.isSearchLoadingMore = false
                } else {
                    self.searchLoad = .failed(error.localizedDescription)
                }
            }
        }
    }

    func loadMoreSearchResults() {
        guard case let .loaded(page) = searchLoad,
              page.hasMore,
              !isSearchLoadingMore
        else { return }
        search(offset: page.offset + 20)
    }

    func loadDetail(_ route: Route, reload: Bool = false) {
        guard path.contains(route) else { return }
        let needsRefresh = reload || staleDetailRoutes.contains(route)
        if !needsRefresh, case .loaded? = detailLoads[route] { return }

        if needsRefresh, case let .playlist(id) = route {
            playlistLoadMoreTasks[id]?.cancel()
            playlistLoadMoreTasks[id] = nil
            loadingPlaylistIDs.remove(id)
            playlistLoadMoreErrors[id] = nil
        }

        let now = Date()
        let cached = detailCache[route]
        if !needsRefresh, var cached, now.timeIntervalSince(cached.loadedAt) < 5 * 60 {
            cached.lastAccess = now
            detailCache[route] = cached
            detailLoads[route] = .loaded(cached.content)
            return
        }

        let generation = (detailGenerations[route] ?? 0) + 1
        detailGenerations[route] = generation
        detailTasks[route]?.cancel()
        detailLoads[route] = cached.map { .loaded($0.content) } ?? .loading
        detailTasks[route] = Task { @MainActor [weak self, repository] in
            do {
                let detail = try await repository.detail(for: route)
                try Task.checkCancellation()
                guard let self,
                      self.detailGenerations[route] == generation,
                      self.path.contains(route)
                else { return }
                self.storeDetail(detail, for: route)
                self.staleDetailRoutes.remove(route)
                self.detailLoads[route] = .loaded(detail)
                self.detailTasks[route] = nil
            } catch is CancellationError {
                guard let self,
                      !Task.isCancelled,
                      self.detailGenerations[route] == generation,
                      self.path.contains(route)
                else { return }
                self.detailTasks[route] = nil
                self.loadDetail(route, reload: true)
            } catch {
                guard let self,
                      !Task.isCancelled,
                      self.detailGenerations[route] == generation,
                      self.path.contains(route)
                else { return }
                self.detailLoads[route] = cached.map { .loaded($0.content) }
                    ?? .failed(error.localizedDescription)
                self.detailTasks[route] = nil
            }
        }
    }

    func reloadPlaylist(_ playlistID: Int64) async throws -> Playlist {
        let route = Route.playlist(playlistID)
        let generation = (detailGenerations[route] ?? 0) + 1
        detailGenerations[route] = generation
        detailTasks[route]?.cancel()
        detailTasks[route] = nil
        await library?.invalidateCachedResponses(in: [.detail, .library])

        let detail = try await repository.detail(for: route)
        try Task.checkCancellation()
        guard detailGenerations[route] == generation,
              case let .playlist(playlist, _, _, _) = detail
        else { throw CancellationError() }

        storeDetail(detail, for: route)
        staleDetailRoutes.remove(route)
        if path.contains(route) { detailLoads[route] = .loaded(detail) }
        if let index = librarySnapshot?.playlists.firstIndex(where: { $0.id == playlistID }) {
            librarySnapshot?.playlists[index] = playlist
        }
        return playlist
    }

    func playlistContentsDidChange(_ playlistID: Int64? = nil) {
        playlistSummariesDidChange()
        let knownID = playlistID ?? cachedFavoritePlaylistID
        let routes = if let knownID {
            Set([Route.playlist(knownID)])
        } else {
            Set(detailCache.keys)
                .union(detailLoads.keys)
                .union(path)
                .filter { if case .playlist = $0 { true } else { false } }
        }

        for route in routes where detailCache[route] != nil || detailLoads[route] != nil || path.contains(route) {
            staleDetailRoutes.insert(route)
            if path.contains(route) { loadDetail(route, reload: true) }
        }
    }

    func playlistSummariesDidChange() {
        playlistContentRevision &+= 1
    }

    func cachedPlaylistsAreFresh(at now: Date = Date()) -> Bool {
        librarySnapshot != nil
            && cachedPlaylistRevision == playlistContentRevision
            && cachedPlaylistsLoadedAt.map { now.timeIntervalSince($0) < 90 } == true
    }

    func storeLibrarySnapshot(
        _ snapshot: LibrarySnapshot,
        playlistRevision: Int,
        loadedAt: Date = Date()
    ) {
        librarySnapshot = snapshot
        cachedPlaylistRevision = playlistRevision
        cachedPlaylistsLoadedAt = loadedAt
    }

    @discardableResult
    func storeCachedPlaylists(
        _ playlists: [Playlist],
        playlistRevision: Int,
        loadedAt: Date = Date()
    ) -> Bool {
        guard playlistRevision == playlistContentRevision, var snapshot = librarySnapshot else { return false }
        cachedPlaylistRevision = playlistRevision
        cachedPlaylistsLoadedAt = loadedAt
        guard snapshot.playlists != playlists else { return true }
        snapshot.playlists = playlists
        librarySnapshot = snapshot
        return true
    }

    func loadMorePlaylistSongs(_ playlistID: Int64) {
        let route = Route.playlist(playlistID)
        guard path.contains(route), playlistLoadMoreTasks[playlistID] == nil,
              case let .loaded(content)? = detailLoads[route],
              case let .playlist(_, _, trackIDs, loadedTrackCount) = content,
              let range = PlaylistSongPaging.nextRange(total: trackIDs.count, loaded: loadedTrackCount)
        else { return }

        loadingPlaylistIDs.insert(playlistID)
        playlistLoadMoreErrors[playlistID] = nil
        playlistLoadMoreTasks[playlistID] = Task { @MainActor [weak self, repository] in
            do {
                let page = try await repository.songs(ids: Array(trackIDs[range]))
                try Task.checkCancellation()
                guard let self, self.path.contains(route),
                      case let .loaded(current)? = self.detailLoads[route],
                      case let .playlist(currentPlaylist, currentSongs, currentTrackIDs, currentLoadedCount) = current,
                      currentTrackIDs == trackIDs,
                      currentLoadedCount == loadedTrackCount
                else { return }

                let existingIDs = Set(currentSongs.map(\.id))
                let updated = DetailContent.playlist(
                    currentPlaylist,
                    songs: currentSongs + page.filter { !existingIDs.contains($0.id) },
                    trackIDs: currentTrackIDs,
                    loadedTrackCount: range.upperBound
                )
                self.detailLoads[route] = .loaded(updated)
                self.storeDetail(updated, for: route)
                self.loadingPlaylistIDs.remove(playlistID)
                self.playlistLoadMoreTasks[playlistID] = nil
            } catch is CancellationError {
            } catch {
                guard let self, self.path.contains(route) else { return }
                self.playlistLoadMoreErrors[playlistID] = error.localizedDescription
                self.loadingPlaylistIDs.remove(playlistID)
                self.playlistLoadMoreTasks[playlistID] = nil
            }
        }
    }

    private func discardInactiveDetails() {
        let activeRoutes = Set(path)
        detailTasks
            .filter { !activeRoutes.contains($0.key) }
            .values
            .forEach { $0.cancel() }
        detailTasks = detailTasks.filter { activeRoutes.contains($0.key) }
        detailGenerations = detailGenerations.filter { activeRoutes.contains($0.key) }
        detailLoads = detailLoads.filter { activeRoutes.contains($0.key) }

        let activePlaylistIDs = Set(activeRoutes.compactMap { route -> Int64? in
            guard case let .playlist(id) = route else { return nil }
            return id
        })
        playlistLoadMoreTasks
            .filter { !activePlaylistIDs.contains($0.key) }
            .values
            .forEach { $0.cancel() }
        playlistLoadMoreTasks = playlistLoadMoreTasks.filter { activePlaylistIDs.contains($0.key) }
        loadingPlaylistIDs.formIntersection(activePlaylistIDs)
        playlistLoadMoreErrors = playlistLoadMoreErrors.filter { activePlaylistIDs.contains($0.key) }
    }

    func setAppearance(_ appearance: Appearance) {
        settings.appearance = appearance
        defaults.set(appearance.rawValue, forKey: "appearance")
        showToast("外观设置已保存")
    }

    func setQuality(_ quality: AudioQuality) {
        settings.quality = quality
        defaults.set(quality.rawValue, forKey: "quality")
        showToast("下载音质已保存")
    }

    func setDownloadConcurrency(_ count: Int) {
        let count = min(max(count, 1), 5)
        settings.downloadConcurrency = count
        defaults.set(count, forKey: "downloadConcurrency")
        downloads?.setMaximumConcurrentDownloads(count)
        showToast("下载并发数已保存")
    }

    func setPlaybackQuality(_ quality: AudioQuality) {
        settings.playbackQuality = quality
        defaults.set(quality.rawValue, forKey: "playbackQuality")
        showToast("播放音质已保存")
    }

    func setCrossfadeDuration(_ seconds: TimeInterval) {
        let seconds = min(max(seconds, 0), 12)
        settings.crossfadeDuration = seconds
        defaults.set(seconds, forKey: "crossfadeDuration")
        showToast(seconds == 0 ? "歌曲过渡已关闭" : "歌曲过渡已保存")
    }

    func setHomeSection(_ id: String, enabled: Bool) {
        var ids = settings.homeSectionIDs
        if enabled {
            guard !ids.contains(id) else { return }
            ids.append(id)
            ids.sort { descriptorIndex($0) < descriptorIndex($1) }
        } else {
            guard ids.count > 1 else {
                settingsMessage = "首页至少保留一个栏目"
                return
            }
            ids.removeAll { $0 == id }
        }
        settings.homeSectionIDs = ids
        defaults.set(ids, forKey: "homeSectionIDs")
        showToast("首页栏目已更新")
        loadHome()
    }

    func setDownloadFolder(_ url: URL) {
        do {
            let bookmark = try folderBookmark(for: url)
            settings.downloadBookmark = bookmark
            defaults.set(bookmark, forKey: "downloadBookmark")
            settingsMessage = nil
            showToast("下载位置已保存")
        } catch {
            settingsMessage = "无法保存下载目录权限"
        }
    }

    func setCacheFolder(_ url: URL) {
        do {
            let bookmark = try folderBookmark(for: url)
            settings.cacheBookmark = bookmark
            defaults.set(bookmark, forKey: "cacheBookmark")
            settingsMessage = nil
            showToast("缓存位置已保存")
        } catch {
            settingsMessage = "无法保存缓存目录权限"
        }
    }

    func setImageFolder(_ url: URL) {
        do {
            let bookmark = try folderBookmark(for: url)
            settings.imageBookmark = bookmark
            defaults.set(bookmark, forKey: "imageBookmark")
            settingsMessage = nil
            showToast("图片保存位置已保存")
        } catch {
            settingsMessage = "无法保存图片目录权限"
        }
    }

    func download(_ song: Song) {
        guard let downloads else { return }
        downloads.enqueue(
            song: song,
            to: downloadFolderURL,
            quality: settings.quality,
            includeLyrics: true
        )
    }

    func downloadPlaylist(
        loadedSongs: [Song],
        trackIDs: [Int64],
        quality: AudioQuality
    ) async throws -> Int {
        guard let downloads else { return 0 }
        var songsByID = Dictionary(loadedSongs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let missingIDs = trackIDs.filter { songsByID[$0] == nil }
        for song in try await repository.songs(ids: missingIDs) { songsByID[song.id] = song }

        return trackIDs.compactMap { songsByID[$0] }.reduce(into: 0) { count, song in
            if downloads.enqueue(
                song: song,
                to: downloadFolderURL,
                quality: quality,
                includeLyrics: true
            ) {
                count += 1
            }
        }
    }

    func download(_ song: CloudSong) {
        guard let downloads, let userID = currentUserID else { return }
        downloads.enqueue(
            cloudSong: song,
            userID: userID,
            to: downloadFolderURL,
            includeLyrics: true
        )
    }

    func saveArtwork(from sourceURL: URL, title: String) {
        let destinationFolder = imageFolderURL
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let data = try await ArtworkPipeline.shared.loadData(for: sourceURL)
                let hasSecurityScope = destinationFolder.startAccessingSecurityScopedResource()
                defer { if hasSecurityScope { destinationFolder.stopAccessingSecurityScopedResource() } }
                try FileManager.default.createDirectory(at: destinationFolder, withIntermediateDirectories: true)

                let cleanedTitle = MusicDownloadFiles.sanitizedFileName(title)
                let fileName = cleanedTitle.isEmpty ? "封面" : cleanedTitle
                let fileExtension = sourceURL.pathExtension.lowercased() == "png" ? "png" : "jpg"
                let destination = destinationFolder.appending(path: fileName).appendingPathExtension(fileExtension)
                try data.write(to: destination, options: .atomic)
                showToast("图片保存成功")
            } catch {
                libraryMessage = "图片保存失败：\(error.localizedDescription)"
            }
        }
    }

    func showToast(_ message: String) {
        interactionMessageTask?.cancel()
        interactionMessage = message
        interactionMessageTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(2))
                self?.interactionMessage = nil
            } catch {
            }
        }
    }

    func toggleSongLiked(_ songID: Int64) {
        guard let library else { return }
        let liked = !likedSongIDs.contains(songID)
        Task { @MainActor [weak self] in
            do {
                try await library.setSongLiked(songID, liked: liked)
                guard let self else { return }
                if liked { self.likedSongIDs.insert(songID) } else { self.likedSongIDs.remove(songID) }
                self.playlistContentsDidChange()
                self.showToast(liked ? "已喜欢歌曲" : "已取消喜欢")
            } catch {
                self?.libraryMessage = error.localizedDescription
            }
        }
    }

    func favoriteSongs(_ songIDs: [Int64]) async throws -> Int {
        guard let library else { return 0 }
        var count = 0
        defer { if count > 0 { playlistContentsDidChange() } }
        for songID in songIDs where songID > 0 && !likedSongIDs.contains(songID) {
            try Task.checkCancellation()
            try await library.setSongLiked(songID, liked: true)
            likedSongIDs.insert(songID)
            count += 1
        }
        return count
    }

    func setPlaylistSubscribed(_ id: Int64, subscribed: Bool) {
        guard let library else { return }
        Task { @MainActor [weak self] in
            do {
                try await library.setPlaylistSubscribed(id, subscribed: subscribed)
                guard let self else { return }
                self.playlistSubscriptionOverrides[id] = subscribed
                self.playlistSummariesDidChange()
                self.showToast(subscribed ? "歌单已收藏" : "已取消收藏歌单")
            } catch {
                self?.libraryMessage = error.localizedDescription
            }
        }
    }

    func setAlbumSubscribed(_ id: Int64, subscribed: Bool) {
        guard let library else { return }
        Task { @MainActor [weak self] in
            do {
                try await library.setAlbumSubscribed(id, subscribed: subscribed)
                guard let self else { return }
                self.albumSubscriptionOverrides[id] = subscribed
                self.showToast(subscribed ? "专辑已收藏" : "已取消收藏专辑")
            } catch {
                self?.libraryMessage = error.localizedDescription
            }
        }
    }

    func setArtistFollowed(_ id: Int64, followed: Bool) {
        guard let library else { return }
        Task { @MainActor [weak self] in
            do {
                try await library.setArtistFollowed(id, followed: followed)
                guard let self else { return }
                self.artistFollowOverrides[id] = followed
                self.showToast(followed ? "已关注歌手" : "已取消关注歌手")
            } catch {
                self?.libraryMessage = error.localizedDescription
            }
        }
    }

    func setUserFollowed(_ id: Int64, followed: Bool) {
        guard let library else { return }
        Task { @MainActor [weak self] in
            do {
                try await library.setUserFollowed(id, followed: followed)
                guard let self else { return }
                self.userFollowOverrides[id] = followed
                self.showToast(followed ? "已关注用户" : "已取消关注用户")
            } catch {
                self?.libraryMessage = error.localizedDescription
            }
        }
    }

    var downloadPath: String {
        downloadFolderURL.path(percentEncoded: false)
    }

    var imagePath: String {
        imageFolderURL.path(percentEncoded: false)
    }

    var cachePath: String {
        cacheFolderURL.path(percentEncoded: false)
    }

    var cacheFolderURL: URL {
        resolveFolder(settings.cacheBookmark) ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: "TinyCloudMusic", directoryHint: .isDirectory)
    }

    private func startHomeTask(id: String, generation: Int) {
        let taskID = UUID()
        let task = Task { @MainActor [weak self, repository] in
            defer { self?.finishHomeTask(id: id, taskID: taskID) }
            do {
                let section = try await repository.homeSection(id: id)
                try Task.checkCancellation()
                guard let self,
                      self.homeGeneration == generation,
                      self.homeSlots.contains(where: { $0.id == id })
                else { return }
                self.homeCache[id] = section
                self.updateHomeSlot(id: id, load: .loaded(section))
            } catch is CancellationError {
            } catch {
                guard let self, self.homeGeneration == generation else { return }
                self.updateHomeSlot(
                    id: id,
                    load: self.homeCache[id].map(HomeSectionLoad.loaded)
                        ?? .failed(error.localizedDescription)
                )
            }
        }
        homeTasks[id] = HomeTaskEntry(id: taskID, task: task)
    }

    private func finishHomeTask(id: String, taskID: UUID) {
        guard homeTasks[id]?.id == taskID else { return }
        homeTasks[id] = nil
    }

    private func storeSearchHints(_ values: [String], for key: String) {
        let now = Date()
        searchHintCache[key] = SearchHintCacheEntry(
            values: values,
            expiresAt: now.addingTimeInterval(5 * 60),
            lastAccess: now
        )
        guard searchHintCache.count > 32,
              let oldest = searchHintCache.min(by: { $0.value.lastAccess < $1.value.lastAccess })?.key
        else { return }
        searchHintCache[oldest] = nil
    }

    private func storeDetail(_ content: DetailContent, for route: Route) {
        let now = Date()
        detailCache[route] = DetailCacheEntry(content: content, loadedAt: now, lastAccess: now)
        guard detailCache.count > 64,
              let oldest = detailCache.min(by: { $0.value.lastAccess < $1.value.lastAccess })?.key
        else { return }
        detailCache[oldest] = nil
    }

    private var cachedFavoritePlaylistID: Int64? {
        if let id = librarySnapshot?.playlists.first(where: { $0.specialType == 5 })?.id {
            return id
        }
        return detailCache.values.lazy.compactMap { entry -> Int64? in
            guard case let .playlist(playlist, _, _, _) = entry.content,
                  playlist.specialType == 5
            else { return nil }
            return playlist.id
        }.first
    }

    private func resetAccountScopedState(userID: Int64?) {
        downloads?.cancelCloudDownloads(exceptUserID: userID)
        homeGeneration &+= 1
        homeTasks.values.forEach { $0.task.cancel() }
        homeTasks.removeAll()
        homeCache.removeAll()
        rebuildHomeSlots()

        searchGeneration &+= 1
        searchTask?.cancel()
        searchTask = nil
        searchLoad = .idle
        isSearchLoadingMore = false
        searchLoadMoreError = nil
        searchHintGeneration &+= 1
        searchHintTask?.cancel()
        searchHintTask = nil
        searchDirectMatchTask?.cancel()
        searchDirectMatchTask = nil
        searchHints = []
        searchDirectMatches = []
        searchHintCache.removeAll()
        hotSearchGeneration &+= 1
        hotSearchTask?.cancel()
        hotSearchTask = nil
        hotSearchItems = []
        isHotSearchLoading = false

        detailTasks.values.forEach { $0.cancel() }
        detailTasks.removeAll()
        playlistLoadMoreTasks.values.forEach { $0.cancel() }
        playlistLoadMoreTasks.removeAll()
        loadingPlaylistIDs.removeAll()
        playlistLoadMoreErrors.removeAll()
        detailGenerations.removeAll()
        detailLoads.removeAll()
        detailCache.removeAll()
        staleDetailRoutes.removeAll()
        path.removeAll()

        likedSongIDs = []
        playlistSubscriptionOverrides.removeAll()
        albumSubscriptionOverrides.removeAll()
        artistFollowOverrides.removeAll()
        userFollowOverrides.removeAll()
        librarySnapshot = nil
        playlistContentRevision = 0
        cachedPlaylistRevision = -1
        cachedPlaylistsLoadedAt = nil
        playlistPickerSong = nil
        currentUserID = userID
    }

    private func rebuildHomeSlots(load: HomeSectionLoad = .idle) {
        let titles = Dictionary(uniqueKeysWithValues: homeDescriptors.map { ($0.id, $0.title) })
        homeSlots = settings.homeSectionIDs.map {
            HomeSlot(id: $0, title: titles[$0] ?? $0, load: homeCache[$0].map(HomeSectionLoad.loaded) ?? load)
        }
    }

    private func updateHomeSlot(id: String, load: HomeSectionLoad) {
        guard let index = homeSlots.firstIndex(where: { $0.id == id }) else { return }
        homeSlots[index].load = load
    }

    private func descriptorIndex(_ id: String) -> Int {
        homeDescriptors.firstIndex(where: { $0.id == id }) ?? .max
    }

    var downloadFolderURL: URL {
        resolveFolder(settings.downloadBookmark) ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
            .appending(path: "TinyCloudMusic", directoryHint: .isDirectory)
    }

    var imageFolderURL: URL {
        resolveFolder(settings.preferredImageBookmark) ?? downloadFolderURL
    }

    private func folderBookmark(for url: URL) throws -> Data {
        try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    private func resolveFolder(_ bookmark: Data?) -> URL? {
        guard let bookmark else { return nil }
        var stale = false
        return try? URL(
            resolvingBookmarkData: bookmark,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        )
    }
}
