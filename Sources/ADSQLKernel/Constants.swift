/// On-disk format v0 constants. The format is little-endian throughout.
///
/// File layout: pages 0 and 1 are the ping-pong meta pages; every other page
/// is a typed node (branch, leaf, overflow, freelist). Committed pages are
/// immutable: a write transaction only ever writes to pages that no committed
/// meta references, so torn writes cannot corrupt committed state.
public enum Format {
  /// "ADSQLv0\0"
  public static let magicBytes: [UInt8] = Array("ADSQLv0".utf8) + [0]
  public static let lockMagicBytes: [UInt8] = Array("ADSQLLCK".utf8)

  /// v1 (M5/F0): adds the catalog FTS record kind (`0x66`) and its three owned
  /// B+trees — gates older readers that would silently ignore FTS tables.
  public static let formatVersion: UInt32 = 1
  public static let pageSize: Int = 16384
  /// Tearing granularity assumed by the crash model (APFS/NVMe sector writes).
  public static let subBlockSize: Int = 4096

  public static let metaPageCount: UInt64 = 2
  public static let metaHeaderSize: Int = 128
  public static let nodeHeaderSize: Int = 32
  public static let slotSize: Int = 2

  /// Keys are raw bytes, compared lexicographically (memcmp order).
  public static let maxKeySize: Int = 1024
  /// A cell whose encoded size exceeds this spills its value to overflow pages.
  /// Chosen so a leaf always holds at least 4 cells:
  /// 4 × (4064 + 2-byte slot) = 16264 ≤ 16352 usable bytes.
  public static let maxInlineCellSize: Int = 4064

  public static let usablePageSize: Int = pageSize - nodeHeaderSize
  public static let overflowCapacity: Int = pageSize - nodeHeaderSize

  /// First allocatable data page.
  public static let firstDataPage: UInt64 = 2

  /// Main-tree keys beginning with this byte belong to the relational
  /// catalog; the public KV API rejects them.
  public static let reservedKeyPrefix: UInt8 = 0x00

  /// Reader table (lock file) layout.
  public static let lockHeaderSize: Int = 128
  public static let readerSlotSize: Int = 128
  public static let readerSlotCount: Int = 126
  public static let lockFileSize: Int = lockHeaderSize + readerSlotCount * readerSlotSize // 16256 ≤ 16 KiB
}

public enum PageType: UInt8, Sendable {
  case branch = 1
  case leaf = 2
  case overflow = 3
  case freelist = 4
}

/// How committed data reaches stable storage.
public enum DurabilityProfile: Sendable, Equatable {
  /// `F_BARRIERFSYNC` around the meta flip: commits are always
  /// crash-consistent; a power loss may drop the last few commits. Default.
  case barrier
  /// `F_FULLFSYNC`: power-loss durable, significantly slower.
  case full
  /// No syncing. Benchmarks and throwaway data only.
  case none
}
