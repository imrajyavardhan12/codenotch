import Foundation

/// The OpenCode Go key, borrowed from the tool's own sign-in.
///
/// `~/.local/share/opencode/auth.json` maps provider ids to credentials, and
/// a Go subscription signs in as `opencode-go` with an `sk-…` API key. Only
/// that id is claimed: a plain `opencode` entry would be a Zen OAuth login — a
/// different product on a different endpoint — and reading it here would
/// report the wrong account under Go's name.
enum OpenCodeCredentials {
    static var authURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".local/share/opencode/auth.json")
    }

    static func load(from url: URL = authURL) -> String? {
        guard let root = dictionary(at: url),
              let entry = root["opencode-go"] else { return nil }
        // The entry is an object carrying the key today; a plain string is
        // accepted too, because both shapes have shipped across tools that
        // read this file.
        if let token = string(entry) {
            return token
        }
        guard let object = entry as? [String: Any] else { return nil }
        return ["key", "apiKey", "api_key", "token"]
            .compactMap { string(object[$0]) }.first
    }

    private static func dictionary(at url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return root
    }

    /// Non-empty strings only: an empty key is worse than a missing one, it is
    /// a request that cannot succeed being sent all the same.
    private static func string(_ value: Any?) -> String? {
        (value as? String).flatMap { $0.isEmpty ? nil : $0 }
    }
}
