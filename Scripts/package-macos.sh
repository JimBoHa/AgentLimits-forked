#!/bin/bash -p
# shellcheck disable=SC2154

release_environment_needs_reset=false
if [[ "${AGENTLIMITS_RELEASE_ENV_PID:-}" != "$$" ]]; then
    release_environment_needs_reset=true
else
    while IFS= read -r -d '' inherited_environment_entry; do
        case "$inherited_environment_entry" in
            "AGENTLIMITS_RELEASE_ENV_PID=$$" \
                | DEVELOPER_DIR=* \
                | "LANG=C" \
                | "LC_ALL=C" \
                | "PATH=/usr/bin:/bin:/usr/sbin:/sbin" \
                | PWD=* \
                | SHLVL=* \
                | _=*)
                ;;
            *)
                release_environment_needs_reset=true
                break
                ;;
        esac
    done < <(/usr/bin/env -0)
fi
if [[ "$release_environment_needs_reset" == "true" ]]; then
    exec /usr/bin/env -i \
        AGENTLIMITS_RELEASE_ENV_PID="$$" \
        DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}" \
        LANG=C \
        LC_ALL=C \
        PATH=/usr/bin:/bin:/usr/sbin:/sbin \
        /bin/bash -p "$0" "$@"
    echo "Could not create a sanitized release environment" >&2
    exit 70
fi
unset \
    AGENTLIMITS_RELEASE_ENV_PID \
    inherited_environment_entry \
    release_environment_needs_reset
HOME="$(cd ~ >/dev/null && pwd -P)" || exit 70
export HOME

set -euo pipefail

PATH="/usr/bin:/bin:/usr/sbin:/sbin"
export PATH
unset CDPATH

usage() {
    echo "Usage: $0 /ABSOLUTE/OUTPUT_DIRECTORY NOTARY_KEYCHAIN_PROFILE \"DEVELOPER_ID_INSTALLER_IDENTITY\"" >&2
    echo "Example installer identity: Developer ID Installer: Example Corp (ABCDE12345)" >&2
}

if [[ $# -ne 3 ]]; then
    usage
    exit 64
fi

requested_output="$1"
notary_profile="$2"
installer_identity="$3"
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
trusted_signing_config_directory="$(
    /usr/bin/mktemp -d /private/tmp/AgentLimits-signing-bootstrap.XXXXXX
)" || {
    echo "Could not create a trusted release bootstrap directory" >&2
    exit 65
}
trusted_signing_config="$trusted_signing_config_directory/signing-config.sh"
trusted_signing_config_metadata="$(
    /usr/bin/stat -f '%u %Lp' "$trusted_signing_config_directory" 2>/dev/null
)" || {
    /bin/rmdir "$trusted_signing_config_directory" 2>/dev/null || true
    echo "Could not validate the trusted release bootstrap directory" >&2
    exit 65
}
if [[ ! "$trusted_signing_config_directory" =~ ^/private/tmp/AgentLimits-signing-bootstrap\.[A-Za-z0-9]{6}$ \
    || -L "$trusted_signing_config_directory" \
    || ! -d "$trusted_signing_config_directory" \
    || "$trusted_signing_config_metadata" != "$(/usr/bin/id -u) 700" ]]; then
    /bin/rmdir "$trusted_signing_config_directory" 2>/dev/null || true
    echo "Could not secure the trusted release bootstrap directory" >&2
    exit 65
fi
if ! /usr/bin/env -i \
        GIT_ATTR_NOSYSTEM=1 \
        GIT_CONFIG_GLOBAL=/dev/null \
        GIT_CONFIG_NOSYSTEM=1 \
        GIT_NO_REPLACE_OBJECTS=1 \
        HOME="$HOME" \
        LANG=C \
        LC_ALL=C \
        PATH=/usr/bin:/bin:/usr/sbin:/sbin \
        /usr/bin/git -C "$project_root" cat-file blob \
            HEAD:Scripts/signing-config.sh \
        >"$trusted_signing_config"; then
    /bin/rm -f "$trusted_signing_config"
    /bin/rmdir "$trusted_signing_config_directory" 2>/dev/null || true
    echo "Could not load the committed release bootstrap" >&2
    exit 65
fi
/bin/chmod 0400 "$trusted_signing_config" || exit 65
# shellcheck disable=SC1090
source "$trusted_signing_config"
/bin/rm -f "$trusted_signing_config" || exit 65
/bin/rmdir "$trusted_signing_config_directory" || exit 65
unset \
    trusted_signing_config \
    trusted_signing_config_directory \
    trusted_signing_config_metadata
sanitize_release_git_environment
pin_clean_release_source "$project_root" || exit $?
source_commit="$validated_release_source_commit"
source_tree="$validated_release_source_tree"
# shellcheck disable=SC1091
source "$script_dir/notary-log.sh"
# shellcheck disable=SC1091
source "$script_dir/macos-code-signing.sh"
# shellcheck disable=SC1091
source "$script_dir/macos-container-validation.sh"
# shellcheck disable=SC1091
source "$script_dir/release-output.sh"
# shellcheck disable=SC1091
source "$script_dir/apple-toolchain.sh"
# shellcheck disable=SC1091
source "$script_dir/release-artifact-validation.sh"
validated_container_app=""
validated_dmg_device=""

