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
session's filesystem roots`: an agent's skills, memory and plans in `~/.agents`, `~/.claude` and the like, the files
M13 will hand an agent in the app's data folder (#314, #315, #316), and an attachment outside the roots (ADR-0018). The
owner hit it on 2026-11-10 when an agent's read of a skill reference failed and the agent went on without it.

For an agent with an unrestricted shell the rule protected nothing for reads: it reads the file with `cat`. For an agent
without a shell, or with one that cannot read outside its workspace, the app's file system is a channel of its own, and
widening it widens what that agent can read.

## Decision

**Reads anywhere, writes inside the roots.**

- `fs/read_text_file` reads a regular UTF-8 text file at any absolute path. A symlink resolves wherever it leads (skill
  folders are often links, `~/.claude/skills/x` to `~/.agents/skills/x`). The other checks stay: no NUL byte, the
  canonical path opened with `O_NOFOLLOW_ANY` and `O_NONBLOCK`, a regular file, and a device or a FIFO is refused
  before it is opened.
- A read is capped at 16 MiB and a larger file fails with `File is larger than 16 MiB` before it is loaded, so a
  multi-gigabyte log or disk image anywhere on the disk cannot exhaust the app's memory. The cap is larger than the
  file preview's 2 MiB because reads inside the checkout had no cap before, and a lock file or a generated source
  there can exceed 2 MiB.
- `fs/write_text_file` stays inside the roots, so what an agent changes through the app stays in the checkout the user
  reviews. A refused write says what is allowed: `Writes are limited to the session's folders: <roots>`, the roots as
  the agent was given them.

**This widens what the app allows; it is not only a fix.** The app's `fs/read_text_file` now reads any file the user can
read: `.env` files, keys, other projects. What stands between an agent and such a file is the agent's own permission
flow, which the app shows; the app adds no policy of its own (ADR-0042 is deferred).

## The three agents

From each agent's installed source (`claude-agent-acp` 0.101.0 with the Claude Agent SDK it bundles, `codex-acp` 2.5.0,
`kimi-code` 2.5.2) and documentation, **not checked live**. The amendment of 2026-11-19 below checked Claude and Codex
live and corrects this table where it disagrees; Kimi stays as it is here, from sources only (#420):

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
- ADR-0018 is outdated where it says the app refuses reads outside the roots: in its Context (`fs/read_text_file`
  refuses a checkout path), and in its Consequences (an agent without file tools of its own reads a link only when it
  points into a root; a file dropped from the checkout reaches the agent outside the roots). Such a link is now read
  through the app wherever it points. A checkout path may still name a different file than the worktree's copy.
- `acp-cli`'s `CLIFileSystem`, a tool for trying the protocol by hand, keeps its working-directory scope for both.

### To check live

Done on 2026-11-19 for Claude and Codex; see the amendment below. Kimi is still open (#420).

## Amendment (2026-11-19): checked live with Claude and Codex

Claude (`claude-agent-acp` 0.101.0, Claude Code 2.1.311) and Codex (`codex-acp` 2.5.0, codex-cli 0.169.0) were run on
2026-11-19 through a throwaway Python ACP client that sends the same client capabilities as `LiveSession`, serves
`fs/*` by this ADR's rules and logs every ACP message, in a throwaway repository with the "outside" files in a scratch
folder, never the owner's real folders. Kimi Code CLI 2.5.2 could not be checked: its subscription has no access to
Kimi Code, so everything above about Kimi is from its sources only (#420).

What the live runs show, and where it corrects the table above:

- **Default modes.** Claude starts in `auto` ("Claude handles permission decisions"). Codex starts in `agent` ("Auto
  review", the adapter's `DEFAULT_AGENT_MODE`; its approvals reviewer is `auto_review`, not the user), not the
  `workspace-write` this ADR assumed. Kimi's is `default`, from sources.
- **Reads outside the working directory.** Claude in `auto` does not ask and reads with its own Read tool; in `default`
  ("Manual") it asks (`session/request_permission`) before reading, so "No, unless the user sets
  `permissions.blockReadsOutsideWorkingDirectories`" is true only of `auto`. Codex in `agent` does not ask and reads
  itself (`cat` through `exec_command`).
- **Writes outside the working directory.** Claude writes with its own Write tool and asks only in `default`; Codex
  writes itself with `apply_patch`. Neither sent a single `fs/read_text_file` or `fs/write_text_file` in any run, so
  neither uses the app's `fs`, which confirms the table's "No" for both. Caveat: the outside folder was under
  `/private/tmp`, which Codex's workspace sandbox keeps writable, so whether Codex asks for a write elsewhere outside
  the workspace is not shown. Memory and plan files the agents write on their own initiative were not triggered, to
  keep them out of the owner's real folders; both agents use the same write tools for them.

So for Claude and Codex, the app's `fs` is no channel at all: they read and write with their own tools, and what stands
between them and a file is their own permission mode, which the app shows as a permission card when it asks. The
conclusion that Kimi is the agent the rule matters for rests on its sources and stays open until #420.
