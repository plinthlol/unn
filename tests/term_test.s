# terminal check: run screens and keystrokes through the emulator (src/app/term.s
# on top of libghostty-vt) and print what the screen looks like plus what the
# terminal would send back to the program. all output accumulates in the
# string-builder out, is written to stdout in one flush at the end, and is
# diffed byte-for-byte against tests/data/term.expected by tests/run.sh, so any
# byte added to or removed from a dump line changes the golden on purpose.
#
# out, and the emulator handle stays owned by main the whole way through,
# travelling in rbx.
#
# main runs these sections, in order:
#   cases table (t1..t16): one fed escape string each -- cursor jumps, erase and
#     insert/delete, autowrap, unicode double width, alt screen, OSC title and
#     colour queries, DEC special graphics, tabs and ECMA-48 repeat, scroll
#     regions, margins, DECAWM, DECRQM and DECRPM queries.
#   colors and attributes (c_sgr): SGR bold, 24-bit and 256-colour, underline
#     and reverse, then the cell ROW,COL lines pin the packed cell words.
#   scrollback and resizing (c_scroll): 5 lines pushed through a 3-row screen,
#     the scrollback count, a term_text window over the ring, then two resizes.
#   deep scrollback: 20 fed lines through a 3-line ring and the deep 19/3
#     clamp pin (see that section below).
#   keys and paste: on a fresh terminal, press the keys table and print the
#     encodings sent to the program, then enable application cursor keys
#     mid-table (the -1 entry), paste, switch on bracketed paste, paste again.
#   kitty keyboard protocol: query and enable, the kk_keys table, the flag
#     stack pushed through alt-screen save/restore, pops and sets up to an
#     overfull push, then the legacy duplicate keys after the last pop.
# SGR/mouse report encoding is exercised by tests/terminal-keys.py, not by the
# case tables here.
.include "unn.inc"
.bss
.p2align 3
out: .zero SB_SIZE
.text

# show(ptr, len): copy bytes into out as one dump line. control bytes (< 0x20)
# first print a ^ and then the byte + 0x40, so ESC prints as ^[ and \r as ^M
show:
    push rbx
    push r12
    push r13
    mov r12, rdi
    mov r13, rsi
    xor ebx, ebx
1:  cmp rbx, r13
    jae 3f
    movzx esi, byte ptr [r12 + rbx]
    cmp esi, 0x20
    jae 2f
    push rsi
    lea rdi, [rip + out]
    mov esi, '^'
    call sb_push_byte
    pop rsi
    add esi, 0x40
2:  lea rdi, [rip + out]
    call sb_push_byte
    inc rbx
    jmp 1b
3:  lea rdi, [rip + out]
    mov esi, 10
    call sb_push_byte
    pop r13
    pop r12
    pop rbx
    ret

# replies(t): if the terminal has queued an answer for the program, append the
# reply label and one line of the queued bytes (see show), then clear the queue.
# called after a feed or press batch so replies land where the golden expects
replies:
    push rbx
    mov rbx, rdi
    cmp qword ptr [rbx + TM_out + SB_len], 0
    je 1f
    lea rdi, [rip + out]
    lea rsi, [rip + .Lreply]
    call sb_push_cstr
    mov rdi, [rbx + TM_out + SB_ptr]
    mov rsi, [rbx + TM_out + SB_len]
    call show
    lea rdi, [rbx + TM_out]
    call sb_clear
1:  pop rbx
    ret

# feed_cstr(str): strlen it, send exactly those bytes to the terminal in rbx
# with term_feed. companion harness strings in the keys section are length-fed
# instead and deliberately .ascii (no NUL), because they contain bytes whose
# NUL-terminators are irrelevant. anything reaching this or another strlen-fed
# path must be .asciz.
feed_cstr:
    push r12
    mov r12, rdi
    call strlen
    mov rdi, rbx
    mov rsi, r12
    mov rdx, rax
    call term_feed
    pop r12
    ret

# press(table): for each row -- keysym (0 terminates), codepoint, mods -- call
# term_key for the terminal in rbx, so the reply buffer picks up the encoding
# the emulator would send the program for that key event
press:
    push r12
    mov r12, rdi
1:  mov esi, [r12]
    test esi, esi
    jz 2f
    mov rdi, rbx
    mov edx, [r12 + 4]
    mov ecx, [r12 + 8]
    call term_key
    add r12, 12
    jmp 1b
2:  pop r12
    ret

