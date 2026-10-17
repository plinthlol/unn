# ---- headless platform: run the app with no compositor at all ----
# A drop-in back end for the g_plat vtable (see loop.s) that renders into an
# offscreen buffer instead of a Wayland window, used by tests and scripted
# runs. headless_init installs it: every hook not implemented is pointed at
# hl_nop first, then the interesting ones (timeout, draw, clipboard, move,
# minimize, maximize) are filled in with real handlers below; P_resize stays
# a nop, and headless_resize is called directly by headless_init and the
# control socket instead.
# The window always reports CSD (unn draws its own decorations) and
# g_dirty drives the event loop: hl_timeout returns immediately when
# another frame is wanted, and blocks forever otherwise.
# Test hooks: g_hl_moves, g_hl_minimized, g_hl_frames count what the
# platform asked for, g_hl_grab records that a window move took the pointer.
.include "unn.inc"

.bss
.p2align 3
# the offscreen framebuffer, one 32-bit XRGB pixel word per cell, and the
# app-owned clip text (hl_clip_set / hl_clip_get round-trip through it)
hbuf: .quad 0
hw: .long 0
hh: .long 0
.p2align 3
hclip: .zero SB_SIZE
# window requests recorded for tests: a move takes the pointer like a
# compositor would (g_hl_grab) and is counted in g_hl_moves
.globl g_hl_grab, g_hl_moves, g_hl_minimized, g_hl_frames
g_hl_grab: .long 0
g_hl_moves: .long 0
g_hl_minimized: .long 0
g_hl_frames: .long 0            # frames drawn, for tests

.text

# headless_init(w=edi, h=esi): install the headless vtable and size the
# buffer. Everything in g_plat starts as hl_nop, then the handlers this
# platform actually implements are set one by one (note P_timeout, P_draw,
# clipboard and the window verbs), g_headless and g_csd are asserted so the
# app skips pointer-driven CSD logic, and the buffer is allocated.
FN headless_init
    PROLOGUE
    mov r12d, edi
    mov r13d, esi
    lea rax, [rip + hl_nop]
    lea rdi, [rip + g_plat]
    mov ecx, PLAT_SIZE / 8
1:  mov [rdi], rax
    add rdi, 8
    dec ecx
    jnz 1b
    lea rax, [rip + hl_timeout]
    mov [rip + g_plat + P_timeout], rax
    lea rax, [rip + hl_draw]
    mov [rip + g_plat + P_draw], rax
    lea rax, [rip + hl_clip_set]
    mov [rip + g_plat + P_clip_set], rax
    lea rax, [rip + hl_clip_get]
    mov [rip + g_plat + P_clip_get], rax
    lea rax, [rip + hl_move]
    mov [rip + g_plat + P_move], rax
    lea rax, [rip + hl_minimize]
    mov [rip + g_plat + P_minimize], rax
    lea rax, [rip + hl_maximize]
    mov [rip + g_plat + P_maximize], rax
    mov dword ptr [rip + g_headless], 1
    mov dword ptr [rip + g_csd], 1
    mov edi, r12d
    mov esi, r13d
    call headless_resize
    EPILOGUE

# headless_resize(w=edi, h=esi): (re)allocate the XRGB buffer and tell the
# app, like a compositor configure would. Marks the frame dirty so the
# event loop draws into the new size once.
FN headless_resize
    push rbx
    push r12
    push r13
    mov r12d, edi
    mov r13d, esi
    mov [rip + hw], edi
    mov [rip + hh], esi
    mov rdi, [rip + hbuf]
    call mem_free
    mov eax, r12d
    imul eax, r13d
    lea rdi, [rax*4]
    call mem_alloc
    mov [rip + hbuf], rax
    mov edi, r12d
    mov esi, r13d
    call app_on_resize
    mov dword ptr [rip + g_dirty], 1
    pop r13
    pop r12
    pop rbx
    ret

# hl_nop: the fill-in for g_plat hooks this platform does not implement.
# Just returns, which is the whole point: unimplemented verbs are free.
hl_nop:
    ret

# hl_move: a window move request. The compositor grabs the pointer on such
# a click, and tests may want to know that, so record it (and count it).
hl_move:
    inc dword ptr [rip + g_hl_moves]
    mov dword ptr [rip + g_hl_grab], 1
    ret

# hl_minimize: a minimize request, counted for tests.
hl_minimize:
    inc dword ptr [rip + g_hl_minimized]
    ret

# hl_maximize: toggles the maximized window state bit, like a tiling
# compositor would flip it, and redraws.
hl_maximize:
    xor dword ptr [rip + g_win_states], 1
    mov dword ptr [rip + g_dirty], 1
    ret

# hl_timeout(): 0 ms (wake now) when the last render asked for another
# frame (g_dirty set), otherwise -1 (sleep until the next input), so the
# event loop idles like a real display connection would.
hl_timeout:
    xor eax, eax
    cmp dword ptr [rip + g_dirty], 0
    jne 1f
    mov eax, -1
1:  ret

# hl_draw(): the platform's render callback. Points the canvas at the
# offscreen buffer (stride equals width), clears the dirty flag, counts the
# frame via g_hl_frames, then calls app_render.
hl_draw:
    push rbx
    mov rdi, [rip + hbuf]
    mov esi, [rip + hw]
    mov edx, [rip + hh]
    mov ecx, esi
    call gfx_set_target
    mov dword ptr [rip + g_dirty], 0
    inc dword ptr [rip + g_hl_frames]
    call app_render
    pop rbx
    ret

# hl_clip_set(text=rdi, len=rsi): remember the clipboard contents in hclip.
hl_clip_set:
    push rbx
    push r12
    push r13
    mov r12, rdi
    mov r13, rsi
    lea rdi, [rip + hclip]
    call sb_clear
    lea rdi, [rip + hclip]
    mov rsi, r12
    mov rdx, r13
    call sb_push
    pop r13
    pop r12
    pop rbx
    ret

# hl_clip_get(): paste the stored text: tail-calls app_on_paste with its
# bytes, and returns without doing anything when the buffer is empty. Paste
# is synchronous because there is no foreign selection owner to wait for.
hl_clip_get:
    mov rdi, [rip + hclip + SB_ptr]
    mov rsi, [rip + hclip + SB_len]
    test rdi, rdi
    jz 1f
    jmp app_on_paste
1:  ret
