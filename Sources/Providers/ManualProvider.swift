import Foundation
import os

/// Counts down to a user-declared limit: the provider for tools Codenotch does
/// not read natively. The declaration lives in `Preferences`; this only reads
/// it, advances rolled-over windows, and renders the number.
///
/// The numbers are the user's, so this is `.manual` — the tooltip qualifies
/// them and nothing here is ever presented as a vendor figure. There is no
/// credential, no network and no failure mode except a limit that vanished
/// mid-flight (deleted in Settings while a fetch was running).
actor ManualProvider: UsageProvider {
    /// Provider ids for declared limits, so the UI can tell them apart from
    /// borrowed credentials without a new flag threaded through every row.
    private static let idPrefix = "manual-"

    static func id(for limitID: String) -> String { idPrefix + limitID }

    static func isManual(id: String) -> Bool { id.hasPrefix(idPrefix) }

    /// The declaration id behind a provider id, for edits and deletes, which
    /// address the stored limit rather than the ring.
    static func limitID(forProviderID id: String) -> String? {
        guard isManual(id: id) else { return nil }
        return String(id.dropFirst(idPrefix.count))
    }

    nonisolated let id: String
    nonisolated let displayName: String
    nonisolated let glyph = ProviderGlyph.custom

    /// The declaration as built. Sync reads (name, account row) come from this
    /// copy; `fetchSnapshot` re-reads preferences for the live numbers, so an
    /// edit between polls is picked up at the next one without rebuilding.
    nonisolated let limit: ManualLimit
    private let preferences: Preferences

    init(limit: ManualLimit, preferences: Preferences) {
        self.limit = limit
        self.preferences = preferences
        self.id = Self.id(for: limit.id)
        self.displayName = limit.name
    }

    nonisolated var signInRoute: SignInRoute {
        // Nothing signs in anywhere: the numbers are typed in Settings, and
        // this text only surfaces where a sign-in would otherwise be offered.
        .guidance("Numbers for this limit are entered in Settings — there is no account to sign into.")
    }

    nonisolated func forgetCachedCredential() {
        // Nothing is cached and nothing could prompt: the numbers live in
        // UserDefaults beside every other preference.
    }

    nonisolated func account() -> ProviderAccount? {
        ProviderAccount(label: nil, plan: nil, source: "Declared by you", manageURL: nil)
    }

    func fetchSnapshot() async throws -> ProviderSnapshot {
        // Fresh on every fetch: edits land between polls, and the window may
        // have rolled over since the provider was built.
        guard var current = await preferences.manualLimit(id: limit.id) else {
            // Deleted in Settings while a fetch was running. The store prunes
            // the provider on the same change, so this is a one-pass ghost:
            // report it gone rather than signed out, which would be a lie —
            // there was never anything to sign into.
            throw UsageProviderError.nothingMetered("Limit removed")
        }
        current = current.advanced()
        if current != limit {
            // Fires the preferences sink, which rebuilds the store's providers
            // and calls refreshNow() into the refresh already in flight —
            // absorbed by its guard with a log line, not a loop: the rebuilt
            // provider reads the advanced limit and writes nothing further.
            await preferences.updateManualLimit(current)
        }

        return ProviderSnapshot(
            id: id,
            displayName: current.name,
            glyph: glyph,
            fidelity: .manual,
            status: .ok,
            windows: [
                LimitWindow(id: "usage", label: "Used",
                            usedFraction: current.fraction,
                            resetsAt: current.windowEnd())
            ],
            headlineID: "usage"
        )
    }
}
