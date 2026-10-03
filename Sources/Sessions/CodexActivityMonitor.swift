import AppKit
import Combine
import Foundation

/// Reports whether Codex is mid-turn.
///
/// Codex publishes no status field — no equivalent of Claude Code's `status` or
/// Cursor's `unfinishedRunAt`. What it does do is append to a thread's rollout
/// log continuously while a turn runs, so a rollout written moments ago means
/// work is happening now.
///
/// **That is a heuristic, and it is labelled as one.** It cannot tell a turn
/// that is thinking from one that finished a second ago, so it errs short: the
/// ring stops spinning `staleAfter` seconds after the last write rather than
/// claiming activity it cannot see. If Codex grows a real status field this
/// should be replaced by it.
@MainActor
final class CodexActivityMonitor: ObservableObject, AgentActivityMonitor {
    @Published private(set) var sessions: [AgentSession] = []
    var sessionsPublisher: AnyPublisher<[AgentSession], Never> { $sessions.eraseToAnyPublisher() }

    private let stateStore: URL
    private let desktopStore: URL
    private let interval: TimeInterval
    /// How long after the last write a turn is still considered in flight.
    private let staleAfter: TimeInterval
    private var timer: Timer?
    /// When the two stores last changed, and when they were last read in full.
    /// Opening two SQLite databases every two seconds to learn that nothing is
    /// happening is most of what this monitor costs; a `stat` of the files
    /// answers the same question for almost nothing.
    private var lastFingerprint: [Date?] = []
    private var lastFullRead = Date.distantPast
    /// A full read at least this often while idle, whatever the files say — the
    /// rollout is appended to without necessarily touching either database.
    private let idleFullReadEvery: TimeInterval = 10

    init(
        stateStore: URL = CodexStore.stateURL,
        desktopStore: URL = CodexStore.desktopStoreURL,
        interval: TimeInterval = 2,
        staleAfter: TimeInterval = 8
    ) {
        self.stateStore = stateStore
        self.desktopStore = desktopStore
        self.interval = interval
        self.staleAfter = staleAfter
    }

    func start() {
        rescan()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.rescan() }
        }
        timer.tolerance = interval / 2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func rescan() {
        let fingerprint = Self.fingerprint(stateStore: stateStore, desktopStore: desktopStore)
        let now = Date()
        // Idle, unchanged, and read recently: still idle. Anything showing as
        // working is always re-read, because it has to time out on its own.
        if sessions.isEmpty, fingerprint == lastFingerprint,
           now.timeIntervalSince(lastFullRead) < idleFullReadEvery {
            return
        }
        lastFingerprint = fingerprint
        lastFullRead = now
        let found = Self.read(stateStore: stateStore, desktopStore: desktopStore,
                              staleAfter: staleAfter)
        guard found != sessions else { return }
        sessions = found
    }

    /// Modification dates of both stores and their write-ahead logs, which is
    /// where the writes land while the owning app is running.
    static func fingerprint(stateStore: URL, desktopStore: URL) -> [Date?] {
        [stateStore, desktopStore].flatMap { url in
            [url.path, url.path + "-wal"].map {
                (try? FileManager.default.attributesOfItem(atPath: $0))?[.modificationDate] as? Date
            }
        }
    }

    static func read(stateStore: URL, desktopStore: URL,
                     staleAfter: TimeInterval, now: Date = Date()) -> [AgentSession] {
        // Both surfaces, because "Codex" is two programs that record their work
        // in different places: the CLI and the VS Code extension append to a
        // rollout, and the desktop app writes to its own catalogue. Whichever
        // moved last is the one that is working.
        var candidates: [(id: String, name: String, at: Date)] = []

        if let rollout = CodexStore.newestRollout(in: stateStore),
           let modified = (try? FileManager.default
               .attributesOfItem(atPath: rollout.path))?[.modificationDate] as? Date {
            candidates.append((id: "codex.\(rollout.lastPathComponent)",
                               name: "Codex", at: modified))
        }
        if let desktop = CodexStore.newestDesktopThread(in: desktopStore) {
            candidates.append((id: "codex.desktop", name: desktop.title,
                               at: desktop.updatedAt))
        }

        guard let newest = candidates.max(by: { $0.at < $1.at }),
              let session = session(id: newest.id, name: newest.name,
                                    modified: newest.at, staleAfter: staleAfter, now: now)
        else { return [] }
        return [session]
    }

    /// Only work recorded within the window counts. Anything older is a
    /// finished turn, and reporting it as work in progress would be a guess
    /// dressed as a fact.
    static func session(
        id: String, name: String, modified: Date, staleAfter: TimeInterval, now: Date
    ) -> AgentSession? {
        guard now.timeIntervalSince(modified) <= staleAfter else { return nil }
        return AgentSession(
            id: id,
            name: name,
            detail: "Working",
            state: .busy,
            waitingFor: nil,
            since: modified
        )
    }
}
