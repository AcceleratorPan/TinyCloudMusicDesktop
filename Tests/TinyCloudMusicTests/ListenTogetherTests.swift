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

    @Test("Playlist, member, ignored-ID, and existing wire bounds reject inconsistent input")
    func structuralValidation() throws {
        #expect((try? ListenTogetherPlaylistCommand(
            commandType: .replace,
            userID: 42,
            version: 1,
            playMode: .orderLoop,
            anchorSongID: 1,
            anchorPosition: 0,
            randomList: [1, 2],
            displayList: [1, 2]
        )) != nil)
        #expect((try? ListenTogetherPlaylistCommand(
            commandType: .replace,
            userID: 42,
            version: 1,
            randomList: [1, 1],
            displayList: [1, 2]
        )) == nil)
        #expect((try? ListenTogetherPlaylistCommand(
            commandType: .replace,
            userID: 42,
            version: 1,
            playMode: .random,
            anchorSongID: 1,
            anchorPosition: 1,
            randomList: [2, 1],
            displayList: [1, 2]
        )) == nil)
        #expect((try? ListenTogetherResponseDecoder.authoritativeState(from: Data(#"""
        {"code":200,"data":{"playList":{"displayList":[1,2],"randomList":[1,3],"anchorPosition":-1}}}
        """#.utf8))) == nil)
        #expect((try? ListenTogetherResponseDecoder.authoritativeState(from: Data(#"""
        {"code":200,"data":{"playList":{"displayList":[1,2],"randomList":[1,2],"anchorSongId":1,"anchorPosition":1}}}
        """#.utf8))) == nil)
        #expect((try? ListenTogetherResponseDecoder.authoritativeState(from: Data(#"""
        {"code":200,"data":{"playList":{"displayList":[1,2],"randomList":[1,2],"anchorSongId":1}}}
        """#.utf8))) == nil)
        #expect((try? ListenTogetherResponseDecoder.authoritativeState(from: Data(#"""
        {"code":200,"data":{"playList":{"displayList":[1,2],"randomList":[1,2]}}}
        """#.utf8))) == nil)
        #expect((try? ListenTogetherResponseDecoder.room(
            from: Data(#"{"code":200,"data":{"roomInfo":{"roomId":"room","chatRoomId":"chat","creatorId":42,"roomUsers":[{"userId":42,"nickname":"A"},{"userId":42,"nickname":"B"}]}}}"#.utf8),
            currentUserID: 42
        )) == nil)
        #expect((try? ListenTogetherResponseDecoder.remoteEvent(
            from: #"{"content":{"type":20008,"content":{"ignoreUserIds":[42,42]}}}"#
        )) == nil)

        let event = #"{"content":{"type":20002,"content":{}}}"#
        let bounded = event + String(repeating: " ", count: 65_536 - event.utf8.count)
        #expect(try ListenTogetherResponseDecoder.remoteEvent(from: bounded) == .memberJoined)
        #expect((try? ListenTogetherResponseDecoder.remoteEvent(from: bounded + " ")) == nil)

        func nestedEvent(depth: Int) throws -> String {
            var value: [String: Any] = ["type": 20_002, "content": [:]]
            for _ in 0..<depth { value = ["content": value] }
            return String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self)
        }
        #expect(try ListenTogetherResponseDecoder.remoteEvent(from: nestedEvent(depth: 7)) == .memberJoined)
        #expect((try? ListenTogetherResponseDecoder.remoteEvent(from: nestedEvent(depth: 8))) == nil)
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
              "anchorPosition": 0,
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
              "anchorPosition": -1,
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

    @Test("Authenticated mutations keep the credential revision captured before send")
    func mutationCredentialFence() async {
        RevisionFenceProtocol.reset()
        let gate = RevisionFenceGate()
        let snapshot = CredentialSnapshot(.guest)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RevisionFenceProtocol.self]
        let service = LiveListenTogetherService(transport: EAPITransport(
            session: URLSession(configuration: configuration),
            credentialSnapshot: snapshot,
            beforeSendingRequest: { await gate.wait() }
        ))

        let request = Task {
            _ = try await service.createRoom(expectedCredentialRevision: 0)
        }
        await gate.waitUntilBlocked()
        _ = snapshot.store(.guest)
        await gate.open()

        do {
            try await request.value
            Issue.record("The stale mutation unexpectedly sent")
        } catch is CredentialRevisionMismatch {
        } catch {
            Issue.record("The stale mutation failed with \(error)")
        }
        #expect(RevisionFenceProtocol.requestCount == 0)
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
        let expectedCredentialRevision = transport.credentialSnapshotValue().revision
        let userID = try await listenTogetherLiveUserID(transport: transport)
        let first = try await listenTogetherTokenMetadata(
            transport: transport,
            userID: userID,
            host: "https://interface3.music.163.com",
            expectedCredentialRevision: expectedCredentialRevision
        )
        let second = try await listenTogetherTokenMetadata(
            transport: transport,
            userID: userID,
            host: "https://interface3.music.163.com",
            expectedCredentialRevision: expectedCredentialRevision
        )
        let standardHost = try await listenTogetherTokenMetadata(
            transport: transport,
            userID: userID,
            host: "https://interface.music.163.com",
            expectedCredentialRevision: expectedCredentialRevision
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
        ListenTogetherControllerProtocol.reset(Self.operationStubs)
        let gate = NonCooperativeRequestGate()
        let realtime = ListenTogetherRealtimeStub()
        let controller = makeController(realtime: realtime, requestGate: gate)
        controller.updateAccount(42)
        await wait { controller.currentUserID == 42 && controller.errorMessage != nil }

        await gate.arm(afterPassing: 1)
        let firstCreate = Task { @MainActor in await controller.createRoom() }
        #expect(await gate.waitUntilEntered(1))
        #expect(controller.room?.id == "room-1")
        firstCreate.cancel()
        let duplicateCreate = Task { @MainActor in await controller.createRoom() }
        var logoutCompletions = 0
        let firstLogout = Task { @MainActor in
            await controller.prepareForLogout()
            logoutCompletions += 1
        }
        let duplicateLogout = Task { @MainActor in
            await controller.prepareForLogout()
            logoutCompletions += 1
        }
        #expect(await gate.waitUntilCancelled(1))
        try? await Task.sleep(for: .milliseconds(20))
        #expect(logoutCompletions == 0)
        #expect(ListenTogetherControllerProtocol.requestCount(
            for: "/eapi/listen/together/end/v2"
        ) == 0)

        await gate.release(1)
        await firstCreate.value
        await duplicateCreate.value
        await firstLogout.value
        await duplicateLogout.value

        #expect(logoutCompletions == 2)
        #expect(ListenTogetherControllerProtocol.requestCount(
            for: "/eapi/listen/together/room/create"
        ) == 1)
        #expect(ListenTogetherControllerProtocol.requestCount(
            for: "/eapi/listen/together/end/v2"
        ) == 1)
        #expect(realtime.connectCount == 0)
        #expect(controller.room == nil)
        #expect(controller.currentUserID == nil)
        #expect(!controller.requiresShutdown)
    }

    @Test("Account B waits for a non-cooperative A create")
    func accountSwitchWaitsForCreate() async throws {
        try await assertAccountSwitchWaits(for: .create)
    }

    @Test("Account B waits for a non-cooperative A join")
    func accountSwitchWaitsForJoin() async throws {
        try await assertAccountSwitchWaits(for: .join)
    }

    @Test("Account B waits for a non-cooperative A token request")
    func accountSwitchWaitsForToken() async throws {
        try await assertAccountSwitchWaits(for: .token)
    }

    @Test("Rapid A to B to C waits for the retired A operation")
    func rapidAccountSwitchWaitsForRetiredOperation() async {
        ListenTogetherControllerProtocol.reset(Self.operationStubs)
        let gate = NonCooperativeRequestGate()
        let credentialSnapshot = CredentialSnapshot(.guest)
        let realtime = ListenTogetherRealtimeStub()
        let controller = makeController(
            realtime: realtime,
            requestGate: gate,
            credentialSnapshot: credentialSnapshot
        )
        controller.updateAccount(42)
        await wait { controller.currentUserID == 42 && controller.errorMessage != nil }

        await gate.arm()
        let stalled = Task { @MainActor in await controller.createRoom() }
        #expect(await gate.waitUntilEntered(1))
        _ = credentialSnapshot.store(.guest)
        controller.updateAccount(84)
        #expect(await gate.waitUntilCancelled(1))
        _ = credentialSnapshot.store(.guest)
        controller.updateAccount(126)
        try? await Task.sleep(for: .milliseconds(20))
        #expect(controller.currentUserID == 42)
        #expect(ListenTogetherControllerProtocol.requestCount(
            for: "/weapi/listen/together/status/get"
        ) == 1)

        await gate.release(1)
        await stalled.value
        await wait { controller.currentUserID == 126 && controller.errorMessage != nil }
        #expect(controller.currentUserID == 126)
        #expect(ListenTogetherControllerProtocol.requestCount(
            for: "/weapi/listen/together/status/get"
        ) == 2)
        #expect(realtime.connectCount == 0)
        await controller.shutdown()
    }

    @Test("Same-user credential revision fences realtime and migrates the session")
    func sameUserCredentialRevisionMigratesSession() async {
        ListenTogetherControllerProtocol.reset([
            "/weapi/listen/together/status/get": .init(Self.inRoom),
            "/api/middle/im/token/get": .init(Self.credentials),
            "/eapi/listen/together/sync/playlist/get": .init(Self.authoritativePaused),
            "/eapi/listen/together/heartbeat": .init(Self.heartbeat)
        ])
        let snapshot = CredentialSnapshot(.guest)
        let realtime = ListenTogetherRealtimeStub()
        let player = PlayerController(repository: FixtureMusicRepository(), crossfadeDuration: 0)
        let controller = makeController(
            player: player,
            realtime: realtime,
            credentialSnapshot: snapshot
        )
        controller.updateAccount(42)
        await wait {
            if case .recoveryAvailable = controller.phase { return true }
            return false
        }
        controller.recover()
        await wait { controller.isConnected }
        #expect(player.currentSongID == 1)
        let statusCount = ListenTogetherControllerProtocol.requestCount(
            for: "/weapi/listen/together/status/get"
        )

        _ = snapshot.store(.guest)
        realtime.send(Self.remotePlay)
        #expect(player.currentSongID == 1)

        controller.updateAccount(42)
        await wait {
            guard realtime.disconnectCount == 1 else { return false }
            if case .recoveryAvailable = controller.phase { return true }
            return false
        }
        #expect(ListenTogetherControllerProtocol.requestCount(
            for: "/weapi/listen/together/status/get"
        ) == statusCount + 1)
        controller.recover()
        await wait { controller.isConnected && realtime.connectCount == 2 }
        #expect(player.currentSongID == 1)
        await controller.shutdown()
    }

    @Test("AppModel invalidates an active room before same-user confirmation")
    func appModelInvalidatesActiveRoomBeforeConfirmation() async {
        ListenTogetherControllerProtocol.reset([
            "/eapi/v1/user/info": .init(#"{"code":200,"userPoint":{"userId":42}}"#, delay: 0.25),
            "/eapi/v1/user/detail": .init(#"{"code":200,"profile":{"userId":42,"nickname":"Fixture"}}"#),
            "/eapi/user/playlist": .init(#"{"code":200,"playlist":[],"more":false}"#),
            "/weapi/listen/together/status/get": .init(Self.inRoom),
            "/api/middle/im/token/get": .init(Self.credentials),
            "/eapi/listen/together/sync/playlist/get": .init(Self.authoritativePaused),
            "/eapi/listen/together/heartbeat": .init(Self.heartbeat)
        ])
        let snapshot = CredentialSnapshot(.guest)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ListenTogetherControllerProtocol.self]
        let transport = EAPITransport(
            session: URLSession(configuration: configuration),
            credentialSnapshot: snapshot
        )
        let player = PlayerController(repository: FixtureMusicRepository(), crossfadeDuration: 0)
        let realtime = ListenTogetherRealtimeStub()
        let controller = ListenTogetherController(
            service: LiveListenTogetherService(transport: transport),
            player: player,
            realtime: realtime
        )
        let model = AppModel(
            repository: FixtureMusicRepository(),
            library: LiveMusicLibrary(transport: transport),
            extras: LiveMusicExtras(transport: transport),
            defaults: UserDefaults(suiteName: UUID().uuidString)!
        )
        model.listenTogether = controller
        model.installConfirmedAccount(userID: 42, credentialRevision: snapshot.load().revision)

        await wait {
            if case .recoveryAvailable = controller.phase { return true }
            return false
        }
        controller.recover()
        await wait { controller.isConnected && player.currentSongID == 1 }

        let revision = snapshot.store(.guest).revision
        model.invalidateAccountDomainIfNeeded(forCredentialRevision: revision)
        let refresh = Task { @MainActor in await model.refreshAccountState() }

        #expect(model.currentUserID == nil)
        realtime.send(Self.remotePlay)
        #expect(player.currentSongID == 1)
        await wait {
            controller.currentUserID == nil
                && controller.room == nil
                && realtime.disconnectCount == 1
        }
        #expect(player.controlInterceptor == nil)
        #expect(!player.isControlInteractionLocked)
        #expect(ListenTogetherControllerProtocol.requestCount(
            for: "/eapi/listen/together/end/v2"
        ) == 0)

        await refresh.value
        #expect(model.currentUserID == 42)
        #expect(model.confirmedAccountCredentialRevision == revision)
        await wait {
            controller.currentUserID == 42
                && ListenTogetherControllerProtocol.requestCount(
                    for: "/weapi/listen/together/status/get"
                ) == 2
        }
        await controller.shutdown()
    }

    @Test("Sleep cancels a non-cooperative room operation before returning")
    func sleepDoesNotWaitForRoomOperation() async {
        ListenTogetherControllerProtocol.reset(Self.operationStubs)
        let gate = NonCooperativeRequestGate()
        let realtime = ListenTogetherRealtimeStub()
        let controller = makeController(realtime: realtime, requestGate: gate)
        controller.updateAccount(42)
        await wait { controller.currentUserID == 42 && controller.errorMessage != nil }

        await gate.arm(afterPassing: 1)
        let create = Task { @MainActor in await controller.createRoom() }
        #expect(await gate.waitUntilEntered(1))
        var finished = false
        let sleep = Task { @MainActor in
            await controller.sleep()
            finished = true
        }
        #expect(await gate.waitUntilCancelled(1))
        await wait { finished }
        let finishedBeforeRelease = finished

        await gate.release(1)
        await create.value
        await sleep.value
        #expect(finishedBeforeRelease)
        #expect(realtime.connectCount == 0)
        await controller.shutdown()
    }

    @Test("Sleep fences a delayed exit fallback status response")
    func sleepFencesExitFallbackStatus() async {
        ListenTogetherControllerProtocol.reset([
            "/weapi/listen/together/status/get": .init(Self.inRoom),
            "/eapi/listen/together/end/v2": .init(#"{"code":200,"data":{"result":false}}"#)
        ])
        let gate = NonCooperativeRequestGate()
        let controller = makeController(
            realtime: ListenTogetherRealtimeStub(),
            requestGate: gate
        )
        controller.updateAccount(42)
        await wait {
            if case .recoveryAvailable = controller.phase { return true }
            return false
        }

        await gate.arm(afterPassing: 1)
        let end = Task { @MainActor in await controller.endRoom() }
        #expect(await gate.waitUntilEntered(1))
        let sleep = Task { @MainActor in await controller.sleep() }
        #expect(await gate.waitUntilCancelled(1))
        await sleep.value
        #expect(controller.isSleeping)

        await gate.release(1)
        await end.value
        #expect(controller.isSleeping)
        #expect(controller.room?.id == "room-1")
        #expect(controller.errorMessage == nil)
    }

    @Test("Logout waits for a cancelled non-cooperative room operation")
    func logoutWaitsForRoomOperation() async {
        ListenTogetherControllerProtocol.reset(Self.operationStubs)
        let gate = NonCooperativeRequestGate()
        let realtime = ListenTogetherRealtimeStub()
        let controller = makeController(realtime: realtime, requestGate: gate)
        controller.updateAccount(42)
        await wait { controller.currentUserID == 42 && controller.errorMessage != nil }

        await gate.arm(afterPassing: 1)
        let create = Task { @MainActor in await controller.createRoom() }
        #expect(await gate.waitUntilEntered(1))
        var finished = false
        let logout = Task { @MainActor in
            await controller.prepareForLogout()
            finished = true
        }
        #expect(await gate.waitUntilCancelled(1))
        try? await Task.sleep(for: .milliseconds(20))
        #expect(!finished)
        #expect(ListenTogetherControllerProtocol.requestCount(
            for: "/eapi/listen/together/end/v2"
        ) == 0)

        await gate.release(1)
        await create.value
        await logout.value
        #expect(finished)
        #expect(controller.currentUserID == nil)
        #expect(realtime.connectCount == 0)
        #expect(!controller.requiresShutdown)
    }

    @Test("Shutdown drains a retired non-cooperative room operation")
    func shutdownDrainsRetiredRoomOperation() async {
        ListenTogetherControllerProtocol.reset(Self.operationStubs)
        let gate = NonCooperativeRequestGate()
        let realtime = ListenTogetherRealtimeStub()
        let controller = makeController(realtime: realtime, requestGate: gate)
        controller.updateAccount(42)
        await wait { controller.currentUserID == 42 && controller.errorMessage != nil }

        await gate.arm()
        let create = Task { @MainActor in await controller.createRoom() }
        #expect(await gate.waitUntilEntered(1))
        var finished = false
        let shutdown = Task { @MainActor in
            await controller.shutdown()
            finished = true
        }
        #expect(await gate.waitUntilCancelled(1))
        try? await Task.sleep(for: .milliseconds(20))
        #expect(!finished)
        #expect(controller.requiresShutdown)

        await gate.release(1)
        await create.value
        await shutdown.value
        #expect(finished)
        #expect(!controller.requiresShutdown)
    }

    @Test("Cancelled termination can rebind after reversible cleanup completes")
    func completedTerminationCleanupCanRebind() async {
        ListenTogetherControllerProtocol.reset([
            "/weapi/listen/together/status/get": .init(Self.inRoom),
            "/api/middle/im/token/get": .init(Self.credentials),
            "/eapi/listen/together/sync/playlist/get": .init(Self.authoritativePaused),
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

        await controller.prepareForLogout()
        #expect(controller.currentUserID == nil)
        #expect(realtime.shutdownCount == 0)

        controller.updateAccount(42)
        await wait {
            if case .recoveryAvailable = controller.phase { return true }
            return false
        }
        controller.recover()
        await wait { controller.isConnected }
        #expect(realtime.connectCount == 2)
        #expect(realtime.shutdownCount == 0)
        await controller.shutdown()
    }

    @Test("Cancelled termination supersedes blocked cleanup and reconnects")
    func timedOutTerminationCleanupCanRebind() async {
        ListenTogetherControllerProtocol.reset([
            "/weapi/listen/together/status/get": .init(Self.inRoom),
            "/api/middle/im/token/get": .init(Self.credentials),
            "/eapi/listen/together/sync/playlist/get": .init(Self.authoritativePaused),
            "/eapi/listen/together/heartbeat": .init(Self.heartbeat),
            "/eapi/listen/together/end/v2": .init(Self.succeeded)
        ])
        let gate = NonCooperativeRequestGate()
        let realtime = ListenTogetherRealtimeStub()
        let controller = makeController(realtime: realtime, requestGate: gate)
        controller.updateAccount(42)
        await wait {
            if case .recoveryAvailable = controller.phase { return true }
            return false
        }
        controller.recover()
        await wait { controller.isConnected }

        await gate.arm()
        let cleanup = Task { @MainActor in await controller.prepareForLogout() }
        #expect(await gate.waitUntilEntered(1))

        controller.updateAccount(42)
        #expect(await gate.waitUntilCancelled(1))
        await gate.release(1)
        await cleanup.value
        await wait {
            if case .recoveryAvailable = controller.phase { return true }
            return false
        }
        controller.recover()
        await wait { controller.isConnected }
        #expect(realtime.connectCount == 2)
        #expect(realtime.shutdownCount == 0)
        await controller.shutdown()
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

    @Test("Remote end hints require authoritative confirmation before clearing the session")
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
        await wait { !controller.isReconciling }
        #expect(controller.isConnected)
        #expect(controller.room != nil)
        #expect(realtime.disconnectCount == 0)

        ListenTogetherControllerProtocol.reset([
            "/weapi/listen/together/status/get": .init(Self.notInRoom)
        ])
        realtime.send(Self.remoteEnded)
        await wait { controller.room == nil }
        await wait { realtime.disconnectCount == 1 }
        #expect(controller.phase == .ended(reason: "房间已结束"))
        #expect(controller.errorMessage == nil)
        #expect(!player.isControlInteractionLocked)
        #expect(!player.isSharedControlActive)
        #expect(!controller.requiresShutdown)
    }

    @Test("Shutdown waits for the single tracked disconnect")
    func shutdownWaitsForDisconnect() async {
        ListenTogetherControllerProtocol.reset([
            "/weapi/listen/together/status/get": .init(Self.inRoom),
            "/api/middle/im/token/get": .init(Self.credentials),
            "/eapi/listen/together/sync/playlist/get": .init(Self.authoritativePaused),
            "/eapi/listen/together/heartbeat": .init(Self.heartbeat),
            "/eapi/listen/together/end/v2": .init(Self.succeeded)
        ])
        let gate = RevisionFenceGate()
        let realtime = ListenTogetherRealtimeStub(disconnectGate: gate)
        let controller = makeController(realtime: realtime)
        controller.updateAccount(42)
        await wait {
            if case .recoveryAvailable = controller.phase { return true }
            return false
        }
        controller.recover()
        await wait { controller.isConnected }

        ListenTogetherControllerProtocol.reset([
            "/weapi/listen/together/status/get": .init(Self.notInRoom)
        ])
        realtime.send(Self.remoteEnded)
        await gate.waitUntilBlocked()
        #expect(controller.requiresShutdown)

        let shutdown = Task { @MainActor in await controller.shutdown() }
        await Task.yield()
        #expect(controller.requiresShutdown)
        await gate.open()
        await shutdown.value
        #expect(realtime.disconnectCount == 1)
        #expect(realtime.shutdownCount == 1)
        #expect(!controller.requiresShutdown)
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

    @Test("Join waits for account bootstrap before accepting once")
    func joinWaitsForAccountBootstrap() async throws {
        ListenTogetherControllerProtocol.reset([
            "/weapi/listen/together/status/get": .init(Self.notInRoom),
            "/eapi/listen/together/play/invitation/accept": .init(Self.room),
            "/api/middle/im/token/get": .init(Self.credentials),
            "/eapi/listen/together/sync/playlist/get": .init(Self.authoritativePaused),
            "/eapi/listen/together/heartbeat": .init(Self.heartbeat),
            "/eapi/listen/together/end/v2": .init(Self.succeeded)
        ])
        let gate = NonCooperativeRequestGate()
        let waitGate = BootstrapWaitGate()
        await gate.arm()
        let realtime = ListenTogetherRealtimeStub()
        let controller = makeController(
            realtime: realtime,
            requestGate: gate,
            accountBootstrapWaitObserver: { waitGate.enter() }
        )
        controller.updateAccount(84)
        #expect(await gate.waitUntilEntered(1))

        var joinFinished = false
        let join = Task { @MainActor in
            await controller.join(try! ListenTogetherInvitation(roomID: "room-1", inviterID: 42))
            joinFinished = true
        }
        await waitGate.waitUntilEntered()
        #expect(!joinFinished)
        #expect(ListenTogetherControllerProtocol.requestCount(
            for: "/eapi/listen/together/play/invitation/accept"
        ) == 0)

        await gate.release(1)
        await join.value
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
        #expect(ListenTogetherControllerProtocol.requestCount(
            for: "/eapi/listen/together/play/invitation/accept"
        ) == 1)
        await controller.shutdown()
    }

    @Test("Account replacement drops a join waiting for old bootstrap")
    func accountReplacementDropsWaitingJoin() async throws {
        ListenTogetherControllerProtocol.reset([
            "/weapi/listen/together/status/get": .init(Self.notInRoom),
            "/eapi/listen/together/play/invitation/accept": .init(Self.room)
        ])
        let gate = NonCooperativeRequestGate()
        let waitGate = BootstrapWaitGate()
        await gate.arm()
        let controller = makeController(
            realtime: ListenTogetherRealtimeStub(),
            requestGate: gate,
            accountBootstrapWaitObserver: { waitGate.enter() }
        )
        controller.updateAccount(84)
        #expect(await gate.waitUntilEntered(1))
        let join = Task { @MainActor in
            await controller.join(try! ListenTogetherInvitation(roomID: "room-1", inviterID: 42))
        }
        await waitGate.waitUntilEntered()

        controller.updateAccount(85)
        await gate.release(1)
        await join.value
        #expect(ListenTogetherControllerProtocol.requestCount(
            for: "/eapi/listen/together/play/invitation/accept"
        ) == 0)
        await controller.shutdown()
    }

    @Test("Caller cancellation drops a join waiting for bootstrap")
    func callerCancellationDropsWaitingJoin() async throws {
        ListenTogetherControllerProtocol.reset([
            "/weapi/listen/together/status/get": .init(Self.notInRoom),
            "/eapi/listen/together/play/invitation/accept": .init(Self.room)
        ])
        let gate = NonCooperativeRequestGate()
        let waitGate = BootstrapWaitGate()
        await gate.arm()
        let controller = makeController(
            realtime: ListenTogetherRealtimeStub(),
            requestGate: gate,
            accountBootstrapWaitObserver: { waitGate.enter() }
        )
        controller.updateAccount(84)
        #expect(await gate.waitUntilEntered(1))
        let join = Task { @MainActor in
            await controller.join(try! ListenTogetherInvitation(roomID: "room-1", inviterID: 42))
        }

        await waitGate.waitUntilEntered()
        join.cancel()
        await gate.release(1)
        await join.value
        #expect(ListenTogetherControllerProtocol.requestCount(
            for: "/eapi/listen/together/play/invitation/accept"
        ) == 0)
        await controller.shutdown()
    }

    @Test("Nil queue sends only play while a real queue change preserves playlist then play")
    func queueIntentConsumption() async throws {
        ListenTogetherControllerProtocol.reset([
            "/weapi/listen/together/status/get": .init(Self.inRoom),
            "/api/middle/im/token/get": .init(Self.credentials),
            "/eapi/listen/together/sync/playlist/get": .init(Self.authoritativePaused),
            "/eapi/listen/together/sync/list/command/report": .init(Self.succeeded),
            "/eapi/listen/together/play/command/report": .init(Self.succeeded),
            "/eapi/listen/together/heartbeat": .init(Self.heartbeat),
            "/eapi/listen/together/end/v2": .init(Self.succeeded)
        ])
        let realtime = ListenTogetherRealtimeStub()
        let player = PlayerController(repository: FixtureMusicRepository(), crossfadeDuration: 0)
        let controller = makeController(player: player, realtime: realtime)
        controller.updateAccount(42)
        await wait {
            if case .recoveryAvailable = controller.phase { return true }
            return false
        }
        controller.recover()
        await wait { controller.isConnected }
        ListenTogetherControllerProtocol.clearEvents()

        var commitCount = 0
        let playOnly = PlayerControlIntent(
            trigger: .user,
            play: .pause(songID: 1, progress: 1),
            queue: nil
        )
        #expect(player.controlInterceptor?(playOnly) { commitCount += 1 } == true)
        await wait { commitCount == 1 }
        #expect(ListenTogetherControllerProtocol.requestCount(
            for: "/eapi/listen/together/sync/list/command/report"
        ) == 0)
        #expect(ListenTogetherControllerProtocol.requestCount(
            for: "/eapi/listen/together/play/command/report"
        ) == 1)

        ListenTogetherControllerProtocol.clearEvents()
        let changedQueue = PlayerControlIntent(
            trigger: .user,
            play: .play(songID: 2, progress: 0),
            queue: PlayerQueueOrder(
                displaySongIDs: [1, 2],
                randomSongIDs: [2, 1],
                anchorSongID: 2
            )
        )
        #expect(player.controlInterceptor?(changedQueue) { commitCount += 1 } == true)
        await wait { commitCount == 2 }
        let events = ListenTogetherControllerProtocol.events
        let playlistIndex = try #require(events.firstIndex(
            of: "/eapi/listen/together/sync/list/command/report"
        ))
        let playIndex = try #require(events.firstIndex(
            of: "/eapi/listen/together/play/command/report"
        ))
        #expect(playlistIndex < playIndex)
        #expect(ListenTogetherControllerProtocol.requestCount(
            for: "/eapi/listen/together/sync/list/command/report"
        ) == 1)
        #expect(ListenTogetherControllerProtocol.requestCount(
            for: "/eapi/listen/together/play/command/report"
        ) == 1)
        await controller.prepareForLogout()
    }

    private func assertAccountSwitchWaits(
        for operation: StalledRoomOperation
    ) async throws {
        ListenTogetherControllerProtocol.reset(Self.operationStubs)
        let gate = NonCooperativeRequestGate()
        let credentialSnapshot = CredentialSnapshot(.guest)
        let realtime = ListenTogetherRealtimeStub()
        let controller = makeController(
            realtime: realtime,
            requestGate: gate,
            credentialSnapshot: credentialSnapshot
        )
        let invitation = try ListenTogetherInvitation(roomID: "fixture-room", inviterID: 7)
        controller.updateAccount(42)
        await wait { controller.currentUserID == 42 && controller.errorMessage != nil }

        await gate.arm(afterPassing: operation == .token ? 1 : 0)
        let stalled = Task { @MainActor in
            switch operation {
            case .create, .token:
                await controller.createRoom()
            case .join:
                await controller.join(invitation)
            }
        }
        #expect(await gate.waitUntilEntered(1))

        _ = credentialSnapshot.store(.guest)
        controller.updateAccount(84)
        let cancellationObserved = await gate.waitUntilCancelled(1)
        let replacement = Task { @MainActor in await controller.checkInvitation(invitation) }
        try? await Task.sleep(for: .milliseconds(20))
        #expect(controller.currentUserID == 42)
        #expect(ListenTogetherControllerProtocol.requestCount(
            for: "/eapi/listen/together/room/check"
        ) == 0)

        await gate.release(1)
        await stalled.value
        await replacement.value
        await wait { controller.currentUserID == 84 }
        #expect(cancellationObserved)
        if case .readyToJoin = controller.phase {
        } else {
            Issue.record("Replacement room operation did not run after the account switch drained")
        }
        #expect(realtime.connectCount == 0)
        #expect(ListenTogetherControllerProtocol.requestCount(
            for: "/eapi/listen/together/room/check"
        ) == 1)
        switch operation {
        case .create:
            #expect(ListenTogetherControllerProtocol.requestCount(
                for: "/eapi/listen/together/room/create"
            ) == 0)
        case .join:
            #expect(ListenTogetherControllerProtocol.requestCount(
                for: "/eapi/listen/together/play/invitation/accept"
            ) == 0)
        case .token:
            #expect(ListenTogetherControllerProtocol.requestCount(
                for: "/eapi/listen/together/room/create"
            ) == 1)
            #expect(ListenTogetherControllerProtocol.requestCount(
                for: "/api/middle/im/token/get"
            ) == 0)
        }
        await controller.shutdown()
    }

    private func makeController(
        player: PlayerController? = nil,
        realtime: ListenTogetherRealtimeStub,
        requestGate: NonCooperativeRequestGate? = nil,
        credentialSnapshot: CredentialSnapshot? = nil,
        accountBootstrapWaitObserver: (@MainActor @Sendable () -> Void)? = nil
    ) -> ListenTogetherController {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ListenTogetherControllerProtocol.self]
        let beforeSendingRequest: (@Sendable () async -> Void)?
        if let requestGate {
            beforeSendingRequest = { await requestGate.wait() }
        } else {
            beforeSendingRequest = nil
        }
        let transport = EAPITransport(
            session: URLSession(configuration: configuration),
            cookie: "",
            musicU: "",
            credentialSnapshot: credentialSnapshot,
            beforeSendingRequest: beforeSendingRequest
        )
        return ListenTogetherController(
            service: LiveListenTogetherService(transport: transport),
            player: player ?? PlayerController(
                repository: FixtureMusicRepository(),
                crossfadeDuration: 0
            ),
            realtime: realtime,
            accountBootstrapWaitObserver: accountBootstrapWaitObserver
        )
    }

    private func wait(until condition: @MainActor () -> Bool) async {
        for _ in 0..<200 where !condition() {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private static let room = #"{"code":200,"data":{"roomInfo":{"roomId":"room-1","chatRoomId":"chat-1","creatorId":42,"roomUsers":[{"userId":42,"nickname":"Host"}]}}}"#
    private static let roomCheck = #"{"code":200,"data":{"joinable":true,"status":"READY"}}"#
    private static let invalidStatus = #"{"code":200,"data":{"status":"NOT_IN_ROOM"}}"#
    private static let notInRoom = #"{"code":200,"data":{"inRoom":false,"status":"NOT_IN_ROOM"}}"#
    private static let inRoom = #"{"code":200,"data":{"inRoom":true,"status":"IN_ROOM","roomInfo":{"roomId":"room-1","chatRoomId":"chat-1","creatorId":42,"roomUsers":[{"userId":42,"nickname":"Host"}]}}}"#
    private static let credentials = #"{"code":200,"data":{"accId":"account","token":"token"}}"#
    private static let succeeded = #"{"code":200,"data":{"result":true}}"#
    private static let heartbeat = #"{"code":200,"data":{"result":true,"timeSpan":30}}"#
    private static let authoritativePaused = #"{"code":200,"data":{"playList":{"displayList":[1,2],"randomList":[1,2],"anchorSongId":1,"anchorPosition":0,"version":1},"playCommand":{"commandType":"PROGRESS","progress":1000,"playStatus":"PAUSE","formerSongId":1,"targetSongId":1}}}"#
    private static let remotePlay = #"{"content":{"type":20000,"content":{"serverSeq":1,"commandType":"GOTO","formerSongId":1,"targetSongId":2,"progress":2000,"playStatus":"PAUSE"}}}"#
    private static let remoteUnknownSong = #"{"content":{"type":20000,"content":{"serverSeq":1,"commandType":"GOTO","formerSongId":1,"targetSongId":999,"progress":0,"playStatus":"PAUSE"}}}"#
    private static let remoteEnded = #"{"ext":{"serverExt":{"type":20003,"content":{"exitType":"ROOM_EMPTY"}}}}"#
    private static let operationStubs: [String: ListenTogetherControllerProtocol.Stub] = [
        "/weapi/listen/together/status/get": .init(invalidStatus),
        "/eapi/listen/together/room/create": .init(room),
        "/eapi/listen/together/play/invitation/accept": .init(room),
        "/eapi/listen/together/room/check": .init(roomCheck),
        "/api/middle/im/token/get": .init(credentials),
        "/eapi/listen/together/end/v2": .init(succeeded)
    ]
}

private enum StalledRoomOperation: Equatable {
    case create
    case join
    case token
}

@MainActor
private final class BootstrapWaitGate {
    private var entered = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func enter() {
        entered = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

private actor NonCooperativeRequestGate {
    private var passesBeforeBlocking: Int?
    private var nextEntry = 0
    private var entered: Set<Int> = []
    private var cancelled: Set<Int> = []
    private var waiters: [Int: CheckedContinuation<Void, Never>] = [:]
    private var entryWaiters: [Int: [CheckedContinuation<Bool, Never>]] = [:]
    private var cancellationWaiters: [Int: [CheckedContinuation<Bool, Never>]] = [:]

    func arm(afterPassing passes: Int = 0) {
        passesBeforeBlocking = passes
    }

    func wait() async {
        guard let passesBeforeBlocking else { return }
        if passesBeforeBlocking > 0 {
            self.passesBeforeBlocking = passesBeforeBlocking - 1
            return
        }
        self.passesBeforeBlocking = nil
        nextEntry += 1
        let entry = nextEntry
        await withTaskCancellationHandler {
            await withCheckedContinuation {
                waiters[entry] = $0
                entered.insert(entry)
                let pending = entryWaiters.removeValue(forKey: entry) ?? []
                for waiter in pending { waiter.resume(returning: true) }
            }
        } onCancel: {
            Task { await self.recordCancellation(entry) }
        }
    }

    func waitUntilEntered(_ entry: Int) async -> Bool {
        if entered.contains(entry) { return true }
        return await withCheckedContinuation { entryWaiters[entry, default: []].append($0) }
    }

    func waitUntilCancelled(_ entry: Int) async -> Bool {
        if cancelled.contains(entry) { return true }
        return await withCheckedContinuation {
            cancellationWaiters[entry, default: []].append($0)
        }
    }

    func release(_ entry: Int) {
        waiters.removeValue(forKey: entry)?.resume()
    }

    private func recordCancellation(_ entry: Int) {
        cancelled.insert(entry)
        let pending = cancellationWaiters.removeValue(forKey: entry) ?? []
        for waiter in pending { waiter.resume(returning: true) }
    }
}

private actor RevisionFenceGate {
    private var blocked = true
    private var entered = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        entered = true
        guard blocked else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func waitUntilBlocked() async {
        while !entered { await Task.yield() }
    }

    func open() {
        blocked = false
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}

private final class RevisionFenceProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var count = 0

    static var requestCount: Int { lock.withLock { count } }
    static func reset() { lock.withLock { count = 0 } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.withLock { Self.count += 1 }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: [:]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"code":200,"data":{"result":true}}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
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
    private(set) var disconnectCount = 0
    private(set) var shutdownCount = 0
    private(set) var emittedMessageCount = 0
    private var generation = 0
    private var connected = false
    private let messageOnConnect: String?
    private let disconnectGate: RevisionFenceGate?

    init(
        messageOnConnect: String? = nil,
        disconnectGate: RevisionFenceGate? = nil
    ) {
        self.messageOnConnect = messageOnConnect
        self.disconnectGate = disconnectGate
    }

    func connect(
        roomID: String,
        credentials: ListenTogetherRealtimeCredentials,
        generation: Int
    ) async throws {
        if connected {
            disconnectCount += 1
            ListenTogetherControllerProtocol.record("realtime-disconnect")
        }
        connectCount += 1
        self.generation = generation
        connected = true
        ListenTogetherControllerProtocol.record("realtime-connect")
        if connectCount == 1, let messageOnConnect {
            emittedMessageCount += 1
            onEvent?(.message(raw: messageOnConnect, generation: generation))
        }
    }

    func disconnect(generation: Int) async {
        if let disconnectGate { await disconnectGate.wait() }
        guard connected, self.generation == generation else { return }
        connected = false
        disconnectCount += 1
        ListenTogetherControllerProtocol.record("realtime-disconnect")
    }

    func shutdown() async {
        shutdownCount += 1
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
    let expectedCredentialRevision = service.credentialRevision
    let realtime = NIMChatroomTransport()
    let recorder = ListenTogetherRealtimeRecorder()
    realtime.onEvent = { recorder.events.append($0) }
    var hostUserID: Int64?
    var roomID: String?
    var failure: ListenTogetherLiveTestError?

    do {
        let userID = try await listenTogetherLiveUserID(transport: transport)
        hostUserID = userID
        let room = try await service.createRoom(
            currentUserID: userID,
            expectedCredentialRevision: expectedCredentialRevision
        )
        roomID = room.id
        try coordination.writeRoom(ListenTogetherLiveRoomDescriptor(
            roomID: room.id,
            chatRoomID: room.chatRoomID,
            inviterID: userID
        ))
        try coordination.signal("host-room-created")
        try await coordination.waitForSignal("member-joined")

        let realtimeCredentials = try await service.realtimeCredentials(
            expectedCredentialRevision: expectedCredentialRevision
        )
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
            progress: 0,
            expectedCredentialRevision: expectedCredentialRevision
        ).succeeded else { throw ListenTogetherLiveTestError.heartbeatRejected }
        try coordination.signal("host-heartbeat")
        try await coordination.waitForSignal("member-heartbeat")
        try await coordination.waitForSignal("member-receive-ready")

        for (index, step) in listenTogetherLivePlaySteps(sender: .host).enumerated() {
            let command = try listenTogetherLiveCommand(step: step, sequence: index + 1)
            guard try await service.reportPlayCommandConfirmed(
                roomID: room.id,
                command: command,
                expectedCredentialRevision: expectedCredentialRevision
            ) else {
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
        guard try await service.reportPlaylistCommandConfirmed(
            roomID: room.id,
            command: playlist,
            expectedCredentialRevision: expectedCredentialRevision
        ) else {
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
                progress: 0,
                expectedCredentialRevision: expectedCredentialRevision
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
            transport: transport,
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
                transport: transport,
                roomID: roomID,
                currentUserID: hostUserID,
                expectedCredentialRevision: expectedCredentialRevision
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
    let expectedCredentialRevision = service.credentialRevision
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
        let accepted = try await service.acceptInvitation(
            invitation,
            currentUserID: userID,
            expectedCredentialRevision: expectedCredentialRevision
        )
        guard accepted.id == descriptor.roomID, accepted.chatRoomID == descriptor.chatRoomID else {
            throw ListenTogetherLiveTestError.roomMismatch
        }
        joined = true
        try coordination.signal("member-joined")

        let realtimeCredentials = try await service.realtimeCredentials(
            expectedCredentialRevision: expectedCredentialRevision
        )
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
            progress: 0,
            expectedCredentialRevision: expectedCredentialRevision
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
                progress: 0,
                expectedCredentialRevision: expectedCredentialRevision
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
                command: command,
                expectedCredentialRevision: expectedCredentialRevision
            ) else { throw ListenTogetherLiveTestError.commandRejected }
            try coordination.signal("member-play-\(index)-sent")
            try await coordination.waitForSignal("host-play-\(index)-received")
        }

        try await coordination.waitForSignal("host-exit-ready")
        guard try await service.endRoomConfirmed(
            roomID: descriptor.roomID,
            expectedCredentialRevision: expectedCredentialRevision
        ) else {
            throw ListenTogetherLiveTestError.endRejected
        }
        guard await waitForListenTogetherRoomState(
            service: service,
            transport: transport,
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
        _ = try? await service.endRoomConfirmed(
            roomID: room.roomID,
            expectedCredentialRevision: expectedCredentialRevision
        )
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
    host: String,
    expectedCredentialRevision: UInt64
) async throws -> ListenTogetherTokenMetadata {
    let response = try await transport.requestQuery(
        path: "/api/middle/im/token/get",
        fields: [("bizName", "music_listenTogether")],
        host: host,
        expectedCredentialRevision: expectedCredentialRevision
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
    transport: EAPITransport,
    roomID: String,
    currentUserID: Int64,
    expectedCredentialRevision: UInt64
) async throws {
    _ = try? await service.endRoomConfirmed(
        roomID: roomID,
        expectedCredentialRevision: expectedCredentialRevision
    )
    guard await waitForListenTogetherRoomState(
        service: service,
        transport: transport,
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

private func listenTogetherPlaylistDiagnostic(_ data: [String: Any], expectedSongID: Int64) -> String {
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
    transport: EAPITransport,
    currentUserID: Int64,
    roomID: String,
    inRoom: Bool
) async -> Bool {
    for _ in 0..<20 {
        if let status = try? await listenTogetherLiveStatus(
            service: service,
            transport: transport,
            currentUserID: currentUserID
        ),
           status.inRoom == inRoom,
           !inRoom || status.room?.id == roomID {
            return true
        }
        try? await Task.sleep(for: .milliseconds(250))
    }
    return false
}

private func listenTogetherLiveStatus(
    service: LiveListenTogetherService,
    transport: EAPITransport,
    currentUserID: Int64
) async throws -> ListenTogetherStatus {
    do {
        return try await service.status(currentUserID: currentUserID)
    } catch EAPIError.service(301, _) {
        let data = try await transport.request(
            EAPIEndpoint(
                "/eapi/listen/together/status/get",
                signing: "/api/listen/together/status/get"
            ),
            json: compactJSON([:]),
            invalidatesAccountCache: false,
            retryable: false
        )
        return try ListenTogetherResponseDecoder.status(from: data, currentUserID: currentUserID)
    }
}
