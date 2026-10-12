"""
Modifications de la ROM NES pour le portage Jaguar, appliquées par
tools/recomp6502.py (code recompilé) et tools/nes_probe.py (émulateur de
référence des tests), pour que les deux restent identiques.

Menu titre (banque 9) : le jeu d'origine ne déplace le curseur ($29 : 0 = 1
PLAYER, 1 = 2 PLAYERS, 2 = OPTION) qu'avec SELECT, toujours vers le bas, et
valide avec START. Nouvelle boucle :
  - Bas  : curseur + 1 (en boucle), Haut : curseur - 1 (en boucle), avec le
    son et l'appel $C708 d'origine ;
  - B valide (code de validation d'origine, $BF14) ;
  - SELECT et START sont sans effet.
$F8 = boutons nouvellement appuyés : A $80, B $40, SELECT $20, START $10,
HAUT $08, BAS $04, GAUCHE $02, DROITE $01.
L'ancienne gestion ($BEF5) saute vers la nouvelle, placée dans l'espace
libre de la banque 9 ($BF51-$BFFF, octets $FF jamais exécutés ni lus).
"""

MENU_BANK = 9
MENU_HOOK = 0xBEF5        # LDA $F8 / AND #$20 ... (gestion SELECT / START)
MENU_NEW = 0xBF51         # espace libre
MENU_VALIDATE = 0xBF14    # validation d'origine (son $71, $21 + 1...)
MENU_NONE = 0xBEB7        # sortie sans validation (cible d'origine du BEQ)


def _menu_code():
    """Assemble la nouvelle boucle à MENU_NEW (sauts relatifs calculés)"""
    code = bytearray()
    labels, fixups = {}, []

    def emit(*b):
        code.extend(b)

    def br(op, lab):                 # branchement relatif vers une étiquette
        emit(op, 0)
        fixups.append((len(code) - 1, lab))

    def label(name):
        labels[name] = len(code)

    def jmp(addr):
        emit(0x4C, addr & 0xFF, addr >> 8)

    emit(0xA5, 0xF8)                 # LDA $F8
    emit(0x29, 0x0C)                 # AND #HAUT|BAS
    br(0xF0, 'chk_b')                # BEQ chk_b
    emit(0x48)                       # PHA
    emit(0xA9, 0x70)                 # LDA #$70 (son du curseur)
    emit(0x20, 0x14, 0xF1)           # JSR $F114
    emit(0x20, 0x08, 0xC7)           # JSR $C708
    emit(0x68)                       # PLA
    emit(0x29, 0x04)                 # AND #BAS
    br(0xF0, 'up')                   # BEQ up
    emit(0xE6, 0x29)                 # INC $29
    emit(0xA5, 0x29)                 # LDA $29
    emit(0xC9, 0x03)                 # CMP #3
    br(0x90, 'chk_b')                # BCC chk_b
    emit(0xA9, 0x00)                 # LDA #0
    emit(0x85, 0x29)                 # STA $29
    br(0xF0, 'chk_b')                # BEQ chk_b (toujours : A = 0)
    label('up')
    emit(0xC6, 0x29)                 # DEC $29
    br(0x10, 'chk_b')                # BPL chk_b
    emit(0xA9, 0x02)                 # LDA #2
    emit(0x85, 0x29)                 # STA $29
    label('chk_b')
    emit(0xA5, 0xF8)                 # LDA $F8
    emit(0x29, 0x40)                 # AND #B
    br(0xF0, 'none')                 # BEQ none
    jmp(MENU_VALIDATE)               # JMP $BF14
    label('none')
    jmp(MENU_NONE)                   # JMP $BEB7
    for pos, lab in fixups:
        rel = labels[lab] - (pos + 1)
        assert -128 <= rel <= 127
        code[pos] = rel & 0xFF
    return bytes(code)


# ---------------------------------------------------------------------------
# Commandes à 3 boutons (manette Jaguar) : A = transformation (A NES), B = tir
# (B NES), C = bombe. main.s envoie C comme SELECT, inutilisé en jeu par la
# ROM d'origine (vérifié). Le jeu d'origine lance la bombe quand on appuie
# sur la transformation en tenant le tir : supprimé, la transformation a
# toujours lieu et seul SELECT (C) lance la bombe.
# Entrées du joueur X (banque 0, $8439) : $41,X = nouveaux appuis, $43,X =
# boutons tenus, $39 / $3A = masques transformation / tir (ligne KEY).
# Nouvelle routine dans l'espace libre de la banque fixe 14 ($C000).
# ---------------------------------------------------------------------------
INPUT_BANK = 0
INPUT_HOOK = 0x8439       # LDA $41,X / AND $39 / BEQ $845F
INPUT_NEW = 0xC000        # banque 14, 64 octets $FF jamais exécutés
BOMB = 0x8468             # LDA #0 / STA $04F1,X / JMP $85FE (bombe d'origine)
CHANGE = 0x8445           # transformation d'origine
SHOT = 0x845F             # suite : tir


def _input_code():
    return bytes([
        0xB5, 0x41,                         # LDA $41,X
        0x29, 0x20,                         # AND #SELECT (Jaguar C)
        0xF0, 0x03,                         # BEQ +3
        0x4C, BOMB & 0xFF, BOMB >> 8,       # JMP bombe
        0xB5, 0x41,                         # LDA $41,X
        0x25, 0x39,                         # AND $39 (transformation)
        0xD0, 0x03,                         # BNE +3
        0x4C, SHOT & 0xFF, SHOT >> 8,       # JMP tir
        0x4C, CHANGE & 0xFF, CHANGE >> 8,   # JMP transformation (même tir tenu)
    ])


