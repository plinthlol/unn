# ---- raster: scanline coverage rasterizer ----
# Turns lines and quadratic curves into per-pixel 8-bit alpha coverage for
# one glyph at a time (font.s drives it: raster_begin, then a flood of
# raster_line / raster_quad edges, then raster_end). termview.s draws its
# powerline arrows through the same three calls, one arrow at a time, saving
# xmm8-xmm15 around each raster_line (pl_edge).
#
# The active drawing area is a float accumulation buffer of w*h cells
# (acc_buf, reallocated on the spot as needed). Every edge deposits its
# signed area contribution into the cells it crosses; the winding direction
# (stored in xmm15, +1 or -1) makes contributions cancel between opposite
# edges of a filled shape. raster_end turns the running prefix sums into
# |coverage| clamped to 0..1, feeds it through gamma_tab (square-root-ish
# blend curve built by raster_init), and writes one alpha byte per pixel.
# Coordinates are in pixel space, y increasing downward.
# Entry points: raster_init, raster_begin, raster_line, raster_quad,
# raster_end.
.include "unn.inc"

.bss
.p2align 3
# float accumulation buffer shared by all rasterize calls, grown to fit
acc_buf: .quad 0
acc_cap: .quad 0                # floats
.globl g_acc_w, g_acc_h
# dimensions of the last raster_begin, used by raster_line bounds checks
g_acc_w: .long 0
g_acc_h: .long 0
.p2align 4
# coverage (0..255) to gamma-corrected alpha, built by raster_init
gamma_tab: .zero 256

.text

# raster_init(): builds gamma_tab, one byte per coverage value.
# The curve is (t + t^0.75)/2 scaled to 0..255: brighter than linear
# antialiasing so small text stays readable without going full gamma.
FN raster_init
    xor ecx, ecx
    lea rdi, [rip + gamma_tab]
1:  cvtsi2ss xmm0, ecx
    divss xmm0, [rip + f_255]
    movss xmm1, xmm0
    sqrtss xmm1, xmm1
    mulss xmm1, xmm0
    sqrtss xmm1, xmm1           # t^0.75
    addss xmm1, xmm0
    mulss xmm1, [rip + f_half]  # (t + t^0.75) / 2
    mulss xmm1, [rip + f_255]
    cvtss2si eax, xmm1
    mov [rdi + rcx], al
    inc ecx
    cmp ecx, 256
    jb 1b
    ret

# raster_begin(w=edi, h=esi): prepares a rasterization pass over a w*h
# accumulator. Grows acc_buf if needed (capacity is w*h + w + 8 floats), then
# zeroes the whole thing. raster_line indexes cells linearly as y*w + x, and
# the extra room is for that x: xa and xb clamp at zero on the left only, so
# an edge touching x = w writes a cell past its row — past the w*h cells
# raster_end reads, on the last row.
FN raster_begin
    push rbx
    mov [rip + g_acc_w], edi
    mov [rip + g_acc_h], esi
    mov eax, edi
    imul eax, esi
    lea ebx, [rax + rdi + 8]
    cmp rbx, [rip + acc_cap]
    jbe 1f
    lea rsi, [rbx*4]
    mov rdi, [rip + acc_buf]
    call mem_realloc
    mov [rip + acc_buf], rax
    mov [rip + acc_cap], rbx
1:  mov rdi, [rip + acc_buf]
    mov rcx, rbx
    xor eax, eax
    rep stosd
    pop rbx
    ret

