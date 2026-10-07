# Cached-fragment invalidation experiment

Owner-approved local experiment for #83, based on Agenthesia `59db59a` and STTextView 2.4.1
(`bbdcfd9d413ad3055dafd23a223be9bd39742f89`). **Rejected as a fix.** No production dependency change.

## Change and correctness

The [one-line deletion](no-cached-invalidation.patch) removes reassignment of the same layout fragment
to its cached view. This avoids the setter's unconditional `needsDisplay` and `needsLayout` updates.
It is a diagnostic reduction of redraw requests, not a safe optimization.

The [four Swift Testing checks](CachedFragmentRedrawTests.swift) run in a separate dependency checkout:

| Check | Upstream | Prototype |
|---|---|---|
| Unchanged cached fragment does not invalidate display or layout | Fails both assertions | Passes |
| Adding and removing a temporary foreground color requests redraw | Passes | Fails both assertions |
| Persistent color reaches the displayed text-line fragment and requests redraw | Passes | Passes |
| Replaced text reaches a displayed fragment and requests redraw | Passes | Passes |

Tests first finish initial window/layer drawing and assert a clean surface. They check both NSView's
`needsDisplay` and its backing CALayer's `needsDisplay()`: checking only the view flag misses scheduled
layer updates. They inspect fragment contents and invalidation, **not final screen pixels**. The temporary
attribute test retains the original fragment as the cache key, exercising reuse rather than replacement.

The prototype fails the correctness gate. A same-object identity check is insufficient; temporary
rendering attributes can change without replacing that fragment. Broader selection, scrolling,
attachments, appearance and spelling validation would still be needed for any revised implementation.
Do not repair only the public add/remove wrappers: text-checking annotations also call the layout
manager directly. No broader invalidation mechanism was added for this rejected experiment.

## Unprofiled runs

Three fresh processes per variant, sequential blocks (baseline first), same S4 warm `lines+colors`,
10,000-line fixture, 868 x 340 pt viewport, 2x scale, 120 Hz display, 7,200 pt/s and optimized Debug build.
Only the dependency path was temporarily overridden. Xcode's compiled source list confirmed the local
modified checkout. Transitive dependency revisions matched the existing pins. The benchmark runner
cannot see ignored-checkout changes; [experiment.json](experiment.json) records the patch hash and identity.

| Variant | Maximum display intervals, ms | Median maximum, ms | Median excess frame time, ms |
|---|---|---:|---:|
| Upstream | 48.73 / 24.68 / 76.21 | 48.73 | 247.60 |
| Prototype | 71.12 / 44.68 / 75.26 | 71.12 | 510.48 |

p95 was 8.33 ms in all six runs. Raw reports: [baseline](baseline.json), [prototype](prototype.json).
The three maxima are per-run observations, not confidence intervals. Ordinary desktop load varied
(6.56–9.99); variants were not interleaved. These data establish neither a reliable improvement nor a
reliable slowdown. In particular, quiet baseline runs compared with earlier 100–308 ms observations
show why absence of a large pause in a short run cannot establish a fix.

An additional waiting-thread profile of the prototype completed with a 42.70 ms maximum display
interval. It did not reproduce a large display gap, so it does not establish whether the previous
synchronization-wait mechanism changed. Its result is retained in `experiment.json`; raw trace remains
local. Profiled timing is separate from the six unprofiled measurements.

The experiment does not justify a dependency fork or a more complex invalidation scheme to address
#83. It also does not prove that redundant redraws have no cost.

## Reproduction

Use an isolated checkout at the revision above. Do not patch the application's dependency caches.
Copying and running the checks is supported by the diagnostic justfile:

```sh
just --working-directory . --justfile docs/benchmarks/2026-10-07/source-scroll/reproduce.just redraw-test /absolute/path/to/STTextView
```

This command intentionally exits nonzero on upstream (the optimization assertion fails). Apply
`no-cached-invalidation.patch` in that checkout and run the same command: the temporary-color test
must now fail instead. These checks are research artifacts, outside the application's CI test target.

For timing, first run `just lab-run S4:lines+colors --runs 3` with the pinned upstream dependency.
Temporarily replace its package declaration with `.package(path: "../../.build/source-redraw/STTextView")`
if using the experiment's checkout location, and run the same command again. Keep the lab visible,
run serially, and agree on resource use first. Save the patch, dependency revisions and reports together.
Restore the manifest and both resolved files afterward, then rebuild the lab so the default binary also
uses upstream. Do not commit the override or treat the failing prototype as a deployable change.
