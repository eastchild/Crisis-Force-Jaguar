;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Crisis Force - Portage Atari Jaguar
;; main.s - programme 68000 : matériel Jaguar autour du jeu NES recompilé
;;
;; Le code 6502 de la ROM est recompilé en 68000 (tools/recomp6502.py ->
;; nes_code.s) et s'exécute tel quel sur le 68000. Ce fichier fournit la
;; « machine NES » côté Jaguar :
;;   - VBL Jaguar  -> NMI 6502 (logique du jeu, mises à jour PPU) ;
;;   - PIT de Tom  -> IRQ du mapper VRC4 (driver son 4 fois par frame) ;
;;   - GPU (gpu.s) -> rendu des nametables et de l'OAM dans des bitmaps 8 bpp ;
;;   - DSP (dsp.s) -> émulation de l'APU (son) ;
;;   - Object Processor : décor (2 nametables), sprites devant/derrière,
;;     CLUT = palette NES courante.
;;
;; Build : rmac -fb main.s, rln -a 4000 -> CrisisForce.abs (build.py)
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

    .include "JAGUAR.INC"
    .include "nes_jag.inc"

PERF_W          equ 192                  ; largeur du HUD perfhud (pixels, 24 caractères)
BOOT_STOP       equ $3FF8                ; objet STOP du démarrage (boot.s, Start)
RT_JAGUAR       equ 1                  ; nes_runtime.s : jag_irq_changed (PIT), jag_halt (erreur)

    .68000

;; Début de la BSS (avant celle du runtime inclus plus bas) : effacée au démarrage
    .bss
    .long
bss_start:
    .text

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Démarrage
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

Start:
    move.w  #$2700,sr
    ;; Retour inattendu au point d'entrée (saut perdu) : on le signale
    tst.l   boot_count
    beq.s   .lfirst
    move.l  a7,exc_frame
    move.l  (a7),exc_frame+4
    move.l  4(a7),exc_frame+8
    move.w  #$FF,exc_vec
    move.l  #INITSTACK,a7
    bra     exc_halt
.lfirst:
    addq.l  #1,boot_count
    move.l  #INITSTACK,a7
    ;; (pas d'écriture de 0 dans G_CTRL / D_CTRL : arrêter un RISC depuis le
    ;; 68000 n'est pas fiable ; le GPU et le DSP sont au repos à l'amorçage)
    move.l  #$00070007,G_END
    move.l  #$00070007,D_END
    move.w  #$100,JOYSTICK             ; son activé (bit 8)
    ;; Avant toute autre écriture en RAM (la liste du boot ROM est en $1000) :
    ;; OP sur notre STOP en RAM basse (posé aussi par boot.s) tant que la
    ;; liste n'est pas prête ; OLP écrit par le GPU (GpuSetOlp)
    moveq   #0,d0
    move.l  d0,BOOT_STOP
    move.l  #4,BOOT_STOP+4
    move.l  #BOOT_STOP,d0
    bsr     GpuSetOlp
    bsr     InstallExceptions
    move.w  #0,INT1
    ;; La RAM n'est pas à zéro à la mise sous tension : BSS effacée
    lea     bss_start,a0
    move.l  #bss_end,d0
    sub.l   a0,d0
    lsr.l   #2,d0
.lclrbss:
    clr.l   (a0)+
    subq.l  #1,d0
    bne.s   .lclrbss

    bsr     InitVideo
    .if ^^defined JAGDEBUG
    move.w  #$F800,BG                  ; rouge : avant l'effacement des tampons
    .endif
    bsr     ClearBuffers
    .if ^^defined JAGDEBUG
    move.w  #$FFC0,BG                  ; jaune : tampons effacés
    .endif
    lea     rt_vars,a6
    clr.b   rt_ppuctrl(a6)
    clr.b   rt_ppumask(a6)

    ;; Première liste d'objets (vide : STOP) ; OLP pointé dessus par le GPU,
    ;; avant que le programme GPU ne soit chargé (ensuite OLP ne change plus :
    ;; la liste est mise à jour sur place)
    .if ^^defined DIAGOL
    lea     diag_bmp,a0                ; un point tous les 8 pixels, une ligne sur 8
    move.w  #NES_HEIGHT-1,d1
.ldg_y:
    moveq   #0,d0
    move.w  d1,d2
    andi.w  #7,d2
    bne.s   .ldg_e
    move.l  #$FE000000,d0
.ldg_e:
    moveq   #31,d2                     ; 32 x 8 octets = une ligne de 256 pixels
.ldg_x:
    move.l  d0,(a0)+
    move.l  d0,(a0)+
    dbra    d2,.ldg_x
    dbra    d1,.ldg_y
    .endif
    move.l  #ObjectListM0,ol_wbuf
    move.l  #ObjectListM0,ol_master
    bsr     BuildObjectList
    move.w  ol_wcount,ol_count
    st      ol_full
    bsr     RefreshOL
    move.l  #0,ObjectList+OL_STOP      ; STOP de garde (RefreshOL ne le recopie pas)
    move.l  #4,ObjectList+OL_STOP+4
    move.l  #ObjectList,d0
    bsr     GpuSetOlp
    bsr     InitGPU
    bsr     InitDSP
    .if ^^defined JAGDEBUG
    move.w  #$003F,BG                  ; vert : GPU et DSP lancés
    .endif
    move.w  #NES_VMODE,VMODE
    move.l  #jag_int,LEVEL0
    move.w  a_vde,d0
    ori.w   #1,d0
    move.w  d0,VI
    move.w  #C_VIDENA,int_enables
    move.w  #C_VIDENA,INT1

    ;; Registres et état du code 6502 (en dernier : X/Y doivent rester propres)
    bsr     rt_init
    .if ^^defined JAGDEBUG
    move.w  #$FFFF,BG                  ; blanc : départ du code 6502
    .endif
    move.w  #$2000,sr

    ;; Le jeu démarre au vecteur RESET de la ROM et ne revient jamais
    jmp     NES_RESET_ENTRY

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Vidéo (d'après le startup Atari) : 320x240 RGB16, NES centrée
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

XMARGIN         equ 8               ; pixels affichés avant la zone visible

InitVideo:
    move.w  CONFIG,d0
    andi.w  #VIDTYPE,d0
    beq.s   .pal
    move.w  #525,frame_hl              ; demi-lignes par image
    move.w  #NTSC_HMID,d2
    move.w  #NTSC_WIDTH,d0
    move.w  #NTSC_VMID,d6
    move.w  #NTSC_HEIGHT,d4
    bra.s   .calc
.pal:
    move.w  #625,frame_hl
    move.w  #PAL_HMID,d2
    move.w  #PAL_WIDTH,d0
    move.w  #PAL_VMID,d6
    move.w  #PAL_HEIGHT,d4
.calc:
    move.w  d0,d1
    asr.w   #1,d1
    ;; Zone visible : 1280 horloges (320 pixels Jaguar) à partir de la
    ;; première colonne visible des téléviseurs (et de BigPEmu), 176 en NTSC,
    ;; 196 en PAL. L'affichage commence XMARGIN pixels plus tôt : les objets
    ;; décalés à gauche par le défilement fin gardent un XPOS positif
    move.w  #176-(XMARGIN*NES_PIXCLK),d2
    cmpi.w  #PAL_WIDTH,d0
    bne.s   .hdb
    move.w  #196-(XMARGIN*NES_PIXCLK),d2
.hdb:
    subq.w  #1,d1
    ori.w   #$400,d1
    move.w  d1,HDE
    move.w  d2,HDB1
    move.w  d2,HDB2
    move.w  d6,d5
    sub.w   d4,d5
    move.w  d5,a_vdb
    add.w   d4,d6
    move.w  d6,a_vde
    move.w  d5,VDB
    move.w  #$FFFF,VDE
    ;; Image NES centrée dans la zone visible, en pixels (marge + 0 en
    ;; pleine largeur, + 32 en --pillarbox)
    move.w  #XMARGIN+((1280-(256*NES_PIXCLK))/(2*NES_PIXCLK)),a_xpos
    ;; Image NES (240 lignes) centrée verticalement
    move.w  d6,d0
    sub.w   d5,d0
    sub.w   #NES_HEIGHT*2,d0
    asr.w   #1,d0
    add.w   d5,d0
    andi.w  #$FFFE,d0                  ; YPOS pair (affichage non entrelacé)
    move.w  d0,a_ypos
    move.l  #0,BORD1
    move.w  #0,BG
    rts

;; Plans, sprites, cache GPU et palette à zéro
ClearBuffers:
    move.l  #-1,edge_mask
    move.l  #-1,edge_mask+4
    lea     CLUT,a1
    move.w  #255,d0
    moveq   #0,d1                      ; (pas de clr : lecture-écriture sur Tom)
.cl:
    move.w  d1,(a1)+
    dbra    d0,.cl
    .if ^^defined PERFHUD
    move.w  #$FFFF,CLUT+(253*2)        ; texte du HUD (fond : 252, noir)
    .endif
    ;; Cache des tuiles : clé impossible -> tout sera rendu au premier passage
    lea     bg_cache,a0
    move.w  #(NUM_PLANES*2*960)-1,d0
.cc:
    move.l  #-1,(a0)+
    dbra    d0,.cc
    rts

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; GPU et DSP : copie du code en RAM locale et démarrage
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

;; OLP <- d0 (adresse de la liste), écrit par le GPU : le 68000 ne doit pas
;; l'écrire (l'OP peut le lire entre ses deux mots). GPU au repos : le petit
;; programme set_olp est chargé en RAM GPU, écrit OLP et s'arrête lui-même.
GpuSetOlp:
    lea     SetOlpCode,a0
    lea     G_RAM,a1
    move.l  #((SetOlpCodeEnd-SetOlpCode)+3)/4-1,d1
.lcp:
    move.l  (a0)+,(a1)+
    dbra    d1,.lcp
    swap    d0                         ; OLP s'écrit mots échangés
    move.l  d0,olp_val
    move.l  #set_olp,G_PC
    move.l  #RISCGO,G_CTRL
.lwt:
    move.l  G_CTRL,d0
    btst    #0,d0
    bne.s   .lwt
    rts

InitGPU:
    lea     GPUCode,a0
    lea     G_RAM,a1
    move.l  #(GPUCodeEnd-GPUCode+3)/4-1,d0
.cp:
    move.l  (a0)+,(a1)+
    dbra    d0,.cp
    move.l  #gpu_start,G_PC
    move.l  #GPUGO,G_CTRL
    rts

InitDSP:
    lea     DSPCode,a0
    lea     D_RAM,a1
    move.l  #(DSPCodeEnd-DSPCode+3)/4-1,d0
.cp:
    move.l  (a0)+,(a1)+
    dbra    d0,.cp
    move.l  #dsp_start,D_PC
    move.l  #DSPGO,D_CTRL
    rts

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Interruption (niveau 0) : vidéo -> NMI, PIT -> IRQ VRC4
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

