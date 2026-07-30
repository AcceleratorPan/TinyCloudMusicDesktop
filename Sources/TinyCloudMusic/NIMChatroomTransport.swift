import Darwin
import Foundation

enum NIMChatroomEvent: Equatable, Sendable {
    case message(raw: String, generation: Int)
    case status(Int, generation: Int)
}

enum NIMChatroomError: LocalizedError {
    case unavailable
    case connectionFailed(stage: String)

    var errorDescription: String? {
        switch self {
        case .unavailable: "实时同步组件不可用"
        case .connectionFailed: "无法连接一起听实时服务"
        }
    }
}

@MainActor
final class NIMChatroomTransport {
    var onEvent: ((NIMChatroomEvent) -> Void)?

    nonisolated static let sdkVersion = "10.9.40"
    nonisolated fileprivate static let initializationAppKey = "3a6a3e48f6854dfa4e4464f3bdaec3b4"
    nonisolated private static let loginAppKey = initializationAppKey
    private static let connectionTimeout: Duration = .seconds(20)

    private let ownerID = UUID()
    private let runtime: NIMNativeRuntime
    private var generation = 0
    private var connectContinuation: CheckedContinuation<Void, Error>?
    private var timeoutTask: Task<Void, Never>?
    private var isDisconnecting = false

    init() {
        runtime = .shared
    }

    func connect(
        roomID: String,
        credentials: ListenTogetherRealtimeCredentials,
        generation: Int
    ) async throws {
        guard let nativeRoomID = Int64(roomID), nativeRoomID > 0 else {
            throw NIMChatroomError.connectionFailed(stage: "room-id")
        }
        await disconnect()
        self.generation = generation
        isDisconnecting = false

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                connectContinuation = continuation
                do {
                    try runtime.activate(owner: ownerID) { [weak self] event in
                        Task { @MainActor [weak self] in self?.receive(event) }
                    }
                    try runtime.prepareChatroom(roomID: nativeRoomID, owner: ownerID)
                    try runtime.login(
                        appKey: Self.loginAppKey,
                        accountID: credentials.accountID,
                        token: credentials.token
                    )
                    timeoutTask = Task { @MainActor [weak self] in
                        do {
                            try await Task.sleep(for: Self.connectionTimeout)
                        } catch {
                            return
                        }
                        self?.finishConnect(.failure(
                            NIMChatroomError.connectionFailed(stage: "timeout")
                        ))
                    }
                } catch {
                    finishConnect(.failure(error))
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.finishConnect(.failure(CancellationError()))
            }
        }
    }

    func disconnect() async {
        isDisconnecting = true
        timeoutTask?.cancel()
        timeoutTask = nil
        if let continuation = connectContinuation {
            connectContinuation = nil
            continuation.resume(throwing: CancellationError())
        }
        runtime.disconnect(owner: ownerID)

        // Logout is asynchronous. Waiting briefly prevents a reconnect from racing the old session.
        for _ in 0..<40 where runtime.isLoggedIn {
            do {
                try await Task.sleep(for: .milliseconds(50))
            } catch {
                break
            }
        }
        runtime.deactivate(owner: ownerID)
    }

    nonisolated static func bundledNativeSDKURLs() -> [URL]? {
        let names = ["libh_available", "libnim", "libnim_chatroom"]
        let urls = names.compactMap {
            Bundle.module.url(forResource: $0, withExtension: "dylib", subdirectory: "NIMNative")
        }
        return urls.count == names.count ? urls : nil
    }

    private func receive(_ event: NIMNativeEvent) {
        switch event {
        case let .login(raw):
            guard let value = Self.object(from: raw),
                  let code = Self.integer(value["err_code"]),
                  let step = Self.integer(value["login_step"])
            else {
                finishConnect(.failure(NIMChatroomError.connectionFailed(stage: "nim-login-response")))
                return
            }
            if code == 200, step == 3 {
                do {
                    try runtime.requestChatroomEnter(owner: ownerID)
                } catch {
                    finishConnect(.failure(error))
                }
            } else if code != 200, step >= 3 {
                if connectContinuation != nil {
                    finishConnect(.failure(NIMChatroomError.connectionFailed(stage: "nim-login-\(code)")))
                } else if !isDisconnecting {
                    onEvent?(.status(0, generation: generation))
                }
            }

        case let .chatroomEnter(step, code):
            if code == 200, step == 5 {
                finishConnect(.success(()))
                onEvent?(.status(5, generation: generation))
            } else if code != 200, step >= 3 {
                if connectContinuation != nil {
                    finishConnect(.failure(
                        NIMChatroomError.connectionFailed(stage: "chatroom-enter-\(code)")
                    ))
                } else if !isDisconnecting {
                    onEvent?(.status(0, generation: generation))
                }
            }

        case let .chatroomRequestFailed(code):
            finishConnect(.failure(
                NIMChatroomError.connectionFailed(stage: "chatroom-request-\(code)")
            ))

        case let .message(raw):
            guard raw.utf8.count <= 65_536 else { return }
            onEvent?(.message(raw: raw, generation: generation))

        case .disconnected:
            guard !isDisconnecting else { return }
            onEvent?(.status(0, generation: generation))
        }
    }

    private func finishConnect(_ result: Result<Void, Error>) {
        guard let continuation = connectContinuation else { return }
        connectContinuation = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        if case .failure = result {
            runtime.disconnect(owner: ownerID)
        }
        continuation.resume(with: result)
    }

    private static func object(from raw: String) -> [String: Any]? {
        guard raw.utf8.count <= 65_536, let data = raw.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite,
              number.doubleValue.rounded(.towardZero) == number.doubleValue
        else { return nil }
        return Int(exactly: number.int64Value)
    }
}

