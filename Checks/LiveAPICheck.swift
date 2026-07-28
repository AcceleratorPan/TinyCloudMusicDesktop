import Foundation

@main
enum LiveAPICheck {
    static func main() async {
        let environment = ProcessInfo.processInfo.environment
        let cookie = environment["TINYCLOUDMUSIC_COOKIE"] ?? ""
        let musicU = environment["TINYCLOUDMUSIC_MUSIC_U"] ?? ""
        let hasAccountCredentials = !cookie.isEmpty || !musicU.isEmpty
        let repository = LiveMusicRepository(transport: EAPITransport(
            cookie: cookie,
            musicU: musicU
        ))
        let library = LiveMusicLibrary(transport: repository.transport)
        let audioLibrary = LiveAudioContentLibrary(transport: repository.transport)
        let knowledgeLibrary = LiveMusicKnowledgeLibrary(transport: repository.transport)
        let extras = LiveMusicExtras(transport: repository.transport)
        var passed: [String] = []
        var failed: [String] = []
        var skipped: [String] = []

        func check<T>(
            _ name: String,
            required: Bool = true,
            _ operation: () async throws -> T
        ) async -> T? {
            do {
                let value = try await operation()
                passed.append(name)
                return value
            } catch {
                if required {
                    failed.append("\(name): \(errorText(error))")
                } else {
                    skipped.append("\(name): \(errorText(error))")
                }
                return nil
            }
        }

        let podcastCategories = await check("audio.podcastCategories") {
            let values = try await audioLibrary.podcastCategories()
            guard !values.isEmpty else { throw EAPIError.missingData("categories") }
            return values
        }
        if let category = podcastCategories?.first,
           let podcasts = await check("audio.recommendedPodcasts", {
               let values = try await audioLibrary.recommendedPodcasts(categoryID: category.id)
               guard !values.isEmpty else { throw EAPIError.missingData("djRadios") }
               return values
           }),
           let podcast = podcasts.first {
            _ = await check("audio.podcastDetail") { try await audioLibrary.podcast(id: podcast.id) }
            _ = await check("audio.podcastEpisodes") {
                try await audioLibrary.podcastEpisodes(podcastID: podcast.id)
            }
        }
        _ = await check("audio.broadcastFilters") {
            let values = try await audioLibrary.broadcastFilters()
            guard !values.categories.isEmpty || !values.regions.isEmpty else {
                throw EAPIError.missingData("data")
            }
            return values
        }
        if let channels = await check("audio.broadcastChannels", {
            let page = try await audioLibrary.broadcastChannels()
            guard !page.channels.isEmpty else { throw EAPIError.missingData("channels") }
            return page.channels
        }) {
            var checkedStreams = 0
            for channel in channels {
                do {
                    let current = try await audioLibrary.broadcastCurrentInfo(channelID: channel.id)
                    guard let streamURL = current.streamURL else { continue }
                    _ = try await BroadcastStreamURLPolicy.playableURL(streamURL.absoluteString)
                    checkedStreams += 1
                } catch EAPIError.service(400, let message) where message.contains("下架") {
                    skipped.append("audio.broadcastCurrentInfo: \(message)")
                } catch AudioContentError.unavailable(let message) {
                    skipped.append("audio.broadcastCurrentInfo: \(message)")
                } catch {
                    let host = (try? await broadcastStreamHost(
                        transport: repository.transport,
                        channelID: channel.id
                    )) ?? "unknown"
                    failed.append("audio.broadcastCurrentInfo: \(errorText(error)) (host: \(host))")
                }
            }
            if checkedStreams > 0 {
                passed.append("audio.broadcastCurrentInfo")
            }
        }

        let keywords = await check("search.default") { try await extras.defaultSearchKeywords() }
        _ = await check("search.suggest") { try await extras.searchSuggestions(for: keywords?.first?.query ?? "周杰伦") }
        _ = await check("search.hot") {
            let items = try await extras.hotSearch()
            guard !items.isEmpty else { throw EAPIError.missingData("data") }
            return items
        }
        _ = await check("search.multimatch") {
            let matches = try await extras.searchDirectMatches(for: "周杰伦")
            guard !matches.isEmpty else { throw EAPIError.missingData("result") }
            return matches
        }

        let songPage = await check("search.song") {
            try await repository.search(query: "周杰伦", scope: .songs, offset: 0, limit: 20)
        }
        let artistPage = await check("search.artist") {
            try await repository.search(query: "周杰伦", scope: .artists, offset: 0, limit: 20)
        }
        let albumPage = await check("search.album") {
            try await repository.search(query: "周杰伦", scope: .albums, offset: 0, limit: 20)
        }
        let playlistPage = await check("search.playlist") {
            try await repository.search(query: "周杰伦", scope: .playlists, offset: 0, limit: 20)
        }
        let userPage = await check("search.user") {
            try await repository.search(query: "网易云音乐", scope: .users, offset: 0, limit: 20)
        }

        let song = songPage?.items.compactMap { item -> Song? in
            guard case let .song(value) = item else { return nil }
            return value
        }.first
        let artist = artistPage?.items.compactMap { item -> Artist? in
            guard case let .artist(value) = item else { return nil }
            return value
        }.first
        let album = albumPage?.items.compactMap { item -> Album? in
            guard case let .album(value) = item else { return nil }
            return value
        }.first
        let playlist = playlistPage?.items.compactMap { item -> Playlist? in
            guard case let .playlist(value) = item else { return nil }
            return value
        }.first
        let user = userPage?.items.compactMap { item -> UserProfile? in
            guard case let .user(value) = item else { return nil }
            return value
        }.first

        _ = await check("song.lyric.word", required: false) {
            let lyrics = try await repository.lyrics(for: 186_016)
            guard lyrics.wordLyrics?.isEmpty == false else { throw EAPIError.missingData("yrc.lyric") }
        }

        if let song {
            _ = await check("song.lyric") { try await repository.lyrics(for: song.id) }
            if let source = await check("song.playerSource", { try await repository.playbackSource(for: song.id, quality: .standard) }) {
                _ = await check("song.audioBytes") { try await audioBytes(from: source.url) }
            }
            _ = await check("song.qualityDetails") { try await repository.songQualityDetails(for: song.id) }
            _ = await check("song.copyrightAlternatives") { try await repository.copyrightAlternatives(for: 27_946_878) }
            if let comments = await check("comment.list", { try await library.comments(songID: song.id) }),
               let parent = comments.comments.first(where: { $0.replyCount > 0 }) {
                _ = await check("comment.floor") {
                    try await library.commentFloor(songID: song.id, parentCommentID: parent.id)
                }
            } else {
                skipped.append("comment.floor: no parent comment with replies")
            }
            _ = await check("similar.song") { try await library.similarSongs(to: song.id) }
        } else {
            failed.append("search.song: no decodable song")
        }

        if let artist {
            _ = await check("detail.artist") { try await repository.detail(for: .artist(artist.id)) }
            _ = await check("artist.albums") { try await extras.artistAlbums(artistID: artist.id) }
            _ = await check("artist.followStatus") { try await extras.artistFollowStatus(artistID: artist.id) }
            _ = await check("similar.artist", required: hasAccountCredentials) {
                try await library.similarArtists(to: artist.id)
            }
        } else {
            failed.append("search.artist: no decodable artist")
        }

        if let album {
            _ = await check("detail.album") { try await repository.detail(for: .album(album.id)) }
            _ = await check("album.subscription") { try await extras.albumSubscription(albumID: album.id) }
        } else {
            failed.append("search.album: no decodable album")
        }

        if let playlist {
            _ = await check("detail.playlist") { try await repository.detail(for: .playlist(playlist.id)) }
            _ = await check("similar.playlist") { try await library.similarPlaylists(to: playlist.id) }
        } else {
            failed.append("search.playlist: no decodable playlist")
        }

        if let user {
            _ = await check("detail.user") { try await repository.detail(for: .user(user.id)) }
            _ = await check("user.playlists") { try await extras.userPlaylists(userID: user.id) }
            _ = await check("user.followingUsers") { try await library.followingUsers(userID: user.id, size: 20) }
            _ = await check("user.followedArtists", required: hasAccountCredentials) {
                try await library.followedArtists(userID: user.id, limit: 20)
            }
        } else {
            failed.append("search.user: no decodable user")
        }

        for descriptor in repository.homeDescriptors {
            _ = await check("home.\(descriptor.id)", required: hasAccountCredentials) {
                try await repository.homeSection(id: descriptor.id)
            }
        }

        let styles = await check("knowledge.styles") {
            let values = try await knowledgeLibrary.styles()
            guard !values.isEmpty else { throw EAPIError.missingData("styles") }
            return values
        }
        if let style = styles?.first(where: { !$0.children.isEmpty })?.children.first ?? styles?.first {
            _ = await check("knowledge.stylePlaylists") {
                let page = try await knowledgeLibrary.stylePage(id: style.id, kind: .playlists)
                guard !page.items.isEmpty else { throw EAPIError.missingData("playlist") }
                guard page.items.allSatisfy({ item in
                    guard case let .playlist(playlist) = item else { return false }
                    return playlist.artwork.remoteURL != nil
                }) else { throw EAPIError.missingData("playlist artwork") }
                return page
            }
        }

        let login = await check("account.loginState") { try await library.loginState() }
        if case let .loggedIn(account)? = login {
            _ = await check("account.dailyRecommendations") { try await library.dailyRecommendations() }
            let fmModes: [PersonalFMMode] = [
                .standard, .familiar, .explore,
                .scene(.exercise), .scene(.focus), .scene(.night)
            ]
            for mode in fmModes {
                _ = await check("account.personalFM.\(mode.requestValues.mode).\(mode.requestValues.subMode)") {
                    let tracks = try await library.personalFM(mode: mode)
                    guard !tracks.isEmpty else { throw EAPIError.missingData("data") }
                    return tracks
                }
            }
            _ = await check("account.recentlyPlayedSongs") { try await library.recentlyPlayedSongs() }
            _ = await check("account.recentlyPlayedAlbums") { try await library.recentlyPlayedAlbums() }
            _ = await check("account.recentlyPlayedPlaylists") { try await library.recentlyPlayedPlaylists() }
            _ = await check("account.recentlyPlayedVideos") { try await library.recentlyPlayedVideos() }
            _ = await check("account.recentlyPlayedVoices") { try await library.recentlyPlayedVoices() }
            _ = await check("account.recentlyPlayedPodcasts") { try await library.recentlyPlayedPodcasts() }
            _ = await check("account.listeningRecords.week") {
                try await library.listeningRecords(userID: account.id, period: .week)
            }
            _ = await check("account.listeningRecords.allTime") {
                try await library.listeningRecords(userID: account.id, period: .allTime)
            }
            do {
                _ = try await library.totalListeningDuration()
                passed.append("account.totalListeningDuration")
            } catch {
                skipped.append("account.totalListeningDuration: unavailable for this account")
            }
            _ = await check("account.favoriteSongIDs") { try await extras.favoriteSongIDs(userID: account.id) }
            _ = await check("account.myFollowing") { try await library.myFollowing(size: 20) }
            _ = await check("account.recommendedUsers") { try await extras.recommendedUsers() }
            _ = await check("account.vipStatus") { try await library.hasActiveVIP() }
            if let song {
                _ = await check("account.availablePlaylists") {
                    try await extras.availablePlaylists(userID: account.id, trackID: song.id)
                }
            }
            if ProcessInfo.processInfo.environment["TINYCLOUDMUSIC_MUTATING_API_CHECK"] == "YES", let song {
                await runMutatingChecks(
                    library: library,
                    extras: extras,
                    account: account,
                    song: song,
                    artist: artist,
                    album: album,
                    playlist: playlist,
                    user: user,
                    passed: &passed,
                    failed: &failed,
                    skipped: &skipped
                )
            } else {
                skipped.append("account.write: set TINYCLOUDMUSIC_MUTATING_API_CHECK=YES with a dedicated test account")
            }
        } else {
            skipped.append("account.authenticatedReads: no valid authorized session")
            skipped.append("account.write: no dedicated authorized test account")
        }

        print("Live API checks: passed=\(passed.count), failed=\(failed.count), skipped=\(skipped.count)")
        if !skipped.isEmpty { print("Skipped: \(skipped.joined(separator: " | "))") }
        if !failed.isEmpty {
            print("Failed: \(failed.joined(separator: " | "))")
            exit(1)
        }
    }

