# scripted control channel, for tests and scripts (--script runs a file through
# control_run_script, --control listens on a unix socket via control_listen).
# One command per line, whitespace separated; # comments the line out; unknown
# commands answer with the error output. Implemented commands (ctl_table pairs
# each name with its handler):
#   key COMBO | type TEXT | move X Y | click X Y [right|middle|shift|ctrl]
#   tap X Y | down | up | up-down | scroll DY [MODS] | scroll-x DX
#   open PATH | cmd NAME | shot FILE.ppm | resize W H | focus out|in
#   wait MS | wait-term TEXT | quit | echo TEXT
#   print-state | print-term | print-link | print-term-cell R C
#   print-shape | print-window | print-cursor SHAPE SIZE | print-frames
#   print-toast
# Handlers share conventions: rbx = the rest of the line after the command,
# r12 = its length (next_arg/next_int consume parsed tokens), output accumulates
# in `out` as sb_* calls, and each returns the control_exec status.
.include "unn.inc"

.bss
.p2align 3
out: .zero SB_SIZE              # this command's textual output, also the test's stdout source
cbuf: .zero SB_SIZE             # the socket client's bytes not consumed as lines yet
tbuf: .zero SB_SIZE             # wait-term's screen text workspace
oc_busy: .long 0                # a command that runs the loop (wait-term) is in flight
oc_eof: .long 0                 # the client closed its side while oc_busy, close when done
addr: .zero 110                 # sockaddr_un buffer (sun_path is 108 on Linux)
.globl g_headless
g_headless: .long 0             # set by the headless platform: draw frames synchronously

.text

# arg helpers built over next_word. rbx = rest pointer and r12 = rest length are
# the convention every c_* handler lives by; next_arg yields rax/rdx as the
# token, next_int parses it as u64 with an optional leading minus.
next_arg:
    mov rdi, rbx
    mov rsi, r12
    call next_word
    add rbx, rcx
    sub r12, rcx
    ret

next_int:
    call next_arg
    push rbx
    mov rdi, rax
    mov rsi, rdx
    xor ebx, ebx
    test rsi, rsi
    jz 1f
    cmp byte ptr [rdi], '-'
    jne 1f
    inc rdi
    dec rsi
    mov ebx, 1
1:  call parse_u64
    test ebx, ebx
    jz 2f
    neg rax
2:  pop rbx
    ret

# flush_frame(): make sure the last command's effect is visible. Headless
# drawing is synchronous, so it draws the pending frame right here.
flush_frame:
    cmp dword ptr [rip + g_headless], 0
    je 1f
    cmp dword ptr [rip + g_dirty], 0
    je 1f
    PCALL P_draw
1:  ret

# emit_key(keysym, mods): feed app_on_key synthesizing the character the way a
# real keyboard event arrives: printable keysyms carry themselves as cp, and a
# shifted letter is reported as its capital on an unshifted key. rbx/r12/r13
# hold keysym, cp and mods through the call.
emit_key:
    push rbx
    push r12
    push r13
    mov ebx, edi
    mov r12d, esi
    xor r13d, r13d
    cmp ebx, 0x20
    jb 1f
    cmp ebx, 0x7e
    ja 1f
    mov r13d, ebx
    # a shifted letter goes out as its capital: cp and keysym both minus 32
    test r12d, MOD_SHIFT
    jz 1f
    lea eax, [rbx - 'a']
    cmp eax, 25
    ja 1f
    sub r13d, 32
    sub ebx, 32
1:  mov edi, ebx
    mov esi, r13d
    mov edx, r12d
    call app_on_key
    pop r13
    pop r12
    pop rbx
    ret

# control_exec(line, len) -> eax 0 done, 1 quit, -1 unknown command.
# rdi/rsi the text of one line. The first token selects a handler from
# ctl_table; the rest of the line (its leading blanks trimmed for type/echo)
# is the handler's job in rbx/r12. After any handler, term_frame_now and
# flush_frame give the command a frame showing all output so far.
FN control_exec
    PROLOGUE 32
    mov rbx, rdi
    mov r12, rsi
    lea rdi, [rip + out]
    call sb_clear
    call next_arg
    test rdx, rdx
    jz .Lce_ok
    mov r13, rax
    mov r14, rdx
    cmp byte ptr [r13], '#'
    je .Lce_ok
    # trim leading blank of the rest (for type/echo)
    mov rdi, rbx
    mov rsi, r12
    call trim
    mov rbx, rax
    mov r12, rdx
    lea r15, [rip + ctl_table]