private enum NIMNativeEvent: Sendable {
    case login(String)
    case chatroomEnter(step: Int, code: Int)
    case chatroomRequestFailed(Int)
    case message(String)
    case disconnected
}

private final class NIMNativeRuntime: @unchecked Sendable {
    static let shared = NIMNativeRuntime()

    private let lock = NSLock()
    private var owner: UUID?
    private var eventSink: (@Sendable (NIMNativeEvent) -> Void)?
    private var symbols: NIMNativeSymbols?
    private var handles: [UnsafeMutableRawPointer] = []
    private var initialized = false
    private var pendingChatroomID: Int64?
    private var activeChatroomID: Int64?
    private var isChatroomRequestInFlight = false

    private init() {}

    func activate(owner: UUID, eventSink: @escaping @Sendable (NIMNativeEvent) -> Void) throws {
        lock.lock()
        guard self.owner == nil || self.owner == owner else {
            lock.unlock()
            throw NIMChatroomError.connectionFailed(stage: "native-sdk-busy")
        }
        self.owner = owner
        self.eventSink = eventSink
        lock.unlock()

        do {
            try initializeIfNeeded()
        } catch {
            deactivate(owner: owner)
            throw error
        }
    }

    func deactivate(owner: UUID) {
        lock.lock()
        var runtimeToCleanUp: NIMNativeSymbols?
        if self.owner == owner {
            self.owner = nil
            eventSink = nil
            pendingChatroomID = nil
            activeChatroomID = nil
            isChatroomRequestInFlight = false
            if initialized {
                initialized = false
                runtimeToCleanUp = symbols
            }
        }
        lock.unlock()

        guard let runtimeToCleanUp else { return }
        "".withCString { runtimeToCleanUp.chatroomCleanup($0) }
        "".withCString { runtimeToCleanUp.clientCleanup($0) }
    }

    func prepareChatroom(roomID: Int64, owner: UUID) throws {
        lock.lock()
        defer { lock.unlock() }
        guard self.owner == owner, initialized else { throw NIMChatroomError.unavailable }
        pendingChatroomID = roomID
        activeChatroomID = nil
        isChatroomRequestInFlight = false
    }

