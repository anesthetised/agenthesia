# 0019. Session config controls

- Status: Accepted
- Date: 2026-10-16
- Decider: Project owner
- Scope: config options picker (#23); builds on ADR-0003 and ADR-0005

## Context

The agent exposes session settings through config options. The ACP adapter already normalizes legacy
modes into these options. The composer needs controls without introducing agent-specific settings or
ambiguous changes to a running turn.

## Decision

- Render supported options in the composer toolbar with native pickers/menus and toggles. Use the
  agent's names, choices and grouping; hide unknown option types.
- Allow changes only while the session is idle (superseded by the amendment of 2026-11-19: the mode changes at once,
  the other options from the next turn). Saved history displays the recorded settings read-only.
- Treat the agent's returned settings as authoritative. Show a change as accepted only after the
  response has been committed to the event log; keep the last confirmed values on request failure
  and show the error. Agent notifications continue through the existing ordered recording path.
- Keep coordination in `SessionController`, with config state reduced from the existing event log.
  Legacy-mode fallback remains in the ACP adapter; the UI does not branch on protocol versions.

## Alternatives

- **Optimistic selection:** faster visual feedback, but requires rollback and can display a setting
  the agent rejected. Rejected in favor of confirmed state with pending feedback.
- **Change settings during a turn:** more flexible, but the point of application depends on the agent.
  Deferred; the first implementation changes settings between turns.

## Consequences

Users see the configuration the agent has confirmed. Config requests and prompt submission must be
coordinated so a new turn cannot overtake an in-flight setting change. No new settings store or
session manager is needed.

## Amendment (2026-11-19): the mode at once, the other settings from the next turn

- Status: Accepted by the owner on 2026-11-10 (#397); implemented in #397's pull request.

The rule "only while the session is idle" kept the user from restricting an
agent that runs in a permissive mode without stopping its turn (VISION principle 5), and a setting meant for the next
message came too late, because the queue sent that message as soon as the turn ended.

### Decision

- **The mode changes at once**, also while a turn runs, stops or waits for a permission answer. As before, the pill
  shows the new value only once the agent confirmed it and the response is recorded; a refusal keeps the confirmed
  value. A permission request that already waits is not answered by the change: it stays until the user answers it or
  the agent withdraws it. A mode confirmed during a turn brings a generic note, until the turn ends, that the agent
  decides when it applies and some apply it from the next turn; the app keeps no per-agent knowledge (owner's decision
  of 2026-11-19, after the review of #419).
- **Every other option changes from the next turn.** A pick during a turn is kept as the session's one pending change
  for that option (`SessionController.pendingConfig`); choosing the confirmed value again drops it. When the turn has
  ended, also by Stop (even when Stop overtook a steering prompt), the pending changes go to the agent one at a time in
  the agent's order, before the next prompt is sent, whether it comes from the queue, from the composer or from
  steering. A pending change that the agent itself makes current is dropped.
- A mode the agent refuses during a turn becomes its pending change for the next turn.
- If the agent refuses a pending change when the turn ends, the change is dropped, the queue pauses (a stored
  `queuePaused` event, as after Stop, unless it is paused already) and the error names every refused change, so the
  queue does not drain with the old settings. A prompt sent now is not sent (`SessionError.configRefused`). The error
  clears when the queue resumes.
- The pending change belongs to the session, not to a queued message: the queue is still sent as one prompt. It is not
  stored in the event log; after a relaunch the confirmed values stand.
- `isChangingConfig` keeps its rule on both paths: every new turn waits in `dispatch` for a change in flight, also a
  mode change made during the last turn, and a prompt typed while the pending changes are applied waits behind them in
  the queue coordinator.

The UI behaviour is in [composer.md](../behavior/composer.md#session-settings) and
[queue.md](../behavior/queue.md#pausing).

### The agents (checked live for Claude and Codex, from sources for Kimi)

Claude and Codex were checked live on 2026-11-19 with a throwaway ACP client that sends `LiveSession`'s client
capabilities and logs every ACP message, in a throwaway repository: Claude through `claude-agent-acp` 0.101.0 (Claude
Code 2.1.311), Codex through `codex-acp` 2.5.0 (codex-cli 0.169.0). Kimi (`kimi-code` 2.5.2) could not be checked: its
subscription has no access to Kimi Code, so what follows for it is read from its installed adapter only (#420).

- **Claude** (checked live): `session/set_config_option` for the mode is accepted during a turn (about 10 ms), with a
  `current_mode_update`, and applies within the turn in both directions: from `default` to `acceptEdits` while a Write
  request waited, the next write needed no request; from `acceptEdits` back to `default`, the next write asked. The
  adapter does not refuse it during a prompt (config changes of a session are only serialised with each other) and
  hands the mode to the Claude Agent SDK's `query.setPermissionMode`.
- **Codex** (checked live): the change is accepted and confirmed in the response, but there is no
  `current_mode_update`, and it applies only from the next turn, in both directions. From read-only to
  workspace-write, the next write in the same turn still asked and the next turn's did not; from workspace-write to
  read-only, the running turn kept writing without asking. So **Codex cannot be restricted during a turn**, which works
  against this amendment's motivation. The adapter only sets the session's `agentMode`, which it reads at `turn/start`.
- **Kimi** (from sources only, not checked live; #420): `setMode` has no check for a running turn (unlike `prompt`,
  which refuses a second turn). It sets the agent's permission mode service, which the permission policies read at each
  tool call, so it should apply within the running turn; it also enters or leaves plan mode.

A permission request that already waited was kept by both Claude and Codex until it was answered: neither withdrew or
answered it because of the mode change, and neither sent a cancel. For Kimi this is from sources: its waiting approvals
are not resolved by `setMode`.

Neither Claude nor Codex refused a mode change during a turn (Kimi's sources show no refusal either), so the refusal
path is covered by tests only.

### Alternatives not taken

- **Every option at once:** the point at which a model or reasoning change applies inside a running turn stays
  unknown and differs between agents.
- **Every option from the next turn:** an agent in a permissive mode could not be restricted without stopping its
  turn.
- **Settings stored with each queued message:** the queue could no longer be sent together as one prompt, and its
  stored format would change.

### Consequences

Codex confirms a mode that its running turn does not use yet, and cannot be restricted during a turn. The pill cannot
tell, because the agent's answer is the only signal (Claude sends a `current_mode_update`, Codex does not), so the
composer's generic grey line is the owner's answer: it says only that the agent decides when the mode applies. The
specific option, a pending pill (`Agent → Read only, next turn`, "This turn keeps the previous mode.") when a mode is
confirmed without a `current_mode_update`, is parked in #421: it is accurate for Codex today but rests on a heuristic
that a new adapter version may break, and it reworks the pill.

A pending change lives only as long as the controller, so a crash or relaunch before the turn ends loses it without a
trace in the history.
