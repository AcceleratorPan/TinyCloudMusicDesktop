import Observation
import SwiftUI

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
    @ObservationIgnored private var requestedIDs: Set<Int64> = []
    @ObservationIgnored private var accountID: Int64?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var requestTask: Task<Void, Never>?
    @ObservationIgnored private var trashTask: Task<Void, Never>?
    @ObservationIgnored private var monitorTask: Task<Void, Never>?
    @ObservationIgnored private var pendingSkipSongID: Int64?

    init(library: LiveMusicLibrary, player: PlayerController) {
        self.library = library
        self.player = player
    }

    isolated deinit {
        requestTask?.cancel()
        trashTask?.cancel()
        monitorTask?.cancel()
    }

    var currentTrack: PersonalFMTrack? {
        guard let songID = player.currentSongID else { return tracks.first }
        return tracks.first { $0.id == songID }
    }

    func start(userID: Int64) {
        guard userID > 0 else { return }
        startMonitoring()
        let isNewAccount = accountID != userID
        accountID = userID
        if isNewAccount || tracks.isEmpty || !tracks.contains(where: { $0.id == player.currentSongID }) {
            reload()
        }
    }

    func selectMode(_ mode: PersonalFMMode) {
        guard self.mode != mode else { return }
        self.mode = mode
        reload()
    }

    func retryLoading() {
        guard !isLoading else { return }
        loadBatch(startPlayback: tracks.isEmpty)
    }

    func trashCurrent() {
        guard !isTrashing, let track = currentTrack, player.currentSongID == track.id else { return }
        let playedSeconds = player.position.isFinite ? max(1, Int(player.position)) : 25
        isTrashing = true
        errorMessage = nil
        canRetryLoading = false
        trashTask = Task { @MainActor [weak self, library, player] in
            do {
                try await library.trashPersonalFMTrack(track, playedSeconds: playedSeconds)
                try Task.checkCancellation()
                guard let self else { return }
                if player.currentSongID == track.id, player.canGoNext {
                    player.next()
                    player.removeFromQueue(track.id)
                    self.tracks.removeAll { $0.id == track.id }
                    self.isTrashing = false
                } else if player.currentSongID == track.id {
                    self.pendingSkipSongID = track.id
                    if !self.isLoading { self.loadBatch(startPlayback: false) }
                } else {
                    player.removeFromQueue(track.id)
                    self.tracks.removeAll { $0.id == track.id }
                    self.isTrashing = false
                }
                self.trashTask = nil
                self.loadMoreIfNeeded()
            } catch is CancellationError {
            } catch {
                self?.errorMessage = error.localizedDescription
                self?.canRetryLoading = false
                self?.isTrashing = false
                self?.trashTask = nil
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

    private func reload() {
        generation += 1
        requestTask?.cancel()
        trashTask?.cancel()
        trashTask = nil
        pendingSkipSongID = nil
        isTrashing = false
        isLoading = false
        tracks = []
        requestedIDs = []
        errorMessage = nil
        canRetryLoading = false
        loadBatch(startPlayback: true)
    }

    private func loadBatch(startPlayback: Bool) {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        canRetryLoading = false
        let requestGeneration = generation
        let requestMode = mode

        requestTask = Task { @MainActor [weak self, library, player] in
            do {
                var additions: [PersonalFMTrack] = []
                for _ in 0..<2 {
                    let batch = try await library.personalFM(mode: requestMode)
                    try Task.checkCancellation()
                    guard let self,
                          Self.acceptsResponse(
                              requestGeneration: requestGeneration,
                              currentGeneration: self.generation,
                              requestMode: requestMode,
                              currentMode: self.mode,
                              isCancelled: Task.isCancelled
                          )
                    else { return }
                    additions = Self.newTracks(from: batch, requestedIDs: &self.requestedIDs)
                    if !additions.isEmpty { break }
                }

                guard let self,
                      Self.acceptsResponse(
                          requestGeneration: requestGeneration,
                          currentGeneration: self.generation,
                          requestMode: requestMode,
                          currentMode: self.mode,
                          isCancelled: Task.isCancelled
                      )
                else { return }
                guard !additions.isEmpty else {
                    self.errorMessage = "暂无更多推荐"
                    self.canRetryLoading = true
                    self.finishLoading(generation: requestGeneration)
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
                    player.play(first.song, in: self.tracks.map(\.song))
                    player.useLinearQueueMode()
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
                self.finishLoading(generation: requestGeneration)
            } catch is CancellationError {
            } catch {
                guard let self,
                      Self.acceptsResponse(
                          requestGeneration: requestGeneration,
                          currentGeneration: self.generation,
                          requestMode: requestMode,
                          currentMode: self.mode,
                          isCancelled: Task.isCancelled
                      )
                else { return }
                self.errorMessage = error.localizedDescription
                self.canRetryLoading = true
                self.finishLoading(generation: requestGeneration)
            }
        }
    }

    private func finishLoading(generation: Int) {
        guard self.generation == generation else { return }
        isLoading = false
        requestTask = nil
    }

    private func startMonitoring() {
        guard monitorTask == nil else { return }
        // ponytail: one-second polling keeps FM alive off-screen; replace with a player callback only if profiling warrants it.
        monitorTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                self?.loadMoreIfNeeded()
            }
        }
    }

    private func loadMoreIfNeeded() {
        guard !isLoading,
              errorMessage == nil,
              let index = player.currentIndex,
              player.queue.indices.contains(index),
              tracks.contains(where: { $0.id == player.currentSongID }),
              player.queue.count - index - 1 <= 1
        else { return }
        loadBatch(startPlayback: false)
    }
}

struct PersonalFMView: View {
    @Bindable var controller: PersonalFMController
    let userID: Int64

    var body: some View {
        Group {
            if controller.isLoading && controller.tracks.isEmpty {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("正在获取私人 FM…")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if controller.tracks.isEmpty {
                ContentUnavailableView {
                    Label(
                        controller.errorMessage == nil ? "暂无私人 FM 推荐" : "私人 FM 加载失败",
                        systemImage: controller.errorMessage == nil ? "radio" : "wifi.exclamationmark"
                    )
                } description: {
                    if let errorMessage = controller.errorMessage { Text(errorMessage) }
                } actions: {
                    Button("重试") { controller.retryLoading() }
                }
            } else if let track = controller.currentTrack {
                ScrollView {
                    VStack(spacing: 22) {
                        ArtworkView(artwork: track.song.album.artwork)
                            .frame(width: 240, height: 240)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .shadow(color: .black.opacity(0.16), radius: 18, y: 8)

                        VStack(spacing: 6) {
                            SongTitleText(song: track.song)
                                .font(.title2.weight(.semibold))
                                .lineLimit(2)
                                .multilineTextAlignment(.center)
                            Text(track.song.artistsDisplay)
                                .font(.body)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Text(track.song.album.name)
                                .font(.callout)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                        .frame(maxWidth: 520)

                        PlaybackControls(
                            player: controller.player,
                            showsQueueOptions: false,
                            isDislikePending: controller.isTrashing,
                            onDislike: { controller.trashCurrent() }
                        )
                            .frame(maxWidth: 520)

                        if let errorMessage = controller.errorMessage {
                            HStack(spacing: 10) {
                                Label(errorMessage, systemImage: "exclamationmark.triangle")
                                    .foregroundStyle(.red)
                                if controller.canRetryLoading {
                                    Button("重试加载") { controller.retryLoading() }
                                }
                            }
                            .font(.callout)
                        } else if controller.isLoading {
                            ProgressView()
                                .controlSize(.small)
                                .accessibilityLabel("正在加载下一批推荐")
                        }
                    }
                    .padding(28)
                    .frame(maxWidth: .infinity, minHeight: 500)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("私人 FM")
        .toolbar {
            ToolbarItem {
                modeMenu
            }
        }
        .task(id: userID) { controller.start(userID: userID) }
    }

    private var modeMenu: some View {
        Menu {
            modeButton(.standard)
            modeButton(.familiar)
            modeButton(.explore)
            Menu("场景推荐") {
                ForEach(PersonalFMScene.allCases, id: \.self) { scene in
                    modeButton(.scene(scene))
                }
            }
        } label: {
            Label(controller.mode.title, systemImage: "slider.horizontal.3")
        }
        .help("选择私人 FM 推荐模式")
        .accessibilityLabel("推荐模式：\(controller.mode.title)")
    }

    private func modeButton(_ mode: PersonalFMMode) -> some View {
        Button {
            controller.selectMode(mode)
        } label: {
            if controller.mode == mode {
                Label(mode.title, systemImage: "checkmark")
            } else {
                Text(mode.title)
            }
        }
    }

}
