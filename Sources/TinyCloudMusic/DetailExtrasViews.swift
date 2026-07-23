import SwiftUI

struct ArtistExtrasView: View {
    let artistID: Int64
    let extras: LiveMusicExtras
    let library: LiveMusicLibrary
    let onOpenRoute: (Route) -> Void
    let onFollowChanged: (Bool) -> Void
    let songList: AnyView

    @State private var phase: DetailExtrasPhase<ArtistExtrasSnapshot> = .loading
    @State private var selectedSection = ArtistDetailSection.songs
    @State private var reloadID = 0
    @State private var isUpdatingFollow = false
    @State private var followError: String?
    @State private var followTask: Task<Void, Never>?

    init(
        artistID: Int64,
        extras: LiveMusicExtras,
        library: LiveMusicLibrary,
        onOpenRoute: @escaping (Route) -> Void,
        onFollowChanged: @escaping (Bool) -> Void,
        songList: AnyView
    ) {
        self.artistID = artistID
        self.extras = extras
        self.library = library
        self.onOpenRoute = onOpenRoute
        self.onFollowChanged = onFollowChanged
        self.songList = songList
    }

    var body: AnyView { AnyView(content) }

    private var content: AnyView {
        AnyView(VStack(alignment: .leading, spacing: 16) {
            switch phase {
            case .loading:
                DetailExtrasStatusView(status: .loading("正在加载歌手内容"))
                songList
            case let .failed(message):
                DetailExtrasStatusView(status: .failed(message)) { reloadID += 1 }
                songList
            case let .loaded(snapshot):
                loadedContent(snapshot)
            }
        }
        .task(id: "\(artistID):\(reloadID)") { await load() }
        .onChange(of: artistID) { _, _ in
            selectedSection = .songs
            followTask?.cancel()
        }
        .onDisappear { followTask?.cancel() })
    }

    private func loadedContent(_ snapshot: ArtistExtrasSnapshot) -> AnyView {
        AnyView(Group {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("关注状态")
                        .font(.headline)
                    Text(followSummary(snapshot.followStatus))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    updateFollow(snapshot)
                } label: {
                    if isUpdatingFollow {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("更新中")
                        }
                    } else {
                        Label(
                            snapshot.followStatus.isFollowed ? "取消关注" : "关注歌手",
                            systemImage: snapshot.followStatus.isFollowed ? "person.badge.minus" : "person.badge.plus"
                        )
                    }
                }
                .buttonStyle(.bordered)
                .disabled(isUpdatingFollow)
                .frame(minHeight: 44)
                .accessibilityHint(snapshot.followStatus.isFollowed ? "取消关注这位歌手" : "关注这位歌手")
            }

            if let followError {
                Label(followError, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.red)
            }

