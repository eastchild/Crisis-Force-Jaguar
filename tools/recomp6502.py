#!/usr/bin/env python3
"""
Recompilation statique du code 6502 de Crisis Force en assembleur 68000 (rmac).

Entrées :
  - la ROM NES (PRG-ROM 128 Ko, 16 banques de 8 Ko, mapper VRC4) ;
  - les relevés de couverture de tools/nes_trace.py (assets/trace/*.json) :
    instructions exécutées par banque, cibles des sauts indirects, banques
    lues par les accès aux données.

Sortie : source/nes_code.s (généré), à inclure dans main.s.

Modèle d'exécution (registres 68000) :
  d0 = A, d1 = X, d2 = Y (octet ; X/Y gardent l'octet haut du mot à 0 pour
  servir d'index), d6 = drapeau V (octet non nul = V), a2 = pointeur de pile
  6502 (adresse hôte de $0100+S+1 : PHA = move.b d0,-(a2)), a4 = WRAM $6000,
  a5 = RAM NES + $80 (la page zéro tient dans un déplacement 8 bits signé),
  a6 = variables du runtime (nes_runtime.s). d3-d5, d7, a0, a1, a3 : temporaires.

Drapeaux 6502 : N/Z dans N/Z du CCR, retenue C dans le drapeau X du 68000
(addx/subx/roxl/roxr l'utilisent directement), V matérialisé dans d6.
À l'intérieur d'un bloc, le générateur suit l'emplacement réel de chaque
drapeau (retenue inversée après CMP/SBC, connue après CLC/SEC...) et ne
remet la forme canonique qu'aux frontières de blocs, si le drapeau est
vivant (analyse de vivacité globale).

Pile : JSR/RTS utilisent la pile 68000 ; la pile 6502 ne reçoit pas les
adresses de retour mais S est ajusté de 2 (les PHA/PLA restent exacts).
Le répartiteur $C75F (JSR suivi d'une table d'adresses, lue via la pile)
est traduit en saut indexé direct.

Usage : python recomp6502.py
"""

import collections
import json
import rom_patches
import rom_path
import os
import sys
from collections import defaultdict

from py65.devices.mpu6502 import MPU as _MPU

CYCLES = _MPU().cycletime              # cycles de base de chaque opcode 6502

PROJECT_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ROM_PATH = None                      # rom_path.rom_path() (CRISIS_FORCE_ROM, projet, parent)
TRACE_DIR = os.path.join(PROJECT_DIR, 'assets', 'trace')
OUT_PATH = os.path.join(PROJECT_DIR, 'source', 'nes_code.s')
PRG_BIN = os.path.join(PROJECT_DIR, 'include', 'nes', 'prg.bin')
CHR_BIN = os.path.join(PROJECT_DIR, 'include', 'nes', 'chr.bin')

FIXED_C000 = 14          # VRC4, $9002 bit 1 = 0 : $C000-$DFFF = avant-dernière banque
FIXED_E000 = 15

# Routines « répartiteur » : JSR suivi d'une table d'adresses .dw, indexée par A
DISPATCHERS = {0xC75F}

# Routines remplacées par une version 68000 native (source/nes_hle.s)
HLE = {
    (4, 0x8001): 'hle_sprites',     # objets -> OAM (métasprites)
    (15, 0xEC4C): 'hle_pads',       # lecture des manettes
    (15, 0xEAE7): 'hle_idle',       # boucle principale : stop jusqu'à l'interruption
}

# --------------------------------------------------------------------------
# Table des opcodes 6502 officiels : opcode -> (mnémonique, mode)
# --------------------------------------------------------------------------
MODES_LEN = {'imp': 1, 'acc': 1, 'imm': 2, 'zp': 2, 'zpx': 2, 'zpy': 2, 'abs': 3, 'abx': 3,
             'aby': 3, 'ind': 3, 'izx': 2, 'izy': 2, 'rel': 2}
OPTABLE = {}


def _ops(mn, pairs):
    for op, mode in pairs:
        OPTABLE[op] = (mn, mode)


_ops('ADC', [(0x69, 'imm'), (0x65, 'zp'), (0x75, 'zpx'), (0x6D, 'abs'), (0x7D, 'abx'), (0x79, 'aby'), (0x61, 'izx'), (0x71, 'izy')])
_ops('AND', [(0x29, 'imm'), (0x25, 'zp'), (0x35, 'zpx'), (0x2D, 'abs'), (0x3D, 'abx'), (0x39, 'aby'), (0x21, 'izx'), (0x31, 'izy')])
_ops('ASL', [(0x0A, 'acc'), (0x06, 'zp'), (0x16, 'zpx'), (0x0E, 'abs'), (0x1E, 'abx')])
_ops('BCC', [(0x90, 'rel')]); _ops('BCS', [(0xB0, 'rel')]); _ops('BEQ', [(0xF0, 'rel')]); _ops('BMI', [(0x30, 'rel')])
_ops('BNE', [(0xD0, 'rel')]); _ops('BPL', [(0x10, 'rel')]); _ops('BVC', [(0x50, 'rel')]); _ops('BVS', [(0x70, 'rel')])
_ops('BIT', [(0x24, 'zp'), (0x2C, 'abs')])
_ops('BRK', [(0x00, 'imp')])
_ops('CLC', [(0x18, 'imp')]); _ops('CLD', [(0xD8, 'imp')]); _ops('CLI', [(0x58, 'imp')]); _ops('CLV', [(0xB8, 'imp')])
_ops('CMP', [(0xC9, 'imm'), (0xC5, 'zp'), (0xD5, 'zpx'), (0xCD, 'abs'), (0xDD, 'abx'), (0xD9, 'aby'), (0xC1, 'izx'), (0xD1, 'izy')])
_ops('CPX', [(0xE0, 'imm'), (0xE4, 'zp'), (0xEC, 'abs')])
_ops('CPY', [(0xC0, 'imm'), (0xC4, 'zp'), (0xCC, 'abs')])
_ops('DEC', [(0xC6, 'zp'), (0xD6, 'zpx'), (0xCE, 'abs'), (0xDE, 'abx')])
_ops('DEX', [(0xCA, 'imp')]); _ops('DEY', [(0x88, 'imp')])
_ops('EOR', [(0x49, 'imm'), (0x45, 'zp'), (0x55, 'zpx'), (0x4D, 'abs'), (0x5D, 'abx'), (0x59, 'aby'), (0x41, 'izx'), (0x51, 'izy')])
_ops('INC', [(0xE6, 'zp'), (0xF6, 'zpx'), (0xEE, 'abs'), (0xFE, 'abx')])
_ops('INX', [(0xE8, 'imp')]); _ops('INY', [(0xC8, 'imp')])
_ops('JMP', [(0x4C, 'abs'), (0x6C, 'ind')])
_ops('JSR', [(0x20, 'abs')])
_ops('LDA', [(0xA9, 'imm'), (0xA5, 'zp'), (0xB5, 'zpx'), (0xAD, 'abs'), (0xBD, 'abx'), (0xB9, 'aby'), (0xA1, 'izx'), (0xB1, 'izy')])
_ops('LDX', [(0xA2, 'imm'), (0xA6, 'zp'), (0xB6, 'zpy'), (0xAE, 'abs'), (0xBE, 'aby')])
_ops('LDY', [(0xA0, 'imm'), (0xA4, 'zp'), (0xB4, 'zpx'), (0xAC, 'abs'), (0xBC, 'abx')])
_ops('LSR', [(0x4A, 'acc'), (0x46, 'zp'), (0x56, 'zpx'), (0x4E, 'abs'), (0x5E, 'abx')])
_ops('NOP', [(0xEA, 'imp')])
_ops('ORA', [(0x09, 'imm'), (0x05, 'zp'), (0x15, 'zpx'), (0x0D, 'abs'), (0x1D, 'abx'), (0x19, 'aby'), (0x01, 'izx'), (0x11, 'izy')])
_ops('PHA', [(0x48, 'imp')]); _ops('PHP', [(0x08, 'imp')]); _ops('PLA', [(0x68, 'imp')]); _ops('PLP', [(0x28, 'imp')])
_ops('ROL', [(0x2A, 'acc'), (0x26, 'zp'), (0x36, 'zpx'), (0x2E, 'abs'), (0x3E, 'abx')])
_ops('ROR', [(0x6A, 'acc'), (0x66, 'zp'), (0x76, 'zpx'), (0x6E, 'abs'), (0x7E, 'abx')])
_ops('RTI', [(0x40, 'imp')]); _ops('RTS', [(0x60, 'imp')])
_ops('SBC', [(0xE9, 'imm'), (0xE5, 'zp'), (0xF5, 'zpx'), (0xED, 'abs'), (0xFD, 'abx'), (0xF9, 'aby'), (0xE1, 'izx'), (0xF1, 'izy')])
_ops('SEC', [(0x38, 'imp')]); _ops('SED', [(0xF8, 'imp')]); _ops('SEI', [(0x78, 'imp')])
_ops('STA', [(0x85, 'zp'), (0x95, 'zpx'), (0x8D, 'abs'), (0x9D, 'abx'), (0x99, 'aby'), (0x81, 'izx'), (0x91, 'izy')])
_ops('STX', [(0x86, 'zp'), (0x96, 'zpy'), (0x8E, 'abs')])
_ops('STY', [(0x84, 'zp'), (0x94, 'zpx'), (0x8C, 'abs')])
_ops('TAX', [(0xAA, 'imp')]); _ops('TAY', [(0xA8, 'imp')]); _ops('TSX', [(0xBA, 'imp')])
_ops('TXA', [(0x8A, 'imp')]); _ops('TXS', [(0x9A, 'imp')]); _ops('TYA', [(0x98, 'imp')])

