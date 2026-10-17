# unn: shared macros and constants, included by every source file.
# Defines: linux x86-64 syscall and flag numbers, the FN/PROLOGUE/EPILOGUE
# function-frame helpers, the STRUCT/F/ENDSTRUCT offset macros (see below),
# and the layouts and enums all of unn shares: theme slots, ui metrics,
# documents, syntax grammars, terminal cells ("unn's cell format"), the
# library side of the libghostty-vt bridge, agents, and so on. Constants
# here are offsets, not variables: globals live in the file that uses them.
# This is the terminal-only build: the document, grammar, agent, updater
# and vim-mode sets below no longer have readers, but their constants stay
# defined.
.intel_syntax noprefix

# ---- linux x86-64 syscall numbers (nr in eax, args rdi rsi rdx r10 r8 r9;
# SYS + XSYS below issue one) ----
.equ SYS_read, 0
.equ SYS_write, 1
.equ SYS_open, 2
.equ SYS_close, 3
.equ SYS_fstat, 5
.equ SYS_lstat, 6
.equ SYS_poll, 7
.equ SYS_lseek, 8
.equ SYS_mmap, 9
.equ SYS_munmap, 11
.equ SYS_rt_sigaction, 13
.equ SYS_ioctl, 16
.equ SYS_access, 21
.equ SYS_mremap, 25
.equ SYS_shmget, 29
.equ SYS_shmat, 30
.equ SYS_shmctl, 31
.equ SYS_dup2, 33
.equ SYS_getpid, 39
.equ SYS_socket, 41
.equ SYS_connect, 42
.equ SYS_accept, 43
.equ SYS_sendmsg, 46
.equ SYS_recvmsg, 47
.equ SYS_bind, 49
.equ SYS_listen, 50
.equ SYS_vfork, 58
.equ SYS_execve, 59
.equ SYS_exit, 60
.equ SYS_wait4, 61
.equ SYS_kill, 62
.equ SYS_uname, 63
.equ SYS_fcntl, 72
.equ SYS_fsync, 74
.equ SYS_ftruncate, 77
.equ SYS_getcwd, 79
.equ SYS_chdir, 80
.equ SYS_rename, 82
.equ SYS_mkdir, 83
.equ SYS_unlink, 87
.equ SYS_readlink, 89
.equ SYS_chmod, 90
.equ SYS_fchmod, 91
.equ SYS_setsid, 112
.equ SYS_shmdt, 67
.equ SYS_getdents64, 217
.equ SYS_clock_gettime, 228
.equ SYS_exit_group, 231
.equ SYS_inotify_add_watch, 254
.equ SYS_inotify_rm_watch, 255
.equ SYS_openat, 257
.equ SYS_timerfd_create, 283
.equ SYS_timerfd_settime, 286
.equ SYS_accept4, 288
.equ SYS_pipe2, 293
.equ SYS_inotify_init1, 294
.equ SYS_memfd_create, 319
.equ SYS_close_range, 436

# ---- open(2) flags ----
.equ O_RDONLY, 0
.equ O_WRONLY, 1
.equ O_RDWR, 2
.equ O_CREAT, 0x40
.equ O_EXCL, 0x80
.equ O_NOCTTY, 0x100
.equ O_TRUNC, 0x200
.equ O_APPEND, 0x400
.equ O_NONBLOCK, 0x800
.equ O_DIRECTORY, 0x10000
.equ O_CLOEXEC, 0x80000

# mmap(2), mremap(2) flags
.equ PROT_READ, 1
.equ PROT_WRITE, 2
.equ MAP_SHARED, 1
.equ MAP_PRIVATE, 2
.equ MAP_ANONYMOUS, 0x20
.equ MREMAP_MAYMOVE, 1

# ---- socket, sendmsg and flag constants (SCM_RIGHTS passes fds over a unix socket,
# which is how wayland hands its shared memory buffer across) ----
.equ AF_UNIX, 1
.equ SOCK_STREAM, 1
.equ SOCK_NONBLOCK, 0x800
.equ SOCK_CLOEXEC, 0x80000
.equ SOL_SOCKET, 1
.equ SCM_RIGHTS, 1
.equ MSG_DONTWAIT, 0x40
.equ MSG_NOSIGNAL, 0x4000

# poll(2) result / request reuse bits
.equ POLLIN, 1
.equ POLLOUT, 4
.equ POLLERR, 8
.equ POLLHUP, 16

.equ CLOCK_REALTIME, 0
.equ CLOCK_MONOTONIC, 1

.equ IN_MODIFY, 0x2
.equ IN_CLOSE_WRITE, 0x8
.equ IN_MOVED_FROM, 0x40
.equ IN_MOVED_TO, 0x80
.equ IN_CREATE, 0x100
.equ IN_DELETE, 0x200
.equ IN_MOVE_SELF, 0x800
.equ IN_IGNORED, 0x8000
.equ IN_ONLYDIR, 0x1000000
.equ IN_NONBLOCK, 0x800
.equ IN_CLOEXEC, 0x80000

# errno values (negative kernel returns) and process/state odds and ends
.equ EAGAIN, 11
.equ EIO, 5
.equ WNOHANG, 1
.equ SIGHUP, 1
.equ SIGKILL, 9
.equ EINTR, 4

# ---- function helpers ----
# FN name opens a .text function of the given name: global, 16-byte aligned,
# defined right after the macro call.
.macro FN name
    .text
    .globl \name
    .type \name, @function
    .p2align 4
\name:
.endm

# Saves rbp, rbx and r12-r15 (six pushes), then reserves 8 + frame bytes:
# the extra 8 keeps rsp 16-aligned, so frame must be a multiple of 16.
.macro PROLOGUE frame=0
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 8 + \frame
.endm

