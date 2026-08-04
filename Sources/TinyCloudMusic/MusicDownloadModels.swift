import Foundation
import Darwin

enum MusicDownloadState: Equatable, Sendable {
    case queued
    case running(progress: Double?)
    case paused(progress: Double?)
    case completed(audioURL: URL, lyricURL: URL?)
    case failed(String)
    case cancelled
}

struct MusicDownloadItem: Identifiable, Equatable, Sendable {
    let id: Int64
    let title: String
    let artist: String
    let quality: String
    let expectedBytes: Int64?
}

struct MusicDownloadRequest: Equatable, Sendable {
    let songID: Int64
    let songName: String
    let artists: String
    let destination: URL
    let quality: AudioQuality
    let includeLyrics: Bool
    let source: MusicDownloadSource
    let expectedBytes: Int64?
    let expectedCredentialRevision: UInt64?

    init(
        songID: Int64,
        songName: String,
        artists: String,
        destination: URL,
        quality: AudioQuality,
        includeLyrics: Bool,
        source: MusicDownloadSource,
        expectedBytes: Int64?,
        expectedCredentialRevision: UInt64? = nil
    ) {
        self.songID = songID
        self.songName = songName
        self.artists = artists
        self.destination = destination
        self.quality = quality
        self.includeLyrics = includeLyrics
        self.source = source
        self.expectedBytes = expectedBytes
        self.expectedCredentialRevision = expectedCredentialRevision
    }

    func bindingCloudCredentialRevision(_ revision: UInt64) -> Self {
        Self(
            songID: songID,
            songName: songName,
            artists: artists,
            destination: destination,
            quality: quality,
            includeLyrics: includeLyrics,
            source: source,
            expectedBytes: expectedBytes,
            expectedCredentialRevision: revision
        )
    }
}

enum MusicDownloadSource: Equatable, Sendable {
    case catalog
    case cloud(userID: Int64, fileName: String)
}

struct MusicDownloadResult: Sendable {
    let audioURL: URL
    let lyricURL: URL?
}

enum MusicDownloadError: LocalizedError, Equatable, Sendable {
    case unavailable
    case qualityMismatch
    case invalidResponse
    case emptyFile
    case insufficientSpace
    case destinationExists

    var errorDescription: String? {
        switch self {
        case .unavailable: "这首歌暂时无法下载"
        case .qualityMismatch: "服务端未返回要求的最高音质，已取消下载以避免降质"
        case .invalidResponse: "音频下载请求失败"
        case .emptyFile: "下载文件为空"
        case .insufficientSpace: "下载目录可用空间不足"
        case .destinationExists: "下载目标已存在"
        }
    }
}

struct MusicDownloadTargets: Sendable {
    let audioFinal: URL
    let audioPart: URL
    let lyricFinal: URL
    let lyricPart: URL
}

enum MusicDownloadFiles {
    private struct ManagedIdentity: Codable {
        let version: Int
        let songID: Int64
        let source: String
        let quality: AudioQuality
        let verifiedBytes: Int64
    }

    private static let managedIdentityAttribute = "com.tinycloudmusic.download.identity"

    private static let invalidCharacters = CharacterSet(charactersIn: "\\/:*?\"<>|")
        .union(.controlCharacters)

    static func sanitizedFileName(_ value: String) -> String {
        let cleaned = value.unicodeScalars
            .filter { !invalidCharacters.contains($0) }
            .map(String.init)
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned == "." || cleaned == ".." ? "" : cleaned
    }

    static func availableTargets(
        in directory: URL,
        stem: String,
        audioExtension: String,
        fileManager: FileManager = .default
    ) -> MusicDownloadTargets {
        var index = 1
        while true {
            let suffix = index == 1 ? "" : " (\(index))"
            let base = stem + suffix
            let audioFinal = directory.appending(path: base).appendingPathExtension(audioExtension)
            let lyricFinal = directory.appending(path: base).appendingPathExtension("lrc")
            if [audioFinal, lyricFinal].allSatisfy({ !fileManager.fileExists(atPath: $0.path) }) {
                let token = UUID().uuidString
                return MusicDownloadTargets(
                    audioFinal: audioFinal,
                    audioPart: audioFinal.appendingPathExtension("\(token).part"),
                    lyricFinal: lyricFinal,
                    lyricPart: lyricFinal.appendingPathExtension("\(token).part")
                )
            }
            index += 1
        }
    }

