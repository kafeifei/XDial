#!/bin/bash

set -euo pipefail

repository_root="$(cd "$(dirname "$0")/.." && pwd)"
contract="$repository_root/scripts/release-contract.sh"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/xdial-release-test.XXXXXX")"
trap 'rm -rf "$test_root"' EXIT

# Fixture repositories are removed right after use; keep git from starting a
# detached auto maintenance that could still be writing into them.
export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=maintenance.auto GIT_CONFIG_VALUE_0=false

fail() {
    echo "release contract test failed: $*" >&2
    exit 1
}

expect_failure() {
    if "$@" >/dev/null 2>&1; then
        fail "command unexpectedly succeeded: $*"
    fi
}

# Also pins the reason, so a fixture cannot fail for an unrelated defect.
expect_failure_with() {
    local message="$1"
    shift
    local output
    if output="$("$@" 2>&1)"; then
        fail "command unexpectedly succeeded: $*"
    fi
    grep -Fq -- "$message" <<<"$output" \
        || fail "expected '$message' from: $*; got: $output"
}

"$contract" validate-inputs v0.7.0 98
"$contract" validate-inputs v12.34.56 1787300000
expect_failure "$contract" validate-inputs 0.7.0 98
expect_failure "$contract" validate-inputs v0.7 98
expect_failure "$contract" validate-inputs v01.7.0 98
expect_failure "$contract" validate-inputs v0.7.0-rc.1 98
expect_failure "$contract" validate-inputs next-v0.7.0 98
expect_failure "$contract" validate-inputs v0.7.0 0
expect_failure "$contract" validate-inputs v0.7.0 build-98
expect_failure_with 'exact stable SemVer' "$contract" validate-inputs v1.4.0-beta.1 98

# Beta ships the same formal identity; the channel only picks the tag syntax
# and the branch the tag must be on.
beta_contract() {
    XDIAL_RELEASE_CHANNEL=beta "$contract" "$@"
}
beta_contract validate-inputs v1.4.0-beta.1 98
beta_contract validate-inputs v12.34.56-beta.789 1787300000
for tag in v1.4.0 v1.4.0-beta.0 v1.4.0-beta.01 v1.4.0-rc.1 v1.4.0-beta \
    v1.4.0-beta.1.2 v01.4.0-beta.1 1.4.0-beta.1; do
    expect_failure_with 'beta release tag must be exact' \
        beta_contract validate-inputs "$tag" 98
done
expect_failure beta_contract validate-inputs v1.4.0-beta.1 0
[[ "$("$contract" version-from-tag v1.4.0)" == 1.4.0 ]] \
    || fail "stable version-from-tag changed"
[[ "$(beta_contract version-from-tag v1.4.0-beta.1)" == 1.4.0 ]] \
    || fail "beta version-from-tag must drop -beta.N"
expect_failure "$contract" version-from-tag v1.4.0-beta.1
[[ "$("$contract" release-branch)" == main ]] || fail "stable must release from main"
[[ "$(beta_contract release-branch)" == xdial-beta ]] \
    || fail "beta must release from xdial-beta"
expect_failure_with 'unknown release channel' \
    env XDIAL_RELEASE_CHANNEL=next "$contract" release-branch

check_debug_entitlement() (
    source "$contract"
    assert_get_task_allow_absent_in_plist fixture "$1"
)

entitlement_plist_prefix='<?xml version="1.0"?><plist version="1.0"><dict>'
entitlement_plist_suffix='</dict></plist>'
debug_entitlement='<key>com.apple.security.get-task-allow</key>'
expect_failure check_debug_entitlement \
    "$entitlement_plist_prefix$debug_entitlement<true/>$entitlement_plist_suffix"
check_debug_entitlement \
    "$entitlement_plist_prefix$debug_entitlement<false/>$entitlement_plist_suffix"
check_debug_entitlement "$entitlement_plist_prefix$entitlement_plist_suffix"
check_debug_entitlement ''
expect_failure check_debug_entitlement 'invalid plist'

check_hardened_signature_details() (
    source "$contract"
    assert_hardened_signature_details fixture "$1"
)

# Shape of a notarized Developer ID signature as printed by codesign -dvvv.
hardened_details='Identifier=com.kafeifei.xdial.app
Format=app bundle with Mach-O thin (arm64)
CodeDirectory v=20500 size=29092 flags=0x10000(runtime) hashes=898+7 location=embedded
Authority=Developer ID Application: XDial Fixture (UVZM439VGU)
Authority=Developer ID Certification Authority
Authority=Apple Root CA
Timestamp=Oct 11, 2026 at 23:06:00
TeamIdentifier=UVZM439VGU
Runtime Version=26.0.0'
check_hardened_signature_details "$hardened_details"
check_hardened_signature_details \
    "${hardened_details/0x10000(runtime)/0x12000(library-validation,runtime)}"
expect_failure_with 'not signed with the hardened runtime' \
    check_hardened_signature_details "${hardened_details/0x10000(runtime)/0x0(none)}"
expect_failure_with 'not signed with the hardened runtime' \
    check_hardened_signature_details \
    "${hardened_details/0x10000(runtime)/0x10000(runtime-disabled)}"
expect_failure_with 'no secure signing timestamp' \
    check_hardened_signature_details "${hardened_details/Timestamp=/Signed Time=}"
expect_failure check_hardened_signature_details ''

distribution_root="$test_root/distribution"
mkdir -p "$distribution_root/go-helper"
printf '%s\n' '#include <stdio.h>' \
    'int main(void) { puts("XDial fixture"); return 0; }' \
    >"$distribution_root/host.c"
printf '%s\n' '#include <stdio.h>' \
    'int main(void) { puts("DebugServer: ready on localhost:19877"); return 0; }' \
    >"$distribution_root/debug-host.c"
/usr/bin/xcrun clang -mmacosx-version-min=15.0 "$distribution_root/host.c" \
    -o "$distribution_root/host"
/usr/bin/xcrun clang -mmacosx-version-min=15.0 "$distribution_root/debug-host.c" \
    -o "$distribution_root/debug-host"
printf '%s\n' 'module example.invalid/helper' '' 'go 1.21' \
    >"$distribution_root/go-helper/go.mod"
cat >"$distribution_root/go-helper/main.go" <<'EOF'
package main

import (
	"fmt"
	"os"
)

var version = "dev"
var buildFlavor string

