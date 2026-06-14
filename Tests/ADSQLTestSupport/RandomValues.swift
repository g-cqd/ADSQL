package import ADSQLKernel

/// Seeded generators for typed values, shared by codec property tests and
/// the relational model tests.
package enum RandomValues {
  package static func value(
    _ rng: inout SplitMix64, type: ColumnType, nullRatio: UInt64 = 10
  ) -> Value {
    if rng.next() % 100 < nullRatio { return .null }
    switch type {
    case .integer:
      switch rng.next() % 4 {
      case 0: return .integer(Int64(bitPattern: rng.next()))
      case 1: return .integer(Int64(rng.next() % 1000) - 500)
      case 2: return .integer(.min)
      default: return .integer(.max)
      }
    case .real:
      switch rng.next() % 5 {
      case 0: return .real(Double(Int64(bitPattern: rng.next())) / 1e6)
      case 1: return .real(-Double(rng.next() % 100_000) / 1e3)
      case 2: return .real(0)
      case 3: return .real(-0.0)
      default: return .real(Double(rng.next() % 1_000_000))
      }
    case .text:
      return .text(string(&rng))
    case .blob:
      return .blob(bytes(&rng, maxLength: 24))
    }
  }

  package static func string(_ rng: inout SplitMix64) -> String {
    let alphabet = Array("abcXYZ 0\u{0}é🦊".unicodeScalars)
    let length = Int(rng.next() % 12)
    var out = String.UnicodeScalarView()
    for _ in 0..<length {
      out.append(alphabet[Int(rng.next() % UInt64(alphabet.count))])
    }
    return String(out)
  }

  package static func bytes(_ rng: inout SplitMix64, maxLength: Int) -> [UInt8] {
    let length = Int(rng.next() % UInt64(maxLength + 1))
    // Bias toward 0x00/0xFF edges to stress escaping.
    return (0..<length).map { _ in
      switch rng.next() % 5 {
      case 0: return 0x00
      case 1: return 0xFF
      default: return UInt8(truncatingIfNeeded: rng.next())
      }
    }
  }

  package static func anyType(_ rng: inout SplitMix64) -> ColumnType {
    [ColumnType.integer, .real, .text, .blob][Int(rng.next() % 4)]
  }
}
