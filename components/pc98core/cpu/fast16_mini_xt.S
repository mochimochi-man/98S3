/* SPDX-License-Identifier: MIT
 * Copyright (c) mochimochi-man / Uh
 * fast16 mini loop for the ESP32-S3 (Xtensa LX7), stage 20. Same contract as fast16_mini.inc (which stays the
 * reference, and runs the opcodes not written here one at a time through f16x_cone), but laid out for this core
 * instead of following the C:
 *  - one windowed function, f16x_start; every handler is a label in it, entered with jx, so the whole batch runs in
 *    one register window and the state never leaves the registers:
 *        a2 A   a3 pc (host pointer to the opcode)   a4 rem   a5 LR   a6 lim   a7 T   a8 ram   a9 nret   a10 LV
 *        a11 R: the handler's record (T entry of its opcode)   a0 a12-a15: scratch (a0 is the EA stub link; the
 *        return link is kept in the frame and put back before retw)
 *  - lazy flags in two registers instead of FLAGS:
 *        LR = the last result, sign-extended to 32 bits: ZF = (LR == 0), SF = (LR < 0), PF = parity of its low byte
 *        LV = bit 16 CF, bit 15 OF, bit 4 AF (other bits are don't-care)
 *    so a conditional jump is one beqz / bltz / bbsi, and ADD / SUB set the flags in six instructions. The system
 *    bits (TF IF DF IOPL) live in a stack slot. FLAGS is built only for PUSHF / LAHF, the C calls and the exit.
 *    A FLAGS value with ZF set and SF set or PF clear has no LR (only POPF / SAHF / IRET can make one): the loop is
 *    not entered with it, and SAHF hands it back.
 *  - T = f16x_rec (fast16.c): 8 bytes per index i, 256 for the plain opcodes and 256 for the ones after a segment
 *    prefix: +0 handler of opcode i, +4 byte register offsets of ModR/M i (rm | reg << 4), +5 PF of byte i (4 / 0),
 *    +6 clock of opcode i (register form / no ModR/M), +7 clock of opcode i (memory form). Dispatch is
 *    l8ui / addx8 / l32i / jx and leaves the record in a11, so a handler loads its clock with one l8ui.
 *  - a hand-back (f16x_exit) happens before any side effect, with pc at the opcode (or at the prefix: f16x_bailov)
 *  - memory: as fast16_mini.inc (RAM below A0000h for writes, A4000h for reads, no 64K wrap); a byte move to plain
 *    graphics VRAM calls the bus handler (gvram_plain_rd8 / wr8) with the clock handed over, as the C one. */
#include "fast16_rv.h"

#ifdef PC98_FAST16_WRITE_HOOK
#error "fast16_mini_xt.S has no write hook (differential tests run on the host)"
#endif

#define rA   a2
#define rPC  a3
#define rREM a4
#define rLR  a5
#define rLIM a6
#define rT   a7
#define rRAM a8
#define rN   a9
#define rLV  a10
#define rR   a11

/* stack frame (entry a1, FRAME): sp+0..15 outgoing, locals; the top 32 bytes are the window save areas (a4-a7 of
 * this frame when a callee spills it, and the caller's a0-a3) */
#define FRAME      96
#define FS_FSYS    16      /* FLAGS without CF PF AF ZF SF OF */
#define FS_PCB     20      /* A->mo_pcb */
#define FS_MCKT    24      /* A->mck_t */
#define FS_MCKMAIN 28      /* A->mck_main */
#define FS_OVB     32      /* segment base named by the prefix (handlers entered after one) */
#define FS_RAM     36
#define FS_NRET    40
#define FS_A0      44      /* the return link: a0 is a scratch register in the loop */
#define FS_LV      48      /* around a C call */
#define FS_T1      52
#define FS_T2      56
#define FS_T3      60

#define REC_M8     4
#define REC_PF     5
#define REC_CR     6
#define REC_CM     7
#define REC_OV     2048

#define MO(x)      ((x) - 0x500)   /* A fields past 1020: addmi 0x500 first */

    .set xov, 0

/* ---------------- dispatch / retire ---------------- */
.macro DISPATCH
    l8ui a12, rPC, 0
    addx8 rR, a12, rT
    l32i a12, rR, 0
    jx a12
.endm
/* exit islands: every retire is followed by one, so a hand-back branch (98f / 98b, 97 after a prefix) stays short */
.macro ISLAND
98: j f16x_exit
  .if xov
97: j f16x_bailov
  .endif
.endm
/* retire: debit a15 clocks, advance pc by nb (immediate, 0: already set), continue unless the batch is over.
 * The next opcode is read after the last store of the instruction (no stale prefetch on self-modifying code). */
.macro RETIRE nb
    l8ui a12, rPC, \nb
    sub rREM, rREM, a15
    addx8 rR, a12, rT
    addi rN, rN, 1
    l32i a12, rR, 0
  .if \nb
    addi rPC, rPC, \nb
  .endif
    blti rREM, 1, 98f
    bgeu rPC, rLIM, 98f
    jx a12
    ISLAND
.endm
/* the same, pc advanced by a register (not a12 / a15) */
.macro RETIRER nbr
    add rPC, rPC, \nbr
    RETIRE 0
.endm

/* ---------------- lazy flags ---------------- */
/* d = FLAGS (t u scratch) */
.macro MATFL d, t, u
    l32i \d, a1, FS_FSYS
    extui \t, rLV, 16, 1
    or \d, \d, \t
    extui \t, rLV, 15, 1
    slli \t, \t, 11
    or \d, \d, \t
    extui \t, rLV, 4, 1
    slli \t, \t, 4
    or \d, \d, \t
    extui \t, rLR, 31, 1
    slli \t, \t, 7
    or \d, \d, \t
    movi \t, 0x40
    movi \u, 0
    movnez \t, \u, rLR
    or \d, \d, \t
    extui \t, rLR, 0, 8
    addx8 \t, \t, rT
    l8ui \t, \t, REC_PF
    or \d, \d, \t
.endm
/* LR from ZF SF PF of f; to fail (nothing changed) when there is none */
.macro LAZYLR f, fail
    bbsi \f, 6, .Lz\@
    movi rLR, 1
    bbci \f, 2, .Lp\@
    movi rLR, 3
.Lp\@:
    bbci \f, 7, .Le\@
    addi rLR, rLR, -4                  /* -3: FDh (odd), -1: FFh (even) */
    j .Le\@
.Lz\@:
    bbsi \f, 7, \fail
    bbci \f, 2, \fail
    movi rLR, 0
.Le\@:
.endm
/* LR LV and the system bits from FLAGS f (t scratch); to fail (nothing changed) when there is no LR */
.macro LAZYFL f, t, fail
    LAZYLR \f, \fail
    extui rLV, \f, 0, 1
    slli rLV, rLV, 16
    extui \t, \f, 11, 1
    slli \t, \t, 15
    or rLV, rLV, \t
    extui \t, \f, 4, 1
    slli \t, \t, 4
    or rLV, rLV, \t
    movi \t, ~0x8d5
    and \t, \f, \t
    s32i \t, a1, FS_FSYS
.endm
/* add / sub flags: r = x +- y (+- carry) unmasked; x clobbered, v scratch */
.macro FLA w, x, y, r, v
    xor \v, \x, \y
    xor \v, \v, \r
  .if \w == 16
    extui \x, \v, 16, 1
    slli \x, \x, 15
    xor rLV, \v, \x                    /* bit 16 carry out, bit 15 carry in ^ out, bit 4 the nibble carry */
    sext rLR, \r, 15
  .else
    slli \x, \v, 8
    extui \v, \v, 0, 8
    or \x, \x, \v
    extui \v, \x, 16, 1
    slli \v, \v, 15
    xor rLV, \x, \v
    sext rLR, \r, 7
  .endif
.endm
/* OR AND XOR TEST: CF = OF = 0, AF kept */
.macro FLOG w, r, t
    movi \t, 16
    and rLV, rLV, \t
    sext rLR, \r, \w-1
.endm
/* ALU operation aop (0 ADD 1 OR 2 ADC 3 SBB 4 AND 5 SUB 6 XOR 7 CMP): r = x op y with the flags; x clobbered */
.macro ALUOP aop, w, r, x, y, v
  .if \aop == 0
    add \r, \x, \y
  .elseif \aop == 1
    or \r, \x, \y
  .elseif \aop == 2
    extui \v, rLV, 16, 1
    add \r, \x, \y
    add \r, \r, \v
  .elseif \aop == 3
    extui \v, rLV, 16, 1
    sub \r, \x, \y
    sub \r, \r, \v
  .elseif \aop == 4
    and \r, \x, \y
  .elseif \aop == 6
    xor \r, \x, \y
  .else
    sub \r, \x, \y
  .endif
  .if (\aop == 1) || (\aop == 4) || (\aop == 6)
    FLOG \w, \r, \x
  .else
    FLA \w, \x, \y, \r, \v
  .endif
.endm
/* INC / DEC flags: r = x +- 1 unmasked; CF kept; v t scratch */
.macro FLID w, x, r, v, t
    xor \v, \x, \r
  .if \w == 16
    extui \t, \v, 16, 1
    slli \t, \t, 15
    xor \v, \v, \t
  .else
    slli \t, \v, 8
    extui \v, \v, 0, 8
    or \v, \v, \t
    extui \t, \v, 16, 1
    slli \t, \t, 15
    xor \v, \v, \t
  .endif
    xor \t, \v, rLV
    extui \t, \t, 16, 1
    slli \t, \t, 16
    xor rLV, \v, \t
    sext rLR, \r, \w-1
.endm
/* LV = (LV & AF) | cf << 16 | of << 15 (cf of: 0 / 1, clobbered) */
.macro ROTFL cf, of
    slli \cf, \cf, 16
    slli \of, \of, 15
    or \cf, \cf, \of
    movi \of, 16
    and rLV, rLV, \of
    or rLV, rLV, \cf
.endm

/* ---------------- memory ---------------- */
.macro LDW d, p, t
    l8ui \d, \p, 0
    l8ui \t, \p, 1
    slli \t, \t, 8
    or \d, \d, \t
.endm
.macro STW p, v, t
    s8i \v, \p, 0
    srli \t, \v, 8
    s8i \t, \p, 1
