import AVKit
import SwiftUI

enum VideoPageResource: Hashable, Sendable {
    case mv(Int64)
    case video(String)

    var identity: String {
        switch self {
        case let .mv(id): "mv-\(id)"
        case let .video(id): "video-\(id)"
        }
    }

    var commentResource: CommentResource {
        switch self {
        case let .mv(id): .mv(id)
        case let .video(id): .video(id)
        }
    }

    var displayName: String {
        switch self {
        case .mv: "MV"
        case .video: "视频"
        }
    }
}

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

    func settingSubscribed(_ subscribed: Bool) -> Self {
        switch self {
        case let .mv(value): .mv(value.settingSubscribed(subscribed))
        case let .video(value): .video(value.settingSubscribed(subscribed))
        }
    }
}

private enum VideoDetailSection: String, CaseIterable {
    case comments = "评论"
    case related = "相关推荐"

    var symbol: String {
        switch self {
        case .comments: "bubble.left"
        case .related: "rectangle.stack"
        }
    }

    static func visible(hasRelated: Bool) -> [Self] {
        hasRelated ? allCases : [.comments]
    }
}

struct VideoRecommendationsView: View {
    let library: LiveVideoLibrary
    let onOpenRoute: (Route) -> Void

    @State private var items: [VideoRecommendation] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var generation = 0
    @State private var loadTask: Task<Void, Never>?

    var body: some View {
        Group {
            if isLoading && items.isEmpty {
                ProgressView("正在加载推荐…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage, items.isEmpty {
                ContentUnavailableView {
                    Label("推荐加载失败", systemImage: "wifi.exclamationmark")
                } description: {
                    Text(errorMessage)
                } actions: {
                    Button("重试") { startLoad() }
                }
            } else if items.isEmpty {
                ContentUnavailableView("暂无推荐", systemImage: "play.rectangle")
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
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                }
            }
        }
        .navigationTitle("MV 与视频")
        .toolbar {
            ToolbarItem {
                Button(action: startLoad) { Image(systemName: "arrow.clockwise") }
                    .help("刷新推荐")
                    .accessibilityLabel("刷新推荐")
                    .disabled(isLoading)
            }
        }
        .task { startLoad() }
        .onDisappear {
            generation &+= 1
            loadTask?.cancel()
            loadTask = nil
        }
    }

