# memmove_test: memmove must behave like a byte-at-a-time copy on
# overlapping ranges, in either direction: every size 0..100 is moved
# 1..40 bytes up and down (dst above or below src at a distance of
# 1..40 from the source at 80), and a whole-buffer memeq flags any byte
# outside n that got touched. Against an honest bytewise reference this
# catches a fast path that reads or writes ahead of itself; the closing
# "ok" is pinned by tests/data/memmove.expected.
.include "unn.inc"
.equ N, 256
.bss
buf: .zero N
ref: .zero N
.text
FN main
    PROLOGUE 128
    mov r12d, 0                 # size
.Lsize:
    mov r13d, 1                 # distance
.Ldist:
    mov r14d, 0                 # 0 up, 1 down
.Ldir:
    # buf and ref both start as the bytes 0, 1, 2, ...: untouched cells
    # stay equal by construction, so the final memeq sees only what the
    # copy actually moved
    xor ecx, ecx
1:  lea rax, [rip + buf]
    mov [rax + rcx], cl
    lea rax, [rip + ref]
    mov [rax + rcx], cl
    inc ecx
    cmp ecx, N
    jb 1b
    # src at 80, dst 80 +/- distance
    mov r15d, 80
    mov ebx, 80
    add ebx, r13d
    test r14d, r14d
    jz 2f
    mov ebx, 80
    sub ebx, r13d
2:  # the reference: the src range stashed on the stack scratch
    # (PROLOGUE 128), then written to dst byte by byte
    xor ecx, ecx
3:  cmp ecx, r12d
    jae 4f
    lea rax, [rip + buf]
    lea edx, [r15 + rcx]
    movzx edx, byte ptr [rax + rdx]
    mov [rsp + rcx], dl
    inc ecx
    jmp 3b
4:  xor ecx, ecx
5:  cmp ecx, r12d
    jae 6f
    movzx edx, byte ptr [rsp + rcx]
    lea rax, [rip + ref]
    lea r8d, [rbx + rcx]
    mov [rax + r8], dl
    inc ecx
    jmp 5b
6:  lea rdi, [rip + buf]
    add rdi, rbx
    lea rsi, [rip + buf]
    add rsi, r15
    mov edx, r12d
    call memmove
    lea rdi, [rip + buf]
    lea rsi, [rip + ref]
    mov edx, N
    call memeq
    test eax, eax
    jz fail
    inc r14d
    cmp r14d, 2
    jb .Ldir
    inc r13d
    cmp r13d, 40
    jbe .Ldist
    inc r12d
    cmp r12d, 100
    jbe .Lsize
    lea rdi, [rip + ok]
    call log_cstr
    xor eax, eax
    EPILOGUE
fail:
    lea rdi, [rip + bad]
    call log_cstr
    mov eax, 1
    EPILOGUE

.section .rodata
ok: .asciz "ok\n"
bad: .asciz "memmove differs from a byte copy\n"
