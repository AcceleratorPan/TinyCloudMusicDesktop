import Foundation
import Observation
import Testing
@testable import TinyCloudMusic

private actor LibraryMutationGate {
    private let blockedCalls: Set<Int>
    private var enteredCallCount = 0
    private var released = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    init(blockedCallCount: Int = 1) {
        blockedCalls = Set(1...blockedCallCount)
    }

    init(blockedCalls: Set<Int>) {
        self.blockedCalls = blockedCalls
    }

    func wait() async {
        enteredCallCount += 1
        guard blockedCalls.contains(enteredCallCount), !released else { return }
        await withCheckedContinuation { continuations.append($0) }
    }

    func release() {
        released = true
        continuations.forEach { $0.resume() }
        continuations.removeAll()
    }

    func hasEntered(_ count: Int = 1) -> Bool { enteredCallCount >= count }
    func waiterCount() -> Int { continuations.count }
}

private actor LibraryMutationStepGate {
    private var enteredCallCount = 0
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        enteredCallCount += 1
        await withCheckedContinuation { continuation = $0 }
    }

    func releaseNext() {
        continuation?.resume()
        continuation = nil
    }

    func hasEntered(_ count: Int) -> Bool { enteredCallCount >= count }
}

private final class LibraryObservationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}

private final class LibraryMutationProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var counts: [String: Int] = [:]
    nonisolated(unsafe) private static var recordedBodies: [String: [Data]] = [:]
    nonisolated(unsafe) private static var failedPaths: Set<String> = []
    nonisolated(unsafe) private static var failedCalls: [String: Set<Int>] = [:]
    nonisolated(unsafe) private static var blockedResponse: (path: String, call: Int)?
    nonisolated(unsafe) private static var responseGate: DispatchSemaphore?

    static func reset() {
        lock.withLock {
            counts = [:]
            recordedBodies = [:]
            failedPaths = []
            failedCalls = [:]
            blockedResponse = nil
            responseGate = nil
        }
    }
    static func fail(_ path: String) { lock.withLock { _ = failedPaths.insert(path) } }
    static func fail(_ path: String, onCall call: Int) {
        lock.withLock { _ = failedCalls[path, default: []].insert(call) }
    }
    static func blockResponse(_ path: String, onCall call: Int) {
        lock.withLock {
            blockedResponse = (path, call)
            responseGate = DispatchSemaphore(value: 0)
        }
    }
    static func releaseBlockedResponse() { lock.withLock { responseGate }?.signal() }
    static func count(_ path: String) -> Int { lock.withLock { counts[path, default: 0] } }
    static func bodies(_ path: String) -> [Data] { lock.withLock { recordedBodies[path, default: []] } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let path = request.url?.path ?? ""
        let requestBody = requestBody()
        let (count, shouldFail, responseGate) = Self.lock.withLock {
            Self.counts[path, default: 0] += 1
            if !requestBody.isEmpty { Self.recordedBodies[path, default: []].append(requestBody) }
            let count = Self.counts[path, default: 0]
            return (
                count,
                Self.failedPaths.contains(path) || Self.failedCalls[path]?.contains(count) == true,
                Self.blockedResponse.map { $0.path == path && $0.call == count } == true
                    ? Self.responseGate
                    : nil
            )
        }
        responseGate?.wait()
        let body = if shouldFail {
            #"{"code":500,"message":"fixture failure"}"#
        } else if path == "/eapi/v1/user/info" {
            #"{"code":200,"userPoint":{"userId":\#(count.isMultiple(of: 2) ? 7 : 8)}}"#
        } else if path == "/eapi/v1/user/detail" {
            #"{"code":200,"profile":{"userId":\#(count.isMultiple(of: 2) ? 7 : 8),"nickname":"fixture"}}"#
        } else if path == "/eapi/user/playlist" {
            #"{"code":200,"playlist":[{"id":900,"name":"Liked","specialType":5,"creator":{"userId":8,"nickname":"fixture"}}],"more":false}"#
        } else if path == "/eapi/v6/playlist/detail" {
            #"{"code":200,"playlist":{"id":900,"name":"Liked","specialType":5,"trackCount":0,"creator":{"userId":8,"nickname":"fixture"},"trackIds":[],"tracks":[]}}"#
        } else if path == "/weapi/djradio/get/subed" {
            count == 1
                ? #"{"code":200,"djRadios":[{"id":1,"name":"Existing","subed":true}],"more":false}"#
                : #"{"code":200,"djRadios":[{"id":1,"name":"Existing","subed":true},{"id":81,"name":"New","subed":true}],"more":false}"#
        } else if path == "/weapi/nos/token/alloc" {
            #"{"code":200,"result":{"objectKey":"fixture.jpg","token":"fixture-token","docId":"fixture-id"}}"#
        } else if path.contains("recommend/songs/history/recent") {
            count == 1
                ? #"{"code":200,"data":{"dates":["2026-07-30"]}}"#
                : #"{"code":200,"data":{"dates":["2026-07-31"]}}"#
        } else {
            #"{"code":200}"#
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private func requestBody() -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var body = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            body.append(buffer, count: count)
        }
        return body
    }
}

private enum LibraryPaginationTail: Equatable, Sendable {
    case exhausted
    case duplicate
    case empty
    case repeatedCursor
}

private final class LibraryPaginationProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var counts: [String: Int] = [:]
    nonisolated(unsafe) private static var recordedBodies: [String: [Data]] = [:]
    nonisolated(unsafe) private static var tailGate: DispatchSemaphore?
    nonisolated(unsafe) private static var usesLargePlaylist = false
    nonisolated(unsafe) private static var dataPageCount: Int?
    nonisolated(unsafe) private static var tail: LibraryPaginationTail = .exhausted

    static func reset(largePlaylist: Bool = false) {
        lock.withLock {
            counts = [:]
            recordedBodies = [:]
            tailGate = DispatchSemaphore(value: 0)
            usesLargePlaylist = largePlaylist
            dataPageCount = nil
            tail = .exhausted
        }
    }

    static func reset(
        dataPages: Int,
        tail: LibraryPaginationTail = .exhausted,
        gateTail: Bool = false
    ) {
        lock.withLock {
            counts = [:]
            recordedBodies = [:]
            tailGate = gateTail ? DispatchSemaphore(value: 0) : nil
            usesLargePlaylist = false
            dataPageCount = dataPages
            self.tail = tail
        }
    }
    static func count(_ path: String) -> Int { lock.withLock { counts[path, default: 0] } }
    static func bodies(_ path: String) -> [Data] { lock.withLock { recordedBodies[path, default: []] } }
    static func releaseTail() { lock.withLock { tailGate }?.signal() }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let path = request.url?.path ?? ""
        let requestBody = requestBody()
        let (count, tailGate, usesLargePlaylist, dataPageCount, tail) = Self.lock.withLock {
            Self.counts[path, default: 0] += 1
            if !requestBody.isEmpty { Self.recordedBodies[path, default: []].append(requestBody) }
            return (
                Self.counts[path, default: 0],
                Self.tailGate,
                Self.usesLargePlaylist,
                Self.dataPageCount,
                Self.tail
            )
        }
        if count == 2, !usesLargePlaylist { tailGate?.wait() }
        let ids: [Int64] = if let dataPageCount, count <= dataPageCount {
            Array(Int64((count - 1) * 100 + 1)...Int64(count * 100))
        } else if let dataPageCount, count == dataPageCount + 1, tail == .duplicate {
            Array(1...100).map(Int64.init)
        } else if dataPageCount != nil {
            []
        } else if usesLargePlaylist, path == "/eapi/user/playlist" {
            count <= 10
                ? Array(Int64((count - 1) * 100 + 1)...Int64(count * 100))
                : count == 11 ? [1_001] : []
        } else {
            count == 1 ? [1, 2] : [3, 2]
        }
        let claimsMore: Bool = if let dataPageCount {
            switch tail {
            case .exhausted:
                path == "/eapi/user/playlist" ? count < dataPageCount : count <= dataPageCount
            case .duplicate, .empty:
                count <= dataPageCount + 1
            case .repeatedCursor:
                true
            }
        } else if path == "/eapi/user/playlist" {
            usesLargePlaylist ? count < 11 : count == 1
        } else {
            true
        }
        let nextCursor = if tail == .repeatedCursor,
                            let dataPageCount,
                            count == dataPageCount {
            "cursor-\(max(1, count - 1))"
        } else {
            "cursor-\(count)"
        }
        let body: [String: Any]
        switch path {
        case "/eapi/user/playlist":
            body = [
                "code": 200,
                "playlist": ids.map {
                    ["id": $0, "name": "Playlist \($0)", "creator": ["userId": 7, "nickname": "Fixture"]]
                },
                "more": claimsMore
            ]
        case "/eapi/user/follow/users/mixed/get/v2":
            body = [
                "code": 200,
                "data": [
                    "records": ids.map {
                        ["type": 1, "userProfile": ["userId": $0, "nickname": "User \($0)"]]
                    },
                    "hasMore": claimsMore,
                    "nextCursor": nextCursor
                ]
            ]
        case "/eapi/user/v3/follows/get":
            body = [
                "code": 200,
                "data": [
                    "records": ids.map {
                        ["userProfile": ["userId": $0, "nickname": "User \($0)"]]
                    },
                    "hasMore": claimsMore,
                    "nextCursor": nextCursor
                ]
            ]
        case "/eapi/user/sub/artist/get":
            body = [
                "code": 200,
                "data": [
                    "artists": ids.map { ["id": $0, "name": "Artist \($0)"] },
                    "hasMore": claimsMore
                ]
            ]
        default:
            body = ["code": 404]
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: body))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private func requestBody() -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var body = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            body.append(buffer, count: count)
        }
        return body
    }
}

@MainActor
private final class LibraryPageRecorder<Value> {
    private(set) var updates: [[Value]] = []
    private(set) var completed = false

    func record(_ values: [Value]) { updates.append(values) }
    func finish() { completed = true }
}

private enum LibraryPaginationEntry: CaseIterable, Equatable, Sendable {
    case playlists
    case mixedFollowing
    case followingUsers
    case followedArtists

    var path: String {
        switch self {
        case .playlists: "/eapi/user/playlist"
        case .mixedFollowing: "/eapi/user/follow/users/mixed/get/v2"
        case .followingUsers: "/eapi/user/v3/follows/get"
        case .followedArtists: "/eapi/user/sub/artist/get"
        }
    }
}

private enum LikedSongTupleChange: CaseIterable, Sendable {
    case generation
    case user
    case accountRevision
    case transportRevision
}