jag_int:
    movem.l d0-d7/a0-a6,-(sp)
    lea     rt_vars,a6
    .if ^^defined PERFHUD
    tst.b   idle_on                    ; 68000 réveillé de son stop (hle_idle)
    beq.s   .lpi
    sf      idle_on
    move.w  idle_vc,d0
    bsr     PerfElapsed
    add.l   d0,perf_idle_hl
.lpi:
    .endif
    move.w  INT1,d7
    move.w  d7,-(sp)
    btst    #0,d7
    beq.s   .novi
    move.w  int_enables,d0
    ori.w   #C_VIDCLR,d0
    move.w  d0,INT1
    bsr     jag_vbl
.novi:
    move.w  (sp),d7
    btst    #3,d7
    beq.s   .nopit
    move.w  int_enables,d0
    ori.w   #C_PITCLR,d0
    move.w  d0,INT1
    ;; rechargement du compteur : une période VRC4 (PitAt a programmé le PIT
    ;; pour la première interruption ; une IRQ 6502 restée en attente ne doit
    ;; pas revenir à chaque ligne)
    moveq   #0,d0
    move.b  rt_irqlatch(a6),d0
    neg.w   d0
    addi.w  #255,d0
    move.w  d0,PIT1
.nopit:
    ;; INT2 dès l'acquittement : le 68000 rend la priorité du bus au GPU et au
    ;; blitter (la garder pendant le NMI, qui dure presque une image au niveau 2,
    ;; affamait le GPU : mesuré dans JagMCP, 2 images sur 3 sautées)
    move.w  #0,INT2
    ;; Contexte du code 6502 interrompu (a2 = pile 6502...) pour rt_nmi/rt_irq
    movem.l 2(sp),d0-d7/a0-a6
    lea     rt_vars,a6
    move.w  (sp)+,d7
    ;; Les gestionnaires 6502 peuvent durer : les interruptions restent
    ;; possibles pendant leur exécution (IRQ pendant le NMI, comme sur NES)
    btst    #0,d7
    beq.s   .nonmi
    btst    #7,rt_ppuctrl(a6)
    beq.s   .nonmi
    move.w  #$2000,sr
    ;; liste d'objets de l'image que le GPU rend, avant le NMI : elle ne dépend
    ;; que de l'instantané pris à cette VBL ; construite après le NMI, elle
    ;; manquait une fois sur deux à la VBL suivante quand le NMI dure presque une
    ;; image (JagMCP, niveau 2), sans faire perdre d'images de jeu ici
    bsr     PrebuildOL
    move.b  jag_in_irq,-(sp)           ; NMI pendant une IRQ : écritures « NMI »
    sf      jag_in_irq
    bsr     rt_nmi
    move.b  (sp)+,jag_in_irq
    addq.l  #1,stat_nmi
    .if ^^defined PERFHUD
    addq.w  #1,perf_nmi                ; image de jeu terminée
    .endif
.nonmi:
    btst    #3,d7
    beq.s   .noirq
    btst    #1,rt_irqctrl(a6)
    beq.s   .noirq
    move.w  #$2000,sr
    bsr     rt_irq
.noirq:
    movem.l (sp)+,d0-d7/a0-a6
    rte

;; Début de VBL : affichage de la dernière image rendue, palette, manettes,
;; instantané de l'état PPU pour le GPU
jag_vbl:
    move.w  VC,d0                      ; repère des lignes NES (NesLine)
    andi.w  #$7FF,d0
    move.w  d0,vc_vbl
    addq.l  #1,rt_frame(a6)
    .if ^^defined PERFHUD
    bsr     PerfVbl
    .endif
    ;; Statistiques : image NES pas finie (NMI en cours), rendu GPU pas fini
    tst.b   rt_innmi(a6)
    beq.s   .lnolag
    addq.l  #1,stat_lag
.lnolag:
    move.l  gpu_busy,d1                ; RAM GPU : move.l seulement
    beq.s   .lnodrop
    addq.l  #1,stat_gpubusy
.lnodrop:
    ori.b   #$80,rt_ppustatus(a6)      ; drapeau VBL de $2002
    .if ^^defined JAGDEBUG
    bsr     JagDebugColor
    .endif
    .if ^^defined PERFHUD
    ;; build --perfhud : fond rouge = image NES en retard (NMI pas fini),
    ;; orange = rendu GPU pas fini (image sautée), noir sinon
    moveq   #0,d0
    move.l  gpu_busy,d1                ; RAM GPU : move.l seulement
    beq.s   .lph1
    move.w  #$FC00,d0                  ; orange
.lph1:
    tst.b   rt_innmi(a6)
    beq.s   .lph2
    move.w  #$F800,d0                  ; rouge
.lph2:
    move.w  d0,BG
    .endif
    ;; GPU occupé : l'image en cours de rendu reste à faire, celle-ci est
    ;; sautée (ses bandes sont oubliées) ; de même si sa liste d'objets est
    ;; en cours de préparation (PrebuildOL interrompu par la VBL)
    sf      vbl_swapped
    sf      vbl_take
    move.l  gpu_busy,d1                ; RAM GPU : move.l seulement
    bne.s   .ldropb
    tst.b   ol_building
    bne.s   .ldropl
    st      vbl_take
    ;; Image rendue par le GPU disponible : on l'affiche, avec sa liste
    ;; d'objets préparée avant le NMI (PrebuildOL). Pas prête : elle attend la
    ;; VBL suivante (HUD L). La construire ici retardait
    ;; RefreshOL d'environ 37 lignes : le haut de l'image était affiché avec
    ;; la liste de l'image précédente (déjà parcourue par l'OP), sans ses
    ;; sprites alors que le décor restait visible.
    tst.l   snap_pending
    beq.s   .lafter
    tst.b   ol_next_ready
    bne.s   .lready
    sf      vbl_take
    bra.s   .ldropl
.ldropb:
    .if ^^defined PERFHUD
    addq.w  #1,perf_bdrop              ; image sautée : GPU pas fini (HUD B)
    .endif
    bra.s   .ldrop
.ldropl:
    addq.l  #1,stat_ldrop              ; image sautée : liste pas prête
    .if ^^defined PERFHUD
    addq.w  #1,perf_ldrop              ; (HUD L)
    .endif
    bra.s   .ldrop
.lready:
    sf      ol_next_ready
    clr.l   snap_pending
    st      vbl_swapped
    addq.l  #1,stat_drawn              ; images affichées (mesures : JagMCP, MAME)
    .if ^^defined PERFHUD
    addq.w  #1,perf_drawn              ; image affichée
    .endif
    move.l  ol_wbuf,ol_master
    move.w  ol_wcount,ol_count
    st      ol_full
    bsr     TrimSpriteLayers
    bra.s   .lafter
.ldrop:
    clr.l   rlog_count
