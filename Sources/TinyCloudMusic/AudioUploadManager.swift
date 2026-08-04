import Foundation
import Observation

@MainActor
@Observable
final class AudioUploadManager {
    private struct UploadContext: Equatable, Sendable {
        let accountID: Int64
        let generation: UInt64
        let credentialRevision: UInt64
        let id: UUID
        let identity: UUID
    }

    private struct PendingUpload: Sendable {
        let id: UUID
        let context: UploadContext
    }

    private(set) var items: [UUID: AudioUploadItem] = [:]
    private(set) var itemOrder: [UUID] = []
    private(set) var completionRevision = 0
    private(set) var podcastCompletionRevision = 0
    private(set) var persistenceError: String?

    @ObservationIgnored private let musicLibrary: LiveMusicLibrary
    @ObservationIgnored private let audioLibrary: LiveAudioContentLibrary
    @ObservationIgnored private let nos: NOSAudioUpload
    @ObservationIgnored private let store: AudioUploadStore
    @ObservationIgnored private let credentialRevision: @Sendable () -> UInt64
    @ObservationIgnored private let pauseTimeout: Duration
    @ObservationIgnored private var manifests: [UUID: AudioUploadManifest] = [:]
    @ObservationIgnored private var pending: [PendingUpload] = []
    @ObservationIgnored private var activeID: UUID?
    @ObservationIgnored private var activeTaskIdentity: UUID?
    @ObservationIgnored private var activeTask: Task<Void, Never>?
    @ObservationIgnored private var preparationTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var draftSaveTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var draftContexts: [UUID: UploadContext] = [:]
    @ObservationIgnored private var dirtyDrafts: Set<UUID> = []
    @ObservationIgnored private var draftVersions: [UUID: UInt64] = [:]
    @ObservationIgnored private var lockedDrafts: Set<UUID> = []
    @ObservationIgnored private var sourceIdentities: [UUID: AudioUploadInspector.SourceIdentity] = [:]
    @ObservationIgnored private var pauseRequested: Set<UUID> = []
    @ObservationIgnored private var accountID: Int64?
    @ObservationIgnored private var accountGeneration: UInt64 = 0
    @ObservationIgnored private var operationIdentities: [UUID: UUID] = [:]
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var accountTransitionTask: Task<Void, Never>?

    init(
        musicLibrary: LiveMusicLibrary,
        audioLibrary: LiveAudioContentLibrary,
        nos: NOSAudioUpload = NOSAudioUpload(),
        store: AudioUploadStore = .shared,
        credentialRevision: (@Sendable () -> UInt64)? = nil,
        pauseTimeout: Duration = .seconds(5)
    ) {
        self.musicLibrary = musicLibrary
        self.audioLibrary = audioLibrary
        self.nos = nos
        self.store = store
        self.credentialRevision = credentialRevision
            ?? { musicLibrary.transport.credentialSnapshotValue().revision }
        self.pauseTimeout = pauseTimeout
        loadTask = Task { [weak self, store] in
            do {
                let result = try await store.load()
                self?.install(result)
            } catch {
                self?.persistenceError = "无法读取上传记录：\(error.localizedDescription)"
            }
        }
    }

    isolated deinit {
        loadTask?.cancel()
        accountTransitionTask?.cancel()
        activeTask?.cancel()
        preparationTasks.values.forEach { $0.cancel() }
        draftSaveTasks.values.forEach { $0.cancel() }
    }

    var isActive: Bool {
        activeID != nil || !pending.isEmpty || !preparationTasks.isEmpty || accountTransitionTask != nil
    }
    var pendingDraftSaveCount: Int { draftSaveTasks.count }

    func waitUntilLoaded() async {
        await loadTask?.value
    }

    func setAccount(_ accountID: Int64?) {
        guard self.accountID != accountID else { return }
        accountGeneration &+= 1
        let generation = accountGeneration
        let oldActive = activeTask
        let oldTransition = accountTransitionTask
        let checkpoints = manifests.values.filter {
            $0.accountID == self.accountID
                && ($0.phase.isInterruptedTransfer || dirtyDrafts.contains($0.id))
        }

        activeTask?.cancel()
        preparationTasks.values.forEach { $0.cancel() }
        draftSaveTasks.values.forEach { $0.cancel() }
        pending.removeAll()
        preparationTasks.removeAll()
        draftSaveTasks.removeAll()
        draftContexts.removeAll()
        dirtyDrafts.removeAll()
        draftVersions.removeAll()
        lockedDrafts.removeAll()
        pauseRequested.removeAll()
        activeID = nil
        activeTaskIdentity = nil
        activeTask = nil
        operationIdentities.removeAll()
        items.removeAll()
        itemOrder.removeAll()
        self.accountID = accountID
        showCurrentAccount()

        accountTransitionTask = Task { [weak self, store] in
            await oldTransition?.value
            var persistenceFailure: Error?
            for var manifest in checkpoints {
                if !manifest.phase.requiresReconciliationOrCleanup { manifest.phase = .paused }
                do {
                    try await store.save(manifest)
                } catch {
                    persistenceFailure = persistenceFailure ?? error
                }
            }
            await oldActive?.value
            if persistenceFailure == nil {
                do {
                    try await store.flush()
                } catch {
                    persistenceFailure = error
                }
            }
            guard let self, self.accountGeneration == generation else { return }
            self.accountTransitionTask = nil
            if let persistenceFailure {
                self.persistenceError = "无法完成上传记录写入：\(persistenceFailure.localizedDescription)"
                return
            }
            self.schedule()
        }
    }

