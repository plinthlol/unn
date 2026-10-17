# XKB keymap parser for the text compositors send on wl_keyboard.keymap:
# xkb_parse lexes a full keymap file and fills xkb_map[kc][group][level]
# with keysyms; wayland.s turns a keycode + mods into a keysym by calling
# xkb_keysym at every key event.
# The tables are all here and rebuilt from nothing on every parse: the map
# (cleared), the keyname->keycode table (kc_*), g_xkb_ngroups (back to 1).
.include "unn.inc"

.equ TOK_EOF, 0
.equ TOK_IDENT, 1
.equ TOK_KEYNAME, 2
.equ TOK_STRING, 3
.equ TOK_PUNCT, 4
.equ MAXNAMES, 768

.bss
.p2align 4
.globl xkb_map
xkb_map: .zero 256 * 4 * 4 * 4
kc_names: .zero 8 * MAXNAMES
kc_codes: .zero 2 * MAXNAMES
kc_n: .long 0
xk_p: .quad 0
xk_end: .quad 0
tok_type: .long 0
tok_ch: .long 0
tok_ptr: .quad 0
tok_len: .quad 0

.text

# xk_next(): lex the next token out of xk_p..xk_end into tok_type / tok_ch /
# tok_ptr / tok_len. Bytes <= ' ' are whitespace and // comments run to the
# newline; both vanish here. '<...>' is a TOK_KEYNAME and '...' a TOK_STRING
# with tok_ptr/tok_len spanning the inside, an is_ident run a TOK_IDENT, and
# anything else a one-byte TOK_PUNCT with its byte in tok_ch. At the end of
# the text: TOK_EOF, tok_ch 0.
xk_next:
    mov rsi, [rip + xk_p]
    mov rdi, [rip + xk_end]
.Lxn_ws:
    cmp rsi, rdi
    jae .Lxn_eof
    movzx eax, byte ptr [rsi]
    cmp al, ' '
    jbe .Lxn_skip1
    cmp al, '/'
    jne .Lxn_tok
    lea rcx, [rsi + 1]
    cmp rcx, rdi
    jae .Lxn_tok
    cmp byte ptr [rcx], '/'
    jne .Lxn_tok
.Lxn_comment:
    cmp rsi, rdi
    jae .Lxn_eof
    cmp byte ptr [rsi], 10
    je .Lxn_ws
    inc rsi
    jmp .Lxn_comment
.Lxn_skip1:
    inc rsi
    jmp .Lxn_ws
.Lxn_tok:
    cmp al, '<'
    je .Lxn_keyname
    cmp al, '"'
    je .Lxn_string
    push rdi
    mov edi, eax
    call is_ident
    pop rdi
    test eax, eax
    jnz .Lxn_ident
    movzx eax, byte ptr [rsi]
    mov dword ptr [rip + tok_type], TOK_PUNCT
    mov [rip + tok_ch], eax
    inc rsi
    jmp .Lxn_done
.Lxn_keyname:
    inc rsi
    mov [rip + tok_ptr], rsi
1:  cmp rsi, rdi
    jae 2f
    cmp byte ptr [rsi], '>'
    je 2f
    inc rsi
    jmp 1b
2:  mov rax, rsi
    sub rax, [rip + tok_ptr]
    mov [rip + tok_len], rax
    inc rsi
    mov dword ptr [rip + tok_type], TOK_KEYNAME
    jmp .Lxn_done
.Lxn_string:
    inc rsi
    mov [rip + tok_ptr], rsi
1:  cmp rsi, rdi
    jae 2f
    cmp byte ptr [rsi], '"'
    je 2f
    inc rsi
    jmp 1b
2:  mov rax, rsi
    sub rax, [rip + tok_ptr]
    mov [rip + tok_len], rax
    inc rsi
    mov dword ptr [rip + tok_type], TOK_STRING
    jmp .Lxn_done
.Lxn_ident:
    mov [rip + tok_ptr], rsi
1:  inc rsi
    cmp rsi, rdi
    jae 2f
    push rdi
    push rsi
    movzx edi, byte ptr [rsi]
    call is_ident
    pop rsi
    pop rdi
    test eax, eax
    jnz 1b
