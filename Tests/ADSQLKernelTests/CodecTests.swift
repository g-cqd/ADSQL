import Testing

@testable import ADSQLKernel

@Suite("Meta codec")
struct MetaCodecTests {
    func makeMeta(generation: UInt64) -> Meta {
        Meta(
            generation: generation, rootPage: 7, freeRootPage: 9,
            pageCount: 42, kvCount: 12345, treeDepth: 3, flags: 0,
            freeDepth: 2, freeEntryCount: 6)
    }

    @Test func roundTrip() {
        let buf = PageBuf()
        let meta = makeMeta(generation: 11)
        meta.encode(into: buf.raw, pageNo: 1)
        #expect(Meta.decode(from: buf.readOnly, pageNo: 1) == .valid(meta))
    }

    @Test func checksumIsSeededByPageNo() {
        let buf = PageBuf()
        makeMeta(generation: 4).encode(into: buf.raw, pageNo: 0)
        // Same bytes presented as the other meta page must fail validation.
        #expect(Meta.decode(from: buf.readOnly, pageNo: 1) == .corrupt)
    }

    @Test func flippedBitIsCorrupt() {
        let buf = PageBuf()
        makeMeta(generation: 4).encode(into: buf.raw, pageNo: 0)
        buf.raw[33] ^= 0x40
        #expect(Meta.decode(from: buf.readOnly, pageNo: 0) == .corrupt)
    }

    @Test func zeroPageIsNotAMeta() {
        let buf = PageBuf()
        #expect(Meta.decode(from: buf.readOnly, pageNo: 0) == .notAMeta)
    }

    @Test func wrongVersionIsStructural() {
        let buf = PageBuf()
        makeMeta(generation: 1).encode(into: buf.raw, pageNo: 0)
        buf.raw.storeLE32(99, at: Meta.Offset.formatVersion)
        #expect(Meta.decode(from: buf.readOnly, pageNo: 0) == .unsupportedVersion(99))
    }

    @Test func recoveryPicksNewestValid() throws {
        let m0 = PageBuf()
        let m1 = PageBuf()
        makeMeta(generation: 10).encode(into: m0.raw, pageNo: 0)
        makeMeta(generation: 11).encode(into: m1.raw, pageNo: 1)
        #expect(try Meta.recover(meta0: m0.readOnly, meta1: m1.readOnly).generation == 11)

        // Torn newest meta → fall back to the older valid one.
        m1.raw[60] ^= 0xFF
        #expect(try Meta.recover(meta0: m0.readOnly, meta1: m1.readOnly).generation == 10)
    }

    @Test func recoveryFailsWhenBothInvalid() {
        let m0 = PageBuf()
        let m1 = PageBuf()
        makeMeta(generation: 1).encode(into: m0.raw, pageNo: 0)
        makeMeta(generation: 2).encode(into: m1.raw, pageNo: 1)
        m0.raw[16] ^= 1
        m1.raw[16] ^= 1
        #expect(throws: DBError.bothMetasInvalid) {
            try Meta.recover(meta0: m0.readOnly, meta1: m1.readOnly)
        }
    }

    @Test func recoveryOnForeignFileIsBadMagic() {
        let m0 = PageBuf()
        let m1 = PageBuf()
        #expect(throws: DBError.badMagic) {
            try Meta.recover(meta0: m0.readOnly, meta1: m1.readOnly)
        }
    }

    @Test func unsupportedVersionBeatsCorrupt() {
        let m0 = PageBuf()
        let m1 = PageBuf()
        makeMeta(generation: 1).encode(into: m0.raw, pageNo: 0)
        m0.raw.storeLE32(7, at: Meta.Offset.formatVersion)
        #expect(throws: DBError.unsupportedFormatVersion(7)) {
            try Meta.recover(meta0: m0.readOnly, meta1: m1.readOnly)
        }
    }
}

@Suite("Page header")
struct PageHeaderTests {
    @Test func initializeAndRoundTrip() {
        let buf = PageBuf(zeroed: false)
        PageHeader.initialize(buf.raw, type: .leaf)
        #expect(PageHeader.pageType(buf.readOnly) == .leaf)
        #expect(PageHeader.cellCount(buf.readOnly) == 0)
        #expect(PageHeader.cellAreaStart(buf.readOnly) == Format.pageSize)
        #expect(PageHeader.fragmentedBytes(buf.readOnly) == 0)
        #expect(PageHeader.link(buf.readOnly) == 0)
        #expect(PageHeader.freeSpace(buf.readOnly) == Format.pageSize - Format.nodeHeaderSize)

        PageHeader.setCellCount(buf.raw, 3)
        PageHeader.setCellAreaStart(buf.raw, 16000)
        PageHeader.setFragmentedBytes(buf.raw, 17)
        PageHeader.setLink(buf.raw, 0xDEAD)
        PageHeader.setSlotOffset(buf.raw, 0, 16100)
        PageHeader.setSlotOffset(buf.raw, 1, 16050)
        PageHeader.setSlotOffset(buf.raw, 2, 16000)

        #expect(PageHeader.cellCount(buf.readOnly) == 3)
        #expect(PageHeader.cellAreaStart(buf.readOnly) == 16000)
        #expect(PageHeader.fragmentedBytes(buf.readOnly) == 17)
        #expect(PageHeader.link(buf.readOnly) == 0xDEAD)
        #expect(PageHeader.slotOffset(buf.readOnly, 0) == 16100)
        #expect(PageHeader.slotOffset(buf.readOnly, 1) == 16050)
        #expect(PageHeader.slotOffset(buf.readOnly, 2) == 16000)
        #expect(PageHeader.freeSpace(buf.readOnly) == 16000 - Format.nodeHeaderSize - 6)
    }

    @Test func unknownPageTypeIsNil() {
        let buf = PageBuf()
        buf.raw[PageHeader.Offset.pageType] = 200
        #expect(PageHeader.pageType(buf.readOnly) == nil)
    }

    @Test func checksumStampAndVerify() {
        let buf = PageBuf(zeroed: false)
        PageHeader.initialize(buf.raw, type: .branch)
        PageHeader.setLink(buf.raw, 5)
        PageHeader.stampChecksum(buf.raw, pageNo: 77)
        #expect(PageHeader.verifyChecksum(buf.readOnly, pageNo: 77))
        // Wrong location → fail (seeded by page number).
        #expect(!PageHeader.verifyChecksum(buf.readOnly, pageNo: 78))
        // Any body bit flip → fail.
        buf.raw[9000] ^= 0x02
        #expect(!PageHeader.verifyChecksum(buf.readOnly, pageNo: 77))
    }

    @Test func unalignedStoresWork() {
        let buf = PageBuf()
        buf.raw.storeLE64(0x0102_0304_0506_0708, at: 13)
        #expect(buf.readOnly.loadLE64(13) == 0x0102_0304_0506_0708)
        #expect(buf.readOnly[13] == 0x08)  // little-endian byte order on disk
        buf.raw.storeLE32(0xAABB_CCDD, at: 1)
        #expect(buf.readOnly.loadLE32(1) == 0xAABB_CCDD)
        buf.raw.storeLE16(0xBEEF, at: 3)  // overlaps the 32-bit store above
        #expect(buf.readOnly.loadLE16(3) == 0xBEEF)
    }
}
