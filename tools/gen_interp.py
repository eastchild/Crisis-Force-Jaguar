#!/usr/bin/env python3
"""
Génère source/nes_interp.s : interpréteur 6502 de secours en 68000, pour le
code que le traçage n'a pas couvert (le code recompilé y saute avec
d3 = adresse 6502, d4 = CCR).

Modèle : d0/d1/d2 = A/X/Y, a2 = pile 6502, d7 = PC 6502, drapeaux 6502 dans
rt_ip(a6) au format P (N V - B D I Z C). Mémoire : rt_rd_ind / rt_wr_ind.
Sortie vers le code recompilé dès qu'un saut, un branchement ou un retour
mène à une adresse qui en a (profondeur d'appels interprétés nulle).

Usage : python gen_interp.py
"""

import os

from recomp6502 import OPTABLE

PROJECT_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(PROJECT_DIR, 'source', 'nes_interp.s')

READ_OPS = {'ADC', 'AND', 'BIT', 'CMP', 'CPX', 'CPY', 'EOR', 'LDA', 'LDX', 'LDY', 'ORA', 'SBC'}
RMW_OPS = {'ASL', 'LSR', 'ROL', 'ROR', 'INC', 'DEC'}
STORE_OPS = {'STA', 'STX', 'STY'}

N, V, Z, C = 0x80, 0x40, 0x02, 0x01


def mode_code(mode):
    """Code qui calcule l'adresse effective dans a1 (ou d3 = valeur immédiate)"""
    if mode == 'imm':
        return ['bsr     ip_fetch']                            # d3 = octet
    if mode == 'zp':
        return ['bsr     ip_fetch', 'andi.w  #$FF,d3', 'movea.w d3,a1']
    if mode in ('zpx', 'zpy'):
        r = 'd1' if mode == 'zpx' else 'd2'
        return ['bsr     ip_fetch', f'add.b   {r},d3', 'andi.w  #$FF,d3', 'movea.w d3,a1']
    if mode == 'abs':
        return ['bsr     ip_fetch16', 'movea.w d3,a1']
    if mode in ('abx', 'aby'):
        r = 'd1' if mode == 'abx' else 'd2'
        return ['bsr     ip_fetch16', f'add.w   {r},d3', 'movea.w d3,a1']
    if mode == 'izx':
        return ['bsr     ip_fetch', 'add.b   d1,d3', 'bsr     ip_zpptr', 'movea.w d3,a1']
    if mode == 'izy':
        return ['bsr     ip_fetch', 'bsr     ip_zpptr', 'add.w   d2,d3', 'movea.w d3,a1']
    raise ValueError(mode)


def op_code(mn):
    """Opération sur d3 (opérande) ; drapeaux via ip_flags (d4 = CCR, d5 = masque P)"""
    def flags(mask, invert_c=False):
        out = ['move.w  sr,d4']
        if invert_c:
            out.append('eori.b  #1,d4')
        out += [f'moveq   #${mask:02X},d5', 'bsr     ip_flags']
        return out
    if mn == 'LDA':
        return ['move.b  d3,d0'] + flags(N | Z)
    if mn == 'LDX':
        return ['move.b  d3,d1'] + flags(N | Z)
    if mn == 'LDY':
        return ['move.b  d3,d2'] + flags(N | Z)
    if mn in ('AND', 'ORA', 'EOR'):
        op = {'AND': 'and', 'ORA': 'or', 'EOR': 'eor'}[mn]
        return [f'{op}.b   d3,d0'] + flags(N | Z)
    if mn == 'ADC':
        return ['bsr     ip_c2x', 'addx.b  d3,d0', 'move.w  sr,d4', 'andi.w  #$13,d4',
                'tst.b   d0', 'move.w  sr,d5', 'andi.w  #$0C,d5', 'or.w    d5,d4',
                f'moveq   #${N | V | Z | C:02X},d5', 'bsr     ip_flags']
    if mn == 'SBC':
        return ['bsr     ip_nc2x', 'subx.b  d3,d0', 'move.w  sr,d4', 'andi.w  #$13,d4',
                'eori.b  #1,d4', 'tst.b   d0', 'move.w  sr,d5', 'andi.w  #$0C,d5', 'or.w    d5,d4',
                f'moveq   #${N | V | Z | C:02X},d5', 'bsr     ip_flags']
    if mn in ('CMP', 'CPX', 'CPY'):
        r = {'CMP': 'd0', 'CPX': 'd1', 'CPY': 'd2'}[mn]
        return [f'move.b  {r},d4', 'sub.b   d3,d4'] + flags(N | Z | C, invert_c=True)
    if mn == 'BIT':
        return ['bsr     ip_bit']
    if mn == 'ASL':
        return ['add.b   d3,d3'] + flags(N | Z | C)
    if mn == 'LSR':
        return ['lsr.b   #1,d3'] + flags(N | Z | C)
    if mn == 'ROL':
        return ['bsr     ip_c2x', 'roxl.b  #1,d3'] + flags(N | Z | C)
    if mn == 'ROR':
        return ['bsr     ip_c2x', 'roxr.b  #1,d3'] + flags(N | Z | C)
    if mn == 'INC':
        return ['addq.b  #1,d3'] + flags(N | Z)
    if mn == 'DEC':
        return ['subq.b  #1,d3'] + flags(N | Z)
    raise ValueError(mn)


