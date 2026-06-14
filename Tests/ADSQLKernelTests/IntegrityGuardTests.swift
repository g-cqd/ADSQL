import ADSQLTestSupport
import Darwin
import Testing

@testable import ADSQLKernel

/// Read-path integrity guards (health-check R1/R2): the committed-page reader
/// rejects an out-of-range page pointer, and — opt-in — verifies checksums as
/// pages are faulted in.
@Suite("Integrity read guards")
struct IntegrityGuardTests {
    /// R2: a page number ≥ the snapshot's committed high-water is a corrupt
    /// in-page pointer. It must be rejected rather than reading mapped-but-
    /// uncommitted (zeroed) space, which would not fault.
    @Test func resolverRejectsOutOfRangePage() throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        let db = try Database.open(at: dir.file("guard.adsql"))
        defer { db.close() }
        try db.writeSync { (txn) throws(DBError) in
            try txn.put(Array("k".utf8), Array("v".utf8))
        }

        let bounded = CommittedResolver(source: db.pager, pageCount: 3)
        #expect(throws: DBError.corruptPage(pageNo: 3)) {
            _ = try bounded.resolvePage(3)
        }
        #expect(throws: DBError.corruptPage(pageNo: 99)) {
            _ = try bounded.resolvePage(99)
        }
        // An in-range committed page still resolves to a full page.
        #expect(try bounded.resolvePage(2).count == Format.pageSize)
    }

    /// R1: with `verifyChecksumsOnRead`, a byte flipped in a committed page's
    /// checksummed body is caught on the read that faults it in. The flip lands
    /// in the page's (zeroed) free space, so the lax reader returns the correct
    /// value — proving the corruption is otherwise silent and that verification
    /// is what catches it.
    @Test func verifyChecksumsOnReadCatchesFlippedByte() throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        let path = dir.file("corrupt.adsql")
        do {
            let db = try Database.open(at: path)
            try db.writeSync { (txn) throws(DBError) in
                try txn.put(Array("alpha".utf8), Array("payload".utf8))
            }
            db.close()
        }

        // Flip a byte in page 2's checksummed body (offset ≥ 8), inside free space.
        let fd = path.withCString { open($0, O_RDWR) }
        precondition(fd >= 0, "open failed: errno \(errno)")
        let offset = off_t(2 * Format.pageSize + 100)
        var byte: UInt8 = 0
        precondition(pread(fd, &byte, 1, offset) == 1)
        byte ^= 0xFF
        precondition(pwrite(fd, &byte, 1, offset) == 1)
        close(fd)

        // Control: without verification the read does not throw and is correct.
        let lax = try Database.open(at: path)
        let value = try lax.read { (txn) throws(DBError) in try txn.get(Array("alpha".utf8)) }
        #expect(value == Array("payload".utf8))
        lax.close()

        // With verification the read that touches the corrupt page throws.
        let strict = try Database.open(
            at: path, options: DatabaseOptions(verifyChecksumsOnRead: true))
        defer { strict.close() }
        #expect(throws: DBError.self) {
            _ = try strict.read { (txn) throws(DBError) in try txn.get(Array("alpha".utf8)) }
        }
    }
}
