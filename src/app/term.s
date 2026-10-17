# terminal emulator: libghostty-vt runs the escape sequences; this adapter
# mirrors the live viewport into unn's line/cell format so the renderer,
# selection and goldens keep reading plain cells.
#
# The GhosttyTerminal inside a TERM is the single source of truth. unn keeps
# geometry (cols/rows/cursor/scroll/mode state) and the LN lines of the
# visible viewport; vt_sync refreshes both whenever a reader arrives after a
# mutation (TM_gen != TM_sync). Lines that scrolled out live in the library's
# scrollback: while the view is scrolled up, the ring slots covered by the
# viewport are filled too.
#
# termview.s owns the sessions around this: it runs the shells and reaches
# the terminals only through the public term_* functions below, so a reader
# never sees a half-updated mirror. internal helpers take the
# terminal in rbx.
.include "unn.inc"

# ---- libghostty-vt enum values (third_party/ghostty/ghostty/vt) ----
# GhosttyTerminalData
.equ GD_ACTIVE_SCREEN, 6
.equ GD_SCROLLBAR, 9
.equ GD_TITLE, 12
.equ GD_MODE, 37
# GhosttyRenderStateData
.equ RD_ROW_ITERATOR, 4
.equ RD_CURSOR, 18
# GhosttyRenderStateRowData
.equ RW_RAW, 2
.equ RW_CELLS, 3
.equ RW_VIEWPORT_Y, 6
# GhosttyRenderStateRowCellsData
.equ RC_RAW, 1
.equ RC_STYLE, 2
# GhosttyCellData
.equ CD_CODEPOINT, 1
.equ CD_CONTENT_TAG, 2
.equ CD_WIDE, 3
.equ CD_HAS_STYLING, 5
.equ CD_COLOR_PALETTE, 10
.equ CD_COLOR_RGB, 11
# GhosttyRowData
.equ ROW_WRAP, 1
# GhosttyCellContentTag
.equ CT_CODEPOINT, 0
.equ CT_BG_PALETTE, 2
.equ CT_BG_RGB, 3
# GhosttyCellWide
.equ CW_NARROW, 0
.equ CW_WIDE, 1
.equ CW_SPACER_TAIL, 2
.equ CW_SPACER_HEAD, 3
# GhosttyPoint tags (point.h) and GhosttyGridRef (grid_ref.h)
.equ PT_HISTORY, 3
.equ GRIDREF_SIZE, 24
# GhosttyStyle layout (style.h): size@0, fg@8 (tag@8, value@16),
# bg@24 (tag@24, value@32), underline_color@40; flags bold..overline @56..63;
# underline (c_int) @64
.equ ST_SIZE, 72
.equ ST_FG, 8
.equ ST_BG, 24
.equ STC_NONE, 0
.equ STC_PALETTE, 1
.equ STC_RGB, 2
.equ ST_BOLD, 56
.equ ST_ITALIC, 57
.equ ST_FAINT, 58
.equ ST_BLINK, 59
.equ ST_INVERSE, 60
.equ ST_INVISIBLE, 61
.equ ST_STRIKE, 62
.equ ST_UNDERLINE, 64
# GhosttyRenderStateCursor layout: size@0, viewport_has_value@8, x@10, y@12,
# wide_tail@14, visible@15, blinking@16, password_input@17, visual_style@20
.equ RSC_SIZE, 24
.equ RSC_HAS_VALUE, 8
.equ RSC_X, 10
.equ RSC_Y, 12
.equ RSC_VISIBLE, 15
.equ RSC_BLINKING, 16
.equ RSC_STYLE, 20
.equ CU_BAR, 0
.equ CU_BLOCK, 1
.equ CU_UNDERLINE, 2
.equ CU_HOLLOW, 3
# GhosttyTerminalScrollViewportTag
.equ SC_BOTTOM, 1
.equ SC_DELTA, 2
.equ SC_ROW, 3
# GhosttyTerminalOption
.equ OPT_USERDATA, 0
.equ OPT_WRITE_PTY, 1
.equ OPT_COLOR_FOREGROUND, 11
.equ OPT_COLOR_BACKGROUND, 12
.equ OPT_COLOR_CURSOR, 13
.equ OPT_SCROLLBACK_MAX_LINES, 28
# GhosttyMode packing: low 15 bits the value, bit 15 the ANSI flag
.equ MM_ANSI, 0x8000

.bss
.p2align 2
# the unshifted character of the key being handled, set by a platform around
# its key event (0 when it has none): the kitty keyboard protocol names a key
# by it, Ctrl+Shift+2 as 2 with Shift
.globl g_key_base
g_key_base: .long 0

# cell_get_multi keys for the row readers: one ghostty_cell_get_multi asks
# for content tag, codepoint, wide property and has_styling together; the
# answers land at the DL_* offsets each caller builds pointers for
.section .rodata
.p2align 2
vt_cell_keys:
    .long CD_CONTENT_TAG, CD_CODEPOINT, CD_WIDE, CD_HAS_STYLING
.p2align 2
# the same GD_MODE asked once per query; the answers rewrite the vt_modespec
# mode-config entries in place (mode in, then the bool value at +2)
vt_modekeys:
    .long GD_MODE, GD_MODE, GD_MODE, GD_MODE, GD_MODE, GD_MODE, GD_MODE
    .long GD_MODE, GD_MODE, GD_MODE, GD_MODE, GD_MODE, GD_MODE
.text

# CELLP out, line, col: the address of the col-th cell (12 bytes each) of
# the line pointer, past the line's 8-byte header
.macro CELLP out, line, col
    lea \out, [\col + \col*2]
    lea \out, [\line + \out*4 + LN_HDR]
.endm

# the mode queries, one GhosttyTerminalModeConfig each
# (u16 mode, bool value): the u16 mode goes in, vt_sync reads the bool
# back at +2
.equ VM_WRAP, 0
.equ VM_APPCUR, 4
.equ VM_HIDE, 8
.equ VM_INSERT, 12
.equ VM_PASTE, 16
.equ VM_SGRMOUSE, 20
.equ VM_FOCUS, 24
.equ VM_ORIGIN, 28
.equ VM_LNM, 32
.equ VM_SYNC, 36
.equ VM_MOUSE1, 40
.equ VM_MOUSE2, 44
.equ VM_MOUSE3, 48
.equ VM_COUNT, 13

.section .data
.p2align 3
vt_modespec:
    .long 7                     # wraparound (DEC 7)
    .long 1                     # cursor keys (DEC 1)
    .long 25                    # cursor visible (DEC 25)
    .long 4 | MM_ANSI           # insert (ANSI 4)
    .long 2004                  # bracketed paste
    .long 1006                  # SGR mouse
    .long 1004                  # focus events
    .long 6                     # origin
    .long 20 | MM_ANSI          # linefeed/newline (ANSI 20)
    .long 2026                  # synchronized output
    .long 1000                  # mouse: normal tracking
    .long 1002                  # mouse: button-event tracking
    .long 1003                  # mouse: any-event tracking
vt_modevals:
    .quad vt_modespec + 0,  vt_modespec + 4,  vt_modespec + 8
    .quad vt_modespec + 12, vt_modespec + 16, vt_modespec + 20
    .quad vt_modespec + 24, vt_modespec + 28, vt_modespec + 32
    .quad vt_modespec + 36, vt_modespec + 40, vt_modespec + 44
    .quad vt_modespec + 48

.text

# ---------------- setup ----------------

# vt_default_colors(rbx=TERM): hand the library unn's text, background
# and cursor colours as its defaults, so it can answer the program's
# OSC 10/11/12 queries from them. Theme slots are 0xAARRGGBB; the
# library wants a GhosttyColorRgb { r, g, b }. Call it again when the
# theme changes.
.globl vt_default_colors
vt_default_colors:
    PROLOGUE_ALIGNED 16
    xor r12d, r12d
1:  cmp r12d, 3
    jae 9f
    lea rcx, [rip + vt_col_slots]
    mov eax, [rcx + r12*4]
    lea rcx, [rip + g_theme]
    mov edx, [rcx + rax*4]
    mov eax, edx
    shr eax, 16
    mov [rsp], al               # r
    mov eax, edx
    shr eax, 8
    mov [rsp + 1], al           # g
    mov [rsp + 2], dl           # b
    lea rcx, [rip + vt_col_opts]
    mov esi, [rcx + r12*4]
    mov rdi, [rbx + TM_gt]
    mov rdx, rsp
    call ghostty_terminal_set
    inc r12d
    jmp 1b
