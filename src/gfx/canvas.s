# ---- canvas: the whole 2d drawing layer ----
# The UI paints onto a single 32-bit framebuffer through these routines. Each
# pixel is one 32-bit word in XRGB8888 layout (little endian: B, G, R bytes,
# then an X byte that is treated as opaque). gfx_set_target points the canvas
# at a buffer: normally one buffer's worth of a Wayland shared-memory pool
# (wayland.s, re-targeted every frame), or the offscreen headless buffer
# (headless.s). Row pitch is stride_px, in pixels, applied as + stride*4
# bytes between rows.
# Every drawing primitive is clipped against the rectangle held in g_cv
# (CV_cx0..CV_cy1). gfx_clip_push intersects the clip with a rectangle and
# saves the old clip rect on clip_stack, gfx_clip_pop restores it. That lets
# each widget draw without knowing its scroll state.
# Entry points: gfx_set_target, gfx_fill, gfx_blend_px, gfx_round_rect,
# gfx_frame, gfx_mask (alpha bitmap, the glyph path), color_mix,
# color_alpha. All clobber only argument registers unless stated otherwise.
.include "unn.inc"

.equ CLIP_DEPTH, 32

.bss
.p2align 4
.globl g_cv
g_cv: .zero CV_SIZE
clip_stack: .zero 16 * CLIP_DEPTH   # x0, x1 of each pushed clip (the y edges
                                    # are not stacked)
clip_sp: .quad 0

.text

# gfx_set_target(pixels=rdi, w=esi, h=edx, stride_px=ecx)
# Sets the drawing target and resets the clip rectangle to the whole buffer.
# Note the clip and pixel pointers live in g_cv in .bss, so re-targeting is
# cheap: no allocation, no state to restore.
FN gfx_set_target
    mov [rip + g_cv + CV_pixels], rdi
    mov [rip + g_cv + CV_w], esi
    mov [rip + g_cv + CV_h], edx
    mov [rip + g_cv + CV_stride], ecx
    mov dword ptr [rip + g_cv + CV_cx0], 0
    mov dword ptr [rip + g_cv + CV_cy0], 0
    mov [rip + g_cv + CV_cx1], esi
    mov [rip + g_cv + CV_cy1], edx
    mov qword ptr [rip + clip_sp], 0
    ret

# gfx_clip_push(x=rdi, y=esi, w=edx, h=ecx)
# Intersects the clip with x..x+w and y..y+h, after saving the current clip
# rect on clip_stack: two 8-byte pairs ([cx0|cy0], [cx1|cy1] — CV_cx0 and
# CV_cx1 each sit on adjacent dwords, so one qword move carries a pair),
# 16 bytes per entry, both axes restored by gfx_clip_pop. If the
# intersection is empty, x0/x1 (and y0/y1) invert, which every primitive
# treats as nothing to draw. With the stack full the old clip is not saved,
# but the intersection still applies.
FN gfx_clip_push
    mov rax, [rip + clip_sp]
    cmp rax, CLIP_DEPTH
    jae 1f
    lea r8, [rip + clip_stack]
    shl rax, 4
    mov r9, [rip + g_cv + CV_cx0]
    mov [r8 + rax], r9
    mov r9, [rip + g_cv + CV_cx1]
    mov [r8 + rax + 8], r9
    inc qword ptr [rip + clip_sp]
1:  lea edx, [rdx + rdi]        # x1
    lea ecx, [rcx + rsi]        # y1
    mov eax, [rip + g_cv + CV_cx0]
    cmp edi, eax
    cmovl edi, eax
    mov eax, [rip + g_cv + CV_cy0]
    cmp esi, eax
    cmovl esi, eax
    mov eax, [rip + g_cv + CV_cx1]
    cmp edx, eax
    cmovg edx, eax
    mov eax, [rip + g_cv + CV_cy1]
    cmp ecx, eax
    cmovg ecx, eax
    cmp edx, edi
    cmovl edx, edi
    cmp ecx, esi
    cmovl ecx, esi
    mov [rip + g_cv + CV_cx0], edi
    mov [rip + g_cv + CV_cy0], esi
    mov [rip + g_cv + CV_cx1], edx
    mov [rip + g_cv + CV_cy1], ecx
    ret

