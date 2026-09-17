import Foundation

/// The last good reading for each provider, remembered across launches.
///
/// Without this, a cold start that cannot reach the endpoint — rate limited,
/// offline, token expired — shows nothing at all, which is the least useful
/// thing the notch could do. A remembered reading is dimmed and dated, but a
/// dated number you can see beats a blank ring.
struct UsageArchive {
    private struct Entry: Codable {
        let id: String
        let displayName: String
        let glyph: ProviderGlyph
        let fidelity: Fidelity
        let windows: [LimitWindow]
        let fetchedAt: Date
        var history: [UsageSample]

        enum CodingKeys: String, CodingKey {
            case id, displayName, glyph, fidelity, windows, fetchedAt, history
        }

        init(id: String, displayName: String, glyph: ProviderGlyph, fidelity: Fidelity,
             windows: [LimitWindow], fetchedAt: Date, history: [UsageSample] = []) {
            self.id = id
            self.displayName = displayName
            self.glyph = glyph
            self.fidelity = fidelity
            self.windows = windows
            self.fetchedAt = fetchedAt
            self.history = history
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            displayName = try container.decode(String.self, forKey: .displayName)
            glyph = try container.decode(ProviderGlyph.self, forKey: .glyph)
            fidelity = try container.decode(Fidelity.self, forKey: .fidelity)
            windows = try container.decode([LimitWindow].self, forKey: .windows)
            fetchedAt = try container.decode(Date.self, forKey: .fetchedAt)
            // Archives written before history existed carry no such key: they
            // load with an empty past rather than failing the whole file —
            // losing every remembered reading over a missing array would be
            // the update punishing users for updating.
            history = try container.decodeIfPresent([UsageSample].self, forKey: .history) ?? []
        }
    }

    /// How often a successful fetch leaves a point behind. Hourly, nominally:
    /// the poll runs every minute while busy, and sampling every one of those
    /// would make 48 points cover an afternoon rather than two days.
    static let sampleInterval: TimeInterval = 55 * 60
    /// How many points survive. At the sampling interval this is about two
    /// days — the window the tooltip claims, so the store never grows.
    static let historyCap = 48

    private let defaults: UserDefaults
    private let key = "lastGoodReadings"
    private let backoffKey = "backoffUntil"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: - Back-off

    /// When the endpoint may next be called, remembered across launches.
    ///
    /// Without this, every relaunch starts with a clean slate and fires a
    /// request immediately — so a development loop of `make run` walks straight
    /// into the rate limit it is being punished by, and keeps the punishment
    /// alive. Which is exactly what happened.
    ///
    /// Kept per provider: the limit is per account, so a work profile being
    /// told to slow down says nothing about the personal one. The default
    /// profile keeps the key it always had, so a penalty in progress survives
    /// the update.
    func loadBackoffUntil(providerID: String = ClaudeProfile.defaultID) -> Date? {
        guard let date = defaults.object(forKey: backoffKey(for: providerID)) as? Date,
              date > Date() else {
            return nil
        }
        return date
    }

    func saveBackoffUntil(_ date: Date?, providerID: String = ClaudeProfile.defaultID) {
        let key = backoffKey(for: providerID)
        if let date {
            defaults.set(date, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    private func backoffKey(for providerID: String) -> String {
        providerID == ClaudeProfile.defaultID ? backoffKey : "\(backoffKey).\(providerID)"
    }

    private func loadEntries() -> [Entry] {
        guard let data = defaults.data(forKey: key),
              let entries = try? JSONDecoder().decode([Entry].self, from: data)
        else { return [] }
        return entries
    }

    private func saveEntries(_ entries: [Entry]) {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: key)
    }

    func load() -> [String: (snapshot: ProviderSnapshot, fetchedAt: Date)] {
        var result: [String: (snapshot: ProviderSnapshot, fetchedAt: Date)] = [:]
        for entry in loadEntries() {
            var snapshot = ProviderSnapshot(
                id: entry.id,
                displayName: entry.displayName,
                glyph: entry.glyph,
                fidelity: entry.fidelity,
                status: .stale(since: entry.fetchedAt),
                windows: entry.windows
            )
            snapshot.history = entry.history
            result[entry.id] = (snapshot, entry.fetchedAt)
        }
        return result
    }

    func save(_ readings: [String: (snapshot: ProviderSnapshot, fetchedAt: Date)]) {
        // Histories ride with their entries, not with the readings being
        // saved: the readings carry fresh windows but no past, and rebuilding
        // entries from them alone would amputate the line on every fetch.
        let histories = Dictionary(uniqueKeysWithValues: loadEntries().map { ($0.id, $0.history) })
        let entries = readings.values.map {
            Entry(
                id: $0.snapshot.id,
                displayName: $0.snapshot.displayName,
                glyph: $0.snapshot.glyph,
                fidelity: $0.snapshot.fidelity,
                windows: $0.snapshot.windows,
                fetchedAt: $0.fetchedAt,
                history: $0.snapshot.history.isEmpty
                    ? histories[$0.snapshot.id] ?? []
                    : $0.snapshot.history
            )
        }
        saveEntries(entries)
    }

    /// The past for one provider, oldest first. Empty for strangers and for
    /// readings that predate history altogether.
    func history(for providerID: String) -> [UsageSample] {
        loadEntries().first { $0.id == providerID }?.history ?? []
    }

    /// Leave a point behind a successful fetch. Due when there is no point
    /// yet, or the last one is about an interval old — the tolerance absorbs
    /// timer jitter so a 61-minute gap still samples once, not twice. Called
    /// after `save`, so the entry always exists; unknown ids are ignored
    /// rather than conjured into shell entries that `load` would then surface
    /// as ghost providers.
    @discardableResult
    func recordSample(id: String, fraction: Double, at: Date) -> [UsageSample] {
        var entries = loadEntries()
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return [] }
        var history = entries[index].history
        if let last = history.last,
           at.timeIntervalSince(last.at) < Self.sampleInterval {
            return history
        }
        history.append(UsageSample(fraction: fraction, at: at))
        history = Array(history.suffix(Self.historyCap))
        entries[index].history = history
        saveEntries(entries)
        return history
    }

    /// Drop what we remember about one provider.
    ///
    /// Signing out has to reach this, or the notch keeps showing the last
    /// reading — dimmed and dated, but still that account's numbers, still on
    /// screen after the next launch.
    func forget(_ providerID: String) {
        var readings = load()
        readings.removeValue(forKey: providerID)
        save(readings)
    }
}
