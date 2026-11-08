/* SPDX-License-Identifier: MIT
 * Copyright (c) mochimochi-man / Uh
 * fast16 mini loop in RISC-V assembly (stage 19, fast16_mini_rv.S): byte offsets inside Pc98Adapter used by the
 * assembly handlers. fast16.c checks every value against offsetof() at compile time. */
#ifndef PC98_FAST16_RV_H
#define PC98_FAST16_RV_H
#define F16A_R        156     /* s.low.r[8]   AX CX DX BX SP BP SI DI */
#define F16A_SEG      172     /* s.low.seg[4] ES CS SS DS */
#define F16A_FLAGS    182     /* s.low.flags */
#define F16A_BASE     184     /* s.low.base[4] */
#define F16A_IRQINH   206     /* s.low.irq_inhibit */
#define F16A_CACHE    32      /* mode.segments.cache[4], 8 bytes each: base(u32) limit(u16) access(u8) */
#define F16A_VALID    64      /* mode.segments.valid[4] (u8) */
#define F16A_MENU     592
#define F16A_ROM      656
#define F16A_ITF      660
#define F16A_SLICEP   688
#define F16A_IRQPROBE 708
#define F16A_IRQEND   712
#define F16A_MCKN     716     /* mck_n[256] */
#define F16A_MCKM     972     /* mck_m[512] */
#define F16A_MCKMAIN  1484    /* mck_main (pointer) */
#define F16A_MCKT     1488    /* mck_t (pointer) */
#define F16A_MOPCB    1500
#define F16A_MCKSHIFT 1504    /* mck_shift (pointer) */
#define F16A_MOREM    1508
#define F16A_MOOFF    1512
#define F16A_MOFL     1516
#define F16A_MONRET   1520
#define F16A_MOIP     1524
#define F16A_MOEV     1528
#define F16A_MOOV     1532
#define F16A_MOROM    1536
/* f16a_tabs[]: flag and register tables (filled by f16a_init) */
#define F16A_T_LO     0       /* PF | ZF(low byte 0) | 80h, by low byte */
#define F16A_T_HI     256     /* SF | ZF(high byte 0) | 04h, by high byte: T_LO[lo] & T_HI[hi] = PF ZF SF of a word */
#define F16A_T_SZP8   512     /* PF ZF SF of a byte */
#define F16A_T_M8     768     /* by ModR/M byte: low nibble = byte offset of the r/m byte register, high nibble = of the reg one */
#define F16A_T_SIZE   1024
/* EA form: 1 = branch-free table (f16a_eat = 16-byte entries), 0 = per-(mod, rm) stubs called through f16a_eat */
#ifndef F16A_EATAB
#define F16A_EATAB 0
#endif
#define F16A_MZ       1496    /* mz: a zero halfword */
/* f16a_eat[192] entries (16 bytes) */
#define F16A_E_O1     0       /* u16 offset in A of the first EA register (F16A_MZ: none) */
#define F16A_E_O2     2       /* u16 second register */
#define F16A_E_BO     4       /* u16 offset of the default segment base */
#define F16A_E_NB     6       /* u8 instruction length: opcode + ModR/M + displacement */
#define F16A_E_MK8    7       /* u8 FFh: 8-bit displacement */
#define F16A_E_MK16   8       /* u8 FFh: 16-bit displacement */
#endif
