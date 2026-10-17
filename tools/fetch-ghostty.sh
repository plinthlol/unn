#!/bin/sh
# rebuild third_party/ghostty/libghostty-vt.a from a pinned ghostty commit.
# requires zig 0.16.0 on PATH (or point ZIG at the binary). no other deps.
#
# why these flags:
#   -Dtarget=x86_64-linux-none   freestanding ABI, no libc at all (unn is
#                                -nostdlib; the lib gets memory from the
#                                allocator vtable in src/vtglue.s instead)
#   -Demit-lib-vt                the C API for the vt core only (parser,
#                                state, replies, formatter): no threading,
#                                no io engine, no renderer
#   -Dapp-runtime=none           likewise, no app runtime dependency
#   -Dcpu=baseline               portable codegen for the archive
#   -Dsimd=false                 drops the simdutf/highway system deps
#   -Doptimize=ReleaseFast       audit log: baseline+ReleaseFast kept fully
#                                static (zero undefined symbols in the
#                                linked test binary, see tests/vt_test.s)
#
# inputs: the pin on the "Pin: <commit>" line of third_party/ghostty/COMMIT. side effects:
# clones upstream into a throwaway mktemp dir (needs network) and overwrites the vendored
# libghostty-vt.a and the headers under third_party/ghostty/ghostty/.
set -e
cd "$(dirname "$0")/.."

COMMIT=$(sed -n 's/^Pin: //p' third_party/ghostty/COMMIT | awk '{print $1}')
ZIG=${ZIG:-zig}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

git clone https://github.com/ghostty-org/ghostty.git "$work/ghostty"
cd "$work/ghostty"
git checkout "$COMMIT"

$ZIG build -Demit-lib-vt -Dapp-runtime=none -Dcpu=baseline \
    -Doptimize=ReleaseFast -Dsimd=false -Dtarget=x86_64-linux-none

cd ../..
cp "$work/ghostty/zig-out/lib/libghostty-vt.a" third_party/ghostty/
rm -rf third_party/ghostty/ghostty && mkdir third_party/ghostty/ghostty
cp -r "$work/ghostty/include/ghostty" third_party/ghostty/
echo "vendored libghostty-vt.a from $COMMIT" | sed "s/^/done: /"
