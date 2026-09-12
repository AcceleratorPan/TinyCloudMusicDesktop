import Foundation
import Observation
import OSLog

#if canImport(Testing)
import Testing
@testable import TinyCloudMusic

@Suite("Download persistence and transfer", .serialized)
struct DownloadTransferPerformanceTests {
    @Test("Resume commands stay ordered and flush reports persistence errors")
    @MainActor
    func orderedResumeCommandsAndErrors() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MusicDownloadResumeStore(directory: root.appending(path: "resume"))
        let first = musicRequest(id: 1, destination: root)
        let second = musicRequest(id: 2, destination: root)

        store.save(first)
        store.remove(songID: first.songID)
        store.save(second, resumeData: Data([2]))
        try await store.flush()
        let recovered = await store.recoverableDownloadsAsync()
        #expect(recovered.downloads.map(\.request.songID) == [2])
        #expect(recovered.downloads.first?.resumeData == Data([2]))

        try Data("not a directory".utf8).write(to: root.appending(path: "blocked"))
        let failing = MusicDownloadResumeStore(directory: root.appending(path: "blocked"))
        #expect((await failing.recoverableDownloadsAsync()).failureDescription != nil)
        failing.save(first)
        failing.remove(songID: first.songID)
        failing.save(second, resumeData: Data([3]))
        for _ in 0..<2 {
            do {
                try await failing.flush()
                Issue.record("flush should keep surfacing the undurable write")
            } catch {
                #expect(!error.localizedDescription.isEmpty)
            }
        }
        try FileManager.default.removeItem(at: root.appending(path: "blocked"))
        try await failing.flush()
        let recoveredAfterRepair = await MusicDownloadResumeStore(
            directory: root.appending(path: "blocked")
        ).recoverableDownloadsAsync()
        #expect(recoveredAfterRepair.downloads.map(\.request.songID) == [second.songID])
        #expect(recoveredAfterRepair.downloads.first?.resumeData == Data([3]))

        let delayed = MusicDownloadResumeStore(directory: root.appending(path: "delayed"))
        delayed.save((10_000..<11_000).map {
            MusicDownloadResumeEntry(request: musicRequest(id: Int64($0), destination: root), resumeData: nil)
        })
        do {
            try await delayed.flush(timeout: .zero)
            Issue.record("zero-duration flush should time out behind the queued batch")
        } catch {
            #expect(error as? MusicDownloadPersistenceError == .flushTimedOut)
        }
        try await delayed.flush()

        try Data("broken".utf8).write(to: root.appending(path: "resume/broken.resume.plist"))
        let isolated = await store.recoverableDownloadsAsync()
        #expect(isolated.downloads.map(\.request.songID) == [2])
        #expect(isolated.failureDescription?.contains("broken.resume.plist") == true)

        try Data("broken again".utf8).write(to: root.appending(path: "resume/broken.resume.plist"))
        let network = blockedNetwork()
        defer { network.session.invalidateAndCancel() }
        let manager = MusicDownloadManager(
            transport: network.transport,
            session: network.session,
            maximumConcurrentDownloads: 1,
            resumeStore: store,
            targetAllocator: MusicDownloadTargetAllocator()
        )
        for _ in 0..<200 where manager.persistenceError == nil {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(manager.persistenceError?.contains("broken.resume.plist") == true)
        await manager.pauseAll()
    }

    @MainActor
    @Test("One thousand songs enqueue as one observable order mutation and recover durably")
    func batchEnqueueAndRecovery() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let network = blockedNetwork()
        defer { network.session.invalidateAndCancel() }
        let store = MusicDownloadResumeStore(directory: root.appending(path: "resume"))
        let manager = MusicDownloadManager(
            transport: network.transport,
            session: network.session,
            maximumConcurrentDownloads: 1,
            resumeStore: store,
            targetAllocator: MusicDownloadTargetAllocator()
        )
        let changes = LockedCounter()
        withObservationTracking {
            _ = manager.itemOrder
        } onChange: {
            changes.increment()
        }
        let songs = (1...1_000).map(song)

        #expect(manager.enqueue(songs: songs, to: root, quality: .standard, includeLyrics: false) == 1_000)
        #expect(manager.itemOrder == songs.map(\.id))
        #expect(changes.value == 1)

        await manager.pauseAll()
        let recovered = await store.recoverableDownloadsAsync()
        #expect(recovered.downloads.count == 1_000)
        #expect(recovered.downloads.map(\.request.songID) == songs.map(\.id))
        #expect(manager.persistenceError == nil)

        let videos = (1...2).map { index in
            let request = videoRequest(id: Int64(index), destination: root)
            return MusicDownloadVideoResumeEntry(
                request: request,
                resumeData: Data([UInt8(index)]),
                resolution: 720,
                sourceURL: URL(string: "https://vod.126.net/recovery-\(index).mp4")!,
                sourceExpiresAt: Date().addingTimeInterval(3_600)
            )
        }
        store.save(audio: [], videos: videos)
        try await store.flush()

        let restarted = MusicDownloadManager(
            transport: network.transport,
            session: network.session,
            maximumConcurrentDownloads: 1,
            resumeStore: store,
            targetAllocator: MusicDownloadTargetAllocator()
        )
        let recoveryChanges = LockedCounter()
        withObservationTracking {
            _ = restarted.itemOrder
        } onChange: {
            recoveryChanges.increment()
        }
        let videoRecoveryChanges = LockedCounter()
        withObservationTracking {
            _ = restarted.videoItemOrder
        } onChange: {
            videoRecoveryChanges.increment()
        }
        for _ in 0..<500 where restarted.itemOrder.count != 1_000
            || restarted.videoItemOrder.count != videos.count {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(restarted.itemOrder == songs.map(\.id))
        #expect(restarted.videoItemOrder == videos.map(\.request.resource.identity))
        #expect(recoveryChanges.value == 1)
        #expect(videoRecoveryChanges.value == 1)
        await restarted.pauseAll()
    }

