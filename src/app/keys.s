# command registry and key bindings. A command row (COMMAND macro below, layout
# CMD_* in unn.inc) is {name, title, fn, keys} where `keys` is a space-separated
# list of ctrl+l style combo strings naming the command's default bindings.
# keys_init parses each combo into a KB row (bind), keys_lookup runs at key
# time in O(rows). cmd_find/cmd_for_fn find rows by name/fn, keys_for prints a
# binding as text. The table is only a registry — firing a command is
# keys_lookup'ing here (app.s's app_on_key, after the terminal got its chance
# at the key) and calling the fn it returns.
.include "unn.inc"

# one binding: (mods, keysym, CMD*), 16 bytes each
STRUCT
F KB_mods, 4
F KB_key, 4
F KB_cmd, 8             # CMD*
ENDSTRUCT KB_SIZE

.bss
.p2align 3
bindings: .zero VEC_SIZE        # vec of KB rows, later binds replace same-key rows

.text

# parse_combo(ptr, len) -> eax keysym (0 invalid), edx MOD_* bits from the
# ctrl+shift+x style tokens. '+' separates tokens, and a '+' as the first byte of
# a token is literal (the Plus key). r12 holds the pointer, r13 the length,
# r14d the mods, r15d the key.
FN parse_combo
    PROLOGUE 16
    mov r12, rdi
    mov r13, rsi
    xor r14d, r14d              # mods
    xor r15d, r15d              # key
.Lpc_tok:
    test r13, r13
    jz .Lpc_done
    # token until '+' (a '+' right at the start of a token is the key itself)
    xor ecx, ecx
    cmp byte ptr [r12], '+'
    jne 1f
    mov ecx, 1
    jmp 2f
1:  cmp rcx, r13
    jae 2f
    cmp byte ptr [r12 + rcx], '+'
    je 2f
    inc rcx
    jmp 1b
2:  mov [rsp], rcx
    mov rdi, r12
    mov rsi, rcx
    call combo_token
    test edx, edx
    jz 3f
    or r14d, edx
    jmp 4f
3:  mov r15d, eax
4:  mov rcx, [rsp]
    add r12, rcx
    sub r13, rcx
    test r13, r13
    jz .Lpc_done
    cmp byte ptr [r12], '+'
    jne .Lpc_tok
    inc r12
    dec r13
    jmp .Lpc_tok
.Lpc_done:
    mov eax, r15d
    mov edx, r14d
    EPILOGUE

# combo_token(ptr, len) -> for a modifier name: edx MOD_* bit, eax 0. For a
# key name: eax keysym, edx 0. Matched case-insensitively against mod_names
# then key_names. A single character is its own keysym (lowercased), anything
# longer falls to keysym_value's table.
combo_token:
    PROLOGUE
    mov r12, rdi
    mov r13, rsi
    lea rbx, [rip + mod_names]
1:  mov rdx, [rbx]
    test rdx, rdx
    jz 2f
    mov rdi, r12
    mov rsi, r13
    call str_ieq_cstr
    test eax, eax
    jnz 3f
    add rbx, 16
    jmp 1b
3:  mov edx, [rbx + 8]
    xor eax, eax
    EPILOGUE
2:  lea rbx, [rip + key_names]
4:  mov rdx, [rbx]
    test rdx, rdx
    jz 5f
    mov rdi, r12
    mov rsi, r13
    call str_ieq_cstr
    test eax, eax
    jnz 6f
    add rbx, 16
    jmp 4b
6:  mov eax, [rbx + 8]
    xor edx, edx
    EPILOGUE
5:  # single character (lowercased), else any keysym name
    xor edx, edx
    cmp r13, 1
    jne 7f
    movzx edi, byte ptr [r12]
    call to_lower
    xor edx, edx
    EPILOGUE
7:  mov rdi, r12
    mov rsi, r13
    call keysym_value
    xor edx, edx
    EPILOGUE