    @discardableResult
    func prepareCloudFile(_ url: URL) -> UUID? {
        prepare(url, destination: .cloud, podcastForm: nil)
    }

    @discardableResult
    func preparePodcastFile(_ url: URL, form: PodcastUploadForm) -> UUID? {
        prepare(url, destination: .podcast(voiceListID: form.voiceListID), podcastForm: form)
    }

    func updateMetadata(id: UUID, title: String? = nil, artist: String? = nil, album: String? = nil) {
        guard var manifest = manifests[id], manifest.phase == .paused, !lockedDrafts.contains(id) else { return }
        if let title { manifest.metadata.title = title }
        if let artist { manifest.metadata.artist = artist }
        if let album { manifest.metadata.album = album }
        stageDraft(manifest)
    }

    func updatePodcastForm(
        id: UUID,
        name: String? = nil,
        description: String? = nil,
        isPrivate: Bool? = nil,
        publishTimeMilliseconds: Int64? = nil,
        order: Int? = nil
    ) {
        guard var manifest = manifests[id],
              manifest.phase == .paused,
              !lockedDrafts.contains(id),
              var form = manifest.podcastForm
        else { return }
        if let name { form.name = name }
        if let description { form.description = description }
        if let isPrivate { form.isPrivate = isPrivate }
        if let publishTimeMilliseconds { form.publishTimeMilliseconds = max(0, publishTimeMilliseconds) }
        if let order { form.order = max(1, order) }
        manifest.podcastForm = form
        stageDraft(manifest)
    }

    func flushEdits() async {
        let contexts = Array(dirtyDrafts).compactMap { id in
            manifests[id].flatMap(beginContext)
        }
        let fence = (
            accountID: accountID,
            generation: accountGeneration,
            credentialRevision: credentialRevision()
        )
        for context in contexts {
            draftSaveTasks.removeValue(forKey: context.id)?.cancel()
            draftContexts[context.id] = context
            do {
                try await flushDraft(context.id, context: context)
            } catch is CancellationError {
            } catch {
                fail(context, "无法保存上传信息：\(error.localizedDescription)")
            }
        }
        do {
            try await store.flush()
        } catch {
            publishPersistenceError(
                "无法完成上传记录写入：\(error.localizedDescription)",
                fence: fence
            )
        }
    }

    func start(_ id: UUID) async {
        await waitUntilLoaded()
        guard var manifest = manifests[id],
              !manifest.phase.requiresReconciliationOrCleanup,
              let context = beginContext(for: manifest)
        else { return }
        lockedDrafts.insert(id)
        draftSaveTasks.removeValue(forKey: id)?.cancel()
        draftContexts[id] = context
        defer {
            if isCurrent(context) { lockedDrafts.remove(id) }
        }
        do {
            try await flushDraft(id, context: context)
            try validate(context)
            guard let latest = manifests[id] else { throw CancellationError() }
            manifest = latest
            manifest.metadata.title = requiredTitle(manifest.metadata.title, filename: manifest.filename)
            if let form = manifest.podcastForm { manifest.podcastForm = try form.validated() }
            manifest.phase = .allocating
            _ = try await persist(manifest, context: context)
            try commit(context) {
                pauseRequested.remove(id)
                if !pending.contains(where: { $0.id == id }), activeID != id {
                    pending.append(PendingUpload(id: id, context: context))
                }
                schedule()
            }
        } catch is CancellationError {
        } catch {
            fail(context, "无法保存上传进度：\(error.localizedDescription)")
        }
    }

    func pause(_ id: UUID) async {
        guard let manifest = manifests[id], let context = beginContext(for: manifest) else { return }
        draftSaveTasks.removeValue(forKey: id)?.cancel()
        draftContexts[id] = context
        do {
            try await flushDraft(id, context: context)
        } catch is CancellationError {
            return
        } catch {
            fail(context, "无法保存上传信息：\(error.localizedDescription)")
            return
        }
        do {
            try commit(context) { pending.removeAll { $0.id == id } }
        } catch {
            return
        }
        if activeID == id {
            pauseRequested.insert(id)
            activeTask?.cancel()
            await activeTask?.value
            _ = try? commit(context) { pauseRequested.remove(id) }
        }
        guard isCurrent(context) else { return }
        guard var manifest = manifests[id], !manifest.phase.requiresReconciliationOrCleanup else { return }
        manifest.phase = .paused
        do {
            _ = try await persist(manifest, context: context)
        } catch is CancellationError {
        } catch {
            fail(context, "无法保存暂停状态：\(error.localizedDescription)")
        }
    }

