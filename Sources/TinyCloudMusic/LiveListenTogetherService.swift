import Foundation

struct LiveListenTogetherService: Sendable {
    let transport: EAPITransport

    var credentialRevision: UInt64 { transport.credentialSnapshotValue().revision }

    init(transport: EAPITransport = EAPITransport()) {
        self.transport = transport
    }

    func createRoom(expectedCredentialRevision: UInt64) async throws -> [String: Any] {
        try await call(
            "/api/listen/together/room/create",
            payload: ["refer": "songplay_more"],
            expectedCredentialRevision: expectedCredentialRevision
        )
    }

    func createRoom(
        currentUserID: Int64,
        expectedCredentialRevision: UInt64
    ) async throws -> ListenTogetherRoom {
        try ListenTogetherResponseDecoder.room(
            from: await createRoom(expectedCredentialRevision: expectedCredentialRevision),
            currentUserID: currentUserID
        )
    }

    func checkRoom(roomID: String, expectedCredentialRevision: UInt64? = nil) async throws -> [String: Any] {
        try await call(
            "/api/listen/together/room/check",
            payload: ["roomId": try validatedRoomID(roomID)],
            expectedCredentialRevision: expectedCredentialRevision ?? credentialRevision,
            retryable: true
        )
    }

    func checkInvitation(
        _ invitation: ListenTogetherInvitation,
        expectedCredentialRevision: UInt64? = nil
    ) async throws -> ListenTogetherRoomCheck {
        try ListenTogetherResponseDecoder.roomCheck(from: await checkRoom(
            roomID: invitation.roomID,
            expectedCredentialRevision: expectedCredentialRevision
        ))
    }

    func acceptInvitation(
        roomID: String,
        inviterID: Int64,
        expectedCredentialRevision: UInt64
    ) async throws -> [String: Any] {
        guard inviterID > 0 else { throw EAPIError.invalidPayload }
        return try await call(
            "/api/listen/together/play/invitation/accept",
            payload: ["refer": "inbox_invite", "roomId": try validatedRoomID(roomID), "inviterId": inviterID],
            expectedCredentialRevision: expectedCredentialRevision
        )
    }

    func acceptInvitation(
        _ invitation: ListenTogetherInvitation,
        currentUserID: Int64,
        expectedCredentialRevision: UInt64
    ) async throws -> ListenTogetherRoom {
        try ListenTogetherResponseDecoder.room(
            from: await acceptInvitation(
                roomID: invitation.roomID,
                inviterID: invitation.inviterID,
                expectedCredentialRevision: expectedCredentialRevision
            ),
            currentUserID: currentUserID
        )
    }

    func status(expectedCredentialRevision: UInt64? = nil) async throws -> [String: Any] {
        let expectedCredentialRevision = expectedCredentialRevision ?? credentialRevision
        return try await transport.requestWEAPIJSONObject(
            path: "/weapi/listen/together/status/get",
            payload: [:],
            expectedCredentialRevision: expectedCredentialRevision,
            invalidatesAccountCache: false
        )
    }

    func status(
        currentUserID: Int64,
        expectedCredentialRevision: UInt64? = nil
    ) async throws -> ListenTogetherStatus {
        try ListenTogetherResponseDecoder.status(
            from: await status(expectedCredentialRevision: expectedCredentialRevision),
            currentUserID: currentUserID
        )
    }

    func heartbeat(
        roomID: String,
        songID: Int64,
        playStatus: ListenTogetherPlayStatus,
        progress: Int64,
        expectedCredentialRevision: UInt64
    ) async throws -> [String: Any] {
        guard songID > 0, progress >= 0 else { throw EAPIError.invalidPayload }
        return try await call(
            "/api/listen/together/heartbeat",
            payload: [
                "roomId": try validatedRoomID(roomID),
                "songId": songID,
                "playStatus": playStatus.rawValue,
                "progress": progress
            ],
            expectedCredentialRevision: expectedCredentialRevision
        )
    }