            Picker("艺人主页内容", selection: $selectedSection) {
                ForEach(ArtistDetailSection.allCases, id: \.self) { section in
                    Label(section.rawValue, systemImage: section.symbol)
                        .tag(section)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 560)

            switch selectedSection {
            case .songs:
                songList
            case .albums:
                if snapshot.albums.isEmpty {
                    DetailExtrasStatusView(status: .empty("暂无专辑", "square.stack"))
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 12)], spacing: 8) {
                        ForEach(snapshot.albums) { item in
                            DetailExtrasNavigationRow(
                                title: item.album.name,
                                subtitle: item.isSubscribed ? "\(item.album.artist.name) · 已收藏" : item.album.artist.name,
                                imageURL: item.album.artwork.remoteURL,
                                symbol: "square.stack",
                                accessibilityHint: "打开专辑详情"
                            ) {
                                onOpenRoute(.album(item.album.id))
                            }
                        }
                    }
                }
            case .similarArtists:
                if snapshot.similarArtists.isEmpty {
                    DetailExtrasStatusView(status: .empty("暂无相似歌手", "music.mic"))
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 12)], spacing: 8) {
                        ForEach(snapshot.similarArtists) { artist in
                            DetailExtrasNavigationRow(
                                title: artist.name,
                                subtitle: artist.isFollowed ? "已关注" : "歌手",
                                imageURL: artist.imageURL,
                                symbol: "music.mic",
                                accessibilityHint: "打开歌手详情"
                            ) {
                                onOpenRoute(.artist(artist.id))
                            }
                        }
                    }
                }
            }
        })
    }

    @MainActor
    private func load() async {
        phase = .loading
        followError = nil
        do {
            async let albums = extras.artistAlbums(artistID: artistID)
            async let followStatus = extras.artistFollowStatus(artistID: artistID)
            async let similarArtists = library.similarArtists(to: artistID)
            let result = try await (albums, followStatus, similarArtists)
            try Task.checkCancellation()
            phase = .loaded(
                ArtistExtrasSnapshot(
                    albums: result.0.albums,
                    followStatus: result.1,
                    similarArtists: result.2
                )
            )
        } catch is CancellationError {
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private func updateFollow(_ snapshot: ArtistExtrasSnapshot) {
        let target = !snapshot.followStatus.isFollowed
        followError = nil
        isUpdatingFollow = true
        followTask?.cancel()
        followTask = Task { @MainActor in
            do {
                try await library.setArtistFollowed(artistID, followed: target)
                try Task.checkCancellation()
                guard case var .loaded(current) = phase else {
                    isUpdatingFollow = false
                    return
                }
                current.followStatus = MusicArtistFollowStatus(
                    isFollowed: target,
                    followerCount: max(0, current.followStatus.followerCount + (target ? 1 : -1)),
                    followDay: target ? current.followStatus.followDay : ""
                )
                phase = .loaded(current)
                onFollowChanged(target)
            } catch is CancellationError {
            } catch {
                followError = error.localizedDescription
            }
            isUpdatingFollow = false
        }
    }

    private func followSummary(_ status: MusicArtistFollowStatus) -> String {
        let count = "\(status.followerCount) 位关注者"
        return status.isFollowed && !status.followDay.isEmpty ? "\(status.followDay) · \(count)" : count
    }
}

private enum ArtistDetailSection: String, CaseIterable {
    case songs = "歌曲"
    case albums = "专辑"
    case similarArtists = "相似歌手"

    var symbol: String {
        switch self {
        case .songs: "music.note"
        case .albums: "square.stack"
        case .similarArtists: "music.mic"
        }
    }
}

struct PlaylistExtrasView: View {
    let phase: DetailExtrasPhase<[MusicLibraryPlaylist]>
    let onRetry: () -> Void
    let onOpenRoute: (Route) -> Void

    var body: AnyView { AnyView(content) }

    private var content: AnyView {
        AnyView(VStack(alignment: .leading, spacing: 10) {
            switch phase {
            case .loading:
                Text("相似歌单")
                    .font(.title3.weight(.semibold))
                DetailExtrasStatusView(status: .loading("正在加载相似歌单"))
            case let .failed(message):
                Text("相似歌单")
                    .font(.title3.weight(.semibold))
                DetailExtrasStatusView(status: .failed(message), retry: onRetry)
            case let .loaded(playlists):
                if !playlists.isEmpty {
                    Text("相似歌单")
                        .font(.title3.weight(.semibold))
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 12)], spacing: 8) {
                        ForEach(playlists) { playlist in
                            DetailExtrasNavigationRow(
                                title: playlist.name,
                                subtitle: playlist.creatorName.isEmpty ? "歌单" : playlist.creatorName,
                                imageURL: playlist.coverURL,
                                symbol: "music.note.list",
                                accessibilityHint: "打开歌单详情"
                            ) {
                                onOpenRoute(.playlist(playlist.id))
                            }
                        }
                    }
                }
            }
        })
    }
}

