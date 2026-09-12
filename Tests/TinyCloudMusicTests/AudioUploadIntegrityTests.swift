import Foundation
import OSLog
import Testing
@testable import TinyCloudMusic

private final class IntegrityCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var progress: [(Int64, Int64)] = []
    private var ranOnMainThread = false

    func increment() { lock.withLock { count += 1 } }
    func append(_ completed: Int64, _ total: Int64) {
        lock.withLock { progress.append((completed, total)) }
    }
    func recordThread() { lock.withLock { ranOnMainThread = ranOnMainThread || Thread.isMainThread } }
    func snapshot() -> (count: Int, progress: [(Int64, Int64)], ranOnMainThread: Bool) {
        lock.withLock { (count, progress, ranOnMainThread) }
    }
}

private actor UploadGate {
    private var entered = false
    private var entryCount = 0
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]

    func wait() async {
        entered = true
        entryCount += 1
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume()
                } else {
                    waiters[id] = continuation
                }
            }
        } onCancel: {
            Task { await self.release(id) }
        }
    }

    func hasEntered(_ count: Int = 1) -> Bool { entered && entryCount >= count }

    func releaseAll() {
        let continuations = Array(waiters.values)
        waiters.removeAll()
        continuations.forEach { $0.resume() }
    }

    private func release(_ id: UUID) {
        waiters.removeValue(forKey: id)?.resume()
    }
}

private actor UncooperativeUploadGate {
    private var entered = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        entered = true
        await withCheckedContinuation { waiters.append($0) }
    }

    func hasEntered() -> Bool { entered }

    func releaseAll() {
        let continuations = waiters
        waiters.removeAll()
        continuations.forEach { $0.resume() }
    }
}

private actor UploadStoreGate {
    enum SaveTarget: Sendable {
        case allocating
        case paused
        case completed
        case cleanupPending

        func matches(_ phase: AudioUploadPhase) -> Bool {
            switch (self, phase) {
            case (.allocating, .allocating),
                 (.paused, .paused),
                 (.completed, .completed),
                 (.cleanupPending, .cleanupPending):
                true
            default:
                false
            }
        }
    }

    private let saveTarget: SaveTarget?
    private let failBlockedSaves: Bool
    private var remainingSaveBlocks: Int
    private var remainingRemoveBlocks: Int
    private var saveEntries = 0
    private var removeEntries = 0
    private var blockedSaves: [CheckedContinuation<Void, Never>] = []
    private var blockedRemoves: [CheckedContinuation<Void, Never>] = []
    private var saveEntryWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var removeEntryWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    init(
        saveTarget: SaveTarget? = nil,
        saveBlocks: Int = 0,
        removeBlocks: Int = 0,
        failBlockedSaves: Bool = false
    ) {
        self.saveTarget = saveTarget
        self.failBlockedSaves = failBlockedSaves
        self.remainingSaveBlocks = saveBlocks
        self.remainingRemoveBlocks = removeBlocks
    }

    func beforeSave(_ manifest: AudioUploadManifest) async throws {
        guard remainingSaveBlocks > 0, saveTarget?.matches(manifest.phase) == true else { return }
        remainingSaveBlocks -= 1
        saveEntries += 1
        let ready = saveEntryWaiters.filter { $0.0 <= saveEntries }
        saveEntryWaiters.removeAll { $0.0 <= saveEntries }
        ready.forEach { $0.1.resume() }
        await withCheckedContinuation { blockedSaves.append($0) }
        if failBlockedSaves { throw UploadIntegrityError.injectedSaveFailure }
    }

    func beforeRemove(_: UUID) async {
        guard remainingRemoveBlocks > 0 else { return }
        remainingRemoveBlocks -= 1
        removeEntries += 1
        let ready = removeEntryWaiters.filter { $0.0 <= removeEntries }
        removeEntryWaiters.removeAll { $0.0 <= removeEntries }
        ready.forEach { $0.1.resume() }
        await withCheckedContinuation { blockedRemoves.append($0) }
    }

    func waitForSaveEntry(_ count: Int = 1) async {
        guard saveEntries < count else { return }
        await withCheckedContinuation { saveEntryWaiters.append((count, $0)) }
    }

    func waitForRemoveEntry(_ count: Int = 1) async {
        guard removeEntries < count else { return }
        await withCheckedContinuation { removeEntryWaiters.append((count, $0)) }
    }

    func releaseNextSave() {
        guard !blockedSaves.isEmpty else { return }
        blockedSaves.removeFirst().resume()
    }

    func releaseNextRemove() {
        guard !blockedRemoves.isEmpty else { return }
        blockedRemoves.removeFirst().resume()
    }

}

private final class UploadIntegrityProtocol: URLProtocol, @unchecked Sendable {
    enum Mode: Sendable {
        case countOnly
        case cloudSecondPage
        case cloudRepeatedPage
        case cloudEmptyPage
        case podcastFound
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var mode: Mode = .countOnly
    nonisolated(unsafe) private static var requestCount = 0

    static func reset(_ mode: Mode) {
        lock.withLock {
            self.mode = mode
            requestCount = 0
        }
    }

