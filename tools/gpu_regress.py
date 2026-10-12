#!/usr/bin/env python3
"""
Régression bit à bit du rendu GPU (skill : « verify each rescheduled routine with
a bit-exact output comparison »).

Le vrai code GPU (gpu.s) tourne dans jag_sim.py (build --autotest) ; après chaque
rendu, l'empreinte SHA-1 des tampons vidéo (plans du décor et 4 calques de
sprites, de vid_start à vid_end) est écrite, une ligne par image. Deux builds
dont le GPU doit dessiner la même chose donnent des fichiers identiques
(le rendu est fait d'un bloc à la VBL : il ne dépend pas de la vitesse du GPU).

Usage : python gpu_regress.py images sortie.txt
        python gpu_regress.py --cmp ref.txt nouveau.txt
"""

import hashlib
import sys

import jag_sim


def run(frames, out):
    syms = jag_sim.symbols()
    sim = jag_sim.Sim(syms)
    sim.real_gpu = True
    lo, hi = syms['vid_start'], syms['vid_end']
    last = 0
    with open(out, 'w') as f:
        for n in range(frames):
            sim.step_frame()
            steps = sim.gpu.steps if hasattr(sim, 'gpu') else 0
            if steps != last:
                last = steps
                h = hashlib.sha1(bytes(sim.uc.mem_read(lo, hi - lo))).hexdigest()
                f.write(f'{n} {h}\n')
    print(f'{frames} images -> {out}')


def compare(a, b):
    la = open(a).read().split('\n')
    lb = open(b).read().split('\n')
    diff = [(x, y) for x, y in zip(la, lb) if x != y]
    print(f'{len(la) - 1} / {len(lb) - 1} rendus, {len(diff)} différence(s)')
    for x, y in diff[:5]:
        print('  ', x, '|', y)
    return 1 if diff or len(la) != len(lb) else 0


if __name__ == '__main__':
    if sys.argv[1] == '--cmp':
        sys.exit(compare(sys.argv[2], sys.argv[3]))
    run(int(sys.argv[1]), sys.argv[2])