    func login(appKey: String, accountID: String, token: String) throws {
        guard let login = currentSymbols()?.clientLogin else { throw NIMChatroomError.unavailable }
        appKey.withCString { appKeyPointer in
            accountID.withCString { accountPointer in
                token.withCString { tokenPointer in
                    login(
                        appKeyPointer,
                        accountPointer,
                        tokenPointer,
                        nil,
                        nimClientLoginCallback,
                        Unmanaged.passUnretained(self).toOpaque()
                    )
                }
            }
        }
    }

    func requestChatroomEnter(owner: UUID) throws {
        lock.lock()
        guard self.owner == owner,
              let roomID = pendingChatroomID,
              activeChatroomID == nil,
              !isChatroomRequestInFlight,
              let requestEnter = symbols?.requestChatroomEnter
        else {
            lock.unlock()
            throw NIMChatroomError.connectionFailed(stage: "chatroom-request-state")
        }
        isChatroomRequestInFlight = true
        lock.unlock()

        requestEnter(
            roomID,
            nil,
            nimChatroomRequestEnterCallback,
            Unmanaged.passUnretained(self).toOpaque()
        )
    }

    func disconnect(owner: UUID) {
        lock.lock()
        let ownsRuntime = self.owner == owner
        let symbols = self.symbols
        let chatroomID = ownsRuntime ? activeChatroomID : nil
        if ownsRuntime {
            pendingChatroomID = nil
            activeChatroomID = nil
            isChatroomRequestInFlight = false
        }
        lock.unlock()
        guard ownsRuntime, let symbols else { return }
        if let chatroomID {
            "".withCString { symbols.chatroomExit(chatroomID, $0) }
        }
        "".withCString { symbols.clientLogout(1, $0, nil, nil) }
    }

    var isLoggedIn: Bool {
        currentSymbols()?.clientLoginState(nil) == 1
    }

    fileprivate func emit(_ event: NIMNativeEvent) {
        lock.lock()
        let sink = eventSink
        lock.unlock()
        sink?(event)
    }

    fileprivate func emitChatroomMessage(roomID: Int64, raw: String) {
        lock.lock()
        let sink = activeChatroomID == roomID ? eventSink : nil
        lock.unlock()
        sink?(.message(raw))
    }

    fileprivate func finishChatroomRequest(
        code: Int32,
        enterData: UnsafePointer<CChar>?
    ) {
        lock.lock()
        guard owner != nil, let roomID = pendingChatroomID, activeChatroomID == nil else {
            lock.unlock()
            return
        }
        isChatroomRequestInFlight = false
        guard code == 200, let enterData, let chatroomEnter = symbols?.chatroomEnter else {
            pendingChatroomID = nil
            let sink = eventSink
            lock.unlock()
            sink?(.chatroomRequestFailed(Int(code)))
            return
        }
        activeChatroomID = roomID
        lock.unlock()

        let accepted = chatroomEnter(roomID, enterData, nil, nil)

        guard !accepted else { return }
        lock.lock()
        guard owner != nil, activeChatroomID == roomID else {
            lock.unlock()
            return
        }
        activeChatroomID = nil
        pendingChatroomID = nil
        let sink = eventSink
        lock.unlock()
        sink?(.chatroomRequestFailed(0))
    }

    fileprivate func finishChatroomEnter(roomID: Int64, step: Int32, code: Int32) {
        lock.lock()
        guard owner != nil, activeChatroomID == roomID else {
            lock.unlock()
            return
        }
        if step >= 3, code != 200 {
            activeChatroomID = nil
            pendingChatroomID = nil
        } else if step == 5, code == 200 {
            pendingChatroomID = nil
        }
        let sink = eventSink
        lock.unlock()
        sink?(.chatroomEnter(step: Int(step), code: Int(code)))
    }

    fileprivate func finishChatroomExit(roomID: Int64) {
        lock.lock()
        guard activeChatroomID == roomID else {
            lock.unlock()
            return
        }
        activeChatroomID = nil
        pendingChatroomID = nil
        let sink = eventSink
        lock.unlock()
        sink?(.disconnected)
    }

