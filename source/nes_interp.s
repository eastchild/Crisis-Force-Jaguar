;; Généré par tools/gen_interp.py - ne pas modifier à la main
;; Interpréteur 6502 de secours (code non couvert par le traçage)

    .text

;; Entrée : d3 = adresse 6502, d4 = CCR (X = retenue) ; d6 = V
rt_interp:
    ;; Journal des 16 dernières entrées : adresse 6502, appelant 68000, pile 6502
    movem.l d5/a0,-(sp)
    lea     ip_log,a0
    move.w  ip_log_pos,d5
    move.w  d3,(a0,d5.w)
    move.l  8(sp),2(a0,d5.w)
    move.w  a2,6(a0,d5.w)
    addq.w  #8,d5
    andi.w  #127,d5
    move.w  d5,ip_log_pos
    movem.l (sp)+,d5/a0
    move.w  d3,d7
    bsr     ip_ccr2p
    ;; Niveau de pile 6502 de l'entrée (réentrant) : un RTS à ce niveau revient
    ;; au code 68000 appelant ; plus bas, on reste dans l'interpréteur
    move.l  ip_base,-(sp)
    move.l  a2,ip_base
    addq.l  #1,rt_interp_count(a6)
ip_next:
    bsr     ip_fetch                 ; opcode
    andi.w  #$FF,d3
    add.w   d3,d3
    add.w   d3,d3
    lea     ip_table,a0
    movea.l (a0,d3.w),a0
    jmp     (a0)

;; Branchement / saut vers d7 : retour au code recompilé si possible
ip_goto:
    cmpa.l  ip_base,a2
    bcs     ip_next                  ; appel interprété en cours : on continue
    move.w  d7,d3
    jsr     rt_dispatch_lookup       ; a0 = code, ou Z
    beq     ip_next
ip_exit_jmp:
    move.l  (sp)+,ip_base
    bsr     ip_p2ccr                 ; d4 = CCR, d6 = V
    move.w  d4,ccr
    jmp     (a0)

;; JSR : appel natif si la cible est recompilée, sinon interprétée
ip_jsr:
    bsr     ip_fetch16               ; d3 = cible, d7 = adresse après le JSR
    move.w  d3,-(sp)
    ;; routine qui jette son adresse de retour (répartiteur $C75F...) :
    ;; toujours interprétée (sa cible revient à notre appelant)
    lea     nes_droppers,a0
.ldrop:
    move.w  (a0)+,d4
    beq.s   .lnodrop
    cmp.w   d4,d3
    beq.s   .lijsr
    bra.s   .ldrop
.lnodrop:
    jsr     rt_dispatch_lookup
    beq.s   .lijsr
    addq.l  #2,sp
    subq.w  #2,a2
    move.w  d7,-(sp)                 ; PC de retour
    bsr     ip_p2ccr
    move.w  d4,ccr
    jsr     (a0)                     ; le code recompilé revient par rts
    move.w  sr,d4
    bsr     ip_ccr2p
    move.w  (sp)+,d7
    bra     ip_next
.lijsr:
    move.w  d7,d4
    subq.w  #1,d4                    ; le 6502 empile adresse de retour - 1
    move.w  d4,-(sp)
    move.b  (sp),-(a2)               ; octet haut
    move.b  1(sp),-(a2)              ; octet bas
    addq.l  #2,sp
    move.w  (sp)+,d7
    bra     ip_goto

;; RTS : retour interprété, ou sortie vers l'appelant 68000
ip_rts:
    cmpa.l  ip_base,a2
    bcc.s   .lrtsx                   ; niveau de l'entrée : retour natif
    move.b  (a2)+,d3                 ; bas
    move.b  (a2)+,-(sp)              ; haut
    move.w  (sp)+,d4
    move.b  d3,d4
    addq.w  #1,d4
    move.w  d4,d7
    bra     ip_goto
.lrtsx:
    move.l  (sp)+,ip_base
    bsr     ip_p2ccr
    move.w  d4,ccr
    addq.w  #2,a2
    rts

ip_rti:
    move.l  (sp)+,ip_base
    bsr     ip_p2ccr
    move.w  d4,ccr
    jmp     rt_rti

ip_bad:
    move.w  #RTE_BRK,rt_error(a6)
    move.w  d7,rt_erraddr+2(a6)
    jmp     rt_halt

;; Lecture de l'octet en PC -> d3, PC + 1
ip_fetch:
    movea.w d7,a1
    addq.w  #1,d7
    jmp     rt_rd_ind
;; Mot (petit-boutiste) en PC -> d3.w, PC + 2
ip_fetch16:
    bsr.s   ip_fetch
    move.b  d3,-(sp)
    bsr.s   ip_fetch
    lsl.w   #8,d3
    move.b  (sp)+,d3
    rts
;; Pointeur en page zéro (d3 = adresse, retour à la page) -> d3.w
ip_zpptr:
    andi.w  #$FF,d3
    move.w  d3,-(sp)
    addq.b  #1,d3
    movea.w d3,a1
    jsr     rt_rd_ind
    move.b  d3,-(sp)
    move.w  2(sp),d3
    movea.w d3,a1
    jsr     rt_rd_ind
    move.b  (sp)+,d4
    lsl.w   #8,d4
    move.b  d3,d4
    move.w  d4,d3
    addq.l  #2,sp
    rts
;; JMP (ind) : d3 = pointeur -> d3 = cible (bogue de page du 6502)
ip_indptr:
    move.w  d3,-(sp)
    movea.w d3,a1
    jsr     rt_rd_ind
    move.b  d3,-(sp)
    move.w  2(sp),d3
    move.w  d3,d4
    addq.b  #1,d4
    move.b  d4,d3
    movea.w d3,a1
    jsr     rt_rd_ind
    lsl.w   #8,d3
    move.b  (sp)+,d3
    addq.l  #2,sp
    rts
ip_read:
    jmp     rt_rd_ind
ip_write:
    jmp     rt_wr_ind

;; Drapeaux : P = (P & ~d5) | (conversion du CCR d4 & d5)
ip_flags:
    andi.w  #$0F,d4
    move.b  ip_ccrp(pc,d4.w),d4
    and.b   d5,d4
    not.b   d5
    and.b   d5,rt_ip(a6)
    or.b    d4,rt_ip(a6)
    rts
;; CCR (N Z V C) -> bits P
ip_ccrp:
    dc.b    $00,$01,$40,$41,$02,$03,$42,$43,$80,$81,$C0,$C1,$82,$83,$C2,$C3

;; X du 68000 = C du 6502 (ADC/ROL/ROR)
ip_c2x:
    move.b  rt_ip(a6),d4
    lsr.b   #1,d4
    rts
;; X = !C (SBC)
ip_nc2x:
    move.b  rt_ip(a6),d4
    not.b   d4
    lsr.b   #1,d4
    rts

;; BIT : Z = (A & M) == 0, N = bit 7 de M, V = bit 6 de M
ip_bit:
    andi.b  #$3D,rt_ip(a6)
    move.b  d3,d4
    andi.b  #$C0,d4
    or.b    d4,rt_ip(a6)
    and.b   d0,d3
    bne.s   .lbz
    ori.b   #$02,rt_ip(a6)
.lbz:
    rts

;; CCR canonique (d4, X = C) + d6 (V) + rt_iflag -> rt_ip
ip_ccr2p:
    moveq   #$20,d5
    btst    #3,d4
    beq.s   .lc1
    ori.b   #$80,d5
.lc1:
    btst    #2,d4
    beq.s   .lc2
    ori.b   #$02,d5
