import Darwin
import Testing
import ADSQLTestSupport
@testable import ADSQLKernel

@Suite("FileChannel")
struct FileChannelTests {
  @Test func readWriteRoundTrip() throws {
    let dir = TempDir()
    defer { dir.cleanup() }
    let ch = try FileChannel(path: dir.file("rw.bin"), mode: .readWrite(create: true))
    defer { ch.close() }

    let payload = [UInt8]((0..<1000).map { UInt8(truncatingIfNeeded: $0) })
    try ch.pwrite(payload, at: 4096)
    #expect(try ch.fileSize() == 5096)
    #expect(try ch.preadBytes(count: 1000, at: 4096) == payload)
  }

  @Test func vectoredWriteIsContiguous() throws {
    let dir = TempDir()
    defer { dir.cleanup() }
    let ch = try FileChannel(path: dir.file("vec.bin"), mode: .readWrite(create: true))
    defer { ch.close() }

    let a = [UInt8](repeating: 0xAA, count: 300)
    let b = [UInt8](repeating: 0xBB, count: 500)
    let c = [UInt8](repeating: 0xCC, count: 200)
    try pwritevCopied(ch, [a, b, c], at: 100)
    #expect(try ch.preadBytes(count: 1000, at: 100) == a + b + c)
  }

  @Test func syncProfilesSucceedOnAPFS() throws {
    let dir = TempDir()
    defer { dir.cleanup() }
    let ch = try FileChannel(path: dir.file("sync.bin"), mode: .readWrite(create: true))
    defer { ch.close() }
    try ch.pwrite([UInt8](repeating: 1, count: 64), at: 0)
    try ch.sync(.barrier)
    try ch.sync(.full)
    try ch.sync(.none)
  }

  @Test func preallocateExtends() throws {
    let dir = TempDir()
    defer { dir.cleanup() }
    let ch = try FileChannel(path: dir.file("prealloc.bin"), mode: .readWrite(create: true))
    defer { ch.close() }
    try ch.preallocate(minimumSize: 32 * 1024 * 1024)
    #expect(try ch.fileSize() == 32 * 1024 * 1024)
    // Shrinking request is a no-op.
    try ch.preallocate(minimumSize: 1024)
    #expect(try ch.fileSize() == 32 * 1024 * 1024)
  }

  @Test func closeOnExecIsSet() throws {
    let dir = TempDir()
    defer { dir.cleanup() }
    let ch = try FileChannel(path: dir.file("cloexec.bin"), mode: .readWrite(create: true))
    defer { ch.close() }
    let flags = fcntl(ch.fileDescriptor, F_GETFD)
    #expect(flags & FD_CLOEXEC != 0)
  }

  @Test func shortReadPastEOFThrows() throws {
    let dir = TempDir()
    defer { dir.cleanup() }
    let ch = try FileChannel(path: dir.file("eof.bin"), mode: .readWrite(create: true))
    defer { ch.close() }
    #expect(throws: DBError.self) {
      _ = try ch.preadBytes(count: 16, at: 1 << 20)
    }
  }
}

@Suite("MMap")
struct MMapTests {
  /// The architecture-critical assumption: reserve a mapping far larger than
  /// the file, grow the file afterwards with pwrite/ftruncate, and observe
  /// the new bytes through the existing mapping without remapping.
  @Test func reserveBeyondEOFAndGrow() throws {
    let dir = TempDir()
    defer { dir.cleanup() }
    let ch = try FileChannel(path: dir.file("grow.adsql"), mode: .readWrite(create: true))
    defer { ch.close() }

    // Start with one 16 KiB page.
    try ch.pwrite([UInt8](repeating: 0x11, count: Format.pageSize), at: 0)

    // Reserve 1 GiB of address space over a 16 KiB file.
    let map = try MMap(fileDescriptor: ch.fileDescriptor, capacity: 1 << 30)
    #expect(map.pageBytes(0)[0] == 0x11)
    #expect(map.pageBytes(0)[Format.pageSize - 1] == 0x11)

    // Grow the file by five pages and verify visibility through the old map.
    try ch.preallocate(minimumSize: 6 * Format.pageSize)
    try ch.pwrite([UInt8](repeating: 0x55, count: Format.pageSize), at: 5 * Format.pageSize)
    let page5 = map.pageBytes(5)
    #expect(page5[0] == 0x55)
    #expect(page5[Format.pageSize - 1] == 0x55)
  }