# gfx_clip_pop(): restores the clip rect saved by the last gfx_clip_push
# (both axes: the stack holds [cx0|cy0] and [cx1|cy1] pairs). On an empty
# stack it leaves the clip untouched.
FN gfx_clip_pop
    mov rax, [rip + clip_sp]
    test rax, rax
    jz 1f
    dec rax
    mov [rip + clip_sp], rax
    lea r8, [rip + clip_stack]
    shl rax, 4
    mov r9, [r8 + rax]
    mov [rip + g_cv + CV_cx0], r9
    mov r9, [r8 + rax + 8]
    mov [rip + g_cv + CV_cx1], r9
1:  ret

# BLEND: blend the color in ecx over the pixel in eax by alpha edx (0..255),
# result in eax, clobbers r8-r11 and its inputs. Inline expansion, used by
# the scalar fill, point blend and mask paths. The given alpha is widened to
# 0..256 (a + (a>>7)) so (src*a' + dst*(256-a')) >> 8 is exact at 0 and 255,
# and the color is split into a red+blue half and a green half, widened in
# place, multiplied, added and shifted back down; every 8-bit channel times
# a' (255*256) stays inside its 16-bit lane, so the halves mix independently.
# The top byte is forced opaque.
.macro BLEND
    mov r8d, edx
    shr r8d, 7
    add r8d, edx                # a' in 0..256
    mov r9d, 256
    sub r9d, r8d                # 256 - a'
    mov r10d, ecx
    and r10d, 0xff00ff
    imul r10d, r8d
    mov r11d, eax
    and r11d, 0xff00ff
    imul r11d, r9d
    add r10d, r11d
    shr r10d, 8
    and r10d, 0xff00ff
    and ecx, 0x00ff00
    imul ecx, r8d
    and eax, 0x00ff00
    imul eax, r9d
    add eax, ecx
    shr eax, 8
    and eax, 0x00ff00
    or eax, r10d
    or eax, 0xff000000
.endm

# gfx_fill(x=rdi, y=esi, w=edx, h=ecx, argb=r8d): fill a rectangle.
# The rectangle is intersected with the clip, then drawn along one of three
# paths: fully opaque colors go through rep stosd one row at a time,
# translucent ones through the scalar blend loop below, and translucent rows
# of 4 or more pixels through .Lfill_wide, the vector loop.
FN gfx_fill
    push rbx
    push r12
    push r13
    push r14
    push r15
    lea edx, [rdx + rdi]        # x1
    lea ecx, [rcx + rsi]        # y1
    mov eax, [rip + g_cv + CV_cx0]
    cmp edi, eax
    cmovl edi, eax
    mov eax, [rip + g_cv + CV_cy0]
    cmp esi, eax
    cmovl esi, eax
    mov eax, [rip + g_cv + CV_cx1]
    cmp edx, eax
    cmovg edx, eax
    mov eax, [rip + g_cv + CV_cy1]
    cmp ecx, eax
    cmovg ecx, eax
    sub edx, edi                # w
    jle .Lfill_ret
    sub ecx, esi                # h
    jle .Lfill_ret
    mov r12d, edx
    mov r13d, ecx
    mov ebx, r8d                # color
    movsxd rdi, edi
    movsxd rsi, esi
    mov eax, [rip + g_cv + CV_stride]
    mov r14, rax
    imul rsi, rax
    add rsi, rdi
    mov r15, [rip + g_cv + CV_pixels]
    lea r15, [r15 + rsi*4]      # row ptr
    mov eax, ebx
    shr eax, 24
    cmp eax, 255
    jne .Lfill_blend
    or ebx, 0xff000000
