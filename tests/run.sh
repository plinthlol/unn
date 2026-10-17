#!/bin/sh
# The whole gate: builds (./build.sh test), then runs the checks. Currently 18 of them:
#   - 13 golden ones, each a check() below: the command must exit 0 and its combined
#     stdout+stderr must be byte-identical to tests/data/<name>.expected;
#   - the --version check against build/unn;
#   - the four script probes: three Python unittests plus tests/detach.sh.
# On top of those, tests/file-faults.sh runs when strace is installed; the script probes
# its own syscall observation and exits 77 when it fails, which counts as a clean skip.
# tests/ui.sh runs when it is executable.
# usage: tests/run.sh    (from anywhere, needs the tree; exit status tells the gate)
cd "$(dirname "$0")/.."
./build.sh test || exit 1
fail=0
tmp=$(mktemp) || exit 1
trap 'rm -f "$tmp"' EXIT HUP INT TERM
check() { # name cmd...
    # pass = exit 0 AND byte-identical combined output vs tests/data/<name>.expected:
    # any message change, however small, breaks the golden and fails the check
    name=$1; shift
    if "$@" > "$tmp" 2>&1 && cmp -s "$tmp" "tests/data/$name.expected"; then
        echo "ok   $name"
    else
        echo "FAIL $name"; fail=1
    fi
}
check keymap-names-us-ru build/xkb_test tests/data/keymap-names-us-ru.txt
check keymap-gnome-us build/xkb_test tests/data/keymap-gnome-us.txt
check keymap-pl-intl build/xkb_test tests/data/keymap-pl-intl.txt
check keys build/keys_test
check ui-clip build/ui_clip_test
check fill build/fill_test
check memmove build/memmove_test
check term build/term_test
check vt build/vt_test
check cpu build/cpu_test
check strfind build/str_test tests/data/strfind.txt
check paths build/path_test tests/data/paths.txt
check themes build/theme_test
# the Python probes print their own ok/FAIL lines; only their exit status gates here
if [ "$(build/unn --version)" = "unn $(cat VERSION)" ]; then echo "ok   version"; else echo "FAIL version"; fail=1; fi
python3 tests/terminal-panel.py || fail=1
python3 tests/shift-wheel.py || fail=1
python3 tests/terminal-keys.py || fail=1
sh tests/detach.sh || fail=1
# side suites: the fault-injection one only when strace is installed at all (its own
# observation probe may fail and skip with 77, which does not fail the gate). tests/ui.sh runs
# the headless .rsc scripts, as long as that file is executable.
if command -v strace >/dev/null; then
    status=0
    sh tests/file-faults.sh || status=$?
    [ "$status" = 0 ] || [ "$status" = 77 ] || fail=1
fi
[ -x tests/ui.sh ] && { tests/ui.sh || fail=1; }
exit $fail
