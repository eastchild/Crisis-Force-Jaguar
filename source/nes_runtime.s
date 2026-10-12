;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Crisis Force - Runtime du code 6502 recompilé (nes_code.s)
;; nes_runtime.s - mémoire NES, registres PPU/APU/manette, mapper VRC4,
;; sauts dynamiques, interruptions 6502.
;;
;; Ne dépend pas du matériel Jaguar : la PPU et l'APU sont des états en
;; mémoire (VRAM, palette, OAM, registres APU) lus par le rendu GPU et le
;; synthé DSP. Le même fichier sert au banc de test (tools/recomp_test.py).
;;
;; Registres du code recompilé : d0=A d1=X d2=Y d6=V a2=pile 6502
;; a4=WRAM a5=RAM+$80 a6=rt_vars. Les routines rt_* ne conservent que
;; d0-d2, d6, d7 et a2-a6 (d3-d5, a0, a1 et le CCR sont libres).
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

;; Décalages dans rt_vars (a6)
rt_slotptr      equ 0           ; 4 longs : banque PRG vue en $8000/$A000/$C000/$E000
rt_slotbank     equ 16          ; 4 octets : numéros de banque
rt_iflag        equ 20          ; drapeau I du 6502 (non nul = IRQ masquée)
rt_irqpend      equ 21          ; IRQ VRC4 en attente (masquée)
rt_prgreg0      equ 22          ; registres PRG du VRC4
rt_prgreg1      equ 23
rt_prgswap      equ 24          ; mode de commutation ($9008 bit 1)
rt_mirror       equ 25          ; miroir : 0 vertical, 1 horizontal, 2/3 écran unique
rt_ppuctrl      equ 26
rt_ppumask      equ 27
rt_ppustatus    equ 28          ; bit 7 = VBL, bit 6 = sprite 0
rt_ppuw         equ 29          ; bascule d'écriture $2005/$2006
rt_oamaddr      equ 30
rt_ppubuf       equ 31          ; tampon de lecture $2007
rt_vaddr        equ 32          ; .w adresse VRAM
rt_scrollx      equ 34          ; .b
rt_scrolly      equ 35          ; .b
rt_padshift     equ 36          ; .b registre à décalage manette 1
rt_padstrobe    equ 37
rt_pad          equ 38          ; .b état manette 1 (bit 0 = A ... bit 7 = Droite)
rt_irqlatch     equ 39
rt_irqctrl      equ 40
rt_sp0count     equ 41          ; lectures de $2002 depuis le VBL (sprite 0 simulé)
rt_chrbank      equ 42          ; 8 mots : banques CHR de 1 Ko
rt_error        equ 58          ; .w code d'erreur (0 = aucune)
rt_erraddr      equ 60          ; .l adresse 6502 / 68000 fautive
rt_apuwrites    equ 64          ; .l compteur d'écritures APU
rt_apuevent     equ 68          ; .l bits : registre APU écrit depuis la dernière lecture DSP
rt_frame        equ 72          ; .l compteur de frames (VBL)
rt_innmi        equ 76          ; .b profondeur d'imbrication du NMI
rt_padshift2    equ 77
rt_pad2         equ 78
rt_ip           equ 80          ; .b drapeaux 6502 (P) pendant l'interprétation
rt_idepth       equ 82          ; .w profondeur d'appels interprétés
rt_interp_count equ 84          ; .l entrées dans l'interpréteur (diagnostic)
rt_forceip      equ 88          ; .b banc de test : tout interpréter
rt_t            equ 90          ; .w registre t de la PPU (défilement / nametable)
rt_v            equ 92          ; .w registre v recopié de t au 2e $2006
rt_fx           equ 94          ; .b défilement fin X
rt_vset         equ 95          ; .b v rechargé pendant l'IRQ courante (effet de trame)
rt_pdirty       equ 96          ; .b état PPU des bandes modifié ($2000/$2005/$2006, banques CHR)
rt_pvc          equ 98          ; .w instant d'effet NES (1/16 ligne depuis l'IRQ) des écritures PPU
rt_pvc0         equ 100         ; .w non nul : écritures PPU chronométrées dans cette IRQ
RT_VARS_SIZE    equ 102

;; Codes d'erreur (rt_error)
RTE_FELL_OFF    equ 1           ; fin de code recompilé atteinte
RTE_GEN         equ 2           ; instruction non traduite
RTE_JTAB        equ 3           ; entrée de table de sauts inconnue
RTE_BRK         equ 4
RTE_DISPATCH    equ 5           ; cible de saut dynamique inconnue

    .text

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Initialisation : registres du code recompilé et état du runtime
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

rt_init:
    lea     rt_vars,a6
    movea.l a6,a0
    move.w  #(RT_VARS_SIZE/2)-1,d0
.clr:
    clr.w   (a0)+
    dbra    d0,.clr
    ;; RAM, WRAM, VRAM, OAM à zéro
    lea     nes_ram,a0
    move.w  #(2048/4)-1,d0
.c1:
    clr.l   (a0)+
    dbra    d0,.c1
    lea     nes_wram,a0
    move.w  #(8192/4)-1,d0
.c2:
    clr.l   (a0)+
    dbra    d0,.c2
    lea     nes_vram,a0
    move.w  #(4096/4)-1,d0
.c3:
    clr.l   (a0)+
    dbra    d0,.c3
    move.l  #-1,vram_dirty             ; tout à recopier pour le GPU
    ;; Banques PRG de départ : 0, 1, 14, 15
    clr.b   rt_prgreg0(a6)
    move.b  #1,rt_prgreg1(a6)
    bsr     rt_update_slots
    lea     nes_wram,a4
    ;; Ligne KEY des options (tools/rom_patches.py) : attribution 0 et son texte
    clr.b   KEY_IDX(a4)
    moveq   #0,d4
    bsr     rt_key_text
    lea     nes_ram+$80,a5
    lea     nes_ram+$100+$FD+1,a2        ; S = $FD
    moveq   #0,d0
    moveq   #0,d1
    moveq   #0,d2
    moveq   #0,d6
    move.b  #1,rt_iflag(a6)
    rts

