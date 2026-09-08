import XCTest
@testable import Codenotch

/// Guards the OpenCode Go adapter: the key file's shapes, the usage response's
/// shape, and the status mapping — especially the 403 fork, where a Cloudflare
/// block and a rejected key mean opposite things.
final class OpenCodeCredentialsTests: XCTestCase {
    private func file(_ contents: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("opencode-auth-\(UUID().uuidString).json")
        try! Data(contents.utf8).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// The shape `/connect` writes today.
    func testReadsTheGoKey() {
        let url = file(#"{"opencode-go": {"type": "api", "key": "sk-live-key"}}"#)
        XCTAssertEqual(OpenCodeCredentials.load(from: url), "sk-live-key")
    }

    /// A plain string worked in earlier builds and still does.
    func testAcceptsAPlainStringKey() {
        let url = file(#"{"opencode-go": "sk-plain-key"}"#)
        XCTAssertEqual(OpenCodeCredentials.load(from: url), "sk-plain-key")
    }

    /// A Zen OAuth login is a different product on a different endpoint:
    /// claiming it here would report the wrong account under Go's name.
    func testIgnoresOtherProviderIDs() {
        let url = file(#"{"opencode": {"type": "oauth", "access": "tok"}}"#)
        XCTAssertNil(OpenCodeCredentials.load(from: url))
    }

    func testMissingFileIsNil() {
        XCTAssertNil(OpenCodeCredentials.load(
            from: URL(fileURLWithPath: "/tmp/nope-\(UUID().uuidString).json")))
    }

    /// An empty key is worse than a missing one: it is a request that cannot
    /// succeed being sent all the same.
    func testAnEmptyKeyIsNil() {
        let url = file(#"{"opencode-go": {"type": "api", "key": ""}}"#)
        XCTAssertNil(OpenCodeCredentials.load(from: url))
    }
}

/// The recorded live shape of `GET /zen/go/v1/usage`.
final class OpenCodeUsageTests: XCTestCase {
    private let live = """
        {"usage": {"rolling": {"status": "ok", "percent": 2,
                               "resetsAt": "2026-09-08T06:55:06.584Z"},
                    "weekly":  {"status": "ok", "percent": 34,
                               "resetsAt": "2026-09-14T00:00:00.000Z"},
                    "monthly": {"status": "ok", "percent": 56,
                               "resetsAt": "2026-10-07T03:36:20.000Z"}}}
        """

    func testDecodesTheLiveShape() throws {
        let windows = try OpenCodeUsage.parse(Data(live.utf8)).windows
        XCTAssertEqual(windows.map(\.id), ["rolling", "weekly", "monthly"])
        XCTAssertEqual(windows.map(\.label), ["Rolling", "Weekly", "Monthly"])
        XCTAssertEqual(windows[0].usedFraction ?? -1, 0.02, accuracy: 0.0001)
        XCTAssertEqual(windows[2].usedFraction ?? -1, 0.56, accuracy: 0.0001)
        XCTAssertNotNil(windows[0].resetsAt)
    }

    /// The rolling window leads: like Claude's session, it is the one that
    /// bites first, so it is the ring's number.
    func testRollingSortsFirstWhateverOrderArrives() throws {
        let json = """
            {"usage": {"monthly": {"status": "ok", "percent": 56},
                        "rolling": {"status": "ok", "percent": 2}}}
            """
        XCTAssertEqual(try OpenCodeUsage.parse(Data(json.utf8)).windows.map(\.id),
                       ["rolling", "monthly"])
    }

    /// A window without a percent is dropped rather than guessed at — and a
    /// `status` other than ok never hides a percent that is there.
    func testWindowsWithoutAPercentAreDropped() throws {
        let json = """
            {"usage": {"rolling": {"status": "ok"},
                        "weekly": {"status": "limited", "percent": 34}}}
            """
        let windows = try OpenCodeUsage.parse(Data(json.utf8)).windows
        XCTAssertEqual(windows.map(\.id), ["weekly"])
    }

    /// A window the code does not know is ignored, not fatal: vendors add
    /// windows, and an unknown one must never take the known three down
    /// with it — nor sneak a mystery number onto the ring.
    func testUnknownWindowsAreIgnored() throws {
        let json = """
            {"usage": {"rolling": {"status": "ok", "percent": 2},
                        "daily": {"status": "ok", "percent": 99}}}
            """
        XCTAssertEqual(try OpenCodeUsage.parse(Data(json.utf8)).windows.map(\.id),
                       ["rolling"])
    }

    func testAnEmptyUsageThrows() {
        XCTAssertThrowsError(try OpenCodeUsage.parse(Data(#"{"usage": {}}"#.utf8)))
        XCTAssertThrowsError(try OpenCodeUsage.parse(Data(#"{}"#.utf8)))
        XCTAssertThrowsError(try OpenCodeUsage.parse(Data("not json".utf8)))
    }
}

/// The fetch path, behind a stubbed endpoint: headers, status mapping, and
/// the snapshot it builds. Mirrors `StubEndpoint`'s shape because each test
/// file stands alone here — sharing it would couple every adapter's tests to
/// one helper.
@MainActor
final class OpenCodeProviderTests: XCTestCase {
    private final class StubEndpoint: URLProtocol {
        struct Answer {
            let status: Int
            var body: Data = Data()
        }

        private static let lock = NSLock()
        private static var queued: [Answer] = []
        private static var requests: [URLRequest] = []

        static func reset(_ answers: [Answer]) {
            lock.lock(); queued = answers; requests = []; lock.unlock()
        }

        static var lastHeaders: [String: String]? {
            lock.lock(); defer { lock.unlock() }
            return requests.last?.allHTTPHeaderFields
        }

        static func session() -> URLSession {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [StubEndpoint.self]
            return URLSession(configuration: configuration)
        }

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            Self.lock.lock()
            Self.requests.append(request)
            let answer = Self.queued.isEmpty ? Answer(status: 500) : Self.queued.removeFirst()
            Self.lock.unlock()
            let response = HTTPURLResponse(url: request.url!,
                                           statusCode: answer.status,
                                           httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: answer.body)
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }

    private func keyFile(_ contents: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("opencode-auth-\(UUID().uuidString).json")
        try! Data(contents.utf8).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func provider(auth: String, session: URLSession? = nil) -> OpenCodeProvider {
        let name = "OpenCodeProviderTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return OpenCodeProvider(session: session ?? StubEndpoint.session(),
                                archive: UsageArchive(defaults: defaults),
                                authURL: keyFile(auth))
    }

    private let live = """
        {"usage": {"rolling": {"status": "ok", "percent": 52,
                               "resetsAt": "2026-09-08T06:55:06.584Z"},
                    "weekly": {"status": "ok", "percent": 17,
                               "resetsAt": "2026-09-14T00:00:00.000Z"}}}
        """

    func testIdentity() {
        let provider = provider(auth: #"{"opencode-go": "sk-x"}"#)
        XCTAssertEqual(provider.id, "opencode")
        XCTAssertEqual(provider.displayName, "OpenCode")
        XCTAssertEqual(provider.glyph, .opencode)
    }

    func testAFetchBuildsTheSnapshot() async throws {
        StubEndpoint.reset([.init(status: 200, body: Data(live.utf8))])
        let snapshot = try await provider(auth: #"{"opencode-go": "sk-x"}"#).fetchSnapshot()
        XCTAssertEqual(snapshot.headline?.id, "rolling")
        XCTAssertEqual(snapshot.headline?.usedFraction ?? -1, 0.52, accuracy: 0.0001)
        XCTAssertEqual(snapshot.fidelity, .official)
    }

    /// The whole point of the file: the key travels as a Bearer token, and
    /// the client introduces itself as a browser — Cloudflare 1010s anything
    /// that does not.
    func testSendsBearerAndABrowserUserAgent() async throws {
        StubEndpoint.reset([.init(status: 200, body: Data(live.utf8))])
        _ = try await provider(auth: #"{"opencode-go": "sk-secret"}"#).fetchSnapshot()
        let headers = try XCTUnwrap(StubEndpoint.lastHeaders)
        XCTAssertEqual(headers["Authorization"], "Bearer sk-secret")
        XCTAssertTrue(headers["User-Agent"]?.contains("Mozilla") ?? false,
                      "a bare URLSession signature gets Cloudflare-blocked")
    }

    func testMissingKeyNeedsAuth() async {
        let provider = provider(auth: #"{"something-else": "sk-x"}"#)
        do {
            _ = try await provider.fetchSnapshot()
            XCTFail("a missing key should need auth")
        } catch UsageProviderError.needsAuth {
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func testARejectedKeyNeedsAuth() async {
        StubEndpoint.reset([.init(status: 401)])
        do {
            _ = try await provider(auth: #"{"opencode-go": "sk-stale"}"#).fetchSnapshot()
            XCTFail("a 401 should need auth")
        } catch UsageProviderError.needsAuth {
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    /// The 403 fork: a Cloudflare block names itself in the body, and that is
    /// a network-shape failure — transient, last good reading stands — while a
    /// bare 403 is the key being rejected.
    func testACloudflareBlockIsNotASignOut() async {
        StubEndpoint.reset([.init(status: 403,
                                   body: Data("error code: 1010".utf8))])
        do {
            _ = try await provider(auth: #"{"opencode-go": "sk-x"}"#).fetchSnapshot()
            XCTFail("a block should surface, not vanish")
        } catch UsageProviderError.badResponse(let status) {
            XCTAssertEqual(status, 403)
            XCTAssertEqual(UsageStore.statusForTesting(UsageProviderError.badResponse(status: 403)),
                           .error("HTTP 403"))
        } catch {
            XCTFail("a Cloudflare block must not read as \(error)")
        }

        StubEndpoint.reset([.init(status: 403)])
        do {
            _ = try await provider(auth: #"{"opencode-go": "sk-x"}"#).fetchSnapshot()
            XCTFail("a bare 403 should need auth")
        } catch UsageProviderError.needsAuth {
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }
}
