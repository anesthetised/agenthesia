# Live session integration measurements

Workload approved by the project owner: one baseline and one final `just bench-session` pass (three
10,000-event reductions at each publication cadence), one baseline/final `S1:A2` run, and one additional
`S1:App` run. Runs were sequential, without overlapping tests or builds. The benchmark commands build
before measuring. No additional repetitions were taken.

Machine: MacBookPro18,2, 10 cores, 32 GiB RAM, macOS 27.0.1, Swift 6.4. Session microbenchmarks use
Release; GUI scenarios use Debug with `-O`, an 868×340-point viewport, scale 2, and a 120 Hz screen.
Baseline rendering preceded the UI changes at parent commit `9ebdd93`; final measurements include the
live-session branch's UI changes. The JSON reports retain commit and dirty-tree information.

## Reducer and snapshot publication

Milliseconds to reduce 10,000 events containing 130,000 characters:

| Publication cadence | Before runs | After runs | Before / after median |
|---|---|---|---|
| Every event | 93.133, 91.821, 92.530 | 91.997, 90.232, 90.143 | 92.530 / 90.232 |
| Every 16 events | 70.626, 70.817, 71.230 | 70.711, 69.351, 69.341 | 70.817 / 69.351 |

The reducer implementation is unchanged. These small differences are not evidence of an optimization.
SQLite fixture creation is outside the measured region. The workload does not measure live durable
append throughput. Resource snapshots bracket each command (including its build), rather than each
individual measured loop: baseline free RAM 72–74%, one-minute load 7.28–7.12; final free RAM 76–78%,
one-minute load 27.94–17.62. Compilation and other machine activity affect these comparisons.

## Streaming UI

200 initial items; 1,244 chunks containing 16,249 characters, offered at 100 chunks/second. Values below
are milliseconds except backlog (chunks) and memory (MiB).

| Scenario | Frame p95 | Largest interval | Hitches / missed≈ | Apply p95 / max | Peak backlog | Memory |
|---|---:|---:|---:|---:|---:|---:|
| A′ before | 8.33 | 49.45 | 2 / 7 | 8.54 / 33.14 | 4 | 70.58 |
| A′ after | 8.33 | 24.78 | 1 / 2 | 9.49 / 15.55 | 2 | 66.45 |
| Production table | 8.33 | 10.65 | 0 / 0 | 10.19 / 32.28 | 4 | 69.88 |

The original A′ implementation is unchanged. Its before/after runs check that the app integration did
not obviously disrupt the lab. The production variant exercises the actual shared table and Markdown
cache, with different row presentation; it is not an identical replacement comparison. Resource
snapshots for the three runs were respectively 75%, 77%, 77% free RAM and 9.98, 7.74, 7.01 one-minute load.

One production run had no counted frame hitches, but a 32.28 ms maximum application latency and a
four-chunk backlog remain visible in the data. These samples do not establish steady-state guarantees,
long-session behavior, or end-to-end ACP → SQLite → SwiftUI throughput. That investigation remains #97.

## Functional verification

`just lint`, `just test`, `just coverage`, and `just app` passed. Final coverage: Core 96.2%, Workspace
98.1%, product total 86.2%; all enforced module thresholds passed. Product UI coverage is 43.0% and has
no enforced threshold. Native smoke testing additionally verified:

- Launching MockAgent from the app in an automatically created worktree.
- Sending a prompt and displaying its streamed reply.
- Stopping a slow turn and opening the bounded stderr panel.
- Quitting during a turn, with no remaining MockAgent process.
- Relaunching and opening the persisted transcript read-only, including its worktree path.

The tests include failed launch/authentication, close during environment resolution and active turns,
unexpected idle process exit, live/replay equivalence, unchanged dirty checkout contents, selected-text
preservation, lazy rendering updates, history selection, and release of the table's data source.
