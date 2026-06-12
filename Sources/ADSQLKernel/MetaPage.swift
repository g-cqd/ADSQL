import Darwin

/// The database meta state, persisted in the two ping-pong meta pages
/// (page 0 and page 1). Commit N+1 writes to page `(N+1) % 2`; recovery
/// takes the newest checksum-valid meta, so one torn meta page is expected
/// and harmless.
public struct Meta: Equatable, Sendable {
  public var generation: UInt64
  /// Root of the main B+tree; 0 means the tree is empty.
  public var rootPage: UInt64
  /// Root of the free-list B+tree; 0 means no free-list.
  public var freeRootPage: UInt64
  /// High-water page count: pages `[0, pageCount)` are owned by the file.
  public var pageCount: UInt64
  public var kvCount: UInt64
  public var treeDepth: UInt16
  public var flags: UInt16

  public static let empty = Meta(
    generation: 0, rootPage: 0, freeRootPage: 0,
    pageCount: Format.firstDataPage, kvCount: 0, treeDepth: 0, flags: 0)

  /// Which meta page the *next* commit (this meta's generation) writes to.
  @inline(__always)
  public var pageNo: UInt64 { generation % 2 }

  enum Offset {
    static let magic = 0
    static let formatVersion = 8
    static let pageSize = 12
    static let generation = 16
    static let rootPage = 24
    static let freeRootPage = 32
    static let pageCount = 40
    static let kvCount = 48
    static let treeDepth = 56
    static let flags = 58
    static let reservedEnd = 120
    static let checksum = 120
  }

  /// Serializes into a full page buffer (only the first 128 bytes are
  /// meaningful; the rest stays as-is, normally zero).
  public func encode(into buffer: UnsafeMutableRawBufferPointer, pageNo: UInt64) {
    precondition(buffer.count == Format.pageSize)
    Format.magicBytes.withUnsafeBytes { magic in
      UnsafeMutableRawBufferPointer(rebasing: buffer[Offset.magic..<Offset.formatVersion])
        .copyMemory(from: magic)
    }
    buffer.storeLE32(Format.formatVersion, at: Offset.formatVersion)
    buffer.storeLE32(UInt32(Format.pageSize), at: Offset.pageSize)
    buffer.storeLE64(generation, at: Offset.generation)
    buffer.storeLE64(rootPage, at: Offset.rootPage)
    buffer.storeLE64(freeRootPage, at: Offset.freeRootPage)
    buffer.storeLE64(pageCount, at: Offset.pageCount)
    buffer.storeLE64(kvCount, at: Offset.kvCount)
    buffer.storeLE16(treeDepth, at: Offset.treeDepth)
    buffer.storeLE16(flags, at: Offset.flags)
    for i in (Offset.flags + 2)..<Offset.reservedEnd { buffer[i] = 0 }
    let digest = XXH64.hash(
      UnsafeRawBufferPointer(rebasing: buffer[0..<Offset.checksum]), seed: pageNo)
    buffer.storeLE64(digest, at: Offset.checksum)
  }

  /// Strict decode: magic, format version, page size, and checksum must all
  /// hold. Returns nil for "not a valid meta" (torn/empty); throws only for
  /// structurally impossible databases (wrong magic on page 0 is reported by
  /// the caller as `badMagic` / `unsupportedFormatVersion`).
  public static func decode(
    from buffer: UnsafeRawBufferPointer, pageNo: UInt64
  ) -> DecodeResult {
    precondition(buffer.count >= Format.metaHeaderSize)
    let magicOK = Format.magicBytes.withUnsafeBytes { magic in
      memcmp(buffer.baseAddress!, magic.baseAddress!, 8) == 0
    }
    guard magicOK else { return .notAMeta }
    let version = buffer.loadLE32(Offset.formatVersion)
    guard version == Format.formatVersion else { return .unsupportedVersion(version) }
    let pageSize = buffer.loadLE32(Offset.pageSize)
    guard pageSize == UInt32(Format.pageSize) else { return .unsupportedPageSize(pageSize) }
    let stored = buffer.loadLE64(Offset.checksum)
    let computed = XXH64.hash(
      UnsafeRawBufferPointer(rebasing: buffer[0..<Offset.checksum]), seed: pageNo)
    guard stored == computed else { return .corrupt }
    return .valid(
      Meta(
        generation: buffer.loadLE64(Offset.generation),
        rootPage: buffer.loadLE64(Offset.rootPage),
        freeRootPage: buffer.loadLE64(Offset.freeRootPage),
        pageCount: buffer.loadLE64(Offset.pageCount),
        kvCount: buffer.loadLE64(Offset.kvCount),
        treeDepth: buffer.loadLE16(Offset.treeDepth),
        flags: buffer.loadLE16(Offset.flags)))
  }

  public enum DecodeResult: Equatable, Sendable {
    case valid(Meta)
    case notAMeta
    case corrupt
    case unsupportedVersion(UInt32)
    case unsupportedPageSize(UInt32)
  }

  /// Recovery: pick the newest valid meta of the two. A single torn meta is
  /// normal (it was the in-flight commit); both invalid is fatal.
  public static func recover(
    meta0: UnsafeRawBufferPointer, meta1: UnsafeRawBufferPointer
  ) throws(DBError) -> Meta {
    let results = [decode(from: meta0, pageNo: 0), decode(from: meta1, pageNo: 1)]
    // Structural rejections take priority: opening a different format or an
    // incompatible version should say so, not "corrupt".
    for result in results {
      if case .unsupportedVersion(let v) = result { throw DBError.unsupportedFormatVersion(v) }
      if case .unsupportedPageSize(let s) = result { throw DBError.unsupportedPageSize(s) }
    }
    var best: Meta?
    for result in results {
      if case .valid(let meta) = result {
        if best == nil || meta.generation > best!.generation { best = meta }
      }
    }
    if let best { return best }
    if results.allSatisfy({ $0 == .notAMeta }) { throw DBError.badMagic }
    throw DBError.bothMetasInvalid
  }
}
