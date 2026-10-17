# entry point: parse arguments, pick the window platform, and hand over to the
# app's event loop
#   unn [PATH...] [--wait] [--headless WxH] [--scale F] [--script FILE] [--control SOCKET]
# Paths open in windows; an existing folder becomes the working directory the
# side shell spawns in. --headless gives no window (scripting, --script or
# --control). start.s reaches here through sys_init after recording
# argc/argv/envp.
.include "unn.inc"

.equ TCGETS, 0x5401

.bss
.p2align 3
sigact: .zero 32                # rt_sigaction's act struct, filled once below
opt_headless: .long 0
opt_paths: .long 0              # past a -- argument: the rest are paths
.p2align 3
opt_script: .quad 0             # --script FILE, control commands then exit
opt_control: .quad 0            # --control SOCKET, a unix socket to serve
cwd: .zero 4096                 # startup directory (kept for reference)
self_path: .zero 4096           # /proc/self/exe, for re-executing ourselves

.data
opt_w: .long 1280               # --headless WxH defaults
opt_h: .long 800
.text
FN main
    PROLOGUE 16
    # writes to a closed pipe (a pager exits, git closes early) must fail as
    # EPIPE rather than kill the process: act.sa_handler = SIG_IGN
    mov qword ptr [rip + sigact], 1
    mov edi, 13
    lea rsi, [rip + sigact]
    xor edx, edx
    mov r10d, 8
    SYS SYS_rt_sigaction
    # parse, detach if spawning a display copy, then start the app; the
    # platform is wayland except in --headless mode
1:
    call parse_args
    call detach
    call raster_init
    call app_init
    cmp dword ptr [rip + opt_headless], 0
    jne .Lm_headless
    call wl_connect
    test eax, eax
    jz 2f
    lea rdi, [rip + .Ltitle]
    call wl_open_window
    jmp .Lm_open
2:  lea rdi, [rip + .Lno_display]
    call die
.Lm_headless:
    call scale_from_env
    mov edi, [rip + opt_w]
    mov esi, [rip + opt_h]
    call headless_init
.Lm_open:
    call open_initial
    call term_boot
    mov rdi, [rip + opt_control]
    test rdi, rdi
    jz 2f
    call control_listen
2:  mov rdi, [rip + opt_script]
    test rdi, rdi
    jz 3f
    call control_run_script
    jmp .Lm_exit
3:  call loop_run
.Lm_exit:
    xor eax, eax
    EPILOGUE

.section .rodata
.text
# parse_args(): fill the opt_* flags above from the command line (g_argv,
# g_argc, set by sys_init). Options with a value take the next argv entry;
# anything unrecognized is pushed as a start path. The -- separator makes
# every later argument a path.
parse_args:
    PROLOGUE
    mov r12, [rip + g_argv]
    mov r13, [rip + g_argc]
    mov ebx, 1
.Lpa_next:
    cmp rbx, r13
    jae .Lpa_done
    mov r14, [r12 + rbx*8]
    # after --, paths only (no options are parsed after it, so that a quote in a path cannot
    # start an option)
    cmp dword ptr [rip + opt_paths], 0
    jne 4f
    mov rdi, r14
    lea rsi, [rip + .Lo_dashdash]
    call strcmp_eq
    test eax, eax
    jz 0f
    mov dword ptr [rip + opt_paths], 1
    jmp 9f
0:  mov rdi, r14
    call help_flag
    mov rdi, r14
    lea rsi, [rip + .Lo_headless]
    call strcmp_eq
    test eax, eax
    jz 1f
    mov dword ptr [rip + opt_headless], 1
    inc rbx
    cmp rbx, r13
    jae .Lpa_done
    mov rdi, [r12 + rbx*8]
    call parse_size
    jmp 9f
1:  mov rdi, r14
    lea rsi, [rip + .Lo_script]
    call strcmp_eq
    test eax, eax
    jz 2f
    inc rbx
    mov rax, [r12 + rbx*8]
    mov [rip + opt_script], rax
    jmp 9f
2:  mov rdi, r14
    lea rsi, [rip + .Lo_control]
    call strcmp_eq
    test eax, eax
    jz 3f
    inc rbx
    mov rax, [r12 + rbx*8]
    mov [rip + opt_control], rax
    jmp 9f
3:  mov rdi, r14
    lea rsi, [rip + .Lo_wait]
    call strcmp_eq
    test eax, eax
    jz 31f
    mov dword ptr [rip + g_wait], 1
    jmp 9f
