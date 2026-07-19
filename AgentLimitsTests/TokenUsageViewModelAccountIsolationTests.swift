import XCTest
@testable import AgentLimits

@MainActor
final class TokenUsageViewModelAccountIsolationTests: XCTestCase {
    func testIndeterminateStartupLoadPreservesSelectedProjection() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let priorProjection = makeSnapshot(
            provider: .codex,
            fetchedAt: 90
        )
        fixture.repository.projections[.codex] = priorProjection
        fixture.repository.indeterminateLoadIdentities.insert(
            RecordingSnapshotIdentity(
                accountID: fixture.personal.id,
                provider: .codex
            )
        )

        let viewModel = fixture.makeViewModel()

        XCTAssertNil(viewModel.snapshots[.codex])
        XCTAssertEqual(
            fixture.repository.projections[.codex]?.fetchedAt,
            priorProjection.fetchedAt
        )
        XCTAssertFalse(
            fixture.repository.projectionDeletionAttempts.contains(.codex)
        )
        XCTAssertTrue(
            fixture.repository.suppressedProjectionProviders.contains(.codex)
        )
    }

    func testPrecommitRootQuarantineSurvivesCrashWithoutRegistryChange()
        throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let oldSnapshot = makeSnapshot(provider: .codex, fetchedAt: 91)
        fixture.repository.snapshots[fixture.personal.id] = oldSnapshot
        fixture.repository.projections[.codex] = oldSnapshot
        let viewModel = fixture.makeViewModel()
        let proposed = fixture.personal.updating(
            label: fixture.personal.label,
            isEnabled: fixture.personal.isEnabled,
            cliDataRoot: "/tmp/agentlimits-crash-root"
        )

        try viewModel.prepareCLIDataRootChange(
            from: fixture.personal,
            to: proposed
        )

        XCTAssertNil(fixture.accountStore.account(id: fixture.personal.id)?.cliDataRoot)
        XCTAssertNil(fixture.repository.snapshots[fixture.personal.id])
        XCTAssertNil(fixture.repository.projections[.codex])

        let relaunched = fixture.makeViewModel()
        XCTAssertNil(relaunched.snapshot(for: fixture.personal.id))
        XCTAssertNil(relaunched.snapshots[.codex])
        XCTAssertNil(fixture.repository.projections[.codex])
    }

    func testIndeterminateRootChangeDeletionFailureClearsOldProjection()
        throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let oldProjection = makeSnapshot(provider: .codex, fetchedAt: 92)
        fixture.repository.projections[.codex] = oldProjection
        fixture.repository.indeterminateLoadIdentities.insert(
            RecordingSnapshotIdentity(
                accountID: fixture.personal.id,
                provider: .codex
            )
        )
        fixture.repository.deletionErrors[fixture.personal.id] =
            TestTokenError.delete
        let viewModel = fixture.makeViewModel()
        XCTAssertEqual(
            fixture.repository.projections[.codex]?.fetchedAt,
            oldProjection.fetchedAt
        )

        try fixture.accountStore.updateAccount(
            fixture.personal.updating(
                label: fixture.personal.label,
                isEnabled: fixture.personal.isEnabled,
                cliDataRoot: "/tmp/agentlimits-new-root"
            )
        )
        viewModel.reloadAccounts()

        XCTAssertNil(fixture.repository.projections[.codex])
        XCTAssertNil(viewModel.snapshots[.codex])
    }

    func testCombinedRootAndSelectionChangeClearsPriorSiblingProjection()
        throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let personalSnapshot = makeSnapshot(provider: .codex, fetchedAt: 93)
        fixture.repository.snapshots[fixture.personal.id] = personalSnapshot
        fixture.repository.projections[.codex] = personalSnapshot
        fixture.repository.indeterminateLoadIdentities.insert(
            RecordingSnapshotIdentity(
                accountID: fixture.work.id,
                provider: .codex
            )
        )
        fixture.repository.deletionErrors[fixture.work.id] =
            TestTokenError.delete
        let viewModel = fixture.makeViewModel()

        try fixture.accountStore.updateAccount(
            fixture.work.updating(
                label: fixture.work.label,
                isEnabled: fixture.work.isEnabled,
                cliDataRoot: "/tmp/agentlimits-work-moved"
            )
        )
        try fixture.accountStore.selectAccount(id: fixture.work.id)
        viewModel.reloadAccounts()

        XCTAssertNil(fixture.repository.projections[.codex])
        XCTAssertNil(viewModel.snapshots[.codex])
    }

    func testSameUUIDProviderSwapRetiresOldSnapshotAndNeverCrossDisplays()
        async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        fixture.repository.snapshots[fixture.personal.id] = makeSnapshot(
            provider: .codex,
            fetchedAt: 95
        )
        fixture.repository.additionalSnapshots[fixture.personal.id] = [
            .copilot: makeSnapshot(provider: .copilot, fetchedAt: 96)
        ]
        let viewModel = fixture.makeViewModel()

        var accounts = fixture.accountStore.loadAccounts()
        let index = try XCTUnwrap(
            accounts.firstIndex { $0.id == fixture.personal.id }
        )
        let oldAccount = accounts[index]
        accounts[index] = ProviderAccount(
            id: oldAccount.id,
            provider: .githubCopilot,
            label: oldAccount.label,
            isEnabled: oldAccount.isEnabled,
            cliDataRoot: oldAccount.cliDataRoot,
            createdAt: oldAccount.createdAt,
            webKitStorage: oldAccount.webKitStorage
        )
        fixture.defaults.set(
            try JSONEncoder().encode(
                TestProviderRegistryPayload(
                    version: 3,
                    accounts: accounts,
                    pendingWebKitDataStoreDeletionIDs: []
                )
            ),
            forKey: "accounts"
        )
        try fixture.accountStore.selectAccount(id: fixture.personal.id)

        viewModel.reloadAccounts()
        await viewModel.refreshNow(for: .copilot)

        XCTAssertNil(viewModel.snapshot(for: fixture.personal.id))
        XCTAssertNil(viewModel.snapshots[.codex])
        XCTAssertNil(viewModel.snapshots[.copilot])
        XCTAssertNil(
            fixture.repository.additionalSnapshots[fixture.personal.id]?[.copilot]
        )
        XCTAssertTrue(
            fixture.repository.deletionProviderAttempts.contains {
                $0.accountID == fixture.personal.id && $0.provider == .codex
            }
        )
        XCTAssertTrue(
            fixture.repository.deletionProviderAttempts.contains {
                $0.accountID == fixture.personal.id && $0.provider == .copilot
            }
        )
    }

    func testSharedSelectionControlsProviderFacadeAndProjection() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let personalSnapshot = makeSnapshot(provider: .codex, fetchedAt: 100)
        let workSnapshot = makeSnapshot(provider: .codex, fetchedAt: 200)
        fixture.repository.snapshots[fixture.personal.id] = personalSnapshot
        fixture.repository.snapshots[fixture.work.id] = workSnapshot

        let viewModel = fixture.makeViewModel()

        XCTAssertEqual(viewModel.snapshots[.codex]?.fetchedAt, personalSnapshot.fetchedAt)
        XCTAssertEqual(
            fixture.repository.projections[.codex]?.fetchedAt,
            personalSnapshot.fetchedAt
        )

        try viewModel.prepareSelectedProjectionRemoval(for: fixture.personal)
        try fixture.accountStore.selectAccount(id: fixture.work.id)
        viewModel.reloadAccounts()

        XCTAssertEqual(viewModel.selectedAccount(for: .codex).id, fixture.work.id)
        XCTAssertEqual(viewModel.snapshots[.codex]?.fetchedAt, workSnapshot.fetchedAt)
        XCTAssertEqual(
            fixture.repository.projections[.codex]?.fetchedAt,
            workSnapshot.fetchedAt
        )
        XCTAssertEqual(
            viewModel.snapshot(for: fixture.personal.id)?.fetchedAt,
            personalSnapshot.fetchedAt
        )
        XCTAssertEqual(
            viewModel.snapshot(for: fixture.work.id)?.fetchedAt,
            workSnapshot.fetchedAt
        )
    }

    func testExactAccountRefreshDoesNotPublishNonselectedSibling() async throws {
        let fetcher = RecordingAccountCCUsageFetcher()
        let fixture = try makeFixture(fetcher: fetcher)
        defer { fixture.cleanup() }
        let viewModel = fixture.makeViewModel()

        await viewModel.refreshNow(for: fixture.work)

        XCTAssertEqual(fetcher.requestedAccountIDs, [fixture.work.id])
        XCTAssertEqual(
            fixture.repository.savedAccountIDs,
            [fixture.work.id]
        )
        XCTAssertNotNil(viewModel.snapshot(for: fixture.work.id))
        XCTAssertNil(viewModel.snapshots[.codex])
        XCTAssertNil(fixture.repository.projections[.codex])

        await viewModel.refreshNow(for: fixture.personal)

        XCTAssertEqual(
            fetcher.requestedAccountIDs,
            [fixture.work.id, fixture.personal.id]
        )
        XCTAssertEqual(
            viewModel.snapshots[.codex]?.fetchedAt,
            fetcher.snapshotDate(for: fixture.personal.id)
        )
        XCTAssertEqual(
            fixture.repository.projections[.codex]?.fetchedAt,
            fetcher.snapshotDate(for: fixture.personal.id)
        )
    }

    func testAutoRefreshVisitsEveryEnabledAccountWithEnabledMaster() async throws {
        let fetcher = RecordingAccountCCUsageFetcher()
        let fixture = try makeFixture(fetcher: fetcher)
        defer { fixture.cleanup() }
        let disabled = try fixture.accountStore.addAccount(
            provider: .chatgptCodex,
            label: "Disabled",
            cliDataRoot: "/tmp/agentlimits-disabled"
        )
        try fixture.accountStore.updateAccount(
            disabled.updating(
                label: disabled.label,
                isEnabled: false,
                cliDataRoot: disabled.cliDataRoot
            )
        )
        let viewModel = fixture.makeViewModel()
        viewModel.updateSettings(
            CCUsageSettings(
                provider: .codex,
                isEnabled: true,
                additionalArgs: ""
            )
        )

        await viewModel.refreshEnabledProviders()

        XCTAssertEqual(
            Set(fetcher.requestedAccountIDs),
            Set([fixture.personal.id, fixture.work.id])
        )
        XCTAssertFalse(fetcher.requestedAccountIDs.contains(disabled.id))
    }

    func testSecondaryAccountWithoutRootBlocksCLIInvocation() async throws {
        let fetcher = RecordingAccountCCUsageFetcher()
        let fixture = try makeFixture(
            fetcher: fetcher,
            workRoot: nil
        )
        defer { fixture.cleanup() }
        let viewModel = fixture.makeViewModel()

        await viewModel.refreshNow(for: fixture.personal)

        XCTAssertTrue(fetcher.requestedAccountIDs.isEmpty)
        XCTAssertTrue(
            viewModel.statusMessage(for: fixture.personal.id)
                .contains("Work needs a unique Codex CLI data root")
        )
    }

    func testNormalizedDuplicateRootsBlockCLIInvocation() async throws {
        let fetcher = RecordingAccountCCUsageFetcher()
        let fixture = try makeFixture(
            fetcher: fetcher,
            personalRoot: "/tmp/agentlimits-root/../shared",
            workRoot: "/tmp/shared"
        )
        defer { fixture.cleanup() }
        let viewModel = fixture.makeViewModel()

        await viewModel.refreshNow(for: fixture.work)

        XCTAssertTrue(fetcher.requestedAccountIDs.isEmpty)
        XCTAssertTrue(
            viewModel.statusMessage(for: fixture.work.id)
                .contains("use the same Codex CLI data root")
        )
    }

    func testExplicitDefaultRootConflictsWithImplicitPrimary() async throws {
        let cases: [(UsageProvider, String, String)] = [
            (.chatgptCodex, "~/.codex", "Codex"),
            (.claudeCode, "~/.claude", "Claude Code"),
            (.claudeCode, "~/.config/claude", "Claude Code")
        ]

        for (usageProvider, root, displayName) in cases {
            let fetcher = RecordingAccountCCUsageFetcher()
            let fixture = try makeFixture(
                fetcher: fetcher,
                usageProvider: usageProvider,
                workRoot: root
            )
            defer { fixture.cleanup() }
            let viewModel = fixture.makeViewModel()
            let tokenProvider = try XCTUnwrap(
                usageProvider.tokenUsageProvider
            )

            await viewModel.refreshNow(for: fixture.work)

            XCTAssertTrue(fetcher.requestedAccountIDs.isEmpty, root)
            let status = viewModel.statusMessage(for: fixture.work.id)
            XCTAssertTrue(
                status.contains(
                    "uses \(displayName)'s default CLI data root"
                ),
                "\(root): \(status)"
            )
            XCTAssertNil(viewModel.snapshots[tokenProvider], root)
        }
    }

    func testValidDistinctRootsReachExactAccountFetcher() async throws {
        let fetcher = RecordingAccountCCUsageFetcher()
        let fixture = try makeFixture(
            fetcher: fetcher,
            personalRoot: nil,
            workRoot: "/tmp/agentlimits-work"
        )
        defer { fixture.cleanup() }
        let viewModel = fixture.makeViewModel()

        await viewModel.refreshNow(for: fixture.work)

        XCTAssertEqual(fetcher.requestedAccountIDs, [fixture.work.id])
        XCTAssertEqual(fetcher.requestedRoots, ["/tmp/agentlimits-work"])
    }

    func testRootMetadataChangeInvalidatesSuspendedFetch() async throws {
        let fetcher = SuspendingAccountCCUsageFetcher()
        let fixture = try makeFixture(fetcher: fetcher)
        defer { fixture.cleanup() }
        fixture.repository.snapshots[fixture.work.id] = makeSnapshot(
            provider: .codex,
            fetchedAt: 250
        )
        let viewModel = fixture.makeViewModel()
        XCTAssertNotNil(viewModel.snapshot(for: fixture.work.id))
        let oldTask = Task {
            await viewModel.refreshNow(for: fixture.work)
        }
        await fetcher.waitForRequestCount(1)

        try fixture.accountStore.updateAccount(
            fixture.work.updating(
                label: fixture.work.label,
                isEnabled: fixture.work.isEnabled,
                cliDataRoot: "/tmp/agentlimits-work-new"
            )
        )
        viewModel.reloadAccounts()
        fetcher.completeFirst(
            with: makeSnapshot(provider: .codex, fetchedAt: 300)
        )
        await oldTask.value

        XCTAssertTrue(fixture.repository.savedAccountIDs.isEmpty)
        XCTAssertTrue(
            fixture.repository.deletionAttempts.contains(fixture.work.id)
        )
        XCTAssertNil(viewModel.snapshot(for: fixture.work.id))
        XCTAssertFalse(viewModel.isFetching(for: fixture.work.id))
    }

    func testSiblingFetchesCompleteIndependentlyAndSelectedFacadeStaysExact()
        async throws {
        let fetcher = SuspendingAccountCCUsageFetcher()
        let fixture = try makeFixture(fetcher: fetcher)
        defer { fixture.cleanup() }
        let viewModel = fixture.makeViewModel()
        let personalTask = Task {
            await viewModel.refreshNow(for: fixture.personal)
        }
        let workTask = Task {
            await viewModel.refreshNow(for: fixture.work)
        }
        await fetcher.waitForRequestCount(2)

        fetcher.complete(
            accountID: fixture.work.id,
            with: makeSnapshot(provider: .codex, fetchedAt: 400)
        )
        fetcher.complete(
            accountID: fixture.personal.id,
            with: makeSnapshot(provider: .codex, fetchedAt: 500)
        )
        await personalTask.value
        await workTask.value

        XCTAssertEqual(
            viewModel.snapshot(for: fixture.work.id)?.fetchedAt,
            Date(timeIntervalSince1970: 400)
        )
        XCTAssertEqual(
            viewModel.snapshot(for: fixture.personal.id)?.fetchedAt,
            Date(timeIntervalSince1970: 500)
        )
        XCTAssertEqual(
            viewModel.snapshots[.codex]?.fetchedAt,
            Date(timeIntervalSince1970: 500)
        )
        XCTAssertEqual(
            fixture.repository.projections[.codex]?.fetchedAt,
            Date(timeIntervalSince1970: 500)
        )
    }

    func testExternalSiblingSaveUsesCapturedAccountAndPublishesOnlySelected()
        throws {
        let fixture = try makeFixture(
            usageProvider: .githubCopilot,
            workRoot: nil
        )
        defer { fixture.cleanup() }
        let viewModel = fixture.makeViewModel()
        viewModel.updateSettings(
            CCUsageSettings(
                provider: .copilot,
                isEnabled: true,
                additionalArgs: ""
            )
        )
        let workContext = try XCTUnwrap(
            viewModel.captureExternalSnapshotContext(for: fixture.work)
        )
        let workSnapshot = makeSnapshot(provider: .copilot, fetchedAt: 600)

        XCTAssertTrue(
            try viewModel.saveExternallyFetchedSnapshot(
                workSnapshot,
                context: workContext
            )
        )
        XCTAssertEqual(
            fixture.repository.snapshots[fixture.work.id]?.fetchedAt,
            workSnapshot.fetchedAt
        )
        XCTAssertNil(fixture.repository.projections[.copilot])
        XCTAssertNil(viewModel.snapshots[.copilot])

        let personalContext = try XCTUnwrap(
            viewModel.captureExternalSnapshotContext(for: fixture.personal)
        )
        let personalSnapshot = makeSnapshot(
            provider: .copilot,
            fetchedAt: 700
        )
        XCTAssertTrue(
            try viewModel.saveExternallyFetchedSnapshot(
                personalSnapshot,
                context: personalContext
            )
        )
        XCTAssertEqual(
            fixture.repository.projections[.copilot]?.fetchedAt,
            personalSnapshot.fetchedAt
        )
    }

    func testAnySettingsChangeInvalidatesExternalContext() throws {
        let fixture = try makeFixture(
            usageProvider: .githubCopilot,
            workRoot: nil
        )
        defer { fixture.cleanup() }
        let viewModel = fixture.makeViewModel()
        viewModel.updateSettings(
            CCUsageSettings(
                provider: .copilot,
                isEnabled: true,
                additionalArgs: ""
            )
        )
        let context = try XCTUnwrap(
            viewModel.captureExternalSnapshotContext(for: fixture.personal)
        )

        viewModel.updateSettings(
            CCUsageSettings(
                provider: .copilot,
                isEnabled: true,
                additionalArgs: "--timezone UTC"
            )
        )

        XCTAssertFalse(
            try viewModel.saveExternallyFetchedSnapshot(
                makeSnapshot(provider: .copilot, fetchedAt: 800),
                context: context
            )
        )
        XCTAssertNil(fixture.repository.snapshots[fixture.personal.id])
    }

    func testClearDeletesEveryAccountNamespaceAndEveryProjection() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let claude = fixture.accountStore.selectedAccount(for: .claudeCode)
        let copilot = fixture.accountStore.selectedAccount(for: .githubCopilot)
        fixture.repository.snapshots = [
            fixture.personal.id: makeSnapshot(provider: .codex, fetchedAt: 1),
            fixture.work.id: makeSnapshot(provider: .codex, fetchedAt: 2),
            claude.id: makeSnapshot(provider: .claude, fetchedAt: 3),
            copilot.id: makeSnapshot(provider: .copilot, fetchedAt: 4)
        ]
        fixture.repository.deletionErrors[fixture.work.id] = TestTokenError.delete
        let viewModel = fixture.makeViewModel()
        let clearToken = try XCTUnwrap(viewModel.beginDataClear())

        let failures = viewModel.clearAllSnapshots(during: clearToken)

        XCTAssertTrue(viewModel.finishDataClear(clearToken))
        XCTAssertEqual(
            Set(fixture.repository.deletionAttempts),
            Set([fixture.personal.id, fixture.work.id, claude.id, copilot.id])
        )
        XCTAssertEqual(
            Set(fixture.repository.projectionDeletionAttempts),
            Set(TokenUsageProvider.allCases)
        )
        XCTAssertEqual(failures.count, 1)
        XCTAssertEqual(failures[0].accountID, fixture.work.id)
        XCTAssertEqual(failures[0].accountLabel, "Work")
        XCTAssertEqual(
            failures[0].targetDescription,
            "Codex — Work"
        )
        XCTAssertNil(viewModel.snapshot(for: fixture.personal.id))
        XCTAssertNil(viewModel.snapshot(for: fixture.work.id))
        XCTAssertNil(viewModel.snapshots[.codex])
    }

    func testClearRetriesForAccountRegisteredByDeletionHook() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        var addedAccount: ProviderAccount?
        fixture.repository.onDelete = { _ in
            guard addedAccount == nil else { return }
            addedAccount = try? fixture.accountStore.addAccount(
                provider: .chatgptCodex,
                label: "Late",
                cliDataRoot: "/tmp/agentlimits-late"
            )
        }
        let viewModel = fixture.makeViewModel()
        let clearToken = try XCTUnwrap(viewModel.beginDataClear())

        let failures = viewModel.clearAllSnapshots(during: clearToken)

        XCTAssertTrue(failures.isEmpty)
        XCTAssertTrue(viewModel.finishDataClear(clearToken))
        let lateID = try XCTUnwrap(addedAccount?.id)
        XCTAssertTrue(
            fixture.repository.deletionAttempts.contains(lateID)
        )
        XCTAssertNil(viewModel.snapshot(for: lateID))
    }

    func testPrepareAndRestoreProjectionFailClosed() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let snapshot = makeSnapshot(provider: .codex, fetchedAt: 900)
        fixture.repository.snapshots[fixture.personal.id] = snapshot
        let viewModel = fixture.makeViewModel()

        try viewModel.prepareSelectedProjectionRemoval(for: fixture.personal)
        XCTAssertNil(fixture.repository.projections[.codex])

        try viewModel.restoreSelectedProjection(for: fixture.personal)
        XCTAssertEqual(
            fixture.repository.projections[.codex]?.fetchedAt,
            snapshot.fetchedAt
        )
    }

    func testIndeterminateProjectionRemovalPreservesSourceUntilRetry()
        throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let legacySnapshot = makeSnapshot(provider: .codex, fetchedAt: 901)
        let identity = RecordingSnapshotIdentity(
            accountID: fixture.personal.id,
            provider: .codex
        )
        fixture.repository.projections[.codex] = legacySnapshot
        fixture.repository.indeterminateLoadIdentities.insert(identity)

        let viewModel = fixture.makeViewModel()

        XCTAssertTrue(
            fixture.repository.suppressedProjectionProviders.contains(.codex)
        )
        XCTAssertEqual(
            fixture.repository.projections[.codex]?.fetchedAt,
            legacySnapshot.fetchedAt
        )
        XCTAssertThrowsError(
            try viewModel.prepareSelectedProjectionRemoval(
                for: fixture.personal
            )
        ) { error in
            XCTAssertEqual(
                error as? AccountTokenUsageConfigurationError,
                .indeterminateSnapshot(
                    provider: .codex,
                    accountLabel: fixture.personal.label
                )
            )
        }
        XCTAssertNoThrow(
            try viewModel.restoreSelectedProjection(for: fixture.personal)
        )
        XCTAssertEqual(
            fixture.accountStore.selectedAccount(for: .chatgptCodex).id,
            fixture.personal.id
        )
        XCTAssertEqual(
            fixture.repository.projections[.codex]?.fetchedAt,
            legacySnapshot.fetchedAt
        )
        XCTAssertTrue(
            fixture.repository.suppressedProjectionProviders.contains(.codex)
        )

        fixture.repository.indeterminateLoadIdentities.remove(identity)
        fixture.repository.snapshots[fixture.personal.id] = legacySnapshot
        _ = fixture.makeViewModel()

        XCTAssertEqual(
            fixture.repository.projections[.codex]?.fetchedAt,
            legacySnapshot.fetchedAt
        )
        XCTAssertFalse(
            fixture.repository.suppressedProjectionProviders.contains(.codex)
        )
    }

    func testFutureAccountRegistryNeverUsesPlaceholderNamespaces() async throws {
        let suiteName =
            "TokenUsageFutureRegistryTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let payload: [String: Any] = [
            "version": 999,
            "accounts": [],
            "pendingWebKitDataStoreDeletionIDs": []
        ]
        defaults.set(
            try JSONSerialization.data(withJSONObject: payload),
            forKey: "accounts"
        )
        let accountStore = ProviderAccountStore(
            userDefaults: defaults,
            key: "accounts"
        )
        let repository = RecordingTokenSnapshotRepository()
        let fetcher = RecordingAccountCCUsageFetcher()
        let viewModel = TokenUsageViewModel(
            fetcher: fetcher,
            snapshotRepository: repository,
            accountStore: accountStore,
            settingsStore: CCUsageSettingsStore(userDefaults: defaults)
        )
        viewModel.updateSettings(
            CCUsageSettings(
                provider: .codex,
                isEnabled: true,
                additionalArgs: ""
            )
        )

        await viewModel.refreshNow(for: .codex)

        XCTAssertTrue(repository.loadAttempts.isEmpty)
        XCTAssertTrue(repository.projectionPublishAttempts.isEmpty)
        XCTAssertTrue(fetcher.requestedAccountIDs.isEmpty)
        XCTAssertNil(viewModel.snapshots[.codex])
        XCTAssertTrue(
            viewModel.statusMessages[.codex]?
                .contains("newer AgentLimits version") == true
        )
    }

    private func makeFixture(
        fetcher: (any CCUsageFetching)? = nil,
        usageProvider: UsageProvider = .chatgptCodex,
        personalRoot: String? = nil,
        workRoot: String? = "/tmp/agentlimits-work"
    ) throws -> TokenAccountFixture {
        let suiteName =
            "TokenUsageAccountIsolationTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let accountStore = ProviderAccountStore(
            userDefaults: defaults,
            key: "accounts"
        )
        let initialPersonal = accountStore.selectedAccount(for: usageProvider)
        if personalRoot != nil {
            try accountStore.updateAccount(
                initialPersonal.updating(
                    label: initialPersonal.label,
                    isEnabled: initialPersonal.isEnabled,
                    cliDataRoot: personalRoot
                )
            )
        }
        let personal = accountStore.selectedAccount(for: usageProvider)
        let work = try accountStore.addAccount(
            provider: usageProvider,
            label: "Work",
            cliDataRoot: workRoot
        )
        return TokenAccountFixture(
            suiteName: suiteName,
            defaults: defaults,
            accountStore: accountStore,
            personal: personal,
            work: work,
            repository: RecordingTokenSnapshotRepository(),
            fetcher: fetcher
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
}

