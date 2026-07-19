#!/bin/bash

set -euo pipefail

usage() {
    echo "Usage: $0 OUTPUT_DIRECTORY NOTARY_KEYCHAIN_PROFILE \"DEVELOPER_ID_INSTALLER_IDENTITY\"" >&2
    echo "Example installer identity: Developer ID Installer: Example Corp (ABCDE12345)" >&2
}

if [[ $# -ne 3 ]]; then
    usage
    exit 64
fi

output_dir="$1"
notary_profile="$2"
installer_identity="$3"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
project_root="$(cd "$script_dir/.." && pwd)"
developer_dir="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
local_config="$project_root/Configurations/DevelopmentTeam.local.xcconfig"

if [[ ! -x "$developer_dir/usr/bin/xcodebuild" ]]; then
    echo "Xcode not found at $developer_dir" >&2
    exit 69
fi
if [[ ! -f "$local_config" ]]; then
    echo "Missing $local_config" >&2
    echo "Copy the .example file and set your Apple Developer Team ID." >&2
    exit 78
fi
if [[ -e "$output_dir" ]]; then
    echo "Refusing to overwrite existing path: $output_dir" >&2
    exit 73
fi
if [[ -n "$(git -C "$project_root" status --porcelain \
        --untracked-files=normal)" ]]; then
    echo "Refusing a signed package from a dirty Git working tree" >&2
    exit 65
fi
source_commit="$(git -C "$project_root" rev-parse HEAD)"

verify_source_unchanged() {
    if [[ "$(git -C "$project_root" rev-parse HEAD)" != "$source_commit" \
        || -n "$(git -C "$project_root" status --porcelain \
            --untracked-files=normal)" ]]; then
        echo "Source changed while building; discard these packages" >&2
        exit 65
    fi
}

mkdir -p "$output_dir"
output_dir="$(cd "$output_dir" && pwd)"
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/AgentLimits-macos-package.XXXXXX")"

cleanup() {
    if [[ -n "${work_dir:-}" && -d "$work_dir" \
        && "$work_dir" == *"/AgentLimits-macos-package."* ]]; then
        rm -rf "$work_dir"
    fi
}
trap cleanup EXIT

export DEVELOPER_DIR="$developer_dir"

settings="$(xcodebuild \
    -project "$project_root/AgentLimits.xcodeproj" \
    -scheme AgentLimits \
    -configuration Release \
    -showBuildSettings 2>/dev/null)"
team_id="$(printf '%s\n' "$settings" \
    | sed -n 's/^[[:space:]]*DEVELOPMENT_TEAM = //p' \
    | head -1)"

if [[ -z "$team_id" ]]; then
    echo "DEVELOPMENT_TEAM is empty after resolving Xcode settings" >&2
    exit 78
fi
if [[ ! "$team_id" =~ ^[A-Z0-9]{10}$ ]]; then
    echo "Unexpected Apple Team ID format: $team_id" >&2
    exit 78
fi
if [[ ! "$installer_identity" =~ ^Developer\ ID\ Installer:\ .+\ \(${team_id}\)$ ]]; then
    echo "Installer identity does not belong to Team $team_id" >&2
    exit 78
fi
if ! security find-identity -v -p basic \
        | grep -Fq "\"$installer_identity\""; then
    echo "Installer identity and private key are not available in Keychain" >&2
    exit 78
fi

archive="$output_dir/AgentLimits-macOS.xcarchive"
archive_log="$output_dir/archive.log"
export_log="$output_dir/export.log"
export_dir="$work_dir/export"

echo "Archiving macOS app for team $team_id..."
if ! xcodebuild archive \
    -allowProvisioningUpdates \
    -project "$project_root/AgentLimits.xcodeproj" \
    -scheme AgentLimits \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    -archivePath "$archive" \
    SWIFT_TREAT_WARNINGS_AS_ERRORS=YES \
    GCC_TREAT_WARNINGS_AS_ERRORS=YES \
    >"$archive_log" 2>&1; then
    tail -120 "$archive_log" >&2
    exit 1
fi

archive_team="$(plutil -extract ApplicationProperties.Team raw \
    "$archive/Info.plist" 2>/dev/null || true)"
archive_identity="$(plutil -extract ApplicationProperties.SigningIdentity raw \
    "$archive/Info.plist" 2>/dev/null || true)"
if [[ "$archive_team" != "$team_id" || -z "$archive_identity" ]]; then
    echo "Archive is missing the expected Team or signing identity" >&2
    exit 1
fi

mkdir -p "$export_dir"
echo "Exporting with Developer ID..."
if ! xcodebuild -exportArchive \
    -allowProvisioningUpdates \
    -archivePath "$archive" \
    -exportPath "$export_dir" \
    -exportOptionsPlist \
        "$project_root/Distribution/ExportOptions-DeveloperID.plist" \
    >"$export_log" 2>&1; then
    tail -120 "$export_log" >&2
    exit 1
fi
verify_source_unchanged

exported_app="$(find "$export_dir" -maxdepth 1 -type d -name '*.app' -print -quit)"
if [[ -z "$exported_app" ]]; then
    echo "Developer ID export produced no app bundle" >&2
    exit 1
fi

app="$output_dir/AgentLimitsForked.app"
ditto "$exported_app" "$app"
widget="$app/Contents/PlugIns/AgentLimitsWidgetExtension.appex"

for required_path in \
    "$widget" \
    "$app/Contents/Frameworks/Sparkle.framework" \
    "$app/Contents/Resources/PrivacyInfo.xcprivacy" \
    "$app/Contents/Resources/LICENSE" \
    "$app/Contents/Resources/THIRD_PARTY_NOTICES.md" \
    "$app/Contents/embedded.provisionprofile" \
    "$widget/Contents/Resources/PrivacyInfo.xcprivacy" \
    "$widget/Contents/embedded.provisionprofile"; do
    if [[ ! -e "$required_path" ]]; then
        echo "Export is missing required content: $required_path" >&2
        exit 1
    fi
done

plutil -lint "$app/Contents/Resources/PrivacyInfo.xcprivacy" >/dev/null
plutil -lint "$widget/Contents/Resources/PrivacyInfo.xcprivacy" >/dev/null

codesign --verify --deep --strict --verbose=4 "$app"
codesign --verify --strict --verbose=4 "$widget"

verify_developer_id_signature() {
    local bundle="$1"
    local label="$2"
    local details
    local signed_team

    details="$(codesign -dvvv "$bundle" 2>&1)"
    signed_team="$(printf '%s\n' "$details" \
        | sed -n 's/^TeamIdentifier=//p' | head -1)"
    if [[ "$signed_team" != "$team_id" ]]; then
        echo "$label signature has unexpected Team: $signed_team" >&2
        exit 1
    fi
    if ! printf '%s\n' "$details" \
        | grep -q '^Authority=Developer ID Application:'; then
        echo "$label is not signed by Developer ID Application" >&2
        exit 1
    fi
    if ! printf '%s\n' "$details" | grep -q '^CodeDirectory .*runtime'; then
        echo "$label signature lacks hardened runtime" >&2
        exit 1
    fi
}

validate_developer_id_profile() {
    local profile="$1"
    local bundle_id="$2"
    local label="$3"
    local decoded="$work_dir/$label-profile.plist"
    local profile_team
    local application_id

    security cms -D -i "$profile" >"$decoded"
    plutil -lint "$decoded" >/dev/null
    profile_team="$(plutil -extract TeamIdentifier.0 raw "$decoded")"
    application_id="$(plutil -extract \
        'Entitlements.com\.apple\.application-identifier' raw "$decoded" \
        2>/dev/null \
        || plutil -extract Entitlements.application-identifier raw "$decoded")"

    if [[ "$profile_team" != "$team_id" \
        || "$application_id" != "$team_id.$bundle_id" ]]; then
        echo "$label profile has unexpected Team or app ID" >&2
        exit 1
    fi
    if [[ "$(plutil -extract \
            'Entitlements.com\.apple\.security\.application-groups' raw \
            "$decoded" 2>/dev/null || true)" != "1" \
        || "$(plutil -extract \
            'Entitlements.com\.apple\.security\.application-groups.0' raw \
            "$decoded" 2>/dev/null || true)" \
            != "group.com.jimboha.agentlimits.macos" ]]; then
        echo "$label profile lacks the fork App Group" >&2
        exit 1
    fi
    if [[ "$(plutil -extract Entitlements.get-task-allow raw "$decoded" \
            2>/dev/null || true)" == "true" ]]; then
        echo "$label profile enables get-task-allow" >&2
        exit 1
    fi
    if ! plutil -extract ExpirationDate raw "$decoded" >/dev/null; then
        echo "$label profile has no expiration date" >&2
        exit 1
    fi
}

verify_developer_id_signature "$app" "macOS app"
verify_developer_id_signature "$widget" "macOS widget"
validate_developer_id_profile \
    "$app/Contents/embedded.provisionprofile" \
    "com.jimboha.agentlimits.macos" \
    macos
validate_developer_id_profile \
    "$widget/Contents/embedded.provisionprofile" \
    "com.jimboha.agentlimits.macos.widget" \
    widget

app_info="$app/Contents/Info.plist"
version="$(plutil -extract CFBundleShortVersionString raw "$app_info")"
build="$(plutil -extract CFBundleVersion raw "$app_info")"
executable="$(plutil -extract CFBundleExecutable raw "$app_info")"
architectures="$(lipo -archs "$app/Contents/MacOS/$executable")"
widget_info="$widget/Contents/Info.plist"
widget_executable="$(plutil -extract CFBundleExecutable raw "$widget_info")"
widget_architectures="$(lipo -archs \
    "$widget/Contents/MacOS/$widget_executable")"

if [[ "$(plutil -extract CFBundleIdentifier raw "$app_info")" \
        != "com.jimboha.agentlimits.macos" \
    || "$(plutil -extract CFBundleIdentifier raw "$widget_info")" \
        != "com.jimboha.agentlimits.macos.widget" ]]; then
    echo "Developer ID export has unexpected bundle identifiers" >&2
    exit 1
fi

if [[ " $architectures " != *" arm64 "* \
    || " $architectures " != *" x86_64 "* ]]; then
    echo "Developer ID app is not universal: $architectures" >&2
    exit 1
fi
if [[ " $widget_architectures " != *" arm64 "* \
    || " $widget_architectures " != *" x86_64 "* ]]; then
    echo "Developer ID widget is not universal: $widget_architectures" >&2
    exit 1
fi

entitlements="$work_dir/app-entitlements.plist"
codesign -d --entitlements "$entitlements" --xml "$app" 2>/dev/null
plutil -lint "$entitlements" >/dev/null
if [[ "$(plutil -extract 'com\.apple\.application-identifier' raw \
        "$entitlements" 2>/dev/null || true)" \
        != "$team_id.com.jimboha.agentlimits.macos" \
    || "$(plutil -extract 'com\.apple\.developer\.team-identifier' raw \
        "$entitlements" 2>/dev/null || true)" != "$team_id" ]]; then
    echo "Developer ID app has unexpected identifier entitlements" >&2
    exit 1
fi
if [[ "$(plutil -extract get-task-allow raw "$entitlements" 2>/dev/null \
        || true)" == "true" ]]; then
    echo "Developer ID app contains get-task-allow" >&2
    exit 1
fi

if [[ "$(plutil -extract 'com\.apple\.security\.application-groups' raw \
        "$entitlements" 2>/dev/null || true)" != "1" \
    || "$(plutil -extract \
        'com\.apple\.security\.application-groups.0' raw \
        "$entitlements" 2>/dev/null || true)" \
        != "group.com.jimboha.agentlimits.macos" ]]; then
    echo "Developer ID app is missing the fork App Group entitlement" >&2
    exit 1
fi

widget_entitlements="$work_dir/widget-entitlements.plist"
codesign -d --entitlements "$widget_entitlements" --xml "$widget" 2>/dev/null
plutil -lint "$widget_entitlements" >/dev/null
if [[ "$(plutil -extract 'com\.apple\.application-identifier' raw \
        "$widget_entitlements" 2>/dev/null || true)" \
        != "$team_id.com.jimboha.agentlimits.macos.widget" \
    || "$(plutil -extract 'com\.apple\.developer\.team-identifier' raw \
        "$widget_entitlements" 2>/dev/null || true)" != "$team_id" ]]; then
    echo "Widget has unexpected identifier entitlements" >&2
    exit 1
fi
if [[ "$(plutil -extract 'com\.apple\.security\.app-sandbox' raw \
        "$widget_entitlements" 2>/dev/null || true)" != "true" ]]; then
    echo "Widget distribution signature lacks App Sandbox" >&2
    exit 1
fi
if [[ "$(plutil -extract 'com\.apple\.security\.application-groups' raw \
        "$widget_entitlements" 2>/dev/null || true)" != "1" \
    || "$(plutil -extract \
        'com\.apple\.security\.application-groups.0' raw \
        "$widget_entitlements" 2>/dev/null || true)" \
        != "group.com.jimboha.agentlimits.macos" ]]; then
    echo "Widget distribution signature lacks the fork App Group" >&2
    exit 1
fi

submit_notary() {
    local artifact="$1"
    local label="$2"
    local result="$output_dir/notary-$label.plist"
    local log="$output_dir/notary-$label-log.json"
    local submission_id
    local status
    local submit_exit=0

    xcrun notarytool submit "$artifact" \
        --keychain-profile "$notary_profile" \
        --wait \
        --timeout 60m \
        --output-format plist \
        >"$result" \
        || submit_exit=$?
    if ! plutil -lint "$result" >/dev/null 2>&1; then
        echo "$label notarization returned no valid result" >&2
        exit 1
    fi
    submission_id="$(plutil -extract id raw "$result")"
    status="$(plutil -extract status raw "$result")"
    xcrun notarytool log "$submission_id" \
        --keychain-profile "$notary_profile" \
        "$log" \
        >/dev/null

    if [[ $submit_exit -ne 0 || "$status" != "Accepted" ]]; then
        echo "Apple did not accept $label notarization; inspect $log" >&2
        exit 1
    fi
}

base_name="AgentLimitsForked-$version-$build-macOS"
temporary_notary_zip="$work_dir/$base_name-notary.zip"
ditto -c -k --sequesterRsrc --keepParent "$app" "$temporary_notary_zip"

echo "Notarizing the app..."
submit_notary "$temporary_notary_zip" app
xcrun stapler staple "$app"
xcrun stapler validate "$app"

zip="$output_dir/$base_name.zip"
dmg="$output_dir/$base_name.dmg"
pkg="$output_dir/$base_name.pkg"
ditto -c -k --sequesterRsrc --keepParent "$app" "$zip"

echo "Building and signing installer package..."
productbuild \
    --component "$app" /Applications \
    --sign "$installer_identity" \
    "$pkg" \
    >/dev/null
package_signature="$(pkgutil --check-signature "$pkg" 2>&1)"
if ! printf '%s\n' "$package_signature" \
        | grep -Fq "$installer_identity"; then
    echo "PKG has an unexpected installer signature" >&2
    exit 1
fi

echo "Notarizing installer package..."
submit_notary "$pkg" pkg
xcrun stapler staple "$pkg"
xcrun stapler validate "$pkg"

dmg_root="$work_dir/dmg-root"
mkdir -p "$dmg_root"
ditto "$app" "$dmg_root/AgentLimitsForked.app"
ln -s /Applications "$dmg_root/Applications"
hdiutil create \
    -quiet \
    -volname "AgentLimits Forked" \
    -srcfolder "$dmg_root" \
    -format UDZO \
    -fs HFS+ \
    "$dmg"
hdiutil verify "$dmg" >/dev/null

echo "Notarizing disk image..."
submit_notary "$dmg" dmg
xcrun stapler staple "$dmg"
xcrun stapler validate "$dmg"

codesign --verify --deep --strict --verbose=4 "$app"
pkgutil --check-signature "$pkg"
spctl --assess --type execute --verbose=4 "$app"
spctl --assess --type install --verbose=4 "$pkg"
spctl --assess --type open \
    --context context:primary-signature \
    --verbose=4 "$dmg"

(
    verify_source_unchanged
    cd "$output_dir"
    shasum -a 256 \
        "$(basename "$zip")" \
        "$(basename "$dmg")" \
        "$(basename "$pkg")" \
        > SHA256SUMS
)

cat >"$output_dir/BUILD-METADATA.txt" <<EOF
AgentLimits Forked $version ($build)
Team ID: $team_id
Git commit: $source_commit
Xcode: $(xcodebuild -version | tr '\n' ' ')
macOS architectures: $architectures
macOS widget architectures: $widget_architectures
Developer ID verification: passed
Notarization and stapling: passed for app, PKG, and DMG
EOF

echo "Signed and notarized macOS artifacts created at: $output_dir"