2:  mov rax, rsi
    sub rax, [rip + tok_ptr]
    mov [rip + tok_len], rax
    mov dword ptr [rip + tok_type], TOK_IDENT
.Lxn_done:
    mov [rip + xk_p], rsi
    ret
.Lxn_eof:
    mov [rip + xk_p], rsi
    mov dword ptr [rip + tok_type], TOK_EOF
    mov dword ptr [rip + tok_ch], 0
    ret

# IS_PUNCT ch: macro, not a call. ZF set when the current token is a
# TOK_PUNCT holding the byte ch, so plain je/jne follow it.
.macro IS_PUNCT ch
    cmp dword ptr [rip + tok_type], TOK_PUNCT
    jne 99f
    cmp dword ptr [rip + tok_ch], \ch
99:
.endm

# tok_is(cstr) -> eax 1 if the current token is a TOK_IDENT spelling cstr:
# its tok_ptr/tok_len compared against the cstr via str_eq_cstr. Anything
# else is 0.
tok_is:
    xor eax, eax
    cmp dword ptr [rip + tok_type], TOK_IDENT
    jne 1f
    mov rdx, rdi
    mov rdi, [rip + tok_ptr]
    mov rsi, [rip + tok_len]
    call str_eq_cstr
1:  ret

# tok_pack() -> rax the current token packed into a u64, the first
# character in the low byte, capped at 8 (longer names keep the first 8).
# This is how keynames become the integers kc_lookup/kc_add compare.
tok_pack:
    xor eax, eax
    mov rsi, [rip + tok_ptr]
    mov rcx, [rip + tok_len]
    cmp rcx, 8
    jbe 1f
    mov ecx, 8
1:  test rcx, rcx
    jz 2f
    movzx edx, byte ptr [rsi + rcx - 1]
    shl rax, 8
    or rax, rdx
    dec rcx
    jmp 1b
2:  ret

# kc_lookup(packed) -> eax keycode, or -1 when no keyname defines it.
# kc_names/kc_codes is the table kc_add fills from the xkb_keycodes section,
# one row per keyname or alias.
kc_lookup:
    lea rsi, [rip + kc_names]
    xor ecx, ecx
1:  cmp ecx, [rip + kc_n]
    jae 2f
    cmp [rsi + rcx*8], rdi
    je 3f
    inc ecx
    jmp 1b
2:  mov eax, -1
    ret
3:  lea rsi, [rip + kc_codes]
    movzx eax, word ptr [rsi + rcx*2]
    ret

# kc_add(packed rdi, code in si): append a keyname row; silently dropped once
# MAXNAMES rows exist.
kc_add:
    mov ecx, [rip + kc_n]
    cmp ecx, MAXNAMES
    jae 1f
    lea rax, [rip + kc_names]
    mov [rax + rcx*8], rdi
    lea rax, [rip + kc_codes]
    mov [rax + rcx*2], si
    inc dword ptr [rip + kc_n]
1:  ret

# skip tokens until ';' or unbalanced '}' at depth 0 (the ';' is consumed, '}' is not)
skip_stmt:
    push rbx
    xor ebx, ebx
1:  call xk_next
    cmp dword ptr [rip + tok_type], TOK_EOF
    je 9f
    cmp dword ptr [rip + tok_type], TOK_PUNCT
    jne 1b
    mov eax, [rip + tok_ch]
    cmp eax, '{'
    je 2f
    cmp eax, '['
    je 2f
    cmp eax, '}'
    je 3f
    cmp eax, ']'
    je 3f
    cmp eax, ';'
    jne 1b
    test ebx, ebx
    jz 9f
    jmp 1b
2:  inc ebx
    jmp 1b
3:  test ebx, ebx
    jz 8f
    dec ebx
    jmp 1b
8:  # unbalanced close: push it back by marking
    dec qword ptr [rip + xk_p]
9:  pop rbx
    ret

# skip_group: eat through the '}' or ']' that balances whatever opener is the
# current token (depth 1 after it), so a whole value between openers vanishes
# for the callers that only want the ';' afterwards. EOF ends it.
skip_group:
    push rbx
    mov ebx, 1
