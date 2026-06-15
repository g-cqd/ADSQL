import ADJSONCore

/// SQLite-compatible JSON support, backed by ADJSON. ADJSON parses text → an immutable
/// tape (lazy, non-materializing) and `SQLiteJSONPath` walks it with SQLite path
/// semantics; this layer maps tape nodes to SQL `Value`s and renders containers using
/// SQLite's number formatting (so `json_extract` on an object/array round-trips, and
/// integers stay integers rather than becoming `Double`s).
enum SQLJSON {
    // MARK: - Parsing

    /// Parse JSON text to the lazy root node. The returned `JSON` retains its backing
    /// `JSONDocument`, so it keeps the parse alive for navigation. Malformed input is a
    /// runtime error (matching SQLite, which rejects ill-formed JSON in `json_extract`).
    static func parse(_ text: String) throws(DBError) -> JSON {
        do {
            return try ADJSON.parse(text).root
        } catch {
            throw DBError.sqlRuntime("malformed JSON")
        }
    }

    private static func parsePath(_ path: String) throws(DBError) -> SQLiteJSONPath {
        do {
            return try SQLiteJSONPath(path)
        } catch {
            throw DBError.sqlRuntime("bad JSON path: \(path)")
        }
    }

    // MARK: - SQL mappings

    /// SQLite `json_extract` value mapping for a single lazy node: JSON null (and a
    /// missing node) → SQL NULL, booleans → 0/1, numbers → INTEGER/REAL, strings → the
    /// raw text (unquoted), and objects/arrays → their minified JSON text.
    static func toSQL(_ json: JSON) -> Value {
        if !json.exists || json.isNull { return .null }
        if let b = json.bool { return .integer(b ? 1 : 0) }
        if let i = json.int { return .integer(Int64(i)) }
        if let d = json.double { return .real(d) }
        if let s = json.string { return .text(s) }
        return .text(render(json))  // object or array
    }

    /// Minified JSON text with SQLite's number formatting. Used for container results of
    /// `json_extract`, for the elements of a multi-path extract, and by `json_quote`.
    static func render(_ json: JSON) -> String {
        if !json.exists || json.isNull { return "null" }
        if let b = json.bool { return b ? "true" : "false" }
        if let i = json.int { return String(i) }
        if let d = json.double { return SQLFunctions.realToText(d) }
        if let s = json.string { return renderString(s) }
        if json.isArray {
            var out = "["
            var first = true
            json.forEachElement { element in
                if !first { out += "," }
                first = false
                out += render(element)
            }
            return out + "]"
        }
        var out = "{"
        var first = true
        json.forEachMember { key, value in
            if !first { out += "," }
            first = false
            out += renderString(key) + ":" + render(value)
        }
        return out + "}"
    }

    private static func renderString(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += "\\u" + hex4(scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }

    private static func hex4(_ value: UInt32) -> String {
        let hex = String(value, radix: 16)
        return String(repeating: "0", count: max(0, 4 - hex.count)) + hex
    }

    /// SQLite type name for a node: null / true / false / integer / real / text /
    /// array / object.
    static func typeName(_ json: JSON) -> String {
        if json.isNull { return "null" }
        if let b = json.bool { return b ? "true" : "false" }
        if json.int != nil { return "integer" }
        if json.double != nil { return "real" }
        if json.string != nil { return "text" }
        if json.isArray { return "array" }
        return "object"
    }

    // MARK: - Scalar functions

    /// `json_extract(doc, path)`: single-path form. Returns SQL NULL for a path that
    /// doesn't resolve; a malformed PATH is an error.
    static func extract(_ json: String, path: String) throws(DBError) -> Value {
        let root = try parse(json)
        return toSQL(try parsePath(path).evaluate(root))
    }

    /// `json_extract(doc, p1, p2, …)` with two or more paths: a JSON array of the
    /// extracted values, each rendered as JSON (a path that doesn't resolve → `null`).
    static func extractMultiple(_ json: String, paths: [String]) throws(DBError) -> Value {
        let root = try parse(json)
        var out = "["
        for (index, path) in paths.enumerated() {
            if index > 0 { out += "," }
            let node = try parsePath(path).evaluate(root)
            out += node.exists ? render(node) : "null"
        }
        return .text(out + "]")
    }

    /// `json_type(doc[, path])`: NULL when the path doesn't resolve.
    static func type(_ json: String, path: String?) throws(DBError) -> Value {
        let root = try parse(json)
        let node: JSON
        if let path {
            node = try parsePath(path).evaluate(root)
        } else {
            node = root
        }
        guard node.exists else { return .null }
        return .text(typeName(node))
    }

    /// `json_array_length(doc[, path])`: element count (0 for non-arrays); NULL when the
    /// path doesn't resolve.
    static func arrayLength(_ json: String, path: String?) throws(DBError) -> Value {
        let root = try parse(json)
        let node: JSON
        if let path {
            node = try parsePath(path).evaluate(root)
        } else {
            node = root
        }
        guard node.exists else { return .null }
        return .integer(Int64(node.isArray ? node.count : 0))
    }

    /// `json_valid(x)`: 1 if `x` is well-formed JSON text, else 0; NULL → NULL.
    static func valid(_ value: Value) -> Value {
        switch value {
        case .null: return .null
        case .blob(let bytes): return .integer((try? ADJSON.parse(bytes)) != nil ? 1 : 0)
        case .text(let s): return .integer((try? ADJSON.parse(s)) != nil ? 1 : 0)
        case .integer, .real:
            return .integer((try? ADJSON.parse(SQLFunctions.textify(value))) != nil ? 1 : 0)
        }
    }

    /// `json_quote(value)`: the JSON text for a SQL scalar.
    static func quote(_ value: Value) throws(DBError) -> Value {
        switch value {
        case .null: return .text("null")
        case .integer(let v): return .text(String(v))
        case .real(let d): return .text(SQLFunctions.realToText(d))
        case .text(let s): return .text(renderString(s))
        case .blob: throw DBError.sqlRuntime("JSON cannot hold BLOB values")
        }
    }

    // MARK: - Table-valued helpers

    /// `json_each` over an array (or single value): the `value` column rowset, in
    /// document order.
    static func eachValues(_ json: String) throws(DBError) -> [Value] {
        let root = try parse(json)
        if root.isArray {
            var out: [Value] = []
            out.reserveCapacity(root.count)
            root.forEachElement { out.append(toSQL($0)) }
            return out
        }
        if root.isObject {
            var out: [Value] = []
            out.reserveCapacity(root.count)
            root.forEachMember { _, value in out.append(toSQL(value)) }
            return out
        }
        return [toSQL(root)]
    }
}
