/* SPDX-License-Identifier: MIT
 * Copyright (c) mochimochi-man / Uh
 * fast16 mini loop, RISC-V assembly handlers (stage 19). Same contract as fast16_mini.inc, which stays the
 * reference (host builds, opcodes not written here):
 *  - a handler is entered with the C mini-handler arguments and leaves them the same way, so assembly and C
 *    handlers share one dispatch table and jump into each other freely:
 *        a0 A   a1 pc (host pointer to the opcode)   a2 rem   a3 fl   a4 lim   a5 nret   a6 tab   a7 ram
 *  - f16a_start (called instead of m_start) saves s0-s11 and loads the constants below; C handlers keep them
 *    (callee-saved), so they stay valid across the whole batch. ra is never touched: every exit returns to f16a_start.
 *        s0 FFFFh            s1 f16a_tabs (flag / byte-register tables, fast16_rv.h)
 *        s2 9FFFFh (last+1 start of a RAM word write; byte write ok while <= s2)
 *        s3 A3FFFh (same for reads)                s4 C0h (ModR/M register form)
 *        s5 f16a_eat (ModR/M -> EA stub)           s6 ~ARITH (8D5h)   s8 ~(CF PF ZF SF OF)
 *        s9 8000h            s10 800h (OF)        s7, s11, t0-t6: scratch
 *  - t6 holds the next handler when a handler fetched it early (PREF / PREFR, then RETIREP). Only handlers that write
 *    no memory do that: a write may change the next opcode byte.
 *  - a hand-back happens before any side effect: f16a_exit (pc at the opcode) or f16a_bail_ov (pc after a prefix)
 *  - EA (macro, no branches: f16a_eat[] has one 16-byte entry per ModR/M 00-BF): in t5 = ModR/M (< C0h);
 *    out t1 = offset, t2 = instruction length (opcode+modrm+disp), t3 = linear address; t0 t4 scratch. */
#include "fast16_rv.h"

/* ---------------- dispatch ---------------- */
.macro DISPATCH
    lbu t6, 0(a1)
    slli t6, t6, 2
    add t6, t6, a6
    lw t6, 0(t6)
    jr t6
.endm
/* Exit islands. f16a_exit is far from most handlers, and a conditional branch out of its +-4 KB range is assembled as
 * an inverted branch over a jump, i.e. a branch taken on every instruction. So every RETIRE / RETIREP is followed by
 * "98: j f16a_exit" (and "97: j f16a_bail_ov" inside handlers entered after a prefix, f16a_ovc = 1), and every
 * hand-back branch is a short forward branch to the next of these (BX / BRB), not taken in the normal case. */
    .set f16a_ovc, 0
.macro ISLAND
98: j f16a_exit
  .if f16a_ovc
97: j f16a_bail_ov
  .endif
.endm
/* hand-back branch: insn r1, r2 (or insn r1 for the one-operand forms) to the exit / prefix exit island */
.macro BX insn, r1, r2
  .ifb \r2
    \insn \r1, 98f
  .else
    \insn \r1, \r2, 98f
  .endif
.endm
.macro BRB insn, r1, r2
  .if f16a_ovc
    \insn \r1, \r2, 97f
  .else
    \insn \r1, \r2, 98f
  .endif
.endm
/* retire: pc already advanced; debit clk (register), count, continue unless the batch is over */
.macro RETIRE clk
    sub a2, a2, \clk
    addi a5, a5, 1
    TRACE
    blez a2, 98f
    bgeu a1, a4, 98f
    DISPATCH
    ISLAND
.endm
/* the next handler, fetched early: t6 = tab[pc[nb]] (nb immediate / register) */
.macro PREF nb
    lbu t6, \nb(a1)
    slli t6, t6, 2
    add t6, t6, a6
    lw t6, 0(t6)
.endm
.macro PREFR nb
    add t6, a1, \nb
    lbu t6, 0(t6)
    slli t6, t6, 2
    add t6, t6, a6
    lw t6, 0(t6)
.endm
/* retire with t6 from PREF: advance pc by nb (immediate, or a register when reg = 1) */
.macro RETIREP clk, nb, reg=0
    sub a2, a2, \clk
  .if \reg
    add a1, a1, \nb
  .else
    addi a1, a1, \nb
  .endif
    addi a5, a5, 1
    TRACE
    blez a2, 98f
    bgeu a1, a4, 98f
    jr t6
    ISLAND
.endm

/* ---------------- write hook (the differential test records every RAM write before it happens) ---------------- */
#ifdef PC98_FAST16_WRITE_HOOK
.macro HOOK1 ptr, val, add
    addi sp, sp, -80
    sw ra, 0(sp)
    sw t0, 4(sp)
    sw t1, 8(sp)
    sw t2, 12(sp)
    sw t3, 16(sp)
    sw t4, 20(sp)
    sw t5, 24(sp)
    sw t6, 28(sp)
    sw a0, 32(sp)
    sw a1, 36(sp)
    sw a2, 40(sp)
    sw a3, 44(sp)
    sw a4, 48(sp)
    sw a5, 52(sp)
    sw a6, 56(sp)
    sw a7, 60(sp)
    sub a0, \ptr, a7
  .if \add
    addi a0, a0, 1
    srli a1, \val, 8
  .else
    mv a1, \val
  .endif
    andi a1, a1, 255
    call PC98_FAST16_WRITE_HOOK
    lw ra, 0(sp)
    lw t0, 4(sp)
    lw t1, 8(sp)
    lw t2, 12(sp)
    lw t3, 16(sp)
    lw t4, 20(sp)
    lw t5, 24(sp)
    lw t6, 28(sp)
    lw a0, 32(sp)
    lw a1, 36(sp)
    lw a2, 40(sp)
    lw a3, 44(sp)
    lw a4, 48(sp)
    lw a5, 52(sp)
    lw a6, 56(sp)
    lw a7, 60(sp)
    addi sp, sp, 80
.endm
/* differential test only: the pc after every instruction retired here (t_trace) */
.macro TRACE
    addi sp, sp, -80
    sw ra, 0(sp)
    sw t0, 4(sp)
    sw t1, 8(sp)
    sw t2, 12(sp)
    sw t3, 16(sp)
    sw t4, 20(sp)
    sw t5, 24(sp)
    sw t6, 28(sp)
    sw a0, 32(sp)
    sw a1, 36(sp)
    sw a2, 40(sp)
    sw a3, 44(sp)
    sw a4, 48(sp)
    sw a5, 52(sp)
    sw a6, 56(sp)
    sw a7, 60(sp)
    mv a0, a1
    call t_trace
    lw ra, 0(sp)
    lw t0, 4(sp)
    lw t1, 8(sp)
    lw t2, 12(sp)
    lw t3, 16(sp)
    lw t4, 20(sp)
    lw t5, 24(sp)
    lw t6, 28(sp)
    lw a0, 32(sp)
    lw a1, 36(sp)
    lw a2, 40(sp)
    lw a3, 44(sp)
    lw a4, 48(sp)
    lw a5, 52(sp)
    lw a6, 56(sp)
    lw a7, 60(sp)
    addi sp, sp, 80
.endm
#else
.macro HOOK1 ptr, val, add
.endm
.macro TRACE
.endm
#endif
/* RAM stores through a host pointer (no alignment assumed) */
.macro STB ptr, val
    HOOK1 \ptr, \val, 0
    sb \val, 0(\ptr)
.endm
.macro STW ptr, val, tmp
    HOOK1 \ptr, \val, 0
    HOOK1 \ptr, \val, 1
    sb \val, 0(\ptr)
    srli \tmp, \val, 8
    sb \tmp, 1(\ptr)
.endm
.macro LDW dst, ptr, tmp
    lbu \dst, 0(\ptr)
    lbu \tmp, 1(\ptr)
    slli \tmp, \tmp, 8
    or \dst, \dst, \tmp
.endm

/* ---------------- flags (bit-exact with fast16.c f_add16 ... f_log8) ---------------- */
/* u |= PF ZF SF of the word r */
.macro FPZS16 r, u, v, w
    andi \v, \r, 255
    add \v, \v, s1
    lbu \v, F16A_T_LO(\v)
    srli \w, \r, 8
    add \w, \w, s1
    lbu \w, F16A_T_HI(\w)
    and \v, \v, \w
    or \u, \u, \v
.endm
/* r = x + y (+ CF); r u v w distinct from x y */
.macro FADD16 r, x, y, u, v, w, c
    add \r, \x, \y
  .if \c
    andi \u, a3, 1
    add \r, \r, \u
  .endif
    srli \u, \r, 16
    and \r, \r, s0
    xor \v, \x, \r
    xor \w, \v, \y
    andi \w, \w, 16
    or \u, \u, \w
    xor \w, \y, \r
    and \w, \v, \w
    srli \w, \w, 4
    and \w, \w, s10
    or \u, \u, \w
    FPZS16 \r, \u, \v, \w
    and a3, a3, s6
    or a3, a3, \u
