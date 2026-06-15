/// Aggregate functions: COUNT(*), COUNT(expr), SUM(expr), and the JSON aggregates
/// json_group_array(value) / json_group_object(name, value). AVG/MIN/MAX/TOTAL/
/// GROUP_CONCAT and COUNT(DISTINCT) are rejected at bind with named `sqlUnsupported`
/// errors.
struct AggregateSpec: Sendable, Equatable {
    enum Kind: Sendable, Equatable {
        case countStar
        case count(SQLExpr)
        case sum(SQLExpr)
        case jsonGroupArray(SQLExpr)
        case jsonGroupObject(name: SQLExpr, value: SQLExpr)
    }
    let kind: Kind
}

/// One group's running aggregate state, indexed by aggregate slot.
final class GroupAccumulators {
    private let specs: [AggregateSpec]
    private var count: [Int]
    private var sumNonNull: [Bool]
    private var sumIsReal: [Bool]
    private var sumInt: [Int64]
    private var sumReal: [Double]
    /// Rendered JSON fragments per slot for json_group_array/json_group_object, in row order.
    private var jsonParts: [[String]]

    init(specs: [AggregateSpec]) {
        self.specs = specs
        self.count = Array(repeating: 0, count: specs.count)
        self.sumNonNull = Array(repeating: false, count: specs.count)
        self.sumIsReal = Array(repeating: false, count: specs.count)
        self.sumInt = Array(repeating: 0, count: specs.count)
        self.sumReal = Array(repeating: 0, count: specs.count)
        self.jsonParts = Array(repeating: [], count: specs.count)
    }

    /// Folds one input row into every aggregate (arguments are evaluated against
    /// the live row via `env`).
    func update(_ env: SQLEvalEnv) throws(DBError) {
        for (slot, spec) in specs.enumerated() {
            switch spec.kind {
            case .countStar:
                count[slot] += 1
            case .count(let expr):
                if !(try SQLEval.evaluate(expr, env)).isNull { count[slot] += 1 }
            case .sum(let expr):
                try addToSum(slot, try SQLEval.evaluate(expr, env))
            case .jsonGroupArray(let expr):
                jsonParts[slot].append(try SQLJSON.encodeValue(try SQLEval.evaluate(expr, env)))
            case .jsonGroupObject(let nameExpr, let valueExpr):
                let label = try SQLEval.evaluate(nameExpr, env)
                guard case .text(let key) = label else {
                    throw DBError.sqlRuntime("json_group_object() labels must be TEXT")
                }
                let value = try SQLEval.evaluate(valueExpr, env)
                jsonParts[slot].append(SQLJSON.encodeKey(key) + ":" + (try SQLJSON.encodeValue(value)))
            }
        }
    }

    func result(_ slot: Int) -> Value {
        switch specs[slot].kind {
        case .countStar, .count:
            return .integer(Int64(count[slot]))
        case .sum:
            guard sumNonNull[slot] else { return .null }  // empty / all-NULL SUM is NULL
            return sumIsReal[slot] ? .real(sumReal[slot]) : .integer(sumInt[slot])
        case .jsonGroupArray:
            return .text("[" + jsonParts[slot].joined(separator: ",") + "]")
        case .jsonGroupObject:
            return .text("{" + jsonParts[slot].joined(separator: ",") + "}")
        }
    }

    private func addToSum(_ slot: Int, _ value: Value) throws(DBError) {
        // SQLite SUM ignores NULLs and applies numeric affinity to other classes.
        let numeric: Value
        switch value {
        case .null: return
        case .integer, .real: numeric = value
        case .text(let s): numeric = SQLFunctions.numericPrefix(s)
        case .blob: numeric = .integer(0)
        }
        sumNonNull[slot] = true
        switch numeric {
        case .integer(let n):
            if sumIsReal[slot] {
                sumReal[slot] += Double(n)
            } else {
                let (total, overflow) = sumInt[slot].addingReportingOverflow(n)
                if overflow { throw DBError.sqlRuntime("integer overflow in SUM()") }
                sumInt[slot] = total
            }
        case .real(let d):
            if !sumIsReal[slot] {
                sumIsReal[slot] = true
                sumReal[slot] = Double(sumInt[slot])
            }
            sumReal[slot] += d
        default:
            break
        }
    }
}