struct UserRelationsView: View {
    let userID: Int64
    let library: LiveMusicLibrary
    let section: UserRelationSection
    let onOpenRoute: (Route) -> Void

    @State private var phase: DetailExtrasPhase<UserRelationsSnapshot> = .loading
    @State private var reloadID = 0

    init(
        userID: Int64,
        library: LiveMusicLibrary,
        section: UserRelationSection,
        onOpenRoute: @escaping (Route) -> Void
    ) {
        self.userID = userID
        self.library = library
        self.section = section
        self.onOpenRoute = onOpenRoute
    }

    var body: AnyView { AnyView(content) }

    private var content: AnyView {
        AnyView(VStack(alignment: .leading, spacing: 12) {
            switch phase {
            case .loading:
                DetailExtrasStatusView(status: .loading("正在加载关注关系"))
            case let .failed(message):
                if message.contains("隐私") {
                    DetailExtrasStatusView(status: .empty(message, "eye.slash"))
                } else {
                    DetailExtrasStatusView(status: .failed(message)) { reloadID += 1 }
                }
            case let .loaded(snapshot):
                if snapshot.users.isEmpty && snapshot.artists.isEmpty {
                    DetailExtrasStatusView(status: .empty("暂无公开关注", "person.2"))
                } else {
                    relations(snapshot)
                }
            }
        }
        .task(id: "\(userID):\(reloadID)") { await load() })
    }

    private func relations(_ snapshot: UserRelationsSnapshot) -> AnyView {
        AnyView(Group {
            switch section {
            case .users:
                if snapshot.users.isEmpty {
                    DetailExtrasStatusView(status: .empty("暂无公开用户", "person.crop.circle"))
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 12)], spacing: 8) {
                        ForEach(snapshot.users) { user in
                            DetailExtrasNavigationRow(
                                title: user.nickname,
                                subtitle: user.signature.isEmpty ? "用户" : user.signature,
                                imageURL: user.avatarURL,
                                symbol: "person.crop.circle",
                                accessibilityHint: "打开用户详情"
                            ) {
                                onOpenRoute(.user(user.id))
                            }
                        }
                    }
                }
            case .artists:
                if snapshot.artists.isEmpty {
                    DetailExtrasStatusView(status: .empty("暂无公开歌手", "music.mic"))
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 12)], spacing: 8) {
                        ForEach(snapshot.artists) { artist in
                            DetailExtrasNavigationRow(
                                title: artist.name,
                                subtitle: artist.isFollowed ? "已关注" : "歌手",
                                imageURL: artist.imageURL,
                                symbol: "music.mic",
                                accessibilityHint: "打开歌手详情"
                            ) {
                                onOpenRoute(.artist(artist.id))
                            }
                        }
                    }
                }
            }
        })
    }

    @MainActor
    private func load() async {
        phase = .loading
        do {
            async let users = library.followingUsers(userID: userID)
            async let artists = library.followedArtists(userID: userID)
            let result = try await (users, artists)
            try Task.checkCancellation()
            phase = .loaded(UserRelationsSnapshot(users: result.0, artists: result.1))
        } catch is CancellationError {
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }
}

enum UserRelationSection {
    case users
    case artists
}

struct SimilarSongsView: View {
    let sourceSong: Song
    @Bindable private var model: AppModel
    let library: LiveMusicLibrary
    @Bindable private var player: PlayerController

    @State private var phase: DetailExtrasPhase<[Song]> = .loading
    @State private var reloadID = 0
    @State private var visibleCount = 20

    init(sourceSong: Song, model: AppModel, library: LiveMusicLibrary, player: PlayerController) {
        self.sourceSong = sourceSong
        self.model = model
        self.library = library
        self.player = player
    }

    var body: AnyView { AnyView(content) }

