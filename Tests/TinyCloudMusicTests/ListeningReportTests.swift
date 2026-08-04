import Foundation

#if !LISTENING_REPORT_CHECK
@testable import TinyCloudMusic
#if canImport(Testing)
import Testing
#endif
#endif

private enum ListeningReportCheckError: Error {
    case failed
}

private func listeningFixture(_ name: String) throws -> [String: Any] {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appending(path: "Fixtures/\(name).json")
    guard let value = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else {
        throw ListeningReportCheckError.failed
    }
    return value
}

private func fixtureObject(_ fixture: [String: Any], _ key: String) throws -> [String: Any] {
    guard let value = fixture[key] as? [String: Any] else { throw ListeningReportCheckError.failed }
    return value
}

private func verifyListeningSuccessFixture() throws {
    let fixture = try listeningFixture("listening-success")
    let annualFixture = try listeningFixture("annual-report")
    let library = LiveMusicLibrary()
    guard try library.decodeTotalListeningDuration(fixtureObject(fixture, "total")) == 1_219_210
    else { throw ListeningReportCheckError.failed }

    let today = library.decodeListeningRank(try fixtureObject(fixture, "today"))
    let rank = library.decodeListeningRank(try fixtureObject(fixture, "rank"))
    let realtime = library.decodeRealtimeListeningReport(
        try fixtureObject(fixture, "realtime"),
        period: .month
    )
    let report = library.decodeListeningReport(try fixtureObject(fixture, "report"), period: .week)
    let years = library.decodeYearListeningFootprints(try fixtureObject(fixture, "year"))
    let annual = library.decodeAnnualListeningReport(annualFixture, year: 2024)
    let memory = library.decodeFirstListenMemory(
        try fixtureObject(fixture, "first"),
        now: Date(timeIntervalSince1970: 1_735_689_600)
    )
    guard today.map(\.id) == [42],
          today.first?.playCount == 4,
          today.first?.durationSeconds == 720,
          today.first?.song.artists.first?.id == 7,
          today.first?.song.album.id == 0,
          rank.map(\.id) == [43, 44],
          rank.map(\.playCount) == [6, 3],
          realtime.metrics == [
              ListeningMetric(kind: .duration, value: .number(83_700)),
              ListeningMetric(kind: .days, value: .number(9))
          ],
          report.title == "Weekly report",
          report.metrics == [
              ListeningMetric(kind: .duration, value: .number(7_200)),
              ListeningMetric(kind: .songs, value: .number(12)),
              ListeningMetric(kind: .days, value: .number(5))
          ],
          report.topSongs.map(\.id) == [45],
          report.previousEndTime == 1_719_705_600_000,
          report.previousCursor?.endTime == report.previousEndTime,
          years == [
              YearListeningFootprint(year: 2025, playCount: 1_234, durationSeconds: 567_890),
              YearListeningFootprint(year: 2024, playCount: 987, durationSeconds: 3_600)
          ],
          annual.year == 2024,
          annual.overviewMetrics == [
              ListeningMetric(kind: .duration, value: .number(65_432)),
              ListeningMetric(kind: .plays, value: .number(321))
          ],
          annual.sections.map(\.id) == [
              "listening-methods", "annual-song", "annual-singer", "favorite-album",
              "annual-playlist", "genres", "discoveries", "seasons", "months",
              "listening-times", "late-listening", "loop-song", "crowd-memory",
              "monthly-moods", "listen-together", "singer-comparison", "keyword-firstKeyWord"
          ],
          annual.sections.first(where: { $0.id == "annual-playlist" })?.tracks.first?.song.id == 104,
          annual.sections.first(where: { $0.id == "annual-playlist" })?.tracks.first?.song.artists.first?.id == 204,
          annual.sections.first(where: { $0.id == "annual-singer" })?.tracks.first?.song.album.artwork.remoteURL
              == URL(string: "https://p1.music.126.net/example/singer-song.jpg"),
          annual.sections.first(where: { $0.id == "annual-song" })?.tracks.first?.caption == "First Artist / Second Artist",
          annual.sections.first(where: { $0.id == "genres" })?.items == [
              .genre(name: "Pop", percent: 60),
              .genre(name: "Rock", percent: 20),
              .genre(name: "Electronic", percent: 12),
              .genre(name: "Classical", percent: 8)
          ],
          annual.sections.first(where: { $0.id == "discoveries" })?.items == [
              .artist(
                  id: 401,
                  name: "New Artist",
                  imageURL: URL(string: "https://p1.music.126.net/example/new-artist.jpg"),
                  note: "新遇见 · 5 首歌"
              ),
              .artist(
                  id: 402,
                  name: "Frequent Artist",
                  imageURL: URL(string: "https://p1.music.126.net/example/frequent-artist.jpg"),
                  note: "常听歌手"
              )
          ],
          annual.sections.first(where: { $0.id == "months" })?.items == [
              .month(
                  month: 7,
                  durationSeconds: 7_200,
                  artistID: 403,
                  artistName: "July Artist",
                  imageURL: URL(string: "https://p1.music.126.net/example/july.jpg")
              )
          ],
          annual.sections.first(where: { $0.id == "monthly-moods" })?.items == [
              .mood(month: 7, name: "Calm", genre: "Ambient")
          ],
          annual.sections.first(where: { $0.id == "keyword-firstKeyWord" })?.tracks.first?.song.artists.first?.id == 208,
          memory.listenedAt == Date(timeIntervalSince1970: 1_704_067_200),
          memory.text == "Found in a daily recommendation"
    else { throw ListeningReportCheckError.failed }
}