// Mirrors cmd/xdial's versionLine.
func main() {
	if len(os.Args) == 2 && os.Args[1] == "version" {
		line := "xdial " + version
		if buildFlavor != "" {
			line += " (buildFlavor=" + buildFlavor + ")"
		}
		fmt.Println(line)
	}
}
EOF
build_fixture_helper() {
    local output="$1"
    shift
    (
        cd "$distribution_root/go-helper"
        GOWORK=off GOFLAGS= go build -buildvcs=false "$@" -o "$output" .
    )
}
build_fixture_helper "$distribution_root/helper" -ldflags '-X main.version=v0.7.0'
build_fixture_helper "$distribution_root/flavored-helper" \
    -ldflags '-X main.version=v0.7.0 -X main.buildFlavor=x'
build_fixture_helper "$distribution_root/trimmed-flavored-helper" -trimpath \
    -ldflags '-X main.version=v0.7.0 -X main.buildFlavor=x'
debug_entitlements="$distribution_root/debug.entitlements"
printf '%s\n' "$entitlement_plist_prefix$debug_entitlement<true/>$entitlement_plist_suffix" \
    >"$debug_entitlements"

write_bundle_info() {
    local bundle="$1" executable="$2" identifier="$3"
    mkdir -p "$bundle/Contents/MacOS"
    cat >"$bundle/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>$executable</string>
<key>CFBundleIdentifier</key><string>$identifier</string>
<key>CFBundleShortVersionString</key><string>0.7.0</string>
<key>CFBundleVersion</key><string>98</string>
<key>NSLocationUsageDescription</key><string>fixture</string>
</dict></plist>
EOF
}

distribution_app="$distribution_root/clean/XDial.app"
distribution_settings="$distribution_app/Contents/Helpers/XDial Settings UI.app"
distribution_extension_name=com.kafeifei.xdial.app.transparent-proxy
distribution_extension="$distribution_app/Contents/Library/SystemExtensions/$distribution_extension_name.systemextension"
write_bundle_info "$distribution_app" XDial com.kafeifei.xdial.app
write_bundle_info "$distribution_settings" 'XDial Settings UI' \
    com.kafeifei.xdial.app.settings-ui
write_bundle_info "$distribution_extension" "$distribution_extension_name" \
    "$distribution_extension_name"
cp "$distribution_root/host" "$distribution_app/Contents/MacOS/XDial"
cp "$distribution_root/host" "$distribution_settings/Contents/MacOS/XDial Settings UI"
cp "$distribution_root/host" \
    "$distribution_extension/Contents/MacOS/$distribution_extension_name"
cp "$distribution_root/helper" "$distribution_app/Contents/MacOS/xdial-daemon"

# Ad-hoc signs inside-out; the component named by $2 gets get-task-allow.
sign_distribution_fixture() {
    local app="$1" debuggable="${2:-}"
    local settings="$app/Contents/Helpers/XDial Settings UI.app"
    local extension="$app/Contents/Library/SystemExtensions/$distribution_extension_name.systemextension"
    local name path arguments
    for name in helper settings extension app; do
        case "$name" in
            helper) path="$app/Contents/MacOS/xdial-daemon" ;;
            settings) path="$settings" ;;
            extension) path="$extension" ;;
            app) path="$app" ;;
        esac
        arguments=(-f -s -)
        if [[ "$name" == "$debuggable" ]]; then
            arguments+=(--entitlements "$debug_entitlements")
        fi
        /usr/bin/codesign "${arguments[@]}" "$path" 2>/dev/null
    done
}

distribution_variant() {
    local name="$1"
    local variant="$distribution_root/variants/$name/XDial.app"
    mkdir -p "$distribution_root/variants/$name"
    /usr/bin/ditto "$distribution_app" "$variant"
    printf '%s\n' "$variant"
}

hardened_record="$distribution_root/hardened-components"
# Everything that needs Developer ID signing or provisioning is stubbed, so
# verify-app exercises the real distribution checks on an ad-hoc bundle.
verify_distribution_fixture() (
    source "$contract"
    assert_app_deployment_target() { :; }
    assert_component_names() { :; }
    assert_developer_id_signature() { :; }
    assert_system_extension_authorization() { :; }
    assert_location_entitlement() { :; }
    # Ad-hoc signatures cannot carry a secure timestamp.
    assert_hardened_signature() { printf '%s\n' "$1" >>"$hardened_record"; }
    verify_app "$1" v0.7.0 98
)

sign_distribution_fixture "$distribution_app"
rm -f "$hardened_record"
if ! clean_output="$(verify_distribution_fixture "$distribution_app" 2>&1)"; then
    fail "verify-app rejected a clean distribution fixture: $clean_output"
fi
[[ "$(cat "$hardened_record")" == "$(printf '%s\n' "$distribution_app" \
    "$distribution_settings" "$distribution_extension" \
    "$distribution_app/Contents/MacOS/xdial-daemon")" ]] \
    || fail "verify-app did not check the signature of every distribution component"

for component in app settings extension helper; do
    variant="$(distribution_variant "debuggable-$component")"
    sign_distribution_fixture "$variant" "$component"
    expect_failure_with 'forbidden get-task-allow entitlement' \
        verify_distribution_fixture "$variant"
done

variant="$(distribution_variant debug-server)"
cp "$distribution_root/debug-host" "$variant/Contents/MacOS/XDial"
sign_distribution_fixture "$variant"
expect_failure_with 'contains the development DebugServer' \
    verify_distribution_fixture "$variant"

# The Debug configuration's layout: a clean stub executable, with the host's
# code in a debug dylib beside it.
variant="$(distribution_variant debug-dylib)"
cp "$distribution_root/debug-host" "$variant/Contents/MacOS/XDial.debug.dylib"
/usr/bin/codesign -f -s - "$variant/Contents/MacOS/XDial.debug.dylib" 2>/dev/null
sign_distribution_fixture "$variant"
expect_failure_with 'XDial.debug.dylib contains the development DebugServer' \
    verify_distribution_fixture "$variant"

variant="$(distribution_variant flavored-helper)"
cp "$distribution_root/flavored-helper" "$variant/Contents/MacOS/xdial-daemon"
sign_distribution_fixture "$variant"
expect_failure_with 'main.buildFlavor override' \
    verify_distribution_fixture "$variant"

# -trimpath drops -ldflags from the build information, so only the helper's
# version line reveals this flavor.
variant="$(distribution_variant trimmed-flavored-helper)"
cp "$distribution_root/trimmed-flavored-helper" "$variant/Contents/MacOS/xdial-daemon"
sign_distribution_fixture "$variant"
expect_failure_with "bundled helper reports 'xdial v0.7.0 (buildFlavor=x)'" \
    verify_distribution_fixture "$variant"

