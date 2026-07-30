import Foundation

enum ListenTogetherRole: Equatable, Sendable {
    case host
    case member
}

struct ListenTogetherMember: Identifiable, Equatable, Sendable {
    let id: Int64
    let nickname: String
    let avatarURL: URL?
}

struct ListenTogetherRoom: Equatable, Sendable {
    let id: String
    let chatRoomID: String
    let creatorID: Int64
    let role: ListenTogetherRole
    let members: [ListenTogetherMember]
    let startedAt: Date?

    func invitationURL(songID: Int64) -> URL? {
        guard songID > 0 else { return nil }
        var components = URLComponents()
        components.scheme = "https"
        components.host = "st.music.163.com"
        components.path = "/listen-together/share/"
        components.queryItems = [
            URLQueryItem(name: "songId", value: String(songID)),
            URLQueryItem(name: "roomId", value: id),
            URLQueryItem(name: "inviterId", value: String(creatorID))
        ]
        return components.url
    }
}

struct ListenTogetherInvitation: Equatable, Sendable {
    let roomID: String
    let inviterID: Int64

    init(roomID: String, inviterID: Int64) throws {
        let roomID = roomID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !roomID.isEmpty,
              roomID.count <= 128,
              !roomID.contains(where: { $0.isWhitespace || $0.isNewline }),
              inviterID > 0
        else { throw EAPIError.invalidPayload }
        self.roomID = roomID
        self.inviterID = inviterID
    }

    static func parse(_ value: String, inviterID: String) throws -> Self {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let components = URLComponents(string: value),
           components.scheme != nil || components.host != nil {
            guard components.scheme == "https",
                  components.host == "st.music.163.com",
                  components.path == "/listen-together/share/"
            else { throw EAPIError.invalidPayload }
            let items = components.queryItems ?? []
            let roomIDs = items.filter { $0.name == "roomId" }.compactMap(\.value)
            let inviterIDs = items.filter { $0.name == "inviterId" }.compactMap(\.value)
            guard roomIDs.count == 1,
                  inviterIDs.count == 1,
                  let roomID = roomIDs.first,
                  let inviter = inviterIDs.first.flatMap(Int64.init)
            else { throw EAPIError.invalidPayload }
            return try Self(roomID: roomID, inviterID: inviter)
        }
        guard let inviter = Int64(inviterID.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw EAPIError.invalidPayload
        }
        return try Self(roomID: value, inviterID: inviter)
    }
}

struct ListenTogetherRoomCheck: Equatable, Sendable {
    let joinable: Bool
    let status: String
    let message: String?
}

struct ListenTogetherStatus: Equatable, Sendable {
    let inRoom: Bool
    let status: String
    let room: ListenTogetherRoom?
}

struct ListenTogetherHeartbeat: Equatable, Sendable {
    let succeeded: Bool
    let intervalSeconds: Int
}

struct ListenTogetherRealtimeCredentials: Equatable, Sendable {
    let accountID: String
    let token: String
    let addresses: [String]
}

struct ListenTogetherPlaylist: Equatable, Sendable {
    let displaySongIDs: [Int64]
    let randomSongIDs: [Int64]
    let anchorSongID: Int64?
    let version: Int64
}

struct ListenTogetherPlaybackSnapshot: Equatable, Sendable {
    let commandType: ListenTogetherPlayCommandType
    let progressMilliseconds: Int64
    let playStatus: ListenTogetherPlayStatus
    let formerSongID: Int64
    let targetSongID: Int64
}

struct ListenTogetherAuthoritativeState: Equatable, Sendable {
    let playlist: ListenTogetherPlaylist
    let playback: ListenTogetherPlaybackSnapshot?
}

struct ListenTogetherRemotePlayCommand: Equatable, Sendable {
    let commandType: ListenTogetherPlayCommandType
    let progressMilliseconds: Int64
    let playStatus: ListenTogetherPlayStatus
    let formerSongID: Int64
    let targetSongID: Int64
    let serverSequence: Int64
}

