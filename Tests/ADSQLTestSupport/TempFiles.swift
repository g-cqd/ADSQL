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
            // Read d_name in place via a pointer, never by copying the whole fixed-size
            // field: readdir's dirent occupies only d_reclen bytes, so a by-value read of
            // the entire 1024-byte d_name array over-reads the directory stream's buffer
            // when the record sits at its end (a heap-buffer-overflow ASan flags).
            // String(cString:) stops at the NUL, which is within the record's real bytes.
            let name = withUnsafePointer(to: &entry.pointee.d_name) { ptr in
                String(cString: UnsafeRawPointer(ptr).assumingMemoryBound(to: CChar.self))
            }
            if name == "." || name == ".." { continue }
            _ = unlink(path + "/" + name)
        }
        closedir(dir)
        _ = rmdir(path)
    }
}
