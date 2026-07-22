import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import Observation
import SwiftUI

enum NativeQRCodeError: LocalizedError {
    case invalidURL
    case generationFailed

    var errorDescription: String? {
        switch self {
        case .invalidURL: "无法生成二维码登录地址"
        case .generationFailed: "无法生成登录二维码"
        }
    }
}

enum NativeQRCode {
    static func loginURL(key: String, chainID: String? = nil) throws -> URL {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        guard let encodedKey = key.addingPercentEncoding(withAllowedCharacters: allowed) else {
            throw NativeQRCodeError.invalidURL
        }
        let encodedChainID = chainID?.addingPercentEncoding(withAllowedCharacters: allowed)
        let value = "https://music.163.com/login?codekey=\(encodedKey)"
            + (encodedChainID.map { "&chainId=\($0)" } ?? "")
        guard let url = URL(string: value)
        else { throw NativeQRCodeError.invalidURL }
        return url
    }

    static func webChainID() -> String {
        "v1_unknown-\(Int.random(in: 0..<1_000_000))_web_login_\(Int64(Date().timeIntervalSince1970 * 1_000))"
    }

    static func image(key: String, chainID: String? = nil, size: Int = 300) throws -> NSImage {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(try loginURL(key: key, chainID: chainID).absoluteString.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { throw NativeQRCodeError.generationFailed }

        let extent = output.extent.integral
        let scale = floor(CGFloat(size) / (max(extent.width, extent.height) + 8))
        guard scale >= 1 else { throw NativeQRCodeError.generationFailed }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let origin = CGPoint(
            x: floor((CGFloat(size) - scaled.extent.width) / 2),
            y: floor((CGFloat(size) - scaled.extent.height) / 2)
        )
        let positioned = scaled.transformed(by: CGAffineTransform(translationX: origin.x, y: origin.y))
        let canvas = CGRect(x: 0, y: 0, width: size, height: size)
        let image = positioned.composited(over: CIImage(color: .white).cropped(to: canvas))
        guard let cgImage = CIContext().createCGImage(image, from: canvas) else {
            throw NativeQRCodeError.generationFailed
        }
        return NSImage(cgImage: cgImage, size: NSSize(width: size, height: size))
    }
}

enum QRLoginPhase: Equatable {
    case idle
    case loading
    case waitingScan
    case waitingConfirmation
    case succeeded
    case expired
    case failed
}

@MainActor
@Observable
final class QRLoginController {
    private(set) var key: String?
    private(set) var image: NSImage?
    private(set) var phase: QRLoginPhase = .idle
    private(set) var error: String?

    @ObservationIgnored private let session: SessionController
    @ObservationIgnored private let pollingInterval: Duration
    @ObservationIgnored private var pollingTask: Task<Void, Never>?
    @ObservationIgnored private var generation = 0

    init(session: SessionController, pollingInterval: Duration = .seconds(2)) {
        self.session = session
        self.pollingInterval = pollingInterval
    }

    var isPolling: Bool { pollingTask != nil }

    func start() {
        replaceTask { controller, generation in
            controller.phase = .loading
            controller.error = nil
            controller.key = nil
            controller.image = nil
            do {
                let key = try await controller.session.requestQRLoginKey()
                let image = try NativeQRCode.image(key: key, chainID: NativeQRCode.webChainID())
                guard controller.generation == generation else { return }
                controller.key = key
                controller.image = image
                await controller.poll(key: key, generation: generation)
            } catch is CancellationError {
            } catch {
                controller.fail(error, generation: generation)
            }
        }
    }

    func retry() {
        guard let key, image != nil else {
            start()
            return
        }
        replaceTask { controller, generation in
            controller.error = nil
            await controller.poll(key: key, generation: generation)
        }
    }

    func refreshCode() {
        start()
    }

    func setActive(_ active: Bool) {
        if !active {
            generation &+= 1
            pollingTask?.cancel()
            pollingTask = nil
        } else if pollingTask == nil {
            switch phase {
            case .loading: start()
            case .waitingScan, .waitingConfirmation: retry()
            case .idle, .succeeded, .expired, .failed: break
            }
        }
    }

