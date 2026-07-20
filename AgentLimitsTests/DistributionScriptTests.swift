import Foundation
import XCTest

final class DistributionScriptTests: XCTestCase {
    func testAppleToolchainVersionComparisonIsNumericAndFailClosed() throws {
        let command = #"source "$1"; apple_version_is_at_least 26.10 26.9 || exit 1; older=0; apple_version_is_at_least 26.9 26.10 || older=$?; malformed=0; apple_version_is_at_least 26.beta 26 || malformed=$?; oversized=0; apple_version_is_at_least 1234567890.1 26 || oversized=$?; [[ "$older" == 1 && "$malformed" == 2 && "$oversized" == 2 ]]"#

        let result = try runAppleToolchainHelper(command: command)

        XCTAssertEqual(result.status, 0, result.output)
    }

    func testAppleToolchainPreflightUsesHermeticXcodeAndSDKFixtures() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let developerDirectory = try createAppleToolchainFixture(
            at: directory,
            dtxcode: "2610"
        )

        let result = try runAppleToolchainFixture(
            developerDirectory: developerDirectory,
            xcodeVersion: "26.1",
            xcodeBuild: "17A1",
            sdkVersion: "26.2",
            sdkBuild: "23A1",
            platforms: ["macosx", "iphoneos", "watchos"]
        )

        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertEqual(
            result.output.split(separator: "\n").map(String.init),
            ["26", "26", "26.1", "26.2", "26.2", "26.2"],
            result.output
        )
    }

    func testAppleToolchainPreflightRejectsBelowFloorAndMalformedFixtures() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let currentDeveloperDirectory = try createAppleToolchainFixture(
            at: directory.appendingPathComponent("current"),
            dtxcode: "2610"
        )
        let oldDeveloperDirectory = try createAppleToolchainFixture(
            at: directory.appendingPathComponent("old"),
            dtxcode: "2550"
        )
        let fixtures: [(
            name: String,
            developerDirectory: URL,
            xcodeVersion: String,
            xcodeBuild: String,
            sdkVersion: String,
            sdkBuild: String,
            expected: String
        )] = [
            (
                "old Xcode", oldDeveloperDirectory, "25.5", "16F1",
                "26.2", "23A1", "Xcode 25.5 is below required version 26"
            ),
            (
                "malformed Xcode", currentDeveloperDirectory, "26.beta", "17A1",
                "26.2", "23A1", "malformed version metadata"
            ),
            (
                "malformed Xcode build", currentDeveloperDirectory, "26.1", "17-A1",
                "26.2", "23A1", "malformed build metadata"
            ),
            (
                "old SDK", currentDeveloperDirectory, "26.1", "17A1",
                "25.9", "22A1", "SDK 25.9 is below required version 26"
            ),
            (
                "malformed SDK", currentDeveloperDirectory, "26.1", "17A1",
                "26.beta", "23A1", "SDK version could not be validated"
            ),
            (
                "malformed SDK build", currentDeveloperDirectory, "26.1", "17A1",
                "26.2", "23-A1", "Could not read selected macosx SDK build"
            )
        ]

        for fixture in fixtures {
            let result = try runAppleToolchainFixture(
                developerDirectory: fixture.developerDirectory,
                xcodeVersion: fixture.xcodeVersion,
                xcodeBuild: fixture.xcodeBuild,
                sdkVersion: fixture.sdkVersion,
                sdkBuild: fixture.sdkBuild,
                platforms: ["macosx"]
            )
            XCTAssertEqual(result.status, 69, fixture.name + ": " + result.output)
            XCTAssertTrue(
                result.output.contains(fixture.expected),
                fixture.name + ": " + result.output
            )
        }
    }

    func testAppleToolchainTrustAcceptsInstalledAppleXcode() throws {
        let selectedDeveloperDirectory = ProcessInfo.processInfo.environment[
            "DEVELOPER_DIR"
        ] ?? "/Applications/Xcode.app/Contents/Developer"
        let canonicalDeveloperDirectory = URL(
            fileURLWithPath: selectedDeveloperDirectory,
            isDirectory: true
        ).resolvingSymlinksInPath().path
        guard FileManager.default.fileExists(
            atPath: canonicalDeveloperDirectory + "/usr/bin/xcodebuild"
        ) else {
            throw XCTSkip("A selected Xcode installation is required")
        }
        let command = #"source "$1"; apple_validate_xcode_bundle_trust "$2"; exit $?"#

        let result = try runAppleToolchainHelper(
            command: command,
            arguments: [canonicalDeveloperDirectory]
        )

        XCTAssertEqual(result.status, 0, result.output)
    }

    func testAppleToolchainRejectsUntrustedBundleBeforeToolExecution() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let developerDirectory = try createAppleToolchainFixture(
            at: directory,
            dtxcode: "2610"
        )
        let marker = directory.appendingPathComponent("selected-tool-ran")
        let command = #"""
        source "$1"
        selected_tool_marker="$3"
        apple_run_selected_tool() {
            /usr/bin/touch "$selected_tool_marker"
            return 97
        }
        validate_apple_distribution_toolchain "$2" macosx
        result=$?
        [[ ! -e "$selected_tool_marker" ]] || exit 98
        exit "$result"
        """#

        let result = try runAppleToolchainHelper(
            command: command,
            arguments: [developerDirectory.path, marker.path]
        )

        XCTAssertEqual(result.status, 69, result.output)
        XCTAssertTrue(
            result.output.contains("canonical Xcode Developer directory"),
            result.output
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        let helper = try releaseScript(named: "apple-toolchain.sh")
        XCTAssertTrue(
            helper.contains("/usr/bin/codesign --verify --deep --strict")
        )
        XCTAssertTrue(
            helper.contains(
                #"certificate leaf[field.1.2.840.113635.100.6.1.9] exists"#
            )
        )
        XCTAssertTrue(
            helper.contains(
                #"certificate leaf[subject.OU] = "59GAB85EFG""#
            )
        )
        XCTAssertTrue(helper.contains(#"identifier "com.apple.dt.Xcode""#))
        XCTAssertTrue(helper.contains("'!' -uid 0"))
        XCTAssertTrue(helper.contains("-o -perm -0002"))
        XCTAssertTrue(helper.contains("-o -acl"))
    }

    func testAppleProductMetadataMustExactlyMatchPreflight() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let info = directory.appendingPathComponent("Info.plist")
        let validMetadata: [String: Any] = [
            "DTXcode": "2660",
            "DTXcodeBuild": "17F113",
            "DTSDKName": "iphoneos26.5",
            "DTSDKBuild": "23F81a",
            "DTPlatformName": "iphoneos",
            "DTPlatformVersion": "26.5"
        ]
        let command = #"source "$1"; validated_apple_toolchain_ready=1; validated_apple_xcode_version=26.6; validated_apple_xcode_build=17F113; validated_apple_dtxcode=2660; validated_apple_iphoneos_sdk_version=26.5; validated_apple_iphoneos_sdk_name=iphoneos26.5; validated_apple_iphoneos_sdk_build=23F81a; verify_apple_product_toolchain_metadata "$2" iphoneos fixture; exit $?"#

        try PropertyListSerialization.data(
            fromPropertyList: validMetadata,
            format: .xml,
            options: 0
        ).write(to: info)
        var result = try runAppleToolchainHelper(
            command: command,
            arguments: [info.path]
        )
        XCTAssertEqual(result.status, 0, result.output)

        let unequalWellFormedValues: [String: String] = [
            "DTXcode": "2670",
            "DTXcodeBuild": "17F114",
            "DTSDKName": "iphoneos26.6",
            "DTSDKBuild": "23F82",
            "DTPlatformName": "iphonesimulator",
            "DTPlatformVersion": "26.6"
        ]
        for (key, unequalValue) in unequalWellFormedValues {
            var invalidMetadata = validMetadata
            invalidMetadata[key] = unequalValue
            try PropertyListSerialization.data(
                fromPropertyList: invalidMetadata,
                format: .xml,
                options: 0
            ).write(to: info)
            result = try runAppleToolchainHelper(
                command: command,
                arguments: [info.path]
            )
            XCTAssertNotEqual(result.status, 0, "\(key): \(result.output)")
        }
    }

    func testReleasePathsEnforcePreflightAndPostBuildMetadata() throws {
        let unsigned = try releaseScript(named: "build-unsigned-artifacts.sh")
        assertOrderedSnippets(
            [
                #"source "$script_dir/apple-toolchain.sh""#,
                #"""
                validate_apple_distribution_toolchain \
                    "$developer_dir" macosx iphoneos watchos || exit $?
                """#,
                #"""
                verify_apple_product_toolchain_metadata \
                    "$mac_info" macosx "Unsigned macOS app" || exit $?
                """#,
                #"""
                verify_apple_product_toolchain_metadata \
                    "$widget_info" macosx "Unsigned macOS widget" || exit $?
                """#,
                #"""
                verify_apple_product_toolchain_metadata \
                    "$ios_info" iphoneos "Unsigned iOS app" || exit $?
                """#,
                #"""
                verify_apple_product_toolchain_metadata \
                    "$watch_info" watchos "Unsigned Watch app" || exit $?
                """#
            ],
            in: unsigned,
            context: "build-unsigned-artifacts.sh"
        )
        XCTAssertEqual(
            occurrenceCount(
                of: "verify_apple_product_toolchain_metadata",
                in: unsigned
            ),
            4
        )

        let ios = try releaseScript(named: "export-ios.sh")
        assertOrderedSnippets(
            [
                #"source "$script_dir/apple-toolchain.sh""#,
                #"""
                validate_apple_distribution_toolchain \
                    "$developer_dir" iphoneos watchos || exit $?
                """#,
                #"""
                verify_apple_product_toolchain_metadata \
                    "$archive_ios_info" iphoneos "Archived iOS app" || exit $?
                """#,
                #"""
                verify_apple_product_toolchain_metadata \
                    "$archive_watch_info" watchos "Archived Watch app" || exit $?
                """#,
                #"""
                verify_apple_product_toolchain_metadata \
                    "$ios_info" iphoneos "Exported iOS app" || exit $?
                """#,
                #"""
                verify_apple_product_toolchain_metadata \
                    "$watch_info" watchos "Exported Watch app" || exit $?
                """#
            ],
            in: ios,
            context: "export-ios.sh"
        )
        XCTAssertEqual(
            occurrenceCount(of: "verify_apple_product_toolchain_metadata", in: ios),
            4
        )

        let mac = try releaseScript(named: "package-macos.sh")
        assertOrderedSnippets(
            [
                #"source "$script_dir/apple-toolchain.sh""#,
                #"validate_apple_distribution_toolchain "$developer_dir" macosx || exit $?"#,
                #"""
                verify_apple_product_toolchain_metadata \
                    "$archive_app/Contents/Info.plist" macosx "Archived macOS app" || exit $?
                """#,
                #"""
                verify_apple_product_toolchain_metadata \
                    "$archive_widget/Contents/Info.plist" macosx "Archived macOS widget" \
                    || exit $?
                """#,
                #"""
                verify_apple_product_toolchain_metadata \
                    "$app_info" macosx "Developer ID app" || exit $?
                """#,
                #"""
                verify_apple_product_toolchain_metadata \
                    "$widget_info" macosx "Developer ID widget" || exit $?
                """#,
                #"""
                    verify_apple_product_toolchain_metadata \
                        "$candidate_info" macosx "$label" || exit $?
                """#,
                #"""
                    verify_apple_product_toolchain_metadata \
                        "$candidate_widget_info" macosx "$label widget" || exit $?
                """#,
                #"verify_packaged_app "$zip_app" "ZIP app""#,
                #"verify_packaged_app "$pkg_app" "PKG payload app""#,
                #"verify_packaged_app "$mounted_app" "DMG app""#
            ],
            in: mac,
            context: "package-macos.sh"
        )
        XCTAssertEqual(
            occurrenceCount(of: "verify_apple_product_toolchain_metadata", in: mac),
            6
        )

        for (name, script) in [
            ("build-unsigned-artifacts.sh", unsigned),
            ("export-ios.sh", ios),
            ("package-macos.sh", mac)
        ] {
            XCTAssertEqual(
                occurrenceCount(
                    of: "validate_apple_distribution_toolchain",
                    in: script
                ),
                1,
                name
            )
            XCTAssertFalse(script.contains("sort -V"), name)
        }
    }

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

    func testReleaseGitEnvironmentDropsInheritedOverrides() throws {
        let command = #"source "$1"; sanitize_release_git_environment; /usr/bin/env | LC_ALL=C /usr/bin/sort | /usr/bin/sed -n '/^GIT_/p'"#
        let result = try runSigningConfigHelper(
            command: command,
            environment: [
                "GIT_ATTR_NOSYSTEM": "0",
                "GIT_COMMON_DIR": "/private/tmp/hostile-common",
                "GIT_CONFIG_COUNT": "1",
                "GIT_CONFIG_GLOBAL": "/private/tmp/hostile.gitconfig",
                "GIT_CONFIG_KEY_0": "core.worktree",
                "GIT_CONFIG_VALUE_0": "/private/tmp/hostile-worktree",
                "GIT_DIR": "/private/tmp/hostile.git",
                "GIT_INDEX_FILE": "/private/tmp/hostile-index",
                "GIT_NO_REPLACE_OBJECTS": "0",
                "GIT_REPLACE_REF_BASE": "refs/hostile-replacements",
                "GIT_WORK_TREE": "/private/tmp/hostile-worktree"
            ]
        )

        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertEqual(
            result.output.split(separator: "\n").map(String.init),
            [
                "GIT_ATTR_NOSYSTEM=1",
                "GIT_CONFIG_GLOBAL=/dev/null",
                "GIT_CONFIG_NOSYSTEM=1",
                "GIT_NO_REPLACE_OBJECTS=1"
            ]
        )
    }

    func testReleaseGitEnvironmentPinsRepositoryAndDisablesReplacementRefs() throws {
        let repository = try temporaryDirectory()
        let alternateRepository = try temporaryDirectory()
        let hostileConfig = try temporaryDirectory()
            .appendingPathComponent("hostile.gitconfig")
        defer {
            try? FileManager.default.removeItem(at: repository)
            try? FileManager.default.removeItem(at: alternateRepository)
            try? FileManager.default.removeItem(
                at: hostileConfig.deletingLastPathComponent()
            )
        }

        let trustedCommit = try initializeGitRepository(
            at: repository,
            fileName: "trusted.txt"
        )
        try FileManager.default.removeItem(
            at: repository.appendingPathComponent("trusted.txt")
        )
        try Data("replacement".utf8).write(
            to: repository.appendingPathComponent("replacement.txt")
        )
        _ = try git(["add", "-A"], at: repository)
        _ = try git(["commit", "-qm", "replacement"], at: repository)
        let replacementCommit = try git(["rev-parse", "HEAD"], at: repository)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try git(["checkout", "-q", "--detach", trustedCommit], at: repository)
        _ = try git(
            ["replace", trustedCommit, replacementCommit],
            at: repository
        )

        _ = try initializeGitRepository(
            at: alternateRepository,
            fileName: "alternate.txt"
        )
        try Data(
            "[core]\n\tworktree = \(alternateRepository.path)\n".utf8
        ).write(to: hostileConfig)

        let command = #"source "$1"; sanitize_release_git_environment; /usr/bin/git -C "$2" archive --format=tar HEAD | /usr/bin/tar -tf -"#
        let result = try runSigningConfigHelper(
            command: command,
            arguments: [repository.path],
            environment: [
                "GIT_COMMON_DIR": alternateRepository
                    .appendingPathComponent(".git").path,
                "GIT_CONFIG_COUNT": "1",
                "GIT_CONFIG_GLOBAL": hostileConfig.path,
                "GIT_CONFIG_KEY_0": "core.worktree",
                "GIT_CONFIG_VALUE_0": alternateRepository.path,
                "GIT_DIR": alternateRepository.appendingPathComponent(".git").path,
                "GIT_INDEX_FILE": alternateRepository
                    .appendingPathComponent(".git/index").path,
                "GIT_NO_REPLACE_OBJECTS": "0",
                "GIT_REPLACE_REF_BASE": "refs/replace",
                "GIT_WORK_TREE": alternateRepository.path
            ]
        )

        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertEqual(
            result.output.trimmingCharacters(in: .whitespacesAndNewlines),
            "trusted.txt"
        )
    }

    func testReleaseEntrypointsIgnoreBashEnvAndExportedFunctions() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let bashEnvironment = directory.appendingPathComponent("hostile-bash-env")
        let contents = #"""
        if [[ "${BASH_ENV_PARENT_ONLY:-}" == "1" ]]; then
            echo() {
                /usr/bin/printf 'HOSTILE_EXPORTED_ECHO\n' >&2
                return 97
            }
            export -f echo
        else
            /usr/bin/printf 'HOSTILE_BASH_ENV\n' >&2
        fi
        """#
        try Data(contents.utf8).write(to: bashEnvironment)
        try setPermissions(0o600, for: bashEnvironment)

        for name in [
            "build-unsigned-artifacts.sh",
            "export-ios.sh",
            "package-macos.sh"
        ] {
            let script = repositoryRoot.appendingPathComponent("Scripts/\(name)")
            let scriptText = try releaseScript(named: name)
            XCTAssertTrue(scriptText.hasPrefix("#!/bin/bash -p\n"), name)
            XCTAssertEqual(
                occurrenceCount(of: "exec /usr/bin/env -i", in: scriptText),
                1,
                name
            )
            XCTAssertTrue(
                scriptText.contains(
                    #"${AGENTLIMITS_RELEASE_ENV_PID:-}" != "$$""#
                ),
                name
            )
            XCTAssertTrue(scriptText.contains("BASH_FUNC_*)"), name)
            XCTAssertTrue(scriptText.contains("builtin unset HOME CDPATH"), name)
            XCTAssertTrue(
                scriptText.contains(#"HOME="$agentlimits_release_home""#),
                name
            )
            XCTAssertFalse(scriptText.contains(#"HOME="${HOME"#), name)
            XCTAssertTrue(
                scriptText.contains(
                    #"${HOME:-}" != "$agentlimits_release_home""#
                ),
                name
            )
            XCTAssertTrue(
                scriptText.contains(
                    #"${PATH:-}" != /usr/bin:/bin:/usr/sbin:/sbin"#
                ),
                name
            )
            let result = try runProcess(
                executable: "/bin/bash",
                arguments: [
                    "-c",
                    #"unset BASH_ENV_PARENT_ONLY; exec "$1""#,
                    "release-entrypoint-test",
                    script.path
                ],
                environment: [
                    "BASH_ENV": bashEnvironment.path,
                    "BASH_ENV_PARENT_ONLY": "1",
                    "HOME": directory.path
                ]
            )

            XCTAssertEqual(result.status, 64, name + ": " + result.output)
            XCTAssertTrue(
                result.output.contains("Usage:"),
                name + ": " + result.output
            )
            XCTAssertFalse(
                result.output.contains("HOSTILE_"),
                name + ": " + result.output
            )
            XCTAssertFalse(
                result.output.contains("Release environment was not sanitized"),
                name + ": " + result.output
            )

            let forgedSentinel = try runProcess(
                executable: "/bin/bash",
                arguments: [
                    "-c",
                    #"exec /usr/bin/env -i AGENTLIMITS_RELEASE_ENV_PID="$$" DEVELOPER_DIR= HOME=/var/empty LANG=C LC_ALL=C PATH=/private/tmp "$1""#,
                    "release-entrypoint-forged-sentinel-test",
                    script.path
                ]
            )
            XCTAssertEqual(
                forgedSentinel.status,
                70,
                name + ": " + forgedSentinel.output
            )
            XCTAssertTrue(
                forgedSentinel.output.contains(
                    "Release environment was not sanitized "
                        + "(unexpected fixed variable value)"
                ),
                name + ": " + forgedSentinel.output
            )

            let forgedHome = try runProcess(
                executable: "/bin/bash",
                arguments: [
                    "-c",
                    #"exec /usr/bin/env -i AGENTLIMITS_RELEASE_ENV_PID="$$" DEVELOPER_DIR= HOME=/private/tmp LANG=C LC_ALL=C PATH=/usr/bin:/bin:/usr/sbin:/sbin "$1""#,
                    "release-entrypoint-forged-home-test",
                    script.path
                ]
            )
            XCTAssertEqual(
                forgedHome.status,
                70,
                name + ": " + forgedHome.output
            )
            XCTAssertTrue(
                forgedHome.output.contains(
                    "Release environment was not sanitized "
                        + "(unexpected fixed variable value)"
                ),
                name + ": " + forgedHome.output
            )
        }
    }

    func testReleaseScriptsIgnoreHostileCDPATHWithNewlineTrap() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cdPathRoot = directory.appendingPathComponent("cdpath")
        let decoyScripts = cdPathRoot.appendingPathComponent("Scripts")
        try FileManager.default.createDirectory(
            at: decoyScripts,
            withIntermediateDirectories: true
        )
        let poisonedScriptDirectory = URL(
            fileURLWithPath: "\(decoyScripts.path)\n\(decoyScripts.path)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: poisonedScriptDirectory,
            withIntermediateDirectories: true
        )
        try Data(
            #"printf 'sourced\n' >"$AGENTLIMITS_CDPATH_MARKER"; exit 99"#.utf8
        ).write(
            to: poisonedScriptDirectory.appendingPathComponent("signing-config.sh")
        )
        let missingDeveloperDirectory = directory.appendingPathComponent("missing-Xcode")
        let invocations: [(String, [String])] = [
            (
                "Scripts/export-ios.sh",
                [directory.appendingPathComponent("ios-output").path, "app-store-connect"]
            ),
            (
                "Scripts/package-macos.sh",
                [
                    directory.appendingPathComponent("mac-output").path,
                    "notary-profile",
                    "Developer ID Installer: Example (ABCDE12345)"
                ]
            ),
            (
                "Scripts/build-unsigned-artifacts.sh",
                [directory.appendingPathComponent("unsigned-output").path]
            )
        ]

        for (index, invocation) in invocations.enumerated() {
            let marker = directory.appendingPathComponent("marker-\(index)")
            let result = try runReleaseScript(
                relativePath: invocation.0,
                arguments: invocation.1,
                environment: [
                    "AGENTLIMITS_CDPATH_MARKER": marker.path,
                    "CDPATH": cdPathRoot.path,
                    "DEVELOPER_DIR": missingDeveloperDirectory.path
                ]
            )

            XCTAssertEqual(result.status, 69, "\(invocation.0): \(result.output)")
            XCTAssertTrue(
                result.output.contains(
                    "Xcode not found at \(missingDeveloperDirectory.path)"
                ),
                "\(invocation.0): \(result.output)"
            )
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: marker.path),
                invocation.0
            )
        }
    }

    func testReleaseScriptsRejectSymlinkInvocationBeforeSourcingHelpers() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = directory.appendingPathComponent("sourced-marker")
        try Data(
            #"printf 'sourced\n' >"$AGENTLIMITS_SYMLINK_MARKER"; exit 99"#.utf8
        ).write(to: directory.appendingPathComponent("signing-config.sh"))
        let invocations: [(String, [String])] = [
            (
                "export-ios.sh",
                [directory.appendingPathComponent("ios-output").path, "app-store-connect"]
            ),
            (
                "package-macos.sh",
                [
                    directory.appendingPathComponent("mac-output").path,
                    "notary-profile",
                    "Developer ID Installer: Example (ABCDE12345)"
                ]
            ),
            (
                "build-unsigned-artifacts.sh",
                [directory.appendingPathComponent("unsigned-output").path]
            )
        ]

        for invocation in invocations {
            let link = directory.appendingPathComponent(invocation.0)
            try FileManager.default.createSymbolicLink(
                at: link,
                withDestinationURL: repositoryRoot
                    .appendingPathComponent("Scripts")
                    .appendingPathComponent(invocation.0)
            )
            let result = try runProcess(
                executable: "/bin/bash",
                arguments: [link.path] + invocation.1,
                environment: ["AGENTLIMITS_SYMLINK_MARKER": marker.path]
            )

            XCTAssertEqual(result.status, 64, "\(invocation.0): \(result.output)")
            XCTAssertTrue(result.output.contains("script symlink"), result.output)
            XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        }
    }

    func testSignedReleaseScriptsUseCleanSnapshotAndRecheckConfig() throws {
        for name in ["package-macos.sh", "export-ios.sh"] {
            let script = try releaseScript(named: name)
            XCTAssertTrue(script.contains("source \"$script_dir/signing-config.sh\""), name)
            XCTAssertTrue(script.contains("sanitize_release_git_environment"), name)
            XCTAssertTrue(script.contains("unset CDPATH"), name)
            XCTAssertTrue(
                script.contains("Refusing to run a signed release through a script symlink"),
                name
            )
            XCTAssertTrue(script.contains("source \"$script_dir/release-output.sh\""), name)
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

    func testSignedReleaseScriptsPublishOnlyAfterFinalSourceFence() throws {
        for name in ["package-macos.sh", "export-ios.sh"] {
            let script = try releaseScript(named: name)
            let dirtyRejection = try offset(of: "Refusing a signed", in: script)
            let lock = try offset(of: "acquire_release_publication_lock", in: script)
            let stage = try offset(of: "create_release_staging_directory", in: script)
            let publish = try offset(of: "publish_staged_release_directory", in: script)

            XCTAssertLessThan(dirtyRejection, lock, name)
            XCTAssertLessThan(lock, stage, name)
            XCTAssertLessThan(stage, publish, name)
            XCTAssertTrue(
                script.contains(
                    "verify_source_unchanged\npublish_staged_release_directory"
                ),
                name
            )
            XCTAssertTrue(script.contains("output_dir=\"$staging_dir\""), name)
            XCTAssertTrue(script.contains("release_output_dir"), name)
            XCTAssertTrue(
                script.contains("configure_private_release_temporary_directory"),
                name
            )
            XCTAssertTrue(script.contains("derived_data=\"$work_dir/DerivedData\""), name)
            XCTAssertTrue(script.contains("mkdir -m 700 \"$derived_data\""), name)
            XCTAssertTrue(
                script.contains("make_release_directory_private \"$derived_data\""),
                name
            )
            XCTAssertFalse(script.contains("${TMPDIR:-"), name)
        }
    }

    func testSignedPublicationUsesAtomicExclusiveRenameHelper() throws {
        let helper = try releaseScript(named: "release-output.sh")
        let publisher = try releaseScript(named: "atomic-release-publish.c")

        XCTAssertTrue(publisher.contains("renamex_np"))
        XCTAssertTrue(publisher.contains("RENAME_EXCL"))
        XCTAssertTrue(publisher.contains("RENAME_NOFOLLOW_ANY"))
        XCTAssertTrue(
            helper.contains("/usr/bin/xcrun --no-cache --sdk macosx clang")
        )
        XCTAssertTrue(helper.contains("verify_atomic_release_publisher"))
        XCTAssertFalse(helper.contains("/bin/mv -n"))
        for name in ["package-macos.sh", "export-ios.sh"] {
            let script = try releaseScript(named: name)
            XCTAssertTrue(
                script.contains(
                    "$build_root/Scripts/atomic-release-publish.c"
                ),
                name
            )
        }
    }

    func testReleaseOutputRejectsRelativeTraversalAndSymlinkAliases() throws {
        let directory = try releaseTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let child = directory.appendingPathComponent("child")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: false)
        let parentLink = directory.appendingPathComponent("parent-link")
        try FileManager.default.createSymbolicLink(
            at: parentLink,
            withDestinationURL: child
        )
        let command = #"source "$1"; validate_release_output_request "$2" "$3"; exit $?"#

        var result = try runReleaseOutputHelper(
            command: command,
            arguments: ["relative-output", repositoryRoot.path]
        )
        XCTAssertEqual(result.status, 64, result.output)

        result = try runReleaseOutputHelper(
            command: command,
            arguments: [
                child.appendingPathComponent("../result").path,
                repositoryRoot.path
            ]
        )
        XCTAssertEqual(result.status, 64, result.output)

        result = try runReleaseOutputHelper(
            command: command,
            arguments: [
                parentLink.appendingPathComponent("result").path,
                repositoryRoot.path
            ]
        )
        XCTAssertEqual(result.status, 73, result.output)
    }

    func testReleaseOutputRejectsExistingAndDanglingTargets() throws {
        let directory = try releaseTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let existingFile = directory.appendingPathComponent("existing-file")
        let existingDirectory = directory.appendingPathComponent("existing-directory")
        let dangling = directory.appendingPathComponent("dangling")
        try Data("occupied".utf8).write(to: existingFile)
        try FileManager.default.createDirectory(
            at: existingDirectory,
            withIntermediateDirectories: false
        )
        try FileManager.default.createSymbolicLink(
            atPath: dangling.path,
            withDestinationPath: directory.appendingPathComponent("missing").path
        )
        let command = #"source "$1"; validate_release_output_request "$2" "$3"; exit $?"#

        for target in [existingFile, existingDirectory, dangling] {
            let result = try runReleaseOutputHelper(
                command: command,
                arguments: [target.path, repositoryRoot.path]
            )
            XCTAssertEqual(result.status, 73, "\(target.lastPathComponent): \(result.output)")
        }
    }

    func testReleaseOutputRejectsExternallyWritableParentAndMutatingACL() throws {
        let directory = try releaseTemporaryDirectory()
        defer {
            _ = try? runProcess(
                executable: "/bin/chmod",
                arguments: ["-N", directory.path]
            )
            try? FileManager.default.removeItem(at: directory)
        }
        let output = directory.appendingPathComponent("result")
        let command = #"source "$1"; validate_release_output_request "$2" "$3"; exit $?"#

        try setPermissions(0o722, for: directory)
        var result = try runReleaseOutputHelper(
            command: command,
            arguments: [output.path, repositoryRoot.path]
        )
        XCTAssertEqual(result.status, 73, result.output)

        try setPermissions(0o700, for: directory)
        let aclResult = try runProcess(
            executable: "/bin/chmod",
            arguments: ["+a", "everyone allow add_file", directory.path]
        )
        XCTAssertEqual(aclResult.status, 0, aclResult.output)
        result = try runReleaseOutputHelper(
            command: command,
            arguments: [output.path, repositoryRoot.path]
        )
        XCTAssertEqual(result.status, 73, result.output)
    }

    func testReleasePublicationLockIsExclusiveAndNoClobber() throws {
        let directory = try releaseTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("result")
        let command = #"source "$1"; validate_release_output_request "$2" "$3" || exit $?; parent="$validated_release_output_parent"; parent_id="$validated_release_output_parent_identity"; name="$validated_release_output_name"; acquire_release_publication_lock "$parent" "$name" "$parent_id" || exit $?; lock="$validated_release_publication_lock"; lock_id="$validated_release_publication_lock_identity"; second=0; acquire_release_publication_lock "$parent" "$name" "$parent_id" || second=$?; printf '%s\n' "$second"; release_release_publication_lock "$lock" "$lock_id" "$parent" "$name" || exit $?; [[ "$second" == 73 ]]"#

        let result = try runReleaseOutputHelper(
            command: command,
            arguments: [output.path, repositoryRoot.path]
        )

        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertTrue(result.output.contains("73"), result.output)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: directory.path),
            []
        )
    }

    func testReleasePublicationRejectsExistingEmptyDestination() throws {
        let directory = try releaseTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("result")
        let command = #"source "$1"; validate_release_output_request "$2" "$3" || exit $?; parent="$validated_release_output_parent"; parent_id="$validated_release_output_parent_identity"; name="$validated_release_output_name"; build_atomic_release_publisher "$4" "$parent/atomic-release-publish" || exit $?; publisher="$validated_release_atomic_publisher"; publisher_id="$validated_release_atomic_publisher_identity"; publisher_hash="$validated_release_atomic_publisher_hash"; acquire_release_publication_lock "$parent" "$name" "$parent_id" || exit $?; lock="$validated_release_publication_lock"; lock_id="$validated_release_publication_lock_identity"; create_release_staging_directory "$parent" "$name" "$parent_id" race || exit $?; stage_parent="$validated_release_staging_parent"; stage_parent_id="$validated_release_staging_parent_identity"; stage="$validated_release_staging_directory"; stage_id="$validated_release_staging_directory_identity"; touch "$stage/staged"; mkdir "$parent/$name"; competitor_id="$(release_path_identity "$parent/$name")"; publish=0; publish_staged_release_directory "$stage" "$stage_id" "$parent" "$parent_id" "$name" "$publisher" "$publisher_id" "$publisher_hash" || publish=$?; [[ "$publish" == 73 && -f "$stage/staged" && -d "$parent/$name" && "$(release_path_identity "$parent/$name")" == "$competitor_id" && -z "$(find "$parent/$name" -mindepth 1 -print -quit)" ]] || exit 1; rmdir "$parent/$name"; cleanup_private_release_directory "$stage_parent" "$stage_parent_id" "$parent" '^\.AgentLimits-race-stage\.[A-Za-z0-9]{6}$' || exit $?; release_release_publication_lock "$lock" "$lock_id" "$parent" "$name" || exit $?; rm "$publisher""#

        let result = try runReleaseOutputHelper(
            command: command,
            arguments: [
                output.path,
                repositoryRoot.path,
                repositoryRoot.appendingPathComponent(
                    "Scripts/atomic-release-publish.c"
                ).path
            ]
        )

        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: directory.path),
            []
        )
    }

    func testAtomicPublisherNeverReplacesEmptyDestination() throws {
        let directory = try releaseTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source")
        let destination = directory.appendingPathComponent("destination")
        let publisher = directory.appendingPathComponent("atomic-release-publish")
        try FileManager.default.createDirectory(
            at: source,
            withIntermediateDirectories: false
        )
        try FileManager.default.createDirectory(
            at: destination,
            withIntermediateDirectories: false
        )
        try Data("staged".utf8).write(
            to: source.appendingPathComponent("payload")
        )
        let build = try runReleaseOutputHelper(
            command: #"source "$1"; build_atomic_release_publisher "$2" "$3""#,
            arguments: [
                repositoryRoot.appendingPathComponent(
                    "Scripts/atomic-release-publish.c"
                ).path,
                publisher.path
            ]
        )
        XCTAssertEqual(build.status, 0, build.output)
        let sourceIdentity = try fileIdentity(at: source)
        let destinationIdentity = try fileIdentity(at: destination)

        let result = try runProcess(
            executable: publisher.path,
            arguments: [source.path, destination.path]
        )

        XCTAssertEqual(result.status, 73, result.output)
        XCTAssertEqual(try fileIdentity(at: source), sourceIdentity)
        XCTAssertEqual(try fileIdentity(at: destination), destinationIdentity)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: source.appendingPathComponent("payload").path
            )
        )
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: destination.path),
            []
        )
    }

    func testReleasePublicationAtomicallyPreservesStagedIdentity() throws {
        let directory = try releaseTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("result")
        let command = #"source "$1"; validate_release_output_request "$2" "$3" || exit $?; parent="$validated_release_output_parent"; parent_id="$validated_release_output_parent_identity"; name="$validated_release_output_name"; build_atomic_release_publisher "$4" "$parent/atomic-release-publish" || exit $?; publisher="$validated_release_atomic_publisher"; publisher_id="$validated_release_atomic_publisher_identity"; publisher_hash="$validated_release_atomic_publisher_hash"; acquire_release_publication_lock "$parent" "$name" "$parent_id" || exit $?; lock="$validated_release_publication_lock"; lock_id="$validated_release_publication_lock_identity"; create_release_staging_directory "$parent" "$name" "$parent_id" atomic || exit $?; stage_parent="$validated_release_staging_parent"; stage="$validated_release_staging_directory"; stage_id="$validated_release_staging_directory_identity"; touch "$stage/payload"; publish_staged_release_directory "$stage" "$stage_id" "$parent" "$parent_id" "$name" "$publisher" "$publisher_id" "$publisher_hash" || exit $?; [[ ! -e "$stage" && -f "$parent/$name/payload" && "$(release_path_identity "$parent/$name")" == "$stage_id" ]] || exit 1; rmdir "$stage_parent"; release_release_publication_lock "$lock" "$lock_id" "$parent" "$name" || exit $?; rm "$publisher""#

        let result = try runReleaseOutputHelper(
            command: command,
            arguments: [
                output.path,
                repositoryRoot.path,
                repositoryRoot.appendingPathComponent(
                    "Scripts/atomic-release-publish.c"
                ).path
            ]
        )

        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: output.appendingPathComponent("payload").path
            )
        )
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: directory.path),
            ["result"]
        )
    }

    func testReleaseWorkDirectoryIgnoresHostileTMPDIRAndIsPrivate() throws {
        let hostileTMPDIR = try releaseTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: hostileTMPDIR) }
        let command = #"source "$1"; create_private_release_work_directory AgentLimits-test-work || exit $?; work="$validated_release_work_directory"; work_id="$validated_release_work_directory_identity"; configure_private_release_temporary_directory "$work" || exit $?; probe="$(mktemp "${TMPDIR}probe.XXXXXX")" || exit $?; [[ "$probe" == "$validated_release_temporary_directory/"* ]] || exit 1; printf '%s\n%s\n%s\n%s\n' "$work" "$(stat -f '%Lp' "$work")" "$(release_acl_entry_count "$work")" "$TMPDIR"; cleanup_private_release_directory "$work" "$work_id" /private/tmp '^AgentLimits-test-work\.[A-Za-z0-9]{6}$'"#

        let result = try runReleaseOutputHelper(
            command: command,
            environment: ["TMPDIR": hostileTMPDIR.path]
        )

        XCTAssertEqual(result.status, 0, result.output)
        let lines = result.output.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 4, result.output)
        XCTAssertTrue(lines[0].hasPrefix("/private/tmp/AgentLimits-test-work."), result.output)
        XCTAssertEqual(lines[1], "700", result.output)
        XCTAssertEqual(lines[2], "0", result.output)
        XCTAssertEqual(lines[3], "\(lines[0])/tmp/", result.output)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: hostileTMPDIR.path),
            []
        )
    }

    func testReleaseCleanupRefusesChangedIdentity() throws {
        let command = #"source "$1"; create_private_release_work_directory AgentLimits-cleanup-test || exit $?; work="$validated_release_work_directory"; work_id="$validated_release_work_directory_identity"; refused=0; cleanup_private_release_directory "$work" '0:0' /private/tmp '^AgentLimits-cleanup-test\.[A-Za-z0-9]{6}$' || refused=$?; [[ "$refused" == 73 && -d "$work" ]] || exit 1; cleanup_private_release_directory "$work" "$work_id" /private/tmp '^AgentLimits-cleanup-test\.[A-Za-z0-9]{6}$' || exit $?; [[ ! -e "$work" ]]"#

        let result = try runReleaseOutputHelper(command: command)

        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertTrue(result.output.contains("identity changed"), result.output)
    }

    func testReleaseCleanupNeverFollowsReplacementSymlink() throws {
        let directory = try releaseTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let protectedFile = directory.appendingPathComponent("protected")
        try Data("keep".utf8).write(to: protectedFile)
        let command = #"source "$1"; create_private_release_work_directory AgentLimits-cleanup-link || exit $?; work="$validated_release_work_directory"; work_id="$validated_release_work_directory_identity"; rmdir "$work"; ln -s "$2" "$work"; trap '[[ ! -L "$work" ]] || rm "$work"' EXIT; refused=0; cleanup_private_release_directory "$work" "$work_id" /private/tmp '^AgentLimits-cleanup-link\.[A-Za-z0-9]{6}$' || refused=$?; [[ "$refused" == 73 && -L "$work" && -f "$2/protected" ]]"#

        let result = try runReleaseOutputHelper(
            command: command,
            arguments: [directory.path]
        )

        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertEqual(
            try String(contentsOf: protectedFile, encoding: .utf8),
            "keep"
        )
    }

    func testUnsignedBuildUsesCleanSnapshotAndAtomicStaging() throws {
        let script = try releaseScript(named: "build-unsigned-artifacts.sh")
        let containerValidation = try releaseScript(
            named: "macos-container-validation.sh"
        )

        XCTAssertTrue(script.contains("PATH=\"/usr/bin:/bin:/usr/sbin:/sbin\""))
        XCTAssertTrue(script.contains("source \"$script_dir/signing-config.sh\""))
        XCTAssertTrue(script.contains("sanitize_release_git_environment"))
        XCTAssertTrue(script.contains("unset CDPATH"))
        XCTAssertTrue(script.contains("Refusing to run a release build through a script symlink"))
        XCTAssertTrue(script.contains("git -C \"$project_root\" archive"))
        XCTAssertTrue(script.contains("$build_root/AgentLimits.xcodeproj"))
        XCTAssertTrue(
            script.contains("prepare_xcode_signing_environment \"$snapshot_config\"")
        )
        XCTAssertTrue(script.contains("verify_source_unchanged"))
        XCTAssertTrue(script.contains("-derivedDataPath \"$derived_data\""))
        XCTAssertTrue(script.contains("output_parent_owner"))
        XCTAssertTrue(script.contains("output_parent_mode"))
        XCTAssertTrue(script.contains("output_parent_mutating_acl_entries"))
        XCTAssertTrue(
            script.contains(
                "mktemp -d \"$output_parent/.AgentLimits-unsigned-stage.XXXXXX\""
            )
        )
        XCTAssertTrue(script.contains("publication_lock"))
        XCTAssertTrue(script.contains("publish_staged_directory"))
        XCTAssertTrue(
            containerValidation.contains("Output path appeared while building")
        )
    }

    func testUnsignedBuildValidatesEveryBundleIdentityAndVersion() throws {
        let script = try releaseScript(named: "build-unsigned-artifacts.sh")

        for identifier in [
            "com.jimboha.agentlimits.macos",
            "com.jimboha.agentlimits.macos.widget",
            "com.jimboha.agentlimits.ios",
            "com.jimboha.agentlimits.ios.watchkitapp"
        ] {
            XCTAssertTrue(script.contains(identifier), identifier)
        }
        XCTAssertTrue(
            script.contains(
                "macOS, widget, iOS, and watchOS version/build values are not synchronized"
            )
        )
        XCTAssertTrue(script.contains("verify_archive_has_no_signing_metadata"))
        XCTAssertTrue(script.contains("verify_linker_adhoc_bundle"))
        XCTAssertTrue(script.contains("verify_no_code_signature_for_architecture"))
        XCTAssertTrue(script.contains("verify_unsigned_product_package"))
        XCTAssertTrue(script.contains("verify_unsigned_disk_image"))
        XCTAssertTrue(script.contains("embedded.mobileprovision"))
        XCTAssertTrue(script.contains("embedded.provisionprofile"))
        XCTAssertTrue(script.contains("ApplicationProperties.Team"))
        XCTAssertTrue(script.contains("ApplicationProperties.SigningIdentity"))
    }

    func testReleaseBuildsUseOnlyResolvedPackageVersions() throws {
        let lockFlag = "-onlyUsePackageVersionsFromResolvedFile"
        for name in [
            "build-unsigned-artifacts.sh",
            "package-macos.sh",
            "export-ios.sh"
        ] {
            let script = try releaseScript(named: name)
            let commands = xcodebuildCommands(in: script)
            let dependencyResolvingCommands = commands.filter {
                $0.contains("xcodebuild archive") || $0.contains("-showBuildSettings")
            }
            XCTAssertEqual(dependencyResolvingCommands.count, 2, name)
            XCTAssertTrue(
                dependencyResolvingCommands.allSatisfy { $0.contains(lockFlag) },
                name
            )
            XCTAssertTrue(
                dependencyResolvingCommands.allSatisfy {
                    $0.contains("-derivedDataPath \"$derived_data\"")
                },
                name
            )
            XCTAssertTrue(
                commands.filter { $0.contains("-exportArchive") }
                    .allSatisfy { !$0.contains(lockFlag) },
                name
            )
        }
    }

    func testReleaseToolEnvironmentDropsLoaderPerlGrepAndTarOverrides() throws {
        let hostileEnvironment = [
            "CCC_ADD_ARGS": "-fplugin=/private/tmp/hostile.dylib",
            "CCC_FUTURE_OVERRIDE": "hostile",
            "DYLD_INSERT_LIBRARIES": "/private/tmp/hostile.dylib",
            "DYLD_LIBRARY_PATH": "/private/tmp/hostile-library",
            "DYLD_FUTURE_OVERRIDE": "hostile",
            "BASH_ENV": "/dev/null",
            "ENV": "/dev/null",
            "GREP_OPTIONS": "--invert-match",
            "PERL5OPT": "-Mhostile",
            "PERL5LIB": "/private/tmp/hostile-perl5",
            "PERLLIB": "/private/tmp/hostile-perl",
            "TAR_READER_OPTIONS": "mtree:checkfs",
            "TAR_WRITER_OPTIONS": "zip:compression=store",
            "COPYFILE_DISABLE": "1"
        ]
        let command = #"source "$1"; sanitize_release_tool_environment; /usr/bin/env"#

        let result = try runSigningConfigHelper(
            command: command,
            environment: hostileEnvironment
        )

        XCTAssertEqual(result.status, 0, result.output)
        let sanitized = environmentDictionary(from: result.output)
        for variable in hostileEnvironment.keys {
            XCTAssertNil(sanitized[variable], variable + ": " + result.output)
        }
    }

    func testHostileXcodeEnvironmentIsReplaced() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = directory.appendingPathComponent("sanitized.xcconfig")
        try Data("DEVELOPMENT_TEAM = ABCDE12345\n".utf8).write(to: config)
        let hostileEnvironment = [
            "XCODE_XCCONFIG_FILE": "/private/tmp/hostile.xcconfig",
            "TOOLCHAINS": "hostile",
            "XCRUN_TOOLCHAIN_NAME": "hostile",
            "SDKROOT": "/private/tmp/hostile-sdk",
            "CCC_ADD_ARGS": "-fplugin=/private/tmp/hostile.dylib",
            "CCC_OVERRIDE_OPTIONS": "^--driver-mode=g++",
            "CCC_PRINT_OPTIONS": "1",
            "CCC_PRINT_OPTIONS_FILE": "/private/tmp/hostile-options",
            "ADDITIONAL_SWIFT_DRIVER_FLAGS": "-load-plugin-library /private/tmp/hostile.dylib",
            "OTHER_CFLAGS": "-fplugin=/private/tmp/hostile.dylib",
            "OTHER_CPLUSPLUSFLAGS": "-I/private/tmp/hostile-include",
            "OTHER_LDFLAGS": "-L/private/tmp/hostile-library",
            "OTHER_SWIFT_FLAGS": "-load-plugin-library /private/tmp/hostile.dylib",
            "CLANG_FUTURE_OVERRIDE": "/private/tmp/hostile-clang",
            "RC_FUTURE_OVERRIDE": "/private/tmp/hostile-rc",
            "GCC_FUTURE_OVERRIDE": "/private/tmp/hostile-gcc",
            "COMPILER_PATH": "/private/tmp/hostile-bin",
            "GCC_EXEC_PREFIX": "/private/tmp/hostile-prefix",
            "CPATH": "/private/tmp/hostile-include",
            "C_INCLUDE_PATH": "/private/tmp/hostile-c",
            "CPLUS_INCLUDE_PATH": "/private/tmp/hostile-cxx",
            "OBJC_INCLUDE_PATH": "/private/tmp/hostile-objc",
            "OBJCPLUS_INCLUDE_PATH": "/private/tmp/hostile-objcxx",
            "LIBRARY_PATH": "/private/tmp/hostile-library",
            "FRAMEWORK_SEARCH_PATHS": "/private/tmp/hostile-frameworks",
            "HEADER_SEARCH_PATHS": "/private/tmp/hostile-headers",
            "LIBRARY_SEARCH_PATHS": "/private/tmp/hostile-library-search",
            "SWIFT_DRIVER_SWIFT_FRONTEND_EXEC": "/private/tmp/hostile-frontend",
            "SWIFT_DRIVER_SWIFTSCAN_LIB": "/private/tmp/hostile-swiftscan.dylib",
            "SWIFT_DRIVER_TOOLCHAIN_CASPLUGIN_LIB": "/private/tmp/hostile-cas.dylib",
            "SWIFT_PLUGIN_SEARCH_PATHS": "/private/tmp/hostile-plugins",
            "LD_LIBRARY_PATH": "/private/tmp/hostile-ld",
            "DYLD_INSERT_LIBRARIES": "/private/tmp/hostile.dylib",
            "DYLD_FRAMEWORK_PATH": "/private/tmp/hostile-frameworks",
            "GREP_OPTIONS": "--invert-match",
            "PERL5OPT": "-Mhostile",
            "PERL5LIB": "/private/tmp/hostile-perl5",
            "PERLLIB": "/private/tmp/hostile-perl",
            "TAR_READER_OPTIONS": "mtree:checkfs",
            "TAR_WRITER_OPTIONS": "zip:compression=store",
            "ZERO_AR_DATE": "1",
            "xcrun_verbose": "1",
            "xcrun_log": "/private/tmp/hostile-xcrun.log"
        ]
        let command = #"source "$1"; prepare_xcode_signing_environment "$2"; /usr/bin/env"#

        let result = try runSigningConfigValidator(
            config: config,
            command: command,
            environment: hostileEnvironment
        )

        XCTAssertEqual(result.status, 0, result.output)
        let sanitized = environmentDictionary(from: result.output)
        XCTAssertEqual(sanitized["XCODE_XCCONFIG_FILE"], config.path)
        for variable in hostileEnvironment.keys
            where variable != "XCODE_XCCONFIG_FILE" {
            XCTAssertNil(sanitized[variable], variable + ": " + result.output)
        }
    }

    func testAppleToolchainProbeUsesEnvironmentAllowlist() throws {
        let hostileEnvironment = [
            "CCC_ADD_ARGS": "-fplugin=/private/tmp/hostile.dylib",
            "CCC_OVERRIDE_OPTIONS": "^--driver-mode=g++",
            "ADDITIONAL_SWIFT_DRIVER_FLAGS": "-load-plugin-library hostile",
            "DYLD_INSERT_LIBRARIES": "/private/tmp/hostile.dylib",
            "GREP_OPTIONS": "--invert-match",
            "PERL5OPT": "-Mhostile",
            "TAR_READER_OPTIONS": "mtree:checkfs",
            "XCODE_XCCONFIG_FILE": "/private/tmp/hostile.xcconfig",
            "xcrun_verbose": "1",
            "xcrun_log": "/private/tmp/hostile-xcrun.log"
        ]
        let command = #"source "$1"; apple_run_selected_tool /private/tmp/FixtureXcode.app/Contents/Developer /usr/bin/env"#

        let result = try runAppleToolchainHelper(
            command: command,
            environment: hostileEnvironment
        )

        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertEqual(
            environmentDictionary(from: result.output),
            [
                "DEVELOPER_DIR": "/private/tmp/FixtureXcode.app/Contents/Developer",
                "LC_ALL": "C",
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "TMPDIR": "/private/tmp/"
            ]
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
        let staple = try offset(
            of: #"/usr/bin/xcrun --no-cache stapler staple "$app""#,
            in: script
        )

        XCTAssertLessThan(accepted, validate)
        XCTAssertLessThan(validate, staple)
    }

    func testMacNotaryAndStaplerUseAbsoluteUncachedXcrun() throws {
        let script = try packageScript()

        XCTAssertEqual(
            occurrenceCount(
                of: "/usr/bin/xcrun --no-cache notarytool submit",
                in: script
            ),
            1
        )
        XCTAssertEqual(
            occurrenceCount(
                of: "/usr/bin/xcrun --no-cache notarytool log",
                in: script
            ),
            1
        )
        XCTAssertEqual(
            occurrenceCount(
                of: "/usr/bin/xcrun --no-cache stapler staple",
                in: script
            ),
            3
        )
        XCTAssertEqual(
            occurrenceCount(
                of: "/usr/bin/xcrun --no-cache stapler validate",
                in: script
            ),
            4
        )
        let relevantCalls = script.split(separator: "\n").map {
            $0.trimmingCharacters(in: .whitespaces)
        }.filter {
            $0.contains("notarytool") || $0.contains("stapler")
        }.filter {
            !$0.hasPrefix("#") && !$0.contains("Notarization and stapling")
        }
        XCTAssertEqual(relevantCalls.count, 9, relevantCalls.joined(separator: "\n"))
        XCTAssertTrue(
            relevantCalls.allSatisfy {
                $0.hasPrefix("/usr/bin/xcrun --no-cache ")
            },
            relevantCalls.joined(separator: "\n")
        )
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
        let staple = try offset(
            of: "/usr/bin/xcrun --no-cache stapler staple \"$dmg\"",
            in: script
        )
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

    func testLinkerAdHocSignatureValidationRejectsDistributionMetadata() throws {
        let identifier = "AgentLimitsForked"
        let validDetails = """
        Identifier=\(identifier)
        CodeDirectory v=20400 size=426 flags=0x20002(adhoc,linker-signed) hashes=10+0 location=embedded
        Signature=adhoc
        Info.plist=not bound
        TeamIdentifier=not set
        Sealed Resources=none
        Internal requirements=none
        """
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let detailsFile = directory.appendingPathComponent("codesign.txt")
        let command = #"source "$1"; details="$(cat "$2")"; validate_linker_adhoc_signature_details "$details" "$3" component"#

        try Data(validDetails.utf8).write(to: detailsFile)
        var result = try runMacCodeSigningHelper(
            command: command,
            arguments: [detailsFile.path, identifier]
        )
        XCTAssertEqual(result.status, 0, result.output)

        for invalid in [
            validDetails.replacingOccurrences(
                of: "TeamIdentifier=not set",
                with: "TeamIdentifier=ABCDE12345"
            ),
            validDetails + "\nAuthority=Developer ID Application: Example\n",
            validDetails.replacingOccurrences(
                of: "flags=0x20002(adhoc,linker-signed)",
                with: "flags=0x10000(runtime)"
            )
        ] {
            try Data(invalid.utf8).write(to: detailsFile)
            result = try runMacCodeSigningHelper(
                command: command,
                arguments: [detailsFile.path, identifier]
            )
            XCTAssertNotEqual(result.status, 0, result.output)
        }
    }

    func testUnsignedCodeDiagnosticRequiresExactCodesignFailure() throws {
        let command = #"source "$1"; validate_no_code_signature_diagnostic "$2" "$3" component"#
        let unsignedDetails = "/tmp/Product: code object is not signed at all"

        var result = try runMacCodeSigningHelper(
            command: command,
            arguments: [unsignedDetails, "1"]
        )
        XCTAssertEqual(result.status, 0, result.output)

        for (details, status) in [
            (unsignedDetails, "0"),
            ("/tmp/Product: bundle format unrecognized", "1"),
            ("Signature=adhoc", "0")
        ] {
            result = try runMacCodeSigningHelper(
                command: command,
                arguments: [details, status]
            )
            XCTAssertNotEqual(result.status, 0, result.output)
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

    func testDeviceArchitectureValidationRejectsExtraSlices() throws {
        let watchCommand = #"source "$1"; validate_exact_binary_architectures "$2" watch arm64 arm64_32"#
        for architectures in ["arm64 arm64_32", "arm64_32 arm64"] {
            let result = try runMacCodeSigningHelper(
                command: watchCommand,
                arguments: [architectures]
            )
            XCTAssertEqual(result.status, 0, result.output)
        }
        for architectures in [
            "arm64",
            "arm64_32",
            "arm64 arm64_32 x86_64"
        ] {
            let result = try runMacCodeSigningHelper(
                command: watchCommand,
                arguments: [architectures]
            )
            XCTAssertNotEqual(result.status, 0, result.output)
        }

        let iOSCommand = #"source "$1"; validate_exact_binary_architectures "$2" ios arm64"#
        var result = try runMacCodeSigningHelper(
            command: iOSCommand,
            arguments: ["arm64"]
        )
        XCTAssertEqual(result.status, 0, result.output)
        result = try runMacCodeSigningHelper(
            command: iOSCommand,
            arguments: ["arm64 x86_64"]
        )
        XCTAssertNotEqual(result.status, 0, result.output)
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

    func testZIPAndDMGLayoutsRejectExtraOrRedirectedContent() throws {
        let zipRoot = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: zipRoot) }
        let zipApp = zipRoot.appendingPathComponent("AgentLimitsForked.app")
        try FileManager.default.createDirectory(at: zipApp, withIntermediateDirectories: false)
        let zipCommand = #"source "$1"; validate_zip_container_root "$2" || exit $?; printf '%s\n' "$validated_container_app""#
        var result = try runMacContainerHelper(
            command: zipCommand,
            arguments: [zipRoot.path]
        )
        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertEqual(result.output.trimmingCharacters(in: .whitespacesAndNewlines), zipApp.path)

        try Data("unexpected".utf8).write(
            to: zipRoot.appendingPathComponent("unexpected.txt")
        )
        result = try runMacContainerHelper(
            command: zipCommand,
            arguments: [zipRoot.path]
        )
        XCTAssertNotEqual(result.status, 0, result.output)

        let symlinkRoot = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: symlinkRoot) }
        try FileManager.default.createSymbolicLink(
            atPath: symlinkRoot.appendingPathComponent("AgentLimitsForked.app").path,
            withDestinationPath: "/Applications"
        )
        result = try runMacContainerHelper(
            command: zipCommand,
            arguments: [symlinkRoot.path]
        )
        XCTAssertNotEqual(result.status, 0, result.output)

        let dmgRoot = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dmgRoot) }
        let dmgApp = dmgRoot.appendingPathComponent("AgentLimitsForked.app")
        try FileManager.default.createDirectory(at: dmgApp, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(
            atPath: dmgRoot.appendingPathComponent("Applications").path,
            withDestinationPath: "/Applications"
        )
        let dmgCommand = #"source "$1"; validate_dmg_container_root "$2" || exit $?; printf '%s\n' "$validated_container_app""#
        result = try runMacContainerHelper(
            command: dmgCommand,
            arguments: [dmgRoot.path]
        )
        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertEqual(result.output.trimmingCharacters(in: .whitespacesAndNewlines), dmgApp.path)

        try FileManager.default.removeItem(
            at: dmgRoot.appendingPathComponent("Applications")
        )
        try FileManager.default.createSymbolicLink(
            atPath: dmgRoot.appendingPathComponent("Applications").path,
            withDestinationPath: "/tmp"
        )
        result = try runMacContainerHelper(
            command: dmgCommand,
            arguments: [dmgRoot.path]
        )
        XCTAssertNotEqual(result.status, 0, result.output)
    }

    func testArchiveTreeManifestDetectsContentAndSymlinkChanges() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source")
        let candidate = directory.appendingPathComponent("candidate")
        let sourceSubdirectory = source.appendingPathComponent("subdirectory")
        let candidateSubdirectory = candidate.appendingPathComponent("subdirectory")
        try FileManager.default.createDirectory(
            at: sourceSubdirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: candidateSubdirectory,
            withIntermediateDirectories: true
        )
        try Data("same".utf8).write(
            to: sourceSubdirectory.appendingPathComponent("file")
        )
        try Data("same".utf8).write(
            to: candidateSubdirectory.appendingPathComponent("file")
        )
        try FileManager.default.createSymbolicLink(
            atPath: source.appendingPathComponent("link").path,
            withDestinationPath: "subdirectory/file"
        )
        try FileManager.default.createSymbolicLink(
            atPath: candidate.appendingPathComponent("link").path,
            withDestinationPath: "subdirectory/file"
        )
        let reference = directory.appendingPathComponent("reference.tree")
        let actual = directory.appendingPathComponent("actual.tree")
        let command = #"source "$1"; create_tree_manifest "$2" "$3" || exit $?; validate_tree_matches_manifest "$4" "$3" "$5" fixture"#

        var result = try runMacContainerHelper(
            command: command,
            arguments: [
                source.path,
                reference.path,
                candidate.path,
                actual.path
            ]
        )
        XCTAssertEqual(result.status, 0, result.output)

        try Data("changed".utf8).write(
            to: candidateSubdirectory.appendingPathComponent("file")
        )
        result = try runMacContainerHelper(
            command: command,
            arguments: [
                source.path,
                reference.path,
                candidate.path,
                actual.path
            ]
        )
        XCTAssertNotEqual(result.status, 0, result.output)

        try Data("same".utf8).write(
            to: candidateSubdirectory.appendingPathComponent("file")
        )
        try FileManager.default.removeItem(at: candidate.appendingPathComponent("link"))
        try FileManager.default.createSymbolicLink(
            atPath: candidate.appendingPathComponent("link").path,
            withDestinationPath: "unexpected"
        )
        result = try runMacContainerHelper(
            command: command,
            arguments: [
                source.path,
                reference.path,
                candidate.path,
                actual.path
            ]
        )
        XCTAssertNotEqual(result.status, 0, result.output)
    }

    func testTreeManifestFailsForUnreadableContent() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = directory.appendingPathComponent("root")
        let blockedDirectory = root.appendingPathComponent("blocked")
        let blockedFile = root.appendingPathComponent("blocked-file")
        let manifest = directory.appendingPathComponent("manifest.tree")
        try FileManager.default.createDirectory(
            at: blockedDirectory,
            withIntermediateDirectories: true
        )
        try Data("secret".utf8).write(to: blockedFile)
        let command = #"source "$1"; create_tree_manifest "$2" "$3""#

        try setPermissions(0o000, for: blockedFile)
        var result = try runMacContainerHelper(
            command: command,
            arguments: [root.path, manifest.path]
        )
        XCTAssertNotEqual(result.status, 0, result.output)
        XCTAssertFalse(FileManager.default.fileExists(atPath: manifest.path))
        try setPermissions(0o600, for: blockedFile)

        try Data("hidden".utf8).write(
            to: blockedDirectory.appendingPathComponent("file")
        )
        try setPermissions(0o000, for: blockedDirectory)
        result = try runMacContainerHelper(
            command: command,
            arguments: [root.path, manifest.path]
        )
        try setPermissions(0o700, for: blockedDirectory)
        XCTAssertNotEqual(result.status, 0, result.output)
        XCTAssertFalse(FileManager.default.fileExists(atPath: manifest.path))
    }

    func testStagedPublicationNeverNestsIntoExistingDestination() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let stageParent = directory.appendingPathComponent("stage")
        let outputParent = directory.appendingPathComponent("output")
        let staged = stageParent.appendingPathComponent("result")
        let existing = outputParent.appendingPathComponent("result")
        try FileManager.default.createDirectory(
            at: staged,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: existing,
            withIntermediateDirectories: true
        )
        try Data("staged".utf8).write(to: staged.appendingPathComponent("file"))
        try Data("existing".utf8).write(
            to: existing.appendingPathComponent("competitor")
        )
        let command = #"source "$1"; publish_staged_directory "$2" "$3" result"#

        var result = try runMacContainerHelper(
            command: command,
            arguments: [staged.path, outputParent.path]
        )
        XCTAssertEqual(result.status, 73, result.output)
        XCTAssertTrue(FileManager.default.fileExists(atPath: staged.path))
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: existing.appendingPathComponent("competitor").path
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: existing.appendingPathComponent("result").path
            )
        )

        try FileManager.default.removeItem(at: existing)
        result = try runMacContainerHelper(
            command: command,
            arguments: [staged.path, outputParent.path]
        )
        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path))
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: outputParent
                    .appendingPathComponent("result/file").path
            )
        )
    }

    func testExpandedProductPackageLayoutAndMetadataFailClosed() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try createProductPackageFixture(at: root)
        let command = #"source "$1"; validate_product_package_layout "$2" 1.1.6 16 || exit $?; printf '%s\n' "$validated_container_app""#

        var result = try runMacContainerHelper(
            command: command,
            arguments: [root.path]
        )
        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertTrue(result.output.contains("Payload/AgentLimitsForked.app"))

        let packageInfo = root
            .appendingPathComponent("com.jimboha.agentlimits.macos.pkg/PackageInfo")
        let validPackageInfo = try String(contentsOf: packageInfo, encoding: .utf8)
        try Data(
            validPackageInfo.replacingOccurrences(
                of: "install-location=\"/Applications\"",
                with: "install-location=\"/tmp\""
            ).utf8
        ).write(to: packageInfo)
        result = try runMacContainerHelper(
            command: command,
            arguments: [root.path]
        )
        XCTAssertNotEqual(result.status, 0, result.output)

        try Data(validPackageInfo.utf8).write(to: packageInfo)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(
                "com.jimboha.agentlimits.macos.pkg/Scripts"
            ),
            withIntermediateDirectories: false
        )
        result = try runMacContainerHelper(
            command: command,
            arguments: [root.path]
        )
        XCTAssertNotEqual(result.status, 0, result.output)
    }

    func testDMGAttachmentMetadataRequiresOneReadOnlyExpectedVolume() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let attach = directory.appendingPathComponent("attach.json")
        let disk = directory.appendingPathComponent("disk.json")
        let mount = "/private/tmp/AgentLimitsDMG"
        let attachObject: [String: Any] = [
            "system-entities": [
                [
                    "content-hint": "Apple_HFS",
                    "mount-point": mount,
                    "dev-entry": "/dev/disk4s1",
                    "volume-kind": "hfs"
                ],
                [
                    "content-hint": "GUID_partition_scheme",
                    "dev-entry": "/dev/disk4"
                ]
            ]
        ]
        let validDiskObject: [String: Any] = [
            "MountPoint": mount,
            "DeviceNode": "/dev/disk4s1",
            "FilesystemType": "hfs",
            "FilesystemName": "HFS+",
            "VolumeName": "AgentLimits Forked",
            "WritableVolume": false,
            "Writable": false,
            "WritableMedia": false
        ]
        try JSONSerialization.data(withJSONObject: attachObject).write(to: attach)
        try JSONSerialization.data(withJSONObject: validDiskObject).write(to: disk)
        let command = #"source "$1"; validate_dmg_attachment_metadata "$2" "$3" "$4" || exit $?; printf '%s\n' "$validated_dmg_device""#

        var result = try runMacContainerHelper(
            command: command,
            arguments: [attach.path, disk.path, mount]
        )
        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertEqual(result.output.trimmingCharacters(in: .whitespacesAndNewlines), "/dev/disk4s1")

        var writableDiskObject = validDiskObject
        writableDiskObject["WritableVolume"] = true
        try JSONSerialization.data(withJSONObject: writableDiskObject).write(to: disk)
        result = try runMacContainerHelper(
            command: command,
            arguments: [attach.path, disk.path, mount]
        )
        XCTAssertNotEqual(result.status, 0, result.output)

        try JSONSerialization.data(withJSONObject: validDiskObject).write(to: disk)
        result = try runMacContainerHelper(
            command: command,
            arguments: [attach.path, disk.path, "/private/tmp/OtherMount"]
        )
        XCTAssertNotEqual(result.status, 0, result.output)
    }

    func testFinalContainersReopenBeforeChecksums() throws {
        let script = try packageScript()
        let zipCreate = try offset(
            of: #"ditto -c -k --sequesterRsrc --keepParent "$app" "$zip""#,
            in: script
        )
        let zipExtract = try offset(of: #"ditto -x -k "$zip""#, in: script)
        let pkgStaple = try offset(
            of: #"/usr/bin/xcrun --no-cache stapler staple "$pkg""#,
            in: script
        )
        let pkgExpand = try offset(of: #"pkgutil --expand-full "$pkg""#, in: script)
        let dmgStaple = try offset(
            of: #"/usr/bin/xcrun --no-cache stapler staple "$dmg""#,
            in: script
        )
        let postStapleVerify = try offset(
            of: #"hdiutil verify "$dmg""#,
            in: script,
            after: dmgStaple
        )
        let dmgAttach = try offset(of: "hdiutil attach", in: script)
        let dmgDetach = try offset(
            of: #"hdiutil detach "$dmg_attached_device" -quiet"#,
            in: script,
            after: dmgAttach
        )
        let checksums = try offset(of: "> SHA256SUMS", in: script)

        XCTAssertLessThan(zipCreate, zipExtract)
        XCTAssertLessThan(pkgStaple, pkgExpand)
        XCTAssertLessThan(dmgStaple, postStapleVerify)
        XCTAssertLessThan(postStapleVerify, dmgAttach)
        XCTAssertLessThan(dmgAttach, dmgDetach)
        XCTAssertLessThan(dmgDetach, checksums)
        XCTAssertTrue(script.contains("source \"$script_dir/macos-container-validation.sh\""))
        XCTAssertTrue(script.contains("Signed with a trusted timestamp"))
        XCTAssertTrue(script.contains("verify_packaged_app \"$zip_app\""))
        XCTAssertTrue(script.contains("verify_packaged_app \"$pkg_app\""))
        XCTAssertTrue(script.contains("verify_packaged_app \"$mounted_app\""))
        XCTAssertTrue(script.contains("-readonly"))
        let outputHelper = try releaseScript(named: "release-output.sh")
        XCTAssertTrue(
            outputHelper.contains(
                "mktemp -d \"/private/tmp/AgentLimits-macos-package.XXXXXX\""
            ) || outputHelper.contains("/private/tmp/$work_label.XXXXXX")
        )
    }

    func testSignedBuildMetadataIsIncludedInChecksumsBeforePublication() throws {
        let ios = try releaseScript(named: "export-ios.sh")
        let iosMetadata = try offset(
            of: #"cat >"$output_dir/BUILD-METADATA.txt""#,
            in: ios
        )
        let iosChecksums = try offset(of: "> SHA256SUMS", in: ios)
        let iosPublish = try offset(
            of: "publish_staged_release_directory",
            in: ios
        )
        XCTAssertLessThan(iosMetadata, iosChecksums)
        XCTAssertLessThan(iosChecksums, iosPublish)
        XCTAssertEqual(occurrenceCount(of: "> SHA256SUMS", in: ios), 1)
        XCTAssertTrue(
            ios.contains(
                #"shasum -a 256 "$ipa_name" BUILD-METADATA.txt > SHA256SUMS"#
            )
        )

        let mac = try releaseScript(named: "package-macos.sh")
        let macMetadata = try offset(
            of: #"cat >"$output_dir/BUILD-METADATA.txt""#,
            in: mac
        )
        let macChecksums = try offset(of: "> SHA256SUMS", in: mac)
        let macPublish = try offset(
            of: "publish_staged_release_directory",
            in: mac
        )
        XCTAssertLessThan(macMetadata, macChecksums)
        XCTAssertLessThan(macChecksums, macPublish)
        XCTAssertEqual(occurrenceCount(of: "> SHA256SUMS", in: mac), 1)
        XCTAssertTrue(
            mac.contains("BUILD-METADATA.txt \\\n        > SHA256SUMS")
        )
    }

    func testDependentWatchSchemeCannotArchiveStandaloneInstaller() throws {
        let scheme = try schemeDocument(named: "AgentLimitsWatch")
        let watchEntries = try scheme.nodes(
            forXPath: "//BuildActionEntry[BuildableReference[@BlueprintIdentifier='D30000000000000000000008']]"
        )
        let watchEntry = try XCTUnwrap(watchEntries.first as? XMLElement)

        XCTAssertEqual(watchEntries.count, 1)
        XCTAssertEqual(
            watchEntry.attribute(forName: "buildForArchiving")?.stringValue,
            "NO"
        )
        XCTAssertEqual(
            try scheme.nodes(forXPath: "//ArchiveAction").count,
            0,
            "A dependent Watch app must not expose a standalone Archive action"
        )

        for supportedAction in [
            "buildForTesting",
            "buildForRunning",
            "buildForProfiling",
            "buildForAnalyzing"
        ] {
            XCTAssertEqual(
                watchEntry.attribute(forName: supportedAction)?.stringValue,
                "YES",
                supportedAction
            )
        }
    }

    func testIOSReleaseArchiveEmbedsDependentWatchApp() throws {
        let scheme = try schemeDocument(named: "AgentLimitsiOS")
        let iosEntries = try scheme.nodes(
            forXPath: "//BuildActionEntry[BuildableReference[@BlueprintIdentifier='B20000000000000000000016']]"
        )
        let iosEntry = try XCTUnwrap(iosEntries.first as? XMLElement)
        XCTAssertEqual(iosEntries.count, 1)
        XCTAssertEqual(
            iosEntry.attribute(forName: "buildForArchiving")?.stringValue,
            "YES"
        )
        let archiveAction = try XCTUnwrap(
            try scheme.nodes(forXPath: "//ArchiveAction").first as? XMLElement
        )
        XCTAssertEqual(
            archiveAction.attribute(forName: "buildConfiguration")?.stringValue,
            "Release"
        )

        let project = try repositoryText("AgentLimits.xcodeproj/project.pbxproj")
        let iosTarget = try projectObject(
            "B20000000000000000000016 /* AgentLimitsiOS */",
            in: project
        )
        XCTAssertTrue(
            iosTarget.contains(
                "D30000000000000000000015 /* Embed Watch Content */"
            )
        )
        XCTAssertTrue(
            iosTarget.contains("D30000000000000000000018 /* PBXTargetDependency */")
        )

        let embedPhase = try projectObject(
            "D30000000000000000000015 /* Embed Watch Content */",
            in: project
        )
        XCTAssertTrue(embedPhase.contains("dstSubfolderSpec = 16;"))
        XCTAssertTrue(
            embedPhase.contains(
                "D30000000000000000000014 /* AgentLimitsWatch.app in Embed Watch Content */"
            )
        )

        let watchDependency = try projectObject(
            "D30000000000000000000018 /* PBXTargetDependency */",
            in: project
        )
        XCTAssertTrue(
            watchDependency.contains(
                "target = D30000000000000000000008 /* AgentLimitsWatch */;"
            )
        )

        let watchRelease = try projectObject(
            "D3000000000000000000001E /* Release */",
            in: project
        )
        XCTAssertTrue(watchRelease.contains("SKIP_INSTALL = YES;"))
        XCTAssertTrue(
            watchRelease.contains(
                "INFOPLIST_KEY_WKCompanionAppBundleIdentifier = com.jimboha.agentlimits.ios;"
            )
        )
        XCTAssertTrue(
            watchRelease.contains(
                "INFOPLIST_KEY_WKRunsIndependentlyOfCompanionApp = NO;"
            )
        )

        let infoData = try Data(
            contentsOf: repositoryRoot.appendingPathComponent("AgentLimitsWatch/Info.plist")
        )
        let info = try XCTUnwrap(
            PropertyListSerialization.propertyList(
                from: infoData,
                options: [],
                format: nil
            ) as? [String: Any]
        )
        XCTAssertEqual(
            info["WKCompanionAppBundleIdentifier"] as? String,
            "com.jimboha.agentlimits.ios"
        )
        XCTAssertEqual(info["WKRunsIndependentlyOfCompanionApp"] as? Bool, false)
    }

    func testUnsignedContainersReopenBeforePublication() throws {
        let script = try releaseScript(named: "build-unsigned-artifacts.sh")
        let zipCreate = try offset(
            of: #"ditto -c -k --sequesterRsrc --keepParent "$mac_app" "$mac_zip""#,
            in: script
        )
        let zipExtract = try offset(of: #"ditto -x -k "$mac_zip""#, in: script)
        let packageCreate = try offset(of: "productbuild", in: script)
        let packageExpand = try offset(
            of: #"pkgutil --expand-full "$mac_pkg""#,
            in: script
        )
        let dmgCreate = try offset(of: "hdiutil create", in: script)
        let dmgAttach = try offset(of: "hdiutil attach", in: script)
        let checksums = try offset(of: "> SHA256SUMS", in: script)
        let publish = try offset(of: "publish_staged_directory", in: script)

        XCTAssertLessThan(zipCreate, zipExtract)
        XCTAssertLessThan(packageCreate, packageExpand)
        XCTAssertLessThan(dmgCreate, dmgAttach)
        XCTAssertLessThan(zipExtract, checksums)
        XCTAssertLessThan(packageExpand, checksums)
        XCTAssertLessThan(dmgAttach, checksums)
        XCTAssertLessThan(checksums, publish)
        XCTAssertTrue(script.contains("--component \"$mac_app\" /Applications"))
        XCTAssertTrue(script.contains("validate_product_package_layout"))
        XCTAssertTrue(script.contains("validate_tree_matches_manifest"))
        XCTAssertTrue(script.contains("ARCHIVE-MANIFESTS"))
        XCTAssertTrue(
            script.contains("create_tree_manifest \"$mac_archive\" \"$mac_archive_manifest\"")
        )
        XCTAssertTrue(
            script.contains("create_tree_manifest \"$ios_archive\" \"$ios_archive_manifest\"")
        )
        XCTAssertTrue(script.contains("staged macOS archive"))
        XCTAssertTrue(script.contains("staged iOS/watchOS archive"))
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
        try repositoryText("Scripts/\(name)")
    }

    private func repositoryText(_ path: String) throws -> String {
        try String(
            contentsOf: repositoryRoot.appendingPathComponent(path),
            encoding: .utf8
        )
    }

    private func schemeDocument(named name: String) throws -> XMLDocument {
        let path = "AgentLimits.xcodeproj/xcshareddata/xcschemes/\(name).xcscheme"
        return try XMLDocument(
            data: Data(contentsOf: repositoryRoot.appendingPathComponent(path)),
            options: []
        )
    }

    private func projectObject(_ declaration: String, in project: String) throws -> String {
        let marker = "\n\t\t\(declaration) = {"
        let start = try XCTUnwrap(project.range(of: marker)?.lowerBound)
        let openingBrace = try XCTUnwrap(project[start...].firstIndex(of: "{"))
        var depth = 0

        for index in project[openingBrace...].indices {
            switch project[index] {
            case "{":
                depth += 1
            case "}":
                depth -= 1
                if depth == 0 {
                    return String(project[start...index])
                }
            default:
                break
            }
        }

        XCTFail("Unterminated project object: \(declaration)")
        return ""
    }

    private func xcodebuildCommands(in script: String) -> [String] {
        let lines = script.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        var commands: [String] = []
        var index = 0

        while index < lines.count {
            guard lines[index].contains("xcodebuild") else {
                index += 1
                continue
            }

            var command = lines[index]
            while lines[index].trimmingCharacters(in: .whitespaces).hasSuffix("\\"),
                  index + 1 < lines.count {
                index += 1
                command += "\n" + lines[index]
            }
            commands.append(command)
            index += 1
        }
        return commands
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

    private func createAppleToolchainFixture(
        at root: URL,
        dtxcode: String
    ) throws -> URL {
        let contents = root.appendingPathComponent(
            "FixtureXcode.app/Contents",
            isDirectory: true
        )
        let developerDirectory = contents.appendingPathComponent(
            "Developer",
            isDirectory: true
        )
        let binaryDirectory = developerDirectory.appendingPathComponent(
            "usr/bin",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: binaryDirectory,
            withIntermediateDirectories: true
        )
        let xcodebuild = binaryDirectory.appendingPathComponent("xcodebuild")
        try Data("#!/bin/sh\nexit 99\n".utf8).write(to: xcodebuild)
        try setPermissions(0o700, for: xcodebuild)
        let info: [String: Any] = ["DTXcode": dtxcode]
        try PropertyListSerialization.data(
            fromPropertyList: info,
            format: .xml,
            options: 0
        ).write(to: contents.appendingPathComponent("Info.plist"))
        return developerDirectory
    }

    private func releaseTemporaryDirectory() throws -> URL {
        let directory = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("AgentLimitsReleaseOutputTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
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

    private func createProductPackageFixture(at root: URL) throws {
        let component = root.appendingPathComponent(
            "com.jimboha.agentlimits.macos.pkg"
        )
        let payload = component.appendingPathComponent("Payload")
        try FileManager.default.createDirectory(
            at: payload.appendingPathComponent("AgentLimitsForked.app"),
            withIntermediateDirectories: true
        )
        try Data("bom".utf8).write(to: component.appendingPathComponent("Bom"))
        let distribution = """
        <?xml version="1.0" encoding="utf-8"?>
        <installer-gui-script minSpecVersion="2">
          <pkg-ref id="com.jimboha.agentlimits.macos">
            <bundle-version>
              <bundle CFBundleShortVersionString="1.1.6" CFBundleVersion="16" id="com.jimboha.agentlimits.macos" path="AgentLimitsForked.app"/>
            </bundle-version>
          </pkg-ref>
          <product id="com.jimboha.agentlimits.macos" version="1.1.6"/>
          <options customize="never" require-scripts="false" hostArchitectures="arm64,x86_64"/>
          <choice id="com.jimboha.agentlimits.macos" customLocation="/Applications"/>
          <pkg-ref id="com.jimboha.agentlimits.macos" version="1.1.6">#com.jimboha.agentlimits.macos.pkg</pkg-ref>
        </installer-gui-script>
        """
        try Data(distribution.utf8).write(
            to: root.appendingPathComponent("Distribution")
        )
        let packageInfo = """
        <?xml version="1.0" encoding="utf-8"?>
        <pkg-info relocatable="false" identifier="com.jimboha.agentlimits.macos" version="1.1.6" install-location="/Applications" auth="root" postinstall-action="none">
          <bundle path="./AgentLimitsForked.app" id="com.jimboha.agentlimits.macos" CFBundleShortVersionString="1.1.6" CFBundleVersion="16"/>
        </pkg-info>
        """
        try Data(packageInfo.utf8).write(
            to: component.appendingPathComponent("PackageInfo")
        )
    }

    private func setPermissions(_ permissions: Int, for url: URL) throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: permissions],
            ofItemAtPath: url.path
        )
    }

    private func runSigningConfigValidator(
        config: URL,
        command: String = #"source "$1"; validate_development_team_config "$2"; status=$?; if [[ $status -eq 0 ]]; then printf '%s\n' "$validated_development_team"; fi; exit "$status""#,
        environment: [String: String] = [:]
    ) throws -> (status: Int32, output: String) {
        try runSigningConfigHelper(
            command: command,
            arguments: [config.path],
            environment: environment
        )
    }

    private func runSigningConfigHelper(
        command: String,
        arguments: [String] = [],
        environment: [String: String] = [:]
    ) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [
            "-c",
            command,
            "signing-config-test",
            repositoryRoot.appendingPathComponent("Scripts/signing-config.sh").path
        ] + arguments
        process.environment = ProcessInfo.processInfo.environment.merging(
            environment,
            uniquingKeysWith: { _, override in override }
        )
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

    private func runReleaseScript(
        relativePath: String,
        arguments: [String],
        environment: [String: String]
    ) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [relativePath] + arguments
        process.currentDirectoryURL = repositoryRoot
        process.environment = ProcessInfo.processInfo.environment.merging(
            environment,
            uniquingKeysWith: { _, override in override }
        )
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

    private func runAppleToolchainHelper(
        command: String,
        arguments: [String] = [],
        environment: [String: String] = [:]
    ) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [
            "-c",
            command,
            "apple-toolchain-test",
            repositoryRoot.appendingPathComponent("Scripts/apple-toolchain.sh").path
        ] + arguments
        process.environment = ProcessInfo.processInfo.environment.merging(
            environment,
            uniquingKeysWith: { _, override in override }
        )
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

    private func runAppleToolchainFixture(
        developerDirectory: URL,
        xcodeVersion: String,
        xcodeBuild: String,
        sdkVersion: String,
        sdkBuild: String,
        platforms: [String]
    ) throws -> (status: Int32, output: String) {
        let command = #"""
        source "$1"
        fixture_developer_dir="$2"
        fixture_xcode_version="$3"
        fixture_xcode_build="$4"
        fixture_sdk_version="$5"
        fixture_sdk_build="$6"
        shift 6
        apple_validate_xcode_bundle_trust() {
            return 0
        }
        apple_run_selected_tool() {
            local developer_dir="$1"
            shift
            if [[ "$#" == 2 \
                && "$1" == "$developer_dir/usr/bin/xcodebuild" \
                && "$2" == "-version" ]]; then
                printf 'Xcode %s\nBuild version %s\n' \
                    "$fixture_xcode_version" "$fixture_xcode_build"
                return 0
            fi
            if [[ "$#" == 5 \
                && "$1" == /usr/bin/xcrun \
                && "$2" == --no-cache \
                && "$3" == --sdk ]]; then
                case "$4" in
                    macosx|iphoneos|watchos) ;;
                    *) return 97 ;;
                esac
                case "$5" in
                    --show-sdk-version)
                        printf '%s\n' "$fixture_sdk_version"
                        return 0
                        ;;
                    --show-sdk-build-version)
                        printf '%s\n' "$fixture_sdk_build"
                        return 0
                        ;;
                esac
            fi
            printf 'Unexpected selected-tool arguments: %s\n' "$*" >&2
            return 97
        }
        validate_apple_distribution_toolchain \
            "$fixture_developer_dir" "$@" || exit $?
        printf '%s\n%s\n%s\n%s\n%s\n%s\n' \
            "$apple_distribution_minimum_xcode_version" \
            "$apple_distribution_minimum_sdk_version" \
            "$validated_apple_xcode_version" \
            "$validated_apple_macosx_sdk_version" \
            "$validated_apple_iphoneos_sdk_version" \
            "$validated_apple_watchos_sdk_version"
        """#
        return try runAppleToolchainHelper(
            command: command,
            arguments: [
                developerDirectory.path,
                xcodeVersion,
                xcodeBuild,
                sdkVersion,
                sdkBuild
            ] + platforms
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

    private func runMacContainerHelper(
        command: String,
        arguments: [String]
    ) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [
            "-c",
            command,
            "mac-container-test",
            repositoryRoot.appendingPathComponent(
                "Scripts/macos-container-validation.sh"
            ).path
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

    private func runReleaseOutputHelper(
        command: String,
        arguments: [String] = [],
        environment: [String: String] = [:]
    ) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [
            "-c",
            command,
            "release-output-test",
            repositoryRoot.appendingPathComponent("Scripts/release-output.sh").path
        ] + arguments
        process.environment = ProcessInfo.processInfo.environment.merging(
            environment,
            uniquingKeysWith: { _, override in override }
        )
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

    private func runProcess(
        executable: String,
        arguments: [String],
        currentDirectory: URL? = nil,
        environment: [String: String] = [:],
        inheritEnvironment: Bool = true
    ) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectory
        process.environment = inheritEnvironment
            ? ProcessInfo.processInfo.environment.merging(
                environment,
                uniquingKeysWith: { _, override in override }
            )
            : environment
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

    private func initializeGitRepository(
        at directory: URL,
        fileName: String
    ) throws -> String {
        _ = try git(["init", "-q"], at: directory)
        _ = try git(["config", "user.name", "Release Test"], at: directory)
        _ = try git(
            ["config", "user.email", "release-test@example.invalid"],
            at: directory
        )
        try Data("fixture".utf8).write(
            to: directory.appendingPathComponent(fileName)
        )
        _ = try git(["add", fileName], at: directory)
        _ = try git(["commit", "-qm", "fixture"], at: directory)
        return try git(["rev-parse", "HEAD"], at: directory)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func git(_ arguments: [String], at directory: URL) throws -> String {
        let result = try runProcess(
            executable: "/usr/bin/git",
            arguments: arguments,
            currentDirectory: directory,
            environment: [
                "GIT_ATTR_NOSYSTEM": "1",
                "GIT_CONFIG_GLOBAL": "/dev/null",
                "GIT_CONFIG_NOSYSTEM": "1",
                "GIT_NO_REPLACE_OBJECTS": "1",
                "LC_ALL": "C",
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"
            ],
            inheritEnvironment: false
        )
        guard result.status == 0 else {
            throw NSError(
                domain: "DistributionScriptTests.Git",
                code: Int(result.status),
                userInfo: [NSLocalizedDescriptionKey: result.output]
            )
        }
        return result.output
    }

    private func fileIdentity(at url: URL) throws -> String {
        let result = try runProcess(
            executable: "/usr/bin/stat",
            arguments: ["-f", "%d:%i", url.path]
        )
        XCTAssertEqual(result.status, 0, result.output)
        return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func environmentDictionary(from output: String) -> [String: String] {
        var environment: [String: String] = [:]
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let separator = line.firstIndex(of: "=") else { continue }
            environment[String(line[..<separator])] = String(line[line.index(after: separator)...])
        }
        return environment
    }

    private func occurrenceCount(of needle: String, in text: String) -> Int {
        text.components(separatedBy: needle).count - 1
    }

    private func assertOrderedSnippets(
        _ snippets: [String],
        in text: String,
        context: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        var searchStart = text.startIndex
        for snippet in snippets {
            guard let range = text.range(
                of: snippet,
                range: searchStart..<text.endIndex
            ) else {
                XCTFail(
                    "Missing or out-of-order snippet in \(context):\n\(snippet)",
                    file: file,
                    line: line
                )
                return
            }
            searchStart = range.upperBound
        }
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