.lc2:
    btst    #4,d4
    beq.s   .lc3
    ori.b   #$01,d5
.lc3:
    tst.b   d6
    beq.s   .lc4
    ori.b   #$40,d5
.lc4:
    tst.b   rt_iflag(a6)
    beq.s   .lc5
    ori.b   #$04,d5
.lc5:
    move.b  d5,rt_ip(a6)
    rts
;; rt_ip -> d4 = CCR canonique (N, Z, X = C = C), d6 = V
ip_p2ccr:
    moveq   #0,d4
    move.b  rt_ip(a6),d5
    bpl.s   .lp1
    ori.b   #$08,d4
.lp1:
    btst    #1,d5
    beq.s   .lp2
    ori.b   #$04,d4
.lp2:
    btst    #0,d5
    beq.s   .lp3
    ori.b   #$11,d4
.lp3:
    btst    #6,d5
    sne     d6
    andi.w  #$FF,d1
    andi.w  #$FF,d2
    rts

ip_op_00:    ; BRK imp
    bra     ip_bad

ip_op_01:    ; ORA izx
    bsr     ip_fetch
    add.b   d1,d3
    bsr     ip_zpptr
    movea.w d3,a1
    bsr     ip_read
    or.b   d3,d0
    move.w  sr,d4
    moveq   #$82,d5
    bsr     ip_flags
    bra     ip_next

ip_op_05:    ; ORA zp
    bsr     ip_fetch
    andi.w  #$FF,d3
    movea.w d3,a1
    bsr     ip_read
    or.b   d3,d0
    move.w  sr,d4
    moveq   #$82,d5
    bsr     ip_flags
    bra     ip_next

ip_op_06:    ; ASL zp
    bsr     ip_fetch
    andi.w  #$FF,d3
    movea.w d3,a1
    move.l  a1,-(sp)
    bsr     ip_read
    add.b   d3,d3
    move.w  sr,d4
    moveq   #$83,d5
    bsr     ip_flags
    movea.l (sp)+,a1
    bsr     ip_write
    bra     ip_next

ip_op_08:    ; PHP imp
    move.b  rt_ip(a6),d3
    ori.b   #$30,d3
    move.b  d3,-(a2)
    bra     ip_next

ip_op_09:    ; ORA imm
    bsr     ip_fetch
    or.b   d3,d0
    move.w  sr,d4
    moveq   #$82,d5
    bsr     ip_flags
    bra     ip_next

ip_op_0A:    ; ASL acc
    move.b  d0,d3
    add.b   d3,d3
    move.w  sr,d4
    moveq   #$83,d5
    bsr     ip_flags
    move.b  d3,d0
    bra     ip_next

ip_op_0D:    ; ORA abs
    bsr     ip_fetch16
    movea.w d3,a1
    bsr     ip_read
    or.b   d3,d0
    move.w  sr,d4
    moveq   #$82,d5
    bsr     ip_flags
    bra     ip_next

ip_op_0E:    ; ASL abs
    bsr     ip_fetch16
    movea.w d3,a1
    move.l  a1,-(sp)
    bsr     ip_read
    add.b   d3,d3
    move.w  sr,d4
    moveq   #$83,d5
    bsr     ip_flags
    movea.l (sp)+,a1
    bsr     ip_write
    bra     ip_next

ip_op_10:    ; BPL rel
    bsr     ip_fetch
    btst    #7,rt_ip(a6)
    bne     ip_next
    ext.w   d3
    add.w   d3,d7
    bra     ip_goto

ip_op_11:    ; ORA izy
    bsr     ip_fetch
    bsr     ip_zpptr
    add.w   d2,d3
    movea.w d3,a1
    bsr     ip_read
    or.b   d3,d0
    move.w  sr,d4
    moveq   #$82,d5
    bsr     ip_flags
    bra     ip_next

ip_op_15:    ; ORA zpx
    bsr     ip_fetch
    add.b   d1,d3
    andi.w  #$FF,d3
    movea.w d3,a1
    bsr     ip_read
    or.b   d3,d0
    move.w  sr,d4
    moveq   #$82,d5
    bsr     ip_flags
    bra     ip_next

ip_op_16:    ; ASL zpx
    bsr     ip_fetch
    add.b   d1,d3
    andi.w  #$FF,d3
    movea.w d3,a1
    move.l  a1,-(sp)
    bsr     ip_read
    add.b   d3,d3
    move.w  sr,d4
    moveq   #$83,d5
    bsr     ip_flags
    movea.l (sp)+,a1
    bsr     ip_write
    bra     ip_next

ip_op_18:    ; CLC imp
    andi.b  #$FE,rt_ip(a6)
    bra     ip_next

ip_op_19:    ; ORA aby
    bsr     ip_fetch16
    add.w   d2,d3
    movea.w d3,a1
    bsr     ip_read
    or.b   d3,d0
    move.w  sr,d4
    moveq   #$82,d5
    bsr     ip_flags
    bra     ip_next

ip_op_1D:    ; ORA abx
    bsr     ip_fetch16
    add.w   d1,d3
    movea.w d3,a1
    bsr     ip_read
    or.b   d3,d0
    move.w  sr,d4
    moveq   #$82,d5
    bsr     ip_flags
    bra     ip_next

ip_op_1E:    ; ASL abx
    bsr     ip_fetch16
    add.w   d1,d3
    movea.w d3,a1
    move.l  a1,-(sp)
    bsr     ip_read
    add.b   d3,d3
    move.w  sr,d4
    moveq   #$83,d5
    bsr     ip_flags
    movea.l (sp)+,a1
    bsr     ip_write
    bra     ip_next

ip_op_20:    ; JSR abs
    bra     ip_jsr

ip_op_21:    ; AND izx
    bsr     ip_fetch
    add.b   d1,d3
    bsr     ip_zpptr
    movea.w d3,a1
    bsr     ip_read
    and.b   d3,d0
    move.w  sr,d4
    moveq   #$82,d5
    bsr     ip_flags
    bra     ip_next

ip_op_24:    ; BIT zp
    bsr     ip_fetch
    andi.w  #$FF,d3
    movea.w d3,a1
    bsr     ip_read
    bsr     ip_bit
    bra     ip_next

ip_op_25:    ; AND zp
    bsr     ip_fetch
    andi.w  #$FF,d3
    movea.w d3,a1
    bsr     ip_read
    and.b   d3,d0
    move.w  sr,d4
    moveq   #$82,d5
    bsr     ip_flags
    bra     ip_next

ip_op_26:    ; ROL zp
    bsr     ip_fetch
    andi.w  #$FF,d3
    movea.w d3,a1
    move.l  a1,-(sp)
    bsr     ip_read
    bsr     ip_c2x
    roxl.b  #1,d3
    move.w  sr,d4
    moveq   #$83,d5
    bsr     ip_flags
    movea.l (sp)+,a1
    bsr     ip_write
    bra     ip_next

ip_op_28:    ; PLP imp
    move.b  (a2)+,d3
    andi.b  #$CF,d3
    move.b  d3,rt_ip(a6)
    btst    #2,d3
    sne     rt_iflag(a6)
    bra     ip_next

ip_op_29:    ; AND imm
    bsr     ip_fetch
    and.b   d3,d0
    move.w  sr,d4
    moveq   #$82,d5
    bsr     ip_flags
    bra     ip_next

ip_op_2A:    ; ROL acc
    move.b  d0,d3
    bsr     ip_c2x
    roxl.b  #1,d3
    move.w  sr,d4
    moveq   #$83,d5
    bsr     ip_flags
    move.b  d3,d0
    bra     ip_next

