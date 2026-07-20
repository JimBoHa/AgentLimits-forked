#!/bin/bash
# shellcheck disable=SC2034

# Exact-layout validation helpers for final macOS release containers.
# This file is sourced by package-macos.sh and its tests.

validated_container_app=""
validated_dmg_device=""

create_tree_manifest() {
    local root="$1"
    local output="$2"
    local inventory=""
    local entry
    local full_path
    local relative
    local relative_hex
    local target_hex
    local mode
    local size
    local digest
    local result=0

    if [[ -L "$root" || ! -d "$root" ]]; then
        echo "Tree manifest root is not a regular directory" >&2
        return 1
    fi
    if [[ -L "$output" || -d "$output" ]]; then
        echo "Tree manifest output is unsafe" >&2
        return 1
    fi

    if ! inventory="$(mktemp "/private/tmp/AgentLimits-tree-inventory.XXXXXX")"; then
        echo "Could not create tree inventory" >&2
        return 1
    fi
    if ! (cd "$root" && LC_ALL=C find -s . -print0 >"$inventory"); then
        echo "Could not inventory tree manifest root" >&2
        rm -f "$inventory"
        return 1
    fi
    if ! : >"$output"; then
        echo "Could not create tree manifest output" >&2
        rm -f "$inventory"
        return 1
    fi

    while IFS= read -r -d '' entry; do
        relative="${entry#./}"
        full_path="$root/$relative"
        if ! relative_hex="$(
            set -o pipefail
            printf '%s' "$relative" \
                | LC_ALL=C od -An -v -tx1 \
                | tr -d ' \n'
        )"; then
            echo "Could not encode tree path" >&2
            result=1
            break
        fi
        if [[ -L "$full_path" ]]; then
            if ! target_hex="$(
                set -o pipefail
                readlink "$full_path" \
                    | LC_ALL=C od -An -v -tx1 \
                    | tr -d ' \n'
            )"; then
                echo "Could not read tree symlink: $relative" >&2
                result=1
                break
            fi
            if ! printf 'L\t%s\t%s\n' \
                "$target_hex" "$relative_hex" >>"$output"; then
                result=1
                break
            fi
        elif [[ -d "$full_path" ]]; then
            if ! mode="$(stat -f '%Lp' "$full_path")" \
                || ! printf 'D\t%s\t%s\n' \
                    "$mode" "$relative_hex" >>"$output"; then
                echo "Could not record tree directory: $relative" >&2
                result=1
                break
            fi
        elif [[ -f "$full_path" ]]; then
            if ! mode="$(stat -f '%Lp' "$full_path")" \
                || ! size="$(stat -f '%z' "$full_path")" \
                || ! digest="$(
                    set -o pipefail
                    shasum -a 256 "$full_path" | awk '{ print $1 }'
                )" \
                || [[ ! "$digest" =~ ^[0-9a-f]{64}$ ]] \
                || ! printf 'F\t%s\t%s\t%s\t%s\n' \
                    "$mode" "$size" "$digest" "$relative_hex" >>"$output"; then
                echo "Could not hash tree file: $relative" >&2
                result=1
                break
            fi
        else
            echo "Tree contains unsupported content: $relative" >&2
            result=1
            break
        fi
    done <"$inventory"

    rm -f "$inventory"
    if [[ "$result" != "0" ]]; then
        rm -f "$output"
        return "$result"
    fi
}

validate_tree_matches_manifest() {
    local root="$1"
    local expected_manifest="$2"
    local actual_manifest="$3"
    local label="$4"

    if [[ -L "$expected_manifest" || ! -f "$expected_manifest" ]]; then
        echo "$label reference manifest is missing or unsafe" >&2
        return 1
    fi
    create_tree_manifest "$root" "$actual_manifest" || return $?
    if ! cmp -s "$expected_manifest" "$actual_manifest"; then
        echo "$label content differs from the archived source" >&2
        return 1
    fi
}

