import AppKit
import SwiftUI

@main
enum TinyCloudMusicApp {
    @MainActor
    static func main() {
        ProcessInfo.processInfo.processName = "Tiny Cloud Music"
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.setActivationPolicy(.regular)
        application.delegate = delegate
        withExtendedLifetime(delegate) {
            application.run()
        }
    }
}

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private var nowPlayingWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var menuBarPlayer: MenuBarPlayerController?
    private var model: AppModel?
    private var credentialObserver: NSObjectProtocol?
    private var sleepObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?
    private var terminationConfirmed = false
    private var terminationTask: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu()

        let environment = ProcessInfo.processInfo.environment
        func credentialOverride(_ name: String) -> String? {
            guard let value = environment[name],
                  !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return nil }
            return value
        }
        let credentialStore = CredentialStore(service: CredentialStore.productionService)
        let transport = EAPITransport(
            cookie: credentialOverride("TINYCLOUDMUSIC_COOKIE"),
            musicU: credentialOverride("TINYCLOUDMUSIC_MUSIC_U"),
            loadStoredCredentials: { try? credentialStore.load() }
        )
        let repository = LiveMusicRepository(transport: transport)
        let library = LiveMusicLibrary(transport: transport)
        let videoLibrary = LiveVideoLibrary(transport: transport)
        let audioLibrary = LiveAudioContentLibrary(transport: transport)
        let knowledgeLibrary = LiveMusicKnowledgeLibrary(transport: transport)
        let extras = LiveMusicExtras(transport: transport)
        MusicSheetTemporaryFiles.cleanupExpired()
        let storedConcurrency = UserDefaults.standard.object(forKey: "downloadConcurrency") == nil
            ? 3
            : UserDefaults.standard.integer(forKey: "downloadConcurrency")
        let downloads = MusicDownloadManager(
            transport: transport,
            maximumConcurrentDownloads: storedConcurrency
        )
        let uploads = AudioUploadManager(
            musicLibrary: library,
            audioLibrary: audioLibrary
        )
        let session = SessionController(
            store: credentialStore,
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
        observeCredentialIssues(session)
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
        self.model = model
        ArtworkPipeline.shared.configure(cacheRoot: model.cacheFolderURL)
        let player = PlayerController(
            repository: repository,
            playbackQuality: model.settings.playbackQuality,
            cacheRoot: model.cacheFolderURL,
            crossfadeDuration: model.settings.crossfadeDuration
        )
        let listenTogether = ListenTogetherController(
            service: LiveListenTogetherService(transport: transport),
            player: player
        )
        model.listenTogether = listenTogether
        session.beforeLogout = { [weak listenTogether] in
            await listenTogether?.prepareForLogout()
        }
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak uploads, weak listenTogether] _ in
            Task { @MainActor in
                await uploads?.pauseAll()
                await listenTogether?.sleep()
            }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak listenTogether] _ in
            Task { @MainActor in listenTogether?.wake() }
        }
        model.personalFM = PersonalFMController(
            library: library,
            player: player,
            onTrashSucceeded: { [weak model] in model?.showToast("已减少这首歌的推荐") }
        )
        let rootView = RootView(model: model, player: player) { [weak self] in
            self?.openNowPlaying(model: model, player: player)
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_180, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "小云音乐"
        window.minSize = NSSize(width: 900, height: 600)
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: rootView)
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window
        menuBarPlayer = MenuBarPlayerController(model: model, player: player, window: window)

        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    private func openNowPlaying(model: AppModel, player: PlayerController) {
        if let nowPlayingWindow {
            nowPlayingWindow.deminiaturize(nil)
            nowPlayingWindow.makeKeyAndOrderFront(nil)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 940, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "正在播放"
        window.contentMinSize = NSSize(width: 780, height: 720)
        window.contentMaxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: 720)
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(
            rootView: NowPlayingDetailView(model: model, player: player) { [weak window] in
                window?.close()
            }
        )
        window.center()
        window.makeKeyAndOrderFront(nil)
        nowPlayingWindow = window
    }

    @objc private func openSettings(_ sender: Any?) {
        guard let model else { return }
        if let settingsWindow {
            settingsWindow.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate(ignoringOtherApps: true)
            return
        }
        if let session = model.session, session.state == .error {
            Task { await session.restore() }
        }

        let settingsWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        settingsWindow.title = "设置"
        settingsWindow.minSize = NSSize(width: 640, height: 560)
        settingsWindow.isReleasedWhenClosed = false
        settingsWindow.contentViewController = NSHostingController(rootView: SettingsView(model: model))
        settingsWindow.center()
        settingsWindow.makeKeyAndOrderFront(nil)
        self.settingsWindow = settingsWindow
    }

    private func observeCredentialIssues(_ session: SessionController) {
        credentialObserver = NotificationCenter.default.addObserver(
            forName: .neteaseCredentialIssue,
            object: nil,
            queue: .main
        ) { [weak self, weak session] notification in
            guard let value = notification.object as? String,
                  let issue = SessionCredentialIssue(rawValue: value)
            else { return }
            Task { @MainActor in
                guard let session, session.invalidate(issue) else { return }
                if issue == .cookie { await session.restore() }
                self?.presentCredentialAlert(issue)
            }
        }
    }

    private func presentCredentialAlert(_ issue: SessionCredentialIssue) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.addButton(withTitle: "好")
        switch issue {
        case .cookie:
            alert.messageText = "登录已失效"
            alert.informativeText = "扫码 Cookie 已失效，请重新登录。已验证的 MUSIC_U 不受影响。"
        case .musicU:
            alert.messageText = "VIP 凭据已失效"
            alert.informativeText = "MUSIC_U 已失效并被移除，相关请求将改用扫码 Cookie。"
        }
        alert.runModal()
    }

    private func installMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu(title: "小云音乐")
        let settingsItem = appMenu.addItem(
            withTitle: "设置…",
            action: #selector(openSettings(_:)),
            keyEquivalent: ","
        )
        settingsItem.target = self
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: "退出小云音乐",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        NSApplication.shared.mainMenu = mainMenu
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        window?.deminiaturize(nil)
        window?.makeKeyAndOrderFront(nil)
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard terminationTask == nil else { return .terminateLater }
        guard !terminationConfirmed else { return .terminateNow }
        guard confirmTermination() else { return .terminateCancel }
        terminationConfirmed = true

        let downloads = model?.downloads
        let uploads = model?.uploads
        let listenTogether = model?.listenTogether
        guard downloads?.runningDownloadCount ?? 0 > 0
                || downloads?.queuedDownloadCount ?? 0 > 0
                || uploads?.isActive == true
                || listenTogether?.requiresShutdown == true
        else { return .terminateNow }

        terminationTask = Task { [weak self] in
            await downloads?.pauseAll()
            await uploads?.pauseAll()
            await listenTogether?.shutdown()
            self?.terminationTask = nil
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    private func confirmTermination() -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "确定要退出小云音乐吗？"
        alert.informativeText = "当前播放将停止；未完成的下载和上传会保存已确认进度。"
        alert.addButton(withTitle: "退出")
        alert.addButton(withTitle: "取消")
        alert.buttons.first?.hasDestructiveAction = true
        return alert.runModal() == .alertFirstButtonReturn
    }
}

