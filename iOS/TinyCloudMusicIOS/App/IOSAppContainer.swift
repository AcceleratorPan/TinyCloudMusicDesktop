import AVFoundation
import Observation
import UIKit

@MainActor
@Observable
final class IOSAppContainer {
    let model: AppModel
    let player: PlayerController
    private(set) var isStarting = true
    private(set) var startupError: String?
    private(set) var canRetryAudioSession = false

    private let credentialStore: CredentialStore
    private let credentialSnapshot: CredentialSnapshot
    private let audioSession: IOSAudioSessionCoordinator
    private let isTesting: Bool
    private var credentialStartupError: String?
    private var audioStartupError: String?
    private var credentialObserver: NSObjectProtocol?
    @ObservationIgnored private var backgroundCheckpointTask: Task<Void, Never>?
    @ObservationIgnored private var backgroundCheckpointID: UUID?
    @ObservationIgnored private var backgroundTaskIdentifier: UIBackgroundTaskIdentifier = .invalid

    init(isTesting: Bool = false) {
        let service = isTesting
            ? "TinyCloudMusicTests.\(UUID().uuidString)"
            : CredentialStore.productionService
        let credentialStore = CredentialStore(service: service)
        let credentialSnapshot = CredentialSnapshot()
        let transport = EAPITransport(credentialSnapshot: credentialSnapshot)
        let repository = LiveMusicRepository(transport: transport)
        let library = LiveMusicLibrary(transport: transport)
        let videoLibrary = LiveVideoLibrary(transport: transport)
        let audioLibrary = LiveAudioContentLibrary(transport: transport)
        let knowledgeLibrary = LiveMusicKnowledgeLibrary(transport: transport)
        let extras = LiveMusicExtras(transport: transport)
        let downloads = MusicDownloadManager(transport: transport)
        let uploads = AudioUploadManager(musicLibrary: library, audioLibrary: audioLibrary)
        let session = SessionController(
            store: credentialStore,
            credentialSnapshot: credentialSnapshot,
            transport: transport,
            validator: { credentials in
                try await Self.validatedAccount(for: credentials) != nil
            },
            vipValidator: { musicU in
                try await LiveMusicLibrary(
                    transport: EAPITransport(cookie: "", musicU: musicU)
                ).hasActiveVIP()
            }
        )
        let model = AppModel(
            repository: repository,
            library: library,
            videoLibrary: videoLibrary,
            audioLibrary: audioLibrary,
            knowledgeLibrary: knowledgeLibrary,
            extras: extras,
            downloads: downloads,
            uploads: uploads,
            session: session
        )
        let player = PlayerController(
            repository: repository,
            playbackQuality: model.settings.playbackQuality,
            cacheRoot: model.cacheFolderURL,
            crossfadeDuration: model.settings.crossfadeDuration,
            playbackControlFadeEnabled: model.settings.playbackControlFadeEnabled
        )
        let together = ListenTogetherController(
            service: LiveListenTogetherService(transport: transport),
            player: player
        )
        model.listenTogether = together
        session.beforeLogout = { [weak together] in
            await together?.prepareForLogout()
        }
        model.personalFM = PersonalFMController(
            library: library,
            player: player,
            onTrashSucceeded: { [weak model] in model?.showToast("已减少这首歌的推荐") }
        )

        self.credentialStore = credentialStore
        self.credentialSnapshot = credentialSnapshot
        self.isTesting = isTesting
        self.model = model
        self.player = player
        self.audioSession = model.audioSession
        credentialObserver = NotificationCenter.default.addObserver(
            forName: .neteaseCredentialIssue,
            object: nil,
            queue: .main
        ) { [weak session] notification in
            guard let event = notification.object as? SessionCredentialIssueEvent else { return }
            Task { @MainActor in
                guard let session, session.invalidate(event) else { return }
                if event.issue == .cookie { await session.restore() }
            }
        }
        audioSession.player = player
        player.onPlaybackRequested = { [weak audioSession] in audioSession?.musicPlaybackWillStart() }
    }

    isolated deinit {
        backgroundCheckpointTask?.cancel()
        endBackgroundTask()
        if let credentialObserver {
            NotificationCenter.default.removeObserver(credentialObserver)
        }
    }