    static func existingDownload(
        in directory: URL,
        stem: String,
        audioExtension: String,
        matchingAudio source: URL? = nil,
        fileManager: FileManager = .default
    ) -> MusicDownloadResult? {
        let audioURL = directory.appending(path: stem).appendingPathExtension(audioExtension)
        guard fileManager.fileExists(atPath: audioURL.path),
              (try? validatedAudioFileSize(at: audioURL)) != nil,
              source.map({ fileManager.contentsEqual(atPath: audioURL.path, andPath: $0.path) }) ?? true
        else { return nil }
        let lyricURL = directory.appending(path: stem).appendingPathExtension("lrc")
        return MusicDownloadResult(
            audioURL: audioURL,
            lyricURL: fileManager.fileExists(atPath: lyricURL.path) ? lyricURL : nil
        )
    }

    static func managedDownload(
        for request: MusicDownloadRequest,
        fileManager: FileManager = .default
    ) -> MusicDownloadResult? {
        let hasSecurityScope = request.destination.startAccessingSecurityScopedResource()
        defer { if hasSecurityScope { request.destination.stopAccessingSecurityScopedResource() } }
        let expectedSource = sourceIdentity(for: request)
        let audioExtensions = managedAudioExtensions(for: request)
        for stem in managedDownloadStems(for: request) {
            var index = 1
            while true {
                let suffix = index == 1 ? "" : " (\(index))"
                let base = stem + suffix
                let lyricURL = request.destination.appending(path: base).appendingPathExtension("lrc")
                var hasCandidate = fileManager.fileExists(atPath: lyricURL.path)
                for audioExtension in audioExtensions {
                    let audioURL = request.destination.appending(path: base).appendingPathExtension(audioExtension)
                    guard fileManager.fileExists(atPath: audioURL.path) else { continue }
                    hasCandidate = true
                    guard let identity = managedIdentity(at: audioURL),
                          identity.version == 1,
                          identity.songID == request.songID,
                          identity.source == expectedSource,
                          identity.quality == request.quality,
                          (try? validatedAudioFileSize(at: audioURL)) == identity.verifiedBytes
                    else { continue }
                    return MusicDownloadResult(
                        audioURL: audioURL,
                        lyricURL: fileManager.fileExists(atPath: lyricURL.path) ? lyricURL : nil
                    )
                }
                guard hasCandidate else { break }
                index += 1
            }
        }
        return nil
    }

