# 0018. Composer attachments and slash commands

- Status: Accepted
- Date: 2026-10-15
- Decider: Project owner
- Scope: composer (#18); builds on [0006](0006-worktree-isolation.md) and [0014](0014-window-bound-live-sessions.md)

## Context

The composer has to attach files and offer the commands an agent announces in
`available_commands_update`. ACP lets a prompt carry `resource_link` blocks, which every agent must
accept, and embedded `resource` blocks, only when the agent advertises `embeddedContext`. A slash
command is not a separate request: the prompt's text starts with `/name`.

Git sessions run in a worktree (ADR-0006), but users drag files from Finder or their editor, which show
the main checkout. A path into the checkout makes the agent read a file that may differ from the one it
edits, and `fs/read_text_file` refuses it because it is outside the session's roots.

## Decision

- **Links, not contents.** Each attached file or folder becomes a `resource_link` with a `file://` URI,
  its name, and, for files, the size and the MIME type when the system knows one. The agent reads it
  itself. Contents are not embedded and images are not sent as `image` blocks; both can come later.
- **Text first.** The prompt is the text block, if not blank, followed by one link per attachment in the
  order they were added. Attachments alone are a valid prompt.
- **Checkout paths point into the worktree.** When the session runs in a linked worktree, a path inside
  the main checkout is replaced by the same relative path in the worktree, if that exists there.
  Untracked files and paths outside the checkout are sent unchanged. The pair of directories comes from
  Git (`--show-toplevel` and `--git-common-dir`), so continued sessions behave the same.
- **Commands are text.** Typing `/` at the start of a draft lists the agent's commands whose names
  start with the typed word. ↑/↓ select, Return or Tab insert `/name `, Escape hides the list. Nothing
  is sent until the user sends the draft.
- **Keyboard and mouse.** Files are added by dropping them on the composer, pasting them, or with
  Attach Files… (⇧⌘A). The editor is an `NSTextView`, so pasted and dropped files become attachments
  instead of inserted paths.

## Consequences

- Works with every ACP agent; agents without file tools of their own still read links through the
  client's scoped filesystem when the link points into a root.
- The prompt the agent receives can name a different path than the one the user dropped. The
  transcript shows the attachment's name; the link in the event log is the one that was sent.
- A dropped file that exists only in the checkout reaches the agent with its checkout path, outside the
  session's roots. Copying it into the worktree is a separate decision.
