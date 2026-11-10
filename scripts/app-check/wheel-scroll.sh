#!/bin/bash
# The wheel scenario of #396: scrolls a recorded session in the optimized lab build with real wheel or trackpad
# events, while Instruments records Animation Hitches and the transcript's Points of Interest (`Cell`, `Message`,
# `Show`, `RowView`, `TextLayout`, `TableLayout`, `Draw`).
#
#   scripts/app-check/wheel-scroll.sh <wheel|gesture> <new .trace path>
#
# `wheel` posts mouse wheel lines without phases (3 lines, 60 events/s); `gesture` posts trackpad-like drags of 20
# points, 120 events/s, one gesture per second, without momentum. Each scrolls up for SECONDS_EACH (default 15) seconds
# from the end of the session, then down as long. The history is a copy of HISTORY (default: the installed app's) in a
# temporary home, pruned to one session: SESSION (an id) or the one with the most events. It is renamed `Wheel
# scenario` and points at an empty repository, so nothing of the owner's is touched. APP defaults to the lab build;
# WINDOW is the window's size in points (default `1480 860`).
#
# It needs `just lab-build` and `just app-check-tools`. It drives the app through scripts/app-check/lib.sh: leave the
# machine alone while it runs (about 50 seconds); it aborts when another app comes to the front.
set -euo pipefail

cd "$(dirname "$0")/../.."
input=${1:-}
out=${2:-}
[ "$input" = wheel ] || [ "$input" = gesture ] || { echo "usage: $0 <wheel|gesture> <new .trace path>" >&2; exit 1; }
[ -n "$out" ] && [ ! -e "$out" ] || { echo "ABORT: give a new .trace path" >&2; exit 1; }
app=${APP:-.build/xcode-lab/Build/Products/Debug/Agenthesia.app}
history=${HISTORY:-"$HOME/Library/Application Support/Agenthesia/history.sqlite"}
seconds=${SECONDS_EACH:-15}
read -r width height <<<"${WINDOW:-1480 860}"
[ -d "$app" ] || { echo "ABORT: $app is missing; run \`just lab-build\`" >&2; exit 1; }
[ -f "$history" ] || { echo "ABORT: no history at $history" >&2; exit 1; }

tmp=$(mktemp -d /tmp/agh-wheel.XXXXXX)
pid=
recorder=
cleanup() {
    [ -n "$recorder" ] && kill -INT "$recorder" 2>/dev/null && wait "$recorder" 2>/dev/null || true
    [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
    rm -rf "$tmp"
}
trap cleanup EXIT

# The data folder follows the bundle identifier, as AppSupport.folderName does.
bundle=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")
case $bundle in
io.github.anesthetised.Agenthesia.?*) folder="Agenthesia-${bundle#io.github.anesthetised.Agenthesia.}" ;;
*) folder=Agenthesia ;;
esac
support="$tmp/Library/Application Support/$folder"
mkdir -p "$support" "$tmp/work"
git -C "$tmp/work" init -q
git -C "$tmp/work" -c user.name=Wheel -c user.email=wheel@example.com commit -q --allow-empty -m init
db="$support/history.sqlite"
sqlite3 "$history" ".backup '$db'"

# One settled session, found in the sidebar by its new title. Deleting sessions is allowed through session_deletion
# (ADR-0044), here in the copy only.
session=${SESSION:-$(sqlite3 "$db" "SELECT sessionID FROM event GROUP BY sessionID ORDER BY count(*) DESC LIMIT 1")}
[ -n "$session" ] || { echo "ABORT: the history has no session" >&2; exit 1; }
sqlite3 "$db" <<EOF
INSERT INTO session_deletion SELECT id FROM session WHERE id != '$session';
DELETE FROM event WHERE sessionID != '$session';
DELETE FROM session WHERE id != '$session';
DELETE FROM session_deletion;
DELETE FROM project WHERE id NOT IN (SELECT projectID FROM session);
UPDATE session SET title = 'Wheel scenario', archivedAt = NULL, workingDirectory = '$tmp/work';
UPDATE project SET rootPath = '$tmp/work';
EOF
echo "Session $session: $(sqlite3 "$db" "SELECT count(*) FROM event") events"

. scripts/app-check/lib.sh
CFFIXED_USER_HOME=$tmp "$app/Contents/MacOS/Agenthesia" -NSRequiresAquaSystemAppearance YES &
pid=$!
export APP_CHECK_PID=$pid
sleep 4
guard
ax 'set position of window 1 to {80, 60}' >/dev/null
ax "set size of window 1 to {$width, $height}" >/dev/null
sleep 1

# Open the session from the sidebar.
row=$(ac_tool axlabels "$pid" | grep -m1 -F " d=Wheel scenario, " || true)
[ -n "$row" ] || { echo "ABORT: no sidebar row for the session" >&2; exit 1; }
read -r left top <<<"$(echo "$row" | sed -E 's/^[^@]*@([0-9-]+),([0-9-]+).*/\1 \2/')"
guard
ac_tool wintool click "$((left + 20))" "$((top + 10))"
sleep 4
ac_tool axlabels "$pid" | grep -F " d=Conversation " >/dev/null || { echo "ABORT: the transcript did not open" >&2; exit 1; }

# The pointer over the middle of the transcript column, right of the sidebar.
read -r _ left top width height _ <<<"$(ac_tool wintool winid "$pid" | head -1)"
x=$((left + width * 62 / 100))
y=$((top + height / 2))

xcrun xctrace record --template 'Animation Hitches' --instrument 'Points of Interest' --attach "$pid" \
    --time-limit "$((2 * seconds + 8))s" --output "$out" --no-prompt &
recorder=$!
sleep 4
for direction in 1 -1; do
    for _ in $(seq "$seconds"); do
        guard
        if [ "$input" = wheel ]; then
            ac_tool wintool scroll "$x" "$y" "$((3 * direction))" 60 16
        else
            ac_tool wintool gesture "$x" "$y" "$((20 * direction))" 120 8
        fi
    done
done
wait "$recorder"
recorder=
echo "Saved $out"
