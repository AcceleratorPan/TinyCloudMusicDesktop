import Foundation
import Observation

@MainActor
@Observable
final class AudioUploadManager {
    private(set) var items: [UUID: AudioUploadItem] = [:]
    private(set) var itemOrder: [UUID] = []
    private(set) var completionRevision = 0

    @ObservationIgnored private let musicLibrary: LiveMusicLibrary
    @ObservationIgnored private let audioLibrary: LiveAudioContentLibrary
    @ObservationIgnored private let nos: NOSAudioUpload
    @ObservationIgnored private let store: AudioUploadStore
    @ObservationIgnored private var manifests: [UUID: AudioUploadManifest] = [:]
    @ObservationIgnored private var pending: [UUID] = []
    @ObservationIgnored private var activeID: UUID?
    @ObservationIgnored private var activeTask: Task<Void, Never>?
    @ObservationIgnored private var preparationTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var pauseRequested: Set<UUID> = []
    @ObservationIgnored private var accountID: Int64?

    init(
        musicLibrary: LiveMusicLibrary,
        audioLibrary: LiveAudioContentLibrary,
        nos: NOSAudioUpload = NOSAudioUpload(),
        store: AudioUploadStore = .shared
    ) {
        self.musicLibrary = musicLibrary
        self.audioLibrary = audioLibrary
        self.nos = nos
        self.store = store
        manifests = Dictionary(uniqueKeysWithValues: store.load().map { ($0.id, $0) })
    }

    isolated deinit {
        activeTask?.cancel()
        preparationTasks.values.forEach { $0.cancel() }
    }

    var isActive: Bool { activeID != nil || !pending.isEmpty || !preparationTasks.isEmpty }