.Lfill_row:
    mov rdi, r15
    mov eax, ebx
    mov ecx, r12d
    rep stosd
    lea r15, [r15 + r14*4]
    dec r13d
    jnz .Lfill_row
    jmp .Lfill_ret
.Lfill_blend:
    test eax, eax
    jz .Lfill_ret
    mov esi, eax                # alpha
    cmp r12d, 4
    jae .Lfill_wide
.Lfill_brow:
    xor edi, edi
.Lfill_bpx:
    mov eax, [r15 + rdi*4]
    mov ecx, ebx
    mov edx, esi
    BLEND
    mov [r15 + rdi*4], eax
    inc edi
    cmp edi, r12d
    jb .Lfill_bpx
    lea r15, [r15 + r14*4]
    dec r13d
    jnz .Lfill_brow
.Lfill_ret:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret
# Vector path for wide translucent rows, the same math as BLEND, four pixels
# at a time: (color * a' + pixel * (256 - a')) >> 8 per 16-bit channel. The
# color's contribution is the same for every pixel, so it is precomputed in
# xmm5, which is what makes this worthwhile: the modal dialog shade that dims
# a whole window used to take most of its frame one pixel at a time. Only
# colors with alpha 1..254 reach this path (0 and 255 were filtered out on
# the way to .Lfill_blend). The xmm registers it borrows are saved on the
# stack first and restored before the common return.
.Lfill_wide:
    sub rsp, 96
    movdqu [rsp], xmm0
    movdqu [rsp + 16], xmm1
    movdqu [rsp + 32], xmm4
    movdqu [rsp + 48], xmm5
    movdqu [rsp + 64], xmm6
    movdqu [rsp + 80], xmm7
    mov eax, esi
    shr eax, 7
    add eax, esi                # a' 0..256
    mov ecx, 256
    sub ecx, eax
    movd xmm4, ecx
    pshuflw xmm4, xmm4, 0
    punpcklqdq xmm4, xmm4       # 256 - a' in every word
    movd xmm0, eax
    pshuflw xmm0, xmm0, 0       # a' in the low four
    pxor xmm6, xmm6
    movd xmm5, ebx
    punpcklbw xmm5, xmm6        # the color's channels as words
    pmullw xmm5, xmm0
    punpcklqdq xmm5, xmm5       # times a', for two pixels
    mov eax, 0xff000000
    movd xmm7, eax
    pshufd xmm7, xmm7, 0
.Lfill_wrow:
    xor edi, edi
.Lfill_w4:
    lea eax, [rdi + 4]
    cmp eax, r12d
    ja .Lfill_wtail
    movdqu xmm0, [r15 + rdi*4]
    movdqu xmm1, xmm0
    psrldq xmm1, 8
    punpcklbw xmm0, xmm6
    punpcklbw xmm1, xmm6
    pmullw xmm0, xmm4
    pmullw xmm1, xmm4
    paddw xmm0, xmm5
    paddw xmm1, xmm5
    psrlw xmm0, 8
    psrlw xmm1, 8
    packuswb xmm0, xmm1
    por xmm0, xmm7
    movdqu [r15 + rdi*4], xmm0
    add edi, 4
    jmp .Lfill_w4
.Lfill_wtail:
    cmp edi, r12d
    jae .Lfill_wnext
    mov eax, [r15 + rdi*4]
    mov ecx, ebx
    mov edx, esi
    BLEND
    mov [r15 + rdi*4], eax
    inc edi
    jmp .Lfill_wtail
.Lfill_wnext:
    lea r15, [r15 + r14*4]
    dec r13d
    jnz .Lfill_wrow
    movdqu xmm0, [rsp]
    movdqu xmm1, [rsp + 16]
    movdqu xmm4, [rsp + 32]
    movdqu xmm5, [rsp + 48]
    movdqu xmm6, [rsp + 64]
    movdqu xmm7, [rsp + 80]
    add rsp, 96
    jmp .Lfill_ret