# PROLOGUE plus a forced 16-byte alignment. unn's own helpers only touch memory
# (and spill with unaligned moves) so they tolerate a caller that didn't keep
# the ABI's stack alignment, but libghostty is compiled and may use aligned SSE
# moves on its own frame: the frame pointer it derives from a call is rsp - 8,
# so a call made with rsp off by 8 faults there. Every function that reaches
# libghostty therefore aligns first, whatever the caller did.
.macro PROLOGUE_ALIGNED frame=0
    PROLOGUE \frame
    and rsp, -16
.endm

# Unwinds a PROLOGUE/PROLOGUE_ALIGNED frame from rbp: frame size and any
# extra alignment both drop out.
.macro EPILOGUE
    lea rsp, [rbp - 40]
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    pop rbp
    ret
.endm

# issue a syscall: number in eax, register args already loaded.
# XSYS is the same but the number was loaded some other way (constant computed
# on the fly). Kernel clobbers rcx and r11.
.macro SYS num
    mov eax, \num
    XSYS
.endm

.macro XSYS
    syscall
.endm

# ---- struct layout macros ----
# STRUCT resets the running offset; F name, size defines `name` = the offset of
# the next field and advances; ENDSTRUCT name defines `name` = the struct size.
# Layouts transcribed from the C structs they shadow (type sizes in bytes,
# alignment as written); put the fields in memory order.
.macro STRUCT
    .set __so, 0
.endm
.macro F name, size
    .equ \name, __so
    .set __so, __so + \size
.endm
.macro ENDSTRUCT name
    .equ \name, __so
.endm

# zero-terminated string literal in .rodata, labels = name, and back to .text
.macro CSTR name, text
    .section .rodata
\name: .asciz "\text"
    .text
.endm

# ---- shared structs ----

# growable byte buffer: ptr of cap bytes, len used, cap total. len bytes are
# always NUL-terminated so the buffer can be read as a string while growing.
STRUCT
F SB_ptr, 8
F SB_len, 8             # bytes written so far
F SB_cap, 8
ENDSTRUCT SB_SIZE

# generic growable array of fixed-size items (same shape as SB, items instead
# of bytes; vec_push in mem.s fills it)
STRUCT
F VEC_ptr, 8
F VEC_len, 8            # number of items
F VEC_cap, 8            # capacity in items
ENDSTRUCT VEC_SIZE

# rectangle (i32), x/y the top-left, w/h its size
STRUCT
F R_x, 4
F R_y, 4
F R_w, 4
F R_h, 4
ENDSTRUCT RECT_SIZE

# keysym values as wayland's xkb gives them (the 0xffxx range, ISO_Left_Tab's
# 0xfe20 aside); printable keys arrive as their unicode codepoint instead
.equ KEY_BACKSPACE, 0xff08
.equ KEY_TAB, 0xff09
.equ KEY_RETURN, 0xff0d
.equ KEY_ESCAPE, 0xff1b
.equ KEY_HOME, 0xff50
.equ KEY_LEFT, 0xff51
.equ KEY_UP, 0xff52
.equ KEY_RIGHT, 0xff53
.equ KEY_DOWN, 0xff54
.equ KEY_PAGEUP, 0xff55
.equ KEY_PAGEDOWN, 0xff56
.equ KEY_END, 0xff57
.equ KEY_INSERT, 0xff63
.equ KEY_KP_ENTER, 0xff8d
.equ KEY_F1, 0xffbe
.equ KEY_SHIFT_L, 0xffe1
.equ KEY_SUPER_R, 0xffec
.equ KEY_ISO_LEFT_TAB, 0xfe20
.equ KEY_DELETE, 0xffff

# modifier bitmask the key handler builds (see app/keys.s for how they map from
# xkb state)
.equ MOD_SHIFT, 1
.equ MOD_CTRL, 4
.equ MOD_ALT, 8
.equ MOD_SUPER, 64

# mouse buttons as wayland reports them (button numbers)
.equ BTN_LEFT, 1
.equ BTN_MIDDLE, 2
.equ BTN_RIGHT, 3

# cursor shapes (g_cursor / P_cursor take these; xcursor_load turns one into an image)
.equ CUR_DEFAULT, 0
.equ CUR_TEXT, 1
.equ CUR_POINTER, 2
.equ CUR_EW, 3
.equ CUR_NS, 4
.equ CUR_NWSE, 5
.equ CUR_NESW, 6
.equ CUR_ARROW, 7               # the arrow shape again, but claimed: unlike CUR_DEFAULT it is not "unset"

# cursor image as loaded (xcursor_load / xcursor_builtin); the struct is owned
# by the caller and handed to the compositor as a shared memory buffer.
# Built-ins get one allocation behind both XC_file and XC_pixels: free it once
STRUCT
F XC_file, 8            # the image file's bytes (mem_free when done)
F XC_pixels, 8          # premultiplied ARGB, w * h pixels (mem_free when done)
F XC_w, 4               # pixels
F XC_h, 4
F XC_xhot, 4            # hotspot position: the pixel where the pointer clicks
F XC_yhot, 4
ENDSTRUCT XC_SIZE

# ---- big-endian loads (font and other file tables; load little-endian, rotate,
# and sign-extend where wanted) ----
.macro LDBE16 r32, r16, mem
    movzx \r32, word ptr \mem
    rol \r16, 8
.endm
.macro LDBE16S r32, r16, mem
    movzx \r32, word ptr \mem
    rol \r16, 8
    movsx \r32, \r16
.endm
.macro LDBE32 r32, mem
    mov \r32, dword ptr \mem
    bswap \r32
.endm

