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
protocol NIMRuntime: AnyObject {
    func activate(
        owner: UUID,
        generation: UInt64,
        eventSink: @escaping @Sendable (NIMNativeEvent) -> Void
    ) async throws
    func deactivate(owner: UUID, generation: UInt64)
    func prepareChatroom(roomID: Int64, owner: UUID, generation: UInt64) throws
    func login(
        appKey: String,
        accountID: String,
        token: String,
        owner: UUID,
        generation: UInt64
    ) throws
    func requestChatroomEnter(owner: UUID, generation: UInt64) throws
    func disconnect(owner: UUID, generation: UInt64) async
    func reserveShutdown(owner: UUID) -> Bool
    func shutdown(owner: UUID) async
}

@MainActor
final class NIMChatroomTransport {
    var onEvent: ((NIMChatroomEvent) -> Void)?

    nonisolated static let sdkVersion = "10.9.40"
    nonisolated fileprivate static let initializationAppKey = "3a6a3e48f6854dfa4e4464f3bdaec3b4"
    nonisolated private static let loginAppKey = initializationAppKey
    private static let connectionTimeout: Duration = .seconds(20)

    private let ownerID = UUID()
    private let runtime: any NIMRuntime
    private let connectionTimeout: Duration
    private var nextOperationGeneration: UInt64 = 0
    private var activeOperationGeneration: UInt64?
    private var sessionGeneration: Int?
    private var connectContinuation: CheckedContinuation<Void, Error>?
    private var timeoutTask: Task<Void, Never>?
    private var teardownTask: Task<Void, Never>?
    private var teardownTaskID: UUID?
    private var isDisconnecting = false
    private var isTerminal = false
    private var shutdownTask: Task<Void, Never>?
    var beforeConnectCancellation: ((UInt64) async -> Void)?
    var afterConnectCancellation: ((UInt64) -> Void)?
    var afterNativeEvent: ((UInt64) -> Void)?

    init() {
        runtime = NIMNativeRuntime.shared
        connectionTimeout = Self.connectionTimeout
    }

    init(runtime: any NIMRuntime, connectionTimeout: Duration = .seconds(20)) {
        self.runtime = runtime
        self.connectionTimeout = connectionTimeout
    }

    func connect(
        roomID: String,
        credentials: ListenTogetherRealtimeCredentials,
        generation: Int
    ) async throws {
        guard !isTerminal else { throw NIMChatroomError.unavailable }
        guard let nativeRoomID = Int64(roomID), nativeRoomID > 0 else {
            throw NIMChatroomError.connectionFailed(stage: "room-id")
        }
        await disconnectCurrent()
        guard !isTerminal else { throw NIMChatroomError.unavailable }
        try Task.checkCancellation()
        let operationGeneration = reserveOperationGeneration()
        activeOperationGeneration = operationGeneration
        sessionGeneration = generation
        isDisconnecting = false

        do {
            try await runtime.activate(owner: ownerID, generation: operationGeneration) { [weak self] event in
                Task { @MainActor [weak self] in
                    await self?.receive(
                        event,
                        operationGeneration: operationGeneration,
                        sessionGeneration: generation
                    )
                }
            }
            guard !isTerminal else { throw NIMChatroomError.unavailable }
            try runtime.prepareChatroom(
                roomID: nativeRoomID,
                owner: ownerID,
                generation: operationGeneration
            )
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    connectContinuation = continuation
                    do {
                        try runtime.login(
                            appKey: Self.loginAppKey,
                            accountID: credentials.accountID,
                            token: credentials.token,
                            owner: ownerID,
                            generation: operationGeneration
                        )
                        timeoutTask = Task { @MainActor [weak self, connectionTimeout] in
                            do {
                                try await Task.sleep(for: connectionTimeout)
                            } catch {
                                return
                            }
                            await self?.finishConnect(.failure(
                                NIMChatroomError.connectionFailed(stage: "timeout")
                            ), operationGeneration: operationGeneration)
                        }
                    } catch {
                        Task { @MainActor [weak self] in
                            await self?.finishConnect(
                                .failure(error),
                                operationGeneration: operationGeneration
                            )
                        }
                    }
                }
            } onCancel: {
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    await self.beforeConnectCancellation?(operationGeneration)
                    await self.cancelConnect(operationGeneration: operationGeneration)
                    self.afterConnectCancellation?(operationGeneration)
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
        if let shutdownTask {
            await shutdownTask.value
            return
        }
        isTerminal = true
        let ownsRuntimeShutdown = runtime.reserveShutdown(owner: ownerID)
        let task = Task { @MainActor [self] in
            await disconnectCurrent()
            await waitForNativeTeardown()
            if ownsRuntimeShutdown { await runtime.shutdown(owner: ownerID) }
        }
        shutdownTask = task
        await task.value
    }

