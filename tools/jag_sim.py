#!/usr/bin/env python3
"""
Simulateur Â« Jaguar lÃ©ger Â» du programme complet (output/CrisisForce.bin) sous
Unicorn (68000), pour dÃ©boguer l'intÃ©gration sans Ã©mulateur Jaguar :
  - les registres matÃ©riels ($F00000-$F1FFFF) sont de la mÃ©moire ordinaire ;
  - l'interruption vidÃ©o est injectÃ©e toutes les ~INSNS_PER_FRAME instructions
    (cadre d'exception 68000 + vecteur LEVEL0) si le masque du SR le permet,
    avec INT1 indiquant la source (bit 0 = VI, bit 3 = PIT) ;
  - le GPU est simulÃ© : quand gpu_busy passe Ã  1, le rendu (dÃ©cor + sprites)
    est fait en Python Ã  partir de l'instantanÃ©, puis gpu_busy repasse Ã  0 ;
  - les manettes renvoient Â« aucun bouton Â» (le build --autotest les simule).

Les adresses des symboles viennent de la carte de rln (build.py -> -m).

Usage : python jag_sim.py [frames] [png de sortie]
"""

import os
import re
import struct
import subprocess
import sys

from PIL import Image
from unicorn import Uc, UC_ARCH_M68K, UC_MODE_BIG_ENDIAN, UcError, UC_HOOK_CODE, UC_HOOK_MEM_READ, UC_HOOK_MEM_WRITE
from unicorn.m68k_const import *

from nes_probe import NES_RGB
from jrisc import JRisc


class UcBus:
    """Mémoire Unicorn vue par l'émulateur RISC (GPU), avec contrôle des écritures"""

    def __init__(self, uc, allowed, log):
        self.uc = uc
        self.allowed = allowed          # [(début, fin)] autorisés en RAM principale
        self.log = log

    def r8(self, a):
        return self.uc.mem_read(a & 0xFFFFFF, 1)[0]

    def r16(self, a):
        return int.from_bytes(self.uc.mem_read(a & 0xFFFFFF, 2), 'big')

    def r32(self, a):
        return int.from_bytes(self.uc.mem_read(a & 0xFFFFFF, 4), 'big')

    def check(self, a, n):
        a &= 0xFFFFFF
        if a < 0x200000 and not any(lo <= a and a + n <= hi for lo, hi in self.allowed):
            if len(self.log) < 20:
                self.log.append(a)

    def w8(self, a, v):
        self.check(a, 1)
        self.uc.mem_write(a & 0xFFFFFF, bytes([v & 0xFF]))

    def w16(self, a, v):
        self.check(a, 2)
        self.uc.mem_write(a & 0xFFFFFF, (v & 0xFFFF).to_bytes(2, 'big'))

    def w32(self, a, v):
        self.check(a, 4)
        self.uc.mem_write(a & 0xFFFFFF, (v & 0xFFFFFFFF).to_bytes(4, 'big'))

PROJECT_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(PROJECT_DIR, 'output')
LOAD = 0x4000
INSNS_PER_FRAME = 60000
LEVEL0 = 0x100


def symbols():
    """Symboles depuis le listing de rmac (main.lst) : on relit la carte de rln"""
    path = os.path.join(OUT, 'CrisisForce.map')
    syms = {}
    if os.path.exists(path):
        for line in open(path, errors='replace'):
            for name, addr in re.findall(r'(\S+)\s+[LG]\s+([0-9A-Fa-f]{8})', line):
                syms[name] = int(addr, 16)
    return syms


