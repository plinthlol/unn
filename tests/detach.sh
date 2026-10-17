#!/bin/sh
# Started from a terminal, unn goes on as a copy of its own and the terminal gets its prompt back;
# --wait stays, and so does a start without a display, so its error is seen.
# Needs Linux with script(1) to hand unn a real terminal. Three starts, each with its own
# throwaway HOME/XDG tree and every display socket variable stripped:
#   nodisplay  no display at all: unn stays on the terminal and its "no Wayland" error is
#              there for the check to read
#   display    a WAYLAND_DISPLAY that does not exist, without --wait: unn detaches at once,
#              so the terminal is free and the failed copy's output is seen by nobody
#   wait       the same start with --wait: unn stays in the foreground, so the error is visible
set -u
cd "$(dirname "$0")/.."
if [ "$(uname -s)" != Linux ] || ! command -v script >/dev/null 2>&1; then
    echo "skip detach (Linux with script(1) only)"
    exit 0
fi
w=$(mktemp -d)
trap 'rm -rf "$w"' EXIT HUP INT TERM
fail=0
# run NAME UNN-ARGS ENV...: unn on a terminal (script(1)) with its own HOME and the variables
# ENV; output in $w/NAME, status in $st. The -u DISPLAY -u WAYLAND_DISPLAY at the head
# guarantees unn never sees a real socket; the one in ENV is set on top for the last two runs.
run() {
    n=$1 args=$2
    shift 2
    st=0
    env -u DISPLAY -u WAYLAND_DISPLAY HOME="$w" XDG_CONFIG_HOME="$w/c" XDG_STATE_HOME="$w/s" \
        XDG_RUNTIME_DIR="$w" "$@" script -qec "build/unn $args $w" /dev/null > "$w/$n" 2>&1 || st=$?
}
check() { # NAME WHAT CMD...
    n=$1 what=$2
    shift 2
    if "$@"; then echo "ok   detach/$n"; else echo "FAIL detach/$n: $what"; sed 's/^/    | /' "$w/$n"; fail=1; fi
}
run nodisplay ''
check nodisplay "stays and says there is no display" grep -q 'no Wayland' "$w/nodisplay"
# a display that is not there: the copy fails where no one sees it, and the terminal is free at once
run display '' WAYLAND_DISPLAY=nowhere-0
check display "the terminal gets its prompt back" sh -c "[ $st = 0 ] && [ ! -s '$w/display' ]"
# --wait stays, so there the same start fails where it can be seen
run wait --wait WAYLAND_DISPLAY=nowhere-0
check wait "stays until unn ends" grep -q 'no Wayland' "$w/wait"
exit $fail