    static func writeManagedIdentity(
        for request: MusicDownloadRequest,
        audioURL: URL,
        fileManager: FileManager = .default
    ) throws {
        let size = try validatedAudioFileSize(at: audioURL)
        let identity = ManagedIdentity(
            version: 1,
            songID: request.songID,
            source: sourceIdentity(for: request),
            quality: request.quality,
            verifiedBytes: size
        )
        let data = try PropertyListEncoder().encode(identity)
        let result = data.withUnsafeBytes { bytes in
            audioURL.path.withCString { path in
                managedIdentityAttribute.withCString { name in
                    setxattr(path, name, bytes.baseAddress, bytes.count, 0, 0)
                }
            }
        }
        if result != 0 {
            let code = errno
            guard code == ENOTSUP || code == EOPNOTSUPP else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
            }
        }
        try? fileManager.removeItem(at: legacyManagedIdentityURL(for: audioURL))
    }

    static func removeManagedIdentity(for audioURL: URL, fileManager: FileManager = .default) {
        audioURL.path.withCString { path in
            managedIdentityAttribute.withCString { name in
                _ = removexattr(path, name, 0)
            }
        }
        try? fileManager.removeItem(at: legacyManagedIdentityURL(for: audioURL))
    }

    static func downloadStem(for request: MusicDownloadRequest, level: String?) -> String {
        let prefix = request.artists.isEmpty ? request.songName : "\(request.artists) - \(request.songName)"
        let label = level.map { "【\(qualityLabel($0))】" } ?? ""
        let cleaned = sanitizedFileName(label + prefix)
        var usedBytes = 0
        let shortened = cleaned.prefix { character in
            let count = String(character).utf8.count
            guard usedBytes + count <= 180 else { return false }
            usedBytes += count
            return true
        }
        return shortened.isEmpty ? "歌曲" : String(shortened)
    }

    static func sanitizedAudioExtension(_ value: String) -> String {
        let result = value.lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
        return result.isEmpty ? "mp3" : String(result.prefix(10))
    }

    static func stageDownloadedFile(
        _ source: URL,
        at partURL: URL,
        fileManager: FileManager = .default
    ) throws {
        try? fileManager.removeItem(at: partURL)
        do {
            try fileManager.moveItem(at: source, to: partURL)
            guard try fileSize(at: partURL) > 0 else { throw MusicDownloadError.emptyFile }
        } catch {
            try? fileManager.removeItem(at: partURL)
            throw error
        }
    }

    static func stageCachedFile(
        _ source: URL,
        at partURL: URL,
        fileManager: FileManager = .default
    ) throws {
        try? fileManager.removeItem(at: partURL)
        do {
            try fileManager.copyItem(at: source, to: partURL)
            guard try fileSize(at: partURL) > 0 else { throw MusicDownloadError.emptyFile }
        } catch {
            try? fileManager.removeItem(at: partURL)
            throw error
        }
    }

    static func cachedLyrics(
        for request: MusicDownloadRequest,
        cacheRoot: URL,
        context: MusicDownloadCacheContext? = nil,
        generation: MusicDownloadCacheGeneration? = nil
    ) -> String? {
        if let context, let generation, !generation.isCurrent(context) { return nil }
        let root = lyricCacheURL(for: request, cacheRoot: cacheRoot)
        let hasSecurityScope = cacheRoot.startAccessingSecurityScopedResource()
        defer { if hasSecurityScope { cacheRoot.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: root),
              !data.isEmpty,
              let lyrics = String(data: data, encoding: .utf8),
              !lyrics.isEmpty
        else { return nil }
        return lyrics
    }

    static func cacheLyrics(
        _ lyrics: String,
        for request: MusicDownloadRequest,
        cacheRoot: URL,
        context: MusicDownloadCacheContext? = nil,
        generation: MusicDownloadCacheGeneration? = nil,
        activity: MusicDownloadCacheActivity? = nil
    ) throws {
        guard !lyrics.isEmpty else { return }
        let url = lyricCacheURL(for: request, cacheRoot: cacheRoot)
        if let context, let generation {
            activity?.begin()
            defer { activity?.end() }
            guard generation.isCurrent(context) else { return }
        }
        let hasSecurityScope = cacheRoot.startAccessingSecurityScopedResource()
        defer { if hasSecurityScope { cacheRoot.stopAccessingSecurityScopedResource() } }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let context, let generation else {
            try Data(lyrics.utf8).write(to: url, options: .atomic)
            return
        }
        let part = url.appendingPathExtension("\(UUID().uuidString).part")
        defer { try? FileManager.default.removeItem(at: part) }
        try Data(lyrics.utf8).write(to: part, options: .atomic)
        _ = try generation.withCurrent(context) {
            if FileManager.default.fileExists(atPath: url.path) {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: part)
            } else {
                try FileManager.default.moveItem(at: part, to: url)
            }
        }
    }

    static func stageData(
        _ data: Data,
        at partURL: URL,
        fileManager: FileManager = .default
    ) throws {
        guard !data.isEmpty else { throw MusicDownloadError.emptyFile }
        try? fileManager.removeItem(at: partURL)
        do {
            try data.write(to: partURL, options: .atomic)
            guard try fileSize(at: partURL) > 0 else { throw MusicDownloadError.emptyFile }
        } catch {
            try? fileManager.removeItem(at: partURL)
            throw error
        }
    }

    static func commit(
        partURL: URL,
        finalURL: URL,
        fileManager: FileManager = .default
    ) throws {
        guard try fileSize(at: partURL) > 0 else { throw MusicDownloadError.emptyFile }
        guard !fileManager.fileExists(atPath: finalURL.path) else { throw MusicDownloadError.destinationExists }
        try fileManager.moveItem(at: partURL, to: finalURL)
    }

    static func validatedAudioFileSize(at url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        let size = Int64(values.fileSize ?? 0)
        guard values.isRegularFile == true, size > 0 else { throw MusicDownloadError.invalidResponse }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let bytes = [UInt8](try handle.read(upToCount: 16) ?? Data())
        guard looksLikeAudio(bytes) else { throw MusicDownloadError.invalidResponse }
        return size
    }

    private static func looksLikeAudio(_ bytes: [UInt8]) -> Bool {
        func matches(_ value: String, at offset: Int = 0) -> Bool {
            let pattern = Array(value.utf8)
            guard bytes.count >= offset + pattern.count else { return false }
            return bytes[offset..<(offset + pattern.count)].elementsEqual(pattern)
        }
        return matches("ID3")
            || matches("fLaC")
            || matches("OggS")
            || matches("RIFF")
            || matches("ftyp", at: 4)
            || (bytes.count >= 2 && bytes[0] == 0xff && bytes[1] & 0xe0 == 0xe0)
    }

    private static func fileSize(at url: URL) throws -> Int {
        try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
    }

    private static func lyricCacheURL(for request: MusicDownloadRequest, cacheRoot: URL) -> URL {
        let source = switch request.source {
        case .catalog: "catalog"
        case let .cloud(userID, _): "cloud-\(userID)"
        }
        return cacheRoot
            .appending(path: "DownloadCache", directoryHint: .isDirectory)
            .appending(path: "Lyrics", directoryHint: .isDirectory)
            .appending(path: source, directoryHint: .isDirectory)
            .appending(path: "\(request.songID).lrc", directoryHint: .notDirectory)
    }

    private static func sourceIdentity(for request: MusicDownloadRequest) -> String {
        switch request.source {
        case .catalog: "catalog"
        case let .cloud(userID, fileName): "cloud:\(userID):\(fileName)"
        }
    }

    private static func managedIdentity(at audioURL: URL) -> ManagedIdentity? {
        let size = audioURL.path.withCString { path in
            managedIdentityAttribute.withCString { name in
                getxattr(path, name, nil, 0, 0, 0)
            }
        }
        guard size > 0, size <= 65_536 else { return nil }
        var data = Data(count: size)
        let read = data.withUnsafeMutableBytes { bytes in
            audioURL.path.withCString { path in
                managedIdentityAttribute.withCString { name in
                    getxattr(path, name, bytes.baseAddress, bytes.count, 0, 0)
                }
            }
        }
        guard read == size else { return nil }
        return try? PropertyListDecoder().decode(ManagedIdentity.self, from: data)
    }

    private static func managedDownloadStems(for request: MusicDownloadRequest) -> [String] {
        let levels: [String?] = switch request.source {
        case .cloud: [nil]
        case .catalog:
            switch request.quality {
            case .standard: ["standard"]
            case .lossless: ["lossless"]
            case .best: SongQualityDetail.orderedLevels.reversed().map(Optional.some)
            }
        }
        return levels.reduce(into: []) { result, level in
            let stem = downloadStem(for: request, level: level)
            if !result.contains(stem) { result.append(stem) }
        }
    }

    private static func managedAudioExtensions(for request: MusicDownloadRequest) -> [String] {
        var result = ["mp3", "flac", "m4a"]
        if case let .cloud(_, fileName) = request.source {
            let value = sanitizedAudioExtension(URL(fileURLWithPath: fileName).pathExtension)
            if !result.contains(value) { result.insert(value, at: 0) }
        }
        return result
    }

    static func qualityLabel(_ level: String) -> String {
        switch level {
        case "standard": "标准"
        case "higher": "较高"
        case "exhigh": "极高"
        case "lossless": "无损"
        case "hires": "Hi-Res"
        case "jyeffect": "高清环绕声"
        case "sky": "沉浸环绕声"
        case "jymaster": "超清母带"
        case "dolby": "杜比全景声"
        default: level
        }
    }

    private static func legacyManagedIdentityURL(for audioURL: URL) -> URL {
        let key = Data(audioURL.lastPathComponent.utf8).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")
        return audioURL.deletingLastPathComponent()
            .appending(path: ".TinyCloudMusic.\(key).plist", directoryHint: .notDirectory)
    }
}

