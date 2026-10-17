# keys_test: every registered command and shortcut must resolve to the
# advertised handler. Walks the g_commands registry (keys.s) row by row
# after keys_init turned each row's combo string into bindings: cmd_find
# must return the very row whose name was looked up, and every combo in
# the row's keys string must parse (next_word, parse_combo) and key
# through keys_lookup to that same row's fn. The closing "ok" is pinned
# by tests/data/keys.expected.
.include "unn.inc"
.text
FN main
    PROLOGUE
    call keys_init
    lea rbx, [rip + g_commands]
.Lcommand:
    mov rdi, [rbx + CMD_name]
    test rdi, rdi
    jz .Ldone
    call strlen
    mov rsi, rax
    mov rdi, [rbx + CMD_name]
    call cmd_find
    cmp rax, rbx
    jne .Lfail
    mov r12, [rbx + CMD_keys]
    mov rdi, r12
    call strlen
    mov r13, rax
.Lbinding:
    test r13, r13
    jz .Lnext
    mov rdi, r12
    mov rsi, r13
    call next_word
    add r12, rcx
    sub r13, rcx
    test rdx, rdx
    jz .Lnext
    mov rdi, rax
    mov rsi, rdx
    call parse_combo
    test eax, eax
    jz .Lfail
    mov edi, eax
    mov esi, edx
    call keys_lookup
    cmp rax, [rbx + CMD_fn]
    jne .Lfail
    jmp .Lbinding
.Lnext:
    add rbx, CMD_SIZE
    jmp .Lcommand
.Ldone:
    # Native hints must account for shortcuts owned by the operating
    # system: each hint pair names a command, and the registry must be
    # able to render exactly that text. cmd_find has to resolve the
    # advertised name, keys_for has to render its binding, and the text
    # has to match byte for byte (Ctrl+L in the plain string below, the
    # .ifdef MACOS string when a build targets one of those), so printed
    # hint text can never drift from the actual binding.
    lea rbx, [rip + hints]
.Lhint:
    mov rdi, [rbx]
    test rdi, rdi
    jz .Lunbound
    call strlen
    mov rsi, rax
    mov rdi, [rbx]
    call cmd_find
    test rax, rax
    jz .Lfail
    mov rdi, rax
    call keys_for
    test rax, rax
    jz .Lfail
    mov r12, rax
    mov rdi, rax
    call strlen
    mov rsi, rax
    mov rdi, r12
    mov rdx, [rbx + 8]
    call str_eq_cstr
    test eax, eax
    jnz .Lhint_ok
    mov rdi, r12
    call log_cstr
    jmp .Lfail
.Lhint_ok:
    add rbx, 16
    jmp .Lhint
.Lunbound:
    # Unbound keys and unknown commands cannot invoke another action:
    # keys_lookup('a', MOD_ALT | MOD_SHIFT) must come back null (nothing
    # in the registry binds that combo) and cmd_find must reject a name
    # no row carries instead of falling through to some row's fn.
    mov edi, 'a'
    mov esi, MOD_ALT | MOD_SHIFT
    call keys_lookup
    test rax, rax
    jnz .Lfail
    lea rdi, [rip + unknown]
    mov esi, 17
    call cmd_find
    test rax, rax
    jnz .Lfail
    lea rdi, [rip + ok]
    call log_cstr
    xor eax, eax
    EPILOGUE
.Lfail:
    mov eax, 1
    EPILOGUE
.section .rodata
unknown: .asciz "unknown_command_x"
ok: .asciz "ok\n"
# hints: {advertised command name, the hint text its binding must render
# as}, null-terminated. Checked with cmd_find + keys_for above.
term_name: .asciz "clear_terminal"
.ifdef MACOS
term_hint: .asciz "\342\214\203L"
.else
term_hint: .asciz "Ctrl+L"
.endif
.p2align 3
hints:
    .quad term_name, term_hint, 0, 0
