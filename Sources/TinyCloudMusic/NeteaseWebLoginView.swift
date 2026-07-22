import SwiftUI
@preconcurrency import WebKit

private enum WebLoginPhase: Equatable {
    case loading
    case waiting
    case saving
    case failed(String)
}

struct NeteaseWebLoginView: View {
    @Bindable var controller: SessionController
    let onSuccess: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var phase: WebLoginPhase = .loading
    @State private var browserID = UUID()
    @State private var pendingCredentials: SessionCredentials?

    init(controller: SessionController, onSuccess: @escaping () -> Void) {
        self.controller = controller
        self.onSuccess = onSuccess
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Label("网易云音乐登录", systemImage: "lock.shield")
                    .font(.headline)
                Text("music.163.com")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .frame(width: 44, height: 44)
                .help("关闭")
                .accessibilityLabel("关闭网页登录")
            }
            .padding(.horizontal, 20)
            .frame(height: 56)

            Divider()

            NeteaseLoginWebView(
                onReady: {
                    if phase == .loading { phase = .waiting }
                },
                onFailure: { message in
                    if phase != .saving { phase = .failed(message) }
                },
                onCredentials: save
            )
            .id(browserID)

            Divider()
            status
                .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
                .padding(.horizontal, 20)
        }
        .frame(minWidth: 760, idealWidth: 920, minHeight: 560, idealHeight: 680)
    }

    @ViewBuilder
    private var status: some View {
        switch phase {
        case .loading:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("正在打开网易云音乐登录页…")
            }
        case .waiting:
            Label("请在网页中扫码登录，成功后会自动验证、保存并关闭窗口。", systemImage: "qrcode")
                .foregroundStyle(.secondary)
        case .saving:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("正在确认登录状态…")
                    .foregroundStyle(.secondary)
            }
        case let .failed(message):
            HStack(spacing: 12) {
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                Spacer()
                Button("重试") {
                    phase = .loading
                    browserID = UUID()
                }
            }
        }
    }

    private func save(_ credentials: SessionCredentials) {
        guard phase != .saving else {
            pendingCredentials = credentials
            return
        }
        phase = .saving
        Task { @MainActor in
            let saved = await controller.save(cookie: credentials.cookie)
            if saved {
                onSuccess()
                dismiss()
            } else if let pendingCredentials, pendingCredentials != credentials {
                self.pendingCredentials = nil
                phase = .waiting
                save(pendingCredentials)
            } else if controller.state != .error {
                phase = .waiting
            } else {
                phase = .failed("保存失败，请检查网络后重试。")
            }
        }
    }
}

private struct NeteaseLoginWebView: NSViewRepresentable {
    let onReady: () -> Void
    let onFailure: (String) -> Void
    let onCredentials: (SessionCredentials) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onReady: onReady, onFailure: onFailure, onCredentials: onCredentials)
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()

        let webView = WKWebView(frame: .zero, configuration: configuration)
        let cookieStore = configuration.websiteDataStore.httpCookieStore
        context.coordinator.cookieStore = cookieStore
        cookieStore.add(context.coordinator)
        webView.navigationDelegate = context.coordinator
        webView.allowsMagnification = true
        webView.load(URLRequest(url: URL(string: "https://music.163.com/#/login")!))
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {}

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.stopLoading()
        if let cookieStore = coordinator.cookieStore {
            cookieStore.remove(coordinator)
        }
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKHTTPCookieStoreObserver {
        let onReady: () -> Void
        let onFailure: (String) -> Void
        let onCredentials: (SessionCredentials) -> Void
        var cookieStore: WKHTTPCookieStore?
        private var lastCredentials: SessionCredentials?

        init(
            onReady: @escaping () -> Void,
            onFailure: @escaping (String) -> Void,
            onCredentials: @escaping (SessionCredentials) -> Void
        ) {
            self.onReady = onReady
            self.onFailure = onFailure
            self.onCredentials = onCredentials
        }

        func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
            inspect(cookieStore)
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
        ) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.cancel)
                return
            }
            if url.scheme == "about" {
                decisionHandler(.allow)
                return
            }
            let host = url.host?.lowercased() ?? ""
            let isOfficial = url.scheme == "https" && (host == "163.com" || host.hasSuffix(".163.com"))
            decisionHandler(isOfficial ? .allow : .cancel)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {
            onReady()
            if let cookieStore { inspect(cookieStore) }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation?, withError error: any Error) {
            report(error)
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation?,
            withError error: any Error
        ) {
            report(error)
        }

        private func report(_ error: any Error) {
            let error = error as NSError
            guard error.code != NSURLErrorCancelled else { return }
            onFailure("登录页加载失败：\(error.localizedDescription)")
        }

        private func inspect(_ cookieStore: WKHTTPCookieStore) {
            cookieStore.getAllCookies { [weak self] cookies in
                guard let credentials = NeteaseWebCookieExtractor.credentials(from: cookies) else { return }
                Task { @MainActor [weak self] in
                    guard let self, self.lastCredentials != credentials else { return }
                    self.lastCredentials = credentials
                    self.onCredentials(credentials)
                }
            }
        }
    }
}
