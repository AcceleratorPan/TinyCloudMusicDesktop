import Foundation
import Testing
@testable import TinyCloudMusic

@Suite("NIM runtime boundary", .serialized)
@MainActor
struct NIMRuntimeBoundaryTests {
    @Test("A connecting replacement cancels and tears down only the old generation")
    func operationGenerationFencesReplacement() async throws {
        let runtime = FakeNIMRuntime()
        let transport = NIMChatroomTransport(
            runtime: runtime,
            connectionTimeout: .seconds(60)
        )
        let cancellationGate = NIMTestGate()
        let cancellationHandled = NIMTestSignal()
        transport.beforeConnectCancellation = { generation in
            #expect(generation == 1)
            await cancellationGate.wait()
        }
        transport.afterConnectCancellation = { generation in
            #expect(generation == 1)
            cancellationHandled.signal()
        }
        var events: [NIMChatroomEvent] = []
        transport.onEvent = { events.append($0) }

        let first = connect(transport, roomID: "1", generation: 1)
        await runtime.waitUntilActivated(generation: 1)
        first.cancel()
        await cancellationGate.waitUntilEntered()

        let second = connect(transport, roomID: "2", generation: 2)
        await runtime.waitUntilActivated(generation: 2)
        await expectCancellation(first)
        #expect(runtime.activations(generation: 1) == 1)
        #expect(runtime.activations(generation: 2) == 1)
        #expect(runtime.disconnects(generation: 1) == 1)
        #expect(runtime.deactivations(generation: 1) == 1)

        await completeConnect(runtime, generation: 2)
        try await second.value
        #expect(events == [.status(5, generation: 2)])
        await cancellationGate.open()
        await cancellationHandled.wait()
        #expect(runtime.isCurrent(generation: 2))
        #expect(runtime.disconnects(generation: 2) == 0)
        #expect(runtime.deactivations(generation: 2) == 0)

        await transport.disconnect(generation: 1)
        #expect(runtime.disconnects(generation: 1) == 1)
        await transport.disconnect(generation: 2)
        #expect(runtime.disconnects(generation: 2) == 1)
        #expect(runtime.deactivations(generation: 2) == 1)
    }

