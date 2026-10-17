# the one theme: runtime/themes/unn.theme, embedded in the binary, in an
# XResources-like key = value plain text (theme_load). A key names a color
# slot by its slot_names string, and every slot the file does not name is derived
# from the ones it does (theme_derive), so a minimal file still gives a full
# palette. Entry points: theme_load(text, len) then any reader of g_theme
# (0xAARRGGBB words, one dword per T_* slot in src/unn.inc order).
# Internals: theme_next walks the source, the DERIVE/COPY/CONST/HUE/LEGIBLE
# macros fill undefined slots, parse_color/luma/legible are color helpers.
.include "unn.inc"


.bss
.p2align 3
.globl g_theme, g_theme_dark
g_theme: .zero 4 * T_COUNT        # slot colors (argb), later slots filled by derive
g_theme_dark: .long 0             # 1 dark, 0 light: from the kind key, default dark
defined: .zero 16                 # bit per slot the theme file gave (ISDEF)
.p2align 3
tp: .zero 8                       # theme text cursor: next byte, end
tend: .zero 8
tkey: .zero 8                     # current line's key and value, kept in memory
tkeylen: .zero 8                  #   because str_eq_cstr works in these registers
tval: .zero 8
tvallen: .zero 8

.text

# theme_next(): the next key = value line of the text tp..tend points into.
# Empty lines, '#'- and ';'-comments and lines without the '=' are skipped,
# spaces/
# tabs/CR trimmed at both ends of the key and of the value.
#   -> eax 1, rdi key, rsi keylen, r8 value, r9 vallen; or eax 0 at the end.
# tp is left past the line, so repeated calls walk the whole file.
theme_next:
    push r12
    push r13
.Ltn_line:
    mov r12, [rip + tp]
    mov r13, [rip + tend]
    cmp r12, r13
    jae .Ltn_end
    # find the end of the line
    mov rcx, r12
1:  cmp rcx, r13
    jae 2f
    cmp byte ptr [rcx], 10
    je 2f
    inc rcx
    jmp 1b
2:  lea rax, [rcx + 1]
    cmp rax, r13
    jbe 3f
    mov rax, r13
3:  mov [rip + tp], rax
    mov rdi, r12
    mov rsi, rcx
    sub rsi, r12
    call trim
    test rdx, rdx
    jz .Ltn_line
    movzx ecx, byte ptr [rax]
    cmp cl, '#'
    je .Ltn_line
    cmp cl, ';'
    je .Ltn_line
    # split at the first '='
    mov r12, rax
    mov r13, rdx
    xor ecx, ecx
4:  cmp rcx, r13
    jae .Ltn_line
    cmp byte ptr [r12 + rcx], '='
    je 5f
    inc rcx
    jmp 4b
5:  mov rdi, r12
    mov rsi, rcx
    push rcx
    call trim
    pop rcx
    push rax                     # key, length to hand out after the value
    push rdx
    lea rdi, [r12 + rcx + 1]
    mov rsi, r13
    sub rsi, rcx
    dec rsi
    call trim
    mov r8, rax
    mov r9, rdx
    pop rsi
    pop rdi
    mov eax, 1
    jmp .Ltn_ret
.Ltn_end:
    xor eax, eax
.Ltn_ret:
    pop r13
    pop r12
    ret

# theme_load(text, len): rdi the theme file's bytes, rsi length. The file never
# comes back: a later theme_load reuses the same g_theme slots, so every load
# starts by clearing `defined`. First the special kind key (light or dark),
# then each key is matched against slot_names in T_ order and its parsed color
# lands in g_theme. After the last line theme_derive fills the rest.
FN theme_load
    PROLOGUE 16
    mov qword ptr [rip + defined], 0
    mov qword ptr [rip + defined + 8], 0
    mov dword ptr [rip + g_theme_dark], 1
    mov [rip + tp], rdi          # the text from here to len bytes at its end
    add rdi, rsi
    mov [rip + tend], rdi