.endm
.macro FSUB16 r, x, y, u, v, w, c
    sub \r, \x, \y
  .if \c
    andi \u, a3, 1
    sub \r, \r, \u
  .endif
    srli \u, \r, 16
    andi \u, \u, 1
    and \r, \r, s0
    xor \v, \x, \r
    xor \w, \v, \y
    andi \w, \w, 16
    or \u, \u, \w
    xor \w, \x, \y
    and \w, \v, \w
    srli \w, \w, 4
    and \w, \w, s10
    or \u, \u, \w
    FPZS16 \r, \u, \v, \w
    and a3, a3, s6
    or a3, a3, \u
.endm
.macro FLOG16 r, u, v
    andi \u, \r, 255
    add \u, \u, s1
    lbu \u, F16A_T_LO(\u)
    srli \v, \r, 8
    add \v, \v, s1
    lbu \v, F16A_T_HI(\v)
    and \u, \u, \v
    and a3, a3, s8
    or a3, a3, \u
.endm
.macro FADD8 r, x, y, u, v, w, c
    add \r, \x, \y
  .if \c
    andi \u, a3, 1
    add \r, \r, \u
  .endif
    srli \u, \r, 8
    andi \r, \r, 255
    xor \v, \x, \r
    xor \w, \v, \y
    andi \w, \w, 16
    or \u, \u, \w
    xor \w, \y, \r
    and \w, \v, \w
    slli \w, \w, 4
    and \w, \w, s10
    or \u, \u, \w
    add \v, \r, s1
    lbu \v, F16A_T_SZP8(\v)
    or \u, \u, \v
    and a3, a3, s6
    or a3, a3, \u
.endm
.macro FSUB8 r, x, y, u, v, w, c
    sub \r, \x, \y
  .if \c
    andi \u, a3, 1
    sub \r, \r, \u
  .endif
    srli \u, \r, 8
    andi \u, \u, 1
    andi \r, \r, 255
    xor \v, \x, \r
    xor \w, \v, \y
    andi \w, \w, 16
    or \u, \u, \w
    xor \w, \x, \y
    and \w, \v, \w
    slli \w, \w, 4
    and \w, \w, s10
    or \u, \u, \w
    add \v, \r, s1
    lbu \v, F16A_T_SZP8(\v)
    or \u, \u, \v
    and a3, a3, s6
    or a3, a3, \u
.endm
.macro FLOG8 r, u
    add \u, \r, s1
    lbu \u, F16A_T_SZP8(\u)
    and a3, a3, s8
    or a3, a3, \u
.endm
/* ALU operation aop (0 ADD 1 OR 2 ADC 3 SBB 4 AND 5 SUB 6 XOR 7 CMP): r = x op y, flags */
.macro ALU16 aop, r, x, y, u, v, w
  .if \aop == 0
    FADD16 \r, \x, \y, \u, \v, \w, 0
  .elseif \aop == 1
    or \r, \x, \y
    FLOG16 \r, \u, \v
  .elseif \aop == 2
    FADD16 \r, \x, \y, \u, \v, \w, 1
  .elseif \aop == 3
    FSUB16 \r, \x, \y, \u, \v, \w, 1
  .elseif \aop == 4
    and \r, \x, \y
    FLOG16 \r, \u, \v
  .elseif \aop == 6
    xor \r, \x, \y
    FLOG16 \r, \u, \v
  .else
    FSUB16 \r, \x, \y, \u, \v, \w, 0
  .endif
.endm
.macro ALU8 aop, r, x, y, u, v, w
  .if \aop == 0
    FADD8 \r, \x, \y, \u, \v, \w, 0
  .elseif \aop == 1
    or \r, \x, \y
    FLOG8 \r, \u
  .elseif \aop == 2
    FADD8 \r, \x, \y, \u, \v, \w, 1
  .elseif \aop == 3
    FSUB8 \r, \x, \y, \u, \v, \w, 1
  .elseif \aop == 4
    and \r, \x, \y
    FLOG8 \r, \u
  .elseif \aop == 6
    xor \r, \x, \y
    FLOG8 \r, \u
  .else
    FSUB8 \r, \x, \y, \u, \v, \w, 0
  .endif
.endm

/* ---------------- ModR/M ---------------- */
/* memory operand: t5 = ModR/M (< C0h) -> t1 offset, t2 length, t3 linear address (default or override segment).
 * Entry (fast16_rv.h F16A_E_*): two register offsets (the zero halfword A->mz when absent), the segment base offset,
 * the length, and byte masks (0 / FFh, sign-extended) selecting the 8-bit and the 16-bit displacement. */
#if F16A_EATAB
.macro EA ov
    slli t0, t5, 4
    add t0, t0, s5
    lhu t1, F16A_E_O1(t0)
    lhu t3, F16A_E_O2(t0)
    add t1, t1, a0
    add t3, t3, a0
    lhu t1, 0(t1)
    lhu t3, 0(t3)
    lbu t2, 2(a1)
    lbu t4, 3(a1)
    add t1, t1, t3
    slli t4, t4, 8
    or t4, t4, t2
    lb t3, F16A_E_MK16(t0)
    lb t2, 2(a1)
    and t4, t4, t3
    lb t3, F16A_E_MK8(t0)
    add t1, t1, t4
    and t2, t2, t3
    add t1, t1, t2
    and t1, t1, s0
  .if \ov
    lw t3, F16A_MOOV(a0)
  .else
    lhu t3, F16A_E_BO(t0)
  .endif
    add t3, t3, a0
    lw t3, 0(t3)
    lbu t2, F16A_E_NB(t0)
    add t3, t3, t1
.endm
#else
/* stub form: f16a_eat[ModR/M] = code address of a stub for (mod, rm), called with jalr t0 */
.macro EA ov
    slli t1, t5, 2
    add t1, t1, s5
    lw t1, 0(t1)
    jalr t0, t1
  .if \ov
    lw t3, F16A_MOOV(a0)
    add t3, t3, a0
    lw t3, 0(t3)
  .endif
    add t3, t3, t1
.endm
#endif
/* pointer (A + 2*index) of the reg field word register */
.macro REGW dst, m
    srli \dst, \m, 2
    andi \dst, \dst, 14
    add \dst, \dst, a0
.endm
/* pointer of the r/m field word register */
.macro RMW dst, m
    andi \dst, \m, 7
    slli \dst, \dst, 1
    add \dst, \dst, a0
.endm
/* pointer of the reg field byte register */
.macro REGB dst, m
    add \dst, s1, \m
    lbu \dst, F16A_T_M8(\dst)
    srli \dst, \dst, 4
    add \dst, \dst, a0
.endm

    .section .iram1.f16a, "ax"
    .align 2

/* unsigned f16a_start(MARGS): run the threaded handlers from tab[*pc] until one returns */
    .globl f16a_start
    .type f16a_start, @function
f16a_start:
    addi sp, sp, -64
    sw ra, 60(sp)
    sw s0, 56(sp)
    sw s1, 52(sp)
    sw s2, 48(sp)
    sw s3, 44(sp)
    sw s4, 40(sp)
    sw s5, 36(sp)
    sw s6, 32(sp)
    sw s7, 28(sp)
    sw s8, 24(sp)
    sw s9, 20(sp)
    sw s10, 16(sp)
    sw s11, 12(sp)
    li s0, 0xffff
    la s1, f16a_tabs
    li s2, 0x9ffff
    li s3, 0xa3fff
    li s4, 0xc0
    la s5, f16a_eat
    li s6, ~0x8d5
    li s8, ~0x8c5
    li s9, 0x8000
    li s10, 0x800
    lbu t6, 0(a1)
    slli t6, t6, 2
    add t6, t6, a6
    lw t6, 0(t6)
    jalr ra, t6
    lw ra, 60(sp)
    lw s0, 56(sp)
    lw s1, 52(sp)
    lw s2, 48(sp)
    lw s3, 44(sp)
    lw s4, 40(sp)
    lw s5, 36(sp)
    lw s6, 32(sp)
    lw s7, 28(sp)
    lw s8, 24(sp)
    lw s9, 20(sp)
    lw s10, 16(sp)
    lw s11, 12(sp)
    addi sp, sp, 64
    ret
    .size f16a_start, . - f16a_start

/* hand back (same as C m_exit): store the exit state, return 0 to f16a_start */
    .globl f16a_exit
    .type f16a_exit, @function
f16a_exit:
    lw t0, F16A_MOPCB(a0)
    sub t0, a1, t0
    sw t0, F16A_MOIP(a0)
    sw a2, F16A_MOREM(a0)
    sw a3, F16A_MOFL(a0)
    sw a5, F16A_MONRET(a0)
    li a0, 0
    ret
    .size f16a_exit, . - f16a_exit
/* hand back from a handler entered after a segment-override prefix: pc goes back to the prefix */
f16a_bail_ov:
    addi a1, a1, -1
    j f16a_exit
#if !F16A_EATAB
/* ---------------- EA stubs (stub form of EA): out t1 offset, t2 length, t3 default segment base; t4 scratch ---------------- */
.macro EASTUB mod, rm
    .align 1
