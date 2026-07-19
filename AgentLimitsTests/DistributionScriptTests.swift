import Foundation
import XCTest

final class DistributionScriptTests: XCTestCase {
    func testSigningConfigAcceptsOnlyCanonicalTeamAssignment() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = directory.appendingPathComponent("team.xcconfig")
        try Data("// local Team\n\nDEVELOPMENT_TEAM = ABCDE12345\n".utf8).write(to: config)
        try setPermissions(0o600, for: config)

        let result = try runSigningConfigValidator(config: config)

        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertTrue(result.output.contains("ABCDE12345"), result.output)
    }

    func testSigningConfigRejectsInjectedAndDuplicateSettings() throws {
        let invalidContents = [
            "DEVELOPMENT_TEAM = ABCDE12345\nOTHER_SWIFT_FLAGS = -DUNSAFE\n",
            "#include \"untrusted.xcconfig\"\nDEVELOPMENT_TEAM = ABCDE12345\n",
            "DEVELOPMENT_TEAM[sdk=macosx*] = ABCDE12345\n",
            "DEVELOPMENT_TEAM = ABCDE12345\nDEVELOPMENT_TEAM = ABCDE12345\n"
        ]

        for (index, contents) in invalidContents.enumerated() {
            let directory = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let config = directory.appendingPathComponent("invalid-\(index).xcconfig")
            try Data(contents.utf8).write(to: config)
            try setPermissions(0o600, for: config)

            let result = try runSigningConfigValidator(config: config)
            XCTAssertEqual(result.status, 78, result.output)
        }
    }

    func testSigningConfigRejectsSymlinkAndUnsafePermissions() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = directory.appendingPathComponent("team.xcconfig")
        let symlink = directory.appendingPathComponent("team-link.xcconfig")
        try Data("DEVELOPMENT_TEAM = ABCDE12345\n".utf8).write(to: config)
        try setPermissions(0o600, for: config)
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: config)

        let symlinkResult = try runSigningConfigValidator(config: symlink)
        XCTAssertEqual(symlinkResult.status, 78, symlinkResult.output)

        try setPermissions(0o622, for: config)
        let permissionsResult = try runSigningConfigValidator(config: config)
        XCTAssertEqual(permissionsResult.status, 78, permissionsResult.output)
    }

    func testSigningConfigMutationIsDetected() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = directory.appendingPathComponent("team.xcconfig")
        try Data("DEVELOPMENT_TEAM = ABCDE12345\n".utf8).write(to: config)
        try setPermissions(0o600, for: config)
        let command = #"source "$1"; validate_development_team_config "$2" || exit $?; expected_team="$validated_development_team"; expected_hash="$validated_development_team_config_hash"; printf 'DEVELOPMENT_TEAM = ZYXWV98765\n' >"$2"; verify_development_team_config_unchanged "$2" "$expected_team" "$expected_hash"; exit $?"#

        let result = try runSigningConfigValidator(config: config, command: command)

        XCTAssertEqual(result.status, 65, result.output)
        XCTAssertTrue(result.output.contains("changed while building"), result.output)
    }

    func testSignedReleaseScriptsUseCleanSnapshotAndRecheckConfig() throws {
        for name in ["package-macos.sh", "export-ios.sh"] {
            let script = try releaseScript(named: name)
            XCTAssertTrue(script.contains("source \"$script_dir/signing-config.sh\""), name)
            XCTAssertTrue(script.contains("git -C \"$project_root\" archive"), name)
            XCTAssertTrue(script.contains("$build_root/AgentLimits.xcodeproj"), name)
            XCTAssertTrue(
                script.contains("prepare_xcode_signing_environment \"$snapshot_config\""),
                name
            )
            XCTAssertTrue(script.contains("PATH=\"/usr/bin:/bin:/usr/sbin:/sbin\""), name)
            XCTAssertTrue(
                script.contains("verify_development_team_config_unchanged"),
                name
            )
        }
    }

    func testHostileXcodeEnvironmentIsReplaced() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = directory.appendingPathComponent("sanitized.xcconfig")
        try Data("DEVELOPMENT_TEAM = ABCDE12345\n".utf8).write(to: config)
        let command = #"source "$1"; export XCODE_XCCONFIG_FILE=/private/tmp/hostile.xcconfig; export TOOLCHAINS=hostile; export XCRUN_TOOLCHAIN_NAME=hostile; prepare_xcode_signing_environment "$2"; printf '%s\n%s\n%s\n' "$XCODE_XCCONFIG_FILE" "${TOOLCHAINS-unset}" "${XCRUN_TOOLCHAIN_NAME-unset}""#

        let result = try runSigningConfigValidator(config: config, command: command)

        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertEqual(
            result.output.split(separator: "\n").map(String.init),
            [config.path, "unset", "unset"]
        )
    }

    func testAcceptedNotaryLogsWithNullOrEmptyIssuesPass() throws {
        let lowercaseJobID = "2efe2717-52ef-43a5-96dc-0797e4ca1041"
        let uppercaseJobID = lowercaseJobID.uppercased()
        for issues in ["null", "[]"] {
            let directory = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let log = directory.appendingPathComponent("accepted.json")
            let json = #"{"jobId":"JOB_ID","status":"Accepted","statusCode":0,"issues":ISSUES}"#
                .replacingOccurrences(of: "JOB_ID", with: uppercaseJobID)
                .replacingOccurrences(of: "ISSUES", with: issues)
            try Data(json.utf8).write(to: log)

            let result = try runNotaryLogValidator(log: log, jobID: lowercaseJobID)
            XCTAssertEqual(result.status, 0, result.output)
        }
    }

    func testNotaryWarningsFailRelease() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = directory.appendingPathComponent("warning.json")
        let json = #"{"jobId":"job-123","status":"Accepted","statusCode":0,"issues":[{"severity":"warning","path":"AgentLimits.app","message":"Fix this warning"}]}"#
        try Data(json.utf8).write(to: log)

        let result = try runNotaryLogValidator(log: log, jobID: "job-123")

        XCTAssertEqual(result.status, 1, result.output)
        XCTAssertTrue(result.output.contains("Fix this warning"), result.output)
    }

    func testMalformedMismatchedAndRejectedNotaryLogsFail() throws {
        let fixtures = [
            #"{"jobId":"other-job","status":"Accepted","statusCode":0,"issues":null}"#,
            #"{"jobId":"job-123","status":"Rejected","statusCode":4000,"issues":null}"#,
            #"{"jobId":"job-123","status":"Accepted","statusCode":0}"#,
            "{"
        ]

        for (index, json) in fixtures.enumerated() {
            let directory = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let log = directory.appendingPathComponent("invalid-\(index).json")
            try Data(json.utf8).write(to: log)

            let result = try runNotaryLogValidator(log: log, jobID: "job-123")
            XCTAssertEqual(result.status, 1, result.output)
        }
    }

    func testMacPackageValidatesAcceptedNotaryLogBeforeStapling() throws {
        let script = try packageScript()
        let accepted = try offset(
            of: #"if [[ $submit_exit -ne 0 || "$status" != "Accepted" ]]"#,
            in: script
        )
        let validate = try offset(
            of: #"validate_accepted_notary_log "$log" "$submission_id""#,
            in: script
        )
        let staple = try offset(of: #"xcrun stapler staple "$app""#, in: script)

        XCTAssertLessThan(accepted, validate)
        XCTAssertLessThan(validate, staple)
    }

    func testMacPackageRequiresUsableDeveloperIDApplicationIdentity() throws {
        let script = try packageScript()

        XCTAssertTrue(
            script.contains("application_identity=\"$(codesign -dvvv \"$app\""),
            "The DMG identity must come from the verified exported app"
        )
        XCTAssertTrue(
            script.contains("security find-identity -v -p codesigning"),
            "The signing identity and private key must be present"
        )
        XCTAssertTrue(
            script.contains("Developer ID Application identity and private key are unavailable")
        )
    }

    func testDiskImageIsSignedBeforeNotarizationAndGatekeeperAssessment() throws {
        let script = try packageScript()
        let create = try offset(of: "hdiutil create", in: script)
        let sign = try offset(of: "--sign \"$application_identity\"", in: script)
        let timestamp = try offset(of: "--timestamp", in: script, after: sign)
        let identifier = try offset(
            of: "--identifier com.jimboha.agentlimits.macos.dmg",
            in: script,
            after: sign
        )
        let verify = try offset(
            of: "codesign --verify --strict --verbose=4 \"$dmg\"",
            in: script,
            after: sign
        )
        let notarize = try offset(of: "submit_notary \"$dmg\" dmg", in: script)
        let staple = try offset(of: "xcrun stapler staple \"$dmg\"", in: script)
        let assess = try offset(
            of: "spctl --assess --type open",
            in: script,
            after: staple
        )

        XCTAssertLessThan(create, sign)
        XCTAssertLessThan(sign, timestamp)
        XCTAssertLessThan(timestamp, identifier)
        XCTAssertLessThan(identifier, verify)
        XCTAssertLessThan(verify, notarize)
        XCTAssertLessThan(notarize, staple)
        XCTAssertLessThan(staple, assess)
    }

    func testDeveloperIDSignatureDetailValidationFailsClosed() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let detailsFile = directory.appendingPathComponent("codesign.txt")
        let team = "ABCDE12345"
        let identifier = "org.example.Component"
        let authority = "Developer ID Application: Example Corp (\(team))"
        let validDetails = """
        Identifier=\(identifier)
        CodeDirectory v=20500 size=100 flags=0x10000(runtime) hashes=1+1 location=embedded
        Authority=\(authority)
        Authority=Developer ID Certification Authority
        Authority=Apple Root CA
        Timestamp=Jul 18, 2026 at 1:00:00 PM
        TeamIdentifier=\(team)
        """
        let command = #"source "$1"; details="$(cat "$2")"; validate_developer_id_signature_details "$details" "$3" "$4" "$5" component"#

        try Data(validDetails.utf8).write(to: detailsFile)
        let valid = try runMacCodeSigningHelper(
            command: command,
            arguments: [detailsFile.path, team, identifier, authority]
        )
        XCTAssertEqual(valid.status, 0, valid.output)

        let invalidDetails = [
            validDetails.replacingOccurrences(
                of: "TeamIdentifier=\(team)",
                with: "TeamIdentifier=ZYXWV98765"
            ),
            validDetails + "\nSignature=adhoc\n",
            validDetails.replacingOccurrences(of: "(runtime)", with: "()"),
            validDetails.replacingOccurrences(of: "Timestamp=", with: "Signed Time="),
            validDetails.replacingOccurrences(
                of: "Identifier=\(identifier)",
                with: "Identifier=org.example.Unexpected"
            )
        ]

        for (index, details) in invalidDetails.enumerated() {
            try Data(details.utf8).write(to: detailsFile)
            let result = try runMacCodeSigningHelper(
                command: command,
                arguments: [detailsFile.path, team, identifier, authority]
            )
            XCTAssertNotEqual(result.status, 0, "fixture \(index): \(result.output)")
        }
    }

    func testEveryUniversalSignatureSliceMustPass() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let arm64 = directory.appendingPathComponent("arm64.txt")
        let x86_64 = directory.appendingPathComponent("x86_64.txt")
        let team = "ABCDE12345"
        let identifier = "org.example.Component"
        let authority = "Developer ID Application: Example Corp (\(team))"
        let validDetails = """
        Identifier=\(identifier)
        CodeDirectory v=20500 size=100 flags=0x10000(runtime) hashes=1+1 location=embedded
        Authority=\(authority)
        Authority=Developer ID Certification Authority
        Authority=Apple Root CA
        Timestamp=Jul 18, 2026 at 1:00:00 PM
        TeamIdentifier=\(team)
        """
        let command = #"source "$1"; arm="$(cat "$2")"; intel="$(cat "$3")"; validate_developer_id_signature_slices "$arm" "$intel" "$4" "$5" "$6" component"#

        try Data(validDetails.utf8).write(to: arm64)
        try Data(
            validDetails.replacingOccurrences(of: "(runtime)", with: "()").utf8
        ).write(to: x86_64)
        let weakIntelSlice = try runMacCodeSigningHelper(
            command: command,
            arguments: [arm64.path, x86_64.path, team, identifier, authority]
        )
        XCTAssertNotEqual(weakIntelSlice.status, 0, weakIntelSlice.output)

        try Data(validDetails.utf8).write(to: x86_64)
        let bothValid = try runMacCodeSigningHelper(
            command: command,
            arguments: [arm64.path, x86_64.path, team, identifier, authority]
        )
        XCTAssertEqual(bothValid.status, 0, bothValid.output)
    }

    func testUniversalArchitectureValidationRejectsMissingOrExtraSlices() throws {
        let command = #"source "$1"; validate_universal_binary_architectures "$2" component"#

        for architectures in ["arm64 x86_64", "x86_64 arm64"] {
            let result = try runMacCodeSigningHelper(
                command: command,
                arguments: [architectures]
            )
            XCTAssertEqual(result.status, 0, result.output)
        }
        for architectures in ["arm64", "x86_64", "arm64 x86_64 i386"] {
            let result = try runMacCodeSigningHelper(
                command: command,
                arguments: [architectures]
            )
            XCTAssertNotEqual(result.status, 0, result.output)
        }
    }

    func testSparkleAutoupdateIdentifiersArePinned() throws {
        let command = #"source "$1"; validate_sparkle_autoupdate_identifier "$2""#
        let accepted = [
            "Autoupdate",
            "Autoupdate-555549442401fd215d503466a26c3d081e5a8443"
        ]

        for identifier in accepted {
            let result = try runMacCodeSigningHelper(
                command: command,
                arguments: [identifier]
            )
            XCTAssertEqual(result.status, 0, result.output)
        }
        for identifier in ["Autoupdate-other", "Unexpected"] {
            let result = try runMacCodeSigningHelper(
                command: command,
                arguments: [identifier]
            )
            XCTAssertNotEqual(result.status, 0, result.output)
        }
    }

    func testNestedEntitlementsRequireGetTaskAllowToBeAbsent() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let entitlements = directory.appendingPathComponent("entitlements.plist")
        let command = #"source "$1"; validate_no_get_task_allow_entitlements "$2" component"#
        let safe = try PropertyListSerialization.data(
            fromPropertyList: ["com.apple.application-identifier": "example"],
            format: .xml,
            options: 0
        )
        try safe.write(to: entitlements)
        let safeResult = try runMacCodeSigningHelper(
            command: command,
            arguments: [entitlements.path]
        )
        XCTAssertEqual(safeResult.status, 0, safeResult.output)

        let unsafe = try PropertyListSerialization.data(
            fromPropertyList: ["get-task-allow": false],
            format: .xml,
            options: 0
        )
        try unsafe.write(to: entitlements)
        let unsafeResult = try runMacCodeSigningHelper(
            command: command,
            arguments: [entitlements.path]
        )
        XCTAssertNotEqual(unsafeResult.status, 0, unsafeResult.output)
    }

    func testSparkleSymlinkInventoryRejectsRedirectsAndExtras() throws {
        let validDirectory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: validDirectory) }
        try createSparkleSymlinkFixture(at: validDirectory)
        let command = #"source "$1"; validate_sparkle_symlink_inventory "$2""#

        let valid = try runMacCodeSigningHelper(
            command: command,
            arguments: [validDirectory.path]
        )
        XCTAssertEqual(valid.status, 0, valid.output)

        try FileManager.default.createSymbolicLink(
            atPath: validDirectory.appendingPathComponent("Unexpected").path,
            withDestinationPath: "/tmp"
        )
        let extra = try runMacCodeSigningHelper(
            command: command,
            arguments: [validDirectory.path]
        )
        XCTAssertNotEqual(extra.status, 0, extra.output)

        let redirectedDirectory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: redirectedDirectory) }
        try createSparkleSymlinkFixture(
            at: redirectedDirectory,
            currentTarget: "../../outside"
        )
        let redirected = try runMacCodeSigningHelper(
            command: command,
            arguments: [redirectedDirectory.path]
        )
        XCTAssertNotEqual(redirected.status, 0, redirected.output)
    }

    func testSparkleCodePathClassifierRejectsUnexpectedCode() throws {
        let command = #"source "$1"; is_expected_sparkle_code_path "$2""#
        let accepted = [
            "Versions/B/Sparkle",
            "Versions/B/Autoupdate",
            "Versions/B/Updater.app/Contents/MacOS/Updater",
            "Versions/B/XPCServices/Downloader.xpc/Contents/MacOS/Downloader",
            "Versions/B/XPCServices/Installer.xpc/Contents/MacOS/Installer"
        ]

        for path in accepted {
            let result = try runMacCodeSigningHelper(
                command: command,
                arguments: [path]
            )
            XCTAssertEqual(result.status, 0, result.output)
        }
        for path in ["Versions/B/Unexpected", "Versions/B/Other.app/Contents/MacOS/Other"] {
            let result = try runMacCodeSigningHelper(
                command: command,
                arguments: [path]
            )
            XCTAssertNotEqual(result.status, 0, result.output)
        }
    }

    func testNestedSparkleVerificationRunsBeforeAppNotarization() throws {
        let script = try packageScript()
        let export = try offset(of: "xcodebuild -exportArchive", in: script)
        let inventory = try offset(
            of: "validate_sparkle_code_inventory || exit $?",
            in: script
        )
        let component = try offset(
            of: "verify_signed_sparkle_component \\\n    \"$sparkle\"",
            in: script
        )
        let notarize = try offset(
            of: #"submit_notary "$temporary_notary_zip" app"#,
            in: script
        )

        XCTAssertLessThan(export, inventory)
        XCTAssertLessThan(inventory, component)
        XCTAssertLessThan(component, notarize)
        XCTAssertTrue(script.contains("1.2.840.113635.100.6.2.6"))
        XCTAssertTrue(script.contains("1.2.840.113635.100.6.1.13"))
        XCTAssertTrue(script.contains("source \"$script_dir/macos-code-signing.sh\""))
        XCTAssertTrue(script.contains("Sparkle changed; audit and update"))
        XCTAssertTrue(script.contains("codesign -d -a arm64 -vvv"))
        XCTAssertTrue(script.contains("codesign -d -a x86_64 -vvv"))
        XCTAssertTrue(script.contains("codesign -d -a \"$signature_architecture\""))
        XCTAssertTrue(script.contains("codesign --verify --all-architectures"))
    }

    private func packageScript() throws -> String {
        try releaseScript(named: "package-macos.sh")
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func releaseScript(named name: String) throws -> String {
        try String(
            contentsOf: repositoryRoot.appendingPathComponent("Scripts/\(name)"),
            encoding: .utf8
        )
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentLimitsSigningConfigTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false
        )
        return directory
    }

    private func createSparkleSymlinkFixture(
        at directory: URL,
        currentTarget: String = "B"
    ) throws {
        let versions = directory.appendingPathComponent("Versions")
        try FileManager.default.createDirectory(
            at: versions,
            withIntermediateDirectories: true
        )
        let links = [
            ("Versions/Current", currentTarget),
            ("Autoupdate", "Versions/Current/Autoupdate"),
            ("Resources", "Versions/Current/Resources"),
            ("Sparkle", "Versions/Current/Sparkle"),
            ("Updater.app", "Versions/Current/Updater.app"),
            ("XPCServices", "Versions/Current/XPCServices")
        ]
        for (relativePath, target) in links {
            try FileManager.default.createSymbolicLink(
                atPath: directory.appendingPathComponent(relativePath).path,
                withDestinationPath: target
            )
        }
    }

    private func setPermissions(_ permissions: Int, for url: URL) throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: permissions],
            ofItemAtPath: url.path
        )
    }

    private func runSigningConfigValidator(
        config: URL,
        command: String = #"source "$1"; validate_development_team_config "$2"; status=$?; if [[ $status -eq 0 ]]; then printf '%s\n' "$validated_development_team"; fi; exit "$status""#
    ) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [
            "-c",
            command,
            "signing-config-test",
            repositoryRoot.appendingPathComponent("Scripts/signing-config.sh").path,
            config.path
        ]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        return (
            process.terminationStatus,
            String(decoding: data, as: UTF8.self)
        )
    }

    private func runNotaryLogValidator(
        log: URL,
        jobID: String
    ) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [
            "-c",
            #"source "$1"; validate_accepted_notary_log "$2" "$3"; exit $?"#,
            "notary-log-test",
            repositoryRoot.appendingPathComponent("Scripts/notary-log.sh").path,
            log.path,
            jobID
        ]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        return (
            process.terminationStatus,
            String(decoding: data, as: UTF8.self)
        )
    }

    private func runMacCodeSigningHelper(
        command: String,
        arguments: [String]
    ) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [
            "-c",
            command,
            "mac-code-signing-test",
            repositoryRoot.appendingPathComponent("Scripts/macos-code-signing.sh").path
        ] + arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        return (
            process.terminationStatus,
            String(decoding: data, as: UTF8.self)
        )
    }

    private func offset(
        of needle: String,
        in text: String,
        after lowerBound: Int = 0
    ) throws -> Int {
        let start = text.index(text.startIndex, offsetBy: lowerBound)
        let range = try XCTUnwrap(text.range(of: needle, range: start..<text.endIndex))
        return text.distance(from: text.startIndex, to: range.lowerBound)
    }
}