;; Écritures directes des registres PRG (générées pour STA $8000 / STA $A000) :
;; un seul pointeur recalculé, par table
rt_wr_prg0:
    andi.w  #$1F,d3
    move.b  d3,rt_prgreg0(a6)
    tst.b   rt_prgswap(a6)
    bne     rt_update_slots
    andi.w  #$0F,d3
    move.b  d3,rt_slotbank+0(a6)
    add.w   d3,d3
    add.w   d3,d3
    move.l  rt_banktab(pc,d3.w),rt_slotptr+0(a6)
    rts
rt_wr_prg1:
    andi.w  #$1F,d3
    move.b  d3,rt_prgreg1(a6)
    andi.w  #$0F,d3
    move.b  d3,rt_slotbank+1(a6)
    add.w   d3,d3
    add.w   d3,d3
    move.l  rt_banktab(pc,d3.w),rt_slotptr+4(a6)
    rts
rt_banktab:
    dc.l    prg_rom+(0*8192),prg_rom+(1*8192),prg_rom+(2*8192),prg_rom+(3*8192)
    dc.l    prg_rom+(4*8192),prg_rom+(5*8192),prg_rom+(6*8192),prg_rom+(7*8192)
    dc.l    prg_rom+(8*8192),prg_rom+(9*8192),prg_rom+(10*8192),prg_rom+(11*8192)
    dc.l    prg_rom+(12*8192),prg_rom+(13*8192),prg_rom+(14*8192),prg_rom+(15*8192)

;; Recalcule les pointeurs de banques PRG (VRC4 : $9008 bit 1 échange $8000/$C000)
rt_update_slots:
    moveq   #0,d4
    move.b  rt_prgreg0(a6),d4
    andi.w  #$0F,d4
    moveq   #0,d5
    move.b  rt_prgreg1(a6),d5
    andi.w  #$0F,d5
    tst.b   rt_prgswap(a6)
    bne.s   .swap
    move.b  d4,rt_slotbank+0(a6)
    move.b  #14,rt_slotbank+2(a6)
    bra.s   .s1
.swap:
    move.b  #14,rt_slotbank+0(a6)
    move.b  d4,rt_slotbank+2(a6)
.s1:
    move.b  d5,rt_slotbank+1(a6)
    move.b  #15,rt_slotbank+3(a6)
    lea     prg_rom,a0
    moveq   #3,d4
    lea     rt_slotbank(a6),a1
    lea     rt_slotptr(a6),a3
.s2:
    moveq   #0,d5
    move.b  (a1)+,d5
    swap    d5
    lsr.l   #3,d5                       ; banque * 8192
    add.l   a0,d5
    move.l  d5,(a3)+
    dbra    d4,.s2
    rts

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Accès mémoire génériques : a1 = adresse 6502 (mot), d3 = donnée
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

rt_rd_ind:
    move.w  a1,d4
    bmi.s   .rom                       ; >= $8000 (cas le plus fréquent)
    cmpi.w  #$2000,d4
    bcs.s   .ram
    cmpi.w  #$6000,d4
    bcc.s   .wram
    cmpi.w  #$4000,d4
    bcc.s   .apu
    andi.w  #7,d4
    cmpi.b  #2,d4
    beq     rt_rd_2002
    cmpi.b  #7,d4
    beq     rt_rd_2007
    cmpi.b  #4,d4
    beq.s   .oam
    moveq   #0,d3
    rts
.oam:
    moveq   #0,d4
    move.b  rt_oamaddr(a6),d4
    lea     nes_oam,a0
    move.b  (a0,d4.w),d3
    rts
.ram:
    andi.w  #$7FF,d4
    lea     nes_ram,a0
    move.b  (a0,d4.w),d3
    rts
.wram:
    andi.w  #$1FFF,d4
    move.b  (a4,d4.w),d3
    rts
.rom:
    move.w  d4,d5
    rol.w   #3,d5
    andi.w  #3,d5
    add.w   d5,d5
    add.w   d5,d5
    movea.l rt_slotptr(a6,d5.w),a0
    andi.w  #$1FFF,d4
    move.b  (a0,d4.w),d3
    rts
.apu:
    cmpi.w  #$4016,d4
    beq     rt_rd_4016
    cmpi.w  #$4017,d4
    beq     rt_rd_4017
    cmpi.w  #$4015,d4
    beq     rt_rd_4015
    moveq   #$40,d3
    rts

rt_wr_ind:
    move.w  a1,d4
    cmpi.w  #$2000,d4
    bcs.s   .ram
    cmpi.w  #$8000,d4
    bcc     rt_wr_mapper
    cmpi.w  #$6000,d4
    bcc.s   .wram
    cmpi.w  #$4000,d4
    bcc.s   .apu
    andi.w  #7,d4
    add.w   d4,d4
    add.w   d4,d4
    lea     .ppu(pc),a0
    movea.l (a0,d4.w),a0
    jmp     (a0)
.ppu:
    dc.l    rt_wr_2000,rt_wr_2001,rt_wr_none,rt_wr_2003
    dc.l    rt_wr_2004,rt_wr_2005,rt_wr_2006,rt_wr_2007
.ram:
    andi.w  #$7FF,d4
    lea     nes_ram,a0
    move.b  d3,(a0,d4.w)
    rts
.wram:
    andi.w  #$1FFF,d4
    move.b  d3,(a4,d4.w)
    rts
.apu:
    cmpi.w  #KEY_REG,d4
    beq     rt_wr_keycfg
    cmpi.w  #$4014,d4
    beq     rt_wr_4014
    cmpi.w  #$4016,d4
    beq     rt_wr_4016
    cmpi.w  #$4018,d4
    bcc.s   rt_wr_none
    bra     rt_wr_apu

rt_wr_none:
    rts

;; Instant NES d'une écriture PPU / banque CHR dans une IRQ (appel émis par
;; le recompilateur avant l'écriture) : a3 = cycles 6502 depuis le début de
;; l'IRQ (comptés par le code recompilé, cf. tools/ppu_timing.py), d4 = délai
;; avant que la PPU ne la voie (1/16 de ligne). Les écritures qui prennent
;; effet sur la même ligne forment un groupe (rt_pvc = effet le plus tardif) ;
;; une écriture sur une ligne plus tardive ferme la bande du groupe en attente
;; (jag_ppu_split). Détruit d3-d5 (libres avant l'écriture : la valeur
;; écrite est dans d0-d2).
rt_ppu_time:
    move.w  a3,d5
    move.w  d5,d3
    lsl.w   #3,d5
    add.w   d3,d5
    lsr.w   #6,d5                      ; cycles -> 1/16 de ligne (16/113,67 ~ 9/64)
    add.w   d5,d4
    tst.w   rt_pvc0(a6)
    bne.s   .lnext
    st      rt_pvc0(a6)                ; premier groupe de l'IRQ
    move.w  d4,rt_pvc(a6)
    rts