    func retry(_ id: UUID) async {
        guard case .failed? = items[id]?.phase, let manifest = manifests[id] else { return }
        switch manifest.phase {
        case .completed, .cleanupPending:
            items[id]?.phase = manifest.phase
            retryCleanup(manifest)
        case .reconciling:
            items[id]?.phase = manifest.phase
            reconcile(id)
        default:
            await start(id)
        }
    }

    func reconcile(_ id: UUID) {
        guard preparationTasks[id] == nil,
              activeID != id,
              let manifest = manifests[id],
              manifest.phase == .reconciling,
              let context = beginContext(for: manifest)
        else { return }
        let task = Task { [weak self] in
            guard let self else { return }
            defer { finishPreparation(context) }
            do {
                let found = switch manifest.destination {
                case .cloud:
                    try await musicLibrary.reconcileCloudUpload(
                        md5: manifest.md5,
                        songID: manifest.cloud.registeredSongID ?? manifest.cloud.songID,
                        expectedCredentialRevision: context.credentialRevision
                    )
                case let .podcast(voiceListID):
                    try await audioLibrary.reconcilePodcastUpload(
                        voiceListID: voiceListID,
                        documentID: manifest.podcast.documentID,
                        expectedCredentialRevision: context.credentialRevision
                    )
                }
                try validate(context)
                if found {
                    await complete(id, context: context)
                } else {
                    var failed = manifest
                    failed.phase = .failed("服务列表中尚未找到该音频，可显式重试")
                    _ = try await persist(failed, context: context)
                }
            } catch is CancellationError {
            } catch is CredentialRevisionMismatch {
            } catch {
                fail(context, "对账失败：\(error.localizedDescription)")
            }
        }
        preparationTasks[id] = task
    }

    func cancel(_ id: UUID) async {
        guard let context = beginContext(id: id) else { return }
        preparationTasks.removeValue(forKey: id)?.cancel()
        draftSaveTasks.removeValue(forKey: id)?.cancel()
        draftContexts.removeValue(forKey: id)
        dirtyDrafts.remove(id)
        draftVersions.removeValue(forKey: id)
        lockedDrafts.remove(id)
        pending.removeAll { $0.id == id }
        pauseRequested.insert(id)
        if activeID == id {
            activeTask?.cancel()
            await activeTask?.value
        }
        _ = try? commit(context) { pauseRequested.remove(id) }
        guard isCurrent(context) else { return }

        guard var manifest = manifests[id] else {
            _ = try? commit(context) {
                items.removeValue(forKey: id)
                itemOrder.removeAll { $0 == id }
                sourceIdentities.removeValue(forKey: id)
                operationIdentities.removeValue(forKey: id)
            }
            return
        }
        manifest.phase = .cleanupPending("正在清理本地上传记录")
        do {
            _ = try await persist(manifest, context: context)
            try validate(context)
            try await store.remove(id)
            try commit(context) {
                manifests.removeValue(forKey: id)
                items.removeValue(forKey: id)
                itemOrder.removeAll { $0 == id }
                sourceIdentities.removeValue(forKey: id)
                operationIdentities.removeValue(forKey: id)
            }
        } catch is CancellationError {
        } catch {
            fail(context, "无法删除上传记录：\(error.localizedDescription)")
        }
    }

