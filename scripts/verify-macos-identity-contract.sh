#!/bin/bash

set -euo pipefail

readonly project_path="${1:-macos/XDial.xcodeproj}"
readonly application_identifier="com.kafeifei.xdial.app"
readonly settings_identifier="com.kafeifei.xdial.app.settings-ui"
readonly extension_identifier="com.kafeifei.xdial.app.transparent-proxy"
readonly settings_cache="$(mktemp -d "${TMPDIR:-/tmp}/xdial-build-settings.XXXXXX")"
trap 'rm -rf "$settings_cache"' EXIT

fail() {
    echo "error: $*" >&2
    exit 1
}

build_setting() {
    local configuration="$1"
    local target="$2"
    local key="$3"

    local cached="$settings_cache/$configuration-$target.txt"
    if [[ ! -f "$cached" ]]; then
        /usr/bin/xcodebuild -project "$project_path" -target "$target" \
            -configuration "$configuration" -showBuildSettings \
            >"$cached" 2>"$cached.stderr" \
            || { cat "$cached.stderr" >&2; fail "cannot read $configuration/$target settings"; }
    fi
    /usr/bin/awk -F ' = ' -v key="$key" '
        $1 ~ "^[[:space:]]*" key "$" { value=$2 }
        END { print value }
    ' "$cached"
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

for configuration in FormalDevelopment Release; do
    assert_setting "$configuration" XDial "$application_identifier"
    assert_setting "$configuration" XDialSettingsUI "$settings_identifier"
    assert_setting \
        "$configuration" XDialTransparentProxy "$extension_identifier"
done

assert_setting Debug XDial com.kafeifei.xdial.debug
assert_setting Debug XDialSettingsUI com.kafeifei.xdial.debug.settings-ui
assert_setting Debug XDialTransparentProxy com.kafeifei.xdial.debug.transparent-proxy
assert_build_setting Debug XDial PRODUCT_NAME 'XDail Debug'
assert_build_setting Debug XDial EXECUTABLE_NAME XDial
assert_build_setting Debug XDial XDIAL_HELPER_IDENTIFIER com.kafeifei.xdial.debug.helper
assert_build_setting Debug XDial XDIAL_DAEMON_PLIST com.kafeifei.xdial.debug.daemon.plist
assert_build_setting Debug XDial XDIAL_DAEMON_ENTITLEMENTS XDialDaemonDebug.entitlements
assert_build_setting Debug XDial CODE_SIGN_ENTITLEMENTS XDialDebug.entitlements
assert_build_setting Debug XDialTransparentProxy CODE_SIGN_ENTITLEMENTS TransparentProxyExtension/XDialTransparentProxyDebug.entitlements
for target in XDial XDialSettingsUI XDialTransparentProxy XDialTests; do
    [[ " $(build_setting Debug "$target" SWIFT_ACTIVE_COMPILATION_CONDITIONS) " == *' XDIAL_DEVELOPMENT_IDENTITY '* ]] \
        || fail "Debug/$target missing development identity condition"
done
for configuration in FormalDevelopment Release; do
    for target in XDial XDialSettingsUI XDialTransparentProxy; do
        [[ " $(build_setting "$configuration" "$target" SWIFT_ACTIVE_COMPILATION_CONDITIONS) " != *' XDIAL_DEVELOPMENT_IDENTITY '* ]] \
            || fail "$configuration/$target incorrectly uses development identity"
    done
    assert_build_setting "$configuration" XDial PRODUCT_NAME XDial
    assert_build_setting "$configuration" XDial XDIAL_HELPER_IDENTIFIER com.kafeifei.xdial.app.helper
    assert_build_setting "$configuration" XDial XDIAL_DAEMON_PLIST com.kafeifei.xdial.app.daemon.plist
done
for target in XDial XDialSettingsUI XDialTransparentProxy; do
    assert_build_setting Debug "$target" CODE_SIGN_IDENTITY 'Apple Development'
    assert_build_setting Release "$target" CODE_SIGN_IDENTITY 'Developer ID Application'
done
assert_build_setting Release XDial PROVISIONING_PROFILE_SPECIFIER 'XDial Developer ID App Host 2026'
assert_build_setting Release XDialTransparentProxy PROVISIONING_PROFILE_SPECIFIER 'XDial Developer ID App Transparent Proxy'
for configuration in FormalDevelopment; do
    assert_build_setting \
        "$configuration" XDial CODE_SIGN_ENTITLEMENTS XDial.entitlements
done
assert_build_setting \
    Release XDial CODE_SIGN_ENTITLEMENTS XDialRelease.entitlements

assert_plist_boolean macos/XDialDebug.entitlements \
    'com\.apple\.security\.personal-information\.location'
assert_plist_boolean macos/XDial.entitlements \
    'com\.apple\.security\.personal-information\.location'
assert_plist_boolean macos/XDialRelease.entitlements \
    'com\.apple\.security\.personal-information\.location'
assert_plist_nonempty macos/Info.plist NSLocationUsageDescription

python3 - <<'PYTHON'
import pathlib, plistlib
for path in ["XDialDebug.entitlements", "XDialDaemonDebug.entitlements", "TransparentProxyExtension/XDialTransparentProxyDebug.entitlements"]:
    value = plistlib.loads((pathlib.Path("macos") / path).read_bytes())
    assert value["com.apple.security.application-groups"] == ["UVZM439VGU.com.kafeifei.xdial.debug.network"], path
value = plistlib.loads(pathlib.Path("macos/com.kafeifei.xdial.debug.daemon.plist").read_bytes())
assert value["Label"] == "com.kafeifei.xdial.debug.daemon"
assert "/tmp/xdial-debug.sock" in value["ProgramArguments"]
assert value["AssociatedBundleIdentifiers"] == ["com.kafeifei.xdial.debug"]
assert value["StandardOutPath"] == value["StandardErrorPath"] == "/tmp/xdial-debug.log"
PYTHON

echo "macOS development isolation, formal identity, and location-access contracts verified"
