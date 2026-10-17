#!/bin/sh
# Builds unn and (with "test") the test binaries out of the assembly under src/ and tests/.
# Everything is assembled with GNU as and linked statically -nostdlib: unn is freestanding
# x86-64 with no libc; the terminal core comes from the vendored libghostty-vt.a archive.
#
# usage: ./build.sh [release|test]
#   (no arg)  debug build: build/unn, -g so the debugger has line info
#   release   the same, stripped (-s), for tools/install.sh
#   test      also links each tests/*.s with the app's objects (every file but
#             src_main.o, whose main the test replaces with its own) into
#             build/<name>, which tests/run.sh then drives
#
# Rebuilds are incremental; nothing is installed or run here.
set -e
cd "$(dirname "$0")"
mkdir -p build/obj
ASFLAGS="--64 -I src -I build"
[ "$1" = release ] || ASFLAGS="$ASFLAGS -g"
# build/assets.s .incbin-embeds the runtime files. Regenerate only when its content actually
# changed: a no-op generation leaves the file (and its cached object) alone, since the
# generator always rewrites fresh bytes that would otherwise look stale by mtime alone.
tools/gen-assets.sh > build/assets.s.new
cmp -s build/assets.s.new build/assets.s || { mv build/assets.s.new build/assets.s; rm -f build/obj/build_assets.o; }
objs=""
for s in $(find src -name "*.s" | LC_ALL=C sort) build/assets.s; do
    o=build/obj/$(echo "$s" | sed 's|/|_|g; s|\.s$|.o|')
    stale=
    # assets.s only names the embedded files; their contents count too
    [ "$s" = build/assets.s ] && [ -f "$o" ] && [ -n "$(find runtime assets/fonts -newer "$o" -print -quit)" ] && stale=1
    # unn.inc is .included by every source, so touching it re-assembles all of them
    if [ -n "$stale" ] || [ ! -f "$o" ] || [ "$s" -nt "$o" ] || [ src/unn.inc -nt "$o" ]; then
        as $ASFLAGS -o "$o" "$s"
    fi
    objs="$objs $o"
done
LDFLAGS="-static -nostdlib --no-dynamic-linker -z noexecstack"
[ "$1" = release ] && LDFLAGS="$LDFLAGS -s"
# libghostty-vt is the terminal core now, so every binary that pulls term.o
# (the app and each test) links the vendored archive
VTLIB=third_party/ghostty/libghostty-vt.a
ld $LDFLAGS -o build/unn $objs $VTLIB
if [ "$1" = test ]; then
    # every app object but src_main.o: the test brings its own entry point
    lib=$(echo $objs | tr ' ' '\n' | grep -v 'src_main.o')
    for t in tests/*.s; do
        n=$(basename "$t" .s)
        as $ASFLAGS -o "build/obj/test_$n.o" "$t"
        ld $LDFLAGS -o "build/$n" "build/obj/test_$n.o" $lib $VTLIB
    done
fi
