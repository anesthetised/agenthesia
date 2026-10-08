#!/usr/bin/env python3
"""Run benchmarks sequentially in fresh processes and retain raw output and metadata."""

import argparse
from datetime import datetime, timezone
import fcntl
import json
import os
from pathlib import Path
import platform
import re
import subprocess
import time


ROOT = Path(__file__).resolve().parent.parent
RESULT_PREFIX = "BENCHMARK_RESULT="


def capture(*command):
    return subprocess.run(command, cwd=ROOT, check=True, capture_output=True, text=True).stdout.strip()


def scenarios(value):
    parts = value.split(",")
    for part in parts:
        if re.fullmatch(r"S[1256]:(A|A2|B|C)", part):
            continue
        if part.startswith("S4:"):
            flags = part[3:].split("+") if part[3:] else []
            if len(flags) == len(set(flags)) and set(flags) <= {"cold", "lines", "colors", "appkit"}:
                continue
        raise argparse.ArgumentTypeError(f"Invalid scenario: {part!r}")
    return parts


def positive(value):
    value = int(value)
    if value < 1:
        raise argparse.ArgumentTypeError("Must be a positive integer")
    return value


def read_results(lines):
    results = [json.loads(line[len(RESULT_PREFIX):]) for line in lines if line.startswith(RESULT_PREFIX)]
    if not results:
        raise ValueError("Benchmark produced no structured results; see the saved log")
    return results


def run_once(command, environment, log, timeout):
    # Stream output to disk rather than retaining large logs in the runner's memory.
    with log.open("w") as output:
        subprocess.run(command, cwd=ROOT, env=environment, stdout=output, stderr=subprocess.STDOUT,
                       check=True, timeout=timeout)
    with log.open() as output:
        return read_results(output)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=["micro", "lab", "persistence"])
    parser.add_argument("scenarios", nargs="?", type=scenarios)
    parser.add_argument("--runs", type=positive, default=3, help="Fresh-process repetitions per scenario (default: 3)")
    parser.add_argument("--timeout", type=positive, default=180, help="Seconds per benchmark process (default: 180)")
    parser.add_argument("--output", type=Path, help="New result directory (default: .build/benchmarks/<timestamp>)")
    args = parser.parse_args()
    if args.mode != "lab" and args.scenarios is not None:
        parser.error("Scenarios are only supported by lab mode; use just lab-run <scenarios>")
    args.scenarios = args.scenarios or ["S1:A2"]

    base = ROOT / ".build/benchmarks"
    base.mkdir(parents=True, exist_ok=True)
    with (base / "run.lock").open("w") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            parser.exit(1, "Another benchmark runner is active; wait for it to finish.\n")
        run(args)


def run(args):
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S.%fZ")
    directory = (args.output or ROOT / ".build/benchmarks" / stamp).resolve()
    directory.mkdir(parents=True, exist_ok=False)
    metadata = {
        "schemaVersion": 1, "startedAt": stamp, "mode": args.mode, "runs": args.runs,
        "timeoutSeconds": args.timeout, "commit": capture("git", "rev-parse", "HEAD"),
        "workingTree": capture("git", "status", "--porcelain"),
        "os": platform.platform(), "machine": capture("sysctl", "-n", "hw.model"),
        "architecture": platform.machine(), "memoryBytes": int(capture("sysctl", "-n", "hw.memsize")),
        "cpuCount": os.cpu_count(), "toolchain": capture("xcrun", "swift", "--version"),
        "build": "Debug with -O" if args.mode == "lab" else "Release",
        "scenarios": (args.scenarios if args.mode == "lab" else
                      [f"{batch}:{rate}" for batch in [1, 16, 64] for rate in [100, 1000, 0]]
                      if args.mode == "persistence" else ["micro"]), "results": [],
    }
    report = directory / "report.json"

    def save():
        report.write_text(json.dumps(metadata, indent=2) + "\n")

    save()
    print(f"Results: {directory}", flush=True)
    try:
        recipe = {"micro": "bench-build", "lab": "lab-build",
                  "persistence": "bench-persistence-build"}[args.mode]
        with (directory / "build.log").open("w") as output:
            subprocess.run(["just", recipe], cwd=ROOT, stdout=output, stderr=subprocess.STDOUT, check=True)
        if args.mode != "lab":
            product = "persistence-bench" if args.mode == "persistence" else "rendering-bench"
            binary = Path(capture("just", "bench-path")) / product
        else:
            binary = ROOT / ".build/xcode-lab/Build/Products/Debug/Agenthesia.app/Contents/MacOS/Agenthesia"
        for repetition in range(1, args.runs + 1):
            for index, scenario in enumerate(metadata["scenarios"], start=1):
                environment = dict(os.environ)
                environment.pop("AGENTHESIA_LAB_RUNS", None)
                environment.pop("AGENTHESIA_LAB_SNAPSHOTS", None)
                if args.mode == "lab":
                    environment["AGENTHESIA_LAB_RUNS"] = scenario  # One scenario per process, including cold runs.
                log = directory / f"run-{repetition}-{index}.log"
                print(f"Run {repetition}/{args.runs}: {scenario}", flush=True)
                start = time.monotonic()
                command = [str(binary)]
                if args.mode == "persistence":
                    command += scenario.split(":")
                results = run_once(command, environment, log, args.timeout)
                metadata["results"].append({
                    "repetition": repetition, "scenario": scenario, "log": log.name,
                    "wallSeconds": time.monotonic() - start, "samples": results,
                })
                save()
    except (subprocess.SubprocessError, ValueError, OSError, KeyboardInterrupt) as error:
        metadata["error"] = str(error) or type(error).__name__
        save()
        raise
    print(f"Saved {report}", flush=True)


if __name__ == "__main__":
    main()