private struct TestProviderRegistryPayload: Codable {
    let version: Int
    let accounts: [ProviderAccount]
    let pendingWebKitDataStoreDeletionIDs: [UUID]
}

private struct RecordingSnapshotIdentity: Hashable {
    let accountID: UUID
    let provider: TokenUsageProvider
}

@MainActor
private struct TokenAccountFixture {
    let suiteName: String
    let defaults: UserDefaults
    let accountStore: ProviderAccountStore
    let personal: ProviderAccount
    let work: ProviderAccount
    let repository: RecordingTokenSnapshotRepository
    let fetcher: (any CCUsageFetching)?

    func makeViewModel() -> TokenUsageViewModel {
        TokenUsageViewModel(
            fetcher: fetcher,
            snapshotRepository: repository,
            accountStore: accountStore,
            settingsStore: CCUsageSettingsStore(userDefaults: defaults)
        )
    }

    func cleanup() {
        defaults.removePersistentDomain(forName: suiteName)
    }
}

@MainActor
private final class RecordingTokenSnapshotRepository:
    AccountTokenUsageSnapshotRepository {
    var snapshots: [UUID: TokenUsageSnapshot] = [:]
    var additionalSnapshots:
        [UUID: [TokenUsageProvider: TokenUsageSnapshot]] = [:]
    var projections: [TokenUsageProvider: TokenUsageSnapshot] = [:]
    var deletionErrors: [UUID: Error] = [:]
    var onDelete: ((ProviderAccount) -> Void)?
    var indeterminateLoadIdentities: Set<RecordingSnapshotIdentity> = []
    var suppressedProjectionProviders: Set<TokenUsageProvider> = []
    private(set) var savedAccountIDs: [UUID] = []
    private(set) var loadAttempts: [UUID] = []
    private(set) var deletionAttempts: [UUID] = []
    private(set) var deletionProviderAttempts:
        [RecordingSnapshotIdentity] = []
    private(set) var projectionDeletionAttempts: [TokenUsageProvider] = []
    private(set) var projectionPublishAttempts: [TokenUsageProvider] = []
    private var suppressedAccountIDs: Set<UUID> = []

    func loadSnapshot(for account: ProviderAccount) -> TokenUsageSnapshot? {
        loadAttempts.append(account.id)
        guard !suppressedAccountIDs.contains(account.id),
              let provider = account.provider.tokenUsageProvider else {
            return nil
        }
        if snapshots[account.id]?.provider == provider {
            return snapshots[account.id]
        }
        return additionalSnapshots[account.id]?[provider]
    }

    func canSafelyPublishMissingSnapshot(
        for account: ProviderAccount
    ) -> Bool {
        guard let provider = account.provider.tokenUsageProvider else {
            return true
        }
        return !indeterminateLoadIdentities.contains(
            RecordingSnapshotIdentity(
                accountID: account.id,
                provider: provider
            )
        )
    }

    func setSelectedProjectionSuppressed(
        _ isSuppressed: Bool,
        for account: ProviderAccount
    ) {
        guard let provider = account.provider.tokenUsageProvider else { return }
        if isSuppressed {
            suppressedProjectionProviders.insert(provider)
        } else {
            suppressedProjectionProviders.remove(provider)
        }
    }

    func saveSnapshot(
        _ snapshot: TokenUsageSnapshot,
        for account: ProviderAccount
    ) throws {
        guard snapshot.provider == account.provider.tokenUsageProvider else {
            throw AccountTokenUsageSnapshotRepositoryError.providerMismatch
        }
        savedAccountIDs.append(account.id)
        snapshots[account.id] = snapshot
        additionalSnapshots[account.id]?.removeValue(
            forKey: snapshot.provider
        )
        suppressedAccountIDs.remove(account.id)
    }

    func deleteSnapshot(for account: ProviderAccount) throws {
        deletionAttempts.append(account.id)
        guard let provider = account.provider.tokenUsageProvider else {
            throw AccountTokenUsageSnapshotRepositoryError.providerMismatch
        }
        deletionProviderAttempts.append(
            RecordingSnapshotIdentity(
                accountID: account.id,
                provider: provider
            )
        )
        onDelete?(account)
        if let error = deletionErrors[account.id] {
            throw error
        }
        if snapshots[account.id]?.provider == provider {
            snapshots.removeValue(forKey: account.id)
        }
        additionalSnapshots[account.id]?.removeValue(forKey: provider)
    }

    func setSnapshotSuppressed(
        _ isSuppressed: Bool,
        for account: ProviderAccount
    ) {
        if isSuppressed {
            suppressedAccountIDs.insert(account.id)
        } else {
            suppressedAccountIDs.remove(account.id)
        }
    }

    func publishSelectedSnapshot(
        _ snapshot: TokenUsageSnapshot?,
        for account: ProviderAccount
    ) throws {
        guard let provider = account.provider.tokenUsageProvider else {
            throw AccountTokenUsageSnapshotRepositoryError.providerMismatch
        }
        suppressedProjectionProviders.insert(provider)
        projectionPublishAttempts.append(provider)
        if let snapshot {
            guard snapshot.provider == provider else {
                throw AccountTokenUsageSnapshotRepositoryError.providerMismatch
            }
            projections[provider] = snapshot
        } else {
            projectionDeletionAttempts.append(provider)
            projections.removeValue(forKey: provider)
        }
        suppressedProjectionProviders.remove(provider)
    }
}

