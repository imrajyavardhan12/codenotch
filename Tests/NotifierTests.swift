import XCTest
@testable import Codenotch

/// Pings for spent limits and waiting agents. The policy — what earns a ping —
/// is pinned here through the pure `pending*` methods; delivery itself (auth,
/// posting) is covered at the bottom through a spy that never touches the real
/// notification center.
@MainActor
final class NotifierTests: XCTestCase {
    /// Stands in for UNUserNotificationCenter: records what would have posted,
    /// and answers authorization without ever prompting.
    private final class SpyDelivery: NotifierDelivery, @unchecked Sendable {
        var authorization: Notifier.Authorization = .granted
        /// What requestAuthorization should answer with. Nil means answer with
        /// the current authorization (no change).
        var answerOnRequest: Notifier.Authorization?
        private(set) var asked = 0
        private(set) var delivered: [UsageEvent] = []

        func currentAuthorization() async -> Notifier.Authorization { authorization }

        func requestAuthorization() async -> Notifier.Authorization {
            asked += 1
            let answer = answerOnRequest ?? authorization
            authorization = answer
            return answer
        }

        func deliver(_ event: UsageEvent) async { delivered.append(event) }
    }

    private func preferences(enabled: Bool = true) -> Preferences {
        let name = "NotifierTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        let prefs = Preferences(defaults: defaults)
        prefs.notificationsEnabled = enabled
        return prefs
    }

    private func notifier(enabled: Bool = true) -> (Notifier, SpyDelivery) {
        let spy = SpyDelivery()
        return (Notifier(preferences: preferences(enabled: enabled), delivery: spy), spy)
    }

    private func snapshot(id: String = "claude", name: String = "Claude",
                          fraction: Double?, fidelity: Fidelity = .official,
                          status: ProviderStatus = .ok,
                          resetsAt: Date? = nil) -> ProviderSnapshot {
        ProviderSnapshot(
            id: id, displayName: name, glyph: .claude, fidelity: fidelity,
            status: status,
            windows: fraction.map {
                [LimitWindow(id: "session", label: "Current session",
                             usedFraction: $0, resetsAt: resetsAt)]
            } ?? [],
            headlineID: "session"
        )
    }

    private func session(id: String = "s1", state: AgentSession.State,
                         waitingFor: String? = "Approve the diff") -> AgentSession {
        AgentSession(id: id, name: "Fix login", detail: "~/proj",
                     state: state, waitingFor: waitingFor, since: Date())
    }

    // MARK: - Limits

    /// A cold start at 95% is state you can already see on the ring, not a
    /// change worth interrupting you for.
    func testFirstSightNeverPings() {
        let (notifier, _) = notifier()
        XCTAssertTrue(notifier.pendingUsageEvents(for: [snapshot(fraction: 0.95)]).isEmpty)
        // …and the identical second sight is not a crossing either.
        XCTAssertTrue(notifier.pendingUsageEvents(for: [snapshot(fraction: 0.95)]).isEmpty)
    }

