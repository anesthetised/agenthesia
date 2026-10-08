# Benchmarks

Obtain the user's approval before running benchmarks. Agree on scenarios and repetitions first: they
consume CPU and memory, and GUI runs bring the lab window to the foreground. Builds and deterministic
tests can be run separately without launching benchmarks.

## Commands

```sh
just bench-build                  # Build the Release rendering microbenchmarks without running them
just bench-persistence-build      # Build the Release persistence benchmark without running it
just lab-build                    # Build the optimized Debug lab without running it
just test                         # Includes metric, scheduling and runner tests; no benchmark runs

# Run only after approval:
just bench --runs 1
just bench-persistence --runs 3
just lab-run S1:A2,S6:A2,S4:cold+lines+colors --runs 1
```

The runner defaults to three repetitions. Each repetition runs each scenario in a fresh process,
sequentially, with a 180-second timeout per process. Use `--runs N`, `--timeout SECONDS` and
`--output NEW_DIRECTORY` to override these settings. A lock prevents concurrent runner invocations in
the same checkout. It does not limit peak memory within one benchmark process or prevent manually
launched lab windows; close those before measuring.

Scenario arguments are supported only by `just lab-run`. `just bench S1:A2` is rejected before building
or running anything; `just bench` runs the complete microbenchmark suite.

Results go to `.build/benchmarks/<UTC timestamp>/`: `report.json`, `build.log`, and a raw log per run.
The report records the commit, dirty working-tree status, machine, OS, RAM, CPU count, Swift toolchain,
build configuration, workload, repetitions and per-run results. Lab results also include viewport size,
screen maximum refresh rate and backing scale. Failed and timed-out runs retain logs and an error in
the report. An existing output directory is never overwritten.

Runner logs are written to disk and read back line by line for structured results. Only those results,
not the full log, are retained in the runner's memory.

Coverage reports the debug-only `AgenthesiaUI/Lab/` directory separately as `RenderingLab`. This scope
and test support are excluded from the product total and badge; the rest of `AgenthesiaUI` remains
included. Deterministic lab metric and scheduling tests still run in CI.

## Persistence append workload

`just bench-persistence` measures the public `PersistenceStore.append` API against a new on-disk
SQLite database per process. It uses the production `DatabaseQueue` configuration (rollback journal,
FULL synchronous commits); it does not change journal mode or durability settings. The fixed matrix
is batches of 1, 16 and 64 events at 100 and 1,000 events/second, plus saturation (rate zero). Each
payload is a 1 KiB synthetic ACP text-chunk JSON object. Schema creation and metadata inserts happen
before timing; reopening and checking every stored payload and sequence happen after timing.

Each scenario has a two-second arrival window and a cap of 65,536 events (64 MiB of payload).
The last transaction can finish beyond the window. Paced batches become ready at absolute deadlines
`start + cumulative events / rate`, so slow commits do not reset the offered rate. Only complete
batches are scheduled. Work that remains when the window ends is not drained; compare `events`
with `scheduledEvents` to detect a writer that falls behind. Saturation stops at the time or event
limit, whichever comes first. `eventLimitReached` identifies runs that hit the cap.

Each result includes system-load snapshots immediately before and after the timed region: the
one-minute load average, active core count and free-memory percentage (`kern.memorystatus_level`),
matching the rendering benchmark. Unavailable OS counters are omitted, not reported as zero. These
snapshots expose background contention but do not isolate its effect on timings.

Results include achieved events/second, append p50/p95/max, p95 delay from the scheduled batch-ready
time to commit completion, event counts, elapsed time and final database size. Append latency excludes
waiting to fill a batch: at 100 events/second, batching 64 adds up to 630 ms of waiting for the first
event. This is a storage microbenchmark, not a measurement of the live session controller or UI.

The default three repetitions take about 54 seconds of measurement plus Release compilation and
replay verification. Processes and database files are sequential; each file is deleted on normal
exit. A forcibly killed process can leave an `agenthesia-bench-*` directory in the system temporary
directory. Do not run other builds, tests or measurements alongside this workload. These short,
fresh-database runs do not establish long-session, multi-session, WAL or crash-durability behavior.

