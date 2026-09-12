#!/bin/bash
set -euo pipefail
repository_root="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$repository_root/build/menu-bar-fixtures"
fixture_root="$(mktemp -d "$repository_root/build/menu-bar-fixtures/run.XXXXXX")"
fixture_app="$fixture_root/Menu Recovery Fixture.app"
mkdir -p "$fixture_app/Contents/MacOS"
python3 - "$fixture_app/Contents/Info.plist" <<'PY'
import plistlib, sys, uuid
with open(sys.argv[1], 'wb') as stream:
    plistlib.dump({
        'CFBundleIdentifier': 'com.kafeifei.xdial.tests.menu-recovery.' + uuid.uuid4().hex,
        'CFBundleExecutable': 'MenuRecoveryFixture',
        'CFBundleName': 'Menu Recovery Fixture',
        'CFBundlePackageType': 'APPL',
        'LSUIElement': True,
        'LSMinimumSystemVersion': '15.0',
    }, stream)
PY
xcrun swiftc -parse-as-library \
    "$repository_root/macos/Shared/XDialBuildIdentity.swift" \
    "$repository_root/macos/Sources/XDial/MenuBarRecoveryPolicy.swift" \
    "$repository_root/macos/Sources/XDial/MenuBarTrackingRepair.swift" \
    "$repository_root/macos/Sources/XDial/MenuBarRecoveryController.swift" \
    "$repository_root/test/fixtures/MenuBarRecoveryFixture.swift" \
    -o "$fixture_app/Contents/MacOS/MenuRecoveryFixture"
/usr/bin/codesign --force --sign - "$fixture_app"
xcrun swiftc -O \
    "$repository_root/macos/Sources/XDial/ApplicationLaunchPolicy.swift" \
    "$repository_root/tools/launch-macos-app.swift" -o "$fixture_root/launch"
"$fixture_root/launch" "$fixture_app"
python3 - "$fixture_root/result.json" <<'PY'
import json, pathlib, sys, time
result = pathlib.Path(sys.argv[1])
deadline = time.monotonic() + 45
while time.monotonic() < deadline:
    if result.exists():
        report = json.loads(result.read_text())
        print(json.dumps(report, ensure_ascii=False, indent=2))
        print('Evidence:', result)
        sys.exit(0 if report.get('success') else 1)
    time.sleep(0.25)
raise SystemExit('Fixture did not finish; inspect ' + str(result.parent))
PY
