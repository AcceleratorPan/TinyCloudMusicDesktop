import Foundation

struct MusicStyle: Identifiable, Equatable, Sendable {
    let id: Int64
    let name: String
    let children: [MusicStyle]
}

struct MusicStyleDetail: Equatable, Sendable {
    let id: Int64
    let name: String
    let description: String
    let coverURL: URL?
}

enum MusicStyleResourceKind: String, CaseIterable, Hashable, Sendable {
    case songs = "歌曲"
    case albums = "专辑"
    case artists = "歌手"
    case playlists = "歌单"

    var symbol: String {
        switch self {
        case .songs: "music.note"
        case .albums: "square.stack"
        case .artists: "music.mic"
        case .playlists: "music.note.list"
        }
    }
}

enum MusicStyleResource: Identifiable, Equatable, Sendable {
    case song(Song)
    case album(Album)
    case artist(Artist)
    case playlist(Playlist)

    var id: String {
        switch self {
        case let .song(value): "song-\(value.id)"
        case let .album(value): "album-\(value.id)"
        case let .artist(value): "artist-\(value.id)"
        case let .playlist(value): "playlist-\(value.id)"
        }
    }

    var route: Route? {
        switch self {
        case .song: nil
        case let .album(value): .album(value.id)
        case let .artist(value): .artist(value.id)
        case let .playlist(value): .playlist(value.id)
        }
    }
}

struct MusicStylePage: Equatable, Sendable {
    let items: [MusicStyleResource]
    let nextCursor: String?

    func appending(_ page: Self) -> Self {
        let existing = Set(items.map(\.id))
        return Self(
            items: items + page.items.filter { !existing.contains($0.id) },
            nextCursor: page.nextCursor
        )
    }
}

struct MusicSheetSummary: Identifiable, Equatable, Sendable {
    let id: Int64
    let title: String
    let instrument: String?
    let pageCount: Int?
}

enum MusicSheetPreview: Equatable, Sendable {
    case images([URL])
    case pdf(URL)
    case unsupported
}

enum MusicKnowledgeBlock: Identifiable, Equatable, Sendable {
    case text(id: String, title: String, body: String)
    case image(id: String, url: URL, caption: String)
    case metric(id: String, title: String, value: String)
    case resource(id: String, title: String, route: Route)

    var id: String {
        switch self {
        case let .text(id, _, _), let .image(id, _, _),
             let .metric(id, _, _), let .resource(id, _, _): id
        }
    }

    var metadataItems: [String] {
        let title: String
        let value: String
        switch self {
        case let .text(_, blockTitle, body): (title, value) = (blockTitle, body)
        case let .metric(_, blockTitle, metric): (title, value) = (blockTitle, metric)
        case .image, .resource: return []
        }
        let allowedTitles = ["曲风", "推荐标签", "语种", "BPM"]
        guard allowedTitles.contains(where: { title.caseInsensitiveCompare($0) == .orderedSame }) else { return [] }
        let items = value.split(whereSeparator: \.isNewline).map(String.init)
        return title.caseInsensitiveCompare("BPM") == .orderedSame ? items.map { "\($0) BPM" } : items
    }
}

enum KnowledgeMetadataRows {
    static func indices(
        itemWidths: [CGFloat],
        separatorWidth: CGFloat,
        separatorSpacings: [CGFloat],
        width: CGFloat
    ) -> [[Int]] {
        var rows: [[Int]] = []
        var row: [Int] = []
        var rowWidth: CGFloat = 0

        for (index, itemWidth) in itemWidths.enumerated() {
            let addedWidth = row.isEmpty
                ? itemWidth
                : separatorSpacings[index - 1] * 2 + separatorWidth + itemWidth
            if !row.isEmpty, rowWidth + addedWidth > width {
                rows.append(row)
                row = [index]
                rowWidth = itemWidth
            } else {
                row.append(index)
                rowWidth += addedWidth
            }
        }
        if !row.isEmpty { rows.append(row) }
        return rows
    }
}

enum MusicSheetURLPolicy {
    static func validated(_ rawValue: String) -> URL? {
        guard var components = URLComponents(string: rawValue),
              let host = components.host?.lowercased()
        else { return nil }
        if components.scheme?.lowercased() == "http", isAllowedHost(host) {
            components.scheme = "https"
        }
        guard let url = components.url, isAllowed(url) else { return nil }
        return url
    }

    static func isAllowed(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https",
              url.user == nil,
              url.password == nil,
              let host = url.host?.lowercased()
        else { return false }
        return isAllowedHost(host)
    }

