# 0030. Notification activation and identity

- Status: Accepted
- Date: 2026-10-24
- Decider: Project owner
- Scope: #38; completes the notifications and Dock badge of ADR-0026

## Context

ADR-0026 fixes what is notified and when: a notification only for a session that is not shown in the key
window of the active app, Allow once and Reject only for `allow_once` and `reject_once`, a Dock badge
counting sessions that need input, and activation that selects the session in a window. It leaves open how
a notification reaches a window. Notification Center delivers the response to the AppKit delegate, while
opening a window by value (`openWindow`) exists only inside SwiftUI, and the user may have closed every
window. It also leaves open what identifies a notification, so that a stale one disappears.

## Decision

- **Activation by URL.** A notification tap opens `agenthesia://session/<id>` with `NSWorkspace`. The app
  declares the scheme in `App/Info.plist`; the generated plist keeps the other keys. Windows handle the URL
  with `onOpenURL` and `handlesExternalEvents(preferring: [], allowing: ["*"])`, so an open window receives
  it instead of the system making a new one, and with no window open the system makes one to receive it.
  `WindowTarget` converts to and from the URL; anything but a well-formed session URL is ignored. The URL
  only selects a session by identifier and starts nothing.
- **Which window.** A blank launch form that is the only window shows the session in place, which covers
  the case with no window open. Otherwise `openWindow(value:)` raises the window that shows the session or
  opens one, as the sidebar's Open in New Window does.
- **Derived notices.** `SessionAttention` in Core derives the wanted notices from the manager on every
  change and diffs them with those already posted: it posts new ones and removes those that no longer apply.
  Nothing is stored. The system side is an `AttentionSink` seam; `SystemAttention` in AgenthesiaUI
  implements it with `UserNotifications` and the Dock tile, and is created only inside an app bundle.
- **Identity.** A permission request or form is identified by its request, so answering it anywhere removes
  its notification. A failure is identified by its session, and a finished turn by its session and
  completed-turn count. A notice ends when its cause ends, when the session ends, or when the session
  is shown in the key window of the active app; going away from a session with a pending request posts it
  again, while a failure, which no one can answer, is announced once and again only if the session fails
  anew. A session that failed before it had a controller is reported too. Nothing is posted until the
  system has answered the authorization request, and banners left over from an earlier run are removed at
  launch, because sessions do not survive quitting.
- **Shown sessions.** A window tells `SessionManager.setShown` which session it shows while its scene
  appears active, and clears it when it closes. The set is observable, so notices follow it.
- **Buttons.** A button re-reads the pending request when pressed, picks the offered `allow_once` or
  `reject_once` option, and does nothing for a request that is gone. Buttons never bring the app forward.
- **Badge and permission.** The badge counts sessions that need input whether or not they are shown.
  Authorization is requested once, when the first session appears in the process, for alerts, sounds and
  badges; without the badge option the Dock never shows the count, and macOS then offers no *Badge app
  icon* switch. The system remembers the answer.

## Alternatives

- **A router object the windows observe.** No Info.plist change, but with no window open nothing observes
  it, so it needs a way to make a window anyway.
- **A hidden always-present scene holding `openWindow`.** A macOS scene is either visible or not alive.
- **Posting from the controller.** Puts the system into the event path and cannot remove a notice when the
  user answers in the window.

## Consequences

Other apps can open `agenthesia://session/<id>` to bring a session forward, which reveals nothing and
changes nothing. A notification left over from a previous run opens that session read-only with
Continue. The URL scheme and the Dock badge are not exercised by package tests: they are covered by
pure functions (derivation, payload, routing, activation) and checked by hand in the app.
