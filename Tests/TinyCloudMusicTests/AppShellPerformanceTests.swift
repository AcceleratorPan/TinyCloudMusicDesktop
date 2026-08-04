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
        let home = try slice(views, from: "private struct HomeView", to: "private struct HomeSectionView")
        let comment = try slice(comments, from: "struct CommentEmojiText", to: "#else")
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
