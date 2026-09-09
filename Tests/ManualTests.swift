import XCTest
@testable import Codenotch

/// Declared limits: period math, validation, storage, and the provider that
/// renders them. The date math is pinned hardest — month lengths and DST are
/// where rolling windows go wrong.
final class ManualLimitTests: XCTestCase {
    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func limit(name: String = "Copilot", limit: Int = 100, used: Int = 0,
                       period: ManualLimit.Period = .week,
                       started: Date = Date(timeIntervalSince1970: 1_787_900_000)) -> ManualLimit {
        ManualLimit(id: UUID().uuidString, name: name, limit: limit, used: used,
                    period: period, windowStartedAt: started)
    }

    func testFraction() {
        XCTAssertEqual(limit(limit: 100, used: 25).fraction, 0.25)
    }

    /// Going over is meaningful, not an error: the ring pins at full (see
    /// `ProviderRing.sweep`) and the number keeps climbing past 100%.
    func testGoingOverKeepsClimbing() {
        XCTAssertEqual(limit(limit: 100, used: 112).fraction, 1.12, accuracy: 0.0001)
    }

    func testWindowEndFollowsThePeriod() {
        let start = Date(timeIntervalSince1970: 1_787_900_000)
        XCTAssertEqual(limit(period: .day, started: start).windowEnd(calendar: utc),
                       utc.date(byAdding: .day, value: 1, to: start))
        XCTAssertEqual(limit(period: .week, started: start).windowEnd(calendar: utc),
                       utc.date(byAdding: .weekOfYear, value: 1, to: start))
        XCTAssertEqual(limit(period: .month, started: start).windowEnd(calendar: utc),
                       utc.date(byAdding: .month, value: 1, to: start))
    }

    /// Inside the window, nothing moves — a read must not rewrite the store.
    func testNoAdvanceInsideTheWindow() {
        let started = Date(timeIntervalSince1970: 1_787_900_000)
        let current = limit(used: 40, period: .week, started: started)
        let advanced = current.advanced(to: started.addingTimeInterval(3600), calendar: utc)
        XCTAssertEqual(advanced, current)
    }

    func testRolloverZeroesUse() {
        let started = Date(timeIntervalSince1970: 1_787_900_000)
        let current = limit(used: 90, period: .week, started: started)
        let advanced = current.advanced(to: started.addingTimeInterval(8 * 24 * 3600), calendar: utc)
        XCTAssertEqual(advanced.used, 0)
        XCTAssertEqual(advanced.windowStartedAt,
                       utc.date(byAdding: .weekOfYear, value: 1, to: started))
    }

    /// A long absence advances several windows at once: landing "in" a window
    /// that ended weeks ago would show a reset countdown to a date already gone.
    func testCatchesUpMultipleWindows() {
        let started = Date(timeIntervalSince1970: 1_787_900_000)
        let current = limit(used: 90, period: .day, started: started)
        let now = started.addingTimeInterval(10 * 24 * 3600 + 3600)
        let advanced = current.advanced(to: now, calendar: utc)
        XCTAssertEqual(advanced.used, 0)
        let end = try! XCTUnwrap(advanced.windowEnd(calendar: utc))
        XCTAssertTrue(end > now, "landed in an already-ended window")
    }

    /// Months are not 30 days: Jan 31 plus one month is Feb 28, and the next
    /// window must start there rather than drifting.
    func testMonthBoundary() {
        let calendar = utc
        let start = calendar.date(from: DateComponents(year: 2026, month: 1, day: 31))!
        let current = limit(used: 10, period: .month, started: start)
        let advanced = current.advanced(
            to: calendar.date(from: DateComponents(year: 2026, month: 3, day: 5))!,
            calendar: calendar)
        XCTAssertEqual(advanced.windowStartedAt,
                       calendar.date(from: DateComponents(year: 2026, month: 2, day: 28)))
        XCTAssertEqual(advanced.used, 0)
    }

    /// The reason the window math goes through Calendar instead of raw
    /// seconds: across spring-forward, a day is 23 hours but still a day.
    func testDaylightSavingBoundary() {
        var eastern = Calendar(identifier: .gregorian)
        eastern.timeZone = TimeZone(identifier: "America/New_York")!
        // Midnight Mar 7 2026 plus one day is midnight Mar 8, not +86400s
        // (which would land at 1 AM and drift every window after).
        let start = eastern.date(from: DateComponents(year: 2026, month: 3, day: 7))!
        let current = limit(used: 10, period: .day, started: start)
        XCTAssertEqual(current.windowEnd(calendar: eastern),
                        eastern.date(from: DateComponents(year: 2026, month: 3, day: 8)))
        // Just past the short midnight, the window rolls and zeroes use.
        let advanced = current.advanced(
            to: eastern.date(from: DateComponents(year: 2026, month: 3, day: 8, hour: 0, minute: 1))!,
            calendar: eastern)
        XCTAssertEqual(advanced.used, 0)
        XCTAssertEqual(advanced.windowStartedAt,
                        eastern.date(from: DateComponents(year: 2026, month: 3, day: 8)))
    }