1:  mov rdx, [r15]
    test rdx, rdx
    jz .Lce_unknown
    mov rdi, r13
    mov rsi, r14
    call str_eq_cstr
    test eax, eax
    jnz 2f
    add r15, 16
    jmp 1b
2:  call [r15 + 8]
    push rax
    push rax          # rax lives through the two calls; the second push only
                      # keeps the stack 16-byte aligned for them
    call term_frame_now         # a command ends with a frame that shows all output so far
    call flush_frame
    pop rax
    pop rax
    EPILOGUE
.Lce_ok:
    xor eax, eax
    EPILOGUE
.Lce_unknown:
    lea rdi, [rip + out]
    lea rsi, [rip + .Lunknown]
    call sb_push_cstr
    mov rax, -1
    EPILOGUE

# c_key COMBO: parse_combo resolves the keysym and mods, emit_key posts them;
# a combo it rejects is dropped and still answers done (0).
c_key:
    mov rdi, rbx
    mov rsi, r12
    call parse_combo
    test eax, eax
    jz 1f
    mov edi, eax
    mov esi, edx
    call emit_key
1:  xor eax, eax
    ret

# c_type TEXT: feed the rest of the line as if typed, UTF-8 decoding one
# codepoint at a time and one key event each; codepoints over 0x7e carry the
# 0x1000000 bit as the compose table's emit does, and each key is followed by
# a frame so the screen stays current
c_type:
    push r13
    push r14
    sub rsp, 8
    xor r13d, r13d
1:  cmp r13, r12
    jae 2f
    lea rdi, [rbx + r13]
    mov rsi, r12
    sub rsi, r13
    call utf8_decode
    add r13, rdx
    mov r14d, eax
    mov edi, eax
    cmp eax, 0x7e
    jbe 3f
    or edi, 0x1000000
3:  mov esi, r14d
    xor edx, edx
    call app_on_key
    call flush_frame
    jmp 1b
2:  add rsp, 8
    pop r14
    pop r13
    xor eax, eax
    ret

# c_move X Y / c_click X Y [opt] / c_tap X Y: pointer events in pixels. click
# posts a move, then a left (or named) button press and release; the option
# word names right/middle or shift/ctrl held, which click_mods puts on both
# edges. tap posts press and release while leaving the pointer where it was,
# so no frame ever sees it hover over the target.
c_move:
    call next_int
    push rax
    call next_int
    pop rdi
    mov esi, eax
    call app_on_motion
    xor eax, eax
    ret

c_click:
    call next_int
    push rax
    call next_int
    pop rdi
    push rdi
    push rax
    mov esi, eax
    call app_on_motion
    call flush_frame
    call next_arg
    mov dword ptr [rip + click_mods], 0
    mov r13d, BTN_LEFT
    test rdx, rdx
    jz 1f
    # shift: a left click with Shift held, pressed and released
    cmp byte ptr [rax], 's'
    jne 21f
    mov dword ptr [rip + click_mods], MOD_SHIFT
    jmp 1f
    # ctrl: Ctrl+click
21: cmp byte ptr [rax], 'c'
    jne 2f
    mov dword ptr [rip + click_mods], MOD_CTRL
    jmp 1f
2:  mov r13d, BTN_RIGHT
    cmp byte ptr [rax], 'r'
    je 1f
    mov r13d, BTN_MIDDLE
    cmp byte ptr [rax], 'm'
    je 1f
    mov r13d, BTN_LEFT
1:  mov edi, r13d
    mov esi, 1
    mov edx, [rip + click_mods]
    call app_on_button
    call flush_frame
    mov edi, r13d
    mov esi, [rip + click_mods]
    call release
    pop rax
    pop rax
    xor eax, eax
    ret

