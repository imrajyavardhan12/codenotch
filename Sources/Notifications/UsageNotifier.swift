import Foundation
import UserNotifications

/// One thing worth interrupting the user for.
struct UsageEvent: Equatable, Sendable {
    enum Kind: Sendable {
        case warning
        case critical
        case waiting
    }

    /// Stable per cause: doubles as the UN request identifier, so a level
    /// still firing replaces its own notification instead of stacking new ones.
    let id: String
    let title: String
    let body: String
    let kind: Kind
}

/// The one system call the policy needs, behind a seam so tests never touch
/// the real notification center — which would prompt, or worse, actually ping.
protocol NotifierDelivery: Sendable {
    func currentAuthorization() async -> Notifier.Authorization
    func requestAuthorization() async -> Notifier.Authorization
    func deliver(_ event: UsageEvent) async
}

extension Notification.Name {
    /// Posted when a banner is clicked. The router cannot reach the settings
    /// window — it belongs to the app delegate — so this is the handoff
    /// between them, observed next to every other app-level event there.
    static let openSettings = Notification.Name("CodenotchOpenSettings")
}

/// Opens Settings when a banner is clicked. Without this a notification is a
/// dead end — it can only be dismissed, never followed. Kept beside the
/// delivery it serves rather than on the app delegate.
///
/// Deliberately free of closures and isolated state: everything here is either
/// `nonisolated` or main-actor-confined with nothing captured, so installing
/// it from the app delegate needs no hops, no captures, and no new warnings.
/// Deliberately outside any actor: it holds no state of its own, and posting
/// to the default center is thread-safe, so there is nothing to isolate —
/// which is also what keeps the conformance warning-free.
final class NotificationRouter: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationRouter()

    nonisolated static func install() {
        UNUserNotificationCenter.current().delegate = shared
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        NotificationCenter.default.post(name: .openSettings, object: nil)
        completionHandler()
    }
}

/// Posts through the real notification center. Local delivery needs no
/// entitlement and no provisioning — it works in an ad-hoc Debug build exactly
/// as in a signed release, which is why this feature does not wait on a paid
/// membership.
final class SystemNotifierDelivery: NotifierDelivery, @unchecked Sendable {
    private let center = UNUserNotificationCenter.current()

    func currentAuthorization() async -> Notifier.Authorization {
        Notifier.Authorization(from: await center.notificationSettings())
    }

    func requestAuthorization() async -> Notifier.Authorization {
        // Asked lazily on the first thing worth saying, never up front: the
        // prompt arrives with its reason already on screen behind it.
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        return granted ? .granted : .denied
    }

    func deliver(_ event: UsageEvent) async {
        let content = UNMutableNotificationContent()
        content.title = event.title
        content.body = event.body
        // The critical level gets a sound; a warning is a glance, not an alarm.
        if event.kind == .critical || event.kind == .waiting {
            content.sound = .default
        }
        let request = UNNotificationRequest(identifier: event.id, content: content, trigger: nil)
        try? await center.add(request)
    }
}

/// Decides what is newly worth a ping, and posts it.
///
/// Two sources, one rule each:
/// - **Limits:** the ring's own (headline) number crossing 80% then 90% — but
///   only when a vendor said the number (`.official`) and it is live (`.ok`).
///   A derived guess crossing a line is not news, it is noise; a stale reading
///   is yesterday's news.
/// - **Sessions:** an agent entering `waiting` — something is blocked on you.
///
/// And one rule over both: **first sight never pings, only changes do.** A cold
/// start at 95% is state you can already see on the ring, not an interruption
/// worth having. Crossings are keyed by reset date, so a fresh window re-arms
/// every level on its own.
@MainActor
final class Notifier: ObservableObject {
    enum Authorization: Equatable {
        case unknown
        case granted
        case denied

