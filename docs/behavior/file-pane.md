# File pane and links

The file pane sits right of the transcript and shows one file of the session's working directory: a header with the
path, Open in Editor, Reload File and Close File, then the content. A Markdown file opens as a rendered preview, with
a *Preview* / *Source* switch above it. Links in the preview and in the transcript follow the same rules.

## Width

- The file pane, or the review pane in its slot, and the inspector share the detail column with the transcript. The
  transcript keeps at least 240 pt; beside both panes it keeps 360 pt, so the inspector gives way first: it hides
  while the column is narrower than 360 + 240 + 220 pt (about a 1060 pt window with the sidebar) and a file or review
  is open. A hidden inspector keeps its state and returns when the window widens. This replaces the 240 pt rule of
  [ADR-0039](../adr/0039-t3-style-window-layout.md)'s amendment 2 for three panes.
- Quick Open's Return in the search field opens the selected match, the first one unless ↑/↓ moved the selection.

## Links

- A relative link in the Markdown preview (`adr/0010-prompt-queue-and-steering.md`, `../README.md`) resolves against
  the directory of the previewed file; in the transcript, against the session's working directory. `..` is resolved.
- A link to a file inside the working directory opens that file in the file pane. A `#fragment` or `?query` is
  dropped, and the file opens at its top. Absolute `file:` links work the same way.
- A link to anything outside the working directory (also through a symlink), a link that is only a `#fragment`, and a
  link with any scheme other than `http`, `https`, `mailto` and `file` do nothing.
- `http`, `https` and `mailto` links open in the system's app.
- A click never shows a system alert: the preview and the transcript handle every link themselves.

*Why:* Markdown destinations are stored as plain URLs, so a relative path has no scheme and AppKit hands it to
`NSWorkspace`, which fails with Finder's *The application can't be opened. -50*.

## Changes

- 2026-11-09, #301: the inspector hides while the transcript would get less than 360 pt beside a file or review;
  Return in Quick Open's search field opens the match.
- 2026-11-08, #281: links in the Markdown preview and the transcript resolve against the file's directory or the
  working directory, open in the file pane or the system, and never reach `NSWorkspace` as relative URLs.