    private func disconnectCurrent() async {
        await waitForNativeTeardown()
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
        isDisconnecting = true
        timeoutTask?.cancel()
        timeoutTask = nil
        let continuation = connectContinuation
        connectContinuation = nil
        let taskID = UUID()
        let task = Task { @MainActor [ownerID, runtime] in
            await runtime.disconnect(owner: ownerID, generation: operationGeneration)
            runtime.deactivate(owner: ownerID, generation: operationGeneration)
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

    private func waitForNativeTeardown() async {
        if let teardownTask { await teardownTask.value }
    }

    nonisolated static func bundledNativeSDKURLs() -> [URL]? {
        let names = ["libh_available", "libnim", "libnim_chatroom"]
        let urls = names.compactMap {
            Bundle.module.url(forResource: $0, withExtension: "dylib", subdirectory: "NIMNative")
        }
        return urls.count == names.count ? urls : nil
    }

    private func receive(
        _ event: NIMNativeEvent,
        operationGeneration: UInt64,
        sessionGeneration: Int
    ) async {
        defer { afterNativeEvent?(operationGeneration) }
        guard activeOperationGeneration == operationGeneration,
              self.sessionGeneration == sessionGeneration
        else { return }
        switch event {
        case let .login(raw):
            guard let value = Self.object(from: raw),
                  let code = Self.integer(value["err_code"]),
                  let step = Self.integer(value["login_step"])
            else {
                await finishConnect(
                    .failure(NIMChatroomError.connectionFailed(stage: "nim-login-response")),
                    operationGeneration: operationGeneration
                )
                return
            }
            if code == 200, step == 3 {
                do {
                    try runtime.requestChatroomEnter(
                        owner: ownerID,
                        generation: operationGeneration
                    )
                } catch {
                    await finishConnect(.failure(error), operationGeneration: operationGeneration)
                }
            } else if code != 200, step >= 3 {
                if connectContinuation != nil {
                    await finishConnect(
                        .failure(NIMChatroomError.connectionFailed(stage: "nim-login-\(code)")),
                        operationGeneration: operationGeneration
                    )
                } else if !isDisconnecting {
                    onEvent?(.status(0, generation: sessionGeneration))
                }
            }

        case let .chatroomEnter(step, code):
            if code == 200, step == 5 {
                await finishConnect(.success(()), operationGeneration: operationGeneration)
                onEvent?(.status(5, generation: sessionGeneration))
            } else if code != 200, step >= 3 {
                if connectContinuation != nil {
                    await finishConnect(.failure(
                        NIMChatroomError.connectionFailed(stage: "chatroom-enter-\(code)")
                    ), operationGeneration: operationGeneration)
                } else if !isDisconnecting {
                    onEvent?(.status(0, generation: sessionGeneration))
                }
            }

        case let .chatroomRequestFailed(code):
            await finishConnect(.failure(
                NIMChatroomError.connectionFailed(stage: "chatroom-request-\(code)")
            ), operationGeneration: operationGeneration)

        case let .message(raw):
            guard raw.utf8.count <= 65_536 else { return }
            onEvent?(.message(raw: raw, generation: sessionGeneration))

        case .disconnected:
            guard !isDisconnecting else { return }
            onEvent?(.status(0, generation: sessionGeneration))
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

    func cancelConnect(operationGeneration: UInt64) async {
        await finishConnect(
            .failure(CancellationError()),
            operationGeneration: operationGeneration
        )
    }

    private func reserveOperationGeneration() -> UInt64 {
        nextOperationGeneration += 1
        return nextOperationGeneration
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

enum NIMNativeEvent: Sendable {
    case login(String)
    case chatroomEnter(step: Int, code: Int)
    case chatroomRequestFailed(Int)
    case message(String)
    case disconnected
}

@MainActor
final class NIMNativeRuntime: NIMRuntime {
    static let shared = NIMNativeRuntime()

    private static let chatroomExitTimeout: Duration = .seconds(5)
    private static let logoutTimeout: Duration = .seconds(20)
    private static let cleanupTimeout: Duration = .seconds(5)

    private var owner: UUID?
    private var ownerGeneration: UInt64?
    private var eventSink: (@Sendable (NIMNativeEvent) -> Void)?
    private var symbols: NIMNativeSymbols?
    private var handles: [UnsafeMutableRawPointer] = []
    private var callbackContext: NIMNativeCallbackContext?
    private var retainedCallbackContexts: [NIMNativeCallbackContext] = []
    private var initialized = false
    private var pendingChatroomID: Int64?
    private var activeChatroomID: Int64?
    private var isChatroomRequestInFlight = false
    private var exitWait: NIMChatroomExitWait?
    private var logoutWait: (owner: UUID, generation: UInt64, waiter: NIMCallbackWaiter)?
    private var cleanupWaiter: NIMCallbackWaiter?
    private var finalized = false
    private var shutdownOwner: UUID?
    private var shutdownTask: Task<Void, Never>?

    init() {}

    func activate(
        owner: UUID,
        generation: UInt64,
        eventSink: @escaping @Sendable (NIMNativeEvent) -> Void
    ) async throws {
        try beginActivation(owner: owner, generation: generation, eventSink: eventSink)
        try initializeIfNeeded(owner: owner, generation: generation)
    }

    func beginActivation(
        owner: UUID,
        generation: UInt64,
        eventSink: @escaping @Sendable (NIMNativeEvent) -> Void
    ) throws {
        guard !finalized else { throw NIMChatroomError.unavailable }
        guard self.owner == nil || self.owner == owner else {
            throw NIMChatroomError.connectionFailed(stage: "native-sdk-busy")
        }
        self.owner = owner
        ownerGeneration = generation
        self.eventSink = eventSink
    }

    func deactivate(owner: UUID, generation: UInt64) {
        guard self.owner == owner, ownerGeneration == generation else { return }
        callbackContext?.stopAcceptingCallbacks()
        self.owner = nil
        ownerGeneration = nil
        eventSink = nil
        callbackContext = nil
        pendingChatroomID = nil
        activeChatroomID = nil
        isChatroomRequestInFlight = false
    }

    func prepareChatroom(roomID: Int64, owner: UUID, generation: UInt64) throws {
        guard self.owner == owner,
              ownerGeneration == generation,
              initialized
        else { throw NIMChatroomError.unavailable }
        pendingChatroomID = roomID
        activeChatroomID = nil
        isChatroomRequestInFlight = false
    }

    func login(
        appKey: String,
        accountID: String,
        token: String,
        owner: UUID,
        generation: UInt64
    ) throws {
        let login = self.owner == owner && ownerGeneration == generation
            ? symbols?.clientLogin
            : nil
        let context = self.owner == owner && ownerGeneration == generation
            ? callbackContext
            : nil
        guard let login, let context else { throw NIMChatroomError.unavailable }
        appKey.withCString { appKeyPointer in
            accountID.withCString { accountPointer in
                token.withCString { tokenPointer in
                    login(
                        appKeyPointer,
                        accountPointer,
                        tokenPointer,
                        nil,
                        nimClientLoginCallback,
                        Unmanaged.passUnretained(context).toOpaque()
                    )
                }
            }
        }
    }

    func requestChatroomEnter(owner: UUID, generation: UInt64) throws {
        guard self.owner == owner,
              ownerGeneration == generation,
              let roomID = pendingChatroomID,
              activeChatroomID == nil,
              !isChatroomRequestInFlight,
              let requestEnter = symbols?.requestChatroomEnter,
              let context = callbackContext
        else {
            throw NIMChatroomError.connectionFailed(stage: "chatroom-request-state")
        }
        isChatroomRequestInFlight = true

        requestEnter(
            roomID,
            nil,
            nimChatroomRequestEnterCallback,
            Unmanaged.passUnretained(context).toOpaque()
        )
    }

    func disconnect(owner: UUID, generation: UInt64) async {
        guard self.owner == owner,
              ownerGeneration == generation,
              initialized,
              let symbols,
              let context = callbackContext
        else { return }
        pendingChatroomID = nil
        isChatroomRequestInFlight = false

        await NIMNativeTeardownSequence.disconnect {
            guard let roomID = self.activeChatroomID else { return }
            _ = await self.waitForChatroomExit(
                roomID: roomID,
                owner: owner,
                generation: generation,
                timeout: Self.chatroomExitTimeout
            ) {
                "".withCString { symbols.chatroomExit(roomID, $0) }
            }
            if self.activeChatroomID == roomID { self.activeChatroomID = nil }
        } logout: {
            let waiter = NIMCallbackWaiter()
            self.logoutWait = (owner, generation, waiter)
            _ = await waiter.wait(timeout: Self.logoutTimeout) {
                "".withCString {
                    symbols.clientLogout(
                        1,
                        $0,
                        nimClientLogoutCallback,
                        Unmanaged.passUnretained(context).toOpaque()
                    )
                }
            }
            if self.logoutWait?.waiter === waiter { self.logoutWait = nil }
        }

        guard self.owner == owner,
              ownerGeneration == generation,
              initialized
        else { return }
        context.stopAcceptingCallbacks()
        await cleanup(symbols)
    }

    func reserveShutdown(owner: UUID) -> Bool {
        if let shutdownOwner { return shutdownOwner == owner }
        guard self.owner == nil || self.owner == owner else { return false }
        shutdownOwner = owner
        finalized = true
        return true
    }

    func shutdown(owner: UUID) async {
        guard shutdownOwner == owner else { return }
        if let shutdownTask {
            await shutdownTask.value
            return
        }
        let task = Task { @MainActor [self] in await performShutdown() }
        shutdownTask = task
        await task.value
    }

    private func performShutdown() async {
        guard initialized, let symbols else { return }

        await cleanup(symbols)
    }

    private func cleanup(_ symbols: NIMNativeSymbols) async {
        await NIMNativeTeardownSequence.shutdown {
            "".withCString { symbols.chatroomCleanup($0) }
        } cleanupClient: {
            _ = await self.waitForClientCleanup(timeout: Self.cleanupTimeout) { context in
                "".withCString {
                    symbols.clientCleanup2(
                        nimClientCleanupCallback,
                        $0,
                        Unmanaged.passUnretained(context).toOpaque()
                    )
                }
            }
        }
        initialized = false
    }

    func waitForChatroomExit(
        roomID: Int64,
        owner: UUID,
        generation: UInt64,
        timeout: Duration,
        start: () -> Void
    ) async -> NIMChatroomExitOutcome? {
        let pending = NIMChatroomExitWait(
            roomID: roomID,
            owner: owner,
            generation: generation
        )
        exitWait = pending
        _ = await pending.waiter.wait(timeout: timeout, start: start)
        if exitWait === pending { exitWait = nil }
        return pending.outcome
    }

    func waitForClientCleanup(
        timeout: Duration,
        start: (NIMNativeCallbackContext) -> Void
    ) async -> NIMCallbackWaitResult {
        let context = NIMNativeCallbackContext(runtime: self, owner: UUID(), generation: 0)
        retainCallbackContext(context)
        let waiter = NIMCallbackWaiter()
        cleanupWaiter = waiter
        let result = await waiter.wait(timeout: timeout) { start(context) }
        if cleanupWaiter === waiter { cleanupWaiter = nil }
        context.stopAcceptingCallbacks()
        return result
    }

    func retainCallbackContext(_ context: NIMNativeCallbackContext) {
        retainedCallbackContexts.append(context)
    }

    fileprivate func emit(_ event: NIMNativeEvent, owner: UUID, generation: UInt64) {
        let sink = self.owner == owner && ownerGeneration == generation ? eventSink : nil
        sink?(event)
    }

    fileprivate func emitChatroomMessage(
        roomID: Int64,
        raw: String,
        owner: UUID,
        generation: UInt64
    ) {
        let sink = self.owner == owner
            && ownerGeneration == generation
            && activeChatroomID == roomID
            ? eventSink
            : nil
        sink?(.message(raw))
    }

    fileprivate func finishChatroomRequest(
        code: Int32,
        enterData: String?,
        owner: UUID,
        generation: UInt64
    ) {
        guard self.owner == owner,
              ownerGeneration == generation,
              let roomID = pendingChatroomID,
              activeChatroomID == nil
        else { return }
        isChatroomRequestInFlight = false
        guard code == 200, let enterData, let chatroomEnter = symbols?.chatroomEnter else {
            pendingChatroomID = nil
            eventSink?(.chatroomRequestFailed(Int(code)))
            return
        }
        activeChatroomID = roomID

        let accepted = enterData.withCString { chatroomEnter(roomID, $0, nil, nil) }

        guard !accepted else { return }
        guard self.owner == owner,
              ownerGeneration == generation,
              activeChatroomID == roomID
        else { return }
        activeChatroomID = nil
        pendingChatroomID = nil
        eventSink?(.chatroomRequestFailed(0))
    }

    fileprivate func finishChatroomEnter(
        roomID: Int64,
        step: Int32,
        code: Int32,
        owner: UUID,
        generation: UInt64
    ) {
        guard self.owner == owner,
              ownerGeneration == generation,
              activeChatroomID == roomID
        else { return }
        if step >= 3, code != 200 {
            activeChatroomID = nil
            pendingChatroomID = nil
        } else if step == 5, code == 200 {
            pendingChatroomID = nil
        }
        eventSink?(.chatroomEnter(step: Int(step), code: Int(code)))
    }

    fileprivate func finishChatroomExit(
        _ outcome: NIMChatroomExitOutcome,
        owner: UUID,
        generation: UInt64
    ) {
        if let exitWait,
           exitWait.roomID == outcome.roomID,
           exitWait.owner == owner,
           exitWait.generation == generation {
            exitWait.resume(outcome)
        }
        guard self.owner == owner,
              ownerGeneration == generation,
              activeChatroomID == outcome.roomID
        else { return }
        activeChatroomID = nil
        pendingChatroomID = nil
        eventSink?(.disconnected)
    }

    fileprivate func finishChatroomLink(
        roomID: Int64,
        condition: Int32,
        owner: UUID,
        generation: UInt64
    ) {
        guard condition == 2,
              self.owner == owner,
              ownerGeneration == generation,
              activeChatroomID == roomID
        else { return }
        activeChatroomID = nil
        pendingChatroomID = nil
        eventSink?(.disconnected)
    }

    fileprivate func finishLogout(owner: UUID, generation: UInt64) {
        guard let logoutWait,
              logoutWait.owner == owner,
              logoutWait.generation == generation
        else { return }
        logoutWait.waiter.resume()
    }

    fileprivate func finishCleanup() {
        cleanupWaiter?.resume()
    }

    private func initializeIfNeeded(owner: UUID, generation: UInt64) throws {
        if initialized {
            guard let symbols else { throw NIMChatroomError.unavailable }
            try installCallbacks(symbols, owner: owner, generation: generation)
            return
        }

        guard let urls = NIMChatroomTransport.bundledNativeSDKURLs() else {
            throw NIMChatroomError.unavailable
        }

        let existingSymbols = symbols
        let existingHandles = handles

        let loadedSymbols: NIMNativeSymbols
        let loadedHandles: [UnsafeMutableRawPointer]
        if let existingSymbols, existingHandles.count == 3 {
            loadedSymbols = existingSymbols
            loadedHandles = existingHandles
            try initialize(loadedSymbols, owner: owner, generation: generation)
        } else {
            let loaded = try NIMLibraryLoadTransaction.run(
                items: urls,
                open: { dlopen($0.path, RTLD_NOW | RTLD_GLOBAL) },
                close: { dlclose($0) }
            ) { newHandles in
                guard newHandles.count == 3 else { throw NIMChatroomError.unavailable }
                let newSymbols = try NIMNativeSymbols(
                    clientHandle: newHandles[1],
                    chatroomHandle: newHandles[2]
                )
                try initialize(newSymbols, owner: owner, generation: generation)
                return (newHandles, newSymbols)
            }
            loadedHandles = loaded.0
            loadedSymbols = loaded.1
        }

        handles = loadedHandles
        symbols = loadedSymbols
        initialized = true
    }

    private func initialize(
        _ loadedSymbols: NIMNativeSymbols,
        owner: UUID,
        generation: UInt64
    ) throws {
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
        try NIMClientInitializationTransaction.run(
            initialized: didInitialize,
            cleanup: { "".withCString { loadedSymbols.clientCleanup($0) } }
        ) {
            "".withCString {
                loadedSymbols.chatroomInit($0)
            }
            try installCallbacks(loadedSymbols, owner: owner, generation: generation)
        }
    }

    private func installCallbacks(
        _ symbols: NIMNativeSymbols,
        owner: UUID,
        generation: UInt64
    ) throws {
        let callbackContext = try installCallbackContext(owner: owner, generation: generation)
        let context = Unmanaged.passUnretained(callbackContext).toOpaque()
        "".withCString {
            symbols.registerChatroomEnter($0, nimChatroomEnterCallback, context)
            symbols.registerChatroomExit($0, nimChatroomExitCallback, context)
            symbols.registerChatroomLink($0, nimChatroomLinkCallback, context)
            symbols.registerChatroomMessage($0, nimChatroomMessageCallback, context)
            symbols.registerChatroomNotification($0, nimChatroomMessageCallback, context)
            symbols.registerHTTPMessage(nimHTTPMessageCallback, $0, context)
            symbols.registerMessage($0, nimMessageCallback, context)
            symbols.registerBroadcast($0, nimMessageCallback, context)
            symbols.registerSystemMessage($0, nimSystemMessageCallback, context)
            symbols.registerPushEvent($0, nimPushEventCallback, context)
            symbols.registerDisconnect($0, nimClientDisconnectCallback, context)
            symbols.registerAutoRelogin($0, nimClientReloginCallback, context)
        }
    }

    func installCallbackContext(
        owner: UUID,
        generation: UInt64
    ) throws -> NIMNativeCallbackContext {
        guard self.owner == owner, ownerGeneration == generation else {
            throw CancellationError()
        }
        callbackContext?.stopAcceptingCallbacks()
        let callbackContext = NIMNativeCallbackContext(
            runtime: self,
            owner: owner,
            generation: generation
        )
        self.callbackContext = callbackContext
        // ponytail: retain callback contexts for process lifetime until the vendor proves quiescence.
        retainCallbackContext(callbackContext)
        return callbackContext
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

@MainActor
final class NIMCallbackWaiter {
    private var continuation: CheckedContinuation<NIMCallbackWaitResult, Never>?
    private var timeoutTask: Task<Void, Never>?

    func wait(timeout: Duration, start: () -> Void) async -> NIMCallbackWaitResult {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            timeoutTask = Task { @MainActor [weak self] in
                do {
                    try await Task.sleep(for: timeout)
                } catch {
                    return
                }
                self?.finish(.timeout)
            }
            start()
        }
    }

    func resume() {
        finish(.callback)
    }

    private func finish(_ result: NIMCallbackWaitResult) {
        timeoutTask?.cancel()
        timeoutTask = nil
        let continuation = continuation
        self.continuation = nil
        continuation?.resume(returning: result)
    }
}

enum NIMCallbackWaitResult: Equatable, Sendable {
    case callback
    case timeout
}

struct NIMChatroomExitOutcome: Equatable, Sendable {
    let roomID: Int64
    let errorCode: Int32
    let exitType: Int32
}

@MainActor
private final class NIMChatroomExitWait {
    let roomID: Int64
    let owner: UUID
    let generation: UInt64
    let waiter = NIMCallbackWaiter()
    private(set) var outcome: NIMChatroomExitOutcome?

    init(roomID: Int64, owner: UUID, generation: UInt64) {
        self.roomID = roomID
        self.owner = owner
        self.generation = generation
    }

    func resume(_ outcome: NIMChatroomExitOutcome) {
        guard self.outcome == nil else { return }
        self.outcome = outcome
        waiter.resume()
    }
}

enum NIMNativeTeardownSequence {
    @MainActor
    static func disconnect(
        exit: @MainActor () async -> Void,
        logout: @MainActor () async -> Void
    ) async {
        await exit()
        await logout()
    }

    @MainActor
    static func shutdown(
        cleanupChatroom: @MainActor () -> Void,
        cleanupClient: @MainActor () async -> Void
    ) async {
        cleanupChatroom()
        await cleanupClient()
    }
}

enum NIMLibraryLoadTransaction {
    static func run<Item, Handle, Output>(
        items: [Item],
        open: (Item) -> Handle?,
        close: (Handle) -> Void,
        body: ([Handle]) throws -> Output
    ) throws -> Output {
        var handles: [Handle] = []
        var committed = false
        defer {
            if !committed {
                for handle in handles.reversed() { close(handle) }
            }
        }
        for item in items {
            guard let handle = open(item) else { throw NIMChatroomError.unavailable }
            handles.append(handle)
        }
        let output = try body(handles)
        committed = true
        return output
    }
}

enum NIMClientInitializationTransaction {
    static func run<Output>(
        initialized: Bool,
        cleanup: () -> Void,
        body: () throws -> Output
    ) throws -> Output {
        guard initialized else { throw NIMChatroomError.unavailable }
        do {
            return try body()
        } catch {
            cleanup()
            throw error
        }
    }
}

final class NIMNativeCallbackContext: @unchecked Sendable {
    private let lock = NSLock()
    private weak var runtime: NIMNativeRuntime?
    private var acceptingCallbacks = true
    let owner: UUID
    let generation: UInt64

    init(runtime: NIMNativeRuntime, owner: UUID, generation: UInt64) {
        self.runtime = runtime
        self.owner = owner
        self.generation = generation
    }

    func isAcceptingCallbacks() -> Bool {
        lock.withLock { acceptingCallbacks }
    }

    func stopAcceptingCallbacks() {
        lock.withLock { acceptingCallbacks = false }
    }

    func copyString(from pointer: UnsafePointer<CChar>?) -> String? {
        lock.withLock {
            guard acceptingCallbacks else { return nil }
            return NIMNativeString.copy(from: pointer)
        }
    }

    func emit(_ event: NIMNativeEvent) {
        submit { runtime in
            runtime.emit(event, owner: self.owner, generation: self.generation)
        }
    }

    func emitChatroomMessage(roomID: Int64, raw: String) {
        submit { runtime in
            runtime.emitChatroomMessage(
                roomID: roomID,
                raw: raw,
                owner: self.owner,
                generation: self.generation
            )
        }
    }

    func finishChatroomRequest(code: Int32, enterData: String?) {
        submit { runtime in
            runtime.finishChatroomRequest(
                code: code,
                enterData: enterData,
                owner: self.owner,
                generation: self.generation
            )
        }
    }

    func finishChatroomEnter(roomID: Int64, step: Int32, code: Int32) {
        submit { runtime in
            runtime.finishChatroomEnter(
                roomID: roomID,
                step: step,
                code: code,
                owner: self.owner,
                generation: self.generation
            )
        }
    }

    func finishChatroomExit(_ outcome: NIMChatroomExitOutcome) {
        submit { runtime in
            runtime.finishChatroomExit(
                outcome,
                owner: self.owner,
                generation: self.generation
            )
        }
    }

    func finishChatroomLink(roomID: Int64, condition: Int32) {
        submit { runtime in
            runtime.finishChatroomLink(
                roomID: roomID,
                condition: condition,
                owner: self.owner,
                generation: self.generation
            )
        }
    }

    func finishLogout() {
        submit { runtime in
            runtime.finishLogout(owner: self.owner, generation: self.generation)
        }
    }

    func finishCleanup() {
        submit { runtime in runtime.finishCleanup() }
    }

    private func submit(
        _ operation: @escaping @MainActor @Sendable (NIMNativeRuntime) -> Void
    ) {
        guard isAcceptingCallbacks() else { return }
        Task { @MainActor [weak runtime] in
            guard self.isAcceptingCallbacks(), let runtime else { return }
            operation(runtime)
        }
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
    let clientCleanup2: @convention(c) (
        NIMJSONCallback?,
        UnsafePointer<CChar>?,
        UnsafeRawPointer?
    ) -> Void
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
        clientCleanup2 = try Self.resolve("nim_client_cleanup2", from: clientHandle)
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

private func callbackContext(from pointer: UnsafeRawPointer?) -> NIMNativeCallbackContext? {
    pointer.map { Unmanaged<NIMNativeCallbackContext>.fromOpaque($0).takeUnretainedValue() }
}

enum NIMNativeString {
    static let maximumBytes = 65_536

    static func copy(from pointer: UnsafePointer<CChar>?) -> String? {
        guard let pointer else { return "" }
        // ponytail: local-only cap; vendor length, NUL, encoding, and lifetime remain unverified.
        let count = strnlen(pointer, maximumBytes + 1)
        guard count <= maximumBytes else { return nil }
        let bytes = UnsafeRawPointer(pointer).assumingMemoryBound(to: UInt8.self)
        return String(bytes: UnsafeBufferPointer(start: bytes, count: count), encoding: .utf8)
    }
}

private func nimClientLoginCallback(_ raw: UnsafePointer<CChar>?, _ context: UnsafeRawPointer?) {
    guard let context = callbackContext(from: context),
          let raw = context.copyString(from: raw)
    else {
        return
    }
    context.emit(.login(raw))
}

private func nimChatroomRequestEnterCallback(
    _ code: Int32,
    _ enterData: UnsafePointer<CChar>?,
    _: UnsafePointer<CChar>?,
    _ context: UnsafeRawPointer?
) {
    guard let context = callbackContext(from: context) else { return }
    if let enterData {
        guard let enterData = context.copyString(from: enterData) else { return }
        context.finishChatroomRequest(code: code, enterData: enterData)
    } else if context.isAcceptingCallbacks() {
        context.finishChatroomRequest(code: code, enterData: nil)
    }
}

private func nimChatroomEnterCallback(
    _ roomID: Int64,
    _ step: Int32,
    _ code: Int32,
    _: UnsafePointer<CChar>?,
    _: UnsafePointer<CChar>?,
    _ context: UnsafeRawPointer?
) {
    callbackContext(from: context)?.finishChatroomEnter(
        roomID: roomID,
        step: step,
        code: code
    )
}

func nimChatroomExitCallback(
    _ roomID: Int64,
    _ errorCode: Int32,
    _ exitType: Int32,
    _: UnsafePointer<CChar>?,
    _ context: UnsafeRawPointer?
) {
    let outcome = NIMChatroomExitOutcome(
        roomID: roomID,
        errorCode: errorCode,
        exitType: exitType
    )
    callbackContext(from: context)?.finishChatroomExit(outcome)
}

private func nimChatroomLinkCallback(
    _ roomID: Int64,
    _ condition: Int32,
    _: UnsafePointer<CChar>?,
    _ context: UnsafeRawPointer?
) {
    callbackContext(from: context)?.finishChatroomLink(
        roomID: roomID,
        condition: condition
    )
}

private func nimChatroomMessageCallback(
    _ roomID: Int64,
    _ result: UnsafePointer<CChar>?,
    _: UnsafePointer<CChar>?,
    _ context: UnsafeRawPointer?
) {
    guard let context = callbackContext(from: context),
          let result = context.copyString(from: result)
    else {
        return
    }
    context.emitChatroomMessage(roomID: roomID, raw: result)
}

private func nimSystemMessageCallback(
    _ result: UnsafePointer<CChar>?,
    _: UnsafePointer<CChar>?,
    _ context: UnsafeRawPointer?
) {
    guard let context = callbackContext(from: context),
          let result = context.copyString(from: result)
    else {
        return
    }
    context.emit(.message(result))
}

private func nimMessageCallback(
    _ result: UnsafePointer<CChar>?,
    _: UnsafePointer<CChar>?,
    _ context: UnsafeRawPointer?
) {
    guard let context = callbackContext(from: context),
          let result = context.copyString(from: result)
    else {
        return
    }
    context.emit(.message(result))
}

private func nimPushEventCallback(
    _ code: Int32,
    _ result: UnsafePointer<CChar>?,
    _: UnsafePointer<CChar>?,
    _ context: UnsafeRawPointer?
) {
    guard code == 200,
          let context = callbackContext(from: context),
          let result = context.copyString(from: result)
    else { return }
    context.emit(.message(result))
}

func nimHTTPMessageCallback(
    _: UnsafePointer<CChar>?,
    _ body: UnsafePointer<CChar>?,
    _ timestamp: UInt64,
    _ context: UnsafeRawPointer?
) {
    _ = timestamp
    guard let context = callbackContext(from: context),
          let body = context.copyString(from: body)
    else {
        return
    }
    context.emit(.message(body))
}

private func nimClientDisconnectCallback(
    _: UnsafePointer<CChar>?,
    _ context: UnsafeRawPointer?
) {
    callbackContext(from: context)?.emit(.disconnected)
}

private func nimClientReloginCallback(_ raw: UnsafePointer<CChar>?, _ context: UnsafeRawPointer?) {
    guard let context = callbackContext(from: context),
          let raw = context.copyString(from: raw)
    else {
        return
    }
    context.emit(.login(raw))
}

private func nimClientLogoutCallback(_: UnsafePointer<CChar>?, _ context: UnsafeRawPointer?) {
    callbackContext(from: context)?.finishLogout()
}

func nimClientCleanupCallback(_: UnsafePointer<CChar>?, _ context: UnsafeRawPointer?) {
    callbackContext(from: context)?.finishCleanup()
}
