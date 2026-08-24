#!/bin/bash

set -euo pipefail

readonly PRODUCT_NAME="XDial"
readonly RELEASE_APPLICATION_IDENTIFIER="com.kafeifei.xdial.app"
readonly RELEASE_SETTINGS_IDENTIFIER="com.kafeifei.xdial.app.settings-ui"
readonly RELEASE_EXTENSION_IDENTIFIER="com.kafeifei.xdial.app.transparent-proxy"
readonly RELEASE_HELPER_IDENTIFIER="com.kafeifei.xdial.app.helper"
readonly RELEASE_TEAM_IDENTIFIER="UVZM439VGU"

cleanup_root=""
cleanup() {
    if [[ -n "${cleanup_root:-}" && -d "$cleanup_root" ]]; then
        rm -rf "$cleanup_root"
    fi
}
trap cleanup EXIT

fail() {
    echo "error: $*" >&2
    exit 1
}

usage() {
    cat >&2 <<'EOF'
Usage:
  release-contract.sh validate-inputs <vMAJOR.MINOR.PATCH> <build-number>
  release-contract.sh validate-notes <tag> <release-notes.md>
  release-contract.sh assert-git-tag <tag>
  release-contract.sh verify-app <XDial.app> <tag> <build-number> [--notarized]
  release-contract.sh notarize <XDial.app> <tag> <build-number> <log-path>
  release-contract.sh archive <XDial.app> <tag> <output-directory>
  release-contract.sh verify-archive-shape <archive.zip>
  release-contract.sh verify-checksum <archive.zip> <archive.zip.sha256>
  release-contract.sh verify-archive <archive.zip> <tag> <build-number>
EOF
    exit 2
}