    @MainActor
    private func startLoad() {
        generation &+= 1
        let requestGeneration = generation
        loadTask?.cancel()
        isLoading = true
        errorMessage = nil
        loadTask = Task { @MainActor in
            do {
                let loaded = try await library.recommendations()
                try Task.checkCancellation()
                guard generation == requestGeneration else { return }
                items = loaded
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

struct VideoDetailView: View {
    let resource: VideoPageResource
    let library: LiveVideoLibrary
    let knowledgeLibrary: LiveMusicKnowledgeLibrary?
    @Bindable var songPlayer: PlayerController
    let currentUserID: Int64?
    let onOpenUser: (Int64) -> Void
    let onOpenRelated: (Route) -> Void
    let onLogin: () -> Void

    @State private var detail: VideoPageDetail?
    @State private var related: [VideoRecommendation] = []
    @State private var detailError: String?
    @State private var relatedError: String?
    @State private var playbackError: String?
    @State private var subscriptionError: String?
    @State private var selectedResolution = 720
    @State private var isPreparingPlayback = false
    @State private var isUpdatingSubscription = false
    @State private var videoPlayer: AVPlayer?
    @State private var selectedSection = VideoDetailSection.comments
    @State private var generation = 0
    @State private var detailTask: Task<Void, Never>?
    @State private var relatedTask: Task<Void, Never>?
    @State private var playbackTask: Task<Void, Never>?
    @State private var subscriptionTask: Task<Void, Never>?

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
                    LazyVStack(alignment: .leading, spacing: 24, pinnedViews: [.sectionHeaders]) {
                        mediaArea(detail)
                        metadata(detail)
                        Section {
                            switch selectedSection {
                            case .comments:
                                if case let .mv(id) = resource, let knowledgeLibrary {
                                    MusicKnowledgeSection(
                                        resource: .mv(id),
                                        library: knowledgeLibrary,
                                        onOpenRoute: onOpenRelated
                                    )
                                }
                                VideoCommentsSection(
                                    resource: resource.commentResource,
                                    library: library,
                                    onOpenUser: onOpenUser
                                )
                            case .related:
                                relatedSection
                            }
                        } header: {
                            if visibleSections.count > 1 {
                                HStack {
                                    Picker("视频内容", selection: $selectedSection) {
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

    private func mediaArea(_ detail: VideoPageDetail) -> some View {
        ZStack {
            Color.black
            if let videoPlayer {
                VideoPlayer(player: videoPlayer)
            } else {
                VideoArtwork(url: detail.coverURL, symbol: "play.rectangle")
                Button(action: startPlayback) {
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
                .disabled(detail.availableResolutions.isEmpty || isPreparingPlayback)
                .help(detail.availableResolutions.isEmpty ? "该资源暂无可用清晰度" : "播放")
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
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Label(resource.displayName, systemImage: "play.rectangle")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(detail.title)
                        .font(.title2.weight(.semibold))
                        .textSelection(.enabled)
                    HStack(spacing: 8) {
                        if !detail.creator.isEmpty {
                            Label(detail.creator, systemImage: "person")
                        }
                        Label(videoDurationText(detail.durationMilliseconds), systemImage: "clock")
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                HStack(spacing: 8) {
                    if !detail.availableResolutions.isEmpty {
                        Picker("清晰度", selection: $selectedResolution) {
                            ForEach(detail.availableResolutions, id: \.self) { value in
                                Text("\(value)P").tag(value)
                            }
                        }
                        .pickerStyle(.menu)
                        .fixedSize()
                        .frame(minHeight: 44)
                    }
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
            }
            if let subscriptionError {
                Label(subscriptionError, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private var visibleSections: [VideoDetailSection] {
        VideoDetailSection.visible(hasRelated: !related.isEmpty || relatedError != nil)
    }

    @ViewBuilder
    private var relatedSection: some View {
        if let relatedError, related.isEmpty {
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
        videoPlayer?.pause()
        videoPlayer = nil
        detail = nil
        related = []
        detailError = nil
        relatedError = nil
        playbackError = nil
        subscriptionError = nil
        isPreparingPlayback = false
        isUpdatingSubscription = false
        selectedSection = .comments
        detailTask = Task { @MainActor in
            do {
                let loaded: VideoPageDetail = switch resource {
                case let .mv(id): .mv(try await library.mvDetail(id: id))
                case let .video(id): .video(try await library.videoDetail(id: id))
                }
                try Task.checkCancellation()
                guard generation == requestGeneration else { return }
                detail = loaded
                selectedResolution = VideoResolutionPolicy.preferred(
                    720,
                    available: loaded.availableResolutions
                ) ?? 720
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
        if related.isEmpty { selectedSection = .comments }
        relatedTask = Task { @MainActor in
            do {
                let loaded = switch resource {
                case let .mv(id): try await library.related(toMV: id)
                case let .video(id): try await library.related(toVideo: id)
                }
                try Task.checkCancellation()
                guard generation == requestGeneration else { return }
                related = loaded
                if loaded.isEmpty { selectedSection = .comments }
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
    private func startPlayback() {
        guard let detail, !isPreparingPlayback else { return }
        let requestGeneration = generation
        playbackTask?.cancel()
        playbackError = nil
        isPreparingPlayback = true
        playbackTask = Task { @MainActor in
            do {
                let source = switch resource {
                case let .mv(id): try await library.mvPlaybackSource(
                    id: id,
                    preferredResolution: selectedResolution,
                    availableResolutions: detail.availableResolutions
                )
                case let .video(id): try await library.videoPlaybackSource(
                    id: id,
                    preferredResolution: selectedResolution,
                    availableResolutions: detail.availableResolutions
                )
                }
                try Task.checkCancellation()
                guard generation == requestGeneration else { return }
                let playbackURL = try await VideoPlaybackURLResolver.resolve(source.url)
                try Task.checkCancellation()
                guard generation == requestGeneration else { return }
                songPlayer.pauseForVideo()
                let player = AVPlayer(url: playbackURL)
                videoPlayer = player
                selectedResolution = source.resolution
                player.play()
            } catch is CancellationError {
            } catch {
                guard generation == requestGeneration else { return }
                playbackError = error.localizedDescription
            }
            guard generation == requestGeneration else { return }
            isPreparingPlayback = false
            playbackTask = nil
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
        switch resource {
        case let .mv(id): .mv(try await library.mvDetail(id: id))
        case let .video(id): .video(try await library.videoDetail(id: id))
        }
    }

    @MainActor
    private func stopAndCancel() {
        generation &+= 1
        detailTask?.cancel()
        relatedTask?.cancel()
        playbackTask?.cancel()
        subscriptionTask?.cancel()
        videoPlayer?.pause()
        videoPlayer?.replaceCurrentItem(with: nil)
        videoPlayer = nil
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
