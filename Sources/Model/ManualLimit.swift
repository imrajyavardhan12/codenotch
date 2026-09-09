import Foundation

/// A limit the user declares for a tool Codenotch does not read natively —
/// Copilot, Ollama, a company proxy, raw API spend. The user names the
/// allowance and keeps the count; the notch counts down to it like any other
/// ring, qualified as self-declared rather than vendor-published.
struct ManualLimit: Identifiable, Codable, Equatable, Sendable {
    enum Period: String, Codable, CaseIterable, Sendable {
        case day
        case week
        case month

        var title: String { rawValue.capitalized }

        /// The window after `date`, on the calendar — month lengths and DST
        /// included, which is why this is a function and not 30 × 24 × 3600.
        func end(ofWindowStarting date: Date, calendar: Calendar = .current) -> Date? {
            switch self {
            case .day:   return calendar.date(byAdding: .day, value: 1, to: date)
            case .week:  return calendar.date(byAdding: .weekOfYear, value: 1, to: date)
            case .month: return calendar.date(byAdding: .month, value: 1, to: date)
            }
        }
    }

    /// Stable across launches: archive entries, notification keys and the
    /// disconnected set all address the limit by this, never by its name.
    let id: String
    var name: String
    /// The allowance per period, in whatever the tool counts. Positive by
    /// construction — the editor refuses anything else.
    var limit: Int
    /// Spent in the current window. Past the limit on purpose: going over a
    /// self-declared budget is precisely the event worth seeing plainly, so
    /// the ring pins at full and the number keeps climbing.
    var used: Int
    var period: Period
    /// When the current window started. Rolls forward on read (see
    /// `advanced(to:)`), never on a timer — nothing here polls.
    var windowStartedAt: Date

    var fraction: Double {
        guard limit > 0 else { return 0 }
        return Double(used) / Double(limit)
    }

    func windowEnd(calendar: Calendar = .current) -> Date? {
        period.end(ofWindowStarting: windowStartedAt, calendar: calendar)
    }

    /// Roll the window forward to contain `now`, zeroing use on rollover. Pure:
    /// returns the limit to store, storing nothing itself. A long absence
    /// advances several windows at once rather than stopping at the first one
    /// past — landing "in" a window that ended weeks ago would show a reset
    /// countdown to a date already gone.
    func advanced(to now: Date = Date(), calendar: Calendar = .current) -> ManualLimit {
        var next = self
        while let end = next.windowEnd(calendar: calendar), end <= now {
            next.windowStartedAt = end
            next.used = 0
        }
        return next
    }

    /// What the editor refuses, in words for the form. Over budget is not an
    /// error — see `used` — so only the meaningless is rejected.
    static func validate(name: String, limit: Int, used: Int) -> String? {
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Give it a name."
        }
        if limit < 1 {
            return "The limit must be at least 1."
        }
        if used < 0 {
            return "Used can't be negative."
        }
        return nil
    }
}