struct MusicDownloadProgressThrottle {
    private let minimumInterval: TimeInterval
    private var lastProgress: Double?
    private var lastUpdateTime: TimeInterval?

    init(minimumInterval: TimeInterval = 0.1) {
        self.minimumInterval = max(0, minimumInterval)
    }

    mutating func update(
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64,
        responseExpectedContentLength: Int64 = NSURLSessionTransferSizeUnknown,
        now: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> Double? {
        let expectedBytes = responseExpectedContentLength > 0
            ? responseExpectedContentLength
            : totalBytesExpectedToWrite
        guard expectedBytes > 0 else { return nil }
        let value = min(max(Double(totalBytesWritten) / Double(expectedBytes), 0), 1)
        guard lastProgress.map({ value > $0 }) ?? true,
              value == 1 || lastUpdateTime.map({ now - $0 >= minimumInterval }) ?? true
        else { return nil }
        lastProgress = value
        lastUpdateTime = now
        return value
    }
}

final class MusicDownloadProgressReporter: @unchecked Sendable {
    private let weight: Double
    private let output: @Sendable (Double) -> Void
    private let lock = NSLock()
    private var throttle: MusicDownloadProgressThrottle
    private var expectedBytes: Int64?
    private var latestValue: Double?
    private var lastOutput: Double?

