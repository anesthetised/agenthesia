# UI behavior

These documents say how the app behaves **now**, one area per file. They are edited in place: a pull request that
changes UI behavior changes the document in the same pull request as the code, deleting the old behavior from the text
rather than striking it through. To learn how something works, read its file here, not the chain of ADRs that led to it.

## ADR or behavior document

- **ADR** ([docs/adr/](../adr/)): a decision that is hard or costly to undo — module boundaries and dependency
  direction, data format and storage (including the append-only history), the ACP protocol, the lifecycle of processes
  and worktrees, security and permissions, new dependencies, a departure from [VISION.md](../VISION.md).
- **Behavior document** (here): anything one pull request can change without a data migration — layout, panes,
  shortcuts, texts and wording, screen states and transitions, what is shown where.
- A UI decision that changes stored data or the protocol is an ADR (for example
  [ADR-0044](../adr/0044-delete-and-archive-sessions.md), delete and archive), and the UI behavior it brings is described
  here with a link to it.

Noticeable UX changes are still decided with the owner first (AGENTS.md); the document records the outcome.

## Areas

| File | Covers |
|---|---|
| [queue.md](queue.md) | The prompt queue: Send, Queue, steering, pausing, recovery after errors |
| [sidebar.md](sidebar.md) | Sections, rows, search, navigation between sessions, row actions |
| [composer.md](composer.md) | The composer card: text, attachments, slash commands, config controls, Send and Stop |
| [session-start.md](session-start.md) | The draft: project, agent and checkout, hints, Send, starting and failed starts |
| [file-pane.md](file-pane.md) | The file pane and the links in the Markdown preview and the transcript |
| [agents-settings.md](agents-settings.md) | Settings → Agents: installed, local and registry agents, runtimes, sign-in from Settings |
| [transcript.md](transcript.md) | The transcript: selecting rows, Copy, keyboard navigation |
| [merge.md](merge.md) | The merge sheet and the push after a merge |
| [inspector.md](inspector.md) | The inspector: plan, changed files, workspace, agent |

Not written yet, each by the first pull request that changes it: review, permissions and forms,
session sign-in, notifications and the Dock, the board and the menu bar.

## File template

```markdown
# <Area>

One paragraph: what this area is and where it is in the window.

## <Topic>

Current behavior, in short statements: what the user sees and does, the exact wording, shortcuts, states and
transitions. A short *Why:* after a point whose reason is not obvious. Links to the ADRs that constrain it, for
storage, protocol or lifecycle.

## Changes

- 2026-11-08, #261: summarised from ADR-0010, ADR-0021 … (newest first, one line each).
```

Keep implementation detail (types, functions) in [ARCHITECTURE.md](../ARCHITECTURE.md); name a type here only when it
helps find the code.
