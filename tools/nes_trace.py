#!/usr/bin/env python3
"""
Couverture du code 6502 de Crisis Force, pour la recompilation statique.

ExÃ©cute la ROM (nes_probe.py) dans plusieurs scÃ©narios (Ã©cran titre et dÃ©mos,
chaque niveau avec un joueur invincible qui tire, change de forme et lance des
bombes, mort et continue) et relÃ¨ve :
  - chaque instruction exÃ©cutÃ©e : (banque, adresse) ;
  - les cibles des sauts indirects JMP ($xxxx) et des retours RTS/RTI qui
    ne reviennent pas juste aprÃ¨s leur JSR (tables de sauts) ;
  - les banques prÃ©sentes dans chaque fenÃªtre ($8000/$A000/$C000) lors des
    accÃ¨s en lecture aux donnÃ©es de la PRG-ROM ;
  - les cycles 6502 consommÃ©s par frame (estimation de charge).

Usage :
    python nes_trace.py <sortie.json> [scÃ©nario ...]
    scÃ©narios : title, stage1 ... stage7, death   (dÃ©faut : tous)

Les patchs (choix du niveau, invincibilitÃ©) ne servent qu'au traÃ§age.
"""

import json
import os
import sys
import time
from collections import defaultdict

from nes_probe import NES, BTN_A, BTN_B, BTN_START, BTN_SELECT, BTN_LEFT, BTN_RIGHT, BTN_UP, BTN_DOWN, boot, run_frames

STAGE_PATCH = 14 * 8192 + 0xB14     # LDA #$00 ; STA $59 (nouvelle partie) -> niveau de dÃ©part
PLAYER_HP = 0x6658                  # niveau de puissance / vie du joueur 1 (case 0)
LIVES = 0x68
STAGE = 0x59


class Tracer:
    def __init__(self):
        self.code = defaultdict(set)          # banque -> adresses exÃ©cutÃ©es
        self.indirect = defaultdict(set)      # (banque, pc) -> cibles
        self.data_banks = defaultdict(set)    # (banque, pc) -> (fenÃªtre, banque lue)
        self.frame_cycles = []

    def attach(self, nes, cpu):
        cls = type(cpu)
        orig_step = cls.step
        tracer = self
        state = {'pc': 0, 'bank': 0, 'op': 0}

        def step(self_cpu):
            pc = self_cpu.pc
            bank = nes.prg_bank_for((pc - 0x8000) >> 13) if pc >= 0x8000 else -1
            op = nes[pc] if pc >= 0x8000 else 0
            state['pc'], state['bank'], state['op'] = pc, bank, op
            tracer.code[bank].add(pc)
            r = orig_step(self_cpu)
            npc = self_cpu.pc
            # JMP (ind), RTS, RTI : on note la destination rÃ©elle
            if op in (0x6C, 0x60, 0x40):
                nb = nes.prg_bank_for((npc - 0x8000) >> 13) if npc >= 0x8000 else -1
                tracer.indirect[(bank, pc)].add((nb, npc))
            return r

        orig_get = NES.__getitem__

        def getitem(self_nes, addr):
            if addr >= 0x8000 and state['pc'] >= 0x8000:
                slot = (addr - 0x8000) >> 13
                pslot = (state['pc'] - 0x8000) >> 13
                # lecture de donnÃ©es hors de l'instruction en cours
                if not (state['pc'] <= addr < state['pc'] + 3):
                    tracer.data_banks[(state['bank'], state['pc'])].add((slot, self_nes.prg_bank_for(slot)))
            return orig_get(self_nes, addr)

        cls.step = step
        NES.__getitem__ = getitem
        self._restore = (cls, orig_step, orig_get)

    def detach(self):
        cls, orig_step, orig_get = self._restore
        cls.step = orig_step
        NES.__getitem__ = orig_get

    def to_json(self):
        return {
            'code': {str(b): sorted(v) for b, v in self.code.items()},
            'indirect': [[b, pc, sorted(t)] for (b, pc), t in self.indirect.items() if len(t) > 0],
            'data_banks': [[b, pc, sorted(t)] for (b, pc), t in self.data_banks.items()],
            'frame_cycles': self.frame_cycles,
        }

    def merge(self, other):
        for b, v in other.get('code', {}).items():
            self.code[int(b)].update(v)
        for b, pc, t in other.get('indirect', []):
            self.indirect[(b, pc)].update(tuple(x) for x in t)
        for b, pc, t in other.get('data_banks', []):
            self.data_banks[(b, pc)].update(tuple(x) for x in t)


def start_buttons(frame):
    return BTN_START if frame in (0, 1, 2, 3) else BTN_B if frame in (240, 241, 242, 243) else 0   # B valide (menu modifié)


