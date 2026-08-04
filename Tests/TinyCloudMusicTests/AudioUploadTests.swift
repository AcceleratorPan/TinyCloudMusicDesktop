import Foundation

#if !AUDIO_UPLOAD_CHECK && canImport(Testing)
import Testing
@testable import TinyCloudMusic
#endif

private enum AudioUploadCheckError: Error {
    case failed(String)
}

private final class ConfirmedOffsets: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Int64] = []

    func append(_ value: Int64) { lock.withLock { values.append(value) } }
    func snapshot() -> [Int64] { lock.withLock { values } }
}

private final class AudioUploadProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var requests: [URLRequest] = []
    nonisolated(unsafe) private static var bodies: [Data] = []

    static func reset() {
        lock.withLock {
            requests = []
            bodies = []
        }
    }

    static func captured() -> [(URLRequest, Data)] {
        lock.withLock { Array(zip(requests, bodies)) }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body = requestBody(request)
        Self.lock.withLock {
            Self.requests.append(request)
            Self.bodies.append(body)
        }
        let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)
        let query = Dictionary(uniqueKeysWithValues: (components?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        let responseBody: Data
        var headers: [String: String] = [:]
        if components?.query == "uploads" {
            responseBody = Data("<InitiateMultipartUploadResult><UploadId>upload-1</UploadId></InitiateMultipartUploadResult>".utf8)
        } else if let part = query["partNumber"] {
            responseBody = Data()
            headers["ETag"] = "etag-\(part)"
        } else if query["uploadId"] != nil {
            responseBody = Data()
        } else if query["complete"] == "false", let offset = Int64(query["offset"] ?? "") {
            responseBody = Data()
            headers["x-nos-next-append-position"] = String(offset + Int64(body.count))
        } else {
            responseBody = Data()
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: headers
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: responseBody)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private func requestBody(_ request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var body = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            body.append(buffer, count: count)
        }
        return body
    }
}

private func uploadManifest(byteCount: Int64, bookmark: Data = Data()) -> AudioUploadManifest {
    AudioUploadManifest(
        id: UUID(),
        accountID: 7,
        destination: .cloud,
        bookmark: bookmark,
        filename: "track.mp3",
        fileExtension: "mp3",
        contentType: "audio/mpeg",
        byteCount: byteCount,
        modificationTime: 1,
        md5: "900150983cd24fb0d6963f7d28e17f72",
        metadata: AudioUploadMetadata(
            title: "Track",
            artist: "Artist",
            album: "Album",
            durationMilliseconds: 1_000,
            bitrate: 320_000
        )
    )
}