# The helper must be a Go executable whose build information is readable.
variant="$(distribution_variant native-helper)"
cp "$distribution_root/host" "$variant/Contents/MacOS/xdial-daemon"
sign_distribution_fixture "$variant"
expect_failure_with 'cannot read Go build information' \
    verify_distribution_fixture "$variant"

# A machine without Go is told so, instead of being sent after a valid helper.
no_tools="$test_root/no-tools"
mkdir -p "$no_tools"
check_helper_flavor_without_go() (
    source "$contract"
    PATH="$no_tools"
    assert_helper_without_build_flavor "$1"
)
expect_failure_with 'go is required' \
    check_helper_flavor_without_go "$distribution_root/helper"

check_hardened_signature() (
    source "$contract"
    assert_hardened_signature "$1"
)

# Real codesign output: an ad-hoc signature never has a secure timestamp, and
# the hardened runtime flag is parsed from the CodeDirectory line.
cp "$distribution_root/host" "$distribution_root/plain-signed"
/usr/bin/codesign -s - "$distribution_root/plain-signed" 2>/dev/null
expect_failure_with 'not signed with the hardened runtime' \
    check_hardened_signature "$distribution_root/plain-signed"
cp "$distribution_root/host" "$distribution_root/runtime-signed"
/usr/bin/codesign -s - -o runtime "$distribution_root/runtime-signed" 2>/dev/null
expect_failure_with 'no secure signing timestamp' \
    check_hardened_signature "$distribution_root/runtime-signed"
expect_failure check_hardened_signature "$distribution_root/missing"

check_deployment_target() (
    source "$contract"
    assert_app_deployment_target "$1"
)

deployment_fixture="$test_root/DeploymentFixture.app"
mkdir -p "$deployment_fixture/Contents/MacOS"
cat >"$deployment_fixture/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>DeploymentFixture</string>
<key>CFBundleIdentifier</key><string>com.kafeifei.xdial.deployment-fixture</string>
<key>LSMinimumSystemVersion</key><string>15.0</string>
</dict></plist>
EOF
printf '%s\n' 'int main(void) { return 0; }' >"$test_root/deployment-fixture.c"
/usr/bin/xcrun clang -mmacosx-version-min=15.0 \
    "$test_root/deployment-fixture.c" \
    -o "$deployment_fixture/Contents/MacOS/DeploymentFixture"
/usr/bin/xcrun clang -mmacosx-version-min=15.0 \
    "$test_root/deployment-fixture.c" \
    -o "$deployment_fixture/Contents/MacOS/xdial-daemon"
check_deployment_target "$deployment_fixture"

# Older Mach-O files use LC_VERSION_MIN_MACOSX instead of LC_BUILD_VERSION.
/usr/bin/vtool -set-version-min macos 15.0 26.5 -replace \
    -output "$test_root/legacy-helper" \
    "$deployment_fixture/Contents/MacOS/xdial-daemon"
mv "$test_root/legacy-helper" \
    "$deployment_fixture/Contents/MacOS/xdial-daemon"
check_deployment_target "$deployment_fixture"

# Every architecture in a universal executable must target macOS.
/usr/bin/xcrun clang -arch arm64 -mmacosx-version-min=15.0 \
    "$test_root/deployment-fixture.c" -o "$test_root/helper-arm64-15"
/usr/bin/xcrun clang -arch x86_64 -mmacosx-version-min=26.0 \
    "$test_root/deployment-fixture.c" -o "$test_root/helper-x86_64-26"
/usr/bin/lipo -create "$test_root/helper-arm64-15" \
    "$test_root/helper-x86_64-26" \
    -output "$deployment_fixture/Contents/MacOS/xdial-daemon"
expect_failure check_deployment_target "$deployment_fixture"

/usr/bin/vtool -set-build-version iossim 26.0 26.5 -replace \
    -output "$test_root/helper-x86_64-iossim" \
    "$test_root/helper-x86_64-26"
/usr/bin/lipo -create "$test_root/helper-arm64-15" \
    "$test_root/helper-x86_64-iossim" \
    -output "$deployment_fixture/Contents/MacOS/xdial-daemon"
expect_failure check_deployment_target "$deployment_fixture"

# A valid first slice must not hide a second slice with no deployment command.
/usr/bin/vtool -remove-build-version macos \
    -output "$test_root/helper-x86_64-no-deployment" \
    "$test_root/helper-x86_64-26"
/usr/bin/lipo -create "$test_root/helper-arm64-15" \
    "$test_root/helper-x86_64-no-deployment" \
    -output "$deployment_fixture/Contents/MacOS/xdial-daemon"
expect_failure check_deployment_target "$deployment_fixture"

/usr/bin/xcrun clang -mmacosx-version-min=26.0 \
    "$test_root/deployment-fixture.c" \
    -o "$deployment_fixture/Contents/MacOS/xdial-daemon"
expect_failure check_deployment_target "$deployment_fixture"

check_system_extension_authorization() (
    source "$contract"
    assert_system_extension_authorization_plists "$1" "$2" "$3" 1800000000
)

for identifier in com.kafeifei.xdial.app com.kafeifei.xdial.app.transparent-proxy; do
    authorization_dictionary="<dict>
<key>com.apple.application-identifier</key><string>UVZM439VGU.$identifier</string>
<key>com.apple.developer.team-identifier</key><string>UVZM439VGU</string>
<key>com.apple.developer.networking.networkextension</key>
<array><string>app-proxy-provider-systemextension</string></array>
<key>com.apple.developer.system-extension.install</key><true/>
</dict>"
    signed="<plist version=\"1.0\">$authorization_dictionary</plist>"
    profile="<plist version=\"1.0\"><dict>
