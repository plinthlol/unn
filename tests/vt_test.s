# phase-0 spike for libghostty-vt, kept on as a golden check: create a
# terminal, feed it VT bytes (bold, green, a 30-x run that soft-wraps at 20
# cols, a cursor jump), read a DSR cursor-position query back through the
# write_pty callback, dump the screen through the PLAIN formatter, resize
# 20 -> 40 cols so the wrap reflows back into one line, then free the
# formatter and terminal through our allocator and report whatever it still
# counts live. every step appends name/result lines to the
# out string builder, flushed once to stdout at the end and diffed
# byte-for-byte against tests/data/vt.expected by tests/run.sh. the whole
# thing is deterministic. sections below: small output helpers, the write_pty
# callback, the formatter dump helper, then main (new, set, feed, reply,
# format, resize, teardown, exit-code rollup).
.include "unn.inc"

.extern g_vt_allocator

.bss
.p2align 3
out: .zero SB_SIZE                  # the golden output, printed once at the end
pty: .zero SB_SIZE                  # write_pty replies, shown and cleared per query
vt_term: .quad 0
vt_fmt: .quad 0
fmt_ptr: .quad 0
fmt_len: .quad 0
live_base: .quad 0
.text

# ---- small output helpers: they only ever append to the out builder ----

# out_str(cstr): copy a NUL-terminated string into out, byte by byte
out_str:
    push rbx
    mov rbx, rdi
1:  movzx esi, byte ptr [rbx]
    test esi, esi
    jz 2f
    lea rdi, [rip + out]
    call sb_push_byte
    inc rbx
    jmp 1b
2:  pop rbx
    ret

# out_show(ptr, len): bytes with ESC (and other control chars) as ^X, i.e. a
# ^ plus the byte + 0x40; the reply lines go through this so CR, ESC and any
# other C0 control in a reply are visible in the golden
out_show:
    push rbx
    push r12
    push r13
    mov r12, rdi
    mov r13, rsi
    xor ebx, ebx
1:  cmp rbx, r13
    jae 4f
    movzx esi, byte ptr [r12 + rbx]
    cmp esi, 0x20
    jae 3f
    push rsi
    lea rdi, [rip + out]
    mov esi, '^'
    call sb_push_byte
    pop rsi
    add esi, 0x40
3:  lea rdi, [rip + out]
    call sb_push_byte
    inc rbx
    jmp 1b
4:  pop r13
    pop r12
    pop rbx
    ret

# out_bytes(ptr, len): as-is (plain formatter output only, no wrapping)
out_bytes:
    push rbx
    push r12
    push r13
    mov r12, rdi
    mov r13, rsi
    xor ebx, ebx
1:  cmp rbx, r13
    jae 3f
    movzx esi, byte ptr [r12 + rbx]
    lea rdi, [rip + out]
    call sb_push_byte
    inc rbx
    jmp 1b
3:  pop r13
    pop r12
    pop rbx
    ret

# out_num(edi): decimal digits, no sign and no minus (value must be >= 0)
out_num:
    push rbx
    mov r8d, edi
    test r8d, r8d
    jz 5f
    mov eax, r8d
    xor ebx, ebx
1:  xor edx, edx
    mov ecx, 10
    div ecx
    push rdx
    inc ebx
    test eax, eax
    jnz 1b
2:  pop rax
    lea rdi, [rip + out]
    add eax, '0'
    mov esi, eax
    call sb_push_byte
    dec ebx
    jnz 2b
    pop rbx
    ret
5:  lea rdi, [rip + out]
    mov esi, '0'
    call sb_push_byte
    pop rbx
    ret

# step(name, code): the name, a space, the decimal code from eax, a newline.
# the checked hops in main (new, set, fmt creation, resize) funnel their
# result codes through step so the golden holds one progress line per API
# hop; feeds report nothing themselves
step:
    push rbx
    push r12
    mov rbx, rdi
    mov r12d, esi
    mov rdi, rbx
    call out_str
    lea rdi, [rip + out]
    mov esi, ' '
    call sb_push_byte
    mov edi, r12d
    call out_num
    lea rdi, [rip + out]
    mov esi, 10
    call sb_push_byte
    pop r12
    pop rbx
    ret

