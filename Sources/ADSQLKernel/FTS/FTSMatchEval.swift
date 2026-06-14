/// Boolean MATCH evaluation (M5/F3b). Turns an `FTSQuery` (F3a) into a
/// docid-ascending match set over the F2 index: terms/prefixes/phrases resolve
/// to postings, the operators are sorted-set merges, and `col:` restricts by
/// field. Query phrase text is tokenized with the table's own tokenizer, so
/// `Running` matches the indexed stem `run`. Membership only — ranking is F4.
enum FTSMatch {
  static func evaluate(
    _ query: FTSQuery, record: Catalog.FTSRecord, resolver: some PageResolver,
    columns: Set<Int>? = nil
  ) throws(DBError) -> [Int64] {
    let matcher = try Matcher(record: record, resolver: resolver)
    return try matcher.eval(query, columns: columns)
  }

  struct Matcher<R: PageResolver> {
    let record: Catalog.FTSRecord
    let resolver: R
    let tokenizer: any FTSTokenizer

    init(record: Catalog.FTSRecord, resolver: R) throws(DBError) {
      self.record = record
      self.resolver = resolver
      self.tokenizer = try FTSTokenizerFactory.make(record.definition.tokenize)
    }

    func eval(_ query: FTSQuery, columns: Set<Int>?) throws(DBError) -> [Int64] {
      switch query {
      case .phrase(let text, let prefix):
        return try evalPhrase(text: text, prefix: prefix, columns: columns)
      case .and(let lhs, let rhs):
        return FTSMatch.intersect(try eval(lhs, columns: columns), try eval(rhs, columns: columns))
      case .or(let lhs, let rhs):
        return FTSMatch.union(try eval(lhs, columns: columns), try eval(rhs, columns: columns))
      case .not(let lhs, let rhs):
        return FTSMatch.difference(try eval(lhs, columns: columns), try eval(rhs, columns: columns))
      case .column(let names, let inner):
        return try eval(inner, columns: try restrict(columns, to: names))
      }
    }

    private func restrict(_ current: Set<Int>?, to names: [String]) throws(DBError) -> Set<Int> {
      var resolved = Set<Int>()
      for name in names {
        guard let index = record.definition.columns.firstIndex(of: name) else {
          throw DBError.sqlRuntime("no such column \(name) in FTS table \(record.definition.name)")
        }
        resolved.insert(index)
      }
      return current.map { $0.intersection(resolved) } ?? resolved
    }

    // MARK: phrases / terms

    private func evalPhrase(
      text: String, prefix: Bool, columns: Set<Int>?
    ) throws(DBError) -> [Int64] {
      let tokens = try tokenizer.allTokens(Array(text.utf8)).map(\.term)
      if tokens.isEmpty { return [] }
      if tokens.count == 1 { return try evalTerm(tokens[0], prefix: prefix, columns: columns) }
      guard record.definition.detail != .none else {
        throw DBError.sqlUnsupported("phrase MATCH requires detail=full|column")
      }
      return try evalPhraseTokens(tokens, prefix: prefix, columns: columns)
    }

    private func evalTerm(
      _ term: [UInt8], prefix: Bool, columns: Set<Int>?
    ) throws(DBError) -> [Int64] {
      if !prefix { return try docids(term, columns: columns) }
      var result: [Int64] = []
      for expansion in try FTSIndex.termsMatchingPrefix(resolver, record, prefix: term) {
        result = FTSMatch.union(result, try docids(expansion, columns: columns))
      }
      return result
    }

    /// Docids of a single term, optionally restricted to documents where the
    /// term occurs in one of `columns` (via the per-field term frequencies).
    private func docids(_ term: [UInt8], columns: Set<Int>?) throws(DBError) -> [Int64] {
      // No column filter: membership needs only docids — take the F6e fast path
      // that skips each doc's TF/position payload.
      guard let columns else { return try FTSIndex.docids(resolver, record, term: term) ?? [] }
      guard let postings = try FTSIndex.postings(resolver, record, term: term) else { return [] }
      return postings.compactMap { posting in
        columns.contains { $0 < posting.fieldTFs.count && posting.fieldTFs[$0] > 0 }
          ? posting.docid : nil
      }
    }

