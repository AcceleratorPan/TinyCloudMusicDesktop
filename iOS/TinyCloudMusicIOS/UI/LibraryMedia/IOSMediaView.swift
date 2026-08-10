import AVKit
import CryptoKit
import PDFKit
import SwiftUI
import UIKit

struct IOSMediaView: View {
    @Bindable private var model: AppModel
    @Bindable private var player: PlayerController
    @State private var isImporting = false
    @State private var showsUploads = false
    @State private var uploadError: String?

    init(container: IOSAppContainer) {
        model = container.model
        player = container.player
    }

    var body: some View {
        List {
            Section("视频") {
                NavigationLink {
                    IOSVideoRecommendationsView(model: model, player: player)
                } label: {
                    Label("MV 与视频", systemImage: "play.rectangle.on.rectangle")
                }
            }

            Section("声音") {
                NavigationLink {
                    IOSAudioDiscoveryView(model: model)
                } label: {
                    Label("播客与广播", systemImage: "dot.radiowaves.left.and.right")
                }
                NavigationLink(value: Route.podcastSubscriptions) {
                    Label("订阅的播客", systemImage: "star")
                }
                NavigationLink {
                    IOSPersonalFMView(model: model, player: player)
                } label: {
                    Label("私人 FM", systemImage: "radio")
                }
            }

            Section("音乐知识") {
                NavigationLink(value: Route.musicStyles) {
                    Label("曲风", systemImage: "guitars")
                }
                if let song = player.currentSong {
                    NavigationLink {
                        IOSMusicKnowledgeView(song: song, model: model)
                    } label: {
                        Label("当前歌曲百科", systemImage: "text.book.closed")
                    }
                    NavigationLink {
                        IOSMusicSheetsView(song: song, model: model)
                    } label: {
                        Label("当前歌曲乐谱", systemImage: "music.quarternote.3")
                    }
                } else {
                    LabeledContent {
                        Text("播放歌曲后可用").foregroundStyle(.secondary)
                    } label: {
                        Label("歌曲百科与乐谱", systemImage: "text.book.closed")
                    }
                }
            }

            if model.uploads != nil {
                Section("上传") {
                    Button { isImporting = true } label: {
                        Label("上传音频到云盘", systemImage: "arrow.up.circle")
                    }
                    .disabled(model.currentUserID == nil)
                    Button { showsUploads = true } label: {
                        Label("上传任务", systemImage: "tray.full")
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("媒体")
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
}

struct IOSLibraryMediaRouteView: View {
    let route: Route
    @Bindable var model: AppModel
    @Bindable var player: PlayerController

    @ViewBuilder
    var body: some View {
        switch route {
        case .cloudMusic:
            IOSCloudMusicView(model: model, player: player)
        case let .comments(songID):
            IOSCommentsView(songID: songID, model: model)
        case let .similarSongs(song):
            IOSSimilarSongsView(source: song, model: model, player: player)
        case .recommendationHistory:
            IOSRecommendationHistoryView(model: model, player: player)
        case .listeningFootprints:
            IOSListeningFootprintsView(model: model, player: player)
        case let .mv(id):
            IOSVideoDetailView(resource: .mv(id), model: model, player: player)
        case let .video(id):
            IOSVideoDetailView(resource: .video(id), model: model, player: player)
        case let .podcast(id):
            IOSPodcastDetailView(podcastID: id, model: model, player: player)
        case let .podcastEpisode(id):
            IOSPodcastEpisodeView(episodeID: id, model: model, player: player)
        case let .broadcast(id, coverURL):
            IOSBroadcastDetailView(channelID: id, coverURL: coverURL, model: model, songPlayer: player)
        case .podcastSubscriptions:
            IOSPodcastSubscriptionsView(model: model)
        case .musicStyles:
            IOSMusicStylesView(model: model)
        case let .musicStyle(id, name):
            IOSMusicStyleDetailView(styleID: id, styleName: name, model: model, player: player)
        case .home, .search, .artist, .album, .playlist, .user:
            IOSLibraryEmptyState(title: "无法打开此页面", symbol: "questionmark.circle")
        }
    }
}

private enum IOSVideoSection: String, CaseIterable, Identifiable {
    case recommendations = "推荐"
    case mvs = "MV"
    case subscriptions = "收藏"
    var id: Self { self }
}

private struct IOSVideoRecommendationsView: View {
    @Bindable var model: AppModel
    @Bindable var player: PlayerController
    @State private var section = IOSVideoSection.recommendations
    @State private var items: [VideoRecommendation] = []
    @State private var subscriptionPage: VideoSubscriptionPage?
    @State private var nextOffset = 0
    @State private var isLoading = true
    @State private var isLoadingMore = false
    @State private var errorMessage: String?
    @State private var loadGeneration = 0

    var body: some View {
        VStack(spacing: 0) {
            Picker("视频内容", selection: $section) {
                ForEach(IOSVideoSection.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding()
            Divider()
            content
        }
        .navigationTitle("MV 与视频")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: "\(section.rawValue):\(model.currentUserID ?? 0):\(revision)") { await load(force: false) }
        .toolbar {
            ToolbarItem {
                Button { Task { await load(force: true) } } label: { Image(systemName: "arrow.clockwise") }
                    .accessibilityLabel("刷新视频")
                    .disabled(isLoading || isLoadingMore)
            }
        }
    }

    private var revision: UInt64 {
        model.videoLibrary?.transport.credentialSnapshotValue().revision ?? 0
    }

    @ViewBuilder
    private var content: some View {
        if section == .subscriptions && model.currentUserID == nil {
            IOSLibraryEmptyState(title: "登录后查看收藏视频", symbol: "star")
        } else if isLoading && items.isEmpty {
            IOSLibraryLoadingView(title: "正在载入视频")
        } else if let errorMessage, items.isEmpty {
            IOSLibraryFailureView(title: "无法载入视频", message: errorMessage) {
                Task { await load(force: true) }
            }
        } else if items.isEmpty {
            IOSLibraryEmptyState(title: "暂无视频", symbol: "play.rectangle")
        } else {
            List {
                ForEach(items) { item in
                    NavigationLink(value: item.route) {
                        IOSVideoRecommendationLabel(item: item)
                    }
                }
                if canLoadMore {
                    Button("载入更多") { Task { await loadMore() } }
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .disabled(isLoadingMore)
                }
                if let errorMessage {
                    IOSInlineRetry(message: errorMessage) { Task { await loadMore() } }
                }
            }
            .listStyle(.plain)
            .refreshable { await load(force: true) }
        }
    }

    private var canLoadMore: Bool {
        switch section {
        case .recommendations: !items.isEmpty
        case .mvs: false
        case .subscriptions: subscriptionPage?.hasMore == true
        }
    }

    @MainActor
    private func load(force: Bool) async {
        loadGeneration &+= 1
        let generation = loadGeneration
        let section = section
        let revision = revision
        isLoadingMore = false
        guard let library = model.videoLibrary else {
            isLoading = false
            errorMessage = "视频服务不可用"
            return
        }
        isLoading = true
        errorMessage = nil
        items = []
        subscriptionPage = nil
        nextOffset = 0
        do {
            let loadedItems: [VideoRecommendation]
            let loadedPage: VideoSubscriptionPage?
            switch section {
            case .recommendations:
                loadedItems = try await library.recommendations(
                    refreshCache: force,
                    expectedCredentialRevision: revision
                )
                loadedPage = nil
            case .mvs:
                loadedItems = try await library.personalizedMVs(
                    refreshCache: force,
                    expectedCredentialRevision: revision
                )
                loadedPage = nil
            case .subscriptions:
                let page = try await library.subscriptions(
                    refreshCache: force,
                    expectedCredentialRevision: revision
                )
                loadedItems = page.items
                loadedPage = page
            }
            try Task.checkCancellation()
            guard loadGeneration == generation,
                  self.section == section,
                  self.revision == revision
            else { return }
            items = loadedItems
            subscriptionPage = loadedPage
            nextOffset = section == .recommendations ? loadedItems.count : 0
            if let loadedPage { model.recordVideoSubscriptions(loadedPage.items.map(\.resource)) }
            isLoading = false
        } catch is CancellationError {
        } catch {
            guard loadGeneration == generation,
                  self.section == section,
                  self.revision == revision
            else { return }
            isLoading = false
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func loadMore() async {
        guard let library = model.videoLibrary, !isLoading, !isLoadingMore else { return }
        let generation = loadGeneration
        let section = section
        let revision = revision
        isLoadingMore = true
        errorMessage = nil
        defer {
            if loadGeneration == generation,
               self.section == section,
               self.revision == revision {
                isLoadingMore = false
            }
        }
        do {
            switch section {
            case .recommendations:
                let offset = nextOffset
                let next = try await library.recommendations(
                    offset: offset,
                    expectedCredentialRevision: revision
                )
                try Task.checkCancellation()
                guard loadGeneration == generation,
                      self.section == section,
                      self.revision == revision,
                      nextOffset == offset
                else { return }
                var seen = Set(items.map(\.id))
                let additions = next.filter { seen.insert($0.id).inserted }
                items += additions
                nextOffset += max(next.count, 1)
            case .subscriptions:
                guard let page = subscriptionPage else { break }
                let next = try await library.subscriptions(
                    offset: page.nextOffset,
                    expectedCredentialRevision: revision
                )
                try Task.checkCancellation()
                guard loadGeneration == generation,
                      self.section == section,
                      self.revision == revision,
                      subscriptionPage?.nextOffset == page.nextOffset
                else { return }
                let combined = page.appending(next)
                subscriptionPage = combined
                items = combined.items
                model.recordVideoSubscriptions(next.items.map(\.resource))
            case .mvs:
                break
            }
        } catch is CancellationError {
        } catch {
            guard loadGeneration == generation,
                  self.section == section,
                  self.revision == revision
            else { return }
            errorMessage = error.localizedDescription
        }
    }
}

private struct IOSVideoRecommendationLabel: View {
    let item: VideoRecommendation

    var body: some View {
        HStack(spacing: 12) {
            IOSRemoteArtwork(url: coverURL, symbol: "play.rectangle")
                .frame(width: 72, height: 52)
                .aspectRatio(16 / 9, contentMode: .fit)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).lineLimit(2)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .frame(minHeight: 60)
    }

    private var title: String {
        switch item { case let .mv(value): value.title; case let .video(value): value.title }
    }
    private var subtitle: String {
        switch item { case let .mv(value): value.artistName; case let .video(value): value.creatorName }
    }
    private var coverURL: URL? {
        switch item { case let .mv(value): value.coverURL; case let .video(value): value.coverURL }
    }
}

private enum IOSVideoLoadedDetail {
    case mv(MVDetail)
    case video(VideoDetail)

    var title: String { switch self { case let .mv(v): v.title; case let .video(v): v.title } }
    var creator: String { switch self { case let .mv(v): v.artistName; case let .video(v): v.creatorName } }
    var description: String { switch self { case let .mv(v): v.description; case let .video(v): v.description } }
    var publishTime: String { switch self { case let .mv(v): v.publishTime; case let .video(v): v.publishTime } }
    var playCount: Int64 { switch self { case let .mv(v): v.playCount; case let .video(v): v.playCount } }
    var coverURL: URL? { switch self { case let .mv(v): v.coverURL; case let .video(v): v.coverURL } }
    var availableResolutions: [Int] { switch self { case let .mv(v): v.availableResolutions; case let .video(v): v.availableResolutions } }
    var isSubscribed: Bool { switch self { case let .mv(v): v.isSubscribed; case let .video(v): v.isSubscribed } }
}

private struct IOSVideoDetailView: View {
    let resource: VideoPageResource
    @Bindable var model: AppModel
    @Bindable var player: PlayerController
    @State private var detail: IOSVideoLoadedDetail?
    @State private var videoPlayer: AVPlayer?
    @State private var related: [VideoRecommendation] = []
    @State private var isLoadingRelated = false
    @State private var relatedError: String?
    @State private var isSubscribed = false
    @State private var isWriting = false
    @State private var isLoading = true
    @State private var selectedResolution = 720
    @State private var activeResolution: Int?
    @State private var isSwitchingResolution = false
    @State private var resolutionTask: Task<Void, Never>?
    @State private var playbackError: String?
    @State private var detailRefreshError: String?
    @State private var mutationError: String?
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if isLoading && detail == nil {
                IOSLibraryLoadingView(title: "正在载入\(resource.displayName)")
            } else if let errorMessage, detail == nil {
                IOSLibraryFailureView(title: "无法载入\(resource.displayName)", message: errorMessage) {
                    Task { await load(force: true) }
                }
            } else if let detail {
                List {
                    Section {
                        ZStack {
                            VideoPlayer(player: videoPlayer)
                                .aspectRatio(16 / 9, contentMode: .fit)
                                .background(.black)
                                .accessibilityLabel("\(detail.title)视频播放器")
                            if isSwitchingResolution {
                                ProgressView()
                                    .controlSize(.large)
                                    .tint(.white)
                                    .padding(14)
                                    .background(.black.opacity(0.7), in: Circle())
                                    .accessibilityLabel("正在切换视频清晰度")
                            }
                        }
                        VStack(alignment: .leading, spacing: 7) {
                            Text(detail.title).font(.title3.weight(.semibold))
                            Text(detail.creator).foregroundStyle(.secondary)
                            Text([detail.publishTime, "\(detail.playCount.formatted()) 次播放"]
                                .filter { !$0.isEmpty }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary)
                            if !detail.description.isEmpty {
                                Text(detail.description).font(.subheadline).textSelection(.enabled)
                            }
                            if let playbackError {
                                Label(playbackError, systemImage: "exclamationmark.triangle")
                                    .font(.caption)
                                    .foregroundStyle(.red)
                                if videoPlayer == nil {
                                    Button("重试播放") {
                                        resolutionTask?.cancel()
                                        resolutionTask = Task { await switchResolution(to: selectedResolution) }
                                    }
                                }
                            }
                        }
                    }
                    if let detailRefreshError {
                        Section("详情刷新失败") {
                            IOSInlineRetry(message: detailRefreshError) {
                                Task { await load(force: true) }
                            }
                        }
                    }
                    Section("操作") {
                        if !selectableResolutions.isEmpty {
                            Picker("播放清晰度", selection: Binding(
                                get: { selectedResolution },
                                set: { value in
                                    resolutionTask?.cancel()
                                    resolutionTask = Task { await switchResolution(to: value) }
                                }
                            )) {
                                ForEach(selectableResolutions, id: \.self) { resolution in
                                    Text("\(resolution)P").tag(resolution)
                                }
                            }
                            .disabled(isSwitchingResolution)
                        }
                        Button { Task { await setSubscribed(!isSubscribed) } } label: {
                            Label(isSubscribed ? "取消收藏" : "收藏", systemImage: isSubscribed ? "star.fill" : "star")
                        }
                        .disabled(model.currentUserID == nil || isWriting)
                        if let downloads = model.downloads {
                            Button {
                                _ = downloads.enqueue(
                                    video: resource,
                                    title: detail.title,
                                    creator: detail.creator,
                                    availableResolutions: detail.availableResolutions,
                                    to: model.videoDownloadFolderURL,
                                    quality: model.settings.videoDownloadQuality
                                )
                            } label: {
                                Label("下载视频", systemImage: "arrow.down.circle")
                            }
                        }
                    }
                    if case let .mv(id) = resource {
                        IOSMVKnowledgeSection(mvID: id, model: model)
                    }
                    if isLoadingRelated {
                        Section("相关推荐") {
                            HStack { ProgressView(); Text("正在载入推荐").foregroundStyle(.secondary) }
                        }
                    } else if let relatedError {
                        Section("相关推荐") {
                            IOSInlineRetry(message: relatedError) { Task { await loadRelated() } }
                        }
                    } else if !related.isEmpty {
                        Section("相关推荐") {
                            ForEach(related) { item in
                                NavigationLink(value: item.route) { IOSVideoRecommendationLabel(item: item) }
                            }
                        }
                    }
                    if let library = model.videoLibrary {
                        IOSVideoCommentsSection(
                            resource: resource.commentResource,
                            library: library,
                            model: model
                        )
                    }
                }
                .listStyle(.insetGrouped)
                .refreshable {
                    await load(force: true)
                    await loadRelated()
                }
            }
        }
        .navigationTitle(resource.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: resource.identity) { await load(force: false) }
        .task(id: "\(resource.identity)-related") { await loadRelated() }
        .onDisappear {
            resolutionTask?.cancel()
            resolutionTask = nil
            videoPlayer?.pause()
            videoPlayer?.replaceCurrentItem(with: nil)
            videoPlayer = nil
        }
        .alert("操作失败", isPresented: Binding(
            get: { mutationError != nil },
            set: { if !$0 { mutationError = nil } }
        )) {
            Button("好") { mutationError = nil }
        } message: {
            Text(mutationError ?? "")
        }
    }

    private var selectableResolutions: [Int] {
        guard let detail else { return [] }
        return VideoResolutionPolicy.normalized(detail.availableResolutions)
    }

    @MainActor
    private func load(force: Bool) async {
        guard let library = model.videoLibrary else {
            isLoading = false
            errorMessage = "视频服务不可用"
            return
        }
        let isRefreshing = detail != nil
        isLoading = true
        errorMessage = nil
        detailRefreshError = nil

        let loaded: IOSVideoLoadedDetail
        do {
            switch resource {
            case let .mv(id): loaded = .mv(try await library.mvDetail(id: id, refreshCache: force))
            case let .video(id): loaded = .video(try await library.videoDetail(id: id, refreshCache: force))
            }
            try Task.checkCancellation()
        } catch is CancellationError {
            return
        } catch {
            isLoading = false
            if isRefreshing { detailRefreshError = error.localizedDescription }
            else { errorMessage = error.localizedDescription }
            return
        }

        detail = loaded
        isSubscribed = model.videoSubscriptionOverrides[resource] ?? loaded.isSubscribed
        if isRefreshing, videoPlayer != nil {
            isLoading = false
            return
        }

        playbackError = nil
        activeResolution = nil
        let preferredResolution = VideoResolutionPolicy.preferred(
            model.settings.videoPlaybackQuality,
            available: loaded.availableResolutions
        ) ?? model.settings.videoPlaybackQuality.resolution
        selectedResolution = preferredResolution
        do {
            let source = try await playbackSource(for: loaded, resolution: preferredResolution)
            let playbackURL = try await VideoPlaybackURLResolver.resolve(source.url)
            try Task.checkCancellation()
            player.pauseForVideo()
            videoPlayer = AVPlayer(url: playbackURL)
            selectedResolution = source.resolution
            activeResolution = source.resolution
            videoPlayer?.play()
            isLoading = false
        } catch is CancellationError {
        } catch {
            isLoading = false
            playbackError = error.localizedDescription
        }
    }

    @MainActor
    private func loadRelated() async {
        guard let library = model.videoLibrary else {
            related = []
            isLoadingRelated = false
            relatedError = "视频服务不可用"
            return
        }
        isLoadingRelated = true
        relatedError = nil
        do {
            related = switch resource {
            case let .mv(id): try await library.related(toMV: id)
            case let .video(id): try await library.related(toVideo: id)
            }
        } catch is CancellationError {
        } catch {
            relatedError = error.localizedDescription
        }
        isLoadingRelated = false
    }

    private func playbackSource(
        for detail: IOSVideoLoadedDetail,
        resolution: Int
    ) async throws -> VideoPlaybackSource {
        guard let library = model.videoLibrary else {
            throw VideoLibraryError.unavailable("视频服务不可用")
        }
        return switch resource {
        case let .mv(id):
            try await library.mvPlaybackSource(
                id: id,
                preferredResolution: resolution,
                availableResolutions: detail.availableResolutions
            )
        case let .video(id):
            try await library.videoPlaybackSource(
                id: id,
                preferredResolution: resolution,
                availableResolutions: detail.availableResolutions
            )
        }
    }

    @MainActor
    private func switchResolution(to resolution: Int) async {
        guard let detail, resolution != activeResolution, !isSwitchingResolution else { return }
        let previousResolution = activeResolution ?? selectedResolution
        let previousPlayer = videoPlayer
        let position = previousPlayer?.currentTime()
        let shouldPlay = previousPlayer?.timeControlStatus != .paused
        selectedResolution = resolution
        playbackError = nil
        isSwitchingResolution = true
        do {
            let source = try await playbackSource(for: detail, resolution: resolution)
            let playbackURL = try await VideoPlaybackURLResolver.resolve(source.url)
            try Task.checkCancellation()
            let replacement = AVPlayer(url: playbackURL)
            if let position, position.isNumeric {
                _ = await replacement.seek(to: position, toleranceBefore: .zero, toleranceAfter: .zero)
            }
            try Task.checkCancellation()
            previousPlayer?.pause()
            previousPlayer?.replaceCurrentItem(with: nil)
            videoPlayer = replacement
            selectedResolution = source.resolution
            activeResolution = source.resolution
            if shouldPlay { replacement.play() }
        } catch is CancellationError {
            selectedResolution = previousResolution
        } catch {
            selectedResolution = previousResolution
            playbackError = error.localizedDescription
        }
        isSwitchingResolution = false
        resolutionTask = nil
    }

    @MainActor
    private func setSubscribed(_ subscribed: Bool) async {
        guard let library = model.videoLibrary,
              model.currentUserID != nil,
              let revision = model.confirmedAccountCredentialRevision,
              library.transport.credentialSnapshotValue().revision == revision
        else { return }
        isWriting = true
        mutationError = nil
        do {
            switch resource {
            case let .mv(id):
                try await library.setMVSubscribed(id, subscribed: subscribed, expectedCredentialRevision: revision)
            case let .video(id):
                try await library.setVideoSubscribed(id, subscribed: subscribed, expectedCredentialRevision: revision)
            }
            isSubscribed = subscribed
            model.videoSubscriptionDidChange(resource, subscribed: subscribed)
        } catch {
            mutationError = error.localizedDescription
        }
        isWriting = false
    }
}

private extension LiveVideoLibrary {
    func iosAddComment(
        to resource: CommentResource,
        content: String,
        expectedCredentialRevision: UInt64
    ) async throws {
        try await iosWriteComment(
            to: resource,
            action: "add",
            content: content,
            expectedCredentialRevision: expectedCredentialRevision
        )
    }

    func iosReply(
        to resource: CommentResource,
        commentID: Int64,
        content: String,
        expectedCredentialRevision: UInt64
    ) async throws {
        try await iosWriteComment(
            to: resource,
            action: "reply",
            commentID: commentID,
            content: content,
            expectedCredentialRevision: expectedCredentialRevision
        )
    }

    func iosDeleteComment(
        from resource: CommentResource,
        commentID: Int64,
        expectedCredentialRevision: UInt64
    ) async throws {
        try await iosWriteComment(
            to: resource,
            action: "delete",
            commentID: commentID,
            expectedCredentialRevision: expectedCredentialRevision
        )
    }

    func iosSetCommentLiked(
        on resource: CommentResource,
        commentID: Int64,
        liked: Bool,
        expectedCredentialRevision: UInt64
    ) async throws {
        guard commentID > 0 else { throw EAPIError.invalidPayload }
        _ = try await transport.requestCommentLike(
            threadID: resource.threadID(),
            commentID: commentID,
            liked: liked,
            expectedCredentialRevision: expectedCredentialRevision
        )
    }

    func iosReportComment(
        on resource: CommentResource,
        commentID: Int64,
        reason: String,
        expectedCredentialRevision: UInt64
    ) async throws {
        let reason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard commentID > 0, !reason.isEmpty else { throw EAPIError.invalidPayload }
        _ = try await transport.requestJSONObject(
            EAPIEndpoint(
                "/eapi/report/reportcomment",
                signing: "/api/report/reportcomment",
                host: "https://interface.music.163.com"
            ),
            json: compactJSON([
                "threadId": try resource.threadID(),
                "commentId": String(commentID),
                "reason": reason
            ]),
            expectedCredentialRevision: expectedCredentialRevision,
            invalidatesGroups: [.comments],
            retryable: false
        )
    }

    func iosWriteComment(
        to resource: CommentResource,
        action: String,
        commentID: Int64? = nil,
        content: String? = nil,
        expectedCredentialRevision: UInt64
    ) async throws {
        let content = content?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard ["add", "reply", "delete"].contains(action),
              action == "delete" || content?.isEmpty == false,
              action == "add" || (commentID ?? 0) > 0
        else { throw EAPIError.invalidPayload }
        var payload: [String: Any] = ["threadId": try resource.threadID()]
        if let commentID { payload["commentId"] = String(commentID) }
        if let content { payload["content"] = content }
        _ = try await transport.requestJSONObject(
            EAPIEndpoint(
                "/eapi/resource/comments/\(action)",
                signing: "/api/resource/comments/\(action)",
                host: "https://interface.music.163.com"
            ),
            json: compactJSON(payload),
            expectedCredentialRevision: expectedCredentialRevision,
            invalidatesGroups: [.comments],
            retryable: false
        )
    }
}

private struct IOSMVKnowledgeSection: View {
    let mvID: Int64
    @Bindable var model: AppModel
    @State private var blocks: [MusicKnowledgeBlock] = []
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        Section("MV 百科") {
            if isLoading {
                HStack { ProgressView(); Text("正在载入百科").foregroundStyle(.secondary) }
            } else if let errorMessage {
                IOSInlineRetry(message: errorMessage) { Task { await load() } }
            } else if blocks.isEmpty {
                IOSLibraryEmptyRow(title: "暂无 MV 百科", symbol: "text.book.closed")
            } else {
                ForEach(blocks) { block in
                    IOSKnowledgeBlockRow(block: block)
                }
            }
        }
        .task(id: mvID) { await load() }
    }

    @MainActor
    private func load() async {
        guard let library = model.knowledgeLibrary else {
            isLoading = false
            errorMessage = "音乐百科服务不可用"
            return
        }
        isLoading = true
        errorMessage = nil
        do { blocks = try await library.knowledge(for: .mv(mvID)) }
        catch is CancellationError {}
        catch { errorMessage = error.localizedDescription }
        isLoading = false
    }
}

private struct IOSVideoCommentsSection: View {
    let resource: CommentResource
    let library: LiveVideoLibrary
    @Bindable var model: AppModel
    @State private var comments: [MusicComment] = []
    @State private var emojiPictureIDs: [String: String] = [:]
    @State private var totalCount = 0
    @State private var nextOffset = 0
    @State private var beforeTime: Int64 = 0
    @State private var hasMore = false
    @State private var text = ""
    @State private var isLoading = false
    @State private var isWriting = false
    @State private var mutatingCommentID: Int64?
    @State private var loadGeneration = 0
    @State private var loadError: String?
    @State private var mutationMessage: String?
    @State private var replyingTo: MusicComment?
    @State private var deleting: MusicComment?
    @State private var reporting: MusicComment?

    var body: some View {
        Group {
            Section("发表评论") {
                TextField("评论内容", text: $text, axis: .vertical)
                    .lineLimit(1...4)
                    .disabled(revision == nil || isWriting)
                Button { Task { await submit() } } label: {
                    if isWriting { HStack { ProgressView(); Text("正在发表") } }
                    else { Label("发表", systemImage: "paperplane.fill") }
                }
                .disabled(revision == nil || isWriting || trimmedText.isEmpty)
                if revision == nil {
                    Text("登录后可发表评论和参与互动。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                if isLoading && comments.isEmpty {
                    HStack { ProgressView(); Text("正在载入评论").foregroundStyle(.secondary) }
                } else if comments.isEmpty, let loadError {
                    IOSInlineRetry(message: loadError) { Task { await load(reset: true) } }
                } else if comments.isEmpty {
                    IOSLibraryEmptyRow(title: "暂无评论", symbol: "bubble.left")
                } else {
                    ForEach(comments) { comment in
                        IOSVideoCommentRow(
                            comment: comment,
                            emojiPictureIDs: emojiPictureIDs,
                            canMutate: revision != nil,
                            isMutating: mutatingCommentID == comment.id,
                            isMine: comment.userID == model.currentUserID,
                            openUser: { model.open(.user(comment.userID)) },
                            like: { Task { await setLiked(comment, liked: !comment.isLiked) } },
                            reply: { replyingTo = comment },
                            delete: { deleting = comment },
                            report: { reporting = comment }
                        )
                    }
                    if let loadError {
                        IOSInlineRetry(message: loadError) { Task { await load(reset: false) } }
                    } else if hasMore {
                        Button("载入更多") { Task { await load(reset: false) } }
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .disabled(isLoading)
                    }
                }
            } header: {
                Text(totalCount > 0 ? "评论 \(totalCount.formatted())" : "评论")
            }
        }
        .task(id: resource) {
            await load(reset: true)
            emojiPictureIDs = (try? await library.commentEmojiPictureIDs()) ?? [:]
        }
        .sheet(item: $replyingTo) { comment in
            IOSVideoCommentReplySheet(comment: comment) { content in
                try await reply(to: comment, content: content)
            }
        }
        .sheet(item: $reporting) { comment in
            IOSVideoCommentReportSheet(comment: comment) { reason in
                try await report(comment, reason: reason)
            }
        }
        .confirmationDialog("删除评论？", isPresented: Binding(
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
        .alert("评论操作", isPresented: Binding(
            get: { mutationMessage != nil },
            set: { if !$0 { mutationMessage = nil } }
        )) {
            Button("好") { mutationMessage = nil }
        } message: {
            Text(mutationMessage ?? "")
        }
    }

    private var trimmedText: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var revision: UInt64? {
        guard model.currentUserID != nil,
              let confirmed = model.confirmedAccountCredentialRevision,
              library.transport.credentialSnapshotValue().revision == confirmed
        else { return nil }
        return confirmed
    }

    @MainActor
    private func load(reset: Bool) async {
        guard reset || (!isLoading && hasMore) else { return }
        if reset {
            loadGeneration += 1
            comments = []
            totalCount = 0
            nextOffset = 0
            beforeTime = 0
            hasMore = false
        }
        let requestGeneration = loadGeneration
        let offset = reset ? 0 : nextOffset
        isLoading = true
        loadError = nil
        do {
            let page = try await library.comments(
                for: resource,
                offset: offset,
                limit: 20,
                beforeTime: offset >= 5_000 ? beforeTime : 0
            )
            try Task.checkCancellation()
            guard loadGeneration == requestGeneration else { return }
            var seen = Set(reset ? [] : comments.map(\.id))
            let additions = page.comments.filter { seen.insert($0.id).inserted }
            comments = reset ? additions : comments + additions
            totalCount = page.totalCount
            nextOffset = page.nextOffset
            beforeTime = page.beforeTime
            hasMore = page.hasMore && page.nextOffset > offset && !additions.isEmpty
        } catch is CancellationError {
        } catch {
            guard loadGeneration == requestGeneration else { return }
            loadError = error.localizedDescription
        }
        guard loadGeneration == requestGeneration else { return }
        isLoading = false
    }

    @MainActor
    private func submit() async {
        guard let revision, !trimmedText.isEmpty else { return }
        isWriting = true
        do {
            try await library.iosAddComment(
                to: resource,
                content: trimmedText,
                expectedCredentialRevision: revision
            )
            text = ""
            isWriting = false
            await load(reset: true)
        } catch {
            isWriting = false
            mutationMessage = error.localizedDescription
        }
    }

    @MainActor
    private func reply(to comment: MusicComment, content: String) async throws {
        guard let revision else { throw EAPIError.invalidPayload }
        try await library.iosReply(
            to: resource,
            commentID: comment.id,
            content: content,
            expectedCredentialRevision: revision
        )
        await load(reset: true)
    }

    @MainActor
    private func delete(_ comment: MusicComment) async {
        defer { deleting = nil; mutatingCommentID = nil }
        guard let revision, comment.userID == model.currentUserID else { return }
        mutatingCommentID = comment.id
        do {
            try await library.iosDeleteComment(
                from: resource,
                commentID: comment.id,
                expectedCredentialRevision: revision
            )
            await load(reset: true)
        } catch { mutationMessage = error.localizedDescription }
    }

    @MainActor
    private func setLiked(_ comment: MusicComment, liked: Bool) async {
        guard let revision, mutatingCommentID == nil else { return }
        mutatingCommentID = comment.id
        do {
            try await library.iosSetCommentLiked(
                on: resource,
                commentID: comment.id,
                liked: liked,
                expectedCredentialRevision: revision
            )
            comments = comments.map { $0.id == comment.id ? $0.settingLiked(liked) : $0 }
        } catch { mutationMessage = error.localizedDescription }
        mutatingCommentID = nil
    }

    @MainActor
    private func report(_ comment: MusicComment, reason: String) async throws {
        guard let revision, comment.userID != model.currentUserID else { throw EAPIError.invalidPayload }
        try await library.iosReportComment(
            on: resource,
            commentID: comment.id,
            reason: reason,
            expectedCredentialRevision: revision
        )
        mutationMessage = "已提交举报。"
    }
}

private struct IOSVideoCommentRow: View {
    let comment: MusicComment
    let emojiPictureIDs: [String: String]
    let canMutate: Bool
    let isMutating: Bool
    let isMine: Bool
    let openUser: () -> Void
    let like: () -> Void
    let reply: () -> Void
    let delete: () -> Void
    let report: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: openUser) {
                Text(comment.nickname).font(.subheadline.weight(.semibold))
            }
            .buttonStyle(.plain)
            IOSCommentEmojiText(content: comment.displayContent, remotePictureIDs: emojiPictureIDs)
            HStack(spacing: 8) {
                Text(comment.timeText).font(.caption).foregroundStyle(.secondary)
                if comment.replyCount > 0 {
                    Text("\(comment.replyCount.formatted()) 条回复")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: like) {
                    Label(
                        comment.likedCount.formatted(),
                        systemImage: comment.isLiked ? "hand.thumbsup.fill" : "hand.thumbsup"
                    )
                    .frame(minHeight: 44)
                }
                .buttonStyle(.plain)
                .disabled(!canMutate || isMutating)
                Menu {
                    Button("回复", systemImage: "arrowshape.turn.up.left", action: reply)
                    if isMine {
                        Button("删除", systemImage: "trash", role: .destructive, action: delete)
                    } else {
                        Button("举报", systemImage: "exclamationmark.bubble", action: report)
                    }
                } label: {
                    Image(systemName: "ellipsis").frame(width: 44, height: 44)
                }
                .disabled(!canMutate || isMutating)
                .accessibilityLabel("评论操作")
            }
        }
        .padding(.vertical, 5)
    }
}

private struct IOSVideoCommentReplySheet: View {
    @Environment(\.dismiss) private var dismiss
    let comment: MusicComment
    let submit: (String) async throws -> Void
    @State private var text = ""
    @State private var isSubmitting = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("回复 \(comment.nickname)") {
                    IOSCommentEmojiText(content: comment.displayContent, remotePictureIDs: [:])
                    TextField("回复内容", text: $text, axis: .vertical).lineLimit(2...6)
                }
                if let errorMessage { Section { Text(errorMessage).foregroundStyle(.red) } }
            }
            .navigationTitle("回复评论")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("发送") { Task { await send() } }
                        .disabled(isSubmitting || trimmedText.isEmpty)
                }
            }
        }
    }