ip_op_2C:    ; BIT abs
    bsr     ip_fetch16
    movea.w d3,a1
    bsr     ip_read
    bsr     ip_bit
    bra     ip_next

ip_op_2D:    ; AND abs
    bsr     ip_fetch16
    movea.w d3,a1
    bsr     ip_read
    and.b   d3,d0
    move.w  sr,d4
    moveq   #$82,d5
    bsr     ip_flags
    bra     ip_next

ip_op_2E:    ; ROL abs
    bsr     ip_fetch16
    movea.w d3,a1
    move.l  a1,-(sp)
    bsr     ip_read
    bsr     ip_c2x
    roxl.b  #1,d3
    move.w  sr,d4
    moveq   #$83,d5
    bsr     ip_flags
    movea.l (sp)+,a1
    bsr     ip_write
    bra     ip_next

ip_op_30:    ; BMI rel
    bsr     ip_fetch
    btst    #7,rt_ip(a6)
    beq     ip_next
    ext.w   d3
    add.w   d3,d7
    bra     ip_goto

ip_op_31:    ; AND izy
    bsr     ip_fetch
    bsr     ip_zpptr
    add.w   d2,d3
    movea.w d3,a1
    bsr     ip_read
    and.b   d3,d0
    move.w  sr,d4
    moveq   #$82,d5
    bsr     ip_flags
    bra     ip_next

ip_op_35:    ; AND zpx
    bsr     ip_fetch
    add.b   d1,d3
    andi.w  #$FF,d3
    movea.w d3,a1
    bsr     ip_read
    and.b   d3,d0
    move.w  sr,d4
    moveq   #$82,d5
    bsr     ip_flags
    bra     ip_next

ip_op_36:    ; ROL zpx
    bsr     ip_fetch
    add.b   d1,d3
    andi.w  #$FF,d3
    movea.w d3,a1
    move.l  a1,-(sp)
    bsr     ip_read
    bsr     ip_c2x
    roxl.b  #1,d3
    move.w  sr,d4
    moveq   #$83,d5
    bsr     ip_flags
    movea.l (sp)+,a1
    bsr     ip_write
    bra     ip_next

ip_op_38:    ; SEC imp
    ori.b   #$01,rt_ip(a6)
    bra     ip_next

ip_op_39:    ; AND aby
    bsr     ip_fetch16
    add.w   d2,d3
    movea.w d3,a1
    bsr     ip_read
    and.b   d3,d0
    move.w  sr,d4
    moveq   #$82,d5
    bsr     ip_flags
    bra     ip_next

ip_op_3D:    ; AND abx
    bsr     ip_fetch16
    add.w   d1,d3
    movea.w d3,a1
    bsr     ip_read
    and.b   d3,d0
    move.w  sr,d4
    moveq   #$82,d5
    bsr     ip_flags
    bra     ip_next

ip_op_3E:    ; ROL abx
    bsr     ip_fetch16
    add.w   d1,d3
    movea.w d3,a1
    move.l  a1,-(sp)
    bsr     ip_read
    bsr     ip_c2x
    roxl.b  #1,d3
    move.w  sr,d4
    moveq   #$83,d5
    bsr     ip_flags
    movea.l (sp)+,a1
    bsr     ip_write
    bra     ip_next

ip_op_40:    ; RTI imp
    bra     ip_rti

ip_op_41:    ; EOR izx
    bsr     ip_fetch
    add.b   d1,d3
    bsr     ip_zpptr
    movea.w d3,a1
    bsr     ip_read
    eor.b   d3,d0
    move.w  sr,d4
    moveq   #$82,d5
    bsr     ip_flags
    bra     ip_next

ip_op_45:    ; EOR zp
    bsr     ip_fetch
    andi.w  #$FF,d3
    movea.w d3,a1
    bsr     ip_read
    eor.b   d3,d0
    move.w  sr,d4
    moveq   #$82,d5
    bsr     ip_flags
    bra     ip_next

ip_op_46:    ; LSR zp
    bsr     ip_fetch
    andi.w  #$FF,d3
    movea.w d3,a1
    move.l  a1,-(sp)
    bsr     ip_read
    lsr.b   #1,d3
    move.w  sr,d4
    moveq   #$83,d5
    bsr     ip_flags
    movea.l (sp)+,a1
    bsr     ip_write
    bra     ip_next

ip_op_48:    ; PHA imp
    move.b  d0,-(a2)
    bra     ip_next

ip_op_49:    ; EOR imm
    bsr     ip_fetch
    eor.b   d3,d0
    move.w  sr,d4
    moveq   #$82,d5
    bsr     ip_flags
    bra     ip_next

ip_op_4A:    ; LSR acc
    move.b  d0,d3
    lsr.b   #1,d3
    move.w  sr,d4
    moveq   #$83,d5
    bsr     ip_flags
    move.b  d3,d0
    bra     ip_next

ip_op_4C:    ; JMP abs
    bsr     ip_fetch16
    move.w  d3,d7
    bra     ip_goto

ip_op_4D:    ; EOR abs
    bsr     ip_fetch16
    movea.w d3,a1
    bsr     ip_read
    eor.b   d3,d0
    move.w  sr,d4
    moveq   #$82,d5
    bsr     ip_flags
    bra     ip_next

ip_op_4E:    ; LSR abs
    bsr     ip_fetch16
    movea.w d3,a1
    move.l  a1,-(sp)
    bsr     ip_read
    lsr.b   #1,d3
    move.w  sr,d4
    moveq   #$83,d5
    bsr     ip_flags
    movea.l (sp)+,a1
    bsr     ip_write
    bra     ip_next

ip_op_50:    ; BVC rel
    bsr     ip_fetch
    btst    #6,rt_ip(a6)
    bne     ip_next
    ext.w   d3
    add.w   d3,d7
    bra     ip_goto

ip_op_51:    ; EOR izy
    bsr     ip_fetch
    bsr     ip_zpptr
    add.w   d2,d3
    movea.w d3,a1
    bsr     ip_read
    eor.b   d3,d0
    move.w  sr,d4
    moveq   #$82,d5
    bsr     ip_flags
    bra     ip_next

ip_op_55:    ; EOR zpx
    bsr     ip_fetch
    add.b   d1,d3
    andi.w  #$FF,d3
    movea.w d3,a1
    bsr     ip_read
    eor.b   d3,d0
    move.w  sr,d4
    moveq   #$82,d5
    bsr     ip_flags
    bra     ip_next

ip_op_56:    ; LSR zpx
    bsr     ip_fetch
    add.b   d1,d3
    andi.w  #$FF,d3
    movea.w d3,a1
    move.l  a1,-(sp)
    bsr     ip_read
    lsr.b   #1,d3
    move.w  sr,d4
    moveq   #$83,d5
    bsr     ip_flags
    movea.l (sp)+,a1
    bsr     ip_write
    bra     ip_next

ip_op_58:    ; CLI imp
    andi.b  #$FB,rt_ip(a6)
    jsr     rt_cli
    bra     ip_next

ip_op_59:    ; EOR aby
    bsr     ip_fetch16
    add.w   d2,d3
    movea.w d3,a1
    bsr     ip_read
    eor.b   d3,d0
    move.w  sr,d4
    moveq   #$82,d5
    bsr     ip_flags
    bra     ip_next

ip_op_5D:    ; EOR abx
    bsr     ip_fetch16
    add.w   d1,d3
    movea.w d3,a1
    bsr     ip_read
    eor.b   d3,d0
    move.w  sr,d4
    moveq   #$82,d5
    bsr     ip_flags
    bra     ip_next

