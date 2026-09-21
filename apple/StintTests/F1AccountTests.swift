import XCTest
@testable import Stint

final class F1AccountTests: XCTestCase {
    func testLoginURLUsesTheAccountSitesFragmentRouting() {
        // account.formula1.com is a single-page app: `/en/login` as a path returns 404,
        // while formula1.com links sign-in as `/#/en/login`.
        let url = F1Account.loginURL
        XCTAssertEqual(url.host, "account.formula1.com")
        XCTAssertEqual(url.path, "/")
        XCTAssertEqual(url.fragment, "/en/login")
    }
}
