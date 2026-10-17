# application shell for the terminal-only build: exactly one fullscreen terminal,
# nothing else. app_init loads the embedded theme, fonts and key bindings. The
# app_on_* functions are the platform's callbacks (key, mouse, scroll, focus,
# paste, resize) and app_timeout/app_tick/app_render are the event loop's hooks.
# Every callback funnels into termview.s, which owns the sessions and the TERM.
# The terminal keeps the keyboard: app_on_key feeds dead keys and Compose first,
# then term_panel_key, and only keys the terminal rejected reach the remaining
# app commands (zoom, quit).
.include "unn.inc"

.bss
.p2align 3
.globl g_focus, g_win_focused
g_focus: .long 0
g_win_focused: .long 0
.globl g_project
g_project: .quad 0
.globl g_start_paths
g_start_paths: .zero VEC_SIZE
.globl g_wait
g_wait: .long 0                  # --wait: no detach, the program that started
                                 # unn waits for this window
.globl g_mods
g_mods: .long 0                  # mods of the last key event
.globl g_scroll_mods
g_scroll_mods: .long 0           # mods of the last scroll event
.globl g_toast, g_toast_until
g_toast: .zero 256
g_toast_until: .quad 0
.globl g_shot_path
g_shot_path: .quad 0
link_path: .zero 4096
scroll_rem: .long 0, 0           # what scroll sensitivity left of a pixel, x and y, in hundredths

.text

# ---------------- init ----------------

# app_init(): one-time startup. Loads row 0 of themes_table (each row is
# (name ptr, data ptr, end ptr) — here the single embedded theme), then the
# built-in font and the compiled-in [keys] bindings. Editor-era subsystems
# (syntax grammars, vim mode, watchers, updater) are deliberately not started.
FN app_init
    PROLOGUE 16
    mov rdi, [rip + themes_table + 8]      # themes_table row 0: (name, data, end)
    mov rsi, [rip + themes_table + 16]
    sub rsi, rdi
    call theme_load
    call app_load_fonts
    call keys_init
    EPILOGUE

# app_load_fonts(): the one embedded JetBrainsMono Nerd Font (assets/fonts) serves everything:
# it is loaded once into g_font_code and g_font_ui, and g_font_term stays 0,
# the marker for termview.s' term_metrics to fall back to the code face.
FN app_load_fonts
    PROLOGUE
    lea rdi, [rip + font_mono]
    lea rsi, [rip + font_mono_end]
    sub rsi, rdi
    call font_load
    mov [rip + g_font_code], rax
    mov [rip + g_font_ui], rax
    mov qword ptr [rip + g_font_term], 0
    EPILOGUE

# ---------------- platform callbacks ----------------

# app_on_resize(): nothing to compute yet: app_render re-measures metrics and
# fonts at the top of every frame, so one dirty flag asks for it.
FN app_on_resize
    mov dword ptr [rip + g_dirty], 1
    ret

# app_on_motion(x, y): the pointer's new place, stored into the ui state
# (g_mx / g_my; ui_input_motion holds it back across a press, ui.s). A redraw
# follows for whatever hovering changes.
FN app_on_motion
    call ui_input_motion
    mov dword ptr [rip + g_dirty], 1
    ret

# app_on_pointer_leave(): the pointer left the window. (-10000, -10000) is
# where g_mx / g_my start, so nothing can be under it anymore; the redraw
# drops whatever was hovered.
FN app_on_pointer_leave
    mov edi, -10000
    mov esi, -10000
    call ui_input_motion
    mov dword ptr [rip + g_dirty], 1
    ret

# app_on_button(btn, pressed, mods): a mouse button. Mods are remembered in
# g_mods so delayed handlers (selection logic) still see them.
FN app_on_button
    mov [rip + g_mods], edx
    call ui_input_button
    mov dword ptr [rip + g_dirty], 1
    ret

# app_on_scroll(dx, dy, mods): fractional wheel deltas are scaled by
# cfg_scroll_sens (hundredths, 4x while Alt is held), accumulated in
# scroll_rem with the rounding remainder, and only reach the UI once at least
# one whole pixel has accumulated in x or y.
FN app_on_scroll
    mov [rip + g_scroll_mods], edx
    mov ecx, 100                   # scroll sensitivity: 1.0x in hundredths
    test edx, MOD_ALT
    jz 1f
    mov ecx, 400                   # 4.0x while alt is held
1:  imul edi, ecx
    add edi, [rip + scroll_rem]
    imul esi, ecx
    add esi, [rip + scroll_rem + 4]
    mov ecx, 100
    mov eax, edi
    cdq
    idiv ecx
    mov edi, eax
    mov [rip + scroll_rem], edx
    mov eax, esi
    cdq
    idiv ecx
    mov esi, eax
    mov [rip + scroll_rem + 4], edx
    # less than a pixel so far: nothing to draw
    mov eax, edi
    or eax, esi
    jz 2f
    call ui_input_scroll
    mov dword ptr [rip + g_dirty], 1
2:  ret

