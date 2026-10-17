# ---- ui: immediate-mode interface core ----
# Scaled metrics, input state, hit testing and the small widget set the app
# draws with. Everything is immediate mode: each frame the app walks its
# widgets in draw order, calling ui_btn etc. with an id and a rectangle, and
# the returned bits tell it what happened. Hit testing is only
# pointer-inside-rectangle; g_block suppresses widget input while a modal
# layer is up, and g_hole reserves a strip for an element drawn later on the
# frame. This terminal-only build draws the terminal fullscreen and raises
# neither, but ui_in honors both.
# Layout sizes are logical values scaled at frame start by ui_update_metrics
# into g_mt (indexed by the MI_* constants); the M reg, MI_x macro loads one.
# Fonts live in here too: ui faces (small, big, huge variants) and the
# code face the terminal builds its face from, with the code face's line
# height and cell width globals g_lh / g_cw / g_base.
# Input comes in from the platform layer through ui_input_motion,
# ui_input_button and ui_input_scroll; the frame bracket is ui_begin /
# ui_end (ui_end also clears per-frame input and picks the cursor).
# Scrollbars: ui_scrollbar, ui_hscrollbar plus the auto-hide flash state
# (sb_thumb, sb_tick, sb_timeout, sb_cursor).
# Entry points: ui_update_metrics, ui_force_metrics, sc (scale helper),
# the ui_input_* trio, ui_begin, ui_end, ui_in, ui_btn, ui_set_cursor,
# ui_text_v, ui_text_c, ui_text_center, ui_card_shadow, ui_toggle,
# ui_scrollbar, ui_hscrollbar, sb_tick, sb_timeout.
.include "unn.inc"

.bss
.p2align 3
# ---- input and widget state, one frame's worth ----
# g_mt: MI_COUNT scaled metric values, rebuilt by ui_update_metrics
.globl g_mt, g_s, g_mx, g_my, g_mdown, g_pressed, g_released, g_scroll_x, g_scroll_y
.globl g_hot, g_active, g_cursor, g_block, g_clicks, g_press_x, g_face_ui, g_face_small, g_face_big, g_face_code
.globl g_hole
g_mt: .zero 4 * MI_COUNT
g_s: .long 0                    # float scale, config x dpi scale
g_mdown: .long 0                # buttons held (bit per button)
g_pressed: .long 0              # pressed bits since the last frame ended
g_released: .long 0
g_scroll_x: .long 0
g_scroll_y: .long 0
g_hot: .long 0
g_active: .long 0
g_cursor: .long 0
g_block: .long 0                # 1 while drawing layers under a modal
g_hole: .zero 16                # x, y, w, h: a strip an element drawn later on this
                                # frame will own, so widgets drawn before it get no
                                # pointer events there (inner h 0: none set). Only
                                # the strip test in ui_in reads it in this build.
g_clicks: .long 0               # click count of the last press (1..3)
last_press_t: .quad 0
last_press_x: .long 0
last_press_y: .long 0
g_press_x: .long 0              # where the left button went down last
held_mx: .long 0                # a pointer move waiting for the frame of a press
held_my: .long 0
held_move: .long 0
.equ SB_MAX, 16                 # scrollbars tracked for the scroll-flash
.equ SB_SHOW_MS, 800            # ms a thumb stays visible after its offset last moved
# sb_flash slot: +0 scrollbar id, +8 last offset px (+pad), +16 show-until ms; 24B each
sb_flash: .zero SB_MAX * 24
.p2align 3
g_face_ui: .zero FACE_SIZE
g_face_small: .zero FACE_SIZE
g_face_big: .zero FACE_SIZE
g_face_code: .zero FACE_SIZE
.globl g_face_huge
g_face_huge: .zero FACE_SIZE
last_scale: .long 0
last_code_px: .long 0
last_ui_px: .long 0
.globl g_font_code, g_font_ui, g_font_term
g_font_code: .quad 0
g_font_ui: .quad 0
g_font_term: .quad 0            # the terminal's own font, or 0 to fall back to g_font_code
.globl g_lh, g_cw, g_base
g_lh: .long 0                   # code face line height
g_cw: .long 0                   # code face cell width
g_base: .long 0                 # baseline offset inside a line

.text

