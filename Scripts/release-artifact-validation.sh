#!/bin/bash

# Shared, pure validation helpers for release artifact identity.
# Sourced by signed and unsigned distribution workflows and their tests.

validated_artifact_path=""
validated_dwarfdump_uuid_inventory=""

validate_only_named_directory_entry() {
    local parent="$1"
    local expected_name="$2"
    local label="$3"
    local expected
    local entry
    local count=0

    validated_artifact_path=""
    if [[ -L "$parent" || ! -d "$parent" ]]; then
        echo "$label parent is not one regular directory" >&2
        return 1
    fi
    if [[ ! "$expected_name" =~ ^[A-Za-z0-9._-]+$ \
        || "$expected_name" == "." || "$expected_name" == ".." ]]; then
        echo "$label expected name is unsafe" >&2
        return 1
    fi
    expected="$parent/$expected_name"
    if ! find "$parent" -mindepth 1 -maxdepth 1 -print0 >/dev/null; then
        echo "$label entries could not be enumerated" >&2
        return 1
    fi
    while IFS= read -r -d '' entry; do
        count=$((count + 1))
        if [[ "$entry" != "$expected" ]]; then
            echo "$label contains an unexpected entry: $(basename "$entry")" >&2
            return 1
        fi
    done < <(find "$parent" -mindepth 1 -maxdepth 1 -print0)

    if [[ "$count" != "1" || -L "$expected" || ! -d "$expected" ]]; then
        echo "$label must contain exactly one regular directory named $expected_name" >&2
        return 1
    fi
    validated_artifact_path="$expected"
}

validate_only_named_regular_file_entry() {
    local parent="$1"
    local expected_name="$2"
    local label="$3"
    local expected
    local entry
    local count=0

    validated_artifact_path=""
    if [[ -L "$parent" || ! -d "$parent" ]]; then
        echo "$label parent is not one regular directory" >&2
        return 1
    fi
    if [[ ! "$expected_name" =~ ^[A-Za-z0-9._-]+$ \
        || "$expected_name" == "." || "$expected_name" == ".." ]]; then
        echo "$label expected name is unsafe" >&2
        return 1
    fi
    expected="$parent/$expected_name"
    if ! find "$parent" -mindepth 1 -maxdepth 1 -print0 >/dev/null; then
        echo "$label entries could not be enumerated" >&2
        return 1
    fi
    while IFS= read -r -d '' entry; do
        count=$((count + 1))
        if [[ "$entry" != "$expected" ]]; then
            echo "$label contains an unexpected entry: $(basename "$entry")" >&2
            return 1
        fi
    done < <(find "$parent" -mindepth 1 -maxdepth 1 -print0)

    if [[ "$count" != "1" || -L "$expected" || ! -f "$expected" ]]; then
        echo "$label must contain exactly one regular file named $expected_name" >&2
        return 1
    fi
    validated_artifact_path="$expected"
}

resolve_exactly_one_directory_with_suffix() {
    local parent="$1"
    local suffix="$2"
    local expected_name="$3"
    local label="$4"
    local candidate=""
    local entry
    local count=0

    validated_artifact_path=""
    if [[ -L "$parent" || ! -d "$parent" ]]; then
        echo "$label parent is not one regular directory" >&2
        return 1
    fi
    if [[ ! "$suffix" =~ ^\.[A-Za-z0-9]+$ \
        || ( -n "$expected_name" \
            && ! "$expected_name" =~ ^[A-Za-z0-9._-]+$ ) \
        || "$expected_name" == "." || "$expected_name" == ".." ]]; then
        echo "$label matching rule is unsafe" >&2
        return 1
    fi
    if ! find "$parent" -mindepth 1 -maxdepth 1 \
            -name "*$suffix" -print0 >/dev/null; then
        echo "$label candidates could not be enumerated" >&2
        return 1
    fi
    while IFS= read -r -d '' entry; do
        count=$((count + 1))
        candidate="$entry"
    done < <(find "$parent" -mindepth 1 -maxdepth 1 \
        -name "*$suffix" -print0)

    if [[ "$count" != "1" || -L "$candidate" || ! -d "$candidate" ]]; then
        echo "$label must contain exactly one regular *$suffix directory" >&2
        return 1
    fi
    if [[ -n "$expected_name" \
        && "$(basename "$candidate")" != "$expected_name" ]]; then
        echo "$label has unexpected name: $(basename "$candidate")" >&2
        return 1
    fi
    validated_artifact_path="$candidate"
}

