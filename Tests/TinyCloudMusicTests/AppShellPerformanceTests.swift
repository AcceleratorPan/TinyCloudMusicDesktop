import AppKit
import Foundation
import SwiftUI
import Testing
@testable import TinyCloudMusic

private final class AppShellLockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() { lock.withLock { value += 1 } }
    var count: Int { lock.withLock { value } }
}

private struct AppShellBootstrapError: Error {}

@Suite("App shell performance", .serialized)
struct AppShellPerformanceTests {
    @MainActor
    @Test("Main menu exposes About and standard playback shortcuts")
    func mainMenuCommands() throws {
        let application = NSApplication.shared
        let previousMenu = application.mainMenu
        defer { application.mainMenu = previousMenu }

        let delegate = AppDelegate()
        delegate.installMainMenu()
        let mainMenu = try #require(application.mainMenu)
        let menus = mainMenu.items.compactMap(\.submenu)
        let appMenu = try #require(menus.first { $0.title == "小云音乐" })
        let playbackMenu = try #require(menus.first { $0.title == "播放控制" })
        #expect(appMenu.item(withTitle: "关于小云音乐") != nil)

        let expected: [(String, String, NSEvent.ModifierFlags)] = [
            ("播放/暂停", " ", []),
            ("上一首", "\u{F702}", [.command]),
            ("下一首", "\u{F703}", [.command]),
            ("快退 10 秒", "\u{F702}", [.command, .shift]),
            ("快进 10 秒", "\u{F703}", [.command, .shift]),
            ("增大音量", "\u{F700}", [.command]),
            ("减小音量", "\u{F701}", [.command]),
            ("静音/取消静音", "\u{F701}", [.command, .shift])
        ]
        for (title, key, modifiers) in expected {
            let item = try #require(playbackMenu.item(withTitle: title))
            #expect(item.keyEquivalent == key)
            #expect(item.keyEquivalentModifierMask == modifiers)
        }
    }

    @Test("Credential bootstrap owns one detached load and preserves read failure")
    func credentialBootstrap() async {
        let loadedCount = AppShellLockedCounter()
        let loaded = AppCredentialBootstrap.start {
            loadedCount.increment()
            return .guest
        }
        #expect(await loaded.value == .loaded(.guest))
        #expect(loadedCount.count == 1)

        let failedCount = AppShellLockedCounter()
        let failed = AppCredentialBootstrap.start {
            failedCount.increment()
            throw AppShellBootstrapError()
        }
        #expect(await failed.value == .failed)
        #expect(failedCount.count == 1)
    }

    @Test("Termination deadline denies timeout without cancelling durable cleanup")
    func terminationDeadline() async {
        let (events, continuation) = AsyncStream<Void>.makeStream()
        let cleanup = Task {
            for await _ in events { break }
        }

        #expect(await AppTerminationDeadline.wait(for: cleanup, timeout: .milliseconds(10)) == false)
        #expect(!cleanup.isCancelled)
        continuation.yield()
        continuation.finish()
        await cleanup.value

        let completed = Task {}
        #expect(await AppTerminationDeadline.wait(for: completed, timeout: .seconds(1)))
    }

    @Test("Typed history sequences coalesce without losing a newer event")
    func historyRefreshCoalescing() {
        var tracker = PlaybackHistoryRefreshTracker<RecentPlaybackKind>()
        let first = PlaybackHistoryEvent(sequence: 1, credentialRevision: 7, kind: .song)
        let second = PlaybackHistoryEvent(sequence: 2, credentialRevision: 7, kind: .song)

        let recordedFirst = tracker.record(first, credentialRevision: 7, keys: [.song])
        let recordedSecond = tracker.record(second, credentialRevision: 7, keys: [.song])
        #expect(recordedFirst)
        #expect(recordedSecond)
        #expect(tracker.pendingSequence(for: .song) == 2)
        let settledFirst = tracker.settle(.song, sequence: 1)
        #expect(!settledFirst)
        #expect(tracker.pendingSequence(for: .song) == 2)
        let settledSecond = tracker.settle(.song, sequence: 2)
        #expect(settledSecond)
        #expect(tracker.pendingSequence(for: .song) == nil)

        let wrongAccount = PlaybackHistoryEvent(sequence: 3, credentialRevision: 8, kind: .song)
        let recordedWrongAccount = tracker.record(wrongAccount, credentialRevision: 7, keys: [.song])
        #expect(!recordedWrongAccount)
        #expect(tracker.pendingSequence(for: .song) == nil)
    }