if [[ ! -x "$developer_dir/usr/bin/xcodebuild" ]]; then
    echo "Xcode not found at $developer_dir" >&2
    exit 69
fi
validate_apple_distribution_toolchain "$developer_dir" macosx || exit $?
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
verify_source_unchanged() {
    verify_development_team_config_unchanged \
        "$local_config" "$team_id" "$local_config_hash" || exit $?
    verify_pinned_release_source_unchanged \
        "$project_root" "$source_commit" "$source_tree" || exit $?
}

work_dir=""
work_dir_identity=""
source_snapshot=""
source_snapshot_identity=""
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
dmg_attached_device=""
dmg_mount=""

cleanup() {
    local exit_status=$?
    local work_cleanup_allowed=true

    set +e
    if [[ -n "${dmg_attached_device:-}" ]]; then
        if ! hdiutil detach "$dmg_attached_device" -quiet 2>/dev/null \
            && [[ -n "${dmg_mount:-}" ]]; then
            hdiutil detach "$dmg_mount" -quiet 2>/dev/null || true
        fi
    elif [[ -n "${dmg_mount:-}" ]] \
        && mount | grep -Fq " on $dmg_mount "; then
        hdiutil detach "$dmg_mount" -quiet 2>/dev/null || true
    fi
    if [[ -n "${dmg_mount:-}" ]] \
        && mount | grep -Fq " on $dmg_mount "; then
        echo "DMG remains mounted; preserving temporary work at $work_dir" >&2
        echo "Preserving staged output at $staging_dir" >&2
    else
        cleanup_private_release_directory \
            "${staging_parent:-}" \
            "${staging_parent_identity:-}" \
            "$output_parent" \
            '^\.AgentLimits-macos-package-stage\.[A-Za-z0-9]{6}$' \
            || true
        if [[ -n "${source_snapshot:-}" ]] \
            && ! unlock_immutable_release_source_snapshot_for_cleanup \
                "$source_snapshot" \
                "$source_snapshot_identity" \
                "$work_dir" \
                "$project_root" \
                "$source_tree"; then
            work_cleanup_allowed=false
        fi
        if [[ "$work_cleanup_allowed" == "true" ]]; then
            cleanup_private_release_directory \
                "${work_dir:-}" \
                "${work_dir_identity:-}" \
                /private/tmp \
                '^AgentLimits-macos-package\.[A-Za-z0-9]{6}$' \
                || true
        fi
    fi
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
    macos-package \
    || exit $?
staging_parent="$validated_release_staging_parent"
staging_parent_identity="$validated_release_staging_parent_identity"
staging_dir="$validated_release_staging_directory"
staging_dir_identity="$validated_release_staging_directory_identity"
output_dir="$staging_dir"
create_private_release_work_directory AgentLimits-macos-package || exit $?
work_dir="$validated_release_work_directory"
work_dir_identity="$validated_release_work_directory_identity"
configure_private_release_temporary_directory "$work_dir" || exit $?
derived_data="$work_dir/DerivedData"
mkdir -m 700 "$derived_data"
make_release_directory_private "$derived_data" || exit $?
verify_source_unchanged

export DEVELOPER_DIR="$developer_dir"

create_immutable_release_source_snapshot \
    "$project_root" "$source_commit" "$source_tree" "$work_dir" || exit $?
source_snapshot="$validated_release_source_snapshot"
source_snapshot_identity="$validated_release_source_snapshot_identity"
build_root="$source_snapshot"
snapshot_config="$work_dir/DevelopmentTeam.local.xcconfig"
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
    -scheme AgentLimits \
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
    -project "$build_root/AgentLimits.xcodeproj" \
    -scheme AgentLimits \
    -configuration Release \
    -destination 'generic/platform=macOS' \
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
archive_app="$archive/Products/Applications/AgentLimitsForked.app"
archive_widget="$archive_app/Contents/PlugIns/AgentLimitsWidgetExtension.appex"
verify_apple_product_toolchain_metadata \
    "$archive_app/Contents/Info.plist" macosx "Archived macOS app" || exit $?
verify_apple_product_toolchain_metadata \
    "$archive_widget/Contents/Info.plist" macosx "Archived macOS widget" \
    || exit $?

validate_only_named_directory_entry \
    "$archive/Products/Applications" \
    AgentLimitsForked.app \
    "macOS archive products" || exit $?
archive_app="$validated_artifact_path"
validate_only_named_directory_entry \
    "$archive_app/Contents/PlugIns" \
    AgentLimitsWidgetExtension.appex \
    "macOS archive plug-ins" || exit $?
archive_widget="$validated_artifact_path"
validate_dsym_matches_binary \
    "$archive_app/Contents/MacOS/AgentLimitsForked" \
    "$archive/dSYMs/AgentLimitsForked.app.dSYM" \
    "macOS archive app" arm64 x86_64 || exit $?
validate_dsym_matches_binary \
    "$archive_widget/Contents/MacOS/AgentLimitsWidgetExtension" \
    "$archive/dSYMs/AgentLimitsWidgetExtension.appex.dSYM" \
    "macOS archive widget" arm64 x86_64 || exit $?

mkdir -p "$export_dir"
echo "Exporting with Developer ID..."
if ! xcodebuild -exportArchive \
    -allowProvisioningUpdates \
    -archivePath "$archive" \
    -exportPath "$export_dir" \
    -exportOptionsPlist \
        "$build_root/Distribution/ExportOptions-DeveloperID.plist" \
    >"$export_log" 2>&1; then
    tail -120 "$export_log" >&2
    exit 1
fi
verify_source_unchanged

resolve_exactly_one_directory_with_suffix \
    "$export_dir" .app AgentLimitsForked.app \
    "Developer ID export" || exit $?
exported_app="$validated_artifact_path"

app="$output_dir/AgentLimitsForked.app"
ditto "$exported_app" "$app"
validate_only_named_directory_entry \
    "$app/Contents/PlugIns" \
    AgentLimitsWidgetExtension.appex \
    "Developer ID app plug-ins" || exit $?
widget="$validated_artifact_path"

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

codesign --verify --all-architectures --deep --strict --verbose=4 "$app"
codesign --verify --all-architectures --strict --verbose=4 "$widget"

verify_developer_id_signature() {
    local bundle="$1"
    local label="$2"
    local expected_identifier="$3"
    local expected_authority="${4:-}"
    local arm64_details
    local requirement
    local x86_64_details

    requirement="=anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = \"$team_id\""
    if [[ -n "$expected_identifier" ]]; then
        requirement="$requirement and identifier \"$expected_identifier\""
    fi

    codesign --verify --all-architectures --strict --verbose=4 \
        -R "$requirement" "$bundle"
    if ! arm64_details="$(codesign -d -a arm64 -vvv "$bundle" 2>&1)" \
        || ! x86_64_details="$(codesign -d -a x86_64 -vvv \
            "$bundle" 2>&1)"; then
        echo "$label does not contain two readable signature slices" >&2
        exit 1
    fi
    validate_developer_id_signature_slices \
        "$arm64_details" \
        "$x86_64_details" \
        "$team_id" \
        "$expected_identifier" \
        "$expected_authority" \
        "$label" \
        || exit $?
}

validate_developer_id_profile() {
    local profile="$1"
    local bundle_id="$2"
    local label="$3"
    local decoded="$work_dir/$label-profile.plist"
    local profile_team
    local application_id
    local source_identity
    local source_hash

    validate_unlinked_regular_file_artifact \
        "$profile" "$label embedded provisioning profile" || exit $?
    source_identity="$validated_regular_artifact_identity"
    source_hash="$validated_regular_artifact_hash"
    security cms -D -i "$profile" >"$decoded"
    verify_unlinked_regular_file_artifact_unchanged \
        "$profile" "$source_identity" "$source_hash" \
        "$label embedded provisioning profile" || exit $?
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
    validate_provisioning_profile_validity_window \
        "$decoded" "$label" || exit $?
}

validate_profiles_at_final_publication_fence() {
    local validation_epoch
    local macos_expiration_epoch
    local widget_expiration_epoch

    validated_final_profile_expiration_epoch=""

    validation_epoch="$(/bin/date -u '+%s')" || return $?
    validate_provisioning_profile_validity_window \
        "$work_dir/macos-profile.plist" macos "$validation_epoch" || return $?
    macos_expiration_epoch="$validated_profile_expiration_epoch"
    validate_provisioning_profile_validity_window \
        "$work_dir/widget-profile.plist" widget "$validation_epoch" || return $?
    widget_expiration_epoch="$validated_profile_expiration_epoch"
    if (( macos_expiration_epoch < widget_expiration_epoch )); then
        validated_final_profile_expiration_epoch="$macos_expiration_epoch"
    else
        validated_final_profile_expiration_epoch="$widget_expiration_epoch"
    fi
}

application_identity="$(codesign -dvvv "$app" 2>&1 \
    | sed -n 's/^Authority=\(Developer ID Application:.*\)$/\1/p' \
    | head -1)"
if [[ -z "$application_identity" \
    || ! "$application_identity" =~ ^Developer\ ID\ Application:\ .+\ \(${team_id}\)$ ]]; then
    echo "Could not resolve the Team $team_id Developer ID Application identity" >&2
    exit 1
fi
verify_developer_id_signature \
    "$app" \
    "macOS app" \
    "com.jimboha.agentlimits.macos" \
    "$application_identity"
if ! security find-identity -v -p codesigning \
        | grep -Fq "\"$application_identity\""; then
    echo "Developer ID Application identity and private key are unavailable" >&2
    exit 78
fi
verify_developer_id_signature \
    "$widget" \
    "macOS widget" \
    "com.jimboha.agentlimits.macos.widget" \
    "$application_identity"
validate_developer_id_profile \
    "$app/Contents/embedded.provisionprofile" \
    "com.jimboha.agentlimits.macos" \
    macos
validate_developer_id_profile \
    "$widget/Contents/embedded.provisionprofile" \
    "com.jimboha.agentlimits.macos.widget" \
    widget

sparkle="$app/Contents/Frameworks/Sparkle.framework"
sparkle_version_root="$sparkle/Versions/B"
sparkle_lock="$build_root/AgentLimits.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
sparkle_pin_count="$(jq \
    '[.pins[] | select(.identity == "sparkle")] | length' \
    "$sparkle_lock")"
if [[ "$sparkle_pin_count" != "1" ]]; then
    echo "Package.resolved must contain exactly one Sparkle pin" >&2
    exit 1
fi
sparkle_version="$(jq -er \
    '.pins[] | select(.identity == "sparkle") | .state.version' \
    "$sparkle_lock")"
sparkle_revision="$(jq -er \
    '.pins[] | select(.identity == "sparkle") | .state.revision' \
    "$sparkle_lock")"
if [[ "$sparkle_version" != "2.9.4" \
    || "$sparkle_revision" \
        != "b6496a74a087257ef5e6da1c5b29a447a60f5bd7" ]]; then
    echo "Sparkle changed; audit and update the signed-code inventory first" >&2
    exit 1
fi

validate_sparkle_code_inventory() {
    local candidate
    local candidate_architectures
    local mode
    local relative
    local expected
    local file_inventory
    local bundle_inventory

    if [[ -L "$sparkle" || ! -d "$sparkle_version_root" \
        || -L "$sparkle_version_root" ]]; then
        echo "Sparkle framework has an unsafe version root" >&2
        return 1
    fi
    validate_sparkle_symlink_inventory "$sparkle" || return $?
    file_inventory="$(mktemp "${TMPDIR}sparkle-files.XXXXXX")" || return 1
    bundle_inventory="$(mktemp "${TMPDIR}sparkle-bundles.XXXXXX")" || {
        rm -f "$file_inventory"
        return 1
    }
    if ! find "$sparkle" -type f -print0 >"$file_inventory" \
        || ! find "$sparkle_version_root" -type d \
            \( -name '*.app' -o -name '*.xpc' -o -name '*.framework' \) \
            -print0 >"$bundle_inventory"; then
        echo "Could not traverse the Sparkle framework" >&2
        rm -f "$file_inventory" "$bundle_inventory"
        return 1
    fi

    for expected in \
        Versions/B/Sparkle \
        Versions/B/Autoupdate \
        Versions/B/Updater.app/Contents/MacOS/Updater \
        Versions/B/XPCServices/Downloader.xpc/Contents/MacOS/Downloader \
        Versions/B/XPCServices/Installer.xpc/Contents/MacOS/Installer; do
        if [[ -L "$sparkle/$expected" || ! -f "$sparkle/$expected" \
            || ! -x "$sparkle/$expected" ]]; then
            echo "Sparkle code is missing or unsafe: $expected" >&2
            rm -f "$file_inventory" "$bundle_inventory"
            return 1
        fi
    done

    while IFS= read -r -d '' candidate; do
        relative="${candidate#"$sparkle"/}"
        mode="$(stat -f '%Lp' "$candidate")" || {
            rm -f "$file_inventory" "$bundle_inventory"
            return 1
        }
        candidate_architectures=""
        if candidate_architectures="$(lipo -archs "$candidate" \
                2>/dev/null)"; then
            :
        fi
        if [[ -n "$candidate_architectures" ]] \
            || (( (8#$mode & 8#111) != 0 )); then
            if ! is_expected_sparkle_code_path "$relative"; then
                echo "Sparkle contains unexpected code: $relative" >&2
                rm -f "$file_inventory" "$bundle_inventory"
                return 1
            fi
        fi
    done <"$file_inventory"

    while IFS= read -r -d '' candidate; do
        relative="${candidate#"$sparkle"/}"
        if ! is_expected_sparkle_bundle_path "$relative"; then
            echo "Sparkle contains unexpected nested bundle: $relative" >&2
            rm -f "$file_inventory" "$bundle_inventory"
            return 1
        fi
    done <"$bundle_inventory"
    rm -f "$file_inventory" "$bundle_inventory"
}

verify_sparkle_bundle_metadata() {
    local plist="$1"
    local expected_identifier="$2"
    local expected_executable="$3"
    local expected_build="$4"
    local label="$5"

    if [[ -L "$plist" || ! -f "$plist" ]]; then
        echo "$label has no regular Info.plist" >&2
        exit 1
    fi
    plutil -lint "$plist" >/dev/null
    if [[ "$(plutil -extract CFBundleIdentifier raw "$plist")" \
            != "$expected_identifier" \
        || "$(plutil -extract CFBundleExecutable raw "$plist")" \
            != "$expected_executable" \
        || "$(plutil -extract CFBundleShortVersionString raw "$plist")" \
            != "$sparkle_version" \
        || "$(plutil -extract CFBundleVersion raw "$plist")" \
            != "$expected_build" ]]; then
        echo "$label metadata does not match the audited Sparkle pin" >&2
        exit 1
    fi
}

verify_signed_sparkle_component() {
    local component="$1"
    local binary="$2"
    local expected_identifier="$3"
    local label="$4"
    local index="$5"
    local architectures
    local details
    local entitlements
    local signature_architecture
    local signed_identifier

    verify_developer_id_signature \
        "$component" \
        "$label" \
        "$expected_identifier" \
        "$application_identity"
    architectures="$(lipo -archs "$binary")"
    validate_universal_binary_architectures \
        "$architectures" "$label" || exit $?
    for signature_architecture in arm64 x86_64; do
        entitlements="$work_dir/sparkle-$index-$signature_architecture-entitlements.plist"
        codesign -d -a "$signature_architecture" \
            --entitlements "$entitlements" --xml \
            "$component" 2>/dev/null
        validate_no_get_task_allow_entitlements \
            "$entitlements" "$label ($signature_architecture)" || exit $?

        if [[ -z "$expected_identifier" ]]; then
            details="$(codesign -d -a "$signature_architecture" -vvv \
                "$component" 2>&1)"
            signed_identifier="$(printf '%s\n' "$details" \
                | sed -n 's/^Identifier=//p' | head -1)"
            validate_sparkle_autoupdate_identifier "$signed_identifier" \
                || exit $?
        fi
    done
}

validate_sparkle_code_inventory || exit $?
sparkle_build="$(plutil -extract CFBundleVersion raw \
    "$sparkle_version_root/Resources/Info.plist")"
if [[ ! "$sparkle_build" =~ ^[0-9]+$ ]]; then
    echo "Sparkle framework has an invalid build number" >&2
    exit 1
fi
verify_sparkle_bundle_metadata \
    "$sparkle_version_root/Resources/Info.plist" \
    "org.sparkle-project.Sparkle" \
    "Sparkle" \
    "$sparkle_build" \
    "Sparkle framework"
verify_sparkle_bundle_metadata \
    "$sparkle_version_root/Updater.app/Contents/Info.plist" \
    "org.sparkle-project.Sparkle.Updater" \
    "Updater" \
    "$sparkle_build" \
    "Sparkle Updater"
verify_sparkle_bundle_metadata \
    "$sparkle_version_root/XPCServices/Downloader.xpc/Contents/Info.plist" \
    "org.sparkle-project.DownloaderService" \
    "Downloader" \
    "$sparkle_build" \
    "Sparkle Downloader"
verify_sparkle_bundle_metadata \
    "$sparkle_version_root/XPCServices/Installer.xpc/Contents/Info.plist" \
    "org.sparkle-project.InstallerLauncher" \
    "Installer" \
    "$sparkle_build" \
    "Sparkle Installer"

verify_signed_sparkle_component \
    "$sparkle" \
    "$sparkle_version_root/Sparkle" \
    "org.sparkle-project.Sparkle" \
    "Sparkle framework" \
    framework
verify_signed_sparkle_component \
    "$sparkle_version_root/Autoupdate" \
    "$sparkle_version_root/Autoupdate" \
    "" \
    "Sparkle Autoupdate" \
    autoupdate
verify_signed_sparkle_component \
    "$sparkle_version_root/Updater.app" \
    "$sparkle_version_root/Updater.app/Contents/MacOS/Updater" \
    "org.sparkle-project.Sparkle.Updater" \
    "Sparkle Updater" \
    updater
verify_signed_sparkle_component \
    "$sparkle_version_root/XPCServices/Downloader.xpc" \
    "$sparkle_version_root/XPCServices/Downloader.xpc/Contents/MacOS/Downloader" \
    "org.sparkle-project.DownloaderService" \
    "Sparkle Downloader" \
    downloader
verify_signed_sparkle_component \
    "$sparkle_version_root/XPCServices/Installer.xpc" \
    "$sparkle_version_root/XPCServices/Installer.xpc/Contents/MacOS/Installer" \
    "org.sparkle-project.InstallerLauncher" \
    "Sparkle Installer" \
    installer

app_info="$app/Contents/Info.plist"
version="$(plutil -extract CFBundleShortVersionString raw "$app_info")"
build="$(plutil -extract CFBundleVersion raw "$app_info")"
executable="$(plutil -extract CFBundleExecutable raw "$app_info")"
architectures="$(lipo -archs "$app/Contents/MacOS/$executable")"
widget_info="$widget/Contents/Info.plist"
verify_apple_product_toolchain_metadata \
    "$app_info" macosx "Developer ID app" || exit $?
verify_apple_product_toolchain_metadata \
    "$widget_info" macosx "Developer ID widget" || exit $?
widget_executable="$(plutil -extract CFBundleExecutable raw "$widget_info")"
widget_architectures="$(lipo -archs \
    "$widget/Contents/MacOS/$widget_executable")"

validate_dsym_matches_binary \
    "$app/Contents/MacOS/$executable" \
    "$archive/dSYMs/AgentLimitsForked.app.dSYM" \
    "Developer ID app" arm64 x86_64 || exit $?
validate_dsym_matches_binary \
    "$widget/Contents/MacOS/$widget_executable" \
    "$archive/dSYMs/AgentLimitsWidgetExtension.appex.dSYM" \
    "Developer ID widget" arm64 x86_64 || exit $?

if [[ "$(plutil -extract CFBundleIdentifier raw "$app_info")" \
        != "com.jimboha.agentlimits.macos" \
    || "$(plutil -extract CFBundleIdentifier raw "$widget_info")" \
        != "com.jimboha.agentlimits.macos.widget" ]]; then
    echo "Developer ID export has unexpected bundle identifiers" >&2
    exit 1
fi

validate_universal_binary_architectures \
    "$architectures" "Developer ID app" || exit $?
validate_universal_binary_architectures \
    "$widget_architectures" "Developer ID widget" || exit $?

for signature_architecture in arm64 x86_64; do
    entitlements="$work_dir/app-$signature_architecture-entitlements.plist"
    codesign -d -a "$signature_architecture" \
        --entitlements "$entitlements" --xml "$app" 2>/dev/null
    validate_no_get_task_allow_entitlements \
        "$entitlements" "Developer ID app ($signature_architecture)" \
        || exit $?
    if [[ "$(plutil -extract 'com\.apple\.application-identifier' raw \
            "$entitlements" 2>/dev/null || true)" \
            != "$team_id.com.jimboha.agentlimits.macos" \
        || "$(plutil -extract 'com\.apple\.developer\.team-identifier' raw \
            "$entitlements" 2>/dev/null || true)" != "$team_id" ]]; then
        echo "Developer ID app ($signature_architecture) has unexpected identifier entitlements" >&2
        exit 1
    fi
    if [[ "$(plutil -extract 'com\.apple\.security\.application-groups' raw \
            "$entitlements" 2>/dev/null || true)" != "1" \
        || "$(plutil -extract \
            'com\.apple\.security\.application-groups.0' raw \
            "$entitlements" 2>/dev/null || true)" \
            != "group.com.jimboha.agentlimits.macos" ]]; then
        echo "Developer ID app ($signature_architecture) is missing the fork App Group entitlement" >&2
        exit 1
    fi

    widget_entitlements="$work_dir/widget-$signature_architecture-entitlements.plist"
    codesign -d -a "$signature_architecture" \
        --entitlements "$widget_entitlements" --xml "$widget" 2>/dev/null
    validate_no_get_task_allow_entitlements \
        "$widget_entitlements" "Widget ($signature_architecture)" \
        || exit $?
    if [[ "$(plutil -extract 'com\.apple\.application-identifier' raw \
            "$widget_entitlements" 2>/dev/null || true)" \
            != "$team_id.com.jimboha.agentlimits.macos.widget" \
        || "$(plutil -extract 'com\.apple\.developer\.team-identifier' raw \
            "$widget_entitlements" 2>/dev/null || true)" != "$team_id" ]]; then
        echo "Widget ($signature_architecture) has unexpected identifier entitlements" >&2
        exit 1
    fi
    if [[ "$(plutil -extract 'com\.apple\.security\.app-sandbox' raw \
            "$widget_entitlements" 2>/dev/null || true)" != "true" ]]; then
        echo "Widget ($signature_architecture) signature lacks App Sandbox" >&2
        exit 1
    fi
    if [[ "$(plutil -extract 'com\.apple\.security\.application-groups' raw \
            "$widget_entitlements" 2>/dev/null || true)" != "1" \
        || "$(plutil -extract \
            'com\.apple\.security\.application-groups.0' raw \
            "$widget_entitlements" 2>/dev/null || true)" \
            != "group.com.jimboha.agentlimits.macos" ]]; then
        echo "Widget ($signature_architecture) signature lacks the fork App Group" >&2
        exit 1
    fi
done

submit_notary() {
    local artifact="$1"
    local label="$2"
    local result="$output_dir/notary-$label.plist"
    local log="$output_dir/notary-$label-log.json"
    local submission_id
    local status
    local submit_exit=0

    /usr/bin/xcrun --no-cache notarytool submit "$artifact" \
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
    /usr/bin/xcrun --no-cache notarytool log "$submission_id" \
        --keychain-profile "$notary_profile" \
        "$log" \
        >/dev/null

    if [[ $submit_exit -ne 0 || "$status" != "Accepted" ]]; then
        echo "Apple did not accept $label notarization; inspect $log" >&2
        exit 1
    fi
    validate_accepted_notary_log "$log" "$submission_id" || exit $?
}

code_directory_hash() {
    local code="$1"
    local architecture="$2"
    local label="$3"
    local details
    local hash

    details="$(codesign -d -a "$architecture" -vvv "$code" 2>&1)"
    hash="$(printf '%s\n' "$details" \
        | sed -n 's/^CDHash=//p' | head -1)"
    if [[ ! "$hash" =~ ^[0-9a-f]{40}$ ]]; then
        echo "$label has no valid $architecture Code Directory hash" >&2
        return 1
    fi
    printf '%s\n' "$hash"
}

verify_packaged_app() {
    local candidate_app="$1"
    local label="$2"
    local candidate_widget="$candidate_app/Contents/PlugIns/AgentLimitsWidgetExtension.appex"
    local candidate_info="$candidate_app/Contents/Info.plist"
    local candidate_widget_info="$candidate_widget/Contents/Info.plist"
    local candidate_executable
    local candidate_widget_executable
    local candidate_architectures
    local candidate_widget_architectures
    local architecture
    local actual_hash
    local expected_hash

    if [[ -L "$candidate_app" || ! -d "$candidate_app" \
        || -L "$candidate_widget" || ! -d "$candidate_widget" ]]; then
        echo "$label is missing the regular app or widget bundle" >&2
        exit 1
    fi
    verify_apple_product_toolchain_metadata \
        "$candidate_info" macosx "$label" || exit $?
    verify_apple_product_toolchain_metadata \
        "$candidate_widget_info" macosx "$label widget" || exit $?
    codesign --verify --all-architectures --deep --strict --verbose=4 \
        "$candidate_app"
    verify_developer_id_signature \
        "$candidate_app" \
        "$label" \
        "com.jimboha.agentlimits.macos" \
        "$application_identity"
    verify_developer_id_signature \
        "$candidate_widget" \
        "$label widget" \
        "com.jimboha.agentlimits.macos.widget" \
        "$application_identity"

    if [[ "$(plutil -extract CFBundleShortVersionString raw \
            "$candidate_info")" != "$version" \
        || "$(plutil -extract CFBundleVersion raw "$candidate_info")" \
            != "$build" \
        || "$(plutil -extract CFBundleShortVersionString raw \
            "$candidate_widget_info")" != "$version" \
        || "$(plutil -extract CFBundleVersion raw \
            "$candidate_widget_info")" != "$build" ]]; then
        echo "$label version metadata changed in its container" >&2
        exit 1
    fi
    candidate_executable="$(plutil -extract CFBundleExecutable raw \
        "$candidate_info")"
    candidate_widget_executable="$(plutil -extract CFBundleExecutable raw \
        "$candidate_widget_info")"
    candidate_architectures="$(lipo -archs \
        "$candidate_app/Contents/MacOS/$candidate_executable")"
    candidate_widget_architectures="$(lipo -archs \
        "$candidate_widget/Contents/MacOS/$candidate_widget_executable")"
    validate_universal_binary_architectures \
        "$candidate_architectures" "$label" || exit $?
    validate_universal_binary_architectures \
        "$candidate_widget_architectures" "$label widget" || exit $?

    for architecture in arm64 x86_64; do
        actual_hash="$(code_directory_hash \
            "$candidate_app" "$architecture" "$label")"
        case "$architecture" in
            arm64) expected_hash="$reference_app_arm64_cdhash" ;;
            x86_64) expected_hash="$reference_app_x86_64_cdhash" ;;
        esac
        if [[ "$actual_hash" != "$expected_hash" ]]; then
            echo "$label $architecture signature changed in its container" >&2
            exit 1
        fi

        actual_hash="$(code_directory_hash \
            "$candidate_widget" "$architecture" "$label widget")"
        case "$architecture" in
            arm64) expected_hash="$reference_widget_arm64_cdhash" ;;
            x86_64) expected_hash="$reference_widget_x86_64_cdhash" ;;
        esac
        if [[ "$actual_hash" != "$expected_hash" ]]; then
            echo "$label widget $architecture signature changed in its container" >&2
            exit 1
        fi
    done

    /usr/bin/xcrun --no-cache stapler validate "$candidate_app"
    spctl --assess --type execute --verbose=4 "$candidate_app"
}