    func pauseAll() async {
        persistenceError = nil
        await waitUntilLoaded()
        await accountTransitionTask?.value
        let pendingIDs = pending.map(\.id)
        let activeID = activeID
        var targetIDs = Set(pendingIDs).union(dirtyDrafts)
        if let activeID { targetIDs.insert(activeID) }
        let snapshots = Dictionary(uniqueKeysWithValues: targetIDs.compactMap { id in
            manifests[id].map { (id, $0) }
        })
        let contexts = Dictionary(uniqueKeysWithValues: targetIDs.compactMap { id in
            beginContext(id: id).map { (id, $0) }
        })
        let fence = (
            accountID: accountID,
            generation: accountGeneration,
            credentialRevision: credentialRevision()
        )
        let task = activeTask

        if let activeID {
            pauseRequested.insert(activeID)
            task?.cancel()
        }
        for id in Array(dirtyDrafts) {
            guard let context = contexts[id] else { continue }
            draftSaveTasks.removeValue(forKey: id)?.cancel()
            draftContexts[id] = context
            do {
                try await flushDraft(id, context: context)
            } catch is CancellationError {
            } catch {
                fail(context, "无法保存上传信息：\(error.localizedDescription)")
            }
        }
        for id in pendingIDs {
            guard var manifest = snapshots[id],
                  let context = contexts[id],
                  !manifest.phase.requiresReconciliationOrCleanup
            else { continue }
            manifest.phase = .paused
            do {
                _ = try await persist(manifest, context: context)
            } catch is CancellationError {
            } catch {
                fail(context, "无法保存暂停状态：\(error.localizedDescription)")
            }
            _ = try? commit(context) { pending.removeAll { $0.id == id } }
        }
        if let activeID,
           var manifest = snapshots[activeID],
           let context = contexts[activeID],
           !manifest.phase.requiresReconciliationOrCleanup {
            manifest.phase = .paused
            do {
                _ = try await persist(manifest, context: context)
            } catch is CancellationError {
            } catch {
                fail(context, "无法保存暂停状态：\(error.localizedDescription)")
            }
        }
        if let task {
            let finished = await waitForCompletion(task, timeout: pauseTimeout)
            if !finished {
                publishPersistenceError("暂停上传超时；已保留可恢复记录", fence: fence)
            }
        }
        if let activeID, let context = contexts[activeID] {
            _ = try? commit(context) { pauseRequested.remove(activeID) }
        }
        do {
            try await store.flush()
        } catch {
            publishPersistenceError(
                "无法完成上传记录写入：\(error.localizedDescription)",
                fence: fence
            )
        }
    }

    private func install(_ result: AudioUploadLoadResult) {
        loadTask = nil
        if !result.diagnostics.isEmpty { persistenceError = result.diagnostics.joined(separator: "\n") }
        for manifest in result.manifests where manifests[manifest.id] == nil {
            manifests[manifest.id] = manifest
        }
        showCurrentAccount()
    }

    private func showCurrentAccount() {
        guard let accountID else { return }
        for stored in manifests.values
            .filter({ $0.accountID == accountID })
            .sorted(by: { $0.savedAt < $1.savedAt }) {
            var manifest = stored
            if manifest.phase.isInterruptedTransfer {
                manifest.phase = .paused
                stageDraft(manifest)
            } else {
                manifests[manifest.id] = manifest
                items[manifest.id] = item(manifest)
            }
            if !itemOrder.contains(manifest.id) { itemOrder.append(manifest.id) }
            if manifest.phase.requiresCleanup { retryCleanup(manifest) }
        }
    }

    private func retryCleanup(_ manifest: AudioUploadManifest) {
        guard preparationTasks[manifest.id] == nil,
              let context = beginContext(for: manifest)
        else { return }
        preparationTasks[manifest.id] = Task { [weak self, store] in
            guard let self else { return }
            defer { finishPreparation(context) }
            do {
                try validate(context)
                try await store.remove(manifest.id)
                try commit(context) {
                    guard self.manifests[manifest.id]?.phase.requiresCleanup == true else { return }
                    self.manifests.removeValue(forKey: manifest.id)
                    self.items.removeValue(forKey: manifest.id)
                    self.itemOrder.removeAll { $0 == manifest.id }
                }
            } catch is CancellationError {
            } catch {
                _ = try? commit(context) {
                    self.items[manifest.id]?.phase = .cleanupPending(
                        "无法清理上传记录：\(error.localizedDescription)"
                    )
                }
            }
        }
    }

    private func prepare(
        _ url: URL,
        destination: AudioUploadDestination,
        podcastForm: PodcastUploadForm?
    ) -> UUID? {
        guard let accountID else { return nil }
        let id = UUID()
        guard let context = beginContext(id: id, accountID: accountID) else { return nil }
        items[id] = AudioUploadItem(
            id: id,
            destination: destination,
            filename: url.lastPathComponent,
            byteCount: 0,
            metadata: nil,
            podcastForm: podcastForm,
            phase: .inspecting
        )
        itemOrder.append(id)
        let task = Task { [weak self] in
            guard let self else { return }
            defer { finishPreparation(context) }
            do {
                try commit(context) { self.items[id]?.phase = .hashing }
            } catch {
                return
            }
            do {
                var manifest = try await AudioUploadInspector.inspect(
                    url,
                    accountID: accountID,
                    destination: destination,
                    podcastForm: podcastForm
                )
                try validate(context)
                manifest = AudioUploadManifest(
                    id: id,
                    accountID: manifest.accountID,
                    destination: manifest.destination,
                    bookmark: manifest.bookmark,
                    filename: manifest.filename,
                    fileExtension: manifest.fileExtension,
                    contentType: manifest.contentType,
                    byteCount: manifest.byteCount,
                    modificationTime: manifest.modificationTime,
                    md5: manifest.md5,
                    metadata: manifest.metadata,
                    podcastForm: manifest.podcastForm
                )
                _ = try await persist(manifest, context: context)
            } catch is CancellationError {
                _ = try? commit(context) {
                    self.items.removeValue(forKey: id)
                    self.itemOrder.removeAll { $0 == id }
                }
            } catch {
                _ = try? commit(context) { self.items[id]?.phase = .failed(error.localizedDescription) }
            }
        }
        preparationTasks[id] = task
        return id
    }

