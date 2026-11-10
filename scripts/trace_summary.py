#!/usr/bin/env python3
"""Summarize a wheel-scenario trace (#396): hitch time per second of scrolling and the transcript's signposts.

    scripts/trace_summary.py <trace> <seconds of scrolling> [--process Agenthesia]

Exports the trace's hitches table and its os-signpost table with `xctrace export`. The hitch time ratio is the hitch
time of the app's process, in ms, over the seconds spent scrolling (scripts/app-check/wheel-scroll.sh measures and
passes them); hitches of other processes are left out when the table names a process.
"""

import argparse
from collections import defaultdict
import subprocess
import sys
import xml.etree.ElementTree as ET


# The first one the trace has: Animation Hitches names its table differently across Xcode versions.
HITCH_SCHEMAS = ["hitches", "hitches-summary", "hitches-lifetime-interval"]
SUBSYSTEM = "io.github.anesthetised.Agenthesia"
BUCKET_SECONDS = 5


def export(trace, *arguments):
    command = ["xcrun", "xctrace", "export", "--input", str(trace), *arguments]
    return subprocess.run(command, check=True, capture_output=True, text=True).stdout


def table_xpath(schema):
    return f'/trace-toc/run[@number="1"]/data/table[@schema="{schema}"]'


def schemas(toc):
    """The table schemas of the trace's first run, from `xctrace export --toc`."""
    return {table.get("schema") for table in ET.fromstring(toc).findall('run[@number="1"]/data/table')}


def rows(document):
    """The rows of an export as {column mnemonic: element}, without empty (sentinel) values. An element may be a
    `ref` to an element with that `id` anywhere in the document, also in another row or table."""
    root = ET.fromstring(document)
    ids = {element.get("id"): element for element in root.iter() if element.get("id") is not None}
    result = []
    # A real export may give the schema in a node of its own and the rows in later nodes without one.
    columns = []
    for node in root.iter("node"):
        schema = node.find("schema")
        if schema is not None:
            columns = [column.findtext("mnemonic") for column in schema.findall("col")]
        for row in node.findall("row"):
            values = {}
            for column, element in zip(columns, row):
                element = ids.get(element.get("ref"), element)
                if element.tag != "sentinel":
                    values[column] = element
            result.append(values)
    return result


def label(element):
    return element.get("fmt") or element.text or ""


def number(element):
    return int(element.text)


def unique(rows, columns):
    """Rows that differ in `columns`: a schema recorded in two tables lists the same events twice."""
    seen = set()
    for row in rows:
        key = tuple((label(row[column]), row[column].text) if column in row else None for column in columns)
        if key not in seen:
            seen.add(key)
            yield row


def hitches(rows, process):
    """The durations of the process's hitches in ms, and whether the table names processes at all."""
    named = any("process" in row for row in rows)
    durations = []
    for row in unique(rows, ["start", "duration", "hitch-duration", "process"]):
        if named and not ("process" in row and label(row["process"]).startswith(process)):
            continue
        duration = row.get("hitch-duration", row.get("duration"))
        if duration is not None:
            durations.append(number(duration) / 1e6)
    return durations, named


def intervals(rows, subsystem=SUBSYSTEM):
    """The app's signpost intervals as {name: [(start ns, duration ns)]} and the count of unmatched events. A begin
    pairs with the latest open begin of its name and identifier on its thread."""
    open_intervals = defaultdict(list)
    result = defaultdict(list)
    unmatched = 0
    events = [row for row in rows if "subsystem" in row and label(row["subsystem"]) == subsystem]
    events = list(unique(events, ["time", "thread", "event-type", "name", "identifier"]))
    events.sort(key=lambda row: number(row["time"]))
    for row in events:
        kind = label(row["event-type"])
        name = label(row["name"])
        key = (label(row["thread"]), name, label(row["identifier"]) if "identifier" in row else "")
        if kind == "Begin":
            open_intervals[key].append(number(row["time"]))
        elif kind == "End":
            if open_intervals[key]:
                start = open_intervals[key].pop()
                result[name].append((start, number(row["time"]) - start))
            else:
                unmatched += 1
    return result, unmatched + sum(len(starts) for starts in open_intervals.values())


def report(hitch_durations, named, schema, process, seconds, signposts, unmatched):
    total = sum(hitch_durations)
    whose = f"process {process}" if named else "all processes: the table names none"
    lines = [
        f"Hitches ({schema}, {whose}): {len(hitch_durations)}, {total:.1f} ms in {seconds:g} s of scrolling: "
        f"{total / seconds:.2f} ms/s; longest {max(hitch_durations, default=0):.1f} ms",
        "Signpost intervals:",
    ]
    for name in sorted(signposts):
        durations = [duration / 1e6 for _, duration in signposts[name]]
        lines.append(f"  {name:<12} {len(durations):>7}  total {sum(durations):>9.1f} ms  longest {max(durations):.1f} ms")
    if unmatched:
        lines.append(f"  ({unmatched} begin or end events without their pair)")
    cells = signposts.get("Cell", [])
    if cells:
        buckets = defaultdict(int)
        for start, _ in cells:
            buckets[start // (BUCKET_SECONDS * 10**9)] += 1
        first, last = min(buckets), max(buckets)
        counts = " ".join(str(buckets[bucket]) for bucket in range(first, last + 1))
        lines.append(f"Cell intervals per {BUCKET_SECONDS} s from {first * BUCKET_SECONDS} s of the trace: {counts}")
    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("trace")
    parser.add_argument("seconds", type=float, help="Seconds spent scrolling")
    parser.add_argument("--process", default="Agenthesia", help="The app's process name (default: Agenthesia)")
    args = parser.parse_args()
    present = schemas(export(args.trace, "--toc"))
    schema = next((schema for schema in HITCH_SCHEMAS if schema in present), None)
    if schema is None:
        found = ", ".join(sorted(schema for schema in present if "hitch" in schema)) or "none"
        sys.exit(f"No hitches table in {args.trace}; tables about hitches: {found}")
    durations, named = hitches(rows(export(args.trace, "--xpath", table_xpath(schema))), args.process)
    signposts, unmatched = intervals(rows(export(args.trace, "--xpath", table_xpath("os-signpost"))))
    print(report(durations, named, schema, args.process, args.seconds, signposts, unmatched))


if __name__ == "__main__":
    main()
