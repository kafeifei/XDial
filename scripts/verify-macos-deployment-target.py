#!/usr/bin/env python3
"""Verify that every executable in a macOS app honors its declared minimum OS."""

import json
import pathlib
import plistlib
import re
import stat
import subprocess
import sys


VERSION_PATTERN = re.compile(r"^(0|[1-9][0-9]*)(?:\.(0|[1-9][0-9]*))?(?:\.(0|[1-9][0-9]*))?$")


class DeploymentTargetError(ValueError):
    pass


def parse_version(value, label):
    match = VERSION_PATTERN.fullmatch(str(value))
    if not match:
        raise DeploymentTargetError(f"{label} has invalid version: {value}")
    return tuple(int(part or 0) for part in match.groups())


def read_plist(plist_path):
    try:
        return plistlib.loads(plist_path.read_bytes())
    except (OSError, plistlib.InvalidFileException) as error:
        raise DeploymentTargetError(f"cannot read {plist_path}: {error}") from error


def owning_bundle(executable, app_bundle):
    directory = executable.parent
    while directory == app_bundle or app_bundle in directory.parents:
        plist_path = directory / "Contents/Info.plist"
        if plist_path.is_file():
            return directory, plist_path
        directory = directory.parent
    raise DeploymentTargetError(f"executable has no owning bundle: {executable}")


def command_output(arguments, description):
    result = subprocess.run(
        arguments,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        detail = result.stderr.strip() or result.stdout.strip()
        raise DeploymentTargetError(f"cannot {description}: {detail}")
    return result.stdout


def macho_architectures(executable):
    output = command_output(
        ["/usr/bin/lipo", "-archs", str(executable)],
        f"read Mach-O architectures from {executable}",
    )
    architectures = output.split()
    if not architectures:
        raise DeploymentTargetError(f"Mach-O has no architectures: {executable}")
    return architectures


def slice_minimum_versions(executable, architecture):
    output = command_output(
        [
            "/usr/bin/vtool",
            "-arch",
            architecture,
            "-show-build",
            str(executable),
        ],
        f"read {architecture} Mach-O build version from {executable}",
    )

    minimums = []
    platform = None
    command = None
    for line in output.splitlines():
        fields = line.split()
        if len(fields) == 3 and fields[:2] == ["Load", "command"]:
            command = None
            platform = None
        elif len(fields) == 2 and fields[0] == "cmd":
            command = fields[1]
            if command.startswith("LC_VERSION_MIN_") and command != "LC_VERSION_MIN_MACOSX":
                raise DeploymentTargetError(
                    f"{executable} {architecture} slice targets non-macOS "
                    f"platform in {command}"
                )
        elif len(fields) == 2 and fields[0] == "platform":
            platform = fields[1]
            if command == "LC_BUILD_VERSION" and platform != "MACOS":
                raise DeploymentTargetError(
                    f"{executable} {architecture} slice targets {platform}, not macOS"
                )
        elif len(fields) == 2 and fields[0] == "minos" and platform == "MACOS":
            minimums.append(fields[1])
        elif (
            len(fields) == 2
            and fields[0] == "version"
            and command == "LC_VERSION_MIN_MACOSX"
        ):
            minimums.append(fields[1])
    if not minimums:
        raise DeploymentTargetError(
            f"missing macOS minimum version in {executable} {architecture} slice"
        )
    return minimums


def macho_minimum_versions(executable):
    return [
        {
            "architecture": architecture,
            "minimums": slice_minimum_versions(executable, architecture),
        }
        for architecture in macho_architectures(executable)
    ]


def executable_files(app_bundle):
    for candidate in app_bundle.rglob("*"):
        if candidate.is_symlink() or not candidate.is_file():
            continue
        if candidate.stat().st_mode & (stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH):
            yield candidate


def verify_app(app_bundle):
    app_bundle = app_bundle.resolve()
    if not app_bundle.is_dir() or app_bundle.suffix != ".app":
        raise DeploymentTargetError(f"not a macOS application bundle: {app_bundle}")

    root_plist_path = app_bundle / "Contents/Info.plist"
    root_plist = read_plist(root_plist_path)
    root_declared_text = root_plist.get("LSMinimumSystemVersion")
    root_declared = parse_version(
        root_declared_text,
        f"{root_plist_path} LSMinimumSystemVersion",
    )

    results = []
    for executable in sorted(executable_files(app_bundle)):
        bundle, plist_path = owning_bundle(executable, app_bundle)
        metadata = read_plist(plist_path)
        declared_text = metadata.get("LSMinimumSystemVersion")
        declared = parse_version(
            declared_text,
            f"{plist_path} LSMinimumSystemVersion",
        )
        if declared > root_declared:
            raise DeploymentTargetError(
                f"{bundle} declares macOS {declared_text}, newer than application "
                f"minimum {root_declared_text}"
            )

        slices = macho_minimum_versions(executable)
        for architecture_slice in slices:
            for minimum_text in architecture_slice["minimums"]:
                minimum = parse_version(
                    minimum_text,
                    f"{executable} {architecture_slice['architecture']} minimum",
                )
                if minimum > declared:
                    raise DeploymentTargetError(
                        f"{executable} {architecture_slice['architecture']} slice "
                        f"requires macOS {minimum_text}, newer than its bundle "
                        f"declaration {declared_text}"
                    )
                if minimum > root_declared:
                    raise DeploymentTargetError(
                        f"{executable} {architecture_slice['architecture']} slice "
                        f"requires macOS {minimum_text}, newer than application "
                        f"minimum {root_declared_text}"
                    )

        results.append(
            {
                "path": str(executable.relative_to(app_bundle)),
                "declared": str(declared_text),
                "machO": slices,
            }
        )

    if not results:
        raise DeploymentTargetError(f"application has no executable files: {app_bundle}")
    return {
        "bundle": str(app_bundle),
        "minimumSystemVersion": str(root_declared_text),
        "executables": results,
    }


def main():
    if len(sys.argv) != 2:
        raise DeploymentTargetError(
            "usage: verify-macos-deployment-target.py <application.app>"
        )
    print(json.dumps(verify_app(pathlib.Path(sys.argv[1])), sort_keys=True))


if __name__ == "__main__":
    try:
        main()
    except DeploymentTargetError as error:
        print(f"error: {error}", file=sys.stderr)
        sys.exit(1)
