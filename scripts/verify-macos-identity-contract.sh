#!/bin/bash

set -euo pipefail

readonly project_path="${1:-macos/XDial.xcodeproj}"
readonly application_identifier="com.kafeifei.xdial.app"
readonly settings_identifier="com.kafeifei.xdial.app.settings-ui"
readonly extension_identifier="com.kafeifei.xdial.app.transparent-proxy"

fail() {
    echo "error: $*" >&2
    exit 1
}

build_setting() {
    local configuration="$1"
    local target="$2"
    local key="$3"

    /usr/bin/xcodebuild \
        -project "$project_path" \
        -target "$target" \
        -configuration "$configuration" \
        -showBuildSettings 2>/dev/null \
        | /usr/bin/awk -F ' = ' -v key="$key" '
            $1 ~ "^[[:space:]]*" key "$" { print $2; exit }
        '
}

assert_setting() {
    local configuration="$1"
    local target="$2"
    local expected="$3"
    local actual

    actual="$(build_setting \
        "$configuration" "$target" PRODUCT_BUNDLE_IDENTIFIER)"
    [[ "$actual" == "$expected" ]] \
        || fail "$configuration/$target uses '$actual', expected '$expected'"
}

assert_build_setting() {
    local configuration="$1"
    local target="$2"
    local key="$3"
    local expected="$4"
    local actual

    actual="$(build_setting "$configuration" "$target" "$key")"
    [[ "$actual" == "$expected" ]] \
        || fail "$configuration/$target $key is '$actual', expected '$expected'"
}

assert_plist_boolean() {
    local plist="$1"
    local key="$2"
    local actual

    [[ -f "$plist" ]] || fail "missing plist: $plist"
    actual="$(/usr/bin/plutil -extract "$key" raw -o - "$plist" 2>/dev/null \
        || true)"
    [[ "$actual" == true ]] \
        || fail "$plist is missing required boolean entitlement $key"
}

assert_plist_nonempty() {
    local plist="$1"
    local key="$2"
    local actual

    [[ -f "$plist" ]] || fail "missing plist: $plist"
    actual="$(/usr/bin/plutil -extract "$key" raw -o - "$plist" 2>/dev/null \
        || true)"
    [[ -n "$actual" ]] || fail "$plist is missing required key $key"
}

[[ -f "$project_path/project.pbxproj" ]] \
    || fail "generated Xcode project is missing: $project_path"

for configuration in Debug FormalDevelopment Release; do
    assert_setting "$configuration" XDial "$application_identifier"
    assert_setting "$configuration" XDialSettingsUI "$settings_identifier"
    assert_setting \
        "$configuration" XDialTransparentProxy "$extension_identifier"
done

for configuration in Debug FormalDevelopment; do
    assert_build_setting \
        "$configuration" XDial CODE_SIGN_ENTITLEMENTS XDial.entitlements
done
assert_build_setting \
    Release XDial CODE_SIGN_ENTITLEMENTS XDialRelease.entitlements

assert_plist_boolean macos/XDial.entitlements \
    'com\.apple\.security\.personal-information\.location'
assert_plist_boolean macos/XDialRelease.entitlements \
    'com\.apple\.security\.personal-information\.location'
assert_plist_nonempty macos/Info.plist NSLocationUsageDescription

echo "macOS identity and location-access contract verified for Debug, FormalDevelopment, and Release"
