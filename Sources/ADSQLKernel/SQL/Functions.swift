import Darwin

/// Scalar functions and value coercions, matching SQLite's core behavior:
/// ASCII-only LOWER/UPPER, character-based LENGTH/INSTR/SUBSTR (1-based),
/// numeric-prefix text coercion, %.15g-style real formatting with a
/// round-trip precision upgrade, and overflow-promoting arithmetic.
enum SQLFunctions {
    // MARK: - Coercions

    /// SQLite text rendering of a value (for ||, CAST AS TEXT, LIKE).
    static func textify(_ value: Value) -> String {
        switch value {
        case .null: return ""  // callers handle NULL before textify
        case .integer(let v): return String(v)
        case .real(let d): return realToText(d)
        case .text(let s): return s
        case .blob(let b): return String(decoding: b, as: UTF8.self)
        }
    }

    /// SQLite formats reals with %!.15g, upgrading precision until the text
    /// round-trips.
    static func realToText(_ d: Double) -> String {
        if d.isNaN { return "" }  // NaN is NULL upstream
        if d.isInfinite { return d > 0 ? "Inf" : "-Inf" }
        for precision in [15, 17, 20] {
            let text = format(d, precision: precision)
            if Double(text) == d {
                return ensureRealShape(text)
            }
        }
        return ensureRealShape(format(d, precision: 20))
    }

