/// A hashable, collation-aware grouping key for GROUP BY, DISTINCT, and
/// compound (UNION) deduplication. Canonicalization matches SQLite's grouping
/// equality: numeric classes unify (1 and 1.0 group together via an integral
/// REAL folding to INTEGER), NULLs are equal to each other, and text under a
/// NOCASE collation is ASCII-folded. `Value` itself stays non-Hashable.
struct GroupKey: Hashable {
  let parts: [Part]

  enum Part: Hashable {
    case null
    case integer(Int64)
    case real(Double)     // only non-integral reals reach here
    case text([UInt8])    // raw, or NOCASE-folded, bytes
    case blob([UInt8])
  }

  init(_ values: [Value], collations: [Collation]) {
    self.parts = values.enumerated().map { index, value in
      Self.canonicalize(value, collation: collations[index])
    }
  }

  static func canonicalize(_ value: Value, collation: Collation) -> Part {
    switch value {
    case .null:
      return .null
    case .integer(let i):
      return .integer(i)
    case .real(let d):
      // Group 1.0 with 1: fold an integral real that fits Int64 to INTEGER.
      if d.rounded() == d && d >= -9.223372036854776e18 && d < 9.223372036854776e18 {
        return .integer(Int64(d))
      }
      return .real(d)
    case .text(let s):
      let bytes = Array(s.utf8)
      return .text(collation == .nocase ? KeyCodec.asciiFolded(bytes) : bytes)
    case .blob(let b):
      return .blob(b)
    }
  }
}
