import Foundation
import Observation

@MainActor
protocol ListenTogetherRealtimeTransport: AnyObject {
    var onEvent: ((NIMChatroomEvent) -> Void)? { get set }

    func connect(
        roomID: String,
        credentials: ListenTogetherRealtimeCredentials,
        generation: Int
    ) async throws
    func disconnect(generation: Int) async
    func shutdown() async
}

extension NIMChatroomTransport: ListenTogetherRealtimeTransport {}

@MainActor
@Observable
final class ListenTogetherController {
    private static let fallbackHeartbeatInterval = 30
    private static let maximumReconnectAttempts = 3
    private static let driftThreshold: TimeInterval = 1.5

    private(set) var phase: ListenTogetherPhase = .idle
    private(set) var room: ListenTogetherRoom?
    private(set) var currentUserID: Int64?
    private(set) var errorMessage: String?
    private(set) var statusMessage: String?
    private(set) var isSleeping = false
    private(set) var isReconciling = false
    private(set) var isSendingCommand = false

    @ObservationIgnored private let service: LiveListenTogetherService
    @ObservationIgnored private let player: PlayerController
    @ObservationIgnored private let realtime: any ListenTogetherRealtimeTransport
    @ObservationIgnored private let accountBootstrapWaitObserver: (@MainActor @Sendable () -> Void)?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var accountRevision = 0
    @ObservationIgnored private var sessionAccountRevision = 0
    @ObservationIgnored private var credentialRevision: UInt64?
    @ObservationIgnored private var realtimeGeneration: Int?
    @ObservationIgnored private var nextClientSequence: Int64 = 1
    @ObservationIgnored private var playlistVersion: Int64 = 0
    @ObservationIgnored private var lastAppliedRemoteSequence: Int64 = 0
    @ObservationIgnored private var pendingRemoteSequence: Int64?
    @ObservationIgnored private var pendingRemoteCommand: ListenTogetherRemotePlayCommand?
    @ObservationIgnored private var heartbeatInterval = 30
    @ObservationIgnored private var accountTask: Task<Void, Never>?
    @ObservationIgnored private var heartbeatTask: Task<Void, Never>?
    @ObservationIgnored private var reconcileTask: Task<Void, Never>?
    @ObservationIgnored private var commandTask: Task<Void, Never>?
    @ObservationIgnored private var hostSnapshotTask: Task<Void, Never>?
    @ObservationIgnored private var remoteApplyTask: Task<Void, Never>?
    @ObservationIgnored private var roomOperationTask: Task<Void, Never>?
    @ObservationIgnored private var roomOperationTaskID: UUID?
    @ObservationIgnored private var retiredRoomOperations: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var logoutTask: Task<Void, Never>?
    @ObservationIgnored private var logoutTaskID: UUID?
    @ObservationIgnored private var disconnectTask: Task<Void, Never>?
    @ObservationIgnored private var disconnectTaskRevision: UInt64 = 0
    @ObservationIgnored private var reconciliationRequested = false
    @ObservationIgnored private var reconciliationRequiresReconnect = false
    @ObservationIgnored private var isEstablishingSession = false
    @ObservationIgnored private var roomOperationsBlocked = true

    init(
        service: LiveListenTogetherService,
        player: PlayerController,
        realtime: any ListenTogetherRealtimeTransport = NIMChatroomTransport(),
        accountBootstrapWaitObserver: (@MainActor @Sendable () -> Void)? = nil
    ) {
        self.service = service
        self.player = player
        self.realtime = realtime
        self.accountBootstrapWaitObserver = accountBootstrapWaitObserver
        realtime.onEvent = { [weak self] event in self?.receive(event) }
    }

    isolated deinit {
        accountTask?.cancel()
        heartbeatTask?.cancel()
        reconcileTask?.cancel()
        commandTask?.cancel()
        hostSnapshotTask?.cancel()
        remoteApplyTask?.cancel()
        roomOperationTask?.cancel()
        for task in retiredRoomOperations.values { task.cancel() }
        logoutTask?.cancel()
        disconnectTask?.cancel()
        player.controlInterceptor = nil
        player.setControlInteractionLocked(false)
        realtime.onEvent = nil
    }

    var members: [ListenTogetherMember] { room?.members ?? [] }

    var isConnected: Bool {
        guard case .connected = phase else { return false }
        return !isSleeping && !isReconciling
    }

    var canControlPlayback: Bool { isConnected && !isSendingCommand }

    var invitationURL: URL? {
        guard let room,
              room.role == .host,
              let songID = player.currentSongID
        else { return nil }
        return room.invitationURL(songID: songID)
    }

    var requiresShutdown: Bool {
        room != nil
            || roomOperationTask != nil
            || !retiredRoomOperations.isEmpty
            || logoutTask != nil
            || disconnectTask != nil
            || realtimeGeneration != nil
    }

    func updateAccount(_ userID: Int64?) {
        let expectedCredentialRevision = service.credentialRevision
        if currentUserID == userID,
           credentialRevision == expectedCredentialRevision,
           room != nil,
           logoutTask == nil,
           !roomOperationsBlocked {
            return
        }
        accountRevision += 1
        let revision = accountRevision
        let previousRoom = room
        let previousCredentialRevision = credentialRevision
        let disconnectGeneration = realtimeGeneration
        roomOperationsBlocked = true
        invalidateSessionWork()
        retireCurrentRoomOperation()
        accountTask?.cancel()
        accountTask = Task { @MainActor [weak self] in
            await self?.updateAccountState(
                userID,
                revision: revision,
                expectedCredentialRevision: expectedCredentialRevision,
                previousCredentialRevision: previousCredentialRevision,
                previousRoom: previousRoom,
                disconnectGeneration: disconnectGeneration
            )
        }
    }

