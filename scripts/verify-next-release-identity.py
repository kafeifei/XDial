#!/usr/bin/env python3
"""Reject development binaries, mixed channels and private payloads in Next releases."""

import pathlib
import plistlib
import subprocess
import sys


def run(*args):
    return subprocess.check_output(args, stderr=subprocess.PIPE)


def require(condition, message):
    if not condition:
        raise ValueError(message)


def verify(bundle, tag):
    prefix = "com.kafeifei.xdial.next"
    group = "UVZM439VGU." + prefix + ".network"
    host = plistlib.loads((bundle / "Contents/Info.plist").read_bytes())
    require(bundle.name == "XDial Next.app", "Next release has the wrong bundle filename")
    require(host.get("CFBundleDisplayName") == "XDial Next", "wrong Next display name")
    require(host.get("XDialBuildFlavor") == "next", "wrong Next build flavor")
    require(host.get("XDialBuildConfiguration") == "NextRelease", "Next requires a distribution build")
    revision = run("git", "rev-parse", f"refs/tags/{tag}^{{commit}}").decode().strip()
    require(host.get("XDialSourceRevision") == revision, "Next archive and source tag differ")
    require(not host.get("XDialUpdateAcceptanceID"), "acceptance builds cannot be published")
    require(host.get("XDialTransparentProxyBundleIdentifier") == prefix + ".transparent-proxy",
            "host points to another channel's extension")
    require(host.get("LSUIElement") is True, "host must be a menu bar application")
    carrier = bundle / "Contents/Helpers/XDial Settings UI.app"
    carrier_info = plistlib.loads((carrier / "Contents/Info.plist").read_bytes())
    require(carrier_info.get("LSUIElement") is False, "settings carrier must own its Dock window")
    require(carrier_info.get("CFBundleDisplayName") == "XDial Next", "wrong settings display name")
    extension = bundle / f"Contents/Library/SystemExtensions/{prefix}.transparent-proxy.systemextension"
    helper = bundle / "Contents/MacOS/xdial-daemon"
    for component in (bundle, extension, helper):
        entitlements = plistlib.loads(run("codesign", "-d", "--entitlements", ":-", str(component)))
        require(entitlements.get("com.apple.security.application-groups") == [group],
                f"mixed application group: {component.name}")
    for component in (bundle, carrier, extension, helper):
        signature = subprocess.run(["codesign", "-dvvv", str(component)],
                                   capture_output=True, text=True, check=True).stderr
        require("runtime" in signature and "Timestamp=" in signature,
                f"missing hardened runtime or secure timestamp: {component.name}")
        data = run("codesign", "-d", "--entitlements", ":-", str(component))
        require(not data or not plistlib.loads(data).get("com.apple.security.get-task-allow"),
                f"debugging entitlement in distribution component: {component.name}")
    build = run("go", "version", "-m", str(helper)).decode()
    require("main.buildFlavor=next" in build, "helper was compiled for another channel")
    require(f"vcs.revision={revision}" in build and "vcs.modified=false" in build,
            "helper is not from the clean release commit")
    host_strings = run("strings", str(bundle / "Contents/MacOS/XDial"))
    require(b"DebugServer:" not in host_strings, "Next distribution contains DebugServer")
    require(not (bundle / "Contents/Resources/RuleSetPresets.json").exists(),
            "Next distribution contains private RuleSet presets")
    daemon_dir = bundle / "Contents/Library/LaunchDaemons"
    require(sorted(p.name for p in daemon_dir.iterdir()) == [prefix + ".daemon.plist"],
            "Next distribution contains another channel's daemon")
    daemon = plistlib.loads((daemon_dir / (prefix + ".daemon.plist")).read_bytes())
    require(daemon.get("Label") == prefix + ".daemon", "wrong daemon label")
    require(daemon.get("Program") == "/Applications/XDial Next.app/Contents/MacOS/xdial-daemon"
            and "BundleProgram" not in daemon, "daemon must launch from the canonical installed path")
    require(daemon.get("AssociatedBundleIdentifiers") == [prefix], "wrong daemon owner")
    require(daemon.get("ProgramArguments") == ["xdial-daemon", "daemon", "--socket", "/tmp/xdial-next.sock"],
            "wrong daemon arguments")
    print("Next distribution identity and source revision verified")


if __name__ == "__main__":
    try:
        verify(pathlib.Path(sys.argv[1]).resolve(), sys.argv[2])
    except (ValueError, KeyError, OSError, subprocess.CalledProcessError) as error:
        print(f"error: {error}", file=sys.stderr)
        sys.exit(1)
