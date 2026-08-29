import Foundation

// Test-CLI: test_main <projektordner> [--dry] [--search <ordner>]
let args = CommandLine.arguments
guard args.count >= 2 else {
    print("usage: test_main <folder> [--dry] [--search <folder>]")
    exit(1)
}
let folder = URL(fileURLWithPath: args[1])
var options = CollectOptions(dryRun: args.contains("--dry"), searchFolder: nil)
if let i = args.firstIndex(of: "--search"), i + 1 < args.count {
    options.searchFolder = URL(fileURLWithPath: args[i + 1])
}

let engine = CollectEngine(log: { print($0) })
let stats = engine.run(folder: folder, options: options)
print("STATS projects=\(stats.projects) copied=\(stats.copied) present=\(stats.alreadyPresent) viaSearch=\(stats.foundViaSearch) missing=\(stats.missing.count) errors=\(stats.errors.count)")