    private func updateAccountState(
        _ userID: Int64?,
        revision: Int,
        expectedCredentialRevision: UInt64,
        previousCredentialRevision: UInt64?,
        previousRoom: ListenTogetherRoom?,
        disconnectGeneration: Int?
    ) async {
        await drainRoomOperations()
        guard isCurrentAccount(revision, credentialRevision: expectedCredentialRevision),
              !Task.isCancelled
        else { return }
        defer {
            if revision == accountRevision { roomOperationsBlocked = userID == nil }
        }
        player.controlInterceptor = nil
        player.setControlInteractionLocked(false)
        if userID == nil,
           let previousRoom,
           let previousCredentialRevision {
            _ = try? await service.endRoomConfirmed(
                roomID: previousRoom.id,
                expectedCredentialRevision: previousCredentialRevision
            )
            guard isCurrentAccount(revision, credentialRevision: expectedCredentialRevision),
                  !Task.isCancelled
            else { return }
        }
        currentUserID = userID
        sessionAccountRevision = revision
        credentialRevision = expectedCredentialRevision
        phase = .idle
        errorMessage = nil
        statusMessage = nil
        isSleeping = false
        await disconnectRealtime(generation: disconnectGeneration)
        guard isCurrentAccount(revision, credentialRevision: expectedCredentialRevision),
              !Task.isCancelled
        else { return }

        guard let userID, userID > 0 else { return }
        let sessionGeneration = generation
        do {
            let status = try await service.status(
                currentUserID: userID,
                expectedCredentialRevision: expectedCredentialRevision
            )
            try Task.checkCancellation()
            guard isCurrentAccount(revision, credentialRevision: expectedCredentialRevision),
                  generation == sessionGeneration,
                  currentUserID == userID
            else { return }
            if status.inRoom, let existingRoom = status.room {
                room = existingRoom
                phase = .recoveryAvailable(existingRoom)
                statusMessage = "发现未恢复的一起听房间"
            }
        } catch is CancellationError {
        } catch {
            guard isCurrentAccount(revision, credentialRevision: expectedCredentialRevision),
                  generation == sessionGeneration,
                  currentUserID == userID
            else { return }
            errorMessage = error.localizedDescription
        }
    }

    func createRoom() async {
        await performRoomOperation { [weak self] in
            await self?.performCreateRoom()
        }
    }

    private func performCreateRoom() async {
        guard let userID = authenticatedUserID(),
              let expectedCredentialRevision = credentialRevision,
              room == nil
        else { return }
        let expectedAccountRevision = accountRevision
        let sessionGeneration = beginRoomOperation(phase: .creating)
        do {
            let createdRoom = try await service.createRoom(
                currentUserID: userID,
                expectedCredentialRevision: expectedCredentialRevision
            )
            guard !Task.isCancelled, isCurrent(
                sessionGeneration,
                accountRevision: expectedAccountRevision,
                credentialRevision: expectedCredentialRevision,
                userID: userID
            ) else {
                await cleanUpInvalidatedRoom(
                    createdRoom,
                    expectedCredentialRevision: expectedCredentialRevision
                )
                return
            }
            try await establish(
                createdRoom,
                generation: sessionGeneration,
                accountRevision: expectedAccountRevision,
                credentialRevision: expectedCredentialRevision,
                bootstrapHost: true
            )
        } catch is CancellationError {
        } catch {
            fail(error, generation: sessionGeneration)
        }
    }

    func checkInvitation(_ invitation: ListenTogetherInvitation) async {
        await performRoomOperation { [weak self] in
            await self?.performCheckInvitation(invitation)
        }
    }

    private func performCheckInvitation(_ invitation: ListenTogetherInvitation) async {
        guard authenticatedUserID() != nil,
              let expectedCredentialRevision = credentialRevision,
              room == nil
        else { return }
        let expectedAccountRevision = accountRevision
        let sessionGeneration = beginRoomOperation(phase: .checking(invitation))
        do {
            let check = try await service.checkInvitation(
                invitation,
                expectedCredentialRevision: expectedCredentialRevision
            )
            try Task.checkCancellation()
            guard isCurrent(
                sessionGeneration,
                accountRevision: expectedAccountRevision,
                credentialRevision: expectedCredentialRevision
            ) else { return }
            if check.joinable {
                phase = .readyToJoin(invitation)
                statusMessage = check.message
            } else {
                let message = check.message ?? "这个一起听房间当前无法加入"
                errorMessage = message
                phase = .failed(message)
            }
        } catch is CancellationError {
        } catch {
            fail(error, generation: sessionGeneration)
        }
    }

    func join(_ invitation: ListenTogetherInvitation) async {
        await performRoomOperation { [weak self] in
            await self?.performJoin(invitation)
        }
    }

    private func performJoin(_ invitation: ListenTogetherInvitation) async {
        guard let userID = authenticatedUserID(),
              let expectedCredentialRevision = credentialRevision,
              room == nil
        else { return }
        let expectedAccountRevision = accountRevision
        let sessionGeneration = beginRoomOperation(phase: .joining(invitation))
        do {
            let joinedRoom = try await service.acceptInvitation(
                invitation,
                currentUserID: userID,
                expectedCredentialRevision: expectedCredentialRevision
            )
            guard !Task.isCancelled, isCurrent(
                sessionGeneration,
                accountRevision: expectedAccountRevision,
                credentialRevision: expectedCredentialRevision,
                userID: userID
            ) else {
                await cleanUpInvalidatedRoom(
                    joinedRoom,
                    expectedCredentialRevision: expectedCredentialRevision
                )
                return
            }
            try await establish(
                joinedRoom,
                generation: sessionGeneration,
                accountRevision: expectedAccountRevision,
                credentialRevision: expectedCredentialRevision,
                bootstrapHost: false
            )
        } catch is CancellationError {
        } catch {
            fail(error, generation: sessionGeneration)
        }
    }

    func recover() {
        guard room != nil, currentUserID != nil else { return }
        installPlayerGate()
        requestReconciliation(reconnect: true)
    }

    func reconnect() {
        guard room != nil, currentUserID != nil, !isSleeping else { return }
        installPlayerGate()
        errorMessage = nil
        requestReconciliation(reconnect: true)
    }

    func sleep() async {
        guard room != nil || roomOperationTask != nil else { return }
        isSleeping = true
        statusMessage = "一起听同步已暂停"
        let currentRoom = room
        let disconnectGeneration = realtimeGeneration
        invalidateSessionWork(retainingRoomState: true)
        retireCurrentRoomOperation()
        if let currentRoom { room = currentRoom }
        guard isSleeping, let currentRoom else {
            isSleeping = false
            return
        }
        room = currentRoom
        installPlayerGate()
        await disconnectRealtime(generation: disconnectGeneration)
    }

    func wake() {
        guard room != nil else { return }
        isSleeping = false
        requestReconciliation(reconnect: true)
    }

    func endRoom() async {
        await performRoomOperation { [weak self] in
            await self?.exitRoom()
        }
    }

