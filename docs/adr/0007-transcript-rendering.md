# 0007. Transcript and text rendering

- Status: Accepted
- Date: 2026-10-06

## Context

The transcript is the riskiest UI component: a long, streaming list of Markdown messages, code blocks,
tool calls and diffs that must stay smooth, support text selection and stick to the bottom while
streaming. SwiftUI `List`/`LazyVStack` degrade under these conditions. The same text-rendering pieces
(highlighting, Markdown, source view, diff view) are reused by the file viewer.

The M2 spike built the rendering pieces for real (`Rendering` module) and four transcript prototypes in a
debug-only Rendering Lab, all on one item model and one deterministic transcript generator:

- **A**: view-based `NSTableView`, a row per item, messages in selectable text fields.
- **A′**: A, but the message that is streaming is a TextKit 2 `NSTextView` that a chunk changes only at
  the end.
- **B**: the whole transcript as one TextKit 2 document in a read-only `NSTextView`, tool calls as view
  attachments. It opens at the end: the last 300 items at once, older ones rendered in the background and
  put above.
- **C**: SwiftUI `Text` views in a `LazyVStack`, as the control.

## Acceptance criteria

- p95 frame time ≤ 16.7 ms while streaming and scrolling.
- 10,000 transcript items open in under 500 ms.
- A 10,000-line file opens in `SourceView` in under 300 ms and scrolls smoothly.
- Text selection works within messages and code blocks.

## Measurements

MacBook Pro M1 Max, 120 Hz display (8.3 ms a frame), optimized build (`just lab-run`, `just bench`), the
Mac otherwise idle: 74–81% memory free, load average 5–10.5 on 10 cores during the runs.

| Scenario | A | A′ | B | C |
|---|--:|--:|--:|--:|
| S1: stream a ~4000-token answer into 200 items, a chunk a frame — p95, ms | 18.8 | **8.3** | 8.3 | 88.8 |
| S1 — frames dropped of 1244 | 246 | **0** | 10 | 994 |
| S2: open 10,000 items at the end, ms | 18.9 | **18.0** | 51.2 | 12.6 |
| S2: then scroll up 120 pt a frame — p95, ms | 8.3 | **8.3** | 16.7 | 19.9 |
| S2 — longest frame, ms | 81 | **58** | 939 | 32 |
| S5: switch light and dark 10 times — longest frame, ms | 54 | **38** | 44 | 44 |

S3 (selection): A and A′ select text within one message, including code blocks; B selects across messages.

`SourceView` (S4), a 10,000-line Swift file: opens in 5–6 ms; scrolling 60 pt a frame has a p95 of
8.3 ms with or without line numbers and colors. Colors arrive once, in a single ~230 ms frame after the
background highlight finishes.

`just bench`, one thread:

| Work | Time |
|---|--:|
| Markdown, typical answer (1,500 characters) | 0.85 ms |
| Markdown, long answer (16,000 characters) | 9.0 ms |
| Streaming the long answer in 13-character chunks | p50 0.71 ms, p95 1.28 ms a chunk |
| Highlighting 10,000 lines | 53 ms (JSON) to 317 ms (TSX) |
| First use of a grammar | 236 ms (Swift), 2–19 ms (others) |

## Decision

### Transcript: `NSTableView` with a TextKit 2 streaming message (A′)

- A view-based `NSTableView`, one row per transcript item, row heights from Auto Layout. Rows are created
  and rendered only when they scroll into view; heights of rows not yet seen are estimated.
- A finished message is rendered once to an `NSAttributedString`, cached per item, and shown in a
  selectable text field. Tool calls and diffs are their own row views.
- The message that is streaming is a TextKit 2 `NSTextView`. `StreamingMarkdown` re-renders only the
  blocks a chunk changed, and the view replaces only that tail of its text.
- While the user is at the bottom, the table follows the end after every update.
- Text selects within one message. Instead of selecting across messages:
  - a Copy action on every message and code block, copying Markdown;
  - row selection (⇧/⌘-click) where ⌘C copies the selected messages as Markdown;
  - ⌘F through our own `NSTextFinder` client that searches all messages (M3).

### Text rendering

- `MarkdownRenderer`: swift-markdown (cmark-gfm) to `NSAttributedString`, every top-level block rendered
  on its own and joined by newlines, so a block can be re-rendered alone. Smart punctuation is off. Tables
  are monospaced text until a real grid is designed: `NSTextTable` does not work in TextKit 2.
- `StreamingMarkdown`: re-parses the whole text on every chunk (cmark is linear) and re-renders only blocks
  whose structure changed; it reports the stable prefix and the new tail.
- `Highlighter`: SwiftTreeSitter with bundled grammars for 11 languages. A grammar loads once per process;
  code blocks are highlighted while rendering, whole files on a background queue.
- `Theme`: dynamic colors, so a light/dark switch needs no re-rendering.

### `SourceView`

- `STTextView` (TextKit 2), read-only for now.
- The text shows at once; the whole file is highlighted on a background queue and its colors applied in
  one text replacement.
- Our own line-number gutter: it finds visible line numbers by binary search over line starts.
- No Neon: its rendering attributes cost ~8 ms a frame when scrolling a 10,000-line file, and it parses
  documents under 1 MB on the main thread. Revisit incremental highlighting when `SourceView` becomes
  editable (M11).

## Why not the others

- **A**: a text field has no partial update, so every chunk lays out the whole streaming message again
  (p95 18.8 ms). A TextKit 2 text view in *every* row fixes nothing: each draws its whole message into its
  own layer and scrolling dropped to p95 18.5 ms.
- **B** streams perfectly and selects across messages, but:
  - scrolling up costs about one 120 Hz frame even in a 300-item document (p95 16.7 ms, 8–13% of frames
    dropped): TextKit 2 replaces estimated heights above the viewport as it lays them out;
  - opening needs every item rendered. All 10,000 take 1.1 s, and more cores barely help: attributed
    string attributes are uniqued under a process-wide lock;
  - opening at the end and adding older items later costs a ~0.9 s frame once: inserting at the start of a
    TextKit 2 document grows with its length, and restoring the scroll position lays out everything above.
- **C**: p50 45 ms while streaming; `Text` also drops paragraph styles.

## Consequences

- The transcript meets every criterion with headroom: streaming p95 8.3 ms with no dropped frames,
  10,000 items open in 18 ms and scroll at p95 8.3 ms.
- No mouse selection across messages. If users ask for it, it needs custom selection across rows; the
  row-based layout does not have to change for that.
- Find needs our own `NSTextFinder` client instead of the one `NSTextView` provides.
- Rendered messages are cached per item; memory grows with what has been scrolled into view (the lab app
  used ~120 MB after scrolling through 10,000 items).
- The grammars make up most of the app's size: the Release binary is 18.6 MB (arm64), 10.5 MB of it
  constant data, mostly parse tables. In object code a grammar takes from 0.02 MB (JSON) to 1.5 MB (Bash,
  TSX); Swift's is the largest at 4.3 MB.
- `Rendering` depends on STTextView (GPL-3.0, compatible with our license), SwiftTreeSitter and the
  grammars listed in [ARCHITECTURE](../ARCHITECTURE.md#dependencies). Three grammars come from forks
  until upstream fixes its Swift manifests.

## Notes for measuring

- Measure an optimized build: a Debug build was about 3× slower.
- Keep the Mac idle and the window in front. A window behind others gets a throttled display link, and
  other apps' drawing (WindowServer) slows frames without showing in the load average.
- STTextView's own line-number gutter counted all paragraphs above the viewport: ~10 ms a frame deep in a
  10,000-line file.
