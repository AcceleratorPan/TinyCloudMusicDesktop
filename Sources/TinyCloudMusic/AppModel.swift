import Foundation
import Observation

enum SidebarItem: Hashable {
    case home, search, videos, audio, personalFM, library, history, downloads, session
}

enum LibraryMutationKey: Hashable, Sendable {
    case songLike(Int64)
    case playlistSubscription(Int64)
    case albumSubscription(Int64)
    case artistFollow(Int64)
    case userFollow(Int64)
    case playlistSong(playlistID: Int64, songID: Int64)
}

struct FavoriteSongsFailure: LocalizedError, Sendable {
    let successfulIDs: [Int64]
    let failedID: Int64
    let unattemptedIDs: [Int64]
    let causeDescription: String

    var errorDescription: String? {
        "已收藏 \(successfulIDs.count) 首；歌曲 \(failedID) 收藏失败，"
            + "另有 \(unattemptedIDs.count) 首未尝试：\(causeDescription)"
    }
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

private struct MutationTaskEntry {
    let id: UUID
    let task: Task<Void, Never>
}

private struct ResolvedFolders: Sendable {
    let download: URL?
    let video: URL?
    let image: URL?
    let sheet: URL?
    let cache: URL?
}

private actor ArtworkFileWriter {
    func write(_ data: Data, to destination: URL, folder: URL) throws {
        let hasSecurityScope = folder.startAccessingSecurityScopedResource()
        defer { if hasSecurityScope { folder.stopAccessingSecurityScopedResource() } }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try data.write(to: destination, options: .atomic)
    }
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
    var videoSubscriptionOverrides: [VideoPageResource: Bool] = [:]
    private(set) var videoSubscriptionRevision = 0
    private(set) var loadedVideoSubscriptionRevision = 0
    var albumSubscriptionOverrides: [Int64: Bool] = [:]
    var artistFollowOverrides: [Int64: Bool] = [:]
    var userFollowOverrides: [Int64: Bool] = [:]
    private(set) var pendingMutations: Set<LibraryMutationKey> = []
    private var podcastSubscriptionOverrides: [Int64: Bool] = [:]
    private(set) var podcastSubscriptionRevision: UInt64 = 0
    private(set) var cacheConfigurationRevision: UInt64 = 0
    var broadcastCollectionOverrides: [String: Bool] = [:]
    var currentUserID: Int64? {
        didSet {
            listenTogether?.updateAccount(currentUserID)
        }
    }
    var confirmedAccountCredentialRevision: UInt64? { accountCredentialRevision }
    var playlistPickerSong: Song?
    var isListenTogetherPresented = false
    var librarySnapshot: LibrarySnapshot?
    var personalFM: PersonalFMController?
    var listenTogether: ListenTogetherController? {
        didSet { listenTogether?.updateAccount(currentUserID) }
    }

    let repository: any MusicRepository
    let library: LiveMusicLibrary?
    let videoLibrary: LiveVideoLibrary?
    let audioLibrary: LiveAudioContentLibrary?
    let knowledgeLibrary: LiveMusicKnowledgeLibrary?
    let extras: LiveMusicExtras?
    let downloads: MusicDownloadManager?
    let uploads: AudioUploadManager?
    let session: SessionController?
    let homeDescriptors: [HomeSectionDescriptor]

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var homeGeneration = 0
    @ObservationIgnored private var searchGeneration = 0
    @ObservationIgnored private var searchHintGeneration = 0
    @ObservationIgnored private var hotSearchGeneration = 0
    @ObservationIgnored private var accountRefreshGeneration = 0
    @ObservationIgnored private var accountCredentialRevision: UInt64?
    @ObservationIgnored private var accountPlaylistsTask: (
        id: UUID,
        userID: Int64,
        credentialRevision: UInt64,
        task: Task<[Playlist], any Error>,
        loadedAt: Date?
    )?
    @ObservationIgnored private var accountPlaylistsProgress: (taskID: UUID, values: [Playlist])?
    @ObservationIgnored private var accountPlaylistObservers: [UUID: ([Playlist]) -> Void] = [:]
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
    @ObservationIgnored private var playlistLoadMoreTaskIDs: [Int64: UUID] = [:]
    @ObservationIgnored private var mutationTasks: [LibraryMutationKey: MutationTaskEntry] = [:]
    @ObservationIgnored private var favoriteTask: Task<Int, any Error>?
    @ObservationIgnored private var favoriteTaskID: UUID?
    @ObservationIgnored private var interactionMessageTask: Task<Void, Never>?
    @ObservationIgnored private let artworkFileWriter = ArtworkFileWriter()
    @ObservationIgnored private var savingArtworkDestinations: Set<URL> = []
    @ObservationIgnored private var resolvedDownloadFolder: URL?
    @ObservationIgnored private var resolvedVideoDownloadFolder: URL?
    @ObservationIgnored private var resolvedImageFolder: URL?
    @ObservationIgnored private var resolvedSheetFolder: URL?
    @ObservationIgnored private var resolvedCacheFolder: URL?
    @ObservationIgnored private var bookmarkResolveTask: Task<Void, Never>?
    @ObservationIgnored private var bookmarkGeneration = 0
    @ObservationIgnored private let downloadCacheConfigurator: @MainActor (URL) -> Void
    @ObservationIgnored private let bookmarkResolver: @Sendable (Data?) async -> URL?
    @ObservationIgnored private(set) var bookmarkResolutionCompletionCount: UInt64 = 0

    init(
        repository: any MusicRepository,
        library: LiveMusicLibrary? = nil,
        videoLibrary: LiveVideoLibrary? = nil,
        audioLibrary: LiveAudioContentLibrary? = nil,
        knowledgeLibrary: LiveMusicKnowledgeLibrary? = nil,
        extras: LiveMusicExtras? = nil,
        downloads: MusicDownloadManager? = nil,
        uploads: AudioUploadManager? = nil,
        session: SessionController? = nil,
        defaults: UserDefaults = .standard,
        downloadCacheConfigurator: (@MainActor (URL) -> Void)? = nil,
        bookmarkResolver: @escaping @Sendable (Data?) async -> URL? = {
            AppModel.resolveFolder($0)
        }
    ) {
        self.repository = repository
        self.library = library
        self.videoLibrary = videoLibrary
        self.audioLibrary = audioLibrary
        self.knowledgeLibrary = knowledgeLibrary
        self.extras = extras
        self.downloads = downloads
        self.uploads = uploads
        self.session = session
        self.defaults = defaults
        self.downloadCacheConfigurator = downloadCacheConfigurator ?? { [weak downloads] root in
            downloads?.configure(cacheRoot: root)
        }
        self.bookmarkResolver = bookmarkResolver
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
            videoPlaybackQuality: VideoQuality(
                rawValue: defaults.string(forKey: "videoPlaybackQuality") ?? ""
            ) ?? .high,
            videoDownloadQuality: VideoQuality(
                rawValue: defaults.string(forKey: "videoDownloadQuality") ?? ""
            ) ?? .high,
            crossfadeDuration: min(max(storedCrossfadeDuration, 0), 12),
            playbackControlFadeEnabled: defaults.bool(forKey: "playbackControlFadeEnabled"),
            homeSectionIDs: storedSections.isEmpty ? defaultSections : storedSections,
            downloadBookmark: defaults.data(forKey: "downloadBookmark"),
            videoDownloadBookmark: defaults.data(forKey: "videoDownloadBookmark"),
            imageBookmark: defaults.data(forKey: "imageBookmark"),
            sheetBookmark: defaults.data(forKey: "sheetBookmark"),
            cacheBookmark: defaults.data(forKey: "cacheBookmark")
        )
        downloads?.setMaximumConcurrentDownloads(settings.downloadConcurrency)
        self.downloadCacheConfigurator(cacheFolderURL.standardizedFileURL)
        rebuildHomeSlots()
        restoreBookmarkedFolders()
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

    func replaceCurrentRoute(with route: Route) {
        if path.isEmpty { path = [route] } else { path[path.count - 1] = route }
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
        searchTask = nil
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
        hotSearchGeneration += 1
        let generation = hotSearchGeneration
        isHotSearchLoading = true
        hotSearchTask = Task { @MainActor [weak self, extras] in
            defer {
                if let self, self.hotSearchGeneration == generation {
                    self.isHotSearchLoading = false
                    self.hotSearchTask = nil
                }
            }
            do {
                let items = try await extras.hotSearch()
                try Task.checkCancellation()
                guard let self, self.hotSearchGeneration == generation else { return }
                self.hotSearchItems = items
            } catch is CancellationError {
            } catch {
            }
        }
    }

    private func cancelHotSearchLoad() {
        guard hotSearchTask != nil || isHotSearchLoading else { return }
        hotSearchGeneration += 1
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
        guard let library else { return }
        defer {
            invalidateAccountDomainIfNeeded(
                forCredentialRevision: library.transport.credentialSnapshotValue().revision
            )
        }
        let credentialRevision = library.transport.credentialSnapshotValue().revision
        invalidateAccountDomainIfNeeded(forCredentialRevision: credentialRevision)
        guard let extras else { return }
        accountRefreshGeneration += 1
        var generation = accountRefreshGeneration
        if let session, session.state != .authenticated {
            if currentUserID != nil {
                await library.invalidateAllCachedResponses()
                guard accountRefreshGeneration == generation else { return }
                _ = resetAccountScopedState(userID: nil, credentialRevision: nil)
            }
            return
        }
        do {
            let login = try await library.loginState(
                expectedCredentialRevision: credentialRevision
            )
            try Task.checkCancellation()
            guard accountRefreshGeneration == generation,
                  library.transport.credentialSnapshotValue().revision == credentialRevision
            else { return }
            guard case let .loggedIn(user) = login else {
                if currentUserID != nil {
                    await library.invalidateAllCachedResponses()
                    guard accountRefreshGeneration == generation else { return }
                    _ = resetAccountScopedState(userID: nil, credentialRevision: nil)
                } else {
                    likedSongIDs = []
                }
                return
            }
            if currentUserID != user.id || accountCredentialRevision != credentialRevision {
                await library.invalidateAllCachedResponses()
                guard accountRefreshGeneration == generation,
                      library.transport.credentialSnapshotValue().revision == credentialRevision
                else { return }
                generation = installConfirmedAccount(
                    userID: user.id,
                    credentialRevision: credentialRevision
                )
            }
            let playlists = try await accountPlaylists(
                userID: user.id,
                credentialRevision: credentialRevision
            )
            try Task.checkCancellation()
            guard accountRefreshGeneration == generation,
                  currentUserID == user.id,
                  library.transport.credentialSnapshotValue().revision == credentialRevision
            else { return }
            let favorites = try await extras.favoriteSongIDs(
                userID: user.id,
                playlists: playlists,
                expectedCredentialRevision: credentialRevision
            )
            try Task.checkCancellation()
            guard accountRefreshGeneration == generation,
                  currentUserID == user.id,
                  library.transport.credentialSnapshotValue().revision == credentialRevision
            else { return }
            likedSongIDs = Set(favorites)
            if librarySnapshot?.user.id == user.id {
                _ = storeCachedPlaylists(playlists, playlistRevision: playlistContentRevision)
            }
            libraryMessage = nil
        } catch is CancellationError {
        } catch {
            guard accountRefreshGeneration == generation,
                  library.transport.credentialSnapshotValue().revision == credentialRevision
            else { return }
            libraryMessage = error.localizedDescription
        }
    }

    func showAddToPlaylist(for song: Song) {
        playlistPickerSong = song
    }

    func search(offset: Int? = nil) {
        let query = searchState.query.precomposedStringWithCompatibilityMapping
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            searchGeneration += 1
            searchTask?.cancel()
            searchTask = nil
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
            defer {
                if let self, self.searchGeneration == generation {
                    self.isSearchLoadingMore = false
                    self.searchTask = nil
                }
            }
            do {
                let page = try await repository.search(query: query, scope: scope, offset: requestOffset, limit: 20)
                try Task.checkCancellation()
                guard let self, self.searchGeneration == generation,
                      self.searchState.scope == scope,
                      self.searchState.offset == requestOffset
                else { return }
                self.searchLoad = .loaded(Self.mergedSearchPage(previousPage, page))
            } catch is CancellationError {
            } catch {
                guard let self, self.searchGeneration == generation else { return }
                if previousPage != nil {
                    self.searchLoadMoreError = error.localizedDescription
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

    static func mergedSearchPage(_ existing: SearchPage?, _ page: SearchPage) -> SearchPage {
        var seen = Set(existing?.items.map(\.id) ?? [])
        var pageSeen = Set<String>()
        let uniquePage = page.items.filter { pageSeen.insert($0.id).inserted }
        let additions = uniquePage.filter { seen.insert($0.id).inserted }
        let progressed = existing.map { page.offset > $0.offset && !additions.isEmpty } ?? !uniquePage.isEmpty
        return SearchPage(
            items: (existing?.items ?? []) + additions,
            offset: max(existing?.offset ?? page.offset, page.offset),
            hasMore: page.hasMore && progressed
        )
    }

    func loadDetail(_ route: Route, reload: Bool = false) {
        guard path.last == route else { return }
        let needsRefresh = reload || staleDetailRoutes.contains(route)
        if !needsRefresh, case .loaded? = detailLoads[route] { return }

        if needsRefresh, case let .playlist(id) = route {
            playlistLoadMoreTasks[id]?.cancel()
            playlistLoadMoreTasks[id] = nil
            playlistLoadMoreTaskIDs[id] = nil
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
        let isAccountScopedDetail = switch route {
        case .album, .playlist, .user: true
        default: false
        }
        let accountGeneration = isAccountScopedDetail ? accountRefreshGeneration : nil
        let accountID = currentUserID
        let credentialRevision = isAccountScopedDetail ? repository.currentCredentialRevision : nil
        detailGenerations[route] = generation
        detailTasks[route]?.cancel()
        detailLoads[route] = cached.map { .loaded($0.content) } ?? .loading
        detailTasks[route] = Task { @MainActor [weak self, repository, library] in
            do {
                if needsRefresh,
                   case let .playlist(id) = route,
                   let credentialRevision {
                    try await library?.refreshPlaylistDetail(
                        id,
                        expectedCredentialRevision: credentialRevision
                    )
                }
                let detail = try await repository.detail(
                    for: route,
                    expectedCredentialRevision: credentialRevision
                )
                try Task.checkCancellation()
                guard let self,
                      self.detailGenerations[route] == generation,
                      self.path.last == route,
                      (accountGeneration.map {
                          self.accountRefreshGeneration == $0
                              && self.currentUserID == accountID
                              && repository.currentCredentialRevision == credentialRevision
                      } ?? true)
                else { return }
                self.storeDetail(detail, for: route)
                self.staleDetailRoutes.remove(route)
                self.detailLoads[route] = .loaded(detail)
                self.detailTasks[route] = nil
            } catch is CancellationError {
                guard let self,
                      !Task.isCancelled,
                      self.detailGenerations[route] == generation,
                      self.path.last == route,
                      (accountGeneration.map {
                          self.accountRefreshGeneration == $0
                              && self.currentUserID == accountID
                              && repository.currentCredentialRevision == credentialRevision
                      } ?? true)
                else { return }
                self.detailTasks[route] = nil
                self.loadDetail(route, reload: true)
            } catch {
                guard let self,
                      !Task.isCancelled,
                      self.detailGenerations[route] == generation,
                      self.path.last == route,
                      (accountGeneration.map {
                          self.accountRefreshGeneration == $0
                              && self.currentUserID == accountID
                              && repository.currentCredentialRevision == credentialRevision
                      } ?? true)
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
        let accountGeneration = accountRefreshGeneration
        let accountID = currentUserID
        let credentialRevision = repository.currentCredentialRevision
        detailGenerations[route] = generation
        detailTasks[route]?.cancel()
        detailTasks[route] = nil
        try await library?.refreshPlaylistDetail(
            playlistID,
            expectedCredentialRevision: credentialRevision
        )

        let detail = try await repository.detail(
            for: route,
            expectedCredentialRevision: credentialRevision
        )
        try Task.checkCancellation()
        guard detailGenerations[route] == generation,
              accountRefreshGeneration == accountGeneration,
              currentUserID == accountID,
              repository.currentCredentialRevision == credentialRevision,
              case let .playlist(playlist, _, _, _) = detail
        else { throw CancellationError() }

        storeDetail(detail, for: route)
        staleDetailRoutes.remove(route)
        if path.last == route { detailLoads[route] = .loaded(detail) }
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

    func songPlaylistMembershipDidChange(
        _ songID: Int64,
        playlistID: Int64,
        isFavoritePlaylist: Bool,
        containsSong: Bool
    ) {
        if isFavoritePlaylist {
            if containsSong { likedSongIDs.insert(songID) } else { likedSongIDs.remove(songID) }
        }
        playlistSummariesDidChange()
        let route = Route.playlist(playlistID)
        guard case let .loaded(content)? = detailLoads[route],
              case let .playlist(originalPlaylist, songs, trackIDs, loadedTrackCount) = content
        else {
            staleDetailRoutes.insert(route)
            if path.last == route { loadDetail(route, reload: true) }
            return
        }

        var playlist = originalPlaylist
        var updatedSongs = songs
        var updatedTrackIDs = trackIDs
        var updatedLoadedCount = loadedTrackCount
        if containsSong {
            guard !trackIDs.contains(songID) else { return }
            guard let song = playlistPickerSong, song.id == songID else {
                staleDetailRoutes.insert(route)
                if path.last == route { loadDetail(route, reload: true) }
                return
            }
            updatedTrackIDs.append(songID)
            updatedSongs.append(song)
            updatedLoadedCount += 1
        } else {
            updatedTrackIDs.removeAll { $0 == songID }
            updatedSongs.removeAll { $0.id == songID }
            updatedLoadedCount = min(updatedLoadedCount, updatedTrackIDs.count)
        }
        playlist.trackCount = updatedTrackIDs.count
        let updated = DetailContent.playlist(
            playlist,
            songs: updatedSongs,
            trackIDs: updatedTrackIDs,
            loadedTrackCount: updatedLoadedCount
        )
        detailLoads[route] = .loaded(updated)
        storeDetail(updated, for: route)
        staleDetailRoutes.remove(route)
        if let index = librarySnapshot?.playlists.firstIndex(where: { $0.id == playlistID }) {
            librarySnapshot?.playlists[index].trackCount = updatedTrackIDs.count
        }
    }

    func playlistSummariesDidChange() {
        accountPlaylistsTask?.task.cancel()
        accountPlaylistsTask = nil
        playlistContentRevision += 1
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

    func accountPlaylists(
        userID: Int64,
        credentialRevision: UInt64,
        onUpdate: (([Playlist]) -> Void)? = nil
    ) async throws -> [Playlist] {
        guard userID > 0, let library else { throw EAPIError.invalidPayload }
        if currentUserID == userID,
           accountCredentialRevision == credentialRevision,
           let snapshot = librarySnapshot,
           snapshot.user.id == userID,
           cachedPlaylistsAreFresh() {
            onUpdate?(snapshot.playlists)
            return snapshot.playlists
        }

        let taskID: UUID
        let task: Task<[Playlist], any Error>
        if let existing = accountPlaylistsTask,
           existing.userID == userID,
           existing.credentialRevision == credentialRevision,
           existing.loadedAt.map({ Date().timeIntervalSince($0) < 90 }) ?? true {
            taskID = existing.id
            task = existing.task
        } else {
            accountPlaylistsTask?.task.cancel()
            taskID = UUID()
            accountPlaylistsProgress = nil
            accountPlaylistObservers.removeAll()
            task = Task { @MainActor [weak self, library] in
                try await library.userPlaylists(
                    userID: userID,
                    expectedCredentialRevision: credentialRevision
                ) { values in
                    guard let self, self.accountPlaylistsTask?.id == taskID else { return }
                    self.accountPlaylistsProgress = (taskID, values)
                    self.accountPlaylistObservers.values.forEach { $0(values) }
                }
            }
            accountPlaylistsTask = (taskID, userID, credentialRevision, task, nil)
        }

        let observerID = onUpdate.map { observer -> UUID in
            let id = UUID()
            accountPlaylistObservers[id] = observer
            if accountPlaylistsProgress?.taskID == taskID,
               let values = accountPlaylistsProgress?.values {
                observer(values)
            }
            return id
        }
        defer { if let observerID { accountPlaylistObservers[observerID] = nil } }

        let playlists: [Playlist]
        do {
            playlists = try await task.value
            if accountPlaylistsTask?.id == taskID, accountPlaylistsTask?.loadedAt == nil {
                accountPlaylistsTask?.loadedAt = Date()
            }
        } catch {
            if accountPlaylistsTask?.id == taskID {
                accountPlaylistsTask = nil
                accountPlaylistsProgress = nil
            }
            throw error
        }
        try Task.checkCancellation()
        guard currentUserID == userID,
              accountCredentialRevision == credentialRevision,
              library.transport.credentialSnapshotValue().revision == credentialRevision
        else { throw CancellationError() }
        return playlists
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
        guard path.last == route, playlistLoadMoreTasks[playlistID] == nil,
              case let .loaded(content)? = detailLoads[route],
              case let .playlist(_, _, trackIDs, loadedTrackCount) = content,
              let range = PlaylistSongPaging.nextRange(total: trackIDs.count, loaded: loadedTrackCount)
        else { return }

        loadingPlaylistIDs.insert(playlistID)
        playlistLoadMoreErrors[playlistID] = nil
        let taskID = UUID()
        playlistLoadMoreTaskIDs[playlistID] = taskID
        playlistLoadMoreTasks[playlistID] = Task { @MainActor [weak self, repository] in
            defer { self?.finishPlaylistLoadMore(playlistID, taskID: taskID) }
            do {
                let page = try await repository.songs(ids: Array(trackIDs[range]))
                try Task.checkCancellation()
                guard let self, self.path.last == route,
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
            } catch is CancellationError {
            } catch {
                guard let self, self.path.last == route else { return }
                self.playlistLoadMoreErrors[playlistID] = error.localizedDescription
            }
        }
    }

    private func finishPlaylistLoadMore(_ playlistID: Int64, taskID: UUID) {
        guard playlistLoadMoreTaskIDs[playlistID] == taskID else { return }
        playlistLoadMoreTaskIDs[playlistID] = nil
        playlistLoadMoreTasks[playlistID] = nil
        loadingPlaylistIDs.remove(playlistID)
    }

    private func discardInactiveDetails() {
        let activeRoutes = Set(path.last.map { [$0] } ?? [])
        detailTasks
            .filter { !activeRoutes.contains($0.key) }
            .values
            .forEach { $0.cancel() }
        detailTasks = detailTasks.filter { activeRoutes.contains($0.key) }

        let activePlaylistIDs = Set(activeRoutes.compactMap { route -> Int64? in
            guard case let .playlist(id) = route else { return nil }
            return id
        })
        playlistLoadMoreTasks
            .filter { !activePlaylistIDs.contains($0.key) }
            .values
            .forEach { $0.cancel() }
        playlistLoadMoreTasks = playlistLoadMoreTasks.filter { activePlaylistIDs.contains($0.key) }
        playlistLoadMoreTaskIDs = playlistLoadMoreTaskIDs.filter { activePlaylistIDs.contains($0.key) }
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

    func setVideoPlaybackQuality(_ quality: VideoQuality) {
        settings.videoPlaybackQuality = quality
        defaults.set(quality.rawValue, forKey: "videoPlaybackQuality")
        showToast("视频播放清晰度已保存")
    }

    func setVideoDownloadQuality(_ quality: VideoQuality) {
        settings.videoDownloadQuality = quality
        defaults.set(quality.rawValue, forKey: "videoDownloadQuality")
        showToast("视频下载清晰度已保存")
    }

    func setCrossfadeDuration(_ seconds: TimeInterval) {
        let seconds = min(max(seconds, 0), 12)
        settings.crossfadeDuration = seconds
        defaults.set(seconds, forKey: "crossfadeDuration")
        showToast(seconds == 0 ? "歌曲过渡已关闭" : "歌曲过渡已保存")
    }

    func setPlaybackControlFadeEnabled(_ enabled: Bool) {
        settings.playbackControlFadeEnabled = enabled
        defaults.set(enabled, forKey: "playbackControlFadeEnabled")
        showToast(enabled ? "播放控制淡入淡出已开启" : "播放控制淡入淡出已关闭")
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
        if enabled {
            let title = homeDescriptors.first(where: { $0.id == id })?.title ?? id
            homeSlots.append(HomeSlot(id: id, title: title, load: .loading))
            homeSlots.sort { descriptorIndex($0.id) < descriptorIndex($1.id) }
            startHomeTask(id: id, generation: homeGeneration)
        } else {
            homeTasks[id]?.task.cancel()
            homeTasks[id] = nil
            homeCache[id] = nil
            homeSlots.removeAll { $0.id == id }
        }
    }

    func setDownloadFolder(_ url: URL) {
        do {
            let bookmark = try folderBookmark(for: url)
            settings.downloadBookmark = bookmark
            defaults.set(bookmark, forKey: "downloadBookmark")
            resolvedDownloadFolder = url
            restoreBookmarkedFolders()
            settingsMessage = nil
            showToast("音频下载位置已保存")
        } catch {
            settingsMessage = "无法保存音频下载目录权限"
        }
    }

    func setVideoDownloadFolder(_ url: URL) {
        do {
            let bookmark = try folderBookmark(for: url)
            settings.videoDownloadBookmark = bookmark
            defaults.set(bookmark, forKey: "videoDownloadBookmark")
            resolvedVideoDownloadFolder = url
            restoreBookmarkedFolders()
            settingsMessage = nil
            showToast("视频下载位置已保存")
        } catch {
            settingsMessage = "无法保存视频下载目录权限"
        }
    }

    func setCacheFolder(_ url: URL) {
        do {
            let bookmark = try folderBookmark(for: url)
            settings.cacheBookmark = bookmark
            defaults.set(bookmark, forKey: "cacheBookmark")
            commitCacheFolder(url)
            restoreBookmarkedFolders()
            settingsMessage = nil
            showToast("缓存位置已保存")
        } catch {
            settingsMessage = "无法保存缓存目录权限"
        }
    }

    func clearCacheFolder() {
        guard settings.cacheBookmark != nil || resolvedCacheFolder != nil else { return }
        settings.cacheBookmark = nil
        defaults.removeObject(forKey: "cacheBookmark")
        commitCacheFolder(nil)
        restoreBookmarkedFolders()
        settingsMessage = nil
        showToast("缓存位置已恢复默认")
    }

    func setImageFolder(_ url: URL) {
        do {
            let bookmark = try folderBookmark(for: url)
            settings.imageBookmark = bookmark
            defaults.set(bookmark, forKey: "imageBookmark")
            resolvedImageFolder = url
            restoreBookmarkedFolders()
            settingsMessage = nil
            showToast("图片保存位置已保存")
        } catch {
            settingsMessage = "无法保存图片目录权限"
        }
    }

    func setSheetFolder(_ url: URL) {
        do {
            let bookmark = try folderBookmark(for: url)
            settings.sheetBookmark = bookmark
            defaults.set(bookmark, forKey: "sheetBookmark")
            resolvedSheetFolder = url
            restoreBookmarkedFolders()
            settingsMessage = nil
            showToast("琴谱保存位置已保存")
        } catch {
            settingsMessage = "无法保存琴谱目录权限"
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

        return downloads.enqueue(
            songs: trackIDs.compactMap { songsByID[$0] },
            to: downloadFolderURL,
            quality: quality,
            includeLyrics: true
        )
    }

    func download(_ song: CloudSong) {
        guard let downloads,
              let userID = currentUserID,
              let credentialRevision = accountCredentialRevision,
              library?.transport.credentialSnapshotValue().revision == credentialRevision
        else { return }
        downloads.enqueue(
            cloudSong: song,
            userID: userID,
            expectedCredentialRevision: credentialRevision,
            to: downloadFolderURL,
            includeLyrics: true
        )
    }

    func saveArtwork(from sourceURL: URL, title: String) {
        let destinationFolder = imageFolderURL
        let cleanedTitle = MusicDownloadFiles.sanitizedFileName(title)
        let fileName = cleanedTitle.isEmpty ? "封面" : cleanedTitle
        let fileExtension = sourceURL.pathExtension.lowercased() == "png" ? "png" : "jpg"
        let destination = destinationFolder.appending(path: fileName).appendingPathExtension(fileExtension)
        guard savingArtworkDestinations.insert(destination).inserted else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.savingArtworkDestinations.remove(destination) }
            do {
                let data = try await ArtworkPipeline.shared.loadData(for: sourceURL)
                try await artworkFileWriter.write(data, to: destination, folder: destinationFolder)
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
        startMutation(.songLike(songID), transport: library.transport, operation: { revision in
            try await library.setSongLiked(
                songID,
                liked: liked,
                expectedCredentialRevision: revision
            )
        }) { model in
            if liked { model.likedSongIDs.insert(songID) } else { model.likedSongIDs.remove(songID) }
            model.playlistContentsDidChange()
            model.showToast(liked ? "已喜欢歌曲" : "已取消喜欢")
        }
    }

    func favoriteSongs(_ songIDs: [Int64]) async throws -> Int {
        if let favoriteTask {
            _ = try await favoriteTask.value
            return try await favoriteSongs(songIDs)
        }
        guard let library,
              let userID = currentUserID,
              let revision = accountCredentialRevision,
              library.transport.credentialSnapshotValue().revision == revision
        else { return 0 }
        var seen = Set<Int64>()
        let ids = songIDs.filter {
            $0 > 0 && seen.insert($0).inserted && !likedSongIDs.contains($0)
        }
        guard !ids.isEmpty else { return 0 }

        let generation = accountRefreshGeneration
        let keys = Set(ids.map(LibraryMutationKey.songLike))
        guard pendingMutations.isDisjoint(with: keys) else { return 0 }
        let taskID = UUID()
        favoriteTaskID = taskID
        pendingMutations.formUnion(keys)
        let task = Task { @MainActor [weak self, library] () throws -> Int in
            guard let self else { throw CancellationError() }
            var successfulIDs: [Int64] = []
            defer {
                if !successfulIDs.isEmpty,
                   self.accountContextMatches(
                       generation: generation,
                       userID: userID,
                       credentialRevision: revision,
                       transport: library.transport
                   ) {
                    self.playlistContentsDidChange()
                }
                self.finishFavoriteTask(id: taskID, keys: keys)
            }
            for songID in ids {
                try Task.checkCancellation()
                guard self.accountContextMatches(
                    generation: generation,
                    userID: userID,
                    credentialRevision: revision,
                    transport: library.transport
                ) else { throw CancellationError() }
                do {
                    try await library.setSongLiked(
                        songID,
                        liked: true,
                        expectedCredentialRevision: revision
                    )
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    guard self.accountContextMatches(
                        generation: generation,
                        userID: userID,
                        credentialRevision: revision,
                        transport: library.transport
                    ) else { throw CancellationError() }
                    let failedIndex = successfulIDs.count
                    throw FavoriteSongsFailure(
                        successfulIDs: successfulIDs,
                        failedID: songID,
                        unattemptedIDs: Array(ids.dropFirst(failedIndex + 1)),
                        causeDescription: error.localizedDescription
                    )
                }
                try Task.checkCancellation()
                guard self.accountContextMatches(
                    generation: generation,
                    userID: userID,
                    credentialRevision: revision,
                    transport: library.transport
                ) else { throw CancellationError() }
                self.likedSongIDs.insert(songID)
                successfulIDs.append(songID)
            }
            return successfulIDs.count
        }
        favoriteTask = task
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    func setPlaylistSubscribed(_ id: Int64, subscribed: Bool) {
        guard let library else { return }
        startMutation(.playlistSubscription(id), transport: library.transport, operation: { revision in
            try await library.setPlaylistSubscribed(
                id,
                subscribed: subscribed,
                expectedCredentialRevision: revision
            )
        }) { model in
            model.playlistSubscriptionOverrides[id] = subscribed
            if let index = model.librarySnapshot?.playlists.firstIndex(where: { $0.id == id }) {
                model.librarySnapshot?.playlists[index].isSubscribed = subscribed
            }
            model.playlistSummariesDidChange()
            model.showToast(subscribed ? "歌单已收藏" : "已取消收藏歌单")
        }
    }

    func recordVideoSubscriptions(_ resources: [VideoPageResource]) {
        for resource in resources where videoSubscriptionOverrides[resource] == nil {
            videoSubscriptionOverrides[resource] = true
        }
        loadedVideoSubscriptionRevision = videoSubscriptionRevision
    }

    func videoSubscriptionDidChange(_ resource: VideoPageResource, subscribed: Bool) {
        videoSubscriptionOverrides[resource] = subscribed
        videoSubscriptionRevision += 1
        showToast(subscribed ? "\(resource.displayName)已收藏" : "已取消收藏\(resource.displayName)")
    }

    func setAlbumSubscribed(_ id: Int64, subscribed: Bool) {
        guard let library else { return }
        startMutation(.albumSubscription(id), transport: library.transport, operation: { revision in
            try await library.setAlbumSubscribed(
                id,
                subscribed: subscribed,
                expectedCredentialRevision: revision
            )
        }) { model in
            model.albumSubscriptionOverrides[id] = subscribed
            model.showToast(subscribed ? "专辑已收藏" : "已取消收藏专辑")
        }
    }

    func setArtistFollowed(_ id: Int64, followed: Bool) {
        guard let library else { return }
        startMutation(.artistFollow(id), transport: library.transport, operation: { revision in
            try await library.setArtistFollowed(
                id,
                followed: followed,
                expectedCredentialRevision: revision
            )
        }) { model in
            model.artistFollowOverrides[id] = followed
            model.showToast(followed ? "已关注歌手" : "已取消关注歌手")
        }
    }

    func setUserFollowed(_ id: Int64, followed: Bool) {
        guard let library else { return }
        startMutation(.userFollow(id), transport: library.transport, operation: { revision in
            try await library.setUserFollowed(
                id,
                followed: followed,
                expectedCredentialRevision: revision
            )
        }) { model in
            model.userFollowOverrides[id] = followed
            model.showToast(followed ? "已关注用户" : "已取消关注用户")
        }
    }

    func addSongToPlaylist(
        _ songID: Int64,
        playlistID: Int64,
        isFavoritePlaylist: Bool,
        onFailure: (@MainActor (String) -> Void)? = nil
    ) {
        guard let library else { return }
        startMutation(
            .playlistSong(playlistID: playlistID, songID: songID),
            transport: library.transport,
            operation: { revision in
                try await library.addSongs(
                    [songID],
                    to: playlistID,
                    expectedCredentialRevision: revision
                )
            },
            failure: onFailure
        ) { model in
            model.songPlaylistMembershipDidChange(
                songID,
                playlistID: playlistID,
                isFavoritePlaylist: isFavoritePlaylist,
                containsSong: true
            )
            model.playlistPickerSong = nil
            model.showToast("已加入歌单")
        }
    }

    func removeSongFromPlaylist(_ songID: Int64, playlistID: Int64, isFavoritePlaylist: Bool) {
        guard let library else { return }
        startMutation(
            .playlistSong(playlistID: playlistID, songID: songID),
            transport: library.transport,
            operation: { revision in
                try await library.removeSongs(
                    [songID],
                    from: playlistID,
                    expectedCredentialRevision: revision
                )
            }
        ) { model in
            model.songPlaylistMembershipDidChange(
                songID,
                playlistID: playlistID,
                isFavoritePlaylist: isFavoritePlaylist,
                containsSong: false
            )
            model.showToast("已从歌单移除")
        }
    }

    func podcastSubscriptionOverride(for id: Int64) -> Bool? {
        podcastSubscriptionOverrides[id]
    }

    func commitPodcastSubscription(id: Int64, subscribed: Bool) {
        guard podcastSubscriptionOverrides[id] != subscribed else { return }
        podcastSubscriptionOverrides[id] = subscribed
        podcastSubscriptionRevision &+= 1
        showToast(subscribed ? "播客已订阅" : "已取消订阅播客")
    }

    var downloadPath: String {
        downloadFolderURL.path(percentEncoded: false)
    }

    var videoDownloadPath: String {
        videoDownloadFolderURL.path(percentEncoded: false)
    }

    var imagePath: String {
        imageFolderURL.path(percentEncoded: false)
    }

    var sheetPath: String {
        sheetFolderURL.path(percentEncoded: false)
    }

    var cachePath: String {
        cacheFolderURL.path(percentEncoded: false)
    }

    var cacheFolderURL: URL {
        resolvedCacheFolder ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: "TinyCloudMusic", directoryHint: .isDirectory)
    }

    private func startMutation(
        _ key: LibraryMutationKey,
        transport: EAPITransport,
        operation: @escaping @Sendable (UInt64) async throws -> Void,
        failure: (@MainActor (String) -> Void)? = nil,
        commit: @escaping @MainActor (AppModel) -> Void
    ) {
        let revision = transport.credentialSnapshotValue().revision
        guard let userID = currentUserID,
              accountCredentialRevision == revision,
              !pendingMutations.contains(key)
        else { return }
        let generation = accountRefreshGeneration
        let taskID = UUID()
        pendingMutations.insert(key)
        let task = Task { @MainActor [weak self] in
            defer { self?.finishMutation(key, taskID: taskID) }
            guard let self,
                  self.accountContextMatches(
                      generation: generation,
                      userID: userID,
                      credentialRevision: revision,
                      transport: transport
                  )
            else { return }
            do {
                try await operation(revision)
                try Task.checkCancellation()
                guard self.accountContextMatches(
                    generation: generation,
                    userID: userID,
                    credentialRevision: revision,
                    transport: transport
                ) else { return }
                commit(self)
            } catch is CancellationError {
            } catch {
                guard self.accountContextMatches(
                    generation: generation,
                    userID: userID,
                    credentialRevision: revision,
                    transport: transport
                ) else { return }
                if let failure {
                    failure(error.localizedDescription)
                } else {
                    self.libraryMessage = error.localizedDescription
                }
            }
        }
        mutationTasks[key] = MutationTaskEntry(id: taskID, task: task)
    }

    private func finishMutation(_ key: LibraryMutationKey, taskID: UUID) {
        guard mutationTasks[key]?.id == taskID else { return }
        mutationTasks[key] = nil
        pendingMutations.remove(key)
    }

    private func finishFavoriteTask(id: UUID, keys: Set<LibraryMutationKey>) {
        guard favoriteTaskID == id else { return }
        favoriteTask = nil
        favoriteTaskID = nil
        pendingMutations.subtract(keys)
    }

    private func accountContextMatches(
        generation: Int,
        userID: Int64,
        credentialRevision: UInt64,
        transport: EAPITransport
    ) -> Bool {
        accountRefreshGeneration == generation
            && currentUserID == userID
            && accountCredentialRevision == credentialRevision
            && transport.credentialSnapshotValue().revision == credentialRevision
    }

    private func startHomeTask(id: String, generation: Int) {
        let taskID = UUID()
        let accountGeneration = accountRefreshGeneration
        let accountID = currentUserID
        let credentialRevision = repository.currentCredentialRevision
        let task = Task { @MainActor [weak self, repository] in
            defer { self?.finishHomeTask(id: id, taskID: taskID) }
            do {
                let section = try await repository.homeSection(
                    id: id,
                    expectedCredentialRevision: credentialRevision
                )
                try Task.checkCancellation()
                guard let self,
                      self.homeGeneration == generation,
                      self.homeSlots.contains(where: { $0.id == id }),
                      self.accountRefreshGeneration == accountGeneration,
                      self.currentUserID == accountID,
                      repository.currentCredentialRevision == credentialRevision
                else { return }
                self.homeCache[id] = section
                self.updateHomeSlot(id: id, load: .loaded(section))
            } catch is CancellationError {
            } catch {
                guard let self,
                      self.homeGeneration == generation,
                      self.accountRefreshGeneration == accountGeneration,
                      self.currentUserID == accountID,
                      repository.currentCredentialRevision == credentialRevision
                else { return }
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

    func invalidateAccountDomainIfNeeded(forCredentialRevision credentialRevision: UInt64) {
        let isUnauthenticated = session.map { $0.state != .authenticated } ?? false
        guard currentUserID != nil || accountCredentialRevision != nil,
              isUnauthenticated || accountCredentialRevision != credentialRevision
        else { return }
        _ = resetAccountScopedState(userID: nil, credentialRevision: nil)
    }

    @discardableResult
    func installConfirmedAccount(userID: Int64, credentialRevision: UInt64) -> Int {
        resetAccountScopedState(userID: userID, credentialRevision: credentialRevision)
    }

    @discardableResult
    private func resetAccountScopedState(userID: Int64?, credentialRevision: UInt64?) -> Int {
        accountRefreshGeneration += 1
        let generation = accountRefreshGeneration
        mutationTasks.values.forEach { $0.task.cancel() }
        mutationTasks.removeAll()
        favoriteTask?.cancel()
        favoriteTask = nil
        favoriteTaskID = nil
        accountPlaylistsTask?.task.cancel()
        accountPlaylistsTask = nil
        accountPlaylistsProgress = nil
        accountPlaylistObservers.removeAll()
        pendingMutations.removeAll()
        homeGeneration += 1
        homeTasks.values.forEach { $0.task.cancel() }
        homeTasks.removeAll()
        homeCache.removeAll()
        rebuildHomeSlots()

        searchGeneration += 1
        searchTask?.cancel()
        searchTask = nil
        searchLoad = .idle
        isSearchLoadingMore = false
        searchLoadMoreError = nil
        searchHintGeneration += 1
        searchHintTask?.cancel()
        searchHintTask = nil
        searchDirectMatchTask?.cancel()
        searchDirectMatchTask = nil
        searchHints = []
        searchDirectMatches = []
        searchHintCache.removeAll()
        hotSearchGeneration += 1
        hotSearchTask?.cancel()
        hotSearchTask = nil
        hotSearchItems = []
        isHotSearchLoading = false

        detailTasks.values.forEach { $0.cancel() }
        detailTasks.removeAll()
        playlistLoadMoreTasks.values.forEach { $0.cancel() }
        playlistLoadMoreTasks.removeAll()
        playlistLoadMoreTaskIDs.removeAll()
        loadingPlaylistIDs.removeAll()
        playlistLoadMoreErrors.removeAll()
        detailGenerations.removeAll()
        detailLoads.removeAll()
        detailCache.removeAll()
        staleDetailRoutes.removeAll()
        path.removeAll()

        likedSongIDs = []
        playlistSubscriptionOverrides.removeAll()
        videoSubscriptionOverrides.removeAll()
        videoSubscriptionRevision = 0
        loadedVideoSubscriptionRevision = 0
        albumSubscriptionOverrides.removeAll()
        artistFollowOverrides.removeAll()
        userFollowOverrides.removeAll()
        podcastSubscriptionOverrides.removeAll()
        podcastSubscriptionRevision &+= 1
        broadcastCollectionOverrides.removeAll()
        librarySnapshot = nil
        playlistContentRevision = 0
        cachedPlaylistRevision = -1
        cachedPlaylistsLoadedAt = nil
        playlistPickerSong = nil
        accountCredentialRevision = userID == nil ? nil : credentialRevision
        downloads?.setCloudDownloadAccount(
            userID: userID,
            credentialRevision: accountCredentialRevision
        )
        personalFM?.setAccount(userID)
        uploads?.setAccount(userID, credentialRevision: accountCredentialRevision)
        currentUserID = userID
        return generation
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
        resolvedDownloadFolder ?? defaultDownloadRoot
            .appending(path: "歌曲", directoryHint: .isDirectory)
    }

    var videoDownloadFolderURL: URL {
        resolvedVideoDownloadFolder ?? defaultDownloadRoot
            .appending(path: "视频", directoryHint: .isDirectory)
    }

    var imageFolderURL: URL {
        resolvedImageFolder ?? resolvedDownloadFolder ?? defaultDownloadRoot
            .appending(path: "图片", directoryHint: .isDirectory)
    }

    var sheetFolderURL: URL {
        resolvedSheetFolder ?? resolvedDownloadFolder ?? defaultDownloadRoot
            .appending(path: "琴谱", directoryHint: .isDirectory)
    }

    private var defaultDownloadRoot: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
            .appending(path: "TinyCloudMusicDownloads", directoryHint: .isDirectory)
    }

    private func folderBookmark(for url: URL) throws -> Data {
        try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    private func restoreBookmarkedFolders() {
        bookmarkGeneration += 1
        let generation = bookmarkGeneration
        bookmarkResolveTask?.cancel()
        let bookmarks = (
            settings.downloadBookmark,
            settings.videoDownloadBookmark,
            settings.imageBookmark,
            settings.sheetBookmark,
            settings.cacheBookmark
        )
        let resolver = bookmarkResolver
        bookmarkResolveTask = Task { @MainActor [weak self] in
            let resolved = await Task.detached(priority: .utility) {
                let download = await resolver(bookmarks.0)
                let video = await resolver(bookmarks.1)
                let image = await resolver(bookmarks.2)
                let sheet = await resolver(bookmarks.3)
                let cache = await resolver(bookmarks.4)
                return ResolvedFolders(
                    download: download,
                    video: video,
                    image: image,
                    sheet: sheet,
                    cache: cache
                )
            }.value
            guard let self else { return }
            defer { self.bookmarkResolutionCompletionCount &+= 1 }
            guard self.bookmarkGeneration == generation, !Task.isCancelled else { return }
            self.resolvedDownloadFolder = resolved.download
            self.resolvedVideoDownloadFolder = resolved.video
            self.resolvedImageFolder = resolved.image
            self.resolvedSheetFolder = resolved.sheet
            self.commitCacheFolder(resolved.cache)
            self.bookmarkResolveTask = nil
        }
    }

    private func commitCacheFolder(_ folder: URL?) {
        let previousRoot = cacheFolderURL.standardizedFileURL
        resolvedCacheFolder = folder?.standardizedFileURL
        let root = cacheFolderURL.standardizedFileURL
        guard root != previousRoot else { return }
        downloadCacheConfigurator(root)
        cacheConfigurationRevision &+= 1
    }

    nonisolated private static func resolveFolder(_ bookmark: Data?) -> URL? {
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
