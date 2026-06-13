/// A single owned, page-aligned 16 KiB buffer. Dirty pages live in these
/// (keyed by page number in the write transaction's dirty table); ownership
/// is unique so the backing memory is freed exactly once.
@safe public final class PageBuf {
  // The naked mutable buffer is now `internal` (was `public`): the page
  // mutators (`Node.*`/`PageHeader.*`) live in this module, and external code
  // only needs the read-only view below, so the writable pointer no longer
  // leaves the package (Review 0001 F4). SAFETY: the buffer outlives every
  // borrowed view of it — PageBuf owns it for its whole lifetime and frees it
  // exactly once in `deinit`. Vending it as a `MutableRawSpan` via a
  // `withMutableBytes` scope (compiler-checked borrow) is deferred: it would
  // touch the ~60 in-module `.raw` mutator call sites.
  let raw: UnsafeMutableRawBufferPointer
  /// Which batch request last gained mutable access (group-commit nesting).
  var requestEpoch: UInt32 = 0

  public init(zeroed: Bool = true) {
    let ptr = UnsafeMutableRawPointer.allocate(
      byteCount: Format.pageSize, alignment: Format.pageSize)
    unsafe self.raw = unsafe UnsafeMutableRawBufferPointer(start: ptr, count: Format.pageSize)
    if zeroed {
      unsafe raw.initializeMemory(as: UInt8.self, repeating: 0)
    }
  }

  public convenience init(copying source: UnsafeRawBufferPointer) {
    precondition(source.count == Format.pageSize)
    self.init(zeroed: false)
    unsafe raw.copyMemory(from: source)
  }

  deinit {
    unsafe raw.deallocate()
  }

  @inline(__always)
  public var readOnly: UnsafeRawBufferPointer { unsafe UnsafeRawBufferPointer(raw) }
}
