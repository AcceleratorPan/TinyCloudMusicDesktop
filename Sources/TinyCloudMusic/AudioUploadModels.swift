import AVFoundation
import CryptoKit
import Darwin
import Foundation
import UniformTypeIdentifiers

enum AudioUploadDestination: Codable, Equatable, Sendable {
    case cloud
    case podcast(voiceListID: Int64)
}

enum AudioUploadPhase: Codable, Equatable, Sendable {
    case inspecting
    case hashing
    case allocating
    case uploading(completed: Int64, total: Int64)
    case registering
    case paused
    case reconciling
    case completed
    case cleanupPending(String)
    case failed(String)
}

struct AudioUploadMetadata: Codable, Equatable, Sendable {
    var title: String
    var artist: String
    var album: String
    let durationMilliseconds: Int64
    let bitrate: Int
}

struct PodcastUploadForm: Codable, Equatable, Sendable {
    var name: String
    var description: String
    let voiceListID: Int64
    let coverImageID: Int64
    let categoryID: Int64
    let secondCategoryID: Int64
    var composedSongIDs: [Int64] = []
    var isPrivate = false
    var publishTimeMilliseconds: Int64 = 0
    var order = 1
    let precheckDupkey: UUID
    let submitDupkey: UUID

    init(
        name: String,
        description: String,
        voiceListID: Int64,
        coverImageID: Int64,
        categoryID: Int64,
        secondCategoryID: Int64,
        composedSongIDs: [Int64] = [],
        isPrivate: Bool = false,
        publishTimeMilliseconds: Int64 = 0,
        order: Int = 1,
        precheckDupkey: UUID = UUID(),
        submitDupkey: UUID = UUID()
    ) {
        self.name = name
        self.description = description
        self.voiceListID = voiceListID
        self.coverImageID = coverImageID
        self.categoryID = categoryID
        self.secondCategoryID = secondCategoryID
        self.composedSongIDs = composedSongIDs
        self.isPrivate = isPrivate
        self.publishTimeMilliseconds = publishTimeMilliseconds
        self.order = order
        self.precheckDupkey = precheckDupkey
        self.submitDupkey = submitDupkey
    }

    func validated() throws -> Self {
        var value = self
        value.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        value.description = description.trimmingCharacters(in: .whitespacesAndNewlines)
        value.composedSongIDs = Array(Set(composedSongIDs.filter { $0 > 0 })).sorted()
        guard !value.name.isEmpty,
              value.voiceListID > 0,
              value.coverImageID > 0,
              value.categoryID > 0,
              value.secondCategoryID > 0,
              value.publishTimeMilliseconds >= 0,
              value.order > 0,
              value.precheckDupkey != value.submitDupkey
        else { throw AudioUploadError.invalidPodcastForm }
        return value
    }

    func voiceData(documentID: Int64) throws -> [[String: Any]] {
        let value = try validated()
        guard documentID > 0 else { throw AudioUploadError.invalidPodcastForm }
        return [[
            "name": value.name,
            "autoPublish": value.publishTimeMilliseconds == 0,
            "autoPublishText": "",
            "description": value.description,
            "voiceListId": value.voiceListID,
            "coverImgId": value.coverImageID,
            "dfsId": documentID,
            "categoryId": value.categoryID,
            "secondCategoryId": value.secondCategoryID,
            "composedSongs": value.composedSongIDs,
            "privacy": value.isPrivate,
            "publishTime": value.publishTimeMilliseconds,
            "orderNo": value.order
        ]]
    }
}

struct AudioUploadPart: Codable, Equatable, Sendable {
    let number: Int
    let etag: String
}

struct CloudUploadResume: Codable, Equatable, Sendable {
    var objectKey = ""
    var resourceID = ""
    var songID: Int64 = 0
    var confirmedOffset: Int64 = 0
    var registeredSongID: Int64?
}

struct PodcastUploadResume: Codable, Equatable, Sendable {
    static let partSize = 10 * 1_024 * 1_024

