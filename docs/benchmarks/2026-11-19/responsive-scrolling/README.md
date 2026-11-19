# Responsive scrolling (#396, step 1)

Step 1 of #396 (`e74c9ca`) drops `TranscriptScrollView`'s `scrollWheel(with:)` override, which made the transcript
incompatible with responsive scrolling. MacBookPro18,2 (32 GiB, 10 logical CPUs, 120 Hz display), macOS 27.0.1, Apple
Swift 6.4.2, optimized Debug lab (`just lab-build`), one fresh process per run, Docker stopped. The owner approved each
workload. *Before* is `1394723`, branch `perf/396-measurement` with `e74c9ca` reverted (its reports show the runner
scripts of `d2d0a56` copied in by hand); *after* is `d2d0a56`. The sides were interleaved in every series.

## 2026-11-10: wheel, S2 and the streaming scenarios

Three rounds, 1-minute load 2.6–8.0 between runs, 76–79 % free memory. S12 runs with
`scripts/app-check/wheel-scroll.sh`, the rest with `scripts/bench.py lab`. The raw reports and traces were kept in a
temporary folder that macOS has since cleaned; the medians and ranges below are from the summary posted to #396.

### S12, hitch time per second of scrolling

S2's 10,000 items in a 1240 x 760 pt window, 15 s up from the end and 15 s down. Target under 5 ms/s, 10 at worst.

| Input | Before, median | After, median | Rounds, before → after |
|---|---|---|---|
| Wheel, 3 lines × 60/s, no phases | 385 | 390 | 537 → 390, 358 → 326, 385 → 409 |
| Gesture, 20 pt × 120/s with phases, no momentum | 84 | 71 | 93 → 71, 83 → 52, 84 → 72 |

The longest hitch did not change: about 320–450 ms for the wheel, 58–75 ms for the gesture.

### S2, after only, five runs

| Table | Frame p95 | Excess over budget | Hitches | Reached the start in 25 s |
|---|---|---|---|---|
| Prototype (A2) | 16.7 ms | 4.9 s (4.0–7.0) | 582 | 4 of 5 |
| App | 35.0 ms (33.3–37.7) | 17.6 s | 889 | 0 of 5 |

### Streaming scenarios, medians of three rounds, before → after

| Scenario | Excess, ms | Hitches | Apply p95, ms |
|---|---|---|---|
| S1 Stream | 1061 → 1041 | 127 → 124 | 12.3 → 12.1 |
| S6 Long unclosed code | 4721 → 4728 | 254 → 254 | 44.2 → 43.0 |
| S7 Tool updates | 1142 → 1123 | 136 → 134 | 13.2 → 13.1 |
| S8 Group toggles | 1469 → 1476 | 131 → 133 | 16.0 → 15.9 |
| S9 Tool updates, 10k items | 1697 → 1846 | 171 → 191 | 15.6 → 16.1 |
| S10 Thoughts | 1279 → 1247 | 152 → 146 | 11.4 → 11.3 |

## 2026-11-19: S9

### Profile

One run per side of `S9:App` recorded system-wide under Animation Hitches with Points of Interest and Time Profiler,
counted over the `Scenario` signpost interval (12.8 s); load 4.4 before and 6.6 after, 63 % and 55 % free memory. One
run per side is enough to locate the work, not to size it.

| | Before | After |
|---|---|---|
| Display-link callbacks | 1429 | 1328 |
| Main-thread samples (1 ms) | 8846 | 8623 |
| Main-thread ms per callback | 6.19 | 6.49 |
| `TranscriptTableController.update` per callback | 2.06 | 2.30 |
| `TranscriptMessage.init(group:…)` samples | 1 | 27 |
| `Cell` intervals, all of the run | 72 | 80 |
| `-[NSTableView prepareContentInRect:]` samples | 50 | 53 |

The main thread does about 5 % more work per frame. The new part is the tool group's row: the answer streams below
it, so it leaves the viewport early on. Before step 1 the table then dropped it. With responsive scrolling it stays
prepared above the visible rect, so `update` asks for its message on every batch, rebuilding the five calls' summary,
and compares it. Rows are not made or prepared more often: `Cell` and `prepareContentInRect` are level. Both sides spend
most of a frame on the streamed answer, the same in both: `renderMarkdown` of the whole answer (0.66 ms per callback)
and the layout `update` forces (about 1 ms). Comparing the 10,002 rows with the last shown ones (`Array ==` under
`update`) took 73 samples after and 4 before; that is not explained yet. Frames already took about three quarters of the
8.3 ms budget, so 0.3 ms more pushes a disproportionate share of them over it.

### Confirmation

`scripts/bench.py lab S9:App --runs 1` per side and round, three rounds (before, after each time), 2026-11-19
00:13–00:18 UTC; 1-minute load 4.4–8.9 as the reports record it (each run started below 8), 63–65 % free memory. Raw
reports: `s9-before.json`, `s9-after.json`, in round order.

| | Excess, ms | Hitches | p95 / p99 frame, ms | Max frame, ms | Apply p95, ms | Load | Frames |
|---|---|---|---|---|---|---|---|
| Before | 1535, 1604, 1688 | 103, 106, 124 | 19.5, 19.0, 19.3 / 22.8, 23.2, 22.4 | 97.4, 122.7, 132.3 | 16.3, 17.9, 16.5 | 4.4, 6.3, 5.7 | 1345, 1337, 1327 |
| After | 1778, 1603, 1759 | 127, 121, 129 | 19.5, 19.1, 19.5 / 23.0, 22.4, 22.6 | 118.1, 115.1, 132.3 | 16.0, 17.0, 15.8 | 5.8, 6.2, 8.9 | 1316, 1337, 1323 |

The medians, 1604 → 1759 ms and 106 → 127 hitches, repeat 2026-11-10's +9 % in excess time, but this time the ranges
overlap.

## Reading

- The wheel gains nothing measurable; the gesture gains about 15 %, in all three rounds. Both stay far from the
  target, the wheel about 80 times over it: the hitches are rows built as they scroll in, which steps 2–4 address.
- S9 costs about 9 % in excess time from one row kept prepared off screen. The step lands with it; the larger cost of
  S9, the streamed answer's full render and the forced layout on every batch, is the same on both sides.
