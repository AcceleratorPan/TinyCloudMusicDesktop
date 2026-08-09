import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct ProcessedPlaylistCover: Equatable, Sendable {
    let jpegData: Data
    let filename: String
    let width: Int
    let height: Int
}

enum PlaylistCoverError: LocalizedError, Equatable {
    case sourceTooLarge
    case dimensionsTooLarge
    case invalidImage
    case encodingFailed

    var errorDescription: String? {
        switch self {
        case .sourceTooLarge: "图片文件不能超过 25 MB"
        case .dimensionsTooLarge: "图片像素尺寸过大"
        case .invalidImage: "无法读取所选图片"
        case .encodingFailed: "无法生成 JPEG 封面"
        }
    }
}

enum PlaylistCoverProcessor {
    static let maxSourceBytes = 25 * 1_024 * 1_024
    private static let maxSourcePixels = 40_000_000
    private static let outputSize = 1_000

    static func process(url: URL) throws -> ProcessedPlaylistCover {
        try Task.checkCancellation()
        let hasSecurityScope = url.startAccessingSecurityScopedResource()
        defer { if hasSecurityScope { url.stopAccessingSecurityScopedResource() } }

        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile != false,
              let fileSize = values.fileSize,
              fileSize <= maxSourceBytes
        else { throw PlaylistCoverError.sourceTooLarge }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        try Task.checkCancellation()
        return try process(
            data: data,
            filename: url.deletingPathExtension().lastPathComponent
        )
    }

    static func process(data: Data, filename: String) throws -> ProcessedPlaylistCover {
        try Task.checkCancellation()
        guard !data.isEmpty, data.count <= maxSourceBytes,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0, height > 0
        else {
            if data.count > maxSourceBytes { throw PlaylistCoverError.sourceTooLarge }
            throw PlaylistCoverError.invalidImage
        }
        guard height <= maxSourcePixels / width else { throw PlaylistCoverError.dimensionsTooLarge }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: outputSize,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw PlaylistCoverError.invalidImage
        }
        try Task.checkCancellation()
        let side = min(thumbnail.width, thumbnail.height)
        let crop = CGRect(
            x: (thumbnail.width - side) / 2,
            y: (thumbnail.height - side) / 2,
            width: side,
            height: side
        )
        guard let cropped = thumbnail.cropping(to: crop),
              let context = CGContext(
                data: nil,
                width: outputSize,
                height: outputSize,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { throw PlaylistCoverError.invalidImage }
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: outputSize, height: outputSize))
        context.interpolationQuality = .high
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: outputSize, height: outputSize))
        guard let image = context.makeImage() else { throw PlaylistCoverError.encodingFailed }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else { throw PlaylistCoverError.encodingFailed }
        CGImageDestinationAddImage(
            destination,
            image,
            [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else { throw PlaylistCoverError.encodingFailed }
        return ProcessedPlaylistCover(
            jpegData: output as Data,
            filename: sanitizedFilename(filename),
            width: outputSize,
            height: outputSize
        )
    }

    private static func sanitizedFilename(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let base = value.unicodeScalars.map { allowed.contains($0) ? Character(String($0)) : "_" }
        let name = String(base.prefix(80)).trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return (name.isEmpty ? "playlist-cover" : name) + ".jpg"
    }
}

struct PlaylistImageUpload: Sendable {
    let transport: EAPITransport

    func updateCover(
        playlistID: Int64,
        cover: ProcessedPlaylistCover,
        expectedCredentialRevision: UInt64
    ) async throws {
        try Task.checkCancellation()
        let allocationRoot = try await transport.requestWEAPIJSONObject(
                path: "/weapi/nos/token/alloc",
                payload: [
                    "bucket": "yyimgs",
                    "ext": "jpg",
                    "filename": cover.filename,
                    "local": false,
                    "nos_product": 0,
                    "return_body": #"{"code":200,"size":"$(ObjectSize)"}"#,
                    "type": "other"
                ],
                expectedCredentialRevision: expectedCredentialRevision,
                invalidatesAccountCache: false,
                retryable: false
        )
        try validate(expectedCredentialRevision)
        try requireUploadSuccess(allocationRoot)
        let result = allocationRoot.object("result")
        let objectKey = result.string("objectKey")
        let token = result.string("token")
        let coverImageID = uploadString(result["docId"] ?? result["resourceId"])
        guard !objectKey.isEmpty, !token.isEmpty, !coverImageID.isEmpty else {
            throw EAPIError.missingData("result.objectKey/token/docId")
        }
        try Task.checkCancellation()

        var components = URLComponents()
        components.scheme = "https"
        components.host = "nosup-hz1.127.net"
        components.path = "/yyimgs/\(objectKey)"
        components.queryItems = [
            URLQueryItem(name: "offset", value: "0"),
            URLQueryItem(name: "complete", value: "true"),
            URLQueryItem(name: "version", value: "1.0")
        ]
        guard let uploadURL = components.url else { throw EAPIError.invalidPayload }
        var request = URLRequest(url: uploadURL, timeoutInterval: 60)
        request.httpMethod = "POST"
        request.httpBody = cover.jpegData
        request.setValue(token, forHTTPHeaderField: "x-nos-token")
        request.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
        _ = try await transport.requestRaw(
            request,
            expectedCredentialRevision: expectedCredentialRevision
        )
        try validate(expectedCredentialRevision)

        let updateRoot = try await transport.requestWEAPIJSONObject(
                path: "/weapi/playlist/cover/update",
                payload: ["id": playlistID, "coverImgId": coverImageID],
                expectedCredentialRevision: expectedCredentialRevision,
                invalidatesAccountCache: false,
                retryable: false
        )
        try validate(expectedCredentialRevision)
        try requireUploadSuccess(updateRoot)
    }

    private func validate(_ expectedCredentialRevision: UInt64) throws {
        let actual = transport.credentialSnapshotValue().revision
        guard actual == expectedCredentialRevision else {
            throw CredentialRevisionMismatch(expected: expectedCredentialRevision, actual: actual)
        }
    }
}
