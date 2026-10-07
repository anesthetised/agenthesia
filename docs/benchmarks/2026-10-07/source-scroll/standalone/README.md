# Standalone scroll isolation controls

Follow-up to #83 and the rejected cached-fragment prototype. This executable contains no Agenthesia
modules and constructs no SwiftUI views. It compares unmodified STTextView 2.4.1 with NSTextView using
TextKit 2, in separate fresh processes. It is an isolation harness, not a replacement renderer proposal.

## Geometry correction after the measurements

A later S4 control, completed before further benchmarks were stopped, exposed the difference:
outer SourceView width **868 pt**, actual text viewport **814 pt**, reserved hidden gutter **54 pt**.
[Source geometry report](source-geometry.json) retains the measurement. Its 260 ms whole-scenario
maximum is not a located late-scroll event; that run did not record an event timeline.

S4 now reports `textViewportWidth`, `textViewportHeight`, `documentWidth` and `documentHeight` in
addition to the existing outer-view measurements. The probe's default `source` geometry reserves the
same gutter width; `SCROLL_PROBE_GEOMETRY=full` retains the 868 pt control. Hidden-window tests check
both renderers and both layouts without starting a display link or a benchmark.

**No performance run of the corrected source-width geometry has been performed.** The recorded six
runs and four profiles below use the earlier full-width geometry from source commit `4fdd34e`, identified
by the saved source/binary hashes. Do not present these data as a matched comparison with S4.

## Recorded workload and checks

- Identical 10,000-line text, verified against the **actual** `TranscriptGenerator.swiftFile` compiled
  from the application. SHA-256: `36c2cd063a34aaaa8d33617de58ca65820cce45f6cc944a2c2b7fb75d4011ce7`;
  243,399 UTF-16 code units.
- Same 12 pt monospaced system font, 868 x 340 pt window and actual clip viewport, 2x scale, 120 Hz,
  horizontal resizing enabled, no gutter or highlighting, and programmatic scrolling at 7,200 pt/s.
- First-line height is 15 pt in both controls. Final document heights are 150,000.5 pt (STTextView) and
  150,001 pt (NSTextView). Every traversal reached the end, taking about 20.8–21.0 seconds.
- The first display callback installs the text. Measurement includes the next callback after the last
  scroll update, like S4. The process stops at 25 seconds even if traversal is incomplete; the runner
  rejects incomplete results. Unlike lab autorun, this harness has no one-second activation delay.
- The runner validates renderer selection, fixture identity, window dimensions, a laid-out
  first line, nontrivial frame/document counts and completion. Actual clip dimensions were also checked
  in the saved results. Invalid renderer input must fail.

STTextView's package product links SwiftUI, so **both modes have SwiftUI loaded** despite constructing
no SwiftUI hierarchy. The native control therefore also shares the dependency's loaded code; it is not
the earlier pure-AppKit executable. The views retain their respective internal layer/layout behavior.
The two controls match each other's actual viewport. S4 originally reported only the outer SourceView
bounds, while its hidden gutter retained an active width constraint; these 868 pt clip widths must not be
assumed to match S4's text viewport. This geometry difference is a further limit on comparison to the
application. See [identity.json](identity.json) and [Package.resolved](Package.resolved) for binary/source
identities, frameworks and dependency pins. The dependency checkout was clean at the pinned revision.

## Six unprofiled runs

Fresh-process order: native, STTextView, STTextView, native, native, STTextView. Release build on the
same MacBookPro18,2 / macOS 27.0.1. Runs were serial on an ordinary desktop, with no other deliberate
build or benchmark running. Load varied from 4.80 to 6.91. Window focus/occlusion changes and other
process activity were not logged, so this is not an isolated-machine comparison.

| Renderer | Maximum display intervals, ms | Synchronous setup, ms | Intervals above 50 ms after the first second |
|---|---|---|---|
| STTextView | 52.23 / 41.59 / 81.17 | 10.65 / 10.83 / 11.00 | One: 81.17 ms at 4.841 s (callback 80.55 ms) |
| NSTextView | 260.36 / 190.65 / 347.35 | 183.98 / 184.18 / 187.81 | None |