f16a_ea_\mod\rm:
  .if (\mod == 0) && (\rm == 6)
    lbu t1, 2(a1)
    lbu t4, 3(a1)
    slli t4, t4, 8
    or t1, t1, t4
    lw t3, F16A_BASE+12(a0)
    li t2, 4
    jr t0
  .else
    .if (\rm == 0) || (\rm == 1) || (\rm == 7)
    lhu t1, F16A_R+6(a0)
    .elseif (\rm == 2) || (\rm == 3) || (\rm == 6)
    lhu t1, F16A_R+10(a0)
    .elseif \rm == 4
    lhu t1, F16A_R+12(a0)
    .else
    lhu t1, F16A_R+14(a0)
    .endif
    .if \rm < 4
    lhu t4, F16A_R+12+2*(\rm & 1)(a0)
    add t1, t1, t4
    .endif
    .if \mod == 1
    lb t4, 2(a1)
    add t1, t1, t4
    .elseif \mod == 2
    lbu t4, 2(a1)
    add t1, t1, t4
    lbu t4, 3(a1)
    slli t4, t4, 8
    add t1, t1, t4
    .endif
    .if (\mod != 0) || (\rm < 4)
    and t1, t1, s0
    .endif
    .if (\rm == 2) || (\rm == 3) || (\rm == 6)
    lw t3, F16A_BASE+8(a0)
    .else
    lw t3, F16A_BASE+12(a0)
    .endif
    li t2, 2+\mod
    jr t0
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
    .section .rodata.f16a_ea24, "a"
    .align 2
    .globl f16a_ea24
f16a_ea24:
    .word f16a_ea_00, f16a_ea_01, f16a_ea_02, f16a_ea_03, f16a_ea_04, f16a_ea_05, f16a_ea_06, f16a_ea_07
    .word f16a_ea_10, f16a_ea_11, f16a_ea_12, f16a_ea_13, f16a_ea_14, f16a_ea_15, f16a_ea_16, f16a_ea_17
    .word f16a_ea_20, f16a_ea_21, f16a_ea_22, f16a_ea_23, f16a_ea_24, f16a_ea_25, f16a_ea_26, f16a_ea_27
    .section .iram1.f16a, "ax"
#endif

/* tail-jump to a C handler (the slow cases the assembly does not do), index k of f16a_cfb[] */
.macro CFALLBACK k
    la t6, f16a_cfb
    lw t6, 4*\k(t6)
    jr t6
.endm

/* ---------------- ALU r/m,r  r,r/m (00-3B) ----------------
 * form bit0 = word, bit1 = reg is the destination. CMP (aop 7) writes nothing. */
.macro ALU_RM name, op, aop, form, ov
    .set f16a_ovc, \ov
    .align 1
    .globl \name
\name:
    lbu t5, 1(a1)
    bgeu t5, s4, 5f
    EA \ov
  .if \form & 1
    BRB beq, t1, s0
    .if (\form & 2) || (\aop == 7)
    BRB bgeu, t3, s3
    .else
    BRB bgeu, t3, s2
    .endif
    add t4, a7, t3
    LDW t1, t4, t3
    REGW t0, t5
    lhu s7, F16A_R(t0)
    .if (\form & 2) || (\aop == 7)
    PREFR t2
    .endif
    .if \form & 2
    ALU16 \aop, s11, s7, t1, t3, t4, t5
      .if \aop != 7
    sh s11, F16A_R(t0)
      .endif
    .else
    ALU16 \aop, s11, t1, s7, t0, t3, t5
      .if \aop != 7
    STW t4, s11, t3
      .endif
    .endif
  .else
    .if (\form & 2) || (\aop == 7)
    BRB bltu, s3, t3
    .else
    BRB bltu, s2, t3
    .endif
    add t4, a7, t3
    lbu t1, 0(t4)
    REGB t0, t5
    lbu s7, F16A_R(t0)
    .if (\form & 2) || (\aop == 7)
    PREFR t2
    .endif
    .if \form & 2
    ALU8 \aop, s11, s7, t1, t3, t4, t5
      .if \aop != 7
    sb s11, F16A_R(t0)
      .endif
    .else
    ALU8 \aop, s11, t1, s7, t0, t3, t5
      .if \aop != 7
    STB t4, s11
      .endif
    .endif
  .endif
    lbu t1, F16A_MCKM+2*\op+1(a0)
  .if (\form & 2) || (\aop == 7)
    RETIREP t1, t2, 1
  .else
    add a1, a1, t2
    RETIRE t1
  .endif
5:  PREF 2
  .if \form & 1
    RMW t1, t5
    lhu t3, F16A_R(t1)
    REGW t2, t5
    lhu t4, F16A_R(t2)
    .if \form & 2
    ALU16 \aop, s11, t4, t3, t0, t5, s7
      .if \aop != 7
    sh s11, F16A_R(t2)
      .endif
    .else
    ALU16 \aop, s11, t3, t4, t0, t5, s7
      .if \aop != 7
    sh s11, F16A_R(t1)
      .endif
    .endif
  .else
    add t0, s1, t5
    lbu t0, F16A_T_M8(t0)
    andi t1, t0, 15
    srli t2, t0, 4
    add t1, t1, a0
    add t2, t2, a0
    lbu t3, F16A_R(t1)
    lbu t4, F16A_R(t2)
    .if \form & 2
    ALU8 \aop, s11, t4, t3, t0, t5, s7
      .if \aop != 7
    sb s11, F16A_R(t2)
      .endif
    .else
    ALU8 \aop, s11, t3, t4, t0, t5, s7
      .if \aop != 7
    sb s11, F16A_R(t1)
      .endif
    .endif
  .endif
    lbu t1, F16A_MCKM+2*\op(a0)
    RETIREP t1, 2
    .set f16a_ovc, 0
.endm
.macro ALU_ROW base, aop
    ALU_RM f16a_\base\()0, 0x\base\()0, \aop, 0, 0
    ALU_RM f16a_\base\()1, 0x\base\()1, \aop, 1, 0
    ALU_RM f16a_\base\()2, 0x\base\()2, \aop, 2, 0
    ALU_RM f16a_\base\()3, 0x\base\()3, \aop, 3, 0
.endm
.macro ALU_ROW8 base, aop
    ALU_RM f16a_\base\()8, 0x\base\()8, \aop, 0, 0
    ALU_RM f16a_\base\()9, 0x\base\()9, \aop, 1, 0
    ALU_RM f16a_\base\()a, 0x\base\()a, \aop, 2, 0
    ALU_RM f16a_\base\()b, 0x\base\()b, \aop, 3, 0
.endm
    ALU_ROW 0, 0
    ALU_ROW8 0, 1
    ALU_ROW 1, 2
    ALU_ROW8 1, 3
    ALU_ROW 2, 4
    ALU_ROW8 2, 5
    ALU_ROW 3, 6
    ALU_ROW8 3, 7

/* ---------------- ALU AL/AX, imm ---------------- */
.macro ALU_ACC name, op, aop
    .align 1
    .globl \name
\name:
  .if (\op & 1) == 0
    PREF 2
    lbu t1, F16A_R(a0)
    lbu t2, 1(a1)
    ALU8 \aop, t3, t1, t2, t4, t5, s7
    .if \aop != 7
    sb t3, F16A_R(a0)
    .endif
    lbu t1, F16A_MCKN+\op(a0)
    RETIREP t1, 2
  .else
    PREF 3
    lhu t1, F16A_R(a0)
    lbu t2, 1(a1)
    lbu t3, 2(a1)
    slli t3, t3, 8
    or t2, t2, t3
    ALU16 \aop, t3, t1, t2, t4, t5, s7
    .if \aop != 7
    sh t3, F16A_R(a0)
    .endif
    lbu t1, F16A_MCKN+\op(a0)
    RETIREP t1, 3
  .endif
.endm
    ALU_ACC f16a_04, 0x04, 0
    ALU_ACC f16a_05, 0x05, 0
    ALU_ACC f16a_0c, 0x0c, 1
    ALU_ACC f16a_0d, 0x0d, 1
    ALU_ACC f16a_14, 0x14, 2
    ALU_ACC f16a_15, 0x15, 2
    ALU_ACC f16a_1c, 0x1c, 3
    ALU_ACC f16a_1d, 0x1d, 3
    ALU_ACC f16a_24, 0x24, 4
    ALU_ACC f16a_25, 0x25, 4
    ALU_ACC f16a_2c, 0x2c, 5
    ALU_ACC f16a_2d, 0x2d, 5
    ALU_ACC f16a_34, 0x34, 6
    ALU_ACC f16a_35, 0x35, 6
    ALU_ACC f16a_3c, 0x3c, 7
    ALU_ACC f16a_3d, 0x3d, 7

/* ---------------- INC / DEC r16 (CF kept) ---------------- */
.macro INCDEC i, dec
    .align 1
  .if \dec
    .globl f16a_dec\i
f16a_dec\i:
  .else
    .globl f16a_inc\i