@MainActor
private final class RecordingAccountCCUsageFetcher: CCUsageFetching {
    private(set) var requestedAccountIDs: [UUID] = []
    private(set) var requestedRoots: [String?] = []

    func fetchSnapshot(
        for provider: TokenUsageProvider
    ) async throws -> TokenUsageSnapshot {
        throw TestTokenError.providerFallbackUsed
    }

    func fetchSnapshot(
        for account: ProviderAccount
    ) async throws -> TokenUsageSnapshot {
        guard let provider = account.provider.tokenUsageProvider else {
            throw TestTokenError.providerFallbackUsed
        }
        requestedAccountIDs.append(account.id)
        requestedRoots.append(account.cliDataRoot)
        return TokenUsageSnapshot(
            provider: provider,
            fetchedAt: snapshotDate(for: account.id),
            today: TokenUsagePeriod(costUSD: 1, totalTokens: 1),
            thisWeek: TokenUsagePeriod(costUSD: 1, totalTokens: 1),
            thisMonth: TokenUsagePeriod(costUSD: 1, totalTokens: 1)
        )
    }

    func snapshotDate(for accountID: UUID) -> Date {
        let bytes = accountID.uuid
        let value = TimeInterval(Int(bytes.0) + Int(bytes.15) + 1_000)
        return Date(timeIntervalSince1970: value)
    }
}

