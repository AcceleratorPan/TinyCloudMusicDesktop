import SwiftUI

struct AddSongToPlaylistView: View {
    let song: Song
    let userID: Int64
    let extras: LiveMusicExtras
    let library: LiveMusicLibrary
    let onFinished: (Int64) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var phase: AvailablePlaylistPhase = .idle
    @State private var addingPlaylistID: Int64?
    @State private var failedPlaylistID: Int64?
    @State private var operationError: String?

    init(
        song: Song,
        userID: Int64,
        extras: LiveMusicExtras,
        library: LiveMusicLibrary,
        onFinished: @escaping (Int64) -> Void
    ) {
        self.song = song
        self.userID = userID
        self.extras = extras
        self.library = library
        self.onFinished = onFinished
    }

    var body: AnyView { AnyView(bodyContent) }

    private var bodyContent: AnyView {
        AnyView(NavigationStack {
            VStack(spacing: 0) {
                if let operationError {
                    HStack(spacing: 10) {
                        Label(operationError, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                            .lineLimit(2)
                        Spacer()
                        if let failedPlaylistID {
                            Button("重试") { add(to: failedPlaylistID) }
                                .disabled(addingPlaylistID != nil)
                        }
                        Button {
                            self.operationError = nil
                            failedPlaylistID = nil
                        } label: {
                            Image(systemName: "xmark")
                        }
                        .buttonStyle(.plain)
                        .help("关闭错误提示")
                        .accessibilityLabel("关闭错误提示")
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    Divider()
                }

                content
            }
            .navigationTitle("添加到歌单")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .disabled(addingPlaylistID != nil)
                    .help("关闭")
                    .accessibilityLabel("关闭")
                }
            }
        }
        .frame(minWidth: 480, idealWidth: 540, minHeight: 420, idealHeight: 520)
        .task {
            guard phase == .idle else { return }
            await load()
        })
    }

    private var content: AnyView {
        AnyView(Group {
            switch phase {
            case .idle, .loading:
                VStack(spacing: 12) {
                    ProgressView()
                    Text("正在加载可用歌单…")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case let .failed(message):
                ContentUnavailableView {
                    Label("歌单加载失败", systemImage: "wifi.exclamationmark")
                } description: {
                    Text(message)
                } actions: {
                    Button("重试") { Task { await load() } }
                }
            case let .loaded(playlists):
                if playlists.isEmpty {
                    ContentUnavailableView(
                        "没有可用歌单",
                        systemImage: "music.note.list",
                        description: Text("创建歌单后可将这首歌添加进去。")
                    )
                } else {
                    List(playlists) { item in
                        playlistRow(item)
                    }
                    .listStyle(.inset)
                }
            }
        })
    }

    private func playlistRow(_ item: MusicAvailablePlaylist) -> AnyView {
        AnyView(HStack(spacing: 12) {
            PlaylistCover(url: item.playlist.coverURL)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.playlist.name)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                Text("\(item.playlist.trackCount) 首 · \(item.playlist.creatorName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if item.containsTrack {
                Label("已包含", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Button {
                    add(to: item.id)
                } label: {
                    if addingPlaylistID == item.id {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "plus.circle")
                    }
                }
                .buttonStyle(.borderless)
                .disabled(addingPlaylistID != nil)
                .frame(width: 36, height: 36)
                .help("添加到“\(item.playlist.name)”")
                .accessibilityLabel("添加到\(item.playlist.name)")
            }
        }
        .padding(.vertical, 4))
    }

    @MainActor
    private func load() async {
        phase = .loading
        operationError = nil
        do {
            var offset = 0
            var values: [MusicAvailablePlaylist] = []
            var seen = Set<Int64>()
            while true {
                let page = try await extras.availablePlaylists(userID: userID, trackID: song.id, offset: offset)
                let newValues = page.playlists.filter { seen.insert($0.id).inserted }
                values.append(contentsOf: newValues)
                guard page.hasMore, !page.playlists.isEmpty else { break }
                offset += page.playlists.count
            }
            try Task.checkCancellation()
            phase = .loaded(values)
        } catch is CancellationError {
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private func add(to playlistID: Int64) {
        addingPlaylistID = playlistID
        failedPlaylistID = nil
        operationError = nil
        Task { @MainActor in
            do {
                try await library.addSongs([song.id], to: playlistID)
                addingPlaylistID = nil
                onFinished(playlistID)
                dismiss()
            } catch is CancellationError {
                addingPlaylistID = nil
            } catch {
                addingPlaylistID = nil
                failedPlaylistID = playlistID
                operationError = error.localizedDescription
            }
        }
    }
}

struct RemoveSongFromPlaylistButton: View {
    let songID: Int64
    let playlistID: Int64
    let library: LiveMusicLibrary
    let onRemoved: () -> Void

    @State private var showConfirmation = false
    @State private var isRemoving = false
    @State private var errorMessage: String?

    init(
        songID: Int64,
        playlistID: Int64,
        library: LiveMusicLibrary,
        onRemoved: @escaping () -> Void
    ) {
        self.songID = songID
        self.playlistID = playlistID
        self.library = library
        self.onRemoved = onRemoved
    }

    var body: AnyView { AnyView(content) }

    private var content: AnyView {
        AnyView(Button(role: .destructive) {
            showConfirmation = true
        } label: {
            if isRemoving {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text("正在移除")
                }
            } else {
                Label("从歌单移除", systemImage: "trash")
            }
        }
        .disabled(isRemoving)
        .confirmationDialog("从歌单移除这首歌？", isPresented: $showConfirmation) {
            Button("移除", role: .destructive) { remove() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("移除后仍可重新添加。")
        }
        .alert("移除失败", isPresented: showsError) {
            Button("重试") { remove() }
            Button("取消", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "未知错误")
        })
    }

    private var showsError: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )
    }

    private func remove() {
        isRemoving = true
        errorMessage = nil
        Task { @MainActor in
            do {
                try await library.removeSongs([songID], from: playlistID)
                isRemoving = false
                onRemoved()
            } catch is CancellationError {
                isRemoving = false
            } catch {
                isRemoving = false
                errorMessage = error.localizedDescription
            }
        }
    }
}

private enum AvailablePlaylistPhase: Equatable {
    case idle
    case loading
    case loaded([MusicAvailablePlaylist])
    case failed(String)
}

private struct PlaylistCover: View {
    let url: URL?

    var body: some View {
        CachedAsyncImage(url: url) { phase in
            switch phase {
            case let .success(image):
                image.resizable().scaledToFill()
            default:
                ZStack {
                    Rectangle().fill(.quaternary)
                    Image(systemName: "music.note.list")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: 44, height: 44)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}
