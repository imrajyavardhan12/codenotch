import AppKit
import SwiftUI
import XCTest
@testable import Codenotch

/// The history line: sampling cadence, retention, migration, and what the
/// tooltip draws. Samples are hourly points of the headline number; the store
/// records them on successful fetches and the archive keeps 48.
final class HistoryArchiveTests: XCTestCase {
    private func defaults() -> UserDefaults {
        let name = "HistoryArchiveTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private func reading(id: String = "claude", fraction: Double = 0.5) -> ProviderSnapshot {
        ProviderSnapshot(id: id, displayName: "Claude", glyph: .claude,
                         fidelity: .official, status: .ok,
                         windows: [LimitWindow(id: "session", label: "Current session",
                                               usedFraction: fraction)])
    }

    private let t0 = Date(timeIntervalSince1970: 1_787_900_000)

    private func seed(_ defaults: UserDefaults, id: String = "claude") {
        UsageArchive(defaults: defaults).save([id: (reading(id: id), t0)])
    }

    func testFirstSampleRecordsImmediately() {
        let defaults = defaults()
        seed(defaults)
        let history = UsageArchive(defaults: defaults)
            .recordSample(id: "claude", fraction: 0.5, at: t0)
        XCTAssertEqual(history, [UsageSample(fraction: 0.5, at: t0)])
    }

    /// The poll runs every minute while busy; sampling every one of those
    /// would make 48 points cover an afternoon rather than two days.
    func testSkipsSamplingWithinTheInterval() {
        let defaults = defaults()
        seed(defaults)
        let archive = UsageArchive(defaults: defaults)
        _ = archive.recordSample(id: "claude", fraction: 0.5, at: t0)
        let history = archive.recordSample(id: "claude", fraction: 0.6,
                                           at: t0.addingTimeInterval(30 * 60))
        XCTAssertEqual(history.count, 1, "a 30-minute-later fetch left a second point")
        XCTAssertEqual(archive.history(for: "claude").count, 1)
    }

    func testSamplesAfterTheInterval() {
        let defaults = defaults()
        seed(defaults)
        let archive = UsageArchive(defaults: defaults)
        _ = archive.recordSample(id: "claude", fraction: 0.5, at: t0)
        let history = archive.recordSample(id: "claude", fraction: 0.6,
                                           at: t0.addingTimeInterval(61 * 60))
        XCTAssertEqual(history.map(\.fraction), [0.5, 0.6])
    }

    /// Unknown ids are ignored, not conjured into shell entries that `load`
    /// would then surface as ghost providers.
    func testUnknownIDsAreIgnored() {
        let defaults = defaults()
        XCTAssertTrue(UsageArchive(defaults: defaults)
            .recordSample(id: "nope", fraction: 0.5, at: t0).isEmpty)
        XCTAssertTrue(UsageArchive(defaults: defaults).load().isEmpty)
    }

    func testTrimsToTheCapOldestFirst() {
        let defaults = defaults()
        seed(defaults)
        let archive = UsageArchive(defaults: defaults)
        for hour in 0..<55 {
            _ = archive.recordSample(id: "claude", fraction: Double(hour) / 100,
                                     at: t0.addingTimeInterval(Double(hour) * 3600))
        }
        let history = archive.history(for: "claude")
        XCTAssertEqual(history.count, UsageArchive.historyCap)
        // Hours 0–6 fell off; hour 7 is the oldest survivor.
        XCTAssertEqual(history.first?.fraction ?? -1, 0.07, accuracy: 0.0001)
        XCTAssertEqual(history.last?.fraction ?? -1, 0.54, accuracy: 0.0001)
    }

    /// Archives written before history existed carry no such key: they load
    /// with an empty past rather than failing the whole file.
    func testOldArchivesLoadWithEmptyHistory() {
        let defaults = defaults()
        let legacy = """
            [{"id": "claude", "displayName": "Claude", "glyph": "claude",
              "fidelity": "official",
              "windows": [{"id": "session", "label": "Current session",
                           "usedFraction": 0.5}],
              "fetchedAt": 1787900000}]
            """
        defaults.set(Data(legacy.utf8), forKey: "lastGoodReadings")
        let loaded = UsageArchive(defaults: defaults).load()
        XCTAssertEqual(loaded["claude"]?.snapshot.windows.count, 1)
        XCTAssertTrue(loaded["claude"]?.snapshot.history.isEmpty ?? false)
    }

    /// Saving fresh windows must not amputate the line: the readings carry new
    /// numbers but no past, and the past lives with the stored entry.
    func testSavePreservesHistory() {
        let defaults = defaults()
        seed(defaults)
        let archive = UsageArchive(defaults: defaults)
        _ = archive.recordSample(id: "claude", fraction: 0.5, at: t0)
        archive.save(["claude": (reading(fraction: 0.7), t0.addingTimeInterval(3600))])
        XCTAssertEqual(archive.history(for: "claude").map(\.fraction), [0.5])
    }