resolve_exactly_one_regular_file_with_suffix() {
    local parent="$1"
    local suffix="$2"
    local expected_name="$3"
    local label="$4"
    local candidate=""
    local entry
    local count=0

    validated_artifact_path=""
    if [[ -L "$parent" || ! -d "$parent" ]]; then
        echo "$label parent is not one regular directory" >&2
        return 1
    fi
    if [[ ! "$suffix" =~ ^\.[A-Za-z0-9]+$ \
        || ( -n "$expected_name" \
            && ! "$expected_name" =~ ^[A-Za-z0-9._-]+$ ) \
        || "$expected_name" == "." || "$expected_name" == ".." ]]; then
        echo "$label matching rule is unsafe" >&2
        return 1
    fi
    if ! find "$parent" -mindepth 1 -maxdepth 1 \
            -name "*$suffix" -print0 >/dev/null; then
        echo "$label candidates could not be enumerated" >&2
        return 1
    fi
    while IFS= read -r -d '' entry; do
        count=$((count + 1))
        candidate="$entry"
    done < <(find "$parent" -mindepth 1 -maxdepth 1 \
        -name "*$suffix" -print0)

    if [[ "$count" != "1" || -L "$candidate" || ! -f "$candidate" ]]; then
        echo "$label must contain exactly one regular *$suffix file" >&2
        return 1
    fi
    if [[ -n "$expected_name" \
        && "$(basename "$candidate")" != "$expected_name" ]]; then
        echo "$label has unexpected name: $(basename "$candidate")" >&2
        return 1
    fi
    validated_artifact_path="$candidate"
}

validate_dwarfdump_uuid_inventory() {
    local details="$1"
    local label="$2"
    local uuid_line_regex='^UUID:[[:space:]]+([0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12})[[:space:]]+\(([A-Za-z0-9_]+)\)[[:space:]]+.+$'
    local line
    local raw_uuid
    local uuid
    local architecture
    local inventory=""
    local seen_architectures=" "
    local seen_uuids=" "
    local count=0

    validated_dwarfdump_uuid_inventory=""
    while IFS= read -r line; do
        if [[ ! "$line" =~ $uuid_line_regex ]]; then
            echo "$label has malformed UUID inventory" >&2
            return 1
        fi
        raw_uuid="${BASH_REMATCH[1]}"
        architecture="${BASH_REMATCH[2]}"
        uuid="$(printf '%s' "$raw_uuid" | tr '[:lower:]' '[:upper:]')"
        if [[ "$seen_architectures" == *" $architecture "* ]]; then
            echo "$label repeats architecture $architecture" >&2
            return 1
        fi
        if [[ "$seen_uuids" == *" $uuid "* ]]; then
            echo "$label repeats UUID $uuid" >&2
            return 1
        fi
        seen_architectures="$seen_architectures$architecture "
        seen_uuids="$seen_uuids$uuid "
        inventory="${inventory}${architecture} ${uuid}"$'\n'
        count=$((count + 1))
    done <<<"$details"

    if [[ "$count" == "0" ]]; then
        echo "$label has no UUID inventory" >&2
        return 1
    fi
    validated_dwarfdump_uuid_inventory="$(printf '%s' "$inventory" \
        | LC_ALL=C sort)"
}

