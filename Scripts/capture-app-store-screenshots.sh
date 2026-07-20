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

work_dir="$(mktemp -d "${TMPDIR:-/tmp}/AgentLimits-screenshots.XXXXXX")"
output_reserved=false
output_published=false
simulator_states_restored=true
simulator_udids=()
simulator_initial_states=()
simulator_appearances=()
simulator_content_sizes=()
simulator_contrasts=()
simulator_status_files=()
simulator_status_supported=()
simulator_mutated=()
simulator_restored=()

device_state() {
    local udid="$1"
    xcrun simctl list devices --json \
        | jq -r --arg udid "$udid" '
            [.devices[][] | select(.udid == $udid) | .state]
            | if length == 1 then .[0] else "unknown" end
        '
}

data_network_name() {
    case "$1" in
        0) echo "hide" ;;
        1) echo "wifi" ;;
        6) echo "3g" ;;
        7) echo "4g" ;;
        8) echo "lte" ;;
        9) echo "lte-a" ;;
        10) echo "lte+" ;;
        11) echo "5g" ;;
        12) echo "5g+" ;;
        13) echo "5g-uwb" ;;
        14) echo "5g-uc" ;;
        *) return 1 ;;
    esac
}

network_mode_name() {
    case "$1" in
        0) echo "notSupported" ;;
        1) echo "searching" ;;
        2) echo "failed" ;;
        3) echo "active" ;;
        *) return 1 ;;
    esac
}

wifi_mode_name() {
    case "$1" in
        1) echo "searching" ;;
        2) echo "failed" ;;
        3) echo "active" ;;
        *) return 1 ;;
    esac
}

battery_state_name() {
    case "$1" in
        0) echo "discharging" ;;
        1) echo "charging" ;;
        2) echo "charged" ;;
        *) return 1 ;;
    esac
}

validate_status_bar_snapshot() {
    local snapshot="$1"
    local value
    local wifi_mode_code

    if grep -Ev '^(Current Status Bar Overrides:|=+|Time:.*|DataNetworkType:.*|WiFi Mode:.*|Cell Mode:.*|Operator Name:.*|Battery State:.*|[[:space:]]*)$' \
        "$snapshot" >/dev/null; then
        return 1
    fi
    if grep -q '^Time:' "$snapshot"; then
        value="$(
            LC_ALL=en_US.UTF-8 sed -nE \
                's/^Time: (.*[^[:space:]])[[:space:]]*$/\1/p' \
                "$snapshot"
        )"
        [[ -n "$value" ]] || return 1
    fi
    if grep -q '^DataNetworkType:' "$snapshot"; then
        value="$(sed -nE 's/^DataNetworkType: ([0-9]+)$/\1/p' "$snapshot")"
        [[ -n "$value" ]] || return 1
        data_network_name "$value" >/dev/null || return 1
    fi
    if grep -q '^WiFi Mode:' "$snapshot"; then
        value="$(sed -nE 's/^WiFi Mode: ([0-9]+), WiFi Bars: ([0-9]+)$/\1/p' "$snapshot")"
        [[ -n "$value" ]] || return 1
        if [[ "$value" != "0" ]]; then
            wifi_mode_name "$value" >/dev/null || return 1
        fi
        wifi_mode_code="$value"
        value="$(sed -nE 's/^WiFi Mode: ([0-9]+), WiFi Bars: ([0-9]+)$/\2/p' "$snapshot")"
        [[ "$value" =~ ^[0-3]$ ]] || return 1
        if [[ "$wifi_mode_code" == "0" && "$value" != "0" ]]; then
            return 1
        fi
    fi
    if grep -q '^Cell Mode:' "$snapshot"; then
        value="$(sed -nE 's/^Cell Mode: ([0-9]+), Cell Bars: ([0-9]+)$/\1/p' "$snapshot")"
        [[ -n "$value" ]] || return 1
        network_mode_name "$value" >/dev/null || return 1
        value="$(sed -nE 's/^Cell Mode: ([0-9]+), Cell Bars: ([0-9]+)$/\2/p' "$snapshot")"
        [[ "$value" =~ ^[0-4]$ ]] || return 1
    fi
    if grep -q '^Battery State:' "$snapshot"; then
        value="$(sed -nE 's/^Battery State: ([0-9]+), Battery Level: ([0-9]+), Not Charging: ([0-9]+)$/\1/p' "$snapshot")"
        [[ -n "$value" ]] || return 1
        battery_state_name "$value" >/dev/null || return 1
        value="$(sed -nE 's/^Battery State: ([0-9]+), Battery Level: ([0-9]+), Not Charging: ([0-9]+)$/\2/p' "$snapshot")"
        [[ "$value" =~ ^([0-9]|[1-9][0-9]|100)$ ]] || return 1
    fi
    return 0
}

