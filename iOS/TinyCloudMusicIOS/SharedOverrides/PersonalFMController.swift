import Observation
import SwiftUI

struct PersonalFMRecentIDs: Sendable {
    let limit: Int
    private(set) var values: Set<Int64> = []
    private var order: [Int64] = []

    init(limit: Int) { self.limit = max(1, limit) }

    mutating func insert(_ id: Int64) -> Bool {
        guard values.insert(id).inserted else { return false }
        order.append(id)
        while order.count > limit {
            values.remove(order.removeFirst())
        }
        return true
    }

    mutating func removeAll() {
        values.removeAll(keepingCapacity: true)
        order.removeAll(keepingCapacity: true)
    }
}

enum PersonalFMRetention {
    static let consumedTrackLimit = 2
    static let recentIDLimit = 128

    static func staleConsumedSongIDs(
        queue: [PlaybackQueueItem],
        currentIndex: Int,
        consumedLimit: Int = consumedTrackLimit
    ) -> [Int64] {
        guard queue.indices.contains(currentIndex) else { return [] }
        return queue.prefix(max(0, currentIndex - max(0, consumedLimit))).map(\.id)
    }

    static func isActive(sessionID: UUID, queueIdentity: PlayerQueueIdentity?) -> Bool {
        queueIdentity?.sessionID == sessionID
    }
}

@MainActor
@Observable
final class PersonalFMController {
    private(set) var tracks: [PersonalFMTrack] = []
    private(set) var mode: PersonalFMMode = .standard
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    private(set) var isTrashing = false
    private(set) var canRetryLoading = false

    @ObservationIgnored private let library: LiveMusicLibrary
    @ObservationIgnored let player: PlayerController
    @ObservationIgnored private let onTrashSucceeded: () -> Void
    @ObservationIgnored private var requestedIDs = PersonalFMRecentIDs(limit: PersonalFMRetention.recentIDLimit)
    @ObservationIgnored private var accountID: Int64?
    @ObservationIgnored private var credentialRevision: UInt64?
    @ObservationIgnored private var sessionID: UUID?
    @ObservationIgnored private var sessionStartQueueIdentity: PlayerQueueIdentity?
    @ObservationIgnored private var hasInstalledQueue = false
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var requestTask: Task<Void, Never>?
    @ObservationIgnored private var requestTaskID: UUID?
    @ObservationIgnored private var trashTask: Task<Void, Never>?
    @ObservationIgnored private var trashTaskID: UUID?
    @ObservationIgnored private var playerObservationID: UUID?
    @ObservationIgnored private var pendingSkipSongID: Int64?

    init(library: LiveMusicLibrary, player: PlayerController, onTrashSucceeded: @escaping () -> Void) {
        self.library = library
        self.player = player
        self.onTrashSucceeded = onTrashSucceeded
    }

    isolated deinit {
        requestTask?.cancel()
        trashTask?.cancel()
    }

    var currentTrack: PersonalFMTrack? {
        guard let songID = player.currentSongID else { return tracks.first }
        return tracks.first { $0.id == songID }
    }

    func start(userID: Int64) {
        guard userID > 0, accountID == userID else { return }
        if let sessionID,
           hasInstalledQueue,
           PersonalFMRetention.isActive(sessionID: sessionID, queueIdentity: player.queueIdentity) {
            observePlayer(generation: generation, sessionID: sessionID)
            loadMoreIfNeeded()
        } else if requestTask == nil {
            beginSession()
        }
    }

    func setAccount(_ userID: Int64?) {
        let nextCredentialRevision = userID == nil
            ? nil
            : library.transport.credentialSnapshotValue().revision
        guard accountID != userID || credentialRevision != nextCredentialRevision else { return }
        let oldSessionID = sessionID
        generation += 1
        cancelTasks()
        if let oldSessionID,
           PersonalFMRetention.isActive(sessionID: oldSessionID, queueIdentity: player.queueIdentity) {
            removeUnplayedQueueItems()
        }
        accountID = userID
        credentialRevision = nextCredentialRevision
        sessionID = nil
        sessionStartQueueIdentity = nil
        hasInstalledQueue = false
        playerObservationID = nil
        tracks = []
        requestedIDs.removeAll()
        pendingSkipSongID = nil
        errorMessage = nil
        canRetryLoading = false
        isLoading = false
        isTrashing = false
    }

    func selectMode(_ mode: PersonalFMMode) {
        guard self.mode != mode else { return }
        self.mode = mode
        beginSession()
    }

    func retryLoading() {
        guard !isLoading else { return }
        if sessionID == nil {
            beginSession()
        } else {
            loadBatch(startPlayback: !hasInstalledQueue)
        }
    }

