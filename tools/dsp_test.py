#!/usr/bin/env python3
"""
Test du synthÃƒÂ© APU du DSP (source/dsp.s) dans l'ÃƒÂ©mulateur RISC (jrisc.py).

1. La ROM est exÃƒÂ©cutÃƒÂ©e par py65 (nes_probe.py) ; chaque ÃƒÂ©criture APU est
   relevÃƒÂ©e avec son cycle CPU.
2. Le code DSP est extrait de output/CrisisForce.bin (build.py) et exÃƒÂ©cutÃƒÂ© :
   les ÃƒÂ©critures sont dÃƒÂ©posÃƒÂ©es dans l'anneau dsp_ring au bon moment (comme
   rt_wr_apu), l'interruption I2S est dÃƒÂ©clenchÃƒÂ©e ÃƒÂ  25 971 Hz.
3. Les ÃƒÂ©chantillons ÃƒÂ©crits dans L_I2S forment assets/sound_preview/dsp_*.wav.

Usage : python dsp_test.py [secondes] [niveau]
"""

import os
import re
import struct
import sys
import wave

from jrisc import JRisc, Memory
from nes_probe import BTN_START, BTN_B, BTN_LEFT, BTN_RIGHT, NES, boot, run_frames

PROJECT_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(PROJECT_DIR, 'output')
PREVIEW = os.path.join(PROJECT_DIR, 'assets', 'sound_preview')
LOAD = 0x4000
D_RAM = 0xF1B000
D_FLAGS = 0xF1A100
L_I2S = 0xF1A148
CPU_HZ = 1789773
START_FRAME = 700         # début de la capture : niveau 1 lancé, musique en cours
RATE = 26593900 / (64 * 16)
MAIN_STEPS = 120          # instructions de la boucle principale entre deux ÃƒÂ©chantillons


def symbols():
    syms = {}
    for line in open(os.path.join(OUT, 'CrisisForce.map'), errors='replace'):
        for name, addr in re.findall(r'(\S+)\s+[LG]\s+([0-9A-Fa-f]{8})', line):
            syms[name] = int(addr, 16)
    return syms