.endm
/* ModR/M memory operand, a15 = ModR/M (< C0h): a12 offset, a13 linear address, a14 opcode+ModR/M+disp length */
.macro EA
    movi a12, f16x_eat
    addx4 a12, a15, a12
    l32i a12, a12, 0
    callx0 a12
  .if xov
    l32i a13, a1, FS_OVB
  .endif
    add a13, a13, a12
.endm
/* hand-back branch to the nearest island in direction d (b / f): 98 (plain), 97 (after a prefix) */
.macro BX insn, r1, r2, d
  .if xov
    \insn \r1, \r2, 97\d
  .else
    \insn \r1, \r2, 98\d
  .endif
.endm
.macro BX1 insn, r1, d
  .if xov
    \insn \r1, 97\d
  .else
    \insn \r1, 98\d
  .endif
.endm
/* operand bounds (a12 offset, a13 linear; a0 scratch): word / byte, ro = read only; hand-back to the island in d */
.macro CHKW ro, d
    addi a0, a12, 1
    BX bbsi, a0, 16, \d                /* offset FFFFh: 64K wrap */
  .if \ro
    movi a0, 0xa3fff
    BX bgeu, a13, a0, \d
  .else
    addi a0, a13, 1
    extui a0, a0, 17, 15
    BX bgeui, a0, 5, \d                /* last byte at A0000h or above */
  .endif
.endm
.macro CHKB ro, d
  .if \ro
    movi a0, 0xa4000
    BX bgeu, a13, a0, \d
  .else
    extui a0, a13, 17, 15
    BX bgeui, a0, 5, \d
  .endif
.endm
/* register pointers from ModR/M m: word rm / reg (A + 2 * index), byte rm / reg (A + byte offset) */
.macro RMW d, m
    extui \d, \m, 0, 3
    addx2 \d, \d, rA
.endm
.macro REGW d, m
    extui \d, \m, 3, 3
    addx2 \d, \d, rA
.endm
.macro REGB d, m
    addx8 \d, \m, rT
    l8ui \d, \d, REC_M8
    extui \d, \d, 4, 4
    add \d, \d, rA
.endm
.macro RMB d, m
    addx8 \d, \m, rT
    l8ui \d, \d, REC_M8
    extui \d, \d, 0, 4
    add \d, \d, rA
.endm
/* the same as byte pointers into A (offset of the register file added): byte (B 8) or word (B 16) */
.macro RMP d, m, B, t
  .if \B == 8
    RMB \d, \m
  .else
    RMW \d, \m
  .endif
    movi \t, F16A_R
    add \d, \d, \t
.endm
/* clock from mck_main[(op << 4) | (reg << 1) | mem]: d = clock, reg in r */
.macro MAINCLK d, op, r, mem
    l32i \d, a1, FS_MCKMAIN
    addmi \d, \d, ((\op) << 4) & 0xf00
    addx2 \d, \r, \d
    l8ui \d, \d, (((\op) << 4) & 0xf0) + \mem
.endm
/* new ip = (ip + nb + d) & FFFFh: pc = pcb + that; d register, t scratch */
.macro JREL nb, d, t
    l32i \t, a1, FS_PCB
    sub rPC, rPC, \t
    addi rPC, rPC, \nb
    add rPC, rPC, \d
    extui rPC, rPC, 0, 16
    add rPC, rPC, \t
.endm
/* LOADSEG: segment sg (register, 0..3), value v: seg, base, and the descriptor cache in the 286 models; t u scratch */
.macro LOADSEG sg, v, t, u, acc=0x93
    addx2 \t, \sg, rA
    s16i \v, \t, F16A_SEG
    slli \u, \v, 4
    addx4 \t, \sg, rA
    s32i \u, \t, F16A_BASE
    l32i \t, rA, F16A_MENU
    beqz \t, .Lls\@
    addx8 \t, \sg, rA
    s32i \u, \t, F16A_CACHE
    movi \u, -1
    s16i \u, \t, F16A_CACHE+4
    movi \u, \acc
    s8i \u, \t, F16A_CACHE+6
    add \t, \sg, rA
    movi \u, 1
    s8i \u, \t, F16A_VALID
.Lls\@:
.endm
/* jump on r (0..7) to the numeric labels 20..27 through a table in internal RAM; t scratch */
.macro JT8 r, t, tab
    .pushsection .dram1.f16x_jt, "aw"
    .align 4
\tab:
    .word 20f, 21f, 22f, 23f, 24f, 25f, 26f, 27f
    .popsection
    movi \t, \tab
    addx4 \t, \r, \t
    l32i \t, \t, 0
    jx \t
.endm

    .section .iram1.f16x, "ax"
    .align 4
    .global f16x_start
    .type f16x_start, @function
/* void f16x_start(Pc98Adapter *A, const uint8_t *pc, int32_t rem, unsigned fl, const uint8_t *lim, uint8_t *ram) */
f16x_start:
    entry a1, FRAME
    s32i a0, a1, FS_A0
    s32i a7, a1, FS_RAM
    mov rRAM, a7
    mov a12, a5
    movi rT, f16x_rec
    addmi a13, rA, 0x500
    l32i a14, a13, MO(F16A_MOPCB)
    s32i a14, a1, FS_PCB
    l32i a14, a13, MO(F16A_MCKT)
    s32i a14, a1, FS_MCKT
    l32i a14, a13, MO(F16A_MCKMAIN)
    s32i a14, a1, FS_MCKMAIN
    movi rN, 0
    LAZYFL a12, a13, .Lrefuse
    DISPATCH
.Lrefuse:                              /* FLAGS has no LR: nothing done, the generic loop goes on */
    addmi a13, rA, 0x500
    l32i a14, a1, FS_PCB
    sub a14, rPC, a14
    s32i a14, a13, MO(F16A_MOIP)
    s32i rREM, a13, MO(F16A_MOREM)
    s32i a12, a13, MO(F16A_MOFL)
    s32i rN, a13, MO(F16A_MONRET)
    l32i a0, a1, FS_A0
    retw

/* hand back (as C m_exit): pc, clock, FLAGS, count */
    .align 4
    .global f16x_h_exit
f16x_h_exit:
f16x_exit:
    MATFL a12, a13, a14
    addmi a13, rA, 0x500
    l32i a14, a1, FS_PCB
    sub a14, rPC, a14
    s32i a14, a13, MO(F16A_MOIP)
    s32i rREM, a13, MO(F16A_MOREM)
    s32i a12, a13, MO(F16A_MOFL)
    s32i rN, a13, MO(F16A_MONRET)
    l32i a0, a1, FS_A0
    retw
/* hand back from a handler entered after a segment prefix: pc goes back to the prefix */
    .align 4
    .global f16x_h_bailov
f16x_h_bailov:
f16x_bailov:
    addi rPC, rPC, -1
    j f16x_exit
f16x_ret:                              /* the A->mo_* state is already stored */
    l32i a0, a1, FS_A0
    retw

/* one instruction through the C mini handlers (f16x_cone), then on unless it ended the batch or changed CS */
    .align 4
f16x_cstep_ov:
    addi rPC, rPC, -1
    .global f16x_h_cstep
f16x_h_cstep:
f16x_cstep:
    MATFL a13, a12, a14
    s32i rN, a1, FS_NRET
    mov a10, rA
    mov a11, rPC
    mov a12, rREM
    mov a14, rN
    movi a15, f16x_cone
    callx8 a15
    l32i rRAM, a1, FS_RAM
    addmi a13, rA, 0x500
    l32i rN, a13, MO(F16A_MONRET)
    l32i a14, a1, FS_NRET
    beq rN, a14, 9f                    /* handed back: the generic loop runs it */
    l32i a14, a13, MO(F16A_MOEV)
    bnez a14, 9f
    l32i a14, a13, MO(F16A_MOPCB)
    l32i a15, a1, FS_PCB
    bne a14, a15, 9f
    l32i rREM, a13, MO(F16A_MOREM)
    blti rREM, 1, 9f
    l32i a14, a13, MO(F16A_MOIP)
    add rPC, a15, a14
    bgeu rPC, rLIM, 9f
    l32i a12, a13, MO(F16A_MOFL)
    LAZYFL a12, a14, 9f
    DISPATCH
9:  j f16x_ret

/* ---------------- EA stubs: called with callx0 (link a0); out a12 offset, a13 default segment base, a14 length ---------------- */
.macro EASTUB mod, rm
    .align 4
x_ea_\mod\rm:
  .if (\mod == 0) && (\rm == 6)
    l8ui a12, rPC, 2
    l8ui a14, rPC, 3
    l32i a13, rA, F16A_BASE+12
    slli a14, a14, 8
    or a12, a12, a14
    movi a14, 4
    jx a0
  .else
    .if (\rm == 0) || (\rm == 1) || (\rm == 7)
    l16ui a12, rA, F16A_R+6
    .elseif (\rm == 2) || (\rm == 3) || (\rm == 6)
    l16ui a12, rA, F16A_R+10
    .elseif \rm == 4
    l16ui a12, rA, F16A_R+12
    .else
    l16ui a12, rA, F16A_R+14
    .endif
    .if \rm < 4
    l16ui a14, rA, F16A_R+12+2*(\rm & 1)
    add a12, a12, a14
    .endif
    .if \mod == 1
    l8ui a14, rPC, 2
    sext a14, a14, 7
    add a12, a12, a14
    .elseif \mod == 2
    l8ui a14, rPC, 2
    add a12, a12, a14
    l8ui a14, rPC, 3
    slli a14, a14, 8
    add a12, a12, a14
    .endif
    .if (\mod != 0) || (\rm < 4)
    extui a12, a12, 0, 16
    .endif
    .if (\rm == 2) || (\rm == 3) || (\rm == 6)
    l32i a13, rA, F16A_BASE+8
    .else
    l32i a13, rA, F16A_BASE+12
    .endif
    movi a14, 2+\mod
    jx a0
  .endif
.endm
    EASTUB 0,0
    EASTUB 0,1
    EASTUB 0,2
    EASTUB 0,3
    EASTUB 0,4
    EASTUB 0,5
    EASTUB 0,6
    EASTUB 0,7
    EASTUB 1,0
    EASTUB 1,1
    EASTUB 1,2
    EASTUB 1,3
    EASTUB 1,4
    EASTUB 1,5
    EASTUB 1,6
    EASTUB 1,7
    EASTUB 2,0
    EASTUB 2,1
    EASTUB 2,2
    EASTUB 2,3
    EASTUB 2,4
    EASTUB 2,5
    EASTUB 2,6
    EASTUB 2,7

