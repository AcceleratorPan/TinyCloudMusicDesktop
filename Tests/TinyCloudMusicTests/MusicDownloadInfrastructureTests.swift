import Foundation

#if canImport(Testing)
import Testing
@testable import TinyCloudMusic

@Suite("Music download infrastructure")
struct MusicDownloadInfrastructureTests {
    @Test("Retry delay honors server backoff and paused resume data")
    func retryDelayAndPausedResumeData() {
        let policy = MusicDownloadRetryPolicy(maximumAttempts: 4, baseDelay: 0.5, maximumDelay: 2)
        let resumeData = Data([2, 4, 6])

        #expect(policy.delay(forRetry: 1, retryAfter: 70) == 70)
        #expect(policy.delay(forRetry: 3, retryAfter: 0.25) == 2)
        #expect(policy.delay(forRetry: 1, retryAfter: 400) == 300)
        #expect(!policy.shouldRetry(EAPIError.service(code: 800, message: "business")))
        #expect(policy.resumeData(from: MusicDownloadTransferPaused(resumeData: resumeData)) == resumeData)
    }

    @Test("Allocator reserves lyric targets across audio extensions")
    func allocatorReservesLyricsAcrossAudioExtensions() async {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let allocator = MusicDownloadTargetAllocator()
        let mp3 = await allocator.reserve(in: root, stem: "song", audioExtension: "mp3")
        let flac = await allocator.reserve(in: root, stem: "song", audioExtension: "flac")

        #expect(mp3.audioFinal != flac.audioFinal)
        #expect(mp3.lyricFinal != flac.lyricFinal)

        await allocator.release(mp3)
        await allocator.release(flac)
    }

    @Test("Pending requests and resume data survive a new store instance")
    func requestAndResumeDataSurviveRestart() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let storeDirectory = root.appending(path: "resume", directoryHint: .isDirectory)
        let request = request(destination: root)

        MusicDownloadResumeStore(directory: storeDirectory).save(request)
        let restarted = MusicDownloadResumeStore(directory: storeDirectory)
        #expect(restarted.load(for: request) == nil)
        let pending = try #require(restarted.recoverableDownloads().first)
        #expect(pending.resumeData == nil)
        #expect(pending.request.songID == request.songID)
        #expect(pending.request.source == request.source)
        #expect(pending.request.destination.standardizedFileURL.path == root.standardizedFileURL.path)

        let resumeData = Data([1, 3, 5, 7])
        restarted.save(resumeData, for: request)
        let resumed = MusicDownloadResumeStore(directory: storeDirectory)
        #expect(resumed.load(for: request) == resumeData)
        #expect(resumed.recoverableDownloads().first?.resumeData == resumeData)
    }

    @Test("Enumeration prunes expired records")
    func enumerationPrunesExpiredRecords() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MusicDownloadResumeStore(directory: root, maximumAge: 1)
        store.save(request(destination: root))

        #expect(store.recoverableDownloads(now: Date().addingTimeInterval(2)).isEmpty)
        #expect((try? FileManager.default.contentsOfDirectory(atPath: root.path))?.isEmpty == true)
    }

    @Test("Resume updates preserve original FIFO order")
    func resumeUpdatesPreserveFIFO() {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MusicDownloadResumeStore(directory: root)
        let first = request(destination: root, songID: 41)
        let second = request(destination: root, songID: 42)
        store.save(first)
        Thread.sleep(forTimeInterval: 0.01)
        store.save(second)
        Thread.sleep(forTimeInterval: 0.01)
        store.save(first, resumeData: Data([1]))

        #expect(store.recoverableDownloads().map(\.request.songID) == [41, 42])
    }

    @Test("Stale cleanup only removes UUID part files")
    func stalePartCleanupIsScoped() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? fileManager.removeItem(at: root) }
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let now = Date()
        let stale = root.appending(path: "song.mp3.\(UUID().uuidString).part")
        let recent = root.appending(path: "song.flac.\(UUID().uuidString).part")
        let unrelated = root.appending(path: "other.part")
        for url in [stale, recent, unrelated] { try Data([1]).write(to: url) }
        try fileManager.setAttributes(
            [.modificationDate: now.addingTimeInterval(-120)],
            ofItemAtPath: stale.path
        )
        try fileManager.setAttributes(
            [.modificationDate: now.addingTimeInterval(-120)],
            ofItemAtPath: unrelated.path
        )

        #expect(MusicDownloadPartialFiles.removeStale(
            in: root,
            olderThan: 60,
            now: now,
            fileManager: fileManager
        ) == 1)
        #expect(!fileManager.fileExists(atPath: stale.path))
        #expect(fileManager.fileExists(atPath: recent.path))
        #expect(fileManager.fileExists(atPath: unrelated.path))
    }

    private func request(destination: URL, songID: Int64 = 42) -> MusicDownloadRequest {
        MusicDownloadRequest(
            songID: songID,
            songName: "Resume",
            artists: "Artist",
            destination: destination,
            quality: .lossless,
            includeLyrics: true,
            source: .cloud(userID: 7, fileName: "original.flac"),
            expectedBytes: 1_024
        )
    }
}
#endif