# raster_line(xmm0=x0, xmm1=y0, xmm2=x1, xmm3=y1): deposit one edge into the
# accumulator, in pixel space with y down.
# The edge is walked a row at a time from floor(y0) through ceil(y1),
# clamped to the buffer (y0 never below 0, yend never past the height), so
# the partial rows at both ends keep their share of the vertical span. Per
# row the slope dxdy gives the x where the edge leaves the row (xnext); the
# interval it spans inside the row is [xa, xb]. Each cell the interval
# covers (its intersection with the row's covered height d, dy times the
# winding sign) gets the same full/partial split, so cell xai takes d times
# its left fraction, interior cells take d / one cell each and cell xbi the
# remainder. The winding sign is kept in xmm15, +1 for an edge walked
# downward and -1 for one walked upward. The
# deposits mean nothing on their own: raster_end takes the running prefix
# sum over the cells, so a region between matching edges ends up at the
# winding count (1 for an ordinary fill, more where shapes overlap, hence
# the abs + clamp at the end).
FN raster_line
    movss xmm4, xmm1
    subss xmm4, xmm3
    andps xmm4, [rip + abs_mask]
    comiss xmm4, [rip + f_eps]
    jb .Lrl_ret
    movss xmm15, [rip + f_one]
    comiss xmm1, xmm3
    jb 1f
    movss xmm4, xmm0
    movss xmm0, xmm2
    movss xmm2, xmm4
    movss xmm4, xmm1
    movss xmm1, xmm3
    movss xmm3, xmm4
    movss xmm15, [rip + f_mone]
1:  # clamp y range to buffer
    maxss xmm1, [rip + f_zero]
    movss xmm5, xmm2
    subss xmm5, xmm0
    movss xmm4, xmm3
    subss xmm4, xmm1
    comiss xmm4, [rip + f_eps]
    jb .Lrl_ret
    divss xmm5, xmm4            # dxdy
    movss xmm6, xmm0            # x
    cvttss2si ecx, xmm1         # y
    roundss xmm4, xmm3, 2
    cvttss2si edx, xmm4         # yend
    cmp edx, [rip + g_acc_h]
    jle 2f
    mov edx, [rip + g_acc_h]
2:  mov rdi, [rip + acc_buf]
    mov r9d, [rip + g_acc_w]
.Lrl_row:
    cmp ecx, edx
    jge .Lrl_ret
    mov r8d, ecx
    imul r8d, r9d               # linestart
    cvtsi2ss xmm7, ecx
    movss xmm8, xmm7
    addss xmm8, [rip + f_one]
    minss xmm8, xmm3
    maxss xmm7, xmm1
    subss xmm8, xmm7            # dy
    movss xmm9, xmm5
    mulss xmm9, xmm8
    addss xmm9, xmm6            # xnext
    movss xmm10, xmm8
    mulss xmm10, xmm15          # d
    movss xmm11, xmm6
    minss xmm11, xmm9           # xa
    movss xmm12, xmm6
    maxss xmm12, xmm9           # xb
    maxss xmm11, [rip + f_zero]
    maxss xmm12, [rip + f_zero]
    roundss xmm13, xmm11, 1     # floor(xa)
    cvttss2si r10d, xmm13       # xai
    roundss xmm14, xmm12, 2     # ceil(xb)
    cvttss2si r11d, xmm14       # xbi
    add r10d, r8d               # absolute index of xai
    add r11d, r8d               # absolute index of xbi
    lea eax, [r10 + 1]
    cmp r11d, eax
    jg .Lrl_wide
    # single cell
    movss xmm0, xmm6
    addss xmm0, xmm9
    mulss xmm0, [rip + f_half]
    subss xmm0, xmm13           # xmf
    maxss xmm0, [rip + f_zero]
    minss xmm0, [rip + f_one]
    movss xmm2, xmm10
    mulss xmm2, xmm0            # d*xmf
    movss xmm4, xmm10
    subss xmm4, xmm2
    addss xmm4, [rdi + r10*4]
    movss [rdi + r10*4], xmm4
    addss xmm2, [rdi + r10*4 + 4]
    movss [rdi + r10*4 + 4], xmm2
    jmp .Lrl_next
