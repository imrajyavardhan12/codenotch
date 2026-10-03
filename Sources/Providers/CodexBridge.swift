import AppKit
import Foundation
import os

/// Asks Codex itself what the account's limits are, instead of reading what it
/// happened to write down last time it ran.
///
/// **Why this exists.** Codex publishes no usage endpoint, so the reading used
/// to come from the `rate_limits` snapshot it records in a thread's rollout
/// log. That is a *file*: it is written during a turn and never again, so the
/// figure is only as fresh as the last time Codex was used. Three days without
/// running it and the notch confidently reported a three-day-old percentage
/// while Codex's own panel, which fetches live, showed a different one.
///
/// Codex ships an app server — the same process its desktop app drives — and it
/// answers `account/rateLimits/read` with the current figure. So this spawns
/// one, asks, and stops it again. Sub-second in practice.
///
/// It is the same bargain as everywhere else here: the number comes from the
/// vendor's own tool, so the vendor's own tool has to be installed. Where it is
/// not, the rollout is still there to fall back on.
enum CodexBridge {
    /// The desktop app that carries the `codex` binary. Named `com.openai.codex`
    /// even though the bundle on disk is ChatGPT.app.
    static let appBundleID = "com.openai.codex"

    /// Where to look for the binary, in order.
    ///
    /// The app bundle first: it is the copy that matches the app writing the
    /// rollouts. Then the fixed install locations, then the Node version
    /// managers and the process's own `PATH`: Codex is published to npm, so
    /// on many machines it lives under `~/.nvm/versions/node/<v>/bin` — which
    /// no fixed list can name, and which is where the one this was written
    /// against was. Missing it did not fail loudly; it quietly meant the live
    /// figure was never asked for and the ring fell back to a log file that
    /// carries no windows at all.
    static func candidatePaths(home: String = NSHomeDirectory(),
                               appBundle: URL? = nil,
                               environmentPath: String? = ProcessInfo.processInfo.environment["PATH"],
                               fileManager: FileManager = .default) -> [URL] {
        var paths: [URL] = []
        if let appBundle {
            paths.append(appBundle.appendingPathComponent("Contents/Resources/codex"))
        }
        paths.append(URL(fileURLWithPath: "/Applications/ChatGPT.app/Contents/Resources/codex"))
        let homeURL = URL(fileURLWithPath: home)
        paths.append(homeURL.appendingPathComponent(".codex/bin/codex"))
        paths.append(URL(fileURLWithPath: "/opt/homebrew/bin/codex"))
        paths.append(URL(fileURLWithPath: "/usr/local/bin/codex"))
        for relative in [".volta/bin", ".bun/bin", ".local/bin", ".npm-global/bin"] {
            paths.append(homeURL.appendingPathComponent(relative).appendingPathComponent("codex"))
        }
        paths += nodeManagerBinaries(home: homeURL, fileManager: fileManager)
        for directory in (environmentPath ?? "").split(separator: ":") where !directory.isEmpty {
            paths.append(URL(fileURLWithPath: String(directory)).appendingPathComponent("codex"))
        }
        // A directory can be reached twice — `PATH` often repeats the fixed ones.
        var seen = Set<String>()
        return paths.filter { seen.insert($0.path).inserted }
    }

