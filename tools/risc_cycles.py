#!/usr/bin/env python3
"""
Estimation hors ligne des cycles du GPU (skill atari-jaguar-game-dev, « Pipeline,
wait states and interleaving ») : MAME et les autres émulateurs comptent une
instruction par cycle, la console non.

Le vrai code GPU (gpu.s) est exécuté par jrisc.py sur les images d'une partie
simulée (jag_sim.py, build --autotest) ; chaque instruction exécutée est relevée
avec ses registres et l'adresse de ses accès mémoire (externes : RAM principale,
ROM, registres de Tom ; internes : RAM GPU, registres GPU et blitter). La trace
est rejouée avec les règles de SoftRef V10 :

  - lire le résultat de l'instruction précédente (ALU, load interne) : +1 ;
  - utiliser les drapeaux posés par l'instruction précédente (jr/jump cc) : +1 ;
  - conflit du port d'écriture : l'instruction i écrit pendant que i+2 lit deux
    registres dont aucun n'est la cible de i : +1 ;
  - après un store indexé (r14/r15) : +1 ;
  - saut pris : +3 ;
  - lire un résultat de div trop tôt (16 cycles), un load externe trop tôt
    (--ext cycles, 10 par défaut) ; au plus 2 accès externes en attente.

Sortie : par étiquette de gpu.s, instructions exécutées, cycles estimés et cause
des attentes, pour choisir les boucles à réordonner.

Usage : python risc_cycles.py [images de chauffe] [images mesurées] [--ext=N]
"""

import bisect
import collections
import re
import sys

import jag_sim
from jrisc import JRisc

EXT = int(next((a.split('=')[1] for a in sys.argv if a.startswith('--ext=')), 10))
DIV_LAT = 16
STORE_EXT = 4

ALU2 = {0, 1, 4, 5, 9, 10, 11, 16, 17, 23, 26, 28}          # lisent r1 et r2, écrivent r2
ALU1 = {2, 3, 6, 7, 8, 12, 14, 15, 24, 25, 27, 29}          # lisent et écrivent r2
SETS_FLAGS = {0, 1, 2, 4, 5, 6, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 23, 24, 25, 26, 27, 28, 29, 30, 31}
LOADS = {39, 40, 41, 42, 43, 44, 58, 59}
STORES = {45, 46, 47, 48, 49, 50, 60, 61}
INDEXED_STORE = {49, 50, 60, 61}


def decode(op, r1, r2):
    """-> (registres lus, registre écrit, lit deux registres)"""
    if op in ALU2:
        return {r1, r2}, r2, True
    if op in ALU1:
        return {r2}, r2, False
    if op == 30:                                    # cmp
        return {r1, r2}, None, True
    if op in (13, 31):                              # btst, cmpq
        return {r2}, None, False
    if op == 21:                                    # div
        return {r1, r2}, r2, True
    if op in (34, 36, 37):                          # move, movefa, moveta
        return {r1}, r2, False
    if op in (35, 38, 51):                          # moveq, movei, move pc
        return set(), r2, False
    if op in (39, 40, 41, 42):
        return {r1}, r2, False
    if op in (43, 44):
        return {14 if op == 43 else 15}, r2, False
    if op in (58, 59):
        return {14 if op == 58 else 15, r1}, r2, True
    if op in (45, 46, 47, 48):
        return {r1, r2}, None, True
    if op in (49, 50):
        return {14 if op == 49 else 15, r2}, None, True
    if op in (60, 61):
        return {14 if op == 60 else 15, r1, r2}, None, True
    if op == 52:                                    # jump
        return {r1}, None, False
    return set(), None, False


def is_internal(a):
    a &= 0xFFFFFF
    return 0xF03000 <= a < 0xF04000 or 0xF02100 <= a < 0xF02300


def record(trace):
    """Remplace JRisc.step : relève (pc, op, r1, r2, accès externe ?, saut pris)"""
    orig = JRisc.step

    def step(self):
        pc = self.pc
        w = self.mem.r16(pc)
        op, r1, r2 = w >> 10, (w >> 5) & 31, w & 31
        reg = self.bank
        ext = None
        if op in (39, 40, 41, 42, 45, 46, 47, 48):
            ext = not is_internal(reg[r1])
        elif op in (43, 44, 49, 50):
            ext = not is_internal(reg[14 if op in (43, 49) else 15] + 4 * (r1 or 32))
        elif op in (58, 59, 60, 61):
            ext = not is_internal(reg[14 if op in (58, 60) else 15] + reg[r1])
        orig(self)
        taken = op in (52, 53) and self.delay is not None
        trace.append((pc, op, r1, r2, ext, taken))
    JRisc.step = step


