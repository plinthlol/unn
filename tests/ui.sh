#!/bin/sh
# runs tests/scripts/*.rsc headless and compares the output with tests/data/<name>.ui.expected.
# Run plain as a gate, or tests/ui.sh update to regenerate the expected files after a
# deliberate output change. Every script runs in its own sandbox: XDG config/state dirs a
# level below one fresh temp HOME, a compose table (XCOMPOSEFILE) and cursor theme/paths
# from tests/data, a fixed SHELL and PS1; each run gets limit()'d. @HOME@ inside a .rsc is
# rewritten to the sandbox (see the sed) before unn reads it.
cd "$(dirname "$0")/.."
fail=0
tmp=$(mktemp -d)
# timeout(1) is not everywhere: fall back to a perl alarm wrapper with the same args
limit() { # seconds cmd...
    if command -v timeout >/dev/null; then timeout "$@"; else perl -e 'alarm shift; exec @ARGV' "$@"; fi
}
shell=/bin/sh
home=$tmp
for s in tests/scripts/*.rsc; do
    n=$(basename "$s" .rsc)
    sed "s|@HOME@|$home|g" "$s" > "$tmp/$n.rsc"
    status=0
    XDG_CONFIG_HOME=$tmp/config-$n XDG_STATE_HOME=$tmp/state-$n HOME=$home XCOMPOSEFILE=$PWD/tests/data/compose.txt XCURSOR_PATH=tests/data/icons XCURSOR_THEME=child SHELL=$shell PS1='$ ' \
        limit 20 build/unn --headless 1400x860 --script "$tmp/$n.rsc" > "$tmp/$n.out" 2>&1 || status=$?
    # a run that did not exit 0 tells its own story nowhere else: show the exit status
    # and skip the bytewise compare, which would only bark about a wrong tail of output
    if [ "$status" != 0 ]; then
        echo "FAIL ui/$n (exit $status)"; fail=1
        continue
    fi
    if [ "$1" = update ]; then
        cp "$tmp/$n.out" "tests/data/$n.ui.expected"
    fi
    if cmp -s "$tmp/$n.out" "tests/data/$n.ui.expected"; then
        echo "ok   ui/$n"
    else
        echo "FAIL ui/$n"; diff "tests/data/$n.ui.expected" "$tmp/$n.out" | head -20; fail=1
    fi
done
rm -rf "$tmp"
exit $fail