    /// Signing out or switching off takes the past with the numbers: the
    /// archive forgets the whole entry, history included.
    func testForgetDropsHistory() {
        let defaults = defaults()
        seed(defaults)
        let archive = UsageArchive(defaults: defaults)
        _ = archive.recordSample(id: "claude", fraction: 0.5, at: t0)
        archive.forget("claude")
        XCTAssertTrue(archive.history(for: "claude").isEmpty)
        XCTAssertTrue(archive.load().isEmpty)
    }
}

/// The store samples successful fetches and attaches what the archive holds —
/// including the just-taken sample — so the tooltip and the archive can never
/// disagree about the past.
@MainActor
final class HistoryStoreTests: XCTestCase {
    private final class Stub: UsageProvider, @unchecked Sendable {
        let id = "claude"
        let displayName = "Claude"
        let glyph = ProviderGlyph.claude
        func fetchSnapshot() async throws -> ProviderSnapshot {
            ProviderSnapshot(id: id, displayName: displayName, glyph: glyph,
                             fidelity: .official, status: .ok,
                             windows: [LimitWindow(id: "session", label: "Current session",
                                                   usedFraction: 0.5)])
        }
    }

    private func store() -> (UsageStore, UserDefaults) {
        let name = "HistoryStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return (UsageStore(providers: [Stub()], archive: UsageArchive(defaults: defaults)), defaults)
    }

    func testAFetchSamplesAndAttaches() async {
        let (store, _) = store()
        await store.refresh()
        XCTAssertEqual(store.snapshots.first?.history.count, 1)
        XCTAssertEqual(store.snapshots.first?.history.first?.fraction ?? -1, 0.5, accuracy: 0.0001)
        // An immediate second fetch is inside the interval: no second point.
        await store.refresh()
        XCTAssertEqual(store.snapshots.first?.history.count, 1)
    }

    /// The attached past survives a failed fetch through the degraded reading,
    /// dimmed like the number it belongs to.
    func testHistorySurvivesDegradation() async {
        final class Flaky: UsageProvider, @unchecked Sendable {
            let id = "flaky"
            let displayName = "Flaky"
            let glyph = ProviderGlyph.claude
            var fail = false
            func fetchSnapshot() async throws -> ProviderSnapshot {
                if fail { throw UsageProviderError.badResponse(status: 500) }
                return ProviderSnapshot(id: id, displayName: displayName, glyph: glyph,
                                        fidelity: .official, status: .ok,
                                        windows: [LimitWindow(id: "w", label: "W",
                                                              usedFraction: 0.5)])
            }
        }
        let name = "HistoryStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        let flaky = Flaky()
        let store = UsageStore(providers: [flaky], archive: UsageArchive(defaults: defaults))
        await store.refresh()
        XCTAssertEqual(store.snapshots.first?.history.count, 1)
        flaky.fail = true
        await store.refresh()
        XCTAssertEqual(store.snapshots.first?.history.count, 1,
                       "degrading to the last good reading dropped its past")
    }
}

/// The line draws at six samples and not before — and the budgets already
/// reserve its room, so its arrival moves nothing else.
@MainActor
final class HistoryRenderTests: XCTestCase {
    private func snapshot(sampleCount: Int) -> ProviderSnapshot {
        var snapshot = ProviderSnapshot(
            id: "claude", displayName: "Claude", glyph: .claude,
            fidelity: .official, status: .ok,
            windows: [LimitWindow(id: "session", label: "Session", usedFraction: 0.47)]
        )
        let base = Date(timeIntervalSince1970: 1_787_900_000)
        snapshot.history = (0..<sampleCount).map {
            UsageSample(fraction: 0.1 + 0.7 * Double($0) / Double(max(1, sampleCount - 1)),
                        at: base.addingTimeInterval(Double($0) * 3600))
        }
        return snapshot
    }

    private func render(_ snapshot: ProviderSnapshot) throws -> NSImage {
        let view = TooltipCard(snapshot: snapshot, now: Date())
            .padding(20)
            .background(Color.black)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.nsImage)
        if let path = ProcessInfo.processInfo.environment["HISTORY_RENDER_PATH"] {
            let tiff = try XCTUnwrap(image.tiffRepresentation)
            let png = try XCTUnwrap(NSBitmapImageRep(data: tiff)?
                .representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: path))
        }
        return image
    }

    func testFewSamplesDrawNoLine() throws {
        let bare = try render(snapshot(sampleCount: 0))
        let stub = try render(snapshot(sampleCount: 5))
        // Same height, to the point: below the threshold the card is exactly
        // what it always was, not approximately.
        XCTAssertEqual(stub.size.height, bare.size.height, accuracy: 1)
    }

    func testEnoughSamplesDrawTheLine() throws {
        let bare = try render(snapshot(sampleCount: 0))
        let lined = try render(snapshot(sampleCount: 8))
        XCTAssertGreaterThan(lined.size.height, bare.size.height + 10,
                             "eight samples should buy a visible history row")
    }
}
