#!/bin/bash

set -euo pipefail

usage() {
    echo "Usage: $0 OUTPUT_DIRECTORY {app-store-connect|release-testing}" >&2
    echo "Archives iOS with its embedded Watch app, then exports a signed IPA." >&2
}

if [[ $# -ne 2 ]]; then
    usage
    exit 64
fi

output_dir="$1"
distribution_method="$2"

case "$distribution_method" in
    app-store-connect)
        export_options="ExportOptions-AppStoreConnect.plist"
        ;;
    release-testing)
        export_options="ExportOptions-ReleaseTesting.plist"
        ;;
    *)
        usage
        exit 64
        ;;
esac

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
project_root="$(cd "$script_dir/.." && pwd)"
developer_dir="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
local_config="$project_root/Configurations/DevelopmentTeam.local.xcconfig"
validated_development_team=""
validated_development_team_config_hash=""
# shellcheck disable=SC1091
source "$script_dir/signing-config.sh"

if [[ ! -x "$developer_dir/usr/bin/xcodebuild" ]]; then
    echo "Xcode not found at $developer_dir" >&2
    exit 69
fi
if [[ ! -e "$local_config" && ! -L "$local_config" ]]; then
    echo "Missing $local_config" >&2
    echo "Copy the .example file and set your Apple Developer Team ID." >&2
    exit 78
fi
validate_development_team_config "$local_config" || exit $?
team_id="$validated_development_team"
local_config_hash="$validated_development_team_config_hash"
if [[ -e "$output_dir" ]]; then
    echo "Refusing to overwrite existing path: $output_dir" >&2
    exit 73
fi
if [[ -n "$(git -C "$project_root" status --porcelain \
        --untracked-files=normal)" ]]; then
    echo "Refusing a signed export from a dirty Git working tree" >&2
    exit 65
fi
source_commit="$(git -C "$project_root" rev-parse HEAD)"

verify_source_unchanged() {
    verify_development_team_config_unchanged \
        "$local_config" "$team_id" "$local_config_hash" || exit $?
    if [[ "$(git -C "$project_root" rev-parse HEAD)" != "$source_commit" \
        || -n "$(git -C "$project_root" status --porcelain \
            --untracked-files=normal)" ]]; then
        echo "Source changed while building; discard this export" >&2
        exit 65
    fi
}

mkdir -p "$output_dir"
output_dir="$(cd "$output_dir" && pwd)"
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/AgentLimits-ios-export.XXXXXX")"

cleanup() {
    if [[ -n "${work_dir:-}" && -d "$work_dir" \
        && "$work_dir" == *"/AgentLimits-ios-export."* ]]; then
        rm -rf "$work_dir"
    fi
}
trap cleanup EXIT

export DEVELOPER_DIR="$developer_dir"

build_root="$work_dir/source"
mkdir -p "$build_root"
git -C "$project_root" archive --format=tar "$source_commit" \
    | tar -xf - -C "$build_root"
snapshot_config="$build_root/Configurations/DevelopmentTeam.local.xcconfig"
printf 'DEVELOPMENT_TEAM = %s\n' "$team_id" >"$snapshot_config"
chmod 600 "$snapshot_config"
verify_source_unchanged

settings="$(xcodebuild \
    -project "$build_root/AgentLimits.xcodeproj" \
    -scheme AgentLimitsiOS \
    -configuration Release \
    -showBuildSettings 2>/dev/null)"
resolved_team_id="$(printf '%s\n' "$settings" \
    | sed -n 's/^[[:space:]]*DEVELOPMENT_TEAM = //p' \
    | head -1)"

if [[ "$resolved_team_id" != "$team_id" ]]; then
    echo "Resolved Apple Team does not match the validated local config" >&2
    exit 78
fi
verify_source_unchanged

archive="$output_dir/AgentLimits-iOS-watchOS.xcarchive"
export_dir="$output_dir/export"
archive_log="$output_dir/archive.log"
export_log="$output_dir/export.log"

echo "Archiving signed iOS and embedded watchOS apps for team $team_id..."
if ! xcodebuild archive \
    -allowProvisioningUpdates \
    -project "$build_root/AgentLimits.xcodeproj" \
    -scheme AgentLimitsiOS \
    -configuration Release \
    -destination 'generic/platform=iOS' \
    -archivePath "$archive" \
    SWIFT_TREAT_WARNINGS_AS_ERRORS=YES \
    GCC_TREAT_WARNINGS_AS_ERRORS=YES \
    >"$archive_log" 2>&1; then
    tail -120 "$archive_log" >&2
    exit 1
fi
verify_source_unchanged

