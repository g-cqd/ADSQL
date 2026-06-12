import Darwin

public struct IntegrityReport: Sendable {
  public var generation: UInt64
  public var pageCount: UInt64
  public var kvCount: UInt64
  public var treeDepth: UInt16
  public var mainTreePages: Int
  public var freeTreePages: Int
  public var overflowPages: Int
  public var freeListedPages: Int
}

/// Whole-file verification: both trees structurally valid with checksums,
/// and the page-liveness invariant — {metas} ∪ main pages ∪ free-tree pages
/// ∪ free-listed pages == [0, pageCount), pairwise disjoint. Any deviation
/// (corruption, leak, double-use) throws.
public enum Integrity {
  public static func check(
    resolver: some PageResolver, meta: Meta, verifyChecksums: Bool = true
  ) throws(DBError) -> IntegrityReport {
    let main = try BTree.validate(
      resolver: resolver, tree: meta.mainTree, verifyChecksums: verifyChecksums)
    let free = try BTree.validate(
      resolver: resolver, tree: meta.freeTree, verifyChecksums: verifyChecksums)

    var seen = Set<UInt64>([0, 1])
    func claim(_ page: UInt64, _ what: @autoclosure () -> String) throws(DBError) {
      guard page >= Format.firstDataPage, page < meta.pageCount else {
        throw DBError.integrityFailure("\(what()): page \(page) out of bounds")
      }
      guard seen.insert(page).inserted else {
        throw DBError.integrityFailure("\(what()): page \(page) claimed twice")
      }
    }
    for page in main.reachablePages { try claim(page, "main tree") }
    for page in free.reachablePages { try claim(page, "free tree") }
    var freeListed = 0
    for entry in try FreeList.allListedPages(resolver: resolver, tree: meta.freeTree) {
      try claim(entry.page, "free entry gen \(entry.gen)")
      freeListed += 1
    }
    guard seen.count == Int(meta.pageCount) else {
      let missing = (0..<meta.pageCount).filter { !seen.contains($0) }
      throw DBError.integrityFailure(
        "leaked pages: \(Array(missing.prefix(20))) (\(missing.count) of \(meta.pageCount))")
    }

    return IntegrityReport(
      generation: meta.generation,
      pageCount: meta.pageCount,
      kvCount: meta.kvCount,
      treeDepth: meta.treeDepth,
      mainTreePages: main.reachablePages.count,
      freeTreePages: free.reachablePages.count,
      overflowPages: main.overflowPages,
      freeListedPages: freeListed)
  }
}

extension Database {
  /// Verifies the newest committed generation end to end (checksums,
  /// structure, page liveness). Runs as a reader: the writer is unaffected.
  public func verifyIntegrity() throws(DBError) -> IntegrityReport {
    let meta = try beginRead()
    defer { endRead(generation: meta.generation) }
    return try Integrity.check(resolver: CommittedResolver(source: pager), meta: meta)
  }

  /// O(1) atomic snapshot via APFS clonefile(2). Quiesces the writer for
  /// the (instant) duration of the clone, so the snapshot is exactly the
  /// newest committed generation.
  public func snapshot(to destination: String) throws(DBError) {
    var result: Result<Void, DBError> = .success(())
    writeQueue.sync {
      let status = path.withCString { src in
        destination.withCString { dst in
          clonefile(src, dst, 0)
        }
      }
      if status != 0 {
        result = .failure(
          errno == EEXIST
            ? DBError.snapshotDestinationExists
            : DBError.io(errno: errno, op: "clonefile(\(destination))"))
      }
    }
    try result.get()
  }
}
