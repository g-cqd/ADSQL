/// The `trigram` tokenizer: every overlapping run of three characters is a
/// term (the basis for substring / `LIKE`-style matching), case-folded unless
/// `case_sensitive 1`. Positions are window indices; each term's source span
/// covers its three characters in the original bytes.
public struct TrigramTokenizer: FTSTokenizer {
  public let caseSensitive: Bool

  public init(caseSensitive: Bool = false) {
    self.caseSensitive = caseSensitive
  }

  public init(arguments: [String]) throws(DBError) {
    var caseSensitive = false
    var index = 0
    while index < arguments.count {
      let key = arguments[index].lowercased()
      guard index + 1 < arguments.count else {
        throw DBError.sqlUnsupported("trigram option '\(key)' needs a value")
      }
      let value = arguments[index + 1]
      index += 2
      switch key {
      case "case_sensitive":
        caseSensitive = value != "0"
      case "remove_diacritics":
        break  // accepted; diacritics are not stripped for trigram (SQLite default 0)
      default:
        throw DBError.sqlUnsupported("trigram option '\(key)'")
      }
    }
    self.caseSensitive = caseSensitive
  }

  public func tokenize(
    _ text: [UInt8], _ sink: (FTSToken) throws(DBError) -> Void
  ) throws(DBError) {
    // Decode once into (folded scalar, source byte offset, source byte width),
    // then slide a 3-wide window. TEXT is valid UTF-8 so offsets stay aligned.
    var units: [(scalar: Unicode.Scalar, start: Int, width: Int)] = []
    var offset = 0
    for scalar in String(decoding: text, as: UTF8.self).unicodeScalars {
      let width = UTF8Text.width(scalar)
      units.append((caseSensitive ? scalar : Self.fold(scalar), offset, width))
      offset += width
    }
    guard units.count >= 3 else { return }
    for i in 0...(units.count - 3) {
      var term: [UInt8] = []
      UTF8Text.append(units[i].scalar, to: &term)
      UTF8Text.append(units[i + 1].scalar, to: &term)
      UTF8Text.append(units[i + 2].scalar, to: &term)
      let end = units[i + 2].start + units[i + 2].width
      try sink(FTSToken(term: term, start: units[i].start, end: end, position: i))
    }
  }

  /// Single-scalar case fold (ASCII fast path; otherwise the first scalar of the
  /// stdlib lowercase mapping, keeping one character per trigram slot).
  static func fold(_ scalar: Unicode.Scalar) -> Unicode.Scalar {
    if (0x41...0x5A).contains(scalar.value) { return Unicode.Scalar(scalar.value + 0x20)! }
    if scalar.value < 0x80 { return scalar }
    return scalar.properties.lowercaseMapping.unicodeScalars.first ?? scalar
  }
}