.lafter:
    ;; Liste affichée : recopiée à chaque image (l'OP modifie les objets
    ;; bitmap qu'il parcourt) ; courte, prête avant le haut de l'image
    bsr     RefreshOL
    tst.b   vbl_swapped
    beq.s   .lnoclut
    bsr     LoadClut
.lnoclut:
    ;; Nouvel instantané pour le GPU (s'il est libre)
    .if ^^defined NODRAW
    sf      vbl_take                   ; build --nodraw : le GPU ne dessine rien
    .endif
    tst.b   vbl_take
    beq.s   .lnotake
    bsr     TakeSnapshot
    move.l  #1,snap_pending
    move.l  #1,gpu_busy                ; le GPU remet à 0 quand il a fini
    .if ^^defined PERFHUD
    st      gpu_on
    move.w  vc_vbl,gpu_start_vc
    .endif
.lnotake:
    bra     ReadPads

    .if ^^defined JAGDEBUG
;; Diagnostic : fond rouge = GPU bloqué, vert = rendu terminé au moins
;; une fois, bleu clignotant = VBL vivantes
JagDebugColor:
    move.l  rt_frame(a6),d0
    andi.w  #16,d0
    lsl.w   #2,d0                      ; bleu (bits 6-10) clignotant
    move.l  gpu_busy,d1                ; RAM GPU : move.l seulement
    beq.s   .dbg1
    addq.l  #1,dbg_gpuwait
    cmpi.l  #60,dbg_gpuwait
    bcs.s   .dbg2
    ;; GPU bloqué : couleur selon la dernière étape atteinte (gpu_dbg)
    move.l  gpu_dbg,d1
    andi.w  #7,d1
    add.w   d1,d1
    lea     dbg_colors,a0
    move.w  (a0,d1.w),d0
    bra.s   .dbg2
.dbg1:
    clr.l   dbg_gpuwait
    ;; DSP : rouge si le compteur d'échantillons n'avance plus, sinon vert
    ;; d'intensité égale au volume du carré 1 (+ bleu clignotant)
    move.l  dsp_sample_count,d1
    cmp.l   dbg_dspcount,d1
    bne.s   .dbg3
    ori.w   #$F800,d0
    bra.s   .dbg2
.dbg3:
    move.l  d1,dbg_dspcount
    move.l  dsp_params+(4*3),d1        ; P_P1VOL
    andi.w  #15,d1
    lsl.w   #2,d1
    addq.w  #3,d1
    or.w    d1,d0
.dbg2:
    move.w  d0,BG
    rts
    .endif

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; build --perfhud : HUD de mesure sur console (skill « Performance on the
;; real console »), mis à jour chaque seconde (60 / 50 VBL) :
;;   J = images de jeu (NMI terminés), A = images affichées (rendues par le
;;   GPU), R = % du temps où le 68000 attend (stop de hle_idle), G = % du
;;   temps où le GPU dessine, B / L = images sautées faute de rendu GPU fini /
;;   de liste d'objets prête. Temps mesurés en demi-lignes (VC).
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
    .if ^^defined PERFHUD
;; d0.w = VC de départ -> d0.l = demi-lignes écoulées depuis (moins d'une image)
PerfElapsed:
    move.w  VC,d1
    andi.w  #$7FF,d1
    sub.w   d0,d1
    bpl.s   .lp
    add.w   frame_hl,d1
.lp:
    moveq   #0,d0
    move.w  d1,d0
    rts

;; À chaque VBL : temps GPU de l'image précédente, compte de la période
PerfVbl:
    tst.b   gpu_on
    beq.s   .lng
    move.l  gpu_busy,d1                ; RAM GPU : move.l seulement
    bne.s   .lgb
    sf      gpu_on
    move.l  gpu_end_vc,d1              ; fin du rendu (VC, écrit par le GPU)
    andi.w  #$7FF,d1
    sub.w   gpu_start_vc,d1
    bpl.s   .lgadd
    add.w   frame_hl,d1
    bra.s   .lgadd
.lgb:
    move.w  frame_hl,d1                ; encore occupé : toute l'image
    move.w  vc_vbl,gpu_start_vc
.lgadd:
    andi.l  #$FFFF,d1
    add.l   d1,perf_gpu_hl
.lng:
    addq.w  #1,perf_vbls
    moveq   #60,d0
    cmpi.w  #625,frame_hl
    bne.s   .lnt
    moveq   #50,d0
.lnt:
    cmp.w   perf_vbls,d0
    bhi.s   .lr
    bsr.s   PerfShow
.lr:
    rts

;; Texte « Jnn Ann Rnn Gnn » -> perf_bmp (16 caractères de 8 x 8, 8 bpp :
;; CLUT 253 texte, 252 fond), puis remise à zéro des compteurs
PerfShow:
    move.w  frame_hl,d2
    mulu.w  perf_vbls,d2               ; demi-lignes de la période (<= 31500)
    lea     perf_txt,a0
    move.b  #10,(a0)+                  ; J
    move.w  perf_nmi,d0
    bsr     .ldig2
    move.b  #15,(a0)+
    move.b  #11,(a0)+                  ; A
    move.w  perf_drawn,d0
    bsr     .ldig2
    move.b  #15,(a0)+
    move.b  #12,(a0)+                  ; R
    move.l  perf_idle_hl,d0
    bsr     .lpct
    bsr     .ldig2
    move.b  #15,(a0)+
    move.b  #13,(a0)+                  ; G
    move.l  perf_gpu_hl,d0
    bsr     .lpct
    bsr     .ldig2
    move.b  #15,(a0)+
    move.b  #16,(a0)+                  ; B
    move.w  perf_bdrop,d0
    bsr     .ldig2
    move.b  #15,(a0)+
    move.b  #17,(a0)+                  ; L
    move.w  perf_ldrop,d0
    bsr     .ldig2
    move.b  #15,(a0)+
    clr.w   perf_bdrop
    clr.w   perf_ldrop
    clr.w   perf_vbls
    clr.w   perf_nmi
    clr.w   perf_drawn
    clr.l   perf_idle_hl
    clr.l   perf_gpu_hl
    ;; rendu des 16 caractères
    lea     perf_txt,a0
    lea     perf_bmp,a1
    lea     perf_font,a2
    moveq   #(PERF_W/8)-1,d4
.lch:
    moveq   #0,d0
    move.b  (a0)+,d0
    lsl.w   #3,d0
    lea     (a2,d0.w),a3
    movea.l a1,a4
    moveq   #7,d3
.lrow:
    move.b  (a3)+,d1
    moveq   #7,d2
.lpx:
    add.b   d1,d1                      ; bit de gauche -> retenue
    bcs.s   .lon
    move.b  #252,(a4)+
    dbra    d2,.lpx
    bra.s   .lrend
.lon:
    move.b  #253,(a4)+
    dbra    d2,.lpx
.lrend:
    lea     256-8(a4),a4               ; ligne suivante (pas de 256 octets)
    dbra    d3,.lrow
    addq.l  #8,a1
    dbra    d4,.lch
    rts
;; d0.l demi-lignes -> d0.l = pourcentage de d2 (borné à 100)
.lpct:
    cmp.l   d2,d0
    bls.s   .lp1
    move.l  d2,d0
.lp1:
    mulu.w  #100,d0
    divu.w  d2,d0
    andi.l  #$FFFF,d0
    rts
;; d0.w -> deux chiffres (borné à 99)
.ldig2:
    andi.l  #$FFFF,d0
    cmpi.w  #99,d0
    bls.s   .ld1
    moveq   #99,d0
.ld1:
    divu.w  #10,d0
    move.b  d0,(a0)+
    swap    d0
    move.b  d0,(a0)+
    rts
    .endif

;; Liste d'objets de l'image en attente d'affichage (instantané rendu ou en
;; cours de rendu par le GPU), préparée après le NMI pour que la VBL reste
;; courte : le NMI commence plus tôt et la liste est prête avant le haut de
;; l'image. Appelé avec les interruptions permises (une VBL peut survenir :
;; ol_building).
PrebuildOL:
    tst.l   snap_pending
    beq.s   .lr
    tst.b   ol_next_ready
    bne.s   .lr
    tst.b   ol_building
    bne.s   .lr
    ;; tous les registres conservés : jag_int enchaîne avec rt_irq, qui a
    ;; besoin du contexte 6502 interrompu (a2, a4, a5, d0-d2) et de d7
    movem.l d0-d7/a0-a6,-(sp)
    bsr.s   PrepareNextOL
    movem.l (sp)+,d0-d7/a0-a6
.lr:
    rts

;; Instantané -> image à afficher (entrées de BuildObjectList et LoadClut),
;; puis sa liste d'objets dans le tampon maître libre (ol_wbuf)
PrepareNextOL:
    st      ol_building
    move.l  snap_front,disp_front
    move.l  snap_behind,disp_behind
    lea     snap_regs,a0
    lea     disp_regs,a1
    moveq   #(SNAP_REGS_SIZE/4)-1,d0
.cr:
    move.l  (a0)+,(a1)+
    dbra    d0,.cr
    move.l  snap_nbands,d1
    move.l  d1,disp_nbands
    beq.s   .lnob
    mulu    #BAND_SIZE/4,d1
    subq.w  #1,d1
    lea     snap_bands,a0
    lea     disp_bands,a1
.lcbd:
    move.l  (a0)+,(a1)+
    dbra    d1,.lcbd
.lnob:
    move.l  #ObjectListM0,d0
    cmp.l   ol_master,d0
    bne.s   .lm
    move.l  #ObjectListM1,d0
.lm:
    move.l  d0,ol_wbuf
    bsr     BuildObjectList
    st      ol_next_ready
    sf      ol_building
    rts

;; Liste maîtresse affichée -> ObjectList (lue par l'OP)
;; Liste neuve (ol_full) : copie complète ; sinon seulement la 1re phrase
;; des objets bitmap (DATA, HEIGHT), la seule que l'OP réécrit en les
;; parcourant.
RefreshOL:
    .if ^^defined DIAGOL
    move.w  #$FFC0,CLUT+(254*2)        ; magenta (grille de diagnostic)
    .endif
    movea.l ol_master,a0
    lea     ObjectList,a1
    tst.b   ol_full
    beq.s   .lpart
    sf      ol_full
    ;; Liste valide à chaque étape (l'OP peut la lire) : STOP d'abord, puis
    ;; les objets du dernier au premier (chacun lie au suivant, déjà écrit ;
    ;; phrase 1 puis phrase 0), puis la branche +8, la tête (+0) en dernier ;
    ;; chaque phrase long haut d'abord. Le STOP de garde (OL_STOP) reste.
    moveq   #0,d0
    move.w  ol_count,d0
    cmpi.w  #(OL_STOP-24)/16,d0
    bls.s   .lfn
    moveq   #(OL_STOP-24)/16,d0
.lfn:
    move.l  d0,d1
    lsl.l   #4,d1
    lea     16(a0,d1.l),a2             ; STOP de la liste maîtresse
    lea     16(a1,d1.l),a3
    move.l  (a2),(a3)
    move.l  4(a2),4(a3)
    bra.s   .lobn
.lob:
    lea     -16(a2),a2
    lea     -16(a3),a3
    move.l  8(a2),8(a3)                ; phrase 1
    move.l  12(a2),12(a3)
    move.l  (a2),(a3)                  ; phrase 0 (TYPE, LINK...)
    move.l  4(a2),4(a3)
.lobn:
    dbra    d0,.lob
    move.l  8(a0),8(a1)                ; branche +8
    move.l  12(a0),12(a1)
    move.l  (a0),(a1)                  ; tête de liste en dernier
    move.l  4(a0),4(a1)
    rts
.lpart:
    move.w  ol_count,d0
    beq.s   .lr
    subq.w  #1,d0
    lea     16(a0),a0
    lea     16(a1),a1
.lpp:
    move.l  (a0),(a1)
    move.l  4(a0),4(a1)
    lea     16(a0),a0
    lea     16(a1),a1
    dbra    d0,.lpp
.lr:
    rts

;; HUD devant les sprites : sur NES, l'ordre de l'OAM tourne à chaque image
;; ($6740 += $44) et le HUD (vies, bombes ; écrit en dernier par $AE35) passe
;; tantôt devant, tantôt derrière les autres sprites. Dans l'OAM de
;; l'instantané (affichage seulement), ses entrées (oam_hud : départ, nombre,
;; pas $44) sont mises en tête : le GPU dessine l'entrée 0 au-dessus.
HudFirst:
    moveq   #0,d0
    move.b  oam_hud+1,d0               ; n entrées
    beq.s   .lr
    cmpi.w  #8,d0
    bhi.s   .lr
    lea     snap_oam,a0
    lea     hud_pos,a1
    lea     snap_otmp,a2
    moveq   #0,d1
    move.b  oam_hud,d1                 ; index d'octet de la 1re entrée
    andi.b  #$FC,d1
    move.w  d0,d2
    subq.w  #1,d2
.lp:
    move.w  d1,(a1)+                   ; positions du HUD
    move.l  (a0,d1.w),(a2)+            ; et entrées mises de côté
    addi.b  #$44,d1
    dbra    d2,.lp
    ;; les entrées hors HUD des n premières places vont aux places du HUD
    ;; situées au-delà (autant de l'un que de l'autre)
    move.w  d0,d6
    lsl.w   #2,d6                      ; limite (octets)
    lea     hud_pos,a1
    moveq   #0,d3
.ls:
    cmp.w   d6,d3
    bcc.s   .lput
    lea     hud_pos,a3
    move.w  d0,d2
    subq.w  #1,d2
.lq:
    cmp.w   (a3)+,d3
    beq.s   .lsn                       ; déjà une entrée du HUD
    dbra    d2,.lq
.lf:
    move.w  (a1)+,d4
    cmp.w   d6,d4
    bcs.s   .lf
    move.l  (a0,d3.w),(a0,d4.w)
.lsn:
    addq.w  #4,d3
    bra.s   .ls
.lput:
    lea     snap_otmp,a2
    subq.w  #1,d0
.lw:
    move.l  (a2)+,(a0)+
    dbra    d0,.lw
.lr:
    rts

;; Copie de l'état PPU (VRAM, OAM, palette, registres) pour le GPU, et
;; choix des tampons de sprites à remplir (ceux qui ne sont pas affichés)
;; Bandes d'affichage : la dernière frame NES est décrite par rlog_bands
;; (état en début d'image + changements faits par l'IRQ en cours d'image)
TakeSnapshot:
    ;; VRAM (2 Ko) et OAM (256 octets), avant que le NMI ne les modifie.
    ;; VRAM : seulement les blocs de 64 octets écrits depuis (rt_wr_2007,
    ;; vram_dirty), plus un bloc tournant (filet si une écriture du programme
    ;; principal croise la VBL)
    move.l  vram_dirty,d0
    clr.l   vram_dirty
    moveq   #0,d1
    move.b  vram_rot,d1
    addq.b  #1,vram_rot
    andi.b  #31,d1
    bset    d1,d0
    lea     nes_vram,a0
    lea     snap_vram,a1
    moveq   #31,d6
.lv:
    lsr.l   #1,d0
    bcc.s   .lvn
    movem.l (a0),d1-d5/d7/a2-a3
    movem.l d1-d5/d7/a2-a3,(a1)
    movem.l 32(a0),d1-d5/d7/a2-a3
    movem.l d1-d5/d7/a2-a3,32(a1)
.lvn:
    lea     64(a0),a0
    lea     64(a1),a1
    dbra    d6,.lv
    lea     nes_oam,a0
    lea     snap_oam,a1
    moveq   #(256/32)-1,d0
.lo:
    movem.l (a0)+,d1-d7/a2
    movem.l d1-d7/a2,(a1)
    lea     32(a1),a1
    dbra    d0,.lo
    bsr     HudFirst
    lea     snap_regs,a1
    lea     nes_palette,a0
    moveq   #(32/4)-1,d0
.lp_:
    move.l  (a0)+,(a1)+
    dbra    d0,.lp_
    move.b  rt_ppuctrl(a6),(a1)+       ; SR_CTRL
    move.b  rt_ppumask(a6),(a1)+       ; SR_MASK
    clr.w   (a1)+                      ; (SR_SCROLLX/Y : remplacés par les bandes)
    move.b  rt_mirror(a6),(a1)+        ; SR_MIRROR
    clr.b   (a1)+
    clr.w   (a1)+
    ;; Pas d'effet de trame dans la frame : une bande, état courant
    tst.l   rlog_count
    bne.s   .lhave
    lea     rlog_bands,a0
    bsr     CaptureBand
    clr.w   B_LINE0(a0)
    move.l  #1,rlog_count
.lhave:
    move.l  rlog_count,d3
    move.l  d3,snap_nbands
    lea     rlog_bands,a0
    lea     snap_bands,a1
    moveq   #0,d4                      ; index de bande
.lcb:
    movea.l a1,a3
    moveq   #(BAND_SIZE/4)-1,d0
.lcp:
    move.l  (a0)+,(a3)+
    dbra    d0,.lcp
    ;; plan partagé par les bandes au même décor (BandPlane), fin = début
    ;; de la bande suivante
    bsr     BandPlane
    move.w  d0,B_PLANE(a1)
    move.w  #NES_HEIGHT,d0
    move.l  d4,d1
    addq.l  #1,d1
    cmp.l   d3,d1
    bcc.s   .llast
    move.w  B_LINE0(a0),d0             ; a0 = bande suivante du journal
.llast:
    move.w  d0,B_LINE1(a1)
    lea     BAND_SIZE(a1),a1
    addq.l  #1,d4
    cmp.l   d3,d4
    bcs.s   .lcb
    clr.l   rlog_count
    ;; Sprites : banques CHR de la bande 0
    lea     snap_bands+B_CHR,a0
    lea     snap_regs+SR_CHRPTR,a1
    moveq   #7,d0
.lch:
    move.l  (a0)+,(a1)+
    dbra    d0,.lch
    ;; Tampons de sprites : les deux autres que ceux affichés
    move.l  #spr_front0,d0
    cmp.l   disp_front,d0
    bne.s   .lf_
    move.l  #spr_front1,d0
.lf_:
    move.l  d0,snap_front
    move.l  #spr_behind0,d0
    cmp.l   disp_behind,d0
    bne.s   .lb_
    move.l  #spr_behind1,d0
.lb_:
    move.l  d0,snap_behind
    rts

;; Plan de rendu de la bande a1 (indice d4 dans snap_bands) : celui d'une
;; bande précédente qui a les mêmes banques CHR du fond (même image des
;; nametables, seule l'origine diffère), sinon le suivant (au plus
;; NUM_PLANES-1). Deux bandes au décor différent dans le même plan
;; s'écraseraient leurs tuiles communes. -> d0 ; conserve le reste.
BandPlane:
    movem.l d1-d2/d5/a2-a4,-(sp)
    lea     B_CHR(a1),a2
    btst    #4,B_CTRL(a1)              ; table du fond : banques 0-3 ou 4-7
    beq.s   .l0
    lea     16(a2),a2
.l0:
    moveq   #0,d5                      ; plans déjà utilisés
    lea     snap_bands,a3
    move.w  d4,d2
    subq.w  #1,d2
    bmi.s   .lnew
.lprev:
    move.w  B_PLANE(a3),d0
    cmp.w   d5,d0
    bcs.s   .lu
    move.w  d0,d5
    addq.w  #1,d5
.lu:
    lea     B_CHR(a3),a4
    btst    #4,B_CTRL(a3)
    beq.s   .l1
    lea     16(a4),a4
.l1:
    move.l  (a2),d1
    cmp.l   (a4),d1
    bne.s   .lnext
    move.l  4(a2),d1
    cmp.l   4(a4),d1
    bne.s   .lnext
    move.l  8(a2),d1
    cmp.l   8(a4),d1
    bne.s   .lnext
    move.l  12(a2),d1
    cmp.l   12(a4),d1
    beq.s   .ldone                     ; même décor : son plan (d0)
.lnext:
    lea     BAND_SIZE(a3),a3
    dbra    d2,.lprev
.lnew:
    move.w  d5,d0
    cmpi.w  #NUM_PLANES-1,d0
    bls.s   .ldone
    moveq   #NUM_PLANES-1,d0
.ldone:
    movem.l (sp)+,d1-d2/d5/a2-a4
    rts

;; État PPU courant -> bande a0 : $2000, origine X/Y (registre t), banques CHR
;; Conserve a0 ; détruit d0-d2, a3.
CaptureBand:
    move.b  rt_ppuctrl(a6),B_CTRL(a0)
    move.w  rt_t(a6),d0
    move.w  d0,d1
    andi.w  #$1F,d1
    lsl.w   #3,d1
    moveq   #0,d2
    move.b  rt_fx(a6),d2
    add.w   d2,d1
    btst    #10,d0
    beq.s   .lx0
    addi.w  #256,d1
.lx0:
    move.w  d1,B_X(a0)
    bsr.s   OriginY
    move.w  d1,B_Y(a0)
    lea     rt_chrbank(a6),a3
    moveq   #7,d2
    lea     B_CHR(a0),a0
.lch:
    moveq   #0,d0
    move.w  (a3)+,d0
    andi.w  #$7F,d0
    swap    d0
    lsr.l   #6,d0                      ; banque * 1024
    add.l   #chr_rom,d0
    move.l  d0,(a0)+
    dbra    d2,.lch
    lea     -B_CHR-32(a0),a0
    rts

;; d0 = registre t/v de la PPU -> d1 = ligne dans l'espace des nametables (0-479+)
OriginY:
    move.w  d0,d1
    lsr.w   #5,d1
    andi.w  #$1F,d1
    lsl.w   #3,d1                      ; Y grossier * 8
    move.w  d0,d2
    rol.w   #4,d2
    andi.w  #7,d2                      ; Y fin
    add.w   d2,d1
    btst    #11,d0
    beq.s   .ly0
    addi.w  #240,d1
.ly0:
    rts

;; Avant une IRQ 6502 : état de début d'image si c'est la première de la frame
;; (appelé par rt_run_irq ; conserve tous les registres sauf d3-d5, a0, a1)
jag_raster_pre:
    sf      rt_vset(a6)
    ;; ligne nominale de cette IRQ ; la suivante (rechargement automatique du
    ;; compteur) vient une période plus tard, sauf reprogrammation
    st      jag_in_irq
    clr.w   rt_pvc(a6)                 ; instants des écritures PPU de cette IRQ
    clr.w   rt_pvc0(a6)
    move.w  irq_nom16,d5
    move.w  d5,irq_cur16
    move.w  d5,d4
    lsr.w   #4,d4
    move.w  d4,irq_cur
    moveq   #0,d4
    move.b  rt_irqlatch(a6),d4
    neg.w   d4
    addi.w  #256,d4
    lsl.w   #4,d4
    add.w   d4,d5
    bsr     IrqWrapLine
    move.w  d5,irq_nom16
    lsr.w   #4,d4
    bsr     PitAt                      ; IRQ suivante (rechargement) à sa ligne
    ;; IRQ d'une nouvelle image NES (ligne du modèle pas après la dernière
    ;; bande) alors que le journal contient déjà des bandes : ce sont celles
    ;; d'une IRQ de l'image précédente arrivée après la VBL (68000 en retard)
    ;; -> journal repris, sinon les bandes de cette image seraient refusées
    move.l  rlog_count,d3
    beq.s   .lcap
    subq.l  #1,d3
    mulu    #BAND_SIZE,d3
    lea     rlog_bands,a0
    move.w  B_LINE0(a0,d3.l),d3
    cmp.w   irq_cur,d3
    blt.s   .lcap
    clr.l   rlog_count
.lcap:
    tst.l   rlog_count
    bne.s   .lr
    movem.l d0-d2/a3,-(sp)
    lea     rlog_bands,a0
    bsr     CaptureBand
    clr.w   B_LINE0(a0)
    move.l  #1,rlog_count
    sf      rt_pdirty(a6)              ; changements suivis à partir d'ici
    movem.l (sp)+,d0-d2/a3
.lr:
    rts

;; Écriture PPU à venir dans une IRQ qui prend effet sur une ligne plus
;; tardive que le groupe d'écritures en attente (appelé par rt_ppu_time) :
;; d4 = son instant d'effet (1/16 de ligne depuis l'IRQ), d5 = ligne du
;; groupe. L'état actuel (avant elle) forme une bande à la ligne du groupe et
;; elle commence un nouveau groupe (rt_pvc). Détruit d3-d5 (cf. rt_ppu_time).
jag_ppu_split:
    .if ^^defined NORASTER
    rts
    .endif
    tst.b   jag_in_irq                 ; écritures de la NMI : pas de bande
    beq.s   .lr
    move.w  d4,rt_pvc(a6)              ; nouveau groupe
    movem.l d0-d2/d6/a0-a1/a3,-(sp)
    move.w  d5,d4
    addq.w  #1,d4
    bsr.s   jag_band_at
    movem.l (sp)+,d0-d2/d6/a0-a1/a3
.lr:
    rts

;; Après une IRQ 6502 : si l'état PPU a changé, nouvelle bande à la ligne où
;; la PPU NES voit les dernières écritures du gestionnaire (rt_ppu_time ;
;; 1 ligne après l'IRQ si inconnu). Les registres sont restaurés par rt_run_irq.
jag_raster_post:
    sf      jag_in_irq
    .if ^^defined NORASTER
    rts
    .endif
    move.w  rt_pvc(a6),d4
    tst.w   rt_pvc0(a6)
    bne.s   .lt
    moveq   #16,d4
.lt:
    add.w   irq_cur16,d4
    lsr.w   #4,d4
    addq.w  #1,d4                      ; l'état vaut à partir de la ligne suivante
;; Bande à partir de la ligne d4 avec l'état PPU actuel, s'il a changé depuis
;; la bande précédente. Détruit d0-d4, a0, a1, a3.
jag_band_at:
    tst.b   rt_pdirty(a6)              ; état PPU inchangé depuis la dernière bande
    beq     .lr
    sf      rt_pdirty(a6)
    move.l  rlog_count,d3
    beq     .lr
    cmpi.l  #MAX_BANDS,d3
    bcc     .lr
    tst.w   d4
    ble     .lr
    cmpi.w  #NES_HEIGHT,d4
    bge     .lr
    move.l  d3,d0
    mulu    #BAND_SIZE,d0
    lea     rlog_bands,a0
    adda.l  d0,a0
    cmp.w   B_LINE0-BAND_SIZE(a0),d4   ; les bandes doivent se suivre
    ble     .lr
    bsr     CaptureBand
    move.w  d4,B_LINE0(a0)
    lea     -BAND_SIZE(a0),a1          ; bande précédente
    tst.b   rt_vset(a6)
    bne.s   .lvset
    ;; défilement vertical inchangé : suite de la bande précédente
    move.w  B_Y(a1),d1
    add.w   d4,d1
    sub.w   B_LINE0(a1),d1
    move.w  d1,B_Y(a0)
    ;; état identique : pas de nouvelle bande
    move.b  B_CTRL(a0),d0
    cmp.b   B_CTRL(a1),d0
    bne.s   .ladd
    move.w  B_X(a0),d0
    cmp.w   B_X(a1),d0
    bne.s   .ladd
    moveq   #7,d2
    lea     B_CHR(a0),a3
    lea     B_CHR(a1),a1
.lcmp:
    cmpm.l  (a3)+,(a1)+
    bne.s   .ladd
    dbra    d2,.lcmp
    rts
.lvset:
    move.w  rt_v(a6),d0                ; défilement rechargé par $2006
    bsr     OriginY
    move.w  d1,B_Y(a0)
.ladd:
    addq.l  #1,rlog_count
.lr:
    rts

;; CLUT : 32 couleurs NES (index = adresse de palette $3F00-$3F1F)
LoadClut:
    lea     disp_regs,a0
    lea     clut_last,a1
    moveq   #7,d0
.lcmp_:
    cmpm.l  (a0)+,(a1)+
    dbne    d0,.lcmp_
    beq.s   .lsame_                    ; palette inchangée
    lea     disp_regs,a0
    lea     clut_last,a1
    moveq   #7,d0
.lsave_:
    move.l  (a0)+,(a1)+
    dbra    d0,.lsave_
    lea     disp_regs,a0
    lea     CLUT,a1
    lea     nes_rgb16,a2
    moveq   #31,d0
.ll_:
    moveq   #0,d1
    move.b  (a0)+,d1
    andi.w  #$3F,d1
    add.w   d1,d1
    move.w  (a2,d1.w),(a1)+
    dbra    d0,.ll_
    ;; Couleur de fond (palette 0) : fond de ligne et bordures, et cache du
    ;; bord droit (CLUT 255) ; recalculée plutôt que relue dans la CLUT
    moveq   #0,d1
    move.b  disp_regs,d1
    andi.w  #$3F,d1
    add.w   d1,d1
    move.w  (a2,d1.w),d1
    move.w  d1,CLUT+(255*2)
    .if ^^defined PERFHUD
    .else
    move.w  d1,BG
    .endif
.lsame_:
    rts

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Liste d'objets : sprites derrière, décor (jusqu'à 4 morceaux selon le
;; défilement), sprites devant. Reconstruite à chaque VBL.
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

BuildObjectList:
    movea.l ol_wbuf,a0                 ; tampon maître ; liens vers ObjectList
    move.l  #ObjectList,d0
    sub.l   a0,d0
    move.l  d0,ol_bias
    ;; +0 : si VC dépasse la fin de l'image -> STOP (évite que l'OP ne
    ;; réaffiche le haut des bitmaps après la reconstruction)
    lea     ObjectList+OL_STOP,a1
    move.w  a_ypos,d0
    add.w   #NES_HEIGHT*2,d0
    moveq   #2,d1
    bsr     WriteBranch
    ;; +8 : si VC est avant le haut de l'image -> STOP (l'OP ne parcourt pas
    ;; la liste au-dessus de l'image), sinon objet suivant (+16)
    lea     ObjectList+OL_STOP,a1
    move.w  a_ypos,d0
    moveq   #1,d1
    bsr     WriteBranch
    movea.l ol_wbuf,a0
    lea     16(a0),a0
    ;; Sprites derrière le décor (lignes occupées : TrimSpriteLayers)
    clr.l   ol_wsprb
    clr.l   ol_wsprf
    btst    #4,disp_regs+SR_MASK
    beq.s   .lnob
    move.l  disp_behind,d0
    beq.s   .lnob
    move.l  a0,ol_wsprb                ; ajusté à l'échange (TrimSpriteLayers)
    moveq   #-1,d6
    bsr     SpriteLayer
