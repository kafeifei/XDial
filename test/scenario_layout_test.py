#!/usr/bin/env python3
"""Bounded, offscreen checks of the production Scenario views with synthetic data."""

import argparse
from pathlib import Path
import plistlib
import subprocess
import time


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("bundle", type=Path)
    arguments = parser.parse_args()
    bundle = arguments.bundle.resolve()
    info = plistlib.loads((bundle / "Contents/Info.plist").read_bytes())
    if info.get("XDialBuildConfiguration") not in ("Debug", "Next"):
        parser.error("requires a development bundle; release apps must not be launched by this check")
    executable = bundle / "Contents/MacOS/XDial"
    code = bundle / "Contents/MacOS/XDial.debug.dylib"
    if b"--check-scenario-layout" not in (code if code.exists() else executable).read_bytes():
        parser.error("this development bundle does not support the isolated layout entrypoint")
    for count in (6, 100):
        started = time.monotonic()
        # This entrypoint precedes relocation and normal AppState initialization.
        # subprocess.run kills only the isolated child if layout fails to settle.
        result = subprocess.run(
            [str(executable), "--check-scenario-layout", "--binding-count", str(count)],
            capture_output=True, text=True, timeout=30,
        )
        if result.returncode or "Scenario layout check passed" not in result.stdout:
            raise RuntimeError(f"Scenario layout failed for {count} bindings:\n{result.stdout}\n{result.stderr}")
        print(f"Scenario layout: {count} bindings, expand/scroll/resize/update passed in {time.monotonic() - started:.2f}s")


if __name__ == "__main__":
    main()