# cell(t, row, col): append the cell label plus the three dwords of the cell
# (row, col) starting at LN_HDR -- codepoint with the A_* attribute bits, then
# its fg and bg colour words -- as hex pairs separated by spaces
cell:
    push rbx
    push r12
    push r13
    mov rdi, rdi
    call term_row
    movsxd rdx, edx
    lea rcx, [rdx + rdx*2]
    lea r12, [rax + rcx*4 + LN_HDR]
    lea rdi, [rip + out]
    lea rsi, [rip + .Lcell]
    call sb_push_cstr
    xor ebx, ebx
1:  lea rdi, [rip + out]
    mov esi, [r12 + rbx*4]
    call hex
    inc ebx
    cmp ebx, 3
    jb 1b
    lea rdi, [rip + out]
    mov esi, 10
    call sb_push_byte
    pop r13
    pop r12
    pop rbx
    ret
# hex(value in esi): append eight hex digits, high to low, then one space
hex:
    push rbx
    mov ebx, esi
    mov ecx, 28
1:  mov eax, ebx
    shr eax, cl
    and eax, 15
    lea rdx, [rip + hexdigits]
    movzx esi, byte ptr [rdx + rax]
    push rcx
    push rcx
    lea rdi, [rip + out]
    call sb_push_byte
    pop rcx
    pop rcx
    sub ecx, 4
    jns 1b
    lea rdi, [rip + out]
    mov esi, ' '
    call sb_push_byte
    pop rbx
    ret

# run(case): the case is cols byte, rows byte, then the .asciz feed string.
# builds a term_new(cols, rows, 100 lines of scrollback), feeds the string,
# dumps the screen into out (term_dump: one text line per screen row, then the
# cursor line), appends any replies, closes with a blank line, returns the term
run:
    push rbx
    push r12
    push r13
    mov r12, rdi
    movzx edi, byte ptr [r12]
    movzx esi, byte ptr [r12 + 1]
    mov edx, 100
    call term_new
    mov rbx, rax
    lea rdi, [r12 + 2]
    call strlen
    mov rdi, rbx
    lea rsi, [r12 + 2]
    mov rdx, rax
    call term_feed
    mov rdi, rbx
    lea rsi, [rip + out]
    call term_dump
    mov rdi, rbx
    call replies
    lea rdi, [rip + out]
    mov esi, 10
    call sb_push_byte
    mov rax, rbx
    pop r13
    pop r12
    pop rbx
    ret

FN main
    PROLOGUE
    lea r12, [rip + cases]
    # walk the 16-entry table (t1..t16), dumping and freeing each entry before
    # the next one feeds a fresh screen
1:  mov rdi, [r12]
    test rdi, rdi
    jz 2f
    call run
    mov rdi, rax
    call term_free
    add r12, 8
    jmp 1b
    # colors and attributes: c_sgr feeds SGR bold, default-reverse, 24-bit bg
    # and the 24-bit/256-colour/underline/other resets. the dumps show the
    # visible result and the three cell dumps pin row 0 (the X, Y, Z run) as
    # the packed codepoint/attribute word plus fg and bg per cell
