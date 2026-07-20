#!/bin/bash

# Shared, pure validation helpers for signed macOS release code.
# This file is sourced by package-macos.sh and its tests.

validate_linker_adhoc_signature_details() {
    local details="$1"
    local expected_identifier="$2"
    local label="$3"

    if ! printf '%s\n' "$details" \
            | grep -q '^CodeDirectory .*flags=0x20002(adhoc,linker-signed) ' \
        || ! printf '%s\n' "$details" \
            | grep -Fqx "Identifier=$expected_identifier" \
        || ! printf '%s\n' "$details" | grep -Fqx 'Signature=adhoc' \
        || ! printf '%s\n' "$details" | grep -Fqx 'Info.plist=not bound' \
        || ! printf '%s\n' "$details" | grep -Fqx 'TeamIdentifier=not set' \
        || ! printf '%s\n' "$details" | grep -Fqx 'Sealed Resources=none' \
        || printf '%s\n' "$details" \
            | grep -qE '^(Authority|Timestamp|Signed Time)='; then
        echo "$label is not exclusively linker-generated ad-hoc code" >&2
        return 1
    fi
}

validate_no_code_signature_diagnostic() {
    local details="$1"
    local signature_exit="$2"
    local label="$3"

    if [[ "$signature_exit" != "1" \
        || "$details" != *"code object is not signed at all"* ]]; then
        echo "$label signature state could not be proven unsigned" >&2
        return 1
    fi
}

validate_developer_id_signature_details() {
    local details="$1"
    local expected_team="$2"
    local expected_identifier="$3"
    local expected_authority="$4"
    local label="$5"
    local signed_team
    local signed_identifier
    local signed_authority

    signed_team="$(printf '%s\n' "$details" \
        | sed -n 's/^TeamIdentifier=//p' | head -1)"
    signed_identifier="$(printf '%s\n' "$details" \
        | sed -n 's/^Identifier=//p' | head -1)"
    signed_authority="$(printf '%s\n' "$details" \
        | sed -n 's/^Authority=\(Developer ID Application:.*\)$/\1/p' \
        | head -1)"

    if [[ "$signed_team" != "$expected_team" ]]; then
        echo "$label signature has unexpected Team: $signed_team" >&2
        return 1
    fi
    if [[ -n "$expected_identifier" \
        && "$signed_identifier" != "$expected_identifier" ]]; then
        echo "$label signature has unexpected identifier: $signed_identifier" >&2
        return 1
    fi
    if [[ -z "$signed_identifier" ]]; then
        echo "$label signature has no identifier" >&2
        return 1
    fi
    if [[ -n "$expected_authority" ]]; then
        if [[ "$signed_authority" != "$expected_authority" ]]; then
            echo "$label signature has unexpected Developer ID authority" >&2
            return 1
        fi
    elif [[ ! "$signed_authority" =~ \
        ^Developer\ ID\ Application:\ .+\ \($expected_team\)$ ]]; then
        echo "$label is not signed by Team $expected_team Developer ID Application" >&2
        return 1
    fi
    if printf '%s\n' "$details" | grep -Fqx 'Signature=adhoc'; then
        echo "$label has an ad-hoc signature" >&2
        return 1
    fi
    if ! printf '%s\n' "$details" \
        | grep -q '^CodeDirectory .*runtime'; then
        echo "$label signature lacks hardened runtime" >&2
        return 1
    fi
    if ! printf '%s\n' "$details" | grep -q '^Timestamp=..*'; then
        echo "$label signature lacks a secure timestamp" >&2
        return 1
    fi
    if printf '%s\n' "$details" | grep -q '^Signed Time='; then
        echo "$label has an insecure local signing time" >&2
        return 1
    fi
}

validate_developer_id_signature_slices() {
    local arm64_details="$1"
    local x86_64_details="$2"
    local expected_team="$3"
    local expected_identifier="$4"
    local expected_authority="$5"
    local label="$6"

    validate_developer_id_signature_details \
        "$arm64_details" \
        "$expected_team" \
        "$expected_identifier" \
        "$expected_authority" \
        "$label (arm64)" \
        || return $?
    validate_developer_id_signature_details \
        "$x86_64_details" \
        "$expected_team" \
        "$expected_identifier" \
        "$expected_authority" \
        "$label (x86_64)" \
        || return $?
}