<key>TeamIdentifier</key><array><string>UVZM439VGU</string></array>
<key>ProvisionsAllDevices</key><true/>
<key>CreationDate</key><date>2026-01-01T00:00:00Z</date>
<key>ExpirationDate</key><date>2044-01-01T00:00:00Z</date>
<key>Entitlements</key>$authorization_dictionary
</dict></plist>"
    check_system_extension_authorization "$identifier" "$signed" "$profile"
    expect_failure check_system_extension_authorization "$identifier" '' "$profile"
    expect_failure check_system_extension_authorization "$identifier" "$signed" ''
    expect_failure check_system_extension_authorization "$identifier" "$signed" 'invalid plist'
    expect_failure check_system_extension_authorization "$identifier" \
        "${signed/UVZM439VGU.$identifier/UVZM439VGU.wrong}" "$profile"
    expect_failure check_system_extension_authorization "$identifier" "$signed" \
        "${profile/UVZM439VGU.$identifier/UVZM439VGU.wrong}"
    expect_failure check_system_extension_authorization "$identifier" \
        "${signed/<string>UVZM439VGU<\//<string>WRONGTEAM<\/}" "$profile"
    expect_failure check_system_extension_authorization "$identifier" "$signed" \
        "${profile/<string>UVZM439VGU<\//<string>WRONGTEAM<\/}"
    expect_failure check_system_extension_authorization "$identifier" \
        "${signed/app-proxy-provider-systemextension/app-proxy-provider}" "$profile"
    expect_failure check_system_extension_authorization "$identifier" "$signed" \
        "${profile/app-proxy-provider-systemextension/app-proxy-provider}"
    expect_failure check_system_extension_authorization "$identifier" "$signed" \
        "${profile/2044-01-01/2000-01-01}"
    expect_failure check_system_extension_authorization "$identifier" "$signed" \
        "${profile/2026-01-01/2040-01-01}"
    expect_failure check_system_extension_authorization "$identifier" "$signed" \
        "${profile/CreationDate/MissingCreationDate}"
    expect_failure check_system_extension_authorization "$identifier" "$signed" \
        "${profile/ProvisionsAllDevices/MissingProvisionsAllDevices}"
    if [[ "$identifier" == com.kafeifei.xdial.app ]]; then
        expect_failure check_system_extension_authorization "$identifier" \
            "${signed/system-extension.install/missing.install}" "$profile"
        expect_failure check_system_extension_authorization "$identifier" "$signed" \
            "${profile/system-extension.install/missing.install}"
        expect_failure check_system_extension_authorization "$identifier" \
            "${signed/<true\//<false\/}" "$profile"
    fi
done

notes="$test_root/RELEASE_NOTES.md"
printf '%s\n' \
    '# XDial v0.7.0' \
    '' \
    '## 更新了什么' \
    '' \
    '- 新增应用内更新。' >"$notes"
"$contract" validate-notes v0.7.0 "$notes"
expect_failure "$contract" validate-notes v0.8.0 "$notes"
printf '%s\n' '# XDial v0.7.0' '' '## 更新了什么' >"$notes"
expect_failure "$contract" validate-notes v0.7.0 "$notes"

git_fixture="$test_root/git-fixture"
mkdir -p "$git_fixture"
(
    cd "$git_fixture"
    git init -q -b main
    git config user.name 'XDial Test'
    git config user.email 'xdial-test@example.invalid'
    printf '%s\n' fixture >tracked.txt
    git add tracked.txt
    git commit -qm fixture
    git tag v1.2.3
    expect_failure "$contract" assert-git-tag v1.2.3
    git update-ref refs/remotes/origin/main HEAD
    "$contract" assert-git-tag v1.2.3
    printf '%s\n' dirty >>tracked.txt
    expect_failure "$contract" assert-git-tag v1.2.3
    git restore tracked.txt

    git switch -qc feature
    printf '%s\n' feature >feature.txt
    git add feature.txt
    git commit -qm feature
    git tag v1.2.4
    expect_failure "$contract" assert-git-tag v1.2.4
    git switch -q main
    git merge --no-ff -qm 'merge feature' feature
    git update-ref refs/remotes/origin/main HEAD
    git tag v1.2.5
    "$contract" assert-git-tag v1.2.5
    git switch -q --detach v1.2.4
    expect_failure "$contract" assert-git-tag v1.2.4

    git switch -q main
    printf '%s\n' later >later.txt
    git add later.txt
    git commit -qm later
    git update-ref refs/remotes/origin/main HEAD
    git switch -q --detach v1.2.5
    "$contract" assert-git-tag v1.2.5
)

# origin is a local bare repository, so release-inputs never fetches over the
# network.
release_source="$test_root/release-source.git"
release_work="$test_root/release-work"
git init -q --bare "$release_source"
git init -q -b main "$release_work"
(
    cd "$release_work"
    git config user.name 'XDial Test'
    git config user.email 'xdial-test@example.invalid'
    printf '%s\n' source >tracked.txt
    git add tracked.txt
    git commit -qm source
    git remote add origin "$release_source"
    git push -qu origin main
    git tag v2.3.4
    git update-ref -d refs/remotes/origin/main
    release_notes="$test_root/release-input-notes.md"

    # Notes for another version fail before origin/main is fetched, and an
    # acceptance build does not skip them.
    printf '%s\n' '# XDial v2.3.3' '' '## 更新了什么' '' '- 门禁测试。' \
        >"$release_notes"
    expect_failure make -s --no-print-directory -f "$repository_root/Makefile" \
        release-inputs RELEASE_CONTRACT="$contract" RELEASE_TAG=v2.3.4 \
        RELEASE_BUILD_NUMBER=234 RELEASE_NOTES_FILE="$release_notes"
    expect_failure make -s --no-print-directory -f "$repository_root/Makefile" \
        release-inputs RELEASE_CONTRACT="$contract" RELEASE_TAG=v2.3.4 \
        RELEASE_BUILD_NUMBER=234 RELEASE_NOTES_FILE="$release_notes" \
        RELEASE_UPDATE_ACCEPTANCE_ID=pages-fixture
    if git rev-parse -q --verify refs/remotes/origin/main >/dev/null; then
        fail "release-inputs fetched origin/main before validating the notes"
    fi

    # Valid inputs refresh origin/main before the tag is checked against it.
    printf '%s\n' '# XDial v2.3.4' '' '## 更新了什么' '' '- 门禁测试。' \
        >"$release_notes"
    make -s --no-print-directory -f "$repository_root/Makefile" release-inputs \
        RELEASE_CONTRACT="$contract" RELEASE_TAG=v2.3.4 RELEASE_BUILD_NUMBER=234 \
        RELEASE_NOTES_FILE="$release_notes"
    [[ "$(git rev-parse refs/remotes/origin/main)" == "$(git rev-parse HEAD)" ]] \
        || fail "release-inputs did not refresh origin/main"

    # A failed refresh must not fall through to a stale, otherwise valid ref.
    git remote remove origin
    git update-ref refs/remotes/origin/main HEAD
    expect_failure make -s --no-print-directory -f "$repository_root/Makefile" \
        release-inputs RELEASE_CONTRACT="$contract" RELEASE_TAG=v2.3.4 \
        RELEASE_BUILD_NUMBER=234 RELEASE_NOTES_FILE="$release_notes"

    # Explicit formal-identity acceptance builds have synthetic versions and no
    # stable tag. They alone may bypass the stable tag/main check, and publish
    # refuses them before the stable publisher runs. This fixture has no
    # scripts/publish-release.py, so a broken guard still cannot publish.
    git tag -d v2.3.4 >/dev/null
    printf '%s\n' '# XDial v9.9.9' '' '## 更新了什么' '' '- 验收包。' \
        >"$release_notes"
    make -s --no-print-directory -f "$repository_root/Makefile" release-inputs \
        RELEASE_CONTRACT="$contract" RELEASE_TAG=v9.9.9 RELEASE_BUILD_NUMBER=999 \
        RELEASE_NOTES_FILE="$release_notes" \
        RELEASE_UPDATE_ACCEPTANCE_ID=pages-fixture
    if publish_output="$(make -s --no-print-directory -f "$repository_root/Makefile" \
        publish RELEASE_TAG=v9.9.9 RELEASE_UPDATE_ACCEPTANCE_ID=pages-fixture 2>&1)"; then
        fail "an acceptance build reached the stable publisher"
    fi
    grep -Fq 'an acceptance build cannot be published to stable' <<<"$publish_output" \
        || fail "publish did not refuse the acceptance build before running"
)

