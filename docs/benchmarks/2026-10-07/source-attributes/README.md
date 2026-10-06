# SourceView attribute-update prototype — 2026-10-07

Issue [#78](https://github.com/anesthetised/agenthesia/issues/78), proposed
[ADR-0013](../../../adr/0013-source-highlight-attributes.md).

## Reproduction

Same MacBookPro18,2 / 32 GiB / macOS 27.0.1 / Swift 6.4 / 120 Hz display / 2x scale / 868 x 340 pt viewport
as the [earlier validation](../README.md). Optimized Debug builds, three fresh-process repetitions per
scenario, sequential foreground runs with no concurrent local builds or tests. Ordinary desktop
conditions: load averages ranged from 4.5 to 6.6 across the two run sets. This was not a controlled lab.

```sh
just lab-run S4:lines+colors,S4:cold+lines+colors --runs 3 --timeout 90
```

- Before: `dba92c0b7bd33cdc4e553dca788f1b9cf94ae984`, [raw results](before.json).
- Prototype: `5b5262918ef66a6fa046c81966e49701b8f5157c`, [raw results](after.json).
- Both working trees were clean at the start of their repeated run sets. Subsequent documentation edits
  do not affect the measured implementation.

## Results

Medians of per-process statistics; ranges show the minimum and maximum of the three processes.
Highlight completion includes background work and applying its result. Callback intervals are a
responsiveness proxy, not measured pixel presentation.

| Metric | Original, warm | Prototype, warm | Original, cold | Prototype, cold |
|---|---:|---:|---:|---:|
| Highlight complete, ms | 412.37 (410.34–424.53) | 230.76 (229.69–231.67) | 686.53 (676.08–689.13) | 493.88 (493.67–499.45) |
| Largest callback interval, ms | 227.52 (204.98–242.31) | 118.05 (38.88–240.44) | 239.03 (236.74–250.33) | 42.58 (27.51–243.56) |
| Callback p95, ms | 8.33 | 8.33 | 8.33 | 8.33 |
| First callback after setup, ms | 17.24 | 17.12 | 19.38 | 20.82 |
| End footprint, MiB | 69.52 | 65.14 | 70.78 | 65.53 |

Completion improved consistently in these runs, about 44% warm and 28% cold. The whole-scenario maximum
remains variable, with prototype outliers around 244 ms. **This does not establish that all SourceView
hitches are fixed.** End footprint is not peak memory, and the observed difference is not a memory-budget
claim. A single visual smoke run also confirmed colored code and line numbers in the cached view image;
it is excluded from the timing comparison above.

## Why batching and the single-attribute API matter

The first prototype used one `NSTextContentManager.performEditingTransaction` and called STTextView's
`addAttributes` per color range. It preserved view state but did not batch `NSTextStorage` notifications:
a short regression fixture emitted six notifications. Its one-run-per-scenario smoke results were
worse than replacement: maximum intervals of 766/810 ms, warm/cold
([raw negative result](unbatched.json)).

An explicit storage `beginEditing` / `endEditing` pair reduced notifications to one. A diagnostic profile
then showed 88 ms sampled inside completion, with substantial dictionary construction/bridging in the
per-range `addAttributes` path. Since only one attribute changes, the final prototype uses the native
`NSTextStorage.addAttribute(.foregroundColor, value:range:)` API instead.

A fresh Time Profiler run of the final prototype sampled **20 ms** in the main-thread completion task,
compared with **213 ms** in the [original profile](../profiling/README.md). The new filtered call tree has
no text-checking preparation path. These are individual sampled CPU totals, not wall-clock guarantees
or additional unprofiled repetitions. Inclusive call-tree weights overlap.

```sh
just lab-profile S4:lines+colors .build/source-attributes-direct.trace
just lab-profile-export .build/source-attributes-direct.trace .build/source-attributes-direct.xml
```

[Filtered completion profile](completion-profile.txt). The same profile contains later main-thread CPU
bursts involving viewport layout and drawing around 16.8 and 20.8 seconds after recording start, well
after highlighting completed. These warrant separate scroll investigation; they do not prove the exact
cause of every maximum interval in the unprofiled runs. Raw traces and exports remain local in `.build/`.

## Correctness and adoption

New regression tests fail on the original implementation for discarded decorations, character edits,
selection reset, viewport movement and accessibility-selected text. They pass with the prototype.
Tests cover Unicode selection, one attributes-only storage notification, unchanged text, preserved
extra attributes, latest-theme application and existing stale-generation rejection. Accessibility
properties are tested; a complete VoiceOver interaction audit has not been performed.

This is a reviewable prototype, not an accepted replacement for ADR-0007 yet. It provides a targeted
completion improvement and fixes state loss without new dependencies. Remaining scroll stalls and
adoption of ADR-0013 need review; the performance issue is not closed solely on a good p95.