/* ---------------- 00-3B: ALU r/m, r and r, r/m (form bit 0 word, bit 1 reg is the destination) ---------------- */
.macro ALU_RM lbl, aop, form, ov
    .set xov, \ov
    .align 4
\lbl:
    l8ui a15, rPC, 1
    extui a12, a15, 6, 2
    bnei a12, 3, .Lm\@
  .if \form & 1
    RMW a12, a15
    REGW a13, a15
    l16ui a14, a12, F16A_R
    l16ui a0, a13, F16A_R
  .else
    addx8 a12, a15, rT
    l8ui a12, a12, REC_M8
    extui a13, a12, 4, 4
    extui a12, a12, 0, 4
    add a12, a12, rA
    add a13, a13, rA
    l8ui a14, a12, F16A_R
    l8ui a0, a13, F16A_R
  .endif
    l8ui a15, rR, REC_CR
  .if \form & 2
    ALUOP \aop, 8+8*(\form & 1), a12, a0, a14, rR
    .if \aop != 7
      .if \form & 1
    s16i a12, a13, F16A_R
      .else
    s8i a12, a13, F16A_R
      .endif
    .endif
  .else
    ALUOP \aop, 8+8*(\form & 1), a13, a14, a0, rR
    .if \aop != 7
      .if \form & 1
    s16i a13, a12, F16A_R
      .else
    s8i a13, a12, F16A_R
      .endif
    .endif
  .endif
    RETIRE 2
.Lm\@:
    EA
  .if \form & 1
    CHKW (\form & 2) || (\aop == 7), b
  .else
    CHKB (\form & 2) || (\aop == 7), b
  .endif
    add rPC, rPC, a14
    add a13, a13, rRAM
  .if \form & 1
    LDW a12, a13, a14
    REGW a14, a15
    l16ui a0, a14, F16A_R
  .else
    l8ui a12, a13, 0
    REGB a14, a15
    l8ui a0, a14, F16A_R
  .endif
    l8ui a15, rR, REC_CM
  .if \form & 2
    ALUOP \aop, 8+8*(\form & 1), a13, a0, a12, rR
    .if \aop != 7
      .if \form & 1
    s16i a13, a14, F16A_R
      .else
    s8i a13, a14, F16A_R
      .endif
    .endif
  .else
    ALUOP \aop, 8+8*(\form & 1), a14, a12, a0, rR
    .if \aop != 7
      .if \form & 1
    STW a13, a14, rR
      .else
    s8i a14, a13, 0
      .endif
    .endif
  .endif
    RETIRE 0
    .set xov, 0
.endm
    ALU_RM x_00, 0, 0, 0
    ALU_RM x_01, 0, 1, 0
    ALU_RM x_02, 0, 2, 0
    ALU_RM x_03, 0, 3, 0
    ALU_RM xo_00, 0, 0, 1
    ALU_RM xo_01, 0, 1, 1
    ALU_RM xo_02, 0, 2, 1
    ALU_RM xo_03, 0, 3, 1
    ALU_RM x_08, 1, 0, 0
    ALU_RM x_09, 1, 1, 0
    ALU_RM x_0a, 1, 2, 0
    ALU_RM x_0b, 1, 3, 0
    ALU_RM xo_08, 1, 0, 1
    ALU_RM xo_09, 1, 1, 1
    ALU_RM xo_0a, 1, 2, 1
    ALU_RM xo_0b, 1, 3, 1
    ALU_RM x_10, 2, 0, 0
    ALU_RM x_11, 2, 1, 0
    ALU_RM x_12, 2, 2, 0
    ALU_RM x_13, 2, 3, 0
    ALU_RM xo_10, 2, 0, 1
    ALU_RM xo_11, 2, 1, 1
    ALU_RM xo_12, 2, 2, 1
    ALU_RM xo_13, 2, 3, 1
    ALU_RM x_18, 3, 0, 0
    ALU_RM x_19, 3, 1, 0
    ALU_RM x_1a, 3, 2, 0
    ALU_RM x_1b, 3, 3, 0
    ALU_RM xo_18, 3, 0, 1
    ALU_RM xo_19, 3, 1, 1
    ALU_RM xo_1a, 3, 2, 1
    ALU_RM xo_1b, 3, 3, 1
    ALU_RM x_20, 4, 0, 0
    ALU_RM x_21, 4, 1, 0
    ALU_RM x_22, 4, 2, 0
    ALU_RM x_23, 4, 3, 0
    ALU_RM xo_20, 4, 0, 1
    ALU_RM xo_21, 4, 1, 1
    ALU_RM xo_22, 4, 2, 1
    ALU_RM xo_23, 4, 3, 1
    ALU_RM x_28, 5, 0, 0
    ALU_RM x_29, 5, 1, 0
    ALU_RM x_2a, 5, 2, 0
    ALU_RM x_2b, 5, 3, 0
    ALU_RM xo_28, 5, 0, 1
    ALU_RM xo_29, 5, 1, 1
    ALU_RM xo_2a, 5, 2, 1
    ALU_RM xo_2b, 5, 3, 1
    ALU_RM x_30, 6, 0, 0
    ALU_RM x_31, 6, 1, 0
    ALU_RM x_32, 6, 2, 0
    ALU_RM x_33, 6, 3, 0
    ALU_RM xo_30, 6, 0, 1
    ALU_RM xo_31, 6, 1, 1
    ALU_RM xo_32, 6, 2, 1
    ALU_RM xo_33, 6, 3, 1
    ALU_RM x_38, 7, 0, 0
    ALU_RM x_39, 7, 1, 0
    ALU_RM x_3a, 7, 2, 0
    ALU_RM x_3b, 7, 3, 0
    ALU_RM xo_38, 7, 0, 1
    ALU_RM xo_39, 7, 1, 1
    ALU_RM xo_3a, 7, 2, 1
    ALU_RM xo_3b, 7, 3, 1

/* ---------------- ALU AL / AX, imm ---------------- */
.macro ALU_ACC lbl, aop, w
    .align 4
\lbl:
    l8ui a15, rR, REC_CR
  .if \w == 16
    l16ui a12, rA, F16A_R
    l8ui a13, rPC, 1
    l8ui a14, rPC, 2
    slli a14, a14, 8
    or a13, a13, a14
    ALUOP \aop, 16, a14, a12, a13, a0
    .if \aop != 7
    s16i a14, rA, F16A_R
    .endif
    RETIRE 3
  .else
    l8ui a12, rA, F16A_R
    l8ui a13, rPC, 1
    ALUOP \aop, 8, a14, a12, a13, a0
    .if \aop != 7
    s8i a14, rA, F16A_R
    .endif
    RETIRE 2
  .endif
.endm
    ALU_ACC x_04, 0, 8
    ALU_ACC x_05, 0, 16
    ALU_ACC x_0c, 1, 8
    ALU_ACC x_0d, 1, 16
    ALU_ACC x_14, 2, 8
    ALU_ACC x_15, 2, 16
    ALU_ACC x_1c, 3, 8
    ALU_ACC x_1d, 3, 16
    ALU_ACC x_24, 4, 8
    ALU_ACC x_25, 4, 16
    ALU_ACC x_2c, 5, 8
    ALU_ACC x_2d, 5, 16
    ALU_ACC x_34, 6, 8
    ALU_ACC x_35, 6, 16
    ALU_ACC x_3c, 7, 8
    ALU_ACC x_3d, 7, 16

/* ---------------- INC / DEC r16 (CF kept) ---------------- */
.macro INCDEC lbl, i, dec
    .align 4
\lbl:
    l16ui a12, rA, F16A_R+2*\i
    l8ui a15, rR, REC_CR
  .if \dec
    addi a13, a12, -1
  .else
    addi a13, a12, 1
  .endif
    s16i a13, rA, F16A_R+2*\i
    FLID 16, a12, a13, a14, a0
    RETIRE 1
.endm
    INCDEC x_40, 0, 0
    INCDEC x_41, 1, 0
    INCDEC x_42, 2, 0
    INCDEC x_43, 3, 0
    INCDEC x_44, 4, 0
    INCDEC x_45, 5, 0
    INCDEC x_46, 6, 0
    INCDEC x_47, 7, 0
    INCDEC x_48, 0, 1
    INCDEC x_49, 1, 1
    INCDEC x_4a, 2, 1
    INCDEC x_4b, 3, 1
    INCDEC x_4c, 4, 1
    INCDEC x_4d, 5, 1
    INCDEC x_4e, 6, 1
    INCDEC x_4f, 7, 1

/* ---------------- PUSH / POP ---------------- */
/* push: a13 host address of the new top, a14 new SP; hand-back (98f) when SP = 1 or the word is not below A0000h */
.macro PUSHCHK d=f
    l16ui a12, rA, F16A_R+8
    l32i a13, rA, F16A_BASE+8
    addi a14, a12, -2
    extui a14, a14, 0, 16
    beqi a12, 1, 98\d
    add a13, a13, a14
    addi a0, a13, 1
    extui a0, a0, 17, 15
    bgeui a0, 5, 98\d
    add a13, a13, rRAM
.endm
/* pop: a13 host address of the top, a12 SP; hand-back when SP = FFFFh or the word is not below A4000h */
.macro POPCHK
    l16ui a12, rA, F16A_R+8
    l32i a13, rA, F16A_BASE+8
    movi a0, 0xa3fff
    add a13, a13, a12
    bgeu a13, a0, 98f
    addi a14, a12, 1
    bbsi a14, 16, 98f
    add a13, a13, rRAM
.endm
.macro PUSHR lbl, off
    .align 4
\lbl:
    PUSHCHK
    l16ui a0, rA, \off
    l8ui a15, rR, REC_CR
    STW a13, a0, a12
    s16i a14, rA, F16A_R+8
    RETIRE 1
.endm
.macro POPR lbl, i
    .align 4
\lbl:
    POPCHK
    LDW a14, a13, a0
    addi a12, a12, 2
    l8ui a15, rR, REC_CR
    s16i a12, rA, F16A_R+8
    s16i a14, rA, F16A_R+2*\i
    RETIRE 1