# tap x y: move, press, release and move back, all inside this one handler: a
# synthetic mouse faster than any frame, so no frame ever sees the pointer
# over x y and the pointer ends up where it was
c_tap:
    push r13
    push r14
    push r15
    mov r13d, [rip + g_mx]
    mov r14d, [rip + g_my]
    call next_int
    mov r15d, eax
    call next_int
    mov edi, r15d
    mov esi, eax
    call app_on_motion
    mov edi, BTN_LEFT
    mov esi, 1
    xor edx, edx
    call app_on_button
    mov edi, BTN_LEFT
    xor esi, esi
    xor edx, edx
    call app_on_button
    mov edi, r13d
    mov esi, r14d
    call app_on_motion
    call flush_frame
    # the button came up before the frame: a move asked for now has no release to take
    mov dword ptr [rip + g_hl_grab], 0
    pop r15
    pop r14
    pop r13
    xor eax, eax
    ret

# release(button, mods): post the button's release through app_on_button
# (state 0, mods in edx), unless a window move took the pointer -- the
# headless platform records that grab (hl_move), and the grab eats the
# release; c_tap clears it once its own inline release and frame are done.
release:
    cmp dword ptr [rip + g_hl_grab], 0
    je 1f
    mov dword ptr [rip + g_hl_grab], 0
    ret
1:  mov edx, esi
    xor esi, esi
    jmp app_on_button

# c_down: the left button pressed, no mods
c_down:
    mov edi, BTN_LEFT
    mov esi, 1
    xor edx, edx
    call app_on_button
    xor eax, eax
    ret

# up-down: a release and the next press before one frame, as a busy event queue delivers them
c_updown:
    mov edi, BTN_LEFT
    xor esi, esi
    xor edx, edx
    call app_on_button
    mov edi, BTN_LEFT
    mov esi, 1
    xor edx, edx
    call app_on_button
    xor eax, eax
    ret

# c_up: the left button released, no mods
c_up:
    mov edi, BTN_LEFT
    xor esi, esi
    call release
    xor eax, eax
    ret

# print-cursor SHAPE SIZE: which cursor image the theme lookup picks
c_print_cursor:
    push r13
    push r14
    sub rsp, 8
    call next_int
    mov r13d, eax
    call next_int
    mov r14d, eax
    mov edi, r13d
    mov esi, r14d
    lea rdx, [rip + pc_xc]
    call xcursor_load
    test eax, eax
    jz 1f
    lea rdi, [rip + out]
    mov rsi, [rip + g_xcursor_found + SB_ptr]
    call sb_push_cstr
    jmp 2f
1:  mov edi, r13d
    mov esi, r14d
    lea rdx, [rip + pc_xc]
    call xcursor_builtin
    lea rdi, [rip + out]
    lea rsi, [rip + .Ls_builtin]
    call sb_push_cstr
2:  lea rdi, [rip + out]
    mov esi, ' '
    call sb_push_byte
    lea rdi, [rip + out]
    mov esi, [rip + pc_xc + XC_w]
    call sb_push_u64
    lea rdi, [rip + out]
    mov esi, 'x'
    call sb_push_byte
    lea rdi, [rip + out]
    mov esi, [rip + pc_xc + XC_h]
    call sb_push_u64
    lea rdi, [rip + out]
    lea rsi, [rip + .Ls_hot]
    call sb_push_cstr
    lea rdi, [rip + out]
    mov esi, [rip + pc_xc + XC_xhot]
    call sb_push_u64
    lea rdi, [rip + out]
    mov esi, ','
    call sb_push_byte
    lea rdi, [rip + out]
    mov esi, [rip + pc_xc + XC_yhot]
    call sb_push_u64
    lea rdi, [rip + out]
    mov esi, 10
    call sb_push_byte
    mov rdi, [rip + pc_xc + XC_file]
    call mem_free
    add rsp, 8
    pop r14
    pop r13
    xor eax, eax
    ret