enum MenuBarMarquee {
    private static let speed: CGFloat = 28
    private static let delay: TimeInterval = 1.2

    static func duration(textWidth: CGFloat, viewportWidth: CGFloat, gap: CGFloat) -> TimeInterval? {
        guard textWidth > viewportWidth else { return nil }
        return TimeInterval((textWidth + gap) / speed)
    }

    static func offset(elapsed: TimeInterval, distance: CGFloat) -> CGFloat {
        guard elapsed > delay, distance > 0 else { return 0 }
        let traveled = CGFloat(elapsed - delay) * speed
        return -traveled.truncatingRemainder(dividingBy: distance)
    }
}

@MainActor
private final class MenuBarLyricView: NSView {
    private let label = NSTextField(labelWithString: "")
    private var marqueeTimer: Timer?
    private var marqueeStartedAt: TimeInterval = 0
    private var marqueeDistance: CGFloat = 0

    init(width: CGFloat) {
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: NSStatusBar.system.thickness))
        wantsLayer = true
        layer?.masksToBounds = true
        setAccessibilityRole(.staticText)
        setAccessibilityLabel("当前歌词")

        label.font = .menuBarFont(ofSize: 14)
        label.lineBreakMode = .byClipping
        label.maximumNumberOfLines = 1
        label.wantsLayer = true
        label.setAccessibilityElement(false)
        addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func show(_ text: String) {
        let font = label.font ?? .menuBarFont(ofSize: 0)
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        let displayedText = "♪  \(text)"
        let textWidth = ceil((displayedText as NSString).size(withAttributes: attributes).width)
        let gapText = "        "
        let gapWidth = ceil((gapText as NSString).size(withAttributes: attributes).width)
        marqueeTimer?.invalidate()
        marqueeTimer = nil
        toolTip = text
        setAccessibilityValue(text)

        guard MenuBarMarquee.duration(
            textWidth: textWidth,
            viewportWidth: bounds.width,
            gap: gapWidth
        ) != nil else {
            place(displayedText, width: bounds.width, alignment: .center)
            return
        }

        place(
            displayedText + gapText + displayedText,
            width: textWidth * 2 + gapWidth,
            alignment: .left
        )
        marqueeDistance = textWidth + gapWidth
        marqueeStartedAt = ProcessInfo.processInfo.systemUptime
        let timer = Timer(
            timeInterval: 1 / 30,
            target: self,
            selector: #selector(advanceMarquee),
            userInfo: nil,
            repeats: true
        )
        RunLoop.main.add(timer, forMode: .common)
        marqueeTimer = timer
    }

    @objc private func advanceMarquee() {
        label.frame.origin.x = MenuBarMarquee.offset(
            elapsed: ProcessInfo.processInfo.systemUptime - marqueeStartedAt,
            distance: marqueeDistance
        )
    }

    private func place(_ text: String, width: CGFloat, alignment: NSTextAlignment) {
        label.stringValue = text
        label.alignment = alignment
        label.frame = NSRect(x: 0, y: -2, width: width, height: bounds.height)
    }
}

