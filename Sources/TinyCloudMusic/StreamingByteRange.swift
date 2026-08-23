import Foundation

struct StoredByteRange: Codable, Equatable, Sendable {
    let lowerBound: Int64
    let upperBound: Int64

    var range: Range<Int64> { lowerBound..<upperBound }
}

struct StreamingByteRangeSet: Equatable, Sendable {
    private(set) var ranges: [Range<Int64>] = []

    init(_ stored: [StoredByteRange] = []) {
        for range in stored where range.lowerBound >= 0 && range.lowerBound < range.upperBound {
            insert(range.range)
        }
    }

    mutating func insert(_ range: Range<Int64>) {
        guard range.lowerBound >= 0, range.lowerBound < range.upperBound else { return }

        var result: [Range<Int64>] = []
        var merged = range
        var inserted = false

        for existing in ranges {
            if existing.upperBound < merged.lowerBound {
                result.append(existing)
            } else if merged.upperBound < existing.lowerBound {
                if !inserted {
                    result.append(merged)
                    inserted = true
                }
                result.append(existing)
            } else {
                merged = min(existing.lowerBound, merged.lowerBound)..<max(existing.upperBound, merged.upperBound)
            }
        }

        if !inserted { result.append(merged) }
        ranges = result
    }

    func contiguousUpperBound(from offset: Int64) -> Int64? {
        ranges.first { $0.lowerBound <= offset && offset < $0.upperBound }?.upperBound
    }

    func contains(_ range: Range<Int64>) -> Bool {
        guard range.lowerBound >= 0, range.lowerBound < range.upperBound else { return false }
        return ranges.contains {
            $0.lowerBound <= range.lowerBound && range.upperBound <= $0.upperBound
        }
    }

    func covers(length: Int64) -> Bool {
        length > 0 && contains(0..<length)
    }

    var storedRanges: [StoredByteRange] {
        ranges.map { StoredByteRange(lowerBound: $0.lowerBound, upperBound: $0.upperBound) }
    }
}

enum HTTPContentRange: Equatable, Sendable {
    case bytes(range: Range<Int64>, completeLength: Int64)
    case unsatisfied(completeLength: Int64)

    init?(_ headerValue: String) {
        let header = headerValue.trimmingCharacters(in: Self.httpWhitespace)
        guard let separator = header.firstIndex(where: { $0 == " " || $0 == "\t" }),
              header[..<separator].caseInsensitiveCompare("bytes") == .orderedSame
        else { return nil }

        let value = String(header[separator...]).trimmingCharacters(in: Self.httpWhitespace)
        let components = value.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count == 2,
              let completeLength = Self.decimal(components[1]),
              completeLength > 0
        else { return nil }

        let rangeValue = components[0].trimmingCharacters(in: Self.httpWhitespace)
        if rangeValue == "*" {
            self = .unsatisfied(completeLength: completeLength)
            return
        }

        let bounds = rangeValue.split(separator: "-", omittingEmptySubsequences: false)
        guard bounds.count == 2,
              let lowerBound = Self.decimal(bounds[0]),
              let inclusiveUpperBound = Self.decimal(bounds[1]),
              lowerBound <= inclusiveUpperBound,
              inclusiveUpperBound < completeLength,
              inclusiveUpperBound != Int64.max
        else { return nil }

        self = .bytes(
            range: lowerBound..<(inclusiveUpperBound + 1),
            completeLength: completeLength
        )
    }

    private static func decimal(_ value: some StringProtocol) -> Int64? {
        let value = String(value).trimmingCharacters(in: httpWhitespace)
        guard !value.isEmpty,
              value.utf8.allSatisfy({ (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) })
        else { return nil }
        return Int64(value)
    }

    private static let httpWhitespace = CharacterSet(charactersIn: " \t")
}
