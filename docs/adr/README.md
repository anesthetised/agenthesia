# Architecture Decision Records

Each ADR records one decision: its context, the decision itself and its consequences.
ADRs are immutable once accepted; to change a decision, write a new ADR that supersedes the old one.

| # | Title | Status |
|---|---|---|
| [0001](0001-acp-client-not-harness.md) | ACP client, not an agent harness | Accepted |
| [0002](0002-tech-stack-and-layout.md) | Tech stack and project layout | Accepted |
| [0003](0003-own-acp-implementation.md) | Own ACP implementation | Accepted |
| [0004](0004-agent-runtime.md) | Agent runtime | Accepted |
| [0005](0005-event-log.md) | Event log as the source of truth | Accepted |
| [0006](0006-worktree-isolation.md) | Worktree isolation | Accepted |
| [0007](0007-transcript-rendering.md) | Transcript and text rendering | Accepted; SourceView highlight completion superseded by [0013](0013-source-highlight-attributes.md) |
| [0008](0008-viewer-not-ide.md) | A viewer, not an IDE | Accepted |
| [0009](0009-tools-and-mcp.md) | Tools and MCP | Accepted |
| [0010](0010-prompt-queue-and-steering.md) | Prompt queue and steering | Accepted; empty-draft Command-Return superseded by [0028](0028-empty-draft-sends-queue.md); empty-queue recovery superseded by [0029](0029-empty-queue-recovery.md) |
| [0011](0011-cross-agent-memory.md) | Cross-agent memory | Superseded by [0012](0012-defer-cross-agent-memory.md) |
| [0012](0012-defer-cross-agent-memory.md) | Defer cross-agent memory until after the MVP | Accepted |
| [0013](0013-source-highlight-attributes.md) | Apply SourceView highlighting as attribute edits | Accepted |
| [0014](0014-window-bound-live-sessions.md) | Window-bound live sessions | Accepted; disconnected saved history superseded by [0017](0017-continue-saved-sessions.md); window ownership superseded by [0026](0026-app-wide-session-manager.md) |
| [0015](0015-agent-terminals.md) | Agent terminals | Accepted; ACP semantics, lifecycle and history superseded by [0016](0016-agent-reported-command-output.md) |
| [0016](0016-agent-reported-command-output.md) | Agent-reported command output | Accepted |
| [0017](0017-continue-saved-sessions.md) | Continue saved sessions | Accepted |
| [0018](0018-composer-attachments.md) | Composer attachments and slash commands | Accepted |
| [0019](0019-session-config-controls.md) | Session config controls | Accepted |
| [0020](0020-native-elicitation-forms.md) | Native elicitation forms | Accepted |
| [0021](0021-prompt-queue-lifecycle.md) | Prompt queue lifecycle | Accepted; prompt error responses clarified by [0027](0027-recoverable-prompt-errors.md); empty-draft Command-Return superseded by [0028](0028-empty-draft-sends-queue.md); empty-queue recovery superseded by [0029](0029-empty-queue-recovery.md) |
| [0022](0022-session-scoped-elicitation.md) | Session-scoped elicitation first | Accepted |
| [0023](0023-session-files.md) | Session files and their initial Git revision | Accepted; committed changed paths superseded by [0024](0024-changed-files-session-base.md) |
| [0024](0024-changed-files-session-base.md) | Compare changed files with the session base | Accepted |
| [0025](0025-transcript-paths-and-editor-handoff.md) | Transcript paths and editor handoff | Accepted |
| [0026](0026-app-wide-session-manager.md) | App-wide session manager | Accepted |
| [0027](0027-recoverable-prompt-errors.md) | Keep sessions alive after prompt error responses | Accepted; empty-queue recovery superseded by [0029](0029-empty-queue-recovery.md) |
| [0028](0028-empty-draft-sends-queue.md) | Send the queue when Command-Return has no draft | Accepted; empty-queue recovery superseded by [0029](0029-empty-queue-recovery.md) |
| [0029](0029-empty-queue-recovery.md) | Empty queues do not block fresh prompts after recovery | Accepted |
| [0030](0030-notification-activation-and-identity.md) | Notification activation and identity | Accepted |

Template: Status, Date, Context, Decision, Consequences.
