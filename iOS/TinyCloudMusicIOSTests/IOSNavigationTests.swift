import XCTest
@testable import TinyCloudMusic

final class IOSNavigationTests: XCTestCase {
    func testMainTabsRemainUniqueAndBounded() {
        XCTAssertEqual(IOSMainTab.allCases.count, 5)
        XCTAssertEqual(Set(IOSMainTab.allCases.map(\.title)).count, 5)
        XCTAssertEqual(Set(IOSMainTab.allCases.map(\.symbol)).count, 5)
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