# Drapeaux utilisés / définis (N, Z, C, V) pour l'analyse de vivacité
NZ = {'N', 'Z'}
ALLF = {'N', 'Z', 'C', 'V'}
FLAG_USE = defaultdict(set, {
    'ADC': {'C'}, 'SBC': {'C'}, 'ROL': {'C'}, 'ROR': {'C'},
    'BCC': {'C'}, 'BCS': {'C'}, 'BEQ': {'Z'}, 'BNE': {'Z'}, 'BMI': {'N'}, 'BPL': {'N'},
    'BVC': {'V'}, 'BVS': {'V'}, 'PHP': ALLF,
})
FLAG_DEF = defaultdict(set, {
    'ADC': ALLF, 'SBC': ALLF, 'AND': NZ, 'ORA': NZ, 'EOR': NZ, 'ASL': NZ | {'C'}, 'LSR': NZ | {'C'},
    'ROL': NZ | {'C'}, 'ROR': NZ | {'C'}, 'BIT': ALLF - {'C'}, 'CMP': NZ | {'C'}, 'CPX': NZ | {'C'},
    'CPY': NZ | {'C'}, 'DEC': NZ, 'INC': NZ, 'DEX': NZ, 'DEY': NZ, 'INX': NZ, 'INY': NZ,
    'LDA': NZ, 'LDX': NZ, 'LDY': NZ, 'TAX': NZ, 'TAY': NZ, 'TXA': NZ, 'TYA': NZ, 'TSX': NZ,
    'PLA': NZ, 'PLP': ALLF, 'CLC': {'C'}, 'SEC': {'C'}, 'CLV': {'V'},
})


def s8(v):
    return v - 256 if v >= 128 else v


class Insn:
    __slots__ = ('bank', 'pc', 'op', 'mn', 'mode', 'len', 'operand', 'target', 'succ', 'live_out',
                 'label', 'traced', 'jtab', 'drop_ret', 'ret_write')

    def __init__(self, bank, pc, raw):
        self.bank, self.pc = bank, pc
        self.op = raw[0]
        self.mn, self.mode = OPTABLE[self.op]
        self.len = MODES_LEN[self.mode]
        self.operand = 0
        if self.len == 2:
            self.operand = raw[1]
        elif self.len == 3:
            self.operand = raw[1] | (raw[2] << 8)
        self.target = None
        if self.mode == 'rel':
            self.target = (pc + 2 + s8(self.operand)) & 0xFFFF
        elif self.mn in ('JMP', 'JSR') and self.mode == 'abs':
            self.target = self.operand
        self.succ = []
        self.live_out = set(ALLF)
        self.label = False
        self.traced = False
        self.jtab = None
        self.drop_ret = False       # 2e PLA d'une paire qui jette l'adresse de retour
        self.ret_write = False      # JSR vers une routine qui lit/jette son adresse de retour


def label(bank, pc):
    return f'L{bank:X}{pc:04X}'


def slot_of(addr):
    return (addr - 0x8000) >> 13