# nl(): a bare newline through the same builder
nl:
    push rbx
    lea rdi, [rip + out]
    mov esi, 10
    call sb_push_byte
    pop rbx
    ret

# ---- write_pty(terminal, userdata, data, len): ghostty's reply-channel
# callback as installed via OPT_WRITE_PTY. accumulate the raw reply bytes into
# the pty builder -- do not show or clear them here -- so a query step can
# print and clear what has arrived since the last flush
vt_test_write_pty:
    push rbx
    push r12
    push r13
    mov r12, rdx                # data
    mov r13, rcx                # len
1:  test r13, r13
    jz 3f
    movzx esi, byte ptr [r12]
    lea rdi, [rip + pty]
    call sb_push_byte
    inc r12
    dec r13
    jmp 1b
3:  pop r13
    pop r12
    pop rbx
    ret

# ---- dump(): run the PLAIN formatter over the current screen. format_alloc
# runs through our allocator, the emitted bytes go into out verbatim
# (out_bytes), ghostty_free hands them back, and the format result code is
# printed decimal below the screen. each call pins a screen snapshot, both
# before and after the resize below.
dump:
    push rbx
    mov rdi, [rip + vt_fmt]
    lea rsi, [rip + g_vt_allocator]
    lea rdx, [rip + fmt_ptr]
    lea rcx, [rip + fmt_len]
    call ghostty_formatter_format_alloc
    mov ebx, eax                # result code
    mov rdi, [rip + fmt_ptr]
    test rdi, rdi
    jz 1f
    mov rsi, [rip + fmt_len]
    call out_bytes
1:  call nl
    lea rdi, [rip + g_vt_allocator]
    mov rsi, [rip + fmt_ptr]
    mov rdx, [rip + fmt_len]
    call ghostty_free
    lea rdi, [rip + .Ls_dump]
    mov edi, ebx
    call out_num
    call nl
    pop rbx
    ret