    func didEnterBackground() {
        guard backgroundCheckpointTask == nil else { return }

        let checkpointID = UUID()
        backgroundCheckpointID = checkpointID
        backgroundTaskIdentifier = UIApplication.shared.beginBackgroundTask(
            withName: "TinyCloudMusic persistence checkpoint"
        ) { [weak self] in
            Task { @MainActor [weak self] in
                self?.expireBackgroundCheckpoint(checkpointID)
            }
        }

        let downloads = model.downloads
        let uploads = model.uploads
        let listenTogether = model.listenTogether
        let checkpointPlayer = player
        backgroundCheckpointTask = Task { [weak self] in
            await Self.checkpoint(
                downloads: downloads,
                uploads: uploads,
                listenTogether: listenTogether,
                player: checkpointPlayer
            )
            self?.finishBackgroundCheckpoint(checkpointID)
        }
    }

    func didBecomeActive() {
        endBackgroundTask()
        if let listenTogether = model.listenTogether, listenTogether.isSleeping {
            listenTogether.wake()
        }
    }

    private static func checkpoint(
        downloads: MusicDownloadManager?,
        uploads: AudioUploadManager?,
        listenTogether: ListenTogetherController?,
        player: PlayerController
    ) async {
        async let downloadCheckpoint: Void = checkpointDownloads(downloads)
        async let uploadCheckpoint: Void = checkpointUploads(uploads)
        async let realtimeCheckpoint: Void = checkpointRealtime(listenTogether, player: player)
        _ = await (downloadCheckpoint, uploadCheckpoint, realtimeCheckpoint)
    }

    private static func checkpointDownloads(_ downloads: MusicDownloadManager?) async {
        guard let downloads else { return }
        try? await downloads.flushPersistence(timeout: .seconds(3))
    }

    private static func checkpointUploads(_ uploads: AudioUploadManager?) async {
        await uploads?.flushEdits()
    }

    private static func checkpointRealtime(
        _ listenTogether: ListenTogetherController?,
        player: PlayerController
    ) async {
        guard player.isPlaybackRequested == false else { return }
        await listenTogether?.sleep()
    }

    private func finishBackgroundCheckpoint(_ checkpointID: UUID) {
        guard backgroundCheckpointID == checkpointID else { return }
        backgroundCheckpointTask = nil
        backgroundCheckpointID = nil
        endBackgroundTask()
    }

    private func expireBackgroundCheckpoint(_ checkpointID: UUID) {
        guard backgroundCheckpointID == checkpointID else { return }
        backgroundCheckpointTask?.cancel()
        backgroundCheckpointTask = nil
        backgroundCheckpointID = nil
        endBackgroundTask()
    }

    private func endBackgroundTask() {
        guard backgroundTaskIdentifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTaskIdentifier)
        backgroundTaskIdentifier = .invalid
    }

    func start() async {
        guard isStarting else { return }
        guard !isTesting else {
            isStarting = false
            return
        }
        do {
            credentialSnapshot.store(try credentialStore.loadSnapshotState())
            credentialStartupError = nil
        } catch {
            credentialStartupError = "无法读取本地会话：\(error.localizedDescription)"
        }
        do {
            try audioSession.activate()
            audioStartupError = nil
            canRetryAudioSession = false
        } catch {
            audioStartupError = "音频会话启动失败：\(error.localizedDescription)"
            canRetryAudioSession = true
        }
        let confirmedAccount = await model.session?.restore(accountValidator: { credentials in
            try await Self.validatedAccount(for: credentials)
        })
        player.setAccountCredentialRevision(model.session?.credentialRevision ?? 0)
        if model.session != nil {
            await model.refreshAccountState(
                confirmedAccount: confirmedAccount
            ) { [model] in model.loadHome() }
        } else {
            model.loadHome()
        }
        updateStartupError()
        isStarting = false
        _ = Task.detached(priority: .utility) {
            await MusicSheetWorker.shared.cleanupExpired(
                additionalRoots: [IOSExportFileStore.directory]
            )
        }
    }

    func retryAudioSession() {
        guard canRetryAudioSession else { return }
        do {
            try audioSession.activate()
            audioStartupError = nil
            canRetryAudioSession = false
        } catch {
            audioStartupError = "音频会话启动失败：\(error.localizedDescription)"
        }
        updateStartupError()
    }

    func dismissStartupError() {
        startupError = nil
    }

    private func updateStartupError() {
        let messages = [credentialStartupError, audioStartupError].compactMap { $0 }
        startupError = messages.isEmpty ? nil : messages.joined(separator: "\n")
    }

    nonisolated private static func validatedAccount(
        for credentials: SessionCredentials
    ) async throws -> MusicLibraryUser? {
        let validator = LiveMusicLibrary(
            transport: EAPITransport(cookie: credentials.cookie, musicU: "")
        )
        guard case let .loggedIn(user) = try await validator.loginState() else { return nil }
        return user
    }
}