Recorded comparisons: [initial persistence review fixes](benchmarks/2026-10-08/persistence/README.md)
and [rowid storage with resource snapshots](benchmarks/2026-10-08/persistence-rowid/README.md).

## Production transcript table

`just lab-run S1:App --runs 1` runs the existing 200-item, 100-chunks/second streaming workload through
`TranscriptTableController` and `LiveTranscriptSource`'s Markdown cache. It measures the production
AppKit table and rendering path. The original `S1:A2` prototype remains available unchanged for a
reference; its different row presentation is not an identical before/after implementation.

This variant does not include ACP transport, SQLite commits, the session reducer, or SwiftUI observation.
It cannot establish end-to-end durable streaming throughput; that remains #97. Like other lab runs,
it requires prior workload/resource approval. `App` also supports the lab's selection, scroll, and
appearance scenarios; these are separate workloads and were not part of this change's approved run.

## Rendering workloads

The microbenchmarks measure first use of each grammar, warm whole-file highlighting, Markdown rendering,
streaming with fixed 13-character chunks, and rendering 1,000 transcript items. Streaming covers both
a mixed answer and one long unclosed Swift code block. They measure computation, not UI responsiveness.
Per-operation medians use five highlighting iterations or twenty Markdown iterations; streaming reports
percentiles across chunks. Fresh-process repetitions are separate observations, not pooled chunk samples.

Lab prototypes are `A` (text fields), `A2` (A′, TextKit 2 for the last message), `B` (one TextKit 2
document), and `C` (SwiftUI). Examples:

| Scenario | Workload |
|---|---|
| `S1:A2` | Mixed answer into 200 items; 100 chunks/s on a monotonic schedule |
| `S6:A2` | One unclosed 400-line Swift block; same schedule and transcript size |
| `S2:A2` | Open 10,000 items, then scroll at 14,400 points/s for at most 25 seconds |
| `S5:A2` | Ten appearance switches; includes the callback after the last switch |
| `S4:lines+colors` | Warm Swift grammar, 10,000-line file; scroll at 7,200 points/s |
| `S4:cold+lines+colors` | Same file, no grammar prewarming in a fresh process |
| `S4:` | Plain file, no line numbers or highlighting |
| `S4:appkit+lines+colors` | SourceView in a separate AppKit window, without SwiftUI hosting ancestors |

S1 and S6 use deterministic 2–24-character chunks. The producer is a virtual arrival schedule: elapsed
time determines how many chunks are due, even if the main thread stalls. Each callback coalesces all due
chunks into one update. This tests the intended UI coalescing policy; it does not exercise ACP transport
or persistence. Transcript scenarios prewarm grammars. S4 cold refers to process-local grammar state,
not a cold OS filesystem cache or total app launch time. Use the runner for cold runs; a manual cold run
after other work in the same lab process is not cold.

## Interpreting metrics

- **Callbacks, p50/p95/p99/max:** intervals between display-link timestamps. They are a responsiveness
  proxy, not CPU rendering durations or proof of pixel presentation. A whole-scenario maximum includes
  setup and initial layout; locate the interval before calling it a scrolling stall.
- **Hitches:** intervals longer than 1.5 times the expected refresh interval.
- **Estimated missed intervals:** `max(0, round(interval / budget) - 1)`, summed across callbacks. A long
  pause can count as one hitch and many missed intervals. Variable refresh makes this an estimate.
- **Excess milliseconds:** sum of positive time beyond each callback's expected refresh budget; small
  scheduling jitter contributes too. The budget comes from the display link's target timestamp, with
  its duration as a fallback.
- **Setup:** synchronous content installation and layout. It excludes view construction and fixture
  generation. It is not an end-to-end opening time.
- **Viewport geometry (S4):** `viewportWidth`/`viewportHeight` describe the outer SourceView;
  `textViewportWidth`/`textViewportHeight` describe the actual scroll clip. The gutter currently reserves
  width even when hidden. `documentWidth`/`documentHeight` record the final text-view extent.
