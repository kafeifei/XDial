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
    git init -q
    git config user.name 'XDial Test'
    git config user.email 'xdial-test@example.invalid'
    printf '%s\n' fixture >tracked.txt
    git add tracked.txt
    git commit -qm fixture
    git tag v1.2.3
    "$contract" assert-git-tag v1.2.3
    printf '%s\n' dirty >>tracked.txt
    expect_failure "$contract" assert-git-tag v1.2.3
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