def gen_opcode(op):
    mn, mode = OPTABLE[op]
    lab = f'ip_op_{op:02X}'
    L = [f'{lab}:    ; {mn} {mode}']
    e = lambda s: L.append('    ' + s)
    if mn in READ_OPS:
        for c in mode_code(mode):
            e(c)
        if mode != 'imm':
            e('bsr     ip_read')
        for c in op_code(mn):
            e(c)
    elif mn in STORE_OPS:
        for c in mode_code(mode):
            e(c)
        e(f'move.b  {"d0" if mn == "STA" else "d1" if mn == "STX" else "d2"},d3')
        e('bsr     ip_write')
    elif mn in RMW_OPS:
        if mode == 'acc':
            e('move.b  d0,d3')
            for c in op_code(mn):
                e(c)
            e('move.b  d3,d0')
        else:
            for c in mode_code(mode):
                e(c)
            e('move.l  a1,-(sp)')
            e('bsr     ip_read')
            for c in op_code(mn):
                e(c)
            e('movea.l (sp)+,a1')
            e('bsr     ip_write')
    elif mn in ('TAX', 'TAY', 'TXA', 'TYA', 'TSX', 'INX', 'INY', 'DEX', 'DEY'):
        code = {'TAX': ['move.b  d0,d1'], 'TAY': ['move.b  d0,d2'], 'TXA': ['move.b  d1,d0'],
                'TYA': ['move.b  d2,d0'], 'INX': ['addq.b  #1,d1'], 'INY': ['addq.b  #1,d2'],
                'DEX': ['subq.b  #1,d1'], 'DEY': ['subq.b  #1,d2'],
                'TSX': ['move.l  a2,d1', 'subi.l  #nes_ram+$101,d1', 'andi.l  #$FF,d1', 'tst.b   d1']}[mn]
        for c in code:
            e(c)
        e('move.w  sr,d4')
        e(f'moveq   #${N | Z:02X},d5')
        e('bsr     ip_flags')
    elif mn == 'TXS':
        e('lea     nes_ram+$101,a2')
        e('adda.w  d1,a2')
    elif mn == 'PHA':
        e('move.b  d0,-(a2)')
    elif mn == 'PLA':
        e('move.b  (a2)+,d0')
        e('move.w  sr,d4')
        e(f'moveq   #${N | Z:02X},d5')
        e('bsr     ip_flags')
    elif mn == 'PHP':
        e('move.b  rt_ip(a6),d3')
        e('ori.b   #$30,d3')
        e('move.b  d3,-(a2)')
    elif mn == 'PLP':
        e('move.b  (a2)+,d3')
        e('andi.b  #$CF,d3')
        e('move.b  d3,rt_ip(a6)')
        e('btst    #2,d3')
        e('sne     rt_iflag(a6)')
    elif mn in ('CLC', 'SEC', 'CLV', 'CLD', 'SED'):
        bit = {'CLC': C, 'SEC': C, 'CLV': V, 'CLD': 8, 'SED': 8}[mn]
        if mn.startswith('CL'):
            e(f'andi.b  #${0xFF ^ bit:02X},rt_ip(a6)')
        else:
            e(f'ori.b   #${bit:02X},rt_ip(a6)')
    elif mn == 'SEI':
        e('ori.b   #$04,rt_ip(a6)')
        e('st      rt_iflag(a6)')
    elif mn == 'CLI':
        e('andi.b  #$FB,rt_ip(a6)')
        e('jsr     rt_cli')
    elif mn == 'NOP':
        pass
    elif mn in ('BPL', 'BMI', 'BVC', 'BVS', 'BCC', 'BCS', 'BNE', 'BEQ'):
        bit, want = {'BPL': (7, 0), 'BMI': (7, 1), 'BVC': (6, 0), 'BVS': (6, 1), 'BCC': (0, 0),
                     'BCS': (0, 1), 'BNE': (1, 0), 'BEQ': (1, 1)}[mn]
        e('bsr     ip_fetch')
        e(f'btst    #{bit},rt_ip(a6)')
        e(f'{"beq" if want else "bne"}     ip_next')         # pas pris
        e('ext.w   d3')
        e('add.w   d3,d7')
        e('bra     ip_goto')
    elif mn == 'JMP':
        e('bsr     ip_fetch16')
        if mode == 'ind':
            e('bsr     ip_indptr')
        e('move.w  d3,d7')
        e('bra     ip_goto')
    elif mn == 'JSR':
        e('bra     ip_jsr')
    elif mn == 'RTS':
        e('bra     ip_rts')
    elif mn == 'RTI':
        e('bra     ip_rti')
    elif mn == 'BRK':
        e('bra     ip_bad')
    else:
        raise ValueError(mn)
    if not L[-1].strip().startswith('bra'):
        e('bra     ip_next')
    return L