# print-window: window requests seen by the headless platform
c_print_window:
    lea rdi, [rip + out]
    lea rsi, [rip + .Ls_moves]
    call sb_push_cstr
    lea rdi, [rip + out]
    mov esi, [rip + g_hl_moves]
    call sb_push_u64
    lea rdi, [rip + out]
    lea rsi, [rip + .Ls_maximized]
    call sb_push_cstr
    lea rdi, [rip + out]
    mov esi, [rip + g_win_states]
    and esi, 1
    call sb_push_u64
    lea rdi, [rip + out]
    lea rsi, [rip + .Ls_minimized]
    call sb_push_cstr
    lea rdi, [rip + out]
    mov esi, [rip + g_hl_minimized]
    call sb_push_u64
    lea rdi, [rip + out]
    lea rsi, [rip + .Ls_quit]
    call sb_push_cstr
    lea rdi, [rip + out]
    mov esi, [rip + g_quit]
    call sb_push_u64
    lea rdi, [rip + out]
    lea rsi, [rip + .Ls_csd]
    call sb_push_cstr
    lea rdi, [rip + out]
    mov esi, [rip + g_csd]
    call sb_push_u64
    lea rdi, [rip + out]
    mov esi, 10
    call sb_push_byte
    xor eax, eax
    ret

# print-shape: the current cursor shape (g_cursor)
c_print_shape:
    lea rdi, [rip + out]
    mov esi, [rip + g_cursor]
    call sb_push_u64
    lea rdi, [rip + out]
    mov esi, 10
    call sb_push_byte
    xor eax, eax
    ret

# scroll dy [mods]: the wheel, with modifiers held as a key combination names them (ctrl, shift+alt)
c_scroll:
    call next_int
    push rax
    push rax
    call next_arg
    xor ecx, ecx
    test rdx, rdx
    jz 1f
    mov rdi, rax
    mov rsi, rdx
    call parse_combo
    mov ecx, edx
1:  pop rax
    pop rax
    xor edi, edi
    mov esi, eax
    mov edx, ecx
    call app_on_scroll
    xor eax, eax
    ret

# scroll-x dx: a sideways wheel or trackpad
c_scroll_x:
    call next_int
    mov edi, eax
    xor esi, esi
    xor edx, edx
    call app_on_scroll
    xor eax, eax
    ret

# open PATH: app_open_path on a mem_dup of the rest of the line, freed after
c_open:
    mov rdi, rbx
    mov rsi, r12
    call mem_dup
    push rax
    push rax
    mov rdi, rax
    call app_open_path
    pop rdi
    pop rdi
    call mem_free
    xor eax, eax
    ret

# c_cmd NAME: run the handler cmd_find finds for the name, then mark dirty so
# a frame shows it; an unknown name returns -1 (error).
c_cmd:
    mov rdi, rbx
    mov rsi, r12
    call cmd_find
    test rax, rax
    jz 1f
    call [rax + CMD_fn]
    mov dword ptr [rip + g_dirty], 1
    xor eax, eax
    ret
1:  mov rax, -1
    ret

# c_shot PATH: name the path in g_shot_path and mark dirty; the next drawn
# frame is written by shot_write (headless draws one right here), and
# app_render clears g_shot_path once it has been used.
c_shot:
    mov rdi, rbx
    mov rsi, r12
    call mem_dup
    mov [rip + g_shot_path], rax
    mov dword ptr [rip + g_dirty], 1
    cmp dword ptr [rip + g_headless], 0
    je 1f
    PCALL P_draw
1:  xor eax, eax
    ret

# wait-term TEXT: until the current terminal's screen shows TEXT (10 s at most): a shell's prompt,
# or what a command printed, rather than a guess at how long it takes
c_wait_term:
    push r13
    push r14
    push r15
    mov r14, rbx
    mov r15, r12
    call time_ms
    lea r13, [rax + 10000]
1:  lea rdi, [rip + tbuf]
    call sb_clear
    lea rdi, [rip + tbuf]
    call term_dump_current
    mov rsi, [rip + tbuf + SB_len]
    cmp rsi, r15
    jb 3f
    mov rdi, [rip + tbuf + SB_ptr]
    mov rdx, r14
    mov rcx, r15
    call str_find
    test rax, rax
    jns 2f
3:  call time_ms
    cmp rax, r13
    jae 2f
    mov edi, 20
    call loop_poll
    call app_tick
    call flush_frame
    jmp 1b
2:  pop r15
    pop r14
    pop r13
    xor eax, eax
    ret

# wait ms: run file watches, programs' output and timers for that long, drawing frames as they are
# due, as the event loop does
c_wait:
    push r13
    push r14
    push r15
    call next_int
    mov r13, rax
    call time_ms
    add r13, rax