    var objectKey = ""
    var documentID: Int64 = 0
    var uploadID = ""
    var parts: [AudioUploadPart] = []
    var multipartCompleted = false
    var prechecked = false

    var uploadedPartNumbers: Set<Int> { Set(parts.lazy.map(\.number)) }
    var stableParts: [AudioUploadPart] {
        Dictionary(parts.map { ($0.number, $0) }, uniquingKeysWith: { current, _ in current })
            .values
            .sorted { $0.number < $1.number }
    }
}

struct AudioUploadManifest: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let accountID: Int64
    let destination: AudioUploadDestination
    let bookmark: Data
    let filename: String
    let fileExtension: String
    let contentType: String
    let byteCount: Int64
    let modificationTime: TimeInterval
    let md5: String
    var metadata: AudioUploadMetadata
    var podcastForm: PodcastUploadForm?
    var cloud = CloudUploadResume()
    var podcast = PodcastUploadResume()
    var phase: AudioUploadPhase = .paused
    var savedAt = Date()
}

struct AudioUploadItem: Equatable, Identifiable, Sendable {
    let id: UUID
    let destination: AudioUploadDestination
    let filename: String
    var byteCount: Int64
    var metadata: AudioUploadMetadata?
    var podcastForm: PodcastUploadForm?
    var phase: AudioUploadPhase
    var isPrepared: Bool { metadata != nil }
}

enum AudioUploadError: LocalizedError, Equatable {
    case notRegularFile
    case emptyFile
    case unreadableFile
    case unsupportedType
    case fileChanged
    case invalidBookmark
    case invalidPodcastForm
    case invalidUploadHost
    case invalidServerOffset
    case missingUploadIdentifier
    case missingETag
    case resultUnknown

    var errorDescription: String? {
        switch self {
        case .notRegularFile: "只能上传普通音频文件"
        case .emptyFile: "音频文件为空"
        case .unreadableFile: "无法读取所选音频"
        case .unsupportedType: "服务不支持这种音频格式"
        case .fileChanged: "源文件已发生变化，请重新选择"
        case .invalidBookmark: "无法恢复源文件访问权限"
        case .invalidPodcastForm: "播客名称、封面或分类信息不完整"
        case .invalidUploadHost: "上传服务器地址不受信任"
        case .invalidServerOffset: "服务器没有确认可恢复的上传位置"
        case .missingUploadIdentifier: "服务未返回上传会话标识"
        case .missingETag: "服务未确认上传分片"
        case .resultUnknown: "提交结果未知，已停止自动重试"
        }
    }
}

enum AudioUploadInspector {
    static let supportedExtensions = Set(["mp3", "m4a", "aac", "flac", "wav", "aiff", "aif", "ogg"])
    private static let readSize = 1_024 * 1_024

    static func inspect(
        _ url: URL,
        accountID: Int64,
        destination: AudioUploadDestination,
        podcastForm: PodcastUploadForm?
    ) async throws -> AudioUploadManifest {
        guard accountID > 0, url.isFileURL else { throw AudioUploadError.unreadableFile }
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }

        let keys: Set<URLResourceKey> = [
            .isRegularFileKey, .isReadableKey, .fileSizeKey, .contentModificationDateKey
        ]
        let values = try url.resourceValues(forKeys: keys)
        guard values.isRegularFile == true else { throw AudioUploadError.notRegularFile }
        guard values.isReadable != false else { throw AudioUploadError.unreadableFile }
        guard let size = values.fileSize, size > 0 else { throw AudioUploadError.emptyFile }
        let ext = url.pathExtension.lowercased()
        guard supportedExtensions.contains(ext),
              let type = UTType(filenameExtension: ext),
              type.conforms(to: .audio)
        else { throw AudioUploadError.unsupportedType }

