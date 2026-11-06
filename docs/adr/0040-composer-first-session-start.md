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

**Draft screen.** New Session (⇧⌘N) and a window with no session show a draft: an empty transcript area
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

## Amendment (2026-11-02): the draft shows the last mode and model as hints

- Status: Accepted by the owner on 2026-11-06 (#195); not yet implemented. Until it lands, "the pill menus are absent" above describes the code.
- Related: [0019](0019-session-config-controls.md), [0039](0039-t3-style-window-layout.md),
  [0042](0042-allow-edits-in-this-worktree.md)

### Context

ADR-0040 accepted that model and mode cannot be chosen before the first message, because config options exist only
after `session/new`. In practice, the first prompt of each session runs with whatever the agent defaults to, and
choosing a plan mode or a smaller model means sending first and stopping, or starting with a throwaway message. The
ACP specification confirms the constraint: options arrive with the session setup response, and only then. It allows
changing them at any time, and requires a response with the complete list. So the agent cannot tell the draft what it
offers, but the app has heard it before: every `started`, `reopened` and `configOptions` event holds a confirmed list.

### Decision

**Pills as hints.** If the app has a cached list for the selected agent, the composer's bottom row shows its **mode and
model** as the same pill menus a live session has (`SessionConfigControls`). They are hints from a cache, not facts:
the tooltip and the accessibility label say `Last used with this agent; confirmed when the session starts`, and they
are drawn as secondary. Changing a pill changes only this draft (`SessionWindowModel`), and changing the agent resets
them.

**What is shown.** Select options with category `mode` or `model`, which are the agent's own labels; no category, no
pill, and the app does not guess from a name. The specification says categories are for UX and must not be needed for
correctness; here they decide only what the draft offers, and the session's own controls still list everything once
it runs. Effort, booleans and unknown types wait for the session, as before.

**A mode is applied only when chosen in this draft (owner's decision).** The model hint is applied by default. The mode
pill offers the cached choices but reads `Default mode` until the user picks one, and only a mode picked in this draft
is sent to the agent; otherwise the session keeps the mode the agent starts in. So a mode that stops asking for
permission never comes back by itself, because the app cannot recognise such a mode from its name without
agent-specific knowledge (principle 8). The cost is one extra choice for each session started in plan mode.

**Where they are applied.** In `SessionController.createRemote`, after `session/new` returned and **before the
session record is created** (`SessionController.swift:168-195`):

1. Compare the model hint, and a mode picked in this draft, with the options the agent just reported. An equal value
   sends nothing.
2. Otherwise `setConfigOption`, one at a time in the agent's order. Each response is the complete list, and the next
   step uses it, because a change of mode may change what else exists.
3. Write the final list into the `started` event. So history and the composer show the confirmed values and ADR-0019
   holds: the agent's returned settings are authoritative, and nothing is shown as accepted before it is committed.
4. Submit the initial prompt at the first idle state, as ADR-0040 says. After sign-in, this runs in the same place,
   because `session/new` does.

**A rejection returns the draft.** An error response, or a hint whose option or value the agent no longer offers,
fails the start: the draft returns with the text, attachments and error (`The agent does not offer “Plan” any more`).
A session that silently ran in another mode than its pill showed would be the worst outcome here; a mode can be the
difference between read-only and writing. Because the record does not exist yet, the existing path applies:
`removeUnstartedWorktree` (`LiveSession.swift:307`) removes the worktree, `returnToDraft` ends the owner, and nothing
stays in append-only history. The pills then show the list the agent just reported, so the next Send works; one
bounce, at most, per stale hint.

**The cache.** `UserDefaults`, one small JSON value per agent, kept by `AgentCatalog` beside `lastAgent`
(`AgentCatalog.swift:49`), keyed by `AgentCatalog.Choice`, so that an installed agent keeps its hints across versions.
It holds the mode and model options as last confirmed, with their choices and names. Any confirmed list updates it,
except during step 1–2 above: it is written after the hints were applied or the start failed, so that the agent's
default on `session/new` never overwrites the user's choice. Losing the cache costs one session without pills.

**An agent that never reported modes** has no cache entry or an entry without such options, so the draft shows no pills
and behaves exactly as ADR-0040 describes. The first session with an agent always looks like that.

**The changed statement.** ADR-0040's "until then the command list is empty and the pill menus are absent" becomes:
until then the command list is empty and the pill menus are absent, **except for cached mode and model hints**. Its
consequence "Model, mode and effort cannot be chosen before the first message" becomes: mode and model can be chosen
as hints once the agent has reported them in an earlier session; effort cannot.

### Alternatives

- **Read the cache from history** (the last `configOptions` of the agent's newest session). No new store, like the
  default project, but sessions refer to an `agent_install`, which changes across versions, and opening a draft would
  read an append-only log for a value that is safe to lose.
- **Apply after the record exists, through the public `setConfigOption`.** Reuses the path as is, and adds nothing to
  startup. But a rejection then leaves an empty saved session forever and a worktree to discard, because history is
  append-only and #176 removes only unrecorded worktrees.
- **Keep the session and report the rejection in its composer.** No second start, but the worktree, the empty record and
  a composer that shows a mode the user did not pick; and the prompt is one Return from running there. The owner's
  decision is to return the draft.
- **Run with the agent's value when the hint is stale and the user never touched the pill.** Fewer bounces, but the pill
  promised a value; the user would have to read the composer afterwards to find out.
- **Start the agent when the draft opens.** Already rejected in ADR-0040: processes and worktrees for abandoned drafts.
- **Do nothing.** ADR-0040 stands and the first prompt runs with the default.

### Consequences and risks

- **The last mode is not remembered as a default.** Someone who always works in plan mode picks it for each session.
  Reapplying it automatically was rejected: a mode that lets the agent act without asking (for example a "bypass" mode)
  would come back with only a visible pill as the safeguard, and the specification asks agents not to reduce oversight
  without user action. Dropping the mode cache entirely was rejected too, because starting in plan mode is the main gain.
- A stale hint costs an agent start, one bounce and possibly a sign-in check, on an upgrade that removes a value.
- Startup gains round trips before the record exists. `startupUpdates` buffers notifications until the session is
  established, and config responses must keep working there; this is why the issue is `agent:strong`.
- Agents whose options differ per project will bounce once when the user switches projects with a value only one offers.
- `ConfigOption` is stored outside the event log, so a format change must tolerate an undecodable value by ignoring it.

### Not decided

Hints for effort or other categories, a per-project cache, and letting a mode be chosen in the draft for an agent never
run before.

## Amendment (2026-11-07): the first message shows at once

- Status: Accepted by the owner on 2026-11-07 (#220); not yet implemented. Until it lands, "Start on Send" above describes the code.
- Related: [0039](0039-t3-style-window-layout.md), [0043](0043-sessions-in-the-project-folder.md)

### Context

Send holds the draft in memory (`LiveSession.initialPrompt`) and the window shows `Starting session…` in an empty
detail column until the agent is up and the prompt is submitted; with an install check, a sign-in and a worktree to
create, that is several seconds in which the message the user just wrote is nowhere on screen. A failed start brings
it back to the draft, so nothing is lost, but the window reads as if nothing happened.

### Decision

From Send until the first idle state, the detail column shows the **transcript layout with the held message** as its
only row, a user block as ADR-0039's amendment draws it, with its attachments, followed by the status line
`Starting <agent>…` and the compact card ADR-0039 gives sessions that cannot take a prompt (`Starting…`, no Continue).
The row is the held prompt rendered by the same table from a one-item source, so when the session's own transcript
replaces it, the message stays where it was and the layout does not jump.

- If the agent asks to sign in, the sign-in panel replaces the card as today; the message stays above it.
- If startup fails or is cancelled, the draft returns with the text and the error, as today.
- The Checkout chip's choice (ADR-0043) is shown in the status line while starting: `Starting <agent> in a new
  worktree…` or `Starting <agent> in the project folder…`.

### Consequences

- `RootView` shows the held prompt instead of `ContentUnavailableView` while `owner.isStarting`; `LiveTranscript`
  gains a source for a draft, or `TranscriptTable` is fed a one-item `TranscriptSource`.
- The window title is the draft's first line already (ADR-0039 titles); nothing changes there.
