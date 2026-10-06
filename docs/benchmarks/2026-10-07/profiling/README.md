# Rendering CPU profiles — 2026-10-07

Follow-up to [the repeated benchmarks](../README.md), issues
[#77](https://github.com/anesthetised/agenthesia/issues/77) and
[#78](https://github.com/anesthetised/agenthesia/issues/78).

## Method

The same optimized Debug application from `7960afe` was profiled on the same MacBookPro18,2. Only the
profiling recipes and documentation changed. Recordings ran sequentially using Xcode 27 Time Profiler,
with its default 1 ms CPU sampling interval. Each scenario ran once in a fresh process. The application
exited normally before the 30-second recording limit. These diagnostic recordings are not additional
unprofiled benchmark repetitions and do not establish a before/after performance claim.

```sh
just lab-profile S6:A2 .build/stream-code.trace
just lab-profile-export .build/stream-code.trace .build/stream-code.xml
just lab-profile S4:lines+colors .build/source-colors.trace
just lab-profile-export .build/source-colors.trace .build/source-colors.xml
```

Open the trace in Instruments to inspect call trees and sample timestamps. The export recipe produces
Time Profiler XML for the first recording. The text summaries here resolve XML `id`/`ref` elements,
select main-thread samples, and sum their `weight` in milliseconds. Inclusive symbol totals count a
symbol at most once per sample; they overlap and **must not be added together**. A sampled CPU weight is
not an exact wall-clock duration. Unnamed addresses and optimized/inlined frames limit attribution.

Raw traces and XML remain local under `.build/`; the committed summaries contain selected CPU data,
not device identifiers or the full trace. Reproduce the summaries in Instruments by filtering for the
named ancestor below or selecting the stated time range. The source-completion summary is restricted to
the completion task, not background highlighting or subsequent display work.

## Long unclosed Swift block

The profiled workload still exhibited a 33.7 ms callback p95. Select main-thread samples from the first
to last sample containing `closure #1 in RenderingLab.runStream(longCode:)`: **2.645883291–9.902878291 s**
after recording start. This approximates the active streaming window; it is not a signposted interval.

The window contains 6,151 ms of sampled main-thread CPU work:

| Inclusive call path | Sampled CPU, ms | Share of window |
|---|---:|---:|
| Display callback's streaming closure | 1,780 | 28.9% |
| `StreamingMarkdown.append` | 1,248 | 20.3% |
| `Highlighter.highlight` | 1,093 | 17.8% |
| `MarkdownRenderer.blocks(in:)` | 26 | 0.4% |
| `SizingTextView.apply` | 440 | 7.2% |
| `SizingTextView.intrinsicContentSize` | 1,737 | 28.2% |
| `NSDisplayCycleFlush` | 3,170 | 51.5% |

See [the time-window summary](stream-window.txt) and
[the callback-only call tree](stream-callback.txt). The callback accounts for only part of the work;
substantial layout/display work runs later. Inside the callback, highlighting is 61.4% of sampled CPU.
The Markdown parse entry point is small in this particular workload.

Code inspection explains the pattern: one growing code block is entirely re-highlighted, and its
`stablePrefixLength` remains zero. The TextKit view replaces that whole block, invalidates intrinsic
size, and measures its height with `ensureLayout(for: layout.documentRange)`. The table then follows its
end. Optimizing only the Markdown parser or moving only highlighting off-main would leave substantial
text replacement and layout work.

### Options to discuss

1. **First investigate preserving unchanged attributed text within the changing block.** Retain the
   existing renderer and final output, but reduce the range sent to text storage. This may reduce layout
   invalidation without changing highlighting policy. A prototype must prove attribute equality,
   Unicode-safe boundaries, selection behavior, and actual layout savings; finding the common prefix
   has a cost and semantic edits may invalidate earlier text.
2. **Change the streaming highlighting policy or move work off-main.** This can reduce main-thread
   computation but introduces stale-result handling, cancellation/backpressure, or temporarily delayed
   colors. It does not by itself fix full-block layout. Discuss the behavior before implementing it.
3. **Incremental Markdown parsing or a different transcript architecture.** Not justified as the first
   intervention by this profile. The measured parse entry point is only 26 ms across the streaming
   window, and replacing A′ would enlarge the scope substantially.

Recommendation: test a smaller text-storage replacement first, while separately considering the cost
of full-block highlighting. Do not introduce an incremental Markdown parser based on these data.

## SourceView highlight completion

Filter the main-thread call tree to `closure #1 in SourceView.startHighlighting()`.
[The completion summary](source-completion.txt) contains 213 ms of sampled CPU between
**2.499522416–2.712524666 s** after recording start:

- All 213 ms are under `STTextView.attributedText.setter`.
- 208 ms (97.7%) are under `NSTextCheckingController.didChangeTextInRange:`.
- 207 ms are under `STTextView.annotatedSubstring(forProposedRange:actualRange:)`.
- 167 ms are under `NSMutableAttributedString.removeAttribute:range:`.

In the pinned STTextView implementation, replacing text unconditionally calls
`textCheckingDidChangeText(in:)`. The controller asks for annotated text, and STTextView copies the
attributed substring, gathers non-annotation attributes, and removes them from that copy. The expensive
work is on the main thread. `isContinuousSpellCheckingEnabled` already defaults to `false`, and
Agenthesia already sets `isEditable = false`; merely disabling either is not a fix.

This localizes the dominant completion cost to text-checking preparation, rather than the background
highlighter or an assumed 200 ms layout pass. Subsequent layout still exists and needs measurement
after any fix. The profiled scenario's maximum callback interval was 276 ms; use the unprofiled repeated
runs in the parent report for baseline timing.

### Options to discuss

1. **Apply highlight attributes through an appropriate public text-storage editing transaction.** The
   source text has not changed; avoid presenting a color update as a new document. This stays in our
   adapter, but must preserve selection, viewport, accessibility behavior, layout invalidation, and the
   generation guard. ADR-0007 previously found in-place coloring slow, so a new implementation needs
   measurement rather than an assumption that this is automatically faster. A change from the ADR's
   single-replacement strategy needs an explicit decision.
2. **Fix text-checking preparation in STTextView.** This targets the dependency's expensive path and
   retains the accepted integration. It may require upstream work or a maintained fork/pin, with tests
   for actual spell-check annotations and editable views. Do not silently skip required annotations.

Recommendation: compare a narrowly scoped public-API attribute-update prototype with the dependency
fix before choosing. No production rendering strategy or dependency has been changed by this profiling
work. Both choices need owner discussion; neither requires a renderer rewrite.
