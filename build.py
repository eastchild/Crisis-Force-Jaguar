#!/usr/bin/env python3
"""
Script de build pour Crisis Force sur Atari Jaguar
Utilise JagStudio (rmac, rln) pour assembler et linker
"""

import os
import sys
import subprocess
import shutil
from datetime import datetime

# JagStudio (rmac, rln, JAGUAR.INC, Univ.bin) : variable JAGSTUDIO = son dossier buildfiles
JS_PATH = os.environ.get('JAGSTUDIO', r'D:\source_codes\jagstudio\buildfiles')

# Chemins des outils
RMAC = os.path.join(JS_PATH, 'bin', 'rmac.exe')
RLN = os.path.join(JS_PATH, 'bin', 'rln.exe')
INC = os.path.join(JS_PATH, 'include')

# Chemins du projet
PROJECT_DIR = os.path.dirname(os.path.abspath(__file__))
SOURCE_DIR = os.path.join(PROJECT_DIR, 'source')
INCLUDE_DIR = os.path.join(PROJECT_DIR, 'include')
OUTPUT_DIR = os.path.join(PROJECT_DIR, 'output')
TOOLS_DIR = os.path.join(PROJECT_DIR, 'tools')

# Fichiers sources
# main.s inclut gpu.s (.gpu) et dsp.s (.dsp) : seul main.s est assemblé.
MAIN_SOURCE = os.path.join(SOURCE_DIR, 'main.s')
SOURCE_FILES = [
    MAIN_SOURCE,
    os.path.join(SOURCE_DIR, 'gpu.s'),
    os.path.join(SOURCE_DIR, 'dsp.s'),
    os.path.join(SOURCE_DIR, 'nes_runtime.s'),
]   # (source/nes_code.s est produit par tools/recomp6502.py : voir recompile())

# Options de build de test :
#   --autotest : partie lancée sans écran titre, tir et déplacements automatiques
#   --snddebug : le score affiche le nombre d'échantillons produits par le DSP / 256
DEFINES = [name for flag, name in (('--autotest', 'AUTOTEST'), ('--snddebug', 'SNDDEBUG'), ('--jagdebug', 'JAGDEBUG'), ('--noraster', 'NORASTER'), ('--perfhud', 'PERFHUD'), ('--noedgemask', 'NOEDGEMASK'), ('--pillarbox', 'PILLARBOX'), ('--diagol', 'DIAGOL'), ('--nodraw', 'NODRAW'), ('--norowsig', 'NOROWSIG'), ('--oldtile', 'OLDTILE'))
           if flag in sys.argv]
if 'NODRAW' in DEFINES and 'PERFHUD' not in DEFINES:
    DEFINES.append('PERFHUD')          # --nodraw : HUD de mesure inclus
#   --stage N : une nouvelle partie commence au niveau N (1-7), comme le patch
#               de tools/nes_trace.py (LDA #$00 en $CB13 -> LDA #N-1)
START_STAGE = int(sys.argv[sys.argv.index('--stage') + 1]) if '--stage' in sys.argv else None
STAGE_DIR = os.path.join(OUTPUT_DIR, 'stage')
if START_STAGE is not None:
    DEFINES.append('START_STAGE')


def write_stage_code():
    """Copie de nes_code.s avec le niveau de départ modifié"""
    with open(os.path.join(SOURCE_DIR, 'nes_code.s'), encoding='utf-8') as f:
        code = f.read()
    old = 'LECB13:\n    moveq   #0,d0\n'
    if old not in code:
        log('--stage : instruction $CB13 introuvable dans nes_code.s', error=True)
        return False
    os.makedirs(STAGE_DIR, exist_ok=True)
    with open(os.path.join(STAGE_DIR, 'nes_code_stage.s'), 'w', encoding='utf-8') as f:
        f.write(code.replace(old, f'LECB13:\n    moveq   #{START_STAGE - 1},d0\n'))
    log(f'Niveau de départ : {START_STAGE}')
    return True

# Adresse de chargement (comme les projets JagStudio)
LOAD_ADDRESS = '4000'