# Go stamps vcs.modified from git status when it compiles the helper, and the
# icon targets rewrite tracked .icns files, so release-app must compile the
# helper first. A fresh BUILD_DIR makes every icon rule part of the plan.
release_plan_build="$test_root/release-plan-build"
release_plan="$(make -n --no-print-directory -C "$repository_root" release-app \
    BUILD_DIR="$release_plan_build" RELEASE_TAG=v0.7.0 RELEASE_BUILD_NUMBER=98)"
helper_step="$(grep -n -F -- "-o $release_plan_build/xdial ./cmd/xdial/" \
    <<<"$release_plan" | head -n 1 | cut -d: -f1)"
icon_step="$(grep -n -F 'iconutil -c icns' <<<"$release_plan" | head -n 1 | cut -d: -f1)"
[[ -n "$helper_step" && -n "$icon_step" ]] \
    || fail "release-app plan has no helper or icon step"
[[ "$helper_step" -lt "$icon_step" ]] \
    || fail "release-app regenerates tracked icons before compiling the helper"

# verify-release-helper-source.sh runs only in the official release workflow.
helper_source="$repository_root/scripts/verify-release-helper-source.sh"
source_repository="$test_root/helper-source"
source_app="$test_root/helper-source-app/XDial.app"
mkdir -p "$source_repository" "$source_app/Contents/MacOS"
cp "$distribution_root/go-helper/go.mod" "$distribution_root/go-helper/main.go" \
    "$source_repository/"
(
    cd "$source_repository"
    git init -q -b main
    git config user.name 'XDial Test'
    git config user.email 'xdial-test@example.invalid'
    git add go.mod main.go
    git commit -qm source
    git tag v3.4.5

    build_stamped_helper() {
        GOWORK=off GOFLAGS= go build -trimpath "$@" \
            -o "$source_app/Contents/MacOS/xdial-daemon" .
    }

    build_stamped_helper
    "$helper_source" "$source_app" v3.4.5 >/dev/null
    expect_failure_with 'go is required' \
        /usr/bin/env PATH="$no_tools" "$helper_source" "$source_app" v3.4.5
    expect_failure_with 'release tag does not exist' \
        "$helper_source" "$source_app" v3.4.6
    expect_failure "$helper_source" "$test_root/helper-source-app/Missing.app" v3.4.5

    printf '%s\n' '// local edit' >>main.go
    build_stamped_helper
    expect_failure_with 'uncommitted changes' "$helper_source" "$source_app" v3.4.5
    git commit -qam later
    build_stamped_helper
    expect_failure_with "not v3.4.5" "$helper_source" "$source_app" v3.4.5

    git switch -q --detach v3.4.5
    build_stamped_helper -buildvcs=false
    expect_failure_with 'no Git build stamp' "$helper_source" "$source_app" v3.4.5
)

fixture_root="$test_root/archive-fixture"
fixture_app="$fixture_root/XDial.app"
mkdir -p "$fixture_app/Contents"
printf '%s\n' fixture >"$fixture_app/Contents/payload"
output_root="$test_root/output"
archive_path="$output_root/XDial-v0.7.0.zip"
"$contract" archive "$fixture_app" v0.7.0 "$output_root" >/dev/null
[[ -f "$archive_path" ]] || fail "archive was not created"
[[ -f "$archive_path.sha256" ]] || fail "checksum was not created"
"$contract" verify-archive-shape "$archive_path"
"$contract" verify-checksum "$archive_path" "$archive_path.sha256"

ln -s "$fixture_app" "$fixture_root/Symlink.app"
expect_failure "$contract" archive "$fixture_root/Symlink.app" v0.7.0 "$output_root"

tampered_root="$test_root/tampered"
mkdir -p "$tampered_root"
/usr/bin/ditto "$fixture_app" "$tampered_root/XDial.app"
printf '%s\n' extra >"$tampered_root/extra.txt"
(
    cd "$tampered_root"
    /usr/bin/zip -qry "$test_root/tampered.zip" XDial.app extra.txt
)
expect_failure "$contract" verify-archive-shape "$test_root/tampered.zip"

other_root="$test_root/other-root"
mkdir -p "$other_root"
/usr/bin/ditto "$fixture_app" "$other_root/Other.app"
/usr/bin/ditto -c -k --keepParent "$other_root/Other.app" "$test_root/other-root.zip"
expect_failure "$contract" verify-archive-shape "$test_root/other-root.zip"

printf '%s\n' tampered >>"$archive_path"
expect_failure "$contract" verify-checksum "$archive_path" "$archive_path.sha256"

beta_output="$test_root/beta-output"
beta_contract archive "$fixture_app" v1.4.0-beta.1 "$beta_output" >/dev/null
[[ -f "$beta_output/XDial-v1.4.0-beta.1.zip" \
    && -f "$beta_output/XDial-v1.4.0-beta.1.zip.sha256" ]] \
    || fail "beta archive is not named XDial-v1.4.0-beta.1.zip"
beta_contract verify-archive-shape "$beta_output/XDial-v1.4.0-beta.1.zip"
beta_contract verify-checksum "$beta_output/XDial-v1.4.0-beta.1.zip" \
    "$beta_output/XDial-v1.4.0-beta.1.zip.sha256"
