import Foundation
import XCTest
@testable import AgentLimits

@MainActor
final class AccountScopedSnapshotStoreTests: XCTestCase {
    func testAccountsPersistAndDeleteIndependently() throws {
        try withTemporaryContainer { containerURL in
            let firstID = try XCTUnwrap(
                UUID(uuidString: "10000000-0000-0000-0000-000000000001")
            )
            let secondID = try XCTUnwrap(
                UUID(uuidString: "20000000-0000-0000-0000-000000000002")
            )
            let firstStore = makeStore(accountID: firstID, containerURL: containerURL)
            let secondStore = makeStore(accountID: secondID, containerURL: containerURL)
            let firstSnapshot = makeSnapshot(fetchedAt: Date(timeIntervalSince1970: 1_000))
            let secondSnapshot = makeSnapshot(fetchedAt: Date(timeIntervalSince1970: 2_000))

            try firstStore.saveSnapshot(firstSnapshot)
            try secondStore.saveSnapshot(secondSnapshot)

            XCTAssertEqual(
                firstStore.loadSnapshot(for: .chatgptCodex)?.fetchedAt,
                firstSnapshot.fetchedAt
            )
            XCTAssertEqual(
                secondStore.loadSnapshot(for: .chatgptCodex)?.fetchedAt,
                secondSnapshot.fetchedAt
            )

            try firstStore.deleteSnapshot(for: .chatgptCodex)
            XCTAssertNil(firstStore.loadSnapshot(for: .chatgptCodex))
            XCTAssertEqual(
                secondStore.loadSnapshot(for: .chatgptCodex)?.fetchedAt,
                secondSnapshot.fetchedAt
            )
        }
    }

    func testOnlyDesignatedPrimaryAccountMigratesLegacySnapshot() throws {
        try withTemporaryContainer { containerURL in
            let primaryID = try XCTUnwrap(
                UUID(uuidString: "30000000-0000-0000-0000-000000000003")
            )
            let secondaryID = try XCTUnwrap(
                UUID(uuidString: "40000000-0000-0000-0000-000000000004")
            )
            let legacyStore = makeStore(containerURL: containerURL)
            let snapshot = makeSnapshot(fetchedAt: Date(timeIntervalSince1970: 3_000))
            try legacyStore.saveSnapshot(snapshot)

            let secondaryStore = makeStore(
                accountID: secondaryID,
                containerURL: containerURL
            )
            XCTAssertNil(secondaryStore.loadSnapshot(for: .chatgptCodex))

            let primaryStore = makeStore(
                accountID: primaryID,
                migratesLegacySnapshot: true,
                containerURL: containerURL
            )
            XCTAssertEqual(
                primaryStore.loadSnapshot(for: .chatgptCodex)?.fetchedAt,
                snapshot.fetchedAt
            )

            try legacyStore.deleteSnapshot(for: .chatgptCodex)
            XCTAssertEqual(
                primaryStore.loadSnapshot(for: .chatgptCodex)?.fetchedAt,
                snapshot.fetchedAt
            )
            XCTAssertNil(secondaryStore.loadSnapshot(for: .chatgptCodex))
        }
    }

    func testLegacySuppressionMigratesAsAccountSuppression() throws {
        try withTemporaryContainer { containerURL in
            let accountID = try XCTUnwrap(
                UUID(uuidString: "50000000-0000-0000-0000-000000000005")
            )
            let visibilityStore = RecordingAccountSnapshotVisibilityStore()
            let legacyStore = makeStore(
                visibilityStore: visibilityStore,
                containerURL: containerURL
            )
            try legacyStore.saveSnapshot(
                makeSnapshot(fetchedAt: Date(timeIntervalSince1970: 4_000))
            )
            visibilityStore.setSnapshotSuppressed(
                true,
                fileName: UsageProvider.chatgptCodex.snapshotFileName
            )
            let accountStore = makeStore(
                visibilityStore: visibilityStore,
                accountID: accountID,
                migratesLegacySnapshot: true,
                containerURL: containerURL
            )
            let accountVisibilityKey = accountStore.snapshotVisibilityKey(
                for: .chatgptCodex
            )

            XCTAssertNil(accountStore.loadSnapshot(for: .chatgptCodex))
            XCTAssertTrue(
                visibilityStore.isSnapshotSuppressed(fileName: accountVisibilityKey)
            )

            visibilityStore.setSnapshotSuppressed(
                false,
                fileName: UsageProvider.chatgptCodex.snapshotFileName
            )
            XCTAssertNil(accountStore.loadSnapshot(for: .chatgptCodex))

            let freshSnapshot = makeSnapshot(
                fetchedAt: Date(timeIntervalSince1970: 5_000)
            )
            try accountStore.saveSnapshot(freshSnapshot)
            XCTAssertFalse(
                visibilityStore.isSnapshotSuppressed(fileName: accountVisibilityKey)
            )
            XCTAssertEqual(
                accountStore.loadSnapshot(for: .chatgptCodex)?.fetchedAt,
                freshSnapshot.fetchedAt
            )
        }
    }