    private var content: AnyView {
        AnyView(ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                Text("由「\(sourceSong.artistsDisplay) - \(sourceSong.name)」相似推荐")
                    .font(.title3.weight(.semibold))
                switch phase {
                case .loading:
                    DetailExtrasStatusView(status: .loading("正在加载相似歌曲"))
                case let .failed(message):
                    DetailExtrasStatusView(status: .failed(message)) { reloadID += 1 }
                case let .loaded(songs):
                    if songs.isEmpty {
                        DetailExtrasStatusView(status: .empty("暂无相似歌曲", "music.note"))
                    } else {
                        ForEach(songs.prefix(visibleCount)) { song in
                            HStack(spacing: 10) {
                                DetailExtrasRemoteImage(url: song.album.artwork.remoteURL, symbol: "music.note", size: 40)
                                VStack(alignment: .leading, spacing: 2) {
                                    SongTitleText(song: song)
                                        .font(.body.weight(.medium))
                                        .lineLimit(1)
                                    SongMetadataLinks(song: song, onOpenRoute: model.open)
                                }
                                Spacer(minLength: 8)
                                Text(song.durationText)
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                Button {
                                    player.play(song, in: songs)
                                } label: {
                                    Image(
                                        systemName: player.currentSong?.id == song.id && player.isPlaying
                                            ? "speaker.wave.2.fill"
                                            : "play.fill"
                                    )
                                    .frame(width: 20, height: 20)
                                }
                                .buttonStyle(.borderless)
                                .frame(width: 44, height: 44)
                                .help("播放 \(song.name)")
                                .accessibilityLabel("播放 \(song.name)")
                            }
                            .frame(minHeight: 52)
                            .contentShape(Rectangle())
                            .onTapGesture(count: 2) { player.play(song, in: songs) }
                            .contextMenu {
                                SongContextMenu(song: song, songs: songs, model: model, player: player)
                            }
                            Divider().padding(.leading, 50)
                        }
                        if visibleCount < songs.count {
                            LoadMoreTrigger(title: "正在显示更多…") {
                                visibleCount = min(visibleCount + 20, songs.count)
                            }
                            .id(visibleCount)
                        }
                    }
                }
            }
            .padding(24)
        }
        .task(id: "\(sourceSong.id):\(reloadID)") { await load() })
    }

    @MainActor
    private func load() async {
        phase = .loading
        visibleCount = 20
        do {
            let songs = try await library.similarSongs(to: sourceSong.id)
            try Task.checkCancellation()
            phase = .loaded(songs)
        } catch is CancellationError {
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }
}

struct PlaybackQualityButton: View {
    let songID: Int64
    let repository: any MusicRepository
    @Bindable var player: PlayerController

    @State private var isPresented = false
    @State private var phase: DetailExtrasPhase<[SongQualityDetail]> = .loading
    @State private var reloadID = 0