# str_ieq_cstr(ptr, len, cstr) -> eax 1 if the bytes equal the NUL-terminated
# string, ascii case-insensitively (strlen first for the other side's length)
FN str_ieq_cstr
    push rbx
    push r12
    push r13
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov rdi, rdx
    call strlen
    mov rdi, rbx
    mov rsi, r12
    mov rdx, r13
    mov rcx, rax
    call str_ieq
    pop r13
    pop r12
    pop rbx
    ret

# bind(cmd*, ptr, len): parse the combo string into a KB row. An existing row
# bound to the same keysym+mods is replaced in place, otherwise one is pushed.
# Internal, called by keys_init.
bind:
    PROLOGUE
    mov rbx, rdi
    mov rdi, rsi
    mov rsi, rdx
    call parse_combo
    test eax, eax
    jz 9f
    mov r12d, eax
    mov r13d, edx
    # replace an existing binding of the same keys
    xor ecx, ecx
1:  cmp rcx, [rip + bindings + VEC_len]
    jae 2f
    imul rax, rcx, KB_SIZE
    add rax, [rip + bindings + VEC_ptr]
    cmp [rax + KB_key], r12d
    jne 11f
    cmp [rax + KB_mods], r13d
    jne 11f
    mov [rax + KB_cmd], rbx
    jmp 9f
11: inc rcx
    jmp 1b
2:  lea rdi, [rip + bindings]
    mov esi, KB_SIZE
    call vec_push
    mov [rax + KB_key], r12d
    mov [rax + KB_mods], r13d
    mov [rax + KB_cmd], rbx
9:  EPILOGUE

# cmd_find(ptr, len) -> rax CMD* row whose name matches, else 0. Null-terminated
# g_commands table (the last row's name is 0).
FN cmd_find
    PROLOGUE
    mov r12, rdi
    mov r13, rsi
    lea rbx, [rip + g_commands]
1:  mov rdx, [rbx + CMD_name]
    test rdx, rdx
    jz 2f
    mov rdi, r12
    mov rsi, r13
    call str_eq_cstr
    test eax, eax
    jnz 3f
    add rbx, CMD_SIZE
    jmp 1b
2:  xor ebx, ebx
3:  mov rax, rbx
    EPILOGUE

# cmd_for_fn(fn) -> rax the command whose handler fn is rdi, else 0
FN cmd_for_fn
    lea rax, [rip + g_commands]
1:  cmp qword ptr [rax + CMD_name], 0
    je 2f
    cmp [rax + CMD_fn], rdi
    je 3f
    add rax, CMD_SIZE
    jmp 1b
2:  xor eax, eax
3:  ret

# keys_init(): turn each command's own space-separated combo string (CMD_keys)
# into KB rows. next_word yields one combo at a time and bind registers it.
FN keys_init
    PROLOGUE
    lea rbx, [rip + g_commands]
.Lki_cmd:
    cmp qword ptr [rbx + CMD_name], 0
    je .Lki_end
    mov r12, [rbx + CMD_keys]
    mov rdi, r12
    call strlen
    mov r13, rax
1:  test r13, r13
    jz 2f
    mov rdi, r12
    mov rsi, r13
    call next_word
    add r12, rcx
    sub r13, rcx
    test rdx, rdx
    jz 2f
    mov rdi, rbx
    mov rsi, rax
    call bind
    jmp 1b
2:  add rbx, CMD_SIZE
    jmp .Lki_cmd
.Lki_end:
    EPILOGUE

# keys_lookup(keysym, mods) -> rax handler fn, or 0 when nothing is bound.
# Letters are bound lowercase, so 'A'..'Z' is folded to 'a'..'z' (Shift stays a
# mod bit). ISO_Left_Tab is folded to Tab so shift+tab matches a Tab binding.
FN keys_lookup
    # letters bind lowercase; shift is part of mods
    lea eax, [rdi - 'A']
    cmp eax, 25
    ja 1f
    or edi, 0x20
1:  cmp edi, KEY_ISO_LEFT_TAB
    jne 2f
    mov edi, KEY_TAB