9:  EPILOGUE

.section .rodata
.p2align 2
vt_col_opts: .long OPT_COLOR_FOREGROUND, OPT_COLOR_BACKGROUND, OPT_COLOR_CURSOR
vt_col_slots: .long T_FG, T_BG, T_CURSOR
.text

# term_new(cols, rows, scrollback lines) -> TERM*
FN term_new
    PROLOGUE_ALIGNED
    mov r12d, edi               # cols
    mov r13d, esi               # rows
    mov r14d, edx               # sbcap
    # the library wants a nonzero grid; unn clamps to at least 2x1
    cmp r12d, 2
    jge 1f
    mov r12d, 2
1:  cmp r13d, 1
    jge 2f
    mov r13d, 1
2:  mov edi, TM_SIZE
    call mem_alloc
    mov rbx, rax
    mov [rbx + TM_cols], r12d
    mov [rbx + TM_rows], r13d
    mov [rbx + TM_sbcap], r14d
    mov dword ptr [rbx + TM_modes], TMM_WRAP
    # encoder and event handles created later; zeroed first for a safe fail path
    mov qword ptr [rbx + TM_kenc], 0
    mov qword ptr [rbx + TM_kev], 0
    mov qword ptr [rbx + TM_menc], 0
    mov qword ptr [rbx + TM_mev], 0
    # TM_gt is the GhosttyTerminal* out-parameter
    lea rdi, [rip + g_vt_allocator]
    lea rsi, [rbx + TM_gt]
    mov edx, r12d
    mov ecx, r13d
    call ghostty_terminal_new
    test eax, eax
    jnz .Ltn_fail
    # scrollback line limit follows unn's ring capacity; 0 = no library scrollback
    mov [rsp], r14
    mov rdi, [rbx + TM_gt]
    mov esi, OPT_SCROLLBACK_MAX_LINES
    mov rdx, rsp
    call ghostty_terminal_set
    # replies land in TM_out, from where termview.s send_replies
    # flushes them to the shell's fd; the callback gets the terminal
    # as userdata
    mov rdi, [rbx + TM_gt]
    mov esi, OPT_USERDATA
    mov rdx, rbx
    call ghostty_terminal_set
    mov rdi, [rbx + TM_gt]
    mov esi, OPT_WRITE_PTY
    lea rdx, [rip + vt_write_pty]
    call ghostty_terminal_set
    # render state for row reads
    lea rdi, [rip + g_vt_allocator]
    lea rsi, [rbx + TM_gts]
    call ghostty_render_state_new
    test eax, eax
    jnz .Ltn_fail
    # reusable row-cells container
    lea rdi, [rip + g_vt_allocator]
    lea rsi, [rbx + TM_gtc]
    call ghostty_render_state_row_cells_new
    test eax, eax
    jnz .Ltn_fail
    # reusable row iterator (render_state_get fills it in every sync)
    lea rdi, [rip + g_vt_allocator]
    lea rsi, [rbx + TM_gti]
    call ghostty_render_state_row_iterator_new
    test eax, eax
    jnz .Ltn_fail
    # input encoders and the events they fill; keyboard first, then mouse
    lea rdi, [rip + g_vt_allocator]
    lea rsi, [rbx + TM_kenc]
    call ghostty_key_encoder_new
    test eax, eax
    jnz .Ltn_fail
    lea rdi, [rip + g_vt_allocator]
    lea rsi, [rbx + TM_kev]
    call ghostty_key_event_new
    test eax, eax
    jnz .Ltn_fail
    lea rdi, [rip + g_vt_allocator]
    lea rsi, [rbx + TM_menc]
    call ghostty_mouse_encoder_new
    test eax, eax
    jnz .Ltn_fail
    lea rdi, [rip + g_vt_allocator]
    lea rsi, [rbx + TM_mev]
    call ghostty_mouse_event_new
    test eax, eax
    jnz .Ltn_fail
    # mirror lines of the active screen
    call screen_new
    mov [rbx + TM_lines], rax
    # the scrollback ring: pointers, lazily filled by vt_sync
    test r14d, r14d
    jz 4f
    lea rdi, [r14*8]
    call mem_alloc
    mov [rbx + TM_sb], rax
4:  call vt_default_colors
    mov dword ptr [rbx + TM_gen], 1
    mov rax, rbx
    EPILOGUE
.Ltn_fail:
    call vt_free_grid
    mov rax, [rbx + TM_mev]
    test rax, rax
    jz 4f
    mov rdi, rax
    call ghostty_mouse_event_free
4:  mov rax, [rbx + TM_menc]
    test rax, rax
    jz 4f
    mov rdi, rax
    call ghostty_mouse_encoder_free
4:  mov rax, [rbx + TM_kev]
    test rax, rax
    jz 4f
    mov rdi, rax
    call ghostty_key_event_free
4:  mov rax, [rbx + TM_kenc]
    test rax, rax
    jz 4f
    mov rdi, rax
    call ghostty_key_encoder_free
4:  mov rax, [rbx + TM_gti]
    test rax, rax
    jz 0f
    mov rdi, rax
    call ghostty_render_state_row_iterator_free
0:  mov rax, [rbx + TM_gt]
    test rax, rax
    jz 1f
    mov rdi, rax
    call ghostty_terminal_free
1:  mov rax, [rbx + TM_gtc]
    test rax, rax
    jz 2f
    mov rdi, rax
    call ghostty_render_state_row_cells_free
2:  mov rax, [rbx + TM_gts]
    test rax, rax
    jz 3f
    mov rdi, rax
    call ghostty_render_state_free
3:  mov rdi, rbx
    call mem_free
    xor eax, eax
    EPILOGUE

# term_free(t)
FN term_free
    PROLOGUE_ALIGNED
    mov rbx, rdi
    test rbx, rbx
    jz 9f
    mov rdi, [rbx + TM_gti]
    test rdi, rdi
    jz 0f
    call ghostty_render_state_row_iterator_free
0:  mov rdi, [rbx + TM_gtc]
    test rdi, rdi
    jz 1f
    call ghostty_render_state_row_cells_free
1:  call vt_free_grid
    mov rdi, [rbx + TM_gt]
    test rdi, rdi
    jz 2f
    call ghostty_terminal_free
2:  mov rdi, [rbx + TM_gts]
    test rdi, rdi
    jz 3f
    call ghostty_render_state_free
3:  mov rdi, [rbx + TM_kev]
    test rdi, rdi
    jz 5f
    call ghostty_key_event_free
5:  mov rdi, [rbx + TM_kenc]
    test rdi, rdi
    jz 6f
    call ghostty_key_encoder_free
6:  mov rdi, [rbx + TM_mev]
    test rdi, rdi
    jz 7f
    call ghostty_mouse_event_free
7:  mov rdi, [rbx + TM_menc]
    test rdi, rdi
    jz 8f
    call ghostty_mouse_encoder_free
8:  mov rdi, [rbx + TM_sb]
    call mem_free
    lea rdi, [rbx + TM_out]
    call sb_free
    lea rdi, [rbx + TM_title]
    call sb_free
    mov rdi, rbx
    call mem_free
9:  EPILOGUE

# vt_free_grid (term in rbx): drop the mirror lines and every ring line
vt_free_grid:
    push r12
    push r13
    test rbx, rbx
    jz 9f
    mov r12, [rbx + TM_lines]
    test r12, r12
    jz 3f
    xor r13d, r13d
1:  cmp r13d, [rbx + TM_rows]
    jae 2f
    mov rdi, [r12 + r13*8]
    call mem_free
    inc r13d
    jmp 1b
2:  mov rdi, r12
    call mem_free
    mov qword ptr [rbx + TM_lines], 0
3:  mov dword ptr [rbx + TM_sbhead], 0
    mov dword ptr [rbx + TM_sblen], 0
    mov qword ptr [rbx + TM_total], 0
    mov r12, [rbx + TM_sb]
    test r12, r12
    jz 9f
    mov r13d, [rbx + TM_sbcap]
    dec r13d
4:  js 9f
    mov rdi, [r12 + r13*8]
    call mem_free
    mov qword ptr [r12 + r13*8], 0
    dec r13d
    jmp 4b
9:  pop r13
    pop r12
    ret

# screen_new (term in rbx) -> TM_rows pointers, one fresh blank line each
# (the mirror owns them, vt_free_grid drops the lot)
screen_new:
    push r12
    push r13
    push r14
    mov r12d, [rbx + TM_rows]
    lea rdi, [r12*8]
    call mem_alloc
    mov r13, rax
    xor r14d, r14d