.Lrl_wide:
    movss xmm0, xmm12
    subss xmm0, xmm11
    movss xmm2, [rip + f_one]
    divss xmm2, xmm0            # s
    movss xmm0, xmm11
    subss xmm0, xmm13           # x0f
    movss xmm4, [rip + f_one]
    subss xmm4, xmm0
    mulss xmm4, xmm4
    mulss xmm4, xmm2
    mulss xmm4, [rip + f_half]  # a0
    movss xmm7, xmm12
    subss xmm7, xmm14
    addss xmm7, [rip + f_one]   # x1f
    mulss xmm7, xmm7
    mulss xmm7, xmm2
    mulss xmm7, [rip + f_half]  # am
    # a[xai] += d*a0
    movss xmm8, xmm4
    mulss xmm8, xmm10
    addss xmm8, [rdi + r10*4]
    movss [rdi + r10*4], xmm8
    lea eax, [r10 + 2]
    cmp r11d, eax
    jne .Lrl_long
    movss xmm8, [rip + f_one]
    subss xmm8, xmm4
    subss xmm8, xmm7
    mulss xmm8, xmm10
    addss xmm8, [rdi + r10*4 + 4]
    movss [rdi + r10*4 + 4], xmm8
    jmp .Lrl_last
.Lrl_long:
    movss xmm8, [rip + f_1p5]
    subss xmm8, xmm0
    mulss xmm8, xmm2            # a1
    movss xmm13, xmm8
    subss xmm13, xmm4
    mulss xmm13, xmm10
    addss xmm13, [rdi + r10*4 + 4]
    movss [rdi + r10*4 + 4], xmm13
    movss xmm13, xmm2
    mulss xmm13, xmm10          # d*s
    lea eax, [r10 + 2]
    lea esi, [r11 - 1]
3:  cmp eax, esi
    jge 4f
    movss xmm14, [rdi + rax*4]
    addss xmm14, xmm13
    movss [rdi + rax*4], xmm14
    inc eax
    jmp 3b
4:  # a2 = a1 + (xbi - xai - 3) * s
    mov eax, r11d
    sub eax, r10d
    sub eax, 3
    cvtsi2ss xmm13, eax
    mulss xmm13, xmm2
    addss xmm13, xmm8
    movss xmm14, [rip + f_one]
    subss xmm14, xmm13
    subss xmm14, xmm7
    mulss xmm14, xmm10
    addss xmm14, [rdi + r11*4 - 4]
    movss [rdi + r11*4 - 4], xmm14
.Lrl_last:
    mulss xmm7, xmm10
    addss xmm7, [rdi + r11*4]
    movss [rdi + r11*4], xmm7
.Lrl_next:
    movss xmm6, xmm9
    inc ecx
    jmp .Lrl_row
.Lrl_ret:
    ret

# raster_quad(xmm0..5 = x0, y0, x1, y1, x2, y2): rasterize a quadratic
# Bezier segment by flattening it into raster_line calls between
# successive points t = i/n.
# n is chosen from the curve's bulge: dd = |p0 - 2*p1 + p2| (the deviation
# from a straight line) turns into sqrt(1.5*dd) + 1 segments, so
# nearly straight curves cost one line and sharp ones (capped at 48) still
# stay smooth.
FN raster_quad
    PROLOGUE 64
    movss [rsp], xmm0
    movss [rsp + 4], xmm1
    movss [rsp + 8], xmm2
    movss [rsp + 12], xmm3
    movss [rsp + 16], xmm4
    movss [rsp + 20], xmm5
    # dd = |p0 - 2p1 + p2|
    movss xmm6, xmm2
    addss xmm6, xmm6
    movss xmm7, xmm0
    subss xmm7, xmm6
    addss xmm7, xmm4
    movss xmm6, xmm3
    addss xmm6, xmm6
    movss xmm8, xmm1
    subss xmm8, xmm6
    addss xmm8, xmm5
    mulss xmm7, xmm7
    mulss xmm8, xmm8
    addss xmm7, xmm8
    sqrtss xmm7, xmm7
    mulss xmm7, [rip + f_1p5]
    sqrtss xmm7, xmm7
    cvttss2si ebx, xmm7
    inc ebx
    cmp ebx, 48
    jle 1f
    mov ebx, 48
