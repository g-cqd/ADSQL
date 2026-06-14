/// Doc/field length statistics (M5/F2) for bm25f length normalization. Per-doc
/// field lengths live in the stats tree keyed by docid; a single global row
/// (keyed by a reserved sentinel) holds the corpus totals so `avgdl[field] =
/// totalFieldLengths[field] / docCount` is an O(1) read at query time.

/// Per-document token counts, one per column.
public struct FTSDocStats: Equatable, Sendable {
    public var fieldLengths: [UInt32]

    public init(fieldLengths: [UInt32]) {
        self.fieldLengths = fieldLengths
    }

    public func encode() -> [UInt8] {
        var out: [UInt8] = []
        Varint.append(UInt64(fieldLengths.count), to: &out)
        for length in fieldLengths { Varint.append(UInt64(length), to: &out) }
        return out
    }

    public static func decode(_ bytes: [UInt8]) throws(DBError) -> FTSDocStats {
        var offset = 0
        guard let count = Varint.read(bytes, &offset) else {
            throw DBError.integrityFailure("fts doc stats: missing field count")
        }
        var lengths: [UInt32] = []
        lengths.reserveCapacity(Int(count))
        for _ in 0..<Int(count) {
            guard let length = Varint.read(bytes, &offset) else {
                throw DBError.integrityFailure("fts doc stats: truncated field length")
            }
            lengths.append(UInt32(truncatingIfNeeded: length))
        }
        return FTSDocStats(fieldLengths: lengths)
    }
}

/// Corpus aggregates: document count and per-field length sums.
public struct FTSGlobalStats: Equatable, Sendable {
    public var docCount: UInt64
    public var totalFieldLengths: [UInt64]

    public init(docCount: UInt64 = 0, totalFieldLengths: [UInt64] = []) {
        self.docCount = docCount
        self.totalFieldLengths = totalFieldLengths
    }

    /// Average length of `field` across the corpus (0 when empty).
    public func averageLength(field: Int) -> Double {
        guard docCount > 0, field < totalFieldLengths.count else { return 0 }
        return Double(totalFieldLengths[field]) / Double(docCount)
    }

    public func encode() -> [UInt8] {
        var out: [UInt8] = []
        Varint.append(docCount, to: &out)
        Varint.append(UInt64(totalFieldLengths.count), to: &out)
        for total in totalFieldLengths { Varint.append(total, to: &out) }
        return out
    }

    public static func decode(_ bytes: [UInt8]) throws(DBError) -> FTSGlobalStats {
        var offset = 0
        guard let docCount = Varint.read(bytes, &offset), let count = Varint.read(bytes, &offset) else {
            throw DBError.integrityFailure("fts global stats: truncated header")
        }
        var totals: [UInt64] = []
        totals.reserveCapacity(Int(count))
        for _ in 0..<Int(count) {
            guard let total = Varint.read(bytes, &offset) else {
                throw DBError.integrityFailure("fts global stats: truncated field total")
            }
            totals.append(total)
        }
        return FTSGlobalStats(docCount: docCount, totalFieldLengths: totals)
    }
}
