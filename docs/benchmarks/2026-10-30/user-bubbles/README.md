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

Inconclusive for scrolling, settled by the quiet rerun below. The hitch count is higher after the change in all three runs (735–909 against
589–707), although the *after* side ran under a lower load. The frame-time percentiles move the other way: p95 and
p99 are lower in two of the three *after* runs, and the maximum frame is unchanged. Three runs on a loaded
machine cannot tell a real regression in the hitch count from noise. A repeat of S2:App alone, with more runs on a
quiet machine and the two sides interleaved, would settle it.

## Quiet rerun of S2:App (2026-11-01)

Command: `just lab-run S2:App --runs 1` per side and round, five rounds, with the sides interleaved (before first in
odd rounds, after first in even ones). Same machine, toolchain and lab build settings as above. *Before* is
`b414ee3`, *after* is `aa141c0`, which only adds this directory to `58f62ca`. No other agent ran builds; the owner
left the Mac alone. The 1-minute load average was 14 at the first run (just after the two lab builds) and 3–6 for the
others; the reports record 80–81% free memory, and free plus inactive memory stayed at 50%. The raw reports are
`s2-rerun-before.json` and `s2-rerun-after.json` (five reports each, in round order).

| | Frames (hitches) per run | Median p50 / p95 / p99, ms | Max frame, ms | Missed frames, median | Load per run |
|---|---|---|---|---|---|
| Before | 874, 909, 881, 901, 881 | 28.0 / 36.0 / 44.4 | 49.3–54.6 | 2113 | 8.6, 4.5, 3.7, 3.1, 3.2 |
| After | 936, 933, 977 (966), 944, 956 | 27.0 / 30.5 / 32.8 | 34.2–43.3 | 2046 | 6.4, 5.0, 3.4, 3.2, 2.7 |

At 14,400 pt/s neither side reaches the 120 Hz budget, so nearly every delivered frame counts as a hitch: the hitch
count follows the number of frames delivered in the 25-second scroll, and a higher count means *more* frames, not
worse ones. That explains the higher counts in the first measurement. With the sides interleaved, the change
delivers about 6% more frames, lowers p95 by 15% and p99 by 26%, caps the worst frame at 43 ms instead of 55 ms and
misses about 3% fewer frames. Scrolling is not slower; it is slightly smoother.
