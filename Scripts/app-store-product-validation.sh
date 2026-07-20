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

validate_app_store_product() {
    if [[ $# -ne 4 ]]; then
        app_store_validation_error \
            "usage: validate_app_store_product IOS_APP VERSION BUILD SCRATCH_DIR"
        return 64
    fi

    local ios_app="$1"
    local expected_version="$2"
    local expected_build="$3"
    local scratch_dir="$4"
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

    app_store_require_regular_file \
        "$ios_app/Assets.car" "iOS compiled assets" || return 1
    app_store_require_regular_file \
        "$ios_app/agentlimits60x60@2x.png" "iPhone App Store icon" || return 1
    app_store_require_regular_file \
        "$ios_app/agentlimits76x76@2x~ipad.png" "iPad App Store icon" || return 1

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
    app_store_require_regular_file \
        "$watch_app/Assets.car" "Watch compiled assets" || return 1

    app_store_validate_privacy_manifest \
        "$ios_app/PrivacyInfo.xcprivacy" "iOS privacy manifest" ios \
        "$scratch_dir" || return 1
    app_store_validate_privacy_manifest \
        "$watch_app/PrivacyInfo.xcprivacy" "Watch privacy manifest" watch \
        "$scratch_dir" || return 1
}
