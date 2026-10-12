"""
Emplacement de la ROM NES d'origine (non fournie avec le projet).

Recherche, dans l'ordre : la variable d'environnement CRISIS_FORCE_ROM, puis
« Crisis Force (Japan) (En).nes » dans le dossier du projet et dans son dossier
parent. Le SHA-1 attendu est vérifié (avertissement seulement).
"""

import hashlib
import os
import sys

ROM_NAME = 'Crisis Force (Japan) (En).nes'
ROM_SHA1 = '91030a8ffc22be284eb6f8ebaec4ca9418871d96'
PROJECT_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def find_rom():
    """-> chemin de la ROM, ou None"""
    env = os.environ.get('CRISIS_FORCE_ROM')
    cands = [env] if env else []
    cands += [os.path.join(PROJECT_DIR, ROM_NAME), os.path.join(os.path.dirname(PROJECT_DIR), ROM_NAME)]
    for c in cands:
        if c and os.path.isfile(c):
            return c
    return None


def rom_path():
    """Chemin de la ROM (arrêt avec un message clair si elle est introuvable)"""
    p = find_rom()
    if p is None:
        sys.exit(f'ROM introuvable : placez « {ROM_NAME} » dans le dossier du projet ou son dossier '
                 f'parent, ou indiquez son chemin dans CRISIS_FORCE_ROM.')
    with open(p, 'rb') as f:
        sha1 = hashlib.sha1(f.read()).hexdigest()
    if sha1 != ROM_SHA1:
        print(f'attention : SHA-1 de la ROM {sha1}, attendu {ROM_SHA1}', file=sys.stderr)
    return p
