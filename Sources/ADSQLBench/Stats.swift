import Darwin
import Foundation

struct BenchRNG: RandomNumberGenerator {
  private var state: UInt64
  init(seed: UInt64) { self.state = seed }
  mutating func next() -> UInt64 {
    state &+= 0x9E37_79B9_7F4A_7C15
    var z = state
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return z ^ (z >> 31)
  }
}

@inline(__always)
func nowNanos() -> UInt64 {
  clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
}

struct LatencyHistogram {
  var samples: [UInt64] = []

  mutating func record(_ nanos: UInt64) { samples.append(nanos) }
  mutating func reserve(_ n: Int) { samples.reserveCapacity(n) }

  var count: Int { samples.count }

  func percentile(_ p: Double) -> UInt64 {
    guard !samples.isEmpty else { return 0 }
    let sorted = samples.sorted()
    let rank = min(sorted.count - 1, Int(Double(sorted.count) * p))
    return sorted[rank]
  }

  func summary() -> String {
    let p50 = Double(percentile(0.50)) / 1000
    let p99 = Double(percentile(0.99)) / 1000
    let p999 = Double(percentile(0.999)) / 1000
    return String(format: "p50 %8.1fµs  p99 %8.1fµs  p99.9 %8.1fµs  (n=%d)", p50, p99, p999, count)
  }
}

/// Workload shaped like apple-docs document_chunks: text keys, ~580 B values.
enum Workload {
  static func key(_ index: Int) -> [UInt8] {
    let n = String(index)
    return Array(("chunk-" + String(repeating: "0", count: max(0, 8 - n.count)) + n).utf8)
  }

  static func value(_ index: Int, rng: inout BenchRNG) -> [UInt8] {
    let size = 520 + Int(rng.next() % 120) // ≈580 B like vec_i8 + text remnants
    var value = [UInt8](repeating: 0, count: size)
    var x = UInt64(index) &* 0x9E37
    for i in 0..<size {
      x = x &* 6364136223846793005 &+ 1442695040888963407
      value[i] = UInt8(truncatingIfNeeded: x >> 33)
    }
    return value
  }

  /// Skewed access (hot head) approximating Zipf-like document popularity.
  @inline(__always)
  static func skewedIndex(_ rng: inout BenchRNG, rows: Int) -> Int {
    let u = Double(rng.next() >> 11) * 0x1p-53
    return min(rows - 1, Int(Double(rows) * u * u * u))
  }
}

func formatRate(_ count: Int, _ nanos: UInt64) -> String {
  let seconds = Double(nanos) / 1e9
  let rate = Double(count) / seconds
  if rate > 1_000_000 { return String(format: "%.2fM/s", rate / 1_000_000) }
  if rate > 1_000 { return String(format: "%.1fk/s", rate / 1_000) }
  return String(format: "%.0f/s", rate)
}