.lnext:
    .if ^^defined RT_JAGUAR
    move.w  rt_pvc(a6),d5
    move.w  irq_cur16,d3
    add.w   d3,d5
    lsr.w   #4,d5                      ; ligne du groupe en attente
    add.w   d4,d3
    lsr.w   #4,d3                      ; ligne de cette écriture
    cmp.w   d5,d3
    bhi     jag_ppu_split              ; plus tardive : bande du groupe, nouveau groupe
    .endif
    cmp.w   rt_pvc(a6),d4
    bls.s   .lr
    move.w  d4,rt_pvc(a6)
.lr:
    rts

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Ligne KEY de l'écran OPTION (ROM modifiée, tools/rom_patches.py) : 6
;; attributions des fonctions transformation / tir / bombe aux boutons
;; A / B / C. Indice en WRAM $7F00, texte affiché par le jeu en WRAM $7F10.
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
KEY_REG         equ $5FFF       ; registre fictif écrit par la ligne KEY
KEY_IDX         equ $1F00       ; décalages dans la WRAM (a4)
KEY_BUF         equ $1F10

;; Écriture en $5FFF : d3 = boutons nouveaux (Gauche $02 : précédente,
;; sinon suivante)
rt_wr_keycfg:
    moveq   #0,d4
    move.b  KEY_IDX(a4),d4
    btst    #1,d3
    beq.s   .lnext
    subq.b  #1,d4
    bpl.s   .lset
    moveq   #5,d4
    bra.s   .lset
.lnext:
    addq.b  #1,d4
    cmpi.b  #6,d4
    bcs.s   .lset
    moveq   #0,d4
.lset:
    move.b  d4,KEY_IDX(a4)
;; d4 = indice (0-5) -> texte de la ligne KEY en WRAM (28 octets)
rt_key_text:
    lea     rt_key_tpl(pc),a0
    lea     KEY_BUF(a4),a1
    moveq   #28-1,d5
.lcp:
    move.b  (a0)+,(a1)+
    dbra    d5,.lcp
    add.w   d4,d4
    add.w   d4,d4                      ; 4 octets par attribution
    lea     rt_key_perm(pc),a0
    adda.w  d4,a0
    move.b  (a0)+,KEY_BUF+2(a4)        ; transformation
    move.b  (a0)+,KEY_BUF+12(a4)       ; tir
    move.b  (a0)+,KEY_BUF+21(a4)       ; bombe
    rts
;; « x CHANGE  y SHOT » (rangée 17) / « z BOMB » (rangée 19)
rt_key_tpl:
    dc.b    $2E,$22,$0B,$00,$0D,$12,$0B,$18,$11,$0F,$00,$00,$0C,$00,$1D,$12
    dc.b    $19,$1E,$FE,$6E,$22,$0D,$00,$0C,$19,$17,$0C,$FF
;; lettres (A $0B, B $0C, C $0D) des boutons transformation / tir / bombe
rt_key_perm:
    dc.b    $0B,$0C,$0D,0, $0B,$0D,$0C,0, $0C,$0B,$0D,0
    dc.b    $0C,$0D,$0B,0, $0D,$0B,$0C,0, $0D,$0C,$0B,0
    .even

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; PPU
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

rt_wr_2000:
    st      rt_pdirty(a6)
    move.b  d3,rt_ppuctrl(a6)
    move.w  rt_t(a6),d4                ; t : bits 10-11 = nametable
    andi.w  #$F3FF,d4
    moveq   #3,d5
    and.b   d3,d5
    lsl.w   #8,d5
    lsl.w   #2,d5
    or.w    d5,d4
    move.w  d4,rt_t(a6)
    rts

rt_wr_2001:
    move.b  d3,rt_ppumask(a6)
    rts

rt_wr_2003:
    move.b  d3,rt_oamaddr(a6)
    rts

rt_wr_2004:
    moveq   #0,d4
    move.b  rt_oamaddr(a6),d4
    lea     nes_oam,a0
    move.b  d3,(a0,d4.w)
    addq.b  #1,rt_oamaddr(a6)
    rts

;; $2005 : registres t / x fin de la PPU (défilement)
rt_wr_2005:
    st      rt_pdirty(a6)
    move.w  rt_t(a6),d4
    tst.b   rt_ppuw(a6)
    bne.s   .ly_
    move.b  d3,rt_scrollx(a6)
    moveq   #7,d5
    and.b   d3,d5
    move.b  d5,rt_fx(a6)
    andi.w  #$FFE0,d4                  ; X grossier = valeur >> 3
    moveq   #0,d5
    move.b  d3,d5
    lsr.w   #3,d5
    or.w    d5,d4
    move.w  d4,rt_t(a6)
    st      rt_ppuw(a6)
    rts
.ly_:
    move.b  d3,rt_scrolly(a6)
    andi.w  #$8C1F,d4                  ; Y fin (bits 12-14), Y grossier (5-9)
    moveq   #7,d5
    and.b   d3,d5
    lsl.w   #8,d5
    lsl.w   #4,d5
    or.w    d5,d4
    moveq   #0,d5
    move.b  d3,d5
    andi.w  #$F8,d5
    lsl.w   #2,d5
    or.w    d5,d4
    move.w  d4,rt_t(a6)
    sf      rt_ppuw(a6)
    rts

rt_wr_2006:
    st      rt_pdirty(a6)
    tst.b   rt_ppuw(a6)
    bne.s   .llo
    andi.b  #$3F,d3
    move.b  d3,rt_vaddr(a6)
    move.b  d3,rt_t(a6)                ; t bits 8-13 (bit 14 effacé)
    st      rt_ppuw(a6)
    rts
.llo:
    move.b  d3,rt_vaddr+1(a6)
    move.b  d3,rt_t+1(a6)
    move.w  rt_t(a6),rt_v(a6)          ; v = t : défilement changé en cours d'image
    st      rt_vset(a6)
    sf      rt_ppuw(a6)
    rts