archive_team="$(plutil -extract ApplicationProperties.Team raw \
    "$archive/Info.plist" 2>/dev/null || true)"
archive_identity="$(plutil -extract ApplicationProperties.SigningIdentity raw \
    "$archive/Info.plist" 2>/dev/null || true)"
if [[ "$archive_team" != "$team_id" || -z "$archive_identity" ]]; then
    echo "Archive is missing the expected Team or signing identity" >&2
    exit 1
fi

mkdir -p "$export_dir"
echo "Exporting with method $distribution_method..."
if ! xcodebuild -exportArchive \
    -allowProvisioningUpdates \
    -archivePath "$archive" \
    -exportPath "$export_dir" \
    -exportOptionsPlist "$build_root/Distribution/$export_options" \
    >"$export_log" 2>&1; then
    tail -120 "$export_log" >&2
    exit 1
fi
verify_source_unchanged

ipa="$(find "$export_dir" -maxdepth 1 -type f -name '*.ipa' -print -quit)"
if [[ -z "$ipa" ]]; then
    echo "Xcode export produced no IPA" >&2
    exit 1
fi

verification_root="$work_dir/ipa"
mkdir -p "$verification_root"
unzip -q "$ipa" -d "$verification_root"
ios_app="$(find "$verification_root/Payload" -maxdepth 1 -type d -name '*.app' -print -quit)"
watch_app="$ios_app/Watch/AgentLimitsWatch.app"

if [[ ! -d "$watch_app" ]]; then
    echo "Exported IPA is missing its embedded Watch app" >&2
    exit 1
fi

for required_path in \
    "$ios_app/PrivacyInfo.xcprivacy" \
    "$ios_app/LICENSE" \
    "$ios_app/embedded.mobileprovision" \
    "$watch_app/PrivacyInfo.xcprivacy" \
    "$watch_app/LICENSE" \
    "$watch_app/embedded.mobileprovision"; do
    if [[ ! -e "$required_path" ]]; then
        echo "Exported IPA is missing required content: $required_path" >&2
        exit 1
    fi
done

plutil -lint "$ios_app/PrivacyInfo.xcprivacy" >/dev/null
plutil -lint "$watch_app/PrivacyInfo.xcprivacy" >/dev/null

codesign --verify --deep --strict --verbose=4 "$ios_app"
codesign --verify --deep --strict --verbose=4 "$watch_app"

verify_distribution_signature() {
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
        | grep -q '^Authority=Apple Distribution:'; then
        echo "$label is not signed by Apple Distribution" >&2
        exit 1
    fi
}

validate_profile() {
    local profile="$1"
    local bundle_id="$2"
    local label="$3"
    local decoded="$work_dir/$label-profile.plist"
    local profile_team
    local application_id
    local provisions_all_devices

    security cms -D -i "$profile" >"$decoded"
    plutil -lint "$decoded" >/dev/null
    profile_team="$(plutil -extract TeamIdentifier.0 raw "$decoded")"
    application_id="$(plutil -extract Entitlements.application-identifier \
        raw "$decoded")"
    provisions_all_devices="$(plutil -extract ProvisionsAllDevices raw \
        "$decoded" 2>/dev/null || true)"

    if [[ "$profile_team" != "$team_id" \
        || "$application_id" != "$team_id.$bundle_id" ]]; then
        echo "$label provisioning profile has unexpected Team or app ID" >&2
        exit 1
    fi
    if [[ "$(plutil -extract Entitlements.get-task-allow raw "$decoded" \
            2>/dev/null || true)" == "true" ]]; then
        echo "$label provisioning profile enables get-task-allow" >&2
        exit 1
    fi
    if ! plutil -extract ExpirationDate raw "$decoded" >/dev/null; then
        echo "$label provisioning profile has no expiration date" >&2
        exit 1
    fi

    case "$distribution_method" in
        app-store-connect)
            if plutil -extract ProvisionedDevices xml1 -o - "$decoded" \
                    >/dev/null 2>&1 \
                || [[ "$provisions_all_devices" == "true" ]]; then
                echo "$label profile is not an App Store profile" >&2
                exit 1
            fi
            ;;
        release-testing)
            if ! plutil -extract ProvisionedDevices xml1 -o - "$decoded" \
                    >/dev/null 2>&1; then
                echo "$label profile has no registered test devices" >&2
                exit 1
            fi
            ;;
    esac
}

verify_distribution_signature "$ios_app" "iOS app"
verify_distribution_signature "$watch_app" "Watch app"

