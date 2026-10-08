# Persistence append comparison — 2026-10-08

Review follow-up for [PR #95](https://github.com/anesthetised/agenthesia/pull/95) / #16.
Both review findings were reproduced with regression tests before fixing them: fractional dates
changed after reopening, and NUL / invalid UTF-8 payloads were accepted into the immutable event log.
The fixed implementation preserves the Foundation reference epoch and rejects malformed bytes inside
the append transaction. The new tests also verify rollback, unchanged sequence allocation, and valid
Unicode / escaped NUL payloads.

Follow-up: [rowid storage comparison with system-load snapshots](../persistence-rowid/README.md).

## Method

- Before: Persistence implementation at `424c6a7`, with the new benchmark harness added locally.
- After: `09ebd49`, including both correctness fixes and the benchmark runner.
- Same workload and timed code in both runs. The only harness change between measurements replaces
  a force unwrap of the nonempty latency array with the equivalent percentile-1 lookup, after timing.
- MacBookPro18,2, arm64, 32 GiB RAM; macOS 27.0.1; Apple Swift 6.4; Release build.
- Production DatabaseQueue defaults: rollback journal and FULL synchronous commits. No WAL experiment.
- 1 KiB JSON payloads; batches 1/16/64; offered rates 100/1,000 events/s and saturation.
- Two-second arrival window, three sequential fresh-process repetitions per scenario, new database
  each time. No other build, test or benchmark was deliberately run during measurements. General
  system activity was not controlled. All before runs preceded all after runs; this was not randomized.
- Each process reopened the database and verified every stored sequence and payload outside timing.
- No scenario reached the 65,536-event cap. Peak final database size was 196.9 MiB; temporary databases
  were removed between processes. Database size includes SQLite page overhead, not only payloads.

```sh
just bench-persistence --runs 3 --timeout 15 --output .build/benchmarks/persistence-95-before
# Apply the review fixes.
just bench-persistence --runs 3 --timeout 15 --output .build/benchmarks/persistence-95-after
```

The first command above must use the old Persistence implementation with the benchmark harness
present; rerunning it at the fixed commit does not recreate the baseline. See the
[benchmark guide](../../../BENCHMARKS.md) for pacing, resource bounds and metric definitions.
[Before samples](before.json) and [after samples](after.json) retain all 27 observations per phase,
including machine metadata, commit, working-tree status, counts, p50/p95/max and completion delay.
Build logs and per-process stdout remain in the corresponding local `.build/benchmarks/` directories.

## Results

Each cell is the median of three per-process measurements; percentiles are not pooled across runs.
Latency covers one append transaction, not one individual event within a batch.

| Batch | Offered events/s | Before events/s | After events/s | Before append p95, ms | After append p95, ms |
|---:|---:|---:|---:|---:|---:|
| 1 | 100 | 99.8 | 99.7 | 4.697 | 5.962 |
| 1 | 1000 | 999.1 | 999.5 | 0.783 | 0.787 |
| 1 | Saturation | 2,043.7 | 2,148.1 | 0.632 | 0.630 |
| 16 | 100 | 99.3 | 99.4 | 9.887 | 8.654 |
| 16 | 1000 | 997.9 | 997.5 | 3.785 | 6.305 |
| 16 | Saturation | 13,850.0 | 13,108.7 | 1.403 | 1.476 |
| 64 | 100 | 98.1 | 98.2 | 13.075 | 12.828 |
| 64 | 1000 | 992.0 | 993.9 | 13.199 | 14.264 |
| 64 | Saturation | 21,244.1 | 19,925.1 | 3.457 | 3.554 |

## Interpretation and limits

At 1,000 events/s with single-event commits, median append p95 was 0.783 → 0.787 ms.
Before runs committed 1,999/2,000/2,000 events; after runs committed 1,999/1,999/1,999 of the 2,000
scheduled events within the bounded window. Other paced scenarios completed every scheduled full
batch. Partial batches are excluded: batch 64 at 100 events/s schedules only three commits, making
its per-run p95 the maximum of just three observations.

Saturation medians changed by +5.1% for batch 1, −5.4% for batch 16 and −6.2% for batch 64.
Batched validation has a measurable cost candidate here, but these short sequential runs do not
isolate that cost from system variation. In the batch-16 / 1,000 events/s case, median p95 rose from
3.785 to 6.305 ms; retaining the individual samples matters more than calling the overall change free.

Batching raises throughput but also delays the first event while the batch fills: up to 150 ms for
batch 16 and 630 ms for batch 64 at 100 events/s. Those delays are **not** included in append latency.
The completion-delay metric starts when the complete batch should be ready, so it captures scheduler
and writer delay, but also excludes batch assembly time.

Keep the current journal configuration for this PR. These measurements do not establish a need for
WAL, nor prove it would not help. Before choosing batching or changing durability/journal settings in
#17, measure the live arrival pattern and replay contention. This workload covers fresh databases,
one writer, fixed small payloads and short runs; it does not establish long-session, multi-session,
crash-recovery or UI performance.
