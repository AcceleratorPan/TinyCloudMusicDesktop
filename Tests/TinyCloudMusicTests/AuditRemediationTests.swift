import Foundation
import Observation
import Testing
@testable import TinyCloudMusic

@Suite("iOS audit remediation", .serialized)
struct AuditRemediationTests {
    @Test("Malformed lyric timestamps cannot overflow and valid boundary values remain intact")
    func lyricTimestampBounds() {
        let invalid = [
            "[9223372036854775807:00]overflow", "[153722867280912:56]overflow",
            "[999999999999999999999999:00]overflow", "[00:60]invalid seconds"
        ]
        for input in invalid { #expect(LRCParser.parse(primary: input).isEmpty) }
        #expect(LRCParser.parse(primary: "[00:03.100]normal").map(\.timestampMilliseconds) == [3_100])
        #expect(LRCParser.parse(primary: "[153722867280912:55.807]last").map(\.timestampMilliseconds) == [Int64.max])
        #expect(LRCParser.parse(primary: "[153722867280912:55.808]overflow").isEmpty)
    }

    @Test("Off-main lyrics retain results, bound oversized inputs and propagate cancellation")
    func backgroundLyrics() async throws {
        let source = SongLyrics(lineLyrics: "[00:01]first\n[00:02]second", translatedLyrics: "[00:01]一")
        #expect(try await LRCParser.parseOffMain(source) == LRCParser.parse(source))
        #expect(LRCParser.parse(primary: "[00:01]" + String(repeating: "a", count: 2_097_152)).isEmpty)
        let task = Task { try await LRCParser.parseOffMain(source) }
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("Cancelled parsing unexpectedly committed a result")
        } catch is CancellationError {
        } catch { Issue.record("Unexpected cancellation error") }
    }