    fileprivate func finishChatroomLink(roomID: Int64, condition: Int32) {
        guard condition == 2 else { return }
        finishChatroomExit(roomID: roomID)
    }

    private func initializeIfNeeded() throws {
        lock.lock()
        if initialized {
            lock.unlock()
            return
        }
        lock.unlock()

        guard let urls = NIMChatroomTransport.bundledNativeSDKURLs() else {
            throw NIMChatroomError.unavailable
        }

        lock.lock()
        let existingSymbols = symbols
        let existingHandles = handles
        lock.unlock()

        let loadedSymbols: NIMNativeSymbols
        let loadedHandles: [UnsafeMutableRawPointer]
        if let existingSymbols, existingHandles.count == 3 {
            loadedSymbols = existingSymbols
            loadedHandles = existingHandles
        } else {
            var newHandles: [UnsafeMutableRawPointer] = []
            for url in urls {
                guard let handle = dlopen(url.path, RTLD_NOW | RTLD_GLOBAL) else {
                    throw NIMChatroomError.unavailable
                }
                newHandles.append(handle)
            }
            guard newHandles.count == 3 else { throw NIMChatroomError.unavailable }
            loadedHandles = newHandles
            loadedSymbols = try NIMNativeSymbols(
                clientHandle: newHandles[1],
                chatroomHandle: newHandles[2]
            )
        }

        let dataDirectory = try Self.dataDirectory()
        let config: [String: Any] = [
            "app_key": NIMChatroomTransport.initializationAppKey,
            "global_config": [
                "app_key": NIMChatroomTransport.initializationAppKey,
                "db_encrypt_key": NIMChatroomTransport.initializationAppKey
            ]
        ]
        let configData = try JSONSerialization.data(withJSONObject: config)
        guard let configJSON = String(data: configData, encoding: .utf8) else {
            throw NIMChatroomError.unavailable
        }
        let dataPath = dataDirectory.path + "/"
        let didInitialize = dataPath.withCString { dataPointer in
            configJSON.withCString { configPointer in
                loadedSymbols.clientInit(dataPointer, nil, configPointer)
            }
        }
        guard didInitialize else { throw NIMChatroomError.unavailable }

        let context = Unmanaged.passUnretained(self).toOpaque()
        "".withCString {
            loadedSymbols.chatroomInit($0)
            loadedSymbols.registerChatroomEnter($0, nimChatroomEnterCallback, context)
            loadedSymbols.registerChatroomExit($0, nimChatroomExitCallback, context)
            loadedSymbols.registerChatroomLink($0, nimChatroomLinkCallback, context)
            loadedSymbols.registerChatroomMessage($0, nimChatroomMessageCallback, context)
            loadedSymbols.registerChatroomNotification($0, nimChatroomMessageCallback, context)
            loadedSymbols.registerHTTPMessage(nimHTTPMessageCallback, $0, context)
            loadedSymbols.registerMessage($0, nimMessageCallback, context)
            loadedSymbols.registerBroadcast($0, nimMessageCallback, context)
            loadedSymbols.registerSystemMessage($0, nimSystemMessageCallback, context)
            loadedSymbols.registerPushEvent($0, nimPushEventCallback, context)
            loadedSymbols.registerDisconnect($0, nimClientDisconnectCallback, context)
            loadedSymbols.registerAutoRelogin($0, nimClientReloginCallback, context)
        }

        lock.lock()
        handles = loadedHandles
        symbols = loadedSymbols
        initialized = true
        lock.unlock()
    }

    private func currentSymbols() -> NIMNativeSymbols? {
        lock.lock()
        let value = symbols
        lock.unlock()
        return value
    }

