#!/usr/bin/env python3
"""Line coverage per module for the Swift package, with per-module thresholds.

    coverage.py clean  <package-path>
    coverage.py report <package-path> [Module=percent ...]

SwiftPM builds one bundle per test target and writes one raw profile per bundle, but its own export only
covers a single binary. `report` merges every raw profile and exports coverage across all test bundles.
"""

import glob
import json
import os
import re
import subprocess
import sys
from collections import defaultdict


def swift(package: str, *args: str) -> str:
    return subprocess.run(
        ["swift", *args, "--package-path", package], check=True, capture_output=True, text=True
    ).stdout.strip()


def codecov_dir(package: str) -> str:
    return os.path.dirname(swift(package, "test", "--show-codecov-path"))


def clean(package: str) -> int:
    for path in glob.glob(os.path.join(codecov_dir(package), "*.profraw")):
        os.remove(path)
    return 0


def report(package: str, threshold_args: list[str]) -> int:
    thresholds = {name: float(value) for name, value in (arg.split("=") for arg in threshold_args)}
    directory = codecov_dir(package)
    raw = glob.glob(os.path.join(directory, "*.profraw"))
    if not raw:
        print("No coverage data; run the tests with --enable-code-coverage first.", file=sys.stderr)
        return 1
    merged = os.path.join(directory, "merged.profdata")
    subprocess.run(["xcrun", "llvm-profdata", "merge", "-sparse", *raw, "-o", merged], check=True)

    bin_dir = swift(package, "build", "--show-bin-path")
    binaries = [
        os.path.join(bundle, "Contents", "MacOS", os.path.basename(bundle).removesuffix(".xctest"))
        for bundle in sorted(glob.glob(os.path.join(bin_dir, "*.xctest")))
    ]
    binaries = [binary for binary in binaries if os.path.exists(binary)]
    objects = [binaries[0]] + [arg for binary in binaries[1:] for arg in ("-object", binary)]
    exported = subprocess.run(
        ["xcrun", "llvm-cov", "export", "-summary-only", "-instr-profile", merged, *objects],
        check=True,
        capture_output=True,
        text=True,
    ).stdout

    totals: dict[str, list[int]] = defaultdict(lambda: [0, 0])
    for entry in json.loads(exported)["data"][0]["files"]:
        match = re.search(r"/Packages/AgenthesiaKit/Sources/([^/]+)/", entry["filename"])
        if not match:
            continue
        lines = entry["summary"]["lines"]
        totals[match.group(1)][0] += lines["covered"]
        totals[match.group(1)][1] += lines["count"]

    failures = []
    print(f"{'Module':<20} {'Lines':>13} {'Coverage':>9} {'Required':>9}")
    for module in sorted(totals):
        covered, count = totals[module]
        percent = 100.0 * covered / count if count else 100.0
        required = thresholds.get(module)
        status = ""
        if required is not None:
            status = f"{required:>8.1f}%"
            if percent < required:
                failures.append(module)
                status += "  FAIL"
        print(f"{module:<20} {covered:>6}/{count:<6} {percent:>8.1f}% {status}")

    missing = sorted(set(thresholds) - set(totals))
    for module in missing:
        print(f"{module:<20} no coverage data  FAIL")

    if failures or missing:
        print(f"\nCoverage below threshold: {', '.join(failures + missing)}", file=sys.stderr)
        return 1
    return 0


def main() -> int:
    command, package, *rest = sys.argv[1:]
    if command == "clean":
        return clean(package)
    if command == "report":
        return report(package, rest)
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())
