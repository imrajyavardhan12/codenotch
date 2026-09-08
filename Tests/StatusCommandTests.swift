import XCTest
@testable import Codenotch

/// The `codenotch status` surface: argument parsing and the JSON report. Pure
/// throughout — entries are injected, `now` is injected — so nothing here
/// touches UserDefaults, the keychain, or the network.
final class StatusCommandTests: XCTestCase {
    private func snapshot(id: String = "claude", name: String = "Claude",
                          fraction: Double? = 0.52, fidelity: Fidelity = .official,
                          remaining: Int? = nil, headlineID: String = "session") -> ProviderSnapshot {
        var windows: [LimitWindow] = []
        if let fraction {
            windows.append(LimitWindow(id: "session", label: "Current session",
                                       usedFraction: fraction))
        } else if let remaining {
            windows.append(LimitWindow(id: "pro", label: "Pro searches",
                                       remaining: remaining))
        }
        return ProviderSnapshot(id: id, displayName: name, glyph: .claude,
                                fidelity: fidelity, status: .ok,
                                windows: windows, headlineID: headlineID)
    }

    private func entries(_ snapshots: [ProviderSnapshot],
                         fetchedAt: Date = Date(timeIntervalSince1970: 1_787_900_000)) -> [
        (snapshot: ProviderSnapshot, fetchedAt: Date)
    ] {
        snapshots.map { (snapshot: $0, fetchedAt: fetchedAt) }
    }

    private func decoded(_ json: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }

    private func providers(_ json: String) throws -> [[String: Any]] {
        try XCTUnwrap(try decoded(json)["providers"] as? [[String: Any]])
    }

    // MARK: - Report

