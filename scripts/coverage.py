#!/usr/bin/env python3
"""Prints line coverage per module from `swift test --enable-code-coverage` and enforces thresholds.

Usage: coverage.py <codecov.json> [Module=percent ...]
"""

import json
import re
import sys
from collections import defaultdict


def main() -> int:
    path, *threshold_args = sys.argv[1:]
    thresholds = {name: float(value) for name, value in (arg.split("=") for arg in threshold_args)}

    with open(path) as file:
        report = json.load(file)

    totals: dict[str, list[int]] = defaultdict(lambda: [0, 0])
    for entry in report["data"][0]["files"]:
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


if __name__ == "__main__":
    sys.exit(main())
