# Work plan

The near-term order of work, for agents and humans picking up the next task. Milestones and issues on
GitHub stay the source of truth for scope; this file records order, dependencies, and the pitfalls known
so far. Update it when a step lands or the order changes.

Every step follows [AGENTS.md](../AGENTS.md): issue → branch → tests and docs → pull request after the
owner's approval. Architectural choices are presented to the owner as options with a recommendation
before implementation.

## State (2026-10-27)

- Live sessions run end-to-end ([ADR-0014](adr/0014-window-bound-live-sessions.md)): tool call
  cards, permission requests, scoped filesystem, agent-reported command output
  ([ADR-0016](adr/0016-agent-reported-command-output.md)).
- Saved history opens read-only; Continue reattaches it to its agent
  ([ADR-0017](adr/0017-continue-saved-sessions.md)).
- Tool call diffs render as unified diffs with word-level highlights (#20); side-by-side is not scheduled.
- The composer attaches files as `resource_link` and lists the agent's slash commands
  ([ADR-0018](adr/0018-composer-attachments.md), #18).
  Command rows retain their names inside the Commands accessibility group and use command names for
  identity and scrolling. Attachment chips retain their file icons across draft edits.
- Session config controls show confirmed settings between turns (#23,
  [ADR-0019](adr/0019-session-config-controls.md)); responses are committed before later notifications.
- The durable prompt queue supports editing, ordering, grouped sends and steering (#65,
  [ADR-0010](adr/0010-prompt-queue-and-steering.md), [ADR-0021](adr/0021-prompt-queue-lifecycle.md)). Stop
  pauses it; continued sessions with retained entries require explicit queue resume. Ended sessions remain available to Continue.
- Native session-scoped elicitation forms appear in the transcript (#24,
  [ADR-0020](adr/0020-native-elicitation-forms.md), [ADR-0022](adr/0022-session-scoped-elicitation.md)).
- Client-side `terminal/*` is deferred (#104), so the rest of M5 waits.
- Quick Open, the side file viewer and changed-file tracking (#26–#28) are merged (#113)
  under [ADR-0023](adr/0023-session-files.md). New Git sessions retain their initial revision; legacy
  sessions show working changes only. Changed Files compares with the session base rather than the
  merge base (#114, #115, [ADR-0024](adr/0024-changed-files-session-base.md)). Transcript paths open
  the file pane at a line, and Open in Editor hands off to the chosen editor (#29, #116,
  [ADR-0025](adr/0025-transcript-paths-and-editor-handoff.md)). M4 is complete.
- M7 slices 1–2 are merged in PR [#118](https://github.com/anesthetised/agenthesia/pull/118)
  (#37, [ADR-0026](adr/0026-app-wide-session-manager.md)): app-wide ownership supports parallel
  sessions, closing a window detaches it, and the sidebar groups sessions by project with live statuses.
  Local `just lint`, `just test` and `just app` pass; coverage is enforced by CI.
- M7 is complete: session controls and prompt error recovery (#119), window restoration (#120),
  notifications and the Dock badge (#121). The app icon and the Dock tile (#122) deliver the icon half of
  #45; its first-run flow remains open.
- M8 (Worktrees) is complete under [ADR-0032](adr/0032-worktree-merge-and-discard.md): the base branch (#123),
  discard (#124), review (#125) and squash merge (#127).
- Agent sign-in (#32, [ADR-0033](adr/0033-agent-sign-in.md)) is merged in #128.
- `ScenarioAgent` tolerates a saturated main actor in CI (#129); the saturation itself remains.
- M6: the registry client (#33), Node/npm checks (#34) and installers (#35) are merged; #36 is split into
  three slices under [ADR-0036](adr/0036-agent-settings-and-installed-sessions.md). Slice 1 (Settings →
  Agents, the agent picker and session leases) is merged in #141; slice 2 (local agents and the initialize
  probe, [ADR-0037](adr/0037-local-agents.md)) is implemented on `feat/agent-discovery`; slice 3
  (pre-session sign-in) is next.

## Previous batch: session interactions (merged)

| # | Issue | Depends on | Model and effort |
|---|-------|------------|------------------|
| 1 | #23 Config options picker | Approved ADR-0019 | Sol, medium |
| 2 | #65 Prompt queue and steering | Approved ADR-0021 and ADR-0010 | Sol, high |
| 3 | #24 Native elicitation forms | Approved ADR-0020 | Sol, medium |

The owner approved these decisions on 2026-10-16. All three landed in main through #112 and their
issues are closed. They were developed in isolated worktrees and integrated in the order above.

### 1–2. Config options, prompt queue (#23, #65)

- Both extend the composer from #18 (`ComposerInput` in `AgenthesiaUI/Composer.swift`). Its key
  handling is the pure `ComposerInput.keyAction`; Command-Return sends now even while the editor is
  first responder. Queue edits retain non-text attachment blocks.
- The behavior of #65 is fixed by [ADR-0010](adr/0010-prompt-queue-and-steering.md); queue entries are
  persisted in the event log. Queued prompts must keep their attachments.
- [ADR-0019](adr/0019-session-config-controls.md): native config controls, idle-only changes and
  agent-confirmed values committed before display; legacy modes stay in the adapter.
- [ADR-0021](adr/0021-prompt-queue-lifecycle.md): Stop pauses the queue; restored entries require Continue
  and explicit resume. Command-Return sends a nonempty draft only; with no draft it sends the queue
  ([ADR-0028](adr/0028-empty-draft-sends-queue.md)). Command-Shift-Return sends queued entries
  plus the nonempty draft last.
- `AgentProfile.steering` already reports whether the agent supports injection.

### 3. Elicitation forms (#24)

- `LiveSession` enables form elicitation; the controller validates and owns session-scoped requests.
  See [ADR-0009](adr/0009-tools-and-mcp.md).
- [ADR-0020](adr/0020-native-elicitation-forms.md): native transcript forms, durable requests and final
  answers, temporary drafts, cancellation on lifecycle termination. URL elicitation is separate work.
- [ADR-0022](adr/0022-session-scoped-elicitation.md): #24 supports established session scopes only;
  request-scoped forms are explicitly declined. Pre-session presentation, persistence and request
  lifetimes are deferred to [#111](https://github.com/anesthetised/agenthesia/issues/111).

### Integration and verification

- The shared base is `fee57ab`, containing the composer and approved decisions. This batch retains
  the composer dependency if it has not landed on main.
- Shared integration points are `SessionController`, `SessionEvent`, `TranscriptState`, `LiveSession`
  and `RootView`. Keep config confirmation, queue admission and form cancellation on the existing
  ordered event path. Queue draining waits for accepted config changes rather than losing its retry.
- Stop must supersede earlier pending steering/resume operations. Injection preparation retains
  recoverable content until acknowledgement; a pre-wire cancelled prompt is requeued and marked not
  sent. A wire turn ending during preparation falls back to a new turn without losing the draft.
- Close drains admitted config, queue and form work. Reopening cancels unfinished forms and leaves
  restored queued entries paused; a failed process reaching `closed` must still offer Continue.
- Use Sol high for lifecycle changes and integration. Medium is sufficient for bounded view work.
  Review changed SwiftUI/AppKit views with `swiftui-pro`. Serialize full builds/tests across worktrees;
  use `just lint`, `just test`, `just coverage` and `just app` for the integrated batch. Benchmarks,
  push and PR creation retain the approvals in `AGENTS.md`.

### Acceptance

| Issue | Acceptance criteria and focused verification |
|---|---|
| #23 | Select/grouped/boolean controls and legacy modes; confirmed settings replay correctly; rejected changes retain confirmed values; prompt submission cannot overtake a config change. |
| #65 | Queue editing/reordering/deletion preserve attachments across replay; combined sends retain message identity; shortcuts, pause/resume and steering obey ADR-0010/0021 under turn-end/cancellation races. |
| #24 | Supported fields validate required values and constraints; optional text can be omitted after editing; concurrent requests resolve once; stop/close/cancellation and recovery leave no pending callers or active historical forms; responses persist before delivery. |

The integration regressions cover config change → send → enqueue → form request → steering/Stop →
close → restore/Continue, checking ordered events, retained attachments and explicit queue resume.
Native hosted-view tests cover form sizing at narrow widths and draft identity across transcript
updates. Integrated `just lint`, `just test`, `just coverage` and `just app` pass; Core line coverage is
97.8%, above its 90% gate. Native app smoke checks cover form submission, attachment-preserving queue
edits, steering shortcuts, Stop, End Session, Continue and explicit queue resume. Keyboard actions and
accessibility labels were inspected; a spoken VoiceOver pass remains manual. Config response ordering
and model selection are covered by protocol tests; native popup selection was not completed by UI
automation.

CI pins Xcode 26.6 and runs package coverage and the app build in parallel with separate incremental
build caches. The aggregate `Lint, test, build` status requires both jobs to pass; cache hits still run
all checks. Coverage builds once, then runs the remaining core tests, AgentRuntime tests and hosted
UI/Rendering tests in three sequential invocations before merging their profiles (#133). Each group
retains parallel tests; no test or coverage threshold is omitted. Badge publication runs only after both
jobs succeed on main.

### Coverage test isolation (#133, 2026-10-27)

[Main run 40511015178](https://github.com/anesthetised/agenthesia/actions/runs/40511015178), on `5365bb0`,
failed only the 60-second limits of `toolCallsUpdateInPlaceAndReplayIdentically`,
`continueFailuresKeepTheHistory` and `mergeCommitsTheSessionEndsItAndRecordsTheOutcome` (63.5–64.0 s).
The combined 715-test run took 85.7 s; many unrelated successful tests also took 50–60 s. App build and
lint passed. This is consistent with #133's cross-target main-actor contention, not a Registry failure.
Local Xcode 27 runs separate test-target processes by default, so its green run did not reproduce the
CI runner's combined bundle.

The owner chose to separate hosted `AgenthesiaUITests`/`RenderingTests` from their complement rather
than serialize every test. `coverage.py` builds once, then runs the two groups sequentially using the
same regex for `--skip` and `--filter`. Tests within each group retain parallelism. Each invocation
keeps its 120-second process timeout; test time limits and coverage thresholds are unchanged. Both
groups run even if the first fails, and either failure fails the command. Group-specific profile names
prevent replacement on PID reuse; reporting still merges every profile and enforces all module gates.

Regression tests first failed against the single invocation. A deliberate selector mutation duplicated
the hosted group and omitted other tests; the partition test failed before the mutation was restored.
Local `just test-scripts` passes 18 tests, `just test` passes 735 Swift tests, and split `just coverage`
passes 550 non-hosted plus 185 hosted tests and every coverage gate (AgentRuntime 92.9%). The two
instrumented invocations took 43.7 s and 22.6 s locally, including runner overhead; these are validation
run times, not a benchmark or a CI speedup claim. Three corrupt raw profiles were excluded through the
existing merge policy. The same selectors were also verified with instrumented `just test
--build-system native`, which retains the combined test bundle: 550 non-hosted tests passed in 15.1 s,
including all three original failures, and 185 hosted tests passed in 16.4 s. These are bundle-reported
times excluding build/driver overhead. `just lint` and `git diff --check` pass.

The main-actor profiling, audit of machine-dependent waits and consecutive green CI runs in #133 remain
open. The failing GitHub run cannot validate unpublished changes. No benchmark or native-app UI check
was run for this test-runner change.

PR #137's [first run](https://github.com/anesthetised/agenthesia/actions/runs/40518505904) stopped at
lint before exercising the split: Xcode 26.6's `NeverUseForceTry` rule rejected two JSON fixture
encodings that the local Xcode 27 formatter had accepted. The fixture now records encoding errors as
test issues instead of using force try. The lint rule remains enabled. `just lint` and full `just test` pass for this follow-up (735 Swift tests
and 18 script tests). PR #137 subsequently passed its required checks and merged into main.

### CI Markdown attribute crash (#126, 2026-10-25)

The [original failed run](https://github.com/anesthetised/agenthesia/actions/runs/40134242723/attempts/1)
used macOS 26.6.2 (25G83), Xcode 26.6 and Swift 6.3.3. It aborted during the first quarter-second of
the test run in `NSAttributeDictionary.mutableCopyWithZone`, called by `MarkdownRenderer.inlineCode`.
This is a copy of the string's existing font/color attributes; the stack does not identify the new
background color or inline-code marker as the nil value. The string is local and has not been published,
and paragraph styles are applied later. Inspection found no mutation of shared attributes on this path.
Cold AppKit initialization remains a hypothesis, not a diagnosis.

On macOS 27.0.1 / Xcode 27.1, all 71 Rendering tests passed. Six fresh-process runs combining
`marksInlineCodeForCallers`, `hostedSettingsKeepTheStoredChoice` and
`previewIsSelectableReadOnlyAndAccessible` passed, as did an isolated inline-code control. These runs
used `just test --build-system native -Xswiftc -profile-generate -Xswiftc -profile-coverage-mapping`
with the test-name filter, to retain CI's single test bundle and instrumentation. They do not prove
safety on the failing OS/toolchain.

Thread Sanitizer reported no races in the 73-test Rendering/hosting diagnostic run, but
`SourceViewTests.highlightsALargeFile` exhausted its existing highlighting wait under the sanitizer,
so that run failed. The three-test cold-initialization scenario passed separately under Thread Sanitizer.
These are correctness diagnostics, not benchmarks; no performance conclusion is drawn from their timings.

The failed CI run retained no full crash report, so the other threads and framework image versions are
unavailable. After a coverage failure, CI allows 30 seconds for macOS to write test-runner `.ips`
reports, then attempts to upload them from both DiagnosticReports directories. Missing reports produce
a warning, and the failed check stays failed.
The artifact is named `test-crashes-<attempt>` and retained for 14 days. Inspect it on the next recurrence
before choosing a fix. No renderer change or reproducing regression has been justified; #126 stays open.

Validation: `just lint`, full `just test` (674 Swift tests and 15 script tests), `just coverage` (all gates;
Rendering 97.9%), `just app` and `actionlint .github/workflows/ci.yml` pass. Coverage discarded one corrupt raw profile
through its existing merge policy. Review found and addressed the asynchronous report-writing gap;
the wait recipe also resolves correctly with `just --dry-run wait-for-test-crash-reports`. Uploading a real
report on macOS 26 remains unverified until CI runs the change and a crash recurs. Native-app, VoiceOver
and system-prompt checks were not performed for this CI-only change.

## Next steps

The rest of M5 (#61, #67) waits for an agent that calls `terminal/create` (#104). Then #126 (the CI
rendering crash, strong tier) and M6 (Registry), whose installation scope is accepted in
[ADR-0034](adr/0034-agent-installs-with-user-runtimes.md). Small independent chores such as #73
(CI with Xcode 27) fit the light tier. The sections after this one record how M8, M7 and M4 were built
and verified.

### M6: Registry and local agents (2026-10-27)

Use user-provided Node/npm, isolated binary/npm installations and local ACP command discovery. Do not
download or update runtimes; defer `uvx` installation and standalone adapter packaging. ADR-0034
supersedes only the managed Node and installation decisions of ADR-0004; its historical text stays intact.

Implementation order (#33 merged in #136; #34 merged in #137; #35 merged in #140; #36 remains open):

1. **#33 — Registry client with ETag cache. Sol, High (`agent:light`). Merged.** Parse and cache registry
   metadata, conditional requests and platform distribution selection; retain unsupported entries
   for an explanation instead of silently hiding them.
2. **#34 — User runtime discovery and prerequisite checks. Astra, High (`agent:strong`). Merged.** Replace the
   old managed-Node scope with Node/npm checks and fresh login-shell capture for Check Again. Keep
   installation and launch on a consistent runtime, detect removed/incompatible runtimes, and keep
   running sessions unaffected. This can be developed independently of #33.
3. **#35 — Binary and npm installers. Astra, High (`agent:strong`). Merged.** After #33 and #34: private
   versioned installs, exact packages with retained lockfiles, binary verification, cancellation and
   failure cleanup, explicit updates with retained working versions, and removal only of owned files
   that are not in use. Authentication and chat use the same installation and runtime.
4. **#36 — Agent browser, local discovery and updates. Astra, High (`agent:strong`).** After #35:
   discover known local ACP commands without spawning them, retain manual setup, show prerequisites
   and Check Again, validate selected commands through bounded ACP initialization, and expose install,
   update and removal. A discovered ordinary CLI may still need an adapter and a compatibility check.
   Pre-session sign-in remains part of this issue as recorded by ADR-0033. The owner split it into three
   pull requests ([ADR-0036](adr/0036-agent-settings-and-installed-sessions.md)): 1) Settings → Agents,
   the agent picker and session leases; 2) local discovery from a built-in command table and the
   initialize probe; 3) pre-session sign-in.

Each implementation has its own branch and tests. Do not equate a successful initialize handshake
with successful sign-in. Verify first-run prerequisite recovery, discovery, updates and failures in the
built app with temporary fixtures/MockAgent; check VoiceOver and system prompts separately and record
what was actually exercised. No real-agent prompt or benchmark is needed for this documentation change.

ADR preparation checked upstream source and release metadata only; standalone adapter builds, real
agent sessions, native-app UI, VoiceOver and system prompts have not been tested for M6. The decision
and issue scope were recorded before implementation; implementation results follow below.
Documentation validation: `just lint`, full `just test` (695 Swift tests and 15 script tests),
`git diff --check` and local Markdown link checks pass.

#33 implemented (2026-10-27): `AgentRegistry` parses stable registry metadata and selects the exact
macOS platform binary before npm, retaining uvx and unknown kinds for unsupported explanations.
The client has an atomic body/ETag cache, conditional requests, bounded HTTPS fetching, explicit stale
cache warnings, cancellation and concurrent-request sharing. The owner selected stale cache with a
warning on refresh failure. No installer, runtime discovery or browser UI is included; #34 is next.
Tests use registry fixtures and URLProtocol rather than live agent processes. The red tests first
failed for missing models/client; an added redirect-port regression failed before the origin check
was corrected. A reproduced cancellation/network-failure race now gives cancellation precedence;
deliberately disabling binary selection made its regression fail, and the mutation was restored.
`just lint`, full `just test` before the cancellation follow-up, all 20 registry tests afterwards,
and full `just coverage` pass (715 Swift tests; AgentRuntime 92.6%, all module gates pass). The
`just test` recipe also passed its 15 script tests. Local documentation links and `git diff --check`
pass. Coverage skipped five corrupt raw profiles through the existing merge policy. Native-app UI,
VoiceOver, system prompts, live registry HTTP requests and real-agent sessions
were not exercised for this metadata-only change.

#34 merged in #137 (2026-10-27): `ShellEnvironment.refresh()` shares concurrent captures and
protects the cache from stale completion; running sessions retain their environment snapshot.
`NodeRuntime` discovers executable Node/npm, resolves the actual Node behind shims and a standard npm
CLI, checks both npm's own Node requirement and supplied package engine ranges with npm's semver, and
prepares commands using explicit tool paths. A persisted toolchain stores paths and versions only.
Revalidation refuses removed or changed tools and gives actionable diagnostics. The bounded shell
collector now also serves runtime probes; it still cleans up the process group. No runtime is installed
or changed. #35 supplies exact-package requirements and stores the descriptor; #36 owns Check Again
and recovery UI. Unresolvable npm wrappers are reported, not launched opportunistically.

Fixture tests cover shared refreshes and both stale completion orders,
prerequisite failures, recovery, version-manager shims, removed/changed tools, cancellation and paths
with spaces. The optional installed-Node/npm integration runs when both tools are available, without
installing anything: it exercises real semver ranges and launches a temporary JavaScript entrypoint
whose working directory contains misleading node/npm commands. It ran locally and caught a percent-
encoded filesystem path bug before the fix. No real agent, native-app UI, VoiceOver, system prompt or
benchmark was exercised. Local integration used Node 26.12.1 and npm 11.20.0, with a temporary npm
fixture reusing the installed semver dependency to verify prerelease handling. Missing package engine
ranges impose no extra constraint; an explicitly declared `*` retains npm's prerelease semantics.
A cancellation-during-shell-capture regression reproduced a missing-tool error taking precedence over
cancellation; both discovery and saved-toolchain preparation now give cancellation precedence. A
runtime-version mutation failed its regression before restoration. A colon in the Node directory is
rejected because it cannot be pinned as a single PATH entry. `just lint`, full `just test` before the cancellation/prerelease follow-ups, targeted regressions after
the fixes, and final full `just coverage` pass (735 Swift tests, AgentRuntime 92.9%, all module gates).
The test recipe also passed its 15 script tests. Coverage excluded three corrupt raw profiles through the
existing merge policy. Documentation links and `git diff --check` pass.

#35 implemented in [PR #140](https://github.com/anesthetised/agenthesia/pull/140) (2026-10-27), under the owner-approved
[ADR-0035](adr/0035-installer-storage-and-script-policy.md): `AgentInstaller` keeps versioned metadata and
payloads in AgentRuntime. Binary installs verify declared SHA-256 checksums and use system libarchive
with built-in filters only; extraction rejects links, special files, escaping paths and excessive expansion.
npm installs exact packages with isolated configuration/cache and lifecycle scripts disabled, retains
the manifest/lockfile, and launches the installed entrypoint through the saved, revalidated Node.
Updates retain old versions. Owned staging directories are cleaned on cancellation/failure; publication
is an exclusive rename. Shared launch leases prevent removal across cooperating installer instances.
The caller must retain a lease through sign-in/chat and release it after all owned processes exit.
Windows, history, readiness checks and recovery messages remain #36; no Persistence migration is needed.

Tests cover archive formats and hostile entries, HTTPS limits/redirects, checksums, failure/cancellation,
version retention, ownership, executable containment, runtime changes, npm flags and lease conflicts.
A local HTTP registry served a temporary fixture to real npm: installation and direct Node launch worked,
postinstall did not execute, user npm state was untouched, and the retained lockfile includes integrity.
This caught npm's sensitivity to `/var` versus the physical `/private/var` prefix: staging now uses
POSIX `realpath`. Other regressions caught Foundation directory URL normalization, a substituted payload
symlink, and process capture cancellation. The system libarchive's zstd registration requested an external
helper, so that filter is deliberately unsupported. Explicit lease unlock avoids retaining a lock through
a descriptor briefly inherited by a concurrent fork before exec.

Validation: `just lint`, full `just test` (758 Swift tests and 18 script tests), final `just coverage`
(all module gates; AgentRuntime 91.6%) and `just app` pass. A deliberately inverted SHA-256 comparison
failed the checksum/update regression before restoration; the truncated-archive test also checks a valid
header with an incomplete payload in a fresh destination. The coverage merge excluded 7 corrupt raw
profiles through the existing policy. Local documentation links and `git diff --check` pass.
No real agent, native-app UI, VoiceOver, system prompt or benchmark was exercised for this API-only slice.
Use Astra, High for #36's shared session/authentication lifecycle integration; Sol, High suits subsequent
isolated UI polish.

#36 slice 1 merged in [PR #141](https://github.com/anesthetised/agenthesia/pull/141) (2026-10-27), under the
owner-approved ADR-0036: Settings
gains an Agents tab (installed versions with Update and Remove, the Node.js/npm check with Check Again,
the ACP Registry with search, distribution, source and license confirmed before installation). The launch
form picks the newest installed version of an agent or a custom command. Migration
`v4-agent-install-installation` links one `agent_install` row to each installed version, so saved sessions
keep their version; Continue of a removed version names the agent and points to Settings. `LiveSession`
leases the version before creating a worktree, runs chat and terminal sign-in with the leased command and
releases the lease after its processes exit.

Pitfall found and fixed: #35's installer held its exclusive operation lock across the download, the npm
run and the shell capture of `acquire`, so starting a session while another agent installed, or two
parallel starts with one installed agent, failed with "Another installation or removal is in progress".
The lock now covers synchronous steps only. Both cases had red regressions before the fix. Disabling the
lease release made all three installed-session tests fail before restoration (a first mutation that only
skipped `release()` survived because dropping the lease object also unlocks it).

Validation: `just lint`, full `just test` (772 Swift tests and 18 script tests), `just coverage` (all
module gates; AgentRuntime 93.4%, AgenthesiaCore 97.7%; six corrupt raw profiles excluded by the
existing merge policy) and `just app` pass. Views were reviewed with `swiftui-pro`; `confirmationDialog(_:item:)`
was not adopted because it needs Xcode 27 and CI builds with 26.6. Tests use local registry stubs and
archive fixtures with MockAgent.

Built-app check (2026-10-27, Debug build of this branch, scripted with `osascript`/System Events and
`screencapture` because computer use was unavailable in the session): the live registry loaded, and search
narrowed it to OpenCode. The install confirmation named the source repository, the MIT license, the archive
URL and checksum verification. Cancelling during the download left no staging directory and no error.
A full install of OpenCode 2.2.0 (100 MB zip, SHA-256 verified) published the version in about 2.5
minutes. Check Again showed Checking… and then Node.js 26.12.1/npm 11.20.0 again. The launch form listed
OpenCode 2.2.0, hid the custom command fields, and started a session in a test repository whose agent ran
from the private payload. Removal was refused while the session ran. After End Session, Continue relaunched
the same version. After removing it, Continue showed the "no longer installed" message. The check found an
empty agent directory left after removing the last version; removal now deletes it (red regression first).
Not exercised: a real update (the registry offers one version per agent; covered by `AgentCatalogTests`),
npm installs from the browser, a prompt to the real agent, VoiceOver and system prompts. Form buttons in
the launch form and Agents tab expose no accessibility titles to System Events; the same is true of the
existing Choose… and Start Session buttons, so this needs a separate VoiceOver pass rather than a fix here.
Leftovers only the owner can remove: one test session, "OpenCode · agh-agents-check", in history.

#36 slice 2 implemented on `feat/agent-discovery` (2026-10-28), under the owner-approved ADR-0037: Settings →
Agents gains On This Mac. A built-in table of 18 known ACP commands and two ordinary CLIs (`claude`,
`codex`) is looked up on the login shell's `PATH` without running anything; found commands show their path
and ACP arguments and are added explicitly, Add Custom… adds any command, and the list lives in
`UserDefaults`. Local agents follow the installed versions in the launch form's picker. Check runs
`AgentProbe`: the command starts in an empty temporary directory with the login shell's environment, gets
ACP `initialize` under a 20-second timeout, and its process group is terminated; the result names the agent,
the protocol version and the number of sign-in methods, or why the command failed (it could not start, did
not answer, exited with its last stderr line, spoke another protocol version, or answered with an error).
`claude` and `codex` are shown with the registry adapter they need and an Install button.

Tests cover discovery (relative `PATH` entries, plain files, directories, first match, links not resolved),
the probe against MockAgent and shell fixtures (timeout with termination, early exit with stderr,
unsupported protocol, error response, missing executable) and the catalog (adding, de-duplication,
persistence across instances, removal, suggestions, per-command check results). Replacing the probe's
process termination with a constant status made the timeout and exit-status tests fail before restoration.
Validation: `just lint`, full `just coverage` (784 Swift tests; all module gates; AgentRuntime 93.5%,
AgenthesiaCore 97.4%). After the picker fix, `just lint`, full `just test` (784 Swift tests and 18 script
tests), and `just app` passed again. Views were reviewed with `swiftui-pro`.

Built-app check (2026-10-28, Debug build with the bundle identifier
`io.github.anesthetised.Agenthesia.localagentstest` so the list did not touch the owner's defaults, scripted
with System Events clicks at measured coordinates because walking the Agents tab's accessibility tree with
the full registry list took minutes): On This Mac listed `kimi` and `opencode` with Check and Add, and
Claude Code and Codex CLI with Install Claude Agent… and Install Codex…. Check on
`/opt/homebrew/bin/opencode acp` showed "Speaks ACP v1 · OpenCode 2.2.0 · 1 sign-in method", left no
`opencode acp` process and no probe directory. Add moved OpenCode to the top with Remove and wrote the
defaults key; Add Custom… with
MockAgent's path added "Mock Agent", whose Check showed Echo Agent 1.0.0. The picker listed both, and
choosing OpenCode hid the custom command fields. Removing both emptied the defaults list, and OpenCode
returned to Add with its check result kept. The check found that removing the agent selected in an open
launch form left the picker blank (also possible for an installed version since slice 1); the picker now
falls back to Custom Command, confirmed in a rebuilt app. Not exercised: Check on `kimi` (on this machine
it is Moonshot's Kimi Code, not the registry's Kimi CLI, and its reaction to `acp` is unknown), a session
started with a local agent (it uses the existing manual-command path; skipped to keep history clean),
Install from a suggestion, Look Again, VoiceOver and system prompts. The first scripted run raised a macOS
prompt for T3 Code to control the computer, which the owner resolved.

### Installer cancellation test readiness (#35, PR #140)

[Run 40548357958](https://github.com/anesthetised/agenthesia/actions/runs/40548357958), on `12dd3df`,
passed lint and the app build. Its only failure among 573 non-hosted tests was
`cancellationStopsTheProcessGroupBeforeTheCaptureDeadline`: the three-second `waitForChildPID` deadline
expired before the PID was available, before the test requested cancellation. The log does not establish
whether the delay occurred in task scheduling, the utility queue or process startup. A fixture delaying
startup by four seconds reproduced the same timeout locally against the old test.

The test now races child readiness against capture completion in a structured task group. An early
capture exit reports its actual outcome; the capture's existing 30-second deadline and the suite's
one-minute limit bound the test. Group cancellation joins cleanup before removing temporary files.
Once ready, both immediate and delayed fixtures still require a cancelled result, return within ten
seconds of cancellation, and an inactive child. Temporarily disabling cancellation polling made both
cases fail the ten-second assertion; production code was restored. Other callers retain the PID helper's
existing default deadline. This addresses this test's startup assumption, not the broader #133 audit.

Local `just lint` and full `just test` pass (758 Swift tests and 18 script tests). Instrumented
`just test --build-system native` with CI's non-hosted selector passes 573 tests in one combined bundle,
including both readiness cases. This follows the CI bundle structure on the local toolchain; it does
not reproduce the runner's exact scheduling load. CI confirmation awaits the follow-up push.
Production code and coverage thresholds are unchanged; the app build already passed on the failing run.

### Runtime process-test isolation and observation races (#133, PR #140)

[Run 40551715264](https://github.com/anesthetised/agenthesia/actions/runs/40551715264), on `e372241`,
passed the repaired capture cancellation test, lint and the app build. Its non-hosted group took 81.5 s
and reported seven issues in five existing process tests. Two observed a descendant only after natural
leader-exit cleanup had killed it; the stderr test also assumed its drain could not already be finished.
The other failures involved graceful-exit expectations and a ten-second bound under concurrent load.
These results do not establish a production termination defect, and no signal/grace policy is changed.

Delaying observation by four seconds reproduced the descendant-group and already-finished-drain
failures locally. Both integration fixtures now wait for an explicit release before the leader exits,
so their process-group assertions run while the leader is still alive. A separate stderr-reader test
keeps the writer open and checks the drain's own deadline without natural process cleanup or EOF.
`StderrCapture` is internal for this focused test; its implementation and public APIs are unchanged.

Coverage now separates AgentRuntime from Core as well as hosted views, extending the existing process
isolation. It builds once and runs three sequential groups: 451 remaining core tests, 123 runtime tests
and 185 hosted tests. A complement selector includes future targets automatically. Every group retains
its existing 120-second process timeout and parallel tests; any failure fails the run, all groups still
execute, and separate profile prefixes preserve merged coverage. Tests cover the partition, near-matching
target names, unique profiles and failure propagation from each group. A deliberate duplicated-runtime
selector failed those tests before restoration. This adds one test-driver invocation; no CI speedup is claimed.

Local `just lint`, 18 script tests and all 759 Swift tests pass. The three selectors were exercised
sequentially with instrumented `just test --build-system native`, preserving CI's combined-bundle layout,
and then through full `just coverage`: every module gate passes (AgentRuntime 91.9%). `just app` passes.
The delayed-observation regressions first failed before the fixture changes. CI confirmation awaits
the follow-up push; the broader scheduling/wait audit and consecutive CI verification in #133 remain
open. No benchmark or native-app UI check was run.

### Flaky `SessionControllerTests` in CI (#129, 2026-10-25)

The CI runner is not frozen during these failures; its main actor is saturated. In the failed run on
`0fcb77a`, tests that take a fraction of a second locally (in-memory `EchoAgent` sessions, hosted views)
each took 40–43 seconds and finished in one burst, as a shared serial queue does when it drains: hundreds
of `@MainActor` tests (`SessionController`, hosted AppKit and SwiftUI views) share one main thread on a
3-core runner. `ScenarioAgent` runs off the main actor, and its 5-second wait for the next client message
expired while the controller was still queued, so it reported a mismatch and closed the transport. That
yields every symptom in the issue: `start` throwing `.closed`, a prompt error read as transport loss
(`.failed`, then `.invalidState`), a non-`nil` mismatch, and a test waiting for a notification that never
comes until its time limit. The stack sample taken at the 120-second process timeout showed every thread
idle, so no test was spinning or blocking a thread at that point.

The default wait is now 50 seconds (`ScenarioAgent.defaultTimeout`): playback still ends, and closes the
transport so the test's awaits fail with its step, before a suite's one-minute time limit. A regression
test answers after 6 seconds and fails with `.closed` on the old default. A temporary experiment (not
committed) blocked the main actor for 6 seconds during `SessionController.start` against a scenario: it
failed with `.closed` at 5 seconds and passed at 50. `just lint` and `just test` pass.

Not addressed: the saturation itself (#133); other waits tuned to a quiet machine can fail the same way.
The test process's output also reaches the CI log in buffered bursts, so its timestamps do not show when a
test ran, and output still buffered when the process is killed is lost (#134).

### Agent sign-in (#32, 2026-10-25)

The owner accepted [ADR-0033](adr/0033-agent-sign-in.md): sign-in is offered when the session request gets
`-32000`, in the same session and worktree; agent methods use `authenticate` on the open connection, and
terminal methods run in a SwiftTerm sheet before the agent is launched again. Checking the adapters'
sources showed why both kinds are needed: `claude-agent-acp` offers only terminal methods, and only to a
client declaring `auth.terminal`; `codex-acp` offers only agent methods.

Slices, one commit each on `feat/sign-in`: `TerminalProcess` input, resizing and output observers; a
retryable `SessionController` (`authenticationRequired`, `retry`); `LiveSession` sign-in with the notice
and MockAgent's terminal login (`--auth`, `--auth-file`, `--login`); the panel, the terminal sheet and the
SwiftTerm dependency. A session waiting for sign-in counts as starting for discard and merge, because a new
one has no history yet.

Tests: terminal input, window size and observers; a start and a reopen that wait without writing, retry
on the same connection, a new connection after a terminal sign-in, close while waiting; against the real
MockAgent process, agent and terminal sign-in, a failed and an ineffective terminal sign-in, Cancel, close
during the terminal, and Continue; the notice and the badge; discard refused while waiting; the method rows,
the panel at 480 pt, the window model's sheet binding, and SwiftTerm showing output and sending typing.
Turning off `auth.terminal`, the discard guard, or the terminal's output feed each makes a test fail.
`just lint`, `just coverage` (694 Swift tests; Core 97.9%, AgentRuntime 92.9%) and `just app` pass.
`swiftui-pro` asked to put each type in its own file (applied). Pitfall: MockAgent's stdio transport read
standard input as soon as it was created, so `--login` creates it only in the agent modes.

Built app, checked by script (no computer use in the session) with MockAgent `--auth` in a temporary Git
repository, a temporary `CFFIXED_USER_HOME` and a fresh bundle identifier: the panel with both methods, the
*Needs input* mark in the sidebar and the Dock badge; the terminal sheet showing the prompt; a wrong answer
leaving the output and "Sign-in exited with status 1." until Close; the right answer closing the sheet and
opening the composer in the same worktree; Cancel killing the login process; the agent method opening the
composer. Not checked: VoiceOver, the system notification banner of the sign-in notice, a real
`claude-agent-acp` or `codex-acp`.

### M8 slices (2026-10-24)

The owner accepted [ADR-0032](adr/0032-worktree-merge-and-discard.md) after comparing T3 Code: the base
branch is recorded at start, the base is not pinned, merge is a local squash in the project checkout, and a
merged or discarded session is read-only. Each issue is written to be picked up by an agent of its tier
without this conversation; tiers follow AGENTS.md (light: Sonnet or Sol; strong: Opus or Astra; both at High).

| # | Issue | Depends on | Tier | Acceptance in short |
|---|---|---|---|---|
| 1 | #41 Record the base branch | — | light | `baseBranch` stored at start; nil for detached `HEAD`, non-Git and legacy sessions. Merged in #123 |
| 2 | #44 Discard and the worktree outcome | #41 | strong | `worktreeRemoved` event, safe removal of Agenthesia's worktrees only, Continue disabled, confirmation. Merged in #124 |
| 3 | #42 Review view | #41 | light | `baseBranch...HEAD` plus uncommitted, file by file; ADR-0024 fallback without a base branch. Merged in #125 |
| 4 | #43 Squash merge | #44, #42 | strong | Preconditions, intermediate commit, squash and final commit with hooks, rollback on failure. Implemented on `feat/worktree-merge`; verification below |

#42 and #44 can run in parallel in separate worktrees after #41; #43 reuses the removal and the event of
#44 and opens from the review view of #42. Each slice is its own branch and pull request, and closes its
issue. Pitfalls: the removal must never touch a directory outside the worktrees root (sessions of non-Git
folders run in the user's own directory); `git` commands run in the project checkout for merge and branch
deletion, and in the worktree for the intermediate commit.

#41 verified: `just lint` and `just test` pass. New tests cover a named branch, a branch with a slash, a
detached `HEAD`, a subdirectory selection and a non-Git folder; a round trip, a v1 and a v2 database upgrade
that leave `baseBranch` nil; and the branch surviving start, history and Continue. The first run failed to
compile against the missing property (RED). `just coverage` passes all gates (Workspace 97.4%, Persistence
100%, Core 98.3%) and `just app` builds. No UI changed.

#44 implemented: the outcome event and its replay, `SessionWorkspace.Worktree`/`remove`/`discardSummary`,
`SessionManager.discard`, *Discard Worktree…* in the Session menu and the sidebar context menu, the
confirmation and error alerts, and the outcome under saved sessions in the sidebar. `SessionManager.resume`
now returns nil while the session's worktree is being discarded. Workspace tests cover clean, dirty,
untracked and committed worktrees, a directory deleted by hand, a missing branch, an unregistered directory
at the expected path, refusal for a wrong id, the user's checkout, a path outside the root, a sibling with the
same prefix and a non-Git session, and the summary counts; breaking the path check makes the refusal test
fail. Core tests cover the event coding and replay, discarding a live and a saved session, a failed removal
(a locked worktree) that appends nothing followed by a successful retry, coalesced discards with Continue
refused meanwhile, refusal while continuing, and non-Git sessions; removing the replay guard in
`LiveSession` makes the Continue test fail. UI tests cover `canContinue`, menu eligibility, the alert text,
and a second window learning the outcome. `just lint`, `just test`, `just coverage` (Core 98.3%, Workspace 97.7%, Persistence 100%) and `just app` pass; `swiftui-pro` asked for model
bindings instead of `Binding(get:set:)` (applied; `alert(_:item:)` needs Xcode 27, which CI lacks).

#44 follow-up (2026-10-24): fixed two reproduced defects. The alert now passes its captured confirmation
to `confirmDiscard` because SwiftUI clears the presentation state before the button's task runs. Removal
checks the exact session branch immediately before `git worktree remove`; a different branch or detached
HEAD leaves the worktree and branches intact. Missing-directory/missing-branch retries still succeed.
Regressions failed before the fixes and pass afterward; inverting the branch guard also fails the new
preservation test. `just lint`, full `just test`, `just coverage` (Workspace 97.7%, Core 98.3%, Persistence
100%) and `just app` pass. The changed alert was reviewed with `swiftui-pro`.

Computer-use checks in the built app with MockAgent and temporary Git repositories pass: Session menu and
sidebar context menu, live and saved discard, confirmation counts, Cancel, and the error alert when the
branch changes after confirmation opens. The rejected removal preserves the dirty files; restoring the
session branch allows a retry. Successful removal deletes the session worktree and branch, preserves the
project checkout and other branch, retains the transcript, shows Discarded, and disables Continue and
repeated discard. After Quit/relaunch, selecting both sessions from history preserves those outcomes without
starting an agent. Screenshots were captured. VoiceOver, system permission prompts and automatic window
restoration were not checked.

#42 implemented (2026-10-25): `SessionWorkspace.review` resolves the base branch's merge base and
returns net working-tree changes, statuses and rename sources, plus nonignored untracked files.
Without a base branch it uses `baseRevision`, or HEAD for legacy working changes; a missing base branch
is an explicit error. `reviewContents` size-checks an immutable blob before loading it. Core's
`SessionReview` loads the selected file only, applies `SessionFileDocument`'s UTF-8/NUL and 2 MiB limits
to both sides, rejects outside symlinks and replaced roots, and retains a still-differing selection.
The native review sheet opens from the Session menu (⌃⌘R; ⇧⌘R remains Resume Queue) and Changed Files.
It shares `SessionFiles` invalidation, shows status and rename source, and renders through `UnifiedDiff`
and the native Markdown preview off the main actor. Merge remains #43.

The UI reference was T3's Changes entry point and
[DiffPanel](https://github.com/pingdotgg/t3code/blob/main/apps/web/src/components/DiffPanel.tsx).
A system sheet with a native selectable list and one unified diff follows VISION principles 2–3 and
keeps the existing 740 pt main-window minimum; layout and base-selection settings are omitted under
principle 6 and ADR-0032.

Focused tests pass: committed/staged/unstaged/untracked changes, a base advanced independently,
renames, deletion, subdirectory scope, base-revision and HEAD fallback, missing branch, bounded
historical reads, binary and invalid UTF-8 contents, outside symlinks and root substitution. Replacing
the merge-base calculation with the base branch tip makes the divergence test fail (then restored).
Hosted native-view tests pass in Aqua and Dark Aqua at 640 and 900 pt, covering the file list, Down-arrow
navigation, two-way selection, selectable read-only diff text, watcher-driven updates with selection
retained, binary notices and command eligibility. `swiftui-pro` review found no blocking issues.
`just lint`, full `just test` (650 Swift tests and 15 script tests) and `just coverage` pass all gates
(Workspace 98.0%, Core 98.4%, Persistence 100%); `just app` builds.

Computer-use checks in the built app with one MockAgent session and a temporary Git repository pass:
⌃⌘R and the Changed Files action open review; committed, staged, unstaged, added, deleted, renamed and
untracked files show correctly, while an unrelated base-branch commit is omitted. Tab into the list
and Up/Down change the selected diff. An external edit refreshes its contents without moving selection.
Binary and oversized files show their notices. Renaming the base branch produces an error naming it;
restoring it reloads review. End Session and Quit/relaunch preserve review for read-only saved history
without starting an agent. Light and dark screenshots were captured; the light pass used a process-only
`NSRequiresAquaSystemAppearance` argument, without changing System Settings. The test app was quit and
temporary repository/worktree files removed. No code fix was needed. VoiceOver, system permission
prompts and automatic window restoration were not checked.

#43 implemented (2026-10-25): `SessionWorkspace.mergeCheck` and `merge`, `SessionManager.merge` with the
turn hold in `SessionController`, the `merged(commit:into:)` outcome, and the merge sheet from review and the
Session menu. The owner settled four questions the ADR left open: the final commit runs in the login shell's
environment, the default message is the agent's session title or else the first prompt line, a saved
session merges without starting its agent, and a hanging hook has no Cancel (quit waits for the merge).
The owners end before the outcome is appended, rather than after as the issue listed, because closing
can still record events and the outcome must stay last. No `merged` event had been written before, so
the payload gained the base branch without a migration.

Workspace tests with temporary repositories cover committed, uncommitted, untracked and deleted changes
squashed into one commit with the session's exact tree and message; a base advanced independently; a
conflict, a rejecting `pre-commit` hook, an untracked file the merge would overwrite and changes already on
the base, each restoring the checkout without `SQUASH_MSG`; hooks found only on the given `PATH`
(`commit-msg` and `pre-commit`); and every blocker (dirty checkout, other branch, detached checkout, missing
base, no base, nothing to merge, worktree off its branch or missing, unresolved worktree conflicts) leaving
refs, the checkout and the worktree untouched. Core tests cover a live and a saved merge, refusal during a
turn, prompts, Continue, discard and a second merge refused while merging, quit waiting for a merge, a
conflict that keeps the agent usable, a failed removal that keeps the merge and lets Discard finish it,
and a session without a base branch. UI tests cover command eligibility and title, the default message,
blocker and conflict states kept in the sheet, and the read-only result. Removing the hold from
`dispatch`, any of the three `git reset --merge` calls, or the outcome guard in discard makes a test fail.
`just lint`, full `just test`, `just coverage` (Core 98.0%, Workspace 97.9%, Persistence 100%) and
`just app` pass. `swiftui-pro` asked to split the sheet's types into files and not to rely on colour
alone for failures (applied); a vertical `TextField` was rejected because Return would press Merge.

Checks in the built app (2026-10-25), scripted because the session had no computer-use tools (see
AGENTS.md): a copy with its own bundle identifier ran with `CFFIXED_USER_HOME` pointing at a temporary
directory, so its history, worktrees and Git identity never touched the owner's. MockAgent worked in a
temporary repository with a `commit-msg` hook that appends a line, and wrote `notes.txt` through a real
permission request. With a turn waiting for permission, *Merge into main…* explains that the session is
busy and offers no Merge button. A dirty project checkout shows its blocker, and Git is left untouched.
With the base branch advanced on the same file, Merge reports `file.txt`, leaves the base branch and the
checkout as they were (no `SQUASH_MSG`) and the agent usable; the worktree only gains the intermediate commit.
After the base was reset, the same sheet merged: one commit on `main` with the edited multi-line message and
the hook's line (so the hook ran in the app's environment), the tree of the session including its
untracked files, the worktree and branch gone, the session read-only with “Merged into main as a21ca50.”,
“Merged” in the sidebar, and Continue, Discard, Review and Merge disabled. After Quit and relaunch the
session opens from history read-only without starting an agent. The check found two defects, both fixed
and re-checked in a rebuilt copy: the failure text in the sheet was cut off to one line, and the commit
message field stayed visible beside a blocker. MockAgent's `write` needs an absolute path. Screenshots were
captured; the test app was quit, the clipboard restored and temporary files removed. The owner can remove
the notification entry of `io.github.anesthetised.Agenthesia.mergetest` in System Settings → Notifications
(its first-run prompt appeared). Not verified: VoiceOver, commit signing (needs the owner's key and
pinentry), and a hook that hangs.

#43 review follow-up (2026-10-25): a `/code-review` pass found ten issues; nine are fixed. A history write
failing after the commit and a failing `git reset --merge` no longer read as "the checkout was left as it
was"; the alert about a kept worktree appears after the sheets close; the intermediate commit runs no hooks
(`--no-verify` still ran `prepare-commit-msg` and `post-commit`); a merge, cherry-pick, revert or rebase in
progress in the checkout blocks the merge instead of being aborted by the reset; discarding a merged
session's leftover worktree says nothing is lost; leftovers are found at history refresh, not per sidebar
render; ADR-0032 gained notes for the refinements; and duplicated text and code were shared. The message
file is now written before anything changes. Not fixed: a removal that deletes the directory but fails to
delete the branch leaves `agenthesia/<id>` for the user to delete, because the app cannot see it without
running Git per row. New tests cover the hooks, the in-progress operation, a failed restore (a held
`index.lock`), the failed history write, and the kept worktree through the window model; removing the
hooks override, the operation check or the restore classification makes a test fail.

CI on #127 (2026-10-25) stalled the whole test process for about 43 seconds and ran into its 120-second
limit; main had finished its 650 tests in 34 seconds. Every suite that starts Git or an agent was slow at
once, and the stack of the stalled process stood in a test's `while controller.status != .running { await
Task.yield() }`: after the 60-second limit cancelled the test, the loop kept spinning on the main actor
shared by every other test. Waits in the merge tests now poll with `Task.sleep` under a deadline and fail
instead of spinning, and the three merge suites run one test at a time (`.serialized`), because eleven
Workspace tests started Git processes at once. The Workspace fixture writes its Git configuration in one
write instead of four processes. The first cause of the stall (a thundering herd of Git processes, or the
spin after the first timeout) was not reproduced locally, where the suites take 4–13 seconds.

### M7 slices (2026-10-17)

The owner accepted ADR-0026. Slices 1–2 are merged; slice 3 (#39) is implemented in this batch.
Implement slice 5 (#40) before slice 4 (#38), so notification activation reuses window opening and
selection.

| # | Slice | Acceptance and verification | Model and effort |
|---|---|---|---|
| 1 | `SessionManager` in Core owns every `LiveSession`; windows select one; closing a window detaches; quit closes all owners; the `SessionLibrary` live claim moves into the manager | Several sessions run at once; Continue on a live session selects it; a failed session stays until ended or continued; quit waits for every owner, including one still starting | Opus, high; merged in #118 |
| 2 | Sidebar: projects → sessions with derived statuses and the in-memory *done* mark | Status priority (needs input, failed, working, done, idle) is a pure tested function; showing a session in a key window clears *done*; accessibility labels | Sol, medium; merged in #118 |
| 3 | Quit confirmation and the Session menu (#39) | Confirmation only when a session works or needs input; previous, next and next-needing-input navigation in sidebar order | Sol, medium; implemented, verification below |
| 5 | Multiple windows and restoration (#40) | Window opening and selection are shared with later notification activation; value-based `WindowGroup` restores selections read-only with Continue; no agent starts on relaunch | Sol, medium; merged in #120, see below |
| 4 | Notifications with actions and the Dock badge (#38), after #40 | Posted only when the session is not in the key window of the active app; Allow once and Reject only for `allow_once`/`reject_once`; badge counts sessions needing input; system seams injected | Sol, high; implemented on `feat/notifications-dock-badge`, see below |

#39 adds focused-window Session commands, wraparound sidebar navigation (including saved history and
Starting), next-needing-input navigation, and a count-based quit confirmation before awaited shutdown.
New regression tests cover command eligibility, independent window selections, navigation, cancellation
and retry, idle/failed shutdown without confirmation, and resuming a paused empty queue to restore
normal Return behavior. The isolated #39 branch passed `just lint`, `just test` (579 Swift tests and
15 script tests), `just coverage` and `just app`; every module met its coverage gate (Core 98.1%).
`swiftui-pro` review found no blocking issues. Native menu focus/shortcuts and the actual quit alert
remain manual smoke checks; automated tests exercise selection, eligibility and injected confirmation.

Manual acceptance of the combined #39/#117 PR confirmed new-session/navigation and permission
shortcuts. Follow-up feedback adds empty-draft Command-Return to send the complete queue
([ADR-0028](adr/0028-empty-draft-sends-queue.md)), and native sidebar selection synchronized with
mouse and keyboard navigation. Regressions first reproduced the rejected empty send and the missing
native selection. The owner subsequently passed queue shortcuts, recoverable `fail`, selected-session
End, and quit confirmation/cancellation. Native selection is visible in the supplied screenshot.
The fatal `exit` check exposed disabled Continue: history refreshed on the controller's early ID, before
its database insert, and was not refreshed when startup completed. Refreshing after startup settles
preserves the saved-session eligibility guard and makes Continue available after process cleanup.
A hosted RootView regression blocks the initial insert, then verifies automatic history refresh and
`exit` → Continue → idle on the same session. Fresh Return after Continue is also covered by the
ADR-0029 follow-up below.
The combined follow-ups passed `just lint`, `just test` (591 Swift tests and 15 script tests), `just coverage`
(all gates; Core 98.2%), and `just app`. Queue, native sidebar and startup-persistence/Continue regressions were verified RED then
GREEN; the native selection check also fails when the binding is removed. `swiftui-pro` and code review
found no blockers. The first full run hit an existing shell-descendant timeout test before its PID file
was created; the isolated retry and subsequent full run passed without changes to that test.

Further acceptance exposed a pause that survived Continue and repeated explicit sends. The owner
accepted [ADR-0029](adr/0029-empty-queue-recovery.md): idle Return sends into an empty queue;
Continue clears only an empty queue's pause, and explicitly sending the last queued entry durably
restores ordinary sending. Retained entries stay paused; a newer Stop wins over a pending send.
Queue fixtures now create retained entries during a real running turn before Stop, rather than using
an empty paused queue to force new drafts into it. Regressions reproduced repeated fresh-draft
queueing after error/Continue and sticky pause after explicit flush before the fix.
The final follow-up passed `just lint`, `just test` (594 Swift tests and 15 script tests),
`just coverage` (all gates; Core 98.2%), and `just app`. The new Stop/injection regression fails if the generation
guard is removed. The atomic-dequeue failure test covers paused sends and verifies that a failed
batch commits neither the unpause nor the dequeue. `swiftui-pro` and code review found no blockers.
The owner passed the remaining native checks: repeated Return after `fail`, Return after
`exit`/Continue, and Return after explicitly draining retained paused entries. The supplied screenshot
shows separate fresh prompts receiving replies with an empty composer and Idle status. The agreed
manual acceptance checklist for #39/#117 is complete; retained work still requires explicit dispatch.

Pitfalls: parallel starts with one agent raced in `SessionLibrary.install` (a duplicate insert failed the
second start); installs are now serialized. The window model keeps its own selection token for history loads; a window may display an
owner the manager already removed, which then reads as ended. Run `swiftui-pro` over changed views.
CI exposed a process-readiness polling race: a task can resume after its deadline with the child PID
already recorded. Check readiness before the deadline; regression tests cover both a ready PID and a
missing PID after expiry.
Issues close with the slice that completes them: #37 with slice 2, #39 with slice 3, #38 with slice 4,
#40 with slice 5.

#### Notifications and the Dock badge (#38)

[ADR-0030](adr/0030-notification-activation-and-identity.md) is accepted. `SessionAttention` (Core) derives
notices from the manager and the sessions the windows report as shown, and drives an `AttentionSink`;
`SystemAttention` (UI) posts them through `UserNotifications` and sets the Dock badge. A tap opens
`agenthesia://session/<id>`; `RootView` handles it with `onOpenURL`, filling a lone blank launch form in
place or opening the session's window with `openWindow(value:)`. Tests cover derivation, identity and
removal, shown-window suppression, the badge, one-time authorization, `canDecide`, the payload and button
routing, URL parsing and window activation; removing the shown-session filter fails the suppression test.
Checks of the built app, scripted because the session had no computer-use tools (see AGENTS.md): with a
blank window, several windows, no window and a cold start the URL shows the session once and leaves no stray
launch window. With a MockAgent session and Finder in front: the system permission prompt appears at the
first session start; a permission request posts a banner with Allow once and Reject, and both buttons
record `allow` and `reject`, clear the banner and the Dock badge, and leave the app in the background; a
turn that ends while the session is not shown posts the finished banner, and one that ends while it is shown
does not. The check found that the badge never appeared because authorization omitted `.badge`; with it the
Dock shows `1` while a request waits and clears on any answer. A copy built with another bundle identifier
gave a fresh authorization to prove that. Tapping the finished banner (a System Events click; synthetic
CGEvent clicks and `AXPress` did not reach the app) brings the app forward and shows the session in its own
window. The blank *New Session* window seen at first came from a second process: Notification Center routes
a tap by bundle identifier, and with several copies registered (worktrees, derived data) it launched another
checkout's build next to the running one. A build with its own bundle identifier taps into the running
process, with no second process and no extra window.
Not verified: VoiceOver and the first-run prompt text.

Pitfall: `handlesExternalEvents(preferring: [], allowing: ["*"])` is what stops the system opening a new
window beside the one that handles the URL; without it every tap added a blank window.

#### Window restoration (#40)

Windows use `WindowGroup(for: WindowTarget.self)` (`.launch` or `.session(id)`). `RootView` publishes the
displayed target through the group's binding, which the system persists, and `SessionWindowModel.restore`
shows a saved session read-only (Continue available) or falls back to the launch form when the record is
gone. The sidebar context menu's Open in New Window calls `openWindow(value:)`, which raises the window that
already shows the session. Notification activation (#38) reuses the same call.

Hosted tests cover restoring, publishing and falling back. The owner's relaunch check needs System Settings →
Desktop & Dock → *Close windows when quitting an application* turned off: with it on, nothing is restored,
whatever the app does. With it off, three windows (launch form plus two saved sessions) came back after
Quit and relaunch with no agent started, and File → New Window twice opened two separate launch forms.
The context menu itself is a manual check (the accessibility tree did not expose it to scripting).

#### App icon and Dock tile (#45)

The icon half of #45; its first-run flow is separate work. [ADR-0031](adr/0031-app-icon-and-dock-tile.md) is
accepted. The app icon is the layered `App/AppIcon.icon` (sky fill, moon and stars as SVG layers with night
variants), so macOS 26 can build the Default, Dark and Tinted renditions; an `appiconset` cannot, because `actool`
drops its dark entries. `AppIcon` (UI) draws a sleepy moon with up to five stars for the Dock tile, README shows
the static `docs/images/logo-light.svg` and `logo-dark.svg`, and the three are kept in step by hand.
`AttentionSink.setDock(badge:live:)` replaces `setBadge`, and `SystemAttention` draws the tile while sessions
are live: one star per session that has not failed, open eyes while one needs input, and the icon from
`AppIcon.icon` back when none runs. The tile is always the light sky: the Dark, Clear and Tinted icon styles are
the system's, and the app has no public way to read them (see the ADR). The version that followed the app's
appearance is kept at the tag `app-icon-dark-mode-tile`.

Tests cover the stars' clamping, the eyes, the transparent margin and the live count the sink receives (a failed session stops counting). Rendering is stable to the eye but
not to the byte: the same icon drawn after a few others differs in rounding, so tests compare pixels with a
tolerance. Checked in a built process, not in the app: a scratch executable put `NSHostingView<AppIcon>` into
`NSApp.dockTile.contentView`, and a screenshot of the Dock showed the tile at the size of its neighbours, asleep
with three stars and then awake with one star and the badge `1`. The `.icon` compiles with `actool`, and the
built catalog holds Aqua, DarkAqua and Tintable stacks with the night layers and a separate dark gradient; the
default rendition, viewed as the compiled `AppIcon.icns`, matches the design. After adding the first icon, Launch
Services kept the Dock's generic icon for an already registered build path until `lsregister -f` re-registered
the bundle.
Not verified: the whole path with a real session in the running app (it would add a session to the owner's
history, which cannot be deleted), how the Dark, Clear and Tinted renditions look in the system (the Icon Composer
file was written by hand and only compiled, and switching the owner's icon style was not done) and VoiceOver.

### Prompt error recovery (#117)

[ADR-0027](adr/0027-recoverable-prompt-errors.md) is accepted and implemented on
`fix/prompt-error-recovery`. A JSON-RPC error response ends the turn, retains the live connection and
process, and pauses the queue without retrying it. Transport loss, invalid responses, process exit,
failed event writes and failed cancellation delivery remain fatal. MockAgent's `fail` and `exit`
exercise these paths separately, including agents without resume/load support.

Regressions cover error-response codes, a successful next prompt on the same session, replay,
attachment-preserving queues, explicit send/resume, pending permissions and forms, steering,
injection preparation, Stop, close and write failures. Register permission requests before awaiting
their initial event write, so turn completion can cancel them during that write. The regression
blocks the cancellation write and verifies that the session stays busy until it commits.
`just lint`, `just test` (582 Swift tests plus 15 script tests), `just coverage` and `just app` pass; Core line
coverage is 98.1%, above its 90% gate. The error-response and permission-admission regressions each
reproduced their failure before the fix; inverting the recovery condition also made the regression
fail. Filesystem tests separately cover retained access after a prompt error and revoked access after
transport loss.

### #29 slices (2026-10-17, merged in #116)

The owner accepted ADR-0025. One branch, `feat/clickable-paths`, one commit or more per slice, in order:

| # | Slice | Acceptance and verification | Model and effort |
|---|---|---|---|
| 1 | Core: path candidate parsing and resolution; editor table and URL construction | Suffixes `:line`, `:line:col`, `#Lline`; `./` dropped; absolute inside root → relative; outside root, `..`, symlinked escape → nil; percent-encoding of spaces, `#`, `?` and non-ASCII in editor URLs; table without a line template | Sol, medium; done |
| 2 | `SourceView` line navigation | Scroll a line into view and select it; clamp past the end; works before and after highlighting finishes; hosted-view test | Sol, medium; done |
| 3 | Structural links and the file pane: tool locations and diff paths, `agenthesia-path` interception, Open in Editor (⌥⌘O), Markdown switches to Source for a line | Click opens the pane at the line for the displayed session only; links never reach `NSWorkspace`; stale clicks after session switch are ignored | Sol, medium; done |
| 4 | Settings scene with the editor picker | Installed editors only, "System default" first, choice persists; missing editor falls back to the default app | Sol, medium; done |
| 5 | Inline code links with index-driven restyling | `Rendering` marks inline code generically; restyle on every index publication, bounded by cached rows; streaming rows keep their text; benchmark before/after | Opus, high; done, [benchmark](benchmarks/2026-10-17/transcript-links/README.md) |

Pitfalls: `Rendering` must not import Core; resolution reuses `ScopedFileAccess` canonical roots;
`SessionFiles.open` already guards the session identity. Run `swiftui-pro` over changed views before
committing slices 3–5. The owner approved slice 5's benchmark (200 rows with 20 inline spans each
against a 10,001-path index, three Release runs). Manual checks by the owner: mouse clicks on tool and inline links, VS Code, Cursor and Zed line jumps,
Settings and VoiceOver labels pass; Xcode's scheme ignores the line, so Xcode opens files at the start.
The pane button's ⌥⌘O did not fire, so Open in Editor is a File menu command; its shortcut, the
changed-file list after an ACP write and the unavailable-file layout were checked again.
Push and the pull request keep their separate approvals; save `just coverage` output to a log file.

### M4 parallel batch (2026-10-16)

The owner approved [ADR-0023](adr/0023-session-files.md): a side file pane and an initial Git revision
saved for new sessions. Existing sessions explicitly show working changes only; non-Git folders
support browsing and explain that change tracking requires Git.

| Issue | Owner and files | Acceptance and verification | Model and effort |
|---|---|---|---|
| #26 Quick Open | Index/search and palette, isolated worktree | Tracked/untracked/ignored paths, non-Git traversal, unusual names, deterministic bounded search, keyboard/focus/accessibility tests | GPT-6.1-Sol, medium |
| #27 File viewer | Bounded reads, Core document loader, source/Markdown views, isolated worktree | Scoped regular UTF-8 reads, 2 MiB boundary, binary/missing/errors, source/preview selection and hosted resizing tests | GPT-6.1-Sol, medium |
| #28 Changed files | Git changed paths, FSEvents bridge and successful ACP write invalidation, isolated worktree | Committed plus working changes, metadata-only events, selected-folder scope, external edits, cancellation/lifetime tests | GPT-6.1-Sol, high |
| Integration | Initial revision migration/capture, Core file state and RootView | Preserve base across start/replay/Continue; stale work cannot overwrite new selections; switching sessions and closing windows stop observation | GPT-6.1-Sol, high |

All file navigation uses the displayed session's working directory. RootView and shared presentation
state have one integration owner. The streams were integrated from separate worktrees, with Swift
build/test commands serialized. The owner approved the initial-revision migration and benchmark
workload before implementation and execution. Push and PR creation retain their separate approvals.

### File batch verification

The integrated suite has 523 Swift tests and 15 script tests. Regressions cover initial-revision
migration and start/replay/Continue preservation, committed and working paths, linked-worktree Git
metadata, ACP/external write invalidation, stale searches/selections, cancelled attachment/read tasks,
root symlink replacement during a scan, and watcher closure. The scan regression checks transient
publication, rather than only the final list after an FSEvents retry.
Review fixes keep search results and selection through background refreshes without progress flicker,
limit sustained rescans to one per second, exclude Git object/reflog events, report watcher failures
without clearing the index, skip non-UTF-8 names and unreadable subdirectories, and keep files across
Continue. `just lint`, `just test`, `just coverage` and `just app` pass after the review fixes. Coverage remains above every module gate: Core 97.9%, Workspace 97.5%, Persistence 100%, Rendering 97.5%, ACP 99.0%, JSONRPC 98.7%, AgentRuntime
92.6% and CLI 88.7%.

Hosted native tests switch Markdown Preview/Source at 740, 900 and 1000 pt widths and bound a long
source line to its viewport. Native app checks cover Command-P, arrow/Return selection, changed-file
navigation including committed paths, external updates and Reload, binary-file errors, Preview/Source,
divider resizing and closing the pane. Source views accept the proposed viewport size to prevent
native constraint-update recursion; the detail container accepts its available width to avoid clipping
the whole split view. Keyboard access and accessibility labels were inspected; spoken VoiceOver
verification remains manual.

The approved three-run Release benchmark passed every count/content validation. Medians are 101.552 ms
for indexing 10,001 files, 192.190 ms for all 20 fuzzy queries, 87.378 ms for 100 changed paths and
0.712 ms for a bounded 2 MiB read. These are initial API timings, not an improvement or UI-latency claim;
see [raw results and limitations](benchmarks/2026-10-16/files/README.md).

## Open research

Not scheduled, pick up when they block something: #77, #78, #83 (transcript and highlighting hitches),
#97 (streaming performance), #98 (raw-notification contract), #91 (`posix_spawn` lifecycle).