- **First callback after setup (S4):** time from setup start to the following callback; a first-frame
  proxy only. The monitor starts before content installation so setup stalls are included.
- **Highlight complete (S4):** time from setup start until background highlighting has finished and its
  attributes have been applied on the main thread. The next callback is also observed before finishing.
- **Apply latency p95/max (S1/S6):** scheduled chunk arrival to completion of the UI update call, per
  original chunk. Deferred drawing may happen later; this is not pixel-presentation latency.
- **Peak backlog:** maximum observed number of chunks due but not yet applied, including arrivals during
  a UI update. **Elapsed:** total streaming scenario duration including the final observation callback.
- **Memory:** process footprint at the end of the scenario, not peak usage or retained memory after close.
- **All items available / reached start (S2):** distinguish a completed traversal from the 25-second cap
  or unfinished background insertion. Availability does not mean every virtualized row has been rendered.

## Comparing changes

Keep the Mac idle and the lab window in front. Use the same hardware, display, viewport, power conditions,
build configuration and workload. Review per-run variability and worst pauses as well as medians; do not
infer a regression from one noisy run. Start with `--runs 1` for a smoke check, then agree on repetitions
for a comparison. Do not run builds, coverage or other benchmarks concurrently with measurements.

The measurements in ADR-0007 are historical: its streaming input and scrolling advanced per display
callback, `Dropped` counted long intervals, and `Open` measured synchronous setup with warm grammars.
The new scheduled streaming results are not directly comparable to those numbers. This changes the
measurement method, not the accepted choice of A′. Revisit that choice only after reviewing new evidence.

Recorded validation: [2026-10-07 results and raw samples](benchmarks/2026-10-07/README.md).
## CPU profiling

The [SourceView attribute-update comparison](benchmarks/2026-10-07/source-attributes/README.md) records a
measured prototype, its rejected unbatched variant, and the remaining whole-scenario outliers.

Use `just lab-profile S6:A2 .build/stream-code.trace` or
`just lab-profile S4:lines+colors .build/source-colors.trace` for a single scenario under Xcode's Time
Profiler with Points of Interest. Recordings stop after 30 seconds or when the app exits; use a new output path for each run.
Run profiling sequentially, separately from ordinary benchmarks. Profiler overhead changes timing and
memory consumption. Inspect the trace in Instruments or export its first recording's CPU samples with
`just lab-profile-export .build/stream-code.trace .build/stream-code.xml`.

The optional third argument to `lab-profile` is an xctrace recording-options JSON file. To distinguish
CPU work from blocking, enable waiting-thread recording and context-switch sampling; those sample
weights must not be interpreted as CPU time. The optional third argument to `lab-profile-export`
selects a table, such as `PointsOfInterestEvents`. `LongFrame` events mark display or callback gaps
above 50 ms for timeline correlation; they do not alter the refresh-budget hitch metrics.

The `appkit` S4 flag is a diagnostic hosting control, not an alternative product architecture. It uses
a separate 868 x 340 pt window and closes it after measurement. Do not combine its results with the
default SwiftUI-hosted scenario when reporting repeated runs.

See the [2026-10-07 diagnostic profiles](benchmarks/2026-10-07/profiling/README.md) for localized costs and
the implementation choices that remain to be discussed.

The [SourceView scroll-wait investigation](benchmarks/2026-10-07/source-scroll/README.md) correlates long
callback gaps with Core Animation synchronization waits and includes AppKit and native TextKit 2 controls.

## Session transcript reduction

`just bench-session` compares publication after each chunk with publication after every 16 chunks,
using 10,000 recorded text updates and three sequential Release runs. It measures decoding, pure
reduction and snapshot copies; fixture/database setup, UI rendering and controller scheduling are
outside the timed loop. Ask for workload/resource approval before running it, like the other benchmarks.
See [the initial comparison](benchmarks/2026-10-08/session/README.md) for results and limitations.
