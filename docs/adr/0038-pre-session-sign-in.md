# 0038. Sign in before a session

- Status: Accepted
- Date: 2026-10-28
- Decider: Project owner
- Issue: #36 (M6), slice 3
- Extends: [0033](0033-agent-sign-in.md), [0036](0036-agent-settings-and-installed-sessions.md)

## Context

Settings lists installed and local agents, but sign-in is available only after starting or continuing
a session. ADR-0036 assigns sign-in before a session to the third slice of #36. `LiveSession` already
implements agent and terminal methods, but also owns a project, worktree and session controller.

[ACP v1 authentication](https://agentclientprotocol.com/protocol/v1/authentication) defines success
for `authenticate` and terminal exit status, but provides no portable account-status query or promise
that an authenticated connection's state survives a new process. An initialize response describes
methods; an empty list does not prove sign-in. Credentials remain the agent's responsibility.

T3 Code's provider settings offer Sign in, Cancel and Retry sign-in beside the configured provider
(`ProviderAuthenticationSection.tsx`). Agenthesia follows that placement with native sheets and its
existing terminal view. It cannot copy persistent account badges without a protocol source for them.

## Decision

**Entry point.** Add Sign In… to the newest installed version and to each explicitly added local
agent in Settings → Agents. An installed flow pins that exact version even if an update finishes.
The sheet initializes the agent, shows its advertised methods, and allows one attempt at a time.
No methods and unknown methods have explicit explanations. Discovery suggestions must first be added
or installed, as in ADR-0037.

**Ownership.** A small `AgentSignIn` owner in AgenthesiaCore owns this flow, independent of `LiveSession`.
`AgentCatalog` retains one active flow, so cancellation and app termination can await its cleanup.
Closing the sheet or Settings cancels the flow; quitting waits for cleanup even when no session exists.
Use the existing `AgentProcess`, ACP adapter, `SignInTerminal`, method-row presentation and terminal
view. Share only concrete helpers needed by both callers; do not redesign session startup.

**Launch.** Resolve the local command with the login-shell environment, or acquire the installed
version's lease and use its prepared command and runtime throughout. Run in an owned empty temporary
directory, never a project. Initialize with terminal authentication enabled under the same 20-second
bound as the readiness probe. Advertise no filesystem, session-terminal or elicitation capabilities.
No `session/new`, history row, worktree, prompt or durable sign-in state is created.

**Methods.** An agent method calls `authenticate` on the initialized connection. A terminal method
stops the ACP process and runs the same configured command with the method's appended arguments and
environment overrides, following ADR-0033. Its output and input use the existing terminal view.
After exit status zero, reconnect and initialize under the same bound before reporting completion.
A failed terminal preserves its output in the sheet until dismissed. Retry after a stopped connection
initializes again and uses the fresh method list. Interactive sign-in has no automatic user deadline;
Cancel remains available.

**Completion.** Report "Sign-in completed" only after the method succeeds and owned processes stop;
explain that the agent may ask for sign-in when a session starts. Do not show a persistent "Signed in"
badge. No-method, timeout, nonzero exit, connection loss and cancellation are not success. Starting or
continuing a session still handles authentication-required through ADR-0033 on its own connection.

**Cleanup.** Cancel, dismissal, failure and success close connections, terminate owned process groups,
join work still acquiring or launching resources, remove the temporary directory, and only then
release the installation lease. Late completion after cancellation cannot report success or replace
a newer flow. The app stores no credentials or terminal transcript from this flow.

## Alternatives

- **Retain the authenticated process for the next session.** Preserves connection-only authentication,
  but requires handing ownership and leases from Settings into session startup, deciding which future
  session claims it, and managing unused processes. Working-directory and capability negotiation also
  differ from a real session. Not recommended for this slice.
- **Use a temporary `LiveSession`.** Reuses orchestration but brings session metadata and workspace
  lifecycle into account setup. It conflicts with the requirement to sign in before any session.
- **Only offer terminal methods.** Smaller, but excludes agents that advertise only agent methods.

## Consequences and verification

Pre-session sign-in helps agents that retain their own credentials. It cannot guarantee that every
new connection is authenticated; session-time sign-in remains necessary. Logout, account switching,
credential storage and pre-session elicitation remain separate work.

Tests cover agent success/error, terminal success/failure and reinitialization, empty/unknown methods,
initialize timeout, cancellation during acquisition/startup/authentication, dismissal and quit,
installation removal while leased and release after cleanup. They assert that no session request is
sent and that no owned process or temporary directory remains. Native-app checks use MockAgent in
isolated defaults, exercise both methods and cancellation, and record accessibility coverage in PLAN.md.

The owner accepted this decision on 2026-10-28. Use Astra, High (`agent:strong`).
