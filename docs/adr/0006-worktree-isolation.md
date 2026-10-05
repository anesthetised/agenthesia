# 0006. Worktree isolation

- Status: Accepted
- Date: 2026-10-05

## Context

Running several agents on one repository at the same time requires isolation, and principle 5
("visible and reversible") requires that nothing reaches the user's branch without review.

## Decision

- In a git repository, every new session gets its own worktree by default.
- Location: `~/.agenthesia/worktrees/<repo>/<slug>`, on branch `agenthesia/<slug>`. Not under
  `Application Support`, because the space in that path breaks poorly quoted scripts and build tools,
  which agents run all the time. Not inside the repository, to keep indexers, test runners and linters
  from picking up copies of the code.
- Review shows `base...HEAD` plus uncommitted changes.
- Accepting work is a **squash merge** into the base branch with an editable commit message. If the
  main checkout is dirty, the merge is blocked with an explanation.
- Discarding removes the worktree and its branch after confirmation.
- Git is driven through the `git` CLI so the user's configuration (hooks, signing, credentials) applies.

## Consequences

- Parallel sessions never step on each other or on the user's working copy.
- Agents' intermediate commits never reach the base branch history.
- Untracked files the project needs (for example `.env`) are not in a fresh worktree; a setup step for
  that is a later decision.