# gfx_blend_px(x=edi, y=esi, argb=edx, alpha=ecx 0..255): blend one pixel.
# The effective alpha is the color's own alpha multiplied by the argument,
# in 255ths with rounding, which is what layered shading wants. Points
# outside the clip rectangle and fully transparent results do not touch
# memory at all. Uses the BLEND macro above (so r8-r11 are clobbered).
FN gfx_blend_px
    cmp edi, [rip + g_cv + CV_cx0]
    jl 1f
    cmp edi, [rip + g_cv + CV_cx1]
    jge 1f
    cmp esi, [rip + g_cv + CV_cy0]
    jl 1f
    cmp esi, [rip + g_cv + CV_cy1]
    jge 1f
    mov eax, edx
    shr eax, 24
    imul ecx, eax
    lea eax, [rcx + 128]
    shr eax, 8
    add ecx, eax
    shr ecx, 8                  # alpha * a / 255
    test ecx, ecx
    jz 1f
    push rbx
    mov ebx, edx
    mov edx, ecx
    mov ecx, ebx
    movsxd rsi, esi
    movsxd rdi, edi
    mov eax, [rip + g_cv + CV_stride]
    imul rsi, rax
    add rsi, rdi
    mov rdi, [rip + g_cv + CV_pixels]
    lea rdi, [rdi + rsi*4]
    mov eax, [rdi]
    BLEND
    mov [rdi], eax
    pop rbx
1:  ret

# gfx_round_rect(x=rdi, y=esi, w=edx, h=ecx, radius=r8d, argb=r9d)
# A filled rounded rectangle. The radius is clamped to half of min(w, h)
# first, so degenerate sizes degrade to a plain fill (.Lrr_plain). With a
# real radius: the middle band (rows r..h-r) is one gfx_fill, then for the
# first and last r rows the center span is filled as a 1px-high rect and the
# corner pixels are placed by gfx_blend_px. A corner pixel's coverage comes
# from its distance to the quadrant's arc center, measured at the pixel
# center (offset by f_half), folded into an alpha 0..255 by the float code
# with the f_* constants in .rodata below.
FN gfx_round_rect
    PROLOGUE 48
    mov r12d, edi               # x
    mov r13d, esi               # y
    mov r14d, edx               # w
    mov r15d, ecx               # h
    mov [rsp + 36], r9d         # color
    # clamp radius to min(w,h)/2
    mov eax, edx
    cmp eax, ecx
    cmovg eax, ecx
    sar eax, 1
    cmp r8d, eax
    cmovg r8d, eax
    mov ebx, r8d                # r
    test ebx, ebx
    jle .Lrr_plain
    # middle band
    mov edi, r12d
    lea esi, [r13 + rbx]
    mov edx, r14d
    mov ecx, r15d
    sub ecx, ebx
    sub ecx, ebx
    mov r8d, r9d
    call gfx_fill
    # center spans of corner rows
    mov dword ptr [rsp], 0      # i
.Lrr_rows:
    mov eax, [rsp]
    cmp eax, ebx
    jge .Lrr_done
    lea edi, [r12 + rbx]
    lea esi, [r13 + rax]
    mov edx, r14d
    sub edx, ebx
    sub edx, ebx
    mov ecx, 1
    mov r8d, [rsp + 36]
    call gfx_fill
    mov eax, [rsp]
    lea edi, [r12 + rbx]
    lea esi, [r13 + r15 - 1]
    sub esi, eax
    mov edx, r14d
    sub edx, ebx
    sub edx, ebx
    mov ecx, 1
    mov r8d, [rsp + 36]
    call gfx_fill
    # corner pixels of this row
    mov dword ptr [rsp + 4], 0  # j
