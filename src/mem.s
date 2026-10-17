# heap: power-of-two size classes (32 B .. 64 KiB) carved from 1 MiB chunks,
# larger blocks get their own mapping. Every block has a 16-byte header:
#   [0] class index (< 64), or mapping size (>= 4096) for large blocks
#   [8] requested size
# mem_alloc returns zeroed memory. Small blocks are zeroed by a rep stosb
# across the class block except the header; large ones trust the fresh
# anonymous mapping. vec and sb at the bottom are the shared growable array
# and byte buffer (layouts VEC*/SB* in unn.inc), grown through mem_realloc.
.include "unn.inc"

.equ MEM_CLASSES, 12
.equ MEM_MAXSMALL, 65536
.equ MEM_CHUNK, 1 << 20

.bss
.p2align 3
free_lists: .zero 8 * MEM_CLASSES
chunk_ptr: .quad 0
chunk_end: .quad 0
.globl g_mem_live
g_mem_live: .quad 0             # live blocks: each alloc path adds one, mem_free drops it

.text

# os_map(size) -> ptr (dies on failure)
FN os_map
    mov rsi, rdi
    xor edi, edi
    mov edx, PROT_READ | PROT_WRITE
    mov r10d, MAP_PRIVATE | MAP_ANONYMOUS
    mov r8, -1
    xor r9d, r9d
    SYS SYS_mmap
    cmp rax, -4096
    ja .Lmap_fail
    ret
.Lmap_fail:
    lea rdi, [rip + .Loom]
    jmp die

.section .rodata
.Loom: .asciz "unn: out of memory"
.text

# mem_alloc(size) -> zeroed ptr; dies through os_map when a fresh chunk or a
# large block cannot be mapped
FN mem_alloc
    push rbx
    push r12
    push r13
    mov r12, rdi                # requested
    lea rbx, [rdi + 16]
    cmp rbx, MEM_MAXSMALL
    ja .Lma_large
    # class = max(0, ceil(log2(total)) - 5)
    lea rax, [rbx - 1]
    or rax, 31
    bsr rcx, rax
    inc ecx                     # ceil log2
    sub ecx, 5
    mov r13d, ecx
    lea rdx, [rip + free_lists]
    mov rax, [rdx + rcx*8]
    test rax, rax
    jz .Lma_bump
    mov r8, [rax + 16]          # next free stored in payload
    mov [rdx + rcx*8], r8
    jmp .Lma_init
.Lma_bump:
    mov ebx, 32
    shl rbx, cl                 # block size
    mov rax, [rip + chunk_ptr]
    lea r8, [rax + rbx]
    cmp r8, [rip + chunk_end]
    jbe .Lma_take
    mov edi, MEM_CHUNK
    call os_map
    mov [rip + chunk_ptr], rax
    lea r8, [rax + MEM_CHUNK]
    mov [rip + chunk_end], r8
    lea r8, [rax + rbx]
.Lma_take:
    mov [rip + chunk_ptr], r8
.Lma_init:
    mov [rax], r13
    mov [rax + 8], r12
    mov r8, rax
    lea rdi, [rax + 16]
    mov ecx, r13d
    mov edx, 32
    shl rdx, cl
    lea rcx, [rdx - 16]
    xor eax, eax
    rep stosb
    lea rax, [r8 + 16]
    inc qword ptr [rip + g_mem_live]
    pop r13
    pop r12
    pop rbx
    ret
.Lma_large:
    add rbx, 4095
    and rbx, -4096
    mov rdi, rbx
    call os_map                 # anonymous mappings are zeroed
    mov [rax], rbx
    mov [rax + 8], r12
    add rax, 16
    inc qword ptr [rip + g_mem_live]
    pop r13
    pop r12
    pop rbx
    ret

