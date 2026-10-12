;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Crisis Force - Routines 6502 réécrites en 68000 natif (HLE)
;; nes_hle.s - remplacent des routines chaudes du code recompilé, avec les
;; mêmes effets en mémoire (vérifiés par tools/recomp_test.py).
;;
;; Appel : comme une routine recompilée (JSR : a2 déjà décrémenté de 2) ;
;; retour : addq.w #2,a2 / rts. Registres : d0-d2 = A/X/Y (X/Y propres sur
;; 16 bits au retour), d6/a2/a4-a6 conservés.
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

;; Page zéro relative à a5 (= RAM + $80)
ZP              equ -$80

    .text

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; $EAE7 (banque fixe) : boucle principale du jeu. Tout se passe dans le
;; NMI ; la boucle ne fait qu'avancer le générateur pseudo-aléatoire ($2A,
;; JSR $EAED) en attendant. Ici : un pas, puis stop #$2000 jusqu'à
;; l'interruption suivante (VBL / NMI, PIT / IRQ), au lieu de tourner en
;; lisant la RAM et la ROM : le bus reste au GPU et à l'OP (skill :
;; « do not let the 68000 busy-wait on RAM »). Ne revient jamais.
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

hle_idle:
    subq.w  #2,a2
    jsr     LFEAED
    .if ^^defined PERFHUD
    move.w  VC,d3                      ; début de l'attente (HUD perfhud)
    andi.w  #$7FF,d3
    move.w  d3,idle_vc
    st      idle_on
    .endif
hle_idle_stop:
    stop    #$2000
    bra.s   hle_idle

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; $FEC4C (banque fixe) : lecture des manettes. STY $4016 (1 puis 0), puis
;; 8 fois : bit lu de $4016 -> ROL $00,X, de $4017 -> ROL $01,X ($04 / $05 =
;; dernières valeurs lues). Sortie : A = $30, Y = 0, Z = 1, N = 0, retenue =
;; ancien bit 0 de $01,X (sorti par le dernier ROL).
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

hle_pads:
    clr.b   rt_padstrobe(a6)
    move.b  rt_pad(a6),d4              ; 8e lecture : bit 7 | $40
    rol.b   #1,d4
    andi.b  #1,d4
    ori.b   #$40,d4
    move.b  d4,ZP+$04(a5)
    move.b  rt_pad2(a6),d4
    rol.b   #1,d4
    andi.b  #1,d4
    ori.b   #$40,d4
    move.b  d4,ZP+$05(a5)
    lea     ZP(a5,d1.w),a0
    move.b  (a0),d0
    move.b  1(a0),d2
    move.b  rt_pad(a6),d4              ; bits lus du 0 (A) au 7
    move.b  rt_pad2(a6),d5
    moveq   #7,d3
.lpb:
    lsr.b   #1,d4
    roxl.b  #1,d0
    lsr.b   #1,d5
    roxl.b  #1,d2                      ; X : bit sorti (dernier = retenue finale)
    dbra    d3,.lpb
    move.b  d0,(a0)
    move.b  d2,1(a0)
    st      rt_padshift(a6)            ; registres vidés (remplis de 1)
    st      rt_padshift2(a6)
    moveq   #$30,d0                    ; (moveq ne touche pas X)
    moveq   #0,d2                      ; Y = 0 : Z = 1, N = 0
    addq.w  #2,a2
    rts

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; $8001 (banque 4) : objets (tableaux en WRAM $6000-$61FF) -> OAM ($0200)
;; Pour chaque objet visible, son métasprite (pièces dy/tuile/attr/dx)
;; est écrit dans la page OAM, avec miroirs, palette imposée, découpage
;; hors écran, ordre tournant ($6740 : +$44 par frame) ; les entrées
;; restantes sont cachées (Y = $F4).
;; Registres : d7 = X de la boucle ($0A), d1 = index OAM, d4 = Y, a3 = données
;; du métasprite (adresse hôte), a1 = page OAM.
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

