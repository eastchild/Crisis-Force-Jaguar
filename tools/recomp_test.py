#!/usr/bin/env python3
"""
Banc de test différentiel du code 6502 recompilé (source/nes_code.s).

Référence : la ROM exécutée par py65 (nes_probe.py). À chaque interruption
NMI ou IRQ, l'état complet (registres, RAM, WRAM, VRAM, palette, OAM,
registres PPU/mapper) est relevé à l'entrée et au RTI correspondant. Les
interruptions sont rendues « pures » : pas d'IRQ ni de NMI imbriqués pendant
un gestionnaire (ils sont différés).

Test : le programme source/nes_test.s (runtime + code recompilé) est exécuté
dans Unicorn (68000). Pour chaque interruption relevée, l'état d'entrée est
chargé, le gestionnaire recompilé est appelé, et la mémoire est comparée à
l'état de sortie de la référence.

Usage :
    python recomp_test.py [frames] [niveau]     (défaut : 1200 frames, niveau 1)
"""

import os
import subprocess
import struct
import sys

from unicorn import Uc, UC_ARCH_M68K, UC_MODE_BIG_ENDIAN, UC_HOOK_CODE, UcError
from unicorn.m68k_const import *

from nes_probe import (NES, BTN_START, BTN_B, BTN_A, BTN_LEFT, BTN_RIGHT, BTN_SELECT, BTN_DOWN, CYCLES_PER_FRAME,
                       VBLANK_START, boot)

PROJECT_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
JS_BIN = r'D:\source_codes\jagstudio\buildfiles\bin'
SRC = os.path.join(PROJECT_DIR, 'source')
OUT = os.path.join(PROJECT_DIR, 'output')
LOAD = 0x4000

# Décalages rt_vars (nes_runtime.s)
RT = dict(slotptr=0, slotbank=16, iflag=20, irqpend=21, prgreg0=22, prgreg1=23, prgswap=24, mirror=25,
          ppuctrl=26, ppumask=27, ppustatus=28, ppuw=29, oamaddr=30, ppubuf=31, vaddr=32, scrollx=34,
          scrolly=35, padshift=36, padstrobe=37, pad=38, irqlatch=39, irqctrl=40, chrbank=42,
          error=58, erraddr=60)


def build():
    inc = os.path.join(PROJECT_DIR, 'include')
    obj = os.path.join(OUT, 'nes_test.o')
    binf = os.path.join(OUT, 'nes_test.bin')
    r = subprocess.run([os.path.join(JS_BIN, 'rmac.exe'), '-fb', f'-i{inc}', '-o', obj, 'nes_test.s'],
                       cwd=SRC, capture_output=True, text=True)
    if r.returncode:
        print(r.stdout, r.stderr)
        sys.exit('assemblage échoué')
    r = subprocess.run([os.path.join(JS_BIN, 'rln.exe'), '-z', '-rq', '-n', '-o', binf, '-a', '4000', 'x', 'x', obj],
                       capture_output=True, text=True)
    if r.returncode:
        print(r.stdout, r.stderr)
        sys.exit('édition de liens échouée')
    return open(binf, 'rb').read()


