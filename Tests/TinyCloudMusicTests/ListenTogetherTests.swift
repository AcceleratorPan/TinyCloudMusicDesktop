import Foundation
import Testing
@testable import TinyCloudMusic

@Suite("Listen together")
struct ListenTogetherTests {
    @Test("Official invitations round-trip and reject untrusted URLs")
    func invitations() throws {
        let room = ListenTogetherRoom(
            id: "room-42",
            chatRoomID: "chat-42",
            creatorID: 42,
            role: .host,
            members: [],
            startedAt: nil
        )
        let url = try #require(room.invitationURL(songID: 2_671_812_705))
        let invitation = try ListenTogetherInvitation.parse(url.absoluteString, inviterID: "")
        #expect(invitation == (try ListenTogetherInvitation(roomID: "room-42", inviterID: 42)))
        #expect((try? ListenTogetherInvitation.parse("http://st.music.163.com/listen-together/share/", inviterID: "42")) == nil)
        #expect((try? ListenTogetherInvitation.parse("https://example.com/listen-together/share/", inviterID: "42")) == nil)
    }

    @Test("Realtime messages decode strict known types")
    func realtimeMessages() throws {
        let play = try ListenTogetherResponseDecoder.remoteEvent(
            from: #"{"content":{"type":20000,"content":{"serverSeq":7,"commandType":"PROGRESS","formerSongId":2671812705,"targetSongId":2671812705,"progress":1500,"playStatus":"PLAY"}}}"#
        )
        #expect(play == .play(ListenTogetherRemotePlayCommand(
            commandType: .progress,
            progressMilliseconds: 1_500,
            playStatus: .playing,
            formerSongID: 2_671_812_705,
            targetSongID: 2_671_812_705,
            serverSequence: 7
        )))
        #expect(try ListenTogetherResponseDecoder.remoteEvent(
            from: #"{"ext":{"serverExt":{"type":20000,"content":{"serverSeq":7,"commandType":"PROGRESS","formerSongId":"2671812705","targetSongId":"2671812705","progress":1500,"playStatus":"PLAY"}}}}"#
        ) == play)
        #expect(try ListenTogetherResponseDecoder.remoteEvent(
            from: #"{"content":{"type":20001,"content":{"serverSeq":8}}}"#
        )
            == .playlistChanged(serverSequence: 8))
        #expect(try ListenTogetherResponseDecoder.remoteEvent(
            from: #"{"content":{"type":20002,"content":{}}}"#
        ) == .memberJoined)
        #expect(try ListenTogetherResponseDecoder.remoteEvent(
            from: #"{"ext":{"serverExt":{"type":20003,"content":{"exitType":"ROOM_EMPTY"}}}}"#
        ) == .roomEnded(reason: nil))
        #expect(try ListenTogetherResponseDecoder.remoteEvent(
            from: #"{"content":{"type":20008,"content":{"ignoreUserIds":[42]}}}"#
        ) == .heartbeatRequested(ignoredUserIDs: [42]))
        let protocolMessage = try JSONSerialization.data(withJSONObject: [
            "msg_type": 100,
            "attach": #"{"content":{"type":20002,"content":{}}}"#
        ])
        let localMessage = try JSONSerialization.data(withJSONObject: [
            "rescode": 200,
            "content": try #require(String(data: protocolMessage, encoding: .utf8))
        ])
        #expect(try ListenTogetherResponseDecoder.remoteEvent(
            from: try #require(String(data: localMessage, encoding: .utf8))
        ) == .memberJoined)
        let nativeProtocolMessage = try JSONSerialization.data(withJSONObject: [
            "msg_type": 100,
            "msg_attach": #"{"content":{"type":20002,"content":{}}}"#
        ])
        let nativeLocalMessage = try JSONSerialization.data(withJSONObject: [
            "rescode": 200,
            "content": try #require(String(data: nativeProtocolMessage, encoding: .utf8))
        ])
        #expect(try ListenTogetherResponseDecoder.remoteEvent(
            from: try #require(String(data: nativeLocalMessage, encoding: .utf8))
        ) == .memberJoined)
        #expect(try ListenTogetherResponseDecoder.remoteEvent(
            from: #"{"event_type":20000,"config":"{\"serverSeq\":9,\"commandType\":\"PAUSE\",\"formerSongId\":2671812705,\"targetSongId\":2671812705,\"progress\":2500,\"playStatus\":\"PAUSE\"}"}"#
        ) == .play(ListenTogetherRemotePlayCommand(
            commandType: .pause,
            progressMilliseconds: 2_500,
            playStatus: .paused,
            formerSongID: 2_671_812_705,
            targetSongID: 2_671_812_705,
            serverSequence: 9
        )))
        #expect((try? ListenTogetherResponseDecoder.remoteEvent(
            from: #"{"content":{"type":20000,"content":{"serverSeq":0}}}"#
        )) == nil)
        #expect((try? ListenTogetherResponseDecoder.remoteEvent(
            from: #"{"content":{"type":29999,"content":{}}}"#
        )) == nil)
    }

    @Test("Authoritative state decodes playlist and playback snapshot")
    func authoritativeState() throws {
        let decoded = try ListenTogetherResponseDecoder.authoritativeState(from: Data(#"""
        {
          "code": 200,
          "data": {
            "playList": {
              "displayList": [2671812705, 1],
              "randomList": [1, 2671812705],
              "anchorSongId": 2671812705,
              "version": 4
            },
            "playCommand": {
              "commandType": "PROGRESS",
              "progress": 1500,
              "playStatus": "PLAY",
              "formerSongId": 2671812705,
              "targetSongId": 2671812705
            }
          }
        }
        """#.utf8))
        let state = try #require(decoded)
        #expect(state.playlist == ListenTogetherPlaylist(
            displaySongIDs: [2_671_812_705, 1],
            randomSongIDs: [1, 2_671_812_705],
            anchorSongID: 2_671_812_705,
            version: 4
        ))
        #expect(state.playback == ListenTogetherPlaybackSnapshot(
            commandType: .progress,
            progressMilliseconds: 1_500,
            playStatus: .playing,
            formerSongID: 2_671_812_705,
            targetSongID: 2_671_812_705
        ))
        let official = try ListenTogetherResponseDecoder.authoritativeState(from: Data(#"""
        {
          "code": 200,
          "data": {
            "playlist": {
              "displayList": {"changed": true, "result": ["2671812705"], "rcmdSongIds": []},
              "randomList": null,
              "version": [{"userId": 42, "version": 1}]
            },
            "playCommand": null
          }
        }
        """#.utf8))
        #expect(official?.playlist.displaySongIDs == [2_671_812_705])
        #expect(official?.playlist.randomSongIDs == [2_671_812_705])
    }

    @Test("Rooms decode the server session start time")
    func roomStartTime() throws {
        let room = try ListenTogetherResponseDecoder.room(
            from: Data(#"{"code":200,"data":{"roomInfo":{"roomId":"room-1","chatRoomId":"chat-1","creatorId":42,"roomCreateTime":1785257186329,"roomUsers":[]}}}"#.utf8),
            currentUserID: 42
        )
        let startedAt = try #require(room.startedAt)
        #expect(abs(startedAt.timeIntervalSince1970 - 1_785_257_186.329) < 0.001)
    }

    @Test("Realtime credentials use accId and allow a missing address list")
    func realtimeCredentials() throws {
        let credentials = try ListenTogetherResponseDecoder.realtimeCredentials(
            from: Data(#"{"code":200,"data":{"uid":"wrong","accId":"account","token":"token"}}"#.utf8)
        )
        #expect(credentials == ListenTogetherRealtimeCredentials(
            accountID: "account",
            token: "token",
            addresses: []
        ))
    }

    @Test("Native realtime SDK and chatroom ABI are bundled")
    @MainActor
    func realtimeSDKIsBundled() throws {
        let urls = try #require(NIMChatroomTransport.bundledNativeSDKURLs())
        #expect(NIMChatroomTransport.sdkVersion == "10.9.40")
        #expect(urls.map(\.lastPathComponent) == [
            "libh_available.dylib",
            "libnim.dylib",
            "libnim_chatroom.dylib"
        ])
        #expect(urls.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })

        let client = try Data(contentsOf: urls[1], options: .mappedIfSafe)
        let chatroom = try Data(contentsOf: urls[2], options: .mappedIfSafe)
        #expect(client.range(of: Data("nim_plugin_chatroom_request_enter_async".utf8)) != nil)
        #expect(chatroom.range(of: Data("nim_chatroom_enter".utf8)) != nil)
        #expect(chatroom.range(of: Data("nim_chatroom_reg_receive_msg_cb".utf8)) != nil)
        #expect(chatroom.range(of: Data("nim_chatroom_exit".utf8)) != nil)
    }

    @Test("Live realtime credential diagnostics")
    func liveRealtimeCredentialDiagnostics() async throws {
        guard ProcessInfo.processInfo.environment["TINYCLOUDMUSIC_RUN_LISTEN_TOGETHER_TOKEN_DIAGNOSTIC"] == "1" else {
            return
        }

        let credentials = try listenTogetherLiveCredentials(role: "member")
        let transport = EAPITransport(cookie: credentials.cookie, musicU: credentials.musicU)
        let userID = try await listenTogetherLiveUserID(transport: transport)
        let first = try await listenTogetherTokenMetadata(
            transport: transport,
            userID: userID,
            host: "https://interface3.music.163.com"
        )
        let second = try await listenTogetherTokenMetadata(
            transport: transport,
            userID: userID,
            host: "https://interface3.music.163.com"
        )
        let standardHost = try await listenTogetherTokenMetadata(
            transport: transport,
            userID: userID,
            host: "https://interface.music.163.com"
        )

        print(
            "Listen together token metadata: fields=\(first.fields), "
                + "uidLength=\(first.uid.count), accIdLength=\(first.accountID.count), "
                + "tokenLength=\(first.token.count), uidMatchesUser=\(first.uidMatchesUser), "
                + "accIdMatchesUser=\(first.accountIDMatchesUser), "
                + "uidStable=\(first.uid == second.uid), "
                + "accIdStable=\(first.accountID == second.accountID), "
                + "tokenStable=\(first.token == second.token), "
                + "hostsReturnSameUid=\(first.uid == standardHost.uid), "
                + "hostsReturnSameAccId=\(first.accountID == standardHost.accountID), "
                + "hostsReturnSameToken=\(first.token == standardHost.token)"
        )
    }

    @Test("Remote sequence decisions drop duplicates and reconcile gaps")
    @MainActor
    func sequenceDecisions() {
        #expect(ListenTogetherController.sequenceDecision(lastApplied: 0, incoming: 9) == .apply)
        #expect(ListenTogetherController.sequenceDecision(lastApplied: 9, incoming: 9) == .discard)
        #expect(ListenTogetherController.sequenceDecision(lastApplied: 9, incoming: 8) == .discard)
        #expect(ListenTogetherController.sequenceDecision(lastApplied: 9, incoming: 10) == .apply)
        #expect(ListenTogetherController.sequenceDecision(lastApplied: 9, incoming: 11) == .reconcile)
    }

    @Test("Authoritative player changes do not feed back into local commands")
    @MainActor
    func authoritativeSuppression() {
        let player = PlayerController(repository: FixtureMusicRepository(), crossfadeDuration: 0)
        let song = Song(
            id: 1,
            name: "Test",
            artists: [ArtistSummary(id: 1, name: "Artist")],
            album: AlbumSummary(
                id: 1,
                name: "Album",
                artwork: Artwork(symbol: "music.note", accent: .red)
            ),
            duration: .seconds(180)
        )
        player.play(song, in: [song])

        let recorder = PlayerControlRecorder()
        player.controlInterceptor = { _, commit in
            recorder.count += 1
            commit()
            return true
        }
        player.applyAuthoritatively { player.setPlayback(false) }
        #expect(recorder.count == 0)

        player.setPlayback(true)
        #expect(recorder.count == 1)
    }

    @Test("Live two-account realtime delivery")
    @MainActor
    func liveRealtimeDelivery() async throws {
        guard ProcessInfo.processInfo.environment["TINYCLOUDMUSIC_RUN_LISTEN_TOGETHER_REALTIME_LIVE"] == "1" else {
            return
        }
        guard let role = ListenTogetherLiveRole(
            rawValue: ProcessInfo.processInfo.environment[
                "TINYCLOUDMUSIC_LISTEN_TOGETHER_REALTIME_ROLE"
            ] ?? ""
        ) else { throw ListenTogetherLiveTestError.missingCoordination }
        let coordination = try ListenTogetherLiveCoordination(role: role)

        switch role {
        case .host:
            try await runListenTogetherHostLiveSmoke(coordination: coordination)
        case .member:
            try await runListenTogetherMemberLiveSmoke(coordination: coordination)
        }
    }

}

@Suite("Listen together controller lifecycle", .serialized)
@MainActor
struct ListenTogetherControllerLifecycleTests {
    @Test("Rapid create and logout perform one write and clean the created room")
    func roomOperationsAreExclusive() async {
        ListenTogetherControllerProtocol.reset([
            "/weapi/listen/together/status/get": .init(Self.notInRoom),
            "/eapi/listen/together/room/create": .init(Self.room, delay: 0.15),
            "/api/middle/im/token/get": .init(Self.credentials),
            "/eapi/listen/together/end/v2": .init(Self.succeeded)
        ])
        let realtime = ListenTogetherRealtimeStub()
        let controller = makeController(realtime: realtime)
        controller.updateAccount(42)
        await wait { controller.currentUserID == 42 }

        let firstCreate = Task { @MainActor in await controller.createRoom() }
        await wait {
            ListenTogetherControllerProtocol.requestCount(for: "/eapi/listen/together/room/create") == 1
        }
        firstCreate.cancel()
        let duplicateCreate = Task { @MainActor in await controller.createRoom() }
        let firstLogout = Task { @MainActor in await controller.prepareForLogout() }
        let duplicateLogout = Task { @MainActor in await controller.prepareForLogout() }
        await firstCreate.value
        await duplicateCreate.value
        await firstLogout.value
        await duplicateLogout.value

        #expect(ListenTogetherControllerProtocol.requestCount(
            for: "/eapi/listen/together/room/create"
        ) == 1)
        #expect(ListenTogetherControllerProtocol.requestCount(
            for: "/eapi/listen/together/end/v2"
        ) == 1)
        #expect(realtime.connectCount == 1)
        #expect(controller.room == nil)
        #expect(controller.currentUserID == nil)
    }

    @Test("Recovery connects before authority and preserves a message received during reconciliation")
    func recoveryBuffersRealtimeMessages() async throws {
        ListenTogetherControllerProtocol.reset([
            "/weapi/listen/together/status/get": .init(Self.inRoom),
            "/api/middle/im/token/get": .init(Self.credentials),
            "/eapi/listen/together/sync/playlist/get": .init(Self.authoritativePaused),
            "/eapi/listen/together/heartbeat": .init(Self.heartbeat),
            "/eapi/listen/together/play/command/report": .init(Self.succeeded),
            "/eapi/listen/together/end/v2": .init(Self.succeeded)
        ])
        let realtime = ListenTogetherRealtimeStub(messageOnConnect: Self.remotePlay)
        let player = PlayerController(repository: FixtureMusicRepository(), crossfadeDuration: 0)
        let controller = makeController(player: player, realtime: realtime)
        controller.updateAccount(42)
        await wait {
            if case .recoveryAvailable = controller.phase { return true }
            return false
        }
        ListenTogetherControllerProtocol.clearEvents()

        controller.recover()
        await wait { controller.isConnected && player.currentSongID == 2 }

        let events = ListenTogetherControllerProtocol.events
        let statusIndex = try #require(events.firstIndex(of: "/weapi/listen/together/status/get"))
        let connectIndex = try #require(events.firstIndex(of: "realtime-connect"))
        let authorityIndex = try #require(events.firstIndex(of: "/eapi/listen/together/sync/playlist/get"))
        #expect(statusIndex < connectIndex)
        #expect(connectIndex < authorityIndex)
        #expect(player.currentSongID == 2)
        #expect(controller.isConnected)

        await controller.prepareForLogout()
    }

    @Test("Successful reconciliation clears an earlier error")
    func reconciliationClearsEarlierError() async {
        ListenTogetherControllerProtocol.reset([
            "/weapi/listen/together/status/get": .init(Self.inRoom, delay: 0.05),
            "/api/middle/im/token/get": .init(Self.credentials),
            "/eapi/listen/together/sync/playlist/get": .init(Self.authoritativePaused),
            "/eapi/listen/together/sync/list/command/report": .init(#"{"code":500}"#),
            "/eapi/listen/together/heartbeat": .init(Self.heartbeat),
            "/eapi/listen/together/end/v2": .init(Self.succeeded)
        ])
        let realtime = ListenTogetherRealtimeStub()
        let controller = makeController(realtime: realtime)
        controller.updateAccount(42)
        await wait {
            if case .recoveryAvailable = controller.phase { return true }
            return false
        }
        controller.recover()
        await wait { controller.isConnected }

        realtime.send(#"{"content":{"type":20002,"content":{}}}"#)
        await wait { controller.isReconciling }
        await wait { controller.errorMessage != nil }
        #expect(controller.errorMessage != nil)
        await wait { !controller.isReconciling }

        #expect(controller.errorMessage == nil)
        #expect(ListenTogetherControllerProtocol.requestCount(
            for: "/eapi/listen/together/sync/list/command/report"
        ) == 1)
        await controller.prepareForLogout()
    }

    @Test("Reconciliation drops a superseded command and remote end clears the session")
    func reconciliationDropsSupersededCommand() async {
        ListenTogetherControllerProtocol.reset([
            "/weapi/listen/together/status/get": .init(Self.inRoom),
            "/api/middle/im/token/get": .init(Self.credentials),
            "/eapi/listen/together/sync/playlist/get": .init(Self.authoritativePaused),
            "/eapi/listen/together/heartbeat": .init(Self.heartbeat),
            "/eapi/listen/together/end/v2": .init(Self.succeeded)
        ])
        #expect((try? ListenTogetherResponseDecoder.remoteEvent(from: Self.remoteUnknownSong)) != nil)
        let realtime = ListenTogetherRealtimeStub(messageOnConnect: Self.remoteUnknownSong)
        let player = PlayerController(repository: FixtureMusicRepository(), crossfadeDuration: 0)
        let controller = makeController(player: player, realtime: realtime)
        controller.updateAccount(42)
        await wait {
            if case .recoveryAvailable = controller.phase { return true }
            return false
        }

        controller.recover()
        await wait { controller.isConnected }

        #expect(realtime.connectCount == 1)
        #expect(realtime.emittedMessageCount == 1)
        #expect(controller.errorMessage == nil)
        #expect(player.currentSongID == 1)

        realtime.send(Self.remoteEnded)
        await wait { controller.room == nil }
        #expect(controller.phase == .ended(reason: nil))
        #expect(controller.errorMessage == nil)
        #expect(!player.isControlInteractionLocked)
        #expect(!player.isSharedControlActive)
    }

    @Test("Joining connects before authority and preserves a message received during setup")
    func joinBuffersRealtimeMessages() async throws {
        ListenTogetherControllerProtocol.reset([
            "/weapi/listen/together/status/get": .init(Self.notInRoom),
            "/eapi/listen/together/play/invitation/accept": .init(Self.room),
            "/api/middle/im/token/get": .init(Self.credentials),
            "/eapi/listen/together/sync/playlist/get": .init(Self.authoritativePaused),
            "/eapi/listen/together/heartbeat": .init(Self.heartbeat),
            "/eapi/listen/together/play/command/report": .init(Self.succeeded),
            "/eapi/listen/together/end/v2": .init(Self.succeeded)
        ])
        let realtime = ListenTogetherRealtimeStub(messageOnConnect: Self.remotePlay)
        let player = PlayerController(repository: FixtureMusicRepository(), crossfadeDuration: 0)
        let controller = makeController(player: player, realtime: realtime)
        controller.updateAccount(84)
        await wait { controller.currentUserID == 84 }
        ListenTogetherControllerProtocol.clearEvents()

        await controller.join(try ListenTogetherInvitation(roomID: "room-1", inviterID: 42))

        let events = ListenTogetherControllerProtocol.events
        let acceptIndex = try #require(events.firstIndex(
            of: "/eapi/listen/together/play/invitation/accept"
        ))
        let connectIndex = try #require(events.firstIndex(of: "realtime-connect"))
        let authorityIndex = try #require(events.firstIndex(
            of: "/eapi/listen/together/sync/playlist/get"
        ))
        #expect(acceptIndex < connectIndex)
        #expect(connectIndex < authorityIndex)
        #expect(player.currentSongID == 2)
        #expect(controller.isConnected)

        await controller.prepareForLogout()
    }

    private func makeController(
        player: PlayerController = PlayerController(repository: FixtureMusicRepository(), crossfadeDuration: 0),
        realtime: ListenTogetherRealtimeStub
    ) -> ListenTogetherController {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ListenTogetherControllerProtocol.self]
        let transport = EAPITransport(
            session: URLSession(configuration: configuration),
            cookie: "",
            musicU: ""
        )
        return ListenTogetherController(
            service: LiveListenTogetherService(transport: transport),
            player: player,
            realtime: realtime
        )
    }

    private func wait(until condition: @MainActor () -> Bool) async {
        for _ in 0..<200 where !condition() {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private static let room = #"{"code":200,"data":{"roomInfo":{"roomId":"room-1","chatRoomId":"chat-1","creatorId":42,"roomUsers":[{"userId":42,"nickname":"Host"}]}}}"#
    private static let notInRoom = #"{"code":200,"data":{"inRoom":false,"status":"NOT_IN_ROOM"}}"#
    private static let inRoom = #"{"code":200,"data":{"inRoom":true,"status":"IN_ROOM","roomInfo":{"roomId":"room-1","chatRoomId":"chat-1","creatorId":42,"roomUsers":[{"userId":42,"nickname":"Host"}]}}}"#
    private static let credentials = #"{"code":200,"data":{"accId":"account","token":"token"}}"#
    private static let succeeded = #"{"code":200,"data":{"result":true}}"#
    private static let heartbeat = #"{"code":200,"data":{"result":true,"timeSpan":30}}"#
    private static let authoritativePaused = #"{"code":200,"data":{"playList":{"displayList":[1,2],"randomList":[1,2],"anchorSongId":1,"version":1},"playCommand":{"commandType":"PROGRESS","progress":1000,"playStatus":"PAUSE","formerSongId":1,"targetSongId":1}}}"#
    private static let remotePlay = #"{"content":{"type":20000,"content":{"serverSeq":1,"commandType":"GOTO","formerSongId":1,"targetSongId":2,"progress":2000,"playStatus":"PAUSE"}}}"#
    private static let remoteUnknownSong = #"{"content":{"type":20000,"content":{"serverSeq":1,"commandType":"GOTO","formerSongId":1,"targetSongId":999,"progress":0,"playStatus":"PAUSE"}}}"#
    private static let remoteEnded = #"{"ext":{"serverExt":{"type":20003,"content":{"exitType":"ROOM_EMPTY"}}}}"#
}

private final class ListenTogetherControllerProtocol: URLProtocol, @unchecked Sendable {
    struct Stub: Sendable {
        let body: Data
        let delay: TimeInterval

        init(_ body: String, delay: TimeInterval = 0) {
            self.body = Data(body.utf8)
            self.delay = delay
        }
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var stubs: [String: Stub] = [:]
    nonisolated(unsafe) private static var recordedEvents: [String] = []

    static var events: [String] { lock.withLock { recordedEvents } }

    static func reset(_ stubs: [String: Stub]) {
        lock.withLock {
            self.stubs = stubs
            recordedEvents = []
        }
    }

    static func clearEvents() {
        lock.withLock { recordedEvents = [] }
    }

    static func record(_ event: String) {
        lock.withLock { recordedEvents.append(event) }
    }

    static func requestCount(for path: String) -> Int {
        lock.withLock { recordedEvents.count(where: { $0 == path }) }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let path = request.url?.path ?? ""
        let stub = Self.lock.withLock {
            Self.recordedEvents.append(path)
            return Self.stubs[path]
        } ?? Stub(#"{"code":404}"#)
        if stub.delay > 0 { Thread.sleep(forTimeInterval: stub.delay) }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: [:]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: stub.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@MainActor
private final class ListenTogetherRealtimeStub: ListenTogetherRealtimeTransport {
    var onEvent: ((NIMChatroomEvent) -> Void)?
    private(set) var connectCount = 0
    private(set) var emittedMessageCount = 0
    private var generation = 0
    private let messageOnConnect: String?

    init(messageOnConnect: String? = nil) {
        self.messageOnConnect = messageOnConnect
    }

    func connect(
        roomID: String,
        credentials: ListenTogetherRealtimeCredentials,
        generation: Int
    ) async throws {
        connectCount += 1
        self.generation = generation
        ListenTogetherControllerProtocol.record("realtime-connect")
        if connectCount == 1, let messageOnConnect {
            emittedMessageCount += 1
            onEvent?(.message(raw: messageOnConnect, generation: generation))
        }
    }

    func disconnect() async {
        ListenTogetherControllerProtocol.record("realtime-disconnect")
    }

    func send(_ raw: String) {
        onEvent?(.message(raw: raw, generation: generation))
    }
}

@MainActor
private final class PlayerControlRecorder {
    var count = 0
}

private enum ListenTogetherLiveRole: String {
    case host
    case member

    var peerFailureSignal: String {
        self == .host ? "member-failed" : "host-failed"
    }
}

private struct ListenTogetherLiveRoomDescriptor: Codable {
    let roomID: String
    let chatRoomID: String
    let inviterID: Int64
}

private struct ListenTogetherLivePlayStep {
    let type: ListenTogetherPlayCommandType
    let progress: Int64
    let status: ListenTogetherPlayStatus
    let formerSongID: Int64
}

private struct ListenTogetherLiveCoordination {
    private let directory: URL
    private let role: ListenTogetherLiveRole

    init(role: ListenTogetherLiveRole) throws {
        guard let path = ProcessInfo.processInfo.environment[
            "TINYCLOUDMUSIC_LISTEN_TOGETHER_COORDINATION_DIR"
        ], path.hasPrefix("/") else { throw ListenTogetherLiveTestError.missingCoordination }
        let directory = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              let permissions = try FileManager.default.attributesOfItem(atPath: directory.path)[
                .posixPermissions
              ] as? NSNumber,
              permissions.intValue & 0o077 == 0
        else { throw ListenTogetherLiveTestError.insecureCoordination }
        self.directory = directory
        self.role = role
    }

    func writeRoom(_ room: ListenTogetherLiveRoomDescriptor) throws {
        let data = try JSONEncoder().encode(room)
        try write(data, named: "room.json")
    }

    func readRoom() async throws -> ListenTogetherLiveRoomDescriptor {
        try await waitForSignal("room.json")
        return try JSONDecoder().decode(
            ListenTogetherLiveRoomDescriptor.self,
            from: Data(contentsOf: try url(named: "room.json"))
        )
    }

    func signal(_ name: String) throws {
        try write(Data(), named: name)
    }

    func waitForSignal(_ name: String) async throws {
        let expected = try url(named: name)
        let peerFailure = try url(named: role.peerFailureSignal)
        for _ in 0..<1_800 {
            try Task.checkCancellation()
            if FileManager.default.fileExists(atPath: expected.path) { return }
            if FileManager.default.fileExists(atPath: peerFailure.path) {
                throw ListenTogetherLiveTestError.peerFailed
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw ListenTogetherLiveTestError.coordinationTimeout
    }

    private func write(_ data: Data, named name: String) throws {
        let destination = try url(named: name)
        try data.write(to: destination, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: destination.path
        )
    }

    private func url(named name: String) throws -> URL {
        guard !name.isEmpty, name.allSatisfy({ character in
            character.isASCII
                && (character.isLowercase || character.isNumber || character == "-" || character == ".")
        }) else { throw ListenTogetherLiveTestError.invalidCoordinationName }
        return directory.appendingPathComponent(name, isDirectory: false)
    }
}

@MainActor
private func runListenTogetherHostLiveSmoke(
    coordination: ListenTogetherLiveCoordination
) async throws {
    let credentials = try listenTogetherLiveCredentials(role: "host")
    let transport = EAPITransport(cookie: credentials.cookie, musicU: credentials.musicU)
    let service = LiveListenTogetherService(transport: transport)
    let realtime = NIMChatroomTransport()
    let recorder = ListenTogetherRealtimeRecorder()
    realtime.onEvent = { recorder.events.append($0) }
    var hostUserID: Int64?
    var roomID: String?
    var failure: ListenTogetherLiveTestError?

    do {
        let userID = try await listenTogetherLiveUserID(transport: transport)
        hostUserID = userID
        let room = try await service.createRoom(currentUserID: userID)
        roomID = room.id
        try coordination.writeRoom(ListenTogetherLiveRoomDescriptor(
            roomID: room.id,
            chatRoomID: room.chatRoomID,
            inviterID: userID
        ))
        try coordination.signal("host-room-created")
        try await coordination.waitForSignal("member-joined")

        let realtimeCredentials = try await service.realtimeCredentials()
        try await realtime.connect(
            roomID: room.chatRoomID,
            credentials: realtimeCredentials,
            generation: 1
        )
        try coordination.signal("host-ready")
        try await coordination.waitForSignal("member-ready")

        guard try await service.heartbeatState(
            roomID: room.id,
            songID: listenTogetherLiveSongID,
            playStatus: .playing,
            progress: 0
        ).succeeded else { throw ListenTogetherLiveTestError.heartbeatRejected }
        try coordination.signal("host-heartbeat")
        try await coordination.waitForSignal("member-heartbeat")
        try await coordination.waitForSignal("member-receive-ready")

        for (index, step) in listenTogetherLivePlaySteps(sender: .host).enumerated() {
            let command = try listenTogetherLiveCommand(step: step, sequence: index + 1)
            guard try await service.reportPlayCommandConfirmed(roomID: room.id, command: command) else {
                throw ListenTogetherLiveTestError.commandRejected
            }
            try coordination.signal("host-play-\(index)-sent")
            try await coordination.waitForSignal("member-play-\(index)-received")
        }

        let playlist = try ListenTogetherPlaylistCommand(
            commandType: .replace,
            userID: userID,
            version: 1,
            anchorSongID: listenTogetherLiveSongID,
            anchorPosition: 0,
            randomList: [listenTogetherLiveSongID],
            displayList: [listenTogetherLiveSongID]
        )
        guard try await service.reportPlaylistCommandConfirmed(roomID: room.id, command: playlist) else {
            throw ListenTogetherLiveTestError.commandRejected
        }
        try coordination.signal("host-playlist-sent")
        try await coordination.waitForSignal("member-playlist-received")

        var eventOffset = recorder.events.count
        try coordination.signal("host-receive-ready")
        for (index, step) in listenTogetherLivePlaySteps(sender: .member).enumerated() {
            try await coordination.waitForSignal("member-play-\(index)-sent")
            guard try await service.heartbeatState(
                roomID: room.id,
                songID: listenTogetherLiveSongID,
                playStatus: .playing,
                progress: 0
            ).succeeded else { throw ListenTogetherLiveTestError.heartbeatRejected }
            guard try await recorder.waitForPlay(step: step, after: eventOffset) else {
                throw ListenTogetherLiveTestError.messageTimeout(recorder.diagnostic(after: eventOffset))
            }
            eventOffset = recorder.events.count
            try coordination.signal("host-play-\(index)-received")
        }

        let exitOffset = recorder.events.count
        try coordination.signal("host-exit-ready")
        try await coordination.waitForSignal("member-left")
        guard await waitForListenTogetherRoomState(
            service: service,
            currentUserID: userID,
            roomID: room.id,
            inRoom: false
        ) else { throw ListenTogetherLiveTestError.hostExitNotObserved }
        try await Task.sleep(for: .seconds(2))
        print("Listen together member exit notification: \(recorder.diagnostic(after: exitOffset))")
    } catch {
        failure = sanitizedListenTogetherLiveFailure(error)
        try? coordination.signal("host-failed")
    }

    await realtime.disconnect()
    if let roomID, let hostUserID {
        do {
            try await confirmListenTogetherCleanup(
                service: service,
                roomID: roomID,
                currentUserID: hostUserID
            )
        } catch {
            throw ListenTogetherLiveTestError.cleanupFailed
        }
    }
    if let failure { throw failure }
}

@MainActor
private func runListenTogetherMemberLiveSmoke(
    coordination: ListenTogetherLiveCoordination
) async throws {
    let credentials = try listenTogetherLiveCredentials(role: "member")
    let transport = EAPITransport(cookie: credentials.cookie, musicU: credentials.musicU)
    let service = LiveListenTogetherService(transport: transport)
    let realtime = NIMChatroomTransport()
    let recorder = ListenTogetherRealtimeRecorder()
    realtime.onEvent = { recorder.events.append($0) }
    var room: ListenTogetherLiveRoomDescriptor?
    var memberUserID: Int64?
    var joined = false
    var failure: ListenTogetherLiveTestError?

    do {
        let descriptor = try await coordination.readRoom()
        room = descriptor
        try await coordination.waitForSignal("host-room-created")
        let userID = try await listenTogetherLiveUserID(transport: transport)
        memberUserID = userID
        guard userID != descriptor.inviterID else { throw ListenTogetherLiveTestError.sameAccount }
        let invitation = try ListenTogetherInvitation(
            roomID: descriptor.roomID,
            inviterID: descriptor.inviterID
        )
        guard try await service.checkInvitation(invitation).joinable else {
            throw ListenTogetherLiveTestError.invitationRejected
        }
        let accepted = try await service.acceptInvitation(invitation, currentUserID: userID)
        guard accepted.id == descriptor.roomID, accepted.chatRoomID == descriptor.chatRoomID else {
            throw ListenTogetherLiveTestError.roomMismatch
        }
        joined = true
        try coordination.signal("member-joined")

        let realtimeCredentials = try await service.realtimeCredentials()
        try await realtime.connect(
            roomID: descriptor.chatRoomID,
            credentials: realtimeCredentials,
            generation: 1
        )
        try coordination.signal("member-ready")

        guard try await service.heartbeatState(
            roomID: descriptor.roomID,
            songID: listenTogetherLiveSongID,
            playStatus: .playing,
            progress: 0
        ).succeeded else { throw ListenTogetherLiveTestError.heartbeatRejected }
        try coordination.signal("member-heartbeat")
        try await coordination.waitForSignal("host-heartbeat")

        var eventOffset = recorder.events.count
        try coordination.signal("member-receive-ready")
        for (index, step) in listenTogetherLivePlaySteps(sender: .host).enumerated() {
            try await coordination.waitForSignal("host-play-\(index)-sent")
            guard try await service.heartbeatState(
                roomID: descriptor.roomID,
                songID: listenTogetherLiveSongID,
                playStatus: .playing,
                progress: 0
            ).succeeded else { throw ListenTogetherLiveTestError.heartbeatRejected }
            guard try await recorder.waitForPlay(step: step, after: eventOffset) else {
                throw ListenTogetherLiveTestError.messageTimeout(recorder.diagnostic(after: eventOffset))
            }
            eventOffset = recorder.events.count
            try coordination.signal("member-play-\(index)-received")
        }

        let playlistOffset = recorder.events.count
        try await coordination.waitForSignal("host-playlist-sent")
        guard try await recorder.waitForPlaylistChange(after: playlistOffset) else {
            throw ListenTogetherLiveTestError.messageTimeout(recorder.diagnostic(after: playlistOffset))
        }
        try await confirmListenTogetherPlaylist(
            service: service,
            roomID: descriptor.roomID,
            songID: listenTogetherLiveSongID
        )
        try coordination.signal("member-playlist-received")

        try await coordination.waitForSignal("host-receive-ready")
        for (index, step) in listenTogetherLivePlaySteps(sender: .member).enumerated() {
            let command = try listenTogetherLiveCommand(step: step, sequence: index + 1)
            guard try await service.reportPlayCommandConfirmed(
                roomID: descriptor.roomID,
                command: command
            ) else { throw ListenTogetherLiveTestError.commandRejected }
            try coordination.signal("member-play-\(index)-sent")
            try await coordination.waitForSignal("host-play-\(index)-received")
        }

        try await coordination.waitForSignal("host-exit-ready")
        guard try await service.endRoomConfirmed(roomID: descriptor.roomID) else {
            throw ListenTogetherLiveTestError.endRejected
        }
        guard await waitForListenTogetherRoomState(
            service: service,
            currentUserID: userID,
            roomID: descriptor.roomID,
            inRoom: false
        ) else { throw ListenTogetherLiveTestError.memberExitNotObserved }
        joined = false
        await realtime.disconnect()
        try coordination.signal("member-left")
    } catch {
        failure = sanitizedListenTogetherLiveFailure(error)
        try? coordination.signal("member-failed")
    }

    await realtime.disconnect()
    if joined, let room, memberUserID != nil {
        _ = try? await service.endRoomConfirmed(roomID: room.roomID)
    }
    if let failure { throw failure }
}

private let listenTogetherLiveSongID: Int64 = 2_671_812_705

private func listenTogetherLivePlaySteps(
    sender: ListenTogetherLiveRole
) -> [ListenTogetherLivePlayStep] {
    let base: Int64 = sender == .host ? 0 : 3_000
    return [
        ListenTogetherLivePlayStep(type: .goTo, progress: base, status: .paused, formerSongID: -1),
        ListenTogetherLivePlayStep(
            type: .play,
            progress: base + 100,
            status: .playing,
            formerSongID: listenTogetherLiveSongID
        ),
        ListenTogetherLivePlayStep(
            type: .progress,
            progress: base + 200,
            status: .playing,
            formerSongID: listenTogetherLiveSongID
        ),
        ListenTogetherLivePlayStep(
            type: .pause,
            progress: base + 300,
            status: .paused,
            formerSongID: listenTogetherLiveSongID
        )
    ]
}

private func listenTogetherLiveCommand(
    step: ListenTogetherLivePlayStep,
    sequence: Int
) throws -> ListenTogetherPlayCommand {
    try ListenTogetherPlayCommand(
        commandType: step.type,
        progress: step.progress,
        playStatus: step.status,
        formerSongID: step.formerSongID,
        targetSongID: listenTogetherLiveSongID,
        clientSequence: Int64(sequence)
    )
}

private func sanitizedListenTogetherLiveFailure(_ error: any Error) -> ListenTogetherLiveTestError {
    if let error = error as? ListenTogetherLiveTestError { return error }
    if let error = error as? NIMChatroomError {
        switch error {
        case .unavailable:
            return .realtimeFailure("unavailable")
        case let .connectionFailed(stage):
            return .realtimeFailure(stage)
        }
    }
    if error is EAPIError { return .apiFailure }
    if error is CancellationError { return .cancelled }
    return .unexpectedFailure
}

@MainActor
private final class ListenTogetherRealtimeRecorder {
    var events: [NIMChatroomEvent] = []

    func waitForPlay(step: ListenTogetherLivePlayStep, after offset: Int) async throws -> Bool {
        try await waitForPlay(
            type: step.type,
            progress: step.progress,
            status: step.status,
            formerSongID: step.formerSongID,
            targetSongID: listenTogetherLiveSongID,
            after: offset
        )
    }

    func waitForMemberJoined(after offset: Int) async throws -> Bool {
        try await wait {
            self.events.dropFirst(offset).contains { event in
                guard case let .message(raw, _) = event else { return false }
                return (try? ListenTogetherResponseDecoder.remoteEvent(from: raw)) == .memberJoined
            }
        }
    }

    func waitForPlay(
        type: ListenTogetherPlayCommandType,
        progress: Int64,
        status: ListenTogetherPlayStatus,
        formerSongID: Int64,
        targetSongID: Int64,
        after offset: Int
    ) async throws -> Bool {
        try await wait {
            self.events.dropFirst(offset).contains { event in
                guard case let .message(raw, _) = event,
                      case let .play(command) = try? ListenTogetherResponseDecoder.remoteEvent(from: raw)
                else { return false }
                return command.commandType == type
                    && command.progressMilliseconds == progress
                    && command.playStatus == status
                    && command.formerSongID == formerSongID
                    && command.targetSongID == targetSongID
            }
        }
    }

    func waitForPlaylistChange(after offset: Int) async throws -> Bool {
        try await wait {
            self.events.dropFirst(offset).contains { event in
                guard case let .message(raw, _) = event else { return false }
                if case .playlistChanged = try? ListenTogetherResponseDecoder.remoteEvent(from: raw) {
                    return true
                }
                return false
            }
        }
    }

    func diagnostic(after offset: Int) -> String {
        let events = events.dropFirst(offset)
        let messages = events.compactMap { event -> String? in
            guard case let .message(raw, _) = event else { return nil }
            return raw
        }
        let decoded = messages.filter { (try? ListenTogetherResponseDecoder.remoteEvent(from: $0)) != nil }
        let shapes = messages.prefix(8).map(Self.shape).joined(separator: "|")
        return "events=\(events.count),messages=\(messages.count),decoded=\(decoded.count),shapes=\(shapes.isEmpty ? "none" : shapes)"
    }

    private func wait(until condition: () -> Bool) async throws -> Bool {
        for _ in 0..<200 {
            if condition() { return true }
            try await Task.sleep(for: .milliseconds(100))
        }
        return condition()
    }

    private static func shape(_ raw: String) -> String {
        guard raw.utf8.count <= 65_536,
              let data = raw.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data)
        else { return "invalid" }
        return shape(value, depth: 0)
    }

    private static func shape(_ value: Any, depth: Int) -> String {
        guard depth < 8 else { return "depth" }
        if let object = value as? [String: Any] {
            return "{" + object.keys.sorted().map { key in
                "\(key):\(shape(object[key] as Any, depth: depth + 1))"
            }.joined(separator: ",") + "}"
        }
        if let values = value as? [Any] {
            return "[" + (values.first.map { shape($0, depth: depth + 1) } ?? "") + "]"
        }
        if let text = value as? String,
           text.utf8.count <= 65_536,
           let data = text.data(using: .utf8),
           let nested = try? JSONSerialization.jsonObject(with: data) {
            return shape(nested, depth: depth + 1)
        }
        if value is String { return "string" }
        if value is NSNull { return "null" }
        if let number = value as? NSNumber {
            return CFGetTypeID(number) == CFBooleanGetTypeID() ? "bool" : "number"
        }
        return "unknown"
    }
}

private enum ListenTogetherLiveTestError: Error {
    case apiFailure
    case cancelled
    case commandRejected
    case cleanupFailed
    case coordinationTimeout
    case endRejected
    case heartbeatRejected
    case hostExitNotObserved
    case insecureCoordination
    case invitationRejected
    case invalidCoordinationName
    case memberExitNotObserved
    case messageTimeout(String)
    case missingCoordination
    case missingCredentials
    case missingUserID
    case peerFailed
    case playlistNotObserved(String)
    case realtimeFailure(String)
    case roomMismatch
    case sameAccount
    case unexpectedFailure
}

private struct ListenTogetherTokenMetadata {
    let fields: [String]
    let uid: String
    let accountID: String
    let token: String
    let uidMatchesUser: Bool
    let accountIDMatchesUser: Bool
}

private func listenTogetherTokenMetadata(
    transport: EAPITransport,
    userID: Int64,
    host: String
) async throws -> ListenTogetherTokenMetadata {
    let response = try await transport.requestQuery(
        path: "/api/middle/im/token/get",
        fields: [("bizName", "music_listenTogether")],
        host: host
    )
    let value = try decodedJSONObject(response).object("data")
    let uid = listenTogetherScalarString(value["uid"])
    let accountID = listenTogetherScalarString(value["accId"])
    let token = listenTogetherScalarString(value["token"])
    let expected = String(userID)
    return ListenTogetherTokenMetadata(
        fields: value.keys.sorted(),
        uid: uid,
        accountID: accountID,
        token: token,
        uidMatchesUser: uid == expected,
        accountIDMatchesUser: accountID == expected
    )
}

private func listenTogetherScalarString(_ value: Any?) -> String {
    if let value = value as? String { return value }
    guard let value = value as? NSNumber,
          CFGetTypeID(value) != CFBooleanGetTypeID()
    else { return "" }
    return value.stringValue
}

private func listenTogetherLiveCredentials(role: String) throws -> SessionCredentials {
    let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/TinyCloudMusic/ListenTogetherTest")
        .appendingPathComponent("\(role).cookie")
    guard let cookie = try? String(contentsOf: url, encoding: .utf8) else {
        throw ListenTogetherLiveTestError.missingCredentials
    }
    let musicU = NeteaseCookieHeader.value(named: "MUSIC_U", in: cookie)
    guard !cookie.isEmpty, !musicU.isEmpty else { throw ListenTogetherLiveTestError.missingCredentials }
    return try SessionCredentials(
        cookie: cookie,
        musicU: musicU,
        deviceID: NeteaseCookieHeader.value(named: "deviceId", in: cookie)
    )
}

private func listenTogetherLiveUserID(transport: EAPITransport) async throws -> Int64 {
    let data = try await transport.request(
        EAPIEndpoint("/eapi/v1/user/info", signing: "/api/v1/user/info"),
        json: Data(),
        retryable: false
    )
    let userID = try decodedJSONObject(data).object("userPoint").int64("userId")
    guard userID > 0 else { throw ListenTogetherLiveTestError.missingUserID }
    return userID
}

private func confirmListenTogetherCleanup(
    service: LiveListenTogetherService,
    roomID: String,
    currentUserID: Int64
) async throws {
    _ = try? await service.endRoomConfirmed(roomID: roomID)
    guard await waitForListenTogetherRoomState(
        service: service,
        currentUserID: currentUserID,
        roomID: roomID,
        inRoom: false
    ) else { throw ListenTogetherLiveTestError.cleanupFailed }
}

private func confirmListenTogetherPlaylist(
    service: LiveListenTogetherService,
    roomID: String,
    songID: Int64
) async throws {
    var diagnostic = "none"
    for _ in 0..<40 {
        if let data = try? await service.playlist(
            roomID: roomID,
            displaySongIDs: [],
            randomSongIDs: [],
            anchorSongID: nil
        ) {
            diagnostic = listenTogetherPlaylistDiagnostic(data, expectedSongID: songID)
            if let playlist = try? ListenTogetherResponseDecoder.playlist(from: data),
               playlist.displaySongIDs == [songID],
               playlist.randomSongIDs == [songID] {
                return
            }
        }
        try await Task.sleep(for: .milliseconds(250))
    }
    throw ListenTogetherLiveTestError.playlistNotObserved(diagnostic)
}

private func listenTogetherPlaylistDiagnostic(_ data: Data, expectedSongID: Int64) -> String {
    guard let root = try? decodedJSONObject(data) else { return "invalid" }
    let payload = root.object("data")
    let playlist = payload.object("playlist")
    let display = playlist.object("displayList")
    let random = playlist.object("randomList")
    let decoded = try? ListenTogetherResponseDecoder.playlist(from: data)
    return "decoded=\(decoded != nil),displayCount=\(decoded?.displaySongIDs.count ?? -1),"
        + "randomCount=\(decoded?.randomSongIDs.count ?? -1),"
        + "displayContainsExpected=\(decoded?.displaySongIDs.contains(expectedSongID) ?? false),"
        + "randomContainsExpected=\(decoded?.randomSongIDs.contains(expectedSongID) ?? false),"
        + "dataKeys=\(payload.keys.sorted()),playlistKeys=\(playlist.keys.sorted()),"
        + "displayKeys=\(display.keys.sorted()),randomKeys=\(random.keys.sorted())"
}

private func waitForListenTogetherRoomState(
    service: LiveListenTogetherService,
    currentUserID: Int64,
    roomID: String,
    inRoom: Bool
) async -> Bool {
    for _ in 0..<20 {
        if let status = try? await service.status(currentUserID: currentUserID),
           status.inRoom == inRoom,
           !inRoom || status.room?.id == roomID {
            return true
        }
        try? await Task.sleep(for: .milliseconds(250))
    }
    return false
}
