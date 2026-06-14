import ADSQL

/// Multi-criteria strategy matrix (RFC 0009 H1). For each (join × evaluator)
/// strategy combination, run the `sql` scenario for ADSQL and print its latency
/// lines under a labeled header; the SQLite arm runs once as the external
/// baseline. This is the **performance** axis of the seven criteria; the other
/// six (accuracy, concurrency, parallelism, reliability, consistency, integrity)
/// are enforced by the differential/crash/integrity test suites
/// (`SQLStrategyMatrixTests`, `SQLHashJoinTests`, `CommitRecoveryTests`,
/// `Integrity.deepCheck`) — not by this latency harness.
///
/// Only strategies that are actually implemented are listed; `merge`/`auto`
/// (join) and `vdbe` (eval) are added here as they land (today they fall back),
/// so the matrix grows with the program and never silently measures a fallback
/// as if it were the real strategy.
enum StrategyBench {
  /// Implemented join strategies to sweep (extend with `.merge`/`.auto` in H4).
  static let joins: [(label: String, value: ExecutionOptions.Join)] = [
    ("nestedLoop", .nestedLoop),
    ("hash", .hash),
  ]
  /// Implemented evaluator strategies to sweep (extend with `.vdbe` in H6).
  static let evaluators: [(label: String, value: ExecutionOptions.Evaluator)] = [
    ("treeWalk", .treeWalk),
    ("compiled", .compiledClosures),
  ]

  static func run(engines: [String], dir: String, config: BenchConfig) throws {
    print(
      "strategy matrix — join×eval over the sql scenario "
        + "(rows=\(config.rows), point-gets=\(config.pointGets)); "
        + "accuracy/integrity/etc. gated by the test suites")

    if engines.contains("sqlite") {
      print("\n-- sqlite (external baseline) --")
      try SQLScenario.run("sqlite", dir: dir, config: config)
    }
    guard engines.contains("adsql") else { return }

    for join in joins {
      for evaluator in evaluators {
        var combo = config
        combo.joinStrategy = join.value
        combo.evaluator = evaluator.value
        print("\n-- adsql [join=\(join.label) eval=\(evaluator.label)] --")
        try SQLScenario.run("adsql", dir: dir, config: combo)
      }
    }
  }
}
