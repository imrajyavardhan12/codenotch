import XCTest
@testable import Codenotch

/// One hung endpoint must not hold every other ring hostage. `refresh()` used
/// to await each provider in turn; now the fetches overlap, each slot is
/// bounded by `perProviderTimeout`, and the provider order is restored
/// afterwards so rings never swap places.
@MainActor
final class ConcurrentRefreshTests: XCTestCase {
    private final class Stub: UsageProvider, @unchecked Sendable {
        let id: String
        let displayName: String
        let glyph = ProviderGlyph.claude
        /// How long the fetch takes. Mutated only between refreshes, never
        /// while one is in flight.
        var delay: TimeInterval

        init(id: String, delay: TimeInterval = 0) {
            self.id = id
            self.displayName = id
            self.delay = delay
        }

        func fetchSnapshot() async throws -> ProviderSnapshot {
            if delay > 0 {
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            return ProviderSnapshot(
                id: id, displayName: displayName, glyph: glyph,
                fidelity: .official, status: .ok,
                windows: [LimitWindow(id: "w", label: "W", usedFraction: 0.5)]
            )
        }
    }

    private func freshDefaults() -> UserDefaults {
        let name = "ConcurrentRefreshTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private func store(_ providers: [Stub], timeout: TimeInterval = 0.3) -> UsageStore {
        UsageStore(providers: providers, perProviderTimeout: timeout,
                   archive: UsageArchive(defaults: freshDefaults()))
    }

    /// The regression this exists for: a 5s hang behind a sequential loop made
    /// every ring wait 5s. Now the hung slot degrades on the timeout while the
    /// healthy one reads normally.
    func testASlowProviderDoesNotBlockTheOthers() async {
        let store = store([Stub(id: "slow", delay: 5), Stub(id: "fast")])

        let start = Date()
        await store.refresh()
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertLessThan(elapsed, 4, "refresh waited out the hung provider")
        let byID = Dictionary(uniqueKeysWithValues: store.snapshots.map { ($0.id, $0) })
        XCTAssertEqual(byID["fast"]?.windows.count, 1, "the healthy provider has no reading")
        XCTAssertTrue(byID["slow"]?.windows.isEmpty ?? false,
                      "the hung provider should have degraded to no reading on a cold start")
    }

    /// Rings are positional: whichever provider answers first must not steal
    /// another's place.
    func testOrderFollowsProvidersNotFinishOrder() async {
        let store = store([Stub(id: "slow", delay: 0.25), Stub(id: "fast")], timeout: 5)
        await store.refresh()
        XCTAssertEqual(store.snapshots.map(\.id), ["slow", "fast"])
    }

    /// A timeout ages like any other fetch failure: the number already shown
    /// was true when taken, so it survives dimmed rather than being dropped.
    func testATimeoutFallsBackToTheLastGoodReading() async {
        let slow = Stub(id: "slow")
        let store = store([slow])
        await store.refresh()
        XCTAssertEqual(store.snapshots.first?.windows.count, 1)

        slow.delay = 5
        await store.refresh()

        XCTAssertEqual(store.snapshots.first?.windows.count, 1,
                       "the last good reading was dropped by a timeout")
    }

    /// …and it says what happened rather than reporting success.
    func testATimeoutReadsAsAnErrorNotOk() async {
        let store = store([Stub(id: "slow", delay: 5)])
        await store.refresh()
        guard case .error(let why) = store.snapshots.first?.status else {
            return XCTFail("a timed-out first fetch should be .error, "
                           + "got \(String(describing: store.snapshots.first?.status))")
        }
        XCTAssertTrue(why.contains("Timed out"), "unexpected message: \(why)")
    }

    /// The shipped default is a bound, not a hair-trigger: comfortably above
    /// any healthy fetch, comfortably below any hang a user would notice.
    /// Built without the test helper's shortened timeout — that is what this
    /// pins, so it must see the real default.
    func testTheDefaultTimeoutIsSane() {
        let store = UsageStore(providers: [Stub(id: "a")],
                               archive: UsageArchive(defaults: freshDefaults()))
        XCTAssertGreaterThanOrEqual(store.perProviderTimeoutForTesting, 5)
        XCTAssertLessThanOrEqual(store.perProviderTimeoutForTesting, 60)
    }
}
