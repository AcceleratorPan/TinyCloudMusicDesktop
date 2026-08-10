import AVFoundation
import Observation

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
    private let audioSession = IOSAudioSessionCoordinator()
    private let isTesting: Bool
    private var credentialStartupError: String?
    private var audioStartupError: String?

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
                let validator = LiveMusicLibrary(
                    transport: EAPITransport(cookie: credentials.cookie, musicU: "")
                )
                guard case .loggedIn = try await validator.loginState() else { return false }
                return true
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
        audioSession.player = player
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
        await model.session?.restore()
        player.setAccountCredentialRevision(model.session?.credentialRevision ?? 0)
        if model.session != nil {
            await model.refreshAccountState { [model] in model.loadHome() }
        } else {
            model.loadHome()
        }
        updateStartupError()
        isStarting = false
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
}
