# Merge

The merge sheet squash-merges a session's worktree into its base branch in the project checkout
([ADR-0032](../adr/0032-worktree-merge-and-discard.md)). It opens from Merge into `<base>`… in the inspector's
Changes, the review pane's Merge… and the Session menu.

## The sheet

- The title is `Merge into <base>`. While Git is asked it reads `Checking the merge…`; a blocker replaces the form with
  its explanation (the checkout on another branch or with changes, the base behind the session's start, nothing to
  merge, …) and only Cancel stays.
- Ready, it says what happens, `2 changed files and 1 commit become one commit on main. Uncommitted changes are
  included.`, then the commit message (the agent's title or the first prompt line; Return adds a line) and Cancel /
  Merge. While merging the buttons are disabled and the sheet reads `Merging…`.
- A conflict or a refused commit keeps the sheet open with the failure; the checkout is restored.

## Push after merge

- When the base branch tracks a branch on a remote ([ADR-0045](../adr/0045-push-and-pull-requests.md)), a checkbox
  `Push <base> to <remote>` follows the summary. Without a remote upstream (none, or a local branch) it is absent and
  nothing is pushed.
- It is off the first time and then remembers the last choice, for every project; it is a default, not a setting.
  While merging with it on, the sheet reads `Merging and pushing…`.
- The push runs after the merge commit is recorded and sends the base branch to the branch its upstream names. It never
  pulls, rebases or forces, cannot ask for credentials and is stopped after 2 minutes.
- A failed push undoes nothing: the session ends and its worktree goes as after any merge, the sheet closes, and an
  alert `Merged, but Not Pushed` says the merge succeeded and shows Git's output (for a remote that moved:
  `rejected … (fetch first)`). The user pushes by hand.

## Changes

- 2026-11-09, #232: the `Push <base> to <remote>` checkbox; the rest summarised from ADR-0032 and the code at 3e6d0c3.