f16a_inc\i:
  .endif
    PREF 1
    lhu t1, F16A_R+2*\i(a0)
  .if \dec
    addi t2, t1, -1
  .else
    addi t2, t1, 1
  .endif
    and t2, t2, s0
    sh t2, F16A_R+2*\i(a0)
    xor t3, t1, t2
    andi t3, t3, 16
  .if \dec
    xor t4, t1, s9
  .else
    xor t4, t2, s9
  .endif
    seqz t4, t4
    slli t4, t4, 11
    or t3, t3, t4
    FPZS16 t2, t3, t4, t5
    ori s7, s6, 1
    and a3, a3, s7
    or a3, a3, t3
    lbu t1, F16A_MCKN+0x40+8*\dec+\i(a0)
    RETIREP t1, 1
.endm
    INCDEC 0, 0
    INCDEC 1, 0
    INCDEC 2, 0
    INCDEC 3, 0
    INCDEC 4, 0
    INCDEC 5, 0
    INCDEC 6, 0
    INCDEC 7, 0
    INCDEC 0, 1
    INCDEC 1, 1
    INCDEC 2, 1
    INCDEC 3, 1
    INCDEC 4, 1
    INCDEC 5, 1
    INCDEC 6, 1
    INCDEC 7, 1

/* ---------------- PUSH / POP r16 (not SP: the V30 differs) ---------------- */
.macro PUSHR i
    .align 1
    .globl f16a_push\i
f16a_push\i:
    lhu t1, F16A_R+8(a0)
    addi t2, t1, -2
    and t2, t2, s0
    lw t3, F16A_BASE+8(a0)
    add t3, t3, t2
    addi t4, t1, -1
    BX beqz, t4
    BX bgeu, t3, s2
    add t4, a7, t3
    lhu t5, F16A_R+2*\i(a0)
    STW t4, t5, t6
    sh t2, F16A_R+8(a0)
    lbu t1, F16A_MCKN+0x50+\i(a0)
    addi a1, a1, 1
    RETIRE t1
.endm
.macro POPR i
    .align 1
    .globl f16a_pop\i
f16a_pop\i:
    PREF 1
    lhu t1, F16A_R+8(a0)
    lw t3, F16A_BASE+8(a0)
    add t3, t3, t1
    BX beq, t1, s0
    BX bgeu, t3, s3
    add t4, a7, t3
    LDW t5, t4, s7
    addi t1, t1, 2
    sh t1, F16A_R+8(a0)
    sh t5, F16A_R+2*\i(a0)
    lbu t1, F16A_MCKN+0x58+\i(a0)
    RETIREP t1, 1
.endm
    PUSHR 0
    PUSHR 1
    PUSHR 2
    PUSHR 3
    PUSHR 5
    PUSHR 6
    PUSHR 7
    POPR 0
    POPR 1
    POPR 2
    POPR 3
    POPR 5
    POPR 6
    POPR 7

/* ---------------- MOV 88-8B ---------------- */
/* 88: MOV r/m8, r8. A write outside RAM below A0000h goes to the C handler (plain graphics VRAM path). */
.macro MOV88 name, ov, cfb
    .set f16a_ovc, \ov
    .align 1
    .globl \name
\name:
    lbu t5, 1(a1)
    bgeu t5, s4, 5f
    EA \ov
    bltu s2, t3, 6f
    add t4, a7, t3
    REGB t0, t5
    lbu s7, F16A_R(t0)
    STB t4, s7
    lbu t1, F16A_MCKM+2*0x88+1(a0)
    add a1, a1, t2
    RETIRE t1
5:  PREF 2
    add t0, s1, t5
    lbu t0, F16A_T_M8(t0)
    andi t1, t0, 15
    srli t2, t0, 4
    add t1, t1, a0
    add t2, t2, a0
    lbu t3, F16A_R(t2)
    sb t3, F16A_R(t1)
    lbu t1, F16A_MCKM+2*0x88(a0)
    RETIREP t1, 2
6:  CFALLBACK \cfb
    .set f16a_ovc, 0
.endm
.macro MOV89 name, ov
    .set f16a_ovc, \ov
    .align 1
    .globl \name
\name:
    lbu t5, 1(a1)
    bgeu t5, s4, 5f
    EA \ov
    BRB beq, t1, s0
    BRB bgeu, t3, s2
    add t4, a7, t3
    REGW t0, t5
    lhu s7, F16A_R(t0)
    STW t4, s7, t3
    lbu t1, F16A_MCKM+2*0x89+1(a0)
    add a1, a1, t2
    RETIRE t1
5:  PREF 2
    RMW t1, t5
    REGW t2, t5
    lhu t3, F16A_R(t2)
    sh t3, F16A_R(t1)
    lbu t1, F16A_MCKM+2*0x89(a0)
    RETIREP t1, 2
    .set f16a_ovc, 0
.endm
/* 8A: MOV r8, r/m8. A read outside RAM below A4000h goes to the C handler. */
.macro MOV8A name, ov, cfb
    .set f16a_ovc, \ov
    .align 1
    .globl \name
\name:
    lbu t5, 1(a1)
    bgeu t5, s4, 5f
    EA \ov
    bltu s3, t3, 6f
    PREFR t2
    add t4, a7, t3
    lbu s7, 0(t4)
    REGB t0, t5
    sb s7, F16A_R(t0)
    lbu t1, F16A_MCKM+2*0x8a+1(a0)
    RETIREP t1, t2, 1
5:  PREF 2
    add t0, s1, t5
    lbu t0, F16A_T_M8(t0)
    andi t1, t0, 15
    srli t2, t0, 4
    add t1, t1, a0
    add t2, t2, a0
    lbu t3, F16A_R(t1)
    sb t3, F16A_R(t2)
    lbu t1, F16A_MCKM+2*0x8a(a0)
    RETIREP t1, 2
6:  CFALLBACK \cfb
    .set f16a_ovc, 0
.endm
.macro MOV8B name, ov
    .set f16a_ovc, \ov
    .align 1
    .globl \name
\name:
    lbu t5, 1(a1)
    bgeu t5, s4, 5f
    EA \ov
    BRB beq, t1, s0
    BRB bgeu, t3, s3
    PREFR t2
    add t4, a7, t3
    LDW t1, t4, t3
    REGW t0, t5
    sh t1, F16A_R(t0)
    lbu t1, F16A_MCKM+2*0x8b+1(a0)
    RETIREP t1, t2, 1
5:  PREF 2
    RMW t1, t5
    REGW t2, t5
    lhu t3, F16A_R(t1)
    sh t3, F16A_R(t2)
    lbu t1, F16A_MCKM+2*0x8b(a0)
    RETIREP t1, 2
    .set f16a_ovc, 0
.endm
    MOV88 f16a_88, 0, 0
    MOV88 f16o_88, 1, 2
    MOV89 f16a_89, 0
    MOV89 f16o_89, 1
    MOV8A f16a_8a, 0, 1
    MOV8A f16o_8a, 1, 3
    MOV8B f16a_8b, 0
    MOV8B f16o_8b, 1

/* ---------------- Jcc rel8 (70-7F) ---------------- */
.macro JCC op
    .align 1
    .globl f16a_j\op
f16a_j\op:
    .set cc_, ((0x\op) & 15) >> 1
    lbu t1, F16A_MCKN+0x\op(a0)
  .if cc_ == 0
    and t2, a3, s10
  .elseif cc_ == 1
    andi t2, a3, 1
  .elseif cc_ == 2
    andi t2, a3, 0x40
  .elseif cc_ == 3
    andi t2, a3, 0x41
  .elseif cc_ == 4
    andi t2, a3, 0x80
  .elseif cc_ == 5
    andi t2, a3, 4
  .elseif cc_ == 6
    srli t2, a3, 7
    srli t3, a3, 11
    xor t2, t2, t3
    andi t2, t2, 1
  .else
    srli t2, a3, 7
    srli t3, a3, 11
    xor t2, t2, t3
    andi t2, t2, 1
    andi t3, a3, 0x40
    or t2, t2, t3
  .endif
  .if (0x\op) & 1
    bnez t2, 1f
  .else
    beqz t2, 1f
  .endif
    lb t2, 1(a1)
    beqz t2, 2f
    lw t3, F16A_MCKT(a0)
    lbu t3, 0x\op(t3)
    add t1, t1, t3
2:  lw t3, F16A_MOPCB(a0)
    sub t4, a1, t3
    addi t4, t4, 2
    add t4, t4, t2
    and t4, t4, s0
    add a1, t3, t4
    RETIRE t1
1:  addi a1, a1, 2
    RETIRE t1
.endm
    JCC 70
    JCC 71
    JCC 72
    JCC 73
    JCC 74
    JCC 75
    JCC 76
    JCC 77
    JCC 78
    JCC 79
    JCC 7a
    JCC 7b
    JCC 7c
    JCC 7d
    JCC 7e
    JCC 7f


/* ================= stage 19b: remaining handlers (default segment; mo_* stay C) ================= */
/* pointer (from A) of the r/m field byte register */
.macro RMB dst, m
    add \dst, s1, \m
    lbu \dst, F16A_T_M8(\dst)
    andi \dst, \dst, 15
    add \dst, \dst, a0
