import Foundation
import XCTest
@testable import AgentLimits

@MainActor
final class AccountTokenUsageSnapshotRepositoryTests: XCTestCase {
    func testSameProviderAccountsSaveSuppressAndDeleteIndependently() throws {
        try withRepository { repository, visibilityStore, _ in
            let personal = makeAccount(
                id: "a1000000-0000-0000-0000-00000000000a",
                provider: .chatgptCodex,
                label: "Personal"
            )
            let work = makeAccount(
                id: "b1000000-0000-0000-0000-00000000000b",
                provider: .chatgptCodex,
                label: "Work"
            )
            let personalSnapshot = makeSnapshot(
                provider: .codex,
                fetchedAt: 1_000
            )
            let workSnapshot = makeSnapshot(
                provider: .codex,
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

            try repository.setSnapshotSuppressed(true, for: personal)
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

            try repository.setSnapshotSuppressed(false, for: personal)
            try repository.deleteSnapshot(for: personal)
            XCTAssertNil(repository.loadSnapshot(for: personal))
            XCTAssertEqual(
                repository.loadSnapshot(for: work)?.fetchedAt,
                workSnapshot.fetchedAt
            )
        }
    }

    func testLegacyDefaultMigratesOnceAndIsolatedAccountNeverImportsProjection()
        throws {
        try withRepository { repository, _, context in
            let primary = makeAccount(
                id: "c1000000-0000-0000-0000-00000000000c",
                provider: .claudeCode,
                label: "Primary",
                webKitStorage: .legacyDefault
            )
            let secondary = makeAccount(
                id: "d1000000-0000-0000-0000-00000000000d",
                provider: .claudeCode,
                label: "Secondary"
            )
            let legacySnapshot = makeSnapshot(
                provider: .claude,
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
                context.projectionStore.loadSnapshot(for: .claude)
            )

            let relaunched = makeRepository(context: context)
            XCTAssertNil(relaunched.loadSnapshot(for: primary))
            XCTAssertNil(relaunched.loadSnapshot(for: secondary))
        }
    }

    func testMissingLegacyProjectionBecomesDurableTerminalMigration() throws {
        try withRepository { repository, _, context in
            let account = makeAccount(
                id: "e1000000-0000-0000-0000-00000000000e",
                provider: .githubCopilot,
                label: "Primary",
                webKitStorage: .legacyDefault
            )

            XCTAssertNil(repository.loadSnapshot(for: account))

            let lateProjection = makeSnapshot(
                provider: .copilot,
                fetchedAt: 4_000
            )
            try context.projectionStore.saveSnapshot(lateProjection)

            let relaunched = makeRepository(context: context)
            XCTAssertNil(relaunched.loadSnapshot(for: account))
            XCTAssertEqual(
                context.projectionStore.loadSnapshot(for: .copilot)?.fetchedAt,
                lateProjection.fetchedAt
            )
        }
    }

    func testExplicitDeleteBeforeLoadPreventsLaterLegacyImport() throws {
        try withRepository { repository, _, context in
            let account = makeAccount(
                id: "e2000000-0000-0000-0000-00000000000e",
                provider: .githubCopilot,
                label: "Primary",
                webKitStorage: .legacyDefault
            )

            try repository.deleteSnapshot(for: account)
            try context.projectionStore.saveSnapshot(
                makeSnapshot(provider: .copilot, fetchedAt: 4_500)
            )

            let relaunched = makeRepository(context: context)
            XCTAssertNil(relaunched.loadSnapshot(for: account))
            XCTAssertTrue(
                relaunched.canSafelyPublishMissingSnapshot(for: account)
            )
        }
    }

    func testNonMissingMigrationFailureRemainsRetryable() throws {
        try withRepository { _, _, context in
            let account = makeAccount(
                id: "f1000000-0000-0000-0000-00000000000f",
                provider: .chatgptCodex,
                label: "Primary",
                webKitStorage: .legacyDefault
            )
            let legacySnapshot = makeSnapshot(
                provider: .codex,
                fetchedAt: 5_000
            )
            try context.projectionStore.saveSnapshot(legacySnapshot)

            let accountsPath = context.containerURL
                .appendingPathComponent(AppGroupConfig.snapshotDirectory)
                .appendingPathComponent("accounts")
            try Data("blocks-directory".utf8).write(
                to: accountsPath,
                options: .atomic
            )

            let firstAttempt = makeRepository(context: context)
            XCTAssertNil(firstAttempt.loadSnapshot(for: account))
            XCTAssertFalse(
                firstAttempt.canSafelyPublishMissingSnapshot(for: account)
            )
            try firstAttempt.setSelectedProjectionSuppressed(
                true,
                for: account
            )
            XCTAssertNil(
                context.projectionStore.loadSnapshot(for: .codex)
            )
            let legacyURL = context.containerURL
                .appendingPathComponent(AppGroupConfig.snapshotDirectory)
                .appendingPathComponent(
                    TokenUsageProvider.codex.snapshotFileName
                )
            XCTAssertFalse(try Data(contentsOf: legacyURL).isEmpty)

            try FileManager.default.removeItem(at: accountsPath)
            let retry = makeRepository(context: context)
            let recovered = try XCTUnwrap(retry.loadSnapshot(for: account))
            XCTAssertEqual(recovered.fetchedAt, legacySnapshot.fetchedAt)
            XCTAssertTrue(
                retry.canSafelyPublishMissingSnapshot(for: account)
            )
            try retry.publishSelectedSnapshot(recovered, for: account)
            XCTAssertEqual(
                context.projectionStore.loadSnapshot(for: .codex)?.fetchedAt,
                legacySnapshot.fetchedAt
            )
            XCTAssertFalse(
                context.projectionStore.isProjectionDisplaySuppressed(
                    for: .codex
                )
            )
        }
    }

    func testDisplayOnlySuppressionHidesProjectionButAllowsMigration()
        throws {
        try withRepository { repository, _, context in
            let account = makeAccount(
                id: "f2000000-0000-0000-0000-00000000000f",
                provider: .chatgptCodex,
                label: "Primary",
                webKitStorage: .legacyDefault
            )
            let legacySnapshot = makeSnapshot(
                provider: .codex,
                fetchedAt: 5_100
            )
            try context.projectionStore.saveSnapshot(legacySnapshot)
            try context.projectionStore.setProjectionDisplaySuppressed(
                true,
                for: .codex
            )

            XCTAssertNil(context.projectionStore.loadSnapshot(for: .codex))
            XCTAssertEqual(
                repository.loadSnapshot(for: account)?.fetchedAt,
                legacySnapshot.fetchedAt
            )
        }
    }

    func testDeletionSuppressionDoesNotImportLegacyProjection() throws {
        try withRepository { repository, visibilityStore, context in
            let account = makeAccount(
                id: "f3000000-0000-0000-0000-00000000000f",
                provider: .chatgptCodex,
                label: "Primary",
                webKitStorage: .legacyDefault
            )
            try context.projectionStore.saveSnapshot(
                makeSnapshot(provider: .codex, fetchedAt: 5_200)
            )
            visibilityStore.setSnapshotSuppressed(
                true,
                fileName: TokenUsageProvider.codex.snapshotFileName
            )
            try context.projectionStore.setProjectionDisplaySuppressed(
                true,
                for: .codex
            )

            XCTAssertNil(context.projectionStore.loadSnapshot(for: .codex))
            XCTAssertNil(repository.loadSnapshot(for: account))
            XCTAssertTrue(repository.canSafelyPublishMissingSnapshot(for: account))
        }
    }

    func testIndeterminateLegacySourceBlocksSiblingProjectionOverwrite()
        throws {
        try withRepository { repository, visibilityStore, context in
            let primary = makeAccount(
                id: "f4000000-0000-0000-0000-00000000000f",
                provider: .chatgptCodex,
                label: "Primary",
                webKitStorage: .legacyDefault
            )
            let sibling = makeAccount(
                id: "f5000000-0000-0000-0000-00000000000f",
                provider: .chatgptCodex,
                label: "Work"
            )
            let legacySnapshot = makeSnapshot(
                provider: .codex,
                fetchedAt: 5_300
            )
            let siblingSnapshot = makeSnapshot(
                provider: .codex,
                fetchedAt: 5_400
            )
            try repository.saveSnapshot(siblingSnapshot, for: sibling)
            try context.projectionStore.saveSnapshot(legacySnapshot)
            let accountsPath = context.containerURL
                .appendingPathComponent(AppGroupConfig.snapshotDirectory)
                .appendingPathComponent("accounts")
            try FileManager.default.removeItem(at: accountsPath)
            try Data("blocks-directory".utf8).write(
                to: accountsPath,
                options: .atomic
            )

            XCTAssertNil(repository.loadSnapshot(for: primary))
            XCTAssertThrowsError(
                try repository.publishSelectedSnapshot(
                    siblingSnapshot,
                    for: sibling
                )
            ) { error in
                XCTAssertEqual(
                    error as? AccountTokenUsageSnapshotRepositoryError,
                    .legacyProjectionSourceIndeterminate(.codex)
                )
            }
            XCTAssertTrue(
                context.projectionStore.isProjectionDisplaySuppressed(
                    for: .codex
                )
            )
            XCTAssertEqual(
                try loadRawProjection(
                    TokenUsageSnapshot.self,
                    providerFileName: TokenUsageProvider.codex
                        .snapshotFileName,
                    context: context
                ).fetchedAt,
                legacySnapshot.fetchedAt
            )

            try FileManager.default.removeItem(at: accountsPath)
            XCTAssertEqual(
                repository.loadSnapshot(for: primary)?.fetchedAt,
                legacySnapshot.fetchedAt
            )
            try repository.publishSelectedSnapshot(
                siblingSnapshot,
                for: sibling
            )
            XCTAssertEqual(
                context.projectionStore.loadSnapshot(for: .codex)?.fetchedAt,
                siblingSnapshot.fetchedAt
            )
        }
    }

    func testFailedDeleteRetirementRestoresMarkerAndAllowsMigration()
        throws {
        let containerURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "TokenRetirementRollback-\(UUID().uuidString)",
                isDirectory: true
            )
        let suiteName = "TokenRetirementRollback-\(UUID().uuidString)"
        let defaults = TokenSequencedSyncUserDefaults(
            suiteName: suiteName
        )!
        let visibilityStore = LockedTokenRepositoryVisibilityStore()
        let context = RepositoryContext(
            containerURL: containerURL,
            visibilityStore: visibilityStore,
            migrationDefaults: defaults,
            projectionStore: TokenUsageSnapshotStore(
                visibilityStore: visibilityStore,
                containerURLOverride: containerURL
            )
        )
        defer {
            try? FileManager.default.removeItem(at: containerURL)
            defaults.removePersistentDomain(forName: suiteName)
        }
        let account = makeAccount(
            id: "f6000000-0000-0000-0000-00000000000f",
            provider: .chatgptCodex,
            label: "Primary",
            webKitStorage: .legacyDefault
        )
        let legacySnapshot = makeSnapshot(
            provider: .codex,
            fetchedAt: 5_500
        )
        try context.projectionStore.saveSnapshot(legacySnapshot)
        defaults.synchronizeResults = [false, false]

        let repository = makeRepository(context: context)
        XCTAssertThrowsError(
            try repository.deleteSnapshot(for: account)
        ) { error in
            XCTAssertEqual(
                error as? AccountTokenUsageSnapshotRepositoryError,
                .migrationRetirementFailed
            )
        }
        XCTAssertNil(
            defaults.object(
                forKey: AccountSnapshotMigrationKey.tokenUsage(for: account)
            )
        )

        defaults.synchronizeResults = []
        let retry = makeRepository(context: context)
        XCTAssertEqual(
            retry.loadSnapshot(for: account)?.fetchedAt,
            legacySnapshot.fetchedAt
        )
    }