1:  call time_ms
    mov r14, r13
    sub r14, rax
    jle 2f
    call app_timeout
    cmp eax, -1
    je 3f
    cmp rax, r14
    jae 3f
    mov r14d, eax
3:  mov edi, r14d
    call loop_poll
    call app_tick
    call flush_frame
    jmp 1b
2:  xor edi, edi
    call loop_poll
    call app_tick
    pop r15
    pop r14
    pop r13
    xor eax, eax
    ret

# print-frames: the frames the headless platform drew since the last
# print-frames, read and then reset to 0
c_print_frames:
    lea rdi, [rip + out]
    lea rsi, [rip + .Ls_frames]
    call sb_push_cstr
    lea rdi, [rip + out]
    mov esi, [rip + g_hl_frames]
    call sb_push_u64
    mov dword ptr [rip + g_hl_frames], 0
    lea rdi, [rip + out]
    mov esi, 10
    call sb_push_byte
    xor eax, eax
    ret

# print-state: "focus=F theme=unn term=N [hidden]"
c_print_state:
    PROLOGUE
    lea rdi, [rip + out]
    lea rsi, [rip + .Ls_focus]
    call sb_push_cstr
    lea rdi, [rip + out]
    mov esi, [rip + g_focus]
    call sb_push_u64
    lea rdi, [rip + out]
    lea rsi, [rip + .Ls_theme]
    call sb_push_cstr
    lea rdi, [rip + out]
    lea rsi, [rip + .Ls_unn]
    call sb_push_cstr
    call term_count
    test rax, rax
    jz 1f
    mov rbx, rax
    lea rdi, [rip + out]
    lea rsi, [rip + .Ls_term]
    call sb_push_cstr
    lea rdi, [rip + out]
    mov rsi, rbx
    call sb_push_u64
    cmp dword ptr [rip + g_term_open], 0
    jne 1f
    lea rdi, [rip + out]
    lea rsi, [rip + .Ls_hidden]
    call sb_push_cstr
1:  lea rdi, [rip + out]
    mov esi, 10
    call sb_push_byte
    EPILOGUE

# focus out|in: the window loses or gets the keyboard, as a platform reports it
c_focus:
    call next_arg
    xor edi, edi
    test rdx, rdx
    jz 1f
    cmp byte ptr [rax], 'i'
    jne 1f
    mov edi, 1
1:  call app_on_focus
    xor eax, eax
    ret

# print-toast: "toast=" and the toast text while the toast is still up
# (time_ms below g_toast_until), else no value
c_print_toast:
    lea rdi, [rip + out]
    lea rsi, [rip + .Ls_toast]
    call sb_push_cstr
    call time_ms
    cmp rax, [rip + g_toast_until]
    jae 1f
    lea rdi, [rip + out]
    lea rsi, [rip + g_toast]
    call sb_push_cstr
1:  lea rdi, [rip + out]
    mov esi, 10
    call sb_push_byte
    xor eax, eax
    ret

# print-term: the screen of the current terminal
c_print_term:
    lea rdi, [rip + out]
    call term_dump_current
    xor eax, eax
    ret

# print-link: the terminal's link under the pointer, "link=" when there is none
c_print_link:
    lea rdi, [rip + out]
    call term_link_dump
    xor eax, eax
    ret

# print-term-cell ROW COL: "X Y", the middle of that cell of the terminal
c_print_term_cell:
    call next_int
    push rax
    call next_int
    pop rdi
    mov esi, eax
    lea rdx, [rip + out]
    call term_cell_dump
    xor eax, eax
    ret

# c_resize W H: headless_resize(w, h) -- reallocate the headless framebuffer
# and deliver an app_on_resize.
c_resize:
    call next_int
    push rax
    call next_int
    pop rdi
    mov esi, eax
    call headless_resize
    xor eax, eax
    ret

# c_quit: status 1, the quit status control_run_script and control_listen
# both stop on.
c_quit:
    mov eax, 1
    ret

# c_echo TEXT: the rest of the line plus a newline, pushed to out.
c_echo:
    lea rdi, [rip + out]
    mov rsi, rbx
    mov rdx, r12
    call sb_push
    lea rdi, [rip + out]
    mov esi, 10
    call sb_push_byte
    xor eax, eax
    ret

