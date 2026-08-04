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

    func preferredStyleIDs(expectedCredentialRevision: UInt64) async throws -> [Int64] {
        MusicKnowledgeDecoder.preferredStyleIDs(
            try await weapi(
                "/weapi/tag/my/preference/get",
                payload: [:],
                cache: .library,
                expectedCredentialRevision: expectedCredentialRevision
            )
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
            return try await Self.combinedSongKnowledge(
                wiki: { try await songWiki(songID: id) },
                brief: { try await briefKnowledge(for: resource) }
            )
        }

        return try await briefKnowledge(for: resource)
    }

    static func combinedSongKnowledge(
        wiki: @escaping @Sendable () async throws -> [MusicKnowledgeBlock],
        brief: @escaping @Sendable () async throws -> [MusicKnowledgeBlock]
    ) async throws -> [MusicKnowledgeBlock] {
        try await withThrowingTaskGroup(of: MusicKnowledgePartResult.self) { group in
            group.addTask { .wiki(await musicKnowledgeResult(wiki)) }
            group.addTask { .brief(await musicKnowledgeResult(brief)) }

            var wikiResult: Result<[MusicKnowledgeBlock], any Error>?
            var briefResult: Result<[MusicKnowledgeBlock], any Error>?
            while let part = try await group.next() {
                try Task.checkCancellation()
                switch part {
                case let .wiki(result): wikiResult = result
                case let .brief(result): briefResult = result
                }
                if part.isCancellation {
                    group.cancelAll()
                    throw CancellationError()
                }
            }

            if case let .failure(error)? = wikiResult,
               case .failure(_)? = briefResult {
                throw error
            }
            let wikiBlocks: [MusicKnowledgeBlock]
            if case let .success(blocks)? = wikiResult { wikiBlocks = blocks } else { wikiBlocks = [] }
            let briefBlocks: [MusicKnowledgeBlock]
            if case let .success(blocks)? = briefResult { briefBlocks = blocks } else { briefBlocks = [] }
            return wikiBlocks + briefBlocks
        }
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
        cache: EAPIReadCache,
        expectedCredentialRevision: UInt64? = nil
    ) async throws -> [String: Any] {
        try await transport.requestWEAPIJSONObject(
            path: path,
            payload: payload,
            cache: cache,
            expectedCredentialRevision: expectedCredentialRevision,
            invalidatesAccountCache: false
        )
    }

    private func eapi(
        _ physicalPath: String,
        signing logicalPath: String,
        payload: [String: Any],
        cache: EAPIReadCache = .detail
    ) async throws -> [String: Any] {
        try await transport.requestJSONObject(
            EAPIEndpoint(physicalPath, signing: logicalPath, host: Self.interfaceHost),
            json: compactJSON(payload),
            cache: cache
        )
    }
}

private enum MusicKnowledgePartResult: Sendable {
    case wiki(Result<[MusicKnowledgeBlock], any Error>)
    case brief(Result<[MusicKnowledgeBlock], any Error>)

    var isCancellation: Bool {
        switch self {
        case let .wiki(.failure(error)), let .brief(.failure(error)): error is CancellationError
        case .wiki(.success), .brief(.success): false
        }
    }
}

private func musicKnowledgeResult<Value: Sendable>(
    _ operation: @escaping @Sendable () async throws -> Value
) async -> Result<Value, any Error> {
    do {
        return .success(try await operation())
    } catch {
        return .failure(error)
    }
}