hle_sprites:
    lea     nes_ram+$200,a1
    clr.b   hle_hud+1                  ; pas de HUD noté (affichage, cf. TakeSnapshot)
    clr.b   hle_xedge_n                ; morceaux au bord haut / gauche (affichage)
    clr.b   ZP+$1A(a5)
    ;; Table des métasprites du niveau : Y = $59*2, ou $0E (écran titre...)
    move.b  ZP+$20(a5),d3
    add.b   d3,d3
    cmp.b   ZP+$21(a5),d3
    bne.s   .lc2
    cmpi.b  #2,d3
    beq.s   .lstage
.lc2:
    cmpi.b  #4,ZP+$20(a5)
    bne.s   .ly0e
    cmpi.b  #2,ZP+$45(a5)
    bne.s   .ly0e
    cmpi.b  #8,ZP+$4E(a5)
    bcs.s   .lstage
    addq.b  #1,ZP+$1A(a5)
.lstage:
    moveq   #0,d2
    move.b  ZP+$59(a5),d2
    add.b   d2,d2
    bra.s   .ltab
.ly0e:
    moveq   #$0E,d2
.ltab:
    movea.l rt_slotptr+0(a6),a0
    lea     $218(a0),a0
    move.b  (a0,d2.w),ZP+$18(a5)
    move.b  1(a0,d2.w),ZP+$19(a5)
    move.b  #$40,ZP+$08(a5)
    move.b  $740(a4),d3                ; $6740 += $44
    addi.b  #$44,d3
    move.b  d3,ZP+$09(a5)
    move.b  d3,$740(a4)
    moveq   #0,d7                      ; $0A
    ;; ($08 ne change qu'en dessinant : testé après chaque objet dessiné)
.lscan:
    move.b  (a4,d7.w),d3               ; $6000,X : numéro de métasprite
    bne.s   .lfound
.lnext:
    addq.b  #1,d7
    cmpi.b  #$3A,d7
    bcs.s   .lscan
    move.b  d7,ZP+$0A(a5)
    bra     .lafter
.lfound:
    cmpi.b  #$20,d7
    bcc.s   .ldraw
    cmpi.b  #2,d7
    bcs.s   .ldraw
    tst.b   ZP+$1A(a5)
    beq.s   .ldraw
    move.b  d7,d4                      ; clignotement : un objet sur deux
    move.b  ZP+$23(a5),d5
    eor.b   d5,d4
    btst    #0,d4
    beq     .lnext
.ldraw:
    lea     (a4,d7.w),a0
    move.b  $74(a0),ZP+$01(a5)         ; Y bas / haut
    move.b  $AE(a0),ZP+$02(a5)
    move.b  $122(a0),ZP+$03(a5)        ; X bas / haut
    move.b  $15C(a0),ZP+$04(a5)
    move.b  $196(a0),ZP+$05(a5)        ; palette imposée (bit 7)
    move.b  $1D0(a0),ZP+$06(a5)        ; miroirs
    move.b  d7,ZP+$0A(a5)
    bsr     .lmeta
    addq.b  #1,d7
    move.b  d7,ZP+$0A(a5)
    tst.b   ZP+$08(a5)
    beq     .lret_a0                   ; plus de place : RTS
    cmpi.b  #$3A,d7
    bcs.s   .lscan
    bra     .lafter

    ;; Fin de la liste d'objets
.lafter:
    tst.b   ZP+$08(a5)
    beq.s   .lret_a0
    cmpi.b  #4,ZP+$20(a5)
    bne.s   .lfill
    ;; JSR $AE35 (HUD, code recompilé de la banque 5)
    moveq   #0,d1
    move.b  d7,d1
    moveq   #0,d2
    move.b  d4,d2
    move.b  ZP+$09(a5),hle_hud         ; entrées du HUD : index de départ ($44 par entrée)
    move.b  ZP+$08(a5),hle_hud+1
    subq.w  #2,a2
    jsr     L5AE35
    move.b  hle_hud+1,d3               ; ... et nombre
    sub.b   ZP+$08(a5),d3
    move.b  d3,hle_hud+1
    lea     nes_ram+$200,a1
    tst.b   ZP+$08(a5)
    beq.s   .lret_a0
.lfill:
    ;; Entrées restantes cachées
    moveq   #0,d1
    move.b  ZP+$09(a5),d1
    move.b  ZP+$08(a5),d3
.lfl:
    move.b  #$F4,(a1,d1.w)
    addi.b  #$44,d1
    subq.b  #1,d3
    bne.s   .lfl
    clr.b   ZP+$08(a5)
    move.b  d1,d0
    bra.s   .lret
.lret_a0:
    moveq   #0,d0
.lret:
    movem.l d0/d2/d7,-(sp)
    bsr     .lextra
    movem.l (sp)+,d0/d2/d7
    moveq   #0,d1
    move.b  d7,d1
    andi.w  #$FF,d2
    tst.b   d0
    addq.w  #2,a2
    rts

;; Clignotement ($1A, boss...) : les objets 2-$1F sautés à cette image sont
;; dessinés dans hle_xoam (affichage seulement, ajouté à l'OAM par rt_wr_4014).
;; La page zéro utilisée par .lmeta est rétablie : la mémoire du jeu reste
;; celle de la routine d'origine.
;; hle_xoam_n = nombre d'entrées écrites (positions k*$44, comme $09).
.lextra:
    clr.b   hle_xoam_n
    tst.b   ZP+$1A(a5)
    beq     .lxr
    lea     ZP(a5),a0
    lea     hle_zpsave,a1
    moveq   #7,d1
.lxs:
    move.l  (a0)+,(a1)+
    dbra    d1,.lxs
    clr.b   ZP+$09(a5)
    move.b  #64,ZP+$08(a5)
    moveq   #2,d7
.lxl:
    move.b  (a4,d7.w),d3
    beq.s   .lxn
    move.b  d7,d4
    move.b  ZP+$23(a5),d5
    eor.b   d5,d4
    btst    #0,d4
    bne.s   .lxn                       ; déjà dans l'OAM du jeu
    lea     (a4,d7.w),a0
    move.b  $74(a0),ZP+$01(a5)
    move.b  $AE(a0),ZP+$02(a5)
    move.b  $122(a0),ZP+$03(a5)
    move.b  $15C(a0),ZP+$04(a5)
    move.b  $196(a0),ZP+$05(a5)
    move.b  $1D0(a0),ZP+$06(a5)
    move.b  d7,ZP+$0A(a5)
    lea     hle_xoam,a1
    bsr     .lmeta
    tst.b   ZP+$08(a5)
    beq.s   .lxd
.lxn:
    addq.b  #1,d7
    cmpi.b  #$20,d7
    bcs.s   .lxl
.lxd:
    moveq   #64,d1                     ; entrées écrites (la suivante, peut-être
    sub.b   ZP+$08(a5),d1              ; à demi écrite, est ignorée)
    move.b  d1,hle_xoam_n
    lea     hle_zpsave,a0
    lea     ZP(a5),a1
    moveq   #7,d1
.lxr2:
    move.l  (a0)+,(a1)+
    dbra    d1,.lxr2
.lxr:
    rts

;; Métasprite d3 de l'objet courant -> OAM
.lmeta:
    moveq   #0,d4
    move.b  d3,d4
    cmpi.b  #$60,d3
    bcc.s   .lm2
    add.w   d4,d4
    movea.l rt_slotptr+0(a6),a0
    lea     $226(a0),a0
    bra.s   .lmp
.lm2:
    cmpi.b  #$A0,d3
    bcc.s   .lm3
    subi.w  #$60,d4
    add.w   d4,d4
    movea.l rt_slotptr+0(a6),a0
    lea     $2E6(a0),a0
    bra.s   .lmp
.lm3:
    subi.b  #$A0,d4
    add.b   d4,d4                      ; index 8 bits (comme Y)
    move.b  ZP+$19(a5),d5
    lsl.w   #8,d5
    move.b  ZP+$18(a5),d5
    bsr     .lhost
    movea.l a3,a0
.lmp:
    move.b  1(a0,d4.w),d5              ; pointeur : octet haut
    lsl.w   #8,d5
    move.b  (a0,d4.w),d5               ; octet bas
    move.b  d5,ZP+$0E(a5)
    move.w  d5,d3
    lsr.w   #8,d3
    move.b  d3,ZP+$0F(a5)
    bsr     .lhost                     ; a3 = données
    moveq   #0,d4                      ; Y
    move.b  (a3),ZP+$00(a5)            ; nombre de pièces
    moveq   #0,d1
    move.b  ZP+$09(a5),d1              ; index OAM
    move.b  ZP+$05(a5),d3
    andi.b  #$7F,d3
    move.b  d3,ZP+$14(a5)
    tst.b   ZP+$06(a5)
    bne     .lflip

    ;; --- Sans miroir ---
    bsr     .lxy
.lpiece:
    addq.b  #1,d4
    move.b  (a3,d4.w),d5               ; dy (ou $80 : suite ailleurs)
    cmpi.b  #$80,d5
    bne.s   .lp1
    bsr     .ljump
    move.b  (a3),d5
.lp1:
    ext.w   d5                         ; Y 16 bits + dy signé
    add.w   d0,d5
    move.b  d5,(a1,d1.w)
    cmpi.w  #$FF,d5
    bhi.s   .lpskip
    addq.b  #1,d4
    move.b  (a3,d4.w),1(a1,d1.w)       ; tuile
    addq.b  #1,d4
    move.b  (a3,d4.w),d5               ; attributs
    tst.b   ZP+$05(a5)
    bpl.s   .lp2
    andi.b  #$C0,d5
    or.b    ZP+$14(a5),d5
.lp2:
    move.b  d5,2(a1,d1.w)
    addq.b  #1,d4
    move.b  (a3,d4.w),d5               ; dx
    ext.w   d5
    add.w   a0,d5
    move.b  d5,3(a1,d1.w)
    cmpi.w  #$FF,d5
    bhi     .lpxo                      ; hors écran : l'entrée sera réécrite
    addi.b  #$44,d1
    subq.b  #1,ZP+$08(a5)
    beq.s   .lpend
.lpnext:
    subq.b  #1,ZP+$00(a5)
    bne     .lpiece
.lpend:
    move.b  d1,ZP+$09(a5)
    rts
.lpskip:
    ;; Y hors écran : morceau juste au-dessus du bord haut (affichage seulement)
    cmpi.w  #$FFF0,d5
    bcs.s   .lpsk2
    movem.l d3-d5,-(sp)
    move.w  d5,d3                      ; Y 16 bits
    move.b  1(a3,d4.w),hle_etmp        ; tuile
    move.b  2(a3,d4.w),d5              ; attributs
    tst.b   ZP+$05(a5)
    bpl.s   .lpe1
    andi.b  #$C0,d5
    or.b    ZP+$14(a5),d5
.lpe1:
    move.b  d5,hle_etmp+1
    move.b  3(a3,d4.w),d5              ; dx
    ext.w   d5
    add.w   a0,d5                      ; X 16 bits
    bsr     .ledge
    movem.l (sp)+,d3-d5
.lpsk2:
    addq.b  #3,d4
    bra     .lpnext
.lpxo:
    ;; X hors écran : morceau juste à gauche du bord (affichage seulement)
    cmpi.w  #$FFF8,d5
    bcs     .lpnext
    movem.l d3-d5,-(sp)
    moveq   #0,d3
    move.b  (a1,d1.w),d3
    move.b  1(a1,d1.w),hle_etmp
    move.b  2(a1,d1.w),hle_etmp+1
    bsr     .ledge
    movem.l (sp)+,d3-d5
    bra     .lpnext

    ;; --- Avec miroir(s) : $06 bit 7 = vertical, bit 6 = horizontal ---
.lflip:
    move.b  ZP+$06(a5),d3
    add.b   d3,d3
    move.b  d3,ZP+$07(a5)
    btst    #7,ZP+$06(a5)
    beq.s   .lf1
    move.b  ZP+$02(a5),d3              ; Y -= 16
    lsl.w   #8,d3
    move.b  ZP+$01(a5),d3
    subi.w  #$10,d3
    move.b  d3,ZP+$01(a5)
    lsr.w   #8,d3
    move.b  d3,ZP+$02(a5)
.lf1:
    btst    #6,ZP+$06(a5)
    beq.s   .lf3
    move.b  ZP+$04(a5),d3              ; X -= 8
    lsl.w   #8,d3
    move.b  ZP+$03(a5),d3
    subq.w  #8,d3
    move.b  d3,ZP+$03(a5)
    lsr.w   #8,d3
    move.b  d3,ZP+$04(a5)
.lf3:
    bsr     .lxy
.lfpiece:
    addq.b  #1,d4
    move.b  (a3,d4.w),d5
    cmpi.b  #$80,d5
    bne.s   .lfp1
    bsr     .ljump
    move.b  (a3),d5
.lfp1:
    move.w  d0,d3
    ext.w   d5
    tst.b   ZP+$06(a5)
    bpl.s   .lfy
    sub.w   d5,d3                      ; miroir vertical : Y - dy
    bra.s   .lfy2
.lfy:
    add.w   d5,d3
.lfy2:
    move.b  d3,(a1,d1.w)
    cmpi.w  #$FF,d3
    bhi.s   .lfskip
    addq.b  #1,d4
    move.b  (a3,d4.w),1(a1,d1.w)
    addq.b  #1,d4
    move.b  (a3,d4.w),d5
    tst.b   ZP+$05(a5)
    bpl.s   .lf2
    andi.b  #$C0,d5
    or.b    ZP+$14(a5),d5
.lf2:
    move.b  ZP+$06(a5),d3
    eor.b   d3,d5                      ; miroirs (et priorité) inversés
    move.b  d5,2(a1,d1.w)
    addq.b  #1,d4
    move.b  (a3,d4.w),d5
    move.w  a0,d3
    ext.w   d5
    tst.b   ZP+$07(a5)
    bpl.s   .lfx
    sub.w   d5,d3                      ; miroir horizontal : X - dx
    bra.s   .lfx2
.lfx:
    add.w   d5,d3
.lfx2:
    move.b  d3,3(a1,d1.w)
    cmpi.w  #$FF,d3
    bhi     .lfxo
    addi.b  #$44,d1
    subq.b  #1,ZP+$08(a5)
    beq.s   .lfend
.lfnext:
    subq.b  #1,ZP+$00(a5)
    bne     .lfpiece
.lfend:
    move.b  d1,ZP+$09(a5)
    rts
.lfskip:
    cmpi.w  #$FFF0,d3
    bcs.s   .lfsk2
    movem.l d3-d5,-(sp)
    move.b  1(a3,d4.w),hle_etmp
    move.b  2(a3,d4.w),d5
    tst.b   ZP+$05(a5)
    bpl.s   .lfe1
    andi.b  #$C0,d5
    or.b    ZP+$14(a5),d5
.lfe1:
    move.b  d5,hle_etmp+1
    move.b  ZP+$06(a5),d5
    eor.b   d5,hle_etmp+1              ; miroirs (et priorité) inversés
    move.b  3(a3,d4.w),d4
    ext.w   d4
    move.w  a0,d5
    tst.b   ZP+$07(a5)
    bpl.s   .lfe2
    sub.w   d4,d5                      ; miroir horizontal : X - dx
    bra.s   .lfe3
.lfe2:
    add.w   d4,d5
.lfe3:
    bsr     .ledge
    movem.l (sp)+,d3-d5
.lfsk2:
    addq.b  #3,d4
    bra     .lfnext
.lfxo:
    cmpi.w  #$FFF8,d3
    bcs     .lfnext
    movem.l d3-d5,-(sp)
    move.w  d3,d5                      ; X 16 bits
    moveq   #0,d3
    move.b  (a1,d1.w),d3
    move.b  1(a1,d1.w),hle_etmp
    move.b  2(a1,d1.w),hle_etmp+1
    bsr     .ledge
    movem.l (sp)+,d3-d5
    bra     .lfnext

;; Morceau partiellement hors écran en haut (Y < 0) ou à gauche (X < 0) : la
;; NES ne peut pas l'afficher (il apparaît / disparaît d'un coup au bord) ;
;; noté dans hle_xedge pour l'affichage Jaguar (rt_wr_4014, GPU) avec les
;; bits d'attributs 4 (Y négatif) et 3 (X négatif), inutilisés par la NES.
;; d3.w = Y 16 bits, d5.w = X 16 bits, hle_etmp = tuile, attributs
.ledge:
    movem.l d0-d1/a0,-(sp)
    moveq   #0,d0
    cmpi.w  #$EF,d3
    bcs.s   .le_y
    cmpi.w  #$FFF0,d3
    bcs.s   .le_r                      ; sous l'écran ou trop haut
    bset    #4,d0