.lnob:
    ;; Décor : une série d'objets par bande
    btst    #3,disp_regs+SR_MASK
    beq.s   .lnobg
    move.l  disp_nbands,d6
    beq.s   .lnobg
    lea     disp_bands,a3
.lband:
    bsr     BuildBandObjects
    lea     BAND_SIZE(a3),a3
    subq.l  #1,d6
    bne.s   .lband
.lnobg:
    btst    #4,disp_regs+SR_MASK
    beq.s   .lnof
    move.l  disp_front,d0
    beq.s   .lnof
    move.l  a0,ol_wsprf
    moveq   #-1,d6
    bsr     SpriteLayer
.lnof:
    .if ^^defined NOEDGEMASK
    .else
    ;; Cache du bord droit : un morceau de décor peut dépasser de 1 à 7 pixels
    ;; à droite de l'image NES (largeur affichée arrondie à la phrase de 8
    ;; pixels quand le défilement X n'est pas multiple de 8). Objet opaque de
    ;; la couleur de fond (CLUT 255), une seule phrase répétée (DWIDTH = 0).
    move.l  #edge_mask,d0
    moveq   #0,d1
    moveq   #0,d2
    move.w  #NES_HEIGHT,d3
    moveq   #8,d4
    moveq   #0,d5
    move.l  #256<<16,d7
    bsr     WriteBitmap8At
    andi.l  #~$8000,-8(a0)             ; TRANS désactivé
    andi.l  #~($3FF<<18),-4(a0)        ; DWIDTH = 0
    .endif
    .if ^^defined DIAGOL
    ;; build --diagol : grille de points (CLUT 254, magenta) en dernier objet,
    ;; pour voir si l'OP traite la fin de la liste sur toutes les lignes
    move.l  #diag_bmp,d0
    moveq   #0,d1
    moveq   #0,d2
    move.w  #NES_HEIGHT,d3
    move.w  #256,d4
    moveq   #0,d5
    bsr     WriteBitmap8
    .endif
    .if ^^defined PERFHUD
    ;; HUD de mesure : 128 x 8 pixels opaques en haut à gauche de l'image (ligne 8)
    move.l  #perf_bmp,d0
    moveq   #0,d1
    moveq   #0,d2
    moveq   #8,d3
    move.w  #PERF_W,d4
    moveq   #0,d5
    moveq   #8,d7                      ; ligne 8 (les premières sont souvent rognées)
    bsr     WriteBitmap8At
    andi.l  #~$8000,-8(a0)             ; TRANS désactivé (fond noir)
    .endif
    ;; nombre d'objets bitmap (RefreshOL), puis STOP (et STOP de garde à
    ;; l'emplacement fixe OL_STOP)
    move.l  a0,d0
    sub.l   ol_wbuf,d0
    subi.l  #16,d0
    lsr.l   #4,d0
    move.w  d0,ol_wcount
    move.l  #0,(a0)+
    move.l  #4,(a0)+
    movea.l ol_wbuf,a0
    lea     OL_STOP(a0),a0
    move.l  #0,(a0)+
    move.l  #4,(a0)
    rts

