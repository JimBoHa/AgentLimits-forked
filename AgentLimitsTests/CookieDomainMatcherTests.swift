import XCTest
@testable import AgentLimits

final class CookieDomainMatcherTests: XCTestCase {
    func testAcceptsExactDomainsAndRealSubdomains() {
        XCTAssertTrue(CookieDomainMatcher.matches("claude.ai", expectedDomain: "claude.ai"))
        XCTAssertTrue(CookieDomainMatcher.matches(".claude.ai", expectedDomain: "claude.ai"))
        XCTAssertTrue(CookieDomainMatcher.matches("accounts.claude.ai", expectedDomain: "claude.ai"))
        XCTAssertTrue(CookieDomainMatcher.matches(".GitHub.com", expectedDomain: "github.com"))
    }

    func testRejectsLookalikeAndParentDomains() {
        XCTAssertFalse(CookieDomainMatcher.matches("evilclaude.ai", expectedDomain: "claude.ai"))
        XCTAssertFalse(CookieDomainMatcher.matches("claude.ai.evil.test", expectedDomain: "claude.ai"))
        XCTAssertFalse(CookieDomainMatcher.matches("notgithub.com", expectedDomain: "github.com"))
        XCTAssertFalse(CookieDomainMatcher.matches("com", expectedDomain: "github.com"))
        XCTAssertFalse(CookieDomainMatcher.matches("", expectedDomain: "github.com"))
    }
}
