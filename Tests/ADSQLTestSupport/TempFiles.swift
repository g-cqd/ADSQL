import Darwin

/// Creates a fresh private temp directory and returns paths inside it.
package struct TempDir: Sendable {
  package let path: String

  package init() {
    var template = Array("/tmp/adsql-test.XXXXXX".utf8CString)
    let result = template.withUnsafeMutableBufferPointer { mkdtemp($0.baseAddress!) }
    precondition(result != nil, "mkdtemp failed: errno \(errno)")
    self.path = String(decoding: template.dropLast().map { UInt8(bitPattern: $0) }, as: UTF8.self)
  }

  package func file(_ name: String) -> String { path + "/" + name }

  /// Best-effort recursive removal.
  package func cleanup() {
    guard let dir = opendir(path) else { return }
    while let entry = readdir(dir) {
      let name = withUnsafeBytes(of: entry.pointee.d_name) { raw in
        String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
      }
      if name == "." || name == ".." { continue }
      _ = unlink(path + "/" + name)
    }
    closedir(dir)
    _ = rmdir(path)
  }
}