  @Test func writeThenReadIsCoherentWithoutMsync() throws {
    let dir = TempDir()
    defer { dir.cleanup() }
    let ch = try FileChannel(path: dir.file("coherent.adsql"), mode: .readWrite(create: true))
    defer { ch.close() }
    try ch.preallocate(minimumSize: Format.pageSize)
    let map = try MMap(fileDescriptor: ch.fileDescriptor, capacity: 1 << 24)

    for round in UInt8(0)..<8 {
      try ch.pwrite([UInt8](repeating: round, count: Format.pageSize), at: 0)
      // Unified buffer cache: pwrite must be immediately visible via mmap.
      #expect(map.pageBytes(0)[100] == round)
    }
  }
}

@Suite("SimulatedDisk")
struct SimulatedDiskTests {
  @Test func writesPassThrough() throws {
    let dir = TempDir()
    defer { dir.cleanup() }
    let disk = try SimulatedDisk(path: dir.file("sim.bin"))
    defer { disk.close() }
    let bytes = [UInt8](repeating: 0x7F, count: 128)
    try disk.pwrite(bytes, at: 256)
    #expect(try disk.preadBytes(count: 128, at: 256) == bytes)
  }

  @Test func crashDropsGroupsAfterCut() throws {
    let dir = TempDir()
    defer { dir.cleanup() }
    let disk = try SimulatedDisk(path: dir.file("cut.bin"))
    defer { disk.close() }

    try disk.pwrite([0xA1], at: 0) // group 0
    try disk.sync(.barrier)
    try disk.pwrite([0xB2], at: 1) // group 1
    try disk.sync(.barrier)
    try disk.pwrite([0xC3], at: 2) // group 2 — lost when cut at group 1

    // Cut exactly at group 1: group 0 fully present, group 1 torn, group 2 gone.
    var sawKept = false
    var sawDropped = false
    for seed: UInt64 in 0..<32 {
      let image = disk.materializeCrashImage(cutGroup: 1, tearSeed: seed)
      #expect(image.count >= 1 && image[0] == 0xA1)
      if image.count > 2 { #expect(image[2] != 0xC3) }
      if image.count > 1 && image[1] == 0xB2 { sawKept = true } else { sawDropped = true }
    }
    // Tearing must exercise both outcomes for the cut group across seeds.
    #expect(sawKept && sawDropped)
  }

  @Test func fullSyncPinsDurableFloor() throws {
    let dir = TempDir()
    defer { dir.cleanup() }
    let disk = try SimulatedDisk(path: dir.file("floor.bin"))
    defer { disk.close() }
    try disk.pwrite([UInt8](repeating: 9, count: 8), at: 0)
    try disk.sync(.full)
    #expect(disk.crashCutGroups.lowerBound == 1)
    for seed: UInt64 in 0..<16 {
      let image = disk.materializeCrashImage(seed: seed)
      #expect(image.count >= 8)
      #expect(image[0] == 9)
    }
  }

  @Test func tearingIs4KGranular() throws {
    let dir = TempDir()
    defer { dir.cleanup() }
    let disk = try SimulatedDisk(path: dir.file("tear.bin"))
    defer { disk.close() }
    // One 16 KiB write in the cut group → kept sub-blocks must be uniform.
    let page = (0..<Format.pageSize).map { UInt8(truncatingIfNeeded: $0 / Format.subBlockSize + 1) }
    try disk.pwrite(page, at: 0)
    var outcomes = Set<UInt8>()
    for seed: UInt64 in 0..<64 {
      let image = disk.materializeCrashImage(cutGroup: 0, tearSeed: seed)
      for block in 0..<4 {
        let start = block * Format.subBlockSize
        guard image.count >= start + Format.subBlockSize else {
          outcomes.insert(0)
          continue
        }
        let slice = image[start..<(start + Format.subBlockSize)]
        let uniform = Set(slice)
        #expect(uniform.count == 1, "sub-block \(block) must be all-kept or all-dropped")
        outcomes.formUnion(uniform)
      }
    }
    // Across seeds we must see kept blocks (1...4) and dropped blocks (0).
    #expect(outcomes.contains(0))
    #expect(outcomes.isSuperset(of: [1, 2, 3, 4]))
  }
}