# ---- graphics ----
# drawable surface with a clip rectangle
STRUCT
F CV_pixels, 8
F CV_w, 4               # in pixels
F CV_h, 4
F CV_stride, 4          # pixels per row (rounding can make it wider than w)
F CV_cx0, 4             # only pixels of the clip rect [x0,x1) x [y0,y1) are touched
F CV_cy0, 4
F CV_cx1, 4
F CV_cy1, 4
F CV_pad, 4
ENDSTRUCT CV_SIZE

# cached glyph bitmap in the per-face glyph cache
STRUCT
F GL_key, 4             # codepoint + 1; 0 marks the slot empty
F GL_w, 2               # bitmap size in pixels
F GL_h, 2
F GL_left, 2            # bitmap's x offset from the pen
F GL_top, 2             # rows from the bitmap's top to the baseline
F GL_adv, 4             # advance to the next cell, 26.6 fixed point
F GL_bits, 8            # w * h alpha (coverage) bytes
ENDSTRUCT GL_SIZE

# parsed TrueType font, pointers into the loaded file image
STRUCT
F FONT_data, 8          # the whole file, kept alive while the font is used
F FONT_glyf, 8
F FONT_loca, 8
F FONT_hmtx, 8
F FONT_cmap, 8          # the (format-4 preferred) subtable actually used
F FONT_cmapfmt, 4
F FONT_upem, 4          # units per em, the font's design grid size
F FONT_localong, 4
F FONT_nglyphs, 4
F FONT_nhmetrics, 4
F FONT_ascent, 4
F FONT_descent, 4
F FONT_linegap, 4
ENDSTRUCT FONT_SIZE

# a font rasterized at one pixel size (raster.s renders it)
STRUCT
F FACE_font, 8
F FACE_scale, 4         # float, pixels per font unit
F FACE_px, 4            # requested size in px
F FACE_ascent, 4
F FACE_descent, 4
F FACE_lineh, 4
F FACE_cellw, 4         # advance of '0' in px (rounded), the cell width for tabs
F FACE_tab, 8           # open-probe GL* hash for glyphs the ascii array missed
F FACE_tabcap, 4        # buckets
F FACE_tabn, 4          # glyphs stored
F FACE_ascii, 1024      # fast path: 128 GL* pointers for cp < 128
F FACE_embolden, 4
F FACE_pad2, 4
ENDSTRUCT FACE_SIZE

# ---- event loop fd watchers (loop.s) ----
# handler runs for whichever of PW_events is ready in revents
STRUCT
F PW_fd, 4
F PW_events, 4          # POLLIN | POLLOUT | POLLERR | POLLHUP wanted
F PW_handler, 8         # handler(fd, revents, ctx); unlink the watch inside, loop_poll copes
F PW_ctx, 8
ENDSTRUCT PW_SIZE
.equ MAX_WATCH, 96

# ---- platform vtable (wayland plat/wayland.s or headless plat/headless.s):
# the app calls the window system only through these, filling its tab with
# functions at startup ----
STRUCT
F P_flush, 8            # () flush output the ui drew this frame
F P_timeout, 8          # () -> ms until the next platform task, -1 none
F P_tick, 8             # () once per loop pass
F P_draw, 8             # () render the window now if it can
F P_cursor, 8           # (shape CUR_*) set the mouse pointer image
F P_clip_set, 8         # (ptr, len) claim the clipboard with text
F P_clip_get, 8         # () ask for the clipboard; the answer comes back to app_on_paste
F P_move, 8             # () drag the window from the header press
F P_resize, 8           # (edges EDGE_*) interactive resize from an edge handle
F P_minimize, 8         # () iconify the window
F P_maximize, 8         # () toggle maximize
F P_title, 8            # (cstr) set the window title
F P_menu, 8             # (x, y) open the window menu at screen x, y
ENDSTRUCT PLAT_SIZE

# EDGE_* masks for P_resize's edges (wayland's wl_resize edge-drags); no caller
# opens a resize in this build, the values are kept for it
.equ EDGE_TOP, 1
.equ EDGE_BOTTOM, 2
.equ EDGE_LEFT, 4
.equ EDGE_RIGHT, 8

# invoke a platform vtable entry: PCALL P_draw does call [rip + g_plat + P_draw]
.macro PCALL fn
    call [rip + g_plat + \fn]
.endm

# ---- theme color slots ----
# g_theme is word T_COUNT of ARGB at [rip + g_theme + 4*slot]; COLOR r, slot loads one.
# T_SYN and beyond are ranges computed from the base enums.
.equ T_BG, 0
.equ T_FG, 1
.equ T_ACCENT, 2
.equ T_PANEL, 3
.equ T_TITLEBAR, 4
.equ T_BORDER, 5
.equ T_MUTED, 6
.equ T_LINENO, 7
.equ T_LINENO_ACTIVE, 8
.equ T_LINE_HL, 9
.equ T_SELECTION, 10
.equ T_CURSOR, 11
.equ T_HOVER, 12
.equ T_ACTIVE, 13
.equ T_POPUP, 14
.equ T_INPUT, 15
.equ T_SCROLLBAR, 16
.equ T_STATUS, 17
.equ T_TAB, 18
.equ T_TAB_ACTIVE, 19
.equ T_ERROR, 20
.equ T_WARNING, 21
.equ T_SUCCESS, 22
.equ T_MATCH, 23
.equ T_GUIDE, 24
.equ T_ACCENT_FG, 25
.equ T_PANEL_FG, 26
# syntax color slots: color for class i is T_SYN + i
.equ T_SYN, 27              # + syntax class below
# syntax classes (tokens the highlighter can label a span with)
.equ C_TEXT, 0
.equ C_KEYWORD, 1
.equ C_TYPE, 2
.equ C_FUNCTION, 3
.equ C_STRING, 4
.equ C_NUMBER, 5
.equ C_COMMENT, 6
.equ C_CONSTANT, 7
.equ C_OPERATOR, 8
.equ C_PUNCT, 9
.equ C_PREPROC, 10
.equ C_VARIABLE, 11
.equ C_BUILTIN, 12
.equ C_ATTRIBUTE, 13
.equ C_TAG, 14
.equ C_HEADING, 15
.equ C_INSERTED, 16
.equ C_DELETED, 17
.equ C_ESCAPE, 18
.equ C_LINK, 19
.equ C_COUNT, 20
# the last chunk of the theme: slots for the 16 standard terminal colors
# (T_TERM + 0..15), then git gutter and file-icon colors
.equ T_TERM, T_SYN + C_COUNT    # 16 terminal colors follow
.equ T_GIT_ADD, T_TERM + 16
.equ T_GIT_MOD, T_TERM + 17
.equ T_GIT_DEL, T_TERM + 18
.equ T_ICON, T_TERM + 19        # file icons: one color each red orange yellow green blue purple pink cyan grey white
.equ T_COUNT, T_ICON + 10

