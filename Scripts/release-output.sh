#!/bin/bash
# shellcheck disable=SC2034

# Safe output-directory handling for signed release scripts.
# This file is sourced by export-ios.sh, package-macos.sh, and their tests.

validated_release_output_parent=""
validated_release_output_parent_identity=""
validated_release_output_name=""
validated_release_output_directory=""
validated_release_publication_lock=""
validated_release_publication_lock_identity=""
validated_release_staging_parent=""
validated_release_staging_parent_identity=""
validated_release_staging_directory=""
validated_release_staging_directory_identity=""
validated_release_work_directory=""
validated_release_work_directory_identity=""
validated_release_temporary_directory=""
validated_release_atomic_publisher=""
validated_release_atomic_publisher_identity=""
validated_release_atomic_publisher_hash=""
validated_release_source_snapshot=""
validated_release_source_snapshot_identity=""

release_path_identity() {
    local path="$1"

    stat -f '%d:%i' "$path"
}

release_mutating_acl_entry_count() {
    local path="$1"

    # Paths are local release paths. ACL entries are available only through ls.
    # shellcheck disable=SC2012
    ls -lde "$path" \
        | awk 'NR > 1 && / allow / && \
            /(write|append|delete|add_file|add_subdirectory|chown)/ \
            { count += 1 } END { print count + 0 }'
}

release_acl_entry_count() {
    local path="$1"

    # Paths are local release paths. ACL entries are available only through ls.
    # shellcheck disable=SC2012
    ls -lde "$path" \
        | awk 'NR > 1 { count += 1 } END { print count + 0 }'
}