class Jag:
    """Machine 68000 Unicorn chargée avec nes_test.bin"""

    def __init__(self, image):
        self.uc = Uc(UC_ARCH_M68K, UC_MODE_BIG_ENDIAN)
        self.uc.ctl_set_cpu_model(UC_CPU_M68K_M68000)
        self.uc.mem_map(0, 0x200000)
        self.uc.mem_write(LOAD, image)
        h = struct.unpack('>19L', image[:76])
        (self.t_start, self.t_nmi, self.t_irq, self.t_reset, self.rt_vars, self.nes_ram, self.nes_wram,
         self.nes_vram, self.nes_oam, self.nes_pal, self.nes_apu, self.prg_rom, self.t_end, self.rt_halt,
         self.nmi_entry, self.irq_entry, self.label_tab, self.t_nmi_ip, self.t_irq_ip) = h
        if '--interp' in sys.argv:
            self.t_nmi, self.t_irq = self.t_nmi_ip, self.t_irq_ip
        # Étiquettes des instructions 6502 : adresse 68000 -> (banque, pc)
        self.labels = {}
        self.empty = set()          # instructions sans code (CLC, SEC, NOP...) : même adresse que la suivante
        off = self.label_tab - LOAD
        while True:
            a, bp = struct.unpack('>2L', image[off:off + 8])
            if a == 0:
                break
            if a in self.labels:
                self.empty.add(self.labels[a])
            self.labels[a] = (bp >> 16, bp & 0xFFFF)
            off += 8
        self.inv_labels = {v: k for k, v in self.labels.items()}
        self.tracing = None
        self.uc.hook_add(UC_HOOK_CODE, self._hook, begin=LOAD, end=self.label_tab)
        self.uc.reg_write(UC_M68K_REG_SR, 0x2700)
        self.uc.reg_write(UC_M68K_REG_A7, 0x1FFF00)
        self.run(self.t_start)

    def run(self, pc, limit=50_000_000):
        self.uc.reg_write(UC_M68K_REG_A7, 0x1FFF00)
        try:
            self.uc.emu_start(pc, self.t_end, count=limit)
        except UcError as ex:
            pc = self.uc.reg_read(UC_M68K_REG_PC)
            raise RuntimeError(f'exception 68000 {ex} en ${pc:06X}')
        pc = self.uc.reg_read(UC_M68K_REG_PC)
        err = self.rd16(self.rt_vars + RT['error'])
        if err:
            raise RuntimeError(f'erreur runtime {err}, adresse ${self.rd32(self.rt_vars + RT["erraddr"]):08X}')
        if pc != self.t_end:
            raise RuntimeError(f'arrêt en ${pc:06X} (limite d\'instructions ?)')

    def _hook(self, uc, address, size, user):
        if self.tracing is None:
            return
        bp = self.labels.get(address)
        if bp is not None:
            self.tracing.append((bp[0], bp[1], uc.reg_read(UC_M68K_REG_D0) & 0xFF, uc.reg_read(UC_M68K_REG_D1) & 0xFF,
                                 uc.reg_read(UC_M68K_REG_D2) & 0xFF,
                                 (uc.reg_read(UC_M68K_REG_A2) - self.nes_ram - 0x101) & 0xFF, 0))

    def trace_run(self, pc, limit=5_000_000):
        """Exécute en relevant (banque, pc, A, X, Y, S, CCR) à chaque étiquette d'instruction 6502"""
        self.tracing = []
        try:
            self.run(pc, limit)
        except RuntimeError as ex:
            self.tracing.append(('erreur', str(ex)))
        out, self.tracing = self.tracing, None
        return out

    def rd(self, a, n):
        return bytes(self.uc.mem_read(a, n))

    def rd16(self, a):
        return struct.unpack('>H', self.rd(a, 2))[0]

    def rd32(self, a):
        return struct.unpack('>L', self.rd(a, 4))[0]

    def wr(self, a, data):
        self.uc.mem_write(a, bytes(data))

    def var(self, name, val=None, size=1):
        a = self.rt_vars + RT[name]
        if val is None:
            return int.from_bytes(self.rd(a, size), 'big')
        self.wr(a, val.to_bytes(size, 'big'))


def nt_offset(addr, mirror):
    """Même calcul que rt_nt_offset (nes_runtime.s)"""
    a = addr & 0xFFF
    if mirror == 0:
        return a & 0x7FF
    if mirror == 1:
        return (a & 0x3FF) | ((a & 0x800) >> 1)
    return (a & 0x3FF) | (0x400 if mirror == 3 else 0)


def snapshot(nes, cpu):
    return {
        'a': cpu.a, 'x': cpu.x, 'y': cpu.y, 's': cpu.sp, 'p': cpu.p, 'pc': cpu.pc,
        'ram': bytes(nes.ram), 'wram': bytes(nes.wram),
        'nt': bytes(nes.vram[nes.nt_addr(0x2000 + i)] for i in range(0x1000)),
        'pal': bytes(nes.vram[0x3F00 + i] & 0x3F for i in range(32)),
        'oam': bytes(nes.oam),
        'prg': list(nes.prg_reg), 'swap': nes.prg_swap, 'mirror': nes.mirroring,
        'chr': list(nes.chr_bank), 'ctrl': nes.ppu_ctrl, 'mask': nes.ppu_mask,
        'scroll': list(nes.scroll), 'w': nes.w, 'vaddr': nes.vaddr, 'oamaddr': nes.oam_addr,
        'vblank': nes.vblank, 'latch': nes.irq_latch, 'irqctrl': nes.irq_ctrl,
        'buttons': nes.buttons, 'shift': nes.shift & 0xFF, 'strobe': nes.strobe,
    }


