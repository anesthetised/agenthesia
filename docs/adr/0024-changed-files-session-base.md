# 0024. Compare changed files with the session base

- Status: Accepted
- Date: 2026-10-16
- Decider: Project owner
- Supersedes in part: [0023](0023-session-files.md) (committed paths from `base...HEAD`)
- Scope: the session changed-file list (#114); worktree review stays with #42

## Context

ADR-0023 lists committed paths from `base...HEAD`. Three dots diff `merge-base(base, HEAD)` against
`HEAD`, which equals `base` only while the agent commits on top of it. When the agent rewrites history,
the list is wrong exactly when the user most needs it:

- After `git reset --hard` past the base, the merge base is `HEAD`: reverted files disappear.
- After amending or rebasing the base commit, the merge base is its parent: every file of the user's
  original commit appears, including files that still equal the base.
- After switching to another branch, files that exist only on the base side are hidden.

The list also deliberately keeps a path when any layer differs: a committed change whose disk contents
were restored, or a staged change whose working copy matches `HEAD`. Such a change remains in the
session's history or index even though the disk does not show it.

## Decision

- For sessions with a base revision, list committed paths from `git diff <base> HEAD` (two trees, no
  merge base) together with staged, unstaged and nonignored untracked paths, as before.
- The list shows a path when the base, `HEAD`, the index or the working tree differ for it. The
  criterion is a difference from the base, not authorship: after the agent checks out another commit,
  every path that differs from the base is listed. A difference is never hidden because of how the
  history got there.
- Legacy sessions, renames, deleted files, errors for a missing or invalid base, and non-Git folders
  keep the ADR-0023 behavior.
- The review view (ADR-0006, #42) is out of scope. There `base` is the base branch, not the session's
  base revision: a squash merge applies `<branch>...HEAD`, so review may keep three dots. #42 decides
  that together with how it reports a rewritten base revision.

## Alternatives

- **Disk contents against the base** (`git diff <base>` plus untracked paths), as proposed in #114.
  It answers "what differs on disk from the session's start", which matches a pane that shows disk
  contents, and needs two Git commands instead of four. It drops the deliberate retention above:
  committed or staged changes the working copy reverted would not be listed, although they remain in
  the session's history or index. Two existing behaviors and their tests would be reversed.
- **Keep three dots and warn when the merge base is not the base.** Cheap, but the list stays wrong;
  a banner only says so.
- **Pin the base with a ref** (`refs/agenthesia/…`) so a garbage-collected rewrite cannot remove it.
  The base is normally reachable from the user's branch, and an unreachable base already shows an
  explicit error. Pinning belongs to the worktree lifecycle in M8, which also removes the ref.

## Consequences

The fix is one revision range in `SessionWorkspace.changedPaths`; Git invocations per refresh and
FSEvents invalidation are unchanged. A tree-to-tree diff skips the merge-base computation. A path can
be listed while its disk contents equal the base; opening it shows those contents. A switch to a
distant commit can list many paths the agent never edited. Tests cover reset past the base, an amended
base and a branch switch, which now also lists files that exist only on the base side.