    private static func format(_ d: Double, precision: Int) -> String {
        var buffer = [CChar](repeating: 0, count: 48)
        let result = "%.\(precision)g".withCString { fmt in
            unsafe withVaList([d]) { args in
                buffer.withUnsafeMutableBufferPointer { out in
                    unsafe vsnprintf(out.baseAddress!, out.count, fmt, args)
                }
            }
        }
        precondition(result > 0)
        let written = buffer.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }
        return String(decoding: written, as: UTF8.self)
    }

    /// SQLite always renders reals with a decimal point or exponent.
    private static func ensureRealShape(_ text: String) -> String {
        if text.contains(".") || text.contains("e") || text.contains("E")
            || text.contains("Inf")
        {
            return text
        }
        return text + ".0"
    }

    /// SQLite numeric-prefix coercion of text: leading spaces, sign, digits,
    /// optional fraction/exponent; empty/invalid prefix → integer 0.
    static func numericPrefix(_ s: String) -> Value {
        let bytes = Array(s.utf8)
        var i = 0
        while i < bytes.count, bytes[i] == 0x20 || bytes[i] == 0x09 { i += 1 }
        let start = i
        if i < bytes.count, bytes[i] == 0x2B || bytes[i] == 0x2D { i += 1 }
        var sawDigit = false
        while i < bytes.count, bytes[i] >= 0x30, bytes[i] <= 0x39 {
            sawDigit = true
            i += 1
        }
        var isReal = false
        if i < bytes.count, bytes[i] == 0x2E {
            isReal = true
            i += 1
            while i < bytes.count, bytes[i] >= 0x30, bytes[i] <= 0x39 {
                sawDigit = true
                i += 1
            }
        }
        if sawDigit, i < bytes.count, bytes[i] | 0x20 == 0x65 {
            var j = i + 1
            if j < bytes.count, bytes[j] == 0x2B || bytes[j] == 0x2D { j += 1 }
            if j < bytes.count, bytes[j] >= 0x30, bytes[j] <= 0x39 {
                isReal = true
                i = j
                while i < bytes.count, bytes[i] >= 0x30, bytes[i] <= 0x39 { i += 1 }
            }
        }
        guard sawDigit else { return .integer(0) }
        let text = String(decoding: bytes[start..<i], as: UTF8.self)
        if !isReal, let v = Int64(text) { return .integer(v) }
        return .real(Double(text) ?? 0)
    }

    /// Numeric coercion for arithmetic operands.
    static func toNumeric(_ value: Value) -> Value {
        switch value {
        case .integer, .real, .null: return value
        case .text(let s): return numericPrefix(s)
        case .blob: return .integer(0)
        }
    }

    static func cast(_ value: Value, to type: ColumnType) -> Value {
        if value.isNull { return .null }
        switch type {
        case .integer:
            switch toNumeric(value) {
            case .integer(let v): return .integer(v)
            case .real(let d):
                if d.isNaN { return .integer(0) }
                if d <= -9.223372036854776e18 { return .integer(.min) }
                if d >= 9.223372036854776e18 { return .integer(.max) }
                return .integer(Int64(d))  // truncates toward zero
            default: return .integer(0)
            }
        case .real:
            switch toNumeric(value) {
            case .integer(let v): return .real(Double(v))
            case .real(let d): return .real(d)
            default: return .real(0)
            }
        case .text:
            return .text(textify(value))
        case .blob:
            if case .blob = value { return value }
            return .blob(Array(textify(value).utf8))
        }
    }

    // MARK: - Arithmetic (overflow promotes to REAL; /0 and %0 yield NULL)

    static func negate(_ value: Value) -> Value {
        switch toNumeric(value) {
        case .null: return .null
        case .integer(let v):
            if v == .min { return .real(9.223372036854776e18) }
            return .integer(-v)
        case .real(let d): return .real(-d)
        default: return .null
        }
    }

    static func arithmetic(
        _ op: SQLBinaryOp, _ rawL: Value, _ rawR: Value
    ) throws(DBError) -> Value {
        let l = toNumeric(rawL)
        let r = toNumeric(rawR)
        if l.isNull || r.isNull { return .null }

        if op == .modulo {
            // SQLite %: both operands int-cast; the RESULT is REAL when either
            // input was REAL.
            guard let li = asInt(l), let ri = asInt(r) else { return .null }
            guard ri != 0 else { return .null }
            let remainder = (li == .min && ri == -1) ? 0 : li % ri
            let anyReal = isReal(l) || isReal(r)
            return anyReal ? .real(Double(remainder)) : .integer(remainder)
        }

        if case .integer(let li) = l, case .integer(let ri) = r {
            switch op {
            case .add:
                let (sum, overflow) = li.addingReportingOverflow(ri)
                return overflow ? .real(Double(li) + Double(ri)) : .integer(sum)
            case .subtract:
                let (difference, overflow) = li.subtractingReportingOverflow(ri)
                return overflow ? .real(Double(li) - Double(ri)) : .integer(difference)
            case .multiply:
                let (product, overflow) = li.multipliedReportingOverflow(by: ri)
                return overflow ? .real(Double(li) * Double(ri)) : .integer(product)
            case .divide:
                guard ri != 0 else { return .null }
                if li == .min && ri == -1 { return .real(9.223372036854776e18) }
                return .integer(li / ri)
            default:
                throw DBError.sqlRuntime("unsupported arithmetic operator \(op.rawValue)")
            }
        }

        let ld = asDouble(l)
        let rd = asDouble(r)
        let result: Double
        switch op {
        case .add: result = ld + rd
        case .subtract: result = ld - rd
        case .multiply: result = ld * rd
        case .divide:
            guard rd != 0 else { return .null }
            result = ld / rd
        default:
            throw DBError.sqlRuntime("unsupported arithmetic operator \(op.rawValue)")
        }
        return result.isNaN ? .null : .real(result)
    }

    private static func isReal(_ v: Value) -> Bool {
        if case .real = v { return true }
        return false
    }

    /// Int-cast with SQLite CAST semantics: saturate out-of-range doubles,
    /// NaN → 0.
    private static func asInt(_ v: Value) -> Int64? {
        switch v {
        case .integer(let i): return i
        case .real(let d):
            if d.isNaN { return 0 }
            if d <= -9.223372036854776e18 { return .min }
            if d >= 9.223372036854776e18 { return .max }
            return Int64(d)
        default: return nil
        }
    }

    /// Affinity conversion: text that is a complete well-formed number
    /// becomes numeric (leading/trailing whitespace allowed); otherwise nil.
    static func fullNumeric(_ s: String) -> Value? {
        let bytes = Array(s.utf8)
        var lo = 0
        var hi = bytes.count
        while lo < hi, bytes[lo] == 0x20 || bytes[lo] == 0x09 || bytes[lo] == 0x0A { lo += 1 }
        while hi > lo, bytes[hi - 1] == 0x20 || bytes[hi - 1] == 0x09 || bytes[hi - 1] == 0x0A {
            hi -= 1
        }
        guard hi > lo else { return nil }
        let core = String(decoding: bytes[lo..<hi], as: UTF8.self)
        if let v = Int64(core) { return .integer(v) }
        // Reject hex/inf/nan spellings Double() accepts but SQLite does not.
        for byte in bytes[lo..<hi] {
            switch byte {
            case 0x30...0x39, 0x2B, 0x2D, 0x2E, 0x65, 0x45: continue
            default: return nil
            }
        }
        guard let d = Double(core) else { return nil }
        return .real(d)
    }

    private static func asDouble(_ v: Value) -> Double {
        switch v {
        case .integer(let i): return Double(i)
        case .real(let d): return d
        default: return 0
        }
    }

    // MARK: - LIKE (ASCII-case-insensitive, % and _ over characters)

    static func like(text: String, pattern: String) -> Bool {
        let t = Array(text.unicodeScalars).map(foldScalar)
        let p = Array(pattern.unicodeScalars).map(foldScalar)
        return likeMatch(t[...], p[...])
    }

    private static func foldScalar(_ s: Unicode.Scalar) -> Unicode.Scalar {
        (s.value >= 0x41 && s.value <= 0x5A) ? Unicode.Scalar(s.value + 0x20)! : s
    }

    private static func likeMatch(
        _ text: ArraySlice<Unicode.Scalar>, _ pattern: ArraySlice<Unicode.Scalar>
    ) -> Bool {
        var t = text
        var p = pattern
        while let pc = p.first {
            if pc == "%" {
                p = p.dropFirst()
                while p.first == "%" { p = p.dropFirst() }  // collapse runs
                if p.isEmpty { return true }
                var rest = t
                while true {
                    if likeMatch(rest, p) { return true }
                    if rest.isEmpty { return false }
                    rest = rest.dropFirst()
                }
            }
            guard let tc = t.first else { return false }
            if pc == "_" || pc == tc {
                t = t.dropFirst()
                p = p.dropFirst()
            } else {
                return false
            }
        }
        return t.isEmpty
    }

    // MARK: - Scalar function dispatch

    static func call(
        _ name: String, args: [SQLExpr], star: Bool, offset: Int, _ env: SQLEvalEnv
    ) throws(DBError) -> Value {
        func arg(_ i: Int) throws(DBError) -> Value {
            try SQLEval.evaluate(args[i], env)
        }
        func requireArgs(_ counts: ClosedRange<Int>) throws(DBError) {
            guard !star, counts.contains(args.count) else {
                throw DBError.sqlBind("\(name)() takes \(counts) arguments")
            }
        }

        switch name {
        case "COALESCE":
            for expr in args {
                let value = try SQLEval.evaluate(expr, env)
                if !value.isNull { return value }
            }
            return .null
        case "LOWER", "UPPER":
            try requireArgs(1...1)
            let value = try arg(0)
            guard case .text(let s) = value else { return value.isNull ? .null : .text(textify(value)) }
            let folded = String(
                String.UnicodeScalarView(
                    s.unicodeScalars.map { scalar in
                        if name == "LOWER" {
                            return (scalar.value >= 0x41 && scalar.value <= 0x5A)
                                ? Unicode.Scalar(scalar.value + 0x20)! : scalar
                        }
                        return (scalar.value >= 0x61 && scalar.value <= 0x7A)
                            ? Unicode.Scalar(scalar.value - 0x20)! : scalar
                    }))
            return .text(folded)
        case "LENGTH":
            try requireArgs(1...1)
            switch try arg(0) {
            case .null: return .null
            case .text(let s): return .integer(Int64(s.count))
            case .blob(let b): return .integer(Int64(b.count))
            case .integer(let v): return .integer(Int64(String(v).count))
            case .real(let d): return .integer(Int64(realToText(d).count))
            }
        case "INSTR":
            try requireArgs(2...2)
            let haystack = try arg(0)
            let needle = try arg(1)
            guard !haystack.isNull, !needle.isNull else { return .null }
            let h = Array(textify(haystack))
            let n = Array(textify(needle))
            if n.isEmpty { return .integer(0) }
            if n.count <= h.count {
                for start in 0...(h.count - n.count) where Array(h[start..<start + n.count]) == n {
                    return .integer(Int64(start + 1))
                }
            }
            return .integer(0)
        case "SUBSTR", "SUBSTRING":
            try requireArgs(2...3)
            let value = try arg(0)
            guard !value.isNull else { return .null }
            let chars = Array(textify(value))
            guard case .integer(var start) = cast(try arg(1), to: .integer) else { return .null }
            var length = Int64(chars.count)
            if args.count == 3 {
                guard case .integer(let l) = cast(try arg(2), to: .integer) else { return .null }
                length = l
            }
            // SQLite 1-based; negative start counts from the end; negative
            // length takes the |length| characters BEFORE the position.
            if start < 0 {
                start = Int64(chars.count) + start + 1
                if start < 1 {
                    length += start - 1
                    start = 1
                }
            } else if start == 0 {
                if length > 0 { length -= 1 }
                start = 1
            }
            if length < 0 {
                let newStart = start + length
                length = -length
                start = newStart
                if start < 1 {
                    length += start - 1
                    start = 1
                }
            }
            if length < 0 { return .text("") }
            let from = Int(start) - 1
            guard from < chars.count, from >= 0 else { return .text("") }
            let to = min(chars.count, from + Int(length))
            return .text(String(chars[from..<max(from, to)]))
        case "DATETIME":
            try requireArgs(1...1)
            guard case .text("now") = try arg(0) else {
                throw DBError.sqlUnsupported("datetime() arguments other than 'now'")
            }
            return .text(CivilTime.utcNowString())
        case "JSON_EXTRACT":
            try requireArgs(2...2)
            let document = try arg(0)
            let path = try arg(1)
            guard case .text(let json) = document else { return .null }
            guard case .text(let p) = path else {
                throw DBError.sqlRuntime("json_extract path must be TEXT")
            }
            return try SQLJSON.extract(json, path: p)
        case "COUNT", "SUM":
            throw DBError.sqlBind("\(name)() is an aggregate and needs GROUP BY context")
        default:
            throw DBError.sqlUnsupported("\(name)() function")
        }
    }
}
