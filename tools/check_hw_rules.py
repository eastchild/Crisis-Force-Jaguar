#!/usr/bin/env python3
"""
Contrôle mécanique des règles matérielles Jaguar (skill atari-jaguar-game-dev,
« Real hardware rules » 1, 2 et 9, et bogues GPU/DSP documentés par Atari).
Les émulateurs acceptent tout cela ; la console non.

68000 (image liée output/CrisisForce.bin chargée en $4000, hors blocs RISC et
données, et amorce output/boot.bin jusqu'au « jmp $4000 ») : tout accès à
$F02000-$F07FFF / $F1A000-$F1FFFF (RAM et registres GPU / DSP / blitter) doit
être un move.l : ni .w / .b, ni tst / cmp / or..., ni clr, ni écriture en
-(an). Adresses absolues, et registres d'adresse chargés par lea / movea.l
d'une constante (suivis jusqu'au prochain saut).

GPU / DSP (sources gpu.s, dsp.s ; valeurs des symboles lues dans la carte) :
  - règle 2 : pas de loadb / loadw / storeb / storew sur la RAM locale ;
  - pas de saut, de movei ni de move pc dans le créneau de délai d'un saut ;
  - store indexé (r14 / r15) d'un résultat de load / div pas encore lu : or rN,rN ;
  - instruction en écriture seule (move*, load*) sur un registre dont un load /
    div est en attente, ou que l'instruction précédente écrit ;
  - div qui lit le quotient d'un div précédent pas encore lu ;
  - store dans G_FLAGS / D_FLAGS hors créneau de délai sans 2 nop derrière.
L'analyse RISC est linéaire (registres connus suivis le long du source) :
une alerte se relit à la main.

Usage : python check_hw_rules.py [dossier output]   -> code 1 si une faute
"""

import bisect
import os
import re
import sys

PROJECT_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SOURCE_DIR = os.path.join(PROJECT_DIR, 'source')
RANGES = ((0xF02000, 0xF08000), (0xF1A000, 0xF20000))
LOCAL_RAM = {'gpu.s': (0xF03000, 0xF04000), 'dsp.s': (0xF1B000, 0xF1D000)}
FLAGS_REGS = {0xF02100, 0xF1A100}
ABS = re.compile(r'(?<![#\w])\$([0-9a-f]+)(?:\.[wl])?(?!\s*\()', re.I)
FLOW = re.compile(r'^(b[a-z]{2}|bra|bsr|db[a-z]+|jmp|jsr|rts|rte|rtr|trap)(\.|$)')


def load_map(path):
    syms = {}
    for line in open(path, errors='replace'):
        for name, addr in re.findall(r'(\S+)\s+[LG]\s+([0-9A-Fa-f]{8})', line):
            syms.setdefault(name, int(addr, 16))
    return syms


def in_ranges(a):
    return a is not None and any(lo <= a < hi for lo, hi in RANGES)


# --------------------------------------------------------------------------
# 68000
# --------------------------------------------------------------------------

def check_68k(code, base, start, end, near, stop_at_jmp=False):
    """-> fautes [(adresse, texte, où)] dans [start, end)"""
    from capstone import Cs, CS_ARCH_M68K, CS_MODE_M68K_000
    cs = Cs(CS_ARCH_M68K, CS_MODE_M68K_000)
    cs.skipdata = True                       # données au milieu du code : on continue
    faults = []
    known = {}                               # aN -> adresse constante (lea / movea.l #)
    for ins in cs.disasm(code[start - base:end - base], start):
        mn = ins.mnemonic.lower()
        ops = ins.op_str.lower()
        if mn.startswith('.'):
            known.clear()
            continue
        why = None
        size_l = mn.endswith('.l') or mn.split('.')[0] in ('lea', 'pea')
        move_l = mn in ('move.l', 'movea.l', 'movem.l')
        # adresses absolues
        if any(in_ranges(int(m.group(1), 16)) for m in ABS.finditer(ops)):
            if mn.split('.')[0] in ('lea', 'pea'):
                pass
            elif not move_l:
                why = 'pas un move.l'
        # registres d'adresse pointant sur la zone
        for r, a in list(known.items()):
            if not in_ranges(a) or r not in ops:
                continue
            dst = ops.rsplit(',', 1)[-1] if ',' in ops else ops
            uses = re.search(rf'\({r}\)|\({r},|-\({r}\)', ops)
            if not uses:
                continue
            if f'-({r})' in dst and ',' in ops:
                why = f'écriture en -({r})'
            elif mn.startswith('clr'):
                why = 'clr'
            elif not move_l:
                why = 'pas un move.l' if size_l else 'accès .w/.b'
        if why:
            faults.append((ins.address, f'{mn} {ins.op_str} ({why})', near(ins.address)))
        # suivi des registres d'adresse
        m = re.match(r'^\$([0-9a-f]+)(?:\.[wl])?, (a[0-7])$', ops)
        if mn.split('.')[0] == 'lea' and m:
            known[m.group(2)] = int(m.group(1), 16)
        elif mn == 'movea.l' and re.match(r'^#\$[0-9a-f]+, a[0-7]$', ops):
            v, r = ops.split(', ')
            known[r] = int(v[2:], 16)
        else:
            d = re.search(r', (a[0-7])$', ops)
            if d:
                known.pop(d.group(1), None)
        if FLOW.match(mn):
            known.clear()
            if stop_at_jmp and mn == 'jmp':
                break
    return faults


