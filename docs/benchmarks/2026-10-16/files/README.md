# Session file operations

Command: `just bench-files`, MacBookPro18,2 (32 GiB, 10 logical CPUs), macOS 27.0.1, Apple Swift 6.4,
Release. The owner approved the workload and resource cost before execution. The measured source was
the `feat/files` implementation based on `72da4fe`; it had not yet been committed. No new dependencies
or network access were needed. The app was closed, and builds/tests were not run during measurement.

One temporary Git repository contains 10,000 short files and one 2 MiB UTF-8 file. After capturing the
baseline, 50 files are changed and committed, and another 50 are modified without staging. Three
sequential runs in one process reuse that fixture. Setup is excluded; there is no warm-up or cache
eviction. Later runs can benefit from OS and Git caches. The fixture is removed after completion.

| Operation | Run 1 | Run 2 | Run 3 | Median |
|---|---:|---:|---:|---:|
| Index 10,001 files | 101.552 ms | 101.106 ms | 101.870 ms | 101.552 ms |
| 20 fuzzy queries, total | 207.694 ms | 192.190 ms | 192.103 ms | 192.190 ms |
| Find 100 changed paths | 80.185 ms | 98.606 ms | 87.378 ms | 87.378 ms |
| Read 2 MiB, bounded | 1.142 ms | 0.712 ms | 0.703 ms | 0.712 ms |

Every run validates 10,001 indexed paths, exactly one known result for each of the 20 queries, all
50 committed plus 50 unstaged changed paths, and the full expected 2,097,152 bytes. All validations
passed. See [raw samples](results.json) and [machine context](environment.json). The Release build log
is retained locally at `.build/files-benchmark-build.log`.

These are initial timings for new APIs. There is no historical implementation of this path to compare,
and three runs do not establish a performance threshold. The query duration is for all 20 searches,
not a single search. FSEvents delivery, refresh debounce, Core/UI scheduling, Markdown rendering and
native layout are outside the measured intervals. These results do not measure end-to-end UI latency.

Load averages were 6.42/7.83/7.10 before the command and 5.22/7.42/6.98 after it; memory-pressure
queries reported 75% system-wide memory free at both points. Those observations bracket the build and
run together, rather than each individual measurement. Background system activity was not controlled.