.Ltl_next:
    call theme_next
    test eax, eax
    jz .Ltl_derive
    mov [rip + tkey], rdi
    mov [rip + tkeylen], rsi
    mov [rip + tval], r8
    mov [rip + tvallen], r9
    lea rdx, [rip + .Lkind]
    call str_eq_cstr
    test eax, eax
    jz 1f
    mov rdi, [rip + tval]        # kind = light? anything else dark
    mov rsi, [rip + tvallen]
    lea rdx, [rip + .Llight]
    call str_eq_cstr
    xor eax, 1
    mov [rip + g_theme_dark], eax
    jmp .Ltl_next
1:  # slot name lookup
    lea rbx, [rip + slot_names]
    xor r12d, r12d
2:  cmp r12d, T_COUNT
    jae .Ltl_next
    mov rdi, [rip + tkey]
    mov rsi, [rip + tkeylen]
    mov rdx, [rbx + r12*8]
    call str_eq_cstr
    test eax, eax
    jnz 3f
    inc r12d
    jmp 2b
3:  mov rdi, [rip + tval]
    mov rsi, [rip + tvallen]
    call parse_color
    test edx, edx
    jz .Ltl_next
    lea rcx, [rip + g_theme]
    mov [rcx + r12*4], eax
    bts qword ptr [rip + defined], r12
    jmp .Ltl_next
.Ltl_derive:
    call theme_derive
    EPILOGUE

# slot-derivation macros. `defined` says the theme file gave the slot explicitly
# and it must not be touched. 88: is each macro's shared skip-out label.
#
# ISDEF slot       : carry set when the theme file named this slot
# DERIVE slot,a,b,t: else slot = mix(color a, color b, t)  (t in hundredths)
# DERIVE_C slot,a,c: else slot = mix(color a, fixed value c, t)
# COPY slot, src   : else slot = the value of another slot
# CONST slot, c    : else slot = the fixed value c
# HUE slot, term, c: else the terminal color `term` when the theme gave it,
# HUE slot, term, c: else the terminal color `term` when the theme gave it,
#                    else the fallback hue c — icon hues stay coordinated
#                    with the terminal palette
# LEGIBLE slot     : else the color is walked toward the text until 3:1 contrast
.macro ISDEF slot
    bt qword ptr [rip + defined + 8 * ((\slot) / 64)], (\slot) % 64
.endm

# DERIVE slot, a, b, t  : if slot undefined, slot = mix(color a, color b, t)
.macro DERIVE slot, a, b, t
    ISDEF \slot
    jc 88f
    mov edi, [rip + g_theme + 4*(\a)]
    mov esi, [rip + g_theme + 4*(\b)]
    mov edx, \t
    call color_mix
    mov [rip + g_theme + 4*(\slot)], eax
88:
.endm
.macro DERIVE_C slot, a, c, t
    ISDEF \slot
    jc 88f
    mov edi, [rip + g_theme + 4*(\a)]
    mov esi, \c
    mov edx, \t
    call color_mix
    mov [rip + g_theme + 4*(\slot)], eax
88:
.endm
.macro COPY slot, src
    ISDEF \slot
    jc 88f
    mov eax, [rip + g_theme + 4*(\src)]
    mov [rip + g_theme + 4*(\slot)], eax
88:
.endm
.macro CONST slot, c
    ISDEF \slot
    jc 88f
    mov dword ptr [rip + g_theme + 4*(\slot)], \c
88:
.endm

# HUE slot, term, c: the terminal color `term` when the theme gives it, else the
# fixed fallback hue c. Terminal blue, magenta and cyan default to the function/
# keyword/builtin syntax slots (accent-family colors, not true hues), so these
# icon hues stay coordinated with that palette unless the theme names the colors.
.macro HUE slot, term, c
    ISDEF \slot
    jc 88f
    mov eax, \c
    ISDEF \term
    jnc 87f
    mov eax, [rip + g_theme + 4*(\term)]
87: mov [rip + g_theme + 4*(\slot)], eax
88:
.endm

