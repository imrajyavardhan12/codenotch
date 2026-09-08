import Foundation

#if CLI_TYPES_LOCAL
// Compiled alongside the model files (CLI tool target): the types below come
// from sibling sources, nothing to import.
#else
@testable import Codenotch
#endif

/// The `codenotch status` report: last-known readings as JSON, for menu bars,
/// prompts, and scripts.
///
/// Reads nothing live — no keychain, no network, no new permissions. The app
/// already persists its last good reading per provider (`UsageArchive`), so
/// the CLI surfaces that with its age attached and lets the consumer decide
/// what "fresh enough" means. A widget polling every minute gets data at most
/// a poll old; an install the app never ran on yields an empty list, honestly.
///
/// Pure by design: every decision here is a function of its arguments, so the
/// whole surface is pinned by tests and `main.swift` stays a thin shell.
enum StatusCommand {
    struct Options {
        var pretty = false
        var providerID: String?
        var showHelp = false
    }

    struct RunResult {
        let stdout: String
        let stderr: String
        let exitCode: Int32
    }

    static let usage = """
        usage: codenotch [status] [--pretty] [--provider ID]

          Without flags prints every provider's last-known reading as compact JSON.
          --pretty        indented JSON for humans
          --provider ID   only this provider (e.g. claude, cursor, codex)
          -h, --help      this text

        Readings come from the app's archive, not live endpoints: launch
        Codenotch once and the CLI reports what it knew, each reading dated.
        """

    /// Parses `codenotch [status] [--pretty] [--provider ID] [-h|--help]`.
    static func parse(_ arguments: [String]) -> (options: Options, error: String?) {
        var options = Options()
        var args = arguments
        // Accepted and ignored: leaves room for a `refresh` or `watch` later
        // without breaking anyone's muscle memory or scripts.
        if args.first == "status" {
            args.removeFirst()
        }
        var i = args.startIndex
        while i < args.endIndex {
            let arg = args[i]
            switch arg {
            case "--pretty":
                options.pretty = true
            case "-h", "--help":
                options.showHelp = true
            case "--provider":
                i = args.index(after: i)
                guard i < args.endIndex else {
                    return (options, "--provider needs an ID")
                }
                options.providerID = args[i]
            case let flagged where flagged.hasPrefix("--provider="):
                options.providerID = String(flagged.dropFirst("--provider=".count))
            default:
                return (options, "unknown argument '\(arg)'")
            }
            i = args.index(after: i)
        }
        return (options, nil)
    }

    static func run(arguments: [String],
                    entries: [(snapshot: ProviderSnapshot, fetchedAt: Date)],
                    now: Date = Date()) -> RunResult {
        let (options, parseError) = parse(arguments)
        if options.showHelp {
            return RunResult(stdout: usage, stderr: "", exitCode: 0)
        }
        if let parseError {
            return RunResult(stdout: "", stderr: "\(parseError)\n\(usage)", exitCode: 2)
        }

        if let id = options.providerID,
           !entries.contains(where: { $0.snapshot.id == id }) {
            let known = entries.map(\.snapshot.id).sorted().joined(separator: ", ")
            return RunResult(
                stdout: "",
                stderr: "unknown provider '\(id)'"
                    + (known.isEmpty ? "" : " (known: \(known))"),
                exitCode: 2
            )
        }

        var providers = entries.map {
            StatusReport.Provider(snapshot: $0.snapshot, fetchedAt: $0.fetchedAt, now: now)
        }
        if let id = options.providerID {
            providers = providers.filter { $0.id == id }
        }
        // The archive is keyed, so its order is meaningless. Sort, so scripts
        // and screenshots see a stable listing.
        providers.sort { $0.id < $1.id }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = options.pretty
            ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
        guard let data = try? encoder.encode(StatusReport(generatedAt: now, providers: providers)),
              let json = String(data: data, encoding: .utf8) else {
            return RunResult(stdout: "", stderr: "codenotch: could not encode report", exitCode: 1)
        }
        // Empty is a valid answer, not an error — but say why, on stderr where
        // it cannot corrupt a pipe.
        let note = entries.isEmpty
            ? "codenotch: no readings yet — launch Codenotch once; the CLI reports what it knew.\n"
            : ""
        return RunResult(stdout: json, stderr: note, exitCode: 0)
    }
}

/// The JSON surface. One ready-to-render `display` string per provider ("82%",
/// "~73%", "2 left", "—") plus the raw numbers underneath for anyone doing
/// their own thresholds or bars. Machine readers: gate any threshold on
/// `fidelity == "official"` — `percentUsed` carries no qualifier of its own,
/// and a derived guess must never drive automation as if a vendor said it.
struct StatusReport: Encodable {
    struct Provider: Encodable {
        struct Window: Encodable {
            let id: String
            let label: String
            let usedFraction: Double?
            let remaining: Int?
            let used: Int?
            let resetsAt: Date?
        }

        let id: String
        let displayName: String
        let glyph: String
        let fidelity: String
        let display: String
        let percentUsed: Int?
        let headlineLabel: String?
        let resetsAt: Date?
        let fetchedAt: Date
        let ageSeconds: Int
        let windows: [Window]

        init(snapshot: ProviderSnapshot, fetchedAt: Date, now: Date) {
            id = snapshot.id
            displayName = snapshot.displayName
            glyph = snapshot.glyph.rawValue
            fidelity = snapshot.fidelity.rawValue
            // The ring's number, honesty-prefix included: a derived figure
            // arrives wearing its "~" rather than masquerading as a vendor's.
            display = "\(snapshot.fidelity.qualifier)\(snapshot.headlineText)"
            if let fraction = snapshot.usedFraction {
                percentUsed = Int((fraction * 100).rounded())
            } else {
                percentUsed = nil
            }
            headlineLabel = snapshot.headline?.label
            resetsAt = snapshot.headline?.resetsAt
            self.fetchedAt = fetchedAt
            ageSeconds = max(0, Int(now.timeIntervalSince(fetchedAt)))
            windows = snapshot.windows.map {
                Window(id: $0.id, label: $0.label, usedFraction: $0.usedFraction,
                       remaining: $0.remaining, used: $0.used, resetsAt: $0.resetsAt)
            }
        }
    }

    let generatedAt: Date
    let providers: [Provider]
}
