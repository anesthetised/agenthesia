# Work plan

The near-term order of work, for agents and humans picking up the next task. Milestones and issues on
GitHub stay the source of truth for scope; this file records order, dependencies, and the pitfalls known
so far. Update it when a step lands or the order changes.

Every step follows [AGENTS.md](../AGENTS.md): issue → branch → tests and docs → pull request after the
owner's approval. Architectural choices are presented to the owner as options with a recommendation
before implementation.

## State (2026-10-16)

- Live sessions run end-to-end in one window ([ADR-0014](adr/0014-window-bound-live-sessions.md)): tool call
  cards, permission requests, scoped filesystem, agent-reported command output
  ([ADR-0016](adr/0016-agent-reported-command-output.md)).
- Saved history opens read-only; Continue reattaches it to its agent
  ([ADR-0017](adr/0017-continue-saved-sessions.md)).
- Tool call diffs render as unified diffs with word-level highlights (#20); side-by-side is not scheduled.
- The composer attaches files as `resource_link` and lists the agent's slash commands
  ([ADR-0018](adr/0018-composer-attachments.md), #18).
  Command rows retain their names inside the Commands accessibility group and use command names for
  identity and scrolling. Attachment chips retain their file icons across draft edits.
- Client-side `terminal/*` is deferred (#104), so the rest of M5 waits.

## Next steps

| # | Issue | Depends on | Model and effort |
|---|-------|------------|------------------|
| 1 | #23 Config options picker | Approved ADR-0019 | Sol, medium |
| 2 | #65 Prompt queue and steering | Approved ADR-0021 and ADR-0010 | Sol, high |
| 3 | #24 Native elicitation forms | Approved ADR-0020 | Sol, medium |

The owner approved these decisions on 2026-10-16. They are ready for implementation, not yet shipped.
The order above is the integration order; implementation may proceed in parallel as described below.

Then M4 (Files), M7 (Parallel sessions), M8 (Worktrees). Small independent chores such as #73 (CI with
Xcode 27) fit Sonnet at medium effort.

### 1–2. Config options, prompt queue (#23, #65)

- Both extend the composer from #18 (`ComposerInput` in `AgenthesiaUI/Composer.swift`). Its key
  handling is the pure `ComposerInput.keyAction`; ⌘Return still sends and becomes "send now" in #65.
- The behavior of #65 is fixed by [ADR-0010](adr/0010-prompt-queue-and-steering.md); queue entries are
  persisted in the event log. Queued prompts must keep their attachments.
- [ADR-0019](adr/0019-session-config-controls.md): native config controls, idle-only changes and
  agent-confirmed values committed before display; legacy modes stay in the adapter.
- [ADR-0021](adr/0021-prompt-queue-lifecycle.md): Stop pauses the queue; restored entries require Continue
  and explicit resume. Command-Return sends the draft only; Command-Shift-Return sends queued entries
  plus the nonempty draft last.
- `AgentProfile.steering` already reports whether the agent supports injection.

### 3. Elicitation forms (#24)

- The adapter is created with `elicitation: false` in `LiveSession`; the delegate's default declines.
  See [ADR-0009](adr/0009-tools-and-mcp.md).
- [ADR-0020](adr/0020-native-elicitation-forms.md): native transcript forms, durable requests and final
  answers, temporary drafts, cancellation on lifecycle termination. URL elicitation is separate work.

## Implementation handoff and parallel work

- **Switch from Astra to Sol after recording these decisions.** Use high effort for coordination,
  #65 and integration; medium is sufficient for the bounded #23 and #24 implementations. Return to
  architectural review if implementation uncovers a conflict with an accepted ADR or a protocol
  limitation that changes the agreed behavior.
- **Start subagents after the shared documentation commit and worktree setup.** Use one branch and
  worktree per existing issue, all based on the same commit containing the composer and these ADRs.
  If the composer has not landed on main, retain that base dependency explicitly.
- Three subagents may implement #23, #65 and #24 concurrently. Each owns its feature's logic, views
  and tests in its own worktree. The coordinator owns integration, shared-contract decisions and
  updates to this plan. Worktree isolation does not make changes to shared state independent.
- Shared integration points are `SessionController`, `SessionEvent`, `TranscriptState`, `LiveSession`
  and `RootView`; #65 also owns composer keyboard behavior. Coordinate public entry points and event
  cases before parallel edits, and avoid unrelated refactors of these files.
- Integrate #23, then #65, then #24. Reconcile lifecycle behavior explicitly: pending config changes
  versus sending, queue drain versus Stop, and pending forms versus steering/close/recovery. Each
  feature must build and pass its checks before the next integration.
- Serialize full builds and test suites across worktrees to avoid competing compiler/test processes.
  Every changed SwiftUI/AppKit view receives `swiftui-pro` review. Before commits, run `just lint` and
  `just test`; verify integrated code with `just coverage` and `just app`. Benchmarks require a separate
  agreement on workload and resource use. Push and PR creation retain the approvals in `AGENTS.md`.

### Acceptance and verification

| Issue | Acceptance criteria and focused verification |
|---|---|
| #23 | Select/grouped/boolean controls and legacy modes; confirmed settings replay correctly; rejected changes retain confirmed values; prompt submission cannot overtake a config change. |
| #65 | Queue editing/reordering/deletion preserve attachments across replay; combined sends retain message identity; shortcuts, pause/resume and steering obey ADR-0010/0021 under turn-end/cancellation races. |
| #24 | Supported fields validate required values and constraints; concurrent requests resolve once; stop/close/cancellation and recovery leave no pending callers or active historical forms; responses persist before delivery. |

Integration checkpoint: exercise config change → send → enqueue → form request → steering/Stop →
close → restore/Continue with the scenario agent, checking ordered events, retained attachments and
explicit queue resume. Check keyboard access, VoiceOver labels and narrow-window layout in the app.

## Open research

Not scheduled, pick up when they block something: #77, #78, #83 (transcript and highlighting hitches),
#97 (streaming performance), #98 (raw-notification contract), #91 (`posix_spawn` lifecycle).