# ui_update_metrics(): recompute scaled sizes and font faces if anything
# changed. The UI scale is cfg_ui_scale * g_dpi_scale / 100, floored at half
# (fonts would be unreadable below that). When it moves, every MI_* logical
# metric is scaled into g_mt (at least 1 px), and the ui faces (normal,
# small - 1.5f px, big - 1.55x, huge - 3.4x) are re-initialized from the ui
# font. The code face changes when cfg_font_size or cfg_line_height change,
# and that is also where the code face's line metrics come from: line
# height is font px * line_height / 100 but never below the glyphs'
# ascent+descent,
# g_base centers the baseline in the extra leading, g_cw is the face's cell
# width (at least 1 px). All the last_* fields just remember the current
# settings so that unchanged ones skip re-initialization.
FN ui_update_metrics
    PROLOGUE 16
    # s = dpi * ui_scale / 100
    cvtsi2ss xmm0, dword ptr [rip + cfg_ui_scale]
    mulss xmm0, [rip + g_dpi_scale]
    divss xmm0, [rip + f_100]
    maxss xmm0, [rip + f_min_scale]     # fonts need a size of at least a few pixels
    movss [rip + g_s], xmm0
    movd eax, xmm0
    cmp eax, [rip + last_scale]
    je 2f
    mov [rip + last_scale], eax
    lea rbx, [rip + metric_values]
    xor ecx, ecx
1:  cmp ecx, MI_COUNT
    jae 2f
    cvtsi2ss xmm1, dword ptr [rbx + rcx*4]
    mulss xmm1, [rip + g_s]
    cvtss2si eax, xmm1
    cmp eax, 1
    jge 11f
    mov eax, 1
11: lea rdx, [rip + g_mt]
    mov [rdx + rcx*4], eax
    inc ecx
    jmp 1b
2:  # ui faces
    cvtsi2ss xmm0, dword ptr [rip + cfg_ui_font_size]
    mulss xmm0, [rip + g_s]
    cvtss2si ebx, xmm0
    cmp ebx, [rip + last_ui_px]
    je 3f
    mov [rip + last_ui_px], ebx
    lea rdi, [rip + g_face_ui]
    mov rsi, [rip + g_font_ui]
    mov edx, ebx
    call face_init
    cvtsi2ss xmm0, dword ptr [rip + cfg_ui_font_size]
    subss xmm0, [rip + f_1p5]
    mulss xmm0, [rip + g_s]
    cvtss2si edx, xmm0
    lea rdi, [rip + g_face_small]
    mov rsi, [rip + g_font_ui]
    call face_init
    cvtsi2ss xmm0, dword ptr [rip + cfg_ui_font_size]
    mulss xmm0, [rip + f_big]
    mulss xmm0, [rip + g_s]
    cvtss2si edx, xmm0
    lea rdi, [rip + g_face_big]
    mov rsi, [rip + g_font_ui]
    call face_init
    cvtsi2ss xmm0, dword ptr [rip + cfg_ui_font_size]
    mulss xmm0, [rip + f_huge]
    mulss xmm0, [rip + g_s]
    cvtss2si edx, xmm0
    lea rdi, [rip + g_face_huge]
    mov rsi, [rip + g_font_ui]
    call face_init
3:  # code face + line metrics
    cvtsi2ss xmm0, dword ptr [rip + cfg_font_size]
    mulss xmm0, [rip + g_s]
    cvtss2si ebx, xmm0
    mov eax, ebx
    shl eax, 8
    xor eax, [rip + cfg_line_height]
    cmp eax, [rip + last_code_px]
    je 4f
    mov [rip + last_code_px], eax
    lea rdi, [rip + g_face_code]
    mov rsi, [rip + g_font_code]
    mov edx, ebx
    call face_init
    # line height = font px * line_height / 100, at least ascent+descent
    mov eax, ebx
    imul eax, [rip + cfg_line_height]
    add eax, 50
    xor edx, edx
    mov ecx, 100
    div ecx
    mov ecx, [rip + g_face_code + FACE_ascent]
    add ecx, [rip + g_face_code + FACE_descent]
    cmp eax, ecx
    cmovl eax, ecx
    mov [rip + g_lh], eax
    sub eax, ecx
    sar eax, 1
    add eax, [rip + g_face_code + FACE_ascent]
    mov [rip + g_base], eax
    mov eax, [rip + g_face_code + FACE_cellw]
    cmp eax, 1
    jge 5f
    mov eax, 1
5:  mov [rip + g_cw], eax
4:  EPILOGUE

# ui_force_metrics(): invalidate the last_* change detectors so that the
# next ui_update_metrics rebuilds every face and metric (call when fonts
# or settings changed under us), and mark the screen dirty.
FN ui_force_metrics
    mov dword ptr [rip + last_scale], 0
    mov dword ptr [rip + last_ui_px], 0
    mov dword ptr [rip + last_code_px], 0
    mov dword ptr [rip + g_dirty], 1
    ret

# sc(v=edi) -> eax v scaled by the current UI scale (round to px)
FN sc
    cvtsi2ss xmm0, edi
    mulss xmm0, [rip + g_s]
    cvtss2si eax, xmm0
    ret