    func testBareInvocationPrintsCompactJSON() throws {
        let result = StatusCommand.run(arguments: [],
                                       entries: entries([snapshot()]),
                                       now: Date(timeIntervalSince1970: 1_787_900_037))
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.stderr.isEmpty)
        XCTAssertFalse(result.stdout.contains("\n"), "default output should be one pipeable line")
        let first = try XCTUnwrap(try providers(result.stdout).first)
        XCTAssertEqual(first["id"] as? String, "claude")
        XCTAssertEqual(first["displayName"] as? String, "Claude")
        XCTAssertEqual(first["glyph"] as? String, "claude")
        XCTAssertEqual(first["fidelity"] as? String, "official")
        XCTAssertEqual(first["display"] as? String, "52%")
        XCTAssertEqual(first["percentUsed"] as? Int, 52)
        XCTAssertEqual(first["ageSeconds"] as? Int, 37)
        XCTAssertNotNil(first["fetchedAt"])
        XCTAssertNotNil(first["windows"])
    }

    func testPrettyIndentsForHumans() {
        let result = StatusCommand.run(arguments: ["--pretty"],
                                       entries: entries([snapshot()]))
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.stdout.contains("\n"))
    }

    /// The subcommand composes with flags rather than competing with them.
    func testStatusComposesWithFlags() {
        let result = StatusCommand.run(arguments: ["status", "--pretty"],
                                       entries: entries([snapshot()]))
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.stdout.contains("\n"))
    }

    func testAnExplicitStatusSubcommandBehavesTheSame() {
        let plain = StatusCommand.run(arguments: [], entries: entries([snapshot()]))
        let explicit = StatusCommand.run(arguments: ["status"], entries: entries([snapshot()]))
        XCTAssertEqual(plain.stdout, explicit.stdout)
    }

    /// A guess arrives wearing its "~" rather than masquerading as a vendor's.
    func testDerivedReadingsKeepTheirQualifier() throws {
        let result = StatusCommand.run(
            arguments: [],
            entries: entries([snapshot(fraction: 0.73, fidelity: .derived)]))
        let first = try XCTUnwrap(try providers(result.stdout).first)
        XCTAssertEqual(first["display"] as? String, "~73%")
        XCTAssertEqual(first["fidelity"] as? String, "derived")
    }

    func testCountBasedReadingsRenderAsCounts() throws {
        let result = StatusCommand.run(
            arguments: [],
            entries: entries([snapshot(fraction: nil, remaining: 2, headlineID: "pro")]))
        // A provider that counts down ships the ring's own number, not a dash
        // and not an invented percentage. Bare, like the ring itself — the
        // headlineLabel beside it says what the number counts.
        let first = try XCTUnwrap(try providers(result.stdout).first)
        XCTAssertNil(first["percentUsed"] as? Int)
        XCTAssertEqual(first["display"] as? String, "2")
    }

    /// Empty is a valid answer, not an error — but it says why on stderr,
    /// where it cannot corrupt a pipe.
    func testAnEmptyArchiveExplainsItself() throws {
        let result = StatusCommand.run(arguments: [], entries: [])
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(try providers(result.stdout).count, 0)
        XCTAssertTrue(result.stderr.contains("launch Codenotch once"))
    }

    /// The archive is keyed, so its order is meaningless: scripts and
    /// screenshots get a stable listing regardless.
    func testProvidersSortByID() throws {
        let result = StatusCommand.run(
            arguments: [],
            entries: entries([snapshot(id: "cursor", name: "Cursor"),
                              snapshot(id: "claude")]))
        let ids = try providers(result.stdout).compactMap { $0["id"] as? String }
        XCTAssertEqual(ids, ["claude", "cursor"])
    }

    // MARK: - Filtering

    func testProviderFilter() throws {
        let result = StatusCommand.run(
            arguments: ["--provider", "cursor"],
            entries: entries([snapshot(id: "claude"), snapshot(id: "cursor", name: "Cursor")]))
        XCTAssertEqual(result.exitCode, 0)
        let ids = try providers(result.stdout).compactMap { $0["id"] as? String }
        XCTAssertEqual(ids, ["cursor"])
    }

    /// An empty `--provider=` is a caller error, not an empty filter: it
    /// names nothing, so it matches nothing, and failing loudly beats
    /// printing an empty list that looks like an outage.
    func testAnEmptyProviderValueFails() {
        let result = StatusCommand.run(arguments: ["--provider="],
                                       entries: entries([snapshot()]))
        XCTAssertEqual(result.exitCode, 2)
        XCTAssertTrue(result.stdout.isEmpty)
    }

    func testProviderEqualsForm() throws {
        let result = StatusCommand.run(arguments: ["--provider=cursor"],
                                       entries: entries([snapshot(id: "cursor")]))
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(try providers(result.stdout).count, 1)
    }

    /// An unknown filter is a caller error: non-zero, naming the id and what
    /// exists, so a renamed provider shows up as a typo rather than silence.
    func testUnknownProviderFailsLoudly() {
        let result = StatusCommand.run(arguments: ["--provider", "copilot"],
                                       entries: entries([snapshot()]))
        XCTAssertEqual(result.exitCode, 2)
        XCTAssertTrue(result.stderr.contains("copilot"))
        XCTAssertTrue(result.stderr.contains("claude"))
        XCTAssertTrue(result.stdout.isEmpty)
    }

    // MARK: - Usage errors

    func testHelpExitsZero() {
        let result = StatusCommand.run(arguments: ["--help"], entries: [])
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.stdout.contains("usage:"))
        XCTAssertTrue(result.stderr.isEmpty)
    }

    func testUnknownFlagsFailWithUsage() {
        let result = StatusCommand.run(arguments: ["--watch"], entries: entries([snapshot()]))
        XCTAssertEqual(result.exitCode, 2)
        XCTAssertTrue(result.stderr.contains("--watch"))
        XCTAssertTrue(result.stderr.contains("usage:"))
        XCTAssertTrue(result.stdout.isEmpty)
    }

    func testAFlagWithoutItsValueFails() {
        let result = StatusCommand.run(arguments: ["--provider"], entries: [])
        XCTAssertEqual(result.exitCode, 2)
        XCTAssertTrue(result.stderr.contains("--provider"))
    }
}
