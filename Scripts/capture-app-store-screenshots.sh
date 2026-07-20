#!/bin/bash

set -euo pipefail

usage() {
    echo "Usage: $0 OUTPUT_DIRECTORY" >&2
    echo "Captures deterministic iPhone, iPad, and Apple Watch App Store screenshots." >&2
}

if [[ $# -ne 1 ]]; then
    usage
    exit 64
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
project_root="$(cd "$script_dir/.." && pwd)"
developer_dir="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
output_arg="$1"

if [[ ! -x "$developer_dir/usr/bin/xcodebuild" ]]; then
    echo "Xcode not found at $developer_dir" >&2
    exit 69
fi
if ! command -v jq >/dev/null 2>&1; then
    echo "jq is required to resolve simulators and write metadata." >&2
    exit 69
fi

case "$output_arg" in
    /*) ;;
    *) output_arg="$PWD/$output_arg" ;;
esac
output_parent="$(dirname "$output_arg")"
output_name="$(basename "$output_arg")"
mkdir -p "$output_parent"
output_parent="$(cd "$output_parent" && pwd -P)"
output_dir="$output_parent/$output_name"

if [[ -e "$output_dir" ]]; then
    echo "Refusing to overwrite existing path: $output_dir" >&2
    exit 73
fi

work_dir="$(mktemp -d "${TMPDIR:-/tmp}/AgentLimits-screenshots.XXXXXX")"
cleanup() {
    if [[ -n "${work_dir:-}" && -d "$work_dir" \
        && "$work_dir" == *"/AgentLimits-screenshots."* ]]; then
        rm -rf "$work_dir"
    fi
}
trap cleanup EXIT

export DEVELOPER_DIR="$developer_dir"

runtimes_json="$(xcrun simctl list runtimes available --json)"
devices_json="$(xcrun simctl list devices available --json)"

resolve_simulator() {
    local platform="$1"
    local device_name="$2"
    local available_runtimes
    local latest_version
    local latest_runtimes
    local runtime_count
    local runtime_id
    local matches
    local device_count
    local udid

    available_runtimes="$(
        jq -c --arg platform "$platform" '
            [.runtimes[]
                | select(
                    .platform == $platform
                    and .isAvailable == true
                )
                | {identifier, version}]
        ' <<<"$runtimes_json"
    )"
    if [[ "$(jq 'length' <<<"$available_runtimes")" -eq 0 ]]; then
        echo "No available $platform simulator runtime is installed." >&2
        return 1
    fi

    latest_version="$(
        jq -r '
            max_by(.version | split(".") | map(tonumber))
            | .version
        ' <<<"$available_runtimes"
    )"
    latest_runtimes="$(
        jq -c --arg version "$latest_version" '
            [.[] | select(.version == $version)]
        ' <<<"$available_runtimes"
    )"
    runtime_count="$(jq 'length' <<<"$latest_runtimes")"
    if [[ "$runtime_count" -ne 1 ]]; then
        echo "Expected one latest $platform $latest_version runtime; found $runtime_count." >&2
        return 1
    fi
    runtime_id="$(jq -r '.[0].identifier' <<<"$latest_runtimes")"

    matches="$(
        jq -c \
            --arg runtime "$runtime_id" \
            --arg name "$device_name" '
                [.devices[$runtime][]?
                    | select(
                        .name == $name
                        and .isAvailable == true
                    )
                    | {udid}]
            ' <<<"$devices_json"
    )"
    device_count="$(jq 'length' <<<"$matches")"
    if [[ "$device_count" -ne 1 ]]; then
        echo "Expected one available '$device_name' on $platform $latest_version; found $device_count." >&2
        jq -r --arg runtime "$runtime_id" '
            .devices[$runtime][]?
            | select(.isAvailable == true)
            | "  \(.name): \(.udid)"
        ' <<<"$devices_json" >&2
        return 1
    fi
    udid="$(jq -r '.[0].udid' <<<"$matches")"
    printf '%s\t%s\t%s\n' "$runtime_id" "$latest_version" "$udid"
}

IFS=$'\t' read -r ios_runtime ios_version iphone_udid < <(
    resolve_simulator "iOS" "iPhone 17 Pro Max"
)
IFS=$'\t' read -r ipad_runtime ipad_version ipad_udid < <(
    resolve_simulator "iOS" "iPad Pro 13-inch (M5)"
)
IFS=$'\t' read -r watch_runtime watch_version watch_udid < <(
    resolve_simulator "watchOS" "Apple Watch Series 11 (46mm)"
)

if [[ "$ios_runtime" != "$ipad_runtime" \
    || "$ios_version" != "$ipad_version" ]]; then
    echo "iPhone and iPad did not resolve to same latest iOS runtime." >&2
    exit 1
fi

echo "iPhone 17 Pro Max ($ios_version): $iphone_udid"
echo "iPad Pro 13-inch (M5) ($ipad_version): $ipad_udid"
echo "Apple Watch Series 11 (46mm) ($watch_version): $watch_udid"

run_mobile_screenshot_test() {
    local label="$1"
    local udid="$2"
    local result_bundle="$3"
    local derived_data="$4"
    local log_path="$5"

    echo "Capturing $label screenshot..."
    if ! xcodebuild test \
        -project "$project_root/AgentLimits.xcodeproj" \
        -scheme AgentLimitsiOS \
        -configuration Debug \
        -destination "platform=iOS Simulator,id=$udid" \
        -only-testing:AgentLimitsiOSUITests/AgentLimitsiOSUITests/testAppStoreCopilotAccountsScreenshot \
        -parallel-testing-enabled NO \
        -onlyUsePackageVersionsFromResolvedFile \
        -resultBundlePath "$result_bundle" \
        -derivedDataPath "$derived_data" \
        CODE_SIGNING_ALLOWED=NO \
        CODE_SIGNING_REQUIRED=NO \
        CODE_SIGN_IDENTITY= \
        DEVELOPMENT_TEAM= \
        COMPILER_INDEX_STORE_ENABLE=NO \
        SWIFT_TREAT_WARNINGS_AS_ERRORS=YES \
        GCC_TREAT_WARNINGS_AS_ERRORS=YES \
        >"$log_path" 2>&1; then
        tail -120 "$log_path" >&2
        return 1
    fi

    assert_test_result "$result_bundle" 1
}

assert_test_result() {
    local result_bundle="$1"
    local expected_count="$2"
    local summary
    local total_count
    local passed_count
    local result

    summary="$(
        xcrun xcresulttool get test-results summary \
            --path "$result_bundle"
    )"
    total_count="$(jq -r '.totalTestCount' <<<"$summary")"
    passed_count="$(jq -r '.passedTests' <<<"$summary")"
    result="$(jq -r '.result' <<<"$summary")"
    if [[ "$total_count" -ne "$expected_count" \
        || "$passed_count" -ne "$expected_count" \
        || "$result" != "Passed" ]]; then
        echo "Screenshot test result invalid: expected $expected_count passes; result=$result passed=$passed_count total=$total_count." >&2
        return 1
    fi
}

iphone_result="$work_dir/iPhone.xcresult"
ipad_result="$work_dir/iPad.xcresult"
watch_result="$work_dir/Watch.xcresult"

run_mobile_screenshot_test \
    "iPhone 17 Pro Max" \
    "$iphone_udid" \
    "$iphone_result" \
    "$work_dir/DerivedData-iPhone" \
    "$work_dir/iPhone.log"

run_mobile_screenshot_test \
    "iPad Pro 13-inch (M5)" \
    "$ipad_udid" \
    "$ipad_result" \
    "$work_dir/DerivedData-iPad" \
    "$work_dir/iPad.log"

echo "Capturing Apple Watch screenshots..."
if ! xcodebuild test \
    -project "$project_root/AgentLimits.xcodeproj" \
    -scheme AgentLimitsWatch \
    -configuration Debug \
    -destination "platform=watchOS Simulator,id=$watch_udid" \
    -only-testing:AgentLimitsWatchUITests/AgentLimitsWatchUITests/testAppStoreCopilotAccountsScreenshot \
    -only-testing:AgentLimitsWatchUITests/AgentLimitsWatchUITests/testAppStoreCopilotDetailScreenshot \
    -parallel-testing-enabled NO \
    -onlyUsePackageVersionsFromResolvedFile \
    -resultBundlePath "$watch_result" \
    -derivedDataPath "$work_dir/DerivedData-Watch" \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGN_IDENTITY= \
    DEVELOPMENT_TEAM= \
    COMPILER_INDEX_STORE_ENABLE=NO \
    SWIFT_TREAT_WARNINGS_AS_ERRORS=YES \
    GCC_TREAT_WARNINGS_AS_ERRORS=YES \
    >"$work_dir/Watch.log" 2>&1; then
    tail -120 "$work_dir/Watch.log" >&2
    exit 1
fi
assert_test_result "$watch_result" 2

staging_dir="$work_dir/output"
mkdir -p "$staging_dir"

export_attachment() {
    local result_bundle="$1"
    local attachment_name="$2"
    local output_file="$3"
    local expected_width="$4"
    local expected_height="$5"
    local export_dir="$work_dir/export-$(basename "$output_file" .jpg)"
    local attachment_manifest
    local matching_files
    local match_count
    local exported_name
    local source_file
    local source_width
    local source_height
    local output_width
    local output_height
    local has_alpha

    mkdir -p "$export_dir"
    xcrun xcresulttool export attachments \
        --path "$result_bundle" \
        --output-path "$export_dir" \
        >/dev/null
    attachment_manifest="$export_dir/manifest.json"
    matching_files="$(
        jq -c --arg name "$attachment_name" '
            [.[].attachments[]
                | select(
                    .suggestedHumanReadableName == $name
                    or .suggestedHumanReadableName == ($name + ".png")
                    or (
                        .suggestedHumanReadableName
                            | startswith($name + "_")
                            and endswith(".png")
                    )
                )
                | .exportedFileName]
        ' "$attachment_manifest"
    )"
    match_count="$(jq 'length' <<<"$matching_files")"
    if [[ "$match_count" -ne 1 ]]; then
        echo "Expected one '$attachment_name' attachment; found $match_count." >&2
        jq -r '.[].attachments[].suggestedHumanReadableName' \
            "$attachment_manifest" >&2
        return 1
    fi
    exported_name="$(jq -r '.[0]' <<<"$matching_files")"
    source_file="$export_dir/$exported_name"

    source_width="$(
        sips -g pixelWidth "$source_file" 2>/dev/null \
            | awk '/pixelWidth:/ {print $2}'
    )"
    source_height="$(
        sips -g pixelHeight "$source_file" 2>/dev/null \
            | awk '/pixelHeight:/ {print $2}'
    )"
    if [[ "$source_width" != "$expected_width" \
        || "$source_height" != "$expected_height" ]]; then
        echo "Unexpected screenshot dimensions for $attachment_name: ${source_width}x${source_height}; expected ${expected_width}x${expected_height}." >&2
        return 1
    fi

    sips \
        -s format jpeg \
        -s formatOptions 95 \
        "$source_file" \
        --out "$output_file" \
        >/dev/null
    output_width="$(
        sips -g pixelWidth "$output_file" 2>/dev/null \
            | awk '/pixelWidth:/ {print $2}'
    )"
    output_height="$(
        sips -g pixelHeight "$output_file" 2>/dev/null \
            | awk '/pixelHeight:/ {print $2}'
    )"
    has_alpha="$(
        sips -g hasAlpha "$output_file" 2>/dev/null \
            | awk '/hasAlpha:/ {print $2}'
    )"
    if [[ "$output_width" != "$expected_width" \
        || "$output_height" != "$expected_height" \
        || "$has_alpha" != "no" ]]; then
        echo "Converted JPEG failed validation: $output_file" >&2
        return 1
    fi
}

export_attachment \
    "$iphone_result" \
    "app-store-copilot-accounts" \
    "$staging_dir/iphone-6.9-01-copilot-accounts.jpg" \
    1320 \
    2868
export_attachment \
    "$ipad_result" \
    "app-store-copilot-accounts" \
    "$staging_dir/ipad-13-01-copilot-accounts.jpg" \
    2064 \
    2752
export_attachment \
    "$watch_result" \
    "app-store-watch-copilot-accounts" \
    "$staging_dir/watch-46mm-01-copilot-accounts.jpg" \
    416 \
    496
export_attachment \
    "$watch_result" \
    "app-store-watch-session-detail" \
    "$staging_dir/watch-46mm-02-session-detail.jpg" \
    416 \
    496

echo "Building unsigned Release app for fixture-marker guard..."
release_derived_data="$work_dir/DerivedData-Release"
if ! xcodebuild build \
    -project "$project_root/AgentLimits.xcodeproj" \
    -scheme AgentLimitsiOS \
    -configuration Release \
    -destination generic/platform=iOS \
    -onlyUsePackageVersionsFromResolvedFile \
    -derivedDataPath "$release_derived_data" \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGN_IDENTITY= \
    DEVELOPMENT_TEAM= \
    COMPILER_INDEX_STORE_ENABLE=NO \
    SWIFT_TREAT_WARNINGS_AS_ERRORS=YES \
    GCC_TREAT_WARNINGS_AS_ERRORS=YES \
    >"$work_dir/Release.log" 2>&1; then
    tail -120 "$work_dir/Release.log" >&2
    exit 1
fi

release_ios_app="$release_derived_data/Build/Products/Release-iphoneos/AgentLimits.app"
release_watch_app="$release_ios_app/Watch/AgentLimitsWatch.app"
for app_path in "$release_ios_app" "$release_watch_app"; do
    if [[ ! -d "$app_path" ]]; then
        echo "Release guard app missing: $app_path" >&2
        exit 1
    fi
    executable="$(plutil -extract CFBundleExecutable raw "$app_path/Info.plist")"
    binary="$app_path/$executable"
    strings_file="$work_dir/$executable.strings"
    LC_ALL=C strings -a "$binary" >"$strings_file"
    for marker in \
        "-ui-testing-sample-data" \
        "agentlimits-app-store-screenshot-fixture-v1" \
        "app-store-screenshot-personal-copilot-v1" \
        "app-store-screenshot-work-copilot-v1"; do
        if grep -Fq -- "$marker" "$strings_file"; then
            echo "Release binary contains screenshot fixture marker: $marker ($binary)" >&2
            exit 1
        fi
    done
done

(
    cd "$staging_dir"
    shasum -a 256 \
        iphone-6.9-01-copilot-accounts.jpg \
        ipad-13-01-copilot-accounts.jpg \
        watch-46mm-01-copilot-accounts.jpg \
        watch-46mm-02-session-detail.jpg \
        > SHA256SUMS
)

iphone_sha="$(shasum -a 256 "$staging_dir/iphone-6.9-01-copilot-accounts.jpg" | awk '{print $1}')"
ipad_sha="$(shasum -a 256 "$staging_dir/ipad-13-01-copilot-accounts.jpg" | awk '{print $1}')"
watch_root_sha="$(shasum -a 256 "$staging_dir/watch-46mm-01-copilot-accounts.jpg" | awk '{print $1}')"
watch_detail_sha="$(shasum -a 256 "$staging_dir/watch-46mm-02-session-detail.jpg" | awk '{print $1}')"
git_dirty=false
if [[ -n "$(git -C "$project_root" status --porcelain)" ]]; then
    git_dirty=true
fi
xcode_version="$(xcodebuild -version | paste -sd ' ' -)"

jq -n \
    --arg generatedAt "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    --arg gitCommit "$(git -C "$project_root" rev-parse HEAD)" \
    --argjson gitDirty "$git_dirty" \
    --arg xcode "$xcode_version" \
    --arg iosRuntime "$ios_runtime" \
    --arg iosVersion "$ios_version" \
    --arg iphoneUDID "$iphone_udid" \
    --arg ipadUDID "$ipad_udid" \
    --arg watchRuntime "$watch_runtime" \
    --arg watchVersion "$watch_version" \
    --arg watchUDID "$watch_udid" \
    --arg iphoneSHA "$iphone_sha" \
    --arg ipadSHA "$ipad_sha" \
    --arg watchRootSHA "$watch_root_sha" \
    --arg watchDetailSHA "$watch_detail_sha" '
    {
        schemaVersion: 1,
        generatedAt: $generatedAt,
        source: {
            gitCommit: $gitCommit,
            gitDirty: $gitDirty,
            xcode: $xcode
        },
        fixture: {
            data: "fictional, deterministic, and local-only",
            externalServicesUsed: false,
            accounts: [
                {label: "Personal Codex", provider: "Codex"},
                {label: "Personal Claude", provider: "Claude Code"},
                {
                    label: "Personal Copilot",
                    provider: "GitHub Copilot",
                    working: 3,
                    waiting: 2,
                    open: 5
                },
                {
                    label: "Work Copilot",
                    provider: "GitHub Copilot",
                    working: 6,
                    waiting: 2,
                    open: 8
                }
            ]
        },
        screenshots: [
            {
                file: "iphone-6.9-01-copilot-accounts.jpg",
                attachment: "app-store-copilot-accounts",
                simulator: "iPhone 17 Pro Max",
                udid: $iphoneUDID,
                runtime: $iosRuntime,
                runtimeVersion: $iosVersion,
                width: 1320,
                height: 2868,
                sha256: $iphoneSHA
            },
            {
                file: "ipad-13-01-copilot-accounts.jpg",
                attachment: "app-store-copilot-accounts",
                simulator: "iPad Pro 13-inch (M5)",
                udid: $ipadUDID,
                runtime: $iosRuntime,
                runtimeVersion: $iosVersion,
                width: 2064,
                height: 2752,
                sha256: $ipadSHA
            },
            {
                file: "watch-46mm-01-copilot-accounts.jpg",
                attachment: "app-store-watch-copilot-accounts",
                simulator: "Apple Watch Series 11 (46mm)",
                udid: $watchUDID,
                runtime: $watchRuntime,
                runtimeVersion: $watchVersion,
                width: 416,
                height: 496,
                sha256: $watchRootSHA
            },
            {
                file: "watch-46mm-02-session-detail.jpg",
                attachment: "app-store-watch-session-detail",
                simulator: "Apple Watch Series 11 (46mm)",
                udid: $watchUDID,
                runtime: $watchRuntime,
                runtimeVersion: $watchVersion,
                width: 416,
                height: 496,
                sha256: $watchDetailSHA
            }
        ],
        releaseGuard: {
            checkedBinaries: ["AgentLimits", "AgentLimitsWatch"],
            fixtureMarkersFound: false
        }
    }
' >"$staging_dir/MANIFEST.json"

ditto "$staging_dir" "$output_dir"
echo "App Store screenshots created at: $output_dir"