validate_matching_dwarfdump_uuid_inventories() {
    local binary_details="$1"
    local dsym_details="$2"
    local label="$3"
    local binary_inventory
    local dsym_inventory
    local actual_architectures
    local expected_architectures
    local architecture
    local seen_expected=" "

    shift 3
    if [[ $# -eq 0 ]]; then
        echo "$label has no expected architectures" >&2
        return 1
    fi
    validate_dwarfdump_uuid_inventory \
        "$binary_details" "$label binary" || return $?
    binary_inventory="$validated_dwarfdump_uuid_inventory"
    validate_dwarfdump_uuid_inventory \
        "$dsym_details" "$label dSYM" || return $?
    dsym_inventory="$validated_dwarfdump_uuid_inventory"

    if [[ "$binary_inventory" != "$dsym_inventory" ]]; then
        echo "$label dSYM UUIDs or architectures do not match its binary" >&2
        return 1
    fi

    expected_architectures=""
    for architecture in "$@"; do
        if [[ ! "$architecture" =~ ^[A-Za-z0-9_]+$ \
            || "$seen_expected" == *" $architecture "* ]]; then
            echo "$label expected architecture set is invalid" >&2
            return 1
        fi
        seen_expected="$seen_expected$architecture "
        expected_architectures="${expected_architectures}${architecture}"$'\n'
    done
    expected_architectures="$(printf '%s' "$expected_architectures" \
        | LC_ALL=C sort)"
    actual_architectures="$(printf '%s\n' "$binary_inventory" \
        | awk '{ print $1 }')"
    if [[ "$actual_architectures" != "$expected_architectures" ]]; then
        echo "$label UUID inventory has unexpected architectures" >&2
        return 1
    fi
}

validate_dsym_matches_binary() {
    local binary="$1"
    local dsym="$2"
    local label="$3"
    local dwarf_name
    local dwarf_directory
    local dwarf_binary
    local binary_details
    local dsym_details
    local dsym_component

    shift 3
    if [[ -L "$binary" || ! -f "$binary" ]]; then
        echo "$label binary is missing or unsafe" >&2
        return 1
    fi
    if [[ -L "$dsym" || ! -d "$dsym" ]]; then
        echo "$label dSYM is missing or unsafe" >&2
        return 1
    fi
    dwarf_name="$(basename "$binary")"
    dwarf_directory="$dsym/Contents/Resources/DWARF"
    for dsym_component in \
        "$dsym/Contents" \
        "$dsym/Contents/Resources" \
        "$dwarf_directory"; do
        if [[ -L "$dsym_component" || ! -d "$dsym_component" ]]; then
            echo "$label dSYM contains an unsafe directory chain" >&2
            return 1
        fi
    done
    validate_only_named_regular_file_entry \
        "$dwarf_directory" "$dwarf_name" "$label dSYM DWARF" || return $?
    dwarf_binary="$validated_artifact_path"
    if ! binary_details="$(/usr/bin/dwarfdump --uuid "$binary" 2>&1)"; then
        echo "$label binary UUID inventory could not be read" >&2
        return 1
    fi
    if ! dsym_details="$(/usr/bin/dwarfdump --uuid "$dwarf_binary" 2>&1)"; then
        echo "$label dSYM UUID inventory could not be read" >&2
        return 1
    fi
    validate_matching_dwarfdump_uuid_inventories \
        "$binary_details" "$dsym_details" "$label" "$@"
}

profile_rfc3339_epoch() {
    local value="$1"
    local label="$2"
    local epoch
    local canonical

    if [[ ! "$value" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]; then
        echo "$label is not a canonical UTC profile date" >&2
        return 1
    fi
    if ! epoch="$(LC_ALL=C /bin/date -j -u \
            -f '%Y-%m-%dT%H:%M:%SZ' "$value" '+%s' 2>/dev/null)" \
        || [[ ! "$epoch" =~ ^[0-9]+$ ]]; then
        echo "$label is not a valid profile date" >&2
        return 1
    fi
    canonical="$(LC_ALL=C /bin/date -j -u -r "$epoch" \
        '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null)" || return $?
    if [[ "$canonical" != "$value" ]]; then
        echo "$label is not a real calendar date" >&2
        return 1
    fi
    printf '%s\n' "$epoch"
}

validate_profile_validity_values() {
    local creation_date="$1"
    local expiration_date="$2"
    local validation_epoch="$3"
    local label="$4"
    local creation_epoch
    local expiration_epoch

    if [[ ! "$validation_epoch" =~ ^[0-9]+$ ]]; then
        echo "$label validation time is invalid" >&2
        return 1
    fi
    creation_epoch="$(profile_rfc3339_epoch \
        "$creation_date" "$label CreationDate")" || return $?
    expiration_epoch="$(profile_rfc3339_epoch \
        "$expiration_date" "$label ExpirationDate")" || return $?
    if (( creation_epoch >= expiration_epoch )); then
        echo "$label provisioning profile has an invalid validity window" >&2
        return 1
    fi
    if (( validation_epoch < creation_epoch )); then
        echo "$label provisioning profile is not yet valid" >&2
        return 1
    fi
    if (( validation_epoch >= expiration_epoch )); then
        echo "$label provisioning profile is expired" >&2
        return 1
    fi
}

validate_provisioning_profile_validity_window() {
    local decoded_profile="$1"
    local label="$2"
    local validation_epoch="${3:-}"
    local creation_date
    local expiration_date

    if [[ -L "$decoded_profile" || ! -f "$decoded_profile" ]]; then
        echo "$label provisioning profile data is missing or unsafe" >&2
        return 1
    fi
    if ! creation_date="$(plutil -extract CreationDate raw -expect date \
            "$decoded_profile" 2>/dev/null)"; then
        echo "$label provisioning profile has no typed CreationDate" >&2
        return 1
    fi
    if ! expiration_date="$(plutil -extract ExpirationDate raw -expect date \
            "$decoded_profile" 2>/dev/null)"; then
        echo "$label provisioning profile has no typed ExpirationDate" >&2
        return 1
    fi
    if [[ -z "$validation_epoch" ]]; then
        validation_epoch="$(/bin/date -u '+%s')"
    fi
    validate_profile_validity_values \
        "$creation_date" "$expiration_date" "$validation_epoch" "$label"
}