# ---- input (called from platform callbacks) ----

# ui_input_motion(x, y): while a press waits for its frame the pointer
# stays where the press was made, and the move lands after that frame;
# otherwise a synthetic click, or a mouse faster than the frames, has the
# press hit tested wherever the pointer went next
FN ui_input_motion
    cmp dword ptr [rip + g_pressed], 0
    jne 1f
    mov [rip + g_mx], edi
    mov [rip + g_my], esi
    ret
1:  mov [rip + held_mx], edi
    mov [rip + held_my], esi
    mov dword ptr [rip + held_move], 1
    ret

# ui_input_button(btn=edi, pressed=esi)
# Updates the button bit in g_mdown, the per-frame g_pressed / g_released
# bitmasks. For left presses the multi-click detector runs: a click within
# 450 ms AND within the double-click slop (metric MI_4) of the previous one
# bumps g_clicks (wrapping back to 1 past triple), anything else resets it
# to 1.
FN ui_input_button
    push rbx
    mov ecx, edi
    mov eax, 1
    shl eax, cl
    test esi, esi
    jz 2f
    or [rip + g_mdown], eax
    or [rip + g_pressed], eax
    cmp edi, BTN_LEFT
    jne 9f
    mov ebx, eax
    # multi-click detection
    mov eax, [rip + g_mx]
    mov [rip + g_press_x], eax
    call time_ms
    mov rcx, rax
    sub rcx, [rip + last_press_t]
    mov [rip + last_press_t], rax
    cmp rcx, 450
    ja 1f
    mov eax, [rip + g_mx]
    sub eax, [rip + last_press_x]
    cdq
    xor eax, edx
    sub eax, edx
    cmp eax, [rip + g_mt + 4*MI_4]
    jg 1f
    mov eax, [rip + g_my]
    sub eax, [rip + last_press_y]
    cdq
    xor eax, edx
    sub eax, edx
    cmp eax, [rip + g_mt + 4*MI_4]
    jg 1f
    mov eax, [rip + g_clicks]
    inc eax
    cmp eax, 3
    jbe 3f
    mov eax, 1
3:  mov [rip + g_clicks], eax
    jmp 4f
1:  mov dword ptr [rip + g_clicks], 1
4:  mov eax, [rip + g_mx]
    mov [rip + last_press_x], eax
    mov eax, [rip + g_my]
    mov [rip + last_press_y], eax
    jmp 9f
2:  not eax
    and [rip + g_mdown], eax
    not eax
    or [rip + g_released], eax
9:  pop rbx
    ret

# ui_input_scroll(dx=edi, dy=esi): accumulate scroll deltas for the frame,
# consumed by whichever scrollbar or view sees the pointer.
FN ui_input_scroll
    add [rip + g_scroll_x], edi
    add [rip + g_scroll_y], esi
    ret

# ---- frame ----

# ui_begin(): start a widget walk. Resets the per-frame hot widget, the
# cursor request and the modal block, and clears the reserved strip (g_hole).
FN ui_begin
    mov dword ptr [rip + g_hot], 0
    mov dword ptr [rip + g_cursor], CUR_DEFAULT
    mov dword ptr [rip + g_block], 0
    mov dword ptr [rip + g_hole + 12], 0
    ret

# ui_end(): close the frame's input.
# If a widget ran any press or release handler after part of the frame was
# already drawn, one extra frame gets scheduled so the result shows. Active
# state is
# released when the left button comes up, pressed/released/scroll are
# consumed, a pointer move that was held back for this frame's press lands
# now (the same rules as ui_input_motion above), and the frame's chosen
# cursor shape is pushed to the platform layer.
FN ui_end
    # handlers ran for a press or release during this frame, after part of
    # it was drawn: another frame shows what they changed
    mov eax, [rip + g_pressed]
    or eax, [rip + g_released]
    jz 0f
    mov dword ptr [rip + g_dirty], 1
0:  # clear active when left button is up
    test dword ptr [rip + g_mdown], 1 << BTN_LEFT
    jnz 1f
    mov dword ptr [rip + g_active], 0
1:  mov dword ptr [rip + g_pressed], 0
    mov dword ptr [rip + g_released], 0
    mov dword ptr [rip + g_scroll_x], 0
    mov dword ptr [rip + g_scroll_y], 0
    # the move held back for this frame's press, and a frame that shows it
    cmp dword ptr [rip + held_move], 0
    je 2f
    mov dword ptr [rip + held_move], 0
    mov eax, [rip + held_mx]
    mov [rip + g_mx], eax
    mov eax, [rip + held_my]
    mov [rip + g_my], eax
    mov dword ptr [rip + g_dirty], 1