base_name="AgentLimitsForked-$version-$build-macOS"
temporary_notary_zip="$work_dir/$base_name-notary.zip"
ditto -c -k --sequesterRsrc --keepParent "$app" "$temporary_notary_zip"

echo "Notarizing the app..."
submit_notary "$temporary_notary_zip" app
/usr/bin/xcrun --no-cache stapler staple "$app"
/usr/bin/xcrun --no-cache stapler validate "$app"
reference_app_arm64_cdhash="$(code_directory_hash "$app" arm64 "macOS app")"
reference_app_x86_64_cdhash="$(code_directory_hash "$app" x86_64 "macOS app")"
reference_widget_arm64_cdhash="$(code_directory_hash \
    "$widget" arm64 "macOS widget")"
reference_widget_x86_64_cdhash="$(code_directory_hash \
    "$widget" x86_64 "macOS widget")"

zip="$output_dir/$base_name.zip"
dmg="$output_dir/$base_name.dmg"
pkg="$output_dir/$base_name.pkg"
ditto -c -k --sequesterRsrc --keepParent "$app" "$zip"
zip_extract="$work_dir/zip-extract"
mkdir -m 700 "$zip_extract"
ditto -x -k "$zip" "$zip_extract"
validate_zip_container_root "$zip_extract" || exit $?
zip_app="$validated_container_app"
verify_packaged_app "$zip_app" "ZIP app"

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
/usr/bin/xcrun --no-cache stapler staple "$pkg"
/usr/bin/xcrun --no-cache stapler validate "$pkg"
final_package_signature="$(pkgutil --check-signature "$pkg" 2>&1)"
if ! printf '%s\n' "$final_package_signature" \
        | grep -Fq "$installer_identity" \
    || ! printf '%s\n' "$final_package_signature" \
        | grep -Fq 'Signed with a trusted timestamp'; then
    echo "Final PKG lacks the expected identity or trusted timestamp" >&2
    exit 1