    private func evalPhraseTokens(
      _ tokens: [[UInt8]], prefix: Bool, columns: Set<Int>?
    ) throws(DBError) -> [Int64] {
      guard prefix else { return try phraseAdjacency(tokens, columns: columns) }
      // Trailing `*`: expand the last token over its prefix terms, OR the phrases.
      var result: [Int64] = []
      let last = tokens[tokens.count - 1]
      for expansion in try FTSIndex.termsMatchingPrefix(resolver, record, prefix: last) {
        var expanded = tokens
        expanded[expanded.count - 1] = expansion
        result = FTSMatch.union(result, try phraseAdjacency(expanded, columns: columns))
      }
      return result
    }

    /// Docids where `tokens` occur at consecutive positions within one allowed
    /// column (`pos[t]+1 == pos[t+1]`).
    private func phraseAdjacency(_ tokens: [[UInt8]], columns: Set<Int>?) throws(DBError) -> [Int64] {
      var perToken: [[Int64: FTSPosting]] = []
      for token in tokens {
        guard let postings = try FTSIndex.postings(resolver, record, term: token) else { return [] }
        var byDoc: [Int64: FTSPosting] = [:]
        for posting in postings { byDoc[posting.docid] = posting }
        perToken.append(byDoc)
      }
      var candidates = Set(perToken[0].keys)
      for byDoc in perToken.dropFirst() { candidates.formIntersection(byDoc.keys) }
      let allowed = columns ?? Set(0..<record.definition.columns.count)
      var result: [Int64] = []
      for docid in candidates where phraseHit(perToken, docid: docid, columns: allowed) {
        result.append(docid)
      }
      return result.sorted()
    }

    private func phraseHit(
      _ perToken: [[Int64: FTSPosting]], docid: Int64, columns: Set<Int>
    ) -> Bool {
      for column in columns {
        guard let first = perToken[0][docid]?.positions, column < first.count else { continue }
        let starts = first[column]
        if starts.isEmpty { continue }
        var followers: [Set<UInt32>] = []
        var usable = true
        for index in 1..<perToken.count {
          guard let positions = perToken[index][docid]?.positions, column < positions.count else {
            usable = false
            break
          }
          followers.append(Set(positions[column]))
        }
        guard usable else { continue }
        for start in starts {
          var matched = true
          for (offset, set) in followers.enumerated() where !set.contains(start + UInt32(offset + 1)) {
            matched = false
            break
          }
          if matched { return true }
        }
      }
      return false
    }

    // MARK: sorted-set merges (inputs docid-ascending & deduped)
  }

  static func union(_ a: [Int64], _ b: [Int64]) -> [Int64] {
    var out: [Int64] = []
    out.reserveCapacity(a.count + b.count)
    var i = 0
    var j = 0
    while i < a.count, j < b.count {
      if a[i] == b[j] { out.append(a[i]); i += 1; j += 1 }
      else if a[i] < b[j] { out.append(a[i]); i += 1 }
      else { out.append(b[j]); j += 1 }
    }
    out.append(contentsOf: a[i...])
    out.append(contentsOf: b[j...])
    return out
  }

  static func intersect(_ a: [Int64], _ b: [Int64]) -> [Int64] {
    var out: [Int64] = []
    var i = 0
    var j = 0
    while i < a.count, j < b.count {
      if a[i] == b[j] { out.append(a[i]); i += 1; j += 1 }
      else if a[i] < b[j] { i += 1 }
      else { j += 1 }
    }
    return out
  }

  static func difference(_ a: [Int64], _ b: [Int64]) -> [Int64] {
    var out: [Int64] = []
    var i = 0
    var j = 0
    while i < a.count {
      if j >= b.count || a[i] < b[j] { out.append(a[i]); i += 1 }
      else if a[i] == b[j] { i += 1; j += 1 }
      else { j += 1 }
    }
    return out
  }
}