.endm
    PUSHR x_50, F16A_R+0
    PUSHR x_51, F16A_R+2
    PUSHR x_52, F16A_R+4
    PUSHR x_53, F16A_R+6
    PUSHR x_55, F16A_R+10
    PUSHR x_56, F16A_R+12
    PUSHR x_57, F16A_R+14
    POPR x_58, 0
    POPR x_59, 1
    POPR x_5a, 2
    POPR x_5b, 3
    POPR x_5d, 5
    POPR x_5e, 6
    POPR x_5f, 7
    PUSHR x_06, F16A_SEG+0
    PUSHR x_0e, F16A_SEG+2
    PUSHR x_16, F16A_SEG+4
    PUSHR x_1e, F16A_SEG+6
.macro POPSEG lbl, sg
    .align 4
\lbl:
    POPCHK
    LDW a14, a13, a0
    addi a12, a12, 2
    s16i a12, rA, F16A_R+8
    movi a15, \sg
    LOADSEG a15, a14, a12, a13
    l8ui a15, rR, REC_CR
    RETIRE 1
.endm
    POPSEG x_07, 0
    POPSEG x_1f, 3

/* PUSHF: the V30 (menu 0) sets the top four bits (hand-back to the island before it) */
    ISLAND
    .align 4
x_9c:
    PUSHCHK b
    MATFL a0, a12, a15
    l32i a12, rA, F16A_MENU
    bnez a12, 1f
    movi a12, 0xfd5
    and a0, a0, a12
    movi a12, 0xf002
    or a0, a0, a12
    j 2f
1:  movi a12, 0x7fd5
    and a0, a0, a12
    movi a12, 2
    or a0, a0, a12
2:  STW a13, a0, a12
    s16i a14, rA, F16A_R+8
    l8ui a15, rR, REC_CR
    RETIRE 1

/* ---------------- segment prefix: on in the prefixed table with the base in FS_OVB ---------------- */
    .align 4
x_26:
x_2e:
x_36:
x_3e:
    l8ui a12, rPC, 0
    extui a12, a12, 3, 2
    addx4 a12, a12, rA
    l32i a12, a12, F16A_BASE
    s32i a12, a1, FS_OVB
    addi rPC, rPC, 1
    l8ui a12, rPC, 0
    addx8 rR, a12, rT
    addmi rR, rR, REC_OV
    l32i a12, rR, 0
    jx a12

/* ---------------- Jcc rel8: to 1f when the condition holds ---------------- */
.macro JCC lbl, op
    .align 4
\lbl:
    l8ui a15, rR, REC_CR
    .set cc_, ((\op) & 15)
  .if cc_ == 0
    bbsi rLV, 15, 1f
  .elseif cc_ == 1
    bbci rLV, 15, 1f
  .elseif cc_ == 2
    bbsi rLV, 16, 1f
  .elseif cc_ == 3
    bbci rLV, 16, 1f
  .elseif cc_ == 4
    beqz rLR, 1f
  .elseif cc_ == 5
    bnez rLR, 1f
  .elseif cc_ == 6
    bbsi rLV, 16, 1f
    beqz rLR, 1f
  .elseif cc_ == 7
    bbsi rLV, 16, 3f
    bnez rLR, 1f
  .elseif cc_ == 8
    bltz rLR, 1f
  .elseif cc_ == 9
    bgez rLR, 1f
  .elseif cc_ == 10
    extui a12, rLR, 0, 8
    addx8 a12, a12, rT
    l8ui a12, a12, REC_PF
    bnez a12, 1f
  .elseif cc_ == 11
    extui a12, rLR, 0, 8
    addx8 a12, a12, rT
    l8ui a12, a12, REC_PF
    beqz a12, 1f
  .elseif cc_ == 12
    slli a12, rLV, 16
    xor a12, a12, rLR
    bltz a12, 1f
  .elseif cc_ == 13
    slli a12, rLV, 16
    xor a12, a12, rLR
    bgez a12, 1f
  .elseif cc_ == 14
    beqz rLR, 1f
    slli a12, rLV, 16
    xor a12, a12, rLR
    bltz a12, 1f
  .else
    beqz rLR, 3f
    slli a12, rLV, 16
    xor a12, a12, rLR
    bgez a12, 1f
  .endif
3:  RETIRE 2
1:  l8ui a13, rPC, 1
    sext a13, a13, 7
    beqz a13, 2f
    l32i a14, a1, FS_MCKT
    l8ui a14, a14, \op
    add a15, a15, a14
2:  JREL 2, a13, a14
    RETIRE 0
.endm
    JCC x_70, 0x70
    JCC x_71, 0x71
    JCC x_72, 0x72
    JCC x_73, 0x73
    JCC x_74, 0x74
    JCC x_75, 0x75
    JCC x_76, 0x76
    JCC x_77, 0x77
    JCC x_78, 0x78
    JCC x_79, 0x79
    JCC x_7a, 0x7a
    JCC x_7b, 0x7b
    JCC x_7c, 0x7c
    JCC x_7d, 0x7d
    JCC x_7e, 0x7e
    JCC x_7f, 0x7f

/* ---------------- TEST AL / AX, imm ---------------- */
    .align 4
x_a8:
    l8ui a12, rA, F16A_R
    l8ui a13, rPC, 1
    l8ui a15, rR, REC_CR
    and a14, a12, a13
    FLOG 8, a14, a12
    RETIRE 2
    .align 4
x_a9:
    l16ui a12, rA, F16A_R
    l8ui a13, rPC, 1
    l8ui a14, rPC, 2
    l8ui a15, rR, REC_CR
    slli a14, a14, 8
    or a13, a13, a14
    and a14, a12, a13
    FLOG 16, a14, a12
    RETIRE 3

/* ---------------- MOV r, imm; XCHG AX, r ---------------- */
.macro MOVI8 lbl, i
    .align 4
\lbl:
    l8ui a12, rPC, 1
    l8ui a15, rR, REC_CR
    s8i a12, rA, F16A_R+(((\i & 3) << 1) | (\i >> 2))
    RETIRE 2
.endm
.macro MOVI16 lbl, i
    .align 4
\lbl:
    l8ui a12, rPC, 1
    l8ui a13, rPC, 2
    l8ui a15, rR, REC_CR
    slli a13, a13, 8
    or a12, a12, a13
    s16i a12, rA, F16A_R+2*\i
    RETIRE 3
.endm
.macro XCHG lbl, i
    .align 4
\lbl:
    l16ui a12, rA, F16A_R
    l16ui a13, rA, F16A_R+2*\i
    l8ui a15, rR, REC_CR
    s16i a13, rA, F16A_R
    s16i a12, rA, F16A_R+2*\i
    RETIRE 1
.endm
    MOVI8 x_b0, 0
    MOVI8 x_b1, 1
    MOVI8 x_b2, 2
    MOVI8 x_b3, 3
    MOVI8 x_b4, 4
    MOVI8 x_b5, 5
    MOVI8 x_b6, 6
    MOVI8 x_b7, 7
    MOVI16 x_b8, 0
    MOVI16 x_b9, 1
    MOVI16 x_ba, 2
    MOVI16 x_bb, 3
    MOVI16 x_bc, 4
    MOVI16 x_bd, 5
    MOVI16 x_be, 6
    MOVI16 x_bf, 7
    XCHG x_90, 0
    XCHG x_91, 1
    XCHG x_92, 2
    XCHG x_93, 3
    XCHG x_94, 4
    XCHG x_95, 5
    XCHG x_96, 6
    XCHG x_97, 7

/* ---------------- CBW CWD SAHF LAHF, flag bits ---------------- */
    .align 4
x_98:
    l8ui a12, rA, F16A_R
    l8ui a15, rR, REC_CR
    sext a12, a12, 7
    s16i a12, rA, F16A_R
    RETIRE 1
    .align 4
x_99:
    l16si a12, rA, F16A_R
    l8ui a15, rR, REC_CR
    srai a12, a12, 31
    s16i a12, rA, F16A_R+4
    RETIRE 1
/* SAHF: SF ZF AF PF CF from AH, OF kept; an AH without an LR is handed back */
    .align 4
x_9e:
    l8ui a12, rA, F16A_R+1
    LAZYLR a12, 98f
    extui a13, rLV, 15, 1
    slli a13, a13, 15
    extui a14, a12, 0, 1
    slli a14, a14, 16
    or a13, a13, a14
    extui a14, a12, 4, 1
    slli a14, a14, 4
    or rLV, a13, a14
    l8ui a15, rR, REC_CR
    RETIRE 1
    .align 4
x_9f:
    extui a12, rLV, 16, 1
    extui a13, rLV, 4, 1
    slli a13, a13, 4
    or a12, a12, a13
    extui a13, rLR, 31, 1
    slli a13, a13, 7
    or a12, a12, a13
    movi a13, 0x40
    movi a14, 0
    movnez a13, a14, rLR
    or a12, a12, a13
    extui a13, rLR, 0, 8
    addx8 a13, a13, rT
    l8ui a13, a13, REC_PF
    or a12, a12, a13
    movi a13, 2
    or a12, a12, a13
    l8ui a15, rR, REC_CR
    s8i a12, rA, F16A_R+1
    RETIRE 1
    .align 4
x_f5:
    movi a12, 1
    slli a12, a12, 16
    l8ui a15, rR, REC_CR
    xor rLV, rLV, a12
    RETIRE 1
    .align 4
x_f8:
    extui a12, rLV, 16, 1
    slli a12, a12, 16
    l8ui a15, rR, REC_CR
    xor rLV, rLV, a12
    RETIRE 1
    .align 4
x_f9:
    movi a12, 1
    slli a12, a12, 16
    l8ui a15, rR, REC_CR
    or rLV, rLV, a12
    RETIRE 1
.macro FSYSOP lbl, insn, k
    .align 4
\lbl:
    l32i a12, a1, FS_FSYS
    movi a13, \k
    l8ui a15, rR, REC_CR
    \insn a12, a12, a13
    s32i a12, a1, FS_FSYS
    RETIRE 1
.endm
    FSYSOP x_fa, and, ~0x200
    FSYSOP x_fc, and, ~0x400
    FSYSOP x_fd, or, 0x400

/* ---------------- JMP short / near, CALL near, RET near ---------------- */
    .align 4
x_eb:
    l8ui a13, rPC, 1
    l8ui a15, rR, REC_CR
    sext a13, a13, 7
    JREL 2, a13, a14
    RETIRE 0
    .align 4
