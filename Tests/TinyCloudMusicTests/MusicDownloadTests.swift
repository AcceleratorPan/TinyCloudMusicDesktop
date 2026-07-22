import Foundation

#if !MUSIC_DOWNLOAD_CHECK && canImport(Testing)
import Testing
@testable import TinyCloudMusic
#endif

private enum MusicDownloadCheckError: Error {
    case failed
}

private final class DowngradedDownloadProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body: Data
        switch request.url?.path {
        case "/eapi/song/music/detail/get":
            body = Data(#"{"code":200,"data":{"jm":{"br":1900000,"size":19000,"sr":192000},"sk":{"br":900000,"size":9000,"sr":48000}}}"#.utf8)
        case "/eapi/v3/song/detail":
            body = Data(#"{"code":200,"privileges":[{"plLevel":"sky","flLevel":"exhigh","downloadMaxBrLevel":"sky"}]}"#.utf8)
        default:
            body = Data(#"{"code":200,"data":{"url":"https://example.com/audio.flac","type":"flac","level":"lossless","size":4096}}"#.utf8)
        }
        let status = [
            "/eapi/song/music/detail/get",
            "/eapi/v3/song/detail",
            "/eapi/song/enhance/player/url/v1"
        ].contains(request.url?.path ?? "") ? 200 : 400
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private func verifyHighestQualityDoesNotDowngrade() async throws {
    let skyPayload = MusicDownloadManager.audioSourcePayload(songID: 1, level: "sky")
    let losslessPayload = MusicDownloadManager.audioSourcePayload(songID: 1, level: "lossless")
    guard skyPayload["ids"] as? String == "[\"1\"]",
          skyPayload["level"] as? String == "sky",
          skyPayload["encodeType"] as? String == "flac",
          skyPayload["immerseType"] as? String == "c51",
          losslessPayload["immerseType"] == nil
    else { throw MusicDownloadCheckError.failed }

    guard MusicDownloadManager.nextLowerLevel(after: "jymaster") == "sky",
          MusicDownloadManager.nextLowerLevel(after: "sky") == "jyeffect",
          MusicDownloadManager.nextLowerLevel(after: "higher") == "standard",
          MusicDownloadManager.nextLowerLevel(after: "standard") == nil
    else { throw MusicDownloadCheckError.failed }

    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [DowngradedDownloadProtocol.self]
    let transport = EAPITransport(session: URLSession(configuration: configuration), cookie: "", musicU: "")
    let request = MusicDownloadRequest(
        songID: 1,
        songName: "测试歌曲",
        artists: "测试歌手",
        destination: FileManager.default.temporaryDirectory,
        quality: .best,
        includeLyrics: false,
        source: .catalog,
        expectedBytes: nil
    )
    let highestLevel = try await MusicDownloadManager.downloadLevel(for: request, transport: transport)
    guard highestLevel == "jymaster" else { throw MusicDownloadCheckError.failed }

    do {
        _ = try await MusicDownloadManager.audioSource(
            songID: 1,
            level: "sky",
            requiresExactLevel: true,
            transport: transport
        )
        throw MusicDownloadCheckError.failed
    } catch MusicDownloadError.qualityMismatch {}

    let losslessSource = try await MusicDownloadManager.audioSource(
        songID: 1,
        level: "lossless",
        requiresExactLevel: true,
        transport: transport
    )
    guard losslessSource.expectedBytes == 4096 else { throw MusicDownloadCheckError.failed }
}

private func verifyMusicDownloadFiles() throws {
    guard MusicDownloadFiles.sanitizedFileName("A/B:C\\D*?\"<>|\n") == "ABCD",
          MusicDownloadFiles.sanitizedFileName("..").isEmpty
    else { throw MusicDownloadCheckError.failed }

    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let targets = MusicDownloadFiles.availableTargets(in: root, stem: "song", audioExtension: "mp3")
    let source = root.appending(path: "source.tmp")
    try Data([1, 2, 3]).write(to: source)
    try MusicDownloadFiles.stageDownloadedFile(source, at: targets.audioPart)
    guard FileManager.default.fileExists(atPath: targets.audioPart.path),
          !FileManager.default.fileExists(atPath: targets.audioFinal.path)
    else { throw MusicDownloadCheckError.failed }

    try MusicDownloadFiles.commit(partURL: targets.audioPart, finalURL: targets.audioFinal)
    guard try Data(contentsOf: targets.audioFinal) == Data([1, 2, 3]),
          !FileManager.default.fileExists(atPath: targets.audioPart.path),
          MusicDownloadFiles.existingDownload(
              in: root,
              stem: "song",
              audioExtension: "mp3"
          )?.audioURL == targets.audioFinal
    else { throw MusicDownloadCheckError.failed }

    let emptySource = root.appending(path: "empty.tmp")
    let emptyFinal = root.appending(path: "empty.mp3")
    let emptyPart = emptyFinal.appendingPathExtension("part")
    try Data().write(to: emptySource)
    do {
        try MusicDownloadFiles.stageDownloadedFile(emptySource, at: emptyPart)
        throw MusicDownloadCheckError.failed
    } catch MusicDownloadError.emptyFile {
    guard !FileManager.default.fileExists(atPath: emptyFinal.path),
          !FileManager.default.fileExists(atPath: emptyPart.path)
    else { throw MusicDownloadCheckError.failed }

    var progress = MusicDownloadProgressThrottle(minimumInterval: 0.1)
    guard progress.update(totalBytesWritten: 1, totalBytesExpectedToWrite: 100, now: 0) == 0.01,
          progress.update(totalBytesWritten: 2, totalBytesExpectedToWrite: 100, now: 0.05) == nil,
          progress.update(totalBytesWritten: 3, totalBytesExpectedToWrite: 100, now: 0.1) == 0.03,
          progress.update(totalBytesWritten: 2, totalBytesExpectedToWrite: 100, now: 0.2) == nil,
          progress.update(totalBytesWritten: 100, totalBytesExpectedToWrite: 100, now: 0.11) == 1,
          MusicDownloadManager.overallProgress(audioProgress: 0.5, weight: 0.99) == 0.495,
          MusicDownloadManager.overallProgress(audioProgress: 0.5, weight: 1) == 0.5,
          MusicDownloadManager.overallProgress(audioProgress: 2, weight: 0.99) == 0.99
    else { throw MusicDownloadCheckError.failed }

    var responseProgress = MusicDownloadProgressThrottle()
    guard responseProgress.update(
        totalBytesWritten: 25,
        totalBytesExpectedToWrite: 200,
        responseExpectedContentLength: 100
    ) == 0.25 else { throw MusicDownloadCheckError.failed }

    var unknownProgress = MusicDownloadProgressThrottle()
    guard unknownProgress.update(
        totalBytesWritten: 25,
        totalBytesExpectedToWrite: NSURLSessionTransferSizeUnknown
    ) == nil else { throw MusicDownloadCheckError.failed }
}
}

private func verifyRetryPolicyAndResumeStore() throws {
    let policy = MusicDownloadRetryPolicy(maximumAttempts: 4, baseDelay: 0.5, maximumDelay: 1.5)
    guard policy.maximumRetryCount == 3,
          policy.delay(forRetry: 1) == 0.5,
          policy.delay(forRetry: 2) == 1,
          policy.delay(forRetry: 3) == 1.5,
          policy.delay(forRetry: 1, retryAfter: 70) == 60,
          policy.shouldRetry(URLError(.networkConnectionLost)),
          policy.shouldRetry(MusicDownloadHTTPError(statusCode: 503, retryAfter: nil)),
          !policy.shouldRetry(MusicDownloadHTTPError(statusCode: 400, retryAfter: nil))
    else { throw MusicDownloadCheckError.failed }

    let resumeBytes = Data([1, 3, 5, 7])
    let resumableError = NSError(
        domain: NSURLErrorDomain,
        code: URLError.networkConnectionLost.rawValue,
        userInfo: [NSURLSessionDownloadTaskResumeData: resumeBytes]
    )
    guard policy.resumeData(from: resumableError) == resumeBytes else {
        throw MusicDownloadCheckError.failed
    }

    let root = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = MusicDownloadResumeStore(directory: root)
    let request = MusicDownloadRequest(
        songID: 99,
        songName: "Resume",
        artists: "Artist",
        destination: root,
        quality: .lossless,
        includeLyrics: true,
        source: .catalog,
        expectedBytes: 1_024
    )
    store.save(resumeBytes, for: request)
    guard store.load(for: request) == resumeBytes else { throw MusicDownloadCheckError.failed }
    store.remove(songID: request.songID)
    guard store.load(for: request) == nil else { throw MusicDownloadCheckError.failed }
}

@MainActor
private func verifyDuplicateQualityIsSkipped() throws {
    let manager = MusicDownloadManager()
    let song = Song(
        id: 7,
        name: "Queue",
        artists: [ArtistSummary(id: 1, name: "Artist")],
        album: AlbumSummary(id: 1, name: "Album", artwork: Artwork(symbol: "music.note", accent: .red)),
        duration: .seconds(1)
    )
    let destination = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    guard manager.enqueue(song: song, to: destination, quality: .standard, includeLyrics: false),
          !manager.enqueue(song: song, to: destination, quality: .standard, includeLyrics: false),
          manager.enqueue(song: song, to: destination, quality: .lossless, includeLyrics: false)
    else { throw MusicDownloadCheckError.failed }
    manager.cancelAll()
}

#if MUSIC_DOWNLOAD_CHECK
@main
private enum MusicDownloadCheck {
    @MainActor
    static func main() async throws {
        try verifyMusicDownloadFiles()
        try verifyRetryPolicyAndResumeStore()
        try verifyDuplicateQualityIsSkipped()
        try await verifyHighestQualityDoesNotDowngrade()
        print("Music download checks passed")
    }
}
#elseif canImport(Testing)
@Suite("Music download files")
struct MusicDownloadTests {
    @Test("Filename cleanup and atomic finalization")
    func filenameAndAtomicFinalization() throws {
        try verifyMusicDownloadFiles()
    }

    @Test("Highest available quality never accepts a downgraded source")
    func highestQualityDoesNotDowngrade() async throws {
        try await verifyHighestQualityDoesNotDowngrade()
    }

    @Test("Retries use exponential backoff and persist matching resume data")
    func retryPolicyAndResumeStore() throws {
        try verifyRetryPolicyAndResumeStore()
    }

    @MainActor
    @Test("Duplicate quality is skipped while a different quality replaces the task")
    func duplicateQualityIsSkipped() throws {
        try verifyDuplicateQualityIsSkipped()
    }
}
#endif