    private static func dataDirectory() throws -> URL {
        let root: URL
        if let path = ProcessInfo.processInfo.environment[
            "TINYCLOUDMUSIC_LISTEN_TOGETHER_NIM_DATA_DIR"
        ], !path.isEmpty {
            root = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        } else {
            root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("TinyCloudMusic/NIMRealtime-v4", isDirectory: true)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}

private typealias NIMJSONCallback = @convention(c) (UnsafePointer<CChar>?, UnsafeRawPointer?) -> Void
private typealias NIMSystemMessageCallback = @convention(c) (
    UnsafePointer<CChar>?,
    UnsafePointer<CChar>?,
    UnsafeRawPointer?
) -> Void
private typealias NIMPushEventCallback = @convention(c) (
    Int32,
    UnsafePointer<CChar>?,
    UnsafePointer<CChar>?,
    UnsafeRawPointer?
) -> Void
private typealias NIMReceivedHTTPMessageCallback = @convention(c) (
    UnsafePointer<CChar>?,
    UnsafePointer<CChar>?,
    UInt64,
    UnsafeRawPointer?
) -> Void
private typealias NIMRegisterJSONCallback = @convention(c) (
    UnsafePointer<CChar>?,
    NIMJSONCallback?,
    UnsafeRawPointer?
) -> Void
private typealias NIMChatroomRequestEnterCallback = @convention(c) (
    Int32,
    UnsafePointer<CChar>?,
    UnsafePointer<CChar>?,
    UnsafeRawPointer?
) -> Void
private typealias NIMChatroomEnterCallback = @convention(c) (
    Int64,
    Int32,
    Int32,
    UnsafePointer<CChar>?,
    UnsafePointer<CChar>?,
    UnsafeRawPointer?
) -> Void
private typealias NIMChatroomExitCallback = @convention(c) (
    Int64,
    Int32,
    Int32,
    UnsafePointer<CChar>?,
    UnsafeRawPointer?
) -> Void
private typealias NIMChatroomMessageCallback = @convention(c) (
    Int64,
    UnsafePointer<CChar>?,
    UnsafePointer<CChar>?,
    UnsafeRawPointer?
) -> Void
private typealias NIMChatroomLinkCallback = @convention(c) (
    Int64,
    Int32,
    UnsafePointer<CChar>?,
    UnsafeRawPointer?
) -> Void
private typealias NIMRegisterChatroomEnterCallback = @convention(c) (
    UnsafePointer<CChar>?,
    NIMChatroomEnterCallback?,
    UnsafeRawPointer?
) -> Void
private typealias NIMRegisterChatroomExitCallback = @convention(c) (
    UnsafePointer<CChar>?,
    NIMChatroomExitCallback?,
    UnsafeRawPointer?
) -> Void
private typealias NIMRegisterChatroomMessageCallback = @convention(c) (
    UnsafePointer<CChar>?,
    NIMChatroomMessageCallback?,
    UnsafeRawPointer?
) -> Void
private typealias NIMRegisterChatroomLinkCallback = @convention(c) (
    UnsafePointer<CChar>?,
    NIMChatroomLinkCallback?,
    UnsafeRawPointer?
) -> Void

private struct NIMNativeSymbols: @unchecked Sendable {
    let clientInit: @convention(c) (
        UnsafePointer<CChar>?,
        UnsafePointer<CChar>?,
        UnsafePointer<CChar>?
    ) -> Bool
    let clientCleanup: @convention(c) (UnsafePointer<CChar>?) -> Void
    let clientLogin: @convention(c) (
        UnsafePointer<CChar>?,
        UnsafePointer<CChar>?,
        UnsafePointer<CChar>?,
        UnsafePointer<CChar>?,
        NIMJSONCallback?,
        UnsafeRawPointer?
    ) -> Void
    let clientLogout: @convention(c) (
        Int32,
        UnsafePointer<CChar>?,
        NIMJSONCallback?,
        UnsafeRawPointer?
    ) -> Void
    let clientLoginState: @convention(c) (UnsafePointer<CChar>?) -> Int32
    let registerSystemMessage: @convention(c) (
        UnsafePointer<CChar>?,
        NIMSystemMessageCallback?,
        UnsafeRawPointer?
    ) -> Void
    let registerMessage: @convention(c) (
        UnsafePointer<CChar>?,
        NIMSystemMessageCallback?,
        UnsafeRawPointer?
    ) -> Void
    let registerBroadcast: @convention(c) (
        UnsafePointer<CChar>?,
        NIMSystemMessageCallback?,
        UnsafeRawPointer?
    ) -> Void
    let registerPushEvent: @convention(c) (
        UnsafePointer<CChar>?,
        NIMPushEventCallback?,
        UnsafeRawPointer?
    ) -> Void
    let registerHTTPMessage: @convention(c) (
        NIMReceivedHTTPMessageCallback?,
        UnsafePointer<CChar>?,
        UnsafeRawPointer?
    ) -> Void
    let registerDisconnect: NIMRegisterJSONCallback
    let registerAutoRelogin: NIMRegisterJSONCallback
    let requestChatroomEnter: @convention(c) (
        Int64,
        UnsafePointer<CChar>?,
        NIMChatroomRequestEnterCallback?,
        UnsafeRawPointer?
    ) -> Void
    let chatroomInit: @convention(c) (UnsafePointer<CChar>?) -> Void
    let chatroomCleanup: @convention(c) (UnsafePointer<CChar>?) -> Void
    let registerChatroomEnter: NIMRegisterChatroomEnterCallback
    let registerChatroomExit: NIMRegisterChatroomExitCallback
    let registerChatroomLink: NIMRegisterChatroomLinkCallback
    let registerChatroomMessage: NIMRegisterChatroomMessageCallback
    let registerChatroomNotification: NIMRegisterChatroomMessageCallback
    let chatroomEnter: @convention(c) (
        Int64,
        UnsafePointer<CChar>?,
        UnsafePointer<CChar>?,
        UnsafePointer<CChar>?
    ) -> Bool
    let chatroomExit: @convention(c) (Int64, UnsafePointer<CChar>?) -> Void

    init(clientHandle: UnsafeMutableRawPointer, chatroomHandle: UnsafeMutableRawPointer) throws {
        clientInit = try Self.resolve("nim_client_init", from: clientHandle)
        clientCleanup = try Self.resolve("nim_client_cleanup", from: clientHandle)
        clientLogin = try Self.resolve("nim_client_login", from: clientHandle)
        clientLogout = try Self.resolve("nim_client_logout", from: clientHandle)
        clientLoginState = try Self.resolve("nim_client_get_login_state", from: clientHandle)
        registerMessage = try Self.resolve("nim_talk_reg_receive_cb", from: clientHandle)
        registerBroadcast = try Self.resolve("nim_talk_reg_receive_broadcast_cb", from: clientHandle)
        registerSystemMessage = try Self.resolve("nim_sysmsg_reg_sysmsg_cb", from: clientHandle)
        registerPushEvent = try Self.resolve("nim_subscribe_event_reg_push_event_cb", from: clientHandle)
        registerHTTPMessage = try Self.resolve("nim_reg_received_http_msg_cb", from: clientHandle)
        registerDisconnect = try Self.resolve("nim_client_reg_disconnect_cb", from: clientHandle)
        registerAutoRelogin = try Self.resolve("nim_client_reg_auto_relogin_cb", from: clientHandle)
        requestChatroomEnter = try Self.resolve(
            "nim_plugin_chatroom_request_enter_async",
            from: clientHandle
        )
        chatroomInit = try Self.resolve("nim_chatroom_init", from: chatroomHandle)
        chatroomCleanup = try Self.resolve("nim_chatroom_cleanup", from: chatroomHandle)
        registerChatroomEnter = try Self.resolve("nim_chatroom_reg_enter_cb", from: chatroomHandle)
        registerChatroomExit = try Self.resolve("nim_chatroom_reg_exit_cb", from: chatroomHandle)
        registerChatroomLink = try Self.resolve(
            "nim_chatroom_reg_link_condition_cb",
            from: chatroomHandle
        )
        registerChatroomMessage = try Self.resolve(
            "nim_chatroom_reg_receive_msg_cb",
            from: chatroomHandle
        )
        registerChatroomNotification = try Self.resolve(
            "nim_chatroom_reg_receive_notification_cb",
            from: chatroomHandle
        )
        chatroomEnter = try Self.resolve("nim_chatroom_enter", from: chatroomHandle)
        chatroomExit = try Self.resolve("nim_chatroom_exit", from: chatroomHandle)
    }

    private static func resolve<T>(_ name: String, from handle: UnsafeMutableRawPointer) throws -> T {
        guard let pointer = dlsym(handle, name) else { throw NIMChatroomError.unavailable }
        return unsafeBitCast(pointer, to: T.self)
    }
}

private func runtime(from pointer: UnsafeRawPointer?) -> NIMNativeRuntime? {
    pointer.map { Unmanaged<NIMNativeRuntime>.fromOpaque($0).takeUnretainedValue() }
}

private func string(from pointer: UnsafePointer<CChar>?) -> String {
    pointer.map(String.init(cString:)) ?? ""
}

private func nimClientLoginCallback(_ raw: UnsafePointer<CChar>?, _ context: UnsafeRawPointer?) {
    runtime(from: context)?.emit(.login(string(from: raw)))
}

private func nimChatroomRequestEnterCallback(
    _ code: Int32,
    _ enterData: UnsafePointer<CChar>?,
    _: UnsafePointer<CChar>?,
    _ context: UnsafeRawPointer?
) {
    runtime(from: context)?.finishChatroomRequest(code: code, enterData: enterData)
}

private func nimChatroomEnterCallback(
    _ roomID: Int64,
    _ step: Int32,
    _ code: Int32,
    _: UnsafePointer<CChar>?,
    _: UnsafePointer<CChar>?,
    _ context: UnsafeRawPointer?
) {
    runtime(from: context)?.finishChatroomEnter(roomID: roomID, step: step, code: code)
}

private func nimChatroomExitCallback(
    _ roomID: Int64,
    _: Int32,
    _: Int32,
    _: UnsafePointer<CChar>?,
    _ context: UnsafeRawPointer?
) {
    runtime(from: context)?.finishChatroomExit(roomID: roomID)
}

private func nimChatroomLinkCallback(
    _ roomID: Int64,
    _ condition: Int32,
    _: UnsafePointer<CChar>?,
    _ context: UnsafeRawPointer?
) {
    runtime(from: context)?.finishChatroomLink(roomID: roomID, condition: condition)
}

private func nimChatroomMessageCallback(
    _ roomID: Int64,
    _ result: UnsafePointer<CChar>?,
    _: UnsafePointer<CChar>?,
    _ context: UnsafeRawPointer?
) {
    runtime(from: context)?.emitChatroomMessage(roomID: roomID, raw: string(from: result))
}

private func nimSystemMessageCallback(
    _ result: UnsafePointer<CChar>?,
    _: UnsafePointer<CChar>?,
    _ context: UnsafeRawPointer?
) {
    runtime(from: context)?.emit(.message(string(from: result)))
}

private func nimMessageCallback(
    _ result: UnsafePointer<CChar>?,
    _: UnsafePointer<CChar>?,
    _ context: UnsafeRawPointer?
) {
    runtime(from: context)?.emit(.message(string(from: result)))
}

private func nimPushEventCallback(
    _ code: Int32,
    _ result: UnsafePointer<CChar>?,
    _: UnsafePointer<CChar>?,
    _ context: UnsafeRawPointer?
) {
    guard code == 200 else { return }
    runtime(from: context)?.emit(.message(string(from: result)))
}

private func nimHTTPMessageCallback(
    _: UnsafePointer<CChar>?,
    _ body: UnsafePointer<CChar>?,
    _: UInt64,
    _ context: UnsafeRawPointer?
) {
    runtime(from: context)?.emit(.message(string(from: body)))
}

private func nimClientDisconnectCallback(_: UnsafePointer<CChar>?, _ context: UnsafeRawPointer?) {
    runtime(from: context)?.emit(.disconnected)
}

private func nimClientReloginCallback(_ raw: UnsafePointer<CChar>?, _ context: UnsafeRawPointer?) {
    runtime(from: context)?.emit(.login(string(from: raw)))
}
