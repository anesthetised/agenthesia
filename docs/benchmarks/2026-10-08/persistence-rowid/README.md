# Event-table layout comparison — 2026-10-08

Follow-up to [PR #95](https://github.com/anesthetised/agenthesia/pull/95) and the
[first append comparison](../persistence/README.md). Ordinary rowid storage reduces the measured
footprint of 1 KiB events by about 70%. Timing results favor batched rowid writes in this run, but
background load differed substantially between phases.

## Method and changes

- Before: `27bebed`, `WITHOUT ROWID`, with numeric system-load snapshots.
- After: `a6e02a4`, ordinary rowid event table, retaining the composite primary key and all triggers.
- The new connection also enables recursive triggers. A regression test demonstrated that simply
  dropping `WITHOUT ROWID` allows `INSERT OR REPLACE` to overwrite an existing hidden rowid without
  firing the delete guard. Enabling recursive triggers closes that path. Payload validation, journal
  mode, synchronous settings, benchmark code and workload are unchanged.
- This adjusts the unreleased `v1` schema. Experimental databases from older PR revisions retain
  their original physical layout; both phases here create fresh databases.
- MacBookPro18,2, arm64, 32 GiB RAM, macOS 27.0.1, Apple Swift 6.4, Release build.
- Approved workload: 1 KiB JSON, batches 1/16/64, offered rates 100/1,000 events/s and saturation,
  two-second arrival windows, three sequential fresh-process repetitions per scenario and phase.
- All 54 processes verified replayed sequence numbers and payload bytes outside timing. None hit
  the 65,536-event cap. Databases were deleted between processes. No other build or test was deliberately
  run concurrently with measurements; general machine activity was not controlled.

```sh
# At 27bebed:
just bench-persistence --runs 3 --timeout 15 --output .build/benchmarks/persistence-rowid-before
# At a6e02a4:
just bench-persistence --runs 3 --timeout 15 --output .build/benchmarks/persistence-rowid-after
```

[Before samples](before.json) and [after samples](after.json) retain every observation and resource
snapshot. Build logs and per-process stdout remain in those local output directories. See the
[benchmark guide](../../../BENCHMARKS.md) for pacing and resource limits.

## Storage

Median final database bytes divided by committed events in the saturation runs, including the
composite-key index, other tables and fixed schema overhead:

| Batch | WITHOUT ROWID, bytes/event | Rowid, bytes/event | Reduction |
|---:|---:|---:|---:|
| 1 | 4,692.8 | 1,435.6 | 69.4% |
| 16 | 4,683.0 | 1,424.3 | 69.6% |
| 64 | 4,682.6 | 1,424.5 | 69.6% |

Fixed database overhead is proportionally larger in the short paced scenarios; these ratios are not
universal per-row costs. A separate regression test pins 4 KiB pages, writes 256 1 KiB events and
requires less than 2 KiB/event of database growth including the index. It failed with the old layout
and passes with rowid storage. This directly guards the overflow-page cliff without a timing threshold.

## Timing

Each cell is the median of three per-process measurements. Append p95 measures a whole batch;
percentiles are not pooled across runs.

| Batch | Offered events/s | Before events/s | After events/s | Before append p95, ms | After append p95, ms |
|---:|---:|---:|---:|---:|---:|
| 1 | 100 | 99.9 | 99.8 | 4.748 | 4.584 |
| 1 | 1000 | 999.2 | 999.2 | 0.790 | 0.707 |
| 1 | Saturation | 2,175.4 | 2,173.5 | 0.606 | 0.539 |
| 16 | 100 | 99.3 | 99.6 | 8.042 | 9.379 |
| 16 | 1000 | 995.9 | 997.2 | 7.470 | 6.181 |
| 16 | Saturation | 13,085.5 | 16,626.8 | 1.421 | 1.159 |
| 64 | 100 | 97.7 | 99.2 | 10.854 | 8.010 |
| 64 | 1000 | 991.7 | 995.2 | 14.046 | 9.915 |
| 64 | Saturation | 19,867.2 | 25,506.3 | 3.554 | 2.885 |

Saturation throughput medians changed by −0.1%, +27.1% and +28.4% for batches 1, 16 and 64.
At 1,000 offered events/s, single-event runs committed 2,000/2,000/2,000 events before and
1,999/1,999/1,999 after. Batch 16 committed 2,000/1,984/2,000 before and all 2,000 after.
All other paced scenarios committed every scheduled full batch. Partial batches are excluded;
batch 64 at 100 events/s schedules only three commits, so its p95 is the maximum of three observations.

## Resource snapshots and limits

| Counter, across start/end snapshots | Before | After |
|---|---:|---:|
| Active cores | 10 | 10 |
| One-minute load average | 4.46–6.04 | 8.04–11.16 |
| Free memory (`kern.memorystatus_level`) | 79–80% | 73–80% |

The after phase had higher load and more variable throughput. Load average is not CPU utilization,
and snapshots cannot attribute or remove background interference. All before runs preceded all after
runs, so this is not a randomized controlled timing comparison. Keep the measured improvements as
observations, not a guaranteed speedup. The storage reduction and regression test support the layout
change independently of those timing claims.

Batch assembly time is excluded from append latency: at 100 events/s, a 64-event batch adds up to
630 ms for its first event before append even starts. The test covers one writer and fresh databases,
not long sessions, replay contention, mixed payload sizes, UI latency or crash durability. WAL remains
unchanged; the live session workload in #17 should guide any further journal or batching decision.