1:  call xk_next
    cmp dword ptr [rip + tok_type], TOK_EOF
    je 9f
    cmp dword ptr [rip + tok_type], TOK_PUNCT
    jne 1b
    mov eax, [rip + tok_ch]
    cmp eax, '{'
    je 2f
    cmp eax, '['
    je 2f
    cmp eax, '}'
    je 3f
    cmp eax, ']'
    je 3f
    jmp 1b
2:  inc ebx
    jmp 1b
3:  dec ebx
    jnz 1b
9:  pop rbx
    ret

# find_section(cstr rdi): scan for the TOK_IDENT cstr and then the '{' that
# opens its body; both (and whatever sat between them) are consumed.
# -> eax 1 found, 0 at EOF.
find_section:
    push rbx
    mov rbx, rdi
1:  call xk_next
    cmp dword ptr [rip + tok_type], TOK_EOF
    je 3f
    mov rdi, rbx
    call tok_is
    test eax, eax
    jz 1b
2:  call xk_next
    cmp dword ptr [rip + tok_type], TOK_EOF
    je 3f
    IS_PUNCT '{'
    jne 2b
    mov eax, 1
    pop rbx
    ret
3:  xor eax, eax
    pop rbx
    ret

# keysym_value(ptr, len) -> eax keysym, 0 if unknown. A one-character name
# is its own latin-1 keysym; "0x..." parses as hex; "U..." becomes
# 0x1000000 plus the hex value, but only when every byte after the U was a
# hex digit (parse_hex reports how many it parsed in rdx); otherwise a
# binary search of the keysym_names table (keysyms.s, sorted by name).
FN keysym_value
    push rbx
    push r12
    push r13
    mov rbx, rdi
    mov r12, rsi
    cmp r12, 1
    jne 1f
    movzx eax, byte ptr [rbx]
    jmp .Lkv_ret
1:  cmp r12, 2
    jbe 2f
    cmp word ptr [rbx], 0x7830      # "0x"
    jne 2f
    lea rdi, [rbx + 2]
    lea rsi, [r12 - 2]
    call parse_hex
    jmp .Lkv_ret
2:  cmp byte ptr [rbx], 'U'
    jne 3f
    cmp r12, 5
    jb 3f
    lea rdi, [rbx + 1]
    lea rsi, [r12 - 1]
    call parse_hex
    lea rcx, [r12 - 1]
    cmp rdx, rcx
    jne 3f
    add eax, 0x1000000
    jmp .Lkv_ret
3:  # binary search by name
    xor r13d, r13d                  # lo
    mov r8, [rip + keysym_names_count] # hi
4:  cmp r13, r8
    jae 6f
    lea r9, [r13 + r8]
    shr r9, 1
    mov rax, r9
    shl rax, 4
    lea rdx, [rip + keysym_names]
    mov r10, [rdx + rax]            # name
    xor ecx, ecx
41: xor eax, eax
    cmp rcx, r12
    jae 42f
    movzx eax, byte ptr [rbx + rcx]
42: movzx edx, byte ptr [r10 + rcx]
    cmp eax, edx
    jne 43f
    test eax, eax
    jz 5f
    inc rcx
    jmp 41b
43: jb 44f
    lea r13, [r9 + 1]
    jmp 4b
44: mov r8, r9
    jmp 4b
5:  mov rax, r9
    shl rax, 4
    lea rdx, [rip + keysym_names]
    mov eax, [rdx + rax + 8]
    jmp .Lkv_ret
6:  xor eax, eax
.Lkv_ret:
    pop r13
    pop r12
    pop rbx
    ret

# parse_levels(code edi, group esi): current token is the '[' that opens a
# symbols row. Ident tokens are the keysyms of the level r13d counts,
# ',' advances the level, and a nested '{' list keeps only its first
# keysym, skipping the rest. .Lpl_store clamps to code <= 255, group <= 3,
# level <= 3 and grows g_xkb_ngroups to group+1 when the row is wider than
# the map has seen. ']' or EOF ends it. Keeps rbx, r12-r13.
parse_levels:
    push rbx
    push r12
    push r13
    mov ebx, edi
    mov r12d, esi
    xor r13d, r13d                  # level
