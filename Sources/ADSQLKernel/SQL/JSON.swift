import ADJSONCore

/// SQLite-compatible JSON support, backed by ADJSON. ADJSON owns every SQLite-dialect
/// detail: it parses text → an immutable lazy tape, `SQLiteJSONPath` walks it with SQLite
/// path semantics, `JSONValue` is the mutable tree (preserving the integer/real distinction
/// and document order), `JSONValue.setting`/`removing` are the `json_set`/`insert`/`replace`/
/// `remove` mutation engine, `SQLiteJSON` provides `extract`/`type`/`array_length`/`valid`/
/// `patch`, and `encodedBytes(options: .sqlite)` renders bytes byte-for-byte with `sqlite3`
/// (`%!.15g` reals, `\b`/`\f` short escapes, unescaped slashes, minified, declaration order).
/// This layer only maps between SQL `Value`s and JSON and wires the `json_*` functions.
enum SQLJSON {
    // MARK: - Parsing

    /// Parse JSON text to the lazy root node. The returned `JSON` retains its backing
    /// document, so it keeps the parse alive for navigation. Malformed input is a runtime
    /// error (matching SQLite, which rejects ill-formed JSON in `json_extract`).
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

    // MARK: - Encoding boundary (ADJSON is the sole SQLite-dialect serializer)

