import XCTest
@testable import Codenotch

/// macOS files a login item under the path the app had when it registered.
/// A copy reinstalled elsewhere — or the build folder the first registration
/// came from being cleaned — left "Open at login" switched on in Settings and
/// launching nothing after a restart. These pin the mending, and what it must
/// never do: act from a build folder, override System Settings, or re-register
/// something already right.
@MainActor
final class LoginItemTests: XCTestCase {
    private final class FakeLoginItem: LoginItemService {
        var state: LoginItemState
        var registers = 0, unregisters = 0
        var refuses = false
        var refusesUnregister = false
        /// What registering leaves behind: an item the user has not approved
        /// comes back "requires approval" rather than "enabled".
        var registerLandsAs: LoginItemState = .enabled
        init(_ state: LoginItemState) { self.state = state }
        func register() throws {
            registers += 1
            if refuses { throw NSError(domain: "test", code: 1) }
            state = registerLandsAs
        }
        func unregister() throws {
            unregisters += 1
            if refusesUnregister { throw NSError(domain: "test", code: 2) }
            state = .notRegistered
        }
    }

    private let installed = "/Applications/Codenotch.app"
    private let buildFolder = "/Users/x/Library/Developer/Xcode/DerivedData/Codenotch-abc/Build/Products/Debug/Codenotch.app"

    private func defaults(path: String? = nil, mendPending: Bool = false) -> UserDefaults {
        let name = "LoginItemTests.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        addTeardownBlock { d.removePersistentDomain(forName: name) }
        if let path { d.set(path, forKey: "launchAtLoginPath") }
        if mendPending { d.set(true, forKey: "launchAtLoginMendPending") }
        return d
    }

    private func preferences(_ d: UserDefaults, _ item: FakeLoginItem,
                             at path: String? = nil) -> Preferences {
        Preferences(defaults: d, loginItem: item, bundlePath: path ?? installed)
    }

    // MARK: Mending

    /// The reported case: registered from somewhere that is gone.
    func testARegistrationFromAnotherPathIsRedoneFromTheInstalledCopy() {
        let d = defaults(path: buildFolder)
        let item = FakeLoginItem(.enabled)
        let p = preferences(d, item)

        p.reconcileLoginItem()

        XCTAssertEqual(item.registers, 1)
        XCTAssertEqual(item.unregisters, 1, "the stale entry has to go first")
        XCTAssertEqual(d.string(forKey: "launchAtLoginPath"), installed)
        XCTAssertTrue(p.launchAtLogin)
    }

    func testARegistrationFromThisCopyIsLeftAlone() {
        let d = defaults(path: installed)
        let item = FakeLoginItem(.enabled)
        preferences(d, item).reconcileLoginItem()

        XCTAssertEqual(item.registers + item.unregisters, 0,
                       "re-registering on every launch would re-announce the login item each time")
    }

    /// A machine already in the broken state: enabled, nothing recorded.
    func testAnEnabledItemWithNoRecordedPathIsMendedOnce() {
        let d = defaults()
        let item = FakeLoginItem(.enabled)
        let p = preferences(d, item)

        p.reconcileLoginItem()
        p.reconcileLoginItem()

        XCTAssertEqual(item.registers, 1, "the second launch must find it already right")
    }

    /// A re-registration that broke between its two calls is finished, not
    /// mistaken for the user having removed the item.
    func testAMendThatFailedHalfwayIsFinishedNextLaunch() {
        let d = defaults(path: buildFolder)
        let item = FakeLoginItem(.enabled)
        item.refuses = true
        preferences(d, item).reconcileLoginItem()
        XCTAssertEqual(item.state, .notRegistered)

        item.refuses = false
        preferences(d, item).reconcileLoginItem()

        XCTAssertEqual(item.state, .enabled)
        XCTAssertEqual(d.string(forKey: "launchAtLoginPath"), installed)
    }

    /// The mend can land "requires approval" too; the user has to be told why
    /// the switch they had on now reads off.
    func testAMendThatNeedsApprovalSaysSo() {
        let d = defaults(path: buildFolder)
        let item = FakeLoginItem(.enabled)
        item.registerLandsAs = .disabledInSystemSettings
        let p = preferences(d, item)

        p.reconcileLoginItem()

        XCTAssertFalse(p.launchAtLogin)
        XCTAssertNotNil(p.launchAtLoginProblem)
    }

    // MARK: What it must not do

    /// `make run` next to `make install`: the build-folder copy must not take
    /// the login item from the installed one.
    func testACopyRunFromABuildFolderNeverTouchesTheLoginItem() {
        let d = defaults(path: installed)
        let item = FakeLoginItem(.enabled)
        preferences(d, item, at: buildFolder).reconcileLoginItem()

        XCTAssertEqual(item.registers + item.unregisters, 0)
        XCTAssertEqual(d.string(forKey: "launchAtLoginPath"), installed)
    }

    /// …nor by the switch, in either direction: registering or removing moves
    /// the system's single entry to whoever asks, and the copies share settings.
    func testTheSwitchDoesNothingFromABuildFolderAndSaysWhy() {
        let d = defaults(path: installed, mendPending: true)
        let item = FakeLoginItem(.enabled)
        let p = preferences(d, item, at: buildFolder)

        p.launchAtLogin = false
        p.launchAtLogin = true

        XCTAssertEqual(item.registers + item.unregisters, 0)
        XCTAssertNotNil(p.launchAtLoginProblem)
        XCTAssertEqual(d.string(forKey: "launchAtLoginPath"), installed)
        XCTAssertTrue(d.bool(forKey: "launchAtLoginMendPending"),
                      "a refused flip must not cancel the installed copy's unfinished mend")
    }

