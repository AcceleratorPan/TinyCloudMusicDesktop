import Foundation
import SwiftUI
import XCTest
@testable import TinyCloudMusic

final class IOSNavigationTests: XCTestCase {
    func testPlaylistPagingUsesPhoneSizedBatches() {
        XCTAssertEqual(PlaylistSongPaging.initialRange(total: 2_000), 0..<50)
        XCTAssertEqual(PlaylistSongPaging.nextRange(total: 2_000, loaded: 50), 50..<100)
    }

    func testMainTabsRemainUniqueAndBounded() {
        XCTAssertEqual(IOSMainTab.allCases.count, 5)
        XCTAssertEqual(Set(IOSMainTab.allCases.map(\.title)).count, 5)
        XCTAssertEqual(Set(IOSMainTab.allCases.map(\.symbol)).count, 5)
    }

    func testTopTabsStartAtTopAndRestorePreviousOffset() {
        let positions = TopTabScrollPositions(selection: "overview")

        XCTAssertEqual(positions.target(for: "daily", currentOffset: 240), 0)
        XCTAssertEqual(positions.target(for: "playlists", currentOffset: 80), 0)
        XCTAssertEqual(positions.target(for: "overview", currentOffset: 55), 240)
        XCTAssertEqual(positions.target(for: "daily", currentOffset: 240), 80)

        let clamped = TopTabScrollPositions(selection: "first")
        XCTAssertEqual(clamped.target(for: "second", currentOffset: -20), 0)
        XCTAssertEqual(clamped.target(for: "first", currentOffset: 10), 0)
    }

    func testListeningReportPeriodsKeepIndependentScrollOffsets() {
        let positions = TopTabScrollPositions(selection: FootprintPeriod.week)

        XCTAssertEqual(positions.target(for: .month, currentOffset: 360), 0)
        XCTAssertEqual(positions.target(for: .week, currentOffset: 120), 360)
        XCTAssertEqual(positions.target(for: .month, currentOffset: 360), 120)
        XCTAssertEqual(positions.target(for: .year, currentOffset: 120), 0)
    }

    func testTypographyStepUsesPreviousDynamicTypeSize() {
        let sizes: [DynamicTypeSize] = [
            .xSmall, .small, .medium, .large, .xLarge, .xxLarge, .xxxLarge,
            .accessibility1, .accessibility2, .accessibility3, .accessibility4, .accessibility5,
        ]

        XCTAssertEqual(
            sizes.map(\.oneStepSmaller),
            [.xSmall, .xSmall, .small, .medium, .large, .xLarge, .xxLarge,
             .xxxLarge, .accessibility1, .accessibility2, .accessibility3, .accessibility4]
        )
    }

    func testEmptySimilarPlaylistsHideTheirTab() {
        XCTAssertEqual(IOSPlaylistDetailSection.visible(hasSimilarPlaylists: false), [.songs])
        XCTAssertEqual(
            IOSPlaylistDetailSection.visible(hasSimilarPlaylists: true),
            [.songs, .similarPlaylists]
        )
    }

    @MainActor
    func testDetailTitleUsesGreedyMultilineSizing() {
        let label = IOSGreedyTitle.makeLabel()
        IOSGreedyTitle.configure(label, text: "寻声广州 ｜戴上耳机 漫游广东")
        let size = IOSGreedyTitle.fittingSize(of: label, width: 242)

        XCTAssertTrue(label.lineBreakStrategy.isEmpty)
        XCTAssertEqual(size.width, 242)
        XCTAssertGreaterThan(size.height, label.font.lineHeight)
    }

    func testNowPlayingDownloadActionsMatchTransferState() {
        XCTAssertEqual(IOSDownloadAction(state: nil), .start)
        XCTAssertEqual(IOSDownloadAction(state: .queued), .pause)
        XCTAssertEqual(IOSDownloadAction(state: .running(progress: 0.5)), .pause)
        XCTAssertEqual(IOSDownloadAction(state: .paused(progress: 0.5)), .retry)
        XCTAssertEqual(IOSDownloadAction(state: .failed("offline")), .retry)
        XCTAssertEqual(IOSDownloadAction(state: .cancelled), .start)
        XCTAssertEqual(
            IOSDownloadAction(
                state: .completed(audioURL: URL(fileURLWithPath: "/tmp/song.mp3"), lyricURL: nil)
            ),
            .none
        )
    }

    func testNowPlayingMarqueeScrollsOnlyAfterOverflowAndDelay() {
        XCTAssertEqual(IOSMarquee.offset(elapsed: 2, textWidth: 40, viewportWidth: 40, gap: 32), 0)
        XCTAssertEqual(IOSMarquee.offset(elapsed: 1.2, textWidth: 80, viewportWidth: 40, gap: 32), 0)
        XCTAssertEqual(
            IOSMarquee.offset(elapsed: 2.2, textWidth: 80, viewportWidth: 40, gap: 32),
            -28,
            accuracy: 0.000_001
        )
    }

    func testFirstListenMemoryIsVisibleOnlyWithUsableContent() {
        XCTAssertTrue(FirstListenMemory(listenedAt: nil, text: nil).isEmpty)
        XCTAssertTrue(FirstListenMemory(listenedAt: nil, text: "").isEmpty)
        XCTAssertFalse(FirstListenMemory(listenedAt: Date(timeIntervalSince1970: 1), text: nil).isEmpty)
        XCTAssertFalse(FirstListenMemory(listenedAt: nil, text: "来自每日推荐").isEmpty)
    }

