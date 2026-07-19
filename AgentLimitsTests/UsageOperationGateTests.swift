import XCTest
@testable import AgentLimits

@MainActor
final class UsageOperationGateTests: XCTestCase {
    func testClearInvalidatesOutstandingContextsAndFetches() throws {
        var gate = UsageOperationGate<UsageProvider>()
        let context = try XCTUnwrap(gate.captureContext(for: .chatgptCodex))
        let fetch = try XCTUnwrap(
            gate.beginFetch(for: .chatgptCodex, context: context)
        )

        let clear = try XCTUnwrap(gate.beginClear())

        XCTAssertFalse(gate.isCurrent(context))
        XCTAssertFalse(gate.isCurrent(fetch))
        XCTAssertFalse(gate.finishFetch(fetch))
        XCTAssertNil(gate.captureContext(for: .chatgptCodex))
        XCTAssertNil(gate.beginFetch(for: .claudeCode))
        XCTAssertNil(gate.beginClear())

        XCTAssertTrue(gate.finishClear(clear))
        XCTAssertNotNil(gate.captureContext(for: .chatgptCodex))
    }

    func testStaleFetchCannotFinishNewerFetchingState() throws {
        var gate = UsageOperationGate<UsageProvider>()
        let oldFetch = try XCTUnwrap(gate.beginFetch(for: .githubCopilot))
        let clear = try XCTUnwrap(gate.beginClear())
        XCTAssertTrue(gate.finishClear(clear))

        let newFetch = try XCTUnwrap(gate.beginFetch(for: .githubCopilot))

        XCTAssertFalse(gate.finishFetch(oldFetch))
        XCTAssertTrue(gate.isCurrent(newFetch))
        XCTAssertTrue(gate.finishFetch(newFetch))
        XCTAssertFalse(gate.isCurrent(newFetch))
    }

    func testOldLoginRecoveryAndBillingContextStaysInvalidAfterClear() throws {
        var gate = UsageOperationGate<UsageProvider>()
        let oldContext = try XCTUnwrap(gate.captureContext(for: .claudeCode))
        let clear = try XCTUnwrap(gate.beginClear())
        XCTAssertTrue(gate.finishClear(clear))
        let newContext = try XCTUnwrap(gate.captureContext(for: .claudeCode))

        XCTAssertFalse(gate.isCurrent(oldContext))
        XCTAssertTrue(gate.isCurrent(newContext))
        XCTAssertNotEqual(oldContext, newContext)
        XCTAssertNil(gate.beginFetch(for: .claudeCode, context: oldContext))
        XCTAssertNotNil(gate.beginFetch(for: .claudeCode, context: newContext))
    }

    func testFetchesForDifferentProvidersRemainIndependent() throws {
        var gate = UsageOperationGate<UsageProvider>()
        let codex = try XCTUnwrap(gate.beginFetch(for: .chatgptCodex))
        let claude = try XCTUnwrap(gate.beginFetch(for: .claudeCode))

        XCTAssertNil(gate.beginFetch(for: .chatgptCodex))
        XCTAssertTrue(gate.finishFetch(codex))
        XCTAssertTrue(gate.isCurrent(claude))
        XCTAssertTrue(gate.finishFetch(claude))
    }

    func testPreClearAutoRefreshContextCannotStartLaterProvider() throws {
        var gate = UsageOperationGate<UsageProvider>()
        let loopContext = try XCTUnwrap(gate.captureContext(for: .chatgptCodex))
        let firstProviderFetch = try XCTUnwrap(
            gate.beginFetch(for: .chatgptCodex, context: loopContext)
        )

        let clear = try XCTUnwrap(gate.beginClear())
        XCTAssertTrue(gate.finishClear(clear))

        XCTAssertFalse(gate.finishFetch(firstProviderFetch))
        XCTAssertFalse(gate.isCurrent(loopContext))
        XCTAssertNil(gate.beginFetch(for: .claudeCode, context: loopContext))
        XCTAssertNotNil(gate.beginFetch(for: .claudeCode))
    }

    func testInvalidatingUUIDScopeLeavesSiblingContextAndFetchCurrent() throws {
        var gate = UsageOperationGate<UUID>()
        let personalID = UUID()
        let workID = UUID()
        let personalContext = try XCTUnwrap(gate.captureContext(for: personalID))
        let workContext = try XCTUnwrap(gate.captureContext(for: workID))
        let personalFetch = try XCTUnwrap(
            gate.beginFetch(for: personalID, context: personalContext)
        )
        let workFetch = try XCTUnwrap(
            gate.beginFetch(for: workID, context: workContext)
        )

        gate.invalidate(scope: personalID)

        XCTAssertFalse(gate.isCurrent(personalContext))
        XCTAssertFalse(gate.isCurrent(personalFetch))
        XCTAssertFalse(gate.finishFetch(personalFetch))
        XCTAssertTrue(gate.isCurrent(workContext))
        XCTAssertTrue(gate.isCurrent(workFetch))
        XCTAssertTrue(gate.finishFetch(workFetch))
        XCTAssertNotNil(gate.beginFetch(for: personalID))
    }

    func testContextCannotStartFetchForDifferentUUIDScope() throws {
        var gate = UsageOperationGate<UUID>()
        let personalID = UUID()
        let workID = UUID()
        let personalContext = try XCTUnwrap(gate.captureContext(for: personalID))

        XCTAssertNil(gate.beginFetch(for: workID, context: personalContext))
        XCTAssertNotNil(gate.beginFetch(for: personalID, context: personalContext))
        XCTAssertNotNil(gate.beginFetch(for: workID))
    }
}
