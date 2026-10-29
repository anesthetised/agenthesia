# Transcript column and Copy on hover (#151)

Command: `just lab-run S1:App,S2:App --runs 3` and `just lab-run S1:App --runs 5`, MacBookPro18,2 (32 GiB,
10 logical CPUs, 120 Hz display), macOS 27.0.1, Apple Swift 6.4, optimized Debug lab, one fresh process per run.
The owner approved running S1 and S2 for this change. *Before* is `7eb89cf` (the composer card, #156, without
the table change); *after* is `3a9b05f`. The viewport was 868 pt wide, so the 720 pt column applies. The app was
not running; builds and tests did not run during a measurement. The raw reports are `s1-s2-before.json`,
`s1-s2-after.json`, `s1-before.json` and `s1-after.json`.

The first batch (3 runs of S1 and S2) ran under a 1-minute load average of 11–18 and 58–72% free memory; the
second batch (S1, 5 runs each) ran at 5.8–11.4 and 67–70% free memory. The 1-minute load average was 16.4 before
the second batch, 6.5 between its two sides and 5.8 after it.

## S1:App, streaming into the production table (hitches per run)

| Batch | Before | After |
|---|---|---|
| 1 (3 runs, high load) | 3, 1, 11 | 12, 50, 50 |
| 2 (5 runs) | 0, 0, 0, 1, 3 | 7, 19, 1, 4, 4 |

Frame p95 is 8.3 ms in every run; p99 is 8.3 ms except three runs after the change (16.7 ms). Apply latency p95
is 9.8–10.4 ms before and 9.5–11.4 ms after. Maximum frame time is 8.3–22.7 ms before and 18.9–27.5 ms after.

## S2:App, scrolling a long transcript (3 runs, high load)

| | Hitches per run | p95 / p99 frame, ms | Max frame, ms |
|---|---|---|---|
| Before | 620, 533, 520 | 53.0–54.3 / 56.3–57.8 | 59.6–63.9 |
| After | 688, 473, 514 | 51.9–62.4 / 56.6–66.2 | 64.9–84.4 |

## Reading

Scrolling is unchanged within the noise of a loaded machine. Streaming shows a small increase in single-frame
hitches (median 4 against 0 in the quieter batch) with the same p95 frame and apply latency; the first batch's
larger numbers coincide with a load average above 11 and are not conclusive. The change narrows the text from
820 to 720 pt, which wraps more lines per chunk, and replaces two fixed edge constraints with a centered
column (`centerX`, `width <= 720`, `leading >= 24`, and a 999-priority fill width). If the hitches matter, the
next step is to compute the column's edges in `layout()` from `TranscriptColumn` instead of solving them.