    func heartbeatState(
        roomID: String,
        songID: Int64,
        playStatus: ListenTogetherPlayStatus,
        progress: Int64,
        expectedCredentialRevision: UInt64
    ) async throws -> ListenTogetherHeartbeat {
        try ListenTogetherResponseDecoder.heartbeat(
            from: await heartbeat(
                roomID: roomID,
                songID: songID,
                playStatus: playStatus,
                progress: progress,
                expectedCredentialRevision: expectedCredentialRevision
            )
        )
    }

    func reportPlayCommand(
        roomID: String,
        command: ListenTogetherPlayCommand,
        expectedCredentialRevision: UInt64
    ) async throws -> [String: Any] {
        let commandInfo: [String: Any] = [
            "commandType": command.commandType.rawValue,
            "progress": command.progress,
            "playStatus": command.playStatus.rawValue,
            "formerSongId": command.formerSongID,
            "targetSongId": command.targetSongID,
            "clientSeq": command.clientSequence
        ]
        return try await call(
            "/api/listen/together/play/command/report",
            payload: ["roomId": try validatedRoomID(roomID), "commandInfo": try jsonString(commandInfo)],
            expectedCredentialRevision: expectedCredentialRevision
        )
    }

    func reportPlayCommandConfirmed(
        roomID: String,
        command: ListenTogetherPlayCommand,
        expectedCredentialRevision: UInt64
    ) async throws -> Bool {
        try ListenTogetherResponseDecoder.succeeded(
            from: await reportPlayCommand(
                roomID: roomID,
                command: command,
                expectedCredentialRevision: expectedCredentialRevision
            )
        )
    }

    func reportPlaylistCommand(
        roomID: String,
        command: ListenTogetherPlaylistCommand,
        expectedCredentialRevision: UInt64
    ) async throws -> [String: Any] {
        let playlist: [String: Any] = [
            "commandType": command.commandType.rawValue,
            "version": [["userId": command.userID, "version": command.version]],
            "playMode": command.playMode.rawValue,
            "anchorSongId": command.anchorSongID.map(String.init) ?? "",
            "anchorPosition": command.anchorPosition,
            "randomList": command.randomList.map(String.init),
            "displayList": command.displayList.map(String.init)
        ]
        return try await call(
            "/api/listen/together/sync/list/command/report",
            payload: ["roomId": try validatedRoomID(roomID), "playlistParam": try jsonString(playlist)],
            expectedCredentialRevision: expectedCredentialRevision
        )
    }

    func reportPlaylistCommandConfirmed(
        roomID: String,
        command: ListenTogetherPlaylistCommand,
        expectedCredentialRevision: UInt64
    ) async throws -> Bool {
        try ListenTogetherResponseDecoder.succeeded(
            from: await reportPlaylistCommand(
                roomID: roomID,
                command: command,
                expectedCredentialRevision: expectedCredentialRevision
            )
        )
    }

    func playlist(
        roomID: String,
        displaySongIDs: [Int64],
        randomSongIDs: [Int64],
        anchorSongID: Int64?,
        expectedCredentialRevision: UInt64? = nil
    ) async throws -> [String: Any] {
        let anchorPosition = anchorSongID.flatMap(displaySongIDs.firstIndex(of:)) ?? -1
        let playMode: ListenTogetherPlayMode = randomSongIDs.isEmpty || randomSongIDs == displaySongIDs
            ? .orderLoop
            : .random
        guard ListenTogetherPlaylistValidator.isValid(
            display: displaySongIDs,
            random: randomSongIDs,
            anchorSongID: anchorSongID,
            anchorPosition: anchorPosition,
            playMode: playMode,
            allowsEmptyDisplay: true
        ) else { throw EAPIError.invalidPayload }
        let playlistParam: [String: Any] = [
            "playMode": playMode.rawValue,
            "anchorSongId": anchorSongID.map(String.init) ?? "",
            "anchorPosition": anchorPosition,
            "randomList": randomSongIDs.map(String.init),
            "displayList": displaySongIDs.map(String.init)
        ]
        return try await call(
            "/api/listen/together/sync/playlist/get",
            payload: [
                "roomId": try validatedRoomID(roomID),
                "playlistParam": try jsonString(playlistParam)
            ],
            expectedCredentialRevision: expectedCredentialRevision ?? credentialRevision,
            retryable: true
        )
    }