    @Test("Recent playback keeps loaded data for inactive kinds")
    func recentPlaybackStateRetention() {
        var state = RecentPlaybackState()
        state.reset(accountID: 42)
        let generation = state.generation
        let accepted = state.accept(
            .loaded(.songs([])),
            for: .song,
            generation: generation,
            accountID: 42
        )
        #expect(accepted)
        state.setLoading(.album)
        #expect(state.load(for: .song) == .loaded(.songs([])))
        #expect(state.load(for: .album) == .loading)

        state.reset(accountID: 42)
        let acceptedStale = state.accept(
            .loaded(.songs([])),
            for: .song,
            generation: generation,
            accountID: 42
        )
        #expect(!acceptedStale)
    }

    @Test("One hundred position ticks only cross the previous-button threshold once")
    func menuBarPositionThreshold() {
        var state = MenuBarPositionState()
        var semanticChanges = 0
        for tick in 0..<100 where state.update(position: Double(tick) / 10) {
            semanticChanges += 1
        }

        #expect(semanticChanges == 1)
        #expect(state.restartsCurrentSong)
        let reset = state.update(position: 0)
        #expect(reset)
        #expect(!state.restartsCurrentSong)
    }

    @Test("Cache revisions fan out one standardized root without duplicate pairs")
    func cacheConfigurationFanout() {
        let initial = CacheConfigurationSnapshot(
            playbackQuality: .standard,
            cacheRoot: URL(fileURLWithPath: "/tmp/cache/../cache-a"),
            revision: 0
        )
        var state = CacheConfigurationFanoutState(initial: initial)
        let unchanged = state.update(to: initial)
        #expect(!unchanged.configuresPlayer)
        #expect(!unchanged.configuresArtwork)

        let resolved = CacheConfigurationSnapshot(
            playbackQuality: .lossless,
            cacheRoot: URL(fileURLWithPath: "/tmp/cache-b/../cache-b"),
            revision: 1
        )
        let first = state.update(to: resolved)
        let duplicate = state.update(to: resolved)
        var playerConfigurations: [(AudioQuality, URL)] = []
        var artworkConfigurations: [URL] = []
        first.apply(
            configurePlayer: { playerConfigurations.append(($0, $1)) },
            configureArtwork: { artworkConfigurations.append($0) }
        )
        duplicate.apply(
            configurePlayer: { playerConfigurations.append(($0, $1)) },
            configureArtwork: { artworkConfigurations.append($0) }
        )
        #expect(first.snapshot.cacheRoot == resolved.cacheRoot.standardizedFileURL)
        #expect(first.configuresPlayer)
        #expect(first.configuresArtwork)
        #expect(!duplicate.configuresPlayer)
        #expect(!duplicate.configuresArtwork)
        #expect(playerConfigurations.count == 1)
        #expect(artworkConfigurations.count == 1)
        #expect(playerConfigurations[0].1 == artworkConfigurations[0])

        let qualityOnly = CacheConfigurationSnapshot(
            playbackQuality: .best,
            cacheRoot: resolved.cacheRoot,
            revision: resolved.revision
        )
        let qualityUpdate = state.update(to: qualityOnly)
        qualityUpdate.apply(
            configurePlayer: { playerConfigurations.append(($0, $1)) },
            configureArtwork: { artworkConfigurations.append($0) }
        )
        #expect(qualityUpdate.configuresPlayer)
        #expect(!qualityUpdate.configuresArtwork)
        #expect(playerConfigurations.count == 2)
        #expect(artworkConfigurations.count == 1)
    }

