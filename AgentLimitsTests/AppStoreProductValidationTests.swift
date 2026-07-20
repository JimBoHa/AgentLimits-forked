import Foundation
import XCTest

final class AppStoreProductValidationTests: XCTestCase {
    func testIOSReleaseEnablesProductValidation() throws {
        let project = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "AgentLimits.xcodeproj/project.pbxproj"
            ),
            encoding: .utf8
        )
        let release = try buildConfiguration(
            id: "B20000000000000000000029",
            in: project
        )

        XCTAssertTrue(release.contains("VALIDATE_PRODUCT = YES;"), release)
    }

    func testReleaseWorkflowsRunSemanticProductValidation() throws {
        for name in ["build-unsigned-artifacts.sh", "export-ios.sh"] {
            let script = try String(
                contentsOf: repositoryRoot.appendingPathComponent("Scripts/\(name)"),
                encoding: .utf8
            )
            XCTAssertTrue(
                script.contains(
                    "source \"$script_dir/app-store-product-validation.sh\""
                ),
                name
            )
            XCTAssertTrue(script.contains("validate_app_store_product"), name)
        }
    }

    func testValidAppStoreProductPassesSemanticValidation() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try createProductFixture(at: directory)

        let result = try runValidator(
            fixture: fixture,
            scratch: directory.appendingPathComponent("validation")
        )

        XCTAssertEqual(result.status, 0, result.output)
    }

    func testProductMetadataMutationsFailSemanticValidation() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let mutations: [(String, (ProductFixture) throws -> Void)] = [
            ("bundle-id", { fixture in
                try self.mutatePropertyList(fixture.iosInfo) {
                    $0["CFBundleIdentifier"] = "org.example.changed"
                }
            }),
            ("version", { fixture in
                try self.mutatePropertyList(fixture.watchInfo) {
                    $0["CFBundleVersion"] = "17"
                }
            }),
            ("encryption", { fixture in
                try self.mutatePropertyList(fixture.iosInfo) {
                    $0["ITSAppUsesNonExemptEncryption"] = true
                }
            }),
            ("launch-screen", { fixture in
                try self.mutatePropertyList(fixture.iosInfo) {
                    $0.removeValue(forKey: "UILaunchScreen")
                }
            }),
            ("icon", { fixture in
                try self.mutatePropertyList(fixture.watchInfo) {
                    $0["CFBundleIcons"] = [
                        "CFBundlePrimaryIcon": [
                            "CFBundleIconName": "ChangedIcon"
                        ]
                    ]
                }
            }),
            ("companion", { fixture in
                try self.mutatePropertyList(fixture.watchInfo) {
                    $0["WKCompanionAppBundleIdentifier"] = "org.example.changed"
                }
            })
        ]

        for (name, mutate) in mutations {
            let caseDirectory = directory.appendingPathComponent(name)
            let fixture = try createProductFixture(at: caseDirectory)
            try mutate(fixture)

            let result = try runValidator(
                fixture: fixture,
                scratch: caseDirectory.appendingPathComponent("validation")
            )
            XCTAssertNotEqual(result.status, 0, "\(name): \(result.output)")
        }
    }

    func testPrivacyClaimMutationsFailSemanticValidation() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let mutations: [(String, (ProductFixture) throws -> Void)] = [
            ("tracking", { fixture in
                try self.mutatePropertyList(fixture.iosPrivacy) {
                    $0["NSPrivacyTracking"] = true
                }
            }),
            ("collected-data", { fixture in
                try self.mutatePropertyList(fixture.watchPrivacy) {
                    $0["NSPrivacyCollectedDataTypes"] = [
                        ["NSPrivacyCollectedDataType": "NSPrivacyCollectedDataTypeEmailAddress"]
                    ]
                }
            }),
            ("required-reason", { fixture in
                try self.mutatePropertyList(fixture.iosPrivacy) {
                    $0["NSPrivacyAccessedAPITypes"] = [[
                        "NSPrivacyAccessedAPIType":
                            "NSPrivacyAccessedAPICategoryUserDefaults",
                        "NSPrivacyAccessedAPITypeReasons": ["C617.1"]
                    ]]
                }
            }),
            ("undeclared-key", { fixture in
                try self.mutatePropertyList(fixture.watchPrivacy) {
                    $0["UnexpectedPrivacyClaim"] = true
                }
            })
        ]

        for (name, mutate) in mutations {
            let caseDirectory = directory.appendingPathComponent(name)
            let fixture = try createProductFixture(at: caseDirectory)
            try mutate(fixture)

            let result = try runValidator(
                fixture: fixture,
                scratch: caseDirectory.appendingPathComponent("validation")
            )
            XCTAssertNotEqual(result.status, 0, "\(name): \(result.output)")
        }
    }

    private struct ProductFixture {
        let iosApp: URL
        let iosInfo: URL
        let watchInfo: URL
        let iosPrivacy: URL
        let watchPrivacy: URL
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func buildConfiguration(id: String, in project: String) throws -> String {
        let marker = "\t\t\(id) /* Release */ = {"
        let start = try XCTUnwrap(project.range(of: marker))
        let tail = project[start.lowerBound...]
        let end = try XCTUnwrap(tail.range(of: "\n\t\t};"))
        return String(project[start.lowerBound..<end.upperBound])
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "AgentLimitsAppStoreValidationTests-\(UUID().uuidString)"
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false
        )
        return directory
    }

    private func createProductFixture(at directory: URL) throws -> ProductFixture {
        let iosApp = directory.appendingPathComponent("AgentLimits.app")
        let watchApp = iosApp.appendingPathComponent("Watch/AgentLimitsWatch.app")
        try FileManager.default.createDirectory(
            at: watchApp,
            withIntermediateDirectories: true
        )

        let iosInfo = iosApp.appendingPathComponent("Info.plist")
        let watchInfo = watchApp.appendingPathComponent("Info.plist")
        let iosPrivacy = iosApp.appendingPathComponent("PrivacyInfo.xcprivacy")
        let watchPrivacy = watchApp.appendingPathComponent("PrivacyInfo.xcprivacy")

        try writePropertyList([
            "CFBundleDisplayName": "AgentLimits Forked",
            "CFBundleIcons": [
                "CFBundlePrimaryIcon": [
                    "CFBundleIconFiles": ["agentlimits60x60"],
                    "CFBundleIconName": "agentlimits"
                ]
            ],
            "CFBundleIcons~ipad": [
                "CFBundlePrimaryIcon": [
                    "CFBundleIconFiles": ["agentlimits60x60", "agentlimits76x76"],
                    "CFBundleIconName": "agentlimits"
                ]
            ],
            "CFBundleIdentifier": "com.jimboha.agentlimits.ios",
            "CFBundleName": "AgentLimits",
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": "1.1.6",
            "CFBundleSupportedPlatforms": ["iPhoneOS"],
            "CFBundleVersion": "16",
            "ITSAppUsesNonExemptEncryption": false,
            "LSApplicationCategoryType": "public.app-category.utilities",
            "LSRequiresIPhoneOS": true,
            "UIDeviceFamily": [1, 2],
            "UILaunchScreen": ["UILaunchScreen": [String: Any]()]
        ], to: iosInfo)
        try writePropertyList([
            "CFBundleDisplayName": "AgentLimits Forked",
            "CFBundleIcons": [
                "CFBundlePrimaryIcon": ["CFBundleIconName": "agentlimits"]
            ],
            "CFBundleIdentifier": "com.jimboha.agentlimits.ios.watchkitapp",
            "CFBundleName": "AgentLimitsWatch",
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": "1.1.6",
            "CFBundleSupportedPlatforms": ["WatchOS"],
            "CFBundleVersion": "16",
            "ITSAppUsesNonExemptEncryption": false,
            "UIDeviceFamily": [4],
            "WKApplication": true,
            "WKCompanionAppBundleIdentifier": "com.jimboha.agentlimits.ios",
            "WKRunsIndependentlyOfCompanionApp": false
        ], to: watchInfo)

        let privacy: [String: Any] = [
            "NSPrivacyAccessedAPITypes": [[
                "NSPrivacyAccessedAPIType":
                    "NSPrivacyAccessedAPICategoryUserDefaults",
                "NSPrivacyAccessedAPITypeReasons": ["CA92.1"]
            ]],
            "NSPrivacyCollectedDataTypes": [Any](),
            "NSPrivacyTracking": false,
            "NSPrivacyTrackingDomains": [Any]()
        ]
        try writePropertyList(privacy, to: iosPrivacy)
        try writePropertyList(privacy, to: watchPrivacy)

        for file in [
            iosApp.appendingPathComponent("Assets.car"),
            iosApp.appendingPathComponent("agentlimits60x60@2x.png"),
            iosApp.appendingPathComponent("agentlimits76x76@2x~ipad.png"),
            watchApp.appendingPathComponent("Assets.car")
        ] {
            try Data().write(to: file)
        }

        return ProductFixture(
            iosApp: iosApp,
            iosInfo: iosInfo,
            watchInfo: watchInfo,
            iosPrivacy: iosPrivacy,
            watchPrivacy: watchPrivacy
        )
    }

    private func writePropertyList(_ object: [String: Any], to url: URL) throws {
        let data = try PropertyListSerialization.data(
            fromPropertyList: object,
            format: .xml,
            options: 0
        )
        try data.write(to: url)
    }

    private func mutatePropertyList(
        _ url: URL,
        mutation: (inout [String: Any]) -> Void
    ) throws {
        let data = try Data(contentsOf: url)
        var plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
            ) as? [String: Any]
        )
        mutation(&plist)
        try writePropertyList(plist, to: url)
    }

    private func runValidator(
        fixture: ProductFixture,
        scratch: URL
    ) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [
            "-c",
            #"set -euo pipefail; source "$1"; validate_app_store_product "$2" "$3" "$4" "$5""#,
            "app-store-product-validation-test",
            repositoryRoot.appendingPathComponent(
                "Scripts/app-store-product-validation.sh"
            ).path,
            fixture.iosApp.path,
            "1.1.6",
            "16",
            scratch.path
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
}
