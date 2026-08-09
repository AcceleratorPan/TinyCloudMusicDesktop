import Foundation
@preconcurrency import NIMSDK

enum NIMChatroomEvent: Equatable, Sendable {
    case message(raw: String, generation: Int)
    case status(Int, generation: Int)
}

enum NIMChatroomError: LocalizedError {
    case unavailable
    case connectionFailed(stage: String)

    var errorDescription: String? {
        switch self {
        case .unavailable: "一起听实时服务不可用"
        case .connectionFailed: "无法连接一起听实时服务"
        }
    }
}

enum IOSNIMChatroomMessageAdapter {
    private static let maximumBytes = 65_536

    static func event(
        rawAttachContent: String?,
        remoteExtension: [String: Any]?,
        text: String?,
        generation: Int
    ) -> NIMChatroomEvent? {
        guard let raw = rawPayload(
            rawAttachContent: rawAttachContent,
            remoteExtension: remoteExtension,
            text: text
        ) else { return nil }
        return .message(raw: raw, generation: generation)
    }

    static func rawPayload(from message: NIMMessage) -> String? {
        rawPayload(
            rawAttachContent: message.rawAttachContent,
            remoteExtension: message.remoteExt as? [String: Any],
            text: message.text
        )
    }

    private static func rawPayload(
        rawAttachContent: String?,
        remoteExtension: [String: Any]?,
        text: String?
    ) -> String? {
        if let rawAttachContent, isJSONObject(rawAttachContent) { return rawAttachContent }
        if let remoteExtension,
           JSONSerialization.isValidJSONObject(remoteExtension),
           let data = try? JSONSerialization.data(withJSONObject: remoteExtension, options: [.sortedKeys]),
           data.count <= maximumBytes,
           let raw = String(data: data, encoding: .utf8) {
            return raw
        }
        if let text, isJSONObject(text) { return text }
        return nil
    }

    private static func isJSONObject(_ raw: String) -> Bool {
        guard !raw.isEmpty,
              raw.utf8.count <= maximumBytes,
              let data = raw.data(using: .utf8)
        else { return false }
        return (try? JSONSerialization.jsonObject(with: data)) is [String: Any]
    }
}

private struct IOSNIMInboundMessage: Sendable {
    let roomID: String
    let raw: String
}

private enum IOSNIMNativeEvent: Sendable {
    case messages([IOSNIMInboundMessage])
    case connectionState(roomID: String, state: Int)
    case autoLoginFailed(roomID: String, code: Int)
    case kicked(roomID: String)
}

private final class IOSNIMDelegateProxy: NSObject, NIMChatManagerDelegate, NIMChatroomManagerDelegate {
    private let sink: @Sendable (IOSNIMNativeEvent) -> Void

    init(sink: @escaping @Sendable (IOSNIMNativeEvent) -> Void) {
        self.sink = sink
    }

    func onRecvMessages(_ messages: [NIMMessage]) {
        let values = messages.compactMap { message -> IOSNIMInboundMessage? in
            guard let session = message.session,
                  session.sessionType == .chatroom,
                  let raw = IOSNIMChatroomMessageAdapter.rawPayload(from: message)
            else { return nil }
            return IOSNIMInboundMessage(roomID: session.sessionId, raw: raw)
        }
        if !values.isEmpty { sink(.messages(values)) }
    }

    func chatroom(_ roomId: String, connectionStateChanged state: NIMChatroomConnectionState) {
        sink(.connectionState(roomID: roomId, state: state.rawValue))
    }

    func chatroom(_ roomId: String, autoLoginFailed error: Error) {
        sink(.autoLoginFailed(roomID: roomId, code: (error as NSError).code))
    }

    func chatroomBeKicked(_ result: NIMChatroomBeKickedResult) {
        sink(.kicked(roomID: result.roomId))
    }
}

@MainActor
private final class IOSNIMCallbackWaiter {
    private var continuation: CheckedContinuation<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var finished = false

    func wait(
        timeout: Duration,
        start: (@escaping @Sendable () -> Void) -> Void
    ) async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            start { [weak self] in
                Task { @MainActor [weak self] in self?.finish() }
            }
            timeoutTask = Task { @MainActor [weak self] in
                do {
                    try await Task.sleep(for: timeout)
                } catch {
                    return
                }
                self?.finish()
            }
        }
        timeoutTask?.cancel()
        timeoutTask = nil
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        let continuation = continuation
        self.continuation = nil
        continuation?.resume()
    }
}

@MainActor
final class NIMChatroomTransport {
    var onEvent: ((NIMChatroomEvent) -> Void)?