    private static func isAllowedHost(_ host: String) -> Bool {
        host == "music.126.net" || host.hasSuffix(".music.126.net")
            || host == "music.163.com" || host.hasSuffix(".music.163.com")
            || host == "nosdn.127.net" || host.hasSuffix(".nosdn.127.net")
    }
}

enum MusicSheetTemporaryFiles {
    private static var directory: URL {
        FileManager.default.temporaryDirectory.appending(
            path: "TinyCloudMusicSheetPreviews",
            directoryHint: .isDirectory
        )
    }

    static func cleanupExpired(now: Date = Date()) {
        let manager = FileManager.default
        guard let files = try? manager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        for file in files {
            let date = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            if date.map({ now.timeIntervalSince($0) > 24 * 60 * 60 }) != false {
                try? manager.removeItem(at: file)
            }
        }
    }

    static func write(_ data: Data) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "\(UUID().uuidString).pdf")
        try data.write(to: url, options: [.atomic])
        return url
    }

    static func remove(_ url: URL?) {
        guard let url, url.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL else { return }
        try? FileManager.default.removeItem(at: url)
    }
}

struct MusicSheetSaveResult: Equatable, Sendable {
    let url: URL
    let saved: Bool
}

enum MusicSheetFileError: LocalizedError {
    case invalidPDF

    var errorDescription: String? { "琴谱 PDF 文件无效" }
}

enum MusicSheetFiles {
    private static let invalidCharacters = CharacterSet(charactersIn: "\\/:*?\"<>|")
        .union(.controlCharacters)

    static func fileName(song: Song, sheet: MusicSheetSummary) -> String {
        let type = [sheet.instrument, sheet.title]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? "乐谱"
        let artists = song.artists.map(\.name).joined(separator: "、")
        let credit = artists.isEmpty ? song.primaryName : "\(artists) - \(song.primaryName)"
        let cleaned = sanitized("【\(type)】\(credit)")
        let suffix = " [\(sheet.id)]"
        let byteLimit = max(0, 180 - suffix.utf8.count)
        var usedBytes = 0
        let shortened = cleaned.prefix { character in
            let count = String(character).utf8.count
            guard usedBytes + count <= byteLimit else { return false }
            usedBytes += count
            return true
        }
        let stem = shortened.isEmpty ? "琴谱 [\(sheet.id)]" : String(shortened) + suffix
        return stem + ".pdf"
    }

    static func existingPDF(
        song: Song,
        sheet: MusicSheetSummary,
        in directory: URL,
        fileManager: FileManager = .default
    ) -> URL? {
        let hasSecurityScope = directory.startAccessingSecurityScopedResource()
        defer { if hasSecurityScope { directory.stopAccessingSecurityScopedResource() } }
        let url = directory.appending(path: fileName(song: song, sheet: sheet))
        return isValidPDF(at: url, fileManager: fileManager) ? url : nil
    }

    static func cachedPDF(
        sheetID: Int64,
        cacheRoot: URL,
        fileManager: FileManager = .default
    ) -> URL? {
        guard sheetID > 0 else { return nil }
        let hasSecurityScope = cacheRoot.startAccessingSecurityScopedResource()
        defer { if hasSecurityScope { cacheRoot.stopAccessingSecurityScopedResource() } }
        let url = cacheURL(sheetID: sheetID, root: cacheRoot)
        return isValidPDF(at: url, fileManager: fileManager) ? url : nil
    }