class Recompiler:
    def __init__(self, rom, traces):
        prg_size = rom[4] * 16384
        # ROM modifiée pour le portage (tools/rom_patches.py) ; les instructions
        # tracées sur la ROM d'origine à l'intérieur d'une zone modifiée (hors
        # son premier octet) sont ignorées
        self.prg = bytes(rom_patches.apply(bytearray(rom[16:16 + prg_size])))
        skip = set()
        for off, _, data in rom_patches.patches():
            b, o = off // 8192, off % 8192
            for k in range(1, len(data)):
                skip.add((b, o + k))
        self.chr = rom[16 + prg_size:16 + prg_size + rom[5] * 8192]
        self.nbanks = prg_size // 8192
        self.code = defaultdict(set)
        self.indirect = defaultdict(set)
        self.data_banks = defaultdict(set)
        for t in traces:
            for b, pcs in t['code'].items():
                b = int(b)
                self.code[b].update(pc for pc in pcs if (b, pc & 0x1FFF) not in skip)
            for b, pc, tg in t['indirect']:
                self.indirect[(b, pc)].update(tuple(x) for x in tg)
            for b, pc, tg in t.get('data_banks', []):
                self.data_banks[(b, pc)].update(tuple(x) for x in tg)
        self.insns = {}          # (banque, pc) -> Insn
        # Instructions exécutées en IRQ (tools/ppu_timing.py) : cycles 6502 comptés
        tp = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), 'assets', 'irq_code.json')
        self.irq_code = set(json.load(open(tp))) if os.path.exists(tp) else set()
        self.warnings = []
        self.dyn_targets = defaultdict(set)    # banque -> adresses cibles de sauts dynamiques

    # ---------------- lecture ROM ----------------
    def rom_byte(self, bank, addr):
        return self.prg[bank * 8192 + (addr & 0x1FFF)]

    def bank_for(self, cur_bank, cur_pc, addr):
        """Banque statique d'une adresse de code vue depuis (cur_bank, cur_pc), ou None si dynamique"""
        if addr >= 0xE000:
            return FIXED_E000
        if addr >= 0xC000:
            return FIXED_C000
        if addr >= 0x8000 and cur_pc >= 0x8000 and slot_of(addr) == slot_of(cur_pc):
            return cur_bank
        return None

    def decode(self, bank, pc):
        raw = [self.rom_byte(bank, pc + i) for i in range(3)]
        if raw[0] not in OPTABLE:
            return None
        return Insn(bank, pc, raw)

    # ---------------- découverte du code ----------------
    def discover(self):
        work = []
        for b, pcs in self.code.items():
            if b < 0:
                if pcs:
                    self.warnings.append(f'code exécuté hors ROM : {sorted(pcs)[:8]}')
                continue
            for pc in pcs:
                work.append((b, pc, True))
        seen_bytes = defaultdict(dict)       # banque -> octet -> pc de l'instruction qui le couvre
        traced_starts = {(b, pc) for b, pcs in self.code.items() for pc in pcs if b >= 0}
        # Instructions tracées d'abord, puis descente récursive
        work.sort(key=lambda w: not w[2])
        while work:
            b, pc, traced = work.pop()
            if (b, pc) in self.insns:
                continue
            ins = self.decode(b, pc)
            if ins is None:
                if traced:
                    self.warnings.append(f'opcode inconnu exécuté en {b}:{pc:04X}')
                continue
            # Recouvrement avec une instruction tracée : on ignore la découverte
            cover = seen_bytes[b]
            if not traced and any((b, pc + i) in traced_starts or (pc + i) in cover for i in range(ins.len)):
                continue
            for i in range(ins.len):
                cover[pc + i] = pc
            ins.traced = traced
            self.insns[(b, pc)] = ins
            for nb, npc in self.static_successors(ins):
                if (nb, npc) not in self.insns:
                    work.append((nb, npc, (nb, npc) in traced_starts))
        # Tables de répartition après JSR $C75F
        for ins in list(self.insns.values()):
            if ins.mn == 'JSR' and ins.target in DISPATCHERS:
                self.build_jtab(ins)

    def static_successors(self, ins):
        out = []
        b, pc = ins.bank, ins.pc
        nxt = (pc + ins.len) & 0xFFFF
        same_region = lambda a: a >= 0x8000 and self.bank_for(b, pc, a) is not None
        if ins.mn in ('RTS', 'RTI', 'BRK') or (ins.mn == 'JMP'):
            if ins.mn == 'JMP' and ins.mode == 'abs' and same_region(ins.target):
                out.append((self.bank_for(b, pc, ins.target), ins.target))
            return out
        if ins.mn == 'JSR':
            if same_region(ins.target):
                out.append((self.bank_for(b, pc, ins.target), ins.target))
            if ins.target in DISPATCHERS:
                return out           # la table suit le JSR
            if same_region(nxt):
                out.append((self.bank_for(b, pc, nxt), nxt))
            return out
        if ins.mode == 'rel' and same_region(ins.target):
            out.append((self.bank_for(b, pc, ins.target), ins.target))
        if same_region(nxt):
            out.append((self.bank_for(b, pc, nxt), nxt))
        return out

    def build_jtab(self, ins):
        """Table d'adresses qui suit un JSR répartiteur : jusqu'à la prochaine instruction tracée"""
        b = ins.bank
        start = (ins.pc + 3) & 0xFFFF
        entries = []
        a = start
        traced = self.code.get(b, set())
        while len(entries) < 128:
            if a in traced or (a + 1) in traced:
                break
            if (b, a) in self.insns and self.insns[(b, a)].traced:
                break
            t = self.rom_byte(b, a) | (self.rom_byte(b, a + 1) << 8)
            if t < 0x8000:
                break
            entries.append(t)
            a += 2
        ins.jtab = entries
        for t in entries:
            tb = self.bank_for(b, ins.pc, t)
            if tb is not None and (tb, t) not in self.insns:
                # cible de table non tracée : décodée par descente
                self.add_code_from(tb, t)

    def add_code_from(self, b, pc):
        work = [(b, pc)]
        while work:
            b, pc = work.pop()
            if (b, pc) in self.insns:
                continue
            ins = self.decode(b, pc)
            if ins is None:
                continue
            self.insns[(b, pc)] = ins
            work.extend(self.static_successors(ins))

    # ---------------- graphe et vivacité des drapeaux ----------------
    def build_cfg(self):
        for ins in self.insns.values():
            b, pc = ins.bank, ins.pc
            nxt = (pc + ins.len) & 0xFFFF
            succ = []
            if ins.mn in ('RTS', 'RTI', 'BRK'):
                succ = None                         # inconnu : tout vivant
            elif ins.mn == 'JMP':
                if ins.mode == 'abs':
                    tb = self.bank_for(b, pc, ins.target)
                    succ = [(tb, ins.target)] if tb is not None and (tb, ins.target) in self.insns else None
                else:
                    succ = None
            elif ins.mn == 'JSR':
                if ins.jtab is not None:
                    succ = [(self.bank_for(b, pc, t), t) for t in ins.jtab]
                    succ = [s for s in succ if s[0] is not None and s in self.insns] or None
                    if succ is not None and len(succ) != len(ins.jtab):
                        succ = None
                else:
                    tb = self.bank_for(b, pc, ins.target)
                    callee = (tb, ins.target) if tb is not None else None
                    ret = (self.bank_for(b, pc, nxt), nxt)
                    succ = []
                    if callee and callee in self.insns:
                        succ.append(callee)
                    else:
                        succ = None
                    if succ is not None and ret[0] is not None and ret in self.insns:
                        succ.append(ret)
                    elif succ is not None:
                        succ = None
            else:
                if ins.mode == 'rel':
                    tb = self.bank_for(b, pc, ins.target)
                    t = (tb, ins.target)
                    succ.append(t if t in self.insns else None)
                nb = self.bank_for(b, pc, nxt)
                succ.append((nb, nxt) if (nb, nxt) in self.insns else None)
                if None in succ:
                    succ = None
            ins.succ = succ
            # Étiquettes : cibles de branchement/saut/appel et points de retour
            if succ:
                for s in succ:
                    if s != (b, nxt) or ins.mn == 'JSR':
                        self.insns[s].label = True
        # Points d'entrée atteints dynamiquement : cibles de JMP (ind), et RTS qui ne
        # reviennent pas après un JSR (saut calculé). Les retours d'interruption
        # (RTI) reviennent par la pile 68000 et ne créent pas d'étiquette.
        ret_points = set()
        for ins in self.insns.values():
            if ins.mn == 'JSR':
                nxt = (ins.pc + 3) & 0xFFFF
                ret_points.add((self.bank_for(ins.bank, ins.pc, nxt), nxt))
        self.rts_tricks = []
        for (b, pc), tg in self.indirect.items():
            src = self.insns.get((b, pc))
            if src is None or src.mn == 'RTI':
                continue
            for nb, npc in tg:
                if src.mn == 'RTS' and (nb, npc) not in ret_points:
                    self.rts_tricks.append((b, pc, nb, npc))
                if (nb, npc) in self.insns:
                    self.insns[(nb, npc)].label = True
        for ins in self.insns.values():
            if ins.mn == 'JSR':
                nxt = (ins.pc + 3) & 0xFFFF
                nb = self.bank_for(ins.bank, ins.pc, nxt)
                if nb is not None and (nb, nxt) in self.insns:
                    self.insns[(nb, nxt)].label = True
        self.stack_analysis()
        self.return_sites()
        self.liveness()

    def stack_analysis(self):
        """
        Profondeur de pile relative à l'entrée de chaque routine (cible de JSR).
        Une paire PLA PLA consécutive à la profondeur 0 jette l'adresse de retour :
        le code 68000 doit aussi dépiler la sienne. Les JSR vers ces routines écrivent
        la vraie adresse de retour dans la pile 6502 (A reçoit son octet haut).
        """
        entries = set()
        for ins in self.insns.values():
            if ins.mn == 'JSR' and ins.jtab is None:
                tb = self.bank_for(ins.bank, ins.pc, ins.target)
                cands = [tb] if tb is not None else [b for b in self.code if b >= 0 and ins.target in self.code[b]]
                for b in cands:
                    entries.add((b, ins.target))
            if ins.jtab:
                for t in ins.jtab:
                    tb = self.bank_for(ins.bank, ins.pc, t)
                    if tb is not None:
                        entries.add((tb, t))
        self.droppers = set()
        for e in sorted(entries):
            if e not in self.insns:
                continue
            seen = {}
            work = [(e, 0)]
            while work:
                k, d = work.pop()
                if k in seen or k not in self.insns:
                    continue
                seen[k] = d
                ins = self.insns[k]
                nxt = (ins.pc + ins.len) & 0xFFFF
                nk = (self.bank_for(ins.bank, ins.pc, nxt), nxt)
                if ins.mn == 'PLA' and d == 0 and nk in self.insns and self.insns[nk].mn == 'PLA':
                    self.insns[nk].drop_ret = True
                    self.droppers.add(e)
                    continue            # au-delà : contexte de l'appelant
                nd = d + (1 if ins.mn in ('PHA', 'PHP') else -1 if ins.mn in ('PLA', 'PLP') else 0)
                if ins.mn in ('RTS', 'RTI', 'BRK') or (ins.mn == 'JMP' and ins.mode == 'ind'):
                    continue
                succ = []
                if ins.mn == 'JSR':
                    if ins.jtab is None:
                        succ = [nk]
                elif ins.mn == 'JMP':
                    succ = [(self.bank_for(ins.bank, ins.pc, ins.target), ins.target)]
                else:
                    if ins.mode == 'rel':
                        succ.append((self.bank_for(ins.bank, ins.pc, ins.target), ins.target))
                    succ.append(nk)
                for sk in succ:
                    if sk[0] is not None:
                        work.append((sk, nd))
        for ins in self.insns.values():
            if ins.mn == 'JSR' and ins.jtab is None:
                tb = self.bank_for(ins.bank, ins.pc, ins.target)
                cands = [tb] if tb is not None else [b for b in self.code if b >= 0 and ins.target in self.code[b]]
                if any((b, ins.target) in self.droppers for b in cands):
                    ins.ret_write = True

    def return_sites(self):
        """
        Analyse interprocédurale des RTS : pour chaque RTS, les points de retour
        (instruction qui suit un JSR) où il peut revenir. Chaque routine (cible de
        JSR) est parcourue sans entrer dans ses appels ; les cibles du répartiteur
        $C75F sont suivies (leur RTS revient à l'appelant de la routine). Un RTS
        reste « inconnu » (tous les drapeaux vivants) s'il est atteint depuis un
        vecteur ou une cible de saut indirect, après un PLA PLA qui jette
        l'adresse de retour, s'il sert de saut calculé, ou si un appelant revient
        vers du code non recompilé.
        """
        UNK = 'UNK'
        self.rts_returns = {}                # clé RTS -> ensemble de clés de retour, ou None
        callers = collections.defaultdict(list)
        for ins in self.insns.values():
            if ins.mn != 'JSR' or ins.jtab is not None:
                continue
            tb = self.bank_for(ins.bank, ins.pc, ins.target)
            cands = [tb] if tb is not None else [b for b in self.code if b >= 0 and ins.target in self.code[b]]
            nxt = (ins.pc + 3) & 0xFFFF
            ret = (self.bank_for(ins.bank, ins.pc, nxt), nxt)
            for b in cands:
                if ins.target in DISPATCHERS:
                    continue                    # suivi à travers (voir walk)
                if ret in self.insns:
                    callers[(b, ins.target)].append(ret)
                elif (b, ins.target) not in self.droppers:
                    # (une routine qui jette son adresse de retour ne revient
                    # jamais après ce JSR : la suite peut ne pas être du code)
                    callers[(b, ins.target)].append(None)
                    if os.environ.get('RTS_DEBUG'):
                        print(f'  retour non recompilé : JSR {ins.bank}:{ins.pc:04X} -> {b}:{ins.target:04X} '
                              f'(retour {ret[0]}:{ret[1]:04X})', file=sys.stderr)
        entries = collections.defaultdict(set)   # clé RTS -> entrées de routine (ou UNK)
        # Cibles relevées des JMP (ind) de chaque répartiteur (JSR sans table résolue)
        disp_targets = collections.defaultdict(set)
        for (b, pc), tg in self.indirect.items():
            src = self.insns.get((b, pc))
            if src is not None and src.mn == 'JMP' and src.mode == 'ind':
                for d in DISPATCHERS:
                    if 0 <= pc - d < 64:
                        disp_targets[d] |= {tuple(x) for x in tg}

        def walk(start, tag):
            seen = set()
            work = [(start, tag)]
            while work:
                k, t = work.pop()
                if (k, t) in seen or k not in self.insns:
                    continue
                seen.add((k, t))
                ins = self.insns[k]
                if getattr(ins, 'drop_ret', False):
                    t = UNK                     # adresse de retour jetée
                if ins.mn == 'RTS':
                    entries[k].add(t)
                    # RTS utilisé comme saut calculé : la cible revient à
                    # l'appelant de la routine courante
                    for tb, tpc, nb, npc in self.rts_tricks:
                        if (tb, tpc) == k:
                            work.append(((nb, npc), t))
                    continue
                if ins.mn in ('RTI', 'BRK'):
                    continue
                nxt = (ins.pc + ins.len) & 0xFFFF
                nk = (self.bank_for(ins.bank, ins.pc, nxt), nxt)
                if ins.mn == 'JMP':
                    if ins.mode == 'abs':
                        work.append(((self.bank_for(ins.bank, ins.pc, ins.target), ins.target), t))
                    else:
                        # JMP (ind) : cibles relevées par la trace, même routine
                        for tg in self.indirect.get(k, ()):
                            work.append((tuple(tg), t))
                elif ins.mn == 'JSR':
                    if ins.jtab is not None:
                        for tg in ins.jtab:
                            work.append(((self.bank_for(ins.bank, ins.pc, tg), tg), t))
                    elif ins.target in DISPATCHERS:
                        # table non résolue : toutes les cibles relevées du répartiteur
                        for tg in disp_targets[ins.target]:
                            work.append((tg, t))
                    else:
                        work.append((nk, t))
                else:
                    if ins.mode == 'rel':
                        work.append(((self.bank_for(ins.bank, ins.pc, ins.target), ins.target), t))
                    work.append((nk, t))

        for e in list(callers):
            walk(e, e)
        # Entrées dynamiques : vecteurs, cibles de sauts indirects (hors retours de RTI)
        for vec in (0xFFFA, 0xFFFC, 0xFFFE):
            a = self.rom_byte(15, vec) | (self.rom_byte(15, vec + 1) << 8)
            walk((self.bank_for(15, 0xE000, a), a), UNK)
        tricks = {(b, pc) for b, pc, _, _ in self.rts_tricks}
        for k, es in entries.items():
            rets = set()
            for e in es:
                if e == UNK:
                    rets = None
                    break
                for r in callers[e]:
                    if r is None:
                        rets = None
                        break
                    rets.add(r)
                if rets is None:
                    break
            self.rts_returns[k] = None if (rets is None or k in tricks) else rets
        known = sum(1 for v in self.rts_returns.values() if v is not None)
        all_rts = [k for k, i in self.insns.items() if i.mn == 'RTS']
        why = collections.Counter()
        for k in all_rts:
            es = entries.get(k)
            if not es:
                why['jamais atteint'] += 1
            elif UNK in es:
                why['entrée dynamique / pile'] += 1
            elif k in tricks:
                why['saut calculé'] += 1
            elif self.rts_returns[k] is None:
                why['appelant non recompilé'] += 1
        print(f'RTS : {known}/{len(all_rts)} avec retours connus ; inconnus : {dict(why)}', file=sys.stderr)
        if os.environ.get('RTS_DEBUG'):
            for k in sorted(all_rts):
                es = entries.get(k)
                if es and UNK in es:
                    print(f'  UNK {k[0]}:{k[1]:04X}', file=sys.stderr)

    def liveness(self):
        """
        Analyse arrière itérative : drapeaux vivants en sortie de chaque instruction.
        Appels sensibles au contexte : pour chaque instruction, résumé de la
        fonction « drapeaux vivants au RTS de la trame courante -> vivants ici »,
        de la forme f(R) = A | (R & B), avec A = f(vide) et B = f(tous). Un JSR
        reçoit A[appelé] | (vivants au retour & B[appelé]) : un drapeau vivant
        au retour d'un seul appelant n'est plus préservé avant les autres appels.
        """
        order = sorted(self.insns, reverse=True)
        simple = lambda ins: ins.mn != 'JSR' or ins.jtab is not None or ins.succ is None
        # 1. Résumés A et B (point fixe commun)
        la = {k: set() for k in self.insns}
        lb = {k: set() for k in self.insns}
        changed = True
        while changed:
            changed = False
            for k in order:
                ins = self.insns[k]
                if ins.mn == 'RTS' and self.rts_returns.get(k) is not None:
                    oa, ob = set(), set(ALLF)
                elif ins.succ is None:
                    oa, ob = set(ALLF), set(ALLF)
                elif not simple(ins):
                    callee, ret = ins.succ
                    oa = la[callee] | (la[ret] & lb[callee])
                    ob = la[callee] | (lb[ret] & lb[callee])
                else:
                    oa, ob = set(), set()
                    for s in ins.succ:
                        oa |= la[s]
                        ob |= lb[s]
                if simple(ins) and ins.mn != 'JSR':
                    ia = (oa - FLAG_DEF[ins.mn]) | FLAG_USE[ins.mn]
                    ib = (ob - FLAG_DEF[ins.mn]) | FLAG_USE[ins.mn]
                else:
                    ia, ib = oa, ob
                if ia != la[k] or ib != lb[k]:
                    la[k], lb[k] = ia, ib
                    changed = True
        # 2. Vivacité réelle : RTS -> union des points de retour
        live_in = {k: set() for k in self.insns}
        for ins in self.insns.values():
            ins.live_out = set(ALLF) if ins.succ is None else set()
        changed = True
        while changed:
            changed = False
            for k in order:
                ins = self.insns[k]
                if ins.mn == 'RTS' and self.rts_returns.get(k) is not None:
                    out = set()
                    for r in self.rts_returns[k]:
                        out |= live_in[r]
                elif ins.succ is None:
                    out = set(ALLF)
                elif not simple(ins):
                    callee, ret = ins.succ
                    out = la[callee] | (live_in[ret] & lb[callee])
                else:
                    out = set()
                    for s in ins.succ:
                        out |= live_in[s]
                ins.live_out = out
                inn = (out - FLAG_DEF[ins.mn]) | FLAG_USE[ins.mn]
                if ins.mn == 'JSR':
                    inn = set(out)
                if inn != live_in[k]:
                    live_in[k] = inn
                    changed = True


