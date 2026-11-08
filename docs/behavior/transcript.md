# Transcript

The conversation of a session fills the center of its window: one row per message, tool call or notice, in a column
at most 720 pt wide that the composer card below it shares ([ADR-0039](../adr/0039-t3-style-window-layout.md)). This
document covers how rows are selected and copied and how the keyboard moves through them; what each kind of row shows
is not summarised here yet.

## Row selection

- Clicking a row selects it; ⇧-click and ⌘-click extend the selection to a range and toggle single rows, as in any
  table. Several rows can be selected at once.
- A selected row gets a quiet background: the color of `.quaternary` fills (`NSColor.quaternarySystemFill`), in
  a rounded rectangle (10 pt radius) as high as the row, behind its content, and 8 pt wider than the text column on each
  side so the text does not touch its edge (the column's margin keeps it inside the window). There is
  no system selection band across the window, whether or not the window is key.
- The text of a selected row keeps its normal colors: status labels such as `1 failed` stay red, the running status
  keeps the accent color. Nothing turns white.
- The background fades in and out in 0.12 s when a row on screen is selected or deselected, and appears and
  disappears at once under Reduce Motion. Rows that are created already selected (after scrolling or a rebuild) show
  the background at once.
- The system adapts the fill to light and dark appearance and to Increase Contrast.
- Find in Transcript (⌘F) selects the row of the current match and scrolls to it.
- VoiceOver reports the selection as it does for any table row; the background is not an accessibility element.

*Why quiet:* the system band is a saturated bar across a window whose content is a 720 pt column, and it recolors
the text; a selection here marks which message ⌘C or a keystroke acts on, not a state to read at a glance.

## Copy

- ⌘C (Edit → Copy) with rows selected puts them on the pasteboard as Markdown, whole rows in transcript order,
  separated by a blank line.
- A tool call row copies its output, and a folded summary of several calls copies what its cards hold. When a summary
  and some of its expanded cards are both selected, the cards are copied once.
- Pointing at a row shows a `Copy` button in its header (tooltip `Copy message as Markdown`) that copies that one
  row; VoiceOver gets the same action as a custom action `Copy` on the row. It is a small bordered button in the
  system's label colors, readable on the selection in light, dark and Increase Contrast.

## Keyboard navigation

- ↑ and ↓ move the selection by one row, ⇧↑ and ⇧↓ extend it; Page Up, Page Down, Home and End scroll by a page
  or to the start or end of the transcript. These are the table's own keys.
- Any of these keys, like scrolling with the wheel or trackpad, stops the transcript from following the end of a
  running turn; reaching the end again resumes it.

## Changes

- 2026-11-09, #301: a row's hover Copy follows the pointer when a layout moves the row from under it.
- 2026-11-09, #160: a row fits its content again after the transcript changes width, with no empty band above the
  text.
- 2026-11-08, #269: a quiet selection: a rounded `.quaternary` background of the text column's width instead of the
  system band across the window; text keeps its colors; the transcript area written.
- 2026-11-08, #288: the selection background reaches 8 pt past the text column on each side; the hover `Copy` button is a
  small bordered button instead of the inline one, whose light text vanished on the selection in light mode.
