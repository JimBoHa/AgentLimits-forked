import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
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

        let exportScript = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Scripts/export-ios.sh"
            ),
            encoding: .utf8
        )
        XCTAssertTrue(
            exportScript.contains("-target AgentLimitsiOS"),
            exportScript
        )
        XCTAssertTrue(exportScript.contains("-sdk iphoneos"), exportScript)

        let unsignedScript = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Scripts/build-unsigned-artifacts.sh"
            ),
            encoding: .utf8
        )
        XCTAssertEqual(
            unsignedScript.components(
                separatedBy: "app_store_validate_applications_root"
            ).count - 1,
            2,
            unsignedScript
        )
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

    func testHostileMagicEnvironmentCannotOverrideCodeInventory() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try createProductFixture(at: directory)
        let hostileMagic = directory.appendingPathComponent("hostile.magic")
        try Data().write(to: hostileMagic)

        let validResult = try runValidator(
            fixture: fixture,
            scratch: directory.appendingPathComponent("valid-validation"),
            environment: ["MAGIC": hostileMagic.path]
        )
        XCTAssertEqual(validResult.status, 0, validResult.output)

        let unexpectedCode = fixture.iosApp.appendingPathComponent(
            "UnexpectedCode"
        )
        try FileManager.default.copyItem(
            at: URL(fileURLWithPath: "/usr/bin/true"),
            to: unexpectedCode
        )
        try setPermissions(0o600, for: unexpectedCode)

        let rejectedResult = try runValidator(
            fixture: fixture,
            scratch: directory.appendingPathComponent("rejected-validation"),
            environment: ["MAGIC": hostileMagic.path]
        )
        XCTAssertNotEqual(rejectedResult.status, 0, rejectedResult.output)
        XCTAssertTrue(
            rejectedResult.output.contains(
                "product contains an unaudited Mach-O code object"
            ),
            rejectedResult.output
        )
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
            ("executable-name", { fixture in
                try self.mutatePropertyList(fixture.watchInfo) {
                    $0["CFBundleExecutable"] = "Unexpected"
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

    func testUnexpectedProductTopologyFailsSemanticValidation() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let mutations: [(String, (ProductFixture) throws -> Void)] = [
            ("second-watch-app", { fixture in
                try FileManager.default.createDirectory(
                    at: fixture.iosApp.appendingPathComponent(
                        "Watch/Unexpected.app"
                    ),
                    withIntermediateDirectories: false
                )
            }),
            ("unexpected-extension", { fixture in
                try FileManager.default.createDirectory(
                    at: fixture.iosApp.appendingPathComponent(
                        "PlugIns/Unexpected.appex"
                    ),
                    withIntermediateDirectories: true
                )
            }),
            ("product-symlink", { fixture in
                try FileManager.default.createSymbolicLink(
                    at: fixture.iosApp.appendingPathComponent("UnexpectedLink"),
                    withDestinationURL: fixture.iosInfo
                )
            }),
            ("unexpected-framework", { fixture in
                try FileManager.default.createDirectory(
                    at: fixture.iosApp.appendingPathComponent(
                        "Frameworks/Unexpected.framework"
                    ),
                    withIntermediateDirectories: true
                )
            }),
            ("unexpected-xpc", { fixture in
                try FileManager.default.createDirectory(
                    at: fixture.iosApp.appendingPathComponent(
                        "XPCServices/Unexpected.xpc"
                    ),
                    withIntermediateDirectories: true
                )
            }),
            ("unexpected-bundle", { fixture in
                try FileManager.default.createDirectory(
                    at: fixture.iosApp.appendingPathComponent(
                        "Resources/Unexpected.bundle"
                    ),
                    withIntermediateDirectories: true
                )
            }),
            ("unexpected-dylib", { fixture in
                let frameworks = fixture.iosApp.appendingPathComponent(
                    "Frameworks"
                )
                try FileManager.default.createDirectory(
                    at: frameworks,
                    withIntermediateDirectories: false
                )
                try Data([1]).write(
                    to: frameworks.appendingPathComponent("Unexpected.dylib")
                )
            }),
            ("raw-mach-o", { fixture in
                let code = fixture.iosApp.appendingPathComponent(
                    "UnexpectedCode"
                )
                try FileManager.default.copyItem(
                    at: URL(fileURLWithPath: "/usr/bin/true"),
                    to: code
                )
                try self.setPermissions(0o600, for: code)
            }),
            ("executable-script", { fixture in
                let script = fixture.iosApp.appendingPathComponent(
                    "UnexpectedTool"
                )
                try Data("#!/bin/sh\n".utf8).write(to: script)
                try self.setPermissions(0o700, for: script)
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

    func testHostileIconArtifactsFailSemanticValidation() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let mutations: [(String, (ProductFixture) throws -> Void)] = [
            ("empty-png", { fixture in
                try Data().write(
                    to: fixture.iosApp.appendingPathComponent(
                        "agentlimits60x60@2x.png"
                    )
                )
            }),
            ("wrong-png-dimensions", { fixture in
                try self.writePNG(
                    width: 1,
                    height: 1,
                    to: fixture.iosApp.appendingPathComponent(
                        "agentlimits76x76@2x~ipad.png"
                    )
                )
            }),
            ("missing-phone-rendition", { fixture in
                try self.writeAssetCatalogInfo(
                    platform: "ios",
                    idioms: ["pad"],
                    to: fixture.iosAssetInfo
                )
            }),
            ("wrong-watch-platform", { fixture in
                try self.writeAssetCatalogInfo(
                    platform: "ios",
                    idioms: ["watch"],
                    to: fixture.watchAssetInfo
                )
            }),
            ("empty-assets", { fixture in
                try Data().write(
                    to: fixture.iosApp.appendingPathComponent("Assets.car")
                )
            }),
            ("assetutil-symlink", { fixture in
                try FileManager.default.removeItem(at: fixture.assetutil)
                try FileManager.default.createSymbolicLink(
                    at: fixture.assetutil,
                    withDestinationURL: URL(fileURLWithPath: "/bin/cat")
                )
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

    func testIPAAndPayloadSelectionRejectCardinalityAndSymlinks() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let export = directory.appendingPathComponent("export")
        try FileManager.default.createDirectory(
            at: export,
            withIntermediateDirectories: false
        )
        let firstIPA = export.appendingPathComponent("AgentLimits.ipa")
        try Data([1]).write(to: firstIPA)
        var result = try runValidationHelper(
            "app_store_select_single_ipa",
            arguments: [export.path, directory.appendingPathComponent("ipa").path]
        )
        XCTAssertEqual(result.status, 0, result.output)

        let secondIPA = export.appendingPathComponent("Unexpected.IPA")
        try Data([2]).write(to: secondIPA)
        result = try runValidationHelper(
            "app_store_select_single_ipa",
            arguments: [export.path, directory.appendingPathComponent("ipa-two").path]
        )
        XCTAssertNotEqual(result.status, 0, result.output)
        try FileManager.default.removeItem(at: secondIPA)
        try FileManager.default.createSymbolicLink(
            at: export.appendingPathComponent("alias"),
            withDestinationURL: firstIPA
        )
        result = try runValidationHelper(
            "app_store_select_single_ipa",
            arguments: [export.path, directory.appendingPathComponent("ipa-link").path]
        )
        XCTAssertNotEqual(result.status, 0, result.output)

        let ipaRoot = directory.appendingPathComponent("expanded")
        let payload = ipaRoot.appendingPathComponent("Payload")
        try FileManager.default.createDirectory(
            at: payload.appendingPathComponent("AgentLimits.app"),
            withIntermediateDirectories: true
        )
        result = try runValidationHelper(
            "app_store_select_single_payload_app",
            arguments: [
                ipaRoot.path,
                directory.appendingPathComponent("payload").path
            ]
        )
        XCTAssertEqual(result.status, 0, result.output)
        try FileManager.default.createDirectory(
            at: payload.appendingPathComponent("Unexpected.app"),
            withIntermediateDirectories: false
        )
        result = try runValidationHelper(
            "app_store_select_single_payload_app",
            arguments: [
                ipaRoot.path,
                directory.appendingPathComponent("payload-two").path
            ]
        )
        XCTAssertNotEqual(result.status, 0, result.output)
    }

    func testArchiveApplicationsRootRejectsSiblingEntry() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let applications = directory.appendingPathComponent("Applications")
        let expected = applications.appendingPathComponent("AgentLimits.app")
        try FileManager.default.createDirectory(
            at: expected,
            withIntermediateDirectories: true
        )

        var result = try runValidationHelper(
            "app_store_validate_applications_root",
            arguments: [
                applications.path,
                expected.path,
                directory.appendingPathComponent("root-valid").path
            ]
        )
        XCTAssertEqual(result.status, 0, result.output)

        try FileManager.default.createDirectory(
            at: applications.appendingPathComponent("Unexpected.app"),
            withIntermediateDirectories: false
        )
        result = try runValidationHelper(
            "app_store_validate_applications_root",
            arguments: [
                applications.path,
                expected.path,
                directory.appendingPathComponent("root-sibling").path
            ]
        )
        XCTAssertNotEqual(result.status, 0, result.output)
    }

    private struct ProductFixture {
        let iosApp: URL
        let iosInfo: URL
        let watchInfo: URL
        let iosPrivacy: URL
        let watchPrivacy: URL
        let iosAssetInfo: URL
        let watchAssetInfo: URL
        let assetutil: URL
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
            "CFBundleExecutable": "AgentLimits",
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
            "CFBundleExecutable": "AgentLimitsWatch",
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

        let systemExecutable = URL(fileURLWithPath: "/usr/bin/true")
        let iosExecutable = iosApp.appendingPathComponent("AgentLimits")
        let watchExecutable = watchApp.appendingPathComponent("AgentLimitsWatch")
        try FileManager.default.copyItem(
            at: systemExecutable,
            to: iosExecutable
        )
        try FileManager.default.copyItem(
            at: systemExecutable,
            to: watchExecutable
        )
        try setPermissions(0o700, for: iosExecutable)
        try setPermissions(0o700, for: watchExecutable)

        let iosAssets = iosApp.appendingPathComponent("Assets.car")
        let watchAssets = watchApp.appendingPathComponent("Assets.car")
        try Data([1]).write(to: iosAssets)
        try Data([2]).write(to: watchAssets)
        try writePNG(
            width: 120,
            height: 120,
            to: iosApp.appendingPathComponent("agentlimits60x60@2x.png")
        )
        try writePNG(
            width: 152,
            height: 152,
            to: iosApp.appendingPathComponent("agentlimits76x76@2x~ipad.png")
        )

        let iosAssetInfo = URL(
            fileURLWithPath: iosAssets.path + ".assetinfo.json"
        )
        let watchAssetInfo = URL(
            fileURLWithPath: watchAssets.path + ".assetinfo.json"
        )
        try writeAssetCatalogInfo(
            platform: "ios",
            idioms: ["phone", "pad"],
            to: iosAssetInfo
        )
        try writeAssetCatalogInfo(
            platform: "watch",
            idioms: ["watch"],
            to: watchAssetInfo
        )

        let assetutil = directory.appendingPathComponent("assetutil")
        try """
        #!/bin/bash
        set -euo pipefail
        if [[ $# -ne 2 || "$1" != "--info" ]]; then
            exit 64
        fi
        /bin/cat "$2.assetinfo.json"
        """.write(to: assetutil, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: assetutil.path
        )

        return ProductFixture(
            iosApp: iosApp,
            iosInfo: iosInfo,
            watchInfo: watchInfo,
            iosPrivacy: iosPrivacy,
            watchPrivacy: watchPrivacy,
            iosAssetInfo: iosAssetInfo,
            watchAssetInfo: watchAssetInfo,
            assetutil: assetutil
        )
    }

    private func writePNG(width: Int, height: Int, to url: URL) throws {
        let context = try XCTUnwrap(
            CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            )
        )
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try XCTUnwrap(context.makeImage())
        let destination = try XCTUnwrap(
            CGImageDestinationCreateWithURL(
                url as CFURL,
                UTType.png.identifier as CFString,
                1,
                nil
            )
        )
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw NSError(
                domain: "AppStoreProductValidationTests",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Could not write PNG fixture"]
            )
        }
    }

    private func setPermissions(_ permissions: Int, for url: URL) throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: permissions],
            ofItemAtPath: url.path
        )
    }

    private func writeAssetCatalogInfo(
        platform: String,
        idioms: [String],
        to url: URL
    ) throws {
        var entries: [[String: Any]] = [["Platform": platform]]
        entries.append(contentsOf: idioms.map { idiom in
            [
                "AssetType": "Icon Image",
                "Name": "agentlimits",
                "Idiom": idiom,
                "PixelWidth": 1024,
                "PixelHeight": 1024,
                "Opaque": true
            ]
        })
        let data = try JSONSerialization.data(
            withJSONObject: entries,
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: url)
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
        scratch: URL,
        environment: [String: String] = [:]
    ) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [
            "-c",
            #"set -euo pipefail; source "$1"; app_store_validate_product_with_assetutil "$2" "$3" "$4" "$5" "$6""#,
            "app-store-product-validation-test",
            repositoryRoot.appendingPathComponent(
                "Scripts/app-store-product-validation.sh"
            ).path,
            fixture.iosApp.path,
            "1.1.6",
            "16",
            scratch.path,
            fixture.assetutil.path
        ]
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

    private func runValidationHelper(
        _ helper: String,
        arguments: [String]
    ) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [
            "-c",
            #"set -euo pipefail; source "$1"; helper="$2"; shift 2; "$helper" "$@""#,
            "app-store-product-validation-helper-test",
            repositoryRoot.appendingPathComponent(
                "Scripts/app-store-product-validation.sh"
            ).path,
            helper
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
}
