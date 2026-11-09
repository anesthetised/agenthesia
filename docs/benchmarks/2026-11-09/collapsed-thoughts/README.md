# Collapsed thoughts (#223)

Command: `just lab-run S1:App,S7:App,S9:App,S10:App --runs 1` per side and round, three rounds, with the sides
interleaved (before, after; after, before; before, after), 2026-11-09 21:33–21:41. MacBookPro18,2 (32 GiB, 10 logical
CPUs, 120 Hz display), macOS 27.0.1, Apple Swift 6.4.2, optimized Debug lab, one fresh process per run. The owner
approved the workload. *Before* is `916a81c` (`main`) with the S10 scenario patched in by hand, so its reports show a
dirty working tree; there a thought is a row that streams its full text. *After* is `50f1ffd`, #339's head rebased onto
`916a81c`, where thoughts fold into one collapsed row. The reports record 76–79% free memory on every run; the runner's
log recorded 7–12% free and 40–44% free plus inactive memory (`vm_stat`). The 1-minute load average is in the tables:
the first round started right after the builds, at a load of 36 that fell to 13 during it. The raw reports are
`before.json` and `after.json` (three reports each, in round order).

## S1:App, streaming with no tool calls

| | Hitches per run | p95 / p99 frame, ms | Max frame, ms | Apply p95, ms | Load per run |
|---|---|---|---|---|---|
| Before | 8, 3, 3 | 8.3 / 8.3 | 79.5, 20.3, 20.6 | 10.7, 10.3, 10.2 | 23.0, 4.5, 5.5 |
| After | 9, 2, 10 | 8.3 / 8.3 | 42.8, 16.7, 39.6 | 10.3, 9.7, 10.8 | 11.1, 7.0, 4.8 |

Frames delivered: 1473, 1485, 1485 before and 1476, 1487, 1474 after.

## S7:App, tool updates while streaming, on a 200-item history

| | Hitches per run | p95 / p99 frame, ms | Max frame, ms | Apply p95, ms | Load per run |
|---|---|---|---|---|---|
| Before | 43, 78, 87 | 8.3, 12.8, 13.5 / 16.7, 21.8, 21.1 | 20.8, 25.2, 24.9 | 11.1, 11.5, 11.0 | 18.6, 4.2, 5.9 |
| After | 31, 44, 108 | 8.3, 8.3, 14.4 / 16.7, 21.8, 21.2 | 26.1, 24.6, 25.1 | 10.2, 11.3, 14.2 | 11.1, 7.1, 5.3 |

Frames delivered: 1446, 1382, 1382 before and 1457, 1422, 1365 after.

## S9:App, the same on a 10,000-item history

| | Hitches per run | p95 / p99 frame, ms | Max frame, ms | Apply p95, ms | Load per run |
|---|---|---|---|---|---|
| Before | 77, 86, 103 | 16.7, 15.5, 13.6 / 16.7, 22.7, 21.6 | 115.1, 111.9, 95.9 | 11.9, 15.3, 11.5 | 16.8, 3.9, 6.0 |
| After | 51, 84, 109 | 8.3, 13.4, 18.6 / 17.0, 23.0, 21.9 | 108.2, 109.4, 124.2 | 14.1, 16.9, 15.4 | 9.2, 6.6, 5.7 |

Frames delivered: 1420, 1369, 1396 before and 1443, 1371, 1359 after.

## S10:App, two thoughts and then the S1 answer, on a 200-item history

| | Hitches per run | p95 / p99 frame, ms | Max frame, ms | Apply p95, ms | Load per run |
|---|---|---|---|---|---|
| Before | 14, 6, 7 | 8.3 / 8.3 | 20.6, 24.1, 23.6 | 10.3, 9.9, 9.8 | 13.3, 3.8, 6.0 |
| After | 64, 105, 197 | 8.3, 8.3, 17.0 / 16.7, 18.4, 18.1 | 31.5, 24.8, 39.4 | 9.6, 10.5, 13.3 | 7.7, 5.2, 5.2 |

