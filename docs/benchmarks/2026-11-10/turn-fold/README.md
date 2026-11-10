# Turn fold (#341)

Command: `just lab-run S1:App,S7:App,S9:App,S10:App,S11:App --runs 1` per side and round, three rounds, with the sides
interleaved (before, after; after, before; before, after), 2026-11-10 02:47–02:57. MacBookPro18,2 (32 GiB, 10 logical
CPUs, 120 Hz display), macOS 27.0.1, Apple Swift 6.4.2, optimized Debug lab, one fresh process per run. The owner
approved the workload. *Before* is `f089e49` (`main`) with the S11 scenario patched in by hand (the patch in #343's
description), so its reports show a dirty working tree; there nothing folds. *After* is `952f7a0`, #343's first head,
where every finished turn folds under `Worked for …`. The 1-minute load average stayed at 4–8 and the reports record
74–76 % free memory on every run; the runner's log recorded 17–22 % free and 43–45 % free plus inactive memory
(`vm_stat`). The raw reports are `before.json` and `after.json` (three reports each, in round order).

S11 streams a new turn (a prompt, S7's five tool calls with their updates, S10's two thoughts and the S1 answer) below
a 10,000-item history of finished turns; on the *after* side every history turn folds, and the new turn folds when its
answer is complete, inside the measured interval.

## S1:App

| | Hitches per run | p95 / p99 frame, ms | Max frame, ms | Apply p95, ms | Load per run | Free memory, % | Frames |
|---|---|---|---|---|---|---|---|
| Before | 8, 10, 9 | 8.3, 8.3, 8.3 / 8.3, 8.3, 8.3 | 16.7, 20.2, 19.3 | 10.3, 9.7, 9.6 | 8.1, 6.2, 4.8 | 75, 76, 76 | 1481, 1478, 1479 |
| After | 8, 11, 7 | 8.3, 8.3, 8.3 / 8.3, 8.3, 8.3 | 21.5, 20.5, 18.9 | 10.1, 10.6, 10.1 | 7.1, 4.1, 8.4 | 75, 76, 76 | 1479, 1477, 1481 |

## S7:App

| | Hitches per run | p95 / p99 frame, ms | Max frame, ms | Apply p95, ms | Load per run | Free memory, % | Frames |
|---|---|---|---|---|---|---|---|
| Before | 50, 94, 103 | 8.3, 13.5, 14.3 / 16.7, 22.0, 21.2 | 29.4, 25.2, 31.4 | 11.7, 11.6, 13.2 | 7.8, 5.8, 4.4 | 75, 76, 76 | 1438, 1364, 1366 |
| After | 74, 82, 107 | 13.0, 14.6, 14.2 / 23.1, 22.3, 20.7 | 34.1, 25.5, 32.2 | 12.5, 12.0, 13.1 | 5.9, 3.9, 7.3 | 75, 75, 76 | 1366, 1359, 1370 |

## S9:App

| | Hitches per run | p95 / p99 frame, ms | Max frame, ms | Apply p95, ms | Load per run | Free memory, % | Frames |
|---|---|---|---|---|---|---|---|
| Before | 60, 131, 127 | 8.3, 19.6, 19.2 / 16.7, 22.7, 22.5 | 119.8, 119.3, 113.1 | 14.9, 16.4, 15.6 | 7.9, 5.6, 3.8 | 75, 76, 76 | 1433, 1335, 1336 |
| After | 100, 99, 124 | 20.6, 19.8, 18.4 / 23.9, 23.2, 21.7 | 129.8, 124.4, 125.7 | 17.9, 17.1, 15.6 | 6.3, 4.1, 6.4 | 75, 74, 76 | 1329, 1341, 1350 |

## S10:App

| | Hitches per run | p95 / p99 frame, ms | Max frame, ms | Apply p95, ms | Load per run | Free memory, % | Frames |
|---|---|---|---|---|---|---|---|
| Before | 24, 21, 22 | 8.3, 8.3, 8.3 / 16.7, 10.0, 8.4 | 33.3, 31.7, 30.1 | 10.5, 10.6, 10.0 | 6.6, 4.7, 5.1 | 75, 76, 76 | 2272, 2274, 2274 |
| After | 26, 22, 17 | 8.3, 8.3, 8.3 / 12.7, 8.3, 8.3 | 32.4, 33.2, 32.2 | 9.5, 10.3, 9.6 | 6.0, 6.9, 5.4 | 75, 76, 76 | 2267, 2274, 2278 |

## S11:App

| | Hitches per run | p95 / p99 frame, ms | Max frame, ms | Apply p95, ms | Load per run | Free memory, % | Frames |
|---|---|---|---|---|---|---|---|
| Before | 94, 153, 142 | 11.5, 14.4, 13.8 / 23.5, 21.4, 21.3 | 73.3, 114.5, 124.0 | 12.1, 14.5, 14.3 | 6.3, 5.4, 4.3 | 75, 76, 75 | 2125, 2074, 2083 |
| After | 176, 179, 227 | 19.6, 18.5, 18.4 / 24.0, 23.0, 21.4 | 128.6, 122.7, 121.0 | 16.9, 16.8, 17.6 | 5.0, 5.9, 4.7 | 75, 76, 76 | 2007, 2023, 1998 |

## Reading

S1 and S10 are within noise, and S7 roughly too: they stream on a 200-item history, where folding costs little.