1:  cmp r14d, r12d
    jae 2f
    call line_new
    mov [r13 + r14*8], rax
    inc r14d
    jmp 1b
2:  mov rax, r13
    pop r14
    pop r13
    pop r12
    ret

# line_new (term in rbx) -> a blank line of TM_cols cells (cap 0, no flags)
line_new:
    push r12
    mov r12d, [rbx + TM_cols]
    lea rdi, [r12 + r12*2]
    lea rdi, [rdi*4 + LN_HDR]
    call mem_alloc
    mov dword ptr [rax + LN_cap], 0
    mov dword ptr [rax + LN_flags], 0
    pop r12
    ret

# ---------------- replies ----------------

# reply_cstr (terminal in rbx, string in rdi): append the string to TM_out
reply_cstr:
    mov rsi, rdi
    lea rdi, [rbx + TM_out]
    jmp sb_push_cstr

# vt_write_pty(terminal, userdata, data, len): the OPT_WRITE_PTY callback.
# Replies to the program's queries append to TM_out; termview.s bridges them
# to the shell's fd
vt_write_pty:
    PROLOGUE_ALIGNED
    mov rbx, rsi                # TERM
    lea rdi, [rbx + TM_out]
    mov rsi, rdx                # data
    mov rdx, rcx                # len
    call sb_push
    EPILOGUE

# ---------------- feeding ----------------

# term_feed(t, ptr, len): the running program's output; the library parses it
# and the TM_gen bump makes the next reader re-sync the mirror
FN term_feed
    PROLOGUE_ALIGNED
    mov rbx, rdi
    mov rdi, [rbx + TM_gt]
    call ghostty_terminal_vt_write
    inc dword ptr [rbx + TM_gen]
    EPILOGUE

# term_clear(t): the screen goes away (into scrollback) and the scrollback with it
FN term_clear
    PROLOGUE_ALIGNED
    mov rbx, rdi
    mov rdi, [rbx + TM_gt]
    lea rsi, [rip + .Lclear]
    mov rdx, .Lclear_end - .Lclear
    call ghostty_terminal_vt_write
    inc dword ptr [rbx + TM_gen]
    EPILOGUE

# term_resize(t, cols, rows): clamp to 2x1, skip entirely when the size is
# unchanged, otherwise let the library reflow and rebuild the mirror from
# scratch (the old LN lines and ring lines are freed)
FN term_resize
    PROLOGUE_ALIGNED
    mov rbx, rdi
    mov r12d, esi
    mov r13d, edx
    cmp r12d, 2
    jge 1f
    mov r12d, 2
1:  cmp r13d, 1
    jge 2f
    mov r13d, 1
2:  cmp r12d, [rbx + TM_cols]
    jne 3f
    cmp r13d, [rbx + TM_rows]
    je .Ltr_done
3:  call vt_free_grid
    mov rdi, [rbx + TM_gt]
    mov esi, r12d
    mov edx, r13d
    mov ecx, 8                  # cell size in pixels: unn's own metrics are
    mov r8d, 16                 # separate, the library needs these only for
                                # its size reports and image protocol
    call ghostty_terminal_resize
    mov [rbx + TM_cols], r12d
    mov [rbx + TM_rows], r13d
    call screen_new
    mov [rbx + TM_lines], rax
    inc dword ptr [rbx + TM_gen]
.Ltr_done:
    EPILOGUE

# ---------------- scrolling ----------------

# term_view_home(t): back to the live screen
FN term_view_home
    PROLOGUE_ALIGNED 32
    mov rbx, rdi
    mov dword ptr [rsp], SC_BOTTOM
    mov qword ptr [rsp + 8], 0
    mov qword ptr [rsp + 16], 0
    mov rdi, [rbx + TM_gt]
    call ghostty_terminal_scroll_viewport
    inc dword ptr [rbx + TM_gen]
    EPILOGUE

# term_view_delta(t, lines): lines back (positive) or forward
FN term_view_delta
    PROLOGUE_ALIGNED 32
    mov rbx, rdi
    mov dword ptr [rsp], SC_DELTA
    movsxd rax, esi
    neg rax                     # ghostty's delta is negative going up
    mov [rsp + 8], rax
    mov qword ptr [rsp + 16], 0
    mov rdi, [rbx + TM_gt]
    call ghostty_terminal_scroll_viewport
    inc dword ptr [rbx + TM_gen]
    EPILOGUE

# term_view_set(t, view): scrolled back by exactly `view` rows
FN term_view_set
    PROLOGUE_ALIGNED 64
    mov rbx, rdi
    mov r12d, esi
    mov rdi, [rbx + TM_gt]
    mov esi, GD_SCROLLBAR
    lea rdx, [rsp + 32]
    call ghostty_terminal_get
    mov rax, [rsp + 32]         # total
    sub rax, [rsp + 48]         # len -> scrollback rows
    movsxd rcx, r12d
    sub rax, rcx
    jns 1f
    xor eax, eax                # the request can run past the oldest
                                # row: pin it at 0
1:  mov dword ptr [rsp], SC_ROW
    mov [rsp + 8], rax
    mov qword ptr [rsp + 16], 0
    mov rdi, [rbx + TM_gt]
    call ghostty_terminal_scroll_viewport
    inc dword ptr [rbx + TM_gen]
    EPILOGUE

# ---------------- the mirror ----------------

.equ VS_SB, 0               # GhosttyTerminalScrollbar (24)
.equ VS_CUR, 32             # GhosttyRenderStateCursor (24)
.equ VS_SCR, 56             # active screen (i32)
.equ VS_TITLE, 64           # GhosttyString {ptr,len}
.equ VS_IT, 80              # row iterator handle
.equ VS_ROW, 88             # GhosttyRow
.equ VS_VY, 96              # i32 viewport y
.equ VS_WRAP, 100           # u8 row wrap
.equ VS_SLOT, 104           # i32 ring slot
.equ VS_N, 108              # i32 safety counter

# vt_sync (term in rbx): reclaim the LN view and geometry from libghostty, a
# no-op while the mirror is current (TM_sync == TM_gen). Every public reader
# lands here first so its answers reflect the library's last write.
vt_sync:
    PROLOGUE_ALIGNED 128
    mov eax, [rbx + TM_gen]
    cmp eax, [rbx + TM_sync]
    je .Lvs_done
    # 1. scroll geometry first: it fixes which rows the mirror can hold, and the
    # viewport may have to be pulled back onto them before the render state is
    # taken, because the mirror walks that render state
    mov rdi, [rbx + TM_gt]
    mov esi, GD_SCROLLBAR
    lea rdx, [rsp + VS_SB]
    call ghostty_terminal_get
    mov rax, [rsp + VS_SB]          # total rows (scrollback + screen)
    sub rax, [rsp + VS_SB + 16]     # len = screen rows -> S = history rows held
    mov [rbx + TM_hlen], rax
    mov rdx, rax
    sub rdx, [rsp + VS_SB + 8]      # view = S - offset
    jns .Lvs_geo_view
    xor edx, edx
.Lvs_geo_view:
    # sblen = min(S, sbcap): the lines unn's ring holds, which is also all unn
    # can address. libghostty prunes scrollback a page at a time, so it keeps
    # more history than it was asked for; the extra rows are not ours to show.
    movsxd r8, dword ptr [rbx + TM_sbcap]
    cmp rax, r8
    jbe .Lvs_geo_cap
    mov rax, r8
.Lvs_geo_cap:
    mov [rbx + TM_sblen], eax
    mov [rbx + TM_total], rax
    mov dword ptr [rbx + TM_sbhead], 0
    cmp edx, eax
    jbe 2f
    # pull the library's viewport back onto the ring
    mov r15d, eax                   # stash the clamped view across the call
    mov ecx, eax
    mov rax, [rbx + TM_hlen]
    sub rax, rcx                    # SC_ROW: the oldest row unn keeps
    mov dword ptr [rsp], SC_ROW
    mov [rsp + 8], rax
    mov qword ptr [rsp + 16], 0
    mov rdi, [rbx + TM_gt]
    call ghostty_terminal_scroll_viewport
    mov edx, r15d