expect_failure "$contract" archive "$fixture_app" v1.4.0-beta.1 "$beta_output"
expect_failure beta_contract archive "$fixture_app" v1.4.0 "$beta_output"

beta_notes="$test_root/BETA_RELEASE_NOTES.md"
printf '%s\n' '# XDial v1.4.0-beta.1' '' '## 更新了什么' '' '- 实验功能。' >"$beta_notes"
beta_contract validate-notes v1.4.0-beta.1 "$beta_notes"
expect_failure beta_contract validate-notes v1.4.0-beta.2 "$beta_notes"
expect_failure "$contract" validate-notes v1.4.0-beta.1 "$beta_notes"

# A beta tag sits on origin/xdial-beta's first-parent history, contains the
# newest stable tag and sorts above it.
beta_git_fixture="$test_root/beta-git-fixture"
mkdir -p "$beta_git_fixture"
(
    cd "$beta_git_fixture"
    git init -q -b main
    git config user.name 'XDial Test'
    git config user.email 'xdial-test@example.invalid'
    printf '%s\n' fixture >tracked.txt
    git add tracked.txt
    git commit -qm fixture
    git switch -qc xdial-beta
    printf '%s\n' experiment >experiment.txt
    git add experiment.txt
    git commit -qm experiment
    git tag v1.4.0-beta.1
    git update-ref refs/remotes/origin/xdial-beta HEAD
    expect_failure_with 'no stable vMAJOR.MINOR.PATCH tag' \
        beta_contract assert-git-tag v1.4.0-beta.1
    git tag v1.3.0 main
    beta_contract assert-git-tag v1.4.0-beta.1
    expect_failure "$contract" assert-git-tag v1.4.0-beta.1
    git tag v1.3.0-beta.9
    expect_failure_with 'must be newer than the latest stable tag v1.3.0' \
        beta_contract assert-git-tag v1.3.0-beta.9
    git tag -d v1.3.0-beta.9 >/dev/null
    git update-ref -d refs/remotes/origin/xdial-beta
    expect_failure_with 'fetch origin/xdial-beta' \
        beta_contract assert-git-tag v1.4.0-beta.1
    git update-ref refs/remotes/origin/main HEAD
    expect_failure beta_contract assert-git-tag v1.4.0-beta.1
    git update-ref -d refs/remotes/origin/main

    # A stable hotfix that xdial-beta has not merged yet.
    git switch -q main
    printf '%s\n' hotfix >hotfix.txt
    git add hotfix.txt
    git commit -qm hotfix
    git tag v1.3.1
    git switch -q xdial-beta
    printf '%s\n' more >>experiment.txt
    git commit -qam more
    git tag v1.4.0-beta.2
    git update-ref refs/remotes/origin/xdial-beta HEAD
    expect_failure_with 'must contain the latest stable tag v1.3.1' \
        beta_contract assert-git-tag v1.4.0-beta.2
    git merge --no-ff -qm 'merge main' main
    git tag v1.4.0-beta.3
    git update-ref refs/remotes/origin/xdial-beta HEAD
    beta_contract assert-git-tag v1.4.0-beta.3

    # A tag on a feature branch merged into xdial-beta is off its first parent.
    git switch -qc feature/experiment
    printf '%s\n' feature >feature.txt
    git add feature.txt
    git commit -qm feature
    git tag v1.4.0-beta.4
    git switch -q xdial-beta
    git merge --no-ff -qm 'merge feature' feature/experiment
    git update-ref refs/remotes/origin/xdial-beta HEAD
    git switch -q --detach v1.4.0-beta.4
    expect_failure_with "origin/xdial-beta's first-parent history" \
        beta_contract assert-git-tag v1.4.0-beta.4
)

# Offline, like the stable release-inputs fixture: origin is a local bare
# repository. Beta fetches xdial-beta and the v* tags, never main.
beta_source="$test_root/beta-source.git"
beta_work="$test_root/beta-work"
git init -q --bare "$beta_source"
git init -q -b main "$beta_work"
(
    cd "$beta_work"
    git config user.name 'XDial Test'
    git config user.email 'xdial-test@example.invalid'
    printf '%s\n' source >tracked.txt
    git add tracked.txt
    git commit -qm source
    git tag v2.3.4
    git remote add origin "$beta_source"
    git push -q origin main refs/tags/v2.3.4
    git switch -qc xdial-beta
    printf '%s\n' experiment >experiment.txt
    git add experiment.txt
    git commit -qm experiment
    git push -q origin xdial-beta
    git tag v2.4.0-beta.1
    git update-ref -d refs/remotes/origin/main
    git update-ref -d refs/remotes/origin/xdial-beta
    # The newest stable tag exists only on origin until release-inputs runs.
    git tag -d v2.3.4 >/dev/null
    beta_input_notes="$test_root/beta-input-notes.md"
    printf '%s\n' '# XDial v2.4.0-beta.1' '' '## 更新了什么' '' '- 门禁测试。' \
        >"$beta_input_notes"
    make -s --no-print-directory -f "$repository_root/Makefile" release-inputs \
        RELEASE_CONTRACT_SCRIPT="$contract" RELEASE_CHANNEL=beta \
        RELEASE_TAG=v2.4.0-beta.1 RELEASE_BUILD_NUMBER=240 \
        RELEASE_NOTES_FILE="$beta_input_notes"
    [[ "$(git rev-parse refs/remotes/origin/xdial-beta)" == "$(git rev-parse HEAD)" ]] \
        || fail "beta release-inputs did not refresh origin/xdial-beta"
    git rev-parse -q --verify refs/tags/v2.3.4 >/dev/null \
        || fail "beta release-inputs did not refresh the stable tags"
    if git rev-parse -q --verify refs/remotes/origin/main >/dev/null; then
        fail "beta release-inputs fetched main"
    fi
    beta_input_plan="$(make -n -s --no-print-directory -f "$repository_root/Makefile" \
        release-inputs RELEASE_CONTRACT_SCRIPT="$contract" RELEASE_CHANNEL=beta \
        RELEASE_TAG=v2.4.0-beta.1 RELEASE_BUILD_NUMBER=240)"
    grep -Fq 'validate-notes "v2.4.0-beta.1" "BETA_RELEASE_NOTES.md"' <<<"$beta_input_plan" \
        || fail "beta release-inputs does not default to BETA_RELEASE_NOTES.md"

    # Acceptance builds (PR-6) skip the xdial-beta gate, and publish refuses them.
    printf '%s\n' '# XDial v9.9.9-beta.1' '' '## 更新了什么' '' '- 验收包。' \
        >"$beta_input_notes"
    acceptance_output="$(make -s --no-print-directory -f "$repository_root/Makefile" \
        release-inputs RELEASE_CONTRACT_SCRIPT="$contract" RELEASE_CHANNEL=beta \
        RELEASE_TAG=v9.9.9-beta.1 RELEASE_BUILD_NUMBER=999 \
        RELEASE_NOTES_FILE="$beta_input_notes" RELEASE_UPDATE_ACCEPTANCE_ID=pages-fixture)"
    grep -Fq 'beta tag/xdial-beta gate is intentionally skipped' <<<"$acceptance_output" \
        || fail "beta acceptance build did not skip the branch gate"
    expect_failure_with 'an acceptance build cannot be published to beta' \
        make -s --no-print-directory -f "$repository_root/Makefile" publish \
        RELEASE_CHANNEL=beta RELEASE_TAG=v9.9.9-beta.1 \
        RELEASE_UPDATE_ACCEPTANCE_ID=pages-fixture
)

