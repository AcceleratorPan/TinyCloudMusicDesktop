import Testing
@testable import TinyCloudMusic

@Suite("Streaming byte ranges")
struct StreamingByteRangeTests {
    @Test("Ranges merge overlap and adjacency in either insertion order")
    func insertion() {
        var ranges = StreamingByteRangeSet()
        #expect(ranges.ranges.isEmpty)
        ranges.insert(10..<20)
        #expect(ranges.ranges == [10..<20])
        ranges.insert(20..<30)
        ranges.insert(0..<10)
        ranges.insert(4..<24)
        ranges.insert(-1..<2)
        ranges.insert(2..<2)

        #expect(ranges.ranges == [0..<30])
        #expect(ranges.contains(5..<25))
        #expect(!ranges.contains(29..<31))
    }

    @Test("Gaps, boundaries, coverage, and storage round-trip stay exact")
    func queries() {
        var ranges = StreamingByteRangeSet([
            StoredByteRange(lowerBound: 20, upperBound: 30),
            StoredByteRange(lowerBound: 0, upperBound: 10),
            StoredByteRange(lowerBound: 3, upperBound: 8),
            StoredByteRange(lowerBound: -1, upperBound: 1),
            StoredByteRange(lowerBound: 7, upperBound: 7),
        ])

        #expect(ranges.ranges == [0..<10, 20..<30])
        #expect(ranges.contiguousUpperBound(from: 0) == 10)
        #expect(ranges.contiguousUpperBound(from: 9) == 10)
        #expect(ranges.contiguousUpperBound(from: 10) == nil)
        #expect(ranges.contiguousUpperBound(from: 20) == 30)
        #expect(ranges.contiguousUpperBound(from: 30) == nil)
        #expect(!ranges.covers(length: -1))
        #expect(!ranges.covers(length: 0))
        #expect(!ranges.covers(length: 30))
        #expect(!StreamingByteRangeSet([
            StoredByteRange(lowerBound: 0, upperBound: 29)
        ]).covers(length: 30))

        ranges.insert(10..<20)
        #expect(ranges.covers(length: 30))
        #expect(StreamingByteRangeSet(ranges.storedRanges) == ranges)
    }

    @Test("Content-Range accepts bytes, unsatisfied, case, and HTTP whitespace")
    func validContentRanges() {
        #expect(HTTPContentRange("bytes 0-499/1000") == .bytes(range: 0..<500, completeLength: 1_000))
        #expect(HTTPContentRange("bytes */1000") == .unsatisfied(completeLength: 1_000))
        #expect(HTTPContentRange(" \tByTeS\t 0 - 499 / 1000 \t") == .bytes(range: 0..<500, completeLength: 1_000))
    }

    @Test("Content-Range rejects malformed and overflowing values", arguments: [
        "bytes -1-2/3",
        "bytes 2-1/3",
        "bytes 0-3/3",
        "bytes 0-0/0",
        "bytes */*",
        "bytes 0-1/*",
        "bytes 0-1/3, 4-5/6",
        "bytes 0-/3",
        "items 0-1/3",
        "bytes 0-9223372036854775807/9223372036854775807",
        "bytes 0-9223372036854775807/9223372036854775808",
    ])
    func invalidContentRanges(_ header: String) {
        #expect(HTTPContentRange(header) == nil)
    }
}
