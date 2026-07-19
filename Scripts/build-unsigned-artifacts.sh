#!/bin/bash

set -euo pipefail

usage() {
    echo "Usage: $0 OUTPUT_DIRECTORY" >&2
    echo "Builds non-distributable macOS and iOS/watchOS preflight artifacts." >&2
}

if [[ $# -ne 1 ]]; then
    usage
    exit 64
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
project_root="$(cd "$script_dir/.." && pwd)"
output_dir="$1"
developer_dir="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

if [[ ! -x "$developer_dir/usr/bin/xcodebuild" ]]; then
    echo "Xcode not found at $developer_dir" >&2
    exit 69
fi

if [[ -e "$output_dir" ]]; then
    echo "Refusing to overwrite existing path: $output_dir" >&2
    exit 73
fi

mkdir -p "$output_dir"
output_dir="$(cd "$output_dir" && pwd)"
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/AgentLimits-distribution.XXXXXX")"

cleanup() {
    if [[ -n "${work_dir:-}" && -d "$work_dir" \
        && "$work_dir" == *"/AgentLimits-distribution."* ]]; then
        rm -rf "$work_dir"
    fi
}
trap cleanup EXIT

export DEVELOPER_DIR="$developer_dir"

mac_archive="$work_dir/AgentLimits-macOS.xcarchive"
ios_archive="$work_dir/AgentLimits-iOS-watchOS.xcarchive"
mac_log="$output_dir/build-macOS.log"
ios_log="$output_dir/build-iOS-watchOS.log"
git_state="clean"
if [[ -n "$(git -C "$project_root" status --porcelain)" ]]; then
    git_state="dirty"
fi

echo "Building unsigned universal macOS archive..."
if ! xcodebuild archive \
    -project "$project_root/AgentLimits.xcodeproj" \
    -scheme AgentLimits \
    -configuration Release \
    -destination 'generic/platform=macOS' \
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

echo "Building unsigned iOS archive with embedded Watch app..."
if ! xcodebuild archive \
    -project "$project_root/AgentLimits.xcodeproj" \
    -scheme AgentLimitsiOS \
    -configuration Release \
    -destination 'generic/platform=iOS' \
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

mac_app="$mac_archive/Products/Applications/AgentLimitsForked.app"
ios_app="$ios_archive/Products/Applications/AgentLimits.app"
watch_app="$ios_app/Watch/AgentLimitsWatch.app"
widget="$mac_app/Contents/PlugIns/AgentLimitsWidgetExtension.appex"

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
ios_info="$ios_app/Info.plist"
watch_info="$watch_app/Info.plist"

version="$(plutil -extract CFBundleShortVersionString raw "$mac_info")"
build="$(plutil -extract CFBundleVersion raw "$mac_info")"

if [[ "$(plutil -extract CFBundleShortVersionString raw "$ios_info")" != "$version" \
    || "$(plutil -extract CFBundleVersion raw "$ios_info")" != "$build" \
    || "$(plutil -extract CFBundleShortVersionString raw "$watch_info")" != "$version" \
    || "$(plutil -extract CFBundleVersion raw "$watch_info")" != "$build" ]]; then
    echo "macOS, iOS, and watchOS version/build values are not synchronized" >&2
    exit 1
fi

if [[ "$(plutil -extract CFBundleIdentifier raw "$mac_info")" \
        != "com.jimboha.agentlimits.macos" \
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
ios_executable="$(plutil -extract CFBundleExecutable raw "$ios_info")"
watch_executable="$(plutil -extract CFBundleExecutable raw "$watch_info")"
widget_info="$widget/Contents/Info.plist"
widget_executable="$(plutil -extract CFBundleExecutable raw "$widget_info")"
mac_archs="$(lipo -archs "$mac_app/Contents/MacOS/$mac_executable")"
widget_archs="$(lipo -archs "$widget/Contents/MacOS/$widget_executable")"
ios_archs="$(lipo -archs "$ios_app/$ios_executable")"
watch_archs="$(lipo -archs "$watch_app/$watch_executable")"

if [[ " $mac_archs " != *" arm64 "* || " $mac_archs " != *" x86_64 "* ]]; then
    echo "macOS app is not universal: $mac_archs" >&2
    exit 1
fi
if [[ " $widget_archs " != *" arm64 "* \
    || " $widget_archs " != *" x86_64 "* ]]; then
    echo "macOS widget is not universal: $widget_archs" >&2
    exit 1
fi
if [[ " $ios_archs " != *" arm64 "* ]]; then
    echo "iOS app lacks the arm64 device architecture: $ios_archs" >&2
    exit 1
fi
if [[ " $watch_archs " != *" arm64_32 "* || " $watch_archs " != *" arm64 "* ]]; then
    echo "Watch app lacks expected device architectures: $watch_archs" >&2
    exit 1
fi
if [[ "$(plutil -extract WKRunsIndependentlyOfCompanionApp raw \
        "$watch_info")" != "false" ]]; then
    echo "Watch app unexpectedly declares independent distribution" >&2
    exit 1
fi

for manifest in \
    "$mac_app/Contents/Resources/PrivacyInfo.xcprivacy" \
    "$widget/Contents/Resources/PrivacyInfo.xcprivacy" \
    "$ios_app/PrivacyInfo.xcprivacy" \
    "$watch_app/PrivacyInfo.xcprivacy"; do
    plutil -lint "$manifest" >/dev/null
done

base_name="AgentLimitsForked-$version-$build"
mac_archive_output="$output_dir/$base_name-macOS-unsigned.xcarchive"
ios_archive_output="$output_dir/$base_name-iOS-watchOS-unsigned.xcarchive"

ditto "$mac_archive" "$mac_archive_output"
ditto "$ios_archive" "$ios_archive_output"

mac_zip="$output_dir/$base_name-macOS-unsigned.zip"
mac_dmg="$output_dir/$base_name-macOS-unsigned.dmg"
mac_pkg="$output_dir/$base_name-macOS-unsigned.pkg"
ios_archive_zip="$output_dir/$base_name-iOS-watchOS-unsigned.xcarchive.zip"

ditto -c -k --sequesterRsrc --keepParent "$mac_app" "$mac_zip"
ditto -c -k --sequesterRsrc --keepParent "$ios_archive" "$ios_archive_zip"

dmg_root="$work_dir/dmg-root"
mkdir -p "$dmg_root"
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

pkgbuild \
    --component "$mac_app" \
    --install-location /Applications \
    "$mac_pkg" \
    >/dev/null

cat >"$output_dir/BUILD-METADATA.txt" <<EOF
AgentLimits Forked $version ($build)
Built: $(date -u '+%Y-%m-%dT%H:%M:%SZ')
Git commit: $(git -C "$project_root" rev-parse HEAD)
Git state: $git_state
Xcode: $(xcodebuild -version | tr '\n' ' ')
macOS architectures: $mac_archs
macOS widget architectures: $widget_archs
iOS architectures: $ios_archs
watchOS architectures: $watch_archs
Signing: UNSIGNED

These files are preflight artifacts only. Do not re-sign, upload, or publicly
distribute them. Rebuild with signing enabled for release. They will not install
normally on iPhone or Apple Watch. The Watch app is correctly embedded in the
iOS archive and must remain embedded in the eventual signed iOS IPA.
EOF

(
    cd "$output_dir"
    shasum -a 256 \
        "$(basename "$mac_zip")" \
        "$(basename "$mac_dmg")" \
        "$(basename "$mac_pkg")" \
        "$(basename "$ios_archive_zip")" \
        > SHA256SUMS
)

echo "Unsigned artifacts created at: $output_dir"
echo "Version: $version ($build)"
echo "macOS architectures: $mac_archs"
echo "iOS architectures: $ios_archs"
echo "watchOS architectures: $watch_archs"
