# Helpers for scripted running-app checks (AGENTS.md → Testing the running app). Source from bash or zsh:
#
#   export APP_CHECK_PID=<pid of the app under test>
#   export APP_CHECK_SHOTS=<existing directory for screenshots>
#   export APP_CHECK_AGENT=<path of the MockAgent executable>     # pickagent
#   export APP_CHECK_REPO=<Git repository with a commit>          # pickproject
#   . scripts/app-check/lib.sh
#
# The Swift tools come from `just app-check-tools` (.build/app-check/). A function aborts the calling script
# (`exit 1`) when its input is missing or the app is not frontmost, so source this file in a script, not in
# an interactive shell you want to keep.

# Layout-dependent: accessibility paths of the draft screen. They follow the window layout and break when it
# changes; find the new ones with `dump` and fix them here.
AC_DRAFT="group 3 of splitter group 1 of group 1 of window 1"
AC_PROJECT_MENU="menu button 1 of $AC_DRAFT"
AC_AGENT_MENU="menu button 2 of $AC_DRAFT"
AC_DRAFT_TEXT="text area 1 of scroll area 1 of $AC_DRAFT"

# zsh does not word-split unquoted variables and has no BASH_SOURCE: quote everything, resolve the directory
# per shell.
if [ -n "${ZSH_VERSION:-}" ]; then
    AC_SOURCE=$(eval 'echo ${(%):-%x}')
else
    AC_SOURCE=${BASH_SOURCE[0]}
fi
AC_DIR=$(cd "$(dirname "$AC_SOURCE")" && pwd)
AC_BIN=$AC_DIR/../../.build/app-check

ac_need() {
    local name
    for name in "$@"; do
        eval "[ -n \"\${$name:-}\" ]" || { echo "ABORT: $name is not set (see scripts/app-check/lib.sh)" >&2; exit 1; }
    done
}

ac_tool() {
    local tool=$AC_BIN/$1
    shift
    [ -x "$tool" ] || { echo "ABORT: $tool is missing; run \`just app-check-tools\`" >&2; exit 1; }
    "$tool" "$@"
}

# Activate the app and abort unless it is frontmost: the owner may be working at the same time.
guard() {
    ac_need APP_CHECK_PID
    [ "$(ac_tool wintool front)" = "$APP_CHECK_PID" ] || {
        osascript -e "tell application \"System Events\" to set frontmost of (first process whose unix id is $APP_CHECK_PID) to true"
        sleep 0.5
    }
    [ "$(ac_tool wintool front)" = "$APP_CHECK_PID" ] || { echo "ABORT: app not frontmost" >&2; exit 1; }
}

# Window id of the app's first window.
wid() { ac_need APP_CHECK_PID; ac_tool wintool winid "$APP_CHECK_PID" | head -1 | cut -d' ' -f1; }

# shot <name>: save the app window to $APP_CHECK_SHOTS/<name>.png.
shot() { ac_need APP_CHECK_PID APP_CHECK_SHOTS; screencapture -x -o -l "$(wid)" "$APP_CHECK_SHOTS/$1.png" && echo "shot $1"; }

# ax <System Events clause>: run it against the app's process, e.g. ax 'click button 1 of window 1'.
ax() { ac_need APP_CHECK_PID; osascript -e "tell application \"System Events\" to tell (first process whose unix id is $APP_CHECK_PID) to $1"; }

# paste <text>: clipboard + ⌘V, because `keystroke` follows the keyboard layout. Overwrites the clipboard.
paste() { printf '%s' "$1" | pbcopy; guard; osascript -e 'tell application "System Events" to key code 9 using command down'; }

# key <code> [modifiers], e.g. key 36 or key 0 "command down".
key() {
    guard
    if [ -n "${2:-}" ]; then
        osascript -e "tell application \"System Events\" to key code $1 using {$2}"
    else
        osascript -e "tell application \"System Events\" to key code $1"
    fi
}

# dump [depth]: the accessibility tree of the first window.
dump() { ac_need APP_CHECK_PID; osascript "$AC_DIR/axdump.applescript" "$APP_CHECK_PID" "${1:-14}"; }

# Draft helpers: choose the repository in the open panel, the MockAgent as a custom command, send a message.
pickproject() {
    ac_need APP_CHECK_REPO
    guard
    ax "click $AC_PROJECT_MENU" >/dev/null; sleep 0.8
    ax "click menu item \"Choose Folder…\" of menu 1 of $AC_PROJECT_MENU" >/dev/null; sleep 1.5
    key 5 "command down, shift down"; sleep 0.8
    paste "$APP_CHECK_REPO"; sleep 0.5
    key 36; sleep 1; key 36; sleep 1.5
}

pickagent() {
    ac_need APP_CHECK_AGENT
    guard
    ax "click $AC_AGENT_MENU" >/dev/null; sleep 0.8
    ax "click menu item \"Custom Command…\" of menu 1 of $AC_AGENT_MENU" >/dev/null; sleep 1.2
    key 0 "command down"
    paste "$APP_CHECK_AGENT"; sleep 0.4
    key 36; sleep 1
}

draftsend() {
    guard
    ax "set focused of $AC_DRAFT_TEXT to true"
    key 0 "command down"
    paste "$1"; sleep 0.3
    key 36
}