ip_op_5E:    ; LSR abx
    bsr     ip_fetch16
    add.w   d1,d3
    movea.w d3,a1
    move.l  a1,-(sp)
    bsr     ip_read
    lsr.b   #1,d3
    move.w  sr,d4
    moveq   #$83,d5
    bsr     ip_flags
    movea.l (sp)+,a1
    bsr     ip_write
    bra     ip_next

ip_op_60:    ; RTS imp
    bra     ip_rts

ip_op_61:    ; ADC izx
    bsr     ip_fetch
    add.b   d1,d3
    bsr     ip_zpptr
    movea.w d3,a1
    bsr     ip_read
    bsr     ip_c2x
    addx.b  d3,d0
    move.w  sr,d4
    andi.w  #$13,d4
    tst.b   d0
    move.w  sr,d5
    andi.w  #$0C,d5
    or.w    d5,d4
    moveq   #$C3,d5
    bsr     ip_flags
    bra     ip_next

ip_op_65:    ; ADC zp
    bsr     ip_fetch
    andi.w  #$FF,d3
    movea.w d3,a1
    bsr     ip_read
    bsr     ip_c2x
    addx.b  d3,d0
    move.w  sr,d4
    andi.w  #$13,d4
    tst.b   d0
    move.w  sr,d5
    andi.w  #$0C,d5
    or.w    d5,d4
    moveq   #$C3,d5
    bsr     ip_flags
    bra     ip_next

ip_op_66:    ; ROR zp
    bsr     ip_fetch
    andi.w  #$FF,d3
    movea.w d3,a1
    move.l  a1,-(sp)
    bsr     ip_read
    bsr     ip_c2x
    roxr.b  #1,d3
    move.w  sr,d4
    moveq   #$83,d5
    bsr     ip_flags
    movea.l (sp)+,a1
    bsr     ip_write
    bra     ip_next

ip_op_68:    ; PLA imp
    move.b  (a2)+,d0
    move.w  sr,d4
    moveq   #$82,d5
    bsr     ip_flags
    bra     ip_next

ip_op_69:    ; ADC imm
    bsr     ip_fetch
    bsr     ip_c2x
    addx.b  d3,d0
    move.w  sr,d4
    andi.w  #$13,d4
    tst.b   d0
    move.w  sr,d5
    andi.w  #$0C,d5
    or.w    d5,d4
    moveq   #$C3,d5
    bsr     ip_flags
    bra     ip_next

ip_op_6A:    ; ROR acc
    move.b  d0,d3
    bsr     ip_c2x
    roxr.b  #1,d3
    move.w  sr,d4
    moveq   #$83,d5
    bsr     ip_flags
    move.b  d3,d0
    bra     ip_next

ip_op_6C:    ; JMP ind
    bsr     ip_fetch16
    bsr     ip_indptr
    move.w  d3,d7
    bra     ip_goto

ip_op_6D:    ; ADC abs
    bsr     ip_fetch16
    movea.w d3,a1
    bsr     ip_read
    bsr     ip_c2x
    addx.b  d3,d0
    move.w  sr,d4
    andi.w  #$13,d4
    tst.b   d0
    move.w  sr,d5
    andi.w  #$0C,d5
    or.w    d5,d4
    moveq   #$C3,d5
    bsr     ip_flags
    bra     ip_next

ip_op_6E:    ; ROR abs
    bsr     ip_fetch16
    movea.w d3,a1
    move.l  a1,-(sp)
    bsr     ip_read
    bsr     ip_c2x
    roxr.b  #1,d3
    move.w  sr,d4
    moveq   #$83,d5
    bsr     ip_flags
    movea.l (sp)+,a1
    bsr     ip_write
    bra     ip_next

ip_op_70:    ; BVS rel
    bsr     ip_fetch
    btst    #6,rt_ip(a6)
    beq     ip_next
    ext.w   d3
    add.w   d3,d7
    bra     ip_goto

ip_op_71:    ; ADC izy
    bsr     ip_fetch
    bsr     ip_zpptr
    add.w   d2,d3
    movea.w d3,a1
    bsr     ip_read
    bsr     ip_c2x
    addx.b  d3,d0
    move.w  sr,d4
    andi.w  #$13,d4
    tst.b   d0
    move.w  sr,d5
    andi.w  #$0C,d5
    or.w    d5,d4
    moveq   #$C3,d5
    bsr     ip_flags
    bra     ip_next

ip_op_75:    ; ADC zpx
    bsr     ip_fetch
    add.b   d1,d3
    andi.w  #$FF,d3
    movea.w d3,a1
    bsr     ip_read
    bsr     ip_c2x
    addx.b  d3,d0
    move.w  sr,d4
    andi.w  #$13,d4
    tst.b   d0
    move.w  sr,d5
    andi.w  #$0C,d5
    or.w    d5,d4
    moveq   #$C3,d5
    bsr     ip_flags
    bra     ip_next

ip_op_76:    ; ROR zpx
    bsr     ip_fetch
    add.b   d1,d3
    andi.w  #$FF,d3
    movea.w d3,a1
    move.l  a1,-(sp)
    bsr     ip_read
    bsr     ip_c2x
    roxr.b  #1,d3
    move.w  sr,d4
    moveq   #$83,d5
    bsr     ip_flags
    movea.l (sp)+,a1
    bsr     ip_write
    bra     ip_next

ip_op_78:    ; SEI imp
    ori.b   #$04,rt_ip(a6)
    st      rt_iflag(a6)
    bra     ip_next

ip_op_79:    ; ADC aby
    bsr     ip_fetch16
    add.w   d2,d3
    movea.w d3,a1
    bsr     ip_read
    bsr     ip_c2x
    addx.b  d3,d0
    move.w  sr,d4
    andi.w  #$13,d4
    tst.b   d0
    move.w  sr,d5
    andi.w  #$0C,d5
    or.w    d5,d4
    moveq   #$C3,d5
    bsr     ip_flags
    bra     ip_next

ip_op_7D:    ; ADC abx
    bsr     ip_fetch16
    add.w   d1,d3
    movea.w d3,a1
    bsr     ip_read
    bsr     ip_c2x
    addx.b  d3,d0
    move.w  sr,d4
    andi.w  #$13,d4
    tst.b   d0
    move.w  sr,d5
    andi.w  #$0C,d5
    or.w    d5,d4
    moveq   #$C3,d5
    bsr     ip_flags
    bra     ip_next

ip_op_7E:    ; ROR abx
    bsr     ip_fetch16
    add.w   d1,d3
    movea.w d3,a1
    move.l  a1,-(sp)
    bsr     ip_read
    bsr     ip_c2x
    roxr.b  #1,d3
    move.w  sr,d4
    moveq   #$83,d5
    bsr     ip_flags
    movea.l (sp)+,a1
    bsr     ip_write
    bra     ip_next

ip_op_81:    ; STA izx
    bsr     ip_fetch
    add.b   d1,d3
    bsr     ip_zpptr
    movea.w d3,a1
    move.b  d0,d3
    bsr     ip_write
    bra     ip_next

ip_op_84:    ; STY zp
    bsr     ip_fetch
    andi.w  #$FF,d3
    movea.w d3,a1
    move.b  d2,d3
    bsr     ip_write
    bra     ip_next

ip_op_85:    ; STA zp
    bsr     ip_fetch
    andi.w  #$FF,d3
    movea.w d3,a1
    move.b  d0,d3
    bsr     ip_write
    bra     ip_next

ip_op_86:    ; STX zp
    bsr     ip_fetch
    andi.w  #$FF,d3
    movea.w d3,a1
    move.b  d1,d3
    bsr     ip_write
    bra     ip_next

