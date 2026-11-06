# 0043. Sessions in the project folder

- Status: Accepted (2026-11-07, #220)
- Date: 2026-11-07
- Decider: Project owner
- Supersedes: "every new session gets its own worktree" in [0006](0006-worktree-isolation.md) as the only choice (it
  stays the default); the rejected alternative "A Current checkout option" in [0040](0040-composer-first-session-start.md)
- Related: [0023](0023-session-files.md), [0024](0024-changed-files-session-base.md),
  [0032](0032-worktree-merge-and-discard.md), [0041](0041-review-pane.md)

## Context

ADR-0006 gives every session in a Git repository its own worktree and branch, and ADR-0040 shows that as a label in
the draft (`New worktree from main`) with no choice. That is right for delegated work: the vision's agents run in
parallel and nothing reaches the user's branch without review.

It is wrong for the other half of what people ask an agent: *what does this module do*, *where is the retry logic*,
*why does this test fail*. Each such question today costs a worktree, a branch in `git branch`, a sidebar row that can
be merged or discarded, and the worktree's own files, which do not include the user's uncommitted work, so the agent
answers about a tree the user is not looking at. T3 Code offers *Current checkout* beside *New worktree* for this
reason, and ADR-0040 recorded that a copy would need a new ADR because it contradicts ADR-0006. This is that ADR.

Sessions without a worktree already exist: a folder that is not a Git repository starts the agent in the folder itself
(`SessionWorkspace.prepare`, `DraftCheckout.folder`), with no base revision, no Merge and no Discard, and the Changes
section says that tracking requires Git (ADR-0023). The removal rules of ADR-0032 never touch a directory outside the
worktrees root. So the mechanism exists; what is missing is the choice for a Git project and a base for its changes.

## Decision

**A choice in the draft.** For a Git project, the Checkout chip of ADR-0040 is a menu with two items:

- `New worktree from <branch>`, the default, unchanged.
- `Project folder`: the session runs in the selected directory itself, on whatever is checked out there.

Its help text says what each does; for the folder: "The agent works in your checkout. Edits land on `<branch>` directly
and are not isolated from your own changes." For a folder that is not a Git repository the chip stays a label, as
today.

**The choice is per draft.** It is not remembered, unlike the project and the agent: every new draft starts with the
worktree. Working in the checkout is the less safe option, and a default that drifted there silently would surprise the
next delegated task; this follows the owner's decision on modes in ADR-0040's amendment, where a mode is applied only
when chosen in this draft. New Session in Project (ADR-0040) opens the draft with the worktree as well.

**What such a session is.** `SessionWorkspace.prepare` gains an in-place form. The project directory is the repository
root, the working directory the selected directory, `baseRevision` the checkout's `HEAD` when the session starts, and
`baseBranch` the branch checked out, or nil when detached. No worktree, no branch, nothing under the worktrees root.

- **Changes** compare with `baseRevision` as ADR-0024 says, so the section shows what changed since the session started,
  including commits the user made in the checkout meanwhile; the header says `Changes since the session started`.
  Review (ADR-0041) compares the same and says so in its header.
- **Merge and Discard are not offered.** There is nothing to merge and nothing of Agenthesia's to remove. The Session menu
  and the inspector disable them with the help text `This session works in the project folder`. ADR-0032's removal
  check already refuses such a session: its working directory is outside the worktrees root. The in-place form is
  recognised by that same test, `Worktree.contains(workingDirectory)`, so no column is added; a session is in place when
  it has a `baseRevision` and lives outside the worktrees root.
- **The inspector's Workspace block** shows `In <branch>, project folder` where a worktree session shows its branch
  and base, and the path. Nothing is repeated elsewhere: the sidebar row and the title do not mark the session, because
  the checkout is a property of where it runs, not of what it is doing.
- **Everything else is the same session.** The event log, the file pane, Quick Open, the filesystem roots of
  `ScopedFileAccess` (the working directory and the project root), terminals, sign-in, Continue and history do not
  change. A continued session (ADR-0017) runs where it ran.

**Several sessions in one folder** are allowed, as several non-Git sessions in one folder are today. The app does not
coordinate them; the user chose to share the checkout.

## Alternatives

- **Keep ADR-0006 as is.** Nothing to decide, and every question costs a worktree and a branch. The owner rejected it.
- **A read-only kind of session**, with `fs/write_text_file` refused and a warning on the first edit permission. It
  protects only the client's own filesystem capability; an agent's own tools write directly, as ADR-0042 records, so the
  protection would be partial and the name a promise the app cannot keep. Users who want a read-only session choose the
  agent's plan or ask mode, which the draft will offer as a hint (ADR-0040's amendment).
- **A separate "Ask" session type** with its own button, hidden Changes and a mode hint. It names the intention, but it
  is a second kind of session to explain and test, and the folder choice is enough to get the behavior.
- **Remember the last checkout choice per project.** Fewer clicks for someone who only asks questions of a project, but
  a silent drift toward editing the checkout. Rejected for the reason given above; it can be revisited with a count of
  how often the folder is chosen.

## Consequences and risks

- The agent edits the user's checkout. Nothing stands between an allowed edit and the branch except the permission
  request, which is the situation of every terminal agent today; the help text and the Workspace block say it, and the
  default stays the worktree.
- `canMerge`, `canDiscard` and `canReview` gain the in-place case; the Changes header changes its wording per base.
  The existing non-Git path is the model for the tests.
- `SessionWorkspace.prepare` grows a second branch for a repository; the dirty-checkout and bare-repository checks
  stay, and the symlink and subdirectory handling of the worktree path must not be duplicated by hand.
- ADR-0040's draft tests gain the menu and the per-draft reset. ARCHITECTURE.md's "Non-Git folders" paragraphs become
  "folder sessions" and name both origins.

## Not decided

Remembering the choice, a warning banner on the first write, and whether a folder session should be startable from a
transcript path or a notification. None has a demonstrated need.
