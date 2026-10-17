# ui_clip_test: hits reported by ui_in must agree with the visible
# canvas clip, nested clips included. ui_in is the gate every widget
# goes through: the pointer must sit inside the widget's own rect AND
# inside the current canvas clip (g_cv -- the same rectangle the drawing
# primitives clip against, on clip_stack for pushes) AND input must not
# be blocked by a modal (g_block). gfx_clip_pop unrolls a push on both
# axes, so nested clips leave no residue behind. The closing "ok" is
# pinned by tests/data/ui-clip.expected.
.include "unn.inc"
.bss
pixels: .zero 40000
clip_offset: .zero 4
.text
FN main
    PROLOGUE
    lea rdi, [rip + pixels]
    mov esi, 100
    mov edx, 100
    mov ecx, 100
    call gfx_set_target
    mov edi, 20
    mov esi, 20
    mov edx, 20
    mov ecx, 20
    call gfx_clip_push
    mov dword ptr [rip + g_mx], 10
    mov dword ptr [rip + g_my], 30
    call hit
    test eax, eax
    jnz fail
    mov dword ptr [rip + g_mx], 30
    call hit
    test eax, eax
    jz fail
    mov edi, 30
    mov esi, 30
    mov edx, 10
    mov ecx, 10
    call gfx_clip_push
    mov dword ptr [rip + g_my], 25
    call hit
    test eax, eax
    jnz fail
    call gfx_clip_pop
    call hit
    test eax, eax
    jz fail
    mov dword ptr [rip + g_block], 1
    call hit
    test eax, eax
    jnz fail
    mov dword ptr [rip + g_block], 0
    call gfx_clip_pop
    mov dword ptr [rip + g_mx], 10
    call hit
    test eax, eax
    jz fail
    # The drag in flight: ui_scrollbar given a grabbed id (g_active),
    # buttons held and g_my moved under it -- but with g_block set it
    # short-circuits ui_btn, no held state reaches the offset math, and
    # clip_offset must still be 300 after the sticky drag never moves.
    mov dword ptr [rip + clip_offset], 300
    mov dword ptr [rip + g_block], 1
    mov dword ptr [rip + g_active], 900
    mov dword ptr [rip + g_mdown], 1
    mov dword ptr [rip + g_my], 70
    mov eax, 100
    push rax
    mov eax, 1000
    push rax
    mov edi, 900
    mov esi, 20
    xor edx, edx
    mov ecx, 20
    mov r8d, 100
    lea r9, [rip + clip_offset]
    call ui_scrollbar
    add rsp, 16
    cmp dword ptr [rip + clip_offset], 300
    jne fail
    lea rdi, [rip + ok]
    call log_cstr
    xor eax, eax
    EPILOGUE
fail:
    mov eax, 1
    EPILOGUE
# hit(): ui_in over the whole 100x100 canvas, so what it returns is
# exactly what the clip and g_block parts of ui_in decide -- the widget
# rect never rules anything out here.
hit:
    xor edi, edi
    xor esi, esi
    mov edx, 100
    mov ecx, 100
    jmp ui_in
.section .rodata
ok: .asciz "ok\n"
