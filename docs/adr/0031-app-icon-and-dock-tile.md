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
app icon, such as the macOS 26 Dark and Tinted styles, does not apply to a tile the app draws.

A classic `AppIcon.appiconset` cannot carry those styles for macOS: `actool` accepts dark entries but keeps
only the default images. A layered Icon Composer icon (`.icon`) can.

## Decision

- **The icon.** A sleepy moon under stars. `App/AppIcon.icon` holds its layers: a sky gradient as the fill, a
  moon-with-face layer and a stars layer as SVG, each with a night variant for the dark appearance. The system
  builds the Default, Dark and Tinted renditions from it; the build compiles it with the asset catalog, and
  the synchronized `App` folder picks it up without a project change.
- **The Dock tile.** While sessions are live, `AppIcon` (AgenthesiaUI, SwiftUI `Canvas`) draws the tile, always
  in the sky of the Default icon style. The icon style chosen in System Settings (Default, Dark, Clear,
  Tinted) is the system's: Settings changes it through a private SkyLight call, the app's appearance does not
  follow it (Dark Mode with the Default style still shows the light icon), and no public API reads it. Matching
  it would need a private call, an undocumented `defaults` key or a guess from the pixels of the icon the
  system shows, so the tile does not try. An earlier version followed the app's appearance; it is kept at the
  tag `app-icon-dark-mode-tile`.
- **Copies.** The Swift drawing, the `.icon` layers and README's `docs/images/logo-light.svg` and
  `logo-dark.svg` are three renditions of one design and are kept in step by hand; each file says so. The
  layers are plain SVG, written without Icon Composer, so opening the icon there is a way to adjust it.
- **Stars.** One star is lit for each live session, up to five places; the Dock badge keeps the exact count of
  sessions that need input. A failed session no longer runs an agent and does not count.
- **Awake.** The moon opens its eyes while any session needs input, which is also when the badge shows.
- **Rest state.** With no live session the tile content is removed and the icon from `AppIcon.icon` returns,
  so an idle app looks like any other. The tile is drawn only while sessions are live.
- **Not animated.** The tile is redrawn when its state changes, and only then. Stars light
  and the moon wakes at once; nothing moves in between, which fits the calm principle and keeps the Dock free
  of timers.
- **Seam.** `AttentionSink.setDock(badge:live:)` replaces `setBadge`; `SystemAttention` keeps the last drawn
  state and redraws the tile only when it changes.

## Consequences

- While sessions are live the Dock icon is ours and has none of the system's treatment of app icons, which
  the owner accepted. The Dark, Clear and Tinted styles apply only to the idle icon, so with the Dark style the
  live tile is light while the idle icon is dark. If macOS gains a public way to read the style, the tile can
  follow it.
- Changing the icon means changing three places; none can be generated from another without a tool for SVG
  export from Swift, which does not exist.
- Dock drawing is covered by tests of the state and the rendered output, and checked in the built app; the tile itself cannot be read back by a test. The `.icon` is checked by compiling it: the built
  asset catalog holds Aqua, DarkAqua and Tintable icon stacks with the night layers and gradient.