validate_single_directory_container_root() {
    local root="$1"
    local expected_name="$2"
    local entry
    local relative
    local seen=0

    validated_container_app=""
    if [[ -z "$expected_name" || "$expected_name" == "." \
        || "$expected_name" == ".." || "$expected_name" == */* ]]; then
        echo "Container expected name is unsafe" >&2
        return 1
    fi
    if [[ -L "$root" || ! -d "$root" ]]; then
        echo "Container extraction root is not a regular directory" >&2
        return 1
    fi
    while IFS= read -r -d '' entry; do
        relative="${entry#"$root"/}"
        if [[ "$relative" != "$expected_name" ]]; then
            echo "Container contains unexpected top-level content: $relative" >&2
            return 1
        fi
        ((seen += 1))
    done < <(find "$root" -mindepth 1 -maxdepth 1 -print0)

    if [[ "$seen" != "1" \
        || -L "$root/$expected_name" \
        || ! -d "$root/$expected_name" ]]; then
        echo "Container must contain one regular $expected_name" >&2
        return 1
    fi
    validated_container_app="$root/$expected_name"
}

validate_zip_container_root() {
    validate_single_directory_container_root \
        "$1" "AgentLimitsForked.app"
}

validate_dmg_container_root() {
    local root="$1"
    local entry
    local relative
    local seen=0

    validated_container_app=""
    if [[ -L "$root" || ! -d "$root" ]]; then
        echo "DMG mount root is not a regular directory" >&2
        return 1
    fi
    while IFS= read -r -d '' entry; do
        relative="${entry#"$root"/}"
        case "$relative" in
            AgentLimitsForked.app | Applications)
                ((seen += 1))
                ;;
            *)
                echo "DMG contains unexpected top-level content: $relative" >&2
                return 1
                ;;
        esac
    done < <(find "$root" -mindepth 1 -maxdepth 1 -print0)

    if [[ "$seen" != "2" \
        || -L "$root/AgentLimitsForked.app" \
        || ! -d "$root/AgentLimitsForked.app" ]]; then
        echo "DMG must contain one regular AgentLimitsForked.app" >&2
        return 1
    fi
    if [[ ! -L "$root/Applications" \
        || "$(readlink "$root/Applications")" != "/Applications" ]]; then
        echo "DMG Applications link must point exactly to /Applications" >&2
        return 1
    fi
    validated_container_app="$root/AgentLimitsForked.app"
}

xml_value() {
    local xml="$1"
    local xpath="$2"

    xmllint --nonet --xpath "string($xpath)" "$xml" 2>/dev/null
}

validate_product_package_layout() {
    local root="$1"
    local expected_version="$2"
    local expected_build="$3"
    local component="$root/com.jimboha.agentlimits.macos.pkg"
    local distribution="$root/Distribution"
    local package_info="$component/PackageInfo"
    local payload="$component/Payload"
    local entry
    local relative
    local seen=0

    validated_container_app=""
    if [[ -L "$root" || ! -d "$root" ]]; then
        echo "Expanded PKG root is not a regular directory" >&2
        return 1
    fi
    while IFS= read -r -d '' entry; do
        relative="${entry#"$root"/}"
        case "$relative" in
            Distribution | com.jimboha.agentlimits.macos.pkg)
                ((seen += 1))
                ;;
            *)
                echo "PKG contains unexpected top-level content: $relative" >&2
                return 1
                ;;
        esac
    done < <(find "$root" -mindepth 1 -maxdepth 1 -print0)
    if [[ "$seen" != "2" \
        || -L "$distribution" || ! -f "$distribution" \
        || -L "$component" || ! -d "$component" ]]; then
        echo "PKG product layout is incomplete" >&2
        return 1
    fi

    seen=0
    while IFS= read -r -d '' entry; do
        relative="${entry#"$component"/}"
        case "$relative" in
            Bom | PackageInfo | Payload)
                ((seen += 1))
                ;;
            *)
                echo "PKG component contains unexpected content: $relative" >&2
                return 1
                ;;
        esac
    done < <(find "$component" -mindepth 1 -maxdepth 1 -print0)
    if [[ "$seen" != "3" \
        || -L "$component/Bom" || ! -f "$component/Bom" \
        || -L "$package_info" || ! -f "$package_info" \
        || -L "$payload" || ! -d "$payload" ]]; then
        echo "PKG component layout is incomplete or unsafe" >&2
        return 1
    fi

    seen=0
    while IFS= read -r -d '' entry; do
        relative="${entry#"$payload"/}"
        if [[ "$relative" != "AgentLimitsForked.app" ]]; then
            echo "PKG payload contains unexpected content: $relative" >&2
            return 1
        fi
        ((seen += 1))
    done < <(find "$payload" -mindepth 1 -maxdepth 1 -print0)
    if [[ "$seen" != "1" \
        || -L "$payload/AgentLimitsForked.app" \
        || ! -d "$payload/AgentLimitsForked.app" ]]; then
        echo "PKG payload must contain one regular AgentLimitsForked.app" >&2
        return 1
    fi

    if ! xmllint --nonet --noout "$distribution" "$package_info"; then
        echo "PKG metadata is malformed XML" >&2
        return 1
    fi
    if [[ "$(xml_value "$distribution" 'name(/*)')" \
            != "installer-gui-script" \
        || "$(xml_value "$distribution" \
            '/installer-gui-script/@minSpecVersion')" != "2" \
        || "$(xml_value "$distribution" \
            '/installer-gui-script/product/@id')" \
            != "com.jimboha.agentlimits.macos" \
        || "$(xml_value "$distribution" \
            '/installer-gui-script/product/@version')" \
            != "$expected_version" \
        || "$(xml_value "$distribution" \
            '/installer-gui-script/options/@customize')" != "never" \
        || "$(xml_value "$distribution" \
            '/installer-gui-script/options/@require-scripts')" != "false" \
        || "$(xml_value "$distribution" \
            '/installer-gui-script/options/@hostArchitectures')" \
            != "arm64,x86_64" \
        || "$(xml_value "$distribution" \
            '/installer-gui-script/choice[@id="com.jimboha.agentlimits.macos"]/@customLocation')" \
            != "/Applications" \
        || "$(xml_value "$distribution" \
            '/installer-gui-script/pkg-ref[last()]/@id')" \
            != "com.jimboha.agentlimits.macos" \
        || "$(xml_value "$distribution" \
            '/installer-gui-script/pkg-ref[last()]/@version')" \
            != "$expected_version" \
        || "$(xml_value "$distribution" \
            '/installer-gui-script/pkg-ref[last()]')" \
            != "#com.jimboha.agentlimits.macos.pkg" \
        || "$(xml_value "$distribution" \
            'count(//script | //@script)')" != "0" ]]; then
        echo "PKG Distribution metadata is unexpected" >&2
        return 1
    fi
    if [[ "$(xml_value "$distribution" \
            '/installer-gui-script/pkg-ref/bundle-version/bundle/@id')" \
            != "com.jimboha.agentlimits.macos" \
        || "$(xml_value "$distribution" \
            '/installer-gui-script/pkg-ref/bundle-version/bundle/@path')" \
            != "AgentLimitsForked.app" \
        || "$(xml_value "$distribution" \
            '/installer-gui-script/pkg-ref/bundle-version/bundle/@CFBundleShortVersionString')" \
            != "$expected_version" \
        || "$(xml_value "$distribution" \
            '/installer-gui-script/pkg-ref/bundle-version/bundle/@CFBundleVersion')" \
            != "$expected_build" ]]; then
        echo "PKG Distribution bundle metadata is unexpected" >&2
        return 1
    fi
    if [[ "$(xml_value "$package_info" 'name(/*)')" != "pkg-info" \
        || "$(xml_value "$package_info" '/pkg-info/@identifier')" \
            != "com.jimboha.agentlimits.macos" \
        || "$(xml_value "$package_info" '/pkg-info/@version')" \
            != "$expected_version" \
        || "$(xml_value "$package_info" '/pkg-info/@install-location')" \
            != "/Applications" \
        || "$(xml_value "$package_info" '/pkg-info/@relocatable')" \
            != "false" \
        || "$(xml_value "$package_info" '/pkg-info/@auth')" != "root" \
        || "$(xml_value "$package_info" '/pkg-info/@postinstall-action')" \
            != "none" \
        || "$(xml_value "$package_info" '/pkg-info/bundle/@path')" \
            != "./AgentLimitsForked.app" \
        || "$(xml_value "$package_info" '/pkg-info/bundle/@id')" \
            != "com.jimboha.agentlimits.macos" \
        || "$(xml_value "$package_info" \
            '/pkg-info/bundle/@CFBundleShortVersionString')" \
            != "$expected_version" \
        || "$(xml_value "$package_info" \
            '/pkg-info/bundle/@CFBundleVersion')" != "$expected_build" ]]; then
        echo "PKG PackageInfo metadata is unexpected" >&2
        return 1
    fi

    validated_container_app="$payload/AgentLimitsForked.app"
}

resolve_dmg_attached_device() {
    local attach_json="$1"
    local expected_mount="$2"
    local device

    validated_dmg_device=""
    if [[ -L "$attach_json" || ! -f "$attach_json" ]]; then
        echo "DMG attach metadata is missing or unsafe" >&2
        return 1
    fi
    if ! jq -e --arg mount "$expected_mount" '
        (."system-entities" | type == "array") and
        ([."system-entities"[] | select(."mount-point" != null)] | length == 1) and
        ([."system-entities"[] | select(."mount-point" == $mount)] | length == 1) and
        ([."system-entities"[] | select(."mount-point" == $mount)][0] |
            (."dev-entry" | type == "string") and
            (."dev-entry" | test("^/dev/disk[0-9]+s[0-9]+$")) and
            ."content-hint" == "Apple_HFS" and
            ."volume-kind" == "hfs")
        ' "$attach_json" >/dev/null; then
        echo "DMG attached an unexpected volume" >&2
        return 1
    fi
    device="$(jq -er --arg mount "$expected_mount" \
        '."system-entities"[] | select(."mount-point" == $mount) | ."dev-entry"' \
        "$attach_json")"
    validated_dmg_device="$device"
}

validate_dmg_attachment_metadata() {
    local attach_json="$1"
    local disk_json="$2"
    local expected_mount="$3"
    local device

    if [[ -L "$disk_json" || ! -f "$disk_json" ]]; then
        echo "DMG disk metadata is missing or unsafe" >&2
        return 1
    fi
    resolve_dmg_attached_device "$attach_json" "$expected_mount" \
        || return $?
    device="$validated_dmg_device"
    if ! jq -e \
        --arg mount "$expected_mount" \
        --arg device "$device" '
        .MountPoint == $mount and
        .DeviceNode == $device and
        .FilesystemType == "hfs" and
        .FilesystemName == "HFS+" and
        .VolumeName == "AgentLimits Forked" and
        .WritableVolume == false and
        .Writable == false and
        .WritableMedia == false
        ' "$disk_json" >/dev/null; then
        echo "DMG volume is not the expected read-only HFS+ image" >&2
        return 1
    fi
}