;; Bande a3 : lignes [B_LINE0, B_LINE1) de l'écran, origine (B_X, B_Y) dans
;; l'espace logique 512x480 des 4 nametables ; découpée en morceaux qui
;; appartiennent chacun à une nametable physique du plan B_PLANE.
;; a0 = objet suivant (avance) ; conserve a3, d6.
BuildBandObjects:
    movem.l d6/a3,-(sp)
    move.w  B_LINE1(a3),d0
    sub.w   B_LINE0(a3),d0
    ble     .ldone
    move.w  d0,bgo_h                   ; lignes restantes
    move.w  B_LINE0(a3),bgo_screeny
    move.w  B_Y(a3),d0
.lym:
    cmpi.w  #480,d0
    bcs.s   .lyok
    subi.w  #480,d0
    bra.s   .lym
.lyok:
    move.w  d0,bgo_sy                  ; ligne logique courante
    move.w  B_X(a3),d0
    andi.w  #511,d0
    move.w  d0,bgo_sx
    move.w  B_PLANE(a3),d0
    mulu    #(PLANE_BYTES>>4),d0
    lsl.l   #4,d0
    add.l   #bg_planes,d0
    move.l  d0,bgo_plane
.lvpiece:
    ;; morceau vertical : jusqu'à la prochaine frontière de nametable (240/480)
    move.w  bgo_sy,d2
    moveq   #0,d6                      ; rangée logique
    cmpi.w  #240,d2
    bcs.s   .lr0
    moveq   #1,d6
    subi.w  #240,d2
.lr0:
    move.w  #240,d3
    sub.w   d2,d3                      ; lignes jusqu'à la frontière
    cmp.w   bgo_h,d3
    bls.s   .lh
    move.w  bgo_h,d3
.lh:
    movem.w d2-d3,-(sp)
    ;; morceau gauche : colonnes x..255 de la nametable logique lx
    move.w  bgo_sx,d1
    move.w  d1,d5
    lsr.w   #8,d5                      ; lx
    andi.w  #255,d1
    move.w  #256,d4
    sub.w   d1,d4
    move.w  #0,bgo_screenx
    bsr     .lphys
    move.w  d1,d5
    andi.w  #7,d5                      ; premier pixel
    andi.w  #$F8,d1
    bsr     .lpiece
    movem.w (sp),d2-d3
    ;; morceau droit : colonnes 0..x-1 de la nametable voisine
    move.w  bgo_sx,d1
    andi.w  #255,d1
    beq.s   .lnoright
    move.w  #256,d0
    sub.w   d1,d0
    move.w  d0,bgo_screenx
    move.w  d1,d4                      ; largeur
    move.w  bgo_sx,d5
    lsr.w   #8,d5
    eori.w  #1,d5
    bsr     .lphys
    moveq   #0,d1
    moveq   #0,d5
    bsr     .lpiece
