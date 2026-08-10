import AppKit
import Observation
import QuartzCore
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

enum AppCredentialBootstrapResult: Equatable, Sendable {
    case loaded(CredentialSnapshotState)
    case failed
}

enum AppCredentialBootstrap {
    static func start(
        load: @escaping @Sendable () throws -> CredentialSnapshotState
    ) -> Task<AppCredentialBootstrapResult, Never> {
        Task.detached(priority: .userInitiated) {
            do {
                return .loaded(try load())
            } catch {
                return .failed
            }
        }
    }
}

enum AppTerminationDeadline {
    static func wait(for cleanup: Task<Void, Never>, timeout: Duration) async -> Bool {
        let (events, continuation) = AsyncStream<Bool>.makeStream(bufferingPolicy: .bufferingOldest(1))
        let completion = Task {
            await cleanup.value
            continuation.yield(true)
        }
        let deadline = Task {
            do {
                try await Task.sleep(for: timeout)
                continuation.yield(false)
            } catch {}
        }
        for await completed in events {
            completion.cancel()
            deadline.cancel()
            continuation.finish()
            return completed
        }
        return false
    }
}

@MainActor
private final class PlaybackMainMenu: NSMenu {
    var playbackMenu: NSMenu? {
        items.lazy.compactMap(\.submenu).first { $0.title == "播放控制" }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .function, .numericPad])
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        let commandShortcutKeys = ["\u{F700}", "\u{F701}", "\u{F702}", "\u{F703}"]
        let shiftedCommandShortcutKeys = ["\u{F701}", "\u{F702}", "\u{F703}"]
        let isPlaybackShortcut = (key == " " && modifiers.isEmpty)
            || (modifiers == [.command] && commandShortcutKeys.contains(key))
            || (modifiers == [.command, .shift] && shiftedCommandShortcutKeys.contains(key))
        let isEditingText = MainActor.assumeIsolated {
            NSApp.keyWindow?.firstResponder is NSTextView
        }
        if isEditingText, isPlaybackShortcut {
            return false
        }
        return super.performKeyEquivalent(with: event)
    }
}

private struct MainThreadKeyEvent: @unchecked Sendable {
    let value: NSEvent
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuItemValidation {
    private var window: NSWindow?
    private var nowPlayingWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var menuBarPlayer: MenuBarPlayerController?
    private var model: AppModel?
    private var player: PlayerController?
    private var credentialObserver: NSObjectProtocol?
    private var sleepObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?
    private var playbackKeyMonitor: Any?
    private var credentialBootstrapTask: Task<AppCredentialBootstrapResult, Never>?
    private var sheetCleanupTask: Task<Void, Never>?
    private var terminationConfirmed = false
    private var terminationTask: Task<Void, Never>?
    private var terminationCleanupTask: Task<Void, Never>?

    var hasNowPlayingWindow: Bool { nowPlayingWindow != nil }
    var hasSettingsWindow: Bool { settingsWindow != nil }

    isolated deinit {
        if let playbackKeyMonitor { NSEvent.removeMonitor(playbackKeyMonitor) }
    }

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
        let cookieOverride = credentialOverride("TINYCLOUDMUSIC_COOKIE")
        let musicUOverride = credentialOverride("TINYCLOUDMUSIC_MUSIC_U")
        let credentialSnapshot = CredentialSnapshot()
        credentialBootstrapTask = AppCredentialBootstrap.start {
            try credentialStore.loadSnapshotState()
        }
        let transport = EAPITransport(
            cookie: cookieOverride,
            musicU: musicUOverride,
            credentialSnapshot: credentialSnapshot
        )
        let repository = LiveMusicRepository(transport: transport)
        let library = LiveMusicLibrary(transport: transport)
        let videoLibrary = LiveVideoLibrary(transport: transport)
        let audioLibrary = LiveAudioContentLibrary(transport: transport)
        let knowledgeLibrary = LiveMusicKnowledgeLibrary(transport: transport)
        let extras = LiveMusicExtras(transport: transport)
        sheetCleanupTask = Task { [weak self] in
            await MusicSheetWorker.shared.cleanupExpired()
            self?.sheetCleanupTask = nil
        }
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
        let initialCacheConfiguration = CacheConfigurationSnapshot(
            playbackQuality: model.settings.playbackQuality,
            cacheRoot: model.cacheFolderURL,
            revision: model.cacheConfigurationRevision
        )
        ArtworkPipeline.shared.configure(cacheRoot: initialCacheConfiguration.cacheRoot)
        let player = PlayerController(
            repository: repository,
            playbackQuality: initialCacheConfiguration.playbackQuality,
            cacheRoot: initialCacheConfiguration.cacheRoot,
            crossfadeDuration: model.settings.crossfadeDuration,
            playbackControlFadeEnabled: model.settings.playbackControlFadeEnabled
        )
        self.player = player
        installPlaybackKeyMonitor()
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
        let rootView = RootView(
            model: model,
            player: player,
            initialCacheConfiguration: initialCacheConfiguration,
            openNowPlaying: { [weak self] in
                self?.openNowPlaying(model: model, player: player)
            },
            start: { [weak self, weak session, weak player] in
                guard let self, let session, let player else { return false }
                return await self.finishCredentialBootstrap(
                    credentialSnapshot,
                    session: session,
                    player: player
                )
            }
        )

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_416, height: 912),
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

