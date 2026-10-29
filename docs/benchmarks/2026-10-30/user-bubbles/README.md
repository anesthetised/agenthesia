# User message bubbles (#152)

Command: `just lab-run S1:App,S2:App --runs 3`, MacBookPro18,2 (32 GiB, 10 logical CPUs, 120 Hz display),
macOS 27.0.1, Apple Swift 6.4, optimized Debug lab, one fresh process per run. The owner approved the workload.
*Before* is `b414ee3` (#168), *after* is `58f62ca`. The viewport was 868 pt wide. Builds ran first, then the
measurements, one side after the other, under the shared build lock; other agents were idle but their earlier
builds were still draining. The raw reports are `s1-s2-before.json` and `s1-s2-after.json`.

The machine was not quiet. The 1-minute load average was 37 when the *before* side started and 8 when it ended;
the *after* side ran at 8 down to 6. Free plus inactive memory was 54, 47 and 48% at the three snapshots; the
reports record 62–64% free before and 65–67% after. Per-run load is in the table.

## S1:App, streaming into the production table

| | Hitches per run | p95 / p99 frame, ms | Max frame, ms | Load per run |
|---|---|---|---|---|
| Before | 5, 7, 8 | 8.3 / 8.3 | 20.8 | 24.3, 14.1, 9.6 |
| After | 4, 5, 0 | 8.3 / 8.3 | 9.5–16.7 | 7.0, 6.4, 6.2 |

Apply latency p95 is 10.0–10.7 ms on both sides. Streaming is unchanged or better.

## S2:App, scrolling a long transcript

| | Hitches per run | p95 / p99 frame, ms | Max frame, ms | Load per run |
|---|---|---|---|---|
| Before | 707, 685, 589 | 48.6–52.9 / 52.0–55.8 | 56.7–57.2 | 17.1, 10.3, 8.0 |
| After | 735, 908, 909 | 34.1–49.5 / 39.8–52.5 | 54.3–59.6 | 7.8, 7.2, 6.2 |

## Reading

Inconclusive for scrolling. The hitch count is higher after the change in all three runs (735–909 against
589–707), although the *after* side ran under a lower load. The frame-time percentiles move the other way: p95 and
p99 are lower in two of the three *after* runs, and the maximum frame is unchanged. Three runs on a loaded
machine cannot tell a real regression in the hitch count from noise. A repeat of S2:App alone, with more runs on a
quiet machine and the two sides interleaved, would settle it.
