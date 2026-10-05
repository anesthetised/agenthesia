# 0008. A viewer, not an IDE

- Status: Accepted
- Date: 2026-10-05

## Context

Reviewing an agent's work requires reading files, diffs and Markdown with syntax highlighting. A full
editor (autocomplete, language servers, project tree) would turn the app into an IDE, which conflicts
with principle 1.

## Decision

- Built-in, read-only viewing of files, diffs and rendered Markdown, with tree-sitter highlighting.
- Navigation by Quick Open (⌘P), the list of files changed in the session and clickable paths in the
  transcript. No file tree.
- *Open in Editor* hands off to the user's editor.
- Basic editing comes after the MVP: edit in `SourceView`, undo, save, detection of external changes,
  conflict handling with agent writes and serving unsaved buffers to the agent through ACP
  `fs/read_text_file`. No autocomplete, no LSP.

## Consequences

- Shared rendering components (`Rendering` module) serve the transcript, diffs and the viewer.
- `SourceView` is designed to become editable later.
