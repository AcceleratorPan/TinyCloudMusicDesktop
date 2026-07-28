import Foundation

enum ListenTogetherPlayStatus: String, CaseIterable, Sendable {
    case playing = "PLAY"
    case paused = "PAUSE"
}

enum ListenTogetherPlayCommandType: String, CaseIterable, Sendable {
    case play = "PLAY"
    case pause = "PAUSE"
    case goTo = "GOTO"
    case seek
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
    let anchorSongID: Int64?
    let anchorPosition: Int
    let randomList: [Int64]
    let displayList: [Int64]

    init(
        commandType: ListenTogetherPlaylistCommandType,
        userID: Int64,
        version: Int64,
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
        self.anchorSongID = anchorSongID
        self.anchorPosition = anchorPosition
        self.randomList = randomList
        self.displayList = displayList
    }
}
