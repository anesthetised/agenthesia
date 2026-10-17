# Transcript inline code links

Command: `just bench-transcript-links`, MacBookPro18,2 (32 GiB, 10 logical CPUs), macOS 27.0.1, Apple
Swift 6.4, Release. The owner approved running benchmarks for this change. The measured source was #29
slice 5 on `feat/clickable-paths`, not yet committed. Builds and tests were not run during measurement;
the app was not running.

200 finished agent rows each contain 20 inline code spans: 10 paths in the index (half absolute under
the session root, half relative with a line), 5 paths missing from it and 5 non-path spans. The index
holds 10,001 paths. Three sequential runs in one process render every row's Markdown, link every row
once, then link again against the same index, as a rescan that finds nothing new does.

| Operation, all 200 rows | Run 1 | Run 2 | Run 3 | Median |
|---|---:|---:|---:|---:|
| Render Markdown (existing cost, for scale) | 117.006 ms | 66.759 ms | 67.594 ms | 67.594 ms |
| Link inline code | 42.589 ms | 41.727 ms | 41.764 ms | 41.764 ms |
| Link again, nothing new | 39.482 ms | 41.529 ms | 40.192 ms | 40.192 ms |

Every run validates exactly 2,000 links. See [raw samples](results.json) and
[machine context](environment.json).

There is no previous implementation of this path, so this is the added cost, shown next to the
rendering every row already pays. Linking costs about 0.2 ms per row. A publication relinks only the
rows `NSTableView` has materialized; other rows are linked when scrolled into view, so 20 visible rows
cost about 4 ms per index publication, and publications are limited to one per second. The relink after
an unchanged index costs the same as the first, because each row's spans are parsed again; caching
the parsed spans per row is the next step if this shows up in profiles. Table updates and native layout
are outside the measured intervals.

Load averages were 11.01/11.02/12.45 before the command and 9.70/10.74/12.33 after it; free memory
was 87% before and 88% after.