2:  xor ecx, ecx
3:  cmp rcx, [rip + bindings + VEC_len]
    jae 5f
    imul rax, rcx, KB_SIZE
    add rax, [rip + bindings + VEC_ptr]
    cmp [rax + KB_key], edi
    jne 4f
    cmp [rax + KB_mods], esi
    jne 4f
    mov rax, [rax + KB_cmd]
    mov rax, [rax + CMD_fn]
    ret
4:  inc rcx
    jmp 3b
5:  xor eax, eax
    ret

# keys_for(cmd*) -> rax static keybuf with the binding as Ctrl+Shift+P style
# Modifier prefixes in KB order (ctrl shift alt super), then the key's name:
# a key_names row when there is one, else the single character capitalized.
FN keys_for
    PROLOGUE
    mov rbx, rdi
    xor ecx, ecx
1:  cmp rcx, [rip + bindings + VEC_len]
    jae 8f
    imul r12, rcx, KB_SIZE
    add r12, [rip + bindings + VEC_ptr]
    cmp [r12 + KB_cmd], rbx
    je 2f
    inc rcx
    jmp 1b
2:  lea r13, [rip + keybuf]
    mov r14d, [r12 + KB_mods]
    test r14d, MOD_CTRL
    jz 3f
    lea rsi, [rip + .Lctrl]
    mov rdi, r13
    call cstr_copy
    mov r13, rax
3:  test r14d, MOD_SHIFT
    jz 4f
    lea rsi, [rip + .Lshift]
    mov rdi, r13
    call cstr_copy
    mov r13, rax
4:  test r14d, MOD_ALT
    jz 5f
    lea rsi, [rip + .Lalt]
    mov rdi, r13
    call cstr_copy
    mov r13, rax
5:  test r14d, MOD_SUPER
    jz 6f
    lea rsi, [rip + .Lsuper]
    mov rdi, r13
    call cstr_copy
    mov r13, rax
6:  # key name
    mov eax, [r12 + KB_key]
    lea rbx, [rip + key_names]
7:  cmp qword ptr [rbx], 0
    je 71f
    cmp [rbx + 8], eax
    je 72f
    add rbx, 16
    jmp 7b
72: mov rsi, [rbx]
    mov rdi, r13
    call cstr_copy
    # nothing more: a named key is copied as-is, the table already stores
    # title case ("Enter", "PageUp", ...)
    lea rdi, [rip + keybuf]
    jmp 73f
71: lea ecx, [rax - 'a']
    cmp ecx, 25
    ja 74f
    sub eax, 32                  # lowercase key -> capital, as in "ctrl+p" → "P"
74: mov [r13], al
    mov byte ptr [r13 + 1], 0
73: # both paths return here: rax = keybuf
    lea rax, [rip + keybuf]
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

.section .rodata
.p2align 3
.Lctrl: .asciz "Ctrl+"
.Lshift: .asciz "Shift+"
.Lalt: .asciz "Alt+"
.Lsuper: .asciz "Super+"
mod_names:                    # {cstr, MOD_* bit} pairs, null-terminated
    .quad .Lm_ctrl, MOD_CTRL, .Lm_control, MOD_CTRL, .Lm_shift, MOD_SHIFT, .Lm_alt, MOD_ALT
    .quad .Lm_super, MOD_SUPER, .Lm_cmd, MOD_SUPER, .Lm_meta, MOD_SUPER, 0, 0