    func testValidation() {
        XCTAssertNotNil(ManualLimit.validate(name: "", limit: 100, used: 0))
        XCTAssertNotNil(ManualLimit.validate(name: "  ", limit: 100, used: 0))
        XCTAssertNotNil(ManualLimit.validate(name: "X", limit: 0, used: 0))
        XCTAssertNotNil(ManualLimit.validate(name: "X", limit: -5, used: 0))
        XCTAssertNotNil(ManualLimit.validate(name: "X", limit: 100, used: -1))
        // Over budget is allowed — it is the event worth seeing.
        XCTAssertNil(ManualLimit.validate(name: "X", limit: 100, used: 150))
        XCTAssertNil(ManualLimit.validate(name: "Copilot", limit: 100, used: 0))
    }
}

/// Declarations persist beside every other preference and round-trip intact.
@MainActor
final class ManualPreferencesTests: XCTestCase {
    private func preferences() -> (Preferences, UserDefaults) {
        let name = "ManualPreferencesTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return (Preferences(defaults: defaults), defaults)
    }

    private func limit() -> ManualLimit {
        ManualLimit(id: "abc", name: "Copilot", limit: 2000, used: 640,
                    period: .week, windowStartedAt: Date(timeIntervalSince1970: 1_787_900_000))
    }

    func testRoundTrips() {
        let (prefs, defaults) = preferences()
        prefs.addManualLimit(limit())
        let relaunched = Preferences(defaults: defaults)
        XCTAssertEqual(relaunched.manualLimits, [limit()])
    }

    func testUpdateAndRemove() {
        let (prefs, _) = preferences()
        prefs.addManualLimit(limit())
        var edited = limit()
        edited.used = 700
        prefs.updateManualLimit(edited)
        XCTAssertEqual(prefs.manualLimit(id: "abc")?.used, 700)
        prefs.removeManualLimit(id: "abc")
        XCTAssertTrue(prefs.manualLimits.isEmpty)
        // Removing what is not there is a no-op, not a crash.
        prefs.removeManualLimit(id: "nope")
        prefs.updateManualLimit(edited)
    }

    func testACorruptArrayDecodesToEmpty() {
        let (prefs, defaults) = preferences()
        _ = prefs
        defaults.set(Data("not json".utf8), forKey: "manualLimits")
        XCTAssertTrue(Preferences(defaults: defaults).manualLimits.isEmpty)
    }
}

/// The provider: snapshots from declarations, rollover persisted, honest
/// absence when deleted mid-flight.
@MainActor
final class ManualProviderTests: XCTestCase {
    private func preferences(with limits: [ManualLimit] = []) -> Preferences {
        let name = "ManualProviderTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        let prefs = Preferences(defaults: defaults)
        for limit in limits { prefs.addManualLimit(limit) }
        return prefs
    }

    private func limit(used: Int = 25) -> ManualLimit {
        // Anchored now: an August anchor would have rolled over (zeroing use)
        // by the time this runs, which is the rollover test's job, not this one's.
        ManualLimit(id: "abc", name: "Copilot", limit: 100, used: used,
                    period: .week, windowStartedAt: Date())
    }

    func testIdentity() {
        let provider = ManualProvider(limit: limit(), preferences: preferences())
        XCTAssertEqual(provider.id, "manual-abc")
        XCTAssertEqual(provider.displayName, "Copilot")
        XCTAssertEqual(provider.glyph, .custom)
        XCTAssertTrue(ManualProvider.isManual(id: "manual-abc"))
        XCTAssertFalse(ManualProvider.isManual(id: "claude"))
        XCTAssertEqual(ManualProvider.limitID(forProviderID: "manual-abc"), "abc")
        XCTAssertNil(ManualProvider.limitID(forProviderID: "claude"))
    }

    func testAFetchBuildsTheSnapshot() async throws {
        let prefs = preferences(with: [limit()])
        let snapshot = try await ManualProvider(limit: limit(), preferences: prefs).fetchSnapshot()
        XCTAssertEqual(snapshot.headline?.usedFraction ?? -1, 0.25, accuracy: 0.0001)
        XCTAssertEqual(snapshot.fidelity, .manual)
        XCTAssertEqual(snapshot.headline?.id, "usage")
        XCTAssertNotNil(snapshot.headline?.resetsAt)
    }

    /// The window rolled over between polls: the fetch advances it, zeroes
    /// use, and writes the advanced limit back — once, not on every fetch.
    func testRolloverPersists() async throws {
        // Deliberately last month: the window must roll over on read.
        let old = ManualLimit(id: "abc", name: "Copilot", limit: 100, used: 90,
                              period: .week,
                              windowStartedAt: Date(timeIntervalSince1970: 1_787_900_000))
        let prefs = preferences(with: [old])
        let provider = ManualProvider(limit: old, preferences: prefs)
        let snapshot = try await provider.fetchSnapshot()
        XCTAssertEqual(snapshot.headline?.usedFraction ?? -1, 0, accuracy: 0.0001)
        XCTAssertEqual(prefs.manualLimit(id: "abc")?.used, 0)
        // Second fetch: already advanced, so nothing is rewritten and the
        // store's no-op guard sees an identical declaration.
        let again = prefs.manualLimit(id: "abc")
        _ = try await ManualProvider(limit: again!, preferences: prefs).fetchSnapshot()
        XCTAssertEqual(prefs.manualLimit(id: "abc")?.used, 0)
    }

