#!/bin/sh
# Emits build/assets.s on stdout, the assembly that .incbin-embeds the runtime's read-only
# data into the binary: the interface font, the version string and every runtime/themes file.
# build.sh runs it above; to regenerate by hand:
#   tools/gen-assets.sh > build/assets.s
# Inputs: VERSION, assets/fonts and runtime/themes; the file names become globls of the same
# name with a _end label after each blob. UNN_DIST=1 in the environment sets unn_dist to 1.
# Deleting runtime/themes files only removes their rows from themes_table.
cd "$(dirname "$0")/.."
# emit LABEL FILE: one .incbin of the file's bytes between LABEL and LABEL_end plus a
# trailing NUL; the path is made absolute ($PWD) because `as` resolves .incbin against its
# own working directory, not the source's directory.
emit() { # label file
    printf '.globl %s, %s_end\n.p2align 4\n%s: .incbin "%s"\n%s_end: .byte 0\n' "$1" "$1" "$1" "$PWD/$2" "$1"
}
echo '.section .rodata'
# UNN_DIST=1 marks a distribution build in the binary's unn_dist flag (0 otherwise)
dist=0
[ "${UNN_DIST:-}" = 1 ] && dist=1
printf '.globl unn_version, unn_dist\nunn_version: .asciz "%s"\n.p2align 2\nunn_dist: .long %d\n' "$(cat VERSION)" "$dist"
# one font for the interface and the terminal
emit font_mono assets/fonts/IosevkaFixed-Regular.ttf
# font_ui is an alias of the same blob: one memory copy serves both, just two symbols
printf '.globl font_ui, font_ui_end\n.set font_ui, font_mono\n.set font_ui_end, font_mono_end\n'
# name table of runtime theme files: (name ptr, data ptr, data end); sorted in the C locale
# so the generated order is deterministic
list=$(ls runtime/themes 2>/dev/null | LC_ALL=C sort)
i=0
for f in $list; do
    emit "themes_$i" "runtime/themes/$f"
    printf 'themes_%d_name: .asciz "%s"\n' $i "$f"
    i=$((i+1))
done
printf '.p2align 3\n.globl themes_table, themes_count\nthemes_count: .quad %d\nthemes_table:\n' $i
# themes_table is one (name, data, end) triple per theme file; the trailing all-zero row
# marks the end of the table
j=0
while [ $j -lt $i ]; do
    printf '.quad themes_%d_name, themes_%d, themes_%d_end\n' $j $j $j
    j=$((j+1))
done
printf '.quad 0, 0, 0\n'
