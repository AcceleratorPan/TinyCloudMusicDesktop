import Foundation

extension LiveMusicLibrary {
    func checkCloudUpload(_ manifest: AudioUploadManifest) async throws -> CloudUploadCheck {
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
            ]
        )
        try requireUploadSuccess(root)
        let songID = root.int64("songId")
        guard songID > 0 else { throw EAPIError.missingData("songId") }
        return CloudUploadCheck(needsUpload: root.bool("needUpload"), songID: songID)
    }

    func allocateCloudUpload(_ manifest: AudioUploadManifest) async throws -> NOSAllocation {
        try await allocateUpload(
            bucket: NOSAudioUpload.cloudBucket,
            filename: manifest.filename,
            fileExtension: manifest.fileExtension,
            product: 3,
            type: "audio",
            md5: manifest.md5
        )
    }

    func registerCloudUpload(_ manifest: AudioUploadManifest, allocation: NOSAllocation) async throws -> Int64 {
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
            ]
        )
        try requireUploadSuccess(root)
        let songID = root.int64("songId")
        guard songID > 0 else { throw EAPIError.missingData("songId") }
        return songID
    }

    func publishCloudUpload(songID: Int64) async throws {
        guard songID > 0 else { throw EAPIError.invalidPayload }
        let root = try await uploadEAPI(
            "/eapi/cloud/pub/v2",
            signing: "/api/cloud/pub/v2",
            payload: ["songid": songID]
        )
        try requireUploadSuccess(root)
        await transport.invalidateCachedResponses(in: [.library])
    }

    func reconcileCloudUpload(md5: String, songID: Int64?) async throws -> Bool {
        let root = try decodedJSONObject(try await transport.requestCloudSongs(offset: 0, limit: 100))
        return root.array("data").contains { value in
            (!md5.isEmpty && value.string("md5").caseInsensitiveCompare(md5) == .orderedSame)
                || (songID != nil && value.int64("songId") == songID)
        }
    }

    private func uploadEAPI(
        _ physicalPath: String,
        signing logicalPath: String,
        payload: [String: Any]
    ) async throws -> [String: Any] {
        try decodedJSONObject(try await transport.request(
            EAPIEndpoint(physicalPath, signing: logicalPath),
            json: compactJSON(payload),
            invalidatesAccountCache: false,
            retryable: false
        ))
    }

    private func allocateUpload(
        bucket: String,
        filename: String,
        fileExtension: String,
        product: Int,
        type: String,
        md5: String? = nil
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
        let root = try decodedJSONObject(try await transport.requestWEAPI(
            path: "/weapi/nos/token/alloc",
            payload: payload,
            invalidatesAccountCache: false
        ))
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

    fileprivate func requireUploadSuccess(_ root: [String: Any]) throws {
        let code = root.int("code")
        guard code == 0 || (200..<300).contains(code) else {
            throw EAPIError.service(code: code, message: root.string("message"))
        }
    }

    fileprivate func uploadString(_ value: Any?) -> String {
        if let value = value as? String { return value }
        return (value as? NSNumber)?.stringValue ?? ""
    }

    fileprivate func nonempty(_ value: String, fallback: String) -> String {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? fallback : value
    }
}

extension LiveAudioContentLibrary {
    func myCreatedPodcasts(limit: Int = 100) async throws -> [Podcast] {
        guard (1...200).contains(limit) else { throw EAPIError.invalidPayload }
        let root = try decodedJSONObject(try await transport.requestWEAPI(
            path: "/weapi/social/my/created/voicelist/v1",
            payload: ["limit": limit],
            invalidatesAccountCache: false
        ))
        return AudioContentDecoder.podcasts(root)
    }

    func uploadPodcast(id: Int64) async throws -> Podcast {
        guard id > 0 else { throw EAPIError.invalidPayload }
        let root = try decodedJSONObject(try await transport.requestWEAPI(
            path: "/weapi/voice/workbench/voicelist/detail",
            payload: ["id": id],
            invalidatesAccountCache: false
        ))
        guard let podcast = AudioContentDecoder.podcast(root) else { throw EAPIError.missingData("data") }
        return podcast
    }

    func allocatePodcastUpload(_ manifest: AudioUploadManifest) async throws -> NOSAllocation {
        let root = try decodedJSONObject(try await transport.requestWEAPI(
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
            invalidatesAccountCache: false
        ))
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

    func precheckPodcastUpload(form: PodcastUploadForm, documentID: Int64, token: String) async throws {
        _ = try await podcastUploadRequest(
            path: "/weapi/voice/workbench/voice/batch/upload/preCheck",
            dupkey: form.precheckDupkey,
            voiceData: form.voiceData(documentID: documentID),
            token: token
        )
    }

    func submitPodcastUpload(form: PodcastUploadForm, documentID: Int64, token: String) async throws {
        _ = try await podcastUploadRequest(
            path: "/weapi/voice/workbench/voice/batch/upload/v2",
            dupkey: form.submitDupkey,
            voiceData: form.voiceData(documentID: documentID),
            token: token
        )
        await transport.invalidateCachedResponses(in: [.library])
    }

    func reconcilePodcastUpload(voiceListID: Int64, documentID: Int64) async throws -> Bool {
        guard voiceListID > 0, documentID > 0 else { throw EAPIError.invalidPayload }
        let root = try decodedJSONObject(try await transport.requestWEAPI(
            path: "/weapi/voice/workbench/voice/list",
            payload: ["limit": 200, "offset": 0, "radioId": voiceListID],
            invalidatesAccountCache: false
        ))
        let data = root.object("data")
        let values = [root, data].flatMap { object in
            ["list", "voices", "programs"].flatMap { object.array($0) }
        }
        return values.contains { value in
            value.int64("dfsId") == documentID
                || value.object("mainSong").int64("dfsId") == documentID
        }
    }

    private func podcastUploadRequest(
        path: String,
        dupkey: UUID,
        voiceData: [[String: Any]],
        token: String
    ) async throws -> [String: Any] {
        guard !token.isEmpty,
              let voiceJSON = String(
                data: try JSONSerialization.data(withJSONObject: voiceData, options: [.sortedKeys]),
                encoding: .utf8
              )
        else { throw EAPIError.invalidPayload }
        let root = try decodedJSONObject(try await transport.requestWEAPI(
            path: path,
            payload: ["dupkey": dupkey.uuidString.lowercased(), "voiceData": voiceJSON],
            invalidatesAccountCache: false,
            additionalHeaders: ["x-nos-token": token]
        ))
        try requireUploadSuccess(root)
        return root
    }

    private func requireUploadSuccess(_ root: [String: Any]) throws {
        let code = root.int("code")
        guard code == 0 || (200..<300).contains(code) else {
            throw EAPIError.service(code: code, message: root.string("message"))
        }
    }

    private func uploadString(_ value: Any?) -> String {
        if let value = value as? String { return value }
        return (value as? NSNumber)?.stringValue ?? ""
    }
}
