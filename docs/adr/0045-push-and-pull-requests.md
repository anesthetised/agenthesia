# 0045. Push after merge, and pull requests from a session

- Status: Accepted (2026-11-07, #220)
- Date: 2026-11-07
- Decider: Project owner
- Supersedes: "one session yields one merge" in [0032](0032-worktree-merge-and-discard.md) when a pull request is
  opened instead; "Integrate through pull requests … can be added later" is that later
- Related: [0006](0006-worktree-isolation.md), [0039](0039-t3-style-window-layout.md) (readable branch names),
  [0041](0041-review-pane.md), [0005](0005-event-log.md)

## Context

A merge in Agenthesia ends on the user's local base branch (ADR-0032). What happens next is a terminal: `git push`,
or a branch pushed by hand and a pull request written on the hosting site. T3 Code never merges locally and integrates
through pull requests; ADR-0032 chose the local squash merge and noted that pull requests could come later beside it.
Both are now wanted:

- **Push after merge**, because the local merge is usually followed by exactly that, and forgetting it leaves the work
  on one machine.
- **A pull request from the session branch**, because many projects, this one included, do not merge locally at all:
  CI and review happen on the pull request, and the session should be able to continue while it is reviewed.

Readable branch names (ADR-0039's amendment, #208) matter here: a pushed branch is what reviewers see.

## Decision

### Push after merge

The merge sheet gains a checkbox **Push `<base>` to `<remote>`** when the base branch has an upstream
(`git rev-parse --abbrev-ref <base>@{upstream}`); without one the checkbox is absent and nothing is pushed. It is off
the first time and then remembers the last choice (`UserDefaults`), a default, not a setting (principle 6).

- The push runs in the project checkout after the final commit succeeded: `git push <remote> <base>`, through the
  `git` CLI so the user's credentials and hooks apply (ADR-0006). The app never pulls, rebases or force-pushes.
- A failed push does not undo the merge, which is already on the base branch. The sheet shows the push failure with
  Git's output and a line that says the merge succeeded; the session ends and its worktree is removed as ADR-0032
  describes. The user pushes by hand after resolving, for example a non-fast-forward.
- `worktreeRemoved` records `merged(commit)` as today; whether the push succeeded is not stored, because the remote is
  the authority on that.

### Open Pull Request…

A second way to hand the work over, for a session with a worktree whose base branch has an upstream remote, when the
GitHub CLI `gh` is on the resolved `PATH` and signed in (`gh auth status`). Without `gh` the action is hidden, not
disabled: the app does not install or explain `gh`, and projects without GitHub lose nothing they had.

- **Where.** In the inspector's Changes block beside Merge, in the review pane's footer and in the Session menu.
- **A sheet**: title (the session title by default), body (empty by default, multi-line), the base branch as a label.
  Create runs, in order: the intermediate commit of uncommitted changes on the session branch (ADR-0032 step 3, with
  `--no-verify`), `git push -u <remote> <branch>`, then `gh pr create --base <base> --head <branch> --title … --body …`
  with the result's URL. The sheet shows each step and the first failure with its output; a failure after the push
  leaves the branch pushed, which the sheet says.
- **The session stays live.** The worktree, the branch and the agent remain: the user can ask the agent to address
  review comments and push again. The event log gains `pullRequestOpened(url, number)`, appended once `gh` returned,
  so history and every window show it.
- **The inspector** shows `Pull request #12` as a link in the Changes block, with **Push** beside it while the local
  branch is ahead of its upstream (`git rev-list --count @{upstream}..HEAD`), and Merge is hidden: the pull request is
  the integration path now. Push repeats the intermediate commit and `git push`; it never force-pushes, so a branch
  rewritten on the remote fails with Git's message.
- **Discard** keeps its meaning: it removes the local worktree and branch after confirmation, which now also says that
  the remote branch and the pull request are not touched. The app does not close, merge or poll pull requests; the
  hosting site does that, and the session is discarded when the user is done with it.
- **The branch name** is the stored name of ADR-0039's amendment; sessions without one (started before #208) push
  `agenthesia/<uuid>`, which is valid, only ugly.

### Implementation notes (2026-11-09, #232)

- The push sends the base branch to the branch its upstream names (`git push <remote> refs/heads/<base>:<upstream
  branch>`), which is `git push <remote> <base>` whenever the names match.
- It cannot ask for credentials (`GIT_TERMINAL_PROMPT=0`) and is stopped after 2 minutes (the owner's choice), so the
  sheet never hangs.
- The failure is shown in an alert after the sheet closes, like the merge's other after-commit failures, rather than
  in the sheet itself: the merge is done, so the sheet has nothing left to act on.

## Alternatives

- **Push only, no pull request.** No `gh`, works with every host; but the common GitHub flow then still ends in a
  browser and a form, and the session cannot continue into review.
- **Pull request ends the session**, like a merge: worktree removed, branch left on the remote. One handoff per
  session, simpler to explain, but review comments then mean a new session on a branch the app no longer owns.
- **`git push` plus a compare URL opened in the browser**, without `gh`. Host-agnostic and dependency-free, but the
  pull request is then created outside the app and never recorded; it can still be added for hosts without `gh`.
- **A hosting API integration** (tokens, GitHub app). Full control and status in the inspector, but a dependency, a
  credential store and a second identity to manage; `gh` already has all three.

## Consequences and risks

- `SessionWorkspace` gains upstream detection, push and the `gh` invocation; all through the existing `git` runner
  and the resolved login-shell environment (ADR-0004), so `gh` is found where the user's shell finds it.
- The merge path, a safety path, changes: the push runs after the commit and must not be able to undo or repeat it.
  Tests with real repositories and a local bare remote cover success, a rejected push and a missing upstream.
- `pullRequestOpened` is a new event kind; replay must tolerate it in older builds by ignoring unknown kinds, which the
  decoder does today.
- The intermediate commit on the session branch becomes visible on the remote. Its message says what it is
  (`Agenthesia: uncommitted changes before push`) so reviewers are not puzzled.
- A session with an open pull request can still be merged locally by hand in a terminal; the app shows what it knows
  and does not guard against that.