    /// Deleted in Settings while a fetch was running: gone, not signed out —
    /// there was never anything to sign into.
    func testAMissingLimitReadsAsGone() async {
        let prefs = preferences()
        do {
            _ = try await ManualProvider(limit: limit(), preferences: prefs).fetchSnapshot()
            XCTFail("a deleted limit should read as gone")
        } catch UsageProviderError.nothingMetered {
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func testAccountRowSaysDeclared() {
        let account = ManualProvider(limit: limit(), preferences: preferences()).account()
        XCTAssertTrue(account?.summary.contains("Declared by you") ?? false)
    }
}

/// Declared rings join, leave, and hide exactly like borrowed ones.
@MainActor
final class ManualStoreTests: XCTestCase {
    private func preferences(with limits: [ManualLimit] = []) -> Preferences {
        let name = "ManualStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        let prefs = Preferences(defaults: defaults)
        for limit in limits { prefs.addManualLimit(limit) }
        return prefs
    }

    private func store(manual prefs: Preferences) -> UsageStore {
        let name = "ManualStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return UsageStore(providers: [], archive: UsageArchive(defaults: defaults),
                          manualProviders: prefs.manualLimits.map {
                              ManualProvider(limit: $0, preferences: prefs)
                          })
    }

    private func limit(id: String = "abc", used: Int = 25) -> ManualLimit {
        // Anchored now, for the reason ManualProviderTests.limit says.
        ManualLimit(id: id, name: "Copilot", limit: 100, used: used,
                    period: .week, windowStartedAt: Date())
    }

    func testManualRingsJoinTheList() async {
        let store = store(manual: preferences(with: [limit()]))
        await store.refresh()
        XCTAssertEqual(store.snapshots.map(\.id), ["manual-abc"])
        XCTAssertEqual(store.snapshots.first?.headlineText, "25%")
    }

    /// Deleting a declaration takes its numbers with it: snapshots, memory
    /// and archive, so a removed limit never comes back at the next launch.
    func testDeletingForgetsEverything() async {
        let archiveDefaults: UserDefaults = {
            let name = "ManualStoreTests.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: name)!
            defaults.removePersistentDomain(forName: name)
            return defaults
        }()
        let prefs = preferences(with: [limit()])
        let providers = prefs.manualLimits.map { ManualProvider(limit: $0, preferences: prefs) }
        let store = UsageStore(providers: [], archive: UsageArchive(defaults: archiveDefaults),
                               manualProviders: providers)
        await store.refresh()
        XCTAssertEqual(store.snapshots.count, 1)

        store.manualProviders = []
        XCTAssertTrue(store.snapshots.isEmpty)
        XCTAssertTrue(UsageArchive(defaults: archiveDefaults).load().isEmpty,
                      "a deleted limit's reading survived in the archive")

        let relaunched = UsageStore(providers: [], archive: UsageArchive(defaults: archiveDefaults))
        XCTAssertTrue(relaunched.snapshots.isEmpty)
    }

    /// A no-op rebuild — the same declarations re-wrapped — must not refetch:
    /// without the guard every keystroke mid-edit would spend every
    /// provider's rate-limit budget.
    func testAnUnchangedRebuildDoesNotRefetch() async {
        final class Counting: UsageProvider, @unchecked Sendable {
            let id = "fixed"
            let displayName = "Fixed"
            let glyph = ProviderGlyph.claude
            var calls = 0
            func fetchSnapshot() async throws -> ProviderSnapshot {
                calls += 1
                return ProviderSnapshot(id: id, displayName: displayName, glyph: glyph,
                                        fidelity: .official, status: .ok, windows: [])
            }
        }
        let name = "ManualStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        let fixed = Counting()
        let store = UsageStore(providers: [fixed], archive: UsageArchive(defaults: defaults))
        await store.refresh()
        XCTAssertEqual(fixed.calls, 1)

        let prefs = preferences(with: [limit()])
        store.manualProviders = prefs.manualLimits.map { ManualProvider(limit: $0, preferences: prefs) }
        store.manualProviders = prefs.manualLimits.map { ManualProvider(limit: $0, preferences: prefs) }
        try? await Task.sleep(nanoseconds: 300_000_000)
        // One rebuild fetched once; the identical second rebuild fetched nothing.
        XCTAssertLessThanOrEqual(fixed.calls, 2)
    }

    func testASwitchedOffManualRingIsNotFetched() async {
        let prefs = preferences(with: [limit()])
        let name = "ManualStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        let store = UsageStore(providers: [], archive: UsageArchive(defaults: defaults),
                               disconnected: ["manual-abc"],
                               manualProviders: prefs.manualLimits.map {
                                   ManualProvider(limit: $0, preferences: prefs)
                               })
        await store.refresh()
        XCTAssertTrue(store.snapshots.isEmpty)
    }
}
