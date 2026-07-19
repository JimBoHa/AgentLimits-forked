import XCTest
@testable import AgentLimits

final class TokenUsageFormatterTests: XCTestCase {
    func testRequestCountsUseMillionsAtMillionScale() {
        XCTAssertEqual(TokenUsageFormatter.formatRequests(999), "999 Requests")
        XCTAssertEqual(TokenUsageFormatter.formatRequests(42_000), "42K Requests")
        XCTAssertEqual(TokenUsageFormatter.formatRequests(1_000_000), "1.0M Requests")
        XCTAssertEqual(TokenUsageFormatter.formatRequests(2_500_000), "2.5M Requests")
    }
}