# LEGIBLE slot: a derived color moved toward the text until it has 3:1 contrast on the panel
.macro LEGIBLE slot
    ISDEF \slot
    jc 88f
    mov edi, [rip + g_theme + 4*(\slot)]
    call legible
    mov [rip + g_theme + 4*(\slot)], eax
88:
.endm

# theme_derive(): internal (no FN), called only by theme_load. Fill every slot
# `defined` does not cover. Dark and light take their own mixing constants. The
# common tail copies panel-derived chrome, sets syntax defaults from the
# accent/status colors, builds the 16 terminal palette entries (bright variants
# mix toward white) and the 10 file-icon hues.
theme_derive:
    push rbx
    CONST T_BG, 0xff1e1f24
    CONST T_FG, 0xffd4d6dc
    CONST T_ACCENT, 0xff7aa2f7
    cmp dword ptr [rip + g_theme_dark], 0
    je .Ltd_light
    DERIVE_C T_PANEL, T_BG, 0xff000000, 40
    DERIVE_C T_BORDER, T_PANEL, 0xff000000, 70
    DERIVE T_LINE_HL, T_BG, T_FG, 10
    DERIVE T_SELECTION, T_BG, T_ACCENT, 72
    DERIVE T_HOVER, T_PANEL, T_FG, 18
    DERIVE T_ACTIVE, T_PANEL, T_ACCENT, 56
    DERIVE T_POPUP, T_BG, T_FG, 12
    DERIVE_C T_INPUT, T_BG, 0xff000000, 30
    DERIVE T_GUIDE, T_BG, T_FG, 24
    jmp .Ltd_common
.Ltd_light:
    DERIVE_C T_PANEL, T_BG, 0xff000000, 10
    DERIVE T_BORDER, T_PANEL, T_FG, 36
    DERIVE T_LINE_HL, T_BG, T_FG, 12
    DERIVE T_SELECTION, T_BG, T_ACCENT, 56
    DERIVE T_HOVER, T_PANEL, T_FG, 16
    DERIVE T_ACTIVE, T_PANEL, T_ACCENT, 44
    DERIVE_C T_POPUP, T_BG, 0xffffffff, 140
    DERIVE_C T_INPUT, T_BG, 0xffffffff, 160
    DERIVE T_GUIDE, T_BG, T_FG, 28
.Ltd_common:
    COPY T_TITLEBAR, T_PANEL
    COPY T_STATUS, T_PANEL
    COPY T_TAB, T_PANEL
    COPY T_TAB_ACTIVE, T_BG
    DERIVE T_MUTED, T_FG, T_BG, 110
    DERIVE T_PANEL_FG, T_FG, T_PANEL, 30
    DERIVE T_LINENO, T_FG, T_BG, 150
    COPY T_LINENO_ACTIVE, T_FG
    COPY T_CURSOR, T_ACCENT
    DERIVE T_SCROLLBAR, T_BG, T_FG, 60
    CONST T_ERROR, 0xffe06c75
    CONST T_WARNING, 0xffe5c07b
    CONST T_SUCCESS, 0xff98c379
    DERIVE T_MATCH, T_BG, T_WARNING, 70
    # ACCENT_FG: black or white by rec.709-ish weighted luminance (0.30 r +
    # 0.59 g + 0.11 b of the low bytes). Below the midpoint the black is picked
    ISDEF T_ACCENT_FG
    jc 1f
    mov eax, [rip + g_theme + 4*T_ACCENT]
    movzx ecx, al               # b
    imul ecx, ecx, 29
    movzx edx, ah               # g
    imul edx, edx, 150
    add ecx, edx
    shr eax, 16
    movzx eax, al               # r
    imul eax, eax, 77
    add eax, ecx
    shr eax, 8
    mov ecx, 0xffffffff
    mov edx, 0xff111217
    cmp eax, 165
    cmova ecx, edx
    mov [rip + g_theme + 4*T_ACCENT_FG], ecx