    func testDeletingMigratedSnapshotDoesNotReimportLegacyData() throws {
        try withTemporaryContainer { containerURL in
            let accountID = try XCTUnwrap(
                UUID(uuidString: "60000000-0000-0000-0000-000000000006")
            )
            let visibilityStore = RecordingAccountSnapshotVisibilityStore()
            let legacyStore = makeStore(
                visibilityStore: visibilityStore,
                containerURL: containerURL
            )
            let legacySnapshot = makeSnapshot(
                fetchedAt: Date(timeIntervalSince1970: 6_000)
            )
            try legacyStore.saveSnapshot(legacySnapshot)
            let accountStore = makeStore(
                visibilityStore: visibilityStore,
                accountID: accountID,
                migratesLegacySnapshot: true,
                containerURL: containerURL
            )
            XCTAssertEqual(
                accountStore.loadSnapshot(for: .chatgptCodex)?.fetchedAt,
                legacySnapshot.fetchedAt
            )

            try accountStore.deleteSnapshot(for: .chatgptCodex)

            XCTAssertNil(accountStore.loadSnapshot(for: .chatgptCodex))
            XCTAssertNotNil(legacyStore.loadSnapshot(for: .chatgptCodex))
        }
    }

    func testFreshScopedSaveRetiresLegacyBeforeLaterDeletion() throws {
        try withTemporaryContainer { containerURL in
            let accountID = try XCTUnwrap(
                UUID(uuidString: "70000000-0000-0000-0000-000000000007")
            )
            let visibilityStore = RecordingAccountSnapshotVisibilityStore()
            let legacyStore = makeStore(
                visibilityStore: visibilityStore,
                containerURL: containerURL
            )
            let oldSnapshot = makeSnapshot(
                fetchedAt: Date(timeIntervalSince1970: 7_000)
            )
            try legacyStore.saveSnapshot(oldSnapshot)
            let accountStore = makeStore(
                visibilityStore: visibilityStore,
                accountID: accountID,
                migratesLegacySnapshot: true,
                containerURL: containerURL
            )
            let freshSnapshot = makeSnapshot(
                fetchedAt: Date(timeIntervalSince1970: 8_000)
            )

            try accountStore.saveSnapshot(freshSnapshot)
            try accountStore.deleteSnapshot(for: .chatgptCodex)

            XCTAssertNil(accountStore.loadSnapshot(for: .chatgptCodex))
            XCTAssertEqual(
                legacyStore.loadSnapshot(for: .chatgptCodex)?.fetchedAt,
                oldSnapshot.fetchedAt
            )
        }
    }

    func testLegacySuppressionWinsOverUnmarkedExistingTarget() throws {
        try withTemporaryContainer { containerURL in
            let accountID = try XCTUnwrap(
                UUID(uuidString: "80000000-0000-0000-0000-000000000008")
            )
            let visibilityStore = RecordingAccountSnapshotVisibilityStore()
            let legacyStore = makeStore(
                visibilityStore: visibilityStore,
                containerURL: containerURL
            )
            try legacyStore.saveSnapshot(
                makeSnapshot(fetchedAt: Date(timeIntervalSince1970: 9_000))
            )
            let unmarkedAccountStore = makeStore(
                visibilityStore: visibilityStore,
                accountID: accountID,
                containerURL: containerURL
            )
            try unmarkedAccountStore.saveSnapshot(
                makeSnapshot(fetchedAt: Date(timeIntervalSince1970: 10_000))
            )
            visibilityStore.setSnapshotSuppressed(
                true,
                fileName: UsageProvider.chatgptCodex.snapshotFileName
            )
            let migrationEnabledStore = makeStore(
                visibilityStore: visibilityStore,
                accountID: accountID,
                migratesLegacySnapshot: true,
                containerURL: containerURL
            )

            XCTAssertNil(migrationEnabledStore.loadSnapshot(for: .chatgptCodex))
            XCTAssertTrue(
                visibilityStore.isSnapshotSuppressed(
                    fileName: migrationEnabledStore.snapshotVisibilityKey(
                        for: .chatgptCodex
                    )
                )
            )
        }
    }

