import XCTest
@testable import Codenotch

/// What `/usr/bin/security`'s answer means. Running the tool needs a real
/// keychain, so the mapping from its exit status and output is tested apart.
final class SecurityToolTests: XCTestCase {

    func testAJSONSecretComesBackWithoutItsTrailingNewline() {
        let json = #"{"claudeAiOauth":{"accessToken":"t","expiresAt":1}}"#
        XCTAssertEqual(SecurityTool.outcome(status: 0, output: Data((json + "\n").utf8)),
                       .secret(Data(json.utf8)))
    }

    func testExit44MeansTheItemIsGone() {
        XCTAssertEqual(SecurityTool.outcome(status: 44, output: Data()), .notFound)
    }

    /// Anything else says nothing about the item, so the caller may fall back.
    func testOtherFailuresAreNotMistakenForSignedOut() {
        XCTAssertEqual(SecurityTool.outcome(status: 1, output: Data()), .failed)
        XCTAssertEqual(SecurityTool.outcome(status: 0, output: Data("\n".utf8)), .failed)
    }

    /// `-w` prints a non-text secret as hex.
    func testAHexPrintedSecretIsDecoded() {
        XCTAssertEqual(SecurityTool.outcome(status: 0, output: Data("7b7d0a".utf8)),
                       .secret(Data("{}\n".utf8)))
    }

    /// Neither owner's real payload may be mistaken for hex.
    func testRealPayloadsAreNotHexDecoded() {
        XCTAssertNil(SecurityTool.unhexed(Data(#"{"a":1}"#.utf8)))
        XCTAssertNil(SecurityTool.unhexed(Data("go-keyring-base64:eyJhIjoxfQ==".utf8)))
    }

    /// The decoding the tool's output feeds, end to end for Claude's shape.
    func testClaudesPayloadDecodesFromToolOutput() throws {
        let json = #"{"claudeAiOauth":{"accessToken":"abc","expiresAt":4102444800000,"subscriptionType":"max"}}"#
        guard case .secret(let data) = SecurityTool.outcome(status: 0, output: Data((json + "\n").utf8)) else {
            return XCTFail("expected a secret")
        }
        let credentials = try ClaudeCredentials.decode(data)
        XCTAssertEqual(credentials.accessToken, "abc")
        XCTAssertEqual(credentials.subscriptionType, "max")
        XCTAssertFalse(credentials.isExpired)
    }

    /// A dark wake is transient; a real refusal is still a refusal.
    func testDarkWakeIsTransientAndDenyIsNot() {
        XCTAssertTrue(ClaudeCredentials.failure(for: errSecInDarkWake) is TransientCredentialFailure)
        guard case UsageProviderError.accessDenied = ClaudeCredentials.failure(for: errSecUserCanceled) else {
            return XCTFail("Deny must still read as a refusal")
        }
    }
}