# load a theme color (a word of ARGB) into reg
.macro COLOR reg, slot
    mov \reg, [rip + g_theme + 4*(\slot)]
.endm

# ---- updates (the old self-update flow; no updater in this build) ----
.equ UP_IDLE, 0
.equ UP_AVAILABLE, 1            # a newer release to install
.equ UP_INSTALLING, 2
.equ UP_READY, 3                # installed; a restart runs it

# ---- document ----
# An open document: its text as a gap buffer, the line index for that text,
# cached syntax and git state, undo chains, and view state (scroll, cursor).
# The fields below appear in memory order so offsets are stable.
STRUCT
F DOC_buf, 8            # text bytes, a gap buffer: cap total
F DOC_cap, 8
F DOC_gs, 8             # gap start, the cursor side of the hole
F DOC_ge, 8             # gap end
F DOC_lines, 8          # u64 line start offsets into buf
F DOC_nlines, 8
F DOC_lcap, 8
F DOC_states, 8         # u32 syntax state at line start
F DOC_svalid, 8         # states valid for lines < svalid
F DOC_path, 8           # absolute path or 0 when it has no file
F DOC_name, 8           # display name (tab title)
F DOC_lang, 8           # grammar or 0
F DOC_undo, VEC_SIZE    # UR records
F DOC_redo, VEC_SIZE
F DOC_cur, 8            # cursor, a byte offset into buf
F DOC_anchor, 8         # selection anchor (cur without anchor = plain caret)
F DOC_prefx, 8          # preferred column for vertical motion, -1 = none
F DOC_scrolly, 8        # 1/256 lines
F DOC_scrollx, 8        # pixels
F DOC_wtop, 8           # wrapped view: line that DOC_woff belongs to
F DOC_woff, 8           # wrapped view: 1/256 rows into that line (used while scrolly is on DOC_wtop)
F DOC_group, 8
F DOC_lastedit, 8
F DOC_lastkind, 8
F DOC_savepoint, 8
F DOC_crlf, 4
F DOC_flags, 4
F DOC_mtime, 8
F DOC_version, 8
F DOC_sold, 8           # syntax states were valid below this line before the last edits
F DOC_ehi, 8            # highest line touched by edits since then
F DOC_ghash, 8          # git: hashes of its lines
F DOC_gnl, 8            # git: their count
F DOC_gmarks, 8         # git: GM_* per line
F DOC_gmcap, 8
F DOC_gver, 8           # git: DOC_version the marks were made for
F DOC_gstate, 4         # GS_*
F DOC_gseq, 4           # git: request number; answers to older requests are dropped
F DOC_diff, 8           # diff view: DV* with the kind and numbers of each line
F DOC_lhash, 8          # hash of each line (for git marks), 0 = not known yet
F DOC_img, 8            # image view of a TAB_IMAGE document, or 0
F DOC_wd, 8             # directory watch descriptor, -1 when unavailable
F DOC_reload_at, 8      # external writes coalesce before a reload, 0 when none is pending
F DOC_disk_seen, 8      # last external stamp handled
F DOC_disk_until, 8     # external reload highlight fades until this time
F DOC_disk_lo, 8        # first changed line in the reloaded text
F DOC_wcols, 8          # columns of the widest line
F DOC_wkey, 8           # the text and tab width they were measured for, 0 = not yet
F DOC_disk_hi, 8        # line past the changed range (deletions highlight their surviving neighbor)
F DOC_real, 8           # a symlink's file: its path (owned) and name, and its folder's watch, or 0
F DOC_rname, 8
F DOC_wd2, 8
F DOC_hops, 8           # the symlinks it leads through before that file, or 0
ENDSTRUCT DOC_SIZE

.equ DISK_FADE_MS, 800
.equ DISK_FRAME_MS, 50

# DOC_flags
.equ DF_GROUP, 1
.equ DF_READONLY, 2              # diff views
.equ DF_EOL, 4                   # the text ended in a newline when read or saved: no line after it
.equ DF_DISK_CHANGED, 8          # external contents differ and unsaved edits were kept
.equ DF_REVEAL, 16               # its cursor was placed while it was not shown: in view when next drawn
.equ DF_CENTER, 32               # with DF_REVEAL: that reveal puts the cursor's line in the middle

# READONLY_RET: return 0 at once when the document is read-only: g_doc, or the
# one in reg.
.macro READONLY_RET reg=0
.ifc \reg,0
    push rax
    mov rax, [rip + g_doc]
    test rax, rax
    jz .Lro\@
    test dword ptr [rax + DOC_flags], DF_READONLY
    pop rax
    jz .Lro2\@
    xor eax, eax
    ret