    func trashCurrent() {
        guard !isTrashing,
              let accountID,
              let credentialRevision,
              let sessionID,
              pendingSkipSongID == nil,
              hasInstalledQueue,
              PersonalFMRetention.isActive(sessionID: sessionID, queueIdentity: player.queueIdentity),
              let track = currentTrack,
              player.currentSongID == track.id
        else { return }
        let requestGeneration = generation
        let requestMode = mode
        let taskID = UUID()
        let playedSeconds = player.position.isFinite ? max(1, Int(player.position)) : 25
        isTrashing = true
        errorMessage = nil
        canRetryLoading = false
        trashTaskID = taskID
        trashTask = Task { @MainActor [weak self, library, player] in
            defer {
                if let self, self.trashTaskID == taskID {
                    self.trashTask = nil
                    self.trashTaskID = nil
                    if self.pendingSkipSongID != track.id { self.isTrashing = false }
                }
            }
            do {
                try await library.trashPersonalFMTrack(
                    track,
                    playedSeconds: playedSeconds,
                    expectedCredentialRevision: credentialRevision
                )
                try Task.checkCancellation()
                guard let self,
                      self.acceptsContext(
                          accountID: accountID,
                          credentialRevision: credentialRevision,
                          sessionID: sessionID,
                          generation: requestGeneration,
                          mode: requestMode
                      ),
                      self.trashTaskID == taskID
                else { return }
                if player.currentSongID == track.id, player.canGoNext {
                    player.next()
                    player.removeFromQueue(track.id)
                    self.tracks.removeAll { $0.id == track.id }
                } else if player.currentSongID == track.id {
                    self.pendingSkipSongID = track.id
                    if !self.isLoading { self.loadBatch(startPlayback: false) }
                } else {
                    player.removeFromQueue(track.id)
                    self.tracks.removeAll { $0.id == track.id }
                }
                self.onTrashSucceeded()
                self.loadMoreIfNeeded()
            } catch is CancellationError {
            } catch {
                guard let self,
                      self.trashTaskID == taskID,
                      self.acceptsContext(
                          accountID: accountID,
                          credentialRevision: credentialRevision,
                          sessionID: sessionID,
                          generation: requestGeneration,
                          mode: requestMode
                      )
                else { return }
                self.errorMessage = error.localizedDescription
                self.canRetryLoading = false
            }
        }
    }

    static func newTracks(from batch: [PersonalFMTrack], requestedIDs: inout Set<Int64>) -> [PersonalFMTrack] {
        batch.filter { requestedIDs.insert($0.id).inserted }
    }

    static func acceptsResponse(
        requestGeneration: Int,
        currentGeneration: Int,
        requestMode: PersonalFMMode,
        currentMode: PersonalFMMode,
        isCancelled: Bool
    ) -> Bool {
        !isCancelled && requestGeneration == currentGeneration && requestMode == currentMode
    }

    var retainedRequestIDCount: Int { requestedIDs.values.count }

    private func beginSession() {
        guard accountID != nil, credentialRevision != nil else { return }
        generation += 1
        cancelTasks()
        sessionID = UUID()
        sessionStartQueueIdentity = player.queueIdentity
        hasInstalledQueue = false
        playerObservationID = nil
        pendingSkipSongID = nil
        tracks = []
        requestedIDs.removeAll()
        errorMessage = nil
        canRetryLoading = false
        guard let sessionID else { return }
        observePlayer(generation: generation, sessionID: sessionID)
        loadBatch(startPlayback: true)
    }

    private func loadBatch(startPlayback: Bool) {
        guard !isLoading,
              let accountID,
              let credentialRevision,
              let sessionID
        else { return }
        isLoading = true
        errorMessage = nil
        canRetryLoading = false
        let requestGeneration = generation
        let requestMode = mode
        let taskID = UUID()
        requestTaskID = taskID

        requestTask = Task { @MainActor [weak self, library, player] in
            defer {
                if let self, self.requestTaskID == taskID {
                    self.requestTask = nil
                    self.requestTaskID = nil
                    self.isLoading = false
                }
            }
            do {
                var additions: [PersonalFMTrack] = []
                for _ in 0..<2 {
                    let batch = try await library.personalFM(
                        mode: requestMode,
                        expectedCredentialRevision: credentialRevision
                    )
                    try Task.checkCancellation()
                    guard let self,
                          self.requestTaskID == taskID,
                          self.acceptsContext(
                              accountID: accountID,
                              credentialRevision: credentialRevision,
                              sessionID: sessionID,
                              generation: requestGeneration,
                              mode: requestMode
                          )
                    else { return }
                    additions = self.newTracks(from: batch)
                    if !additions.isEmpty { break }
                }

                guard let self,
                      self.requestTaskID == taskID,
                      self.acceptsContext(
                          accountID: accountID,
                          credentialRevision: credentialRevision,
                          sessionID: sessionID,
                          generation: requestGeneration,
                          mode: requestMode
                      )
                else { return }
                guard !additions.isEmpty else {
                    self.errorMessage = "暂无更多推荐"
                    self.canRetryLoading = true
                    return
                }

                let shouldContinue = !startPlayback
                    && player.currentIndex == player.queue.count - 1
                    && (player.state == .idle || {
                        if case .failed = player.state { return true }
                        return false
                    }())
                self.tracks.append(contentsOf: additions)
                if startPlayback, let first = self.tracks.first {
                    player.play(
                        first.song,
                        in: self.tracks.map(\.song),
                        queueSessionID: sessionID
                    )
                    player.useLinearQueueMode()
                    self.hasInstalledQueue = PersonalFMRetention.isActive(
                        sessionID: sessionID,
                        queueIdentity: player.queueIdentity
                    )
                } else {
                    player.appendToQueue(additions.map(\.song))
                    if let skippedID = self.pendingSkipSongID, skippedID == player.currentSongID {
                        player.next()
                        player.removeFromQueue(skippedID)
                        self.tracks.removeAll { $0.id == skippedID }
                        self.pendingSkipSongID = nil
                        self.isTrashing = false
                    } else if shouldContinue {
                        player.next()
                    }
                }
            } catch is CancellationError {
            } catch {
                guard let self,
                      self.requestTaskID == taskID,
                      self.acceptsContext(
                          accountID: accountID,
                          credentialRevision: credentialRevision,
                          sessionID: sessionID,
                          generation: requestGeneration,
                          mode: requestMode
                      )
                else { return }
                self.errorMessage = error.localizedDescription
                self.canRetryLoading = true
            }
        }
    }