    @Test("Playlist feature writes consume the captured confirmed account tuple")
    func playlistMutationAccountFence() throws {
        let account = PlaylistMutationAccount(userID: 42, credentialRevision: 7)
        #expect(account.matches(userID: 42, confirmedRevision: 7, liveRevision: 7))
        #expect(!account.matches(userID: 43, confirmedRevision: 7, liveRevision: 7))
        #expect(!account.matches(userID: 42, confirmedRevision: 8, liveRevision: 7))
        #expect(!account.matches(userID: 42, confirmedRevision: 7, liveRevision: 8))

        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Sources/TinyCloudMusic")
        let views = try source("Views.swift", in: sourceRoot)
        let libraryViews = try source("LibraryFeatureViews.swift", in: sourceRoot)
        let detail = try slice(
            views,
            from: "private struct PlaylistDetailContent",
            to: "enum PlaylistDetailSection"
        )
        let metadata = try slice(
            views,
            from: "private struct PlaylistMetadataEditor",
            to: "private struct PlaylistCoverConfirmation"
        )
        let cover = try slice(
            views,
            from: "private struct PlaylistCoverConfirmation",
            to: "private struct PlaylistSongOrderEditor"
        )
        let order = try slice(
            views,
            from: "private struct PlaylistSongOrderEditor",
            to: "private struct UserDetailContent"
        )

        #expect(detail.contains("@State private var playlistMutationAccount: PlaylistMutationAccount?"))
        #expect(detail.contains(".onChange(of: model.confirmedAccountCredentialRevision)"))
        #expect(detail.contains("showingPrivacyConfirmation = false"))
        #expect(detail.components(separatedBy: "capturePlaylistMutationAccount(").count == 7)
        #expect(detail.components(separatedBy: "expectedCredentialRevision: account.credentialRevision").count == 2)
        #expect(metadata.components(separatedBy: "expectedCredentialRevision: account.credentialRevision").count == 4)
        #expect(cover.components(separatedBy: "expectedCredentialRevision: account.credentialRevision").count == 2)
        #expect(order.components(separatedBy: "expectedCredentialRevision: account.credentialRevision").count == 2)
        for editor in [metadata, cover, order] {
            #expect(editor.contains("account.matches(model: model, library: library)"))
            #expect(!editor.contains("let credentialRevision = library.transport.credentialSnapshotValue().revision"))
        }
        #expect(libraryViews.contains(
            "@State private var playlistDeleteRequest: (playlist: Playlist, account: PlaylistMutationAccount)?"
        ))
        #expect(libraryViews.contains("playlistDeleteRequest = (playlist, account)"))
        #expect(libraryViews.contains("deletePlaylist(request.playlist, account: request.account)"))
        #expect(libraryViews.contains(
            "@State private var deleteRequest: (comment: MusicComment, account: PlaylistMutationAccount)?"
        ))
        #expect(libraryViews.contains("deleteRequest = (target, account)"))
        #expect(libraryViews.contains("deleteComment(request.comment, account: request.account)"))
    }

    @MainActor
    @Test("Closing Now Playing releases its hosting controller and owner slot")
    func nowPlayingWindowRelease() async {
        let suiteName = "TinyCloudMusicTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let cacheRoot = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: cacheRoot) }
        let model = AppModel(repository: FixtureMusicRepository(), defaults: defaults)
        let player = PlayerController(
            repository: FixtureMusicRepository(),
            cacheRoot: cacheRoot,
            crossfadeDuration: 0
        )
        let delegate = AppDelegate()

        let nowPlaying = delegate.openNowPlaying(model: model, player: player)
        #expect(!nowPlaying.isReleasedWhenClosed)
        weak let nowPlayingHost = nowPlaying.contentViewController
        nowPlaying.close()
        #expect(await appShellEventually {
            nowPlaying.contentViewController == nil
                && nowPlayingHost == nil
                && !delegate.hasNowPlayingWindow
        })
    }

    @MainActor
    @Test("Closing Settings releases its hosting controller and owner slot")
    func settingsWindowRelease() async {
        let suiteName = "TinyCloudMusicTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let cacheRoot = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: cacheRoot) }
        let model = AppModel(repository: FixtureMusicRepository(), defaults: defaults)
        let player = PlayerController(
            repository: FixtureMusicRepository(),
            cacheRoot: cacheRoot,
            crossfadeDuration: 0
        )
        let delegate = AppDelegate()
        let settings = delegate.openSettings(model: model, player: player)
        #expect(!settings.isReleasedWhenClosed)
        weak let settingsHost = settings.contentViewController
        settings.close()
        #expect(await appShellEventually {
            settings.contentViewController == nil
                && settingsHost == nil
                && !delegate.hasSettingsWindow
        })
    }

    @MainActor
    @Test("Cached images cancel their active request when removed from the hosting tree")
    func cachedImageCancellation() async {
        AppShellImageProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AppShellImageProtocol.self]
        let cacheRoot = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let pipeline = ArtworkPipeline(sessionConfiguration: configuration, cacheRoot: cacheRoot)
        let hosting = NSHostingView(rootView: CachedAsyncImage(
            url: URL(string: "https://fixture.invalid/artwork.jpg"),
            pipeline: pipeline
        ) { _ in
            Color.clear
        })
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 80, height: 80),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.orderFrontRegardless()
        hosting.layoutSubtreeIfNeeded()

        #expect(await appShellEventually { AppShellImageProtocol.requestCount == 1 })
        window.contentView = NSView()
        #expect(await appShellEventually { AppShellImageProtocol.cancellationCount == 1 })
        window.close()
        pipeline.pipeline.invalidate()
    }

    @MainActor
    @Test("One crossfade slider drag persists exactly once")
    func crossfadeSliderCommit() throws {
        let suiteName = "TinyCloudMusicTests.\(UUID())"
        let defaults = try #require(AppShellCountingDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let cacheRoot = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: cacheRoot) }
        let model = AppModel(repository: FixtureMusicRepository(), defaults: defaults)
        let player = PlayerController(
            repository: FixtureMusicRepository(),
            cacheRoot: cacheRoot,
            crossfadeDuration: model.settings.crossfadeDuration
        )
        defaults.resetCrossfadeWrites()
        let initialValue = model.settings.crossfadeDuration
        let hosting = NSHostingView(rootView: SettingsView(model: model, player: player))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 680),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        hosting.layoutSubtreeIfNeeded()
        let slider = try #require(appShellSubview(NSSlider.self, in: hosting))

        appShellDrag(slider)

        #expect(model.settings.crossfadeDuration != initialValue)
        #expect(defaults.crossfadeWrites == 1)
        window.close()
        #expect(defaults.crossfadeWrites == 1)
    }

    @Test("Wave 1 mirrors account, detail, and iOS credential lifecycle contracts")
    func sessionNetworkIntegrationStructure() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sharedModel = try source(
            "AppModel.swift",
            in: repositoryRoot.appending(path: "Sources/TinyCloudMusic")
        )
        let iosModel = try source(
            "AppModel.swift",
            in: repositoryRoot.appending(path: "iOS/TinyCloudMusicIOS/SharedOverrides")
        )
        let container = try source(
            "IOSAppContainer.swift",
            in: repositoryRoot.appending(path: "iOS/TinyCloudMusicIOS/App")
        )
        let signature = """
        func refreshAccountState(
                confirmedAccount: ValidatedMusicLibraryAccount? = nil,
                whenAccountReady: @MainActor () -> Void = {}
            ) async
        """

        for model in [sharedModel, iosModel] {
            let accountRefresh = try slice(
                model,
                from: "func refreshAccountState(",
                to: "func showAddToPlaylist"
            )
            let detailRefresh = try slice(
                model,
                from: "func loadDetail(",
                to: "func playlistContentsDidChange"
            )
            #expect(model.contains(signature))
            #expect(accountRefresh.contains("confirmedAccount.credentialRevision == credentialRevision"))
            #expect(accountRefresh.contains("session?.credentialRevision == credentialRevision"))
            #expect(accountRefresh.contains("session?.state == .authenticated"))
            #expect(accountRefresh.components(separatedBy: "invalidateAllCachedResponses()").count == 3)
            #expect(detailRefresh.contains("forceRefresh: needsRefresh"))
            #expect(detailRefresh.contains("forceRefresh: true"))
            #expect(!detailRefresh.contains("refreshPlaylistDetail("))
        }

        #expect(sharedModel.contains("private(set) var cacheConfigurationRevision: UInt64 = 0"))
        #expect(sharedModel.contains("guard detailCache.count > 64"))
        #expect(sharedModel.contains("options: .withSecurityScope"))
        #expect(!sharedModel.contains("homeLoadRevision"))
        #expect(iosModel.contains("private(set) var homeLoadRevision = 0"))
        #expect(iosModel.contains("pendingHomeSectionIDs"))
        #expect(iosModel.contains("guard detailCache.count > 12"))
        #expect(iosModel.contains("options: []"))

        let start = try slice(container, from: "func start() async", to: "func retryAudioSession")
        #expect(container.components(separatedBy: "Self.validatedAccount(for: credentials)").count == 3)
        #expect(container.contains("nonisolated private static func validatedAccount("))
        #expect(start.contains("restore(accountValidator:"))
        #expect(start.contains("confirmedAccount: confirmedAccount"))
        #expect(start.range(of: "restore(accountValidator:")!.lowerBound
            < start.range(of: "refreshAccountState(")!.lowerBound)

        #expect(container.contains("private var credentialObserver: NSObjectProtocol?"))
        #expect(container.contains("forName: .neteaseCredentialIssue"))
        #expect(container.contains("queue: .main"))
        #expect(container.contains("notification.object as? SessionCredentialIssueEvent"))
        #expect(container.contains("guard let session, session.invalidate(event) else { return }"))
        #expect(container.contains("if event.issue == .cookie { await session.restore() }"))
        #expect(container.contains("isolated deinit"))
        #expect(container.contains("NotificationCenter.default.removeObserver(credentialObserver)"))
        #expect(!container.contains("Set<UInt64>"))
    }

    @Test("Account view leaves root as sole account refresh owner")
    func accountViewLeavesRootAsSoleRefreshOwner() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let iosUI = repositoryRoot.appending(path: "iOS/TinyCloudMusicIOS/UI")
        let account = try source(
            "IOSAccountView.swift",
            in: iosUI.appending(path: "LibraryMedia")
        )
        let root = try source("IOSRootView.swift", in: iosUI)
        let saveCookie = try slice(account, from: "private func saveCookie(", to: "private func refresh(")
        let refresh = try slice(account, from: "private func refresh(", to: "private func logout()")
        let logout = try slice(account, from: "private func logout()", to: "private func verifyMusicU(")
        let qrSuccess = try slice(account, from: "private func poll(_ key:", to: "private func cancel()")
        let phoneSuccess = try slice(account, from: "private func login()", to: "private func startCooldown()")
        let rootOwner = try slice(
            root,
            from: ".onChange(of: sessionIdentity)",
            to: ".onChange(of: model.path)"
        )
        let rootIdentity = try slice(
            root,
            from: "private var sessionIdentity:",
            to: "private var cacheConfiguration:"
        )

        #expect(!account.contains("sessionDidChange"))
        #expect(!account.contains("refreshAccountState"))
        #expect(!account.contains("setAccountCredentialRevision"))

        #expect(saveCookie.contains("let saved = await session.save(cookie: value)"))
        #expect(saveCookie.contains("isSavingCookie = false"))
        #expect(saveCookie.contains("model.showToast(\"登录成功\")"))
        #expect(saveCookie.contains("Cookie 未通过验证"))
        #expect(refresh.contains("defer { isRefreshing = false }"))
        #expect(refresh.contains("if try await session.refresh()"))
        #expect(refresh.contains("model.showToast(\"登录已刷新\")"))
        #expect(refresh.contains("message = error.localizedDescription"))
        #expect(logout.contains("let warning = await session.logout()"))
        #expect(logout.contains("isLoggingOut = false"))
        #expect(logout.contains("if let warning"))
        #expect(logout.contains("model.showToast(\"已退出登录\")"))
        #expect(qrSuccess.contains("onSuccess()"))
        #expect(qrSuccess.contains("dismiss()"))
        #expect(qrSuccess.contains("phase = .failed(error.localizedDescription)"))
        #expect(phoneSuccess.contains("defer {\n                isLoggingIn = false"))
        #expect(phoneSuccess.contains("guard await session.save(cookie: cookie)"))
        #expect(phoneSuccess.contains("onSuccess()"))
        #expect(phoneSuccess.contains("dismiss()"))
        #expect(phoneSuccess.contains("showError(error.localizedDescription"))

        #expect(rootIdentity.contains("state: $0.state"))
        #expect(rootIdentity.contains("credentialRevision: $0.credentialRevision"))
        #expect(rootOwner.contains("player.setAccountCredentialRevision(identity.credentialRevision)"))
        #expect(rootOwner.contains("model.invalidateAccountDomainIfNeeded"))
        #expect(rootOwner.contains("await model.refreshAccountState"))
    }

    @Test("iOS startup schedules one shared temporary cleanup only after normal readiness")
    func iosTemporaryCleanupStructure() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let container = try source(
            "IOSAppContainer.swift",
            in: repositoryRoot.appending(path: "iOS/TinyCloudMusicIOS/App")
        )
        let media = try source(
            "IOSMediaView.swift",
            in: repositoryRoot.appending(path: "iOS/TinyCloudMusicIOS/UI/LibraryMedia")
        )
        let start = try slice(container, from: "func start() async", to: "func retryAudioSession")
        let testing = try slice(start, from: "guard !isTesting else {", to: "do {")
        let maintenance = try #require(start.range(of: "Task.detached(priority: .utility)"))
        let normalReady = try #require(start.range(of: "isStarting = false", options: .backwards))
        let exportStore = try slice(
            media,
            from: "enum IOSExportFileStore",
            to: "private struct IOSPDFView"
        )

        #expect(testing.range(of: "isStarting = false")!.lowerBound
            < testing.range(of: "return")!.lowerBound)
        #expect(!testing.contains("cleanupExpired"))
        #expect(!testing.contains("IOSExportFileStore.directory"))
        #expect(normalReady.lowerBound < maintenance.lowerBound)
        #expect(!start[..<maintenance.lowerBound].contains("cleanupExpired"))
        #expect(start.components(separatedBy: "Task.detached(priority: .utility)").count == 2)
        #expect(start.components(separatedBy: "MusicSheetWorker.shared.cleanupExpired(").count == 2)
        #expect(start.contains("additionalRoots: [IOSExportFileStore.directory]"))

        #expect(!media.contains("private enum IOSExportFileStore"))
        #expect(exportStore.contains("static let directory = FileManager.default.temporaryDirectory"))
        #expect(exportStore.contains("let directory = Self.directory"))
        #expect(media.components(separatedBy: "TinyCloudMusicExports").count == 2)
    }

    @Test("iOS background checkpoint preserves resumable work")
    func iosBackgroundCheckpointStructure() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let appRoot = repositoryRoot.appending(path: "iOS/TinyCloudMusicIOS/App")
        let app = try source("TinyCloudMusicIOSApp.swift", in: appRoot)
        let container = try source("IOSAppContainer.swift", in: appRoot)
        let lifecycle = try slice(
            container,
            from: "func didEnterBackground()",
            to: "func start() async"
        )

        #expect(app.components(separatedBy: "@Environment(\\.scenePhase)").count == 2)
        #expect(app.components(separatedBy: ".onChange(of: scenePhase)").count == 2)
        #expect(app.contains("case .active:\n                container.didBecomeActive()"))
        #expect(app.contains("case .background:\n                container.didEnterBackground()"))
        #expect(app.contains("case .inactive:\n                break"))

        #expect(lifecycle.contains("guard backgroundCheckpointTask == nil else { return }"))
        #expect(lifecycle.components(separatedBy: "beginBackgroundTask(").count == 2)
        #expect(lifecycle.contains("expireBackgroundCheckpoint(checkpointID)"))
        #expect(lifecycle.contains("flushPersistence(timeout: .seconds(3))"))
        #expect(lifecycle.contains("flushEdits()"))
        #expect(lifecycle.contains("player.isPlaybackRequested == false"))
        #expect(lifecycle.contains("listenTogether?.sleep()"))
        #expect(lifecycle.contains("listenTogether.wake()"))
        #expect(lifecycle.contains("guard backgroundCheckpointID == checkpointID else { return }"))
        #expect(lifecycle.contains("backgroundCheckpointTask?.cancel()"))
        #expect(lifecycle.contains("UIApplication.shared.endBackgroundTask(backgroundTaskIdentifier)"))

        for forbidden in [
            "pauseAll()",
            "prepareForLogout()",
            "shutdown()",
            "setPlayback(false)",
            "setActive(false)"
        ] {
            #expect(!lifecycle.contains(forbidden))
        }
    }

    @Test("App shell uses event-driven and owner-managed lifecycle paths")
    func sourceStructure() throws {
        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Sources/TinyCloudMusic")
        let app = try source("TinyCloudMusicApp.swift", in: sourceRoot)
        let views = try source("Views.swift", in: sourceRoot)
        let images = try source("CachedAsyncImage.swift", in: sourceRoot)
        let comments = try source("CommentEmojiText.swift", in: sourceRoot)
        let model = try source("AppModel.swift", in: sourceRoot)
        let musicLibraryModels = try source("MusicLibraryModels.swift", in: sourceRoot)
        let library = try source("LibraryFeatureViews.swift", in: sourceRoot)
        let songPlaylists = try source("SongPlaylistViews.swift", in: sourceRoot)
        let home = try slice(views, from: "private struct HomeView", to: "private struct HomeSectionView")
        let comment = try slice(
            comments,
            from: "struct CommentEmojiText",
            to: "#else\n@main\nprivate enum CommentEmojiCheck"
        )
        let recent = try slice(library, from: "struct ListeningHistoryView", to: "private struct RecentMediaRow")
        let menuPosition = try slice(
            app,
            from: "private func observePositionChanges()",
            to: "private func observeLyricChanges()"
        )
        let menuControls = try slice(
            app,
            from: "private func refreshControls()",
            to: "private func updatePreviousButton()"
        )
        let menuLyric = try slice(
            app,
            from: "private func refreshLyric()",
            to: "private func refreshControls()"
        )
        let rootView = try slice(views, from: "struct RootView", to: "private struct PrimaryContentView")
        let rootTask = try slice(
            rootView,
            from: ".task {",
            to: ".onChange(of: sessionChangeIdentity)"
        )
        let sessionChange = try slice(
            rootView,
            from: ".onChange(of: sessionChangeIdentity)",
            to: ".onChange(of: listenTogetherPhase)"
        )
        let cacheCommit = try slice(
            model,
            from: "private func commitCacheFolder",
            to: "nonisolated private static func resolveFolder"
        )

        #expect(!app.contains("Timer("))
        #expect(app.contains("CABasicAnimation"))
        #expect(app.contains("accessibilityDisplayShouldReduceMotion"))
        #expect(!app.contains("contentMaxSize"))
        #expect(app.contains("window.contentViewController = nil"))
        #expect(app.contains("downloads?.persistenceError"))
        #expect(app.contains("uploads?.persistenceError"))
        #expect(app.contains("AppTerminationDeadline.wait(for: cleanup, timeout: .seconds(10))"))
        #expect(!app.contains("timeout: .seconds(35)"))
        #expect(app.contains("reply(toApplicationShouldTerminate: false)"))
        #expect(app.contains("listenTogether?.prepareForLogout()"))
        #expect(!app.contains("listenTogether?.shutdown()"))
        #expect(app.components(separatedBy: "listenTogether?.updateAccount(self?.model?.currentUserID)").count == 3)
        #expect(!app.contains("guard downloads?.runningDownloadCount"))
        #expect(app.contains("observePositionChanges()"))
        #expect(app.contains("observeLyricChanges()"))
        #expect(app.contains("observeControlChanges()"))
        #expect(app.contains("NSEvent.addLocalMonitorForEvents(matching: .keyDown)"))
        #expect(app.contains("menu.performKeyEquivalent(with: event.value)"))
        #expect(app.contains("NSApp.keyWindow?.firstResponder is NSTextView"))
        #expect(app.contains("statusItem.observe(\\.isVisible)"))
        #expect(app.contains("statusItemVisibilityObservation?.invalidate()"))
        #expect(menuPosition.contains("refreshPositionThreshold()"))
        #expect(!menuPosition.contains("refreshControls()"))
        #expect(!menuControls.contains("player.position"))
        #expect(menuLyric.contains("player.currentLyric"))
        #expect(menuLyric.contains("player.state"))
        #expect(menuLyric.contains("statusItem.isVisible"))
        #expect(menuControls.contains("player.isPlaybackRequested"))
        #expect(menuControls.contains("model.pendingMutations"))
        #expect(menuControls.contains("updateDownloadButton"))

        #expect(!views.contains("\"StreamCache\""))
        #expect(!views.contains("\"DownloadCache\""))
        #expect(views.contains("try await player.clearCache()"))
        #expect(views.contains("try await downloads.clearCache()"))
        #expect(views.contains("MusicSheetWorker.shared.clearCache"))
        #expect(views.contains("onEditingChanged: { if !$0 { commitCrossfade() } }"))
        #expect(home.contains("LazyVStack(alignment: .leading, spacing: 34)"))
        #expect(rootView.contains("cacheConfigurationRevision"))
        #expect(rootView.contains("onChange(of: cacheConfiguration, initial: true)"))
        #expect(!rootView.contains("model.settings.cacheBookmark"))
        #expect(rootTask.range(of: "guard !Task.isCancelled")!.lowerBound
            < rootTask.range(of: "isStarting = false")!.lowerBound)
        #expect(rootTask.range(of: "isStarting = false")!.lowerBound
            < rootTask.range(of: "await model.refreshAccountState()")!.lowerBound)
        #expect(sessionChange.range(of: "player.setAccountCredentialRevision")!.lowerBound
            < sessionChange.range(of: "model.invalidateAccountDomainIfNeeded")!.lowerBound)
        #expect(sessionChange.range(of: "model.invalidateAccountDomainIfNeeded")!.lowerBound
            < sessionChange.range(of: "Task {")!.lowerBound)
        #expect(cacheCommit.components(separatedBy: "downloadCacheConfigurator(root)").count == 2)
        #expect(cacheCommit.range(of: "downloadCacheConfigurator(root)")!.lowerBound
            < cacheCommit.range(of: "cacheConfigurationRevision &+= 1")!.lowerBound)
        #expect(musicLibraryModels.contains("mutating func reset(accountID: Int64?) {\n        generation &+= 1"))

        #expect(images.contains(".onDisappear(.cancel)"))
        #expect(images.contains("guard isVisible, url == retryURL"))
        #expect(images.contains("func clearCache() async"))

        #expect(comment.components(separatedBy: "CommentEmojiCatalog.parts(").count == 2)
        #expect(comment.contains(".task(id: parts)"))
        #expect(comment.contains("private func loadImages() async {\n        images = [:]"))
        #expect(comment.contains("for case let .emoji(token, url) in parts"))
        #expect(comment.contains("loadedImage.copy()"))

        #expect(model.contains("currentUserID != user.id || accountCredentialRevision != credentialRevision"))
        #expect(model.components(separatedBy: "personalFM?.setAccount(userID)").count == 2)

        #expect(recent.contains("playbackContent(selectedKind)"))
        #expect(recent.contains(".id(selectedKind)"))
        #expect(!recent.contains(".allowsHitTesting"))
        #expect(!recent.contains("playbackReportRevision"))
        #expect(!recent.contains("invalidateCachedResponses"))
        #expect(recent.components(separatedBy: "forceRefresh: forceRefresh").count == 7)
        #expect(!library.contains("lastPlaybackReportWasPodcast"))
        #expect(songPlaylists.contains("Button(\"重试\") { add(to: failedPlaylist) }"))
        #expect(songPlaylists.contains(".accessibilityLabel(\"关闭错误提示\")"))
    }

    private func source(_ name: String, in root: URL) throws -> String {
        try String(contentsOf: root.appending(path: name), encoding: .utf8)
    }

    private func slice(_ source: String, from start: String, to end: String) throws -> String {
        let lower = try #require(source.range(of: start)?.lowerBound)
        let upper = try #require(source.range(of: end, range: lower..<source.endIndex)?.lowerBound)
        return String(source[lower..<upper])
    }
}