1:  cvtsi2ss xmm0, ebx
    movss xmm1, [rip + f_one]
    divss xmm1, xmm0
    movss [rsp + 24], xmm1      # 1/n
    movss xmm0, [rsp]
    movss [rsp + 28], xmm0      # prev x
    movss xmm0, [rsp + 4]
    movss [rsp + 32], xmm0      # prev y
    mov r12d, 1
.Lrq_loop:
    cmp r12d, ebx
    jg .Lrq_ret
    cvtsi2ss xmm0, r12d
    mulss xmm0, [rsp + 24]      # t
    movss xmm1, [rip + f_one]
    subss xmm1, xmm0            # mt
    movss xmm2, xmm1
    mulss xmm2, xmm1            # mt^2
    movss xmm3, xmm1
    mulss xmm3, xmm0
    addss xmm3, xmm3            # 2 mt t
    movss xmm4, xmm0
    mulss xmm4, xmm0            # t^2
    movss xmm5, [rsp]
    mulss xmm5, xmm2
    movss xmm6, [rsp + 8]
    mulss xmm6, xmm3
    addss xmm5, xmm6
    movss xmm6, [rsp + 16]
    mulss xmm6, xmm4
    addss xmm5, xmm6            # x
    movss xmm7, [rsp + 4]
    mulss xmm7, xmm2
    movss xmm6, [rsp + 12]
    mulss xmm6, xmm3
    addss xmm7, xmm6
    movss xmm6, [rsp + 20]
    mulss xmm6, xmm4
    addss xmm7, xmm6            # y
    movss [rsp + 36], xmm5
    movss [rsp + 40], xmm7
    movss xmm0, [rsp + 28]
    movss xmm1, [rsp + 32]
    movss xmm2, xmm5
    movss xmm3, xmm7
    call raster_line
    movss xmm0, [rsp + 36]
    movss [rsp + 28], xmm0
    movss xmm0, [rsp + 40]
    movss [rsp + 32], xmm0
    inc r12d
    jmp .Lrq_loop
.Lrq_ret:
    EPILOGUE

# raster_end(out=rdi): converts the accumulator into w*h alpha bytes.
# Per cell (walking the buffer linearly) the running prefix sum is kept in
# xmm0, its absolute value clamped to 1, scaled to 0..255, and rounded
# through gamma_tab into out. This is the step that turns per-edge area
# deposits into actual coverage, and it assumes raster_begin laid the cells
# out (see raster_line).
FN raster_end
    mov rsi, [rip + acc_buf]
    mov ecx, [rip + g_acc_w]
    imul ecx, [rip + g_acc_h]
    lea r8, [rip + gamma_tab]
    xorps xmm0, xmm0
    movss xmm2, [rip + f_one]
    movss xmm3, [rip + f_255]
    movss xmm4, [rip + abs_mask]
    xor edx, edx
1:  cmp edx, ecx
    jge 2f
    addss xmm0, [rsi + rdx*4]
    movss xmm1, xmm0
    andps xmm1, xmm4
    minss xmm1, xmm2
    mulss xmm1, xmm3
    cvtss2si eax, xmm1
    movzx eax, byte ptr [r8 + rax]
    mov [rdi + rdx], al
    inc edx
    jmp 1b
2:  ret

.section .rodata
.p2align 4
.globl abs_mask
abs_mask: .long 0x7fffffff, 0x7fffffff, 0x7fffffff, 0x7fffffff
.globl f_eps, f_mone, f_1p5
f_eps: .float 0.0001
f_mone: .float -1.0
f_1p5: .float 1.5