    private func finishCredentialBootstrap(
        _ snapshot: CredentialSnapshot,
        session: SessionController,
        player: PlayerController
    ) async -> Bool {
        if let task = credentialBootstrapTask {
            credentialBootstrapTask = nil
            if case let .loaded(state) = await task.value {
                snapshot.store(state)
            }
        }
        await session.restore()
        player.setAccountCredentialRevision(session.credentialRevision)
        if case .unavailable = snapshot.load().state { return false }
        return true
    }

    @discardableResult
    func openNowPlaying(model: AppModel, player: PlayerController) -> NSWindow {
        if let nowPlayingWindow {
            nowPlayingWindow.deminiaturize(nil)
            nowPlayingWindow.makeKeyAndOrderFront(nil)
            return nowPlayingWindow
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 940, height: 720),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "正在播放"
        window.contentMinSize = NSSize(width: 780, height: 720)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentViewController = NSHostingController(
            rootView: NowPlayingDetailView(model: model, player: player) { [weak window] in
                window?.close()
            }
        )
        window.center()
        window.makeKeyAndOrderFront(nil)
        nowPlayingWindow = window
        return window
    }

    @objc private func openSettings(_ sender: Any?) {
        guard let model, let player else { return }
        openSettings(model: model, player: player)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    @objc private func openAbout(_ sender: Any?) {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "开发版"
        let credits = NSMutableAttributedString(
            string: "由 AcceleratorPan 倾情复刻\n2026 Summer\nGitHub"
        )
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        credits.addAttribute(
            .paragraphStyle,
            value: paragraph,
            range: NSRange(location: 0, length: credits.length)
        )
        credits.addAttribute(
            .link,
            value: URL(string: "https://github.com/AcceleratorPan/TinyCloudMusicDesktop")!,
            range: (credits.string as NSString).range(of: "GitHub")
        )
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "小云音乐",
            .applicationVersion: version,
            .credits: credits
        ])
    }

    @objc private func togglePlayback(_ sender: Any?) { player?.togglePlayback() }
    @objc private func previousTrack(_ sender: Any?) { player?.previous() }
    @objc private func nextTrack(_ sender: Any?) { player?.next() }
    @objc private func seekBackward(_ sender: Any?) {
        if let player { player.seek(to: player.position - 10) }
    }

    @objc private func seekForward(_ sender: Any?) {
        if let player { player.seek(to: player.position + 10) }
    }

    @objc private func volumeUp(_ sender: Any?) {
        if let player { player.volume = min(1, player.volume + 0.1) }
    }

    @objc private func volumeDown(_ sender: Any?) {
        if let player { player.volume = max(0, player.volume - 0.1) }
    }

    @objc private func toggleMute(_ sender: Any?) { player?.toggleMute() }

    private func installPlaybackKeyMonitor() {
        playbackKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let event = MainThreadKeyEvent(value: event)
            let handled = MainActor.assumeIsolated {
                guard !(NSApp.keyWindow?.firstResponder is NSTextView),
                      let menu = (NSApp.mainMenu as? PlaybackMainMenu)?.playbackMenu
                else { return false }
                menu.update()
                return menu.performKeyEquivalent(with: event.value)
            }
            return handled ? nil : event.value
        }
    }

    @discardableResult
    func openSettings(model: AppModel, player: PlayerController) -> NSWindow {
        if let settingsWindow {
            settingsWindow.makeKeyAndOrderFront(nil)
            return settingsWindow
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
        settingsWindow.delegate = self
        settingsWindow.contentViewController = NSHostingController(
            rootView: SettingsView(model: model, player: player)
        )
        settingsWindow.center()
        settingsWindow.makeKeyAndOrderFront(nil)
        self.settingsWindow = settingsWindow
        return settingsWindow
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if window === nowPlayingWindow {
            window.contentViewController = nil
            nowPlayingWindow = nil
        } else if window === settingsWindow {
            window.contentViewController = nil
            settingsWindow = nil
        }
    }

    private func observeCredentialIssues(_ session: SessionController) {
        credentialObserver = NotificationCenter.default.addObserver(
            forName: .neteaseCredentialIssue,
            object: nil,
            queue: .main
        ) { [weak self, weak session] notification in
            guard let event = notification.object as? SessionCredentialIssueEvent else { return }
            Task { @MainActor in
                guard let session, session.invalidate(event) else { return }
                if event.issue == .cookie { await session.restore() }
                self?.presentCredentialAlert(event.issue)
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

    func installMainMenu() {
        let mainMenu = PlaybackMainMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu(title: "小云音乐")
        let aboutItem = appMenu.addItem(
            withTitle: "关于小云音乐",
            action: #selector(openAbout(_:)),
            keyEquivalent: ""
        )
        aboutItem.target = self
        appMenu.addItem(.separator())
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

        let playbackMenuItem = NSMenuItem()
        let playbackMenu = NSMenu(title: "播放控制")
        func addPlaybackItem(
            _ title: String,
            action: Selector,
            keyEquivalent: String,
            modifiers: NSEvent.ModifierFlags = [.command]
        ) {
            let item = playbackMenu.addItem(
                withTitle: title,
                action: action,
                keyEquivalent: keyEquivalent
            )
            item.keyEquivalentModifierMask = modifiers
            item.target = self
        }
        addPlaybackItem("播放/暂停", action: #selector(togglePlayback(_:)), keyEquivalent: " ", modifiers: [])
        playbackMenu.addItem(.separator())
        addPlaybackItem("上一首", action: #selector(previousTrack(_:)), keyEquivalent: "\u{F702}")
        addPlaybackItem("下一首", action: #selector(nextTrack(_:)), keyEquivalent: "\u{F703}")
        addPlaybackItem(
            "快退 10 秒",
            action: #selector(seekBackward(_:)),
            keyEquivalent: "\u{F702}",
            modifiers: [.command, .shift]
        )
        addPlaybackItem(
            "快进 10 秒",
            action: #selector(seekForward(_:)),
            keyEquivalent: "\u{F703}",
            modifiers: [.command, .shift]
        )
        playbackMenu.addItem(.separator())
        addPlaybackItem("增大音量", action: #selector(volumeUp(_:)), keyEquivalent: "\u{F700}")
        addPlaybackItem("减小音量", action: #selector(volumeDown(_:)), keyEquivalent: "\u{F701}")
        addPlaybackItem(
            "静音/取消静音",
            action: #selector(toggleMute(_:)),
            keyEquivalent: "\u{F701}",
            modifiers: [.command, .shift]
        )
        playbackMenuItem.submenu = playbackMenu
        mainMenu.addItem(playbackMenuItem)

        NSApplication.shared.mainMenu = mainMenu
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard let action = menuItem.action else { return true }
        if action == #selector(togglePlayback(_:)) {
            menuItem.title = player?.isPlaying == true ? "暂停" : "播放"
            return player?.currentSong != nil
        }
        if action == #selector(previousTrack(_:)) { return player?.canGoPrevious == true }
        if action == #selector(nextTrack(_:)) { return player?.canGoNext == true }
        if action == #selector(seekBackward(_:)) || action == #selector(seekForward(_:)) {
            return player?.currentSong != nil
        }
        return true
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

        if terminationCleanupTask == nil {
            terminationCleanupTask = Task { @MainActor [weak self] in
                async let downloadCleanup: Void? = downloads?.pauseAll()
                async let uploadCleanup: Void? = uploads?.pauseAll()
                async let listenTogetherCleanup: Void? = listenTogether?.prepareForLogout()
                _ = await (downloadCleanup, uploadCleanup, listenTogetherCleanup)
                self?.terminationCleanupTask = nil
            }
        }
        let cleanup = terminationCleanupTask!
        terminationTask = Task { @MainActor [weak self] in
            let completed = await AppTerminationDeadline.wait(for: cleanup, timeout: .seconds(10))
            self?.terminationTask = nil
            guard completed else {
                self?.terminationConfirmed = false
                listenTogether?.updateAccount(self?.model?.currentUserID)
                self?.presentPersistenceFailure(["退出清理在 10 秒内未完成，已取消退出；进度保存仍在继续。"])
                sender.reply(toApplicationShouldTerminate: false)
                return
            }
            let failures = [downloads?.persistenceError, uploads?.persistenceError].compactMap { $0 }
            guard failures.isEmpty else {
                self?.terminationConfirmed = false
                listenTogether?.updateAccount(self?.model?.currentUserID)
                self?.presentPersistenceFailure(failures)
                sender.reply(toApplicationShouldTerminate: false)
                return
            }
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

    private func presentPersistenceFailure(_ failures: [String]) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "无法安全退出"
        alert.informativeText = "下载或上传进度尚未保存：\n" + failures.joined(separator: "\n")
        alert.addButton(withTitle: "返回应用")
        alert.runModal()
    }
}

enum MenuBarMarquee {
    private static let speed: CGFloat = 28
    static let delay: TimeInterval = 1.2

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
    private var currentText = ""
    private var wantsAnimation = false
    private var viewportWidth: CGFloat = 0

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

    override func layout() {
        super.layout()
        guard bounds.width != viewportWidth else { return }
        show(currentText, animate: wantsAnimation)
    }

    func show(_ text: String, animate: Bool) {
        guard text != currentText || animate != wantsAnimation || bounds.width != viewportWidth else { return }
        currentText = text
        wantsAnimation = animate
        viewportWidth = bounds.width
        let font = label.font ?? .menuBarFont(ofSize: 0)
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        let displayedText = "♪  \(text)"
        let textWidth = ceil((displayedText as NSString).size(withAttributes: attributes).width)
        let gapText = "        "
        let gapWidth = ceil((gapText as NSString).size(withAttributes: attributes).width)
        label.layer?.removeAnimation(forKey: "menu-bar-marquee")
        toolTip = text
        setAccessibilityValue(text)

        guard animate, let duration = MenuBarMarquee.duration(
            textWidth: textWidth,
            viewportWidth: bounds.width,
            gap: gapWidth
        ) else {
            place(displayedText, width: bounds.width, alignment: .center)
            return
        }

        place(
            displayedText + gapText + displayedText,
            width: textWidth * 2 + gapWidth,
            alignment: .left
        )
        let animation = CABasicAnimation(keyPath: "transform.translation.x")
        animation.fromValue = 0
        animation.toValue = -(textWidth + gapWidth)
        animation.beginTime = CACurrentMediaTime() + MenuBarMarquee.delay
        animation.duration = duration
        animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(name: .linear)
        animation.fillMode = .backwards
        label.layer?.add(animation, forKey: "menu-bar-marquee")
    }

    func stop() {
        label.layer?.removeAnimation(forKey: "menu-bar-marquee")
    }

    private func place(_ text: String, width: CGFloat, alignment: NSTextAlignment) {
        label.stringValue = text
        label.alignment = alignment
        label.frame = NSRect(x: 0, y: -2, width: width, height: bounds.height)
    }
}

struct MenuBarPositionState {
    private(set) var restartsCurrentSong = false

    mutating func update(position: TimeInterval) -> Bool {
        let next = position > 3
        guard next != restartsCurrentSong else { return false }
        restartsCurrentSong = next
        return true
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
    private var displayOptionsObserver: NSObjectProtocol?
    private var statusItemVisibilityObservation: NSKeyValueObservation?
    private var positionState = MenuBarPositionState()

    init(model: AppModel, player: PlayerController, window: NSWindow) {
        self.model = model
        self.player = player
        self.window = window
        super.init()

        configureStatusItem()
        observePositionChanges()
        observeLyricChanges()
        observeControlChanges()
        statusItemVisibilityObservation = statusItem.observe(\.isVisible) { [weak self] _, _ in
            Task { @MainActor in self?.refreshLyric() }
        }
        displayOptionsObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshLyric() }
        }
    }

    isolated deinit {
        if let displayOptionsObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(displayOptionsObserver)
        }
        statusItemVisibilityObservation?.invalidate()
        lyricView.stop()
        NSStatusBar.system.removeStatusItem(statusItem)
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

    private func observePositionChanges() {
        withObservationTracking {
            refreshPositionThreshold()
        } onChange: { [weak self] in
            Task { @MainActor in self?.observePositionChanges() }
        }
    }

    private func observeLyricChanges() {
        withObservationTracking {
            refreshLyric()
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeLyricChanges() }
        }
    }

    private func observeControlChanges() {
        withObservationTracking {
            refreshControls()
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeControlChanges() }
        }
    }

    private func refreshPositionThreshold() {
        guard positionState.update(position: player.position) else { return }
        update(
            previousButton,
            symbol: "backward.end.fill",
            label: positionState.restartsCurrentSong ? "从头播放" : "上一首",
            enabled: previousButton.isEnabled
        )
    }

    private func refreshLyric() {
        let text = player.currentLyric?.text ?? player.currentSong?.name ?? "小云音乐"
        let isPlaying = if case .playing = player.state { true } else { false }
        lyricView.show(
            text,
            animate: isPlaying
                && statusItem.isVisible
                && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        )
    }

    private func refreshControls() {
        let song = player.currentSong
        updatePreviousButton()
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
        let isLikePending = song.map { model.pendingMutations.contains(.songLike($0.id)) } ?? false
        update(
            favoriteButton,
            symbol: isPodcastEpisode ? "heart.slash" : (isLiked ? "heart.fill" : "heart"),
            label: isPodcastEpisode
                ? "播客音频不支持收藏"
                : (isLikePending ? "正在更新喜欢状态" : (isLiked ? "取消喜欢" : "喜欢")),
            enabled: song != nil && !isPodcastEpisode && !isLikePending
        )
        updateDownloadButton(for: song)
        update(windowButton, symbol: "music.note.house.fill", label: "打开小云音乐", enabled: true)
    }

    private func updatePreviousButton() {
        update(
            previousButton,
            symbol: "backward.end.fill",
            label: positionState.restartsCurrentSong ? "从头播放" : "上一首",
            enabled: player.canGoPrevious && !player.isControlInteractionLocked
        )
    }

    private func refreshAfterControlAction() {
        refreshPositionThreshold()
        refreshLyric()
        refreshControls()
    }

    @objc private func previous() { player.previous(); refreshAfterControlAction() }
    @objc private func togglePlayback() { player.togglePlayback(); refreshAfterControlAction() }
    @objc private func next() { player.next(); refreshAfterControlAction() }
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
