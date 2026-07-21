#!/bin/bash

set -Eeuo pipefail

if (( $# != 2 )); then
  echo "Usage: $0 <phone-device-name> <watch-device-name>" >&2
  exit 64
fi

phone_device_name="$1"
watch_device_name="$2"
if [[ "$phone_device_name" != "iPhone 17 Pro" ]]; then
  echo "Unsupported CI Watch companion simulator: $phone_device_name" >&2
  exit 64
fi
if [[ "$watch_device_name" != "Apple Watch Series 11 (46mm)" ]]; then
  echo "Unsupported CI Watch simulator: $watch_device_name" >&2
  exit 64
fi

for command_name in xcrun jq; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "Required command is unavailable: $command_name" >&2
    exit 69
  fi
done

uuid_pattern='^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$'
runtime_pattern='^com\.apple\.CoreSimulator\.SimRuntime\.[A-Za-z0-9._-]+$'
device_type_pattern='^com\.apple\.CoreSimulator\.SimDeviceType\.[A-Za-z0-9._-]+$'

runtimes_json="$(xcrun simctl list runtimes --json)"
available_runtimes="$(
  jq -c '
    [.runtimes[]
      | select(
          (.platform == "iOS" or .platform == "watchOS")
          and .isAvailable == true
        )
      | {identifier, platform, version}]
  ' <<< "$runtimes_json"
)"
compatible_runtimes="$(
  jq -c '
    group_by(.version)
    | map({
        version: .[0].version,
        ios: [.[] | select(.platform == "iOS")],
        watchos: [.[] | select(.platform == "watchOS")]
      })
    | map(select((.ios | length) == 1 and (.watchos | length) == 1))
  ' <<< "$available_runtimes"
)"
compatible_count="$(jq 'length' <<< "$compatible_runtimes")"

if [[ "$compatible_count" -eq 0 ]]; then
  echo 'No unique compatible iOS/watchOS simulator runtime pair is installed.' >&2
  jq -r '
    .runtimes[]
    | select(.platform == "iOS" or .platform == "watchOS")
    | "  \(.platform) \(.version) [\(.identifier)] available=\(.isAvailable)"
  ' <<< "$runtimes_json" >&2
  exit 69
fi

selected_runtimes="$(
  jq -c 'max_by(.version | split(".") | map(tonumber))' \
    <<< "$compatible_runtimes"
)"
runtime_version="$(jq -r '.version' <<< "$selected_runtimes")"
ios_runtime_id="$(jq -r '.ios[0].identifier' <<< "$selected_runtimes")"
watch_runtime_id="$(jq -r '.watchos[0].identifier' <<< "$selected_runtimes")"

if [[ ! "$ios_runtime_id" =~ $runtime_pattern ]]; then
  echo "Invalid iOS simulator runtime identifier: $ios_runtime_id" >&2
  exit 65
fi
if [[ ! "$watch_runtime_id" =~ $runtime_pattern ]]; then
  echo "Invalid watchOS simulator runtime identifier: $watch_runtime_id" >&2
  exit 65
fi

device_types_json="$(xcrun simctl list devicetypes --json)"
phone_types="$(
  jq -c --arg name "$phone_device_name" \
    '[.devicetypes[] | select(.name == $name) | {identifier, name}]' \
    <<< "$device_types_json"
)"
watch_types="$(
  jq -c --arg name "$watch_device_name" \
    '[.devicetypes[] | select(.name == $name) | {identifier, name}]' \
    <<< "$device_types_json"
)"

if [[ "$(jq 'length' <<< "$phone_types")" -ne 1 ]]; then
  echo "Expected exactly one '$phone_device_name' simulator device type." >&2
  exit 69
fi
if [[ "$(jq 'length' <<< "$watch_types")" -ne 1 ]]; then
  echo "Expected exactly one '$watch_device_name' simulator device type." >&2
  exit 69
fi

phone_type_id="$(jq -r '.[0].identifier' <<< "$phone_types")"
watch_type_id="$(jq -r '.[0].identifier' <<< "$watch_types")"
if [[ ! "$phone_type_id" =~ $device_type_pattern ]]; then
  echo "Invalid iOS simulator device type identifier: $phone_type_id" >&2
  exit 65
