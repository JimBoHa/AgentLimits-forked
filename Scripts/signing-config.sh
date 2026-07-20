#!/bin/bash

# Shared validation for the gitignored Apple Team configuration.
# This file is sourced by signed release scripts.

validate_development_team_config() {
    local config="$1"
    local owner_uid
    local link_count
    local mode
    local acl_entries
    local line
    local team_count=0
    local team_pattern='^[[:space:]]*DEVELOPMENT_TEAM[[:space:]]*=[[:space:]]*([A-Z0-9]{10})[[:space:]]*$'
    local comment_pattern='^[[:space:]]*//'

    validated_development_team=""
    validated_development_team_config_hash=""

    if [[ -L "$config" || ! -f "$config" ]]; then
        echo "Signing config must be one regular, non-symlink file: $config" >&2
        return 78
    fi

    owner_uid="$(stat -f '%u' "$config")"
    link_count="$(stat -f '%l' "$config")"
    mode="$(stat -f '%Lp' "$config")"
    # The quoted path is local and ACL lines are only available through ls.
    # shellcheck disable=SC2012
    acl_entries="$(ls -lde "$config" \
        | awk 'NR > 1 { count += 1 } END { print count + 0 }')"
    if [[ "$owner_uid" != "$(id -u)" || "$link_count" != "1" ]]; then
        echo "Signing config must be owned only by the current user" >&2
        return 78
    fi
    if (( (8#$mode & 8#022) != 0 )) || [[ "$acl_entries" != "0" ]]; then
        echo "Signing config must not be writable through group, other, or ACL access" >&2
        return 78
    fi

    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" =~ ^[[:space:]]*$ || "$line" =~ $comment_pattern ]]; then
            continue
        fi
        if [[ "$line" =~ $team_pattern ]]; then
            validated_development_team="${BASH_REMATCH[1]}"
            ((team_count += 1))
            continue
        fi
        echo "Signing config may contain only comments and one DEVELOPMENT_TEAM assignment" >&2
        return 78
    done <"$config"

    if [[ "$team_count" != "1" ]]; then
        echo "Signing config must contain exactly one DEVELOPMENT_TEAM assignment" >&2
        return 78
    fi
    validated_development_team_config_hash="$(shasum -a 256 "$config" \
        | awk '{ print $1 }')"
}

verify_development_team_config_unchanged() {
    local config="$1"
    local expected_team="$2"
    local expected_hash="$3"

    validate_development_team_config "$config" || return $?
    if [[ "$validated_development_team" != "$expected_team" \
        || "$validated_development_team_config_hash" != "$expected_hash" ]]; then
        echo "Signing config changed while building; discard the artifacts" >&2
        return 65
    fi
}

prepare_xcode_signing_environment() {
    local sanitized_config="$1"

    XCODE_XCCONFIG_FILE="$sanitized_config"
    export XCODE_XCCONFIG_FILE
    unset \
        TOOLCHAINS \
        XCRUN_TOOLCHAIN_NAME \
        SDKROOT \
        CC \
        CXX \
        LD \
        AR \
        AS \
        NM \
        RANLIB \
        STRIP \
        COMPILER_PATH \
        GCC_EXEC_PREFIX \
        CPATH \
        C_INCLUDE_PATH \
        CPLUS_INCLUDE_PATH \
        OBJC_INCLUDE_PATH \
        LIBRARY_PATH \
        LD_LIBRARY_PATH \
        DYLD_LIBRARY_PATH \
        DYLD_FRAMEWORK_PATH \
        SWIFT_EXEC \
        SWIFT_FRONTEND_EXEC \
        SWIFT_DRIVER_SWIFT_FRONTEND_EXEC \
        MACOSX_DEPLOYMENT_TARGET \
        IPHONEOS_DEPLOYMENT_TARGET \
        WATCHOS_DEPLOYMENT_TARGET
}