    static func count() -> Int { lock.withLock { requestCount } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let (mode, index) = Self.lock.withLock {
            Self.requestCount += 1
            return (Self.mode, Self.requestCount)
        }
        let body: String = switch mode {
        case .countOnly:
            #"{"code":200}"#
        case .cloudSecondPage:
            index == 1
                ? #"{"code":200,"hasMore":true,"data":[{"songId":1,"md5":"first"}]}"#
                : #"{"code":200,"hasMore":false,"data":[{"songId":2,"md5":"target"}]}"#
        case .cloudRepeatedPage:
            #"{"code":200,"hasMore":true,"data":[{"songId":1,"md5":"same"}]}"#
        case .cloudEmptyPage:
            #"{"code":200,"hasMore":true,"data":[]}"#
        case .podcastFound:
            #"{"code":200,"data":{"list":[{"id":1,"dfsId":75}],"hasMore":false}}"#
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
}

private enum UploadIntegrityError: Error {
    case injectedSaveFailure
    case injectedRemoveFailure
}

private enum UploadMeasurementSignposts {
    private static let signposter = OSSignposter(
        subsystem: "com.tinycloudmusic.app.tests",
        category: "W5-FX2A"
    )

    static func markTerminalScale(_ itemCount: Int) {
        switch itemCount {
        case 100: signposter.emitEvent("PERF-B13.Scale.100")
        case 500: signposter.emitEvent("PERF-B13.Scale.500")
        case 1_000: signposter.emitEvent("PERF-B13.Scale.1000")
        default: preconditionFailure("Unsupported upload fixture scale")
        }
    }
}

@Suite("Audio upload integrity", .serialized)
struct AudioUploadIntegrityTests {
    @Test("A failed durable start performs no network operation")
    func durableFailureStopsNetwork() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "source.mp3")
        try Data("abc".utf8).write(to: file)
        let manifest = try makeManifest(file: file)
        let storeDirectory = root.appending(path: "store")
        let store = AudioUploadStore(directory: storeDirectory)
        try await store.save(manifest)
        let manager = await makeManager(store: store)
        await manager.waitUntilLoaded()
        await manager.setAccount(manifest.accountID)

        try FileManager.default.removeItem(at: storeDirectory)
        try Data("not-a-directory".utf8).write(to: storeDirectory)
        UploadIntegrityProtocol.reset(.countOnly)
        await manager.start(manifest.id)

        #expect(UploadIntegrityProtocol.count() == 0)
        guard case .failed? = await manager.items[manifest.id]?.phase else {
            Issue.record("A failed manifest write did not stop start")
            return
        }
    }

    @Test("Corrupt and terminal manifests are isolated from remote retry")
    func loadAndCleanupIntegrity() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "source.mp3")
        try Data("abc".utf8).write(to: file)
        var terminal = try makeManifest(file: file)
        terminal.phase = .completed
        let storeDirectory = root.appending(path: "store")
        let writer = AudioUploadStore(directory: storeDirectory)
        try await writer.save(terminal)
        try Data("{".utf8).write(to: storeDirectory.appending(path: "broken.json"))

        let loaded = try await writer.load()
        #expect(loaded.manifests == [terminal])
        #expect(loaded.diagnostics.count == 1)