fi
pkg_expanded="$work_dir/pkg-expanded"
pkgutil --expand-full "$pkg" "$pkg_expanded"
validate_product_package_layout \
    "$pkg_expanded" "$version" "$build" || exit $?
pkg_app="$validated_container_app"
verify_packaged_app "$pkg_app" "PKG payload app"

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

echo "Signing disk image..."
codesign \
    --sign "$application_identity" \
    --timestamp \
    --identifier com.jimboha.agentlimits.macos.dmg \
    "$dmg"
codesign --verify --strict --verbose=4 "$dmg"
dmg_signature="$(codesign -dvvv "$dmg" 2>&1)"
if ! printf '%s\n' "$dmg_signature" \
        | grep -Fqx "Authority=$application_identity" \
    || ! printf '%s\n' "$dmg_signature" \
        | grep -Fqx 'Identifier=com.jimboha.agentlimits.macos.dmg'; then
    echo "DMG has an unexpected Developer ID Application signature" >&2
    exit 1
fi
hdiutil verify "$dmg" >/dev/null

echo "Notarizing disk image..."
submit_notary "$dmg" dmg
/usr/bin/xcrun --no-cache stapler staple "$dmg"
/usr/bin/xcrun --no-cache stapler validate "$dmg"
codesign --verify --strict --verbose=4 "$dmg"
hdiutil verify "$dmg" >/dev/null

