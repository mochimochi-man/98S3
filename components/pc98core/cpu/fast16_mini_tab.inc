/* SPDX-License-Identifier: MIT
 * Copyright (c) mochimochi-man / Uh
 * fast16 mini loop: fill the handler tables (mini_init, or m_start(NULL, ...) on the Xtensa, where the entries are
 * label addresses inside m_start). */
{
    unsigned i;
    for (i = 0; i < 256; i++) { mtab[i] = MREF(m_exit); mtab_ov[i] = MREF(mo_exit); }
#if F16_XT
    {
        mh_t *const t = mtab;
#define MN(x) m_##x
#define MINI_OV 0
#include "fast16_mini_mreg.inc"
#undef MINI_OV
#undef MN
    }
    {
        mh_t *const t = mtab_ov;
#define MN(x) mo_##x
#define MINI_OV 1
#include "fast16_mini_mreg.inc"
#undef MINI_OV
#undef MN
    }
#else
    m_register(mtab); mo_register(mtab_ov);
#endif
#define MSET(op, h) (mtab[op] = MREF(h))
#if !F16_ASM
    MSET(0x04, m_0x04); MSET(0x05, m_0x05); MSET(0x0c, m_0x0c); MSET(0x0d, m_0x0d); MSET(0x14, m_0x14); MSET(0x15, m_0x15);
    MSET(0x1c, m_0x1c); MSET(0x1d, m_0x1d); MSET(0x24, m_0x24); MSET(0x25, m_0x25); MSET(0x2c, m_0x2c); MSET(0x2d, m_0x2d);
    MSET(0x34, m_0x34); MSET(0x35, m_0x35); MSET(0x3c, m_0x3c); MSET(0x3d, m_0x3d);
    for (i = 0x40; i < 0x48; i++) { MSET(i, m_inc); MSET(i + 8, m_dec); }
    for (i = 0x50; i < 0x58; i++) { if (i != 0x54) MSET(i, m_push); if (i + 8 != 0x5c) MSET(i + 8, m_pop); }   /* PUSH SP / POP SP differ on the V30 */
#endif
#if !F16_ASM
    MSET(0x06, m_pushseg); MSET(0x0e, m_pushseg); MSET(0x16, m_pushseg); MSET(0x1e, m_pushseg);
    MSET(0x07, m_popseg); MSET(0x1f, m_popseg);
#endif
    MSET(0x26, m_pfx); MSET(0x2e, m_pfx); MSET(0x36, m_pfx); MSET(0x3e, m_pfx);
#if !F16_ASM
    MSET(0x70, m_0x70); MSET(0x71, m_0x71); MSET(0x72, m_0x72); MSET(0x73, m_0x73); MSET(0x74, m_0x74); MSET(0x75, m_0x75); MSET(0x76, m_0x76); MSET(0x77, m_0x77);
    MSET(0x78, m_0x78); MSET(0x79, m_0x79); MSET(0x7a, m_0x7a); MSET(0x7b, m_0x7b); MSET(0x7c, m_0x7c); MSET(0x7d, m_0x7d); MSET(0x7e, m_0x7e); MSET(0x7f, m_0x7f);
#endif
#if !F16_ASM
    MSET(0xa8, m_a8); MSET(0xa9, m_a9);
#endif
    MSET(0xa4, m_str1); MSET(0xa5, m_str1); MSET(0xaa, m_str1); MSET(0xab, m_str1);   /* LODS stays out: with STOS also here, a V30 program goes wrong after its notice screen - cause not found */
#if !F16_ASM
    MSET(0x8d, m_8d);
    for (i = 0x90; i < 0x98; i++) MSET(i, m_xchg);
    MSET(0x98, m_cbw); MSET(0x99, m_cwd); MSET(0x9c, m_pushf); MSET(0x9e, m_sahf); MSET(0x9f, m_lahf);
    for (i = 0xb0; i < 0xb8; i++) { MSET(i, m_movi8); MSET(i + 8, m_movi16); }
    MSET(0xc3, m_c3);
    for (i = 0xe0; i < 0xe4; i++) MSET(i, m_loop);
#endif
    MSET(0x9d, m_popf);
    MSET(0xcc, m_int); MSET(0xcd, m_int); MSET(0xcf, m_cf);
    MSET(0xe4, m_io); MSET(0xe5, m_io); MSET(0xe6, m_io); MSET(0xe7, m_io); MSET(0xec, m_io); MSET(0xed, m_io); MSET(0xee, m_io); MSET(0xef, m_io);
#if !F16_ASM
    MSET(0xe8, m_e8); MSET(0xe9, m_e9); MSET(0xeb, m_eb);
    MSET(0xf5, m_cmc); MSET(0xf8, m_clc); MSET(0xf9, m_stc); MSET(0xfa, m_cli); MSET(0xfc, m_cld); MSET(0xfd, m_std);
#endif
    MSET(0xfb, m_sti);
#undef MSET
}