# control_run_script(path): read the file whole, run each newline-delimited
# line through control_exec, and write each command's `out` to stdout with
# the command; a quit status (1) ends the run early, and an unreadable file
# returns 1.
FN control_run_script
    PROLOGUE
    call file_read_all
    test rax, rax
    jz .Lrs_fail
    mov r12, rax
    mov r13, rdx
    xor r14d, r14d
.Lrs_line:
    cmp r14, r13
    jae .Lrs_done
    mov r15, r14
1:  cmp r15, r13
    jae 2f
    cmp byte ptr [r12 + r15], 10
    je 2f
    inc r15
    jmp 1b
2:  lea rdi, [r12 + r14]
    mov rsi, r15
    sub rsi, r14
    call control_exec
    mov rbx, rax
    mov rdi, 1
    mov rsi, [rip + out + SB_ptr]
    mov rdx, [rip + out + SB_len]
    test rdx, rdx
    jz 3f
    call write_all
3:  cmp rbx, 1
    je .Lrs_done
    lea r14, [r15 + 1]
    jmp .Lrs_line
.Lrs_done:
    xor eax, eax
    EPILOGUE
.Lrs_fail:
    mov eax, 1
    EPILOGUE

# control_listen(path): serve control commands on a unix socket at path --
# unlink a stale one, bind, and watch POLLIN for on_accept. One command per
# line; each reply is the command's output then "ok\n" or "error\n". On
# WINDOWS, or when path will not fit sun_path or bind fails, die.
FN control_listen
.ifdef WINDOWS
    lea rdi, [rip + .Lwindows_control]
    jmp die
.endif
    PROLOGUE
    mov rbx, rdi
    # sun_path holds 104 bytes on macOS, 108 on Linux
    call strlen
    cmp rax, 103
    jbe 1f
    lea rdi, [rip + .Llong_path]
    call die
1:  mov edi, AF_UNIX
    mov esi, SOCK_STREAM | SOCK_CLOEXEC | SOCK_NONBLOCK
    xor edx, edx
    SYS SYS_socket
    test rax, rax
    js 9f
    mov [rip + lsock], eax
    mov rdi, rbx
    SYS SYS_unlink
    lea rdi, [rip + addr]
    mov word ptr [rdi], AF_UNIX
    add rdi, 2
    mov rsi, rbx
    call cstr_copy
    mov edi, [rip + lsock]
    lea rsi, [rip + addr]
    mov edx, 110
    SYS SYS_bind
    test rax, rax
    jns 2f
    lea rdi, [rip + .Lno_listen]
    call die
2:  mov edi, [rip + lsock]
    mov esi, 4
    SYS SYS_listen
    mov edi, [rip + lsock]
    mov esi, POLLIN
    lea rdx, [rip + on_accept]
    xor ecx, ecx
    call watch_add
9:  EPILOGUE

on_accept:
    push rbx
    mov edi, [rip + lsock]
    xor esi, esi
    xor edx, edx
    mov r10d, SOCK_CLOEXEC
    SYS SYS_accept4
    test rax, rax
    js 9f
    mov ebx, eax
    # while the client's command waits, the new one waits for it to finish
    cmp dword ptr [rip + oc_busy], 0
    je 2f
    mov edi, [rip + oc_next]
    mov [rip + oc_next], ebx
    test edi, edi
    js 9f
    SYS SYS_close
    jmp 9f
2:  mov edi, ebx
    call oc_install
9:  pop rbx
    ret

# oc_install(fd): the client from now on; one at a time, the previous one is dropped
oc_install:
    push rbx
    mov ebx, edi
    mov edi, [rip + csock]
    test edi, edi
    js 1f
    call watch_remove
    mov edi, [rip + csock]
    SYS SYS_close
1:  mov [rip + csock], ebx
    lea rdi, [rip + cbuf]
    call sb_clear
    mov edi, ebx
    mov esi, POLLIN
    lea rdx, [rip + on_client]
    xor ecx, ecx
    call watch_add
9:  pop rbx
    ret

