# str_test: str_find and str_ifind over the cases in argv[1]
# (tests/data/strfind.txt), one per line -- "f" or "i", a tab, the text,
# a tab, the string to find; each line's result is its own: "-1" on no
# match, else the index -- the same scan lib.s runs over every terminal
# buffer search, so the SIMD path and the casefold table both get pinned
# here, and run.sh compares the dump to tests/data/strfind.expected. An
# "e" case instead compares the two fields with str_ieq and prints 1
# when they match ignoring case, 0 otherwise.
.include "unn.inc"
.bss
.p2align 3
out: .zero SB_SIZE
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
    movzx r14d, byte ptr [r12]
    lea rbx, [r12 + 2]          # text
    mov rdi, rbx
2:  cmp byte ptr [rdi], 9
    je 3f
    inc rdi
    jmp 2b
3:  mov r15, rdi                # end of the text
    lea rcx, [rdi + 1]          # the string to find
    mov rdi, rcx
4:  cmp byte ptr [rdi], 10
    je 5f
    inc rdi
    jmp 4b
5:  lea r12, [rdi + 1]
    mov rdx, rcx
    sub rdi, rcx
    mov rcx, rdi
    mov rsi, r15
    sub rsi, rbx
    mov rdi, rbx
    cmp r14d, 'e'
    jne 0f
    call str_ieq
    jmp 7f
0:  cmp r14d, 'i'
    je 6f
    call str_find
    jmp 7f
6:  call str_ifind
7:  test rax, rax
    jns 8f
    lea rdi, [rip + out]
    mov esi, '-'
    call sb_push_byte
    mov eax, 1
8:  lea rdi, [rip + out]
    mov rsi, rax
    call sb_push_u64
    lea rdi, [rip + out]
    mov esi, 10
    call sb_push_byte
    jmp 1b
9:  mov rdi, [rip + out + SB_ptr]
    mov rsi, [rip + out + SB_len]
    call log_write
    xor eax, eax
    EPILOGUE