.Lrr_cols:
    mov eax, [rsp + 4]
    cmp eax, ebx
    jge .Lrr_nextrow
    # dx = r - j - 0.5 ; dy = r - i - 0.5
    cvtsi2ss xmm0, ebx
    cvtsi2ss xmm1, eax
    subss xmm0, xmm1
    subss xmm0, [rip + f_half]
    cvtsi2ss xmm2, ebx
    cvtsi2ss xmm1, dword ptr [rsp]
    subss xmm2, xmm1
    subss xmm2, [rip + f_half]
    mulss xmm0, xmm0
    mulss xmm2, xmm2
    addss xmm0, xmm2
    sqrtss xmm0, xmm0
    cvtsi2ss xmm1, ebx
    addss xmm1, [rip + f_half]
    subss xmm1, xmm0            # coverage
    maxss xmm1, [rip + f_zero]
    minss xmm1, [rip + f_one]
    mulss xmm1, [rip + f_255]
    cvtss2si eax, xmm1
    test eax, eax
    jz .Lrr_nextcol
    mov [rsp + 8], eax
    # top-left
    mov ecx, [rsp + 4]
    lea edi, [r12 + rcx]
    mov ecx, [rsp]
    lea esi, [r13 + rcx]
    mov edx, [rsp + 36]
    mov ecx, [rsp + 8]
    call gfx_blend_px
    # top-right
    mov ecx, [rsp + 4]
    lea edi, [r12 + r14 - 1]
    sub edi, ecx
    mov ecx, [rsp]
    lea esi, [r13 + rcx]
    mov edx, [rsp + 36]
    mov ecx, [rsp + 8]
    call gfx_blend_px
    # bottom-left
    mov ecx, [rsp + 4]
    lea edi, [r12 + rcx]
    mov ecx, [rsp]
    lea esi, [r13 + r15 - 1]
    sub esi, ecx
    mov edx, [rsp + 36]
    mov ecx, [rsp + 8]
    call gfx_blend_px
    # bottom-right
    mov ecx, [rsp + 4]
    lea edi, [r12 + r14 - 1]
    sub edi, ecx
    mov ecx, [rsp]
    lea esi, [r13 + r15 - 1]
    sub esi, ecx
    mov edx, [rsp + 36]
    mov ecx, [rsp + 8]
    call gfx_blend_px
.Lrr_nextcol:
    inc dword ptr [rsp + 4]
    jmp .Lrr_cols
.Lrr_nextrow:
    inc dword ptr [rsp]
    jmp .Lrr_rows
.Lrr_plain:
    mov edi, r12d
    mov esi, r13d
    mov edx, r14d
    mov ecx, r15d
    mov r8d, [rsp + 36]
    call gfx_fill
.Lrr_done:
    EPILOGUE

# gfx_frame(x=rdi, y=esi, w=edx, h=ecx, radius=r8d, border=r9d,
#           fill at [rbp+16], a 7th argument on the stack)
# A rounded rect in the border color with an inset rounded rect in the fill
# color on top, both drawn by gfx_round_rect: the border ends up border thick
# on every side. g_border (below) is the inset, currently always 1 px.
FN gfx_frame
    PROLOGUE 16
    mov r12d, edi
    mov r13d, esi
    mov r14d, edx
    mov r15d, ecx
    mov ebx, r8d
    mov eax, [rbp + 16]         # fill (7th arg on stack)
    mov [rsp], eax
    mov r8d, ebx
    call gfx_round_rect
    mov eax, [rip + g_border]
    lea edi, [r12 + rax]
    lea esi, [r13 + rax]
    mov edx, r14d
    sub edx, eax
    sub edx, eax
    mov ecx, r15d
    sub ecx, eax
    sub ecx, eax
    mov r8d, ebx
    sub r8d, eax
    mov r9d, [rsp]
    call gfx_round_rect
    EPILOGUE

