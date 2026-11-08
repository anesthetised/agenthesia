#!/bin/bash
# Regenerates the README screenshots, docs/images/agenthesia-light.png and docs/images/agenthesia-dark.png: a demo
# session in a test copy of the app (its own bundle identifier, a temporary home), with MockAgent playing the canned
# turn built from this directory (`before/` is the project, `after/` the files the agent writes, `answer.md` its
# reply). Each window is captured with its shadow on a transparent background.
#
# It drives the app through scripts/app-check/lib.sh, so leave the machine alone while it runs (about a minute);
# it aborts when another app comes to the front. Run it with `just screenshots`.
set -euo pipefail

cd "$(dirname "$0")/../.."
here=$PWD/scripts/readme-screenshot
derived=.build/xcode-screenshot
app=$derived/Build/Products/Debug/Agenthesia.app
prompt="Add status filters to the task list. Keep the UI native and the filtering logic easy to test."

xcodebuild -project Agenthesia.xcodeproj -scheme Agenthesia -configuration Debug -destination 'platform=macOS' \
    -derivedDataPath "$derived" -skipPackagePluginValidation -quiet \
    PRODUCT_BUNDLE_IDENTIFIER=io.github.anesthetised.Agenthesia.screenshot build
swift build --package-path Packages/AgenthesiaKit --product MockAgent
mock="$(swift build --package-path Packages/AgenthesiaKit --show-bin-path)/MockAgent"

# A short path: the window shows the session's worktree.
tmp=$(mktemp -d /tmp/agh.XXXXXX)
pid=
pbpaste >"$tmp/clipboard"   # lib.sh pastes through the clipboard
cleanup() {
    local status=$?
    if [ "$status" -ne 0 ] && [ -n "$pid" ]; then
        screencapture -x -l "$(wid)" .build/readme-screenshot-failure.png && echo "see .build/readme-screenshot-failure.png"
    fi
    [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
    pbcopy <"$tmp/clipboard"
    rm -rf "$tmp"
}
trap cleanup EXIT

# The canned turn: read the list, rewrite it, add two files, run the tests, answer. `{cwd}` is the worktree.
python3 - "$here" >"$tmp/demo.json" <<'EOF'
import json, pathlib, sys

here = pathlib.Path(sys.argv[1])
read = lambda path: path.read_text() if path.exists() else None
files = {str(p.relative_to(here / "after")): p.read_text() for p in sorted((here / "after").rglob("*")) if p.is_file()}

def edit(path, title):
    return {"sessionUpdate": "tool_call", "toolCallId": path, "title": title, "kind": "edit", "status": "completed",
            "content": [{"type": "diff", "path": "{cwd}/" + path, "oldText": read(here / "before" / path),
                         "newText": files[path]}],
            "locations": [{"path": "{cwd}/" + path}]}

updates = [
    {"sessionUpdate": "tool_call", "toolCallId": "read", "title": "Read Sources/Orbit/TaskList.swift",
     "kind": "read", "status": "completed", "locations": [{"path": "{cwd}/Sources/Orbit/TaskList.swift"}]},
    edit("Sources/Orbit/TaskStatus.swift", "Add TaskStatus"),
    edit("Sources/Orbit/TaskList.swift", "Filter the list by status"),
    edit("Tests/OrbitTests/TaskStatusTests.swift", "Test the filters"),
    {"sessionUpdate": "tool_call", "toolCallId": "test", "title": "swift test", "kind": "execute",
     "status": "completed",
     "content": [{"type": "content", "content": {"type": "text", "text": "✔ Test run with 1 test passed."}}]},
    {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": (here / "answer.md").read_text()}},
]
json.dump({"files": files, "updates": updates}, sys.stdout, ensure_ascii=False, indent=1)
EOF

. scripts/app-check/lib.sh
export APP_CHECK_SHOTS=$tmp

# at <description prefix> [seconds]: "x y", the top left corner of the first accessible element so described, waiting
# up to the given time for it (default 5 s).
at() {
    local tries=$((${2:-5} * 2)) line
    while [ "$tries" -gt 0 ]; do
        line=$(ac_tool axlabels "$APP_CHECK_PID" | grep -m1 -F " d=$1") && break
        tries=$((tries - 1))
        sleep 0.5
    done
    [ -n "$line" ] || { echo "ABORT: no element described as \"$1\"" >&2; exit 1; }
    echo "$line" | sed -E 's/^[^@]*@([0-9-]+),([0-9-]+).*/\1 \2/'
}

# shoot <light|dark> <appearance flags…>: one session in a fresh home, saved to docs/images/agenthesia-<name>.png.
shoot() {
    local name=$1 home=$tmp/$1
    shift
    mkdir -p "$home"
    cp -R "$here/before" "$home/Orbit"
    git -C "$home/Orbit" init -q
    git -C "$home/Orbit" add .
    GIT_AUTHOR_DATE=2026-01-01T12:00:00Z GIT_COMMITTER_DATE=2026-01-01T12:00:00Z \
        git -C "$home/Orbit" -c user.name=Demo -c user.email=demo@example.com commit -q -m "Show the task list"
    # The Agent chip shows the executable's name.
    printf '#!/bin/sh\nexec "%s" --effort --demo "%s"\n' "$mock" "$tmp/demo.json" >"$home/Demo Agent"
    chmod +x "$home/Demo Agent"
    export APP_CHECK_REPO="$home/Orbit" APP_CHECK_AGENT="$home/Demo Agent"

    CFFIXED_USER_HOME=$home "$app/Contents/MacOS/Agenthesia" "$@" &
    pid=$!
    export APP_CHECK_PID=$pid
    sleep 3
    guard
    ax 'set position of window 1 to {120, 80}' >/dev/null
    ax 'set size of window 1 to {1480, 860}' >/dev/null
    pickproject
    pickagent
    draftsend "$prompt"
    # Open the rewritten file from the inspector's changes and give the file pane its longest line.
    local point
    point=$(at "Sources/Orbit/TaskList.swift, " 20)
    set -- $point
    guard
    ac_tool wintool click "$(($1 + 12))" "$(($2 + 8))"
    sleep 1.5
    point=$(at "Resize pane")   # the file pane's leading edge comes first
    set -- $point
    guard
    ac_tool wintool drag "$(($1 + 3))" 500 "$(($1 - 60))" 500
    ac_tool wintool move 1650 500   # beside the window, so nothing shows a hover
    sleep 1
    screencapture -x -l "$(wid)" "docs/images/agenthesia-$name.png"
    kill "$pid"
    wait "$pid" 2>/dev/null || true
    pid=
    echo "docs/images/agenthesia-$name.png"
}

shoot light -NSRequiresAquaSystemAppearance YES
shoot dark -AppleInterfaceStyle Dark
