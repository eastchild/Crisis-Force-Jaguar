#!/usr/bin/env python3
"""
Émulateur minimal des processeurs RISC de la Jaguar (GPU Tom / DSP Jerry),
pour tester gpu.s et dsp.s hors matériel.

Encodage (vérifié sur rmac) : opcode = bits 15-10, reg1 (source / immédiat)
= bits 9-5, reg2 (destination / condition) = bits 4-0. MOVEI : mot bas puis
mot haut. SHLQ code 32-n, SHRQ/SHARQ/RORQ codent n, ADDQ/SUBQ codent 0 pour 32.
Saut retardé : l'instruction qui suit JUMP/JR s'exécute toujours.
Registres : 2 bancs ; le banc 0 est imposé pendant une interruption (IMASK).
"""

MASK = 0xFFFFFFFF

# Blitter (registres de Tom, écrits par le GPU)
A1_BASE = 0xF02200
B_CMD = 0xF02238
SRCEN, UPDA1, UPDA2 = 0x1, 0x200, 0x400
LFU_MASK, LFU_REPLACE = 0x01E00000, 0x01800000


def s32(v):
    v &= MASK
    return v - (1 << 32) if v & 0x80000000 else v


class JRisc:
    def __init__(self, mem, ram_base, flags_addr):
        """mem : objet avec r8/r16/r32/w8/w16/w32 (adresses 24 bits)"""
        self.mem = mem
        self.ram_base = ram_base
        self.flags_addr = flags_addr
        self.regs = [[0] * 32, [0] * 32]
        self.z = self.n = self.c = 0
        self.imask = 0
        self.regpage = 0
        self.int_enable = 0          # bits 4-8 de FLAGS
        self.pc = ram_base
        self.delay = None            # cible d'un saut pris (exécutée après l'instruction suivante)
        self.divctrl = 0
        self.hidata = 0              # G_HIDATA (FLAGS + $18) : long haut de LOADP / STOREP
        self.steps = 0

    # ---------- registres ----------
    @property
    def bank(self):
        return self.regs[0 if self.imask else self.regpage]

    def flags_value(self):
        return (self.z | (self.c << 1) | (self.n << 2) | (self.imask << 3) | (self.int_enable << 4)
                | (self.regpage << 14))

    def write_flags(self, v):
        self.z, self.c, self.n = v & 1, (v >> 1) & 1, (v >> 2) & 1
        if not (v & 8):
            self.imask = 0               # IMASK : seul l'effacement est possible
        self.int_enable = (v >> 4) & 0x1F
        self.regpage = (v >> 14) & 1

    def set_zn(self, v):
        v &= MASK
        self.z = int(v == 0)
        self.n = (v >> 31) & 1
        return v

    # ---------- interruption ----------
    def interrupt(self, vector):
        """Déclenche l'interruption `vector` si autorisée (bit d'activation et IMASK)"""
        if self.imask or not (self.int_enable >> vector) & 1:
            return False
        r = self.regs[0]
        r[31] = (r[31] - 4) & MASK
        # Adresse empilée : dernière instruction exécutée (le gestionnaire ajoute 2)
        self.mem.w32(r[31], (self.pc - 2) & MASK)
        self.imask = 1
        self.pc = self.ram_base + vector * 16
        self.delay = None
        return True

    # ---------- exécution ----------
    def cond(self, cc):
        if cc & 1 and self.z:
            return False
        if cc & 2 and not self.z:
            return False
        flag = self.n if cc & 0x10 else self.c
        if cc & 4 and flag:
            return False
        if cc & 8 and not flag:
            return False
        return True

    def step(self):
        m = self.mem
        pc = self.pc
        w = m.r16(pc)
        op, r1, r2 = w >> 10, (w >> 5) & 31, w & 31
        npc = pc + 2
        reg = self.bank
        target = None
        if op == 38:                                   # MOVEI
            lo, hi = m.r16(pc + 2), m.r16(pc + 4)
            reg[r2] = lo | (hi << 16)
            npc = pc + 6
        elif op == 0:                                  # ADD
            a, b = reg[r2], reg[r1]
            res = a + b
            self.c = int(res > MASK)
            reg[r2] = self.set_zn(res)
        elif op == 2:                                  # ADDQ
            n = r1 or 32
            res = reg[r2] + n
            self.c = int(res > MASK)
            reg[r2] = self.set_zn(res)
        elif op == 3:                                  # ADDQT
            reg[r2] = (reg[r2] + (r1 or 32)) & MASK
        elif op == 4:                                  # SUB
            a, b = reg[r2], reg[r1]
            self.c = int(b > a)
            reg[r2] = self.set_zn(a - b)
        elif op == 6:                                  # SUBQ
            n = r1 or 32
            a = reg[r2]
            self.c = int(n > a)
            reg[r2] = self.set_zn(a - n)
        elif op == 7:                                  # SUBQT
            reg[r2] = (reg[r2] - (r1 or 32)) & MASK
        elif op == 8:                                  # NEG
            a = reg[r2]
            self.c = int(a != 0)
            reg[r2] = self.set_zn(-a)
        elif op == 9:
            reg[r2] = self.set_zn(reg[r2] & reg[r1])
        elif op == 10:
            reg[r2] = self.set_zn(reg[r2] | reg[r1])
        elif op == 11:
            reg[r2] = self.set_zn(reg[r2] ^ reg[r1])
        elif op == 12:
            reg[r2] = self.set_zn(~reg[r2])
        elif op == 13:                                 # BTST
            self.z = int(not (reg[r2] >> r1) & 1)
        elif op == 14:                                 # BSET
            reg[r2] = self.set_zn(reg[r2] | (1 << r1))
        elif op == 15:                                 # BCLR
            reg[r2] = self.set_zn(reg[r2] & ~(1 << r1))
        elif op == 16:                                 # MULT (16x16 non signé)
            reg[r2] = self.set_zn((reg[r2] & 0xFFFF) * (reg[r1] & 0xFFFF))
        elif op == 21:                                 # DIV (non signé)
            d = reg[r1]
            reg[r2] = (reg[r2] // d) & MASK if d else MASK
        elif op == 23:                                 # SH (positif : droite)
            n = s32(reg[r1])
            a = reg[r2]
            if n >= 0:
                self.c = a & 1
                reg[r2] = self.set_zn(a >> min(n, 32))
            else:
                self.c = (a >> 31) & 1
                reg[r2] = self.set_zn(a << min(-n, 32))
        elif op == 24:                                 # SHLQ (champ = 32 - n)
            n = 32 - r1
            a = reg[r2]
            self.c = (a >> 31) & 1
            reg[r2] = self.set_zn(a << n)
        elif op == 25:                                 # SHRQ
            n = r1 or 32
            a = reg[r2]
            self.c = a & 1
            reg[r2] = self.set_zn(a >> n)
        elif op == 27:                                 # SHARQ
            n = r1 or 32
            a = s32(reg[r2])
            self.c = a & 1
            reg[r2] = self.set_zn(a >> n)
        elif op == 29:                                 # RORQ
            n = (r1 or 32) & 31
            a = reg[r2]
            self.c = (a >> 31) & 1
            reg[r2] = self.set_zn((a >> n) | (a << (32 - n)) if n else a)
        elif op == 30:                                 # CMP : r2 - r1
            a, b = reg[r2], reg[r1]
            self.c = int(b > a)
            self.set_zn(a - b)
        elif op == 31:                                 # CMPQ
            n = r1 - 32 if r1 & 16 else r1
            a = reg[r2]
            bb = n & MASK
            self.c = int(bb > a)
            self.set_zn(a - bb)
        elif op == 34:                                 # MOVE
            reg[r2] = reg[r1]
        elif op == 35:                                 # MOVEQ
            reg[r2] = r1
        elif op == 39:                                 # LOADB
            reg[r2] = self.load(reg[r1], 1)
        elif op == 40:
            reg[r2] = self.load(reg[r1], 2)
        elif op == 41:                                 # LOAD
            reg[r2] = self.load(reg[r1], 4)
        elif op in (43, 44):                           # LOAD (R14/R15 + n)
            base = reg[14 if op == 43 else 15]
            reg[r2] = self.load(base + 4 * (r1 or 32), 4)
        elif op == 45:                                 # STOREB
            self.store(reg[r1], reg[r2], 1)
        elif op == 46:
            self.store(reg[r1], reg[r2], 2)
        elif op == 47:                                 # STORE
            self.store(reg[r1], reg[r2], 4)
        elif op in (49, 50):                           # STORE (R14/R15 + n)
            base = reg[14 if op == 49 else 15]
            self.store(base + 4 * (r1 or 32), reg[r2], 4)
        elif op == 42:                                 # LOADP (GPU) : long haut -> G_HIDATA
            a = reg[r1] & 0xFFFFF8
            self.hidata = self.mem.r32(a)
            reg[r2] = self.mem.r32(a + 4)
        elif op == 48:                                 # STOREP (GPU) : G_HIDATA -> long haut
            a = reg[r1] & 0xFFFFF8
            self.mem.w32(a, self.hidata & MASK)
            self.mem.w32(a + 4, reg[r2] & MASK)
        elif op in (58, 59):                           # LOAD (R14/R15 + Rn)
            base = reg[14 if op == 58 else 15]
            reg[r2] = self.load(base + reg[r1], 4)
        elif op in (60, 61):
            base = reg[14 if op == 60 else 15]
            self.store(base + reg[r1], reg[r2], 4)
        elif op == 51:                                 # MOVE PC
            reg[r2] = pc
        elif op == 52:                                 # JUMP
            if self.cond(r2):
                target = reg[r1]
        elif op == 53:                                 # JR
            if self.cond(r2):
                off = r1 - 32 if r1 & 16 else r1
                target = npc + off * 2
        elif op == 57:                                 # NOP
            pass
        else:
            raise RuntimeError(f'opcode RISC {op} non émulé en ${pc:06X}')
        self.steps += 1
        if self.delay is not None:
            npc, self.delay = self.delay, None
        if target is not None:
            self.delay = target & MASK
        self.pc = npc

    def load(self, addr, size):
        addr &= 0xFFFFFF
        if size == 4 and addr == self.flags_addr:
            return self.flags_value()
        if size == 4 and addr == self.flags_addr + 0x18:
            return self.hidata
        if size == 4 and addr == B_CMD and self.flags_addr == 0xF02100:
            return 1                                    # blitter au repos (copie immédiate)
        return self.mem.r32(addr) if size == 4 else self.mem.r16(addr) if size == 2 else self.mem.r8(addr)

    def blit(self, cmd):
        """Blitter, sous-ensemble utilisé par gpu.s : copie de rectangle
        (SRCEN, LFU source), A1 = destination, A2 = source, 8 bpp, pointeurs
        (x, y) et largeur des fenêtres (A*_FLAGS), pas en fin de ligne
        (UPDA1 / UPDA2) ; copie immédiate (le GPU attend le repos de toute façon)"""
        r = self.mem.r32
        if cmd & ~(SRCEN | UPDA1 | UPDA2 | LFU_MASK) or cmd & LFU_MASK != LFU_REPLACE or not cmd & SRCEN:
            raise NotImplementedError(f'B_CMD ${cmd:08X}')

        def width(flags):
            if (flags >> 3) & 7 != 3:
                raise NotImplementedError(f'A*_FLAGS ${flags:08X} : 8 bpp seulement')
            f = (flags >> 9) & 63
            return ((4 | (f & 3)) << (f >> 2)) >> 2

        def xy(v):
            return s32(v << 16) >> 16, s32(v) >> 16

        b1, w1 = r(A1_BASE), width(r(A1_BASE + 4))
        b2, w2 = r(A1_BASE + 0x24), width(r(A1_BASE + 0x28))
        x1, y1 = xy(r(A1_BASE + 0x0C))
        x2, y2 = xy(r(A1_BASE + 0x30))
        sx1, sy1 = xy(r(A1_BASE + 0x10))
        sx2, sy2 = xy(r(A1_BASE + 0x34))
        cnt = r(A1_BASE + 0x3C)
        inner, outer = cnt & 0xFFFF or 0x10000, cnt >> 16 or 0x10000
        for _ in range(outer):
            for i in range(inner):
                self.mem.w8(b1 + y1 * w1 + x1 + i, self.mem.r8(b2 + y2 * w2 + x2 + i))
            x1 += inner
            x2 += inner
            if cmd & UPDA1:
                x1, y1 = x1 + sx1, y1 + sy1
            if cmd & UPDA2:
                x2, y2 = x2 + sx2, y2 + sy2

    def store(self, addr, val, size):
        addr &= 0xFFFFFF
        if size == 4 and addr == self.flags_addr:
            self.write_flags(val)
            return
        if size == 4 and addr == self.flags_addr + 0x18:
            self.hidata = val & MASK
            return
        if size == 4 and addr == B_CMD and self.flags_addr == 0xF02100:
            self.blit(val & MASK)
            return
        if size == 4:
            self.mem.w32(addr, val & MASK)
        elif size == 2:
            self.mem.w16(addr, val & 0xFFFF)
        else:
            self.mem.w8(addr, val & 0xFF)


class Memory:
    """Mémoire 16 Mo creuse, gros-boutiste, avec crochets d'écriture"""

    def __init__(self):
        self.data = bytearray(0x1000000)
        self.write_hooks = {}

    def r8(self, a):
        return self.data[a & 0xFFFFFF]

    def r16(self, a):
        a &= 0xFFFFFF
        return (self.data[a] << 8) | self.data[a + 1]

    def r32(self, a):
        a &= 0xFFFFFF
        d = self.data
        return (d[a] << 24) | (d[a + 1] << 16) | (d[a + 2] << 8) | d[a + 3]

    def w8(self, a, v):
        self.data[a & 0xFFFFFF] = v

    def w16(self, a, v):
        a &= 0xFFFFFF
        self.data[a:a + 2] = v.to_bytes(2, 'big')

    def w32(self, a, v):
        a &= 0xFFFFFF
        h = self.write_hooks.get(a)
        if h:
            h(v)
        self.data[a:a + 4] = v.to_bytes(4, 'big')