# Fichiers de sortie
OUTPUT_ROM = os.path.join(OUTPUT_DIR, 'CrisisForce.abs')   # Pour Virtual Jaguar / BigPEmu
OUTPUT_BIN = os.path.join(OUTPUT_DIR, 'CrisisForce.bin')   # Binaire brut chargé à $4000
OUTPUT_LST = os.path.join(OUTPUT_DIR, 'CrisisForce.lst')
OUTPUT_CART = os.path.join(OUTPUT_DIR, 'CrisisForce.j64')  # Cartouche (BigPEmu, cartouches flash)
CART_SIZE = 0x400000

# Fichier de log
LOG_FILE = os.path.join(OUTPUT_DIR, 'build.log')


def log(message, error=False):
    """Écrit un message dans le log"""
    timestamp = datetime.now().strftime('%Y-%m-%d %H:%M:%S')
    line = f'[{timestamp}] {message}'
    print(line)
    with open(LOG_FILE, 'a', encoding='utf-8') as f:
        f.write(line + '\n')
        if error:
            f.write('  ERROR!\n')


def check_dependencies():
    """Vérifie que tous les outils sont disponibles"""
    log('Vérification des dépendances...')
    
    errors = []
    
    # Vérifier les outils JagStudio
    if not os.path.exists(RMAC):
        errors.append(f'rmac non trouvé: {RMAC}')
    if not os.path.exists(RLN):
        errors.append(f'rln non trouvé: {RLN}')
    if not os.path.exists(INC):
        errors.append(f'include non trouvé: {INC}')
    
    # Vérifier les fichiers sources
    for src in SOURCE_FILES:
        if not os.path.exists(src):
            errors.append(f'Source non trouvé: {src}')
    
    if errors:
        for error in errors:
            log(error, error=True)
        return False
    
    log('Toutes les dépendances sont disponibles')
    return True


def create_output_dir():
    """Vide le répertoire de sortie (en gardant le log en cours)"""
    os.makedirs(OUTPUT_DIR, exist_ok=True)
    for name in os.listdir(OUTPUT_DIR):
        path = os.path.join(OUTPUT_DIR, name)
        if path == LOG_FILE:
            continue
        if os.path.isdir(path):
            shutil.rmtree(path)
        else:
            os.remove(path)
    log(f'Répertoire de sortie créé: {OUTPUT_DIR}')


def run_tool(cmd):
    """Lance un outil et journalise sa sortie (rmac/rln écrivent leurs erreurs sur stdout)"""
    result = subprocess.run(cmd, capture_output=True, text=True, errors='replace')
    output = (result.stdout + result.stderr).strip()
    if output:
        log(f'  {output}', error=result.returncode != 0)
    return result.returncode == 0


def assemble_files():
    """Assemble main.s (qui inclut le code GPU et DSP)"""
    log('Assemblage des fichiers...')

    base_name = os.path.splitext(os.path.basename(MAIN_SOURCE))[0]
    obj_file = os.path.join(OUTPUT_DIR, f'{base_name}.o')
    lst_file = os.path.join(OUTPUT_DIR, f'{base_name}.lst')

    # Commande d'assemblage (rmac : -i[path] collé, -o séparé)
    if START_STAGE is not None and not write_stage_code():
        return False
    cmd = [
        RMAC,
        '-fb',              # Objet BSD, à lier avec rln
    ] + [f'-d{name}' for name in DEFINES] + (
        [f'-i{STAGE_DIR}'] if START_STAGE is not None else []) + [
        f'-i{INC}',
        f'-i{INCLUDE_DIR}',
        f'-i{SOURCE_DIR}',  # gpu.s et dsp.s
        '-o', obj_file,
        f'-l*{lst_file}',
        MAIN_SOURCE
    ]

    log(f'Assemblage de {MAIN_SOURCE}...')
    if not run_tool(cmd) or not os.path.exists(obj_file):
        return False

    return [obj_file]


