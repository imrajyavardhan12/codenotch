import Foundation
import os

/// Reading another app's keychain secret through `/usr/bin/security`, the way
/// that app wrote it.
///
/// Claude Code saves its token with `security add-generic-password -U`, and
/// Antigravity's Go `keyring` package shells out to the same tool. Every such
/// write resets the item's *partition list* to Apple's own tools, which drops
/// whatever "Always Allow" had added for Codenotch — so a direct
/// `SecItemCopyMatching` read raised the access dialogue again after every
/// token refresh, however many times Always Allow was clicked. Confirmed on a
/// live machine: Always Allow at 20:50, the next prompt eleven hours later,
/// four minutes after Claude Code rewrote the item.
///
/// `/usr/bin/security` is on the item's access list and inside its partition
/// list by construction, because it is the writer. Asking it reads the same
/// secret with no dialogue, no matter how often the owner rotates it. Nothing
/// is written, and the secret is never logged.
enum SecurityTool {
    enum Outcome: Equatable {
        case secret(Data)
        /// Exit 44: no such item. The owner has signed out or never signed in.
        case notFound
        /// Anything else — the tool could not run, timed out, or failed in a
        /// way that says nothing about the item. The caller may try another way.
        case failed
    }

    /// `security`'s exit status for "The specified item could not be found".
    static let itemNotFoundStatus: Int32 = 44
    /// Long enough for a slow disk on wake; short enough that a hung tool
    /// cannot hold a refresh hostage.
    static let timeout: TimeInterval = 10

    static func read(service: String, account: String?) -> Outcome {
        var arguments = ["find-generic-password", "-s", service]
        if let account { arguments += ["-a", account] }
        arguments.append("-w")

        let tool = Process()
        tool.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        tool.arguments = arguments
        let out = Pipe()
        tool.standardOutput = out
        tool.standardError = FileHandle.nullDevice
        do {
            try tool.run()
        } catch {
            Log.usage.error("could not run the security tool: \(error.localizedDescription, privacy: .public)")
            return .failed
        }

        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [tool] in
            if tool.isRunning { tool.terminate() }
        }
        // Drain before waiting: a full pipe nobody reads is a deadlock.
        let data = out.fileHandleForReading.readDataToEndOfFile()
        tool.waitUntilExit()

        let outcome = outcome(status: tool.terminationStatus, output: data)
        if outcome == .failed {
            Log.usage.error("security tool read of \(service, privacy: .public) failed: exit \(tool.terminationStatus)")
        }
        return outcome
    }

    /// The mapping from what the tool printed to what it means, apart from
    /// running it — the half a unit test can reach without a keychain.
    static func outcome(status: Int32, output: Data) -> Outcome {
        guard status == 0 else {
            return status == itemNotFoundStatus ? .notFound : .failed
        }
        var trimmed = output
        while trimmed.last == 0x0A || trimmed.last == 0x0D { trimmed.removeLast() }
        guard !trimmed.isEmpty else { return .failed }
        return .secret(unhexed(trimmed) ?? trimmed)
    }

    /// `-w` prints a secret that is not printable text as bare hex instead.
    /// Neither owner writes such a secret today, but the JSON they do write
    /// can never be mistaken for hex — it starts with `{` — so decoding only
    /// what is entirely an even run of hex digits is safe either way. Go's
    /// keyring payload starts with `go-keyring-base64:`, which is not hex
    /// either.
    static func unhexed(_ data: Data) -> Data? {
        guard data.count.isMultiple(of: 2),
              let text = String(data: data, encoding: .ascii),
              text.allSatisfy(\.isHexDigit)
        else { return nil }
        var bytes = Data(capacity: data.count / 2)
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(index, offsetBy: 2)
            guard let byte = UInt8(text[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return bytes
    }
}
