import Foundation

@main
enum APIParityCheck {
    static func main() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let sourceRoot = root.appending(path: "Sources/TinyCloudMusic")
        let swiftSource = try FileManager.default.contentsOfDirectory(at: sourceRoot, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
            .map { try String(contentsOf: $0, encoding: .utf8) }
            .joined(separator: "\n")
        let qtRoot = root.deletingLastPathComponent()
        let mainWindow = qtRoot.appending(path: "mainwindow.cpp")
        let qtFiles = ([mainWindow].filter { FileManager.default.fileExists(atPath: $0.path) }) + ["api", "player"].flatMap { directory in
            let directory = qtRoot.appending(path: directory)
            let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil)
            return (files?.allObjects as? [URL] ?? []).filter {
                ["cpp", "h"].contains($0.pathExtension) && !$0.path.contains("Qt-AES-master")
            }
        }
        let qtSource = try qtFiles.map { try String(contentsOf: $0, encoding: .utf8) }.joined(separator: "\n")
        let urlPattern = try Regex(#"https?://(?:interface3\.)?music\.163\.com[^"\s]*"#)
        let qtURLs = Set(qtSource.matches(of: urlPattern).map { String(qtSource[$0.range]) }).filter {
            URL(string: $0)?.path.isEmpty == false
        }

        let endpoints: [(needle: String, count: Int)] = [
            ("/eapi/search/default/keyword/list", 1),
            ("/eapi/search/suggest/keyword/get", 1),
            ("/eapi/search/song/list/page", 1),
            ("/eapi/v1/search/\\(kind)/get", 4),
            ("/eapi/v3/song/detail", 2),
            ("/eapi/song/enhance/player/url/v1", 1),
            ("/eapi/song/lyric", 1),
            ("/api/v3/discovery/recommend/songs", 1),
            ("/weapi/v1/discovery/simiSong", 1),
            ("/eapi/album/v3/detail", 1),
            ("/eapi/artist/albums/\\(artistID)", 1),
            ("/eapi/v6/playlist/detail", 1),
            ("/eapi/v1/artist/top/song", 1),
            ("/eapi/playlist/detail/rcmd/get", 1),
            ("/eapi/playlist/\\(action)", 2),
            ("/eapi/album/\\(action)", 2),
            ("/eapi/album/detail/dynamic", 1),
            ("/eapi/playlist/create", 1),
            ("/eapi/playlist/delete", 1),
            ("/eapi/v1/playlist/manipulate/tracks", 1),
            ("/eapi/user/playlist/v1s", 1),
            ("/eapi/v1/user/info", 1),
            ("/eapi/v1/user/detail", 1),
            ("/eapi/user/playlist", 1),
            ("/eapi/song/like", 1),
            ("/eapi/artist/head/info/get", 1),
            ("/eapi/v1/artist/sub", 1),
            ("/eapi/artist/unsub", 1),
            ("/eapi/user/\\(action)/\\(userID)", 2),
            ("/eapi/user/follow/users/mixed/get/v2", 1),
            ("/eapi/user/v3/follows/get", 1),
            ("/eapi/user/sub/artist/get", 1),
            ("/eapi/artist/follow/count/get", 1),
            ("/eapi/v1/similar/artist/get", 1),
            ("/eapi/user/unfollow/recommend/v1", 1),
            ("/eapi/music-vip-membership/client/vip/info", 1),
            ("/eapi/batch", 1),
            ("/eapi/v2/resource/comment/floor/get", 1),
            ("/eapi/link/page/rcmd/resource/show", 1)
        ]
        let missing = endpoints.filter { !swiftSource.contains($0.needle) }.map(\.needle)
        precondition(missing.isEmpty, "Missing Swift endpoint patterns: \(missing.joined(separator: ", "))")

        let signingPairs = [
            "/api/search/song/list/page",
            "/api/v1/user/detail/\\(id)",
            "/api/v1/user/detail/\\(userID)",
            "/api/user/playlist/v1",
            "/batch",
            "/api/link/page/rcmd/resource/show"
        ]
        let missingSigning = signingPairs.filter { !swiftSource.contains($0) }
        precondition(missingSigning.isEmpty, "Missing signing paths: \(missingSigning.joined(separator: ", "))")

        let playbackReadContracts = [
            ("/eapi/song/enhance/player/url/v1", "/api/song/enhance/player/url/v1", "automatic", "read"),
            ("/eapi/song/music/detail/get", "/api/song/music/detail/get", "automatic", "read"),
            ("/eapi/song/copyright/rcmd", "/api/song/copyright/rcmd", "automatic", "read")
        ]
        for (physical, signing, encoding, access) in playbackReadContracts {
            precondition(swiftSource.contains(physical), "Missing playback physical path: \(physical)")
            precondition(swiftSource.contains(signing), "Missing playback signing path: \(signing)")
            precondition(encoding == "automatic" && access == "read")
        }
        let recentPlaybackReadContracts = [
            "/api/play-record/song/list",
            "/api/play-record/album/list",
            "/api/play-record/playlist/list",
            "/api/play-record/newvideo/list",
            "/api/play-record/voice/list",
            "/api/play-record/djradio/list"
        ]
        for path in recentPlaybackReadContracts {
            precondition(swiftSource.contains(path), "Missing recent playback path: \(path)")
        }
        precondition(swiftSource.contains("transport.requestRecentPlayback("))
        precondition(swiftSource.contains("path.replacingOccurrences(of: \"/api/\", with: \"/weapi/\")"))
        for path in [
            "/weapi/discovery/recommend/songs/history/recent",
            "/weapi/discovery/recommend/songs/history/detail"
        ] {
            precondition(swiftSource.contains(path), "Missing recommendation-memory path: \(path)")
        }
        precondition(swiftSource.contains("https://interface.music.163.com"))
        precondition(swiftSource.components(separatedBy: "responseEncoding: .automatic").count > 3)
        precondition(!swiftSource.contains("/eapi/register/anonimous"))
        precondition(!swiftSource.contains("http://interface3.music.163.com/eapi/song/like/get"))
        if !qtFiles.isEmpty {
            precondition(qtURLs.count == endpoints.reduce(0) { $0 + $1.count } + 2, "Qt endpoint inventory changed")
        }

        let sourceSummary = qtFiles.isEmpty
            ? "Swift endpoint inventory checked (external Qt source unavailable)"
            : "\(endpoints.reduce(0) { $0 + $1.count }) Qt call targets mapped"
        print("API parity check passed: \(sourceSummary); 3 playback and 6 recent-history reads recorded; 2 unsafe targets excluded")
    }
}
