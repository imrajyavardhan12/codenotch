import Foundation

/// Thin entry: load the app's last-known readings and print them. All policy
/// lives in `StatusCommand` (tested); this file only touches the process.
let suiteName = "io.github.imrajyavardhan12.codenotch"
// The *app's* domain, not this tool's own: the archive is written under the
// app target's bundle id, and this target's is `…codenotch.cli`. If either is
// ever renamed, this string follows the app's — see `PRODUCT_BUNDLE_IDENTIFIER`
// in project.yml, which names both.
guard let defaults = UserDefaults(suiteName: suiteName) else {
    // Practically unreachable, but a CLI must not crash when the world is odd.
    fputs("codenotch: could not open preferences\n", stderr)
    exit(1)
}
// Cross-process reads can trail the app's writes by seconds (cfprefsd cache).
// Every reading carries its own timestamp, so consumers see the lag instead of
// tripping on it.
let archive = UsageArchive(defaults: defaults)
let entries = archive.load().values.map { (snapshot: $0.snapshot, fetchedAt: $0.fetchedAt) }
let result = StatusCommand.run(arguments: Array(CommandLine.arguments.dropFirst()),
                               entries: entries)
if !result.stderr.isEmpty {
    fputs(result.stderr + (result.stderr.hasSuffix("\n") ? "" : "\n"), stderr)
}
if !result.stdout.isEmpty {
    print(result.stdout)
}
exit(result.exitCode)
