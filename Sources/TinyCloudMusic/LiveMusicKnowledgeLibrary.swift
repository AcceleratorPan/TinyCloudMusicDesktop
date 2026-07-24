import Foundation

enum MusicKnowledgeResource: Hashable, Sendable {
    case song(Int64)
    case album(Int64)
    case artist(Int64)
    case mv(Int64)
}

struct LiveMusicKnowledgeLibrary: Sendable {
    private static let interfaceHost = "https://interface.music.163.com"

    let transport: EAPITransport
    private let repository: LiveMusicRepository

    init(transport: EAPITransport = EAPITransport()) {
        self.transport = transport
        repository = LiveMusicRepository(transport: transport)
    }

    func styles() async throws -> [MusicStyle] {
        MusicKnowledgeDecoder.styles(try await weapi("/weapi/tag/list/get", payload: [:], cache: .detail))
    }

    func styleDetail(id: Int64, name: String) async throws -> MusicStyleDetail {
        guard id > 0 else { throw EAPIError.invalidPayload }
        return MusicKnowledgeDecoder.styleDetail(
            try await weapi("/weapi/style-tag/home/head", payload: ["tagId": id], cache: .detail),
            fallbackID: id,
            fallbackName: name
        )
    }

    func stylePage(
        id: Int64,
        kind: MusicStyleResourceKind,
        cursor: String? = nil,
        size: Int = 20,
        sort: Int = 0
    ) async throws -> MusicStylePage {
        guard id > 0, (1...50).contains(size), [0, 1].contains(sort) else {
            throw EAPIError.invalidPayload
        }
        let endpoint = switch kind {
        case .songs: "/weapi/style-tag/home/song"
        case .albums: "/weapi/style-tag/home/album"
        case .artists: "/weapi/style-tag/home/artist"
        case .playlists: "/weapi/style-tag/home/playlist"
        }
        let effectiveSort = kind == .songs || kind == .albums ? sort : 0
        let root = try await weapi(
            endpoint,
            payload: ["tagId": id, "cursor": cursor ?? "0", "size": size, "sort": effectiveSort],
            cache: .detail
        )
        return MusicKnowledgeDecoder.stylePage(root, kind: kind) { value in
            switch kind {
            case .songs: repository.decodeLiveSong(value).map(MusicStyleResource.song)
            case .albums: repository.decodeLiveAlbum(value).map(MusicStyleResource.album)
            case .artists: repository.decodeLiveArtist(value).map(MusicStyleResource.artist)
            case .playlists: repository.decodeLivePlaylist(value).map(MusicStyleResource.playlist)
            }
        }
    }

    func preferredStyleIDs() async throws -> [Int64] {
        MusicKnowledgeDecoder.preferredStyleIDs(
            try await weapi("/weapi/tag/my/preference/get", payload: [:], cache: .library)
        )
    }

    func sheets(songID: Int64) async throws -> [MusicSheetSummary] {
        guard songID > 0 else { throw EAPIError.invalidPayload }
        return MusicKnowledgeDecoder.sheets(try await eapi(
            "/eapi/music/sheet/list/v1",
            signing: "/api/music/sheet/list/v1",
            payload: ["id": songID, "abTest": "b"]
        ))
    }

    func sheetPreview(id: Int64) async throws -> MusicSheetPreview {
        guard id > 0 else { throw EAPIError.invalidPayload }
        return MusicKnowledgeDecoder.sheetPreview(try await eapi(
            "/eapi/music/sheet/preview/info",
            signing: "/api/music/sheet/preview/info",
            payload: ["id": id]
        ))
    }

    func knowledge(for resource: MusicKnowledgeResource) async throws -> [MusicKnowledgeBlock] {
        if case let .song(id) = resource {
            var blocks: [MusicKnowledgeBlock] = []
            var firstError: (any Error)?
            do {
                blocks += try await songWiki(songID: id)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                firstError = error
            }
            do {
                blocks += try await briefKnowledge(for: resource)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if blocks.isEmpty { throw firstError ?? error }
            }
            return blocks
        }

        return try await briefKnowledge(for: resource)
    }

    func songWiki(songID: Int64) async throws -> [MusicKnowledgeBlock] {
        guard songID > 0 else { throw EAPIError.invalidPayload }
        return MusicKnowledgeDecoder.songWikiBlocks(try await eapi(
            "/eapi/song/play/about/block/page",
            signing: "/api/song/play/about/block/page",
            payload: ["songId": songID]
        ))
    }

    func briefKnowledge(for resource: MusicKnowledgeResource) async throws -> [MusicKnowledgeBlock] {
        let (path, key, id): (String, String, Int64) = switch resource {
        case let .song(id): ("song", "songId", id)
        case let .album(id): ("album", "albumId", id)
        case let .artist(id): ("artist", "artistId", id)
        case let .mv(id): ("mv", "mvId", id)
        }
        guard id > 0 else { throw EAPIError.invalidPayload }

        return MusicKnowledgeDecoder.knowledgeBlocks(try await eapi(
            "/eapi/rep/ugc/\(path)/get",
            signing: "/api/rep/ugc/\(path)/get",
            payload: [key: id]
        ), prefix: "\(path)-ugc")
    }

    private func weapi(
        _ path: String,
        payload: [String: Any],
        cache: EAPIReadCache
    ) async throws -> [String: Any] {
        try decodedJSONObject(try await transport.requestWEAPI(
            path: path,
            payload: payload,
            cache: cache,
            invalidatesAccountCache: false
        ))
    }

    private func eapi(
        _ physicalPath: String,
        signing logicalPath: String,
        payload: [String: Any],
        cache: EAPIReadCache = .detail
    ) async throws -> [String: Any] {
        try decodedJSONObject(try await transport.request(
            EAPIEndpoint(physicalPath, signing: logicalPath, host: Self.interfaceHost),
            json: compactJSON(payload),
            cache: cache
        ))
    }
}