x_e9:
    l8ui a13, rPC, 1
    l8ui a14, rPC, 2
    l8ui a15, rR, REC_CR
    slli a14, a14, 8
    or a13, a13, a14
    JREL 3, a13, a14
    RETIRE 0
    .align 4
x_e8:
    PUSHCHK
    l8ui a12, rPC, 1                   /* the displacement first: the push may overwrite it (stack over the code) */
    l8ui a0, rPC, 2
    slli a0, a0, 8
    or a12, a12, a0
    l32i a0, a1, FS_PCB
    sub a15, rPC, a0
    addi a15, a15, 3
    extui a15, a15, 0, 16              /* return ip */
    add a12, a12, a15
    extui a12, a12, 0, 16
    add rPC, a0, a12
    STW a13, a15, a0
    s16i a14, rA, F16A_R+8
    l8ui a15, rR, REC_CR
    RETIRE 0
    .align 4
x_c3:
    POPCHK
    LDW a14, a13, a0
    addi a12, a12, 2
    s16i a12, rA, F16A_R+8
    l32i a0, a1, FS_PCB
    l8ui a15, rR, REC_CR
    add rPC, a0, a14
    RETIRE 0

/* ---------------- E0 LOOPNZ  E1 LOOPZ  E2 LOOP  E3 JCXZ ---------------- */
.macro LOOPX lbl, n
    .align 4
\lbl:
    l8ui a15, rR, REC_CR
    l16ui a13, rA, F16A_R+2
  .if \n == 2
    /* LOOP $ (a delay loop onto itself): the taken iterations that fit the budget in one go; the last one
     * (CX 1 -> 0) runs normally (as fast16_mini.inc m_loop) */
    l8ui a12, rPC, 1
    movi a14, 0xfe
    bne a12, a14, 4f
    beqi a13, 1, 4f
    blti rREM, 1, 4f
    l32i a14, a1, FS_MCKT
    l8ui a14, a14, 0xe2
    add a14, a14, a15                  /* clocks of one taken iteration */
    addi a12, a13, -1
    extui a12, a12, 0, 16              /* CX - 1 (CX = 0: FFFFh) */
    quou a0, rREM, a14
    bgeu a0, a12, 5f
    mov a12, a0
    bnez a12, 5f
    movi a12, 1
5:  sub a13, a13, a12
    s16i a13, rA, F16A_R+2
    add rN, rN, a12
    addi rN, rN, -1
    mull a15, a12, a14
    RETIRE 0
4:
  .endif
  .if \n == 3
    bnez a13, 3f
  .else
    addi a13, a13, -1
    extui a13, a13, 0, 16
    s16i a13, rA, F16A_R+2
    beqz a13, 3f
    .if \n == 0
    beqz rLR, 3f
    .elseif \n == 1
    bnez rLR, 3f
    .endif
  .endif
    l8ui a13, rPC, 1
    sext a13, a13, 7
    beqz a13, 2f
    l32i a14, a1, FS_MCKT
    l8ui a14, a14, 0xe0+\n
    add a15, a15, a14
2:  JREL 2, a13, a14
    RETIRE 0
3:  RETIRE 2
.endm
    LOOPX x_e0, 0
    LOOPX x_e1, 1
    LOOPX x_e2, 2
    LOOPX x_e3, 3

/* ---------------- LEA ---------------- */
    .align 4
x_8d:
    l8ui a15, rPC, 1
    extui a12, a15, 6, 2
    beqi a12, 3, 98f
    movi a12, f16x_eat
    addx4 a12, a15, a12
    l32i a12, a12, 0
    callx0 a12
    REGW a13, a15
    s16i a12, a13, F16A_R
    l8ui a15, rR, REC_CM
    RETIRER a14

/* ---------------- plain graphics VRAM byte moves (as fast16_mini.inc M_GVRAM / M_GVRD8 / M_GVWR8) ----------------
 * a13 linear address: hand back (island d) unless it is plain graphics VRAM (A8000h-BFFFFh, no GRCG / EGC) */
.macro GVCHK d
    l32i a0, rA, F16A_SLICEP
    BX1 beqz, a0, \d
    movi a0, 0xa8000
    sub a0, a13, a0
    movi a12, 0x18000
    BX bgeu, a0, a12, \d
    movi a0, g_gvram_plain
    l32i a0, a0, 0
    BX1 bltz, a0, \d
.endm
/* call fn (a10 = a13 address, a11 = a12 value) with the clock handed over and taken back; a14 (length), a15 (ModR/M:
 * FS_T3) kept; out a13 = return value, a15 = memory-form clock */
.macro GVCALL fn
    s32i rN, a1, FS_NRET
    s32i rLV, a1, FS_LV
    s32i a14, a1, FS_T1
    s32i a15, a1, FS_T3
    l8ui a15, rR, REC_CM
    s32i a15, a1, FS_T2
    l32i a0, rA, F16A_SLICEP
    addmi a15, rA, 0x500
    l32i a15, a15, MO(F16A_MOOFF)
    add a15, rREM, a15
    s32i a15, a0, 0
    mov a10, a13
    mov a11, a12
    movi a15, \fn
    callx8 a15
    mov a13, a10
    l32i rRAM, a1, FS_RAM
    l32i rN, a1, FS_NRET
    l32i rLV, a1, FS_LV
    l32i a14, a1, FS_T1
    l32i a0, rA, F16A_SLICEP
    l32i a0, a0, 0
    addmi a15, rA, 0x500
    l32i a15, a15, MO(F16A_MOOFF)
    sub rREM, a0, a15
    l32i a15, a1, FS_T2
.endm

/* ---------------- 88-8B MOV ---------------- */
/* 88: MOV r/m8, r8. A write at A0000h or above: plain graphics VRAM through the bus handler, the rest handed back */
.macro MOV88 lbl, ov
    .set xov, \ov
    .align 4
\lbl:
    l8ui a15, rPC, 1
    extui a12, a15, 6, 2
    bnei a12, 3, .Lm\@
    addx8 a12, a15, rT
    l8ui a12, a12, REC_M8
    extui a13, a12, 4, 4
    extui a12, a12, 0, 4
    add a13, a13, rA
    add a12, a12, rA
    l8ui a14, a13, F16A_R
    l8ui a15, rR, REC_CR
    s8i a14, a12, F16A_R
    RETIRE 2
.Lm\@:
    EA
    extui a0, a13, 17, 15
    bgeui a0, 5, .Ls\@
    add a13, a13, rRAM
    REGB a12, a15
    l8ui a12, a12, F16A_R
    l8ui a15, rR, REC_CM
    s8i a12, a13, 0
    RETIRER a14
.Ls\@:
    GVCHK b
    REGB a12, a15
    l8ui a12, a12, F16A_R
    GVCALL gvram_plain_wr8
    RETIRER a14
    .set xov, 0
.endm
.macro MOV89 lbl, ov
    .set xov, \ov
    .align 4
\lbl:
    l8ui a15, rPC, 1
    extui a12, a15, 6, 2
    bnei a12, 3, .Lm\@
    RMW a12, a15
    REGW a13, a15
    l16ui a14, a13, F16A_R
    l8ui a15, rR, REC_CR
    s16i a14, a12, F16A_R
    RETIRE 2
.Lm\@:
    EA
    CHKW 0, b
    add a13, a13, rRAM
    REGW a12, a15
    l16ui a12, a12, F16A_R
    l8ui a15, rR, REC_CM
    STW a13, a12, a0
    RETIRER a14
    .set xov, 0
.endm
/* 8A: MOV r8, r/m8. A read at A4000h or above: as 88 */
.macro MOV8A lbl, ov
    .set xov, \ov
    .align 4
\lbl:
    l8ui a15, rPC, 1
    extui a12, a15, 6, 2
    bnei a12, 3, .Lm\@
    addx8 a12, a15, rT
    l8ui a12, a12, REC_M8
    extui a13, a12, 4, 4
    extui a12, a12, 0, 4
    add a13, a13, rA
    add a12, a12, rA
    l8ui a14, a12, F16A_R
    l8ui a15, rR, REC_CR
    s8i a14, a13, F16A_R
    RETIRE 2
.Lm\@:
    EA
    movi a0, 0xa4000
    bgeu a13, a0, .Ls\@
    add a13, a13, rRAM
    l8ui a13, a13, 0
    REGB a12, a15
    l8ui a15, rR, REC_CM
    s8i a13, a12, F16A_R
    RETIRER a14
.Ls\@:
    GVCHK b
    GVCALL gvram_plain_rd8
    l32i a12, a1, FS_T3
    REGB a12, a12
    s8i a13, a12, F16A_R
    RETIRER a14
    .set xov, 0
.endm
.macro MOV8B lbl, ov
    .set xov, \ov
    .align 4
\lbl:
    l8ui a15, rPC, 1
    extui a12, a15, 6, 2
    bnei a12, 3, .Lm\@
    RMW a12, a15
    REGW a13, a15
    l16ui a14, a12, F16A_R
    l8ui a15, rR, REC_CR
    s16i a14, a13, F16A_R
    RETIRE 2
.Lm\@:
    EA
    CHKW 1, b
    add a13, a13, rRAM
    LDW a12, a13, a0
    REGW a13, a15
    l8ui a15, rR, REC_CM
    s16i a12, a13, F16A_R
    RETIRER a14
    .set xov, 0
.endm
    MOV88 x_88, 0
    MOV88 xo_88, 1
    MOV89 x_89, 0
    MOV89 xo_89, 1
    MOV8A x_8a, 0
    MOV8A xo_8a, 1
    MOV8B x_8b, 0
    MOV8B xo_8b, 1

/* ---------------- 84 85 TEST r/m, r ---------------- */
.macro TESTRM lbl, w, ov
    .set xov, \ov
    .align 4
\lbl:
    l8ui a15, rPC, 1
    extui a12, a15, 6, 2
    bnei a12, 3, .Lm\@
  .if \w == 16
    RMW a12, a15
    REGW a13, a15
    l16ui a14, a12, F16A_R
    l16ui a13, a13, F16A_R
  .else
    addx8 a12, a15, rT
    l8ui a12, a12, REC_M8
    extui a13, a12, 4, 4
    extui a12, a12, 0, 4
    add a12, a12, rA
    add a13, a13, rA
    l8ui a14, a12, F16A_R
    l8ui a13, a13, F16A_R
  .endif
    l8ui a15, rR, REC_CR
    and a14, a14, a13
    FLOG \w, a14, a12
    RETIRE 2
