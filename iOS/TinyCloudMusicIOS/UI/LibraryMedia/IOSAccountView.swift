import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI
import UniformTypeIdentifiers
import UIKit
@preconcurrency import WebKit

struct IOSAccountView: View {
    @Bindable private var model: AppModel
    @Bindable private var player: PlayerController
    @State private var showsQRLogin = false
    @State private var showsWebLogin = false
    @State private var cookie = ""
    @State private var musicU = ""
    @State private var isSavingCookie = false
    @State private var isVerifyingMusicU = false
    @State private var isRefreshing = false
    @State private var isLoggingOut = false
    @State private var confirmsLogout = false
    @State private var selectedFolder: IOSFolderKind?
    @State private var crossfadeDraft: TimeInterval?
    @State private var isClearingCache = false
    @State private var confirmsCacheClear = false
    @State private var message: String?

    init(container: IOSAppContainer) {
        model = container.model
        player = container.player
    }

    var body: some View {
        Form {
            accountHeader
            sessionSection
            playbackSection
            downloadSection
            storageSection
            homeSection
            uploadSection
            advancedSection
        }
        .navigationTitle("我的")
        .navigationBarTitleDisplayMode(.large)
        .tint(.red)
        .sheet(isPresented: $showsQRLogin) {
            if let session = model.session {
                IOSQRLoginView(session: session, onSuccess: sessionDidChange)
            }
        }
        .sheet(isPresented: $showsWebLogin) {
            if let session = model.session {
                IOSWebLoginView(session: session, onSuccess: sessionDidChange)
            }
        }
        .fileImporter(
            isPresented: Binding(
                get: { selectedFolder != nil },
                set: { if !$0 { selectedFolder = nil } }
            ),
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            handleFolderSelection(result)
        }
        .confirmationDialog("确定退出登录？", isPresented: $confirmsLogout) {
            Button("退出登录", role: .destructive) { logout() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("本地登录 Cookie 将被清除；单独验证的 MUSIC_U 保持不变。")
        }
        .confirmationDialog("清除缓存？", isPresented: $confirmsCacheClear) {
            Button("清除", role: .destructive) { clearCache() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("会清除播放、下载、封面和乐谱缓存，不会删除已下载的媒体文件。")
        }
        .alert("提示", isPresented: Binding(
            get: { message != nil || model.settingsMessage != nil },
            set: {
                if !$0 {
                    message = nil
                    model.settingsMessage = nil
                }
            }
        )) {
            Button("好") {
                message = nil
                model.settingsMessage = nil
            }
        } message: {
            Text(message ?? model.settingsMessage ?? "")
        }
        .onDisappear { commitCrossfade() }
    }

    @ViewBuilder
    private var accountHeader: some View {
        if let snapshot = model.librarySnapshot {
            Section {
                HStack(spacing: 14) {
                    IOSRemoteArtwork(url: snapshot.user.avatarURL, symbol: "person.crop.circle.fill", circular: true)
                        .frame(width: 64, height: 64)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(snapshot.user.nickname).font(.title3.weight(.semibold))
                        Text("Level \(snapshot.user.level) · \(snapshot.user.followerCount.formatted()) 位关注者")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                NavigationLink(value: Route.user(snapshot.user.id)) {
                    Label("查看个人主页", systemImage: "person.crop.circle")
                }
            }
        }
    }

    @ViewBuilder
    private var sessionSection: some View {
        if let session = model.session {
            Section("账号") {
                Label(sessionStateTitle(session.state), systemImage: sessionStateSymbol(session.state))
                    .foregroundStyle(session.state == .invalid || session.state == .error ? .red : .primary)

                if session.state != .authenticated {
                    Button { showsQRLogin = true } label: {
                        Label("二维码登录", systemImage: "qrcode")
                    }
                    Button { showsWebLogin = true } label: {
                        Label("官方网页登录", systemImage: "safari")
                    }
                    SecureField("Cookie", text: $cookie)
                        .textContentType(.password)
                        .privacySensitive()
                    Button { saveCookie(session) } label: {
                        if isSavingCookie { HStack { ProgressView(); Text("正在验证") } }
                        else { Label("验证并保存 Cookie", systemImage: "checkmark.shield") }
                    }
                    .disabled(isSavingCookie || cookie.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                } else {
                    Button { refresh(session) } label: {
                        if isRefreshing { HStack { ProgressView(); Text("正在刷新") } }
                        else { Label("刷新登录", systemImage: "arrow.clockwise") }
                    }
                    .disabled(isRefreshing || isLoggingOut)
                    Button(role: .destructive) { confirmsLogout = true } label: {
                        if isLoggingOut { HStack { ProgressView(); Text("正在退出") } }
                        else { Label("退出登录", systemImage: "rectangle.portrait.and.arrow.right") }
                    }
                    .disabled(isRefreshing || isLoggingOut)
                }
            }
        }
    }

    private var playbackSection: some View {
        Section("播放") {
            Picker("外观", selection: Binding(
                get: { model.settings.appearance },
                set: { model.setAppearance($0) }
            )) {
                ForEach(Appearance.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)

            Picker("音乐播放音质", selection: Binding(
                get: { model.settings.playbackQuality },
                set: { model.setPlaybackQuality($0) }
            )) {
                ForEach(AudioQuality.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }

            Picker("视频播放清晰度", selection: Binding(
                get: { model.settings.videoPlaybackQuality },
                set: { model.setVideoPlaybackQuality($0) }
            )) {
                ForEach(VideoQuality.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }

            VStack(alignment: .leading, spacing: 8) {
                LabeledContent("歌曲过渡", value: displayedCrossfade == 0 ? "关闭" : "\(Int(displayedCrossfade)) 秒")
                Slider(value: Binding(
                    get: { displayedCrossfade },
                    set: {
                        crossfadeDraft = $0
                        player.setCrossfadeDuration($0)
                    }
                ), in: 0...12, step: 1) { editing in
                    if !editing { commitCrossfade() }
                }
                .accessibilityValue(displayedCrossfade == 0 ? "关闭" : "\(Int(displayedCrossfade)) 秒")
            }
        }
    }

    private var downloadSection: some View {
        Section("下载") {
            Picker("音乐下载音质", selection: Binding(
                get: { model.settings.quality },
                set: { model.setQuality($0) }
            )) {
                ForEach(AudioQuality.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            Picker("视频下载清晰度", selection: Binding(
                get: { model.settings.videoDownloadQuality },
                set: { model.setVideoDownloadQuality($0) }
            )) {
                ForEach(VideoQuality.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            Stepper(
                "同时下载 \(model.settings.downloadConcurrency) 个任务",
                value: Binding(
                    get: { model.settings.downloadConcurrency },
                    set: { model.setDownloadConcurrency($0) }
                ),
                in: 1...5
            )
            if let downloads = model.downloads {
                NavigationLink { IOSDownloadsView(manager: downloads) } label: {
                    Label("下载任务", systemImage: "arrow.down.circle")
                }
            }
        }
    }

    private var storageSection: some View {
        Section("存储位置") {
            folderRow("音乐下载", path: model.downloadPath, kind: .audio)
            folderRow("视频下载", path: model.videoDownloadPath, kind: .video)
            folderRow("图片保存", path: model.imagePath, kind: .image)
            folderRow("乐谱保存", path: model.sheetPath, kind: .sheet)
            folderRow("缓存", path: model.cachePath, kind: .cache)
            Button(role: .destructive) { confirmsCacheClear = true } label: {
                if isClearingCache { HStack { ProgressView(); Text("正在清除缓存") } }
                else { Label("清除缓存", systemImage: "trash") }
            }
            .disabled(isClearingCache)
        }
    }

    private var homeSection: some View {
        Section("发现页栏目") {
            ForEach(model.homeDescriptors) { descriptor in
                Toggle(descriptor.title, isOn: Binding(
                    get: { model.settings.homeSectionIDs.contains(descriptor.id) },
                    set: { model.setHomeSection(descriptor.id, enabled: $0) }
                ))
            }
        }
    }

    @ViewBuilder
    private var uploadSection: some View {
        if let uploads = model.uploads {
            Section("上传") {
                NavigationLink { IOSUploadTasksView(manager: uploads) } label: {
                    Label("上传任务", systemImage: "tray.full")
                }
                if let audioLibrary = model.audioLibrary, let accountID = model.currentUserID {
                    NavigationLink {
                        IOSPodcastUploadView(
                            library: audioLibrary,
                            manager: uploads,
                            model: model,
                            accountID: accountID
                        )
                    } label: {
                        Label("上传到我创建的播客", systemImage: "mic.badge.plus")
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var advancedSection: some View {
        if let session = model.session {
            Section("音乐包权益") {
                SecureField("MUSIC_U", text: $musicU)
                    .textContentType(.password)
                    .privacySensitive()
                    .disabled(isVerifyingMusicU)
                Button { verifyMusicU(session) } label: {
                    if isVerifyingMusicU { HStack { ProgressView(); Text("正在验证") } }
                    else { Label("验证并保存", systemImage: "checkmark.shield") }
                }
                .disabled(isVerifyingMusicU || musicU.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button(role: .destructive) {
                    if session.clearMusicU() {
                        musicU = ""
                        message = "MUSIC_U 已清除。"
                    } else {
                        message = "MUSIC_U 清除失败，请重试。"
                    }
                } label: {
                    Label("清除 MUSIC_U", systemImage: "trash")
                }
                .disabled(isVerifyingMusicU)
                if session.isVIPVerified {
                    Label("音乐包权益已验证", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            }
        }
    }

    private var displayedCrossfade: TimeInterval {
        crossfadeDraft ?? model.settings.crossfadeDuration
    }

    private func folderRow(_ title: String, path: String, kind: IOSFolderKind) -> some View {
        Button { selectedFolder = kind } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).foregroundStyle(.primary)
                    Text(path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
                Spacer()
                Image(systemName: "folder.badge.plus")
            }
            .frame(minHeight: 44)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("选择\(title)位置")
    }

    private func sessionStateTitle(_ state: SessionState) -> String {
        switch state {
        case .guest: "访客模式"
        case .authenticated: "账号已验证"
        case .invalid: "登录已失效"
        case .error: "会话验证失败"
        }
    }

    private func sessionStateSymbol(_ state: SessionState) -> String {
        switch state {
        case .guest: "person.crop.circle.badge.questionmark"
        case .authenticated: "checkmark.shield.fill"
        case .invalid: "person.crop.circle.badge.exclamationmark"
        case .error: "wifi.exclamationmark"
        }
    }

    private func saveCookie(_ session: SessionController) {
        let value = cookie
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        isSavingCookie = true
        Task { @MainActor in
            let saved = await session.save(cookie: value)
            cookie = ""
            isSavingCookie = false
            if saved {
                await sessionDidChange()
            } else {
                message = "Cookie 未通过验证，未保存。"
            }
        }
    }

    private func refresh(_ session: SessionController) {
        isRefreshing = true
        Task { @MainActor in
            defer { isRefreshing = false }
            do {
                if try await session.refresh() {
                    await sessionDidChange()
                } else {
                    message = "刷新后的会话未通过验证，原登录保持不变。"
                }
            } catch {
                message = error.localizedDescription
            }
        }
    }

    private func logout() {
        guard let session = model.session else { return }
        isLoggingOut = true
        Task { @MainActor in
            let warning = await session.logout()
            await sessionDidChange()
            isLoggingOut = false
            message = warning ?? "已退出登录。"
        }
    }

    @MainActor
    private func sessionDidChange() async {
        guard let session = model.session else { return }
        player.setAccountCredentialRevision(session.credentialRevision)
        await model.refreshAccountState()
        if session.state == .authenticated { message = "登录成功。" }
    }

    private func verifyMusicU(_ session: SessionController) {
        let value = musicU
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        isVerifyingMusicU = true
        Task { @MainActor in
            defer {
                musicU = ""
                isVerifyingMusicU = false
            }
            do {
                message = try await session.verifyAndSaveMusicU(value)
                    ? "MUSIC_U 已验证并保存。"
                    : "MUSIC_U 无效或没有有效的音乐包权益。"
            } catch {
                message = "验证失败：\(error.localizedDescription)"
            }
        }
    }

    private func commitCrossfade() {
        guard let crossfadeDraft else { return }
        self.crossfadeDraft = nil
        if crossfadeDraft != model.settings.crossfadeDuration {
            model.setCrossfadeDuration(crossfadeDraft)
        }
    }

    private func handleFolderSelection(_ result: Result<[URL], any Error>) {
        defer { selectedFolder = nil }
        guard let kind = selectedFolder else { return }
        switch result {
        case let .success(urls):
            guard let url = urls.first else { return }
            switch kind {
            case .audio: model.setDownloadFolder(url)
            case .video: model.setVideoDownloadFolder(url)
            case .image: model.setImageFolder(url)
            case .sheet: model.setSheetFolder(url)
            case .cache: model.setCacheFolder(url)
            }
        case let .failure(error):
            message = error.localizedDescription
        }
    }

    private func clearCache() {
        guard !isClearingCache else { return }
        isClearingCache = true
        Task { @MainActor in
            var failures: [String] = []
            do { try await player.clearCache() }
            catch { failures.append("播放缓存：\(error.localizedDescription)") }
            if let downloads = model.downloads {
                do { try await downloads.clearCache() }
                catch { failures.append("下载缓存：\(error.localizedDescription)") }
            }
            do { try await MusicSheetWorker.shared.clearCache(at: model.cacheFolderURL) }
            catch { failures.append("乐谱缓存：\(error.localizedDescription)") }
            await ArtworkPipeline.shared.clearCache()
            isClearingCache = false
            message = failures.isEmpty ? "缓存已清除。" : "部分缓存清除失败：\n" + failures.joined(separator: "\n")
        }
    }
}

private enum IOSFolderKind: String, Identifiable {
    case audio, video, image, sheet, cache
    var id: Self { self }
}

private enum IOSQRPhase: Equatable {
    case loading
    case waitingScan
    case waitingConfirmation
    case expired
    case failed(String)
}

private struct IOSQRLoginView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Bindable var session: SessionController
    let onSuccess: @MainActor () async -> Void
    @State private var phase = IOSQRPhase.loading
    @State private var key: String?
    @State private var image: UIImage?
    @State private var task: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            VStack(spacing: 22) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8).fill(.white)
                    if let image {
                        Image(uiImage: image)
                            .resizable()
                            .interpolation(.none)
                            .padding(10)
                            .accessibilityHidden(true)
                    } else {
                        ProgressView()
                    }
                }
                .frame(width: 280, height: 280)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("网易云音乐登录二维码")

                status
                    .frame(maxWidth: .infinity, minHeight: 48)

                if case .expired = phase {
                    Button("刷新二维码", systemImage: "arrow.clockwise", action: start)
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                } else if case .failed = phase {
                    Button("重试", systemImage: "arrow.clockwise", action: start)
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                }
                Spacer(minLength: 0)
            }
            .padding(24)
            .navigationTitle("二维码登录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            }
        }
        .presentationDetents([.large])
        .onAppear(perform: start)
        .onDisappear(perform: cancel)
        .onChange(of: scenePhase) { _, value in
            if value == .active {
                if let key { poll(key) }
            } else {
                task?.cancel()
                task = nil
            }
        }
    }

    @ViewBuilder
    private var status: some View {
        switch phase {
        case .loading:
            Label("正在生成二维码", systemImage: "qrcode").foregroundStyle(.secondary)
        case .waitingScan:
            Label("请使用网易云音乐客户端扫码", systemImage: "viewfinder").foregroundStyle(.secondary)
        case .waitingConfirmation:
            Label("已扫码，请在手机上确认", systemImage: "iphone.and.arrow.forward").foregroundStyle(.secondary)
        case .expired:
            Label("二维码已过期", systemImage: "clock.badge.exclamationmark").foregroundStyle(.red)
        case let .failed(message):
            Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                .multilineTextAlignment(.center)
        }
    }

    private func start() {
        cancel()
        phase = .loading
        key = nil
        image = nil
        task = Task { @MainActor in
            do {
                let key = try await session.requestQRLoginKey()
                let image = try IOSNativeQRCode.image(key: key, chainID: IOSNativeQRCode.webChainID())
                try Task.checkCancellation()
                self.key = key
                self.image = image
                poll(key)
            } catch is CancellationError {
            } catch {
                phase = .failed(error.localizedDescription)
                task = nil
            }
        }
    }

    private func poll(_ key: String) {
        task?.cancel()
        task = Task { @MainActor in
            while !Task.isCancelled {
                do {
                    switch try await session.checkQRLogin(key: key) {
                    case .expired:
                        phase = .expired
                        task = nil
                        return
                    case .waitingScan:
                        phase = .waitingScan
                    case .waitingConfirmation:
                        phase = .waitingConfirmation
                    case .succeeded:
                        task = nil
                        await onSuccess()
                        dismiss()
                        return
                    }
                    try await Task.sleep(for: .seconds(2))
                } catch is CancellationError {
                    return
                } catch {
                    phase = .failed(error.localizedDescription)
                    task = nil
                    return
                }
            }
        }
    }

    private func cancel() {
        task?.cancel()
        task = nil
    }
}

private enum IOSNativeQRCode {
    static func loginURL(key: String, chainID: String?) throws -> URL {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        guard let key = key.addingPercentEncoding(withAllowedCharacters: allowed),
              let chainID = chainID?.addingPercentEncoding(withAllowedCharacters: allowed),
              let url = URL(string: "https://music.163.com/login?codekey=\(key)&chainId=\(chainID)")
        else { throw EAPIError.invalidPayload }
        return url
    }

    static func webChainID() -> String {
        "v1_unknown-\(Int.random(in: 0..<1_000_000))_web_login_\(Int64(Date().timeIntervalSince1970 * 1_000))"
    }

    static func image(key: String, chainID: String, size: Int = 280) throws -> UIImage {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(try loginURL(key: key, chainID: chainID).absoluteString.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { throw EAPIError.invalidPayload }
        let extent = output.extent.integral
        let scale = floor(CGFloat(size - 20) / max(extent.width, extent.height))
        guard scale >= 1 else { throw EAPIError.invalidPayload }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let canvas = CGRect(x: 0, y: 0, width: size, height: size)
        let centered = scaled.transformed(by: CGAffineTransform(
            translationX: floor((CGFloat(size) - scaled.extent.width) / 2),
            y: floor((CGFloat(size) - scaled.extent.height) / 2)
        ))
        let rendered = centered.composited(over: CIImage(color: .white).cropped(to: canvas))
        guard let cgImage = CIContext().createCGImage(rendered, from: canvas) else {
            throw EAPIError.invalidPayload
        }
        return UIImage(cgImage: cgImage)
    }
}

private enum IOSWebLoginPhase: Equatable {
    case loading
    case waiting
    case saving
    case failed(String)
}

private struct IOSWebLoginView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var session: SessionController
    let onSuccess: @MainActor () async -> Void
    @State private var phase = IOSWebLoginPhase.loading
    @State private var browserID = UUID()

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                IOSNeteaseLoginWebView(
                    onReady: { if phase == .loading { phase = .waiting } },
                    onFailure: { if phase != .saving { phase = .failed($0) } },
                    onCredentials: save
                )
                .id(browserID)
                Divider()
                status.padding(.horizontal, 16).frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
            }
            .navigationTitle("官方网页登录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                if case .failed = phase {
                    ToolbarItem(placement: .primaryAction) {
                        Button("重试") {
                            phase = .loading
                            browserID = UUID()
                        }
                    }
                }
            }
        }
        .presentationDetents([.large])
        .interactiveDismissDisabled(phase == .saving)
    }

    @ViewBuilder
    private var status: some View {
        switch phase {
        case .loading:
            HStack { ProgressView(); Text("正在打开 music.163.com") }
        case .waiting:
            Label("请在官方页面完成登录，成功后会自动验证。", systemImage: "lock.shield")
                .foregroundStyle(.secondary)
        case .saving:
            HStack { ProgressView(); Text("正在验证登录状态") }
        case let .failed(message):
            Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
        }
    }

    private func save(_ credentials: SessionCredentials) {
        guard phase != .saving else { return }
        phase = .saving
        Task { @MainActor in
            if await session.save(cookie: credentials.cookie) {
                await onSuccess()
                dismiss()
            } else {
                phase = .failed("登录凭据未通过验证，请重试。")
            }
        }
    }
}

private struct IOSNeteaseLoginWebView: UIViewRepresentable {
    let onReady: () -> Void
    let onFailure: (String) -> Void
    let onCredentials: (SessionCredentials) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onReady: onReady, onFailure: onFailure, onCredentials: onCredentials)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: configuration)
        context.coordinator.cookieStore = configuration.websiteDataStore.httpCookieStore
        configuration.websiteDataStore.httpCookieStore.add(context.coordinator)
        view.navigationDelegate = context.coordinator
        view.load(URLRequest(url: URL(string: "https://music.163.com/#/login")!))
        return view
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        uiView.stopLoading()
        uiView.navigationDelegate = nil
        coordinator.cookieStore?.remove(coordinator)
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKHTTPCookieStoreObserver {
        let onReady: () -> Void
        let onFailure: (String) -> Void
        let onCredentials: (SessionCredentials) -> Void
        var cookieStore: WKHTTPCookieStore?
        private var lastCredentials: SessionCredentials?

        init(onReady: @escaping () -> Void, onFailure: @escaping (String) -> Void, onCredentials: @escaping (SessionCredentials) -> Void) {
            self.onReady = onReady
            self.onFailure = onFailure
            self.onCredentials = onCredentials
        }

        func cookiesDidChange(in cookieStore: WKHTTPCookieStore) { inspect(cookieStore) }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
        ) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.cancel)
                return
            }
            decisionHandler(Self.isOfficialNavigation(url) ? .allow : .cancel)
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation?) {
            guard let url = webView.url, Self.isOfficialNavigation(url) else {
                webView.stopLoading()
                onFailure("已阻止非网易云官方页面。")
                return
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {
            onReady()
            if let cookieStore { inspect(cookieStore) }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation?, withError error: any Error) { report(error) }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation?, withError error: any Error) { report(error) }

        private func report(_ error: any Error) {
            let error = error as NSError
            guard error.code != NSURLErrorCancelled else { return }
            onFailure("登录页加载失败：\(error.localizedDescription)")
        }

        private func inspect(_ cookieStore: WKHTTPCookieStore) {
            cookieStore.getAllCookies { [weak self] cookies in
                guard let credentials = NeteaseWebCookieExtractor.credentials(from: cookies) else { return }
                Task { @MainActor [weak self] in
                    guard let self, credentials != lastCredentials else { return }
                    lastCredentials = credentials
                    onCredentials(credentials)
                }
            }
        }

        private static func isOfficialNavigation(_ url: URL) -> Bool {
            if url.scheme?.lowercased() == "about" { return true }
            let host = url.host?.lowercased() ?? ""
            return url.scheme?.lowercased() == "https" && (host == "163.com" || host.hasSuffix(".163.com"))
        }
    }
}

struct IOSUploadTasksView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var manager: AudioUploadManager

    var body: some View {
        NavigationStack {
            List {
                if let error = manager.persistenceError {
                    Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
                }
                if manager.itemOrder.isEmpty {
                    IOSLibraryEmptyRow(title: "暂无上传任务", symbol: "arrow.up.circle")
                } else {
                    ForEach(manager.itemOrder, id: \.self) { id in
                        if let item = manager.items[id] { uploadRow(item) }
                    }
                }
            }
            .navigationTitle("上传任务")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        Task {
                            await manager.flushEdits()
                            dismiss()
                        }
                    }
                }
            }
        }
        .onDisappear { Task { await manager.flushEdits() } }
    }

