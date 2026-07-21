#!/bin/bash
# shellcheck disable=SC2034

# Apple distribution toolchain validation shared by every release path.
# This file is sourced by the release scripts and their tests.

apple_distribution_minimum_xcode_version="26"
apple_distribution_minimum_sdk_version="26"

validated_apple_toolchain_ready=""
validated_apple_developer_dir=""
validated_apple_xcode_version=""
validated_apple_xcode_build=""
validated_apple_dtxcode=""
validated_apple_macosx_sdk_version=""
validated_apple_macosx_sdk_name=""
validated_apple_macosx_sdk_build=""
validated_apple_iphoneos_sdk_version=""
validated_apple_iphoneos_sdk_name=""
validated_apple_iphoneos_sdk_build=""
validated_apple_watchos_sdk_version=""
validated_apple_watchos_sdk_name=""
validated_apple_watchos_sdk_build=""

apple_validate_numeric_version() {
    local version="$1"
    local label="$2"
    local components
    local component

    if [[ ! "$version" =~ ^[0-9]+(\.[0-9]+)*$ ]]; then
        echo "$label is not a dotted numeric version: $version" >&2
        return 64
    fi
    IFS='.' read -r -a components <<<"$version"
    if (( ${#components[@]} > 4 )); then
        echo "$label has too many numeric components: $version" >&2
        return 64
    fi
    for component in "${components[@]}"; do
        if (( ${#component} > 9 )) \
            || [[ ${#component} -gt 1 && "$component" == 0* ]]; then
            echo "$label has a non-canonical numeric component: $version" >&2
            return 64
        fi
    done
}

apple_version_is_at_least() {
    local actual="$1"
    local minimum="$2"
    local actual_components
    local minimum_components
    local component_count
    local index
    local actual_component
    local minimum_component

    apple_validate_numeric_version "$actual" "Actual version" || return 2
    apple_validate_numeric_version "$minimum" "Minimum version" || return 2
    IFS='.' read -r -a actual_components <<<"$actual"
    IFS='.' read -r -a minimum_components <<<"$minimum"
    component_count=${#actual_components[@]}
    if (( ${#minimum_components[@]} > component_count )); then
        component_count=${#minimum_components[@]}
    fi

    for ((index = 0; index < component_count; index += 1)); do
        actual_component="${actual_components[index]:-0}"
        minimum_component="${minimum_components[index]:-0}"
        actual_component=$((10#$actual_component))
        minimum_component=$((10#$minimum_component))
        if (( actual_component > minimum_component )); then
            return 0
        fi
        if (( actual_component < minimum_component )); then
            return 1
        fi
    done
    return 0
}

apple_require_minimum_version() {
    local actual="$1"
    local minimum="$2"
    local label="$3"
    local comparison_status=0

    apple_version_is_at_least "$actual" "$minimum" || comparison_status=$?
    case "$comparison_status" in
        0)
            return 0
            ;;
        1)
            echo "$label $actual is below required version $minimum" >&2
            return 69
            ;;
        *)
            echo "$label version could not be validated" >&2
            return 69
            ;;
    esac
}

apple_run_selected_tool() (
    local developer_dir="$1"
    local variable

    shift
    # Toolchain discovery needs no caller-controlled build setting, compiler
    # path, plugin path, loader path, cache control, or user configuration.
    # Start from an allowlist so new override variables cannot silently bypass
    # a denylist. Clear loader variables with shell built-ins before launching
    # /usr/bin/env; otherwise dyld can consume them before env -i takes effect.
    # --no-cache is applied by each xcrun caller below.
    for variable in "${!DYLD_@}"; do
        unset "$variable"
    done
    unset xcrun_verbose xcrun_log
    /usr/bin/env -i \
        DEVELOPER_DIR="$developer_dir" \
        LC_ALL=C \
        PATH=/usr/bin:/bin:/usr/sbin:/sbin \
        TMPDIR=/private/tmp/ \
        "$@"
)

apple_validate_xcode_bundle_trust() {
    local developer_dir="$1"
    local canonical_developer_dir
    local xcode_contents
    local xcode_bundle
    local canonical_xcode_bundle
    local trusted_path
    local path_metadata
    local path_owner
    local path_mode
    local path_acl
    local user_id
    local user_groups
    local group_id
    local signature_error
    local untrusted_bundle_entry
    local xcode_requirement
    local -a find_arguments

    if [[ "$developer_dir" != /* \
        || -L "$developer_dir" || ! -d "$developer_dir" ]]; then
        echo "Apple distribution requires one canonical Xcode Developer directory" >&2
        return 69
    fi
    canonical_developer_dir="$(cd "$developer_dir" && pwd -P)" || return 69
    if [[ "$developer_dir" != "$canonical_developer_dir" ]]; then
        echo "Apple distribution requires one canonical Xcode Developer directory" >&2
        return 69
    fi

    xcode_contents="${canonical_developer_dir%/Developer}"
    xcode_bundle="${xcode_contents%/Contents}"
    if [[ "$xcode_contents" == "$canonical_developer_dir" \
        || "$xcode_bundle" == "$xcode_contents" \
        || "$xcode_bundle" != *.app \
        || -L "$xcode_bundle" || ! -d "$xcode_bundle" ]]; then
        echo "Apple distribution requires an Xcode app bundle Developer directory" >&2
        return 69
    fi
    canonical_xcode_bundle="$(cd "$xcode_bundle" && pwd -P)" || return 69
    if [[ "$canonical_xcode_bundle" != "$xcode_bundle" ]]; then
        echo "Apple distribution requires a canonical Xcode app bundle" >&2
        return 69
    fi

    # A valid bundle is not stable when the caller can replace one of its
    # ancestor directory entries after validation. Require every ancestor,
    # including /Applications and /, to be root-owned and immutable to this
    # account before any selected-tool path is used.
    trusted_path="${xcode_bundle%/*}"
    [[ -n "$trusted_path" ]] || trusted_path="/"
    while :; do
        if [[ -L "$trusted_path" || ! -d "$trusted_path" ]] \
            || ! path_metadata="$(/usr/bin/stat -f '%u %Lp' "$trusted_path" 2>/dev/null)" \
            || [[ "$path_metadata" == *$'\n'* ]]; then
            echo "Could not validate selected Xcode ancestor directory" >&2
            return 69
        fi
        path_owner="${path_metadata%% *}"
        path_mode="${path_metadata#* }"
        if [[ "$path_owner" != 0 || ! "$path_mode" =~ ^[0-7]{3,4}$ ]] \
            || (( (8#$path_mode & 022) != 0 )) \
            || [[ -w "$trusted_path" ]]; then
            echo "Selected Xcode ancestor directories must be root-owned and non-writable" >&2
            return 69
        fi
        if ! path_acl="$(
                /usr/bin/find -x "$trusted_path" -prune -acl -print -quit 2>&1
            )"; then
            echo "Could not validate selected Xcode ancestor access controls" >&2
            return 69
        fi
        if [[ -n "$path_acl" ]]; then
            echo "Selected Xcode ancestor directories must not have access-control lists" >&2
            return 69
        fi
        [[ "$trusted_path" == "/" ]] && break
        trusted_path="${trusted_path%/*}"
        [[ -n "$trusted_path" ]] || trusted_path="/"
    done

    for trusted_path in \
        "$xcode_bundle" \
        "$xcode_contents" \
        "$canonical_developer_dir" \
        "$canonical_developer_dir/usr" \
        "$canonical_developer_dir/usr/bin" \
        "$canonical_developer_dir/usr/bin/xcodebuild"; do
        if [[ -L "$trusted_path" \
            || ( ! -d "$trusted_path" \
                && "$trusted_path" != "$canonical_developer_dir/usr/bin/xcodebuild" ) \
            || ( "$trusted_path" == "$canonical_developer_dir/usr/bin/xcodebuild" \
                && ! -f "$trusted_path" ) ]]; then
            echo "Selected Xcode contains an untrusted tool path" >&2
            return 69
        fi
        if ! path_metadata="$(/usr/bin/stat -f '%u %Lp' "$trusted_path" 2>/dev/null)" \
            || [[ "$path_metadata" == *$'\n'* ]]; then
            echo "Could not validate selected Xcode ownership" >&2
            return 69
        fi
        path_owner="${path_metadata%% *}"
        path_mode="${path_metadata#* }"
        if [[ "$path_owner" != 0 || ! "$path_mode" =~ ^[0-7]{3,4}$ ]] \
            || (( (8#$path_mode & 022) != 0 )) \
            || [[ -w "$trusted_path" ]]; then
            echo "Selected Xcode must be root-owned and non-writable" >&2
            return 69
        fi
    done
    if ! user_id="$(/usr/bin/id -u 2>/dev/null)" \
        || ! user_groups="$(/usr/bin/id -G 2>/dev/null)" \
        || [[ ! "$user_id" =~ ^[1-9][0-9]*$ \
            || ! "$user_groups" =~ ^[0-9]+([[:space:]][0-9]+)*$ ]]; then
        echo "Could not validate selected Xcode access controls" >&2
        return 69
    fi
    find_arguments=(
        -x "$xcode_bundle" '('
        '!' -uid 0
        -o -perm -0002
        -o -acl
    )
    for group_id in $user_groups; do
        find_arguments+=(
            -o '(' -gid "$group_id" -perm -0020 ')'
        )
    done
    find_arguments+=(')' -print -quit)
    if ! untrusted_bundle_entry="$(
            /usr/bin/find "${find_arguments[@]}" 2>&1
        )"; then
        echo "Could not inspect selected Xcode access controls" >&2
        return 69
    fi
    if [[ -n "$untrusted_bundle_entry" ]]; then
        echo "Selected Xcode bundle is writable or not root-owned" >&2
        return 69
    fi
    if [[ ! -x "$canonical_developer_dir/usr/bin/xcodebuild" ]]; then
        echo "Apple distribution Xcode path is incomplete" >&2
        return 69
    fi
    xcode_requirement='(anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.9] exists or anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = "59GAB85EFG") and identifier "com.apple.dt.Xcode"'
    if ! signature_error="$(
            /usr/bin/codesign --verify --deep --strict --verbose=4 \
                -R="$xcode_requirement" \
                "$xcode_bundle" 2>&1 >/dev/null
        )"; then
        echo "Selected Xcode does not have a valid Apple signature" >&2
        printf '%s\n' "$signature_error" >&2
        return 69
    fi
}

apple_read_sdk_metadata() {
    local developer_dir="$1"
    local platform="$2"
    local sdk_version
    local sdk_build

    if ! sdk_version="$(apple_run_selected_tool \
            "$developer_dir" \
            /usr/bin/xcrun --no-cache --sdk "$platform" \
                --show-sdk-version 2>&1)" \
        || [[ "$sdk_version" == *$'\n'* ]]; then
        echo "Could not read selected $platform SDK version" >&2
        return 69
    fi
    apple_require_minimum_version \
        "$sdk_version" \
        "$apple_distribution_minimum_sdk_version" \
        "$platform SDK" \
        || return $?
    if ! sdk_build="$(apple_run_selected_tool \
            "$developer_dir" \
            /usr/bin/xcrun --no-cache --sdk "$platform" \
                --show-sdk-build-version 2>&1)" \
        || [[ "$sdk_build" == *$'\n'* ]] \
        || [[ ! "$sdk_build" =~ ^[A-Za-z0-9]+$ ]]; then
        echo "Could not read selected $platform SDK build" >&2
        return 69
    fi

    case "$platform" in
        macosx)
            validated_apple_macosx_sdk_version="$sdk_version"
            validated_apple_macosx_sdk_name="macosx$sdk_version"
            validated_apple_macosx_sdk_build="$sdk_build"
            ;;
        iphoneos)
            validated_apple_iphoneos_sdk_version="$sdk_version"
            validated_apple_iphoneos_sdk_name="iphoneos$sdk_version"
            validated_apple_iphoneos_sdk_build="$sdk_build"
            ;;
        watchos)
            validated_apple_watchos_sdk_version="$sdk_version"
            validated_apple_watchos_sdk_name="watchos$sdk_version"
            validated_apple_watchos_sdk_build="$sdk_build"
            ;;
        *)
            echo "Unsupported Apple distribution SDK: $platform" >&2
            return 64
            ;;
    esac
}

validate_apple_distribution_toolchain() {
    local developer_dir="$1"
    local canonical_developer_dir
    local xcode_info
    local xcode_output
    local xcode_line
    local build_line
    local xcode_version
    local xcode_build
    local dtxcode
    local dtxcode_major
    local xcode_major
    local platform
    local seen_macosx=0
    local seen_iphoneos=0
    local seen_watchos=0

    shift
    validated_apple_toolchain_ready=""
    validated_apple_developer_dir=""
    validated_apple_xcode_version=""
    validated_apple_xcode_build=""
    validated_apple_dtxcode=""
    validated_apple_macosx_sdk_version=""
    validated_apple_macosx_sdk_name=""
    validated_apple_macosx_sdk_build=""
    validated_apple_iphoneos_sdk_version=""
    validated_apple_iphoneos_sdk_name=""
    validated_apple_iphoneos_sdk_build=""
    validated_apple_watchos_sdk_version=""
    validated_apple_watchos_sdk_name=""
    validated_apple_watchos_sdk_build=""

    if [[ $# -eq 0 ]]; then
        echo "Apple distribution requires one canonical Xcode Developer directory" >&2
        return 69
    fi
    canonical_developer_dir="$(cd "$developer_dir" && pwd -P)" || return 69
    apple_validate_xcode_bundle_trust "$developer_dir" || return $?

    if ! xcode_output="$(apple_run_selected_tool \
            "$canonical_developer_dir" \
            "$canonical_developer_dir/usr/bin/xcodebuild" -version 2>&1)" \
        || [[ "$xcode_output" != *$'\n'* ]] \
        || [[ "${xcode_output#*$'\n'}" == *$'\n'* ]]; then
        echo "Could not read one unambiguous selected Xcode version" >&2
        return 69
    fi
    xcode_line="${xcode_output%%$'\n'*}"
    build_line="${xcode_output#*$'\n'}"
    if [[ "$xcode_line" =~ ^Xcode[[:space:]]([0-9]+(\.[0-9]+)*)$ ]]; then
        xcode_version="${BASH_REMATCH[1]}"
    else
        echo "Selected Xcode returned malformed version metadata" >&2
        return 69
    fi
    if [[ "$build_line" =~ ^Build[[:space:]]version[[:space:]]([A-Za-z0-9]+)$ ]]; then
        xcode_build="${BASH_REMATCH[1]}"
    else
        echo "Selected Xcode returned malformed build metadata" >&2
        return 69
    fi
    apple_require_minimum_version \
        "$xcode_version" \
        "$apple_distribution_minimum_xcode_version" \
        "Xcode" \
        || return $?

    xcode_info="$canonical_developer_dir/../Info.plist"
    if [[ -L "$xcode_info" || ! -f "$xcode_info" ]] \
        || ! /usr/bin/plutil -lint "$xcode_info" >/dev/null; then
        echo "Selected Xcode has no regular valid Info.plist" >&2
        return 69
    fi
    dtxcode="$(/usr/bin/plutil -extract DTXcode raw "$xcode_info" \
        2>/dev/null || true)"
    if [[ ! "$dtxcode" =~ ^[1-9][0-9]{3,5}$ ]]; then
        echo "Selected Xcode has malformed DTXcode metadata" >&2
        return 69
    fi
    dtxcode_major="${dtxcode:0:${#dtxcode}-2}"
    xcode_major="${xcode_version%%.*}"
    if [[ "$dtxcode_major" != "$xcode_major" ]]; then
        echo "Selected Xcode version and DTXcode metadata disagree" >&2
        return 69
    fi
    apple_require_minimum_version \
        "$dtxcode_major" \
        "$apple_distribution_minimum_xcode_version" \
        "Xcode DTXcode" \
        || return $?

    for platform in "$@"; do
        case "$platform" in
            macosx)
                if [[ "$seen_macosx" == "1" ]]; then
                    echo "Duplicate Apple distribution SDK: $platform" >&2
                    return 64
                fi
                seen_macosx=1
                ;;
            iphoneos)
                if [[ "$seen_iphoneos" == "1" ]]; then
                    echo "Duplicate Apple distribution SDK: $platform" >&2
                    return 64
                fi
                seen_iphoneos=1
                ;;
            watchos)
                if [[ "$seen_watchos" == "1" ]]; then
                    echo "Duplicate Apple distribution SDK: $platform" >&2
                    return 64
                fi
                seen_watchos=1
                ;;
            *)
                echo "Unsupported Apple distribution SDK: $platform" >&2
                return 64
                ;;
        esac
        apple_read_sdk_metadata "$canonical_developer_dir" "$platform" \
            || return $?
    done

    validated_apple_developer_dir="$canonical_developer_dir"
    validated_apple_xcode_version="$xcode_version"
    validated_apple_xcode_build="$xcode_build"
    validated_apple_dtxcode="$dtxcode"
    validated_apple_toolchain_ready=1
}

verify_apple_product_toolchain_metadata() {
    local info_plist="$1"
    local platform="$2"
    local label="$3"
    local expected_sdk_version
    local expected_sdk_name
    local expected_sdk_build
    local actual_dtxcode
    local actual_xcode_build
    local actual_sdk_name
    local actual_sdk_build
    local actual_platform
    local actual_platform_version
    local actual_dtxcode_major

    if [[ "$validated_apple_toolchain_ready" != "1" ]]; then
        echo "$label cannot be checked before Apple toolchain preflight" >&2
        return 1
    fi
    case "$platform" in
        macosx)
            expected_sdk_version="$validated_apple_macosx_sdk_version"
            expected_sdk_name="$validated_apple_macosx_sdk_name"
            expected_sdk_build="$validated_apple_macosx_sdk_build"
            ;;
        iphoneos)
            expected_sdk_version="$validated_apple_iphoneos_sdk_version"
            expected_sdk_name="$validated_apple_iphoneos_sdk_name"
            expected_sdk_build="$validated_apple_iphoneos_sdk_build"
            ;;
        watchos)
            expected_sdk_version="$validated_apple_watchos_sdk_version"
            expected_sdk_name="$validated_apple_watchos_sdk_name"
            expected_sdk_build="$validated_apple_watchos_sdk_build"
            ;;
        *)
            echo "$label uses unsupported Apple platform metadata: $platform" >&2
            return 1
            ;;
    esac
    if [[ -z "$expected_sdk_version" || -z "$expected_sdk_name" \
        || -z "$expected_sdk_build" ]]; then
        echo "$label uses an SDK omitted from Apple toolchain preflight" >&2
        return 1
    fi
    if [[ -L "$info_plist" || ! -f "$info_plist" ]] \
        || ! /usr/bin/plutil -lint "$info_plist" >/dev/null; then
        echo "$label has no regular valid Info.plist" >&2
        return 1
    fi

    actual_dtxcode="$(/usr/bin/plutil -extract DTXcode raw "$info_plist" \
        2>/dev/null || true)"
    actual_xcode_build="$(/usr/bin/plutil -extract DTXcodeBuild raw \
        "$info_plist" 2>/dev/null || true)"
    actual_sdk_name="$(/usr/bin/plutil -extract DTSDKName raw "$info_plist" \
        2>/dev/null || true)"
    actual_sdk_build="$(/usr/bin/plutil -extract DTSDKBuild raw "$info_plist" \
        2>/dev/null || true)"
    actual_platform="$(/usr/bin/plutil -extract DTPlatformName raw \
        "$info_plist" 2>/dev/null || true)"
    actual_platform_version="$(/usr/bin/plutil -extract DTPlatformVersion raw \
        "$info_plist" 2>/dev/null || true)"

    if [[ ! "$actual_dtxcode" =~ ^[1-9][0-9]{3,5}$ ]]; then
        echo "$label has malformed DTXcode metadata" >&2
        return 1
    fi
    actual_dtxcode_major="${actual_dtxcode:0:${#actual_dtxcode}-2}"
    apple_require_minimum_version \
        "$actual_dtxcode_major" \
        "$apple_distribution_minimum_xcode_version" \
        "$label DTXcode" \
        || return 1
    if [[ "$actual_dtxcode" != "$validated_apple_dtxcode" \
        || "$actual_xcode_build" != "$validated_apple_xcode_build" \
        || "$actual_sdk_name" != "$expected_sdk_name" \
        || "$actual_sdk_build" != "$expected_sdk_build" \
        || "$actual_platform" != "$platform" \
        || "$actual_platform_version" != "$expected_sdk_version" ]]; then
        echo "$label Xcode or SDK metadata differs from validated preflight" >&2
        return 1
    fi
    apple_require_minimum_version \
        "$actual_platform_version" \
        "$apple_distribution_minimum_sdk_version" \
        "$label SDK" \
        || return 1
}
