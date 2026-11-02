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