;; Écriture VRAM : nametables (miroir VRC4) et palette
rt_wr_2007:
    move.w  rt_vaddr(a6),d4
    move.w  d4,d5
    btst    #2,rt_ppuctrl(a6)
    bne.s   .inc32
    addq.w  #1,d5
    bra.s   .inc
.inc32:
    addi.w  #32,d5
.inc:
    andi.w  #$3FFF,d5
    move.w  d5,rt_vaddr(a6)
    cmpi.w  #$3F00,d4
    bcc.s   .pal
    cmpi.w  #$2000,d4
    bcs.s   .chr
    bsr     rt_nt_offset
    lea     nes_vram,a0
    move.b  d3,(a0,d4.w)
    lsr.w   #6,d4                      ; bloc de 64 octets modifié (TakeSnapshot)
    move.l  vram_dirty,d5
    bset    d4,d5
    move.l  d5,vram_dirty
.chr:
    rts
.pal:
    andi.w  #$1F,d4
    move.b  d4,d5
    andi.b  #$13,d5
    cmpi.b  #$10,d5
    bne.s   .p1
    andi.w  #$0F,d4                    ; $3F10/14/18/1C = $3F00/04/08/0C
.p1:
    andi.b  #$3F,d3
    lea     nes_palette,a0
    move.b  d3,(a0,d4.w)
    rts

;; d4 = adresse $2000-$3EFF -> décalage dans nes_vram (4 Ko : 4 nametables logiques)
;; selon le miroir. Conserve d3.
rt_nt_offset:
    andi.w  #$0FFF,d4
    move.b  rt_mirror(a6),d5
    beq.s   .vert
    cmpi.b  #1,d5
    beq.s   .horz
    andi.w  #$03FF,d4                  ; écran unique
    cmpi.b  #3,d5
    bne.s   .done
    ori.w   #$0400,d4
    rts
.vert:
    andi.w  #$07FF,d4                  ; $2000/$2400 distinctes, $2800 = $2000
    rts
.horz:
    move.w  d4,d5
    andi.w  #$03FF,d4                  ; $2000=$2400, $2800=$2C00
    andi.w  #$0800,d5
    lsr.w   #1,d5
    or.w    d5,d4
.done:
    rts

rt_rd_2002:
    ;; lecture : VBL effacé. bclr teste et efface en une instruction : une
    ;; VBL (interruption) entre la lecture et l'effacement ne se perd plus
    move.b  rt_ppustatus(a6),d3
    andi.b  #$7F,d3
    bclr    #7,rt_ppustatus(a6)
    beq.s   .lnv
    ori.b   #$80,d3
.lnv:
    sf      rt_ppuw(a6)
    rts                                ; sprite 0 : le jeu ne le teste pas

rt_rd_2007:
    move.w  rt_vaddr(a6),d4
    move.b  rt_ppubuf(a6),d3
    move.w  d4,d5
    addq.w  #1,d5
    btst    #2,rt_ppuctrl(a6)
    beq.s   .iok
    addi.w  #31,d5
.iok:
    andi.w  #$3FFF,d5
    move.w  d5,rt_vaddr(a6)
    cmpi.w  #$2000,d4
    bcs.s   .chr
    cmpi.w  #$3F00,d4
    bcc.s   .pal
    move.b  d3,-(sp)
    bsr     rt_nt_offset
    lea     nes_vram,a0
    move.b  (a0,d4.w),rt_ppubuf(a6)
    move.b  (sp)+,d3
    rts
.pal:
    andi.w  #$1F,d4
    lea     nes_palette,a0
    move.b  (a0,d4.w),d3
    rts
.chr:
    ;; CHR-ROM : banque de 1 Ko
    move.w  d4,d5
    lsr.w   #8,d5
    lsr.w   #1,d5
    andi.w  #$0E,d5                    ; (adresse >> 10) * 2
    move.w  rt_chrbank(a6,d5.w),d5
    andi.w  #$7F,d5
    lsl.w   #8,d5
    lsl.l   #2,d5                      ; banque * 1024
    andi.w  #$3FF,d4
    add.w   d4,d5
    lea     chr_rom,a0
    move.b  rt_ppubuf(a6),d3
    move.b  (a0,d5.l),rt_ppubuf(a6)
    rts

;; DMA OAM : page d3 de la RAM -> nes_oam
rt_wr_4014:
    moveq   #0,d4
    move.b  d3,d4
    andi.w  #7,d4
    lsl.w   #8,d4
    lea     nes_ram,a0
    adda.w  d4,a0
    lea     nes_oam,a1
    .if ^^defined RT_JAGUAR
    ;; copie déroulée (256 octets) ; bits 3-4 des attributs (inutilisés par
    ;; la NES) effacés : réservés aux morceaux au bord (Y / X négatifs) pour
    ;; le GPU
    move.l  #$FFFFE7FF,d5
    .rept   64
    move.l  (a0)+,d4
    and.l   d5,d4
    move.l  d4,(a1)+
    .endr
    move.w  hle_hud,oam_hud            ; entrées du HUD de cette page (TakeSnapshot)
    ;; Objets que le jeu fait clignoter (une image sur deux, limite NES de 8
    ;; sprites par ligne) : leurs sprites (hle_sprites, .lextra) occupent les
    ;; entrées cachées. Le GPU n'a pas cette limite, et le Jaguar peut sauter
    ;; une image sur deux quand il est chargé : sans cela, ces objets (tirs au
    ;; boss) disparaissaient tant que la phase restait la mauvaise.
    ;; Puis, dans les entrées encore cachées, les morceaux au bord haut /
    ;; gauche (hle_xedge).
    lea     nes_oam,a1
    moveq   #63,d4                     ; entrées de l'OAM
    moveq   #0,d5
    move.b  hle_xoam_n,d5              ; sprites supplémentaires
    beq.s   .lx_end
    subq.w  #1,d5
    lea     hle_xoam,a0
    moveq   #0,d3                      ; position k*$44
.lx_free:
    cmpi.b  #$EF,(a1)
    bcs.s   .lx_used                   ; entrée occupée
    move.l  (a0,d3.w),(a1)
    addi.b  #$44,d3
    subq.w  #1,d5
    bpl.s   .lx_used
    addq.l  #4,a1                      ; tous placés : entrée suivante
    subq.w  #1,d4
    bpl.s   .lx_end
    rts