.lnoright:
    movem.w (sp)+,d2-d3
    ;; morceau suivant
    add.w   d3,bgo_screeny
    sub.w   d3,bgo_h
    ble.s   .ldone
    move.w  bgo_sy,d0
    add.w   d3,d0
    cmpi.w  #480,d0
    bcs.s   .lnw
    subi.w  #480,d0
.lnw:
    move.w  d0,bgo_sy
    bra     .lvpiece
.ldone:
    movem.l (sp)+,d6/a3
    rts
;; d5 = colonne logique (0/1), d6 = rangée logique -> d0 = image de la nametable physique
.lphys:
    move.b  disp_regs+SR_MIRROR,d0
    beq.s   .lmv
    cmpi.b  #1,d0
    beq.s   .lmh
    cmpi.b  #3,d0
    beq.s   .lm1
    moveq   #0,d0
    bra.s   .lmp
.lm1:
    moveq   #1,d0
    bra.s   .lmp
.lmv:
    move.w  d5,d0
    bra.s   .lmp
.lmh:
    move.w  d6,d0
.lmp:
    andi.l  #1,d0
    mulu    #NT_BYTES,d0
    add.l   bgo_plane,d0
    rts
;; d0 = image, d1 = x (multiple de 8), d2 = y, d3 = hauteur, d4 = largeur, d5 = premier pixel
.lpiece:
    move.w  bgo_screenx,d7
    swap    d7
    move.w  bgo_screeny,d7
    bra     WriteBitmap8At

;; Calque de sprites d0 -> objet de 16 octets en a0 : d6 = -1 toute la
;; hauteur ; sinon lignes occupées relevées par le GPU (début << 16 | fin), et
;; 0 = calque vide : bitmap placé sous la fin du balayage (jamais affiché).
;; L'OP, prioritaire sur le 68000, ne relit plus 256 octets par ligne vide.
SpriteLayer:
    moveq   #0,d1                      ; x dans l'image
    move.w  #256,d4                    ; largeur
    moveq   #0,d5                      ; premier pixel (FIRSTPIX)
    cmpi.l  #-1,d6
    bne.s   .lext
    moveq   #0,d2
    move.w  #NES_HEIGHT,d3
    bra.s   WriteBitmap8
.lext:
    move.l  d6,d2
    beq.s   .lnone
    swap    d2                         ; première ligne
    move.w  d6,d3
    sub.w   d2,d3                      ; hauteur
    ble.s   .lnone
    moveq   #0,d7
    move.w  d2,d7                      ; même ligne à l'écran
    bra.s   WriteBitmap8At
.lnone:
    ;; calque vide : bitmap d'une ligne à un YPOS jamais atteint (980 lignes plus
    ;; bas : 1986 NTSC / 2042 PAL, < 2048) ; l'OP le saute et suit son lien
    moveq   #0,d2
    moveq   #1,d3
    move.l  #980,d7
    bra     WriteBitmap8At

;; À l'échange d'image (le GPU a fini ce rendu) : calques de sprites de la
;; liste qui entre limités aux lignes qu'ils occupent (gs_extb / gs_extf)
TrimSpriteLayers:
    move.l  ol_wsprb,d0
    beq.s   .lf
    movea.l d0,a0
    move.l  disp_behind,d0
    move.l  gs_extb,d6                 ; (RAM GPU : move.l)
    bsr     SpriteLayer
.lf:
    move.l  ol_wsprf,d0
    beq.s   .lr
    movea.l d0,a0
    move.l  disp_front,d0
    move.l  gs_extf,d6
    bsr     SpriteLayer
.lr:
    rts

;; Bitmap 8 bpp de l'image NES, plein écran (x/y écran = 0)
WriteBitmap8:
    moveq   #0,d7
;; d0 = image (pas 256 octets), d1/d2 = x/y dans l'image, d3 = hauteur,
;; d4 = largeur affichée (pixels), d5 = premier pixel, d7 = (x écran << 16) | y écran
;; a0 = objet (avance de 16 octets)
WriteBitmap8At:
    movem.l d0-d6,-(sp)
    tst.w   d3
    ble     .skip
    ;; DATA = image + y*256 + x
    moveq   #0,d6
    move.w  d2,d6
    lsl.l   #8,d6
    add.l   d6,d0
    moveq   #0,d6
    move.w  d1,d6
    add.l   d6,d0
    lsr.l   #3,d0                      ; DATA en phrases
    lea     16(a0),a1
    move.l  a1,d1
    add.l   ol_bias,d1                 ; adresse dans ObjectList
    lsr.l   #3,d1                      ; LINK
    ;; Phrase 1 : DATA(43-63) LINK(24-42) HEIGHT(14-23) YPOS(3-13) TYPE=0
    moveq   #11,d6
    move.l  d0,d2
    lsl.l   d6,d2
    move.l  d1,d6
    lsr.l   #8,d6
    or.l    d6,d2
    move.l  d2,(a0)+
    moveq   #24,d6
    move.l  d1,d2
    lsl.l   d6,d2
    moveq   #0,d6
    move.w  d3,d6
    lsl.l   #7,d6
    lsl.l   #7,d6                      ; HEIGHT << 14
    or.l    d6,d2
    moveq   #0,d6
    move.w  d7,d6                      ; y écran
    add.w   d6,d6                      ; demi-lignes
    add.w   a_ypos,d6
    lsl.l   #3,d6
    or.l    d6,d2
    move.l  d2,(a0)+
    ;; Phrase 2 : FIRSTPIX(49-54) RELEASE TRANS(47) RMW REFLECT INDEX(38-44)
    ;; IWIDTH(28-37) DWIDTH(18-27) PITCH(15-17) DEPTH(12-14) XPOS(0-11)
    move.w  d4,d6
    add.w   d5,d6
    addq.w  #7,d6
    lsr.w   #3,d6                      ; IWIDTH (phrases)
    moveq   #0,d2
    move.w  d5,d2
    lsl.l   #8,d2
    lsl.l   #8,d2
    lsl.l   #4,d2                      ; FIRSTPIX (pixels 8 bits : x8) -> bits 49-54 = long haut 17-22
    ori.l   #$18000,d2                 ; TRANS (bit 47) et RELEASE (bit 48 : objet
                                       ; 8 bpp, le bus est rendu entre ses lectures)
    moveq   #0,d1
    move.w  d6,d1
    lsr.w   #4,d1                      ; IWIDTH bits 4-9 -> long haut bits 0-5
    or.l    d1,d2
    move.l  d2,(a0)+
    moveq   #0,d2
    move.w  d6,d2
    andi.w  #$0F,d2
    moveq   #28,d1
    lsl.l   d1,d2                      ; IWIDTH bits 0-3 -> long bas bits 28-31
    ori.l   #(NES_PITCH_PHRASES<<18)|(1<<15)|O_DEPTH8,d2
    swap    d7
    moveq   #0,d1
    move.w  d7,d1
    swap    d7
    add.w   a_xpos,d1
    andi.w  #$FFF,d1
    or.l    d1,d2
    move.l  d2,(a0)+
.skip:
    movem.l (sp)+,d0-d6
    rts

WriteBranch:
    ;; a0 = objet, a1 = cible, d0.w = YPOS, d1 = CC ; a0 += 8
    move.l  a1,d2
    lsr.l   #3,d2
    move.l  d2,d3
    lsr.l   #8,d3
    move.l  d3,(a0)+
    moveq   #24,d3
    lsl.l   d3,d2
    and.l   #$7FF,d0
    lsl.l   #3,d0
    or.l    d0,d2
    move.l  d1,d3
    lsl.l   #8,d3
    lsl.l   #6,d3
    or.l    d3,d2
    or.l    #3,d2
    move.l  d2,(a0)+
    rts

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Manettes : Jaguar -> NES (A B Select Start Haut Bas Gauche Droite)
;;   B (Jaguar) = B NES (tir), A = A NES (transformation), C = SELECT NES
;;   (bombe, cf. tools/rom_patches.py), Pause = Start, Option = rien
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

ReadPads:
    bsr     ReadJoypads                ; d0 = manette 1, d1 = manette 2
    move.l  d1,-(sp)
    bsr     PadToNes
    .if ^^defined AUTOTEST
    bsr     AutoPad
    .endif
    move.b  d0,rt_pad(a6)
    move.l  (sp)+,d0
    bsr     PadToNes
    move.b  d0,rt_pad2(a6)
    rts

;; Lecture des deux ports (méthode de JagStudio, zero_inpt68k.s) : 4 rangées
;; sélectionnées dans JOYSTICK ; port 1 = JOYBUTS bits 0-1 et JOYSTICK bits
;; 8-11, port 2 = JOYBUTS bits 2-3 et JOYSTICK bits 12-15.
;; -> d0 / d1 : boutons appuyés (bits PAD_*)
ReadJoypads:
    movem.l d2-d3,-(sp)
    moveq   #0,d0
    moveq   #0,d1
    move.w  #$81E7,JOYSTICK            ; rangée 3
    bsr.s   .lrow
    move.w  #$81DB,JOYSTICK            ; rangée 2
    bsr.s   .lrow
    move.w  #$81BD,JOYSTICK            ; rangée 1
    bsr.s   .lrow
    move.w  #$817E,JOYSTICK            ; rangée 0
    bsr.s   .lrow
    eori.l  #$FFFFFF,d0                ; matériel actif à l'état bas
    eori.l  #$FFFFFF,d1
    movem.l (sp)+,d2-d3
    rts
.lrow:
    move.w  JOYBUTS,d2
    move.w  JOYSTICK,d3
    lsl.l   #6,d0
    move.w  d2,d4
    andi.l  #3,d4
    or.l    d4,d0
    move.w  d3,d4
    andi.l  #$0F00,d4
    lsr.l   #6,d4
    or.l    d4,d0
    lsl.l   #6,d1
    move.w  d2,d4
    lsr.w   #2,d4
    andi.l  #3,d4
    or.l    d4,d1
    move.w  d3,d4
    andi.l  #$F000,d4
    lsr.l   #8,d4
    lsr.l   #2,d4
    or.l    d4,d1
    rts

;; Bits de ReadJoypads
PAD_PAUSE       equ 0
PAD_A           equ 1
PAD_UP          equ 2
PAD_DOWN        equ 3
PAD_LEFT        equ 4
PAD_RIGHT       equ 5
PAD_B           equ 7
PAD_C           equ 13
PAD_OPTION      equ 19