1:  # syntax class slots: one per C_* class, T_SYN + i for i 0..C_COUNT-1. No
    # highlighter reads them in this build, but they stay loadable by name and
    # are the sources terminal blue/magenta/cyan take below.
    COPY T_SYN + C_TEXT, T_FG
    COPY T_SYN + C_KEYWORD, T_ACCENT
    COPY T_SYN + C_TYPE, T_ACCENT
    COPY T_SYN + C_FUNCTION, T_ACCENT
    COPY T_SYN + C_STRING, T_SUCCESS
    COPY T_SYN + C_NUMBER, T_WARNING
    COPY T_SYN + C_COMMENT, T_MUTED
    COPY T_SYN + C_CONSTANT, T_SYN + C_NUMBER
    COPY T_SYN + C_OPERATOR, T_FG
    DERIVE T_SYN + C_PUNCT, T_FG, T_BG, 60
    COPY T_SYN + C_PREPROC, T_SYN + C_KEYWORD
    COPY T_SYN + C_VARIABLE, T_FG
    COPY T_SYN + C_BUILTIN, T_SYN + C_FUNCTION
    COPY T_SYN + C_ATTRIBUTE, T_SYN + C_TYPE
    COPY T_SYN + C_TAG, T_SYN + C_KEYWORD
    COPY T_SYN + C_HEADING, T_SYN + C_KEYWORD
    COPY T_SYN + C_INSERTED, T_SUCCESS
    COPY T_SYN + C_DELETED, T_ERROR
    COPY T_SYN + C_ESCAPE, T_SYN + C_CONSTANT
    COPY T_SYN + C_LINK, T_ACCENT
    # terminal palette: entries 0..7 dark, 8..15 bright. 0 and 7 are bg/fg
    # shades, red/yellow/green map to the status colors, and blue/magenta/cyan
    # take the function/keyword/builtin syntax slots so the palette shares the
    # UI's accent family unless the theme names those colors. Bright variants
    # of the colored entries mix 50% toward white.
    DERIVE T_TERM + 0, T_BG, T_FG, 40
    COPY T_TERM + 1, T_ERROR
    COPY T_TERM + 2, T_SUCCESS
    COPY T_TERM + 3, T_WARNING
    COPY T_TERM + 4, T_SYN + C_FUNCTION
    COPY T_TERM + 5, T_SYN + C_KEYWORD
    COPY T_TERM + 6, T_SYN + C_BUILTIN
    DERIVE T_TERM + 7, T_FG, T_BG, 40
    COPY T_TERM + 8, T_MUTED
    DERIVE_C T_TERM + 9, T_TERM + 1, 0xffffffff, 50
    DERIVE_C T_TERM + 10, T_TERM + 2, 0xffffffff, 50
    DERIVE_C T_TERM + 11, T_TERM + 3, 0xffffffff, 50
    DERIVE_C T_TERM + 12, T_TERM + 4, 0xffffffff, 50
    DERIVE_C T_TERM + 13, T_TERM + 5, 0xffffffff, 50
    DERIVE_C T_TERM + 14, T_TERM + 6, 0xffffffff, 50
    COPY T_TERM + 15, T_FG
    # file icons: hues from the terminal colors, moved toward the text until they
    # stand out on the panel (the LEGIBLE calls just below)
    COPY T_ICON + 0, T_TERM + 1
    DERIVE T_ICON + 1, T_TERM + 1, T_TERM + 3, 128
    COPY T_ICON + 2, T_TERM + 3
    COPY T_ICON + 3, T_TERM + 2
    HUE T_ICON + 4, T_TERM + 4, 0xff3b8eea
    HUE T_ICON + 5, T_TERM + 5, 0xffbc3fbc
    DERIVE T_ICON + 6, T_ICON + 5, T_TERM + 1, 128
    HUE T_ICON + 7, T_TERM + 6, 0xff11a8cd
    COPY T_ICON + 8, T_MUTED
    COPY T_ICON + 9, T_PANEL_FG
    LEGIBLE T_ICON + 0
    LEGIBLE T_ICON + 1
    LEGIBLE T_ICON + 2
    LEGIBLE T_ICON + 3
    LEGIBLE T_ICON + 4
    LEGIBLE T_ICON + 5
    LEGIBLE T_ICON + 6
    LEGIBLE T_ICON + 7
    COPY T_GIT_ADD, T_SUCCESS
    COPY T_GIT_MOD, T_WARNING
    COPY T_GIT_DEL, T_ERROR
    pop rbx
    ret