    private var trimmedText: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    @MainActor
    private func send() async {
        isSubmitting = true
        do {
            try await submit(trimmedText)
            dismiss()
        } catch { errorMessage = error.localizedDescription }
        isSubmitting = false
    }
}

private enum IOSCommentReportReason: String, CaseIterable, Identifiable {
    case spam = "垃圾广告"
    case abuse = "人身攻击"
    case illegal = "违法违规"
    case other = "其他"
    var id: Self { self }
}

private struct IOSVideoCommentReportSheet: View {
    @Environment(\.dismiss) private var dismiss
    let comment: MusicComment
    let submit: (String) async throws -> Void
    @State private var selectedReason = IOSCommentReportReason.spam
    @State private var customReason = ""
    @State private var isSubmitting = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("举报 \(comment.nickname) 的评论") {
                    Picker("原因", selection: $selectedReason) {
                        ForEach(IOSCommentReportReason.allCases) { Text($0.rawValue).tag($0) }
                    }
                    if selectedReason == .other {
                        TextField("具体原因", text: $customReason, axis: .vertical).lineLimit(2...5)
                    }
                }
                if let errorMessage { Section { Text(errorMessage).foregroundStyle(.red) } }
            }
            .navigationTitle("举报评论")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("提交") { Task { await send() } }
                        .disabled(isSubmitting || resolvedReason.isEmpty)
                }
            }
        }
    }

    private var resolvedReason: String {
        selectedReason == .other
            ? customReason.trimmingCharacters(in: .whitespacesAndNewlines)
            : selectedReason.rawValue
    }

    @MainActor
    private func send() async {
        isSubmitting = true
        do {
            try await submit(resolvedReason)
            dismiss()
        } catch { errorMessage = error.localizedDescription }
        isSubmitting = false
    }
}