ip_op_88:    ; DEY imp
    subq.b  #1,d2
    move.w  sr,d4
    moveq   #$82,d5
    bsr     ip_flags
    bra     ip_next

ip_op_8A:    ; TXA imp
    move.b  d1,d0
    move.w  sr,d4
    moveq   #$82,d5
    bsr     ip_flags
    bra     ip_next

ip_op_8C:    ; STY abs
    bsr     ip_fetch16
    movea.w d3,a1
    move.b  d2,d3
    bsr     ip_write
    bra     ip_next

ip_op_8D:    ; STA abs
    bsr     ip_fetch16
    movea.w d3,a1
    move.b  d0,d3
    bsr     ip_write
    bra     ip_next

ip_op_8E:    ; STX abs
    bsr     ip_fetch16
    movea.w d3,a1
    move.b  d1,d3
    bsr     ip_write
    bra     ip_next

ip_op_90:    ; BCC rel
    bsr     ip_fetch
    btst    #0,rt_ip(a6)
    bne     ip_next
    ext.w   d3
    add.w   d3,d7
    bra     ip_goto

ip_op_91:    ; STA izy
    bsr     ip_fetch
    bsr     ip_zpptr
    add.w   d2,d3
    movea.w d3,a1
    move.b  d0,d3
    bsr     ip_write
    bra     ip_next

ip_op_94:    ; STY zpx
    bsr     ip_fetch
    add.b   d1,d3
    andi.w  #$FF,d3
    movea.w d3,a1
    move.b  d2,d3
    bsr     ip_write
    bra     ip_next

ip_op_95:    ; STA zpx
    bsr     ip_fetch
    add.b   d1,d3
    andi.w  #$FF,d3
    movea.w d3,a1
    move.b  d0,d3
    bsr     ip_write
    bra     ip_next

ip_op_96:    ; STX zpy
    bsr     ip_fetch
    add.b   d2,d3
    andi.w  #$FF,d3
    movea.w d3,a1
    move.b  d1,d3
    bsr     ip_write
    bra     ip_next

ip_op_98:    ; TYA imp
    move.b  d2,d0
    move.w  sr,d4
    moveq   #$82,d5
    bsr     ip_flags
    bra     ip_next

ip_op_99:    ; STA aby
    bsr     ip_fetch16
    add.w   d2,d3
    movea.w d3,a1
    move.b  d0,d3
    bsr     ip_write
    bra     ip_next

ip_op_9A:    ; TXS imp
    lea     nes_ram+$101,a2
    adda.w  d1,a2
    bra     ip_next

ip_op_9D:    ; STA abx
    bsr     ip_fetch16
    add.w   d1,d3
    movea.w d3,a1
    move.b  d0,d3
    bsr     ip_write
    bra     ip_next

ip_op_A0:    ; LDY imm
    bsr     ip_fetch
    move.b  d3,d2
    move.w  sr,d4
    moveq   #$82,d5
    bsr     ip_flags
    bra     ip_next

ip_op_A1:    ; LDA izx
    bsr     ip_fetch
    add.b   d1,d3
    bsr     ip_zpptr
    movea.w d3,a1
    bsr     ip_read
    move.b  d3,d0
    move.w  sr,d4
    moveq   #$82,d5
    bsr     ip_flags
    bra     ip_next

ip_op_A2:    ; LDX imm
    bsr     ip_fetch
    move.b  d3,d1
    move.w  sr,d4
    moveq   #$82,d5
    bsr     ip_flags
    bra     ip_next

ip_op_A4:    ; LDY zp
    bsr     ip_fetch
    andi.w  #$FF,d3
    movea.w d3,a1
    bsr     ip_read
    move.b  d3,d2
    move.w  sr,d4
    moveq   #$82,d5
    bsr     ip_flags
    bra     ip_next

ip_op_A5:    ; LDA zp
    bsr     ip_fetch
    andi.w  #$FF,d3
    movea.w d3,a1
    bsr     ip_read
    move.b  d3,d0
    move.w  sr,d4
    moveq   #$82,d5
    bsr     ip_flags
    bra     ip_next

ip_op_A6:    ; LDX zp
    bsr     ip_fetch
    andi.w  #$FF,d3
    movea.w d3,a1
    bsr     ip_read
    move.b  d3,d1
    move.w  sr,d4
    moveq   #$82,d5
    bsr     ip_flags
    bra     ip_next

ip_op_A8:    ; TAY imp
    move.b  d0,d2
    move.w  sr,d4
    moveq   #$82,d5
    bsr     ip_flags
    bra     ip_next

ip_op_A9:    ; LDA imm
    bsr     ip_fetch
    move.b  d3,d0
    move.w  sr,d4
    moveq   #$82,d5
    bsr     ip_flags
    bra     ip_next

ip_op_AA:    ; TAX imp
    move.b  d0,d1
    move.w  sr,d4
    moveq   #$82,d5
    bsr     ip_flags
    bra     ip_next

ip_op_AC:    ; LDY abs
    bsr     ip_fetch16
    movea.w d3,a1
    bsr     ip_read
    move.b  d3,d2
    move.w  sr,d4
    moveq   #$82,d5
    bsr     ip_flags
    bra     ip_next

ip_op_AD:    ; LDA abs
    bsr     ip_fetch16
    movea.w d3,a1
    bsr     ip_read
    move.b  d3,d0
    move.w  sr,d4
    moveq   #$82,d5
    bsr     ip_flags
    bra     ip_next

ip_op_AE:    ; LDX abs
    bsr     ip_fetch16
    movea.w d3,a1
    bsr     ip_read
    move.b  d3,d1
    move.w  sr,d4
    moveq   #$82,d5
    bsr     ip_flags
    bra     ip_next

ip_op_B0:    ; BCS rel
    bsr     ip_fetch
    btst    #0,rt_ip(a6)
    beq     ip_next
    ext.w   d3
    add.w   d3,d7
    bra     ip_goto

ip_op_B1:    ; LDA izy
    bsr     ip_fetch
    bsr     ip_zpptr
    add.w   d2,d3
    movea.w d3,a1
    bsr     ip_read
    move.b  d3,d0
    move.w  sr,d4
    moveq   #$82,d5
    bsr     ip_flags
    bra     ip_next

ip_op_B4:    ; LDY zpx
    bsr     ip_fetch
    add.b   d1,d3
    andi.w  #$FF,d3
    movea.w d3,a1
    bsr     ip_read
    move.b  d3,d2
    move.w  sr,d4
    moveq   #$82,d5
    bsr     ip_flags
    bra     ip_next

ip_op_B5:    ; LDA zpx
    bsr     ip_fetch
    add.b   d1,d3
    andi.w  #$FF,d3
    movea.w d3,a1
    bsr     ip_read
    move.b  d3,d0
    move.w  sr,d4
    moveq   #$82,d5
    bsr     ip_flags
    bra     ip_next

ip_op_B6:    ; LDX zpy
    bsr     ip_fetch
    add.b   d2,d3
    andi.w  #$FF,d3
    movea.w d3,a1
    bsr     ip_read
    move.b  d3,d1
    move.w  sr,d4
    moveq   #$82,d5
    bsr     ip_flags
    bra     ip_next

ip_op_B8:    ; CLV imp
    andi.b  #$BF,rt_ip(a6)
    bra     ip_next

ip_op_B9:    ; LDA aby
    bsr     ip_fetch16
    add.w   d2,d3
    movea.w d3,a1
    bsr     ip_read
    move.b  d3,d0
    move.w  sr,d4
    moveq   #$82,d5
    bsr     ip_flags
    bra     ip_next