    static func cachePDF(
        at source: URL,
        sheetID: Int64,
        cacheRoot: URL,
        fileManager: FileManager = .default
    ) throws -> URL {
        guard sheetID > 0, isValidPDF(at: source, fileManager: fileManager) else {
            throw MusicSheetFileError.invalidPDF
        }
        let hasSecurityScope = cacheRoot.startAccessingSecurityScopedResource()
        defer { if hasSecurityScope { cacheRoot.stopAccessingSecurityScopedResource() } }
        let destination = cacheURL(sheetID: sheetID, root: cacheRoot)
        if isValidPDF(at: destination, fileManager: fileManager) { return destination }
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let part = destination.appendingPathExtension("\(UUID().uuidString).part")
        defer { try? fileManager.removeItem(at: part) }
        try fileManager.copyItem(at: source, to: part)
        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: part)
        } else {
            try fileManager.moveItem(at: part, to: destination)
        }
        return destination
    }

    static func savePDF(
        at source: URL,
        song: Song,
        sheet: MusicSheetSummary,
        to directory: URL,
        fileManager: FileManager = .default
    ) throws -> MusicSheetSaveResult {
        let hasSecurityScope = directory.startAccessingSecurityScopedResource()
        defer { if hasSecurityScope { directory.stopAccessingSecurityScopedResource() } }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let destination = directory.appending(path: fileName(song: song, sheet: sheet))
        if isValidPDF(at: destination, fileManager: fileManager) {
            return MusicSheetSaveResult(url: destination, saved: false)
        }
        guard isValidPDF(at: source, fileManager: fileManager) else {
            throw MusicSheetFileError.invalidPDF
        }

        let part = destination.appendingPathExtension("\(UUID().uuidString).part")
        defer { try? fileManager.removeItem(at: part) }
        try fileManager.copyItem(at: source, to: part)
        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: part)
        } else {
            try fileManager.moveItem(at: part, to: destination)
        }
        return MusicSheetSaveResult(url: destination, saved: true)
    }

    private static func sanitized(_ value: String) -> String {
        value.unicodeScalars
            .filter { !invalidCharacters.contains($0) }
            .map(String.init)
            .joined()
            .split(whereSeparator: \Character.isWhitespace)
            .joined(separator: " ")
    }

    private static func cacheURL(sheetID: Int64, root: URL) -> URL {
        root.appending(path: "DownloadCache", directoryHint: .isDirectory)
            .appending(path: "Sheets", directoryHint: .isDirectory)
            .appending(path: "\(sheetID).pdf", directoryHint: .notDirectory)
    }

    private static func isValidPDF(at url: URL, fileManager: FileManager) -> Bool {
        guard fileManager.fileExists(atPath: url.path),
              let handle = try? FileHandle(forReadingFrom: url)
        else { return false }
        defer { try? handle.close() }
        do {
            let size = try handle.seekToEnd()
            guard size >= 9 else { return false }
            try handle.seek(toOffset: 0)
            guard try handle.read(upToCount: 4)?.starts(with: Data("%PDF".utf8)) == true else { return false }
            try handle.seek(toOffset: size - min(size, 1_024))
            return try handle.readToEnd()?.range(of: Data("%%EOF".utf8)) != nil
        } catch {
            return false
        }
    }
}

enum MusicKnowledgeDecoder {
    static func styles(_ root: [String: Any]) -> [MusicStyle] {
        let data = root["data"]
        let values = objectArray(data).isEmpty
            ? firstObjectArray(in: root.object("data"), keys: ["tagList", "tags", "items"])
            : objectArray(data)
        return values.compactMap(style)
    }

    static func styleDetail(_ root: [String: Any], fallbackID: Int64, fallbackName: String) -> MusicStyleDetail {
        let data = root.object("data")
        let value = data.object("tag").isEmpty ? data : data.object("tag")
        let id = positiveID(value, keys: ["tagId", "id"]) ?? fallbackID
        return MusicStyleDetail(
            id: id,
            name: firstText(value, keys: ["tagName", "name"]) ?? fallbackName,
            description: safeText(firstText(value, keys: ["desc", "description", "intro"]) ?? "", limit: 2_000),
            coverURL: firstSafeURL(value, keys: ["coverUrl", "cover", "picUrl"])
        )
    }

    static func preferredStyleIDs(_ root: [String: Any]) -> [Int64] {
        let data = root.object("data")
        let values = objectArray(root["data"]) + firstObjectArray(
            in: data,
            keys: ["tags", "tagList", "tagPreferenceVos", "styleTags", "preferences", "items"]
        )
        var seen = Set<Int64>()
        return values.compactMap { positiveID($0, keys: ["tagId", "id"]) }
            .filter { seen.insert($0).inserted }
    }