private enum IOSCommentEmojiPart: Equatable {
    case text(String)
    case emoji(token: String, url: URL)
}

private enum IOSCommentEmojiCatalog {
    static func parts(in text: String, remotePictureIDs: [String: String]) -> [IOSCommentEmojiPart] {
        var parts: [IOSCommentEmojiPart] = []
        var plainStart = text.startIndex
        var searchStart = text.startIndex
        while searchStart < text.endIndex,
              let open = text[searchStart...].firstIndex(of: "["),
              let close = text[open...].firstIndex(of: "]") {
            let tokenEnd = text.index(after: close)
            let token = String(text[open..<tokenEnd])
            guard let url = imageURL(for: token, remotePictureIDs: remotePictureIDs) else {
                searchStart = text.index(after: open)
                continue
            }
            if plainStart < open { parts.append(.text(String(text[plainStart..<open]))) }
            parts.append(.emoji(token: token, url: url))
            plainStart = tokenEnd
            searchStart = tokenEnd
        }
        if plainStart < text.endIndex { parts.append(.text(String(text[plainStart...]))) }
        return parts
    }

    private static func imageURL(for token: String, remotePictureIDs: [String: String]) -> URL? {
        guard let pictureID = remotePictureIDs[token] ?? fallbackPictureIDs[token] else { return nil }
        let key = Array("3go8&$8*3*3h0k(2)2".utf8)
        let bytes = pictureID.utf8.enumerated().map { $0.element ^ key[$0.offset % key.count] }
        let encryptedID = Data(Insecure.MD5.hash(data: Data(bytes))).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
        return URL(string: "https://p1.music.126.net/\(encryptedID)/\(pictureID).jpg")
    }

