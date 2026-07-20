#!/bin/bash
# shellcheck disable=SC2034

# Shared validation for the gitignored Apple Team configuration.
# This file is sourced by signed release scripts.

validated_release_source_commit=""
validated_release_source_tree=""

sanitize_release_git_environment() {
    local variable

    # Repository selectors, command-line config injection, and replacement
    # refs must not redirect or reinterpret the source snapshot being signed.
    for variable in "${!GIT_@}"; do
        unset "$variable"
    done
    for variable in "${!DYLD_@}"; do
        unset "$variable"
    done
    for variable in "${!CCC_@}"; do
        unset "$variable"
    done
    unset \
        BASH_ENV \
        COPY_EXTENDED_ATTRIBUTES_DISABLE \
        COPYFILE_DISABLE \
        ENV \
        GREP_OPTIONS \
        PERL5LIB \
        PERL5OPT \
        PERLLIB \
        TAR_OPTIONS \
        xcrun_cache_path \
        xcrun_log \
        xcrun_verbose
    COPY_EXTENDED_ATTRIBUTES_DISABLE=1
    COPYFILE_DISABLE=1
    LC_ALL=C
    GIT_ATTR_NOSYSTEM=1
    GIT_CONFIG_GLOBAL=/dev/null
    GIT_CONFIG_NOSYSTEM=1
    GIT_NO_REPLACE_OBJECTS=1
    export \
        GIT_ATTR_NOSYSTEM \
        GIT_CONFIG_GLOBAL \
        GIT_CONFIG_NOSYSTEM \
        GIT_NO_REPLACE_OBJECTS \
        COPY_EXTENDED_ATTRIBUTES_DISABLE \
        COPYFILE_DISABLE \
        LC_ALL
}

pin_clean_release_source() {
    local project_root="$1"
    local canonical_root
    local repository_root
    local source_commit
    local source_tree
    local status_output

    validated_release_source_commit=""
    validated_release_source_tree=""
    if [[ -L "$project_root" || ! -d "$project_root" ]]; then
        echo "Release source root is missing or unsafe" >&2
        return 65
    fi
    canonical_root="$(cd "$project_root" >/dev/null && pwd -P)" || return 65
    repository_root="$(/usr/bin/git -C "$canonical_root" rev-parse \
        --show-toplevel)" || return 65
    if [[ "$repository_root" != "$canonical_root" ]]; then
        echo "Release source root does not match the Git worktree" >&2
        return 65
    fi
    source_commit="$(/usr/bin/git -C "$canonical_root" rev-parse \
        --verify 'HEAD^{commit}')" || return 65
    source_tree="$(/usr/bin/git -C "$canonical_root" rev-parse \
        --verify "$source_commit^{tree}")" || return 65
    validate_release_git_repository_configuration "$canonical_root" \
        || return $?
    if ! status_output="$(/usr/bin/git \
            -c core.fsmonitor=false \
            -c core.untrackedCache=false \
            -C "$canonical_root" status --no-renames \
            --porcelain --untracked-files=normal \
            --ignore-submodules=all)"; then
        echo "Could not verify that the release source is clean" >&2
        return 65
    fi
    if [[ -n "$status_output" ]]; then
        echo "Refusing release artifacts from a dirty Git working tree" >&2
        return 65
    fi

    validated_release_source_commit="$source_commit"
    validated_release_source_tree="$source_tree"
}

verify_pinned_release_source_unchanged() {
    local project_root="$1"
    local expected_commit="$2"
    local expected_tree="$3"
    local actual_commit
    local actual_tree
    local status_output

    actual_commit="$(/usr/bin/git -C "$project_root" rev-parse \
        --verify 'HEAD^{commit}')" || return 65
    actual_tree="$(/usr/bin/git -C "$project_root" rev-parse \
        --verify "$actual_commit^{tree}")" || return 65
    validate_release_git_repository_configuration "$project_root" \
        || return $?
    if ! status_output="$(/usr/bin/git \
            -c core.fsmonitor=false \
            -c core.untrackedCache=false \
            -C "$project_root" status --no-renames \
            --porcelain --untracked-files=normal \
            --ignore-submodules=all)"; then
        echo "Could not recheck the release source" >&2
        return 65
    fi
    if [[ "$actual_commit" != "$expected_commit" \
        || "$actual_tree" != "$expected_tree" \
        || -n "$status_output" ]]; then
        echo "Source changed while building; discard these artifacts" >&2
        return 65
    fi
}

validate_release_git_repository_configuration() {
    local project_root="$1"
    local unsafe_configuration
    local config_status=0

    unsafe_configuration="$(/usr/bin/git -C "$project_root" config \
        --includes --name-only --get-regexp \
        '^(core\.fsmonitor|core\.attributesfile|filter\..*\.(clean|process|required))$')" \
        || config_status=$?
    if [[ "$config_status" != "0" && "$config_status" != "1" ]]; then
        echo "Could not validate local Git release configuration" >&2
        return 65
    fi
    if [[ -n "$unsafe_configuration" ]]; then
        echo "Repository Git configuration can alter or execute during release validation" >&2
        return 65
    fi
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

prepare_xcode_signing_environment() {
    local sanitized_config="$1"
    local variable

    XCODE_XCCONFIG_FILE="$sanitized_config"
    export XCODE_XCCONFIG_FILE
    for variable in "${!DYLD_@}"; do
        unset "$variable"
    done
    for variable in "${!CCC_@}"; do
        unset "$variable"
    done
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