on_client:
    PROLOGUE
    mov ebx, edi
    lea rdi, [rip + cbuf]
    mov esi, 4096
    call sb_reserve
    mov edi, ebx
    mov rsi, rax
    mov edx, 4096
    SYS SYS_read
    test rax, rax
    jle 7f
    add [rip + cbuf + SB_len], rax
    # a command that waits (wait-term) runs the loop, which re-enters here:
    # bytes read while it runs only join cbuf, and are run once it is done
    cmp dword ptr [rip + oc_busy], 0
    jne 9f
    mov dword ptr [rip + oc_busy], 1
.Loc_lines:
    mov edi, [rip + oc_next]
    test edi, edi
    jns .Loc_next
    mov r12, [rip + cbuf + SB_ptr]
    mov r13, [rip + cbuf + SB_len]
    xor ecx, ecx
1:  cmp rcx, r13
    jae 8f
    cmp byte ptr [r12 + rcx], 10
    je 2f
    inc rcx
    jmp 1b
2:  mov r14, rcx
    mov rdi, r12
    mov rsi, rcx
    call control_exec
    mov r15, rax
    # reply: output then ok / error
    mov edi, ebx
    mov rsi, [rip + out + SB_ptr]
    mov rdx, [rip + out + SB_len]
    test rdx, rdx
    jz 3f
    call write_all
3:  lea rsi, [rip + .Lok]
    mov edx, 3
    test r15, r15
    jns 4f
    lea rsi, [rip + .Lerror]
    mov edx, 6
4:  mov edi, ebx
    call write_all
    cmp r15, 1
    jne 5f
    mov dword ptr [rip + g_quit], 1
5:  # drop the processed line
    mov rdi, [rip + cbuf + SB_ptr]
    lea rsi, [rdi + r14 + 1]
    mov rdx, [rip + cbuf + SB_len]
    sub rdx, r14
    dec rdx
    mov [rip + cbuf + SB_len], rdx
    call memmove
    jmp .Loc_lines
8:  mov dword ptr [rip + oc_busy], 0
    cmp dword ptr [rip + oc_eof], 0
    je 9f
    mov dword ptr [rip + oc_eof], 0
    jmp .Loc_close
7:  cmp dword ptr [rip + oc_busy], 0
    je .Loc_close
    # the client left while a command waits: close when it is done
    mov dword ptr [rip + oc_eof], 1
    mov edi, ebx
    call watch_remove
    jmp 9f
.Loc_close:
    mov edi, ebx
    call watch_remove
    mov edi, ebx
    SYS SYS_close
    mov dword ptr [rip + csock], -1
9:  EPILOGUE
    # a client came while a command waited: it replaces this one
.Loc_next:
    mov dword ptr [rip + oc_next], -1
    mov dword ptr [rip + oc_busy], 0
    mov dword ptr [rip + oc_eof], 0
    call oc_install
    EPILOGUE

