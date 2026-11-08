# File pane and links

The file pane sits right of the transcript and shows one file of the session's working directory: a header with the
path, Open in Editor, Reload File and Close File, then the content. A Markdown file opens as a rendered preview, with
a *Preview* / *Source* switch above it. Links in the preview and in the transcript follow the same rules.

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

- 2026-11-08, #281: links in the Markdown preview and the transcript resolve against the file's directory or the
  working directory, open in the file pane or the system, and never reach `NSWorkspace` as relative URLs.