private func verifyListeningEmptyFixture() throws {
    let fixture = try listeningFixture("listening-empty")
    let library = LiveMusicLibrary()
    guard try library.decodeTotalListeningDuration(fixtureObject(fixture, "total")) == 0,
          library.decodeListeningRank(try fixtureObject(fixture, "today")).isEmpty,
          library.decodeListeningRank(try fixtureObject(fixture, "rank")).isEmpty
    else { throw ListeningReportCheckError.failed }

    let realtime = library.decodeRealtimeListeningReport(
        try fixtureObject(fixture, "realtime"),
        period: .month
    )
    let report = library.decodeListeningReport(try fixtureObject(fixture, "report"), period: .month)
    guard realtime.metrics.isEmpty,
          report.metrics.isEmpty,
          report.topSongs.isEmpty,
          report.previousEndTime == nil
    else {
        throw ListeningReportCheckError.failed
    }
    guard library.decodeYearListeningFootprints(try fixtureObject(fixture, "year")).isEmpty
    else { throw ListeningReportCheckError.failed }
    guard library.decodeFirstListenMemory(try fixtureObject(fixture, "first")) == FirstListenMemory(
        listenedAt: nil,
        text: nil
    ) else { throw ListeningReportCheckError.failed }
}

private func verifyListeningMissingFixture() throws {
    let fixture = try listeningFixture("listening-missing")
    let library = LiveMusicLibrary()
    do {
        _ = try library.decodeTotalListeningDuration(fixtureObject(fixture, "total"))
        throw ListeningReportCheckError.failed
    } catch EAPIError.missingData(_) {
    }

    let report = library.decodeListeningReport(try fixtureObject(fixture, "report"), period: .week)
    let memory = library.decodeFirstListenMemory(
        try fixtureObject(fixture, "first"),
        now: Date(timeIntervalSince1970: 1_735_689_600)
    )
    let realtime = library.decodeRealtimeListeningReport(
        try fixtureObject(fixture, "realtime"),
        period: .week
    )
    guard library.decodeListeningRank(try fixtureObject(fixture, "today")).isEmpty,
          library.decodeListeningRank(try fixtureObject(fixture, "rank")).isEmpty,
          report.metrics.isEmpty,
          report.topSongs.isEmpty,
          report.previousCursor == nil,
          realtime.metrics.isEmpty,
          library.decodeYearListeningFootprints(try fixtureObject(fixture, "year")).isEmpty,
          memory.listenedAt == nil,
          memory.text == nil
    else { throw ListeningReportCheckError.failed }
}

private func verifyListeningNestedFixture() throws {
    let data = Data(#"{"code":200,"data":{"outer":{"level2":{"level3":{"level4":{"title":"Nested report","reportTitle":"Wrong report title","totalDuration":3600,"songCount":12,"totalSongCount":99,"albumCount":2,"previousEndTime":"1719705600000","level5":{"dayCount":365}}}}},"ranking":{"topSongBlock":{"playCount":88,"songItems":[{"songId":46,"songName":"Nested Song","artists":[{"id":15,"name":"Nested Artist"}],"albumId":16,"albumName":"Nested Album","playCount":8}]}},"rankEntryMetadata":{"songId":999,"artistCount":77}}}"#.utf8)
    guard let fixture = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw ListeningReportCheckError.failed
    }
    let report = LiveMusicLibrary().decodeListeningReport(
        fixture,
        period: .week
    )
    guard report.title == "Nested report",
          report.metrics == [
              ListeningMetric(kind: .duration, value: .number(3_600)),
              ListeningMetric(kind: .songs, value: .number(12)),
              ListeningMetric(kind: .albums, value: .number(2))
          ],
          report.topSongs.map(\.id) == [46],
          report.topSongs.first?.playCount == 8,
          report.previousEndTime == 1_719_705_600_000
    else { throw ListeningReportCheckError.failed }
}

