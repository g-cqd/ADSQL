/// Overflow chains hold values whose leaf cell would exceed
/// `Format.maxInlineCellSize`. Each overflow page stores up to
/// `Format.overflowCapacity` payload bytes; the header link field points to
/// the next page in the chain (0 terminates).
public protocol OverflowPager {
    mutating func allocateOverflowPage() throws(DBError) -> (pageNo: UInt64, buffer: UnsafeMutableRawBufferPointer)
    func readOverflowPage(_ pageNo: UInt64) throws(DBError) -> UnsafeRawBufferPointer
    mutating func freeOverflowPage(_ pageNo: UInt64) throws(DBError)
}

public enum Overflow {
    public static func pageCount(forLength length: Int) -> Int {
        (length + Format.overflowCapacity - 1) / Format.overflowCapacity
    }

    /// Writes `value` into a fresh chain; returns the head page number.
    public static func write<P: OverflowPager>(
        _ value: UnsafeRawBufferPointer, pager: inout P
    ) throws(DBError) -> UInt64 {
        unsafe precondition(!value.isEmpty)
        let pages = pageCount(forLength: value.count)
        var allocated: [(pageNo: UInt64, buffer: UnsafeMutableRawBufferPointer)] = unsafe []
        unsafe allocated.reserveCapacity(pages)
        for _ in 0..<pages {
            unsafe allocated.append(try pager.allocateOverflowPage())
        }
        var remaining = unsafe value
        for unsafe (i, slot) in unsafe allocated.enumerated() {
            let take = min(remaining.count, Format.overflowCapacity)
            unsafe PageHeader.initialize(slot.buffer, type: .overflow)
            unsafe PageHeader.setCellCount(slot.buffer, take)  // dataLen
            unsafe PageHeader.setLink(slot.buffer, i + 1 < pages ? allocated[i + 1].pageNo : 0)
            unsafe Node.copyBytes(
                into: slot.buffer, at: Format.nodeHeaderSize,
                from: UnsafeRawBufferPointer(rebasing: remaining[remaining.startIndex..<remaining.startIndex + take]))
            unsafe remaining = unsafe UnsafeRawBufferPointer(rebasing: remaining[(remaining.startIndex + take)...])
        }
        return unsafe allocated[0].pageNo
    }

    /// Reads a whole chain back (copying); `length` comes from the leaf cell.
    public static func read<P: OverflowPager>(
        head: UInt64, length: Int, pager: P
    ) throws(DBError) -> [UInt8] {
        var out = [UInt8]()
        out.reserveCapacity(length)
        var pageNo = head
        var remaining = length
        while pageNo != 0, remaining > 0 {
            let page = unsafe try pager.readOverflowPage(pageNo)
            guard unsafe PageHeader.pageType(page) == .overflow else {
                throw DBError.corruptPage(pageNo: pageNo)
            }
            let dataLen = unsafe PageHeader.overflowDataLen(page)
            guard dataLen <= Format.overflowCapacity, dataLen <= remaining else {
                throw DBError.corruptPage(pageNo: pageNo)
            }
            unsafe out.append(
                contentsOf: page[Format.nodeHeaderSize..<Format.nodeHeaderSize + dataLen])
            remaining -= dataLen
            pageNo = unsafe PageHeader.link(page)
        }
        guard remaining == 0 else {
            throw DBError.corruptPage(pageNo: head)
        }
        return out
    }

    /// Visits each chain page's payload without concatenating.
    public static func withChunks<P: OverflowPager>(
        head: UInt64, length: Int, pager: P,
        _ body: (UnsafeRawBufferPointer) -> Void
    ) throws(DBError) {
        var pageNo = head
        var remaining = length
        while pageNo != 0, remaining > 0 {
            let page = unsafe try pager.readOverflowPage(pageNo)
            guard unsafe PageHeader.pageType(page) == .overflow else {
                throw DBError.corruptPage(pageNo: pageNo)
            }
            let dataLen = unsafe PageHeader.overflowDataLen(page)
            guard dataLen <= Format.overflowCapacity, dataLen <= remaining else {
                throw DBError.corruptPage(pageNo: pageNo)
            }
            unsafe body(
                UnsafeRawBufferPointer(
                    rebasing: page[Format.nodeHeaderSize..<Format.nodeHeaderSize + dataLen]))
            remaining -= dataLen
            pageNo = unsafe PageHeader.link(page)
        }
        guard remaining == 0 else {
            throw DBError.corruptPage(pageNo: head)
        }
    }

    /// Frees every page of a chain (reading each page's link before freeing).
    public static func free<P: OverflowPager>(
        head: UInt64, pager: inout P
    ) throws(DBError) {
        var pageNo = head
        while pageNo != 0 {
            let next = unsafe PageHeader.link(try pager.readOverflowPage(pageNo))
            try pager.freeOverflowPage(pageNo)
            pageNo = next
        }
    }
}