    @ViewBuilder
    private func uploadRow(_ item: AudioUploadItem) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: destinationSymbol(item.destination)).frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.filename).font(.headline).lineLimit(2)
                    Text(uploadDetail(item)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Menu {
                    controls(item)
                } label: {
                    Image(systemName: "ellipsis").frame(width: 44, height: 44)
                }
                .accessibilityLabel("\(item.filename)上传操作")
            }
            if case let .uploading(completed, total) = item.phase {
                ProgressView(value: Double(completed), total: Double(max(1, total)))
                    .accessibilityLabel("上传进度")
            }
            if item.phase == .paused, let metadata = item.metadata {
                Divider()
                if item.destination == .cloud {
                    TextField("标题", text: Binding(
                        get: { manager.items[item.id]?.metadata?.title ?? metadata.title },
                        set: { manager.updateMetadata(id: item.id, title: $0) }
                    ))
                    TextField("歌手", text: Binding(
                        get: { manager.items[item.id]?.metadata?.artist ?? metadata.artist },
                        set: { manager.updateMetadata(id: item.id, artist: $0) }
                    ))
                    TextField("专辑", text: Binding(
                        get: { manager.items[item.id]?.metadata?.album ?? metadata.album },
                        set: { manager.updateMetadata(id: item.id, album: $0) }
                    ))
                } else if let form = item.podcastForm {
                    TextField("节目名称", text: Binding(
                        get: { manager.items[item.id]?.podcastForm?.name ?? form.name },
                        set: { manager.updatePodcastForm(id: item.id, name: $0) }
                    ))
                    TextField("节目描述", text: Binding(
                        get: { manager.items[item.id]?.podcastForm?.description ?? form.description },
                        set: { manager.updatePodcastForm(id: item.id, description: $0) }
                    ), axis: .vertical)
                    Toggle("私密节目", isOn: Binding(
                        get: { manager.items[item.id]?.podcastForm?.isPrivate ?? form.isPrivate },
                        set: { manager.updatePodcastForm(id: item.id, isPrivate: $0) }
                    ))
                }
            }
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private func controls(_ item: AudioUploadItem) -> some View {
        switch item.phase {
        case .paused:
            Button("开始上传", systemImage: "play.fill") { Task { await manager.start(item.id) } }
        case .failed:
            if item.isPrepared {
                Button("重试", systemImage: "arrow.clockwise") { Task { await manager.retry(item.id) } }
            }
        case .reconciling:
            Button("核对结果", systemImage: "checkmark.arrow.trianglehead.counterclockwise") { manager.reconcile(item.id) }
        case .allocating, .uploading, .registering:
            Button("暂停", systemImage: "pause.fill") { Task { await manager.pause(item.id) } }
        case .completed, .cleanupPending, .inspecting, .hashing:
            EmptyView()
        }
        Divider()
        Button(item.phase == .completed ? "移除任务" : "取消上传", systemImage: item.phase == .completed ? "trash" : "xmark", role: .destructive) {
            Task { await manager.cancel(item.id) }
        }
    }

    private func uploadDetail(_ item: AudioUploadItem) -> String {
        let bytes = item.byteCount > 0
            ? ByteCountFormatter.string(fromByteCount: item.byteCount, countStyle: .file)
            : ""
        return [bytes, uploadPhaseText(item.phase)].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private func uploadPhaseText(_ phase: AudioUploadPhase) -> String {
        switch phase {
        case .inspecting: "正在检查"
        case .hashing: "正在计算校验值"
        case .allocating: "正在准备上传"
        case let .uploading(completed, total): "\(Int(Double(completed) / Double(max(1, total)) * 100))%"
        case .registering: "正在提交"
        case .paused: "已暂停"
        case .reconciling: "等待核对"
        case .completed: "已完成"
        case let .cleanupPending(message): message
        case let .failed(message): message
        }
    }

    private func destinationSymbol(_ destination: AudioUploadDestination) -> String {
        switch destination { case .cloud: "externaldrive.badge.icloud"; case .podcast: "mic" }
    }
}

