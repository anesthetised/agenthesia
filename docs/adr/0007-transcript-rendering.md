# 0007. Transcript and text rendering

- Status: Proposed
- Date: 2026-10-05

## Context

The transcript is the riskiest UI component: a long, streaming list of Markdown messages, code blocks,
tool calls and diffs that must stay smooth, support text selection and stick to the bottom while
streaming. SwiftUI `List`/`LazyVStack` degrade under these conditions. The same text-rendering pieces
(highlighting, Markdown, source view, diff view) are reused by the file viewer.

## Options

- `NSTableView` (view-based) with cell reuse and per-message text views.
- A single TextKit 2 document with custom layout fragments for non-text elements.

## Acceptance criteria

- 60 fps while streaming.
- 10,000 transcript items without degradation.
- Text selection within messages and code blocks.
- Smooth scrolling of a 10,000-line file in `SourceView`.

## Decision

To be made after the M2 spike.
