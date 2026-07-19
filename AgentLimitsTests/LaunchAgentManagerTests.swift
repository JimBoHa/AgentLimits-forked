import Foundation
import XCTest
@testable import AgentLimits

@MainActor
final class LaunchAgentManagerTests: XCTestCase {
    func testFailedBootstrapThrowsAndRemovesNewPlist() throws {
        let context = makeContext()
        defer { context.cleanup() }
        context.launchCtl.bootstrapStatuses = [5]

        XCTAssertThrowsError(try context.manager.install(schedule: context.schedule)) { error in
            XCTAssertTrue(error.localizedDescription.contains("Input/output error"))
        }
        XCTAssertFalse(context.manager.isInstalled(for: context.schedule))
        XCTAssertFalse(context.manager.isPlistPresent(for: context.schedule))
    }

    func testFailedUpdateRestoresPreviousPlistAndService() throws {
        let context = makeContext(initiallyLoaded: true)
        defer { context.cleanup() }
        let previousData = try context.seedPreviousPlist()
        context.launchCtl.bootstrapStatuses = [78, 0]

        XCTAssertThrowsError(try context.manager.install(schedule: context.schedule))
        XCTAssertEqual(try context.plistData(), previousData)
        XCTAssertTrue(context.launchCtl.isLoaded)
        XCTAssertTrue(context.manager.isInstalled(for: context.schedule))
        XCTAssertEqual(context.launchCtl.bootstrapCallCount, 2)
    }

    func testStatus37IsFailureRatherThanFalseSuccess() throws {
        let context = makeContext()
        defer { context.cleanup() }
        context.launchCtl.bootstrapStatuses = [37]

        XCTAssertThrowsError(try context.manager.install(schedule: context.schedule))
        XCTAssertFalse(context.manager.isInstalled(for: context.schedule))
        XCTAssertFalse(context.manager.isPlistPresent(for: context.schedule))
    }

    func testLoadedOrphanIsStoppedWhenReplacementFails() throws {
        let context = makeContext(initiallyLoaded: true)
        defer { context.cleanup() }
        context.launchCtl.bootstrapStatuses = [37]

        XCTAssertThrowsError(try context.manager.install(schedule: context.schedule))
        XCTAssertFalse(context.launchCtl.isLoaded)
        XCTAssertFalse(context.manager.isPlistPresent(for: context.schedule))
        XCTAssertEqual(context.launchCtl.bootoutCallCount, 1)
    }

    func testBootoutFailureKeepsPriorServiceAndPlist() throws {
        let context = makeContext(initiallyLoaded: true)
        defer { context.cleanup() }
        let previousData = try context.seedPreviousPlist()
        context.launchCtl.bootoutStatuses = [5]

        XCTAssertThrowsError(try context.manager.install(schedule: context.schedule))
        XCTAssertEqual(try context.plistData(), previousData)
        XCTAssertTrue(context.launchCtl.isLoaded)
        XCTAssertTrue(context.manager.isInstalled(for: context.schedule))
        XCTAssertEqual(context.launchCtl.bootstrapCallCount, 1)
    }

    func testRollbackLoadFailureDoesNotReportInstalled() throws {
        let context = makeContext(initiallyLoaded: true)
        defer { context.cleanup() }
        let previousData = try context.seedPreviousPlist()
        context.launchCtl.bootstrapStatuses = [78, 79]

        XCTAssertThrowsError(try context.manager.install(schedule: context.schedule)) { error in
            XCTAssertTrue(error.localizedDescription.contains("rollback also failed"))
        }
        XCTAssertEqual(try context.plistData(), previousData)
        XCTAssertFalse(context.launchCtl.isLoaded)
        XCTAssertFalse(context.manager.isInstalled(for: context.schedule))
    }

    func testUninstallFailureLeavesConfigurationInPlace() throws {
        let context = makeContext(initiallyLoaded: true)
        defer { context.cleanup() }
        let previousData = try context.seedPreviousPlist()
        context.launchCtl.bootoutStatuses = [5]

        XCTAssertThrowsError(try context.manager.uninstall(schedule: context.schedule))
        XCTAssertEqual(try context.plistData(), previousData)
        XCTAssertTrue(context.launchCtl.isLoaded)
    }

    func testAmbiguousPrintFailurePreservesConfiguration() throws {
        let context = makeContext(initiallyLoaded: true)
        defer { context.cleanup() }
        let previousData = try context.seedPreviousPlist()
        context.launchCtl.bootoutStatuses = [5]
        context.launchCtl.printStatuses = [5]

        XCTAssertThrowsError(try context.manager.uninstall(schedule: context.schedule))
        XCTAssertEqual(try context.plistData(), previousData)
        XCTAssertTrue(context.launchCtl.isLoaded)
    }

