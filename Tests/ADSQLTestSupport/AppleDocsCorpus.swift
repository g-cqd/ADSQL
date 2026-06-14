/// A deterministic, apple-docs-SHAPED synthetic corpus for the FTS parity gate
/// (M5/F6a) and the later FTS bench (F6b). "Apple-docs-shaped" means the text
/// reads like DocC reference pages — framework names, symbol/type names,
/// declarations, headings, and short prose abstracts — so MATCH queries return
/// non-trivial, varied result sets and bm25 ranking is discriminating.
///
/// Determinism is the whole point: identical `(count, seed)` yields byte-identical
/// rows on every run and every machine, so the same corpus can be built into both
/// ADSQL and a real SQLite FTS5 mirror and compared. The generator owns its RNG
/// (`SplitMix64`) and never touches Foundation `random`, the system clock, or any
/// hashing whose iteration order varies — the word lists are fixed arrays indexed
/// by the seeded stream.
///
/// Shapes covered (one `Document` feeds all four apple-docs FTS tables):
///   - `documents_fts`     ← title, abstract, declaration, headings, key
///   - `documents_trigram` ← title (external content over `documents`)
///   - `documents_body_fts`← body (contentless)
///   - `sf_symbols_fts`    ← name, keywords, categories, aliases
///
/// The row count is parameterized so the parity test uses ~2k (fast + plenty to
/// discriminate ranking) while F6b can scale the *same* generator to ≥100k.
package enum AppleDocsCorpus {
  /// One synthetic documentation row. `id` is the 1-based rowid shared by the
  /// base table and every FTS table (so `d.id == fts.rowid`, the apple-docs join).
  package struct Document: Sendable, Equatable {
    package let id: Int64
    // documents / documents_fts columns
    package let title: String
    package let abstract: String
    package let declaration: String
    package let headings: String
    package let key: String
    // documents_body_fts (contentless) column
    package let body: String
    // sf_symbols_fts columns
    package let name: String
    package let keywords: String
    package let categories: String
    package let aliases: String
  }

  // MARK: - Vocabulary (fixed; indexed by the seeded stream)

  /// Framework / module names — high-frequency anchor terms that appear in
  /// titles and keys, so single-term MATCH (e.g. `swiftui`) hits a meaningful
  /// fraction of the corpus.
  static let frameworks = [
    "SwiftUI", "UIKit", "AppKit", "Foundation", "Combine", "CoreData",
    "Metal", "CoreML", "CloudKit", "AVFoundation", "MapKit", "StoreKit",
    "WidgetKit", "SwiftData", "Observation", "CoreGraphics", "Vision",
    "ARKit", "RealityKit", "CoreLocation",
  ]

  /// Type / symbol name stems combined with a role suffix to form realistic
  /// declarations and titles (e.g. "AsyncImageView", "NavigationController").
  static let typeStems = [
    "Async", "Navigation", "Scroll", "Stack", "Grid", "List", "Text",
    "Image", "Button", "Toggle", "Picker", "Gesture", "Animation",
    "Layout", "Render", "Query", "Model", "Store", "Session", "Stream",
    "Buffer", "Texture", "Pipeline", "Descriptor", "Coordinate",
  ]

  static let typeRoles = [
    "View", "Controller", "Manager", "Provider", "Builder", "Context",
    "Configuration", "Delegate", "Coordinator", "Renderer", "Reader",
    "Writer", "Cache", "Registry", "Resolver",
  ]

  /// Prose vocabulary for abstracts/bodies — verbs and nouns that stem under
  /// porter (e.g. "rendering"→"render", "configures"→"configur") so the porter
  /// tables exercise stemming, and that recur enough for phrase queries.
  static let proseVerbs = [
    "renders", "configures", "manages", "observes", "encodes", "decodes",
    "schedules", "animates", "loads", "caches", "fetches", "presents",
    "computes", "transforms", "synchronizes", "validates", "resolves",
  ]
  static let proseNouns = [
    "view", "value", "model", "context", "buffer", "texture", "request",
    "response", "gesture", "layout", "pipeline", "snapshot", "transaction",
    "subscription", "coordinate", "descriptor", "hierarchy",
  ]
  static let proseAdjectives = [
    "structured", "concurrent", "declarative", "immutable", "lazy", "shared",
    "observable", "asynchronous", "composable", "reusable", "deterministic",
  ]
  static let headingWords = [
    "Overview", "Topics", "Declaration", "Discussion", "Parameters",
    "Return Value", "See Also", "Mentioned in", "Availability", "Conforms To",
  ]

  /// SF Symbols-style names (dotted, lowercase) and their facets, so the
  /// `sf_symbols_fts` shape (prefix index, detail=column, columnsize=0) has its
  /// own vocabulary distinct from the prose tables.
  static let symbolNames = [
    "square.and.arrow.up", "heart.fill", "star.circle", "bell.badge",
    "gearshape.2", "magnifyingglass", "trash.slash", "folder.badge.plus",
    "doc.text", "paperplane.fill", "bookmark.circle", "tag.fill",
    "bolt.horizontal", "cloud.sun", "moon.stars", "flame.fill",
    "drop.triangle", "leaf.arrow.circlepath", "wifi.exclamationmark",
    "antenna.radiowaves.left.and.right",
  ]
  static let symbolKeywords = [
    "share", "export", "upload", "favorite", "like", "rating", "alert",
    "notify", "settings", "search", "find", "delete", "remove", "add",
    "create", "document", "send", "message", "save", "label",
  ]
  static let symbolCategories = [
    "communication", "weather", "objectsandtools", "devices", "connectivity",
    "transportation", "human", "nature", "editing", "media",
  ]

  // MARK: - Generation

  /// Builds `count` deterministic documents from `seed`. Same arguments ⇒ same
  /// rows. `count` rows get ids `1...count` (matching SQLite's implicit rowid).
  package static func generate(count: Int, seed: UInt64) -> [Document] {
    var rng = SplitMix64(seed: seed)
    var docs: [Document] = []
    docs.reserveCapacity(count)
    for index in 0..<count {
      docs.append(makeDocument(id: Int64(index + 1), rng: &rng))
    }
    return docs
  }

  private static func makeDocument(id: Int64, rng: inout SplitMix64) -> Document {
    let framework = pick(frameworks, &rng)
    let typeName = pick(typeStems, &rng) + pick(typeRoles, &rng)
    let secondary = pick(frameworks, &rng)

    // title: e.g. "SwiftUI AsyncImageView" — framework + type, the densest field.
    let title = "\(framework) \(typeName)"

    // abstract: 1–2 short prose sentences with recurring verbs/nouns/adjectives.
    let abstract = sentence(&rng) + " " + sentence(&rng)

    // declaration: a Swift-ish signature, so `func`/`struct`/type tokens appear.
    let declaration = makeDeclaration(typeName: typeName, framework: framework, rng: &rng)

    // headings: 2–3 DocC section names.
    let headingCount = 2 + Int(rng.next() % 2)
    let headings = (0..<headingCount).map { _ in pick(headingWords, &rng) }
      .joined(separator: " ")

    // key: a DocC-style path, lowercased and slashed (distinct token shapes).
    let key = "doc/\(framework.lowercased())/\(typeName.lowercased())/\(id)"

    // body (contentless table): a longer prose blob (3–5 sentences) so doc
    // lengths vary widely — exercises bm25 length normalization.
    let bodyCount = 3 + Int(rng.next() % 3)
    let body = (0..<bodyCount).map { _ in sentence(&rng) }.joined(separator: " ")
      + " " + framework + " " + secondary

    // sf_symbols facets — independent vocabulary.
    let name = pick(symbolNames, &rng)
    let keywordCount = 2 + Int(rng.next() % 3)
    let keywords = (0..<keywordCount).map { _ in pick(symbolKeywords, &rng) }
      .joined(separator: " ")
    let categories = pick(symbolCategories, &rng)
    // aliases: the dotted name with separators replaced, plus a keyword — gives
    // the prefix index something to expand (`squar*`, `hear*`). Pure-Swift map
    // (no Foundation): this module is intentionally Foundation-free.
    let aliases =
      String(name.map { $0 == "." ? " " : $0 }) + " " + pick(symbolKeywords, &rng)

    return Document(
      id: id, title: title, abstract: abstract, declaration: declaration,
      headings: headings, key: key, body: body, name: name, keywords: keywords,
      categories: categories, aliases: aliases)
  }

  /// A short prose sentence: "<adjective> <noun> <verb> the <noun>" (e.g.
  /// "structured view renders the value"). Recurring terms so phrase queries
  /// (e.g. "renders the view", "structured view") can hit and porter stems
  /// repeat across documents.
  private static func sentence(_ rng: inout SplitMix64) -> String {
    "\(pick(proseAdjectives, &rng)) \(pick(proseNouns, &rng)) \(pick(proseVerbs, &rng)) the \(pick(proseNouns, &rng))"
  }

  private static func makeDeclaration(
    typeName: String, framework: String, rng: inout SplitMix64
  ) -> String {
    let kind = ["struct", "final class", "enum", "actor"][Int(rng.next() % 4)]
    let role = pick(typeRoles, &rng)
    return "\(kind) \(typeName) conforms to \(role) in \(framework)"
  }

  private static func pick<T>(_ array: [T], _ rng: inout SplitMix64) -> T {
    array[Int(rng.next() % UInt64(array.count))]
  }
}
