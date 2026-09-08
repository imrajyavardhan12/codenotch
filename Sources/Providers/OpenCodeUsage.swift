import Foundation

/// Parses `GET https://opencode.ai/zen/go/v1/usage`.
///
/// The recorded live shape:
///
/// ```json
/// {"usage": {"rolling": {"status": "ok", "percent": 2,
///                        "resetsAt": "2026-09-08T06:55:06.584Z"},
///             "weekly":  {"status": "ok", "percent": 2, "resetsAt": "…"},
///             "monthly": {"status": "ok", "percent": 1, "resetsAt": "…"}}}
/// ```
///
/// Three spend windows, each a percent with its reset — the Go plan's rolling,
/// weekly and monthly allowances. `status` travels along but decides nothing:
/// a percent is a percent whatever it says, and a window without one is
/// dropped rather than guessed at.
enum OpenCodeUsage {
    struct Payload {
        let windows: [LimitWindow]
    }

    /// In tooltip order. The rolling window leads: like Claude's session, it
    /// is the one that bites first, so it is the ring's number too.
    private static let windows: [(id: String, label: String)] = [
        ("rolling", "Rolling"),
        ("weekly", "Weekly"),
        ("monthly", "Monthly"),
    ]

    static func parse(_ data: Data) throws -> Payload {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let usage = root["usage"] as? [String: Any] else {
            throw UsageProviderError.badResponse(status: 0)
        }

        let windows = Self.windows.compactMap { id, label -> LimitWindow? in
            guard let window = usage[id] as? [String: Any],
                  let percent = (window["percent"] as? NSNumber)?.doubleValue else {
                return nil
            }
            return LimitWindow(id: id, label: label, usedFraction: percent / 100,
                               resetsAt: date(window["resetsAt"]))
        }

        guard !windows.isEmpty else { throw UsageProviderError.badResponse(status: 0) }
        return Payload(windows: windows)
    }

    /// ISO8601 with fractional seconds and a plain fallback — the endpoint
    /// writes `"2026-09-08T06:55:06.584Z"`, and a client this brittle about a
    /// timestamp format is a client waiting to break.
    private static func date(_ value: Any?) -> Date? {
        guard let text = value as? String else { return nil }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: text) { return date }
        return ISO8601DateFormatter().date(from: text)
    }
}