restore_status_bar_snapshot() {
    local udid="$1"
    local snapshot="$2"
    local time_value
    local data_network_code
    local wifi_mode_code
    local wifi_bars
    local cell_mode_code
    local cell_bars
    local operator_name
    local battery_state_code
    local battery_level
    local args=()

    xcrun simctl status_bar "$udid" clear

    if grep -q '^Time:' "$snapshot"; then
        time_value="$(
            LC_ALL=en_US.UTF-8 sed -nE \
                's/^Time: (.*[^[:space:]])[[:space:]]*$/\1/p' \
                "$snapshot"
        )"
        [[ -n "$time_value" ]] && args+=(--time "$time_value")
    fi
    if grep -q '^DataNetworkType:' "$snapshot"; then
        data_network_code="$(
            sed -nE 's/^DataNetworkType: ([0-9]+)$/\1/p' "$snapshot"
        )"
        args+=(--dataNetwork "$(data_network_name "$data_network_code")")
    fi
    if grep -q '^WiFi Mode:' "$snapshot"; then
        wifi_mode_code="$(
            sed -nE 's/^WiFi Mode: ([0-9]+), WiFi Bars: ([0-9]+)$/\1/p' \
                "$snapshot"
        )"
        wifi_bars="$(
            sed -nE 's/^WiFi Mode: ([0-9]+), WiFi Bars: ([0-9]+)$/\2/p' \
                "$snapshot"
        )"
        if [[ "$wifi_mode_code" != "0" ]]; then
            args+=(
                --wifiMode "$(wifi_mode_name "$wifi_mode_code")"
                --wifiBars "$wifi_bars"
            )
        fi
    fi
    if grep -q '^Cell Mode:' "$snapshot"; then
        cell_mode_code="$(
            sed -nE 's/^Cell Mode: ([0-9]+), Cell Bars: ([0-9]+)$/\1/p' \
                "$snapshot"
        )"
        cell_bars="$(
            sed -nE 's/^Cell Mode: ([0-9]+), Cell Bars: ([0-9]+)$/\2/p' \
                "$snapshot"
        )"
        args+=(
            --cellularMode "$(network_mode_name "$cell_mode_code")"
            --cellularBars "$cell_bars"
        )
    fi
    if grep -q '^Operator Name:' "$snapshot"; then
        operator_name="$(sed -n 's/^Operator Name: //p' "$snapshot")"
        args+=(--operatorName "$operator_name")
    fi
    if grep -q '^Battery State:' "$snapshot"; then
        battery_state_code="$(
            sed -nE 's/^Battery State: ([0-9]+), Battery Level: ([0-9]+), Not Charging: ([0-9]+)$/\1/p' \
                "$snapshot"
        )"
        battery_level="$(
            sed -nE 's/^Battery State: ([0-9]+), Battery Level: ([0-9]+), Not Charging: ([0-9]+)$/\2/p' \
                "$snapshot"
        )"
        args+=(
            --batteryState "$(battery_state_name "$battery_state_code")"
            --batteryLevel "$battery_level"
        )
    fi
    if [[ "${#args[@]}" -gt 0 ]]; then
        xcrun simctl status_bar "$udid" override "${args[@]}"
    fi
}