31: mov rdi, r14
    lea rsi, [rip + .Lo_scale]
    call strcmp_eq
    test eax, eax
    jz 4f
    inc rbx
    mov rdi, [r12 + rbx*8]
    call set_scale
    jmp 9f
4:  lea rdi, [rip + g_start_paths]
    mov esi, 8
    call vec_push
    mov [rax], r14
9:  inc rbx
    jmp .Lpa_next
.Lpa_done:
    EPILOGUE

# detach(): started from a terminal, unn goes on as a fresh copy in a
# session of its own that reads and writes /dev/null, and this one exits:
# the shell gets its prompt back, and closing the terminal does not close
# unn. Not with --wait (git runs $EDITOR and waits for it, so EDITOR="unn
# --wait" keeps unn in the terminal), not for scripting, and not without
# a display, so that the error is seen. A fresh copy rather than a fork:
# the copy's input and output are no terminal, so it stays.
detach:
    PROLOGUE 64
    mov eax, [rip + opt_headless]
    or eax, [rip + g_wait]
    jnz 9f
    cmp qword ptr [rip + opt_script], 0
    jne 9f
    cmp qword ptr [rip + opt_control], 0
    jne 9f
    # a terminal on stdin, stdout or stderr
    xor ebx, ebx
1:  mov edi, ebx
    mov esi, TCGETS
    lea rdx, [rsp]
    SYS SYS_ioctl
    test rax, rax
    jz 2f
    inc ebx
    cmp ebx, 3
    jb 1b
    jmp 9f
2:
    lea rdi, [rip + .Lenv_wayland]
    call getenv
    test rax, rax
    jz 9f
3:  lea rdi, [rip + .Lself_exe]
    lea rsi, [rip + self_path]
    mov edx, 4095
    SYS SYS_readlink
    test rax, rax
    jle 9f
    lea rcx, [rip + self_path]
    mov byte ptr [rcx + rax], 0
    lea rdi, [rip + .Ldevnull]
    mov esi, O_RDWR | O_CLOEXEC
    xor edx, edx
    SYS SYS_open
    test rax, rax
    js 9f
    mov ebx, eax
    # a pipe whose write end the copy closes once it is in its new session (proc_spawn closes all
    # but 0-2 after setsid): this one exits only then, and a copy still in the terminal's process
    # group would go with it when the terminal signals the group.
    lea rdi, [rsp]
    mov esi, O_CLOEXEC
    SYS SYS_pipe2
    test rax, rax
    js 8f
    # the same arguments, run from the path of this program
    mov rax, [rip + g_argv]
    lea rcx, [rip + self_path]
    mov [rax], rcx
    mov rdi, rax
    mov rsi, [rip + g_envp]
    xor edx, edx
    mov ecx, ebx
    mov r8d, ebx
    mov r9d, ebx
    # ctty 1: setsid detaches the terminal's session, and the TIOCSCTTY
    # ioctl on /dev/null fails, so the copy ends up with no controlling
    # terminal
    push 1
    push 1
    call proc_spawn
    add rsp, 16
    mov r12, rax
    mov edi, [rsp + 4]
    SYS SYS_close
    test r12, r12
    jle 7f                      # it did not start: stay
6:  mov edi, [rsp]
    lea rsi, [rsp + 8]
    mov edx, 1
    SYS SYS_read
    cmp rax, -EINTR
    je 6b
    xor edi, edi
    call sys_exit
7:  mov edi, [rsp]
    SYS SYS_close
8:  mov edi, ebx
    SYS SYS_close
9:  EPILOGUE

# help_flag(arg): -h/--help prints usage, --version the version; both exit
help_flag:
    push rbx
    mov rbx, rdi
    lea rsi, [rip + .Lo_version]
    call strcmp_eq
    test eax, eax
    jz 1f
    # --version: print "unn " and the version string
    lea rdi, [rip + .Lversion]
    call out_cstr
    lea rdi, [rip + unn_version]
    call out_cstr
    lea rdi, [rip + .Lnl]
    jmp 3f
1:  mov rdi, rbx
    lea rsi, [rip + .Lo_help]
    call strcmp_eq
    test eax, eax
    jnz 2f
    mov rdi, rbx
    lea rsi, [rip + .Lo_h]
    call strcmp_eq
    test eax, eax
    jz 9f
2:  lea rdi, [rip + .Lusage]
3:  call out_cstr
    xor edi, edi
    call sys_exit
9:  pop rbx
    ret

# out_cstr(s): write the NUL-terminated string to stdout (fd 1)
out_cstr:
    push rdi
    call strlen
    pop rsi
    mov rdx, rax
    mov edi, 1
    jmp write_all