.endm
/* dst = mck_main[(opv << 4) | (reg << 1) | mem] for the ModR/M byte m (mem = m < C0h); tmp scratch */
.macro MAINCLK dst, opv, m, tmp
    srli \dst, \m, 2
    andi \dst, \dst, 14
    sltu \tmp, \m, s4
    or \dst, \dst, \tmp
    li \tmp, (\opv) << 4
    or \dst, \dst, \tmp
    lw \tmp, F16A_MCKMAIN(a0)
    add \dst, \dst, \tmp
    lbu \dst, 0(\dst)
.endm
/* jump on the op field r (0..7) to 20..27 (numeric labels) through a table in internal RAM; t scratch */
.macro JT8 r, t, tab
    .pushsection .dram1.f16a_jt, "aw"
    .align 2
\tab:
    .word 20f, 21f, 22f, 23f, 24f, 25f, 26f, 27f
    .popsection
    slli \r, \r, 2
    la \t, \tab
    add \r, \r, \t
    lw \r, 0(\r)
    jr \r
.endm
/* jump on the op field r (0..7): 20..27 (numeric labels); falls through into the code for 6 */
.macro DISP8 r, t
    li \t, 7
    beq \r, \t, 27f
    beqz \r, 20f
    li \t, 5
    beq \r, \t, 25f
    li \t, 4
    beq \r, \t, 24f
    li \t, 1
    beq \r, \t, 21f
    li \t, 2
    beq \r, \t, 22f
    li \t, 3
    beq \r, \t, 23f
.endm

/* ---------------- TEST AL/AX, imm ---------------- */
    .align 1
    .globl f16a_a8
f16a_a8:
    PREF 2
    lbu t1, F16A_R(a0)
    lbu t2, 1(a1)
    and t1, t1, t2
    FLOG8 t1, t3
    lbu t1, F16A_MCKN+0xa8(a0)
    RETIREP t1, 2
    .align 1
    .globl f16a_a9
f16a_a9:
    PREF 3
    lhu t1, F16A_R(a0)
    lbu t2, 1(a1)
    lbu t3, 2(a1)
    slli t3, t3, 8
    or t2, t2, t3
    and t1, t1, t2
    FLOG16 t1, t2, t3
    lbu t1, F16A_MCKN+0xa9(a0)
    RETIREP t1, 3

/* ---------------- MOV r, imm (B0-BF) ---------------- */
.macro MOVI8 i
    .align 1
    .globl f16a_movi8_\i
f16a_movi8_\i:
    PREF 2
    lbu t1, 1(a1)
    sb t1, F16A_R+(((\i & 3) << 1) | (\i >> 2))(a0)
    lbu t1, F16A_MCKN+0xb0+\i(a0)
    RETIREP t1, 2
.endm
.macro MOVI16 i
    .align 1
    .globl f16a_movi16_\i
f16a_movi16_\i:
    PREF 3
    lbu t1, 1(a1)
    lbu t2, 2(a1)
    slli t2, t2, 8
    or t1, t1, t2
    sh t1, F16A_R+2*\i(a0)
    lbu t1, F16A_MCKN+0xb8+\i(a0)
    RETIREP t1, 3
.endm
.macro XCHG i
    .align 1
    .globl f16a_xchg\i
f16a_xchg\i:
    PREF 1
    lhu t1, F16A_R(a0)
    lhu t2, F16A_R+2*\i(a0)
    sh t1, F16A_R+2*\i(a0)
    sh t2, F16A_R(a0)
    lbu t1, F16A_MCKN+0x90+\i(a0)
    RETIREP t1, 1
.endm
    MOVI8 0
    MOVI8 1
    MOVI8 2
    MOVI8 3
    MOVI8 4
    MOVI8 5
    MOVI8 6
    MOVI8 7
    MOVI16 0
    MOVI16 1
    MOVI16 2
    MOVI16 3
    MOVI16 4
    MOVI16 5
    MOVI16 6
    MOVI16 7
    XCHG 0
    XCHG 1
    XCHG 2
    XCHG 3
    XCHG 4
    XCHG 5
    XCHG 6
    XCHG 7

/* ---------------- CBW CWD SAHF LAHF, flag bits ---------------- */
    .align 1
    .globl f16a_cbw
f16a_cbw:
    PREF 1
    lb t1, F16A_R(a0)
    sh t1, F16A_R(a0)
    lbu t1, F16A_MCKN+0x98(a0)
    RETIREP t1, 1
    .align 1
    .globl f16a_cwd
f16a_cwd:
    PREF 1
    lh t1, F16A_R(a0)
    srai t1, t1, 31
    sh t1, F16A_R+4(a0)
    lbu t1, F16A_MCKN+0x99(a0)
    RETIREP t1, 1
    .align 1
    .globl f16a_sahf
f16a_sahf:
    PREF 1
    lbu t1, F16A_R+1(a0)
    andi t1, t1, 0xd5
    andi a3, a3, ~0xd5
    or a3, a3, t1
    lbu t1, F16A_MCKN+0x9e(a0)
    RETIREP t1, 1
    .align 1
    .globl f16a_lahf
f16a_lahf:
    PREF 1
    andi t1, a3, 0xd5
    ori t1, t1, 2
    sb t1, F16A_R+1(a0)
    lbu t1, F16A_MCKN+0x9f(a0)
    RETIREP t1, 1
.macro FLAGOP name, op, insn:vararg
    .align 1
    .globl \name
\name:
    PREF 1
    \insn
    lbu t1, F16A_MCKN+\op(a0)
    RETIREP t1, 1
.endm
    FLAGOP f16a_cmc, 0xf5, xori a3, a3, 1
    FLAGOP f16a_clc, 0xf8, andi a3, a3, ~1
    FLAGOP f16a_stc, 0xf9, ori a3, a3, 1
    FLAGOP f16a_cli, 0xfa, andi a3, a3, ~0x200
    FLAGOP f16a_cld, 0xfc, andi a3, a3, ~0x400
    FLAGOP f16a_std, 0xfd, ori a3, a3, 0x400

/* ---------------- PUSH / POP segment register ---------------- */
.macro PUSHSEG i, op
    .align 1
    .globl f16a_pushseg\i
f16a_pushseg\i:
    lhu t1, F16A_R+8(a0)
    addi t2, t1, -2
    and t2, t2, s0
    lw t3, F16A_BASE+8(a0)
    add t3, t3, t2
    addi t4, t1, -1
    BX beqz, t4
    BX bgeu, t3, s2
    add t4, a7, t3
    lhu t5, F16A_SEG+2*\i(a0)
    STW t4, t5, t6
    sh t2, F16A_R+8(a0)
    lbu t1, F16A_MCKN+\op(a0)
    addi a1, a1, 1
    RETIRE t1
.endm
.macro POPSEG i, op
    .align 1
    .globl f16a_popseg\i
f16a_popseg\i:
    PREF 1
    lhu t1, F16A_R+8(a0)
    lw t3, F16A_BASE+8(a0)
    add t3, t3, t1
    BX beq, t1, s0
    BX bgeu, t3, s3
    add t4, a7, t3
    LDW t5, t4, s7
    addi t1, t1, 2
    sh t1, F16A_R+8(a0)
    sh t5, F16A_SEG+2*\i(a0)
    slli t5, t5, 4
    sw t5, F16A_BASE+4*\i(a0)
    lw t2, F16A_MENU(a0)
    beqz t2, 1f
    sw t5, F16A_CACHE+8*\i(a0)
    sh s0, F16A_CACHE+8*\i+4(a0)
    li t2, 0x93
    sb t2, F16A_CACHE+8*\i+6(a0)
    li t2, 1
    sb t2, F16A_VALID+\i(a0)
1:  lbu t1, F16A_MCKN+\op(a0)
    RETIREP t1, 1
.endm
    PUSHSEG 0, 0x06
    PUSHSEG 1, 0x0e
    PUSHSEG 2, 0x16
    PUSHSEG 3, 0x1e
    POPSEG 0, 0x07
    POPSEG 3, 0x1f

/* PUSHF: the V30 (menu 0) sets the top four bits */
    .align 1
    .globl f16a_pushf
f16a_pushf:
    lhu t1, F16A_R+8(a0)
    addi t2, t1, -2
    and t2, t2, s0
    lw t3, F16A_BASE+8(a0)
    add t3, t3, t2
    addi t4, t1, -1
    BX beqz, t4
    BX bgeu, t3, s2
    add t4, a7, t3
    lw t5, F16A_MENU(a0)
    beqz t5, 1f
    li t5, 0x7fd5
    and t5, a3, t5
    ori t5, t5, 2
    j 2f
1:  li t5, 0xfd5
    and t5, a3, t5
    ori t5, t5, 2
    li t6, 0xf000
    or t5, t5, t6
2:  STW t4, t5, t6
    sh t2, F16A_R+8(a0)
    lbu t1, F16A_MCKN+0x9c(a0)
    addi a1, a1, 1
    RETIRE t1

/* ---------------- JMP short / near, CALL near, RET near, LOOP ---------------- */
    .align 1
    .globl f16a_eb
f16a_eb:
    lb t2, 1(a1)
    lw t3, F16A_MOPCB(a0)
    sub t4, a1, t3
    addi t4, t4, 2
    add t4, t4, t2
    and t4, t4, s0
    add a1, t3, t4
    lbu t1, F16A_MCKN+0xeb(a0)
    RETIRE t1
    .align 1
    .globl f16a_e9