2:  mov edi, [rip + g_cursor]
    PCALL P_cursor
    ret

# ui_in(x=edi, y=esi, w=edx, h=ecx) -> eax 1 if the pointer is inside the
# rectangle this frame AND input is not blocked by a modal (g_block) AND the
# pointer is inside the current canvas clip AND not over the reserved strip
# g_hole. This is the gate every widget goes through.
FN ui_in
    xor eax, eax
    cmp dword ptr [rip + g_block], 0
    jne 1f
    mov r8d, [rip + g_mx]
    mov r9d, [rip + g_my]
    cmp r8d, edi
    jl 1f
    add edi, edx
    cmp r8d, edi
    jge 1f
    cmp r9d, esi
    jl 1f
    add esi, ecx
    cmp r9d, esi
    jge 1f
    cmp r8d, [rip + g_cv + CV_cx0]
    jl 1f
    cmp r8d, [rip + g_cv + CV_cx1]
    jge 1f
    cmp r9d, [rip + g_cv + CV_cy0]
    jl 1f
    cmp r9d, [rip + g_cv + CV_cy1]
    jge 1f
1:  # g_hole belongs to an element drawn later on this frame, so widgets
    # drawn under it must not claim the pointer. (Only the registers this
    # clobbers anyway are used inside here.)
    mov eax, [rip + g_hole + 12]
    test eax, eax
    jz 2f
    mov esi, [rip + g_hole + 4]
    cmp r9d, esi
    jl 2f
    add esi, eax
    cmp r9d, esi
    jge 2f
    mov edi, [rip + g_hole]
    cmp r8d, edi
    jl 2f
    add edi, [rip + g_hole + 8]
    cmp r8d, edi
    jge 2f
    xor eax, eax
    ret
2:  mov eax, 1
1:  ret

# ui_btn(id=edi, x=esi, y=edx, w=ecx, h=r8d) -> eax UB_* bits (see unn.inc):
# UB_HOVER when the pointer is over the box, UB_PRESS / UB_RPRESS / UB_CLICK
# / UB_HELD while the frame's press, release or drag lands on the box
# (a UB_CLICK also requires this widget to be the active one from the press,
# so drags outside do not trigger), UB_DOUBLE on the second click of a
# multi-click press. Registering hits also sets g_hot (last widget hovered
# this frame) and g_active (widget owning the current drag).
FN ui_btn
    push rbx
    push r12
    mov ebx, edi
    mov edi, esi
    mov esi, edx
    mov edx, ecx
    mov ecx, r8d
    call ui_in
    xor r12d, r12d
    test eax, eax
    jz 2f
    or r12d, UB_HOVER
    mov [rip + g_hot], ebx
    test dword ptr [rip + g_pressed], 1 << BTN_LEFT
    jz 1f
    or r12d, UB_PRESS
    mov [rip + g_active], ebx
    cmp dword ptr [rip + g_clicks], 2
    jne 1f
    or r12d, UB_DOUBLE
1:  test dword ptr [rip + g_pressed], 1 << BTN_RIGHT
    jz 11f
    or r12d, UB_RPRESS
11: test dword ptr [rip + g_released], 1 << BTN_LEFT
    jz 2f
    cmp [rip + g_active], ebx
    jne 2f
    or r12d, UB_CLICK
2:  cmp [rip + g_active], ebx
    jne 3f
    test dword ptr [rip + g_mdown], 1 << BTN_LEFT
    jz 3f
    or r12d, UB_HELD
3:  mov eax, r12d
    pop r12
    pop rbx
    ret

# ui_set_cursor(shape=edi): request the frame's pointer shape. ui_end sends
# the request to the platform layer once per frame, and ui_begin resets it,
# so widgets must re-request whatever they want every frame.
FN ui_set_cursor
    mov [rip + g_cursor], edi
    ret

# ---- drawing helpers ----

# ui_text_v(face=rdi, x=esi, y=edx, h=ecx, ptr=r8, len=r9,
#           argb at [rbp+16], a 7th argument on the stack)
# Draws a run of text vertically centered in the band y .. y+h:
# baseline y + (h - ascent - descent)/2 + ascent. Thin wrapper over
# text_draw.
FN ui_text_v
    PROLOGUE
    mov rbx, rdi
    mov r12d, esi
    mov eax, ecx
    sub eax, [rbx + FACE_ascent]
    sub eax, [rbx + FACE_descent]
    sar eax, 1
    add eax, edx
    add eax, [rbx + FACE_ascent]
    mov edx, eax
    mov rcx, r8
    mov r8, r9
    mov r9d, [rbp + 16]
    mov rdi, rbx
    mov esi, r12d
    call text_draw
    EPILOGUE