2:  lea rdi, [rip + c_sgr]
    call run
    mov rbx, rax
    mov rdi, rbx
    xor esi, esi
    xor edx, edx
    call cell
    mov rdi, rbx
    xor esi, esi
    mov edx, 1
    call cell
    mov rdi, rbx
    xor esi, esi
    mov edx, 2
    call cell
    mov rdi, rbx
    call term_free
    # scrollback and resizing: c_scroll feeds 5 lines onto a 3-row screen.
    # the scrollback line pins TM_sblen (2 pruned history lines), term_text
    # (rows -2 down to -1, cols 0 up to 10) shows what the ring holds, and the
    # resizes to 10x5 and 6x2 re-dump the screen so line reuse is pinned
    lea rdi, [rip + c_scroll]
    call run
    mov rbx, rax
    lea rdi, [rip + out]
    lea rsi, [rip + .Lsb]
    call sb_push_cstr
    lea rdi, [rip + out]
    mov esi, [rbx + TM_sblen]
    call sb_push_u64
    lea rdi, [rip + out]
    mov esi, 10
    call sb_push_byte
    mov rdi, rbx
    lea rsi, [rip + out]
    mov edx, -2
    xor ecx, ecx
    mov r8d, -1
    mov r9d, 10
    call term_text
    lea rdi, [rip + out]
    mov esi, 10
    call sb_push_byte
    mov rdi, rbx
    mov esi, 10
    mov edx, 5
    call term_resize
    mov rdi, rbx
    lea rsi, [rip + out]
    call term_dump
    mov rdi, rbx
    mov esi, 6
    mov edx, 2
    call term_resize
    mov rdi, rbx
    lea rsi, [rip + out]
    call term_dump
    mov rdi, rbx
    call term_free
    # deep scrollback clamp pin: 20 lines (a..t) are pushed through only a
    # 3-line ring on a 2-row screen. after the dump the test asks to scroll 100
    # lines up (term_view_delta). the view must clamp to the ring instead of
    # pointing past the pruned history. the deep line pins hlen/total -- 19/3:
    # 19 history rows the library counts, 3 lines unn's own ring still holds --
    # and the following dump proves no out-of-range row is rendered
    mov edi, 8
    mov esi, 2
    mov edx, 3
    call term_new
    mov rbx, rax
    lea rdi, [rip + .Ldsn]
    call feed_cstr
    mov rdi, rbx
    lea rsi, [rip + out]
    call term_dump
    mov rdi, rbx
    mov esi, 100
    call term_view_delta          # overscroll 100 lines: far past the 3-line ring
    lea rdi, [rip + out]
    lea rsi, [rip + .Lsbdeep]
    call sb_push_cstr
    lea rdi, [rip + out]
    mov rsi, [rbx + TM_hlen]
    call sb_push_u64
    lea rdi, [rip + out]
    mov esi, '/'
    call sb_push_byte
    lea rdi, [rip + out]
    mov rsi, [rbx + TM_total]
    call sb_push_u64
    lea rdi, [rip + out]
    mov esi, 10
    call sb_push_byte
    mov rdi, rbx
    lea rsi, [rip + out]
    call term_dump
    mov rdi, rbx
    call term_free
    # keys: a fresh 20x3 terminal, then the keys table (keysym, cp, mods rows,
    # zero keysym ends). each row is pressed with term_key on the terminal in
    # rbx. nothing is dumped here, replies() after the whole table collects
    # every encoding back to back in out. a -1 keysym row is a mode sentinel:
    # it switches the terminal to application cursor keys (?1h, DECCKM)
    # instead of sending a key. the rows cover cursor keys with and without
    # ctrl, function and numpad keys, ctrl/alt letter chords, shift-tab, bare
    # escape and plain letters, spanning every encoding shape the reply pins.
    mov edi, 20
    mov esi, 3
    mov edx, 10
    call term_new
    mov rbx, rax
    lea r12, [rip + keys]
3:  mov esi, [r12]
    test esi, esi
    jz 4f
    cmp esi, -1
    jne 31f
    # the sentinel row: feed \033[?1h (5 bytes, explicitly length-fed .ascii,
    # see feed_cstr), then keep stepping the table. from here the cursor keys
    # in the table must encode application-style
    mov rdi, rbx
    lea rsi, [rip + .Lappcur]
    mov edx, 5
    call term_feed
    jmp 32f
31: mov rdi, rbx
    mov edx, [r12 + 4]
    mov ecx, [r12 + 8]
    call term_key
32: add r12, 12
    jmp 3b
4:  mov rdi, rbx
    call replies
    # paste vector: paste the same 7 length-fed bytes (newline, bare ESC,
    # \r\n) while bracketed paste is still off, then feed \033[?2004h (8 bytes,
    # explicitly length-fed .ascii) and paste again. the two replies batches
    # pin how pasted text reaches the program with and without the bracket
    mov rdi, rbx
    lea rsi, [rip + .Lpaste]
    mov edx, 7
    call term_paste
    mov rdi, rbx
    lea rsi, [rip + .Lbpm]
    mov edx, 8
    call term_feed
    mov rdi, rbx
    lea rsi, [rip + .Lpaste]
    mov edx, 7
    call term_paste
    mov rdi, rbx
    call replies
    mov rdi, rbx
    call term_free
    # kitty keyboard protocol. the CSI u query, push, pop and set grammars
    # live inside libghostty-vt, so the feeds below drive it from the outside
    # and the replies pin whatever it answers:
    #   .Lkk_on -- query current flags, set them, query again, so the answers come
    #     out of the first replies batch, then the kk_keys table (per-modifier
    #     variants, plain letters and control chars) reports its own encodings
    #   .Lkk_stack -- alt-screen entries bracket the whole dance: push flag 1,
    #     pop, pop again, re-sets of 1, 1+3, 1+2, 8+2, a pop of 9 (too deep)
    #     and bare pops, one ?u query between every step. each step's answer
    #     lands in the second replies batch
    #   .Lkk_full -- nine pushes, then pop 8 and a bare pop. with kitty off
    #     again, the kk_legacy table (post-last-pop) returns to plain encodings
    mov edi, 20
    mov esi, 3
    mov edx, 10
    call term_new
    mov rbx, rax
    lea rdi, [rip + .Lkk_on]
    call feed_cstr
    lea rdi, [rip + kk_keys]
    call press
    mov rdi, rbx
    call replies
    lea rdi, [rip + .Lkk_stack]
    call feed_cstr
    mov rdi, rbx
    call replies
    lea rdi, [rip + .Lkk_full]
    call feed_cstr
    lea rdi, [rip + kk_legacy]
    call press
    mov rdi, rbx
    call replies
    mov rdi, rbx
    call term_free
    mov rdi, 1
    mov rsi, [rip + out + SB_ptr]
    mov rdx, [rip + out + SB_len]
    call write_all
    xor eax, eax
    EPILOGUE

