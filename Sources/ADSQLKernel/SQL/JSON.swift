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

    // MARK: - Builders

    /// JSON literal text for a SQL scalar used as a `json_array`/`json_object` element or
    /// a `json_set` value: a TEXT value becomes a JSON *string* (quoted), numbers and
    /// NULL pass through, and BLOB is rejected.
    ///
    /// Note: SQLite uses a per-value "JSON subtype" so that the result of a nested
    /// `json()`/`json_array()`/… is embedded as JSON rather than quoted. ADSQL's `Value`
    /// carries no subtype, so a TEXT argument is always treated as a JSON string.
    private static func jsonLiteral(_ value: Value) throws(DBError) -> String {
        switch value {
        case .null: return "null"
        case .integer(let v): return String(v)
        case .real(let d): return SQLFunctions.realToText(d)
        case .text(let s): return renderString(s)
        case .blob: throw DBError.sqlRuntime("JSON cannot hold BLOB values")
        }
    }

    /// `json(X)`: validate and minify JSON text. NULL → NULL.
    static func minify(_ value: Value) throws(DBError) -> Value {
        if value.isNull { return .null }
        return .text(render(try parse(SQLFunctions.textify(value))))
    }

    /// `json_array(v1, v2, …)`.
    static func array(_ values: [Value]) throws(DBError) -> Value {
        var out = "["
        for (index, value) in values.enumerated() {
            if index > 0 { out += "," }
            out += try jsonLiteral(value)
        }
        return .text(out + "]")
    }

    /// `json_object(k1, v1, k2, v2, …)`: labels must be TEXT.
    static func object(_ pairs: [(key: Value, value: Value)]) throws(DBError) -> Value {
        var out = "{"
        for (index, pair) in pairs.enumerated() {
            if index > 0 { out += "," }
            guard case .text(let key) = pair.key else {
                throw DBError.sqlRuntime("json_object() labels must be TEXT")
            }
            out += renderString(key) + ":" + (try jsonLiteral(pair.value))
        }
        return .text(out + "}")
    }

    // MARK: - Mutations

    /// A SQLite-typed, mutable JSON tree. Distinct from ADJSON's `JSONValue` because it
    /// preserves the integer/real distinction (so `json_set(x, '$.n', 1)` writes `1`, not
    /// `1.0`) and keeps object members in document order.
    private indirect enum Tree {
        case null
        case bool(Bool)
        case integer(Int64)
        case real(Double)
        case string(String)
        case array([Tree])
        case object([(String, Tree)])
    }

    enum MutationMode { case set, insert, replace }

    private static func materialize(_ json: JSON) -> Tree {
        if json.isNull { return .null }
        if let b = json.bool { return .bool(b) }
        if let i = json.int { return .integer(Int64(i)) }
        if let d = json.double { return .real(d) }
        if let s = json.string { return .string(s) }
        if json.isArray {
            var items: [Tree] = []
            items.reserveCapacity(json.count)
            json.forEachElement { items.append(materialize($0)) }
            return .array(items)
        }
        var members: [(String, Tree)] = []
        members.reserveCapacity(json.count)
        json.forEachMember { key, value in members.append((key, materialize(value))) }
        return .object(members)
    }

    private static func serialize(_ node: Tree) -> String {
        switch node {
        case .null: return "null"
        case .bool(let b): return b ? "true" : "false"
        case .integer(let v): return String(v)
        case .real(let d): return SQLFunctions.realToText(d)
        case .string(let s): return renderString(s)
        case .array(let items): return "[" + items.map(serialize).joined(separator: ",") + "]"
        case .object(let members):
            return "{" + members.map { renderString($0.0) + ":" + serialize($0.1) }.joined(separator: ",") + "}"
        }
    }

    private static func leafValue(_ value: Value) throws(DBError) -> Tree {
        switch value {
        case .null: return .null
        case .integer(let v): return .integer(v)
        case .real(let d): return .real(d)
        case .text(let s): return .string(s)
        case .blob: throw DBError.sqlRuntime("JSON cannot hold BLOB values")
        }
    }

    /// Apply one path assignment. Like SQLite, `set`/`insert` create missing intermediate
    /// containers (their type inferred from the next segment: object for a key, array for
    /// an index), while `replace` never creates. Descending into a wrong-typed existing
    /// value is a no-op.
    private static func applyMutation(
        _ node: Tree, _ segments: ArraySlice<SQLiteJSONPath.Segment>, _ value: Tree,
        _ mode: MutationMode
    ) -> Tree {
        guard let segment = segments.first else {
            // Whole-document target ($): set/replace overwrite; insert is a no-op ($ exists).
            return mode == .insert ? node : value
        }
        let rest = segments.dropFirst()
        let isLast = rest.isEmpty
        let creating = mode != .replace
        switch segment {
        case .key(let key):
            guard case .object(var members) = node else { return node }
            if let index = members.firstIndex(where: { $0.0 == key }) {
                if isLast {
                    if mode != .insert { members[index].1 = value }
                } else {
                    members[index].1 = applyMutation(members[index].1, rest, value, mode)
                }
            } else if isLast {
                if creating { members.append((key, value)) }
            } else if creating {
                members.append((key, applyMutation(emptyContainer(for: rest.first!), rest, value, mode)))
            }
            return .object(members)
        case .index(let i):
            guard case .array(var items) = node, i >= 0, i < items.count else { return node }
            if isLast {
                if mode != .insert { items[i] = value }
            } else {
                items[i] = applyMutation(items[i], rest, value, mode)
            }
            return .array(items)
        case .fromEnd(let n):
            guard case .array(var items) = node else { return node }
            let i = items.count - n
            guard i >= 0, i < items.count else { return node }
            if isLast {
                if mode != .insert { items[i] = value }
            } else {
                items[i] = applyMutation(items[i], rest, value, mode)
            }
            return .array(items)
        case .append:
            guard case .array(var items) = node, creating else { return node }
            if isLast {
                items.append(value)
            } else {
                items.append(applyMutation(emptyContainer(for: rest.first!), rest, value, mode))
            }
            return .array(items)
        }
    }

    private static func emptyContainer(for segment: SQLiteJSONPath.Segment) -> Tree {
        switch segment {
        case .key: return .object([])
        case .index, .fromEnd, .append: return .array([])
        }
    }

    private static func removeAt(_ node: Tree, _ segments: ArraySlice<SQLiteJSONPath.Segment>) -> Tree {
        guard let segment = segments.first else { return node }
        let rest = segments.dropFirst()
        let isLast = rest.isEmpty
        switch segment {
        case .key(let key):
            guard case .object(var members) = node,
                let index = members.firstIndex(where: { $0.0 == key })
            else { return node }
            if isLast { members.remove(at: index) } else { members[index].1 = removeAt(members[index].1, rest) }
            return .object(members)
        case .index(let i):
            guard case .array(var items) = node, i >= 0, i < items.count else { return node }
            if isLast { items.remove(at: i) } else { items[i] = removeAt(items[i], rest) }
            return .array(items)
        case .fromEnd(let n):
            guard case .array(var items) = node else { return node }
            let i = items.count - n
            guard i >= 0, i < items.count else { return node }
            if isLast { items.remove(at: i) } else { items[i] = removeAt(items[i], rest) }
            return .array(items)
        case .append:
            return node  // the append slot never holds a value
        }
    }

    /// RFC 7396 JSON Merge Patch (SQLite's `json_patch` semantics).
    private static func mergePatch(_ target: Tree, _ patch: Tree) -> Tree {
        guard case .object(let patchMembers) = patch else { return patch }
        var result: [(String, Tree)]
        if case .object(let existing) = target { result = existing } else { result = [] }
        for (key, patchValue) in patchMembers {
            if case .null = patchValue {
                result.removeAll { $0.0 == key }
            } else if let index = result.firstIndex(where: { $0.0 == key }) {
                result[index].1 = mergePatch(result[index].1, patchValue)
            } else {
                result.append((key, mergePatch(.null, patchValue)))
            }
        }
        return .object(result)
    }

    /// `json_set` / `json_insert` / `json_replace`: apply (path, value) assignments.
    static func mutate(
        _ json: String, _ assignments: [(path: String, value: Value)], mode: MutationMode
    ) throws(DBError) -> Value {
        var tree = materialize(try parse(json))
        for assignment in assignments {
            let segments = try parsePath(assignment.path).segments
            let value = try leafValue(assignment.value)
            tree = applyMutation(tree, segments[...], value, mode)
        }
        return .text(serialize(tree))
    }

    /// `json_remove`: delete each path. Removing the root (`$`) yields SQL NULL.
    static func removePaths(_ json: String, paths: [String]) throws(DBError) -> Value {
        var tree = materialize(try parse(json))
        for path in paths {
            let segments = try parsePath(path).segments
            if segments.isEmpty { return .null }
            tree = removeAt(tree, segments[...])
        }
        return .text(serialize(tree))
    }

    /// `json_patch(target, patch)`: RFC 7396 merge.
    static func patch(_ target: String, with patch: String) throws(DBError) -> Value {
        let merged = mergePatch(materialize(try parse(target)), materialize(try parse(patch)))
        return .text(serialize(merged))
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
