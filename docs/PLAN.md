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
- Session config controls show confirmed settings between turns (#23,
  [ADR-0019](adr/0019-session-config-controls.md)); responses are committed before later notifications.
- The durable prompt queue supports editing, ordering, grouped sends and steering (#65,
  [ADR-0010](adr/0010-prompt-queue-and-steering.md), [ADR-0021](adr/0021-prompt-queue-lifecycle.md)). Stop
  pauses it; continued sessions require explicit queue resume. Ended sessions remain available to Continue.
- Native session-scoped elicitation forms appear in the transcript (#24,
  [ADR-0020](adr/0020-native-elicitation-forms.md), [ADR-0022](adr/0022-session-scoped-elicitation.md)).
- Client-side `terminal/*` is deferred (#104), so the rest of M5 waits.

## Current batch

| # | Issue | Depends on | Model and effort |
|---|-------|------------|------------------|
| 1 | #23 Config options picker | Approved ADR-0019 | Sol, medium |
| 2 | #65 Prompt queue and steering | Approved ADR-0021 and ADR-0010 | Sol, high |
| 3 | #24 Native elicitation forms | Approved ADR-0020 | Sol, medium |

The owner approved these decisions on 2026-10-16. All three are implemented in this checkout; the
issues remain open pending review and merge. They were developed in isolated worktrees and integrated
in the order above.

### 1–2. Config options, prompt queue (#23, #65)

- Both extend the composer from #18 (`ComposerInput` in `AgenthesiaUI/Composer.swift`). Its key
  handling is the pure `ComposerInput.keyAction`; Command-Return sends now even while the editor is
  first responder. Queue edits retain non-text attachment blocks.
- The behavior of #65 is fixed by [ADR-0010](adr/0010-prompt-queue-and-steering.md); queue entries are
  persisted in the event log. Queued prompts must keep their attachments.
- [ADR-0019](adr/0019-session-config-controls.md): native config controls, idle-only changes and
  agent-confirmed values committed before display; legacy modes stay in the adapter.
- [ADR-0021](adr/0021-prompt-queue-lifecycle.md): Stop pauses the queue; restored entries require Continue
  and explicit resume. Command-Return sends the draft only; Command-Shift-Return sends queued entries
  plus the nonempty draft last.
- `AgentProfile.steering` already reports whether the agent supports injection.

### 3. Elicitation forms (#24)

- `LiveSession` enables form elicitation; the controller validates and owns session-scoped requests.
  See [ADR-0009](adr/0009-tools-and-mcp.md).
- [ADR-0020](adr/0020-native-elicitation-forms.md): native transcript forms, durable requests and final
  answers, temporary drafts, cancellation on lifecycle termination. URL elicitation is separate work.
- [ADR-0022](adr/0022-session-scoped-elicitation.md): #24 supports established session scopes only;
  request-scoped forms are explicitly declined. Pre-session presentation, persistence and request
  lifetimes are deferred to [#111](https://github.com/anesthetised/agenthesia/issues/111).

## Integration and verification

- The shared base is `fee57ab`, containing the composer and approved decisions. This batch retains
  the composer dependency if it has not landed on main.
- Shared integration points are `SessionController`, `SessionEvent`, `TranscriptState`, `LiveSession`
  and `RootView`. Keep config confirmation, queue admission and form cancellation on the existing
  ordered event path. Queue draining waits for accepted config changes rather than losing its retry.
- Stop must supersede earlier pending steering/resume operations. Injection preparation retains
  recoverable content until acknowledgement; a pre-wire cancelled prompt is requeued and marked not
  sent. A wire turn ending during preparation falls back to a new turn without losing the draft.
- Close drains admitted config, queue and form work. Reopening cancels unfinished forms and leaves
  restored queued entries paused; a failed process reaching `closed` must still offer Continue.
- Use Sol high for lifecycle changes and integration. Medium is sufficient for bounded view work.
  Review changed SwiftUI/AppKit views with `swiftui-pro`. Serialize full builds/tests across worktrees;
  use `just lint`, `just test`, `just coverage` and `just app` for the integrated batch. Benchmarks,
  push and PR creation retain the approvals in `AGENTS.md`.

### Acceptance and verification

| Issue | Acceptance criteria and focused verification |
|---|---|
| #23 | Select/grouped/boolean controls and legacy modes; confirmed settings replay correctly; rejected changes retain confirmed values; prompt submission cannot overtake a config change. |
| #65 | Queue editing/reordering/deletion preserve attachments across replay; combined sends retain message identity; shortcuts, pause/resume and steering obey ADR-0010/0021 under turn-end/cancellation races. |
| #24 | Supported fields validate required values and constraints; optional text can be omitted after editing; concurrent requests resolve once; stop/close/cancellation and recovery leave no pending callers or active historical forms; responses persist before delivery. |

The integration regressions cover config change → send → enqueue → form request → steering/Stop →
close → restore/Continue, checking ordered events, retained attachments and explicit queue resume.
Native hosted-view tests cover form sizing at narrow widths and draft identity across transcript
updates. Integrated `just lint`, `just test`, `just coverage` and `just app` pass; Core line coverage is
97.8%, above its 90% gate. Native app smoke checks cover form submission, attachment-preserving queue
edits, steering shortcuts, Stop, End Session, Continue and explicit queue resume. Keyboard actions and
accessibility labels were inspected; a spoken VoiceOver pass remains manual. Config response ordering
and model selection are covered by protocol tests; native popup selection was not completed by UI
automation.

CI pins Xcode 26.6 and runs package coverage and the app build in parallel with separate incremental
build caches. The aggregate `Lint, test, build` status requires both jobs to pass; cache hits still run
all checks. Badge publication runs only after both succeed on main.

## Next steps

Review and land the current batch, then M4 (Files), M7 (Parallel sessions), M8 (Worktrees).
Small independent chores such as #73 (CI with Xcode 27) fit Sonnet at medium effort.

## Open research

Not scheduled, pick up when they block something: #77, #78, #83 (transcript and highlighting hitches),
#97 (streaming performance), #98 (raw-notification contract), #91 (`posix_spawn` lifecycle).