enum ListenTogetherRemoteEvent: Equatable, Sendable {
    case play(ListenTogetherRemotePlayCommand)
    case playlistChanged(serverSequence: Int64?)
    case memberJoined
    case roomEnded(reason: String?)
    case heartbeatRequested(ignoredUserIDs: [Int64])
}

enum ListenTogetherPhase: Equatable, Sendable {
    case idle
    case recoveryAvailable(ListenTogetherRoom)
    case creating
    case checking(ListenTogetherInvitation)
    case readyToJoin(ListenTogetherInvitation)
    case joining(ListenTogetherInvitation)
    case connected(ListenTogetherRoom)
    case reconnecting(ListenTogetherRoom, attempt: Int)
    case ending(ListenTogetherRoom)
    case ended(reason: String?)
    case failed(String)
}

enum ListenTogetherPlayStatus: String, CaseIterable, Sendable {
    case playing = "PLAY"
    case paused = "PAUSE"
}

enum ListenTogetherPlayCommandType: String, CaseIterable, Sendable {
    case play = "PLAY"
    case pause = "PAUSE"
    case progress = "PROGRESS"
    case next = "NEXT"
    case previous = "PREVIOUS"
    case goTo = "GOTO"
}

enum ListenTogetherPlayMode: String, CaseIterable, Sendable {
    case orderLoop = "ORDER_LOOP"
    case random = "RANDOM"
    case singleLoop = "SINGLE_LOOP"
}

enum ListenTogetherPlaylistCommandType: String, CaseIterable, Sendable {
    case replace = "REPLACE"
}

struct ListenTogetherPlayCommand: Equatable, Sendable {
    let commandType: ListenTogetherPlayCommandType
    let progress: Int64
    let playStatus: ListenTogetherPlayStatus
    let formerSongID: Int64
    let targetSongID: Int64
    let clientSequence: Int64

    init(
        commandType: ListenTogetherPlayCommandType,
        progress: Int64,
        playStatus: ListenTogetherPlayStatus,
        formerSongID: Int64,
        targetSongID: Int64,
        clientSequence: Int64
    ) throws {
        guard progress >= 0,
              formerSongID == -1 || formerSongID > 0,
              targetSongID > 0,
              clientSequence > 0
        else { throw EAPIError.invalidPayload }
        self.commandType = commandType
        self.progress = progress
        self.playStatus = playStatus
        self.formerSongID = formerSongID
        self.targetSongID = targetSongID
        self.clientSequence = clientSequence
    }
}

struct ListenTogetherPlaylistCommand: Equatable, Sendable {
    let commandType: ListenTogetherPlaylistCommandType
    let userID: Int64
    let version: Int64
    let playMode: ListenTogetherPlayMode
    let anchorSongID: Int64?
    let anchorPosition: Int
    let randomList: [Int64]
    let displayList: [Int64]

    init(
        commandType: ListenTogetherPlaylistCommandType,
        userID: Int64,
        version: Int64,
        playMode: ListenTogetherPlayMode = .orderLoop,
        anchorSongID: Int64? = nil,
        anchorPosition: Int = -1,
        randomList: [Int64],
        displayList: [Int64]
    ) throws {
        guard userID > 0,
              version >= 0,
              anchorSongID.map({ $0 > 0 }) ?? true,
              anchorPosition >= -1,
              randomList.allSatisfy({ $0 > 0 }),
              displayList.allSatisfy({ $0 > 0 })
        else { throw EAPIError.invalidPayload }
        self.commandType = commandType
        self.userID = userID
        self.version = version
        self.playMode = playMode
        self.anchorSongID = anchorSongID
        self.anchorPosition = anchorPosition
        self.randomList = randomList
        self.displayList = displayList
    }
}

enum ListenTogetherResponseDecoder {
    static func room(from data: Data, currentUserID: Int64) throws -> ListenTogetherRoom {
        let root = try decodedJSONObject(data)
        let nested = root.object("data").object("roomInfo")
        let value = nested.isEmpty ? root.object("roomInfo") : nested
        return try room(from: value, currentUserID: currentUserID)
    }