    static func stylePage(
        _ root: [String: Any],
        kind: MusicStyleResourceKind,
        decode: ([String: Any]) -> MusicStyleResource?
    ) -> MusicStylePage {
        let data = root.object("data")
        let key = switch kind {
        case .songs: "songs"
        case .albums: "albums"
        case .artists: "artists"
        case .playlists: "playlists"
        }
        let singularKey = String(key.dropLast())
        var values = firstObjectArray(
            in: data,
            keys: [key, singularKey, "\(singularKey)List", "items", "resources"]
        )
        if values.isEmpty {
            values = firstObjectArray(in: root, keys: [key, singularKey, "\(singularKey)List", "data"])
        }
        var seen = Set<String>()
        let items = values.compactMap { source -> MusicStyleResource? in
            let value = unwrappedResource(source, singularKey: singularKey)
            let item = decode(value)
            guard let item, seen.insert(item.id).inserted else { return nil }
            return item
        }
        let cursor = firstText(data, keys: ["cursor", "nextCursor"])
            ?? firstText(root, keys: ["cursor", "nextCursor"])
        let hasMore = boolean(data, keys: ["more", "hasMore"])
            ?? boolean(root, keys: ["more", "hasMore"])
        let nextCursor = cursor.flatMap { $0 == "0" || hasMore == false ? nil : $0 }
        return MusicStylePage(items: items, nextCursor: items.isEmpty ? nil : nextCursor)
    }

    static func sheets(_ root: [String: Any]) -> [MusicSheetSummary] {
        let data = root.object("data")
        var values = firstObjectArray(
            in: data,
            keys: ["musicSheetSimpleInfoVOS", "items", "sheets", "sheetList", "list"]
        )
        if values.isEmpty { values = firstObjectArray(in: root, keys: ["items", "sheets", "sheetList", "data"]) }
        var seen = Set<Int64>()
        return values.compactMap { value in
            guard let id = positiveID(value, keys: ["id", "sheetId"]), seen.insert(id).inserted else { return nil }
            let typeNames = objectArray(value["type"])
                .compactMap { firstText($0, keys: ["name", "typeName"]) }
            return MusicSheetSummary(
                id: id,
                title: safeText(firstText(value, keys: ["name", "title", "sheetName"]) ?? "乐谱", limit: 120),
                instrument: firstText(value, keys: ["instrument", "instrumentName", "typeName"])
                    .map { safeText($0, limit: 80) }
                    ?? (typeNames.isEmpty ? nil : safeText(typeNames.joined(separator: " / "), limit: 80)),
                pageCount: positiveInt(value, keys: ["totalPageSize", "pageCount", "pages", "pageNum"])
            )
        }
    }

    static func sheetPreview(_ root: [String: Any]) -> MusicSheetPreview {
        let data = root.object("data")
        let containers = [data, data.object("previewInfo"), data.object("sheet"), root]
        var urls = urlArray(root["data"])
        for container in containers {
            for key in [
                "images", "imageUrls", "pageList", "previewImages", "imgList",
                "sheetPreviewVOList", "musicSheetPreviewVOS"
            ] {
                urls += urlArray(container[key])
            }
        }
        urls = unique(urls)
        if let pdf = containers.lazy.compactMap({ firstSafeURL($0, keys: ["pdfUrl", "pdf"]) }).first {
            return .pdf(pdf)
        }
        if let container = containers.first(where: {
            firstSafeURL($0, keys: ["url", "sheetUrl", "previewUrl", "imageUrl", "imgUrl"]) != nil
        }), let url = firstSafeURL(container, keys: ["url", "sheetUrl", "previewUrl", "imageUrl", "imgUrl"]) {
            let type = firstText(container, keys: ["fileType", "previewType", "type"])?.lowercased()
            if url.pathExtension.lowercased() == "pdf" || type == "pdf" || type == "application/pdf" {
                return .pdf(url)
            }
            urls.insert(url, at: 0)
        }
        let images = unique(urls).filter { $0.pathExtension.lowercased() != "pdf" }
        return images.isEmpty ? .unsupported : .images(images)
    }

    static func songWikiBlocks(_ root: [String: Any], prefix: String = "song-block") -> [MusicKnowledgeBlock] {
        let data = root.object("data")
        let blocks = firstObjectArray(in: data, keys: ["blocks", "items", "list"])
        let basicBlocks = blocks.filter {
            let code = firstText($0, keys: ["code", "blockCode"])?.uppercased()
            let showType = firstText($0, keys: ["showType"])?.uppercased()
            return code == "SONG_PLAY_ABOUT_SONG_BASIC" || showType == "SONG_PLAY_ABOUT_TAB_SONG_BASIC"
        }
        guard !basicBlocks.isEmpty else { return knowledgeBlocks(root, prefix: prefix) }
        return basicBlocks.enumerated().flatMap { blockIndex, block in
            objectArray(block["creatives"]).enumerated().flatMap { creativeIndex, creative in
                creativeKnowledgeBlocks(
                    creative,
                    id: "\(prefix)-\(blockIndex)-\(creativeIndex)"
                )
            }
        }
    }