    private static let fallbackPictureIDs = [
        "[大笑]": "109951163626288227",
        "[可爱]": "109951163626292590",
        "[憨笑]": "109951163626287772",
        "[色]": "109951163626282488",
        "[亲亲]": "109951163626285344",
        "[惊恐]": "109951163626283490",
        "[流泪]": "109951163626284414",
        "[亲]": "109951163626290631",
        "[呆]": "109951163626287355",
        "[哀伤]": "109951163626285834",
        "[呲牙]": "109951163626292580",
        "[吐舌]": "109951163626283909",
        "[撇嘴]": "109951163626290628",
        "[怒]": "109951163626282485",
        "[奸笑]": "109951163626294536",
        "[汗]": "109951163626295545",
        "[痛苦]": "109951163626281966",
        "[惶恐]": "109951163626285341",
        "[生病]": "109951163626293558",
        "[口罩]": "109951163626288731",
        "[大哭]": "109951163626286820",
        "[晕]": "109951163626293560",
        "[发怒]": "109951163626288724",
        "[开心]": "109951163626291598",
        "[鬼脸]": "109951163626291602",
        "[皱眉]": "109951163626281977",
        "[流感]": "109951163626284872",
        "[爱心]": "109951163626286814",
        "[心碎]": "109951163626285338",
        "[钟情]": "109951163626295031",
        "[星星]": "109951163626284864",
        "[生气]": "109951163626290124",
        "[便便]": "109951163626287776",
        "[强]": "109951163626289189",
        "[弱]": "109951163626289199",
        "[拜]": "109951163626288212",
        "[牵手]": "109951163626289693",
        "[跳舞]": "109951163626292089",
        "[禁止]": "109951163626293561",
        "[这边]": "109951163626291590",
        "[爱意]": "109951163626292575",
        "[示爱]": "109951163626284417",
        "[嘴唇]": "109951163626283914",
        "[狗]": "109951163626291126",
        "[猫]": "109951163626283916",
        "[猪]": "109951163626294532",
        "[兔子]": "109951163626290633",
        "[小鸡]": "109951163626294542",
        "[公鸡]": "109951163626294064",
        "[幽灵]": "109951163626294055",
        "[圣诞]": "109951163626287360",
        "[外星]": "109951163626285830",
        "[钻石]": "109951163626295544",
        "[礼物]": "109951163626289683",
        "[男孩]": "109951163626290620",
        "[女孩]": "109951163626294052",
        "[蛋糕]": "109951163626292081",
        "[18]": "109951163626287765",
        "[圈]": "109951163626290623",
        "[叉]": "109951163626286350",
        "[多多大笑]": "109951163626285326",
        "[多多耍酷]": "109951163626286808",
        "[多多比耶]": "109951163626291112",
        "[多多大哭]": "109951163626288209",
        "[多多瞌睡]": "109951163626285332",
        "[多多难过]": "109951163626282475",
        "[多多笑哭]": "109951163626295026",
        "[多多可怜]": "109951163626289680",
        "[多多无语]": "109951163626291589",
        "[多多捂脸]": "109951163626287335",
        "[多多亲吻]": "109951163626285824",
        "[多多调皮]": "109951163626288207",
        "[西西心动]": "109951163626284860",
        "[西西发怒]": "109951163626291586",
        "[西西惊讶]": "109951163626290613",
        "[西西奸笑]": "109951163626285329",
        "[西西晕了]": "109951163626294527",
        "[西西机智]": "109951163626295022",
        "[西西惊吓]": "109951163626292571",
        "[西西流汗]": "109951163626281959",
        "[西西呕吐]": "109951163626287760",
        "[西西再见]": "109951163626290116",
        "[西西疑问]": "109951163626285827"
    ]
}

@MainActor
private struct IOSCommentEmojiText: View {
    let content: String
    private let parts: [IOSCommentEmojiPart]
    @Environment(\.displayScale) private var displayScale
    @State private var images: [String: UIImage] = [:]

    init(content: String, remotePictureIDs: [String: String]) {
        self.content = content
        parts = IOSCommentEmojiCatalog.parts(in: content, remotePictureIDs: remotePictureIDs)
    }

    var body: some View {
        renderedText
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
            .accessibilityLabel(Text(content))
            .task(id: parts) { await loadImages() }
    }

    private var renderedText: Text {
        parts.reduce(Text("")) { result, part in
            switch part {
            case let .text(text):
                result + Text(text)
            case let .emoji(token, _):
                if let image = images[token] {
                    result + Text(Image(uiImage: image)).baselineOffset(-3)
                } else {
                    result + Text(token)
                }
            }
        }
    }