    var body: some View {
        PlayerIconButton(
            symbol: "waveform.badge.magnifyingglass",
            label: "选择播放音质",
            isActive: isPresented || player.isSwitchingPlaybackQuality
        ) {
            isPresented.toggle()
        }
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            popoverContent
                .task(id: "\(songID):\(reloadID)") { await load() }
        }
    }

    private var popoverContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("播放音质")
                .font(.headline)
            switch phase {
            case .loading:
                DetailExtrasStatusView(status: .loading("正在加载音质信息"))
            case let .failed(message):
                DetailExtrasStatusView(status: .failed(message)) { reloadID += 1 }
            case let .loaded(qualities):
                if qualities.isEmpty {
                    DetailExtrasStatusView(status: .empty("暂无音质信息", "waveform.slash"))
                } else {
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(qualities.sorted { $0.rank > $1.rank }) { quality in
                                qualityButton(quality)
                            }
                        }
                    }
                    .frame(height: min(CGFloat(qualities.count) * 46, 414))
                }
            }
            if let message = player.playbackQualityErrorMessage {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(width: 320)
    }

    private func qualityButton(_ quality: SongQualityDetail) -> some View {
        let isSelected = player.currentPlaybackLevel == quality.id
        let isPending = player.isSwitchingPlaybackQuality && player.selectedPlaybackLevel == quality.id
        return Button {
            player.selectPlaybackQuality(quality)
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(quality.name)
                        .font(.body.weight(.medium))
                        .foregroundStyle(quality.isAvailable ? Color.primary : Color.secondary)
                    Text(qualityDescription(quality))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if !quality.isAvailable {
                    Image(systemName: "lock.fill")
                        .foregroundStyle(.primary)
                } else if isPending {
                    ProgressView().controlSize(.small)
                } else if isSelected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.red)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!quality.isAvailable || isSelected || isPending)
        .accessibilityLabel("\(quality.name)，\(qualityDescription(quality))")
        .accessibilityValue(quality.isAvailable ? (isSelected ? "当前音质" : "可用") : "当前账号不可用")
    }

    private func qualityDescription(_ quality: SongQualityDetail) -> String {
        let sampleRate = (Double(quality.sampleRate) / 1_000)
            .formatted(.number.precision(.fractionLength(0...1)))
        let size = ByteCountFormatter.string(fromByteCount: quality.size, countStyle: .file)
        return "\(quality.bitrate / 1_000) kbps · \(sampleRate) kHz · \(size)"
    }

    @MainActor
    private func load() async {
        phase = .loading
        do {
            let qualities = try await repository.songQualityDetails(for: songID)
            try Task.checkCancellation()
            phase = .loaded(qualities)
        } catch is CancellationError {
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }
}

enum DetailExtrasPhase<Value> {
    case loading
    case loaded(Value)
    case failed(String)
}

private struct ArtistExtrasSnapshot {
    let albums: [MusicArtistAlbum]
    var followStatus: MusicArtistFollowStatus
    let similarArtists: [MusicLibraryArtist]
}

private struct UserRelationsSnapshot {
    let users: [MusicLibraryUser]
    let artists: [MusicLibraryArtist]
}

private enum DetailExtrasStatus {
    case loading(String)
    case empty(String, String)
    case failed(String)
}

private struct DetailExtrasStatusView: View {
    let status: DetailExtrasStatus
    let retry: (() -> Void)?

    init(status: DetailExtrasStatus, retry: (() -> Void)? = nil) {
        self.status = status
        self.retry = retry
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            switch status {
            case let .loading(message):
                ProgressView()
                    .controlSize(.small)
                Text(message)
                    .foregroundStyle(.secondary)
            case let .empty(message, symbol):
                Image(systemName: symbol)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(message)
                    .foregroundStyle(.secondary)
            case let .failed(message):
                Image(systemName: "wifi.exclamationmark")
                    .foregroundStyle(.red)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("加载失败")
                        .font(.callout.weight(.semibold))
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            if let retry {
                Button(action: retry) {
                    Label("重试", systemImage: "arrow.clockwise")
                }
                .frame(minHeight: 44)
                .accessibilityHint("重新加载这一部分")
            }
        }
        .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
    }
}

private struct DetailExtrasNavigationRow: View {
    let title: String
    let subtitle: String
    let imageURL: URL?
    let symbol: String
    let accessibilityHint: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                DetailExtrasRemoteImage(url: imageURL, symbol: symbol, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.body.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(subtitle.isEmpty ? title : "\(title)，\(subtitle)")
        .accessibilityHint(accessibilityHint)
    }
}

private struct DetailExtrasRemoteImage: View {
    let url: URL?
    let symbol: String
    let size: CGFloat

    var body: some View {
        CachedAsyncImage(url: url) { phase in
            switch phase {
            case let .success(image):
                image.resizable().scaledToFill()
            case .empty:
                ProgressView().controlSize(.mini)
            case .failure:
                Image(systemName: symbol)
                    .foregroundStyle(.secondary)
            @unknown default:
                Image(systemName: symbol)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .background(.quaternary)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .accessibilityHidden(true)
    }
}