    static func knowledgeBlocks(_ root: [String: Any], prefix: String = "knowledge") -> [MusicKnowledgeBlock] {
        let data = root.object("data")
        let container = ["artist", "album", "song", "mv", "resource"]
            .lazy.map { data.object($0) }
            .first { !$0.isEmpty } ?? data
        var values = firstObjectArray(
            in: container,
            keys: ["blocks", "items", "list", "introduction", "introductions"]
        )
        if values.isEmpty {
            values = firstObjectArray(in: data, keys: ["blocks", "items", "list", "introduction", "introductions"])
        }
        if values.isEmpty { values = firstObjectArray(in: root, keys: ["blocks", "items", "data"]) }
        var blocks = values.enumerated().compactMap { index, value in
            knowledgeBlock(value, id: "\(prefix)-\(blockID(value, fallback: index))")
        }
        if let summary = knowledgeBlock(container, id: "\(prefix)-summary") {
            blocks.insert(summary, at: 0)
        }
        return blocks
    }

    private static func style(_ value: [String: Any]) -> MusicStyle? {
        guard let id = positiveID(value, keys: ["tagId", "id"]),
              let name = firstText(value, keys: ["tagName", "name"])
        else { return nil }
        let children = firstObjectArray(in: value, keys: ["childrenTags", "children", "tags"])
            .compactMap(style)
        return MusicStyle(id: id, name: safeText(name, limit: 80), children: children)
    }

    private static func knowledgeBlock(_ value: [String: Any], id: String) -> MusicKnowledgeBlock? {
        let ui = value.object("uiElement")
        let resource = value.object("resource")
        let title = firstText(value, keys: ["title", "name", "label", "ti", "fieldName", "field"])
            ?? firstText(ui.object("mainTitle"), keys: ["title", "text"])
            ?? "音乐百科"

        if let route = resourceRoute(resource.isEmpty ? value : resource) {
            return .resource(id: id, title: safeText(title, limit: 120), route: route)
        }

        if let url = firstSafeURL(value, keys: ["imageUrl", "picUrl", "coverUrl"])
            ?? firstSafeURL(ui.object("image"), keys: ["imageUrl", "picUrl", "url"])
            ?? firstImageURL(ui) {
            return .image(id: id, url: url, caption: safeText(title, limit: 160))
        }

        if let metric = firstText(value, keys: ["value", "metricValue"]), !metric.isEmpty {
            return .metric(id: id, title: safeText(title, limit: 120), value: safeText(metric, limit: 120))
        }

        let body = firstText(value, keys: ["text", "txt", "description", "desc", "summary", "briefDesc", "intro", "content"])
            ?? firstText(ui.object("subTitle"), keys: ["title", "text"])
            ?? uiTexts(ui).first
        guard let body, !body.contains("<"), !body.contains(">") else { return nil }
        let cleanBody = safeText(body, limit: 4_000, maxLines: 20)
        return cleanBody.isEmpty ? nil : .text(
            id: id,
            title: safeText(title, limit: 120),
            body: cleanBody
        )
    }

    private static func creativeKnowledgeBlocks(_ value: [String: Any], id: String) -> [MusicKnowledgeBlock] {
        let creativeType = firstText(value, keys: ["creativeType", "type"])?.lowercased() ?? ""
        let ui = value.object("uiElement")
        let title = firstText(value, keys: ["title", "name", "label"])
            ?? firstText(ui.object("mainTitle"), keys: ["title", "text"])
            ?? "音乐百科"
        guard !creativeType.contains("sheet"), !title.contains("谱") else { return [] }
        let resources = objectArray(value["resources"])
        var details = uiTexts(ui)
        details += resources.compactMap { resource in
            guard resourceRoute(resource) == nil else { return nil }
            let resourceUI = resource.object("uiElement")
            let parts = [firstText(resourceUI.object("mainTitle"), keys: ["title", "text"])]
                .compactMap { $0 } + uiTexts(resourceUI)
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        }
        details = uniqueTexts(details)

        var blocks: [MusicKnowledgeBlock] = []
        if !details.isEmpty {
            let body = details.joined(separator: "\n")
            if creativeType == "bpm" {
                blocks.append(.metric(
                    id: "\(id)-metric",
                    title: safeText(title, limit: 120),
                    value: safeText(body, limit: 120)
                ))
            } else {
                blocks.append(.text(
                    id: "\(id)-text",
                    title: safeText(title, limit: 120),
                    body: safeText(body, limit: 4_000, maxLines: 20)
                ))
            }
        }

        for (index, resource) in resources.enumerated() {
            guard let route = resourceRoute(resource) else { continue }
            let resourceUI = resource.object("uiElement")
            let resourceTitle = firstText(resource, keys: ["title", "name"])
                ?? firstText(resourceUI.object("mainTitle"), keys: ["title", "text"])
                ?? title
            blocks.append(.resource(
                id: "\(id)-resource-\(index)",
                title: safeText(resourceTitle, limit: 120),
                route: route
            ))
        }

        let image = firstImageURL(ui)
            ?? resources.lazy.compactMap { firstImageURL($0.object("uiElement")) }.first
        if let image {
            blocks.append(.image(id: "\(id)-image", url: image, caption: safeText(title, limit: 160)))
        }
        return blocks
    }

