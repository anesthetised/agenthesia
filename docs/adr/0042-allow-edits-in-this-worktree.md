# 0042. Allow edits in this worktree

- Status: Proposed, deferred by the owner on 2026-11-02 (#195). It is not part of M15 and starts no work. It is revisited
  after the docked permission card has shipped, with a count of how many prompts are edits.
- Date: 2026-11-02
- Decider: Project owner
- Related: [0006](0006-worktree-isolation.md), [0032](0032-worktree-merge-and-discard.md),
  [0039](0039-t3-style-window-layout.md), [0026](0026-app-wide-session-manager.md)

## Context

The vision has developers running several agents at once in isolated worktrees, with nothing reaching their branch
without review. An edit inside a session's worktree is therefore the most recoverable thing an agent does: it stays on
a session branch, and the review and squash merge of ADR-0032 stand between it and the user's branch. Yet each such edit
stops the agent until someone answers, and with several agents, those prompts are the main interruption. The app keeps
no permission policy today: "the app keeps no policy of its own" (ARCHITECTURE.md), and "always" belongs to the agent.

**How often this happens has not been measured.** The log records each request with its kind, so the share of edits can
be counted; this ADR did not read the owner's history. See the order of work below.

ACP allows this. From the [tool calls specification](https://agentclientprotocol.com/protocol/tool-calls): "Clients
**MAY** automatically allow or reject permission requests according to the user settings", and "Automatic approval
**SHOULD NOT** rely only on `title` or option `name`".

The owner chose this feature knowing the reviewer's objection. That objection is the most important part of this
record, and it is stated first.

## The objection

**It moves the trust boundary.** Today, a person decides every request the agent chooses to raise. With this on, the
client decides some of them. Principle 5 still holds in the letter, because the edit can be seen and undone before it
reaches the branch. But what used to be a decision in the moment becomes something to catch afterwards, in a review that
people get less careful about the more of it there is.

**It trusts what the agent reports.** The rule reads `kind` and `locations`, and the protocol never promised those for
this purpose:

- Tool kinds "help Clients choose appropriate icons and optimize how they display tool execution progress".
- "Locations are display metadata and do not grant file access."
- Both are supplied by the agent, with no way for the client to verify them. An adapter may label a shell-backed tool
  `edit`; a location may list one file while the tool writes three; a tool may change its target after the answer. The
  specification says that agents **SHOULD** request again if the resolved target changes, which is a should.

**A worktree is not a sandbox.** The agent is a process with the user's rights, and its edits do not pass through the
client: an agent's own edit tool writes directly, and the client's `ScopedFileAccess` only covers `fs/*` calls ("This is
a path policy, not a sandbox for other processes", `ScopedFileAccess.swift:7`). The check runs when the request arrives;
the write happens later, and a symlink can change in between. In the other direction, a file inside the worktree can
be dangerous without ever leaving it:

- **Edit, then execute.** An auto-allowed change to `Makefile`, `package.json`, `justfile` or a test script makes a later
  `just test`, which looks harmless and which the user approves, run whatever the edit put there, with the user's
  environment and credentials. This is the most serious path. It needs no misreporting at all: only a model that was
  misled, for example by text it read in the repository.
- **Edit, then merge.** The final merge commit runs the user's hooks in the project checkout after `git merge --squash`
  has written the session's files there (ADR-0032). With `core.hooksPath` inside the repository, an edited hook runs on
  the user's machine at merge.
- **Edit the agent's own settings.** A project-level settings file can give an agent more permissions or hooks, after
  which later tool calls may not ask at all.

Honesty requires adding how far the objection reaches. Permission is already cooperative: "The Agent **MAY** request
permission", so an agent that means harm needs no answer from anyone, and this feature changes nothing for it. The
threat that changes is an honest agent with a misled model or a sloppy adapter, and it changes in the one place where
a person used to look.

## Decision

An opt-in switch, **Allow edits in this worktree**, with the narrowest rule that still removes the common prompt.

**The switch.**

- Off by default, per session, held only in memory in `SessionController`. It is never stored: not in settings, not as a
  default for the next session, not restored by Continue or relaunch. Turning it on is a decision each time, so it is
  not a setting (principle 6).
- Only for a session with a worktree of its own: `SessionWorkspace.Worktree` must accept it, the same check that guards
  removal. Other sessions cannot turn it on, and the command is disabled with an explanation.
- Reached from Session → Allow Edits in This Worktree (⌥⌘E) and from the inspector's Workspace block. Turning it on
  shows one short confirmation that says what it does and that commands still ask; there is no "don't show again".
  Turning it off asks nothing.
- **Visible while on:** a tinted pill in the composer's bottom row, `Edits allowed`, which turns it off when clicked.
  With the switch off, there is no pill. Every window showing the session shows the pill.
- Turning it off is immediate: the next request asks. A request already on the card is never answered retroactively by
  turning it on.
- A session that ends, fails or merges takes the switch with it; a Continue starts with it off.

**The rule.** The client answers by itself only when *all* of these hold, checked in this order on the tool call as
known when the agent asked (`TranscriptState.Permission.toolCall`, merging the earlier `tool_call`):

1. The switch is on and the session is running.
2. `kind` is exactly `edit`.
3. `locations` is nonempty. Every location, and the path of every `diff` in the content, is absolute.
4. Every path resolves, after `..` and symlinks, inside the worktree. This is `ScopedFileAccess.resolve` with the
   worktree as the only root, including its handling of files that do not exist yet, off the main actor. Additional
   roots do not count, and neither does the project checkout.
5. No component of the path relative to the worktree begins with `.`. This covers `.git`, compared without regard to
   case because APFS usually ignores it, and `.github`, `.husky`, `.env` and agent and editor settings, without a list
   of agent names (principle 8).
6. No path lies under the worktree's `core.hooksPath`, if it is set inside the worktree.
7. The offered options contain exactly one with kind `allow_once`.
8. The switch is still on after the asynchronous resolve in step 4.

Then it answers that `allow_once` option. It never picks `allow_always`, whose scope and lifetime belong to the agent
and would survive turning the switch off.

**Always asks, with the normal card:** `execute`, `delete`, `move`, `fetch`, `read`, `search`, `other`, `switch_mode`,
unknown kinds and a missing kind; calls without locations; relative paths; anything outside the worktree; any failure
to resolve. Every doubt resolves to asking.

**Recorded and visible.**

- The request and the answer go through the existing durable path: the request is committed, the response is committed,
  and only then is it returned to the agent. The answer carries an additive mark that the rule made it.
- The transcript shows the record as `Auto-allowed · Edit · Write note.txt`, in the place of `Allowed once`. So that these
  do not split every folded group (`TranscriptRow.fold` ends a group at any non-tool row), auto-allowed records fold
  into the group, whose summary counts them (`Edited 3 files · 3 auto-allowed`). ADR-0039's rule that pending requests
  are never folded is unaffected: these never pend.
- Turning the switch on or off is a session notice in the transcript, so the log shows when it applied. Replay shows the
  notices and never restores the state.
- These requests raise no card, notification, Dock badge or sidebar reason, because they never enter
  `pendingPermissions`.

**A tripwire.** If a later `tool_call_update` for an auto-allowed call reports another kind, or a location that fails the
rule, the write may already have happened, and nothing can undo the answer. The switch turns off at once and a notice
says why, and the next request asks. This does not catch an agent that never reports the difference.

**Review stays the boundary.** Nothing about merge changes. Review shows the whole diff, whatever answered for it.

## Alternatives

**Rely on each agent's own `allow_always`.** The user picks "always" on the first edit, and the agent stops asking.

- For: no code and no client policy. The agent knows what the tool truly does, which the client can only read from a
  report, and ACP gives it the job: "The Agent owns remembered decisions."
- Against: its scope is whatever the agent decides ("a tool, a command, or a directory"), so it may cover paths outside
  the worktree and may outlive the session. It differs per agent, and the option's name is the only description.
  The client cannot turn it off, and later edits leave no permission record at all.
- Some agents also offer a mode for this (Claude Code calls it `acceptEdits`; not checked against each adapter), reachable
  today through the composer's pills, with the same properties.

**Do nothing.** This is the reviewer's recommendation, and the honest baseline.

- For: no moved boundary and no code. A person sees every request. The people who want fewer prompts have the agent's
  own means, and the point of the app stays simple to explain.
- Against: edits inside an isolated worktree, the most recoverable action, interrupt as much as the least recoverable,
  which trains people to answer without reading. That cost is real but, so far, unmeasured.

**Wider or simpler rules, rejected:**

- **Include `delete` and `move`.** Reversible through Git as well, but untracked files are not, and `move` has a source
  and a target that locations do not distinguish.
- **Only `.git` excluded, as first proposed.** One rule fewer and fewer prompts, but it leaves `.husky/`, `.github/` and
  agent settings open, which are the paths with the worst consequences. This is stricter than the brief; the cost is a
  prompt for `.gitignore`, which is rare and worth reading.
- **A list of risky names** (`Makefile`, `package.json`, …). It looks safer, but it can never be complete, and a partial
  list claims a protection it does not give. The ADR states the risk instead.
- **Persist it per project.** Convenient, but it becomes a standing policy that nobody remembers setting.

## Consequences and risks

- The app now has a small permission policy of its own, which ARCHITECTURE.md says it does not. The sentence changes
  when this is accepted.
- `requestPermission` gains a path between its commit and `pendingPermissions`, and it must keep the guarantee that a
  response is committed before it is returned.
- `TranscriptRow.fold` and `ToolGroupSummary` learn about auto-allowed records, which is the streaming path; Rendering Lab
  S7 and S9 are rerun with the owner's approval.
- Testing needs a mock agent that reports chosen kinds and locations: outside the worktree, through a symlink, with
  `..`, with a differing diff path, and changing them in a later update.
- Residual risk that remains after every safeguard: the whole of "edit, then execute" through files with ordinary names,
  misreported kinds and locations, and the gap between the check and the write.

**What would make the owner regret this:**

1. An approved, ordinary-looking command runs code that an auto-allowed edit planted, with the user's credentials. This
   is the likeliest serious failure. No rule in this ADR prevents it.
2. A popular adapter labels something `edit` that is not, or lists only part of what it writes. One confirmed case means
   the rule cannot stand for that agent, and agent-specific exceptions go against principle 8.
3. People merge without reading, because the session felt safe. Then the switch removed the first check and weakened the
   second; the app's promise about what lands in a branch is broken while every rule worked as designed.
4. It stays on and is forgotten over a long session, despite the pill.
5. It grows. "Also allow reads", "also allow tests", "remember this per project" each sound small; together they make a
   general policy engine. Each widening needs a new ADR that answers the objection above.
6. It turns out to be unused, because agents' own modes are good enough. Then it is complexity on a sensitive path for
   nothing. Removing it is cheap, since nothing is persisted but the history records.

**Order of work, recommended.** Count the share of edit requests in real sessions first. If edits are not the bulk of the
prompts, this ADR should be reconsidered before any code. It is implemented last among the M15 follow-ups, after the
docked permission card has shipped, which may remove much of the pain on its own.

## Not decided

Any rule for `execute`, even for a named command; a global or per-project default; rules the user can write; marking
auto-allowed files in review; and running agents in a real OS sandbox, which is the true answer to "a worktree is not a
sandbox" and a separate decision.
