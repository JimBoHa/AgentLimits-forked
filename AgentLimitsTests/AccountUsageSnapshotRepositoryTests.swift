import Foundation
import XCTest
@testable import AgentLimits

@MainActor
final class AccountUsageSnapshotRepositoryTests: XCTestCase {
    func testSameProviderAccountsSaveSuppressAndDeleteIndependently() throws {
        try withRepository { repository, visibilityStore, _ in
            let personal = makeAccount(
                id: "a0000000-0000-0000-0000-00000000000a",
                provider: .chatgptCodex,
                label: "Personal"
            )
            let work = makeAccount(
                id: "b0000000-0000-0000-0000-00000000000b",
                provider: .chatgptCodex,
                label: "Work"
            )
            let personalSnapshot = makeSnapshot(
                provider: .chatgptCodex,
                fetchedAt: 1_000
            )
            let workSnapshot = makeSnapshot(
                provider: .chatgptCodex,
                fetchedAt: 2_000
            )

            try repository.saveSnapshot(personalSnapshot, for: personal)
            try repository.saveSnapshot(workSnapshot, for: work)

            XCTAssertEqual(
                repository.loadSnapshot(for: personal)?.fetchedAt,
                personalSnapshot.fetchedAt
            )
            XCTAssertEqual(
                repository.loadSnapshot(for: work)?.fetchedAt,
                workSnapshot.fetchedAt
            )

            repository.setSnapshotSuppressed(true, for: personal)
            XCTAssertNil(repository.loadSnapshot(for: personal))
            XCTAssertEqual(
                repository.loadSnapshot(for: work)?.fetchedAt,
                workSnapshot.fetchedAt
            )
            XCTAssertTrue(
                visibilityStore.isSnapshotSuppressed(
                    fileName: accountVisibilityKey(for: personal)
                )
            )
            XCTAssertFalse(
                visibilityStore.isSnapshotSuppressed(
                    fileName: accountVisibilityKey(for: work)
                )
            )

            repository.setSnapshotSuppressed(false, for: personal)
            try repository.deleteSnapshot(for: personal)
            XCTAssertNil(repository.loadSnapshot(for: personal))
            XCTAssertEqual(
                repository.loadSnapshot(for: work)?.fetchedAt,
                workSnapshot.fetchedAt
            )
        }
    }

    func testLegacyDefaultMigratesOnceAndIsolatedAccountNeverImportsProjection() throws {
        try withRepository { repository, _, context in
            let primary = makeAccount(
                id: "c0000000-0000-0000-0000-00000000000c",
                provider: .claudeCode,
                label: "Primary",
                webKitStorage: .legacyDefault
            )
            let secondary = makeAccount(
                id: "d0000000-0000-0000-0000-00000000000d",
                provider: .claudeCode,
                label: "Secondary"
            )
            let legacySnapshot = makeSnapshot(
                provider: .claudeCode,
                fetchedAt: 3_000
            )
            try context.projectionStore.saveSnapshot(legacySnapshot)

            XCTAssertNil(repository.loadSnapshot(for: secondary))
            XCTAssertEqual(
                repository.loadSnapshot(for: primary)?.fetchedAt,
                legacySnapshot.fetchedAt
            )

            try repository.deleteSnapshot(for: primary)
            XCTAssertNotNil(
                context.projectionStore.loadSnapshot(for: .claudeCode)
            )

            let relaunched = makeRepository(context: context)
            XCTAssertNil(relaunched.loadSnapshot(for: primary))
            XCTAssertNil(relaunched.loadSnapshot(for: secondary))
        }
    }