.le_y:
    cmpi.w  #$100,d5
    bcs.s   .le_x
    cmpi.w  #$FFF8,d5
    bcs.s   .le_r
    bset    #3,d0
.le_x:
    tst.b   d0
    beq.s   .le_r
    moveq   #0,d1
    move.b  hle_xedge_n,d1
    cmpi.b  #32,d1
    bcc.s   .le_r
    addq.b  #1,hle_xedge_n
    lsl.w   #2,d1
    lea     hle_xedge,a0
    adda.w  d1,a0
    move.b  d3,(a0)+
    move.b  hle_etmp,(a0)+
    move.b  hle_etmp+1,d1
    andi.b  #$E7,d1
    or.b    d0,d1
    move.b  d1,(a0)+
    move.b  d5,(a0)
.le_r:
    movem.l (sp)+,d0-d1/a0
    rts

;; Position de l'objet : d0.w = Y 16 bits ($01/$02), a0.w = X 16 bits ($03/$04)
.lxy:
    move.b  ZP+$02(a5),d0
    lsl.w   #8,d0
    move.b  ZP+$01(a5),d0
    move.b  ZP+$04(a5),d3
    lsl.w   #8,d3
    move.b  ZP+$03(a5),d3
    movea.w d3,a0
    rts

;; JSR $8209 : suite des pièces à une autre adresse (octets Y+1, Y+2)
.ljump:
    addq.b  #1,d4
    move.b  (a3,d4.w),d3               ; bas
    addq.b  #1,d4
    move.b  (a3,d4.w),d5               ; haut
    move.b  d5,ZP+$0F(a5)
    move.b  d3,ZP+$0E(a5)
    lsl.w   #8,d5
    move.b  d3,d5
    bsr.s   .lhost
    moveq   #0,d4
    rts

;; d5.w = adresse 6502 ($8000-$FFFF) -> a3 = adresse hôte (banque courante)
.lhost:
    move.w  d5,d3
    rol.w   #3,d3
    andi.w  #3,d3
    add.w   d3,d3
    add.w   d3,d3
    movea.l rt_slotptr(a6,d3.w),a3
    andi.w  #$1FFF,d5
    adda.w  d5,a3
    rts
