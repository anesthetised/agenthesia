# 0033. Agent sign-in

- Status: Accepted
- Date: 2026-10-25
- Decider: Project owner
- Scope: signing in to an agent from the app (#32); complements [ADR-0004](0004-agent-runtime.md),
  [ADR-0015](0015-agent-terminals.md), [ADR-0017](0017-continue-saved-sessions.md) and
  [ADR-0026](0026-app-wide-session-manager.md)

## Context

The app assumes agents are already signed in. When `session/new` or the reopen request answers with the
ACP error `-32000` (authentication required), the start fails with that message and nothing else; the
session's worktree has already been created and stays behind. `acp-cli login` can sign in from a terminal,
but the app has no equivalent.

ACP v1 offers two kinds of auth method in the `initialize` response:

- **agent**: the client calls `authenticate(methodId)` on the open connection and the agent signs in by
  itself. Codex (`codex-acp`) offers only these: ChatGPT opens the browser from the agent, and the API key
  methods read `CODEX_API_KEY` or `OPENAI_API_KEY` from the agent's environment. Gemini CLI's methods are
  of this kind as well.
- **terminal**: the client runs the agent's own command with the method's extra `args` and `env` in a
  terminal the user can type into, then restarts the agent. Claude (`claude-agent-acp`) offers only these
  (`--cli auth login --claudeai` or `--console`; a TUI `/login` when it detects a remote machine), and only
  to a client that declares the `auth.terminal` capability. The app does not declare it, so a signed-out
  Claude agent currently reports no way to sign in at all.

## Decision

**Trigger.** Sign-in is offered when starting or continuing a session gets `-32000` from `session/new`,
`session/load` or `session/resume`. The start does not fail: the session waits in a *sign-in required*
state in its own window, with the agent's methods listed by name and description. Nothing has been
written for it yet (a new session's record is created after `session/new`, a reopened one writes only
after the agent accepts), so the state leaves no history behind, and the prepared worktree is reused.
After a successful sign-in the same `LiveSession` retries the request on the same worktree; another
`-32000` returns to the method list with a note that the agent still requires sign-in. The sidebar shows
the session as *Needs input*, it counts towards the Dock badge, and a notification without actions says
that the agent needs sign-in. Ending the session from this state discards nothing: a new session's
worktree is kept like after any failed start (ADR-0032).

**Agent methods.** The app calls `authenticate` on the open connection and, on success, retries the
session request on that connection, because ACP binds authentication to the connection. The agent may
open the browser; the method stays in progress until the agent answers, and Cancel closes the connection
and kills the agent, so the next attempt starts it again. An error response is shown beside the method.

**Terminal methods.** The app declares `auth.terminal` (not the older `_meta["terminal-auth"]`). Choosing
a terminal method shuts the agent down and runs the agent's executable and arguments, followed by the
method's `args`, in a pseudo-terminal: the login-shell environment, then the method's `env`, with
`TERM=xterm-256color`; the session's working directory; process-group termination as in ADR-0015. Unlike
an agent terminal, this one forwards the user's input and window size. A sheet over the session window
shows it with [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) (MIT), with links opening in the
browser. When the command exits with status 0 the sheet closes, the agent is launched again, initialized,
and the session request is retried. A nonzero exit keeps the sheet open with the output and the status,
with Close returning to the method list. Cancel, ending the session, closing its last window or quitting
kills the command's process group and waits for it, as for the agent process.

Methods of unknown kinds are listed as unsupported. The CLI's `login` command is unchanged.

**Out of scope.** Sign-in before any session (an agent list with *Sign In…*) belongs with the agent
browser of the registry (#36). An agent that starts answering `-32000` to prompts mid-session keeps the
recoverable prompt error of ADR-0027; the user can end the session and Continue it, which reaches the
sign-in state above. Logout is not offered.

## Alternatives

- **Hand the command to Terminal.app** through a temporary `.command` file and watch a status file: no
  dependency, but the user leaves the app, the Terminal window outlives the flow, and success is detected
  through the file system. Rejected.
- **A console without an emulator**: `TerminalText` output and a line field writing to the PTY. Enough for
  the line-based `auth login`, but Claude's remote `/login` is a full-screen TUI. Rejected.
- **Fail the start and offer sign-in afterwards**: simpler in Core, but each attempt leaves a worktree and
  makes the user press Start again. Rejected.
- **Restart the agent after an agent method too**: one path for both kinds, but agents may keep the
  credentials in the connection only. Rejected.

## Consequences

SwiftTerm becomes a dependency of `AgenthesiaUI` only; the background processes panel (#61) can reuse it.
Its build tool plugin makes `xcodebuild` require `-skipPackagePluginValidation` on the command line and a
one-time *Trust & Enable* in Xcode. `TerminalProcess` gains input, resizing and a live output stream, used
only by sign-in; ADR-0015's agent terminals still write nothing to their input. Sign-in is not recorded in
history. An agent that needs a terminal method and exits with status 0 without signing in returns the user
to the method list, which is the only signal the app has.