    private static func audioBytes(from url: URL) async throws {
        var request = URLRequest(url: url)
        request.setValue("bytes=0-4095", forHTTPHeaderField: "Range")
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let response = response as? HTTPURLResponse,
              [200, 206].contains(response.statusCode),
              try await bytes.first(where: { _ in true }) != nil
        else { throw EAPIError.invalidResponse }
    }

    private static func broadcastStreamHost(
        transport: EAPITransport,
        channelID: String
    ) async throws -> String {
        let root = try decodedJSONObject(try await transport.request(
            EAPIEndpoint(
                "/eapi/voice/broadcast/channel/currentinfo",
                signing: "/api/voice/broadcast/channel/currentinfo",
                host: "https://interface.music.163.com"
            ),
            json: compactJSON(["channelId": channelID])
        ))
        let data = root.object("data")
        let current = data.object("currentInfo").isEmpty ? data : data.object("currentInfo")
        for object in [current.object("playInfo"), current, data, root] {
            for key in ["playUrl", "streamUrl", "liveUrl", "url"] {
                if let host = URL(string: object.string(key))?.host { return host }
            }
        }
        throw EAPIError.missingData("stream host")
    }

    private static func errorText(_ error: Error) -> String {
        if case let EAPIError.service(code, message) = error {
            return "service \(code)\(message.isEmpty ? "" : ": \(message)")"
        }
        return error.localizedDescription
    }