.Lpl_loop:
    call xk_next
    cmp dword ptr [rip + tok_type], TOK_EOF
    je .Lpl_ret
    cmp dword ptr [rip + tok_type], TOK_IDENT
    je .Lpl_sym
    cmp dword ptr [rip + tok_type], TOK_PUNCT
    jne .Lpl_loop
    mov eax, [rip + tok_ch]
    cmp eax, ']'
    je .Lpl_ret
    cmp eax, ','
    jne 1f
    inc r13d
    jmp .Lpl_loop
1:  cmp eax, '{'
    jne .Lpl_loop
    # multiple keysyms for one level: use the first
    call xk_next
    cmp dword ptr [rip + tok_type], TOK_IDENT
    jne 2f
    call .Lpl_store
2:  call skip_group
    jmp .Lpl_loop
.Lpl_sym:
    call .Lpl_store
    jmp .Lpl_loop
.Lpl_ret:
    pop r13
    pop r12
    pop rbx
    ret
.Lpl_store:
    cmp ebx, 255
    ja 1f
    cmp r12d, 3
    ja 1f
    cmp r13d, 3
    ja 1f
    mov rdi, [rip + tok_ptr]
    mov rsi, [rip + tok_len]
    call keysym_value
    mov ecx, ebx
    shl ecx, 4
    lea ecx, [rcx + r12*4]
    add ecx, r13d
    lea rdx, [rip + xkb_map]
    mov [rdx + rcx*4], eax
    lea eax, [r12 + 1]
    cmp eax, [rip + g_xkb_ngroups]
    jbe 1f
    mov [rip + g_xkb_ngroups], eax
1:  ret

# parse_key(code edi, kept in ebx): current token is the '{' of a key body.
# A bare '[...]' row is an implicit group, r12d counting those; a "symbols"
# row (r13d remembers it) may name one as "symbols [GroupN]" where the
# group index is just the digits at the end of the bracket token, taken
# 1-based (0 becomes "use the implicit counter"). After '=', '[' means
# parse_levels for symbols rows and skip_group for everything else the
# map does not want. Keeps rbx, r12-r13.
parse_key:
    push rbx
    push r12
    push r13
    mov ebx, edi
    xor r12d, r12d                  # implicit group counter
.Lpk_loop:
    call xk_next
    cmp dword ptr [rip + tok_type], TOK_EOF
    je .Lpk_ret
    IS_PUNCT '}'
    je .Lpk_ret
    IS_PUNCT '['
    jne 1f
    mov edi, ebx
    mov esi, r12d
    call parse_levels
    inc r12d
    jmp .Lpk_loop
1:  cmp dword ptr [rip + tok_type], TOK_IDENT
    jne .Lpk_loop
    lea rdi, [rip + .Lsymbols]
    call tok_is
    mov r13d, eax
    # optional [GroupN] index
    call xk_next
    IS_PUNCT '['
    jne 3f
    call xk_next
    mov rdi, [rip + tok_ptr]
    mov rsi, [rip + tok_len]
    # digits at end of token -> group number
    lea rax, [rdi + rsi]
2:  cmp rax, rdi
    je 21f
    movzx ecx, byte ptr [rax - 1]
    sub ecx, '0'
    cmp ecx, 9
    ja 21f
    dec rax
    jmp 2b
21: mov rdi, rax
    mov rsi, [rip + tok_ptr]
    add rsi, [rip + tok_len]
    sub rsi, rax
    call parse_u64
    dec eax
    js 22f
    mov r12d, eax
22: call xk_next                    # ']'
    call xk_next                    # '='
3:  IS_PUNCT '='
    jne .Lpk_loop
    call xk_next
    IS_PUNCT '['
    jne .Lpk_loop
    test r13d, r13d
    jz 4f
    mov edi, ebx
    mov esi, r12d
    call parse_levels
    inc r12d
    jmp .Lpk_loop
4:  call skip_group
    jmp .Lpk_loop
.Lpk_ret:
    pop r13
    pop r12
    pop rbx
    ret