    func authoritativePlaylist(
        roomID: String,
        displaySongIDs: [Int64],
        randomSongIDs: [Int64],
        anchorSongID: Int64?,
        expectedCredentialRevision: UInt64? = nil
    ) async throws -> ListenTogetherPlaylist? {
        try ListenTogetherResponseDecoder.playlist(
            from: await playlist(
                roomID: roomID,
                displaySongIDs: displaySongIDs,
                randomSongIDs: randomSongIDs,
                anchorSongID: anchorSongID,
                expectedCredentialRevision: expectedCredentialRevision
            )
        )
    }

    func authoritativeState(
        roomID: String,
        displaySongIDs: [Int64],
        randomSongIDs: [Int64],
        anchorSongID: Int64?,
        expectedCredentialRevision: UInt64? = nil
    ) async throws -> ListenTogetherAuthoritativeState? {
        try ListenTogetherResponseDecoder.authoritativeState(
            from: await playlist(
                roomID: roomID,
                displaySongIDs: displaySongIDs,
                randomSongIDs: randomSongIDs,
                anchorSongID: anchorSongID,
                expectedCredentialRevision: expectedCredentialRevision
            )
        )
    }

    func realtimeCredentials(
        expectedCredentialRevision: UInt64
    ) async throws -> ListenTogetherRealtimeCredentials {
        let root = try await transport.requestQueryJSONObject(
            path: "/api/middle/im/token/get",
            fields: [("bizName", "music_listenTogether")],
            host: "https://interface3.music.163.com",
            expectedCredentialRevision: expectedCredentialRevision
        )
        try validateCredentialRevision(expectedCredentialRevision)
        return try ListenTogetherResponseDecoder.realtimeCredentials(from: root)
    }

    func endRoom(roomID: String, expectedCredentialRevision: UInt64) async throws -> [String: Any] {
        try await call(
            "/api/listen/together/end/v2",
            payload: ["roomId": try validatedRoomID(roomID)],
            expectedCredentialRevision: expectedCredentialRevision
        )
    }

    func endRoomConfirmed(
        roomID: String,
        expectedCredentialRevision: UInt64
    ) async throws -> Bool {
        try ListenTogetherResponseDecoder.succeeded(from: await endRoom(
            roomID: roomID,
            expectedCredentialRevision: expectedCredentialRevision
        ))
    }

    private func call(
        _ logicalPath: String,
        payload: [String: Any],
        expectedCredentialRevision: UInt64,
        retryable: Bool = false
    ) async throws -> [String: Any] {
        let physicalPath = logicalPath.replacingOccurrences(of: "/api/", with: "/eapi/")
        return try await transport.requestJSONObject(
            EAPIEndpoint(physicalPath, signing: logicalPath),
            json: compactJSON(payload),
            expectedCredentialRevision: expectedCredentialRevision,
            invalidatesAccountCache: false,
            retryable: retryable
        )
    }

    private func validateCredentialRevision(_ expected: UInt64) throws {
        let actual = credentialRevision
        guard actual == expected else {
            throw CredentialRevisionMismatch(expected: expected, actual: actual)
        }
    }

    private func validatedRoomID(_ value: String) throws -> String {
        guard !value.isEmpty,
              value == value.trimmingCharacters(in: .whitespacesAndNewlines)
        else { throw EAPIError.invalidPayload }
        return value
    }

    private func jsonString(_ value: [String: Any]) throws -> String {
        String(decoding: try compactJSON(value), as: UTF8.self)
    }
}