.Lm_ctrl: .asciz "ctrl"
.Lm_control: .asciz "control"
.Lm_shift: .asciz "shift"
.Lm_alt: .asciz "alt"
.Lm_super: .asciz "super"
.Lm_cmd: .asciz "cmd"
.Lm_meta: .asciz "meta"
key_names:
    .quad .Lk_enter, KEY_RETURN, .Lk_return, KEY_RETURN, .Lk_tab, KEY_TAB, .Lk_esc, KEY_ESCAPE
    .quad .Lk_escape, KEY_ESCAPE, .Lk_bs, KEY_BACKSPACE, .Lk_del, KEY_DELETE, .Lk_delete, KEY_DELETE
    .quad .Lk_up, KEY_UP, .Lk_down, KEY_DOWN, .Lk_left, KEY_LEFT, .Lk_right, KEY_RIGHT
    .quad .Lk_home, KEY_HOME, .Lk_end, KEY_END, .Lk_pgup, KEY_PAGEUP, .Lk_pgdn, KEY_PAGEDOWN
    .quad .Lk_ins, KEY_INSERT, .Lk_space, ' ', .Lk_plus, '+', .Lk_comma, ','
    .quad .Lk_f1, KEY_F1, .Lk_f2, KEY_F1 + 1, .Lk_f3, KEY_F1 + 2, .Lk_f4, KEY_F1 + 3
    .quad .Lk_f5, KEY_F1 + 4, .Lk_f6, KEY_F1 + 5, .Lk_f7, KEY_F1 + 6, .Lk_f8, KEY_F1 + 7
    .quad .Lk_f9, KEY_F1 + 8, .Lk_f10, KEY_F1 + 9, .Lk_f11, KEY_F1 + 10, .Lk_f12, KEY_F1 + 11
    .quad 0, 0
.Lk_enter: .asciz "Enter"
.Lk_return: .asciz "Return"
.Lk_tab: .asciz "Tab"
.Lk_esc: .asciz "Esc"
.Lk_escape: .asciz "Escape"
.Lk_bs: .asciz "Backspace"
.Lk_del: .asciz "Del"
.Lk_delete: .asciz "Delete"
.Lk_up: .asciz "Up"
.Lk_down: .asciz "Down"
.Lk_left: .asciz "Left"
.Lk_right: .asciz "Right"
.Lk_home: .asciz "Home"
.Lk_end: .asciz "End"
.Lk_pgup: .asciz "PageUp"
.Lk_pgdn: .asciz "PageDown"
.Lk_ins: .asciz "Insert"
.Lk_space: .asciz "Space"
.Lk_plus: .asciz "Plus"
.Lk_comma: .asciz "Comma"
.Lk_f1: .asciz "F1"
.Lk_f2: .asciz "F2"
.Lk_f3: .asciz "F3"
.Lk_f4: .asciz "F4"
.Lk_f5: .asciz "F5"
.Lk_f6: .asciz "F6"
.Lk_f7: .asciz "F7"
.Lk_f8: .asciz "F8"
.Lk_f9: .asciz "F9"
.Lk_f10: .asciz "F10"
.Lk_f11: .asciz "F11"
.Lk_f12: .asciz "F12"

# COMMAND name, title, fn, keys: one g_commands row (CMD_* order): .quad
# pointers to the name, title and keys strings in .rodata, plus the fn address
# (third quad, before the keys pointer), then the strings themselves. The table
# is under .p2align 3 because CMD rows are read by stride CMD_SIZE and the null
# row terminates keys_init/cmd_find.
.macro COMMAND name, title, fn, keys
    .quad 1f, 2f, \fn, 3f
    .pushsection .rodata.str, "aMS", @progbits, 1
1:  .asciz "\name"
2:  .asciz "\title"
3:  .asciz "\keys"
    .popsection
.endm

# g_commands: the command registry, one COMMAND row each, terminated by the
# null row. Row layout (unn.inc CMD_*): name, title, fn, keys. The keys string
# lists the defaults keys_init parses. zoom_in's six combos cover the Equal and
# Plus keys in plain, shifted and keypad (KP_Add/KP_Equal) spellings.
.p2align 3
.globl g_commands
g_commands:
    COMMAND quit, "Quit", cmd_quit, "Super+q"
    COMMAND clear_terminal, "Clear Terminal", cmd_clear_terminal, "ctrl+l"
    COMMAND zoom_in, "Zoom In", cmd_zoom_in, "ctrl+= ctrl++ ctrl+shift+= ctrl+shift++ ctrl+KP_Add ctrl+KP_Equal"
    COMMAND zoom_out, "Zoom Out", cmd_zoom_out, "ctrl+- ctrl+KP_Subtract"
    COMMAND zoom_reset, "Reset Zoom", cmd_zoom_reset, "ctrl+0 ctrl+KP_0"
    .quad 0, 0, 0, 0

.bss
keybuf: .zero 64                # keys_for's static result, Ctrl+Shift+P form
