#!/usr/bin/env python3
"""
Mesure de vitesse dans JagMCP (émulateur fidèle au cycle près, tiré du cœur FPGA
MiSTer : contention du bus, attentes de la DRAM et des RISC reproduites ; MAME
ne les modélise pas).

La cartouche output/CrisisForce.j64 (par exemple un build --autotest --stage N)
démarre par le BIOS ; elle tourne par tranches d'images, et les compteurs du
programme sont lus entre deux tranches : VBL, images de jeu (NMI terminés),
images affichées, images en retard (VBL pendant le NMI), images sautées faute
de rendu GPU fini (B) ou de liste d'objets prête (L).

  python jagmcp_run.py [images] [tranche] [--shot=fichier.png] [--profile=N] [--gpuprofile=N]

--gpuprofile=N : de même pour le GPU (étiquettes de gpu.s).

--profile=N : profil du 68000 par échantillonnage (N échantillons après la
mesure) : une durée aléatoire, puis debug_trace (instructions récentes et cycle
de début de chacune) ; coût d'une instruction = début de la suivante - le sien,
cumulé par routine de la carte.

Variables : JAGMCP (jagmcp-cli.exe), JAG_BIOS (jagboot.rom).
"""

import bisect
import collections
import json
import os
import random
import re
import subprocess
import sys

PROJECT_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(PROJECT_DIR, 'output')
EXE = os.environ.get('JAGMCP', r'D:\source_codes\JagMCP-v0.1.2-windows-x64\jagmcp-cli.exe')
BIOS = os.environ.get('JAG_BIOS', r'D:\source_codes\convert_room\Wacky Races\tools\jagroms\jaguar\jagboot.rom')


class JagMCP:
    """Client du protocole de commande (lignes JSON sur stdio)"""

    def __init__(self, cart):
        self.p = subprocess.Popen([EXE, '--server', '--m68k', '--bios', BIOS, '--cart', cart],
                                  stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                  text=True, encoding='utf-8')
        self.n = 0

    def call(self, method, **params):
        self.n += 1
        self.p.stdin.write(json.dumps({'id': self.n, 'method': method, 'params': params}) + '\n')
        self.p.stdin.flush()
        while True:
            line = self.p.stdout.readline()
            if not line:
                raise RuntimeError('jagmcp-cli s\'est arrêté')
            r = json.loads(line)
            if r.get('id') == self.n:
                if not r.get('ok', True):
                    raise RuntimeError(f'{method} : {r}')
                return r.get('result')

    def read(self, addr, size):
        r = self.call('memory.read', address=addr, size=size)
        h = r['data_hex'] if isinstance(r, dict) and 'data_hex' in r else r.get('hex', r.get('data'))
        return bytes.fromhex(h)

    def u32(self, addr):
        return int.from_bytes(self.read(addr, 4), 'big')

    def close(self):
        self.p.stdin.close()
        self.p.terminate()


def symbols():
    syms = {}
    for line in open(os.path.join(OUT, 'CrisisForce.map'), errors='replace'):
        for name, addr in re.findall(r'(\S+)\s+[LG]\s+([0-9A-Fa-f]{8})', line):
            syms.setdefault(name, int(addr, 16))
    return syms


def counters(j, s):
    names = ('stat_nmi', 'stat_drawn', 'stat_lag', 'stat_gpubusy', 'stat_ldrop')
    c = {n: j.u32(s[n]) for n in names}
    c['vbl'] = j.u32(s['rt_vars'] + s['rt_frame'])
    return c


def profile(j, s, samples, cpu='m68k'):
    """Profil du 68000 (ou du GPU) : coût (en cycles à 26,59 MHz) par routine de la
    carte ; pour le GPU, par étiquette de gpu.s (le GPU au repos boucle dans gpu_wait /
    gpu_delay)"""
    if cpu == 'gpu':
        keys_all = sorted((a, n) for n, a in s.items() if 0xF03000 <= a < 0xF04000 and not n.startswith('.')
                          and not re.match(r'^[A-Z0-9_]+$', n))
    else:
        keys_all = sorted((a, n) for n, a in s.items()
                          if 0x4000 <= a < 0x200000 and not n.startswith('.') and not re.match(r'^[A-Z0-9_]+$', n))
    keys = [a for a, _ in keys_all]
    cost = collections.Counter()
    for _ in range(samples):
        j.call('emu.run_cycles', count=random.randint(20000, 400000))
        tr = j.call('debug.trace', cpu=cpu, count=1024)
        ins = tr['instructions'] if isinstance(tr, dict) and 'instructions' in tr else tr
        for a, b in zip(ins, ins[1:]):
            pc = a['address'] if 'address' in a else a['pc']
            c0 = a.get('cycle', a.get('began'))
            c1 = b.get('cycle', b.get('began'))
            i = bisect.bisect_right(keys, pc) - 1
            cost[keys_all[i][1] if i >= 0 else '?'] += c1 - c0
    tot = sum(cost.values())
    print(f'profil {cpu} : {samples} échantillons, {tot} cycles')
    for name, c in cost.most_common(30):
        print(f'  {100 * c / tot:5.1f} %  {name}')


def main():
    args = [a for a in sys.argv[1:] if not a.startswith('--')]
    frames = int(args[0]) if args else 1500
    chunk = int(args[1]) if len(args) > 1 else 300
    opt = dict(a[2:].split('=', 1) for a in sys.argv[1:] if a.startswith('--') and '=' in a)
    s = symbols()
    j = JagMCP(os.path.join(OUT, 'CrisisForce.j64'))
    done = 0
    prev = None
    print(' images |  VBL  jeu  aff. retard  B    L  | /s : jeu  affichées')
    while done < frames:
        j.call('emu.run_frames', count=chunk)
        done += chunk
        c = counters(j, s)
        if prev:
            d = {k: c[k] - prev[k] for k in c}
            v = max(1, d['vbl'])
            print(f'{done:6d}  | {d["vbl"]:4d} {d["stat_nmi"]:4d} {d["stat_drawn"]:4d} {d["stat_lag"]:5d} '
                  f'{d["stat_gpubusy"]:4d} {d["stat_ldrop"]:4d} | {60 * d["stat_nmi"] / v:6.1f} {60 * d["stat_drawn"] / v:6.1f}')
        prev = c
    if 'shot' in opt:
        j.call('video.screenshot', path=os.path.abspath(opt['shot']))
    if 'profile' in opt:
        profile(j, s, int(opt['profile']))
    if 'gpuprofile' in opt:
        profile(j, s, int(opt['gpuprofile']), 'gpu')
    j.close()


if __name__ == '__main__':
    main()
