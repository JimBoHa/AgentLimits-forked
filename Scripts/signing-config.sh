#!/bin/bash

# Shared validation for the gitignored Apple Team configuration.
# This file is sourced by signed release scripts.

sanitize_release_tool_environment() {
    local variable

    # System release tools must not inherit Clang-driver or loader injection,
    # nor option files that can change grep, Perl, or bsdtar behavior before
    # Xcode starts. Clear the complete dynamic namespaces, not only names known
    # by today's toolchain.
    for variable in "${!CCC_@}" "${!DYLD_@}"; do
        if [[ -n "$variable" ]]; then
            unset "$variable"
        fi
    done
    unset \
        BASH_ENV \
        ENV \
        GREP_OPTIONS \
        PERL5OPT \
        PERL5LIB \
        PERLLIB \
        TAR_READER_OPTIONS \
        TAR_WRITER_OPTIONS \
        COPYFILE_DISABLE
}

sanitize_release_git_environment() {
    local variable

    sanitize_release_tool_environment
    # Repository selectors, command-line config injection, and replacement
    # refs must not redirect or reinterpret the source snapshot being signed.
    for variable in "${!GIT_@}"; do
        unset "$variable"
    done
    GIT_ATTR_NOSYSTEM=1
    GIT_CONFIG_GLOBAL=/dev/null
    GIT_CONFIG_NOSYSTEM=1
    GIT_NO_REPLACE_OBJECTS=1
    export \
        GIT_ATTR_NOSYSTEM \
        GIT_CONFIG_GLOBAL \
        GIT_CONFIG_NOSYSTEM \
        GIT_NO_REPLACE_OBJECTS
}

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

sanitize_release_xcode_environment() {
    local variable

    sanitize_release_tool_environment
    # Release builds accept build settings only from checked-in project files,
    # explicit xcodebuild arguments, and the validated Team-only xcconfig.
    # These namespaces are concrete compiler/driver/loader override surfaces;
    # clearing each whole namespace also covers new variables in those families.
    for variable in \
        "${!CCC_@}" \
        "${!CLANG_@}" \
        "${!DYLD_@}" \
        "${!GCC_@}" \
        "${!LD_@}" \
        "${!RC_@}" \
        "${!SWIFT_@}" \
        "${!XCODE_@}" \
        "${!XCRUN_@}" \
        "${!xcrun_@}"; do
        if [[ -n "$variable" ]]; then
            unset "$variable"
        fi
    done

    unset \
        ARCHS \
        EXCLUDED_ARCHS \
        ONLY_ACTIVE_ARCH \
        VALID_ARCHS \
        SDKROOT \
        CCC_ADD_ARGS \
        CCC_OVERRIDE_OPTIONS \
        CCC_PRINT_OPTIONS \
        CCC_PRINT_OPTIONS_FILE \
        ADDITIONAL_SWIFT_DRIVER_FLAGS \
        CC \
        CXX \
        CPP \
        LD \
        AR \
        AS \
        NM \
        RANLIB \
        STRIP \
        LIPO \
        LIBTOOL \
        OTOOL \
        DSYMUTIL \
        CODESIGN_ALLOCATE \
        COMPILER_PATH \
        GCC_EXEC_PREFIX \
        CPATH \
        C_INCLUDE_PATH \
        CPLUS_INCLUDE_PATH \
        OBJC_INCLUDE_PATH \
        OBJCPLUS_INCLUDE_PATH \
        LIBRARY_PATH \
        FRAMEWORK_SEARCH_PATHS \
        HEADER_SEARCH_PATHS \
        LIBRARY_SEARCH_PATHS \
        SYSTEM_FRAMEWORK_SEARCH_PATHS \
        SYSTEM_HEADER_SEARCH_PATHS \
        USER_HEADER_SEARCH_PATHS \
        CLANG_MODULE_CACHE_PATH \
        MODULE_CACHE_DIR \
        OTHER_CFLAGS \
        OTHER_CPLUSPLUSFLAGS \
        OTHER_LDFLAGS \
        OTHER_SWIFT_FLAGS \
        GCC_PREPROCESSOR_DEFINITIONS \
        SWIFT_EXEC \
        SWIFT_FRONTEND_EXEC \
        SWIFT_DRIVER_SWIFT_FRONTEND_EXEC \
        SWIFT_DRIVER_SWIFTSCAN_LIB \
        SWIFT_DRIVER_TOOLCHAIN_CASPLUGIN_LIB \
        SWIFT_INCLUDE_PATHS \
        SWIFT_PLUGIN_SEARCH_PATHS \
        TOOLCHAINS \
        XCRUN_TOOLCHAIN_NAME \
        MACOSX_DEPLOYMENT_TARGET \
        IPHONEOS_DEPLOYMENT_TARGET \
        WATCHOS_DEPLOYMENT_TARGET \
        ZERO_AR_DATE \
        GREP_OPTIONS \
        xcrun_verbose \
        xcrun_log
}

prepare_xcode_signing_environment() {
    local sanitized_config="$1"

    sanitize_release_xcode_environment
    XCODE_XCCONFIG_FILE="$sanitized_config"
    export XCODE_XCCONFIG_FILE
}