private func verifyAudioUploadCore() async throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "TinyCloudMusicTests.\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let hashFile = root.appending(path: "hash.bin")
    try Data("abc".utf8).write(to: hashFile)
    guard try AudioUploadInspector.hashFile(hashFile) == "900150983cd24fb0d6963f7d28e17f72" else {
        throw AudioUploadCheckError.failed("Streaming MD5 mismatch")
    }

    guard NOSUploadURL.isAllowed(URL(string: "https://nosup-hz1.127.net/object")!),
          NOSUploadURL.isAllowed(URL(string: "https://ymusic.nos-hz.163yun.com/object")!),
          !NOSUploadURL.isAllowed(URL(string: "http://nosup-hz1.127.net/object")!),
          !NOSUploadURL.isAllowed(URL(string: "https://nosup-hz1.127.net.evil.test/object")!),
          SensitiveHeaderRedirectPolicy.allows(
            originalURL: URL(string: "https://music.163.com/weapi/upload")!,
            redirectedURL: URL(string: "https://music.163.com/weapi/upload-2")!
          ),
          !SensitiveHeaderRedirectPolicy.allows(
            originalURL: URL(string: "https://music.163.com/weapi/upload")!,
            redirectedURL: URL(string: "https://evil.test/steal")!
          )
    else { throw AudioUploadCheckError.failed("NOS host policy mismatch") }

    let form = PodcastUploadForm(
        name: "Episode",
        description: "Description",
        voiceListID: 11,
        coverImageID: 12,
        categoryID: 13,
        secondCategoryID: 14
    )
    let voice = try form.voiceData(documentID: 15)[0]
    guard voice["dfsId"] as? Int64 == 15,
          form.precheckDupkey != form.submitDupkey,
          voice["voiceListId"] as? Int64 == 11
    else { throw AudioUploadCheckError.failed("Podcast form contract mismatch") }

    let store = AudioUploadStore(directory: root.appending(path: "store"))
    let stored = uploadManifest(byteCount: 3, bookmark: Data("bookmark".utf8))
    try await store.save(stored)
    guard try await store.load().manifests == [stored],
          let storedData = try? Data(contentsOf: root.appending(path: "store/\(stored.id.uuidString).json")),
          !String(decoding: storedData, as: UTF8.self).contains("nos-token")
    else { throw AudioUploadCheckError.failed("Upload manifest persistence mismatch") }

    let manager = await MainActor.run {
        AudioUploadManager(
            musicLibrary: LiveMusicLibrary(transport: EAPITransport()),
            audioLibrary: LiveAudioContentLibrary(transport: EAPITransport()),
            store: store
        )
    }
    await manager.waitUntilLoaded()
    await manager.setAccount(8)
    guard await manager.items.isEmpty else { throw AudioUploadCheckError.failed("Account manifests leaked") }
    await manager.setAccount(7)
    guard await manager.items[stored.id]?.phase == .paused else {
        throw AudioUploadCheckError.failed("Recovered manifest was not user-paused")
    }
    await manager.start(stored.id)
    guard try await store.load().manifests.first(where: { $0.id == stored.id })?.phase == .allocating else {
        throw AudioUploadCheckError.failed("Upload phase was overwritten while saving")
    }
    await manager.cancel(stored.id)

    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [AudioUploadProtocol.self]
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    let upload = NOSAudioUpload(session: session)
    let allocation = NOSAllocation(
        token: "nos-token",
        objectKey: "folder/track.mp3",
        resourceID: "resource-1",
        documentID: 15
    )
    let audioFile = root.appending(path: "audio.mp3")
    let audioData = Data(repeating: 7, count: NOSAudioUpload.chunkSize + 3)
    try audioData.write(to: audioFile)
    let manifest = uploadManifest(byteCount: Int64(audioData.count))

    AudioUploadProtocol.reset()
    let offsets = ConfirmedOffsets()
    try await upload.uploadCloud(
        fileURL: audioFile,
        manifest: manifest,
        allocation: allocation,
        uploadBase: URL(string: "https://nosup-hz1.127.net")!,
        confirmedOffset: 0,
        shouldPause: { false },
        didConfirm: { offset in offsets.append(offset) },
        progress: { _, _ in }
    )
    guard offsets.snapshot() == [Int64(NOSAudioUpload.chunkSize), Int64(audioData.count)] else {
        throw AudioUploadCheckError.failed("Cloud offsets were not server-confirmed")
    }

    AudioUploadProtocol.reset()
    let uploadID = try await upload.initiatePodcastMultipart(
        allocation: allocation,
        contentType: manifest.contentType
    )
    let first = try await upload.uploadPodcastPart(
        fileURL: audioFile,
        manifest: manifest,
        allocation: allocation,
        uploadID: uploadID,
        partNumber: 1,
        progress: { _, _ in }
    )
    let second = try await upload.uploadPodcastPart(
        fileURL: audioFile,
        manifest: manifest,
        allocation: allocation,
        uploadID: uploadID,
        partNumber: 2,
        progress: { _, _ in }
    )
    try await upload.completePodcastMultipart(
        allocation: allocation,
        uploadID: uploadID,
        contentType: manifest.contentType,
        parts: [second, first]
    )
    let captured = AudioUploadProtocol.captured()
    guard first == AudioUploadPart(number: 1, etag: "etag-1"),
          second == AudioUploadPart(number: 2, etag: "etag-2"),
          captured.map(\.1.count).contains(NOSAudioUpload.chunkSize),
          captured.map(\.1.count).contains(3),
          let xml = String(data: captured.last?.1 ?? Data(), encoding: .utf8),
          xml.contains("<PartNumber>1</PartNumber><ETag>etag-1</ETag>"),
          xml.contains("<PartNumber>2</PartNumber><ETag>etag-2</ETag>")
    else { throw AudioUploadCheckError.failed("Multipart contract mismatch") }
}

#if AUDIO_UPLOAD_CHECK
@main
private enum AudioUploadCheck {
    static func main() async throws {
        try await verifyAudioUploadCore()
        print("Audio upload check passed")
    }
}
#elseif canImport(Testing)
@Suite("Cloud and podcast upload")
struct AudioUploadTests {
    @Test("Streaming, host, resume, and multipart contracts")
    func core() async throws { try await verifyAudioUploadCore() }
}
#endif