def capture_writes(seconds, stage):
    """Ãƒâ€°critures APU (temps en secondes depuis le dÃƒÂ©but de la partie, adresse, valeur)"""
    nes, cpu = boot()
    if stage > 1:
        nes.prg = bytearray(nes.prg)
        nes.prg[14 * 8192 + 0xB14] = stage - 1
    log = []
    orig = NES.__setitem__

    def setitem(self, addr, val):
        if 0x4000 <= addr <= 0x4017 and addr != 0x4014 and addr != 0x4016:
            log.append((cpu.processorCycles, addr, val & 0xFF))
        orig(self, addr, val)
    NES.__setitem__ = setitem
    start = {}

    def buttons(f):
        if f < 244:
            return BTN_START if f in (0, 1, 2, 3) else BTN_B if f in (240, 241, 242, 243) else 0   # B valide (menu modifié)
        b = BTN_B if f % 8 < 4 else 0
        return b | (BTN_LEFT if (f // 90) % 2 else BTN_RIGHT)

    def cb(f):
        nes.ram[0x68] = 3
        if f == START_FRAME:
            start['cyc'] = cpu.processorCycles
    try:
        run_frames(nes, cpu, START_FRAME + int(seconds * 60) + 2, buttons_fn=buttons, callback=cb)
    finally:
        NES.__setitem__ = orig
    c0 = start['cyc']
    return [((c - c0) / CPU_HZ, a, v) for c, a, v in log if c >= c0]


def replay_writes(path, t0, t1):
    """Écritures relevées dans MAME (scratch apu_tap.lua : temps, adresse, donnée
    16 bits, masque) : chaque entrée de dsp_ring = 2 écritures de mot"""
    writes, high = [], {}
    for line in open(path):
        t, off, data, _ = line.replace(',', '.').split()
        t, off, data = float(t), int(off, 16), int(data, 16) & 0xFFFF
        if off & 2 == 0:
            high[off] = data
        elif t0 <= t < t1 and (off - 2) in high:
            v = (high.pop(off - 2) << 16) | data
            writes.append((t - t0, 0x4000 + (v >> 8), v & 0xFF))
    return writes


def main():
    replay = None
    if '--replay' in sys.argv:
        i = sys.argv.index('--replay')
        replay = (sys.argv[i + 1], float(sys.argv[i + 2]), float(sys.argv[i + 3]))
        del sys.argv[i:i + 4]
    seconds = float(sys.argv[1]) if len(sys.argv) > 1 else 5.0
    stage = int(sys.argv[2]) if len(sys.argv) > 2 else 1
    if replay:
        seconds = replay[2] - replay[1]
    syms = symbols()
    image = open(os.path.join(OUT, 'CrisisForce.bin'), 'rb').read()
    mem = Memory()
    mem.data[LOAD:LOAD + len(image)] = image
    code = image[syms['DSPCode'] - LOAD:syms['DSPCodeEnd'] - LOAD]
    mem.data[D_RAM:D_RAM + len(code)] = code
    out = []
    mem.write_hooks[L_I2S] = lambda v: out.append(v)

    print('Capture des ÃƒÂ©critures APU (py65)...', flush=True)
    writes = replay_writes(*replay) if replay else capture_writes(seconds, stage)
    # Trace des voies au moment du mixage (pulse1+2, triangle, bruit, DMC)
    mix_pc = syms.get('dsp_dmc_done')
    chans = []
    print(f'  {len(writes)} ÃƒÂ©critures', flush=True)

    dsp = JRisc(mem, D_RAM, D_FLAGS)
    dsp.pc = syms['dsp_start']
    ring, ring_wr = syms['dsp_ring'], syms['dsp_ring_wr']
    wi = 0
    nsamples = int(seconds * RATE)
    for i in range(nsamples):
        t = i / RATE
        # ÃƒÂ©critures du 68000 arrivÃƒÂ©es avant cet ÃƒÂ©chantillon
        while wi < len(writes) and writes[wi][0] <= t:
            _, a, v = writes[wi]
            idx = mem.r32(ring_wr) & 63
            mem.w32(ring + idx * 4, ((a - 0x4000) << 8) | v)
            mem.w32(ring_wr, (idx + 1) & 63)
            wi += 1
        for _ in range(MAIN_STEPS):
            dsp.step()
        # interruption I2S (hors crÃƒÂ©neau de saut retardÃƒÂ©)
        while dsp.delay is not None:
            dsp.step()
        n_before = len(out)
        if dsp.interrupt(1):
            guard = 0
            while dsp.imask and guard < 5000:
                if dsp.pc == mix_pc:
                    r = dsp.bank
                    chans.append((r[16], r[19], r[23], r[8]))
                dsp.step()
                guard += 1
            if guard >= 5000:
                sys.exit(f'ISR bloquÃƒÂ©e en ${dsp.pc:06X}')
        if i % int(RATE) == 0:
            print(f'  {t:.0f} s : {len(out)} ÃƒÂ©chantillons, pc ${dsp.pc:06X}', flush=True)
    samples = [struct.unpack('>h', struct.pack('>H', v & 0xFFFF))[0] for v in out]
    os.makedirs(PREVIEW, exist_ok=True)
    path = os.path.join(PREVIEW, 'dsp_replay.wav' if replay else f'dsp_stage{stage}.wav')
    with wave.open(path, 'wb') as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(int(RATE))
        w.writeframes(b''.join(struct.pack('<h', s) for s in samples))
    if samples:
        rms = (sum(s * s for s in samples) / len(samples)) ** 0.5
        print(f'{len(samples)} ÃƒÂ©chantillons, min {min(samples)} max {max(samples)} rms {rms:.0f} -> {path}')
    if replay:
        path = os.path.join(PREVIEW, 'dsp_replay_channels.txt')
        with open(path, 'w') as f:
            for k, c in enumerate(chans):
                f.write(f'{k / RATE:.5f} ' + ' '.join(str(x) for x in c) + '\n')
        print(f'voies -> {path}')
    params = [mem.r32(syms['dsp_params'] + 4 * k) for k in range(19)]
    print('dsp_params', [hex(p) for p in params])


if __name__ == '__main__':
    main()
