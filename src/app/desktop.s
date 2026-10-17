# Opening links and file paths with the desktop's default applications. All of
# this goes through xdg-open: desktop_open(path) passes the path itself,
# desktop_reveal(path) asks the file manager to show its containing folder
# instead of the file. desktop_open backs app_open_path and app_open_file
# (app.s), reached from termview.s link_open and the control open command; the
# cmd_website/feedback/discord/email handlers feed it the project's pages.
.include "unn.inc"

.text
FN cmd_website
    lea rdi, [rip + .Lwebsite]
    jmp desktop_open

FN cmd_feedback
    lea rdi, [rip + .Lfeedback]
    jmp desktop_open

FN cmd_discord
    lea rdi, [rip + .Ldiscord]
    jmp desktop_open

FN cmd_email
    lea rdi, [rip + .Lemail]
    jmp desktop_open

# desktop_open(path) / desktop_reveal(path): esi 0 runs the path itself,
# esi 1 redefines the argv entry to its parent folder (no filename selected).
# The path is always a separate argv element, never a shell string, so a
# filename can't become shell code. proc_which finds xdg-open per call, the
# child runs with run_piped (cwd NULL) and its (nonblocking) output fd goes to
# watch_add: desktop_done drains it and reaps the child so the UI never blocks.
FN desktop_open
    xor esi, esi
    jmp desktop_launch

FN desktop_reveal
    mov esi, 1

desktop_launch:
    PROLOGUE 48
    # rbx = path, r12d = reveal flag, r13 = the folder copy we may allocate,
    # r14 = the xdg-open path. [rsp..rsp+16] is an argv {opener, arg, NULL}
    mov rbx, rdi
    mov r12d, esi
    xor r13d, r13d
    lea rdi, [rip + .Lopener]
    call proc_which
    test rax, rax
    jz 8f
    mov r14, rax
    mov [rsp], rax
    mov [rsp + 8], rbx
    mov qword ptr [rsp + 16], 0
    test r12d, r12d
    jz 2f
    # xdg-open works with GNOME, KDE, Xfce and other desktop file managers.
    # Open the containing folder without opening the selected file itself.
    mov rdi, rbx
    call strlen
    mov rdi, rbx
    mov rsi, rax
    call path_dirlen
    test rax, rax
    jnz 1f
    mov eax, 1                 # the parent of /name is /
1:
    mov rdi, rbx
    mov rsi, rax
    call mem_dup
    mov r13, rax
    mov [rsp + 8], rax
2:  mov rdi, rsp
    mov rsi, [rip + g_envp]
    xor edx, edx
    call run_piped
    mov r12, rax
    mov ebx, edx
    mov rdi, r14
    call mem_free
    mov rdi, r13
    call mem_free
    test r12, r12
    jle 8f
    mov edi, ebx
    mov esi, POLLIN
    lea rdx, [rip + desktop_done]
    mov rcx, r12
    call watch_add
    EPILOGUE
8:  call desktop_failed
    EPILOGUE

# desktop_done(fd, revents, pid): watched callback for the spawned opener
# (run_piped's fd, and the pid as the watch's ctx): drain the opener's output
# without blocking (a blocked read would freeze the UI), drop the watch, close
# the fd and reap the child, and show desktop_failed on a nonzero exit.
desktop_done:
    PROLOGUE 1024
    mov ebx, edi
    mov r12, rdx
1:  mov edi, ebx
    mov rsi, rsp
    mov edx, 1024
    SYS SYS_read
    cmp rax, -EINTR
    je 1b
    cmp rax, -EAGAIN
    je 9f
    test rax, rax
    jg 1b
    mov edi, ebx
    call watch_remove
    mov edi, ebx
    SYS SYS_close
    mov rdi, r12
    xor esi, esi
    call proc_wait
    test eax, eax
    jz 9f
    call desktop_failed
9:  EPILOGUE

# desktop_failed(): what the user sees when no opener exists or it exited nonzero
FN desktop_failed
    lea rdi, [rip + .Lfailed]
    jmp app_toast

.section .rodata
.Lwebsite: .asciz "https://unn.app"
.Lfeedback: .asciz "https://github.com/vshvedov/unn/issues"
.Ldiscord: .asciz "https://discord.gg/Aj4drpFbWf"
.Lemail: .asciz "mailto:hi@unn.app?subject=unn%20feedback"
.Lfailed: .asciz "Could not open the desktop application"
.Lopener: .asciz "xdg-open"
