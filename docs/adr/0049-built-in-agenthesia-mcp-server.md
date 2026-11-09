# 0049. The built-in agenthesia MCP server

- Status: Accepted (2026-11-09)
- Date: 2026-11-09
- Decider: Project owner
- Supersedes in part: [0009](0009-tools-and-mcp.md) (the built-in server's tool list; its transport is kept and
  detailed here). Schedules the built-in server that [0012](0012-defer-cross-agent-memory.md) left after the MVP;
  cross-agent memory stays deferred.
- Related: [0005](0005-event-log.md), [0006](0006-worktree-isolation.md), [0010](0010-prompt-queue-and-steering.md),
  [0015](0015-agent-terminals.md), [0017](0017-continue-saved-sessions.md), [0020](0020-native-elicitation-forms.md),
  [0026](0026-app-wide-session-manager.md), [0041](0041-review-pane.md), [0043](0043-sessions-in-the-project-folder.md),
  [0044](0044-delete-and-archive-sessions.md), [0047](0047-worktrees-from-the-fetched-upstream.md); #93 (invariants of
  cross-agent work), #131 (`asyncTasks`)

## Context

ADR-0009 planned a built-in `agenthesia` MCP server after the MVP: a stdio helper inside the app bundle that talks to
the app, with four tools (`show`, `screenshot`, `ready_for_review`, `delegate`). Nothing of it exists; every session
passes `mcpServers: []` (`SessionController`).

T3 Code, the UI reference, gives its agents about ninety tools in twelve groups (`apps/server/src/mcp/toolkits`):
orchestration (`delegate_task`, `task_status`, `task_cancel`, `t3_thread_read`/`send`/`wait`), inline HTML
(`html_preview`, `html_render`), devices, worktree handoff, pull requests, queue and pending-request control, browser
automation, projects, remote environments and scheduled tasks. ACP agents reach them through a stdio bridge
(`AcpMcpStdioBridge`) that forwards to T3's HTTP MCP server with a token per provider session. T3 tells the agent about
its environment and the tools in three agent-specific ways (`packages/provider-core/src/server/`): Claude through
`--append-system-prompt`, Codex through developer instructions split into sections under 4,000 bytes, and generic ACP
agents through a `<runtime_info>` block added to every prompt and a `<t3_code_instructions>` wrapper around the first
one. The agent list is not in the prompt; `orchestrator_capabilities` returns it on demand.

T3 bounds agent-to-agent work with four mechanisms and no hard limit: a token acts only while its thread owns a live run
(or a background subagent that run started, `assertLiveCaller`); a target may not have broader runtime modes than the
caller (`assertTargetWithinLimits`); credentials carry capabilities; nesting is limited by instructions only (delegation
depth is measured for telemetry, not enforced). Stop holds the queue, drops the completion wakes that delegated tasks
still owe, and stops every delegated child depth first (`docs/orchestration-v2/feature-lifecycles.md`). A delegated
task's completion delivery is durable (`completionDelivery`: pending, acknowledged, disposed), so a result held across a
restart is still delivered.

The owner reviewed T3's set against the issues of M13 (#57–#60) and the infrastructure filed under M9 (#56, #71), and
chose on 2026-11-09 what to port and how.

## Decision

### Transport and identity

- **One helper per session, one socket per app.** The app bundle carries a small executable, `agenthesia-mcp`, in
  `Contents/Helpers`. Every `session/new`, `session/load` and `session/resume` passes it as a stdio server named
  `agenthesia`, for every agent (stdio support is mandatory in ACP). Each agent process (one per session, ADR-0004)
  starts its own helper; a Codex subagent starts one more with the same `env` (spike, #308), so a token may open
  several connections. The helper reads nothing but its two `env` entries, since Codex passes MCP servers only a short
  environment. The helper relays newline-delimited JSON-RPC between its stdio and the app's Unix socket
  verbatim; it parses nothing but its first line, a hello with the token. MCP itself is served by the app.
- **Socket.** One listening socket per app instance, at a short per-user path (`$TMPDIR`, which is per user and `0700`)
  named from a hash of the app's data folder, so the `.dev` build, the installed app and a check under
  `CFFIXED_USER_HOME` never share one, and the path stays under `sun_path`'s 104 bytes. Mode `0600`.
- **Token.** 256 random bits per live session, passed in the server's `env` (`AGENTHESIA_MCP_TOKEN`, with
  `AGENTHESIA_MCP_SOCKET`). The token names the session; it is valid while the session is live and dies with it.
  Continue issues a new one. Distinct `env` per session also keeps an agent from treating two sessions' servers as one.
