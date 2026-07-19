import Foundation
import XCTest
@testable import AgentLimits

final class UpdateSettingsLinksTests: XCTestCase {
    func testPrivacyPolicyUsesCanonicalPublicHTTPSURL() {
        XCTAssertEqual(
            UpdateSettingsLinks.privacyPolicy.absoluteString,
            "https://github.com/JimBoHa/AgentLimits-forked/blob/main/PRIVACY.md"
        )
        XCTAssertEqual(UpdateSettingsLinks.privacyPolicy.scheme, "https")
        XCTAssertEqual(UpdateSettingsLinks.privacyPolicy.host, "github.com")
    }

    func testPrivacyPolicyLabelExistsInEveryLocalization() throws {
        let localizations = [
            "de", "en", "es", "fr", "it", "ja", "ko", "nl", "pl",
            "pt-BR", "tr", "uk", "zh-Hans", "zh-Hant"
        ]

        for localization in localizations {
            let path = try XCTUnwrap(
                Bundle.main.path(
                    forResource: localization,
                    ofType: "lproj"
                ),
                "Missing localization bundle for \(localization)"
            )
            let bundle = try XCTUnwrap(Bundle(path: path))
            let value = bundle.localizedString(
                forKey: "update.privacyPolicy",
                value: nil,
                table: nil
            )
            XCTAssertNotEqual(value, "update.privacyPolicy", localization)
            XCTAssertFalse(value.isEmpty, localization)
        }
    }
}