FN main
    PROLOGUE
    xor r14d, r14d              # accumulated error codes (0 = all good)

    # baseline for the leak report. g_mem_live is the allocator's live-count
    # and nothing test-owned has been allocated yet (out and pty are .bss),
    # so the live line printed at the bottom sees only main's own churn
    mov rax, [rip + g_mem_live]
    mov [rip + live_base], rax

    # ghostty_terminal_new(&alloc, &term, 20, 12): a 20x12 screen on our
    # allocator, the first name/result line of the golden (new 0)
    lea rdi, [rip + g_vt_allocator]
    lea rsi, [rip + vt_term]
    mov edx, 20
    mov ecx, 12
    call ghostty_terminal_new
    or r14d, eax
    lea rdi, [rip + .Ls_new]
    mov esi, eax
    call step

    # set the write_pty callback: option bit 1 selects GHOSTTY_TERMINAL_OPT_
    # WRITE_PTY, so from now on every reply the terminal wants to write to the
    # pty is funneled into vt_test_write_pty above
    mov rdi, [rip + vt_term]
    mov esi, 1                  # GHOSTTY_TERMINAL_OPT_WRITE_PTY
    lea rdx, [rip + vt_test_write_pty]
    call ghostty_terminal_set
    or r14d, eax
    lea rdi, [rip + .Ls_set]
    mov esi, eax
    call step

    # feed the vt bytes of .Lseq1 up to .Lseq1end in one write. the sequence
    # styles text (bold, then green and back), lines up with CR LF, sends a
    # 30-x run that soft-wraps at 20 cols, and ends by jumping to 10,3 and
    # printing an asterisk there. replies this triggers stay queued in pty.
    mov rdi, [rip + vt_term]
    lea rsi, [rip + .Lseq1]
    mov rdx, .Lseq1end - .Lseq1
    call ghostty_terminal_vt_write

    # cursor position query: feed the 4-byte DSR \033[6n, then the reply the
    # query produced -- delivered through the callback and queued in pty --
    # is shown (ESC becomes ^[) and the buffer cleared for the next step
    lea rdi, [rip + .Ls_reply]
    call out_str
    lea rdi, [rip + out]
    mov esi, ' '
    call sb_push_byte
    mov rdi, [rip + vt_term]
    lea rsi, [rip + .Lseq_dsr]
    mov rdx, 4
    call ghostty_terminal_vt_write
    mov rdi, [rip + pty + SB_ptr]
    mov rsi, [rip + pty + SB_len]
    call out_show
    lea rdi, [rip + pty]
    call sb_clear
    call nl

    # formatter over the current screen. GhosttyFormatterTerminalOptions is a
    # MEMORY-class argument, so it goes on the stack in this layout:
    # [0]size=40, [8]emit=PLAIN(0), [12]unwrap=0, [13]trim=1,
    # [16]extra{size=16, six bools 0}, [32]selection=NULL.
    # trim=1 makes the emitted lines drop trailing blanks. the produce-then-
    # dump pair below pins the whole wrapped screen, blanks included, in one
    # golden block
    push 0                      # pad: keeps rsp 16-aligned at the call
    push 0                      # selection
    push 0                      # extra: palette..keyboard
    push 16                     # extra.size
    mov rax, 0x10000000000      # trim (1 << 40)
    push rax
    mov rax, 40                 # size
    push rax
    lea rdi, [rip + g_vt_allocator]
    lea rsi, [rip + vt_fmt]
    mov rdx, [rip + vt_term]
    call ghostty_formatter_terminal_new
    add rsp, 48
    or r14d, eax
    lea rdi, [rip + .Ls_fmt]
    mov esi, eax
    call step
    call dump

    # resize with reflow: 20 -> 40 cols with glyph metrics (8x16 px) attached,
    # since the library wants cell sizes here. the earlier 30-x run was
    # soft-wrapped at 20 cols and the resize reflows it back onto one line,
    # so the dump under this step pins the reflowed geometry
    mov rdi, [rip + vt_term]
    mov esi, 40
    mov edx, 12
    mov ecx, 8                  # cell_width_px
    mov r8d, 16                 # cell_height_px
    call ghostty_terminal_resize
    or r14d, eax
    lea rdi, [rip + .Ls_resize]
    mov esi, eax
    call step
    call dump

    # teardown, every allocation must come home before the live line: free the
    # formatter first, then the terminal, both through our allocator
    mov rdi, [rip + vt_fmt]
    call ghostty_formatter_free
    mov rdi, [rip + vt_term]
    call ghostty_terminal_free

    # the leak line: the live count minus the baseline snapshot, the last
    # line of the golden before the flush. the golden pins 2: the out and pty
    # builders are the only blocks nothing hands back, so terminal, formatter
    # and the format buffer must all come home first
    lea rdi, [rip + .Ls_live]
    call out_str
    mov rdi, [rip + g_mem_live]
    sub rdi, [rip + live_base]
    call out_num
    call nl

    # exit code r14d -- the OR of every checked step's result -- then the
    # flush writes the whole out builder to fd 1; the golden comparison
    # expects both 0 and this exact byte stream
    mov edi, 1
    mov rsi, [rip + out + SB_ptr]
    mov rdx, [rip + out + SB_len]
    call write_all

    mov eax, r14d
    EPILOGUE
    ret

.section .rodata
.Ls_new:    .asciz "new"
.Ls_set:    .asciz "set"
.Ls_reply:  .asciz "reply"
.Ls_fmt:    .asciz "fmt"
.Ls_dump:   .asciz "dump"
.Ls_resize: .asciz "resize"
.Ls_live:   .asciz "live "
.Lseq1:
    .ascii "Hello \033[1mbold\033[0m world\r\n"
    .ascii "\033[32mgreen\033[39m plain\r\n"
    .ascii "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxx\r\n"  # 30 x wraps at 20 cols
    .ascii "\033[10;3H*"
.Lseq1end:
.Lseq_dsr:  .ascii "\033[6n"