    @Test("iOS download body computes each order once")
    func iosDownloadBodyOrderSourceBoundary() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appending(
                path: "iOS/TinyCloudMusicIOS/UI/LibraryMedia/IOSLibraryView.swift"
            ),
            encoding: .utf8
        )
        let viewStart = try #require(source.range(of: "struct IOSDownloadsView: View")?.lowerBound)
        let viewEnd = try #require(
            source.range(of: "private struct IOSDownloadRow", range: viewStart..<source.endIndex)?.lowerBound
        )
        let view = String(source[viewStart..<viewEnd])
        let bodyStart = try #require(view.range(of: "var body: some View")?.lowerBound)
        let gettersStart = try #require(
            view.range(of: "private var orderedSongIDs", range: bodyStart..<view.endIndex)?.lowerBound
        )
        let body = String(view[bodyStart..<gettersStart])

        #expect(body.contains("let songIDs = orderedSongIDs"))
        #expect(body.contains("let videoIDs = orderedVideoIDs"))
        #expect(body.components(separatedBy: "orderedSongIDs").count == 2)
        #expect(body.components(separatedBy: "orderedVideoIDs").count == 2)
        #expect(body.contains("if !songIDs.isEmpty"))
        #expect(body.contains("ForEach(songIDs, id: \\.self)"))
        #expect(body.contains("if !videoIDs.isEmpty"))
        #expect(body.contains("ForEach(videoIDs, id: \\.self)"))
        #expect(body.components(separatedBy: "songIDs").count == 4)
        #expect(body.components(separatedBy: "videoIDs").count == 4)
    }

    @MainActor
    @Test("Pause all reports a failed durable barrier")
    func pauseAllReportsPersistenceFailure() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let blockedStorePath = root.appending(path: "resume")
        try Data([1]).write(to: blockedStorePath)
        let network = blockedNetwork()
        defer { network.session.invalidateAndCancel() }
        let manager = MusicDownloadManager(
            transport: network.transport,
            session: network.session,
            maximumConcurrentDownloads: 1,
            resumeStore: MusicDownloadResumeStore(directory: blockedStorePath),
            targetAllocator: MusicDownloadTargetAllocator()
        )
        #expect(manager.enqueue(songs: [song(1)], to: root, quality: .standard, includeLyrics: false) == 1)
        await manager.pauseAll()
        #expect(manager.persistenceError != nil)
    }

    @Test("Ten thousand callbacks are coalesced and completion emits one")
    func progressCoalescing() {
        let values = LockedValues<Double>()
        let reporter = MusicDownloadProgressReporter { values.append($0) }
        for value in 1...10_000 {
            reporter.update(
                totalBytesWritten: Int64(value),
                totalBytesExpectedToWrite: 10_001,
                responseExpectedContentLength: 10_001
            )
        }
        reporter.finish()

        #expect(values.values.count < 100)
        #expect(values.values.last == 1)
    }

    @MainActor
    @Test("Five hundred terminal downloads keep stable order during ten progress ticks")
    func terminalDownloadHistoryProgressWorkload() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DownloadWorkloadProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        DownloadWorkloadProtocol.reset()
        let workload = DownloadProgressWorkloadGate()
        let manager = MusicDownloadManager(
            transport: EAPITransport(session: session, cookie: "", musicU: ""),
            session: session,
            maximumConcurrentDownloads: 5,
            resumeStore: MusicDownloadResumeStore(directory: root.appending(path: "resume")),
            targetAllocator: MusicDownloadTargetAllocator(),
            videoTransfer: { request, _, progress in
                await workload.waitForProgressRelease()
                try Task.checkCancellation()
                for tick in 1...10 {
                    progress(Int64(tick), 10, 10)
                    if tick < 10 { try await Task.sleep(for: .milliseconds(100)) }
                }
                await workload.holdAfterProgress()
                try Task.checkCancellation()
                return try mp4Result(for: request)
            }
        )
        let songs = (1...500).map(song)
        let songIDs = songs.map(\.id)
        #expect(manager.enqueue(
            songs: songs,
            to: root.appending(path: "songs"),
            quality: .standard,
            includeLyrics: false
        ) == 500)
        for _ in 0..<500 {
            if manager.runningDownloadCount == 5 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(manager.runningDownloadCount == 5)

        let terminalVideos = (1...500).map {
            VideoPageResource.mv(Int64(10_000 + $0))
        }
        let acceptedVideos = terminalVideos.reduce(into: 0) { count, resource in
            if manager.enqueue(
                video: resource,
                title: resource.identity,
                creator: "Fixture",
                availableResolutions: [720],
                to: root.appending(path: "videos"),
                quality: .high
            ) {
                count += 1
            }
        }
        #expect(acceptedVideos == 500)
        let terminalVideoIDs = terminalVideos.map(\.identity)
        terminalVideoIDs.forEach { manager.cancelVideo(id: $0) }
        songIDs.forEach { manager.cancel(songID: $0) }
        for _ in 0..<500 {
            if manager.runningDownloadCount == 0 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(manager.runningDownloadCount == 0)
        #expect(manager.itemOrder == songIDs)
        #expect(manager.videoItemOrder == terminalVideoIDs)
        #expect(songIDs.allSatisfy { manager.states[$0] == .cancelled })
        #expect(terminalVideoIDs.allSatisfy { manager.videoStates[$0] == .cancelled })

        let activeVideos = (1...5).map { VideoPageResource.mv(Int64(20_000 + $0)) }
        for resource in activeVideos {
            #expect(manager.enqueue(
                video: resource,
                title: resource.identity,
                creator: "Fixture",
                availableResolutions: [720],
                to: root.appending(path: "active-videos"),
                quality: .high
            ))
        }
        let activeVideoIDs = activeVideos.map(\.identity)
        for _ in 0..<500 {
            if await workload.progressReadyCount == 5 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await workload.progressReadyCount == 5)
        #expect(DownloadWorkloadProtocol.playbackRequestCount == 5)
        let stableSongOrder = manager.itemOrder
        let stableVideoOrder = manager.videoItemOrder
        #expect(stableSongOrder == songIDs)
        #expect(stableVideoOrder == terminalVideoIDs + activeVideoIDs)

        let songStateChanges = LockedCounter()
        let songOrderChanges = LockedCounter()
        let videoStateChanges = LockedCounter()
        let videoOrderChanges = LockedCounter()
        withObservationTracking {
            _ = manager.states
        } onChange: {
            songStateChanges.increment()
        }
        withObservationTracking {
            _ = manager.itemOrder
        } onChange: {
            songOrderChanges.increment()
        }
        withObservationTracking {
            _ = manager.videoStates
        } onChange: {
            videoStateChanges.increment()
        }
        withObservationTracking {
            _ = manager.videoItemOrder
        } onChange: {
            videoOrderChanges.increment()
        }

        let mergeFixture = DownloadMeasurementSignposts.interval("PERF-B07.ManagerMerge.500x10") {
            var throttles = Array(
                repeating: MusicDownloadProgressThrottle(minimumInterval: 0.1),
                count: songIDs.count
            )
            var states: [Int64: MusicDownloadState] = Dictionary(
                uniqueKeysWithValues: songIDs.map { ($0, .running(progress: nil)) }
            )
            var acceptedUpdates = 0
            var mergeCopies = 0
            for tick in 1...10 {
                var updates: [Int64: Double] = [:]
                updates.reserveCapacity(songIDs.count)
                for index in songIDs.indices {
                    if let value = throttles[index].update(
                        totalBytesWritten: Int64(tick),
                        totalBytesExpectedToWrite: 10,
                        now: Double(tick)
                    ) {
                        updates[songIDs[index]] = value
                    }
                }
                acceptedUpdates += updates.count
                states = MusicDownloadManager.mergingProgress(updates, into: states)
                mergeCopies += 1
            }
            return (states, acceptedUpdates, mergeCopies)
        }
        #expect(mergeFixture.1 == 5_000)
        #expect(mergeFixture.2 == 10)
        #expect(songIDs.allSatisfy { mergeFixture.0[$0] == .running(progress: 1) })

        try await DownloadMeasurementSignposts.asyncInterval("PERF-B07.ManagerVideoProgress.5x10") {
            await workload.releaseProgress()
            for _ in 0..<500 {
                if await workload.completedProgressCount == 5 { break }
                try await Task.sleep(for: .milliseconds(5))
            }
        }
        #expect(await workload.completedProgressCount == 5)
        for _ in 0..<500 {
            if activeVideoIDs.allSatisfy({ manager.videoStates[$0] == .running(progress: 1) }) {
                break
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(activeVideoIDs.allSatisfy { manager.videoStates[$0] == .running(progress: 1) })
        #expect(manager.itemOrder == stableSongOrder)
        #expect(manager.videoItemOrder == stableVideoOrder)
        #expect(songStateChanges.value == 0)
        #expect(songOrderChanges.value == 0)
        #expect(videoStateChanges.value == 1)
        #expect(videoOrderChanges.value == 0)

        manager.cancelAll()
        await workload.releaseAll()
        for _ in 0..<500 {
            if manager.runningDownloadCount == 0 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        await manager.pauseAll()
    }

    @Test("Managed identity never guesses by title, size, or legacy filename")
    func managedIdentityIsExact() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let first = musicRequest(id: 10, destination: root)
        let other = musicRequest(id: 11, destination: root)
        let allocator = MusicDownloadTargetAllocator()
        let stem = MusicDownloadFiles.downloadStem(for: first, level: "lossless")
        let reserved = await allocator.reserve(in: root, stem: stem, audioExtension: "flac")
        try Data("fLaC".utf8).write(to: reserved.audioFinal)
        let target = await allocator.reserve(in: root, stem: stem, audioExtension: "flac")
        try Data("fLaC".utf8).write(to: target.audioFinal)
        try MusicDownloadFiles.writeManagedIdentity(for: first, audioURL: target.audioFinal)

        #expect(MusicDownloadFiles.managedDownload(for: first)?.audioURL == target.audioFinal)
        #expect(MusicDownloadFiles.managedDownload(for: other) == nil)
        try MusicDownloadFiles.writeManagedIdentity(for: musicRequest(
            id: first.songID,
            destination: root,
            quality: .standard
        ), audioURL: target.audioFinal)
        #expect(MusicDownloadFiles.managedDownload(for: first) == nil)
        try MusicDownloadFiles.writeManagedIdentity(for: musicRequest(
            id: first.songID,
            destination: root,
            source: .cloud(userID: 1, fileName: "same.flac")
        ), audioURL: target.audioFinal)
        #expect(MusicDownloadFiles.managedDownload(for: first) == nil)
        try MusicDownloadFiles.writeManagedIdentity(for: first, audioURL: target.audioFinal)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path)
            .allSatisfy { !$0.hasPrefix(".TinyCloudMusic.") })

        let handle = try FileHandle(forWritingTo: target.audioFinal)
        _ = try handle.seekToEnd()
        try handle.write(contentsOf: Data([0]))
        try handle.close()
        #expect(MusicDownloadFiles.managedDownload(for: first) == nil)

        let legacy = root.appending(path: "legacy.flac")
        try Data("fLaC".utf8).write(to: legacy)
        #expect(MusicDownloadFiles.managedDownload(for: musicRequest(id: 12, destination: root)) == nil)
        #expect(reserved.audioFinal != target.audioFinal)
        await allocator.release(reserved)
        await allocator.release(target)
    }

    @Test("Video reservations and fallback classification are exact")
    func videoReservationAndFallback() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let allocator = MusicDownloadTargetAllocator()
        let first = await allocator.reserve(in: root, stem: "video", audioExtension: "mp4")
        let second = await allocator.reserve(in: root, stem: "video", audioExtension: "mp4")
        #expect(first.audioFinal != second.audioFinal)
        await allocator.release(first)
        await allocator.release(second)

        let transfer: VideoFileDownload.Transfer = { request, _, _ in
            try mp4Result(
                for: request,
                suffix: request.url?.lastPathComponent == "concurrent-a.mp4" ? 1 : 2
            )
        }
        async let firstDownload = VideoFileDownload.download(
            URL(string: "https://vod.126.net/concurrent-a.mp4")!,
            title: "same",
            resolution: 720,
            to: root,
            targetAllocator: allocator,
            transferDownload: transfer
        ) { _ in }
        async let secondDownload = VideoFileDownload.download(
            URL(string: "https://vod.126.net/concurrent-b.mp4")!,
            title: "same",
            resolution: 720,
            to: root,
            targetAllocator: allocator,
            transferDownload: transfer
        ) { _ in }
        let targets = try await [firstDownload, secondDownload]
        #expect(Set(targets).count == 2)
        #expect(Set(try targets.compactMap { try Data(contentsOf: $0).last }) == Set([UInt8(1), 2]))
        #expect(try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil
        ).allSatisfy { $0.pathExtension != "part" })

        #expect(MusicDownloadManager.shouldFallbackVideo(
            after: VideoLibraryError.unavailable("该视频暂无可用播放地址")
        ))
        #expect(MusicDownloadManager.shouldFallbackVideo(
            after: VideoLibraryError.unavailable("该视频需要登录或开通权益后播放")
        ))
        #expect(MusicDownloadManager.shouldFallbackVideo(
            after: MusicDownloadHTTPError(statusCode: 404, retryAfter: nil)
        ))
        #expect(!MusicDownloadManager.shouldFallbackVideo(after: EAPIError.http(401)))
        #expect(!MusicDownloadManager.shouldFallbackVideo(after: EAPIError.invalidResponse))
        #expect(!MusicDownloadManager.shouldFallbackVideo(after: CocoaError(.fileWriteNoPermission)))
        #expect(!MusicDownloadManager.shouldFallbackVideo(after: CancellationError()))
        #expect(!MusicDownloadManager.shouldFallbackVideo(
            after: VideoLibraryError.unavailable("视频下载响应无效")
        ))
    }

    @MainActor
    @Test("Cache clear is generation fenced and leaves user files and Sheets")
    func cacheGenerationAndClear() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let downloadCache = root.appending(path: "DownloadCache")
        let lyrics = downloadCache.appending(path: "Lyrics")
        let videos = downloadCache.appending(path: "Videos")
        let sheets = downloadCache.appending(path: "Sheets")
        for directory in [lyrics, videos, sheets] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data([1]).write(to: directory.appending(path: "value"))
        }
        let userFile = root.appending(path: "download.flac")
        try Data("fLaC".utf8).write(to: userFile)

        let manager = MusicDownloadManager(
            resumeStore: MusicDownloadResumeStore(directory: root.appending(path: "clear-resume")),
            targetAllocator: MusicDownloadTargetAllocator(),
            cacheRoot: root
        )
        try await manager.clearCache()
        #expect(!FileManager.default.fileExists(atPath: lyrics.path))
        #expect(!FileManager.default.fileExists(atPath: videos.path))
        #expect(FileManager.default.fileExists(atPath: sheets.path))
        #expect(FileManager.default.fileExists(atPath: userFile.path))

        let generation = MusicDownloadCacheGeneration(root: root)
        let old = generation.context()
        let clearing = generation.beginClear()
        #expect(generation.withCurrent(old) { true } == nil)
        generation.endClear(clearing)
        #expect(!generation.isCurrent(old))

        let oldRoot = root.appending(path: "old-cache")
        let newRoot = root.appending(path: "new-cache")
        let destination = root.appending(path: "user-downloads")
        let video = videoRequest(id: 99, destination: destination)
        let store = MusicDownloadResumeStore(directory: root.appending(path: "root-switch-resume"))
        store.save(MusicDownloadVideoResumeEntry(
            request: video,
            resumeData: nil,
            resolution: 720,
            sourceURL: URL(string: "https://vod.126.net/root-switch.mp4")!,
            sourceExpiresAt: Date().addingTimeInterval(3_600)
        ))
        try await store.flush()
        let started = LockedCounter()
        let switching = MusicDownloadManager(
            maximumConcurrentDownloads: 1,
            resumeStore: store,
            targetAllocator: MusicDownloadTargetAllocator(),
            cacheRoot: oldRoot,
            videoTransfer: { request, _, _ in
                started.increment()
                try await Task.sleep(for: .milliseconds(50))
                return try mp4Result(for: request)
            }
        )
        for _ in 0..<200 where started.value == 0 {
            try await Task.sleep(for: .milliseconds(5))
        }
        try await switching.clearCache()
        switching.configure(cacheRoot: newRoot)
        try await waitForVideo(switching, id: video.resource.identity)
        guard case let .completed(url, nil)? = switching.videoStates[video.resource.identity] else {
            Issue.record("root switch download did not complete")
            return
        }
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(!FileManager.default.fileExists(
            atPath: oldRoot.appending(path: "DownloadCache/Videos").path
        ))
    }

    @Test("Controlled cache inventory aggregates size age activity and video pairs")
    func controlledCacheAggregateInventory() throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "TinyCloudMusicTests.\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = root.appending(path: "DownloadCache", directoryHint: .isDirectory)
        let videos = cache.appending(path: "Videos/identity", directoryHint: .isDirectory)
        let lyrics = cache.appending(path: "Lyrics/catalog", directoryHint: .isDirectory)
        let sheets = cache.appending(path: "Sheets/archive", directoryHint: .isDirectory)
        let referenceDate = Date(timeIntervalSince1970: 2_000_000_000)
        let recent = referenceDate.addingTimeInterval(-3_600)
        let middle = referenceDate.addingTimeInterval(-3 * 24 * 60 * 60)
        let old = referenceDate.addingTimeInterval(-30 * 24 * 60 * 60)

        let pairedVideo = videos.appending(path: "720.mp4")
        let pairedSize = pairedVideo.appendingPathExtension("size")
        let orphanedVideo = videos.appending(path: "1080.mp4")
        let activeLyric = lyrics.appending(path: "active.lrc")
        try writeControlledCacheFile(pairedVideo, bytes: 64, modifiedAt: recent)
        try writeControlledCacheFile(pairedSize, bytes: 2, modifiedAt: recent)
        try Data("64".utf8).write(to: pairedSize)
        try FileManager.default.setAttributes([.modificationDate: recent], ofItemAtPath: pairedSize.path)
        try writeControlledCacheFile(orphanedVideo, bytes: 32, modifiedAt: middle)
        try writeControlledCacheFile(activeLyric, bytes: 7, modifiedAt: recent)
        try writeControlledCacheFile(lyrics.appending(path: "old.lrc"), bytes: 13, modifiedAt: old)
        try writeControlledCacheFile(sheets.appending(path: "middle.pdf"), bytes: 17, modifiedAt: middle)
        try writeControlledCacheFile(sheets.appending(path: "old.pdf"), bytes: 23, modifiedAt: old)

        let outside = root.appending(path: "OutsideCache", directoryHint: .isDirectory)
        try writeControlledCacheFile(
            outside.appending(path: "must-not-count.lrc"),
            bytes: 101,
            modifiedAt: old
        )
        try FileManager.default.createSymbolicLink(
            at: lyrics.appending(path: "outside-link", directoryHint: .isDirectory),
            withDestinationURL: outside
        )

        let readHandle = try FileHandle(forReadingFrom: activeLyric)
        defer { try? readHandle.close() }
        let writeHandle = try FileHandle(forWritingTo: pairedVideo)
        defer { try? writeHandle.close() }
        let activePaths = Set([activeLyric, pairedVideo].map { $0.standardizedFileURL.path })
        let inventory = try DownloadMeasurementSignposts.interval("PERF-A15.CacheInventory") {
            try controlledCacheInventory(
                at: cache,
                referenceDate: referenceDate,
                activePaths: activePaths
            )
        }

        #expect(inventory.roots["Videos"] == ControlledCacheAggregate(
            fileCount: 3,
            logicalBytes: 98,
            ageBuckets: [2, 1, 0],
            activeFileCount: 1
        ))
        #expect(inventory.roots["Lyrics"] == ControlledCacheAggregate(
            fileCount: 2,
            logicalBytes: 20,
            ageBuckets: [1, 0, 1],
            activeFileCount: 1
        ))
        #expect(inventory.roots["Sheets"] == ControlledCacheAggregate(
            fileCount: 2,
            logicalBytes: 40,
            ageBuckets: [0, 1, 1],
            activeFileCount: 0
        ))
        #expect(inventory.roots.values.reduce(0) { $0 + $1.fileCount } == 7)
        #expect(inventory.roots.values.reduce(0) { $0 + $1.logicalBytes } == 158)
        #expect(inventory.pairedVideoCount == 1)
        #expect(inventory.unpairedVideoCount == 1)
    }

    @MainActor
    @Test("Cache lookup cancellation and root mismatch release activity without committing")
    func cacheLookupIdentityAndActivity() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let network = blockedNetwork()
        defer { network.session.invalidateAndCancel() }

        let cancelledRoot = root.appending(path: "cancelled-root")
        let cancelledDestination = root.appending(path: "cancelled-download")
        let cancelledSong = song(601)
        let cancelledGate = CacheLookupGate()
        let cancelledCache = try await gatedCache(
            root: cancelledRoot,
            songID: cancelledSong.id,
            gate: cancelledGate
        )
        let cancelled = MusicDownloadManager(
            transport: network.transport,
            session: network.session,
            maximumConcurrentDownloads: 1,
            retryPolicy: MusicDownloadRetryPolicy(maximumAttempts: 1, baseDelay: 0, maximumDelay: 0),
            resumeStore: MusicDownloadResumeStore(directory: root.appending(path: "cancelled-resume")),
            targetAllocator: MusicDownloadTargetAllocator(),
            cacheRoot: cancelledRoot,
            audioCache: cancelledCache
        )
        #expect(cancelled.enqueue(
            song: cancelledSong,
            to: cancelledDestination,
            quality: .standard,
            includeLyrics: false
        ))
        try await waitForLookup(cancelledGate)
        cancelled.cancel(songID: cancelledSong.id)
        await cancelledGate.release()
        try await cancelled.clearCache()

        #expect(await cancelledGate.wasCancelled == true)
        #expect(cancelled.states[cancelledSong.id] == .cancelled)
        let cancelledFiles = try FileManager.default.contentsOfDirectory(
            at: cancelledDestination,
            includingPropertiesForKeys: nil
        )
        #expect(cancelledFiles.isEmpty)

        let oldRoot = root.appending(path: "old-root")
        let newRoot = root.appending(path: "new-root")
        let staleDestination = root.appending(path: "stale-download")
        let staleSong = song(602)
        let staleGate = CacheLookupGate()
        let staleCache = try await gatedCache(root: oldRoot, songID: staleSong.id, gate: staleGate)
        let stale = MusicDownloadManager(
            transport: network.transport,
            session: network.session,
            maximumConcurrentDownloads: 1,
            retryPolicy: MusicDownloadRetryPolicy(maximumAttempts: 1, baseDelay: 0, maximumDelay: 0),
            resumeStore: MusicDownloadResumeStore(directory: root.appending(path: "stale-resume")),
            targetAllocator: MusicDownloadTargetAllocator(),
            cacheRoot: oldRoot,
            audioCache: staleCache
        )
        #expect(stale.enqueue(
            song: staleSong,
            to: staleDestination,
            quality: .standard,
            includeLyrics: false
        ))
        try await waitForLookup(staleGate)
        stale.configure(cacheRoot: newRoot)
        await staleGate.release()
        try await stale.clearCache()

        #expect(await staleGate.wasCancelled == false)
        let staleFiles = try FileManager.default.contentsOfDirectory(
            at: staleDestination,
            includingPropertiesForKeys: nil
        )
        #expect(staleFiles.isEmpty)
        stale.cancel(songID: staleSong.id)
    }

    @MainActor
    @Test("Partial cache quota never replaces an accepted full audio download")
    func partialQuotaPreservesAcceptedFullAudio() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let cacheRoot = root.appending(path: "cache")
        let cacheDirectory = cacheRoot.appending(path: "StreamCache", directoryHint: .isDirectory)
        let destination = root.appending(path: "downloads")
        let songID: Int64 = 604
        let sourceBytes = Data("ID3-full-cache".utf8)
        let source = root.appending(path: "source.mp3")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try sourceBytes.write(to: source)
        let setupCache = TrackCache(directory: cacheDirectory)
        let cached = try await setupCache.storeCopy(
            of: source,
            for: songID,
            quality: "standard",
            fileExtension: "mp3"
        )

        let partialDirectory = cacheDirectory
            .appending(path: "RangeCache", directoryHint: .isDirectory)
            .appending(path: "standard", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: partialDirectory, withIntermediateDirectories: true)
        let olderPartial = partialDirectory.appending(path: "604-old.range")
        let newerPartial = partialDirectory.appending(path: "604-new.range")
        let partialBytes = Data(repeating: 0x5a, count: 4_096)
        try partialBytes.write(to: olderPartial)
        try partialBytes.write(to: newerPartial)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1)],
            ofItemAtPath: olderPartial.path
        )
        let allocated = try newerPartial.resourceValues(
            forKeys: [.fileAllocatedSizeKey, .fileSizeKey]
        )
        let partialSize = Int64(allocated.fileAllocatedSize ?? allocated.fileSize ?? 0)
        #expect(partialSize > 0)
        let cache = TrackCache(
            directory: cacheDirectory,
            byteLimit: cached.size + partialSize,
            minimumTrimInterval: 0
        )
        #expect(await cache.readyCachedFile(for: 999, quality: "standard") == nil)

        DeferredLyricsProtocol.reset()
        let network = deferredLyricsNetwork()
        defer {
            DeferredLyricsProtocol.release()
            network.session.invalidateAndCancel()
        }
        let manager = MusicDownloadManager(
            transport: network.transport,
            session: network.session,
            maximumConcurrentDownloads: 1,
            resumeStore: MusicDownloadResumeStore(directory: root.appending(path: "resume")),
            targetAllocator: MusicDownloadTargetAllocator(),
            cacheRoot: cacheRoot,
            audioCache: cache
        )
        #expect(manager.enqueue(
            song: song(Int(songID)),
            to: destination,
            quality: .standard,
            includeLyrics: true
        ))
        for _ in 0..<200 where DeferredLyricsProtocol.requestCount == 0 {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(DeferredLyricsProtocol.requestCount > 0)

        await cache.recordPartialFileAccess(newerPartial)
        #expect(!FileManager.default.fileExists(atPath: olderPartial.path))
        #expect(FileManager.default.fileExists(atPath: newerPartial.path))
        #expect(FileManager.default.fileExists(atPath: cached.url.path))

        DeferredLyricsProtocol.release()
        try await waitForMusic(manager, songID: songID)
        guard case let .completed(audioURL, _)? = manager.states[songID] else {
            Issue.record("full cache download did not complete")
            return
        }
        #expect(audioURL.pathExtension == "mp3")
        #expect(try Data(contentsOf: audioURL) == sourceBytes)
        #expect(audioURL.pathExtension != "range")
    }

    @MainActor
    @Test("Clear fences a final cache store without exposing partial audio")
    func clearFencesFinalCacheStore() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let cacheRoot = root.appending(path: "cache")
        let cacheDirectory = cacheRoot.appending(path: "StreamCache", directoryHint: .isDirectory)
        let destination = root.appending(path: "downloads")
        let songID: Int64 = 605
        let partial = cacheDirectory
            .appending(path: "RangeCache", directoryHint: .isDirectory)
            .appending(path: "standard", directoryHint: .isDirectory)
            .appending(path: "605.range")
        try FileManager.default.createDirectory(
            at: partial.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("fLaC-partial".utf8).write(to: partial)

        let gate = CacheLookupGate(blockingInvocation: 3)
        let cache = TrackCache(directory: cacheDirectory, beforeReadyLookup: { await gate.wait() })
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FinalStoreFenceProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let manager = MusicDownloadManager(
            transport: EAPITransport(session: session, cookie: "", musicU: ""),
            session: session,
            maximumConcurrentDownloads: 1,
            retryPolicy: MusicDownloadRetryPolicy(maximumAttempts: 1, baseDelay: 0, maximumDelay: 0),
            resumeStore: MusicDownloadResumeStore(directory: root.appending(path: "resume")),
            targetAllocator: MusicDownloadTargetAllocator(),
            cacheRoot: cacheRoot,
            audioCache: cache
        )
        #expect(manager.enqueue(
            song: song(Int(songID)),
            to: destination,
            quality: .standard,
            includeLyrics: false
        ))
        try await waitForLookup(gate, count: 3)

        let clearFinished = LockedCounter()
        let clearing = Task { @MainActor in
            defer { clearFinished.increment() }
            try await manager.clearCache()
        }
        try await Task.sleep(for: .milliseconds(20))
        #expect(clearFinished.value == 0)
        await gate.release()
        try await clearing.value

        for _ in 0..<200 {
            switch manager.states[songID] {
            case .completed?, .cancelled?, .failed?: break
            default:
                try await Task.sleep(for: .milliseconds(5))
                continue
            }
            break
        }
        switch manager.states[songID] {
        case let .completed(audioURL, _)?:
            #expect(audioURL.pathExtension == "mp3")
            #expect(try Data(contentsOf: audioURL) == Data("ID3-final-store".utf8))
        case .cancelled?:
            let files = (try? FileManager.default.contentsOfDirectory(
                at: destination,
                includingPropertiesForKeys: nil
            )) ?? []
            #expect(!files.contains { $0.pathExtension == "range" })
        default:
            Issue.record("final store did not settle as completed or cancelled")
        }
        #expect(await cache.readyFile(for: songID, quality: "standard") == nil)
        #expect(await cache.readyCachedFile(for: songID, quality: "standard") == nil)
    }

    @MainActor
    @Test("Cache root switch preserves an accepted cached source download")
    func cacheRootSwitchPreservesFinalDownload() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let oldRoot = root.appending(path: "old-cache")
        let newRoot = root.appending(path: "new-cache")
        let destination = root.appending(path: "user-downloads")
        let songID: Int64 = 603
        let source = oldRoot.appending(path: "source.flac")
        try FileManager.default.createDirectory(at: oldRoot, withIntermediateDirectories: true)
        try Data("fLaC-cached".utf8).write(to: source)
        let cache = TrackCache(
            directory: oldRoot.appending(path: "StreamCache", directoryHint: .isDirectory)
        )
        let cached = try await cache.storeCopy(
            of: source,
            for: songID,
            quality: "standard",
            fileExtension: "flac"
        )
        let oldDate = Date(timeIntervalSince1970: 1)
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: cached.url.path)

        DeferredLyricsProtocol.reset()
        let network = deferredLyricsNetwork()
        defer {
            DeferredLyricsProtocol.release()
            network.session.invalidateAndCancel()
        }
        let manager = MusicDownloadManager(
            transport: network.transport,
            session: network.session,
            maximumConcurrentDownloads: 1,
            resumeStore: MusicDownloadResumeStore(directory: root.appending(path: "resume")),
            targetAllocator: MusicDownloadTargetAllocator(),
            cacheRoot: oldRoot,
            audioCache: cache
        )
        #expect(manager.enqueue(
            song: song(Int(songID)),
            to: destination,
            quality: .standard,
            includeLyrics: true
        ))

        var acceptedCachedSource = false
        for _ in 0..<200 {
            let modifiedAt = try? cached.url.resourceValues(
                forKeys: [.contentModificationDateKey]
            ).contentModificationDate
            if DeferredLyricsProtocol.requestCount > 0,
               modifiedAt.map({ $0 > oldDate }) == true {
                acceptedCachedSource = true
                break
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(acceptedCachedSource)
        try await Task.sleep(for: .milliseconds(20))

        manager.configure(cacheRoot: newRoot)
        let clearFinished = LockedCounter()
        let clearTask = Task { @MainActor in
            defer { clearFinished.increment() }
            try await manager.clearCache()
        }
        try await Task.sleep(for: .milliseconds(20))
        #expect(clearFinished.value == 0)

        DeferredLyricsProtocol.release()
        try await waitForMusic(manager, songID: songID)
        try await clearTask.value
        guard case let .completed(audioURL, lyricURL)? = manager.states[songID] else {
            Issue.record("cached source download did not complete after root switch")
            return
        }
        #expect(FileManager.default.fileExists(atPath: audioURL.path))
        #expect(try Data(contentsOf: audioURL) == Data("fLaC-cached".utf8))
        #expect(lyricURL.map { FileManager.default.fileExists(atPath: $0.path) } == true)
    }

    @MainActor
    @Test("Video pause, restart, and network retry reuse nonzero resume offsets")
    func videoResumeAndRetry() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = URL(string: "https://vod.126.net/resumable.mp4")!
        let request = videoRequest(id: 41, destination: root)
        let store = MusicDownloadResumeStore(directory: root.appending(path: "resume"))
        store.save(MusicDownloadVideoResumeEntry(
            request: request,
            resumeData: nil,
            resolution: 720,
            sourceURL: source,
            sourceExpiresAt: Date().addingTimeInterval(3_600)
        ))
        try await store.flush()

        let pausedOffsets = LockedValues<Int>()
        let pausingManager = MusicDownloadManager(
            maximumConcurrentDownloads: 1,
            retryPolicy: MusicDownloadRetryPolicy(maximumAttempts: 2, baseDelay: 0, maximumDelay: 0),
            resumeStore: store,
            targetAllocator: MusicDownloadTargetAllocator(),
            videoTransfer: { _, resumeData, _ in
                pausedOffsets.append(resumeData?.first.map(Int.init) ?? 0)
                do {
                    try await Task.sleep(for: .seconds(30))
                } catch {
                    throw MusicDownloadTransferPaused(resumeData: Data([48]))
                }
                throw MusicDownloadError.invalidResponse
            }
        )
        for _ in 0..<200 where pausedOffsets.values.isEmpty {
            try await Task.sleep(for: .milliseconds(5))
        }
        await pausingManager.pauseAll()
        #expect((await store.recoverableDownloadsAsync()).videos.first?.resumeData == Data([48]))

        let restartOffsets = LockedValues<Int>()
        let restarted = MusicDownloadManager(
            maximumConcurrentDownloads: 1,
            retryPolicy: MusicDownloadRetryPolicy(maximumAttempts: 2, baseDelay: 0, maximumDelay: 0),
            resumeStore: store,
            targetAllocator: MusicDownloadTargetAllocator(),
            videoTransfer: { request, resumeData, _ in
                restartOffsets.append(resumeData?.first.map(Int.init) ?? 0)
                return try mp4Result(for: request)
            }
        )
        await restarted.pauseAll() // Wait for startup recovery without starting paused transfers.
        #expect(restarted.videoStates[request.resource.identity] == .paused(progress: nil))
        #expect(restartOffsets.values.isEmpty)
        restarted.retryVideo(id: request.resource.identity)
        try await waitForVideo(restarted, id: request.resource.identity)
        #expect(restartOffsets.values.first == 48)

        let retryRequest = videoRequest(id: 42, destination: root)
        let retryStore = MusicDownloadResumeStore(directory: root.appending(path: "retry-resume"))
        retryStore.save(MusicDownloadVideoResumeEntry(
            request: retryRequest,
            resumeData: nil,
            resolution: 720,
            sourceURL: source,
            sourceExpiresAt: Date().addingTimeInterval(3_600)
        ))
        try await retryStore.flush()
        let retryOffsets = LockedValues<Int>()
        let retryManager = MusicDownloadManager(
            maximumConcurrentDownloads: 1,
            retryPolicy: MusicDownloadRetryPolicy(maximumAttempts: 2, baseDelay: 0, maximumDelay: 0),
            resumeStore: retryStore,
            targetAllocator: MusicDownloadTargetAllocator(),
            videoTransfer: { request, resumeData, _ in
                let offset = resumeData?.first.map(Int.init) ?? 0
                retryOffsets.append(offset)
                if retryOffsets.values.count == 1 {
                    throw URLError(
                        .networkConnectionLost,
                        userInfo: [NSURLSessionDownloadTaskResumeData: Data([64])]
                    )
                }
                return try mp4Result(for: request)
            }
        )
        try await waitForVideo(retryManager, id: retryRequest.resource.identity)
        #expect(retryOffsets.values == [0, 64])
    }

    @MainActor
    @Test("Video pause during retry backoff preserves the latest resume data")
    func videoPauseDuringRetryBackoff() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = URL(string: "https://vod.126.net/backoff.mp4")!
        let request = videoRequest(id: 43, destination: root)
        let store = MusicDownloadResumeStore(directory: root.appending(path: "backoff-resume"))
        store.save(MusicDownloadVideoResumeEntry(
            request: request,
            resumeData: nil,
            resolution: 720,
            sourceURL: source,
            sourceExpiresAt: Date().addingTimeInterval(3_600)
        ))
        try await store.flush()

        let offsets = LockedValues<Int>()
        let manager = MusicDownloadManager(
            maximumConcurrentDownloads: 1,
            retryPolicy: MusicDownloadRetryPolicy(maximumAttempts: 2, baseDelay: 30, maximumDelay: 30),
            resumeStore: store,
            targetAllocator: MusicDownloadTargetAllocator(),
            videoTransfer: { _, resumeData, _ in
                offsets.append(resumeData?.first.map(Int.init) ?? 0)
                throw URLError(
                    .networkConnectionLost,
                    userInfo: [NSURLSessionDownloadTaskResumeData: Data([96])]
                )
            }
        )
        for _ in 0..<200 where offsets.values.isEmpty {
            try await Task.sleep(for: .milliseconds(5))
        }
        try await Task.sleep(for: .milliseconds(100))
        #expect(offsets.values == [0])

        manager.pauseVideo(id: request.resource.identity)
        for _ in 0..<200 where manager.isVideoActive(id: request.resource.identity) {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(!manager.isVideoActive(id: request.resource.identity))
        try await manager.flushPersistence()
        let paused = await store.recoverableDownloadsAsync()
        #expect(paused.videos.first?.resumeData == Data([96]))

        let restartedOffsets = LockedValues<Int>()
        let restarted = MusicDownloadManager(
            maximumConcurrentDownloads: 1,
            retryPolicy: MusicDownloadRetryPolicy(maximumAttempts: 2, baseDelay: 0, maximumDelay: 0),
            resumeStore: store,
            targetAllocator: MusicDownloadTargetAllocator(),
            videoTransfer: { request, resumeData, _ in
                restartedOffsets.append(resumeData?.first.map(Int.init) ?? 0)
                return try mp4Result(for: request)
            }
        )
        await restarted.pauseAll()
        #expect(restarted.videoStates[request.resource.identity] == .paused(progress: nil))
        #expect(restartedOffsets.values.isEmpty)
        restarted.retryVideo(id: request.resource.identity)
        try await waitForVideo(restarted, id: request.resource.identity)
        #expect(restartedOffsets.values.first == 96)
    }

    @MainActor
    @Test("Queued and recovered cloud downloads keep the account revision captured before start")
    func cloudDownloadRevisionFence() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MusicDownloadResumeStore(directory: root.appending(path: "resume"))
        let recoveredCloud = musicRequest(
            id: 701,
            destination: root,
            source: .cloud(userID: 7, fileName: "recovered.flac")
        )
        let blockingVideo = videoRequest(id: 700, destination: root)
        store.save(
            audio: [MusicDownloadResumeEntry(request: recoveredCloud, resumeData: nil)],
            videos: [MusicDownloadVideoResumeEntry(
                request: blockingVideo,
                resumeData: nil,
                resolution: 720,
                sourceURL: URL(string: "https://vod.126.net/account-fence.mp4")!,
                sourceExpiresAt: Date().addingTimeInterval(3_600)
            )]
        )
        try await store.flush()

        DownloadFenceProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DownloadFenceProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let snapshot = CredentialSnapshot(.authenticated(try downloadCredentials("account-a")))
        let revisionA = snapshot.load().revision
        let blocker = CacheLookupGate()
        let manager = MusicDownloadManager(
            transport: EAPITransport(session: session, credentialSnapshot: snapshot),
            session: session,
            maximumConcurrentDownloads: 1,
            retryPolicy: MusicDownloadRetryPolicy(maximumAttempts: 1, baseDelay: 0, maximumDelay: 0),
            resumeStore: store,
            targetAllocator: MusicDownloadTargetAllocator(),
            videoTransfer: { request, _, _ in
                await blocker.wait()
                return try mp4Result(for: request)
            }
        )
        defer { manager.cancelAll() }

        try await waitForLookup(blocker)
        #expect(manager.items[recoveredCloud.songID] == nil)
        #expect(DownloadFenceProtocol.requestCount == 0)

        manager.setCloudDownloadAccount(userID: 7, credentialRevision: revisionA)
        #expect(manager.items[recoveredCloud.songID] != nil)
        let queuedCloud = CloudSong(
            id: 702,
            song: nil,
            name: "Queued",
            artist: "Artist",
            album: "",
            fileName: "queued.flac",
            fileSize: 4,
            addedAt: nil
        )
        #expect(manager.enqueue(
            cloudSong: queuedCloud,
            userID: 7,
            expectedCredentialRevision: revisionA,
            to: root,
            includeLyrics: false
        ))

        _ = snapshot.store(.authenticated(try downloadCredentials("account-b")))
        await blocker.release()
        let cloudIDs = [recoveredCloud.songID, queuedCloud.id]
        for _ in 0..<400 {
            if cloudIDs.allSatisfy({ id in
                manager.states[id] == .cancelled
            }) { break }
            try await Task.sleep(for: .milliseconds(5))
        }

        #expect(cloudIDs.allSatisfy { manager.states[$0] == .cancelled })
        #expect(DownloadFenceProtocol.requestCount == 0)
    }

    @MainActor
    @Test("Completed-file validation leaves MainActor and rebuilds missing audio and video")
    func completedFileValidationIsOffMainActor() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let cacheRoot = root.appending(path: "cache")
        let destination = root.appending(path: "downloads")
        let audio = song(801)
        let audioCache = TrackCache(
            directory: cacheRoot.appending(path: "StreamCache", directoryHint: .isDirectory)
        )
        let audioSource = root.appending(path: "source.flac")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("fLaC-source".utf8).write(to: audioSource)
        _ = try await audioCache.storeCopy(
            of: audioSource,
            for: audio.id,
            quality: AudioQuality.standard.cacheComponent,
            fileExtension: "flac"
        )

        let video = videoRequest(id: 802, destination: destination)
        let store = MusicDownloadResumeStore(directory: root.appending(path: "resume"))
        store.save(MusicDownloadVideoResumeEntry(
            request: video,
            resumeData: nil,
            resolution: 720,
            sourceURL: URL(string: "https://vod.126.net/validation.mp4")!,
            sourceExpiresAt: Date().addingTimeInterval(3_600)
        ))
        try await store.flush()
        guard let recoveredVideo = (await store.recoverableDownloadsAsync()).videos.first?.request else {
            Issue.record("video recovery fixture was not persisted")
            return
        }

        let audioProbe = BlockingFileValidator()
        let videoProbe = BlockingFileValidator()
        let network = blockedNetwork()
        defer { network.session.invalidateAndCancel() }
        let manager = MusicDownloadManager(
            transport: network.transport,
            session: network.session,
            maximumConcurrentDownloads: 2,
            retryPolicy: MusicDownloadRetryPolicy(maximumAttempts: 1, baseDelay: 0, maximumDelay: 0),
            resumeStore: store,
            targetAllocator: MusicDownloadTargetAllocator(),
            cacheRoot: cacheRoot,
            audioCache: audioCache,
            videoTransfer: { request, _, _ in try mp4Result(for: request) },
            audioFileValidator: audioProbe.validate,
            videoFileValidator: videoProbe.validate
        )
        #expect(manager.enqueue(
            song: audio,
            to: destination,
            quality: .standard,
            includeLyrics: false
        ))
        try await waitForMusic(manager, songID: audio.id)
        try await waitForVideo(manager, id: recoveredVideo.resource.identity)
        guard case let .completed(audioURL, _)? = manager.states[audio.id],
              case let .completed(videoURL, _)? = manager.videoStates[recoveredVideo.resource.identity]
        else {
            Issue.record("initial downloads did not complete")
            return
        }
        try FileManager.default.removeItem(at: audioURL)
        try FileManager.default.removeItem(at: videoURL)

        let audioRelease = Task.detached {
            let didStart = audioProbe.waitForStart()
            try? await Task.sleep(for: .milliseconds(100))
            audioProbe.releaseValidation()
            return didStart
        }
        let videoRelease = Task.detached {
            let didStart = videoProbe.waitForStart()
            try? await Task.sleep(for: .milliseconds(100))
            videoProbe.releaseValidation()
            return didStart
        }
        #expect(!manager.enqueue(
            song: audio,
            to: destination,
            quality: .standard,
            includeLyrics: false
        ))
        #expect(!manager.enqueue(
            video: recoveredVideo.resource,
            title: recoveredVideo.title,
            creator: recoveredVideo.creator,
            availableResolutions: recoveredVideo.availableResolutions,
            to: recoveredVideo.destination,
            quality: recoveredVideo.quality
        ))
        #expect(!audioProbe.wasReleased)
        #expect(!videoProbe.wasReleased)
        #expect(await audioRelease.value)
        #expect(await videoRelease.value)

        for _ in 0..<500 {
            let audioExists = if case let .completed(url, _)? = manager.states[audio.id] {
                FileManager.default.fileExists(atPath: url.path)
            } else {
                false
            }
            let videoExists = if case let .completed(url, _)? = manager.videoStates[recoveredVideo.resource.identity] {
                FileManager.default.fileExists(atPath: url.path)
            } else {
                false
            }
            if audioExists, videoExists { break }
            try await Task.sleep(for: .milliseconds(5))
        }

        #expect(audioProbe.didRun && !audioProbe.ranOnMainThread)
        #expect(videoProbe.didRun && !videoProbe.ranOnMainThread)
        guard case let .completed(rebuiltAudioURL, _)? = manager.states[audio.id],
              case let .completed(rebuiltVideoURL, _)? = manager.videoStates[recoveredVideo.resource.identity]
        else {
            Issue.record("missing completed state after file validation")
            return
        }
        #expect(FileManager.default.fileExists(atPath: rebuiltAudioURL.path))
        #expect(FileManager.default.fileExists(atPath: rebuiltVideoURL.path))
    }
}

