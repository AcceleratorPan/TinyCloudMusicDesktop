import AppKit
import AVKit
import SwiftUI

private enum VideoPageDetail: Equatable {
    case mv(MVDetail)
    case video(VideoDetail)

    var title: String {
        switch self {
        case let .mv(value): value.title
        case let .video(value): value.title
        }
    }

    var creator: String {
        switch self {
        case let .mv(value): value.artistName
        case let .video(value): value.creatorName
        }
    }

    var coverURL: URL? {
        switch self {
        case let .mv(value): value.coverURL
        case let .video(value): value.coverURL
        }
    }

    var durationMilliseconds: Int64 {
        switch self {
        case let .mv(value): value.durationMilliseconds
        case let .video(value): value.durationMilliseconds
        }
    }

    var isSubscribed: Bool {
        switch self {
        case let .mv(value): value.isSubscribed
        case let .video(value): value.isSubscribed
        }
    }

    var availableResolutions: [Int] {
        switch self {
        case let .mv(value): value.availableResolutions
        case let .video(value): value.availableResolutions
        }
    }

    var descriptionText: String {
        switch self {
        case let .mv(value): value.description
        case let .video(value): value.description
        }
    }

    var publishTime: String {
        switch self {
        case let .mv(value): value.publishTime
        case let .video(value): value.publishTime
        }
    }

    var playCount: Int64 {
        switch self {
        case let .mv(value): value.playCount
        case let .video(value): value.playCount
        }
    }

    func settingSubscribed(_ subscribed: Bool) -> Self {
        switch self {
        case let .mv(value): .mv(value.settingSubscribed(subscribed))
        case let .video(value): .video(value.settingSubscribed(subscribed))
        }
    }
}

private enum VideoDetailSection: String {
    case knowledge = "百科"
    case comments = "评论"
    case related = "相关推荐"

    var symbol: String {
        switch self {
        case .knowledge: "text.book.closed"
        case .comments: "bubble.left"
        case .related: "rectangle.stack"
        }
    }
}

// AppKit runs local event monitors on the main thread, but the imported callback is not actor-annotated.
private struct MainThreadScrollEvent: @unchecked Sendable {
    let value: NSEvent
}

struct VideoPlayerScrollGestureState: Sendable {
    private var routesGestureToPage = false

    mutating func shouldRouteToPage(
        phase: NSEvent.Phase,
        momentumPhase: NSEvent.Phase,
        pointerInsidePlayer: Bool
    ) -> Bool {
        if phase.isEmpty, momentumPhase.isEmpty {
            return pointerInsidePlayer
        }
        if phase.contains(.mayBegin) || phase.contains(.began) {
            routesGestureToPage = pointerInsidePlayer
        }
        let shouldRoute = routesGestureToPage || pointerInsidePlayer
        if phase.contains(.cancelled)
            || momentumPhase.contains(.ended)
            || momentumPhase.contains(.cancelled)
        {
            routesGestureToPage = false
        }
        return shouldRoute
    }
}

private final class WeakPlayerView: @unchecked Sendable {
    weak var value: AVPlayerView?

    init(_ value: AVPlayerView) { self.value = value }
}

private final class MainThreadScrollGestureState: @unchecked Sendable {
    @MainActor var value = VideoPlayerScrollGestureState()
}

struct NativeVideoPlayerView: NSViewRepresentable {
    let player: AVPlayer

    final class Coordinator {
        private var scrollMonitor: Any?
        private let scrollGesture = MainThreadScrollGestureState()

        deinit {
            if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
        }

        func installScrollMonitor(for view: AVPlayerView) {
            let view = WeakPlayerView(view)
            let scrollGesture = scrollGesture
            scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
                let event = MainThreadScrollEvent(value: event)
                let consumed = MainActor.assumeIsolated {
                    guard let view = view.value,
                          event.value.window === view.window
                    else { return false }
                    let pointerInsidePlayer = NativeVideoPlayerView.containsScrollLocation(
                        event.value.locationInWindow,
                        window: event.value.window,
                        in: view
                    )
                    guard scrollGesture.value.shouldRouteToPage(
                        phase: event.value.phase,
                        momentumPhase: event.value.momentumPhase,
                        pointerInsidePlayer: pointerInsidePlayer
                    ) else { return false }
                    view.enclosingScrollView?.scrollWheel(with: event.value)
                    return true
                }
                return consumed ? nil : event.value
            }
        }