private final class AppShellCountingDefaults: UserDefaults, @unchecked Sendable {
    private let counterLock = NSLock()
    private var storedCrossfadeWrites = 0

    var crossfadeWrites: Int { counterLock.withLock { storedCrossfadeWrites } }

    func resetCrossfadeWrites() {
        counterLock.withLock { storedCrossfadeWrites = 0 }
    }

    override func set(_ value: Any?, forKey defaultName: String) {
        if defaultName == "crossfadeDuration" {
            counterLock.withLock { storedCrossfadeWrites += 1 }
        }
        super.set(value, forKey: defaultName)
    }
}

private final class AppShellImageProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var requests = 0
    nonisolated(unsafe) private static var cancellations = 0

    static var requestCount: Int { lock.withLock { requests } }
    static var cancellationCount: Int { lock.withLock { cancellations } }

    static func reset() {
        lock.withLock {
            requests = 0
            cancellations = 0
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.withLock { Self.requests += 1 }
    }

    override func stopLoading() {
        Self.lock.withLock { Self.cancellations += 1 }
    }
}

@MainActor
private func appShellSubview<View: NSView>(_ type: View.Type, in root: NSView) -> View? {
    if let match = root as? View { return match }
    for child in root.subviews {
        if let match = appShellSubview(type, in: child) { return match }
    }
    return nil
}

@MainActor
private func appShellDrag(_ slider: NSSlider) {
    guard let target = slider.target, let action = slider.action else {
        Issue.record("Hosted Slider did not install its interaction coordinator")
        return
    }
    #expect(NSApp.sendAction(Selector(("userInteractionStarted:")), to: target, from: slider))
    slider.doubleValue = 0.6
    #expect(NSApp.sendAction(action, to: target, from: slider))
    slider.doubleValue = 0.8
    #expect(NSApp.sendAction(action, to: target, from: slider))
    #expect(NSApp.sendAction(Selector(("userInteractionEnded:")), to: target, from: slider))
}

@MainActor
private func appShellEventually(_ condition: @escaping @MainActor () -> Bool) async -> Bool {
    for _ in 0..<200 {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return false
}