;; Boutons NES envoyés par A / B / C pour chaque attribution de la ligne KEY
;; (même ordre que KEY_PERMS de tools/rom_patches.py : bouton de la
;; transformation, du tir, de la bombe)
key_map:
    dc.b    NES_A,NES_B,NES_SELECT,0       ; 0 : A transf. B tir    C bombe
    dc.b    NES_A,NES_SELECT,NES_B,0       ; 1 : A transf. B bombe  C tir
    dc.b    NES_B,NES_A,NES_SELECT,0       ; 2 : A tir     B transf. C bombe
    dc.b    NES_SELECT,NES_A,NES_B,0       ; 3 : A bombe   B transf. C tir
    dc.b    NES_B,NES_SELECT,NES_A,0       ; 4 : A tir     B bombe  C transf.
    dc.b    NES_SELECT,NES_B,NES_A,0       ; 5 : A bombe   B tir    C transf.
    .even

;; d0 = boutons Jaguar -> d0.b = boutons NES
PadToNes:
    move.l  d0,d1
    moveq   #0,d0
    ;; A / B / C selon l'attribution choisie à la ligne KEY des options
    ;; (WRAM $7F00, 0-5) : transformation = A NES, tir = B NES, bombe =
    ;; SELECT NES (cf. tools/rom_patches.py)
    moveq   #0,d2
    move.b  nes_wram+KEY_IDX,d2
    cmpi.b  #6,d2
    bcs.s   .lk_
    moveq   #0,d2
.lk_:
    add.w   d2,d2
    add.w   d2,d2
    lea     key_map(pc),a0
    adda.w  d2,a0
    btst    #PAD_A,d1
    beq.s   .la_
    or.b    (a0),d0
.la_:
    btst    #PAD_B,d1
    beq.s   .lb_
    or.b    1(a0),d0
.lb_:
    btst    #PAD_C,d1
    beq.s   .lc_
    or.b    2(a0),d0
.lc_:
    btst    #PAD_PAUSE,d1
    beq.s   .lp_
    ori.b   #NES_START,d0
.lp_:
    ;; Option : sans effet (SELECT sert à la bombe)
    btst    #PAD_UP,d1
    beq.s   .lu_
    ori.b   #NES_UP,d0
.lu_:
    btst    #PAD_DOWN,d1
    beq.s   .ld_
    ori.b   #NES_DOWN,d0
.ld_:
    btst    #PAD_LEFT,d1
    beq.s   .ll_
    ori.b   #NES_LEFT,d0
.ll_:
    btst    #PAD_RIGHT,d1
    beq.s   .lr_
    ori.b   #NES_RIGHT,d0
.lr_:
    rts

    .if ^^defined AUTOTEST
;; Build de test : START à l'écran titre (mode $20 = 5), puis tir continu
;; et déplacements gauche/droite
AutoPad:
    move.l  rt_frame(a6),d1
    cmpi.b  #5,nes_ram+$20
    bne.s   .play
    andi.w  #$3F,d1
    cmpi.w  #4,d1
    bcc.s   .lr_
    ori.b   #NES_START|NES_B,d0        ; Start : passe l'intro ; B : valide le menu
.lr_:
    rts
.play:
    move.b  #3,nes_ram+$68             ; vies du joueur 1 maintenues (tests longs)
    ori.b   #NES_B,d0
    btst    #7,d1
    beq.s   .right
    ori.b   #NES_LEFT,d0
    rts
.right:
    ori.b   #NES_RIGHT,d0
    rts
    .endif

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; IRQ du VRC4 -> PIT de Tom : une interruption toutes les (256 - latch)
;; lignes NES (mode « scanline »), tant que l'IRQ est activée.
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

;; La ligne NES de chaque IRQ est calculée selon le modèle du compteur
;; (irq_nom) : les bandes d'effets de trame en dépendent, pas du timing réel
;; du 68000 (sinon elles sautent d'une image à l'autre). Le PIT est programmé
;; pour cette ligne (PitAt), pas pour un délai compté depuis l'écriture : la
;; chaîne d'IRQ de l'image ne dérive pas quand le 68000 écrit plus tard que
;; le 6502 (NMI commencée après le travail de la VBL, gestionnaires plus lents)
;; et reste avant la VBL suivante.
jag_irq_changed:
    btst    #1,rt_irqctrl(a6)
    beq.s   .off
    moveq   #0,d4
    move.b  rt_irqlatch(a6),d4
    neg.w   d4
    addi.w  #256,d4                    ; période (lignes)
    ;; instant NES de l'écriture (1/16 de ligne) : dans une IRQ, ligne de
    ;; l'IRQ + cycles 6502 écoulés depuis (a3, comptés par le code recompilé,
    ;; cf. rt_ppu_time) ; dans le NMI, ligne 242
    tst.b   jag_in_irq
    beq.s   .lnirq
    move.w  a3,d5
    mulu    #9,d5                      ; cycles -> 1/16 de ligne
    lsr.l   #6,d5
    add.w   irq_cur16,d5
    bra.s   .lw
.lnirq:
    move.w  #242*16,d5
    tst.b   rt_innmi(a6)
    bne.s   .lw
    move.w  d2,-(sp)                   ; hors interruption : ligne courante
    bsr     NesLine
    move.w  d2,d5
    move.w  (sp)+,d2
    lsl.w   #4,d5
.lw:
    move.w  d4,-(sp)
    lsl.w   #4,d4
    add.w   d4,d5
    bsr     IrqWrapLine
    move.w  d5,irq_nom16
    move.w  (sp)+,d4
    tst.b   jag_in_irq
    bne.s   .lpit
    tst.b   rt_innmi(a6)
    beq.s   .lpit
    bsr     PitAtNmi
    bra.s   .lpit2
.lpit:
    bsr     PitAt
.lpit2:
    move.w  #C_VIDENA|C_PITENA,int_enables
    move.w  #C_VIDENA|C_PITENA,INT1
    rts
.off:
    move.w  #C_VIDENA,int_enables
    move.w  #C_VIDENA,INT1
    rts

;; Acquittement ($F00C) : le compteur du VRC4 n'est pas rechargé, le PIT
;; continue donc tel quel s'il tourne déjà
jag_irq_acked:
    btst    #1,rt_irqctrl(a6)
    beq     jag_irq_changed            ; désactivée
    move.w  int_enables,d4
    andi.w  #C_PITENA,d4
    beq     jag_irq_changed            ; pas encore lancée
    rts

