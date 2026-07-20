#!/bin/bash

# Fail-closed semantic validation for App Store iOS/watchOS products.
# Source this file, then call validate_app_store_product.

app_store_validation_error() {
    printf 'App Store product validation failed: %s\n' "$1" >&2
    return 1
}

app_store_validate_expected_version_build() {
    if [[ $# -ne 2 ]]; then
        app_store_validation_error \
            "usage: app_store_validate_expected_version_build VERSION BUILD"
        return 64
    fi
    if [[ ! "$1" =~ ^[0-9]+(\.[0-9]+){1,2}$ ]]; then
        app_store_validation_error \
            "expected marketing version is not an App Store version"
        return 1
    fi
    if [[ ! "$2" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]]; then
        app_store_validation_error \
            "expected build number is not an App Store build number"
        return 1
    fi
}

app_store_plist_expect_value() {
    local plist="$1"
    local key="$2"
    local expected_type="$3"
    local expected_value="$4"
    local label="$5"
    local actual_value

    if ! actual_value="$(/usr/bin/plutil -extract "$key" raw \
            -expect "$expected_type" "$plist" 2>/dev/null)"; then
        app_store_validation_error \
            "$label is missing $key or has an unexpected type"
        return 1
    fi
    if [[ "$actual_value" != "$expected_value" ]]; then
        app_store_validation_error \
            "$label has unexpected $key: $actual_value"
        return 1
    fi
}

app_store_plist_expect_array_count() {
    local plist="$1"
    local key="$2"
    local expected_count="$3"
    local label="$4"

    app_store_plist_expect_value \
        "$plist" "$key" array "$expected_count" "$label"
}

app_store_plist_expect_dictionary_keys() {
    local plist="$1"
    local key="$2"
    local label="$3"
    shift 3
    local actual_keys
    local unsorted_keys
    local expected_keys

    if ! unsorted_keys="$(/usr/bin/plutil -extract "$key" raw \
            -expect dictionary "$plist" 2>/dev/null)"; then
        app_store_validation_error \
            "$label is missing $key or it is not a dictionary"
        return 1
    fi
    actual_keys="$(printf '%s\n' "$unsorted_keys" | LC_ALL=C /usr/bin/sort)"
    expected_keys="$(printf '%s\n' "$@" | LC_ALL=C /usr/bin/sort)"
    if [[ "$actual_keys" != "$expected_keys" ]]; then
        app_store_validation_error \
            "$label has unexpected keys in $key"
        return 1
    fi
}

app_store_plist_expect_exact_root_keys() {
    local plist="$1"
    local label="$2"
    local scratch="$3"
    shift 3
    local key
    local remainder

    /bin/cp "$plist" "$scratch" || {
        app_store_validation_error "$label could not be copied for validation"
        return 1
    }
    /bin/chmod u+w "$scratch" || return 1
    for key in "$@"; do
        if ! /usr/bin/plutil -remove "$key" "$scratch" >/dev/null 2>&1; then
            app_store_validation_error "$label is missing expected key $key"
            return 1
        fi
    done
    if ! remainder="$(/usr/bin/plutil -convert json -o - \
            "$scratch" 2>/dev/null)"; then
        app_store_validation_error "$label is not a valid property list"
        return 1
    fi
    if [[ "$remainder" != "{}" ]]; then
        app_store_validation_error "$label contains undeclared top-level keys"
        return 1
    fi
}

app_store_require_regular_file() {
    local path="$1"
    local label="$2"

    if [[ ! -f "$path" || -L "$path" ]]; then
        app_store_validation_error "$label is missing or is not a regular file"
        return 1
    fi
}

validated_app_store_ipa=""
validated_app_store_ios_app=""

app_store_validate_applications_root() {
    if [[ $# -ne 3 ]]; then
        app_store_validation_error \
            "usage: app_store_validate_applications_root ROOT EXPECTED_APP SCRATCH_FILE"
        return 64
    fi

    local applications_root="$1"
    local expected_app="$2"
    local scratch_file="$3"
    local candidate
    local candidate_count=0

    if [[ ! -d "$applications_root" || -L "$applications_root" \
        || ! -d "$expected_app" || -L "$expected_app" ]]; then
        app_store_validation_error \
            "archive Applications root or expected app is missing or is a symlink"
        return 1
    fi
    if ! /usr/bin/find "$applications_root" -mindepth 1 -maxdepth 1 \
            -print0 >"$scratch_file-entries"; then
        app_store_validation_error "archive Applications root could not be inspected"
        return 1
    fi
    while IFS= read -r -d '' candidate; do
        ((candidate_count += 1))
        if [[ "$candidate" != "$expected_app" ]]; then
            app_store_validation_error \
                "archive Applications root contains an unexpected entry"
            return 1
        fi
    done <"$scratch_file-entries"
    if [[ "$candidate_count" != "1" ]]; then
        app_store_validation_error \
            "archive Applications root must contain exactly one expected app"
        return 1
    fi
}

app_store_select_single_ipa() {
    if [[ $# -ne 2 ]]; then
        app_store_validation_error \
            "usage: app_store_select_single_ipa EXPORT_DIR SCRATCH_FILE"
        return 64
    fi

    local export_dir="$1"
    local scratch_file="$2"
    local candidate
    local candidate_count=0

    validated_app_store_ipa=""
    if [[ ! -d "$export_dir" || -L "$export_dir" ]]; then
        app_store_validation_error "IPA export directory is missing or is a symlink"
        return 1
    fi
    if ! /usr/bin/find "$export_dir" -mindepth 1 -maxdepth 1 \
            -type l -print0 >"$scratch_file-symlinks"; then
        app_store_validation_error "IPA export directory could not be inspected"
        return 1
    fi
    if [[ -s "$scratch_file-symlinks" ]]; then
        app_store_validation_error "IPA export directory contains a symlink"
        return 1
    fi
    if ! /usr/bin/find "$export_dir" -mindepth 1 -maxdepth 1 \
            -type f -iname '*.ipa' -print0 >"$scratch_file-candidates"; then
        app_store_validation_error "IPA export directory could not be inspected"
        return 1
    fi
    while IFS= read -r -d '' candidate; do
        ((candidate_count += 1))
        validated_app_store_ipa="$candidate"
    done <"$scratch_file-candidates"
    if [[ "$candidate_count" != "1" ]]; then
        app_store_validation_error \
            "IPA export must contain exactly one regular IPA"
        # Read by callers after sourcing this helper.
        # shellcheck disable=SC2034
        validated_app_store_ipa=""
        return 1
    fi
}

app_store_select_single_payload_app() {
    if [[ $# -ne 2 ]]; then
        app_store_validation_error \
            "usage: app_store_select_single_payload_app IPA_ROOT SCRATCH_FILE"
        return 64
    fi

    local ipa_root="$1"
    local scratch_file="$2"
    local payload="$ipa_root/Payload"
    local candidate
    local candidate_count=0

    validated_app_store_ios_app=""
    if [[ ! -d "$ipa_root" || -L "$ipa_root" \
        || ! -d "$payload" || -L "$payload" ]]; then
        app_store_validation_error \
            "extracted IPA or Payload is missing or is a symlink"
        return 1
    fi
    if ! /usr/bin/find "$ipa_root" -mindepth 1 -type l \
            -print0 >"$scratch_file-symlinks"; then
        app_store_validation_error "extracted IPA could not be inspected"
        return 1
    fi
    if [[ -s "$scratch_file-symlinks" ]]; then
        app_store_validation_error "extracted IPA contains a symlink"
        return 1
    fi
    if ! /usr/bin/find "$payload" -mindepth 1 -maxdepth 1 \
            -type d -iname '*.app' -print0 >"$scratch_file-candidates"; then
        app_store_validation_error "IPA Payload could not be inspected"
        return 1
    fi
    while IFS= read -r -d '' candidate; do
        ((candidate_count += 1))
        validated_app_store_ios_app="$candidate"
    done <"$scratch_file-candidates"
    if [[ "$candidate_count" != "1" ]]; then
        app_store_validation_error \
            "IPA Payload must contain exactly one regular app"
        # Read by callers after sourcing this helper.
        # shellcheck disable=SC2034
        validated_app_store_ios_app=""
        return 1
    fi
}

app_store_validate_executable_bundle_topology() {
    if [[ $# -ne 4 ]]; then
        app_store_validation_error \
            "usage: app_store_validate_executable_bundle_topology ROOT IOS_APP WATCH_APP SCRATCH_FILE"
        return 64
    fi

    local search_root="$1"
    local ios_app="$2"
    local watch_app="$3"
    local scratch_file="$4"
    local candidate
    local ios_count=0
    local watch_count=0

    if [[ ! -d "$search_root" || -L "$search_root" ]]; then
        app_store_validation_error \
            "executable-bundle search root is missing or is a symlink"
        return 1
    fi
    if ! /usr/bin/find "$search_root" -mindepth 1 -type l \
            -print0 >"$scratch_file-symlinks"; then
        app_store_validation_error "product symlinks could not be inspected"
        return 1
    fi
    if [[ -s "$scratch_file-symlinks" ]]; then
        app_store_validation_error "product contains an unexpected symlink"
        return 1
    fi
    if ! /usr/bin/find "$search_root" -mindepth 1 \
            \( -iname '*.app' -o -iname '*.appex' \) \
            -print0 >"$scratch_file-bundles"; then
        app_store_validation_error "executable bundles could not be inspected"
        return 1
    fi
    while IFS= read -r -d '' candidate; do
        if [[ "$candidate" == "$ios_app" ]]; then
            ((ios_count += 1))
        elif [[ "$candidate" == "$watch_app" ]]; then
            ((watch_count += 1))
        else
            app_store_validation_error \
                "product contains unexpected app or app-extension bundle"
            return 1
        fi
    done <"$scratch_file-bundles"
    if [[ "$watch_count" != "1" ]]; then
        app_store_validation_error \
            "product must contain exactly one dependent Watch app"
        return 1
    fi
    if [[ "$search_root" != "$ios_app" && "$ios_count" != "1" ]]; then
        app_store_validation_error \
            "IPA must contain exactly one expected iOS app"
        return 1
    fi
}

app_store_validate_executable_code_inventory() {
    if [[ $# -ne 4 ]]; then
        app_store_validation_error \
            "usage: app_store_validate_executable_code_inventory ROOT IOS_EXECUTABLE WATCH_EXECUTABLE SCRATCH_FILE"
        return 64
    fi

    local search_root="$1"
    local ios_executable="$2"
    local watch_executable="$3"
    local scratch_file="$4"
    local candidate
    local kind
    local ios_mode_count=0
    local watch_mode_count=0
    local ios_macho_count=0
    local watch_macho_count=0

    if [[ ! -d "$search_root" || -L "$search_root" \
        || ! -f "$ios_executable" || -L "$ios_executable" \
        || ! -f "$watch_executable" || -L "$watch_executable" ]]; then
        app_store_validation_error \
            "audited executable root or expected executable is missing or unsafe"
        return 1
    fi
    if ! /usr/bin/find "$search_root" -mindepth 1 \
            \( -iname '*.framework' -o -iname '*.xpc' \
            -o -iname '*.bundle' -o -iname '*.dylib' \
            -o -iname '*.plugin' -o -iname '*.kext' \
            -o -iname '*.systemextension' \) \
            -print0 >"$scratch_file-code-containers"; then
        app_store_validation_error "code containers could not be inspected"
        return 1
    fi
    if [[ -s "$scratch_file-code-containers" ]]; then
        app_store_validation_error \
            "product contains an unaudited framework, service, bundle, or library"
        return 1
    fi

    if ! /usr/bin/find "$search_root" -type f -perm +111 \
            -print0 >"$scratch_file-executable-mode"; then
        app_store_validation_error "executable-mode files could not be inspected"
        return 1
    fi
    while IFS= read -r -d '' candidate; do
        if [[ "$candidate" == "$ios_executable" ]]; then
            ((ios_mode_count += 1))
        elif [[ "$candidate" == "$watch_executable" ]]; then
            ((watch_mode_count += 1))
        else
            app_store_validation_error \
                "product contains an unaudited executable-mode file"
            return 1
        fi
    done <"$scratch_file-executable-mode"
    if [[ "$ios_mode_count" != "1" || "$watch_mode_count" != "1" ]]; then
        app_store_validation_error \
            "expected iOS and Watch executables must be executable files"
        return 1
    fi

    if ! /usr/bin/find "$search_root" -type f \
            -print0 >"$scratch_file-regular-files"; then
        app_store_validation_error "regular product files could not be inspected"
        return 1
    fi
    while IFS= read -r -d '' candidate; do
        if ! kind="$(/usr/bin/env -u MAGIC LC_ALL=C \
                /usr/bin/file -b "$candidate" 2>/dev/null)"; then
            app_store_validation_error "product file type could not be inspected"
            return 1
        fi
        case "$kind" in
            *Mach-O*)
                if [[ "$candidate" == "$ios_executable" ]]; then
                    ((ios_macho_count += 1))
                elif [[ "$candidate" == "$watch_executable" ]]; then
                    ((watch_macho_count += 1))
                else
                    app_store_validation_error \
                        "product contains an unaudited Mach-O code object"
                    return 1
                fi
                ;;
        esac
    done <"$scratch_file-regular-files"
    if [[ "$ios_macho_count" != "1" || "$watch_macho_count" != "1" ]]; then
        app_store_validation_error \
            "expected iOS and Watch executables must be Mach-O code objects"
        return 1
    fi
}

app_store_validate_png() {
    local path="$1"
    local expected_width="$2"
    local expected_height="$3"
    local label="$4"
    local details
    local format
    local width
    local height

    app_store_require_regular_file "$path" "$label" || return 1
    if [[ ! -s "$path" ]]; then
        app_store_validation_error "$label is empty"
        return 1
    fi
    if ! details="$(/usr/bin/sips -g format -g pixelWidth -g pixelHeight \
            "$path" 2>/dev/null)"; then
        app_store_validation_error "$label is not a readable image"
        return 1
    fi
    format="$(printf '%s\n' "$details" \
        | /usr/bin/sed -n 's/^[[:space:]]*format: //p')"
    width="$(printf '%s\n' "$details" \
        | /usr/bin/sed -n 's/^[[:space:]]*pixelWidth: //p')"
    height="$(printf '%s\n' "$details" \
        | /usr/bin/sed -n 's/^[[:space:]]*pixelHeight: //p')"
    if [[ "$format" != "png" || "$width" != "$expected_width" \
        || "$height" != "$expected_height" ]]; then
        app_store_validation_error \
            "$label must be a ${expected_width}x${expected_height} PNG"
        return 1
    fi
}

app_store_write_asset_catalog_info() {
    local catalog="$1"
    local label="$2"
    local expected_platform="$3"
    local info="$4"
    local assetutil="$5"
    local raw_info="$info.raw.json"
    local rendition_count
    local index
    local platform
    local platform_count=0

    app_store_require_regular_file "$catalog" "$label" || return 1
    if [[ ! -s "$catalog" ]]; then
        app_store_validation_error "$label is empty"
        return 1
    fi
    if [[ ! -x "$assetutil" || ! -f "$assetutil" || -L "$assetutil" ]]; then
        app_store_validation_error "assetutil is unavailable or unsafe"
        return 1
    fi
    printf '{"renditions":' >"$raw_info"
    if ! "$assetutil" --info "$catalog" >>"$raw_info" 2>/dev/null; then
        app_store_validation_error "$label could not be inspected by assetutil"
        return 1
    fi
    printf '}\n' >>"$raw_info"
    if ! /usr/bin/plutil -convert xml1 -o "$info" \
            "$raw_info" >/dev/null 2>&1 \
        || ! /usr/bin/plutil -lint "$info" >/dev/null 2>&1; then
        app_store_validation_error "$label produced invalid asset metadata"
        return 1
    fi
    if ! rendition_count="$(/usr/bin/plutil -extract renditions raw \
            -expect array "$info" 2>/dev/null)" \
        || [[ ! "$rendition_count" =~ ^[0-9]+$ \
            || "$rendition_count" -lt 1 \
            || "$rendition_count" -gt 10000 ]]; then
        app_store_validation_error "$label has an invalid rendition count"
        return 1
    fi
    for ((index = 0; index < rendition_count; index += 1)); do
        platform="$(/usr/bin/plutil -extract \
            "renditions.$index.Platform" raw -expect string \
            "$info" 2>/dev/null || true)"
        if [[ -n "$platform" ]]; then
            ((platform_count += 1))
            if [[ "$platform" != "$expected_platform" ]]; then
                app_store_validation_error \
                    "$label has unexpected platform metadata: $platform"
                return 1
            fi
        fi
    done
    if [[ "$platform_count" != "1" ]]; then
        app_store_validation_error \
            "$label must contain exactly one $expected_platform platform record"
        return 1
    fi
}

app_store_asset_catalog_expect_named_icon() {
    local info="$1"
    local expected_idiom="$2"
    local label="$3"
    local rendition_count
    local index
    local asset_type
    local name
    local idiom
    local width
    local height
    local opaque
    local match_count=0

    rendition_count="$(/usr/bin/plutil -extract renditions raw \
        -expect array "$info")" || return 1
    for ((index = 0; index < rendition_count; index += 1)); do
        asset_type="$(/usr/bin/plutil -extract \
            "renditions.$index.AssetType" raw -expect string \
            "$info" 2>/dev/null || true)"
        if [[ "$asset_type" != "Icon Image" ]]; then
            continue
        fi
        name="$(/usr/bin/plutil -extract "renditions.$index.Name" raw \
            -expect string "$info" 2>/dev/null || true)"
        idiom="$(/usr/bin/plutil -extract "renditions.$index.Idiom" raw \
            -expect string "$info" 2>/dev/null || true)"
        if [[ "$name" != "agentlimits" || "$idiom" != "$expected_idiom" ]]; then
            continue
        fi
        width="$(/usr/bin/plutil -extract \
            "renditions.$index.PixelWidth" raw -expect integer \
            "$info" 2>/dev/null || true)"
        height="$(/usr/bin/plutil -extract \
            "renditions.$index.PixelHeight" raw -expect integer \
            "$info" 2>/dev/null || true)"
        opaque="$(/usr/bin/plutil -extract \
            "renditions.$index.Opaque" raw -expect bool \
            "$info" 2>/dev/null || true)"
        if [[ "$width" == "1024" && "$height" == "1024" \
            && "$opaque" == "true" ]]; then
            ((match_count += 1))
        fi
    done
    if [[ "$match_count" -lt 1 ]]; then
        app_store_validation_error \
            "$label lacks an opaque 1024x1024 agentlimits icon for $expected_idiom"
        return 1
    fi
}

app_store_validate_privacy_manifest() {
    local manifest="$1"
    local label="$2"
    local scratch_prefix="$3"
    local scratch_dir="$4"
    local access_entry="$scratch_dir/$scratch_prefix-access-entry.plist"

    app_store_require_regular_file "$manifest" "$label" || return 1
    if ! /usr/bin/plutil -lint "$manifest" >/dev/null 2>&1; then
        app_store_validation_error "$label is not a valid privacy manifest"
        return 1
    fi

    app_store_plist_expect_value \
        "$manifest" NSPrivacyTracking bool false "$label" || return 1
    app_store_plist_expect_array_count \
        "$manifest" NSPrivacyTrackingDomains 0 "$label" || return 1
    app_store_plist_expect_array_count \
        "$manifest" NSPrivacyCollectedDataTypes 0 "$label" || return 1
    app_store_plist_expect_array_count \
        "$manifest" NSPrivacyAccessedAPITypes 1 "$label" || return 1
    app_store_plist_expect_value \
        "$manifest" NSPrivacyAccessedAPITypes.0.NSPrivacyAccessedAPIType \
        string NSPrivacyAccessedAPICategoryUserDefaults "$label" || return 1
    app_store_plist_expect_array_count \
        "$manifest" \
        NSPrivacyAccessedAPITypes.0.NSPrivacyAccessedAPITypeReasons \
        1 "$label" || return 1
    app_store_plist_expect_value \
        "$manifest" \
        NSPrivacyAccessedAPITypes.0.NSPrivacyAccessedAPITypeReasons.0 \
        string CA92.1 "$label" || return 1

    if ! /usr/bin/plutil -extract NSPrivacyAccessedAPITypes.0 xml1 \
            -o "$access_entry" "$manifest" 2>/dev/null; then
        app_store_validation_error "$label has an invalid accessed-API entry"
        return 1
    fi
    app_store_plist_expect_exact_root_keys \
        "$access_entry" "$label accessed-API entry" \
        "$scratch_dir/$scratch_prefix-access-entry-remainder.plist" \
        NSPrivacyAccessedAPIType \
        NSPrivacyAccessedAPITypeReasons || return 1
    app_store_plist_expect_exact_root_keys \
        "$manifest" "$label" \
        "$scratch_dir/$scratch_prefix-root-remainder.plist" \
        NSPrivacyAccessedAPITypes \
        NSPrivacyCollectedDataTypes \
        NSPrivacyTracking \
        NSPrivacyTrackingDomains || return 1
}

app_store_validate_product_with_assetutil() {
    if [[ $# -ne 5 ]]; then
        app_store_validation_error \
            "usage: app_store_validate_product_with_assetutil IOS_APP VERSION BUILD SCRATCH_DIR ASSETUTIL"
        return 64
    fi

    local ios_app="$1"
    local expected_version="$2"
    local expected_build="$3"
    local scratch_dir="$4"
    local assetutil="$5"
    local ios_info="$ios_app/Info.plist"
    local watch_root="$ios_app/Watch"
    local watch_app="$watch_root/AgentLimitsWatch.app"
    local watch_info="$watch_app/Info.plist"

    app_store_validate_expected_version_build \
        "$expected_version" "$expected_build" || return $?
    if [[ ! -d "$ios_app" || -L "$ios_app" ]]; then
        app_store_validation_error "iOS app is missing or is a symlink"
        return 1
    fi
    if [[ ! -d "$watch_root" || -L "$watch_root" \
        || ! -d "$watch_app" || -L "$watch_app" ]]; then
        app_store_validation_error \
            "dependent Watch app is not embedded at expected path"
        return 1
    fi
    if [[ -e "$scratch_dir" || -L "$scratch_dir" ]]; then
        app_store_validation_error "validation scratch path already exists"
        return 1
    fi
    if ! (umask 077 && /bin/mkdir "$scratch_dir"); then
        app_store_validation_error "validation scratch directory could not be created"
        return 1
    fi

    app_store_validate_executable_bundle_topology \
        "$ios_app" "$ios_app" "$watch_app" \
        "$scratch_dir/product-topology" || return 1

    app_store_require_regular_file "$ios_info" "iOS Info.plist" || return 1
    app_store_require_regular_file "$watch_info" "Watch Info.plist" || return 1
    if ! /usr/bin/plutil -lint "$ios_info" "$watch_info" >/dev/null 2>&1; then
        app_store_validation_error "product Info.plist is invalid"
        return 1
    fi

    app_store_plist_expect_value \
        "$ios_info" CFBundleIdentifier string \
        com.jimboha.agentlimits.ios "iOS product" || return 1
    app_store_plist_expect_value \
        "$watch_info" CFBundleIdentifier string \
        com.jimboha.agentlimits.ios.watchkitapp "Watch product" || return 1
    app_store_plist_expect_value \
        "$ios_info" CFBundleExecutable string \
        AgentLimits "iOS product" || return 1
    app_store_plist_expect_value \
        "$watch_info" CFBundleExecutable string \
        AgentLimitsWatch "Watch product" || return 1
    app_store_validate_executable_code_inventory \
        "$ios_app" "$ios_app/AgentLimits" "$watch_app/AgentLimitsWatch" \
        "$scratch_dir/product-code" || return 1
    for plist_and_label in ios watch; do
        local plist
        local label
        if [[ "$plist_and_label" == ios ]]; then
            plist="$ios_info"
            label="iOS product"
        else
            plist="$watch_info"
            label="Watch product"
        fi
        app_store_plist_expect_value \
            "$plist" CFBundleShortVersionString string \
            "$expected_version" "$label" || return 1
        app_store_plist_expect_value \
            "$plist" CFBundleVersion string \
            "$expected_build" "$label" || return 1
        app_store_plist_expect_value \
            "$plist" CFBundlePackageType string APPL "$label" || return 1
        app_store_plist_expect_value \
            "$plist" CFBundleDisplayName string \
            "AgentLimits Forked" "$label" || return 1
        app_store_plist_expect_value \
            "$plist" ITSAppUsesNonExemptEncryption bool false \
            "$label" || return 1
    done

    app_store_plist_expect_value \
        "$ios_info" CFBundleName string AgentLimits "iOS product" || return 1
    app_store_plist_expect_value \
        "$ios_info" LSApplicationCategoryType string \
        public.app-category.utilities "iOS product" || return 1
    app_store_plist_expect_value \
        "$ios_info" LSRequiresIPhoneOS bool true "iOS product" || return 1
    app_store_plist_expect_array_count \
        "$ios_info" CFBundleSupportedPlatforms 1 "iOS product" || return 1
    app_store_plist_expect_value \
        "$ios_info" CFBundleSupportedPlatforms.0 string \
        iPhoneOS "iOS product" || return 1
    app_store_plist_expect_array_count \
        "$ios_info" UIDeviceFamily 2 "iOS product" || return 1
    app_store_plist_expect_value \
        "$ios_info" UIDeviceFamily.0 integer 1 "iOS product" || return 1
    app_store_plist_expect_value \
        "$ios_info" UIDeviceFamily.1 integer 2 "iOS product" || return 1

    app_store_plist_expect_dictionary_keys \
        "$ios_info" UILaunchScreen "iOS product" UILaunchScreen || return 1
    app_store_plist_expect_dictionary_keys \
        "$ios_info" UILaunchScreen.UILaunchScreen \
        "iOS product" || return 1
    app_store_plist_expect_dictionary_keys \
        "$ios_info" CFBundleIcons "iOS product" \
        CFBundlePrimaryIcon || return 1
    app_store_plist_expect_dictionary_keys \
        "$ios_info" CFBundleIcons.CFBundlePrimaryIcon "iOS product" \
        CFBundleIconFiles CFBundleIconName || return 1
    app_store_plist_expect_value \
        "$ios_info" CFBundleIcons.CFBundlePrimaryIcon.CFBundleIconName \
        string agentlimits "iOS product" || return 1
    app_store_plist_expect_array_count \
        "$ios_info" CFBundleIcons.CFBundlePrimaryIcon.CFBundleIconFiles \
        1 "iOS product" || return 1
    app_store_plist_expect_value \
        "$ios_info" CFBundleIcons.CFBundlePrimaryIcon.CFBundleIconFiles.0 \
        string agentlimits60x60 "iOS product" || return 1
    app_store_plist_expect_dictionary_keys \
        "$ios_info" 'CFBundleIcons~ipad' "iPad product" \
        CFBundlePrimaryIcon || return 1
    app_store_plist_expect_dictionary_keys \
        "$ios_info" 'CFBundleIcons~ipad.CFBundlePrimaryIcon' "iPad product" \
        CFBundleIconFiles CFBundleIconName || return 1
    app_store_plist_expect_value \
        "$ios_info" 'CFBundleIcons~ipad.CFBundlePrimaryIcon.CFBundleIconName' \
        string agentlimits "iPad product" || return 1
    app_store_plist_expect_array_count \
        "$ios_info" 'CFBundleIcons~ipad.CFBundlePrimaryIcon.CFBundleIconFiles' \
        2 "iPad product" || return 1
    app_store_plist_expect_value \
        "$ios_info" 'CFBundleIcons~ipad.CFBundlePrimaryIcon.CFBundleIconFiles.0' \
        string agentlimits60x60 "iPad product" || return 1
    app_store_plist_expect_value \
        "$ios_info" 'CFBundleIcons~ipad.CFBundlePrimaryIcon.CFBundleIconFiles.1' \
        string agentlimits76x76 "iPad product" || return 1

    app_store_validate_png \
        "$ios_app/agentlimits60x60@2x.png" 120 120 \
        "iPhone compiled icon" || return 1
    app_store_validate_png \
        "$ios_app/agentlimits76x76@2x~ipad.png" 152 152 \
        "iPad compiled icon" || return 1
    app_store_write_asset_catalog_info \
        "$ios_app/Assets.car" "iOS compiled assets" ios \
        "$scratch_dir/ios-assets.plist" "$assetutil" || return 1
    app_store_asset_catalog_expect_named_icon \
        "$scratch_dir/ios-assets.plist" phone \
        "iOS compiled assets" || return 1
    app_store_asset_catalog_expect_named_icon \
        "$scratch_dir/ios-assets.plist" pad \
        "iOS compiled assets" || return 1

    app_store_plist_expect_value \
        "$watch_info" CFBundleName string AgentLimitsWatch \
        "Watch product" || return 1
    app_store_plist_expect_array_count \
        "$watch_info" CFBundleSupportedPlatforms 1 "Watch product" || return 1
    app_store_plist_expect_value \
        "$watch_info" CFBundleSupportedPlatforms.0 string \
        WatchOS "Watch product" || return 1
    app_store_plist_expect_array_count \
        "$watch_info" UIDeviceFamily 1 "Watch product" || return 1
    app_store_plist_expect_value \
        "$watch_info" UIDeviceFamily.0 integer 4 "Watch product" || return 1
    app_store_plist_expect_value \
        "$watch_info" WKApplication bool true "Watch product" || return 1
    app_store_plist_expect_value \
        "$watch_info" WKCompanionAppBundleIdentifier string \
        com.jimboha.agentlimits.ios "Watch product" || return 1
    app_store_plist_expect_value \
        "$watch_info" WKRunsIndependentlyOfCompanionApp bool false \
        "Watch product" || return 1
    app_store_plist_expect_dictionary_keys \
        "$watch_info" CFBundleIcons "Watch product" \
        CFBundlePrimaryIcon || return 1
    app_store_plist_expect_dictionary_keys \
        "$watch_info" CFBundleIcons.CFBundlePrimaryIcon "Watch product" \
        CFBundleIconName || return 1
    app_store_plist_expect_value \
        "$watch_info" CFBundleIcons.CFBundlePrimaryIcon.CFBundleIconName \
        string agentlimits "Watch product" || return 1
    app_store_write_asset_catalog_info \
        "$watch_app/Assets.car" "Watch compiled assets" watch \
        "$scratch_dir/watch-assets.plist" "$assetutil" || return 1
    app_store_asset_catalog_expect_named_icon \
        "$scratch_dir/watch-assets.plist" watch \
        "Watch compiled assets" || return 1

    app_store_validate_privacy_manifest \
        "$ios_app/PrivacyInfo.xcprivacy" "iOS privacy manifest" ios \
        "$scratch_dir" || return 1
    app_store_validate_privacy_manifest \
        "$watch_app/PrivacyInfo.xcprivacy" "Watch privacy manifest" watch \
        "$scratch_dir" || return 1
}

validate_app_store_product() {
    if [[ $# -ne 4 ]]; then
        app_store_validation_error \
            "usage: validate_app_store_product IOS_APP VERSION BUILD SCRATCH_DIR"
        return 64
    fi
    app_store_validate_product_with_assetutil "$1" "$2" "$3" "$4" \
        /usr/bin/assetutil
}