private final class AppModelAccountReadRepository: MusicRepository, @unchecked Sendable {
    let homeDescriptors = [
        HomeSectionDescriptor(
            id: "PAGE_RECOMMEND_SPECIAL_CLOUD_VILLAGE_PLAYLIST",
            title: "Account Home"
        )
    ]

    private let snapshot: CredentialSnapshot
    private let homeGate: LibraryMutationGate
    private let detailGate: LibraryMutationGate
    private let fixture = FixtureMusicRepository()
    private let lock = NSLock()
    private var homeRevision: UInt64?
    private var detailRevision: UInt64?
    private var detailForceRefreshes: [Bool] = []
    private var completedReads = 0

    init(
        snapshot: CredentialSnapshot,
        homeGate: LibraryMutationGate,
        detailGate: LibraryMutationGate
    ) {
        self.snapshot = snapshot
        self.homeGate = homeGate
        self.detailGate = detailGate
    }

    var currentCredentialRevision: UInt64 { snapshot.load().revision }

    func capturedRevisions() -> (home: UInt64?, detail: UInt64?) {
        lock.withLock { (homeRevision, detailRevision) }
    }

    func completedReadCount() -> Int { lock.withLock { completedReads } }
    func capturedDetailForceRefreshes() -> [Bool] { lock.withLock { detailForceRefreshes } }

    func homeSection(
        id: String,
        expectedCredentialRevision: UInt64
    ) async throws -> HomeSection {
        lock.withLock { homeRevision = expectedCredentialRevision }
        await homeGate.wait()
        lock.withLock { completedReads += 1 }
        return HomeSection(id: id, title: "Account A", subtitle: "", items: [])
    }

    func detail(
        for route: Route,
        expectedCredentialRevision: UInt64?
    ) async throws -> DetailContent {
        lock.withLock { detailRevision = expectedCredentialRevision }
        await detailGate.wait()
        lock.withLock { completedReads += 1 }
        if case let .playlist(id) = route {
            return .playlist(
                Playlist(
                    id: id,
                    name: "Playlist \(id)",
                    creator: "Fixture",
                    description: "",
                    artwork: Artwork(symbol: "music.note.list", accent: .blue),
                    trackCount: 0
                ),
                songs: [],
                trackIDs: [],
                loadedTrackCount: 0
            )
        }
        return .user(
            UserProfile(
                id: 7,
                nickname: "Account A",
                signature: "",
                artwork: Artwork(symbol: "person.crop.circle", accent: .blue)
            ),
            playlists: [],
            hasMore: false
        )
    }

    func detail(
        for route: Route,
        expectedCredentialRevision: UInt64?,
        forceRefresh: Bool
    ) async throws -> DetailContent {
        lock.withLock { detailForceRefreshes.append(forceRefresh) }
        return try await detail(for: route, expectedCredentialRevision: expectedCredentialRevision)
    }

    func search(query: String, scope: SearchScope, offset: Int, limit: Int) async throws -> SearchPage {
        try await fixture.search(query: query, scope: scope, offset: offset, limit: limit)
    }
    func songs(ids: [Int64]) async throws -> [Song] { try await fixture.songs(ids: ids) }
    func lyrics(for songID: Int64) async throws -> SongLyrics { try await fixture.lyrics(for: songID) }
    func playbackSource(for songID: Int64, quality: AudioQuality) async throws -> PlaybackSource {
        try await fixture.playbackSource(for: songID, quality: quality)
    }
    func playbackSource(for songID: Int64, level: String) async throws -> PlaybackSource {
        try await fixture.playbackSource(for: songID, level: level)
    }
    func songQualityDetails(for songID: Int64) async throws -> [SongQualityDetail] {
        try await fixture.songQualityDetails(for: songID)
    }
    func heartModeSongs(seedSongID: Int64, playlistID: Int64?, startSongID: Int64) async throws -> [Song] {
        try await fixture.heartModeSongs(
            seedSongID: seedSongID,
            playlistID: playlistID,
            startSongID: startSongID
        )
    }
    func recordPlaybackStart(
        for songID: Int64,
        sourceID: Int64,
        totalSeconds: Int,
        expectedCredentialRevision: UInt64
    ) async throws {}
    func recordPlayback(
        for songID: Int64,
        sourceID: Int64,
        playedSeconds: Int,
        totalSeconds: Int,
        expectedCredentialRevision: UInt64
    ) async throws {}
    func recordPodcastPlayback(
        for episodeID: Int64,
        positionMilliseconds: Int,
        completed: Bool,
        expectedCredentialRevision: UInt64
    ) async throws {}
}

@Suite("Library mutation ownership and cache", .serialized)
@MainActor
struct LibraryMutationPerformanceTests {
    @Test("Pending mutation coalesces and credential revision fences before send")
    func pendingAndCredentialFence() async throws {
        LibraryMutationProtocol.reset()
        let gate = LibraryMutationGate()
        let snapshot = CredentialSnapshot(.authenticated(try credentials("account-a")))
        let library = LiveMusicLibrary(transport: transport(snapshot: snapshot) { await gate.wait() })
        let model = AppModel(repository: FixtureMusicRepository(), library: library)
        model.installConfirmedAccount(userID: 7, credentialRevision: snapshot.load().revision)

        model.toggleSongLiked(42)
        model.toggleSongLiked(42)

        #expect(await eventually { await gate.hasEntered() })
        #expect(model.pendingMutations == [.songLike(42)])
        #expect(LibraryMutationProtocol.count("/eapi/song/like") == 0)

        snapshot.store(.authenticated(try credentials("account-b")))
        snapshot.store(.authenticated(try credentials("account-a-returned")))
        await gate.release()

        #expect(await eventually { model.pendingMutations.isEmpty })
        #expect(!model.likedSongIDs.contains(42))
        #expect(LibraryMutationProtocol.count("/eapi/song/like") == 0)
    }

