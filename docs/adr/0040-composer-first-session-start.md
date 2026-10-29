# 0040. Start a session from the composer

- Status: Accepted
- Date: 2026-10-29
- Decider: Project owner
- Supersedes: "The launch form chooses the project and agent as today" in [0026](0026-app-wide-session-manager.md)
- Related: [0039](0039-t3-style-window-layout.md), [0036](0036-agent-settings-and-installed-sessions.md),
  [0033](0033-agent-sign-in.md), [0006](0006-worktree-isolation.md), [0032](0032-worktree-merge-and-discard.md)

## Context

A new session starts from a grouped form: project directory with Choose…, an agent picker, the custom
command's executable and arguments, an explanation of worktrees and Start Session. The agent starts with
no prompt, and the user then writes the first message in a second screen. T3 Code opens a new thread as
an empty chat whose composer already holds the model and checkout choices; the thread starts with the
first message.

Two facts constrain a copy. ACP config options (model, mode, effort) and slash commands come from the
agent after `session/new`, so they cannot be offered before the agent runs. ADR-0006 and ADR-0032 give
every Git session its own worktree and the launch form does not ask about it, so T3 Code's
"New worktree / Current checkout" choice has no counterpart.

## Decision

**Draft screen.** New Session (⌘N) and a window with no session show a draft: an empty transcript area
with the line "What should the agent do?" and the composer card of ADR-0039. Above the text, the card
shows three chips:

- *Project*: a menu of known projects, most recently used first, and Choose Folder…; it defaults to the
  last project a session was started in.
- *Agent*: a menu of installed agents (newest version each) and local agents, Custom Command…, and
  Manage Agents… (opens Settings → Agents); it defaults to the last agent a session was started with,
  else the first in the list. Custom Command… opens a small sheet with the executable and arguments.
- *Checkout*: a label, not a menu: "New worktree from `<branch>`" for a Git project (the branch checked out
  in the project, `HEAD` short name when detached), "Project folder" otherwise. Its help text explains
  that uncommitted and untracked files are not copied.

The last project and agent are remembered across launches. They are defaults, not settings
(principle 6).

**Start on Send.** Send (Return) with a nonempty draft starts the session with the selected project and
agent and holds the draft (text and attachments) as its initial prompt. When the session becomes idle for
the first time, the initial prompt is submitted exactly like a typed prompt with intent "when ready"; the
draft then clears. Slash commands and config controls appear once the agent reports them; until then the
command list is empty and the pill menus are absent.

- If the agent asks to sign in (ADR-0033), the sign-in panel replaces the composer as today and the initial
  prompt is submitted after sign-in succeeds.
- If startup fails or is cancelled, the session is not started, the draft returns to the composer
  unchanged, and the error is shown in the draft screen.
- Send with an empty draft does nothing; there is no way to start an agent without a first message.
- The initial prompt is held in memory by the owner (`LiveSession`) until it is submitted. It is not
  written to the prompt queue before the session exists, because the queue belongs to a session record.

**Sidebar and keyboard.** A project's context menu offers New Session in Project, which opens a draft with
that project selected. Existing session navigation is unchanged.

## Alternatives

- **A compact sheet** (recent projects and agent, then Start). Smaller change, but keeps two steps and an
  agent that starts with nothing to do.
- **Start the agent when the draft opens** so config options are available while typing. Starts processes
  and worktrees for drafts that may be abandoned, and leaves orphaned worktrees to clean up.
- **A Current checkout option.** Contradicts ADR-0006; a new ADR would have to supersede it first.

## Consequences

- The launch form is removed. `RootView`'s directory, executable and argument state moves into the draft.
- `LiveSession` gains an initial prompt and its submission after the first idle state; startup errors keep
  the draft. Tests cover success, sign-in, failure, cancellation and attachments.
- Model, mode and effort cannot be chosen before the first message. If agents later expose config options
  before `session/new`, the draft can show them.
- Opening a notification or restoring a window is unaffected: they select sessions, not drafts.