.section .rodata
.Lreply: .asciz "reply "
.Lcell: .asciz "cell "
.Lsb: .asciz "scrollback "
.Lsbdeep: .asciz "deep "
.Ldsn: .asciz "a\012b\012c\012d\012e\012f\012g\012h\012i\012j\012k\012l\012m\012n\012o\012p\012q\012r\012s\012t\012"
.Lappcur: .ascii "\033[?1h"
.Lbpm: .ascii "\033[?2004h"
.Lpaste: .ascii "a\nb\033c\r\n"
.Lkk_on: .asciz "\033[?u\033[>7u\033[?u"
.Lkk_stack: .ascii "\033[?1049h\033[?u\033[>1u\033[?u\033[?1049l\033[?u"
    .ascii "\033[<u\033[?u\033[<u\033[?u\033[=1u\033[?u\033[=1;3u\033[?u\033[=1;2u\033[?u"
    .asciz "\033[=8;2u\033[?u\033[<9u\033[?u"
.Lkk_full: .ascii "\033[>1u\033[>1u\033[>1u\033[>1u\033[>1u\033[>1u\033[>1u\033[>1u\033[>1u"
    .asciz "\033[<8u\033[?u\033[<u\033[?u"
# cols, rows, bytes: one table entry per run() call.
# cursor/addressing cases, in table order:
#   t1  plain text with the wrapping newline, the baseline screen dump
#   t2  CSI H jumps, then a jump back: saved columns must not leak
#   t3  cursor movement (CSI D) followed by erase to end of line (CSI K)
#   t4  autowrap at column 10 (13 chars, no newline in the feed)
#   t5  insert characters (CSI @) and delete characters (CSI P) around a
#       cursor reset and a scroll
#   t6  utf8: a CJK double-width char between narrow letters, then emoji
#       double width with spacers
#   t7  alt screen: feed the switch on and off and pin what the main screen
#       keeps and drops
#   t8  device status queries (CSI 6n and CSI 5n) with a cursor-position
#       report (CSI c) interleaved: the reply lines pin report ordering
#   t9  DEC special graphics charset shifts around wide chars on both lines
#   t10 tabs on a wider screen and ECMA-48 repeat (CSI 3b) on a new line
#   t11 scroll region CSIs: setup, then a newline inside it and a reset
#   t12 OSC title set with BEL, OSC 2 title with ST, plus an OSC 11 query
#       answered as a colour report
#   t13 erase line and screen variants (CSI 3X and 2J), home, then reserved
#       cursor moves: reverse index (CSI M) and insert-line (CSI L)
#   t14 DECAWM off and on (CSI ?7 l/h) with an overlong feed between
#   t15 a wide char run across a wrap boundary: the y must not split it
#   t16 DECRQM probes (CSI ?mode$p) around a mode set, including a partial
#       value request (CSI ?25$p)
t1: .byte 20, 3
    .asciz "hello\r\nworld"
t2: .byte 10, 3
    .asciz "\033[2;3HX\033[1;1HY"
t3: .byte 10, 2
    .asciz "abcdef\033[3D\033[K"
t4: .byte 10, 3
    .asciz "0123456789ABC"
t5: .byte 10, 2
    .asciz "abcdef\033[1;3H\033[2@XY\r\n\033[2PZ"
t6: .byte 10, 2
    .asciz "a\344\270\255b|\360\237\230\200|"
t7: .byte 10, 2
    .asciz "main\033[?1049halt\033[?1049l!"
t8: .byte 10, 2
    .asciz "ab\033[6n\033[c\033[5n"
t9: .byte 10, 2
    .asciz "\033(0lqqk\033(B x\r\n\033(0x\033(B"
t10: .byte 20, 2
    .asciz "a\tb\tc\r\nx\033[3b"
