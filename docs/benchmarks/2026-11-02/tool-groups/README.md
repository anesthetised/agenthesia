# Folded tool calls (#155)

Command: `just lab-run S1:App,S7:App,S9:App --runs 1` per side and round, three rounds, with the sides interleaved
(before, after; after, before; before, after). MacBookPro18,2 (32 GiB, 10 logical CPUs, 120 Hz display), macOS 27.0.1,
Apple Swift 6.4.2, optimized Debug lab, one fresh process per run. The owner approved the workload and left the Mac
alone. *Before* is `764ede4` with the S9 scenario patched in by hand, so its reports show a dirty working tree; *after*
is `ffd0c25` (the same change before later rebases). The reports record 70–72% free memory on every run, and free plus
inactive memory stayed at 45–46%. The 1-minute load average is in the tables. The raw reports are `before.json` and
`after.json` (three reports each, in round order) and `s8-after.json`.

## S1:App, streaming with no tool calls

| | Hitches per run | p95 / p99 frame, ms | Max frame, ms | Apply p95, ms | Load per run |
|---|---|---|---|---|---|
| Before | 1, 0, 0 | 8.3 / 8.3 | 16.7, 9.7, 10.2 | 10.0, 9.8, 9.2 | 8.1, 4.1, 3.0 |
| After | 4, 3, 1 | 8.3 / 8.3 | 27.8, 20.2, 13.5 | 10.2, 9.4, 9.5 | 6.9, 4.5, 3.9 |

## S7:App, tool updates while streaming, on a 200-item history

| | Hitches per run | p95 / p99 frame, ms | Max frame, ms | Apply p95, ms | Load per run |
|---|---|---|---|---|---|
| Before | 18, 21, 18 | 8.3 / 16.7 | 17.0, 16.7, 25.0 | 12.1, 10.7, 9.2 | 7.1, 3.5, 3.1 |
| After | 51, 32, 22 | 10.2, 8.3, 8.3 / 21.5, 16.7, 16.7 | 24.5, 17.0, 17.3 | 14.3, 14.6, 9.6 | 6.5, 3.9, 3.4 |

*Before* shows five cards and *after* one summary row, so this compares behavior, not only code. Frames delivered:
1468, 1469, 1467 before and 1412, 1457, 1467 after.

## S9:App, the same on a 10,000-item history

| | Hitches per run | p95 / p99 frame, ms | Max frame, ms | Apply p95, ms | Load per run |
|---|---|---|---|---|---|
| Before | 43, 37, 47 | 8.3 / 16.7 | 83.4, 86.5, 89.8 | 14.6, 11.0, 16.3 | 6.3, 3.3, 2.9 |
| After | 66, 29, 34 | 12.1, 8.3, 8.3 / 22.0, 16.7, 16.7 | 83.0, 74.2, 67.9 | 12.1, 10.8, 15.2 | 5.9, 3.9, 3.3 |

## S8:App, the group also expanded and collapsed on every tool update (after only)

Three runs at the end of the session: 22, 24, 23 hitches, p95 8.3 ms, p99 16.7–17.5 ms, max 69.5–72.7 ms, apply p95
about 12 ms. There is no *before*, because a group does not exist there.

## Reading

Folding costs nothing visible on a long history: S9 folds and compares 10,000 rows on every chunk and is the same or
better than before, apart from one run at the highest load. That per-chunk work is the only thing the change adds to
S1, on a history 50 times shorter, so folding is an unlikely cause of S1's extra hitches.

The numbers do not settle S1 and S7. Their hitch counts are higher after the change in every round or almost every
round, and the worst *after* run is always the first round, at a load of 6–7. In the two quieter rounds the frame-time
percentiles are unchanged. Hitches stay in the single digits for S1 and move from about 20 to 22–32 for S7. Three runs
cannot tell a small regression from noise; a quiet repeat of S1 and S7 with more runs would.

## Quiet rerun of S1 and S7 (2026-11-02)

Command: `just lab-run S1:App,S7:App --runs 1` per side and round, five rounds, with the sides interleaved (before first
in odd rounds, after first in even ones). Same machine, toolchain and lab build settings as above. *Before* is
`527cb3c` and *after* is `e0b1a66`, the merge of #155; both were clean checkouts, so no scenario was patched in. The
owner left the Mac alone and the script waited for a 1-minute load average below 4 after the builds. The reports record
a load of 1.4–3.2 per run and 85% free memory on every run. The raw reports are `rerun-before.json` and `rerun-after.json` (five reports each, in round
order).

| | Scenario | Hitches per run | Median max frame, ms | p95 / p99 frame, ms | Apply p95, ms |
|---|---|---|---|---|---|
| Before | S1 | 2, 0, 2, 0, 3 | 16.7 | 8.3 / 8.3 | 9.3–9.8 |
| After | S1 | 2, 0, 0, 0, 0 | 12.1 | 8.3 / 8.3 | 9.0–10.2 |
| Before | S7 | 17, 16, 19, 23, 16 | 16.9 | 8.3 / 16.7 | 9.4–13.0 |
| After | S7 | 26, 20, 20, 21, 20 | 22.4 | 8.3 / 16.7 | 9.9–10.2 |

Frames delivered are the same on both sides (S1: 1487–1490; S7: 1463–1473 before, 1465–1471 after).

### Reading

S1 shows no cost: streaming without tool calls is the same or better after the change, so the extra hitches in the
first measurement most likely came from the load of 6–7 in its first round.

S7 is slightly worse after the change, and consistently. The median hitch count is 20 against 17 (the ranges overlap,
16–23 against 20–26), and in four of five runs the worst frame is 22–23 ms where no *before* run exceeded 17 ms: one
frame over the 8.3 ms budget by about two intervals. Percentiles and apply latency are unchanged. S7 is the worst case
for this change: a tool call updates every 10 chunks, and each update rebuilds the summary row and folds the rows again.
A session shows that at most while a tool call is running, so the cost is accepted for now.
