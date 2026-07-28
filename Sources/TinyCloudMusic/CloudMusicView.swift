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

    private let pageSize = 30

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
            Task { await load(reset: true) }
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
        .task(id: model.currentUserID) { await load(reset: true) }
        .task(id: selectedID) { await loadSelectedDetail() }
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
    private func load(reset: Bool) async {
        guard model.currentUserID != nil else {
            page = nil
            return
        }
        if reset {
            generation &+= 1
            isLoadingMore = false
            loadingDetailID = nil
            selectedID = nil
            details = [:]
            detailErrors = [:]
            page = nil
            errorMessage = nil
            loadMoreError = nil
        }
        let currentGeneration = generation
        isLoading = true
        defer { if generation == currentGeneration { isLoading = false } }
        do {
            let loaded = try await library.cloudSongs(limit: pageSize)
            try Task.checkCancellation()
            guard generation == currentGeneration else { return }
            page = loaded
        } catch is CancellationError {
        } catch {
            guard generation == currentGeneration else { return }
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func loadMore() async {
        guard let page, page.hasMore, !isLoadingMore else { return }
        let currentGeneration = generation
        isLoadingMore = true
        loadMoreError = nil
        defer { if generation == currentGeneration { isLoadingMore = false } }
        do {
            let next = try await library.cloudSongs(offset: page.offset + pageSize, limit: pageSize)
            try Task.checkCancellation()
            guard generation == currentGeneration else { return }
            self.page = page.appending(next)
        } catch is CancellationError {
        } catch {
            guard generation == currentGeneration else { return }
            loadMoreError = error.localizedDescription
        }
    }

    @MainActor
    private func loadSelectedDetail() async {
        guard let selectedID, details[selectedID] == nil else { return }
        let currentGeneration = generation
        loadingDetailID = selectedID
        detailErrors[selectedID] = nil
        defer { if loadingDetailID == selectedID { loadingDetailID = nil } }
        do {
            let detail = try await library.cloudSongDetails(ids: [selectedID]).first
            try Task.checkCancellation()
            guard generation == currentGeneration, self.selectedID == selectedID else { return }
            if let detail { details[selectedID] = detail }
        } catch is CancellationError {
        } catch {
            guard generation == currentGeneration, self.selectedID == selectedID else { return }
            detailErrors[selectedID] = error.localizedDescription
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