# parse_color(text, len) -> eax argb (0xAARRGGBB), edx 1 ok. Text is a #rrggbb
# (alpha forced to ff) or #rrggbbaa string (reordered to aarrggbb). Anything else
# fails with eax/edx 0.
FN parse_color
    xor edx, edx
    cmp rsi, 7
    jb 9f
    cmp byte ptr [rdi], '#'
    jne 9f
    push rsi
    inc rdi
    dec rsi
    call parse_hex
    pop rsi
    cmp rsi, 7
    je 1f
    cmp rsi, 9
    jne 9f
    # rrggbbaa -> aarrggbb
    mov ecx, eax
    shr eax, 8
    shl ecx, 24
    or eax, ecx
    mov edx, 1
    ret
1:  or eax, 0xff000000
    mov edx, 1
9:  ret

# luma(argb) -> eax: 54 r^2 + 183 g^2 + 18 b^2 summed over the low three bytes,
# i.e. relative luminance with the square standing in for the sRGB gamma curve
# (weights ~0.21/0.72/0.07 scaled by 255^2). Needed because legible compares it
# against LUMA_MAX in wider integer steps.
luma:
    mov eax, edi
    and eax, 0xff
    imul eax, eax
    imul eax, eax, 18
    mov ecx, edi
    shr ecx, 8
    and ecx, 0xff
    imul ecx, ecx
    imul ecx, ecx, 183
    add eax, ecx
    mov ecx, edi
    shr ecx, 16
    and ecx, 0xff
    imul ecx, ecx
    imul ecx, ecx, 54
    add eax, ecx
    ret

# legible(argb) -> eax: the color mixed toward the foreground, in up to 7 steps
# of color_mix(t=48), until the brighter of it and the panel is 3x as bright as
# the other — WCAG's 3:1 ratio for graphics, (hi + .05)/(lo + .05), which in
# integer luma terms is 20 hi + LUMA_MAX >= 3 (20 lo + LUMA_MAX). Used by
# LEGIBLE for file-icon hues. Slot order follows unn.inc (see slot_names).
.equ LUMA_MAX, 255 * 65025
legible:
    push rbx
    push r12
    push r13
    mov ebx, edi
    mov r12d, 8
1:  mov edi, ebx
    call luma
    mov r13d, eax
    mov edi, [rip + g_theme + 4*T_PANEL]
    call luma
    mov ecx, eax
    cmp r13d, ecx
    jae 2f
    mov eax, r13d
    mov r13d, ecx
    mov ecx, eax
2:  imul r13, r13, 20               # 20 hi + max >= 3 (20 lo + max)
    add r13, LUMA_MAX
    imul rcx, rcx, 20
    add rcx, LUMA_MAX
    imul rcx, rcx, 3
    cmp r13, rcx
    jae 9f
    dec r12d
    jz 9f
    mov edi, ebx
    mov esi, [rip + g_theme + 4*T_FG]
    mov edx, 48
    call color_mix
    mov ebx, eax
    jmp 1b
9:  mov eax, ebx
    pop r13
    pop r12
    pop rbx
    ret

