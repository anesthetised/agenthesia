# Rendering benchmark validation — 2026-10-07

Measured implementation: `7960afe5e6d84391a811a5902564d5decf50ab62`, clean working tree at the start of each
run set. The commands ran sequentially, with no concurrent local builds or tests. The lab was in the
foreground; this was an ordinary desktop session, not a controlled performance machine. System load
varied from 5.7 to 11.1 on 10 cores during the repeated GUI runs.

- Hardware: MacBookPro18,2, Apple silicon, 32 GiB RAM, 10 reported CPUs.
- OS: macOS 27.0.1; Apple Swift 6.4 (`swiftlang-6.4.0.34.1`).
- GUI: optimized Debug (`-O`), 120 Hz screen maximum, 2x scale, 868 x 340 pt content viewport.
- Microbenchmarks: Release; five highlighting iterations or twenty Markdown iterations per process.
- Three fresh-process repetitions per workload; no pooling of frame or chunk samples between runs.

Commands:

```sh
just lab-run S1:A2,S6:A2,S4:lines+colors,S4:cold+lines+colors --runs 3 --timeout 90
just bench --runs 3 --timeout 90
```

[Raw GUI results](lab.json) and [raw microbenchmark results](micro.json) retain per-run samples and
metadata. Raw stdout/stderr and build logs remain in the local `.build/benchmarks/` directories named by
`startedAt`; these logs are not committed. Metric definitions and limitations are in
[the benchmark guide](../../BENCHMARKS.md).

## GUI results

Values below are medians of the three per-run statistics, with the min–max range where useful.
Callback intervals are responsiveness proxies, not measured rendering CPU time or pixel presentation.

| Workload | Callback p95, ms | Largest interval per run, ms | UI-apply latency p95, ms | Backlog, chunks |
|---|---:|---:|---:|---:|
| Mixed answer, A′ | 8.33 (8.33–8.33) | 16.67 (12.21–22.72) | 8.47 (8.37–9.30) | 3 (2–4) |
| Long unclosed Swift block, A′ | 33.87 (33.78–33.91) | 38.82 (38.00–39.15) | 36.06 (35.89–36.86) | 5 (5–5) |
| SourceView, warm grammar | 8.33 | 230.94 (217.54–238.63) | — | — |
| SourceView, cold grammar | 8.33 | 239.34 (216.76–240.43) | — | — |

The GUI mixed answer has 16,249 characters in 1,244 scheduled chunks. The code block has 9,511 characters
in 727 chunks. Both use 100 arrivals/s and coalesce all due chunks once per UI update. A smaller message
can therefore be substantially more expensive when it is one growing code block.

| SourceView, 10,000 lines | Setup, ms | First callback after setup, ms | Highlight complete, ms |
|---|---:|---:|---:|
| Warm grammar | 11.18 | 18.94 | 426.46 (422.91–429.02) |
| Cold grammar | 13.54 | 21.74 | 695.64 (693.15–697.30) |

End-of-scenario process footprint ranged from 59.4 to 70.6 MiB. This is **not peak memory** and does not
establish a peak-memory budget.

## Microbenchmarks

These measure synchronous computation without a window. Their synthetic fixtures differ from the GUI
fixtures, so times should not be subtracted from GUI timings to infer layout cost.

| Workload | Median across processes | Range |
|---|---:|---:|
| Typical Markdown, 1,458 characters | 0.950 ms | 0.943–0.987 ms |
| Long Markdown, 16,058 characters | 9.95 ms | 9.62–10.16 ms |
| Mixed-answer streaming, chunk p95 | 1.484 ms | 1.482–1.485 ms |
| Mixed-answer streaming, total | 1,093 ms | 1,086–1,117 ms |
| Unclosed Swift block, chunk p95 | 15.08 ms | 15.07–15.61 ms |
| Unclosed Swift block, total | 5,843 ms | 5,788–5,880 ms |
| First Swift highlight | 222.6 ms | 219.9–226.9 ms |
| Warm Swift highlighting, 10,000 lines | 291.0 ms | 287.0–297.4 ms |

The headless code block has 11,529 characters in 887 fixed 13-character chunks. The mixed answer has
16,058 characters in 1,236 chunks. Streaming percentiles describe differently sized prefixes of a growing
message, not repeated measurements of identical work.

## Functional smoke coverage

An additional single-process run per scenario exercised the other streaming prototypes, the full
10,000-item scroll, appearance changes, and SourceView without highlighting:

```sh
just lab-run S1:A,S1:B,S1:C,S2:A2,S5:A2,S4: --runs 1 --timeout 90
```

All six scenarios completed and produced structured results ([raw smoke results](smoke.json)). S2
reported both `allItemsAvailable = 1` and `reachedStart = 1`. These single runs validate scenario paths;
they are not a repeated comparison of the renderer candidates. System load was higher (11.5–13.9), so
their timing values should not be compared directly with the repeated A′ runs above.

## Findings and next decisions

- Scheduled mixed-answer streaming meets the 16.7 ms callback-p95 criterion in these runs.
- The long unclosed code block does not: p95 is consistently about 34 ms. Track profiling and a targeted
  fix in [issue #77](https://github.com/anesthetised/agenthesia/issues/77).
- A good whole-scenario p95 hides the SourceView completion pause. Setup is quick, but full highlighting
  takes considerably longer and the run includes a pause over 200 ms. Track this in
  [issue #78](https://github.com/anesthetised/agenthesia/issues/78).
- Keep A′ as the baseline while profiling. These measurements identify workloads to fix; they do not
  establish which replacement architecture would be better.
- No renderer speedup is claimed by this change. ADR-0007 used different pacing and opening definitions;
  its GUI numbers are not a before/after baseline for this method. An earlier one-off headless run also
  differed in process/autorelease lifetime and system conditions, so it is not a controlled comparison.

Both follow-ups require owner discussion before an architectural change. First distinguish parsing and
highlighting cost from attribute replacement and row-height/layout work, then choose the smallest fix.