.Lm\@:
    EA
  .if \w == 16
    CHKW 1, b
    add a13, a13, rRAM
    LDW a12, a13, a0
    REGW a13, a15
    l16ui a13, a13, F16A_R
  .else
    CHKB 1, b
    add a13, a13, rRAM
    l8ui a12, a13, 0
    REGB a13, a15
    l8ui a13, a13, F16A_R
  .endif
    l8ui a15, rR, REC_CM
    and a12, a12, a13
    FLOG \w, a12, a13
    RETIRER a14
    .set xov, 0
.endm
    TESTRM x_84, 8, 0
    TESTRM xo_84, 8, 1
    TESTRM x_85, 16, 0
    TESTRM xo_85, 16, 1

/* ---------------- 80-83: ALU r/m, imm ----------------
 * a13 = pointer to the operand (RAM, or the register inside A as a byte pointer), a12 = its value, a0 = imm,
 * a15 = clock (mck_main by operation), pc past the instruction; then by the reg field through JT8 */
.macro GRP1 lbl, op, ov
    .set xov, \ov
    .set wd_, 8+8*((\op) & 1)
    .align 4
\lbl:
    l8ui a15, rPC, 1
    extui a12, a15, 6, 2
    bnei a12, 3, .Lm\@
    /* register form: a13 = A + register offset, a12 value, a0 imm, rR reg field, a15 clock */
  .if wd_ == 16
    RMW a13, a15
    l16ui a12, a13, F16A_R
  .else
    RMB a13, a15
    l8ui a12, a13, F16A_R
  .endif
    extui rR, a15, 3, 3
    MAINCLK a15, \op, rR, 0
  .if (\op) == 0x81
    l8ui a0, rPC, 2
    l8ui a14, rPC, 3
    addi rPC, rPC, 4
    slli a14, a14, 8
    or a0, a0, a14
  .else
    l8ui a0, rPC, 2
    addi rPC, rPC, 3
    .if (\op) == 0x83
    sext a0, a0, 7
    extui a0, a0, 0, 16
    .endif
  .endif
    JT8 rR, a14, \lbl\()_rops
  .irp k, 0, 1, 2, 3, 4, 5, 6
2\k:
    ALUOP \k, wd_, a14, a12, a0, rR
    .if wd_ == 16
    s16i a14, a13, F16A_R
    .else
    s8i a14, a13, F16A_R
    .endif
    RETIRE 0
  .endr
27:
    ALUOP 7, wd_, a14, a12, a0, rR
    RETIRE 0
.Lm\@:
    EA
  .if wd_ == 16
    CHKW 0, b
  .else
    CHKB 0, b
  .endif
    add a13, a13, rRAM
    extui rR, a15, 3, 3
    MAINCLK a15, \op, rR, 1
    add a14, rPC, a14                  /* the immediate */
  .if wd_ == 8
    l8ui a12, a13, 0
    l8ui a0, a14, 0
    addi rPC, a14, 1
  .elseif (\op) == 0x83
    LDW a12, a13, a0
    l8ui a0, a14, 0
    addi rPC, a14, 1
    sext a0, a0, 7
    extui a0, a0, 0, 16
  .else
    LDW a12, a13, a0
    l8ui a0, a14, 0
    addi rPC, a14, 2
    l8ui a14, a14, 1
    slli a14, a14, 8
    or a0, a0, a14
  .endif
    JT8 rR, a14, \lbl\()_mops
  .irp k, 0, 1, 2, 3, 4, 5, 6
2\k:
    ALUOP \k, wd_, a14, a12, a0, rR
    .if wd_ == 16
    STW a13, a14, rR
    .else
    s8i a14, a13, 0
    .endif
    RETIRE 0
  .endr
27:
    ALUOP 7, wd_, a14, a12, a0, rR
    RETIRE 0
    .set xov, 0
.endm
    GRP1 x_80, 0x80, 0
    GRP1 xo_80, 0x80, 1
    GRP1 x_81, 0x81, 0
    GRP1 xo_81, 0x81, 1
    GRP1 x_82, 0x82, 0
    GRP1 xo_82, 0x82, 1
    GRP1 x_83, 0x83, 0
    GRP1 xo_83, 0x83, 1

/* ---------------- A0-A3: accumulator <-> [moffs] ---------------- */
.macro MOFFS ov
    l8ui a12, rPC, 1
    l8ui a13, rPC, 2
    slli a13, a13, 8
    or a12, a12, a13
  .if \ov
    l32i a13, a1, FS_OVB
  .else
    l32i a13, rA, F16A_BASE+12
  .endif
    add a13, a13, a12
.endm
.macro MOVA lbl, op, ov
    .set xov, \ov
    .align 4
\lbl:
    MOFFS \ov
  .if (\op) == 0xa0
    CHKB 1, f
    add a13, a13, rRAM
    l8ui a12, a13, 0
    l8ui a15, rR, REC_CR
    s8i a12, rA, F16A_R
  .elseif (\op) == 0xa1
    CHKW 1, f
    add a13, a13, rRAM
    LDW a12, a13, a0
    l8ui a15, rR, REC_CR
    s16i a12, rA, F16A_R
  .elseif (\op) == 0xa2
    CHKB 0, f
    add a13, a13, rRAM
    l8ui a12, rA, F16A_R
    l8ui a15, rR, REC_CR
    s8i a12, a13, 0
  .else
    CHKW 0, f
    add a13, a13, rRAM
    l16ui a12, rA, F16A_R
    l8ui a15, rR, REC_CR
    STW a13, a12, a0
  .endif
    RETIRE 3
    .set xov, 0
.endm
    MOVA x_a0, 0xa0, 0
    MOVA xo_a0, 0xa0, 1
    MOVA x_a1, 0xa1, 0
    MOVA xo_a1, 0xa1, 1
    MOVA x_a2, 0xa2, 0
    MOVA xo_a2, 0xa2, 1
    MOVA x_a3, 0xa3, 0
    MOVA xo_a3, 0xa3, 1

/* ---------------- C6 C7: MOV r/m, imm (reg field 0) ---------------- */
.macro MOVIM lbl, w, ov
    .set xov, \ov
    .align 4
\lbl:
    l8ui a15, rPC, 1
    extui a12, a15, 3, 3
    BX1 bnez, a12, f
    extui a12, a15, 6, 2
    bnei a12, 3, .Lm\@
  .if \w == 16
    RMW a12, a15
    l8ui a13, rPC, 2
    l8ui a14, rPC, 3
    l8ui a15, rR, REC_CR
    slli a14, a14, 8
    or a13, a13, a14
    s16i a13, a12, F16A_R
    RETIRE 4
  .else
    RMB a12, a15
    l8ui a13, rPC, 2
    l8ui a15, rR, REC_CR
    s8i a13, a12, F16A_R
    RETIRE 3
  .endif
.Lm\@:
    EA
  .if \w == 16
    CHKW 0, b
  .else
    CHKB 0, b
  .endif
    add a13, a13, rRAM
    add a12, rPC, a14
    l8ui a0, a12, 0
  .if \w == 16
    l8ui a12, a12, 1
    s8i a0, a13, 0
    s8i a12, a13, 1
    addi a14, a14, 2
  .else
    s8i a0, a13, 0
    addi a14, a14, 1
  .endif
    l8ui a15, rR, REC_CM
    RETIRER a14
    .set xov, 0
.endm
    MOVIM x_c6, 8, 0
    MOVIM xo_c6, 8, 1
    MOVIM x_c7, 16, 0
    MOVIM xo_c7, 16, 1

/* ---------------- 8C: MOV r/m16, sreg (sreg 0..3) ---------------- */
.macro MOV8C lbl, ov
    .set xov, \ov
    .align 4
\lbl:
    l8ui a15, rPC, 1
    BX bbsi, a15, 5, f
    extui a12, a15, 6, 2
    bnei a12, 3, .Lm\@
    extui a13, a15, 3, 2
    addx2 a13, a13, rA
    l16ui a13, a13, F16A_SEG
    RMW a12, a15
    l8ui a15, rR, REC_CR
    s16i a13, a12, F16A_R
    RETIRE 2
.Lm\@:
    EA
    CHKW 0, b
    add a13, a13, rRAM
    extui a12, a15, 3, 2
    addx2 a12, a12, rA
    l16ui a12, a12, F16A_SEG
    l8ui a15, rR, REC_CM
    STW a13, a12, a0
    RETIRER a14
    .set xov, 0
.endm
    MOV8C x_8c, 0
    MOV8C xo_8c, 1

/* ---------------- 8E: MOV sreg, r/m16 (ES or DS); the segment cache as M_LOADSEG ---------------- */
.macro MOV8E lbl, ov
    .set xov, \ov
    .align 4
\lbl:
    l8ui a15, rPC, 1
    extui a12, a15, 3, 3
    beqz a12, 1f
    BX bnei, a12, 3, f
1:  extui a13, a15, 6, 2
    bnei a13, 3, .Lm\@
    RMW a13, a15
    l16ui a13, a13, F16A_R
    movi a14, 2
    MAINCLK a0, 0x8e, a12, 0
    j .Ld\@
    ISLAND
.Lm\@:
    EA
    CHKW 1, b
    add a13, a13, rRAM
    LDW a12, a13, a0
    mov a13, a12
    extui a12, a15, 3, 3
    MAINCLK a0, 0x8e, a12, 1
.Ld\@:
    add rPC, rPC, a14
    mov rR, a0
    LOADSEG a12, a13, a14, a15
    mov a15, rR
    RETIRE 0
    .set xov, 0
.endm
    MOV8E x_8e, 0
    MOV8E xo_8e, 1

/* ---------------- C4 C5: LES LDS (as the generic loop: offset at most FFFCh, the four bytes below A4000h) ---------------- */
.macro LXS lbl, sg, ov
    .set xov, \ov
    .align 4