    @Test("Playlist and artist mutations are owned and coalesced by AppModel")
    func playlistAndArtistOwnership() async throws {
        LibraryMutationProtocol.reset()
        let gate = LibraryMutationGate(blockedCallCount: 2)
        let snapshot = CredentialSnapshot(.authenticated(try credentials("ownership")))
        let library = LiveMusicLibrary(transport: transport(snapshot: snapshot) { await gate.wait() })
        let model = AppModel(repository: FixtureMusicRepository(), library: library)
        model.installConfirmedAccount(userID: 7, credentialRevision: snapshot.load().revision)
        model.playlistPickerSong = song(42)

        model.addSongToPlaylist(42, playlistID: 9, isFavoritePlaylist: false)
        model.addSongToPlaylist(42, playlistID: 9, isFavoritePlaylist: false)
        model.setArtistFollowed(6, followed: true)
        model.setArtistFollowed(6, followed: true)

        #expect(await eventually { await gate.hasEntered(2) })
        #expect(model.pendingMutations == [
            .playlistSong(playlistID: 9, songID: 42),
            .artistFollow(6)
        ])
        await gate.release()

        #expect(await eventually { model.pendingMutations.isEmpty })
        #expect(LibraryMutationProtocol.count("/eapi/v1/playlist/manipulate/tracks") == 1)
        #expect(LibraryMutationProtocol.count("/eapi/v1/artist/sub") == 1)
        #expect(model.artistFollowOverrides[6] == true)
        #expect(model.playlistPickerSong == nil)
    }

    @Test("Failed playlist add remains retryable through its dedicated handler")
    func playlistAddRetry() async throws {
        LibraryMutationProtocol.reset()
        LibraryMutationProtocol.fail("/eapi/v1/playlist/manipulate/tracks", onCall: 1)
        let snapshot = CredentialSnapshot(.authenticated(try credentials("playlist-retry")))
        let model = AppModel(
            repository: FixtureMusicRepository(),
            library: LiveMusicLibrary(transport: transport(snapshot: snapshot))
        )
        model.installConfirmedAccount(userID: 7, credentialRevision: snapshot.load().revision)
        model.playlistPickerSong = song(42)
        var failures: [String] = []

        model.addSongToPlaylist(
            42,
            playlistID: 9,
            isFavoritePlaylist: false,
            onFailure: { failures.append($0) }
        )
        #expect(await eventually { model.pendingMutations.isEmpty && failures.count == 1 })
        #expect(model.libraryMessage == nil)
        #expect(model.playlistPickerSong?.id == 42)

        model.addSongToPlaylist(
            42,
            playlistID: 9,
            isFavoritePlaylist: false,
            onFailure: { failures.append($0) }
        )
        #expect(await eventually { model.pendingMutations.isEmpty && model.playlistPickerSong == nil })
        #expect(failures.count == 1)
        #expect(LibraryMutationProtocol.count("/eapi/v1/playlist/manipulate/tracks") == 2)
    }

    @Test("Favorite batch excludes the same single key but not a different key")
    func batchAndSingleKeyExclusion() async throws {
        LibraryMutationProtocol.reset()
        let gate = LibraryMutationGate(blockedCallCount: 2)
        let snapshot = CredentialSnapshot(.authenticated(try credentials("batch")))
        let library = LiveMusicLibrary(transport: transport(snapshot: snapshot) { await gate.wait() })
        let model = AppModel(repository: FixtureMusicRepository(), library: library)
        model.installConfirmedAccount(userID: 7, credentialRevision: snapshot.load().revision)

        let batch = Task { try await model.favoriteSongs([42]) }
        #expect(await eventually { model.pendingMutations.contains(.songLike(42)) })
        model.toggleSongLiked(42)
        model.toggleSongLiked(43)

        #expect(await eventually { await gate.hasEntered(2) })
        #expect(model.pendingMutations == [.songLike(42), .songLike(43)])
        await gate.release()

        #expect(try await batch.value == 1)
        #expect(await eventually { model.pendingMutations.isEmpty })
        #expect(LibraryMutationProtocol.count("/eapi/song/like") == 2)
        #expect(model.likedSongIDs.isSuperset(of: [42, 43]))
    }

    @Test("Canceled batch cleanup cannot mutate or release a later account task")
    func batchCleanupIdentityAfterAccountReset() async throws {
        LibraryMutationProtocol.reset()
        let gate = LibraryMutationGate(blockedCalls: [2])
        let snapshot = CredentialSnapshot(.authenticated(try credentials("batch-a")))
        let transport = transport(snapshot: snapshot) { await gate.wait() }
        let model = AppModel(
            repository: FixtureMusicRepository(),
            library: LiveMusicLibrary(transport: transport),
            extras: LiveMusicExtras(transport: transport)
        )
        model.installConfirmedAccount(userID: 7, credentialRevision: snapshot.load().revision)

        let batch = Task { try await model.favoriteSongs([42, 43]) }
        #expect(await eventually {
            let entered = await gate.hasEntered(2)
            return entered && model.likedSongIDs.contains(42)
        })

        snapshot.store(.authenticated(try credentials("batch-b")))
        await model.refreshAccountState()
        #expect(model.currentUserID == 8)
        #expect(model.pendingMutations.isEmpty)
        #expect(model.playlistContentRevision == 0)

        model.toggleSongLiked(42)
        #expect(await eventually { model.likedSongIDs.contains(42) })
        #expect(model.playlistContentRevision == 1)

        await gate.release()
        _ = try? await batch.value
        #expect(await eventually { model.pendingMutations.isEmpty })
        #expect(model.likedSongIDs == [42])
        #expect(model.playlistContentRevision == 1)
        #expect(LibraryMutationProtocol.count("/eapi/song/like") == 2)
    }

    @Test("Favorite batch reports partial failure and retry skips successful songs")
    func favoriteBatchPartialFailure() async throws {
        LibraryMutationProtocol.reset()
        LibraryMutationProtocol.fail("/eapi/song/like", onCall: 2)
        let snapshot = CredentialSnapshot(.authenticated(try credentials("batch-partial")))
        let model = AppModel(
            repository: FixtureMusicRepository(),
            library: LiveMusicLibrary(transport: transport(snapshot: snapshot))
        )
        model.installConfirmedAccount(userID: 7, credentialRevision: snapshot.load().revision)

        do {
            _ = try await model.favoriteSongs([1, 2, 3])
            Issue.record("The second favorite request should fail")
        } catch let failure as FavoriteSongsFailure {
            #expect(failure.successfulIDs == [1])
            #expect(failure.failedID == 2)
            #expect(failure.unattemptedIDs == [3])
            #expect(!failure.causeDescription.isEmpty)
        }
        #expect(model.likedSongIDs == [1])
        #expect(LibraryMutationProtocol.count("/eapi/song/like") == 2)

        #expect(try await model.favoriteSongs([1, 2, 3]) == 2)
        #expect(model.likedSongIDs == [1, 2, 3])
        #expect(LibraryMutationProtocol.count("/eapi/song/like") == 4)
    }

    @Test("Account bootstrap and Library consumer share one playlist result")
    func accountPlaylistBootstrapSharing() async throws {
        LibraryMutationProtocol.reset()
        let snapshot = CredentialSnapshot(.authenticated(try credentials("playlist-bootstrap")))
        let transport = transport(snapshot: snapshot)
        let model = AppModel(
            repository: FixtureMusicRepository(),
            library: LiveMusicLibrary(transport: transport),
            extras: LiveMusicExtras(transport: transport)
        )

        await model.refreshAccountState()
        let playlists = try await model.accountPlaylists(
            userID: 8,
            credentialRevision: snapshot.load().revision
        )

        #expect(model.currentUserID == 8)
        #expect(playlists.map(\.id) == [900])
        #expect(LibraryMutationProtocol.count("/eapi/user/playlist") == 1)
        #expect(LibraryMutationProtocol.count("/eapi/v6/playlist/detail") == 1)
    }

    @Test("Known account tuple refreshes liked songs without account bootstrap requests")
    func likedSongRefreshUsesKnownAccountTuple() async throws {
        LibraryMutationProtocol.reset()
        let fixture = try likedSongFixture("known-tuple")
        fixture.model.likedSongIDs = [42]
        fixture.model.libraryMessage = "old"

        #expect(await fixture.model.refreshLikedSongIDs(
            userID: 8,
            playlists: fixture.playlists,
            credentialRevision: fixture.revision
        ))
        #expect(fixture.model.likedSongIDs.isEmpty)
        #expect(fixture.model.libraryMessage == nil)
        #expect(LibraryMutationProtocol.count("/eapi/v6/playlist/detail") == 1)
        #expect(LibraryMutationProtocol.count("/eapi/v1/user/info") == 0)
        #expect(LibraryMutationProtocol.count("/eapi/v1/user/detail") == 0)
        #expect(LibraryMutationProtocol.count("/eapi/user/playlist") == 0)
    }

    @Test("Equal liked-song Set does not publish an Observation change")
    func equalLikedSongSetDoesNotPublish() async throws {
        LibraryMutationProtocol.reset()
        let fixture = try likedSongFixture("equal-set")
        fixture.model.libraryMessage = "old"

        await confirmation("likedSongIDs remains unpublished", expectedCount: 0) { changed in
            _ = withObservationTracking {
                fixture.model.likedSongIDs
            } onChange: {
                changed()
            }
            #expect(await fixture.model.refreshLikedSongIDs(
                userID: 8,
                playlists: fixture.playlists,
                credentialRevision: fixture.revision
            ))
        }

        #expect(fixture.model.likedSongIDs.isEmpty)
        #expect(fixture.model.libraryMessage == nil)
        #expect(LibraryMutationProtocol.count("/eapi/v6/playlist/detail") == 1)
    }

    @Test(
        "Liked-song refresh rejects stale generation, user, account, and transport revisions",
        arguments: LikedSongTupleChange.allCases
    )
    fileprivate func likedSongRefreshRejectsStaleTuple(_ change: LikedSongTupleChange) async throws {
        LibraryMutationProtocol.reset()
        let gate = LibraryMutationGate()
        let fixture = try likedSongFixture("stale-\(change)") { await gate.wait() }
        fixture.model.likedSongIDs = [42]
        fixture.model.libraryMessage = "old"

        let refresh = Task {
            await fixture.model.refreshLikedSongIDs(
                userID: 8,
                playlists: fixture.playlists,
                credentialRevision: fixture.revision
            )
        }
        #expect(await eventually { await gate.hasEntered() })

        switch change {
        case .generation:
            fixture.model.installConfirmedAccount(userID: 8, credentialRevision: fixture.revision)
        case .user:
            fixture.model.currentUserID = 9
        case .accountRevision:
            fixture.model.installConfirmedAccount(userID: 8, credentialRevision: fixture.revision &+ 1)
        case .transportRevision:
            _ = fixture.snapshot.store(.authenticated(try credentials("stale-transport-current")))
        }
        fixture.model.likedSongIDs = [99]
        fixture.model.libraryMessage = "current"
        await gate.release()

        #expect(!(await refresh.value))
        #expect(fixture.model.likedSongIDs == [99])
        #expect(fixture.model.libraryMessage == "current")
    }

    @Test("Canceled liked-song refresh preserves state and message")
    func canceledLikedSongRefreshPreservesState() async throws {
        LibraryMutationProtocol.reset()
        let gate = LibraryMutationGate()
        let fixture = try likedSongFixture("cancel-liked") { await gate.wait() }
        fixture.model.likedSongIDs = [42]
        fixture.model.libraryMessage = "old"

        let refresh = Task {
            await fixture.model.refreshLikedSongIDs(
                userID: 8,
                playlists: fixture.playlists,
                credentialRevision: fixture.revision
            )
        }
        #expect(await eventually { await gate.hasEntered() })
        refresh.cancel()
        await gate.release()

        #expect(!(await refresh.value))
        #expect(fixture.model.likedSongIDs == [42])
        #expect(fixture.model.libraryMessage == "old")
    }

    @Test("Liked-song refresh errors publish only for the current tuple")
    func likedSongRefreshErrorPublication() async throws {
        LibraryMutationProtocol.reset()
        LibraryMutationProtocol.fail("/eapi/v6/playlist/detail")
        let current = try likedSongFixture("current-error")
        current.model.likedSongIDs = [42]
        current.model.libraryMessage = "old"

        #expect(!(await current.model.refreshLikedSongIDs(
            userID: 8,
            playlists: current.playlists,
            credentialRevision: current.revision
        )))
        #expect(current.model.likedSongIDs == [42])
        #expect(current.model.libraryMessage != nil)
        #expect(current.model.libraryMessage != "old")

        LibraryMutationProtocol.reset()
        LibraryMutationProtocol.fail("/eapi/v6/playlist/detail")
        let gate = LibraryMutationGate()
        let stale = try likedSongFixture("stale-error") { await gate.wait() }
        stale.model.likedSongIDs = [42]
        stale.model.libraryMessage = "old"
        let refresh = Task {
            await stale.model.refreshLikedSongIDs(
                userID: 8,
                playlists: stale.playlists,
                credentialRevision: stale.revision
            )
        }
        #expect(await eventually { await gate.hasEntered() })
        stale.model.currentUserID = 9
        stale.model.likedSongIDs = [99]
        stale.model.libraryMessage = "current"
        await gate.release()

        #expect(!(await refresh.value))
        #expect(stale.model.likedSongIDs == [99])
        #expect(stale.model.libraryMessage == "current")
    }

    @Test("Cold start reuses the revision-tagged account validation exactly once")
    func coldStartReusesValidatedUserInfoExactlyOnce() async throws {
        LibraryMutationProtocol.reset()
        let snapshot = CredentialSnapshot(.authenticated(try credentials("cold-start")))
        let transport = transport(snapshot: snapshot)
        let library = LiveMusicLibrary(transport: transport)
        let session = session(snapshot: snapshot, transport: transport)
        let model = AppModel(
            repository: LiveMusicRepository(transport: transport),
            library: library,
            extras: LiveMusicExtras(transport: transport),
            session: session
        )

        let confirmedAccount = await session.restore(accountValidator: { _ in
            guard case let .loggedIn(user) = try await library.loginState(
                expectedCredentialRevision: snapshot.load().revision
            ) else { return nil }
            return user
        })
        await model.refreshAccountState(confirmedAccount: confirmedAccount)

        #expect(model.currentUserID == 8)
        #expect(model.confirmedAccountCredentialRevision == snapshot.load().revision)
        #expect(LibraryMutationProtocol.count("/eapi/v1/user/info") == 1)
        #expect(LibraryMutationProtocol.count("/eapi/v1/user/detail") == 1)
    }

    @Test("Confirmed account mismatch falls back without installing the stale user")
    func confirmedAccountMismatchFallsBack() async throws {
        LibraryMutationProtocol.reset()
        let transportSnapshot = CredentialSnapshot(.authenticated(try credentials("fallback-transport")))
        let sessionSnapshot = CredentialSnapshot(.authenticated(try credentials("fallback-session")))
        _ = sessionSnapshot.store(.authenticated(try credentials("fallback-session-current")))
        let libraryTransport = transport(snapshot: transportSnapshot)
        let model = AppModel(
            repository: FixtureMusicRepository(),
            library: LiveMusicLibrary(transport: libraryTransport),
            extras: LiveMusicExtras(transport: libraryTransport),
            session: session(
                snapshot: sessionSnapshot,
                transport: transport(snapshot: sessionSnapshot)
            )
        )

        await model.refreshAccountState(confirmedAccount: ValidatedMusicLibraryAccount(
            user: accountUser(99),
            credentialRevision: transportSnapshot.load().revision
        ))

        #expect(model.currentUserID == 8)
        #expect(model.currentUserID != 99)
        #expect(model.confirmedAccountCredentialRevision == transportSnapshot.load().revision)
        #expect(LibraryMutationProtocol.count("/eapi/v1/user/info") == 1)
        #expect(LibraryMutationProtocol.count("/eapi/v1/user/detail") == 1)
    }

    @Test("Account install preserves fresh login cache and rejects a stale result")
    func accountInstallPreservesFreshLoginCache() async throws {
        LibraryMutationProtocol.reset()
        let snapshot = CredentialSnapshot(.authenticated(try credentials("cache-account-a")))
        let transport = transport(snapshot: snapshot)
        let library = LiveMusicLibrary(transport: transport)
        let session = session(snapshot: snapshot, transport: transport)
        let model = AppModel(
            repository: FixtureMusicRepository(),
            library: library,
            extras: LiveMusicExtras(transport: transport),
            session: session
        )

        await model.refreshAccountState()
        let revisionA = snapshot.load().revision
        _ = try await library.loginState(expectedCredentialRevision: revisionA)
        #expect(LibraryMutationProtocol.count("/eapi/v1/user/info") == 1)
        #expect(LibraryMutationProtocol.count("/eapi/v1/user/detail") == 1)

        let revisionB = snapshot.store(.authenticated(try credentials("cache-account-b"))).revision
        await model.refreshAccountState(confirmedAccount: ValidatedMusicLibraryAccount(
            user: accountUser(99),
            credentialRevision: revisionA
        ))

        #expect(model.currentUserID == 7)
        #expect(model.currentUserID != 99)
        #expect(model.confirmedAccountCredentialRevision == revisionB)
    }

    @Test("Credential issue accepts a matching revision only once")
    func credentialIssueInvalidationAcceptsMatchingRevisionOnce() throws {
        let snapshot = CredentialSnapshot(.authenticated(try credentials("credential-issue")))
        let controller = session(snapshot: snapshot, transport: transport(snapshot: snapshot))
        let revision = snapshot.load().revision
        let event = SessionCredentialIssueEvent(issue: .cookie, credentialRevision: revision)

        #expect(controller.invalidate(event))
        let invalidated = snapshot.load()
        #expect(controller.state == .invalid)
        #expect(invalidated.revision == revision + 1)
        #expect(!controller.invalidate(event))
        #expect(!controller.invalidate(SessionCredentialIssueEvent(
            issue: .musicU,
            credentialRevision: revision
        )))
        #expect(snapshot.load() == invalidated)
    }

    @Test("Loaded details honor expiry and macOS evicts inactive payloads")
    func detailExpiryAndRetention() async throws {
        let repository = AppModelAccountReadRepository(
            snapshot: CredentialSnapshot(.guest),
            homeGate: LibraryMutationGate(blockedCalls: []),
            detailGate: LibraryMutationGate(blockedCalls: [])
        )
        let suiteName = "TinyCloudMusicTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = AppModel(repository: repository, defaults: defaults)
        let first = Route.playlist(1)
        model.path = [first]
        model.loadDetail(first)
        #expect(await eventually {
            guard case .loaded? = model.detailLoads[first] else { return false }
            return true
        })
        model.path = []
        model.path = [first]
        model.loadDetail(first)
        #expect(repository.capturedDetailForceRefreshes() == [false])
        model.loadDetail(first, now: Date().addingTimeInterval(301))
        #expect(await eventually { repository.capturedDetailForceRefreshes() == [false, true] })

        for id in 2...80 {
            let route = Route.playlist(Int64(id))
            model.path = [route]
            model.loadDetail(route)
            #expect(await eventually {
                guard case .loaded? = model.detailLoads[route] else { return false }
                return true
            })
        }
        model.path = []
        #expect(model.detailLoads.count <= 64)
        #expect(model.detailLoads[first] == nil)
        #expect(model.detailLoads[.playlist(80)] != nil)
    }

    @Test("Playlist read and reload each send one accepted detail payload")
    func playlistRefreshSendsOneDetailPayload() async throws {
        LibraryMutationProtocol.reset()
        let snapshot = CredentialSnapshot(.authenticated(try credentials("playlist-detail")))
        let transport = transport(snapshot: snapshot)
        let model = AppModel(
            repository: LiveMusicRepository(transport: transport),
            library: LiveMusicLibrary(transport: transport)
        )
        let route = Route.playlist(900)
        model.path = [route]

        model.loadDetail(route)
        #expect(await eventually {
            guard LibraryMutationProtocol.count("/eapi/v6/playlist/detail") == 1,
                  case .loaded? = model.detailLoads[route]
            else { return false }
            return true
        })
        model.loadDetail(route, reload: true)
        #expect(await eventually {
            guard LibraryMutationProtocol.count("/eapi/v6/playlist/detail") == 2,
                  case .loaded? = model.detailLoads[route]
            else { return false }
            return true
        })

        let counts = LibraryMutationProtocol.bodies("/eapi/v6/playlist/detail")
            .compactMap(libraryMutationPayload)
            .compactMap { $0["n"] as? String }
        #expect(counts == Array(repeating: String(PlaylistSongPaging.initialCount), count: 2))

        let forceRepository = AppModelAccountReadRepository(
            snapshot: CredentialSnapshot(.guest),
            homeGate: LibraryMutationGate(blockedCalls: []),
            detailGate: LibraryMutationGate(blockedCalls: [])
        )
        let forceModel = AppModel(repository: forceRepository)
        forceModel.path = [route]
        forceModel.loadDetail(route)
        #expect(await eventually {
            guard forceRepository.capturedDetailForceRefreshes() == [false],
                  case .loaded? = forceModel.detailLoads[route]
            else { return false }
            return true
        })
        forceModel.loadDetail(route, reload: true)
        #expect(await eventually {
            guard forceRepository.capturedDetailForceRefreshes() == [false, true],
                  case .loaded? = forceModel.detailLoads[route]
            else { return false }
            return true
        })
    }

    @Test("Playlist mutation reload keeps one request and rejects the old generation")
    func playlistMutationRefreshPreservesGenerationFence() async throws {
        let detailGate = LibraryMutationGate()
        let repository = AppModelAccountReadRepository(
            snapshot: CredentialSnapshot(.guest),
            homeGate: LibraryMutationGate(),
            detailGate: detailGate
        )
        let model = AppModel(repository: repository)

        let stale = Task { try await model.reloadPlaylist(900) }
        #expect(await eventually { await detailGate.hasEntered() })
        let current = try await model.reloadPlaylist(900)
        #expect(current.id == 900)
        await detailGate.release()

        do {
            _ = try await stale.value
            Issue.record("The older playlist generation committed")
        } catch is CancellationError {
        }
        #expect(repository.capturedDetailForceRefreshes() == [true, true])
        #expect(repository.completedReadCount() == 2)
    }

    @Test("Post-install revision change clears the stale account and its mutation owner")
    func postInstallRevisionChangeClearsStaleAccount() async throws {
        LibraryMutationProtocol.reset()
        let gate = LibraryMutationGate(blockedCalls: [3, 4])
        let snapshot = CredentialSnapshot(.authenticated(try credentials("post-install-a")))
        let transport = transport(snapshot: snapshot) { await gate.wait() }
        let model = AppModel(
            repository: FixtureMusicRepository(),
            library: LiveMusicLibrary(transport: transport),
            extras: LiveMusicExtras(transport: transport)
        )
        let revisionA = snapshot.load().revision

        let staleRefresh = Task { await model.refreshAccountState() }
        #expect(await eventually { await gate.hasEntered(3) })
        #expect(model.currentUserID == 8)
        #expect(model.confirmedAccountCredentialRevision == revisionA)

        model.toggleSongLiked(42)
        #expect(await eventually {
            let entered = await gate.hasEntered(4)
            return entered && model.pendingMutations == [.songLike(42)]
        })

        let revisionB = snapshot.store(.authenticated(try credentials("post-install-b"))).revision
        await gate.release()
        await staleRefresh.value

        #expect(model.currentUserID == nil)
        #expect(model.confirmedAccountCredentialRevision == nil)
        #expect(model.pendingMutations.isEmpty)
        #expect(LibraryMutationProtocol.count("/eapi/song/like") == 0)

        await model.refreshAccountState()
        #expect(model.currentUserID == 7)
        #expect(model.confirmedAccountCredentialRevision == revisionB)
    }

    @Test("Stale refresh exit preserves a concurrently installed current account")
    func staleRefreshExitPreservesConcurrentAccount() async throws {
        LibraryMutationProtocol.reset()
        let gate = LibraryMutationGate(blockedCalls: [3])
        let snapshot = CredentialSnapshot(.authenticated(try credentials("concurrent-a")))
        let transport = transport(snapshot: snapshot) { await gate.wait() }
        let model = AppModel(
            repository: FixtureMusicRepository(),
            library: LiveMusicLibrary(transport: transport),
            extras: LiveMusicExtras(transport: transport)
        )
        let revisionA = snapshot.load().revision

        let staleRefresh = Task { await model.refreshAccountState() }
        #expect(await eventually { await gate.hasEntered(3) })
        #expect(model.currentUserID == 8)
        #expect(model.confirmedAccountCredentialRevision == revisionA)

        let revisionB = snapshot.store(.authenticated(try credentials("concurrent-b"))).revision
        await model.refreshAccountState()
        #expect(await gate.waiterCount() == 1)
        #expect(model.currentUserID == 7)
        #expect(model.confirmedAccountCredentialRevision == revisionB)

        await gate.release()
        await staleRefresh.value
        #expect(model.currentUserID == 7)
        #expect(model.confirmedAccountCredentialRevision == revisionB)
    }

    @Test("Revision change invalidates mutations until account confirmation")
    func revisionChangeInvalidatesBeforeConfirmation() async throws {
        LibraryMutationProtocol.reset()
        let gate = LibraryMutationGate()
        let snapshot = CredentialSnapshot(.authenticated(try credentials("confirmed-a")))
        let transport = transport(snapshot: snapshot) { await gate.wait() }
        let model = AppModel(
            repository: FixtureMusicRepository(),
            library: LiveMusicLibrary(transport: transport),
            extras: LiveMusicExtras(transport: transport)
        )
        model.currentUserID = 7
        model.toggleSongLiked(41)
        #expect(model.pendingMutations.isEmpty)
        #expect(LibraryMutationProtocol.count("/eapi/song/like") == 0)
        model.installConfirmedAccount(userID: 7, credentialRevision: snapshot.load().revision)

        let revision = snapshot.store(.authenticated(try credentials("confirming-b"))).revision
        let refresh = Task { await model.refreshAccountState() }
        #expect(await eventually { await gate.hasEntered() })
        #expect(model.currentUserID == nil)
        #expect(model.confirmedAccountCredentialRevision == nil)

        model.toggleSongLiked(42)
        #expect(model.pendingMutations.isEmpty)
        #expect(LibraryMutationProtocol.count("/eapi/song/like") == 0)

        await gate.release()
        await refresh.value
        #expect(model.currentUserID == 8)
        #expect(model.confirmedAccountCredentialRevision == revision)

        model.toggleSongLiked(42)
        #expect(await eventually { LibraryMutationProtocol.count("/eapi/song/like") == 1 })
    }

    @Test("Failed account confirmation keeps mutations invalidated")
    func failedAccountConfirmationStaysInvalidated() async throws {
        LibraryMutationProtocol.reset()
        LibraryMutationProtocol.fail("/eapi/v1/user/detail")
        let snapshot = CredentialSnapshot(.authenticated(try credentials("failure-a")))
        let transport = transport(snapshot: snapshot)
        let model = AppModel(
            repository: FixtureMusicRepository(),
            library: LiveMusicLibrary(transport: transport),
            extras: LiveMusicExtras(transport: transport)
        )
        model.installConfirmedAccount(userID: 7, credentialRevision: snapshot.load().revision)

        _ = snapshot.store(.authenticated(try credentials("failure-b")))
        await model.refreshAccountState()
        #expect(model.currentUserID == nil)
        #expect(model.confirmedAccountCredentialRevision == nil)

        model.toggleSongLiked(42)
        #expect(model.pendingMutations.isEmpty)
        #expect(LibraryMutationProtocol.count("/eapi/song/like") == 0)
    }

    @Test("Canceled account confirmation keeps mutations invalidated")
    func canceledAccountConfirmationStaysInvalidated() async throws {
        LibraryMutationProtocol.reset()
        let gate = LibraryMutationGate()
        let snapshot = CredentialSnapshot(.authenticated(try credentials("cancel-a")))
        let transport = transport(snapshot: snapshot) { await gate.wait() }
        let model = AppModel(
            repository: FixtureMusicRepository(),
            library: LiveMusicLibrary(transport: transport),
            extras: LiveMusicExtras(transport: transport)
        )
        model.installConfirmedAccount(userID: 7, credentialRevision: snapshot.load().revision)

        _ = snapshot.store(.authenticated(try credentials("cancel-b")))
        let refresh = Task { await model.refreshAccountState() }
        #expect(await eventually { await gate.hasEntered() })
        refresh.cancel()
        await gate.release()
        await refresh.value
        #expect(model.currentUserID == nil)
        #expect(model.confirmedAccountCredentialRevision == nil)

        model.toggleSongLiked(42)
        #expect(model.pendingMutations.isEmpty)
        #expect(LibraryMutationProtocol.count("/eapi/song/like") == 0)
    }

    @Test("Podcast subscription commit is idempotent")
    func podcastSubscriptionCommit() async throws {
        let model = AppModel(repository: FixtureMusicRepository())
        model.currentUserID = 7
        let initialRevision = model.podcastSubscriptionRevision

        model.commitPodcastSubscription(id: 81, subscribed: true)
        #expect(model.podcastSubscriptionOverride(for: 81) == true)
        #expect(model.podcastSubscriptionRevision == initialRevision &+ 1)

        model.commitPodcastSubscription(id: 81, subscribed: true)
        #expect(model.podcastSubscriptionRevision == initialRevision &+ 1)

    }

    @Test("Podcast missing rows wait for exact-key refresh and preserve server order")
    func podcastMissingRowRefresh() async throws {
        LibraryMutationProtocol.reset()
        let snapshot = CredentialSnapshot(.authenticated(try credentials("podcast-refresh")))
        let transport = transport(snapshot: snapshot)
        let library = LiveAudioContentLibrary(transport: transport)
        let model = AppModel(
            repository: FixtureMusicRepository(),
            audioLibrary: library
        )
        model.currentUserID = 7
        let credentialRevision = snapshot.load().revision
        let initial = try await library.subscribedPodcasts(
            expectedCredentialRevision: credentialRevision
        )
        let initialRevision = model.podcastSubscriptionRevision

        try await library.setPodcastSubscribed(
            81,
            subscribed: true,
            expectedCredentialRevision: snapshot.load().revision
        )
        model.commitPodcastSubscription(id: 81, subscribed: true)
        let projected = PodcastSubscriptionProjection.page(
            initial,
            override: model.podcastSubscriptionOverride
        )
        #expect(projected.podcasts.map(\.id) == [1])

        let refreshed = try await library.subscribedPodcasts(
            refreshCache: true,
            expectedCredentialRevision: credentialRevision
        )
        let cached = try await library.subscribedPodcasts(
            expectedCredentialRevision: credentialRevision
        )
        #expect(refreshed.podcasts.map(\.id) == [1, 81])
        #expect(cached.podcasts.map(\.id) == [1, 81])
        #expect(model.podcastSubscriptionRevision == initialRevision &+ 1)
        #expect(LibraryMutationProtocol.count("/weapi/djradio/sub") == 1)
        #expect(LibraryMutationProtocol.count("/weapi/djradio/get/subed") == 2)
    }

    @Test("Failed page-owned podcast mutation publishes no override or revision")
    func podcastFailureDoesNotPublish() async throws {
        LibraryMutationProtocol.reset()
        LibraryMutationProtocol.fail("/weapi/djradio/sub")
        let snapshot = CredentialSnapshot(.authenticated(try credentials("podcast-failure")))
        let model = AppModel(
            repository: FixtureMusicRepository(),
            audioLibrary: LiveAudioContentLibrary(transport: transport(snapshot: snapshot))
        )
        model.currentUserID = 7
        let initialRevision = model.podcastSubscriptionRevision

        do {
            try await LiveAudioContentLibrary(
                transport: transport(snapshot: snapshot)
            ).setPodcastSubscribed(
                91,
                subscribed: true,
                expectedCredentialRevision: snapshot.load().revision
            )
            Issue.record("The fixture mutation should fail")
        } catch EAPIError.service(500, _) {
        }

        #expect(model.podcastSubscriptionOverride(for: 91) == nil)
        #expect(model.podcastSubscriptionRevision == initialRevision)
        #expect(LibraryMutationProtocol.count("/weapi/djradio/sub") == 1)
        #expect(LibraryMutationProtocol.count("/weapi/djradio/get/subed") == 0)
    }

    @Test("Single-entity mutation keeps unrelated cached reads")
    func targetedMutationCacheMapping() async throws {
        LibraryMutationProtocol.reset()
        let snapshot = CredentialSnapshot(.authenticated(try credentials("cache")))
        let transport = transport(snapshot: snapshot)
        let endpoint = EAPIEndpoint(
            "/eapi/unrelated",
            signing: "/api/unrelated",
            responseEncoding: .json
        )

        _ = try await transport.request(endpoint, json: Data(), cache: .search)
        try await LiveMusicLibrary(transport: transport).setSongLiked(
            9,
            liked: true,
            expectedCredentialRevision: snapshot.load().revision
        )
        _ = try await transport.request(endpoint, json: Data(), cache: .search)

        #expect(LibraryMutationProtocol.count("/eapi/unrelated") == 1)
        #expect(LibraryMutationProtocol.count("/eapi/song/like") == 1)
    }

    @Test("Audio upload publication keeps unrelated library and detail cache entries")
    func uploadPublicationCacheMapping() async throws {
        LibraryMutationProtocol.reset()
        let snapshot = CredentialSnapshot(.authenticated(try credentials("upload-cache")))
        let transport = transport(snapshot: snapshot)
        let libraryEndpoint = EAPIEndpoint(
            "/eapi/unrelated-library",
            signing: "/api/unrelated-library",
            responseEncoding: .json
        )
        let detailEndpoint = EAPIEndpoint(
            "/eapi/unrelated-detail",
            signing: "/api/unrelated-detail",
            responseEncoding: .json
        )
        _ = try await transport.request(libraryEndpoint, json: Data(), cache: .library)
        _ = try await transport.request(detailEndpoint, json: Data(), cache: .detail)
        let revision = snapshot.load().revision

        try await LiveMusicLibrary(transport: transport).publishCloudUpload(
            songID: 1,
            expectedCredentialRevision: revision
        )
        try await LiveAudioContentLibrary(transport: transport).submitPodcastUpload(
            form: PodcastUploadForm(
                name: "Episode",
                description: "",
                voiceListID: 2,
                coverImageID: 3,
                categoryID: 4,
                secondCategoryID: 5
            ),
            documentID: 6,
            token: "fixture-token",
            expectedCredentialRevision: revision
        )

        _ = try await transport.request(libraryEndpoint, json: Data(), cache: .library)
        _ = try await transport.request(detailEndpoint, json: Data(), cache: .detail)
        #expect(LibraryMutationProtocol.count("/eapi/unrelated-library") == 1)
        #expect(LibraryMutationProtocol.count("/eapi/unrelated-detail") == 1)
    }

    @Test("Playlist cover update keeps unrelated cached reads")
    func playlistCoverCacheMapping() async throws {
        LibraryMutationProtocol.reset()
        let snapshot = CredentialSnapshot(.authenticated(try credentials("cover")))
        let transport = transport(snapshot: snapshot)
        let endpoint = EAPIEndpoint(
            "/eapi/unrelated-cover",
            signing: "/api/unrelated-cover",
            responseEncoding: .json
        )

        _ = try await transport.request(endpoint, json: Data(), cache: .search)
        try await LiveMusicLibrary(transport: transport).updatePlaylistCover(
            9,
            cover: ProcessedPlaylistCover(
                jpegData: Data([0x01]),
                filename: "fixture.jpg",
                width: 1,
                height: 1
            ),
            expectedCredentialRevision: snapshot.load().revision
        )
        _ = try await transport.request(endpoint, json: Data(), cache: .search)

        #expect(LibraryMutationProtocol.count("/eapi/unrelated-cover") == 1)
        #expect(LibraryMutationProtocol.count("/weapi/playlist/cover/update") == 1)
    }

    @Test("Prepared playlist cover reuses its preview and uploads the original cover")
    func preparedPlaylistCoverPreviewBoundary() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appending(
                path: "iOS/TinyCloudMusicIOS/UI/DiscoverSearch/IOSRouteDestinationView.swift"
            ),
            encoding: .utf8
        )
        let prepare = try slice(
            source,
            from: "    private func prepareCover",
            to: "    @MainActor\n    private func updateCover"
        )
        let detached = try slice(
            prepare,
            from: "let worker = Task.detached",
            to: "            do {"
        )
        let update = try slice(
            source,
            from: "    @MainActor\n    private func updateCover",
            to: "    private func makePublic()"
        )
        let item = try slice(
            source,
            from: "private struct IOSPreparedPlaylistCover",
            to: "private struct IOSDetailOperationError"
        )
        let sheet = try slice(
            source,
            from: "private struct IOSPlaylistCoverUpdateSheet",
            to: "    private func submit()"
        )
        let workerValue = try #require(
            prepare.range(of: "try await worker.value")?.lowerBound
        )
        let cancellationGuard = try #require(
            prepare.range(of: "try Task.checkCancellation()")?.lowerBound
        )
        let contextGuard = try #require(
            prepare.range(of: "guard let library = model.library, context.matches")?.lowerBound
        )
        let previewConstruction = try #require(
            prepare.range(of: "UIImage(data: cover.jpegData)")?.lowerBound
        )
        let preparedItemInstall = try #require(
            prepare.range(of: "preparedCover = IOSPreparedPlaylistCover")?.lowerBound
        )

        #expect(prepare.contains("coverTask = Task { @MainActor in"))
        #expect(!detached.contains("UIImage(data:"))
        #expect(workerValue < cancellationGuard)
        #expect(cancellationGuard < contextGuard)
        #expect(contextGuard < previewConstruction)
        #expect(previewConstruction < preparedItemInstall)
        #expect(prepare.components(separatedBy: "UIImage(data:").count == 2)
        #expect(prepare.contains("previewImage: previewImage"))
        #expect(item.contains("let cover: ProcessedPlaylistCover"))
        #expect(item.contains("let context: IOSPlaylistMutationContext"))
        #expect(item.contains("let previewImage: UIImage?"))
        #expect(sheet.contains("if let image = item.previewImage"))
        #expect(sheet.contains("ContentUnavailableView(\"无法预览封面\""))
        #expect(!sheet.contains("UIImage(data:"))
        #expect(update.contains("cover: item.cover"))
        #expect(update.contains("expectedCredentialRevision: item.context.credentialRevision"))
        #expect(update.components(separatedBy: "item.context.matches").count == 3)
        #expect(!update.contains("previewImage"))
        #expect(!update.contains("jpegData"))
    }

    @Test("Recommendation force refresh replaces the regular cache entry")
    func recommendationRefreshReplacement() async throws {
        LibraryMutationProtocol.reset()
        let snapshot = CredentialSnapshot(.authenticated(try credentials("history")))
        let library = LiveMusicLibrary(
            transport: transport(snapshot: snapshot)
        )
        let revision = snapshot.load().revision

        let first = try await library.recommendationHistoryDates(expectedCredentialRevision: revision)
        let refreshed = try await library.recommendationHistoryDates(
            forceRefresh: true,
            expectedCredentialRevision: revision
        )
        let regular = try await library.recommendationHistoryDates(expectedCredentialRevision: revision)

        #expect(first.map(\.value) == ["2026-07-30"])
        #expect(refreshed.map(\.value) == ["2026-07-31"])
        #expect(regular == refreshed)
        #expect(LibraryMutationProtocol.count("/weapi/discovery/recommend/songs/history/recent") == 2)
    }

    @Test("Login force refresh replaces only its cached keys")
    func loginRefreshReplacement() async throws {
        LibraryMutationProtocol.reset()
        let library = LiveMusicLibrary(
            transport: transport(
                snapshot: CredentialSnapshot(.authenticated(try credentials("login-refresh")))
            )
        )

        let first = try await library.loginState()
        let refreshed = try await library.loginState(forceRefresh: true)
        let regular = try await library.loginState()

        #expect(userID(first) == 8)
        #expect(userID(refreshed) == 7)
        #expect(userID(regular) == 7)
        #expect(LibraryMutationProtocol.count("/eapi/v1/user/info") == 2)
        #expect(LibraryMutationProtocol.count("/eapi/v1/user/detail") == 2)
    }

    @Test("Library loads reject stale accounts, generations, and same-user credential revisions")
    func libraryLoadIdentity() {
        var state = MusicLibraryLoadState()
        let firstTrigger = MusicLibraryLoadTrigger(
            accountID: 7,
            credentialRevision: 10,
            reloadRevision: 0
        )
        let (accountA, initialForce) = state.begin(firstTrigger)
        #expect(!initialForce)

        let (accountB, _) = state.begin(MusicLibraryLoadTrigger(
            accountID: 8,
            credentialRevision: 11,
            reloadRevision: 0
        ))
        #expect(!state.accepts(accountA, accountID: 8, credentialRevision: 11))
        #expect(state.accepts(accountB, accountID: 8, credentialRevision: 11))

        let returnedAccountTrigger = MusicLibraryLoadTrigger(
            accountID: 7,
            credentialRevision: 12,
            reloadRevision: 0
        )
        let (accountA2, _) = state.begin(returnedAccountTrigger)
        #expect(!state.accepts(accountA, accountID: 7, credentialRevision: 12))
        #expect(!state.accepts(accountB, accountID: 7, credentialRevision: 12))
        #expect(state.accepts(accountA2, accountID: 7, credentialRevision: 12))
        let accountA2Refresh = state.identity(for: returnedAccountTrigger)

        let (sameUserNewCredential, _) = state.begin(MusicLibraryLoadTrigger(
            accountID: 7,
            credentialRevision: 13,
            reloadRevision: 0
        ))
        #expect(!state.accepts(accountA2Refresh, accountID: 7, credentialRevision: 13))
        #expect(state.accepts(sameUserNewCredential, accountID: 7, credentialRevision: 13))

        let reloadTrigger = MusicLibraryLoadTrigger(
            accountID: 7,
            credentialRevision: 13,
            reloadRevision: 1
        )
        let (reload, force) = state.begin(reloadTrigger)
        #expect(force)
        #expect(state.accepts(reload, accountID: 7, credentialRevision: 13))
        let (_, repeatedForce) = state.begin(reloadTrigger)
        #expect(!repeatedForce)
    }

    @Test("Feature mutations do not execute after their confirmed account tuple becomes stale")
    func featureMutationAccountFence() async {
        let accountA = PlaylistMutationAccount(userID: 7, credentialRevision: 10)
        var operationCount = 0

        let sameUserNewRevision = await accountA.performIfCurrent(
            userID: 7,
            confirmedRevision: 11,
            liveRevision: 11
        ) { operationCount += 1 }
        let differentUser = await accountA.performIfCurrent(
            userID: 8,
            confirmedRevision: 12,
            liveRevision: 12
        ) { operationCount += 1 }
        let unconfirmed = await accountA.performIfCurrent(
            userID: nil,
            confirmedRevision: nil,
            liveRevision: 13
        ) { operationCount += 1 }

        #expect(!sameUserNewRevision)
        #expect(!differentUser)
        #expect(!unconfirmed)
        #expect(operationCount == 0)

        let current = await accountA.performIfCurrent(
            userID: 7,
            confirmedRevision: 10,
            liveRevision: 10
        ) { operationCount += 1 }
        #expect(current)
        #expect(operationCount == 1)
    }

    @Test("Late home and user-detail responses cannot commit after an account switch")
    func appModelAccountReadOwnership() async throws {
        let snapshot = CredentialSnapshot(.authenticated(try credentials("owner-a")))
        let expectedRevision = snapshot.load().revision
        let homeGate = LibraryMutationGate()
        let detailGate = LibraryMutationGate()
        let repository = AppModelAccountReadRepository(
            snapshot: snapshot,
            homeGate: homeGate,
            detailGate: detailGate
        )
        let model = AppModel(
            repository: repository,
            defaults: UserDefaults(suiteName: UUID().uuidString)!
        )
        let route = Route.user(99)
        model.currentUserID = 7
        model.loadHome()
        model.path = [route]
        model.loadDetail(route)

        #expect(await eventually {
            let homeEntered = await homeGate.hasEntered()
            let detailEntered = await detailGate.hasEntered()
            return homeEntered && detailEntered
        })
        #expect(repository.capturedRevisions().home == expectedRevision)
        #expect(repository.capturedRevisions().detail == expectedRevision)

        _ = snapshot.store(.authenticated(try credentials("owner-b")))
        model.currentUserID = 8
        await homeGate.release()
        await detailGate.release()
        #expect(await eventually { repository.completedReadCount() == 2 })
        for _ in 0..<10 { await Task.yield() }

        #expect(model.homeSlots.first?.load == .loading)
        #expect(model.detailLoads[route] == .loading)
    }

    @Test("Cache root changes publish one value revision and stale resolves cannot overwrite")
    func cacheConfigurationRevision() async throws {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let first = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let second = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }

        let firstBookmark = try first.bookmarkData(options: .withSecurityScope)
        let secondBookmark = try second.bookmarkData(options: .withSecurityScope)
        let defaultCacheRoot = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: "TinyCloudMusic", directoryHint: .isDirectory)
            .standardizedFileURL
        defaults.set(
            firstBookmark,
            forKey: "cacheBookmark"
        )
        let gate = LibraryMutationGate()
        var downloadCacheRoots: [URL] = []
        let model = AppModel(
            repository: FixtureMusicRepository(),
            defaults: defaults,
            downloadCacheConfigurator: { downloadCacheRoots.append($0) },
            bookmarkResolver: { bookmark in
                guard let bookmark else { return nil }
                if bookmark == firstBookmark {
                    await gate.wait()
                    return first
                }
                return bookmark == secondBookmark ? second : nil
            }
        )
        #expect(await eventually { await gate.hasEntered() })
        model.setCacheFolder(second)
        let revision = model.cacheConfigurationRevision
        #expect(await eventually { model.bookmarkResolutionCompletionCount == 1 })

        await gate.release()
        #expect(await eventually { model.bookmarkResolutionCompletionCount == 2 })
        #expect(model.cacheFolderURL.standardizedFileURL == second.standardizedFileURL)
        #expect(model.cacheConfigurationRevision == revision)
        #expect(downloadCacheRoots == [
            defaultCacheRoot,
            second.standardizedFileURL
        ])

        model.clearCacheFolder()
        #expect(model.cacheConfigurationRevision == revision &+ 1)
        #expect(downloadCacheRoots.last == defaultCacheRoot)
    }

    @Test("PERF-B02 pagination entries preserve scale, order, and request progress")
    func perfB02PaginationScaleMatrix() async throws {
        for entry in LibraryPaginationEntry.allCases {
            for dataPages in [1, 10, 50, 100] {
                LibraryPaginationProtocol.reset(dataPages: dataPages)
                let recorder = LibraryPageRecorder<Int64>()
                let library = try paginationLibrary()
                let values = try await paginationIDs(entry, library: library) { recorder.record($0) }
                let expected = (1...(dataPages * 100)).map(Int64.init)

                #expect(values == expected)
                #expect(recorder.updates.count == dataPages)
                #expect(recorder.updates.first == Array(expected.prefix(100)))
                #expect(recorder.updates.last == expected)
                #expect(LibraryPaginationProtocol.count(entry.path) == expectedPaginationRequestCount(
                    entry,
                    dataPages: dataPages
                ))
                #expect(paginationRequestProgress(entry) == expectedPaginationProgress(
                    entry,
                    dataPages: dataPages
                ))
            }
        }
    }

    @Test("PERF-B02 each entry publishes its first page before a gated tail")
    func perfB02FirstPageBeforeTail() async throws {
        let firstPage = (1...100).map(Int64.init)
        for entry in LibraryPaginationEntry.allCases {
            LibraryPaginationProtocol.reset(dataPages: 10, gateTail: true)
            let recorder = LibraryPageRecorder<Int64>()
            let library = try paginationLibrary()
            let task = Task { @MainActor in
                let values = try await paginationIDs(entry, library: library) { recorder.record($0) }
                recorder.finish()
                return values
            }

            #expect(await eventually { LibraryPaginationProtocol.count(entry.path) == 2 })
            #expect(recorder.updates == [firstPage])
            #expect(!recorder.completed)
            LibraryPaginationProtocol.releaseTail()

            #expect(try await task.value == (1...1_000).map(Int64.init))
            #expect(recorder.completed)
        }
    }

    @Test("PERF-B02 duplicate, empty, and repeated-cursor tails terminate independently")
    func perfB02TerminationFences() async throws {
        let firstPage = (1...100).map(Int64.init)
        for entry in LibraryPaginationEntry.allCases {
            LibraryPaginationProtocol.reset(dataPages: 1, tail: .duplicate)
            let duplicateLibrary = try paginationLibrary()
            #expect(try await paginationIDs(entry, library: duplicateLibrary) == firstPage)
            #expect(LibraryPaginationProtocol.count(entry.path) == 2)

            LibraryPaginationProtocol.reset(dataPages: 1, tail: .empty)
            let emptyLibrary = try paginationLibrary()
            #expect(try await paginationIDs(entry, library: emptyLibrary) == firstPage)
            #expect(LibraryPaginationProtocol.count(entry.path) == 2)
        }

        for entry in [LibraryPaginationEntry.mixedFollowing, .followingUsers] {
            LibraryPaginationProtocol.reset(dataPages: 2, tail: .repeatedCursor)
            let library = try paginationLibrary()
            #expect(try await paginationIDs(entry, library: library) == (1...200).map(Int64.init))
            #expect(LibraryPaginationProtocol.count(entry.path) == 2)
        }
    }

    @Test("PERF-B04 large favorite batch records serial requests and Observation phases")
    func perfB04LargeBatchObservationPhases() async throws {
        LibraryMutationProtocol.reset()
        let stepGate = LibraryMutationStepGate()
        let fixture = try likedSongFixture("perf-b04-scale") { await stepGate.wait() }
        let songIDs = (1...1_000).map(Int64.init)
        let invalidations = LibraryObservationCounter()
        var phaseInvalidations: [Int] = []
        var phaseRequests: [Int] = []
        let task = Task { try await fixture.model.favoriteSongs(songIDs) }

        for expectedCount in 1...songIDs.count {
            #expect(await eventually { await stepGate.hasEntered(expectedCount) })
            withObservationTracking {
                _ = fixture.model.likedSongIDs
            } onChange: {
                invalidations.increment()
            }
            await stepGate.releaseNext()
            #expect(await eventually { fixture.model.likedSongIDs.count == expectedCount })
            if expectedCount.isMultiple(of: 100) {
                phaseInvalidations.append(invalidations.value)
                phaseRequests.append(LibraryMutationProtocol.count("/eapi/song/like"))
            }
        }

        #expect(try await task.value == songIDs.count)
        #expect(fixture.model.likedSongIDs == Set(songIDs))
        #expect(invalidations.value == songIDs.count)
        #expect(phaseInvalidations == Array(stride(from: 100, through: 1_000, by: 100)))
        #expect(phaseRequests == phaseInvalidations)
        #expect(LibraryMutationProtocol.count("/eapi/song/like") == songIDs.count)
        #expect(favoriteRequestIDs() == songIDs)
        #expect(fixture.model.pendingMutations.isEmpty)
    }

    @Test("PERF-B04 large favorite failure, cancellation, and revision fences preserve exact prefixes")
    func perfB04FailureCancellationRevisionFences() async throws {
        let songIDs = (1...100).map(Int64.init)

        LibraryMutationProtocol.reset()
        LibraryMutationProtocol.fail("/eapi/song/like", onCall: 51)
        let partial = try likedSongFixture("perf-b04-partial")
        do {
            _ = try await partial.model.favoriteSongs(songIDs)
            Issue.record("The configured favorite request should fail")
        } catch let failure as FavoriteSongsFailure {
            #expect(failure.successfulIDs == Array(songIDs.prefix(50)))
            #expect(failure.failedID == 51)
            #expect(failure.unattemptedIDs == Array(songIDs.dropFirst(51)))
        }
        #expect(partial.model.likedSongIDs == Set(songIDs.prefix(50)))
        #expect(favoriteRequestIDs() == Array(songIDs.prefix(51)))
        #expect(partial.model.pendingMutations.isEmpty)

        LibraryMutationProtocol.reset()
        LibraryMutationProtocol.blockResponse("/eapi/song/like", onCall: 2)
        let cancellation = try likedSongFixture("perf-b04-cancel")
        let cancelledTask = Task { try await cancellation.model.favoriteSongs(songIDs) }
        #expect(await eventually {
            cancellation.model.likedSongIDs == [1]
                && LibraryMutationProtocol.count("/eapi/song/like") == 2
        })
        cancelledTask.cancel()
        LibraryMutationProtocol.releaseBlockedResponse()
        do {
            _ = try await cancelledTask.value
            Issue.record("The cancelled favorite batch should not complete")
        } catch is CancellationError {
        }
        let cancelledRequests = favoriteRequestIDs()
        #expect(cancelledRequests == Array(songIDs.prefix(2)))
        #expect(cancellation.model.likedSongIDs == [1])
        #expect(cancellation.model.pendingMutations.isEmpty)

        LibraryMutationProtocol.reset()
        LibraryMutationProtocol.blockResponse("/eapi/song/like", onCall: 2)
        let revision = try likedSongFixture("perf-b04-revision")
        let staleTask = Task { try await revision.model.favoriteSongs(songIDs) }
        #expect(await eventually {
            revision.model.likedSongIDs == [1]
                && LibraryMutationProtocol.count("/eapi/song/like") == 2
        })
        _ = revision.snapshot.store(.authenticated(try credentials("perf-b04-revision-current")))
        LibraryMutationProtocol.releaseBlockedResponse()
        do {
            _ = try await staleTask.value
            Issue.record("The stale-revision favorite batch should not complete")
        } catch is CancellationError {
        }
        let revisionRequests = favoriteRequestIDs()
        #expect(revisionRequests == Array(songIDs.prefix(2)))
        #expect(revision.model.likedSongIDs == [1])
        #expect(revision.model.pendingMutations.isEmpty)
    }

    @Test("User playlists publish the first page before the tail and preserve final order")
    func userPlaylistsPublishProgressively() async throws {
        LibraryPaginationProtocol.reset()
        let recorder = LibraryPageRecorder<Playlist>()
        let library = try paginationLibrary()
        let revision = library.transport.credentialSnapshotValue().revision
        let task = Task { @MainActor in
            let values = try await library.userPlaylists(
                userID: 7,
                expectedCredentialRevision: revision
            ) { recorder.record($0) }
            recorder.finish()
            return values
        }

        #expect(await eventually { LibraryPaginationProtocol.count("/eapi/user/playlist") == 2 })
        #expect(recorder.updates.map { $0.map(\.id) } == [[1, 2]])
        #expect(!recorder.completed)
        LibraryPaginationProtocol.releaseTail()

        let values = try await task.value
        #expect(values.map(\.id) == [1, 2, 3])
        #expect(recorder.updates.map { $0.map(\.id) } == [[1, 2], [1, 2, 3]])
        #expect(LibraryPaginationProtocol.count("/eapi/user/playlist") == 2)
    }

    @Test("User playlists do not truncate after one thousand items")
    func userPlaylistsHaveNoFixedTotalLimit() async throws {
        LibraryPaginationProtocol.reset(largePlaylist: true)
        let library = try paginationLibrary()

        let values = try await library.userPlaylists(
            userID: 7,
            expectedCredentialRevision: library.transport.credentialSnapshotValue().revision
        )

        #expect(values.count == 1_001)
        #expect(values.first?.id == 1)
        #expect(values.last?.id == 1_001)
        #expect(LibraryPaginationProtocol.count("/eapi/user/playlist") == 11)
    }

    @Test("Mixed following publishes progressively without expanding size")
    func mixedFollowingPreservesTotalSize() async throws {
        LibraryPaginationProtocol.reset()
        let recorder = LibraryPageRecorder<MusicLibraryFollow>()
        let library = try paginationLibrary()
        let task = Task { @MainActor in
            let values = try await library.myFollowing(
                size: 3,
                expectedCredentialRevision: library.transport.credentialSnapshotValue().revision
            ) { recorder.record($0) }
            recorder.finish()
            return values
        }

        #expect(await eventually {
            LibraryPaginationProtocol.count("/eapi/user/follow/users/mixed/get/v2") == 2
        })
        #expect(recorder.updates.map { $0.map(\.resourceID) } == [[1, 2]])
        #expect(!recorder.completed)
        LibraryPaginationProtocol.releaseTail()

        let values = try await task.value
        #expect(values.map(\.resourceID) == [1, 2, 3])
        #expect(recorder.updates.map { $0.map(\.resourceID) } == [[1, 2], [1, 2, 3]])
        #expect(LibraryPaginationProtocol.count("/eapi/user/follow/users/mixed/get/v2") == 2)
    }

    @Test("Following users publish progressively without expanding size")
    func followingUsersPreserveTotalSize() async throws {
        LibraryPaginationProtocol.reset()
        let recorder = LibraryPageRecorder<MusicLibraryUser>()
        let library = try paginationLibrary()
        let task = Task { @MainActor in
            let values = try await library.followingUsers(userID: 7, size: 3) { recorder.record($0) }
            recorder.finish()
            return values
        }

        #expect(await eventually { LibraryPaginationProtocol.count("/eapi/user/v3/follows/get") == 2 })
        #expect(recorder.updates.map { $0.map(\.id) } == [[1, 2]])
        #expect(!recorder.completed)
        LibraryPaginationProtocol.releaseTail()

        let values = try await task.value
        #expect(values.map(\.id) == [1, 2, 3])
        #expect(recorder.updates.map { $0.map(\.id) } == [[1, 2], [1, 2, 3]])
        #expect(LibraryPaginationProtocol.count("/eapi/user/v3/follows/get") == 2)
    }

    @Test("Followed artists publish progressively without expanding offset range")
    func followedArtistsPreserveRange() async throws {
        LibraryPaginationProtocol.reset()
        let recorder = LibraryPageRecorder<MusicLibraryArtist>()
        let library = try paginationLibrary()
        let task = Task { @MainActor in
            let values = try await library.followedArtists(userID: 7, offset: 50, limit: 3) {
                recorder.record($0)
            }
            recorder.finish()
            return values
        }

        #expect(await eventually { LibraryPaginationProtocol.count("/eapi/user/sub/artist/get") == 2 })
        #expect(recorder.updates.map { $0.map(\.id) } == [[1, 2]])
        #expect(!recorder.completed)
        LibraryPaginationProtocol.releaseTail()

        let values = try await task.value
        #expect(values.map(\.id) == [1, 2, 3])
        #expect(recorder.updates.map { $0.map(\.id) } == [[1, 2], [1, 2, 3]])
        #expect(LibraryPaginationProtocol.count("/eapi/user/sub/artist/get") == 2)
    }

    @Test("Duplicate and non-advancing pages terminate")
    func paginationProgress() {
        let item = SearchItem.song(Song(
            id: 1,
            name: "One",
            artists: [ArtistSummary(id: 2, name: "Artist")],
            album: AlbumSummary(
                id: 3,
                name: "Album",
                artwork: Artwork(symbol: "music.note", accent: .blue)
            ),
            duration: .seconds(1)
        ))
        let first = SearchPage(items: [item], offset: 0, hasMore: true)
        let duplicate = SearchPage(items: [item, item], offset: 20, hasMore: true)
        let merged = AppModel.mergedSearchPage(first, duplicate)
        #expect(merged.items == [item])
        #expect(!merged.hasMore)

        let cloud = CloudSong(
            id: 1,
            song: nil,
            name: "One",
            artist: "",
            album: "",
            fileName: "one.mp3",
            fileSize: 1,
            addedAt: nil
        )
        let cloudFirst = CloudSongPage(songs: [cloud], offset: 30, hasMore: true, totalCount: 2)
        let cloudRepeat = CloudSongPage(songs: [cloud], offset: 30, hasMore: true, totalCount: 2)
        let cloudMerged = cloudFirst.merging(cloudRepeat)
        #expect(cloudMerged.addedUniqueCount == 0)
        #expect(!cloudMerged.page.hasMore)
    }

    private func paginationIDs(
        _ entry: LibraryPaginationEntry,
        library: LiveMusicLibrary,
        onUpdate: (@MainActor @Sendable ([Int64]) -> Void)? = nil
    ) async throws -> [Int64] {
        switch entry {
        case .playlists:
            let values = try await library.userPlaylists(
                userID: 7,
                expectedCredentialRevision: library.transport.credentialSnapshotValue().revision
            ) { onUpdate?($0.map(\.id)) }
            return values.map(\.id)
        case .mixedFollowing:
            let values = try await library.myFollowing(
                expectedCredentialRevision: library.transport.credentialSnapshotValue().revision
            ) { onUpdate?($0.map(\.resourceID)) }
            return values.map(\.resourceID)
        case .followingUsers:
            let values = try await library.followingUsers(userID: 7) { onUpdate?($0.map(\.id)) }
            return values.map(\.id)
        case .followedArtists:
            let values = try await library.followedArtists(userID: 7) { onUpdate?($0.map(\.id)) }
            return values.map(\.id)
        }
    }

    private func expectedPaginationRequestCount(
        _ entry: LibraryPaginationEntry,
        dataPages: Int
    ) -> Int {
        entry == .playlists ? dataPages : dataPages + 1
    }

    private func paginationRequestProgress(_ entry: LibraryPaginationEntry) -> [String] {
        LibraryPaginationProtocol.bodies(entry.path)
            .compactMap(libraryMutationPayload)
            .map { payload in
                switch entry {
                case .playlists:
                    return "\(payloadString(payload["offset"])):\(payloadString(payload["limit"]))"
                case .followedArtists:
                    return "\(payloadString(payload["offset"])):\(payloadString(payload["limit"]))"
                case .mixedFollowing, .followingUsers:
                    guard let page = payload["page"] as? String,
                          let data = page.data(using: .utf8),
                          let object = try? JSONSerialization.jsonObject(with: data),
                          let values = object as? [String: Any]
                    else { return "invalid" }
                    return "\(payloadString(values["cursor"])):\(payloadString(values["size"]))"
                }
            }
    }

    private func expectedPaginationProgress(
        _ entry: LibraryPaginationEntry,
        dataPages: Int
    ) -> [String] {
        switch entry {
        case .playlists:
            (0..<dataPages).map { "\($0 * 100):100" }
        case .followedArtists:
            (0...dataPages).map { "\($0 * 100):100" }
        case .mixedFollowing, .followingUsers:
            [":100"] + (1...dataPages).map { "cursor-\($0):100" }
        }
    }

    private func payloadString(_ value: Any?) -> String {
        if let value = value as? String { return value }
        if let value = value as? NSNumber { return value.stringValue }
        return ""
    }

    private func favoriteRequestIDs() -> [Int64] {
        LibraryMutationProtocol.bodies("/eapi/song/like")
            .compactMap(libraryMutationPayload)
            .compactMap { payload in
                if let value = payload["trackId"] as? NSNumber { return value.int64Value }
                if let value = payload["trackId"] as? String { return Int64(value) }
                return nil
            }
    }

    private func transport(
        snapshot: CredentialSnapshot,
        beforeSendingRequest: (@Sendable () async -> Void)? = nil
    ) -> EAPITransport {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LibraryMutationProtocol.self]
        return EAPITransport(
            session: URLSession(configuration: configuration),
            credentialSnapshot: snapshot,
            beforeSendingRequest: beforeSendingRequest
        )
    }

    private func paginationLibrary() throws -> LiveMusicLibrary {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LibraryPaginationProtocol.self]
        return LiveMusicLibrary(transport: EAPITransport(
            session: URLSession(configuration: configuration),
            credentialSnapshot: CredentialSnapshot(.authenticated(try credentials("pagination")))
        ))
    }

    private func session(
        snapshot: CredentialSnapshot,
        transport: EAPITransport
    ) -> SessionController {
        SessionController(
            store: CredentialStore(service: "TinyCloudMusicTests.\(UUID())"),
            credentialSnapshot: snapshot,
            transport: transport,
            validator: { _ in true },
            vipValidator: { _ in true },
            persistCredentials: { _ in }
        )
    }

    private func likedSongFixture(
        _ token: String,
        beforeSendingRequest: (@Sendable () async -> Void)? = nil
    ) throws -> (
        model: AppModel,
        snapshot: CredentialSnapshot,
        revision: UInt64,
        playlists: [Playlist]
    ) {
        let snapshot = CredentialSnapshot(.authenticated(try credentials(token)))
        let transport = transport(
            snapshot: snapshot,
            beforeSendingRequest: beforeSendingRequest
        )
        let model = AppModel(
            repository: FixtureMusicRepository(),
            library: LiveMusicLibrary(transport: transport),
            extras: LiveMusicExtras(transport: transport)
        )
        let revision = snapshot.load().revision
        model.installConfirmedAccount(userID: 8, credentialRevision: revision)
        var playlist = Playlist(
            id: 900,
            name: "Liked",
            creator: "Fixture",
            description: "",
            artwork: Artwork(symbol: "heart.fill", accent: .red)
        )
        playlist.creatorID = 8
        playlist.specialType = 5
        return (model, snapshot, revision, [playlist])
    }

    private func credentials(_ token: String) throws -> SessionCredentials {
        try SessionCredentials(
            cookie: "MUSIC_U=fixture-\(token); __csrf=fixture",
            musicU: "vip-fixture-\(token)",
            deviceID: String(repeating: "D", count: 52)
        )
    }

    private func accountUser(_ id: Int64) -> MusicLibraryUser {
        MusicLibraryUser(
            id: id,
            nickname: "Fixture",
            signature: "",
            detail: "",
            avatarURL: nil,
            gender: 0,
            level: 0,
            listenedSongCount: 0,
            followerCount: 0,
            followingCount: 0,
            isFollowed: false,
            followsCurrentUser: false
        )
    }

    private func song(_ id: Int64) -> Song {
        Song(
            id: id,
            name: "Fixture",
            artists: [ArtistSummary(id: 1, name: "Artist")],
            album: AlbumSummary(
                id: 2,
                name: "Album",
                artwork: Artwork(symbol: "music.note", accent: .blue)
            ),
            duration: .seconds(1)
        )
    }

    private func userID(_ state: MusicLibraryLoginState) -> Int64? {
        guard case let .loggedIn(user) = state else { return nil }
        return user.id
    }

    private func eventually(_ condition: () async -> Bool) async -> Bool {
        for _ in 0..<200 {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return false
    }

    private func slice(_ source: String, from start: String, to end: String) throws -> String {
        let lower = try #require(source.range(of: start)?.lowerBound)
        let upper = try #require(source.range(of: end, range: lower..<source.endIndex)?.lowerBound)
        return String(source[lower..<upper])
    }
}

private func libraryMutationPayload(_ body: Data) -> [String: Any]? {
    guard let text = String(data: body, encoding: .utf8), text.hasPrefix("params=") else { return nil }
    let hex = text.dropFirst("params=".count)
    var encrypted = Data(capacity: hex.count / 2)
    var index = hex.startIndex
    while index < hex.endIndex {
        guard let next = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex),
              let byte = UInt8(hex[index..<next], radix: 16)
        else { return nil }
        encrypted.append(byte)
        index = next
    }
    guard let envelope = try? EAPICodec.decrypt(encrypted),
          let text = String(data: envelope, encoding: .utf8)
    else { return nil }
    let parts = text.components(separatedBy: "-36cd479b6b5-")
    guard parts.count == 3,
          let data = parts[1].data(using: .utf8),
          let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return nil }
    return payload
}