class Sim:
    def __init__(self, syms):
        self.syms = syms
        image = open(os.path.join(OUT, 'CrisisForce.bin'), 'rb').read()
        self.uc = uc = Uc(UC_ARCH_M68K, UC_MODE_BIG_ENDIAN)
        uc.ctl_set_cpu_model(UC_CPU_M68K_M68000)
        uc.mem_map(0, 0x200000)
        uc.mem_map(0xF00000, 0x20000)
        uc.mem_map(0xFFF000, 0x1000)
        uc.mem_write(LOAD, image)
        uc.reg_write(UC_M68K_REG_SR, 0x2700)
        uc.reg_write(UC_M68K_REG_PC, LOAD)
        # Manettes : aucun bouton (actifs Ã  0) ; le programme Ã©crit le sÃ©lecteur
        # de rangÃ©e au mÃªme endroit, la valeur est rÃ©tablie avant chaque lecture
        joy = bytes.fromhex(os.environ.get('SIM_JOY', 'FFFFFFFF'))
        uc.mem_write(0xF14000, joy)
        # Manette 1 simulée (self.buttons : 'up', 'down', 'left', 'right', 'pause',
        # 'a', 'b', 'c', 'option') : rangée choisie par l'écriture dans JOYSTICK
        self.buttons = set()
        self.joy_row = 0xF
        uc.hook_add(UC_HOOK_MEM_WRITE, self._joy_write, begin=0xF14000, end=0xF14001)
        uc.hook_add(UC_HOOK_MEM_READ, lambda uc_, acc, addr, size, val, u: self._joy_read(joy),
                    begin=0xF14000, end=0xF14003)
        self.pc = LOAD
        self.frame = 0
        # RTE du gestionnaire d'interruption
        a = syms['jag_int']
        while self.r16(a) != 0x4E73:
            a += 2
        uc.hook_add(UC_HOOK_CODE, self._rte_hook, begin=a, end=a)
        # Copie VRAM/OAM faite par le GPU (gpu.s) : simulée à la première
        # lecture de gpu_copy_busy par le 68000
        cb = syms.get('gpu_copy_busy')
        if cb:
            uc.hook_add(UC_HOOK_MEM_READ, self._gpu_copy_hook, begin=cb, end=cb + 3)
        # GpuSetOlp (OLP écrit par le petit programme GPU set_olp) : fait en Python
        a = syms.get('GpuSetOlp')
        if a:
            uc.hook_add(UC_HOOK_CODE, self._set_olp_hook, begin=a, end=a)
        # Boucle principale (hle_idle) : stop #$2000 = attente de l'interruption
        # suivante -> fin de la tranche d'exécution en cours
        a = syms.get('hle_idle_stop')
        if a:
            uc.hook_add(UC_HOOK_CODE, self._stop_hook, begin=a, end=a)

    def _set_olp_hook(self, uc, address, size, user):
        d0 = uc.reg_read(UC_M68K_REG_D0) & 0xFFFFFFFF
        self.w32(0xF00020, ((d0 & 0xFFFF) << 16) | (d0 >> 16))
        sp = uc.reg_read(UC_M68K_REG_A7)
        uc.reg_write(UC_M68K_REG_PC, struct.unpack('>L', self.rd(sp, 4))[0])
        uc.reg_write(UC_M68K_REG_A7, sp + 4)

    def _stop_hook(self, uc, address, size, user):
        uc.reg_write(UC_M68K_REG_PC, address + 4)
        uc.emu_stop()

    # Sauvegarde / reprise d'un état complet (mémoire, registres 68000, PIT) entre
    # deux images : scénarios longs (boss...) rejoués sans repartir du début
    MEM = ((0, 0x200000), (0xF00000, 0x20000), (0xFFF000, 0x1000))
    REGS = [UC_M68K_REG_D0 + i for i in range(8)] + [UC_M68K_REG_A0 + i for i in range(8)] + [UC_M68K_REG_SR]

    def save_state(self, path):
        import pickle
        st = {'mem': [bytes(self.uc.mem_read(a, n)) for a, n in self.MEM],
              'regs': [self.uc.reg_read(r) for r in self.REGS],
              'pc': self.pc, 'frame': self.frame, 'pit_next': getattr(self, 'pit_next', None), 'joy_row': self.joy_row}
        with open(path, 'wb') as f:
            pickle.dump(st, f)

    def load_state(self, path):
        import pickle
        st = pickle.load(open(path, 'rb'))
        for (a, n), data in zip(self.MEM, st['mem']):
            self.uc.mem_write(a, data)
        for r, v in zip(self.REGS, st['regs']):
            self.uc.reg_write(r, v)
        self.pc, self.frame, self.joy_row = st['pc'], st['frame'], st['joy_row']
        if st['pit_next'] is not None:
            self.pit_next = st['pit_next']

    def _joy_write(self, uc, access, addr, size, value, user):
        if addr == 0xF14000 and size == 2:
            self.joy_row = value & 0xF
        elif addr == 0xF14001 and size == 1:
            self.joy_row = value & 0xF

    # (rangée sélectionnée : bit à 0) -> {bouton: (registre, bit)} ; JOYSTICK
    # bits 8-11 (octet haut), JOYBUTS bits 0-1
    JOY_ROWS = {
        0: {'up': ('s', 8), 'down': ('s', 9), 'left': ('s', 10), 'right': ('s', 11), 'pause': ('b', 0), 'a': ('b', 1)},
        1: {'b': ('b', 1)},
        2: {'c': ('b', 1)},
        3: {'option': ('b', 1)},
    }

    def _joy_read(self, default):
        if not self.buttons:
            self.uc.mem_write(0xF14000, default)
            return
        stick, buts = 0xFFFF, 0xFFFF
        for row in range(4):
            if not (self.joy_row >> row) & 1:
                for name, (reg, bit) in self.JOY_ROWS[row].items():
                    if name in self.buttons:
                        if reg == 's':
                            stick &= ~(1 << bit)
                        else:
                            buts &= ~(1 << bit)
        self.uc.mem_write(0xF14000, struct.pack('>HH', stick & 0xFFFF, buts & 0xFFFF))

    def _gpu_copy_hook(self, uc, access, addr, size, value, user):
        s = self.syms
        if self.r32(s['gpu_copy_busy']):
            uc.mem_write(s['snap_vram'], bytes(uc.mem_read(s['nes_vram'], 2048)))
            uc.mem_write(s['snap_oam'], bytes(uc.mem_read(s['nes_oam'], 256)))
            uc.mem_write(s['gpu_copy_busy'], bytes(4))

    def rd(self, a, n):
        return bytes(self.uc.mem_read(a, n))

    def r32(self, a):
        return struct.unpack('>L', self.rd(a, 4))[0]

    def r16(self, a):
        return struct.unpack('>H', self.rd(a, 2))[0]

    def w32(self, a, v):
        self.uc.mem_write(a, struct.pack('>L', v & 0xFFFFFFFF))

    def w16(self, a, v):
        self.uc.mem_write(a, struct.pack('>H', v & 0xFFFF))

    def _rte_hook(self, uc, address, size, user):
        """RTE fait en Python (Unicorn ne sait pas l'exÃ©cuter en 68000)"""
        sp = uc.reg_read(UC_M68K_REG_A7)
        sr, ret = struct.unpack('>HL', self.rd(sp, 6))
        uc.reg_write(UC_M68K_REG_A7, sp + 6)
        uc.reg_write(UC_M68K_REG_SR, sr)
        uc.reg_write(UC_M68K_REG_PC, ret)

    def run(self, count):
        uc = self.uc
        try:
            uc.emu_start(self.pc, 0xFFFFFFFF, count=count)
        except UcError as ex:
            pc = uc.reg_read(UC_M68K_REG_PC)
            raise RuntimeError(f'exception 68000 {ex} en ${pc:06X}')
        self.pc = uc.reg_read(UC_M68K_REG_PC)

    def interrupt(self, int1):
        """Interruption Tom (vecteur LEVEL0) si le masque du SR le permet"""
        uc = self.uc
        sr = uc.reg_read(UC_M68K_REG_SR)
        if (sr & 0x700) >= 0x200:
            return False
        self.w16(0xF000E0, int1)
        sp = uc.reg_read(UC_M68K_REG_A7) - 6
        uc.mem_write(sp, struct.pack('>HL', sr, self.pc))
        uc.reg_write(UC_M68K_REG_A7, sp)
        uc.reg_write(UC_M68K_REG_SR, (sr & 0xF8FF) | 0x2200)
        self.pc = self.r32(LEVEL0)
        return True

    def step_frame(self):
        """Une frame : 262 lignes ; IRQ VRC4 (PIT) toutes les (256 - latch) lignes si armÃ©e"""
        rt = self.syms['rt_vars']
        line = 0
        per_line = INSNS_PER_FRAME / 262
        while line < 262:
            ctrl = self.rd(rt + 40, 1)[0]
            latch = self.rd(rt + 39, 1)[0]
            period = 256 - latch if ctrl & 2 else 262
            if not hasattr(self, 'pit_next') or not (ctrl & 2):
                self.pit_next = period
            step = min(self.pit_next, 262 - line)
            self.run(max(1, int(step * per_line)))
            line += step
            self.pit_next -= step
            if ctrl & 2 and self.pit_next <= 0:
                self.pit_next += period
                self.interrupt(0x0008)
        self.frame += 1
        # GPU simulÃ©
        busy = self.syms['gpu_busy']
        if self.r32(busy):
            self.gpu_render()
            self.w32(busy, 0)
        self.interrupt(0x0001)

    # ---------- rendu GPU simulÃ© (mÃªme algorithme que gpu.s) ----------
    def gpu_render(self):
        s = self.syms
        if getattr(self, 'real_gpu', False):
            # Vrai code GPU (copié en G_RAM par InitGPU) dans l'émulateur RISC,
            # sur la mémoire Unicorn, jusqu'à la fin du rendu (gpu_busy = 0)
            if not hasattr(self, 'gpu'):
                self.gpu_log = []
                lo, hi = s['bss_start'], s['bss_end']
                self.bus = UcBus(self.uc, [(lo, hi)], self.gpu_log)
                self.gpu = JRisc(self.bus, 0xF03000, 0xF02100)
                self.gpu.pc = s['gpu_start']
            for _ in range(20_000_000):
                self.gpu.step()
                if self.r32(s['gpu_busy']) == 0 and self.gpu.delay is None:
                    break
            else:
                sys.exit(f'GPU bloqué en ${self.gpu.pc:06X}')
            if self.gpu_log:
                print('écritures GPU hors zone :', [hex(a) for a in self.gpu_log[:5]])
                self.gpu_log.clear()
        regs = self.rd(s['snap_regs'], 72)
        ctrl = regs[32]
        chrptr = struct.unpack('>8L', regs[40:72])
        vram = self.rd(s['snap_vram'], 2048)
        oam = self.rd(s['snap_oam'], 256)
        self.last = (regs, vram, oam, chrptr)

    def screen(self):
        """Image NES reconstruite depuis le dernier instantanÃ© (contrÃ´le visuel)"""
        regs, vram, oam, chrptr = self.last
        pal = regs[:32]
        ctrl, mask, sx, sy, mirror = regs[32], regs[33], regs[34], regs[35], regs[36]
        chr_mem = {}

        def chr_byte(addr):
            p = chrptr[addr >> 10] + (addr & 0x3FF)
            return self.rd(p, 1)[0]

        img = Image.new('RGB', (256, 240), NES_RGB[pal[0] & 0x3F])
        px = img.load()
        bgtab = 0x1000 if ctrl & 0x10 else 0
        if mask & 8:
            for y in range(240):
                ly = (sy + y + ((ctrl >> 1) & 1) * 240) % 480
                ny, ty = ly // 240, ly % 240
                for x in range(256):
                    lx = (sx + x + (ctrl & 1) * 256) % 512
                    nx, tx = lx // 256, lx % 256
                    phys = {0: nx, 1: ny, 2: 0, 3: 1}[mirror]
                    base = phys * 1024
                    tile = vram[base + (ty // 8) * 32 + tx // 8]
                    attr = vram[base + 0x3C0 + (ty // 32) * 8 + tx // 32]
                    p = (attr >> ((((ty // 8) & 2) << 1) | ((tx // 8) & 2))) & 3
                    a = bgtab + tile * 16 + (ty & 7)
                    b0, b1 = chr_byte(a), chr_byte(a + 8)
                    c = ((b0 >> (7 - (tx & 7))) & 1) | (((b1 >> (7 - (tx & 7))) & 1) << 1)
                    if c:
                        px[x, y] = NES_RGB[pal[p * 4 + c] & 0x3F]
        if mask & 0x10:
            for i in range(63, -1, -1):
                y, t, at, x = oam[i * 4:i * 4 + 4]
                if y >= 0xEF:
                    continue
                h = 16 if ctrl & 0x20 else 8
                for r in range(h):
                    sr_ = h - 1 - r if at & 0x80 else r
                    if h == 16:
                        a = (t & 1) * 0x1000 + ((t & 0xFE) + (sr_ >> 3)) * 16 + (sr_ & 7)
                    else:
                        a = (0x1000 if ctrl & 8 else 0) + t * 16 + sr_
                    b0, b1 = chr_byte(a), chr_byte(a + 8)
                    for c in range(8):
                        bit = c if at & 0x40 else 7 - c
                        v = ((b0 >> bit) & 1) | (((b1 >> bit) & 1) << 1)
                        xx, yy = x + c, y + 1 + r
                        if v and xx < 256 and yy < 240:
                            px[xx, yy] = NES_RGB[pal[16 + (at & 3) * 4 + v] & 0x3F]
        return img


def compose_ol(sim, width=320):
    """
    Image affichée par l'Object Processor : liste d'objets réelle (ObjectList),
    bitmaps 8 bpp rendus par le GPU, CLUT et couleur de fond de Tom. Lignes NES
    0-239 (VC = a_ypos + 2*y), x = XPOS - (a_xpos - 32) : l'image NES est en
    32..287, bordures comprises.
    """
    s = sim.syms
    a_ypos = sim.r16(s['a_ypos'])
    clut = [sim.r16(0xF00400 + 2 * i) for i in range(256)]
    bg = sim.r16(0xF00058)

    def rgb(c):
        r, b, g = (c >> 11) & 31, (c >> 6) & 31, c & 63
        return (r * 255 // 31, g * 255 // 63, b * 255 // 31)

    img = Image.new('RGB', (width, 240), rgb(bg))
    px = img.load()
    for y in range(240):
        vc = a_ypos + 2 * y
        addr = s['ObjectList']
        for _ in range(64):
            hi, lo = sim.r32(addr), sim.r32(addr + 4)
            typ = lo & 7
            ypos = (lo >> 3) & 0x7FF
            link = (((hi & 0x7FF) << 8) | (lo >> 24)) << 3
            if typ == 4:
                break
            if typ == 3:
                cc = (lo >> 14) & 3
                take = (cc == 0 and ypos == vc) or (cc == 1 and ypos > vc) or (cc == 2 and ypos < vc)
                addr = link if take else addr + 8
                continue
            if typ == 0:
                height = (lo >> 14) & 0x3FF
                data = (hi >> 11) << 3
                hi2, lo2 = sim.r32(addr + 8), sim.r32(addr + 12)
                xpos = lo2 & 0xFFF
                if xpos & 0x800:
                    xpos -= 0x1000
                dwidth = (lo2 >> 18) & 0x3FF
                iwidth = ((hi2 & 0x3F) << 4) | (lo2 >> 28)
                trans = (hi2 >> 15) & 1
                firstpix = ((hi2 >> 17) & 0x3F) >> 3
                row = (vc - ypos) // 2
                if ypos <= vc and row < height:
                    line = sim.rd(data + row * dwidth * 8, iwidth * 8)
                    x0 = xpos - sim.r16(s['a_xpos']) + 32
                    for i in range(firstpix, iwidth * 8):
                        c = line[i]
                        x = x0 + i - firstpix
                        if 0 <= x < width and not (trans and c == 0):
                            px[x, y] = rgb(clut[c])
                addr = link
                continue
            break
    return img


def main():
    args = [a for a in sys.argv[1:] if not a.startswith('--')]
    frames = int(args[0]) if args else 600
    out = args[1] if len(args) > 1 else None
    syms = symbols()
    if 'gpu_busy' not in syms:
        sys.exit('symboles introuvables : relancer build.py (carte rln)')
    sim = Sim(syms)
    sim.real_gpu = '--gpu' in sys.argv
    rt = syms['rt_vars']
    ram = syms['nes_ram']
    for f in range(frames):
        sim.step_frame()
        err = sim.r16(rt + 58)
        if err:
            print(f'frame {f}: erreur runtime {err}, adresse ${sim.r32(rt + 60):08X}')
            break
        if f % 60 == 0 or f == frames - 1:
            print(f'frame {f}: pc ${sim.pc:06X} vbl={sim.r32(rt + 72)} ctrl=${sim.rd(rt + 26, 1)[0]:02X} '
                  f'mask=${sim.rd(rt + 27, 1)[0]:02X} stage=${sim.rd(ram + 0x59, 1)[0]:02X} '
                  f'etat=${sim.rd(ram + 0x4E, 1)[0]:02X} apu={sim.r32(rt + 64)}', flush=True)
    if out and '--ol' in sys.argv:
        compose_ol(sim).resize((640, 480), Image.NEAREST).save(out)
        print('image (liste d\'objets) :', out)
    elif out and hasattr(sim, 'last'):
        sim.screen().resize((512, 480), Image.NEAREST).save(out)
        print('image :', out)


if __name__ == '__main__':
    main()