        init(from settings: UNNotificationSettings) {
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral: self = .granted
            case .denied: self = .denied
            case .notDetermined: self = .unknown
            @unknown default: self = .denied
            }
        }
    }

    /// The fractions that earn a ping. Two levels so the first is advice and
    /// the second is news: 80% means "pace yourself", 90% means "wrap up".
    static let warningLevel = 0.8
    static let criticalLevel = 0.9
    /// How far back down a reading has to come before its level re-arms.
    /// Without it a reading hovering on the line pings on every poll.
    static let rearmMargin = 0.05

    /// What the settings sheet shows, refreshed when it appears — the user may
    /// have flipped the switch in System Settings while it was closed.
    @Published private(set) var authorization: Authorization = .unknown

    private let preferences: Preferences
    private let delivery: any NotifierDelivery
    private var lastFractions: [String: Double] = [:]
    /// The reset bucket each provider was last seen in, so a fresh window
    /// re-arms every level even when no poll observed the drop between them.
    private var lastBuckets: [String: String] = [:]
    /// Usage levels already pinged, keyed `provider#level#resetsAt`.
    private var fired: Set<String> = []
    /// Waiting sessions already pinged, keyed `provider#session`.
    private var waitingFired: Set<String> = []
    private var names: [String: String] = [:]
    private var snapshotsBaselined = false
    private var sessionsBaselined = false

    init(preferences: Preferences, delivery: any NotifierDelivery = SystemNotifierDelivery()) {
        self.preferences = preferences
        self.delivery = delivery
    }

    /// New readings are in: decide what changed and, if anything did, post it.
    /// Cheap when quiet — with no events nothing touches the notification
    /// center at all, not even an authorization query. Async so callers (and
    /// tests) know delivery has finished when it returns.
    func update(snapshots: [ProviderSnapshot]) async {
        for snapshot in snapshots {
            names[snapshot.id] = snapshot.displayName
        }
        guard preferences.notificationsEnabled else { return }
        let events = pendingUsageEvents(for: snapshots)
        guard !events.isEmpty else { return }
        await deliver(events)
    }

    /// Live sessions changed: same deal for agents newly waiting on you.
    func update(sessions: [String: [AgentSession]]) async {
        guard preferences.notificationsEnabled else { return }
        let events = pendingSessionEvents(for: sessions)
        guard !events.isEmpty else { return }
        await deliver(events)
    }

    func refreshAuthorization() {
        Task { authorization = await delivery.currentAuthorization() }
    }

    /// One shared authorization flight. Usage and session events arrive on
    /// independent sinks, and without this their first-ever events in the same
    /// tick would prompt twice — the worst possible first impression on a
    /// fresh install. Concurrent callers join the same task instead.
    private var authorizationTask: Task<Authorization, Never>?

    private func deliver(_ events: [UsageEvent]) async {
        // The switch in System Settings is respected without ever re-prompting:
        // only `.unknown` asks, and a denial is remembered by the system, not
        // argued with.
        let state = await resolveAuthorization()
        authorization = state
        guard state == .granted else { return }
        for event in events {
            await delivery.deliver(event)
        }
    }

    private func resolveAuthorization() async -> Authorization {
        // Checked and set with no suspension between, on this actor, so two
        // callers can never both conclude no flight is running.
        if let authorizationTask { return await authorizationTask.value }
        let task = Task { [delivery] in
            let current = await delivery.currentAuthorization()
            if current == .unknown {
                return await delivery.requestAuthorization()
            }
            return current
        }
        authorizationTask = task
        let state = await task.value
        authorizationTask = nil
        return state
    }

    /// Which usage crossings are newly worth a ping. Pure against the held
    /// state, and exposed so tests can pin the policy without delivering
    /// anything.
    func pendingUsageEvents(for snapshots: [ProviderSnapshot]) -> [UsageEvent] {
        var events: [UsageEvent] = []
        for snapshot in snapshots {
            guard snapshot.fidelity == .official,
                  snapshot.status == .ok,
                  let fraction = snapshot.usedFraction else {
                lastFractions.removeValue(forKey: snapshot.id)
                continue
            }
            // Minute resolution on purpose: vendors publish stable window
            // boundaries, and anything finer mints a fresh key per poll — a
            // timestamp that wobbles by seconds would refire every minute
            // while over a level, which is the worst failure this feature has.
            let bucket = snapshot.headline?.resetsAt
                .map { String(Int($0.timeIntervalSince1970 / 60)) } ?? "none"
            // A new window is a new cycle even when the drop between them was
            // never observed — asleep through the reset, most often. Without
            // this, a provider that rolls over while missed stays silent at
            // 85% forever on the grounds that it never "crossed" anything.
            let bucketChanged = lastBuckets[snapshot.id] != bucket
            lastBuckets[snapshot.id] = bucket
            let previous = lastFractions[snapshot.id]
            lastFractions[snapshot.id] = fraction
            guard snapshotsBaselined, let previous else { continue }

            // Critical first, and one ping per provider per pass: at 93% the
            // news is the 90, not the 80 it also passed.
            for level in [Self.criticalLevel, Self.warningLevel] {
                let key = "\(snapshot.id)#\(level)#\(bucket)"
                if fraction >= level && (previous < level || bucketChanged)
                    && !fired.contains(key) {
                    fired.insert(key)
                    events.append(usageEvent(for: snapshot, fraction: fraction,
                                             level: level, key: key))
                    break
                } else if fraction < level - Self.rearmMargin {
                    fired.remove(key)
                }
            }
        }
        // Providers that vanished (switched off) stop being tracked, so a
        // returning one is a first sight again rather than a stale comparison.
        let live = Set(snapshots.map(\.id))
        lastFractions = lastFractions.filter { live.contains($0.key) }
        lastBuckets = lastBuckets.filter { live.contains($0.key) }
        fired = fired.filter { key in live.contains { key.hasPrefix("\($0)#") } }
        snapshotsBaselined = true
        return events
    }

    private func usageEvent(for snapshot: ProviderSnapshot, fraction: Double,
                            level: Double, key: String) -> UsageEvent {
        let percent = Int((fraction * 100).rounded())
        let label = snapshot.headline?.label ?? "Usage"
        if level >= Self.criticalLevel {
            // The same reset copy the tooltip shows, so the two surfaces
            // cannot disagree about when relief arrives.
            let reset = snapshot.headline?.resetsAt
                .map { ResetCopy.text(for: $0) + "." }
                ?? "Wrap up, or wait for the reset."
            return UsageEvent(
                id: key,
                title: "\(snapshot.displayName) is at \(percent)%",
                body: "\(label) is nearly spent. \(reset)",
                kind: .critical
            )
        }
        return UsageEvent(
            id: key,
            title: "\(snapshot.displayName) is at \(percent)%",
            body: "\(label) is \(percent)% through its limit.",
            kind: .warning
        )
    }

    /// Which newly-waiting sessions earn a ping. Same first-sight rule as
    /// usage: opening the app onto an already-waiting room is visible state,
    /// not a change. Sessions that resolve drop out of the fired set, so
    /// waiting again later pings again.
    func pendingSessionEvents(for sessions: [String: [AgentSession]]) -> [UsageEvent] {
        var events: [UsageEvent] = []
        var stillWaiting = Set<String>()
        for (providerID, list) in sessions {
            for session in list where session.state == .waiting {
                let key = "\(providerID)#\(session.id)"
                stillWaiting.insert(key)
                // Seen, whether or not it earns a ping: without marking first
                // sight here, the seeding pass would leave no trace and the
                // identical second pass would ping for old news.
                guard !waitingFired.contains(key) else { continue }
                waitingFired.insert(key)
                guard sessionsBaselined else { continue }
                let provider = names[providerID] ?? providerID
                events.append(UsageEvent(
                    id: "waiting#\(key)",
                    title: "\(session.name) is waiting on you",
                    body: "\(provider) — \(session.waitingFor ?? session.detail)",
                    kind: .waiting
                ))
            }
        }
        waitingFired.formIntersection(stillWaiting)
        sessionsBaselined = true
        return events
    }
}