    @MainActor
    func testHomeLoadsOnlyRequestedSections() async throws {
        let suiteName = "IOSNavigationTests.home.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(["daily", "moods", "new"], forKey: "homeSectionIDs")
        let model = AppModel(
            repository: FixtureMusicRepository(),
            defaults: defaults,
            bookmarkResolver: { _ in nil }
        )

        model.loadHome()
        try await Task.sleep(for: .milliseconds(450))
        XCTAssertFalse(model.homeSlots.contains { if case .loaded = $0.load { true } else { false } })

        model.loadHomeSectionIfNeeded(id: "daily")
        for _ in 0..<20 {
            if case .loaded = model.homeSlots.first(where: { $0.id == "daily" })?.load { break }
            try await Task.sleep(for: .milliseconds(50))
        }

        guard case .loaded = model.homeSlots.first(where: { $0.id == "daily" })?.load else {
            return XCTFail("The requested home section did not load")
        }
        XCTAssertFalse(model.homeSlots.dropFirst().contains {
            if case .loaded = $0.load { true } else { false }
        })
    }

    func testPhoneLoginUsesExpectedWEAPIContract() throws {
        XCTAssertEqual(IOSPhoneLoginRequest.normalizedPhone("+86 138-0013-8000"), "13800138000")
        XCTAssertNil(IOSPhoneLoginRequest.normalizedPhone("1380013800x"))
        XCTAssertNil(IOSPhoneLoginRequest.normalizedPhone("12800138000"))
        XCTAssertEqual(IOSPhoneLoginRequest.normalizedCode(" 1234 "), "1234")
        XCTAssertNil(IOSPhoneLoginRequest.normalizedCode("12ab"))

        let captcha = try IOSPhoneLoginRequest.captchaPayload(phone: "13800138000")
        XCTAssertEqual(captcha["ctcode"] as? String, "86")
        XCTAssertEqual(captcha["cellphone"] as? String, "13800138000")
        XCTAssertEqual(captcha["secrete"] as? String, "music_middleuser_pclogin")

        let login = try IOSPhoneLoginRequest.loginPayload(phone: "13800138000", code: "1234")
        XCTAssertEqual(login["countrycode"] as? String, "86")
        XCTAssertEqual(login["captcha"] as? String, "1234")
        XCTAssertEqual(login["remember"] as? String, "true")

        let cookie = IOSPhoneLoginRequest.cookieHeader(
            baseCookie: "MUSIC_A=guest-token",
            deviceID: "test-device",
            now: Date(timeIntervalSince1970: 1_700_000_000)
        )
        XCTAssertTrue(cookie.contains("deviceId=test-device"))
        XCTAssertTrue(cookie.contains("MUSIC_A=guest-token"))
        XCTAssertTrue(cookie.contains("os=pc"))
    }

    func testMultipartXMLIsStableAndEscaped() {
        let body = NOSMultipartXML.body(parts: [
            AudioUploadPart(number: 2, etag: "second"),
            AudioUploadPart(number: 1, etag: "<&>\"'")
        ])

        XCTAssertEqual(
            String(decoding: body, as: UTF8.self),
            "<CompleteMultipartUpload>"
                + "<Part><PartNumber>1</PartNumber><ETag>&lt;&amp;&gt;&quot;&apos;</ETag></Part>"
                + "<Part><PartNumber>2</PartNumber><ETag>second</ETag></Part>"
                + "</CompleteMultipartUpload>"
        )
    }

    func testNIMChatroomMessageAdapterPreservesAttachmentAndGeneration() {
        let raw = #"{"content":{"type":20002,"content":{}}}"#

        XCTAssertEqual(
            IOSNIMChatroomMessageAdapter.event(
                rawAttachContent: raw,
                remoteExtension: nil,
                text: nil,
                generation: 17
            ),
            .message(raw: raw, generation: 17)
        )
    }

    func testNIMChatroomMessageAdapterFallsBackToServerExtension() throws {
        let event = try XCTUnwrap(IOSNIMChatroomMessageAdapter.event(
            rawAttachContent: "not-json",
            remoteExtension: [
                "serverExt": ["type": 20_003, "content": ["reason": "ROOM_EMPTY"]]
            ],
            text: nil,
            generation: 4
        ))
        guard case let .message(raw, generation) = event else {
            return XCTFail("Expected a message event")
        }

        XCTAssertEqual(generation, 4)
        XCTAssertEqual(
            try ListenTogetherResponseDecoder.remoteEvent(from: raw),
            .roomEnded(reason: "ROOM_EMPTY")
        )
    }

    func testNIMChatroomMessageAdapterRejectsInvalidAndOversizedPayloads() {
        XCTAssertNil(IOSNIMChatroomMessageAdapter.event(
            rawAttachContent: "[]",
            remoteExtension: nil,
            text: "plain text",
            generation: 1
        ))
        XCTAssertNil(IOSNIMChatroomMessageAdapter.event(
            rawAttachContent: #"{"value":""# + String(repeating: "x", count: 65_537) + #""}"#,
            remoteExtension: nil,
            text: nil,
            generation: 1
        ))
    }
}
