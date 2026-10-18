#!/usr/bin/env python3
"""
Non-régression rapide sous MAME (sans affichage) : pour chaque niveau, build
--autotest --stage N, partie automatique de `images` images (BIOS compris), puis
compteurs du programme (erreur du runtime, exception 68000, images de jeu,
images affichées, VBL pendant le NMI, images sautées faute de rendu GPU / de
liste) et captures d'écran (une toutes les 120 images à partir de 900 : elles
doivent montrer une image, pas un écran uni).

MAME ne reproduit pas la contention du bus : pour la vitesse, voir
tools/jagmcp_run.py (JagMCP).

  python mame_stages.py [niveaux, ex. 1,2,5] [images] [--snaps=dossier]

--snaps : garde la dernière capture de chaque niveau (dossier/stageN.png).

Variables : MAME (mame.exe), MAME_ROMS (dossier des ROM du BIOS Jaguar).
"""

import os
import re
import shutil
import subprocess
import sys
import tempfile

PROJECT_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(PROJECT_DIR, 'output')
MAME = os.environ.get('MAME', r'D:\source_codes\convert_room\Wacky Races\tools\mame\mame.exe')
ROMS = os.environ.get('MAME_ROMS', r'D:\source_codes\convert_room\Wacky Races\tools\jagroms')

LUA = r'''
local mem = manager.machine.devices[":maincpu"].spaces["program"]
local f, n = 0, tonumber(os.getenv("CF_FRAMES"))
local S = {}
for k, v in string.gmatch(os.getenv("CF_SYMS"), "([%w_]+)=(%d+)") do S[k] = tonumber(v) end
emu.register_frame_done(function()
  f = f + 1
  if f >= 900 and f % 120 == 0 then manager.machine.video:snapshot() end
  if f == n then
    local out = io.open(os.getenv("CF_OUT"), "w")
    out:write(string.format("err=%d exc=%d nmi=%d drawn=%d lag=%d gpubusy=%d ldrop=%d vbl=%d\n",
      mem:read_u16(S.rt_vars + 58), mem:read_u16(S.exc_vec), mem:read_u32(S.stat_nmi),
      mem:read_u32(S.stat_drawn), mem:read_u32(S.stat_lag), mem:read_u32(S.stat_gpubusy),
      mem:read_u32(S.stat_ldrop), mem:read_u32(S.rt_vars + S.rt_frame)))
    out:close()
    manager.machine:exit()
  end
end)
'''


def symbols():
    syms = {}
    for line in open(os.path.join(OUT, 'CrisisForce.map'), errors='replace'):
        for name, addr in re.findall(r'(\S+)\s+[LG]\s+([0-9A-Fa-f]{8})', line):
            syms.setdefault(name, int(addr, 16))
    return syms


def uniform(png):
    from PIL import Image
    im = Image.open(png).convert('RGB').resize((64, 32))
    return len(im.getcolors(64 * 32)) <= 4


def run_stage(stage, frames, tmp, keep=None):
    r = subprocess.run([sys.executable, os.path.join(PROJECT_DIR, 'build.py'), '--autotest', '--stage', str(stage)],
                       capture_output=True, text=True, encoding='utf-8', errors='replace')
    if r.returncode != 0:
        return f'niveau {stage} : build échoué'
    s = symbols()
    need = ('rt_vars', 'rt_frame', 'exc_vec', 'stat_nmi', 'stat_drawn', 'stat_lag', 'stat_gpubusy', 'stat_ldrop')
    lua = os.path.join(tmp, 'probe.lua')
    open(lua, 'w').write(LUA)
    out = os.path.join(tmp, f'stage{stage}.txt')
    snaps = os.path.join(tmp, f'snap{stage}')
    env = dict(os.environ, CF_FRAMES=str(frames), CF_OUT=out,
               CF_SYMS=' '.join(f'{k}={s[k]}' for k in need))
    subprocess.run([MAME, 'jaguar', '-rompath', ROMS, '-cart', os.path.join(OUT, 'CrisisForce.j64'),
                    '-video', 'none', '-sound', 'none', '-skip_gameinfo', '-nothrottle',
                    '-seconds_to_run', str(frames // 50 + 30), '-snapshot_directory', snaps,
                    '-autoboot_script', lua], cwd=os.path.dirname(MAME), env=env,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    if not os.path.exists(out):
        return f'niveau {stage} : pas de résultat (MAME arrêté ?)'
    res = open(out).read().strip()
    pngs = [os.path.join(dp, f) for dp, _, fs in os.walk(snaps) for f in fs if f.endswith('.png')]
    blank = sum(1 for p in pngs if uniform(p))
    if keep and pngs:
        os.makedirs(keep, exist_ok=True)
        shutil.copy(sorted(pngs)[-1], os.path.join(keep, f'stage{stage}.png'))
    return f'niveau {stage} : {res} ; captures {len(pngs) - blank}/{len(pngs)} non unies'


def main():
    args = [a for a in sys.argv[1:] if not a.startswith('--')]
    stages = [int(x) for x in args[0].split(',')] if args else list(range(1, 8))
    frames = int(args[1]) if len(args) > 1 else 3000
    keep = next((a[8:] for a in sys.argv[1:] if a.startswith('--snaps=')), None)
    with tempfile.TemporaryDirectory() as tmp:
        for st in stages:
            print(run_stage(st, frames, tmp, keep), flush=True)


if __name__ == '__main__':
    main()
