# program entry. The kernel jumps here with rsp -> argc, argv[], envp[], NULL,
# and no return address. _start passes that stack to sys_init in rdi, which
# records g_argc/g_argv/g_envp from it, then rounds rsp down to a 16-byte
# boundary matching what the ABI promises a function that was called
# normally. main runs the whole application, and its return value is the
# exit status, since sys_exit never returns.
.include "unn.inc"

FN _start
    mov rdi, rsp
    and rsp, -16
    call sys_init
    call main
    mov edi, eax
    jmp sys_exit