private enum DownloadMeasurementSignposts {
    private static let signposter = OSSignposter(
        subsystem: "com.tinycloudmusic.app.tests",
        category: "W5-FX2A"
    )

    static func interval<T>(_ name: StaticString, _ operation: () throws -> T) rethrows -> T {
        let state = signposter.beginInterval(name)
        defer { signposter.endInterval(name, state) }
        return try operation()
    }

    @MainActor
    static func asyncInterval<T>(
        _ name: StaticString,
        _ operation: () async throws -> T
    ) async rethrows -> T {
        let state = signposter.beginInterval(name)
        defer { signposter.endInterval(name, state) }
        return try await operation()
    }
}

private struct ControlledCacheAggregate: Equatable {
    let fileCount: Int
    let logicalBytes: Int64
    let ageBuckets: [Int]
    let activeFileCount: Int
}

private struct ControlledCacheInventory {
    let roots: [String: ControlledCacheAggregate]
    let pairedVideoCount: Int
    let unpairedVideoCount: Int
}

private func writeControlledCacheFile(_ url: URL, bytes: Int, modifiedAt: Date) throws {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try Data(repeating: 0x41, count: bytes).write(to: url)
    try FileManager.default.setAttributes(
        [.modificationDate: modifiedAt],
        ofItemAtPath: url.path
    )
}