# ui_text_c(face=rdi, x=esi, y=edx, h=ecx, cstr=r8, argb=r9) -> eax x after
# Same vertical centering as ui_text_v, but the text is a NUL-terminated
# string (length measured with strlen).
FN ui_text_c
    PROLOGUE 16
    mov rbx, rdi
    mov r12d, esi
    mov r13d, edx
    mov r14d, ecx
    mov r15, r8
    mov [rsp], r9d
    mov rdi, r8
    call strlen
    mov r9, rax
    mov rdi, rbx
    mov esi, r12d
    mov edx, r13d
    mov ecx, r14d
    mov r8, r15
    mov eax, [rsp]
    push rax
    push rax
    call ui_text_v
    add rsp, 16
    EPILOGUE

# ui_text_center(face=rdi, x=esi, y=edx, w=ecx, h=r8d, cstr=r9,
#                argb at [rbp+16], a 7th argument on the stack) -> eax x after
# Centered in the box on both axes, with the box also pushed as a clip so a
# too-wide string does not paint outside it. Pairs with gfx_clip_pop.
FN ui_text_center
    PROLOGUE 32
    mov rbx, rdi
    mov r12d, esi
    mov r13d, edx
    mov r14d, ecx
    mov [rsp], r8d
    mov r15, r9
    mov eax, [rbp + 16]
    mov [rsp + 4], eax
    mov edi, r12d
    mov esi, r13d
    mov edx, r14d
    mov ecx, [rsp]
    call gfx_clip_push
    mov rdi, r15
    call strlen
    mov [rsp + 8], rax
    mov rdi, rbx
    mov rsi, r15
    mov rdx, rax
    call text_width
    mov esi, r14d
    sub esi, eax
    sar esi, 1
    add esi, r12d
    mov rdi, rbx
    mov edx, r13d
    mov ecx, [rsp]
    mov r8, r15
    mov r9, [rsp + 8]
    mov eax, [rsp + 4]
    push rax
    push rax
    call ui_text_v
    add rsp, 16
    mov [rsp + 16], eax
    call gfx_clip_pop
    mov eax, [rsp + 16]
    EPILOGUE

    M r8d, MI_12
    M r9d, MI_4
    M eax, MI_RADIUS
    add eax, [rip + g_mt + 4*MI_2]
    push rax
    push rax
    call ui_card_shadow
    add rsp, 16
    EPILOGUE

# ui_card_shadow(x=rdi, y=esi, w=edx, h=ecx, spread=r8d, drop=r9d,
#                radius at [rbp+16], a 7th argument on the stack)
# A popup card. The shadow is a series of rounded rects that expand around
# the body, from the body outline out to spread pixels: each one is filled
# with the same tiny alpha, so they stack up and the shade grows densest
# right at the card and fades with every MI_2 px step outward. drop is how
# far the stack is pushed below the card. For dark and light themes the
# shadow alpha differs slightly (0x07 vs 0x04 per layer). The body is then
# a gfx_frame in the border color, inside a popup-filled rounded rect with
# the given corner radius; spread, drop and radius all come from the
# caller.
FN ui_card_shadow
    PROLOGUE 16
    mov r12d, edi
    mov r13d, esi
    mov r14d, edx
    mov r15d, ecx
    mov [rsp], r9d
    mov eax, [rbp + 16]
    mov [rsp + 4], eax
    # shadow: a few expanding translucent rounded rects
    mov ebx, r8d
.Lcard_sh:
    test ebx, ebx
    jle .Lcard_body
    mov edi, r12d
    sub edi, ebx
    mov esi, r13d
    sub esi, ebx
    add esi, [rsp]
    lea edx, [r14 + rbx*2]
    lea ecx, [r15 + rbx*2]
    mov r8d, [rsp + 4]          # shadow corners grow with the spread, from the body's
    sub r8d, [rip + g_mt + 4*MI_2]
    add r8d, ebx
    mov r9d, 0x07000000
    cmp dword ptr [rip + g_theme_dark], 0
    jne 1f
    mov r9d, 0x04000000
1:  call gfx_round_rect
    M eax, MI_2
    sub ebx, eax
    jg .Lcard_sh
.Lcard_body:
    mov edi, r12d
    mov esi, r13d
    mov edx, r14d
    mov ecx, r15d
    mov r8d, [rsp + 4]
    COLOR r9d, T_BORDER
    COLOR eax, T_POPUP
    push rax
    push rax
    call gfx_frame
    add rsp, 16
    EPILOGUE