ios_info="$ios_app/Info.plist"
watch_info="$watch_app/Info.plist"
version="$(plutil -extract CFBundleShortVersionString raw "$ios_info")"
build="$(plutil -extract CFBundleVersion raw "$ios_info")"
ios_executable="$(plutil -extract CFBundleExecutable raw "$ios_info")"
watch_executable="$(plutil -extract CFBundleExecutable raw "$watch_info")"
ios_archs="$(lipo -archs "$ios_app/$ios_executable")"
watch_archs="$(lipo -archs "$watch_app/$watch_executable")"

if [[ "$(plutil -extract CFBundleIdentifier raw "$ios_info")" \
        != "com.jimboha.agentlimits.ios" \
    || "$(plutil -extract CFBundleIdentifier raw "$watch_info")" \
        != "com.jimboha.agentlimits.ios.watchkitapp" \
    || "$(plutil -extract WKCompanionAppBundleIdentifier raw "$watch_info")" \
        != "com.jimboha.agentlimits.ios" \
    || "$(plutil -extract CFBundleShortVersionString raw "$watch_info")" \
        != "$version" \
    || "$(plutil -extract CFBundleVersion raw "$watch_info")" != "$build" ]]; then
    echo "Exported iOS/watchOS identifiers or versions are inconsistent" >&2
    exit 1
fi
if [[ " $ios_archs " != *" arm64 "* ]]; then
    echo "Exported iOS app lacks arm64: $ios_archs" >&2
    exit 1
fi
if [[ " $watch_archs " != *" arm64_32 "* \
    || " $watch_archs " != *" arm64 "* ]]; then
    echo "Exported Watch app lacks device architectures: $watch_archs" >&2
    exit 1
fi
if [[ "$(plutil -extract WKRunsIndependentlyOfCompanionApp raw \
        "$watch_info")" != "false" ]]; then
    echo "Exported Watch app unexpectedly declares independent distribution" >&2
    exit 1
fi

validate_profile \
    "$ios_app/embedded.mobileprovision" \
    "com.jimboha.agentlimits.ios" \
    ios
validate_profile \
    "$watch_app/embedded.mobileprovision" \
    "com.jimboha.agentlimits.ios.watchkitapp" \
    watch

ios_entitlements="$work_dir/ios-entitlements.plist"
watch_entitlements="$work_dir/watch-entitlements.plist"
codesign -d --entitlements "$ios_entitlements" --xml "$ios_app" 2>/dev/null
codesign -d --entitlements "$watch_entitlements" --xml "$watch_app" 2>/dev/null
plutil -lint "$ios_entitlements" >/dev/null
plutil -lint "$watch_entitlements" >/dev/null

verify_distribution_entitlements() {
    local entitlements="$1"
    local bundle_id="$2"
    local label="$3"
    local application_id
    local entitlement_team

    application_id="$(plutil -extract application-identifier raw \
        "$entitlements" 2>/dev/null || true)"
    entitlement_team="$(plutil -extract \
        'com\.apple\.developer\.team-identifier' raw \
        "$entitlements" 2>/dev/null || true)"
    if [[ "$application_id" != "$team_id.$bundle_id" \
        || "$entitlement_team" != "$team_id" ]]; then
        echo "$label has unexpected signed identifier entitlements" >&2
        exit 1
    fi
    if [[ "$(plutil -extract get-task-allow raw "$entitlements" 2>/dev/null \
            || true)" == "true" ]]; then
        echo "$label distribution entitlements enable get-task-allow" >&2
        exit 1
    fi
}

verify_distribution_entitlements \
    "$ios_entitlements" \
    "com.jimboha.agentlimits.ios" \
    "iOS app"
verify_distribution_entitlements \
    "$watch_entitlements" \
    "com.jimboha.agentlimits.ios.watchkitapp" \
    "Watch app"

ipa_name="AgentLimitsForked-$version-$build-$distribution_method.ipa"
mv "$ipa" "$output_dir/$ipa_name"
rm -rf "$export_dir"

(
    verify_source_unchanged
    cd "$output_dir"
    shasum -a 256 "$ipa_name" > SHA256SUMS
)

cat >"$output_dir/BUILD-METADATA.txt" <<EOF
AgentLimits Forked $version ($build)
Distribution method: $distribution_method
Team ID: $team_id
Git commit: $source_commit
Signing config SHA-256: $local_config_hash
Build source: clean git archive with generated Team-only config
Xcode: $(xcodebuild -version | tr '\n' ' ')
Watch app: embedded in iOS IPA
iOS architectures: $ios_archs
watchOS architectures: $watch_archs
Signing verification: passed
EOF

echo "Signed IPA created: $output_dir/$ipa_name"
echo "The Apple Watch installer is embedded in that IPA."
