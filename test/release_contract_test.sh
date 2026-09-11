#!/bin/bash

set -euo pipefail

repository_root="$(cd "$(dirname "$0")/.." && pwd)"
contract="$repository_root/scripts/release-contract.sh"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/xdial-release-test.XXXXXX")"
trap 'rm -rf "$test_root"' EXIT

fail() {
    echo "release contract test failed: $*" >&2
    exit 1
}

expect_failure() {
    if "$@" >/dev/null 2>&1; then
        fail "command unexpectedly succeeded: $*"
    fi
}

"$contract" validate-inputs v0.7.0 98
"$contract" validate-inputs v12.34.56 1787300000
expect_failure "$contract" validate-inputs 0.7.0 98
expect_failure "$contract" validate-inputs v0.7 98
expect_failure "$contract" validate-inputs v01.7.0 98
expect_failure "$contract" validate-inputs v0.7.0-rc.1 98
expect_failure "$contract" validate-inputs v0.7.0 0
expect_failure "$contract" validate-inputs v0.7.0 build-98

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
    # stable tag. They alone may bypass the stable tag/main check.
    git tag -d v2.3.4 >/dev/null
    printf '%s\n' '# XDial v9.9.9' '' '## 更新了什么' '' '- 验收包。' \
        >"$release_notes"
    make -s --no-print-directory -f "$repository_root/Makefile" release-inputs \
        RELEASE_CONTRACT="$contract" RELEASE_TAG=v9.9.9 RELEASE_BUILD_NUMBER=999 \
        RELEASE_NOTES_FILE="$release_notes" \
        RELEASE_UPDATE_ACCEPTANCE_ID=pages-fixture
    expect_failure make -s --no-print-directory -f "$repository_root/Makefile" \
        publish RELEASE_TAG=v9.9.9 RELEASE_UPDATE_ACCEPTANCE_ID=pages-fixture
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

printf '%s\n' tampered >>"$archive_path"
expect_failure "$contract" verify-checksum "$archive_path" "$archive_path.sha256"

echo "release contract tests passed"
