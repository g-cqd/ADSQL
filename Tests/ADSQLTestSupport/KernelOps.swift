import ADSQLKernel

/// Byte-array bridges over the kernel's raw-buffer APIs, shared by suites.
/// (Closures stay untyped or non-throwing to dodge the Swift 6.4 typed-throws
/// reabstraction crash; errors travel via Result.)
public enum KernelOps {
  public static func put(_ ctx: TxnContext, _ key: [UInt8], _ value: [UInt8]) throws {
    var failure: DBError?
    key.withUnsafeBytes { k in
      value.withUnsafeBytes { v in
        do throws(DBError) { try BTree.put(ctx: ctx, key: k, value: v) } catch { failure = error }
      }
    }
    if let failure { throw failure }
  }

  @discardableResult
  public static func delete(_ ctx: TxnContext, _ key: [UInt8]) throws -> Bool {
    var result: Result<Bool, DBError> = .success(false)
    key.withUnsafeBytes { k in
      do throws(DBError) { result = .success(try BTree.delete(ctx: ctx, key: k)) } catch {
        result = .failure(error)
      }
    }
    return try result.get()
  }

  public static func get(
    _ resolver: some PageResolver, _ meta: Meta, _ key: [UInt8]
  ) throws -> [UInt8]? {
    var result: Result<[UInt8]?, DBError> = .success(nil)
    key.withUnsafeBytes { k in
      do throws(DBError) {
        guard let ref = try BTree.get(resolver: resolver, meta: meta, key: k) else {
          result = .success(nil)
          return
        }
        result = .success(try BTree.copyValue(ref, resolver: resolver))
      } catch {
        result = .failure(error)
      }
    }
    return try result.get()
  }

  public static func scanAll(
    _ resolver: some PageResolver, _ meta: Meta
  ) throws -> [(key: [UInt8], value: [UInt8])] {
    var out: [(key: [UInt8], value: [UInt8])] = []
    try BTree.forEach(resolver: resolver, meta: meta) { (key, ref) throws(DBError) in
      out.append((key: [UInt8](key), value: try BTree.copyValue(ref, resolver: resolver)))
    }
    return out
  }

  /// Applies an op to both the transaction and the model.
  public static func apply(_ op: DBOp, ctx: TxnContext, model: inout ModelStore) throws {
    switch op {
    case .put(let key, let value):
      try put(ctx, key, value)
      model.put(key, value)
    case .delete(let key):
      try delete(ctx, key)
      model.delete(key)
    }
  }
}