def load_state(jag, s):
    jag.wr(jag.nes_ram, s['ram'])
    jag.wr(jag.nes_wram, s['wram'])
    vr = bytearray(4096)
    for i in range(0x1000):
        vr[nt_offset(0x2000 + i, s['mirror'])] = s['nt'][i]
    jag.wr(jag.nes_vram, vr)
    jag.wr(jag.nes_pal, s['pal'])
    jag.wr(jag.nes_oam, s['oam'])
    jag.var('prgreg0', s['prg'][0])
    jag.var('prgreg1', s['prg'][1])
    jag.var('prgswap', s['swap'])
    banks = [s['prg'][0] if not s['swap'] else 14, s['prg'][1], 14 if not s['swap'] else s['prg'][0], 15]
    for i, b in enumerate(banks):
        jag.wr(jag.rt_vars + RT['slotbank'] + i, [b])
        jag.wr(jag.rt_vars + RT['slotptr'] + 4 * i, struct.pack('>L', jag.prg_rom + b * 8192))
    jag.var('mirror', s['mirror'])
    jag.var('ppuctrl', s['ctrl'])
    jag.var('ppumask', s['mask'])
    jag.var('ppustatus', 0x80 if s['vblank'] else 0)
    jag.var('ppuw', 0xFF if s['w'] else 0)
    jag.var('oamaddr', s['oamaddr'])
    jag.var('vaddr', s['vaddr'] & 0x3FFF, 2)
    jag.var('scrollx', s['scroll'][0])
    jag.var('scrolly', s['scroll'][1])
    jag.var('irqlatch', s['latch'])
    jag.var('irqctrl', s['irqctrl'])
    for i, b in enumerate(s['chr']):
        jag.wr(jag.rt_vars + RT['chrbank'] + 2 * i, struct.pack('>H', b))
    jag.var('pad', s['buttons'])
    jag.var('padshift', s['shift'])
    jag.var('padstrobe', s['strobe'])
    jag.var('iflag', 0xFF if s['p'] & 4 else 0)
    jag.var('irqpend', 0)
    uc = jag.uc
    uc.reg_write(UC_M68K_REG_D0, s['a'])
    uc.reg_write(UC_M68K_REG_D1, s['x'])
    uc.reg_write(UC_M68K_REG_D2, s['y'])
    uc.reg_write(UC_M68K_REG_D6, 0xFF if s['p'] & 0x40 else 0)
    uc.reg_write(UC_M68K_REG_A2, jag.nes_ram + 0x100 + s['s'] + 1)
    p = s['p']
    ccr = (8 if p & 0x80 else 0) | (4 if p & 2 else 0) | (0x11 if p & 1 else 0)
    uc.reg_write(UC_M68K_REG_SR, 0x2700 | ccr)