# ui_toggle(id=edi, x=esi, y=edx, on=ecx) -> eax 1 if the switch was clicked
# A 34x20 style toggle: a track (rounded rect, border color off, accent
# on) and a knob inset MI_3, which slides right by MI_14 when on and is
# white (accent foreground color when on). Reuses ui_btn for hit testing
# and returns its UB_PRESS bit shifted down to bit 0.
FN ui_toggle
    PROLOGUE 16
    mov ebx, edi
    mov r12d, esi
    mov r13d, edx
    mov r14d, ecx
    M r15d, MI_20
    mov edi, ebx
    mov esi, r12d
    mov edx, r13d
    mov ecx, r15d
    add ecx, [rip + g_mt + 4*MI_14]
    mov r8d, r15d
    call ui_btn
    mov [rsp], eax
    # track
    COLOR r9d, T_BORDER
    test r14d, r14d
    jz 1f
    COLOR r9d, T_ACCENT
1:  mov edi, r12d
    mov esi, r13d
    mov edx, r15d
    add edx, [rip + g_mt + 4*MI_14]
    mov ecx, r15d
    mov r8d, r15d
    shr r8d, 1
    call gfx_round_rect
    # knob: white, or the text-on-accent color when on
    M eax, MI_3
    mov edi, r12d
    add edi, eax
    mov r9d, 0xffffffff
    test r14d, r14d
    jz 2f
    add edi, [rip + g_mt + 4*MI_14]
    COLOR r9d, T_ACCENT_FG
2:  lea esi, [r13 + rax]
    mov edx, r15d
    sub edx, eax
    sub edx, eax
    mov ecx, edx
    mov r8d, edx
    shr r8d, 1
    call gfx_round_rect
    mov eax, [rsp]
    and eax, UB_PRESS
    shr eax, 1
    EPILOGUE

# ui_scrollbar(id=rdi, x=esi, y=edx, w=ecx, h=r8d, offset=r9 (i32 px),
#              content at [rbp+16], view at [rbp+24], stack args)
# A vertical scrollbar, drawing its own thumb and handling the drag, for
# content taller than the view. The thumb's size and place come straight
# from the ratios (with 64-bit intermediates so huge text offsets don't
# overflow 32 bits); interactions target the whole track, whether a press
# lands on the thumb (grabbing where it landed) or elsewhere (the thumb
# jumps so that spot is centered). While held, offset follows the pointer,
# clamped to content - view, and the frame is marked dirty. The thumb itself
# is drawn through sb_thumb (scroll-flash state below). Cursor rule: arrow
# over this scrollbar but not when another widget holds the drag (sb_cursor).
FN ui_scrollbar
    PROLOGUE 48
    mov [rsp], edi
    mov [rsp + 4], esi
    mov [rsp + 8], edx
    mov [rsp + 12], ecx
    mov [rsp + 16], r8d
    mov r15, r9
    mov r12d, [rbp + 16]        # content
    mov r13d, [rbp + 24]        # view
    cmp r12d, r13d
    jle .Lsb_ret
    # thumb size = max(h * view / content, 24)
    mov eax, [rsp + 16]
    imul eax, r13d
    cdq
    idiv r12d
    M ecx, MI_24
    cmp eax, ecx
    cmovl eax, ecx
    mov r14d, eax               # thumb h
    # thumb y = y + (h - thumb) * off / (content - view)
    mov eax, [rsp + 16]
    sub eax, r14d
    movsxd rax, eax
    mov ecx, [r15]
    movsxd rcx, ecx
    imul rax, rcx               # 64 bits: a long text's offset times the track overflows 32
    mov ecx, r12d
    sub ecx, r13d
    movsxd rcx, ecx
    cqo
    idiv rcx
    add eax, [rsp + 8]
    mov ebx, eax                # thumb y
    # interaction on the whole track
    mov edi, [rsp]
    mov esi, [rsp + 4]
    mov edx, [rsp + 8]
    mov ecx, [rsp + 12]
    mov r8d, [rsp + 16]
    cmp dword ptr [rip + g_block], 0
    jne .Lsb_blocked
    call ui_btn
    jmp .Lsb_input_ready
.Lsb_blocked:
    xor eax, eax
.Lsb_input_ready:
    mov [rsp + 20], eax
    mov edi, eax
    call sb_cursor
    mov eax, [rsp + 20]
    test eax, UB_PRESS
    jz 1f
    # grab offset inside thumb (or jump so the thumb centers on the mouse)
    mov eax, [rip + g_my]
    sub eax, ebx
    js 2f
    cmp eax, r14d
    jl 3f
2:  mov eax, r14d
    shr eax, 1
