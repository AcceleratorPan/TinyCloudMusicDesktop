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
    let library = LiveMusicLibrary()
    guard try library.decodeTotalListeningDuration(fixtureObject(fixture, "total")) == 1_219_210
    else { throw ListeningReportCheckError.failed }

    let today = library.decodeListeningRank(try fixtureObject(fixture, "today"))
    let rank = library.decodeListeningRank(try fixtureObject(fixture, "rank"))
    let realtime = library.decodeListeningReport(try fixtureObject(fixture, "realtime"), period: .month)
    let report = library.decodeListeningReport(try fixtureObject(fixture, "report"), period: .week)
    let year = library.decodeListeningReport(try fixtureObject(fixture, "year"), period: .year)
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
              ListeningMetric(kind: .duration, value: .text("23 小时")),
              ListeningMetric(kind: .days, value: .number(9))
          ],
          report.title == "Weekly report",
          report.metrics.map(\.kind) == [.duration, .songs],
          report.topSongs.map(\.id) == [45],
          report.previousEndTime == 1_719_705_600_000,
          report.previousCursor?.endTime == report.previousEndTime,
          year.metrics.map(\.kind) == [.duration, .artists, .albums, .days],
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

    for key in ["realtime", "report", "year"] {
        let report = library.decodeListeningReport(try fixtureObject(fixture, key), period: .month)
        guard report.metrics.isEmpty, report.topSongs.isEmpty, report.previousEndTime == nil else {
            throw ListeningReportCheckError.failed
        }
    }
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
    guard library.decodeListeningRank(try fixtureObject(fixture, "today")).isEmpty,
          library.decodeListeningRank(try fixtureObject(fixture, "rank")).isEmpty,
          report.metrics.isEmpty,
          report.topSongs.isEmpty,
          report.previousCursor == nil,
          memory.listenedAt == nil,
          memory.text == nil
    else { throw ListeningReportCheckError.failed }
}

private func verifyInvalidListeningPeriods() async throws {
    do {
        _ = try await LiveMusicLibrary().listeningSongRank(period: .year)
        throw ListeningReportCheckError.failed
    } catch EAPIError.invalidPayload {
    }
    do {
        _ = try await LiveMusicLibrary().realtimeListeningReport(period: .year)
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

    @Test("Unsupported periods fail before networking")
    func invalidPeriods() async throws { try await verifyInvalidListeningPeriods() }
}
#endif
