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
  the agent withdraws it.
- **Every other option changes from the next turn.** A pick during a turn is kept as the session's one pending change
  for that option (`SessionController.pendingConfig`); choosing the confirmed value again drops it. When the turn has
  ended, also by Stop, the pending changes go to the agent one at a time in the agent's order, before the next prompt
  is sent, whether it comes from the queue, from the composer or from steering.
- A mode the agent refuses during a turn becomes its pending change for the next turn.
- If the agent refuses a pending change when the turn ends, the change is dropped, the queue pauses (a stored
  `queuePaused` event, as after Stop) and the error says which change was refused, so the queue does not drain with
  the old settings.
- The pending change belongs to the session, not to a queued message: the queue is still sent as one prompt. It is not
  stored in the event log; after a relaunch the confirmed values stand.
- `isChangingConfig` keeps its rule on both paths: a drain, a steering prompt and the turn-end application wait for a
  mode change in flight, and a prompt typed while the pending changes are applied waits behind them in the queue
  coordinator.

The UI behaviour is in [composer.md](../behavior/composer.md#session-settings) and
[queue.md](../behavior/queue.md#pausing).

### The agents (from sources, not checked live)

Read from the installed adapters on 2026-11-19; no agent was run. A live check remains.

- **Claude** (`@agentclientprotocol/claude-agent-acp` 0.101.0): `session/set_config_option` for the mode is not
  refused during a prompt; config changes of a session are only serialised with each other. The mode goes to the
  Claude Agent SDK's `query.setPermissionMode`, which the running query consults at its next permission check. A
  waiting permission request is a pending `session/request_permission` that only its answer or the turn's cancellation
  (its abort signal) settles; the mode change does not touch it.
- **Codex** (`@agentclientprotocol/codex-acp` 2.5.0): the mode change is accepted at any time, but it only sets the
  session's `agentMode`, which the adapter reads when it starts a turn (`turn/start` with that mode's approval policy
  and sandbox). The running turn keeps its old approval policy and sandbox; the pill nevertheless shows the new mode,
  because the agent confirms it. A waiting approval is not touched.
- **Kimi** (`kimi-code` 2.5.2): `setMode` has no check for a running turn (unlike `prompt`, which refuses a second
  turn). It sets the agent's permission mode service, which the permission policies read at each tool call, so it
  applies within the running turn; it also enters or leaves plan mode. Waiting approvals are not resolved by it.

None of the three refuses a mode change during a turn, so the refusal path is covered by tests only.

### Alternatives not taken

- **Every option at once:** the point at which a model or reasoning change applies inside a running turn stays
  unknown and differs between agents.
- **Every option from the next turn:** an agent in a permissive mode could not be restricted without stopping its
  turn.
- **Settings stored with each queued message:** the queue could no longer be sent together as one prompt, and its
  stored format would change.

### Consequences

Codex shows a confirmed mode that its running turn does not use yet; the pill cannot tell, because the agent's answer
is the only signal. A pending change lives only as long as the controller, so a crash or relaunch before the turn ends
loses it without a trace in the history.
