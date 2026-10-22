import Combine
import Foundation
import ServiceManagement
import os

/// Where the system's login item for this app stands.
enum LoginItemState: Equatable {
    case enabled
    /// Registered, then switched off by the user in System Settings → Login
    /// Items. macOS reports this as "requires approval". It is an answer, not
    /// a fault: re-registering over it would undo a choice that was made on
    /// purpose, in the one place the user is meant to make it.
    case disabledInSystemSettings
    /// No usable registration — never made, removed, or filed under a path
    /// that no longer exists.
    case notRegistered
}

/// The system's record of "open this app at login", behind a seam so the
/// logic around it can be tested without touching the real one — registering
/// from a test would put an entry in the tester's Login Items.
protocol LoginItemService {
    var state: LoginItemState { get }
    func register() throws
    func unregister() throws
}

extension LoginItemService {
    var isEnabled: Bool { state == .enabled }
}

struct SystemLoginItem: LoginItemService {
    var state: LoginItemState {
        switch SMAppService.mainApp.status {
        case .enabled:          return .enabled
        case .requiresApproval: return .disabledInSystemSettings
        default:                return .notRegistered
        }
    }
    func register() throws { try SMAppService.mainApp.register() }
    func unregister() throws { try SMAppService.mainApp.unregister() }
}

/// What the user has chosen, kept in `UserDefaults`.
@MainActor
final class Preferences: ObservableObject {
    /// Providers the user has switched off. Stored as the *disconnected* set
    /// rather than the connected one, so a provider added in a later version is
    /// on by default instead of silently staying dark.
    ///
    /// Switching one off is not merely hiding it: the store stops fetching it,
    /// so its credential is never read at all.
    @Published var disconnectedProviders: Set<String> {
        didSet { defaults.set(Array(disconnectedProviders), forKey: Keys.disconnected) }
    }

    /// Limits the user declares for tools Codenotch does not read natively.
    /// Stored as one JSON array beside every other preference; each entry
    /// keeps a stable id so archive readings, notification keys and the
    /// disconnected set survive renames.
    @Published var manualLimits: [ManualLimit] {
        didSet {
            if let data = try? JSONEncoder().encode(manualLimits) {
                defaults.set(data, forKey: Keys.manualLimits)
            }
        }
    }

    /// Whether limits and waiting agents may interrupt with a notification.
    /// On by default — this is an ambient monitor, and silence is its failure
    /// mode — but nothing is ever posted before macOS grants permission, which
    /// is asked for lazily on the first thing worth saying rather than up front.
    @Published var notificationsEnabled: Bool {
        didSet { defaults.set(notificationsEnabled, forKey: Keys.notifications) }
    }

    /// How much of itself the notch shows at rest.
    @Published var notchVisibility: NotchVisibility {
        didSet { defaults.set(notchVisibility.rawValue, forKey: Keys.visibility) }
    }

    /// Which screen edge the notch is welded to.
    @Published var notchEdge: NotchEdge {
        didSet { defaults.set(notchEdge.rawValue, forKey: Keys.edge) }
    }

    /// Where the app itself shows up: Dock, menu bar, or nowhere.
    @Published var appPresence: AppPresence {
        didSet { defaults.set(appPresence.rawValue, forKey: Keys.presence) }
    }

    /// The version whose changes have already been shown.
    ///
    /// Written when the What's New dialogue is dismissed rather than when it
    /// opens, so a crash in between cannot swallow the one launch it was going
    /// to appear on.
    @Published var lastSeenVersion: String? {
        didSet { defaults.set(lastSeenVersion, forKey: Keys.lastSeenVersion) }
    }

    @Published var launchAtLogin: Bool {
        didSet {
            // Compared with the previous value of the switch, not with the
            // system: a switch that is on while macOS says "requires approval"
            // must still be able to be turned off, and the system's answer for
            // that state is the same as for off.
            guard !updatingSwitchFromSystem, launchAtLogin != oldValue else { return }
            applyLaunchAtLogin()
        }
    }
    /// Set while the switch is being brought into line with the system, so that
    /// doing so is not mistaken for the user flipping it.
    private var updatingSwitchFromSystem = false

    /// Set when the login-item request was refused, so the UI can say so rather
    /// than quietly flipping the switch back.
    @Published private(set) var launchAtLoginProblem: String?

