/// The `porter` tokenizer: runs a base tokenizer (default `unicode61`) then
/// applies the **classic Porter (1980) stemmer** to each ASCII term. SQLite
/// FTS5's `porter` uses the original Porter algorithm, so this matches it for
/// the F3 membership differential gate (Porter2/Snowball would diverge). Tokens
/// that aren't pure ASCII `a–z` pass through unchanged, as in SQLite.
public struct PorterTokenizer: FTSTokenizer {
  public let base: any FTSTokenizer

  public init(base: any FTSTokenizer) {
    self.base = base
  }

  public func tokenize(
    _ text: [UInt8], _ sink: (FTSToken) throws(DBError) -> Void
  ) throws(DBError) {
    try base.tokenize(text) { (token) throws(DBError) in
      var stemmed = token
      stemmed.term = Porter.stem(token.term)
      try sink(stemmed)
    }
  }
}

/// The original Porter stemming algorithm (Porter, 1980).
enum Porter {
  static func stem(_ word: [UInt8]) -> [UInt8] {
    guard word.count > 2 else { return word }
    for byte in word where !(0x61...0x7A).contains(byte) { return word }  // ASCII a–z only
    var stemmer = PorterStemmer(b: word)
    stemmer.step1a()
    stemmer.step1b()
    stemmer.step1c()
    stemmer.step2()
    stemmer.step3()
    stemmer.step4()
    stemmer.step5a()
    stemmer.step5b()
    return stemmer.b
  }
}

private struct PorterStemmer {
  var b: [UInt8]

  private static let a = UInt8(ascii: "a")
  private static let e = UInt8(ascii: "e")
  private static let i = UInt8(ascii: "i")
  private static let o = UInt8(ascii: "o")
  private static let u = UInt8(ascii: "u")
  private static let y = UInt8(ascii: "y")

  func isConsonant(_ index: Int) -> Bool {
    switch b[index] {
    case Self.a, Self.e, Self.i, Self.o, Self.u: return false
    case Self.y: return index == 0 ? true : !isConsonant(index - 1)
    default: return true
    }
  }

  /// Measure m of `b[0..<n]`: the number of vowel→consonant transitions.
  func measure(_ n: Int) -> Int {
    var m = 0
    var index = 0
    while index < n, isConsonant(index) { index += 1 }
    while index < n {
      while index < n, !isConsonant(index) { index += 1 }
      if index >= n { break }
      m += 1
      while index < n, isConsonant(index) { index += 1 }
    }
    return m
  }

  func containsVowel(_ n: Int) -> Bool {
    for index in 0..<n where !isConsonant(index) { return true }
    return false
  }

  func endsDoubleConsonant() -> Bool {
    let n = b.count
    return n >= 2 && b[n - 1] == b[n - 2] && isConsonant(n - 1)
  }

  /// The last three letters are consonant–vowel–consonant and the final
  /// consonant is not w, x or y.
  func endsCVC() -> Bool {
    let n = b.count
    guard n >= 3, isConsonant(n - 3), !isConsonant(n - 2), isConsonant(n - 1) else { return false }
    let last = b[n - 1]
    return last != UInt8(ascii: "w") && last != UInt8(ascii: "x") && last != Self.y
  }

  func ends(_ suffix: String) -> Bool {
    let bytes = suffix.utf8
    guard b.count >= bytes.count else { return false }
    return b.suffix(bytes.count).elementsEqual(bytes)
  }

  mutating func replaceSuffix(_ oldLength: Int, _ replacement: String) {
    b.removeLast(oldLength)
    b.append(contentsOf: replacement.utf8)
  }

  // MARK: Steps

  mutating func step1a() {
    if ends("sses") { b.removeLast(2) }  // sses → ss
    else if ends("ies") { b.removeLast(2) }  // ies → i
    else if ends("ss") { /* keep */ }
    else if ends("s") { b.removeLast(1) }
  }

  mutating func step1b() {
    if ends("eed") {
      if measure(b.count - 3) > 0 { b.removeLast(1) }  // (m>0) eed → ee
    } else if ends("ed"), containsVowel(b.count - 2) {
      b.removeLast(2)
      step1bPostfix()
    } else if ends("ing"), containsVowel(b.count - 3) {
      b.removeLast(3)
      step1bPostfix()
    }
  }

  mutating func step1bPostfix() {
    if ends("at") { replaceSuffix(2, "ate") }
    else if ends("bl") { replaceSuffix(2, "ble") }
    else if ends("iz") { replaceSuffix(2, "ize") }
    else if endsDoubleConsonant() {
      let last = b[b.count - 1]
      if last != UInt8(ascii: "l"), last != UInt8(ascii: "s"), last != UInt8(ascii: "z") {
        b.removeLast(1)
      }
    } else if measure(b.count) == 1, endsCVC() {
      b.append(Self.e)
    }
  }

  mutating func step1c() {
    if ends("y"), containsVowel(b.count - 1) { b[b.count - 1] = Self.i }
  }

  mutating func step2() {
    // Suffixes ordered so a proper-suffix never preempts a longer match
    // (e.g. "ational" before "tional", "ization" before "ation").
    let rules: [(String, String)] = [
      ("ational", "ate"), ("tional", "tion"), ("enci", "ence"), ("anci", "ance"),
      ("izer", "ize"), ("abli", "able"), ("alli", "al"), ("entli", "ent"), ("eli", "e"),
      ("ousli", "ous"), ("ization", "ize"), ("ation", "ate"), ("ator", "ate"),
      ("alism", "al"), ("iveness", "ive"), ("fulness", "ful"), ("ousness", "ous"),
      ("aliti", "al"), ("iviti", "ive"), ("biliti", "ble"),
    ]
    for (suffix, replacement) in rules where ends(suffix) {
      if measure(b.count - suffix.utf8.count) > 0 { replaceSuffix(suffix.utf8.count, replacement) }
      return
    }
  }

  mutating func step3() {
    let rules: [(String, String)] = [
      ("icate", "ic"), ("ative", ""), ("alize", "al"), ("iciti", "ic"),
      ("ical", "ic"), ("ful", ""), ("ness", ""),
    ]
    for (suffix, replacement) in rules where ends(suffix) {
      if measure(b.count - suffix.utf8.count) > 0 { replaceSuffix(suffix.utf8.count, replacement) }
      return
    }
  }

  mutating func step4() {
    // "ement" before "ment" before "ent"; "ion" handled separately (needs s/t).
    let suffixes = [
      "al", "ance", "ence", "er", "ic", "able", "ible", "ant", "ement", "ment", "ent",
      "ou", "ism", "ate", "iti", "ous", "ive", "ize",
    ]
    for suffix in suffixes where ends(suffix) {
      if measure(b.count - suffix.utf8.count) > 1 { b.removeLast(suffix.utf8.count) }
      return
    }
    if ends("ion") {
      let stemLength = b.count - 3
      if stemLength > 0, measure(stemLength) > 1 {
        let prior = b[stemLength - 1]
        if prior == UInt8(ascii: "s") || prior == UInt8(ascii: "t") { b.removeLast(3) }
      }
    }
  }

  mutating func step5a() {
    guard ends("e") else { return }
    let stemMeasure = measure(b.count - 1)
    if stemMeasure > 1 {
      b.removeLast(1)
    } else if stemMeasure == 1 {
      b.removeLast(1)
      if endsCVC() { b.append(Self.e) }  // restore: (m=1 and *o) keeps the e
    }
  }

  mutating func step5b() {
    let n = b.count
    if measure(n) > 1, endsDoubleConsonant(), b[n - 1] == UInt8(ascii: "l") { b.removeLast(1) }
  }
}
