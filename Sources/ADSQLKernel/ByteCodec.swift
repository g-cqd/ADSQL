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