    func cancel() {
        generation &+= 1
        pollingTask?.cancel()
        pollingTask = nil
    }

    private func replaceTask(
        _ operation: @escaping @MainActor (QRLoginController, Int) async -> Void
    ) {
        generation &+= 1
        let generation = generation
        pollingTask?.cancel()
        pollingTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await operation(self, generation)
            if self.generation == generation { self.pollingTask = nil }
        }
    }

    private func poll(key: String, generation: Int) async {
        while !Task.isCancelled, self.generation == generation {
            do {
                let status = try await session.checkQRLogin(key: key)
                guard self.generation == generation else { return }
                switch status {
                case .expired:
                    phase = .expired
                    return
                case .waitingScan:
                    phase = .waitingScan
                case .waitingConfirmation:
                    phase = .waitingConfirmation
                case .succeeded:
                    phase = .succeeded
                    return
                }
                try await Task.sleep(for: pollingInterval)
            } catch is CancellationError {
                return
            } catch {
                fail(error, generation: generation)
                return
            }
        }
    }

    private func fail(_ error: Error, generation: Int) {
        guard self.generation == generation else { return }
        self.error = error.localizedDescription
        phase = .failed
    }
}

struct NativeQRLoginView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var controller: QRLoginController
    let onSuccess: () -> Void

    init(session: SessionController, onSuccess: @escaping () -> Void) {
        _controller = State(initialValue: QRLoginController(session: session))
        self.onSuccess = onSuccess
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("二维码登录", systemImage: "qrcode")
                    .font(.headline)
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .help("关闭")
                .accessibilityLabel("关闭二维码登录")
            }
            .padding(.horizontal, 20)
            .frame(height: 56)

            Divider()

            VStack(spacing: 20) {
                qrImage
                status
                    .frame(maxWidth: .infinity, minHeight: 44)
                actions
                    .frame(minHeight: 44)
            }
            .padding(28)
        }
        .frame(width: 420, height: 560)
        .onAppear { controller.start() }
        .onDisappear { controller.cancel() }
        .onChange(of: scenePhase) { _, phase in controller.setActive(phase == .active) }
        .onChange(of: controller.phase) { _, phase in
            if phase == .succeeded {
                onSuccess()
                dismiss()
            }
        }
    }

    @ViewBuilder
    private var qrImage: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(.white)
            if let image = controller.image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.none)
                    .accessibilityHidden(true)
            } else {
                ProgressView()
                    .controlSize(.large)
            }
        }
        .frame(width: 300, height: 300)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("网易云音乐登录二维码")
    }

    @ViewBuilder
    private var status: some View {
        switch controller.phase {
        case .idle, .loading:
            Label("正在生成二维码", systemImage: "qrcode")
                .foregroundStyle(.secondary)
        case .waitingScan:
            Label("等待扫码", systemImage: "viewfinder")
                .foregroundStyle(.secondary)
        case .waitingConfirmation:
            Label("已扫码，等待手机确认", systemImage: "iphone.and.arrow.forward")
                .foregroundStyle(.secondary)
        case .succeeded:
            Label("登录成功", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .expired:
            Label("二维码已过期", systemImage: "clock.badge.exclamationmark")
                .foregroundStyle(.red)
        case .failed:
            Label(controller.error ?? "登录失败", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)
                .multilineTextAlignment(.center)
        }
    }

    @ViewBuilder
    private var actions: some View {
        switch controller.phase {
        case .expired:
            Button("刷新二维码", systemImage: "arrow.clockwise", action: controller.refreshCode)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        case .failed:
            HStack(spacing: 12) {
                Button("重试", systemImage: "arrow.clockwise", action: controller.retry)
                Button("刷新二维码", systemImage: "qrcode", action: controller.refreshCode)
                    .buttonStyle(.borderedProminent)
            }
            .controlSize(.large)
        case .idle, .loading, .waitingScan, .waitingConfirmation, .succeeded:
            EmptyView()
        }
    }
}