@MainActor
private final class MenuBarPlayerController: NSObject {
    private let model: AppModel
    private let player: PlayerController
    private weak var window: NSWindow?
    private let statusItem = NSStatusBar.system.statusItem(withLength: 297)
    private let lyricView = MenuBarLyricView(width: 160)
    private let previousButton = NSButton()
    private let playbackButton = NSButton()
    private let nextButton = NSButton()
    private let favoriteButton = NSButton()
    private let downloadButton = NSButton()
    private let windowButton = NSButton()
    private var displayedText = ""

    init(model: AppModel, player: PlayerController, window: NSWindow) {
        self.model = model
        self.player = player
        self.window = window
        super.init()

        configureStatusItem()
        refresh()
        let timer = Timer(timeInterval: 0.3, target: self, selector: #selector(refresh), userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .common)
    }

    private func configureStatusItem() {
        guard let container = statusItem.button else { return }
        container.title = ""
        container.image = nil
        container.setAccessibilityRole(.group)
        container.setAccessibilityLabel("小云音乐菜单栏播放器")

        lyricView.translatesAutoresizingMaskIntoConstraints = false
        lyricView.widthAnchor.constraint(equalToConstant: 160).isActive = true
        lyricView.heightAnchor.constraint(equalToConstant: NSStatusBar.system.thickness).isActive = true

        configure(previousButton, action: #selector(previous))
        configure(playbackButton, action: #selector(togglePlayback))
        configure(nextButton, action: #selector(next))
        configure(favoriteButton, action: #selector(toggleFavorite))
        configure(downloadButton, action: #selector(download))
        configure(windowButton, action: #selector(showWindow))

        let controls = NSStackView(views: [
            lyricView,
            previousButton,
            playbackButton,
            nextButton,
            favoriteButton,
            downloadButton,
            windowButton
        ])
        controls.orientation = .horizontal
        controls.alignment = .centerY
        controls.spacing = 1
        controls.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(controls)
        container.setAccessibilityChildren([
            lyricView,
            previousButton,
            playbackButton,
            nextButton,
            favoriteButton,
            downloadButton,
            windowButton
        ])
        NSLayoutConstraint.activate([
            controls.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 4),
            controls.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -4),
            controls.centerYAnchor.constraint(equalTo: container.centerYAnchor)
        ])
    }

    private func configure(_ button: NSButton, action: Selector) {
        button.target = self
        button.action = action
        button.isBordered = false
        button.refusesFirstResponder = true
        button.focusRingType = .none
        button.imageScaling = .scaleProportionallyDown
        button.contentTintColor = nil
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 20),
            button.heightAnchor.constraint(equalToConstant: 22)
        ])
    }

    private func update(
        _ button: NSButton,
        symbol: String,
        label: String,
        enabled: Bool
    ) {
        if button.identifier?.rawValue != symbol {
            let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 14, weight: .regular))
            image?.isTemplate = true
            button.image = image
            button.identifier = NSUserInterfaceItemIdentifier(symbol)
        }
        if button.toolTip != label {
            button.toolTip = label
            button.setAccessibilityLabel(label)
        }
        if button.isEnabled != enabled { button.isEnabled = enabled }
    }