    /// SQLite-byte JSON text for a value, via ADJSON's `.sqlite` encoder. Non-throwing: the
    /// encoder only rejects non-finite numbers, which never reach here (parsed JSON can't hold
    /// them and `leaf` maps a non-finite real to `null`), so the `"null"` fallback is just
    /// belt-and-suspenders — mirroring `SQLiteJSON.quote`.
    static func encode(_ value: JSONValue) -> String {
        guard let bytes = try? value.encodedBytes(options: .sqlite) else { return "null" }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// A SQL scalar as a JSON leaf. ADSQL's `Value` carries no "JSON subtype", so a TEXT value
    /// is always a JSON *string* (quoted), not embedded JSON. A non-finite REAL becomes JSON
    /// `null` (JSON can't represent ±Infinity/NaN, and a `Double` that overflowed has already
    /// lost the digits SQLite's bignum printf would have kept). BLOB has no JSON form.
    private static func leaf(_ value: Value) throws(DBError) -> JSONValue {
        switch value {
        case .null: return .null
        case .integer(let v): return .int(v)
        case .real(let d): return d.isFinite ? .number(d) : .null
        case .text(let s): return .string(s)
        case .blob: throw DBError.sqlRuntime("JSON cannot hold BLOB values")
        }
    }

    // MARK: - SQL mappings

    /// SQLite `json_extract` value mapping for a single lazy node: JSON null (and a missing
    /// node) → SQL NULL, booleans → 0/1, numbers → INTEGER/REAL, strings → the raw text
    /// (unquoted), and objects/arrays → their minified JSON text.
    static func toSQL(_ json: JSON) -> Value {
        if !json.exists || json.isNull { return .null }
        if let b = json.bool { return .integer(b ? 1 : 0) }
        if let i = json.int { return .integer(Int64(i)) }
        if let d = json.double { return .real(d) }
        if let s = json.string { return .text(s) }
        return .text(encode(JSONValue(json)))  // object or array
    }

    // MARK: - Scalar functions

    /// `json_extract(doc, path)`: single-path form. Returns SQL NULL for a path that doesn't
    /// resolve; a malformed PATH is an error.
    static func extract(_ json: String, path: String) throws(DBError) -> Value {
        let root = try parse(json)
        return toSQL(try parsePath(path).evaluate(root))
    }

    /// `json_extract(doc, p1, p2, …)` with two or more paths: a JSON array of the extracted
    /// values, each rendered as JSON (a path that doesn't resolve → `null`).
    static func extractMultiple(_ json: String, paths: [String]) throws(DBError) -> Value {
        let root = try parse(json)
        var parsed: [SQLiteJSONPath] = []
        parsed.reserveCapacity(paths.count)
        for path in paths { parsed.append(try parsePath(path)) }
        return .text(encode(SQLiteJSON.extract(root, parsed)))
    }

    /// `json_type(doc[, path])`: NULL when the path doesn't resolve.
    static func type(_ json: String, path: String?) throws(DBError) -> Value {
        let root = try parse(json)
        let node: JSON
        if let path { node = try parsePath(path).evaluate(root) } else { node = root }
        guard let name = SQLiteJSON.type(node) else { return .null }
        return .text(name)
    }

    /// `json_array_length(doc[, path])`: element count (0 for non-arrays); NULL when the path
    /// doesn't resolve.
    static func arrayLength(_ json: String, path: String?) throws(DBError) -> Value {
        let root = try parse(json)
        let node: JSON
        if let path { node = try parsePath(path).evaluate(root) } else { node = root }
        guard node.exists else { return .null }
        return .integer(Int64(SQLiteJSON.arrayLength(node)))
    }

    /// `json_valid(x)`: 1 if `x` is well-formed JSON text, else 0; NULL → NULL.
    static func valid(_ value: Value) -> Value {
        switch value {
        case .null: return .null
        case .blob(let bytes): return .integer(SQLiteJSON.valid(bytes) ? 1 : 0)
        case .text(let s): return .integer(SQLiteJSON.valid(s) ? 1 : 0)
        case .integer, .real:
            return .integer(SQLiteJSON.valid(SQLFunctions.textify(value)) ? 1 : 0)
        }
    }

    /// `json_quote(value)`: the JSON text for a SQL scalar.
    static func quote(_ value: Value) throws(DBError) -> Value {
        .text(encode(try leaf(value)))
    }

    /// The `->` (`asJSON: true`) and `->>` (`asJSON: false`) operators. The right operand
    /// selects a path: an INTEGER `N` → `$[N]`, TEXT beginning with `$` → that path, any other
    /// value → the object label `$."<text>"`. `->` returns the result rendered as JSON text;
    /// `->>` returns it as a SQL scalar. A NULL operand yields NULL.
    static func arrow(_ document: Value, _ spec: Value, asJSON: Bool) throws(DBError) -> Value {
        if document.isNull || spec.isNull { return .null }
        let path: String
        switch spec {
        case .integer(let n): path = "$[\(n)]"
        case .text(let s) where s.hasPrefix("$"): path = s
        case .text(let s): path = "$." + encode(.string(s))
        default: path = "$." + encode(.string(SQLFunctions.textify(spec)))
        }
        let node = try parsePath(path).evaluate(try parse(SQLFunctions.textify(document)))
        if asJSON { return node.exists ? .text(encode(JSONValue(node))) : .null }
        return toSQL(node)
    }

    // MARK: - Builders

    /// JSON literal text for a SQL scalar used as a `json_array`/`json_object` element or a
    /// `json_set` value: a TEXT value becomes a JSON *string* (quoted), numbers and NULL pass
    /// through, and BLOB is rejected.
    private static func jsonLiteral(_ value: Value) throws(DBError) -> String {
        encode(try leaf(value))
    }

    /// JSON text for a SQL value used as an aggregate element (a json_group_array element or a
    /// json_group_object value).
    static func encodeValue(_ value: Value) throws(DBError) -> String { try jsonLiteral(value) }

    /// JSON object-key text for json_group_object labels.
    static func encodeKey(_ key: String) -> String { encode(.string(key)) }

    /// `json(X)`: validate and minify JSON text. NULL → NULL.
    static func minify(_ value: Value) throws(DBError) -> Value {
        if value.isNull { return .null }
        return .text(encode(JSONValue(try parse(SQLFunctions.textify(value)))))
    }

    /// `json_array(v1, v2, …)`.
    static func array(_ values: [Value]) throws(DBError) -> Value {
        var elements: [JSONValue] = []
        elements.reserveCapacity(values.count)
        for value in values { elements.append(try leaf(value)) }
        return .text(encode(.array(elements)))
    }

    /// `json_object(k1, v1, k2, v2, …)`: labels must be TEXT. Built as text rather than through
    /// a dictionary because SQLite keeps duplicate keys (`json_object('a',1,'a',2)` →
    /// `{"a":1,"a":2}`), which an order-collapsing map would lose.
    static func object(_ pairs: [(key: Value, value: Value)]) throws(DBError) -> Value {
        var out = "{"
        for (index, pair) in pairs.enumerated() {
            if index > 0 { out += "," }
            guard case .text(let key) = pair.key else {
                throw DBError.sqlRuntime("json_object() labels must be TEXT")
            }
            out += encode(.string(key)) + ":" + (try jsonLiteral(pair.value))
        }
        return .text(out + "}")
    }

    // MARK: - Mutations

    enum MutationMode { case set, insert, replace }

    private static func setMode(_ mode: MutationMode) -> JSONValue.SQLiteSetMode {
        switch mode {
        case .set: .set
        case .insert: .insert
        case .replace: .replace
        }
    }

    /// `json_set` / `json_insert` / `json_replace`: apply (path, value) assignments left to
    /// right. ADJSON's `setting` matches SQLite (creates missing intermediates for set/insert,
    /// never for replace; descending into a wrong-typed value is a no-op).
    static func mutate(
        _ json: String, _ assignments: [(path: String, value: Value)], mode: MutationMode
    ) throws(DBError) -> Value {
        var value = JSONValue(try parse(json))
        let mode = setMode(mode)
        for assignment in assignments {
            value = value.setting(try parsePath(assignment.path), to: try leaf(assignment.value), mode: mode)
        }
        return .text(encode(value))
    }

    /// `json_remove`: delete each path, each resolved against the result of the previous
    /// removal. Removing the root (`$`) yields SQL NULL.
    static func removePaths(_ json: String, paths: [String]) throws(DBError) -> Value {
        var value = JSONValue(try parse(json))
        for path in paths {
            guard let result = value.removing(try parsePath(path)) else { return .null }
            value = result
        }
        return .text(encode(value))
    }

    /// `json_patch(target, patch)`: RFC 7396 merge.
    static func patch(_ target: String, with patch: String) throws(DBError) -> Value {
        let merged = SQLiteJSON.patch(JSONValue(try parse(target)), with: JSONValue(try parse(patch)))
        return .text(encode(merged))
    }

    // MARK: - Table-valued helpers

    /// `json_each` over an array (or single value): the `value` column rowset, in document
    /// order.
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