restore_simulator_state() {
    local index="$1"
    local udid="${simulator_udids[$index]}"
    local initial_state="${simulator_initial_states[$index]}"
    local current_state
    local restored_status_file="$work_dir/restored-status-$udid.txt"

    if [[ "${simulator_restored[$index]}" == "true" ]]; then
        return 0
    fi

    current_state="$(device_state "$udid")"
    if [[ "${simulator_mutated[$index]}" == "true" \
        || "$initial_state" == "Booted" ]]; then
        if [[ "$current_state" != "Booted" ]]; then
            xcrun simctl boot "$udid" 2>/dev/null || true
            xcrun simctl bootstatus "$udid" -b >/dev/null
        fi
    fi

    if [[ "${simulator_mutated[$index]}" == "true" ]]; then
        if [[ "${simulator_appearances[$index]}" != "unsupported" ]]; then
            xcrun simctl ui "$udid" appearance \
                "${simulator_appearances[$index]}"
        fi
        if [[ "${simulator_content_sizes[$index]}" != "unsupported" ]]; then
            xcrun simctl ui "$udid" content_size \
                "${simulator_content_sizes[$index]}"
        fi
        if [[ "${simulator_contrasts[$index]}" != "unsupported" ]]; then
            xcrun simctl ui "$udid" increase_contrast \
                "${simulator_contrasts[$index]}"
        fi
        if [[ "${simulator_status_supported[$index]}" == "true" ]]; then
            restore_status_bar_snapshot \
                "$udid" \
                "${simulator_status_files[$index]}"
        fi
        if [[ "$(xcrun simctl ui "$udid" appearance)" \
                != "${simulator_appearances[$index]}" \
            || "$(xcrun simctl ui "$udid" content_size)" \
                != "${simulator_content_sizes[$index]}" \
            || "$(xcrun simctl ui "$udid" increase_contrast)" \
                != "${simulator_contrasts[$index]}" ]]; then
            echo "Simulator UI settings did not restore exactly: $udid" >&2
            return 1
        fi
        xcrun simctl status_bar "$udid" list >"$restored_status_file"
        if ! cmp -s \
            "${simulator_status_files[$index]}" \
            "$restored_status_file"; then
            echo "Simulator status-bar overrides did not restore exactly: $udid" >&2
            return 1
        fi
    fi

    current_state="$(device_state "$udid")"
    if [[ "$initial_state" == "Shutdown" \
        && "$current_state" != "Shutdown" ]]; then
        xcrun simctl shutdown "$udid"
        current_state="$(device_state "$udid")"
    fi
    if [[ "$current_state" != "$initial_state" ]]; then
        echo "Simulator boot state did not restore exactly: $udid" >&2
        return 1
    fi
    simulator_restored[index]=true
}

