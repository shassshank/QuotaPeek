import XCTest
@testable import QuotaPeek

final class StatusDecodingTests: XCTestCase {
    func testMissingAccountsKeyDecodesAsEmpty() throws {
        let status = try JSONDecoder().decode(StatusResponse.self, from: Data("{}".utf8))
        XCTAssertTrue(status.accounts.isEmpty)
    }

    func testLegacyProvidersKeyIsIgnored() throws {
        let json = #"{"providers":[{"id":"acct_1","provider":"claude"}]}"#
        let status = try JSONDecoder().decode(StatusResponse.self, from: Data(json.utf8))
        XCTAssertTrue(status.accounts.isEmpty)
    }
}