    private func schedule() {
        guard activeID == nil, accountTransitionTask == nil else { return }
        while let next = pending.first {
            pending.removeFirst()
            guard manifests[next.id]?.accountID == accountID,
                  isCurrent(next.context, id: next.id)
            else { continue }
            activeID = next.id
            activeTaskIdentity = next.context.identity
            activeTask = Task { [weak self] in
                guard let self else { return }
                await run(next.id, context: next.context)
                guard activeID == next.id,
                      activeTaskIdentity == next.context.identity
                else { return }
                activeID = nil
                activeTaskIdentity = nil
                activeTask = nil
                schedule()
            }
            break
        }
    }

    private func run(_ id: UUID, context: UploadContext) async {
        guard var manifest = manifests[id] else { return }
        do {
            let source = try await AudioUploadInspector.resolve(
                manifest,
                cachedIdentity: sourceIdentities[id]
            )
            try validate(context, id: id)
            sourceIdentities[id] = source.identity
            let accessed = source.url.startAccessingSecurityScopedResource()
            defer { if accessed { source.url.stopAccessingSecurityScopedResource() } }
            try validate(context, id: id)
            switch manifest.destination {
            case .cloud:
                try await runCloud(id, manifest: &manifest, url: source.url, context: context)
            case .podcast:
                try await runPodcast(id, manifest: &manifest, url: source.url, context: context)
            }
        } catch is CancellationError {
            await persistPausedIfSafe(manifest, context: context)
        } catch is CredentialRevisionMismatch {
            await persistPausedIfSafe(manifest, context: context)
        } catch {
            guard isCurrent(context, id: id),
                  manifests[id]?.phase != .reconciling
            else { return }
            let transferError = error
            do {
                try await flushCheckpoints(context)
                fail(context, transferError.localizedDescription)
            } catch {
                fail(context, "无法保存上传进度：\(error.localizedDescription)")
            }
        }
    }

    private func runCloud(
        _ id: UUID,
        manifest: inout AudioUploadManifest,
        url: URL,
        context: UploadContext
    ) async throws {
        try validate(context, id: id)
        let check = try await musicLibrary.checkCloudUpload(
            manifest,
            expectedCredentialRevision: context.credentialRevision
        )
        try validate(context, id: id)
        let allocation = try await musicLibrary.allocateCloudUpload(
            manifest,
            expectedCredentialRevision: context.credentialRevision
        )
        try validate(context, id: id)
        if !manifest.cloud.objectKey.isEmpty,
           manifest.cloud.objectKey != allocation.objectKey || manifest.cloud.resourceID != allocation.resourceID {
            manifest.cloud = CloudUploadResume()
        }
        manifest.cloud.objectKey = allocation.objectKey
        manifest.cloud.resourceID = allocation.resourceID
        manifest.cloud.songID = check.songID
        manifest = try await persist(manifest, context: context)

        if check.needsUpload, manifest.cloud.confirmedOffset < manifest.byteCount {
            let uploadBase = try await nos.cloudUploadBase()
            try validate(context, id: id)
            manifest.phase = .uploading(
                completed: manifest.cloud.confirmedOffset,
                total: manifest.byteCount
            )
            manifest = try await persist(manifest, context: context)
            try await nos.uploadCloud(
                fileURL: url,
                manifest: manifest,
                allocation: allocation,
                uploadBase: uploadBase,
                confirmedOffset: manifest.cloud.confirmedOffset,
                authorize: { try await self.validate(context, id: id) },
                shouldPause: { await self.shouldPause(id, context: context) },
                didConfirm: { offset in
                    try await self.confirmCloudOffset(id, offset: offset, context: context)
                },
                progress: progressHandler(id, context: context)
            )
            try validate(context, id: id)
            try await flushCheckpoints(context)
            guard let updated = manifests[id] else { throw CancellationError() }
            manifest = updated
        }

        if manifest.cloud.registeredSongID == nil {
            manifest.phase = .reconciling
            manifest = try await persist(manifest, context: context)
            let songID = try await musicLibrary.registerCloudUpload(
                manifest,
                allocation: allocation,
                expectedCredentialRevision: context.credentialRevision
            )
            try validate(context, id: id)
            manifest.cloud.registeredSongID = songID
            manifest.phase = .registering
            manifest = try await persist(manifest, context: context)
        }

        manifest.phase = .reconciling
        manifest = try await persist(manifest, context: context)
        try await musicLibrary.publishCloudUpload(
            songID: manifest.cloud.registeredSongID ?? 0,
            expectedCredentialRevision: context.credentialRevision
        )
        try validate(context, id: id)
        await complete(id, context: context)
    }

