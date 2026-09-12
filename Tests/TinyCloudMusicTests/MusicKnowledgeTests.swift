import Foundation

#if !MUSIC_KNOWLEDGE_CHECK && canImport(Testing)
import Testing
@testable import TinyCloudMusic
#endif

private enum MusicKnowledgeCheckError: Error {
    case failed
}

private func fixtureSong(id: Int64) -> [String: Any] {
    [
        "id": id,
        "name": "Song \(id)",
        "ar": [["id": 10, "name": "Artist"]],
        "al": ["id": 20, "name": "Album"],
        "dt": 1_000
    ]
}

private func decodedFixtureSong(_ value: [String: Any]) -> MusicStyleResource? {
    let id = value.int64("id")
    guard id > 0 else { return nil }
    return .song(Song(
        id: id,
        name: value.string("name"),
        artists: [ArtistSummary(id: 10, name: "Artist")],
        album: AlbumSummary(id: 20, name: "Album", artwork: Artwork(symbol: "square.stack", accent: .red)),
        duration: .seconds(1)
    ))
}

private func decodedFixturePlaylist(_ value: [String: Any]) -> MusicStyleResource? {
    let id = value.int64("id")
    guard id > 0 else { return nil }
    return .playlist(Playlist(
        id: id,
        name: value.string("name"),
        creator: "Creator",
        description: "",
        artwork: Artwork(symbol: "music.note.list", accent: .green),
        trackCount: 12
    ))
}

private func verifyStyleFixtures() throws {
    let styles = MusicKnowledgeDecoder.styles([
        "data": [[
            "tagId": "1000",
            "tagName": "语种",
            "childrenTags": [
                ["tagId": 1002, "tagName": "欧美"],
                ["tagId": "1001", "tagName": "华语"]
            ]
        ]]
    ])
    guard styles.map(\.id) == [1000], styles[0].children.map(\.id) == [1002, 1001] else {
        throw MusicKnowledgeCheckError.failed
    }

    let first = MusicKnowledgeDecoder.stylePage([
        "data": ["cursor": "next-page", "songs": [fixtureSong(id: 1), fixtureSong(id: 2)]]
    ], kind: .songs, decode: decodedFixtureSong)
    let second = MusicKnowledgeDecoder.stylePage([
        "data": ["songs": [fixtureSong(id: 2), fixtureSong(id: 3)]]
    ], kind: .songs, decode: decodedFixtureSong)
    guard first.items.map(\.id) == ["song-1", "song-2"],
          first.nextCursor == "next-page",
          first.appending(second).items.map(\.id) == ["song-1", "song-2", "song-3"],
          second.nextCursor == nil
    else { throw MusicKnowledgeCheckError.failed }

    let playlists = MusicKnowledgeDecoder.stylePage([
        "data": ["playlist": [["playlist": ["id": "9", "name": "Style Playlist"]]]]
    ], kind: .playlists, decode: decodedFixturePlaylist)
    guard playlists.items.map(\.id) == ["playlist-9"] else {
        throw MusicKnowledgeCheckError.failed
    }
}