# --------------------------------------------------------------------------
# GPU / DSP
# --------------------------------------------------------------------------

WRITE_ONLY = {'move', 'movei', 'moveq', 'movefa', 'moveta', 'load', 'loadb', 'loadw', 'loadp', 'resmac',
              'mtoi', 'normi'}
NO_DEST = {'store', 'storeb', 'storew', 'storep', 'cmp', 'cmpq', 'btst', 'jump', 'jr', 'nop'}
LONG_LAT = {'load', 'loadb', 'loadw', 'loadp', 'div'}


def eval_expr(expr, syms):
    """Expression rmac simple (gauche à droite : sym, $hex, décimal, + - << >> | &)"""
    toks = re.findall(r'\$[0-9A-Fa-f]+|\d+|[A-Za-z_.][\w.]*|<<|>>|[-+|&]', expr)
    if not toks:
        return None
    val, op = None, '+'
    for t in toks:
        if t in ('+', '-', '<<', '>>', '|', '&'):
            op = t
            continue
        if t.startswith('$'):
            v = int(t[1:], 16)
        elif t.isdigit():
            v = int(t)
        elif t in syms:
            v = syms[t]
        else:
            return None
        if val is None:
            val = v
        else:
            val = {'+': val + v, '-': val - v, '<<': val << v, '>>': val >> v, '|': val | v,
                   '&': val & v}[op]
    return val & 0xFFFFFFFF if val is not None else None


def parse_risc(path):
    out = []
    for no, line in enumerate(open(path, encoding='utf-8', errors='replace'), 1):
        code = line.split(';', 1)[0].rstrip()
        if not code.strip():
            continue
        m = re.match(r'^([A-Za-z_.][\w.]*):', code)
        if m:
            out.append((no, 'label', [], code))
            code = code[m.end():]
            if not code.strip():
                continue
        parts = code.split(None, 1)
        mn = parts[0].lower()
        if mn.startswith('.') or mn in ('dc.l', 'dc.w', 'dc.b', 'dcb.l', 'dcb.w', 'dcb.b', 'ds.l', 'ds.b'):
            out.append((no, 'label', [], code))           # données : coupe l'analyse
            continue
        args = [a.strip() for a in parts[1].split(',')] if len(parts) > 1 else []
        out.append((no, mn, args, code.strip()))
    return out


def regs_in(arg):
    return [int(r) for r in re.findall(r'\br(\d+)\b', arg)]


