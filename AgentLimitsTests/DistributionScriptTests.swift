import Foundation
import XCTest

final class DistributionScriptTests: XCTestCase {
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

    func testUnsignedBuildUsesCleanSnapshotAndAtomicStaging() throws {
        let script = try releaseScript(named: "build-unsigned-artifacts.sh")
        let containerValidation = try releaseScript(
            named: "macos-container-validation.sh"
        )

        XCTAssertTrue(script.contains("PATH=\"/usr/bin:/bin:/usr/sbin:/sbin\""))
        XCTAssertTrue(script.contains("source \"$script_dir/signing-config.sh\""))
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
                commands.filter { $0.contains("-exportArchive") }
                    .allSatisfy { !$0.contains(lockFlag) },
                name
            )
        }
    }

    func testHostileXcodeEnvironmentIsReplaced() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = directory.appendingPathComponent("sanitized.xcconfig")
        try Data("DEVELOPMENT_TEAM = ABCDE12345\n".utf8).write(to: config)
        let command = #"source "$1"; export XCODE_XCCONFIG_FILE=/private/tmp/hostile.xcconfig; export TOOLCHAINS=hostile; export XCRUN_TOOLCHAIN_NAME=hostile; export SDKROOT=/private/tmp; export CPATH=/private/tmp/include; export LIBRARY_PATH=/private/tmp/lib; prepare_xcode_signing_environment "$2"; printf '%s\n%s\n%s\n%s\n%s\n%s\n' "$XCODE_XCCONFIG_FILE" "${TOOLCHAINS-unset}" "${XCRUN_TOOLCHAIN_NAME-unset}" "${SDKROOT-unset}" "${CPATH-unset}" "${LIBRARY_PATH-unset}""#

        let result = try runSigningConfigValidator(config: config, command: command)

        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertEqual(
            result.output.split(separator: "\n").map(String.init),
            [config.path, "unset", "unset", "unset", "unset", "unset"]
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
        let pkgStaple = try offset(of: #"xcrun stapler staple "$pkg""#, in: script)
        let pkgExpand = try offset(of: #"pkgutil --expand-full "$pkg""#, in: script)
        let dmgStaple = try offset(of: #"xcrun stapler staple "$dmg""#, in: script)
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
        XCTAssertTrue(
            script.contains(
                "mktemp -d \"/private/tmp/AgentLimits-macos-package.XXXXXX\""
            )
        )
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
        try String(
            contentsOf: repositoryRoot.appendingPathComponent("Scripts/\(name)"),
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