    nonisolated static let sdkVersion = "10.9.40"
    nonisolated private static let appKey = "3a6a3e48f6854dfa4e4464f3bdaec3b4"
    private static let connectionTimeout: Duration = .seconds(20)
    private static let exitTimeout: Duration = .seconds(5)
    private static let logoutTimeout: Duration = .seconds(20)

    private let sdk: NIMSDK
    private var nextOperationGeneration: UInt64 = 0
    private var activeOperationGeneration: UInt64?
    private var sessionGeneration: Int?
    private var roomID: String?
    private var delegateProxy: IOSNIMDelegateProxy?
    private var connectContinuation: CheckedContinuation<Void, Error>?
    private var timeoutTask: Task<Void, Never>?
    private var teardownTask: Task<Void, Never>?
    private var teardownTaskID: UUID?
    private var didStartLogin = false
    private var didStartChatroomEntry = false
    private var didEnterChatroom = false
    private var didReportConnectionLoss = false
    private var isTerminal = false

    init() {
        sdk = NIMSDK.shared()
        sdk.register(withAppID: Self.appKey, cerName: nil)
    }

    func connect(
        roomID: String,
        credentials: ListenTogetherRealtimeCredentials,
        generation: Int
    ) async throws {
        guard !isTerminal else { throw NIMChatroomError.unavailable }
        guard let numericRoomID = Int64(roomID), numericRoomID > 0 else {
            throw NIMChatroomError.connectionFailed(stage: "room-id")
        }
        guard !credentials.accountID.isEmpty, !credentials.token.isEmpty else {
            throw NIMChatroomError.connectionFailed(stage: "credentials")
        }

        await disconnectCurrent()
        guard !isTerminal else { throw NIMChatroomError.unavailable }
        try Task.checkCancellation()

        nextOperationGeneration += 1
        let operationGeneration = nextOperationGeneration
        activeOperationGeneration = operationGeneration
        sessionGeneration = generation
        self.roomID = String(numericRoomID)
        didStartLogin = true
        didStartChatroomEntry = false
        didEnterChatroom = false
        didReportConnectionLoss = false

        let proxy = IOSNIMDelegateProxy { [weak self] event in
            Task { @MainActor [weak self] in
                await self?.receive(event, operationGeneration: operationGeneration)
            }
        }
        delegateProxy = proxy
        sdk.chatManager.add(proxy)
        sdk.chatroomManager.add(proxy)

        do {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    connectContinuation = continuation
                    timeoutTask = Task { @MainActor [weak self] in
                        do {
                            try await Task.sleep(for: Self.connectionTimeout)
                        } catch {
                            return
                        }
                        await self?.finishConnect(
                            .failure(NIMChatroomError.connectionFailed(stage: "timeout")),
                            operationGeneration: operationGeneration
                        )
                    }
                    sdk.loginManager.login(
                        credentials.accountID,
                        token: credentials.token
                    ) { [weak self] error in
                        let code = error.map { ($0 as NSError).code }
                        Task { @MainActor [weak self] in
                            await self?.finishLogin(
                                errorCode: code,
                                operationGeneration: operationGeneration
                            )
                        }
                    }
                }
            } onCancel: {
                Task { @MainActor [weak self] in
                    await self?.finishConnect(
                        .failure(CancellationError()),
                        operationGeneration: operationGeneration
                    )
                }
            }
        } catch {
            await teardownOperation(
                operationGeneration,
                continuationResult: .failure(error)
            )
            throw error
        }
    }

    func disconnect(generation: Int) async {
        guard sessionGeneration == generation else { return }
        await disconnectCurrent()
    }

    func disconnect() async {
        await disconnectCurrent()
    }

    func shutdown() async {
        isTerminal = true
        await disconnectCurrent()
    }

    private func finishLogin(errorCode: Int?, operationGeneration: UInt64) async {
        guard activeOperationGeneration == operationGeneration,
              let roomID
        else { return }
        guard let errorCode else {
            didStartChatroomEntry = true
            let request = NIMChatroomEnterRequest()
            request.roomId = roomID
            request.retryCount = 3
            do {
                _ = try await sdk.chatroomManager.enterChatroom(request)
                await finishChatroomEntry(
                    errorCode: nil,
                    operationGeneration: operationGeneration
                )
            } catch {
                await finishChatroomEntry(
                    errorCode: (error as NSError).code,
                    operationGeneration: operationGeneration
                )
            }
            return
        }
        await finishConnect(
            .failure(NIMChatroomError.connectionFailed(stage: "login-\(errorCode)")),
            operationGeneration: operationGeneration
        )
    }

    private func finishChatroomEntry(errorCode: Int?, operationGeneration: UInt64) async {
        guard activeOperationGeneration == operationGeneration else { return }
        if let errorCode {
            await finishConnect(
                .failure(NIMChatroomError.connectionFailed(stage: "chatroom-enter-\(errorCode)")),
                operationGeneration: operationGeneration
            )
        } else {
            didEnterChatroom = true
            await finishConnect(.success(()), operationGeneration: operationGeneration)
        }
    }

    private func finishConnect(
        _ result: Result<Void, Error>,
        operationGeneration: UInt64
    ) async {
        guard activeOperationGeneration == operationGeneration,
              let continuation = connectContinuation
        else { return }
        timeoutTask?.cancel()
        timeoutTask = nil
        switch result {
        case .success:
            connectContinuation = nil
            continuation.resume()
        case .failure:
            await teardownOperation(operationGeneration, continuationResult: result)
        }
    }

    private func receive(
        _ event: IOSNIMNativeEvent,
        operationGeneration: UInt64
    ) async {
        guard activeOperationGeneration == operationGeneration,
              let sessionGeneration,
              let roomID
        else { return }

        switch event {
        case let .messages(messages):
            for message in messages where message.roomID == roomID {
                onEvent?(.message(raw: message.raw, generation: sessionGeneration))
            }

        case let .connectionState(eventRoomID, state):
            guard eventRoomID == roomID else { return }
            switch state {
            case 1:
                didReportConnectionLoss = false
            case 2:
                if connectContinuation != nil {
                    await finishConnect(
                        .failure(NIMChatroomError.connectionFailed(stage: "chatroom-enter-state")),
                        operationGeneration: operationGeneration
                    )
                } else {
                    reportConnectionLoss(status: 6, generation: sessionGeneration)
                }
            case 3:
                if connectContinuation != nil {
                    await finishConnect(
                        .failure(NIMChatroomError.connectionFailed(stage: "chatroom-disconnected")),
                        operationGeneration: operationGeneration
                    )
                } else {
                    reportConnectionLoss(status: 0, generation: sessionGeneration)
                }
            default:
                break
            }

        case let .autoLoginFailed(eventRoomID, code):
            guard eventRoomID == roomID else { return }
            if connectContinuation != nil {
                await finishConnect(
                    .failure(NIMChatroomError.connectionFailed(stage: "chatroom-relogin-\(code)")),
                    operationGeneration: operationGeneration
                )
            } else {
                reportConnectionLoss(status: 6, generation: sessionGeneration)
            }

        case let .kicked(eventRoomID):
            guard eventRoomID == roomID else { return }
            reportConnectionLoss(status: 6, generation: sessionGeneration)
        }
    }

    private func reportConnectionLoss(status: Int, generation: Int) {
        guard didEnterChatroom, !didReportConnectionLoss else { return }
        didReportConnectionLoss = true
        onEvent?(.status(status, generation: generation))
    }

    private func disconnectCurrent() async {
        await waitForTeardown()
        guard let operationGeneration = activeOperationGeneration else { return }
        await teardownOperation(
            operationGeneration,
            continuationResult: .failure(CancellationError())
        )
    }

    private func teardownOperation(
        _ operationGeneration: UInt64,
        continuationResult: Result<Void, Error>
    ) async {
        guard activeOperationGeneration == operationGeneration else { return }

        activeOperationGeneration = nil
        sessionGeneration = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        let continuation = connectContinuation
        connectContinuation = nil
        let roomID = roomID
        self.roomID = nil
        let shouldExit = didStartChatroomEntry
        let shouldLogout = didStartLogin
        didStartLogin = false
        didStartChatroomEntry = false
        didEnterChatroom = false
        didReportConnectionLoss = false

        if let delegateProxy {
            sdk.chatManager.remove(delegateProxy)
            sdk.chatroomManager.remove(delegateProxy)
            self.delegateProxy = nil
        }

        let taskID = UUID()
        let task = Task { @MainActor [sdk] in
            if shouldExit, let roomID {
                let waiter = IOSNIMCallbackWaiter()
                await waiter.wait(timeout: Self.exitTimeout) { finish in
                    sdk.chatroomManager.exitChatroom(roomID) { _ in finish() }
                }
            }
            if shouldLogout {
                let waiter = IOSNIMCallbackWaiter()
                await waiter.wait(timeout: Self.logoutTimeout) { finish in
                    sdk.loginManager.logout { _ in finish() }
                }
            }
        }
        teardownTaskID = taskID
        teardownTask = task
        await task.value
        if teardownTaskID == taskID {
            teardownTask = nil
            teardownTaskID = nil
        }
        continuation?.resume(with: continuationResult)
    }

    private func waitForTeardown() async {
        if let teardownTask { await teardownTask.value }
    }
}
