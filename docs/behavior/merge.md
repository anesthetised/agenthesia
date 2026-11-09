# Merge

The merge sheet squash-merges a session's worktree into its base branch in the project checkout
([ADR-0032](../adr/0032-worktree-merge-and-discard.md)). It opens from Merge into `<base>`… in the inspector's
Changes, the review pane's Merge… and the Session menu.

A session in the project folder ([ADR-0043](../adr/0043-sessions-in-the-project-folder.md)) has nothing to merge:
Merge in the inspector, the review pane's footer and the Session menu is disabled with the help text `This session works
in the project folder`, and the review's header reads `Changes since the session started`.

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

## Pull requests

*Open Pull Request…* hands a session over through a pull request instead of a local merge
([ADR-0045](../adr/0045-push-and-pull-requests.md)). It sits beside Merge in the inspector's Changes, in the review
pane's footer and in the Session menu.

- It is shown only for a session with an Agenthesia worktree and no outcome yet, whose base branch tracks a branch on a
  remote, while `gh` is on the login shell's `PATH` and `gh auth status` succeeds. Otherwise it is absent, not disabled;
  a session in the project folder or without a project never has it ([ADR-0048](../adr/0048-sessions-without-a-project.md)). A signed-in `gh` is
  remembered until the app quits; a missing or signed-out one is asked again when another session is shown. It is
  disabled like Merge: while the session is busy, and with no changes.
- The sheet is titled `Open Pull Request` and reads `<branch> into <base> on <remote>`, the base being the name of the
  base branch's upstream on the remote. Then `Title` (the session title by default; Create is disabled while it is
  empty), `Description` (empty, multi-line; Return adds a line) and Cancel / Create.
- Create shows three steps, each with a checkmark when done, a spinner while it runs, a red cross when it failed:
  `Commit uncommitted changes` (on the session branch, `Agenthesia: uncommitted changes before push`, without hooks;
  skipped when there is nothing to commit), `Push <branch> to <remote>` (`git push -u`, never forced, no prompts,
  stopped after 2 minutes) and `Create the pull request` (`gh pr create --base --head --title --body`). The first
  failure stays in the sheet with Git's or `gh`'s output; one after the push starts `The branch is pushed, but the
  pull request was not created.` A busy session (working, starting, merging, discarding or pushing) is refused before
  any step.
- On success the sheet closes and the session stays live. Its transcript gains the notice `Opened pull request #12:
  <url>`, and the inspector's Changes show `Pull request #12` as a link instead of Merge: Merge is hidden in the
  inspector, the review pane and the Session menu for that session, and so is Open Pull Request….
- **Push** follows the link while the worktree has uncommitted changes or commits its pushed branch lacks, rechecked
  when the files change, a turn ends or another session is shown. It repeats the intermediate commit and pushes to the
  branch's upstream, never forcing; a failure shows `Cannot Push` with Git's output. A spinner replaces it meanwhile.
- If history cannot record the pull request after `gh` opened it, the sheet closes and an alert `The Pull Request Was
  Not Recorded` gives its number and address.
- Discard keeps its meaning; its confirmation adds `The remote branch <remote>/<branch> and any pull request from it are
  not touched.` when the session branch has a remote upstream ([sidebar.md](sidebar.md#row-actions)).

## Changes

- 2026-11-09, #229: Merge is disabled for a session in the project folder, and Open Pull Request… absent.
- 2026-11-09, #233: Open Pull Request…, the pull request link and Push.
- 2026-11-09, #232: the `Push <base> to <remote>` checkbox; the rest summarised from ADR-0032 and the code at 3e6d0c3.