2:  mov [rbx + TM_view], edx        # never scroll past the ring
    # 2. render state from the terminal
    mov rdi, [rbx + TM_gts]
    mov rsi, [rbx + TM_gt]
    call ghostty_render_state_update
    # 3. cursor
    mov qword ptr [rsp + VS_CUR], RSC_SIZE
    mov rdi, [rbx + TM_gts]
    mov esi, RD_CURSOR
    lea rdx, [rsp + VS_CUR]
    call ghostty_render_state_get
    movzx eax, byte ptr [rsp + VS_CUR + RSC_HAS_VALUE]
    test eax, eax
    jz 3f
    movzx eax, word ptr [rsp + VS_CUR + RSC_X]
    mov [rbx + TM_cx], eax
    movzx eax, word ptr [rsp + VS_CUR + RSC_Y]
    mov [rbx + TM_cy], eax
3:  # DECSCUSR-shaped cursor style
    mov eax, [rsp + VS_CUR + RSC_STYLE]
    cmp eax, CU_BAR
    je .Lvs_bar
    cmp eax, CU_UNDERLINE
    je .Lvs_under
    mov ecx, 1                  # block (and hollow)
    jmp .Lvs_cs
.Lvs_bar:
    mov ecx, 5
    jmp .Lvs_cs
.Lvs_under:
    mov ecx, 3
.Lvs_cs:
    cmp byte ptr [rsp + VS_CUR + RSC_BLINKING], 0
    jne 4f
    inc ecx                     # steady variant
4:  mov [rbx + TM_cursor], ecx
    # 4. modes in one batch
    mov rdi, [rbx + TM_gt]
    mov esi, VM_COUNT
    lea rdx, [rip + vt_modekeys]
    lea rcx, [rip + vt_modevals]
    xor r8d, r8d
    call ghostty_terminal_get_multi
    xor r15d, r15d
    lea r9, [rip + vt_modespec]
    cmp byte ptr [r9 + VM_WRAP + 2], 0
    je 5f
    or r15d, TMM_WRAP
5:  cmp byte ptr [r9 + VM_APPCUR + 2], 0
    je 6f
    or r15d, TMM_APPCUR
6:  cmp byte ptr [r9 + VM_HIDE + 2], 0
    jne 7f
    or r15d, TMM_HIDE         # cursor hidden when mode 25 is off
7:  cmp byte ptr [r9 + VM_INSERT + 2], 0
    je 8f
    or r15d, TMM_INSERT
8:  cmp byte ptr [r9 + VM_PASTE + 2], 0
    je 9f
    or r15d, TMM_PASTE
9:  cmp byte ptr [r9 + VM_SGRMOUSE + 2], 0
    je 10f
    or r15d, TMM_SGRMOUSE
10: cmp byte ptr [r9 + VM_FOCUS + 2], 0
    je 11f
    or r15d, TMM_FOCUS
11: cmp byte ptr [r9 + VM_ORIGIN + 2], 0
    je 12f
    or r15d, TMM_ORIGIN
12: cmp byte ptr [r9 + VM_LNM + 2], 0
    je 13f
    or r15d, TMM_LNM
13: cmp byte ptr [r9 + VM_SYNC + 2], 0
    je 14f
    or r15d, TMM_SYNC
14: # the alternate screen
    mov rdi, [rbx + TM_gt]
    mov esi, GD_ACTIVE_SCREEN
    lea rdx, [rsp + VS_SCR]
    call ghostty_terminal_get
    cmp dword ptr [rsp + VS_SCR], 1
    jne 15f
    or r15d, TMM_ALT
15: mov [rbx + TM_modes], r15d
    # mouse tracking value
    xor eax, eax
    cmp byte ptr [r9 + VM_MOUSE3 + 2], 0
    je 16f
    mov eax, 1003
    jmp 19f
16: cmp byte ptr [r9 + VM_MOUSE2 + 2], 0
    je 17f
    mov eax, 1002
    jmp 19f
17: cmp byte ptr [r9 + VM_MOUSE1 + 2], 0
    je 19f
    mov eax, 1000
19: mov [rbx + TM_mouse], eax
    # 5. title
    mov rdi, [rbx + TM_gt]
    mov esi, GD_TITLE
    lea rdx, [rsp + VS_TITLE]
    call ghostty_terminal_get
    lea rdi, [rbx + TM_title]
    call sb_clear
    mov rdx, [rsp + VS_TITLE + 8]
    test rdx, rdx
    jz 20f
    lea rdi, [rbx + TM_title]
    mov rsi, [rsp + VS_TITLE]
    call sb_push
20: # 6. the rows of the viewport
    mov rax, [rbx + TM_gti]
    mov [rsp + VS_IT], rax
    mov rdi, [rbx + TM_gts]
    mov esi, RD_ROW_ITERATOR
    lea rdx, [rsp + VS_IT]
    call ghostty_render_state_get
    mov dword ptr [rsp + VS_N], 0
.Lvs_row:
    mov eax, [rsp + VS_N]
    cmp eax, [rbx + TM_rows]
    jae .Lvs_rows_done
    mov rdi, [rsp + VS_IT]
    call ghostty_render_state_row_iterator_next
    test eax, eax
    jz .Lvs_rows_done
    mov rdi, [rsp + VS_IT]
    mov esi, RW_VIEWPORT_Y
    lea rdx, [rsp + VS_VY]
    call ghostty_render_state_row_get
    mov rdi, [rsp + VS_IT]
    mov esi, RW_RAW
    lea rdx, [rsp + VS_ROW]
    call ghostty_render_state_row_get
    mov rdi, [rsp + VS_ROW]
    mov esi, ROW_WRAP
    lea rdx, [rsp + VS_WRAP]
    call ghostty_row_get
    mov rdi, [rsp + VS_IT]
    mov esi, RW_CELLS
    lea rdx, [rbx + TM_gtc]
    call ghostty_render_state_row_get
    # which LN line does this viewport row show
    mov eax, [rsp + VS_VY]
    sub eax, [rbx + TM_view]        # rr: the row inside the active area,
    js .Lvs_sb                      # negative = a ring history row
    cmp eax, [rbx + TM_rows]
    jae .Lvs_next
    mov rcx, [rbx + TM_lines]
    movsxd rdx, eax
    mov rsi, [rcx + rdx*8]
    jmp .Lvs_have
.Lvs_sb:
    add eax, [rbx + TM_sblen]       # ring slot (0-based, slot 0 the oldest)
    js .Lvs_next
    mov [rsp + VS_SLOT], eax
    mov rcx, [rbx + TM_sb]
    test rcx, rcx
    jz .Lvs_next
    movsxd rdx, eax
    mov rsi, [rcx + rdx*8]
    test rsi, rsi
    jnz .Lvs_have
    call line_new
    mov ecx, [rsp + VS_SLOT]
    mov rdx, [rbx + TM_sb]
    mov [rdx + rcx*8], rax
    mov rsi, rax
.Lvs_have:
    mov rdi, [rbx + TM_gtc]
    movzx edx, byte ptr [rsp + VS_WRAP]
    call vt_mirror_row
.Lvs_next:
    inc dword ptr [rsp + VS_N]
    jmp .Lvs_row
.Lvs_rows_done:
    mov eax, [rbx + TM_gen]
    mov [rbx + TM_sync], eax
.Lvs_done:
    EPILOGUE

# both row readers fill one of these, then vt_decode_cell turns it into an
# unn cell. cp/tag/wide/styling come from ghostty_cell_get_multi; the style
# body (when has_styling) and the content-tag colour are filled by the reader,
# which is the only part that differs between the live screen and the
# scrollback history.
.equ DL_RAW, 0              # GhosttyCell
.equ DL_CP, 8               # uint32
.equ DL_TAG, 12             # GhosttyCellContentTag
.equ DL_WIDE, 16            # GhosttyCellWide
.equ DL_STYL, 20            # bool has_styling
.equ DL_PAL, 21             # uint8 palette index
.equ DL_RGB, 22             # GhosttyColorRgb { r, g, b }
.equ DL_STYLE, 32           # GhosttyStyle
.equ DL_SIZE, 104

# vt_decode_cell(rdi = DL*) -> eax cell word, r10d foreground, r11d background.
# No calls, caller-saved registers only.
vt_decode_cell:
    xor r8d, r8d                # attributes
    xor r10d, r10d              # foreground
    xor r11d, r11d              # background
    cmp byte ptr [rdi + DL_STYL], 0
    je .Ldc_tag
    lea rsi, [rdi + DL_STYLE]
    cmp byte ptr [rsi + ST_BOLD], 0
    je 1f
    or r8d, A_BOLD
1:  cmp byte ptr [rsi + ST_ITALIC], 0
    je 1f
    or r8d, A_ITALIC
1:  cmp byte ptr [rsi + ST_FAINT], 0
    je 1f
    or r8d, A_DIM