def compare(jag, ref, what):
    """Différences entre l'état Unicorn et l'état de sortie de la référence"""
    diffs = []
    ram = jag.rd(jag.nes_ram, 2048)
    for i in range(2048):
        if 0x100 <= i < 0x200:
            continue
        if ram[i] != ref['ram'][i]:
            diffs.append(f'RAM ${i:03X}: {ram[i]:02X} au lieu de {ref["ram"][i]:02X}')
    wram = jag.rd(jag.nes_wram, 8192)
    for i in range(8192):
        if wram[i] != ref['wram'][i]:
            diffs.append(f'WRAM ${0x6000 + i:04X}: {wram[i]:02X} au lieu de {ref["wram"][i]:02X}')
    vr = jag.rd(jag.nes_vram, 4096)
    mirror = jag.var('mirror')
    for i in range(0x1000):
        v = vr[nt_offset(0x2000 + i, mirror)]
        if v != ref['nt'][i]:
            diffs.append(f'VRAM ${0x2000 + i:04X}: {v:02X} au lieu de {ref["nt"][i]:02X}')
    pal = jag.rd(jag.nes_pal, 32)
    for i in range(32):
        if pal[i] != ref['pal'][i] and (i & 3 or i < 16):
            diffs.append(f'palette {i}: {pal[i]:02X} au lieu de {ref["pal"][i]:02X}')
    if jag.rd(jag.nes_oam, 256) != ref['oam']:
        diffs.append('OAM différente')
    for name, key in (('ppuctrl', 'ctrl'), ('ppumask', 'mask'), ('mirror', 'mirror'), ('irqlatch', 'latch')):
        if jag.var(name) != ref[key]:
            diffs.append(f'{name}: {jag.var(name):02X} au lieu de {ref[key]:02X}')
    if [jag.var('prgreg0'), jag.var('prgreg1')] != ref['prg']:
        diffs.append(f'PRG {[jag.var("prgreg0"), jag.var("prgreg1")]} au lieu de {ref["prg"]}')
    chr_ = [struct.unpack('>H', jag.rd(jag.rt_vars + RT['chrbank'] + 2 * i, 2))[0] for i in range(8)]
    if chr_ != ref['chr']:
        diffs.append(f'CHR {chr_} au lieu de {ref["chr"]}')
    if [jag.var('scrollx'), jag.var('scrolly')] != ref['scroll']:
        diffs.append(f'scroll {[jag.var("scrollx"), jag.var("scrolly")]} au lieu de {ref["scroll"]}')
    return diffs


def reference_run(frames, stage, buttons, on_pair, start=None, per_frame=None):
    """Exécute la ROM ; on_pair(kind, entrée, sortie) pour chaque interruption pure.
    start : (nes, cpu) d'un état sauvé (pickle de nes_probe) ; per_frame(nes) : avant chaque image"""
    nes, cpu = start if start else boot()
    if stage > 1:
        nes.prg = bytearray(nes.prg)
        nes.prg[14 * 8192 + 0xB14] = stage - 1
    frame_cycle = 0
    active = None           # ('nmi'|'irq', snapshot d'entrée, S attendu au retour, trace)
    for frame in range(frames):
        if active is None:
            nes.buttons = buttons(frame)
        if per_frame:
            per_frame(nes)
        in_vblank = False
        nmi_wanted = False
        while frame_cycle < CYCLES_PER_FRAME:
            op = nes[cpu.pc]
            if active is not None:
                active[3].append((nes.prg_bank_for((cpu.pc - 0x8000) >> 13) if cpu.pc >= 0x8000 else -1,
                                  cpu.pc, cpu.a, cpu.x, cpu.y, cpu.sp, cpu.p))
            before = cpu.processorCycles
            cpu.step()
            spent = cpu.processorCycles - before + nes.dma_cycles
            nes.dma_cycles = 0
            nes.clock_irq(spent)
            frame_cycle += spent
            if active and op == 0x40 and cpu.sp == active[2]:
                on_pair(active[0], active[1], snapshot(nes, cpu), active[3])
                active = None
            if not in_vblank and frame_cycle >= VBLANK_START:
                in_vblank = True
                nes.vblank = True
                if nes.ppu_ctrl & 0x80:
                    nmi_wanted = True
            if active is None:
                if nmi_wanted:
                    nmi_wanted = False
                    entry = snapshot(nes, cpu)
                    active = ('nmi', entry, cpu.sp, [])
                    cpu.nmi()
                elif nes.irq_pending and not (cpu.p & cpu.INTERRUPT):
                    entry = snapshot(nes, cpu)
                    active = ('irq', entry, cpu.sp, [])
                    cpu.irq()
        frame_cycle -= CYCLES_PER_FRAME
        nes.vblank = False
        nes.sprite0 = False
    return nes, cpu