    func testDeleteBeforeFirstLoadRetiresLegacyMigration() throws {
        try withTemporaryContainer { containerURL in
            let accountID = try XCTUnwrap(
                UUID(uuidString: "90000000-0000-0000-0000-000000000009")
            )
            let visibilityStore = RecordingAccountSnapshotVisibilityStore()
            let legacyStore = makeStore(
                visibilityStore: visibilityStore,
                containerURL: containerURL
            )
            try legacyStore.saveSnapshot(
                makeSnapshot(fetchedAt: Date(timeIntervalSince1970: 11_000))
            )
            let accountStore = makeStore(
                visibilityStore: visibilityStore,
                accountID: accountID,
                migratesLegacySnapshot: true,
                containerURL: containerURL
            )

            try accountStore.deleteSnapshot(for: .chatgptCodex)

            XCTAssertNil(accountStore.loadSnapshot(for: .chatgptCodex))
            XCTAssertNotNil(legacyStore.loadSnapshot(for: .chatgptCodex))
        }
    }

    func testLegacyMigrationRejectsSnapshotForDifferentProvider() throws {
        try withTemporaryContainer { containerURL in
            let accountID = try XCTUnwrap(
                UUID(uuidString: "a0000000-0000-0000-0000-00000000000a")
            )
            let mismatchedSnapshot = UsageSnapshot(
                provider: .claudeCode,
                fetchedAt: Date(timeIntervalSince1970: 12_000),
                primaryWindow: nil,
                secondaryWindow: nil
            )
            let encoder = JSONEncoder()
            DateCodec.configureEncoder(encoder)
            try writeLegacyData(
                encoder.encode(mismatchedSnapshot),
                fileName: UsageProvider.chatgptCodex.snapshotFileName,
                containerURL: containerURL
            )
            let accountStore = makeStore(
                accountID: accountID,
                migratesLegacySnapshot: true,
                containerURL: containerURL
            )

            XCTAssertNil(accountStore.loadSnapshot(for: .chatgptCodex))

            let legacyStore = makeStore(containerURL: containerURL)
            try legacyStore.saveSnapshot(
                makeSnapshot(fetchedAt: Date(timeIntervalSince1970: 13_000))
            )
            XCTAssertNil(accountStore.loadSnapshot(for: .chatgptCodex))
        }
    }

    private func makeStore(
        visibilityStore: any SnapshotVisibilityControlling = RecordingAccountSnapshotVisibilityStore(),
        accountID: UUID? = nil,
        migratesLegacySnapshot: Bool = false,
        containerURL: URL
    ) -> UsageSnapshotStore {
        UsageSnapshotStore(
            visibilityStore: visibilityStore,
            accountID: accountID,
            migratesLegacySnapshot: migratesLegacySnapshot,
            containerURLOverride: containerURL
        )
    }

    private func makeSnapshot(fetchedAt: Date) -> UsageSnapshot {
        UsageSnapshot(
            provider: .chatgptCodex,
            fetchedAt: fetchedAt,
            primaryWindow: UsageWindow(
                kind: .primary,
                usedPercent: 50,
                resetAt: Date(timeIntervalSince1970: 10_000),
                limitWindowSeconds: UsageLimitDuration.fiveHours
            ),
            secondaryWindow: nil
        )
    }

    private func writeLegacyData(
        _ data: Data,
        fileName: String,
        containerURL: URL
    ) throws {
        let directoryURL = containerURL.appendingPathComponent(
            AppGroupConfig.snapshotDirectory,
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        try data.write(
            to: directoryURL.appendingPathComponent(fileName),
            options: .atomic
        )
    }

    private func withTemporaryContainer(
        _ body: (URL) throws -> Void
    ) throws {
        let containerURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "AccountScopedSnapshotStoreTests-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: containerURL) }
        try body(containerURL)
    }
}

private final class RecordingAccountSnapshotVisibilityStore:
    SnapshotVisibilityControlling,
    @unchecked Sendable {
    private var suppressedFileNames: Set<String> = []

    func isSnapshotSuppressed(fileName: String) -> Bool {
        suppressedFileNames.contains(fileName)
    }

    func setSnapshotSuppressed(_ isSuppressed: Bool, fileName: String) {
        if isSuppressed {
            suppressedFileNames.insert(fileName)
        } else {
            suppressedFileNames.remove(fileName)
        }
    }
}