    func testProviderMismatchRejectsScopedSaveAndFailsProjectionClosed()
        throws {
        try withRepository { repository, visibilityStore, context in
            let account = makeAccount(
                id: "a2000000-0000-0000-0000-00000000000a",
                provider: .githubCopilot,
                label: "Copilot"
            )
            let mismatched = makeSnapshot(
                provider: .codex,
                fetchedAt: 6_000
            )

            XCTAssertThrowsError(
                try repository.saveSnapshot(mismatched, for: account)
            ) { error in
                XCTAssertEqual(
                    error as? AccountTokenUsageSnapshotRepositoryError,
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
                    TokenUsageProvider.copilot.snapshotFileName
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
                    error as? AccountTokenUsageSnapshotRepositoryError,
                    .providerMismatch
                )
            }
            XCTAssertTrue(
                context.projectionStore.isProjectionDisplaySuppressed(
                    for: .copilot
                )
            )
        }
    }

    func testSelectedProjectionPublishesDeletesAndFailsSuppressed() throws {
        try withRepository { repository, visibilityStore, context in
            let account = makeAccount(
                id: "b2000000-0000-0000-0000-00000000000b",
                provider: .chatgptCodex,
                label: "Personal"
            )
            let snapshot = makeSnapshot(
                provider: .codex,
                fetchedAt: 7_000
            )
            try repository.saveSnapshot(snapshot, for: account)

            try repository.publishSelectedSnapshot(snapshot, for: account)
            XCTAssertEqual(
                context.projectionStore.loadSnapshot(for: .codex)?.fetchedAt,
                snapshot.fetchedAt
            )
            XCTAssertFalse(
                visibilityStore.isSnapshotSuppressed(
                    fileName: TokenUsageProvider.codex.snapshotFileName
                )
            )
            XCTAssertEqual(
                repository.loadSnapshot(for: account)?.fetchedAt,
                snapshot.fetchedAt
            )

            try repository.publishSelectedSnapshot(nil, for: account)
            XCTAssertNil(context.projectionStore.loadSnapshot(for: .codex))
            XCTAssertFalse(
                visibilityStore.isSnapshotSuppressed(
                    fileName: TokenUsageProvider.codex.snapshotFileName
                )
            )
            XCTAssertEqual(
                repository.loadSnapshot(for: account)?.fetchedAt,
                snapshot.fetchedAt
            )

            try repository.publishSelectedSnapshot(snapshot, for: account)
            let displayMarker = context.containerURL
                .appendingPathComponent(AppGroupConfig.snapshotDirectory)
                .appendingPathComponent(
                    ".projection-display-suppressed-"
                        + TokenUsageProvider.codex.snapshotFileName
                )
            try FileManager.default.createDirectory(
                at: displayMarker,
                withIntermediateDirectories: true
            )

            XCTAssertThrowsError(
                try repository.publishSelectedSnapshot(
                    nil,
                    for: account
                )
            )
            XCTAssertTrue(
                context.projectionStore.isProjectionDisplaySuppressed(
                    for: .codex
                )
            )
            XCTAssertEqual(
                try loadRawProjection(
                    TokenUsageSnapshot.self,
                    providerFileName: TokenUsageProvider.codex
                        .snapshotFileName,
                    context: context
                ).fetchedAt,
                snapshot.fetchedAt
            )
        }
    }