    func testProviderMismatchRejectsScopedSaveAndFailsProjectionClosed() throws {
        try withRepository { repository, visibilityStore, context in
            let account = makeAccount(
                id: "e0000000-0000-0000-0000-00000000000e",
                provider: .githubCopilot,
                label: "Copilot"
            )
            let mismatched = makeSnapshot(
                provider: .chatgptCodex,
                fetchedAt: 4_000
            )

            XCTAssertThrowsError(
                try repository.saveSnapshot(mismatched, for: account)
            ) { error in
                XCTAssertEqual(
                    error as? AccountUsageSnapshotRepositoryError,
                    .providerMismatch
                )
            }
            XCTAssertNil(repository.loadSnapshot(for: account))

            let accountDirectory = context.containerURL
                .appendingPathComponent(AppGroupConfig.snapshotDirectory)
                .appendingPathComponent("accounts")
                .appendingPathComponent(account.snapshotNamespace)
            try FileManager.default.createDirectory(
                at: accountDirectory,
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            DateCodec.configureEncoder(encoder)
            try encoder.encode(mismatched).write(
                to: accountDirectory.appendingPathComponent(
                    account.provider.snapshotFileName
                ),
                options: .atomic
            )

            XCTAssertNil(repository.loadSnapshot(for: account))
            XCTAssertTrue(
                visibilityStore.isSnapshotSuppressed(
                    fileName: accountVisibilityKey(for: account)
                )
            )

            XCTAssertThrowsError(
                try repository.publishSelectedSnapshot(
                    mismatched,
                    for: account
                )
            ) { error in
                XCTAssertEqual(
                    error as? AccountUsageSnapshotRepositoryError,
                    .providerMismatch
                )
            }
            XCTAssertTrue(
                visibilityStore.isSnapshotSuppressed(
                    fileName: UsageProvider.githubCopilot.snapshotFileName
                )
            )
        }
    }

    private struct RepositoryContext {
        let containerURL: URL
        let visibilityStore: LockedRepositoryVisibilityStore
        let migrationDefaults: UserDefaults
        let projectionStore: UsageSnapshotStore
    }

    private func makeRepository(
        context: RepositoryContext
    ) -> DefaultAccountUsageSnapshotRepository {
        DefaultAccountUsageSnapshotRepository(
            visibilityStore: context.visibilityStore,
            migrationDefaults: context.migrationDefaults,
            makeAccountStore: { account, migratesLegacySnapshot in
                UsageSnapshotStore(
                    visibilityStore: context.visibilityStore,
                    accountID: account.id,
                    migratesLegacySnapshot: migratesLegacySnapshot,
                    containerURLOverride: context.containerURL
                )
            },
            projectionStore: context.projectionStore
        )
    }

    private func withRepository(
        _ body: (
            DefaultAccountUsageSnapshotRepository,
            LockedRepositoryVisibilityStore,
            RepositoryContext
        ) throws -> Void
    ) throws {
        let containerURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "AccountUsageSnapshotRepositoryTests-\(UUID().uuidString)",
                isDirectory: true
            )
        let suiteName = "AccountUsageSnapshotRepositoryTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let visibilityStore = LockedRepositoryVisibilityStore()
        let projectionStore = UsageSnapshotStore(
            visibilityStore: visibilityStore,
            containerURLOverride: containerURL
        )
        let context = RepositoryContext(
            containerURL: containerURL,
            visibilityStore: visibilityStore,
            migrationDefaults: defaults,
            projectionStore: projectionStore
        )
        defer {
            try? FileManager.default.removeItem(at: containerURL)
            defaults.removePersistentDomain(forName: suiteName)
        }

        try body(makeRepository(context: context), visibilityStore, context)
    }

    private func makeAccount(
        id: String,
        provider: UsageProvider,
        label: String,
        webKitStorage: ProviderAccountWebKitStorage = .isolated
    ) -> ProviderAccount {
        ProviderAccount(
            id: UUID(uuidString: id)!,
            provider: provider,
            label: label,
            createdAt: Date(timeIntervalSince1970: 1),
            webKitStorage: webKitStorage
        )
    }

    private func makeSnapshot(
        provider: UsageProvider,
        fetchedAt: TimeInterval
    ) -> UsageSnapshot {
        UsageSnapshot(
            provider: provider,
            fetchedAt: Date(timeIntervalSince1970: fetchedAt),
            primaryWindow: nil,
            secondaryWindow: nil
        )
    }

    private func accountVisibilityKey(for account: ProviderAccount) -> String {
        "accounts/\(account.snapshotNamespace)/\(account.provider.snapshotFileName)"
    }
}

private final class LockedRepositoryVisibilityStore:
    SnapshotVisibilityControlling,
    @unchecked Sendable {
    private let lock = NSLock()
    private var suppressedFileNames: Set<String> = []

    func isSnapshotSuppressed(fileName: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return suppressedFileNames.contains(fileName)
    }

    func setSnapshotSuppressed(_ isSuppressed: Bool, fileName: String) {
        lock.lock()
        defer { lock.unlock() }
        if isSuppressed {
            suppressedFileNames.insert(fileName)
        } else {
            suppressedFileNames.remove(fileName)
        }
    }
}