# Both release-app builds get the version from the contract and the tag as
# XDialReleaseTag; every contract call carries the channel.
for channel_tag in stable:v1.4.0 beta:v1.4.0-beta.1; do
    plan_channel="${channel_tag%%:*}"
    plan_tag="${channel_tag#*:}"
    release_app_plan="$(make -n --no-print-directory -C "$repository_root" release-app \
        BUILD_DIR="$test_root/release-app-plan" RELEASE_CHANNEL="$plan_channel" \
        RELEASE_TAG="$plan_tag" RELEASE_BUILD_NUMBER=98)"
    [[ "$(grep -c -F 'MARKETING_VERSION="1.4.0"' <<<"$release_app_plan")" == 2 ]] \
        || fail "$plan_channel release-app does not build version 1.4.0 twice"
    [[ "$(grep -c -F "XDIAL_RELEASE_TAG=\"$plan_tag\"" <<<"$release_app_plan")" == 2 ]] \
        || fail "$plan_channel release-app does not pass XDialReleaseTag to both builds"
    grep -Fq "XDIAL_RELEASE_CHANNEL=$plan_channel scripts/release-contract.sh verify-app" \
        <<<"$release_app_plan" || fail "$plan_channel verify-app does not carry the channel"
done

# publish hands the channel, and a confirmed beta follow-up, to the publisher.
publish_plan() {
    make -n -s --no-print-directory -C "$repository_root" publish "$@" \
        | tr -d '\\' | tr '\n\t' '  ' | tr -s ' '
}
grep -Fq 'scripts/publish-release.py --channel "beta" --pages "dispatch" "v2.4.0-beta.1"' \
    <<<"$(publish_plan RELEASE_CHANNEL=beta RELEASE_TAG=v2.4.0-beta.1)" \
    || fail "beta publish does not pass --channel beta"
grep -Fq 'scripts/publish-release.py --channel "stable" --pages "dispatch" "v2.3.5"' \
    <<<"$(publish_plan RELEASE_TAG=v2.3.5)" \
    || fail "stable publish changed"
grep -Fq 'scripts/publish-release.py --channel "stable" --pages "dispatch" --beta-followup "withdraw" "v2.3.5"' \
    <<<"$(publish_plan RELEASE_TAG=v2.3.5 RELEASE_BETA_FOLLOWUP=withdraw)" \
    || fail "publish does not pass RELEASE_BETA_FOLLOWUP"
# release.yml publishes with follow: the update repository deploys the feed itself.
grep -Fq 'scripts/publish-release.py --channel "beta" --pages "follow" --pages-timeout "120" "v2.4.0-beta.1"' \
    <<<"$(publish_plan RELEASE_CHANNEL=beta RELEASE_TAG=v2.4.0-beta.1 RELEASE_PAGES=follow RELEASE_PAGES_TIMEOUT=120)" \
    || fail "publish does not pass RELEASE_PAGES and RELEASE_PAGES_TIMEOUT"

# XDialReleaseTag is how clients recognize an installed beta: beta requires the
# exact tag, stable also accepts an empty key. Private configuration is
# refused only by beta here; official CI refuses it for both channels.
check_release_bundle() (
    XDIAL_RELEASE_CHANNEL="$1"
    source "$contract"
    assert_release_tag_key "$2" "$3" \
        "$3/Contents/Helpers/XDial Settings UI.app" \
        "$3/Contents/Library/SystemExtensions/com.kafeifei.xdial.app.transparent-proxy.systemextension"
    assert_private_configuration_absent "$3"
)

write_bundle_plist() {
    mkdir -p "$1/Contents"
    cat >"$1/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleShortVersionString</key><string>1.4.0</string>
$2
</dict></plist>
EOF
}

release_bundle() {
    local app="$test_root/release-bundle/$1/XDial.app"
    write_bundle_plist "$app" "$2"
    write_bundle_plist "$app/Contents/Helpers/XDial Settings UI.app" "${3:-}"
    write_bundle_plist "$app/Contents/Library/SystemExtensions/com.kafeifei.xdial.app.transparent-proxy.systemextension" "${3:-}"
    printf '%s\n' "$app"
}

beta_tag=v1.4.0-beta.1
tag_key() {
    printf '<key>XDialReleaseTag</key><string>%s</string>' "$1"
}
missing_key="$(release_bundle missing '')"
empty_key="$(release_bundle empty "$(tag_key '')")"
tagged="$(release_bundle tagged "$(tag_key "$beta_tag")")"
other_tag="$(release_bundle other "$(tag_key v1.4.0)")"
component_tag="$(release_bundle component "$(tag_key "$beta_tag")" "$(tag_key v1.3.0)")"
integer_key="$(release_bundle integer '<key>XDialReleaseTag</key><integer>1</integer>')"
for app in "$missing_key" "$empty_key"; do
    check_release_bundle stable "$beta_tag" "$app"
    expect_failure_with "XDialReleaseTag is '', expected '$beta_tag'" \
        check_release_bundle beta "$beta_tag" "$app"
done
check_release_bundle beta "$beta_tag" "$tagged"
check_release_bundle stable "$beta_tag" "$tagged"
check_release_bundle stable v1.4.0 "$other_tag"
for channel in stable beta; do
    expect_failure_with "XDialReleaseTag is 'v1.4.0'" \
        check_release_bundle "$channel" "$beta_tag" "$other_tag"
    expect_failure_with "XDialReleaseTag is 'v1.3.0'" \
        check_release_bundle "$channel" "$beta_tag" "$component_tag"
    expect_failure_with 'must be a string' \
        check_release_bundle "$channel" "$beta_tag" "$integer_key"
done

# A beta archive that embeds a first-launch Profile, or private presets.
private_root="$test_root/private-configuration"
mkdir -p "$private_root/source" "$private_root/seed" "$private_root/presets"
/usr/bin/ditto "$tagged" "$private_root/source/XDial.app"
mkdir -p "$private_root/source/XDial.app/Contents/Resources/SeedProfile"
printf '%s\n' '{}' >"$private_root/source/XDial.app/Contents/Resources/SeedProfile/Preset.json"
/usr/bin/ditto -c -k --keepParent "$private_root/source/XDial.app" "$private_root/seed.zip"
/usr/bin/ditto -x -k "$private_root/seed.zip" "$private_root/seed"
expect_failure_with 'beta releases must not embed private configuration' \
    check_release_bundle beta "$beta_tag" "$private_root/seed/XDial.app"
check_release_bundle stable "$beta_tag" "$private_root/seed/XDial.app"
/usr/bin/ditto "$tagged" "$private_root/presets/XDial.app"
mkdir -p "$private_root/presets/XDial.app/Contents/Resources"
printf '%s\n' '{}' >"$private_root/presets/XDial.app/Contents/Resources/RuleSetPresets.json"
expect_failure_with 'beta releases must not embed private configuration' \
    check_release_bundle beta "$beta_tag" "$private_root/presets/XDial.app"

# The same checks through verify-app's entry point. Checks that need a real
# build (deployment target, component names, and the distribution binaries
# where the contract has them) are stubbed. Every bundle's short version is
# wrong, so a bundle that passes both checks stops right after them, before
# the helper would run.
verify_release_app() (
    XDIAL_RELEASE_CHANNEL="$1"
    source "$contract"
    assert_app_deployment_target() { :; }
    assert_component_names() { :; }
    assert_distribution_binaries() { :; }
    verify_app "$3" "$2" 98
)

write_component_plist() {
    mkdir -p "$1/Contents"
    cat >"$1/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>$2</string>
<key>CFBundleShortVersionString</key><string>9.9.9</string>
$3
</dict></plist>
EOF
}

verify_app_bundle() {
    local app="$test_root/verify-app/$1/XDial.app"
    write_component_plist "$app" com.kafeifei.xdial.app \
        "<key>NSLocationUsageDescription</key><string>fixture</string>$2"
    write_component_plist "$app/Contents/Helpers/XDial Settings UI.app" \
        com.kafeifei.xdial.app.settings-ui ''
    write_component_plist \
        "$app/Contents/Library/SystemExtensions/com.kafeifei.xdial.app.transparent-proxy.systemextension" \
        com.kafeifei.xdial.app.transparent-proxy ''
    mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
    printf '%s\n' '#!/bin/sh' 'exit 1' >"$app/Contents/MacOS/xdial-daemon"
    chmod +x "$app/Contents/MacOS/xdial-daemon"
    if [[ -n "${3:-}" ]]; then
        mkdir -p "$(dirname "$app/Contents/Resources/$3")"
        printf '%s\n' '{}' >"$app/Contents/Resources/$3"
    fi
    printf '%s\n' "$app"
}

past_release_checks="CFBundleShortVersionString is '9.9.9'"
untagged_app="$(verify_app_bundle untagged '')"
expect_failure_with "XDialReleaseTag is '', expected '$beta_tag'" \
    verify_release_app beta "$beta_tag" "$untagged_app"
expect_failure_with "$past_release_checks" verify_release_app stable v1.4.0 "$untagged_app"
tagged_app="$(verify_app_bundle tagged "$(tag_key "$beta_tag")")"
expect_failure_with "$past_release_checks" verify_release_app beta "$beta_tag" "$tagged_app"
for private_name in SeedProfile/Preset.json RuleSetPresets.json; do
    private_app="$(verify_app_bundle "beta-${private_name%%/*}" \
        "$(tag_key "$beta_tag")" "$private_name")"
    expect_failure_with 'beta releases must not embed private configuration' \
        verify_release_app beta "$beta_tag" "$private_app"
    # Preset configuration packages share the stable contract and embed it.
    private_app="$(verify_app_bundle "stable-${private_name%%/*}" '' "$private_name")"
    expect_failure_with "$past_release_checks" \
        verify_release_app stable v1.4.0 "$private_app"
done

# Formats beta shares with stable change only through main. Every listed path
# exists here, and only what the beta side changed since its merge base with
# main counts.
shared_formats="$repository_root/scripts/check-beta-shared-formats.sh"
shared_paths="$("$shared_formats" --paths)"
while IFS= read -r shared_path; do
    [[ -n "$(git -C "$repository_root" ls-files -- "$shared_path")" ]] \
        || fail "shared format path is not tracked: $shared_path"
done <<<"$shared_paths"
for shared_path in go.mod go.sum third_party patches scripts/prepare-patched-go-mod.sh; do
    grep -Fxq "$shared_path" <<<"$shared_paths" \
        || fail "the shared format gate must cover $shared_path"
done
shared_fixture="$test_root/shared-formats"
mkdir -p "$shared_fixture/patches/tailscale"
(
    cd "$shared_fixture"
    git init -q -b main
    git config user.name 'XDial Test'
    git config user.email 'xdial-test@example.invalid'
    printf '%s\n' 'module fixture' >go.mod
    printf '%s\n' main >patches/tailscale/0001-fixture.patch
    git add go.mod patches
    git commit -qm main
    git update-ref refs/remotes/origin/main HEAD
    git switch -qc xdial-beta
    printf '%s\n' experiment >experiment.txt
    git add experiment.txt
    git commit -qm experiment
    "$shared_formats" >/dev/null
    # Main moving its own dependencies does not count against the beta.
    git switch -q main
    printf '%s\n' 'go 1.25' >>go.mod
    git commit -qam 'main dependency'
    git update-ref refs/remotes/origin/main HEAD
    git switch -q xdial-beta
    "$shared_formats" origin/main HEAD >/dev/null
    printf '%s\n' beta >patches/tailscale/0001-fixture.patch
    git commit -qam 'beta patch'
    expect_failure_with 'patches/tailscale/0001-fixture.patch' \
        "$shared_formats" origin/main HEAD
    expect_failure_with 'cannot resolve origin/missing' \
        "$shared_formats" origin/missing HEAD
)

echo "release contract tests passed"
