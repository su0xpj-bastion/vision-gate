import Foundation
import VisionGate

/// gate [run] [name...] [--json]   run gates (all by default)
/// gate list                       gate -> feature
/// gate expected                   pinned fault matrix as JSON
let args = Array(CommandLine.arguments.dropFirst())
let cmd = args.first.map { ["run", "list", "expected"].contains($0) ? $0 : "run" } ?? "run"
let names = args.filter { !$0.hasPrefix("--") && !["run", "list", "expected"].contains($0) }

switch cmd {
case "list":
    for g in Gates.all { print("\(g.name)\t\(g.feature)") }
case "expected":
    let m = Dictionary(uniqueKeysWithValues: Gates.expectedFailures.map { ($0.key.rawValue, $0.value.sorted()) })
    print(String(data: try! JSONSerialization.data(withJSONObject: m, options: [.prettyPrinted, .sortedKeys]), encoding: .utf8)!)
default:
    let results = Gates.run(names)
    if args.contains("--json") {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        print(String(data: try! enc.encode(results), encoding: .utf8)!)
    } else {
        for r in results { print("  \(r.passed ? "PASS" : "FAIL")  \(r.name.padding(toLength: 30, withPad: " ", startingAt: 0)) \(r.detail)") }
        print("\(results.filter { $0.passed }.count)/\(results.count) gates passed"
              + (Fault.active.isEmpty ? "" : "  [faults: \(Fault.active.map { $0.rawValue }.sorted().joined(separator: ","))]"))
    }
    exit(results.allSatisfy { $0.passed } ? 0 : 1)
}