def main():
    lines = [
        ';; Généré par tools/gen_interp.py - ne pas modifier à la main',
        ';; Interpréteur 6502 de secours (code non couvert par le traçage)',
        '',
        '    .text',
        '',
        ';; Entrée : d3 = adresse 6502, d4 = CCR (X = retenue) ; d6 = V',
        'rt_interp:',
        '    ;; Journal des 16 dernières entrées : adresse 6502, appelant 68000, pile 6502',
        '    movem.l d5/a0,-(sp)',
        '    lea     ip_log,a0',
        '    move.w  ip_log_pos,d5',
        '    move.w  d3,(a0,d5.w)',
        '    move.l  8(sp),2(a0,d5.w)',
        '    move.w  a2,6(a0,d5.w)',
        '    addq.w  #8,d5',
        '    andi.w  #127,d5',
        '    move.w  d5,ip_log_pos',
        '    movem.l (sp)+,d5/a0',
        '    move.w  d3,d7',
        '    bsr     ip_ccr2p',
        '    ;; Niveau de pile 6502 de l\'entrée (réentrant) : un RTS à ce niveau revient',
        '    ;; au code 68000 appelant ; plus bas, on reste dans l\'interpréteur',
        '    move.l  ip_base,-(sp)',
        '    move.l  a2,ip_base',
        '    addq.l  #1,rt_interp_count(a6)',
        'ip_next:',
        '    bsr     ip_fetch                 ; opcode',
        '    andi.w  #$FF,d3',
        '    add.w   d3,d3',
        '    add.w   d3,d3',
        '    lea     ip_table,a0',
        '    movea.l (a0,d3.w),a0',
        '    jmp     (a0)',
        '',
        ';; Branchement / saut vers d7 : retour au code recompilé si possible',
        'ip_goto:',
        '    cmpa.l  ip_base,a2',
        '    bcs     ip_next                  ; appel interprété en cours : on continue',
        '    move.w  d7,d3',
        '    jsr     rt_dispatch_lookup       ; a0 = code, ou Z',
        '    beq     ip_next',
        'ip_exit_jmp:',
        '    move.l  (sp)+,ip_base',
        '    bsr     ip_p2ccr                 ; d4 = CCR, d6 = V',
        '    move.w  d4,ccr',
        '    jmp     (a0)',
        '',
        ';; JSR : appel natif si la cible est recompilée, sinon interprétée',
        'ip_jsr:',
        '    bsr     ip_fetch16               ; d3 = cible, d7 = adresse après le JSR',
        '    move.w  d3,-(sp)',
        '    ;; routine qui jette son adresse de retour (répartiteur $C75F...) :',
        '    ;; toujours interprétée (sa cible revient à notre appelant)',
        '    lea     nes_droppers,a0',
        '.ldrop:',
        '    move.w  (a0)+,d4',
        '    beq.s   .lnodrop',
        '    cmp.w   d4,d3',
        '    beq.s   .lijsr',
        '    bra.s   .ldrop',
        '.lnodrop:',
        '    jsr     rt_dispatch_lookup',
        '    beq.s   .lijsr',
        '    addq.l  #2,sp',
        '    subq.w  #2,a2',
        '    move.w  d7,-(sp)                 ; PC de retour',
        '    bsr     ip_p2ccr',
        '    move.w  d4,ccr',
        '    jsr     (a0)                     ; le code recompilé revient par rts',
        '    move.w  sr,d4',
        '    bsr     ip_ccr2p',
        '    move.w  (sp)+,d7',
        '    bra     ip_next',
        '.lijsr:',
        '    move.w  d7,d4',
        '    subq.w  #1,d4                    ; le 6502 empile adresse de retour - 1',
        '    move.w  d4,-(sp)',
        '    move.b  (sp),-(a2)               ; octet haut',
        '    move.b  1(sp),-(a2)              ; octet bas',
        '    addq.l  #2,sp',
        '    move.w  (sp)+,d7',
        '    bra     ip_goto',
        '',
        ';; RTS : retour interprété, ou sortie vers l\'appelant 68000',
        'ip_rts:',
        '    cmpa.l  ip_base,a2',
        '    bcc.s   .lrtsx                   ; niveau de l\'entrée : retour natif',
        '    move.b  (a2)+,d3                 ; bas',
        '    move.b  (a2)+,-(sp)              ; haut',
        '    move.w  (sp)+,d4',
        '    move.b  d3,d4',
        '    addq.w  #1,d4',
        '    move.w  d4,d7',
        '    bra     ip_goto',
        '.lrtsx:',
        '    move.l  (sp)+,ip_base',
        '    bsr     ip_p2ccr',
        '    move.w  d4,ccr',
        '    addq.w  #2,a2',
        '    rts',
        '',
        'ip_rti:',
        '    move.l  (sp)+,ip_base',
        '    bsr     ip_p2ccr',
        '    move.w  d4,ccr',
        '    jmp     rt_rti',
        '',
        'ip_bad:',
        '    move.w  #RTE_BRK,rt_error(a6)',
        '    move.w  d7,rt_erraddr+2(a6)',
        '    jmp     rt_halt',
        '',
        ';; Lecture de l\'octet en PC -> d3, PC + 1',
        'ip_fetch:',
        '    movea.w d7,a1',
        '    addq.w  #1,d7',
        '    jmp     rt_rd_ind',
        ';; Mot (petit-boutiste) en PC -> d3.w, PC + 2',
        'ip_fetch16:',
        '    bsr.s   ip_fetch',
        '    move.b  d3,-(sp)',
        '    bsr.s   ip_fetch',
        '    lsl.w   #8,d3',
        '    move.b  (sp)+,d3',
        '    rts',
        ';; Pointeur en page zéro (d3 = adresse, retour à la page) -> d3.w',
        'ip_zpptr:',
        '    andi.w  #$FF,d3',
        '    move.w  d3,-(sp)',
        '    addq.b  #1,d3',
        '    movea.w d3,a1',
        '    jsr     rt_rd_ind',
        '    move.b  d3,-(sp)',
        '    move.w  2(sp),d3',
        '    movea.w d3,a1',
        '    jsr     rt_rd_ind',
        '    move.b  (sp)+,d4',
        '    lsl.w   #8,d4',
        '    move.b  d3,d4',
        '    move.w  d4,d3',
        '    addq.l  #2,sp',
        '    rts',
        ';; JMP (ind) : d3 = pointeur -> d3 = cible (bogue de page du 6502)',
        'ip_indptr:',
        '    move.w  d3,-(sp)',
        '    movea.w d3,a1',
        '    jsr     rt_rd_ind',
        '    move.b  d3,-(sp)',
        '    move.w  2(sp),d3',
        '    move.w  d3,d4',
        '    addq.b  #1,d4',
        '    move.b  d4,d3',
        '    movea.w d3,a1',
        '    jsr     rt_rd_ind',
        '    lsl.w   #8,d3',
        '    move.b  (sp)+,d3',
        '    addq.l  #2,sp',
        '    rts',
        'ip_read:',
        '    jmp     rt_rd_ind',
        'ip_write:',
        '    jmp     rt_wr_ind',
        '',
        ';; Drapeaux : P = (P & ~d5) | (conversion du CCR d4 & d5)',
        'ip_flags:',
        '    andi.w  #$0F,d4',
        '    move.b  ip_ccrp(pc,d4.w),d4',
        '    and.b   d5,d4',
        '    not.b   d5',
        '    and.b   d5,rt_ip(a6)',
        '    or.b    d4,rt_ip(a6)',
        '    rts',
        ';; CCR (N Z V C) -> bits P',
        'ip_ccrp:',
        '    dc.b    $00,$01,$40,$41,$02,$03,$42,$43,$80,$81,$C0,$C1,$82,$83,$C2,$C3',
        '',
        ';; X du 68000 = C du 6502 (ADC/ROL/ROR)',
        'ip_c2x:',
        '    move.b  rt_ip(a6),d4',
        '    lsr.b   #1,d4',
        '    rts',
        ';; X = !C (SBC)',
        'ip_nc2x:',
        '    move.b  rt_ip(a6),d4',
        '    not.b   d4',
        '    lsr.b   #1,d4',
        '    rts',
        '',
        ';; BIT : Z = (A & M) == 0, N = bit 7 de M, V = bit 6 de M',
        'ip_bit:',
        '    andi.b  #$3D,rt_ip(a6)',
        '    move.b  d3,d4',
        '    andi.b  #$C0,d4',
        '    or.b    d4,rt_ip(a6)',
        '    and.b   d0,d3',
        '    bne.s   .lbz',
        '    ori.b   #$02,rt_ip(a6)',
        '.lbz:',
        '    rts',
        '',
        ';; CCR canonique (d4, X = C) + d6 (V) + rt_iflag -> rt_ip',
        'ip_ccr2p:',
        '    moveq   #$20,d5',
        '    btst    #3,d4',
        '    beq.s   .lc1',
        '    ori.b   #$80,d5',
        '.lc1:',
        '    btst    #2,d4',
        '    beq.s   .lc2',
        '    ori.b   #$02,d5',
        '.lc2:',
        '    btst    #4,d4',
        '    beq.s   .lc3',
        '    ori.b   #$01,d5',
        '.lc3:',
        '    tst.b   d6',
        '    beq.s   .lc4',
        '    ori.b   #$40,d5',
        '.lc4:',
        '    tst.b   rt_iflag(a6)',
        '    beq.s   .lc5',
        '    ori.b   #$04,d5',
        '.lc5:',
        '    move.b  d5,rt_ip(a6)',
        '    rts',
        ';; rt_ip -> d4 = CCR canonique (N, Z, X = C = C), d6 = V',
        'ip_p2ccr:',
        '    moveq   #0,d4',
        '    move.b  rt_ip(a6),d5',
        '    bpl.s   .lp1',
        '    ori.b   #$08,d4',
        '.lp1:',
        '    btst    #1,d5',
        '    beq.s   .lp2',
        '    ori.b   #$04,d4',
        '.lp2:',
        '    btst    #0,d5',
        '    beq.s   .lp3',
        '    ori.b   #$11,d4',
        '.lp3:',
        '    btst    #6,d5',
        '    sne     d6',
        '    andi.w  #$FF,d1',
        '    andi.w  #$FF,d2',
        '    rts',
        '',
    ]
    for op in sorted(OPTABLE):
        lines += gen_opcode(op)
        lines.append('')
    lines += ['    .long', 'ip_table:']
    for op in range(256):
        lines.append(f'    dc.l    {"ip_op_%02X" % op if op in OPTABLE else "ip_bad"}')
    lines += ['', '    .bss', '    .long', 'ip_log:         ds.b    128', 'ip_log_pos:     ds.w    1', '    .long',
              'ip_base:        ds.l    1              ; pile 6502 (a2) à l\'entrée de l\'interpréteur',
              '    .long', '    .text']
    with open(OUT, 'w', encoding='utf-8') as f:
        f.write('\n'.join(lines) + '\n')
    print(f'{OUT} : {len(OPTABLE)} opcodes')


if __name__ == '__main__':
    main()
