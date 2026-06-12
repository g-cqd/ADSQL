/// LEB128 variable-length integers, shared by the free-list and the
/// relational record codec.
public enum Varint {
  public static func append(_ value: UInt64, to bytes: inout [UInt8]) {
    var v = value
    while v >= 0x80 {
      bytes.append(UInt8(v & 0x7F) | 0x80)
      v >>= 7
    }
    bytes.append(UInt8(v))
  }

  /// Returns nil on truncation or overflow past 64 bits.
  public static func read(_ bytes: UnsafeRawBufferPointer, _ offset: inout Int) -> UInt64? {
    var result: UInt64 = 0
    var shift: UInt64 = 0
    while offset < bytes.count {
      let byte = bytes[offset]
      offset += 1
      result |= UInt64(byte & 0x7F) << shift
      if byte & 0x80 == 0 { return result }
      shift += 7
      if shift > 63 { return nil }
    }
    return nil
  }

  @inline(__always)
  public static func zigzag(_ value: Int64) -> UInt64 {
    UInt64(bitPattern: (value << 1) ^ (value >> 63))
  }

  @inline(__always)
  public static func unzigzag(_ value: UInt64) -> Int64 {
    Int64(bitPattern: (value >> 1)) ^ -Int64(bitPattern: value & 1)
  }
}

/// Little-endian load/store primitives. The on-disk format is LE everywhere;
/// loads/stores are unaligned-safe.
extension UnsafeRawBufferPointer {
  @inline(__always)
  func loadLE16(_ offset: Int) -> UInt16 {
    UInt16(littleEndian: loadUnaligned(fromByteOffset: offset, as: UInt16.self))
  }
  @inline(__always)
  func loadLE32(_ offset: Int) -> UInt32 {
    UInt32(littleEndian: loadUnaligned(fromByteOffset: offset, as: UInt32.self))
  }
  @inline(__always)
  func loadLE64(_ offset: Int) -> UInt64 {
    UInt64(littleEndian: loadUnaligned(fromByteOffset: offset, as: UInt64.self))
  }
}

extension UnsafeMutableRawBufferPointer {
  @inline(__always)
  func loadLE16(_ offset: Int) -> UInt16 {
    UInt16(littleEndian: loadUnaligned(fromByteOffset: offset, as: UInt16.self))
  }
  @inline(__always)
  func loadLE32(_ offset: Int) -> UInt32 {
    UInt32(littleEndian: loadUnaligned(fromByteOffset: offset, as: UInt32.self))
  }
  @inline(__always)
  func loadLE64(_ offset: Int) -> UInt64 {
    UInt64(littleEndian: loadUnaligned(fromByteOffset: offset, as: UInt64.self))
  }
  @inline(__always)
  func storeLE16(_ value: UInt16, at offset: Int) {
    storeBytes(of: value.littleEndian, toByteOffset: offset, as: UInt16.self)
  }
  @inline(__always)
  func storeLE32(_ value: UInt32, at offset: Int) {
    storeBytes(of: value.littleEndian, toByteOffset: offset, as: UInt32.self)
  }
  @inline(__always)
  func storeLE64(_ value: UInt64, at offset: Int) {
    storeBytes(of: value.littleEndian, toByteOffset: offset, as: UInt64.self)
  }
}
