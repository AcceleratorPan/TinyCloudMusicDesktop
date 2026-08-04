import Foundation

func requireUploadSuccess(_ root: [String: Any]) throws {
    let code = root.int("code")
    guard code == 0 || (200..<300).contains(code) else {
        throw EAPIError.service(code: code, message: root.string("message"))
    }
}

func uploadString(_ value: Any?) -> String {
    if let value = value as? String { return value }
    return (value as? NSNumber)?.stringValue ?? ""
}

extension LiveMusicLibrary {
    func checkCloudUpload(
        _ manifest: AudioUploadManifest,
        expectedCredentialRevision: UInt64
    ) async throws -> CloudUploadCheck {
        let root = try await uploadEAPI(
            "/eapi/cloud/upload/check",
            signing: "/api/cloud/upload/check",
            payload: [
                "bitrate": String(max(0, manifest.metadata.bitrate)),
                "ext": "",
                "length": manifest.byteCount,
                "md5": manifest.md5,
                "songId": "0",
                "version": 1
            ],
            expectedCredentialRevision: expectedCredentialRevision
        )
        try requireUploadSuccess(root)
        let songID = root.int64("songId")
        guard songID > 0 else { throw EAPIError.missingData("songId") }
        return CloudUploadCheck(needsUpload: root.bool("needUpload"), songID: songID)
    }

    func allocateCloudUpload(
        _ manifest: AudioUploadManifest,
        expectedCredentialRevision: UInt64
    ) async throws -> NOSAllocation {
        try await allocateUpload(
            bucket: NOSAudioUpload.cloudBucket,
            filename: manifest.filename,
            fileExtension: manifest.fileExtension,
            product: 3,
            type: "audio",
            md5: manifest.md5,
            expectedCredentialRevision: expectedCredentialRevision
        )
    }

    func registerCloudUpload(
        _ manifest: AudioUploadManifest,
        allocation: NOSAllocation,
        expectedCredentialRevision: UInt64
    ) async throws -> Int64 {
        let root = try await uploadEAPI(
            "/eapi/upload/cloud/info/v2",
            signing: "/api/upload/cloud/info/v2",
            payload: [
                "md5": manifest.md5,
                "songid": manifest.cloud.songID,
                "filename": manifest.filename,
                "song": nonempty(manifest.metadata.title, fallback: manifest.filename),
                "album": nonempty(manifest.metadata.album, fallback: "未知专辑"),
                "artist": nonempty(manifest.metadata.artist, fallback: "未知艺术家"),
                "bitrate": String(max(0, manifest.metadata.bitrate)),
                "resourceId": allocation.resourceID
            ],
            expectedCredentialRevision: expectedCredentialRevision
        )
        try requireUploadSuccess(root)
        let songID = root.int64("songId")
        guard songID > 0 else { throw EAPIError.missingData("songId") }
        return songID
    }

    func publishCloudUpload(songID: Int64, expectedCredentialRevision: UInt64) async throws {
        guard songID > 0 else { throw EAPIError.invalidPayload }
        let root = try await uploadEAPI(
            "/eapi/cloud/pub/v2",
            signing: "/api/cloud/pub/v2",
            payload: ["songid": songID],
            expectedCredentialRevision: expectedCredentialRevision
        )
        try requireUploadSuccess(root)
    }

    func reconcileCloudUpload(
        md5: String,
        songID: Int64?,
        expectedCredentialRevision: UInt64
    ) async throws -> Bool {
        let songID = songID.flatMap { $0 > 0 ? $0 : nil }
        var offset = 0
        var seenOffsets: Set<Int> = []
        var seenItems: Set<String> = []
        while seenOffsets.insert(offset).inserted {
            let root = try await transport.requestWEAPIJSONObject(
                path: "/weapi/v1/cloud/get",
                payload: ["offset": offset, "limit": 100],
                expectedCredentialRevision: expectedCredentialRevision,
                invalidatesAccountCache: false
            )
            let values = root.array("data")
            if values.contains(where: {
                (!md5.isEmpty && $0.string("md5").caseInsensitiveCompare(md5) == .orderedSame)
                    || (songID != nil && $0.int64("songId") == songID)
            }) {
                return true
            }
            let added = values.reduce(into: 0) { count, value in
                let key = "\(value.int64("songId")):\(value.string("md5").lowercased())"
                if seenItems.insert(key).inserted { count += 1 }
            }
            guard root.bool("hasMore"), !values.isEmpty, added > 0 else { return false }
            let next = offset + values.count
            guard next > offset else { return false }
            offset = next
        }
        return false
    }

