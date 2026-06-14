import Darwin
import Foundation

// adsql-bench [--rows N] [--seconds S] [--engine adsql|sqlite] [--dir PATH] [scenarios...]
// Scenarios: cold get scan concurrent upsert (default: all)

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
  case "--seconds":
    config.concurrentSeconds = Double(iterator.next() ?? "") ?? config.concurrentSeconds
  case "--engine":
    if let engine = iterator.next() { engines = [engine] }
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