    private let defaults: UserDefaults
    private let loginItem: any LoginItemService
    /// Where the running copy is. A parameter so tests can be "installed".
    private let bundlePath: String
    private enum Keys {
        /// The copy the system's login item was registered from, set only while
        /// one is registered — see `reconcileLoginItem`.
        static let loginPath = "launchAtLoginPath"
        /// Set when a re-registration this app started did not complete, so
        /// the next launch finishes it instead of reading the gap it left as
        /// the user's choice.
        static let loginMendPending = "launchAtLoginMendPending"
        /// The old name. Kept so existing choices survive the rename.
        static let disconnected = "hiddenProviders"
        static let hasLaunched = "hasLaunchedBefore"
        static let visibility = "notchVisibility"
        static let presence = "appPresence"
        static let edge = "notchEdge"
        static let lastSeenVersion = "lastSeenVersion"
        static let notifications = "notificationsEnabled"
        static let manualLimits = "manualLimits"
    }

    /// True the very first time this copy runs, and never again.
    ///
    /// Deliberately *not* inferred from "there are no readings yet" — that is
    /// also true of someone who switched every provider off, and re-introducing
    /// them to the app every launch would be worse than never introducing them
    /// at all.
    let isFirstLaunch: Bool

    /// Bundle identifiers this app's settings lived under before, newest first.
    ///
    /// A bundle id is the name of the defaults domain, so renaming the app
    /// silently moved every setting to a new, empty one — connection choices,
    /// the notch's mode, the archived readings, all apparently lost. Copying
    /// the old domain across once is the difference between a rename and what
    /// looks like a reset. The fork's own rename heads the list, so an install
    /// that updates across it keeps its choices; older names follow for the
    /// same reason the original rename needed one.
    private static let previousDomains = ["com.vinz.codenotch", "com.vinz.usagenotch"]

    static func migrateFromPreviousName(into defaults: UserDefaults = .standard,
                                        from domain: String? = nil) {
        // The emptiness test has to be about the object being written to, not
        // about `Bundle.main` — under test those are different domains, and the
        // first version happily copied real settings into a test's scratch
        // suite. `hasLaunched` is the sentinel: `Preferences.init` sets it, so
        // its absence means nothing has ever used this domain.
        for candidate in domain.map({ [$0] }) ?? previousDomains {
            guard defaults.object(forKey: Keys.hasLaunched) == nil,
                  let old = defaults.persistentDomain(forName: candidate), !old.isEmpty
            else { continue }

            for (key, value) in old { defaults.set(value, forKey: key) }
            Log.usage.info("migrated \(old.count) settings from the previous app name")
            // Exactly one source: the newest domain with anything in it wins,
            // and older ones must not overwrite it key by key afterwards.
            break
        }
    }

    init(defaults: UserDefaults = .standard,
         loginItem: any LoginItemService = SystemLoginItem(),
         bundlePath: String = Bundle.main.bundlePath) {
        self.defaults = defaults
        self.loginItem = loginItem
        self.bundlePath = bundlePath
        self.isFirstLaunch = !defaults.bool(forKey: Keys.hasLaunched)
        defaults.set(true, forKey: Keys.hasLaunched)
        self.disconnectedProviders = Set(defaults.stringArray(forKey: Keys.disconnected) ?? [])
        // Absent means never chosen. On: an ambient monitor that never speaks
        // is a broken promise, and the system permission gate — not this
        // switch — is what keeps a fresh install quiet until something happens.
        self.notificationsEnabled = defaults.object(forKey: Keys.notifications) as? Bool ?? true
        // Absent means none declared. A corrupt array decodes to empty rather
        // than crashing the launch — declarations can be re-entered, readings
        // cannot be un-lost, and neither is worth a crash.
        if let data = defaults.data(forKey: Keys.manualLimits),
           let limits = try? JSONDecoder().decode([ManualLimit].self, from: data) {
            self.manualLimits = limits
        } else {
            self.manualLimits = []
        }
        // Absent means never chosen, which is the hover behaviour the app was
        // designed around — not hidden, which would make a fresh install look
        // like it failed to start.
        self.notchVisibility = defaults.string(forKey: Keys.visibility)
            .flatMap(NotchVisibility.init(rawValue:)) ?? .onHover
        // Absent means never chosen. The Dock is the default because it is the
        // findable one — a new user who cannot see the app anywhere has no way
        // to learn it is running.
        self.appPresence = defaults.string(forKey: Keys.presence)
            .flatMap(AppPresence.init(rawValue:)) ?? .dock
        // The right edge is where the notch has always been, and it is the one
        // side of a Mac that no system chrome claims by default.
        self.notchEdge = defaults.string(forKey: Keys.edge)
            .flatMap(NotchEdge.init(rawValue:)) ?? .right
        // Absent means nothing has been shown yet, which is true of a fresh
        // install — so the current release reads as new to it.
        self.lastSeenVersion = defaults.string(forKey: Keys.lastSeenVersion)
        // Read from the system rather than from our own store: the user can turn
        // this off in System Settings, and a remembered `true` would then be a lie.
        self.launchAtLogin = loginItem.isEnabled
        // One-time sweep for flags orphaned before removal cleared them:
        // a "manual-…" id with no matching declaration is litter from a
        // deleted custom limit, not a choice. Real provider ids are left
        // alone — only the manual prefix (see ManualProvider.isManual) is pruned.
        // Note the two id shapes: declarations are "abc", the disconnected
        // set holds provider ids ("manual-abc"). Runs here, after every
        // stored property is set, so it may read self freely.
        let declared = Set(self.manualLimits.map { "manual-" + $0.id })
        let pruned = self.disconnectedProviders.filter { id in
            guard id.hasPrefix("manual-") else { return true }
            return declared.contains(id)
        }
        if pruned != self.disconnectedProviders {
            self.disconnectedProviders = pruned
            // didSet does not fire inside init, so persist explicitly.
            defaults.set(Array(pruned), forKey: Keys.disconnected)
        }
    }