    private static func resourceRoute(_ value: [String: Any]) -> Route? {
        guard let id = positiveID(value, keys: ["resourceId", "id", "artistId", "albumId", "playlistId", "mvId"])
        else { return nil }
        switch (firstText(value, keys: ["resourceType", "type"]) ?? "").lowercased() {
        case "artist": return .artist(id)
        case "album": return .album(id)
        case "playlist": return .playlist(id)
        case "mv": return .mv(id)
        default: return nil
        }
    }

    private static func unwrappedResource(_ value: [String: Any], singularKey: String) -> [String: Any] {
        for key in [singularKey, "resource", "data"] where !value.object(key).isEmpty {
            return value.object(key)
        }
        return value
    }

    private static func firstObjectArray(in value: [String: Any], keys: [String]) -> [[String: Any]] {
        keys.lazy.map { objectArray(value[$0]) }.first { !$0.isEmpty } ?? []
    }

    private static func objectArray(_ value: Any?) -> [[String: Any]] {
        value as? [[String: Any]] ?? []
    }

    private static func firstText(_ value: [String: Any], keys: [String]) -> String? {
        keys.lazy.map { value.string($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }

    private static func positiveID(_ value: [String: Any], keys: [String]) -> Int64? {
        keys.lazy.map { value.int64($0) }.first { $0 > 0 }
    }

    private static func positiveInt(_ value: [String: Any], keys: [String]) -> Int? {
        keys.lazy.map { value.int($0) }.first { $0 > 0 }
    }

    private static func boolean(_ value: [String: Any], keys: [String]) -> Bool? {
        for key in keys {
            if let number = value[key] as? NSNumber { return number.boolValue }
            switch value.string(key).lowercased() {
            case "true", "1": return true
            case "false", "0": return false
            default: continue
            }
        }
        return nil
    }

    private static func firstSafeURL(_ value: [String: Any], keys: [String]) -> URL? {
        keys.lazy.compactMap { MusicSheetURLPolicy.validated(value.string($0)) }.first
    }

    private static func urlArray(_ value: Any?) -> [URL] {
        guard let values = value as? [Any] else { return [] }
        return values.compactMap { item in
            if let raw = item as? String { return MusicSheetURLPolicy.validated(raw) }
            guard let object = item as? [String: Any] else { return nil }
            return firstSafeURL(object, keys: ["url", "imageUrl", "imgUrl", "picUrl"])
        }
    }

    private static func firstImageURL(_ ui: [String: Any]) -> URL? {
        urlArray(ui["images"]).first
    }

    private static func uiTexts(_ ui: [String: Any]) -> [String] {
        let mappings = [
            ("subTitles", ["title", "text"]),
            ("textLinks", ["text", "title"]),
            ("descriptions", ["description", "text"]),
            ("buttons", ["text", "title"]),
            ("labels", ["text", "title"])
        ]
        return uniqueTexts(mappings.flatMap { key, fields in
            objectArray(ui[key]).compactMap { firstText($0, keys: fields) }
        })
    }

    private static func uniqueTexts(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter {
            !$0.isEmpty && !$0.contains("<") && !$0.contains(">") && seen.insert($0).inserted
        }
    }

    private static func unique(_ values: [URL]) -> [URL] {
        var seen = Set<URL>()
        return values.filter { seen.insert($0).inserted }
    }

    private static func blockID(_ value: [String: Any], fallback: Int) -> String {
        firstText(value, keys: ["id", "blockCode", "code"]) ?? String(fallback)
    }

    private static func safeText(_ value: String, limit: Int, maxLines: Int = 4) -> String {
        let lines = value.replacingOccurrences(of: "\r", with: "")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .prefix(maxLines)
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(lines.prefix(limit))
    }

}
