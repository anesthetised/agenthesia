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
import signal
import subprocess
import tempfile
import time


ROOT = Path(__file__).resolve().parent.parent
RESULT_PREFIX = "BENCHMARK_RESULT="


def capture(*command):
    return subprocess.run(command, cwd=ROOT, check=True, capture_output=True, text=True).stdout.strip()


def scenarios(value):
    parts = value.split(",")
    for part in parts:
        if re.fullmatch(r"S[1256]:(A|A2|B|C|App)", part):
            continue
        # Only the production table has tool cards, thoughts and turns.
        if part in ("S7:App", "S8:App", "S9:App", "S10:App", "S11:App"):
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


def processes(executable):
    """The identifiers of the running processes of `executable`."""
    found = subprocess.run(["pgrep", "-f", str(executable)], capture_output=True, text=True).stdout
    return {int(pid) for pid in found.split()}


def stop(pids, grace=5):
    """Terminate `pids`, then kill those still running after `grace` seconds; return when all have exited."""
    def alive(pid):
        try:
            os.kill(pid, 0)
            return True
        except ProcessLookupError:
            return False

    for sig in (signal.SIGTERM, signal.SIGKILL):
        for pid in pids:
            try:
                os.kill(pid, sig)
            except ProcessLookupError:
                pass
        deadline = time.monotonic() + grace
        while any(alive(pid) for pid in pids) and time.monotonic() < deadline:
            time.sleep(0.1)
        pids = {pid for pid in pids if alive(pid)}
        if not pids:
            return


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
                log = directory / f"run-{repetition}-{index}.log"
                print(f"Run {repetition}/{args.runs}: {scenario}", flush=True)
                start = time.monotonic()
                command = [str(binary)]
                if args.mode == "persistence":
                    command += scenario.split(":")
                environment = {key: value for key, value in os.environ.items()
                               if key not in ("AGENTHESIA_LAB_RUNS", "AGENTHESIA_LAB_SNAPSHOTS")}
                # A fresh home per lab process keeps the installed app's history, settings and saved windows out,
                # beside the lab build's own bundle identifier; it is removed afterwards.
                with tempfile.TemporaryDirectory(prefix="agh-lab-") as home:
                    if args.mode == "lab":
                        # One scenario per process, including cold runs.
                        environment |= {"AGENTHESIA_LAB_RUNS": scenario, "CFFIXED_USER_HOME": home}
                        # Started by a shell, the app presents no window; through LaunchServices it presents the
                        # Rendering Lab (#396). Its output goes to the log, which `open -W` waits for.
                        command = ["open", "-n", "-W", "--stdout", str(log), "--stderr", str(log),
                                   "--env", f"AGENTHESIA_LAB_RUNS={scenario}", "--env", f"CFFIXED_USER_HOME={home}",
                                   str(binary.parents[2])]
                    # `open -W` waits for the app, but a timeout or an interrupt stops only `open`: stop the lab too
                    # before its temporary home is removed.
                    running = processes(binary) if args.mode == "lab" else set()
                    try:
                        results = run_once(command, environment, log, args.timeout)
                    except BaseException:
                        if args.mode == "lab":
                            stop(processes(binary) - running)
                        raise
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