restore_all_simulator_states() {
    local index
    local failed=0

    if [[ "$simulator_states_restored" == "true" ]]; then
        return 0
    fi
    for ((index=${#simulator_udids[@]} - 1; index >= 0; index--)); do
        if ! restore_simulator_state "$index"; then
            echo "Could not restore simulator state: ${simulator_udids[$index]}" >&2
            failed=1
        fi
    done
    if [[ "$failed" -eq 0 ]]; then
        simulator_states_restored=true
    fi
    return "$failed"
}

cleanup() {
    local exit_status=$?
    local restore_status=0

    trap - EXIT
    set +e
    restore_all_simulator_states
    restore_status=$?
    if [[ "$output_reserved" == "true" \
        && "$output_published" != "true" ]]; then
        if ! rmdir "$output_dir" 2>/dev/null; then
            echo "Reserved output directory retained because it is not empty: $output_dir" >&2
        fi
    fi
    if [[ -n "${work_dir:-}" && -d "$work_dir" \
        && "$work_dir" == *"/AgentLimits-screenshots."* ]]; then
        rm -rf "$work_dir"
    fi
    if [[ "$restore_status" -ne 0 && "$exit_status" -eq 0 ]]; then
        exit_status=1
    fi
    exit "$exit_status"
}
trap cleanup EXIT

if ! mkdir -m 700 "$output_dir" 2>/dev/null; then
    if [[ -e "$output_dir" || -L "$output_dir" ]]; then
        echo "Refusing to overwrite existing path: $output_dir" >&2
    else
        echo "Could not reserve output directory: $output_dir" >&2
    fi
    exit 73
fi
output_reserved=true

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

assert_simulator_presentation() {
    local udid="$1"
    local role="$2"
    local status_supported="$3"
    local status
    local displayed_time

    if [[ "$role" == "watch" ]]; then
        if [[ "$(xcrun simctl ui "$udid" appearance)" != "unsupported" \
            || "$(xcrun simctl ui "$udid" content_size)" != "unsupported" \
            || "$(xcrun simctl ui "$udid" increase_contrast)" \
                != "unsupported" ]]; then
            echo "Unexpected Watch simulator presentation support: $udid" >&2
            return 1
        fi
    elif [[ "$(xcrun simctl ui "$udid" appearance)" != "light" \
        || "$(xcrun simctl ui "$udid" content_size)" != "large" \
        || "$(xcrun simctl ui "$udid" increase_contrast)" != "disabled" ]]; then
        echo "Simulator presentation settings changed before capture: $udid" >&2
        return 1
    fi

    status="$(xcrun simctl status_bar "$udid" list)"
    if [[ "$status_supported" == "true" ]]; then
        displayed_time="$(
            LC_ALL=en_US.UTF-8 sed -nE \
                's/^Time: (.*[^[:space:]])[[:space:]]*$/\1/p' \
                <<<"$status"
        )"
        [[ "$displayed_time" == "9:41" ]]
        grep -q '^Battery State: 2, Battery Level: 100,' <<<"$status"
    elif [[ "$role" != "watch" ]]; then
        echo "Status-bar normalization unavailable for $role: $udid" >&2
        return 1
    fi
    case "$role" in
        iphone)
            [[ "$status_supported" == "true" ]]
            grep -q '^DataNetworkType: 11$' <<<"$status"
            grep -q '^WiFi Mode: 3, WiFi Bars: 3$' <<<"$status"
            grep -q '^Cell Mode: 3, Cell Bars: 4$' <<<"$status"
            ;;
        ipad)
            [[ "$status_supported" == "true" ]]
            grep -q '^DataNetworkType: 1$' <<<"$status"
            grep -q '^WiFi Mode: 3, WiFi Bars: 3$' <<<"$status"
            if grep -q '^Cell Mode:' <<<"$status"; then
                echo "iPad screenshot simulator unexpectedly shows cellular status." >&2
                return 1
            fi
            ;;
        watch) ;;
        *)
            echo "Unknown screenshot simulator role: $role" >&2
            return 1
            ;;
    esac
}

