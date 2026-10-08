import argparse
import io
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import bench


class BenchmarkRunnerTests(unittest.TestCase):
    def test_validates_scenarios_instead_of_silently_running_source_view(self):
        self.assertEqual(bench.scenarios("S1:A2,S6:B,S4:cold+lines+colors"),
                         ["S1:A2", "S6:B", "S4:cold+lines+colors"])
        self.assertEqual(bench.scenarios("S1:App"), ["S1:App"])
        self.assertEqual(bench.scenarios("S7:App"), ["S7:App"])
        self.assertEqual(bench.scenarios("S4:"), ["S4:"])
        self.assertEqual(bench.scenarios("S4:appkit,S4:appkit+lines+colors"),
                         ["S4:appkit", "S4:appkit+lines+colors"])
        for invalid in ["S1:A′", "S3:A", "S7:A", "S7:A2", "S4:colours", "S4:cold+cold", "S1:A2,"]:
            with self.assertRaises(argparse.ArgumentTypeError):
                bench.scenarios(invalid)

    def test_structured_results_are_not_parsed_from_locale_dependent_tables(self):
        result = {"scenario": "stream", "measurements": {"p95MS": 1.25}}
        output = "| 1,25 |\n" + bench.RESULT_PREFIX + json.dumps(result) + "\n"
        self.assertEqual(bench.read_results(iter(output.splitlines())), [result])
        with self.assertRaises(ValueError):
            bench.read_results(["No results"])

    def test_micro_mode_rejects_scenarios_before_building_or_running(self):
        with patch("sys.argv", ["bench.py", "micro", "S1:A2"]), \
             patch("sys.stderr", new_callable=io.StringIO) as stderr, \
             patch.object(bench, "run") as run, \
             patch.object(bench.Path, "mkdir") as mkdir, \
             self.assertRaises(SystemExit) as error:
            bench.main()
        self.assertEqual(error.exception.code, 2)
        self.assertIn("only supported by lab mode", stderr.getvalue())
        run.assert_not_called()
        mkdir.assert_not_called()

    def test_run_preserves_log_and_propagates_failure_and_timeout(self):
        with tempfile.TemporaryDirectory() as directory:
            log = Path(directory) / "run.log"
            def success(*args, **kwargs):
                kwargs["stdout"].write(bench.RESULT_PREFIX + '{"scenario":"test"}\n')
            with patch.object(bench.subprocess, "run", side_effect=success) as run, \
                 patch.object(Path, "read_text", side_effect=AssertionError("Do not load the whole log")):
                self.assertEqual(bench.run_once(["fake"], {}, log, 2), [{"scenario": "test"}])
                self.assertEqual(run.call_args.kwargs["timeout"], 2)
            self.assertIn("test", log.read_text())
            for error in [subprocess.CalledProcessError(1, "fake"), subprocess.TimeoutExpired("fake", 2)]:
                with patch.object(bench.subprocess, "run", side_effect=error), self.assertRaises(type(error)):
                    bench.run_once(["fake"], {}, log, 2)

    def test_repetitions_and_timeout_must_be_positive(self):
        self.assertEqual(bench.positive("3"), 3)
        for value in ["0", "-1"]:
            with self.assertRaises(argparse.ArgumentTypeError):
                bench.positive(value)

    def test_each_scenario_gets_a_separate_process_and_saved_sample(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "results"
            args = argparse.Namespace(mode="lab", runs=2, timeout=7, output=output,
                                      scenarios=["S1:A2", "S4:cold+colors"])
            def capture(*command):
                return "1024" if "hw.memsize" in command else "test"
            with patch.object(bench, "capture", side_effect=capture), \
                 patch.object(bench.subprocess, "run"), \
                 patch.object(bench, "run_once", return_value=[{"scenario": "test"}]) as run:
                bench.run(args)
            self.assertEqual(run.call_count, 4)
            self.assertEqual([call.args[1]["AGENTHESIA_LAB_RUNS"] for call in run.call_args_list],
                             ["S1:A2", "S4:cold+colors", "S1:A2", "S4:cold+colors"])
            report = json.loads((output / "report.json").read_text())
            self.assertEqual([row["repetition"] for row in report["results"]], [1, 1, 2, 2])
            self.assertEqual(len({row["log"] for row in report["results"]}), 4)

    def test_persistence_matrix_uses_release_binary_and_separate_processes(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "results"
            args = argparse.Namespace(mode="persistence", runs=3, timeout=10, output=output, scenarios=None)
            def capture(*command):
                return "1024" if "hw.memsize" in command else "/tmp/bin"
            with patch.object(bench, "capture", side_effect=capture), \
                 patch.object(bench.subprocess, "run") as build, \
                 patch.object(bench, "run_once", return_value=[{"scenario": "test"}]) as run:
                bench.run(args)
            self.assertEqual(build.call_args.args[0], ["just", "bench-persistence-build"])
            expected = [["/tmp/bin/persistence-bench", str(batch), str(rate)]
                        for batch in [1, 16, 64] for rate in [100, 1000, 0]] * 3
            self.assertEqual([call.args[0] for call in run.call_args_list], expected)
            self.assertTrue(all("AGENTHESIA_LAB_RUNS" not in call.args[1] for call in run.call_args_list))
            report = json.loads((output / "report.json").read_text())
            self.assertEqual(report["build"], "Release")
            self.assertEqual(len(report["results"]), 27)

    def test_failed_measurement_retains_error_and_successful_results(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "results"
            args = argparse.Namespace(mode="lab", runs=2, timeout=7, output=output, scenarios=["S1:A2"])
            def capture(*command):
                return "1024" if "hw.memsize" in command else "test"
            failure = subprocess.TimeoutExpired("fake", 7)
            with patch.object(bench, "capture", side_effect=capture), \
                 patch.object(bench.subprocess, "run"), \
                 patch.object(bench, "run_once", side_effect=[[{"scenario": "test"}], failure]), \
                 self.assertRaises(subprocess.TimeoutExpired):
                bench.run(args)
            report = json.loads((output / "report.json").read_text())
            self.assertIn("timed out", report["error"])
            self.assertEqual(len(report["results"]), 1)


if __name__ == "__main__":
    unittest.main()