    private static func runMutatingChecks(
        library: LiveMusicLibrary,
        extras: LiveMusicExtras,
        account: MusicLibraryUser,
        song: Song,
        artist: Artist?,
        album: Album?,
        playlist: Playlist?,
        user: UserProfile?,
        passed: inout [String],
        failed: inout [String],
        skipped: inout [String]
    ) async {
        do {
            let id = try await library.createPlaylist(name: "Tiny Cloud Music API Check \(UUID().uuidString.prefix(8))")
            do {
                try await library.updatePlaylistName(id, name: "Tiny Cloud Music \"Edit\" 🎵")
                try await library.updatePlaylistDescription(id, description: "line 1\nline 2")
                try await library.updatePlaylistTags(id, tags: ["学习", "华语"])
                try await library.addSongs([song.id], to: id)
                try await library.removeSongs([song.id], from: id)
                try await library.deletePlaylist(id)
                passed += [
                    "write.playlistCreate",
                    "write.playlistName",
                    "write.playlistDescription",
                    "write.playlistTags",
                    "write.playlistAdd",
                    "write.playlistRemove",
                    "write.playlistDelete"
                ]
            } catch {
                try? await library.deletePlaylist(id)
                throw error
            }
        } catch {
            failed.append("write.playlistLifecycle: \(error.localizedDescription)")
        }

        let liked = (try? await extras.favoriteSongIDs(userID: account.id).contains(song.id)) ?? false
        await reversible("write.songLike", initial: liked, set: { try await library.setSongLiked(song.id, liked: $0) }, passed: &passed, failed: &failed)
        if let artist, let state = try? await extras.artistFollowStatus(artistID: artist.id) {
            await reversible("write.artistFollow", initial: state.isFollowed, set: { try await library.setArtistFollowed(artist.id, followed: $0) }, passed: &passed, failed: &failed)
        } else { skipped.append("write.artistFollow: no fixture") }
        if let album, let state = try? await extras.albumSubscription(albumID: album.id) {
            await reversible("write.albumSubscribe", initial: state.isSubscribed, set: { try await library.setAlbumSubscribed(album.id, subscribed: $0) }, passed: &passed, failed: &failed)
        } else { skipped.append("write.albumSubscribe: no fixture") }
        if let playlist {
            await reversible("write.playlistSubscribe", initial: playlist.isSubscribed, set: { try await library.setPlaylistSubscribed(playlist.id, subscribed: $0) }, passed: &passed, failed: &failed)
        } else { skipped.append("write.playlistSubscribe: no fixture") }
        if let user {
            await reversible("write.userFollow", initial: user.isFollowed, set: { try await library.setUserFollowed(user.id, followed: $0) }, passed: &passed, failed: &failed)
        } else { skipped.append("write.userFollow: no fixture") }
    }

    private static func reversible(
        _ name: String,
        initial: Bool,
        set: (Bool) async throws -> Void,
        passed: inout [String],
        failed: inout [String]
    ) async {
        do {
            try await set(!initial)
            try await set(initial)
            passed.append(name)
        } catch {
            try? await set(initial)
            failed.append("\(name): \(error.localizedDescription)")
        }
    }
}