\lbl:
    l8ui a15, rPC, 1
    extui a12, a15, 6, 2
    BX beqi, a12, 3, f
    EA
    movi a0, 0xfffc
    BX bltu, a0, a12, f
    movi a0, 0xa3ffc
    BX bltu, a0, a13, f
    add a13, a13, rRAM
    l8ui a0, rR, REC_CM
    add rPC, rPC, a14
    LDW a12, a13, rR
    addi a13, a13, 2
    LDW rR, a13, a14
    REGW a13, a15
    s16i a12, a13, F16A_R
    movi a14, \sg
    LOADSEG a14, rR, a12, a13
    mov a15, a0
    RETIRE 0
    .set xov, 0
.endm
    LXS x_c4, 0, 0
    LXS xo_c4, 0, 1
    LXS x_c5, 3, 0
    LXS xo_c5, 3, 1

/* ---------------- far transfers ---------------- */
/* push CS, then ret (register), as the generic loop's PUSHW pair; to the island d unless the four bytes are in RAM
 * below A0000h (SP 1..3: the generic loop). t u v scratch */
.macro FARPUSH ret, t, u, v, d
    l16ui \t, rA, F16A_R+8
    beqz \t, .Lok\@
    BX bltui, \t, 4, \d
.Lok\@:
    addi \t, \t, -4
    extui \t, \t, 0, 16
    l32i \u, rA, F16A_BASE+8
    add \u, \u, \t
    addi \v, \u, 3
    extui \v, \v, 17, 15
    BX bgeui, \v, 5, \d
    add \u, \u, rRAM
    s16i \t, rA, F16A_R+8
    STW \u, \ret, \v
    l16ui \v, rA, F16A_SEG+2
    addi \u, \u, 2
    STW \u, \v, \t
.endm
/* CS = a12 (selector), IP = a13, a15 clocks: retire. A target in RAM below A4000h stays in the loop with its code
 * window (M_CSWIN); any other one (ROM, the ITF bank, HMA) ends the batch and the generic loop sets the window. */
.macro FARGO
    movi a14, 1
    LOADSEG a14, a12, a0, rR, 0x9b
    slli a12, a12, 4
    add a14, rRAM, a12
    s32i a14, a1, FS_PCB
    add rPC, a14, a13
    movi a0, 0xa3ff6
    bltu a0, a12, .Lx\@
    addmi a0, rA, 0x500
    s32i a14, a0, MO(F16A_MOPCB)
    movi rR, 0
    s32i rR, a0, MO(F16A_MOROM)
    movi a0, 0xa3ff7
    sub a0, a0, a12
    movi rR, 0xfff0
    minu a0, a0, rR
    add rLIM, a14, a0
    RETIRE 0
.Lx\@:
    sub rREM, rREM, a15
    addi rN, rN, 1
    j f16x_exit
.endm
/* EA: JMP far ptr16:16 */
    .align 4
x_ea:
    l8ui a15, rR, REC_CR
    l8ui a13, rPC, 1
    l8ui a14, rPC, 2
    l8ui a12, rPC, 3
    l8ui a0, rPC, 4
    slli a14, a14, 8
    or a13, a13, a14
    slli a0, a0, 8
    or a12, a12, a0
    FARGO
/* 9A: CALL far ptr16:16 (the pointer read before the pushes: the stack may lie over the code) */
    .align 4
x_9a:
    l8ui a15, rR, REC_CR
    s32i a15, a1, FS_T2
    l8ui a12, rPC, 1
    l8ui a13, rPC, 2
    slli a13, a13, 8
    or a12, a12, a13
    l8ui rR, rPC, 3
    l8ui a13, rPC, 4
    slli a13, a13, 8
    or rR, rR, a13
    l32i a0, a1, FS_PCB
    sub a0, rPC, a0
    addi a0, a0, 5
    extui a0, a0, 0, 16
    FARPUSH a0, a13, a14, a15, f
    mov a13, a12
    mov a12, rR
    l32i a15, a1, FS_T2
    FARGO
/* CA CB: RETF (imm16) */
.macro RETF lbl, imm
    .align 4
\lbl:
    l8ui a15, rR, REC_CR
    l16ui a12, rA, F16A_R+8
    movi a0, 0xfffc
    bltu a0, a12, 98f
    l32i a13, rA, F16A_BASE+8
    add a13, a13, a12
    movi a0, 0xa3ffc
    bltu a0, a13, 98f
    add a13, a13, rRAM
  .if \imm
    l8ui a14, rPC, 1
    l8ui a0, rPC, 2
    slli a0, a0, 8
    or a14, a14, a0
    add a12, a12, a14
  .endif
    addi a12, a12, 4
    s16i a12, rA, F16A_R+8
    LDW rR, a13, a0
    addi a13, a13, 2
    LDW a12, a13, a0
    mov a13, rR
    FARGO
.endm
    RETF x_ca, 1
    RETF x_cb, 0

/* C2: RET imm16 */
    .align 4
x_c2:
    POPCHK
    LDW a14, a13, a0
    l8ui a13, rPC, 1
    l8ui a0, rPC, 2
    slli a0, a0, 8
    or a13, a13, a0
    addi a12, a12, 2
    add a12, a12, a13
    s16i a12, rA, F16A_R+8
    l32i a0, a1, FS_PCB
    l8ui a15, rR, REC_CR
    add rPC, a0, a14
    RETIRE 0

/* ---------------- FE: INC / DEC r/m8 ---------------- */
.macro GRPFE lbl, ov
    .set xov, \ov
    .align 4
\lbl:
    l8ui a15, rPC, 1
    extui a12, a15, 4, 2
    BX1 bnez, a12, f
    extui a12, a15, 6, 2
    bnei a12, 3, .Lm\@
    RMP a13, a15, 8, a12
    movi a14, 2
    l8ui a0, rR, REC_CR
    j .Lc\@
    ISLAND
.Lm\@:
    EA
    CHKB 0, b
    add a13, a13, rRAM
    l8ui a0, rR, REC_CM
.Lc\@:
    add rPC, rPC, a14
    l8ui a12, a13, 0
    bbsi a15, 3, 1f
    addi a14, a12, 1
    j 2f
1:  addi a14, a12, -1
2:  mov a15, a0
    s8i a14, a13, 0
    FLID 8, a12, a14, a13, a0
    RETIRE 0
    .set xov, 0
.endm
    GRPFE x_fe, 0
    GRPFE xo_fe, 1

/* ---------------- FF: INC DEC CALL JMP PUSH, CALL far / JMP far (memory) on r/m16 ---------------- */
.macro GRPFF lbl, ov
    .set xov, \ov
    .align 4
\lbl:
    l8ui a15, rPC, 1
    extui a12, a15, 3, 3
    BX beqi, a12, 7, f
    extui a13, a15, 6, 2
    bnei a13, 3, .Lm\@
    BX beqi, a12, 3, f
    BX beqi, a12, 5, f
    RMP a13, a15, 16, a14
    movi a14, 2
    MAINCLK a0, 0xff, a12, 0
    j .Lc\@
    ISLAND
.Lm\@:
    EA
    extui a0, a15, 3, 3
    beqi a0, 3, .Lfar\@
    beqi a0, 5, .Lfar\@
    extui a0, a15, 4, 2
    bnez a0, 1f
    CHKW 0, b
    j 2f
1:  CHKW 1, b
2:  add a13, a13, rRAM
    extui a12, a15, 3, 3
    MAINCLK a0, 0xff, a12, 1
.Lc\@:
    mov a15, a0                        /* clock */
    LDW a0, a13, rR                    /* operand */
    beqz a12, .Linc\@
    beqi a12, 1, .Ldec\@
    beqi a12, 2, .Lcall\@
    beqi a12, 4, .Ljmp\@
    /* 6: PUSH */
    l16ui a12, rA, F16A_R+8
    addi rR, a12, -2
    BX beqi, a12, 1, f
    extui a12, rR, 0, 16
    l32i a13, rA, F16A_BASE+8
    add a13, a13, a12
    addi rR, a13, 1
    extui rR, rR, 17, 15
    BX bgeui, rR, 5, f
    add a13, a13, rRAM
    STW a13, a0, rR
    s16i a12, rA, F16A_R+8
    add rPC, rPC, a14
    RETIRE 0
.Linc\@:
    addi a12, a0, 1
    j 1f
.Ldec\@:
    addi a12, a0, -1
1:  STW a13, a12, rR
    add rPC, rPC, a14
    FLID 16, a0, a12, a13, a14
    RETIRE 0
.Ljmp\@:
    l32i a12, a1, FS_PCB
    add rPC, a12, a0
    RETIRE 0
.Lcall\@:
    l16ui a12, rA, F16A_R+8
    addi rR, a12, -2
    BX beqi, a12, 1, f
    extui a12, rR, 0, 16
    l32i a13, rA, F16A_BASE+8
    add a13, a13, a12
    addi rR, a13, 1
    extui rR, rR, 17, 15
    BX bgeui, rR, 5, f
    add a13, a13, rRAM
    s16i a12, rA, F16A_R+8
    l32i a12, a1, FS_PCB
    sub rR, rPC, a12
    add rR, rR, a14
    extui rR, rR, 0, 16                /* return ip */
    add rPC, a12, a0
    STW a13, rR, a14
    RETIRE 0
.Lfar\@:                               /* 3 5: the pointer at the offset (at most FFFCh, below A4000h) */
    movi a0, 0xfffc
    BX bltu, a0, a12, b
    movi a0, 0xa3ffc
    BX bltu, a0, a13, b
    add a13, a13, rRAM
    extui a0, a15, 3, 3
    MAINCLK rR, 0xff, a0, 1
    s32i rR, a1, FS_T2
    LDW a12, a13, a0                   /* IP */
    addi a13, a13, 2
    LDW rR, a13, a0                    /* CS */
    bbci a15, 4, 3f
    l32i a0, a1, FS_PCB                /* 3: CALL far, the return address pushed */
    sub a0, rPC, a0
    add a0, a0, a14
    extui a0, a0, 0, 16
    FARPUSH a0, a13, a14, a15, b
3:  mov a13, a12
    mov a12, rR
    l32i a15, a1, FS_T2
    FARGO
    .set xov, 0
.endm
    GRPFF x_ff, 0
    GRPFF xo_ff, 1

/* ---------------- F6 / F7: TEST NOT NEG ---------------- */
.macro GRP3 lbl, op, B, ov
    .set xov, \ov
    .align 4