# --------------------------------------------------------------------------
# Génération de code 68000
# --------------------------------------------------------------------------

RAM_BIAS = 0x80          # a5 = RAM + $80

# Accès d'E/S qui ont une routine dédiée dans nes_runtime.s (les autres passent
# par rt_rd_ind / rt_wr_ind avec l'adresse dans a1)
RT_READS = {0x2002, 0x2007, 0x4015, 0x4016, 0x4017}
RT_WRITES = {0x2000, 0x2001, 0x2003, 0x2005, 0x2006, 0x2007, 0x4014, 0x4016}


class CState:
    """Emplacement des drapeaux 6502 pendant la génération (dans un bloc)"""

    def __init__(self):
        self.reset()

    def reset(self):
        self.nz = True          # N/Z valides dans le CCR
        self.nz_reg = None      # registre dont N/Z reflètent la valeur (move.b r,... les conserve)
        self.cx = 'pos'         # X du 68000 : 'pos' = C, 'neg' = !C, None = invalide
        self.cc = None          # C du 68000 : 'pos', 'neg' ou None
        self.ck = None          # retenue connue à la compilation (0/1) ou None


class Gen:
    def __init__(self, rc):
        self.rc = rc
        self.out = []
        self.st = CState()
        self.uid = 0

    def emit(self, s):
        self.out.append('    ' + s)

    def new_label(self):
        self.uid += 1
        return f'.r{self.uid}'

    # ---------- drapeaux ----------
    def carry_alive(self):
        st = self.st
        return st.ck is not None or st.cx is not None or st.cc is not None

    def need_save(self, live, clobbers):
        """Faut-il sauvegarder le CCR autour d'une séquence qui écrase `clobbers` ?"""
        st = self.st
        if 'C' in live and st.ck is None:
            if 'X' in clobbers and st.cx is not None:
                return True
            if 'C68' in clobbers and st.cx is None and st.cc is not None:
                return True
        if 'NZ' in clobbers and (live & NZ) and st.nz:
            return True
        return False

    def clobbered(self, clobbers):
        st = self.st
        if 'X' in clobbers:
            st.cx = None
        if 'C68' in clobbers:
            st.cc = None
        if 'NZ' in clobbers:
            st.nz, st.nz_reg = False, None

    def wrap(self, live, clobbers, body):
        """Exécute body() en préservant les drapeaux vivants écrasés"""
        if self.need_save(live, clobbers):
            self.emit('move.w  sr,-(sp)')
            body()
            self.emit('move.w  (sp)+,ccr')
        else:
            body()
            self.clobbered(clobbers)

    def ccr_table(self, tab):
        """CCR <- table[CCR & $1F] (conversion de retenue sans toucher N/Z/V)"""
        e = self.emit
        e('move.w  sr,d4')
        e('andi.w  #$1F,d4')
        e(f'lea     {tab},a0')
        e('move.b  (a0,d4.w),d4')
        e('move.w  d4,ccr')

    def carry_to_x(self):
        """Retenue -> X canonique (X = C)"""
        st = self.st
        if st.ck is not None:
            self.emit('ori.b   #$10,ccr' if st.ck else 'andi.b  #$EF,ccr')
            st.ck, st.cx = None, 'pos'
            st.cc = None
        elif st.cx == 'pos':
            pass
        elif st.cx == 'neg':
            self.emit('eori.b  #$10,ccr')
            st.cx = 'pos'
        elif st.cc == 'pos':
            self.ccr_table('rt_ccr_c2x')
            st.cx = 'pos'
        elif st.cc == 'neg':
            self.ccr_table('rt_ccr_nc2x')       # X = C = !C68
            st.cx, st.cc = 'pos', 'pos'
        else:
            raise RuntimeError('retenue perdue')

    def nz_restore(self):
        st = self.st
        if st.nz:
            return
        if st.nz_reg is None:
            raise RuntimeError('N/Z perdus')
        self.emit(f'tst.b   {st.nz_reg}')
        st.nz, st.cc = True, None

    def canonicalize(self, live):
        """Forme canonique des drapeaux vivants : C dans X, N/Z dans le CCR"""
        if 'C' in live:
            self.carry_to_x()
        if live & NZ:
            self.nz_restore()

    # ---------- opérandes ----------
    def ea(self, ins):
        """(préambule, ea) pour un opérande en mémoire directe, ou None (E/S, indirect)"""
        m, v = ins.mode, ins.operand
        if m == 'imm':
            return [], f'#${v:02X}'
        if m == 'zp':
            return [], f'{v - RAM_BIAS}(a5)'
        if m in ('zpx', 'zpy'):
            r = 'd1' if m == 'zpx' else 'd2'
            return [], f'{v - RAM_BIAS}(a5,{r}.w)'
        if m in ('abs', 'abx', 'aby'):
            r = None if m == 'abs' else ('d1' if m == 'abx' else 'd2')
            return self.ea_abs(ins, v, r)
        return None

    def ea_abs(self, ins, addr, r, write=False):
        if addr < 0x2000:
            a = addr & 0x7FF
            if r is None:
                return [], f'{a - RAM_BIAS}(a5)'
            if a - RAM_BIAS <= 127:
                return [], f'{a - RAM_BIAS}(a5,{r}.w)'
            return [f'lea     {a - RAM_BIAS}(a5),a0'], f'(a0,{r}.w)'
        if 0x6000 <= addr < 0x8000:
            o = addr - 0x6000
            if r is None:
                return [], f'{o}(a4)'
            return [f'lea     {o}(a4),a0'], f'(a0,{r}.w)'
        if addr >= 0x8000 and not write:
            o = addr & 0x1FFF
            tb = self.rc.bank_for(ins.bank, ins.pc, addr)
            if tb is not None:
                base = f'prg_rom+{tb * 8192 + o}'
                if r is None:
                    return [], base
                return [f'lea     {base},a0'], f'(a0,{r}.w)'
            s = slot_of(addr)
            pre = [f'movea.l rt_slotptr+{s * 4}(a6),a0']
            if r is None:
                return pre, f'{o}(a0)'
            pre.append(f'lea     {o}(a0),a0')
            return pre, f'(a0,{r}.w)'
        return None

    def ind_addr(self, ins):
        """Adresse effective (zp),Y ou (zp,X) -> a1 (sans toucher X du 68000)"""
        z = ins.operand
        e = self.emit
        if ins.mode == 'izy':
            e(f'move.b  {((z + 1) & 0xFF) - RAM_BIAS}(a5),-(sp)')
            e('move.w  (sp)+,d3')
            e(f'move.b  {z - RAM_BIAS}(a5),d3')
            e('movea.w d3,a1')
            e('adda.w  d2,a1')
        else:
            e(f'lea     {z - RAM_BIAS}(a5,d1.w),a0')
            e('move.b  1(a0),-(sp)')
            e('move.w  (sp)+,d3')
            e('move.b  (a0),d3')
            e('movea.w d3,a1')

    def read_slow(self, ins):
        """Lecture E/S ou indirecte -> d3 (écrase tous les drapeaux du CCR)"""
        m, v = ins.mode, ins.operand
        e = self.emit
        if m in ('izy', 'izx'):
            self.ind_addr(ins)
            e('jsr     rt_rd_ind')
        elif m in ('abx', 'aby'):
            r = 'd1' if m == 'abx' else 'd2'
            e(f'movea.w #${v:04X},a1')
            e(f'adda.w  {r},a1')
            e('jsr     rt_rd_ind')
        elif v in RT_READS:
            e(f'jsr     rt_rd_{v:04X}')
        else:
            e(f'movea.w #${v:04X},a1')
            e('jsr     rt_rd_ind')
        self.rc.io_reads.add((m, v))

    def operand_to(self, ins, dst, live, want_nz=False):
        """
        Charge l'opérande dans dst. Pour l'accès lent (E/S, indirect), les drapeaux
        vivants sont préservés ; si want_nz, N/Z reflètent ensuite la valeur chargée.
        """
        r = self.ea(ins)
        if r is not None:
            pre, ea = r
            for p in pre:
                self.emit(p)
            self.emit(f'move.b  {ea},{dst}')
            return True          # N/Z = valeur (move)
        def body():
            self.read_slow(ins)
            if dst != 'd3':
                self.emit(f'move.b  d3,{dst}')
        saved = self.need_save(live, {'X', 'NZ', 'C68'})
        self.wrap(live, {'X', 'NZ', 'C68'}, body)
        if saved and want_nz:
            self.emit(f'tst.b   {dst}')          # N/Z de la valeur, X (retenue) conservé
            self.st.cc = None
        return not saved or want_nz

    def src_operand(self, ins, live):
        """Opérande source pour add/sub/cmp/and/or : ea direct ou d3 après lecture lente"""
        r = self.ea(ins)
        if r is not None:
            for p in r[0]:
                self.emit(p)
            return r[1]
        self.operand_to(ins, 'd3', live)
        return 'd3'

    def store(self, ins, src, live):
        m, v = ins.mode, ins.operand
        st = self.st
        e = self.emit
        direct = None
        if m in ('zp', 'zpx', 'zpy'):
            direct = self.ea(ins)
        elif m in ('abs', 'abx', 'aby'):
            r = None if m == 'abs' else ('d1' if m == 'abx' else 'd2')
            direct = self.ea_abs(ins, v, r, write=True)
        if direct is not None:
            pre, ea = direct
            keep_nz = st.nz_reg == src and st.nz
            clob = {'C68'} | (set() if keep_nz else {'NZ'})

            def body():
                for p in pre:
                    e(p)
                e(f'move.b  {src},{ea}')
            self.wrap(live, clob, body)
            if keep_nz:
                st.nz, st.nz_reg = True, src
            return

        def body_slow():
            self.ppu_time(ins, v)
            if m in ('izy', 'izx'):
                self.ind_addr(ins)
                e(f'move.b  {src},d3')
                e('jsr     rt_wr_ind')
            elif m in ('abx', 'aby') and 0xB000 <= v and v + 0xFF < 0xF000:
                r_ = 'd1' if m == 'abx' else 'd2'
                e(f'move.w  #${v:04X},d4')         # banque CHR indexée
                e(f'add.w   {r_},d4')
                e(f'move.b  {src},d3')
                e('jsr     rt_wr_chr')
            elif m in ('abx', 'aby'):
                r_ = 'd1' if m == 'abx' else 'd2'
                e(f'movea.w #${v:04X},a1')
                e(f'adda.w  {r_},a1')
                e(f'move.b  {src},d3')
                e('jsr     rt_wr_ind')
            elif v in RT_WRITES:
                e(f'move.b  {src},d3')
                e(f'jsr     rt_wr_{v:04X}')
            elif m == 'abs' and 0x8000 <= v < 0x9000:
                e(f'move.b  {src},d3')
                e('jsr     rt_wr_prg0')            # registre PRG 0 du VRC4
            elif m == 'abs' and 0xA000 <= v < 0xB000:
                e(f'move.b  {src},d3')
                e('jsr     rt_wr_prg1')
            elif m == 'abs' and 0xB000 <= v < 0xF000:
                # Banque CHR du VRC4e, décodée à la compilation (cf. rt_wr_mapper)
                idx = ((v >> 2) | v) & 3
                bank = ((v >> 12) - 0xB) * 2 + (idx >> 1)
                reg = f'rt_chrbank+{bank * 2}(a6)'
                e('st      rt_pdirty(a6)')
                e(f'move.w  {reg},d4')
                if idx & 1 == 0:
                    e('andi.w  #$1F0,d4')
                    e('moveq   #$0F,d5')
                    e(f'and.b   {src},d5')
                else:
                    e('andi.w  #$0F,d4')
                    e('moveq   #$1F,d5')
                    e(f'and.b   {src},d5')
                    e('lsl.w   #4,d5')
                e('or.w    d5,d4')
                e(f'move.w  d4,{reg}')
            elif m == 'abs' and v >= 0x8000:
                e(f'move.w  #${v:04X},d4')         # autres registres du mapper
                e(f'move.b  {src},d3')
                e('jsr     rt_wr_mapper')
            else:
                e(f'movea.w #${v:04X},a1')
                e(f'move.b  {src},d3')
                e('jsr     rt_wr_ind')
            self.rc.io_writes.add((m, v))
        self.wrap(live, {'X', 'NZ', 'C68'}, body_slow)

    def ppu_time(self, ins, v):
        """Écriture PPU / banque CHR d'un gestionnaire d'IRQ : instant NES (cycles 6502
        comptés dans a3) transmis au runtime (rt_ppu_time) pour placer la bande d'effet de trame"""
        if f'{ins.bank}:{ins.pc:04X}' not in self.rc.irq_code or v is None:
            return
        if ins.mode == 'abs':
            if not (v in (0x2000, 0x2005, 0x2006) or 0xB000 <= v < 0xF000):
                return
        elif not (ins.mode in ('abx', 'aby') and 0xB000 <= v and v + 0xFF < 0xF000):
            return                                  # seules les banques CHR indexées
        horiz = ins.mode == 'abs' and v in (0x2000, 0x2005)
        self.emit(f'moveq   #{4 if horiz else 0},d4')       # défilement X : recopié au cycle 257
        self.emit('jsr     rt_ppu_time')

    def irq_cycles(self, ins):
        """Cycles 6502 d'une instruction exécutée en IRQ (cf. tools/ppu_timing.py) :
        cycles de base, +1 pour un branchement arrière (boucle d'attente, supposé pris)"""
        c = CYCLES[ins.op]
        if ins.mode == 'rel' and ins.operand >= 0x80:
            c += 1
        return c

    def rmw(self, ins, op_line, in_place=None, table=False):
        """Lecture-modification-écriture en mémoire directe : op_line agit sur d3
        (in_place : instruction appliquée directement à la mémoire, ex. addq.b #1 ;
        table : op_line charge a1 avec une table de 256 octets, résultat = table[valeur])"""
        m, v = ins.mode, ins.operand
        if m in ('abs', 'abx'):
            r = None if m == 'abs' else 'd1'
            direct = self.ea_abs(ins, v, r, write=True)
        else:
            direct = self.ea(ins)
        if direct is None:
            raise RuntimeError(f'RMW sur E/S en {ins.bank}:{ins.pc:04X}')
        pre, ea = direct
        for p in pre:
            self.emit(p)
        if table:
            self.emit('moveq   #0,d4')
            self.emit(f'move.b  {ea},d4')
            self.emit(op_line)
            self.emit(f'move.b  (a1,d4.w),{ea}')
            return
        if in_place:
            self.emit(f'{in_place},{ea}')
            return
        self.emit(f'move.b  {ea},d3')
        self.emit(op_line)
        self.emit(f'move.b  d3,{ea}')

    def keep_xvc_after(self, body):
        """body() modifie X ; on garde N/Z produits par body et on restaure X/V/C"""
        e = self.emit
        e('move.w  sr,-(sp)')
        body()
        e('move.w  sr,d5')
        e('move.w  (sp)+,d4')
        e('andi.w  #$0C,d5')
        e('andi.w  #$13,d4')
        e('or.w    d5,d4')
        e('move.w  d4,ccr')

    # ---------- instructions ----------
    def gen(self, ins):
        st = self.st
        live = ins.live_out
        mn, m = ins.mn, ins.mode
        e = self.emit
        # Retenue vivante uniquement dans C du 68000 : un move l'effacerait
        if ('C' in live and st.ck is None and st.cx is None and st.cc is not None
                and mn not in ('BCC', 'BCS', 'ADC', 'SBC', 'ROL', 'ROR') and 'C' not in FLAG_DEF[mn]):
            self.carry_to_x()

        if mn in ('LDA', 'LDX', 'LDY'):
            dst = {'LDA': 'd0', 'LDX': 'd1', 'LDY': 'd2'}[mn]
            if m == 'imm' and dst == 'd0':
                e(f'moveq   #{s8(ins.operand)},d0')
            else:
                self.operand_to(ins, dst, live, want_nz=True)
            st.nz, st.nz_reg, st.cc = True, dst, None
            return
        if mn in ('STA', 'STX', 'STY'):
            self.store(ins, {'STA': 'd0', 'STX': 'd1', 'STY': 'd2'}[mn], live)
            return
        if mn in ('TAX', 'TAY', 'TXA', 'TYA'):
            s, d = {'TAX': ('d0', 'd1'), 'TAY': ('d0', 'd2'), 'TXA': ('d1', 'd0'), 'TYA': ('d2', 'd0')}[mn]
            e(f'move.b  {s},{d}')
            st.nz, st.nz_reg, st.cc = True, d, None
            return
        if mn == 'TSX':
            def body():
                e('move.l  a2,d1')
                e('subi.l  #nes_ram+$101,d1')
                e('andi.l  #$FF,d1')
                e('tst.b   d1')
            if 'C' in live and st.cx is not None and st.ck is None:
                self.keep_xvc_after(body)
            else:
                body()
                st.cx = None
            st.nz, st.nz_reg, st.cc = True, 'd1', None
            return
        if mn == 'TXS':
            e('lea     nes_ram+$101,a2')
            e('adda.w  d1,a2')
            return
        if mn in ('INX', 'INY', 'DEX', 'DEY'):
            r = 'd1' if mn in ('INX', 'DEX') else 'd2'
            op = 'addq' if mn in ('INX', 'INY') else 'subq'
            line = f'{op}.b  #1,{r}'
            if 'C' in live and st.ck is None and st.cx is not None:
                # retenue dans X : table (move ne touche pas X ; N/Z du résultat)
                e(f'lea     rt_{"inc" if op == "addq" else "dec"}_tab,a0')
                e(f'move.b  (a0,{r}.w),{r}')
            elif 'C' in live and st.ck is None and st.cc is not None:
                self.keep_xvc_after(lambda: e(line))
            else:
                e(line)
                st.cx = None
            st.nz, st.nz_reg, st.cc = True, r, None
            return
        if mn in ('INC', 'DEC'):
            op = 'addq' if mn == 'INC' else 'subq'
            line = f'{op}.b  #1,d3'
            inplace = f'{op}.b  #1'
            if 'C' in live and st.ck is None and st.cx is not None:
                # retenue dans X : table (moveq / move ne touchent pas X)
                self.rmw(ins, f'lea     rt_{"inc" if op == "addq" else "dec"}_tab,a1', table=True)
            elif 'C' in live and st.ck is None and st.cc is not None:
                self.keep_xvc_after(lambda: self.rmw(ins, line, inplace))
            else:
                self.rmw(ins, line, inplace)
                st.cx = None
            st.nz, st.nz_reg, st.cc = True, None, None
            return
        if mn in ('AND', 'ORA', 'EOR'):
            op = {'AND': 'and', 'ORA': 'or', 'EOR': 'eor'}[mn]
            if op == 'eor':
                self.operand_to(ins, 'd3', live | {'C'})
                src = 'd3'
            else:
                src = self.src_operand(ins, live | {'C'})
            e(f'{op}.b   {src},d0')
            st.nz, st.nz_reg, st.cc = True, 'd0', None
            return
        if mn in ('CMP', 'CPX', 'CPY'):
            reg = {'CMP': 'd0', 'CPX': 'd1', 'CPY': 'd2'}[mn]
            src = self.src_operand(ins, live)
            nxt = self.rc.insns.get((ins.bank, (ins.pc + ins.len) & 0xFFFF))
            if 'C' in live and not (nxt and nxt.mn in ('BCC', 'BCS') and not nxt.label):
                # la retenue doit survivre : sub (X = C du 68000 = emprunt)
                e(f'move.b  {reg},d4')
                e(f'sub.b   {src},d4')
                st.cx = 'neg'
            else:
                e(f'cmp.b   {src},{reg}')
                st.cx = None
            st.nz, st.nz_reg = True, None
            st.cc, st.ck = 'neg', None
            return
        if mn == 'BIT':
            self.operand_to(ins, 'd3', live | {'C'})
            if 'V' in live:
                e('btst    #6,d3')
                e('sne     d6')
            if live & NZ:
                l1, l2 = self.new_label(), self.new_label()
                e('move.w  sr,d5')
                e('andi.w  #$13,d5')
                e('tst.b   d3')
                e(f'bpl.s   {l1}')
                e('ori.w   #$08,d5')
                e(f'{l1}:')
                e('and.b   d0,d3')
                e(f'bne.s   {l2}')
                e('ori.w   #$04,d5')
                e(f'{l2}:')
                e('move.w  d5,ccr')
                st.nz, st.nz_reg = True, None
            else:
                st.nz, st.nz_reg = False, None
            return
        if mn == 'ADC':
            self.gen_adc(ins, live)
            return
        if mn == 'SBC':
            self.gen_sbc(ins, live)
            return
        if mn in ('ASL', 'LSR', 'ROL', 'ROR'):
            op = {'ASL': 'lsl', 'LSR': 'lsr', 'ROL': 'roxl', 'ROR': 'roxr'}[mn]
            if mn in ('ROL', 'ROR'):
                self.carry_to_x()
            if m == 'acc':
                e(f'{op}.b  #1,d0')
                st.nz, st.nz_reg = True, 'd0'
                st.cx, st.cc, st.ck = 'pos', 'pos', None
            else:
                self.rmw(ins, f'{op}.b  #1,d3')
                st.nz, st.nz_reg = True, None
                st.cx, st.cc, st.ck = 'pos', None, None
            return
        if mn == 'CLC':
            st.ck, st.cx, st.cc = 0, None, None
            return
        if mn == 'SEC':
            st.ck, st.cx, st.cc = 1, None, None
            return
        if mn == 'CLV':
            e('sf      d6')
            return
        if mn in ('CLD', 'SED', 'NOP'):
            return
        if mn == 'SEI':
            e('st      rt_iflag(a6)')
            return
        if mn == 'CLI':
            self.wrap(live, {'X', 'NZ', 'C68'}, lambda: e('jsr     rt_cli'))
            return
        if mn == 'PHA':
            keep_nz = st.nz_reg == 'd0' and st.nz
            self.wrap(live, {'C68'} | (set() if keep_nz else {'NZ'}), lambda: e('move.b  d0,-(a2)'))
            return
        if mn == 'PLA':
            e('move.b  (a2)+,d0')
            if ins.drop_ret:
                e('addq.l  #4,sp')              # l'adresse de retour 68000 est jetée aussi
            st.nz, st.nz_reg, st.cc = True, 'd0', None
            return
        if mn == 'PHP':
            self.canonicalize(ALLF)
            e('jsr     rt_php')
            return
        if mn == 'PLP':
            e('jsr     rt_plp')
            st.reset()
            return
        if mn in ('BEQ', 'BNE', 'BMI', 'BPL', 'BCC', 'BCS', 'BVC', 'BVS'):
            self.gen_branch(ins)
            return
        if mn == 'JMP':
            self.gen_jmp(ins)
            return
        if mn == 'JSR':
            self.gen_jsr(ins)
            return
        if mn == 'RTS':
            self.canonicalize(ins.live_out)     # drapeaux utilisés aux points de retour
            e('addq.w  #2,a2')
            e('rts')
            return
        if mn == 'RTI':
            self.canonicalize(ALLF)
            e('jmp     rt_rti')
            return
        if mn == 'BRK':
            e('jmp     rt_brk')
            return
        raise RuntimeError(f'instruction non gérée {mn} {m}')

    def gen_adc(self, ins, live):
        st, e = self.st, self.emit
        if st.ck == 0:
            src = self.src_operand(ins, live)
            e(f'add.b   {src},d0')
        else:
            self.operand_to(ins, 'd3', live | {'C'})
            if st.ck == 1:
                e('ori.b   #$14,ccr')         # X=1, Z=1
                st.ck, st.cx = None, 'pos'
            else:
                self.carry_to_x()
                if 'Z' in live:
                    e('ori.b   #$04,ccr')
            e('addx.b  d3,d0')
        if 'V' in live:
            e('svs     d6')
        st.nz, st.nz_reg = True, 'd0'
        st.cx, st.cc, st.ck = 'pos', 'pos', None

    def gen_sbc(self, ins, live):
        st, e = self.st, self.emit
        if st.ck == 1:
            src = self.src_operand(ins, live)
            e(f'sub.b   {src},d0')
        else:
            self.operand_to(ins, 'd3', live | {'C'})
            if st.ck == 0:
                e('ori.b   #$14,ccr')         # emprunt X=1, Z=1
                st.ck = None
            else:
                if st.cx != 'neg':
                    self.carry_to_x()
                    e('eori.b  #$10,ccr')     # X = emprunt
                if 'Z' in live:
                    e('ori.b   #$04,ccr')
            e('subx.b  d3,d0')
        if 'V' in live:
            e('svs     d6')
        st.nz, st.nz_reg = True, 'd0'
        st.cx, st.cc, st.ck = 'neg', 'neg', None

    def target_label(self, ins, addr):
        tb = self.rc.bank_for(ins.bank, ins.pc, addr)
        if tb is None or (tb, addr) not in self.rc.insns:
            return None
        return label(tb, addr)

    def gen_branch(self, ins):
        st, e = self.st, self.emit
        mn = ins.mn
        tgt = self.target_label(ins, ins.target)
        nxt = (ins.pc + 2) & 0xFFFF
        live_after = self.rc.live_in_of(ins.bank, ins.pc, ins.target) | self.rc.live_in_of(ins.bank, ins.pc, nxt)
        if tgt is None:
            live_after = set(ALLF)

        if mn in ('BCC', 'BCS'):
            if st.ck is not None:
                # retenue connue : branchement statique
                taken = (st.ck == 1) == (mn == 'BCS')
                if taken:
                    self.canonicalize(live_after)
                    self.jump(ins, ins.target, tgt)
                return
            if ('C' in live_after and st.cc is not None and st.cx is None and tgt is not None
                    and (st.nz or not (live_after & NZ))):
                # retenue dans C du 68000 seulement : branchement direct, la
                # retenue est connue sur chaque chemin (X posé avant le saut,
                # constante à la suite) - au lieu d'une conversion par table
                want_set = (mn == 'BCS') != (st.cc == 'neg')
                lnot = self.new_label()
                e(f'{"bcc" if want_set else "bcs"}.s   {lnot}')
                e('ori.b   #$10,ccr' if mn == 'BCS' else 'andi.b  #$EF,ccr')
                e(f'bra.w   {tgt}')
                e(f'{lnot}:')
                st.ck, st.cx, st.cc = (0 if mn == 'BCS' else 1), None, None
                return
            if 'C' in live_after:
                self.carry_to_x()
            self.canonicalize(live_after - {'C'})
            if st.cc is None:
                if st.cx is None:
                    raise RuntimeError(f'branchement sur retenue perdue en {ins.bank}:{ins.pc:04X}')
                if not (live_after & (NZ | {'V'})) or tgt is None:
                    # test direct du bit X (N/Z morts après le branchement)
                    e('move.w  sr,d4')
                    e('andi.w  #$10,d4')
                    want_set = (mn == 'BCS') != (st.cx == 'neg')
                    st.nz, st.nz_reg = False, None
                    cc = 'bne' if want_set else 'beq'
                    if tgt is None:
                        inv = 'beq' if cc == 'bne' else 'bne'
                        lf = self.new_label()
                        e(f'{inv}.s   {lf}')
                        self.jump(ins, ins.target, None)
                        e(f'{lf}:')
                    else:
                        e(f'{cc}.w   {tgt}')
                    return
                self.ccr_table('rt_ccr_x2c')
                st.cc = st.cx
            want_set = (mn == 'BCS') != (st.cc == 'neg')
            cc = 'bcs' if want_set else 'bcc'
        elif mn in ('BVC', 'BVS'):
            self.canonicalize(live_after)
            cc = 'bne' if mn == 'BVS' else 'beq'
            if live_after & ALLF - {'V'}:
                lt, lf = self.new_label(), self.new_label()
                e('move.w  sr,-(sp)')
                e('tst.b   d6')
                e(f'{cc}.s   {lt}')
                e('move.w  (sp)+,ccr')
                e(f'bra.s   {lf}')
                e(f'{lt}:')
                e('move.w  (sp)+,ccr')
                self.jump(ins, ins.target, tgt)
                e(f'{lf}:')
                return
            e('tst.b   d6')
            st.nz, st.nz_reg, st.cc = False, None, None
        else:
            self.canonicalize(live_after | FLAG_USE[mn])
            cc = {'BEQ': 'beq', 'BNE': 'bne', 'BMI': 'bmi', 'BPL': 'bpl'}[mn]
        if tgt is None:
            inv = {'beq': 'bne', 'bne': 'beq', 'bmi': 'bpl', 'bpl': 'bmi', 'bcs': 'bcc', 'bcc': 'bcs'}[cc]
            lf = self.new_label()
            e(f'{inv}.s   {lf}')
            self.jump(ins, ins.target, None)
            e(f'{lf}:')
        else:
            e(f'{cc}.w   {tgt}')

    def jump(self, ins, addr, tgt):
        if tgt is not None:
            self.emit(f'jmp     {tgt}')
        else:
            self.emit('move.w  sr,d4')
            self.emit(f'move.w  #${addr:04X},d3')
            self.emit('jmp     rt_dispatch_jmp')
            self.rc.dyn_jumps.add(addr)

    def gen_jmp(self, ins):
        e = self.emit
        if ins.mode == 'abs' and ins.succ:
            self.canonicalize(ins.live_out)
        else:
            self.canonicalize(ALLF)
        if ins.mode == 'abs':
            tgt = self.target_label(ins, ins.target)
            if tgt is not None:
                e(f'jmp     {tgt}')
            else:
                self.dyn_call(ins, ins.target, jump=True)
            return
        # JMP (ind) : pointeur en RAM ; cibles relevées par le traçage
        p = ins.operand
        e('move.w  sr,d4')
        e(f'move.b  {self.abs_ea((p & 0xFF00) | ((p + 1) & 0xFF))},-(sp)')
        e('move.w  (sp)+,d3')
        e(f'move.b  {self.abs_ea(p)},d3')
        for nb, npc in sorted(self.rc.indirect.get((ins.bank, ins.pc), set())):
            if (nb, npc) in self.rc.insns and self.rc.bank_for(ins.bank, ins.pc, npc) == nb:
                lx = self.new_label()
                e(f'cmpi.w  #${npc:04X},d3')
                e(f'bne.s   {lx}')
                e('move.w  d4,ccr')
                e(f'jmp     {label(nb, npc)}')
                e(f'{lx}:')
        e('jmp     rt_dispatch_jmp')

    def abs_ea(self, addr):
        if addr < 0x2000:
            return f'{(addr & 0x7FF) - RAM_BIAS}(a5)'
        if 0x6000 <= addr < 0x8000:
            return f'{addr - 0x6000}(a4)'
        raise RuntimeError(f'pointeur indirect hors RAM ${addr:04X}')

    def dyn_call(self, ins, addr, jump):
        """Appel/saut vers une fenêtre commutable : banques relevées en cache, sinon répartiteur"""
        e = self.emit
        op = 'jmp' if jump else 'jsr'
        banks = []
        if 0x8000 <= addr < 0xC000:
            s = slot_of(addr)
            banks = sorted(b for b in self.rc.code if b >= 0 and addr in self.rc.code[b] and (b, addr) in self.rc.insns)
        e('move.w  sr,d4')
        done = self.new_label()
        for b in banks:
            lx = self.new_label()
            e(f'cmpi.b  #{b},rt_slotbank+{s}(a6)')
            e(f'bne.s   {lx}')
            e('move.w  d4,ccr')
            e(f'{op}     {label(b, addr)}')
            if not jump:
                e(f'bra.s   {done}')
            e(f'{lx}:')
            self.rc.dyn_targets[b].add(addr)
        e(f'move.w  #${addr:04X},d3')
        e(f'{op}     rt_dispatch_{op}')
        if not jump:
            e(f'{done}:')

    def gen_jsr(self, ins):
        e = self.emit
        if ins.jtab is not None:
            self.gen_jtab(ins)
            return
        self.canonicalize(ins.live_out)
        if ins.ret_write:
            ret = (ins.pc + 2) & 0xFFFF
            e('move.w  sr,d4')
            e(f'move.b  #${ret >> 8:02X},-1(a2)')
            e(f'move.b  #${ret & 0xFF:02X},-2(a2)')
            e('move.w  d4,ccr')
        e('subq.w  #2,a2')
        tgt = self.target_label(ins, ins.target)
        if tgt is not None:
            e(f'jsr     {tgt}')
        else:
            self.dyn_call(ins, ins.target, jump=False)
        self.st.reset()
        nxt = (ins.pc + 3) & 0xFFFF
        nb = self.rc.bank_for(ins.bank, ins.pc, nxt)
        if nb is None or (nb, nxt) not in self.rc.insns:
            self.to_interp(nxt)

    def to_interp(self, addr):
        """Suite du code non recompilée : interpréteur 6502 (rt_interp)"""
        self.emit('move.w  sr,d4')
        self.emit(f'move.w  #${addr:04X},d3')
        self.emit('jmp     rt_interp')

    def gen_jtab(self, ins):
        """JSR $C75F + table : effets du répartiteur ($00-$03, A, Y, drapeaux) puis saut"""
        e = self.emit
        pc = ins.pc
        ret = (pc + 2) & 0xFFFF
        tbl = (pc + 3) & 0xFFFF
        base = self.rc.bank_for(ins.bank, pc, tbl)
        e(f'move.b  #${ret & 0xFF:02X},{0 - RAM_BIAS}(a5)')
        e(f'move.b  #${ret >> 8:02X},{1 - RAM_BIAS}(a5)')
        e('moveq   #0,d3')
        e('move.b  d0,d3')
        e('add.b   d3,d3')                                 # ASL A : X = bit 7 de A
        e(f'lea     prg_rom+{base * 8192 + (tbl & 0x1FFF)},a0')
        e(f'move.b  (a0,d3.w),{2 - RAM_BIAS}(a5)')
        e(f'move.b  1(a0,d3.w),{3 - RAM_BIAS}(a5)')
        e(f'lea     .jt{pc:04X},a0')
        e('adda.w  d3,a0')
        e('adda.w  d3,a0')
        e('movea.l (a0),a0')
        e(f'lea     {0x627E - 0x6000}(a4),a1')
        e('move.b  (a1,d1.w),d0')                          # LDA $627E,X
        e('move.b  d0,d2')                                 # TAY
        e('jmp     (a0)')
        e(f'.jt{pc:04X}:')
        missing = []
        for k, t in enumerate(ins.jtab):
            lb = self.target_label(ins, t)
            if lb is None:
                lb = f'.jm{pc:04X}_{k}'
                missing.append((lb, t))
            e(f'dc.l    {lb}')
        for lb, t in missing:
            self.out.append(f'{lb}:')
            self.to_interp(t)