    @Test("Late callbacks and timeout from G1 cannot mutate connected G2")
    func staleCallbacksAndTimeoutAreGenerationFenced() async throws {
        let runtime = FakeNIMRuntime()
        let transport = NIMChatroomTransport(
            runtime: runtime,
            connectionTimeout: .milliseconds(10)
        )
        let firstTimeoutGate = NIMTestGate()
        let secondTimeoutGate = NIMTestGate()
        let timeoutsProcessed = NIMTestSignal(count: 2)
        let staleEventsProcessed = NIMTestSignal(count: 3)
        transport.beforeConnectTimeout = { generation in
            if generation == 1 { await firstTimeoutGate.wait() }
            if generation == 2 { await secondTimeoutGate.wait() }
        }
        transport.afterConnectTimeout = { _ in timeoutsProcessed.signal() }
        transport.afterNativeEvent = { generation in
            if generation == 1 { staleEventsProcessed.signal() }
        }
        var events: [NIMChatroomEvent] = []
        transport.onEvent = { events.append($0) }

        let first = connect(transport, roomID: "1", generation: 1)
        await runtime.waitUntilActivated(generation: 1)
        await firstTimeoutGate.waitUntilEntered()

        let second = connect(transport, roomID: "2", generation: 2)
        await runtime.waitUntilActivated(generation: 2)
        await expectCancellation(first)
        await secondTimeoutGate.waitUntilEntered()
        await completeConnect(runtime, generation: 2)
        try await second.value

        runtime.emit(.login(#"{"err_code":200,"login_step":3}"#), generation: 1)
        runtime.emit(.message("stale"), generation: 1)
        runtime.emit(.disconnected, generation: 1)
        await staleEventsProcessed.wait()
        #expect(runtime.enterRequests(generation: 1) == 0)
        #expect(events == [.status(5, generation: 2)])
        #expect(runtime.isCurrent(generation: 2))
        #expect(runtime.disconnects(generation: 2) == 0)
        #expect(runtime.deactivations(generation: 2) == 0)

        await firstTimeoutGate.open()
        await secondTimeoutGate.open()
        await timeoutsProcessed.wait()
        #expect(events == [.status(5, generation: 2)])
        #expect(runtime.isCurrent(generation: 2))
        #expect(runtime.disconnects(generation: 2) == 0)
        #expect(runtime.deactivations(generation: 2) == 0)

        await transport.disconnect(generation: 2)
        #expect(runtime.disconnects(generation: 2) == 1)
        #expect(runtime.deactivations(generation: 2) == 1)
    }

    @Test("Login request and enter failures each have one teardown owner")
    func failedConnectOwnsOneTeardown() async throws {
        let failures: [(NIMNativeEvent, String)] = [
            (.login(#"{"err_code":401,"login_step":3}"#), "nim-login-401"),
            (.chatroomRequestFailed(403), "chatroom-request-403"),
            (.chatroomEnter(step: 3, code: 500), "chatroom-enter-500")
        ]

        for (event, stage) in failures {
            let runtime = FakeNIMRuntime()
            let transport = NIMChatroomTransport(runtime: runtime, connectionTimeout: .seconds(60))
            let failed = connect(transport, roomID: "1", generation: 1)
            await runtime.waitUntilActivated(generation: 1)
            runtime.emit(event, generation: 1)
            await expectConnectionFailure(failed, stage: stage)
            #expect(runtime.activations(generation: 1) == 1)
            #expect(runtime.disconnects(generation: 1) == 1)
            #expect(runtime.deactivations(generation: 1) == 1)
            #expect(!runtime.isCurrent(generation: 1))

            let replacement = connect(transport, roomID: "2", generation: 2)
            await runtime.waitUntilActivated(generation: 2)
            await completeConnect(runtime, generation: 2)
            try await replacement.value
            #expect(runtime.disconnects(generation: 1) == 1)
            #expect(runtime.deactivations(generation: 1) == 1)
            await transport.disconnect(generation: 2)
            #expect(runtime.disconnects(generation: 2) == 1)
            #expect(runtime.deactivations(generation: 2) == 1)
        }
    }

    @Test("Synchronous runtime failures preserve their error and teardown once")
    func synchronousRuntimeFailures() async {
        for stage in FakeRuntimeFailureStage.allCases {
            let runtime = FakeNIMRuntime(failureStage: stage)
            let transport = NIMChatroomTransport(runtime: runtime, connectionTimeout: .seconds(60))
            let failed = connect(transport, roomID: "1", generation: 1)
            await runtime.waitUntilActivated(generation: 1)
            if stage == .requestEnter {
                runtime.emit(.login(#"{"err_code":200,"login_step":3}"#), generation: 1)
            }

            await expectConnectionFailure(failed, stage: stage.errorStage)
            #expect(runtime.activations(generation: 1) == 1)
            #expect(runtime.disconnects(generation: 1) == 1)
            #expect(runtime.deactivations(generation: 1) == 1)
            #expect(!runtime.isCurrent(generation: 1))
        }
    }

    @Test("Timeout and task cancellation each teardown once and allow reconnect")
    func timeoutAndCancellationTeardown() async throws {
        let timeoutRuntime = FakeNIMRuntime()
        let timeoutTransport = NIMChatroomTransport(
            runtime: timeoutRuntime,
            connectionTimeout: .milliseconds(20)
        )
        let timedOut = connect(timeoutTransport, roomID: "1", generation: 1)
        await timeoutRuntime.waitUntilActivated(generation: 1)
        await expectConnectionFailure(timedOut, stage: "timeout")
        #expect(timeoutRuntime.disconnects(generation: 1) == 1)
        #expect(timeoutRuntime.deactivations(generation: 1) == 1)

        let reconnect = connect(timeoutTransport, roomID: "2", generation: 2)
        await timeoutRuntime.waitUntilActivated(generation: 2)
        await completeConnect(timeoutRuntime, generation: 2)
        try await reconnect.value
        await timeoutTransport.disconnect(generation: 2)
        #expect(timeoutRuntime.disconnects(generation: 2) == 1)
        #expect(timeoutRuntime.deactivations(generation: 2) == 1)

        let cancellationRuntime = FakeNIMRuntime()
        let cancellationTransport = NIMChatroomTransport(
            runtime: cancellationRuntime,
            connectionTimeout: .seconds(60)
        )
        let cancelled = connect(cancellationTransport, roomID: "3", generation: 3)
        await cancellationRuntime.waitUntilActivated(generation: 1)
        cancelled.cancel()
        await expectCancellation(cancelled)
        #expect(cancellationRuntime.disconnects(generation: 1) == 1)
        #expect(cancellationRuntime.deactivations(generation: 1) == 1)
    }

    @Test("Cancel and timeout orderings retain one teardown owner")
    func cancelTimeoutOrderings() async {
        let cancellationRuntime = FakeNIMRuntime()
        let cancellationTransport = NIMChatroomTransport(
            runtime: cancellationRuntime,
            connectionTimeout: .milliseconds(40)
        )
        let cancelled = connect(cancellationTransport, roomID: "1", generation: 1)
        await cancellationRuntime.waitUntilActivated(generation: 1)
        cancelled.cancel()
        await expectCancellation(cancelled)
        let cancellationReplacement = connect(cancellationTransport, roomID: "2", generation: 2)
        await cancellationRuntime.waitUntilActivated(generation: 2)
        await completeConnect(cancellationRuntime, generation: 2)
        try? await cancellationReplacement.value
        #expect(cancellationRuntime.disconnects(generation: 1) == 1)
        #expect(cancellationRuntime.deactivations(generation: 1) == 1)
        #expect(cancellationRuntime.isCurrent(generation: 2))
        #expect(cancellationRuntime.disconnects(generation: 2) == 0)
        await cancellationTransport.disconnect(generation: 2)

        let timeoutRuntime = FakeNIMRuntime()
        let timeoutTransport = NIMChatroomTransport(
            runtime: timeoutRuntime,
            connectionTimeout: .milliseconds(20)
        )
        let timedOut = connect(timeoutTransport, roomID: "2", generation: 2)
        await timeoutRuntime.waitUntilActivated(generation: 1)
        await expectConnectionFailure(timedOut, stage: "timeout")
        let timeoutReplacement = connect(timeoutTransport, roomID: "3", generation: 3)
        await timeoutRuntime.waitUntilActivated(generation: 2)
        await completeConnect(timeoutRuntime, generation: 2)
        try? await timeoutReplacement.value
        timedOut.cancel()
        #expect(timeoutRuntime.disconnects(generation: 1) == 1)
        #expect(timeoutRuntime.deactivations(generation: 1) == 1)
        #expect(timeoutRuntime.isCurrent(generation: 2))
        #expect(timeoutRuntime.disconnects(generation: 2) == 0)
        await timeoutTransport.disconnect(generation: 3)

        let replacementRuntime = FakeNIMRuntime()
        let replacementTransport = NIMChatroomTransport(
            runtime: replacementRuntime,
            connectionTimeout: .seconds(60)
        )
        let old = connect(replacementTransport, roomID: "4", generation: 4)
        await replacementRuntime.waitUntilActivated(generation: 1)
        let current = connect(replacementTransport, roomID: "5", generation: 5)
        await replacementRuntime.waitUntilActivated(generation: 2)
        #expect(replacementRuntime.isCurrent(generation: 2))
        old.cancel()
        await expectCancellation(old)
        await completeConnect(replacementRuntime, generation: 2)
        try? await current.value
        #expect(replacementRuntime.disconnects(generation: 1) == 1)
        #expect(replacementRuntime.deactivations(generation: 1) == 1)
        #expect(replacementRuntime.isCurrent(generation: 2))
        #expect(replacementRuntime.disconnects(generation: 2) == 0)
        await replacementTransport.disconnect(generation: 5)
    }

    @Test("A connected session tears down once after repeated disconnects")
    func connectedDisconnectIsIdempotent() async throws {
        let runtime = FakeNIMRuntime()
        let transport = NIMChatroomTransport(runtime: runtime, connectionTimeout: .seconds(60))
        let staleEventsProcessed = NIMTestSignal(count: 2)
        transport.afterNativeEvent = { generation in
            if generation == 1 { staleEventsProcessed.signal() }
        }
        var events: [NIMChatroomEvent] = []
        transport.onEvent = { events.append($0) }

        let connected = connect(transport, roomID: "1", generation: 1)
        await runtime.waitUntilActivated(generation: 1)
        await completeConnect(runtime, generation: 1)
        try await connected.value
        #expect(runtime.activations(generation: 1) == 1)
        #expect(runtime.disconnects(generation: 1) == 0)
        #expect(runtime.deactivations(generation: 1) == 0)
        #expect(runtime.isCurrent(generation: 1))

        await transport.disconnect(generation: 2)
        #expect(runtime.disconnects(generation: 1) == 0)
        await transport.disconnect(generation: 1)
        await transport.disconnect(generation: 1)
        await transport.disconnect()
        #expect(runtime.disconnects(generation: 1) == 1)
        #expect(runtime.deactivations(generation: 1) == 1)
        #expect(!runtime.isCurrent(generation: 1))

        runtime.emit(.message("stale"), generation: 1)
        runtime.emit(.disconnected, generation: 1)
        await staleEventsProcessed.wait()
        #expect(events == [.status(5, generation: 1)])
    }

    @Test("Callback payloads are copied within a fixed application bound")
    func callbackPayloadCopyIsBounded() {
        let owned = "enter-data".withCString { NIMNativeString.copy(from: $0) }
        #expect(owned == "enter-data")
        #expect(NIMNativeString.copy(from: nil) == "")

        "".withCString { pointer in
            #expect(NIMNativeString.copy(from: pointer) == "")
        }

        var maximum = [CChar](repeating: 65, count: NIMNativeString.maximumBytes + 1)
        maximum[maximum.count - 1] = 0
        maximum.withUnsafeBufferPointer { buffer in
            #expect(NIMNativeString.copy(from: buffer.baseAddress)?.utf8.count == 65_536)
        }

        var oversized = [CChar](repeating: 65, count: NIMNativeString.maximumBytes + 2)
        oversized[oversized.count - 1] = 0
        oversized.withUnsafeBufferPointer { buffer in
            #expect(NIMNativeString.copy(from: buffer.baseAddress) == nil)
        }

        let invalidUTF8 = [CChar(bitPattern: 0xff), 0]
        invalidUTF8.withUnsafeBufferPointer { buffer in
            #expect(NIMNativeString.copy(from: buffer.baseAddress) == nil)
        }
    }

    @Test("HTTP callback treats UInt64 as timestamp and owns bounded strings before returning")
    func httpCallbackBoundary() async throws {
        let runtime = NIMNativeRuntime()
        let owner = UUID()
        let received = NIMStringRecorder()
        try runtime.beginActivation(owner: owner, generation: 1) { event in
            guard case let .message(body) = event else { return }
            received.append(body)
        }
        let context = try runtime.installCallbackContext(owner: owner, generation: 1)
        let pointer = Unmanaged.passUnretained(context).toOpaque()

        "timestamp".withCString {
            nimHTTPMessageCallback(nil, $0, .max, pointer)
        }
        nimHTTPMessageCallback(nil, nil, 1, pointer)
        "".withCString {
            nimHTTPMessageCallback(nil, $0, 2, pointer)
        }

        var maximum = [CChar](repeating: 65, count: NIMNativeString.maximumBytes + 1)
        maximum[maximum.count - 1] = 0
        maximum.withUnsafeBufferPointer {
            nimHTTPMessageCallback(nil, $0.baseAddress, 3, pointer)
        }

        var oversized = [CChar](repeating: 65, count: NIMNativeString.maximumBytes + 2)
        oversized[oversized.count - 1] = 0
        oversized.withUnsafeBufferPointer {
            nimHTTPMessageCallback(nil, $0.baseAddress, 4, pointer)
        }
        let invalidUTF8 = [CChar(bitPattern: 0xff), 0]
        invalidUTF8.withUnsafeBufferPointer {
            nimHTTPMessageCallback(nil, $0.baseAddress, 5, pointer)
        }

        var owned = Array("owned".utf8CString)
        owned.withUnsafeMutableBufferPointer { buffer in
            nimHTTPMessageCallback(nil, buffer.baseAddress, 6, pointer)
            buffer[0] = 88
        }

        for _ in 0..<100 where received.values.count < 5 { await Task.yield() }
        #expect(received.values == ["timestamp", "", "", String(repeating: "A", count: 65_536), "owned"])

        context.stopAcceptingCallbacks()
        "late".withCString { body in
            #expect(context.copyString(from: body) == nil)
            nimHTTPMessageCallback(nil, body, 7, pointer)
        }
        await Task.yield()
        #expect(received.values.count == 5)
        runtime.deactivate(owner: owner, generation: 1)
    }

    @Test("Native reconnect teardown reaches cleanup despite caller cancellation")
    func nativeReconnectTeardownSequenceIsStrict() async {
        var steps: [String] = []
        let exitWaiter = NIMCallbackWaiter()
        let logoutWaiter = NIMCallbackWaiter()
        let cleanupWaiter = NIMCallbackWaiter()
        let exitStarted = NIMTestSignal()
        let logoutStarted = NIMTestSignal()
        let cleanupStarted = NIMTestSignal()

        let disconnect = Task { @MainActor in
            await NIMNativeTeardownSequence.disconnect {
                steps.append("exit-start")
                #expect(await exitWaiter.wait(timeout: .seconds(60)) {
                    exitStarted.signal()
                } == .callback)
                steps.append("exit-finished")
            } logout: {
                steps.append("logout-start")
                #expect(await logoutWaiter.wait(timeout: .seconds(60)) {
                    logoutStarted.signal()
                } == .callback)
                steps.append("logout-finished")
            }
            await NIMNativeTeardownSequence.shutdown {
                steps.append("chatroom-cleanup")
            } cleanupClient: {
                steps.append("cleanup2-start")
                #expect(await cleanupWaiter.wait(timeout: .seconds(60)) {
                    cleanupStarted.signal()
                } == .callback)
                steps.append("cleanup2-finished")
            }
        }
        await exitStarted.wait()
        disconnect.cancel()
        #expect(steps == ["exit-start"])
        exitWaiter.resume()
        await logoutStarted.wait()
        #expect(steps == ["exit-start", "exit-finished", "logout-start"])
        logoutWaiter.resume()
        await cleanupStarted.wait()
        #expect(steps.last == "cleanup2-start")
        cleanupWaiter.resume()
        await disconnect.value

        let logoutOnlyWaiter = NIMCallbackWaiter()
        let logoutOnlyStarted = NIMTestSignal()
        var logoutOnlyFinished = false
        let logoutOnly = Task { @MainActor in await NIMNativeTeardownSequence.disconnect {
        } logout: {
            _ = await logoutOnlyWaiter.wait(timeout: .seconds(60)) {
                logoutOnlyStarted.signal()
            }
            logoutOnlyFinished = true
        } }
        await logoutOnlyStarted.wait()
        logoutOnly.cancel()
        #expect(!logoutOnlyFinished)
        logoutOnlyWaiter.resume()
        await logoutOnly.value
        #expect(logoutOnlyFinished)

        #expect(steps == [
            "exit-start", "exit-finished", "logout-start", "logout-finished",
            "chatroom-cleanup", "cleanup2-start", "cleanup2-finished"
        ])

        let timeoutWaiter = NIMCallbackWaiter()
        #expect(await timeoutWaiter.wait(timeout: .milliseconds(1)) {} == .timeout)
    }

    @Test("Final shutdown invalidates the session before process cleanup")
    func finalShutdownUsesOneLifecycleOwner() async throws {
        let runtime = FakeNIMRuntime()
        let transport = NIMChatroomTransport(runtime: runtime, connectionTimeout: .seconds(60))
        let connected = connect(transport, roomID: "1", generation: 1)
        await runtime.waitUntilActivated(generation: 1)
        await completeConnect(runtime, generation: 1)
        try await connected.value

        await transport.shutdown()

        #expect(runtime.lifecycle == ["disconnect-1", "deactivate-1", "shutdown"])
        #expect(!runtime.isCurrent(generation: 1))
    }

    @Test("Transport shutdown is terminal, cancellation-safe, and owned once")
    func transportShutdownIsTerminalAndOwnedOnce() async throws {
        let disconnectGate = NIMTestGate()
        let runtime = FakeNIMRuntime(disconnectGate: disconnectGate)
        let transport = NIMChatroomTransport(runtime: runtime, connectionTimeout: .seconds(60))
        let connected = connect(transport, roomID: "1", generation: 1)
        await runtime.waitUntilActivated(generation: 1)
        await completeConnect(runtime, generation: 1)
        try await connected.value

        let first = Task { @MainActor in await transport.shutdown() }
        await disconnectGate.waitUntilEntered()
        let second = Task { @MainActor in await transport.shutdown() }
        first.cancel()
        await expectUnavailable(connect(transport, roomID: "2", generation: 2))
        #expect(runtime.disconnects(generation: 1) == 1)
        #expect(runtime.deactivations(generation: 1) == 0)
        #expect(runtime.shutdowns == 0)

        await disconnectGate.open()
        await first.value
        await second.value
        await transport.shutdown()
        #expect(runtime.disconnects(generation: 1) == 1)
        #expect(runtime.deactivations(generation: 1) == 1)
        #expect(runtime.shutdowns == 1)
        #expect(runtime.shutdownReservations == 1)
    }

    @Test("Shutdown terminal fence stops a connect suspended in prior teardown")
    func shutdownFencesSuspendedConnect() async throws {
        let disconnectGate = NIMTestGate()
        let runtime = FakeNIMRuntime(disconnectGate: disconnectGate)
        let transport = NIMChatroomTransport(runtime: runtime, connectionTimeout: .seconds(60))
        let connected = connect(transport, roomID: "1", generation: 1)
        await runtime.waitUntilActivated(generation: 1)
        await completeConnect(runtime, generation: 1)
        try await connected.value

        let replacement = connect(transport, roomID: "2", generation: 2)
        await disconnectGate.waitUntilEntered()
        let shutdown = Task { @MainActor in await transport.shutdown() }
        await runtime.waitUntilShutdownReserved()
        await disconnectGate.open()
        await expectUnavailable(replacement)
        await shutdown.value

        #expect(runtime.activations(generation: 1) == 1)
        #expect(runtime.activations(generation: 2) == 0)
        #expect(runtime.disconnects(generation: 1) == 1)
        #expect(runtime.deactivations(generation: 1) == 1)
        #expect(runtime.shutdowns == 1)
    }

    @Test("Only the active shared-runtime owner can reserve final cleanup")
    func sharedRuntimeShutdownOwner() async throws {
        let runtime = NIMNativeRuntime()
        let activeOwner = UUID()
        let otherOwner = UUID()
        try runtime.beginActivation(owner: activeOwner, generation: 1) { _ in }

        #expect(!runtime.reserveShutdown(owner: otherOwner))
        await runtime.shutdown(owner: otherOwner)
        #expect(runtime.reserveShutdown(owner: activeOwner))
        #expect(runtime.reserveShutdown(owner: activeOwner))
        #expect(!runtime.reserveShutdown(owner: otherOwner))

        runtime.deactivate(owner: activeOwner, generation: 1)
        #expect(!runtime.reserveShutdown(owner: otherOwner))
        await runtime.shutdown(owner: activeOwner)
    }

    @Test("Pre-init shutdown is terminal for the shared runtime")
    func preInitShutdownIsTerminal() async {
        let runtime = NIMNativeRuntime()
        let owner = UUID()
        let other = UUID()

        #expect(runtime.reserveShutdown(owner: owner))
        #expect(runtime.reserveShutdown(owner: owner))
        #expect(!runtime.reserveShutdown(owner: other))
        await runtime.shutdown(owner: owner)

        do {
            try runtime.beginActivation(owner: other, generation: 1) { _ in }
            Issue.record("The finalized production runtime accepted a new activation")
        } catch NIMChatroomError.unavailable {
        } catch {
            Issue.record("The finalized production runtime returned \(error)")
        }
    }

    @Test("Production exit callback preserves unknown outcome scalars through its waiter")
    func exitOutcomeAndContextLifetime() async throws {
        let outcome = NIMChatroomExitOutcome(roomID: 9, errorCode: -17, exitType: .max)
        let runtime = NIMNativeRuntime()
        let owner = UUID()
        try runtime.beginActivation(owner: owner, generation: 1) { _ in }
        var context: NIMNativeCallbackContext? = try runtime.installCallbackContext(
            owner: owner,
            generation: 1
        )
        let pointer = Unmanaged.passUnretained(try #require(context)).toOpaque()
        weak let retainedContext = context
        let started = NIMTestSignal()
        let wait = Task { @MainActor in
            await runtime.waitForChatroomExit(
                roomID: outcome.roomID,
                owner: owner,
                generation: 1,
                timeout: .seconds(60)
            ) {
                started.signal()
            }
        }
        await started.wait()
        context = nil
        #expect(retainedContext != nil)
        #expect(retainedContext?.isAcceptingCallbacks() == true)

        nimChatroomExitCallback(
            outcome.roomID,
            outcome.errorCode,
            outcome.exitType,
            nil,
            pointer
        )
        #expect(await wait.value == outcome)

        runtime.deactivate(owner: owner, generation: 1)
        #expect(retainedContext?.isAcceptingCallbacks() == false)
        nimChatroomExitCallback(9, 0, 0, nil, pointer)
        #expect(retainedContext != nil)
    }

    @Test("Cleanup2 callback owns its context through caller cancellation and rejects late callbacks")
    func cleanupContextLifetime() async {
        let runtime = NIMNativeRuntime()
        let started = NIMTestSignal()
        var capturedContext: NIMNativeCallbackContext?
        let cleanup = Task { @MainActor in
            await runtime.waitForClientCleanup(timeout: .seconds(60)) { context in
                capturedContext = context
                started.signal()
            }
        }
        await started.wait()

        weak let retainedContext = capturedContext
        let pointer = Unmanaged.passUnretained(capturedContext!).toOpaque()
        capturedContext = nil
        cleanup.cancel()

        #expect(retainedContext != nil)
        #expect(retainedContext?.isAcceptingCallbacks() == true)
        nimClientCleanupCallback(nil, pointer)
        #expect(await cleanup.value == .callback)
        #expect(retainedContext != nil)
        #expect(retainedContext?.isAcceptingCallbacks() == false)

        nimClientCleanupCallback(nil, pointer)
        #expect(retainedContext?.isAcceptingCallbacks() == false)
    }

    @Test("Every new-library failure rolls back only new handles in reverse order")
    func loaderRollback() throws {
        for failedOpen in 1...3 {
            var closed: [Int] = []
            #expect(throws: NIMChatroomError.self) {
                try NIMLibraryLoadTransaction.run(
                    items: [1, 2, 3],
                    open: { $0 == failedOpen ? nil : $0 },
                    close: { closed.append($0) },
                    body: { _ in () }
                )
            }
            #expect(closed == Array(Array(1..<failedOpen).reversed()))
        }

        for stage in FailureStage.allCases {
            var closed: [Int] = []
            #expect(throws: InjectedFailure.self) {
                try NIMLibraryLoadTransaction.run(
                    items: [1, 2, 3],
                    open: { $0 },
                    close: { closed.append($0) }
                ) { _ in
                    switch stage {
                    case .firstSymbol:
                        for index in 0..<23 where index == 0 { throw InjectedFailure(stage: stage) }
                    case .middleSymbol:
                        for index in 0..<23 where index == 10 { throw InjectedFailure(stage: stage) }
                    case .lastSymbol:
                        for index in 0..<23 where index == 22 { throw InjectedFailure(stage: stage) }
                    case .directory, .configuration, .clientInit:
                        break
                    }
                    throw InjectedFailure(stage: stage)
                }
            }
            #expect(closed == [3, 2, 1])
        }

        var successfulHandlesClosed: [Int] = []
        let result = try NIMLibraryLoadTransaction.run(
            items: [1, 2, 3],
            open: { $0 },
            close: { successfulHandlesClosed.append($0) },
            body: { $0.count }
        )
        #expect(result == 3)
        #expect(successfulHandlesClosed.isEmpty)

        var laterFailureClosed: [Int] = []
        #expect(throws: InjectedFailure.self) {
            try NIMLibraryLoadTransaction.run(
                items: [4, 5, 6],
                open: { $0 },
                close: { laterFailureClosed.append($0) }
            ) { _ in
                throw InjectedFailure(stage: .clientInit)
            }
        }
        #expect(laterFailureClosed == [6, 5, 4])
        #expect(successfulHandlesClosed.isEmpty)

        var rollbackEvents: [String] = []
        #expect(throws: InjectedFailure.self) {
            try NIMLibraryLoadTransaction.run(
                items: [1, 2, 3],
                open: { $0 },
                close: { rollbackEvents.append("close-\($0)") }
            ) { _ in
                try NIMClientInitializationTransaction.run(
                    initialized: true,
                    cleanup: { rollbackEvents.append("client-cleanup") }
                ) {
                    throw InjectedFailure(stage: .clientInit)
                }
            }
        }
        #expect(rollbackEvents == ["client-cleanup", "close-3", "close-2", "close-1"])
    }

    @Test("Client-init false skips cleanup, rolls back new handles, and can retry")
    func clientInitFalseCanRetry() throws {
        var initialized = false
        var closed: [Int] = []
        var cleanupCount = 0
        let attempt = {
            try NIMLibraryLoadTransaction.run(
                items: [1, 2, 3],
                open: { $0 },
                close: { closed.append($0) }
            ) { handles in
                try NIMClientInitializationTransaction.run(
                    initialized: initialized,
                    cleanup: { cleanupCount += 1 }
                ) { handles }
            }
        }

        #expect(throws: NIMChatroomError.self) { try attempt() }
        #expect(closed == [3, 2, 1])
        #expect(cleanupCount == 0)

        initialized = true
        #expect(try attempt() == [1, 2, 3])
        #expect(closed == [3, 2, 1])
        #expect(cleanupCount == 0)
    }

    @Test("A failed reinitialization cleans the client without closing retained handles")
    func retainedHandlesSurviveReinitializationFailure() throws {
        var closed: [Int] = []
        let handles = try NIMLibraryLoadTransaction.run(
            items: [1, 2, 3],
            open: { $0 },
            close: { closed.append($0) },
            body: { $0 }
        )
        var cleanupCount = 0

        #expect(throws: InjectedFailure.self) {
            try NIMClientInitializationTransaction.run(
                initialized: true,
                cleanup: { cleanupCount += 1 }
            ) {
                throw InjectedFailure(stage: .clientInit)
            }
        }
        #expect(handles == [1, 2, 3])
        #expect(closed.isEmpty)
        #expect(cleanupCount == 1)

        let result = try NIMClientInitializationTransaction.run(
            initialized: true,
            cleanup: { cleanupCount += 1 },
            body: { "ready" }
        )
        #expect(result == "ready")
        #expect(closed.isEmpty)
        #expect(cleanupCount == 1)
    }

    @Test("Bundled NIM Mach-O metadata matches the locked code gate")
    func machOGate() throws {
        let urls = try #require(NIMChatroomTransport.bundledNativeSDKURLs())
        #expect(NIMChatroomTransport.sdkVersion == "10.9.40")
        #expect(urls.map(\.lastPathComponent) == [
            "libh_available.dylib",
            "libnim.dylib",
            "libnim_chatroom.dylib"
        ])

        for url in urls {
            let architectures = try runXcrun("lipo", "-archs", url.path)
                .split(whereSeparator: \.isWhitespace)
                .map(String.init)
            #expect(Set(architectures) == ["arm64", "x86_64"])
            #expect(try runXcrun("vtool", "-show-build", url.path).contains("minos 11.0"))
            #expect(try runXcrun("otool", "-D", url.path).contains("@rpath/\(url.lastPathComponent)"))
        }

        let clientLinks = try runXcrun("otool", "-L", urls[1].path)
        let chatroomLinks = try runXcrun("otool", "-L", urls[2].path)
        #expect(clientLinks.contains("current version 10.9.40"))
        #expect(chatroomLinks.contains("current version 10.9.40"))
        #expect(clientLinks.contains("@rpath/libh_available.dylib"))
        #expect(chatroomLinks.contains("@rpath/libh_available.dylib"))

        let clientSymbols = try exportedSymbols(at: urls[1])
        let chatroomSymbols = try exportedSymbols(at: urls[2])
        #expect(Self.clientSymbols.isSubset(of: clientSymbols))
        #expect(Self.chatroomSymbols.isSubset(of: chatroomSymbols))
        #expect(Self.clientSymbols.count + Self.chatroomSymbols.count == 23)
    }

    private func connect(
        _ transport: NIMChatroomTransport,
        roomID: String,
        generation: Int
    ) -> Task<Void, Error> {
        Task {
            try await transport.connect(
                roomID: roomID,
                credentials: Self.credentials,
                generation: generation
            )
        }
    }

    private func completeConnect(_ runtime: FakeNIMRuntime, generation: UInt64) async {
        runtime.emit(.login(#"{"err_code":200,"login_step":3}"#), generation: generation)
        await runtime.waitUntilEnterRequested(generation: generation)
        runtime.emit(.chatroomEnter(step: 5, code: 200), generation: generation)
    }

    private func expectConnectionFailure(_ task: Task<Void, Error>, stage: String) async {
        do {
            try await task.value
            Issue.record("The failed connect unexpectedly succeeded")
        } catch NIMChatroomError.connectionFailed(let actualStage) {
            #expect(actualStage == stage)
        } catch {
            Issue.record("The failed connect returned \(error)")
        }
    }

    private func expectCancellation(_ task: Task<Void, Error>) async {
        do {
            try await task.value
            Issue.record("The cancelled connect unexpectedly succeeded")
        } catch is CancellationError {
        } catch {
            Issue.record("The cancelled connect returned \(error)")
        }
    }

    private func expectUnavailable(_ task: Task<Void, Error>) async {
        do {
            try await task.value
            Issue.record("The terminal connect unexpectedly succeeded")
        } catch NIMChatroomError.unavailable {
        } catch {
            Issue.record("The terminal connect returned \(error)")
        }
    }

    private func runXcrun(_ arguments: String...) throws -> String {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        guard process.terminationStatus == 0 else { throw CommandFailure(output: text) }
        return text
    }

    private func exportedSymbols(at url: URL) throws -> Set<String> {
        Set(try runXcrun("nm", "-gjU", url.path).split(whereSeparator: \.isNewline).map(String.init))
    }

    private static let credentials = ListenTogetherRealtimeCredentials(
        accountID: "fixture-account",
        token: "fixture-token",
        addresses: []
    )

    private static let clientSymbols: Set<String> = [
        "_nim_client_init", "_nim_client_cleanup", "_nim_client_cleanup2", "_nim_client_login",
        "_nim_client_logout", "_nim_client_get_login_state",
        "_nim_talk_reg_receive_cb", "_nim_talk_reg_receive_broadcast_cb",
        "_nim_sysmsg_reg_sysmsg_cb", "_nim_subscribe_event_reg_push_event_cb",
        "_nim_reg_received_http_msg_cb", "_nim_client_reg_disconnect_cb",
        "_nim_client_reg_auto_relogin_cb", "_nim_plugin_chatroom_request_enter_async"
    ]

    private static let chatroomSymbols: Set<String> = [
        "_nim_chatroom_init", "_nim_chatroom_cleanup", "_nim_chatroom_reg_enter_cb",
        "_nim_chatroom_reg_exit_cb", "_nim_chatroom_reg_link_condition_cb",
        "_nim_chatroom_reg_receive_msg_cb", "_nim_chatroom_reg_receive_notification_cb",
        "_nim_chatroom_enter", "_nim_chatroom_exit"
    ]
}

@MainActor
private final class FakeNIMRuntime: NIMRuntime {
    private let lock = NSLock()
    private let stateRuntime = NIMNativeRuntime()
    private var sinks: [UInt64: @Sendable (NIMNativeEvent) -> Void] = [:]
    private var currentGeneration: UInt64?
    private var currentOwner: UUID?
    private var successfulShutdownOwner: UUID?
    private var activateCounts: [UInt64: Int] = [:]
    private var enterRequestCounts: [UInt64: Int] = [:]
    private var disconnectCounts: [UInt64: Int] = [:]
    private var deactivateCounts: [UInt64: Int] = [:]
    private var lifecycleEvents: [String] = []
    private var shutdownCount = 0
    private var shutdownReservationCount = 0
    private var activationWaiters: [UInt64: [CheckedContinuation<Void, Never>]] = [:]
    private var enterRequestWaiters: [UInt64: [CheckedContinuation<Void, Never>]] = [:]
    private var shutdownReservationWaiters: [CheckedContinuation<Void, Never>] = []
    private let failureStage: FakeRuntimeFailureStage?
    private let disconnectGate: NIMTestGate?

    init(
        failureStage: FakeRuntimeFailureStage? = nil,
        disconnectGate: NIMTestGate? = nil
    ) {
        self.failureStage = failureStage
        self.disconnectGate = disconnectGate
    }

    func activate(
        owner: UUID,
        generation: UInt64,
        eventSink: @escaping @Sendable (NIMNativeEvent) -> Void
    ) async throws {
        try stateRuntime.beginActivation(
            owner: owner,
            generation: generation,
            eventSink: eventSink
        )
        lock.withLock {
            currentOwner = owner
            currentGeneration = generation
            sinks[generation] = eventSink
            activateCounts[generation, default: 0] += 1
        }
        let waiters = activationWaiters.removeValue(forKey: generation) ?? []
        waiters.forEach { $0.resume() }
        if failureStage == .activate { throw FakeRuntimeFailureStage.activate.error }
    }

    func deactivate(owner: UUID, generation: UInt64) {
        let accepted = lock.withLock {
            guard currentOwner == owner, currentGeneration == generation else { return false }
            deactivateCounts[generation, default: 0] += 1
            lifecycleEvents.append("deactivate-\(generation)")
            currentGeneration = nil
            currentOwner = nil
            return true
        }
        if accepted == true { stateRuntime.deactivate(owner: owner, generation: generation) }
    }

    func prepareChatroom(roomID: Int64, owner: UUID, generation: UInt64) throws {
        if failureStage == .prepare { throw FakeRuntimeFailureStage.prepare.error }
    }

    func login(
        appKey: String,
        accountID: String,
        token: String,
        owner: UUID,
        generation: UInt64
    ) throws {
        if failureStage == .login { throw FakeRuntimeFailureStage.login.error }
    }

    func requestChatroomEnter(owner: UUID, generation: UInt64) throws {
        lock.withLock { enterRequestCounts[generation, default: 0] += 1 }
        let waiters = enterRequestWaiters.removeValue(forKey: generation) ?? []
        waiters.forEach { $0.resume() }
        if failureStage == .requestEnter { throw FakeRuntimeFailureStage.requestEnter.error }
    }

    func disconnect(owner: UUID, generation: UInt64) async {
        let accepted = lock.withLock {
            guard currentOwner == owner, currentGeneration == generation else { return false }
            disconnectCounts[generation, default: 0] += 1
            lifecycleEvents.append("disconnect-\(generation)")
            return true
        }
        if accepted, let disconnectGate { await disconnectGate.wait() }
    }

    func reserveShutdown(owner: UUID) -> Bool {
        let reserved = stateRuntime.reserveShutdown(owner: owner)
        lock.withLock {
            shutdownReservationCount += 1
            if reserved { successfulShutdownOwner = owner }
        }
        let waiters = shutdownReservationWaiters
        shutdownReservationWaiters = []
        waiters.forEach { $0.resume() }
        return reserved
    }

    func shutdown(owner: UUID) async {
        await stateRuntime.shutdown(owner: owner)
        lock.withLock {
            guard successfulShutdownOwner == owner, shutdownCount == 0 else { return }
            shutdownCount = 1
            lifecycleEvents.append("shutdown")
        }
    }

    func waitUntilActivated(generation: UInt64) async {
        guard lock.withLock({ sinks[generation] == nil }) else { return }
        await withCheckedContinuation { activationWaiters[generation, default: []].append($0) }
    }

    func waitUntilEnterRequested(generation: UInt64) async {
        guard lock.withLock({ enterRequestCounts[generation, default: 0] == 0 }) else { return }
        await withCheckedContinuation { enterRequestWaiters[generation, default: []].append($0) }
    }

    func waitUntilShutdownReserved() async {
        guard lock.withLock({ shutdownReservationCount == 0 }) else { return }
        await withCheckedContinuation { shutdownReservationWaiters.append($0) }
    }

    func activations(generation: UInt64) -> Int {
        lock.withLock { activateCounts[generation, default: 0] }
    }

    func isCurrent(generation: UInt64) -> Bool {
        lock.withLock { currentGeneration == generation }
    }

    func enterRequests(generation: UInt64) -> Int {
        lock.withLock { enterRequestCounts[generation, default: 0] }
    }

    func disconnects(generation: UInt64) -> Int {
        lock.withLock { disconnectCounts[generation, default: 0] }
    }

    func deactivations(generation: UInt64) -> Int {
        lock.withLock { deactivateCounts[generation, default: 0] }
    }

    var lifecycle: [String] {
        lock.withLock { lifecycleEvents }
    }

    var shutdowns: Int { lock.withLock { shutdownCount } }
    var shutdownReservations: Int { lock.withLock { shutdownReservationCount } }

    func emit(_ event: NIMNativeEvent, generation: UInt64) {
        let sink = lock.withLock { sinks[generation] }
        sink?(event)
    }

}

private actor NIMTestGate {
    private var isOpen = false
    private var entered = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        entered = true
        let pendingEntries = entryWaiters
        entryWaiters = []
        pendingEntries.forEach { $0.resume() }
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters = []
        pending.forEach { $0.resume() }
    }
}

@MainActor
private final class NIMTestSignal {
    private let requiredCount: Int
    private var count = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(count: Int = 1) {
        requiredCount = count
    }

    func signal() {
        guard count < requiredCount else { return }
        count += 1
        guard count == requiredCount else { return }
        let pending = waiters
        waiters = []
        pending.forEach { $0.resume() }
    }

    func wait() async {
        guard count < requiredCount else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

private final class NIMStringRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var values: [String] { lock.withLock { storage } }

    func append(_ value: String) {
        lock.withLock { storage.append(value) }
    }
}

private enum FakeRuntimeFailureStage: String, CaseIterable {
    case activate
    case prepare
    case login
    case requestEnter

    var errorStage: String { "fake-\(rawValue)" }
    var error: NIMChatroomError { .connectionFailed(stage: errorStage) }
}

private enum FailureStage: CaseIterable {
    case firstSymbol
    case middleSymbol
    case lastSymbol
    case directory
    case configuration
    case clientInit
}

private struct InjectedFailure: Error {
    let stage: FailureStage
}

private struct CommandFailure: Error {
    let output: String
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
