#!/bin/bash
# The wheel scenario of #396: the Rendering Lab's S12 (S2's 10,000 items in the app's transcript table, from the end,
# in a 1240 x 760 pt window) scrolled with real wheel or trackpad events, while Instruments records Animation Hitches
# and the transcript's Points of Interest (`Cell`, `Message`, `Show`, `RowView`, `TextLayout`, `TableLayout`, `Draw`).
#
#   scripts/app-check/wheel-scroll.sh <wheel|gesture> <new .trace path>
#
# `wheel` posts mouse wheel events of WHEEL_LINES lines (default 3) without phases, 60 per second; `gesture` posts
# trackpad-like drags of GESTURE_POINTS points (default 20), 120 events per second, one gesture per second, without
# momentum. Each scrolls up for SECONDS_EACH (default 15) seconds from the end, then down as long. The recording starts
# before the first event and stops after the last; then scripts/trace_summary.py prints the hitch time ratio over the
# time spent scrolling and the signposts. APP defaults to the lab build; PROTOTYPE (default App) picks the lab's
# transcript, e.g. A2 for the prototype table. The lab runs under its own bundle identifier in a temporary home
# (CFFIXED_USER_HOME), so it reads nothing of the installed app's.
#
# It needs `just lab-build` and `just app-check-tools`. It drives the app through scripts/app-check/lib.sh: leave the
# machine alone while it runs (about a minute); it aborts when another app comes to the front.
set -euo pipefail

cd "$(dirname "$0")/../.."
input=${1:-}
out=${2:-}
[ "$input" = wheel ] || [ "$input" = gesture ] || { echo "usage: $0 <wheel|gesture> <new .trace path>" >&2; exit 1; }
[ -n "$out" ] && [ ! -e "$out" ] || { echo "ABORT: give a new .trace path" >&2; exit 1; }
app=${APP:-.build/xcode-lab/Build/Products/Debug/Agenthesia.app}
[ -d "$app" ] && app=$(cd "$app" && pwd)   # LaunchServices runs it by its absolute path, which pgrep matches.
seconds=${SECONDS_EACH:-15}
lines=${WHEEL_LINES:-3}
points=${GESTURE_POINTS:-20}
[ -d "$app" ] || { echo "ABORT: $app is missing; run \`just lab-build\`" >&2; exit 1; }
bundle=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")
[ "$bundle" != io.github.anesthetised.Agenthesia ] || {
    echo "ABORT: $app has the installed app's bundle identifier; rebuild it with \`just lab-build\`" >&2
    exit 1
}

tmp=$(mktemp -d /tmp/agh-wheel.XXXXXX)
pid=
recorder=
cleanup() {
    [ -n "$recorder" ] && kill -INT "$recorder" 2>/dev/null && wait "$recorder" 2>/dev/null || true
    [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
    rm -rf "$tmp"
}
trap cleanup EXIT
now() { python3 -c 'import time; print(time.time())'; }

. scripts/app-check/lib.sh
# S12 holds its window longer than this script needs and then quits, so the lab never outlives a failed run for long.
# Started by a shell, the app presents no window; through LaunchServices it presents the lab.
open -n --stdout "$tmp/lab.log" --stderr "$tmp/lab.log" --env "AGENTHESIA_LAB_RUNS=S12:${PROTOTYPE:-App}:$((2 * seconds + 90))" \
    --env "CFFIXED_USER_HOME=$tmp" "$app" --args -NSRequiresAquaSystemAppearance YES
for _ in $(seq 50); do
    pid=$(pgrep -n -f "$app/Contents/MacOS/Agenthesia" || true)
    [ -n "$pid" ] && break
    sleep 0.2
done
[ -n "$pid" ] || { echo "ABORT: the lab did not start" >&2; exit 1; }
export APP_CHECK_PID=$pid

# The window appears once the grammars are loaded and the transcript is laid out at its end.
for _ in $(seq 60); do
    [ "$(ax 'exists window "S12 Wheel"' 2>/dev/null)" = true ] && break
    kill -0 "$pid" 2>/dev/null || { cat "$tmp/lab.log" >&2; echo "ABORT: the lab quit" >&2; exit 1; }
    sleep 0.5
done
[ "$(ax 'exists window "S12 Wheel"' 2>/dev/null)" = true ] || { echo "ABORT: no S12 window after 30 s" >&2; exit 1; }
read -r left top width height <<<"$(ax 'get {position, size} of window "S12 Wheel"' | tr -d ',')"
x=$((left + width / 2))
y=$((top + height / 2))

# Job control gives the recorder its own process group, where SIGINT, which ends the recording, is not ignored as it is
# for background jobs of a script. The time limit is a backstop only.
set -m
xcrun xctrace record --template 'Animation Hitches' --instrument 'Points of Interest' --attach "$pid" \
    --time-limit "$((2 * seconds + 60))s" --output "$out" --no-prompt >"$tmp/xctrace.log" 2>&1 &
recorder=$!
set +m
for _ in $(seq 60); do
    grep -qi 'ctrl-c' "$tmp/xctrace.log" && break
    kill -0 "$recorder" 2>/dev/null || { cat "$tmp/xctrace.log" >&2; echo "ABORT: xctrace quit" >&2; exit 1; }
    sleep 0.5
done
grep -qi 'ctrl-c' "$tmp/xctrace.log" || { cat "$tmp/xctrace.log" >&2; echo "ABORT: xctrace did not start" >&2; exit 1; }
sleep 2

# Each wintool call takes about a second; a leg ends with the first call that starts after its time is up.
start=$(now)
for direction in 1 -1; do
    end=$((SECONDS + seconds))
    while [ "$SECONDS" -lt "$end" ]; do
        guard
        if [ "$input" = wheel ]; then
            ac_tool wintool scroll "$x" "$y" "$((lines * direction))" 60 16
        else
            ac_tool wintool gesture "$x" "$y" "$((points * direction))" 120 8
        fi
    done
done
scrolled=$(python3 -c "print(round($(now) - $start, 2))")
sleep 1
kill -INT "$recorder"
wait "$recorder" || true
recorder=
[ -e "$out" ] || { cat "$tmp/xctrace.log" >&2; echo "ABORT: xctrace saved no trace" >&2; exit 1; }
echo "Saved $out; scrolled for $scrolled s"
python3 scripts/trace_summary.py "$out" "$scrolled"