1:  cmp byte ptr [rsi + ST_BLINK], 0
    je 1f
    or r8d, A_BLINK
1:  cmp byte ptr [rsi + ST_INVERSE], 0
    je 1f
    or r8d, A_INVERSE
1:  cmp byte ptr [rsi + ST_INVISIBLE], 0
    je 1f
    or r8d, A_HIDDEN
1:  cmp byte ptr [rsi + ST_STRIKE], 0
    je 1f
    or r8d, A_STRIKE
1:  cmp dword ptr [rsi + ST_UNDERLINE], 0
    je 1f
    or r8d, A_UNDER
1:  mov eax, [rsi + ST_FG]
    cmp eax, STC_PALETTE
    jne 2f
    movzx r10d, byte ptr [rsi + ST_FG + 8]
    or r10d, TC_IDX
    jmp 3f
2:  cmp eax, STC_RGB
    jne 3f
    movzx r10d, byte ptr [rsi + ST_FG + 8]
    shl r10d, 16
    movzx eax, byte ptr [rsi + ST_FG + 9]
    shl eax, 8
    or r10d, eax
    movzx eax, byte ptr [rsi + ST_FG + 10]
    or r10d, eax
    or r10d, TC_RGB
3:  mov eax, [rsi + ST_BG]
    cmp eax, STC_PALETTE
    jne 4f
    movzx r11d, byte ptr [rsi + ST_BG + 8]
    or r11d, TC_IDX
    jmp .Ldc_tag
4:  cmp eax, STC_RGB
    jne .Ldc_tag
    movzx r11d, byte ptr [rsi + ST_BG + 8]
    shl r11d, 16
    movzx eax, byte ptr [rsi + ST_BG + 9]
    shl eax, 8
    or r11d, eax
    movzx eax, byte ptr [rsi + ST_BG + 10]
    or r11d, eax
    or r11d, TC_RGB
.Ldc_tag:
    mov eax, [rdi + DL_TAG]
    cmp eax, CT_BG_PALETTE
    jne 5f
    movzx r11d, byte ptr [rdi + DL_PAL]
    or r11d, TC_IDX
    xor r8d, r8d
    xor r10d, r10d
    jmp .Ldc_place
5:  cmp eax, CT_BG_RGB
    jne .Ldc_place
    movzx r11d, byte ptr [rdi + DL_RGB]
    shl r11d, 16
    movzx eax, byte ptr [rdi + DL_RGB + 1]
    shl eax, 8
    or r11d, eax
    movzx eax, byte ptr [rdi + DL_RGB + 2]
    or r11d, eax
    or r11d, TC_RGB
    xor r8d, r8d
    xor r10d, r10d
.Ldc_place:
    mov eax, [rdi + DL_CP]
    and eax, CP_MASK
    or eax, r8d
    mov ecx, [rdi + DL_WIDE]
    cmp ecx, CW_WIDE
    jne 6f
    or eax, A_WIDE
6:  cmp ecx, CW_SPACER_TAIL
    jne 7f
    mov eax, r8d                  # the right half of a wide character: no
    or eax, A_WIDE2               # codepoint of its own to draw
7:  cmp ecx, CW_SPACER_HEAD
    jne 8f
    xor eax, eax                  # nothing draws here: the wide character
    xor r10d, r10d                # this spacer reserved soft-wrapped onward
    xor r11d, r11d
8:  ret

# vt_mirror_row(rbx=TERM, rdi=cells, rsi=target line, edx=wrap):
#   decode the render-state row the iterator is on into target's cells
.equ MR_CELLS, 0
.equ MR_TGT, 8
.equ MR_DL, 16              # DL_SIZE -> 16..120
.equ MR_VALS, 120           # 4 pointers -> 120..152
.equ MR_FRAME, 160

vt_mirror_row:
    PROLOGUE_ALIGNED MR_FRAME
    mov [rsp + MR_CELLS], rdi
    mov [rsp + MR_TGT], rsi
    mov r13d, [rbx + TM_cols]
    mov dword ptr [rsi + LN_cap], r13d
    xor eax, eax
    test edx, edx
    jz 1f
    mov eax, LF_WRAPPED
1:  mov [rsi + LN_flags], eax
    lea rax, [rsp + MR_DL + DL_TAG]
    mov [rsp + MR_VALS], rax
    lea rax, [rsp + MR_DL + DL_CP]
    mov [rsp + MR_VALS + 8], rax
    lea rax, [rsp + MR_DL + DL_WIDE]
    mov [rsp + MR_VALS + 16], rax
    lea rax, [rsp + MR_DL + DL_STYL]
    mov [rsp + MR_VALS + 24], rax
    xor r12d, r12d              # column
.Lmr_loop:
    cmp r12d, r13d
    jae .Lmr_done
    mov rdi, [rsp + MR_CELLS]
    mov esi, r12d
    call ghostty_render_state_row_cells_select
    mov rdi, [rsp + MR_CELLS]
    mov esi, RC_RAW
    lea rdx, [rsp + MR_DL + DL_RAW]
    call ghostty_render_state_row_cells_get
    mov dword ptr [rsp + MR_DL + DL_TAG], 0
    mov dword ptr [rsp + MR_DL + DL_CP], 0
    mov dword ptr [rsp + MR_DL + DL_WIDE], 0
    mov byte ptr [rsp + MR_DL + DL_STYL], 0
    mov rdi, [rsp + MR_DL + DL_RAW]
    mov esi, 4
    lea rdx, [rip + vt_cell_keys]
    lea rcx, [rsp + MR_VALS]
    xor r8d, r8d
    call ghostty_cell_get_multi
    cmp byte ptr [rsp + MR_DL + DL_STYL], 0
    je 2f
    mov qword ptr [rsp + MR_DL + DL_STYLE], ST_SIZE
    mov rdi, [rsp + MR_CELLS]
    mov esi, RC_STYLE
    lea rdx, [rsp + MR_DL + DL_STYLE]
    call ghostty_render_state_row_cells_get
2:  lea rdi, [rsp + MR_DL]
    call vt_read_tag_color
    lea rdi, [rsp + MR_DL]
    call vt_decode_cell
    mov rcx, [rsp + MR_TGT]
    movsxd rdx, r12d
    lea rdx, [rdx + rdx*2]
    lea rcx, [rcx + rdx*4 + LN_HDR]
    mov [rcx], eax
    mov [rcx + 4], r10d
    mov [rcx + 8], r11d
    inc r12d
    jmp .Lmr_loop
.Lmr_done:
    EPILOGUE

# vt_read_tag_color(rbx=TERM, rdi=DL*): a cell that is only a coloured
# background keeps its palette index or rgb tuple in the cell itself
vt_read_tag_color:
    mov eax, [rdi + DL_TAG]
    cmp eax, CT_BG_PALETTE
    jne 1f
    mov rsi, rdi
    mov rdi, [rdi + DL_RAW]
    lea rdx, [rsi + DL_PAL]
    mov esi, CD_COLOR_PALETTE
    jmp ghostty_cell_get
1:  cmp eax, CT_BG_RGB
    jne 2f
    mov rsi, rdi
    mov rdi, [rdi + DL_RAW]
    lea rdx, [rsi + DL_RGB]
    mov esi, CD_COLOR_RGB
    jmp ghostty_cell_get
2:  xor eax, eax
    ret

# vt_hist_row(rbx=TERM, esi=row<0) -> line* of a scrollback row the viewport
#   doesn't show, decoded from the library's history into its ring slot.
#   History has no cheap row reads like the render state: every cell
#   resolves through a GhosttyPoint -> ghostty_terminal_grid_ref
#   lookup. A resolve that fails (out of range) leaves that cell blank
#   in the mirror
.equ HR_ARG, 0              # GhosttyPoint (24 bytes) for the call below
                            # bytes and goes on the stack, so it must sit at
                            # the frame base, which is rsp at the call
.equ HR_DL, 32              # 32..136
.equ HR_VALS, 136           # 136..168
.equ HR_REF, 168            # GhosttyGridRef 168..192
.equ HR_ROW, 192            # GhosttyRow
.equ HR_Y, 200              # absolute history row
.equ HR_SLOT, 208
.equ HR_COL, 212
.equ HR_WRAP, 216
.equ HR_FRAME, 240