    func setAccount(_ accountID: Int64?) {
        guard self.accountID != accountID else { return }
        if let activeID { pauseRequested.insert(activeID) }
        pending.removeAll()
        preparationTasks.values.forEach { $0.cancel() }
        preparationTasks.removeAll()
        items.removeAll()
        itemOrder.removeAll()
        self.accountID = accountID

        guard let accountID else { return }
        for manifest in manifests.values.filter({ $0.accountID == accountID }).sorted(by: { $0.savedAt < $1.savedAt }) {
            var manifest = manifest
            if manifest.phase != .reconciling { manifest.phase = .paused }
            manifests[manifest.id] = manifest
            items[manifest.id] = item(manifest)
            itemOrder.append(manifest.id)
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
        guard var manifest = manifests[id], manifest.phase == .paused else { return }
        if let title { manifest.metadata.title = title }
        if let artist { manifest.metadata.artist = artist }
        if let album { manifest.metadata.album = album }
        save(manifest)
    }

    func updatePodcastForm(
        id: UUID,
        name: String? = nil,
        description: String? = nil,
        isPrivate: Bool? = nil,
        publishTimeMilliseconds: Int64? = nil,
        order: Int? = nil
    ) {
        guard var manifest = manifests[id], manifest.phase == .paused, var form = manifest.podcastForm else { return }
        if let name { form.name = name }
        if let description { form.description = description }
        if let isPrivate { form.isPrivate = isPrivate }
        if let publishTimeMilliseconds { form.publishTimeMilliseconds = max(0, publishTimeMilliseconds) }
        if let order { form.order = max(1, order) }
        manifest.podcastForm = form
        save(manifest)
    }

    func start(_ id: UUID) {
        guard var manifest = manifests[id], manifest.accountID == accountID else { return }
        do {
            manifest.metadata.title = requiredTitle(manifest.metadata.title, filename: manifest.filename)
            if let form = manifest.podcastForm { manifest.podcastForm = try form.validated() }
            save(manifest)
            mark(id, .allocating)
            pauseRequested.remove(id)
            if !pending.contains(id), activeID != id { pending.append(id) }
            schedule()
        } catch {
            mark(id, .failed(error.localizedDescription))
        }
    }

    func pause(_ id: UUID) {
        if activeID == id {
            pauseRequested.insert(id)
            return
        }
        pending.removeAll { $0 == id }
        if manifests[id] != nil { mark(id, .paused) }
    }

    func retry(_ id: UUID) {
        guard case .failed? = items[id]?.phase else { return }
        start(id)
    }

    func reconcile(_ id: UUID) {
        guard let manifest = manifests[id], manifest.phase == .reconciling else { return }
        let task = Task { [weak self] in
            guard let self else { return }
            defer { preparationTasks.removeValue(forKey: id) }
            do {
                let found = switch manifest.destination {
                case .cloud:
                    try await musicLibrary.reconcileCloudUpload(
                        md5: manifest.md5,
                        songID: manifest.cloud.registeredSongID ?? manifest.cloud.songID
                    )
                case let .podcast(voiceListID):
                    try await audioLibrary.reconcilePodcastUpload(
                        voiceListID: voiceListID,
                        documentID: manifest.podcast.documentID
                    )
                }
                if found {
                    complete(id)
                } else {
                    mark(id, .failed("服务列表中尚未找到该音频，可显式重试"))
                }
            } catch {
                mark(id, .failed("对账失败：\(error.localizedDescription)"))
            }
        }
        preparationTasks[id] = task
    }

    func cancel(_ id: UUID) {
        preparationTasks.removeValue(forKey: id)?.cancel()
        pending.removeAll { $0 == id }
        pauseRequested.remove(id)
        if activeID == id { activeTask?.cancel() }
        manifests.removeValue(forKey: id)
        items.removeValue(forKey: id)
        itemOrder.removeAll { $0 == id }
        store.remove(id)
    }

    func pauseAll() async {
        pending.forEach { mark($0, .paused) }
        pending.removeAll()
        if let activeID { pauseRequested.insert(activeID) }
        for _ in 0..<100 where activeID != nil {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    private func prepare(
        _ url: URL,
        destination: AudioUploadDestination,
        podcastForm: PodcastUploadForm?
    ) -> UUID? {
        guard let accountID else { return nil }
        let id = UUID()
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
            items[id]?.phase = .hashing
            do {
                var manifest = try await AudioUploadInspector.inspect(
                    url,
                    accountID: accountID,
                    destination: destination,
                    podcastForm: podcastForm
                )
                try Task.checkCancellation()
                guard self.accountID == accountID else { return }
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
                save(manifest)
            } catch is CancellationError {
                items.removeValue(forKey: id)
                itemOrder.removeAll { $0 == id }
            } catch {
                items[id]?.phase = .failed(error.localizedDescription)
            }
            preparationTasks.removeValue(forKey: id)
        }
        preparationTasks[id] = task
        return id
    }

    private func schedule() {
        guard activeID == nil else { return }
        while let id = pending.first {
            pending.removeFirst()
            guard manifests[id]?.accountID == accountID else { continue }
            activeID = id
            activeTask = Task { [weak self] in
                guard let self else { return }
                await run(id)
                if activeID == id { activeID = nil }
                activeTask = nil
                schedule()
            }
            break
        }
    }

    private func run(_ id: UUID) async {
        guard var manifest = manifests[id] else { return }
        do {
            let url = try AudioUploadInspector.resolve(manifest)
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            try pauseCheckpoint(id)
            switch manifest.destination {
            case .cloud:
                try await runCloud(id, manifest: &manifest, url: url)
            case .podcast:
                try await runPodcast(id, manifest: &manifest, url: url)
            }
        } catch is CancellationError {
            if manifests[id] != nil { mark(id, .paused) }
        } catch {
            if manifests[id]?.phase != .reconciling { mark(id, .failed(error.localizedDescription)) }
        }
    }

    private func runCloud(_ id: UUID, manifest: inout AudioUploadManifest, url: URL) async throws {
        mark(id, .allocating)
        let check = try await musicLibrary.checkCloudUpload(manifest)
        try pauseCheckpoint(id)
        let allocation = try await musicLibrary.allocateCloudUpload(manifest)
        if !manifest.cloud.objectKey.isEmpty,
           manifest.cloud.objectKey != allocation.objectKey || manifest.cloud.resourceID != allocation.resourceID {
            manifest.cloud = CloudUploadResume()
        }
        manifest.cloud.objectKey = allocation.objectKey
        manifest.cloud.resourceID = allocation.resourceID
        manifest.cloud.songID = check.songID
        save(manifest)
        try pauseCheckpoint(id)

        if check.needsUpload, manifest.cloud.confirmedOffset < manifest.byteCount {
            let uploadBase = try await nos.cloudUploadBase()
            try pauseCheckpoint(id)
            mark(id, .uploading(completed: manifest.cloud.confirmedOffset, total: manifest.byteCount))
            try await nos.uploadCloud(
                fileURL: url,
                manifest: manifest,
                allocation: allocation,
                uploadBase: uploadBase,
                confirmedOffset: manifest.cloud.confirmedOffset,
                shouldPause: { await self.shouldPause(id) },
                didConfirm: { offset in await self.confirmCloudOffset(id, offset: offset) },
                progress: progressHandler(id)
            )
            guard let updated = manifests[id] else { throw CancellationError() }
            manifest = updated
        }
        try pauseCheckpoint(id)

        mark(id, .registering)
        if manifest.cloud.registeredSongID == nil {
            do {
                manifest.cloud.registeredSongID = try await musicLibrary.registerCloudUpload(
                    manifest,
                    allocation: allocation
                )
                save(manifest)
            } catch {
                mark(id, .reconciling)
                throw AudioUploadError.resultUnknown
            }
        }
        try pauseCheckpoint(id)
        do {
            try await musicLibrary.publishCloudUpload(songID: manifest.cloud.registeredSongID ?? 0)
        } catch {
            mark(id, .reconciling)
            throw AudioUploadError.resultUnknown
        }
        complete(id)
    }

    private func runPodcast(_ id: UUID, manifest: inout AudioUploadManifest, url: URL) async throws {
        guard let form = manifest.podcastForm else { throw AudioUploadError.invalidPodcastForm }
        mark(id, .allocating)
        let allocation = try await audioLibrary.allocatePodcastUpload(manifest)
        if !manifest.podcast.objectKey.isEmpty,
           manifest.podcast.objectKey != allocation.objectKey || manifest.podcast.documentID != allocation.documentID {
            manifest.podcast = PodcastUploadResume()
        }
        manifest.podcast.objectKey = allocation.objectKey
        manifest.podcast.documentID = allocation.documentID
        save(manifest)
        try pauseCheckpoint(id)

        if manifest.podcast.uploadID.isEmpty {
            manifest.podcast.uploadID = try await nos.initiatePodcastMultipart(
                allocation: allocation,
                contentType: manifest.contentType
            )
            save(manifest)
        }
        let partCount = Int((manifest.byteCount + Int64(PodcastUploadResume.partSize) - 1)
            / Int64(PodcastUploadResume.partSize))
        let uploadedBytes = min(
            manifest.byteCount,
            Int64(manifest.podcast.parts.count * PodcastUploadResume.partSize)
        )
        mark(id, .uploading(completed: uploadedBytes, total: manifest.byteCount))
        for partNumber in 1...partCount where !manifest.podcast.parts.contains(where: { $0.number == partNumber }) {
            try pauseCheckpoint(id)
            let part = try await nos.uploadPodcastPart(
                fileURL: url,
                manifest: manifest,
                allocation: allocation,
                uploadID: manifest.podcast.uploadID,
                partNumber: partNumber,
                progress: progressHandler(id)
            )
            manifest.podcast.parts.append(part)
            save(manifest)
        }
        try pauseCheckpoint(id)

        if !manifest.podcast.multipartCompleted {
            do {
                try await nos.completePodcastMultipart(
                    allocation: allocation,
                    uploadID: manifest.podcast.uploadID,
                    contentType: manifest.contentType,
                    parts: manifest.podcast.parts
                )
                manifest.podcast.multipartCompleted = true
                save(manifest)
            } catch {
                mark(id, .reconciling)
                throw AudioUploadError.resultUnknown
            }
        }
        try pauseCheckpoint(id)
        mark(id, .registering)
        if !manifest.podcast.prechecked {
            do {
                try await audioLibrary.precheckPodcastUpload(
                    form: form,
                    documentID: allocation.documentID,
                    token: allocation.token
                )
                manifest.podcast.prechecked = true
                save(manifest)
            } catch {
                mark(id, .reconciling)
                throw AudioUploadError.resultUnknown
            }
        }
        try pauseCheckpoint(id)
        do {
            try await audioLibrary.submitPodcastUpload(
                form: form,
                documentID: allocation.documentID,
                token: allocation.token
            )
        } catch {
            mark(id, .reconciling)
            throw AudioUploadError.resultUnknown
        }
        complete(id)
    }

    private func confirmCloudOffset(_ id: UUID, offset: Int64) {
        guard var manifest = manifests[id], offset >= manifest.cloud.confirmedOffset else { return }
        manifest.cloud.confirmedOffset = offset
        save(manifest)
    }

    private func shouldPause(_ id: UUID) -> Bool {
        pauseRequested.contains(id) || manifests[id]?.accountID != accountID
    }

    private func progressHandler(_ id: UUID) -> @Sendable (Int64, Int64) -> Void {
        { [weak self] completed, total in
            Task { @MainActor in
                guard self?.activeID == id else { return }
                self?.items[id]?.phase = .uploading(completed: completed, total: total)
            }
        }
    }

    private func pauseCheckpoint(_ id: UUID) throws {
        try Task.checkCancellation()
        if pauseRequested.remove(id) != nil { throw CancellationError() }
        guard manifests[id]?.accountID == accountID else { throw CancellationError() }
    }

    private func complete(_ id: UUID) {
        items[id]?.phase = .completed
        manifests.removeValue(forKey: id)
        store.remove(id)
        pauseRequested.remove(id)
        completionRevision &+= 1
    }

    private func mark(_ id: UUID, _ phase: AudioUploadPhase) {
        items[id]?.phase = phase
        guard var manifest = manifests[id] else { return }
        manifest.phase = phase
        save(manifest, preservingCurrentPhase: false)
    }

    private func save(_ manifest: AudioUploadManifest, preservingCurrentPhase: Bool = true) {
        var manifest = manifest
        if preservingCurrentPhase, let current = manifests[manifest.id] { manifest.phase = current.phase }
        manifest.savedAt = Date()
        manifests[manifest.id] = manifest
        items[manifest.id] = item(manifest)
        if !itemOrder.contains(manifest.id) { itemOrder.append(manifest.id) }
        do {
            try store.save(manifest)
        } catch {
            items[manifest.id]?.phase = .failed("无法保存上传进度：\(error.localizedDescription)")
        }
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
}