private func verifyTemporaryCleanupBoundaries() async throws {
    let manager = FileManager.default
    let root = manager.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    let sheetRoot = root.appending(path: "sheet", directoryHint: .isDirectory)
    let exportRoot = root.appending(path: "export", directoryHint: .isDirectory)
    defer { try? manager.removeItem(at: root) }
    try manager.createDirectory(at: sheetRoot, withIntermediateDirectories: true)
    try manager.createDirectory(at: exportRoot, withIntermediateDirectories: true)

    let now = Date(timeIntervalSince1970: 2_000_000_000)
    let cutoff = now.addingTimeInterval(-24 * 60 * 60)
    @discardableResult
    func write(_ name: String, to directory: URL, modifiedAt date: Date) throws -> URL {
        let url = directory.appending(path: name)
        try Data([1]).write(to: url)
        try manager.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
        return url
    }

    let oldSheet = try write("old.pdf", to: sheetRoot, modifiedAt: cutoff.addingTimeInterval(-1))
    let recent = try write("recent.pdf", to: sheetRoot, modifiedAt: cutoff.addingTimeInterval(1))
    let boundary = try write("boundary.pdf", to: sheetRoot, modifiedAt: cutoff)
    let future = try write("future.pdf", to: sheetRoot, modifiedAt: now.addingTimeInterval(1))
    let directory = sheetRoot.appending(path: "nested", directoryHint: .isDirectory)
    try manager.createDirectory(at: directory, withIntermediateDirectories: true)
    let nested = try write("old.pdf", to: directory, modifiedAt: cutoff.addingTimeInterval(-1))
    try manager.setAttributes([.modificationDate: cutoff.addingTimeInterval(-1)], ofItemAtPath: directory.path)
    let symlinkTarget = try write("symlink-target.pdf", to: root, modifiedAt: cutoff.addingTimeInterval(-1))
    let symlink = sheetRoot.appending(path: "old-link.pdf")
    try manager.createSymbolicLink(at: symlink, withDestinationURL: symlinkTarget)
    let linkedRootTarget = root.appending(path: "linked-root-target", directoryHint: .isDirectory)
    try manager.createDirectory(at: linkedRootTarget, withIntermediateDirectories: true)
    let linkedRootFile = try write("old.pdf", to: linkedRootTarget, modifiedAt: cutoff.addingTimeInterval(-1))
    let linkedRoot = root.appending(path: "linked-root")
    try manager.createSymbolicLink(at: linkedRoot, withDestinationURL: linkedRootTarget)
    let oldExport = try write("old-export.jpg", to: exportRoot, modifiedAt: cutoff.addingTimeInterval(-1))

    let worker = MusicSheetWorker(temporaryRoot: sheetRoot)
    await worker.cleanupExpired(now: now)
    guard !manager.fileExists(atPath: oldSheet.path),
          manager.fileExists(atPath: oldExport.path),
          manager.fileExists(atPath: recent.path),
          manager.fileExists(atPath: boundary.path),
          manager.fileExists(atPath: future.path),
          manager.fileExists(atPath: directory.path),
          manager.fileExists(atPath: nested.path),
          manager.fileExists(atPath: symlink.path),
          manager.fileExists(atPath: symlinkTarget.path)
    else { throw MusicKnowledgeCheckError.failed }

    await worker.cleanupExpired(
        now: now,
        additionalRoots: [root.appending(path: "missing"), linkedRoot, exportRoot]
    )
    guard !manager.fileExists(atPath: oldExport.path),
          manager.fileExists(atPath: linkedRootFile.path)
    else {
        throw MusicKnowledgeCheckError.failed
    }

    let blockedRoot = root.appending(path: "blocked", directoryHint: .isDirectory)
    let healthyRoot = root.appending(path: "healthy", directoryHint: .isDirectory)
    try manager.createDirectory(at: blockedRoot, withIntermediateDirectories: true)
    try manager.createDirectory(at: healthyRoot, withIntermediateDirectories: true)
    let blocked = try write("blocked.pdf", to: blockedRoot, modifiedAt: cutoff.addingTimeInterval(-1))
    let healthy = try write("healthy.pdf", to: healthyRoot, modifiedAt: cutoff.addingTimeInterval(-1))
    try manager.setAttributes([.posixPermissions: 0o555], ofItemAtPath: blockedRoot.path)
    defer { try? manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: blockedRoot.path) }
    await worker.cleanupExpired(now: now, additionalRoots: [blockedRoot, healthyRoot])
    try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: blockedRoot.path)
    guard manager.fileExists(atPath: blocked.path),
          !manager.fileExists(atPath: healthy.path)
    else { throw MusicKnowledgeCheckError.failed }

    let cancelledFile = try write(
        "cancelled.pdf",
        to: sheetRoot,
        modifiedAt: cutoff.addingTimeInterval(-1)
    )
    let cancelledCleanup = Task {
        try? await Task.sleep(for: .seconds(60))
        await worker.cleanupExpired(now: now, additionalRoots: [exportRoot])
    }
    cancelledCleanup.cancel()
    await cancelledCleanup.value
    guard manager.fileExists(atPath: cancelledFile.path) else {
        throw MusicKnowledgeCheckError.failed
    }
}

