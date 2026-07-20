#!/bin/bash

set -Eeuo pipefail

if (( $# != 1 )); then
  echo "Usage: $0 <device-name>" >&2
  exit 64
fi

device_name="$1"
case "$device_name" in
  "iPhone 17 Pro"|"iPad Pro 13-inch (M5)") ;;
  *)
    echo "Unsupported CI iOS simulator device: $device_name" >&2
    exit 64
    ;;
esac

for command_name in xcrun jq; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "Required command is unavailable: $command_name" >&2
    exit 69
  fi
done

runtimes_json="$(xcrun simctl list runtimes --json)"
available_runtimes="$(
  jq -c '
    [.runtimes[]
      | select(.platform == "iOS" and .isAvailable == true)
      | {identifier, version}]
  ' <<< "$runtimes_json"
)"
runtime_count="$(jq 'length' <<< "$available_runtimes")"

if [[ "$runtime_count" -eq 0 ]]; then
  echo "No available iOS simulator runtime is installed." >&2
  jq -r '
    .runtimes[]
    | select(.platform == "iOS")
    | "  \(.name) [\(.identifier)] available=\(.isAvailable)"
  ' <<< "$runtimes_json" >&2
  exit 69
fi

latest_version="$(
  jq -r 'max_by(.version | split(".") | map(tonumber)) | .version' \
    <<< "$available_runtimes"
)"
latest_runtimes="$(
  jq -c --arg version "$latest_version" \
    '[.[] | select(.version == $version)]' \
    <<< "$available_runtimes"
)"
latest_runtime_count="$(jq 'length' <<< "$latest_runtimes")"

if [[ "$latest_runtime_count" -ne 1 ]]; then
  echo "Expected exactly one available iOS $latest_version runtime; found $latest_runtime_count:" >&2
  jq -r '.[] | "  \(.identifier)"' <<< "$latest_runtimes" >&2
  exit 69
fi

runtime_id="$(jq -r '.[0].identifier' <<< "$latest_runtimes")"
if [[ ! "$runtime_id" =~ ^com\.apple\.CoreSimulator\.SimRuntime\.[A-Za-z0-9._-]+$ ]]; then
  echo "Invalid iOS simulator runtime identifier: $runtime_id" >&2
  exit 65
fi

device_types_json="$(xcrun simctl list devicetypes --json)"
matching_device_types="$(
  jq -c --arg name "$device_name" \
    '[.devicetypes[] | select(.name == $name) | {identifier, name}]' \
    <<< "$device_types_json"
)"
device_type_count="$(jq 'length' <<< "$matching_device_types")"

if [[ "$device_type_count" -ne 1 ]]; then
  echo "Expected exactly one '$device_name' simulator device type; found $device_type_count:" >&2
  jq -r '.[] | "  \(.identifier)"' <<< "$matching_device_types" >&2
  exit 69
fi

device_type_id="$(jq -r '.[0].identifier' <<< "$matching_device_types")"
if [[ ! "$device_type_id" =~ ^com\.apple\.CoreSimulator\.SimDeviceType\.[A-Za-z0-9._-]+$ ]]; then
  echo "Invalid iOS simulator device type identifier: $device_type_id" >&2
  exit 65
fi

run_id="${GITHUB_RUN_ID:-local}"
run_attempt="${GITHUB_RUN_ATTEMPT:-1}"
if [[ ! "$run_id" =~ ^([0-9]+|local)$ || ! "$run_attempt" =~ ^[0-9]+$ ]]; then
  echo "Invalid GitHub Actions run identity." >&2
  exit 65
fi

simulator_name="AgentLimits CI - $device_name - $run_id-$run_attempt"
created_udid=""
cleanup_on_error() {
  local status=$?
  if [[ -n "$created_udid" ]]; then
    xcrun simctl delete "$created_udid" >/dev/null 2>&1 || true
  fi
  exit "$status"
}
trap cleanup_on_error ERR

created_udid="$(
  xcrun simctl create "$simulator_name" "$device_type_id" "$runtime_id"
)"
if [[ ! "$created_udid" =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]]; then
  echo "simctl returned an invalid simulator UDID: $created_udid" >&2
  exit 65
fi

trap - ERR
printf 'platform=iOS Simulator,id=%s\n' "$created_udid"