        let failingStore = AudioUploadStore(
            directory: storeDirectory,
            removeItem: { _ in throw UploadIntegrityError.injectedRemoveFailure }
        )
        let manager = await makeManager(store: failingStore)
        UploadIntegrityProtocol.reset(.countOnly)
        await manager.waitUntilLoaded()
        await manager.setAccount(terminal.accountID)
        #expect(await eventually {
            guard case .cleanupPending? = await manager.items[terminal.id]?.phase else { return false }
            return true
        })
        #expect(UploadIntegrityProtocol.count() == 0)
        #expect(try await writer.load().manifests.first?.phase == .completed)
    }

    @Test("Retrying a cleanup tombstone never restarts upload")
    func cleanupRetryNeverReuploads() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "source.mp3")
        try Data("abc".utf8).write(to: file)
        let manifest = try makeManifest(file: file)
        let directory = root.appending(path: "store")
        let writer = AudioUploadStore(directory: directory)
        try await writer.save(manifest)
        let removeAttempts = IntegrityCounter()
        let store = AudioUploadStore(directory: directory, removeItem: { url in
            removeAttempts.increment()
            if removeAttempts.snapshot().count == 1 {
                throw UploadIntegrityError.injectedRemoveFailure
            }
            try FileManager.default.removeItem(at: url)
        })
        let manager = await makeManager(store: store)
        await manager.waitUntilLoaded()
        await manager.setAccount(manifest.accountID)
        UploadIntegrityProtocol.reset(.countOnly)

        await manager.cancel(manifest.id)
        guard case .failed? = await manager.items[manifest.id]?.phase else {
            Issue.record("Failed cleanup did not remain retryable")
            return
        }
        await manager.retry(manifest.id)

        #expect(await eventually { removeAttempts.snapshot().count == 2 })
        #expect(await eventually { await manager.items[manifest.id] == nil })
        #expect(UploadIntegrityProtocol.count() == 0)
        #expect(try await writer.load().manifests.isEmpty)
    }

    @Test("Same-user credential revision migrates and pauses a blocked upload")
    func accountAndCredentialFence() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "source.mp3")
        try Data("abc".utf8).write(to: file)
        let manifest = try makeManifest(file: file)
        let store = AudioUploadStore(directory: root.appending(path: "store"))
        try await store.save(manifest)
        let snapshot = CredentialSnapshot(.authenticated(try credentials("account-a")))
        let gate = UploadGate()
        let transport = transport(snapshot: snapshot, gate: gate)
        let manager = await makeManager(store: store, transport: transport)
        await manager.waitUntilLoaded()
        await manager.setAccount(
            manifest.accountID,
            credentialRevision: snapshot.load().revision
        )
        UploadIntegrityProtocol.reset(.countOnly)
        await manager.start(manifest.id)
        #expect(await eventually { await gate.hasEntered() })

        _ = snapshot.store(.authenticated(try credentials("account-b")))
        await manager.setAccount(
            manifest.accountID,
            credentialRevision: snapshot.load().revision
        )
        await gate.releaseAll()
        #expect(await eventually { await manager.isActive == false })
        await manager.pauseAll()

        #expect(UploadIntegrityProtocol.count() == 0)
        #expect(await manager.items[manifest.id]?.phase == .paused)
        #expect(try await store.load().manifests.first { $0.id == manifest.id }?.phase == .paused)
        #expect(await manager.completionRevision == 0)

        await manager.start(manifest.id)
        #expect(await eventually { await gate.hasEntered(2) })
        await gate.releaseAll()
        #expect(await eventually { UploadIntegrityProtocol.count() == 1 })
        #expect(await manager.completionRevision == 0)
    }

    @Test("AppModel revision invalidation durably pauses an active upload")
    func appModelRevisionInvalidationPausesUpload() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "source.mp3")
        try Data("abc".utf8).write(to: file)
        let manifest = try makeManifest(file: file)
        let store = AudioUploadStore(directory: root.appending(path: "store"))
        try await store.save(manifest)
        let snapshot = CredentialSnapshot(.authenticated(try credentials("app-model-a")))
        let gate = UploadGate()
        let transport = transport(snapshot: snapshot, gate: gate)
        let manager = await makeManager(store: store, transport: transport)
        await manager.waitUntilLoaded()
        let model = await AppModel(
            repository: FixtureMusicRepository(),
            library: LiveMusicLibrary(transport: transport),
            extras: LiveMusicExtras(transport: transport),
            uploads: manager,
            defaults: UserDefaults(suiteName: UUID().uuidString)!
        )
        await model.installConfirmedAccount(
            userID: manifest.accountID,
            credentialRevision: snapshot.load().revision
        )
        UploadIntegrityProtocol.reset(.countOnly)
        await manager.start(manifest.id)
        #expect(await eventually { await gate.hasEntered() })

        let revision = snapshot.store(.authenticated(try credentials("app-model-b"))).revision
        await model.invalidateAccountDomainIfNeeded(forCredentialRevision: revision)

        #expect(await model.currentUserID == nil)
        #expect(await manager.items.isEmpty)
        await gate.releaseAll()
        #expect(await eventually { await manager.isActive == false })
        #expect(try await store.load().manifests.first { $0.id == manifest.id }?.phase == .paused)
        #expect(UploadIntegrityProtocol.count() == 0)
    }

    @Test("A slow save cannot publish after switching accounts")
    func slowSaveAccountSwitch() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "source.mp3")
        try Data("abc".utf8).write(to: file)
        let manifest = try makeManifest(file: file)
        let directory = root.appending(path: "store")
        try await AudioUploadStore(directory: directory).save(manifest)
        let gate = UploadStoreGate(saveTarget: .allocating, saveBlocks: 1)
        let store = AudioUploadStore(
            directory: directory,
            beforeSave: { try await gate.beforeSave($0) }
        )
        let manager = await makeManager(store: store)
        await manager.waitUntilLoaded()
        await manager.setAccount(manifest.accountID)
        UploadIntegrityProtocol.reset(.countOnly)

        let start = Task { await manager.start(manifest.id) }
        await gate.waitForSaveEntry()
        await manager.setAccount(manifest.accountID + 1)
        await gate.releaseNextSave()
        await start.value

        #expect(await eventually { await manager.isActive == false })
        #expect(await manager.items[manifest.id] == nil)
        #expect(await manager.itemOrder.isEmpty)
        #expect(await manager.completionRevision == 0)
        #expect(UploadIntegrityProtocol.count() == 0)
    }

    @Test("A slow A1 save cannot reinsert state into A2")
    func slowSaveSameAccountGenerationSwitch() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "source.mp3")
        try Data("abc".utf8).write(to: file)
        let manifest = try makeManifest(file: file)
        let directory = root.appending(path: "store")
        try await AudioUploadStore(directory: directory).save(manifest)
        let gate = UploadStoreGate(saveTarget: .allocating, saveBlocks: 1)
        let store = AudioUploadStore(
            directory: directory,
            beforeSave: { try await gate.beforeSave($0) }
        )
        let manager = await makeManager(store: store)
        await manager.waitUntilLoaded()
        await manager.setAccount(manifest.accountID)
        UploadIntegrityProtocol.reset(.countOnly)

        let start = Task { await manager.start(manifest.id) }
        await gate.waitForSaveEntry()
        await manager.setAccount(manifest.accountID + 1)
        await manager.setAccount(manifest.accountID)
        #expect(await manager.items[manifest.id]?.phase == .paused)
        await gate.releaseNextSave()
        await start.value

        #expect(await eventually { await manager.isActive == false })
        #expect(await manager.items[manifest.id]?.phase == .paused)
        #expect(await manager.itemOrder == [manifest.id])
        #expect(await manager.completionRevision == 0)
        #expect(UploadIntegrityProtocol.count() == 0)
    }

    @Test("A slow draft completion cannot overwrite a newer generation")
    func slowDraftGenerationSwitch() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "source.mp3")
        try Data("abc".utf8).write(to: file)
        let manifest = try makeManifest(file: file)
        let directory = root.appending(path: "store")
        try await AudioUploadStore(directory: directory).save(manifest)
        let gate = UploadStoreGate(saveTarget: .paused, saveBlocks: 1)
        let store = AudioUploadStore(
            directory: directory,
            beforeSave: { try await gate.beforeSave($0) }
        )
        let manager = await makeManager(store: store)
        await manager.waitUntilLoaded()
        await manager.setAccount(manifest.accountID)
        UploadIntegrityProtocol.reset(.countOnly)
        await manager.updateMetadata(id: manifest.id, title: "A1 draft")

        let flush = Task { await manager.flushEdits() }
        await gate.waitForSaveEntry()
        await manager.setAccount(manifest.accountID + 1)
        await manager.setAccount(manifest.accountID)
        await manager.updateMetadata(id: manifest.id, title: "A2 draft")
        await gate.releaseNextSave()
        await flush.value
        await manager.flushEdits()

        #expect(await manager.items[manifest.id]?.metadata?.title == "A2 draft")
        #expect(await manager.itemOrder == [manifest.id])
        #expect(await manager.completionRevision == 0)
        #expect(try await store.load().manifests.first { $0.id == manifest.id }?.metadata.title == "A2 draft")
        #expect(UploadIntegrityProtocol.count() == 0)
    }

    @Test("A stale pause save is durable-only")
    func stalePauseIsDurableOnly() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "source.mp3")
        try Data("abc".utf8).write(to: file)
        var manifest = try makeManifest(file: file)
        manifest.phase = .failed("A1 state")
        let directory = root.appending(path: "store")
        try await AudioUploadStore(directory: directory).save(manifest)
        let gate = UploadStoreGate(saveTarget: .paused, saveBlocks: 1)
        let store = AudioUploadStore(
            directory: directory,
            beforeSave: { try await gate.beforeSave($0) }
        )
        let manager = await makeManager(store: store)
        await manager.waitUntilLoaded()
        await manager.setAccount(manifest.accountID)
        UploadIntegrityProtocol.reset(.countOnly)

        let id = manifest.id
        let pause = Task { await manager.pause(id) }
        await gate.waitForSaveEntry()
        await manager.setAccount(manifest.accountID + 1)
        await manager.setAccount(manifest.accountID)
        await gate.releaseNextSave()
        await pause.value

        #expect(await eventually { await manager.isActive == false })
        #expect(await manager.items[id]?.phase == .failed("A1 state"))
        #expect(await manager.itemOrder == [id])
        #expect(await manager.completionRevision == 0)
        #expect(try await store.load().manifests.first { $0.id == id }?.phase == .paused)
        #expect(UploadIntegrityProtocol.count() == 0)
    }

    @Test("An old-account checkpoint failure is surfaced and blocks new scheduling")
    func accountCheckpointFailureIsSurfaced() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "source.mp3")
        try Data("abc".utf8).write(to: file)
        let manifest = try makeManifest(file: file)
        let directory = root.appending(path: "store")
        try await AudioUploadStore(directory: directory).save(manifest)
        let gate = UploadStoreGate(
            saveTarget: .paused,
            saveBlocks: 1,
            failBlockedSaves: true
        )
        let store = AudioUploadStore(
            directory: directory,
            beforeSave: { try await gate.beforeSave($0) }
        )
        let manager = await makeManager(store: store)
        await manager.waitUntilLoaded()
        await manager.setAccount(manifest.accountID)
        await manager.updateMetadata(id: manifest.id, title: "A dirty draft")
        UploadIntegrityProtocol.reset(.countOnly)

        await manager.setAccount(manifest.accountID + 1)
        await gate.waitForSaveEntry()
        await gate.releaseNextSave()

        #expect(await eventually { await manager.isActive == false })
        #expect(await manager.items.isEmpty)
        #expect(await manager.itemOrder.isEmpty)
        #expect(await manager.completionRevision == 0)
        #expect(await manager.persistenceError != nil)
        #expect(UploadIntegrityProtocol.count() == 0)
    }

    @Test("Stale cancel, completion, tombstone, and retry cleanup cannot commit")
    func staleCleanupCompletions() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        do {
            let file = root.appending(path: "cancel.mp3")
            try Data("abc".utf8).write(to: file)
            let manifest = try makeManifest(file: file)
            let directory = root.appending(path: "cancel-store")
            try await AudioUploadStore(directory: directory).save(manifest)
            let gate = UploadStoreGate(removeBlocks: 1)
            let store = AudioUploadStore(
                directory: directory,
                beforeRemove: { await gate.beforeRemove($0) }
            )
            let manager = await makeManager(store: store)
            await manager.waitUntilLoaded()
            await manager.setAccount(manifest.accountID)
            UploadIntegrityProtocol.reset(.countOnly)

            let cancel = Task { await manager.cancel(manifest.id) }
            await gate.waitForRemoveEntry()
            await manager.setAccount(manifest.accountID + 1)
            await gate.releaseNextRemove()
            await cancel.value

            #expect(await eventually { await manager.isActive == false })
            #expect(await manager.items.isEmpty)
            #expect(await manager.itemOrder.isEmpty)
            #expect(await manager.completionRevision == 0)
            #expect(UploadIntegrityProtocol.count() == 0)
        }

        do {
            let file = root.appending(path: "complete.mp3")
            try Data("abc".utf8).write(to: file)
            var manifest = try makeManifest(file: file)
            manifest.phase = .reconciling
            manifest.cloud.registeredSongID = 2
            let directory = root.appending(path: "complete-store")
            try await AudioUploadStore(directory: directory).save(manifest)
            let gate = UploadStoreGate(saveTarget: .completed, saveBlocks: 1)
            let store = AudioUploadStore(
                directory: directory,
                beforeSave: { try await gate.beforeSave($0) }
            )
            let snapshot = CredentialSnapshot(.authenticated(try credentials("slow-complete")))
            let manager = await makeManager(store: store, transport: transport(snapshot: snapshot))
            await manager.waitUntilLoaded()
            await manager.setAccount(manifest.accountID)
            UploadIntegrityProtocol.reset(.cloudSecondPage)

            await manager.reconcile(manifest.id)
            await gate.waitForSaveEntry()
            await manager.setAccount(manifest.accountID + 1)
            await gate.releaseNextSave()

            #expect(await eventually { await manager.isActive == false })
            #expect(await manager.items.isEmpty)
            #expect(await manager.itemOrder.isEmpty)
            #expect(await manager.completionRevision == 0)
            #expect(UploadIntegrityProtocol.count() == 2)
        }

        do {
            let file = root.appending(path: "tombstone.mp3")
            try Data("abc".utf8).write(to: file)
            var manifest = try makeManifest(file: file)
            manifest.phase = .reconciling
            manifest.cloud.registeredSongID = 2
            let directory = root.appending(path: "tombstone-store")
            try await AudioUploadStore(directory: directory).save(manifest)
            let gate = UploadStoreGate(saveTarget: .cleanupPending, saveBlocks: 1)
            let store = AudioUploadStore(
                directory: directory,
                removeItem: { _ in throw UploadIntegrityError.injectedRemoveFailure },
                beforeSave: { try await gate.beforeSave($0) }
            )
            let snapshot = CredentialSnapshot(.authenticated(try credentials("slow-tombstone")))
            let manager = await makeManager(store: store, transport: transport(snapshot: snapshot))
            await manager.waitUntilLoaded()
            await manager.setAccount(manifest.accountID)
            UploadIntegrityProtocol.reset(.cloudSecondPage)

            await manager.reconcile(manifest.id)
            await gate.waitForSaveEntry()
            await manager.setAccount(manifest.accountID + 1)
            await gate.releaseNextSave()

            #expect(await eventually { await manager.isActive == false })
            #expect(await manager.items.isEmpty)
            #expect(await manager.itemOrder.isEmpty)
            #expect(await manager.completionRevision == 1)
            #expect(await manager.persistenceError == nil)
            #expect(UploadIntegrityProtocol.count() == 2)
        }

        do {
            let file = root.appending(path: "retry.mp3")
            try Data("abc".utf8).write(to: file)
            var manifest = try makeManifest(file: file)
            manifest.phase = .completed
            let directory = root.appending(path: "retry-store")
            try await AudioUploadStore(directory: directory).save(manifest)
            let gate = UploadStoreGate(removeBlocks: 2)
            let store = AudioUploadStore(
                directory: directory,
                beforeRemove: { await gate.beforeRemove($0) }
            )
            let manager = await makeManager(store: store)
            UploadIntegrityProtocol.reset(.countOnly)
            await manager.waitUntilLoaded()
            await manager.setAccount(manifest.accountID)
            await gate.waitForRemoveEntry()
            await manager.setAccount(manifest.accountID + 1)
            await manager.setAccount(manifest.accountID)
            await gate.releaseNextRemove()
            await gate.waitForRemoveEntry(2)

            #expect(await manager.items[manifest.id]?.phase == .completed)
            #expect(await manager.itemOrder == [manifest.id])
            #expect(await manager.completionRevision == 0)
            await gate.releaseNextRemove()
            #expect(await eventually { await manager.items[manifest.id] == nil })
            #expect(UploadIntegrityProtocol.count() == 0)
        }
    }

    @Test("Inspection and first resolve hash an unchanged new source once")
    func inspectionIdentityAvoidsSecondHashOnFirstRun() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "source.wav")
        try writeWAV(to: file)
        let counter = IntegrityCounter()
        let hash: @Sendable (URL) throws -> String = {
            counter.increment()
            return try AudioUploadInspector.hashFile($0)
        }

        let inspection = try await AudioUploadInspector.inspect(
            file,
            accountID: 7,
            destination: .cloud,
            podcastForm: nil,
            hash: hash
        )
        _ = try #require(inspection.identity.fileNumber)
        #expect(inspection.manifest.byteCount == inspection.identity.byteCount)
        #expect(inspection.manifest.modificationTime == inspection.identity.modificationTime)
        #expect(inspection.manifest.md5.count == 32)

        _ = try await AudioUploadInspector.resolve(
            inspection.manifest,
            cachedIdentity: inspection.identity,
            hash: hash
        )
        #expect(counter.snapshot().count == 1)
    }

    @Test("Restored manifests rehash without persisting transient identity")
    func restoredUploadDoesNotReuseTransientIdentity() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "source.mp3")
        try Data("abc".utf8).write(to: file)
        let manifest = try makeManifest(file: file)
        let directory = root.appending(path: "store")
        let store = AudioUploadStore(directory: directory)
        try await store.save(manifest)
        let loaded = try await store.load()
        let restored = try #require(loaded.manifests.first)
        let persisted = try String(
            contentsOf: directory.appending(path: "\(manifest.id.uuidString).json"),
            encoding: .utf8
        )
        #expect(!persisted.contains("SourceIdentity"))
        #expect(!persisted.contains("fileNumber"))
        #expect(!persisted.contains("changeTimeNanoseconds"))

        let counter = IntegrityCounter()
        _ = try await AudioUploadInspector.resolve(restored, hash: {
            counter.increment()
            return try AudioUploadInspector.hashFile($0)
        })
        #expect(counter.snapshot().count == 1)
    }

    @Test("Preparation identity requires durable persistence and a current context")
    func preparationIdentityCommitBoundary() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "source.wav")
        try writeWAV(to: file)
        let gate = UploadStoreGate(
            saveTarget: .paused,
            saveBlocks: 1,
            failBlockedSaves: true
        )
        let store = AudioUploadStore(
            directory: root.appending(path: "store"),
            beforeSave: { try await gate.beforeSave($0) }
        )
        let manager = await makeManager(store: store)
        await manager.waitUntilLoaded()
        await manager.setAccount(7)
        let preparedID = await manager.prepareCloudFile(file)
        let id = try #require(preparedID)
        await gate.waitForSaveEntry()
        await gate.releaseNextSave()

        #expect(await eventually { await manager.isActive == false })
        guard case .failed? = await manager.items[id]?.phase else {
            Issue.record("A failed preparation persist published prepared state")
            return
        }
        #expect(try await store.load().manifests.isEmpty)

        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appending(path: "Sources/TinyCloudMusic/AudioUploadManager.swift"),
            encoding: .utf8
        )
        let prepareStart = try #require(source.range(of: "    private func prepare(")?.lowerBound)
        let prepareEnd = try #require(
            source.range(of: "    private func schedule()", range: prepareStart..<source.endIndex)?.lowerBound
        )
        let prepare = String(source[prepareStart..<prepareEnd])
        let persist = try #require(
            prepare.range(of: "_ = try await persist(manifest, context: context)")?.lowerBound
        )
        let identity = try #require(
            prepare.range(of: "sourceIdentities[id] = inspection.identity")?.lowerBound
        )
        let guardedCommit = String(prepare[persist..<identity])
        #expect(persist < identity)
        #expect(guardedCommit.contains("try validate(context, id: id)"))
        #expect(guardedCommit.contains("try commit(context)"))
        #expect(!prepare.contains("sourceIdentity("))
    }

    @Test("Nil file number remains a full-hash fallback")
    func nilFileNumberRequiresHashBoundary() throws {
        let identity = AudioUploadInspector.SourceIdentity(
            byteCount: 3,
            modificationTime: 1,
            fileNumber: nil,
            changeTimeNanoseconds: 2
        )
        let cached = identity
        #expect(cached == identity)
        #expect(cached != identity || identity.fileNumber == nil)

        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appending(path: "Sources/TinyCloudMusic/AudioUploadModels.swift"),
            encoding: .utf8
        )
        let resolveStart = try #require(source.range(of: "    static func resolve(")?.lowerBound)
        let resolveEnd = try #require(
            source.range(of: "    static func sourceIdentity", range: resolveStart..<source.endIndex)?.lowerBound
        )
        let resolve = String(source[resolveStart..<resolveEnd])
        #expect(resolve.contains("if cachedIdentity != identity || identity.fileNumber == nil"))
        #expect(resolve.contains("guard try hash(url).caseInsensitiveCompare(manifest.md5)"))
    }

    @Test("Resume rehashes changed content and caches only a stable file identity")
    func resumeMD5Validation() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "source.mp3")
        try Data("abc".utf8).write(to: file)
        let manifest = try makeManifest(file: file)
        let counter = IntegrityCounter()
        let hash: @Sendable (URL) throws -> String = {
            counter.increment()
            counter.recordThread()
            return try AudioUploadInspector.hashFile($0)
        }
        let first = try await Task { @MainActor in
            try await AudioUploadInspector.resolve(manifest, hash: hash)
        }.value
        _ = try await Task { @MainActor in
            try await AudioUploadInspector.resolve(
                manifest,
                cachedIdentity: first.identity,
                hash: hash
            )
        }.value
        #expect(counter.snapshot().count == 1)
        #expect(!counter.snapshot().ranOnMainThread)

        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data("xyz".utf8))
        try handle.close()
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: manifest.modificationTime)],
            ofItemAtPath: file.path
        )
        let replacementIdentity = try await AudioUploadInspector.sourceIdentity(file)
        #expect(replacementIdentity.byteCount == first.identity.byteCount)
        #expect(abs(replacementIdentity.modificationTime - first.identity.modificationTime) < 1)
        #expect(replacementIdentity != first.identity)
        do {
            _ = try await AudioUploadInspector.resolve(
                manifest,
                cachedIdentity: first.identity,
                hash: hash
            )
            Issue.record("Same-size and same-mtime replacement bypassed MD5")
        } catch let error as AudioUploadError {
            #expect(error == .fileChanged)
        }
        #expect(counter.snapshot().count == 2)

        let store = AudioUploadStore(directory: root.appending(path: "store"))
        try await store.save(manifest)
        let manager = await makeManager(store: store)
        await manager.waitUntilLoaded()
        await manager.setAccount(manifest.accountID)
        UploadIntegrityProtocol.reset(.countOnly)
        await manager.start(manifest.id)
        #expect(await eventually {
            guard case .failed? = await manager.items[manifest.id]?.phase else { return false }
            return true
        })
        #expect(UploadIntegrityProtocol.count() == 0)
    }

    @Test("Progress, drafts, and part checkpoints coalesce without losing final state")
    func coalescingAndParts() async throws {
        let progress = IntegrityCounter()
        let coalescer = UploadProgressCoalescer(minimumInterval: .seconds(60)) {
            progress.append($0, $1)
        }
        for value in 1...10_000 { coalescer.submit(Int64(value), total: 10_000) }
        coalescer.flush()
        let progressValues = progress.snapshot().progress
        #expect(progressValues.count <= 102)
        #expect(progressValues.last?.0 == 10_000)
        #expect(progressValues.last?.1 == 10_000)

        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "source.mp3")
        try Data("abc".utf8).write(to: file)
        let manifest = try makeManifest(file: file)
        let store = AudioUploadStore(directory: root.appending(path: "store"))
        try await store.save(manifest)
        let manager = await makeManager(store: store)
        await manager.waitUntilLoaded()
        await manager.setAccount(manifest.accountID)
        for value in 1...1_000 {
            await manager.updateMetadata(id: manifest.id, title: "title-\(value)")
        }
        #expect(await manager.pendingDraftSaveCount == 1)
        await manager.flushEdits()
        let saved = try await store.load().manifests.first { $0.id == manifest.id }
        #expect(saved?.metadata.title == "title-1000")
        #expect(await manager.pendingDraftSaveCount == 0)

        let checkpointWrites = IntegrityCounter()
        let checkpointStore = AudioUploadStore(
            directory: root.appending(path: "checkpoint-store"),
            beforeSave: { _ in checkpointWrites.increment() },
            checkpointDelay: .seconds(60)
        )
        var checkpoint = manifest
        for offset in 1...1_000 {
            checkpoint.cloud.confirmedOffset = Int64(offset)
            checkpoint.phase = .uploading(completed: Int64(offset), total: 1_000)
            try await checkpointStore.checkpoint(checkpoint)
        }
        try await checkpointStore.flush()
        #expect(checkpointWrites.snapshot().count == 1)
        #expect(try await checkpointStore.load().manifests.first?.cloud.confirmedOffset == 1_000)

        for partNumber in 1...1_000 {
            checkpoint.podcast.parts.append(AudioUploadPart(number: partNumber, etag: "etag-\(partNumber)"))
            try await checkpointStore.checkpoint(checkpoint)
        }
        try await checkpointStore.flush()
        let durableCheckpoint = try await checkpointStore.load().manifests.first
        #expect(checkpointWrites.snapshot().count == 2)
        #expect(durableCheckpoint?.podcast.parts.count == 1_000)
        #expect(durableCheckpoint?.podcast.parts.last?.number == 1_000)

        let blockedDirectory = root.appending(path: "blocked-checkpoint-store")
        try Data("not a directory".utf8).write(to: blockedDirectory)
        let failingCheckpointStore = AudioUploadStore(
            directory: blockedDirectory,
            checkpointDelay: .seconds(60)
        )
        try await failingCheckpointStore.checkpoint(checkpoint)
        do {
            try await failingCheckpointStore.flush()
            Issue.record("Checkpoint flush should report an undurable write")
        } catch {
            #expect(!error.localizedDescription.isEmpty)
        }
        try FileManager.default.removeItem(at: blockedDirectory)
        try await failingCheckpointStore.flush()
        #expect(try await failingCheckpointStore.load().manifests.first?.podcast.parts.count == 1_000)

        var resume = PodcastUploadResume()
        resume.parts = (1...1_000).reversed().map {
            AudioUploadPart(number: $0, etag: "etag-\($0)")
        } + [AudioUploadPart(number: 500, etag: "duplicate")]
        #expect(resume.uploadedPartNumbers.count == 1_000)
        #expect(resume.stableParts.map(\.number) == Array(1...1_000))
        #expect(resume.stableParts[499].etag == "etag-500")
    }

    @Test("A durable save waits for a superseding checkpoint")
    func durableSaveWaitsForLatestCheckpoint() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "source.mp3")
        try Data("abc".utf8).write(to: file)
        let original = try makeManifest(file: file)
        let gate = UploadStoreGate(saveTarget: .paused, saveBlocks: 1)
        let writes = IntegrityCounter()
        let store = AudioUploadStore(
            directory: root.appending(path: "store"),
            beforeSave: {
                writes.increment()
                try await gate.beforeSave($0)
            },
            checkpointDelay: .seconds(60)
        )

        let save = Task { try await store.save(original) }
        await gate.waitForSaveEntry()
        var latest = original
        latest.cloud.confirmedOffset = latest.byteCount
        latest.phase = .uploading(completed: latest.byteCount, total: latest.byteCount)
        try await store.checkpoint(latest)
        await gate.releaseNextSave()
        try await save.value

        let durable = try await store.load().manifests.first
        #expect(writes.snapshot().count == 2)
        #expect(durable?.cloud.confirmedOffset == latest.byteCount)
        #expect(durable?.phase == latest.phase)
    }

    @Test("Reconcile is single-flight, reaches page two, and bounds no-progress pages")
    func reconcilePagination() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "source.mp3")
        try Data("abc".utf8).write(to: file)
        var manifest = try makeManifest(file: file)
        manifest.phase = .reconciling
        manifest.cloud.registeredSongID = 2
        let store = AudioUploadStore(directory: root.appending(path: "store"))
        try await store.save(manifest)
        let snapshot = CredentialSnapshot(.authenticated(try credentials("reconcile")))
        let transport = transport(snapshot: snapshot)
        let manager = await makeManager(store: store, transport: transport)
        await manager.waitUntilLoaded()
        await manager.setAccount(manifest.accountID)

        UploadIntegrityProtocol.reset(.cloudSecondPage)
        await manager.reconcile(manifest.id)
        await manager.reconcile(manifest.id)
        #expect(await eventually { await manager.completionRevision == 1 })
        #expect(await manager.podcastCompletionRevision == 0)
        #expect(UploadIntegrityProtocol.count() == 2)

        UploadIntegrityProtocol.reset(.cloudRepeatedPage)
        let library = LiveMusicLibrary(transport: transport)
        let repeated = try await library.reconcileCloudUpload(
            md5: "missing",
            songID: nil,
            expectedCredentialRevision: snapshot.load().revision
        )
        #expect(!repeated)
        #expect(UploadIntegrityProtocol.count() == 2)

        UploadIntegrityProtocol.reset(.cloudEmptyPage)
        let empty = try await library.reconcileCloudUpload(
            md5: "missing",
            songID: nil,
            expectedCredentialRevision: snapshot.load().revision
        )
        #expect(!empty)
        #expect(UploadIntegrityProtocol.count() == 1)
    }

    @Test("One thousand terminal upload failures preserve durable boundary work")
    func terminalUploadHistoryWorkload() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let activeFile = root.appending(path: "active.mp3")
        let queuedFile = root.appending(path: "queued.mp3")
        let failedFile = root.appending(path: "retryable.mp3")
        try Data("active".utf8).write(to: activeFile)
        try Data("queued".utf8).write(to: queuedFile)
        try Data("failed".utf8).write(to: failedFile)
        let savedAt = Date(timeIntervalSince1970: 2_000_000_000)
        var active = try makeManifest(file: activeFile)
        var queued = try makeManifest(file: queuedFile)
        var retryable = try makeManifest(file: failedFile)
        active.savedAt = savedAt
        queued.savedAt = savedAt.addingTimeInterval(1)
        retryable.savedAt = savedAt.addingTimeInterval(2)
        retryable.phase = .failed("controlled retryable failure")
        let durable = [active, queued, retryable]
        let durableIDs = durable.map(\.id)
        let store = AudioUploadStore(directory: root.appending(path: "store"))
        for manifest in durable { try await store.save(manifest) }

        let snapshot = CredentialSnapshot(.authenticated(try credentials("terminal-history")))
        let gate = UploadGate()
        let manager = await makeManager(
            store: store,
            transport: transport(snapshot: snapshot, gate: gate)
        )
        await manager.waitUntilLoaded()
        await manager.setAccount(
            active.accountID,
            credentialRevision: snapshot.load().revision
        )
        #expect(await manager.itemOrder == durableIDs)
        UploadIntegrityProtocol.reset(.countOnly)
        await manager.start(active.id)
        #expect(await eventually { await gate.hasEntered() })
        await manager.start(queued.id)
        #expect(await gate.hasEntered())
        #expect(!(await gate.hasEntered(2)))
        #expect(UploadIntegrityProtocol.count() == 0)
        #expect(await manager.items[active.id]?.phase == .allocating)
        #expect(await manager.items[queued.id]?.phase == .allocating)
        #expect(await manager.items[retryable.id]?.phase == retryable.phase)

        var terminalIDs: [UUID] = []
        let missingRoot = root.appending(path: "missing", directoryHint: .isDirectory)
        for checkpoint in [100, 500, 1_000] {
            let additions = checkpoint - durableIDs.count - terminalIDs.count
            for _ in 0..<additions {
                let ordinal = terminalIDs.count + 1
                let id = await manager.prepareCloudFile(
                    missingRoot.appending(path: "terminal-\(ordinal).mp3")
                )
                if let id {
                    terminalIDs.append(id)
                } else {
                    Issue.record("Missing-file fixture was not accepted")
                }
            }
            #expect(await eventually {
                let items = await manager.items
                return terminalIDs.allSatisfy { id in
                    if case .failed? = items[id]?.phase { return true }
                    return false
                }
            })
            let order = await manager.itemOrder
            let items = await manager.items
            #expect(items.count == checkpoint)
            #expect(Array(order.prefix(durableIDs.count)) == durableIDs)
            #expect(Array(order.dropFirst(durableIDs.count)) == terminalIDs)
            #expect(items[active.id]?.phase == .allocating)
            #expect(items[queued.id]?.phase == .allocating)
            #expect(items[retryable.id]?.phase == retryable.phase)
            let loaded = try await store.load().manifests
            let loadedByID = Dictionary(uniqueKeysWithValues: loaded.map { ($0.id, $0) })
            #expect(loaded.count == durableIDs.count)
            #expect(Set(loadedByID.keys) == Set(durableIDs))
            #expect(loadedByID[retryable.id]?.phase == retryable.phase)
            UploadMeasurementSignposts.markTerminalScale(checkpoint)
        }

        #expect(UploadIntegrityProtocol.count() == 0)
        await manager.pauseAll()
        await gate.releaseAll()
        #expect(await eventually { await manager.isActive == false })
        for id in durableIDs { await manager.cancel(id) }
    }

    @Test("Podcast completion advances only the podcast refresh revision")
    func podcastCompletionRevisionIsTargeted() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "podcast.mp3")
        try Data("abc".utf8).write(to: file)
        var manifest = try makeManifest(
            file: file,
            destination: .podcast(voiceListID: 9)
        )
        manifest.phase = .reconciling
        manifest.podcast.documentID = 75
        let store = AudioUploadStore(directory: root.appending(path: "store"))
        try await store.save(manifest)
        let snapshot = CredentialSnapshot(.authenticated(try credentials("podcast-reconcile")))
        let manager = await makeManager(store: store, transport: transport(snapshot: snapshot))
        await manager.waitUntilLoaded()
        await manager.setAccount(manifest.accountID)

        UploadIntegrityProtocol.reset(.podcastFound)
        await manager.reconcile(manifest.id)

        #expect(await eventually { await manager.podcastCompletionRevision == 1 })
        #expect(await manager.completionRevision == 0)
        #expect(UploadIntegrityProtocol.count() == 1)
    }

    @Test("pauseAll waits for task cancellation and leaves a durable resume point")
    func pauseAllIsDurable() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "source.mp3")
        try Data("abc".utf8).write(to: file)
        let manifest = try makeManifest(file: file)
        let store = AudioUploadStore(directory: root.appending(path: "store"))
        try await store.save(manifest)
        let snapshot = CredentialSnapshot(.authenticated(try credentials("pause")))
        let gate = UploadGate()
        let manager = await makeManager(
            store: store,
            transport: transport(snapshot: snapshot, gate: gate)
        )
        await manager.waitUntilLoaded()
        await manager.setAccount(manifest.accountID)
        UploadIntegrityProtocol.reset(.countOnly)
        await manager.start(manifest.id)
        #expect(await eventually { await gate.hasEntered() })

        await manager.pauseAll()
        let saved = try await store.load().manifests.first { $0.id == manifest.id }
        #expect(saved?.phase == .paused)
        #expect(await manager.isActive == false)
    }

    @Test("pauseAll timeout preserves a manifest that a new manager can recover")
    func pauseAllTimeoutIsRecoverable() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "source.mp3")
        try Data("abc".utf8).write(to: file)
        let manifest = try makeManifest(file: file)
        let store = AudioUploadStore(directory: root.appending(path: "store"))
        try await store.save(manifest)
        let snapshot = CredentialSnapshot(.authenticated(try credentials("pause-timeout")))
        let gate = UncooperativeUploadGate()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UploadIntegrityProtocol.self]
        let transport = EAPITransport(
            session: URLSession(configuration: configuration),
            credentialSnapshot: snapshot,
            beforeSendingRequest: { await gate.wait() }
        )
        let manager = await makeManager(
            store: store,
            transport: transport,
            pauseTimeout: .milliseconds(10)
        )
        await manager.waitUntilLoaded()
        await manager.setAccount(manifest.accountID)
        UploadIntegrityProtocol.reset(.countOnly)
        await manager.start(manifest.id)
        #expect(await eventually { await gate.hasEntered() })

        await manager.pauseAll()
        #expect(await manager.persistenceError?.contains("暂停上传超时") == true)
        #expect(try await store.load().manifests.first { $0.id == manifest.id }?.phase == .paused)

        let restored = await makeManager(store: store)
        await restored.waitUntilLoaded()
        await restored.setAccount(manifest.accountID)
        #expect(await restored.items[manifest.id]?.phase == .paused)

        await gate.releaseAll()
        #expect(await eventually { await manager.isActive == false })
    }

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "TinyCloudMusicAudioIntegrity.\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func writeWAV(to url: URL) throws {
        let sampleRate: UInt32 = 8_000
        let dataSize: UInt32 = sampleRate / 10 * 2
        var data = Data("RIFF".utf8)
        appendLittleEndian(36 + dataSize, to: &data)
        data.append(Data("WAVEfmt ".utf8))
        appendLittleEndian(UInt32(16), to: &data)
        appendLittleEndian(UInt16(1), to: &data)
        appendLittleEndian(UInt16(1), to: &data)
        appendLittleEndian(sampleRate, to: &data)
        appendLittleEndian(sampleRate * 2, to: &data)
        appendLittleEndian(UInt16(2), to: &data)
        appendLittleEndian(UInt16(16), to: &data)
        data.append(Data("data".utf8))
        appendLittleEndian(dataSize, to: &data)
        data.append(Data(repeating: 0, count: Int(dataSize)))
        try data.write(to: url)
    }

    private func appendLittleEndian<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var value = value.littleEndian
        withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
    }

    private func makeManifest(
        file: URL,
        accountID: Int64 = 7,
        destination: AudioUploadDestination = .cloud
    ) throws -> AudioUploadManifest {
        let values = try file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        return AudioUploadManifest(
            id: UUID(),
            accountID: accountID,
            destination: destination,
            bookmark: try file.bookmarkData(
                options: [],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            ),
            filename: file.lastPathComponent,
            fileExtension: "mp3",
            contentType: "audio/mpeg",
            byteCount: Int64(values.fileSize ?? 0),
            modificationTime: values.contentModificationDate?.timeIntervalSince1970 ?? 0,
            md5: try AudioUploadInspector.hashFile(file),
            metadata: AudioUploadMetadata(
                title: "Title",
                artist: "Artist",
                album: "Album",
                durationMilliseconds: 1_000,
                bitrate: 320_000
            )
        )
    }

    @MainActor
    private func makeManager(
        store: AudioUploadStore,
        transport: EAPITransport? = nil,
        pauseTimeout: Duration = .seconds(5)
    ) -> AudioUploadManager {
        let transport = transport ?? self.transport(
            snapshot: CredentialSnapshot(.guest)
        )
        return AudioUploadManager(
            musicLibrary: LiveMusicLibrary(transport: transport),
            audioLibrary: LiveAudioContentLibrary(transport: transport),
            store: store,
            pauseTimeout: pauseTimeout
        )
    }

    private func transport(snapshot: CredentialSnapshot, gate: UploadGate? = nil) -> EAPITransport {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UploadIntegrityProtocol.self]
        return EAPITransport(
            session: URLSession(configuration: configuration),
            credentialSnapshot: snapshot,
            beforeSendingRequest: gate.map { gate in { @Sendable in await gate.wait() } }
        )
    }

    private func credentials(_ value: String) throws -> SessionCredentials {
        try SessionCredentials(
            cookie: "MUSIC_U=\(value); __csrf=fixture",
            musicU: "vip-\(value)",
            deviceID: "0123456789abcdef0123456789abcdef"
        )
    }

    private func eventually(_ condition: () async -> Bool) async -> Bool {
        for _ in 0..<500 {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }
}