.Lro\@:
    pop rax
.Lro2\@:
.else
    test dword ptr [\reg + DOC_flags], DF_READONLY
    jz .Lro\@
    xor eax, eax
    ret
.Lro\@:
.endif
.endm

# diff view record a document carries in DOC_diff when it shows a commit or the
# work tree instead of file text
STRUCT
F DV_lines, 8           # DL per line
F DV_n, 8
F DV_name, 8            # tab title
F DV_rev, 8             # commit, or 0 for the work tree
F DV_path, 8            # path in the work tree
F DV_maxno, 4           # largest line number
F DV_pad, 4
ENDSTRUCT DV_SIZE
# DL: figures for one line of that view
STRUCT
F DL_kind, 4            # DK_*
F DL_old, 4             # line number before, 0 none
F DL_new, 4             # line number after, 0 none
ENDSTRUCT DL_SIZE
# DL_kind values: DK_INFO is a hunk header's explanatory line
.equ DK_CTX, 0
.equ DK_ADD, 1
.equ DK_DEL, 2
.equ DK_HUNK, 3
.equ DK_INFO, 4

# a changed file row in the history view
STRUCT
F GF_path, 8
F GF_code, 4
F GF_add, 4             # lines added, -1 binary, -2 unknown
F GF_del, 4             # lines deleted (same sentinels)
F GF_group, 4           # work tree: GG_*
ENDSTRUCT GF_SIZE
# GG_*: groups of the work tree's changes, in the order they are shown
.equ GG_MERGE, 1                # conflicts
.equ GG_STAGED, 2
.equ GG_CHANGES, 3              # not staged, untracked

# what HEAD is (g_git_head)
.equ HD_BRANCH, 0
.equ HD_DETACHED, 1
.equ HD_UNBORN, 2               # a branch without commits yet

# git drawing state of a document (DOC_gstate): asked, and answered how
.equ GS_NONE, 0
.equ GS_ASKED, 1
.equ GS_BASE, 2
.equ GS_NOBASE, 3
# GM_* flags: gutter marks for one line
.equ GM_ADD, 1
.equ GM_MOD, 2
.equ GM_DELUP, 4                # lines deleted above
.equ GM_DELDOWN, 8              # lines deleted below the last line

# undo record: what was edited, and where the cursor was after
STRUCT
F UR_kind, 8            # 1 insert, 2 delete
F UR_pos, 8             # byte offset of the edit
F UR_len, 8             # bytes inserted or removed
F UR_text, 8            # the inserted or removed bytes
F UR_group, 8           # edits of one action share a group and undo together
F UR_cur, 8             # cursor after the edit
F UR_anchor, 8          # anchor after it
ENDSTRUCT UR_SIZE

# edit kinds for grouping adjacent keystrokes (typed, backstepped, deleted) into
# one record's group
.equ EK_OTHER, 0
.equ EK_TYPE, 1
.equ EK_BACK, 2
.equ EK_DEL, 3

# ---- ui metrics (g_mt): scaled logical sizes in px, look them up with M ----
# MI_n means "n px at scale 1"; the specials are the title/tab/status/icon
# row heights and the corner radius
.equ MI_1, 0
.equ MI_2, 1
.equ MI_3, 2
.equ MI_4, 3
.equ MI_6, 4
.equ MI_8, 5
.equ MI_10, 6
.equ MI_12, 7
.equ MI_14, 8
.equ MI_16, 9
.equ MI_20, 10
.equ MI_24, 11
.equ MI_28, 12
.equ MI_32, 13
.equ MI_40, 14
.equ MI_48, 15
.equ MI_TITLE, 16
.equ MI_TAB, 17
.equ MI_STATUS, 18
.equ MI_ROW, 19
.equ MI_ICON, 20
.equ MI_RADIUS, 21
.equ MI_64, 22
.equ MI_5, 23
.equ MI_COUNT, 24
# load ui metric idx into reg
.macro M reg, idx
    mov \reg, [rip + g_mt + 4*(\idx)]
.endm

# ui_btn (ui/ui.s) result bits: the button state after a hit test and button
# event
.equ UB_HOVER, 1
.equ UB_PRESS, 2
.equ UB_CLICK, 4
.equ UB_HELD, 8
.equ UB_RPRESS, 16
.equ UB_DOUBLE, 32

# a one-line text field (the old text area extended it with more fields)
STRUCT
F TF_sb, SB_SIZE        # the text
F TF_cur, 8
F TF_anchor, 8
F TF_scroll, 4
F TF_id, 4
F TF_top, 4             # text area: the first visual row shown
F TF_width, 4           # text area: available text width in pixels
F TF_prefx, 4           # text area: preferred x for vertical motion, -1 = none
F TF_pad, 4
ENDSTRUCT TF_SIZE