    func testCrossingWarningPingsOnce() {
        let (notifier, _) = notifier()
        _ = notifier.pendingUsageEvents(for: [snapshot(fraction: 0.5)])
        let events = notifier.pendingUsageEvents(for: [snapshot(fraction: 0.85)])
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.kind, .warning)
        XCTAssertTrue(events.first?.title.contains("Claude") ?? false)
        XCTAssertTrue(events.first?.title.contains("85") ?? false)
        // Still over the line on the next poll: not news any more.
        XCTAssertTrue(notifier.pendingUsageEvents(for: [snapshot(fraction: 0.86)]).isEmpty)
    }

    /// At 93% the news is the 90, not the 80 it also passed — one ping.
    func testCriticalWinsOverWarning() {
        let (notifier, _) = notifier()
        _ = notifier.pendingUsageEvents(for: [snapshot(fraction: 0.5)])
        let events = notifier.pendingUsageEvents(for: [snapshot(fraction: 0.93)])
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.kind, .critical)
    }

    func testWarningThenCriticalPingsBoth() {
        let (notifier, _) = notifier()
        _ = notifier.pendingUsageEvents(for: [snapshot(fraction: 0.5)])
        XCTAssertEqual(notifier.pendingUsageEvents(for: [snapshot(fraction: 0.85)]).first?.kind, .warning)
        XCTAssertEqual(notifier.pendingUsageEvents(for: [snapshot(fraction: 0.93)]).first?.kind, .critical)
    }

    /// A reading that dips back down re-arms its level: hovering on the line
    /// must not ping every poll, but falling and climbing again is a new event.
    func testDroppingBackRearmsTheLevel() {
        let (notifier, _) = notifier()
        _ = notifier.pendingUsageEvents(for: [snapshot(fraction: 0.5)])
        XCTAssertEqual(notifier.pendingUsageEvents(for: [snapshot(fraction: 0.85)]).count, 1)
        XCTAssertTrue(notifier.pendingUsageEvents(for: [snapshot(fraction: 0.70)]).isEmpty)
        XCTAssertEqual(notifier.pendingUsageEvents(for: [snapshot(fraction: 0.85)]).count, 1,
                       "the level never re-armed after the reading fell back")
    }

    /// A stale reading is yesterday's news: it must neither ping nor poison
    /// the baseline the next live reading compares against.
    func testStaleReadingsNeverPing() {
        let (notifier, _) = notifier()
        let stale = snapshot(fraction: 0.95, status: .stale(since: Date()))
        XCTAssertTrue(notifier.pendingUsageEvents(for: [stale]).isEmpty)
    }

    /// The honesty rule, applied to interruptions: a derived guess crossing a
    /// line is not news, it is noise.
    func testDerivedNumbersNeverPing() {
        let (notifier, _) = notifier()
        _ = notifier.pendingUsageEvents(for: [snapshot(fraction: 0.5, fidelity: .derived)])
        XCTAssertTrue(
            notifier.pendingUsageEvents(for: [snapshot(fraction: 0.95, fidelity: .derived)]).isEmpty)
    }

    func testProvidersWithoutAReadingNeverPing() {
        let (notifier, _) = notifier()
        XCTAssertTrue(notifier.pendingUsageEvents(for: [snapshot(fraction: nil)]).isEmpty)
    }

    /// Crossings are keyed by reset date: the same fraction under a fresh
    /// window is a new cycle, not an already-fired level.
    func testAFreshWindowRearmsEveryLevel() {
        let (notifier, _) = notifier()
        let reset = Date(timeIntervalSince1970: 1_787_910_000)
        _ = notifier.pendingUsageEvents(for: [snapshot(fraction: 0.5, resetsAt: reset)])
        XCTAssertEqual(
            notifier.pendingUsageEvents(for: [snapshot(fraction: 0.85, resetsAt: reset)]).count, 1)
        let next = reset.addingTimeInterval(5 * 3600)
        XCTAssertEqual(
            notifier.pendingUsageEvents(for: [snapshot(fraction: 0.85, resetsAt: next)]).count, 1,
            "a fresh window did not re-arm the level")
    }

    /// Only the ring's own number earns a ping: a secondary window burning
    /// while the headline sits at 20% is tooltip detail, not an interruption.
    func testOnlyTheHeadlineWindowCounts() {
        let (notifier, _) = notifier()
        let burning = ProviderSnapshot(
            id: "claude", displayName: "Claude", glyph: .claude,
            fidelity: .official, status: .ok,
            windows: [LimitWindow(id: "session", label: "Current session", usedFraction: 0.2),
                      LimitWindow(id: "weekly_all", label: "All models", usedFraction: 0.95)],
            headlineID: "session"
        )
        _ = notifier.pendingUsageEvents(for: [snapshot(fraction: 0.2)])
        XCTAssertTrue(notifier.pendingUsageEvents(for: [burning]).isEmpty)
    }

    /// A timestamp that wobbles by seconds is the same window, not a new one:
    /// minute resolution keeps it from minting a fresh key every poll.
    func testSecondLevelJitterDoesNotRefire() {
        let (notifier, _) = notifier()
        let base = Date(timeIntervalSince1970: 1_787_910_000)
        _ = notifier.pendingUsageEvents(for: [snapshot(fraction: 0.5, resetsAt: base)])
        XCTAssertEqual(
            notifier.pendingUsageEvents(for: [snapshot(fraction: 0.85, resetsAt: base)]).count, 1)
        XCTAssertTrue(
            notifier.pendingUsageEvents(
                for: [snapshot(fraction: 0.85, resetsAt: base.addingTimeInterval(30))]).isEmpty,
            "a wobbling timestamp refired the level")
    }

    /// Two providers crossing on the same pass are two pieces of news, with
    /// distinct notification identities so neither replaces the other.
    func testTwoProvidersFireInOnePass() async {
        let (notifier, spy) = notifier()
        await notifier.update(snapshots: [snapshot(id: "a", fraction: 0.5),
                                           snapshot(id: "b", fraction: 0.5)])
        await notifier.update(snapshots: [snapshot(id: "a", fraction: 0.85),
                                           snapshot(id: "b", fraction: 0.93)])
        XCTAssertEqual(spy.delivered.count, 2)
        XCTAssertEqual(Set(spy.delivered.map(\.id)).count, 2,
                       "two pings shared one notification identity")
        XCTAssertEqual(Set(spy.delivered.map(\.kind)), [.warning, .critical])
    }

    // MARK: - Sessions

    func testABusySessionNeverPings() {
        let (notifier, _) = notifier()
        _ = notifier.pendingSessionEvents(for: ["claude": [session(state: .busy)]])
        XCTAssertTrue(
            notifier.pendingSessionEvents(for: ["claude": [session(state: .busy)]]).isEmpty)
    }

    /// Opening the app onto an already-waiting room seeds silently; the ping
    /// is for the *transition* into waiting.
    func testFirstSightWaitingSeedsSilently() {
        let (notifier, _) = notifier()
        XCTAssertTrue(
            notifier.pendingSessionEvents(for: ["claude": [session(state: .waiting)]]).isEmpty)
        XCTAssertTrue(
            notifier.pendingSessionEvents(for: ["claude": [session(state: .waiting)]]).isEmpty)
    }

    func testNewlyWaitingPingsOnce() {
        let (notifier, _) = notifier()
        _ = notifier.pendingSessionEvents(for: ["claude": [session(state: .busy)]])
        let events = notifier.pendingSessionEvents(for: ["claude": [session(state: .waiting)]])
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.kind, .waiting)
        XCTAssertTrue(events.first?.title.contains("Fix login") ?? false)
        XCTAssertTrue(events.first?.body.contains("Approve the diff") ?? false,
                      "the ping should say what it wants, not just that it waits")
        // Still waiting on the next poll: already said.
        XCTAssertTrue(
            notifier.pendingSessionEvents(for: ["claude": [session(state: .waiting)]]).isEmpty)
    }

    /// A session that resolves and waits again is a new interruption, not a echo.
    func testAResolvedSessionRearms() {
        let (notifier, _) = notifier()
        _ = notifier.pendingSessionEvents(for: ["claude": [session(state: .busy)]])
        XCTAssertEqual(
            notifier.pendingSessionEvents(for: ["claude": [session(state: .waiting)]]).count, 1)
        XCTAssertTrue(notifier.pendingSessionEvents(for: [:]).isEmpty)
        XCTAssertEqual(
            notifier.pendingSessionEvents(for: ["claude": [session(state: .waiting)]]).count, 1,
            "a session that waited again after resolving never pinged")
    }

    /// No snapshot has named this provider yet (sessions arrived first), so
    /// the ping falls back to the raw id rather than to an empty string.
    func testAnUnnamedProviderFallsBackToItsID() {
        let (notifier, _) = notifier()
        _ = notifier.pendingSessionEvents(for: ["claude": [session(state: .busy)]])
        let events = notifier.pendingSessionEvents(for: ["claude": [session(state: .waiting)]])
        XCTAssertTrue(events.first?.body.contains("claude") ?? false)
    }

    // MARK: - Delivery

    func testSwitchedOffDeliversNothingAndNeverAsks() async {
        let (notifier, spy) = notifier(enabled: false)
        spy.authorization = .unknown
        await notifier.update(snapshots: [snapshot(fraction: 0.5)])
        await notifier.update(snapshots: [snapshot(fraction: 0.95)])
        XCTAssertTrue(spy.delivered.isEmpty)
        XCTAssertEqual(spy.asked, 0, "being switched off must not even prompt for permission")
    }

    /// A denial is remembered by the system, not argued with: no re-prompt,
    /// no delivery, and the settings sheet is told so it can say so.
    func testDeniedDeliversNothingAndNeverReprompts() async {
        let (notifier, spy) = notifier()
        spy.authorization = .denied
        await notifier.update(snapshots: [snapshot(fraction: 0.5)])
        await notifier.update(snapshots: [snapshot(fraction: 0.95)])
        XCTAssertTrue(spy.delivered.isEmpty)
        XCTAssertEqual(spy.asked, 0, "a denial must never be re-prompted")
        XCTAssertEqual(notifier.authorization, .denied)
    }

    func testGrantedDelivers() async {
        let (notifier, spy) = notifier()
        // First sight seeds silently.
        await notifier.update(snapshots: [snapshot(fraction: 0.5)])
        XCTAssertTrue(spy.delivered.isEmpty)
        await notifier.update(snapshots: [snapshot(fraction: 0.85)])
        XCTAssertEqual(spy.delivered.count, 1)
        XCTAssertEqual(spy.delivered.first?.kind, .warning)
        XCTAssertEqual(notifier.authorization, .granted)
    }

    /// Usage and session events arrive on independent sinks: their first-ever
    /// events landing in the same tick must still prompt exactly once.
    func testConcurrentFirstEventsPromptOnce() async {
        let (notifier, spy) = notifier()
        spy.authorization = .unknown
        spy.answerOnRequest = .granted
        await notifier.update(snapshots: [snapshot(fraction: 0.5)])
        await notifier.update(sessions: ["claude": [session(state: .busy)]])
        async let usage = notifier.update(snapshots: [snapshot(fraction: 0.85)])
        async let waiting = notifier.update(sessions: ["claude": [session(state: .waiting)]])
        await usage
        await waiting
        XCTAssertEqual(spy.asked, 1, "concurrent first events prompted twice")
        XCTAssertEqual(spy.delivered.count, 2)
    }

    /// The prompt appears exactly once, on the first thing worth saying — never
    /// up front, never again.
    func testUnknownAsksOnceOnTheFirstEvent() async {
        let (notifier, spy) = notifier()
        spy.authorization = .unknown
        spy.answerOnRequest = .granted
        await notifier.update(snapshots: [snapshot(fraction: 0.5)])
        XCTAssertEqual(spy.asked, 0, "a quiet poll must not prompt")
        await notifier.update(snapshots: [snapshot(fraction: 0.85)])
        XCTAssertEqual(spy.asked, 1)
        XCTAssertEqual(spy.delivered.count, 1)
        await notifier.update(snapshots: [snapshot(fraction: 0.5)])
        await notifier.update(snapshots: [snapshot(fraction: 0.86)])
        XCTAssertEqual(spy.asked, 1, "an answered prompt must not be asked again")
    }

    func testNotificationsDefaultToOn() {
        let name = "NotifierTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        XCTAssertTrue(Preferences(defaults: defaults).notificationsEnabled)
    }
}