    private func uploadEAPI(
        _ physicalPath: String,
        signing logicalPath: String,
        payload: [String: Any],
        expectedCredentialRevision: UInt64,
        invalidatesGroups: Set<EAPIReadCache> = []
    ) async throws -> [String: Any] {
        try await transport.requestJSONObject(
            EAPIEndpoint(physicalPath, signing: logicalPath),
            json: compactJSON(payload),
            expectedCredentialRevision: expectedCredentialRevision,
            invalidatesGroups: invalidatesGroups,
            invalidatesAccountCache: false,
            retryable: false
        )
    }

    private func allocateUpload(
        bucket: String,
        filename: String,
        fileExtension: String,
        product: Int,
        type: String,
        md5: String? = nil,
        expectedCredentialRevision: UInt64
    ) async throws -> NOSAllocation {
        var payload: [String: Any] = [
            "bucket": bucket,
            "ext": fileExtension,
            "filename": AudioUploadInspector.sanitizedFilename(
                (filename as NSString).deletingPathExtension
            ),
            "local": false,
            "nos_product": product,
            "type": type
        ]
        if let md5 { payload["md5"] = md5 }
        let root = try await transport.requestWEAPIJSONObject(
            path: "/weapi/nos/token/alloc",
            payload: payload,
            expectedCredentialRevision: expectedCredentialRevision,
            invalidatesAccountCache: false
        )
        try requireUploadSuccess(root)
        let result = root.object("result")
        let allocation = NOSAllocation(
            token: result.string("token"),
            objectKey: result.string("objectKey"),
            resourceID: uploadString(result["resourceId"] ?? result["docId"]),
            documentID: result.int64("docId") != 0 ? result.int64("docId") : result.int64("resourceId")
        )
        guard !allocation.token.isEmpty, !allocation.objectKey.isEmpty, !allocation.resourceID.isEmpty else {
            throw EAPIError.missingData("result.objectKey/token/resourceId")
        }
        return allocation
    }

    fileprivate func nonempty(_ value: String, fallback: String) -> String {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? fallback : value
    }
}

extension LiveAudioContentLibrary {
    func myCreatedPodcasts(
        limit: Int = 100,
        expectedCredentialRevision: UInt64
    ) async throws -> [Podcast] {
        guard (1...200).contains(limit) else { throw EAPIError.invalidPayload }
        let root = try await transport.requestWEAPIJSONObject(
            path: "/weapi/social/my/created/voicelist/v1",
            payload: ["limit": limit],
            expectedCredentialRevision: expectedCredentialRevision,
            invalidatesAccountCache: false
        )
        return AudioContentDecoder.podcasts(root)
    }

    func uploadPodcast(
        id: Int64,
        expectedCredentialRevision: UInt64
    ) async throws -> Podcast {
        guard id > 0 else { throw EAPIError.invalidPayload }
        let root = try await transport.requestWEAPIJSONObject(
            path: "/weapi/voice/workbench/voicelist/detail",
            payload: ["id": id],
            expectedCredentialRevision: expectedCredentialRevision,
            invalidatesAccountCache: false
        )
        guard let podcast = AudioContentDecoder.podcast(root) else { throw EAPIError.missingData("data") }
        return podcast
    }

