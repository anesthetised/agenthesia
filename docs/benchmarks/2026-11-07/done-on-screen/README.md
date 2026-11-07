# Done when the result is on screen (#209)

Command: `just lab-run S1:App,S7:App,S9:App --runs 1` per side and round, five rounds, with the sides interleaved
(before first in odd rounds, after first in even ones). MacBookPro18,2 (32 GiB, 10 logical CPUs, 120 Hz display),
macOS 27.0.1, Apple Swift 6.4.2, optimized Debug lab, one fresh process per run. *Before* is `4d00358` (main with #206
and #207), *after* is `e18061c`; both working trees were clean. The owner approved the workload and left the Mac alone,
and asked to start without waiting for a quiet machine, so the runs began right after the lab builds: the 1-minute
load average was 18 (before) and 11 (after) in round 1 and 6–9 in rounds 2–5. Free memory was 59–63% on every run.
The raw reports are `before.json` and `after.json` (five reports each, in round order).

The load makes absolute numbers higher than in the quiet runs of 2026-11-02 (S7 had about 17–20 hitches there, about
110 here); the comparison holds because the sides alternate under the same conditions.

| Scenario | Side | Hitches per round | Median | Frame p95 / p99 (ms, median) | Worst frame per round (ms) | Apply p95 (ms, median) |
|---|---|---|---|---|---|---|
| S1 | Before | 13, 12, 11, 7, 7 | 11 | 8.3 / 8.3 | 53.0, 56.3, 33.6, 17.2, 30.5 | 10.6 |
| S1 | After | 6, 6, 11, 10, 5 | 6 | 8.3 / 8.3 | 18.8, 26.9, 35.2, 20.3, 16.8 | 10.6 |
| S7 | Before | 105, 109, 116, 111, 119 | 111 | 16.7 / 20.8 | 23.4, 25.9, 35.9, 25.6, 85.9 | 13.2 |
| S7 | After | 107, 112, 95, 99, 106 | 106 | 16.7 / 20.9 | 23.6, 23.5, 29.5, 22.3, 25.6 | 13.4 |
| S9 | Before | 120, 121, 67, 113, 142 | 120 | 18.0 / 21.6 | 120.2, 140.0, 141.7, 102.5, 83.4 | 16.0 |
| S9 | After | 115, 120, 133, 121, 130 | 121 | 17.4 / 21.1 | 109.7, 135.2, 138.3, 149.2, 172.8 | 15.6 |

No cost is visible. The scenarios never set an unseen result, so the change reduces to one `nil` check per update and
layout, and the frame-time percentiles and the chunk apply latency are the same on both sides. S1's lower hitch count
after the change and S9's higher worst frames are within the spread of single runs under this load.
