from pathlib import Path
import unittest
from unittest.mock import patch

import trace_summary


FIXTURES = Path(__file__).resolve().parent / "fixtures"


class TraceSummaryTests(unittest.TestCase):
    def test_hitches_of_the_app_resolve_refs_across_rows_and_tables_once(self):
        rows = trace_summary.rows((FIXTURES / "trace-hitches.xml").read_text())
        durations, named = trace_summary.hitches(rows, "Agenthesia")
        self.assertTrue(named)
        # The WindowServer hitch is left out; the second table repeats the first hitch.
        self.assertEqual([round(duration, 3) for duration in durations], [25.0, 8.333, 16.667])

    def test_a_table_without_processes_counts_every_hitch(self):
        rows = [{key: value for key, value in row.items() if key != "process"}
                for row in trace_summary.rows((FIXTURES / "trace-hitches.xml").read_text())]
        durations, named = trace_summary.hitches(rows, "Agenthesia")
        self.assertFalse(named)
        self.assertEqual(round(sum(durations), 3), 100.0)

    def test_signposts_pair_into_intervals_of_the_app(self):
        rows = trace_summary.rows((FIXTURES / "trace-signposts.xml").read_text())
        intervals, unmatched = trace_summary.intervals(rows)
        # Message nests in the first Cell; the AppKit Cell, the LongFrame event and the repeated table are left out.
        self.assertEqual(dict(intervals), {
            "Cell": [(1_000_000_000, 10_000_000), (7_000_000_000, 20_000_000)],
            "Message": [(1_001_000_000, 3_000_000)],
        })
        self.assertEqual(unmatched, 1)  # The Draw end without its begin.

    def test_report(self):
        hitches = trace_summary.rows((FIXTURES / "trace-hitches.xml").read_text())
        signposts = trace_summary.rows((FIXTURES / "trace-signposts.xml").read_text())
        durations, named = trace_summary.hitches(hitches, "Agenthesia")
        intervals, unmatched = trace_summary.intervals(signposts)
        text = trace_summary.report(durations, named, "hitches", "Agenthesia", 10, intervals, unmatched)
        self.assertEqual(text.splitlines(), [
            "Hitches (hitches, process Agenthesia): 3, 50.0 ms in 10 s of scrolling: 5.00 ms/s; longest 25.0 ms",
            "Signpost intervals:",
            "  Cell               2  total      30.0 ms  longest 20.0 ms",
            "  Message            1  total       3.0 ms  longest 3.0 ms",
            "  (1 begin or end events without their pair)",
            "Cell intervals per 5 s from 0 s of the trace: 1 1",
        ])

    def test_picks_the_hitches_table_the_trace_has(self):
        toc = """<?xml version="1.0"?><trace-toc><run number="1"><data>
            <table schema="os-signpost" category="PointsOfInterest"/><table schema="hitches-summary"/>
            <table schema="hitches-lifetime-interval"/></data></run></trace-toc>"""
        exports = []
        def export(trace, *arguments):
            exports.append(arguments)
            if arguments == ("--toc",):
                return toc
            return (FIXTURES / ("trace-signposts.xml" if "os-signpost" in arguments[1] else "trace-hitches.xml")).read_text()
        with patch("sys.argv", ["trace_summary.py", "wheel.trace", "10"]), \
             patch.object(trace_summary, "export", side_effect=export), \
             patch("builtins.print") as output:
            trace_summary.main()
        self.assertEqual(exports[1], ("--xpath", '/trace-toc/run[@number="1"]/data/table[@schema="hitches-summary"]'))
        self.assertIn("Hitches (hitches-summary, process Agenthesia): 3", output.call_args.args[0])

    def test_a_trace_without_hitches_fails_with_the_tables_it_has(self):
        toc = '<trace-toc><run number="1"><data><table schema="hitches-gpu-interval"/></data></run></trace-toc>'
        with patch("sys.argv", ["trace_summary.py", "wheel.trace", "10"]), \
             patch.object(trace_summary, "export", return_value=toc), \
             self.assertRaises(SystemExit) as error:
            trace_summary.main()
        self.assertIn("hitches-gpu-interval", str(error.exception.code))


if __name__ == "__main__":
    unittest.main()