    private func runPodcast(
        _ id: UUID,
        manifest: inout AudioUploadManifest,
        url: URL,
        context: UploadContext
    ) async throws {
        guard let form = manifest.podcastForm else { throw AudioUploadError.invalidPodcastForm }
        let allocation = try await audioLibrary.allocatePodcastUpload(
            manifest,
            expectedCredentialRevision: context.credentialRevision
        )
        try validate(context, id: id)
        if !manifest.podcast.objectKey.isEmpty,
           manifest.podcast.objectKey != allocation.objectKey
            || manifest.podcast.documentID != allocation.documentID {
            manifest.podcast = PodcastUploadResume()
        }
        manifest.podcast.objectKey = allocation.objectKey
        manifest.podcast.documentID = allocation.documentID
        manifest = try await persist(manifest, context: context)

        if manifest.podcast.uploadID.isEmpty {
            manifest.podcast.uploadID = try await nos.initiatePodcastMultipart(
                allocation: allocation,
                contentType: manifest.contentType,
                authorize: { try await self.validate(context, id: id) }
            )
            try validate(context, id: id)
            manifest = try await persist(manifest, context: context)
        }

        let partCount = Int((manifest.byteCount + Int64(PodcastUploadResume.partSize) - 1)
            / Int64(PodcastUploadResume.partSize))
        var uploadedPartNumbers = manifest.podcast.uploadedPartNumbers
        let uploadedBytes = min(
            manifest.byteCount,
            Int64(uploadedPartNumbers.count * PodcastUploadResume.partSize)
        )
        manifest.phase = .uploading(completed: uploadedBytes, total: manifest.byteCount)
        manifest = try await persist(manifest, context: context)
        for partNumber in 1...partCount where !uploadedPartNumbers.contains(partNumber) {
            try validate(context, id: id)
            let part = try await nos.uploadPodcastPart(
                fileURL: url,
                manifest: manifest,
                allocation: allocation,
                uploadID: manifest.podcast.uploadID,
                partNumber: partNumber,
                authorize: { try await self.validate(context, id: id) },
                progress: progressHandler(id, context: context)
            )
            try validate(context, id: id)
            guard uploadedPartNumbers.insert(part.number).inserted else { continue }
            manifest.podcast.parts.append(part)
            manifest = if manifest.podcast.parts.count == 1 {
                try await persist(manifest, context: context)
            } else {
                try await persistCheckpoint(manifest, context: context)
            }
        }
        try await flushCheckpoints(context)

        if !manifest.podcast.multipartCompleted {
            manifest.phase = .reconciling
            manifest = try await persist(manifest, context: context)
            try await nos.completePodcastMultipart(
                allocation: allocation,
                uploadID: manifest.podcast.uploadID,
                contentType: manifest.contentType,
                parts: manifest.podcast.parts,
                authorize: { try await self.validate(context, id: id) }
            )
            try validate(context, id: id)
            manifest.podcast.multipartCompleted = true
            manifest.phase = .registering
            manifest = try await persist(manifest, context: context)
        }

        if !manifest.podcast.prechecked {
            manifest.phase = .reconciling
            manifest = try await persist(manifest, context: context)
            try await audioLibrary.precheckPodcastUpload(
                form: form,
                documentID: allocation.documentID,
                token: allocation.token,
                expectedCredentialRevision: context.credentialRevision
            )
            try validate(context, id: id)
            manifest.podcast.prechecked = true
            manifest.phase = .registering
            manifest = try await persist(manifest, context: context)
        }

        manifest.phase = .reconciling
        manifest = try await persist(manifest, context: context)
        try await audioLibrary.submitPodcastUpload(
            form: form,
            documentID: allocation.documentID,
            token: allocation.token,
            expectedCredentialRevision: context.credentialRevision
        )
        try validate(context, id: id)
        await complete(id, context: context)
    }

    private func confirmCloudOffset(
        _ id: UUID,
        offset: Int64,
        context: UploadContext
    ) async throws {
        try validate(context, id: id)
        guard var manifest = manifests[id],
              offset >= manifest.cloud.confirmedOffset,
              offset <= manifest.byteCount
        else { throw AudioUploadError.invalidServerOffset }
        let isFirstCheckpoint = manifest.cloud.confirmedOffset == 0
        manifest.cloud.confirmedOffset = offset
        manifest.phase = .uploading(completed: offset, total: manifest.byteCount)
        if isFirstCheckpoint {
            _ = try await persist(manifest, context: context)
        } else {
            _ = try await persistCheckpoint(manifest, context: context)
        }
    }

    private func shouldPause(_ id: UUID, context: UploadContext) -> Bool {
        pauseRequested.contains(id) || !isCurrent(context, id: id)
    }

    private func progressHandler(
        _ id: UUID,
        context: UploadContext
    ) -> @Sendable (Int64, Int64) -> Void {
        { [weak self] completed, total in
            Task { @MainActor in
                guard let self, self.activeID == id, self.isCurrent(context, id: id) else { return }
                self.items[id]?.phase = .uploading(completed: completed, total: total)
            }
        }
    }