vt_hist_row:
    PROLOGUE_ALIGNED HR_FRAME
    movsxd rcx, esi
    mov rax, [rbx + TM_hlen]
    add rax, rcx
    js .Lhr_none                # before the oldest kept row
    mov [rsp + HR_Y], rax       # the library's row index, not unn's capped total
    mov eax, [rbx + TM_sblen]
    add eax, esi
    js .Lhr_none
    mov [rsp + HR_SLOT], eax
    mov rdx, [rbx + TM_sb]
    test rdx, rdx
    jz .Lhr_none
    movsxd rcx, eax
    mov r13, [rdx + rcx*8]
    test r13, r13
    jnz 1f
    call line_new
    mov ecx, [rsp + HR_SLOT]
    mov rdx, [rbx + TM_sb]
    mov [rdx + rcx*8], rax
    mov r13, rax
1:  # the wrap flag comes from the row the history point lands on
    mov dword ptr [rsp + HR_ARG], PT_HISTORY
    mov word ptr [rsp + HR_ARG + 8], 0
    mov rax, [rsp + HR_Y]
    mov [rsp + HR_ARG + 12], eax
    mov qword ptr [rsp + HR_REF], GRIDREF_SIZE
    mov rdi, [rbx + TM_gt]
    lea rsi, [rsp + HR_REF]
    call ghostty_terminal_grid_ref
    xor r14d, r14d
    test eax, eax
    jnz 2f
    lea rdi, [rsp + HR_REF]
    lea rsi, [rsp + HR_ROW]
    call ghostty_grid_ref_row
    test eax, eax
    jnz 2f
    mov dword ptr [rsp + HR_WRAP], 0
    mov rdi, [rsp + HR_ROW]
    mov esi, ROW_WRAP
    lea rdx, [rsp + HR_WRAP]
    call ghostty_row_get
    mov r14d, [rsp + HR_WRAP]
2:  mov ecx, [rbx + TM_cols]
    mov [r13 + LN_cap], ecx
    xor eax, eax
    test r14d, r14d
    jz 3f
    mov eax, LF_WRAPPED
3:  mov [r13 + LN_flags], eax
    lea rax, [rsp + HR_DL + DL_TAG]
    mov [rsp + HR_VALS], rax
    lea rax, [rsp + HR_DL + DL_CP]
    mov [rsp + HR_VALS + 8], rax
    lea rax, [rsp + HR_DL + DL_WIDE]
    mov [rsp + HR_VALS + 16], rax
    lea rax, [rsp + HR_DL + DL_STYL]
    mov [rsp + HR_VALS + 24], rax
    mov dword ptr [rsp + HR_COL], 0
.Lhr_col:
    mov eax, [rsp + HR_COL]
    cmp eax, [rbx + TM_cols]
    jae .Lhr_done
    mov dword ptr [rsp + HR_ARG], PT_HISTORY
    mov [rsp + HR_ARG + 8], ax
    mov rax, [rsp + HR_Y]
    mov [rsp + HR_ARG + 12], eax
    mov qword ptr [rsp + HR_REF], GRIDREF_SIZE
    mov rdi, [rbx + TM_gt]
    lea rsi, [rsp + HR_REF]
    call ghostty_terminal_grid_ref
    test eax, eax
    jnz .Lhr_blank
    lea rdi, [rsp + HR_REF]
    lea rsi, [rsp + HR_DL + DL_RAW]
    call ghostty_grid_ref_cell
    mov dword ptr [rsp + HR_DL + DL_TAG], 0
    mov dword ptr [rsp + HR_DL + DL_CP], 0
    mov dword ptr [rsp + HR_DL + DL_WIDE], 0
    mov byte ptr [rsp + HR_DL + DL_STYL], 0
    mov rdi, [rsp + HR_DL + DL_RAW]
    mov esi, 4
    lea rdx, [rip + vt_cell_keys]
    lea rcx, [rsp + HR_VALS]
    xor r8d, r8d
    call ghostty_cell_get_multi
    cmp byte ptr [rsp + HR_DL + DL_STYL], 0
    je 4f
    mov qword ptr [rsp + HR_DL + DL_STYLE], ST_SIZE
    lea rdi, [rsp + HR_REF]
    lea rsi, [rsp + HR_DL + DL_STYLE]
    call ghostty_grid_ref_style
4:  lea rdi, [rsp + HR_DL]
    call vt_read_tag_color
    lea rdi, [rsp + HR_DL]
    call vt_decode_cell
    jmp 5f
.Lhr_blank:
    xor eax, eax
    xor r10d, r10d
    xor r11d, r11d
5:  movsxd rcx, dword ptr [rsp + HR_COL]
    lea rcx, [rcx + rcx*2]
    lea rcx, [r13 + rcx*4 + LN_HDR]
    mov [rcx], eax
    mov [rcx + 4], r10d
    mov [rcx + 8], r11d
    inc dword ptr [rsp + HR_COL]
    jmp .Lhr_col
.Lhr_done:
    mov rax, r13
    EPILOGUE
.Lhr_none:
    xor eax, eax
    EPILOGUE

# ---------------- queries ----------------

# term_row(t, row) -> line; negative rows are scrollback (-1 the newest),
# out-of-range rows: 0
FN term_row
    PROLOGUE_ALIGNED
    mov rbx, rdi
    mov r12d, esi
    call vt_sync
    test r12d, r12d
    js 1f
    cmp r12d, [rbx + TM_rows]
    jge 2f
    mov rax, [rbx + TM_lines]
    movsxd rcx, r12d
    mov rax, [rax + rcx*8]
    EPILOGUE
1:  # a scrollback row: the mirror has it when the viewport shows it, else the
    # library's history has it
    mov ecx, r12d
    add ecx, [rbx + TM_view]
    js 3f
    cmp ecx, [rbx + TM_rows]
    jae 3f
    mov eax, [rbx + TM_sblen]
    add eax, r12d
    js 2f
    mov rcx, [rbx + TM_sb]
    movsxd rdx, eax
    mov rax, [rcx + rdx*8]
    EPILOGUE
3:  mov rdi, rbx
    mov esi, r12d
    call vt_hist_row
    EPILOGUE
2:  xor eax, eax
    EPILOGUE

# term_text(t, sb, row0, col0, row1, col1): text of the cells from (row0, col0)
#   up to (row1, col1), rows as in term_row; wrapped lines join, trailing blanks
#   of a line are dropped
FN term_text
    PROLOGUE_ALIGNED 32
    mov rbx, rdi
    mov r12, rsi
    mov [rsp], edx              # row
    mov [rsp + 4], ecx          # col0
    mov [rsp + 8], r8d          # row1
    mov [rsp + 12], r9d         # col1
.Ltt_row:
    mov eax, [rsp]
    cmp eax, [rsp + 8]
    jg .Ltt_done
    mov rdi, rbx
    mov esi, eax
    call term_row
    test rax, rax
    jz .Ltt_nl
    mov r13, rax
    mov r14d, [rsp + 4]
    mov dword ptr [rsp + 4], 0
    mov r15d, [rbx + TM_cols]
    mov eax, [rsp]
    cmp eax, [rsp + 8]
    jne 1f
    mov r15d, [rsp + 12]
1:  cmp r15d, [r13 + LN_cap]
    jle 2f
    mov r15d, [r13 + LN_cap]
2:  mov ecx, r15d
    cmp eax, [rsp + 8]
    jge 4f
    test dword ptr [r13 + LN_flags], LF_WRAPPED
    jnz 5f
4:  cmp ecx, r14d
    jle 5f
    # trim (or cut) the line back past its trailing blanks
    lea eax, [rcx - 1]
    CELLP rdx, r13, rax
    mov edx, [rdx]
    and edx, CP_MASK
    cmp edx, ' '
    ja 5f
    dec ecx
    jmp 4b
5:  mov [rsp + 16], ecx         # end of text
6:  cmp r14d, [rsp + 16]
    jge 7f
    CELLP rdx, r13, r14
    mov eax, [rdx]
    inc r14d
    test eax, A_WIDE2
    jnz 6b
    and eax, CP_MASK
    # control bytes never leave the terminal raw:
    # the selection copy sends this text on as-is
    cmp eax, ' '
    jae 61f
    mov eax, ' '
61: mov rdi, r12
    mov esi, eax
    call sb_push_utf8
    jmp 6b
7:  mov eax, [rsp]
    cmp eax, [rsp + 8]
    jge .Ltt_done
    test dword ptr [r13 + LN_flags], LF_WRAPPED
    jnz .Ltt_next
.Ltt_nl:
    mov eax, [rsp]
    cmp eax, [rsp + 8]
    jge .Ltt_done
    mov rdi, r12
    mov esi, 10
    call sb_push_byte