private struct IOSPodcastUploadView: View {
    let library: LiveAudioContentLibrary
    @Bindable var manager: AudioUploadManager
    @Bindable var model: AppModel
    let accountID: Int64
    @State private var podcasts: [Podcast] = []
    @State private var selectedID: Int64?
    @State private var isLoading = true
    @State private var isImporting = false
    @State private var errorMessage: String?

    var body: some View {
        List {
            if isLoading {
                HStack { ProgressView(); Text("正在载入播客") }
            } else if podcasts.isEmpty {
                IOSLibraryEmptyRow(title: "没有可用的自建播客", symbol: "mic.slash")
            } else {
                ForEach(podcasts) { podcast in
                    Button { selectedID = podcast.id } label: {
                        HStack {
                            IOSPodcastLabel(podcast: podcast)
                            Spacer()
                            if selectedID == podcast.id { Image(systemName: "checkmark").foregroundStyle(.red) }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .navigationTitle("上传播客节目")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { isImporting = true } label: { Image(systemName: "mic.badge.plus") }
                    .accessibilityLabel("选择节目音频")
                    .disabled(selectedID == nil || isLoading)
            }
        }
        .task(id: "\(accountID):\(revision)") { await load() }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.audio]) { result in
            switch result {
            case let .success(url): Task { await prepare(url) }
            case let .failure(error): errorMessage = error.localizedDescription
            }
        }
        .alert("上传失败", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("好") { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }

    private var revision: UInt64 { library.transport.credentialSnapshotValue().revision }

    @MainActor
    private func load() async {
        isLoading = true
        do {
            podcasts = try await library.myCreatedPodcasts(expectedCredentialRevision: revision)
            selectedID = podcasts.first?.id
        } catch is CancellationError {
        } catch { errorMessage = error.localizedDescription }
        isLoading = false
    }

    @MainActor
    private func prepare(_ url: URL) async {
        guard let selectedID,
              model.currentUserID == accountID,
              model.confirmedAccountCredentialRevision == revision
        else { return }
        do {
            let podcast = try await library.uploadPodcast(id: selectedID, expectedCredentialRevision: revision)
            let form = PodcastUploadForm(
                name: url.deletingPathExtension().lastPathComponent,
                description: "",
                voiceListID: podcast.id,
                coverImageID: podcast.coverImageID,
                categoryID: podcast.categoryID,
                secondCategoryID: podcast.secondCategoryID,
                isPrivate: podcast.isPrivate
            )
            _ = try form.validated()
            guard manager.preparePodcastFile(url, form: form) != nil else {
                throw EAPIError.invalidPayload
            }
            model.showToast("已创建播客上传任务")
        } catch is CancellationError {
        } catch { errorMessage = error.localizedDescription }
    }
}