    func testOnlyCopiesDirectlyInAnApplicationsFolderCount() {
        XCTAssertTrue(Preferences.isInstalledLocation("/Applications/Codenotch.app"))
        XCTAssertTrue(Preferences.isInstalledLocation(NSHomeDirectory() + "/Applications/Codenotch.app"))
        XCTAssertFalse(Preferences.isInstalledLocation(buildFolder))
        XCTAssertFalse(Preferences.isInstalledLocation(
            "/private/var/folders/ab/xyz/T/AppTranslocation/1234/d/Codenotch.app"))
        XCTAssertFalse(Preferences.isInstalledLocation("/Applications/Old/Codenotch.app"),
                       "an old copy filed away must not take the login item back")
    }

    /// Switched off in System Settings is an answer.
    func testSwitchedOffInSystemSettingsIsRespected() {
        let d = defaults(path: installed)
        let item = FakeLoginItem(.disabledInSystemSettings)
        let p = preferences(d, item)

        p.reconcileLoginItem()
        p.reconcileLoginItem()

        XCTAssertEqual(item.registers + item.unregisters, 0)
        XCTAssertFalse(p.launchAtLogin)
    }

    /// …and switching it back on there is then a no-op here, not a
    /// re-registration, while mending stays armed for the next reinstall.
    func testSwitchedBackOnInSystemSettingsNeedsNothingAndStaysMendable() {
        let d = defaults(path: installed)
        let item = FakeLoginItem(.disabledInSystemSettings)
        preferences(d, item).reconcileLoginItem()

        item.state = .enabled
        let p = preferences(d, item)
        p.reconcileLoginItem()
        XCTAssertEqual(item.registers, 0)
        XCTAssertTrue(p.launchAtLogin)

        preferences(d, item, at: NSHomeDirectory() + "/Applications/Codenotch.app").reconcileLoginItem()
        XCTAssertEqual(item.registers, 1, "a later reinstall elsewhere is still mended")
    }

    /// Removed with "−" in System Settings leaves nothing registered. It is not
    /// put back.
    func testRemovedInSystemSettingsIsNotPutBack() {
        let d = defaults(path: installed)
        let item = FakeLoginItem(.notRegistered)
        let p = preferences(d, item)

        p.reconcileLoginItem()

        XCTAssertEqual(item.registers, 0)
        XCTAssertNil(d.string(forKey: "launchAtLoginPath"))
        XCTAssertFalse(p.launchAtLogin)
    }

    /// A mend left pending while the item sat switched off must not later
    /// override the user removing it.
    func testAPendingMendDoesNotOutliveAnAnswerInSystemSettings() {
        let d = defaults(path: installed, mendPending: true)
        let item = FakeLoginItem(.disabledInSystemSettings)
        preferences(d, item).reconcileLoginItem()

        item.state = .notRegistered   // then removed with "−"
        preferences(d, item).reconcileLoginItem()

        XCTAssertEqual(item.registers, 0)
    }

    func testSomeoneWhoNeverWantedItIsNotSignedUp() {
        let d = defaults()
        let item = FakeLoginItem(.notRegistered)
        preferences(d, item).reconcileLoginItem()
        XCTAssertEqual(item.registers + item.unregisters, 0)
    }

    // MARK: The switch

    func testTurningItOnRecordsWhereFrom() {
        let d = defaults()
        let item = FakeLoginItem(.notRegistered)
        preferences(d, item).launchAtLogin = true

        XCTAssertEqual(d.string(forKey: "launchAtLoginPath"), installed)
    }

    func testTurningItOffForgetsWhereFrom() {
        let d = defaults(path: installed)
        let item = FakeLoginItem(.enabled)
        let p = preferences(d, item)

        p.launchAtLogin = false

        XCTAssertEqual(item.state, .notRegistered)
        XCTAssertNil(d.string(forKey: "launchAtLoginPath"))
    }

    /// The switch can read on while macOS awaits approval; turning it off then
    /// has to stick, and the stale "allow it" message has to go.
    func testTurningOffWhileAwaitingApprovalSticksAndClearsTheMessage() {
        let d = defaults()
        let item = FakeLoginItem(.notRegistered)
        item.registerLandsAs = .disabledInSystemSettings
        let p = preferences(d, item)
        p.launchAtLogin = true
        XCTAssertNotNil(p.launchAtLoginProblem, "the user should be told to approve it")

        p.showSwitch(true)
        p.launchAtLogin = false

        XCTAssertNil(p.launchAtLoginProblem)
        XCTAssertNil(d.string(forKey: "launchAtLoginPath"))
    }

    /// Refused off while it keeps running: the switch says on, and the path is
    /// left as it was rather than rewritten.
    func testARefusedOffKeepsTheSwitchHonest() {
        let d = defaults(path: installed)
        let item = FakeLoginItem(.enabled)
        item.refusesUnregister = true
        let p = preferences(d, item)

        p.launchAtLogin = false

        XCTAssertTrue(p.launchAtLogin)
        XCTAssertNotNil(p.launchAtLoginProblem)
        XCTAssertEqual(d.string(forKey: "launchAtLoginPath"), installed)
    }

    func testARefusedMendIsSaidAndTheSwitchTellsTheTruth() {
        let d = defaults(path: buildFolder)
        let item = FakeLoginItem(.enabled)
        item.refuses = true
        let p = preferences(d, item)

        p.reconcileLoginItem()

        XCTAssertNotNil(p.launchAtLoginProblem)
        XCTAssertFalse(p.launchAtLogin, "the switch should not claim it is on")
        XCTAssertEqual(item.registers, 1, "a refusal must not trigger a second attempt via the switch")
    }
}
