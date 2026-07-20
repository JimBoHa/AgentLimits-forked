#!/bin/bash

set -euo pipefail

PATH="/usr/bin:/bin:/usr/sbin:/sbin"
export PATH

usage() {
    echo "Usage: $0 /ABSOLUTE/OUTPUT_DIRECTORY" >&2
    echo "Builds non-distributable macOS and iOS/watchOS preflight artifacts." >&2
}

if [[ $# -ne 1 ]]; then
    usage
    exit 64
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
project_root="$(cd "$script_dir/.." && pwd -P)"
requested_output="$1"
developer_dir="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
validated_container_app=""
validated_dmg_device=""
validated_artifact_path=""
# shellcheck disable=SC1091
source "$script_dir/signing-config.sh"
# shellcheck disable=SC1091
source "$script_dir/macos-container-validation.sh"
# shellcheck disable=SC1091
source "$script_dir/macos-code-signing.sh"
# shellcheck disable=SC1091
source "$script_dir/release-artifact-validation.sh"

if [[ ! -x "$developer_dir/usr/bin/xcodebuild" ]]; then
    echo "Xcode not found at $developer_dir" >&2
    exit 69
fi
if [[ "$requested_output" != /* ]]; then
    echo "Output directory must be an absolute path" >&2
    exit 64
fi

output_name="$(basename "$requested_output")"
requested_parent="$(dirname "$requested_output")"
if [[ -z "$output_name" || "$output_name" == "." \
    || "$output_name" == ".." || "$output_name" == "/" ]]; then
    echo "Output directory name is unsafe" >&2
    exit 64
fi
if [[ -L "$requested_parent" || ! -d "$requested_parent" ]]; then
    echo "Output parent must already be one regular directory: $requested_parent" >&2
    exit 73
fi
output_parent="$(cd "$requested_parent" && pwd -P)"
output_dir="$output_parent/$output_name"
output_parent_owner="$(stat -f '%u' "$output_parent")"
output_parent_mode="$(stat -f '%Lp' "$output_parent")"
# shellcheck disable=SC2012
output_parent_mutating_acl_entries="$(ls -lde "$output_parent" \
    | awk 'NR > 1 && / allow / && \
        /(write|append|delete|add_file|add_subdirectory|chown)/ \
        { count += 1 } END { print count + 0 }')"
if [[ "$output_parent_owner" != "$(id -u)" \
    || $((8#$output_parent_mode & 8#022)) -ne 0 \
    || "$output_parent_mutating_acl_entries" != "0" ]]; then
    echo "Output parent must be current-user-owned without external write access" >&2
    exit 73
fi
if [[ -e "$output_dir" || -L "$output_dir" ]]; then
    echo "Refusing to overwrite existing path: $output_dir" >&2
    exit 73
fi
case "$output_dir/" in
    "$project_root/"*)
        echo "Output directory must be outside the source tree" >&2
        exit 73
        ;;
esac

source_commit="$(git -C "$project_root" rev-parse HEAD)"
if [[ -n "$(git -C "$project_root" status --porcelain \
        --untracked-files=normal)" ]]; then
    echo "Refusing unsigned artifacts from a dirty Git working tree" >&2
    exit 65
fi

verify_source_unchanged() {
    if [[ "$(git -C "$project_root" rev-parse HEAD)" != "$source_commit" \
        || -n "$(git -C "$project_root" status --porcelain \
            --untracked-files=normal)" ]]; then
        echo "Source changed while building; discard these artifacts" >&2
        return 65
    fi
}

verify_no_distribution_material() {
    local bundle="$1"
    local label="$2"
    local unexpected

    for unexpected in \
        "$bundle/_CodeSignature" \
        "$bundle/Contents/_CodeSignature" \
        "$bundle/embedded.mobileprovision" \
        "$bundle/Contents/embedded.mobileprovision" \
        "$bundle/embedded.provisionprofile" \
        "$bundle/Contents/embedded.provisionprofile"; do
        if [[ -e "$unexpected" || -L "$unexpected" ]]; then
            echo "$label contains distribution material: $unexpected" >&2
            return 1
        fi
    done
}

verify_linker_adhoc_bundle() {
    local bundle="$1"
    local expected_identifier="$2"
    local label="$3"
    local details

    verify_no_distribution_material "$bundle" "$label" || return $?
    if ! details="$(codesign -d -a arm64 -vvv "$bundle" 2>&1)"; then
        echo "$label lacks its expected arm64 linker signature" >&2
        return 1
    fi
    validate_linker_adhoc_signature_details \
        "$details" "$expected_identifier" "$label (arm64)" || return $?
    verify_no_code_signature_for_architecture \
        "$bundle" x86_64 "$label (x86_64)" || return $?
}

verify_no_code_signature_for_architecture() {
    local bundle="$1"
    local architecture="$2"
    local label="$3"
    local details
    local signature_exit

    verify_no_distribution_material "$bundle" "$label" || return $?
    if details="$(codesign -d -a "$architecture" -vvv "$bundle" 2>&1)"; then
        echo "$label unexpectedly contains a code signature" >&2
        return 1
    else
        signature_exit=$?
    fi
    validate_no_code_signature_diagnostic \
        "$details" "$signature_exit" "$label" || return $?
}

verify_archive_has_no_signing_metadata() {
    local archive="$1"
    local label="$2"
    local info="$archive/Info.plist"
    local key
    local value

    if [[ -L "$info" || ! -f "$info" ]] || ! plutil -lint "$info" >/dev/null; then
        echo "$label archive metadata is missing or malformed" >&2
        return 1
    fi
    for key in \
        ApplicationProperties.Team \
        ApplicationProperties.SigningIdentity \
        ApplicationProperties.ProvisioningProfile; do
        value="$(plutil -extract "$key" raw "$info" 2>/dev/null || true)"
        if [[ -n "$value" ]]; then
            echo "$label archive unexpectedly records $key" >&2
            return 1
        fi
    done
}

verify_unsigned_product_package() {
    local package="$1"
    local details
    local signature_exit

    if details="$(pkgutil --check-signature "$package" 2>&1)"; then
        echo "Unsigned PKG unexpectedly has an installer signature" >&2
        return 1
    else
        signature_exit=$?
    fi
    if [[ "$signature_exit" != "1" \
        || "$details" != *"Status: no signature"* ]]; then
        echo "PKG signature state could not be proven unsigned" >&2
        return 1
    fi
}

verify_unsigned_disk_image() {
    local disk_image="$1"
    local details
    local signature_exit

    if details="$(codesign -dvvv "$disk_image" 2>&1)"; then
        echo "Unsigned DMG unexpectedly has a code signature" >&2
        return 1
    else
        signature_exit=$?
    fi
    validate_no_code_signature_diagnostic \
        "$details" "$signature_exit" "DMG" || return $?
}

work_dir=""
staging_parent=""
staging_dir=""
publication_lock="$output_parent/.$output_name.AgentLimits-unsigned.lock"
publication_lock_acquired=0
dmg_attached_device=""
dmg_mount=""

release_publication_lock() {
    if [[ "${publication_lock_acquired:-0}" == "1" \
        && -n "${publication_lock:-}" \
        && "$publication_lock" == "$output_parent/."*".AgentLimits-unsigned.lock" \
        && -d "$publication_lock" ]]; then
        if rmdir "$publication_lock" 2>/dev/null; then
            publication_lock_acquired=0
        else
            echo "Could not remove publication lock: $publication_lock" >&2
        fi
    fi
}

cleanup() {
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
        release_publication_lock
        return
    fi
    if [[ -n "${staging_parent:-}" && -d "$staging_parent" \
        && "$staging_parent" == "$output_parent/.AgentLimits-unsigned-stage."* ]]; then
        rm -rf "$staging_parent"
    fi
    if [[ -n "${work_dir:-}" && -d "$work_dir" \
        && "$work_dir" == "/private/tmp/AgentLimits-unsigned-build."* ]]; then
        rm -rf "$work_dir"
    fi
    release_publication_lock
}
trap cleanup EXIT

work_dir="$(mktemp -d "/private/tmp/AgentLimits-unsigned-build.XXXXXX")"
staging_parent="$(mktemp -d "$output_parent/.AgentLimits-unsigned-stage.XXXXXX")"
staging_dir="$staging_parent/$output_name"
mkdir -m 700 "$staging_dir"
if ! mkdir -m 700 "$publication_lock" 2>/dev/null; then
    echo "Another build may already target this output directory" >&2
    exit 73
fi
publication_lock_acquired=1
chmod 700 "$work_dir" "$staging_parent" "$staging_dir"
export DEVELOPER_DIR="$developer_dir"

build_root="$work_dir/source"
mkdir -m 700 "$build_root"
git -C "$project_root" archive --format=tar "$source_commit" \
    | tar -xf - -C "$build_root"
snapshot_config="$build_root/Configurations/UnsignedBuild.xcconfig"
printf '%s\n' '// Sanitized, unsigned build environment.' >"$snapshot_config"
chmod 600 "$snapshot_config"
prepare_xcode_signing_environment "$snapshot_config"
verify_source_unchanged

derived_data="$work_dir/DerivedData"
mkdir -m 700 "$derived_data"
mac_archive="$work_dir/AgentLimits-macOS.xcarchive"
ios_archive="$work_dir/AgentLimits-iOS-watchOS.xcarchive"
mac_log="$staging_dir/build-macOS.log"
ios_log="$staging_dir/build-iOS-watchOS.log"

echo "Building unsigned universal macOS archive..."
if ! xcodebuild archive \
    -project "$build_root/AgentLimits.xcodeproj" \
    -scheme AgentLimits \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    -onlyUsePackageVersionsFromResolvedFile \
    -derivedDataPath "$derived_data" \
    -archivePath "$mac_archive" \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGN_IDENTITY= \
    DEVELOPMENT_TEAM= \
    SWIFT_TREAT_WARNINGS_AS_ERRORS=YES \
    GCC_TREAT_WARNINGS_AS_ERRORS=YES \
    >"$mac_log" 2>&1; then
    tail -100 "$mac_log" >&2
    exit 1
fi
verify_source_unchanged

echo "Building unsigned iOS archive with embedded Watch app..."
if ! xcodebuild archive \
    -project "$build_root/AgentLimits.xcodeproj" \
    -scheme AgentLimitsiOS \
    -configuration Release \
    -destination 'generic/platform=iOS' \
    -onlyUsePackageVersionsFromResolvedFile \
    -derivedDataPath "$derived_data" \
    -archivePath "$ios_archive" \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGN_IDENTITY= \
    DEVELOPMENT_TEAM= \
    SWIFT_TREAT_WARNINGS_AS_ERRORS=YES \
    GCC_TREAT_WARNINGS_AS_ERRORS=YES \
    >"$ios_log" 2>&1; then
    tail -100 "$ios_log" >&2
    exit 1
fi
verify_source_unchanged

validate_only_named_directory_entry \
    "$mac_archive/Products/Applications" \
    AgentLimitsForked.app \
    "unsigned macOS archive products" || exit $?
mac_app="$validated_artifact_path"
validate_only_named_directory_entry \
    "$mac_app/Contents/PlugIns" \
    AgentLimitsWidgetExtension.appex \
    "unsigned macOS archive plug-ins" || exit $?
widget="$validated_artifact_path"
validate_only_named_directory_entry \
    "$ios_archive/Products/Applications" \
    AgentLimits.app \
    "unsigned iOS archive products" || exit $?
ios_app="$validated_artifact_path"
validate_only_named_directory_entry \
    "$ios_app/Watch" \
    AgentLimitsWatch.app \
    "unsigned iOS archive Watch products" || exit $?
watch_app="$validated_artifact_path"

for required_path in \
    "$mac_app" \
    "$widget" \
    "$mac_app/Contents/Frameworks/Sparkle.framework" \
    "$mac_app/Contents/Resources/PrivacyInfo.xcprivacy" \
    "$mac_app/Contents/Resources/LICENSE" \
    "$mac_app/Contents/Resources/THIRD_PARTY_NOTICES.md" \
    "$widget/Contents/Resources/PrivacyInfo.xcprivacy" \
    "$ios_app" \
    "$ios_app/PrivacyInfo.xcprivacy" \
    "$ios_app/LICENSE" \
    "$watch_app" \
    "$watch_app/PrivacyInfo.xcprivacy" \
    "$watch_app/LICENSE"; do
    if [[ ! -e "$required_path" ]]; then
        echo "Archive is missing required content: $required_path" >&2
        exit 1
    fi
done

mac_info="$mac_app/Contents/Info.plist"
widget_info="$widget/Contents/Info.plist"
ios_info="$ios_app/Info.plist"
watch_info="$watch_app/Info.plist"
version="$(plutil -extract CFBundleShortVersionString raw "$mac_info")"
build="$(plutil -extract CFBundleVersion raw "$mac_info")"

if [[ "$(plutil -extract CFBundleShortVersionString raw "$widget_info")" \
        != "$version" \
    || "$(plutil -extract CFBundleVersion raw "$widget_info")" != "$build" \
    || "$(plutil -extract CFBundleShortVersionString raw "$ios_info")" \
        != "$version" \
    || "$(plutil -extract CFBundleVersion raw "$ios_info")" != "$build" \
    || "$(plutil -extract CFBundleShortVersionString raw "$watch_info")" \
        != "$version" \
    || "$(plutil -extract CFBundleVersion raw "$watch_info")" != "$build" ]]; then
    echo "macOS, widget, iOS, and watchOS version/build values are not synchronized" >&2
    exit 1
fi

if [[ "$(plutil -extract CFBundleIdentifier raw "$mac_info")" \
        != "com.jimboha.agentlimits.macos" \
    || "$(plutil -extract CFBundleIdentifier raw "$widget_info")" \
        != "com.jimboha.agentlimits.macos.widget" \
    || "$(plutil -extract CFBundleIdentifier raw "$ios_info")" \
        != "com.jimboha.agentlimits.ios" \
    || "$(plutil -extract CFBundleIdentifier raw "$watch_info")" \
        != "com.jimboha.agentlimits.ios.watchkitapp" \
    || "$(plutil -extract WKCompanionAppBundleIdentifier raw "$watch_info")" \
        != "com.jimboha.agentlimits.ios" ]]; then
    echo "Unexpected release bundle identifiers" >&2
    exit 1
fi

mac_executable="$(plutil -extract CFBundleExecutable raw "$mac_info")"
widget_executable="$(plutil -extract CFBundleExecutable raw "$widget_info")"
ios_executable="$(plutil -extract CFBundleExecutable raw "$ios_info")"
watch_executable="$(plutil -extract CFBundleExecutable raw "$watch_info")"
mac_archs="$(lipo -archs "$mac_app/Contents/MacOS/$mac_executable")"
widget_archs="$(lipo -archs "$widget/Contents/MacOS/$widget_executable")"
ios_archs="$(lipo -archs "$ios_app/$ios_executable")"
watch_archs="$(lipo -archs "$watch_app/$watch_executable")"

validate_exact_binary_architectures \
    "$mac_archs" "macOS app" arm64 x86_64 || exit $?
validate_exact_binary_architectures \
    "$widget_archs" "macOS widget" arm64 x86_64 || exit $?
validate_exact_binary_architectures \
    "$ios_archs" "iOS app" arm64 || exit $?
validate_exact_binary_architectures \
    "$watch_archs" "watchOS app" arm64 arm64_32 || exit $?
validate_dsym_matches_binary \
    "$mac_app/Contents/MacOS/$mac_executable" \
    "$mac_archive/dSYMs/AgentLimitsForked.app.dSYM" \
    "unsigned macOS app" arm64 x86_64 || exit $?
validate_dsym_matches_binary \
    "$widget/Contents/MacOS/$widget_executable" \
    "$mac_archive/dSYMs/AgentLimitsWidgetExtension.appex.dSYM" \
    "unsigned macOS widget" arm64 x86_64 || exit $?
validate_dsym_matches_binary \
    "$ios_app/$ios_executable" \
    "$ios_archive/dSYMs/AgentLimits.app.dSYM" \
    "unsigned iOS app" arm64 || exit $?
validate_dsym_matches_binary \
    "$watch_app/$watch_executable" \
    "$ios_archive/dSYMs/AgentLimitsWatch.app.dSYM" \
    "unsigned Watch app" arm64 arm64_32 || exit $?
if [[ "$(plutil -extract WKRunsIndependentlyOfCompanionApp raw \
        "$watch_info")" != "false" ]]; then
    echo "Watch app unexpectedly declares independent distribution" >&2
    exit 1
fi

verify_archive_has_no_signing_metadata "$mac_archive" "macOS" || exit $?
verify_archive_has_no_signing_metadata "$ios_archive" "iOS/watchOS" || exit $?
verify_linker_adhoc_bundle \
    "$mac_app" "$mac_executable" "macOS app" || exit $?
verify_linker_adhoc_bundle \
    "$widget" "$widget_executable" "macOS widget" || exit $?
verify_no_code_signature_for_architecture \
    "$ios_app" arm64 "iOS app" || exit $?
verify_no_code_signature_for_architecture \
    "$watch_app" arm64 "watchOS app" || exit $?
verify_no_code_signature_for_architecture \
    "$watch_app" arm64_32 "watchOS app" || exit $?

for manifest in \
    "$mac_app/Contents/Resources/PrivacyInfo.xcprivacy" \
    "$widget/Contents/Resources/PrivacyInfo.xcprivacy" \
    "$ios_app/PrivacyInfo.xcprivacy" \
    "$watch_app/PrivacyInfo.xcprivacy"; do
    plutil -lint "$manifest" >/dev/null
done

base_name="AgentLimitsForked-$version-$build"
mac_archive_output="$staging_dir/$base_name-macOS-unsigned.xcarchive"
ios_archive_output="$staging_dir/$base_name-iOS-watchOS-unsigned.xcarchive"
ditto "$mac_archive" "$mac_archive_output"
ditto "$ios_archive" "$ios_archive_output"

archive_manifest_dir="$staging_dir/ARCHIVE-MANIFESTS"
mkdir "$archive_manifest_dir"
mac_archive_manifest="$archive_manifest_dir/$base_name-macOS-unsigned.tree"
ios_archive_manifest="$archive_manifest_dir/$base_name-iOS-watchOS-unsigned.tree"
reference_app_manifest="$work_dir/mac-app-reference.tree"
create_tree_manifest "$mac_app" "$reference_app_manifest"
create_tree_manifest "$mac_archive" "$mac_archive_manifest"
create_tree_manifest "$ios_archive" "$ios_archive_manifest"
validate_tree_matches_manifest \
    "$mac_archive_output" \
    "$mac_archive_manifest" \
    "$work_dir/mac-archive-copy.tree" \
    "staged macOS archive" || exit $?
validate_tree_matches_manifest \
    "$ios_archive_output" \
    "$ios_archive_manifest" \
    "$work_dir/ios-archive-copy.tree" \
    "staged iOS/watchOS archive" || exit $?

mac_zip="$staging_dir/$base_name-macOS-unsigned.zip"
mac_dmg="$staging_dir/$base_name-macOS-unsigned.dmg"
mac_pkg="$staging_dir/$base_name-macOS-unsigned.pkg"
mac_archive_zip="$staging_dir/$base_name-macOS-unsigned.xcarchive.zip"
ios_archive_zip="$staging_dir/$base_name-iOS-watchOS-unsigned.xcarchive.zip"

ditto -c -k --sequesterRsrc --keepParent "$mac_app" "$mac_zip"
ditto -c -k --sequesterRsrc --keepParent \
    "$mac_archive_output" "$mac_archive_zip"
ditto -c -k --sequesterRsrc --keepParent \
    "$ios_archive_output" "$ios_archive_zip"

zip_extract="$work_dir/zip-extract"
mkdir -m 700 "$zip_extract"
ditto -x -k "$mac_zip" "$zip_extract"
validate_zip_container_root "$zip_extract" || exit $?
validate_tree_matches_manifest \
    "$validated_container_app" \
    "$reference_app_manifest" \
    "$work_dir/zip-app.tree" \
    "ZIP app" || exit $?

mac_archive_extract="$work_dir/mac-archive-extract"
mkdir -m 700 "$mac_archive_extract"
ditto -x -k "$mac_archive_zip" "$mac_archive_extract"
validate_single_directory_container_root \
    "$mac_archive_extract" "$(basename "$mac_archive_output")" || exit $?
validate_tree_matches_manifest \
    "$validated_container_app" \
    "$mac_archive_manifest" \
    "$work_dir/mac-archive-zip.tree" \
    "macOS archive ZIP" || exit $?

ios_archive_extract="$work_dir/ios-archive-extract"
mkdir -m 700 "$ios_archive_extract"
ditto -x -k "$ios_archive_zip" "$ios_archive_extract"
validate_single_directory_container_root \
    "$ios_archive_extract" "$(basename "$ios_archive_output")" || exit $?
validate_tree_matches_manifest \
    "$validated_container_app" \
    "$ios_archive_manifest" \
    "$work_dir/ios-archive-zip.tree" \
    "iOS/watchOS archive ZIP" || exit $?

echo "Building unsigned installer package..."
productbuild \
    --component "$mac_app" /Applications \
    "$mac_pkg" \
    >/dev/null
verify_unsigned_product_package "$mac_pkg" || exit $?
pkg_expanded="$work_dir/pkg-expanded"
pkgutil --expand-full "$mac_pkg" "$pkg_expanded"
validate_product_package_layout \
    "$pkg_expanded" "$version" "$build" || exit $?
validate_tree_matches_manifest \
    "$validated_container_app" \
    "$reference_app_manifest" \
    "$work_dir/pkg-app.tree" \
    "PKG payload app" || exit $?

dmg_root="$work_dir/dmg-root"
mkdir -m 700 "$dmg_root"
ditto "$mac_app" "$dmg_root/AgentLimitsForked.app"
ln -s /Applications "$dmg_root/Applications"
hdiutil create \
    -quiet \
    -volname "AgentLimits Forked" \
    -srcfolder "$dmg_root" \
    -format UDZO \
    -fs HFS+ \
    "$mac_dmg"
hdiutil verify "$mac_dmg" >/dev/null
verify_unsigned_disk_image "$mac_dmg" || exit $?

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
    "$mac_dmg" \
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
validate_tree_matches_manifest \
    "$validated_container_app" \
    "$reference_app_manifest" \
    "$work_dir/dmg-app.tree" \
    "DMG app" || exit $?
hdiutil detach "$dmg_attached_device" -quiet
dmg_attached_device=""

cat >"$staging_dir/BUILD-METADATA.txt" <<EOF
AgentLimits Forked $version ($build)
Built: $(date -u '+%Y-%m-%dT%H:%M:%SZ')
Git commit: $source_commit
Git state: clean; pre/post build fence passed
Build source: clean git archive snapshot
Xcode: $(xcodebuild -version | tr '\n' ' ')
macOS architectures: $mac_archs
macOS widget architectures: $widget_archs
iOS architectures: $ios_archs
watchOS architectures: $watch_archs
First-party signing: no Apple Team, certificate identity, or provisioning profile
macOS app/widget code: arm64 linker-ad-hoc; x86_64 unsigned
iOS/watchOS code: no code signature
PKG/DMG: no distribution signature
Third-party Sparkle code: upstream signatures retained
Container verification: ZIP, archive ZIPs, PKG, and DMG reopened and matched
Archive integrity: canonical tree manifests in ARCHIVE-MANIFESTS
Archive/product cardinality: passed
dSYM UUID and architecture identity: passed

These files are preflight artifacts only. Do not re-sign, upload, or publicly
distribute them. Rebuild with signing enabled for release. They will not install
normally on iPhone or Apple Watch. The Watch app is correctly embedded in the
iOS archive and must remain embedded in the eventual signed iOS IPA.
EOF

verify_source_unchanged
(
    cd "$staging_dir"
    shasum -a 256 \
        "$(basename "$mac_zip")" \
        "$(basename "$mac_dmg")" \
        "$(basename "$mac_pkg")" \
        "$(basename "$mac_archive_zip")" \
        "$(basename "$ios_archive_zip")" \
        "ARCHIVE-MANIFESTS/$(basename "$mac_archive_manifest")" \
        "ARCHIVE-MANIFESTS/$(basename "$ios_archive_manifest")" \
        BUILD-METADATA.txt \
        build-macOS.log \
        build-iOS-watchOS.log \
        > SHA256SUMS
)
verify_source_unchanged

publish_staged_directory \
    "$staging_dir" "$output_parent" "$output_name" || exit $?
staging_dir=""
rmdir "$staging_parent"
staging_parent=""

echo "Unsigned artifacts created at: $output_dir"
echo "Version: $version ($build)"
echo "macOS architectures: $mac_archs"
echo "iOS architectures: $ios_archs"
echo "watchOS architectures: $watch_archs"
