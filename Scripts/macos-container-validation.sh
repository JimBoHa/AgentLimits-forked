#!/bin/bash
# shellcheck disable=SC2034

# Exact-layout validation helpers for final macOS release containers.
# This file is sourced by package-macos.sh and its tests.

validated_container_app=""
validated_dmg_device=""

validate_zip_container_root() {
    local root="$1"
    local entry
    local relative
    local seen=0

    validated_container_app=""
    if [[ -L "$root" || ! -d "$root" ]]; then
        echo "ZIP extraction root is not a regular directory" >&2
        return 1
    fi
    while IFS= read -r -d '' entry; do
        relative="${entry#"$root"/}"
        if [[ "$relative" != "AgentLimitsForked.app" ]]; then
            echo "ZIP contains unexpected top-level content: $relative" >&2
            return 1
        fi
        ((seen += 1))
    done < <(find "$root" -mindepth 1 -maxdepth 1 -print0)

    if [[ "$seen" != "1" \
        || -L "$root/AgentLimitsForked.app" \
        || ! -d "$root/AgentLimitsForked.app" ]]; then
        echo "ZIP must contain one regular AgentLimitsForked.app" >&2
        return 1
    fi
    validated_container_app="$root/AgentLimitsForked.app"
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