t11: .byte 10, 5
    .asciz "1\r\n2\r\n3\r\n4\r\n5\033[2;4r\033[4;1H\n\033[r"
t12: .byte 10, 2
    .asciz "\033]0;my title\007\033]2;other\033\\t\033]11;?\033\\"
t13: .byte 10, 3
    .asciz "12345\033[2G\033[3X\r\n\033[2J\033[H\033[3;1Hend\033[1;1H\033M\033[L+"
t14: .byte 6, 2
    .asciz "abcdef\033[?7lgh\033[?7hij"
t15: .byte 10, 2
    .asciz "x\344\270\255\033[1;2Hy"
t16: .byte 10, 2
    .asciz "\033[?2026$p\033[?1049$p\033[?25l\033[?25$p"
    # c_sgr: the dedicated colour/attribute screen, main dumps three cells
    # from it separately (see main). its feed mixes SGR styles in one run:
    # bold red text on a 24-bit bg, then default fg plus colon-separated
    # 24-bit fg, underline and reverse, then all the clears plus 256-colour
c_sgr: .byte 10, 2
    .asciz "\033[1;31;48;2;1;2;3mX\033[0;38:2::255:128:0;4;7mY\033[22;24;27;39;38;5;200mZ"
    # c_scroll: the dedicated scrollback/resize screen (see main), just 5
    # numbered lines so the ring contents are easy to read in the dump
c_scroll: .byte 10, 3
    .asciz "1\r\n2\r\n3\r\n4\r\n5"
.p2align 3
cases: .quad t1, t2, t3, t4, t5, t6, t7, t8, t9, t10, t11, t12, t13, t14, t15, t16, 0
.p2align 2
# keysym, cp, mods (-1: switch to application cursor keys), zero keysym ends
# the table. encodings to the program are pinned term by term:
#   enter in every mod state, shifted numpad enter, tab and shift-tab under
#   kitty mode, ctrl-backspace, bare escape, ctrl-c/alt-x chords, shift+alt
#   letter, ctrl-space, plain letters and a shifted one, and alt-up
# with kitty flag 1
kk_keys:
    .long KEY_RETURN, 0, 0
    .long KEY_RETURN, 0, MOD_SHIFT
    .long KEY_RETURN, 0, MOD_ALT
    .long KEY_RETURN, 0, MOD_CTRL
    .long KEY_KP_ENTER, 0, MOD_SHIFT
    .long KEY_TAB, 0, 0
    .long KEY_ISO_LEFT_TAB, 0, MOD_SHIFT
    .long KEY_BACKSPACE, 0, MOD_CTRL
    .long KEY_ESCAPE, 0, 0
    .long 'c', 'c', MOD_CTRL
    .long 'x', 'x', MOD_ALT
    .long 'A', 'A', MOD_SHIFT | MOD_ALT
    .long ' ', ' ', MOD_CTRL
    .long 'q', 'q', 0
    .long 'Q', 'Q', MOD_SHIFT
    .long KEY_UP, 0, MOD_ALT
    .long 0, 0, 0
# after the last pop, kitty is off again: the same shapes now must encode as
# legacy CSI/M-style sequences
kk_legacy:
    .long KEY_RETURN, 0, MOD_SHIFT
    .long KEY_RETURN, 0, MOD_ALT
    .long 'c', 'c', MOD_CTRL
    .long KEY_ESCAPE, 0, 0
    .long 0, 0, 0
# keys: term_key rows across the legacy encoding paths, kitty off throughout.
#   up arrows with and without ctrl, an F-key offset high in the range
#   (KEY_F1 + 4), shifted delete, F1, ctrl-c and alt-x chords, shifted tab,
#   backspace, enter, a keysym with no US binding (0x439) echoing its own cp,
#   ctrl-[ -- the raw-look control chord -- then the -1 sentinel, and up/home
#   again to pin the application-cursor-key answers
keys:
    .long KEY_UP, 0, 0
    .long KEY_UP, 0, MOD_CTRL
    .long KEY_F1 + 4, 0, 0
    .long KEY_DELETE, 0, MOD_SHIFT
    .long KEY_F1, 0, 0
    .long 'c', 'c', MOD_CTRL
    .long 'x', 'x', MOD_ALT
    .long KEY_TAB, 0, MOD_SHIFT
    .long KEY_BACKSPACE, 0, 0
    .long KEY_RETURN, 0, 0
    .long 0x439, 0x439, 0
    .long '[', '[', MOD_CTRL
    .long -1, 0, 0
    .long KEY_UP, 0, 0
    .long KEY_HOME, 0, 0
    .long 0, 0, 0
