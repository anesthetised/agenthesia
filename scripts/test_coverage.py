import contextlib
import io
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import coverage


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
            with patch.object(coverage, "codecov_dir", return_value=directory), \
                 patch.object(coverage, "swift", return_value=directory), \
                 patch.object(coverage.subprocess, "run",
                              return_value=subprocess.CompletedProcess([], 0, stdout=exported)), \
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
