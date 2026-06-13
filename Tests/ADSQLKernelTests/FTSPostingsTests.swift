import Testing
@testable import ADSQLKernel

@Suite("FTS5 — F2a postings + stats codecs")
struct FTSPostingsTests {
  /// Builds `count` ascending-docid postings across `columns` fields.
  private func sample(count: Int, columns: Int, positions: Bool) -> [FTSPosting] {
    (0..<count).map { i in
      let docid = Int64(i * 7 + 3)
      let tfs = (0..<columns).map { c in UInt32((i + c) % 5 + 1) }
      let pos: [[UInt32]] =
        positions
        ? (0..<columns).map { c in
          let n = (i + c) % 4
          var acc: UInt32 = UInt32(c)
          return (0..<n).map { _ in acc += 2; return acc }
        }
        : []
      return FTSPosting(docid: docid, fieldTFs: tfs, positions: pos)
    }
  }

  @Test func postingsRoundTripMultiBlockWithPositions() throws {
    // 290 postings spans multiple 128-posting blocks.
    let original = sample(count: 290, columns: 3, positions: true)
    let bytes = FTSPostings.encode(original, columns: 3, storePositions: true)
    let decoded = try FTSPostings.decode(bytes, columns: 3, storePositions: true)
    #expect(decoded == original)
  }

  @Test func postingsRoundTripWithoutPositions() throws {
    let original = sample(count: 50, columns: 2, positions: false)
    let bytes = FTSPostings.encode(original, columns: 2, storePositions: false)
    let decoded = try FTSPostings.decode(bytes, columns: 2, storePositions: false)
    #expect(decoded == original)
    #expect(decoded.allSatisfy { $0.positions.isEmpty })
  }

  @Test func postingsBoundaryCounts() throws {
    for count in [0, 1, 128, 129, 256] {
      let original = sample(count: count, columns: 1, positions: true)
      let bytes = FTSPostings.encode(original, columns: 1, storePositions: true)
      let decoded = try FTSPostings.decode(bytes, columns: 1, storePositions: true)
      #expect(decoded == original, "count \(count)")
    }
  }

  @Test func docStatsRoundTrip() throws {
    let stats = FTSDocStats(fieldLengths: [12, 0, 4096, 7])
    #expect(try FTSDocStats.decode(stats.encode()) == stats)
  }

  @Test func globalStatsRoundTripAndAverages() throws {
    let stats = FTSGlobalStats(docCount: 1000, totalFieldLengths: [10_000, 500, 2_000])
    let decoded = try FTSGlobalStats.decode(stats.encode())
    #expect(decoded == stats)
    #expect(decoded.averageLength(field: 0) == 10.0)
    #expect(decoded.averageLength(field: 1) == 0.5)
    #expect(FTSGlobalStats().averageLength(field: 0) == 0)  // empty corpus
  }
}
