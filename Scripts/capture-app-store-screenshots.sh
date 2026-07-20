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
    echo "Usage: $0 /ABSOLUTE/NEW/OUTPUT_DIRECTORY" >&2
    echo "Captures deterministic iPhone, iPad, and Apple Watch App Store screenshots." >&2
}

if [[ $# -ne 1 ]]; then
    usage
    exit 64
fi

invoked_script="${BASH_SOURCE[0]}"
if [[ -L "$invoked_script" ]]; then
    echo "Refusing screenshot capture through a script symlink" >&2
    exit 64
fi
script_dir="$(cd "$(dirname "$invoked_script")" >/dev/null && pwd -P)"
project_root="$(cd "$script_dir/.." >/dev/null && pwd -P)"
developer_dir="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
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
sanitize_release_xcode_environment

selected_xcrun() {
    /usr/bin/xcrun --no-cache "$@"
}

if ! command -v jq >/dev/null 2>&1; then
    echo "jq is required to resolve simulators and write metadata." >&2
    exit 69
fi
validate_release_output_request "$1" "$project_root" || exit $?
output_parent="$validated_release_output_parent"
output_parent_identity="$validated_release_output_parent_identity"
output_name="$validated_release_output_name"
output_dir="$validated_release_output_directory"

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
simulator_lock_udids=()
simulator_lock_paths=()
simulator_lock_identities=()
simulator_locks_released=true
capture_user_id="$(id -u)"

validate_simulator_udid() {
    [[ "$1" =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]]
}

verify_simulator_lock() {
    local index="$1"
    local udid="${simulator_lock_udids[$index]}"
    local lock_path="${simulator_lock_paths[$index]}"
    local expected_path="/private/tmp/.AgentLimits-simulator-${capture_user_id}-${udid}.lock"
    local expected_identity="${simulator_lock_identities[$index]}"
    local actual_identity

    if [[ "$lock_path" != "$expected_path" \
        || -L "$lock_path" \
        || ! -d "$lock_path" ]]; then
        echo "Simulator lock path changed: $udid" >&2
        return 73
    fi
    actual_identity="$(release_path_identity "$lock_path")" || return 73
    if [[ "$actual_identity" != "$expected_identity" ]]; then
        echo "Simulator lock identity changed: $udid" >&2
        return 73
    fi
    if ! verify_private_release_directory "$lock_path"; then
        echo "Simulator lock permissions changed: $udid" >&2
        return 73
    fi
}

verify_all_simulator_locks() {
    local index

    if [[ "$simulator_locks_released" == "true" ]]; then
        echo "Simulator locks are not held" >&2
        return 73
    fi
    for ((index=0; index<${#simulator_lock_paths[@]}; index++)); do
        verify_simulator_lock "$index" || return $?
    done
}

release_all_simulator_locks() {
    local index
    local failed=0

    if [[ "$simulator_locks_released" == "true" ]]; then
        return 0
    fi
    for ((index=${#simulator_lock_paths[@]} - 1; index >= 0; index--)); do
        if [[ -z "${simulator_lock_paths[$index]}" ]]; then
            continue
        fi
        if ! verify_simulator_lock "$index"; then
            failed=1
            continue
        fi
        if ! rmdir "${simulator_lock_paths[$index]}" 2>/dev/null; then
            echo "Could not remove simulator lock: ${simulator_lock_udids[$index]}" >&2
            failed=1
            continue
        fi
        simulator_lock_paths[index]=""
    done
    if [[ "$failed" -eq 0 ]]; then
        simulator_locks_released=true
    fi
    return "$failed"
}

acquire_all_simulator_locks() {
    local ordered_udids=("$@")
    local index
    local compare
    local swap
    local udid
    local lock_path
    local lock_identity

    if [[ "${#ordered_udids[@]}" -eq 0 ]]; then
        echo "No simulator IDs supplied for locking" >&2
        return 64
    fi
    for ((index=0; index<${#ordered_udids[@]}; index++)); do
        validate_simulator_udid "${ordered_udids[$index]}" || {
            echo "Unsafe simulator ID: ${ordered_udids[$index]}" >&2
            return 64
        }
        for ((compare=index + 1; compare<${#ordered_udids[@]}; compare++)); do
            if [[ "${ordered_udids[$index]}" == "${ordered_udids[$compare]}" ]]; then
                echo "Screenshot simulator IDs must be distinct" >&2
                return 64
            fi
        done
    done
    for ((index=0; index<${#ordered_udids[@]} - 1; index++)); do
        for ((compare=index + 1; compare<${#ordered_udids[@]}; compare++)); do
            if [[ "${ordered_udids[$index]}" > "${ordered_udids[$compare]}" ]]; then
                swap="${ordered_udids[$index]}"
                ordered_udids[index]="${ordered_udids[$compare]}"
                ordered_udids[compare]="$swap"
            fi
        done
    done

    simulator_locks_released=false
    for udid in "${ordered_udids[@]}"; do
        lock_path="/private/tmp/.AgentLimits-simulator-${capture_user_id}-${udid}.lock"
        if [[ -e "$lock_path" || -L "$lock_path" ]] \
            || ! mkdir -m 700 "$lock_path" 2>/dev/null; then
            echo "Simulator is already reserved for capture: $udid" >&2
            return 73
        fi
        lock_identity="$(release_path_identity "$lock_path")" || {
            rmdir "$lock_path" 2>/dev/null || true
            return 73
        }
        simulator_lock_udids+=("$udid")
        simulator_lock_paths+=("$lock_path")
        simulator_lock_identities+=("$lock_identity")
        if ! make_release_directory_private "$lock_path" \
            || ! verify_simulator_lock "$((${#simulator_lock_paths[@]} - 1))"; then
            echo "Could not secure simulator lock: $udid" >&2
            return 73
        fi
    done
    verify_all_simulator_locks
}

device_state() {
    local udid="$1"

    verify_all_simulator_locks || return $?
    selected_xcrun simctl list devices --json \
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

    selected_xcrun simctl status_bar "$udid" clear

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
        selected_xcrun simctl status_bar "$udid" override "${args[@]}"
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

    verify_all_simulator_locks || return $?

    current_state="$(device_state "$udid")"
    if [[ "${simulator_mutated[$index]}" == "true" \
        || "$initial_state" == "Booted" ]]; then
        if [[ "$current_state" != "Booted" ]]; then
            selected_xcrun simctl boot "$udid" 2>/dev/null || true
            selected_xcrun simctl bootstatus "$udid" -b >/dev/null
        fi
    fi

    if [[ "${simulator_mutated[$index]}" == "true" ]]; then
        if [[ "${simulator_appearances[$index]}" != "unsupported" ]]; then
            selected_xcrun simctl ui "$udid" appearance \
                "${simulator_appearances[$index]}"
        fi
        if [[ "${simulator_content_sizes[$index]}" != "unsupported" ]]; then
            selected_xcrun simctl ui "$udid" content_size \
                "${simulator_content_sizes[$index]}"
        fi
        if [[ "${simulator_contrasts[$index]}" != "unsupported" ]]; then
            selected_xcrun simctl ui "$udid" increase_contrast \
                "${simulator_contrasts[$index]}"
        fi
        if [[ "${simulator_status_supported[$index]}" == "true" ]]; then
            restore_status_bar_snapshot \
                "$udid" \
                "${simulator_status_files[$index]}"
        fi
        if [[ "$(selected_xcrun simctl ui "$udid" appearance)" \
                != "${simulator_appearances[$index]}" \
            || "$(selected_xcrun simctl ui "$udid" content_size)" \
                != "${simulator_content_sizes[$index]}" \
            || "$(selected_xcrun simctl ui "$udid" increase_contrast)" \
                != "${simulator_contrasts[$index]}" ]]; then
            echo "Simulator UI settings did not restore exactly: $udid" >&2
            return 1
        fi
        selected_xcrun simctl status_bar "$udid" list >"$restored_status_file"
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
        selected_xcrun simctl shutdown "$udid"
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
    local cleanup_status=0
    local work_cleanup_allowed=true

    trap - EXIT
    set +e
    restore_all_simulator_states
    restore_status=$?
    if ! release_all_simulator_locks; then
        cleanup_status=1
    fi
    if [[ -n "${source_snapshot:-}" ]] \
        && ! unlock_immutable_release_source_snapshot_for_cleanup \
            "$source_snapshot" \
            "$source_snapshot_identity" \
            "$work_dir" \
            "$project_root" \
            "$source_tree"; then
        cleanup_status=1
        work_cleanup_allowed=false
    fi
    if ! cleanup_private_release_directory \
        "${staging_parent:-}" \
        "${staging_parent_identity:-}" \
        "$output_parent" \
        '^\.AgentLimits-screenshots-stage\.[A-Za-z0-9]{6}$'; then
        cleanup_status=1
    fi
    if [[ "$work_cleanup_allowed" == "true" ]] \
        && ! cleanup_private_release_directory \
            "${work_dir:-}" \
            "${work_dir_identity:-}" \
            /private/tmp \
            '^AgentLimits-screenshot-capture\.[A-Za-z0-9]{6}$'; then
        cleanup_status=1
    fi
    if [[ -n "${publication_lock:-}" ]] \
        && ! release_release_publication_lock \
            "$publication_lock" \
            "$publication_lock_identity" \
            "$output_parent" \
            "$output_name"; then
        cleanup_status=1
    fi
    if [[ ( "$restore_status" -ne 0 || "$cleanup_status" -ne 0 ) \
        && "$exit_status" -eq 0 ]]; then
        exit_status=1
    fi
    exit "$exit_status"
}
trap cleanup EXIT

export DEVELOPER_DIR="$developer_dir"
acquire_release_publication_lock \
    "$output_parent" "$output_name" "$output_parent_identity" || exit $?
publication_lock="$validated_release_publication_lock"
publication_lock_identity="$validated_release_publication_lock_identity"
create_release_staging_directory \
    "$output_parent" \
    "$output_name" \
    "$output_parent_identity" \
    screenshots \
    || exit $?
staging_parent="$validated_release_staging_parent"
staging_parent_identity="$validated_release_staging_parent_identity"
staging_dir="$validated_release_staging_directory"
staging_dir_identity="$validated_release_staging_directory_identity"
create_private_release_work_directory AgentLimits-screenshot-capture || exit $?
work_dir="$validated_release_work_directory"
work_dir_identity="$validated_release_work_directory_identity"
configure_private_release_temporary_directory "$work_dir" || exit $?
verify_pinned_release_source_unchanged \
    "$project_root" "$source_commit" "$source_tree" || exit $?
create_immutable_release_source_snapshot \
    "$project_root" \
    "$source_commit" \
    "$source_tree" \
    "$work_dir" \
    || exit $?
source_snapshot="$validated_release_source_snapshot"
source_snapshot_identity="$validated_release_source_snapshot_identity"
build_root="$source_snapshot"
build_atomic_release_publisher \
    "$build_root/Scripts/atomic-release-publish.c" \
    "$work_dir/atomic-release-publish" \
    || exit $?
atomic_publisher="$validated_release_atomic_publisher"
atomic_publisher_identity="$validated_release_atomic_publisher_identity"
atomic_publisher_hash="$validated_release_atomic_publisher_hash"

verify_capture_provenance() {
    verify_immutable_release_source_snapshot \
        "$source_snapshot" "$source_snapshot_identity" || return $?
    verify_pinned_release_source_unchanged \
        "$project_root" "$source_commit" "$source_tree" || return $?
}

verify_capture_provenance || exit $?

runtimes_json="$(selected_xcrun simctl list runtimes available --json)"
resolution_devices_json="$(selected_xcrun simctl list devices available --json)"

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
            ' <<<"$resolution_devices_json"
    )"
    device_count="$(jq 'length' <<<"$matches")"
    if [[ "$device_count" -ne 1 ]]; then
        echo "Expected one available '$device_name' on $platform $latest_version; found $device_count." >&2
        jq -r --arg runtime "$runtime_id" '
            .devices[$runtime][]?
            | select(.isAvailable == true)
            | "  \(.name): \(.udid)"
        ' <<<"$resolution_devices_json" >&2
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

acquire_all_simulator_locks \
    "$iphone_udid" "$ipad_udid" "$watch_udid" || exit $?
verify_all_simulator_locks || exit $?
devices_json="$(selected_xcrun simctl list devices available --json)"

echo "iPhone 17 Pro Max ($ios_version): $iphone_udid"
echo "iPad Pro 13-inch (M5) ($ipad_version): $ipad_udid"
echo "Apple Watch Series 11 (46mm) ($watch_version): $watch_udid"

assert_simulator_presentation() {
    local udid="$1"
    local role="$2"
    local status_supported="$3"
    local status
    local displayed_time

    verify_all_simulator_locks || return $?

    if [[ "$role" == "watch" ]]; then
        if [[ "$(selected_xcrun simctl ui "$udid" appearance)" != "unsupported" \
            || "$(selected_xcrun simctl ui "$udid" content_size)" != "unsupported" \
            || "$(selected_xcrun simctl ui "$udid" increase_contrast)" \
                != "unsupported" ]]; then
            echo "Unexpected Watch simulator presentation support: $udid" >&2
            return 1
        fi
    elif [[ "$(selected_xcrun simctl ui "$udid" appearance)" != "light" \
        || "$(selected_xcrun simctl ui "$udid" content_size)" != "large" \
        || "$(selected_xcrun simctl ui "$udid" increase_contrast)" != "disabled" ]]; then
        echo "Simulator presentation settings changed before capture: $udid" >&2
        return 1
    fi

    status="$(selected_xcrun simctl status_bar "$udid" list)"
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

    verify_all_simulator_locks || return $?

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
        selected_xcrun simctl boot "$udid" 2>/dev/null || true
    fi
    selected_xcrun simctl bootstatus "$udid" -b >/dev/null

    appearance="$(selected_xcrun simctl ui "$udid" appearance)"
    content_size="$(selected_xcrun simctl ui "$udid" content_size)"
    contrast="$(selected_xcrun simctl ui "$udid" increase_contrast)"
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
    selected_xcrun simctl status_bar "$udid" list >"$status_file"
    if ! validate_status_bar_snapshot "$status_file"; then
        echo "Cannot preserve existing status-bar overrides: $udid" >&2
        return 1
    fi

    simulator_appearances[index]="$appearance"
    simulator_content_sizes[index]="$content_size"
    simulator_contrasts[index]="$contrast"
    simulator_mutated[index]=true

    if [[ "$role" == "watch" ]]; then
        if selected_xcrun simctl status_bar "$udid" override \
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
        selected_xcrun simctl ui "$udid" appearance light
    fi
    if [[ "$content_size" != "unsupported" ]]; then
        selected_xcrun simctl ui "$udid" content_size large
    fi
    if [[ "$contrast" != "unsupported" ]]; then
        selected_xcrun simctl ui "$udid" increase_contrast disabled
    fi
    if [[ "$status_supported" == "true" ]]; then
        selected_xcrun simctl status_bar "$udid" clear
    fi
    case "$role" in
        iphone)
            selected_xcrun simctl status_bar "$udid" override \
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
            selected_xcrun simctl status_bar "$udid" override \
                --time "$fixed_time" \
                --dataNetwork wifi \
                --wifiMode active \
                --wifiBars 3 \
                --batteryState charged \
                --batteryLevel 100
            ;;
        watch)
            if [[ "$status_supported" == "true" ]]; then
                selected_xcrun simctl status_bar "$udid" override \
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
    verify_all_simulator_locks || return $?
    if ! xcodebuild test \
        -project "$build_root/AgentLimits.xcodeproj" \
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
        selected_xcrun xcresulttool get test-results summary \
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

verify_capture_provenance || exit $?
assert_simulator_presentation \
    "$iphone_udid" iphone "${simulator_status_supported[0]}"
run_mobile_screenshot_test \
    "iPhone 17 Pro Max" \
    "$iphone_udid" \
    "$iphone_result" \
    "$work_dir/DerivedData-iPhone" \
    "$work_dir/iPhone.log"
verify_capture_provenance || exit $?

assert_simulator_presentation \
    "$ipad_udid" ipad "${simulator_status_supported[1]}"
run_mobile_screenshot_test \
    "iPad Pro 13-inch (M5)" \
    "$ipad_udid" \
    "$ipad_result" \
    "$work_dir/DerivedData-iPad" \
    "$work_dir/iPad.log"
verify_capture_provenance || exit $?

echo "Capturing Apple Watch screenshots..."
assert_simulator_presentation \
    "$watch_udid" watch "${simulator_status_supported[2]}"
verify_all_simulator_locks || exit $?
if ! xcodebuild test \
    -project "$build_root/AgentLimits.xcodeproj" \
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
verify_capture_provenance || exit $?
restore_all_simulator_states
release_all_simulator_locks

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
    selected_xcrun xcresulttool export attachments \
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

verify_capture_provenance || exit $?
echo "Building unsigned Release app for fixture-marker guard..."
release_derived_data="$work_dir/DerivedData-Release"
if ! xcodebuild build \
    -project "$build_root/AgentLimits.xcodeproj" \
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
verify_capture_provenance || exit $?

release_ios_app="$release_derived_data/Build/Products/Release-iphoneos/AgentLimits.app"
release_watch_app="$release_ios_app/Watch/AgentLimitsWatch.app"
verify_apple_product_toolchain_metadata \
    "$release_ios_app/Info.plist" iphoneos "Screenshot guard iOS app" \
    || exit $?
verify_apple_product_toolchain_metadata \
    "$release_watch_app/Info.plist" watchos "Screenshot guard Watch app" \
    || exit $?
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
xcode_version="$(xcodebuild -version | paste -sd ' ' -)"
verify_capture_provenance || exit $?

jq -n \
    --arg generatedAt "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    --arg gitCommit "$source_commit" \
    --arg gitTree "$source_tree" \
    --arg xcode "$xcode_version" \
    --arg xcodeVersion "$validated_apple_xcode_version" \
    --arg xcodeBuild "$validated_apple_xcode_build" \
    --arg dtxcode "$validated_apple_dtxcode" \
    --arg iphoneosSDKVersion "$validated_apple_iphoneos_sdk_version" \
    --arg iphoneosSDKName "$validated_apple_iphoneos_sdk_name" \
    --arg iphoneosSDKBuild "$validated_apple_iphoneos_sdk_build" \
    --arg watchosSDKVersion "$validated_apple_watchos_sdk_version" \
    --arg watchosSDKName "$validated_apple_watchos_sdk_name" \
    --arg watchosSDKBuild "$validated_apple_watchos_sdk_build" \
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
        schemaVersion: 2,
        generatedAt: $generatedAt,
        source: {
            gitCommit: $gitCommit,
            gitTree: $gitTree,
            gitDirty: false,
            captureSource: "private immutable git archive",
            xcode: $xcode,
            validatedToolchain: {
                xcodeVersion: $xcodeVersion,
                xcodeBuild: $xcodeBuild,
                dtxcode: $dtxcode,
                iphoneosSDK: {
                    version: $iphoneosSDKVersion,
                    name: $iphoneosSDKName,
                    build: $iphoneosSDKBuild
                },
                watchosSDK: {
                    version: $watchosSDKVersion,
                    name: $watchosSDKName,
                    build: $watchosSDKBuild
                }
            }
        },
        fixture: {
            data: "fictional, deterministic, and local-only",
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
        testEvidence: {
            allPassed: true,
            sourceCommit: $gitCommit,
            fixtureIsolation: {
                buildConfiguration: "Debug",
                evidenceScope: "source-bound implementation wiring and passing UI tests; not dynamic access tracing",
                launchArgument: "-ui-testing-sample-data",
                iOS: {
                    defaultsSuite: "com.jimboha.agentlimits.ios.app-store-screenshot",
                    accountPersistenceKey: "mobile_provider_accounts_app_store_screenshot_v1",
                    credentialStoreImplementation: "MobileInMemoryCredentialStore",
                    usageFetcherImplementation: "MobileAppStoreScreenshotFetcher",
                    watchConnectivityEnabled: false
                },
                watchOS: {
                    cacheImplementation: "WatchAppStoreScreenshotCache",
                    watchConnectivityEnabled: false
                }
            },
            runs: [
                {
                    scheme: "AgentLimitsiOS",
                    testIdentifiers: [
                        "AgentLimitsiOSUITests/AgentLimitsiOSUITests/testAppStoreCopilotAccountsScreenshot"
                    ],
                    simulator: "iPhone 17 Pro Max",
                    udid: $iphoneUDID,
                    runtime: $iosRuntime,
                    result: "Passed",
                    totalTestCount: 1,
                    passedTestCount: 1
                },
                {
                    scheme: "AgentLimitsiOS",
                    testIdentifiers: [
                        "AgentLimitsiOSUITests/AgentLimitsiOSUITests/testAppStoreCopilotAccountsScreenshot"
                    ],
                    simulator: "iPad Pro 13-inch (M5)",
                    udid: $ipadUDID,
                    runtime: $iosRuntime,
                    result: "Passed",
                    totalTestCount: 1,
                    passedTestCount: 1
                },
                {
                    scheme: "AgentLimitsWatch",
                    testIdentifiers: [
                        "AgentLimitsWatchUITests/AgentLimitsWatchUITests/testAppStoreCopilotAccountsScreenshot",
                        "AgentLimitsWatchUITests/AgentLimitsWatchUITests/testAppStoreCopilotDetailScreenshot"
                    ],
                    simulator: "Apple Watch Series 11 (46mm)",
                    udid: $watchUDID,
                    runtime: $watchRuntime,
                    result: "Passed",
                    totalTestCount: 2,
                    passedTestCount: 2
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
            buildConfiguration: "Release",
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
for filename in "${publish_files[@]}"; do
    staged_path="$staging_dir/$filename"
    if [[ -L "$staged_path" || ! -f "$staged_path" ]]; then
        echo "Screenshot publication file is missing or unsafe: $staged_path" >&2
        exit 73
    fi
done
staging_files_inventory="$work_dir/staging-files.inventory"
staging_unexpected_inventory="$work_dir/staging-unexpected.inventory"
if ! /usr/bin/find "$staging_dir" \
        -mindepth 1 -maxdepth 1 -type f -print0 \
        >"$staging_files_inventory"; then
    echo "Could not traverse screenshot staging files: $staging_dir" >&2
    exit 73
fi
if ! /usr/bin/find "$staging_dir" \
        -mindepth 1 -maxdepth 1 ! -type f -print0 \
        >"$staging_unexpected_inventory"; then
    echo "Could not traverse screenshot staging inventory: $staging_dir" >&2
    exit 73
fi
staged_count=0
while IFS= read -r -d '' staged_inventory_path; do
    if [[ -z "$staged_inventory_path" ]]; then
        echo "Screenshot staging inventory contained an empty path" >&2
        exit 73
    fi
    staged_count=$((staged_count + 1))
done <"$staging_files_inventory"
if [[ "$staged_count" -ne "${#publish_files[@]}" \
    || -s "$staging_unexpected_inventory" ]]; then
    echo "Unexpected screenshot staging inventory: $staging_dir" >&2
    exit 73
fi
(
    cd "$staging_dir"
    shasum -a 256 -c SHA256SUMS >/dev/null
)
jq -e '
    .schemaVersion == 2
    and .source.gitDirty == false
    and .source.captureSource == "private immutable git archive"
    and (.source.validatedToolchain.xcodeVersion | length) > 0
    and (.source.validatedToolchain.xcodeBuild | length) > 0
    and (.source.validatedToolchain.iphoneosSDK.build | length) > 0
    and (.source.validatedToolchain.watchosSDK.build | length) > 0
    and .testEvidence.allPassed == true
    and .testEvidence.fixtureIsolation.iOS.credentialStoreImplementation
        == "MobileInMemoryCredentialStore"
    and .testEvidence.fixtureIsolation.iOS.usageFetcherImplementation
        == "MobileAppStoreScreenshotFetcher"
    and .testEvidence.fixtureIsolation.watchOS.cacheImplementation
        == "WatchAppStoreScreenshotCache"
    and (.testEvidence.fixtureIsolation | has("productionDefaultsAccessed") | not)
    and (.testEvidence.fixtureIsolation | has("keychainAccessed") | not)
    and (.testEvidence.fixtureIsolation | has("networkAccessed") | not)
    and (.testEvidence.fixtureIsolation | has("watchConnectivityAccessed") | not)
    and ([.testEvidence.runs[].result] | all(. == "Passed"))
    and ([.testEvidence.runs[].passedTestCount] | add) == 4
    and ([.testEvidence.runs[].totalTestCount] | add) == 4
    and .releaseGuard.fixtureMarkersFound == false
' "$staging_dir/MANIFEST.json" >/dev/null
verify_private_release_directory "$staging_dir" || exit $?
verify_capture_provenance || exit $?
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
    || exit $?
staging_dir=""
if ! rmdir "$staging_parent"; then
    echo "Could not remove empty screenshot staging parent" >&2
    exit 73
fi
staging_parent=""
release_release_publication_lock \
    "$publication_lock" \
    "$publication_lock_identity" \
    "$output_parent" \
    "$output_name" \
    || exit $?
publication_lock=""
echo "App Store screenshots created at: $output_dir"