    private func beginContext(for manifest: AudioUploadManifest) -> UploadContext? {
        beginContext(id: manifest.id, accountID: manifest.accountID)
    }

    private func beginContext(id: UUID, accountID expectedAccountID: Int64? = nil) -> UploadContext? {
        guard let accountID,
              expectedAccountID.map({ $0 == accountID }) ?? true
        else { return nil }
        let identity = UUID()
        operationIdentities[id] = identity
        return UploadContext(
            accountID: accountID,
            generation: accountGeneration,
            credentialRevision: credentialRevision(),
            id: id,
            identity: identity
        )
    }

    private func authorize(_ context: UploadContext, id: UUID? = nil) throws {
        guard isCurrent(context, id: id) else { throw CancellationError() }
    }

    private func validate(_ context: UploadContext, id: UUID? = nil) throws {
        try Task.checkCancellation()
        try authorize(context, id: id)
        if pauseRequested.contains(context.id) { throw CancellationError() }
    }

    private func isCurrent(_ context: UploadContext, id: UUID? = nil) -> Bool {
        accountID == context.accountID
            && accountGeneration == context.generation
            && credentialRevision() == context.credentialRevision
            && operationIdentities[context.id] == context.identity
            && (id.map { $0 == context.id } ?? true)
    }

    @discardableResult
    private func commit<Value>(_ context: UploadContext, _ body: () throws -> Value) throws -> Value {
        try authorize(context)
        return try body()
    }

    private func persistPausedIfSafe(_ value: AudioUploadManifest, context: UploadContext) async {
        guard !value.phase.requiresReconciliationOrCleanup else { return }
        var manifest = manifests[value.id] ?? value
        manifest.phase = .paused
        do {
            if isCurrent(context) {
                _ = try await persist(manifest, context: context)
                try await flushCheckpoints(context)
            } else {
                _ = try await persistDurably(manifest)
            }
        } catch {
            fail(context, "无法保存暂停状态：\(error.localizedDescription)")
        }
    }

    private func complete(_ id: UUID, context: UploadContext) async {
        guard var manifest = manifests[id], isCurrent(context) else { return }
        manifest.phase = .completed
        do {
            manifest = try await persist(manifest, context: context)
            try await flushCheckpoints(context)
            try commit(context) {
                pauseRequested.remove(id)
                switch manifest.destination {
                case .cloud:
                    completionRevision &+= 1
                case .podcast:
                    podcastCompletionRevision &+= 1
                }
            }
        } catch is CancellationError {
            return
        } catch {
            fail(context, "无法保存完成状态：\(error.localizedDescription)")
            return
        }
        do {
            try authorize(context)
            try await store.remove(id)
            try commit(context) { manifests.removeValue(forKey: id) }
        } catch is CancellationError {
            return
        } catch {
            let removeError = error
            manifest.phase = .cleanupPending("上传已完成，等待清理本地记录")
            if isCurrent(context) {
                do {
                    _ = try await persist(manifest, context: context)
                } catch is CancellationError {
                    return
                } catch {
                    _ = try? commit(context) {
                        persistenceError = "无法保存清理状态：\(error.localizedDescription)"
                    }
                }
                _ = try? commit(context) {
                    persistenceError = "无法清理上传记录：\(removeError.localizedDescription)"
                }
            } else {
                _ = try? await persistDurably(manifest)
            }
        }
    }

    private func stageDraft(_ manifest: AudioUploadManifest) {
        guard let context = beginContext(for: manifest) else { return }
        manifests[manifest.id] = manifest
        items[manifest.id] = item(manifest)
        dirtyDrafts.insert(manifest.id)
        draftVersions[manifest.id, default: 0] &+= 1
        draftSaveTasks[manifest.id]?.cancel()
        draftContexts[manifest.id] = context
        draftSaveTasks[manifest.id] = Task { [weak self] in
            defer { self?.finishDraft(context) }
            do {
                try await Task.sleep(for: .milliseconds(300))
                try await self?.flushDraft(manifest.id, context: context)
            } catch is CancellationError {
            } catch {
                self?.fail(context, "无法保存上传信息：\(error.localizedDescription)")
            }
        }
    }

    private func flushDraft(_ id: UUID, context: UploadContext) async throws {
        guard dirtyDrafts.contains(id), var manifest = manifests[id] else { return }
        let version = draftVersions[id, default: 0]
        try authorize(context, id: id)
        manifest.savedAt = Date()
        do {
            try await store.save(manifest)
        } catch {
            _ = try? commit(context) {
                persistenceError = "无法保存上传信息：\(error.localizedDescription)"
            }
            throw error
        }
        try commit(context) {
            guard draftVersions[id, default: 0] == version else { throw CancellationError() }
            manifests[id] = manifest
            items[id] = item(manifest)
            dirtyDrafts.remove(id)
            draftContexts.removeValue(forKey: id)
        }
    }

