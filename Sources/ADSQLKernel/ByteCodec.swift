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
            let byte = unsafe bytes[offset]
            offset += 1
            result |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
            if shift > 63 { return nil }
        }
        return nil
    }

    /// Safe `[UInt8]` overload (bounds-checked, no `unsafe`) for callers that
    /// decode from arrays — e.g. the FTS postings/stats codecs.
    public static func read(_ bytes: [UInt8], _ offset: inout Int) -> UInt64? {
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
        unsafe UInt16(littleEndian: loadUnaligned(fromByteOffset: offset, as: UInt16.self))
    }
    @inline(__always)
    func loadLE32(_ offset: Int) -> UInt32 {
        unsafe UInt32(littleEndian: loadUnaligned(fromByteOffset: offset, as: UInt32.self))
    }
    @inline(__always)
    func loadLE64(_ offset: Int) -> UInt64 {
        unsafe UInt64(littleEndian: loadUnaligned(fromByteOffset: offset, as: UInt64.self))
    }
    /// Big-endian counterpart, for the order-preserving key codec (the only
    /// BE region of the format). A single byte-swapped load, not a shift loop.
    @inline(__always)
    func loadBE64(_ offset: Int) -> UInt64 {
        unsafe UInt64(bigEndian: loadUnaligned(fromByteOffset: offset, as: UInt64.self))
    }
}

extension UnsafeMutableRawBufferPointer {
    @inline(__always)
    func loadLE16(_ offset: Int) -> UInt16 {
        unsafe UInt16(littleEndian: loadUnaligned(fromByteOffset: offset, as: UInt16.self))
    }
    @inline(__always)
    func loadLE32(_ offset: Int) -> UInt32 {
        unsafe UInt32(littleEndian: loadUnaligned(fromByteOffset: offset, as: UInt32.self))
    }
    @inline(__always)
    func loadLE64(_ offset: Int) -> UInt64 {
        unsafe UInt64(littleEndian: loadUnaligned(fromByteOffset: offset, as: UInt64.self))
    }
    @inline(__always)
    func storeLE16(_ value: UInt16, at offset: Int) {
        unsafe storeBytes(of: value.littleEndian, toByteOffset: offset, as: UInt16.self)
    }
    @inline(__always)
    func storeLE32(_ value: UInt32, at offset: Int) {
        unsafe storeBytes(of: value.littleEndian, toByteOffset: offset, as: UInt32.self)
    }
    @inline(__always)
    func storeLE64(_ value: UInt64, at offset: Int) {
        unsafe storeBytes(of: value.littleEndian, toByteOffset: offset, as: UInt64.self)
    }
}