# icons: IC_* are the built-in vector glyphs, IC_F_* the per-filetype icons
# generated from SVG by the removed tools/icons.py, all after the built-ins.
# No icon is drawn in this build; the slot numbers stay defined.
.equ IC_CHEV_R, 0
.equ IC_CHEV_D, 1
.equ IC_FOLDER, 2
.equ IC_FILE, 3
.equ IC_CLOSE, 4
.equ IC_SIDEBAR, 5
.equ IC_PANEL_R, 6
.equ IC_SLIDERS, 7
.equ IC_SEARCH, 8
.equ IC_SPARK, 9
.equ IC_MIN, 10
.equ IC_MAX, 11
.equ IC_RESTORE, 12
.equ IC_WCLOSE, 13
.equ IC_DOT, 14
.equ IC_PLUS, 15
.equ IC_CHECK, 16
.equ IC_TERMINAL, 17
.equ IC_BACK, 18
.equ IC_USER, 19
.equ IC_ARROW_DN, 20
.equ IC_REFRESH, 21
.equ IC_CHEV_UP, 22
.equ IC_CHEV_DN2, 23
.equ IC_CASE, 24
.equ IC_WORD, 25
.equ IC_RUNE, 26                # the app mark (Raido)
.equ IC_BRANCH, 27
.equ IC_ARROW_UP, 28
.equ IC_MINUS, 29
.equ IC_DISCARD, 30
.equ IC_FILE_PLUS, 31
.equ IC_FOLDER_PLUS, 32
# icons from SVG files (their loader is removed)
.equ IC_CLAUDE, 33
.equ IC_OPENAI, 34
.equ IC_GROK, 35
.equ IC_F_R, 36
.equ IC_F_APPLE, 37
.equ IC_F_ASM, 38
.equ IC_F_AUDIO, 39
.equ IC_F_BABEL, 40
.equ IC_F_BAZEL, 41
.equ IC_F_C, 42
.equ IC_F_C_SHARP, 43
.equ IC_F_CLOCK, 44
.equ IC_F_CLOJURE, 45
.equ IC_F_CODE, 46
.equ IC_F_CONFIG, 47
.equ IC_F_CPP, 48
.equ IC_F_CRYSTAL, 49
.equ IC_F_CSS, 50
.equ IC_F_CSV, 51
.equ IC_F_CU, 52
.equ IC_F_D, 53
.equ IC_F_DART, 54
.equ IC_F_DB, 55
.equ IC_F_DEFAULT, 56
.equ IC_F_DOCKER, 57
.equ IC_F_EDITORCONFIG, 58
.equ IC_F_EJS, 59
.equ IC_F_ELIXIR, 60
.equ IC_F_ELM, 61
.equ IC_F_ESLINT, 62
.equ IC_F_ETHEREUM, 63
.equ IC_F_F_SHARP, 64
.equ IC_F_FAVICON, 65
.equ IC_F_FONT, 66
.equ IC_F_GIT, 67
.equ IC_F_GO2, 68
.equ IC_F_GRADLE, 69
.equ IC_F_GRAILS, 70
.equ IC_F_GRAPHQL, 71
.equ IC_F_HAML, 72
.equ IC_F_HASKELL, 73
.equ IC_F_HAXE, 74
.equ IC_F_HEROKU, 75
.equ IC_F_HEX, 76
.equ IC_F_HTML, 77
.equ IC_F_HTML_ERB, 78
.equ IC_F_IGNORED, 79
.equ IC_F_ILLUSTRATOR, 80
.equ IC_F_IMAGE, 81
.equ IC_F_INFO, 82
.equ IC_F_JAVA, 83
.equ IC_F_JAVASCRIPT, 84
.equ IC_F_JENKINS, 85
.equ IC_F_JINJA, 86
.equ IC_F_JSON, 87
.equ IC_F_JULIA, 88
.equ IC_F_KOTLIN, 89
.equ IC_F_LESS, 90
.equ IC_F_LICENSE, 91
.equ IC_F_LIQUID, 92
.equ IC_F_LOCK, 93
.equ IC_F_LUA, 94
.equ IC_F_MAKEFILE, 95
.equ IC_F_MARKDOWN, 96
.equ IC_F_MAVEN, 97
.equ IC_F_MUSTACHE, 98
.equ IC_F_NIM, 99
.equ IC_F_NOTEBOOK, 100
.equ IC_F_NPM, 101
.equ IC_F_OCAML, 102
.equ IC_F_PDF, 103
.equ IC_F_PERL, 104
.equ IC_F_PHOTOSHOP, 105
.equ IC_F_PHP, 106
.equ IC_F_POWERSHELL, 107
.equ IC_F_PRISMA, 108
.equ IC_F_PROLOG, 109
.equ IC_F_PUG, 110
.equ IC_F_PUPPET, 111
.equ IC_F_PURESCRIPT, 112
.equ IC_F_PYTHON, 113
.equ IC_F_REACT, 114
.equ IC_F_RUBY, 115
.equ IC_F_RUST, 116
.equ IC_F_SASS, 117
.equ IC_F_SCALA, 118
.equ IC_F_SHELL, 119
.equ IC_F_SLIM, 120
.equ IC_F_SVELTE, 121
.equ IC_F_SVG, 122
.equ IC_F_SWIFT, 123
.equ IC_F_TERRAFORM, 124
.equ IC_F_TEX, 125
.equ IC_F_TODO, 126
.equ IC_F_TSCONFIG, 127
.equ IC_F_TWIG, 128
.equ IC_F_TYPESCRIPT, 129
.equ IC_F_VALA, 130
.equ IC_F_VIDEO, 131
.equ IC_F_VITE, 132
.equ IC_F_VUE, 133
.equ IC_F_WASM, 134
.equ IC_F_WAT, 135
.equ IC_F_WEBPACK, 136
.equ IC_F_WINDOWS, 137
.equ IC_F_WORD, 138
.equ IC_F_XLS, 139
.equ IC_F_XML, 140
.equ IC_F_YARN, 141
.equ IC_F_YML, 142
.equ IC_F_ZIG, 143
.equ IC_F_ZIP, 144
.equ IC_OPENCODE, 145
.equ IC_PIN, 146
.equ IC_COUNT, 147
# end of the icons from SVG files

# explorer header button ids (the explorer ui is gone in this build)
.equ ID_EXP_NEW, 0x3f00
.equ ID_EXP_REFRESH, 0x3f01
.equ ID_EXP_NEW_FOLDER, 0x3f03