verify_release_output_parent() {
    local output_parent="$1"
    local expected_identity="$2"
    local canonical_parent
    local owner
    local mode
    local identity
    local mutating_acl_entries

    if [[ -L "$output_parent" || ! -d "$output_parent" ]]; then
        echo "Output parent is no longer one regular directory" >&2
        return 73
    fi
    canonical_parent="$(cd "$output_parent" && pwd -P)" || return 73
    if [[ "$canonical_parent" != "$output_parent" ]]; then
        echo "Output parent path changed while building" >&2
        return 73
    fi
    owner="$(stat -f '%u' "$output_parent")" || return 73
    mode="$(stat -f '%Lp' "$output_parent")" || return 73
    identity="$(release_path_identity "$output_parent")" || return 73
    mutating_acl_entries="$(release_mutating_acl_entry_count \
        "$output_parent")" || return 73
    if [[ "$owner" != "$(id -u)" \
        || $((8#$mode & 8#022)) -ne 0 \
        || "$mutating_acl_entries" != "0" ]]; then
        echo "Output parent must be current-user-owned without external write access" >&2
        return 73
    fi
    if [[ -n "$expected_identity" && "$identity" != "$expected_identity" ]]; then
        echo "Output parent identity changed while building" >&2
        return 73
    fi
}

validate_release_output_request() {
    local requested_output="$1"
    local project_root="$2"
    local requested_parent
    local output_parent
    local output_name
    local output_directory
    local parent_identity

    validated_release_output_parent=""
    validated_release_output_parent_identity=""
    validated_release_output_name=""
    validated_release_output_directory=""

    if [[ "$requested_output" != /* ]]; then
        echo "Output directory must be an absolute path" >&2
        return 64
    fi
    output_name="${requested_output##*/}"
    requested_parent="${requested_output%/*}"
    if [[ -z "$requested_parent" ]]; then
        requested_parent="/"
    fi
    if [[ -z "$output_name" || "$output_name" == "." \
        || "$output_name" == ".." || "$output_name" == */* ]]; then
        echo "Output directory name is unsafe" >&2
        return 64
    fi
    if [[ -L "$requested_parent" || ! -d "$requested_parent" ]]; then
        echo "Output parent must already be one regular directory: $requested_parent" >&2
        return 73
    fi
    output_parent="$(cd "$requested_parent" && pwd -P)" || return 73
    output_directory="${output_parent%/}/$output_name"
    if [[ "$requested_output" != "$output_directory" ]]; then
        echo "Output path must be canonical and contain no traversal or symlink aliases" >&2
        return 64
    fi
    parent_identity="$(release_path_identity "$output_parent")" || return 73
    verify_release_output_parent "$output_parent" "$parent_identity" \
        || return $?
    if [[ -e "$output_directory" || -L "$output_directory" ]]; then
        echo "Refusing to overwrite existing path: $output_directory" >&2
        return 73
    fi
    case "$output_directory/" in
        "$project_root/"*)
            echo "Output directory must be outside the source tree" >&2
            return 73
            ;;
    esac

    validated_release_output_parent="$output_parent"
    validated_release_output_parent_identity="$parent_identity"
    validated_release_output_name="$output_name"
    validated_release_output_directory="$output_directory"
}

verify_private_release_directory() {
    local directory="$1"
    local owner
    local mode
    local acl_entries

    if [[ -L "$directory" || ! -d "$directory" ]]; then
        echo "Private release directory is missing or unsafe" >&2
        return 73
    fi
    owner="$(stat -f '%u' "$directory")" || return 73
    if [[ "$owner" != "$(id -u)" ]]; then
        echo "Private release directory has an unexpected owner" >&2
        return 73
    fi
    mode="$(stat -f '%Lp' "$directory")" || return 73
    acl_entries="$(release_acl_entry_count "$directory")" || return 73
    if [[ "$mode" != "700" || "$acl_entries" != "0" ]]; then
        echo "Could not make release directory private" >&2
        return 73
    fi
}

make_release_directory_private() {
    local directory="$1"

    if [[ -L "$directory" || ! -d "$directory" ]]; then
        echo "Private release directory is missing or unsafe" >&2
        return 73
    fi
    chmod -N "$directory" 2>/dev/null || return 73
    chmod 700 "$directory" || return 73
    verify_private_release_directory "$directory"
}

acquire_release_publication_lock() {
    local output_parent="$1"
    local output_name="$2"
    local expected_parent_identity="$3"
    local output_directory="$output_parent/$output_name"
    local publication_lock="$output_parent/.$output_name.AgentLimits-release.lock"
    local lock_identity

    validated_release_publication_lock=""
    validated_release_publication_lock_identity=""
    verify_release_output_parent \
        "$output_parent" "$expected_parent_identity" || return $?
    if [[ -e "$output_directory" || -L "$output_directory" ]]; then
        echo "Output path appeared before lock acquisition: $output_directory" >&2
        return 73
    fi
    if [[ -e "$publication_lock" || -L "$publication_lock" ]] \
        || ! mkdir -m 700 "$publication_lock" 2>/dev/null; then
        echo "Another release may already target this output directory" >&2
        return 73
    fi
    if ! make_release_directory_private "$publication_lock"; then
        rmdir "$publication_lock" 2>/dev/null || true
        return 73
    fi
    lock_identity="$(release_path_identity "$publication_lock")" || {
        rmdir "$publication_lock" 2>/dev/null || true
        return 73
    }
    if ! verify_release_output_parent \
            "$output_parent" "$expected_parent_identity" \
        || [[ -e "$output_directory" || -L "$output_directory" ]]; then
        rmdir "$publication_lock" 2>/dev/null || true
        echo "Output path appeared during lock acquisition: $output_directory" >&2
        return 73
    fi

    validated_release_publication_lock="$publication_lock"
    validated_release_publication_lock_identity="$lock_identity"
}

release_release_publication_lock() {
    local publication_lock="$1"
    local expected_lock_identity="$2"
    local output_parent="$3"
    local output_name="$4"
    local expected_lock="$output_parent/.$output_name.AgentLimits-release.lock"
    local actual_identity

    if [[ -z "$publication_lock" ]]; then
        return 0
    fi
    if [[ "$publication_lock" != "$expected_lock" \
        || -L "$publication_lock" || ! -d "$publication_lock" ]]; then
        echo "Publication lock path changed; refusing cleanup: $publication_lock" >&2
        return 73
    fi
    actual_identity="$(release_path_identity "$publication_lock")" || return 73
    if [[ "$actual_identity" != "$expected_lock_identity" \
        || "$(stat -f '%u' "$publication_lock")" != "$(id -u)" ]]; then
        echo "Publication lock identity changed; refusing cleanup" >&2
        return 73
    fi
    if ! rmdir "$publication_lock" 2>/dev/null; then
        echo "Could not remove publication lock: $publication_lock" >&2
        return 73
    fi
}

create_release_staging_directory() {
    local output_parent="$1"
    local output_name="$2"
    local expected_parent_identity="$3"
    local stage_label="$4"
    local output_device
    local staging_device
    local staging_parent
    local staging_directory

    validated_release_staging_parent=""
    validated_release_staging_parent_identity=""
    validated_release_staging_directory=""
    validated_release_staging_directory_identity=""
    if [[ ! "$stage_label" =~ ^[a-z0-9-]+$ ]]; then
        echo "Release staging label is unsafe" >&2
        return 64
    fi
    verify_release_output_parent \
        "$output_parent" "$expected_parent_identity" || return $?
    if [[ -e "$output_parent/$output_name" \
        || -L "$output_parent/$output_name" ]]; then
        echo "Output path appeared before staging" >&2
        return 73
    fi
    staging_parent="$(mktemp -d \
        "$output_parent/.AgentLimits-$stage_label-stage.XXXXXX")" \
        || return 73
    if ! make_release_directory_private "$staging_parent"; then
        rm -rf "$staging_parent"
        return 73
    fi
    staging_directory="$staging_parent/$output_name"
    if ! mkdir -m 700 "$staging_directory" \
        || ! make_release_directory_private "$staging_directory"; then
        rm -rf "$staging_parent"
        return 73
    fi
    if ! output_device="$(stat -f '%d' "$output_parent")" \
        || ! staging_device="$(stat -f '%d' "$staging_parent")"; then
        rm -rf "$staging_parent"
        return 73
    fi
    if [[ "$staging_device" != "$output_device" ]]; then
        echo "Release staging directory is not on the output filesystem" >&2
        rm -rf "$staging_parent"
        return 73
    fi

    if ! validated_release_staging_parent_identity="$(release_path_identity \
            "$staging_parent")" \
        || ! validated_release_staging_directory_identity="$(release_path_identity \
            "$staging_directory")"; then
        rm -rf "$staging_parent"
        validated_release_staging_parent_identity=""
        validated_release_staging_directory_identity=""
        return 73
    fi
    validated_release_staging_parent="$staging_parent"
    validated_release_staging_directory="$staging_directory"
}

create_private_release_work_directory() {
    local work_label="$1"
    local work_directory

    validated_release_work_directory=""
    validated_release_work_directory_identity=""
    if [[ ! "$work_label" =~ ^AgentLimits-[A-Za-z0-9-]+$ ]]; then
        echo "Release work label is unsafe" >&2
        return 64
    fi
    work_directory="$(mktemp -d "/private/tmp/$work_label.XXXXXX")" \
        || return 73
    if ! make_release_directory_private "$work_directory"; then
        rm -rf "$work_directory"
        return 73
    fi
    if ! validated_release_work_directory_identity="$(release_path_identity \
            "$work_directory")"; then
        rm -rf "$work_directory"
        validated_release_work_directory_identity=""
        return 73
    fi
    validated_release_work_directory="$work_directory"
}

configure_private_release_temporary_directory() {
    local work_directory="$1"
    local temporary_directory="$work_directory/tmp"

    validated_release_temporary_directory=""
    verify_private_release_directory "$work_directory" || return $?
    if [[ -e "$temporary_directory" || -L "$temporary_directory" ]] \
        || ! mkdir -m 700 "$temporary_directory" \
        || ! make_release_directory_private "$temporary_directory"; then
        echo "Could not create a private release temporary directory" >&2
        return 73
    fi
    TMPDIR="$temporary_directory/"
    export TMPDIR
    validated_release_temporary_directory="$temporary_directory"
}

validate_release_source_snapshot_matches_tree() {
    local project_root="$1"
    local expected_tree="$2"
    local source_snapshot="$3"
    local expect_read_only="${4:-false}"
    local validation_directory="${source_snapshot%/*}/.AgentLimits-source-validation"
    local tree_records="$validation_directory/tree-records"
    local expected_paths_raw="$validation_directory/expected-paths.raw"
    local expected_paths="$validation_directory/expected-paths"
    local actual_paths="$validation_directory/actual-paths"
    local unsupported_paths="$validation_directory/unsupported-paths"
    local entry
    local metadata
    local mode
    local type
    local object_id
    local path
    local snapshot_path
    local actual_mode
    local expected_mode
    local actual_object_id
    local validation_failed=0

    if [[ -e "$validation_directory" || -L "$validation_directory" ]] \
        || ! mkdir -m 700 "$validation_directory"; then
        echo "Could not create release source validation state" >&2
        return 73
    fi
    if ! /usr/bin/git -C "$project_root" ls-tree -r -z --full-tree \
            "$expected_tree" >"$tree_records"; then
        echo "Could not enumerate the pinned release source tree" >&2
        rm -rf "$validation_directory"
        return 65
    fi
    : >"$expected_paths_raw"
    while IFS= read -r -d '' entry; do
        if [[ "$entry" != *$'\t'* ]]; then
            validation_failed=1
            break
        fi
        metadata="${entry%%$'\t'*}"
        path="${entry#*$'\t'}"
        read -r mode type object_id extra <<<"$metadata"
        if [[ -n "${extra:-}" || "$type" != "blob" \
            || ( "$mode" != "100644" && "$mode" != "100755" ) \
            || ! "$object_id" =~ ^[0-9a-f]{40}([0-9a-f]{24})?$ \
            || -z "$path" || "$path" == /* \
            || "$path" == "." || "$path" == ".." \
            || "$path" == ../* || "$path" == */../* \
            || "$path" == */.. || "$path" == ./* \
            || "$path" == */./* || "$path" == */. ]]; then
            validation_failed=1
            break
        fi
        snapshot_path="$source_snapshot/$path"
        if [[ -L "$snapshot_path" || ! -f "$snapshot_path" ]]; then
            validation_failed=1
            break
        fi
        actual_mode="$(/usr/bin/stat -f '%Lp' "$snapshot_path")" \
            || validation_failed=1
        expected_mode="${mode#100}"
        if [[ "$expect_read_only" == "true" ]]; then
            if [[ "$mode" == "100644" ]]; then
                expected_mode="444"
            else
                expected_mode="555"
            fi
        fi
        if [[ "$validation_failed" != "0" \
            || "$actual_mode" != "$expected_mode" \
            || "$(/usr/bin/stat -f '%u' "$snapshot_path")" != "$(id -u)" \
            || "$(/usr/bin/stat -f '%l' "$snapshot_path")" != "1" ]]; then
            validation_failed=1
            break
        fi
        actual_object_id="$(/usr/bin/git -C "$project_root" hash-object \
            --no-filters "$snapshot_path")" || validation_failed=1
        if [[ "$validation_failed" != "0" \
            || "$actual_object_id" != "$object_id" ]]; then
            validation_failed=1
            break
        fi
        printf './%s\0' "$path" >>"$expected_paths_raw" \
            || validation_failed=1
        if [[ "$validation_failed" != "0" ]]; then
            break
        fi
    done <"$tree_records"
    if [[ "$validation_failed" != "0" ]]; then
        echo "Release source snapshot differs from the pinned Git tree" >&2
        rm -rf "$validation_directory"
        return 73
    fi
    if ! LC_ALL=C /usr/bin/sort -z "$expected_paths_raw" \
            >"$expected_paths" \
        || ! (
            cd "$source_snapshot" \
                && /usr/bin/find . ! -type d ! -type f ! -type l \
                    -print0 >"$unsupported_paths"
        ) \
        || [[ -s "$unsupported_paths" ]] \
        || ! (
            set -o pipefail
            cd "$source_snapshot" \
                && /usr/bin/find . \( -type f -o -type l \) -print0 \
                    | LC_ALL=C /usr/bin/sort -z >"$actual_paths"
        ) \
        || ! /usr/bin/cmp -s "$expected_paths" "$actual_paths"; then
        echo "Release source snapshot inventory differs from the pinned Git tree" >&2
        rm -rf "$validation_directory"
        return 73
    fi
    rm -rf "$validation_directory"
}

verify_immutable_release_source_snapshot() {
    local source_snapshot="$1"
    local expected_identity="$2"
    local inventory
    local path
    local owner
    local mode
    local flags
    local snapshot_device
    local path_device
    local verification_failed=0

    if [[ -L "$source_snapshot" || ! -d "$source_snapshot" \
        || "$(release_path_identity "$source_snapshot")" \
            != "$expected_identity" ]]; then
        echo "Release source snapshot identity changed" >&2
        return 73
    fi
    snapshot_device="$(/usr/bin/stat -f '%d' "$source_snapshot")" \
        || return 73
    inventory="${source_snapshot%/*}/.AgentLimits-source-inventory"
    if ! /usr/bin/find -x "$source_snapshot" -print0 >"$inventory"; then
        echo "Could not traverse the release source snapshot" >&2
        rm -f "$inventory"
        return 73
    fi
    while IFS= read -r -d '' path; do
        if [[ -L "$path" || ( ! -d "$path" && ! -f "$path" ) ]]; then
            echo "Release source snapshot contains a non-regular path" >&2
            verification_failed=1
            break
        fi
        owner="$(/usr/bin/stat -f '%u' "$path")" \
            || verification_failed=1
        mode="$(/usr/bin/stat -f '%Lp' "$path")" \
            || verification_failed=1
        flags="$(/usr/bin/stat -f '%Sf' "$path")" \
            || verification_failed=1
        path_device="$(/usr/bin/stat -f '%d' "$path")" \
            || verification_failed=1
        if [[ "$verification_failed" != "0" ]]; then
            break
        fi
        if [[ "$owner" != "$(id -u)" \
            || "$path_device" != "$snapshot_device" \
            || $((8#$mode & 8#222)) -ne 0 \
            || "$flags" != *uchg* ]]; then
            echo "Release source snapshot is not immutable" >&2
            verification_failed=1
            break
        fi
        if [[ -f "$path" \
            && "$(/usr/bin/stat -f '%l' "$path")" != "1" ]]; then
            echo "Release source snapshot contains a linked file" >&2
            verification_failed=1
            break
        fi
    done <"$inventory"
    rm -f "$inventory"
    if [[ "$verification_failed" != "0" ]]; then
        return 73
    fi
}

unlock_immutable_release_source_snapshot_for_cleanup() {
    local source_snapshot="$1"
    local expected_identity="$2"
    local expected_work_directory="$3"
    local project_root="$4"
    local expected_tree="$5"

    if [[ -z "$source_snapshot" ]]; then
        return 0
    fi
    if [[ "${source_snapshot%/*}" != "$expected_work_directory" \
        || "${source_snapshot##*/}" != "source" \
        || -L "$source_snapshot" || ! -d "$source_snapshot" \
        || "$(release_path_identity "$source_snapshot")" \
            != "$expected_identity" \
        || "$(/usr/bin/stat -f '%u' "$source_snapshot")" != "$(id -u)" ]]; then
        echo "Release source snapshot changed; preserving temporary work" >&2
        return 73
    fi
    verify_immutable_release_source_snapshot \
        "$source_snapshot" "$expected_identity" || return $?
    validate_release_source_snapshot_matches_tree \
        "$project_root" "$expected_tree" "$source_snapshot" true || return $?
    /usr/bin/chflags -R nouchg "$source_snapshot" || return 73
    /bin/chmod -R u+w "$source_snapshot" || return 73
}

create_immutable_release_source_snapshot() {
    local project_root="$1"
    local source_commit="$2"
    local source_tree="$3"
    local work_directory="$4"
    local source_snapshot="$work_directory/source"
    local source_snapshot_identity
    local actual_tree
    local archive_status=0

    validated_release_source_snapshot=""
    validated_release_source_snapshot_identity=""
    verify_private_release_directory "$work_directory" || return $?
    if [[ -L "$project_root" || ! -d "$project_root" \
        || -e "$source_snapshot" || -L "$source_snapshot" ]]; then
        echo "Release source snapshot path is unsafe" >&2
        return 73
    fi
    actual_tree="$(/usr/bin/git -C "$project_root" rev-parse \
        --verify "$source_commit^{tree}")" || return 65
    if [[ "$actual_tree" != "$source_tree" ]]; then
        echo "Pinned release source tree changed" >&2
        return 65
    fi
    if ! mkdir -m 700 "$source_snapshot" \
        || ! make_release_directory_private "$source_snapshot"; then
        echo "Could not create a private release source snapshot" >&2
        return 73
    fi
    source_snapshot_identity="$(release_path_identity "$source_snapshot")" \
        || return 73

    (
        umask 022
        set -o pipefail
        /usr/bin/git -C "$project_root" archive --format=tar "$source_commit" \
            | /usr/bin/tar -xf - -C "$source_snapshot"
    ) || archive_status=$?
    if [[ "$archive_status" != "0" ]] \
        || ! validate_release_source_snapshot_matches_tree \
            "$project_root" "$source_tree" "$source_snapshot"; then
        echo "Could not create an exact release source snapshot" >&2
        rm -rf "$source_snapshot"
        return 73
    fi
    if ! /bin/chmod -RN "$source_snapshot" \
        || ! /bin/chmod -R a-w "$source_snapshot" \
        || ! /usr/bin/chflags -R uchg "$source_snapshot"; then
        echo "Could not make the release source snapshot immutable" >&2
        /usr/bin/chflags -R nouchg "$source_snapshot" 2>/dev/null || true
        /bin/chmod -R u+w "$source_snapshot" 2>/dev/null || true
        rm -rf "$source_snapshot"
        return 73
    fi
    if ! verify_immutable_release_source_snapshot \
            "$source_snapshot" "$source_snapshot_identity"; then
        unlock_immutable_release_source_snapshot_for_cleanup \
            "$source_snapshot" \
            "$source_snapshot_identity" \
            "$work_directory" \
            "$project_root" \
            "$source_tree" \
            || true
        rm -rf "$source_snapshot"
        return 73
    fi

    validated_release_source_snapshot="$source_snapshot"
    validated_release_source_snapshot_identity="$source_snapshot_identity"
}

build_atomic_release_publisher() {
    local source="$1"
    local output="$2"
    local output_parent="${output%/*}"
    local link_count
    local publisher_hash

    validated_release_atomic_publisher=""
    validated_release_atomic_publisher_identity=""
    validated_release_atomic_publisher_hash=""
    if [[ -L "$source" || ! -f "$source" \
        || -L "$output" || -e "$output" ]]; then
        echo "Atomic publisher source or output path is unsafe" >&2
        return 73
    fi
    link_count="$(stat -f '%l' "$source")" || return 73
    if [[ "$link_count" != "1" ]]; then
        echo "Atomic publisher source must have one filesystem link" >&2
        return 73
    fi
    verify_private_release_directory "$output_parent" || return $?
    if ! /usr/bin/xcrun --no-cache --sdk macosx clang \
        -std=c17 \
        -mmacosx-version-min=14.0 \
        -Os \
        -Wall \
        -Wextra \
        -Werror \
        -Wl,-fatal_warnings \
        "$source" \
        -o "$output"; then
        echo "Could not build the atomic release publisher" >&2
        rm -f "$output"
        return 70
    fi
    if [[ -L "$output" || ! -f "$output" \
        || "$(stat -f '%u' "$output")" != "$(id -u)" \
        || "$(stat -f '%l' "$output")" != "1" ]]; then
        echo "Atomic release publisher output is unsafe" >&2
        rm -f "$output"
        return 73
    fi
    chmod -N "$output" 2>/dev/null || return 73
    chmod 700 "$output" || return 73
    if [[ "$(stat -f '%Lp' "$output")" != "700" \
        || "$(release_acl_entry_count "$output")" != "0" \
        || ! -x "$output" ]]; then
        echo "Atomic release publisher is not private and executable" >&2
        rm -f "$output"
        return 73
    fi
    publisher_hash="$(shasum -a 256 "$output" | awk '{ print $1 }')" \
        || return 73
    if [[ ! "$publisher_hash" =~ ^[0-9a-f]{64}$ ]]; then
        echo "Could not hash the atomic release publisher" >&2
        rm -f "$output"
        return 73
    fi

    validated_release_atomic_publisher="$output"
    validated_release_atomic_publisher_identity="$(release_path_identity \
        "$output")"
    validated_release_atomic_publisher_hash="$publisher_hash"
}

verify_atomic_release_publisher() {
    local publisher="$1"
    local expected_identity="$2"
    local expected_hash="$3"
    local actual_hash

    if [[ -L "$publisher" || ! -f "$publisher" || ! -x "$publisher" \
        || "$(stat -f '%u' "$publisher")" != "$(id -u)" \
        || "$(stat -f '%l' "$publisher")" != "1" \
        || "$(stat -f '%Lp' "$publisher")" != "700" \
        || "$(release_acl_entry_count "$publisher")" != "0" \
        || "$(release_path_identity "$publisher")" != "$expected_identity" ]]; then
        echo "Atomic release publisher changed before publication" >&2
        return 73
    fi
    actual_hash="$(shasum -a 256 "$publisher" | awk '{ print $1 }')" \
        || return 73
    if [[ "$actual_hash" != "$expected_hash" ]]; then
        echo "Atomic release publisher content changed before publication" >&2
        return 73
    fi
}

cleanup_private_release_directory() {
    local directory="$1"
    local expected_identity="$2"
    local expected_parent="$3"
    local expected_name_pattern="$4"
    local name
    local actual_identity

    if [[ -z "$directory" ]]; then
        return 0
    fi
    name="${directory##*/}"
    if [[ "${directory%/*}" != "$expected_parent" \
        || ! "$name" =~ $expected_name_pattern \
        || -L "$directory" || ! -d "$directory" ]]; then
        echo "Release cleanup path changed; preserving: $directory" >&2
        return 73
    fi
    actual_identity="$(release_path_identity "$directory")" || return 73
    if [[ "$actual_identity" != "$expected_identity" \
        || "$(stat -f '%u' "$directory")" != "$(id -u)" ]]; then
        echo "Release cleanup identity changed; preserving: $directory" >&2
        return 73
    fi
    rm -rf "$directory"
}

validate_release_publication_validity_headroom() {
    local expiration_epoch="$1"
    local headroom_seconds="$2"
    local validation_epoch="${3:-}"

    if [[ ! "$expiration_epoch" =~ ^[1-9][0-9]*$ \
        || ! "$headroom_seconds" =~ ^[1-9][0-9]*$ ]]; then
        echo "Release publication profile validity fence is invalid" >&2
        return 73
    fi
    if [[ -z "$validation_epoch" ]]; then
        validation_epoch="$(/bin/date -u '+%s')" || return 73
    fi
    if [[ ! "$validation_epoch" =~ ^[1-9][0-9]*$ ]]; then
        echo "Release publication time is invalid" >&2
        return 73
    fi
    if (( validation_epoch + headroom_seconds >= expiration_epoch )); then
        echo "Provisioning profile validity headroom was exhausted before publication" >&2
        return 73
    fi
}

publish_staged_release_directory() {
    local staged_directory="$1"
    local expected_staged_identity="$2"
    local output_parent="$3"
    local expected_parent_identity="$4"
    local expected_name="$5"
    local atomic_publisher="$6"
    local expected_publisher_identity="$7"
    local expected_publisher_hash="$8"
    local expected_staging_parent_identity="$9"
    local profile_expiration_epoch="${10:-}"
    local profile_validity_headroom_seconds="${11:-}"
    local output_directory="$output_parent/$expected_name"
    local staging_parent="${staged_directory%/*}"
    local staged_device
    local output_device
    local actual_staged_identity
    local published_identity
    local publish_status=0

    if [[ -z "$expected_name" || "$expected_name" == "." \
        || "$expected_name" == ".." || "$expected_name" == */* \
        || -z "$expected_staging_parent_identity" \
        || -L "$staging_parent" || ! -d "$staging_parent" \
        || "$(release_path_identity "$staging_parent")" \
            != "$expected_staging_parent_identity" \
        || -L "$staged_directory" || ! -d "$staged_directory" \
        || "${staged_directory##*/}" != "$expected_name" ]]; then
        echo "Staged publication path is unsafe" >&2
        return 73
    fi
    actual_staged_identity="$(release_path_identity "$staged_directory")" \
        || return 73
    if [[ "$actual_staged_identity" != "$expected_staged_identity" ]]; then
        echo "Staged publication identity changed" >&2
        return 73
    fi
    verify_release_output_parent \
        "$output_parent" "$expected_parent_identity" || return $?
    staged_device="$(stat -f '%d' "$staged_directory")" || return 73
    output_device="$(stat -f '%d' "$output_parent")" || return 73
    if [[ "$staged_device" != "$output_device" ]]; then
        echo "Staged output is not on the publication filesystem" >&2
        return 73
    fi
    if [[ -e "$output_directory" || -L "$output_directory" ]]; then
        echo "Output path appeared while building: $output_directory" >&2
        return 73
    fi
    verify_atomic_release_publisher \
        "$atomic_publisher" \
        "$expected_publisher_identity" \
        "$expected_publisher_hash" \
        || return $?
    if [[ -n "$profile_expiration_epoch" \
        || -n "$profile_validity_headroom_seconds" ]]; then
        validate_release_publication_validity_headroom \
            "$profile_expiration_epoch" \
            "$profile_validity_headroom_seconds" \
            || return $?
    fi
    "$atomic_publisher" \
        "$staging_parent" \
        "$expected_name" \
        "$expected_staging_parent_identity" \
        "$expected_staged_identity" \
        "$output_parent" \
        "$expected_name" \
        "$expected_parent_identity" \
        || publish_status=$?
    if [[ "$publish_status" != "0" ]]; then
        echo "Could not atomically publish the staged output directory" >&2
        return 73
    fi
    if [[ -e "$staged_directory" || -L "$staged_directory" \
        || -L "$output_directory" || ! -d "$output_directory" ]]; then
        echo "Output path appeared while building: $output_directory" >&2
        return 73
    fi
    published_identity="$(release_path_identity "$output_directory")" \
        || return 73
    if [[ "$published_identity" != "$expected_staged_identity" ]]; then
        echo "Published output identity does not match staging" >&2
        return 73
    fi
    verify_release_output_parent \
        "$output_parent" "$expected_parent_identity" || return $?
}
