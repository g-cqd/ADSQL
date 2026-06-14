/// Tunable selection of execution strategies. Every option defaults to the
/// engine's established (reference) behavior; alternative strategies are added
/// *beside* the reference path and only become a default once benchmarked to win
/// on accuracy, performance, concurrency, parallelism, reliability, consistency,
/// and integrity (see the maturity program). A `Sendable` value type, snapshot-
/// copied into each execution — it introduces no shared mutable state, so the
/// single-writer / wait-free-reader MVCC model is unaffected.
public struct ExecutionOptions: Sendable, Equatable {
  /// Per-row expression evaluation strategy.
  public enum Evaluator: Sendable, Equatable {
    /// `SQLEval.evaluate` over the bound AST (the reference path).
    case treeWalk
    /// Bind-time-compiled closure tree (slots/affinity/collation resolved once).
    case compiledClosures
    /// Flat opcode register machine.
    case vdbe
  }

  /// Join algorithm. `.auto` lets the planner choose by row counts.
  public enum Join: Sendable, Equatable {
    /// Index-nested-loop (the reference path, incl. the existence fast path).
    case nestedLoop
    case hash
    case merge
    case auto
  }

  /// Insert execution path.
  public enum Insert: Sendable, Equatable {
    /// Per-row `insertCore` (the reference path).
    case standard
    /// Per-statement plan with loop-invariant work hoisted out of the row loop.
    case hoisted
    /// Warm rightmost-leaf append fast path for ascending rowid inserts.
    case appendCursor
  }

  public var evaluator: Evaluator
  public var join: Join
  public var insert: Insert
  /// Build-side memory budget before a hash join falls back to nested loop.
  public var hashJoinMemoryBudgetBytes: Int

  public init(
    evaluator: Evaluator = .treeWalk,
    join: Join = .nestedLoop,
    insert: Insert = .standard,
    hashJoinMemoryBudgetBytes: Int = 256 << 20
  ) {
    self.evaluator = evaluator
    self.join = join
    self.insert = insert
    self.hashJoinMemoryBudgetBytes = hashJoinMemoryBudgetBytes
  }

  public static let `default` = ExecutionOptions()

  /// Identifies the options that affect the *bound plan* (the join strategy), so
  /// a plan bound under one strategy is never reused under another. The evaluator
  /// and insert strategies are runtime-only and never change a plan.
  var planningTag: Int {
    switch join {
    case .nestedLoop: 0
    case .hash: 1
    case .merge: 2
    case .auto: 3
    }
  }
}