# mem_alloc_try(size) -> ptr or 0. Like mem_alloc, but a large block that
# cannot be mapped returns 0 instead of dying; so does any size >= 1 TiB,
# which is not even attempted.
FN mem_alloc_try
    lea rax, [rdi + 16]
    cmp rax, MEM_MAXSMALL
    jbe mem_alloc
    mov rax, 1 << 40
    cmp rdi, rax
    jae 1f
    push rbx
    push r12
    mov r12, rdi
    lea rbx, [rdi + 16 + 4095]
    and rbx, -4096
    xor edi, edi
    mov rsi, rbx
    mov edx, PROT_READ | PROT_WRITE
    mov r10d, MAP_PRIVATE | MAP_ANONYMOUS
    mov r8, -1
    xor r9d, r9d
    SYS SYS_mmap
    cmp rax, -4096
    ja 2f
    mov [rax], rbx
    mov [rax + 8], r12
    add rax, 16
    inc qword ptr [rip + g_mem_live]
    pop r12
    pop rbx
    ret
2:  pop r12
    pop rbx
1:  xor eax, eax
    ret

# mem_free(ptr): 0 is ignored. A small block returns to its class's free
# list (next pointer kept in its own payload); anything else (its header
# word is then the mapping size) is unmapped whole.
FN mem_free
    test rdi, rdi
    jz 1f
    dec qword ptr [rip + g_mem_live]
    lea rax, [rdi - 16]
    mov rcx, [rax]
    cmp rcx, 64
    jae .Lmf_large
    lea rdx, [rip + free_lists]
    mov r8, [rdx + rcx*8]
    mov [rax + 16], r8
    mov [rdx + rcx*8], rax
1:  ret
.Lmf_large:
    mov rdi, rax
    mov rsi, rcx
    SYS SYS_munmap
    ret

# mem_capacity(ptr) -> usable bytes: the class block less its header, or a
# large block's mapping less 16
FN mem_capacity
    mov rcx, [rdi - 16]
    cmp rcx, 64
    jae 1f
    mov eax, 32
    shl rax, cl
    sub rax, 16
    ret
1:  lea rax, [rcx - 16]
    ret

# mem_realloc(ptr, newsize) -> ptr ; contents preserved up to min(old, new)
FN mem_realloc
    test rdi, rdi
    jnz 1f
    mov rdi, rsi
    jmp mem_alloc
1:  push rbx
    push r12
    push r13
    mov rbx, rdi
    mov r12, rsi
    call mem_capacity
    cmp r12, rax
    ja .Lmr_grow
    # the new size fits the block in place: keep it, record the request
    mov [rbx - 8], r12
    mov rax, rbx
    jmp .Lmr_ret
.Lmr_grow:
    mov rcx, [rbx - 16]
    cmp rcx, 64
    jb .Lmr_copy
    # large -> mremap
    lea rdi, [rbx - 16]
    mov rsi, rcx
    lea rdx, [r12 + 16 + 4095]
    and rdx, -4096
    mov r13, rdx
    mov r10d, MREMAP_MAYMOVE
    SYS SYS_mremap
    cmp rax, -4096
    ja .Lmr_copy                # fall back to copying
    mov [rax], r13
    mov [rax + 8], r12
    add rax, 16
    jmp .Lmr_ret
.Lmr_copy:
    mov rdi, r12
    call mem_alloc
    mov r13, rax
    mov rdi, rax
    mov rsi, rbx
    mov rcx, [rbx - 8]
    cmp rcx, r12
    cmova rcx, r12
    rep movsb
    mov rdi, rbx
    call mem_free
    mov rax, r13
.Lmr_ret:
    pop r13
    pop r12
    pop rbx
    ret

# mem_dup(ptr, len) -> new NUL-terminated copy
FN mem_dup
    push rbx
    push r12
    mov rbx, rdi
    mov r12, rsi
    lea rdi, [rsi + 1]
    call mem_alloc
    mov rdi, rax
    mov rsi, rbx
    mov rcx, r12
    rep movsb
    pop r12
    pop rbx
    ret

# ---- vec: growable array. vec_push(vec, item_size) -> ptr to new zeroed slot ----
FN vec_push
    push rbx
    push r12
    mov rbx, rdi
    mov r12, rsi
    mov rax, [rbx + VEC_len]
    cmp rax, [rbx + VEC_cap]
    jb 1f
    mov rax, [rbx + VEC_cap]
    add rax, rax
    mov ecx, 8
    cmp rax, rcx
    cmovb rax, rcx
    mov [rbx + VEC_cap], rax
    mov rsi, rax
    imul rsi, r12
    mov rdi, [rbx + VEC_ptr]
    call mem_realloc
    mov [rbx + VEC_ptr], rax