    static func roomCheck(from data: Data) throws -> ListenTogetherRoomCheck {
        let value = try decodedJSONObject(data).object("data")
        let status = string(value["status"])
        guard isProtocolValue(status), let joinable = boolean(value["joinable"]) else {
            throw EAPIError.invalidResponse
        }
        let message = optionalString(value["copywriting"])
        return ListenTogetherRoomCheck(joinable: joinable, status: status, message: message)
    }

    static func status(from data: Data, currentUserID: Int64) throws -> ListenTogetherStatus {
        let value = try decodedJSONObject(data).object("data")
        guard let inRoom = boolean(value["inRoom"]) else { throw EAPIError.invalidResponse }
        let room = inRoom ? try room(from: value.object("roomInfo"), currentUserID: currentUserID) : nil
        let status = string(value["status"])
        guard status.isEmpty || isProtocolValue(status) else { throw EAPIError.invalidResponse }
        return ListenTogetherStatus(inRoom: inRoom, status: status, room: room)
    }

    static func heartbeat(from data: Data) throws -> ListenTogetherHeartbeat {
        let value = try decodedJSONObject(data).object("data")
        guard let succeeded = boolean(value["result"]),
              let intervalValue = number(value["timeSpan"]),
              let interval = Int(exactly: intervalValue),
              (5...300).contains(interval)
        else { throw EAPIError.invalidResponse }
        return ListenTogetherHeartbeat(succeeded: succeeded, intervalSeconds: interval)
    }

    static func succeeded(from data: Data) throws -> Bool {
        let value = try decodedJSONObject(data).object("data")
        guard let result = boolean(value["result"] ?? value["success"]) else { throw EAPIError.invalidResponse }
        return result
    }

    static func realtimeCredentials(from data: Data) throws -> ListenTogetherRealtimeCredentials {
        let value = try decodedJSONObject(data).object("data")
        let accountID = string(value["accId"])
        let token = string(value["token"])
        guard let addresses = stringArray(value["addr"] ?? []) else { throw EAPIError.invalidResponse }
        guard !accountID.isEmpty,
              accountID.count <= 128,
              !token.isEmpty,
              token.count <= 4_096,
              addresses.count <= 16,
              addresses.allSatisfy({ !$0.isEmpty && $0.count <= 2_048 && !$0.contains(where: \.isWhitespace) })
        else { throw EAPIError.invalidResponse }
        return ListenTogetherRealtimeCredentials(accountID: accountID, token: token, addresses: addresses)
    }

    static func authoritativeState(from data: Data) throws -> ListenTogetherAuthoritativeState? {
        let data = try decodedJSONObject(data).object("data")
        let playList = data.object("playList")
        let playlist = data.object("playlist")
        let value = !playList.isEmpty ? playList : (playlist.isEmpty ? data : playlist)
        guard !value.isEmpty else { return nil }
        guard let display = songIDs(value["displayList"]),
              let random = songIDs(value["randomList"]),
              !display.isEmpty,
              Set(display).count == display.count,
              random.isEmpty || (random.count == display.count && Set(random) == Set(display))
        else { throw EAPIError.invalidResponse }
        let anchor = positiveID(value["anchorSongId"])
        if let anchor, !display.contains(anchor) { throw EAPIError.invalidResponse }
        let versionValues = value["version"] as? [[String: Any]] ?? []
        let versions = versionValues.compactMap { number($0["version"]) }
        guard versions.count == versionValues.count else { throw EAPIError.invalidResponse }
        let version = max(number(value["version"]) ?? 0, versions.max() ?? 0)
        guard version >= 0 else { throw EAPIError.invalidResponse }
        let decodedPlaylist = ListenTogetherPlaylist(
            displaySongIDs: display,
            randomSongIDs: random.isEmpty ? display : random,
            anchorSongID: anchor,
            version: version
        )
        let playback = try playbackSnapshot(from: data.object("playCommand"))
        return ListenTogetherAuthoritativeState(playlist: decodedPlaylist, playback: playback)
    }