    func allocatePodcastUpload(
        _ manifest: AudioUploadManifest,
        expectedCredentialRevision: UInt64
    ) async throws -> NOSAllocation {
        let root = try await transport.requestWEAPIJSONObject(
            path: "/weapi/nos/token/alloc",
            payload: [
                "bucket": NOSAudioUpload.podcastBucket,
                "ext": manifest.fileExtension,
                "filename": AudioUploadInspector.sanitizedFilename(
                    (manifest.filename as NSString).deletingPathExtension
                ),
                "local": false,
                "nos_product": 0,
                "type": "other"
            ],
            expectedCredentialRevision: expectedCredentialRevision,
            invalidatesAccountCache: false
        )
        try requireUploadSuccess(root)
        let result = root.object("result")
        let allocation = NOSAllocation(
            token: result.string("token"),
            objectKey: result.string("objectKey"),
            resourceID: uploadString(result["resourceId"] ?? result["docId"]),
            documentID: result.int64("docId") != 0 ? result.int64("docId") : result.int64("resourceId")
        )
        guard !allocation.token.isEmpty, !allocation.objectKey.isEmpty, allocation.documentID > 0 else {
            throw EAPIError.missingData("result.objectKey/token/docId")
        }
        return allocation
    }

    func precheckPodcastUpload(
        form: PodcastUploadForm,
        documentID: Int64,
        token: String,
        expectedCredentialRevision: UInt64
    ) async throws {
        _ = try await podcastUploadRequest(
            path: "/weapi/voice/workbench/voice/batch/upload/preCheck",
            dupkey: form.precheckDupkey,
            voiceData: form.voiceData(documentID: documentID),
            token: token,
            expectedCredentialRevision: expectedCredentialRevision
        )
    }

    func submitPodcastUpload(
        form: PodcastUploadForm,
        documentID: Int64,
        token: String,
        expectedCredentialRevision: UInt64
    ) async throws {
        _ = try await podcastUploadRequest(
            path: "/weapi/voice/workbench/voice/batch/upload/v2",
            dupkey: form.submitDupkey,
            voiceData: form.voiceData(documentID: documentID),
            token: token,
            expectedCredentialRevision: expectedCredentialRevision
        )
    }

    func reconcilePodcastUpload(
        voiceListID: Int64,
        documentID: Int64,
        expectedCredentialRevision: UInt64
    ) async throws -> Bool {
        guard voiceListID > 0, documentID > 0 else { throw EAPIError.invalidPayload }
        var offset = 0
        var seenOffsets: Set<Int> = []
        var seenItems: Set<Int64> = []
        while seenOffsets.insert(offset).inserted {
            let root = try await transport.requestWEAPIJSONObject(
                path: "/weapi/voice/workbench/voice/list",
                payload: ["limit": 200, "offset": offset, "radioId": voiceListID],
                expectedCredentialRevision: expectedCredentialRevision,
                invalidatesAccountCache: false
            )
            let data = root.object("data")
            let values = [root, data].flatMap { object in
                ["list", "voices", "programs"].flatMap { object.array($0) }
            }
            if values.contains(where: {
                $0.int64("dfsId") == documentID
                    || $0.object("mainSong").int64("dfsId") == documentID
            }) {
                return true
            }
            let added = values.reduce(into: 0) { count, value in
                let identity = if value.int64("id") != 0 {
                    value.int64("id")
                } else if value.int64("dfsId") != 0 {
                    value.int64("dfsId")
                } else {
                    value.object("mainSong").int64("dfsId")
                }
                if seenItems.insert(identity).inserted { count += 1 }
            }
            let hasMore = root.bool("hasMore") || data.bool("hasMore")
            guard hasMore, !values.isEmpty, added > 0 else { return false }
            let next = offset + values.count
            guard next > offset else { return false }
            offset = next
        }
        return false
    }

    private func podcastUploadRequest(
        path: String,
        dupkey: UUID,
        voiceData: [[String: Any]],
        token: String,
        expectedCredentialRevision: UInt64,
        invalidatesGroups: Set<EAPIReadCache> = []
    ) async throws -> [String: Any] {
        guard !token.isEmpty,
              let voiceJSON = String(
                data: try JSONSerialization.data(withJSONObject: voiceData, options: [.sortedKeys]),
                encoding: .utf8
              )
        else { throw EAPIError.invalidPayload }
        let root = try await transport.requestWEAPIJSONObject(
            path: path,
            payload: ["dupkey": dupkey.uuidString.lowercased(), "voiceData": voiceJSON],
            expectedCredentialRevision: expectedCredentialRevision,
            invalidatesGroups: invalidatesGroups,
            invalidatesAccountCache: false,
            additionalHeaders: ["x-nos-token": token]
        )
        try requireUploadSuccess(root)
        return root
    }
}