# gfx_mask(x=rdi, y=esi, bits=rdx, w=ecx, h=r8d, argb=r9d)
# Blend an 8-bit alpha mask over the canvas: one byte per pixel, row-major,
# row length w in bytes. This is how glyphs land (face_glyph rasterizes each
# glyph once, then text_draw calls this per glyph). The mask byte that maps
# to canvas pixel (px, py) sits at bits + (py - y)*w + (px - x); clipping the
# x range (r13..r14) up front means the pointer arithmetic below can just
# index rsi by the canvas x. Effective alpha is mask * color-alpha in 255ths
# with rounding, then the BLEND macro, exactly like gfx_blend_px.
FN gfx_mask
    PROLOGUE 32
    mov [rsp], edi              # x
    mov [rsp + 4], esi          # y
    mov r12, rdx                # bits
    mov [rsp + 8], ecx          # w (mask stride)
    mov [rsp + 12], r8d         # h
    mov ebx, r9d                # color
    mov eax, ebx
    shr eax, 24
    mov [rsp + 16], eax         # color alpha
    # clipped span
    mov r13d, edi               # x0
    lea r14d, [rdi + rcx]       # x1
    mov eax, [rip + g_cv + CV_cx0]
    cmp r13d, eax
    cmovl r13d, eax
    mov eax, [rip + g_cv + CV_cx1]
    cmp r14d, eax
    cmovg r14d, eax
    cmp r14d, r13d
    jle .Lmk_ret
    mov r15d, esi               # y0
    lea eax, [rsi + r8]
    mov [rsp + 20], eax         # y1
    mov eax, [rip + g_cv + CV_cy0]
    cmp r15d, eax
    cmovl r15d, eax
    mov eax, [rip + g_cv + CV_cy1]
    cmp [rsp + 20], eax
    jle 1f
    mov [rsp + 20], eax
1:
.Lmk_row:
    cmp r15d, [rsp + 20]
    jge .Lmk_ret
    # src row = bits + (y - y0)*w
    mov eax, r15d
    sub eax, [rsp + 4]
    imul eax, [rsp + 8]
    movsxd rax, eax
    lea rsi, [r12 + rax]
    movsxd rax, dword ptr [rsp]
    sub rsi, rax                # so that rsi[x] is the mask byte for canvas x
    mov eax, r15d
    imul eax, [rip + g_cv + CV_stride]
    movsxd rax, eax
    mov rdi, [rip + g_cv + CV_pixels]
    lea rdi, [rdi + rax*4]
    movsxd r10, r13d
.Lmk_px:
    movzx edx, byte ptr [rsi + r10]
    test edx, edx
    jz .Lmk_next
    imul edx, [rsp + 16]
    lea eax, [rdx + 128]
    shr eax, 8
    add edx, eax
    shr edx, 8
    mov eax, [rdi + r10*4]
    mov ecx, ebx
    push r10
    BLEND
    pop r10
    mov [rdi + r10*4], eax
.Lmk_next:
    inc r10
    cmp r10d, r14d
    jl .Lmk_px
    inc r15d
    jmp .Lmk_row
.Lmk_ret:
    EPILOGUE

# color_mix(a=edi, b=esi, t=edx 0..255) -> eax, a faded a*(1-t) + b*t
# BLEND does the work with a as the pixel under the brush and b as the
# source color. The result is opaque.
FN color_mix
    mov eax, edi
    mov ecx, esi
    push rbx
    BLEND
    pop rbx
    ret

# color_alpha(argb=edi, alpha=esi) -> eax, the same color with its top byte
# replaced by alpha. Cheap way to clone a theme color with a different
# opacity for shadows and overlays.
FN color_alpha
    mov eax, edi
    and eax, 0x00ffffff
    shl esi, 24
    or eax, esi
    ret

.section .rodata
.p2align 2
# float helpers for the rounded-rect corner coverage (f_64 is font.s scaling)
.globl f_half, f_zero, f_one, f_255, f_64
f_half: .float 0.5
f_zero: .float 0.0
f_one: .float 1.0
f_255: .float 255.0
f_64: .float 64.0

.data
# g_border: the border width for gfx_frame, in px. Nothing changes it in this
# build (it stays 1), but keeping it a global puts the frame width in one
# place.
.globl g_border
g_border: .long 1