.lx_used:
    addq.l  #4,a1
    dbra    d4,.lx_free
    rts                                ; OAM pleine
.lx_end:
    moveq   #0,d5
    move.b  hle_xedge_n,d5
    beq.s   .le_end
    subq.w  #1,d5
    lea     hle_xedge,a0
.le_free:
    cmpi.b  #$EF,(a1)
    bcs.s   .le_used
    move.l  (a0)+,(a1)
    subq.w  #1,d5
    bmi.s   .le_end
.le_used:
    addq.l  #4,a1
    dbra    d4,.le_free
.le_end:
    .else
    .rept   64                         ; copie déroulée (256 octets)
    move.l  (a0)+,(a1)+
    .endr
    .endif
    rts

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; APU : registres mémorisés pour le DSP
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

rt_wr_apu:
    andi.w  #$1F,d4
    lea     nes_apu,a0
    move.b  d3,(a0,d4.w)
    addq.l  #1,rt_apuwrites(a6)
    .if ^^defined RT_JAGUAR
    ;; Anneau du DSP (dsp.s) : long (registre << 8) | valeur
    moveq   #0,d5
    move.w  d4,d5
    lsl.w   #8,d5
    move.b  d3,d5
    move.l  dsp_ring_wr,d4
    andi.w  #63,d4
    lsl.w   #2,d4
    lea     dsp_ring,a0
    move.l  d5,(a0,d4.w)
    move.l  dsp_ring_wr,d4
    addq.l  #1,d4
    andi.l  #63,d4
    move.l  d4,dsp_ring_wr
    .endif
    rts

rt_rd_4015:
    moveq   #0,d3
    rts

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Manettes
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

rt_wr_4016:
    move.b  d3,rt_padstrobe(a6)
    btst    #0,d3
    beq.s   .lr_
    move.b  rt_pad(a6),rt_padshift(a6)
    move.b  rt_pad2(a6),rt_padshift2(a6)
.lr_:
    rts

rt_rd_4016:
    btst    #0,rt_padstrobe(a6)
    beq.s   .shift
    move.b  rt_pad(a6),rt_padshift(a6)
.shift:
    move.b  rt_padshift(a6),d3
    moveq   #1,d4
    and.b   d3,d4
    lsr.b   #1,d3
    ori.b   #$80,d3
    move.b  d3,rt_padshift(a6)
    move.b  d4,d3
    ori.b   #$40,d3
    rts

rt_rd_4017:
    btst    #0,rt_padstrobe(a6)
    beq.s   .shift
    move.b  rt_pad2(a6),rt_padshift2(a6)
.shift:
    move.b  rt_padshift2(a6),d3
    moveq   #1,d4
    and.b   d3,d4
    lsr.b   #1,d3
    ori.b   #$80,d3
    move.b  d3,rt_padshift2(a6)
    move.b  d4,d3
    ori.b   #$40,d3
    rts

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Mapper VRC4e (lignes A2/A3 ; A0/A1 acceptées aussi)
;; d4 = adresse ($8000-$FFFF), d3 = valeur
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

;; Banque CHR ($B000-$EFFF), adresse calculée (STA $B000,Y...) : d4 = adresse,
;; d3 = valeur. Même décodage que rt_wr_mapper, sans la table de saut.
rt_wr_chr:
    st      rt_pdirty(a6)
    move.w  d4,d5
    lsr.w   #2,d5
    or.w    d4,d5                      ; bit 0 = A0|A2 (moitié), bit 1 = A1|A3
    rol.w   #4,d4
    andi.w  #$0F,d4
    subi.w  #$0B,d4
    add.w   d4,d4
    btst    #1,d5
    beq.s   .le
    addq.w  #1,d4
.le:
    add.w   d4,d4
    lea     rt_chrbank(a6,d4.w),a0
    btst    #0,d5
    bne.s   .lhi
    move.w  (a0),d4
    andi.w  #$1F0,d4
    andi.w  #$0F,d3
    or.w    d3,d4
    move.w  d4,(a0)
    rts
.lhi:
    move.w  (a0),d4
    andi.w  #$0F,d4
    andi.w  #$1F,d3
    lsl.w   #4,d3
    or.w    d3,d4
    move.w  d4,(a0)
    rts

rt_wr_mapper:
    ;; idx = (A0|A2) | (A1|A3) << 1
    move.w  d4,d5
    lsr.w   #2,d5
    or.w    d4,d5
    andi.w  #3,d5                      ; bit0 = A0|A2, bit1 = A1|A3
    move.w  d4,a0                      ; garde l'adresse
    rol.w   #4,d4
    andi.w  #$0F,d4                    ; quartet haut : 8..F
    subq.w  #8,d4
    add.w   d4,d4
    add.w   d4,d4
    lea     .tab(pc),a1
    movea.l (a1,d4.w),a1
    jmp     (a1)
.tab:
    dc.l    .prg0,.mirror,.prg1,.chr,.chr,.chr,.chr,.irq
.prg0:
    andi.b  #$1F,d3
    move.b  d3,rt_prgreg0(a6)
    bra     rt_update_slots
.prg1:
    andi.b  #$1F,d3
    move.b  d3,rt_prgreg1(a6)
    bra     rt_update_slots
.mirror:
    btst    #1,d5
    bne.s   .swap
    andi.b  #3,d3
    move.b  d3,rt_mirror(a6)
    rts
.swap:
    lsr.b   #1,d3
    andi.b  #1,d3
    move.b  d3,rt_prgswap(a6)
    bra     rt_update_slots
.chr:
    ;; banque = ((quartet - $B) * 2) + (idx >> 1) ; idx bit 0 : moitié haute
    st      rt_pdirty(a6)
    move.w  a0,d4
    rol.w   #4,d4
    andi.w  #$0F,d4
    subi.w  #$0B,d4
    add.w   d4,d4
    move.w  d5,-(sp)
    lsr.w   #1,d5
    add.w   d5,d4                      ; numéro de banque 0-7
    add.w   d4,d4
    lea     rt_chrbank(a6,d4.w),a0
    move.w  (sp)+,d5
    btst    #0,d5
    bne.s   .chrhi
    move.w  (a0),d4
    andi.w  #$1F0,d4
    andi.w  #$0F,d3
    or.w    d3,d4
    move.w  d4,(a0)
    rts