private func verifyLegacyAnnualFixture() throws {
    let fixture = try listeningFixture("annual-report-legacy-userdata")
    let report = LiveMusicLibrary().decodeAnnualListeningReport(
        fixture,
        year: 2019
    )
    guard report.year == 2019,
          report.overviewMetrics == [
              ListeningMetric(kind: .duration, value: .number(3_600)),
              ListeningMetric(kind: .plays, value: .number(12))
          ],
          report.sections.map(\.id) == ["annual-playlist"],
          report.sections.first?.tracks.first?.song.id == 9_001,
          report.sections.first?.tracks.first?.song.name == "Synthetic legacy track"
    else { throw ListeningReportCheckError.failed }

    let middle = LiveMusicLibrary().decodeAnnualListeningReport(
        try fixtureObject(fixture, "middleYearFixture"),
        year: 2022
    )
    guard middle.year == 2022,
          middle.overviewMetrics == [
              ListeningMetric(kind: .duration, value: .number(7_200)),
              ListeningMetric(kind: .plays, value: .number(42))
          ],
          middle.sections.map(\.id) == ["annual-song"],
          middle.sections.first?.tracks.first?.song.id == 9_101,
          middle.sections.first?.tracks.first?.song.name == "Synthetic middle-year track",
          middle.sections.first?.tracks.first?.caption == "Middle Artist"
    else { throw ListeningReportCheckError.failed }
}

private func verifyInvalidListeningPeriods() async throws {
    do {
        _ = try await LiveMusicLibrary().listeningSongRank(
            period: .year,
            expectedCredentialRevision: 0
        )
        throw ListeningReportCheckError.failed
    } catch EAPIError.invalidPayload {
    }
    do {
        _ = try await LiveMusicLibrary().realtimeListeningReport(
            period: .year,
            expectedCredentialRevision: 0
        )
        throw ListeningReportCheckError.failed
    } catch EAPIError.invalidPayload {
    }
    do {
        _ = try await LiveMusicLibrary().annualListeningReport(
            year: 2025,
            expectedCredentialRevision: 0
        )
        throw ListeningReportCheckError.failed
    } catch EAPIError.invalidPayload {
    }
}

#if LISTENING_REPORT_CHECK
@main
private enum ListeningReportCheck {
    static func main() async throws {
        try verifyListeningSuccessFixture()
        try verifyListeningEmptyFixture()
        try verifyListeningMissingFixture()
        try verifyListeningNestedFixture()
        try verifyLegacyAnnualFixture()
        try await verifyInvalidListeningPeriods()
        print("Listening footprint fixture check passed")
    }
}
#elseif canImport(Testing)
@Suite("Listening footprints")
struct ListeningReportTests {
    @Test("Success fixtures decode stable data")
    func successFixture() throws { try verifyListeningSuccessFixture() }

    @Test("Empty responses remain valid")
    func emptyFixture() throws { try verifyListeningEmptyFixture() }

    @Test("Missing and unsafe values are ignored")
    func missingFixture() throws { try verifyListeningMissingFixture() }

    @Test("Nested searches preserve priority and depth")
    func nestedFixture() throws { try verifyListeningNestedFixture() }

    @Test("Synthetic legacy and middle-year responses preserve known fields and ignore unknown fields")
    func legacyAnnualFixture() throws { try verifyLegacyAnnualFixture() }

    @Test("Legacy and current annual reports use their versioned endpoint paths")
    func annualEndpointContract() async throws {
        AnnualReportEndpointProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AnnualReportEndpointProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let library = LiveMusicLibrary(transport: EAPITransport(
            session: session,
            cookie: "MUSIC_A=synthetic-fixture",
            musicU: ""
        ))

        let revision = library.transport.credentialSnapshotValue().revision
        _ = try await library.annualListeningReport(
            year: 2019,
            expectedCredentialRevision: revision
        )
        _ = try await library.annualListeningReport(
            year: 2020,
            expectedCredentialRevision: revision
        )
        #expect(AnnualReportEndpointProtocol.paths == [
            "/eapi/activity/summary/annual/2019/userdata",
            "/eapi/activity/summary/annual/2020/data"
        ])
    }

    @Test("Unsupported periods fail before networking")
    func invalidPeriods() async throws { try await verifyInvalidListeningPeriods() }
}

private final class AnnualReportEndpointProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var requestedPaths: [String] = []

    static var paths: [String] { lock.withLock { requestedPaths } }

    static func reset() {
        lock.withLock { requestedPaths = [] }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.withLock { Self.requestedPaths.append(request.url?.path ?? "") }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"code":200,"data":{}}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
#endif