    private func loadImages() async {
        var loaded: [String: UIImage] = [:]
        for case let .emoji(token, url) in parts where loaded[token] == nil {
            guard let request = ArtworkPipeline.request(
                for: url,
                size: CGSize(width: 20, height: 20),
                displayScale: displayScale
            ) else { continue }
            do {
                let source = try await ArtworkPipeline.shared.loadImage(for: request)
                try Task.checkCancellation()
                loaded[token] = UIGraphicsImageRenderer(size: CGSize(width: 18, height: 18)).image { _ in
                    source.draw(in: CGRect(x: 0, y: 0, width: 18, height: 18))
                }
            } catch is CancellationError {
                return
            } catch {
                continue
            }
        }
        guard !Task.isCancelled else { return }
        images = loaded
    }
}

private enum IOSAudioSection: String, CaseIterable, Identifiable {
    case podcasts = "播客"
    case broadcasts = "广播"
    var id: Self { self }
}

private struct IOSAudioDiscoveryView: View {
    @Bindable var model: AppModel
    @State private var section = IOSAudioSection.podcasts
    @State private var categories: [PodcastCategory] = []
    @State private var selectedCategoryID: Int64?
    @State private var podcasts: [Podcast] = []
    @State private var filters: BroadcastFilters?
    @State private var categoryID = "0"
    @State private var regionID = "0"
    @State private var channels: [BroadcastChannel] = []
    @State private var channelPage: BroadcastChannelPage?
    @State private var isLoading = true
    @State private var isLoadingMore = false
    @State private var errorMessage: String?
    @State private var loadGeneration = 0