normalize_simulator_presentation() {
    local role="$1"
    local udid="$2"
    local index="${#simulator_udids[@]}"
    local initial_state
    local appearance
    local content_size
    local contrast
    local status_file="$work_dir/status-$udid.txt"
    local status_probe_file="$work_dir/status-probe-$udid.txt"
    local status_supported=true
    local fixed_time="2026-01-01T09:41:00.000-08:00"

    initial_state="$(
        jq -r --arg udid "$udid" '
            [.devices[][] | select(.udid == $udid) | .state]
            | if length == 1 then .[0] else "unknown" end
        ' <<<"$devices_json"
    )"
    if [[ "$initial_state" != "Booted" \
        && "$initial_state" != "Shutdown" ]]; then
        echo "Unsupported initial simulator state for $udid: $initial_state" >&2
        return 1
    fi

    simulator_udids+=("$udid")
    simulator_initial_states+=("$initial_state")
    simulator_appearances+=("")
    simulator_content_sizes+=("")
    simulator_contrasts+=("")
    simulator_status_files+=("$status_file")
    simulator_status_supported+=("false")
    simulator_mutated+=("false")
    simulator_restored+=("false")
    simulator_states_restored=false

    if [[ "$initial_state" != "Booted" ]]; then
        xcrun simctl boot "$udid" 2>/dev/null || true
    fi
    xcrun simctl bootstatus "$udid" -b >/dev/null

    appearance="$(xcrun simctl ui "$udid" appearance)"
    content_size="$(xcrun simctl ui "$udid" content_size)"
    contrast="$(xcrun simctl ui "$udid" increase_contrast)"
    case "$appearance" in light|dark|unsupported) ;; *)
        echo "Cannot preserve simulator appearance '$appearance': $udid" >&2
        return 1
    esac
    case "$content_size" in
        extra-small|small|medium|large|extra-large|extra-extra-large|extra-extra-extra-large|accessibility-medium|accessibility-large|accessibility-extra-large|accessibility-extra-extra-large|accessibility-extra-extra-extra-large|unsupported) ;;
        *)
            echo "Cannot preserve simulator content size '$content_size': $udid" >&2
            return 1
            ;;
    esac
    case "$contrast" in enabled|disabled|unsupported) ;; *)
        echo "Cannot preserve simulator contrast '$contrast': $udid" >&2
        return 1
    esac
    xcrun simctl status_bar "$udid" list >"$status_file"
    if ! validate_status_bar_snapshot "$status_file"; then
        echo "Cannot preserve existing status-bar overrides: $udid" >&2
        return 1
    fi

    simulator_appearances[index]="$appearance"
    simulator_content_sizes[index]="$content_size"
    simulator_contrasts[index]="$contrast"
    simulator_mutated[index]=true

    if [[ "$role" == "watch" ]]; then
        if xcrun simctl status_bar "$udid" override \
            --time "$fixed_time" >"$status_probe_file" 2>&1; then
            status_supported=true
        elif grep -q 'Status bar overrides not supported on this platform' \
            "$status_probe_file"; then
            status_supported=false
            echo "Watch simulator does not support status-bar overrides; preserving native status." >&2
        else
            cat "$status_probe_file" >&2
            return 1
        fi
    fi
    simulator_status_supported[index]="$status_supported"

    if [[ "$appearance" != "unsupported" ]]; then
        xcrun simctl ui "$udid" appearance light
    fi
    if [[ "$content_size" != "unsupported" ]]; then
        xcrun simctl ui "$udid" content_size large
    fi
    if [[ "$contrast" != "unsupported" ]]; then
        xcrun simctl ui "$udid" increase_contrast disabled
    fi
    if [[ "$status_supported" == "true" ]]; then
        xcrun simctl status_bar "$udid" clear
    fi
    case "$role" in
        iphone)
            xcrun simctl status_bar "$udid" override \
                --time "$fixed_time" \
                --dataNetwork wifi \
                --wifiMode active \
                --wifiBars 3 \
                --cellularMode active \
                --cellularBars 4 \
                --operatorName '' \
                --batteryState charged \
                --batteryLevel 100
            ;;
        ipad)
            xcrun simctl status_bar "$udid" override \
                --time "$fixed_time" \
                --dataNetwork wifi \
                --wifiMode active \
                --wifiBars 3 \
                --batteryState charged \
                --batteryLevel 100
            ;;
        watch)
            if [[ "$status_supported" == "true" ]]; then
                xcrun simctl status_bar "$udid" override \
                    --time "$fixed_time" \
                    --batteryState charged \
                    --batteryLevel 100
            fi
            ;;
        *)
            echo "Unknown screenshot simulator role: $role" >&2
            return 1
            ;;
    esac
    assert_simulator_presentation "$udid" "$role" "$status_supported"
}

