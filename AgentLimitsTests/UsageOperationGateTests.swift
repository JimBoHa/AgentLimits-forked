import XCTest
@testable import AgentLimits

@MainActor
final class UsageOperationGateTests: XCTestCase {
    func testClearInvalidatesOutstandingContextsAndFetches() throws {
        var gate = UsageOperationGate()
        let context = try XCTUnwrap(gate.captureContext())
        let fetch = try XCTUnwrap(
            gate.beginFetch(for: .chatgptCodex, context: context)
        )

        let clear = try XCTUnwrap(gate.beginClear())

        XCTAssertFalse(gate.isCurrent(context))
        XCTAssertFalse(gate.isCurrent(fetch))
        XCTAssertFalse(gate.finishFetch(fetch))
        XCTAssertNil(gate.captureContext())
        XCTAssertNil(gate.beginFetch(for: .claudeCode))
        XCTAssertNil(gate.beginClear())

        XCTAssertTrue(gate.finishClear(clear))
        XCTAssertNotNil(gate.captureContext())
    }

    func testStaleFetchCannotFinishNewerFetchingState() throws {
        var gate = UsageOperationGate()
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
        var gate = UsageOperationGate()
        let oldContext = try XCTUnwrap(gate.captureContext())
        let clear = try XCTUnwrap(gate.beginClear())
        XCTAssertTrue(gate.finishClear(clear))
        let newContext = try XCTUnwrap(gate.captureContext())

        XCTAssertFalse(gate.isCurrent(oldContext))
        XCTAssertTrue(gate.isCurrent(newContext))
        XCTAssertNotEqual(oldContext, newContext)
        XCTAssertNil(gate.beginFetch(for: .claudeCode, context: oldContext))
        XCTAssertNotNil(gate.beginFetch(for: .claudeCode, context: newContext))
    }

    func testFetchesForDifferentProvidersRemainIndependent() throws {
        var gate = UsageOperationGate()
        let codex = try XCTUnwrap(gate.beginFetch(for: .chatgptCodex))
        let claude = try XCTUnwrap(gate.beginFetch(for: .claudeCode))

        XCTAssertNil(gate.beginFetch(for: .chatgptCodex))
        XCTAssertTrue(gate.finishFetch(codex))
        XCTAssertTrue(gate.isCurrent(claude))
        XCTAssertTrue(gate.finishFetch(claude))
    }

    func testPreClearAutoRefreshContextCannotStartLaterProvider() throws {
        var gate = UsageOperationGate()
        let loopContext = try XCTUnwrap(gate.captureContext())
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
}