# UNN_SCALE=1.5 sets the display scale where the platform doesn't report one
# (headless mode; wayland reads its scale from the compositor)
scale_from_env:
    lea rdi, [rip + .Lenv_scale]
    call getenv
    test rax, rax
    jz 1f
    mov rdi, rax
    jmp set_scale
1:  ret

# set_scale(cstr): "2", "1.5" or "150" (percent) -> g_dpi_scale; values outside
# 0.5 .. 4 are ignored
set_scale:
    push rbx
    mov rbx, rdi
    call strlen
    mov rdi, rbx
    mov rsi, rax
    call parse_decimal
    test edx, edx
    jz 1f
    cmp eax, 10
    ja 2f
    imul eax, eax, 100              # a whole number is a factor
2:  cmp eax, 50
    jb 1f
    cmp eax, 400
    ja 1f
    cvtsi2ss xmm0, eax
    divss xmm0, [rip + .Lf100]
    movss [rip + g_dpi_scale], xmm0
1:  pop rbx
    ret

# parse_size("WxH"): fill opt_w and opt_h from the --headless argument
parse_size:
    push rbx
    mov rbx, rdi
    call strlen
    mov rdi, rbx
    mov rsi, rax
    call parse_u64
    mov [rip + opt_w], eax
    lea rdi, [rbx + rdx + 1]
    push rdi
    call strlen
    pop rdi
    mov rsi, rax
    call parse_u64
    mov [rip + opt_h], eax
    pop rbx
    ret

# open_initial(): the command-line folder becomes the shell's working directory; other paths
# open with the system's default application. Nothing is restored.

.bss
.p2align 3
project_path: .zero 4096        # absolute path of the first command-line folder

.text
open_initial:
    PROLOGUE
    xor ebx, ebx
1:  cmp rbx, [rip + g_start_paths + VEC_len]
    jae 9f
    mov rax, [rip + g_start_paths + VEC_ptr]
    mov r12, [rax + rbx*8]
    # an existing folder becomes g_project, the working directory the shell spawns in (the first
    # one wins); other paths open with the system's default application
    mov r13, r12
    cmp qword ptr [rip + g_project], 0
    jne .Lo_open
    mov rdi, r13
    call file_type
    cmp eax, 0x4000            # S_IFDIR
    jne .Lo_open
    # stored as an absolute path
    cmp byte ptr [r13], '/'
    je .Lo_abs
    mov eax, SYS_chdir
    mov rdi, r13
    XSYS
    test rax, rax
    js .Lo_open
    lea rdi, [rip + project_path]
    mov esi, 4096
    mov eax, SYS_getcwd
    XSYS
    test rax, rax
    js .Lo_open
    lea rax, [rip + project_path]
    mov [rip + g_project], rax
    jmp .Lo_next
.Lo_abs:
    mov [rip + g_project], r13
    jmp .Lo_next
.Lo_open:
    mov rdi, r13
    call app_open_path
.Lo_next:
    inc rbx
    jmp 1b
9:  EPILOGUE

.section .rodata
.Ltitle: .asciz "unn"
.Lno_display: .asciz "unn: no Wayland display found"
.Lenv_scale: .asciz "UNN_SCALE"
.Lo_headless: .asciz "--headless"
.Lo_script: .asciz "--script"
.Lo_control: .asciz "--control"
.Lo_scale: .asciz "--scale"
.Lo_wait: .asciz "--wait"

.Lo_dashdash: .asciz "--"
.Ldevnull: .asciz "/dev/null"
.Lself_exe: .asciz "/proc/self/exe"
.Lenv_wayland: .asciz "WAYLAND_DISPLAY"
.Lo_help: .asciz "--help"
.Lo_h: .asciz "-h"
.Lo_version: .asciz "--version"
.Lversion: .asciz "unn "
.Lnl: .asciz "\n"
.Lusage: .ascii "usage: unn [--headless WxH] [--script FILE] [--control SOCKET] [--version]\n"
    .ascii "  --wait           stay in the terminal until unn is closed (for EDITOR)\n"
    .ascii "  --headless WxH   no display; use with --script or --control\n"
    .ascii "  --script FILE    run control commands from FILE and exit\n"
    .ascii "  --control PATH   accept control commands on a unix socket\n"
    .ascii "  --scale F        display scale where the platform has none\n"
    .ascii "  --               the arguments after it are paths\n"
    .asciz "  --version        print the version\n"
.p2align 2
.Lf100: .float 100.0