def play_buttons(frame):
    """Tir continu, dÃ©placements, changement de forme, bombe de temps en temps"""
    if frame < 244:
        return start_buttons(frame)
    b = BTN_B if frame % 8 < 4 else 0
    phase = (frame // 100) % 4
    b |= (BTN_LEFT, BTN_UP, BTN_RIGHT, BTN_DOWN)[phase]
    if frame % 700 == 350:
        b |= BTN_A                    # changement de forme (tir relÃ¢chÃ©)
        b &= ~BTN_B
    if frame % 1500 == 1000:
        b |= BTN_A | BTN_B            # bombe : forme + tir
    return b


def run_scenario(name, tracer, max_frames):
    nes, cpu = boot()
    nes.prg = bytearray(nes.prg)
    keep_alive = False
    buttons = play_buttons
    target_stage = None
    if name.startswith('stage'):
        target_stage = int(name[5:]) - 1
        nes.prg[STAGE_PATCH] = target_stage
        keep_alive = True
    elif name == 'title':
        buttons = lambda f: 0          # Ã©cran titre puis dÃ©mos
    elif name == 'death':
        buttons = lambda f: start_buttons(f) if f < 244 else (BTN_START if f % 600 < 2 and f > 3000 else 0)
    elif name == 'fullgame':
        keep_alive = True                # partie complète : ennemis à 1 PV (boss vite vaincus)
    elif name == 'options':
        # écran OPTION : Select x2 + Start au titre ; chaque rubrique parcourue
        # (droite / gauche), chaque musique du sound test écoutée, sortie par EXIT
        seq = [(400, BTN_DOWN), (420, BTN_DOWN), (450, BTN_B)]     # menu titre : flèches + B
        f0 = 700
        for item in range(5):
            for k in range(12):                       # valeurs suivantes
                seq.append((f0, BTN_RIGHT))
                f0 += 120 if item == 2 else 20       # sound test : laisser jouer
            for k in range(12):
                seq.append((f0, BTN_LEFT))
                f0 += 20
            seq.append((f0, BTN_A)); f0 += 20
            seq.append((f0, BTN_B)); f0 += 20
            seq.append((f0, BTN_DOWN)); f0 += 30
        seq.append((f0, BTN_UP)); f0 += 30
        seq.append((f0, BTN_START)); f0 += 300        # EXIT -> titre
        seq += [(f0, BTN_DOWN), (f0 + 20, BTN_B)]         # 2 PLAYERS
        buttons = lambda f: sum(b for t, b in seq if t <= f < t + 6)

    t0 = time.time()
    tracer.attach(nes, cpu)
    st = {'cleared': None}

    def cb(frame):
        tracer.frame_cycles.append(cpu.processorCycles)
        if keep_alive and frame > 244:
            nes.ram[LIVES] = 3
            nes.wram[PLAYER_HP - 0x6000] = max(1, (frame // 900) % 4)
            if name == 'fullgame':
                # points de vie des ennemis (cases 32-57 de $6658) ramenés à 1
                for slot in range(32, 58):
                    if nes.wram[PLAYER_HP - 0x6000 + slot] > 1:
                        nes.wram[PLAYER_HP - 0x6000 + slot] = 1
        if name == 'fullgame' and frame % 2000 == 0:
            print(f'  fullgame : frame {frame}, niveau {nes.ram[STAGE]}', flush=True)
        if target_stage is not None and st['cleared'] is None and nes.ram[STAGE] == target_stage + 1:
            st['cleared'] = frame
            print(f'  {name}: niveau terminÃ© Ã  la frame {frame}', flush=True)
        if frame % 1000 == 0:
            print(f'  {name}: frame {frame}, niveau {nes.ram[STAGE]}, {time.time() - t0:.0f} s', flush=True)

    try:
        run_frames(nes, cpu, max_frames, buttons_fn=buttons, callback=cb)
    finally:
        tracer.detach()
    return st['cleared']


def main():
    out = sys.argv[1]
    names = sys.argv[2:] or ['title', 'death'] + [f'stage{i}' for i in range(1, 8)]
    tracer = Tracer()
    if os.path.exists(out):
        with open(out) as f:
            tracer.merge(json.load(f))
    for name in names:
        frames = {'title': 6000, 'death': 9000}.get(name, int(os.environ.get('TRACE_FRAMES', '24000')))
        cleared = run_scenario(name, tracer, frames)
        with open(out, 'w') as f:
            json.dump(tracer.to_json(), f)
        total = sum(len(v) for v in tracer.code.values())
        print(f'{name}: terminÃ© (fin de niveau : {cleared}), {total} instructions couvertes', flush=True)


if __name__ == '__main__':
    main()