.section .rodata
# slot_names: one name per g_theme slot, in T_ order (unn.inc): the T_* chrome
# slots first, then the C_* syntax classes, then the 16 terminal colors, the 3
# git colors and the 10 icon colors. theme_load matches keys against
# str_eq_cstr of these. The table is T_COUNT entries long.
.Lkind: .asciz "kind"
.Llight: .asciz "light"
.p2align 3
slot_names:
    .quad .Ls0, .Ls1, .Ls2, .Ls3, .Ls4, .Ls5, .Ls6, .Ls7, .Ls8, .Ls9
    .quad .Ls10, .Ls11, .Ls12, .Ls13, .Ls14, .Ls15, .Ls16, .Ls17, .Ls18, .Ls19
    .quad .Ls20, .Ls21, .Ls22, .Ls23, .Ls24, .Ls25, .Ls26
    .quad .Lc0, .Lc1, .Lc2, .Lc3, .Lc4, .Lc5, .Lc6, .Lc7, .Lc8, .Lc9
    .quad .Lc10, .Lc11, .Lc12, .Lc13, .Lc14, .Lc15, .Lc16, .Lc17, .Lc18, .Lc19
    .quad .Lt0, .Lt1, .Lt2, .Lt3, .Lt4, .Lt5, .Lt6, .Lt7, .Lt8, .Lt9
    .quad .Lt10, .Lt11, .Lt12, .Lt13, .Lt14, .Lt15, .Lg0, .Lg1, .Lg2
    .quad .Li0, .Li1, .Li2, .Li3, .Li4, .Li5, .Li6, .Li7, .Li8, .Li9
.Ls0: .asciz "bg"
.Ls1: .asciz "fg"
.Ls2: .asciz "accent"
.Ls3: .asciz "panel"
.Ls4: .asciz "titlebar"
.Ls5: .asciz "border"
.Ls6: .asciz "muted"
.Ls7: .asciz "line_number"
.Ls8: .asciz "line_number_active"
.Ls9: .asciz "line_highlight"
.Ls10: .asciz "selection"
.Ls11: .asciz "cursor"
.Ls12: .asciz "hover"
.Ls13: .asciz "active"
.Ls14: .asciz "popup"
.Ls15: .asciz "input"
.Ls16: .asciz "scrollbar"
.Ls17: .asciz "status"
.Ls18: .asciz "tab"
.Ls19: .asciz "tab_active"
.Ls20: .asciz "error"
.Ls21: .asciz "warning"
.Ls22: .asciz "success"
.Ls23: .asciz "match"
.Ls24: .asciz "guide"
.Ls25: .asciz "accent_fg"
.Ls26: .asciz "panel_fg"
.Lc0: .asciz "text"
.Lc1: .asciz "keyword"
.Lc2: .asciz "type"
.Lc3: .asciz "function"
.Lc4: .asciz "string"
.Lc5: .asciz "number"
.Lc6: .asciz "comment"
.Lc7: .asciz "constant"
.Lc8: .asciz "operator"
.Lc9: .asciz "punctuation"
.Lc10: .asciz "preproc"
.Lc11: .asciz "variable"
.Lc12: .asciz "builtin"
.Lc13: .asciz "attribute"
.Lc14: .asciz "tag"
.Lc15: .asciz "heading"
.Lc16: .asciz "inserted"
.Lc17: .asciz "deleted"
.Lc18: .asciz "escape"
.Lc19: .asciz "link"
.Lt0: .asciz "black"
.Lt1: .asciz "red"
.Lt2: .asciz "green"
.Lt3: .asciz "yellow"
.Lt4: .asciz "blue"
.Lt5: .asciz "magenta"
.Lt6: .asciz "cyan"
.Lt7: .asciz "white"
.Lt8: .asciz "bright_black"
.Lt9: .asciz "bright_red"
.Lt10: .asciz "bright_green"
.Lt11: .asciz "bright_yellow"
.Lt12: .asciz "bright_blue"
.Lt13: .asciz "bright_magenta"
.Lt14: .asciz "bright_cyan"
.Lt15: .asciz "bright_white"
.Lg0: .asciz "git_added"
.Lg1: .asciz "git_modified"
.Lg2: .asciz "git_deleted"
.Li0: .asciz "icon_red"
.Li1: .asciz "icon_orange"
.Li2: .asciz "icon_yellow"
.Li3: .asciz "icon_green"
.Li4: .asciz "icon_blue"
.Li5: .asciz "icon_purple"
.Li6: .asciz "icon_pink"
.Li7: .asciz "icon_cyan"
.Li8: .asciz "icon_grey"
.Li9: .asciz "icon_white"
