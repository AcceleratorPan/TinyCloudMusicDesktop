import Foundation

#if !MUSIC_DOWNLOAD_CHECK && canImport(Testing)
import Testing
@testable import TinyCloudMusic
#endif

private enum MusicDownloadCheckError: Error {
    case failed
}

private final class DownloadProgressProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var reported = false

    var didReport: Bool { lock.withLock { reported } }
    func record() { lock.withLock { reported = true } }
}

private final class ScriptedDownloadProtocol: URLProtocol, @unchecked Sendable {
    enum Scenario: Sendable {
        case qualityFallback
        case sourceRetry
        case sourceValidation
        case transfer
    }

    private struct Reply: Sendable {
        let status: Int
        let headers: [String: String]
        let body: Data
        var delay: TimeInterval = 0
        var hangs = false
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var scenario = Scenario.qualityFallback
    nonisolated(unsafe) private static var paths: [String] = []
    nonisolated(unsafe) private static var lyricCompleted = false
    nonisolated(unsafe) private static var audioBeforeLyricsCompleted = false
    private let stateLock = NSLock()
    private var stopped = false

    static func configure(_ scenario: Scenario) {
        lock.withLock {
            self.scenario = scenario
            paths = []
            lyricCompleted = false
            audioBeforeLyricsCompleted = false
        }
    }

    static func requestCount(for path: String) -> Int {
        lock.withLock { paths.count(where: { $0 == path }) }
    }

    static var didDownloadBeforeLyricsCompleted: Bool {
        lock.withLock { audioBeforeLyricsCompleted }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let path = request.url?.path ?? ""
        let state = Self.lock.withLock { () -> (Scenario, Int) in
            Self.paths.append(path)
            if ["/quality-audio", "/bad-audio", "/good-audio"].contains(path), !Self.lyricCompleted {
                Self.audioBeforeLyricsCompleted = true
            }
            return (Self.scenario, Self.paths.count(where: { $0 == path }))
        }
        let reply = Self.reply(for: state.0, path: path, requestNumber: state.1)
        guard !reply.hangs else { return }
        if reply.delay > 0 {
            DispatchQueue.global().asyncAfter(deadline: .now() + reply.delay) { [weak self] in
                self?.finish(reply, path: path)
            }
        } else {
            finish(reply, path: path)
        }
    }

    override func stopLoading() {
        stateLock.withLock { stopped = true }
    }