f16a_e9:
    lbu t2, 1(a1)
    lbu t3, 2(a1)
    slli t3, t3, 8
    or t2, t2, t3
    lw t3, F16A_MOPCB(a0)
    sub t4, a1, t3
    addi t4, t4, 3
    add t4, t4, t2
    and t4, t4, s0
    add a1, t3, t4
    lbu t1, F16A_MCKN+0xe9(a0)
    RETIRE t1
    .align 1
    .globl f16a_e8
f16a_e8:
    lhu t1, F16A_R+8(a0)
    addi t2, t1, -2
    and t2, t2, s0
    lw t3, F16A_BASE+8(a0)
    add t3, t3, t2
    addi t4, t1, -1
    BX beqz, t4
    BX bgeu, t3, s2
    add t4, a7, t3
    lbu t1, 1(a1)          /* the displacement first: the push may overwrite it (stack over the code) */
    lbu t3, 2(a1)
    slli t3, t3, 8
    or t1, t1, t3
    lw t0, F16A_MOPCB(a0)
    sub t5, a1, t0
    addi t5, t5, 3
    and t5, t5, s0
    STW t4, t5, t6
    sh t2, F16A_R+8(a0)
    add t1, t1, t5
    and t1, t1, s0
    add a1, t0, t1
    lbu t1, F16A_MCKN+0xe8(a0)
    RETIRE t1
    .align 1
    .globl f16a_c3
f16a_c3:
    lhu t1, F16A_R+8(a0)
    lw t3, F16A_BASE+8(a0)
    add t3, t3, t1
    BX beq, t1, s0
    BX bgeu, t3, s3
    add t4, a7, t3
    LDW t5, t4, s7
    addi t1, t1, 2
    sh t1, F16A_R+8(a0)
    lw t0, F16A_MOPCB(a0)
    add a1, t0, t5
    lbu t1, F16A_MCKN+0xc3(a0)
    RETIRE t1
/* E0 LOOPNZ  E1 LOOPZ  E2 LOOP  E3 JCXZ */
.macro LOOPX n
    .align 1
    .globl f16a_loop\n
f16a_loop\n:
    lbu t1, F16A_MCKN+0xe0+\n(a0)
    lhu t2, F16A_R+2(a0)
  .if \n == 3
    bnez t2, 1f
  .else
    addi t2, t2, -1
    and t2, t2, s0
    sh t2, F16A_R+2(a0)
    beqz t2, 1f
    .if \n == 0
    andi t3, a3, 0x40
    bnez t3, 1f
    .elseif \n == 1
    andi t3, a3, 0x40
    beqz t3, 1f
    .endif
  .endif
    lb t2, 1(a1)
    beqz t2, 2f
    lw t3, F16A_MCKT(a0)
    lbu t3, 0xe0+\n(t3)
    add t1, t1, t3
2:  lw t3, F16A_MOPCB(a0)
    sub t4, a1, t3
    addi t4, t4, 2
    add t4, t4, t2
    and t4, t4, s0
    add a1, t3, t4
    RETIRE t1
1:  addi a1, a1, 2
    RETIRE t1
.endm
    LOOPX 0
    LOOPX 1
    LOOPX 2
    LOOPX 3

/* ---------------- LEA, MOV r/m with imm, MOV acc <-> [moffs], MOV sreg ---------------- */
    .align 1
    .globl f16a_8d
f16a_8d:
    lbu t5, 1(a1)
    BX bgeu, t5, s4
    EA 0
    PREFR t2
    REGW t0, t5
    sh t1, F16A_R(t0)
    lbu t1, F16A_MCKM+2*0x8d+1(a0)
    RETIREP t1, t2, 1

    .align 1
    .globl f16a_c6
f16a_c6:
    lbu t5, 1(a1)
    andi t0, t5, 0x38
    BX bnez, t0
    bgeu t5, s4, 5f
    EA 0
    BX bltu, s2, t3
    add t4, a7, t3
    add t0, a1, t2
    lbu t0, 0(t0)
    STB t4, t0
    lbu t1, F16A_MCKM+2*0xc6+1(a0)
    addi t2, t2, 1
    add a1, a1, t2
    RETIRE t1
5:  PREF 3
    lbu t1, 2(a1)
    RMB t0, t5
    sb t1, F16A_R(t0)
    lbu t1, F16A_MCKM+2*0xc6(a0)
    RETIREP t1, 3
    .align 1
    .globl f16a_c7
f16a_c7:
    lbu t5, 1(a1)
    andi t0, t5, 0x38
    BX bnez, t0
    bgeu t5, s4, 5f
    EA 0
    BX beq, t1, s0
    BX bgeu, t3, s2
    add t4, a7, t3
    add t0, a1, t2
    lbu t1, 0(t0)
    lbu t0, 1(t0)
    slli t0, t0, 8
    or t1, t1, t0
    STW t4, t1, t3
    lbu t1, F16A_MCKM+2*0xc7+1(a0)
    addi t2, t2, 2
    add a1, a1, t2
    RETIRE t1
5:  PREF 4
    lbu t1, 2(a1)
    lbu t2, 3(a1)
    slli t2, t2, 8
    or t1, t1, t2
    RMW t0, t5
    sh t1, F16A_R(t0)
    lbu t1, F16A_MCKM+2*0xc7(a0)
    RETIREP t1, 4

/* A0 A1 A2 A3: offset in t1, linear address in t3 */
.macro MOFFS
    lbu t1, 1(a1)
    lbu t2, 2(a1)
    slli t2, t2, 8
    or t1, t1, t2
    lw t3, F16A_BASE+12(a0)
    add t3, t3, t1
.endm
    .align 1
    .globl f16a_a0
f16a_a0:
    PREF 3
    MOFFS
    BX bltu, s3, t3
    add t4, a7, t3
    lbu t4, 0(t4)
    sb t4, F16A_R(a0)
    lbu t1, F16A_MCKN+0xa0(a0)
    RETIREP t1, 3
    .align 1
    .globl f16a_a1
f16a_a1:
    PREF 3
    MOFFS
    BX beq, t1, s0
    BX bgeu, t3, s3
    add t4, a7, t3
    LDW t5, t4, t2
    sh t5, F16A_R(a0)
    lbu t1, F16A_MCKN+0xa1(a0)
    RETIREP t1, 3
    .align 1
    .globl f16a_a2
f16a_a2:
    MOFFS
    BX bltu, s2, t3
    add t4, a7, t3
    lbu t5, F16A_R(a0)
    STB t4, t5
    lbu t1, F16A_MCKN+0xa2(a0)
    addi a1, a1, 3
    RETIRE t1
    .align 1
    .globl f16a_a3
f16a_a3:
    MOFFS
    BX beq, t1, s0
    BX bgeu, t3, s2
    add t4, a7, t3
    lhu t5, F16A_R(a0)
    STW t4, t5, t2
    lbu t1, F16A_MCKN+0xa3(a0)
    addi a1, a1, 3
    RETIRE t1

/* 8C: MOV r/m16, sreg (sreg 0..3) */
    .align 1
    .globl f16a_8c
f16a_8c:
    lbu t5, 1(a1)
    andi t0, t5, 0x20
    BX bnez, t0
    bgeu t5, s4, 5f
    EA 0
    BX beq, t1, s0
    BX bgeu, t3, s2
    add t4, a7, t3
    srli t0, t5, 2
    andi t0, t0, 6
    add t0, t0, a0
    lhu t0, F16A_SEG(t0)
    STW t4, t0, t3
    lbu t1, F16A_MCKM+2*0x8c+1(a0)
    add a1, a1, t2
    RETIRE t1
5:  PREF 2
    srli t0, t5, 2
    andi t0, t0, 6
    add t0, t0, a0
    lhu t0, F16A_SEG(t0)
    RMW t1, t5
    sh t0, F16A_R(t1)
    lbu t1, F16A_MCKM+2*0x8c(a0)
    RETIREP t1, 2
/* 8E: MOV sreg, r/m16 (ES or DS only); the segment cache follows M_LOADSEG */
    .align 1
    .globl f16a_8e
f16a_8e:
    lbu t5, 1(a1)
    andi t0, t5, 0x38
    beqz t0, 1f
    li t6, 0x18
    BX bne, t0, t6
1:  bgeu t5, s4, 5f
    EA 0
    BX beq, t1, s0
    BX bgeu, t3, s3
    add t4, a7, t3
    LDW t1, t4, t3
    j 6f
5:  RMW t1, t5
    lhu t1, F16A_R(t1)
    li t2, 2
6:  PREFR t2
    srli t0, t5, 3
    andi t0, t0, 3
    slli t3, t0, 1
    add t3, t3, a0
    sh t1, F16A_SEG(t3)
    slli s7, t1, 4
    slli t3, t0, 2
    add t3, t3, a0
    sw s7, F16A_BASE(t3)
    lw t4, F16A_MENU(a0)
    beqz t4, 7f
    slli t3, t0, 3
    add t3, t3, a0
    sw s7, F16A_CACHE(t3)
    sh s0, F16A_CACHE+4(t3)
    li t4, 0x93
    sb t4, F16A_CACHE+6(t3)
    add t3, t0, a0
    li t4, 1
    sb t4, F16A_VALID(t3)