private func verifySheetAndKnowledgeFixtures() async throws {
    let sheets = MusicKnowledgeDecoder.sheets([
        "data": ["musicSheetSimpleInfoVOS": [[
            "id": 171_018,
            "name": "总谱",
            "type": [["code": 100, "name": "总谱"]],
            "totalPageSize": 27
        ]]]
    ])
    guard sheets.count == 1,
          sheets[0].id == 171_018,
          sheets[0].instrument == "总谱",
          sheets[0].pageCount == 27
    else { throw MusicKnowledgeCheckError.failed }

    let preview = MusicKnowledgeDecoder.sheetPreview([
        "data": ["images": [
            "http://p1.music.126.net/legacy.jpg",
            "https://evil.example/page.jpg",
            "https://p1.music.126.net/one.jpg",
            "https://p1.music.126.net/two.jpg"
        ]]
    ])
    guard case let .images(urls) = preview,
          urls.map(\.lastPathComponent) == ["legacy.jpg", "one.jpg", "two.jpg"],
          urls.allSatisfy({ $0.scheme == "https" }),
          !MusicSheetURLPolicy.isAllowed(URL(string: "data:text/html,hello")!),
          !MusicSheetURLPolicy.isAllowed(URL(string: "https://music.126.net.evil.test/a.pdf")!),
          MusicKnowledgeDecoder.sheetPreview(["data": ["html": "<script/>"]]) == .unsupported
    else { throw MusicKnowledgeCheckError.failed }

    let arrayPreview = MusicKnowledgeDecoder.sheetPreview([
        "data": [["imageUrl": "http://p1.music.126.net/preview.jpg"]]
    ])
    guard case let .images(arrayURLs) = arrayPreview,
          arrayURLs.first?.absoluteString == "https://p1.music.126.net/preview.jpg"
    else { throw MusicKnowledgeCheckError.failed }

    let temporaryRoot = FileManager.default.temporaryDirectory.appending(
        path: UUID().uuidString,
        directoryHint: .isDirectory
    )
    let worker = MusicSheetWorker(temporaryRoot: temporaryRoot)
    defer { try? FileManager.default.removeItem(at: temporaryRoot) }
    try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
    let temporaryFile = temporaryRoot.appending(path: "expired.pdf")
    try Data("%PDF-test".utf8).write(to: temporaryFile)
    guard FileManager.default.fileExists(atPath: temporaryFile.path) else {
        throw MusicKnowledgeCheckError.failed
    }
    await worker.cleanupExpired(now: Date().addingTimeInterval(25 * 60 * 60))
    guard !FileManager.default.fileExists(atPath: temporaryFile.path) else {
        throw MusicKnowledgeCheckError.failed
    }

    let song = Song(
        id: 42,
        name: "恋人",
        artists: [ArtistSummary(id: 7, name: "李荣浩")],
        album: AlbumSummary(id: 8, name: "黑马", artwork: Artwork(symbol: "music.note", accent: .red)),
        duration: .seconds(240)
    )
    let downloadRoot = FileManager.default.temporaryDirectory.appending(
        path: UUID().uuidString,
        directoryHint: .isDirectory
    )
    defer { try? FileManager.default.removeItem(at: downloadRoot) }
    let firstPDF = downloadRoot.appending(path: "first.tmp")
    let updatedPDF = downloadRoot.appending(path: "updated.tmp")
    try FileManager.default.createDirectory(at: downloadRoot, withIntermediateDirectories: true)
    try Data("%PDF-first\n%%EOF".utf8).write(to: firstPDF)
    try Data("%PDF-updated\n%%EOF".utf8).write(to: updatedPDF)

    let cacheRoot = downloadRoot.appending(path: "cache", directoryHint: .isDirectory)
    let cachedPDF = try await worker.cachePDF(
        at: firstPDF,
        sheetID: sheets[0].id,
        cacheRoot: cacheRoot
    )
    guard cachedPDF.lastPathComponent == "171018.pdf",
          await worker.cachedPDF(sheetID: sheets[0].id, cacheRoot: cacheRoot) == cachedPDF,
          try Data(contentsOf: cachedPDF) == Data("%PDF-first\n%%EOF".utf8)
    else { throw MusicKnowledgeCheckError.failed }

    let firstSave = try await worker.savePDF(at: firstPDF, song: song, sheet: sheets[0], to: downloadRoot)
    let duplicateSave = try await worker.savePDF(at: updatedPDF, song: song, sheet: sheets[0], to: downloadRoot)
    guard firstSave.saved,
          !duplicateSave.saved,
          firstSave.url == duplicateSave.url,
          firstSave.url.lastPathComponent == "【总谱】李荣浩 - 恋人 [171018].pdf",
          try Data(contentsOf: firstSave.url) == Data("%PDF-first\n%%EOF".utf8),
          await worker.existingPDF(song: song, sheet: sheets[0], in: downloadRoot) == firstSave.url,
          MusicSheetFiles.fileName(
            song: song,
            sheet: MusicSheetSummary(id: 171_019, title: "总谱", instrument: "总谱", pageCount: 27)
          ) != firstSave.url.lastPathComponent
    else { throw MusicKnowledgeCheckError.failed }

    try Data("damaged".utf8).write(to: firstSave.url)
    let repairedSave = try await worker.savePDF(at: updatedPDF, song: song, sheet: sheets[0], to: downloadRoot)
    guard repairedSave.saved,
          repairedSave.url != firstSave.url,
          try Data(contentsOf: firstSave.url) == Data("damaged".utf8),
          try Data(contentsOf: repairedSave.url) == Data("%PDF-updated\n%%EOF".utf8)
    else { throw MusicKnowledgeCheckError.failed }

    let blocks = MusicKnowledgeDecoder.knowledgeBlocks([
        "data": ["blocks": [
            ["blockCode": "text", "title": "背景", "text": "一段说明"],
            ["blockCode": "bad", "payload": ["raw": true]],
            ["blockCode": "invalid", "resourceType": "album", "resourceId": 0, "title": "Invalid"],
            ["blockCode": "album", "resourceType": "album", "resourceId": "42", "title": "Album"]
        ]]
    ])
    guard blocks.count == 2,
          blocks.map(\.id) == ["knowledge-text", "knowledge-album"],
          case .resource(_, _, .album(42)) = blocks.last
    else { throw MusicKnowledgeCheckError.failed }

    let artistBlocks = MusicKnowledgeDecoder.knowledgeBlocks([
        "data": ["artist": [
            "briefDesc": "歌手简介",
            "introduction": [["ti": "早年经历", "txt": "成长故事"]]
        ]]
    ], prefix: "artist")
    let albumBlocks = MusicKnowledgeDecoder.knowledgeBlocks([
        "data": ["album": ["desc": "专辑故事"]]
    ], prefix: "album")
    guard artistBlocks.count == 2,
          case .text(_, "音乐百科", "歌手简介") = artistBlocks[0],
          case .text(_, "早年经历", "成长故事") = artistBlocks[1],
          case .text(_, "音乐百科", "专辑故事") = albumBlocks.first
    else { throw MusicKnowledgeCheckError.failed }

    let wiki = MusicKnowledgeDecoder.songWikiBlocks([
        "data": ["blocks": [
            [
                "code": "SONG_PLAY_ABOUT_SONG_BASIC",
                "creatives": [
                    [
                        "creativeType": "songTag",
                        "uiElement": ["mainTitle": ["title": "曲风"]],
                        "resources": [[
                            "resourceType": "melody_style",
                            "uiElement": ["mainTitle": ["title": "流行"]]
                        ]]
                    ],
                    [
                        "creativeType": "bpm",
                        "uiElement": [
                            "mainTitle": ["title": "BPM"],
                            "textLinks": [["text": "76"]]
                        ]
                    ],
                    [
                        "creativeType": "musicSheet",
                        "uiElement": [
                            "mainTitle": ["title": "乐谱"],
                            "textLinks": [["text": "2个"]]
                        ]
                    ]
                ]
            ],
            [
                "code": "SONG_PLAY_ABOUT_SIMILAR_SONG",
                "creatives": [[
                    "resources": [[
                        "resourceType": "PLAYLIST",
                        "resourceId": "99",
                        "uiElement": ["mainTitle": ["title": "不属于百科"]]
                    ]]
                ]]
            ]
        ]]
    ])
    guard wiki.count == 2,
          case let .text(_, "曲风", body) = wiki[0], body == "流行",
          case .metric(_, "BPM", "76") = wiki[1]
    else { throw MusicKnowledgeCheckError.failed }

    let metadata = [
        MusicKnowledgeBlock.text(id: "style", title: "曲风", body: "轻音乐"),
        .text(id: "tags", title: "推荐标签", body: "浪漫\n治愈\n学习\n放松"),
        .text(id: "language", title: "语种", body: "纯音乐"),
        .metric(id: "bpm", title: "BPM", value: "86"),
        .text(id: "sheet", title: "乐谱", body: "2个"),
        .text(id: "comment", title: "乐评", body: "不应显示")
    ].map(\.metadataItems).filter { !$0.isEmpty }
    let emptyMetadata = [
        MusicKnowledgeBlock.text(id: "style", title: "曲风", body: ""),
        .text(id: "comment", title: "乐评", body: "不应显示")
    ].flatMap(\.metadataItems)
    let rows = KnowledgeMetadataRows.indices(
        itemWidths: [40, 40, 40],
        separatorWidth: 4,
        separatorSpacings: [3, 9],
        width: 92
    )
    let reversedRows = KnowledgeMetadataRows.indices(
        itemWidths: [40, 40, 40],
        separatorWidth: 4,
        separatorSpacings: [9, 3],
        width: 92
    )
    guard metadata == [["轻音乐"], ["浪漫", "治愈", "学习", "放松"], ["纯音乐"], ["86 BPM"]],
          emptyMetadata.isEmpty,
          rows == [[0, 1], [2]],
          reversedRows == [[0], [1, 2]]
    else {
        throw MusicKnowledgeCheckError.failed
    }
}

#if MUSIC_KNOWLEDGE_CHECK
@main
private enum MusicKnowledgeCheck {
    static func main() async throws {
        try verifyStyleFixtures()
        try await verifyTemporaryCleanupBoundaries()
        try await verifySheetAndKnowledgeFixtures()
        print("Music knowledge check passed")
    }
}
#elseif canImport(Testing)
@Suite("Music knowledge")
struct MusicKnowledgeTests {
    @Test("Style hierarchy, cursor, and deduplication are retained")
    func styles() throws { try verifyStyleFixtures() }

    @Test("Temporary cleanup is direct, age-strict, symlink-safe, cancellable, and shared across roots")
    func temporaryCleanupBoundaries() async throws {
        try await verifyTemporaryCleanupBoundaries()
    }

    @Test("Sheet and knowledge content are safely decoded")
    func sheetsAndKnowledge() async throws { try await verifySheetAndKnowledgeFixtures() }
}
#endif