@MainActor
private final class SuspendingAccountCCUsageFetcher: CCUsageFetching {
    private struct PendingRequest {
        let account: ProviderAccount
        let continuation: CheckedContinuation<TokenUsageSnapshot, Error>
    }

    private var requests: [PendingRequest] = []

    func fetchSnapshot(
        for provider: TokenUsageProvider
    ) async throws -> TokenUsageSnapshot {
        throw TestTokenError.providerFallbackUsed
    }

    func fetchSnapshot(
        for account: ProviderAccount
    ) async throws -> TokenUsageSnapshot {
        try await withCheckedThrowingContinuation { continuation in
            requests.append(
                PendingRequest(account: account, continuation: continuation)
            )
        }
    }

    func waitForRequestCount(_ count: Int) async {
        while requests.count < count {
            await Task.yield()
        }
    }

    func completeFirst(with snapshot: TokenUsageSnapshot) {
        requests.removeFirst().continuation.resume(returning: snapshot)
    }

    func complete(accountID: UUID, with snapshot: TokenUsageSnapshot) {
        guard let index = requests.firstIndex(where: {
            $0.account.id == accountID
        }) else {
            XCTFail("Missing request for \(accountID)")
            return
        }
        requests.remove(at: index).continuation.resume(returning: snapshot)
    }
}

private enum TestTokenError: LocalizedError {
    case delete
    case providerFallbackUsed

    var errorDescription: String? {
        switch self {
        case .delete:
            return "Token snapshot deletion failed"
        case .providerFallbackUsed:
            return "Provider fallback unexpectedly used"
        }
    }
}