- **Calls that start work require a running turn.** `delegate`, `session_send` and `task_run` are refused unless the
  calling session has a turn in progress (T3's `assertLiveCaller`). Reading tools work whenever the session is live. A
  native subagent of the agent (Claude's Task, Codex's subagents) inherits the server and the token, so its calls belong
  to the parent session; one that outlives the turn can still read but cannot start work.
- **Own MCP implementation**, like ACP (ADR-0003): `initialize`, `notifications/initialized`, `ping`, `tools/list` and
  `tools/call`, with text and image content, over the existing `JSONRPC` module. No new dependency.

### What the agent is told

Three layers, all through standard mechanisms (principle 8):

1. **MCP `instructions`**, built per session when the helper connects: the client (Agenthesia, its version and build),
   the session's agent and version (from `initialize`), its model and mode (config options, ADR-0019), the project, the
   checkout (worktree or project folder, ADR-0043), branch and base branch, the installed agents, and the rules for the
   tools. Authored as self-contained sections under 4,000 bytes each.
2. **`environment`**, a tool that returns the same facts fresh: agents and models change during a session, and
   `delegate` needs the current list.
3. **A prompt prefix for agents that do not pass `instructions` to the model**: Codex, which shows them only inside
   tool descriptions once its tools are loaded, and Gemini until it is tested; not Claude, which puts them in the system
   prompt (spike, #308). They get a short `<runtime_info>` block with each prompt and the rules wrapped around the
   first one, as T3 does for ACP agents. Native slash commands are left untouched. The transcript shows the prefix as a collapsed *Context from Agenthesia*
   block, never hides it (principle 5), and the event log records it with the prompt.

Every tool also carries a full description, which is all an agent sees when it reads neither.

### Tools

| Tool | What it does | Notes |
|---|---|---|
| `show` | Opens a file at a line, or a file's diff, in the session's file pane | Paths inside the session's roots (ADR-0023); the pane opens only in a window that displays the session, otherwise the card offers Open |
| `ready_for_review` | Records the agent's summary and opens the review pane (ADR-0041) | One notification, as for a finished turn (principle 7) |
| `screenshot` | A PNG of a Simulator (`xcrun simctl io <udid> screenshot`) or of a window (ScreenCaptureKit) | The Simulator needs no permission; a window needs Screen Recording, asked at the first window capture, not at launch |
| `html_render` | Renders a self-contained HTML page offscreen (`WKWebView`) and shows the PNG in the transcript; returns the PNG and the page's console output to the agent | Replaces T3's `html_preview` and `html_render` pair. No network loads; theme variables from system colors; light and dark PNGs so the row never re-renders; a click opens the live page in the file pane |
| `delegate`, `delegate_status`, `delegate_cancel` | Starts a session with another (or the same) agent in a new worktree or the parent's checkout and returns its task; `mode: wait` blocks until the result or at most 240 s (Codex drops an MCP call at 300 s), then returns `still running`; the timeout does not cancel the child | Agents come from `environment`, replacing T3's `orchestrator_capabilities`. The child is an ordinary session in the sidebar; its permissions are answered by the user |
| `session_list`, `session_read`, `session_send` | Lists and reads sessions of the same project, and sends a message to one | `session_send` starts a turn at once (steers or queues behind a running one, ADR-0010); the receiver sees it as a message from another agent session, the developer sees which |
| `request_secret` | A private card with a secure field; returns the path of a one-time file, never the value | File `0600` in a `0700` folder, removed after its timeout (10 minutes by default, at most 60) or with the session; the event log records the request and its outcome, never the value |
| `worktree_handoff` | Moves a session in the project folder (ADR-0043) into a new worktree on a new branch | Runs after the turn ends; the session reopens in the worktree with `session/resume`, which Claude and Codex accept with a new working directory. Uncommitted changes stay in the folder, and the result says so. If the agent refuses the new working directory, the worktree is removed and the session stays where it was |
| `task_run`, `task_output`, `task_stop` | Runs a shell command in the background in a PTY the app owns, reads its output tail, stops it | A fallback for agents without their own background commands; Claude's and Codex's own come from `asyncTasks` (#131). Both kinds share the panel of #61 |
| `environment` | The facts of the instructions, fresh | See above |

Each call goes through the agent's own permission flow and shows in the transcript (ADR-0009). The server executes the
call, so the app writes its own event for it and draws a card from that event (the screenshot, the rendered page, the
delegated task with its status). The agent's generic row for the same call is matched by its ACP `toolCallId`, which
both agents send in `tools/call`'s `_meta` (Claude `claudecode/toolUseId`, Codex `callId`), and folded into the card; an
unmatched row stays an ordinary tool row. A Codex subagent's calls never reach ACP, so their card stands alone.

**Background commands from `task_run`.** `/bin/sh -c` with the session's resolved environment; the working directory
must lie inside the session's roots, as for `terminal/*` (ADR-0015). Output is kept in a 1 MiB buffer; the exit event
records the status and the last 64 KiB. A task outlives its turn and Stop; it ends with its own stop control or with the
session (process group, SIGTERM, then SIGKILL). Its end is delivered to the agent like a delegated result.

### Turns started by agents

- **No limit on chains**, as in T3. An agent may delegate from a delegated session, and two sessions may send to each
  other. The user stops a loop with Stop.
- **Every turn records its origin** in the event log: the user, `session_send` from a session and turn,
  `delegate` (the task), the delivery of a delegated result or a finished `task_run`. The transcript and the sidebar
  label turns that the user did not start; one agent's output is never shown as the developer's words (#93).
- **Stop** ends the session's turn as today, cancels its `session_send` and `delegate` calls that have not started a
  turn yet, drops the deliveries still owed to it, and stops the running turns of its delegated children, depth first.
  Children started with `session_send` are not children; their own Stop stops them.
- **The instructions limit nesting softly**: a delegated session does not delegate unless its task asks for it.

### Delegated tasks across restarts

- The parent's log records `delegationStarted` (task, child session, agent, checkout), the outcome (`completed` with
  the child's last agent message, `failed`, `cancelled`, `interrupted`) and the delivery (`delivered`, `dropped`). The
  child's session record names its parent and task (a migration of the sessions table).
- **A child interrupted by a quit or a crash** gets `failed` for its open turn when it is continued (ADR-0017) and its
  task becomes `interrupted`. Nothing restarts it: the parent learns the status from `delegate_status` and may ask it to
  go on with `session_send`; the user may continue it by hand.
- **A result that arrives while the parent is not live** stays in the parent's log as undelivered and joins the
  parent's queue, marked with its origin, when the user continues the parent.
- **A `wait` does not survive a restart**: the parent's turn is closed as `failed` on Continue, and the parent reads the
  outcome with `delegate_status`.

### Not ported from T3

| T3 tools | Why not |
|---|---|
| `preview_*` (nineteen), `t3_preview_list`, `t3_preview_close` | An automated embedded browser is IDE ground (principle 1) and a large surface; agents have Playwright or Chrome DevTools MCP, which shared servers (M12) can provide |
| `device_list`, `device_open`, `device_close` | Agents drive Simulators with `simctl` in their own shell; only the screenshot is kept |
| `schedule_task` and its siblings, `watch_pull_request`, `unwatch_pull_request` | They start turns with no user action, on a clock or a CI event, and need the app running in the background; that needs its own ADR with a turn budget (#93) |
| `t3_project_*` | Projects are the user's: an agent creating or deleting them takes a decision away from the user (principle 5) |
| `t3_environment_*` | Remote machines; Agenthesia is local |
| `t3_queue_*`, `t3_pending_request_*` | An agent would edit another session's queue or answer questions asked of the user, presenting agent output as the developer's (#93) |
| `t3_thread_configure`, `update`, `organize`, `search`, `fork`, `merge_back`, `transfers`, `create_threads`, `t3_thread_launch`, `t3_thread_interrupt` | Organizing sessions (titles, archive, model, forks, merges) is the user's; new sessions come from `delegate`, stopping a child from `delegate_cancel`, merging from the review pane (ADR-0032) |
| `link_pull_request`, `list_thread_pull_requests`, `*_pull_request_guides` | Pull requests are opened by the app (ADR-0045); guides are a T3 feature |
| `t3_attachment_*` | Agent and app share the machine; files go by path |
| `t3_worktree_list`, `t3_worktree_status`, `t3_workflow_stop` | Git answers the first two; workflows are T3's |
| `t3_background_wait` | Claude-only in T3, and it only marks the thread as working; `asyncTasks` (#131) and `task_run` give the state itself |

## Alternatives

- **Localhost HTTP with a stdio bridge**, T3's design: HTTP for agents that support it, the bridge for the rest. Two
  paths instead of one and a listening port, for no gain on one machine.
- **XPC.** The helper is started by the agent, not by launchd, so it would need a Mach service or a broker to reach the
  app; more machinery than a socket, with the same trust boundary.
- **MCP over ACP (`mcp/message`).** No helper at all, but unstable in ACP (ADR-0009, ADR-0003).
- **An MCP SDK.** Saves the wire types of five methods; adds a dependency and a second JSON-RPC stack beside ours.
- **Agent-specific system prompts**, as T3 gives Claude and Codex: reliable where the adapter accepts them, but agent
  specific (principle 8) and dependent on adapter flags. The prefix of layer 3 covers the same agents through ACP.
- **The prefix for every agent**: needs no spike, but repeats what Claude already reads from `instructions` and spends
  context on every prompt.
- **A budget of automatic turns, or a depth of one**, against loops. Recommended in the discussion; the owner chose T3's
  approach, with Stop as the brake. A budget can be added later from the recorded origins without a migration.
- **`session_send` as a draft in the receiver's composer.** Keeps the user in every hop; the owner chose a direct send,
  covered by the same Stop.
- **A live `WKWebView` per transcript row** for `html_render`: interactive, but one web content process per row in a
  table that must stream at 60 fps (principle 9).
- **Named secrets in the Keychain**: reusable, but they need management and revocation; a one-time file leaves nothing
  behind. Shared MCP servers (#53) will use the Keychain for their own secrets.
- **`background_wait` instead of `task_run`**, or `task_run` alone with #131 closed: the first only marks the session
  as working and needs an agent that tells us about its tasks; the second leaves Claude's and Codex's own background
  commands invisible whenever they ignore the instructions, which they will, since their own tools come first in their
  prompts.

## Consequences and risks

- **Modules.** A new `MCP` module (wire types and the server dispatch, on `JSONRPC`); the `agenthesia-mcp` executable,
  which depends on nothing but the system; the socket listener, token registry and tool handlers in `AgenthesiaCore`;
  cards and the offscreen renderer in `AgenthesiaUI`. The app target copies the helper into `Contents/Helpers` and signs
  it. ARCHITECTURE.md gains the modules when they land.
- **Data.** New event kinds (tool results, origins, delegation and delivery, secret requests without values, task
  exits); a parent link on session records; rendered pages and screenshots as files in a per-session folder of the data
  folder, removed with the session (ADR-0044). Older builds skip unknown event kinds, as the decoder does today.
- **Turns without a human.** With *Always allow* on our tools, or an agent that does not ask for MCP calls, two agents
  can drive each other until the user presses Stop. This is the default: in the spike, Claude's *Auto* and Codex's
  *Auto review* modes ran every call without asking. The origin labels and the sidebar make this visible; the cost is
  real tokens.
- **No ceiling on a child's permissions.** T3 refuses a child with broader runtime modes than its parent; Agenthesia has
  no runtime modes of its own (the agents define them) and no permission policy (ADR-0042, deferred), so a child runs in
  whatever mode its agent starts in.
- **`task_run` runs outside the agent's sandbox.** Codex confines its shell commands; a command run by the app has the
  app's rights. The agent's permission prompt for the call is the only gate, and the instructions say so.
- **`screenshot` of a window** can capture any app the user has open once Screen Recording is granted. The issue
  decides with the owner whether a window capture needs a confirmation in the app on top of the agent's permission.
- **Tokens sit in the agent's environment** and may appear in its logs. Their reach is one session for as long as it is
  live.
- **A slow helper start** would delay a session's first tool call, not its start: `session/new` does not wait for the
  server (spike, #308).

### Spike (2026-11-09, #308)

A throwaway branch passed a minimal server to Claude (`claude-agent-acp` 0.101.0) and Codex (`codex-acp` 2.5.0) with the
owner's consent; Gemini was not installed. The answers are in #308 and shaped the decisions above:

1. Claude shows `instructions` to the model on the first turn; Codex does not (layer 3).
2. Both send the ACP `toolCallId` in `tools/call`'s `_meta` (card matching); a Codex subagent's calls never reach ACP.
3. Neither runs MCP servers in its sandbox; both reach a socket in `$TMPDIR`. Codex passes only a short environment.
4. Both accept `session/resume` with a new working directory (`worktree_handoff`); `session/load` was not tried.
5. Claude's subagents share the parent's server; each Codex subagent starts its own with the same `env`.
6. Codex drops an MCP call at 300 s; Claude had no limit up to 660 s (`delegate`'s `wait` at most 240 s).
7. Image content reaches both models.
8. `session/new` does not wait for the server; `initialize` follows within 0.1 s warm and about 1 s cold.

Still open: Gemini, and the shape of a permission request for our tools (both agents' auto modes asked none).