normalize_simulator_presentation iphone "$iphone_udid"
normalize_simulator_presentation ipad "$ipad_udid"
normalize_simulator_presentation watch "$watch_udid"

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

assert_simulator_presentation \
    "$iphone_udid" iphone "${simulator_status_supported[0]}"
run_mobile_screenshot_test \
    "iPhone 17 Pro Max" \
    "$iphone_udid" \
    "$iphone_result" \
    "$work_dir/DerivedData-iPhone" \
    "$work_dir/iPhone.log"

assert_simulator_presentation \
    "$ipad_udid" ipad "${simulator_status_supported[1]}"
run_mobile_screenshot_test \
    "iPad Pro 13-inch (M5)" \
    "$ipad_udid" \
    "$ipad_result" \
    "$work_dir/DerivedData-iPad" \
    "$work_dir/iPad.log"

echo "Capturing Apple Watch screenshots..."
assert_simulator_presentation \
    "$watch_udid" watch "${simulator_status_supported[2]}"
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
restore_all_simulator_states

staging_dir="$work_dir/output"
mkdir -p "$staging_dir"

export_attachment() {
    local result_bundle="$1"
    local attachment_name="$2"
    local output_file="$3"
    local expected_width="$4"
    local expected_height="$5"
    local export_dir
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

    export_dir="$work_dir/export-$(basename "$output_file" .jpg)"
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

publish_files=(
    iphone-6.9-01-copilot-accounts.jpg
    ipad-13-01-copilot-accounts.jpg
    watch-46mm-01-copilot-accounts.jpg
    watch-46mm-02-session-detail.jpg
    SHA256SUMS
    MANIFEST.json
)
if [[ -n "$(find "$output_dir" -mindepth 1 -maxdepth 1 -print -quit)" ]]; then
    echo "Reserved output directory changed during capture: $output_dir" >&2
    exit 73
fi
for filename in "${publish_files[@]}"; do
    source_path="$staging_dir/$filename"
    destination_path="$output_dir/$filename"
    if [[ -e "$destination_path" || -L "$destination_path" ]]; then
        echo "Refusing to overwrite output path: $destination_path" >&2
        exit 73
    fi
    cp -p -n "$source_path" "$destination_path"
    if ! cmp -s "$source_path" "$destination_path"; then
        echo "Output publication collision: $destination_path" >&2
        exit 73
    fi
done
published_count="$(find "$output_dir" -mindepth 1 -maxdepth 1 -type f | wc -l | tr -d '[:space:]')"
if [[ "$published_count" -ne "${#publish_files[@]}" \
    || -n "$(find "$output_dir" -mindepth 1 -maxdepth 1 ! -type f -print -quit)" ]]; then
    echo "Unexpected output appeared while publishing: $output_dir" >&2
    exit 73
fi
for filename in "${publish_files[@]}"; do
    if ! cmp -s "$staging_dir/$filename" "$output_dir/$filename"; then
        echo "Published output changed before verification: $output_dir/$filename" >&2
        exit 73
    fi
done
(
    cd "$output_dir"
    shasum -a 256 -c SHA256SUMS >/dev/null
)
published_count="$(find "$output_dir" -mindepth 1 -maxdepth 1 -type f | wc -l | tr -d '[:space:]')"
if [[ "$published_count" -ne "${#publish_files[@]}" \
    || -n "$(find "$output_dir" -mindepth 1 -maxdepth 1 ! -type f -print -quit)" ]]; then
    echo "Published output inventory changed during verification: $output_dir" >&2
    exit 73
fi
output_mode="$(stat -f '%Lp' "$output_dir")"
if [[ "$output_mode" != "700" ]]; then
    echo "Reserved output directory mode changed: $output_mode" >&2
    exit 73
fi
output_published=true
echo "App Store screenshots created at: $output_dir"
