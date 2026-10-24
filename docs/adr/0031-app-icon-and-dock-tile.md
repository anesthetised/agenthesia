# 0031. App icon and Dock tile

- Status: Accepted
- Date: 2026-10-24
- Decider: Project owner
- Scope: the app icon, README art and the Dock tile; extends the Dock badge of ADR-0030

## Context

The app needs an icon, and the Dock is where it is seen most. VISION asks for a calm app that interrupts only
when an agent needs a human, so the Dock should tell how many agents are running and whether one waits,
without a sound or a bounce. An app may replace the content of its Dock tile while it runs
(`NSDockTile.contentView`), but then it draws the whole tile itself. The system's own treatment of an
asset-catalog icon, such as the macOS 26 appearances, does not apply to a tile the app draws.

## Decision

- **The icon.** A sleepy moon under stars. Its sky is the `sky` palette; `night` is the same icon for a dark
  README background and is not an app icon, since the Dock has no dark variant.
- **One drawing.** `AppIcon` (AgenthesiaUI, SwiftUI `Canvas`) draws the icon for the Dock tile and renders the
  PNGs of `AppIcon.appiconset` (`just icon`, the `icon-render` tool). README shows static SVGs,
  `docs/images/logo-light.svg` and `logo-dark.svg`, which repeat the drawing with three stars lit; they are
  kept in step by hand, and each file says so.
- **Stars.** One star is lit for each live session, up to five places; the Dock badge keeps the exact count of
  sessions that need input. A failed session no longer runs an agent and does not count.
- **Awake.** The moon opens its eyes while any session needs input, which is also when the badge shows.
- **Rest state.** With no live session the tile content is removed and the asset-catalog icon returns, so an
  idle app looks like any other. The tile is drawn only while sessions are live.
- **Not animated.** The tile is redrawn when its state changes, and only then. Stars light and the moon wakes
  at once; nothing moves in between, which fits the calm principle and keeps the Dock free of timers.
- **Seam.** `AttentionSink.setDock(badge:live:)` replaces `setBadge`; `SystemAttention` keeps the last drawn
  state and redraws the tile only when it changes.

## Consequences

- While sessions are live the Dock icon is ours and has none of the system's treatment of catalog icons. The
  owner accepted this. Dark and tinted macOS appearances of the static icon would need a layered `.icon`
  from Icon Composer; that is separate work.
- Changing the icon means changing `AppIcon` and the two SVG files, then running `just icon`.
- Dock drawing is covered by tests of the state and the renderer's output, and checked in the built app; the
  tile itself cannot be read back by a test.
