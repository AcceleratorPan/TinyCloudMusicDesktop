import Foundation

struct NOSAllocation: Equatable, Sendable {
    let token: String
    let objectKey: String
    let resourceID: String
    let documentID: Int64
}

struct CloudUploadCheck: Equatable, Sendable {
    let needsUpload: Bool
    let songID: Int64
}

enum NOSUploadURL {
    static func isAllowed(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https",
              url.user == nil,
              url.password == nil,
              url.port == nil || url.port == 443,
              let host = url.host?.lowercased()
        else { return false }
        return host.hasSuffix(".127.net") || host.hasSuffix(".163yun.com")
    }

    static func objectURL(base: URL, bucket: String?, objectKey: String) throws -> URL {
        guard isAllowed(base), !objectKey.isEmpty, !objectKey.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else { throw AudioUploadError.invalidUploadHost }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        guard let encodedObject = objectKey.addingPercentEncoding(withAllowedCharacters: allowed) else {
            throw AudioUploadError.invalidUploadHost
        }
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
        let prefix = [components?.percentEncodedPath, bucket].compactMap { value in
            guard let value, !value.isEmpty else { return nil }
            return value.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }.joined(separator: "/")
        components?.percentEncodedPath = "/" + [prefix, encodedObject].filter { !$0.isEmpty }.joined(separator: "/")
        components?.query = nil
        guard let url = components?.url, isAllowed(url) else { throw AudioUploadError.invalidUploadHost }
        return url
    }
}

final class UploadProgressCoalescer: @unchecked Sendable {
    private let lock = NSLock()
    private let progress: @Sendable (Int64, Int64) -> Void
    private let minimumIntervalNanoseconds: UInt64
    private var lastEmission: UInt64 = 0
    private var lastCompleted: Int64 = -1
    private var latest: (completed: Int64, total: Int64)?

    init(
        minimumInterval: Duration = .milliseconds(100),
        progress: @escaping @Sendable (Int64, Int64) -> Void
    ) {
        minimumIntervalNanoseconds = UInt64(max(
            0,
            minimumInterval.components.seconds * 1_000_000_000
                + minimumInterval.components.attoseconds / 1_000_000_000
        ))
        self.progress = progress
    }

    func submit(_ completed: Int64, total: Int64, force: Bool = false) {
        let value = lock.withLock { () -> (Int64, Int64)? in
            let completed = min(max(0, completed), max(0, total))
            latest = (completed, total)
            let now = DispatchTime.now().uptimeNanoseconds
            let significant = completed - lastCompleted >= max(1, total / 100)
            guard force
                    || lastCompleted < 0
                    || (total > 0 && completed == total)
                    || significant
                    || now &- lastEmission >= minimumIntervalNanoseconds
            else { return nil }
            lastEmission = now
            lastCompleted = completed
            return (completed, total)
        }
        if let value { progress(value.0, value.1) }
    }

    func flush() {
        let value: (completed: Int64, total: Int64)? = lock.withLock {
            guard let latest, latest.completed != lastCompleted else { return nil }
            return latest
        }
        guard let value else { return }
        submit(value.completed, total: value.total, force: true)
    }
}

private final class NOSRequestDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let originalHost: String?
    private let base: Int64
    private let total: Int64
    private let progress: UploadProgressCoalescer

    init(url: URL, base: Int64, total: Int64, progress: @escaping @Sendable (Int64, Int64) -> Void) {
        originalHost = url.host?.lowercased()
        self.base = base
        self.total = total
        self.progress = UploadProgressCoalescer(progress: progress)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        progress.submit(min(total, base + totalBytesSent), total: total)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let url = request.url,
              NOSUploadURL.isAllowed(url),
              url.host?.lowercased() == originalHost
        else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }

    func flushProgress() { progress.flush() }
}

private final class UploadIDParser: NSObject, XMLParserDelegate {
    private(set) var uploadID = ""
    private var capturesUploadID = false

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?, attributes attributeDict: [String: String] = [:]) {
        capturesUploadID = elementName == "UploadId"
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if capturesUploadID { uploadID += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
        if elementName == "UploadId" { capturesUploadID = false }
    }
}

struct NOSAudioUpload: Sendable {
    static let cloudBucket = "jd-musicrep-privatecloud-audio-public"
    static let podcastBucket = "ymusic"
    static let chunkSize = 10 * 1_024 * 1_024

