#!/bin/bash

set -euo pipefail

repository_root="$(cd "$(dirname "$0")/.." && pwd)"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/xdial-installation-launch.XXXXXX")"
registrar="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

cleanup() {
    # Only the randomly identified fixture bundles are registered or removed.
    for fixture in "$test_root"/*/Applications/LaunchFixture.app; do
        if [[ -d "$fixture" && -x "$registrar" ]]; then
            "$registrar" -u "$fixture" >/dev/null 2>&1 || true
        fi
    done
    rm -rf "$test_root"
}
trap cleanup EXIT

xcrun swiftc \
    "$repository_root/macos/Shared/ApplicationInstallationQuarantine.swift" \
    "$repository_root/macos/Shared/InstallationTransaction.swift" \
    "$repository_root/macos/Sources/XDial/ApplicationLaunchPolicy.swift" \
    "$repository_root/test/fixtures/InstallationLaunchFixture.swift" \
    -o "$test_root/installation-launch-test"

"$test_root/installation-launch-test" "$test_root"