def live_in_of(rc, bank, pc, addr):
    tb = rc.bank_for(bank, pc, addr)
    ins = rc.insns.get((tb, addr)) if tb is not None else None
    if ins is None:
        return set(ALLF)
    if ins.mn == 'JSR':
        return set(ins.live_out)
    return (ins.live_out - FLAG_DEF[ins.mn]) | FLAG_USE[ins.mn]


Recompiler.live_in_of = lambda self, b, pc, a: live_in_of(self, b, pc, a)


def generate(rc):
    rc.io_reads, rc.io_writes, rc.dyn_jumps = set(), set(), set()
    lines = [
        ';; Généré par tools/recomp6502.py - ne pas modifier à la main',
        ';; Code 6502 de Crisis Force recompilé en 68000 (modèle : voir l\'en-tête du script)',
        '',
        '    .text',
        '',
    ]
    errors = 0
    by_bank = defaultdict(list)
    for (b, pc), ins in rc.insns.items():
        by_bank[b].append(ins)
    for b in sorted(by_bank):
        g = Gen(rc)
        lines.append(f';; ===== Banque {b} =====')
        prev_end = None
        for ins in sorted(by_bank[b], key=lambda i: i.pc):
            if prev_end is not None and prev_end != ins.pc:
                try:
                    g.canonicalize(ALLF)
                except RuntimeError:
                    pass
                g.to_interp(prev_end)
                prev_end = None
            if ins.label and prev_end is not None:
                g.canonicalize(live_in_of(rc, b, ins.pc, ins.pc))
            g.out.append(f'{label(b, ins.pc)}:')
            if (b, ins.pc) in HLE and not getattr(rc, 'no_hle', False):
                g.emit(f'jmp     {HLE[(b, ins.pc)]}')      # version native
            if ins.label or prev_end is None:
                g.st.reset()
            if f'{b}:{ins.pc:04X}' in rc.irq_code:
                g.emit(f'lea     {g.irq_cycles(ins)}(a3),a3')   # temps 6502 en IRQ (sans toucher au CCR)
            try:
                g.gen(ins)
            except RuntimeError as ex:
                errors += 1
                rc.warnings.append(f'{b}:{ins.pc:04X} {ins.mn}: {ex}')
                g.emit('jmp     rt_gen_error')
                g.st.reset()
            if ins.mn in ('RTS', 'RTI', 'JMP', 'BRK') or (ins.mn == 'JSR' and ins.jtab is not None):
                prev_end = None
            else:
                prev_end = (ins.pc + ins.len) & 0xFFFF
        if prev_end is not None:
            try:
                g.canonicalize(ALLF)
            except RuntimeError:
                pass
            g.to_interp(prev_end)
        lines += g.out
        lines.append('')
    # Points d'entrée et table des sauts dynamiques (rt_dispatch_find)
    m = lambda a: rc.rom_byte(FIXED_E000, a) | (rc.rom_byte(FIXED_E000, a + 1) << 8)
    lines += [
        f'NES_NMI_ENTRY   equ {label(FIXED_E000, m(0xFFFA))}',
        f'NES_RESET_ENTRY equ {label(FIXED_E000, m(0xFFFC))}',
        f'NES_IRQ_ENTRY   equ {label(FIXED_E000, m(0xFFFE))}',
        '',
        '    .data',
        '    .long',
        ';; Routines qui jettent leur adresse de retour (PLA PLA) : l\'interpréteur',
        ';; ne les appelle jamais en natif (leur cible revient à son appelant)',
        'nes_droppers:',
        '    dc.w    ' + ','.join(f'${a:04X}' for a in sorted({a for _, a in rc.droppers} | DISPATCHERS)) + ',0',
        '    .long',
        ';; Répartiteur des sauts dynamiques (rt_dispatch_find) : par banque,',
        ';; adresses 6502 triées (.w) et code 68000 correspondant (.l)',
        'nes_dyn_tab:',
    ]
    # Toutes les entrées possibles : étiquettes (cibles de branchement, d'appel,
    # retours de JSR, cibles indirectes) et cibles d'appels dynamiques
    entries = defaultdict(set)
    for (b, pc), ins in rc.insns.items():
        if ins.label:
            entries[b].add(pc)
    for b, addrs in rc.dyn_targets.items():
        entries[b].update(a for a in addrs if (b, a) in rc.insns)
    for b in range(16):
        lines.append(f'    dc.l    nes_dyn_a{b},nes_dyn_p{b},{len(entries[b])}')
    for b in range(16):
        lst = sorted(entries[b])
        lines.append('    .long')
        lines.append(f'nes_dyn_p{b}:')
        for i in range(0, len(lst), 8):
            lines.append('    dc.l    ' + ','.join(label(b, a) for a in lst[i:i + 8]))
        lines.append(f'nes_dyn_a{b}:')
        for i in range(0, len(lst), 16):
            lines.append('    dc.w    ' + ','.join(f'${a:04X}' for a in lst[i:i + 16]))
        lines.append('    dc.w    0')
    # Table étiquette -> adresse 6502 (banc de test uniquement)
    lines += ['    .if ^^defined RECOMP_TEST', '    .long', 'nes_label_tab:']
    for (b, pc) in sorted(rc.insns):
        lines.append(f'    dc.l    {label(b, pc)},${(b << 16) | pc:06X}')
    lines += ['    dc.l    0,0', '    .endif']
    lines += ['    .text', '']
    return lines, errors