ip_op_BA:    ; TSX imp
    move.l  a2,d1
    subi.l  #nes_ram+$101,d1
    andi.l  #$FF,d1
    tst.b   d1
    move.w  sr,d4
    moveq   #$82,d5
    bsr     ip_flags
    bra     ip_next

ip_op_BC:    ; LDY abx
    bsr     ip_fetch16
    add.w   d1,d3
    movea.w d3,a1
    bsr     ip_read
    move.b  d3,d2
    move.w  sr,d4
    moveq   #$82,d5
    bsr     ip_flags
    bra     ip_next

ip_op_BD:    ; LDA abx
    bsr     ip_fetch16
    add.w   d1,d3
    movea.w d3,a1
    bsr     ip_read
    move.b  d3,d0
    move.w  sr,d4
    moveq   #$82,d5
    bsr     ip_flags
    bra     ip_next

ip_op_BE:    ; LDX aby
    bsr     ip_fetch16
    add.w   d2,d3
    movea.w d3,a1
    bsr     ip_read
    move.b  d3,d1
    move.w  sr,d4
    moveq   #$82,d5
    bsr     ip_flags
    bra     ip_next

ip_op_C0:    ; CPY imm
    bsr     ip_fetch
    move.b  d2,d4
    sub.b   d3,d4
    move.w  sr,d4
    eori.b  #1,d4
    moveq   #$83,d5
    bsr     ip_flags
    bra     ip_next

ip_op_C1:    ; CMP izx
    bsr     ip_fetch
    add.b   d1,d3
    bsr     ip_zpptr
    movea.w d3,a1
    bsr     ip_read
    move.b  d0,d4
    sub.b   d3,d4
    move.w  sr,d4
    eori.b  #1,d4
    moveq   #$83,d5
    bsr     ip_flags
    bra     ip_next

ip_op_C4:    ; CPY zp
    bsr     ip_fetch
    andi.w  #$FF,d3
    movea.w d3,a1
    bsr     ip_read
    move.b  d2,d4
    sub.b   d3,d4
    move.w  sr,d4
    eori.b  #1,d4
    moveq   #$83,d5
    bsr     ip_flags
    bra     ip_next

ip_op_C5:    ; CMP zp
    bsr     ip_fetch
    andi.w  #$FF,d3
    movea.w d3,a1
    bsr     ip_read
    move.b  d0,d4
    sub.b   d3,d4
    move.w  sr,d4
    eori.b  #1,d4
    moveq   #$83,d5
    bsr     ip_flags
    bra     ip_next

ip_op_C6:    ; DEC zp
    bsr     ip_fetch
    andi.w  #$FF,d3
    movea.w d3,a1
    move.l  a1,-(sp)
    bsr     ip_read
    subq.b  #1,d3
    move.w  sr,d4
    moveq   #$82,d5
    bsr     ip_flags
    movea.l (sp)+,a1
    bsr     ip_write
    bra     ip_next

ip_op_C8:    ; INY imp
    addq.b  #1,d2
    move.w  sr,d4
    moveq   #$82,d5
    bsr     ip_flags
    bra     ip_next

ip_op_C9:    ; CMP imm
    bsr     ip_fetch
    move.b  d0,d4
    sub.b   d3,d4
    move.w  sr,d4
    eori.b  #1,d4
    moveq   #$83,d5
    bsr     ip_flags
    bra     ip_next

ip_op_CA:    ; DEX imp
    subq.b  #1,d1
    move.w  sr,d4
    moveq   #$82,d5
    bsr     ip_flags
    bra     ip_next

ip_op_CC:    ; CPY abs
    bsr     ip_fetch16
    movea.w d3,a1
    bsr     ip_read
    move.b  d2,d4
    sub.b   d3,d4
    move.w  sr,d4
    eori.b  #1,d4
    moveq   #$83,d5
    bsr     ip_flags
    bra     ip_next

ip_op_CD:    ; CMP abs
    bsr     ip_fetch16
    movea.w d3,a1
    bsr     ip_read
    move.b  d0,d4
    sub.b   d3,d4
    move.w  sr,d4
    eori.b  #1,d4
    moveq   #$83,d5
    bsr     ip_flags
    bra     ip_next

ip_op_CE:    ; DEC abs
    bsr     ip_fetch16
    movea.w d3,a1
    move.l  a1,-(sp)
    bsr     ip_read
    subq.b  #1,d3
    move.w  sr,d4
    moveq   #$82,d5
    bsr     ip_flags
    movea.l (sp)+,a1
    bsr     ip_write
    bra     ip_next

ip_op_D0:    ; BNE rel
    bsr     ip_fetch
    btst    #1,rt_ip(a6)
    bne     ip_next
    ext.w   d3
    add.w   d3,d7
    bra     ip_goto

ip_op_D1:    ; CMP izy
    bsr     ip_fetch
    bsr     ip_zpptr
    add.w   d2,d3
    movea.w d3,a1
    bsr     ip_read
    move.b  d0,d4
    sub.b   d3,d4
    move.w  sr,d4
    eori.b  #1,d4
    moveq   #$83,d5
    bsr     ip_flags
    bra     ip_next

ip_op_D5:    ; CMP zpx
    bsr     ip_fetch
    add.b   d1,d3
    andi.w  #$FF,d3
    movea.w d3,a1
    bsr     ip_read
    move.b  d0,d4
    sub.b   d3,d4
    move.w  sr,d4
    eori.b  #1,d4
    moveq   #$83,d5
    bsr     ip_flags
    bra     ip_next

ip_op_D6:    ; DEC zpx
    bsr     ip_fetch
    add.b   d1,d3
    andi.w  #$FF,d3
    movea.w d3,a1
    move.l  a1,-(sp)
    bsr     ip_read
    subq.b  #1,d3
    move.w  sr,d4
    moveq   #$82,d5
    bsr     ip_flags
    movea.l (sp)+,a1
    bsr     ip_write
    bra     ip_next

ip_op_D8:    ; CLD imp
    andi.b  #$F7,rt_ip(a6)
    bra     ip_next

ip_op_D9:    ; CMP aby
    bsr     ip_fetch16
    add.w   d2,d3
    movea.w d3,a1
    bsr     ip_read
    move.b  d0,d4
    sub.b   d3,d4
    move.w  sr,d4
    eori.b  #1,d4
    moveq   #$83,d5
    bsr     ip_flags
    bra     ip_next

ip_op_DD:    ; CMP abx
    bsr     ip_fetch16
    add.w   d1,d3
    movea.w d3,a1
    bsr     ip_read
    move.b  d0,d4
    sub.b   d3,d4
    move.w  sr,d4
    eori.b  #1,d4
    moveq   #$83,d5
    bsr     ip_flags
    bra     ip_next

ip_op_DE:    ; DEC abx
    bsr     ip_fetch16
    add.w   d1,d3
    movea.w d3,a1
    move.l  a1,-(sp)
    bsr     ip_read
    subq.b  #1,d3
    move.w  sr,d4
    moveq   #$82,d5
    bsr     ip_flags
    movea.l (sp)+,a1
    bsr     ip_write
    bra     ip_next

ip_op_E0:    ; CPX imm
    bsr     ip_fetch
    move.b  d1,d4
    sub.b   d3,d4
    move.w  sr,d4
    eori.b  #1,d4
    moveq   #$83,d5
    bsr     ip_flags
    bra     ip_next