p95 was 8.33 ms in every run. [results.json](results.json) preserves each run and every >50 ms event,
including its elapsed time. The first-second split is a descriptive inspection aid, **not a revised
benchmark score or a pre-registered statistical cutoff**. Full maxima remain visible. All native >50 ms
events occurred within 0.603 seconds; the first STTextView run's 52 ms event occurred at 0.355 seconds.

One late 81 ms interval was observed without Agenthesia. That is evidence that a later callback gap
can occur in this standalone configuration. It does **not** show that this gap shares the previously
recorded 100–308 ms synchronization-wait mechanism, establish a STTextView defect, or exclude the OS,
compositor, scheduler or window state. Three quiet native traversals do not establish immunity.

## Profiling

Profiles use the same binary and saved waiting-thread/context-switch options as the prior investigation.
Profiled durations are not included in the table above. See [profiles.json](profiles.json).

Three STTextView recordings had maxima of 42.58, 27.74 and 60.18 ms. None captured a >50 ms interval
after the first second. The third recording's 60 ms gap at elapsed 0.310 s includes input-method
activation (12.02 ms selected wait weight), window/Space state queries (8.54 ms), and a window-ordering
fence request (19.75 ms). It has no `CA::Render::Context::wait_for_synchronize` sample. These are concrete
examples of window activation contaminating a whole-scenario maximum, not an explanation for the
unprofiled 81 ms event at 4.841 s.

The native profile's 195 ms opening interval contains about 185 ms of main-thread sample weight in
`NSTextLayoutManager.ensureLayoutForRange`. Its 337 ms interval at elapsed 0.617 s contains about 255 ms
under that method and 325 ms under view layout. Neither interval contains the earlier
`CA::Render::Context::wait_for_synchronize` stack. These are startup layout observations, not evidence
of the previously observed late synchronization wait. An intervening 86 ms gap also contains window
activation and backing-store activity, without `wait_for_synchronize` samples. Sample weights with
waiting-thread recording enabled must not be relabeled as CPU time or summed as non-overlapping durations.

## Decision and next step

Keep #83 open. No rendering policy or dependency change is justified by this control. The standalone
late gap was not reproduced under profiling, and the original long synchronization wait remains
unexplained. The useful next diagnostic improvement is to record window activity/occlusion changes
alongside S4 gap events, then capture a repeatable late gap while those conditions are stable. Do not
silently discard intervals affected by window changes; retain and label them. Window activation is a
known confound in these startup traces, not a proven cause of the earlier late stalls.

## Reproduction

Agree on workload/resource use, keep the Mac idle and the window visible, and run serially. The package
is isolated from the application's manifests and caches. Commands below run from the repository root:

```sh
just --working-directory . --justfile docs/benchmarks/2026-10-07/source-scroll/reproduce.just standalone-build
just --working-directory . --justfile docs/benchmarks/2026-10-07/source-scroll/reproduce.just standalone-run .build/standalone-results-new
just --working-directory . --justfile docs/benchmarks/2026-10-07/source-scroll/reproduce.just standalone-profile sttextview .build/standalone-st-new.trace
just --working-directory . --justfile docs/benchmarks/2026-10-07/source-scroll/reproduce.just standalone-profile native .build/standalone-native-new.trace
just --working-directory . --justfile docs/benchmarks/2026-10-07/source-scroll/reproduce.just standalone-lint
just --working-directory . --justfile docs/benchmarks/2026-10-07/source-scroll/reproduce.just standalone-test
```

`standalone-build`, `standalone-test` and `standalone-lint` do not run benchmarks. The default
`source` geometry computes the reserved width with the same font/digit/padding formula as SourceView.
Set `SCROLL_PROBE_GEOMETRY=full` for the wider control; the runner records the geometry and checks
that clip width plus reserved width equals the outer width.

`standalone-run` builds, computes the application's fixture identity, then runs exactly six fresh
processes. Each process has an external 40-second timeout. It preserves logs and reports failures,
and refuses to overwrite its output directory. Unlike the main benchmark runner, it has no cross-run
lock; do not start it alongside another measurement. This standalone probe is not part of product CI.
Raw traces and XML exports stay local under `.build/`; use `just lab-profile-export` to inspect them.
