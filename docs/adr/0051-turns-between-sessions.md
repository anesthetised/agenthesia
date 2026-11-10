# 0051. Turns between sessions

- Status: Accepted (2026-11-10, #354)
- Date: 2026-11-10
- Decider: Project owner
- Amends: [0049](0049-built-in-agenthesia-mcp-server.md) (*Turns started by agents*, `session_send`, the delivery of
  results, the socket's checks, the wrapper); [0010](0010-prompt-queue-and-steering.md) and
  [0021](0021-prompt-queue-lifecycle.md) (the queue takes messages the user did not send);
  [0029](0029-empty-queue-recovery.md) is read with this ADR's meaning of an empty queue
- Related: [0005](0005-event-log.md), [0017](0017-continue-saved-sessions.md),
  [0044](0044-delete-and-archive-sessions.md), [0050](0050-settled-is-the-users-decision.md); #93 (invariants of
  cross-agent work), #257 (Send to Session…), #307 (M13), #308 (spike)

## Context

ADR-0049 lets agents start turns: `delegate` starts a child session, `session_send` sends a message to any session of
the project, and a delegated result or a finished `task_run` is delivered to the session that asked for it. It puts no
limit on chains and makes Stop the brake. The owner reviewed that part on 2026-11-10, with the spike's answers (#308)
and the code at `f089e49`, and found it unsafe in four ways:

- **No human is in the loop.** #93 counted every agent-started turn as approved by the user, because a `delegate` call
  goes through the agent's permission flow. In the spike neither Claude's *Auto* nor Codex's *Auto review* mode asked
  permission for our tools, so these turns run with no human action.
- **Stop neither reaches a peer nor sticks.** Two sessions that send to each other are not parent and child, so Stop in
  one does not stop the other. And Stop pauses the queue, but `SessionController.submit(.whenReady)` starts a turn in an
  idle session with an empty queue whether or not it is paused, so the next message from another session restarts a
  session the user just stopped.
- **A sender learns nothing.** `session_send` returned nothing, and the receiver's wrapper names no source (`another
  agent session`, `QueuedPrompt.Origin.wrapped`): a reply has no address, and the sender can only poll `session_read`.
  Only completed delegated results were delivered; a parent that ended its turn to wait for a child that failed or was
  interrupted was never woken.
- **The queue has one author.** `queueChanged` stores the whole queue, so n queued messages write n snapshots. A drain
  sends every entry as one turn whose origin is the first entry's, which would merge the user's draft with an agent's
  message. `submit` returns nothing, and send-now cancels the running turn and its pending permission requests
  (`requestStop`) whoever started that turn. The automatic drain is `Task { try? … }`, so a failed drain is silent.

The socket has gaps of its own: the token is checked once, at the hello; `MCPTokens.revoke` removes the map entry and
leaves open connections served; any process of the user that holds a token is that session; and the hello's five
seconds apply to each byte read, not to the hello (`MCPSocket.hello`).

This ADR records the owner's decisions of 2026-11-10. ADR-0049 stays in force where this one is silent.

## Decision

### Messages travel along delegation edges

- **`session_send` addresses only the caller's parent or one of its own children.** Any other target, a sibling
  included, is refused with a result that names the rule. Every session therefore belongs to one tree whose root is a
  session the user started, and every agent-started turn has a root: Stop, the turn counter and the cost are per tree.
- **Messages between unrelated sessions are carried by the user**, with Send to Session… (#257).
- `session_list` and `session_read` keep ADR-0049's reach, every session of the project; a session without a project
  sees its own tree. `delegate` still works from a delegated session, with no depth limit; the instructions limit
  nesting softly (ADR-0049).

### Stop is sticky

- **A paused queue holds what the user did not send.** A message the user did not send never starts a turn in a session
  whose queue is paused: it gets the disposition `held` and waits in the queue with its origin, even when the queue was
  empty. The user's Stop pauses the queue, as it does today (ADR-0021), so after Stop nothing starts there until the
  user says so. An error or a refusal pauses the queue too and holds the same way, since ADR-0021 leaves what runs next
  to the user after those as well.
- **The hold ends when the user sends a message or resumes the queue.** In ADR-0029's rules an empty queue now means
  one with no entry of the user's: Return on an idle session where only held entries wait sends the draft at once and
  clears the pause, and the held entries drain after that turn. Resume Queue sends them at once when the session is
  idle.
- **Stop reaches the subtree.** Stop in a session stops its running turn and the running turns of its descendants,
  depth first (ADR-0049), and pauses the queues of all of them, idle ones included, so that a stopped grandchild's
  outcome cannot start a turn in its idle parent. Stop also cancels the stopped turns' tool calls in flight, a
  `delegate` whose child has not started yet included.
- **Stop Tree**, on any member of a tree, does the same from the tree's root. **Stop All Agents**, in the Session menu
  and the menu bar item, stops every running turn and pauses the queue of every live session; it is disabled when
  nothing runs.
- **Results are held, not dropped.** ADR-0049 dropped the deliveries owed to a stopped session, as T3 Code does. Under
  the hold a delivery waits in the queue, visible and deletable, and the agent learns what happened when the user lets
  it go on.
- **Resume reaches the subtree.** Resume Queue on a session resumes its queue and the paused queues of all its
  descendants, as Stop paused them. The user's message releases only the session it is sent in: until the user resumes,
  a message the parent sends to a held child gets `held`, and `next` tells the agent that the user holds that session.

### Chains are counted, not limited

No limit on chains and no pause, as ADR-0049 decided. A pure function counts, from the stored origins, the turns that
agents started in a tree since the user's last message in it; the root's card and row show the count with the tree's
cost (#365).

### Replies, and what every result says

- **`session_send(reply: true)` is a task**, as a `delegate` is, without a new session. The reply is the last agent
  message of the turn that handles the message; it is delivered to the sender like a delegated result, with the same
  outcomes, size limit and delivery. Deleting the queued message from the receiver's queue ends the task `cancelled`.
  No tool waits for a reply or polls for one.
- **Every result says what happened and what to do now.** `delegate`, `session_send` and `task_run` return a
  `disposition`: `started`, `queued`, `held`, or `refused` with the reason. Their results, and those of
  `delegate_status` and `delegate_cancel`, carry `next`, one sentence that tells the agent what to do now, such as
  `End your turn; the reply arrives as a message.` A receiver that is not live is refused by name; nothing continues it.

### The queue takes several authors

- **`submit` takes the message's origin and returns its disposition.** The user's sends keep their behavior.
- **An appended-entry event.** `queueAppended(prompt)` appends one entry; `queueChanged` stays for edits, deletions and
  reordering, and logs written with it decode as before.
- **Draining by author.** A drain sends, as one turn, the run of entries at the front of the queue that share the first
  entry's author: all the user's, or all not the user's. The user's messages are never sent in one turn with messages
  the user did not send; deliveries and messages that wait together are sent together, and each reply task among them
  is answered by that turn's last agent message.
- **No interruption by agents.** A message the user did not send never cancels a turn the user started and never
  cancels a pending permission request or input form. A steer (`session_send` with `mode: steer`) is honoured only from
  a parent to its own child, and only while the child's running turn was not started by the user and nothing in it waits
  for the user; otherwise the message queues. The transcript's red `Run interrupted · Stopped by user` divider stays
  for the user's Stop.
- **A failed automatic drain** is recorded and shown as the queue's error.
- **In the queue**, an entry the user did not send shows its origin, can be deleted but not edited, and is not recalled
  by ↑ (#366); how it looks is in [docs/behavior/queue.md](../behavior/queue.md).

### Delivery

- **Every outcome is delivered.** `completed`, `failed`, `interrupted` and `cancelled` reach the caller through its
  queue with the origin `delivery(taskID)`; the three that are not `completed` also raise the caller among the rows
  that need the user.
- **A size limit.** The delivered result is the last agent message cut at 32 KiB, with a note that `session_read`
  returns the rest.
- **One transaction.** A child's end of turn and the outcome in its parent's log are written in one transaction; one
  database already holds every session's log, and one writer per session (#355) makes the append safe while either is
  loaded. A launch reconciles a child that ended with no outcome in its parent.
- **A start timeout.** A child that does not answer `initialize` or `session/new` within 20 s, or that asks to sign in,
  fails its task instead of leaving the parent waiting.
- **Across restarts** ADR-0049 holds, and its `interrupted` outcome is now delivered. A parent that is not live finds
  its deliveries in its queue on Continue, paused like every retained entry (ADR-0029).
- `delegate`'s `wait` also returns when the child asks the user for something, and ends when the caller's turn is
  cancelled (MCP `notifications/cancelled`).

### The socket

- **Every `tools/call` checks** that the token is still live and, for the tools that start work, that the caller has a
  running turn.
- **Revoking a token closes** the session's open connections.
- **One deadline for the hello**, five seconds from the connection, and a cap on hellos pending at once.
- **The peer's process group** (`LOCAL_PEERPID`) must be the group of the session's agent process, which already runs
  in a private group (`AgentProcess`). #321 checks Claude, Codex and the helper a Codex subagent starts; if a real
  agent cannot pass, the check is dropped and the reason recorded in an amendment to this ADR.

### What the receiver is told

- The wrapper names the source session's id, title, agent and model, and its relation to the receiver (`parent` or
  `subtask`); it says that the content is data from that session, not instructions from the user, and whether a reply
  is expected, which the turn's last message gives without another `session_send`.
- Each message is fenced by a delimiter that carries a random token per message, so content cannot close the fence.
- The transcript's label is unchanged, `From <title> · <agent>`. This replaces the anonymous source of ADR-0049's
  wrapper; #93 keeps anonymity for a reviewer (#259), where identity bias matters.

## Alternatives

- **A pause after a number of agent turns in a tree** (#344): the root moves to Needs You until the user continues. It
  stops a chain that runs while the user is away, but it may interrupt legitimate long work; the owner chose a visible
  counter. Kept on record.
- **`session_send` beyond the tree** (#345): to siblings, or to any session of the project as ADR-0049 decided. Siblings
  keep loops inside a tree; any session leaves two peers that Stop in one does not stop. #257 tries messages between
  unrelated sessions with the user carrying them. Kept on record.
- **A cap on queued messages from agents** (#346): bounds a sender in a loop, but with edges and the hold only a held
  session's own parent and children can fill its queue, and the tree's Stop ends that. Kept on record.
- **`session_read` limited to the caller's tree** (#347): keeps one provider from reading what the user wrote for
  another, but takes away the earlier work that a delegated reviewer or a second attempt reads. Kept on record.
- **A fully anonymous source**, as ADR-0049 and #93 had: keeps the receiver from judging a message by its author, but
  leaves a reply without an address and the receiver unable to tell its parent from its child.
- **A send without replies**: a sender then polls `session_read`, which spends turns and tokens, or asks the receiver to
  send back, which is a second message and relies on instructions.
- **A budget of agent turns per tree**, recommended in ADR-0049's discussion: rejected again; the counter shows a chain,
  Stop stops it. It can still be added from the stored origins without a migration.
- **A hold separate from the pause**: a second stored state for the same thing. The pause already ends with the user's
  send or Resume (ADR-0029), which is the release the owner chose.
- **Releasing the hold one session at a time**: Resume on a parent would leave its held children held, so after a Stop
  each child waits for the user separately. Rejected by the owner on 2026-11-10 in favour of a Resume that reaches the
  subtree, which mirrors Stop.
- **Dropping deliveries on Stop**, as T3 Code and ADR-0049 do: no turn starts either way, but a dropped result leaves
  the agent unaware of what its children did.

## Consequences and risks

- **Data.** New event kinds: `queueAppended`, and task events in the caller's log. ADR-0049's `delegationStarted`,
  outcome and delivery describe a task, not a session: a task has a kind (a delegation, a reply, a background command),
  and only a delegation has a session of its own. A reply's task names the receiving session and the message; the
  queued message's origin records the task, so the receiver's turn answers it after a relaunch too. The session table's
  migration of #60 (parent, task, agent name) is unchanged. Older builds skip unknown kinds; one that edits a queue
  written with `queueAppended` rewrites it with the entries it saw, so going back to an older build can lose queued
  messages from agents.
- **A session core before wave 3.** One log writer per session (#355), a turn router that reports the end of every turn
  and routes Stop through the session manager (#356), the queue (#357), the sticky Stop (#358) and the removal of the
  legacy `send` path (#359) land before `delegate` and `session_send`; the socket (#360), the `MCP` module's tool-call
  context and cancellation (#361) and the wrapper (#362) beside them. The order is in [PLAN.md](../PLAN.md).
- **Resume also releases a child that paused on its own.** A descendant whose queue paused after its own error or
  refusal is resumed with the rest of the subtree; Resume on that child alone is the way to release only part of a
  tree.
- **A held queue has no bound** (#346); with edges and Stop Tree, only the tree can fill it.
- **The process-group check may fail for a real agent** that starts its MCP servers in a group of their own; the check
  is then dropped, and a token in the agent's environment is again enough to act as the session.
- **Reads cross providers.** `session_read` sends one agent's transcript to another agent's provider with no action of
  the user (#347).
- **Instructions.** The rules (edges, replies, end the turn instead of polling, read `next`) go into the MCP
  instructions (#310).
- **Behavior documents.** `queue.md` (#357, #358), `menu-bar.md` (Stop All Agents), `sidebar.md` and `board.md`
  (#363–#365), `transcript.md` (#362, #366) and `tools.md` (#312, #317, #318) describe the UI as each issue lands.
- **#93.** Its first invariant now says that agent-started turns run without human action and that Stop is sticky; its
  working assumption names the source in delegation and keeps review anonymous.