    func testPlistRemovalFailureReloadsPriorService() throws {
        let context = makeContext(removeItem: { _ in
            throw CocoaError(.fileWriteNoPermission)
        })
        defer { context.cleanup() }
        let previousData = try context.seedPreviousPlist()

        XCTAssertThrowsError(try context.manager.uninstall(schedule: context.schedule))
        XCTAssertEqual(try context.plistData(), previousData)
        XCTAssertTrue(context.launchCtl.isLoaded)
        XCTAssertTrue(context.manager.isInstalled(for: context.schedule))
        XCTAssertEqual(context.launchCtl.bootstrapCallCount, 1)
    }

    func testConfirmedAbsentServiceCanBeUninstalled() throws {
        let context = makeContext(initiallyLoaded: false)
        defer { context.cleanup() }
        _ = try context.seedPreviousPlist()
        context.launchCtl.bootoutStatuses = [3]

        XCTAssertNoThrow(try context.manager.uninstall(schedule: context.schedule))
        XCTAssertFalse(context.manager.isPlistPresent(for: context.schedule))
    }

    func testSchedulerDoesNotPersistFailedRequestedSchedule() {
        let context = makeContext()
        defer { context.cleanup() }
        context.launchCtl.bootstrapStatuses = [5]
        let defaults = UserDefaults(
            suiteName: "LaunchAgentManagerTests-\(UUID().uuidString)"
        )!
        let store = WakeUpScheduleStore(userDefaults: defaults)
        let scheduler = WakeUpScheduler(
            launchAgentManager: context.manager,
            store: store,
            syncOnInit: false
        )
        var requested = context.schedule
        requested.enabledHours = [9, 17]

        scheduler.updateSchedule(requested)

        XCTAssertEqual(
            scheduler.schedules[requested.provider],
            .defaultSchedule(for: requested.provider)
        )
        XCTAssertEqual(
            store.loadSchedules()[requested.provider],
            .defaultSchedule(for: requested.provider)
        )
        XCTAssertNotNil(scheduler.scheduleErrors[requested.provider])
    }

    func testSchedulerCommitsSuccessfulRequestedSchedule() {
        let context = makeContext()
        defer { context.cleanup() }
        context.launchCtl.bootstrapStatuses = [0]
        let defaults = UserDefaults(
            suiteName: "LaunchAgentManagerTests-\(UUID().uuidString)"
        )!
        let store = WakeUpScheduleStore(userDefaults: defaults)
        let scheduler = WakeUpScheduler(
            launchAgentManager: context.manager,
            store: store,
            syncOnInit: false
        )

        scheduler.updateSchedule(context.schedule)

        XCTAssertEqual(scheduler.schedules[context.schedule.provider], context.schedule)
        XCTAssertEqual(store.loadSchedules()[context.schedule.provider], context.schedule)
        XCTAssertNil(scheduler.scheduleErrors[context.schedule.provider])
    }

    func testInstallUsesPrivateUserOwnedLogDirectory() throws {
        let context = makeContext()
        defer { context.cleanup() }

        try context.manager.install(schedule: context.schedule)

        let logURL = context.manager.logURL(for: context.schedule)
        let attributes = try FileManager.default.attributesOfItem(
            atPath: logURL.deletingLastPathComponent().path
        )
        let permissions = try XCTUnwrap(
            attributes[.posixPermissions] as? NSNumber
        ).intValue & 0o777
        XCTAssertEqual(permissions, 0o700)
        XCTAssertTrue(
            logURL.path.hasPrefix(
                context.home.path + "/Library/Logs/AgentLimitsForked/"
            )
        )

        let plist = try XCTUnwrap(
            try PropertyListSerialization.propertyList(
                from: context.plistData(),
                format: nil
            ) as? [String: Any]
        )
        XCTAssertEqual(plist["StandardOutPath"] as? String, logURL.path)
        XCTAssertEqual(plist["StandardErrorPath"] as? String, logURL.path)
        let workingDirectory = WakeUpWorkingDirectoryResolver.workingDirectory(
            homeDirectory: context.home
        )
        let workingAttributes = try FileManager.default.attributesOfItem(
            atPath: workingDirectory.path
        )
        let workingPermissions = try XCTUnwrap(
            workingAttributes[.posixPermissions] as? NSNumber
        ).intValue & 0o777
        XCTAssertEqual(workingPermissions, 0o700)
        let programArguments = try XCTUnwrap(plist["ProgramArguments"] as? [String])
        XCTAssertEqual(
            Array(programArguments.prefix(3)),
            ["/bin/zsh", "-f", "-c"]
        )
    }