# ---- images ----
# IMG_fmt is one of IMF_*; no image decoder runs in this build
.equ IMF_PNG, 1
.equ IMF_JPEG, 2
.equ IMF_GIF, 3
.equ IMF_BMP, 4
.equ IMF_ICO, 5
.equ IMF_QOI, 6
.equ IMF_PNM, 7
.equ IMF_TGA, 8
.equ IMG_MAXDIM, 32768
.equ IMG_MAXPX, 1 << 26

# decoded image
STRUCT
F IMG_px, 8             # premultiplied ARGB, w * h pixels (mem_alloc_try, mem_free when done)
F IMG_w, 4              # pixels
F IMG_h, 4
F IMG_fmt, 4            # IMF_*
F IMG_opaque, 4         # 1 when every pixel is opaque (fast path: no blending needed)
ENDSTRUCT IMG_SIZE

# ---- app ----
# tab kinds: TAB_doc points at a TAB of the named kind, except TAB_IMAGE whose
# DOC holds no text and carries the image in DOC_img instead
.equ TAB_DOC, 1
.equ TAB_SETTINGS, 2
.equ TAB_IMAGE, 3               # TAB_doc is a DOC without text; DOC_img holds the view
.equ TAB_GIT, 4
# a tab's payload
STRUCT
F TAB_kind, 8           # TAB_*
F TAB_doc, 8
F TAB_flags, 8          # TF_*
ENDSTRUCT TAB_SIZE
# TAB_flags
.equ TF_PIN, 1                  # pinned: the pinned tabs are the first ones in the strip

# where keyboard input goes (g_focus); only FOCUS_EDITOR and FOCUS_TERMINAL
# are used any more, the rest name surfaces the old ui had
        .equ FOCUS_EDITOR, 0
.equ FOCUS_PALETTE, 1
.equ FOCUS_FIND, 2
.equ FOCUS_EXPLORER, 3
.equ FOCUS_SETTINGS, 4
.equ FOCUS_DIALOG, 5
.equ FOCUS_AGENTS, 6
.equ FOCUS_PROMPT, 7
.equ FOCUS_TERMINAL, 8
.equ FOCUS_SCM, 9               # the commit message

# grammar: the syntax definition struct one language was highlighted with;
# the highlighter is gone in this build, so GR_*/GF_* have no readers
STRUCT
F GR_name, 8
F GR_files, 8           # space separated file name patterns
F GR_first, 8           # first-line prefixes (shebang)
F GR_icon, 8            # explorer icon: icon and color names
F GR_regions, VEC_SIZE  # REG items
F GR_lines, VEC_SIZE    # LR items: line prefix -> class
F GR_words, 8           # hash table of WORD
F GR_wcap, 8
F GR_wn, 8
F GR_comment, 8         # line comment token (for toggle comment)
F GR_commentlen, 8
F GR_flags, 8           # GF_*
F GR_identx, 32         # extra identifier chars
F GR_prefixes, 32       # chars that start variables ($) / attributes (@)
F GR_rstart, 256        # 1 for bytes that can start a region
F GR_wchar, 256         # 1 for identifier bytes
F GR_src, 8             # built-in text not parsed yet, or 0
F GR_srclen, 8
F GR_ficon, 8           # GR_icon after its names are read, 0 until then
ENDSTRUCT GR_SIZE
# SN_EXACT is OR-ed onto a match to mark that a name matched exactly
.equ SN_EXACT, 0x10000           # an exact name fits
# GF_* flags, GR_flags: which built-in highlighting rules to apply
.equ GF_NOCASE, 1
.equ GF_FUNCS, 2
.equ GF_CAPTYPES, 4
.equ GF_MARKUP, 8
.equ GF_LABELS, 16
.equ GF_NUMBERS, 32
.equ GF_OPS, 64
.equ GF_COLON, 128          # indent after a line ending with ":"

STRUCT
F REG_start, 16         # bytes that open the region
F REG_end, 16           # bytes that close it; empty = end of line
F REG_slen, 1
F REG_elen, 1
F REG_class, 1          # C_*
F REG_esc, 1
F REG_multi, 1
F REG_bol, 1            # only at line start (after blanks)
F REG_pad, 2
ENDSTRUCT REG_SIZE

# prompt kinds for the old palette one-line prompt (removed)
.equ PROMPT_SAVE_AS, 1
.equ PROMPT_NEW_FILE, 2
.equ PROMPT_NEW_FOLDER, 3
.equ PROMPT_RENAME, 4

# vim modes (the vim-mode feature is not in this build)
.equ VM_NORMAL, 0
.equ VM_INSERT, 1
.equ VM_VISUAL, 2
.equ VM_VLINE, 3

# command table entry
STRUCT
F CMD_name, 8
F CMD_title, 8
F CMD_fn, 8
F CMD_keys, 8           # default bindings, space separated
ENDSTRUCT CMD_SIZE

# json
.equ JT_NULL, 0
.equ JT_FALSE, 1
.equ JT_TRUE, 2
.equ JT_NUM, 3
.equ JT_STR, 4
.equ JT_ARR, 5
.equ JT_OBJ, 6

