# Session reduction and publication

Command: `just bench-session`, on MacBookPro18,2 (M1 Max, 32 GiB), macOS 27.0.1, Release Swift build. Three sequential runs in one
process, 10,000 stored ACP text-chunk events per case, producing one 130,000-character message.
The workload was approved before execution. No GUI or agent process runs. Fixture creation and
SQLite writes occur before timing; measured work is JSON decoding, pure reduction, and retaining
published value snapshots across subsequent mutations.

There was no session reducer before #17. The baseline is the same new reducer publishing every chunk;
the comparison publishes every 16 chunks, modeling multiple arrivals between display callbacks.
This does not simulate a real display clock or measure rendering, Observation delivery, disk latency,
controller task scheduling, scroll performance, or end-to-end session latency.

| Publication cadence | Publications | Run 1 | Run 2 | Run 3 | Median |
|---|---:|---:|---:|---:|---:|
| Every chunk | 10,000 | 91.55 ms | 88.22 ms | 87.62 ms | 88.22 ms |
| Every 16 chunks | 625 | 71.45 ms | 69.36 ms | 69.43 ms | 69.43 ms |

The median measured duration decreases by 21.3%, and snapshot assignments decrease by 16×. Every case
asserts the same final sequence and text length. This supports coalescing publications; it is not an
FPS claim or an absolute performance threshold. The live view uses its display link rather than a
fixed chunk count. Raw samples are in [results.json](results.json).

## After recording fixes

The same approved workload was repeated after making recording tolerate undecodable update bodies
and preserve notification metadata. Medians were 92.58 ms per-chunk and 72.55 ms coalesced (three runs,
[raw samples](review-results.json)), versus 88.22 ms and 69.43 ms above. The coalesced median is 4.5%
higher in this run; these are separate, unpaired measurements, not evidence of a statistically
significant regression or improvement. Publication counts and final output are unchanged. The
benchmark does exercise the revised recording decoder, but does not measure the live router,
permission handling, transaction latency, or the config-only equality check.

Free RAM percentage and load averages were not captured for either measurement set. The system load
at measurement time is therefore unknown; current readings cannot reconstruct it. Future comparisons
should record both before each run and use paired measurements before attributing timing changes to code.
