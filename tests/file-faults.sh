#!/bin/sh
# Failed saves must retain the old file, and EINTR must retry. Linux: strace injection.
# Needs strace whose syscall observation works (--trace=read) and then perturbs it
# (--inject, each fault at the first occurrence of that call). When the first observation
# shows nothing, this is not an strace that can do the job: exit 77, which tests/run.sh
# treats as a skip. Three scenarios, on one file at a time:
#   - a save that hits one hard fault (ENOSPC/EIO/EACCES/EPERM) must fail with status 1,
#     leave the original bytes on disk and leave no .unn-*.tmp behind;
#   - a save whose write or fsync merely gets EINTR must retry, ending up as 'saved';
#   - on load, faults in read or fstat make the file_test error mode report 5 (EIO's
#     errno) instead of pretending the read went through.
set -eu
cd "$(dirname "$0")/.."
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT HUP INT TERM
printf 'original\n' > "$work/original"
printf 'saved\n' > "$work/saved"
command -v strace >/dev/null
# first make sure the strace can even see syscalls, else skip rather than false-fail
strace -qq -o "$work/trace" -e trace=read build/file_test load "$work/original" > /dev/null
if ! grep -q 'read(' "$work/trace"; then
    echo 'SKIP file-faults: strace cannot observe syscalls'
    exit 77
fi
inject() {
    call=$1; error=$2; shift 2
    # when=1 fails the very first occurrence of the call with that errno
    strace -qq -o "$work/trace" -e "inject=$call:error=$error:when=1" "$@"
}
# one fault kind per round: the save must bail out with 1 and keep the original intact
for fault in write:ENOSPC fsync:ENOSPC close:EIO rename:EACCES fchmod:EPERM; do
    cp "$work/original" "$work/file"
    status=0
    inject "${fault%:*}" "${fault#*:}" build/file_test write "$work/file" || status=$?
    if [ "$status" != 1 ]; then
        echo "FAIL file-faults/$fault: expected exit 1, got $status"; exit 1
    fi
    cmp "$work/file" "$work/original"
    for f in "$work"/.unn-*.tmp; do
        if [ -e "$f" ]; then echo "FAIL file-faults/$fault: temporary file remains"; exit 1; fi
    done
done
# the retry side: an EINTR is not fatal, a fresh save attempt is allowed and succeeds
for call in write fsync; do
    inject "$call" EINTR build/file_test write "$work/file"
    cmp "$work/file" "$work/saved"
done
# the load side: read/fstat faults surface as the error number they are (5 = EIO)
for call in read fstat; do
    inject "$call" EIO build/file_test error "$work/file" > "$work/out" 2>&1
    [ "$(cat "$work/out")" = 5 ]
done
echo 'ok   file-faults'