version_from_tag() {
    local tag="$1"
    if [[ ! "$tag" =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
        fail "release tag must be exact stable SemVer vMAJOR.MINOR.PATCH: $tag"
    fi
    printf '%s\n' "${tag#v}"
}

validate_inputs() {
    local tag="$1"
    local build_number="$2"
    version_from_tag "$tag" >/dev/null
    if [[ ! "$build_number" =~ ^[1-9][0-9]*$ ]]; then
        fail "release build number must be a positive integer: $build_number"
    fi
}

validate_notes() {
    local tag="$1"
    local notes_path="$2"
    validate_inputs "$tag" 1
    [[ -f "$notes_path" ]] || fail "release notes do not exist: $notes_path"
    grep -Fqx "# XDial $tag" "$notes_path" \
        || fail "release notes must contain the exact heading '# XDial $tag'"
    awk '
        /^## 更新了什么[[:space:]]*$/ { in_updates = 1; next }
        in_updates && /^## / { exit }
        in_updates && NF { found = 1; exit }
        END { exit !found }
    ' "$notes_path" \
        || fail "release notes must contain non-empty '## 更新了什么' content"
}

assert_git_tag() {
    local tag="$1"
    validate_inputs "$tag" 1
    git rev-parse --is-inside-work-tree >/dev/null 2>&1 \
        || fail "release must run inside a Git worktree"

    local head tagged_commit
    head="$(git rev-parse HEAD)"
    tagged_commit="$(git rev-parse -q --verify "refs/tags/$tag^{commit}" 2>/dev/null || true)"
    [[ -n "$tagged_commit" ]] || fail "release tag does not exist locally: $tag"
    [[ "$tagged_commit" == "$head" ]] \
        || fail "release tag $tag does not point at HEAD"
    [[ -z "$(git status --porcelain)" ]] \
        || fail "release worktree must be clean"
}

plist_value() {
    local plist="$1"
    local key="$2"
    /usr/libexec/PlistBuddy -c "Print :$key" "$plist" 2>/dev/null \
        || fail "missing $key in $plist"
}

assert_plist_value() {
    local plist="$1"
    local key="$2"
    local expected="$3"
    local actual
    [[ -f "$plist" ]] || fail "missing Info.plist: $plist"
    actual="$(plist_value "$plist" "$key")"
    [[ "$actual" == "$expected" ]] \
        || fail "$plist $key is '$actual', expected '$expected'"
}

assert_developer_id_signature() {
    local path="$1"
    local expected_identifier="$2"
    local details

    /usr/bin/codesign --verify --strict --verbose=2 "$path"
    details="$(/usr/bin/codesign -dvvv "$path" 2>&1)"
    grep -Fqx "Identifier=$expected_identifier" <<<"$details" \
        || fail "$path has the wrong signing identifier"
    grep -Fq 'Authority=Developer ID Application:' <<<"$details" \
        || fail "$path is not signed with Developer ID Application"
    grep -Fqx "TeamIdentifier=$RELEASE_TEAM_IDENTIFIER" <<<"$details" \
        || fail "$path has the wrong signing team"
}

assert_get_task_allow_absent() {
    local path="$1"
    local entitlements
    entitlements="$(/usr/bin/codesign -d --entitlements :- "$path" 2>/dev/null || true)"
    if printf '%s' "$entitlements" \
        | /usr/bin/plutil -extract com.apple.security.get-task-allow raw -o - - \
            2>/dev/null \
        | grep -qx true; then
        fail "$path contains the forbidden get-task-allow entitlement"
    fi
}

verify_app() {
    local app_path="$1"
    local tag="$2"
    local build_number="$3"
    local notarized="${4:-}"
    local version

    validate_inputs "$tag" "$build_number"
    version="$(version_from_tag "$tag")"

    [[ -d "$app_path" && ! -L "$app_path" ]] \
        || fail "release application must be a real directory: $app_path"

    local settings_path="$app_path/Contents/Helpers/XDial Settings UI.app"
    local extension_path="$app_path/Contents/Library/SystemExtensions/$RELEASE_EXTENSION_IDENTIFIER.systemextension"
    local helper_path="$app_path/Contents/MacOS/xdial-daemon"

    [[ -d "$settings_path" && ! -L "$settings_path" ]] \
        || fail "missing settings carrier: $settings_path"
    [[ -d "$extension_path" && ! -L "$extension_path" ]] \
        || fail "missing System Extension: $extension_path"
    [[ -x "$helper_path" && ! -L "$helper_path" ]] \
        || fail "missing bundled helper: $helper_path"

    assert_plist_value "$app_path/Contents/Info.plist" CFBundleIdentifier \
        "$RELEASE_APPLICATION_IDENTIFIER"
    assert_plist_value "$settings_path/Contents/Info.plist" CFBundleIdentifier \
        "$RELEASE_SETTINGS_IDENTIFIER"
    assert_plist_value "$extension_path/Contents/Info.plist" CFBundleIdentifier \
        "$RELEASE_EXTENSION_IDENTIFIER"

    local bundle
    for bundle in "$app_path" "$settings_path" "$extension_path"; do
        assert_plist_value "$bundle/Contents/Info.plist" \
            CFBundleShortVersionString "$version"
        assert_plist_value "$bundle/Contents/Info.plist" \
            CFBundleVersion "$build_number"
    done

    [[ "$("$helper_path" version)" == "xdial $tag" ]] \
        || fail "bundled helper version does not match $tag"

    assert_developer_id_signature "$helper_path" "$RELEASE_HELPER_IDENTIFIER"
    assert_developer_id_signature "$settings_path" "$RELEASE_SETTINGS_IDENTIFIER"
    assert_developer_id_signature "$extension_path" "$RELEASE_EXTENSION_IDENTIFIER"
    assert_developer_id_signature "$app_path" "$RELEASE_APPLICATION_IDENTIFIER"
    assert_get_task_allow_absent "$app_path"
    assert_get_task_allow_absent "$extension_path"
    /usr/bin/codesign --verify --deep --strict --verbose=2 "$app_path"

    if [[ "$notarized" == "--notarized" ]]; then
        /usr/bin/xcrun stapler validate "$app_path"
        /usr/sbin/spctl --assess --type execute --verbose=4 "$app_path"
    elif [[ -n "$notarized" ]]; then
        fail "unknown verify-app option: $notarized"
    fi
}

notary_auth_args() {
    NOTARY_AUTH_ARGS=()
    if [[ -n "${NOTARY_KEYCHAIN_PROFILE:-}" ]]; then
        NOTARY_AUTH_ARGS=(--keychain-profile "$NOTARY_KEYCHAIN_PROFILE")
        if [[ -n "${NOTARY_KEYCHAIN:-}" ]]; then
            NOTARY_AUTH_ARGS+=(--keychain "$NOTARY_KEYCHAIN")
        fi
        return
    fi

    if [[ -n "${NOTARY_KEY:-}" && -n "${NOTARY_KEY_ID:-}" \
        && -n "${NOTARY_ISSUER:-}" ]]; then
        [[ -f "$NOTARY_KEY" ]] || fail "NOTARY_KEY does not exist: $NOTARY_KEY"
        NOTARY_AUTH_ARGS=(
            --key "$NOTARY_KEY"
            --key-id "$NOTARY_KEY_ID"
            --issuer "$NOTARY_ISSUER"
        )
        return
    fi

    fail "configure NOTARY_KEYCHAIN_PROFILE, or NOTARY_KEY + NOTARY_KEY_ID + NOTARY_ISSUER"
}

notarize_app() {
    local app_path="$1"
    local tag="$2"
    local build_number="$3"
    local log_path="$4"
    local temp_root result_path submission_path submission_id status

    verify_app "$app_path" "$tag" "$build_number"
    notary_auth_args
    temp_root="$(mktemp -d "${TMPDIR:-/tmp}/xdial-notary.XXXXXX")"
    cleanup_root="$temp_root"
    submission_path="$temp_root/$PRODUCT_NAME-$tag.zip"
    result_path="$temp_root/notary-result.json"

    /usr/bin/ditto -c -k --keepParent "$app_path" "$submission_path"
    /usr/bin/xcrun notarytool submit \
        --wait --output-format json \
        "${NOTARY_AUTH_ARGS[@]}" \
        "$submission_path" >"$result_path"

    submission_id="$(/usr/bin/plutil -extract id raw -o - "$result_path")"
    status="$(/usr/bin/plutil -extract status raw -o - "$result_path")"
    [[ "$status" == "Accepted" ]] \
        || fail "Apple notarization did not accept the application: $status"

    mkdir -p "$(dirname "$log_path")"
    /usr/bin/xcrun notarytool log \
        "${NOTARY_AUTH_ARGS[@]}" \
        "$submission_id" "$log_path"
    if grep -Eq '"severity"[[:space:]]*:[[:space:]]*"(warning|error)"' "$log_path"; then
        fail "Apple notarization log contains warnings or errors: $log_path"
    fi

    /usr/bin/xcrun stapler staple "$app_path"
    verify_app "$app_path" "$tag" "$build_number" --notarized
    cleanup
    cleanup_root=""
}

archive_app() {
    local app_path="$1"
    local tag="$2"
    local output_directory="$3"
    local archive_name archive_path

    validate_inputs "$tag" 1
    [[ -d "$app_path" && ! -L "$app_path" ]] \
        || fail "archive source must be a real application directory: $app_path"
    [[ "$(basename "$app_path")" == "$PRODUCT_NAME.app" ]] \
        || fail "archive source must be named $PRODUCT_NAME.app"

    archive_name="$PRODUCT_NAME-$tag.zip"
    archive_path="$output_directory/$archive_name"
    mkdir -p "$output_directory"
    rm -f "$archive_path" "$archive_path.sha256"
    /usr/bin/ditto -c -k --keepParent "$app_path" "$archive_path"
    (
        cd "$output_directory"
        /usr/bin/shasum -a 256 "$archive_name" >"$archive_name.sha256"
    )
    printf '%s\n' "$archive_path"
}

verify_archive_shape() {
    local archive_path="$1"
    local temp_root top_count
    [[ -f "$archive_path" && ! -L "$archive_path" ]] \
        || fail "release archive does not exist: $archive_path"

    temp_root="$(mktemp -d "${TMPDIR:-/tmp}/xdial-archive.XXXXXX")"
    cleanup_root="$temp_root"
    /usr/bin/ditto -x -k "$archive_path" "$temp_root"
    top_count="$(find "$temp_root" -mindepth 1 -maxdepth 1 -print \
        | wc -l | tr -d '[:space:]')"
    [[ "$top_count" == "1" ]] \
        || fail "release archive must contain exactly one top-level entry"
    [[ -d "$temp_root/$PRODUCT_NAME.app" && ! -L "$temp_root/$PRODUCT_NAME.app" ]] \
        || fail "release archive must contain exactly one real $PRODUCT_NAME.app root"
    cleanup
    cleanup_root=""
}

verify_checksum() {
    local archive_path="$1"
    local checksum_path="$2"
    [[ -f "$archive_path" && -f "$checksum_path" ]] \
        || fail "archive and checksum must both exist"
    [[ "$(basename "$checksum_path")" == "$(basename "$archive_path").sha256" ]] \
        || fail "checksum filename must be <archive>.sha256"
    (
        cd "$(dirname "$archive_path")"
        /usr/bin/shasum -a 256 -c "$(basename "$checksum_path")"
    )
}

verify_archive() {
    local archive_path="$1"
    local tag="$2"
    local build_number="$3"
    local expected_name temp_root

    validate_inputs "$tag" "$build_number"
    expected_name="$PRODUCT_NAME-$tag.zip"
    [[ "$(basename "$archive_path")" == "$expected_name" ]] \
        || fail "release archive must be named $expected_name"
    verify_checksum "$archive_path" "$archive_path.sha256"
    verify_archive_shape "$archive_path"

    temp_root="$(mktemp -d "${TMPDIR:-/tmp}/xdial-roundtrip.XXXXXX")"
    cleanup_root="$temp_root"
    /usr/bin/ditto -x -k "$archive_path" "$temp_root"
    verify_app "$temp_root/$PRODUCT_NAME.app" "$tag" "$build_number" --notarized
    cleanup
    cleanup_root=""
}

[[ $# -ge 1 ]] || usage
command="$1"
shift

case "$command" in
    validate-inputs)
        [[ $# -eq 2 ]] || usage
        validate_inputs "$1" "$2"
        ;;
    validate-notes)
        [[ $# -eq 2 ]] || usage
        validate_notes "$1" "$2"
        ;;
    assert-git-tag)
        [[ $# -eq 1 ]] || usage
        assert_git_tag "$1"
        ;;
    verify-app)
        [[ $# -ge 3 && $# -le 4 ]] || usage
        verify_app "$@"
        ;;
    notarize)
        [[ $# -eq 4 ]] || usage
        notarize_app "$1" "$2" "$3" "$4"
        ;;
    archive)
        [[ $# -eq 3 ]] || usage
        archive_app "$1" "$2" "$3"
        ;;
    verify-archive-shape)
        [[ $# -eq 1 ]] || usage
        verify_archive_shape "$1"
        ;;
    verify-checksum)
        [[ $# -eq 2 ]] || usage
        verify_checksum "$1" "$2"
        ;;
    verify-archive)
        [[ $# -eq 3 ]] || usage
        verify_archive "$1" "$2" "$3"
        ;;
    *)
        usage
        ;;
esac
