# 0014. Window-bound live sessions

- Status: Accepted
- Date: 2026-10-08
- Decider: Project owner
- Scope: First live app integration (#99); complements ADR-0004, ADR-0005, and ADR-0006.

## Context

The runtime, durable session controller, replay, and native transcript exist independently. Connecting
one live session requires an explicit owner for process cleanup, startup cancellation, and window
closure. The controller intentionally does not own its agent process.

## Decision

A window retains one `LiveSession` owner in Core. That owner coordinates `AgentProcess`,
`SessionController`, workspace preparation, and persistence metadata. Ending a session, closing its
window, or quitting the app closes ACP, waits for pending event writes, and terminates the process
group. Startup may be in flight; shutdown waits for it and cleans up any process it produced.

The app shares one `SessionLibrary` and database. A small UI-side registry tracks window owners only
so AppKit can delay app termination until their asynchronous cleanup finishes. It is not a background
session manager. Viewing saved history within a window does not stop that window's live session.

Git sessions receive an automatic worktree and branch from HEAD as required by ADR-0006. Include
minimal creation in this integration; retain worktrees on close and failed startup. Full review,
acceptance, discard, and worktree metadata remain separate implementation steps. Non-Git directories
are used directly and the launch form explains that distinction.

## Alternatives

- **App-wide session manager:** permits sessions to outlive windows and supports several live sessions
  per window, but adds ownership and navigation behavior not needed for the first integration. Revisit
  with the parallel-session milestone.
- **Launch in the selected Git checkout:** less implementation work, but violates ADR-0006's isolation
  guarantee and risks changing the user's working branch. Rejected.
- **Complete worktree review/merge/discard first:** provides a fuller workflow but delays testing live
  sessions. Retaining the worktree gives an explicit recovery path until those controls exist.

## Consequences

A live session ends with its window. Saved history remains readable after restart, but does not
reconnect to an agent. Worktree files survive and are accessible through Show in Finder. Uncommitted
and untracked files from the original checkout are not copied. Process cleanup uses the existing
runtime's group termination guarantees; it does not contain deliberately detached descendants.