# Écran OPTION, ligne KEY (banque 7) : choix parmi les 6 attributions des 3
# fonctions (transformation, tir, bombe) aux 3 boutons A, B, C.
#  - Gauche / Droite sur la ligne KEY écrit les boutons dans le registre fictif
#    $5FFF : le runtime (nes_runtime.s, rt_wr_keycfg ; ici key_hook) fait
#    tourner l'indice (WRAM $7F00, 0-5) et réécrit les 3 lettres du texte
#    (WRAM $7F10), puis le jeu réaffiche la chaîne. main.s convertit les
#    boutons Jaguar selon l'indice (key_map).
#  - Les deux chaînes KEY pointent vers ce texte en WRAM ($7F00-$7FFF n'est
#    jamais utilisé par le jeu).
#  - KEY passe en rangée 17 (« x CHANGE  y SHOT ») et 19 (« z BOMB ») : les deux
#    lignes sont dans le bloc d'attributs de KEY (rangées 16-19), qui passe en
#    blanc quand la ligne est choisie.
# Texte : pointeur -> adresse PPU (2 octets), caractères (espace $00, 0-9
# $01-$0A, A-Z $0B-$24), $FE + adresse = ligne suivante, $FF = fin.
KEY_PTRS = 0xBB0A         # pointeurs des deux chaînes KEY : $BBC9, $BBDC
KEY_CODE = 0xBD77         # échange des masques $39 / $3A (12 octets) -> nouveau code
KEY_LABEL = 0xBC50        # adresse PPU du libellé « KEY » ($2262)
KEY_IDX = 0x7F00          # WRAM : indice de l'attribution (0-5)
KEY_BUF = 0x7F10          # WRAM : texte de la ligne KEY
KEY_REG = 0x5FFF          # registre fictif (écriture : boutons Gauche $02 / Droite $01)
# Bouton de chaque fonction (transformation, tir, bombe) pour chaque indice
KEY_PERMS = ['ABC', 'ACB', 'BAC', 'BCA', 'CAB', 'CBA']


def _text(s):
    out = bytearray()
    for c in s:
        if c == ' ':
            out.append(0)
        elif c.isdigit():
            out.append(1 + int(c))
        else:
            out.append(0x0B + ord(c) - ord('A'))
    return bytes(out)


def key_buffer(idx):
    """Texte de la ligne KEY pour l'indice idx (lettres en +2, +12 et +21)"""
    ch, sh, bo = KEY_PERMS[idx]
    data = bytes([0x2E, 0x22]) + _text(f'{ch} CHANGE  {sh} SHOT') + bytes([0xFE, 0x6E, 0x22]) + _text(f'{bo} BOMB') + bytes([0xFF])
    assert len(data) == 28
    return data


def init_wram(wram):
    """État initial (aussi fait par rt_init côté 68000)"""
    wram[KEY_IDX - 0x6000] = 0
    b = KEY_BUF - 0x6000
    wram[b:b + 28] = key_buffer(0)


def key_hook(wram, val):
    """Écriture dans KEY_REG (même effet que rt_wr_keycfg)"""
    i = wram[KEY_IDX - 0x6000] % 6
    i = (i - 1) % 6 if val & 0x02 else (i + 1) % 6
    wram[KEY_IDX - 0x6000] = i
    b = KEY_BUF - 0x6000
    wram[b:b + 28] = key_buffer(i)


def _key_code():
    return bytes([
        0x8E, KEY_REG & 0xFF, KEY_REG >> 8,   # STX $5FFF (X = boutons nouveaux)
        0xA0, 0x11,                           # LDY #$11 (chaîne KEY)
        0x98,                                 # TYA
        0x4C, 0xDF, 0xF0,                     # JMP $F0DF (affichage de la chaîne)
        0xEA, 0xEA, 0xEA,
    ])


def patches():
    """[(décalage dans la PRG-ROM, octets attendus ou None, nouveaux octets)]"""
    base = MENU_BANK * 8192 - 0xA000
    new = _menu_code()
    inp = _input_code()
    b7 = 7 * 8192 - 0xA000
    return [
        (base + MENU_HOOK, bytes([0xA5, 0xF8, 0x29]), bytes([0x4C, MENU_NEW & 0xFF, MENU_NEW >> 8])),
        (base + MENU_NEW, bytes([0xFF]) * len(new), new),
        (INPUT_BANK * 8192 + INPUT_HOOK - 0x8000, bytes([0xB5, 0x41, 0x25]), bytes([0x4C, INPUT_NEW & 0xFF, INPUT_NEW >> 8])),
        (14 * 8192 + INPUT_NEW - 0xC000, bytes([0xFF]) * len(inp), inp),
        (b7 + KEY_CODE, bytes.fromhex('a53a8500a539853aa5008539'), _key_code()),
        (b7 + KEY_PTRS, bytes([0xC9, 0xBB, 0xDC, 0xBB]), bytes([KEY_BUF & 0xFF, KEY_BUF >> 8] * 2)),
        (b7 + KEY_LABEL, bytes([0x62, 0x22]), bytes([0x22, 0x22])),
    ]


def apply(prg):
    """Applique les modifications à la PRG-ROM (bytearray), avec contrôle"""
    for off, expect, data in patches():
        if expect is not None and bytes(prg[off:off + len(expect)]) != expect:
            if bytes(prg[off:off + len(data)]) == data:
                continue                 # déjà appliqué
            raise ValueError(f'ROM inattendue en ${off:05X}')
        prg[off:off + len(data)] = data
    return prg