**S11 regressed:** 176, 179 and 227 hitches per run after against 94, 153 and 142 before, p95 frames of 18.4–19.6 ms
against 11.5–14.4 ms, about 80 fewer frames delivered, and apply p95 up from 12.1–14.5 ms to 16.8–17.6 ms. S9 drifts the
same way, mostly in the first round (apply p95 15.6–17.9 ms against 14.9–16.4 ms, p95 frame 20.6 ms against 8.3 ms).
The apply latency rising with the history's length points at work proportional to the transcript on every update:
the first head folded every row again on each state change, as before #341, and added a second scan of all items for
the turns' spans, each item through a closure (in the prototype a dictionary lookup and a string comparison). On a
10,000-item history that is two full passes per streamed chunk.

The fix (in #343): `TranscriptFolder` keeps the rows and folds of everything before the last turn's first prompt, which
can no longer change (items only append, and a turn before the last has its end, its time and the kinds of its items
fixed), and folds again only the last turn's items on each update. A change of expansion, a user's action, folds
everything once. A streamed chunk now folds the running turn's items, not the history's, which is less than before
#341; the table still compares the new row list with the shown one, as it did before.
The prototype uses the same folder for S11 and the plain fold, unchanged, for the other scenarios. Tests check that
the folder's rows equal a full fold after every appended item and that a streamed chunk folds the same number of items
below one finished turn or four; that test fails when the folder starts over on every update.

## Second run (after the fix)

Command: `just lab-run S1:App,S9:App,S11:App --runs 1` per side and round, three rounds with the sides interleaved
(before, after; after, before; before, after), 2026-11-10 03:17–03:23, approved by the owner, who left the Mac alone.
*Before* is the same `f089e49` with the S11 patch (the same build as the first run); *after* is `0c7557e`, #343's head
with `TranscriptFolder`. The 1-minute load average stayed at 3.9–5.7, free memory at 75–77 % on every run, free plus
inactive memory at 38–39 %. The raw reports are `fix-before.json` and `fix-after.json` (three reports each, in round
order). Missed frames (`estimatedMissed`) and excess time are added, since S11's frame p95 sits between two modes and
jumps when a few dozen frames change class (a point raised by an independent review of the first run).

## S1:App

| | Hitches | Missed frames | Excess, s | p95 / p99 frame, ms | Max frame, ms | Apply p95, ms | Load | Free memory, % | Frames |
|---|---|---|---|---|---|---|---|---|---|
| Before | 8, 8, 8 | 9, 8, 9 | 0.08, 0.07, 0.08 | 8.3, 8.3, 8.3 / 8.3, 8.3, 8.3 | 20.9, 19.9, 29.1 | 9.6, 9.9, 10.2 | 4.3, 5.3, 3.9 | 76, 76, 77 | 1479, 1480, 1483 |
| After | 8, 12, 9 | 8, 14, 11 | 0.07, 0.12, 0.09 | 8.3, 8.3, 8.3 / 8.3, 8.3, 8.3 | 19.7, 30.3, 29.2 | 10.3, 10.4, 9.6 | 4.7, 5.7, 4.4 | 76, 76, 77 | 1480, 1478, 1481 |

## S9:App

| | Hitches | Missed frames | Excess, s | p95 / p99 frame, ms | Max frame, ms | Apply p95, ms | Load | Free memory, % | Frames |
|---|---|---|---|---|---|---|---|---|---|
| Before | 87, 113, 115 | 165, 189, 190 | 1.37, 1.58, 1.59 | 16.1, 19.4, 18.9 / 22.4, 22.8, 22.1 | 119.6, 112.4, 107.6 | 15.6, 16.7, 16.4 | 3.9, 4.7, 4.0 | 76, 76, 76 | 1365, 1340, 1339 |
| After | 91, 102, 128 | 170, 181, 185 | 1.42, 1.51, 1.56 | 17.9, 19.5, 18.9 / 23.0, 22.5, 21.9 | 100.2, 113.0, 113.3 | 15.3, 17.0, 16.5 | 4.7, 5.2, 4.5 | 76, 76, 76 | 1360, 1348, 1344 |

## S11:App

| | Hitches | Missed frames | Excess, s | p95 / p99 frame, ms | Max frame, ms | Apply p95, ms | Load | Free memory, % | Frames |
|---|---|---|---|---|---|---|---|---|---|
| Before | 103, 125, 133 | 187, 197, 200 | 1.56, 1.64, 1.68 | 12.3, 13.3, 13.7 / 22.2, 21.9, 21.4 | 107.0, 116.1, 114.3 | 14.4, 14.7, 14.9 | 4.5, 4.6, 4.5 | 76, 77, 76 | 2104, 2096, 2091 |
| After | 93, 112, 129 | 142, 193, 152 | 1.20, 1.61, 1.27 | 12.1, 12.7, 13.5 / 21.4, 22.1, 20.5 | 82.1, 136.6, 71.6 | 11.3, 13.8, 13.6 | 5.5, 4.6, 4.2 | 75, 76, 76 | 2148, 2098, 2140 |

### Reading

The regression is gone. S11 now does better than before #341: 142–193 missed frames against 187–200, 1.20–1.61 s of
excess against 1.56–1.68 s, apply p95 11.3–13.8 ms against 14.4–14.9 ms and more frames delivered (2098–2148 against
2091–2104); a streamed chunk in the running turn folds only that turn instead of the whole history. S9 (no fold) and S1
are within the run-to-run spread on every measure. The first run's S9 drift was round 1's *before* being an outlier
across scenarios, not the change.
