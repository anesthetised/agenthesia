# 0023. Session files and their initial Git revision

- Status: Accepted
- Date: 2026-10-16
- Decider: Project owner
- Scope: M4 Files (#26, #27, #28); complements ADR-0006 and ADR-0008.

## Context

Quick Open, the file viewer and the changed-file list need the same session directory and selection
contract. They must also work for saved sessions without requiring a live ACP connection. A Git status
list alone loses changes once an agent commits them. Existing session records have no original revision.

## Decision

- Show one read-only file in a resizable pane beside the transcript, with an accessible Close action.
  Quick Open and changed-file selections carry a relative path and the displayed session identity;
  Core resolves the URL against the captured root. Transcript line navigation remains #29. The file
  pane does not own agent or window lifetimes.
- Scope indexing, viewing and the changed-file list to the displayed session's working directory,
  including when that directory is a subfolder of a linked worktree. These views read current disk
  contents; saved history is not a historical filesystem snapshot. Full worktree review remains #42.
- Save the newly created worktree's actual initial HEAD as optional `SessionRecord.baseRevision`,
  before launching the agent. Preserve it across protocol initialization and Continue. Add a nullable
  database column; existing sessions keep nil and their base is never guessed from current branches.
- For sessions with a base revision, list committed paths from `base...HEAD` together with staged,
  unstaged and nonignored untracked paths. For legacy sessions, explicitly label the list as working
  changes only. Renames may appear as the old and new paths; a deleted file shows an unavailable-file
  explanation when opened. A missing or invalid stored base is an error, not an empty list.
- Non-Git folders support indexing and viewing. The changed-file list explains that tracking requires
  Git; do not invent a baseline from the time the user opens a view.
- Workspace owns file indexing, Git queries, bounded regular-file reads and FSEvents invalidation.
  Core exposes the session file APIs; window-owned presentation state coordinates cancellation,
  selection and refresh. AgenthesiaUI keeps its existing module dependencies. File browsing does not
  append transcript events or depend on ACP filesystem admission.
- FSEvents invalidates authoritative scans rather than supplying the change list itself. Watch the
  selected directory and the relevant Git metadata, including linked-worktree metadata outside it.
  Successful ACP filesystem writes also invalidate. Stop watchers on selection replacement or window
  close; agent termination alone does not end file browsing.
- Quick Open indexes tracked and nonignored untracked paths in Git, with a directory walk elsewhere.
  It does not recursively index submodules or follow symlink directories. Search uses deterministic
  fuzzy matching with bounded results and no new dependency.
- Reuse the existing source and Markdown renderers. Markdown offers Preview and Source. Limit viewer
  reads to 2 MiB of regular UTF-8 text, reject binary/NUL content, and show errors explicitly. Keep
  existing ACP read behavior unchanged. No file tree, editing or browser-based renderer is added.

## Alternatives

- A modal viewer sheet is simpler on narrow windows but blocks interaction with the transcript.
- A separate viewer window provides space but adds focus and lifetime management. The owner chose an
  adjacent pane; resizing and keyboard access must remain usable at the existing minimum window size.
- Working changes only avoids persistence changes but hides committed agent work. The owner chose a
  saved initial revision. Legacy sessions are explicitly limited to working changes.
- Watching a non-Git folder from selection time cannot recover earlier session edits and would make
  the meaning of "changed" depend on navigation. Show an explanation instead.

## Consequences

The initial revision is available to the later worktree review milestone. Session file browsing
remains independent of process cleanup and event replay. A session selected below the repository root
shows changes within that folder, not a full-session review. Large/binary files remain available
through external tools; editor handoff and transcript path navigation remain #29.