    let session: URLSession

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpShouldSetCookies = false
            configuration.timeoutIntervalForRequest = 60
            configuration.timeoutIntervalForResource = 5 * 60
            self.session = URLSession(configuration: configuration)
        }
    }

    func cloudUploadBase() async throws -> URL {
        var components = URLComponents(string: "https://wanproxy.127.net/lbs")!
        components.queryItems = [
            URLQueryItem(name: "version", value: "1.0"),
            URLQueryItem(name: "bucketname", value: Self.cloudBucket)
        ]
        guard let url = components.url else { throw AudioUploadError.invalidUploadHost }
        let (data, _) = try await perform(URLRequest(url: url), progress: { _, _ in })
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawURL = (root["upload"] as? [String])?.first,
              let uploadURL = URL(string: rawURL),
              NOSUploadURL.isAllowed(uploadURL)
        else { throw AudioUploadError.invalidUploadHost }
        return uploadURL
    }

    func uploadCloud(
        fileURL: URL,
        manifest: AudioUploadManifest,
        allocation: NOSAllocation,
        uploadBase: URL,
        confirmedOffset: Int64,
        authorize: @escaping @Sendable () async throws -> Void = {},
        shouldPause: @escaping @Sendable () async -> Bool,
        didConfirm: @escaping @Sendable (Int64) async throws -> Void,
        progress: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws {
        guard confirmedOffset >= 0, confirmedOffset <= manifest.byteCount else {
            throw AudioUploadError.invalidServerOffset
        }
        let objectURL = try NOSUploadURL.objectURL(
            base: uploadBase,
            bucket: Self.cloudBucket,
            objectKey: allocation.objectKey
        )
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        var offset = confirmedOffset
        while offset < manifest.byteCount {
            if await shouldPause() { throw CancellationError() }
            try handle.seek(toOffset: UInt64(offset))
            let count = min(Int64(Self.chunkSize), manifest.byteCount - offset)
            guard let data = try handle.read(upToCount: Int(count)), Int64(data.count) == count else {
                throw AudioUploadError.fileChanged
            }
            let isFinal = offset + count == manifest.byteCount
            var components = URLComponents(url: objectURL, resolvingAgainstBaseURL: false)!
            components.queryItems = [
                URLQueryItem(name: "offset", value: String(offset)),
                URLQueryItem(name: "complete", value: String(isFinal)),
                URLQueryItem(name: "version", value: "1.0")
            ]
            var request = URLRequest(url: components.url!, timeoutInterval: 5 * 60)
            request.httpMethod = "POST"
            request.httpBody = data
            request.setValue(allocation.token, forHTTPHeaderField: "x-nos-token")
            request.setValue(manifest.md5, forHTTPHeaderField: "Content-MD5")
            request.setValue(manifest.contentType, forHTTPHeaderField: "Content-Type")
            request.setValue(String(data.count), forHTTPHeaderField: "Content-Length")
            let (body, response) = try await perform(
                request,
                base: offset,
                total: manifest.byteCount,
                authorize: authorize,
                progress: progress
            )
            let expected = offset + count
            let serverOffset = isFinal ? expected : self.confirmedOffset(from: response, body: body)
            guard serverOffset == expected else { throw AudioUploadError.invalidServerOffset }
            offset = expected
            try await didConfirm(offset)
            progress(offset, manifest.byteCount)
        }
    }

    func initiatePodcastMultipart(
        allocation: NOSAllocation,
        contentType: String,
        authorize: @escaping @Sendable () async throws -> Void = {}
    ) async throws -> String {
        var components = URLComponents(url: try podcastObjectURL(allocation.objectKey), resolvingAgainstBaseURL: false)!
        components.query = "uploads"
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.setValue(allocation.token, forHTTPHeaderField: "x-nos-token")
        request.setValue(contentType, forHTTPHeaderField: "X-Nos-Meta-Content-Type")
        let (data, _) = try await perform(request, authorize: authorize, progress: { _, _ in })
        let delegate = UploadIDParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse(), !delegate.uploadID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AudioUploadError.missingUploadIdentifier
        }
        return delegate.uploadID.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func uploadPodcastPart(
        fileURL: URL,
        manifest: AudioUploadManifest,
        allocation: NOSAllocation,
        uploadID: String,
        partNumber: Int,
        authorize: @escaping @Sendable () async throws -> Void = {},
        progress: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws -> AudioUploadPart {
        guard !uploadID.isEmpty, partNumber > 0 else { throw AudioUploadError.missingUploadIdentifier }
        let offset = Int64(partNumber - 1) * Int64(PodcastUploadResume.partSize)
        let count = min(Int64(PodcastUploadResume.partSize), manifest.byteCount - offset)
        guard count > 0 else { throw AudioUploadError.invalidServerOffset }
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(offset))
        guard let data = try handle.read(upToCount: Int(count)), Int64(data.count) == count else {
            throw AudioUploadError.fileChanged
        }
        var components = URLComponents(url: try podcastObjectURL(allocation.objectKey), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "partNumber", value: String(partNumber)),
            URLQueryItem(name: "uploadId", value: uploadID)
        ]
        var request = URLRequest(url: components.url!, timeoutInterval: 5 * 60)
        request.httpMethod = "PUT"
        request.httpBody = data
        request.setValue(allocation.token, forHTTPHeaderField: "x-nos-token")
        request.setValue(manifest.contentType, forHTTPHeaderField: "Content-Type")

        var lastError: Error = AudioUploadError.missingETag
        for attempt in 0..<3 {
            do {
                let (_, response) = try await perform(
                    request,
                    base: offset,
                    total: manifest.byteCount,
                    authorize: authorize,
                    progress: progress
                )
                guard let etag = response.value(forHTTPHeaderField: "ETag")?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !etag.isEmpty
                else { throw AudioUploadError.missingETag }
                progress(offset + count, manifest.byteCount)
                return AudioUploadPart(number: partNumber, etag: etag)
            } catch {
                lastError = error
                guard attempt < 2, isTransient(error) else { throw error }
                try await Task.sleep(for: .milliseconds(250 << attempt))
            }
        }
        throw lastError
    }

    func completePodcastMultipart(
        allocation: NOSAllocation,
        uploadID: String,
        contentType: String,
        parts: [AudioUploadPart],
        authorize: @escaping @Sendable () async throws -> Void = {}
    ) async throws {
        guard !uploadID.isEmpty, !parts.isEmpty else { throw AudioUploadError.missingUploadIdentifier }
        let root = XMLElement(name: "CompleteMultipartUpload")
        var resume = PodcastUploadResume()
        resume.parts = parts
        for part in resume.stableParts {
            let element = XMLElement(name: "Part")
            element.addChild(XMLElement(name: "PartNumber", stringValue: String(part.number)))
            element.addChild(XMLElement(name: "ETag", stringValue: part.etag))
            root.addChild(element)
        }
        let body = XMLDocument(rootElement: root).xmlData(options: [.nodeCompactEmptyElement])
        var components = URLComponents(url: try podcastObjectURL(allocation.objectKey), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "uploadId", value: uploadID)]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue(allocation.token, forHTTPHeaderField: "x-nos-token")
        request.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue(contentType, forHTTPHeaderField: "X-Nos-Meta-Content-Type")
        _ = try await perform(request, authorize: authorize, progress: { _, _ in })
    }

    private func podcastObjectURL(_ objectKey: String) throws -> URL {
        try NOSUploadURL.objectURL(
            base: URL(string: "https://ymusic.nos-hz.163yun.com")!,
            bucket: nil,
            objectKey: objectKey
        )
    }

    private func perform(
        _ request: URLRequest,
        base: Int64 = 0,
        total: Int64 = 0,
        authorize: @escaping @Sendable () async throws -> Void = {},
        progress: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws -> (Data, HTTPURLResponse) {
        guard let url = request.url, NOSUploadURL.isAllowed(url) else { throw AudioUploadError.invalidUploadHost }
        let delegate = NOSRequestDelegate(url: url, base: base, total: total, progress: progress)
        do {
            try await authorize()
            let (data, response) = try await session.data(for: request, delegate: delegate)
            delegate.flushProgress()
            guard let http = response as? HTTPURLResponse else { throw EAPIError.invalidResponse }
            guard (200..<300).contains(http.statusCode) else { throw EAPIError.http(http.statusCode) }
            return (data, http)
        } catch {
            delegate.flushProgress()
            throw error
        }
    }

    private func confirmedOffset(from response: HTTPURLResponse, body: Data) -> Int64? {
        for field in ["x-nos-next-append-position", "x-nos-offset", "offset"] {
            if let value = response.value(forHTTPHeaderField: field), let offset = Int64(value) { return offset }
        }
        guard let root = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return nil }
        if let value = root["offset"] as? NSNumber { return value.int64Value }
        if let value = root["offset"] as? String { return Int64(value) }
        return nil
    }

    private func isTransient(_ error: Error) -> Bool {
        if let error = error as? URLError {
            return [.timedOut, .networkConnectionLost, .cannotConnectToHost, .notConnectedToInternet].contains(error.code)
        }
        if case let EAPIError.http(status) = error {
            return status == 408 || status == 429 || (500...599).contains(status)
        }
        return false
    }
}