        func removeScrollMonitor() {
            if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
            scrollMonitor = nil
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    static func containsScrollLocation(
        _ location: NSPoint,
        window: NSWindow?,
        in view: AVPlayerView
    ) -> Bool {
        guard let viewWindow = view.window, window === viewWindow else { return false }
        return view.visibleRect.contains(view.convert(location, from: nil))
    }

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        context.coordinator.installScrollMonitor(for: view)
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }

    static func dismantleNSView(_ view: AVPlayerView, coordinator: Coordinator) {
        coordinator.removeScrollMonitor()
        view.player = nil
    }
}

private enum VideoHomeSection: String, CaseIterable {
    case recommendations = "推荐"
    case subscriptions = "我的收藏"

    var symbol: String {
        switch self {
        case .recommendations: "sparkles"
        case .subscriptions: "star"
        }
    }
}

struct VideoRecommendationsView: View {
    let library: LiveVideoLibrary
    let currentUserID: Int64?
    let subscriptionOverrides: [VideoPageResource: Bool]
    let subscriptionRevision: Int
    let onOpenRoute: (Route) -> Void
    let onLogin: () -> Void
    let onSubscriptionsLoaded: ([VideoPageResource]) -> Void

    @State private var selectedSection = VideoHomeSection.recommendations
    @State private var recommendations: [VideoRecommendation] = []
    @State private var subscriptionPage: VideoSubscriptionPage?
    @State private var isLoading = false
    @State private var isLoadingMore = false
    @State private var errorMessage: String?
    @State private var generation = 0
    @State private var loadTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            Picker("视频内容", selection: $selectedSection) {
                ForEach(VideoHomeSection.allCases, id: \.self) { section in
                    Label(section.rawValue, systemImage: section.symbol).tag(section)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 360)
            .padding(.horizontal, 24)
            .padding(.vertical, 12)

            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("MV 与视频")
        .toolbar {
            ToolbarItem {
                Button { startLoad(force: true) } label: { Image(systemName: "arrow.clockwise") }
                    .help(refreshLabel)
                    .accessibilityLabel(refreshLabel)
                    .disabled(isLoading || isLoadingMore || isLoggedOutSubscription)
            }
        }
        .task(id: loadIdentity) { startLoad() }
        .onDisappear {
            generation &+= 1
            loadTask?.cancel()
            loadTask = nil
        }
    }

    @ViewBuilder
    private var content: some View {
        if isLoggedOutSubscription {
            ContentUnavailableView {
                Label("需要登录", systemImage: "person.crop.circle.badge.exclamationmark")
            } description: {
                Text("登录后查看收藏的 MV 与视频。")
            } actions: {
                Button("前往登录", action: onLogin)
            }
        } else if isLoading && items.isEmpty {
            ProgressView(loadingLabel)
        } else if let errorMessage, items.isEmpty {
            ContentUnavailableView {
                Label(errorTitle, systemImage: "wifi.exclamationmark")
            } description: {
                Text(errorMessage)
            } actions: {
                Button("重试") { startLoad() }
            }
        } else if items.isEmpty {
            ContentUnavailableView(emptyTitle, systemImage: selectedSection.symbol)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(items) { item in
                        Button { onOpenRoute(item.route) } label: {
                            VideoRecommendationRow(item: item)
                        }
                        .buttonStyle(.plain)
                        Divider().padding(.leading, 132)
                    }
                    if let errorMessage {
                        InlineRetry(message: errorMessage) {
                            if selectedSection == .subscriptions, let page = subscriptionPage, page.hasMore {
                                Task { await loadMore(page) }
                            } else {
                                startLoad()
                            }
                        }
                    } else if selectedSection == .subscriptions,
                              let page = subscriptionPage,
                              page.hasMore {
                        LoadMoreTrigger(title: isLoadingMore ? "正在加载更多…" : "继续加载") {
                            Task { await loadMore(page) }
                        }
                        .id(page.nextOffset)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
            }
        }
    }

    private var items: [VideoRecommendation] {
        switch selectedSection {
        case .recommendations: recommendations
        case .subscriptions:
            (subscriptionPage?.items ?? []).filter { subscriptionOverrides[$0.resource] != false }
        }
    }

    private var isLoggedOutSubscription: Bool {
        selectedSection == .subscriptions && currentUserID == nil
    }

    private var loadIdentity: String {
        let revision = selectedSection == .subscriptions ? subscriptionRevision : 0
        return "\(selectedSection.rawValue):\(currentUserID.map(String.init) ?? "guest"):\(revision)"
    }