# xkb_parse(text, len): lex a whole keymap. Zeroes xkb_map, empties kc_n and
# resets g_xkb_ngroups to 1, then two passes: find xkb_keycodes and fill
# the keyname table from <'name'> = code and alias rows (everything else
# gets skip_stmt), rewind xk_p to the text start saved at entry, find
# xkb_symbols and fill the map from key = { ... } rows.
FN xkb_parse
    PROLOGUE
    mov [rip + xk_p], rdi
    add rsi, rdi
    mov [rip + xk_end], rsi
    mov r12, rdi
    lea rdi, [rip + xkb_map]
    xor eax, eax
    mov ecx, 256 * 4 * 4
    rep stosd
    mov dword ptr [rip + kc_n], 0
    mov dword ptr [rip + g_xkb_ngroups], 1
    lea rdi, [rip + .Lkeycodes]
    call find_section
    test eax, eax
    jz .Lxp_ret
.Lxp_kc:
    call xk_next
    cmp dword ptr [rip + tok_type], TOK_EOF
    je .Lxp_ret
    IS_PUNCT '}'
    je .Lxp_symbols
    cmp dword ptr [rip + tok_type], TOK_KEYNAME
    jne .Lxp_kc_other
    call tok_pack
    mov rbx, rax
    call xk_next                    # '='
    call xk_next                    # number
    mov rdi, [rip + tok_ptr]
    mov rsi, [rip + tok_len]
    call parse_u64
    mov rdi, rbx
    mov esi, eax
    call kc_add
    call skip_stmt
    jmp .Lxp_kc
.Lxp_kc_other:
    lea rdi, [rip + .Lalias]
    call tok_is
    test eax, eax
    jz 1f
    call xk_next
    call tok_pack
    mov rbx, rax
    call xk_next                    # '='
    call xk_next
    call tok_pack
    mov rdi, rax
    call kc_lookup
    test eax, eax
    js 2f
    mov rdi, rbx
    mov esi, eax
    call kc_add
2:  call skip_stmt
    jmp .Lxp_kc
1:  call skip_stmt
    jmp .Lxp_kc
.Lxp_symbols:
    mov [rip + xk_p], r12
    lea rdi, [rip + .Lsymsec]
    call find_section
    test eax, eax
    jz .Lxp_ret
.Lxp_sym:
    call xk_next
    cmp dword ptr [rip + tok_type], TOK_EOF
    je .Lxp_ret
    IS_PUNCT '}'
    je .Lxp_ret
    lea rdi, [rip + .Lkey]
    call tok_is
    test eax, eax
    jz .Lxp_sym_other
    call xk_next
    call tok_pack
    mov rdi, rax
    call kc_lookup
    mov ebx, eax
    call xk_next                    # '{'
    IS_PUNCT '{'
    jne .Lxp_sym
    mov edi, ebx
    call parse_key
    call skip_stmt                  # ';'
    jmp .Lxp_sym
.Lxp_sym_other:
    call skip_stmt
    jmp .Lxp_sym
.Lxp_ret:
    EPILOGUE

# xkb_keysym(keycode, group, mods) -> eax keysym. Keycodes above 255 (the
# map's 256 rows) are 0; group >= g_xkb_ngroups falls to group 1, and so
# does a group row with no level-0 keysym (r9/r10 = key row / group row).
# Level comes from mods: MOD_SHIFT is +1, and keypad keys (level-1 keysym
# 0xff80..0xffbc) swap levels 0/1 under num lock (mod2, bit 0x10) so the
# digits keep coming out; caps lock (bit 2) also swaps when keysym_is_lower
# says the base keysym is a lowercase letter; level3 is mod5, bit 0x80,
# +2. Levels that were never filled (0) drop to level&1, then to level 0.
FN xkb_keysym
    cmp edi, 255
    ja .Lks_none
    cmp esi, [rip + g_xkb_ngroups]
    jb 1f
    xor esi, esi
1:  lea r8, [rip + xkb_map]
    mov eax, edi
    shl eax, 4
    lea r9, [r8 + rax*4]            # key row
    mov r10d, esi
    shl r10, 4
    add r10, r9                     # group row
    cmp dword ptr [r10], 0
    jne 2f
    mov r10, r9                     # group missing: use group 1
2:  xor ecx, ecx                    # level
    test edx, MOD_SHIFT
    jz 21f
    mov ecx, 1
21: test edx, 0x10                  # num lock (mod2): keypad keys swap levels, digits first
    jz 3f
    mov eax, [r10 + 4]
    sub eax, 0xff80
    cmp eax, 0xffbd - 0xff80
    ja 3f
    xor ecx, 1