.Ltt_next:
    inc dword ptr [rsp]
    jmp .Ltt_row
.Ltt_done:
    EPILOGUE

# term_dump(t, sb): each row of the screen as a line of text, then
# "cursor ROW,COL"
FN term_dump
    PROLOGUE_ALIGNED
    mov rbx, rdi
    mov r12, rsi
    xor r13d, r13d
1:  cmp r13d, [rbx + TM_rows]
    jae 2f
    mov rdi, rbx
    mov rsi, r12
    mov edx, r13d
    xor ecx, ecx
    mov r8d, r13d
    mov r9d, [rbx + TM_cols]
    call term_text
    mov rdi, r12
    mov esi, 10
    call sb_push_byte
    inc r13d
    jmp 1b
2:  mov rdi, r12
    lea rsi, [rip + .Ld_cursor]
    call sb_push_cstr
    mov rdi, r12
    mov esi, [rbx + TM_cy]
    call sb_push_u64
    mov rdi, r12
    mov esi, ','
    call sb_push_byte
    mov rdi, r12
    mov esi, [rbx + TM_cx]
    call sb_push_u64
    mov rdi, r12
    mov esi, 10
    call sb_push_byte
    EPILOGUE

.section .rodata
.Lclear: .ascii "\033[2J\033[3J\033[H"
.Lclear_end:
.Ld_cursor: .asciz "cursor "
.text
# term_key(t, keysym, cp, mods) -> 1 if something was sent to the program
# keysym: X11 keysym, printable keys carry the character itself; cp: the layout
# text as a codepoint (0 for pure function keys); mods: unn's MOD_* bits.
# Everything goes through the libghostty key encoder: it reads the terminal's
# modes and produces whatever the program asked for.
FN term_key
    PROLOGUE_ALIGNED 64
    mov rbx, rdi
    mov r12d, esi               # keysym
    mov r13d, edx               # layout codepoint
    mov r14d, ecx               # mods
    call vt_sync                 # mode state must be fresh before key encoding
    mov rax, [rbx + TM_kenc]
    test rax, rax
    jz .Lk_no
    # every mode the encoder consults (cursor/keypad application, alt escape
    # prefix, modifyOtherKeys, kitty flags) comes straight from the terminal
    mov rdi, rax
    mov rsi, [rbx + TM_gt]
    call ghostty_key_encoder_setopt_from_terminal
    # ghostty mods: shift 1, ctrl 2, alt 4, super 8
    # (unn: shift 1, ctrl 4, alt 8, super 64)
    xor r10d, r10d
    test r14d, MOD_SHIFT
    jz 1f
    or r10d, 1
1:  test r14d, MOD_CTRL
    jz 2f
    or r10d, 2
2:  test r14d, MOD_ALT
    jz 3f
    or r10d, 4
3:  test r14d, MOD_SUPER
    jz 4f
    or r10d, 8
4:  # physical key: ASCII characters map through a table, other
    # keysyms through a pair list
    xor r15d, r15d              # 0 = GHOSTTY_KEY_UNIDENTIFIED
    mov eax, r12d
    cmp eax, 0x20
    jb 6f
    cmp eax, 0x7e
    ja 5f
    lea rcx, [rip + gkey_ascii]
    movzx r15d, word ptr [rcx + rax*2 - 0x40]
    jmp 7f
5:  lea rcx, [rip + gkey_syms]
51: mov eax, [rcx]
    cmp eax, -1
    je 7f
    cmp eax, r12d
    je 52f
    add rcx, 8
    jmp 51b
52: mov r15d, [rcx + 4]
7:  # the event does not own its text buffer, so the utf8 bytes live
    # in this frame; C0 control characters must not be sent as text,
    # the encoder works from the physical key and mods instead
    mov qword ptr [rsp + 8], 0
    mov qword ptr [rsp + 16], 0
    mov qword ptr [rsp + 24], 0
    test r13d, r13d
    jz 8f
    cmp r13d, 0x20
    jb 8f
    mov [rsp], r13d
    mov edi, r13d
    lea rsi, [rsp]
    call utf8_encode
    lea rcx, [rsp]
    mov [rsp + 8], rcx
    mov [rsp + 16], rax
8:  # unshifted codepoint: the unshifted character, else the
    # codepoint, letters lowercased
    mov ecx, [rip + g_key_base]
    test ecx, ecx
    jnz 9f
    mov ecx, r13d
9:  lea eax, [rcx - 'A']
    cmp eax, 25
    ja 10f
    add ecx, 32
10: # fill the event: press, physical key, mods, text, unshifted codepoint
    mov rdi, [rbx + TM_kev]
    test rdi, rdi
    jz .Lk_no
    mov esi, 1                  # GHOSTTY_KEY_ACTION_PRESS
    call ghostty_key_event_set_action
    mov rdi, [rbx + TM_kev]
    mov esi, r15d
    call ghostty_key_event_set_key
    mov rdi, [rbx + TM_kev]
    mov esi, r10d
    call ghostty_key_event_set_mods
    mov rdi, [rbx + TM_kev]
    mov esi, ecx
    call ghostty_key_event_set_unshifted_codepoint
    mov rdi, [rbx + TM_kev]
    mov rsi, [rsp + 8]
    mov rdx, [rsp + 16]
    call ghostty_key_event_set_utf8
    # encode; the reply bytes (or plain text) go to the pty
    mov rdi, [rbx + TM_kenc]
    mov rsi, [rbx + TM_kev]
    lea rdx, [rsp + 32]
    mov ecx, 32
    lea r8, [rsp + 24]
    call ghostty_key_encoder_encode
    test eax, eax
    jnz .Lk_no
    mov rdx, [rsp + 24]
    test rdx, rdx
    jz .Lk_no
    lea rdi, [rbx + TM_out]
    lea rsi, [rsp + 32]
    call sb_push
.Lk_yes:
    mov eax, 1
    EPILOGUE
.Lk_no:
    xor eax, eax
    EPILOGUE

# term_paste(t, ptr, len): the text pasted into the terminal, framed by the
# library's encoder: bracketed mode wraps it in the 200~ sequences, unbracketed
# mode turns the newlines into Enter; unsafe bytes (NUL, ESC, DEL) become
# spaces instead of being dropped, so the program's view of the paste keeps
# its shape. The ghostty_terminal_paste wrapper (kitty paste events, mode
# 5522, crypto one-time passwords) needs the MIME reader scaffolding; the
# pure text encoder covers everything unn pastes today.
FN term_paste
    PROLOGUE_ALIGNED 16
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    call vt_sync                 # bracketed paste is a mode of the library
    lea rdi, [r13 + r13 + 40]    # the output is at most len + 14 (the two
    call mem_alloc               # brackets); the input copy sits past it
    mov r14, rax
    # the encoder edits its input in place, which must never be the test's
    # .rodata or a shared clipboard page: it gets its own copy of the
    # input there
    mov r15, r14                 # scratch = tail of the allocation; see below
    lea r15, [r14 + r13 + 8]
    test r13, r13
    jz 1f
    mov rdi, r15
    mov rsi, r12
    mov rdx, r13
    call memmove
1:  xor edx, edx
    test dword ptr [rbx + TM_modes], TMM_PASTE
    jz 2f
    mov edx, 1
2:  mov rdi, r15
    mov rsi, r13
    mov rcx, r14
    lea r8, [r13 + 32]
    lea r9, [rsp]                # out_written lives in this frame
    call ghostty_paste_encode
    test eax, eax
    jnz .Lp_done                 # a failure writes nothing (it fits: no retry)
    mov rdx, qword ptr [rsp]
    lea rdi, [rbx + TM_out]
    mov rsi, r14
    call sb_push
.Lp_done:
    mov rdi, r14
    call mem_free
    EPILOGUE

