# 0041. Review as a pane, with Ask agent

- Status: Accepted (#195, 2026-11-06)
- Date: 2026-11-02
- Decider: Project owner
- Supersedes: the native review sheet described in ARCHITECTURE.md (no ADR fixed the sheet;
  [0032](0032-worktree-merge-and-discard.md) decides what review compares, which stays)
- Related: [0039](0039-t3-style-window-layout.md), [0018](0018-composer-attachments.md),
  [0010](0010-prompt-queue-and-steering.md), [0024](0024-changed-files-session-base.md)

## Context

The vision makes review one of the app's core jobs, and T3 Code keeps its diff in a panel beside the chat. Here,
Review Changes is a modal sheet (`RootView.swift:179`, `SessionReviewView.swift`), which has concrete costs:

- **It blocks what review needs.** The transcript and the composer are behind it, so the user can neither read what the
  agent said about a change nor answer it. A permission request that arrives during review cannot be seen or answered
  in this window.
- **The way from a diff to the agent goes through memory.** To comment on a line, the user closes the sheet and retypes
  the path and the lines.
- **It tracks nothing.** There is no way to mark what was read in a long review, and the list has no line counts,
  although the inspector does (`SessionFiles.changeStats`).
- **Refreshing destroys selection.** Every file event refreshes review (`SessionReviewView.swift:83`), which clears the
  document and the rendered diff before loading them again (`SessionReview.swift:68`, `SessionReviewDetail.swift:41`).
  While an agent works, the diff flickers and any selection is lost.

The rendered diff also cannot say which line was selected: it is a fenced Markdown string in `MarkdownPreview`
(`SessionReviewDetail.swift:31,48`) and `UnifiedDiff.make` returns plain text, so line numbers exist only inside `@@`
headers. `HSplitView`, which the sheet's list and diff use, caused the layout faults recorded in ADR-0039's amendment.

## Decision

**A pane of the detail column.** ⌃⌘R (the existing Review Changes shortcut), and Review in the inspector, toggle it.
It shares the file pane's slot in `DetailPanes`, beside the transcript: opening one hides the other, which keeps its
state and returns on ⌃⌘R or when its file is opened again. A path clicked in the transcript opens the file pane. The
slot has its own remembered width, by default 560 pt with `PaneDivider`, and the width rules stay: the transcript
keeps at least 240 pt, and the inspector gives way first. The transcript and the composer stay live beside it, so a
docked permission card (ADR-0039) can be answered during review.

**Layout, top to bottom.**

- The header: what is compared (`Changes against main`), and Refresh only when watching failed (ADR-0039's amendment).
- The file list, at most a third of the pane's height. Each row has the path, status, rename source, line counts and
  a viewed mark. No `HSplitView`.
- One unified diff, as today.
- The footer: **Ask agent**, then Merge…, then the viewed count (`2 of 5 viewed`). The merge sheet moves to `RootView`,
  which removes today's two presentation paths (`RootView.swift:186`, `SessionReviewView.swift:72`).

**Kept from the sheet.** What is compared and all of ADR-0032: `merge-base…` plus staged, unstaged and untracked
files. `SessionReview`'s lazy, size-checked reads of the selected file, canonical roots and the 2 MiB limit.
`UnifiedDiff` off the main actor with word highlights. A window-owned review that ends when the session changes or the
window closes. The native `List` with arrow keys. Only Done goes, replaced by the toggle and by Escape while the pane
has focus and no text is selected.

**Viewed marks.**

- A mark per file, set in its row or with ⌥⌘V, which moves to the next unviewed file.
- It is remembered with a fingerprint of what was viewed: status, size and modification time of the working file, read
  with `stat` on each refresh. If it changes, the mark clears, because a file that changed after it was read is unread.
  A `touch` clears it too, which is the safe direction.
- It lives in `SessionWindowModel`, keyed by session and path. It survives closing the pane and showing another session
  in the window, not closing the window or relaunching. It is a reading aid, so it never goes into the append-only log.
- It does not affect Merge: review is not a gate (principle 6).

**Line counts.** `SessionWorkspace.changeStats(in:baseRevision:)` with the review snapshot's own `baseRevision`. The
inspector's numbers use the session base (ADR-0024), the review's the merge base; each counts what it compares.

**Ask agent.** With lines selected in the diff, Ask agent (footer, context menu, ⌥⌘A) inserts a quote at the composer's
caret and moves focus there. Nothing is sent: the user adds a question and sends it as usual, and Return queues it
while a turn runs (ADR-0010).

    `Sources/App.swift:42-44`
    ```diff
    -let name = old
    +let name = new
     return name
    ```

- A selection grows to whole lines. Hunk headers do not count; a selection across hunks lists both ranges.
- The path is relative to the session's working directory, which is the agent's `cwd` and what review's paths are.
- Line numbers are the new file's. Only-removed lines cannot have one, so they say so:
  `Sources/App.swift:42 (removed)`.
- The quote is text, not a `resource_link`: ADR-0018's links stand for whole files, and here the selected lines are the
  content. The fence uses `LiveTranscriptSource.fenced`, so a backtick in the code cannot close it.
- It is disabled, with an explanation in its help text, when the session cannot take a prompt, for example saved
  history. While a queued message is being edited, the quote goes into that message, where the user can see it.

For this, `Rendering` gains a pure parser from `UnifiedDiff` output to lines (kind, old number, new number, text), and
the diff gets its own selectable text view that knows the character range of each line, using the existing renderer
for highlights.

**Selection across updates.** Selection lives in the diff's text view; the model knows only whether one exists.

- **Streaming does not touch it.** Transcript frames do not invalidate the diff's view, whose identity depends only on
  the session and the pane. This needs a test, because `RootView` re-renders the panes.
- **An unchanged file does not touch it.** A refresh loads the new document *before* replacing anything and compares it.
  An equal document changes nothing, neither selection nor scroll position. The `nil`-then-reload step goes away for
  everyone, and so does the flicker.
- **A changed file with no selection** swaps the diff in place, keeping the scroll position at the nearest line.
- **A changed file with a selection holds.** The user is about to quote what they see, so the diff stays and the pane
  shows `File changed · Show latest`. Clearing the selection, or Show latest, applies the update. The list keeps
  updating meanwhile, and the same holds when the file disappeared from the list. A quote taken from a held diff ends
  with `(from an earlier version; lines may have moved)`, because the agent will read the file as it is now.
- **Selecting another file, closing the pane or switching sessions** drops the selection, as text views do.

## Alternatives

- **Keep the sheet and add Ask agent.** Least work, but the sheet would have to close to reach the composer, and all
  of the first problem stays.
- **Review replaces the transcript in the same column.** Most room for the diff, and no width rules, but the user loses
  the agent's explanation and the composer, which is what the pane is for.
- **A separate window.** Plenty of room, but one more window to manage per session, and Ask agent would cross windows.
- **Reuse the file pane for one file at a time, with a Diff mode.** No new pane, and fewer views, but it loses the
  review as a list to work through, and viewed marks have no home.
- **All files in one scrolling diff** (GitHub). Good for reading everything, but it reads every file instead of the
  selected one, which gives up the lazy reads and size checks, and it needs far more of the transcript's lazy-row work.
- **Follow the refresh and move the selection along** by matching lines. Elegant in the simple case, wrong in the case
  that matters: the lines changed, so the quote would differ from what the user selected.
- **Attach the selection as a file with a range**, as an extension of ADR-0018. ACP has no standard line range for a
  `resource_link` that every agent honors; text works with every agent.

## Consequences and risks

- `DetailPanes` gains a mode for its slot, and the hidden-pane rule now loses selection: below 480 pt of column, the pane
  is hidden and its text view is gone. That needs a narrow window with a wide sidebar. It is accepted.
- At the 740 pt minimum, a 240 pt transcript and a 260 pt diff are both cramped. The user can collapse the sidebar; the
  layout stays correct, not comfortable.
- A long selection makes a long quote. The composer shows it and the user can trim it. No limit is set.
- Holding the diff means that a user who forgets a selection reads an old diff. `File changed` stays visible, and the
  file list shows new line counts.
- Ask agent depends on composer state outside `RootView`'s `@State` (#189) and on focus moving to the composer (#193).
- ⌃⌘R changes from opening to toggling; there is no modal to dismiss with Done, and screenshots and documentation of
  the sheet become outdated.
- Fingerprints use `stat`, which is cheap, but they run for each viewed file on each refresh while the agent works.
- The new text view replaces `MarkdownPreview` in review, so the diff's highlighting needs its rendering checked in
  light and dark, and a benchmark if a large diff turns out slower.

## Not decided

Comments kept across prompts, batched review comments and inline comment boxes; sending from the pane; side-by-side
diffs (still open, as in PLAN.md); quoting from the file pane or the transcript; persisting viewed marks; and making the
review a merge gate.
