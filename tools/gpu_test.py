#!/usr/bin/env python3
"""
Test du rendu GPU (source/gpu.s) dans l'émulateur RISC (jrisc.py), sur l'état
réel du programme simulé par jag_sim.py.

Le programme est exécuté N frames dans le simulateur ; la RAM (2 Mo) est
recopiée dans l'émulateur RISC avec le code GPU en G_RAM, puis un rendu est
lancé (gpu_busy = 1) jusqu'à ce que le GPU le termine. Le blitter est émulé
pour le remplissage (effacement des calques). L'image composée (bandes de
décor + calques de sprites + CLUT) est écrite en PNG.

Usage : python gpu_test.py [frames] [png]
"""

import os
import struct
import sys

from PIL import Image

import jag_sim
from jrisc import JRisc, Memory
from nes_probe import NES_RGB

G_RAM = 0xF03000
G_FLAGS = 0xF02100
B_CMD = 0xF02238
A1_BASE = 0xF02200


def blitter_fill(mem):
    """Remplissage A1 (PATDSEL) : B_COUNT lignes x pixels 8 bits, pas de 256"""
    base = mem.r32(A1_BASE)
    count = mem.r32(0xF0223C)
    lines, pixels = count >> 16, count & 0xFFFF
    for y in range(lines):
        a = base + y * 256
        mem.data[a:a + pixels] = bytes(pixels)


def main():
    frames = int(sys.argv[1]) if len(sys.argv) > 1 else 300
    out = sys.argv[2] if len(sys.argv) > 2 else None
    syms = jag_sim.symbols()
    sim = jag_sim.Sim(syms)
    for f in range(frames):
        sim.step_frame()
    # état : un instantané vient d'être pris (gpu_busy = 1 au moment de la VBL)
    mem = Memory()
    mem.data[0:0x200000] = sim.rd(0, 0x200000)
    image = open(os.path.join(jag_sim.OUT, 'CrisisForce.bin'), 'rb').read()
    code = image[syms['GPUCode'] - 0x4000:syms['GPUCodeEnd'] - 0x4000]
    mem.data[G_RAM:G_RAM + len(code)] = code
    mem.w32(syms['gpu_busy'], 1)
    mem.w32(syms['gpu_copy_busy'], 1)
    gpu = JRisc(mem, G_RAM, G_FLAGS)
    gpu.pc = syms['gpu_start']
    for n in range(20_000_000):
        gpu.step()
        if mem.r32(B_CMD) & 1 == 0 and mem.r32(B_CMD) != 0:
            blitter_fill(mem)
            mem.w32(B_CMD, 1)
        if mem.r32(syms['gpu_busy']) == 0:
            break
    else:
        sys.exit(f'GPU bloqué en ${gpu.pc:06X} après {n} instructions')
    print(f'rendu terminé en {gpu.steps} instructions GPU')
    if not out:
        return
    # composition : CLUT = palette de l'instantané
    regs = mem.data[syms['snap_regs']:syms['snap_regs'] + 72]
    pal = [NES_RGB[c & 0x3F] for c in regs[:32]]
    img = Image.new('RGB', (256, 240), pal[0])
    px = img.load()
    nb = mem.r32(syms['snap_nbands'])
    bands = []
    for k in range(nb):
        b = syms['snap_bands'] + 48 * k
        l0, l1, x0, y0 = struct.unpack('>4H', mem.data[b:b + 8])
        plane = struct.unpack('>H', mem.data[b + 10:b + 12])[0]
        bands.append((l0, l1, x0, y0, plane))
    mirror = regs[36]
    planes = syms['bg_planes']
    behind, front = mem.r32(syms['snap_behind']), mem.r32(syms['snap_front'])
    for y in range(240):
        band = next((b for b in bands if b[0] <= y < b[1]), None)
        for x in range(256):
            c = mem.data[behind + y * 256 + x]
            if band and regs[33] & 8:
                l0, l1, x0, y0, p = band
                ly = (y0 + y - l0) % 480
                lx = (x0 + x) % 512
                nx, ny = lx // 256, ly // 240
                phys = {0: nx, 1: ny, 2: 0, 3: 1}[mirror]
                v = mem.data[planes + p * 2 * 61440 + phys * 61440 + (ly % 240) * 256 + lx % 256]
                if v:
                    c = v
            f = mem.data[front + y * 256 + x]
            if f:
                c = f
            if c:
                px[x, y] = pal[c & 31]
    img.resize((512, 480), Image.NEAREST).save(out)
    print('bandes', bands, '->', out)


if __name__ == '__main__':
    main()
