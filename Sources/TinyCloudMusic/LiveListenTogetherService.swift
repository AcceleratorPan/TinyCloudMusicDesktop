import Foundation

struct LiveListenTogetherService: Sendable {
    let transport: EAPITransport

    init(transport: EAPITransport = EAPITransport()) {
        self.transport = transport
    }

    func createRoom() async throws -> Data {
        try await call("/api/listen/together/room/create", payload: ["refer": "songplay_more"])
    }

    func checkRoom(roomID: String) async throws -> Data {
        try await call("/api/listen/together/room/check", payload: ["roomId": try validatedRoomID(roomID)])
    }

    func acceptInvitation(roomID: String, inviterID: Int64) async throws -> Data {
        guard inviterID > 0 else { throw EAPIError.invalidPayload }
        return try await call(
            "/api/listen/together/play/invitation/accept",
            payload: ["refer": "inbox_invite", "roomId": try validatedRoomID(roomID), "inviterId": inviterID]
        )
    }

    func status() async throws -> Data {
        let data = try await transport.requestWEAPI(
            path: "/weapi/listen/together/status/get",
            payload: [:],
            invalidatesAccountCache: false
        )
        _ = try decodedJSONObject(data)
        return data
    }

    func heartbeat(
        roomID: String,
        songID: Int64,
        playStatus: ListenTogetherPlayStatus,
        progress: Int64
    ) async throws -> Data {
        guard songID > 0, progress >= 0 else { throw EAPIError.invalidPayload }
        return try await call(
            "/api/listen/together/heartbeat",
            payload: [
                "roomId": try validatedRoomID(roomID),
                "songId": songID,
                "playStatus": playStatus.rawValue,
                "progress": progress
            ]
        )
    }

    func reportPlayCommand(roomID: String, command: ListenTogetherPlayCommand) async throws -> Data {
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
            payload: ["roomId": try validatedRoomID(roomID), "commandInfo": try jsonString(commandInfo)]
        )
    }

    func reportPlaylistCommand(
        roomID: String,
        command: ListenTogetherPlaylistCommand
    ) async throws -> Data {
        let playlist: [String: Any] = [
            "commandType": command.commandType.rawValue,
            "version": [["userId": command.userID, "version": command.version]],
            "anchorSongId": command.anchorSongID.map(String.init) ?? "",
            "anchorPosition": command.anchorPosition,
            "randomList": command.randomList.map(String.init),
            "displayList": command.displayList.map(String.init)
        ]
        return try await call(
            "/api/listen/together/sync/list/command/report",
            payload: ["roomId": try validatedRoomID(roomID), "playlistParam": try jsonString(playlist)]
        )
    }

    func playlist(roomID: String) async throws -> Data {
        try await call(
            "/api/listen/together/sync/playlist/get",
            payload: ["roomId": try validatedRoomID(roomID)]
        )
    }

    func endRoom(roomID: String) async throws -> Data {
        try await call("/api/listen/together/end/v2", payload: ["roomId": try validatedRoomID(roomID)])
    }

    private func call(_ logicalPath: String, payload: [String: Any]) async throws -> Data {
        let physicalPath = logicalPath.replacingOccurrences(of: "/api/", with: "/eapi/")
        let data = try await transport.request(
            EAPIEndpoint(physicalPath, signing: logicalPath),
            json: compactJSON(payload),
            invalidatesAccountCache: false,
            retryable: false
        )
        _ = try decodedJSONObject(data)
        return data
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