3:  test edx, 2                     # caps lock
    jz 4f
    mov eax, [r10]
    push rcx
    push rdx
    mov edi, eax
    call keysym_is_lower
    pop rdx
    pop rcx
    test eax, eax
    jz 4f
    xor ecx, 1
4:  test edx, 0x80                  # level3 (mod5)
    jz 5f
    add ecx, 2
5:  mov eax, [r10 + rcx*4]
    test eax, eax
    jnz 6f
    and ecx, 1
    mov eax, [r10 + rcx*4]
    test eax, eax
    jnz 6f
    mov eax, [r10]
6:  ret
.Lks_none:
    xor eax, eax
    ret

# keysym_is_lower(ks) -> 1 for keysyms that are lowercase letters: ASCII
# a-z; Latin-1 0xdf..0xfe except the division sign 0xf7; and the legacy
# keysym block 0x6a1..0x6af / 0x6c0..0x6df, where Cyrillic lowercase
# (dje, yu, yeru, ...) lives.
keysym_is_lower:
    xor eax, eax
    lea ecx, [rdi - 'a']
    cmp ecx, 25
    jbe 1f
    lea ecx, [rdi - 0xdf]
    cmp ecx, 0xfe - 0xdf
    ja 2f
    cmp edi, 0xf7
    jne 1f
    ret
2:  lea ecx, [rdi - 0x6c0]
    cmp ecx, 0x1f
    jbe 1f
    lea ecx, [rdi - 0x6a1]
    cmp ecx, 0x0e
    jbe 1f
    ret
1:  mov eax, 1
    ret

# keysym_to_unicode(ks) -> eax codepoint, 0 when there is no mapping.
# Latin-1 characters (0x20..0x7e, 0xa0..0xff) are themselves, and
# 0x1000000+ is raw Unicode (what keymap "Uxxxx" names became in
# keysym_value). The keypad is special: KP_Space (0xff80) is ' ', the
# 0xffaa..0xffb9 KP_* set comes out of .Lkp_chars, KP_Equal is '=';
# anything else into the binary search of the keysym_ucs table (keysyms.s,
# generated from keysymdef.h).
FN keysym_to_unicode
    mov eax, edi
    cmp eax, 0x20
    jb .Lku_none
    cmp eax, 0x7e
    jbe .Lku_ret
    cmp eax, 0xa0
    jb .Lku_none
    cmp eax, 0xff
    jbe .Lku_ret
    cmp eax, 0x1000000
    jb 2f
    sub eax, 0x1000000
    cmp eax, 0x10ffff
    ja .Lku_none
    ret
2:  cmp eax, 0xff80
    je .Lku_space
    lea ecx, [rax - 0xffaa]
    cmp ecx, 0xffb9 - 0xffaa
    ja 3f
    lea rdx, [rip + .Lkp_chars]
    movzx eax, byte ptr [rdx + rcx]
    test eax, eax
    jz .Lku_none
    ret
3:  cmp eax, 0xffbd
    jne 4f
    mov eax, '='
    ret
4:  # legacy keysyms (Latin 2-9, Greek, Cyrillic, Hebrew, Thai, ...): binary search
    xor ecx, ecx
    mov rdx, [rip + keysym_ucs_count]
    lea r8, [rip + keysym_ucs]
5:  cmp rcx, rdx
    jae .Lku_none
    lea r9, [rcx + rdx]
    shr r9, 1
    cmp eax, [r8 + r9*8]
    je 6f
    jb 7f
    lea rcx, [r9 + 1]
    jmp 5b
7:  mov rdx, r9
    jmp 5b
6:  mov eax, [r8 + r9*8 + 4]
    ret
.Lku_space:
    mov eax, ' '
    ret
.Lku_none:
    xor eax, eax
.Lku_ret:
    ret

.section .rodata
.Lkp_chars: .ascii "*+,-./0123456789"
.Lkeycodes: .asciz "xkb_keycodes"
.Lsymsec: .asciz "xkb_symbols"
.Lalias: .asciz "alias"
.Lkey: .asciz "key"
.Lsymbols: .asciz "symbols"
.data
.globl g_xkb_ngroups
g_xkb_ngroups: .long 1