        let bookmark = try url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        let metadata = try await mediaMetadata(url: url, fallbackTitle: url.deletingPathExtension().lastPathComponent)
        return AudioUploadManifest(
            id: UUID(),
            accountID: accountID,
            destination: destination,
            bookmark: bookmark,
            filename: sanitizedFilename(url.lastPathComponent),
            fileExtension: ext,
            contentType: type.preferredMIMEType ?? "audio/\(ext)",
            byteCount: Int64(size),
            modificationTime: values.contentModificationDate?.timeIntervalSince1970 ?? 0,
            md5: try hashFile(url),
            metadata: metadata,
            podcastForm: podcastForm
        )
    }

    struct SourceIdentity: Equatable, Sendable {
        let byteCount: Int64
        let modificationTime: TimeInterval
        let fileNumber: UInt64?
        let changeTimeNanoseconds: Int64
    }

    struct ResolvedSource: Sendable {
        let url: URL
        let identity: SourceIdentity
    }

    static func resolve(
        _ manifest: AudioUploadManifest,
        cachedIdentity: SourceIdentity? = nil,
        hash: @Sendable (URL) throws -> String = { try hashFile($0) }
    ) async throws -> ResolvedSource {
        var stale = false
        let url: URL
        do {
            url = try URL(
                resolvingBookmarkData: manifest.bookmark,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            )
        } catch {
            stale = false
            url = try URL(
                resolvingBookmarkData: manifest.bookmark,
                options: [],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            )
        }
        guard !stale, url.isFileURL else { throw AudioUploadError.invalidBookmark }
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        let identity = try await sourceIdentity(url)
        guard identity.byteCount == manifest.byteCount,
              abs(identity.modificationTime - manifest.modificationTime) < 1
        else { throw AudioUploadError.fileChanged }
        if cachedIdentity != identity || identity.fileNumber == nil {
            guard try hash(url).caseInsensitiveCompare(manifest.md5) == .orderedSame else {
                throw AudioUploadError.fileChanged
            }
        }
        return ResolvedSource(url: url, identity: identity)
    }

    static func sourceIdentity(_ url: URL) async throws -> SourceIdentity {
        let values = try url.resourceValues(forKeys: [
            .isRegularFileKey, .fileSizeKey, .contentModificationDateKey
        ])
        guard values.isRegularFile == true else { throw AudioUploadError.notRegularFile }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        var status = stat()
        guard url.withUnsafeFileSystemRepresentation({ lstat($0, &status) }) == 0 else {
            throw AudioUploadError.unreadableFile
        }
        return SourceIdentity(
            byteCount: Int64(values.fileSize ?? -1),
            modificationTime: values.contentModificationDate?.timeIntervalSince1970 ?? 0,
            fileNumber: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value,
            changeTimeNanoseconds: Int64(status.st_ctimespec.tv_sec) * 1_000_000_000
                + Int64(status.st_ctimespec.tv_nsec)
        )
    }

    static func hashFile(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var digest = Insecure.MD5()
        while true {
            try Task.checkCancellation()
            guard let data = try handle.read(upToCount: readSize), !data.isEmpty else { break }
            digest.update(data: data)
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func sanitizedFilename(_ value: String) -> String {
        let forbidden = CharacterSet.controlCharacters.union(CharacterSet(charactersIn: "/\\:"))
        let cleaned = value.unicodeScalars.map { forbidden.contains($0) ? "_" : String($0) }.joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return "audio" }
        let ext = (cleaned as NSString).pathExtension
        let base = (cleaned as NSString).deletingPathExtension
        let suffix = ext.isEmpty ? "" : "." + String(ext.prefix(16))
        return String((base.isEmpty ? "audio" : base).prefix(180 - suffix.count)) + suffix
    }

    private static func mediaMetadata(url: URL, fallbackTitle: String) async throws -> AudioUploadMetadata {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty else { throw AudioUploadError.unsupportedType }
        let duration = try await asset.load(.duration)
        let metadata = try await asset.load(.commonMetadata)
        let bitrate = max(0, Int(try await tracks[0].load(.estimatedDataRate)))

        func value(_ identifier: AVMetadataIdentifier) async -> String {
            guard let item = metadata.first(where: { $0.identifier == identifier }) else { return "" }
            return (try? await item.load(.stringValue))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        let title = await value(.commonIdentifierTitle)
        return AudioUploadMetadata(
            title: title.isEmpty ? fallbackTitle : title,
            artist: await value(.commonIdentifierArtist),
            album: await value(.commonIdentifierAlbumName),
            durationMilliseconds: duration.isNumeric
                ? max(0, Int64((CMTimeGetSeconds(duration) * 1_000).rounded()))
                : 0,
            bitrate: bitrate
        )
    }
}

struct AudioUploadLoadResult: Sendable {
    let manifests: [AudioUploadManifest]
    let diagnostics: [String]
}

actor AudioUploadStore {
    private struct PendingCheckpoint: Sendable {
        let revision: UInt64
        let manifest: AudioUploadManifest
    }

    private struct CheckpointFailure: LocalizedError, Sendable {
        let message: String
        var errorDescription: String? { message }
    }

    static let shared = AudioUploadStore()
    private let directory: URL
    private let fileManager: FileManager
    private let removeItem: (URL) throws -> Void
    private let beforeSave: @Sendable (AudioUploadManifest) async throws -> Void
    private let beforeRemove: @Sendable (UUID) async throws -> Void
    private let checkpointDelay: Duration
    private var revisions: [UUID: UInt64] = [:]
    private var pendingCheckpoints: [UUID: PendingCheckpoint] = [:]
    private var checkpointFailures: [UUID: CheckpointFailure] = [:]
    private var checkpointTask: Task<Void, Never>?
    private var writesInFlight: Set<UUID> = []
    private var writeWaiters: [UUID: [CheckedContinuation<Void, Never>]] = [:]

    init(
        directory: URL? = nil,
        fileManager: FileManager = .default,
        removeItem: ((URL) throws -> Void)? = nil,
        beforeSave: (@Sendable (AudioUploadManifest) async throws -> Void)? = nil,
        beforeRemove: (@Sendable (UUID) async throws -> Void)? = nil,
        checkpointDelay: Duration = .milliseconds(250)
    ) {
        self.fileManager = fileManager
        self.removeItem = removeItem ?? { try fileManager.removeItem(at: $0) }
        self.beforeSave = beforeSave ?? { _ in }
        self.beforeRemove = beforeRemove ?? { _ in }
        self.checkpointDelay = checkpointDelay
        self.directory = directory ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "TinyCloudMusic/AudioUploads", directoryHint: .isDirectory)
    }

    func load() throws -> AudioUploadLoadResult {
        guard fileManager.fileExists(atPath: directory.path) else {
            return AudioUploadLoadResult(manifests: [], diagnostics: [])
        }
        let urls = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        var manifests: [AudioUploadManifest] = []
        var diagnostics: [String] = []
        for url in urls.filter({ $0.pathExtension == "json" }) {
            do {
                manifests.append(try JSONDecoder().decode(AudioUploadManifest.self, from: Data(contentsOf: url)))
            } catch {
                let quarantined = url.appendingPathExtension("corrupt-\(UUID().uuidString)")
                do {
                    try fileManager.moveItem(at: url, to: quarantined)
                    diagnostics.append("已隔离损坏的上传记录：\(url.lastPathComponent)")
                } catch {
                    diagnostics.append("无法读取或隔离上传记录：\(url.lastPathComponent)")
                }
            }
        }
        return AudioUploadLoadResult(manifests: manifests, diagnostics: diagnostics)
    }

    func save(_ manifest: AudioUploadManifest) async throws {
        let checkpoint = replacePending(with: manifest)
        pendingCheckpoints[manifest.id] = checkpoint
        try await drainPendingCheckpoint(manifest.id)
    }

    func checkpoint(_ manifest: AudioUploadManifest) throws {
        let checkpoint = replacePending(with: manifest)
        pendingCheckpoints[manifest.id] = checkpoint
        if let failure = checkpointFailures[manifest.id] { throw failure }
        scheduleCheckpointWrite()
    }

    func remove(_ id: UUID) async throws {
        let revision = nextRevision(for: id)
        pendingCheckpoints.removeValue(forKey: id)
        checkpointFailures.removeValue(forKey: id)
        while writesInFlight.contains(id) { await waitForWrite(id) }
        try await beforeRemove(id)
        guard revisions[id] == revision else { return }
        let url = url(id)
        if fileManager.fileExists(atPath: url.path) { try removeItem(url) }
    }

    func flush() async throws {
        if let checkpointTask {
            checkpointTask.cancel()
            await checkpointTask.value
            self.checkpointTask = nil
        }
        do {
            repeat {
                while let id = writesInFlight.first { await waitForWrite(id) }
                try await drainPendingCheckpoints()
            } while !writesInFlight.isEmpty || !pendingCheckpoints.isEmpty
        } catch {
            scheduleCheckpointWriteIfPossible()
            throw error
        }
        if let failure = checkpointFailures.values.first { throw failure }
    }

    private func replacePending(with manifest: AudioUploadManifest) -> PendingCheckpoint {
        let checkpoint = PendingCheckpoint(revision: nextRevision(for: manifest.id), manifest: manifest)
        pendingCheckpoints.removeValue(forKey: manifest.id)
        return checkpoint
    }

    private func nextRevision(for id: UUID) -> UInt64 {
        revisions[id, default: 0] &+= 1
        return revisions[id, default: 0]
    }

    private func scheduleCheckpointWrite() {
        guard checkpointTask == nil else { return }
        let delay = checkpointDelay
        checkpointTask = Task { [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            await self?.drainScheduledCheckpoints()
        }
    }

    private func scheduleCheckpointWriteIfPossible() {
        guard checkpointFailures.isEmpty, !pendingCheckpoints.isEmpty else { return }
        scheduleCheckpointWrite()
    }

    private func drainScheduledCheckpoints() async {
        do {
            try await drainPendingCheckpoints()
        } catch {
            // The next checkpoint or an explicit flush surfaces and retries the durable failure.
        }
        checkpointTask = nil
        scheduleCheckpointWriteIfPossible()
    }

    private func drainPendingCheckpoints() async throws {
        while let id = pendingCheckpoints.keys.first {
            try await drainPendingCheckpoint(id)
        }
    }

    private func drainPendingCheckpoint(_ id: UUID) async throws {
        while true {
            if writesInFlight.contains(id) {
                await waitForWrite(id)
                continue
            }
            guard let checkpoint = pendingCheckpoints.removeValue(forKey: id) else { return }
            do {
                if try await write(checkpoint) { checkpointFailures.removeValue(forKey: id) }
            } catch {
                restore(checkpoint, after: error)
                throw error
            }
        }
    }

    private func write(_ checkpoint: PendingCheckpoint) async throws -> Bool {
        let id = checkpoint.manifest.id
        writesInFlight.insert(id)
        defer { finishWrite(id) }
        try await beforeSave(checkpoint.manifest)
        guard revisions[id] == checkpoint.revision else { return false }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(checkpoint.manifest).write(
            to: url(id),
            options: .atomic
        )
        return true
    }

    private func waitForWrite(_ id: UUID) async {
        await withCheckedContinuation { writeWaiters[id, default: []].append($0) }
    }

    private func finishWrite(_ id: UUID) {
        writesInFlight.remove(id)
        let waiters = writeWaiters.removeValue(forKey: id) ?? []
        waiters.forEach { $0.resume() }
    }

    private func restore(_ checkpoint: PendingCheckpoint, after error: Error) {
        let id = checkpoint.manifest.id
        guard revisions[id] == checkpoint.revision else { return }
        if pendingCheckpoints[id] == nil { pendingCheckpoints[id] = checkpoint }
        checkpointFailures[id] = CheckpointFailure(message: error.localizedDescription)
    }

    private func url(_ id: UUID) -> URL { directory.appending(path: id.uuidString).appendingPathExtension("json") }
}