    func prepareForLogout() async {
        if let logoutTask {
            await logoutTask.value
            return
        }
        let taskID = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performLogoutPreparation()
        }
        logoutTaskID = taskID
        logoutTask = task
        await task.value
        if logoutTaskID == taskID {
            logoutTask = nil
            logoutTaskID = nil
        }
    }

    private func performLogoutPreparation() async {
        roomOperationsBlocked = true
        accountRevision += 1
        let revision = accountRevision
        let expectedCredentialRevision = credentialRevision ?? service.credentialRevision
        let currentRoom = room
        let disconnectGeneration = realtimeGeneration
        accountTask?.cancel()
        accountTask = nil
        let sessionGeneration = invalidateSessionWork(retainingRoomState: true)
        retireCurrentRoomOperation()
        await drainRoomOperations()
        if let currentRoom { room = currentRoom }
        guard revision == accountRevision,
              generation == sessionGeneration,
              currentUserID != nil || currentRoom != nil || disconnectGeneration != nil
        else { return }
        await performRoomOperation(allowWhenBlocked: true) { [weak self] in
            await self?.performLogoutCleanup(
                expectedCredentialRevision: expectedCredentialRevision,
                disconnectGeneration: disconnectGeneration,
                generation: sessionGeneration,
                accountRevision: revision
            )
        }
    }

    private func performLogoutCleanup(
        expectedCredentialRevision: UInt64,
        disconnectGeneration: Int?,
        generation sessionGeneration: Int,
        accountRevision expectedAccountRevision: Int
    ) async {
        let currentRoom = room
        if let currentRoom {
            _ = try? await service.endRoomConfirmed(
                roomID: currentRoom.id,
                expectedCredentialRevision: expectedCredentialRevision
            )
            guard generation == sessionGeneration,
                  accountRevision == expectedAccountRevision,
                  !Task.isCancelled
            else { return }
        }
        clearSession(phase: .idle)
        currentUserID = nil
        credentialRevision = nil
        await disconnectRealtime(generation: disconnectGeneration)
    }

    func shutdown() async {
        await prepareForLogout()
        await drainRoomOperations()
        if let disconnectTask { await disconnectTask.value }
        realtime.onEvent = nil
        await realtime.shutdown()
    }

    private func establish(
        _ newRoom: ListenTogetherRoom,
        generation sessionGeneration: Int,
        accountRevision expectedAccountRevision: Int,
        credentialRevision expectedCredentialRevision: UInt64,
        bootstrapHost: Bool
    ) async throws {
        room = newRoom
        resetSequences()
        installPlayerGate()
        isEstablishingSession = true
        isReconciling = true
        player.setControlInteractionLocked(true)

        do {
            guard !isSleeping else { throw CancellationError() }
            let credentials = try await service.realtimeCredentials(
                expectedCredentialRevision: expectedCredentialRevision
            )
            try Task.checkCancellation()
            guard !isSleeping,
                  isCurrent(
                    sessionGeneration,
                    accountRevision: expectedAccountRevision,
                    credentialRevision: expectedCredentialRevision,
                    roomID: newRoom.id
                  )
            else { throw CancellationError() }
            await cancelDisconnectTask()
            try Task.checkCancellation()
            guard isCurrent(
                sessionGeneration,
                accountRevision: expectedAccountRevision,
                credentialRevision: expectedCredentialRevision,
                roomID: newRoom.id
            ) else { throw CancellationError() }
            realtimeGeneration = sessionGeneration
            try await realtime.connect(
                roomID: newRoom.chatRoomID,
                credentials: credentials,
                generation: sessionGeneration
            )
            try Task.checkCancellation()
            guard !isSleeping,
                  isCurrent(
                    sessionGeneration,
                    accountRevision: expectedAccountRevision,
                    credentialRevision: expectedCredentialRevision,
                    roomID: newRoom.id
                  )
            else { throw CancellationError() }
            if bootstrapHost {
                try await reportHostSnapshot(
                    roomID: newRoom.id,
                    userID: newRoom.creatorID,
                    expectedCredentialRevision: expectedCredentialRevision
                )
            } else {
                try await synchronizeState(
                    roomID: newRoom.id,
                    generation: sessionGeneration,
                    expectedCredentialRevision: expectedCredentialRevision
                )
            }
            try Task.checkCancellation()
            guard !isSleeping,
                  isCurrent(
                    sessionGeneration,
                    accountRevision: expectedAccountRevision,
                    credentialRevision: expectedCredentialRevision,
                    roomID: newRoom.id
                  )
            else { throw CancellationError() }
            applyPendingRemoteEvent()
            isEstablishingSession = false
            if !reconciliationRequested { isReconciling = false }
            setConnected(newRoom)
            startReconciliationTaskIfNeeded()
            startHeartbeat(generation: sessionGeneration, immediately: true)
        } catch {
            if generation == sessionGeneration {
                isEstablishingSession = false
                isReconciling = false
                reconciliationRequested = false
                reconciliationRequiresReconnect = false
            }
            throw error
        }
    }

    private func reportHostSnapshot(
        roomID: String,
        userID: Int64,
        expectedCredentialRevision: UInt64
    ) async throws {
        let order = player.currentQueueOrder
        let queue = order.displaySongIDs.isEmpty ? nil : order
        let play = player.currentSongID.map { songID in
            let status: ListenTogetherPlayStatus = player.isPlaybackRequested ? .playing : .paused
            return status == .playing
                ? PlayerPlayIntent.play(songID: songID, progress: player.position)
                : PlayerPlayIntent.pause(songID: songID, progress: player.position)
        }
        guard queue != nil || play != nil else { return }
        try await report(
            PlayerControlIntent(trigger: .user, play: play, queue: queue),
            roomID: roomID,
            userID: userID,
            expectedCredentialRevision: expectedCredentialRevision
        )
    }

    private func reportHostProgress(
        roomID: String,
        userID: Int64,
        expectedCredentialRevision: UInt64
    ) async throws {
        guard let songID = player.currentSongID else { return }
        try await report(
            PlayerControlIntent(
                trigger: .user,
                play: .seek(
                    songID: songID,
                    progress: player.position,
                    playing: player.isPlaybackRequested
                ),
                queue: nil
            ),
            roomID: roomID,
            userID: userID,
            expectedCredentialRevision: expectedCredentialRevision
        )
    }

    private func sendHostSnapshot(includePlaylist: Bool) {
        guard let currentRoom = room,
              currentRoom.role == .host,
              let userID = currentUserID,
              let expectedCredentialRevision = credentialRevision,
              case .connected = phase
        else { return }
        let previous = hostSnapshotTask
        previous?.cancel()
        let sessionGeneration = generation
        hostSnapshotTask = Task { @MainActor [weak self] in
            guard let self else { return }
            if let previous { await previous.value }
            do {
                try Task.checkCancellation()
                if includePlaylist {
                    try await self.reportHostSnapshot(
                        roomID: currentRoom.id,
                        userID: userID,
                        expectedCredentialRevision: expectedCredentialRevision
                    )
                } else {
                    try await self.reportHostProgress(
                        roomID: currentRoom.id,
                        userID: userID,
                        expectedCredentialRevision: expectedCredentialRevision
                    )
                }
                try Task.checkCancellation()
                guard self.isCurrent(sessionGeneration, roomID: currentRoom.id) else { return }
            } catch is CancellationError {
            } catch {
                guard self.isCurrent(sessionGeneration, roomID: currentRoom.id) else { return }
                self.errorMessage = error.localizedDescription
                self.requestReconciliation(reconnect: false)
            }
        }
    }

    private func installPlayerGate() {
        player.setControlInteractionLocked(!isConnected)
        player.controlInterceptor = { [weak self] intent, commit in
            guard let self else {
                commit()
                return true
            }
            return self.intercept(intent, commit: commit)
        }
    }

    private func intercept(
        _ intent: PlayerControlIntent,
        commit: @escaping @MainActor @Sendable () -> Void
    ) -> Bool {
        guard let currentRoom = room else {
            commit()
            return true
        }
        guard isConnected else {
            errorMessage = isSleeping ? "唤醒并完成同步后才能控制播放" : "重新连接后才能控制播放"
            return false
        }
        guard !isSendingCommand,
              let userID = currentUserID,
              let expectedCredentialRevision = credentialRevision
        else {
            errorMessage = "上一项播放操作仍在同步"
            return false
        }

        isSendingCommand = true
        player.setControlInteractionLocked(true)
        errorMessage = nil
        let sessionGeneration = generation
        commandTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.generation == sessionGeneration {
                    self.isSendingCommand = false
                    self.commandTask = nil
                    self.player.setControlInteractionLocked(!self.isConnected)
                }
            }
            do {
                try await self.report(
                    intent,
                    roomID: currentRoom.id,
                    userID: userID,
                    expectedCredentialRevision: expectedCredentialRevision
                )
                try Task.checkCancellation()
                guard self.isCurrent(sessionGeneration, roomID: currentRoom.id) else { return }
                commit()
            } catch is CancellationError {
            } catch {
                guard self.isCurrent(sessionGeneration, roomID: currentRoom.id) else { return }
                self.errorMessage = error.localizedDescription
                self.requestReconciliation(reconnect: true)
            }
        }
        return true
    }

    private func report(
        _ intent: PlayerControlIntent,
        roomID: String,
        userID: Int64,
        expectedCredentialRevision: UInt64
    ) async throws {
        if let order = intent.queue {
            let version = try reservePlaylistVersion()
            let anchorPosition = order.anchorSongID.flatMap(order.displaySongIDs.firstIndex(of:)) ?? -1
            let command = try ListenTogetherPlaylistCommand(
                commandType: .replace,
                userID: userID,
                version: version,
                playMode: order.randomSongIDs == order.displaySongIDs ? .orderLoop : .random,
                anchorSongID: order.anchorSongID,
                anchorPosition: anchorPosition,
                randomList: order.randomSongIDs,
                displayList: order.displaySongIDs
            )
            guard try await service.reportPlaylistCommandConfirmed(
                roomID: roomID,
                command: command,
                expectedCredentialRevision: expectedCredentialRevision
            ) else {
                throw ListenTogetherControllerError.commandRejected
            }
            try Task.checkCancellation()
        }
        if let intent = intent.play {
            let command = try playCommand(from: intent)
            guard try await service.reportPlayCommandConfirmed(
                roomID: roomID,
                command: command,
                expectedCredentialRevision: expectedCredentialRevision
            ) else {
                throw ListenTogetherControllerError.commandRejected
            }
        }
    }

    private func playCommand(from intent: PlayerPlayIntent) throws -> ListenTogetherPlayCommand {
        let sequence = try reserveClientSequence()
        switch intent {
        case let .play(songID, progress):
            return try ListenTogetherPlayCommand(
                commandType: .play,
                progress: milliseconds(progress),
                playStatus: .playing,
                formerSongID: songID,
                targetSongID: songID,
                clientSequence: sequence
            )
        case let .pause(songID, progress):
            return try ListenTogetherPlayCommand(
                commandType: .pause,
                progress: milliseconds(progress),
                playStatus: .paused,
                formerSongID: songID,
                targetSongID: songID,
                clientSequence: sequence
            )
        case let .seek(songID, progress, playing):
            return try ListenTogetherPlayCommand(
                commandType: .progress,
                progress: milliseconds(progress),
                playStatus: playing ? .playing : .paused,
                formerSongID: songID,
                targetSongID: songID,
                clientSequence: sequence
            )
        case let .transition(transition, formerSongID, targetSongID, progress, playing):
            let commandType: ListenTogetherPlayCommandType = switch transition {
            case .goTo: .goTo
            case .next: .next
            case .previous: .previous
            }
            return try ListenTogetherPlayCommand(
                commandType: commandType,
                progress: milliseconds(progress),
                playStatus: playing ? .playing : .paused,
                formerSongID: formerSongID ?? -1,
                targetSongID: targetSongID,
                clientSequence: sequence
            )
        }
    }

    private func receive(_ event: NIMChatroomEvent) {
        switch event {
        case let .message(raw, eventGeneration):
            guard eventGeneration == generation,
                  credentialRevision == service.credentialRevision,
                  room != nil,
                  !isSleeping
            else { return }
            switch phase {
            case .creating, .joining, .connected, .reconnecting:
                break
            default:
                return
            }
            guard let remoteEvent = try? ListenTogetherResponseDecoder.remoteEvent(from: raw) else { return }
            receive(remoteEvent)
        case let .status(status, eventGeneration):
            guard eventGeneration == generation,
                  credentialRevision == service.credentialRevision,
                  room != nil,
                  !isSleeping
            else { return }
            guard status == 0 || status == 6 else { return }
            switch phase {
            case .creating, .joining, .connected, .reconnecting:
                break
            default:
                return
            }
            statusMessage = "一起听实时连接已断开"
            requestReconciliation(reconnect: true)
        }
    }

    private func receive(_ event: ListenTogetherRemoteEvent) {
        switch event {
        case let .play(command):
            receive(command)
        case let .playlistChanged(sequence):
            if let sequence {
                switch Self.sequenceDecision(lastApplied: lastAppliedRemoteSequence, incoming: sequence) {
                case .discard:
                    return
                case .reconcile:
                    retainPending(sequence: sequence, command: nil)
                case .apply where isReconciling:
                    retainPending(sequence: sequence, command: nil)
                case .apply:
                    lastAppliedRemoteSequence = sequence
                }
            }
            remoteApplyTask?.cancel()
            requestReconciliation(reconnect: false)
        case .memberJoined:
            statusMessage = "新成员已加入"
            requestReconciliation(reconnect: false)
            sendHostSnapshot(includePlaylist: true)
        case .roomEnded:
            // Chat payloads are hints; only the authenticated room status may end our session.
            requestReconciliation(reconnect: false)
        case let .heartbeatRequested(ignoredUserIDs):
            guard let currentUserID, !ignoredUserIDs.contains(currentUserID) else { return }
            sendHostSnapshot(includePlaylist: false)
        }
    }

    private func receive(_ command: ListenTogetherRemotePlayCommand) {
        let sequence = command.serverSequence
        switch Self.sequenceDecision(lastApplied: lastAppliedRemoteSequence, incoming: sequence) {
        case .discard:
            return
        case .reconcile:
            retainPending(sequence: sequence, command: command)
            requestReconciliation(reconnect: false)
            return
        case .apply:
            break
        }
        remoteApplyTask?.cancel()
        if isReconciling {
            retainPending(sequence: sequence, command: command)
            return
        }
        if !canApply(command) {
            retainPending(sequence: sequence, command: command)
            requestReconciliation(reconnect: false)
            return
        }
        lastAppliedRemoteSequence = sequence
        apply(command)
    }

    private func apply(_ command: ListenTogetherRemotePlayCommand) {
        applyPlayback(
            targetSongID: command.targetSongID,
            progressMilliseconds: command.progressMilliseconds,
            playStatus: command.playStatus,
            expectedServerSequence: command.serverSequence
        )
    }

    private func apply(_ snapshot: ListenTogetherPlaybackSnapshot) {
        applyPlayback(
            targetSongID: snapshot.targetSongID,
            progressMilliseconds: snapshot.progressMilliseconds,
            playStatus: snapshot.playStatus,
            expectedServerSequence: nil
        )
    }

    private func applyPlayback(
        targetSongID: Int64,
        progressMilliseconds: Int64,
        playStatus: ListenTogetherPlayStatus,
        expectedServerSequence: Int64?
    ) {
        let progress = TimeInterval(progressMilliseconds) / 1_000
        remoteApplyTask?.cancel()
        player.applyAuthoritatively {
            player.playQueuedSong(targetSongID)
            if player.currentSongID == targetSongID,
               player.currentSong != nil,
               abs(player.position - progress) > Self.driftThreshold {
                player.seek(to: progress)
            }
            player.setPlayback(playStatus == .playing)
        }
        guard player.currentSongID == targetSongID, player.currentSong == nil else { return }
        scheduleDeferredCorrection(
            targetSongID: targetSongID,
            progress: progress,
            playStatus: playStatus,
            expectedServerSequence: expectedServerSequence
        )
    }

    private func scheduleDeferredCorrection(
        targetSongID: Int64,
        progress: TimeInterval,
        playStatus: ListenTogetherPlayStatus,
        expectedServerSequence: Int64?
    ) {
        let sessionGeneration = generation
        let started = ContinuousClock.now
        // ponytail: poll for five seconds; add a player readiness callback only if slow resolutions become common.
        remoteApplyTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for _ in 0..<50 {
                do {
                    try await Task.sleep(for: .milliseconds(100))
                } catch {
                    return
                }
                guard self.isCurrent(sessionGeneration),
                      expectedServerSequence.map({ self.lastAppliedRemoteSequence == $0 }) ?? true,
                      self.player.currentSongID == targetSongID
                else { return }
                guard self.player.currentSong != nil else { continue }
                let elapsed = started.duration(to: .now)
                let elapsedSeconds = Double(elapsed.components.seconds)
                    + Double(elapsed.components.attoseconds) / 1_000_000_000_000_000_000
                let expectedProgress = progress
                    + (playStatus == .playing ? elapsedSeconds : 0)
                self.player.applyAuthoritatively {
                    if abs(self.player.position - expectedProgress) > Self.driftThreshold {
                        self.player.seek(to: expectedProgress)
                    }
                    self.player.setPlayback(playStatus == .playing)
                }
                self.remoteApplyTask = nil
                return
            }
            if expectedServerSequence.map({ self.lastAppliedRemoteSequence == $0 }) ?? true {
                self.remoteApplyTask = nil
            }
        }
    }

    private func canApply(_ command: ListenTogetherRemotePlayCommand) -> Bool {
        player.currentSongID == command.targetSongID
            || player.currentQueueOrder.displaySongIDs.contains(command.targetSongID)
    }

    static func sequenceDecision(
        lastApplied: Int64,
        incoming: Int64
    ) -> ListenTogetherSequenceDecision {
        guard incoming > lastApplied else { return .discard }
        guard lastApplied == 0 || incoming == lastApplied + 1 else { return .reconcile }
        return .apply
    }

    private func retainPending(
        sequence: Int64,
        command: ListenTogetherRemotePlayCommand?
    ) {
        guard sequence >= pendingRemoteSequence ?? 0 else { return }
        pendingRemoteSequence = sequence
        pendingRemoteCommand = command
    }

    private func applyPendingRemoteEvent() {
        guard let sequence = pendingRemoteSequence else { return }
        let command = pendingRemoteCommand
        pendingRemoteSequence = nil
        pendingRemoteCommand = nil
        guard sequence > lastAppliedRemoteSequence else { return }
        guard let command else {
            lastAppliedRemoteSequence = sequence
            return
        }
        guard canApply(command) else { return }
        lastAppliedRemoteSequence = sequence
        apply(command)
    }

    private func requestReconciliation(reconnect: Bool) {
        guard room != nil, currentUserID != nil, !isSleeping else { return }
        isReconciling = true
        player.setControlInteractionLocked(true)
        reconciliationRequested = true
        reconciliationRequiresReconnect = reconciliationRequiresReconnect || reconnect
        if reconnect { heartbeatTask?.cancel() }
        startReconciliationTaskIfNeeded()
    }

    private func startReconciliationTaskIfNeeded() {
        guard !isEstablishingSession, reconcileTask == nil, reconciliationRequested else { return }
        let sessionGeneration = generation
        reconcileTask = Task { @MainActor [weak self] in
            await self?.runReconciliation(generation: sessionGeneration)
        }
    }

    private func runReconciliation(generation sessionGeneration: Int) async {
        guard let expectedCredentialRevision = credentialRevision else { return }
        isReconciling = true
        defer {
            if generation == sessionGeneration {
                isReconciling = false
                reconcileTask = nil
                player.setControlInteractionLocked(!isConnected)
            }
        }

        while reconciliationRequested, generation == sessionGeneration, !Task.isCancelled {
            reconciliationRequested = false
            let reconnect = reconciliationRequiresReconnect
            reconciliationRequiresReconnect = false
            if reconnect {
                guard await reconnectWithRetries(
                    generation: sessionGeneration,
                    expectedCredentialRevision: expectedCredentialRevision
                ) else { return }
                continue
            }
            do {
                let previousError = errorMessage
                try await reconcile(
                    generation: sessionGeneration,
                    reconnectRealtime: false,
                    expectedCredentialRevision: expectedCredentialRevision
                )
                if !reconciliationRequested, errorMessage == previousError {
                    errorMessage = nil
                }
            } catch is CancellationError {
                return
            } catch ListenTogetherControllerError.notInRoom {
                finishSession(reason: "房间已结束")
                return
            } catch {
                errorMessage = error.localizedDescription
                reconciliationRequested = true
                reconciliationRequiresReconnect = true
            }
        }
    }

    private func reconnectWithRetries(
        generation sessionGeneration: Int,
        expectedCredentialRevision: UInt64
    ) async -> Bool {
        for attempt in 1...Self.maximumReconnectAttempts {
            guard generation == sessionGeneration, let currentRoom = room else { return false }
            phase = .reconnecting(currentRoom, attempt: attempt)
            do {
                errorMessage = nil
                try await reconcile(
                    generation: sessionGeneration,
                    reconnectRealtime: true,
                    expectedCredentialRevision: expectedCredentialRevision
                )
                guard let reconciledRoom = room else { return false }
                setConnected(reconciledRoom)
                startHeartbeat(generation: sessionGeneration, immediately: true)
                return true
            } catch is CancellationError {
                return false
            } catch ListenTogetherControllerError.notInRoom {
                finishSession(reason: "房间已结束")
                return false
            } catch {
                errorMessage = error.localizedDescription
                guard attempt < Self.maximumReconnectAttempts else { break }
                do {
                    try await Task.sleep(for: .seconds(1 << (attempt - 1)))
                } catch {
                    return false
                }
            }
        }

        guard generation == sessionGeneration, let currentRoom = room else { return false }
        player.applyAuthoritatively { player.setPlayback(false) }
        let message = "一起听连接已断开，请手动重连"
        phase = .failed(message)
        errorMessage = message
        statusMessage = "同步已停止"
        room = currentRoom
        return false
    }

    private func reconcile(
        generation sessionGeneration: Int,
        reconnectRealtime: Bool,
        expectedCredentialRevision: UInt64
    ) async throws {
        guard let userID = currentUserID, let expectedRoom = room else { throw CancellationError() }
        let status = try await service.status(
            currentUserID: userID,
            expectedCredentialRevision: expectedCredentialRevision
        )
        try Task.checkCancellation()
        guard isCurrent(sessionGeneration, roomID: expectedRoom.id) else { throw CancellationError() }
        guard status.inRoom, let statusRoom = status.room, statusRoom.id == expectedRoom.id else {
            throw ListenTogetherControllerError.notInRoom
        }
        room = statusRoom

        if reconnectRealtime {
            let credentials = try await service.realtimeCredentials(
                expectedCredentialRevision: expectedCredentialRevision
            )
            try Task.checkCancellation()
            guard isCurrent(sessionGeneration, roomID: statusRoom.id) else { throw CancellationError() }
            await cancelDisconnectTask()
            try Task.checkCancellation()
            guard isCurrent(sessionGeneration, roomID: statusRoom.id) else { throw CancellationError() }
            realtimeGeneration = sessionGeneration
            try await realtime.connect(
                roomID: statusRoom.chatRoomID,
                credentials: credentials,
                generation: sessionGeneration
            )
            try Task.checkCancellation()
            guard isCurrent(sessionGeneration, roomID: statusRoom.id) else { throw CancellationError() }
        }
        try await synchronizeState(
            roomID: statusRoom.id,
            generation: sessionGeneration,
            expectedCredentialRevision: expectedCredentialRevision
        )
        applyPendingRemoteEvent()
    }

    private func synchronizeState(
        roomID: String,
        generation sessionGeneration: Int,
        expectedCredentialRevision: UInt64
    ) async throws {
        let localOrder = player.currentQueueOrder
        let state = try await service.authoritativeState(
            roomID: roomID,
            displaySongIDs: localOrder.displaySongIDs,
            randomSongIDs: localOrder.randomSongIDs,
            anchorSongID: localOrder.anchorSongID,
            expectedCredentialRevision: expectedCredentialRevision
        )
        try Task.checkCancellation()
        guard isCurrent(sessionGeneration, roomID: roomID) else { throw CancellationError() }
        guard let state else { return }
        let playlist = state.playlist
        let anchorSongID = state.playback?.targetSongID ?? playlist.anchorSongID
        let authoritativeOrder = PlayerQueueOrder(
            displaySongIDs: playlist.displaySongIDs,
            randomSongIDs: playlist.randomSongIDs,
            anchorSongID: anchorSongID
        )
        guard player.replaceQueueAuthoritatively(authoritativeOrder) else {
            throw ListenTogetherControllerError.invalidPlaylist
        }
        playlistVersion = max(playlistVersion, playlist.version)
        if let playback = state.playback { apply(playback) }
    }

    private func startHeartbeat(generation sessionGeneration: Int, immediately: Bool) {
        guard room != nil, !isSleeping else { return }
        let previous = heartbeatTask
        previous?.cancel()
        heartbeatTask = Task { @MainActor [weak self] in
            if let previous { await previous.value }
            await self?.heartbeatLoop(generation: sessionGeneration, immediately: immediately)
        }
    }

    private func heartbeatLoop(generation sessionGeneration: Int, immediately: Bool) async {
        guard let expectedCredentialRevision = credentialRevision else { return }
        var sendImmediately = immediately
        while isCurrent(sessionGeneration), !isSleeping, !Task.isCancelled {
            if !sendImmediately {
                do {
                    try await Task.sleep(for: .seconds(heartbeatInterval))
                } catch {
                    return
                }
            }
            sendImmediately = false
            guard let currentRoom = room, let songID = player.currentSongID else { continue }
            do {
                let heartbeat = try await service.heartbeatState(
                    roomID: currentRoom.id,
                    songID: songID,
                    playStatus: player.isPlaybackRequested ? .playing : .paused,
                    progress: milliseconds(player.position),
                    expectedCredentialRevision: expectedCredentialRevision
                )
                try Task.checkCancellation()
                guard isCurrent(sessionGeneration, roomID: currentRoom.id) else { return }
                guard heartbeat.succeeded else { throw ListenTogetherControllerError.heartbeatRejected }
                heartbeatInterval = heartbeat.intervalSeconds
            } catch is CancellationError {
                return
            } catch {
                guard isCurrent(sessionGeneration, roomID: currentRoom.id) else { return }
                errorMessage = error.localizedDescription
                requestReconciliation(reconnect: true)
                return
            }
        }
    }

    private func exitRoom() async {
        guard let currentRoom = room,
              let userID = currentUserID,
              let expectedCredentialRevision = credentialRevision
        else { return }
        let expectedAccountRevision = accountRevision
        let disconnectGeneration = realtimeGeneration
        let sessionGeneration = invalidateSessionWork(retainingRoomState: true)
        room = currentRoom
        phase = .ending(currentRoom)
        player.setControlInteractionLocked(true)
        do {
            guard try await service.endRoomConfirmed(
                roomID: currentRoom.id,
                expectedCredentialRevision: expectedCredentialRevision
            ) else {
                throw ListenTogetherControllerError.exitRejected
            }
            try Task.checkCancellation()
            guard isCurrent(sessionGeneration, userID: userID, roomID: currentRoom.id) else { return }
            clearSession(phase: .ended(reason: nil))
            await disconnectRealtime(generation: disconnectGeneration)
        } catch is CancellationError {
        } catch {
            let exitError = error
            guard isCurrent(
                sessionGeneration,
                accountRevision: expectedAccountRevision,
                credentialRevision: expectedCredentialRevision,
                userID: userID,
                roomID: currentRoom.id
            ) else { return }
            do {
                let status = try await service.status(
                    currentUserID: userID,
                    expectedCredentialRevision: expectedCredentialRevision
                )
                try Task.checkCancellation()
                guard isCurrent(
                    sessionGeneration,
                    accountRevision: expectedAccountRevision,
                    credentialRevision: expectedCredentialRevision,
                    userID: userID,
                    roomID: currentRoom.id
                ) else { return }
                if !status.inRoom {
                    clearSession(phase: .ended(reason: nil))
                    await disconnectRealtime(generation: disconnectGeneration)
                    return
                }
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled,
                      isCurrent(
                        sessionGeneration,
                        accountRevision: expectedAccountRevision,
                        credentialRevision: expectedCredentialRevision,
                        userID: userID,
                        roomID: currentRoom.id
                      )
                else { return }
            }
            room = currentRoom
            installPlayerGate()
            fail(exitError, generation: sessionGeneration)
        }
    }

    private func finishSession(reason: String?) {
        let disconnectGeneration = realtimeGeneration
        invalidateSessionWork()
        retireCurrentRoomOperation()
        clearSession(phase: .ended(reason: reason))
        statusMessage = reason ?? "一起听房间已结束"
        scheduleDisconnect(generation: disconnectGeneration)
    }

    private func performRoomOperation(
        allowWhenBlocked: Bool = false,
        _ operation: @escaping @MainActor @Sendable () async -> Void
    ) async {
        if !allowWhenBlocked, roomOperationsBlocked {
            guard let accountTask else { return }
            let expectedAccountRevision = accountRevision
            let expectedCredentialRevision = service.credentialRevision
            accountBootstrapWaitObserver?()
            await accountTask.value
            guard !Task.isCancelled,
                  accountRevision == expectedAccountRevision,
                  credentialRevision == expectedCredentialRevision,
                  service.credentialRevision == expectedCredentialRevision,
                  !roomOperationsBlocked
            else { return }
        }
        if let roomOperationTask {
            await roomOperationTask.value
            return
        }
        let taskID = UUID()
        let task = Task { @MainActor [weak self] in
            if !Task.isCancelled { await operation() }
            self?.finishRoomOperation(taskID)
        }
        roomOperationTaskID = taskID
        roomOperationTask = task
        await task.value
    }

    private func retireCurrentRoomOperation() {
        guard let taskID = roomOperationTaskID, let task = roomOperationTask else { return }
        roomOperationTaskID = nil
        roomOperationTask = nil
        retiredRoomOperations[taskID] = task
        task.cancel()
    }

    private func finishRoomOperation(_ taskID: UUID) {
        if roomOperationTaskID == taskID {
            roomOperationTaskID = nil
            roomOperationTask = nil
        }
        retiredRoomOperations.removeValue(forKey: taskID)
    }

    private func drainRoomOperations() async {
        while let task = roomOperationTask ?? retiredRoomOperations.values.first {
            await task.value
        }
    }

    private func cleanUpInvalidatedRoom(
        _ room: ListenTogetherRoom,
        expectedCredentialRevision: UInt64
    ) async {
        guard service.credentialRevision == expectedCredentialRevision else { return }
        let cleanup = Task { [service] in
            try? await service.endRoomConfirmed(
                roomID: room.id,
                expectedCredentialRevision: expectedCredentialRevision
            )
        }
        _ = await cleanup.value
    }

    private func scheduleDisconnect(generation: Int?) {
        guard let generation else { return }
        disconnectTaskRevision += 1
        let revision = disconnectTaskRevision
        let previous = disconnectTask
        previous?.cancel()
        disconnectTask = Task { @MainActor [weak self, realtime] in
            if let previous { await previous.value }
            guard let self,
                  self.disconnectTaskRevision == revision,
                  !Task.isCancelled
            else { return }
            await realtime.disconnect(generation: generation)
            guard self.disconnectTaskRevision == revision else { return }
            if self.realtimeGeneration == generation { self.realtimeGeneration = nil }
            self.disconnectTask = nil
        }
    }

    private func disconnectRealtime(generation: Int?) async {
        scheduleDisconnect(generation: generation)
        if let disconnectTask { await disconnectTask.value }
    }

    private func cancelDisconnectTask() async {
        guard let previous = disconnectTask else { return }
        disconnectTaskRevision += 1
        disconnectTask = nil
        previous.cancel()
        await previous.value
    }

    @discardableResult
    private func beginRoomOperation(phase newPhase: ListenTogetherPhase) -> Int {
        accountTask?.cancel()
        accountTask = nil
        let sessionGeneration = invalidateSessionWork()
        resetSequences()
        player.controlInterceptor = nil
        player.setControlInteractionLocked(false)
        phase = newPhase
        errorMessage = nil
        statusMessage = nil
        isSleeping = false
        return sessionGeneration
    }

    @discardableResult
    private func invalidateSessionWork(retainingRoomState: Bool = false) -> Int {
        generation += 1
        heartbeatTask?.cancel()
        reconcileTask?.cancel()
        commandTask?.cancel()
        hostSnapshotTask?.cancel()
        remoteApplyTask?.cancel()
        heartbeatTask = nil
        reconcileTask = nil
        commandTask = nil
        hostSnapshotTask = nil
        remoteApplyTask = nil
        reconciliationRequested = false
        reconciliationRequiresReconnect = false
        isReconciling = false
        isSendingCommand = false
        pendingRemoteSequence = nil
        pendingRemoteCommand = nil
        isEstablishingSession = false
        if !retainingRoomState { room = nil }
        return generation
    }

    private func clearSession(phase newPhase: ListenTogetherPhase) {
        room = nil
        player.controlInterceptor = nil
        player.setControlInteractionLocked(false)
        resetSequences()
        isSleeping = false
        isReconciling = false
        isEstablishingSession = false
        isSendingCommand = false
        errorMessage = nil
        phase = newPhase
    }

    private func resetSequences() {
        nextClientSequence = 1
        playlistVersion = 0
        lastAppliedRemoteSequence = 0
        pendingRemoteSequence = nil
        pendingRemoteCommand = nil
        heartbeatInterval = Self.fallbackHeartbeatInterval
    }

    private func setConnected(_ connectedRoom: ListenTogetherRoom) {
        room = connectedRoom
        phase = .connected(connectedRoom)
        player.setControlInteractionLocked(!isConnected)
        statusMessage = "\(connectedRoom.members.count) 人正在一起听"
    }

    private func fail(_ error: any Error, generation expectedGeneration: Int) {
        guard generation == expectedGeneration else { return }
        let message = error.localizedDescription
        errorMessage = message
        phase = .failed(message)
        player.setControlInteractionLocked(room != nil)
    }

    private func authenticatedUserID() -> Int64? {
        guard let currentUserID, currentUserID > 0 else {
            let message = "请先登录后使用一起听"
            errorMessage = message
            phase = .failed(message)
            return nil
        }
        return currentUserID
    }

    private func reserveClientSequence() throws -> Int64 {
        guard nextClientSequence > 0, nextClientSequence < .max else {
            throw ListenTogetherControllerError.sequenceExhausted
        }
        defer { nextClientSequence += 1 }
        return nextClientSequence
    }

    private func reservePlaylistVersion() throws -> Int64 {
        guard playlistVersion < .max else { throw ListenTogetherControllerError.sequenceExhausted }
        playlistVersion += 1
        return playlistVersion
    }

    private func milliseconds(_ seconds: TimeInterval) throws -> Int64 {
        guard seconds.isFinite, seconds >= 0, seconds <= 604_800 else {
            throw ListenTogetherControllerError.invalidProgress
        }
        return Int64((seconds * 1_000).rounded())
    }

    private func isCurrent(_ expectedGeneration: Int) -> Bool {
        generation == expectedGeneration
            && room != nil
            && accountRevision == sessionAccountRevision
            && credentialRevision == service.credentialRevision
    }

    private func isCurrent(_ expectedGeneration: Int, userID: Int64) -> Bool {
        generation == expectedGeneration
            && currentUserID == userID
            && accountRevision == sessionAccountRevision
            && credentialRevision == service.credentialRevision
    }

    private func isCurrent(_ expectedGeneration: Int, roomID: String) -> Bool {
        generation == expectedGeneration
            && room?.id == roomID
            && accountRevision == sessionAccountRevision
            && credentialRevision == service.credentialRevision
    }

    private func isCurrent(_ expectedGeneration: Int, userID: Int64, roomID: String) -> Bool {
        generation == expectedGeneration
            && currentUserID == userID
            && room?.id == roomID
            && accountRevision == sessionAccountRevision
            && credentialRevision == service.credentialRevision
    }

    private func isCurrent(
        _ expectedGeneration: Int,
        accountRevision expectedAccountRevision: Int,
        credentialRevision expectedCredentialRevision: UInt64,
        userID: Int64? = nil,
        roomID: String? = nil
    ) -> Bool {
        generation == expectedGeneration
            && accountRevision == expectedAccountRevision
            && credentialRevision == expectedCredentialRevision
            && service.credentialRevision == expectedCredentialRevision
            && (userID.map({ currentUserID == $0 }) ?? true)
            && (roomID.map({ room?.id == $0 }) ?? true)
    }

    private func isCurrentAccount(
        _ expectedAccountRevision: Int,
        credentialRevision expectedCredentialRevision: UInt64
    ) -> Bool {
        accountRevision == expectedAccountRevision
            && service.credentialRevision == expectedCredentialRevision
    }
}

private enum ListenTogetherControllerError: LocalizedError {
    case notInRoom
    case invalidPlaylist
    case heartbeatRejected
    case exitRejected
    case commandRejected
    case sequenceExhausted
    case invalidProgress

    var errorDescription: String? {
        switch self {
        case .notInRoom: "一起听房间已结束"
        case .invalidPlaylist: "服务端返回了无效的播放队列"
        case .heartbeatRejected: "一起听心跳未被服务端接受"
        case .exitRejected: "服务端未确认退出一起听"
        case .commandRejected: "服务端未确认播放操作，请稍后重试"
        case .sequenceExhausted: "一起听命令序列已耗尽，请重新加入"
        case .invalidProgress: "播放进度无效"
        }
    }
}

enum ListenTogetherSequenceDecision: Equatable {
    case discard
    case apply
    case reconcile
}