# term_mouse(t, button, kind, col, row, mods) -> 1 if the program gets the event
#   button 0 left, 1 middle, 2 right, 3 none, 64/65 wheel;
#   kind 0 press, 1 release, 2 motion
# Coordinates are cells; the encoder wants pixel coordinates, so unn synthesizes
# a 1024 px cell in a zero-padding surface with the pointer centered in its cell.
# Tracking mode and output format come from the terminal like everything else.
FN term_mouse
    PROLOGUE_ALIGNED 96
    mov rbx, rdi
    mov r12d, esi               # unn button
    mov r13d, edx               # kind
    mov r14d, ecx               # col
    mov r15d, r8d               # row
    mov [rsp], r9d              # unn mods
    call vt_sync                 # mouse tracking is a mode of the library
    mov rax, [rbx + TM_menc]
    test rax, rax
    jz .Lm_no
    mov rdi, rax
    mov rsi, [rbx + TM_gt]
    call ghostty_mouse_encoder_setopt_from_terminal
    # GhosttyMouseEncoderSize at [rsp + 16], 40 bytes: the surface geometry
    # the encoder needs, with the synthetic 1024 px cell and no padding
    mov dword ptr [rsp + 16], 40
    mov eax, [rbx + TM_cols]
    shl eax, 10
    mov [rsp + 24], eax
    mov eax, [rbx + TM_rows]
    shl eax, 10
    mov [rsp + 28], eax
    mov dword ptr [rsp + 32], 1024      # cell_width
    mov dword ptr [rsp + 36], 1024      # cell_height
    mov dword ptr [rsp + 40], 0         # padding top/bottom/right/left
    mov dword ptr [rsp + 44], 0
    mov dword ptr [rsp + 48], 0
    mov dword ptr [rsp + 52], 0
    mov rdi, [rbx + TM_menc]
    mov esi, 2                  # GHOSTTY_MOUSE_ENCODER_OPT_SIZE
    lea rdx, [rsp + 16]
    call ghostty_mouse_encoder_setopt
    # a motion carries its held button; button 3 means no button
    # (any-motion tracking)
    mov rdi, [rbx + TM_menc]
    mov esi, 3                  # GHOSTTY_MOUSE_ENCODER_OPT_ANY_BUTTON_PRESSED
    lea rdx, [rip + g_ma_pressed]
    cmp r12d, 3
    jne 1f
    lea rdx, [rip + g_ma_none]
1:  call ghostty_mouse_encoder_setopt
    # termview dedups repeated cells before this call, so the encoder
    # need not bother
    mov rdi, [rbx + TM_menc]
    mov esi, 4                  # GHOSTTY_MOUSE_ENCODER_OPT_TRACK_LAST_CELL
    lea rdx, [rip + g_ma_none]
    call ghostty_mouse_encoder_setopt
    # fill the event: same numeric order for action, button mapping below
    mov rdi, [rbx + TM_mev]
    test rdi, rdi
    jz .Lm_no
    mov esi, r13d
    call ghostty_mouse_event_set_action
    mov rdi, [rbx + TM_mev]
    cmp r12d, 3
    je .Lm_clear
    # unn left/middle/right = 0/1/2, ghostty left/right/middle = 1/2/3
    # (wheel up/down 64/65 -> 4/5)
    test r12d, 0x40
    jz 2f
    mov esi, 4
    cmp r12d, 65
    jne .Lm_mb
    inc esi
    jmp .Lm_mb
2:  cmp r12d, 1
    jne 3f
    mov esi, 3
    jmp .Lm_mb
3:  cmp r12d, 2
    jne 4f
    mov esi, 2
    jmp .Lm_mb
4:  mov esi, 1
.Lm_mb:
    call ghostty_mouse_event_set_button
    jmp .Lm_after_btn
.Lm_clear:
    call ghostty_mouse_event_clear_button
.Lm_after_btn:
    # mods: ghostty shift 1, ctrl 2, alt 4, super 8
    mov r10d, [rsp]
    xor r11d, r11d
    test r10d, MOD_SHIFT
    jz 5f
    or r11d, 1
5:  test r10d, MOD_CTRL
    jz 6f
    or r11d, 2
6:  test r10d, MOD_ALT
    jz 7f
    or r11d, 4
7:  test r10d, MOD_SUPER
    jz 8f
    or r11d, 8
8:  mov rdi, [rbx + TM_mev]
    mov esi, r11d
    call ghostty_mouse_event_set_mods
    # position in pixels, centered in the cell: (col + 0.5) * 1024
    mov eax, r14d
    shl eax, 10
    or eax, 512
    mov [rsp], eax
    mov eax, r15d
    shl eax, 10
    or eax, 512
    mov [rsp + 4], eax
    mov rdi, [rbx + TM_mev]
    movq xmm0, qword ptr [rsp]
    call ghostty_mouse_event_set_position
    # encode; nothing written means the event is not for the program
    mov rdi, [rbx + TM_menc]
    mov rsi, [rbx + TM_mev]
    lea rdx, [rsp + 64]
    mov ecx, 32
    lea r8, [rsp + 56]
    call ghostty_mouse_encoder_encode
    test eax, eax
    jnz .Lm_no
    mov rdx, [rsp + 56]
    test rdx, rdx
    jz .Lm_no
    lea rdi, [rbx + TM_out]
    lea rsi, [rsp + 64]
    call sb_push
    mov eax, 1
    EPILOGUE
.Lm_no:
    xor eax, eax
    EPILOGUE

.section .rodata
# any-button state for the mouse encoder (motion with no button vs a held one)
g_ma_none: .byte 0
g_ma_pressed: .byte 1
# ascii character (0x20..0x7e) -> physical key id, US layout (shifted symbols map
# to the key they sit on); word per entry starting at 0x20
.p2align 1
gkey_ascii:
    .word 63, 7, 48, 9, 10, 11, 13, 48
    .word 15, 6, 14, 16, 5, 46, 47, 50
    .word 6, 7, 8, 9, 10, 11, 12, 13
    .word 14, 15, 49, 49, 5, 16, 47, 50
    .word 8, 20, 21, 22, 23, 24, 25, 26
    .word 27, 28, 29, 30, 31, 32, 33, 34
    .word 35, 36, 37, 38, 39, 40, 41, 42
    .word 43, 44, 45, 3, 2, 4, 12, 46
    .word 1, 20, 21, 22, 23, 24, 25, 26
    .word 27, 28, 29, 30, 31, 32, 33, 34
    .word 35, 36, 37, 38, 39, 40, 41, 42
    .word 43, 44, 45, 3, 2, 4, 1

# keysym -> physical key id pairs, -1 terminated (printable keys never
# reach this list)
.p2align 2
gkey_syms:
    .long 0xff08, 53
    .long 0xff09, 64
    .long 0xff0d, 58
    .long 0xff1b, 120
    .long 0xff50, 71
    .long 0xff51, 76
    .long 0xff52, 78
    .long 0xff53, 77
    .long 0xff54, 75
    .long 0xff55, 74
    .long 0xff56, 73
    .long 0xff57, 69
    .long 0xff63, 72
    .long 0xff8d, 97
    .long 0xffb0, 80
    .long 0xffb1, 81
    .long 0xffb2, 82
    .long 0xffb3, 83
    .long 0xffb4, 84
    .long 0xffb5, 85
    .long 0xffb6, 86
    .long 0xffb7, 87
    .long 0xffb8, 88
    .long 0xffb9, 89
    .long 0xffaa, 90
    .long 0xffab, 104
    .long 0xffac, 108
    .long 0xffad, 107
    .long 0xffae, 95
    .long 0xffaf, 96
    .long 0xffbd, 98
    .long 0xff95, 114
    .long 0xff96, 112
    .long 0xff97, 109
    .long 0xff98, 111
    .long 0xff99, 110
    .long 0xff9a, 118
    .long 0xff9b, 119
    .long 0xff9c, 115
    .long 0xff9d, 113
    .long 0xff9e, 116
    .long 0xff9f, 117
    .long 0xffbe, 121
    .long 0xffbf, 122
    .long 0xffc0, 123
    .long 0xffc1, 124
    .long 0xffc2, 125
    .long 0xffc3, 126
    .long 0xffc4, 127
    .long 0xffc5, 128
    .long 0xffc6, 129
    .long 0xffc7, 130
    .long 0xffc8, 131
    .long 0xffc9, 132
    .long 0xffca, 133
    .long 0xffcb, 134
    .long 0xffcc, 135
    .long 0xffcd, 136
    .long 0xffce, 137
    .long 0xffcf, 138
    .long 0xffd0, 139
    .long 0xffd1, 140
    .long 0xffd2, 141
    .long 0xffd3, 142
    .long 0xffd4, 143
    .long 0xffd5, 144
    .long 0xfe20, 64
    .long 0xffe1, 61
    .long 0xffe2, 62
    .long 0xffe3, 56
    .long 0xffe4, 57
    .long 0xffe5, 54
    .long 0xffe7, 59
    .long 0xffe8, 60
    .long 0xffeb, 59
    .long 0xffec, 60
    .long 0xff14, 149
    .long 0xff13, 150
    .long 0xff61, 148
    .long -1, -1

.text