.chrhi:
    move.w  (a0),d4
    andi.w  #$0F,d4
    andi.w  #$1F,d3
    lsl.w   #4,d3
    or.w    d3,d4
    move.w  d4,(a0)
    rts
.irq:
    tst.b   d5
    beq.s   .latlo
    cmpi.b  #1,d5
    beq.s   .lathi
    cmpi.b  #2,d5
    beq.s   .ctrl
    ;; acquittement : bit 0 -> bit 1 (A)
    sf      rt_irqpend(a6)
    move.b  rt_irqctrl(a6),d4
    andi.b  #5,d4
    btst    #0,d4
    beq.s   .ack
    ori.b   #2,d4
.ack:
    move.b  d4,rt_irqctrl(a6)
    bra     rt_irq_acked
.latlo:
    andi.b  #$F0,rt_irqlatch(a6)
    andi.b  #$0F,d3
    or.b    d3,rt_irqlatch(a6)
    rts
.lathi:
    andi.b  #$0F,rt_irqlatch(a6)
    lsl.b   #4,d3
    or.b    d3,rt_irqlatch(a6)
    rts
.ctrl:
    andi.b  #7,d3
    move.b  d3,rt_irqctrl(a6)
    sf      rt_irqpend(a6)
    bra     rt_irq_changed

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Drapeaux et interruptions
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

;; CLI : une IRQ masquée en attente part immédiatement
rt_cli:
    sf      rt_iflag(a6)
    tst.b   rt_irqpend(a6)
    beq.s   .lr_
    sf      rt_irqpend(a6)
    bra     rt_run_irq
.lr_:
    rts

;; PHP : empile P (N V 1 B D I Z C)
rt_php:
    move.w  sr,d4
    moveq   #$30,d3                    ; bits 5 et 4 (B)
    btst    #3,d4
    beq.s   .ln_
    ori.b   #$80,d3
.ln_:
    tst.b   d6
    beq.s   .lv_
    ori.b   #$40,d3
.lv_:
    tst.b   rt_iflag(a6)
    beq.s   .iok
    ori.b   #$04,d3
.iok:
    btst    #2,d4
    beq.s   .lz_
    ori.b   #$02,d3
.lz_:
    btst    #4,d4                      ; retenue = X
    beq.s   .lc_
    ori.b   #$01,d3
.lc_:
    move.b  d3,-(a2)
    move.w  d4,ccr
    rts

;; PLP : dépile P -> CCR (N, Z, X=C), d6 (V), drapeau I
rt_plp:
    move.b  (a2)+,d3
    moveq   #0,d4
    btst    #7,d3
    beq.s   .ln_
    ori.b   #$08,d4
.ln_:
    btst    #1,d3
    beq.s   .lz_
    ori.b   #$04,d4
.lz_:
    btst    #0,d3
    beq.s   .lc_
    ori.b   #$11,d4
.lc_:
    btst    #6,d3
    sne     d6
    btst    #2,d3
    sne     rt_iflag(a6)
    move.w  d4,ccr
    rts

;; RTI : P et PC sont gérés par l'enrobage d'interruption (rt_nmi / rt_irq)
rt_rti:
    addq.w  #3,a2
    rts