.section .rodata
.Llong_path: .asciz "unn: the control socket path is too long (at most 103 bytes)"
.Lno_listen: .asciz "unn: cannot create the control socket"
.Lunknown: .asciz "unknown command\n"
.Leod: .asciz "\n<eod>\n"
.Lok: .ascii "ok\n"
.Lerror: .ascii "error\n"
.Lnone: .asciz "none"
.Ls_tabs: .asciz "tabs="
.Ls_active: .asciz " active="
.Ls_line: .asciz " line="
.Ls_col: .asciz " col="
.Ls_sel: .asciz " sel="
.Ls_dirty: .asciz " dirty="
.Ls_lang: .asciz " lang="
.Ls_focus: .asciz " focus="
.Ls_vim: .asciz " vim="
.Ls_theme: .asciz " theme="
.Ls_unn: .asciz "unn"
.Lc_key: .asciz "key"
.Lc_type: .asciz "type"
.Lc_move: .asciz "move"
.Lc_click: .asciz "click"
.Lc_tap: .asciz "tap"
.Lc_down: .asciz "down"
.Lc_updown: .asciz "up-down"
.Lc_up: .asciz "up"
.Lc_scroll: .asciz "scroll"
.Lc_open: .asciz "open"
.Lc_cmd: .asciz "cmd"
.Lc_shot: .asciz "shot"
.Lc_wait: .asciz "wait"
.Lc_resize: .asciz "resize"
.Lc_quit: .asciz "quit"
.Lc_echo: .asciz "echo"
.Lc_print_doc: .asciz "print-doc"
.Lc_print_state: .asciz "print-state"
.Lc_print_syntax: .asciz "print-syntax"
.Lc_print_agents: .asciz "print-agents"
.Lc_xkey: .asciz "xkey"
.Lc_print_window: .asciz "print-window"
.Lc_print_cursor: .asciz "print-cursor"
.Lc_print_shape: .asciz "print-shape"
.Lc_print_term: .asciz "print-term"
.Lc_print_git: .asciz "print-git"
.Lc_wait_git: .asciz "wait-git"
.Lc_wait_agents: .asciz "wait-agents"
.Lc_agents_more: .asciz "agents-more"
.Lc_agents_page: .asciz "print-agents-page"
.Lc_agents_runs: .asciz "print-agents-runs"
.Lc_wait_grep: .asciz "wait-grep"
.Lc_wait_term: .asciz "wait-term"
.Lc_print_gitlog: .asciz "print-gitlog"
.Lc_print_scm: .asciz "print-scm"
.Lc_wait_ai: .asciz "wait-ai"
.Lc_print_ai: .asciz "print-ai"
.Lc_wait_update: .asciz "wait-update"
.Lc_print_update: .asciz "print-update"
.Lc_print_frames: .asciz "print-frames"
.Lc_print_project: .asciz "print-project"
.Lc_print_panels: .asciz "print-panels"
.Lc_print_tabs: .asciz "print-tabs"
.Lc_print_palette: .asciz "print-palette"
.Lc_print_menu: .asciz "print-menu"
.Lc_print_tip: .asciz "print-tip"
.Lc_print_toast: .asciz "print-toast"
.Lc_print_link: .asciz "print-link"
.Lc_print_scroll: .asciz "print-scroll"
.Lc_print_settings: .asciz "print-settings"
.Lc_scroll_x: .asciz "scroll-x"
.Lc_focus: .asciz "focus"
.Lc_print_term_cell: .asciz "print-term-cell"
.Ls_project: .asciz "project="
.Ls_bar: .asciz " | "
.Ls_explorer_eq: .asciz "explorer="
.Ls_agents_eq: .asciz " agents="
.Ls_toast: .asciz "toast="
.Ls_frames: .asciz "frames="
.Ls_term: .asciz " term="
.Ls_hidden: .asciz " hidden"
.Ls_builtin: .asciz "built-in"
.Ls_hot: .asciz " hot "
.Ls_moves: .asciz "moves="
.Ls_maximized: .asciz " maximized="
.Ls_minimized: .asciz " minimized="
.Ls_quit: .asciz " quit="
.Ls_csd: .asciz " csd="
.Ls_theme_eq: .asciz " theme="
.Ldigits: .ascii "0123456789abcdefghijk"
.p2align 3
ctl_table:
    .quad .Lc_key, c_key, .Lc_type, c_type, .Lc_move, c_move, .Lc_click, c_click, .Lc_tap, c_tap
    .quad .Lc_down, c_down, .Lc_up, c_up, .Lc_updown, c_updown, .Lc_scroll, c_scroll, .Lc_open, c_open
    .quad .Lc_cmd, c_cmd, .Lc_shot, c_shot, .Lc_wait, c_wait, .Lc_resize, c_resize
    .quad .Lc_quit, c_quit, .Lc_echo, c_echo
    .quad .Lc_print_state, c_print_state, .Lc_print_shape, c_print_shape
    .quad .Lc_print_window, c_print_window, .Lc_print_cursor, c_print_cursor, .Lc_print_term, c_print_term
    .quad .Lc_wait_term, c_wait_term
    .quad .Lc_print_frames, c_print_frames
    .quad .Lc_print_toast, c_print_toast, .Lc_print_link, c_print_link
    .quad .Lc_print_term_cell, c_print_term_cell
    .quad .Lc_scroll_x, c_scroll_x
    .quad .Lc_focus, c_focus, 0, 0


.data
lsock: .long -1
csock: .long -1
oc_next: .long -1               # a client that came while oc_busy, installed when it finishes
.bss
.p2align 3
pc_xc: .zero XC_SIZE
click_mods: .long 0             # c_click: the modifiers its press and release carry
pp_buf: .zero 4096