    init(
        weight: Double = 1,
        minimumInterval: TimeInterval = 0.1,
        output: @escaping @Sendable (Double) -> Void
    ) {
        self.weight = min(max(weight, 0), 1)
        self.output = output
        throttle = MusicDownloadProgressThrottle(minimumInterval: minimumInterval)
    }

    func setExpectedBytes(_ value: Int64?) {
        lock.withLock { expectedBytes = value }
    }

    func update(
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64,
        responseExpectedContentLength: Int64
    ) {
        let value = lock.withLock { () -> Double? in
            let expected = expectedBytes ?? (responseExpectedContentLength > 0
                ? responseExpectedContentLength
                : totalBytesExpectedToWrite)
            if expected > 0 {
                latestValue = min(max(Double(totalBytesWritten) / Double(expected), 0), 1) * weight
            }
            guard let value = throttle.update(
                totalBytesWritten: totalBytesWritten,
                totalBytesExpectedToWrite: totalBytesExpectedToWrite,
                responseExpectedContentLength: expectedBytes ?? responseExpectedContentLength
            ) else { return nil }
            let weighted = value * weight
            lastOutput = weighted
            return weighted
        }
        if let value { output(value) }
    }

    func flush() {
        let value = lock.withLock { () -> Double? in
            guard let latestValue, lastOutput.map({ latestValue > $0 }) ?? true else { return nil }
            lastOutput = latestValue
            return latestValue
        }
        if let value { output(value) }
    }

    func finish() {
        let value = lock.withLock { () -> Double? in
            guard lastOutput != 1 else { return nil }
            latestValue = 1
            lastOutput = 1
            return 1
        }
        if let value { output(value) }
    }
}