dmg_mount="$work_dir/dmg-mount"
mkdir -m 700 "$dmg_mount"
dmg_mount="$(cd "$dmg_mount" && pwd -P)"
dmg_attach_plist="$work_dir/dmg-attach.plist"
dmg_attach_json="$work_dir/dmg-attach.json"
dmg_disk_plist="$work_dir/dmg-disk.plist"
dmg_disk_json="$work_dir/dmg-disk.json"
hdiutil attach \
    -readonly \
    -nobrowse \
    -noautoopen \
    -mountpoint "$dmg_mount" \
    -plist \
    "$dmg" \
    >"$dmg_attach_plist"
plutil -lint "$dmg_attach_plist" >/dev/null
plutil -convert json -o "$dmg_attach_json" "$dmg_attach_plist"
resolve_dmg_attached_device "$dmg_attach_json" "$dmg_mount" || exit $?
dmg_attached_device="$validated_dmg_device"
diskutil info -plist "$dmg_attached_device" >"$dmg_disk_plist"
plutil -lint "$dmg_disk_plist" >/dev/null
plutil -convert json -o "$dmg_disk_json" "$dmg_disk_plist"
validate_dmg_attachment_metadata \
    "$dmg_attach_json" "$dmg_disk_json" "$dmg_mount" || exit $?
