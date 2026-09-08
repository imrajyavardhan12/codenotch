import Foundation
import os

/// Reads OpenCode Go usage from the plan's own endpoint, with the API key the
/// CLI's `/connect` sign-in already holds — see `OpenCodeCredentials`.
///
/// The numbers are OpenCode's, so this is `.official`. The endpoint is not a
/// published API — it was found by asking the site with the tool's own key —
/// and it sits behind Cloudflare, so like every adapter here, every failure
/// degrades to a status the UI can render honestly rather than to a guess.
actor OpenCodeProvider: UsageProvider {
    nonisolated let id = "opencode"
    nonisolated let displayName = "OpenCode"
    nonisolated let glyph = ProviderGlyph.opencode

    private let endpoint = URL(string: "https://opencode.ai/zen/go/v1/usage")!
    private let session: URLSession
    private let archive: UsageArchive
    private let authURL: URL?
    /// Set when the endpoint returns 429. Until it passes, refreshes are
    /// skipped without touching the network — the same bargain Claude's and
    /// GLM's make with theirs.
    private var retryNoEarlierThan: Date?
    private var consecutiveRateLimits = 0

    /// `nil` means "no source", which reads as signed out. A test points this
    /// at a fixture (or nowhere); production reads the tool's own file.
    init(session: URLSession = .shared,
         archive: UsageArchive = UsageArchive(),
         authURL: URL? = OpenCodeCredentials.authURL) {
        self.session = session
        self.archive = archive
        self.authURL = authURL
        self.retryNoEarlierThan = archive.loadBackoffUntil(providerID: id)
    }

    nonisolated var signInRoute: SignInRoute {
        .guidance("Connect the subscription inside opencode with /connect — "
                  + "Codenotch reads the key that saves.")
    }

    nonisolated func forgetCachedCredential() {
        // Nothing is cached: the key is re-read from disk on every fetch,
        // which is prompt-free, unlike a keychain read.
    }

    nonisolated func account() -> ProviderAccount? {
        guard let url = authURL, OpenCodeCredentials.load(from: url) != nil else { return nil }
        return ProviderAccount(
            label: nil,   // the key file carries no address
            plan: "Go",   // the only subscription this endpoint meters
            source: "OpenCode",
            manageURL: URL(string: "https://opencode.ai")
        )
    }

    func fetchSnapshot() async throws -> ProviderSnapshot {
        if let retryNoEarlierThan, retryNoEarlierThan > Date() {
            let remaining = retryNoEarlierThan.timeIntervalSinceNow
            Log.usage.debug("skipping fetch, backing off for \(remaining, format: .fixed(precision: 0))s")
            throw UsageProviderError.rateLimited(retryAfter: remaining)
        }

        // Re-read on every fetch. An ordinary file, not a keychain item:
        // reading it puts no prompt in front of anyone.
        guard let url = authURL, let key = OpenCodeCredentials.load(from: url) else {
            throw UsageProviderError.needsAuth
        }

        do {
            let data = try await fetch(key: key)
            let payload = try OpenCodeUsage.parse(data)

            consecutiveRateLimits = 0
            retryNoEarlierThan = nil
            archive.saveBackoffUntil(nil, providerID: id)

            return ProviderSnapshot(
                id: id,
                displayName: displayName,
                glyph: glyph,
                fidelity: .official,
                status: .ok,
                windows: payload.windows,
                headlineID: "rolling"
            )
        } catch UsageProviderError.rateLimited(let retryAfter) {
            consecutiveRateLimits += 1
            retryNoEarlierThan = Date().addingTimeInterval(retryAfter)
            archive.saveBackoffUntil(retryNoEarlierThan, providerID: id)
            Log.usage.notice("opencode: rate limited (\(self.consecutiveRateLimits)x), next attempt in \(retryAfter, format: .fixed(precision: 0))s")
            throw UsageProviderError.rateLimited(retryAfter: retryAfter)
        }
    }

    private func fetch(key: String) async throws -> Data {
        var request = URLRequest(url: endpoint)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // Browser-shaped, on purpose: Cloudflare answers a bare client (stock
        // URLSession, curl, urllib) with 1010 Access Denied before the request
        // ever reaches the endpoint. Verified live — without this, every poll
        // reads as a failure.
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
                + "AppleWebKit/537.36 (KHTML, like Gecko) "
                + "Chrome/126.0.0.0 Safari/537.36",
            forHTTPHeaderField: "User-Agent"
        )
        request.timeoutInterval = 15

        Log.usage.debug("GET opencode.ai/zen/go/v1/usage")
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        Log.usage.debug("usage endpoint answered \(status)")

        if status == 401 { throw UsageProviderError.needsAuth }
        if status == 403 {
            // Two different refusals share this code, and they mean opposite
            // things. A Cloudflare block names itself in the body — that is a
            // network-shape failure, transient, and the last good reading
            // stands. Anything else is the key being rejected: signed out.
            let body = String(data: data, encoding: .utf8)?.lowercased() ?? ""
            if body.contains("1010") || body.contains("cloudflare") {
                throw UsageProviderError.badResponse(status: status)
            }
            throw UsageProviderError.needsAuth
        }
        if status == 429 {
            throw UsageProviderError.rateLimited(
                retryAfter: Self.backoff(
                    forAttempt: consecutiveRateLimits,
                    retryAfter: Self.retryAfter(from: response)
                )
            )
        }
        guard (200..<300).contains(status) else {
            throw UsageProviderError.badResponse(status: status)
        }
        return data
    }

    /// How long to wait after a 429 — a minute, doubling per consecutive
    /// limit, capped so it always recovers on its own. The server's own hint
    /// is honoured only as a floor-raiser, for the reason Claude's records.
    static func backoff(forAttempt attempt: Int, retryAfter: TimeInterval?) -> TimeInterval {
        let floor: TimeInterval = 60
        let ceiling: TimeInterval = 15 * 60
        let doubled = floor * pow(2, Double(min(attempt, 4)))
        return min(ceiling, max(doubled, retryAfter ?? 0))
    }

    /// `Retry-After` is either a number of seconds or an HTTP date.
    static func retryAfter(from response: URLResponse?) -> TimeInterval? {
        guard let header = (response as? HTTPURLResponse)?
            .value(forHTTPHeaderField: "Retry-After")?
            .trimmingCharacters(in: .whitespaces)
        else { return nil }

        if let seconds = TimeInterval(header) { return max(0, seconds) }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = formatter.date(from: header) else { return nil }
        return max(0, date.timeIntervalSinceNow)
    }
}
