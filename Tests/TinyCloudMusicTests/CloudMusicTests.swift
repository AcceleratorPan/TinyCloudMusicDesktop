import Foundation

#if !CLOUD_MUSIC_CHECK && canImport(Testing)
import Testing
@testable import TinyCloudMusic
#endif

private enum CloudMusicCheckError: Error {
    case failed(String)
}

private final class CloudMusicProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var paths: [String] = []
    nonisolated(unsafe) private static var detailRequestCount = 0
    nonisolated(unsafe) private static var blockAudio = false
    nonisolated(unsafe) private static var audioStarted = false
    nonisolated(unsafe) private static var denyCloudAccess = false

    static func reset(blockAudio: Bool = false, denyCloudAccess: Bool = false) {
        lock.withLock {
            paths = []
            detailRequestCount = 0
            self.blockAudio = blockAudio
            audioStarted = false
            self.denyCloudAccess = denyCloudAccess
        }
    }

    static func requestCount(for path: String) -> Int {
        lock.withLock { paths.count(where: { $0 == path }) }
    }

    static var didStartAudio: Bool { lock.withLock { audioStarted } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let path = request.url?.path ?? ""
        let state = Self.lock.withLock { () -> (detailBatch: Int, blockAudio: Bool, denyCloudAccess: Bool) in
            Self.paths.append(path)
            if path == "/weapi/v1/cloud/get/byids" { Self.detailRequestCount += 1 }
            if path == "/cloud-audio" { Self.audioStarted = true }
            return (Self.detailRequestCount, Self.blockAudio, Self.denyCloudAccess)
        }
        if path == "/cloud-audio", state.blockAudio { return }

        let body: Data
        switch path {
        case "/weapi/v1/cloud/get/byids":
            let ids = state.detailBatch == 1 ? Array((1...50).reversed()) : [51]
            body = try! JSONSerialization.data(withJSONObject: [
                "code": 200,
                "data": ids.map { ["songId": $0, "songName": "Song \($0)"] }
            ])
        case "/eapi/cloud/dowonload":
            body = state.denyCloudAccess
                ? Data(#"{"code":403,"message":"forbidden"}"#.utf8)
                : Data(#"{"code":0,"data":{"url":"https://m1.music.126.net/cloud-audio","type":""}}"#.utf8)
        case "/eapi/v1/user/info":
            body = Data(#"{"code":200,"userPoint":{"userId":7}}"#.utf8)
        case "/eapi/v1/user/detail":
            body = Data(#"{"code":200,"profile":{"userId":7,"nickname":"Tester"}}"#.utf8)
        case "/eapi/cloud/lyric/get":
            body = state.denyCloudAccess
                ? Data(#"{"code":403,"message":"forbidden"}"#.utf8)
                : Data(#"{"code":0,"lrc":{"lyric":""},"tlyric":{"lyric":""}}"#.utf8)
        case "/cloud-audio":
            body = Data("fLaC".utf8)
        default:
            body = Data(#"{"code":404}"#.utf8)
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": path == "/cloud-audio" ? "audio/flac" : "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private func cloudTransport() -> (EAPITransport, URLSession) {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [CloudMusicProtocol.self]
    let session = URLSession(configuration: configuration)
    return (
        EAPITransport(
            session: session,
            cookie: "MUSIC_U=test; __csrf=test",
            musicU: "",
            weapiSecretKey: "abcdefghijklmnop"
        ),
        session
    )
}

@MainActor
private func verifyCloudModelsAndSecurity() throws {
    let decoder = LiveMusicRepository().decodeLiveSong
    let first = CloudMusicDecoder.page([
        "code": 200,
        "count": 3,
        "more": true,
        "data": [
            [
                "songId": 1,
                "songName": "Matched",
                "artist": "Artist",
                "fileName": "matched.flac",
                "fileSize": 1_024,
                "addTime": 1_700_000_000_000,
                "simpleSong": [
                    "id": 1,
                    "name": "Matched",
                    "ar": [["id": 2, "name": "Artist"]],
                    "al": ["id": 3, "name": "Album"],
                    "dt": 180_000
                ]
            ],
            ["songId": 2, "songName": "Unmatched", "fileName": "raw.mp3"]
        ]
    ], offset: 0, decodeSong: decoder)
    let second = CloudSongPage(
        songs: [first.songs[1], CloudSong(
            id: 3, song: nil, name: "Third", artist: "", album: "", fileName: "third.mp3",
            fileSize: 0, addedAt: nil
        )],
        offset: 2,
        hasMore: false,
        totalCount: 3
    )
    let combined = first.appending(second)
    guard first.songs.count == 2,
          first.songs[0].isMatched,
          !first.songs[1].isMatched,
          first.offset == 0,
          first.hasMore,
          first.totalCount == 3,
          combined.songs.map(\.id) == [1, 2, 3],
          !combined.hasMore,
          combined.totalCount == 3
    else { throw CloudMusicCheckError.failed("Cloud fixtures or pagination failed") }

    guard LiveMusicLibrary.cloudDownloadEndpoint.logicalPath == "/api/cloud/dowonload",
          LiveMusicLibrary.cloudDownloadEndpoint.physicalURL.path == "/eapi/cloud/dowonload",
          LiveMusicLibrary.cloudLyricEndpoint.logicalPath == "/api/cloud/lyric/get",
          CloudMusicDecoder.isAllowedDownloadURL(URL(string: "https://m1.music.126.net/file.flac")!),
          !CloudMusicDecoder.isAllowedDownloadURL(URL(string: "http://m1.music.126.net/file.flac")!),
          CloudMusicDecoder.normalizedDownloadURL(URL(string: "http://m1.music.126.net/file.flac")!)?.scheme == "https",
          !CloudMusicDecoder.isAllowedDownloadURL(URL(string: "https://music.126.net.evil.test/file.flac")!)
    else { throw CloudMusicCheckError.failed("Cloud endpoint or URL validation failed") }

    do {
        _ = try CloudMusicDecoder.downloadSource([
            "code": 200,
            "data": ["songId": 2, "url": "https://m1.music.126.net/file.flac"]
        ], expectedSongID: 1)
        throw CloudMusicCheckError.failed("Cloud source song identity was not validated")
    } catch MusicDownloadError.invalidResponse {
    }
}

@MainActor
private func verifyCloudDetailBatchingAndURLCache() async throws {
    CloudMusicProtocol.reset()
    let (transport, _) = cloudTransport()
    let library = LiveMusicLibrary(transport: transport)
    let credentialRevision = library.transport.credentialSnapshotValue().revision
    let ids = (1...51).map(Int64.init)
    let details = try await library.cloudSongDetails(
        ids: ids,
        expectedCredentialRevision: credentialRevision
    )
    guard details.map(\.id) == ids,
          CloudMusicProtocol.requestCount(for: "/weapi/v1/cloud/get/byids") == 2
    else { throw CloudMusicCheckError.failed("Cloud detail batching or order failed") }

    _ = try await library.cloudDownloadSource(
        userID: 7,
        songID: 1,
        expectedCredentialRevision: credentialRevision
    )
    _ = try await library.cloudDownloadSource(
        userID: 7,
        songID: 1,
        expectedCredentialRevision: credentialRevision
    )
    guard CloudMusicProtocol.requestCount(for: "/eapi/cloud/dowonload") == 2 else {
        throw CloudMusicCheckError.failed("Cloud download URLs were cached")
    }
}

@MainActor
private func verifyCloudLocalCredentialFence() async throws {
    CloudMusicProtocol.reset()
    let (transport, session) = cloudTransport()
    defer { session.invalidateAndCancel() }
    let library = LiveMusicLibrary(transport: transport)
    let credentialRevision = library.transport.credentialSnapshotValue().revision

    _ = try await library.cloudLyrics(
        userID: 7,
        songID: 1,
        expectedCredentialRevision: credentialRevision
    )
    _ = try await library.cloudLyrics(
        userID: 7,
        songID: 2,
        expectedCredentialRevision: credentialRevision
    )
    _ = try await library.cloudDownloadSource(
        userID: 7,
        songID: 3,
        expectedCredentialRevision: credentialRevision
    )
    guard CloudMusicProtocol.requestCount(for: "/eapi/v1/user/info") == 0,
          CloudMusicProtocol.requestCount(for: "/eapi/v1/user/detail") == 0,
          CloudMusicProtocol.requestCount(for: "/eapi/cloud/lyric/get") == 2,
          CloudMusicProtocol.requestCount(for: "/eapi/cloud/dowonload") == 1
    else { throw CloudMusicCheckError.failed("Cloud access performed a remote login check") }

    let guestLibrary = LiveMusicLibrary(transport: EAPITransport(
        session: session,
        credentialSnapshot: CredentialSnapshot(.guest),
        weapiSecretKey: "abcdefghijklmnop"
    ))
    do {
        _ = try await guestLibrary.cloudLyrics(
            userID: 7,
            songID: 4,
            expectedCredentialRevision: guestLibrary.transport.credentialSnapshotValue().revision
        )
        throw CloudMusicCheckError.failed("Guest cloud lyrics reached the endpoint")
    } catch let error as EAPIError {
        guard case .service(code: 403, _) = error else { throw error }
    }
    guard CloudMusicProtocol.requestCount(for: "/eapi/cloud/lyric/get") == 2 else {
        throw CloudMusicCheckError.failed("Guest cloud request was sent")
    }

    let registeredGuestLibrary = LiveMusicLibrary(transport: EAPITransport(
        session: session,
        credentialSnapshot: CredentialSnapshot(.authenticated(try SessionCredentials(
            cookie: "MUSIC_A=guest-token; __csrf=guest",
            musicU: "",
            deviceID: "guest-device"
        ))),
        weapiSecretKey: "abcdefghijklmnop"
    ))
    do {
        _ = try await registeredGuestLibrary.cloudDownloadSource(
            userID: 7,
            songID: 4,
            expectedCredentialRevision: registeredGuestLibrary.transport.credentialSnapshotValue().revision
        )
        throw CloudMusicCheckError.failed("Registered guest cloud source reached the endpoint")
    } catch let error as EAPIError {
        guard case .service(code: 403, _) = error else { throw error }
    }
    guard CloudMusicProtocol.requestCount(for: "/eapi/cloud/dowonload") == 1 else {
        throw CloudMusicCheckError.failed("Registered guest cloud request was sent")
    }

    CloudMusicProtocol.reset(denyCloudAccess: true)
    do {
        _ = try await library.cloudLyrics(
            userID: 7,
            songID: 5,
            expectedCredentialRevision: credentialRevision
        )
        throw CloudMusicCheckError.failed("Cloud lyric permission error was swallowed")
    } catch let error as EAPIError {
        guard case .service(code: 403, _) = error else { throw error }
    }
    do {
        _ = try await library.cloudDownloadSource(
            userID: 7,
            songID: 5,
            expectedCredentialRevision: credentialRevision
        )
        throw CloudMusicCheckError.failed("Cloud source permission error was swallowed")
    } catch let error as EAPIError {
        guard case .service(code: 403, _) = error else { throw error }
    }
    guard CloudMusicProtocol.requestCount(for: "/eapi/v1/user/info") == 0,
          CloudMusicProtocol.requestCount(for: "/eapi/v1/user/detail") == 0
    else { throw CloudMusicCheckError.failed("Denied cloud access performed a remote login check") }
}

@MainActor
private func verifyCloudDownloadWithoutLyricsAndCancellation() async throws {
    CloudMusicProtocol.reset()
    let (transport, session) = cloudTransport()
    defer { session.invalidateAndCancel() }
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let manager = MusicDownloadManager(
        transport: transport,
        session: session,
        resumeStore: MusicDownloadResumeStore(directory: root.appending(path: "resume")),
        targetAllocator: MusicDownloadTargetAllocator()
    )
    let cloudSong = CloudSong(
        id: 90,
        song: nil,
        name: "Cloud",
        artist: "Artist",
        album: "",
        fileName: "original.flac",
        fileSize: 4,
        addedAt: nil
    )
    manager.enqueue(
        cloudSong: cloudSong,
        userID: 7,
        expectedCredentialRevision: transport.credentialSnapshotValue().revision,
        to: root
    )
    guard manager.items[cloudSong.id] == MusicDownloadItem(
        id: cloudSong.id,
        title: cloudSong.name,
        artist: cloudSong.artist,
        quality: "原文件",
        expectedBytes: cloudSong.fileSize
    ) else { throw CloudMusicCheckError.failed("Cloud download metadata was not retained") }
    for _ in 0..<100 {
        if case .completed? = manager.states[cloudSong.id] { break }
        if case let .failed(message)? = manager.states[cloudSong.id] {
            throw CloudMusicCheckError.failed(message)
        }
        try await Task.sleep(for: .milliseconds(25))
    }
    guard case let .completed(audioURL, lyricURL)? = manager.states[cloudSong.id],
          audioURL.pathExtension == "flac",
          lyricURL == nil,
          FileManager.default.fileExists(atPath: audioURL.path),
          try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .allSatisfy({ $0.pathExtension != "part" })
    else { throw CloudMusicCheckError.failed("Empty cloud lyrics prevented audio commit") }

    CloudMusicProtocol.reset(blockAudio: true)
    let cancelledSong = CloudSong(
        id: 91, song: nil, name: "Cancel", artist: "", album: "", fileName: "cancel.mp3",
        fileSize: 4, addedAt: nil
    )
    manager.enqueue(
        cloudSong: cancelledSong,
        userID: 7,
        expectedCredentialRevision: transport.credentialSnapshotValue().revision,
        to: root,
        includeLyrics: false
    )
    for _ in 0..<100 where !CloudMusicProtocol.didStartAudio {
        try await Task.sleep(for: .milliseconds(10))
    }
    manager.cancel(songID: cancelledSong.id)
    try await Task.sleep(for: .milliseconds(50))
    guard manager.states[cancelledSong.id] == .cancelled,
          try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .allSatisfy({ $0.pathExtension != "part" })
    else { throw CloudMusicCheckError.failed("Cancelled cloud download left a part file") }
}

@MainActor
private func verifyDownloadConcurrencyLimit() async throws {
    CloudMusicProtocol.reset(blockAudio: true)
    let (transport, session) = cloudTransport()
    let root = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let manager = MusicDownloadManager(
        transport: transport,
        session: session,
        maximumConcurrentDownloads: 2,
        retryPolicy: MusicDownloadRetryPolicy(maximumAttempts: 1, baseDelay: 0, maximumDelay: 0),
        resumeStore: MusicDownloadResumeStore(directory: root.appending(path: "resume")),
        targetAllocator: MusicDownloadTargetAllocator()
    )

    for id in Int64(201)...205 {
        manager.enqueue(
            cloudSong: CloudSong(
                id: id,
                song: nil,
                name: "Concurrent \(id)",
                artist: "Artist",
                album: "",
                fileName: "\(id).flac",
                fileSize: 4,
                addedAt: nil
            ),
            userID: 7,
            expectedCredentialRevision: transport.credentialSnapshotValue().revision,
            to: root,
            includeLyrics: false
        )
    }
    guard manager.enqueue(
        video: .mv(42),
        title: "Queued video",
        creator: "Artist",
        availableResolutions: [720, 480],
        to: root,
        quality: .high
    ) else { throw CloudMusicCheckError.failed("Video was not added to the shared queue") }
    let duplicateAccepted = manager.enqueue(
        cloudSong: CloudSong(
            id: 201,
            song: nil,
            name: "Concurrent 201",
            artist: "Artist",
            album: "",
            fileName: "201.flac",
            fileSize: 4,
            addedAt: nil
        ),
        userID: 7,
        expectedCredentialRevision: transport.credentialSnapshotValue().revision,
        to: root,
        includeLyrics: false
    )
    guard !duplicateAccepted else {
        throw CloudMusicCheckError.failed("Duplicate enqueue replaced an active download")
    }

    for _ in 0..<100 where CloudMusicProtocol.requestCount(for: "/cloud-audio") < 2 {
        try await Task.sleep(for: .milliseconds(10))
    }
    guard manager.runningDownloadCount == 2,
          manager.queuedDownloadCount == 4,
          manager.videoStates["mv-42"] == .queued,
          CloudMusicProtocol.requestCount(for: "/cloud-audio") == 2
    else { throw CloudMusicCheckError.failed("Download concurrency exceeded the configured limit") }

    manager.setMaximumConcurrentDownloads(4)
    for _ in 0..<100 where CloudMusicProtocol.requestCount(for: "/cloud-audio") < 4 {
        try await Task.sleep(for: .milliseconds(10))
    }
    guard manager.runningDownloadCount == 4,
          manager.queuedDownloadCount == 2,
          CloudMusicProtocol.requestCount(for: "/cloud-audio") == 4
    else { throw CloudMusicCheckError.failed("Increasing concurrency did not fill available slots") }

    manager.setMaximumConcurrentDownloads(1)
    guard manager.maximumConcurrentDownloads == 1, manager.runningDownloadCount == 4 else {
        throw CloudMusicCheckError.failed("Lowering concurrency interrupted active downloads")
    }
    manager.cancelAll()
    for _ in 0..<100 where manager.runningDownloadCount > 0 {
        try await Task.sleep(for: .milliseconds(10))
    }
    guard manager.runningDownloadCount == 0,
          manager.queuedDownloadCount == 0,
          manager.videoStates["mv-42"] == .cancelled
    else {
        throw CloudMusicCheckError.failed("Cancelling downloads did not release scheduler slots")
    }
}

@MainActor
private func verifyCloudRecoveryAccountFilter() throws {
    CloudMusicProtocol.reset(blockAudio: true)
    let (transport, session) = cloudTransport()
    defer { session.invalidateAndCancel() }
    let root = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = MusicDownloadResumeStore(directory: root.appending(path: "resume"))
    let manager = MusicDownloadManager(
        transport: transport,
        session: session,
        maximumConcurrentDownloads: 1,
        resumeStore: store,
        targetAllocator: MusicDownloadTargetAllocator()
    )
    for (songID, userID) in [(301 as Int64, 7 as Int64), (302, 8)] {
        _ = manager.enqueue(
            cloudSong: CloudSong(
                id: songID,
                song: nil,
                name: "Account \(userID)",
                artist: "Artist",
                album: "",
                fileName: "\(songID).flac",
                fileSize: 4,
                addedAt: nil
            ),
            userID: userID,
            expectedCredentialRevision: transport.credentialSnapshotValue().revision,
            to: root,
            includeLyrics: false
        )
    }

    manager.cancelCloudDownloads(exceptUserID: 7)
    let recoveredUserIDs = store.recoverableDownloads().compactMap { recovery -> Int64? in
        guard case let .cloud(userID, _) = recovery.request.source else { return nil }
        return userID
    }
    guard manager.states[301] == .running(progress: nil),
          manager.states[302] == .cancelled,
          recoveredUserIDs == [7]
    else { throw CloudMusicCheckError.failed("Matching cloud recovery was cancelled during account setup") }
    manager.cancelAll()
}

@MainActor
private func verifyQueuedCloudDownloadKeepsIntentRevision() async throws {
    CloudMusicProtocol.reset(blockAudio: true)
    let snapshot = CredentialSnapshot(.authenticated(try SessionCredentials(
        cookie: "MUSIC_U=account-a; __csrf=test",
        musicU: "",
        deviceID: "cloud-download-test-device"
    )))
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [CloudMusicProtocol.self]
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    let transport = EAPITransport(
        session: session,
        credentialSnapshot: snapshot,
        weapiSecretKey: "abcdefghijklmnop"
    )
    let root = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let manager = MusicDownloadManager(
        transport: transport,
        session: session,
        maximumConcurrentDownloads: 1,
        resumeStore: MusicDownloadResumeStore(directory: root.appending(path: "resume")),
        targetAllocator: MusicDownloadTargetAllocator()
    )
    let revisionA = snapshot.load().revision
    manager.setCloudDownloadAccount(userID: 7, credentialRevision: revisionA)

    for songID in [401 as Int64, 402] {
        guard manager.enqueue(
            cloudSong: CloudSong(
                id: songID,
                song: nil,
                name: "Queued \(songID)",
                artist: "Artist",
                album: "",
                fileName: "\(songID).flac",
                fileSize: 4,
                addedAt: nil
            ),
            userID: 7,
            expectedCredentialRevision: revisionA,
            to: root,
            includeLyrics: false
        ) else { throw CloudMusicCheckError.failed("Cloud intent was not enqueued") }
    }
    for _ in 0..<100 where !CloudMusicProtocol.didStartAudio {
        try await Task.sleep(for: .milliseconds(10))
    }
    guard CloudMusicProtocol.didStartAudio,
          CloudMusicProtocol.requestCount(for: "/eapi/cloud/dowonload") == 1,
          manager.states[402] == .queued
    else { throw CloudMusicCheckError.failed("Cloud fixture did not leave the second intent queued") }

    _ = snapshot.store(.authenticated(try SessionCredentials(
        cookie: "MUSIC_U=account-b; __csrf=test",
        musicU: "",
        deviceID: "cloud-download-test-device"
    )))
    manager.cancel(songID: 401)
    for _ in 0..<100 where manager.states[402] != .cancelled {
        try await Task.sleep(for: .milliseconds(10))
    }
    guard manager.states[402] == .cancelled,
          CloudMusicProtocol.requestCount(for: "/eapi/cloud/dowonload") == 1
    else { throw CloudMusicCheckError.failed("Queued A cloud intent sent with B credentials") }
    manager.setCloudDownloadAccount(
        userID: 7,
        credentialRevision: snapshot.load().revision
    )
}

#if CLOUD_MUSIC_CHECK
@main
private enum CloudMusicCheck {
    @MainActor
    static func main() async throws {
        try verifyCloudModelsAndSecurity()
        try await verifyCloudDetailBatchingAndURLCache()
        try await verifyCloudDownloadWithoutLyricsAndCancellation()
        try await verifyDownloadConcurrencyLimit()
        try verifyCloudRecoveryAccountFilter()
        print("Cloud music checks passed")
    }
}
#elseif canImport(Testing)
@Suite("Cloud music", .serialized)
@MainActor
struct CloudMusicTests {
    @Test("Fixtures, pagination, and URL validation")
    func modelsAndSecurity() throws {
        try verifyCloudModelsAndSecurity()
    }

    @Test("Details batch at 50 in input order and URLs are never cached")
    func detailBatchingAndURLCache() async throws {
        try await verifyCloudDetailBatchingAndURLCache()
    }

    @Test("Cloud lyrics and sources use only the local credential fence")
    func localCredentialFence() async throws {
        try await verifyCloudLocalCredentialFence()
    }

    @Test("Empty lyrics still commit audio and cancellation removes part files")
    func downloadWithoutLyricsAndCancellation() async throws {
        try await verifyCloudDownloadWithoutLyricsAndCancellation()
    }

    @Test("Concurrent downloads obey the live 1-5 scheduler limit")
    func concurrencyLimit() async throws {
        try await verifyDownloadConcurrencyLimit()
    }

    @Test("Account setup keeps matching recovered cloud downloads")
    func cloudRecoveryAccountFilter() throws {
        try verifyCloudRecoveryAccountFilter()
    }

    @Test("Queued cloud downloads keep the credential revision captured at enqueue")
    func queuedCloudIntentRevision() async throws {
        try await verifyQueuedCloudDownloadKeepsIntentRevision()
    }
}
#endif
