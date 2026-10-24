# 0032. Worktree merge and discard

- Status: Accepted
- Date: 2026-10-24
- Decider: Project owner
- Scope: the rest of the worktree lifecycle of [ADR-0006](0006-worktree-isolation.md) (#41–#44); settles the
  base pin deferred by [ADR-0024](0024-changed-files-session-base.md)

## Context

ADR-0006 fixes the shape of the workflow: a worktree per session, review of `base...HEAD` plus uncommitted
changes, a squash merge into the base branch, and discard after confirmation. Creating the worktree is
implemented: `SessionWorkspace.prepare` adds `~/.agenthesia/worktrees/<repo>/<session id>` on branch
`agenthesia/<session id>` from the checkout's `HEAD` and stores that commit as the session's `baseRevision`.
Nothing records which branch the work goes back to, nothing removes a worktree, and history cannot tell a
session whose worktree is gone, so Continue would start an agent in a missing directory.

T3 Code was studied for comparison. It lets the user pick a base ref at launch and stores only the branch and
the worktree path; it never merges locally and integrates through pull requests on the hosting service; it
removes worktree directories by a cleanup policy with several settings, keeps the branch, and recreates the
checkout from the branch when a thread resumes.

## Decision

- **Base branch.** When the worktree is created, the session records the branch checked out in the selected
  checkout (`git symbolic-ref --quiet --short HEAD`) as `baseBranch`. A detached `HEAD` records nothing, and
  such a session cannot be merged, only discarded. The launch form does not ask. The worktree still starts
  from `HEAD`, so `baseRevision` is the base branch's tip at start.
- **No pinned base.** `baseRevision` is not protected by a ref. It is normally reachable from the base
  branch, and an unreachable base already fails with an explicit error (ADR-0024).
- **Merge is a local squash** in the checkout the session was started from (the project directory):
  1. The session must not be running a turn, and no turn may start while the merge runs. The agent stays
     attached until the merge succeeds, so a blocked or conflicting merge can be fixed by asking the agent.
  2. The project checkout must be on `baseBranch` and have no tracked changes; otherwise the merge is blocked
     with an explanation. Untracked files that the merge would overwrite are reported by Git.
  3. Uncommitted changes in the worktree, untracked files included, are committed on the session branch first
     (`git add -A`, then `git commit --no-verify`): that commit is intermediate and is squashed away.
  4. In the project checkout: `git merge --squash agenthesia/<id>`, then `git commit -F <message>`. The final
     commit runs the user's hooks and signing, as ADR-0006 requires. The message is editable and defaults to
     the session title.
  5. A conflict or a failed final commit runs `git reset --merge`, which restores the checkout to its
     previous commit, and explains what failed. The base branch does not move.
- **After a merge** the session ends, its worktree and branch are removed, and the session is read-only: one
  session yields one merge. Continue is not offered.
- **Discard** asks for confirmation (naming uncommitted files and commits that would be lost), ends a live
  session, runs `git worktree remove --force` and `git branch -D agenthesia/<id>`, and makes the session
  read-only. A worktree already deleted by hand is pruned (`git worktree prune`) and its branch deleted.
- **Only Agenthesia's worktrees are removed.** Removal requires a working directory inside the worktrees root
  and the branch `agenthesia/<session id>`; any other session (non-Git folders, sessions started before
  worktrees) never has files removed.
- **History records the outcome.** The event log gains `worktreeRemoved`, carrying `merged(commit)` or
  `discarded`. It is appended after Git succeeds; replay reads it to disable Continue and show the outcome.
  The removal itself is not undone if the append fails; the error is shown and the session stays read-only.
- **Review compares with the base branch** as the squash merge will: `baseBranch...HEAD` (three dots, from
  the merge base) plus staged, unstaged and untracked changes. Sessions without `baseBranch` fall back to the
  changed-file comparison of ADR-0024 against `baseRevision`.
- The worktree directory keeps the session id as its slug; generated branch names are not adopted.

## Alternatives

- **Pick the base in the launch form** (T3). Flexible, but a form field and validation for a choice that is
  almost always the current branch.
- **Pin the base with `refs/agenthesia/<id>/base`.** One `update-ref`, removed with the worktree. It keeps
  review working after the user rewrites or garbage-collects the base, a case not seen so far.
- **Merge without a checkout** (`git merge-tree --write-tree`, `commit-tree`, `update-ref`). Works with a
  dirty checkout or another branch checked out, but skips hooks and leaves a checked-out base looking
  modified.
- **Integrate through pull requests** (T3). Needs a hosting integration and contradicts ADR-0006; opening a
  pull request can be added later beside the local merge.
- **Keep the branch and recreate the worktree on Continue** (T3). Suits iterative work, but after a squash
  merge the session branch has diverged from the base, so a second merge would repeat or conflict with the
  first.
- **Cleanup by policy** (T3: on merge, on delete, unchanged, after N days, what counts as a change). Each is
  a setting; VISION prefers decisions over settings, and nothing is removed without the user's action here.

## Consequences

- One nullable `baseBranch` column; legacy sessions have none, so they can be discarded but not merged.
- Merge and discard are lifecycle operations on a live owner: they go through the session manager and must
  exclude turns, queue sends and Continue while they run.
- Sessions in the sidebar may be merged or discarded; history stays append-only and keeps them.
- A conflict is resolved in the session (the agent merges the base into its branch), never in the user's
  checkout.
- The worktree is not refreshed when the base branch moves; review and merge use the merge base.