    var body: some View {
        VStack(spacing: 0) {
            Picker("声音内容", selection: $section) {
                ForEach(IOSAudioSection.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding()
            Divider()
            if section == .podcasts { podcastContent } else { broadcastContent }
        }
        .navigationTitle("播客与广播")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: section.rawValue) { await load() }
    }

    @ViewBuilder
    private var podcastContent: some View {
        if isLoading && podcasts.isEmpty {
            IOSLibraryLoadingView(title: "正在载入播客")
        } else if let errorMessage, podcasts.isEmpty {
            IOSLibraryFailureView(title: "无法载入播客", message: errorMessage) { Task { await load() } }
        } else {
            List {
                Section {
                    Picker("分类", selection: $selectedCategoryID) {
                        ForEach(categories) { Text($0.name).tag(Optional($0.id)) }
                    }
                    .onChange(of: selectedCategoryID) { oldValue, newValue in
                        guard oldValue != nil, oldValue != newValue else { return }
                        Task { await loadPodcasts() }
                    }
                }
                Section(selectedCategory?.name ?? "推荐播客") {
                    if podcasts.isEmpty {
                        IOSLibraryEmptyRow(title: "暂无推荐播客", symbol: "dot.radiowaves.left.and.right")
                    } else {
                        ForEach(podcasts) { podcast in
                            NavigationLink(value: Route.podcast(podcast.id)) { IOSPodcastLabel(podcast: podcast) }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .refreshable { await loadPodcasts(force: true) }
        }
    }

    @ViewBuilder
    private var broadcastContent: some View {
        if isLoading && channels.isEmpty {
            IOSLibraryLoadingView(title: "正在载入广播")
        } else if let errorMessage, channels.isEmpty {
            IOSLibraryFailureView(title: "无法载入广播", message: errorMessage) { Task { await load() } }
        } else {
            List {
                if let filters {
                    Section("筛选") {
                        Picker("分类", selection: $categoryID) {
                            Text("全部").tag("0")
                            ForEach(filters.categories) { Text($0.name).tag($0.id) }
                        }
                        Picker("地区", selection: $regionID) {
                            Text("全部").tag("0")
                            ForEach(filters.regions) { Text($0.name).tag($0.id) }
                        }
                    }
                    .onChange(of: categoryID) { _, _ in Task { await loadChannels(reset: true) } }
                    .onChange(of: regionID) { _, _ in Task { await loadChannels(reset: true) } }
                }
                Section("频道") {
                    if channels.isEmpty {
                        IOSLibraryEmptyRow(title: "暂无广播频道", symbol: "radio")
                    } else {
                        ForEach(channels) { channel in
                            NavigationLink(value: Route.broadcast(channel.id, channel.coverURL)) {
                                IOSBroadcastLabel(channel: channel)
                            }
                        }
                        if channelPage?.hasMore == true {
                            Button("载入更多") { Task { await loadChannels(reset: false) } }
                                .frame(maxWidth: .infinity, minHeight: 44)
                                .disabled(isLoadingMore)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .refreshable { await loadChannels(reset: true) }
        }
    }

    @MainActor
    private func load() async {
        loadGeneration &+= 1
        let generation = loadGeneration
        let section = section
        isLoadingMore = false
        guard let library = model.audioLibrary else {
            isLoading = false
            errorMessage = "声音服务不可用"
            return
        }
        isLoading = true
        errorMessage = nil
        do {
            if section == .podcasts {
                let values = try await library.podcastCategories()
                try Task.checkCancellation()
                guard loadGeneration == generation, self.section == section else { return }
                categories = values
                if !values.contains(where: { $0.id == selectedCategoryID }) {
                    selectedCategoryID = values.first?.id
                }
                await loadPodcasts()
            } else {
                let value = try await library.broadcastFilters()
                try Task.checkCancellation()
                guard loadGeneration == generation, self.section == section else { return }
                filters = value
                await loadChannels(reset: true)
            }
        } catch is CancellationError {
        } catch {
            guard loadGeneration == generation, self.section == section else { return }
            isLoading = false
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func loadPodcasts(force: Bool = false) async {
        loadGeneration &+= 1
        let generation = loadGeneration
        let section = section
        guard section == .podcasts,
              let library = model.audioLibrary,
              let selectedCategory
        else {
            isLoading = false
            return
        }
        let categoryID = selectedCategory.id
        isLoading = true
        errorMessage = nil
        defer {
            if loadGeneration == generation,
               self.section == section,
               selectedCategoryID == categoryID {
                isLoading = false
            }
        }
        do {
            let values = try await library.recommendedPodcasts(categoryID: categoryID, refreshCache: force)
            try Task.checkCancellation()
            guard loadGeneration == generation,
                  self.section == section,
                  selectedCategoryID == categoryID
            else { return }
            podcasts = values
        } catch is CancellationError {
        } catch {
            guard loadGeneration == generation,
                  self.section == section,
                  selectedCategoryID == categoryID
            else { return }
            errorMessage = error.localizedDescription
        }
    }

    private var selectedCategory: PodcastCategory? {
        categories.first { $0.id == selectedCategoryID }
    }

    @MainActor
    private func loadChannels(reset: Bool) async {
        guard section == .broadcasts, let library = model.audioLibrary else { return }
        let categoryID = categoryID
        let regionID = regionID
        let currentPage: BroadcastChannelPage?
        if reset {
            loadGeneration &+= 1
            isLoading = true
            isLoadingMore = false
            currentPage = nil
        } else {
            guard !isLoading,
                  !isLoadingMore,
                  let page = channelPage,
                  page.hasMore
            else { return }
            isLoadingMore = true
            currentPage = page
        }
        let generation = loadGeneration
        errorMessage = nil
        defer {
            if loadGeneration == generation,
               section == .broadcasts,
               self.categoryID == categoryID,
               self.regionID == regionID {
                if reset { isLoading = false } else { isLoadingMore = false }
            }
        }
        do {
            let value = try await library.broadcastChannels(
                categoryID: categoryID,
                regionID: regionID,
                cursor: currentPage?.nextCursor ?? .initial
            )
            try Task.checkCancellation()
            guard loadGeneration == generation,
                  section == .broadcasts,
                  self.categoryID == categoryID,
                  self.regionID == regionID,
                  reset || channelPage?.nextCursor == currentPage?.nextCursor
            else { return }
            channelPage = currentPage?.appending(value) ?? value
            channels = channelPage?.channels ?? []
        } catch is CancellationError {
        } catch {
            guard loadGeneration == generation,
                  section == .broadcasts,
                  self.categoryID == categoryID,
                  self.regionID == regionID
            else { return }
            errorMessage = error.localizedDescription
        }
    }
}

struct IOSPodcastLabel: View {
    let podcast: Podcast
    var body: some View {
        HStack(spacing: 12) {
            IOSRemoteArtwork(url: podcast.coverURL, symbol: "dot.radiowaves.left.and.right")
                .frame(width: 52, height: 52)
            VStack(alignment: .leading, spacing: 3) {
                Text(podcast.name).lineLimit(2)
                Text([podcast.hostName, podcast.categoryName].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .frame(minHeight: 60)
    }
}

private struct IOSBroadcastLabel: View {
    let channel: BroadcastChannel
    var body: some View {
        HStack(spacing: 12) {
            IOSRemoteArtwork(url: channel.coverURL, symbol: "radio")
                .frame(width: 52, height: 52)
            VStack(alignment: .leading, spacing: 3) {
                Text(channel.name).lineLimit(2)
                Text(channel.regionName).font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(minHeight: 60)
    }
}

private struct IOSPodcastDetailView: View {
    let podcastID: Int64
    @Bindable var model: AppModel
    @Bindable var player: PlayerController
    @State private var podcast: Podcast?
    @State private var page: PodcastEpisodePage?
    @State private var isSubscribed = false
    @State private var isLoading = true
    @State private var isLoadingMore = false
    @State private var isWriting = false
    @State private var loadMoreError: String?
    @State private var mutationError: String?
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if isLoading && podcast == nil {
                IOSLibraryLoadingView(title: "正在载入播客")
            } else if let errorMessage, podcast == nil {
                IOSLibraryFailureView(title: "无法载入播客", message: errorMessage) { Task { await load(force: true) } }
            } else if let podcast {
                List {
                    Section {
                        HStack(alignment: .top, spacing: 16) {
                            IOSRemoteArtwork(url: podcast.coverURL, symbol: "dot.radiowaves.left.and.right")
                                .frame(width: 112, height: 112)
                            VStack(alignment: .leading, spacing: 6) {
                                Text(podcast.name).font(.title3.weight(.semibold))
                                Text(podcast.hostName).foregroundStyle(.secondary)
                                Text("\(podcast.episodeCount.formatted()) 期 · \(podcast.categoryName)")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        if !podcast.description.isEmpty { Text(podcast.description).font(.subheadline) }
                        Button { Task { await subscribe(!isSubscribed) } } label: {
                            Label(isSubscribed ? "取消订阅" : "订阅", systemImage: isSubscribed ? "star.fill" : "star")
                        }
                        .disabled(model.currentUserID == nil || isWriting)
                    }
                    Section("节目") {
                        if page?.episodes.isEmpty != false {
                            IOSLibraryEmptyRow(title: "暂无节目", symbol: "waveform")
                        } else {
                            ForEach(page?.episodes ?? []) { episode in
                                NavigationLink(value: Route.podcastEpisode(episode.id)) {
                                    IOSEpisodeLabel(episode: episode)
                                }
                            }
                            if let loadMoreError {
                                IOSInlineRetry(message: loadMoreError) { Task { await loadMore() } }
                            } else if page?.hasMore == true {
                                Button("载入更多") { Task { await loadMore() } }
                                    .frame(maxWidth: .infinity, minHeight: 44)
                                    .disabled(isLoadingMore)
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .refreshable { await load(force: true) }
            }
        }
        .navigationTitle(podcast?.name ?? "播客")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: podcastID) { await load(force: false) }
        .alert("操作失败", isPresented: Binding(
            get: { mutationError != nil },
            set: { if !$0 { mutationError = nil } }
        )) {
            Button("好") { mutationError = nil }
        } message: {
            Text(mutationError ?? "")
        }
    }

    @MainActor
    private func load(force: Bool) async {
        guard let library = model.audioLibrary else {
            isLoading = false
            errorMessage = "播客服务不可用"
            return
        }
        loadMoreError = nil
        isLoading = true
        errorMessage = nil
        do {
            async let loadedPodcast = library.podcast(id: podcastID, refreshCache: force)
            async let loadedPage = library.podcastEpisodes(podcastID: podcastID, refreshCache: force)
            let (podcast, page) = try await (loadedPodcast, loadedPage)
            self.podcast = podcast
            self.page = page
            isSubscribed = model.podcastSubscriptionOverride(for: podcast.id) ?? podcast.isSubscribed
        } catch is CancellationError {
        } catch { errorMessage = error.localizedDescription }
        isLoading = false
    }

    @MainActor
    private func loadMore() async {
        guard let library = model.audioLibrary, let page, !isLoadingMore else { return }
        isLoadingMore = true
        loadMoreError = nil
        do {
            let next = try await library.podcastEpisodes(podcastID: podcastID, offset: page.nextOffset)
            self.page = page.appending(next)
        } catch is CancellationError {
        } catch { loadMoreError = error.localizedDescription }
        isLoadingMore = false
    }

    @MainActor
    private func subscribe(_ subscribed: Bool) async {
        guard let library = model.audioLibrary,
              let revision = model.confirmedAccountCredentialRevision,
              library.transport.credentialSnapshotValue().revision == revision
        else { return }
        isWriting = true
        mutationError = nil
        do {
            try await library.setPodcastSubscribed(
                podcastID,
                subscribed: subscribed,
                expectedCredentialRevision: revision
            )
            isSubscribed = subscribed
            model.commitPodcastSubscription(id: podcastID, subscribed: subscribed)
        } catch { mutationError = error.localizedDescription }
        isWriting = false
    }
}

private struct IOSEpisodeLabel: View {
    let episode: PodcastEpisode
    var body: some View {
        HStack(spacing: 12) {
            IOSRemoteArtwork(url: episode.coverURL, symbol: "waveform")
                .frame(width: 52, height: 52)
            VStack(alignment: .leading, spacing: 3) {
                Text(episode.title).lineLimit(2)
                Text([episode.publishedAt?.formatted(date: .abbreviated, time: .omitted), episode.durationText]
                    .compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(minHeight: 60)
    }
}

private enum IOSPodcastLyricsPhase: Equatable {
    case loading
    case loaded([LyricLine])
    case failed(String)
}

private struct IOSPodcastEpisodeView: View {
    let episodeID: Int64
    @Bindable var model: AppModel
    @Bindable var player: PlayerController
    @State private var episode: PodcastEpisode?
    @State private var lyricsPhase = IOSPodcastLyricsPhase.loading
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if isLoading {
                IOSLibraryLoadingView(title: "正在载入节目")
            } else if let errorMessage, episode == nil {
                IOSLibraryFailureView(title: "无法载入节目", message: errorMessage) { Task { await load() } }
            } else if let episode {
                List {
                    Section {
                        HStack(alignment: .top, spacing: 16) {
                            IOSRemoteArtwork(url: episode.coverURL, symbol: "waveform")
                                .frame(width: 112, height: 112)
                            VStack(alignment: .leading, spacing: 6) {
                                Text(episode.title).font(.title3.weight(.semibold))
                                Text([episode.podcastName, episode.hostName].filter { !$0.isEmpty }.joined(separator: " · "))
                                    .foregroundStyle(.secondary)
                                Text(episode.durationText).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        if let song = episode.song {
                            Button { player.play(song, in: [song]) } label: {
                                Label("播放节目", systemImage: "play.fill")
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.red)
                        } else if let reason = episode.unavailableReason {
                            Label(reason, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
                        }
                    }
                    if !episode.description.isEmpty {
                        Section("节目简介") { Text(episode.description).textSelection(.enabled) }
                    }
                    Section("节目文字") {
                        lyricsContent(songID: episode.song?.id)
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle("播客节目")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: episodeID) { await load() }
    }

    @ViewBuilder
    private func lyricsContent(songID: Int64?) -> some View {
        switch lyricsPhase {
        case .loading:
            HStack { ProgressView(); Text("正在载入歌词").foregroundStyle(.secondary) }
        case let .failed(message):
            IOSInlineRetry(message: message) { Task { await loadLyrics() } }
        case let .loaded(lines) where lines.isEmpty:
            IOSLibraryEmptyRow(title: "暂无歌词", symbol: "quote.bubble")
        case let .loaded(lines):
            let currentLineID = songID == player.currentSongID
                ? PodcastLyricLocator.currentLineID(
                    in: lines,
                    at: Int64(player.position * 1_000)
                )
                : nil
            ForEach(lines) { line in
                Button {
                    guard songID == player.currentSongID else { return }
                    player.seek(to: TimeInterval(line.timestampMilliseconds) / 1_000)
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(line.text)
                        if let translation = line.translation, !translation.isEmpty {
                            Text(translation).font(.caption)
                        }
                        if let romanization = line.romanization, !romanization.isEmpty {
                            Text(romanization).font(.caption2)
                        }
                    }
                    .fontWeight(currentLineID == line.id ? .semibold : .regular)
                    .foregroundStyle(currentLineID == line.id ? Color.red : Color.primary)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(currentLineID == line.id ? .isSelected : [])
            }
        }
    }

    @MainActor
    private func load() async {
        guard let library = model.audioLibrary else {
            isLoading = false
            errorMessage = "播客服务不可用"
            return
        }
        isLoading = true
        errorMessage = nil
        lyricsPhase = .loading
        do {
            let value = try await library.resolvedPodcastEpisode(id: episodeID)
            try Task.checkCancellation()
            episode = value
            isLoading = false
            await loadLyrics()
        } catch is CancellationError {
        } catch {
            errorMessage = error.localizedDescription
            isLoading = false
        }
    }

    @MainActor
    private func loadLyrics() async {
        guard let library = model.audioLibrary else {
            lyricsPhase = .failed("播客服务不可用")
            return
        }
        lyricsPhase = .loading
        do {
            let source = try await library.voiceLyrics(programID: episodeID)
            try Task.checkCancellation()
            lyricsPhase = .loaded(LRCParser.parse(source))
        } catch is CancellationError {
        } catch {
            lyricsPhase = .failed(error.localizedDescription)
        }
    }
}

private struct IOSPodcastSubscriptionsView: View {
    @Bindable var model: AppModel
    @State private var page: PodcastPage?
    @State private var isLoading = true
    @State private var isLoadingMore = false
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if model.currentUserID == nil {
                IOSLibraryEmptyState(title: "登录后查看订阅播客", symbol: "star")
            } else if isLoading && page == nil {
                IOSLibraryLoadingView(title: "正在载入订阅播客")
            } else if let errorMessage, page == nil {
                IOSLibraryFailureView(title: "无法载入订阅播客", message: errorMessage) { Task { await load(force: true) } }
            } else if displayedPodcasts.isEmpty {
                IOSLibraryEmptyState(title: "暂无订阅播客", symbol: "star")
            } else {
                List {
                    ForEach(displayedPodcasts) { podcast in
                        NavigationLink(value: Route.podcast(podcast.id)) { IOSPodcastLabel(podcast: podcast) }
                    }
                    if page?.hasMore == true {
                        Button("载入更多") { Task { await loadMore() } }
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .disabled(isLoadingMore)
                    }
                }
                .listStyle(.plain)
                .refreshable { await load(force: true) }
            }
        }
        .navigationTitle("订阅的播客")
        .task(id: "\(model.currentUserID ?? 0):\(revision):\(model.podcastSubscriptionRevision)") { await load(force: false) }
    }

    private var revision: UInt64 { model.audioLibrary?.transport.credentialSnapshotValue().revision ?? 0 }
    private var displayedPodcasts: [Podcast] {
        (page?.podcasts ?? []).compactMap { podcast in
            let subscribed = model.podcastSubscriptionOverride(for: podcast.id) ?? podcast.isSubscribed
            return subscribed ? podcast.settingSubscribed(true) : nil
        }
    }

    @MainActor
    private func load(force: Bool) async {
        guard let library = model.audioLibrary, model.currentUserID != nil else { return }
        isLoading = true
        errorMessage = nil
        do {
            page = try await library.subscribedPodcasts(
                refreshCache: force,
                expectedCredentialRevision: revision
            )
        } catch is CancellationError {
        } catch { errorMessage = error.localizedDescription }
        isLoading = false
    }

    @MainActor
    private func loadMore() async {
        guard let library = model.audioLibrary, let page, !isLoadingMore else { return }
        isLoadingMore = true
        do {
            let next = try await library.subscribedPodcasts(
                offset: page.nextOffset,
                expectedCredentialRevision: revision
            )
            self.page = page.appending(next)
        } catch { errorMessage = error.localizedDescription }
        isLoadingMore = false
    }
}

private struct IOSBroadcastDetailView: View {
    let channelID: String
    let coverURL: URL?
    @Bindable var model: AppModel
    @Bindable var songPlayer: PlayerController
    @State private var info: BroadcastCurrentInfo?
    @State private var streamPlayer: AVPlayer?
    @State private var playbackTask: Task<Void, Never>?
    @State private var playbackRequestID: UUID?
    @State private var isConnecting = false
    @State private var isWriting = false
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if let info {
                List {
                    Section {
                        HStack(alignment: .top, spacing: 16) {
                            IOSRemoteArtwork(url: coverURL ?? info.channel.coverURL, symbol: "radio")
                                .frame(width: 112, height: 112)
                            VStack(alignment: .leading, spacing: 6) {
                                Text(info.channel.name).font(.title3.weight(.semibold))
                                Text(info.channel.regionName).foregroundStyle(.secondary)
                                if !info.currentProgramTitle.isEmpty { Text(info.currentProgramTitle).font(.headline) }
                            }
                        }
                        if !info.currentProgramDescription.isEmpty { Text(info.currentProgramDescription) }
                        if !info.channel.description.isEmpty { Text(info.channel.description).font(.subheadline) }
                    }
                    Section("操作") {
                        Button { streamPlayer == nil ? startPlayback() : stopPlayback() } label: {
                            Label(
                                isConnecting ? "正在连接" : streamPlayer == nil ? "播放直播" : "停止播放",
                                systemImage: streamPlayer == nil ? "play.fill" : "stop.fill"
                            )
                        }
                        .disabled(isConnecting)
                        Button { Task { await collect(!isCollected) } } label: {
                            Label(isCollected ? "取消收藏" : "收藏", systemImage: isCollected ? "star.fill" : "star")
                        }
                        .disabled(model.currentUserID == nil || isWriting)
                    }
                    if let errorMessage {
                        Section { Label(errorMessage, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
                    }
                }
                .listStyle(.insetGrouped)
            } else if let errorMessage {
                IOSLibraryFailureView(title: "无法载入广播", message: errorMessage) { Task { await load() } }
            } else {
                IOSLibraryLoadingView(title: "正在载入广播")
            }
        }
        .navigationTitle(info?.channel.name ?? "广播")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: channelID) { await load() }
        .onDisappear { stopPlayback() }
    }

    private var isCollected: Bool {
        model.broadcastCollectionOverrides[channelID] ?? info?.channel.isCollected ?? false
    }

    @MainActor
    private func load() async {
        guard let library = model.audioLibrary else {
            errorMessage = "广播服务不可用"
            return
        }
        errorMessage = nil
        do {
            info = try await library.broadcastCurrentInfo(
                channelID: channelID,
                expectedCredentialRevision: model.currentUserID == nil ? nil : library.transport.credentialSnapshotValue().revision
            )
        } catch is CancellationError {
        } catch { errorMessage = error.localizedDescription }
    }

    private func startPlayback() {
        guard let library = model.audioLibrary else { return }
        playbackTask?.cancel()
        let requestID = UUID()
        playbackRequestID = requestID
        isConnecting = true
        errorMessage = nil
        playbackTask = Task { @MainActor in
            defer {
                if playbackRequestID == requestID {
                    playbackTask = nil
                    playbackRequestID = nil
                    isConnecting = false
                }
            }
            do {
                let current = try await library.broadcastCurrentInfo(channelID: channelID)
                try Task.checkCancellation()
                guard playbackRequestID == requestID else { throw CancellationError() }
                guard let source = current.streamURL else {
                    throw AudioContentError.unavailable("当前频道暂无可用直播流")
                }
                let url = try await BroadcastStreamURLPolicy.playableURL(source.absoluteString)
                try Task.checkCancellation()
                guard playbackRequestID == requestID else { throw CancellationError() }
                songPlayer.pauseForVideo()
                let player = AVPlayer(url: url)
                streamPlayer = player
                player.play()
                info = current
            } catch is CancellationError {
            } catch { errorMessage = error.localizedDescription }
        }
    }

    private func stopPlayback() {
        playbackRequestID = nil
        playbackTask?.cancel()
        playbackTask = nil
        streamPlayer?.pause()
        streamPlayer = nil
        isConnecting = false
    }

    @MainActor
    private func collect(_ collected: Bool) async {
        guard let library = model.audioLibrary,
              let revision = model.confirmedAccountCredentialRevision,
              library.transport.credentialSnapshotValue().revision == revision
        else { return }
        isWriting = true
        do {
            try await library.setBroadcastCollected(
                channelID,
                collected: collected,
                expectedCredentialRevision: revision
            )
            model.broadcastCollectionOverrides[channelID] = collected
        } catch { errorMessage = error.localizedDescription }
        isWriting = false
    }
}

private struct IOSPersonalFMView: View {
    @Bindable var model: AppModel
    @Bindable var player: PlayerController

    var body: some View {
        Group {
            if model.currentUserID == nil {
                IOSLibraryEmptyState(title: "登录后使用私人 FM", symbol: "radio")
            } else if let controller = model.personalFM {
                IOSPersonalFMContent(controller: controller, model: model, player: player)
            } else {
                IOSLibraryFailureView(title: "私人 FM 不可用", message: "推荐服务未初始化。") {}
            }
        }
        .navigationTitle("私人 FM")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct IOSPersonalFMContent: View {
    @Bindable var controller: PersonalFMController
    @Bindable var model: AppModel
    @Bindable var player: PlayerController

    var body: some View {
        let songs = controller.tracks.map(\.song)
        List {
            Section {
                Menu {
                    Button("默认推荐") { controller.selectMode(.standard) }
                    Button("熟悉歌曲") { controller.selectMode(.familiar) }
                    Button("探索新歌") { controller.selectMode(.explore) }
                    Divider()
                    ForEach(PersonalFMScene.allCases, id: \.rawValue) { scene in
                        Button(scene.title) { controller.selectMode(.scene(scene)) }
                    }
                } label: {
                    LabeledContent("推荐模式", value: controller.mode.title)
                }
            }
            if let track = controller.currentTrack {
                Section("正在推荐") {
                    HStack(spacing: 16) {
                        IOSArtworkView(artwork: track.song.album.artwork)
                            .frame(width: 112, height: 112)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(track.song.name).font(.title3.weight(.semibold)).lineLimit(3)
                            Text(track.song.artistsDisplay).foregroundStyle(.secondary)
                        }
                    }
                    HStack(spacing: 12) {
                        Button { player.previous() } label: { Image(systemName: "backward.fill").frame(width: 44, height: 44) }
                            .disabled(!player.canGoPrevious)
                        Button { player.togglePlayback() } label: {
                            Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").frame(width: 52, height: 52)
                        }
                        Button { player.next() } label: { Image(systemName: "forward.fill").frame(width: 44, height: 44) }
                            .disabled(!player.canGoNext)
                        Spacer()
                        Button(role: .destructive) { controller.trashCurrent() } label: {
                            Label("不再推荐", systemImage: "trash")
                        }
                        .disabled(controller.isTrashing)
                    }
                    .buttonStyle(.bordered)
                }
            }
            Section("队列") {
                if controller.tracks.isEmpty {
                    if controller.isLoading { HStack { ProgressView(); Text("正在获取推荐") } }
                    else { IOSLibraryEmptyRow(title: "暂无推荐歌曲", symbol: "radio") }
                } else {
                    ForEach(controller.tracks) { track in
                        IOSSongRow(
                            song: track.song,
                            songs: songs,
                            model: model,
                            player: player
                        )
                    }
                }
                if let message = controller.errorMessage {
                    IOSInlineRetry(message: message, action: controller.retryLoading)
                }
            }
        }
        .listStyle(.insetGrouped)
        .task {
            if let userID = model.currentUserID { controller.start(userID: userID) }
        }
    }
}

private struct IOSMusicStylesView: View {
    @Bindable var model: AppModel
    @State private var styles: [MusicStyle] = []
    @State private var preferred = Set<Int64>()
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if isLoading {
                IOSLibraryLoadingView(title: "正在载入曲风")
            } else if let errorMessage {
                IOSLibraryFailureView(title: "无法载入曲风", message: errorMessage) { Task { await load() } }
            } else if styles.isEmpty {
                IOSLibraryEmptyState(title: "暂无曲风", symbol: "guitars")
            } else {
                List {
                    ForEach(styles) { style in
                        Section {
                            NavigationLink(value: Route.musicStyle(style.id, style.name)) {
                                IOSStyleLabel(style: style, isPreferred: preferred.contains(style.id))
                            }
                            ForEach(style.children) { child in
                                NavigationLink(value: Route.musicStyle(child.id, child.name)) {
                                    IOSStyleLabel(style: child, isPreferred: preferred.contains(child.id))
                                }
                            }
                        } header: { Text(style.name) }
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle("曲风")
        .task(id: "\(model.currentUserID ?? 0):\(revision)") { await load() }
    }

    private var revision: UInt64 { model.knowledgeLibrary?.transport.credentialSnapshotValue().revision ?? 0 }

    @MainActor
    private func load() async {
        guard let library = model.knowledgeLibrary else {
            isLoading = false
            errorMessage = "曲风服务不可用"
            return
        }
        isLoading = true
        errorMessage = nil
        do {
            async let loadedStyles = library.styles()
            let loadedPreferred = model.currentUserID == nil
                ? []
                : (try? await library.preferredStyleIDs(expectedCredentialRevision: revision)) ?? []
            styles = try await loadedStyles
            preferred = Set(loadedPreferred)
        } catch is CancellationError {
        } catch { errorMessage = error.localizedDescription }
        isLoading = false
    }
}

private struct IOSStyleLabel: View {
    let style: MusicStyle
    let isPreferred: Bool
    var body: some View {
        HStack {
            Label(style.name, systemImage: "guitars")
            Spacer()
            if isPreferred {
                Image(systemName: "heart.fill").foregroundStyle(.red).accessibilityLabel("我的偏好")
            }
        }
        .frame(minHeight: 44)
    }
}

private struct IOSMusicStyleDetailView: View {
    let styleID: Int64
    let styleName: String
    @Bindable var model: AppModel
    @Bindable var player: PlayerController
    @State private var detail: MusicStyleDetail?
    @State private var kind = MusicStyleResourceKind.songs
    @State private var page: MusicStylePage?
    @State private var isLoading = true
    @State private var isLoadingMore = false
    @State private var errorMessage: String?
    @State private var loadGeneration = 0
    @State private var loadedStyleID: Int64?

    var body: some View {
        let items = page?.items ?? []
        let songs = items.compactMap { if case let .song(song) = $0 { song } else { nil } }
        VStack(spacing: 0) {
            Picker("内容类型", selection: $kind) {
                ForEach(MusicStyleResourceKind.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding()
            Divider()
            if isLoading && page == nil {
                IOSLibraryLoadingView(title: "正在载入\(kind.rawValue)")
            } else if let errorMessage, page == nil {
                IOSLibraryFailureView(title: "无法载入\(kind.rawValue)", message: errorMessage) { Task { await load() } }
            } else if page?.items.isEmpty != false {
                IOSLibraryEmptyState(title: "暂无\(kind.rawValue)", symbol: kind.symbol)
            } else {
                List {
                    if let detail, !detail.description.isEmpty {
                        Section("曲风简介") { Text(detail.description).textSelection(.enabled) }
                    }
                    Section(kind.rawValue) {
                        ForEach(items) { item in resourceRow(item, songs: songs) }
                        if let errorMessage {
                            IOSInlineRetry(message: errorMessage) {
                                Task { await loadMore() }
                            }
                        } else if page?.nextCursor != nil {
                            Button("载入更多") { Task { await loadMore() } }
                                .frame(maxWidth: .infinity, minHeight: 44)
                                .disabled(isLoadingMore)
                        }
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle(detail?.name ?? styleName)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: "\(styleID):\(kind.rawValue)") { await load() }
    }

    @ViewBuilder
    private func resourceRow(_ item: MusicStyleResource, songs: [Song]) -> some View {
        switch item {
        case let .song(song):
            IOSSongRow(
                song: song,
                songs: songs,
                model: model,
                player: player
            )
        case let .album(album):
            NavigationLink(value: Route.album(album.id)) {
                IOSMediaListLabel(title: album.name, subtitle: album.artist.name, artwork: album.artwork)
            }
        case let .artist(artist):
            NavigationLink(value: Route.artist(artist.id)) {
                IOSMediaListLabel(title: artist.name, subtitle: "歌手", artwork: artist.artwork)
            }
        case let .playlist(playlist):
            NavigationLink(value: Route.playlist(playlist.id)) {
                IOSMediaListLabel(title: playlist.name, subtitle: playlist.creator, artwork: playlist.artwork)
            }
        }
    }

    @MainActor
    private func load() async {
        loadGeneration &+= 1
        let generation = loadGeneration
        let requestedStyleID = styleID
        let requestedKind = kind
        guard let library = model.knowledgeLibrary else {
            isLoading = false
            errorMessage = "曲风服务不可用"
            return
        }
        isLoading = true
        isLoadingMore = false
        page = nil
        errorMessage = nil
        defer {
            if loadGeneration == generation,
               styleID == requestedStyleID,
               kind == requestedKind {
                isLoading = false
            }
        }
        do {
            async let loadedPage = library.stylePage(id: requestedStyleID, kind: requestedKind)
            let loadedDetail = if loadedStyleID == requestedStyleID, let detail {
                detail
            } else {
                try await library.styleDetail(id: requestedStyleID, name: styleName)
            }
            let nextPage = try await loadedPage
            try Task.checkCancellation()
            guard loadGeneration == generation,
                  styleID == requestedStyleID,
                  kind == requestedKind
            else { return }
            detail = loadedDetail
            loadedStyleID = requestedStyleID
            page = nextPage
        } catch is CancellationError {
        } catch {
            guard loadGeneration == generation,
                  styleID == requestedStyleID,
                  kind == requestedKind
            else { return }
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func loadMore() async {
        guard let library = model.knowledgeLibrary,
              let page,
              let cursor = page.nextCursor,
              !isLoading,
              !isLoadingMore
        else { return }
        let generation = loadGeneration
        let requestedStyleID = styleID
        let requestedKind = kind
        isLoadingMore = true
        errorMessage = nil
        defer {
            if loadGeneration == generation,
               styleID == requestedStyleID,
               kind == requestedKind {
                isLoadingMore = false
            }
        }
        do {
            let next = try await library.stylePage(
                id: requestedStyleID,
                kind: requestedKind,
                cursor: cursor
            )
            try Task.checkCancellation()
            guard loadGeneration == generation,
                  styleID == requestedStyleID,
                  kind == requestedKind,
                  self.page?.nextCursor == cursor
            else { return }
            self.page = page.appending(next)
        } catch is CancellationError {
        } catch {
            guard loadGeneration == generation,
                  styleID == requestedStyleID,
                  kind == requestedKind
            else { return }
            errorMessage = error.localizedDescription
        }
    }
}

private struct IOSMusicKnowledgeView: View {
    let song: Song
    @Bindable var model: AppModel
    @State private var blocks: [MusicKnowledgeBlock] = []
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if isLoading {
                IOSLibraryLoadingView(title: "正在载入歌曲百科")
            } else if let errorMessage {
                IOSLibraryFailureView(title: "无法载入歌曲百科", message: errorMessage) { Task { await load() } }
            } else if blocks.isEmpty {
                IOSLibraryEmptyState(title: "暂无歌曲百科", symbol: "text.book.closed")
            } else {
                List(blocks) { block in IOSKnowledgeBlockRow(block: block) }
                    .listStyle(.insetGrouped)
            }
        }
        .navigationTitle(song.primaryName)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: song.id) { await load() }
    }

    @MainActor
    private func load() async {
        guard let library = model.knowledgeLibrary else {
            isLoading = false
            errorMessage = "音乐百科服务不可用"
            return
        }
        isLoading = true
        errorMessage = nil
        do { blocks = try await library.knowledge(for: .song(song.id)) }
        catch is CancellationError {}
        catch { errorMessage = error.localizedDescription }
        isLoading = false
    }
}

private struct IOSKnowledgeBlockRow: View {
    let block: MusicKnowledgeBlock

    @ViewBuilder
    var body: some View {
        switch block {
        case let .text(_, title, body):
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.headline)
                Text(body).textSelection(.enabled)
            }
        case let .metric(_, title, value):
            LabeledContent(title, value: value)
        case let .image(_, url, caption):
            IOSKnowledgeImageBlock(url: url, caption: caption)
        case let .resource(_, title, route):
            NavigationLink(value: route) { Label(title, systemImage: "arrow.up.right.square") }
        }
    }
}

private struct IOSKnowledgeImageBlock: View {
    let url: URL
    let caption: String
    @State private var isPreparingShare = false
    @State private var shareItem: IOSLocalShareItem?
    @State private var exportError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            IOSRemoteArtwork(url: url, symbol: "photo").frame(maxWidth: 320)
            if !caption.isEmpty { Text(caption).font(.caption).foregroundStyle(.secondary) }
            Button { Task { await shareImage() } } label: {
                if isPreparingShare {
                    HStack { ProgressView(); Text("正在准备图片") }
                } else {
                    Label("分享或存入文件", systemImage: "square.and.arrow.up")
                }
            }
            .disabled(isPreparingShare)
            if let exportError {
                Text(exportError).font(.caption).foregroundStyle(.red)
            }
        }
        .sheet(item: $shareItem) { item in IOSActivityView(url: item.url) }
    }

    @MainActor
    private func shareImage() async {
        isPreparingShare = true
        exportError = nil
        do {
            let data = try await ArtworkPipeline.shared.loadData(for: url)
            let localURL = try await IOSExportFileStore.image(data: data, sourceURL: url)
            shareItem = IOSLocalShareItem(url: localURL)
        } catch is CancellationError {
        } catch { exportError = error.localizedDescription }
        isPreparingShare = false
    }
}

private struct IOSMusicSheetsView: View {
    let song: Song
    @Bindable var model: AppModel
    @State private var sheets: [MusicSheetSummary] = []
    @State private var selected: MusicSheetSummary?
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if isLoading {
                IOSLibraryLoadingView(title: "正在载入乐谱")
            } else if let errorMessage {
                IOSLibraryFailureView(title: "无法载入乐谱", message: errorMessage) { Task { await load() } }
            } else if sheets.isEmpty {
                IOSLibraryEmptyState(title: "暂无乐谱", symbol: "music.quarternote.3")
            } else {
                List(sheets) { sheet in
                    Button { selected = sheet } label: {
                        LabeledContent {
                            Text([sheet.instrument, sheet.pageCount.map { "\($0) 页" }].compactMap { $0 }.joined(separator: " · "))
                                .foregroundStyle(.secondary)
                        } label: {
                            Label(sheet.title, systemImage: "music.quarternote.3")
                        }
                    }
                    .buttonStyle(.plain)
                    .frame(minHeight: 52)
                }
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle("乐谱")
        .task(id: song.id) { await load() }
        .sheet(item: $selected) { sheet in
            IOSMusicSheetPreview(song: song, sheet: sheet, model: model)
        }
    }

    @MainActor
    private func load() async {
        guard let library = model.knowledgeLibrary else {
            isLoading = false
            errorMessage = "乐谱服务不可用"
            return
        }
        isLoading = true
        do { sheets = try await library.sheets(songID: song.id) }
        catch is CancellationError {}
        catch { errorMessage = error.localizedDescription }
        isLoading = false
    }
}

private struct IOSMusicSheetPreview: View {
    @Environment(\.dismiss) private var dismiss
    let song: Song
    let sheet: MusicSheetSummary
    @Bindable var model: AppModel
    @State private var pdfURL: URL?
    @State private var isLoading = true
    @State private var isSaving = false
    @State private var shareItem: IOSLocalShareItem?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    IOSLibraryLoadingView(title: "正在准备乐谱")
                } else if let errorMessage {
                    IOSLibraryFailureView(title: "无法打开乐谱", message: errorMessage) { Task { await load() } }
                } else if let pdfURL {
                    IOSPDFView(url: pdfURL)
                } else {
                    IOSLibraryEmptyState(title: "此乐谱不支持预览", symbol: "doc.questionmark")
                }
            }
            .navigationTitle(sheet.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } }
                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        if let pdfURL { shareItem = IOSLocalShareItem(url: pdfURL) }
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .accessibilityLabel("分享或存入文件")
                    .disabled(pdfURL == nil || isSaving)
                    Button { Task { await savePDF() } } label: {
                        if isSaving { ProgressView() } else { Image(systemName: "arrow.down.circle") }
                    }
                    .accessibilityLabel("保存乐谱")
                    .disabled(pdfURL == nil || isSaving)
                }
            }
        }
        .task(id: sheet.id) { await load() }
        .sheet(item: $shareItem) { item in IOSActivityView(url: item.url) }
    }

    @MainActor
    private func load() async {
        guard let library = model.knowledgeLibrary else { return }
        isLoading = true
        errorMessage = nil
        pdfURL = nil
        do {
            let value = try await library.sheetPreview(id: sheet.id)
            switch value {
            case .images, .pdf:
                pdfURL = try await MusicSheetWorker.shared.preparePDF(
                    sheetID: sheet.id,
                    preview: value,
                    cacheRoot: model.cacheFolderURL
                )
            case .unsupported:
                break
            }
        } catch is CancellationError {
        } catch { errorMessage = error.localizedDescription }
        isLoading = false
    }

    @MainActor
    private func savePDF() async {
        guard let pdfURL else { return }
        isSaving = true
        do {
            _ = try await MusicSheetWorker.shared.savePDF(
                at: pdfURL,
                song: song,
                sheet: sheet,
                to: model.sheetFolderURL
            )
            model.showToast("乐谱已保存")
        } catch { errorMessage = error.localizedDescription }
        isSaving = false
    }
}

private struct IOSLocalShareItem: Identifiable {
    let id = UUID()
    let url: URL
}

private struct IOSActivityView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

private enum IOSExportFileStore {
    static func image(data: Data, sourceURL: URL) async throws -> URL {
        try await Task.detached(priority: .utility) {
            let directory = FileManager.default.temporaryDirectory
                .appending(path: "TinyCloudMusicExports", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            let digest = SHA256.hash(data: Data(sourceURL.absoluteString.utf8))
                .map { String(format: "%02x", $0) }
                .joined()
            let fileURL = directory.appending(
                path: "knowledge-image-\(digest.prefix(16)).\(imageExtension(data: data, sourceURL: sourceURL))"
            )
            if !FileManager.default.fileExists(atPath: fileURL.path) {
                try data.write(to: fileURL, options: .atomic)
            }
            return fileURL
        }.value
    }

    private static func imageExtension(data: Data, sourceURL: URL) -> String {
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "png" }
        if data.starts(with: [0xFF, 0xD8, 0xFF]) { return "jpg" }
        let pathExtension = sourceURL.pathExtension.lowercased()
        return ["gif", "heic", "jpeg", "jpg", "png", "webp"].contains(pathExtension)
            ? pathExtension
            : "jpg"
    }
}

private struct IOSPDFView: UIViewRepresentable {
    let url: URL
    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.document = PDFDocument(url: url)
        return view
    }
    func updateUIView(_ uiView: PDFView, context: Context) {
        if uiView.document?.documentURL != url { uiView.document = PDFDocument(url: url) }
    }
}
