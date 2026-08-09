import SwiftUI

struct AddSongToPlaylistView: View {
    let song: Song
    let userID: Int64
    let extras: LiveMusicExtras
    let library: LiveMusicLibrary
    @Bindable var model: AppModel

    @Environment(\.dismiss) private var dismiss
    @State private var phase: AvailablePlaylistPhase = .idle
    @State private var retryRevision = 0
    @State private var failedPlaylist: MusicAvailablePlaylist?
    @State private var operationError: String?

    init(
        song: Song,
        userID: Int64,
        extras: LiveMusicExtras,
        library: LiveMusicLibrary,
        model: AppModel
    ) {
        self.song = song
        self.userID = userID
        self.extras = extras
        self.library = library
        self.model = model
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
                        if let failedPlaylist {
                            Button("重试") { add(to: failedPlaylist) }
                                .disabled(isAddingSong)
                        }
                        Button {
                            self.operationError = nil
                            failedPlaylist = nil
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
                    .disabled(isAddingSong)
                    .help("关闭")
                    .accessibilityLabel("关闭")
                }
            }
        }
        .frame(minWidth: 480, idealWidth: 540, minHeight: 420, idealHeight: 520)
        .task(id: "\(userID):\(model.currentUserID ?? 0):\(credentialRevision):\(song.id):\(retryRevision)") {
            await load()
        })
    }

    private var credentialRevision: UInt64 {
        library.transport.credentialSnapshotValue().revision
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
                    Button("重试") { retryRevision += 1 }
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
                    add(to: item)
                } label: {
                    if isAdding(to: item.id) {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "plus.circle")
                    }
                }
                .buttonStyle(.borderless)
                .disabled(isAddingSong)
                .frame(width: 36, height: 36)
                .help("添加到“\(item.playlist.name)”")
                .accessibilityLabel("添加到\(item.playlist.name)")
            }
        }
        .padding(.vertical, 4))
    }

    @MainActor
    private func load() async {
        let revision = credentialRevision
        guard model.currentUserID == userID else { return }
        phase = .loading
        do {
            var offset = 0
            var values: [MusicAvailablePlaylist] = []
            var seen = Set<Int64>()
            while true {
                let page = try await extras.availablePlaylists(
                    userID: userID,
                    trackID: song.id,
                    offset: offset,
                    expectedCredentialRevision: revision
                )
                try Task.checkCancellation()
                guard model.currentUserID == userID,
                      credentialRevision == revision
                else { return }
                let newValues = page.playlists.filter { seen.insert($0.id).inserted }
                values.append(contentsOf: newValues)
                phase = .loaded(values)
                guard page.hasMore, page.offset > offset,
                      !newValues.isEmpty
                else { break }
                offset = page.offset
            }
        } catch is CancellationError {
        } catch {
            guard model.currentUserID == userID,
                  credentialRevision == revision
            else { return }
            phase = .failed(error.localizedDescription)
        }
    }

    private func add(to item: MusicAvailablePlaylist) {
        failedPlaylist = nil
        operationError = nil
        model.addSongToPlaylist(
            song.id,
            playlistID: item.id,
            isFavoritePlaylist: item.playlist.specialType == 5,
            onFailure: { message in
                failedPlaylist = item
                operationError = message
            }
        )
    }

    private var isAddingSong: Bool {
        model.pendingMutations.contains { key in
            guard case let .playlistSong(_, songID) = key else { return false }
            return songID == song.id
        }
    }

    private func isAdding(to playlistID: Int64) -> Bool {
        model.pendingMutations.contains(.playlistSong(playlistID: playlistID, songID: song.id))
    }
}

struct RemoveSongFromPlaylistButton: View {
    let songID: Int64
    let playlistID: Int64
    let isFavoritePlaylist: Bool
    @Bindable var model: AppModel

    init(
        songID: Int64,
        playlistID: Int64,
        isFavoritePlaylist: Bool,
        model: AppModel
    ) {
        self.songID = songID
        self.playlistID = playlistID
        self.isFavoritePlaylist = isFavoritePlaylist
        self.model = model
    }

    var body: some View {
        Button(role: .destructive) {
            remove()
        } label: {
            Label("从歌单移除", systemImage: "trash")
        }
        .disabled(model.pendingMutations.contains(key))
    }

    private func remove() {
        model.removeSongFromPlaylist(
            songID,
            playlistID: playlistID,
            isFavoritePlaylist: isFavoritePlaylist
        )
    }

    private var key: LibraryMutationKey {
        .playlistSong(playlistID: playlistID, songID: songID)
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
