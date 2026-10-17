# compiled-in settings: unn has no config file, so every tunable lives here as
# a plain .data value and changing one means editing this file and rebuilding.
# Values that are ratios use hundredths (1 = 0.01) so they stay integer.
# Multipliers referenced: app_on_scroll weighs scroll speed with
# cfg_scroll_sens, or cfg_fast_sens (4x) while Alt is held; the term_* ones
# weigh term_metrics and term_spawn (termview.s), the ui/font size ones weigh
# the base UI code. Nothing reads cfg_font/cfg_ui_font/cfg_term_font —
# app_load_fonts (app.s) hard-wires the built-in Iosevka for code and UI —
# but the slots keep their intended meanings. .Lempty is the shared empty
# string every cstr default points to.
.include "unn.inc"

.data
.p2align 2
.globl cfg_scroll_sens, cfg_fast_sens
cfg_scroll_sens: .long 100        # scroll speed multiplier in hundredths: 1.0x
cfg_fast_sens: .long 400          # the multiplier while Alt is held: 4.0x

.globl cfg_term_font_size, cfg_term_scrollback, cfg_term_shell
.globl cfg_term_line_height, cfg_term_font, cfg_font, cfg_ui_font
cfg_term_font_size: .long 18      # point size zoom resets to (range 8..40)
cfg_term_line_height: .long 100   # line height in hundredths of ascent+descent
cfg_term_scrollback: .long 10000  # scrollback lines a new terminal gets (TM_sbcap)
.p2align 3
cfg_font: .quad .Lempty           # code font, a monospace .ttf, empty = built-in Iosevka
cfg_ui_font: .quad .Lempty        # UI font, empty = the code font
cfg_term_shell: .quad .Lempty     # the shell to spawn, empty = $SHELL then /bin/sh
cfg_term_font: .quad .Lempty      # the terminal's own font, empty = the code font

.globl cfg_ui_scale, cfg_ui_font_size, cfg_font_size, cfg_line_height, cfg_autohide_scrollbars
.globl cfg_decorations
cfg_ui_scale: .long 100           # interface zoom in hundredths over the display scale
cfg_ui_font_size: .long 13        # points of the UI font
cfg_font_size: .long 14           # points the code font metrics were made for
cfg_line_height: .long 150        # line height in hundredths of the code font size
cfg_autohide_scrollbars: .long 1  # show scrollbars only while scrolling or under the pointer
cfg_decorations: .long 0          # 0 auto, 1 unn draws a title bar, 2 the desktop does

.Lempty: .asciz ""