def link_files(obj_files):
    """Lie les fichiers objet : .abs (émulateurs) et binaire brut"""
    log('Linkage des fichiers...')

    # Mêmes options que build.bat de JagStudio
    cmd = [RLN, '-e', '-z', '-rq', '-m', '-o', OUTPUT_ROM,
           '-a', LOAD_ADDRESS, 'x', 'x'] + obj_files
    log(f'Linkage: {" ".join(cmd)}')
    if not run_tool(cmd) or not os.path.exists(OUTPUT_ROM):
        return False

    cmd = [RLN, '-z', '-rq', '-n', '-o', OUTPUT_BIN,
           '-a', LOAD_ADDRESS, 'x', 'x'] + obj_files
    if not (run_tool(cmd) and os.path.exists(OUTPUT_BIN)):
        return False
    # Carte des symboles (y compris locaux) pour tools/jag_sim.py
    result = subprocess.run([RLN, '-z', '-rq', '-n', '-l', '-m', '-o', os.path.join(OUTPUT_DIR, 'map_link.bin'),
                             '-a', LOAD_ADDRESS, 'x', 'x'] + obj_files, capture_output=True, text=True, errors='replace')
    with open(os.path.join(OUTPUT_DIR, 'CrisisForce.map'), 'w', encoding='utf-8') as f:
        f.write(result.stdout)
    return True


def convert_to_bin():
    """Le binaire brut est produit par rln (link_files)"""
    if os.path.exists(OUTPUT_BIN):
        log(f'Binaire brut: {OUTPUT_BIN}')
        return True
    return False


def make_cartridge():
    """Image de cartouche .j64 (4 Mo) : en-tête Univ.bin, amorçage en $802000
    (source/boot.s) qui recopie le programme rangé en $802100 vers $4000"""
    log('Création de la cartouche...')
    boot_obj = os.path.join(OUTPUT_DIR, 'boot.o')
    boot_bin = os.path.join(OUTPUT_DIR, 'boot.bin')
    if not run_tool([RMAC, '-fb', f'-i{INC}', '-o', boot_obj, os.path.join(SOURCE_DIR, 'boot.s')]):
        return False
    # Sans -rq : pas de bourrage, img_size reste dans les 4 derniers octets
    if not run_tool([RLN, '-z', '-n', '-a', '802000', 'x', 'x', '-o', boot_bin, boot_obj]):
        return False
    boot = bytearray(open(boot_bin, 'rb').read())
    # ... en dernier, après le « jmp $4000 » (4EF9 00004000) et le petit
    # programme GPU qui pointe OLP sur le STOP du démarrage
    jmp_end = boot.rfind(bytes.fromhex('4ef900004000')) + 6
    if jmp_end < 6 or len(boot) % 4 or boot[-4:] != b'\0\0\0\0':
        log(f'Cartouche : img_size introuvable à la fin de boot.bin ({boot[-8:].hex()})', error=True)
        return False
    img = open(OUTPUT_BIN, 'rb').read()
    if len(boot) > 0x100 or 0x2100 + len(img) > CART_SIZE:
        log(f'Cartouche : amorçage ({len(boot)}) ou programme ({len(img)}) trop grand', error=True)
        return False
    boot[-4:] = len(img).to_bytes(4, 'big')            # img_size
    univ = open(os.path.join(INC, 'Univ.bin'), 'rb').read()
    rom = bytearray(b'\xff' * CART_SIZE)
    rom[0:len(univ)] = univ
    rom[0x2000:0x2000 + len(boot)] = boot
    rom[0x2100:0x2100 + len(img)] = img
    with open(OUTPUT_CART, 'wb') as f:
        f.write(rom)
    log(f'Cartouche: {OUTPUT_CART} (programme {len(img)} octets)')
    return True


def generate_symbols():
    """Génère un fichier de symboles"""
    log('Génération du fichier de symboles...')
    
    # Le listing de main.s contient aussi le code GPU/DSP inclus
    symbol_file = os.path.join(OUTPUT_DIR, 'CrisisForce.sym')
    lst_file = os.path.join(OUTPUT_DIR, 'main.lst')
    if os.path.exists(lst_file):
        shutil.copy2(lst_file, symbol_file)
    
    log(f'Fichier de symboles généré: {symbol_file}')
    return True


def get_rom_size():
    """Affiche la taille de la ROM"""
    if os.path.exists(OUTPUT_ROM):
        size = os.path.getsize(OUTPUT_ROM)
        log(f'Taille de la ROM: {size} octets ({size/1024:.2f} KB)')
        return size
    return 0


