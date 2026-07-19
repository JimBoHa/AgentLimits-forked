import UserNotifications
import XCTest
@testable import AgentLimits

@MainActor
final class ThresholdNotificationGenerationTests: XCTestCase {
    func testMissingResetTimestampNeverSubmitsRepeatedAlerts() async {
        let center = RecordingThresholdNotificationCenter()
        let manager = makeManager(notificationCenter: center)
        await manager.checkAuthorizationStatus()
        let snapshot = makeSnapshot(resetAt: nil)

        await manager.checkThresholdsIfNeeded(for: snapshot)
        await manager.checkThresholdsIfNeeded(for: snapshot)

        XCTAssertTrue(center.addedRequests.isEmpty)
    }

    func testKnownResetSubmitsEachLevelOnlyOnce() async {
        let center = RecordingThresholdNotificationCenter()
        let manager = makeManager(notificationCenter: center)
        await manager.checkAuthorizationStatus()
        let snapshot = makeSnapshot(resetAt: Date(timeIntervalSince1970: 9_000))

        await manager.checkThresholdsIfNeeded(for: snapshot)
        await manager.checkThresholdsIfNeeded(for: snapshot)

        XCTAssertEqual(center.addedRequests.count, 2)
    }

    func testChangedResetAllowsAlertsForNewQuotaCycle() async {
        let center = RecordingThresholdNotificationCenter()
        let manager = makeManager(notificationCenter: center)
        await manager.checkAuthorizationStatus()

        await manager.checkThresholdsIfNeeded(
            for: makeSnapshot(resetAt: Date(timeIntervalSince1970: 9_000))
        )
        await manager.checkThresholdsIfNeeded(
            for: makeSnapshot(resetAt: Date(timeIntervalSince1970: 19_000))
        )

        XCTAssertEqual(center.addedRequests.count, 4)
    }

    func testStaleCompletionRemovesOnlyItsUniqueSubmission() async throws {
        let defaults = UserDefaults(
            suiteName: "ThresholdNotificationGenerationTests-\(UUID().uuidString)"
        )!
        let center = SuspendingThresholdNotificationCenter()
        let oldSubmissionID = try XCTUnwrap(
            UUID(uuidString: "00000000-0000-0000-0000-000000000001")
        )
        let newSubmissionID = try XCTUnwrap(
            UUID(uuidString: "00000000-0000-0000-0000-000000000002")
        )
        var submissionIDs = [oldSubmissionID, newSubmissionID]
        let manager = ThresholdNotificationManager(
            store: ThresholdNotificationStore(userDefaults: defaults),
            notificationCenter: center,
            makeSubmissionID: { submissionIDs.removeFirst() }
        )
        await manager.checkAuthorizationStatus()

        let snapshot = UsageSnapshot(
            provider: .chatgptCodex,
            fetchedAt: Date(timeIntervalSince1970: 1_000),
            primaryWindow: UsageWindow(
                kind: .primary,
                usedPercent: 80,
                resetAt: Date(timeIntervalSince1970: 9_000),
                limitWindowSeconds: UsageLimitDuration.fiveHours
            ),
            secondaryWindow: nil
        )
        let oldGeneration = NotificationGenerationState(isCurrent: true)
        let newGeneration = NotificationGenerationState(isCurrent: true)

        let oldTask = Task {
            await manager.checkThresholdsIfNeeded(
                for: snapshot,
                isCurrent: { oldGeneration.isCurrent }
            )
        }
        await center.waitForRequestCount(1)
        oldGeneration.isCurrent = false

        let newTask = Task {
            await manager.checkThresholdsIfNeeded(
                for: snapshot,
                isCurrent: { newGeneration.isCurrent }
            )
        }
        await center.waitForRequestCount(2)

        let oldIdentifier = center.addedRequests[0].identifier
        let newIdentifier = center.addedRequests[1].identifier
        XCTAssertNotEqual(oldIdentifier, newIdentifier)
        XCTAssertTrue(oldIdentifier.hasSuffix(oldSubmissionID.uuidString))
        XCTAssertTrue(newIdentifier.hasSuffix(newSubmissionID.uuidString))

        center.completeRequest(identifier: newIdentifier)
        await newTask.value
        center.completeRequest(identifier: oldIdentifier)
        await oldTask.value

        XCTAssertTrue(center.removedPendingIdentifiers.contains(oldIdentifier))
        XCTAssertTrue(center.removedDeliveredIdentifiers.contains(oldIdentifier))
        XCTAssertFalse(center.removedPendingIdentifiers.contains(newIdentifier))
        XCTAssertFalse(center.removedDeliveredIdentifiers.contains(newIdentifier))
    }

