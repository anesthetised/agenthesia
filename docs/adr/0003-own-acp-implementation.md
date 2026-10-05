# 0003. Own ACP implementation

- Status: Accepted
- Date: 2026-10-05

## Context

ACP has official SDKs for Rust, TypeScript, Python and Kotlin, but not for Swift. Community Swift SDKs
exist, with unclear maintenance. The protocol is small: JSON-RPC 2.0 over stdio, one JSON message per
line. A JSON Schema is published (`schema/v1/schema.json`, JSON Schema 2020-12, with tagged unions via
`discriminator`). Generic code generators handle tagged `oneOf` poorly in Swift.

A v2 protocol is in development. It is an unstable draft that changes almost daily and has no
stabilization date. It removes `session/load`, `session/set_mode`, `authenticate` (replaced by
`auth/login|logout`) and all client-side `fs/*` and `terminal/*` methods: agents execute commands and
file operations themselves.

## Decision

- Implement ACP ourselves: a protocol-agnostic `JSONRPC` module and an `ACP` module on top of it.
- Hand-write the `Codable` wire types. Tagged unions are enums with a custom discriminator decoder.
  Unknown variants are preserved as `.unknown(raw)` instead of failing, for forward compatibility.
  `_meta` is kept as an opaque `JSONValue`.
- Vendor the pinned schema (`schema.json`, `meta.json`) in `Resources/acp-schema` as the reference.
  A test checks that every method in `meta.json` is either implemented or explicitly marked unsupported.
- Implement stable v1 only. Unstable features (`session/fork`, subagents, `nes/*`, `document/*`,
  `mcp/message`, `providers/*`) are not supported.
- Client capabilities: `fs.readTextFile`, `fs.writeTextFile`, `terminal`, `auth.terminal`, `elicitation`
  and boolean session config options.
- **Prepare for v2 without implementing it:**
  - wire types live in a versioned namespace (`ACP.V1`);
  - Core talks to a version-agnostic `AgentConnection` protocol built on the methods v1 and v2 share
    (`initialize`, `session/new|prompt|cancel|list|resume|close|delete|set_config_option`,
    `session/request_permission`, `session/update`, `elicitation/*`, `$/cancel_request`);
  - the v1 adapter implements `AgentConnection` and contains everything v1-only (`fs/*`, `terminal/*`
    via `TerminalHost`, `session/load`, modes, `authenticate`);
  - the UI never assumes who executed a command: terminal output reaches it as tool call content;
  - session restore prefers `session/resume`, which both versions have;
  - `protocolVersion` is negotiated during `initialize`.
- Add a v2 adapter once the v2 schema is stable and the major agents (Claude, Codex) speak it.

## Consequences

- Full control over the most important layer of the app, with no third-party dependency in it.
- We must follow schema changes by hand; the vendored schema and the conformance test make drift visible.
- The v2 migration is confined to a new adapter rather than a rewrite of Core and UI.
