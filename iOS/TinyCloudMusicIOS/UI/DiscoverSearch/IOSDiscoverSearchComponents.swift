import SwiftUI

struct IOSSongRow: View {
    let song: Song
    let songs: [Song]
    var allSongIDs: [Int64]?
    var playlistID: Int64?
    @Bindable var model: AppModel
    @Bindable var player: PlayerController

    var body: some View {
        HStack(spacing: 8) {
            Button(action: play) {
                HStack(spacing: 12) {
                    IOSArtworkView(artwork: song.album.artwork)
                        .frame(width: 52, height: 52)
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
                IOSSongActionsMenu(
                    song: song,
                    songs: songs,
                    allSongIDs: allSongIDs,
                    playlistID: playlistID,
                    model: model,
                    player: player
                )
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("\(song.name)的更多操作")
        }
        .frame(minHeight: 68)
        .contextMenu {
            IOSSongActionsMenu(
                song: song,
                songs: songs,
                allSongIDs: allSongIDs,
                playlistID: playlistID,
                model: model,
                player: player
            )
        }
    }

    private func play() {
        player.play(song, in: songs, allSongIDs: allSongIDs, playlistID: playlistID)
    }
}

struct IOSSongActionsMenu: View {
    let song: Song
    let songs: [Song]
    var allSongIDs: [Int64]?
    var playlistID: Int64?
    @Bindable var model: AppModel
    @Bindable var player: PlayerController

    var body: some View {
        Button {
            player.play(song, in: songs, allSongIDs: allSongIDs, playlistID: playlistID)
        } label: {
            Label("播放", systemImage: "play.fill")
        }
        Button { player.appendToQueue([song]) } label: {
            Label("稍后播放", systemImage: "text.badge.plus")
        }
        Button { model.toggleSongLiked(song.id) } label: {
            Label(
                model.likedSongIDs.contains(song.id) ? "取消喜欢" : "喜欢",
                systemImage: model.likedSongIDs.contains(song.id) ? "heart.slash" : "heart"
            )
        }
        .disabled(model.currentUserID == nil || model.pendingMutations.contains(.songLike(song.id)))
        Button { model.showAddToPlaylist(for: song) } label: {
            Label("添加到歌单", systemImage: "music.note.list")
        }
        .disabled(model.currentUserID == nil)
        Button { model.download(song) } label: {
            Label("下载", systemImage: "arrow.down.circle")
        }
        .disabled(model.downloads == nil)

        Divider()
        if !song.artists.isEmpty {
            Menu {
                ForEach(song.artists) { artist in
                    Button { model.open(.artist(artist.id)) } label: {
                        Label(artist.name, systemImage: "music.mic")
                    }
                }
            } label: {
                Label("查看歌手", systemImage: "music.mic")
            }
        }
        Button { model.open(.album(song.album.id)) } label: {
            Label("查看专辑", systemImage: "square.stack")
        }
        Button { model.open(.similarSongs(song)) } label: {
            Label("相似歌曲", systemImage: "waveform.badge.magnifyingglass")
        }
        Button { model.open(.comments(song.id)) } label: {
            Label("评论", systemImage: "bubble.left")
        }
    }
}

struct IOSSongList: View {
    let songs: [Song]
    var allSongIDs: [Int64]?
    var playlistID: Int64?
    @Bindable var model: AppModel
    @Bindable var player: PlayerController
    var hasMore = false
    var isLoadingMore = false
    var loadMoreError: String?
    var onLoadMore: () -> Void = {}

    var body: some View {
        LazyVStack(spacing: 0) {
            ForEach(songs) { song in
                IOSSongRow(
                    song: song,
                    songs: songs,
                    allSongIDs: allSongIDs,
                    playlistID: playlistID,
                    model: model,
                    player: player
                )
                Divider().padding(.leading, 64)
            }
            if let loadMoreError {
                IOSInlineRetry(message: loadMoreError, action: onLoadMore)
            } else if hasMore {
                HStack(spacing: 10) {
                    if isLoadingMore {
                        ProgressView()
                        Text("正在载入更多歌曲")
                            .foregroundStyle(.secondary)
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

struct IOSInlineRetry: View {
    let message: String
    let action: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("重试", action: action)
                .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, minHeight: 88)
        .padding(.vertical, 8)
    }
}

struct IOSPressedButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.72 : 1)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
