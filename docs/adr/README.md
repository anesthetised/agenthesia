# Architecture Decision Records

Each ADR records one decision: its context, the decision itself and its consequences.
ADRs are immutable once accepted; to change a decision, write a new ADR that supersedes the old one. A narrow
change may instead be a dated amendment at the end of the ADR, with its own status (as in ADR-0039).

**What is an ADR.** A decision that is hard or costly to undo: module boundaries and dependency direction, data format
and storage (including the append-only history), the ACP protocol, the lifecycle of processes and worktrees, security
and permissions, new dependencies, a departure from [VISION.md](../VISION.md). Anything one pull request can change
without a data migration (layout, panes, shortcuts, texts and wording, screen states and transitions, what is shown
where) is UI behavior and lives in [docs/behavior/](../behavior/), edited in place. A UI decision that changes stored data
or the protocol is still an ADR, and its UI behavior is described in the behavior document with a link to it.

Several ADRs below were written before that rule and describe UI behavior. They stay as they are; where the table says
*UI behavior, current state in …*, that document describes how the app behaves now and wins over the ADR's text.

| # | Title | Status |
|---|---|---|
| [0001](0001-acp-client-not-harness.md) | ACP client, not an agent harness | Accepted |
| [0002](0002-tech-stack-and-layout.md) | Tech stack and project layout | Accepted |
| [0003](0003-own-acp-implementation.md) | Own ACP implementation | Accepted |
| [0004](0004-agent-runtime.md) | Agent runtime | Accepted; managed Node and installation decisions superseded by [0034](0034-agent-installs-with-user-runtimes.md) |
| [0005](0005-event-log.md) | Event log as the source of truth | Accepted |
| [0006](0006-worktree-isolation.md) | Worktree isolation | Accepted; merge and discard detailed by [0032](0032-worktree-merge-and-discard.md); a folder choice added by [0043](0043-sessions-in-the-project-folder.md) |
| [0007](0007-transcript-rendering.md) | Transcript and text rendering | Accepted; SourceView highlight completion superseded by [0013](0013-source-highlight-attributes.md) |
| [0008](0008-viewer-not-ide.md) | A viewer, not an IDE | Accepted |
| [0009](0009-tools-and-mcp.md) | Tools and MCP | Accepted; the built-in server's tool list superseded by [0049](0049-built-in-agenthesia-mcp-server.md) |
| [0010](0010-prompt-queue-and-steering.md) | Prompt queue and steering | Accepted; empty-draft Command-Return superseded by [0028](0028-empty-draft-sends-queue.md); empty-queue recovery superseded by [0029](0029-empty-queue-recovery.md); UI behavior, current state in [docs/behavior/queue.md](../behavior/queue.md) |
| [0011](0011-cross-agent-memory.md) | Cross-agent memory | Superseded by [0012](0012-defer-cross-agent-memory.md) |
| [0012](0012-defer-cross-agent-memory.md) | Defer cross-agent memory until after the MVP | Accepted; the built-in MCP server scheduled by [0049](0049-built-in-agenthesia-mcp-server.md) |
| [0013](0013-source-highlight-attributes.md) | Apply SourceView highlighting as attribute edits | Accepted |
| [0014](0014-window-bound-live-sessions.md) | Window-bound live sessions | Accepted; disconnected saved history superseded by [0017](0017-continue-saved-sessions.md); window ownership superseded by [0026](0026-app-wide-session-manager.md) |
| [0015](0015-agent-terminals.md) | Agent terminals | Accepted; ACP semantics, lifecycle and history superseded by [0016](0016-agent-reported-command-output.md) |
| [0016](0016-agent-reported-command-output.md) | Agent-reported command output | Accepted |
| [0017](0017-continue-saved-sessions.md) | Continue saved sessions | Accepted |
| [0018](0018-composer-attachments.md) | Composer attachments and slash commands | Accepted; UI behavior, current state in [docs/behavior/composer.md](../behavior/composer.md) |
| [0019](0019-session-config-controls.md) | Session config controls | Accepted; UI behavior, current state in [docs/behavior/composer.md](../behavior/composer.md) |
| [0020](0020-native-elicitation-forms.md) | Native elicitation forms | Accepted |
| [0021](0021-prompt-queue-lifecycle.md) | Prompt queue lifecycle | Accepted; prompt error responses clarified by [0027](0027-recoverable-prompt-errors.md); empty-draft Command-Return superseded by [0028](0028-empty-draft-sends-queue.md); empty-queue recovery superseded by [0029](0029-empty-queue-recovery.md); UI behavior, current state in [docs/behavior/queue.md](../behavior/queue.md) |
| [0022](0022-session-scoped-elicitation.md) | Session-scoped elicitation first | Accepted |
| [0023](0023-session-files.md) | Session files and their initial Git revision | Accepted; committed changed paths superseded by [0024](0024-changed-files-session-base.md) |
| [0024](0024-changed-files-session-base.md) | Compare changed files with the session base | Accepted; base pin settled by [0032](0032-worktree-merge-and-discard.md) |
| [0025](0025-transcript-paths-and-editor-handoff.md) | Transcript paths and editor handoff | Accepted |
| [0026](0026-app-wide-session-manager.md) | App-wide session manager | Accepted; sidebar superseded by [0039](0039-t3-style-window-layout.md); launch form superseded by [0040](0040-composer-first-session-start.md); amendment (Done mark); UI behavior, current state in [docs/behavior/sidebar.md](../behavior/sidebar.md) |
| [0027](0027-recoverable-prompt-errors.md) | Keep sessions alive after prompt error responses | Accepted; empty-queue recovery superseded by [0029](0029-empty-queue-recovery.md); UI behavior, current state in [docs/behavior/queue.md](../behavior/queue.md) |
| [0028](0028-empty-draft-sends-queue.md) | Send the queue when Command-Return has no draft | Accepted; empty-queue recovery superseded by [0029](0029-empty-queue-recovery.md); UI behavior, current state in [docs/behavior/queue.md](../behavior/queue.md) |
| [0029](0029-empty-queue-recovery.md) | Empty queues do not block fresh prompts after recovery | Accepted; UI behavior, current state in [docs/behavior/queue.md](../behavior/queue.md) |
| [0030](0030-notification-activation-and-identity.md) | Notification activation and identity | Accepted |
| [0031](0031-app-icon-and-dock-tile.md) | App icon and Dock tile | Accepted |
| [0032](0032-worktree-merge-and-discard.md) | Worktree merge and discard | Accepted; branch naming changed by an amendment of [0039](0039-t3-style-window-layout.md), implemented in #208; push and pull requests added by [0045](0045-push-and-pull-requests.md); start from `HEAD` superseded by [0047](0047-worktrees-from-the-fetched-upstream.md) |
| [0033](0033-agent-sign-in.md) | Agent sign-in | Accepted |
| [0034](0034-agent-installs-with-user-runtimes.md) | Agent installs with user-provided runtimes | Accepted |
| [0035](0035-installer-storage-and-script-policy.md) | Installer storage and npm script policy | Accepted |
| [0036](0036-agent-settings-and-installed-sessions.md) | Agent settings and sessions of installed agents | Accepted; UI behavior, current state in [docs/behavior/agents-settings.md](../behavior/agents-settings.md) |
| [0037](0037-local-agents.md) | Local agents | Accepted; UI behavior, current state in [docs/behavior/agents-settings.md](../behavior/agents-settings.md) |
| [0038](0038-pre-session-sign-in.md) | Sign in before a session | Accepted; UI behavior, current state in [docs/behavior/agents-settings.md](../behavior/agents-settings.md) |
| [0039](0039-t3-style-window-layout.md) | A window layout after T3 Code | Accepted; amended (sidebar row, inspector, docked permission); amended (user blocks, collapsed thoughts, plan, context usage); UI behavior, current state in [docs/behavior/sidebar.md](../behavior/sidebar.md), [docs/behavior/composer.md](../behavior/composer.md) |
| [0040](0040-composer-first-session-start.md) | Start a session from the composer | Accepted; amended (mode and model hints); amended (first message shows at once); checkout choice added by [0043](0043-sessions-in-the-project-folder.md); UI behavior, current state in [docs/behavior/session-start.md](../behavior/session-start.md) |
| [0041](0041-review-pane.md) | Review as a pane, with Ask agent | Accepted |
| [0042](0042-allow-edits-in-this-worktree.md) | Allow edits in this worktree | Proposed, deferred |
| [0043](0043-sessions-in-the-project-folder.md) | Sessions in the project folder | Accepted |
| [0044](0044-delete-and-archive-sessions.md) | Delete and archive sessions | Accepted; UI behavior, current state in [docs/behavior/sidebar.md](../behavior/sidebar.md) |
| [0045](0045-push-and-pull-requests.md) | Push after merge, and pull requests from a session | Accepted |
| [0046](0046-session-board-and-menu-bar.md) | A session board, a menu bar item, and numbered sessions | Accepted; UI behavior, current state in [docs/behavior/sidebar.md](../behavior/sidebar.md) |
| [0047](0047-worktrees-from-the-fetched-upstream.md) | Worktrees start from the fetched upstream | Accepted |
| [0048](0048-sessions-without-a-project.md) | Sessions without a project | Accepted |
| [0049](0049-built-in-agenthesia-mcp-server.md) | The built-in agenthesia MCP server | Accepted |

Template: Status, Date, Context, Decision, Consequences.
