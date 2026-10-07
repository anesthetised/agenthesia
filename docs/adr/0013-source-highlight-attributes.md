# 0013. Apply SourceView highlighting as attribute edits

- Status: Accepted
- Date: 2026-10-07
- Decider: Project owner
- Scope: Supersedes only the SourceView highlight-completion strategy in [ADR-0007](0007-transcript-rendering.md).

## Context

ADR-0007 applies background highlighting with one replacement of the attributed document. CPU profiling
localized most of its completion-task cost to STTextView's text-checking preparation: the replacement
calls `NSTextCheckingController` even with continuous spell checking disabled. Regression tests also
show that replacement can reset selection, discard unrelated attributes, and shift the viewport.

The owner approved a local public-API prototype before considering changes to STTextView. The text has
not changed when a highlight result arrives; only foreground colors need updating. The source font is
already applied by `SourceView.applyTheme()`.

## Decision

Keep STTextView, background whole-file highlighting, and the existing generation guard. Apply the
result's foreground colors through `NSTextStorage.addAttribute` inside both:

- one `NSTextContentManager.performEditingTransaction`, and
- one explicit `NSTextStorage.beginEditing` / `endEditing` pair.

The content-manager transaction alone does not batch storage edit notifications. A regression test
requires one attributes-only storage notification. Mark the view for layout afterward and retain the
existing scroll-origin restoration. Do not replace characters, reset selection, or clear other attributes.

This uses public APIs and adds no dependency or configuration. It does not introduce incremental
parsing, viewport-only highlighting, or a new concurrency pipeline.

## Alternatives

- **Only a content-manager transaction:** rejected experimentally. It still emitted one notification
  per attribute range and was slower than the original replacement path.
- **STTextView's dictionary-based `addAttributes`:** correct with explicit storage batching, but the
  profile exposed per-range Swift dictionary bridging. The single-attribute storage API avoids that
  unnecessary work.
- **Fix STTextView's text-checking preparation:** remains a valid alternative if local attribute updates
  do not meet the responsiveness requirement. It retains the original integration but may require
  upstream work or a maintained fork; it must preserve spell-check behavior for editable consumers.
- **Incremental or viewport-only highlighting:** deferred. It changes scheduling and result validity
  beyond the localized completion issue and requires a separate decision.

## Validation and limits

The [recorded comparison](../benchmarks/2026-10-07/source-attributes/README.md) shows consistently faster
highlight completion and passing state-preservation tests, but intermittent whole-scenario stalls remain.

Compare fresh-process warm and cold runs with the original implementation using identical workloads,
build configuration and viewport. Report completion time, largest callback intervals and scrolling
percentiles separately; faster color application does not prove all scenario hitches are fixed.

Tests cover a single attributes-only edit notification, preservation of extra attributes, Unicode
selection, viewport position, accessibility text values, and the latest theme. Existing tests cover
stale-generation rejection and large files. Accessibility property tests are not a full VoiceOver audit.

The decision is limited to the current read-only viewer. Editable-view requirements, undo and spelling
annotations need reassessment before extending this strategy to editing. Do not close the performance
issue solely because average or p95 timing is good.

## Consequences

Adopt the measured attribute-update path without changing STTextView or adding a fork. Selection,
unrelated attributes and viewport state are preserved when background colors arrive. The remaining
scrolling stalls are a separate investigation in [#83](https://github.com/anesthetised/agenthesia/issues/83);
accepting this decision does not establish that SourceView meets its overall smoothness requirement.
