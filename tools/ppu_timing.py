#!/usr/bin/env python3
"""
Code 6502 exécuté dans les gestionnaires d'IRQ (référence py65) : chronométrage
des écritures PPU / banques CHR.

Le jeu place ses changements de défilement et de banques CHR à une ligne
précise en attendant dans le gestionnaire d'IRQ (boucles d'attente, routines
appelées de plusieurs endroits). Le 68000 exécute ce code bien plus vite :
pour savoir à quelle ligne la PPU NES aurait vu chaque écriture, le code
recompilé compte les cycles 6502 des instructions exécutées en IRQ
(lea n(a3),a3, cf. tools/recomp6502.py et rt_ppu_time).

Ce script relève l'ensemble de ces instructions (intro sans entrée, puis
partie) dans assets/irq_code.json et vérifie l'approximation des cycles
utilisée par le recompilateur (cycles de base, +1 pour un branchement
arrière, supposé pris) contre le compte exact de py65 à chaque écriture.

Usage : python ppu_timing.py [frames]
"""

import json
import os
import statistics
import sys

import nes_probe as B

OUT = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), 'assets', 'irq_code.json')
LINE = B.CYCLES_PER_LINE


def approx_cycles(cpu, op, pc, nes):
    """Cycles comptés par le code recompilé pour une instruction (cf. recomp6502 : Gen.irq_cycles)"""
    c = cpu.cycletime[op]
    if op & 0x1F == 0x10 and nes[(pc + 1) & 0xFFFF] >= 0x80:     # branchement arrière
        c += 1
    return c


def run(frames, buttons, code, errs, counted=None):
    """Relève dans `code` les instructions exécutées en IRQ avant une écriture
    chronométrée (PPU, banque CHR, registres d'IRQ $F00x) : celles qui ne
    s'exécutent qu'après la dernière (son, logique du jeu) n'ont pas besoin
    d'être comptées. Si `counted` est donné, vérifie le compte approché limité
    à ces instructions (erreurs dans `errs`)."""
    nes, cpu = B.boot()
    cls = type(cpu)
    orig_step, orig_irq = cls.step, cls.irq
    orig_set = B.NES.__setitem__
    st = {'irq': None, 'approx': 0, 'pending': set()}

    def step(c):
        pc = c.pc
        if st['irq'] is not None and pc >= 0x8000:
            op = nes[pc]
            k = f'{nes.prg_bank_for((pc - 0x8000) >> 13)}:{pc:04X}'
            st['pending'].add(k)
            if counted is None or k in counted:
                st['approx'] += approx_cycles(c, op, pc, nes)
            r = orig_step(c)
            if op == 0x40:                    # RTI : fin du gestionnaire
                st['irq'] = None
            return r
        return orig_step(c)

    def irq(c):
        st['irq'] = c.processorCycles
        st['approx'] = 7
        st['pending'] = set()
        return orig_irq(c)

    def setitem(self, addr, val):
        if st['irq'] is not None and (addr in (0x2000, 0x2005, 0x2006) or addr >= 0xB000):
            code.update(st['pending'])
            st['pending'] = set()
            if addr < 0xF000:
                errs.append((cpu.processorCycles - st['irq']) - st['approx'])
        orig_set(self, addr, val)

    cls.step, cls.irq, B.NES.__setitem__ = step, irq, setitem
    try:
        B.run_frames(nes, cpu, frames, buttons_fn=buttons)
    finally:
        cls.step, cls.irq, B.NES.__setitem__ = orig_step, orig_irq, orig_set


def main():
    frames = int(sys.argv[1]) if len(sys.argv) > 1 else 4000
    play = lambda f: (B.BTN_START if f < 4 else B.BTN_B if 240 <= f < 244 else
                      (B.BTN_B if f % 8 < 4 else 0) | (B.BTN_LEFT if (f // 90) % 2 else B.BTN_RIGHT))
    code, errs = set(), []
    run(frames, lambda f: 0, code, errs)                              # intro et démos
    run(min(frames, 3000), play, code, errs)                          # partie
    with open(OUT, 'w') as f:
        json.dump(sorted(code), f, indent=0)
    # Vérification du compte limité à ces instructions
    errs = []
    run(frames, lambda f: 0, set(), errs, code)
    run(min(frames, 3000), play, set(), errs, code)
    # Erreur (cycles exacts - comptés) au moment des écritures : py65 compte
    # l'instruction d'écriture avant l'appel, comme le code recompilé
    print(f'{len(code)} instructions -> {OUT}')
    print(f'{len(errs)} écritures ; erreur en cycles : médiane {statistics.median(errs)}, '
          f'min {min(errs)}, max {max(errs)} ; en lignes : max {max(map(abs, errs)) / LINE:.2f}')


if __name__ == '__main__':
    main()