ip_op_E1:    ; SBC izx
    bsr     ip_fetch
    add.b   d1,d3
    bsr     ip_zpptr
    movea.w d3,a1
    bsr     ip_read
    bsr     ip_nc2x
    subx.b  d3,d0
    move.w  sr,d4
    andi.w  #$13,d4
    eori.b  #1,d4
    tst.b   d0
    move.w  sr,d5
    andi.w  #$0C,d5
    or.w    d5,d4
    moveq   #$C3,d5
    bsr     ip_flags
    bra     ip_next

ip_op_E4:    ; CPX zp
    bsr     ip_fetch
    andi.w  #$FF,d3
    movea.w d3,a1
    bsr     ip_read
    move.b  d1,d4
    sub.b   d3,d4
    move.w  sr,d4
    eori.b  #1,d4
    moveq   #$83,d5
    bsr     ip_flags
    bra     ip_next

ip_op_E5:    ; SBC zp
    bsr     ip_fetch
    andi.w  #$FF,d3
    movea.w d3,a1
    bsr     ip_read
    bsr     ip_nc2x
    subx.b  d3,d0
    move.w  sr,d4
    andi.w  #$13,d4
    eori.b  #1,d4
    tst.b   d0
    move.w  sr,d5
    andi.w  #$0C,d5
    or.w    d5,d4
    moveq   #$C3,d5
    bsr     ip_flags
    bra     ip_next

ip_op_E6:    ; INC zp
    bsr     ip_fetch
    andi.w  #$FF,d3
    movea.w d3,a1
    move.l  a1,-(sp)
    bsr     ip_read
    addq.b  #1,d3
    move.w  sr,d4
    moveq   #$82,d5
    bsr     ip_flags
    movea.l (sp)+,a1
    bsr     ip_write
    bra     ip_next

ip_op_E8:    ; INX imp
    addq.b  #1,d1
    move.w  sr,d4
    moveq   #$82,d5
    bsr     ip_flags
    bra     ip_next

ip_op_E9:    ; SBC imm
    bsr     ip_fetch
    bsr     ip_nc2x
    subx.b  d3,d0
    move.w  sr,d4
    andi.w  #$13,d4
    eori.b  #1,d4
    tst.b   d0
    move.w  sr,d5
    andi.w  #$0C,d5
    or.w    d5,d4
    moveq   #$C3,d5
    bsr     ip_flags
    bra     ip_next

ip_op_EA:    ; NOP imp
    bra     ip_next

ip_op_EC:    ; CPX abs
    bsr     ip_fetch16
    movea.w d3,a1
    bsr     ip_read
    move.b  d1,d4
    sub.b   d3,d4
    move.w  sr,d4
    eori.b  #1,d4
    moveq   #$83,d5
    bsr     ip_flags
    bra     ip_next

ip_op_ED:    ; SBC abs
    bsr     ip_fetch16
    movea.w d3,a1
    bsr     ip_read
    bsr     ip_nc2x
    subx.b  d3,d0
    move.w  sr,d4
    andi.w  #$13,d4
    eori.b  #1,d4
    tst.b   d0
    move.w  sr,d5
    andi.w  #$0C,d5
    or.w    d5,d4
    moveq   #$C3,d5
    bsr     ip_flags
    bra     ip_next

ip_op_EE:    ; INC abs
    bsr     ip_fetch16
    movea.w d3,a1
    move.l  a1,-(sp)
    bsr     ip_read
    addq.b  #1,d3
    move.w  sr,d4
    moveq   #$82,d5
    bsr     ip_flags
    movea.l (sp)+,a1
    bsr     ip_write
    bra     ip_next

ip_op_F0:    ; BEQ rel
    bsr     ip_fetch
    btst    #1,rt_ip(a6)
    beq     ip_next
    ext.w   d3
    add.w   d3,d7
    bra     ip_goto

ip_op_F1:    ; SBC izy
    bsr     ip_fetch
    bsr     ip_zpptr
    add.w   d2,d3
    movea.w d3,a1
    bsr     ip_read
    bsr     ip_nc2x
    subx.b  d3,d0
    move.w  sr,d4
    andi.w  #$13,d4
    eori.b  #1,d4
    tst.b   d0
    move.w  sr,d5
    andi.w  #$0C,d5
    or.w    d5,d4
    moveq   #$C3,d5
    bsr     ip_flags
    bra     ip_next

ip_op_F5:    ; SBC zpx
    bsr     ip_fetch
    add.b   d1,d3
    andi.w  #$FF,d3
    movea.w d3,a1
    bsr     ip_read
    bsr     ip_nc2x
    subx.b  d3,d0
    move.w  sr,d4
    andi.w  #$13,d4
    eori.b  #1,d4
    tst.b   d0
    move.w  sr,d5
    andi.w  #$0C,d5
    or.w    d5,d4
    moveq   #$C3,d5
    bsr     ip_flags
    bra     ip_next

ip_op_F6:    ; INC zpx
    bsr     ip_fetch
    add.b   d1,d3
    andi.w  #$FF,d3
    movea.w d3,a1
    move.l  a1,-(sp)
    bsr     ip_read
    addq.b  #1,d3
    move.w  sr,d4
    moveq   #$82,d5
    bsr     ip_flags
    movea.l (sp)+,a1
    bsr     ip_write
    bra     ip_next

ip_op_F8:    ; SED imp
    ori.b   #$08,rt_ip(a6)
    bra     ip_next

ip_op_F9:    ; SBC aby
    bsr     ip_fetch16
    add.w   d2,d3
    movea.w d3,a1
    bsr     ip_read
    bsr     ip_nc2x
    subx.b  d3,d0
    move.w  sr,d4
    andi.w  #$13,d4
    eori.b  #1,d4
    tst.b   d0
    move.w  sr,d5
    andi.w  #$0C,d5
    or.w    d5,d4
    moveq   #$C3,d5
    bsr     ip_flags
    bra     ip_next

ip_op_FD:    ; SBC abx
    bsr     ip_fetch16
    add.w   d1,d3
    movea.w d3,a1
    bsr     ip_read
    bsr     ip_nc2x
    subx.b  d3,d0
    move.w  sr,d4
    andi.w  #$13,d4
    eori.b  #1,d4
    tst.b   d0
    move.w  sr,d5
    andi.w  #$0C,d5
    or.w    d5,d4
    moveq   #$C3,d5
    bsr     ip_flags
    bra     ip_next

ip_op_FE:    ; INC abx
    bsr     ip_fetch16
    add.w   d1,d3
    movea.w d3,a1
    move.l  a1,-(sp)
    bsr     ip_read
    addq.b  #1,d3
    move.w  sr,d4
    moveq   #$82,d5
    bsr     ip_flags
    movea.l (sp)+,a1
    bsr     ip_write
    bra     ip_next

    .long
