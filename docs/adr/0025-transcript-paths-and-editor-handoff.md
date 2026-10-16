# 0025. Transcript paths and editor handoff

- Status: Proposed
- Date: 2026-10-17
- Decider: Project owner
- Scope: #29; complements ADR-0008 and ADR-0023

## Context

ADR-0008 promises clickable paths in the transcript and *Open in Editor*; ADR-0023 left both to #29.
Today the transcript shows paths as plain inline code (tool call locations, diff headers) or as the
agent's own prose. The transcript text views handle no links, `SourceView` cannot scroll to a line,
and the app has no Settings scene. Agents report absolute paths inside the session's worktree, or
paths relative to it. Editors differ in how they accept a line: VS Code and Cursor document a
`file` URL with a line, while Xcode registers `xcode://` without a documented way to open a file at
a line.

## Decision

- **Which paths link.** Tool call locations and diff paths always link. An inline code span in agent
  text links only when it is a path (optionally followed by `:line`, `:line:column` or `#Lline`) that
  names a file in the session's Quick Open index. The index excludes ignored files, so spans such as
  `.env` or build output stay plain. Bare text and command output are not scanned.
- **Index updates.** Inline spans are matched against the latest published index, so a file the agent
  creates and then mentions becomes a link after the next rescan. Only rows `NSTableView` has
  requested hold attributed text, so restyling is bounded by those rows.
- **Responsibilities.** `Rendering` marks inline code ranges with a generic attribute and knows nothing
  about sessions or the index. Core resolves a candidate against the session's canonical root, as for
  Quick Open: an absolute path inside the root becomes relative; a path outside the root, or with `..`
  components, is not a link and gets no new access (ADR-0023). AgenthesiaUI applies the link to resolved
  ranges. A structural path whose file no longer exists still links; the viewer shows its existing
  unavailable-file explanation.
- **Navigation.** A link carries the relative path and an optional line, and is handled by the
  displayed session's window, which opens the file pane through `SessionFiles.open`. The viewer scrolls
  the line into view and marks it until the selection changes. Markdown files opened with a line
  switch to Source.
- **Open in Editor.** A Settings scene lets the user choose an editor from a built-in table of
  installed apps (initially VS Code, Cursor, Zed, Xcode, discovered by bundle identifier) and stores
  the choice in `UserDefaults`. Each table entry has an optional URL template with a line. The file
  pane's Open in Editor action uses that template through `NSWorkspace` when the entry has one, and
  otherwise opens the file in the chosen app with `NSWorkspace.open(_:withApplicationAt:)`, without a
  line. Without a choice, or when the editor is not installed, the file opens in the system's default
  app. URL construction is pure and tested; `NSWorkspace` calls stay in the UI layer. No subprocesses
  are started.
- The editor receives the session's working directory path, so for a Git session it opens the worktree
  copy, not the user's checkout.

## Alternatives

- **Default app only, with Open With.** No Settings and no table, but never reaches a line. The owner
  chose a configurable editor.
- **URL schemes only.** Simpler entries, but an editor without a line-capable scheme, such as Xcode,
  could not be offered at all.
- **Editor CLIs** (`code -g`, `zed`, `xed --line`). Cover more editors with lines, but a GUI app does
  not inherit the user's `PATH`, so the table would hold binary locations inside each `.app`, and a
  `Process` adds failure modes.
- **A user-supplied command template** with `{path}` and `{line}`. Flexible, but it runs arbitrary
  commands and needs its own security review and UI.
- **Scanning plain text and command output for paths.** More links, more false positives, and a cost on
  every streamed chunk; it needs its own benchmark and can follow if inline code proves too narrow.
- **Styling every path-shaped span and checking existence on click.** No dependency on the index, but
  links that lead nowhere; the owner chose verified links.

## Consequences

Links work for saved sessions as well as live ones, because they depend on the session root and the
file index, not on the agent connection. Until the index loads or rescans, inline code stays plain, so
a large repository or a newly created file shows plain code briefly. Editors without a line URL open at
the start of the file; Xcode is in that group unless its scheme is confirmed during implementation.
Each line template is verified against the installed editor. Restyling on index publication touches the
transcript's hot path and is measured with a benchmark. The Settings scene is the home for later
preferences.
