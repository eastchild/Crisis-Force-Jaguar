;; Entrée de la cartouche ($802000, après l'en-tête Univ.bin) : recopie
;; l'image du programme (texte + données, rangée en $802100) en $4000 et
;; la lance. La BSS est effacée par Start (main.s).
;; img_size est renseigné par build.py (4 derniers octets).
    .include "JAGUAR.INC"
    .text
    .68000
boot::
    move.w  #$2700,sr
    lea     $3FF0,a7
    ;; L'OP suit encore la liste du boot ROM, que la copie va écraser : il
    ;; passe d'abord sur notre STOP en $3FF8 (RAM basse, aligné phrase, hors
    ;; de la copie et de la pile). OLP est écrit par le GPU (le 68000 ne doit
    ;; pas l'écrire) : boot_olp, chargé en RAM GPU, l'écrit puis s'arrête.
    move.l  #$00070007,G_END
    clr.l   $3FF8
    move.l  #4,$3FFC
    lea     boot_olp_img(pc),a0
    lea     G_RAM,a1
    moveq   #((boot_olp_end-boot_olp)+3)/4-1,d0
.lgpu:
    move.l  (a0)+,(a1)+
    dbra    d0,.lgpu
    move.l  #boot_olp,G_PC
    move.l  #RISCGO,G_CTRL
.lwait:
    move.l  G_CTRL,d0
    btst    #0,d0
    bne.s   .lwait
    lea     $802100,a0
    lea     $4000,a1
    move.l  img_size(pc),d0
    addq.l  #3,d0
    lsr.l   #2,d0
.lcopy:
    move.l  (a0)+,(a1)+
    subq.l  #1,d0
    bne.s   .lcopy
    jmp     $4000

    .long
boot_olp_img:
    .gpu
    .org    G_RAM
boot_olp:
    movei   #$3FF80000,r0              ; $3FF8, mots échangés
    movei   #OLP,r2
    store   r0,(r2)
    movei   #G_CTRL,r1
    moveq   #0,r3
    store   r3,(r1)                    ; le GPU s'arrête lui-même
    nop
    nop
    .long
boot_olp_end:
    .68000
    .long
img_size::
    dc.l    0
