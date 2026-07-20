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

    func testAppleCredentialArtifactGuardIsLiveAndCaseInsensitive() throws {
        let gitignore = try repositoryText(".gitignore")
        let workflow = try repositoryText(".github/workflows/apple-ci.yml")
        let ignoredPatterns = [
            "*.[pP]8",
            "*.[pP]12",
            "*.[pP][fF][xX]",
            "*.[pP][eE][mM]",
            "*.[kK][eE][yY]",
            "*.[kK][eE][yY][cC][hH][aA][iI][nN]",
            "*.[kK][eE][yY][cC][hH][aA][iI][nN]-[dD][bB]",
            "*.[mM][oO][bB][iI][lL][eE][pP][rR][oO][vV][iI][sS][iI][oO][nN]",
            "*.[pP][rR][oO][vV][iI][sS][iI][oO][nN][pP][rR][oO][fF][iI][lL][eE]",
            "*.[xX][cC][aA][rR][cC][hH][iI][vV][eE]/"
        ]

        for pattern in ignoredPatterns {
            XCTAssertTrue(
                gitignore.components(separatedBy: .newlines).contains(pattern),
                pattern
            )
        }

        let lines = workflow.components(separatedBy: .newlines)
        let sourceGates = try XCTUnwrap(
            lines.firstIndex(of: "  source-gates:")
        )
        let testMatrix = try XCTUnwrap(lines.firstIndex(of: "  tests:"))
        let sourceGateLines = Array(lines[sourceGates..<testMatrix])
        let step = try XCTUnwrap(
            sourceGateLines.firstIndex(
                of: "      - name: Reject committed Apple credential artifacts"
            )
        )
        XCTAssertEqual(
            sourceGateLines[step + 1],
            "        run: Scripts/reject-apple-credential-artifacts.sh"
        )

        let guardScript = try releaseScript(
            named: "reject-apple-credential-artifacts.sh"
        )
        XCTAssertTrue(guardScript.contains("git -C \"$repository\" ls-files -z"))
        XCTAssertEqual(
            guardScript.components(separatedBy: ":(icase,glob)").count - 1,
            10
        )
        XCTAssertTrue(guardScript.contains("printf 'Tracked Apple credential artifact rejected: %q"))
    }

    func testAppleCredentialGuardRejectsForcedTrackedPathologicalNames() throws {
        let repository = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: repository) }
        _ = try runGit(["init", "-q", "-b", "main"], in: repository)
        _ = try runGit(
            ["config", "user.name", "Apple Credential Guard Fixture"],
            in: repository
        )
        _ = try runGit(
            ["config", "user.email", "fixture@example.invalid"],
            in: repository
        )
        try Data(try repositoryText(".gitignore").utf8).write(
            to: repository.appendingPathComponent(".gitignore")
        )
        try Data("safe\n".utf8).write(
            to: repository.appendingPathComponent("README.md")
        )
        _ = try runGit(["add", ".gitignore", "README.md"], in: repository)
        _ = try runGit(["commit", "-q", "-m", "base"], in: repository)

        var result = try runAppleCredentialGuard(repository: repository)
        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertEqual(result.output, "")

        let trackedArtifacts = [
            "Secrets/AuthKey.P8",
            "Secrets/Distribution.P12",
            "Profiles/Review.mobileProvision",
            "Archives/App.XcArChIvE/Info.plist",
            "Secrets/private.Pem",
            "Secrets/line\nbreak.PEM"
        ]
        for path in trackedArtifacts {
            let file = repository.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data("fixture\n".utf8).write(to: file)
        }

        let ordinaryPaths = Array(trackedArtifacts.dropLast())
        let ignored = try runGit(
            ["check-ignore", "--no-index", "--"] + ordinaryPaths,
            in: repository
        )
        for path in ordinaryPaths {
            XCTAssertTrue(ignored.contains(path), path)
        }
        _ = try runGit(["add", "-f", "--"] + trackedArtifacts, in: repository)

        result = try runAppleCredentialGuard(repository: repository)
        XCTAssertEqual(result.status, 78, result.output)
        XCTAssertEqual(
            result.output.components(
                separatedBy: "Tracked Apple credential artifact rejected:"
            ).count - 1,
            trackedArtifacts.count,
            result.output
        )
        XCTAssertTrue(result.output.contains(#"line\nbreak.PEM"#), result.output)
    }

    func testDependencySecurityConfigurationStaysEnforced() throws {
        let configResult = try runDependencySecurityConfigValidator(
            workflow: repositoryRoot.appendingPathComponent(
                ".github/workflows/dependency-review.yml"
            )
        )
        XCTAssertEqual(configResult.status, 0, configResult.output)

        let registryResult = try runDependencyExceptionValidator(
            registry: repositoryRoot.appendingPathComponent(
                ".github/dependency-review-exceptions.json"
            )
        )
        XCTAssertEqual(registryResult.status, 0, registryResult.output)
        XCTAssertEqual(registryResult.output, "\n")
    }

    func testDependencyWorkflowRejectsCommentedSecurityDecoy() throws {
        let workflow = try repositoryFile(".github/workflows/dependency-review.yml")
            .replacingOccurrences(
                of: "warn-only: false",
                with: "warn-only: true # warn-only: false"
            )
        let fixture = try temporaryFile(
            named: "dependency-review.yml",
            contents: workflow
        )
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let result = try runDependencySecurityConfigValidator(
            workflow: fixture.file
        )

        XCTAssertEqual(result.status, 78, result.output)
        XCTAssertTrue(
            result.output.contains("dependency-review inputs changed"),
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

    func testDependencyWorkflowRejectsSeverityWeakening() throws {
        let workflow = try repositoryFile(".github/workflows/dependency-review.yml")
            .replacingOccurrences(
                of: "fail-on-severity: moderate",
                with: "fail-on-severity: critical # fail-on-severity: moderate"
            )
        let fixture = try temporaryFile(
            named: "dependency-review.yml",
            contents: workflow
        )
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let result = try runDependencySecurityConfigValidator(
            workflow: fixture.file
        )

        XCTAssertEqual(result.status, 78, result.output)
        XCTAssertTrue(
            result.output.contains("dependency-review inputs changed"),
            result.output
        )
    }

    func testDependencyWorkflowRejectsSecretBearingStepNames() throws {
        let workflow = try repositoryFile(".github/workflows/dependency-review.yml")
        let forbiddenNames = [
            #"${{ secrets["TOKEN"] }}"#,
            #"${{ github.token }}"#,
            #"${{ github['token'] }}"#
        ]

        for (index, forbiddenName) in forbiddenNames.enumerated() {
            let contents = workflow.replacingOccurrences(
                of: "name: Check out dependency policy",
                with: "name: \(forbiddenName)"
            )
            let fixture = try temporaryFile(
                named: "dependency-review-secret-name-\(index).yml",
                contents: contents
            )
            defer { try? FileManager.default.removeItem(at: fixture.directory) }

            let result = try runDependencySecurityConfigValidator(
                workflow: fixture.file
            )

            XCTAssertEqual(result.status, 78, result.output)
            XCTAssertTrue(
                result.output.contains("checkout step name changed")
                    || result.output.contains("references secrets or github.token"),
                result.output
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

        if result.status == 69,
           result.output.contains("ancestor directories must be root-owned and non-writable") {
            throw XCTSkip(
                "Selected Xcode is installed below an account-writable directory"
            )
        }
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

    func testAppleToolchainRejectsWritableAncestorBeforeSignatureCheck() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let developerDirectory = try createAppleToolchainFixture(
            at: directory,
            dtxcode: "2610"
        ).resolvingSymlinksInPath()
        let command = #"source "$1"; canonical="$(cd "$2" && pwd -P)" || exit 1; apple_validate_xcode_bundle_trust "$canonical"; exit $?"#

        let result = try runAppleToolchainHelper(
            command: command,
            arguments: [developerDirectory.path]
        )

        XCTAssertEqual(result.status, 69, result.output)
        XCTAssertTrue(
            result.output.contains(
                "ancestor directories must be root-owned and non-writable"
            ),
            result.output
        )
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

    func testDependencyWorkflowRejectsUnregisteredException() throws {
        let workflow = try repositoryFile(".github/workflows/dependency-review.yml")
            .replacingOccurrences(
                of: "${{ steps.dependency-exceptions.outputs.allow-ghsas }}",
                with: "GHSA-2345-6789-cfgh"
            )
        let fixture = try temporaryFile(
            named: "dependency-review.yml",
            contents: workflow
        )
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let result = try runDependencySecurityConfigValidator(
            workflow: fixture.file
        )

        XCTAssertEqual(result.status, 78, result.output)
        XCTAssertTrue(
            result.output.contains("dependency-review inputs changed"),
            result.output
        )
    }

    func testDependencyWorkflowRejectsMultipleYAMLDocuments() throws {
        let workflow = try repositoryFile(".github/workflows/dependency-review.yml")
            + "\n---\nname: Decoy\n"
        let fixture = try temporaryFile(
            named: "dependency-review.yml",
            contents: workflow
        )
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let result = try runDependencySecurityConfigValidator(
            workflow: fixture.file
        )

        XCTAssertEqual(result.status, 78, result.output)
        XCTAssertTrue(
            result.output.contains("exactly one YAML document"),
            result.output
        )
    }

    func testDependabotRejectsMultipleYAMLDocuments() throws {
        let dependabot = try repositoryFile(".github/dependabot.yml")
            + "\n---\nversion: 2\nupdates: []\n"
        let fixture = try temporaryFile(
            named: "dependabot.yml",
            contents: dependabot
        )
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let result = try runDependencySecurityConfigValidator(
            workflow: repositoryRoot.appendingPathComponent(
                ".github/workflows/dependency-review.yml"
            ),
            dependabot: fixture.file
        )

        XCTAssertEqual(result.status, 78, result.output)
        XCTAssertTrue(
            result.output.contains("exactly one YAML document"),
            result.output
        )
    }

    func testDependencyWorkflowRejectsDuplicateYAMLMappingKeys() throws {
        let workflow = try repositoryFile(".github/workflows/dependency-review.yml")
        let duplicateWorkflows = [
            "name: Decoy\n" + workflow,
            workflow.replacingOccurrences(
                of: "          warn-only: false",
                with: "          warn-only: true\n          warn-only: false"
            )
        ]

        for (index, contents) in duplicateWorkflows.enumerated() {
            let fixture = try temporaryFile(
                named: "dependency-review-\(index).yml",
                contents: contents
            )
            defer { try? FileManager.default.removeItem(at: fixture.directory) }

            let result = try runDependencySecurityConfigValidator(
                workflow: fixture.file
            )

            XCTAssertEqual(result.status, 78, result.output)
            XCTAssertTrue(
                result.output.contains("duplicate YAML mapping key"),
                result.output
            )
        }
    }

    func testDependabotRejectsDuplicateYAMLMappingKeys() throws {
        let dependabot = try repositoryFile(".github/dependabot.yml")
        let duplicateConfigurations = [
            "version: 1\n" + dependabot,
            dependabot.replacingOccurrences(
                of: "      interval: weekly",
                with: "      interval: daily\n      interval: weekly"
            )
        ]

        for (index, contents) in duplicateConfigurations.enumerated() {
            let fixture = try temporaryFile(
                named: "dependabot-\(index).yml",
                contents: contents
            )
            defer { try? FileManager.default.removeItem(at: fixture.directory) }

            let result = try runDependencySecurityConfigValidator(
                workflow: repositoryRoot.appendingPathComponent(
                    ".github/workflows/dependency-review.yml"
                ),
                dependabot: fixture.file
            )

            XCTAssertEqual(result.status, 78, result.output)
            XCTAssertTrue(
                result.output.contains("duplicate YAML mapping key"),
                result.output
            )
        }
    }

    func testDependencyExceptionRegistryRejectsExpiredRecord() throws {
        let fixture = try temporaryFile(
            named: "dependency-review-exceptions.json",
            contents: dependencyExceptionRegistry(expiresOn: "2000-01-01")
        )
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let result = try runDependencyExceptionValidator(registry: fixture.file)

        XCTAssertEqual(result.status, 78, result.output)
        XCTAssertTrue(result.output.contains("expired record"), result.output)
    }

    func testDependencyExceptionRegistryRejectsHiddenExpiredRecord() throws {
        let contents = dependencyExceptionRegistry(expiresOn: "2000-01-01") + "\n" + """
        {
          "schema_version": 1,
          "exceptions": []
        }
        """
        let fixture = try temporaryFile(
            named: "dependency-review-exceptions.json",
            contents: contents
        )
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let result = try runDependencyExceptionValidator(registry: fixture.file)

        XCTAssertEqual(result.status, 78, result.output)
        XCTAssertTrue(result.output.contains("expired record"), result.output)
    }

    func testDependencyExceptionRegistryRejectsDuplicateObjectKeys() throws {
        let registry = dependencyExceptionRegistry(expiresOn: "2099-01-01")
        let duplicateRegistries = [
            registry.replacingOccurrences(
                of: #""schema_version": 1,"#,
                with: #""schema_version": 1, "\u0073chema_version": 1,"#
            ),
            registry.replacingOccurrences(
                of: #""exceptions": ["#,
                with: #""exceptions": [], "exceptions": ["#
            ),
            registry.replacingOccurrences(
                of: #""owner": "@JimBoHa","#,
                with: #""owner": "@attacker", "owner": "@JimBoHa","#
            )
        ]

        for (index, contents) in duplicateRegistries.enumerated() {
            let result = try validateDependencyExceptionRegistry(contents)

            XCTAssertEqual(result.status, 78, "fixture \(index): \(result.output)")
            XCTAssertTrue(
                result.output.contains("duplicate object key"),
                "fixture \(index): \(result.output)"
            )
        }
    }

    func testDependencyExceptionRegistryRejectsNonCanonicalIdentities() throws {
        let registry = dependencyExceptionRegistry(expiresOn: "2099-01-01")
        let invalidValues = [
            (
                "owner line feed",
                registry.replacingOccurrences(
                    of: #""owner": "@JimBoHa""#,
                    with: #""owner": "@JimBoHa\n""#
                )
            ),
            (
                "owner whitespace",
                registry.replacingOccurrences(
                    of: #""owner": "@JimBoHa""#,
                    with: #""owner": "@JimBoHa ""#
                )
            ),
            (
                "tracking line feed",
                registry.replacingOccurrences(
                    of: #"issues/1""#,
                    with: #"issues/1\n""#
                )
            ),
            (
                "tracking control",
                registry.replacingOccurrences(
                    of: #"issues/1""#,
                    with: #"issues/1\u0001""#
                )
            ),
            (
                "package whitespace",
                registry.replacingOccurrences(
                    of: #"Sparkle@2.9.4""#,
                    with: #"Sparkle@2.9.4 ""#
                )
            ),
            (
                "package control",
                registry.replacingOccurrences(
                    of: #"Sparkle@2.9.4""#,
                    with: #"Sparkle@2.9.4\u0001""#
                )
            ),
            (
                "package suffix",
                registry.replacingOccurrences(
                    of: #"Sparkle@2.9.4""#,
                    with: #"Sparkle@2.9.4?download=untrusted""#
                )
            )
        ]

        for (label, contents) in invalidValues {
            let result = try validateDependencyExceptionRegistry(contents)

            XCTAssertEqual(result.status, 78, "\(label): \(result.output)")
        }
    }

    func testDependencyExceptionRegistryRejectsInvalidSemVerPrereleases() throws {
        let registry = dependencyExceptionRegistry(expiresOn: "2099-01-01")
        let invalidVersions = ["2.9.4-01", "2.9.4-alpha.01"]

        for version in invalidVersions {
            let contents = registry.replacingOccurrences(
                of: "Sparkle@2.9.4",
                with: "Sparkle@\(version)"
            )
            let result = try validateDependencyExceptionRegistry(contents)

            XCTAssertEqual(result.status, 78, "\(version): \(result.output)")
        }
    }

    func testDependencyExceptionRegistryRejectsMissingSwiftSourceHost() throws {
        let registry = dependencyExceptionRegistry(expiresOn: "2099-01-01")
            .replacingOccurrences(
                of: "pkg:swift/github.com/sparkle-project/Sparkle@2.9.4",
                with: "pkg:swift/sparkle-project/Sparkle@2.9.4"
            )

        let result = try validateDependencyExceptionRegistry(registry)

        XCTAssertEqual(result.status, 78, result.output)
    }

    func testDependencyExceptionRegistryAcceptsSemVerPrereleaseBoundaries() throws {
        let registry = dependencyExceptionRegistry(expiresOn: "2099-01-01")
        let validVersions = [
            "2.9.4-0",
            "2.9.4-1",
            "2.9.4-01alpha",
            "2.9.4-alpha.0",
            "2.9.4+01"
        ]

        for version in validVersions {
            let contents = registry.replacingOccurrences(
                of: "Sparkle@2.9.4",
                with: "Sparkle@\(version)"
            )
            let result = try validateDependencyExceptionRegistry(contents)

            XCTAssertEqual(result.status, 0, "\(version): \(result.output)")
            XCTAssertEqual(result.output, "GHSA-2345-6789-cfgh\n")
        }
    }

    func testDependencyExceptionRegistryEmitsOnlyRegisteredAdvisories() throws {
        let fixture = try temporaryFile(
            named: "dependency-review-exceptions.json",
            contents: dependencyExceptionRegistry(expiresOn: "2099-01-01")
        )
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let result = try runDependencyExceptionValidator(registry: fixture.file)

        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertEqual(result.output, "GHSA-2345-6789-cfgh\n")
    }

    func testDependencyExceptionPullRequestBootstrapRequiresEmptyRegistry()
        throws
    {
        let passing = try dependencyPolicyRepository(registry: nil)
        defer { try? FileManager.default.removeItem(at: passing.directory) }
        try writeDependencyRegistry(
            emptyDependencyExceptionRegistry,
            in: passing.directory
        )
        try Data("policy\n".utf8).write(
            to: passing.directory.appendingPathComponent("Policy.txt")
        )
        let passingHead = try commitAll(
            in: passing.directory,
            message: "bootstrap"
        )

        let passingResult = try runDependencyExceptionPullRequestValidator(
            repository: passing.directory,
            baseSHA: passing.baseSHA,
            headSHA: passingHead
        )

        XCTAssertEqual(passingResult.status, 0, passingResult.output)
        XCTAssertEqual(passingResult.githubOutput, "allow-ghsas=\n")

        let rejected = try dependencyPolicyRepository(registry: nil)
        defer { try? FileManager.default.removeItem(at: rejected.directory) }
        try writeDependencyRegistry(
            dependencyExceptionRegistry(expiresOn: "2099-01-01"),
            in: rejected.directory
        )
        let rejectedHead = try commitAll(
            in: rejected.directory,
            message: "unsafe bootstrap"
        )

        let rejectedResult = try runDependencyExceptionPullRequestValidator(
            repository: rejected.directory,
            baseSHA: rejected.baseSHA,
            headSHA: rejectedHead
        )

        XCTAssertEqual(rejectedResult.status, 78, rejectedResult.output)
        XCTAssertEqual(rejectedResult.githubOutput, "")
    }

    func testDependencyExceptionPullRequestUsesUnchangedRegistry() throws {
        let fixture = try dependencyPolicyRepository(
            registry: dependencyExceptionRegistry(expiresOn: "2099-01-01")
        )
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        try Data("source change\n".utf8).write(
            to: fixture.directory.appendingPathComponent("Source.txt")
        )
        let head = try commitAll(in: fixture.directory, message: "source change")

        let result = try runDependencyExceptionPullRequestValidator(
            repository: fixture.directory,
            baseSHA: fixture.baseSHA,
            headSHA: head
        )

        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertEqual(
            result.githubOutput,
            "allow-ghsas=GHSA-2345-6789-cfgh\n"
        )
    }

    func testDependencyExceptionPullRequestDefersRegistryOnlyChange() throws {
        let fixture = try dependencyPolicyRepository(
            registry: emptyDependencyExceptionRegistry
        )
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        try writeDependencyRegistry(
            dependencyExceptionRegistry(expiresOn: "2099-01-01"),
            in: fixture.directory
        )
        let head = try commitAll(in: fixture.directory, message: "add exception")

        let result = try runDependencyExceptionPullRequestValidator(
            repository: fixture.directory,
            baseSHA: fixture.baseSHA,
            headSHA: head
        )

        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertEqual(result.githubOutput, "allow-ghsas=\n")
    }

    func testDependencyExceptionPullRequestRejectsMixedRegistryChange() throws {
        let fixture = try dependencyPolicyRepository(
            registry: emptyDependencyExceptionRegistry
        )
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        try writeDependencyRegistry(
            dependencyExceptionRegistry(expiresOn: "2099-01-01"),
            in: fixture.directory
        )
        try Data("mixed\n".utf8).write(
            to: fixture.directory.appendingPathComponent("Source.txt")
        )
        let head = try commitAll(in: fixture.directory, message: "mixed change")

        let result = try runDependencyExceptionPullRequestValidator(
            repository: fixture.directory,
            baseSHA: fixture.baseSHA,
            headSHA: head
        )

        XCTAssertEqual(result.status, 78, result.output)
        XCTAssertTrue(result.output.contains("registry-only"), result.output)
        XCTAssertEqual(result.githubOutput, "")
    }

    func testDependencyExceptionPullRequestUsesRegistryAddedToDivergedBase()
        throws
    {
        let fixture = try dependencyPolicyRepository(registry: nil)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        _ = try runGit(["switch", "-q", "-c", "feature"], in: fixture.directory)
        try Data("source change\n".utf8).write(
            to: fixture.directory.appendingPathComponent("Source.txt")
        )
        let featureHead = try commitAll(
            in: fixture.directory,
            message: "source change"
        )

        _ = try runGit(["switch", "-q", "main"], in: fixture.directory)
        try writeDependencyRegistry(
            emptyDependencyExceptionRegistry,
            in: fixture.directory
        )
        let updatedBase = try commitAll(
            in: fixture.directory,
            message: "bootstrap registry"
        )
        _ = try runGit(
            ["merge", "-q", "--no-ff", "feature", "-m", "merge fixture"],
            in: fixture.directory
        )

        let result = try runDependencyExceptionPullRequestValidator(
            repository: fixture.directory,
            baseSHA: updatedBase,
            headSHA: featureHead
        )

        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertEqual(result.githubOutput, "allow-ghsas=\n")
    }

    func testDependencyExceptionPullRequestAllowsDivergedRegistryOnlyChange()
        throws
    {
        let fixture = try dependencyPolicyRepository(
            registry: emptyDependencyExceptionRegistry
        )
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        _ = try runGit(["switch", "-q", "-c", "feature"], in: fixture.directory)
        try writeDependencyRegistry(
            dependencyExceptionRegistry(expiresOn: "2099-01-01"),
            in: fixture.directory
        )
        let featureHead = try commitAll(
            in: fixture.directory,
            message: "add exception"
        )

        _ = try runGit(["switch", "-q", "main"], in: fixture.directory)
        try Data("base-only\n".utf8).write(
            to: fixture.directory.appendingPathComponent("BaseOnly.txt")
        )
        let updatedBase = try commitAll(
            in: fixture.directory,
            message: "advance base"
        )
        _ = try runGit(
            ["merge", "-q", "--no-ff", "feature", "-m", "merge fixture"],
            in: fixture.directory
        )

        let result = try runDependencyExceptionPullRequestValidator(
            repository: fixture.directory,
            baseSHA: updatedBase,
            headSHA: featureHead
        )

        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertEqual(result.githubOutput, "allow-ghsas=\n")
    }

    func testDependencyExceptionPullRequestRejectsUnrelatedHistories() throws {
        let fixture = try dependencyPolicyRepository(
            registry: emptyDependencyExceptionRegistry
        )
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let tree = try runGit(
            ["rev-parse", "HEAD^{tree}"],
            in: fixture.directory
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        let unrelatedHead = try runGit(
            ["commit-tree", tree, "-m", "unrelated root"],
            in: fixture.directory
        ).trimmingCharacters(in: .whitespacesAndNewlines)

        let result = try runDependencyExceptionPullRequestValidator(
            repository: fixture.directory,
            baseSHA: fixture.baseSHA,
            headSHA: unrelatedHead
        )

        XCTAssertEqual(result.status, 78, result.output)
        XCTAssertTrue(result.output.contains("merge base"), result.output)
        XCTAssertEqual(result.githubOutput, "")
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

    func testReleaseEntrypointsResetForgedFixedEnvironmentValues() throws {
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
            "package-macos.sh",
            "capture-app-store-screenshots.sh"
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
            XCTAssertTrue(scriptText.contains("/usr/bin/env -0"), name)
            XCTAssertTrue(scriptText.contains("release_environment_needs_reset"), name)
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
                64,
                name + ": " + forgedSentinel.output
            )
            XCTAssertTrue(
                forgedSentinel.output.contains("Usage:"),
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
                64,
                name + ": " + forgedHome.output
            )
            XCTAssertTrue(
                forgedHome.output.contains("Usage:"),
                name + ": " + forgedHome.output
            )
        }
    }

    func testReleaseEnvironmentDropsHostileToolOverrides() throws {
        let command = #"source "$1"; sanitize_release_git_environment; printf '%s\n' "${CCC_OVERRIDE_OPTIONS-unset}" "${CCC_ADD_ARGS-unset}" "${GREP_OPTIONS-unset}" "${TAR_OPTIONS-unset}" "${PERL5OPT-unset}" "${PERL5LIB-unset}" "${PERLLIB-unset}" "${xcrun_verbose-unset}" "${xcrun_log-unset}" "${xcrun_cache_path-unset}" "${DYLD_FAKE_OVERRIDE-unset}" "$COPYFILE_DISABLE" "$COPY_EXTENDED_ATTRIBUTES_DISABLE" "$LC_ALL""#
        let result = try runSigningConfigHelper(
            command: command,
            environment: [
                "CCC_OVERRIDE_OPTIONS": "hostile",
                "CCC_ADD_ARGS": "hostile",
                "GREP_OPTIONS": "--exclude=*",
                "TAR_OPTIONS": "--exclude=*",
                "PERL5OPT": "-Mhostile",
                "PERL5LIB": "/private/tmp/hostile",
                "PERLLIB": "/private/tmp/hostile",
                "xcrun_verbose": "1",
                "xcrun_log": "/private/tmp/xcrun.log",
                "xcrun_cache_path": "/private/tmp/xcrun-cache",
                "DYLD_FAKE_OVERRIDE": "hostile"
            ]
        )

        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertEqual(
            result.output.split(separator: "\n").map(String.init),
            Array(repeating: "unset", count: 11) + ["1", "1", "C"]
        )
    }

    func testReleaseSourcePinPropagatesGitStatusFailure() throws {
        let repository = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: repository) }
        _ = try initializeGitRepository(at: repository, fileName: "trusted.txt")
        try Data("corrupt-index".utf8).write(
            to: repository.appendingPathComponent(".git/index")
        )
        let command = #"source "$1"; sanitize_release_git_environment; pin_clean_release_source "$2""#

        let result = try runSigningConfigHelper(
            command: command,
            arguments: [repository.path]
        )

        XCTAssertEqual(result.status, 65, result.output)
        XCTAssertTrue(result.output.contains("release source"), result.output)
    }

    func testReleaseSourcePinRejectsHiddenIndexFlagsAndContent() throws {
        for flag in ["--assume-unchanged", "--skip-worktree"] {
            let repository = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: repository) }
            _ = try initializeGitRepository(
                at: repository,
                fileName: "trusted.txt"
            )
            _ = try git(
                ["update-index", flag, "trusted.txt"],
                at: repository
            )
            try Data("hidden mutation".utf8).write(
                to: repository.appendingPathComponent("trusted.txt")
            )
            let command = #"source "$1"; sanitize_release_git_environment; pin_clean_release_source "$2""#

            let result = try runSigningConfigHelper(
                command: command,
                arguments: [repository.path]
            )

            XCTAssertEqual(result.status, 65, "\(flag): \(result.output)")
            XCTAssertTrue(
                result.output.contains("hidden worktree flags"),
                "\(flag): \(result.output)"
            )
        }
    }

    func testReleaseSourceRecheckPropagatesGitStatusFailure() throws {
        let repository = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: repository) }
        _ = try initializeGitRepository(at: repository, fileName: "trusted.txt")
        let command = #"source "$1"; sanitize_release_git_environment; pin_clean_release_source "$2" || exit $?; commit="$validated_release_source_commit"; tree="$validated_release_source_tree"; printf corrupt-index >"$2/.git/index"; verify_pinned_release_source_unchanged "$2" "$commit" "$tree""#

        let result = try runSigningConfigHelper(
            command: command,
            arguments: [repository.path]
        )

        XCTAssertEqual(result.status, 65, result.output)
        XCTAssertTrue(result.output.contains("recheck"), result.output)
    }

    func testReleaseSourcePinRejectsExecutableRepositoryConfiguration() throws {
        let repository = try temporaryDirectory()
        let marker = repository.appendingPathComponent("executed-marker")
        let hook = repository.appendingPathComponent("hostile-hook")
        defer { try? FileManager.default.removeItem(at: repository) }
        _ = try initializeGitRepository(at: repository, fileName: "trusted.txt")
        try Data(
            "#!/bin/sh\n/usr/bin/touch \"$AGENTLIMITS_HOOK_MARKER\"\n".utf8
        ).write(to: hook)
        try setPermissions(0o700, for: hook)
        let command = #"source "$1"; sanitize_release_git_environment; pin_clean_release_source "$2""#

        for key in ["core.fsmonitor", "filter.hostile.clean", "filter.hostile.process"] {
            _ = try git(["config", key, hook.path], at: repository)
            let result = try runSigningConfigHelper(
                command: command,
                arguments: [repository.path],
                environment: ["AGENTLIMITS_HOOK_MARKER": marker.path]
            )

            XCTAssertEqual(result.status, 65, "\(key): \(result.output)")
            XCTAssertTrue(
                result.output.contains("Repository Git configuration"),
                "\(key): \(result.output)"
            )
            XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
            _ = try git(["config", "--unset-all", key], at: repository)
        }

        _ = try git(
            ["config", "extensions.worktreeConfig", "true"],
            at: repository
        )
        _ = try git(
            ["config", "--worktree", "core.fsmonitor", hook.path],
            at: repository
        )
        let worktreeResult = try runSigningConfigHelper(
            command: command,
            arguments: [repository.path],
            environment: ["AGENTLIMITS_HOOK_MARKER": marker.path]
        )
        XCTAssertEqual(worktreeResult.status, 65, worktreeResult.output)
        XCTAssertTrue(
            worktreeResult.output.contains("Repository Git configuration"),
            worktreeResult.output
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testReleaseSourceSnapshotExactlyMatchesPinnedTree() throws {
        let repository = try temporaryDirectory()
        let work = try releaseTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: repository)
            try? FileManager.default.removeItem(at: work)
        }
        _ = try initializeGitRepository(at: repository, fileName: "trusted.txt")
        let command = #"umask 077; source "$1"; source "$2"; sanitize_release_git_environment; pin_clean_release_source "$3" || exit $?; tree="$validated_release_source_tree"; create_immutable_release_source_snapshot "$3" "$validated_release_source_commit" "$tree" "$4" || exit $?; snapshot="$validated_release_source_snapshot"; identity="$validated_release_source_snapshot_identity"; verify_immutable_release_source_snapshot "$snapshot" "$identity" || exit $?; unlock_immutable_release_source_snapshot_for_cleanup "$snapshot" "$identity" "$4" "$3" "$tree" || exit $?; rm -rf "$snapshot""#

        let result = try runReleaseOutputHelper(
            command: command,
            arguments: [
                repositoryRoot.appendingPathComponent("Scripts/signing-config.sh").path,
                repository.path,
                work.path
            ]
        )

        XCTAssertEqual(result.status, 0, result.output)
    }

    func testReleaseSourceSnapshotRejectsInfoAttributesExportIgnore() throws {
        let repository = try temporaryDirectory()
        let work = try releaseTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: repository)
            try? FileManager.default.removeItem(at: work)
        }
        _ = try initializeGitRepository(at: repository, fileName: "trusted.txt")
        try Data("trusted.txt export-ignore\n".utf8).write(
            to: repository.appendingPathComponent(".git/info/attributes")
        )
        let command = #"source "$1"; source "$2"; sanitize_release_git_environment; pin_clean_release_source "$3" || exit $?; create_immutable_release_source_snapshot "$3" "$validated_release_source_commit" "$validated_release_source_tree" "$4""#

        let result = try runReleaseOutputHelper(
            command: command,
            arguments: [
                repositoryRoot.appendingPathComponent("Scripts/signing-config.sh").path,
                repository.path,
                work.path
            ]
        )

        XCTAssertEqual(result.status, 73, result.output)
        XCTAssertTrue(result.output.contains("exact release source"), result.output)
    }

    func testReleaseSourceSnapshotRejectsConfiguredExportSubstitution() throws {
        let repository = try temporaryDirectory()
        let work = try releaseTemporaryDirectory()
        let attributes = work.appendingPathComponent("hostile.attributes")
        defer {
            try? FileManager.default.removeItem(at: repository)
            try? FileManager.default.removeItem(at: work)
        }
        _ = try initializeGitRepository(at: repository, fileName: "trusted.txt")
        try Data("$Format:%H$\n".utf8).write(
            to: repository.appendingPathComponent("trusted.txt")
        )
        _ = try git(["add", "trusted.txt"], at: repository)
        _ = try git(["commit", "-qm", "add archive placeholder"], at: repository)
        try Data("trusted.txt export-subst\n".utf8).write(to: attributes)
        _ = try git(
            ["config", "core.attributesFile", attributes.path],
            at: repository
        )
        let command = #"source "$1"; source "$2"; sanitize_release_git_environment; pin_clean_release_source "$3" || exit $?; create_immutable_release_source_snapshot "$3" "$validated_release_source_commit" "$validated_release_source_tree" "$4""#

        let result = try runReleaseOutputHelper(
            command: command,
            arguments: [
                repositoryRoot.appendingPathComponent("Scripts/signing-config.sh").path,
                repository.path,
                work.path
            ]
        )

        XCTAssertEqual(result.status, 65, result.output)
        XCTAssertTrue(
            result.output.contains("Repository Git configuration"),
            result.output
        )
    }

    func testReleaseSourceCleanupPreservesTamperedSnapshot() throws {
        let repository = try temporaryDirectory()
        let work = try releaseTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: repository)
            try? FileManager.default.removeItem(at: work)
        }
        _ = try initializeGitRepository(at: repository, fileName: "trusted.txt")
        let command = #"source "$1"; source "$2"; sanitize_release_git_environment; pin_clean_release_source "$3" || exit $?; tree="$validated_release_source_tree"; create_immutable_release_source_snapshot "$3" "$validated_release_source_commit" "$tree" "$4" || exit $?; snapshot="$validated_release_source_snapshot"; identity="$validated_release_source_snapshot_identity"; file="$snapshot/trusted.txt"; chflags nouchg "$file"; chmod u+w "$file"; printf tampered >"$file"; refused=0; unlock_immutable_release_source_snapshot_for_cleanup "$snapshot" "$identity" "$4" "$3" "$tree" || refused=$?; preserved=false; [[ "$refused" == 73 && -d "$snapshot" ]] && preserved=true; chflags -R nouchg "$snapshot"; chmod -R u+w "$snapshot"; rm -rf "$snapshot"; [[ "$preserved" == true ]]"#

        let result = try runReleaseOutputHelper(
            command: command,
            arguments: [
                repositoryRoot.appendingPathComponent("Scripts/signing-config.sh").path,
                repository.path,
                work.path
            ]
        )

        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertTrue(result.output.contains("not immutable"), result.output)
    }

    func testScreenshotCaptureUsesPinnedImmutableAtomicPipeline() throws {
        let script = try releaseScript(
            named: "capture-app-store-screenshots.sh"
        )
        let committedBootstrap = try offset(
            of: "HEAD:Scripts/signing-config.sh",
            in: script
        )
        let trustedSource = try offset(
            of: "source \"$trusted_signing_config\"",
            in: script
        )
        let sanitizeGit = try offset(
            of: "sanitize_release_git_environment",
            in: script
        )
        let pin = try offset(of: "pin_clean_release_source", in: script)
        let releaseHelper = try offset(
            of: "source \"$script_dir/release-output.sh\"",
            in: script
        )
        let toolchainHelper = try offset(
            of: "source \"$script_dir/apple-toolchain.sh\"",
            in: script
        )
        let toolchainValidation = try offset(
            of: "validate_apple_distribution_toolchain",
            in: script
        )
        let sanitizeXcode = try offset(
            of: "sanitize_release_xcode_environment",
            in: script
        )
        let outputLock = try offset(
            of: "acquire_release_publication_lock",
            in: script
        )
        let snapshot = try offset(
            of: "create_immutable_release_source_snapshot",
            in: script
        )
        let simulatorProbe = try offset(
            of: #"runtimes_json="$(selected_xcrun"#,
            in: script
        )
        let simulatorLocks = try offset(
            of: "acquire_all_simulator_locks",
            in: script,
            after: simulatorProbe
        )
        let simulatorStateSnapshot = try offset(
            of: #"devices_json="$(selected_xcrun"#,
            in: script,
            after: simulatorLocks
        )
        let manifest = try offset(of: "schemaVersion: 2", in: script)
        let publish = try offset(
            of: "publish_staged_release_directory",
            in: script
        )

        assertOrderedSnippets(
            [
                "HEAD:Scripts/signing-config.sh",
                "source \"$trusted_signing_config\"",
                "sanitize_release_git_environment",
                "pin_clean_release_source",
                "source \"$script_dir/release-output.sh\"",
                "source \"$script_dir/apple-toolchain.sh\"",
                "validate_apple_distribution_toolchain",
                "sanitize_release_xcode_environment"
            ],
            in: script,
            context: "capture-app-store-screenshots.sh"
        )
        XCTAssertLessThan(committedBootstrap, trustedSource)
        XCTAssertLessThan(trustedSource, sanitizeGit)
        XCTAssertLessThan(sanitizeGit, pin)
        XCTAssertLessThan(pin, releaseHelper)
        XCTAssertLessThan(releaseHelper, toolchainHelper)
        XCTAssertLessThan(toolchainHelper, toolchainValidation)
        XCTAssertLessThan(toolchainValidation, sanitizeXcode)
        XCTAssertLessThan(sanitizeXcode, outputLock)
        XCTAssertLessThan(outputLock, snapshot)
        XCTAssertLessThan(snapshot, simulatorProbe)
        XCTAssertLessThan(simulatorProbe, simulatorLocks)
        XCTAssertLessThan(simulatorLocks, simulatorStateSnapshot)
        XCTAssertLessThan(simulatorProbe, manifest)
        XCTAssertLessThan(manifest, publish)
        XCTAssertFalse(
            script.contains("source \"$script_dir/signing-config.sh\"")
        )
        XCTAssertTrue(
            script.contains(
                "\"$developer_dir\" iphoneos watchos || exit $?"
            )
        )
        XCTAssertTrue(
            script.contains("/usr/bin/xcrun --no-cache \"$@\"")
        )
        XCTAssertFalse(script.contains("\nxcrun "))
        XCTAssertTrue(script.contains("$build_root/AgentLimits.xcodeproj"))
        XCTAssertFalse(script.contains("$project_root/AgentLimits.xcodeproj"))
        XCTAssertTrue(
            script.contains(
                "verify_capture_provenance || exit $?\npublish_staged_release_directory"
            )
        )
        XCTAssertTrue(script.contains("\"$source_tree\""))
        XCTAssertTrue(script.contains("\"$staging_parent_identity\""))
        XCTAssertTrue(
            script.contains("captureSource: \"private immutable git archive\"")
        )
        XCTAssertTrue(script.contains("testEvidence:"))
        XCTAssertTrue(script.contains("totalTestCount: 2"))
        XCTAssertTrue(script.contains("validatedToolchain:"))
        XCTAssertEqual(
            occurrenceCount(
                of: "verify_apple_product_toolchain_metadata",
                in: script
            ),
            2
        )
        XCTAssertTrue(script.hasPrefix("#!/bin/bash -p\n"))
        XCTAssertEqual(
            occurrenceCount(of: "exec /usr/bin/env -i", in: script),
            1
        )
        XCTAssertTrue(script.contains("/usr/bin/env -0"))
        XCTAssertTrue(script.contains("release_environment_needs_reset"))
        XCTAssertTrue(script.contains("HOME=\"$(cd ~ >/dev/null && pwd -P)\""))
        XCTAssertTrue(script.contains("verify_all_simulator_locks"))
        XCTAssertTrue(script.contains("release_all_simulator_locks"))
        XCTAssertTrue(script.contains("staging-files.inventory"))
        XCTAssertTrue(script.contains("staging-unexpected.inventory"))
        XCTAssertTrue(
            script.contains(
                "credentialStoreImplementation: \"MobileInMemoryCredentialStore\""
            )
        )
        XCTAssertTrue(
            script.contains(
                "usageFetcherImplementation: \"MobileAppStoreScreenshotFetcher\""
            )
        )
        XCTAssertTrue(
            script.contains(
                "cacheImplementation: \"WatchAppStoreScreenshotCache\""
            )
        )
        XCTAssertFalse(script.contains("productionDefaultsAccessed: false"))
        XCTAssertFalse(script.contains("keychainAccessed: false"))
        XCTAssertFalse(script.contains("networkAccessed: false"))
        XCTAssertFalse(script.contains("watchConnectivityAccessed: false"))
        XCTAssertFalse(script.contains("cp -p -n"))
        XCTAssertFalse(script.contains("${TMPDIR:-"))
    }

    func testScreenshotCaptureIPhoneNetworkMatchesStatusAssertion() throws {
        let script = try releaseScript(
            named: "capture-app-store-screenshots.sh"
        )

        XCTAssertTrue(
            script.contains(
                #"""
                        iphone)
                            selected_xcrun simctl status_bar "$udid" override \
                                --time "$fixed_time" \
                                --dataNetwork 5g \
                                --wifiMode active \
                """#
            )
        )
        XCTAssertTrue(
            script.contains(
                """
                        iphone)
                            [[ "$status_supported" == "true" ]]
                            grep -q '^DataNetworkType: 11$' <<<"$status"
                """
            )
        )
        XCTAssertEqual(
            occurrenceCount(of: "--dataNetwork 5g", in: script),
            1
        )
        XCTAssertEqual(
            occurrenceCount(of: "--dataNetwork wifi", in: script),
            1
        )
    }

    func testScreenshotChecksumsIncludeManifestBeforeVerification() throws {
        let script = try releaseScript(
            named: "capture-app-store-screenshots.sh"
        )
        let manifest = try offset(
            of: #"' >"$staging_dir/MANIFEST.json""#,
            in: script
        )
        let checksums = try offset(
            of: "> SHA256SUMS",
            in: script,
            after: manifest
        )
        let verification = try offset(
            of: "shasum -a 256 -c SHA256SUMS >/dev/null",
            in: script,
            after: checksums
        )
        let publish = try offset(
            of: "publish_staged_release_directory",
            in: script,
            after: verification
        )

        XCTAssertLessThan(manifest, checksums)
        XCTAssertLessThan(checksums, verification)
        XCTAssertLessThan(verification, publish)
        XCTAssertEqual(occurrenceCount(of: "> SHA256SUMS", in: script), 1)
        XCTAssertTrue(
            script.contains(
                #"""
                    shasum -a 256 \
                        iphone-6.9-01-copilot-accounts.jpg \
                        ipad-13-01-copilot-accounts.jpg \
                        watch-46mm-01-copilot-accounts.jpg \
                        watch-46mm-02-session-detail.jpg \
                        MANIFEST.json \
                        > SHA256SUMS
                """#
            )
        )
    }

    func testAppStoreScreenshotAttachmentsRequireStableFrames() throws {
        let ios = try repositoryText(
            "AgentLimitsiOSUITests/AgentLimitsiOSUITests.swift"
        )
        let watch = try repositoryText(
            "AgentLimitsWatchUITests/AgentLimitsWatchUITests.swift"
        )

        XCTAssertEqual(
            ios.components(separatedBy: "addStableScreenshot(named:").count - 1,
            1
        )
        XCTAssertEqual(
            watch.components(separatedBy: "addStableScreenshot(named:").count - 1,
            2
        )
        for source in [ios, watch] {
            XCTAssertTrue(source.contains("frame == previousFrame"))
            XCTAssertTrue(source.contains("requiredMatchingSamples: Int = 3"))
            XCTAssertTrue(
                source.contains(
                    "guard let screenshot = captureVisuallyStableScreenshot()"
                )
            )
            XCTAssertTrue(source.contains("return screenshot"))
            XCTAssertTrue(
                source.contains("XCTAttachment(screenshot: screenshot)")
            )
            XCTAssertEqual(
                source.components(
                    separatedBy: "XCUIScreen.main.screenshot()"
                ).count - 1,
                1
            )
            XCTAssertFalse(
                source.contains(
                    "XCTAttachment(\n            screenshot: XCUIScreen.main.screenshot()"
                )
            )
            XCTAssertTrue(
                source.contains(
                    "Screenshot did not reach repeated identical frames"
                )
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
            ),
            (
                "Scripts/capture-app-store-screenshots.sh",
                [directory.appendingPathComponent("screenshot-output").path]
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
            ),
            (
                "capture-app-store-screenshots.sh",
                [directory.appendingPathComponent("screenshot-output").path]
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
                executable: link.path,
                arguments: invocation.1,
                environment: ["AGENTLIMITS_SYMLINK_MARKER": marker.path]
            )

            XCTAssertEqual(result.status, 64, "\(invocation.0): \(result.output)")
            XCTAssertTrue(result.output.contains("script symlink"), result.output)
            XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        }
    }

    func testReleaseEntrypointsIgnoreBashEnvAndExportedFunctions() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let bashEnvironment = directory.appendingPathComponent("bash-env")
        let bashEnvironmentMarker = directory.appendingPathComponent("bash-env-marker")
        let functionMarker = directory.appendingPathComponent("function-marker")
        try Data(
            "#!/bin/sh\n/usr/bin/touch \"$AGENTLIMITS_BASH_ENV_MARKER\"\n".utf8
        ).write(to: bashEnvironment)

        for name in [
            "build-unsigned-artifacts.sh",
            "export-ios.sh",
            "package-macos.sh",
            "capture-app-store-screenshots.sh"
        ] {
            let script = repositoryRoot
                .appendingPathComponent("Scripts")
                .appendingPathComponent(name)
            let contents = try String(contentsOf: script, encoding: .utf8)
            XCTAssertTrue(contents.hasPrefix("#!/bin/bash -p\n"), name)
            XCTAssertTrue(contents.contains("exec /usr/bin/env -i"), name)
            XCTAssertTrue(contents.contains("/usr/bin/env -0"), name)
            XCTAssertTrue(contents.contains("release_environment_needs_reset"), name)
            let result = try runProcess(
                executable: script.path,
                arguments: [],
                environment: [
                    "AGENTLIMITS_BASH_ENV_MARKER": bashEnvironmentMarker.path,
                    "AGENTLIMITS_FUNCTION_MARKER": functionMarker.path,
                    "BASH_ENV": bashEnvironment.path,
                    "BASH_FUNC_echo%%":
                        "() { /usr/bin/touch \"$AGENTLIMITS_FUNCTION_MARKER\"; }"
                ]
            )

            XCTAssertEqual(result.status, 64, "\(name): \(result.output)")
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: bashEnvironmentMarker.path),
                name
            )
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: functionMarker.path),
                name
            )

            let spoofedSentinel = try runProcess(
                executable: "/bin/bash",
                arguments: [
                    "-c",
                    #"AGENTLIMITS_RELEASE_ENV_PID=$$; export AGENTLIMITS_RELEASE_ENV_PID; exec "$1""#,
                    "release-env-spoof",
                    script.path
                ],
                environment: [
                    "AGENTLIMITS_FUNCTION_MARKER": functionMarker.path,
                    "BASH_FUNC_echo%%":
                        "() { /usr/bin/touch \"$AGENTLIMITS_FUNCTION_MARKER\"; }",
                    "UNEXPECTED_HOSTILE_RELEASE_VARIABLE": "1"
                ]
            )
            XCTAssertEqual(
                spoofedSentinel.status,
                64,
                "\(name): \(spoofedSentinel.output)"
            )
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: functionMarker.path),
                name
            )
        }
    }

    func testSignedReleaseScriptsUseCleanSnapshotAndRecheckConfig() throws {
        for name in ["package-macos.sh", "export-ios.sh"] {
            let script = try releaseScript(named: name)
            XCTAssertTrue(script.contains("HEAD:Scripts/signing-config.sh"), name)
            XCTAssertTrue(script.contains("source \"$trusted_signing_config\""), name)
            XCTAssertFalse(
                script.contains("source \"$script_dir/signing-config.sh\""),
                name
            )
            XCTAssertTrue(script.contains("sanitize_release_git_environment"), name)
            XCTAssertTrue(script.contains("unset CDPATH"), name)
            XCTAssertTrue(
                script.contains("Refusing to run a signed release through a script symlink"),
                name
            )
            XCTAssertTrue(script.contains("source \"$script_dir/release-output.sh\""), name)
            XCTAssertTrue(script.contains("pin_clean_release_source"), name)
            XCTAssertLessThan(
                try offset(of: "pin_clean_release_source", in: script),
                try offset(
                    of: "source \"$script_dir/release-output.sh\"",
                    in: script
                ),
                name
            )
            XCTAssertTrue(
                script.contains("create_immutable_release_source_snapshot"),
                name
            )
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

    func testReleaseScriptsRequireExactProductsProfilesAndDSYMs() throws {
        for name in [
            "build-unsigned-artifacts.sh",
            "package-macos.sh",
            "export-ios.sh"
        ] {
            let script = try releaseScript(named: name)
            XCTAssertTrue(
                script.contains(
                    "source \"$script_dir/release-artifact-validation.sh\""
                ),
                name
            )
            XCTAssertTrue(script.contains("validate_only_named_directory_entry"), name)
            XCTAssertTrue(script.contains("validate_dsym_matches_binary"), name)
        }

        for name in ["package-macos.sh", "export-ios.sh"] {
            let script = try releaseScript(named: name)
            XCTAssertTrue(
                script.contains("validate_provisioning_profile_validity_window"),
                name
            )
            XCTAssertTrue(
                script.contains("validate_unlinked_regular_file_artifact"),
                name
            )
        }
        XCTAssertTrue(
            try releaseScript(named: "package-macos.sh")
                .contains("resolve_exactly_one_directory_with_suffix")
        )
        XCTAssertTrue(
            try releaseScript(named: "export-ios.sh")
                .contains("resolve_exactly_one_regular_file_with_suffix")
        )
    }

    func testArtifactCardinalityRejectsMissingDuplicateAndUnsafeProducts() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let products = directory.appendingPathComponent("Products")
        try FileManager.default.createDirectory(
            at: products,
            withIntermediateDirectories: false
        )
        let command = #"source "$1"; validate_only_named_directory_entry "$2" AgentLimits.app products"#

        var result = try runArtifactValidationHelper(
            command: command,
            arguments: [products.path]
        )
        XCTAssertNotEqual(result.status, 0, result.output)

        let expected = products.appendingPathComponent("AgentLimits.app")
        try FileManager.default.createDirectory(
            at: expected,
            withIntermediateDirectories: false
        )
        result = try runArtifactValidationHelper(
            command: command,
            arguments: [products.path]
        )
        XCTAssertEqual(result.status, 0, result.output)

        try FileManager.default.createDirectory(
            at: products.appendingPathComponent("Injected.app"),
            withIntermediateDirectories: false
        )
        result = try runArtifactValidationHelper(
            command: command,
            arguments: [products.path]
        )
        XCTAssertNotEqual(result.status, 0, result.output)

        try FileManager.default.removeItem(at: products)
        try FileManager.default.createDirectory(
            at: products,
            withIntermediateDirectories: false
        )
        try FileManager.default.createSymbolicLink(
            at: expected,
            withDestinationURL: directory
        )
        result = try runArtifactValidationHelper(
            command: command,
            arguments: [products.path]
        )
        XCTAssertNotEqual(result.status, 0, result.output)
    }

    func testExportCardinalityRejectsMultipleAndSymlinkArtifacts() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let command = #"source "$1"; resolve_exactly_one_regular_file_with_suffix "$2" .ipa "" export"#
        let first = directory.appendingPathComponent("AgentLimits.ipa")
        try Data("one".utf8).write(to: first)

        var result = try runArtifactValidationHelper(
            command: command,
            arguments: [directory.path]
        )
        XCTAssertEqual(result.status, 0, result.output)

        try Data("two".utf8).write(
            to: directory.appendingPathComponent("Injected.ipa")
        )
        result = try runArtifactValidationHelper(
            command: command,
            arguments: [directory.path]
        )
        XCTAssertNotEqual(result.status, 0, result.output)

        try FileManager.default.removeItem(at: directory)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false
        )
        try FileManager.default.createSymbolicLink(
            at: first,
            withDestinationURL: repositoryRoot.appendingPathComponent("README.md")
        )
        result = try runArtifactValidationHelper(
            command: command,
            arguments: [directory.path]
        )
        XCTAssertNotEqual(result.status, 0, result.output)
    }

    func testDSYMInventoryRejectsMalformedMissingExtraAndMismatchedSlices() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let binary = directory.appendingPathComponent("binary.txt")
        let symbols = directory.appendingPathComponent("symbols.txt")
        let armUUID = "AAAAAAAA-1111-2222-3333-444444444444"
        let watchUUID = "BBBBBBBB-1111-2222-3333-444444444444"
        let validBinary = """
        UUID: \(armUUID) (arm64) /private/tmp/App
        UUID: \(watchUUID) (arm64_32) /private/tmp/App
        """
        let validSymbols = """
        UUID: \(watchUUID.lowercased()) (arm64_32) /private/tmp/App.dSYM
        UUID: \(armUUID.lowercased()) (arm64) /private/tmp/App.dSYM
        """
        try Data(validBinary.utf8).write(to: binary)
        let command = #"source "$1"; binary="$(<"$2")"; symbols="$(<"$3")"; validate_matching_dwarfdump_uuid_inventories "$binary" "$symbols" watch arm64 arm64_32"#

        try Data(validSymbols.utf8).write(to: symbols)
        var result = try runArtifactValidationHelper(
            command: command,
            arguments: [binary.path, symbols.path]
        )
        XCTAssertEqual(result.status, 0, result.output)

        let invalidInventories = [
            "UUID: CCCCCCCC-1111-2222-3333-444444444444 (arm64) /tmp/dSYM\n" +
                "UUID: \(watchUUID) (arm64_32) /tmp/dSYM\n",
            "UUID: \(armUUID) (arm64) /tmp/dSYM\n",
            """
            UUID: \(watchUUID.lowercased()) (arm64_32) /tmp/dSYM
            UUID: \(armUUID.lowercased()) (arm64) /tmp/dSYM
            UUID: CCCCCCCC-1111-2222-3333-444444444444 (x86_64) /tmp/dSYM
            """,
            "warning: UUID unavailable\n" + validSymbols,
            "UUID: \(armUUID) (arm64) /tmp/one\n" +
                "UUID: \(watchUUID) (arm64) /tmp/two\n"
        ]
        for (index, inventory) in invalidInventories.enumerated() {
            try Data(inventory.utf8).write(to: symbols)
            result = try runArtifactValidationHelper(
                command: command,
                arguments: [binary.path, symbols.path]
            )
            XCTAssertNotEqual(result.status, 0, "case \(index): \(result.output)")
        }
    }

    func testProvisioningProfileValidityRejectsFutureExpiredAndMalformedWindows() throws {
        let command = #"source "$1"; validate_profile_validity_values "$2" "$3" "$4" profile"#
        let creation = "2026-01-01T00:00:00Z"
        let expiration = "2026-01-03T00:00:00Z"

        var result = try runArtifactValidationHelper(
            command: command,
            arguments: [creation, expiration, "1767312000"]
        )
        XCTAssertEqual(result.status, 0, result.output)

        let invalidWindows = [
            (creation, expiration, "1767139200"),
            (creation, expiration, "1767398400"),
            (expiration, creation, "1767312000"),
            ("2026-01-01T00:00:00+00:00", expiration, "1767312000"),
            ("2026-02-31T00:00:00Z", expiration, "1767312000"),
            (creation, "not-a-date", "1767312000")
        ]
        for (start, end, now) in invalidWindows {
            result = try runArtifactValidationHelper(
                command: command,
                arguments: [start, end, now]
            )
            XCTAssertNotEqual(result.status, 0, result.output)
        }
    }

    func testProvisioningProfileValidityRequiresTypedDates() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let profile = directory.appendingPathComponent("profile.plist")
        let command = #"source "$1"; validate_provisioning_profile_validity_window "$2" profile 1767312000"#
        let valid = try PropertyListSerialization.data(
            fromPropertyList: [
                "CreationDate": Date(timeIntervalSince1970: 1_767_225_600),
                "ExpirationDate": Date(timeIntervalSince1970: 1_767_398_400)
            ],
            format: .xml,
            options: 0
        )
        try valid.write(to: profile)

        var result = try runArtifactValidationHelper(
            command: command,
            arguments: [profile.path]
        )
        XCTAssertEqual(result.status, 0, result.output)

        let invalid = try PropertyListSerialization.data(
            fromPropertyList: [
                "CreationDate": "2026-01-01T00:00:00Z",
                "ExpirationDate": Date(timeIntervalSince1970: 1_767_398_400)
            ],
            format: .xml,
            options: 0
        )
        try invalid.write(to: profile)
        result = try runArtifactValidationHelper(
            command: command,
            arguments: [profile.path]
        )
        XCTAssertNotEqual(result.status, 0, result.output)
    }

    func testReleasePublicationRequiresProfileValidityHeadroom() throws {
        let command = #"source "$1"; validate_release_publication_validity_headroom "$2" "$3" "$4""#

        var result = try runReleaseOutputHelper(
            command: command,
            arguments: ["401", "300", "100"]
        )
        XCTAssertEqual(result.status, 0, result.output)

        for arguments in [
            ["400", "300", "100"],
            ["399", "300", "100"],
            ["100", "300", "101"],
            ["not-an-epoch", "300", "100"],
            ["401", "0", "100"],
            ["401", "300", "invalid"]
        ] {
            result = try runReleaseOutputHelper(
                command: command,
                arguments: arguments
            )
            XCTAssertNotEqual(result.status, 0, result.output)
        }
    }

    func testProfileFileGuardRejectsLinksAndDetectsMutation() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let profile = directory.appendingPathComponent("profile.plist")
        let symlink = directory.appendingPathComponent("profile-link.plist")
        let hardlink = directory.appendingPathComponent("profile-hardlink.plist")
        try Data("profile".utf8).write(to: profile)
        try FileManager.default.createSymbolicLink(
            at: symlink,
            withDestinationURL: profile
        )
        let validate = #"source "$1"; validate_unlinked_regular_file_artifact "$2" profile"#

        var result = try runArtifactValidationHelper(
            command: validate,
            arguments: [profile.path]
        )
        XCTAssertEqual(result.status, 0, result.output)

        result = try runArtifactValidationHelper(
            command: validate,
            arguments: [symlink.path]
        )
        XCTAssertNotEqual(result.status, 0, result.output)

        try FileManager.default.linkItem(at: profile, to: hardlink)
        result = try runArtifactValidationHelper(
            command: validate,
            arguments: [profile.path]
        )
        XCTAssertNotEqual(result.status, 0, result.output)
        try FileManager.default.removeItem(at: hardlink)

        let mutate = #"source "$1"; validate_unlinked_regular_file_artifact "$2" profile || exit $?; identity="$validated_regular_artifact_identity"; digest="$validated_regular_artifact_hash"; printf 'changed\n' >"$2"; verify_unlinked_regular_file_artifact_unchanged "$2" "$identity" "$digest" profile"#
        result = try runArtifactValidationHelper(
            command: mutate,
            arguments: [profile.path]
        )
        XCTAssertNotEqual(result.status, 0, result.output)
    }

    func testSignedReleaseScriptsPublishOnlyAfterFinalFences() throws {
        for name in ["package-macos.sh", "export-ios.sh"] {
            let script = try releaseScript(named: name)
            let sourcePin = try offset(of: "pin_clean_release_source", in: script)
            let lock = try offset(of: "acquire_release_publication_lock", in: script)
            let stage = try offset(of: "create_release_staging_directory", in: script)
            let publish = try offset(of: "publish_staged_release_directory", in: script)

            XCTAssertLessThan(sourcePin, lock, name)
            XCTAssertLessThan(lock, stage, name)
            XCTAssertLessThan(stage, publish, name)
            XCTAssertTrue(
                script.contains(
                    "verify_source_unchanged\n" +
                        "# Both profiles use one timestamp, after every other " +
                        "fallible release check.\n" +
                        "validate_profiles_at_final_publication_fence || exit $?\n" +
                        "profile_publication_headroom_seconds=300\n" +
                        "publish_staged_release_directory"
                ),
                name
            )
            XCTAssertTrue(
                script.contains(
                    #""$validated_final_profile_expiration_epoch" \"#
                ),
                name
            )
            XCTAssertTrue(script.contains("local validation_epoch"), name)
            XCTAssertEqual(
                script.components(separatedBy: #""$validation_epoch""#).count - 1,
                2,
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

        XCTAssertTrue(publisher.contains("renameatx_np"))
        XCTAssertTrue(publisher.contains("RENAME_EXCL"))
        XCTAssertTrue(publisher.contains("RENAME_NOFOLLOW_ANY"))
        XCTAssertTrue(publisher.contains("RENAME_RESOLVE_BENEATH"))
        XCTAssertTrue(publisher.contains("F_DUPFD_CLOEXEC"))
        XCTAssertTrue(publisher.contains("duplicate_directory_fd"))
        XCTAssertFalse(publisher.contains("open("))
        XCTAssertTrue(publisher.contains("fstatat"))
        XCTAssertTrue(
            helper.contains("/usr/bin/xcrun --no-cache --sdk macosx clang")
        )
        XCTAssertTrue(helper.contains("verify_atomic_release_publisher"))
        XCTAssertTrue(
            helper.contains(
                "validate_release_publication_validity_headroom"
            )
        )
        XCTAssertTrue(helper.contains("\"$expected_staging_parent_identity\""))
        XCTAssertTrue(helper.contains("\"$expected_staged_identity\""))
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
        let command = #"source "$1"; validate_release_output_request "$2" "$3" || exit $?; parent="$validated_release_output_parent"; parent_id="$validated_release_output_parent_identity"; name="$validated_release_output_name"; build_atomic_release_publisher "$4" "$parent/atomic-release-publish" || exit $?; publisher="$validated_release_atomic_publisher"; publisher_id="$validated_release_atomic_publisher_identity"; publisher_hash="$validated_release_atomic_publisher_hash"; acquire_release_publication_lock "$parent" "$name" "$parent_id" || exit $?; lock="$validated_release_publication_lock"; lock_id="$validated_release_publication_lock_identity"; create_release_staging_directory "$parent" "$name" "$parent_id" race || exit $?; stage_parent="$validated_release_staging_parent"; stage_parent_id="$validated_release_staging_parent_identity"; stage="$validated_release_staging_directory"; stage_id="$validated_release_staging_directory_identity"; touch "$stage/staged"; mkdir "$parent/$name"; competitor_id="$(release_path_identity "$parent/$name")"; publish=0; publish_staged_release_directory "$stage" "$stage_id" "$parent" "$parent_id" "$name" "$publisher" "$publisher_id" "$publisher_hash" "$stage_parent_id" || publish=$?; [[ "$publish" == 73 && -f "$stage/staged" && -d "$parent/$name" && "$(release_path_identity "$parent/$name")" == "$competitor_id" && -z "$(find "$parent/$name" -mindepth 1 -print -quit)" ]] || exit 1; rmdir "$parent/$name"; cleanup_private_release_directory "$stage_parent" "$stage_parent_id" "$parent" '^\.AgentLimits-race-stage\.[A-Za-z0-9]{6}$' || exit $?; release_release_publication_lock "$lock" "$lock_id" "$parent" "$name" || exit $?; rm "$publisher""#

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

        let result = try runAtomicPublisher(
            executable: publisher.path,
            sourceParent: directory.path,
            sourceName: source.lastPathComponent,
            sourceParentIdentity: try fileIdentity(at: directory),
            sourceIdentity: sourceIdentity,
            destinationParent: directory.path,
            destinationName: destination.lastPathComponent,
            destinationParentIdentity: try fileIdentity(at: directory)
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

    func testAtomicPublisherRejectsReplacedSourceParent() throws {
        let directory = try releaseTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceParent = directory.appendingPathComponent("source-parent")
        let originalParent = directory.appendingPathComponent("original-parent")
        let destinationParent = directory.appendingPathComponent("destination-parent")
        let source = sourceParent.appendingPathComponent("result")
        let publisher = directory.appendingPathComponent("atomic-release-publish")
        try FileManager.default.createDirectory(
            at: source,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: destinationParent,
            withIntermediateDirectories: false
        )
        try Data("trusted".utf8).write(
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
        let sourceParentIdentity = try fileIdentity(at: sourceParent)
        let sourceIdentity = try fileIdentity(at: source)
        let destinationParentIdentity = try fileIdentity(at: destinationParent)
        try FileManager.default.moveItem(at: sourceParent, to: originalParent)
        try FileManager.default.createDirectory(
            at: sourceParent.appendingPathComponent("result"),
            withIntermediateDirectories: true
        )

        let result = try runAtomicPublisher(
            executable: publisher.path,
            sourceParent: sourceParent.path,
            sourceName: "result",
            sourceParentIdentity: sourceParentIdentity,
            sourceIdentity: sourceIdentity,
            destinationParent: destinationParent.path,
            destinationName: "result",
            destinationParentIdentity: destinationParentIdentity
        )

        XCTAssertEqual(result.status, 73, result.output)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: originalParent
                    .appendingPathComponent("result/payload").path
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: destinationParent.appendingPathComponent("result").path
            )
        )
    }

    func testReleasePublicationAtomicallyPreservesStagedIdentity() throws {
        let directory = try releaseTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("result")
        let command = #"source "$1"; validate_release_output_request "$2" "$3" || exit $?; parent="$validated_release_output_parent"; parent_id="$validated_release_output_parent_identity"; name="$validated_release_output_name"; build_atomic_release_publisher "$4" "$parent/atomic-release-publish" || exit $?; publisher="$validated_release_atomic_publisher"; publisher_id="$validated_release_atomic_publisher_identity"; publisher_hash="$validated_release_atomic_publisher_hash"; acquire_release_publication_lock "$parent" "$name" "$parent_id" || exit $?; lock="$validated_release_publication_lock"; lock_id="$validated_release_publication_lock_identity"; create_release_staging_directory "$parent" "$name" "$parent_id" atomic || exit $?; stage_parent="$validated_release_staging_parent"; stage_parent_id="$validated_release_staging_parent_identity"; stage="$validated_release_staging_directory"; stage_id="$validated_release_staging_directory_identity"; touch "$stage/payload"; publish_staged_release_directory "$stage" "$stage_id" "$parent" "$parent_id" "$name" "$publisher" "$publisher_id" "$publisher_hash" "$stage_parent_id" || exit $?; [[ ! -e "$stage" && -f "$parent/$name/payload" && "$(release_path_identity "$parent/$name")" == "$stage_id" ]] || exit 1; rmdir "$stage_parent"; release_release_publication_lock "$lock" "$lock_id" "$parent" "$name" || exit $?; rm "$publisher""#

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

        XCTAssertTrue(script.contains("PATH=\"/usr/bin:/bin:/usr/sbin:/sbin\""))
        XCTAssertTrue(script.contains("HEAD:Scripts/signing-config.sh"))
        XCTAssertTrue(script.contains("source \"$trusted_signing_config\""))
        XCTAssertFalse(script.contains("source \"$script_dir/signing-config.sh\""))
        XCTAssertTrue(script.contains("sanitize_release_git_environment"))
        XCTAssertLessThan(
            try offset(of: "pin_clean_release_source", in: script),
            try offset(
                of: "source \"$script_dir/release-output.sh\"",
                in: script
            )
        )
        XCTAssertTrue(script.contains("unset CDPATH"))
        XCTAssertTrue(script.contains("Refusing to run a release build through a script symlink"))
        XCTAssertTrue(script.contains("pin_clean_release_source"))
        XCTAssertTrue(script.contains("create_immutable_release_source_snapshot"))
        XCTAssertTrue(script.contains("$build_root/AgentLimits.xcodeproj"))
        XCTAssertTrue(
            script.contains("prepare_xcode_signing_environment \"$snapshot_config\"")
        )
        XCTAssertTrue(script.contains("verify_source_unchanged"))
        XCTAssertTrue(script.contains("-derivedDataPath \"$derived_data\""))
        XCTAssertTrue(script.contains("validate_release_output_request"))
        XCTAssertTrue(script.contains("acquire_release_publication_lock"))
        XCTAssertTrue(script.contains("create_release_staging_directory"))
        XCTAssertTrue(script.contains("create_private_release_work_directory"))
        XCTAssertTrue(script.contains("build_atomic_release_publisher"))
        XCTAssertTrue(script.contains("publish_staged_release_directory"))
        XCTAssertFalse(script.contains("/bin/mv -n"))
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

    func testAppleCIProvisionsDedicatedIOSSimulators() throws {
        let workflow = try repositoryText(".github/workflows/apple-ci.yml")

        XCTAssertTrue(workflow.contains("device_name: iPhone 17 Pro"))
        XCTAssertTrue(
            workflow.contains("device_name: iPad Pro 13-inch (M5)")
        )
        XCTAssertTrue(
            workflow.contains(
                "Scripts/create-ci-ios-simulator.sh \"$IOS_DEVICE_NAME\""
            )
        )
        XCTAssertTrue(
            workflow.contains(
                "RESOLVED_IOS_DESTINATION: ${{ steps.ios-destination.outputs.destination }}"
            )
        )
        XCTAssertTrue(
            workflow.contains(
                "xcrun simctl delete \"$IOS_SIMULATOR_UDID\""
            )
        )
        XCTAssertFalse(
            workflow.contains(
                "platform=iOS Simulator,name=iPad Pro 13-inch (M5),OS=latest"
            )
        )
    }

    func testCISimulatorProvisionerCreatesLatestRequestedDevice() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fakeXcrun = directory.appendingPathComponent("xcrun")
        let log = directory.appendingPathComponent("xcrun.log")
        let fakeScript = #"""
        #!/bin/bash
        set -euo pipefail
        printf '%s\n' "$*" >> "$AGENTLIMITS_FAKE_XCRUN_LOG"
        if [[ "$1 $2 $3" == "simctl list runtimes" ]]; then
          printf '%s\n' '{"runtimes":[{"identifier":"com.apple.CoreSimulator.SimRuntime.iOS-26-4","version":"26.4","name":"iOS 26.4","platform":"iOS","isAvailable":true},{"identifier":"com.apple.CoreSimulator.SimRuntime.iOS-27-0","version":"27.0","name":"iOS 27.0","platform":"iOS","isAvailable":false},{"identifier":"com.apple.CoreSimulator.SimRuntime.iOS-26-5","version":"26.5","name":"iOS 26.5","platform":"iOS","isAvailable":true}]}'
        elif [[ "$1 $2 $3" == "simctl list devicetypes" ]]; then
          printf '%s\n' '{"devicetypes":[{"identifier":"com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro","name":"iPhone 17 Pro"},{"identifier":"com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch-M5-12GB","name":"iPad Pro 13-inch (M5)"}]}'
        elif [[ "$1 $2" == "simctl create" ]]; then
          printf '%s\n' '01234567-89AB-CDEF-0123-456789ABCDEF'
        elif [[ "$1 $2" == "simctl delete" ]]; then
          exit 0
        else
          exit 99
        fi
        """#
        try Data(fakeScript.utf8).write(to: fakeXcrun)
        try setPermissions(0o700, for: fakeXcrun)

        let result = try runReleaseScript(
            relativePath: "Scripts/create-ci-ios-simulator.sh",
            arguments: ["iPad Pro 13-inch (M5)"],
            environment: [
                "AGENTLIMITS_FAKE_XCRUN_LOG": log.path,
                "GITHUB_RUN_ATTEMPT": "3",
                "GITHUB_RUN_ID": "12345",
                "PATH": "\(directory.path):/usr/bin:/bin"
            ]
        )

        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertEqual(
            result.output,
            "platform=iOS Simulator,id=01234567-89AB-CDEF-0123-456789ABCDEF\n"
        )
        let calls = try String(contentsOf: log, encoding: .utf8)
        XCTAssertTrue(
            calls.contains(
                "simctl create AgentLimits CI - iPad Pro 13-inch (M5) - 12345-3 com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch-M5-12GB com.apple.CoreSimulator.SimRuntime.iOS-26-5"
            ),
            calls
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
        let publish = try offset(of: "publish_staged_release_directory", in: script)

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

    private func repositoryFile(_ path: String) throws -> String {
        try String(
            contentsOf: repositoryRoot.appendingPathComponent(path),
            encoding: .utf8
        )
    }

    private func temporaryFile(
        named name: String,
        contents: String
    ) throws -> (directory: URL, file: URL) {
        let directory = try temporaryDirectory()
        let file = directory.appendingPathComponent(name)
        try Data(contents.utf8).write(to: file)
        return (directory, file)
    }

    private func dependencyExceptionRegistry(expiresOn: String) -> String {
        """
        {
          "schema_version": 1,
          "exceptions": [
            {
              "advisory_url": "https://github.com/advisories/GHSA-2345-6789-cfgh",
              "affected_packages": ["pkg:swift/github.com/sparkle-project/Sparkle@2.9.4"],
              "compensating_controls": "Affected path is disabled until upgrade.",
              "expires_on": "\(expiresOn)",
              "ghsa": "GHSA-2345-6789-cfgh",
              "justification": "No patched release is currently available.",
              "owner": "@JimBoHa",
              "tracking_issue": "https://github.com/JimBoHa/AgentLimits-forked/issues/1"
            }
          ]
        }
        """
    }

    private var emptyDependencyExceptionRegistry: String {
        """
        {
          "schema_version": 1,
          "exceptions": []
        }
        """
    }

    private func validateDependencyExceptionRegistry(
        _ contents: String
    ) throws -> (status: Int32, output: String) {
        let fixture = try temporaryFile(
            named: "dependency-review-exceptions.json",
            contents: contents
        )
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        return try runDependencyExceptionValidator(registry: fixture.file)
    }

    private func dependencyPolicyRepository(
        registry: String?
    ) throws -> (directory: URL, baseSHA: String) {
        let directory = try temporaryDirectory()
        _ = try runGit(["init", "-q", "-b", "main"], in: directory)
        _ = try runGit(
            ["config", "user.name", "Dependency Policy Fixture"],
            in: directory
        )
        _ = try runGit(
            ["config", "user.email", "fixture@example.invalid"],
            in: directory
        )
        try Data("base\n".utf8).write(
            to: directory.appendingPathComponent("Marker.txt")
        )
        if let registry {
            try writeDependencyRegistry(registry, in: directory)
        }
        let baseSHA = try commitAll(in: directory, message: "base")
        return (directory, baseSHA)
    }

    private func writeDependencyRegistry(
        _ contents: String,
        in directory: URL
    ) throws {
        let github = directory.appendingPathComponent(".github")
        try FileManager.default.createDirectory(
            at: github,
            withIntermediateDirectories: true
        )
        try Data(contents.utf8).write(
            to: github.appendingPathComponent(
                "dependency-review-exceptions.json"
            )
        )
    }

    private func commitAll(in directory: URL, message: String) throws -> String {
        _ = try runGit(["add", "--all"], in: directory)
        _ = try runGit(["commit", "-q", "-m", message], in: directory)
        return try runGit(["rev-parse", "HEAD"], in: directory)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func runGit(
        _ arguments: [String],
        in directory: URL
    ) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.environment = dependencyPolicyProcessEnvironment()
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        let text = String(
            decoding: output.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        )
        guard process.terminationStatus == 0 else {
            throw NSError(
                domain: "DependencyPolicyGitFixture",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: text]
            )
        }
        return text
    }

    private func dependencyPolicyProcessEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment.keys
            .filter { $0.hasPrefix("GIT_") }
            .forEach { environment.removeValue(forKey: $0) }
        environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        environment["GIT_CONFIG_NOSYSTEM"] = "1"
        environment["LC_ALL"] = "C"
        environment["PATH"] = "/usr/bin:/bin"
        return environment
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
        process.executableURL = repositoryRoot.appendingPathComponent(relativePath)
        process.arguments = arguments
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

    private func runAppleCredentialGuard(
        repository: URL
    ) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = repositoryRoot.appendingPathComponent(
            "Scripts/reject-apple-credential-artifacts.sh"
        )
        process.arguments = [repository.path]
        process.environment = dependencyPolicyProcessEnvironment()
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

    private func runDependencySecurityConfigValidator(
        workflow: URL,
        dependabot: URL? = nil
    ) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ruby")
        process.arguments = [
            repositoryRoot.appendingPathComponent(
                "Scripts/validate-dependency-security-config.rb"
            ).path,
            workflow.path,
            (dependabot ?? repositoryRoot.appendingPathComponent(
                ".github/dependabot.yml"
            )).path
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

    private func runDependencyExceptionValidator(
        registry: URL
    ) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [
            repositoryRoot.appendingPathComponent(
                "Scripts/dependency-exceptions.sh"
            ).path,
            "validate",
            registry.path
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

    private func runDependencyExceptionPullRequestValidator(
        repository: URL,
        baseSHA: String,
        headSHA: String
    ) throws -> (status: Int32, output: String, githubOutput: String) {
        let githubOutput = FileManager.default.temporaryDirectory
            .appendingPathComponent("dependency-output-\(UUID().uuidString)")
        try Data().write(to: githubOutput)
        defer { try? FileManager.default.removeItem(at: githubOutput) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [
            repositoryRoot.appendingPathComponent(
                "Scripts/dependency-exceptions.sh"
            ).path,
            "prepare-pull-request",
            ".github/dependency-review-exceptions.json",
            baseSHA,
            headSHA,
            githubOutput.path
        ]
        process.currentDirectoryURL = repository
        process.environment = dependencyPolicyProcessEnvironment()
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let emitted = try String(contentsOf: githubOutput, encoding: .utf8)
        return (
            process.terminationStatus,
            String(decoding: data, as: UTF8.self),
            emitted
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

    private func runArtifactValidationHelper(
        command: String,
        arguments: [String]
    ) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [
            "-c",
            command,
            "artifact-validation-test",
            repositoryRoot.appendingPathComponent(
                "Scripts/release-artifact-validation.sh"
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

    private func runAtomicPublisher(
        executable: String,
        sourceParent: String,
        sourceName: String,
        sourceParentIdentity: String,
        sourceIdentity: String,
        destinationParent: String,
        destinationName: String,
        destinationParentIdentity: String
    ) throws -> (status: Int32, output: String) {
        let command = #"""
        exec 8< "$1" || exit 73
        exec 9< "$5" || exit 73
        exec "$8" 8 "$2" "$3" "$4" 9 "$6" "$7"
        """#
        return try runProcess(
            executable: "/bin/bash",
            arguments: [
                "--noprofile", "--norc", "-c", command,
                "atomic-publisher-test",
                sourceParent,
                sourceName,
                sourceParentIdentity,
                sourceIdentity,
                destinationParent,
                destinationName,
                destinationParentIdentity,
                executable
            ],
            inheritEnvironment: false
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