# ---- terminal ----
# unn's cell format: one cell is 12 bytes, codepoint | A_* attributes, fg, bg.
# colors are 0 (default), TC_IDX | palette index or TC_RGB | 0xrrggbb; the
# codepoint's top bits carry the attribute flags below
.equ CELL_SIZE, 12
.equ CP_MASK, 0x1fffff
.equ A_BOLD, 1 << 21
.equ A_DIM, 1 << 22
.equ A_ITALIC, 1 << 23
.equ A_UNDER, 1 << 24
.equ A_INVERSE, 1 << 25
.equ A_HIDDEN, 1 << 26
.equ A_STRIKE, 1 << 27
.equ A_WIDE, 1 << 28            # left half of a double-width character
.equ A_WIDE2, 1 << 29           # its right half
.equ A_BLINK, 1 << 30
.equ TC_IDX, 0x01000000
.equ TC_RGB, 0x02000000
# line: u32 cells allocated, u32 flags, then the cells
.equ LN_cap, 0
.equ LN_flags, 4
.equ LN_HDR, 8
.equ LF_WRAPPED, 1              # continues on the next line

# DEC modes unn mirrors out of libghostty-vt (TMM_* bits in TM_modes); the
# bit positions are unn's, set by term.s's vt_sync from the library's own
# mode booleans
.equ TMM_WRAP, 1
.equ TMM_APPCUR, 2
.equ TMM_ORIGIN, 4
.equ TMM_HIDE, 8
.equ TMM_ALT, 16
.equ TMM_INSERT, 32
.equ TMM_PASTE, 64
.equ TMM_SGRMOUSE, 128
.equ TMM_FOCUS, 256
.equ TMM_LNM, 512
.equ TMM_SYNC, 1024

# kitty keyboard flags as libghostty reports them (bit 0 = disambiguate escape codes)
.equ KK_SUPPORTED, 1

# unn's mirror of the terminal: the app draws and answers keys from these
# fields, while TM_gt (the GhosttyTerminal) stays the source of truth; the
# mirror is refreshed after every library call and TM_gen/TM_sync tell stale
# from fresh. Ghostty* fields hold the opaque library handles their C typedefs
# name (layouts per third_party/ghostty/ghostty/vt/*.h).
STRUCT
F TM_cols, 4            # active screen size
F TM_rows, 4
F TM_cx, 4              # cursor column, row
F TM_cy, 4
F TM_view, 4            # lines scrolled back (rows hidden above the active area)
F TM_sbcap, 4           # scrollback ring size
F TM_sbhead, 4          # oldest line position inside the ring
F TM_sblen, 4           # lines valid in the ring
F TM_modes, 4           # TMM_* bits, mirrored from libghostty
F TM_cursor, 4          # DECSCUSR style (1..6), 0 default
F TM_mouse, 4           # mouse tracking mode: 0, 1000, 1002 or 1003
F TM_kk, 4              # kitty keyboard flags of the active screen
F TM_kenc, 8            # GhosttyKeyEncoder (term.s encodes keys with it)
F TM_kev, 8             # GhosttyKeyEvent (reused for every key)
F TM_menc, 8            # GhosttyMouseEncoder
F TM_mev, 8             # GhosttyMouseEvent (reused for every button move)
F TM_lines, 8           # line pointers of the active screen
F TM_sb, 8              # scrollback ring
F TM_total, 8           # scrollback lines unn addresses (its ring holds them)
F TM_hlen, 8            # history rows libghostty holds (>= TM_total: it prunes by page)
F TM_gt, 8              # GhosttyTerminal: the source of truth
F TM_gts, 8             # GhosttyRenderState for row reads
F TM_gtc, 8             # reusable render-state row-cells handle
F TM_gti, 8             # reusable render-state row-iterator handle
F TM_gen, 4             # bumped after every mutating ghostty call
F TM_sync, 4            # mirror generation (stale when != TM_gen)
F TM_out, SB_SIZE       # replies to write back to the program inside the terminal
F TM_title, SB_SIZE     # title the program set (OSC 0/2)
ENDSTRUCT TM_SIZE

# Branch on rooted paths without clobbering registers.
.macro PATH_ABSOLUTE reg, target
    cmp byte ptr [\reg], '/'
    je \target
.endm

# ---- agent session metadata and transcript state ----
# One agent session (a chat log on disk): its file, parsed messages (AM
# records in AS_msgs), and cache fields for re-parsing only new bytes.
# Where comments say parent or worker, the field belonged to the list page's
# or the background parse process's use of the record; nothing reads this
# record in the terminal-only build.
STRUCT
F AS_path, 8            # path of the session's transcript file
F AS_title, 8
F AS_mtime, 8
F AS_off, 8             # bytes parsed so far (the log is appended to in place)
F AS_msgs, VEC_SIZE     # AM
F AS_part, SB_SIZE      # incomplete trailing line
F AS_kind, 4            # 1 claude, 2 codex, 3 grok, 4 opencode
F AS_loaded, 4          # messages parsed (opened at least once)
F AS_titled, 4          # has a custom title
F AS_pad, 4
F AS_changed, 8         # time_ms of the last growth
F AS_stamp, 8           # file_stamp, to see every write
F AS_index_title, 8    # parent: last title returned by the metadata index
F AS_recency, 8        # nanosecond mtime used for ordering
F AS_cwd, 8            # worker cache: originating checkout
F AS_seen, 8           # worker cache: present in this scan
F AS_worktree, 8        # linked checkout's name, or 0 for the main checkout
F AS_prefix_hash, 8     # worker: bounded prefix identity for append detection
F AS_title_off, 8       # worker: bytes covered by the last successful title read
F AS_title_rev, 8       # identity of the last indexed custom title record
F AS_record_off, 8      # worker: current title record's newline offset plus one
F AS_replaced, 8        # worker page: metadata came from a replaced or truncated log
F AS_bytes, 8           # worker, OpenCode: the conversation copy's estimated size
F AS_model, 8           # the model the session last used (its row), or 0
F AS_log_model, 8       # parse: the model the log names for the replies that follow
F AS_shown_model, 8     # parse: the model on the last reply labeled with one
ENDSTRUCT AS_SIZE