validate_universal_binary_architectures() {
    local architectures="$1"
    local label="$2"

    validate_exact_binary_architectures \
        "$architectures" "$label" arm64 x86_64
}

validate_exact_binary_architectures() {
    local architectures="$1"
    local label="$2"
    local actual_normalized
    local expected_normalized

    shift 2
    actual_normalized="$(printf '%s\n' "$architectures" \
        | tr -s '[:space:]' '\n' \
        | sed '/^$/d' \
        | LC_ALL=C sort \
        | paste -sd ' ' -)"
    expected_normalized="$(printf '%s\n' "$@" \
        | LC_ALL=C sort \
        | paste -sd ' ' -)"

    if [[ -z "$expected_normalized" \
        || "$actual_normalized" != "$expected_normalized" ]]; then
        echo "$label architectures are not exactly $expected_normalized: $actual_normalized" >&2
        return 1
    fi
}

validate_no_get_task_allow_entitlements() {
    local entitlements="$1"
    local label="$2"

    # codesign creates no output file when a code object has no entitlements.
    if [[ ! -e "$entitlements" ]]; then
        return 0
    fi
    if [[ -L "$entitlements" || ! -f "$entitlements" \
        || ! -s "$entitlements" ]]; then
        echo "$label produced invalid entitlement data" >&2
        return 1
    fi
    if ! plutil -lint "$entitlements" >/dev/null; then
        echo "$label produced malformed entitlements" >&2
        return 1
    fi
    if plutil -extract get-task-allow raw "$entitlements" \
            >/dev/null 2>&1 \
        || plutil -extract 'com\.apple\.security\.get-task-allow' raw \
            "$entitlements" >/dev/null 2>&1; then
        echo "$label contains get-task-allow" >&2
        return 1
    fi
}

validate_sparkle_autoupdate_identifier() {
    local identifier="$1"

    if [[ "$identifier" != "Autoupdate" \
        && "$identifier" \
            != "Autoupdate-555549442401fd215d503466a26c3d081e5a8443" ]]; then
        echo "Sparkle Autoupdate has unexpected identifier: $identifier" >&2
        return 1
    fi
}

is_expected_sparkle_code_path() {
    case "$1" in
        Versions/B/Sparkle \
            | Versions/B/Autoupdate \
            | Versions/B/Updater.app/Contents/MacOS/Updater \
            | Versions/B/XPCServices/Downloader.xpc/Contents/MacOS/Downloader \
            | Versions/B/XPCServices/Installer.xpc/Contents/MacOS/Installer)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

is_expected_sparkle_bundle_path() {
    case "$1" in
        Versions/B/Updater.app \
            | Versions/B/XPCServices/Downloader.xpc \
            | Versions/B/XPCServices/Installer.xpc)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

validate_sparkle_symlink_inventory() {
    local sparkle="$1"
    local link
    local relative
    local target
    local seen=0

    while IFS= read -r -d '' link; do
        relative="${link#"$sparkle"/}"
        target="$(readlink "$link")"
        case "$relative:$target" in
            "Versions/Current:B" \
                | "Autoupdate:Versions/Current/Autoupdate" \
                | "Resources:Versions/Current/Resources" \
                | "Sparkle:Versions/Current/Sparkle" \
                | "Updater.app:Versions/Current/Updater.app" \
                | "XPCServices:Versions/Current/XPCServices")
                ((seen += 1))
                ;;
            *)
                echo "Sparkle contains unexpected symlink: $relative -> $target" >&2
                return 1
                ;;
        esac
    done < <(find "$sparkle" -type l -print0)

    if [[ "$seen" != "6" ]]; then
        echo "Sparkle symlink inventory is incomplete: found $seen of 6" >&2
        return 1
    fi

    for relative in \
        Versions/Current \
        Autoupdate \
        Resources \
        Sparkle \
        Updater.app \
        XPCServices; do
        if [[ ! -L "$sparkle/$relative" ]]; then
            echo "Sparkle is missing expected symlink: $relative" >&2
            return 1
        fi
    done
}
