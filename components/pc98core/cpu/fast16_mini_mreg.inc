/* SPDX-License-Identifier: MIT
 * Copyright (c) mochimochi-man / Uh
 * fast16 mini loop: the ModR/M handlers' table entries (fast16_mini_mem.inc, MINI_OV 0 / 1), filled into t[]. Shared by
 * the function-per-handler build (MN(register)) and the Xtensa one, where the entries are label addresses (MR). */
    unsigned i;
    (void)i;
#if !(F16_ASM && !MINI_OV)
    for (i = 0; i < 0x40; i += 8) {
        static mh_t const alu[8][4] = { { MR(0x00), MR(0x01), MR(0x02), MR(0x03) }, { MR(0x08), MR(0x09), MR(0x0a), MR(0x0b) },
            { MR(0x10), MR(0x11), MR(0x12), MR(0x13) }, { MR(0x18), MR(0x19), MR(0x1a), MR(0x1b) }, { MR(0x20), MR(0x21), MR(0x22), MR(0x23) },
            { MR(0x28), MR(0x29), MR(0x2a), MR(0x2b) }, { MR(0x30), MR(0x31), MR(0x32), MR(0x33) }, { MR(0x38), MR(0x39), MR(0x3a), MR(0x3b) } };
        unsigned k;
        for (k = 0; k < 4; k++) t[i + k] = alu[i >> 3][k];
    }
#endif
#if !(F16_ASM && !MINI_OV)
    t[0x80] = t[0x82] = MR(grp1_b); t[0x81] = t[0x83] = MR(grp1_w);
    t[0x84] = MR(84); t[0x85] = MR(85);
#endif
    t[0x88] = MR(88); t[0x89] = MR(89); t[0x8a] = MR(8a); t[0x8b] = MR(8b);
#if !(F16_ASM && !MINI_OV)
    for (i = 0xa0; i < 0xa4; i++) t[i] = MR(mova);
    t[0xc6] = MR(c6); t[0xc7] = MR(c7);
#endif
#if !MINI_OV   /* the override variants of the rarer opcodes are left out (IRAM budget: they go to the generic loop) */
#if !F16_ASM
    t[0x8c] = MR(8c); t[0x8e] = MR(8e);
#endif
    t[0xc0] = MR(c0); t[0xc1] = MR(c1);
#if !F16_ASM
    t[0xd0] = MR(d0); t[0xd1] = MR(d1);
#endif
    t[0xd2] = MR(d2); t[0xd3] = MR(d3);
#if !F16_ASM
    t[0xf6] = MR(f6); t[0xf7] = MR(f7); t[0xfe] = MR(fe); t[0xff] = MR(ff);
#endif
#endif
