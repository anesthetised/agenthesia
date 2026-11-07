# 0048. Sessions without a project

- Status: Accepted (2026-11-08, owner's first-use feedback)
- Date: 2026-11-08
- Decider: Project owner
- Related: [0040](0040-composer-first-session-start.md), [0043](0043-sessions-in-the-project-folder.md),
  [0044](0044-delete-and-archive-sessions.md), [0006](0006-worktree-isolation.md)

## Context

Every session starts in a project: the draft's Project chip picks a folder, and a Git folder needs a commit or the start
fails with `invalid reference: HEAD`. Much of what people ask an agent has no project: a question, a script, a document,
a design to think through. T3 Code offers *or start without a project* under its draft heading; the draft then reads
*What should we work on?*, and the thread runs in a scratch folder under T3's data directory, outside any Git work tree.
Its sidebar shows such threads with a dashed badge and *No project*.

A folder that is not a Git repository already works as a session today (`SessionWorkspace.prepare`, ADR-0043): no
worktree, no base revision, no Merge or Discard, and Changes say that tracking requires Git. What is missing is a place
for such a folder and a way to start there without choosing one.

## Decision

**One folder per session.** A session without a project runs in its own new, empty folder,
`~/.agenthesia/scratch/<words>-<first 8 hex digits of the session id>`, named like a session branch (ADR-0039's
amendment) from the first line of the first message. The folder is created at Send, before the agent starts, and is the
session's working directory and its only filesystem root (`ScopedFileAccess`). It is not a Git repository, and the app
does not make it one. It sits next to `worktrees` for the same reason as worktrees do (ADR-0006): no space in the path,
nothing for indexers in a project to pick up.

**A project of its own.** All such sessions belong to one project record, *No project*, created on first use with
`~/.agenthesia/scratch` as its root. The recent-projects list does not offer it; a draft reaches it only through its
own choice, which is per draft and not remembered, like the checkout (ADR-0043). How the draft and the sidebar show it
is UI behavior ([docs/behavior/session-start.md](../behavior/session-start.md),
[docs/behavior/sidebar.md](../behavior/sidebar.md)).

**What such a session is.** A folder session of ADR-0043's kind without Git: no worktree, no base revision, so no
Review, Merge, Discard, Push or Open Pull Request, and Changes are not tracked. Continue runs in the same folder.

**Removal.** The folder stays with the session and is removed when the session is deleted (ADR-0044), after
confirmation that names the folder and its file count. Archiving keeps it. An empty folder of a start that failed
before its record existed is removed with the failed start, like an unstarted worktree (#176).

## Alternatives

- **One shared scratch folder, as T3 Code does.** Simplest, but two sessions see and overwrite each other's files, and
  deleting a session cannot tell which files were its own.
- **Let the user pick any folder outside Git.** Already possible through Choose Folder…; it does not answer "start
  without thinking about where".
- **`git init` the folder** so Changes and Review work. Agents and the user would see a repository nobody asked for,
  with commits the user never made; a scratch session is not reviewed work.

## Consequences and risks

- Persistence gains nothing: the project row exists once, and the working directory is already stored per session.
  `ProjectRecord` gains a flag, or a well-known root, for the dashed badge; the store's recent-projects query skips it.
- `SessionWorkspace.prepare` gains the scratch form: create the folder (fail on an existing one), then the non-Git path.
- Folders accumulate with sessions; they are small, listed under one directory, and leave with Delete.
- An agent that writes outside its folder is not stopped by the folder; the permission request and the agent's own
  sandbox are the guard, as for every session.
