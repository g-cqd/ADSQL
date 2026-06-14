/// Aggregate functions supported by M4/PR5: COUNT(*), COUNT(expr), SUM(expr).
/// AVG/MIN/MAX/TOTAL/GROUP_CONCAT and COUNT(DISTINCT) are rejected at bind
/// with named `sqlUnsupported` errors.
struct AggregateSpec: Sendable, Equatable {
    enum Kind: Sendable, Equatable {
        case countStar
        case count(SQLExpr)
        case sum(SQLExpr)
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

    init(specs: [AggregateSpec]) {
        self.specs = specs
        self.count = Array(repeating: 0, count: specs.count)
        self.sumNonNull = Array(repeating: false, count: specs.count)
        self.sumIsReal = Array(repeating: false, count: specs.count)
        self.sumInt = Array(repeating: 0, count: specs.count)
        self.sumReal = Array(repeating: 0, count: specs.count)
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