    /// `codex` under every Node version a manager has installed, newest first:
    /// an older toolchain is the likelier place for a stale copy.
    private static func nodeManagerBinaries(home: URL, fileManager: FileManager) -> [URL] {
        let roots = [
            (".nvm/versions/node", "bin"),
            ("Library/Application Support/fnm/node-versions", "installation/bin"),
            (".local/share/fnm/node-versions", "installation/bin")
        ]
        return roots.flatMap { root, bin -> [URL] in
            let directory = home.appendingPathComponent(root)
            let versions = (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? []
            return versions
                .sorted { $0.compare($1, options: .numeric) == .orderedDescending }
                .map { directory.appendingPathComponent($0).appendingPathComponent(bin)
                    .appendingPathComponent("codex") }
        }
    }

    static func executable(fileManager: FileManager = .default) -> URL? {
        let bundle = NSWorkspace.shared.urlForApplication(withBundleIdentifier: appBundleID)
        let found = candidatePaths(appBundle: bundle, fileManager: fileManager).first {
            fileManager.isExecutableFile(atPath: $0.path)
        }
        if found == nil {
            Log.usage.notice("codex: no app server binary found — falling back to the rollout")
        }
        return found
    }

    /// The environment to start Codex in.
    ///
    /// An app launched from Finder inherits launchd's bare `PATH`, not the
    /// shell's. A Codex installed through npm is a `#!/usr/bin/env node`
    /// script, so under that `PATH` it dies at once with "env: node: No such
    /// file" — the version manager's own `bin` directory is where `node` is,
    /// and it is the one place guaranteed to hold the node that installed it.
    static func environment(for executable: URL,
                            base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var directories = [executable.deletingLastPathComponent().path,
                           executable.resolvingSymlinksInPath().deletingLastPathComponent().path]
        directories += (base["PATH"] ?? "").split(separator: ":").map(String.init)
        directories += ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        var seen = Set<String>()
        var environment = base
        environment["PATH"] = directories.filter { !$0.isEmpty && seen.insert($0).inserted }
            .joined(separator: ":")
        return environment
    }

    /// A write to a pipe whose reader has gone raises SIGPIPE, which ends the
    /// process by default, and `FileHandle.write(_:)` turns the same failure
    /// into an Objective-C exception Swift cannot catch. Codex exiting before
    /// it has read its handshake is an ordinary thing for it to do, so the
    /// signal is ignored once and the throwing write is used.
    private static let ignoreBrokenPipes: Void = { signal(SIGPIPE, SIG_IGN) }()

    // MARK: - Asking

    /// One request/response against a freshly spawned app server.
    ///
    /// All three messages go out at once rather than waiting for the handshake
    /// to answer: the server reads them in order, and a round trip saved here is
    /// a round trip saved on every poll.
    static func rateLimits(executable: URL, timeout: TimeInterval = 10) throws -> Data {
        let process = Process()
        process.executableURL = executable
        process.arguments = ["app-server"]
        process.environment = environment(for: executable)
        _ = ignoreBrokenPipes
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()

        // A watchdog, because a server that never answers would otherwise hold
        // the pipe open for ever. Terminating it closes the pipe, which is what
        // ends the read loop below.
        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
        defer {
            watchdog.cancel()
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
        }

        Log.usage.debug("codex: asking \(executable.path, privacy: .public) for rate limits")
        do {
            for line in handshake {
                try input.fileHandleForWriting.write(contentsOf: Data((line + "\n").utf8))
            }
        } catch {
            Log.usage.error("codex: app server closed its input before the handshake: \(error.localizedDescription, privacy: .public)")
            throw UsageProviderError.nothingMetered("Codex's app server did not start")
        }

        var buffer = Data()
        while true {
            let chunk = output.fileHandleForReading.availableData
            if chunk.isEmpty { break }        // the server exited or was stopped
            buffer.append(chunk)
            if let answer = response(id: requestID, inLines: buffer) { return answer }
        }
        // Whatever it did say, so a protocol change is visible rather than
        // silently becoming a stale rollout reading.
        Log.usage.error("codex: app server gave no answer to id \(requestID); said: \(String(decoding: buffer.prefix(400), as: UTF8.self), privacy: .public)")
        throw UsageProviderError.nothingMetered("Codex's app server did not answer")
    }

    static let requestID = 2

    static var handshake: [String] {
        let version = Bundle.main
            .object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        return [
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientInfo":"#
                + #"{"name":"codenotch","title":"Codenotch","version":"\#(version)"}}}"#,
            #"{"jsonrpc":"2.0","method":"initialized","params":{}}"#,
            #"{"jsonrpc":"2.0","id":\#(requestID),"method":"account/rateLimits/read","params":null}"#
        ]
    }

    /// The server interleaves notifications with replies, so the reply has to be
    /// picked out by id rather than taken as "the next line".
    static func response(id: Int, inLines buffer: Data) -> Data? {
        for line in buffer.split(separator: UInt8(ascii: "\n")) {
            let data = Data(line)
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  (object["id"] as? NSNumber)?.intValue == id,
                  object["result"] != nil
            else { continue }
            return data
        }
        return nil
    }

    // MARK: - Reading the answer

    /// Turns the reply into limit windows.
    ///
    /// The same two windows the rollout carries and under the same ids, so the
    /// headline still means the same thing whichever source answered — only the
    /// spelling differs: `usedPercent` here against `used_percent` there.
    static func windows(in data: Data, now: Date = Date()) -> [LimitWindow] {
        struct Reply: Decodable {
            struct Window: Decodable {
                let usedPercent: Double?
                let windowDurationMins: Double?
                let resetsAt: Double?
            }
            struct Limits: Decodable {
                let primary: Window?
                let secondary: Window?
                let planType: String?
            }
            struct Result: Decodable { let rateLimits: Limits? }
            let result: Result?
        }

        guard let reply = try? JSONDecoder().decode(Reply.self, from: data),
              let limits = reply.result?.rateLimits
        else { return [] }

        return [(limits.primary, "primary"), (limits.secondary, "secondary")]
            .compactMap { window, id in
                guard let window, let percent = window.usedPercent else { return nil }
                return LimitWindow(
                    id: id,
                    label: CodexUsage.label(windowMinutes: window.windowDurationMins,
                                            fallback: id),
                    usedFraction: percent / 100,
                    resetsAt: window.resetsAt.map { Date(timeIntervalSince1970: $0) }
                )
            }
    }

    /// Whether the account is blocked right now, and why.
    ///
    /// `rateLimitReachedType` is null in the ordinary case. When it is not, the
    /// account has hit something — its own allowance, or a workspace's — and
    /// the headline percentage is no longer the whole story.
    static func block(in data: Data) -> UsageBlock? {
        struct Reply: Decodable {
            struct Window: Decodable { let resetsAt: Double? }
            struct Limits: Decodable {
                let primary: Window?
                let secondary: Window?
                let rateLimitReachedType: String?
            }
            struct Result: Decodable { let rateLimits: Limits? }
            let result: Result?
        }
        guard let limits = try? JSONDecoder().decode(Reply.self, from: data).result?.rateLimits,
              let reached = limits.rateLimitReachedType
        else { return nil }

        let resets = limits.primary?.resetsAt ?? limits.secondary?.resetsAt
        return UsageBlock(reason: reason(forReachedType: reached),
                          resetsAt: resets.map { Date(timeIntervalSince1970: $0) })
    }

    /// Codex's own vocabulary, turned into something worth reading on a notch.
    static func reason(forReachedType type: String) -> String {
        switch type {
        case "rate_limit_reached":
            return "Paused"
        case "workspace_owner_credits_depleted", "workspace_member_credits_depleted":
            return "Workspace credits used up"
        case "workspace_owner_usage_limit_reached", "workspace_member_usage_limit_reached":
            return "Workspace limit reached"
        default:
            // An unknown value still means blocked; saying so beats saying
            // nothing because the spelling changed.
            return "Paused"
        }
    }

    /// The plan, as Codex names it — better than the one in the id token, which
    /// goes stale when a plan changes.
    static func planType(in data: Data) -> String? {
        struct Reply: Decodable {
            struct Limits: Decodable { let planType: String? }
            struct Result: Decodable { let rateLimits: Limits? }
            let result: Result?
        }
        return try? JSONDecoder().decode(Reply.self, from: data).result?.rateLimits?.planType
    }
}
