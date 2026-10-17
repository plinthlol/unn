# path_test: path_normalize on the paths in argv[1], one per line
# (tests/data/paths.txt). Each line is copied into buf with the tail
# filled with 3s instead of zeroes, as reused heap memory can be, so any
# overread past the NUL lands in the output run.sh compares against
# tests/data/paths.expected. Prints each normalized result on its own
# line.
.include "unn.inc"
.bss
.p2align 3
out: .zero SB_SIZE               # strbuf collecting every result plus newlines
buf: .zero 256                  # one input line, NUL-terminated after the copy
.text
FN main
    PROLOGUE
    mov rax, [rip + g_argv]
    mov rdi, [rax + 8]
    call file_read_all
    test rax, rax
    jz 9f
    mov r12, rax
    lea r13, [rax + rdx]
1:  cmp r12, r13
    jae 9f
    mov r14, r12                # the line starts here
2:  cmp byte ptr [r12], 10      # scan to its newline
    je 3f
    inc r12
    jmp 2b
3:  mov rbx, r12
    sub rbx, r14                # the line's length, newline excluded
    inc r12                     # past the newline, ready for the next line
    lea rdi, [rip + buf]
    mov esi, 3                  # dirty fill: nothing past the copy may be read
    mov edx, 255
    call memset
    lea rdi, [rip + buf]
    mov rsi, r14
    mov rdx, rbx
    call memcpy
    lea rax, [rip + buf]
    mov byte ptr [rax + rbx], 0
    lea rdi, [rip + buf]
    call path_normalize
    lea rdi, [rip + out]
    lea rsi, [rip + buf]
    call sb_push_cstr
    lea rdi, [rip + out]
    mov esi, 10
    call sb_push_byte
    jmp 1b
9:  mov rdi, [rip + out + SB_ptr]    # all results out at once, then exit 0
    mov rsi, [rip + out + SB_len]
    call log_write
    xor eax, eax
    EPILOGUE
