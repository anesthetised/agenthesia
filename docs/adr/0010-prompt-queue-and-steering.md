# 0010. Prompt queue and steering

- Status: Accepted
- Date: 2026-10-05

## Context

Users want to keep typing while an agent works: either to line up follow-ups or to redirect the agent
right away (steering).

- In ACP v1, `session/prompt` spans the whole turn. There is no way to insert a message into a running
  turn; the only option is to cancel the turn (`session/cancel`) and send a new prompt. Changes the agent
  already made and the conversation context are kept.
- In the ACP v2 draft, `session/prompt` responds once the user message is inserted into the
  conversation, which lays the groundwork for queueing and steering. The draft explicitly leaves
  queueing, steering and inserting prompts while busy up to the agent.

## Decision

- **Client-side queue, per session.** Works with every agent and protocol version. Queued messages are
  shown as a stack above the composer; each can be edited (↑ in an empty composer recalls the last one),
  deleted or reordered. The queue is stored in the event log and survives restarts.
- **Enter — send when the agent is ready.** If the agent is idle and the queue is empty, the message is
  sent immediately; otherwise it is appended to the queue.
- **At the end of a turn, the whole queue is sent as one prompt**, so the agent sees all follow-ups at
  once.
- **If the turn ended with an error or a refusal, the queue pauses** instead of draining, with a visible
  indication and a one-key resume.
- **⌘Enter — send now.** **⌘⇧Enter — send the whole queue now.** Both use the session's steering
  strategy:
  - *inject* — when the agent supports inserting messages into a running turn (ACP v2 or an ACP
    extension), the message is inserted without interrupting;
  - *interrupt and send* — otherwise: cancel the turn, then send the message as a new prompt. The
    transcript marks the turn as interrupted.
- **⌘. — stop the agent** (the macOS convention for cancelling an operation).
- **⇧Enter — new line.**
- `AgentConnection` exposes the steering strategy as a capability; the UI never branches on protocol
  versions.

## Consequences

- Steering works today with every agent, at the cost of interrupting the turn on v1.
- Agents that gain native insertion get non-interrupting steering without UI changes.
- Merging the queue into one prompt changes how a "turn" maps to user messages; the transcript shows
  the queued messages individually but marks them as sent together.
