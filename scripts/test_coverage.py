import contextlib
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

import coverage


class CoverageTestProcessTests(unittest.TestCase):
    def test_samples_only_test_runners_descended_from_this_invocation(self):
        processes = "\n".join([
            "10 1 /usr/bin/swift-test",
            "20 10 /usr/bin/wrapper",
            "30 20 /tmp/Tests.xctest/Contents/MacOS/Tests",
            "40 10 /usr/bin/swiftpm-testing",
            "50 1 /tmp/Other.xctest/Contents/MacOS/Other",
            "60 20 /tmp/MockAgent",
            "70 10 /usr/bin/swiftpm-testing-helper",
        ])
        with patch.object(coverage.subprocess, "check_output", return_value=processes), \
             patch.object(coverage.subprocess, "run") as sample, \
             contextlib.redirect_stdout(io.StringIO()):
            coverage.sample_test_processes(10)
        self.assertEqual([call.args[0][1] for call in sample.call_args_list], ["30", "40", "70"])

    def test_preserves_test_success_and_failure(self):
        for status in (0, 17):
            with self.subTest(status=status):
                actual = coverage.run_test_process(
                    [sys.executable, "-c", f"raise SystemExit({status})"], dict(os.environ), timeout=5
                )
                self.assertEqual(actual, status)

    def test_timeout_reports_failure_and_reaps_the_test_process_even_if_sampling_fails(self):
        with tempfile.TemporaryDirectory() as directory:
            pid_file = Path(directory) / "pid"
            command = [sys.executable, "-c",
                       "import os, pathlib, signal, time; "
                       "signal.signal(signal.SIGTERM, signal.SIG_IGN); "
                       f"pathlib.Path({str(pid_file)!r}).write_text(str(os.getpid())); time.sleep(60)"]
            with patch.object(coverage, "sample_test_processes", side_effect=OSError("sample unavailable")), \
                 contextlib.redirect_stderr(io.StringIO()) as errors:
                status = coverage.run_test_process(command, dict(os.environ), timeout=1)
            self.assertEqual(status, 124)
            self.assertIn("exceeded", errors.getvalue())
            self.assertIn("sample unavailable", errors.getvalue())
            with self.assertRaises(ProcessLookupError):
                os.kill(int(pid_file.read_text()), 0)


class CoverageReportTests(unittest.TestCase):
    def report(self, threshold):
        files = []
        for name, covered, count in [
            ("Rendering/SourceView.swift", 10, 10),
            ("AgenthesiaUI/RootView.swift", 8, 10),
            ("AgenthesiaUI/Lab/RenderingLab.swift", 0, 100),
            ("ACPTesting/MockConnection.swift", 0, 100),
            ("MockAgent/main.swift", 0, 100),
        ]:
            files.append({
                "filename": "/repo/Packages/AgenthesiaKit/Sources/" + name,
                "summary": {"lines": {"covered": covered, "count": count}},
            })
        exported = json.dumps({"data": [{"files": files}]})
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "test.profraw").touch()
            binary = root / "Tests.xctest/Contents/MacOS/Tests"
            binary.parent.mkdir(parents=True)
            binary.touch()
            badge = root / "coverage.svg"
            stdout, stderr = io.StringIO(), io.StringIO()
            run = patch.object(coverage.subprocess, "run",
                               return_value=subprocess.CompletedProcess([], 0, stdout=exported))
            with patch.object(coverage, "codecov_dir", return_value=directory), \
                 patch.object(coverage, "swift", return_value=directory), \
                 run as self.run_mock, \
                 contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
                status = coverage.report("unused", [threshold, "--badge", str(badge)])
            return status, stdout.getvalue(), stderr.getvalue(), badge.read_text()

    def test_product_total_includes_ui_but_reports_lab_and_test_support_separately(self):
        status, output, errors, badge = self.report("Rendering=90")
        self.assertEqual(status, 0, errors)
        self.assertRegex(output, r"AgenthesiaUI\s+8/10\s+80\.0%")
        self.assertRegex(output, r"RenderingLab\s+0/100\s+0\.0%")
        self.assertRegex(output, r"ACPTesting\s+0/100\s+0\.0%")
        self.assertRegex(output, r"MockAgent\s+0/100\s+0\.0%")
        self.assertRegex(output, r"Product total\s+18/20\s+90\.0%")
        self.assertIn("coverage: 90.0%", badge)

    def test_merge_skips_corrupt_profiles_unless_all_are(self):
        self.report("Rendering=90")
        merge = self.run_mock.call_args_list[0].args[0]
        self.assertEqual(merge[:3], ["xcrun", "llvm-profdata", "merge"])
        self.assertIn("--failure-mode=all", merge)

    def test_ui_threshold_is_still_enforced(self):
        status, output, errors, _ = self.report("AgenthesiaUI=85")
        self.assertEqual(status, 1)
        self.assertIn("FAIL", output)
        self.assertIn("Coverage below threshold: AgenthesiaUI", errors)

    def test_missing_required_scope_fails(self):
        status, output, errors, _ = self.report("Missing=90")
        self.assertEqual(status, 1)
        self.assertIn("no coverage data  FAIL", output)
        self.assertIn("Coverage below threshold: Missing", errors)


if __name__ == "__main__":
    unittest.main()