1:  mov rax, [rbx + VEC_len]
    imul rax, r12
    add rax, [rbx + VEC_ptr]
    inc qword ptr [rbx + VEC_len]
    mov rdi, rax
    mov rcx, r12
    push rax
    xor eax, eax
    rep stosb
    pop rax
    pop r12
    pop rbx
    ret

# vec_free(vec): release the items and zero the struct
FN vec_free
    push rbx
    mov rbx, rdi
    mov rdi, [rbx]
    call mem_free
    xor eax, eax
    mov [rbx + VEC_ptr], rax
    mov [rbx + VEC_len], rax
    mov [rbx + VEC_cap], rax
    pop rbx
    ret

# ---- sb: byte buffer ----
# sb_reserve(sb, extra) -> ptr to write position
FN sb_reserve
    push rbx
    push r12
    mov rbx, rdi
    mov rax, [rbx + SB_len]
    add rax, rsi
    inc rax                     # keep room for NUL
    cmp rax, [rbx + SB_cap]
    jbe 1f
    mov rcx, [rbx + SB_cap]
    add rcx, rcx
    cmp rax, rcx
    cmovb rax, rcx
    mov ecx, 64
    cmp rax, rcx
    cmovb rax, rcx
    mov [rbx + SB_cap], rax
    mov rsi, rax
    mov rdi, [rbx + SB_ptr]
    call mem_realloc
    mov [rbx + SB_ptr], rax
1:  mov rax, [rbx + SB_ptr]
    add rax, [rbx + SB_len]
    pop r12
    pop rbx
    ret

# sb_push(sb, ptr, len)
FN sb_push
    push rbx
    push r12
    push r13
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov rsi, rdx
    call sb_reserve
    mov rdi, rax
    mov rsi, r12
    mov rcx, r13
    rep movsb
    mov byte ptr [rdi], 0
    add [rbx + SB_len], r13
    pop r13
    pop r12
    pop rbx
    ret

# sb_push_cstr(sb, cstr)
FN sb_push_cstr
    push rdi
    push rsi
    mov rdi, rsi
    call strlen
    mov rdx, rax
    pop rsi
    pop rdi
    jmp sb_push

# sb_push_byte(sb, byte)
FN sb_push_byte
    push rbx
    push r12
    mov rbx, rdi
    mov r12d, esi
    mov esi, 1
    call sb_reserve
    mov [rax], r12b
    mov byte ptr [rax + 1], 0
    inc qword ptr [rbx + SB_len]
    pop r12
    pop rbx
    ret

# sb_push_u64(sb, value)
FN sb_push_u64
    push rbx
    sub rsp, 32
    mov rbx, rdi
    mov rdi, rsp
    call fmt_u64
    mov rdi, rbx
    mov rsi, rsp
    mov rdx, rax
    call sb_push
    add rsp, 32
    pop rbx
    ret

# sb_push_utf8(sb, codepoint)
FN sb_push_utf8
    push rbx
    sub rsp, 16
    mov rbx, rdi
    mov edi, esi
    mov rsi, rsp
    call utf8_encode
    mov rdi, rbx
    mov rsi, rsp
    mov rdx, rax
    call sb_push
    add rsp, 16
    pop rbx
    ret

# sb_clear(sb): drop the contents, keep the allocation: len back to 0 and
# the buffer re-terminated (a sb with ptr 0 has no buffer to write into, so
# it skips that)
FN sb_clear
    mov qword ptr [rdi + SB_len], 0
    mov rax, [rdi + SB_ptr]
    test rax, rax
    jz 1f
    mov byte ptr [rax], 0
1:  ret

# sb_free(sb): release the buffer and zero the struct
FN sb_free
    push rbx
    mov rbx, rdi
    mov rdi, [rbx + SB_ptr]
    call mem_free
    xor eax, eax
    mov [rbx + SB_ptr], rax
    mov [rbx + SB_len], rax
    mov [rbx + SB_cap], rax
    pop rbx
    ret
