#!/usr/bin/env python3
"""Validate the signed, isolated macOS development bundle without launching it."""

import json
import pathlib
import plistlib
import subprocess
import sys


def run(*args):
    return subprocess.check_output(args, stderr=subprocess.PIPE)


def require(condition, message):
    if not condition:
        raise ValueError(message)


def plist(path):
    return plistlib.loads(path.read_bytes())


def main():
    bundle = pathlib.Path(sys.argv[1]).resolve()
    flavor = sys.argv[2] if len(sys.argv) > 2 else "debug"
    require(flavor in ("debug", "next"), "unknown development channel")
    product = "XDial Next" if flavor == "next" else "XDail Debug"
    prefix = "com.kafeifei.xdial." + flavor
    require(bundle.name == product + ".app", "unexpected development app filename")
    deployment_verifier = pathlib.Path(__file__).with_name(
        "verify-macos-deployment-target.py"
    )
    deployment_result = subprocess.run(
        [sys.executable, str(deployment_verifier), str(bundle)],
        capture_output=True,
        text=True,
    )
    require(
        deployment_result.returncode == 0,
        deployment_result.stderr.strip() or "invalid macOS deployment target",
    )
    run("/usr/bin/codesign", "--verify", "--deep", "--strict", str(bundle))
    group = "UVZM439VGU." + prefix + ".network"
    components = [
        (bundle, prefix, True),
        (bundle / "Contents/Helpers/XDial Settings UI.app",
         prefix + ".settings-ui", False),
        (bundle / f"Contents/Library/SystemExtensions/{prefix}.transparent-proxy.systemextension",
         prefix + ".transparent-proxy", True),
    ]
    host = plist(bundle / "Contents/Info.plist")
    require(host.get("CFBundleExecutable") == "XDial", "unexpected host executable")
    require(host.get("CFBundleDisplayName") == product, "unexpected development display name")
    require(host.get("XDialBuildFlavor") == flavor, "bundle is not a development build")
    require(host.get("XDialTransparentProxyBundleIdentifier") == components[2][1],
            "host points to another channel's extension")
    for path, identifier, has_group in components:
        metadata = plist(path / "Contents/Info.plist")
        require(metadata["CFBundleIdentifier"] == identifier, f"wrong identity: {path}")
        require(metadata["CFBundleVersion"] == host["CFBundleVersion"], f"mixed component build: {path}")
        signature = subprocess.run(
            ["/usr/bin/codesign", "-d", "--verbose=4", str(path)],
            check=True, capture_output=True, text=True,
        ).stderr
        require("Authority=Apple Development:" in signature, f"wrong signing class: {path}")
        require("TeamIdentifier=UVZM439VGU" in signature, f"wrong signing team: {path}")
        if has_group:
            entitlements = plistlib.loads(run("/usr/bin/codesign", "-d", "--entitlements", ":-", str(path)))
            require(entitlements.get("com.apple.security.application-groups") == [group],
                    f"wrong shared data group: {path}")
            profile = plistlib.loads(run("/usr/bin/security", "cms", "-D", "-i",
                                        str(path / "Contents/embedded.provisionprofile")))
            require(profile["Entitlements"]["com.apple.application-identifier"] == "UVZM439VGU." + identifier,
                    f"profile does not authorize development identity: {path}")
            require(bool(profile.get("ProvisionedDevices")), f"missing development devices: {path}")
    helper = bundle / "Contents/MacOS/xdial-daemon"
    helper_signature = subprocess.run(
        ["/usr/bin/codesign", "-d", "--verbose=4", str(helper)],
        check=True, capture_output=True, text=True,
    ).stderr
    require(f"Identifier={prefix}.helper\n" in helper_signature,
            "helper uses another channel's signing identity")
    require("Authority=Apple Development:" in helper_signature, "helper is not development signed")
    helper_entitlements = plistlib.loads(run("/usr/bin/codesign", "-d", "--entitlements", ":-", str(helper)))
    require(helper_entitlements.get("com.apple.security.application-groups") == [group],
            "helper uses another channel's data group")
    build_info = run("go", "version", "-m", str(helper)).decode()
    require(f"main.buildFlavor={flavor}" in build_info, "helper was compiled for the wrong channel")
    daemon_directory = bundle / "Contents/Library/LaunchDaemons"
    require(sorted(p.name for p in daemon_directory.iterdir()) == [prefix + ".daemon.plist"],
            "bundle contains unexpected launch daemons")
    daemon = plist(daemon_directory / (prefix + ".daemon.plist"))
    require(daemon["Label"] == prefix + ".daemon", "wrong daemon label")
    require(daemon["AssociatedBundleIdentifiers"] == [prefix], "wrong daemon owner")
    require(daemon["ProgramArguments"] == ["xdial-daemon", "daemon", "--socket", f"/tmp/xdial-{flavor}.sock"],
            "wrong daemon socket or arguments")
    require(daemon["StandardOutPath"] == daemon["StandardErrorPath"] == f"/tmp/xdial-{flavor}.log",
            "wrong daemon logs")
    print(json.dumps({"bundle": str(bundle), "version": host["CFBundleShortVersionString"],
                      "build": host["CFBundleVersion"], "identity": host["CFBundleIdentifier"],
                      "signing": "Apple Development", "developmentIsolation": "verified"}))


if __name__ == "__main__":
    try:
        main()
    except (ValueError, KeyError, OSError, subprocess.CalledProcessError) as error:
        print(f"error: {error}", file=sys.stderr)
        sys.exit(1)