    @Test("Unique artwork saves preserve existing files, including concurrent saves")
    func artworkDoesNotOverwrite() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appending(path: "封面.jpg")
        let sentinel = Data("existing user file".utf8)
        try sentinel.write(to: destination)
        let first = Task.detached { try MusicDownloadFiles.writeUnique(Data([1, 2]), to: destination) }
        let second = Task.detached { try MusicDownloadFiles.writeUnique(Data([3, 4]), to: destination) }
        let firstURL = try await first.value
        let secondURL = try await second.value
        #expect(firstURL != secondURL && firstURL != destination && secondURL != destination)
        #expect(try Data(contentsOf: destination) == sentinel)
        #expect(try Data(contentsOf: firstURL) == Data([1, 2]))
        #expect(try Data(contentsOf: secondURL) == Data([3, 4]))
    }

    @Test("Paused and completed audio/video records survive restart without transfer")
    @MainActor
    func downloadHistoryAndPauseSurviveRestart() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appending(path: "records")
        let store = MusicDownloadResumeStore(directory: directory, maximumAge: 1)
        let paused = request(id: 1, destination: root)
        let completed = request(id: 2, destination: root)
        let audioURL = root.appending(path: "saved.mp3")
        let lyricURL = root.appending(path: "saved.lrc")
        try Data("ID3 audio".utf8).write(to: audioURL)
        try Data("[00:01]lyrics".utf8).write(to: lyricURL)
        store.save(paused, resumeData: Data([7]), isPaused: true)
        store.save(completed, completion: MusicDownloadResult(audioURL: audioURL, lyricURL: lyricURL))
        let pausedVideo = VideoDownloadRequest(
            resource: .mv(3), title: "paused", creator: "audit", destination: root,
            quality: .standard, availableResolutions: [480]
        )
        let completedVideo = VideoDownloadRequest(
            resource: .mv(4), title: "saved", creator: "audit", destination: root,
            quality: .standard, availableResolutions: [480]
        )
        let videoURL = root.appending(path: "saved.mp4")
        try Data([0, 1, 2, 3]).write(to: videoURL)
        store.save(MusicDownloadVideoResumeEntry(
            request: pausedVideo, resumeData: nil, resolution: nil, sourceURL: nil, sourceExpiresAt: nil, isPaused: true
        ))
        store.save(MusicDownloadVideoResumeEntry(
            request: completedVideo, resumeData: nil, resolution: nil, sourceURL: nil, sourceExpiresAt: nil,
            completion: MusicDownloadResult(audioURL: videoURL, lyricURL: nil)
        ))
        try await store.flush()

        let restartedStore = MusicDownloadResumeStore(directory: directory, maximumAge: 1)
        let recovery = await restartedStore.recoverableDownloadsAsync(now: Date().addingTimeInterval(30 * 86_400))
        #expect(recovery.downloads.count == 2 && recovery.videos.count == 2)
        AuditFixtureProtocol.reset()
        let session = fixtureSession()
        defer { session.invalidateAndCancel() }
        let manager = MusicDownloadManager(
            transport: EAPITransport(session: session), session: session, resumeStore: restartedStore
        )
        for _ in 0..<200 where manager.items.count != 2 || manager.videoItems.count != 2 {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(manager.states[1] == .paused(progress: nil))
        #expect(manager.videoStates[pausedVideo.resource.identity] == .paused(progress: nil))
        guard case let .completed(restoredAudio, restoredLyrics)? = manager.states[2] else {
            Issue.record("Completed audio was not restored")
            return
        }
        #expect(try Data(contentsOf: restoredAudio) == Data("ID3 audio".utf8))
        #expect(restoredLyrics != nil)
        guard case .completed? = manager.videoStates[completedVideo.resource.identity] else {
            Issue.record("Completed video was not restored")
            return
        }
        #expect(AuditFixtureProtocol.requestCount == 0)

        try FileManager.default.removeItem(at: audioURL)
        let missing = await restartedStore.recoverableDownloadsAsync()
        guard case .failed? = missing.downloads.first(where: { $0.request.songID == 2 })?.restoredState else {
            Issue.record("Missing completed file must be reported without automatic redownload")
            return
        }
        restartedStore.save(paused, resumeData: Data([7]))
        try await restartedStore.flush()
        let resumed = await restartedStore.recoverableDownloadsAsync()
        #expect(resumed.downloads.first(where: { $0.request.songID == 1 })?.restoredState == nil)
    }

    @Test("Legacy records with unknown pause intent require explicit resume")
    func legacyPauseMigration() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appending(path: "records")
        let store = MusicDownloadResumeStore(directory: directory, maximumAge: 1)
        store.save(request(id: 1, destination: root))
        store.save(MusicDownloadVideoResumeEntry(
            request: VideoDownloadRequest(
                resource: .mv(2), title: "legacy", creator: "audit", destination: root,
                quality: .standard, availableResolutions: [480]
            ), resumeData: nil, resolution: nil, sourceURL: nil, sourceExpiresAt: nil
        ))
        try await store.flush()
        for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            var record = try #require(PropertyListSerialization.propertyList(
                from: Data(contentsOf: file), format: nil
            ) as? [String: Any])
            record.removeValue(forKey: "isPaused")
            try PropertyListSerialization.data(fromPropertyList: record, format: .binary, options: 0).write(to: file)
        }
        let recovered = await store.recoverableDownloadsAsync(now: Date().addingTimeInterval(30 * 86_400))
        #expect(recovered.downloads.count == 1 && recovered.videos.count == 1)
        #expect(recovered.downloads.first?.restoredState == .paused(progress: nil))
        #expect(recovered.videos.first?.restoredState == .paused(progress: nil))
        store.save(request(id: 1, destination: root))
        try await store.flush()
        let resumed = await store.recoverableDownloadsAsync()
        #expect(resumed.downloads.first?.restoredState == nil)
    }

    @Test("Completed cloud downloads wait for their owner and survive logout")
    @MainActor
    func cloudHistoryWaitsForAccount() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MusicDownloadResumeStore(directory: root.appending(path: "records"))
        let file = root.appending(path: "cloud.mp3")
        try Data("ID3 cloud".utf8).write(to: file)
        let request = MusicDownloadRequest(
            songID: 42, songName: "cloud", artists: "audit", destination: root,
            quality: .standard, includeLyrics: false, source: .cloud(userID: 7, fileName: "cloud.mp3"),
            expectedBytes: nil
        )
        store.save(request, completion: MusicDownloadResult(audioURL: file, lyricURL: nil))
        try await store.flush()
        let session = fixtureSession()
        defer { session.invalidateAndCancel() }
        let manager = MusicDownloadManager(transport: EAPITransport(session: session), session: session, resumeStore: store)
        manager.setCloudDownloadAccount(userID: nil, credentialRevision: nil)
        await manager.pauseAll() // Also waits for the initial recovery task; this fixture has no transfers.
        #expect(manager.items.isEmpty)
        manager.setCloudDownloadAccount(userID: 8, credentialRevision: 0)
        #expect(manager.items.isEmpty)
        manager.setCloudDownloadAccount(userID: 7, credentialRevision: 0)
        guard case .completed? = manager.states[42] else {
            Issue.record("The owner's completed cloud file was not restored")
            return
        }
        manager.setCloudDownloadAccount(userID: nil, credentialRevision: nil)
        #expect(manager.items.isEmpty)
        #expect((await store.recoverableDownloadsAsync()).downloads.count == 1)
        manager.setCloudDownloadAccount(userID: 7, credentialRevision: 1)
        guard case .completed? = manager.states[42] else {
            Issue.record("Logout removed completed cloud history")
            return
        }
    }

    @Test("Same-account credential replacement notifies observers without a state change")
    @MainActor
    func credentialRevisionIsObservable() async {
        let snapshot = CredentialSnapshot(.guest)
        let transport = EAPITransport(credentialSnapshot: snapshot)
        let controller = SessionController(
            store: CredentialStore(service: "TinyCloudMusicTests.\(UUID().uuidString)"),
            credentialSnapshot: snapshot, transport: transport,
            validator: { _ in true }, vipValidator: { _ in false }, persistCredentials: { _ in }
        )
        #expect(await controller.save(cookie: "MUSIC_U=audit-account-one"))
        let initial = controller.credentialRevision
        let changed = AuditChangeCounter()
        withObservationTracking {
            _ = controller.credentialRevision
        } onChange: {
            changed.increment()
        }
        #expect(await controller.save(cookie: "MUSIC_U=audit-account-two"))
        #expect(controller.state == .authenticated)
        #expect(controller.credentialRevision > initial)
        #expect(changed.value == 1)
        let external = snapshot.store(.guest)
        #expect(controller.credentialRevision == external.revision)
    }

    @Test("Video subscription writes invalidate cached subscription lists")
    func videoSubscriptionCacheInvalidation() async throws {
        AuditFixtureProtocol.reset()
        let session = fixtureSession()
        defer { session.invalidateAndCancel() }
        let transport = EAPITransport(session: session)
        let library = LiveVideoLibrary(transport: transport)
        let revision = transport.credentialSnapshotValue().revision
        _ = try await library.subscriptions(expectedCredentialRevision: revision)
        _ = try await library.subscriptions(expectedCredentialRevision: revision)
        #expect(AuditFixtureProtocol.count(path: "/weapi/cloudvideo/allvideo/sublist") == 1)
        try await library.setMVSubscribed(1, subscribed: true, expectedCredentialRevision: revision)
        _ = try await library.subscriptions(expectedCredentialRevision: revision)
        #expect(AuditFixtureProtocol.count(path: "/weapi/cloudvideo/allvideo/sublist") == 2)
        try await library.setVideoSubscribed(
            "0123456789ABCDEF0123456789ABCDEF", subscribed: false, expectedCredentialRevision: revision
        )
        _ = try await library.subscriptions(expectedCredentialRevision: revision)
        #expect(AuditFixtureProtocol.count(path: "/weapi/cloudvideo/allvideo/sublist") == 3)
    }

    private func request(id: Int64, destination: URL) -> MusicDownloadRequest {
        MusicDownloadRequest(
            songID: id, songName: "audit \(id)", artists: "audit", destination: destination,
            quality: .standard, includeLyrics: true, source: .catalog, expectedBytes: nil
        )
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: "TCMAudit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func fixtureSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AuditFixtureProtocol.self]
        return URLSession(configuration: configuration)
    }
}

private final class AuditChangeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}

private final class AuditFixtureProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var paths: [String] = []
    static var requestCount: Int { lock.withLock { paths.count } }
    static func count(path: String) -> Int { lock.withLock { paths.filter { $0 == path }.count } }
    static func reset() { lock.withLock { paths.removeAll() } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.withLock { Self.paths.append(request.url?.path ?? "") }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: [:])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"code":200,"data":[],"hasMore":false,"count":0}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