    private struct RepositoryContext {
        let containerURL: URL
        let visibilityStore: LockedTokenRepositoryVisibilityStore
        let migrationDefaults: UserDefaults
        let projectionStore: TokenUsageSnapshotStore
    }

    private func makeRepository(
        context: RepositoryContext,
        projectionStore: TokenUsageSnapshotStore? = nil
    ) -> DefaultAccountTokenUsageSnapshotRepository {
        DefaultAccountTokenUsageSnapshotRepository(
            visibilityStore: context.visibilityStore,
            migrationDefaults: context.migrationDefaults,
            makeAccountStore: { account, migratesLegacySnapshot in
                TokenUsageSnapshotStore(
                    visibilityStore: context.visibilityStore,
                    accountID: account.id,
                    migratesLegacySnapshot: migratesLegacySnapshot,
                    containerURLOverride: context.containerURL
                )
            },
            projectionStore: projectionStore ?? context.projectionStore
        )
    }

    private func loadRawProjection<Snapshot: Decodable>(
        _ type: Snapshot.Type,
        providerFileName: String,
        context: RepositoryContext
    ) throws -> Snapshot {
        let url = context.containerURL
            .appendingPathComponent(AppGroupConfig.snapshotDirectory)
            .appendingPathComponent(providerFileName)
        let decoder = JSONDecoder()
        DateCodec.configureDecoder(decoder)
        return try decoder.decode(type, from: Data(contentsOf: url))
    }

