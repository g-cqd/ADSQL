import ADSQLKernel

/// Reference model for property tests: a plain dictionary with lexicographic
/// ordering on demand. Deliberately naive — correctness oracle, not fast.
public struct ModelStore: Sendable {
  public private(set) var entries: [[UInt8]: [UInt8]] = [:]

  public init() {}

  public var count: Int { entries.count }

  public mutating func put(_ key: [UInt8], _ value: [UInt8]) {
    entries[key] = value
  }

  @discardableResult
  public mutating func delete(_ key: [UInt8]) -> Bool {
    entries.removeValue(forKey: key) != nil
  }

  public func get(_ key: [UInt8]) -> [UInt8]? {
    entries[key]
  }

  /// All pairs in key order (memcmp order, matching the engine).
  public func sortedPairs() -> [(key: [UInt8], value: [UInt8])] {
    entries
      .map { (key: $0.key, value: $0.value) }
      .sorted { lexicographicallyPrecedes($0.key, $1.key) }
  }

  public func firstKey(atOrAfter key: [UInt8]) -> [UInt8]? {
    var best: [UInt8]?
    for k in entries.keys where !lexicographicallyPrecedes(k, key) {
      if let b = best, lexicographicallyPrecedes(b, k) { continue }
      best = k
    }
    return best
  }
}

/// Strict memcmp-order comparison: a < b.
public func lexicographicallyPrecedes(_ a: [UInt8], _ b: [UInt8]) -> Bool {
  let n = min(a.count, b.count)
  var i = 0
  while i < n {
    if a[i] != b[i] { return a[i] < b[i] }
    i += 1
  }
  return a.count < b.count
}