# app_on_focus(focused): window focus on or off, into g_win_focused. draw_grid
# (termview.s) draws the terminal's cursor as an outline while the window
# lacks it, so the repaint asks.
FN app_on_focus
    mov [rip + g_win_focused], edi
    mov dword ptr [rip + g_dirty], 1
    ret

# app_on_paste(ptr, len): the clipboard's text goes straight to the current
# terminal session (termview.s).
FN app_on_paste
    jmp term_panel_paste

# app_on_key(key, cp, mods) -> void: arg order is edi keysym, esi the layout's
# character as a codepoint (0 for pure function keys), edx MOD_* bits. Order
# matters: dead keys and the Compose key may swallow the key and emit their own,
# then the terminal gets it, then the app bindings. r12d holds the key, r13d
# the cp and r14d the mods across the three calls. The terminal is never left,
# nothing else exists to take the keyboard.
FN app_on_key
    PROLOGUE 16
    mov r12d, edi
    mov r13d, esi
    mov r14d, edx
    mov [rip + g_mods], edx
    mov dword ptr [rip + g_dirty], 1
    # dead keys and the Compose key
    mov edi, r12d
    mov esi, r14d
    call compose_key
    test eax, eax
    jnz 9f
    mov edi, r12d
    mov esi, r13d
    mov edx, r14d
    call term_panel_key
    test eax, eax
    jnz 9f
    # the [keys] bindings that remain (zoom in/out/reset, clear terminal) run
    # only on keys the terminal did not take
    mov edi, r12d
    mov esi, r14d
    call keys_lookup
    test rax, rax
    jz 9f
    call rax
9:  EPILOGUE

# app_on_close(): the window is going away — same as cmd_quit: every terminal
# session ends and the event loop stops.
FN app_on_close
    call term_close_all
    mov dword ptr [rip + g_quit], 1
    ret

# app_timeout() -> eax ms until the next app timer (output pacing in
# termview.s), or -1. Called by the event loop before polling.
FN app_timeout
    jmp term_timeout

FN app_tick
    jmp term_tick

# app_render(): the terminal is the whole window, no chrome at all. Frames in
# order: metrics, ui_begin, then the panel fills the window (or an empty
# background when no shell is running). A scripted shot, if g_shot_path names
# one, is written after the frame the command drew.
FN app_render
    PROLOGUE 16
    call ui_update_metrics
    call ui_begin
    cmp dword ptr [rip + g_term_open], 0
    je .Lr_term_empty
    xor edi, edi
    xor esi, esi
    mov edx, [rip + g_cv + CV_w]
    mov ecx, [rip + g_cv + CV_h]
    call term_panel_draw
    call ui_end
    # scripted screenshot
    mov rdi, [rip + g_shot_path]
    test rdi, rdi
    jz 9f
    mov qword ptr [rip + g_shot_path], 0
    call shot_write
9:  EPILOGUE
.Lr_term_empty:
    xor edi, edi
    xor esi, esi
    mov edx, [rip + g_cv + CV_w]
    mov ecx, [rip + g_cv + CV_h]
    COLOR r8d, T_BG
    call gfx_fill
    EPILOGUE

# ---------------- app services the terminal uses ----------------

# app_toast(text): a message the user should see. The editor's toast bar is gone; printing to the
# terminal would race the shell's output, so it is dropped rather than shown.
FN app_toast
    ret

# app_goto_line(line): the terminal does not scroll to a line on command
FN app_goto_line
    ret

# app_open_file(path): there is no editor to open a file into, so files a terminal link pointed
# at open with the system's default application (via desktop_open)
FN app_open_file
    jmp desktop_open

# ---------------- commands ----------------

# cmd_quit(): close every terminal, end the loop
FN cmd_quit
    call term_close_all
    mov dword ptr [rip + g_quit], 1
    ret

# cmd_zoom_in/out/reset: the terminal's font size via zoom_terminal.
# zoom_terminal esi: 1 in, -1 out, 0 reset to the default 14. Writes
# cfg_term_font_size, clamped to its 8..40 range, and marks the window dirty.
# term_metrics (termview.s) picks it up on the next draw.
FN cmd_zoom_in
    mov esi, 1
    jmp zoom_terminal

FN cmd_zoom_out
    mov esi, -1
    jmp zoom_terminal

FN cmd_zoom_reset
    xor esi, esi
    jmp zoom_terminal

zoom_terminal:                   # esi 1 in, -1 out, 0 reset
    lea rdi, [rip + cfg_term_font_size]
    mov eax, 14                  # the default size resets to
    test esi, esi
    jz 1f
    mov eax, [rdi]
    add eax, esi
    mov edx, 8                   # the setting's range is 8..40
    cmp eax, edx
    cmovl eax, edx
    mov edx, 40
    cmp eax, edx
    cmovg eax, edx
1:  mov [rdi], eax
    mov dword ptr [rip + g_dirty], 1
    ret

# app_open_path(arg): open with the system's default application; directories open in its
# file manager
FN app_open_path
    PROLOGUE 4200
    mov rbx, rdi
    lea rdi, [rsp]
    mov rsi, rbx
    mov edx, 4095
    call cstr_copy
    lea rdi, [rsp]
    call path_normalize
    lea rdi, [rsp]
    call desktop_open
    EPILOGUE
