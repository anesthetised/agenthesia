"""Bounded sequential isolation controls, with workload checks against the application's actual fixture."""
import hashlib
import json
import os
from pathlib import Path
import platform
import subprocess
import sys
from datetime import datetime, timezone

binary, fixture_file, directory = map(Path, sys.argv[1:])
binary = binary.resolve()
directory.mkdir(parents=True, exist_ok=False)
fixture = json.loads(fixture_file.read_text())
order = ["native", "sttextview", "sttextview", "native", "native", "sttextview"]
metadata = {
    "startedAt": datetime.now(timezone.utc).isoformat(),
    "os": platform.platform(),
    "machine": subprocess.check_output(["sysctl", "-n", "hw.model"], text=True).strip(),
    "commit": subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip(),
    "workingTree": subprocess.check_output(["git", "status", "--porcelain"], text=True).strip(),
    "binarySHA256": hashlib.sha256(binary.read_bytes()).hexdigest(),
    "build": "SwiftPM Release", "order": order, "fixture": fixture, "runs": [],
}
report = directory / "report.json"
try:
    # Input validation must fail before launching an application window.
    for invalid_key in ("SCROLL_PROBE_RENDERER", "SCROLL_PROBE_GEOMETRY"):
        invalid = subprocess.run([str(binary)], env={**os.environ, invalid_key: "invalid"},
                                 capture_output=True, text=True, timeout=10)
        assert invalid.returncode != 0 and "PROBE_ERROR=" in invalid.stdout
    for index, renderer in enumerate(order, start=1):
        print(f"Run {index}/{len(order)}: {renderer}", flush=True)
        log = directory / f"run-{index}-{renderer}.log"
        with log.open("w") as output:
            subprocess.run([str(binary)], env={**os.environ, "SCROLL_PROBE_RENDERER": renderer},
                           stdout=output, stderr=subprocess.STDOUT, timeout=40, check=True)
        results = [json.loads(line.removeprefix("PROBE_RESULT=")) for line in log.read_text().splitlines()
                   if line.startswith("PROBE_RESULT=")]
        assert len(results) == 1, "Missing or duplicate result"
        result = results[0]
        metadata["runs"].append({"log": log.name, "result": result})
        assert result["renderer"] == renderer
        assert all(result[key] == value for key, value in fixture.items()), "Fixture differs from the application"
        assert result["reachedEnd"] and not result["timedOut"], "Incomplete traversal"
        assert result["frames"] > 100 and result["documentHeight"] > 100_000, "Insufficient workload"
        assert result["windowWidth"] == 868 and result["windowHeight"] == 340
        assert result["viewportWidth"] == result["windowWidth"] - result["reservedLeadingWidth"]
        assert result["viewportHeight"] == result["windowHeight"]
        assert result["firstLineHeight"] > 0, "Missing laid-out first line"
        report.write_text(json.dumps(metadata, indent=2) + "\n")
except BaseException as error:
    metadata["error"] = str(error) or type(error).__name__
    raise
finally:
    report.write_text(json.dumps(metadata, indent=2) + "\n")
print(f"Saved {report}", flush=True)