private func controlledCacheInventory(
    at cacheRoot: URL,
    referenceDate: Date,
    activePaths: Set<String>
) throws -> ControlledCacheInventory {
    let keys: Set<URLResourceKey> = [
        .isRegularFileKey,
        .isSymbolicLinkKey,
        .fileSizeKey,
        .contentModificationDateKey
    ]
    var roots: [String: ControlledCacheAggregate] = [:]
    var videoPaths = Set<String>()
    for name in ["Videos", "Lyrics", "Sheets"] {
        let root = cacheRoot.appending(path: name, directoryHint: .isDirectory)
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else {
            throw CocoaError(.fileReadUnknown)
        }
        var fileCount = 0
        var logicalBytes: Int64 = 0
        var ageBuckets = [0, 0, 0]
        var activeFileCount = 0
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: keys)
            if values.isSymbolicLink == true {
                enumerator.skipDescendants()
                continue
            }
            guard values.isRegularFile == true else { continue }
            let path = url.standardizedFileURL.path
            fileCount += 1
            logicalBytes += Int64(values.fileSize ?? 0)
            if activePaths.contains(path) { activeFileCount += 1 }
            let age = max(0, referenceDate.timeIntervalSince(
                values.contentModificationDate ?? referenceDate
            ))
            ageBuckets[age < 24 * 60 * 60 ? 0 : age < 7 * 24 * 60 * 60 ? 1 : 2] += 1
            if name == "Videos" { videoPaths.insert(path) }
        }
        roots[name] = ControlledCacheAggregate(
            fileCount: fileCount,
            logicalBytes: logicalBytes,
            ageBuckets: ageBuckets,
            activeFileCount: activeFileCount
        )
    }
    let videoFiles = videoPaths.filter { $0.hasSuffix(".mp4") }
    let pairedVideoCount = videoFiles.count { videoPaths.contains($0 + ".size") }
    return ControlledCacheInventory(
        roots: roots,
        pairedVideoCount: pairedVideoCount,
        unpairedVideoCount: videoFiles.count - pairedVideoCount
    )
}