    private func finish(_ reply: Reply, path: String) {
        guard !stateLock.withLock({ stopped }) else { return }
        if path == "/eapi/song/lyric" {
            Self.lock.withLock { Self.lyricCompleted = true }
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: reply.status,
            httpVersion: nil,
            headerFields: reply.headers
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    private static func reply(for scenario: Scenario, path: String, requestNumber: Int) -> Reply {
        let json = ["Content-Type": "application/json"]
        switch (scenario, path) {
        case (.qualityFallback, "/eapi/song/music/detail/get"):
            return Reply(
                status: 200,
                headers: json,
                body: Data(#"{"code":200,"data":{"jm":{"br":1900000,"size":4,"sr":192000},"sk":{"br":900000,"size":4,"sr":48000},"sq":{"br":900000,"size":4,"sr":48000}}}"#.utf8)
            )
        case (.qualityFallback, "/eapi/v3/song/detail"):
            return Reply(
                status: 200,
                headers: json,
                body: Data(#"{"code":200,"privileges":[{"plLevel":"jymaster","flLevel":"jymaster","downloadMaxBrLevel":"jymaster"}]}"#.utf8)
            )
        case (.qualityFallback, "/eapi/song/enhance/player/url/v1") where requestNumber == 1:
            return Reply(status: 200, headers: json, body: Data(#"{"code":500,"message":"busy"}"#.utf8))
        case (.qualityFallback, "/eapi/song/enhance/player/url/v1") where requestNumber < 4:
            let level = requestNumber == 2 ? "jymaster" : "sky"
            return Reply(
                status: 200,
                headers: json,
                body: Data("{\"code\":200,\"data\":[{\"id\":1,\"code\":404,\"level\":\"\(level)\"}]}".utf8)
            )
        case (.qualityFallback, "/eapi/song/enhance/player/url/v1"):
            return Reply(
                status: 200,
                headers: json,
                body: Data(#"{"code":200,"data":[{"id":1,"code":200,"url":"https://m1.music.126.net/quality-audio","type":"flac","level":"lossless","size":4}]}"#.utf8)
            )
        case (.qualityFallback, "/quality-audio"):
            return Reply(status: 200, headers: ["Content-Type": "audio/flac"], body: Data("fLaC".utf8))

        case (.sourceRetry, "/eapi/song/enhance/player/url/v1") where requestNumber == 1:
            return Reply(status: 200, headers: json, body: Data(#"{"code":500,"message":"busy"}"#.utf8))
        case (.sourceRetry, "/eapi/song/enhance/player/url/v1") where requestNumber == 2:
            return Reply(
                status: 200,
                headers: json,
                body: Data(#"{"code":200,"data":[{"id":2,"code":200,"url":"https://m1.music.126.net/bad-audio","type":"mp3","level":"standard","size":4}]}"#.utf8)
            )
        case (.sourceRetry, "/eapi/song/enhance/player/url/v1"):
            return Reply(
                status: 200,
                headers: json,
                body: Data(#"{"code":200,"data":[{"id":2,"code":200,"url":"https://m1.music.126.net/good-audio","type":"flac","level":"standard","size":4}]}"#.utf8)
            )
        case (.sourceRetry, "/bad-audio"):
            return Reply(status: 200, headers: json, body: Data("fLaC".utf8))
        case (.sourceRetry, "/good-audio"):
            return Reply(status: 200, headers: ["Content-Type": "audio/flac"], body: Data("fLaC".utf8))
        case (.sourceRetry, "/eapi/song/lyric"):
            return Reply(
                status: 200,
                headers: json,
                body: Data(#"{"code":200,"lrc":{"lyric":"[00:00.000]cached lyric"},"tlyric":{"lyric":""}}"#.utf8),
                delay: 0.2
            )

        case (.sourceValidation, "/eapi/song/enhance/player/url/v1") where requestNumber == 1:
            return Reply(
                status: 200,
                headers: json,
                body: Data(#"{"code":200,"data":[{"id":999,"code":200,"url":"https://m1.music.126.net/audio","type":"flac","level":"lossless","size":4}]}"#.utf8)
            )
        case (.sourceValidation, "/eapi/song/enhance/player/url/v1") where requestNumber == 2:
            return Reply(
                status: 200,
                headers: json,
                body: Data(#"{"code":200,"data":[{"id":1,"code":200,"url":"http://example.com/audio","type":"flac","level":"lossless","size":4}]}"#.utf8)
            )
        case (.sourceValidation, "/eapi/song/enhance/player/url/v1") where requestNumber == 3:
            return Reply(
                status: 200,
                headers: json,
                body: Data(#"{"code":200,"data":[{"id":1,"code":200,"url":"https://example.com/audio","type":"flac","level":"lossless","size":4}]}"#.utf8)
            )
        case (.sourceValidation, "/eapi/song/enhance/player/url/v1") where requestNumber == 4:
            return Reply(
                status: 200,
                headers: json,
                body: Data(#"{"code":200,"data":[{"id":1,"code":200,"url":"http://m1.music.126.net/audio","type":"flac","level":"lossless","size":4}]}"#.utf8)
            )
        case (.sourceValidation, "/eapi/song/enhance/player/url/v1"):
            return Reply(
                status: 200,
                headers: json,
                body: Data(#"{"code":200,"data":[{"id":1,"code":200,"url":"https://m1.music.126.net/audio","type":"mp3","level":"standard","size":4}]}"#.utf8)
            )

        case (.transfer, "/transfer-success"):
            return Reply(status: 200, headers: ["Content-Type": "audio/flac"], body: Data("fLaC".utf8))
        case (.transfer, "/transfer-block"):
            return Reply(status: 200, headers: [:], body: Data(), hangs: true)
        case (.transfer, "/eapi/song/enhance/player/url/v1"):
            return Reply(
                status: 200,
                headers: json,
                body: Data(#"{"code":200,"data":[{"id":404,"code":200,"url":"https://m1.music.126.net/transfer-block","type":"mp3","level":"standard"}]}"#.utf8)
            )
        default:
            return Reply(status: 404, headers: json, body: Data(#"{"code":404}"#.utf8))
        }
    }
}

private func scriptedNetwork(
    _ scenario: ScriptedDownloadProtocol.Scenario
) -> (transport: EAPITransport, session: URLSession) {
    ScriptedDownloadProtocol.configure(scenario)
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [ScriptedDownloadProtocol.self]
    let session = URLSession(configuration: configuration)
    return (EAPITransport(session: session, cookie: "", musicU: ""), session)
}

@MainActor
private func completedDownload(
    from manager: MusicDownloadManager,
    songID: Int64
) async throws -> MusicDownloadResult {
    for _ in 0..<500 {
        switch manager.states[songID] {
        case let .completed(audioURL, lyricURL):
            return MusicDownloadResult(audioURL: audioURL, lyricURL: lyricURL)
        case .failed, .cancelled:
            throw MusicDownloadCheckError.failed
        default:
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    throw MusicDownloadCheckError.failed
}

@MainActor
private func verifyHighestQualityFallback() async throws {
    let skyPayload = MusicDownloadManager.audioSourcePayload(songID: 1, level: "sky")
    let losslessPayload = MusicDownloadManager.audioSourcePayload(songID: 1, level: "lossless")
    guard skyPayload["ids"] as? String == "[\"1\"]",
          skyPayload["level"] as? String == "sky",
          skyPayload["encodeType"] as? String == "flac",
          skyPayload["immerseType"] as? String == "c51",
          losslessPayload["immerseType"] == nil
    else { throw MusicDownloadCheckError.failed }

    guard MusicDownloadManager.nextLowerLevel(after: "jymaster") == "sky",
          MusicDownloadManager.nextLowerLevel(after: "sky") == "dolby",
          MusicDownloadManager.nextLowerLevel(after: "higher") == "standard",
          MusicDownloadManager.nextLowerLevel(after: "standard") == nil
    else { throw MusicDownloadCheckError.failed }

    let network = scriptedNetwork(.qualityFallback)
    defer { network.session.invalidateAndCancel() }
    let root = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let cacheRoot = root.appending(path: "cache", directoryHint: .isDirectory)
    let request = MusicDownloadRequest(
        songID: 1,
        songName: "测试歌曲",
        artists: "测试歌手",
        destination: root,
        quality: .best,
        includeLyrics: false,
        source: .catalog,
        expectedBytes: nil
    )
    let highestLevel = try await MusicDownloadManager.downloadLevel(for: request, transport: network.transport)
    guard highestLevel == "jymaster" else { throw MusicDownloadCheckError.failed }

    let manager = MusicDownloadManager(
        transport: network.transport,
        session: network.session,
        maximumConcurrentDownloads: 1,
        retryPolicy: MusicDownloadRetryPolicy(maximumAttempts: 4, baseDelay: 0, maximumDelay: 0),
        resumeStore: MusicDownloadResumeStore(directory: root.appending(path: "resume")),
        targetAllocator: MusicDownloadTargetAllocator(),
        cacheRoot: cacheRoot
    )
    let song = Song(
        id: 1,
        name: "测试歌曲",
        artists: [ArtistSummary(id: 1, name: "测试歌手")],
        album: AlbumSummary(id: 1, name: "测试专辑", artwork: Artwork(symbol: "music.note", accent: .red)),
        duration: .seconds(1)
    )
    guard manager.enqueue(song: song, to: root, quality: .best, includeLyrics: false) else {
        throw MusicDownloadCheckError.failed
    }
    let result = try await completedDownload(from: manager, songID: song.id)
    guard ScriptedDownloadProtocol.requestCount(for: "/eapi/song/enhance/player/url/v1") == 4,
          result.audioURL.pathExtension == "flac",
          result.audioURL.lastPathComponent.contains("【无损】"),
          !result.audioURL.lastPathComponent.contains("[1]"),
          try Data(contentsOf: result.audioURL) == Data("fLaC".utf8)
    else { throw MusicDownloadCheckError.failed }

    let mediaRequests = ScriptedDownloadProtocol.requestCount(for: "/quality-audio")
    let cachedManager = MusicDownloadManager(
        transport: network.transport,
        session: network.session,
        maximumConcurrentDownloads: 1,
        retryPolicy: MusicDownloadRetryPolicy(maximumAttempts: 4, baseDelay: 0, maximumDelay: 0),
        resumeStore: MusicDownloadResumeStore(directory: root.appending(path: "cached-resume")),
        targetAllocator: MusicDownloadTargetAllocator(),
        cacheRoot: cacheRoot
    )
    let destination = root.appending(path: "cached-best", directoryHint: .isDirectory)
    guard cachedManager.enqueue(song: song, to: destination, quality: .best, includeLyrics: false) else {
        throw MusicDownloadCheckError.failed
    }
    let cached = try await completedDownload(from: cachedManager, songID: song.id)
    guard ScriptedDownloadProtocol.requestCount(for: "/quality-audio") == mediaRequests,
          cached.audioURL.lastPathComponent.contains("【无损】"),
          try Data(contentsOf: cached.audioURL) == Data("fLaC".utf8)
    else { throw MusicDownloadCheckError.failed }
}

@MainActor
private func verifySourceRetryAndParallelLyrics() async throws {
    let network = scriptedNetwork(.sourceRetry)
    defer { network.session.invalidateAndCancel() }
    let root = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let cacheRoot = root.appending(path: "cache", directoryHint: .isDirectory)
    let manager = MusicDownloadManager(
        transport: network.transport,
        session: network.session,
        maximumConcurrentDownloads: 1,
        retryPolicy: MusicDownloadRetryPolicy(maximumAttempts: 4, baseDelay: 0, maximumDelay: 0),
        resumeStore: MusicDownloadResumeStore(directory: root.appending(path: "resume")),
        targetAllocator: MusicDownloadTargetAllocator(),
        cacheRoot: cacheRoot
    )
    let song = Song(
        id: 2,
        name: "刷新音源",
        artists: [ArtistSummary(id: 2, name: "测试歌手")],
        album: AlbumSummary(id: 2, name: "测试专辑", artwork: Artwork(symbol: "music.note", accent: .blue)),
        duration: .seconds(1)
    )
    guard manager.enqueue(song: song, to: root, quality: .standard, includeLyrics: true) else {
        throw MusicDownloadCheckError.failed
    }
    let result = try await completedDownload(from: manager, songID: song.id)
    guard ScriptedDownloadProtocol.requestCount(for: "/eapi/song/music/detail/get") == 0,
          ScriptedDownloadProtocol.requestCount(for: "/eapi/v3/song/detail") == 0,
          ScriptedDownloadProtocol.requestCount(for: "/eapi/song/enhance/player/url/v1") == 3,
          ScriptedDownloadProtocol.requestCount(for: "/bad-audio") == 1,
          ScriptedDownloadProtocol.requestCount(for: "/good-audio") == 1,
          ScriptedDownloadProtocol.didDownloadBeforeLyricsCompleted,
          result.audioURL.pathExtension == "flac",
          result.audioURL.lastPathComponent.contains("【标准】"),
          !result.audioURL.lastPathComponent.contains("[2]"),
          try Data(contentsOf: result.audioURL) == Data("fLaC".utf8),
          result.lyricURL.map({ FileManager.default.fileExists(atPath: $0.path) }) == true,
          manager.items[song.id]?.quality == "标准"
    else { throw MusicDownloadCheckError.failed }

    let sourceRequests = ScriptedDownloadProtocol.requestCount(for: "/eapi/song/enhance/player/url/v1")
    let lyricRequests = ScriptedDownloadProtocol.requestCount(for: "/eapi/song/lyric")
    let audioRequests = ScriptedDownloadProtocol.requestCount(for: "/good-audio")
    let cachedDestination = root.appending(path: "cached-output", directoryHint: .isDirectory)
    let cachedManager = MusicDownloadManager(
        transport: network.transport,
        session: network.session,
        maximumConcurrentDownloads: 1,
        retryPolicy: MusicDownloadRetryPolicy(maximumAttempts: 1, baseDelay: 0, maximumDelay: 0),
        resumeStore: MusicDownloadResumeStore(directory: root.appending(path: "cached-resume")),
        targetAllocator: MusicDownloadTargetAllocator(),
        cacheRoot: cacheRoot
    )
    guard cachedManager.enqueue(song: song, to: cachedDestination, quality: .standard, includeLyrics: true) else {
        throw MusicDownloadCheckError.failed
    }
    let cachedResult = try await completedDownload(from: cachedManager, songID: song.id)
    guard ScriptedDownloadProtocol.requestCount(for: "/eapi/song/enhance/player/url/v1") == sourceRequests,
          ScriptedDownloadProtocol.requestCount(for: "/eapi/song/lyric") == lyricRequests,
          ScriptedDownloadProtocol.requestCount(for: "/good-audio") == audioRequests,
          cachedResult.audioURL.pathExtension == "flac",
          try Data(contentsOf: cachedResult.audioURL) == Data("fLaC".utf8),
          cachedResult.lyricURL.flatMap({ try? String(contentsOf: $0, encoding: .utf8) })?.contains("cached lyric") == true
    else { throw MusicDownloadCheckError.failed }
}

private func verifySourceValidation() async throws {
    let network = scriptedNetwork(.sourceValidation)
    defer { network.session.invalidateAndCancel() }

    for _ in 0..<3 {
        do {
            _ = try await MusicDownloadManager.audioSource(
                songID: 1,
                level: "lossless",
                requiresExactLevel: true,
                transport: network.transport
            )
            throw MusicDownloadCheckError.failed
        } catch MusicDownloadError.invalidResponse {}
    }

    let legacySource = try await MusicDownloadManager.audioSource(
        songID: 1,
        level: "lossless",
        requiresExactLevel: true,
        transport: network.transport
    )
    guard legacySource.url.scheme == "https", legacySource.url.host == "m1.music.126.net" else {
        throw MusicDownloadCheckError.failed
    }

    do {
        _ = try await MusicDownloadManager.audioSource(
            songID: 1,
            level: "lossless",
            requiresExactLevel: true,
            transport: network.transport
        )
        throw MusicDownloadCheckError.failed
    } catch MusicDownloadError.qualityMismatch {}

    guard ScriptedDownloadProtocol.requestCount(for: "/eapi/song/enhance/player/url/v1") == 5 else {
        throw MusicDownloadCheckError.failed
    }
}

private func verifyTransferSuccessAndCancellation() async throws {
    let network = scriptedNetwork(.transfer)
    defer { network.session.invalidateAndCancel() }
    let progress = DownloadProgressProbe()
    let transfer = MusicDownloadTransfer(session: network.session) { _, _, _ in progress.record() }
    defer { transfer.invalidate() }

    let success = try await transfer.download(
        request: URLRequest(url: URL(string: "https://example.com/transfer-success")!),
        resumeData: nil
    )
    defer { try? FileManager.default.removeItem(at: success.temporaryURL) }
    guard try Data(contentsOf: success.temporaryURL) == Data("fLaC".utf8), progress.didReport else {
        throw MusicDownloadCheckError.failed
    }

    let blocked = Task {
        try await transfer.download(
            request: URLRequest(url: URL(string: "https://example.com/transfer-block")!),
            resumeData: nil
        )
    }
    for _ in 0..<100 where ScriptedDownloadProtocol.requestCount(for: "/transfer-block") == 0 {
        try await Task.sleep(for: .milliseconds(10))
    }
    guard ScriptedDownloadProtocol.requestCount(for: "/transfer-block") == 1 else {
        blocked.cancel()
        throw MusicDownloadCheckError.failed
    }
    blocked.cancel()
    do {
        _ = try await blocked.value
        throw MusicDownloadCheckError.failed
    } catch is MusicDownloadTransferPaused {}
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
    try Data("fLaC".utf8).write(to: source)
    try MusicDownloadFiles.stageDownloadedFile(source, at: targets.audioPart)
    guard FileManager.default.fileExists(atPath: targets.audioPart.path),
          !FileManager.default.fileExists(atPath: targets.audioFinal.path)
    else { throw MusicDownloadCheckError.failed }

    try MusicDownloadFiles.commit(partURL: targets.audioPart, finalURL: targets.audioFinal)
    guard try Data(contentsOf: targets.audioFinal) == Data("fLaC".utf8),
          !FileManager.default.fileExists(atPath: targets.audioPart.path),
          MusicDownloadFiles.existingDownload(
              in: root,
              stem: "song",
              audioExtension: "mp3"
          )?.audioURL == targets.audioFinal
    else { throw MusicDownloadCheckError.failed }

    let invalidURL = root.appending(path: "invalid.mp3")
    try Data(#"{"code":200}"#.utf8).write(to: invalidURL)
    guard MusicDownloadFiles.existingDownload(
        in: root,
        stem: "invalid",
        audioExtension: "mp3"
    ) == nil else { throw MusicDownloadCheckError.failed }

    let emptySource = root.appending(path: "empty.tmp")
    let emptyFinal = root.appending(path: "empty.mp3")
    let emptyPart = emptyFinal.appendingPathExtension("part")
    try Data().write(to: emptySource)
    do {
        try MusicDownloadFiles.stageDownloadedFile(emptySource, at: emptyPart)
        throw MusicDownloadCheckError.failed
    } catch MusicDownloadError.emptyFile {
    }
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

    let merged = MusicDownloadManager.mergingProgress(
        [1: 0.6, 2: 0.8, 3: 0.9],
        into: [1: .running(progress: 0.4), 2: .running(progress: nil), 3: .cancelled]
    )
    guard merged[1] == .running(progress: 0.6),
          merged[2] == .running(progress: 0.8),
          merged[3] == .cancelled,
          MusicDownloadManager.mergingProgress([1: 0.2], into: merged)[1] == .running(progress: 0.6)
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

private func verifyRetryPolicyAndResumeStore() throws {
    let policy = MusicDownloadRetryPolicy(maximumAttempts: 4, baseDelay: 0.5, maximumDelay: 1.5)
    guard policy.maximumRetryCount == 3,
          policy.delay(forRetry: 1) == 0.5,
          policy.delay(forRetry: 2) == 1,
          policy.delay(forRetry: 3) == 1.5,
          policy.delay(forRetry: 1, retryAfter: 70) == 70,
          policy.shouldRetry(URLError(.networkConnectionLost)),
          policy.shouldRetry(MusicDownloadHTTPError(statusCode: 503, retryAfter: nil)),
          !policy.shouldRetry(MusicDownloadHTTPError(statusCode: 400, retryAfter: nil))
    else { throw MusicDownloadCheckError.failed }

    let retryAfterDelay = MusicDownloadManager.retryDelay(
        after: MusicDownloadHTTPError(statusCode: 429, retryAfter: 70),
        retry: 1,
        policy: policy
    )
    guard retryAfterDelay >= 70, retryAfterDelay <= 71 else {
        throw MusicDownloadCheckError.failed
    }

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

    let laterRequest = MusicDownloadRequest(
        songID: 100,
        songName: request.songName,
        artists: request.artists,
        destination: request.destination,
        quality: request.quality,
        includeLyrics: request.includeLyrics,
        source: request.source,
        expectedBytes: request.expectedBytes
    )
    store.save(request)
    Thread.sleep(forTimeInterval: 0.01)
    store.save(laterRequest)
    Thread.sleep(forTimeInterval: 0.01)
    store.save(request, resumeData: resumeBytes)
    guard store.recoverableDownloads().map(\.request.songID) == [99, 100] else {
        throw MusicDownloadCheckError.failed
    }
}

@MainActor
private func verifyDuplicateQualityIsSkipped() throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let manager = MusicDownloadManager(
        resumeStore: MusicDownloadResumeStore(directory: root.appending(path: "resume")),
        targetAllocator: MusicDownloadTargetAllocator()
    )
    let song = Song(
        id: 7,
        name: "Queue",
        artists: [ArtistSummary(id: 1, name: "Artist")],
        album: AlbumSummary(id: 1, name: "Album", artwork: Artwork(symbol: "music.note", accent: .red)),
        duration: .seconds(1)
    )
    let destination = root.appending(path: "first", directoryHint: .isDirectory)
    let otherDestination = root.appending(path: "second", directoryHint: .isDirectory)
    guard manager.enqueue(song: song, to: destination, quality: .standard, includeLyrics: false),
          !manager.enqueue(song: song, to: destination, quality: .standard, includeLyrics: false),
          manager.enqueue(song: song, to: otherDestination, quality: .standard, includeLyrics: false),
          manager.enqueue(song: song, to: otherDestination, quality: .lossless, includeLyrics: false)
    else { throw MusicDownloadCheckError.failed }
    manager.cancelAll()
}

@MainActor
private func verifyManagerRecoveryAndPause() async throws {
    let network = scriptedNetwork(.transfer)
    defer { network.session.invalidateAndCancel() }
    let root = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = MusicDownloadResumeStore(directory: root.appending(path: "resume"))
    let request = MusicDownloadRequest(
        songID: 404,
        songName: "Recover",
        artists: "Artist",
        destination: root.appending(path: "downloads", directoryHint: .isDirectory),
        quality: .standard,
        includeLyrics: false,
        source: .catalog,
        expectedBytes: nil
    )
    store.save(request)

    let manager = MusicDownloadManager(
        transport: network.transport,
        session: network.session,
        maximumConcurrentDownloads: 1,
        retryPolicy: MusicDownloadRetryPolicy(maximumAttempts: 1, baseDelay: 0, maximumDelay: 0),
        resumeStore: store,
        targetAllocator: MusicDownloadTargetAllocator()
    )
    guard manager.states[request.songID] == .running(progress: nil),
          manager.items[request.songID]?.title == request.songName
    else { throw MusicDownloadCheckError.failed }

    manager.pause(songID: request.songID)
    manager.retry(songID: request.songID)
    for _ in 0..<200 where manager.states[request.songID] != .running(progress: nil)
        || ScriptedDownloadProtocol.requestCount(for: "/eapi/song/enhance/player/url/v1") == 0 {
        try await Task.sleep(for: .milliseconds(10))
    }
    guard manager.states[request.songID] == .running(progress: nil) else {
        throw MusicDownloadCheckError.failed
    }
    manager.pause(songID: request.songID)
    await manager.pauseAll()
    guard case .paused? = manager.states[request.songID] else {
        throw MusicDownloadCheckError.failed
    }
    guard let recovered = store.recoverableDownloads().first?.request,
          recovered.songID == request.songID,
          recovered.songName == request.songName,
          recovered.artists == request.artists,
          recovered.destination.resolvingSymlinksInPath() == request.destination.resolvingSymlinksInPath(),
          recovered.quality == request.quality,
          recovered.includeLyrics == request.includeLyrics,
          recovered.source == request.source,
          recovered.expectedBytes == request.expectedBytes
    else {
        throw MusicDownloadCheckError.failed
    }

    let restarted = MusicDownloadManager(
        transport: network.transport,
        session: network.session,
        maximumConcurrentDownloads: 1,
        retryPolicy: MusicDownloadRetryPolicy(maximumAttempts: 1, baseDelay: 0, maximumDelay: 0),
        resumeStore: store,
        targetAllocator: MusicDownloadTargetAllocator()
    )
    guard restarted.isActive(songID: request.songID) else {
        throw MusicDownloadCheckError.failed
    }
    await restarted.pauseAll()
    restarted.cancel(songID: request.songID)
    guard store.recoverableDownloads().isEmpty else {
        throw MusicDownloadCheckError.failed
    }
}

#if MUSIC_DOWNLOAD_CHECK
@main
private enum MusicDownloadCheck {
    @MainActor
    static func main() async throws {
        try verifyMusicDownloadFiles()
        try verifyRetryPolicyAndResumeStore()
        try verifyDuplicateQualityIsSkipped()
        try await verifyManagerRecoveryAndPause()
        try await verifySourceValidation()
        try await verifyTransferSuccessAndCancellation()
        try await verifyHighestQualityFallback()
        try await verifySourceRetryAndParallelLyrics()
        print("Music download checks passed")
    }
}
#elseif canImport(Testing)
@Suite("Music download files", .serialized)
struct MusicDownloadTests {
    @Test("Filename cleanup and atomic finalization")
    func filenameAndAtomicFinalization() throws {
        try verifyMusicDownloadFiles()
    }

    @MainActor
    @Test("Best quality retries service failures and falls through available levels")
    func highestQualityFallback() async throws {
        try await verifyHighestQualityFallback()
    }

    @MainActor
    @Test("Source retry refreshes metadata while lyrics download in parallel")
    func sourceRetryAndParallelLyrics() async throws {
        try await verifySourceRetryAndParallelLyrics()
    }

    @Test("Audio sources validate song, upgrade trusted HTTP, and require exact lossless level")
    func sourceValidation() async throws {
        try await verifySourceValidation()
    }

    @Test("Download transfer succeeds and cancellation resumes without hanging")
    func transferSuccessAndCancellation() async throws {
        try await verifyTransferSuccessAndCancellation()
    }

    @Test("Retries use exponential backoff and persist matching resume data")
    func retryPolicyAndResumeStore() throws {
        try verifyRetryPolicyAndResumeStore()
    }

    @MainActor
    @Test("Only an identical active request is skipped")
    func duplicateQualityIsSkipped() throws {
        try verifyDuplicateQualityIsSkipped()
    }

    @MainActor
    @Test("Paused and queued requests recover after manager restart")
    func managerRecoveryAndPause() async throws {
        try await verifyManagerRecoveryAndPause()
    }
}
#endif
