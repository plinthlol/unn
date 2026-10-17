# glue between libghostty-vt (third_party/ghostty) and unn's own heap/strings.
# the library is built for x86_64-linux-none (no libc); it gets its memory from
# the allocator vtable below. resize/remap report "no support" so callers copy
# by alloc+move+free, which the API documents as legal; free ignores the len
# argument because mem_free carries sizes in its own block headers.
#
# struct layouts are transcribed from third_party/ghostty/ghostty/vt/
# allocator.h, at the commit recorded in third_party/ghostty/COMMIT;
# re-check that file if the pin ever moves:
#   GhosttyAllocatorVtable = { alloc, resize, remap, free }  (4 opaque fns)
#   GhosttyAllocator       = { void* ctx, const vtable* }    (2 qwords)
.include "unn.inc"

.text

# vtable alloc(ctx, len, alignment, ret_addr) -> ptr or NULL.
# mem_alloc gives >= 32-byte alignment for small classes (classes are 32..64k,
# every block starts on a class-sized boundary inside a 1 MiB-aligned chunk)
# and page-aligned (4096) blocks for large ones. to honor bigger alignment
# demands we round the length up to 1 << alignment, which promotes the size
# class to exactly that alignment. `alignment` is log2 per the header docs.
FN vtglue_vt_alloc
    push rbx
    mov ebx, edx                # alignment log2
    test esi, esi
    jnz 1f
    mov esi, 1                  # len 0 still needs a valid-ish pointer
1:  mov rax, 1
    mov ecx, ebx
    shl rax, cl                 # 1 << alignment
    cmp rax, rsi
    jbe 2f
    mov rsi, rax                # grow len so the size class covers it
2:  cmp ebx, 12
    ja 9f                       # > 4096 not guaranteed by the heap: fail (legal)
    mov rdi, rsi                # mem_alloc(requested)
    call mem_alloc
    pop rbx
    ret
9:  xor eax, eax
    pop rbx
    ret

# vtable resize(...) -> false; callers fall back to remap or copy
FN vtglue_vt_resize
    xor eax, eax
    ret

# vtable remap(...) -> NULL; callers fall back to copy
FN vtglue_vt_remap
    xor eax, eax
    ret

# vtable free(ctx, mem, len, alignment, ret_addr); len/alignment ignored
FN vtglue_vt_free
    test rsi, rsi
    jz 1f
    mov rdi, rsi
    call mem_free
1:  ret

# memcmp(a, b, n) -> <0 if a<b, 0 if equal, >0 if a>b (the library and some of
# its deps expect the C name; the logic is trivial and freestanding-safe)
FN memcmp
    xor eax, eax
    test rdx, rdx
    jz 3f
1:  movzx ecx, byte ptr [rdi]
    movzx r8d, byte ptr [rsi]
    cmp cl, r8b
    jne 2f
    inc rdi
    inc rsi
    dec rdx
    jnz 1b
3:  ret
2:  movzx ecx, cl
    sub ecx, r8d
    mov eax, ecx
    ret

.section .rodata
.p2align 3
vtglue_vtable:
    .quad vtglue_vt_alloc
    .quad vtglue_vt_resize
    .quad vtglue_vt_remap
    .quad vtglue_vt_free

# GhosttyAllocator { ctx, vtable }; ctx = 0 (the heap is global state)
.globl g_vt_allocator
g_vt_allocator:
    .quad 0
    .quad vtglue_vtable