ip_table:
    dc.l    ip_op_00
    dc.l    ip_op_01
    dc.l    ip_bad
    dc.l    ip_bad
    dc.l    ip_bad
    dc.l    ip_op_05
    dc.l    ip_op_06
    dc.l    ip_bad
    dc.l    ip_op_08
    dc.l    ip_op_09
    dc.l    ip_op_0A
    dc.l    ip_bad
    dc.l    ip_bad
    dc.l    ip_op_0D
    dc.l    ip_op_0E
    dc.l    ip_bad
    dc.l    ip_op_10
    dc.l    ip_op_11
    dc.l    ip_bad
    dc.l    ip_bad
    dc.l    ip_bad
    dc.l    ip_op_15
    dc.l    ip_op_16
    dc.l    ip_bad
    dc.l    ip_op_18
    dc.l    ip_op_19
    dc.l    ip_bad
    dc.l    ip_bad
    dc.l    ip_bad
    dc.l    ip_op_1D
    dc.l    ip_op_1E
    dc.l    ip_bad
    dc.l    ip_op_20
    dc.l    ip_op_21
    dc.l    ip_bad
    dc.l    ip_bad
    dc.l    ip_op_24
    dc.l    ip_op_25
    dc.l    ip_op_26
    dc.l    ip_bad
    dc.l    ip_op_28
    dc.l    ip_op_29
    dc.l    ip_op_2A
    dc.l    ip_bad
    dc.l    ip_op_2C
    dc.l    ip_op_2D
    dc.l    ip_op_2E
    dc.l    ip_bad
    dc.l    ip_op_30
    dc.l    ip_op_31
    dc.l    ip_bad
    dc.l    ip_bad
    dc.l    ip_bad
    dc.l    ip_op_35
    dc.l    ip_op_36
    dc.l    ip_bad
    dc.l    ip_op_38
    dc.l    ip_op_39
    dc.l    ip_bad
    dc.l    ip_bad
    dc.l    ip_bad
    dc.l    ip_op_3D
    dc.l    ip_op_3E
    dc.l    ip_bad
    dc.l    ip_op_40
    dc.l    ip_op_41
    dc.l    ip_bad
    dc.l    ip_bad
    dc.l    ip_bad
    dc.l    ip_op_45
    dc.l    ip_op_46
    dc.l    ip_bad
    dc.l    ip_op_48
    dc.l    ip_op_49
    dc.l    ip_op_4A
    dc.l    ip_bad
    dc.l    ip_op_4C
    dc.l    ip_op_4D
    dc.l    ip_op_4E
    dc.l    ip_bad
    dc.l    ip_op_50
    dc.l    ip_op_51
    dc.l    ip_bad
    dc.l    ip_bad
    dc.l    ip_bad
    dc.l    ip_op_55
    dc.l    ip_op_56
    dc.l    ip_bad
    dc.l    ip_op_58
    dc.l    ip_op_59
    dc.l    ip_bad
    dc.l    ip_bad
    dc.l    ip_bad
    dc.l    ip_op_5D
    dc.l    ip_op_5E
    dc.l    ip_bad
    dc.l    ip_op_60
    dc.l    ip_op_61
    dc.l    ip_bad
    dc.l    ip_bad
    dc.l    ip_bad
    dc.l    ip_op_65
    dc.l    ip_op_66
    dc.l    ip_bad
    dc.l    ip_op_68
    dc.l    ip_op_69
    dc.l    ip_op_6A
    dc.l    ip_bad
    dc.l    ip_op_6C
    dc.l    ip_op_6D
    dc.l    ip_op_6E
    dc.l    ip_bad
    dc.l    ip_op_70
    dc.l    ip_op_71
    dc.l    ip_bad
    dc.l    ip_bad
    dc.l    ip_bad
    dc.l    ip_op_75
    dc.l    ip_op_76
    dc.l    ip_bad
    dc.l    ip_op_78
    dc.l    ip_op_79
    dc.l    ip_bad
    dc.l    ip_bad
    dc.l    ip_bad
    dc.l    ip_op_7D
    dc.l    ip_op_7E
    dc.l    ip_bad
    dc.l    ip_bad
    dc.l    ip_op_81
    dc.l    ip_bad
    dc.l    ip_bad
    dc.l    ip_op_84
    dc.l    ip_op_85
    dc.l    ip_op_86
    dc.l    ip_bad
    dc.l    ip_op_88
    dc.l    ip_bad
    dc.l    ip_op_8A
    dc.l    ip_bad
    dc.l    ip_op_8C
    dc.l    ip_op_8D
    dc.l    ip_op_8E
    dc.l    ip_bad
    dc.l    ip_op_90
    dc.l    ip_op_91
    dc.l    ip_bad
    dc.l    ip_bad
    dc.l    ip_op_94
    dc.l    ip_op_95
    dc.l    ip_op_96
    dc.l    ip_bad
    dc.l    ip_op_98
    dc.l    ip_op_99
    dc.l    ip_op_9A
    dc.l    ip_bad
    dc.l    ip_bad
    dc.l    ip_op_9D
    dc.l    ip_bad
    dc.l    ip_bad
    dc.l    ip_op_A0
    dc.l    ip_op_A1
    dc.l    ip_op_A2
    dc.l    ip_bad
    dc.l    ip_op_A4
    dc.l    ip_op_A5
    dc.l    ip_op_A6
    dc.l    ip_bad
    dc.l    ip_op_A8
    dc.l    ip_op_A9
    dc.l    ip_op_AA
    dc.l    ip_bad
    dc.l    ip_op_AC
    dc.l    ip_op_AD
    dc.l    ip_op_AE
    dc.l    ip_bad
    dc.l    ip_op_B0
    dc.l    ip_op_B1
    dc.l    ip_bad
    dc.l    ip_bad
    dc.l    ip_op_B4
    dc.l    ip_op_B5
    dc.l    ip_op_B6
    dc.l    ip_bad
    dc.l    ip_op_B8
    dc.l    ip_op_B9
    dc.l    ip_op_BA
    dc.l    ip_bad
    dc.l    ip_op_BC
    dc.l    ip_op_BD
    dc.l    ip_op_BE
    dc.l    ip_bad
    dc.l    ip_op_C0
    dc.l    ip_op_C1
    dc.l    ip_bad
    dc.l    ip_bad
    dc.l    ip_op_C4
    dc.l    ip_op_C5
    dc.l    ip_op_C6
    dc.l    ip_bad
    dc.l    ip_op_C8
    dc.l    ip_op_C9
    dc.l    ip_op_CA
    dc.l    ip_bad
    dc.l    ip_op_CC
    dc.l    ip_op_CD
    dc.l    ip_op_CE
    dc.l    ip_bad
    dc.l    ip_op_D0
    dc.l    ip_op_D1
    dc.l    ip_bad
    dc.l    ip_bad
    dc.l    ip_bad
    dc.l    ip_op_D5
    dc.l    ip_op_D6
    dc.l    ip_bad
    dc.l    ip_op_D8
    dc.l    ip_op_D9
    dc.l    ip_bad
    dc.l    ip_bad
    dc.l    ip_bad
    dc.l    ip_op_DD
    dc.l    ip_op_DE
    dc.l    ip_bad
    dc.l    ip_op_E0
    dc.l    ip_op_E1
    dc.l    ip_bad
    dc.l    ip_bad
    dc.l    ip_op_E4
    dc.l    ip_op_E5
    dc.l    ip_op_E6
    dc.l    ip_bad
    dc.l    ip_op_E8
    dc.l    ip_op_E9
    dc.l    ip_op_EA
    dc.l    ip_bad
    dc.l    ip_op_EC
    dc.l    ip_op_ED
    dc.l    ip_op_EE
    dc.l    ip_bad
    dc.l    ip_op_F0
    dc.l    ip_op_F1
    dc.l    ip_bad
    dc.l    ip_bad
    dc.l    ip_bad
    dc.l    ip_op_F5
    dc.l    ip_op_F6
    dc.l    ip_bad
    dc.l    ip_op_F8
    dc.l    ip_op_F9
    dc.l    ip_bad
    dc.l    ip_bad
    dc.l    ip_bad
    dc.l    ip_op_FD
    dc.l    ip_op_FE
    dc.l    ip_bad

    .bss
    .long
ip_log:         ds.b    128
ip_log_pos:     ds.w    1
    .long
ip_base:        ds.l    1              ; pile 6502 (a2) à l'entrée de l'interpréteur
    .long
    .text