    private func updateDownloadButton(for song: Song?) {
        guard let song, let manager = model.downloads else {
            update(downloadButton, symbol: "arrow.down.circle", label: "下载", enabled: false)
            return
        }

        switch manager.states[song.id] {
        case .queued:
            update(downloadButton, symbol: "pause.circle", label: "暂停等待中的下载", enabled: true)
        case let .running(progress):
            let retryAttempt = manager.retryAttempts[song.id] ?? 0
            update(
                downloadButton,
                symbol: "arrow.down.circle.fill",
                label: retryAttempt > 0
                    ? "暂停下载，正在进行第 \(retryAttempt) 次断点重试"
                    : progress.map { "暂停下载，已完成 \(Int($0 * 100))%" } ?? "暂停下载，正在下载",
                enabled: true
            )
        case let .paused(progress):
            update(
                downloadButton,
                symbol: "play.circle",
                label: progress.map { "继续下载，已完成 \(Int($0 * 100))%" } ?? "继续下载",
                enabled: true
            )
        case .completed:
            update(
                downloadButton,
                symbol: "checkmark.circle.fill",
                label: "已下载",
                enabled: true
            )
        case let .failed(message):
            update(
                downloadButton,
                symbol: "exclamationmark.circle",
                label: "下载失败：\(message)",
                enabled: true
            )
        case .cancelled, .none:
            update(downloadButton, symbol: "arrow.down.circle", label: "下载", enabled: true)
        }
    }

    @objc private func refresh() {
        let text = player.currentLyric?.text ?? player.currentSong?.name ?? "小云音乐"
        if text != displayedText {
            displayedText = text
            lyricView.show(text)
        }

        let song = player.currentSong
        update(
            previousButton,
            symbol: "backward.end.fill",
            label: player.position > 3 ? "从头播放" : "上一首",
            enabled: player.canGoPrevious && !player.isControlInteractionLocked
        )
        update(
            playbackButton,
            symbol: player.isPlaybackRequested ? "pause.fill" : "play.fill",
            label: player.isPlaybackRequested ? "暂停" : "播放",
            enabled: song != nil && !player.isControlInteractionLocked
        )
        update(
            nextButton,
            symbol: "forward.end.fill",
            label: "下一首",
            enabled: player.canGoNext && !player.isControlInteractionLocked
        )
        let isLiked = song.map { model.likedSongIDs.contains($0.id) } ?? false
        let isPodcastEpisode = song?.isPodcastEpisode == true
        update(
            favoriteButton,
            symbol: isPodcastEpisode ? "heart.slash" : (isLiked ? "heart.fill" : "heart"),
            label: isPodcastEpisode ? "播客音频不支持收藏" : (isLiked ? "取消喜欢" : "喜欢"),
            enabled: song != nil && !isPodcastEpisode
        )
        updateDownloadButton(for: song)
        update(windowButton, symbol: "music.note.house.fill", label: "打开小云音乐", enabled: true)
    }

    @objc private func previous() { player.previous() }
    @objc private func togglePlayback() { player.togglePlayback() }
    @objc private func next() { player.next() }
    @objc private func toggleFavorite() {
        guard let song = player.currentSong, !song.isPodcastEpisode else { return }
        model.toggleSongLiked(song.id)
    }

    @objc private func download() {
        guard let song = player.currentSong, let manager = model.downloads else { return }
        switch manager.states[song.id] {
        case .queued, .running:
            manager.pause(songID: song.id)
        case .paused:
            manager.retry(songID: song.id)
        default:
            model.download(song)
        }
    }

    @objc private func showWindow() {
        window?.deminiaturize(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}