7:  MAINCLK t1, 0x8e, t5, t3
    RETIREP t1, t2, 1

/* ---------------- 80 82 / 81 83: ALU r/m, imm ---------------- */
/* t4 = pointer to the operand (RAM, or the register inside A), t2 = opcode+modrm+disp length, t5 = ModR/M */
    .align 1
    .globl f16a_grp1_b
f16a_grp1_b:
    lbu t5, 1(a1)
    bltu t5, s4, 7f
    RMB t4, t5
    addi t4, t4, F16A_R
    li t2, 2
6:  add t0, a1, t2
    lbu t3, 0(t0)
    lbu t1, 0(t4)
    addi t2, t2, 1
    lbu t0, 0(a1)
    slli t0, t0, 4
    srli t6, t5, 2
    andi t6, t6, 14
    or t0, t0, t6
    sltu t6, t5, s4
    or t0, t0, t6
    lw t6, F16A_MCKMAIN(a0)
    add t6, t6, t0
    lbu s7, 0(t6)
    add a1, a1, t2
    srli t0, t5, 3
    andi t0, t0, 7
    JT8 t0, t6, f16a_grp1_b_ops
26: ALU8 6, s11, t1, t3, t0, t2, t6
    j 8f
20: ALU8 0, s11, t1, t3, t0, t2, t6
    j 8f
21: ALU8 1, s11, t1, t3, t0, t2, t6
    j 8f
22: ALU8 2, s11, t1, t3, t0, t2, t6
    j 8f
23: ALU8 3, s11, t1, t3, t0, t2, t6
    j 8f
24: ALU8 4, s11, t1, t3, t0, t2, t6
    j 8f
25: ALU8 5, s11, t1, t3, t0, t2, t6
8:  bltu t5, s4, 10f
    sb s11, 0(t4)
    RETIRE s7
10: STB t4, s11
    RETIRE s7
27: ALU8 7, s11, t1, t3, t0, t2, t6
    RETIRE s7
7:  EA 0
    BX bltu, s2, t3
    add t4, a7, t3
    j 6b

    .align 1
    .globl f16a_grp1_w
f16a_grp1_w:
    lbu t5, 1(a1)
    bltu t5, s4, 7f
    RMW t4, t5
    addi t4, t4, F16A_R
    lhu t1, 0(t4)
    li t2, 2
6:  lbu t0, 0(a1)
    add t6, a1, t2
    lb t3, 0(t6)
    addi t2, t2, 1
    li s7, 0x83
    beq t0, s7, 4f
    lbu t3, 0(t6)
    lbu s7, 1(t6)
    slli s7, s7, 8
    or t3, t3, s7
    addi t2, t2, 1
4:  and t3, t3, s0
    slli t0, t0, 4
    srli t6, t5, 2
    andi t6, t6, 14
    or t0, t0, t6
    sltu t6, t5, s4
    or t0, t0, t6
    lw t6, F16A_MCKMAIN(a0)
    add t6, t6, t0
    lbu s7, 0(t6)
    add a1, a1, t2
    srli t0, t5, 3
    andi t0, t0, 7
    JT8 t0, t6, f16a_grp1_w_ops
26: ALU16 6, s11, t1, t3, t0, t2, t6
    j 8f
20: ALU16 0, s11, t1, t3, t0, t2, t6
    j 8f
21: ALU16 1, s11, t1, t3, t0, t2, t6
    j 8f
22: ALU16 2, s11, t1, t3, t0, t2, t6
    j 8f
23: ALU16 3, s11, t1, t3, t0, t2, t6
    j 8f
24: ALU16 4, s11, t1, t3, t0, t2, t6
    j 8f
25: ALU16 5, s11, t1, t3, t0, t2, t6
8:  bltu t5, s4, 10f
    sh s11, 0(t4)
    RETIRE s7
10: STW t4, s11, t3
    RETIRE s7
27: ALU16 7, s11, t1, t3, t0, t2, t6
    RETIRE s7
7:  EA 0
    BX beq, t1, s0
    BX bgeu, t3, s2
    add t4, a7, t3
    LDW t1, t4, t3
    j 6b

/* ---------------- 84 85 TEST r/m, r ---------------- */
    .align 1
    .globl f16a_84
f16a_84:
    lbu t5, 1(a1)
    bgeu t5, s4, 5f
    EA 0
    BX bltu, s3, t3
    add t4, a7, t3
    lbu t1, 0(t4)
    PREFR t2
    REGB t0, t5
    lbu t3, F16A_R(t0)
    and t1, t1, t3
    FLOG8 t1, t3
    lbu t1, F16A_MCKM+2*0x84+1(a0)
    RETIREP t1, t2, 1
5:  PREF 2
    add t0, s1, t5
    lbu t0, F16A_T_M8(t0)
    andi t1, t0, 15
    srli t2, t0, 4
    add t1, t1, a0
    add t2, t2, a0
    lbu t3, F16A_R(t1)
    lbu t4, F16A_R(t2)
    and t3, t3, t4
    FLOG8 t3, t4
    lbu t1, F16A_MCKM+2*0x84(a0)
    RETIREP t1, 2
    .align 1
    .globl f16a_85
f16a_85:
    lbu t5, 1(a1)
    bgeu t5, s4, 5f
    EA 0
    BX beq, t1, s0
    BX bgeu, t3, s3
    add t4, a7, t3
    LDW t1, t4, t3
    PREFR t2
    REGW t0, t5
    lhu t3, F16A_R(t0)
    and t1, t1, t3
    FLOG16 t1, t3, t4
    lbu t1, F16A_MCKM+2*0x85+1(a0)
    RETIREP t1, t2, 1
5:  PREF 2
    RMW t1, t5
    REGW t2, t5
    lhu t3, F16A_R(t1)
    lhu t4, F16A_R(t2)
    and t3, t3, t4
    FLOG16 t3, t4, t0
    lbu t1, F16A_MCKM+2*0x85(a0)
    RETIREP t1, 2

/* ---------------- FE: INC / DEC r/m8 ---------------- */
.macro INCDEC8 dec
  .if \dec
    addi t0, t1, -1
  .else
    addi t0, t1, 1
  .endif
    andi t0, t0, 255
    xor t2, t1, t0
    andi t2, t2, 16
  .if \dec
    xori t3, t1, 0x80
  .else
    xori t3, t0, 0x80
  .endif
    seqz t3, t3
    slli t3, t3, 11
    or t2, t2, t3
    add t3, t0, s1
    lbu t3, F16A_T_SZP8(t3)
    or t2, t2, t3
    ori t3, s6, 1
    and a3, a3, t3
    or a3, a3, t2
.endm
    .align 1
    .globl f16a_fe
f16a_fe:
    lbu t5, 1(a1)
    andi t0, t5, 0x30
    BX bnez, t0
    bltu t5, s4, 7f
    RMB t4, t5
    addi t4, t4, F16A_R
    lbu t1, 0(t4)
    lbu s7, F16A_MCKM+2*0xfe(a0)
    addi a1, a1, 2
6:  andi t0, t5, 8
    bnez t0, 20f
    INCDEC8 0
    j 8f
20: INCDEC8 1
8:  bltu t5, s4, 10f
    sb t0, 0(t4)
    RETIRE s7
10: STB t4, t0
    RETIRE s7
7:  EA 0
    BX bltu, s2, t3
    add t4, a7, t3
    lbu t1, 0(t4)
    lbu s7, F16A_MCKM+2*0xfe+1(a0)
    add a1, a1, t2
    j 6b

/* ---------------- FF: INC DEC CALL JMP PUSH on r/m16 ---------------- */
    .align 1
    .globl f16a_ff
f16a_ff:
    lbu t5, 1(a1)
    bgeu t5, s4, 5f
    EA 0
    BX beq, t1, s0
    srli t0, t5, 3
    andi t0, t0, 7
    sltiu t6, t0, 2
    bnez t6, 1f
    BX bgeu, t3, s3
    j 2f
1:  BX bgeu, t3, s2
2:  add t4, a7, t3
    LDW t1, t4, t3
    j 6f
5:  RMW t4, t5
    addi t4, t4, F16A_R
    lhu t1, 0(t4)
    li t2, 2
    srli t0, t5, 3
    andi t0, t0, 7
6:  MAINCLK s7, 0xff, t5, t3
    beqz t0, 20f
    li t6, 1
    beq t0, t6, 21f
    li t6, 2
    beq t0, t6, 22f
    li t6, 4
    beq t0, t6, 24f
    li t6, 6
    beq t0, t6, 26f
    j f16a_exit
20: addi s11, t1, 1
    and s11, s11, s0
    xor t3, t1, s11
    andi t3, t3, 16
    xor t0, s11, s9
    j 23f
21: addi s11, t1, -1
    and s11, s11, s0
    xor t3, t1, s11
    andi t3, t3, 16
    xor t0, t1, s9