    private func newTracks(from batch: [PersonalFMTrack]) -> [PersonalFMTrack] {
        var activeIDs = Set(tracks.map(\.id))
        return batch.filter { track in
            guard activeIDs.insert(track.id).inserted else { return false }
            return requestedIDs.insert(track.id)
        }
    }

    private func observePlayer(generation: Int, sessionID: UUID) {
        guard playerObservationID == nil,
              self.generation == generation,
              self.sessionID == sessionID
        else { return }
        let observationID = UUID()
        playerObservationID = observationID
        withObservationTracking {
            _ = player.queueIdentity
            _ = player.currentIndex
            _ = player.queue.count
            _ = player.currentSongID
            _ = player.state
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.playerDidChange(
                    observationID: observationID,
                    generation: generation,
                    sessionID: sessionID
                )
            }
        }
    }

    private func playerDidChange(observationID: UUID, generation: Int, sessionID: UUID) {
        guard playerObservationID == observationID,
              self.generation == generation,
              self.sessionID == sessionID
        else { return }
        playerObservationID = nil
        observePlayer(generation: generation, sessionID: sessionID)

        if !hasInstalledQueue {
            if PersonalFMRetention.isActive(sessionID: sessionID, queueIdentity: player.queueIdentity) {
                hasInstalledQueue = true
            } else if player.queueIdentity != sessionStartQueueIdentity {
                endSession()
            } else {
                return
            }
        } else if !PersonalFMRetention.isActive(sessionID: sessionID, queueIdentity: player.queueIdentity) {
            endSession()
            return
        }

        pruneConsumedTracks()
        loadMoreIfNeeded()
    }

    private func loadMoreIfNeeded() {
        guard !isLoading,
              errorMessage == nil,
              let sessionID,
              hasInstalledQueue,
              PersonalFMRetention.isActive(sessionID: sessionID, queueIdentity: player.queueIdentity),
              let index = player.currentIndex,
              player.queue.indices.contains(index),
              player.queue.count - index - 1 <= 1
        else { return }
        loadBatch(startPlayback: false)
    }

    private func pruneConsumedTracks() {
        guard let index = player.currentIndex else { return }
        let staleIDs = PersonalFMRetention.staleConsumedSongIDs(
            queue: player.queue,
            currentIndex: index
        )
        guard !staleIDs.isEmpty else { return }
        for id in staleIDs where player.removeFromQueue(id) {
            tracks.removeAll { $0.id == id }
        }
    }

    private func removeUnplayedQueueItems() {
        guard let currentIndex = player.currentIndex else { return }
        let ids = player.queue.indices.filter { $0 != currentIndex }.map { player.queue[$0].id }
        for id in ids { _ = player.removeFromQueue(id) }
    }

    private func acceptsContext(
        accountID: Int64,
        credentialRevision: UInt64,
        sessionID: UUID,
        generation: Int,
        mode: PersonalFMMode
    ) -> Bool {
        !Task.isCancelled
            && self.accountID == accountID
            && self.credentialRevision == credentialRevision
            && library.transport.credentialSnapshotValue().revision == credentialRevision
            && self.sessionID == sessionID
            && self.generation == generation
            && self.mode == mode
            && (hasInstalledQueue
                ? PersonalFMRetention.isActive(sessionID: sessionID, queueIdentity: player.queueIdentity)
                : player.queueIdentity == sessionStartQueueIdentity)
    }

    private func cancelTasks() {
        requestTask?.cancel()
        requestTask = nil
        requestTaskID = nil
        trashTask?.cancel()
        trashTask = nil
        trashTaskID = nil
        isLoading = false
        isTrashing = false
    }

    private func endSession() {
        generation += 1
        cancelTasks()
        playerObservationID = nil
        sessionID = nil
        sessionStartQueueIdentity = nil
        hasInstalledQueue = false
        tracks = []
        requestedIDs.removeAll()
        pendingSkipSongID = nil
    }
}
