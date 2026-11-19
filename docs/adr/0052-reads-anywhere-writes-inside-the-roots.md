# 0052. Reads anywhere, writes inside the roots

- Status: Accepted (2026-11-10, #395)
- Date: 2026-11-19
- Decider: Project owner
- Related: [0006](0006-worktree-isolation.md), [0018](0018-composer-attachments.md),
  [0042](0042-allow-edits-in-this-worktree.md)

## Context

The app advertises the ACP client capabilities `fs.readTextFile` and `fs.writeTextFile`, so an agent may send its file
reads and writes to the app. `SessionFileSystem` served both only inside the session's roots: the working directory and
`additionalDirectories`, which the draft never supplies. Everything else was refused with `Path is outside the
session's filesystem roots`: an agent's skills, memory and plans in `~/.agents`, `~/.claude` and the like, the files M13
will hand an agent in the app's data folder (#314, #315, #316), and an attachment outside the roots (ADR-0018). The owner
hit it on 2026-11-10 when an agent's read of a skill reference failed and the agent went on without it.

For an agent with an unrestricted shell the rule protected nothing for reads: it reads the file with `cat`. For an agent
without a shell, or with one that cannot read outside its workspace, the app's file system is a channel of its own, and
widening it widens what that agent can read.

## Decision

**Reads anywhere, writes inside the roots.**

- `fs/read_text_file` reads a regular UTF-8 text file at any absolute path. A symlink resolves wherever it leads (skill
  folders are often links, `~/.claude/skills/x` to `~/.agents/skills/x`). The other checks stay: no NUL byte, the
  canonical path opened with `O_NOFOLLOW_ANY` and `O_NONBLOCK`, a regular file.
- `fs/write_text_file` stays inside the roots, so what an agent changes through the app stays in the checkout the user
  reviews. A refused write says what is allowed: `Writes are limited to the session's folders: <roots>`, the roots as
  the agent was given them.

**This widens what the app allows; it is not only a fix.** The app's `fs/read_text_file` now reads any file the user can
read: `.env` files, keys, other projects. What stands between an agent and such a file is the agent's own permission
flow, which the app shows; the app adds no policy of its own (ADR-0042 is deferred).

## The three agents

From each agent's installed source (`claude-agent-acp` 0.101.0 with the Claude Agent SDK it bundles, `codex-acp` 2.5.0,
`kimi-code` 2.5.2) and documentation, **not checked live**:

| Agent | Uses the app's `fs` | Asks before reading outside its working directory | Writes memory or plans through the app |
|---|---|---|---|
| Claude | No: the adapter forwards `fs/*` but no tool calls it; Read, Write and Edit work on the disk | No, unless the user sets `permissions.blockReadsOutsideWorkingDirectories` | No: memory and plans are written by its own tools |
| Codex | No: commands and patches run in its own sandbox | No: the default `workspace-write` sandbox reads the whole disk and asks for writes outside the workspace | No |
| Kimi | Yes: Read, Write and Edit route their text through `fs/*` when the client advertises it; skills and its own persistence use the disk | No: Read is approved by default everywhere, except sensitive files (`.env`, `id_*` keys, `credentials`) and Git control paths, which ask | Yes for plan mode: the plan file lives in Kimi's session folder under its home directory and is written with Write |

So Kimi is the agent the rule matters for. It reads outside its working directory without asking, and those reads come
from the app alone; its own shell could read the same files only after a prompt. Kimi's sensitive-file prompt still
asks before `.env` and keys. The read the owner saw refused was most likely Kimi's.

## Not taken

- **Stop advertising `fs`** until the editor needs it (#52). Each agent would then use its own disk access, which also
  lets an agent write its own memory and plan files. It throws away the channel the app's editor and the files of M13
  will need, and an agent without disk access of its own could read nothing.
- **Extra roots per agent** (`~/.claude` for Claude, `~/.kimi` for Kimi). Agent-specific knowledge in the client
  (principle 8), and each new agent or folder layout would need an update.
- **A prompt of the app's own** for access outside the roots. The app has no permission policy; that is ADR-0042's
  question and it is deferred.

## Consequences

- An agent reads skill references, the app's data files and attachments outside the checkout through the app.
- Known and accepted: an agent that writes its memory or plan files through the app is still refused outside the
  roots. From source, that is Kimi's plan file in plan mode; the refusal names the folders it may write to.
- ADR-0018's note that `fs/read_text_file` refuses a checkout path outside the roots is outdated: such an attachment is
  now read through the app as well. It may still differ from the worktree's copy.
- `acp-cli`'s `CLIFileSystem`, a tool for trying the protocol by hand, keeps its working-directory scope for both.

### To check live

With the owner's consent, one session each with Claude, Codex and Kimi: whether a read outside the working directory
asks in the default mode, and which of them sends `fs/*` requests for its memory or plan files (the event log shows
them).
