# 0047. Worktrees start from the fetched upstream

- Status: Accepted (2026-11-08, owner's first-use feedback)
- Date: 2026-11-08
- Decider: Project owner
- Supersedes: "The worktree still starts from `HEAD`" in [0032](0032-worktree-merge-and-discard.md)
- Related: [0006](0006-worktree-isolation.md), [0043](0043-sessions-in-the-project-folder.md),
  [0045](0045-push-and-pull-requests.md), [0024](0024-changed-files-session-base.md)

## Context

A session worktree starts from the selected checkout's `HEAD` (`SessionWorkspace.prepare`, `git worktree add -b
<branch> <path> HEAD`). When the user has not pulled `main`, the agent works on old code, and a pull request from the
session (ADR-0045) starts behind its base. T3 Code (Settings → Worktrees, *Start from remote*, on by default) starts a
new worktree at the latest commit of the base branch's tracked remote branch, falling back to the local branch.

The owner compared both on 2026-11-07 and chose T3 Code's default. T3 Code's other worktree settings (folder, branch
prefix, cleanup after merge, deletion or inactivity) were considered and not adopted: ADR-0032's rule stands that a
worktree is removed only by the user's Merge, Discard or Delete, and the folder and the `agenthesia/` prefix stay fixed
(principle 6).

## Decision

**Start from the remote base.** When `prepare` creates a worktree and the checked-out branch has an upstream
(`git rev-parse --abbrev-ref --symbolic-full-name <branch>@{upstream}`, for example `origin/main`):

1. Fetch that one branch, `git fetch --quiet <remote> <branch>`, in the login-shell environment so credentials and SSH
   agents apply (ADR-0006), with a 20-second limit.
2. Create the worktree from the fetched upstream commit instead of `HEAD`. `baseRevision` is that commit; `baseBranch`
   stays the local branch (ADR-0032).
3. Without an upstream, or when the fetch fails or times out, start from `HEAD` as today. The session starts either
   way, and records where it started so the UI can say so (see `docs/behavior/`).

It is not a setting: fresh code is the right default for delegated work, and the fallback covers offline use. Sessions
in the project folder (ADR-0043) are not affected; they run on whatever the checkout holds.

**Merging a session that started ahead of the local branch.** The local squash merge of ADR-0032 merges from the merge
base of `baseBranch` and the session branch. If the local branch was not pulled, that base is older than the session's
start, and the squash would bring the remote's commits into the local branch a second time. So the merge is blocked
while `baseBranch` does not contain `baseRevision`, with an explanation that names both branches and asks the user to
pull first. The app still never pulls (ADR-0045). Review and Changes compare with `baseRevision` in that case, so they
show the session's own work.

## Alternatives

- **A Start-from-remote setting**, as T3 Code has. A question with one right answer for delegated work.
- **Fetch in the background while the draft is open**, so Send never waits. Faster, but a fetch for every draft that is
  never sent, and a stale answer when the draft sits for a while.
- **Pull the local branch for the user before merging.** Removes the block, but the app would move the user's branch
  without being asked, which ADR-0045 rules out.
- **Remove merged worktrees automatically**, as T3 Code can (off by default there). Rejected by the owner: removal stays
  the user's action.

## Consequences and risks

- `prepare` gains a network step before the agent starts; the 20-second limit and the fallback keep an offline start
  working.
- The session needs to know whether it started from the upstream or fell back; that is one more nullable field next to
  `baseRevision` (or derived by comparing `baseRevision` with the local branch at start), decided with the code.
- ADR-0032's merge check gains the `baseRevision` test. Real-repository tests with a local bare remote cover a local
  branch behind its upstream, a fetch failure and no upstream; never this repository.