    static func playlist(from data: Data) throws -> ListenTogetherPlaylist? {
        try authoritativeState(from: data)?.playlist
    }

    static func remoteEvent(from raw: String) throws -> ListenTogetherRemoteEvent {
        guard !raw.isEmpty, raw.utf8.count <= 65_536,
              let data = raw.data(using: .utf8),
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw EAPIError.invalidResponse }
        guard let envelope = realtimeEnvelope(root),
              let type = number(envelope["type"]) ?? number(envelope["event_type"])
        else { throw EAPIError.invalidResponse }
        let payload = dictionary(envelope["config"])
            ?? dictionary(envelope["content"])
            ?? dictionary(envelope["data"])
            ?? envelope

        switch type {
        case 20_000:
            let command = dictionary(payload["commandInfo"]) ?? payload
            guard let commandType = ListenTogetherPlayCommandType(rawValue: string(command["commandType"])),
                  let playStatus = ListenTogetherPlayStatus(rawValue: string(command["playStatus"])),
                  let progress = number(command["progress"]),
                  let formerSongID = number(command["formerSongId"]),
                  let targetSongID = number(command["targetSongId"]),
                  let serverSequence = number(command["serverSeq"])
                    ?? number(payload["serverSeq"])
                    ?? number(envelope["serverSeq"]),
                  progress >= 0,
                  progress <= 604_800_000,
                  formerSongID == -1 || formerSongID > 0,
                  targetSongID > 0,
                  serverSequence > 0
            else { throw EAPIError.invalidResponse }
            return .play(ListenTogetherRemotePlayCommand(
                commandType: commandType,
                progressMilliseconds: progress,
                playStatus: playStatus,
                formerSongID: formerSongID,
                targetSongID: targetSongID,
                serverSequence: serverSequence
            ))
        case 20_001:
            let sequence = number(payload["serverSeq"]) ?? number(envelope["serverSeq"])
            guard sequence == nil || sequence! > 0 else { throw EAPIError.invalidResponse }
            return .playlistChanged(serverSequence: sequence)
        case 20_002:
            return .memberJoined
        case 20_003:
            let reason = optionalString(payload["reason"] ?? payload["message"])
            guard reason?.count ?? 0 <= 512 else { throw EAPIError.invalidResponse }
            return .roomEnded(reason: reason)
        case 20_008:
            let values = payload["ignoreUserIds"] as? [Any] ?? []
            let ignoredUserIDs = values.compactMap(number)
            guard ignoredUserIDs.count == values.count,
                  ignoredUserIDs.allSatisfy({ $0 > 0 })
            else { throw EAPIError.invalidResponse }
            return .heartbeatRequested(ignoredUserIDs: ignoredUserIDs)
        default:
            throw EAPIError.invalidResponse
        }
    }

    private static func playbackSnapshot(
        from value: [String: Any]
    ) throws -> ListenTogetherPlaybackSnapshot? {
        guard !value.isEmpty else { return nil }
        guard let commandType = ListenTogetherPlayCommandType(rawValue: string(value["commandType"])),
              let playStatus = ListenTogetherPlayStatus(rawValue: string(value["playStatus"])),
              let progress = number(value["progress"]),
              let formerSongID = number(value["formerSongId"]),
              let targetSongID = number(value["targetSongId"]),
              progress >= 0,
              progress <= 604_800_000,
              formerSongID == -1 || formerSongID > 0,
              targetSongID > 0
        else { throw EAPIError.invalidResponse }
        return ListenTogetherPlaybackSnapshot(
            commandType: commandType,
            progressMilliseconds: progress,
            playStatus: playStatus,
            formerSongID: formerSongID,
            targetSongID: targetSongID
        )
    }

    private static func room(
        from value: [String: Any],
        currentUserID: Int64
    ) throws -> ListenTogetherRoom {
        let id = string(value["roomId"])
        let chatRoomID = string(value["chatRoomId"])
        guard let creatorID = number(value["creatorId"]),
              let roomUsers = value["roomUsers"] as? [[String: Any]]
        else { throw EAPIError.invalidResponse }
        guard !id.isEmpty,
              id.count <= 128,
              !chatRoomID.isEmpty,
              chatRoomID.count <= 128,
              creatorID > 0,
              currentUserID > 0
        else { throw EAPIError.invalidResponse }
        let members = try roomUsers.map { member -> ListenTogetherMember in
            guard let id = number(member["userId"]), let nickname = member["nickname"] as? String else {
                throw EAPIError.invalidResponse
            }
            guard id > 0, nickname.count <= 200 else { throw EAPIError.invalidResponse }
            let avatar = member["avatarUrl"] as? String ?? ""
            let avatarURL = URL(string: avatar).flatMap { $0.scheme == "https" ? $0 : nil }
            return ListenTogetherMember(id: id, nickname: nickname, avatarURL: avatarURL)
        }
        guard Set(members.map(\.id)).count == members.count else { throw EAPIError.invalidResponse }
        let startedAt: Date?
        if let rawStartedAt = value["roomCreateTime"], !(rawStartedAt is NSNull) {
            guard let milliseconds = number(rawStartedAt), milliseconds > 0 else {
                throw EAPIError.invalidResponse
            }
            startedAt = Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1_000)
        } else {
            startedAt = nil
        }
        return ListenTogetherRoom(
            id: id,
            chatRoomID: chatRoomID,
            creatorID: creatorID,
            role: creatorID == currentUserID ? .host : .member,
            members: members,
            startedAt: startedAt
        )
    }

    private static func dictionary(_ value: Any?) -> [String: Any]? {
        if let value = value as? [String: Any] { return value }
        guard let text = value as? String,
              text.utf8.count <= 65_536,
              let data = text.data(using: .utf8)
        else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func realtimeEnvelope(_ value: Any?, depth: Int = 0) -> [String: Any]? {
        guard depth < 8, let value = dictionary(value) else { return nil }
        if let type = number(value["type"] ?? value["event_type"]),
           [20_000, 20_001, 20_002, 20_003, 20_008].contains(type) {
            return value
        }
        for key in [
            "content", "attach", "msg_attach", "ext", "serverExt", "server_ext", "msg_body",
            "body", "msg", "data", "payload"
        ] {
            if let envelope = realtimeEnvelope(value[key], depth: depth + 1) { return envelope }
        }
        return nil
    }

    private static func songIDs(_ value: Any?) -> [Int64]? {
        guard let value, !(value is NSNull) else { return [] }
        let valuesContainer = dictionary(value)?["result"] ?? value
        guard let values = valuesContainer as? [Any] else { return nil }
        let result = values.compactMap(number)
        guard result.count == values.count, result.allSatisfy({ $0 > 0 }) else { return nil }
        return result
    }

    private static func stringArray(_ value: Any?) -> [String]? {
        guard let values = value as? [Any] else { return nil }
        let result = values.compactMap { optionalString($0) }
        return result.count == values.count ? result : nil
    }

    private static func number(_ value: Any?) -> Int64? {
        if let value = value as? NSNumber {
            guard CFGetTypeID(value) != CFBooleanGetTypeID(),
                  value.doubleValue.isFinite,
                  value.doubleValue.rounded(.towardZero) == value.doubleValue
            else { return nil }
            return value.int64Value
        }
        if let value = value as? String { return Int64(value) }
        return nil
    }

    private static func boolean(_ value: Any?) -> Bool? {
        guard let value = value as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else { return nil }
        return value.boolValue
    }

    private static func positiveID(_ value: Any?) -> Int64? {
        guard let value = number(value), value > 0 else { return nil }
        return value
    }

    private static func string(_ value: Any?) -> String {
        if let value = value as? String { return value }
        if let value = number(value) { return String(value) }
        return ""
    }

    private static func optionalString(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func isProtocolValue(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 32 && value.allSatisfy {
            $0.isASCII && ($0.isUppercase || $0.isNumber || $0 == "_")
        }
    }
}
