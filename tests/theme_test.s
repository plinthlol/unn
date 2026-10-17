# theme_test: loads the one embedded theme -- runtime/themes/unn.theme,
# .incbin'd into assets.s as row 0 of themes_table, the same row
# app_init loads at startup -- and prints its id plus a few slot colors
# as "#hex <space>", which tests/data/themes.expected pins. theme_load
# derives every slot the file does not name, so what g_theme holds for
# the syntax classes and the file-icon ramp counts on that derivation.
.include "unn.inc"
.bss
.p2align 3
out: .zero SB_SIZE
.text
# hex(v=edi): appends '#rrggbb' -- the six nibbles at bits 20..0, the
# alpha byte left off -- then a space to out. Keeps rbx.
hex:
    push rbx
    mov ebx, edi
    lea rdi, [rip + out]
    mov esi, '#'
    call sb_push_byte
    mov ecx, 20
1:  mov eax, ebx
    shr eax, cl
    and eax, 15
    lea rdx, [rip + hexdigits]
    movzx esi, byte ptr [rdx + rax]
    push rcx
    lea rdi, [rip + out]
    call sb_push_byte
    pop rcx
    sub ecx, 4
    jns 1b
    lea rdi, [rip + out]
    mov esi, ' '
    call sb_push_byte
    pop rbx
    ret
FN main
    PROLOGUE
    # the embedded theme: themes_table row 0 is (name, data, end), and
    # theme_load takes the byte range [data, end)
    mov rdi, [rip + themes_table + 8]
    mov rsi, [rip + themes_table + 16]
    sub rsi, rdi
    call theme_load
    # the id printed is the row's name without the ".theme" suffix
    mov rsi, [rip + themes_table]
    mov rdi, rsi
    call strlen
    sub rax, 6                     # minus ".theme"
    mov rdx, rax
    lea rdi, [rip + out]
    call sb_push
    lea rdi, [rip + out]
    mov esi, ' '
    call sb_push_byte
    lea r12, [rip + slots]
2:  mov eax, [r12]
    cmp eax, -1
    je 3f
    lea rcx, [rip + g_theme]
    mov edi, [rcx + rax*4]
    call hex
    add r12, 4
    jmp 2b
3:  lea rdi, [rip + out]
    mov esi, 10
    call sb_push_byte
    mov rdi, [rip + out + SB_ptr]
    mov rsi, [rip + out + SB_len]
    call log_write
    xor eax, eax
    EPILOGUE
.section .rodata
.p2align 2
slots: .long T_BG, T_FG, T_PANEL, T_SELECTION, T_SYN + C_KEYWORD, T_SYN + C_STRING, T_SYN + C_COMMENT
    # the ten file-icon colors in the order unn.inc names them:
    # red orange yellow green blue purple pink cyan grey white
    .long T_ICON, T_ICON + 1, T_ICON + 2, T_ICON + 3, T_ICON + 4, T_ICON + 5, T_ICON + 6, T_ICON + 7
    .long T_ICON + 8, T_ICON + 9, -1