    func testInstallRejectsSymlinkedLogDirectory() throws {
        let context = makeContext()
        defer { context.cleanup() }
        let logsParent = context.home.appendingPathComponent("Library/Logs")
        let redirectedLogs = context.home.appendingPathComponent("redirected-logs")
        try FileManager.default.createDirectory(
            at: logsParent,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: redirectedLogs,
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            at: logsParent.appendingPathComponent("AgentLimitsForked"),
            withDestinationURL: redirectedLogs
        )

        XCTAssertThrowsError(try context.manager.install(schedule: context.schedule)) { error in
            XCTAssertTrue(error.localizedDescription.contains("private, user-owned"))
        }
        XCTAssertFalse(context.manager.isPlistPresent(for: context.schedule))
    }

    func testInstallRejectsSymlinkedWorkingDirectory() throws {
        let context = makeContext()
        defer { context.cleanup() }
        let redirectedDirectory = context.home.appendingPathComponent("redirected-work")
        try FileManager.default.createDirectory(
            at: redirectedDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: context.home,
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            at: context.home.appendingPathComponent(".agentlimits-forked"),
            withDestinationURL: redirectedDirectory
        )

        XCTAssertThrowsError(try context.manager.install(schedule: context.schedule)) {
            XCTAssertTrue($0.localizedDescription.contains("private, user-owned"))
        }
        XCTAssertFalse(context.manager.isPlistPresent(for: context.schedule))
    }

    private func makeContext(
        initiallyLoaded: Bool = false,
        removeItem: ((URL) throws -> Void)? = nil
    ) -> TestContext {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentLimitsLaunchAgentTests-\(UUID().uuidString)")
        let launchCtl = FakeLaunchCtl(isLoaded: initiallyLoaded)
        let manager = LaunchAgentManager(
            homeDirectory: home,
            launchCtlRunner: launchCtl.run(arguments:),
            removeItem: removeItem
        )
        return TestContext(
            home: home,
            manager: manager,
            launchCtl: launchCtl,
            schedule: WakeUpSchedule(
                provider: .claudeCode,
                enabledHours: [9],
                isEnabled: true
            )
        )
    }
}

@MainActor
private struct TestContext {
    let home: URL
    let manager: LaunchAgentManager
    let launchCtl: FakeLaunchCtl
    let schedule: WakeUpSchedule

    func cleanup() {
        try? FileManager.default.removeItem(at: home)
    }

    func seedPreviousPlist() throws -> Data {
        let url = try XCTUnwrap(manager.plistURL(for: schedule))
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = Data("previous plist".utf8)
        try data.write(to: url)
        return data
    }

    func plistData() throws -> Data {
        let url = try XCTUnwrap(manager.plistURL(for: schedule))
        return try Data(contentsOf: url)
    }
}

@MainActor
private final class FakeLaunchCtl {
    var isLoaded: Bool
    var bootstrapStatuses: [Int32] = []
    var bootoutStatuses: [Int32] = []
    var printStatuses: [Int32] = []
    private(set) var invocations: [[String]] = []

    var bootstrapCallCount: Int {
        invocations.filter { $0.first == "bootstrap" }.count
    }

    var bootoutCallCount: Int {
        invocations.filter { $0.first == "bootout" }.count
    }

    init(isLoaded: Bool) {
        self.isLoaded = isLoaded
    }

    func run(arguments: [String]) -> LaunchCtlResult {
        invocations.append(arguments)
        switch arguments.first {
        case "bootstrap":
            let status = bootstrapStatuses.isEmpty ? 0 : bootstrapStatuses.removeFirst()
            if status == 0 {
                isLoaded = true
            }
            return result(status)
        case "bootout":
            let status = bootoutStatuses.isEmpty ? 0 : bootoutStatuses.removeFirst()
            if status == 0 {
                isLoaded = false
            }
            return result(status)
        case "print":
            if !printStatuses.isEmpty {
                return result(printStatuses.removeFirst())
            }
            return result(isLoaded ? 0 : 113)
        default:
            return result(64)
        }
    }

    private func result(_ status: Int32) -> LaunchCtlResult {
        LaunchCtlResult(
            terminationStatus: status,
            standardError: status == 0 ? "" : "Input/output error"
        )
    }
}

private extension LaunchAgentManager {
    func isPlistPresent(for schedule: WakeUpSchedule) -> Bool {
        guard let url = plistURL(for: schedule) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }
}