\lbl:
    l8ui a15, rPC, 1
    extui a12, a15, 3, 3
    movi a13, 0xf2
    BX bbs, a13, a12, f                /* 1 4 5 6 7: generic loop */
    extui a13, a15, 6, 2
    bnei a13, 3, .Lm\@
    RMP a13, a15, \B, a14
    movi a14, 2
    MAINCLK a0, \op, a12, 0
    j .Lc\@
    ISLAND
.Lm\@:
    EA
    bbsi a15, 4, 1f
  .if \B == 16
    CHKW 1, b
  .else
    CHKB 1, b
  .endif
    j 2f
1:
  .if \B == 16
    CHKW 0, b
  .else
    CHKB 0, b
  .endif
2:  add a13, a13, rRAM
    extui a12, a15, 3, 3
    MAINCLK a0, \op, a12, 1
.Lc\@:
    mov a15, a0
  .if \B == 16
    LDW a0, a13, rR
  .else
    l8ui a0, a13, 0
  .endif
    add rPC, rPC, a14
    beqz a12, 3f
    bbsi a12, 0, 4f
    /* 2: NOT */
    movi a12, -1
    xor a12, a12, a0
  .if \B == 16
    STW a13, a12, rR
  .else
    s8i a12, a13, 0
  .endif
    RETIRE 0
4:  /* 3: NEG */
    movi a14, 0
    ALUOP 5, \B, a12, a14, a0, rR
  .if \B == 16
    STW a13, a12, rR
  .else
    s8i a12, a13, 0
  .endif
    RETIRE 0
3:  /* 0: TEST imm */
    l8ui a12, rPC, 0
  .if \B == 16
    l8ui a14, rPC, 1
    slli a14, a14, 8
    or a12, a12, a14
    addi rPC, rPC, 2
  .else
    addi rPC, rPC, 1
  .endif
    and a12, a12, a0
    FLOG \B, a12, a14
    RETIRE 0
    .set xov, 0
.endm
    GRP3 x_f6, 0xf6, 8, 0
    GRP3 xo_f6, 0xf6, 8, 1
    GRP3 x_f7, 0xf7, 16, 0
    GRP3 xo_f7, 0xf7, 16, 1

/* ---------------- D0 / D1: shift / rotate by 1 ---------------- */
/* r = a12 from v = a0; a14 rR scratch */
.macro SH1 op, B
  .if \op == 0
    slli a12, a0, 1
    extui a14, a0, \B-1, 1
    or a12, a12, a14
    extui a12, a12, 0, \B
    extui a14, a12, 0, 1
    extui rR, a12, \B-1, 1
    xor rR, rR, a14
    ROTFL a14, rR
  .elseif \op == 1
    srli a12, a0, 1
    slli a14, a0, \B-1
    or a12, a12, a14
    extui a12, a12, 0, \B
    extui a14, a12, \B-1, 1
    extui rR, a12, \B-2, 1
    xor rR, rR, a14
    ROTFL a14, rR
  .elseif \op == 2
    extui a14, rLV, 16, 1
    slli a12, a0, 1
    or a12, a12, a14
    extui a12, a12, 0, \B
    extui a14, a0, \B-1, 1
    extui rR, a12, \B-1, 1
    xor rR, rR, a14
    ROTFL a14, rR
  .elseif \op == 3
    extui a14, rLV, 16, 1
    slli a14, a14, \B-1
    srli a12, a0, 1
    or a12, a12, a14
    extui a14, a0, 0, 1
    extui rR, a12, \B-1, 1
    extui a0, a12, \B-2, 1
    xor rR, rR, a0
    ROTFL a14, rR
  .elseif \op == 4
    slli a12, a0, 1
    extui a12, a12, 0, \B
    extui a14, a0, \B-1, 1
    extui rR, a12, \B-1, 1
    xor rR, rR, a14
    ROTFL a14, rR
    sext rLR, a12, \B-1
  .elseif \op == 5
    srli a12, a0, 1
    extui a14, a0, 0, 1
    extui rR, a0, \B-1, 1
    ROTFL a14, rR
    sext rLR, a12, \B-1
  .else
    srli a12, a0, 1
    extui a14, a0, \B-1, 1
    slli a14, a14, \B-1
    or a12, a12, a14
    extui a14, a0, 0, 1
    movi rR, 0
    ROTFL a14, rR
    sext rLR, a12, \B-1
  .endif
.endm
.macro SHIFT1 lbl, op, B, ov
    .set xov, \ov
    .align 4
\lbl:
    l8ui a15, rPC, 1
    extui a12, a15, 3, 3
    BX beqi, a12, 6, f
    extui a13, a15, 6, 2
    bnei a13, 3, .Lm\@
    /* register form: a13 = A + register offset, a0 value */
  .if \B == 16
    RMW a13, a15
    l16ui a0, a13, F16A_R
  .else
    RMB a13, a15
    l8ui a0, a13, F16A_R
  .endif
    l8ui a15, rR, REC_CR
    addi rPC, rPC, 2
    JT8 a12, a14, \lbl\()_rops
  .irp k, 0, 1, 2, 3, 4, 5, 7
2\k:
    SH1 \k, \B
    .if \B == 16
    s16i a12, a13, F16A_R
    .else
    s8i a12, a13, F16A_R
    .endif
    RETIRE 0
  .endr
26: j f16x_exit
.Lm\@:
    EA
  .if \B == 16
    CHKW 0, b
  .else
    CHKB 0, b
  .endif
    add a13, a13, rRAM
    extui a12, a15, 3, 3
    l8ui a15, rR, REC_CM
    add rPC, rPC, a14
  .if \B == 16
    LDW a0, a13, a14
  .else
    l8ui a0, a13, 0
  .endif
    JT8 a12, a14, \lbl\()_mops
  .irp k, 0, 1, 2, 3, 4, 5, 7
2\k:
    SH1 \k, \B
    .if \B == 16
    STW a13, a12, a14
    .else
    s8i a12, a13, 0
    .endif
    RETIRE 0
  .endr
26: j f16x_exit
    .set xov, 0
.endm
    SHIFT1 x_d0, 0xd0, 8, 0
    SHIFT1 xo_d0, 0xd0, 8, 1
    SHIFT1 x_d1, 0xd1, 16, 0
    SHIFT1 xo_d1, 0xd1, 16, 1

/* ---------------- port I/O: E4-E7 EC-EF (as fast16_mini.inc m_io; f16x_in / f16x_out publish FLAGS and the clock) ---------------- */
    .align 4
x_e4:
x_e5:
x_e6:
x_e7:
x_ec:
x_ed:
x_ee:
x_ef:
    l8ui a12, rPC, 0
    l32i a0, rA, F16A_SLICEP
    beqz a0, 98f
    bbsi a12, 3, 1f
    l8ui a13, rPC, 1                   /* port imm8, length 2 */
    movi a14, 2
    j 2f
1:  l16ui a13, rA, F16A_R+4            /* port DX, length 1 */
    movi a14, 1
2:  movi a15, 0xf0
    sub a15, a13, a15
    bltui a15, 8, 98f                  /* F0..F7: CPU reset / A20 */
    s32i rN, a1, FS_NRET
    s32i rLV, a1, FS_LV
    s32i a14, a1, FS_T1
    s32i a12, a1, FS_T3
    l8ui a15, rR, REC_CR
    s32i a15, a1, FS_T2
    MATFL a15, a0, rR
    addmi a0, rA, 0x500
    l32i a0, a0, MO(F16A_MOOFF)
    add a0, rREM, a0                   /* the clock left before this instruction, as the bus sees it */
    extui rR, a12, 0, 1                /* word */
    bbsi a12, 1, 3f
    /* IN: f16x_in(A, port, wide, fl, remv) */
    mov a14, a0
    mov a0, a13
    mov a13, a15
    mov a12, rR
    mov a11, a0
    mov a10, rA
    movi a15, f16x_in
    callx8 a15
    l32i a12, a1, FS_T3
    bbsi a12, 0, 5f
    s8i a10, rA, F16A_R
    j 4f
5:  s16i a10, rA, F16A_R
    j 4f
3:  /* OUT: f16x_out(A, port, wide, AX, fl, remv) */
    mov a14, a15
    mov a15, a0
    mov a12, rR
    mov a11, a13
    l16ui a13, rA, F16A_R
    mov a10, rA
    movi a0, f16x_out
    callx8 a0
4:  l32i rRAM, a1, FS_RAM
    l32i rN, a1, FS_NRET
    l32i rLV, a1, FS_LV
    l32i a14, a1, FS_T1
    l32i a0, rA, F16A_SLICEP
    l32i a0, a0, 0
    addmi a13, rA, 0x500
    l32i a12, a13, MO(F16A_MOOFF)
    sub rREM, a0, a12                  /* devices may retarget the clock */
    l32i a15, a1, FS_T2
    l32i a12, a1, FS_T3
    bbci a12, 1, 6f
    l32i a12, a13, MO(F16A_MOROM)
    beqz a12, 6f
    /* a port write while running from ROM may switch the ITF bank: retire, then look at the code window again */
    sub rREM, rREM, a15
    add rPC, rPC, a14
    addi rN, rN, 1
    j f16x_exit
6:  RETIRER a14

    .set xov, 0
    ISLAND
    .size f16x_start, . - f16x_start

/* ---------------- tables ---------------- */
/* EA stub by ModR/M (00-BF) */
    .section .dram1.f16x_eat, "aw"
    .align 4
    .global f16x_eat
f16x_eat:
  .irp mod, 0, 1, 2
    .rept 8
    .word x_ea_\mod\()0, x_ea_\mod\()1, x_ea_\mod\()2, x_ea_\mod\()3, x_ea_\mod\()4, x_ea_\mod\()5, x_ea_\mod\()6, x_ea_\mod\()7
    .endr
  .endr

/* handlers by opcode (0: none here): plain, and after a segment prefix */
.macro HROW p, hi
  .irp lo, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, a, b, c, d, e, f
    .ifdef \p\hi\lo
    .word \p\hi\lo
    .else
    .word 0
    .endif
  .endr
.endm
    .section .rodata.f16x_h, "a"
    .align 4
    .global f16x_hdef
f16x_hdef:
  .irp hi, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, a, b, c, d, e, f
    HROW x_, \hi
  .endr
    .global f16x_hov
f16x_hov:
  .irp hi, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, a, b, c, d, e, f
    HROW xo_, \hi
  .endr