3:  mov [rip + grab_dy], eax
1:  test dword ptr [rsp + 20], UB_HELD
    jz 4f
    # offset = (my - grab - y) * (content - view) / (h - thumb)
    mov eax, [rip + g_my]
    sub eax, [rip + grab_dy]
    sub eax, [rsp + 8]
    movsxd rax, eax
    mov ecx, r12d
    sub ecx, r13d
    movsxd rcx, ecx
    imul rax, rcx               # 64 bits, as for the thumb position above
    mov ecx, [rsp + 16]
    sub ecx, r14d
    jle 4f
    movsxd rcx, ecx
    cqo
    idiv rcx
    test rax, rax
    jns 5f
    xor eax, eax
5:  mov ecx, r12d
    sub ecx, r13d
    movsxd rcx, ecx
    cmp rax, rcx
    cmovg rax, rcx
    mov [r15], eax
    mov dword ptr [rip + g_dirty], 1
4:  mov edi, [rsp]
    mov rsi, r15
    mov edx, [rsp + 20]
    call sb_thumb
    test eax, eax
    jz .Lsb_ret
    mov r9d, edx
    mov ecx, [rsp + 12]
    mov edx, eax
    mov edi, [rsp + 4]
    add edi, ecx
    sub edi, eax
    sub edi, [rip + g_mt + 4*MI_3]
    mov esi, ebx
    mov ecx, r14d
    mov r8d, eax
    shr r8d, 1
    call gfx_round_rect
.Lsb_ret:
    EPILOGUE

# ui_hscrollbar(id=rdi, x=esi, y=edx, w=ecx, h=r8d, offset=r9 (i32 px),
#               content at [rbp+16], view at [rbp+24], stack args)
# The same widget mirrored to the x axis: thumb at the bottom of the track,
# width from the ratios, drag maps x to offset, everything else identical
# to ui_scrollbar above.
FN ui_hscrollbar
    PROLOGUE 48
    mov [rsp], edi
    mov [rsp + 4], esi
    mov [rsp + 8], edx
    mov [rsp + 12], ecx
    mov [rsp + 16], r8d
    mov r15, r9
    mov r12d, [rbp + 16]        # content
    mov r13d, [rbp + 24]        # view
    cmp r12d, r13d
    jle .Lhs_ret
    # thumb width = max(w * view / content, 24)
    mov eax, [rsp + 12]
    imul eax, r13d
    cdq
    idiv r12d
    M ecx, MI_24
    cmp eax, ecx
    cmovl eax, ecx
    mov r14d, eax               # thumb w
    # thumb x = x + (w - thumb) * off / (content - view)
    mov eax, [rsp + 12]
    sub eax, r14d
    movsxd rax, eax
    mov ecx, [r15]
    movsxd rcx, ecx
    imul rax, rcx               # 64 bits: a long text's offset times the track overflows 32
    mov ecx, r12d
    sub ecx, r13d
    movsxd rcx, ecx
    cqo
    idiv rcx
    add eax, [rsp + 4]
    mov ebx, eax                # thumb x
    # interaction on the whole track
    xor eax, eax
    cmp dword ptr [rip + g_block], 0
    jne 0f
    mov edi, [rsp]
    mov esi, [rsp + 4]
    mov edx, [rsp + 8]
    mov ecx, [rsp + 12]
    mov r8d, [rsp + 16]
    call ui_btn
0:  mov [rsp + 20], eax
    mov edi, eax
    call sb_cursor
    mov eax, [rsp + 20]
    test eax, UB_PRESS
    jz 1f
    # grab offset inside thumb (or jump so the thumb centers on the mouse)
    mov eax, [rip + g_mx]
    sub eax, ebx
    js 2f
    cmp eax, r14d
    jl 3f
2:  mov eax, r14d
    shr eax, 1
3:  mov [rip + grab_dx], eax
1:  test dword ptr [rsp + 20], UB_HELD
    jz 4f
    # offset = (mx - grab - x) * (content - view) / (w - thumb)
    mov eax, [rip + g_mx]
    sub eax, [rip + grab_dx]
    sub eax, [rsp + 4]
    movsxd rax, eax
    mov ecx, r12d
    sub ecx, r13d
    movsxd rcx, ecx
    imul rax, rcx               # 64 bits, as for the thumb position above
    mov ecx, [rsp + 12]
    sub ecx, r14d
    jle 4f
    movsxd rcx, ecx
    cqo
    idiv rcx
    test rax, rax
    jns 5f
    xor eax, eax
5:  mov ecx, r12d
    sub ecx, r13d
    movsxd rcx, ecx
    cmp rax, rcx
    cmovg rax, rcx
    mov [r15], eax
    mov dword ptr [rip + g_dirty], 1