if [[ "$validated_dmg_device" != "$dmg_attached_device" ]]; then
    echo "DMG device identity changed during validation" >&2
    exit 1
fi
validate_dmg_container_root "$dmg_mount" || exit $?
mounted_app="$validated_container_app"
verify_packaged_app "$mounted_app" "DMG app"
hdiutil detach "$dmg_attached_device" -quiet
dmg_attached_device=""

codesign --verify --all-architectures --deep --strict --verbose=4 "$app"
pkgutil --check-signature "$pkg"
spctl --assess --type execute --verbose=4 "$app"
spctl --assess --type install --verbose=4 "$pkg"
spctl --assess --type open \
    --context context:primary-signature \
    --verbose=4 "$dmg"

cat >"$output_dir/BUILD-METADATA.txt" <<EOF
AgentLimits Forked $version ($build)
Team ID: $team_id
Git commit: $source_commit
Signing config SHA-256: $local_config_hash
Build source: clean git archive with generated Team-only config
Xcode: $validated_apple_xcode_version ($validated_apple_xcode_build), DTXcode $validated_apple_dtxcode
macOS SDK: $validated_apple_macosx_sdk_version ($validated_apple_macosx_sdk_build)
macOS architectures: $architectures
macOS widget architectures: $widget_architectures
Sparkle: $sparkle_version ($sparkle_revision), build $sparkle_build
Developer ID verification: passed
Nested Sparkle Developer ID verification: passed
Notarization and stapling: passed for app, PKG, and DMG
Final ZIP, PKG, and DMG reopen verification: passed
Archive/product cardinality: passed
dSYM UUID and architecture identity: passed
Provisioning profile validity windows: passed
EOF

(
    verify_source_unchanged
    cd "$output_dir"
    shasum -a 256 \
        "$(basename "$zip")" \
        "$(basename "$dmg")" \
        "$(basename "$pkg")" \
        BUILD-METADATA.txt \
        > SHA256SUMS
)

verify_source_unchanged
# Both profiles use one timestamp, after every other fallible release check.
validate_profiles_at_final_publication_fence || exit $?
profile_publication_headroom_seconds=300
publish_staged_release_directory \
    "$staging_dir" \
    "$staging_dir_identity" \
    "$output_parent" \
    "$output_parent_identity" \
    "$output_name" \
    "$atomic_publisher" \
    "$atomic_publisher_identity" \
    "$atomic_publisher_hash" \
    "$staging_parent_identity" \
    "$validated_final_profile_expiration_epoch" \
    "$profile_publication_headroom_seconds" \
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

echo "Signed and notarized macOS artifacts created at: $release_output_dir"
