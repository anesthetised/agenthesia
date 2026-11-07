# Agents settings

Settings (⌘,) has two tabs, `General` and `Agents`. The Agents tab manages every agent the draft's Agent chip offers:
installed registry versions, local agents found on this Mac or added by hand, the Node.js and npm that npm agents need,
the ACP Registry catalog, and sign-in before any session. Nothing there runs on its own except looking for commands and
reading the registry. The tab's model is `AgentCatalog`.

## General

- `Open files in` picks the app Open in Editor (⌥⌘O) uses: `System default`, then the supported editors that are
  installed. A chosen editor that is no longer installed shows as `Not installed (<name>)`. The caption under the
  picker explains which editors open at the selected line.

## Opening the tab

- Showing the Agents tab reloads the installed versions, looks for local commands, refreshes the registry and, the
  first time an npm agent matters, checks Node.js and npm.
- `Manage Agents…` in the draft (the Agent chip's menu, the `No agent is installed.` hint, and the failure banner of a
  missing or removed agent) opens the Settings window. It does not switch to the Agents tab.

## Installed

- The section appears once a version is installed, or when the installed versions cannot be read (the reason in red).
- One row per agent, by name: the name, and under it every installed version, newest installation first
  (`1.4.0, 1.3.2`).
- `Sign In…` signs in to the newest version (see Sign-in below).
- `Update to <version>…` appears when the registry offers a version that is not installed. It opens the same
  confirmation as Install; the older version stays installed and saved sessions keep the version they ran with
  ([ADR-0036](../adr/0036-agent-settings-and-installed-sessions.md)).
- `Remove` is a menu with `Remove <version>` for each installed version. It removes at once, without a confirmation,
  and shows `Removing…`. A version a session is running cannot be removed: `This agent version is in use. End its
  sessions before removing it.`
- During an install or removal the buttons give way to a spinner and the operation's text. A failed operation leaves
  its message in red under the row until the next operation on that agent.

## On This Mac

- The header has `Look Again` (an icon; help `Look again with a fresh login-shell PATH`) and `Add Custom…`.
- Rows, in order: local agents the user added, known ACP commands found on the login shell's `PATH` that are not added
  yet, and ordinary CLIs that need an adapter. The first two show the name and the command line, selectable.
- Local agent rows have `Check`, `Sign In…` and `Remove`. `Remove` only takes the agent off the list; its sessions
  keep their own record of the command ([ADR-0037](../adr/0037-local-agents.md)).
- Found rows have `Check` and `Add`. Adding records the path where the command was found, not its symlink target.
  *Why:* a package manager upgrade behind the same link keeps working.
- A `claude` or `codex` CLI shows its path and `<name> does not speak ACP by itself; it needs the <adapter> adapter
  from the ACP Registry.`, with `Install <adapter>…` when the registry lists it. The row disappears once the adapter
  is installed, found or added.
- With nothing added and nothing found: `No known ACP agent was found on your PATH.`
- `Check` shows a spinner, then in green `Speaks ACP v<n> · <agent> <version> · <n> sign-in methods`, or in red why it
  failed (could not start, closed, not ACP, another protocol version, or no answer within 20 seconds).
- Footer: `Agenthesia looks for known ACP agents on your login shell's PATH without running them. Check starts a
  command briefly in an empty folder to ask whether it speaks ACP; it does not sign in.`
  *Why:* finding a command never starts it, and a check runs it in an empty temporary folder with no session, so a
  program that turns out not to be an agent touches no project. A passed check does not gate the draft's picker.
- `Add Custom…` opens `Add Custom Agent` with `Name`, `Executable` (`/path/to/agent or command on PATH`) and
  `Arguments`, footer `One argument per line. The command must speak ACP over standard input and output.` `Add` is
  enabled once Name and Executable are filled; a command already on the list is not added twice.

## Node.js and npm

- The section appears when the registry offers an npm agent or an npm agent is installed.
- Status line: `Not checked yet`, `Checking…` with a spinner, `Node.js <version> and npm <version>` in green (help:
  the path of `node`), or the problem in orange.
- `Check Again` captures a fresh login-shell environment and checks again; it is disabled while checking.
- Footer: `npm agents run with the Node.js and npm from your login shell. Agenthesia does not install or change them;
  after installing or switching Node.js, use Check Again.`
  *Why:* Agenthesia manages agent installations but uses the developer's runtimes, rather than distributing and
  updating its own Node.js ([ADR-0034](../adr/0034-agent-installs-with-user-runtimes.md)).

## ACP Registry

- The header has `Refresh` (an icon), disabled while refreshing; the footer says `Updated <relative time>.`
- `Search agents` filters by name, ID and description, in registry order.
- A row shows `<name> <version>`, the description (two lines), then how it is distributed (`Binary for this Mac`,
  `npm package <package>`, `Requires uv (uvx), which Agenthesia does not support yet`, `No distribution for this
  Mac`), the license and a `Source` link.
- The button is `Install…`, or `Update…` when an older version is installed; the current version shows `Installed`.
  Unsupported distributions have no button.
- Install opens a confirmation `Install <name> <version>?` that states the source, the license (or `a license the
  registry does not state`), that the agent runs with your permissions and is not part of Agenthesia, and either the
  archive downloaded (with or without a checksum to verify) or that npm installs the package with install scripts
  disabled ([ADR-0035](../adr/0035-installer-storage-and-script-policy.md)).
- While installing, the row shows `Installing <version>…` and `Cancel`. Cancel removes the partial files, keeps
  installed versions and shows no error. A failure shows in red under the row while no version is installed, else
  under the Installed row.
- A registry that cannot be loaded shows its reason in orange; a cached catalog is still listed under that warning.

## Sign-in

- `Sign In…` on an installed agent or a local agent opens a sheet `Sign in to <name>` (`<name> <version>` for an
  installed one, pinned to that version even if an update finishes). Only one sign-in exists at a time: every
  `Sign In…` is disabled while a sheet is open or still stopping
  ([ADR-0038](../adr/0038-pre-session-sign-in.md)).
- The sheet shows `Getting sign-in methods…`, then the agent's methods with their descriptions: `Sign In` for an agent
  method, `Sign In…` for a terminal method. An unknown method is listed with `Agenthesia does not support this
  method.` and cannot be used. No methods: `This agent offers no sign-in methods. If sign-in is needed, follow its
  setup instructions.`
- While a method runs, its row shows a spinner and `Cancel`, and the other methods are disabled.
- A terminal method turns the sheet into a terminal titled with the method's name, with `Follow the instructions in
  the terminal.` and `Cancel`. Escape goes to the program in the terminal. If it exits with an error, the sheet keeps
  its output with `Sign-in exited with status <n>.` and `Close`, which returns to the failure.
- Success shows `Sign-in completed` and `The agent may ask you to sign in again when you start a session.` Nothing
  records an account as signed in. *Why:* ACP offers no account status, and a new agent process may ask again.
- A failure (timeout after 20 seconds, the agent exiting, an error) shows the message and `Retry`, which starts the
  agent again and lists its methods afresh.
- The bottom button is `Cancel` (Escape), and `Done` after success or failure. Cancel, Done, closing the
  Settings window and quitting the app all stop the sign-in; the sheet shows `Stopping…` until its processes are gone.
  The sheet cannot be dismissed any other way.

## Changes

- 2026-11-08, #261: summarised from ADR-0036, ADR-0037, ADR-0038 and ADR-0040 (Manage Agents…), with links to ADR-0034
  and ADR-0035, checked against main at c65b8a1.