4:  mov edi, [rsp]
    mov rsi, r15
    mov edx, [rsp + 20]
    call sb_thumb
    test eax, eax
    jz .Lhs_ret
    mov r9d, edx
    mov ecx, eax                # thickness
    mov edi, ebx
    mov esi, [rsp + 8]
    add esi, [rsp + 16]
    sub esi, eax
    sub esi, [rip + g_mt + 4*MI_3]
    mov edx, r14d
    mov r8d, eax
    shr r8d, 1
    call gfx_round_rect
.Lhs_ret:
    EPILOGUE

# sb_tick(): expire scroll-flash windows whose show-until time has passed
# (the ones sb_thumb armed), marking the frame dirty when one goes away so
# the thumb fades out on time even with no other activity.
FN sb_tick
    push rbx
    push r12
    sub rsp, 8
    call time_ms
    mov r12, rax
    lea rbx, [rip + sb_flash]
    mov ecx, SB_MAX
1:  mov rax, [rbx + 16]
    test rax, rax
    jz 2f
    cmp r12, rax
    jb 2f
    mov qword ptr [rbx + 16], 0
    mov dword ptr [rip + g_dirty], 1
2:  add rbx, 24
    dec ecx
    jnz 1b
    add rsp, 8
    pop r12
    pop rbx
    ret

# sb_timeout() -> eax ms until the nearest scroll-flash window would close,
# or -1 when none is armed. Lets the event loop time its next wakeup so a
# fading thumb is not stuck waiting for input.
FN sb_timeout
    push rbx
    push r12
    sub rsp, 8
    call time_ms
    mov r12, rax
    lea rbx, [rip + sb_flash]
    mov ecx, SB_MAX
    mov edx, -1
1:  mov rax, [rbx + 16]
    test rax, rax
    jz 2f
    sub rax, r12
    jle 2f                          # already due: sb_tick clears it
    cmp edx, -1
    je 3f
    cmp eax, edx
    jge 2f
3:  mov edx, eax
2:  add rbx, 24
    dec ecx
    jnz 1b
    mov eax, edx
    add rsp, 8
    pop r12
    pop rbx
    ret

# sb_cursor(bits): the arrow over a scrollbar or while its thumb is
# dragged, but not over another widget's drag
sb_cursor:
    test edi, UB_HELD
    jnz 1f
    test edi, UB_HOVER
    jz 2f
    cmp dword ptr [rip + g_active], 0
    jne 2f
1:  mov dword ptr [rip + g_cursor], CUR_ARROW
2:  ret

# sb_thumb(id, *offset, bits) -> eax thumb thickness (0: none), edx its
# color. The full thumb while hovered or dragged, or for SB_SHOW_MS after
# the offset last moved; otherwise none, or a faint thin one when
# scrollbars do not auto-hide. Each scrollbar id keeps its own sb_flash
# slot (an offset on the caller's stack moves with its depth, so the id is
# the key).
sb_thumb:
    PROLOGUE
    mov ebx, edx
    mov r12, rsi
    mov r14d, edi
    lea r13, [rip + sb_flash]
    xor ecx, ecx
1:  cmp [r13], r14
    je 3f
    cmp qword ptr [r13], 0
    jne 2f
    mov [r13], r14
    mov eax, [r12]                  # seed, don't flash, on first sight
    mov [r13 + 8], eax
    jmp 3f
2:  add r13, 24
    inc ecx
    cmp ecx, SB_MAX
    jl 1b
    jmp 5f                          # table full: keep the thumb shown
3:  call time_ms
    mov ecx, [r12]
    cmp ecx, [r13 + 8]
    je 4f
    mov [r13 + 8], ecx
    lea rdx, [rax + SB_SHOW_MS]
    mov [r13 + 16], rdx
4:  test ebx, UB_HOVER | UB_HELD
    jnz 5f
    cmp rax, [r13 + 16]
    jl 5f
    xor eax, eax
    cmp dword ptr [rip + cfg_autohide_scrollbars], 0
    jne 9f
    COLOR edx, T_SCROLLBAR
    and edx, 0x00ffffff
    or edx, 0xa0000000
    M eax, MI_4
    jmp 9f
5:  COLOR edx, T_SCROLLBAR
    M eax, MI_6
9:  EPILOGUE

.section .rodata
.p2align 2
f_100: .float 100.0
f_min_scale: .float 0.5
f_big: .float 1.55
f_huge: .float 3.4
# logical sizes for MI_* indices
metric_values:
    .long 1, 2, 3, 4, 6, 8, 10, 12, 14, 16, 20, 24, 28, 32, 40, 48
    .long 40, 36, 26, 28, 16, 6, 64, 5
.globl empty_str
empty_str: .byte 0
.data
g_mx: .long -10000
g_my: .long -10000
.bss
grab_dy: .long 0
grab_dx: .long 0
.p2align 3
.data
