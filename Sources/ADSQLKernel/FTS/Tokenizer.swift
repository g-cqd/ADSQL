/// FTS tokenization (M5/F1). A `Tokenizer` turns a column's UTF-8 bytes into a
/// stream of terms, each carrying its source byte span (for highlight/snippet)
/// and its sequential position (for phrase queries). The index build (F2) drives
/// these into postings; the MATCH query layer (F3) tokenizes the query string
/// with the same tokenizer so terms line up.
///
/// Implementations are pure value logic — no `unsafe`. Decoding/encoding and
/// classification use the Swift standard library's native Unicode facilities
/// (`String.unicodeScalars`, the `Unicode.UTF8` codec, `Unicode.Scalar.Properties`),
/// not Foundation, with an ASCII fast path on the hot loop.

public struct FTSToken: Equatable, Sendable {
  /// The indexed term (folded / stemmed bytes, UTF-8).
  public var term: [UInt8]
  /// Byte offset of the term's source in the input (inclusive).
  public var start: Int
  /// Byte offset just past the term's source in the input (exclusive).
  public var end: Int
  /// 0-based token position within the input.
  public var position: Int

  public init(term: [UInt8], start: Int, end: Int, position: Int) {
    self.term = term
    self.start = start
    self.end = end
    self.position = position
  }
}

public protocol FTSTokenizer: Sendable {
  /// Streams tokens to `sink`. The sink may throw `DBError` (e.g. a posting
  /// write); tokenization itself never fails, so errors propagate from `sink`.
  func tokenize(
    _ text: [UInt8], _ sink: (FTSToken) throws(DBError) -> Void
  ) throws(DBError)
}

extension FTSTokenizer {
  /// Collects every token into an array (tests + non-streaming callers).
  public func allTokens(_ text: [UInt8]) throws(DBError) -> [FTSToken] {
    var out: [FTSToken] = []
    try tokenize(text) { (token) throws(DBError) in out.append(token) }
    return out
  }

  /// Convenience over a Swift string (UTF-8).
  public func allTokens(_ text: String) throws(DBError) -> [FTSToken] {
    try allTokens(Array(text.utf8))
  }
}

// MARK: - Factory

/// Builds a tokenizer from a parsed `tokenize=` spec (`FTSDefinition.tokenize`),
/// e.g. `["porter","unicode61"]`, `["trigram","case_sensitive","0"]`,
/// `["unicode61","remove_diacritics","2"]`. `porter` wraps a base tokenizer
/// (default `unicode61`).
public enum FTSTokenizerFactory {
  public static func make(_ spec: [String]) throws(DBError) -> any FTSTokenizer {
    guard let name = spec.first?.lowercased() else { return Unicode61Tokenizer() }
    let arguments = Array(spec.dropFirst())
    switch name {
    case "unicode61":
      return try Unicode61Tokenizer(arguments: arguments)
    case "porter":
      let base = try make(arguments.isEmpty ? ["unicode61"] : arguments)
      return PorterTokenizer(base: base)
    case "trigram":
      return try TrigramTokenizer(arguments: arguments)
    default:
      throw DBError.sqlUnsupported("fts5 tokenizer '\(name)'")
    }
  }
}

// MARK: - UTF-8 helpers (native `Unicode.UTF8` codec)

/// Thin wrappers over the standard library's `Unicode.UTF8` codec so tokenizers
/// stay free of hand-rolled bit twiddling. Tokenizers decode input with
/// `String(decoding:as:).unicodeScalars` (input is always valid UTF-8 — TEXT is
/// stored from Swift `String.utf8`) and track source byte offsets with `width`.
enum UTF8Text {
  /// A scalar's UTF-8 byte width via the native encoder (1 for ASCII).
  @inline(__always)
  static func width(_ scalar: Unicode.Scalar) -> Int {
    scalar.value < 0x80 ? 1 : (Unicode.UTF8.encode(scalar)?.count ?? 0)
  }

  /// Appends a scalar's UTF-8 encoding to `out` via the native encoder.
  @inline(__always)
  static func append(_ scalar: Unicode.Scalar, to out: inout [UInt8]) {
    if let encoded = Unicode.UTF8.encode(scalar) { out.append(contentsOf: encoded) }
  }
}
