# 0053. Require macOS 27

- Status: Accepted (2026-11-19, #413)
- Date: 2026-11-19
- Decider: Project owner
- Supersedes in part: [0002](0002-tech-stack-and-layout.md) (*Platform*: the minimum system)
- Related: #73 (CI with Xcode 27), #126 (an AppKit crash seen on macOS 26), #411

## Context

[ADR-0002](0002-tech-stack-and-layout.md) set the minimum at macOS 26 and built with the current Xcode, with
availability checks for anything newer. CI built with Xcode 26.6 on `macos-26`, while development used Xcode 27 on
macOS 27. The two toolchains behaved differently (Swift 6.2 against 6.4; AppKit geometry; Swift Testing process
layout), and several problems (#126, #133) reproduced on one and not the other. #73 proposed to add Xcode 27 to CI
beside 26.6, and #411 did, informationally.

## Decision

**The app requires macOS 27.** `MACOSX_DEPLOYMENT_TARGET = 27.0` and `platforms: [.macOS(.v27)]` in
`Packages/AgenthesiaKit/Package.swift`, whose `swift-tools-version` is 6.4 because `.v27` does not exist in the 6.2
manifest API.

**One toolchain.** A minimum of macOS 27 needs the macOS 27 SDK, so Xcode 27 builds everything. CI runs Xcode 27.2 on
the `xcode-27` runner image as the only toolchain, and every job is required; the Xcode 26.6 entries are gone. Locally
and in CI the same compiler, SDK and test runner now run.

Availability checks for macOS 27 become always true and may stay; removing them and the Swift 6.2 workarounds is a
separate change, made when it pays.

## Consequences

- Users on macOS 26 lose the app. The project has no release yet, so nobody is cut off; the owner chose to drop them
  rather than keep two toolchains.
- The required check runs on a public preview image (actions/runner-images#14404). Queueing, image updates or an
  outage there can block merges; the owner accepted that. If it becomes a problem, the answer is a new ADR, not a
  fallback matrix.
- The macOS 26 environment in which #126 reproduced is no longer tested. The crash is looked for on macOS 27 only.
- The core test group's process timeout in `scripts/coverage.py` is 240 seconds, as the hosted group's: on the
  `xcode-27` image the group took 125 s against 83–90 s on `macos-26`, with nothing hung.