23: seqz t0, t0
    slli t0, t0, 11
    or t3, t3, t0
    FPZS16 s11, t3, t0, t6
    ori t0, s6, 1
    and a3, a3, t0
    or a3, a3, t3
    add a1, a1, t2
    bltu t5, s4, 10f
    sh s11, 0(t4)
    RETIRE s7
10: STW t4, s11, t3
    RETIRE s7
22: lhu t3, F16A_R+8(a0)
    addi t0, t3, -2
    and t0, t0, s0
    lw t6, F16A_BASE+8(a0)
    add t6, t6, t0
    addi s11, t3, -1
    BX beqz, s11
    BX bgeu, t6, s2
    add t6, a7, t6
    lw s11, F16A_MOPCB(a0)
    sub t3, a1, s11
    add t3, t3, t2
    and t3, t3, s0
    STW t6, t3, t4
    sh t0, F16A_R+8(a0)
    add a1, s11, t1
    RETIRE s7
24: lw t0, F16A_MOPCB(a0)
    add a1, t0, t1
    RETIRE s7
26: lhu t3, F16A_R+8(a0)
    addi t0, t3, -2
    and t0, t0, s0
    lw t6, F16A_BASE+8(a0)
    add t6, t6, t0
    addi s11, t3, -1
    BX beqz, s11
    BX bgeu, t6, s2
    add t6, a7, t6
    STW t6, t1, t4
    sh t0, F16A_R+8(a0)
    add a1, a1, t2
    RETIRE s7

/* ---------------- F6 / F7: TEST NOT NEG ---------------- */
.macro GRP3 name, opc, B
    .align 1
    .globl \name
\name:
    lbu t5, 1(a1)
    srli t0, t5, 3
    andi t0, t0, 7
    li t6, 1
    BX beq, t0, t6
    sltiu t6, t0, 4
    BX beqz, t6
    bgeu t5, s4, 5f
    EA 0
  .if \B == 16
    BX beq, t1, s0
  .endif
    srli t0, t5, 3
    andi t0, t0, 7
    beqz t0, 1f
  .if \B == 8
    BX bltu, s2, t3
  .else
    BX bgeu, t3, s2
  .endif
    j 2f
1:
  .if \B == 8
    BX bltu, s3, t3
  .else
    BX bgeu, t3, s3
  .endif
2:  add t4, a7, t3
  .if \B == 8
    lbu t1, 0(t4)
  .else
    LDW t1, t4, t3
  .endif
    MAINCLK s7, \opc, t5, t3
    j 6f
5:
  .if \B == 8
    RMB t4, t5
    addi t4, t4, F16A_R
    lbu t1, 0(t4)
  .else
    RMW t4, t5
    addi t4, t4, F16A_R
    lhu t1, 0(t4)
  .endif
    li t2, 2
    MAINCLK s7, \opc, t5, t3
    srli t0, t5, 3
    andi t0, t0, 7
6:  beqz t0, 20f
    li t6, 2
    beq t0, t6, 21f
  .if \B == 8
    FSUB8 s11, zero, t1, t3, t6, t0, 0
  .else
    FSUB16 s11, zero, t1, t3, t6, t0, 0
  .endif
    j 8f
21: not s11, t1
  .if \B == 8
    andi s11, s11, 255
  .else
    and s11, s11, s0
  .endif
8:  add a1, a1, t2
    bltu t5, s4, 10f
  .if \B == 8
    sb s11, 0(t4)
  .else
    sh s11, 0(t4)
  .endif
    RETIRE s7
10:
  .if \B == 8
    STB t4, s11
  .else
    STW t4, s11, t3
  .endif
    RETIRE s7
20: add t3, a1, t2
  .if \B == 8
    lbu t3, 0(t3)
    and t1, t1, t3
    FLOG8 t1, t3
    addi t2, t2, 1
  .else
    lbu t0, 0(t3)
    lbu t3, 1(t3)
    slli t3, t3, 8
    or t3, t3, t0
    and t1, t1, t3
    FLOG16 t1, t3, t0
    addi t2, t2, 2
  .endif
    add a1, a1, t2
    RETIRE s7
.endm
    GRP3 f16a_f6, 0xf6, 8
    GRP3 f16a_f7, 0xf7, 16

/* ---------------- D0 / D1: shift / rotate by 1 (f_shift1) ---------------- */
.macro MASKB r, B
  .if \B == 8
    andi \r, \r, 255
  .else
    and \r, \r, s0
  .endif
.endm
/* t3 |= PF ZF SF of s11 */
.macro SHSZP B
  .if \B == 8
    add t0, s11, s1
    lbu t0, F16A_T_SZP8(t0)
    or t3, t3, t0
  .else
    FPZS16 s11, t3, t0, t6
  .endif
.endm
/* t3 (CF) |= (bit B-1 of s11 ^ bit B-2 of s11) << 11 */
.macro SHOF2 B
    srli t0, s11, \B-2
    srli t6, t0, 1
    xor t0, t0, t6
    andi t0, t0, 1
    slli t0, t0, 11
    or t3, t3, t0
.endm
/* t3 (CF) |= (bit B-1 of s11 ^ CF) << 11 */
.macro SHOFC B
    srli t0, s11, \B-1
    andi t0, t0, 1
    xor t0, t0, t3
    slli t0, t0, 11
    or t3, t3, t0
.endm
.macro SHOP1 B, op
  .if \op == 0
    slli t0, t1, 1
    srli t3, t1, \B-1
    or s11, t0, t3
    MASKB s11, \B
    andi t3, s11, 1
    SHOFC \B
  .elseif \op == 1
    srli t0, t1, 1
    slli t3, t1, \B-1
    or s11, t0, t3
    MASKB s11, \B
    srli t3, s11, \B-1
    SHOF2 \B
  .elseif \op == 2
    andi t0, a3, 1
    slli t3, t1, 1
    or s11, t3, t0
    MASKB s11, \B
    srli t3, t1, \B-1
    SHOFC \B
  .elseif \op == 3
    andi t0, a3, 1
    slli t0, t0, \B-1
    srli s11, t1, 1
    or s11, s11, t0
    andi t3, t1, 1
    SHOF2 \B
  .elseif \op == 4
    slli s11, t1, 1
    MASKB s11, \B
    srli t3, t1, \B-1
    SHOFC \B
    SHSZP \B
  .elseif \op == 5
    srli s11, t1, 1
    srli t0, t1, \B-1
    slli t0, t0, 11
    andi t3, t1, 1
    or t3, t3, t0
    SHSZP \B
  .else
    srli s11, t1, 1
    .if \B == 8
    andi t0, t1, 0x80
    .else
    and t0, t1, s9
    .endif
    or s11, s11, t0
    andi t3, t1, 1
    SHSZP \B
  .endif
  .if \op < 4
    ori t0, s8, 0xc4
    and a3, a3, t0
  .else
    and a3, a3, s8
  .endif
    or a3, a3, t3
.endm
.macro SHIFT1 name, opc, B
    .align 1
    .globl \name
\name:
    lbu t5, 1(a1)
    srli t0, t5, 3
    andi t0, t0, 7
    li t6, 6
    BX beq, t0, t6
    bltu t5, s4, 7f
  .if \B == 8
    RMB t4, t5
    addi t4, t4, F16A_R
    lbu t1, 0(t4)
  .else
    RMW t4, t5
    addi t4, t4, F16A_R
    lhu t1, 0(t4)
  .endif
    lbu s7, F16A_MCKM+2*\opc(a0)
    addi a1, a1, 2
    /* operation by the reg field through a jump table (internal RAM) */
    .pushsection .dram1.f16a_shjt, "aw"
    .align 2
\name\()_ops:
    .word 20f, 21f, 22f, 23f, 24f, 25f, 27f, 27f
    .popsection
6:  srli t0, t5, 1
    andi t0, t0, 0x1c
    la t6, \name\()_ops
    add t0, t0, t6
    lw t0, 0(t0)
    jr t0
27: SHOP1 \B, 7
    j 8f
20: SHOP1 \B, 0
    j 8f
21: SHOP1 \B, 1
    j 8f
22: SHOP1 \B, 2
    j 8f
23: SHOP1 \B, 3
    j 8f
24: SHOP1 \B, 4
    j 8f
25: SHOP1 \B, 5
8:  bltu t5, s4, 10f
  .if \B == 8
    sb s11, 0(t4)
  .else
    sh s11, 0(t4)
  .endif
    RETIRE s7
10:
  .if \B == 8
    STB t4, s11
  .else
    STW t4, s11, t3
  .endif
    RETIRE s7
7:  EA 0
  .if \B == 8
    BX bltu, s2, t3
    add t4, a7, t3
    lbu t1, 0(t4)
  .else
    BX beq, t1, s0
    BX bgeu, t3, s2
    add t4, a7, t3
    LDW t1, t4, t3
  .endif
    lbu s7, F16A_MCKM+2*\opc+1(a0)
    add a1, a1, t2
    j 6b
.endm
    SHIFT1 f16a_d0, 0xd0, 8
    SHIFT1 f16a_d1, 0xd1, 16

/* exit island for hand-back branches after the last RETIRE */
    .set f16a_ovc, 0
    ISLAND