    @discardableResult
    private func persist(
        _ value: AudioUploadManifest,
        context: UploadContext
    ) async throws -> AudioUploadManifest {
        try authorize(context, id: value.id)
        let manifest: AudioUploadManifest
        do {
            manifest = try await persistDurably(value)
        } catch {
            _ = try? commit(context) {
                persistenceError = "无法保存上传进度：\(error.localizedDescription)"
            }
            throw error
        }
        try commit(context) {
            manifests[manifest.id] = manifest
            items[manifest.id] = item(manifest)
            if !itemOrder.contains(manifest.id) { itemOrder.append(manifest.id) }
        }
        return manifest
    }

    private func persistDurably(_ value: AudioUploadManifest) async throws -> AudioUploadManifest {
        var manifest = value
        manifest.savedAt = Date()
        try await store.save(manifest)
        return manifest
    }

    @discardableResult
    private func persistCheckpoint(
        _ value: AudioUploadManifest,
        context: UploadContext
    ) async throws -> AudioUploadManifest {
        try authorize(context, id: value.id)
        var manifest = value
        manifest.savedAt = Date()
        do {
            try await store.checkpoint(manifest)
        } catch {
            _ = try? commit(context) {
                manifests[manifest.id] = manifest
                items[manifest.id] = item(manifest)
                persistenceError = "无法保存上传进度：\(error.localizedDescription)"
            }
            throw error
        }
        try commit(context) {
            manifests[manifest.id] = manifest
            items[manifest.id] = item(manifest)
        }
        return manifest
    }

    private func flushCheckpoints(_ context: UploadContext) async throws {
        try authorize(context)
        do {
            try await store.flush()
        } catch {
            _ = try? commit(context) {
                persistenceError = "无法完成上传记录写入：\(error.localizedDescription)"
            }
            throw error
        }
        try authorize(context)
    }

    private func fail(_ context: UploadContext, _ message: String) {
        _ = try? commit(context) { items[context.id]?.phase = .failed(message) }
    }

    private func finishPreparation(_ context: UploadContext) {
        guard isCurrent(context) else { return }
        preparationTasks.removeValue(forKey: context.id)
    }

    private func finishDraft(_ context: UploadContext) {
        guard isCurrent(context) else { return }
        draftSaveTasks.removeValue(forKey: context.id)
        draftContexts.removeValue(forKey: context.id)
    }

    private func publishPersistenceError(
        _ message: String,
        fence: (accountID: Int64?, generation: UInt64, credentialRevision: UInt64)
    ) {
        guard accountID == fence.accountID,
              accountGeneration == fence.generation,
              credentialRevision() == fence.credentialRevision
        else { return }
        persistenceError = message
    }

    private func item(_ manifest: AudioUploadManifest) -> AudioUploadItem {
        AudioUploadItem(
            id: manifest.id,
            destination: manifest.destination,
            filename: manifest.filename,
            byteCount: manifest.byteCount,
            metadata: manifest.metadata,
            podcastForm: manifest.podcastForm,
            phase: manifest.phase
        )
    }

    private func requiredTitle(_ value: String, filename: String) -> String {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? (filename as NSString).deletingPathExtension : value
    }

    private func waitForCompletion(_ task: Task<Void, Never>, timeout: Duration) async -> Bool {
        let waiter = UploadTaskWaiter()
        Task {
            await task.value
            waiter.resolve(true)
        }
        Task {
            try? await Task.sleep(for: timeout)
            waiter.resolve(false)
        }
        return await waiter.wait()
    }
}

private final class UploadTaskWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?
    private var result: Bool?

    func wait() async -> Bool {
        await withCheckedContinuation { continuation in
            let result = lock.withLock { () -> Bool? in
                if let result = self.result { return result }
                self.continuation = continuation
                return nil
            }
            if let result { continuation.resume(returning: result) }
        }
    }

    func resolve(_ result: Bool) {
        let continuation = lock.withLock { () -> CheckedContinuation<Bool, Never>? in
            guard self.result == nil else { return nil }
            self.result = result
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.resume(returning: result)
    }
}

private extension AudioUploadPhase {
    var isInterruptedTransfer: Bool {
        switch self {
        case .inspecting, .hashing, .allocating, .uploading, .registering: true
        case .paused, .reconciling, .completed, .cleanupPending, .failed: false
        }
    }

    var requiresReconciliationOrCleanup: Bool {
        switch self {
        case .reconciling, .completed, .cleanupPending: true
        case .inspecting, .hashing, .allocating, .uploading, .registering, .paused, .failed: false
        }
    }

    var requiresCleanup: Bool {
        switch self {
        case .completed, .cleanupPending: true
        case .inspecting, .hashing, .allocating, .uploading, .registering, .paused, .reconciling, .failed: false
        }
    }
}