    func manualLimit(id: String) -> ManualLimit? {
        manualLimits.first { $0.id == id }
    }

    func addManualLimit(_ limit: ManualLimit) {
        manualLimits.append(limit)
    }

    func updateManualLimit(_ limit: ManualLimit) {
        guard let index = manualLimits.firstIndex(where: { $0.id == limit.id }) else { return }
        manualLimits[index] = limit
    }

    func removeManualLimit(id: String) {
        manualLimits.removeAll { $0.id == id }
        // The disconnected flag is a separate set holding the *provider* id
        // ("manual-abc", not "abc"): deleting the declaration without
        // clearing it leaves a stale entry that grows with every add/delete
        // cycle and outlives what it referred to.
        disconnectedProviders.remove("manual-" + id)
        disconnectedProviders.remove(id)
    }

    func isConnected(_ providerID: String) -> Bool {
        !disconnectedProviders.contains(providerID)
    }

    func setConnected(_ connected: Bool, for providerID: String) {
        if connected {
            disconnectedProviders.remove(providerID)
        } else {
            disconnectedProviders.insert(providerID)
        }
    }

    /// Forget everything this app has stored and quit.
    ///
    /// Deleting an app on macOS leaves `~/Library` untouched, so reinstalling
    /// brings back the old readings, the old connection choices and the old
    /// first-launch flag — which is exactly what makes a reinstall look broken.
    /// Nothing but the app itself can clean that up, so the app has to offer it.
    ///
    /// Not tied to uninstalling: a reinstall is indistinguishable from an
    /// update, and wiping data on every Sparkle update would be catastrophic.
    /// It has to be something the user asks for.
    static func eraseAllData() {
        let bundleID = Bundle.main.bundleIdentifier ?? "io.github.imrajyavardhan12.codenotch"
        UserDefaults.standard.removePersistentDomain(forName: bundleID)
        UserDefaults.standard.synchronize()

        let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
        for relative in ["Caches/\(bundleID)",
                         "WebKit/\(bundleID)",
                         "HTTPStorages/\(bundleID)",
                         "HTTPStorages/\(bundleID).binarycookies",
                         "Saved Application State/\(bundleID).savedState"] {
            if let url = library?.appendingPathComponent(relative) {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    // MARK: - Login item

    private static let refusedMessage = "macOS refused this — try moving Codenotch to /Applications."
    private static let approvalMessage = "Allow Codenotch in System Settings → General → Login Items."

    /// The path a copy is recorded and compared under: links resolved, so one
    /// copy reached two ways is still one copy.
    static func normalized(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// Whether this is an installed copy: directly inside /Applications or
    /// ~/Applications. Anything else — a build folder, a translocated download,
    /// an old copy filed away in a subfolder — is not the one to start at login.
    static func isInstalledLocation(_ path: String) -> Bool {
        let parent = URL(fileURLWithPath: normalized(path)).deletingLastPathComponent().path
        return parent == "/Applications" || parent == normalized(NSHomeDirectory() + "/Applications")
    }

    /// Keeps "open at login" pointing at the copy that is actually installed.
    ///
    /// macOS files a login item under the path the app had when it registered,
    /// not under its identity. Registered from a build folder and then
    /// reinstalled into /Applications, the entry kept pointing at the folder —
    /// and when that was cleaned out, nothing launched after the next restart,
    /// while the system still read "enabled". So the path a registration was
    /// made from is recorded, and when the installed copy is running from
    /// anywhere else, the registration is redone from it.
    ///
    /// The system is the authority on whether the user wants it: switched off
    /// or removed in System Settings is an answer, and is never overridden. The
    /// one exception is a re-registration this app began and did not finish,
    /// which is completed. An enabled item with no recorded path is the state a
    /// machine broken by the old behaviour is in — there is no API to read
    /// which path it points at — so it is redone once, at the cost of one
    /// "login item added" notice.
    func reconcileLoginItem() {
        guard Self.isInstalledLocation(bundlePath) else { return }
        let here = Self.normalized(bundlePath)

        switch loginItem.state {
        case .disabledInSystemSettings:
            // Still registered, from the recorded path, only switched off — so
            // switching it back on there needs nothing from here, and any mend
            // in progress has done what it can.
            defaults.removeObject(forKey: Keys.loginMendPending)
            showSwitch(false)
            return
        case .notRegistered:
            guard defaults.bool(forKey: Keys.loginMendPending) else {
                // Removed, or never added: either way, not wanted.
                defaults.removeObject(forKey: Keys.loginPath)
                showSwitch(false)
                return
            }
        case .enabled:
            if defaults.string(forKey: Keys.loginPath) == here { return }
        }

        let was = defaults.string(forKey: Keys.loginPath) ?? "unrecorded"
        Log.usage.notice("login item re-registered: was \(was, privacy: .public), now \(here, privacy: .public)")
        // Marked before the gap opens, so a failure between the two calls is
        // finished next launch rather than taken for the user's choice.
        defaults.set(true, forKey: Keys.loginMendPending)
        do {
            try loginItem.unregister()
        } catch {
            Log.usage.debug("login item unregister before re-register: \(error.localizedDescription, privacy: .public)")
        }
        register(from: here)
    }

    /// Registers the running copy and records it; shared by the mend and the
    /// switch so both say the same thing about the same outcome.
    private func register(from here: String) {
        do {
            try loginItem.register()
            defaults.removeObject(forKey: Keys.loginMendPending)
            defaults.set(here, forKey: Keys.loginPath)
            launchAtLoginProblem = loginItem.state == .disabledInSystemSettings ? Self.approvalMessage : nil
        } catch {
            Log.usage.error("login item register failed: \(error.localizedDescription, privacy: .public)")
            launchAtLoginProblem = Self.refusedMessage
        }
        showSwitch(loginItem.isEnabled)
    }

    /// Puts the switch in line with the system without it counting as a flip.
    func showSwitch(_ on: Bool) {
        updatingSwitchFromSystem = true
        launchAtLogin = on
        updatingSwitchFromSystem = false
    }

    private func applyLaunchAtLogin() {
        // Registering or removing moves the system's single entry for this app
        // to whichever copy asks, so a build-folder copy — which shares these
        // settings — must not ask in either direction.
        guard Self.isInstalledLocation(bundlePath) else {
            launchAtLoginProblem = "Only the copy in /Applications can change this."
            showSwitch(loginItem.isEnabled)
            return
        }
        let here = Self.normalized(bundlePath)
        if launchAtLogin {
            register(from: here)
            return
        }
        do {
            try loginItem.unregister()
        } catch {
            // Usual when it was already off in System Settings: nothing to
            // remove. Only a refusal that leaves it running is a problem.
            Log.usage.error("launch at login off failed: \(error.localizedDescription, privacy: .public)")
        }
        if loginItem.isEnabled {
            launchAtLoginProblem = "macOS refused this — switch it off in System Settings → Login Items."
            showSwitch(true)
        } else {
            launchAtLoginProblem = nil
            defaults.removeObject(forKey: Keys.loginMendPending)
            defaults.removeObject(forKey: Keys.loginPath)
        }
    }
}
