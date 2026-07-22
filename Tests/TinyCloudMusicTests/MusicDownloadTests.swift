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
            body = Data(#"{"code":200,"data":{"url":"https://example.com/audio.flac","type":"flac","level":"lossless"}}"#.utf8)
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
        source: .catalog
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
          !FileManager.default.fileExists(atPath: targets.audioPart.path)
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

    var progress = MusicDownloadProgressThrottle()
    guard progress.update(totalBytesWritten: 1, totalBytesExpectedToWrite: 100) == 0.01,
          progress.update(totalBytesWritten: 1, totalBytesExpectedToWrite: 100) == nil,
          progress.update(totalBytesWritten: 2, totalBytesExpectedToWrite: 100) == 0.02,
          progress.update(totalBytesWritten: 1, totalBytesExpectedToWrite: 100) == nil
    else { throw MusicDownloadCheckError.failed }
}
}

#if MUSIC_DOWNLOAD_CHECK
@main
private enum MusicDownloadCheck {
    static func main() async throws {
        try verifyMusicDownloadFiles()
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
}
#endif
