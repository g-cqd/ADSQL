import ADSQL
import Foundation

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

// adsql-bench [--rows N] [--seconds S] [--engine adsql|sqlite] [--dir PATH] [scenarios...]
// Scenarios: cold get scan concurrent upsert table sql fts strategy search
// Default (no scenario args): cold get scan concurrent upsert table.
// `sql`, `fts`, and `search` are opt-in (heavier): the FTS index build is
// write-amplified today (F6b), so a bare run would otherwise stall on it — pass
// the scenario explicitly. `search` is the RFC 0010 §1 apple-docs `/search`
// hot-path measurement (ADSQL `searchPagesFramed` vs SQLite, single-thread latency
// + 1/2/4/8-thread concurrency scaling); it builds its own apple-docs-shaped corpus.
//
// REAL-CORPUS mode for `search`: pass `--corpus <adsql-path> --sqlite <sqlite-path>`
// to SKIP synthetic generation and measure against pre-built databases instead (the
// definitive RFC 0010 §1 measurement at the real 4 GB apple-docs scale). Runs the
// ORIGINAL `searchPagesFramed` only (the real corpus has no F6 denorm columns).
// Additionally pass `--corpus-denorm <adsql-path>` (an ADSQL corpus whose documents
// carry the F6 denorm columns) to ALSO measure `searchPagesFramedDenorm` at real
// scale — the decisive "does F6 cross SQLite" arm (RFC 0010 §2.2-2.4 "F6").

// Line-buffer stdout so progress prints (corpus build, per-step latency) flush LIVE
// even when redirected to a file. Fully-buffered output otherwise withholds them until
// the buffer fills or the process exits — which can make a long-but-progressing run
// (e.g. a large read battery) look like a stuck build until it's killed.
setvbuf(stdout, nil, _IOLBF, 0)

var config = BenchConfig()
var engines = ["adsql", "sqlite"]
var scenarios: [String] = []
var dir = "/tmp/adsql-bench"

var iterator = CommandLine.arguments.dropFirst().makeIterator()
while let argument = iterator.next() {
    switch argument {
    case "--rows":
        config.rows = Int(iterator.next() ?? "") ?? config.rows
    case "--point-gets":
        config.pointGets = Int(iterator.next() ?? "") ?? config.pointGets
    case "--eval":
        switch iterator.next() {
        case "compiled", "compiledClosures": config.evaluator = .compiledClosures
        case "vdbe": config.evaluator = .vdbe
        default: config.evaluator = .treeWalk
        }
    case "--join":
        switch iterator.next() {
        case "hash": config.joinStrategy = .hash
        case "merge": config.joinStrategy = .merge
        case "auto": config.joinStrategy = .auto
        default: config.joinStrategy = .nestedLoop
        }
    case "--insert":
        switch iterator.next() {
        case "hoisted": config.insertStrategy = .hoisted
        case "appendCursor", "append": config.insertStrategy = .appendCursor
        default: config.insertStrategy = .standard
        }
    case "--seconds":
        config.concurrentSeconds = Double(iterator.next() ?? "") ?? config.concurrentSeconds
    case "--engine":
        if let engine = iterator.next() { engines = [engine] }
    case "--corpus":
        config.realADSQLPath = iterator.next()
    case "--corpus-denorm":
        config.realDenormPath = iterator.next()
    case "--sqlite":
        config.realSQLitePath = iterator.next()
    case "--dir":
        dir = iterator.next() ?? dir
    case "--full":
        config.rows = 858_000
    default:
        scenarios.append(argument)
    }
}
if scenarios.isEmpty { scenarios = ["cold", "get", "scan", "concurrent", "upsert", "table"] }

mkdir(dir, 0o755)
print("ADSQL bench — rows=\(config.rows), engines=\(engines.joined(separator: ",")), dir=\(dir)")
print("machine: \(ProcessInfo.processInfo.activeProcessorCount) cores")

do {
    var datasets: [String: String] = [:]
    let needsDataset = !Set(scenarios).isDisjoint(with: ["cold", "get", "scan", "concurrent"])
    if needsDataset {
        print("\n== dataset load (durability: none) ==")
        for engine in engines {
            datasets[engine] = try Scenarios.loadDataset(engine, dir: dir, config: config)
        }
    }

    for scenario in scenarios {
        print("\n== \(scenario) ==")
        for engine in engines {
            switch scenario {
            case "cold":
                try Scenarios.coldOpen(engine, path: datasets[engine]!, config: config)
            case "get":
                try Scenarios.pointGets(engine, path: datasets[engine]!, config: config)
            case "scan":
                try Scenarios.scan(engine, path: datasets[engine]!, config: config)
            case "concurrent":
                try Scenarios.concurrent(engine, path: datasets[engine]!, config: config)
            case "upsert":
                try Scenarios.upserts(engine, dir: dir, config: config)
            case "table":
                try TableScenario.run(engine, dir: dir, config: config)
            case "sql":
                try SQLScenario.run(engine, dir: dir, config: config)
            case "fts":
                try FTSScenario.run(engine, dir: dir, config: config)
            case "strategy":
                // Self-contained matrix over both engines; run once, on the first engine.
                if engine == engines.first {
                    try StrategyBench.run(engines: engines, dir: dir, config: config)
                }
            case "search":
                // RFC 0010 §1 apple-docs `/search` hot path — self-contained matrix over
                // both engines (builds the corpus + runs the read passes); run once.
                if engine == engines.first {
                    try SearchPagesScenario.run(engines: engines, dir: dir, config: config)
                }
            default:
                print("unknown scenario \(scenario)")
                exit(1)
            }
        }
    }
} catch {
    print("bench failed: \(error)")
    exit(1)
}