    private func withRepository(
        _ body: (
            DefaultAccountTokenUsageSnapshotRepository,
            LockedTokenRepositoryVisibilityStore,
            RepositoryContext
        ) throws -> Void
    ) throws {
        let containerURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "AccountTokenUsageSnapshotRepositoryTests-\(UUID().uuidString)",
                isDirectory: true
            )
        let suiteName =
            "AccountTokenUsageSnapshotRepositoryTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let visibilityStore = LockedTokenRepositoryVisibilityStore()
        let projectionStore = TokenUsageSnapshotStore(
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
        provider: TokenUsageProvider,
        fetchedAt: TimeInterval
    ) -> TokenUsageSnapshot {
        TokenUsageSnapshot(
            provider: provider,
            fetchedAt: Date(timeIntervalSince1970: fetchedAt),
            today: TokenUsagePeriod(costUSD: 1, totalTokens: 10),
            thisWeek: TokenUsagePeriod(costUSD: 2, totalTokens: 20),
            thisMonth: TokenUsagePeriod(costUSD: 3, totalTokens: 30)
        )
    }

    private func accountVisibilityKey(for account: ProviderAccount) -> String {
        let provider = account.provider.tokenUsageProvider!
        return "accounts/\(account.snapshotNamespace)/\(provider.snapshotFileName)"
    }
}

private final class LockedTokenRepositoryVisibilityStore:
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

private final class TokenSequencedSyncUserDefaults: UserDefaults {
    var synchronizeResults: [Bool] = []

    override func synchronize() -> Bool {
        guard !synchronizeResults.isEmpty else {
            return super.synchronize()
        }
        return synchronizeResults.removeFirst()
    }
}