    private func makeManager(
        notificationCenter: any ThresholdNotificationCenterClient
    ) -> ThresholdNotificationManager {
        let defaults = UserDefaults(
            suiteName: "ThresholdNotificationGenerationTests-\(UUID().uuidString)"
        )!
        return ThresholdNotificationManager(
            store: ThresholdNotificationStore(userDefaults: defaults),
            notificationCenter: notificationCenter
        )
    }

    private func makeSnapshot(resetAt: Date?) -> UsageSnapshot {
        UsageSnapshot(
            provider: .chatgptCodex,
            fetchedAt: Date(timeIntervalSince1970: 1_000),
            primaryWindow: UsageWindow(
                kind: .primary,
                usedPercent: 95,
                resetAt: resetAt,
                limitWindowSeconds: UsageLimitDuration.fiveHours
            ),
            secondaryWindow: nil
        )
    }
}

@MainActor
private final class NotificationGenerationState {
    var isCurrent: Bool

    init(isCurrent: Bool) {
        self.isCurrent = isCurrent
    }
}

@MainActor
private final class RecordingThresholdNotificationCenter: ThresholdNotificationCenterClient {
    private(set) var addedRequests: [UNNotificationRequest] = []

    func isAuthorized() async -> Bool {
        true
    }

    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool {
        true
    }

    func add(_ request: UNNotificationRequest) async throws {
        addedRequests.append(request)
    }

    func removePendingNotificationRequests(withIdentifiers identifiers: [String]) {}

    func removeDeliveredNotifications(withIdentifiers identifiers: [String]) {}
}

@MainActor
private final class SuspendingThresholdNotificationCenter: ThresholdNotificationCenterClient {
    private(set) var addedRequests: [UNNotificationRequest] = []
    private(set) var removedPendingIdentifiers: [String] = []
    private(set) var removedDeliveredIdentifiers: [String] = []
    private var requestContinuations: [String: CheckedContinuation<Void, Error>] = [:]
    private var requestCountWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func isAuthorized() async -> Bool {
        true
    }

    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool {
        true
    }

    func add(_ request: UNNotificationRequest) async throws {
        addedRequests.append(request)
        resumeSatisfiedRequestCountWaiters()
        try await withCheckedThrowingContinuation { continuation in
            requestContinuations[request.identifier] = continuation
        }
    }

    func removePendingNotificationRequests(withIdentifiers identifiers: [String]) {
        removedPendingIdentifiers.append(contentsOf: identifiers)
    }

    func removeDeliveredNotifications(withIdentifiers identifiers: [String]) {
        removedDeliveredIdentifiers.append(contentsOf: identifiers)
    }

    func waitForRequestCount(_ count: Int) async {
        guard addedRequests.count < count else { return }
        await withCheckedContinuation { continuation in
            requestCountWaiters.append((count, continuation))
        }
    }

    func completeRequest(identifier: String) {
        requestContinuations.removeValue(forKey: identifier)?.resume()
    }

    private func resumeSatisfiedRequestCountWaiters() {
        let satisfiedWaiters = requestCountWaiters.filter { addedRequests.count >= $0.0 }
        requestCountWaiters.removeAll { addedRequests.count >= $0.0 }
        for (_, continuation) in satisfiedWaiters {
            continuation.resume()
        }
    }
}