    private var loadingLabel: String {
        selectedSection == .subscriptions ? "正在加载收藏…" : "正在加载推荐…"
    }

    private var errorTitle: String {
        selectedSection == .subscriptions ? "收藏列表加载失败" : "推荐加载失败"
    }

    private var emptyTitle: String {
        selectedSection == .subscriptions ? "暂无收藏的 MV 或视频" : "暂无推荐"
    }

    private var refreshLabel: String {
        selectedSection == .subscriptions ? "刷新收藏" : "刷新推荐"
    }

    @MainActor
    private func startLoad(force: Bool = false) {
        generation &+= 1
        let requestGeneration = generation
        let section = selectedSection
        loadTask?.cancel()
        isLoadingMore = false
        errorMessage = nil
        guard !isLoggedOutSubscription else {
            subscriptionPage = nil
            isLoading = false
            loadTask = nil
            return
        }

        if section == .subscriptions { subscriptionPage = nil }
        isLoading = true
        loadTask = Task { @MainActor in
            do {
                if force {
                    await library.invalidateCachedResponses(
                        in: section == .subscriptions ? [.library] : [.detail]
                    )
                }
                switch section {
                case .recommendations:
                    let loaded = try await loadRecommendations()
                    try Task.checkCancellation()
                    guard generation == requestGeneration else { return }
                    recommendations = loaded
                case .subscriptions:
                    let loaded = try await library.subscriptions()
                    try Task.checkCancellation()
                    guard generation == requestGeneration else { return }
                    onSubscriptionsLoaded(loaded.items.map(\.resource))
                    subscriptionPage = loaded
                }
            } catch is CancellationError {
            } catch {
                guard generation == requestGeneration else { return }
                errorMessage = error.localizedDescription
            }
            guard generation == requestGeneration else { return }
            isLoading = false
            loadTask = nil
        }
    }

    @MainActor
    private func loadMore(_ current: VideoSubscriptionPage) async {
        let requestGeneration = generation
        let accountID = currentUserID
        guard selectedSection == .subscriptions,
              accountID != nil,
              current.hasMore,
              !isLoadingMore
        else { return }
        isLoadingMore = true
        errorMessage = nil
        defer {
            if generation == requestGeneration { isLoadingMore = false }
        }
        do {
            let next = try await library.subscriptions(offset: current.nextOffset)
            try Task.checkCancellation()
            guard generation == requestGeneration,
                  currentUserID == accountID,
                  selectedSection == .subscriptions,
                  subscriptionPage?.nextOffset == current.nextOffset
            else { return }
            onSubscriptionsLoaded(next.items.map(\.resource))
            subscriptionPage = current.appending(next)
        } catch is CancellationError {
        } catch {
            guard generation == requestGeneration, currentUserID == accountID else { return }
            errorMessage = error.localizedDescription
        }
    }

    private func loadRecommendations() async throws -> [VideoRecommendation] {
        async let featuredMVs = try? library.personalizedMVs()
        async let firstPage = try? library.recommendations(offset: 0)
        async let secondPage = try? library.recommendations(offset: 8)
        async let thirdPage = try? library.recommendations(offset: 16)
        let pages = await (featuredMVs, firstPage, secondPage, thirdPage)
        var seen = Set<String>()
        let items = [pages.0, pages.1, pages.2, pages.3]
            .compactMap { $0 }
            .flatMap { $0 }
            .filter { seen.insert($0.id).inserted }
        guard !items.isEmpty else { throw VideoLibraryError.unavailable("暂无可用推荐") }
        return items
    }
}

struct VideoDetailView: View {
    let resource: VideoPageResource
    let library: LiveVideoLibrary
    let knowledgeLibrary: LiveMusicKnowledgeLibrary?
    @Bindable var songPlayer: PlayerController
    let currentUserID: Int64?
    @Bindable var downloadManager: MusicDownloadManager
    let downloadDirectory: URL
    let playbackQuality: VideoQuality
    let downloadQuality: VideoQuality
    let subscriptionOverride: Bool?
    let onOpenUser: (Int64) -> Void
    let onOpenRelated: (Route) -> Void
    let onLogin: () -> Void
    let onDownloadQueued: () -> Void
    let onSubscriptionChanged: (VideoPageResource, Bool) -> Void