def clean():
    """Nettoie les fichiers temporaires"""
    log('Nettoyage des fichiers temporaires...')
    
    # Supprimer les fichiers .o et .lst
    for file in os.listdir(OUTPUT_DIR):
        if file.endswith('.o') or file.endswith('.lst'):
            os.remove(os.path.join(OUTPUT_DIR, file))
            log(f'  Supprimé: {file}')


def generated_files():
    """Fichiers produits par tools/recomp6502.py à partir de la ROM (non versionnés)"""
    return [os.path.join(SOURCE_DIR, 'nes_code.s'),
            os.path.join(INCLUDE_DIR, 'nes', 'prg.bin'),
            os.path.join(INCLUDE_DIR, 'nes', 'chr.bin')]


def recompile():
    """Recompilation du code 6502 de la ROM (tools/recomp6502.py) : nes_code.s, prg.bin,
    chr.bin. Faite si l'un d'eux manque, ou avec --recomp."""
    if '--recomp' not in sys.argv and all(os.path.exists(f) for f in generated_files()):
        return True
    log('Recompilation du code 6502 (tools/recomp6502.py)...')
    result = subprocess.run([sys.executable, os.path.join(TOOLS_DIR, 'recomp6502.py')],
                            capture_output=True, text=True, encoding='utf-8', errors='replace')
    out = (result.stdout + result.stderr).strip().splitlines()
    for line in out[:3]:
        log(line, error=result.returncode != 0)
    if result.returncode != 0:
        for line in out[3:]:
            log(line, error=True)
    return result.returncode == 0 and all(os.path.exists(f) for f in generated_files())


def check_hw_rules():
    """Règle 1 du matériel : le 68000 n'accède à la RAM / aux registres GPU-DSP
    qu'en move.l (tools/check_hw_rules.py, désassemblage capstone)"""
    result = subprocess.run([sys.executable, os.path.join(PROJECT_DIR, 'tools', 'check_hw_rules.py'), OUTPUT_DIR],
                            capture_output=True, text=True, encoding='utf-8', errors='replace')
    for line in result.stdout.splitlines():
        log(line, error=result.returncode != 0)
    return result.returncode == 0


def main():
    """Fonction principale de build"""
    print("=" * 60)
    print("Crisis Force - Build pour Atari Jaguar")
    print("=" * 60)
    print()
    
    # Initialiser le log
    os.makedirs(OUTPUT_DIR, exist_ok=True)
    with open(LOG_FILE, 'w', encoding='utf-8') as f:
        f.write(f'Crisis Force Build Log - {datetime.now()}\n')
        f.write('=' * 60 + '\n\n')
    
    # Vérifier les dépendances
    if not check_dependencies():
        log('Build annulé: dépendances manquantes', error=True)
        return False
    
    # Créer le répertoire de sortie
    create_output_dir()

    # Code 6502 recompilé et données de la ROM (générés, non versionnés)
    if not recompile():
        log('Build échoué: recompilation impossible (ROM introuvable ?)', error=True)
        return False
    
    # Assembler
    obj_files = assemble_files()
    if not obj_files:
        log('Build échoué: erreur d\'assemblage', error=True)
        return False
    
    # Linker
    if not link_files(obj_files):
        log('Build échoué: erreur de linkage', error=True)
        return False
    
    # Convertir
    if not convert_to_bin():
        log('Build échoué: erreur de conversion', error=True)
        return False

    if not make_cartridge():
        log('Build échoué: erreur de création de la cartouche', error=True)
        return False

    if not check_hw_rules():
        log('Build échoué: accès 68000 non conforme à la RAM / aux registres GPU-DSP', error=True)
        return False

    # Générer les symboles
    generate_symbols()
    
    # Afficher la taille
    get_rom_size()
    
    # Nettoyer
    clean()
    
    log('Build terminé avec succès!')
    print()
    print("=" * 60)
    print("Build terminé!")
    print(f"ROM générée: {OUTPUT_ROM}")
    print(f"Taille: {get_rom_size()/1024:.2f} KB")
    print("=" * 60)
    
    return True


if __name__ == '__main__':
    success = main()
    sys.exit(0 if success else 1)