private actor DownloadProgressWorkloadGate {
    private(set) var progressReadyCount = 0
    private(set) var completedProgressCount = 0
    private var progressReleased = false
    private var finishReleased = false
    private var progressWaiters: [CheckedContinuation<Void, Never>] = []
    private var finishWaiters: [CheckedContinuation<Void, Never>] = []

    func waitForProgressRelease() async {
        progressReadyCount += 1
        guard !progressReleased else { return }
        await withCheckedContinuation { progressWaiters.append($0) }
    }

    func releaseProgress() {
        progressReleased = true
        let waiters = progressWaiters
        progressWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func holdAfterProgress() async {
        completedProgressCount += 1
        guard !finishReleased else { return }
        await withCheckedContinuation { finishWaiters.append($0) }
    }

    func releaseAll() {
        releaseProgress()
        finishReleased = true
        let waiters = finishWaiters
        finishWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}

private final class DownloadWorkloadProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var playbackRequests = 0

    static var playbackRequestCount: Int { lock.withLock { playbackRequests } }
    static func reset() { lock.withLock { playbackRequests = 0 } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard request.url?.path == "/weapi/song/enhance/play/mv/url" else { return }
        Self.lock.withLock { Self.playbackRequests += 1 }
        let body = Data(
            #"{"code":200,"data":{"url":"https://vod.126.net/perf-b07.mp4","r":720}}"#.utf8
        )
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json", "Content-Length": String(body.count)]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}

private final class LockedValues<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Value] = []
    var values: [Value] { lock.withLock { storage } }
    func append(_ value: Value) { lock.withLock { storage.append(value) } }
}

private final class BlockingFileValidator: @unchecked Sendable {
    private let lock = NSLock()
    private let started = DispatchSemaphore(value: 0)
    private let release = DispatchSemaphore(value: 0)
    private var didStart = false
    private var didRelease = false
    private var wasOnMainThread = false

    var didRun: Bool { lock.withLock { didStart } }
    var wasReleased: Bool { lock.withLock { didRelease } }
    var ranOnMainThread: Bool { lock.withLock { wasOnMainThread } }

    func validate(_ url: URL) -> Bool {
        lock.withLock {
            didStart = true
            wasOnMainThread = Thread.isMainThread
        }
        started.signal()
        release.wait()
        return FileManager.default.fileExists(atPath: url.path)
    }

    func waitForStart() -> Bool {
        started.wait(timeout: .now() + 2) == .success
    }

    func releaseValidation() {
        lock.withLock { didRelease = true }
        release.signal()
    }
}

private actor CacheLookupGate {
    private let blockingInvocation: Int
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var starts = 0
    private(set) var wasCancelled: Bool?

    init(blockingInvocation: Int = 1) {
        self.blockingInvocation = blockingInvocation
    }

    func wait() async {
        starts += 1
        guard starts == blockingInvocation else { return }
        await withCheckedContinuation { continuation = $0 }
        wasCancelled = Task.isCancelled
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

private final class FinalStoreFenceProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let status: Int
        let body: Data
        let contentType: String
        switch request.url?.path {
        case "/eapi/song/enhance/player/url/v1":
            status = 200
            body = Data(
                #"{"code":200,"data":[{"id":605,"code":200,"url":"https://m1.music.126.net/final-store-audio","type":"mp3","level":"standard","size":15}]}"#.utf8
            )
            contentType = "application/json"
        case "/final-store-audio":
            status = 200
            body = Data("ID3-final-store".utf8)
            contentType = "audio/mpeg"
        default:
            status = 404
            body = Data(#"{"code":404}"#.utf8)
            contentType = "application/json"
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: [
                "Content-Type": contentType,
                "Content-Length": String(body.count)
            ]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class BlockedDownloadProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {}
    override func stopLoading() {}
}

private final class DownloadFenceProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var starts = 0

    static var requestCount: Int { lock.withLock { starts } }
    static func reset() { lock.withLock { starts = 0 } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.withLock { Self.starts += 1 }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"code":403,"message":"unexpected request"}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class DeferredLyricsProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var pending: [DeferredLyricsProtocol] = []
    nonisolated(unsafe) private static var starts = 0
    private let stateLock = NSLock()
    private var stopped = false

    static var requestCount: Int { lock.withLock { starts } }

    static func reset() {
        lock.withLock {
            pending.removeAll()
            starts = 0
        }
    }

    static func release() {
        let protocols = lock.withLock {
            let protocols = pending
            pending.removeAll()
            return protocols
        }
        protocols.forEach { $0.finish() }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.withLock {
            Self.starts += 1
            Self.pending.append(self)
        }
    }

    override func stopLoading() {
        stateLock.withLock { stopped = true }
    }

    private func finish() {
        guard !stateLock.withLock({ stopped }) else { return }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(
            self,
            didLoad: Data(#"{"code":200,"lrc":{"lyric":"[00:00.000]cached lyric"}}"#.utf8)
        )
        client?.urlProtocolDidFinishLoading(self)
    }
}

private func blockedNetwork() -> (transport: EAPITransport, session: URLSession) {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [BlockedDownloadProtocol.self]
    let session = URLSession(configuration: configuration)
    return (EAPITransport(session: session, cookie: "", musicU: ""), session)
}

private func deferredLyricsNetwork() -> (transport: EAPITransport, session: URLSession) {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [DeferredLyricsProtocol.self]
    let session = URLSession(configuration: configuration)
    return (EAPITransport(session: session, cookie: "", musicU: ""), session)
}

private func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
}

private func downloadCredentials(_ value: String) throws -> SessionCredentials {
    try SessionCredentials(
        cookie: "MUSIC_U=\(value); __csrf=fixture",
        musicU: "vip-\(value)",
        deviceID: "0123456789abcdef0123456789abcdef"
    )
}

private func gatedCache(root: URL, songID: Int64, gate: CacheLookupGate) async throws -> TrackCache {
    let directory = root.appending(path: "StreamCache", directoryHint: .isDirectory)
    let source = root.appending(path: "cached-(songID).tmp")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try Data("ID3-cached".utf8).write(to: source)
    _ = try await TrackCache(directory: directory).storeCopy(
        of: source,
        for: songID,
        quality: "standard",
        fileExtension: "mp3"
    )
    return TrackCache(directory: directory, beforeReadyLookup: { await gate.wait() })
}

private func waitForLookup(_ gate: CacheLookupGate, count: Int = 1) async throws {
    for _ in 0..<200 {
        if await gate.starts >= count { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("cache lookup did not start")
}

private func musicRequest(
    id: Int64,
    destination: URL,
    quality: AudioQuality = .lossless,
    source: MusicDownloadSource = .catalog
) -> MusicDownloadRequest {
    MusicDownloadRequest(
        songID: id,
        songName: "same",
        artists: "artist",
        destination: destination,
        quality: quality,
        includeLyrics: true,
        source: source,
        expectedBytes: 4
    )
}

private func song(_ id: Int) -> Song {
    Song(
        id: Int64(id),
        name: "Song \(id)",
        artists: [ArtistSummary(id: 1, name: "Artist")],
        album: AlbumSummary(id: 1, name: "Album", artwork: Artwork(symbol: "music.note", accent: .blue)),
        duration: .seconds(1)
    )
}

private func videoRequest(id: Int64, destination: URL) -> VideoDownloadRequest {
    VideoDownloadRequest(
        resource: .mv(id),
        title: "Video \(id)",
        creator: "Artist",
        destination: destination,
        quality: .high,
        availableResolutions: [720]
    )
}

private func mp4Result(
    for request: URLRequest,
    suffix: UInt8? = nil
) throws -> MusicDownloadTransferResult {
    let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    var bytes: [UInt8] = [0, 0, 0, 16]
    bytes.append(contentsOf: "ftyp".utf8)
    bytes.append(contentsOf: repeatElement(UInt8(0), count: 8))
    if let suffix { bytes.append(suffix) }
    try Data(bytes).write(to: url)
    let response = HTTPURLResponse(
        url: request.url!,
        statusCode: 200,
        httpVersion: "HTTP/1.1",
        headerFields: ["Content-Length": String(bytes.count)]
    )!
    return MusicDownloadTransferResult(temporaryURL: url, response: response)
}

@MainActor
private func waitForVideo(_ manager: MusicDownloadManager, id: String) async throws {
    for _ in 0..<500 {
        if case .completed? = manager.videoStates[id] { return }
        if case let .failed(message)? = manager.videoStates[id] {
            Issue.record("video failed: \(message)")
            return
        }
        try await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("video did not finish")
}

@MainActor
private func waitForMusic(_ manager: MusicDownloadManager, songID: Int64) async throws {
    for _ in 0..<500 {
        if case .completed? = manager.states[songID] { return }
        if case let .failed(message)? = manager.states[songID] {
            Issue.record("music download failed: \(message)")
            return
        }
        if case .cancelled? = manager.states[songID] {
            Issue.record("music download was cancelled")
            return
        }
        try await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("music download did not finish")
}
#endif