def estimate(trace, label_of):
    stats = collections.defaultdict(lambda: collections.Counter())
    ready = [0] * 32
    flags_ready = 0
    t = 0                           # instant d'émission de l'instruction précédente
    hist = []                       # (registre écrit, est un load externe) des 2 dernières
    ext_pending = []                # fins des accès externes en cours
    pending_jump = False
    last_indexed_store = False
    for pc, op, r1, r2, ext, taken in trace:
        reads, dest, two = decode(op, r1, r2)
        lab = label_of(pc)
        st = stats[lab]
        issue = t + 1
        cause = collections.Counter()
        if pending_jump:
            issue += 3
            cause['saut pris'] += 3
            pending_jump = False
        if last_indexed_store:
            issue += 1
            cause['store indexé'] += 1
        # opérandes pas prêts
        need = max([ready[r] for r in reads] + [0])
        if need > issue:
            cause['opérande'] += need - issue
            issue = need
        # drapeaux de l'instruction précédente
        if op in (52, 53) and r2 != 0 and flags_ready > issue:
            cause['drapeaux'] += flags_ready - issue
            issue = flags_ready
        # port d'écriture : i-2 écrit pendant que celle-ci lit deux registres
        if two and len(hist) == 2 and hist[0] is not None and hist[0] not in reads:
            issue += 1
            cause['port'] += 1
        # interface mémoire : 2 accès externes au plus
        if ext:
            ext_pending = [e for e in ext_pending if e > issue]
            if len(ext_pending) >= 2:
                w = min(ext_pending) - issue
                cause['bus'] += w
                issue += w
        # résultat
        if dest is not None:
            if op in LOADS and ext:
                ready[dest] = issue + EXT
            elif op == 21:
                ready[dest] = issue + DIV_LAT
            else:
                ready[dest] = issue + 1     # lu par la suivante : 1 attente
        if ext:
            ext_pending.append(issue + (EXT if op in LOADS else STORE_EXT))
        if op in SETS_FLAGS:
            flags_ready = issue + 1
        hist = (hist + [dest])[-2:]
        last_indexed_store = op in INDEXED_STORE
        st['instructions'] += 1
        st['cycles'] += issue - t
        for k, v in cause.items():
            st[k] += v
        if taken:
            pending_jump = True     # appliqué après le créneau de délai
        t = issue
    return stats


def main():
    args = [a for a in sys.argv[1:] if not a.startswith('--')]
    warm = int(args[0]) if args else 300
    meas = int(args[1]) if len(args) > 1 else 30
    syms = jag_sim.symbols()
    labels = sorted((a, n) for n, a in syms.items()
                    if 0xF03000 <= a < 0xF04000 and re.match(r'^(gpu_|gsb_|gcr_)', n))
    keys = [a for a, _ in labels]

    def label_of(pc):
        i = bisect.bisect_right(keys, pc) - 1
        return labels[i][1] if i >= 0 else '?'

    sim = jag_sim.Sim(syms)
    sim.real_gpu = True
    for _ in range(warm):
        sim.step_frame()
    trace = []
    record(trace)
    for _ in range(meas):
        sim.step_frame()
    stats = estimate(trace, label_of)
    tot = collections.Counter()
    for s in stats.values():
        tot.update(s)
    idle = sum(stats[k]['cycles'] for k in ('gpu_wait', 'gpu_delay', 'gpu_start'))
    work_c = tot['cycles'] - idle
    work_i = tot['instructions'] - sum(stats[k]['instructions'] for k in ('gpu_wait', 'gpu_delay', 'gpu_start'))
    print(f'{meas} images : {work_i} instructions de rendu, {work_c} cycles estimés '
          f'({work_c / max(1, work_i):.2f} cycle/instruction ; ext = {EXT})')
    rows = sorted(((s['cycles'], k, s) for k, s in stats.items() if k not in ('gpu_wait', 'gpu_delay', 'gpu_start')),
                  reverse=True)
    print(f'{"étiquette":20s} {"instr.":>9s} {"cycles":>9s} {"c/i":>5s} {"%":>5s}  attentes')
    for c, k, s in rows[:25]:
        waits = ', '.join(f'{w} {s[w]}' for w in ('opérande', 'drapeaux', 'port', 'store indexé', 'saut pris', 'bus')
                          if s[w])
        print(f'{k:20s} {s["instructions"]:9d} {c:9d} {c / max(1, s["instructions"]):5.2f} '
              f'{100 * c / max(1, work_c):5.1f}  {waits}')


if __name__ == '__main__':
    main()