Frames delivered: 2284, 2288, 2286 before and 2234, 2191, 2090 after.

## Reading

S1, S7 and S9 are within noise: they do not stream thoughts, and the extra fold of thought runs costs nothing visible
on a 10,000-item history. Their spread comes from the load, which was high in the first round.

S10 regressed, and the regression holds at the lowest load of the session (round 3, load 5.2: 197 hitches against 7).
Apply latency is unchanged, so the cost is in the frames, not in folding or rendering the Markdown. While a thought
streams collapsed, its header `Thinking… <last line>` changes with every chunk; the table treated that as a changed
header, rebuilt the header's views (label, icon, disclosure and Copy button) and measured the row's height again on
every chunk. *Before*, the streaming row appended to its text view in place.

The fix (in #339): when only the text of a one-line, truncating header changes, the table sets the label's text in
place and does not measure the row again; a collapsed thought keeps its views and its height while it streams. A hosted
test checks that the label and the row stay the same objects and the height does not change, and fails without the fix.

## Second run (after the fix)

Command: `just lab-run S1:App,S10:App --runs 1` per side and round, three rounds with the sides interleaved (before,
after; after, before; before, after), 2026-11-09 23:05–23:10, approved by the owner, who left the Mac alone. *Before* is
the same `916a81c` with the S10 patch; *after* is `1656500`, #339's head with the in-place header update. The 1-minute
load average stayed at 4–8 and free memory at 76–77 % on every run (free plus inactive 39–41 %). The raw reports are
`fix-before.json` and `fix-after.json` (three reports each, in round order).

## S1:App

| | Hitches per run | p95 / p99 frame, ms | Max frame, ms | Apply p95, ms | Load per run | Free memory, % | Frames |
|---|---|---|---|---|---|---|---|
| Before | 8, 7, 8 | 8.3, 8.3, 8.3 / 8.3, 8.3, 8.3 | 21.1, 20.7, 19.0 | 10.1, 10.8, 10.7 | 4.4, 4.2, 4.5 | 76, 77, 77 | 1479, 1482, 1481 |
| After | 11, 10, 10 | 8.3, 8.3, 8.3 / 8.3, 8.3, 8.3 | 20.6, 29.5, 28.4 | 10.8, 9.9, 10.9 | 7.6, 4.8, 4.3 | 77, 77, 77 | 1478, 1480, 1481 |

## S10:App

| | Hitches per run | p95 / p99 frame, ms | Max frame, ms | Apply p95, ms | Load per run | Free memory, % | Frames |
|---|---|---|---|---|---|---|---|
| Before | 17, 11, 10 | 8.3, 8.3, 8.3 / 8.3, 8.3, 8.3 | 25.3, 23.3, 23.3 | 10.8, 10.5, 10.2 | 4.8, 4.0, 4.8 | 76, 77, 77 | 2276, 2283, 2284 |
| After | 16, 19, 16 | 8.3, 8.3, 8.3 / 8.3, 8.3, 8.3 | 29.0, 30.1, 29.9 | 10.2, 10.1, 10.6 | 6.4, 4.3, 4.8 | 77, 77, 77 | 2280, 2274, 2277 |

### Reading

The S10 regression of the first run is gone: hitches per run are 16, 19, 16 after against 17, 11, 10 before (64, 105,
197 in the first run), p95 and p99 stay at one 120 Hz frame (8.3 ms) on both sides, the frames delivered match (about
2280), and apply p95 is unchanged. The worst single frame is about 6 ms longer after (29–30 ms against 23–25 ms), and
S1 shows two or three more hitches per run with a worst frame up to 29 ms; both are within the run-to-run spread seen
before and are not visible as dropped frames. The fix holds: a streamed thought chunk now costs about what it did
before #223.