def main():
    rom = open(ROM_PATH or rom_path.rom_path(), 'rb').read()
    traces = []
    for f in sorted(os.listdir(TRACE_DIR)):
        if f.endswith('.json'):
            with open(os.path.join(TRACE_DIR, f)) as fh:
                traces.append(json.load(fh))
    rc = Recompiler(rom, traces)
    rc.discover()
    rc.build_cfg()
    lines, errors = generate(rc)
    os.makedirs(os.path.dirname(PRG_BIN), exist_ok=True)
    with open(PRG_BIN, 'wb') as f:
        f.write(rc.prg)
    with open(CHR_BIN, 'wb') as f:
        f.write(rc.chr)
    with open(OUT_PATH, 'w', encoding='utf-8') as f:
        f.write('\n'.join(lines) + '\n')
    traced = sum(1 for i in rc.insns.values() if i.traced)
    print(f'{len(rc.insns)} instructions ({traced} tracées), {len(lines)} lignes, {errors} erreurs')
    print(f'E/S lues : {sorted(set(v for m, v in rc.io_reads))}')
    print(f'E/S écrites : {sorted(set(hex(v) for m, v in rc.io_writes))}')
    print(f'sauts dynamiques : {sorted(hex(a) for a in rc.dyn_jumps)}')
    print(f'routines qui jettent leur adresse de retour : {sorted("%d:%04X" % d for d in rc.droppers)}')
    for t in rc.rts_tricks[:20]:
        print('  RTS hors retour de JSR : %d:%04X -> %d:%04X' % t)
    for w in rc.warnings[:60]:
        print('  !', w)


if __name__ == '__main__':
    main()