;; PIT : interruption à la ligne NES d5 (1/16), comptée depuis la ligne
;; affichée maintenant (VC) ; d4 = période (lignes). Cible déjà dépassée
;; (attente de plus d'une période) : dès que possible. Le rechargement
;; suivant (une période) est fait par jag_int. Conserve tous les registres.
;; PitAtNmi : programmation faite par le NMI, qui commence sur Jaguar bien
;; après la VBL (liste d'objets...) : au moins une période d'attente, comme le
;; compteur du VRC4, pour que l'IRQ n'interrompe pas le début du NMI (banques
;; CHR de l'image) plus tôt que sur NES ; les IRQ suivantes rattrapent leur ligne.
PitAtNmi:
    movem.l d2-d3/d5,-(sp)
    move.w  d4,d3
    lsr.w   #1,d3                      ; attente minimale
    bra.s   PitAtGo
PitAt:
    movem.l d2-d3/d5,-(sp)
    moveq   #1,d3
PitAtGo:
    lsr.w   #4,d5
    bsr.s   NesLine
    sub.w   d2,d5                      ; lignes à attendre (modulo 262)
.lneg:
    tst.w   d5
    bgt.s   .lpos
    addi.w  #262,d5
    bra.s   .lneg
.lpos:
    cmpi.w  #262,d5
    ble.s   .lmod
    subi.w  #262,d5
    bra.s   .lpos
.lmod:
    move.w  d4,d2
    addi.w  #16,d2
    cmp.w   d2,d5
    bls.s   .lmin
    move.w  d3,d5                      ; en retard sur la cible
.lmin:
    cmp.w   d3,d5
    bcc.s   .lok
    move.w  d3,d5
.lok:
    subq.w  #1,d5
    move.w  #PIT_LINE,PIT0
    move.w  d5,PIT1
    movem.l (sp)+,d2-d3/d5
    rts

;; d2 = ligne NES actuelle selon le compteur vidéo, comptée depuis la VBL
;; (début de jag_vbl = ligne 241, celle du NMI) : la chaîne d'IRQ suit la VBL
;; réelle quel que soit le placement de VC (émulateurs, NTSC/PAL)
NesLine:
    move.w  VC,d2
    andi.w  #$7FF,d2
    sub.w   vc_vbl,d2
    bpl.s   .l1
    add.w   frame_hl,d2
.l1:
    asr.w   #1,d2
    addi.w  #241,d2
    rts

;; d5 = ligne NES en 1/16 -> ramenée dans 0-261
IrqWrapLine:
    cmpi.w  #262*16,d5
    blt.s   .l1
    subi.w  #262*16,d5
    bra.s   IrqWrapLine
.l1:
    tst.w   d5
    bge.s   .l2
    addi.w  #262*16,d5
.l2:
    rts

;; Exceptions 68000 (erreur de bus ou d'adresse, instruction illégale...) :
;; numéro de vecteur dans exc_vec, début du cadre de pile dans exc_frame
;; (erreur d'adresse : +2 = adresse accédée, +10 = PC), rt_error = 6
InstallExceptions:
    lea     $8,a0
    lea     exc_stubs,a1
    moveq   #(EXC_LAST-2),d0
.lv:
    move.l  a1,(a0)+
    lea     12(a1),a1
    dbra    d0,.lv
    rts

EXC_LAST        equ 31                 ; vecteurs 2 à 31 (dont $60-$7C)
exc_stubs:
    .rept   EXC_LAST-1
    move.w  #((*-exc_stubs)/12)+2,exc_vec
    bra.w   exc_common
    .endr

exc_common:
    move.w  #$2700,sr
    move.l  a7,exc_sp
    move.l  (a7),exc_frame
    move.l  4(a7),exc_frame+4
    move.l  8(a7),exc_frame+8
    move.l  12(a7),exc_frame+12
exc_halt:
    move.w  #6,rt_error+rt_vars
    move.w  #$F81F,BG                  ; magenta : exception 68000
.lh:
    bra.s   .lh

;; Erreur fatale du code recompilé : écran rouge, code d'erreur en rt_error
jag_halt:
    move.w  #$FFC0,BG                  ; jaune : erreur du code recompilé
    move.w  #$2700,sr
.ll_:
    bra.s   .ll_

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Runtime et code 6502 recompilé
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

    .include "nes_runtime.s"
    .include "nes_hle.s"
    .include "nes_interp.s"
    .if ^^defined START_STAGE
    .include "nes_code_stage.s"        ; build.py --stage N
    .else
    .include "nes_code.s"
    .endif

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Données
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

    .data
    .even
;; Palette maître NES (2C02) en RGB16 Jaguar (RRRRR BBBBB GGGGGG)
nes_rgb16:
    .include "nes_rgb16.inc"
;; build --jagdebug : étape du GPU bloqué 0 = jamais démarré (gris), 1 = décor
;; (rouge), 2 = effacement (magenta), 3 = sprites (orange), 4 = fini (blanc)
dbg_colors:
    dc.w    $8410,$F800,$F83F,$FC20,$FFFF,$0000,$0000,$0000
    .if ^^defined PERFHUD
;; Police du HUD perfhud (8 x 8, bit 7 = pixel de gauche) : 0-9 J A R G % espace
perf_font:
    dc.b    $70,$88,$98,$A8,$C8,$88,$70,$00                ; 0
    dc.b    $20,$60,$20,$20,$20,$20,$70,$00                ; 1
    dc.b    $70,$88,$08,$10,$20,$40,$F8,$00                ; 2
    dc.b    $F8,$10,$20,$10,$08,$88,$70,$00                ; 3
    dc.b    $10,$30,$50,$90,$F8,$10,$10,$00                ; 4
    dc.b    $F8,$80,$F0,$08,$08,$88,$70,$00                ; 5
    dc.b    $30,$40,$80,$F0,$88,$88,$70,$00                ; 6
    dc.b    $F8,$08,$10,$20,$40,$40,$40,$00                ; 7
    dc.b    $70,$88,$88,$70,$88,$88,$70,$00                ; 8
    dc.b    $70,$88,$88,$78,$08,$10,$60,$00                ; 9
    dc.b    $38,$10,$10,$10,$10,$90,$60,$00                ; J
    dc.b    $70,$88,$88,$F8,$88,$88,$88,$00                ; A
    dc.b    $F0,$88,$88,$F0,$A0,$90,$88,$00                ; R
    dc.b    $70,$88,$80,$B8,$88,$88,$78,$00                ; G
    dc.b    $C0,$C8,$10,$20,$40,$98,$18,$00                ; %
    dc.b    $00,$00,$00,$00,$00,$00,$00,$00                ;  
    dc.b    $F0,$88,$88,$F0,$88,$88,$F0,$00                ; B
    dc.b    $80,$80,$80,$80,$80,$80,$F8,$00                ; L
    .even
    .endif
;; Diagnostic des exceptions (hors BSS : conservé si le démarrage est rejoué)
    .long
boot_count:     dc.l    0
exc_sp:         dc.l    0
exc_frame:      dc.l    0,0,0,0
exc_vec:        dc.w    0,0

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Code GPU et DSP (assemblés pour leur RAM locale, copiés au démarrage)
;; Dans la section .text : GPUCode et GPUCodeEnd doivent être dans la même
;; section (après .68000, rmac revient en .text).
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

    .text
    .long
;; set_olp (GpuSetOlp) : OLP écrit par le GPU, qui s'arrête ensuite
SetOlpCode:
    .gpu
    .org    G_RAM
set_olp:
    movei   #olp_val,r1
    load    (r1),r0
    movei   #OLP,r2
    store   r0,(r2)
    movei   #G_CTRL,r1
    moveq   #0,r3
    store   r3,(r1)                    ; le GPU s'arrête lui-même
    nop
    nop
    .long
olp_val:
    dc.l    0
    .68000
SetOlpCodeEnd:

    .long
GPUCode:
    .gpu
    .org    G_RAM
    .include "gpu.s"
    .68000
GPUCodeEnd:

    .long
DSPCode:
    .dsp
    .org    D_RAM
    .include "dsp.s"
    .68000
DSPCodeEnd:
    .long                              ; (code RISC copié en longs : aligné avant et après)

;; Le code RISC doit tenir dans la RAM locale (DSP : marge pour la pile r31)
    .if gpu_end > $F04000                ; (littéraux : rmac peut mal évaluer un .if
                                       ; comparé à un equ calculé, ici G_ENDRAM)
    .error "code GPU trop grand pour la RAM GPU (4 Ko)"
    .endif
    .if dsp_end > $F1CF00                ; D_ENDRAM - 256
    .error "code DSP trop grand pour la RAM DSP (8 Ko moins la pile)"
    .endif

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Variables
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

    .bss
    .long
a_vdb:          ds.w    1
a_vde:          ds.w    1
a_ypos:         ds.w    1
a_xpos:         ds.w    1              ; XPOS (pixels) du bord gauche de l'image NES
bgo_sx:         ds.w    1
bgo_sy:         ds.w    1
bgo_nx:         ds.w    1
bgo_ny:         ds.w    1
bgo_screenx:    ds.w    1
bgo_screeny:    ds.w    1
bgo_h:          ds.w    1
int_enables:    ds.w    1              ; interruptions Tom actives (C_VIDENA, C_PITENA)
clut_last:      ds.l    8              ; palette NES chargée dans la CLUT
    .if ^^defined DIAGOL
    .phrase
diag_bmp:       ds.b    256*NES_HEIGHT ; grille de diagnostic (--diagol)
    .endif
snap_otmp:      ds.l    8              ; entrées du HUD mises de côté (HudFirst)
hud_pos:        ds.w    8              ; leurs positions
ol_count:       ds.w    1              ; objets bitmap de la liste affichée (RefreshOL)
ol_wcount:      ds.w    1              ; idem pour la liste construite
ol_full:        ds.b    1              ; liste neuve : copie complète
vram_rot:       ds.b    1              ; bloc VRAM recopié d'office (TakeSnapshot)
ol_wbuf:        ds.l    1              ; tampon où BuildObjectList écrit
ol_master:      ds.l    1              ; liste maîtresse affichée
ol_bias:        ds.l    1              ; ObjectList - ol_wbuf (liens)
ol_building:    ds.b    1              ; PrepareNextOL en cours
ol_next_ready:  ds.b    1              ; liste de l'instantané en attente prête
vc_vbl:         ds.w    1              ; VC au début de la dernière VBL
frame_hl:       ds.w    1              ; demi-lignes par image (525 NTSC, 625 PAL)
vbl_take:       ds.b    1              ; VBL : instantané à prendre (GPU libre)
    .even
ol_wsprb:       ds.l    1              ; objets des calques de sprites dans la liste
ol_wsprf:       ds.l    1              ; construite (0 = absent ; TrimSpriteLayers)
vbl_swapped:    ds.b    1              ; image échangée à cette VBL
    .even
    .even
stat_lag:       ds.l    1              ; VBL arrivées pendant le NMI (image NES en retard)
stat_gpubusy:   ds.l    1              ; VBL arrivées pendant un rendu GPU (image sautée)
stat_ldrop:     ds.l    1              ; VBL où la liste d'objets n'était pas prête (image sautée)
stat_drawn:     ds.l    1              ; images affichées
stat_nmi:       ds.l    1              ; images de jeu (NMI terminés)
irq_nom16:      ds.w    1              ; ligne NES (1/16) de la prochaine IRQ (modèle du compteur VRC4)
irq_cur16:      ds.w    1              ; ligne NES (1/16) de l'IRQ en cours
irq_cur:        ds.w    1              ; ligne NES (entière) de l'IRQ en cours
jag_in_irq:     ds.b    1              ; gestionnaire IRQ 6502 en cours (hors NMI imbriqué)
    .even
    .long
dbg_gpuwait:    ds.l    1              ; build --jagdebug : frames d'attente du GPU
gpu_dbg:        ds.l    1              ; dernière étape atteinte par le GPU
dbg_dspcount:   ds.l    1              ; compteur d'échantillons DSP à la VBL précédente
    .long
gpu_copy_busy:  ds.l    1              ; (inutilisé : VRAM/OAM copiées par le 68000 ; lu par jag_sim)
snap_pending:   ds.l    1              ; instantané en cours de rendu
snap_front:     ds.l    1              ; tampons de sprites du rendu en cours
snap_behind:    ds.l    1
disp_front:     ds.l    1              ; tampons de sprites affichés
disp_behind:    ds.l    1
snap_regs:      ds.b    SNAP_REGS_SIZE ; palette + registres de l'instantané
disp_regs:      ds.b    SNAP_REGS_SIZE ; idem pour l'image affichée
snap_vram:      ds.b    2048
snap_oam:       ds.b    256
bgo_plane:      ds.l    1
rlog_count:     ds.l    1              ; bandes enregistrées pendant la frame en cours
snap_nbands:    ds.l    1
disp_nbands:    ds.l    1
rlog_bands:     ds.b    MAX_BANDS*BAND_SIZE
snap_bands:     ds.b    MAX_BANDS*BAND_SIZE
disp_bands:     ds.b    MAX_BANDS*BAND_SIZE
    .qphrase
ObjectList:     ds.l    (OL_STOP/4)+2
    .qphrase
ObjectListM0:   ds.l    (OL_STOP/4)+2  ; listes maîtresses (affichée / en préparation)
    .qphrase
ObjectListM1:   ds.l    (OL_STOP/4)+2
    .long
    .phrase
edge_mask:      ds.l    2              ; 8 pixels de couleur 255 (cache du bord droit)

;; Tampons vidéo (phrase-alignés)
    .phrase
vid_start:
bg_planes:      ds.b    NUM_PLANES*PLANE_BYTES ; par bande : 2 nametables physiques (8 bpp)
spr_front0:     ds.b    NT_BYTES
spr_front1:     ds.b    NT_BYTES
spr_behind0:    ds.b    NT_BYTES
spr_behind1:    ds.b    NT_BYTES
vid_end:
bg_cache:       ds.l    NUM_PLANES*2*960 ; clé de la tuile rendue à chaque position
bg_ttag:        ds.l    512            ; cache des tuiles converties (gpu.s) : clés
    .phrase                            ; (lu par loadp : aligné phrase)
bg_tdata:       ds.l    512*16         ; et pixels (64 octets par tuile)
bg_rowsig:      ds.l    NUM_PLANES*2*30*16 ; signature de chaque rangée de plan (gpu.s)
spr_lists:      ds.l    256            ; rectangles des sprites dessinés, 4 calques (gpu.s)
    .if ^^defined PERFHUD
    .long
perf_idle_hl:   ds.l    1              ; HUD perfhud : demi-lignes d'attente du 68000
perf_gpu_hl:    ds.l    1              ; demi-lignes de rendu GPU
perf_vbls:      ds.w    1              ; VBL de la période en cours
perf_nmi:       ds.w    1              ; images de jeu (NMI terminés)
perf_drawn:     ds.w    1              ; images affichées
idle_vc:        ds.w    1              ; VC au début de l'attente (hle_idle)
gpu_start_vc:   ds.w    1              ; VC au départ du rendu
idle_on:        ds.b    1
gpu_on:         ds.b    1
perf_bdrop:     ds.w    1              ; images sautées : GPU pas fini (B)
perf_ldrop:     ds.w    1              ; images sautées : liste pas prête (L)
perf_txt:       ds.b    24             ; caractères affichés (index de perf_font)
    .phrase
perf_bmp:       ds.b    256*8          ; 128 x 8 pixels utiles (pas de 256 octets)
    .endif
    .long
bss_end:
