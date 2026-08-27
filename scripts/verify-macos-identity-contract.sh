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

[[ -f "$project_path/project.pbxproj" ]] \
    || fail "generated Xcode project is missing: $project_path"

for configuration in Debug FormalDevelopment Release; do
    assert_setting "$configuration" XDial "$application_identifier"
    assert_setting "$configuration" XDialSettingsUI "$settings_identifier"
    assert_setting \
        "$configuration" XDialTransparentProxy "$extension_identifier"
done

echo "macOS identity contract verified for Debug, FormalDevelopment, and Release"
