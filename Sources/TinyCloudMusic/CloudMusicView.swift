import SwiftUI
import UniformTypeIdentifiers

struct CloudMusicView: View {
    @Bindable var model: AppModel
    let library: LiveMusicLibrary

    @State private var page: CloudSongPage?
    @State private var selectedID: Int64?
    @State private var details: [Int64: CloudSong] = [:]
    @State private var detailErrors: [Int64: String] = [:]
    @State private var isLoading = false
    @State private var isLoadingMore = false
    @State private var loadingDetailID: Int64?
    @State private var errorMessage: String?
    @State private var loadMoreError: String?
    @State private var generation = 0
    @State private var isImporting = false
    @State private var showsUploadTasks = false
    @State private var uploadError: String?
    @State private var uploadRefreshTask: Task<Void, Never>?
    @State private var uploadRefreshID: UUID?

    private let pageSize = 30
    private var credentialRevision: UInt64 {
        library.transport.credentialSnapshotValue().revision
    }

    var body: some View {
        Group {
            if model.currentUserID == nil {
                ContentUnavailableView(
                    "需要登录",
                    systemImage: "person.crop.circle.badge.exclamationmark",
                    description: Text("登录后查看自己的音乐云盘。")
                )
            } else if isLoading, page == nil {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("正在加载音乐云盘…")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage, page == nil {
                ContentUnavailableView {
                    Label("音乐云盘加载失败", systemImage: "wifi.exclamationmark")
                } description: {
                    Text(errorMessage)
                } actions: {
                    Button("重试") { Task { await load(reset: true) } }
                }
            } else if page?.songs.isEmpty == true {
                ContentUnavailableView(
                    "云盘为空",
                    systemImage: "externaldrive",
                    description: Text("当前账号还没有云盘歌曲。")
                )
            } else {
                cloudList
            }
        }
        .navigationTitle("音乐云盘")
        .toolbar {
            if model.uploads != nil, model.currentUserID != nil {
                ToolbarItemGroup {
                    Button { isImporting = true } label: { Image(systemName: "arrow.up.circle") }
                        .help("上传到音乐云盘")
                        .accessibilityLabel("上传到音乐云盘")
                    Button { showsUploadTasks = true } label: { Image(systemName: "tray.full") }
                        .help("查看上传任务")
                        .accessibilityLabel("查看上传任务")
                }
            }
            ToolbarItem {
                Button {
                    Task { await load(reset: true) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(isLoading || isLoadingMore)
                .help("刷新音乐云盘")
                .accessibilityLabel("刷新音乐云盘")
            }
        }
        .onChange(of: model.uploads?.completionRevision ?? 0) { _, _ in
            scheduleUploadRefresh()
        }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.audio]) { result in
            switch result {
            case let .success(url):
                guard model.uploads?.prepareCloudFile(url) != nil else {
                    uploadError = "当前账号不可用于上传"
                    return
                }
                showsUploadTasks = true
            case let .failure(error):
                uploadError = error.localizedDescription
            }
        }
        .sheet(isPresented: $showsUploadTasks) {
            if let uploads = model.uploads { AudioUploadTaskSheet(manager: uploads) }
        }
        .alert("上传失败", isPresented: Binding(
            get: { uploadError != nil },
            set: { if !$0 { uploadError = nil } }
        )) {
            Button("好") { uploadError = nil }
        } message: {
            Text(uploadError ?? "")
        }
        .task(id: "\(model.currentUserID ?? 0):\(credentialRevision)") { await load(reset: true) }
        .task(id: "\(selectedID ?? 0):\(credentialRevision)") { await loadSelectedDetail() }
        .onDisappear {
            uploadRefreshTask?.cancel()
            uploadRefreshTask = nil
            uploadRefreshID = nil
        }
    }

    private var cloudList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                HStack {
                    Label("共 \((page?.totalCount ?? 0).formatted()) 首", systemImage: "externaldrive")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 12)

                Divider()

                ForEach(page?.songs ?? []) { original in
                    let song = details[original.id] ?? original
                    cloudRow(song)
                    Divider().padding(.leading, 84)
                }

                if let loadMoreError {
                    InlineRetry(message: loadMoreError) {
                        Task { await loadMore() }
                    }
                    .padding(.horizontal, 28)
                    .padding(.vertical, 8)
                } else if page?.hasMore == true {
                    LoadMoreTrigger(title: isLoadingMore ? "正在加载更多…" : "继续加载") {
                        Task { await loadMore() }
                    }
                    .id(page?.offset)
                }
            }
        }
    }

    private func cloudRow(_ song: CloudSong) -> some View {
        HStack(spacing: 12) {
            Button {
                if selectedID == song.id {
                    Task { await loadSelectedDetail() }
                } else {
                    selectedID = song.id
                }
            } label: {
                HStack(spacing: 12) {
                    CloudSongArtwork(song: song)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(song.name.isEmpty ? song.fileName : song.name)
                            .font(.body.weight(.medium))
                            .lineLimit(1)
                        Text(song.artist.isEmpty ? "未知歌手" : song.artist)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        if !song.fileName.isEmpty {
                            Text(song.fileName)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                                .help(song.fileName)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("选择 \(song.name.isEmpty ? song.fileName : song.name)")

            if loadingDetailID == song.id {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 24)
                    .accessibilityLabel("正在加载详情")
            } else if let detailError = detailErrors[song.id] {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
                    .frame(width: 24)
                    .help("详情加载失败：\(detailError)")
                    .accessibilityLabel("详情加载失败")
            }

            VStack(alignment: .trailing, spacing: 3) {
                Text(ByteCountFormatter.string(fromByteCount: song.fileSize, countStyle: .file))
                    .monospacedDigit()
                Text(song.addedAt?.formatted(date: .abbreviated, time: .omitted) ?? "日期未知")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(width: 108, alignment: .trailing)

            Label(song.isMatched ? "已匹配" : "未匹配", systemImage: song.isMatched ? "checkmark.circle" : "questionmark.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 72, alignment: .leading)

            if let downloads = model.downloads {
                DownloadControl(manager: downloads, songID: song.id) {
                    model.download(song)
                }
            }
        }
        .padding(.horizontal, 28)
        .frame(minHeight: 68)
        .background(selectedID == song.id ? Color.accentColor.opacity(0.08) : .clear)
    }

    @MainActor
    private func load(
        reset: Bool,
        preservingVisiblePage: Bool = false,
        forceRefresh: Bool = false
    ) async {
        guard let accountID = model.currentUserID else {
            page = nil
            return
        }
        let credentialRevision = credentialRevision
        if reset {
            generation += 1
            isLoadingMore = false
            if !preservingVisiblePage {
                loadingDetailID = nil
                selectedID = nil
                details = [:]
                detailErrors = [:]
                page = nil
            }
            errorMessage = nil
            loadMoreError = nil
        }
        let currentGeneration = generation
        isLoading = true
        defer { if generation == currentGeneration { isLoading = false } }
        do {
            let loaded = try await library.cloudSongs(
                limit: pageSize,
                forceRefresh: forceRefresh,
                expectedCredentialRevision: credentialRevision
            )
            try Task.checkCancellation()
            guard generation == currentGeneration,
                  model.currentUserID == accountID,
                  self.credentialRevision == credentialRevision
            else { return }
            page = loaded
            if preservingVisiblePage {
                selectedID = nil
                loadingDetailID = nil
                details = [:]
                detailErrors = [:]
            }
        } catch is CancellationError {
        } catch {
            guard generation == currentGeneration,
                  model.currentUserID == accountID,
                  self.credentialRevision == credentialRevision
            else { return }
            if preservingVisiblePage, page != nil {
                loadMoreError = error.localizedDescription
            } else {
                errorMessage = error.localizedDescription
            }
        }
    }

    @MainActor
    private func loadMore() async {
        guard let page, let accountID = model.currentUserID, page.hasMore, !isLoadingMore else { return }
        let credentialRevision = credentialRevision
        let currentGeneration = generation
        isLoadingMore = true
        loadMoreError = nil
        defer { if generation == currentGeneration { isLoadingMore = false } }
        do {
            let requestOffset = page.offset + pageSize
            guard requestOffset > page.offset else {
                self.page = CloudSongPage(
                    songs: page.songs,
                    offset: page.offset,
                    hasMore: false,
                    totalCount: page.totalCount
                )
                return
            }
            let next = try await library.cloudSongs(
                offset: requestOffset,
                limit: pageSize,
                expectedCredentialRevision: credentialRevision
            )
            try Task.checkCancellation()
            guard generation == currentGeneration,
                  model.currentUserID == accountID,
                  self.credentialRevision == credentialRevision
            else { return }
            self.page = page.merging(next).page
        } catch is CancellationError {
        } catch {
            guard generation == currentGeneration,
                  model.currentUserID == accountID,
                  self.credentialRevision == credentialRevision
            else { return }
            loadMoreError = error.localizedDescription
        }
    }

    @MainActor
    private func loadSelectedDetail() async {
        guard let selectedID, let accountID = model.currentUserID, details[selectedID] == nil else { return }
        let credentialRevision = credentialRevision
        let currentGeneration = generation
        loadingDetailID = selectedID
        detailErrors[selectedID] = nil
        defer { if loadingDetailID == selectedID { loadingDetailID = nil } }
        do {
            let detail = try await library.cloudSongDetails(
                ids: [selectedID],
                expectedCredentialRevision: credentialRevision
            ).first
            try Task.checkCancellation()
            guard generation == currentGeneration, model.currentUserID == accountID,
                  self.selectedID == selectedID
                    && self.credentialRevision == credentialRevision
            else { return }
            if let detail { details[selectedID] = detail }
        } catch is CancellationError {
        } catch {
            guard generation == currentGeneration, model.currentUserID == accountID,
                  self.selectedID == selectedID
                    && self.credentialRevision == credentialRevision
            else { return }
            detailErrors[selectedID] = error.localizedDescription
        }
    }

    private func scheduleUploadRefresh() {
        guard let accountID = model.currentUserID else { return }
        uploadRefreshTask?.cancel()
        let taskID = UUID()
        uploadRefreshID = taskID
        uploadRefreshTask = Task { @MainActor in
            defer {
                if uploadRefreshID == taskID {
                    uploadRefreshTask = nil
                    uploadRefreshID = nil
                }
            }
            do {
                try await Task.sleep(for: .milliseconds(250))
                guard model.currentUserID == accountID else { return }
                await load(reset: true, preservingVisiblePage: true, forceRefresh: true)
            } catch is CancellationError {
            } catch {
            }
        }
    }
}

private struct CloudSongArtwork: View {
    let song: CloudSong

    var body: some View {
        CachedAsyncImage(url: song.song?.album.artwork.remoteURL) { phase in
            if let image = phase.image {
                image.resizable().scaledToFill()
            } else {
                Image(systemName: "music.note")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.quaternary)
            }
        }
        .frame(width: 44, height: 44)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .accessibilityHidden(true)
    }
}