fi
if [[ ! "$watch_type_id" =~ $device_type_pattern ]]; then
  echo "Invalid watchOS simulator device type identifier: $watch_type_id" >&2
  exit 65
fi

run_id="${GITHUB_RUN_ID:-local}"
run_attempt="${GITHUB_RUN_ATTEMPT:-1}"
if [[ ! "$run_id" =~ ^([0-9]+|local)$ || ! "$run_attempt" =~ ^[0-9]+$ ]]; then
  echo 'Invalid GitHub Actions run identity.' >&2
  exit 65
fi

phone_udid=""
watch_udid=""
pair_udid=""
cleanup_required=1
cleanup_on_exit() {
  local status=$?
  trap - EXIT
  if (( cleanup_required )); then
    if [[ "$pair_udid" =~ $uuid_pattern ]]; then
      xcrun simctl unpair "$pair_udid" >/dev/null 2>&1 || true
    fi
    if [[ "$watch_udid" =~ $uuid_pattern ]]; then
      xcrun simctl shutdown "$watch_udid" >/dev/null 2>&1 || true
      xcrun simctl delete "$watch_udid" >/dev/null 2>&1 || true
    fi
    if [[ "$phone_udid" =~ $uuid_pattern ]]; then
      xcrun simctl shutdown "$phone_udid" >/dev/null 2>&1 || true
      xcrun simctl delete "$phone_udid" >/dev/null 2>&1 || true
    fi
  fi
  exit "$status"
}
trap cleanup_on_exit EXIT

name_suffix="$run_id-$run_attempt"
phone_udid="$(
  xcrun simctl create \
    "AgentLimits CI - $phone_device_name - $name_suffix" \
    "$phone_type_id" \
    "$ios_runtime_id"
)"
if [[ ! "$phone_udid" =~ $uuid_pattern ]]; then
  echo "simctl returned an invalid phone simulator UDID: $phone_udid" >&2
  exit 65
fi

watch_udid="$(
  xcrun simctl create \
    "AgentLimits CI - $watch_device_name - $name_suffix" \
    "$watch_type_id" \
    "$watch_runtime_id"
)"
if [[ ! "$watch_udid" =~ $uuid_pattern ]]; then
  echo "simctl returned an invalid Watch simulator UDID: $watch_udid" >&2
  exit 65
fi

pair_udid="$(xcrun simctl pair "$watch_udid" "$phone_udid")"
if [[ ! "$pair_udid" =~ $uuid_pattern ]]; then
  echo "simctl returned an invalid simulator pair UUID: $pair_udid" >&2
  exit 65
fi

xcrun simctl pair_activate "$pair_udid" >&2
xcrun simctl bootstatus "$phone_udid" -b >&2
xcrun simctl bootstatus "$watch_udid" -b >&2

pair_ready=0
for (( readiness_attempt = 1; readiness_attempt <= 60; readiness_attempt++ )); do
  pairs_json="$(xcrun simctl list pairs --json)"
  if jq -e \
    --arg pair "$pair_udid" \
    --arg phone "$phone_udid" \
    --arg watch "$watch_udid" '
      .pairs[$pair] as $entry
      | $entry != null
        and $entry.phone.udid == $phone
        and $entry.phone.state == "Booted"
        and $entry.watch.udid == $watch
        and $entry.watch.state == "Booted"
        and ($entry.state | contains("active"))
        and ($entry.state | contains("connected"))
    ' <<< "$pairs_json" >/dev/null; then
    pair_ready=1
    break
  fi
  sleep 1
done

if (( ! pair_ready )); then
  echo "Simulator pair did not become active and connected: $pair_udid" >&2
  xcrun simctl list pairs >&2 || true
  exit 69
fi

provisioning_json="$(
  jq -cn \
    --arg destination "platform=watchOS Simulator,id=$watch_udid,arch=arm64" \
    --arg pair_udid "$pair_udid" \
    --arg phone_udid "$phone_udid" \
    --arg runtime_version "$runtime_version" \
    --arg watch_udid "$watch_udid" \
    '{
      destination: $destination,
      pair_udid: $pair_udid,
      phone_udid: $phone_udid,
      runtime_version: $runtime_version,
      watch_udid: $watch_udid
    }'
)"
cleanup_required=0
trap - EXIT
printf '%s\n' "$provisioning_json"