def lockstep(jag, kind, entry, rtrace):
    """Première divergence instruction par instruction entre la référence et le 68000"""
    load_state(jag, entry)
    jt = jag.trace_run(jag.t_nmi if kind == 'nmi' else jag.t_irq)
    # le répartiteur \ est remplacé par un saut direct dans le code recompilé
    rtrace = [r for r in rtrace if not (r[0] == 14 and 0xC75F <= r[1] <= 0xC779) and (r[0], r[1]) not in jag.empty]
    n = min(len(jt), len(rtrace))
    for i in range(n):
        r, j = rtrace[i], jt[i]
        if j[0] == 'erreur' or r[:6] != j[:6]:
            print(f'    divergence à l\'instruction {i} :')
            for k in range(max(0, i - 6), i + 1):
                rr = rtrace[k]
                jj = jt[k] if k < len(jt) else None
                print(f'      réf {rr[0]:2d}:{rr[1]:04X} A={rr[2]:02X} X={rr[3]:02X} Y={rr[4]:02X} S={rr[5]:02X} P={rr[6]:02X}'
                      f'  | 68k {jj}')
            return
    print(f'    pas de divergence de trace ({len(rtrace)} / {len(jt)} instructions)')


def main():
    args = [a for a in sys.argv[1:] if not a.startswith('--')]
    frames = int(args[0]) if args else 1200
    stage = int(args[1]) if len(args) > 1 else 1
    image = build()
    jag = Jag(image)
    print(f'binaire {len(image)} octets, NMI ${jag.nmi_entry:06X}, IRQ ${jag.irq_entry:06X}')

    def buttons(f):
        if '--options' in sys.argv:
            # écran OPTION : Bas, Bas, B au titre (menu de tools/rom_patches.py), puis menu
            script = [(400, BTN_DOWN), (420, BTN_DOWN), (450, BTN_B), (700, BTN_DOWN),
                      (730, BTN_RIGHT), (760, BTN_DOWN), (790, BTN_RIGHT), (820, BTN_DOWN), (850, BTN_RIGHT)]
            return sum(b for f0, b in script if f0 <= f < f0 + 6)
        if any(a.startswith('--state=') for a in sys.argv):
            f += 244                            # partie en cours : tir et déplacements seulement
        if f < 244:
            return BTN_START if f in (0, 1, 2, 3) else BTN_B if f in (240, 241, 242, 243) else 0   # B valide (menu modifié)
        b = BTN_B if f % 8 < 4 else 0
        b |= BTN_LEFT if (f // 90) % 2 else BTN_RIGHT
        return b

    stats = {'nmi': [0, 0], 'irq': [0, 0]}
    shown = [0]

    def on_pair(kind, entry, exit_, rtrace):
        stats[kind][0] += 1
        load_state(jag, entry)
        try:
            jag.run(jag.t_nmi if kind == 'nmi' else jag.t_irq)
            diffs = compare(jag, exit_, kind)
        except RuntimeError as ex:
            diffs = [str(ex)]
        if diffs:
            stats[kind][1] += 1
            if shown[0] < 12:
                shown[0] += 1
                print(f'{kind} n°{stats[kind][0]} (pc ${entry["pc"]:04X}) : {len(diffs)} différences')
                for d in diffs[:8]:
                    print('    ', d)
                if shown[0] <= 3 and '--interp' not in sys.argv:
                    lockstep(jag, kind, entry, rtrace)

    # --state=fichier : départ d'un état sauvé (pickle (nes, cpu) de nes_probe) ;
    # --poke=adr:val,... : écritures en RAM/WRAM au départ ; --lives : vies
    # du joueur 1 ($68) maintenues (scénarios longs, ex. boss)
    start, per_frame = None, None
    opt = {a.split('=')[0]: a.split('=', 1)[1] for a in sys.argv if a.startswith('--') and '=' in a}
    if '--state' in opt:
        import pickle
        start = pickle.load(open(opt['--state'], 'rb'))
        for item in filter(None, opt.get('--poke', '').split(',')):
            a, v = (int(x, 16) for x in item.split(':'))
            start[0][a] = v
    if '--lives' in sys.argv:
        def per_frame(nes):
            nes.ram[0x68] = 3
    reference_run(frames, stage, buttons, on_pair, start, per_frame)
    for k, (n, bad) in stats.items():
        print(f'{k} : {n} appels, {bad} en échec')


if __name__ == '__main__':
    main()