;; Appel du gestionnaire NMI 6502 (depuis l'interruption VBL ou le banc de test).
;; Sauvegarde le contexte du code interrompu ; le 6502 empile PC et P (3 octets).
rt_nmi:
    movem.l d0-d7/a0-a6,-(sp)
    move.w  sr,-(sp)
    lea     rt_vars,a6
    ;; X/Y propres (octet haut à 0) : l'interruption a pu tomber dans du
    ;; code 68000 du runtime (effets de trame de l'IRQ...) qui les utilise
    andi.w  #$FF,d1
    andi.w  #$FF,d2
    move.b  rt_ip(a6),-(sp)            ; P de l'interpréteur éventuellement interrompu
    move.b  rt_iflag(a6),-(sp)
    st      rt_iflag(a6)
    addq.b  #1,rt_innmi(a6)
    subq.w  #1,a2
    subq.w  #2,a2
    jsr     NES_NMI_ENTRY
    subq.b  #1,rt_innmi(a6)
    move.b  (sp)+,rt_iflag(a6)
    move.b  (sp)+,rt_ip(a6)
    move.w  (sp)+,ccr
    movem.l (sp)+,d0-d7/a0-a6
    rts

;; Appel du gestionnaire IRQ 6502 (si I = 0, sinon mise en attente)
rt_irq:
    tst.b   rt_iflag+rt_vars
    beq.s   rt_run_irq_save
    st      rt_irqpend+rt_vars
    rts
rt_run_irq_save:
rt_run_irq:
    movem.l d0-d7/a0-a6,-(sp)
    move.w  sr,-(sp)
    lea     rt_vars,a6
    .if ^^defined RT_JAGUAR
    jsr     jag_raster_pre             ; état PPU en début d'image (effets de trame)
    .endif
    andi.w  #$FF,d1                   ; X/Y propres (cf. rt_nmi)
    andi.w  #$FF,d2
    move.b  rt_ip(a6),-(sp)            ; P de l'interpréteur éventuellement interrompu
    move.b  rt_iflag(a6),-(sp)
    st      rt_iflag(a6)
    subq.w  #3,a2
    movea.w #7,a3                      ; cycles 6502 depuis l'IRQ (prise en compte : 7)
    jsr     NES_IRQ_ENTRY
    .if ^^defined RT_JAGUAR
    jsr     jag_raster_post            ; changement d'état en cours d'image ?
    .endif
    move.b  (sp)+,rt_iflag(a6)
    move.b  (sp)+,rt_ip(a6)
    move.w  (sp)+,ccr
    movem.l (sp)+,d0-d7/a0-a6
    rts

;; Changement de configuration de l'IRQ VRC4 (programmation de la ligne
;; d'interruption côté Jaguar ; vide dans le banc de test)
rt_irq_acked:                          ; acquittement ($F00C) : compteur non rechargé
    .if ^^defined RT_JAGUAR
    bra     jag_irq_acked
    .else
    rts
    .endif
rt_irq_changed:
    .if ^^defined RT_JAGUAR
    bra     jag_irq_changed
    .else
    rts
    .endif

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Sauts dynamiques : d3 = adresse 6502, d4 = CCR à restaurer
;; Table nes_dyn_tab (générée) : par banque, liste (adresse.w, code.l), 0
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

rt_dispatch_jsr:                       ; l'adresse de retour 68000 est déjà empilée
rt_dispatch_jmp:
    move.w  d4,-(sp)
    bsr.s   rt_dispatch_lookup
    beq.s   .lnocode
    move.w  (sp)+,ccr
    jmp     (a0)
.lnocode:
    move.w  (sp)+,d4                   ; pas de code recompilé : interpréteur
    jmp     rt_interp

;; -> a0 = code 68000 de l'adresse d3 dans la banque courante de sa fenêtre,
;; Z = 0 si trouvé, Z = 1 sinon (recherche dichotomique dans nes_dyn_tab :
;; 3 longs par banque). Conserve d0-d3, d6, d7, a2-a6.
rt_dispatch_lookup:
rt_dispatch_find:
    .if ^^defined RECOMP_TEST
    tst.b   rt_forceip(a6)
    bne     .lbad_
    .endif
    move.w  d3,d5
    rol.w   #3,d5
    andi.w  #7,d5
    subq.w  #4,d5
    bcs     .lbad_                     ; < $8000 : pas de code
    moveq   #0,d4
    move.b  rt_slotbank(a6,d5.w),d4
    andi.w  #$0F,d4
    ;; cache direct (256 entrées : clé banque << 16 | adresse, code ; clé 0
    ;; jamais demandée, BSS effacée au démarrage)
    swap    d4
    move.w  d3,d4
    move.w  d3,d5
    lsl.w   #3,d5
    andi.w  #$7F8,d5
    lea     dyn_cache,a0
    cmp.l   (a0,d5.w),d4
    bne.s   .lmiss
    movea.l 4(a0,d5.w),a0
    move.l  a0,d4                      ; Z = 0
    rts
.lmiss:
    pea     (a0,d5.w)                  ; entrée du cache à remplir
    move.l  d4,-(sp)                   ; et sa clé
    swap    d4
    mulu    #12,d4
    lea     nes_dyn_tab,a0
    adda.w  d4,a0
    movea.l 4(a0),a1                   ; pointeurs de code
    move.l  8(a0),d5                   ; nombre d'entrées
    movea.l (a0),a0                    ; adresses triées
    moveq   #0,d4                      ; bas
    bsr.s   .lsearch
    beq.s   .lnofill
    movea.l 4(sp),a1
    move.l  (sp),(a1)+                 ; clé
    move.l  a0,(a1)                    ; code
    move.l  a0,d4                      ; Z = 0
.lnofill:
    addq.l  #8,sp                      ; (Z conservé)
    rts
.lsearch:
    cmp.l   d4,d5
    bls.s   .lbad_
    move.l  d4,-(sp)
    add.l   d5,d4
    lsr.l   #1,d4                      ; milieu
    move.l  d4,-(sp)
    add.l   d4,d4
    cmp.w   (a0,d4.l),d3
    beq.s   .lfound
    bcs.s   .llow                      ; cible < milieu
    move.l  (sp)+,d4
    addq.l  #4,sp
    addq.l  #1,d4                      ; bas = milieu + 1
    bra.s   .lsearch
.llow:
    move.l  (sp)+,d5                   ; haut = milieu
    move.l  (sp)+,d4
    bra.s   .lsearch
.lfound:
    move.l  (sp)+,d4
    addq.l  #4,sp
    add.l   d4,d4
    add.l   d4,d4
    movea.l (a1,d4.l),a0
    move.l  a0,d4                      ; Z = 0
    rts
.lbad_:
    moveq   #0,d4                      ; Z = 1 : pas de code recompilé
    rts

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Erreurs : code dans rt_error, adresse 68000 fautive dans rt_erraddr
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

rt_fell_off:
    move.w  #RTE_FELL_OFF,rt_error+rt_vars
    bra.s   rt_err_pc
rt_gen_error:
    move.w  #RTE_GEN,rt_error+rt_vars
    bra.s   rt_err_pc
rt_bad_jtab:
    move.w  #RTE_JTAB,rt_error+rt_vars
    bra.s   rt_err_pc
rt_brk:
    move.w  #RTE_BRK,rt_error+rt_vars
rt_err_pc:
    move.l  (sp),rt_erraddr+rt_vars
rt_halt:
    .if ^^defined RT_JAGUAR
    jmp     jag_halt
    .endif
.stop:
    bra.s   .stop

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Tables de conversion du CCR (index = CCR & $1F : X N Z V C)
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

    .data
    .even
;; X := C
rt_ccr_c2x:
    dc.b    $00,$11,$02,$13,$04,$15,$06,$17,$08,$19,$0A,$1B,$0C,$1D,$0E,$1F
    dc.b    $00,$11,$02,$13,$04,$15,$06,$17,$08,$19,$0A,$1B,$0C,$1D,$0E,$1F
;; X := !C, C := !C
rt_ccr_nc2x:
    dc.b    $11,$00,$13,$02,$15,$04,$17,$06,$19,$08,$1B,$0A,$1D,$0C,$1F,$0E
    dc.b    $11,$00,$13,$02,$15,$04,$17,$06,$19,$08,$1B,$0A,$1D,$0C,$1F,$0E
;; C := X
rt_ccr_x2c:
    dc.b    $00,$00,$02,$02,$04,$04,$06,$06,$08,$08,$0A,$0A,$0C,$0C,$0E,$0E
    dc.b    $11,$11,$13,$13,$15,$15,$17,$17,$19,$19,$1B,$1B,$1D,$1D,$1F,$1F
;; INC / DEC (INX...) qui conservent X (retenue 6502) : résultat = table[valeur]
rt_inc_tab:
    dc.b    $01,$02,$03,$04,$05,$06,$07,$08,$09,$0A,$0B,$0C,$0D,$0E,$0F,$10
    dc.b    $11,$12,$13,$14,$15,$16,$17,$18,$19,$1A,$1B,$1C,$1D,$1E,$1F,$20
    dc.b    $21,$22,$23,$24,$25,$26,$27,$28,$29,$2A,$2B,$2C,$2D,$2E,$2F,$30
    dc.b    $31,$32,$33,$34,$35,$36,$37,$38,$39,$3A,$3B,$3C,$3D,$3E,$3F,$40
    dc.b    $41,$42,$43,$44,$45,$46,$47,$48,$49,$4A,$4B,$4C,$4D,$4E,$4F,$50
    dc.b    $51,$52,$53,$54,$55,$56,$57,$58,$59,$5A,$5B,$5C,$5D,$5E,$5F,$60
    dc.b    $61,$62,$63,$64,$65,$66,$67,$68,$69,$6A,$6B,$6C,$6D,$6E,$6F,$70
    dc.b    $71,$72,$73,$74,$75,$76,$77,$78,$79,$7A,$7B,$7C,$7D,$7E,$7F,$80
    dc.b    $81,$82,$83,$84,$85,$86,$87,$88,$89,$8A,$8B,$8C,$8D,$8E,$8F,$90
    dc.b    $91,$92,$93,$94,$95,$96,$97,$98,$99,$9A,$9B,$9C,$9D,$9E,$9F,$A0
    dc.b    $A1,$A2,$A3,$A4,$A5,$A6,$A7,$A8,$A9,$AA,$AB,$AC,$AD,$AE,$AF,$B0
    dc.b    $B1,$B2,$B3,$B4,$B5,$B6,$B7,$B8,$B9,$BA,$BB,$BC,$BD,$BE,$BF,$C0
    dc.b    $C1,$C2,$C3,$C4,$C5,$C6,$C7,$C8,$C9,$CA,$CB,$CC,$CD,$CE,$CF,$D0
    dc.b    $D1,$D2,$D3,$D4,$D5,$D6,$D7,$D8,$D9,$DA,$DB,$DC,$DD,$DE,$DF,$E0
    dc.b    $E1,$E2,$E3,$E4,$E5,$E6,$E7,$E8,$E9,$EA,$EB,$EC,$ED,$EE,$EF,$F0
    dc.b    $F1,$F2,$F3,$F4,$F5,$F6,$F7,$F8,$F9,$FA,$FB,$FC,$FD,$FE,$FF,$00
rt_dec_tab:
    dc.b    $FF,$00,$01,$02,$03,$04,$05,$06,$07,$08,$09,$0A,$0B,$0C,$0D,$0E
    dc.b    $0F,$10,$11,$12,$13,$14,$15,$16,$17,$18,$19,$1A,$1B,$1C,$1D,$1E
    dc.b    $1F,$20,$21,$22,$23,$24,$25,$26,$27,$28,$29,$2A,$2B,$2C,$2D,$2E
    dc.b    $2F,$30,$31,$32,$33,$34,$35,$36,$37,$38,$39,$3A,$3B,$3C,$3D,$3E
    dc.b    $3F,$40,$41,$42,$43,$44,$45,$46,$47,$48,$49,$4A,$4B,$4C,$4D,$4E
    dc.b    $4F,$50,$51,$52,$53,$54,$55,$56,$57,$58,$59,$5A,$5B,$5C,$5D,$5E
    dc.b    $5F,$60,$61,$62,$63,$64,$65,$66,$67,$68,$69,$6A,$6B,$6C,$6D,$6E
    dc.b    $6F,$70,$71,$72,$73,$74,$75,$76,$77,$78,$79,$7A,$7B,$7C,$7D,$7E
    dc.b    $7F,$80,$81,$82,$83,$84,$85,$86,$87,$88,$89,$8A,$8B,$8C,$8D,$8E
    dc.b    $8F,$90,$91,$92,$93,$94,$95,$96,$97,$98,$99,$9A,$9B,$9C,$9D,$9E
    dc.b    $9F,$A0,$A1,$A2,$A3,$A4,$A5,$A6,$A7,$A8,$A9,$AA,$AB,$AC,$AD,$AE
    dc.b    $AF,$B0,$B1,$B2,$B3,$B4,$B5,$B6,$B7,$B8,$B9,$BA,$BB,$BC,$BD,$BE
    dc.b    $BF,$C0,$C1,$C2,$C3,$C4,$C5,$C6,$C7,$C8,$C9,$CA,$CB,$CC,$CD,$CE
    dc.b    $CF,$D0,$D1,$D2,$D3,$D4,$D5,$D6,$D7,$D8,$D9,$DA,$DB,$DC,$DD,$DE
    dc.b    $DF,$E0,$E1,$E2,$E3,$E4,$E5,$E6,$E7,$E8,$E9,$EA,$EB,$EC,$ED,$EE
    dc.b    $EF,$F0,$F1,$F2,$F3,$F4,$F5,$F6,$F7,$F8,$F9,$FA,$FB,$FC,$FD,$FE

;; ROM NES
    .long
prg_rom:
    incbin  "nes/prg.bin"
chr_rom:
    incbin  "nes/chr.bin"

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; État de la machine NES
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

    .bss
    .long
rt_vars:        ds.b    RT_VARS_SIZE
    ;; Alignements obligatoires : le GPU recopie VRAM et OAM par mots longs
    ;; (load/store 32 bits, bits bas de l'adresse ignorés), WRAM idem par sécurité
    .phrase
nes_wram:       ds.b    8192
nes_vram:       ds.b    4096           ; 4 nametables logiques (miroir appliqué)
nes_oam:        ds.b    256
nes_palette:    ds.b    32
nes_apu:        ds.b    32             ; $4000-$401F
hle_xoam:       ds.b    256            ; sprites des objets que le jeu fait clignoter (hle_sprites)
hle_zpsave:     ds.b    32             ; page zéro $00-$1F préservée pendant leur dessin
hle_hud:        ds.b    2              ; entrées du HUD dans la page OAM construite (départ, nombre)
oam_hud:        ds.b    2              ; idem pour l'OAM copiée par $4014
vram_dirty:     ds.l    1              ; blocs de 64 octets de nes_vram (0-$7FF) écrits
hle_xedge:      ds.b    32*4           ; morceaux au bord haut / gauche (hle_sprites, .ledge)
hle_xedge_n:    ds.b    1
hle_etmp:       ds.b    2              ; tuile / attributs du morceau noté
hle_xoam_n:     ds.b    1              ; entrées valides de hle_xoam (positions k*$44)
    .even
dyn_cache:      ds.l    512            ; sauts dynamiques : (clé, code) x 256 (rt_dispatch_lookup)
    .phrase
nes_ram_pad:    ds.b    256            ; nes_ram doit être aligné sur 256 (TSX)
nes_ram:        ds.b    2048
