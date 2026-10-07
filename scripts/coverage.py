#!/usr/bin/env python3
"""Line coverage per module for the Swift package, with per-module thresholds.

    coverage.py clean  <package-path>
    coverage.py test   <package-path>
    coverage.py report <package-path> [Module=percent ...] [--badge <file.svg>]

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


# Executables that tests launch as child processes; their profiles land next to the test runner's.
EXECUTABLES = ["acp-cli", "MockAgent"]

# Test support and debug lab scopes: reported, but not part of the product total.
NON_PRODUCT = {"ACPTesting", "MockAgent", "RenderingLab"}

# Badge colors by minimum percentage, as on shields.io.
BADGE_COLORS = [(90, "#4c1"), (80, "#97ca00"), (70, "#a4a61d"), (60, "#dfb317"), (50, "#fe7d37"), (0, "#e05d44")]


def badge(percent: float) -> str:
    """A flat SVG badge in the shields.io style."""
    label, value = "coverage", f"{percent:.1f}%"
    color = next(color for minimum, color in BADGE_COLORS if percent >= minimum)
    label_width, value_width = 61, 7 * len(value) + 10
    width = label_width + value_width
    return f"""<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="20" role="img" aria-label="{label}: {value}">
<title>{label}: {value}</title>
<linearGradient id="s" x2="0" y2="100%"><stop offset="0" stop-color="#bbb" stop-opacity=".1"/><stop offset="1" stop-opacity=".1"/></linearGradient>
<clipPath id="r"><rect width="{width}" height="20" rx="3" fill="#fff"/></clipPath>
<g clip-path="url(#r)"><rect width="{label_width}" height="20" fill="#555"/><rect x="{label_width}" width="{value_width}" height="20" fill="{color}"/><rect width="{width}" height="20" fill="url(#s)"/></g>
<g fill="#fff" text-anchor="middle" font-family="Verdana,Geneva,DejaVu Sans,sans-serif" font-size="11">
<text x="{label_width / 2}" y="15" fill="#010101" fill-opacity=".3">{label}</text><text x="{label_width / 2}" y="14">{label}</text>
<text x="{label_width + value_width / 2}" y="15" fill="#010101" fill-opacity=".3">{value}</text><text x="{label_width + value_width / 2}" y="14">{value}</text>
</g>
</svg>
"""


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


def test(package: str) -> int:
    """Runs the tests with coverage instrumentation.

    Not `swift test --enable-code-coverage`: after the tests SwiftPM exports coverage of every binary itself,
    which takes over 4 GB of memory with the tree-sitter grammars and then fails with no details. `report`
    exports what it needs, so instrumentation is enabled by hand and SwiftPM never exports. Only Swift code is
    instrumented: the report covers Swift modules only.
    """
    directory = codecov_dir(package)
    os.makedirs(directory, exist_ok=True)
    env = dict(os.environ, LLVM_PROFILE_FILE=os.path.join(directory, "%p.profraw"))
    command = ["swift", "test", "--package-path", package]
    command += ["-Xswiftc", "-profile-generate", "-Xswiftc", "-profile-coverage-mapping"]
    return subprocess.run(command, env=env).returncode


def report(package: str, args: list[str]) -> int:
    badge_path = None
    if "--badge" in args:
        index = args.index("--badge")
        badge_path = args[index + 1]
        args = args[:index] + args[index + 2 :]
    thresholds = {name: float(value) for name, value in (arg.split("=") for arg in args)}
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
    binaries += [os.path.join(bin_dir, name) for name in EXECUTABLES]
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
        module = match.group(1)
        if module == "AgenthesiaUI" and entry["filename"][match.end():].startswith("Lab/"):
            module = "RenderingLab"
        lines = entry["summary"]["lines"]
        totals[module][0] += lines["covered"]
        totals[module][1] += lines["count"]

    failures = []
    print(f"{'Scope':<20} {'Lines':>13} {'Coverage':>9} {'Required':>9}")
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

    product = [totals[module] for module in totals if module not in NON_PRODUCT]
    covered, count = sum(c for c, _ in product), sum(n for _, n in product)
    total = 100.0 * covered / count if count else 100.0
    print(f"{'Product total':<20} {covered:>6}/{count:<6} {total:>8.1f}%")
    if badge_path:
        os.makedirs(os.path.dirname(os.path.abspath(badge_path)), exist_ok=True)
        with open(badge_path, "w") as file:
            file.write(badge(total))

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
    if command == "test":
        return test(package)
    if command == "report":
        return report(package, rest)
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())
