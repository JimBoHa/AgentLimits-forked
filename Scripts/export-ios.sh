#!/bin/bash -p
# shellcheck disable=SC2154

agentlimits_release_entrypoint="${BASH_SOURCE[0]}"
if [[ "$agentlimits_release_entrypoint" != /* ]]; then
    agentlimits_release_entrypoint="$PWD/$agentlimits_release_entrypoint"
fi
if ! agentlimits_release_home="$(
        builtin unset HOME CDPATH
        builtin cd ~ 2>/dev/null || exit 1
        builtin pwd -P
    )" \
    || [[ "$agentlimits_release_home" != /* \
        || "$agentlimits_release_home" == / \
        || "$agentlimits_release_home" == *$'\n'* \
        || ! -d "$agentlimits_release_home" ]]; then
    echo "Could not derive the canonical passwd home directory" >&2
    exit 70
fi
if [[ "${AGENTLIMITS_RELEASE_ENV_PID:-}" != "$$" ]]; then
    exec /usr/bin/env -i \
        AGENTLIMITS_RELEASE_ENV_PID="$$" \
        DEVELOPER_DIR="${DEVELOPER_DIR:-}" \
        HOME="$agentlimits_release_home" \
        LANG=C \
        LC_ALL=C \
        PATH=/usr/bin:/bin:/usr/sbin:/sbin \
        /bin/bash -p "$agentlimits_release_entrypoint" "$@"
fi

agentlimits_release_environment_error=""
while IFS= read -r agentlimits_release_environment_entry; do
    agentlimits_release_environment_name="${agentlimits_release_environment_entry%%=*}"
    case "$agentlimits_release_environment_name" in
        BASH_FUNC_*)
            agentlimits_release_environment_error="inherited shell function"
            break
            ;;
        AGENTLIMITS_RELEASE_ENV_PID|DEVELOPER_DIR|HOME|LANG|LC_ALL|PATH|PWD|SHLVL|_)
            ;;
        *)
            agentlimits_release_environment_error="unexpected variable: $agentlimits_release_environment_name"
            break
            ;;
    esac
done < <(/usr/bin/env)
if [[ -z "$agentlimits_release_environment_error" ]]; then
    if [[ "${LANG:-}" != C \
        || "${LC_ALL:-}" != C \
        || "${HOME:-}" != "$agentlimits_release_home" \
        || "${PATH:-}" != /usr/bin:/bin:/usr/sbin:/sbin ]]; then
        agentlimits_release_environment_error="unexpected fixed variable value"
    fi
fi
if [[ -n "$agentlimits_release_environment_error" ]]; then
    printf 'Release environment was not sanitized (%s)\n' \
        "$agentlimits_release_environment_error" >&2
    exit 70
fi

set -euo pipefail

PATH="/usr/bin:/bin:/usr/sbin:/sbin"
export PATH
unset CDPATH

usage() {
    echo "Usage: $0 /ABSOLUTE/OUTPUT_DIRECTORY {app-store-connect|release-testing}" >&2
    echo "Archives iOS with its embedded Watch app, then exports a signed IPA." >&2
}

if [[ $# -ne 2 ]]; then
    usage
    exit 64
fi

requested_output="$1"
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

invoked_script="${BASH_SOURCE[0]}"
if [[ -L "$invoked_script" ]]; then
    echo "Refusing to run a signed release through a script symlink" >&2
    exit 64
fi
script_dir="$(cd "$(dirname "$invoked_script")" >/dev/null && pwd -P)"
project_root="$(cd "$script_dir/.." >/dev/null && pwd -P)"
developer_dir="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
local_config="$project_root/Configurations/DevelopmentTeam.local.xcconfig"
validated_development_team=""
validated_development_team_config_hash=""
# shellcheck disable=SC1091
source "$script_dir/signing-config.sh"
sanitize_release_git_environment
# shellcheck disable=SC1091
source "$script_dir/release-output.sh"
# shellcheck disable=SC1091
source "$script_dir/apple-toolchain.sh"

if [[ ! -x "$developer_dir/usr/bin/xcodebuild" ]]; then
    echo "Xcode not found at $developer_dir" >&2
    exit 69
fi
validate_apple_distribution_toolchain \
    "$developer_dir" iphoneos watchos || exit $?
developer_dir="$validated_apple_developer_dir"
if [[ ! -e "$local_config" && ! -L "$local_config" ]]; then
    echo "Missing $local_config" >&2
    echo "Copy the .example file and set your Apple Developer Team ID." >&2
    exit 78
fi
validate_development_team_config "$local_config" || exit $?
team_id="$validated_development_team"
local_config_hash="$validated_development_team_config_hash"
validate_release_output_request "$requested_output" "$project_root" || exit $?
output_parent="$validated_release_output_parent"
output_parent_identity="$validated_release_output_parent_identity"
output_name="$validated_release_output_name"
release_output_dir="$validated_release_output_directory"
source_commit="$(git -C "$project_root" rev-parse HEAD)"
if [[ -n "$(git -C "$project_root" status --porcelain \
        --untracked-files=normal)" ]]; then
    echo "Refusing a signed export from a dirty Git working tree" >&2
    exit 65
fi

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

work_dir=""
work_dir_identity=""
staging_parent=""
staging_parent_identity=""
staging_dir=""
staging_dir_identity=""
publication_lock=""
publication_lock_identity=""
atomic_publisher=""
atomic_publisher_identity=""
atomic_publisher_hash=""
derived_data=""

cleanup() {
    local exit_status=$?

    set +e
    cleanup_private_release_directory \
        "${staging_parent:-}" \
        "${staging_parent_identity:-}" \
        "$output_parent" \
        '^\.AgentLimits-ios-export-stage\.[A-Za-z0-9]{6}$' \
        || true
    cleanup_private_release_directory \
        "${work_dir:-}" \
        "${work_dir_identity:-}" \
        /private/tmp \
        '^AgentLimits-ios-export\.[A-Za-z0-9]{6}$' \
        || true
    if [[ -n "${publication_lock:-}" ]]; then
        release_release_publication_lock \
            "$publication_lock" \
            "$publication_lock_identity" \
            "$output_parent" \
            "$output_name" \
            || true
    fi
    return "$exit_status"
}
trap cleanup EXIT

acquire_release_publication_lock \
    "$output_parent" "$output_name" "$output_parent_identity" || exit $?
publication_lock="$validated_release_publication_lock"
publication_lock_identity="$validated_release_publication_lock_identity"
create_release_staging_directory \
    "$output_parent" \
    "$output_name" \
    "$output_parent_identity" \
    ios-export \
    || exit $?
staging_parent="$validated_release_staging_parent"
staging_parent_identity="$validated_release_staging_parent_identity"
staging_dir="$validated_release_staging_directory"
staging_dir_identity="$validated_release_staging_directory_identity"
output_dir="$staging_dir"
create_private_release_work_directory AgentLimits-ios-export || exit $?
work_dir="$validated_release_work_directory"
work_dir_identity="$validated_release_work_directory_identity"
configure_private_release_temporary_directory "$work_dir" || exit $?
derived_data="$work_dir/DerivedData"
mkdir -m 700 "$derived_data"
make_release_directory_private "$derived_data" || exit $?
verify_source_unchanged

export DEVELOPER_DIR="$developer_dir"

build_root="$work_dir/source"
mkdir -p "$build_root"
git -C "$project_root" archive --format=tar "$source_commit" \
    | tar -xf - -C "$build_root"
snapshot_config="$build_root/Configurations/DevelopmentTeam.local.xcconfig"
printf 'DEVELOPMENT_TEAM = %s\n' "$team_id" >"$snapshot_config"
chmod 600 "$snapshot_config"
prepare_xcode_signing_environment "$snapshot_config"
verify_source_unchanged
build_atomic_release_publisher \
    "$build_root/Scripts/atomic-release-publish.c" \
    "$work_dir/atomic-release-publish" \
    || exit $?
atomic_publisher="$validated_release_atomic_publisher"
atomic_publisher_identity="$validated_release_atomic_publisher_identity"
atomic_publisher_hash="$validated_release_atomic_publisher_hash"
verify_source_unchanged

settings="$(xcodebuild \
    -project "$build_root/AgentLimits.xcodeproj" \
    -scheme AgentLimitsiOS \
    -configuration Release \
    -onlyUsePackageVersionsFromResolvedFile \
    -derivedDataPath "$derived_data" \
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
    -onlyUsePackageVersionsFromResolvedFile \
    -derivedDataPath "$derived_data" \
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
archive_ios_info="$archive/Products/Applications/AgentLimits.app/Info.plist"
archive_watch_info="$archive/Products/Applications/AgentLimits.app/Watch/AgentLimitsWatch.app/Info.plist"
verify_apple_product_toolchain_metadata \
    "$archive_ios_info" iphoneos "Archived iOS app" || exit $?
verify_apple_product_toolchain_metadata \
    "$archive_watch_info" watchos "Archived Watch app" || exit $?

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
verify_apple_product_toolchain_metadata \
    "$ios_info" iphoneos "Exported iOS app" || exit $?
verify_apple_product_toolchain_metadata \
    "$watch_info" watchos "Exported Watch app" || exit $?
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

cat >"$output_dir/BUILD-METADATA.txt" <<EOF
AgentLimits Forked $version ($build)
Distribution method: $distribution_method
Team ID: $team_id
Git commit: $source_commit
Signing config SHA-256: $local_config_hash
Build source: clean git archive with generated Team-only config
Xcode: $validated_apple_xcode_version ($validated_apple_xcode_build), DTXcode $validated_apple_dtxcode
iOS/iPadOS SDK: $validated_apple_iphoneos_sdk_version ($validated_apple_iphoneos_sdk_build)
watchOS SDK: $validated_apple_watchos_sdk_version ($validated_apple_watchos_sdk_build)
Watch app: embedded in iOS IPA
iOS architectures: $ios_archs
watchOS architectures: $watch_archs
Signing verification: passed
EOF

(
    verify_source_unchanged
    cd "$output_dir"
    shasum -a 256 "$ipa_name" BUILD-METADATA.txt > SHA256SUMS
)

verify_source_unchanged
publish_staged_release_directory \
    "$staging_dir" \
    "$staging_dir_identity" \
    "$output_parent" \
    "$output_parent_identity" \
    "$output_name" \
    "$atomic_publisher" \
    "$atomic_publisher_identity" \
    "$atomic_publisher_hash" \
    || exit $?
staging_dir=""
rmdir "$staging_parent"
staging_parent=""
release_release_publication_lock \
    "$publication_lock" \
    "$publication_lock_identity" \
    "$output_parent" \
    "$output_name" \
    || exit $?
publication_lock=""

echo "Signed IPA created: $release_output_dir/$ipa_name"
echo "The Apple Watch installer is embedded in that IPA."