def check_risc(fname, syms):
    path = os.path.join(SOURCE_DIR, fname)
    lo, hi = LOCAL_RAM[fname]
    faults = []
    insns = parse_risc(path)
    known = {}                      # registre -> valeur constante
    pending = {}                    # registre -> (mnémonique, ligne) d'un load / div pas encore lu
    prev_dest = None
    in_delay = uncond = clear_next = False
    for k, (no, mn, args, text) in enumerate(insns):
        if mn == 'label':
            pending.clear()
            prev_dest = None
            in_delay = False
            continue
        if clear_next:
            pending.clear()             # après un saut pris (appel...) : la suite vient plus tard
            clear_next = False
        delay_slot = in_delay
        clear_next = delay_slot and uncond
        in_delay = mn in ('jump', 'jr')
        uncond = in_delay and args and args[0].lower() == 't'
        if delay_slot and (mn in ('jump', 'jr', 'movei') or (mn == 'move' and args and args[0].lower() == 'pc')):
            faults.append((fname, no, text, 'saut / movei / move pc dans un créneau de délai'))
        # registres lus / écrit
        dest = None
        reads = []
        if mn in ('store', 'storeb', 'storew', 'storep'):
            reads = regs_in(args[0]) + regs_in(args[1]) if len(args) > 1 else []
        elif mn in ('jump', 'jr'):
            reads = regs_in(args[-1]) if args else []
        elif mn in ('cmp', 'btst', 'cmpq'):
            for a in args:
                reads += regs_in(a)
        elif args:
            d = regs_in(args[-1])
            dest = d[0] if d and re.fullmatch(r'r\d+', args[-1].lower()) else None
            for a in args[:-1]:
                reads += regs_in(a)
            if mn not in WRITE_ONLY and dest is not None:
                reads.append(dest)
            if mn.startswith('load') or mn == 'move' and args[0].lower() == 'pc':
                pass
        # bogue du scoreboard : store indexé d'un résultat long pas encore lu
        if mn == 'store' and len(args) > 1 and re.match(r'\(r1[45]\+', args[1].lower()):
            for r in regs_in(args[0]):
                if r in pending:
                    faults.append((fname, no, text, f'store indexé de r{r} ({pending[r][0]} ligne '
                                   f'{pending[r][1]} pas encore lu) : or r{r},r{r} avant'))
        if mn == 'div':
            for r in regs_in(args[0]) + regs_in(args[1] if len(args) > 1 else ''):
                if r in pending and pending[r][0] == 'div':
                    faults.append((fname, no, text, f'div lisant le quotient r{r} d\'un div récent : or r{r},r{r} avant'))
        # écriture seule qui double un load / div en attente ou l'instruction précédente
        if mn in WRITE_ONLY and dest is not None:
            if dest in pending and dest not in reads:
                faults.append((fname, no, text, f'écriture seule de r{dest} pendant un {pending[dest][0]} '
                               f'(ligne {pending[dest][1]}) : or r{dest},r{dest} avant'))
            elif prev_dest == dest and not delay_slot and dest not in reads:
                faults.append((fname, no, text, f'écriture seule de r{dest} juste après une autre écriture de r{dest}'))
        for r in reads:
            pending.pop(r, None)
        # règle 2 : octet / mot sur la RAM locale
        if mn in ('loadb', 'loadw', 'storeb', 'storew'):
            addr_arg = args[0] if mn.startswith('load') else (args[1] if len(args) > 1 else '')
            for r in regs_in(addr_arg):
                v = known.get(r)
                if v is not None and lo <= v < hi:
                    faults.append((fname, no, text, f'{mn} sur la RAM locale (r{r} = ${v:06X})'))
        # G_FLAGS / D_FLAGS : 2 nop après un store (hors créneau de délai)
        if mn == 'store' and len(args) > 1 and not delay_slot:
            for r in regs_in(args[1]):
                if known.get(r) in FLAGS_REGS:
                    nxt = [x[1] for x in insns[k + 1:k + 3]]
                    if nxt != ['nop', 'nop']:
                        faults.append((fname, no, text, 'store dans FLAGS sans 2 nop derrière'))
        # suivi des valeurs connues et des résultats longs
        if dest is not None:
            if mn == 'movei':
                known[dest] = eval_expr(args[0].lstrip('#'), syms)
            elif mn == 'moveq':
                known[dest] = eval_expr(args[0].lstrip('#'), syms)
            elif mn == 'move' and args[0].lower() != 'pc':
                s = regs_in(args[0])
                known[dest] = known.get(s[0]) if s else None
            elif mn in ('addq', 'addqt') and known.get(dest) is not None:
                known[dest] = (known[dest] + (eval_expr(args[0].lstrip('#'), syms) or 0)) & 0xFFFFFFFF
            else:
                known[dest] = None
            if mn in LONG_LAT:
                pending[dest] = (mn, no)
            else:
                pending.pop(dest, None)
        prev_dest = dest if mn in WRITE_ONLY or dest is not None else None
        if mn in ('jump', 'jr'):
            prev_dest = None
    return faults


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else os.path.join(PROJECT_DIR, 'output')
    syms = load_map(os.path.join(out, 'CrisisForce.map'))
    faults = []
    try:
        import capstone  # noqa: F401
        have_cs = True
    except ImportError:
        have_cs = False
        print('check_hw_rules : capstone absent (pip install capstone), contrôle 68000 sauté')
    if have_cs:
        addrs = sorted((a, n) for n, a in syms.items() if not n.startswith('.'))
        keys = [a for a, _ in addrs]

        def near(a):
            i = bisect.bisect_right(keys, a) - 1
            return f'{addrs[i][1]}+${a - addrs[i][0]:X}' if i >= 0 else '?'

        image = open(os.path.join(out, 'CrisisForce.bin'), 'rb').read()
        for lo, hi in ((syms['Start'], syms['SetOlpCode']), (syms['DSPCodeEnd'], syms['_TEXT_E'])):
            faults += check_68k(image, 0x4000, lo, hi, near)
        boot = os.path.join(out, 'boot.bin')
        if os.path.exists(boot):
            b = open(boot, 'rb').read()
            faults += check_68k(b, 0x802000, 0x802000, 0x802000 + len(b), lambda a: 'boot', stop_at_jmp=True)
    for a, text, where in faults:
        print(f'  68000 ${a:06X} ({where}) : {text}')
    risc = []
    for f in ('gpu.s', 'dsp.s'):
        risc += check_risc(f, syms)
    for f, no, text, why in risc:
        print(f'  {f}:{no} : {text}  <- {why}')
    print(f'check_hw_rules : {len(faults)} faute(s) 68000, {len(risc)} faute(s) GPU/DSP')
    return 1 if faults or risc else 0


if __name__ == '__main__':
    sys.exit(main())