    @State private var detail: VideoPageDetail?
    @State private var related: [VideoRecommendation] = []
    @State private var detailError: String?
    @State private var relatedError: String?
    @State private var playbackError: String?
    @State private var subscriptionError: String?
    @State private var selectedResolution = 720
    @State private var unavailableResolutions: Set<Int> = []
    @State private var isPreparingPlayback = false
    @State private var isUpdatingSubscription = false
    @State private var videoPlayer: AVPlayer?
    @State private var selectedSection = VideoDetailSection.knowledge
    @State private var generation = 0
    @State private var detailTask: Task<Void, Never>?
    @State private var relatedTask: Task<Void, Never>?
    @State private var playbackTask: Task<Void, Never>?
    @State private var subscriptionTask: Task<Void, Never>?
    @State private var playerStatusObservation: NSKeyValueObservation?
    @State private var playerFailureObserver: NSObjectProtocol?

    var body: some View {
        Group {
            if detail == nil, detailError == nil {
                ProgressView("正在加载详情…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let detailError, detail == nil {
                ContentUnavailableView {
                    Label("详情加载失败", systemImage: "wifi.exclamationmark")
                } description: {
                    Text(detailError)
                } actions: {
                    Button("重试") { startLoad() }
                }
            } else if let detail {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 24) {
                        mediaArea(detail)
                        metadata(detail)
                        controls
                        switch selectedSection {
                        case .knowledge:
                            knowledgeSection(detail)
                        case .comments:
                            VideoCommentsSection(
                                resource: resource.commentResource,
                                library: library,
                                onOpenUser: onOpenUser
                            )
                        case .related:
                            relatedSection
                        }
                    }
                    .frame(maxWidth: 920)
                    .padding(.horizontal, 28)
                    .padding(.vertical, 22)
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .navigationTitle(detail?.title ?? "视频详情")
        .task(id: "\(resource.identity)-\(currentUserID.map(String.init) ?? "guest")") { startLoad() }
        .onDisappear(perform: stopAndCancel)
    }

    private var controls: some View {
        HStack(spacing: 10) {
            Picker("视频内容", selection: $selectedSection) {
                ForEach(visibleSections, id: \.self) { section in
                    Label(section.rawValue, systemImage: section.symbol).tag(section)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 360)
        }
    }

    private var visibleSections: [VideoDetailSection] {
        var sections: [VideoDetailSection] = [.knowledge, .comments]
        if relatedTask != nil || relatedError != nil || !related.isEmpty {
            sections.append(.related)
        }
        return sections
    }

    private func mediaArea(_ detail: VideoPageDetail) -> some View {
        ZStack {
            Color.black
            if let videoPlayer {
                NativeVideoPlayerView(player: videoPlayer)
                if isPreparingPlayback {
                    ProgressView()
                        .controlSize(.large)
                        .tint(.white)
                        .padding(16)
                        .background(.black.opacity(0.68), in: Circle())
                        .accessibilityLabel("正在准备播放")
                }
            } else {
                VideoArtwork(url: detail.coverURL, symbol: "play.rectangle")
                Button(action: { startPlayback() }) {
                    if isPreparingPlayback {
                        ProgressView().controlSize(.large)
                    } else {
                        Image(systemName: "play.fill")
                            .font(.system(size: 28))
                            .foregroundStyle(.white)
                            .frame(width: 64, height: 64)
                            .background(.black.opacity(0.68), in: Circle())
                    }
                }
                .buttonStyle(.plain)
                .disabled(isPreparingPlayback)
                .help("播放")
                .accessibilityLabel("播放")
            }
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(alignment: .bottomLeading) {
            if let playbackError {
                Label(playbackError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.white)
                    .padding(10)
                    .background(.black.opacity(0.78), in: RoundedRectangle(cornerRadius: 6))
                    .padding(10)
            }
        }
    }

    private func metadata(_ detail: VideoPageDetail) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(resource.displayName, systemImage: "play.rectangle")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Text(detail.title)
                    .font(.title2.weight(.semibold))
                    .textSelection(.enabled)
                Spacer(minLength: 6)
                if !selectableResolutions.isEmpty {
                    Picker("清晰度", selection: $selectedResolution) {
                        ForEach(selectableResolutions, id: \.self) { value in
                            Text("\(value)P").tag(value)
                        }
                    }
                    .pickerStyle(.menu)
                    .fixedSize()
                    .frame(minHeight: 44)
                    .disabled(isPreparingPlayback)
                    .onChange(of: selectedResolution) { previousResolution, _ in
                        guard videoPlayer != nil, !isPreparingPlayback else { return }
                        startPlayback(revertingTo: previousResolution)
                    }
                }
                Button(action: toggleDownload) {
                    Group {
                        switch videoDownloadState {
                        case let .running(progress):
                            if let progress {
                                ProgressView(value: progress).frame(width: 18)
                            } else {
                                ProgressView().controlSize(.small)
                            }
                        case .queued:
                            ProgressView().controlSize(.small)
                        case .paused:
                            Image(systemName: "play.circle")
                        case .completed:
                            Image(systemName: "checkmark.circle.fill")
                        case .failed:
                            Image(systemName: "exclamationmark.circle")
                        case .cancelled, .none:
                            Image(systemName: "arrow.down.circle")
                        }
                    }
                    .frame(width: 18, height: 18)
                }
                .buttonStyle(.bordered)
                .frame(minWidth: 44, minHeight: 44)
                .help(videoDownloadHelp)
                .accessibilityLabel(videoDownloadHelp)
                .accessibilityValue(videoDownloadProgress.map { "\(Int($0 * 100))%" } ?? "")

                Button(action: toggleSubscription) {
                    Group {
                        if isUpdatingSubscription {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: detail.isSubscribed ? "star.fill" : "star")
                        }
                    }
                    .frame(width: 18, height: 18)
                }
                .buttonStyle(.bordered)
                .frame(minWidth: 44, minHeight: 44)
                .disabled(isUpdatingSubscription)
                .help(detail.isSubscribed ? "取消收藏" : "收藏")
                .accessibilityLabel(detail.isSubscribed ? "取消收藏" : "收藏")
            }
            HStack(spacing: 8) {
                if !detail.creator.isEmpty {
                    Label(detail.creator, systemImage: "person")
                }
                Label(videoDurationText(detail.durationMilliseconds), systemImage: "clock")
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            if let subscriptionError {
                Label(subscriptionError, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            if case let .failed(message)? = videoDownloadState {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    @ViewBuilder
    private func knowledgeSection(_ detail: VideoPageDetail) -> some View {
        if case let .mv(id) = resource, let knowledgeLibrary {
            MusicKnowledgeSection(
                resource: .mv(id),
                library: knowledgeLibrary,
                fallbackText: detail.descriptionText,
                showsTitle: false,
                onOpenRoute: onOpenRelated
            )
        } else {
            VideoKnowledgeSection(
                description: detail.descriptionText,
                publishTime: detail.publishTime,
                playCount: detail.playCount
            )
        }
    }

    @ViewBuilder
    private var relatedSection: some View {
        if relatedTask != nil, related.isEmpty {
            ProgressView("正在加载相关推荐…")
                .frame(maxWidth: .infinity, minHeight: 96)
        } else if let relatedError, related.isEmpty {
            InlineRetry(message: relatedError) { startRelatedLoad(generation: generation) }
        } else {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(related) { item in
                    Button { onOpenRelated(item.route) } label: {
                        VideoRecommendationRow(item: item, compact: true)
                    }
                    .buttonStyle(.plain)
                    Divider().padding(.leading, 116)
                }
            }
        }
    }

    @MainActor
    private func startLoad() {
        generation &+= 1
        let requestGeneration = generation
        detailTask?.cancel()
        relatedTask?.cancel()
        playbackTask?.cancel()
        subscriptionTask?.cancel()
        clearPlaybackObservers()
        videoPlayer?.pause()
        videoPlayer?.replaceCurrentItem(with: nil)
        videoPlayer = nil
        detail = nil
        related = []
        detailError = nil
        relatedError = nil
        playbackError = nil
        subscriptionError = nil
        unavailableResolutions = []
        isPreparingPlayback = false
        isUpdatingSubscription = false
        selectedSection = .knowledge
        detailTask = Task { @MainActor in
            do {
                let loaded = try await loadDetail()
                try Task.checkCancellation()
                guard generation == requestGeneration else { return }
                detail = loaded
                selectedResolution = VideoResolutionPolicy.preferred(
                    playbackQuality,
                    available: loaded.availableResolutions
                ) ?? playbackQuality.resolution
            } catch is CancellationError {
            } catch {
                guard generation == requestGeneration else { return }
                detailError = error.localizedDescription
            }
            guard generation == requestGeneration else { return }
            detailTask = nil
        }
        startRelatedLoad(generation: requestGeneration)
    }

    @MainActor
    private func startRelatedLoad(generation requestGeneration: Int) {
        relatedTask?.cancel()
        relatedError = nil
        relatedTask = Task { @MainActor in
            do {
                let loaded = switch resource {
                case let .mv(id): try await library.related(toMV: id)
                case let .video(id): try await library.related(toVideo: id)
                }
                try Task.checkCancellation()
                guard generation == requestGeneration else { return }
                related = loaded
                if loaded.isEmpty, selectedSection == .related {
                    selectedSection = .knowledge
                }
            } catch is CancellationError {
            } catch {
                guard generation == requestGeneration else { return }
                relatedError = error.localizedDescription
            }
            guard generation == requestGeneration else { return }
            relatedTask = nil
        }
    }

    @MainActor
    private func startPlayback(revertingTo previousResolution: Int? = nil) {
        guard let detail, !isPreparingPlayback else { return }
        let requestGeneration = generation
        let requestedResolution = selectedResolution
        let previousPlayer = videoPlayer
        playbackTask?.cancel()
        playbackError = nil
        isPreparingPlayback = true
        playbackTask = Task { @MainActor in
            do {
                let source = try await playbackSource(for: detail)
                try Task.checkCancellation()
                guard generation == requestGeneration else { return }
                let playbackURL = try await VideoPlaybackURLResolver.resolve(source.url)
                try Task.checkCancellation()
                guard generation == requestGeneration else { return }
                songPlayer.pauseForVideo()
                let player = AVPlayer(playerItem: AVPlayerItem(url: playbackURL))
                if let position = previousPlayer?.currentTime(), position.isNumeric {
                    _ = await player.seek(to: position, toleranceBefore: .zero, toleranceAfter: .zero)
                }
                try Task.checkCancellation()
                guard generation == requestGeneration else { return }
                let shouldPlay = previousPlayer?.timeControlStatus != .paused
                clearPlaybackObservers()
                previousPlayer?.pause()
                previousPlayer?.replaceCurrentItem(with: nil)
                videoPlayer = player
                if source.resolution != requestedResolution {
                    unavailableResolutions.insert(requestedResolution)
                }
                selectedResolution = source.resolution
                installPlaybackObservers(for: player, generation: requestGeneration)
                if shouldPlay { player.play() }
            } catch is CancellationError {
            } catch {
                guard generation == requestGeneration else { return }
                if previousPlayer != nil, let previousResolution {
                    selectedResolution = previousResolution
                }
                playbackError = error.localizedDescription
                isPreparingPlayback = false
            }
            guard generation == requestGeneration else { return }
            playbackTask = nil
        }
    }

    @MainActor
    private func installPlaybackObservers(for player: AVPlayer, generation requestGeneration: Int) {
        guard let item = player.currentItem else { return }
        playerStatusObservation = item.observe(\.status, options: [.initial, .new]) { item, _ in
            let status = item.status
            let message = item.error?.localizedDescription
            Task { @MainActor in
                guard generation == requestGeneration, videoPlayer === player else { return }
                switch status {
                case .readyToPlay:
                    isPreparingPlayback = false
                case .failed:
                    failPlayback(player, message: message ?? "视频播放失败，请重试")
                case .unknown:
                    break
                @unknown default:
                    failPlayback(player, message: "视频播放状态无法识别")
                }
            }
        }
        playerFailureObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: item,
            queue: .main
        ) { notification in
            let message = (notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error)?
                .localizedDescription ?? "视频播放中断，请重试"
            MainActor.assumeIsolated {
                guard generation == requestGeneration, videoPlayer === player else { return }
                failPlayback(player, message: message)
            }
        }
    }

    @MainActor
    private func failPlayback(_ player: AVPlayer, message: String) {
        clearPlaybackObservers()
        player.pause()
        player.replaceCurrentItem(with: nil)
        videoPlayer = nil
        isPreparingPlayback = false
        playbackError = message
    }

    @MainActor
    private func clearPlaybackObservers() {
        playerStatusObservation?.invalidate()
        playerStatusObservation = nil
        if let playerFailureObserver {
            NotificationCenter.default.removeObserver(playerFailureObserver)
            self.playerFailureObserver = nil
        }
    }

    private func playbackSource(for detail: VideoPageDetail) async throws -> VideoPlaybackSource {
        switch resource {
        case let .mv(id):
            try await library.mvPlaybackSource(
                id: id,
                preferredResolution: selectedResolution,
                availableResolutions: detail.availableResolutions
            )
        case let .video(id):
            try await library.videoPlaybackSource(
                id: id,
                preferredResolution: selectedResolution,
                availableResolutions: detail.availableResolutions
            )
        }
    }

    @MainActor
    private func toggleDownload() {
        let id = resource.identity
        switch videoDownloadState {
        case .queued, .running:
            downloadManager.pauseVideo(id: id)
        case .paused:
            downloadManager.retryVideo(id: id)
        case .completed:
            break
        case .failed, .cancelled, .none:
            guard let detail else { return }
            if downloadManager.enqueue(
                video: resource,
                title: detail.title,
                creator: detail.creator,
                availableResolutions: detail.availableResolutions,
                to: downloadDirectory,
                quality: downloadQuality
            ) {
                onDownloadQueued()
            }
        }
    }

    @MainActor
    private func toggleSubscription() {
        guard let detail, !isUpdatingSubscription else { return }
        guard currentUserID != nil else {
            onLogin()
            return
        }
        let requestGeneration = generation
        let desired = !detail.isSubscribed
        isUpdatingSubscription = true
        subscriptionError = nil
        subscriptionTask = Task { @MainActor in
            do {
                switch resource {
                case let .mv(id): try await library.setMVSubscribed(id, subscribed: desired)
                case let .video(id): try await library.setVideoSubscribed(id, subscribed: desired)
                }
                try Task.checkCancellation()
                guard generation == requestGeneration else { return }
                self.detail = detail.settingSubscribed(desired)
                onSubscriptionChanged(resource, desired)
            } catch is CancellationError {
            } catch {
                guard generation == requestGeneration else { return }
                subscriptionError = error.localizedDescription
                await confirmDetailAfterUnknownResult(generation: requestGeneration)
            }
            guard generation == requestGeneration else { return }
            isUpdatingSubscription = false
            subscriptionTask = nil
        }
    }

    @MainActor
    private func confirmDetailAfterUnknownResult(generation requestGeneration: Int) async {
        await library.invalidateCachedResponses(in: [.detail])
        guard let refreshed = try? await loadDetail(), generation == requestGeneration else { return }
        detail = refreshed
    }

    private func loadDetail() async throws -> VideoPageDetail {
        let loaded: VideoPageDetail = switch resource {
        case let .mv(id): .mv(try await library.mvDetail(id: id))
        case let .video(id): .video(try await library.videoDetail(id: id))
        }
        return subscriptionOverride.map { loaded.settingSubscribed($0) } ?? loaded
    }

    @MainActor
    private func stopAndCancel() {
        generation &+= 1
        detailTask?.cancel()
        relatedTask?.cancel()
        playbackTask?.cancel()
        subscriptionTask?.cancel()
        clearPlaybackObservers()
        videoPlayer?.pause()
        videoPlayer?.replaceCurrentItem(with: nil)
        videoPlayer = nil
    }

    private var selectableResolutions: [Int] {
        detail?.availableResolutions.filter { !unavailableResolutions.contains($0) } ?? []
    }

    private var videoDownloadState: MusicDownloadState? {
        downloadManager.videoStates[resource.identity]
    }

    private var videoDownloadProgress: Double? {
        switch videoDownloadState {
        case let .running(progress), let .paused(progress): progress
        default: nil
        }
    }

    private var videoDownloadHelp: String {
        switch videoDownloadState {
        case .queued: "暂停等待中的视频下载"
        case .running: "暂停视频下载"
        case .paused: "继续视频下载"
        case .completed: "视频已下载"
        case let .failed(message): "视频下载失败：\(message)"
        case .cancelled, .none: "下载视频"
        }
    }
}

private struct VideoKnowledgeSection: View {
    let description: String
    let publishTime: String
    let playCount: Int64

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !description.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("简介").font(.title3.weight(.semibold))
                    Text(description)
                        .lineSpacing(5)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if !publishTime.isEmpty {
                LabeledContent("发布时间", value: publishTime)
            }
            if playCount > 0 {
                LabeledContent("播放次数", value: playCount.formatted())
            }
            if description.isEmpty, publishTime.isEmpty, playCount <= 0 {
                ContentUnavailableView(
                    "暂无百科资料",
                    systemImage: "text.book.closed",
                    description: Text("该资源还没有可显示的百科内容。")
                )
                .frame(maxWidth: .infinity, minHeight: 180)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct VideoCommentsSection: View {
    let resource: CommentResource
    let library: LiveVideoLibrary
    let onOpenUser: (Int64) -> Void

    @State private var comments: [MusicComment] = []
    @State private var emojiPictureIDs: [String: String] = [:]
    @State private var totalCount = 0
    @State private var nextOffset = 0
    @State private var beforeTime: Int64 = 0
    @State private var hasMore = false
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var generation = 0
    @State private var loadTask: Task<Void, Never>?

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            Text(totalCount > 0 ? "评论 \(totalCount)" : "评论")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 8)
            if isLoading && comments.isEmpty {
                ProgressView("正在加载评论…")
                    .frame(maxWidth: .infinity, minHeight: 80)
            } else if let errorMessage, comments.isEmpty {
                InlineRetry(message: errorMessage) { startLoad(reset: true) }
            } else if comments.isEmpty {
                Text("暂无评论")
                    .foregroundStyle(.secondary)
                    .frame(minHeight: 52)
            } else {
                ForEach(comments) { comment in
                    ReadOnlyCommentRow(
                        comment: comment,
                        emojiPictureIDs: emojiPictureIDs,
                        onOpenUser: onOpenUser
                    )
                    Divider()
                }
                if let errorMessage {
                    InlineRetry(message: errorMessage) { startLoad(reset: false) }
                } else if hasMore {
                    LoadMoreTrigger { startLoad(reset: false) }
                        .id(nextOffset)
                }
            }
        }
        .task(id: resource) {
            startLoad(reset: true)
            emojiPictureIDs = (try? await library.commentEmojiPictureIDs()) ?? [:]
        }
        .onDisappear {
            generation &+= 1
            loadTask?.cancel()
            loadTask = nil
        }
    }

    @MainActor
    private func startLoad(reset: Bool) {
        guard reset || loadTask == nil else { return }
        if reset {
            generation &+= 1
            loadTask?.cancel()
            comments = []
            nextOffset = 0
            beforeTime = 0
        }
        let requestGeneration = generation
        let offset = reset ? 0 : nextOffset
        errorMessage = nil
        isLoading = true
        loadTask = Task { @MainActor in
            do {
                let page = try await library.comments(
                    for: resource,
                    offset: offset,
                    limit: 20,
                    // The legacy endpoint needs its timestamp cursor only beyond 5,000 comments.
                    beforeTime: offset >= 5_000 ? beforeTime : 0
                )
                try Task.checkCancellation()
                guard generation == requestGeneration else { return }
                if reset {
                    comments = page.comments
                } else {
                    let existing = Set(comments.map(\.id))
                    comments += page.comments.filter { !existing.contains($0.id) }
                }
                totalCount = page.totalCount
                nextOffset = page.nextOffset
                beforeTime = page.beforeTime
                hasMore = page.hasMore && page.nextOffset > offset && !page.comments.isEmpty
            } catch is CancellationError {
            } catch {
                guard generation == requestGeneration else { return }
                errorMessage = error.localizedDescription
            }
            guard generation == requestGeneration else { return }
            isLoading = false
            loadTask = nil
        }
    }
}

private struct VideoRecommendationRow: View {
    let item: VideoRecommendation
    var compact = false

    var body: some View {
        HStack(spacing: 14) {
            VideoArtwork(url: coverURL, symbol: "play.rectangle")
                .frame(width: compact ? 100 : 116, height: compact ? 56 : 66)
                .clipShape(RoundedRectangle(cornerRadius: 5))
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.body.weight(.medium))
                    .lineLimit(2)
                HStack(spacing: 8) {
                    Text(kind)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(kind == "MV" ? Color.red : Color.blue)
                    if !creator.isEmpty {
                        Text(creator).lineLimit(1)
                    }
                    Text(videoDurationText(durationMilliseconds))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .frame(minHeight: compact ? 64 : 76)
        .contentShape(Rectangle())
    }

    private var title: String {
        switch item {
        case let .mv(value): value.title
        case let .video(value): value.title
        }
    }

    private var creator: String {
        switch item {
        case let .mv(value): value.artistName
        case let .video(value): value.creatorName
        }
    }

    private var coverURL: URL? {
        switch item {
        case let .mv(value): value.coverURL
        case let .video(value): value.coverURL
        }
    }

    private var durationMilliseconds: Int64 {
        switch item {
        case let .mv(value): value.durationMilliseconds
        case let .video(value): value.durationMilliseconds
        }
    }

    private var kind: String {
        if case .mv = item { "MV" } else { "视频" }
    }
}

private struct VideoArtwork: View {
    let url: URL?
    let symbol: String

    var body: some View {
        CachedAsyncImage(url: url) { phase in
            if let image = phase.image {
                image.resizable().scaledToFit()
            } else {
                Image(systemName: symbol)
                    .font(.title2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityHidden(true)
    }
}

private func videoDurationText(_ milliseconds: Int64) -> String {
    let seconds = max(0, milliseconds / 1_000)
    return String(format: "%lld:%02lld", seconds / 60, seconds % 60)
}
