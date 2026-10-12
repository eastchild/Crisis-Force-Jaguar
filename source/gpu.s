;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Crisis Force - Code GPU (Tom)
;; gpu.s - rendu de la PPU NES dans des bitmaps 8 bpp affichés par l'OP
;;
;; Inclus par main.s en mode .gpu (assemblé pour G_RAM, copié par InitGPU).
;;
;; À chaque VBL, le 68000 copie l'état PPU (snap_vram, snap_oam, snap_regs)
;; puis met gpu_busy à 1. Le GPU :
;;   1. met à jour le décor : pour chaque tuile des 2 nametables physiques,
;;      la clé (adresse des données CHR | palette << 30) est comparée au
;;      cache bg_cache ; seules les tuiles changées sont redessinées dans
;;      bg_plane (8 bpp, pixel = palette*4 + couleur, 0 = transparent) ;
;;   2. efface au blitter les deux calques de sprites du rendu (devant /
;;      derrière le décor) et y dessine les 64 sprites de l'OAM, de 63 à 0
;;      (le sprite 0 finit au-dessus) : pixel = 16 + palette*4 + couleur ;
;;   3. remet gpu_busy à 0.
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

gpu_start:
    movei   #gpu_busy,r20
gpu_wait:
    load    (r20),r0
    cmpq    #0,r0
    jr      ne,gpu_go
    nop
    movei   #200,r1
gpu_delay:
    subq    #1,r1
    jr      ne,gpu_delay
    nop
    jr      t,gpu_wait
    nop

gpu_go:
    ;; (VRAM et OAM recopiées par le 68000 dans TakeSnapshot)
    movei   #gpu_dbg,r1
    moveq   #1,r0
    store   r0,(r1)
    movei   #gpu_bg,r0
    movei   #gpu_bg_ret,r28
    jump    t,(r0)
    nop
gpu_bg_ret:
    movei   #gpu_dbg,r1
    moveq   #2,r0
    store   r0,(r1)
    movei   #gpu_sprites,r0
    movei   #gpu_spr_ret,r28
    jump    t,(r0)
    nop
gpu_spr_ret:
    movei   #gpu_dbg,r1
    moveq   #4,r0
    store   r0,(r1)
    .if ^^defined PERFHUD
    movei   #VC,r1                     ; fin du rendu (demi-ligne) pour le HUD
    loadw   (r1),r0
    movei   #gpu_end_vc,r1
    store   r0,(r1)
    .endif
    moveq   #0,r0
    movei   #gpu_busy,r20
    store   r0,(r20)
    movei   #gpu_wait,r0
    jump    t,(r0)
    nop

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Décor, bande par bande (snap_bands) : seules les rangées de tuiles visibles
;; dans la bande sont mises à jour, dans le plan de la bande, avec ses banques
;; CHR. Variables en RAM GPU (gb_*) ; rangée : gpu_bg_rowdraw (retour r31).
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

gpu_bg:
    movei   #$3C,r9
    movei   #256,r10                   ; ligne du plan
    moveq   #4,r12                     ; rangée suivante du cache de tuiles - 4
    movei   #$3FF,r13
    movei   #snap_nbands,r0
    load    (r0),r0
    movei   #gb_left,r1
    store   r0,(r1)
    movei   #snap_bands,r0
    movei   #gb_band,r1
    store   r0,(r1)
gpu_bg_band:
    movei   #gb_left,r1
    load    (r1),r0
    cmpq    #0,r0
    movei   #gpu_bg_end,r2
    jump    eq,(r2)
    subq    #1,r0
    store   r0,(r1)
    movei   #gb_band,r1
    load    (r1),r20                   ; r20 = bande
    move    r20,r15                    ; (adressage indexé : r14/r15 seulement)
    ;; table de motifs du décor ($2000 bit 4) et banques CHR
    move    r20,r0
    addq    #B_CTRL,r0
    loadb   (r0),r7
    moveq   #$10,r0
    and     r0,r7
    shlq    #8,r7
    move    r20,r8
    addq    #B_CHR,r8
    ;; plan et cache de la bande
    load    (r15+2),r0                 ; long B_CTRL..B_PLANE : plan dans le mot bas
    shlq    #16,r0
    shrq    #16,r0
    movei   #(PLANE_BYTES>>4),r1
    mult    r0,r1
    shlq    #4,r1
    movei   #bg_planes,r2
    add     r2,r1
    movei   #gb_plane,r2
    store   r1,(r2)
    movei   #CACHE_BYTES,r1
    mult    r0,r1
    movei   #bg_cache,r2
    add     r2,r1
    movei   #gb_cache,r2
    store   r1,(r2)
    ;; rangées : de B_Y >> 3 sur ((B_Y & 7) + hauteur + 7) >> 3 rangées
    load    (r15+1),r1                 ; long B_X..B_Y : Y dans le mot bas
    shlq    #16,r1
    shrq    #16,r1                     ; Y logique
    movei   #480,r2
gpu_bg_ymod:
    cmp     r2,r1
    jr      mi,gpu_bg_yok
    nop
    jr      t,gpu_bg_ymod
    sub     r2,r1
gpu_bg_yok:
    move    r1,r3
    shrq    #3,r3                      ; première rangée (0-59)
    movei   #gb_row,r2
    store   r3,(r2)
    moveq   #7,r3
    and     r1,r3
    load    (r15),r4                   ; B_LINE0 << 16 | B_LINE1
    move    r4,r5
    shlq    #16,r5
    shrq    #16,r5                     ; B_LINE1
    shrq    #16,r4                     ; B_LINE0
    sub     r4,r5                      ; hauteur
    movei   #gpu_bg_nextband,r2
    jump    mi,(r2)                    ; hauteur négative : bande ignorée
    nop
    jump    eq,(r2)                    ; hauteur nulle
    nop
    add     r5,r3
    addq    #7,r3
    shrq    #3,r3                      ; nombre de rangées
    movei   #31,r2
    cmp     r2,r3
    jr      mi,gpu_bg_rowsok           ; au plus 31 rangées
    nop
    move    r2,r3
gpu_bg_rowsok:
    movei   #gb_rows,r2
    store   r3,(r2)
    ;; colonne logique de départ et besoin d'une 2e nametable
    load    (r15+1),r1
    shrq    #16,r1                     ; X logique (mot haut)
    move    r1,r2
    shrq    #8,r2
    moveq   #1,r3
    and     r3,r2
    movei   #gb_lx,r3
    store   r2,(r3)
    ;; colonnes visibles (X & $FF)..(X & $FF)+255 sur 64 : première colonne,
    ;; dernière (>= 32 : suite dans l'autre nametable)
    movei   #$FF,r3
    and     r3,r1
    move    r1,r2
    shrq    #3,r2
    movei   #gb_c0,r3
    store   r2,(r3)
    movei   #255,r2
    add     r2,r1
    shrq    #3,r1
    movei   #gb_twocol,r3
    store   r1,(r3)                    ; dernière colonne (0-63)
gpu_bg_rowloop:
    movei   #gb_rows,r1
    load    (r1),r0
    cmpq    #0,r0
    movei   #gpu_bg_nextband,r2
    jump    eq,(r2)
    subq    #1,r0
    store   r0,(r1)
    movei   #gb_row,r1
    load    (r1),r2                    ; rangée logique 0-59
    move    r2,r3
    addq    #1,r3
    movei   #60,r4
    cmp     r4,r3
    jr      ne,gpu_bg_rok
    nop
    moveq   #0,r3
gpu_bg_rok:
    store   r3,(r1)
    ;; rangée logique -> rangée de nametable (0-29) et rangée logique (0/1)
    moveq   #0,r3                      ; ly
    movei   #30,r4
    cmp     r4,r2
    jr      mi,gpu_bg_ly0
    nop
    sub     r4,r2
    moveq   #1,r3
gpu_bg_ly0:
    movei   #gb_ny,r4
    store   r2,(r4)                    ; rangée dans la nametable
    movei   #gb_ly,r4
    store   r3,(r4)
    movei   #gb_lx,r4
    load    (r4),r5
    movei   #gb_c0,r4
    load    (r4),r3                    ; colonnes r3..r22-1
    movei   #gb_twocol,r4
    load    (r4),r22
    addq    #1,r22
    movei   #33,r0
    cmp     r0,r22
    jr      mi,gpu_bg_e1
    nop
    movei   #32,r22
gpu_bg_e1:
    movei   #gpu_bg_coldraw,r6
    move    pc,r31
    jump    t,(r6)
    addqt   #6,r31
    movei   #gb_twocol,r4
    load    (r4),r22
    movei   #32,r0
    cmp     r0,r22
    movei   #gpu_bg_rowloop,r1
    jump    mi,(r1)                    ; dernière colonne < 32 : une seule nametable
    nop
    subq    #31,r22                    ; colonnes 0..dernière-32
    moveq   #0,r3
    movei   #gb_lx,r4
    load    (r4),r5
    moveq   #1,r0
    xor     r0,r5
    movei   #gpu_bg_coldraw,r6
    move    pc,r31
    jump    t,(r6)
    addqt   #6,r31
    movei   #gpu_bg_rowloop,r1
    jump    t,(r1)
    nop
gpu_bg_nextband:
    movei   #gb_band,r1
    load    (r1),r0
    movei   #BAND_SIZE,r2
    add     r2,r0
    store   r0,(r1)
    movei   #gpu_bg_band,r1
    jump    t,(r1)
    nop
gpu_bg_end:
    jump    t,(r28)
    nop

;; Une rangée (gb_ny) de la nametable logique colonne r5 / rangée gb_ly
;; -> nametable physique (miroir) ; retour par (r31)
gpu_bg_coldraw:
    movei   #snap_regs+SR_MIRROR,r0
    loadb   (r0),r0
    movei   #gb_ly,r1
    load    (r1),r1
    cmpq    #0,r0
    jr      eq,gpu_bg_mv               ; vertical : physique = colonne
    nop
    cmpq    #1,r0
    jr      eq,gpu_bg_mh               ; horizontal : physique = rangée
    nop
    moveq   #1,r5
    cmpq    #3,r0
    jr      eq,gpu_bg_mok
    nop
    moveq   #0,r5                      ; écran unique A
    jr      t,gpu_bg_mok
    nop
gpu_bg_mh:
    move    r1,r5
gpu_bg_mv:
gpu_bg_mok:
    move    r5,r1                      ; r1 = nametable physique (0/1)
    moveq   #1,r0
    and     r0,r1
    movei   #gb_ny,r0
    load    (r0),r2                    ; r2 = rangée (0-29)
    ;; r4 = snap_vram + nt*1024
    movei   #snap_vram,r4
    move    r1,r0
    shlq    #10,r0
    add     r0,r4
    ;; r6 = plan + nt*NT_BYTES + rangée*2048
    movei   #NT_BYTES,r6
    mult    r1,r6
    movei   #gb_plane,r0
    load    (r0),r0
    add     r0,r6
    move    r2,r0
    shlq    #11,r0
    add     r0,r6
    ;; r5 = cache + (nt*960 + rangée*32)*4
    movei   #960,r5
    mult    r1,r5
    move    r2,r0
    shlq    #5,r0
    add     r0,r5
    shlq    #2,r5
    movei   #gb_cache,r0
    load    (r0),r0
    add     r0,r5
    move    r3,r0                      ; première colonne (r3) : clé r3
    shlq    #2,r0
    add     r0,r5
    .if ^^defined NOROWSIG             ; (build --norowsig : référence sans signature)
    .else
    ;; Signature de la rangée de ce plan (bg_rowsig, 64 octets : 8 longs de
    ;; tuiles, 2 d'attributs, les 4 banques CHR du décor, colonnes rendues).
    ;; Rangée inchangée depuis son dernier rendu, colonnes r3..r22-1 déjà
    ;; couvertes : rien à faire (évite ~1300 instructions par rangée).
    move    r5,r21
    sub     r0,r21                     ; début de la rangée dans le cache
    movei   #bg_cache,r0
    sub     r0,r21
    shrq    #1,r21                     ; 128 octets de clés -> 64 de signature
    movei   #bg_rowsig,r0
    add     r0,r21                     ; r21 = signature
    move    r21,r15
    load    (r15+14),r0                ; colonnes rendues : début << 16 | fin
    movei   #gpu_bg_sdiff,r20
    move    r0,r16
    shrq    #16,r16                    ; début
    shlq    #16,r0
    shrq    #16,r0                     ; fin
    cmp     r16,r3                     ; r3 - début
    jump    mi,(r20)
    nop
    cmp     r22,r0                     ; fin - r22
    jump    mi,(r20)
    nop
    ;; comparaison déroulée (skill : pas de saut par long ; deux jeux de
    ;; registres en alternance : les lectures d'une paire précèdent la
    ;; comparaison de la précédente) ; écarts cumulés dans r25
    moveq   #0,r25
    move    r2,r14
    shlq    #5,r14
    add     r4,r14                     ; 8 longs de tuiles de la rangée
    load    (r14),r16
    load    (r15),r17
    addqt   #4,r14
    addqt   #4,r15
    load    (r14),r18
    load    (r15),r19
    addqt   #4,r14
    addqt   #4,r15
    xor     r16,r17
    or      r17,r25
    load    (r14),r16
    load    (r15),r17
    addqt   #4,r14
    addqt   #4,r15
    xor     r18,r19
    or      r19,r25
    load    (r14),r18
    load    (r15),r19
    addqt   #4,r14
    addqt   #4,r15
    xor     r16,r17
    or      r17,r25
    load    (r14),r16
    load    (r15),r17
    addqt   #4,r14
    addqt   #4,r15
    xor     r18,r19
    or      r19,r25
    load    (r14),r18
    load    (r15),r19
    addqt   #4,r14
    addqt   #4,r15
    xor     r16,r17
    or      r17,r25
    load    (r14),r16
    load    (r15),r17
    addqt   #4,r14
    addqt   #4,r15
    xor     r18,r19
    or      r19,r25
    load    (r14),r18
    load    (r15),r19
    addqt   #4,r14
    addqt   #4,r15
    xor     r16,r17
    or      r17,r25
    xor     r18,r19
    or      r19,r25
    move    r2,r14
    shrq    #2,r14
    shlq    #3,r14
    movei   #$3C0,r0
    add     r0,r14
    add     r4,r14                     ; 2 longs d'attributs
    load    (r14),r16
    load    (r15),r17
    addqt   #4,r14
    addqt   #4,r15
    load    (r14),r18
    load    (r15),r19
    addqt   #4,r14
    addqt   #4,r15
    xor     r16,r17
    or      r17,r25
    xor     r18,r19
    or      r19,r25
    move    r7,r14
    shrq    #8,r14                     ; table $0000 / $1000 -> 0 / 16 octets
    add     r8,r14                     ; 4 banques CHR du décor
    load    (r14),r16
    load    (r15),r17
    addqt   #4,r14
    addqt   #4,r15
    load    (r14),r18
    load    (r15),r19
    addqt   #4,r14
    addqt   #4,r15
    xor     r16,r17
    or      r17,r25
    load    (r14),r16
    load    (r15),r17
    addqt   #4,r14
    addqt   #4,r15
    xor     r18,r19
    or      r19,r25
    load    (r14),r18
    load    (r15),r19
    addqt   #4,r14
    addqt   #4,r15
    xor     r16,r17
    or      r17,r25
    xor     r18,r19
    or      r19,r25
    cmpq    #0,r25
    jump    ne,(r20)                   ; différence : nouvelle signature
    nop
    jump    t,(r31)                    ; identique : rangée à jour
    nop
;; r19 longs (r14)+ -> (r15)+ ; retour (r30)
gpu_bg_scpy:
    load    (r14),r16
    addqt   #4,r14
    subq    #1,r19
    store   r16,(r15)
    jr      ne,gpu_bg_scpy
    addqt   #4,r15                     ; (délai)
    jump    t,(r30)
    nop
;; Rangée changée : nouvelle signature, puis vérification tuile par tuile
gpu_bg_sdiff:
    move    r21,r15
    move    r2,r14
    shlq    #5,r14
    add     r4,r14
    moveq   #8,r19
    movei   #gpu_bg_scpy,r18
    move    pc,r30
    jump    t,(r18)
    addqt   #6,r30
    move    r2,r14
    shrq    #2,r14
    shlq    #3,r14
    movei   #$3C0,r0
    add     r0,r14
    add     r4,r14
    moveq   #2,r19
    move    pc,r30
    jump    t,(r18)
    addqt   #6,r30
    move    r7,r14
    shrq    #8,r14
    add     r8,r14
    moveq   #4,r19
    move    pc,r30
    jump    t,(r18)
    addqt   #6,r30
    move    r3,r0
    shlq    #16,r0
    or      r22,r0
    store   r0,(r15)                   ; colonnes rendues (signature + 56)
    .endif
    .if ^^defined OLDTILE              ; (build --oldtile : boucle d'origine, référence)
gpu_bg_tile:
    ;; Numéro de tuile
    move    r2,r15
    shlq    #5,r15
    add     r3,r15
    add     r4,r15
    loadb   (r15),r16                  ; r16 = tuile
    ;; Attribut : $3C0 + (ty>>2)*8 + (tx>>2)
    move    r2,r15
    shrq    #2,r15
    shlq    #3,r15
    move    r3,r17
    shrq    #2,r17
    add     r17,r15
    movei   #$3C0,r17
    add     r17,r15
    add     r4,r15
    loadb   (r15),r17
    ;; décalage = ((ty & 2) << 1) | (tx & 2)
    moveq   #2,r18
    and     r2,r18
    shlq    #1,r18
    moveq   #2,r19
    and     r3,r19
    or      r19,r18
    sh      r18,r17                    ; sh : décalage à droite si positif
    moveq   #3,r18
    and     r18,r17                    ; r17 = palette
    ;; Adresse CHR : table + tuile*16 -> banque de 1 Ko
    shlq    #4,r16
    add     r7,r16
    move    r16,r18
    shrq    #10,r18
    shlq    #2,r18
    add     r8,r18
    load    (r18),r18                  ; pointeur de la banque
    and     r13,r16
    add     r18,r16                    ; r16 = données de la tuile
    ;; Clé = données | palette << 30 ; comparaison au cache
    move    r17,r18
    shlq    #30,r18
    or      r16,r18
    load    (r5),r19
    cmp     r18,r19
    movei   #gpu_bg_next,r0
    jump    eq,(r0)
    nop
    .else
    ;; Invariants de la rangée pour la boucle des tuiles : r2 = tuiles de la
    ;; rangée, r1 = attributs ($3C0 + (ty>>2)*8), gb_rs = (ty & 2) << 1
    moveq   #2,r0
    and     r2,r0
    shlq    #1,r0
    movei   #gb_rs,r18
    store   r0,(r18)
    move    r2,r1
    shrq    #2,r1
    shlq    #3,r1
    movei   #$3C0,r0
    add     r0,r1
    add     r4,r1
    shlq    #5,r2
    add     r4,r2
gpu_bg_tile:
    ;; lectures externes lancées en premier (tuile, attribut, clé en cache) :
    ;; leur latence se recouvre avec les calculs indépendants
    move    r3,r15
    add     r2,r15
    loadb   (r15),r16                  ; tuile
    move    r3,r17
    shrq    #2,r17
    add     r1,r17
    loadb   (r17),r17                  ; attribut : $3C0 + (ty>>2)*8 + (tx>>2)
    movei   #gb_rs,r18
    load    (r18),r18
    moveq   #2,r19
    and     r3,r19
    or      r19,r18                    ; décalage = ((ty & 2) << 1) | (tx & 2)
    load    (r5),r19                   ; clé en cache
    ;; adresse CHR : table + tuile*16 -> banque de 1 Ko
    shlq    #4,r16
    add     r7,r16
    move    r16,r0
    shrq    #10,r0
    shlq    #2,r0
    add     r8,r0
    load    (r0),r0                    ; pointeur de la banque
    sh      r18,r17                    ; sh : décalage à droite si positif
    moveq   #3,r18
    and     r18,r17                    ; r17 = palette
    and     r13,r16
    move    r17,r18
    shlq    #30,r18
    add     r0,r16                     ; r16 = données de la tuile
    or      r16,r18                    ; clé = données | palette << 30
    cmp     r18,r19
    movei   #gpu_bg_next,r0
    jump    eq,(r0)
    nop
    .endif
    store   r18,(r5)
    ;; Cache des tuiles converties (bg_tdata : 64 octets, rangées de 8 pixels
    ;; 8 bpp) : entrée ((données >> 4) ^ (palette << 7)) & 511, clé (même
    ;; forme que bg_cache) dans bg_ttag. Les décors animés par banque CHR
    ;; (eau...) répètent peu de tuiles : une conversion, puis des copies.
    move    r16,r19
    shrq    #4,r19
    move    r17,r0
    shlq    #7,r0
    xor     r0,r19
    movei   #511,r0
    and     r0,r19
    move    r19,r11
    shlq    #6,r11
    movei   #bg_tdata,r0
    add     r0,r11                     ; r11 = tuile convertie
    shlq    #2,r19
    movei   #bg_ttag,r0
    add     r0,r19
    load    (r19),r0
    cmp     r18,r0
    movei   #gpu_bg_copy,r0
    jump    eq,(r0)
    nop
    store   r18,(r19)
    move    r11,r21                    ; conversion dans le cache
    ;; Plans : rangées 0-3 puis 4-7 (adressage indexé : r15 seulement)
    move    r16,r15
    load    (r15),r23                  ; plan 0, rangées 0-3
    load    (r15+2),r24                ; plan 1, rangées 0-3 (octets 8-11)
    load    (r15+1),r29                ; plan 0, rangées 4-7
    load    (r15+3),r30                ; plan 1, rangées 4-7
    ;; Tables (RAM GPU) de cette palette : gpu_bgt + palette * 128, plan 0
    ;; (r14) puis plan 1 (r15 = r14 + 64)
    move    r17,r14
    shlq    #7,r14
    movei   #gpu_bgt,r0
    add     r0,r14
    move    r14,r15
    addq    #32,r15
    addq    #32,r15
    movei   #gpu_bg_rows,r27
    move    pc,r26
    jump    t,(r27)
    addqt   #6,r26                     ; retour après le saut (délai)
    move    r29,r23
    move    r30,r24
    move    pc,r26
    jump    t,(r27)
    addqt   #6,r26
gpu_bg_copy:
    ;; tuile convertie (r11) -> plan : 8 rangées d'une phrase (8 pixels),
    ;; pas de 256 ; accès par phrases (bus de 64 bits : moitié moins
    ;; d'accès à la RAM principale qu'en longs). Adresses alignées phrase.
    move    r11,r14
    move    r3,r15
    shlq    #3,r15
    add     r6,r15
    loadp   (r14),r23                  ; phrase : long haut dans G_HIDATA
    addq    #8,r14
    storep  r23,(r15)                  ; G_HIDATA -> long haut
    add     r10,r15
    loadp   (r14),r23                  ; phrase : long haut dans G_HIDATA
    addq    #8,r14
    storep  r23,(r15)                  ; G_HIDATA -> long haut
    add     r10,r15
    loadp   (r14),r23                  ; phrase : long haut dans G_HIDATA
    addq    #8,r14
    storep  r23,(r15)                  ; G_HIDATA -> long haut
    add     r10,r15
    loadp   (r14),r23                  ; phrase : long haut dans G_HIDATA
    addq    #8,r14
    storep  r23,(r15)                  ; G_HIDATA -> long haut
    add     r10,r15
    loadp   (r14),r23                  ; phrase : long haut dans G_HIDATA
    addq    #8,r14
    storep  r23,(r15)                  ; G_HIDATA -> long haut
    add     r10,r15
    loadp   (r14),r23                  ; phrase : long haut dans G_HIDATA
    addq    #8,r14
    storep  r23,(r15)                  ; G_HIDATA -> long haut
    add     r10,r15
    loadp   (r14),r23                  ; phrase : long haut dans G_HIDATA
    addq    #8,r14
    storep  r23,(r15)                  ; G_HIDATA -> long haut
    add     r10,r15
    loadp   (r14),r23                  ; phrase : long haut dans G_HIDATA
    addq    #8,r14
    storep  r23,(r15)                  ; G_HIDATA -> long haut
    add     r10,r15
gpu_bg_next:
    addq    #1,r3
    addq    #4,r5
    cmp     r22,r3                     ; colonne de fin (exclue)
    movei   #gpu_bg_tile,r0
    jump    ne,(r0)
    nop
    jump    t,(r31)
    nop

;; 4 rangées d'une tuile : r23 = plan 0 (rangée k dans l'octet haut), r24 = plan 1
;; r21 = destination (avance de 4 lignes), r14 / r15 = tables de la palette
;; en RAM GPU (gpu_bgt : quartet du plan -> 4 pixels ; pixel = OU des deux
;; plans), r9 = $3C, r12 = 4 (rangée suivante du cache - 4), r26 = retour
gpu_bg_rows:
    moveq   #4,r25
    movei   #gpu_bg_row1,r20
gpu_bg_row1:
    rorq    #24,r23                    ; octet suivant en bas
    rorq    #24,r24
    ;; index * 4 : quartets hauts (pixels 0-3) = bits 7-4 >> 2, bas << 2
    ;; (les 4 lectures à la suite : leur latence se recouvre)
    move    r23,r17
    move    r24,r18
    move    r23,r19
    move    r24,r16
    shrq    #2,r17
    shrq    #2,r18
    shlq    #2,r19
    shlq    #2,r16
    and     r9,r17
    and     r9,r18
    and     r9,r19
    and     r9,r16
    load    (r14+r17),r17
    load    (r15+r18),r18
    load    (r14+r19),r19
    load    (r15+r16),r16
    or      r18,r17
    or      r16,r19
    store   r17,(r21)
    addq    #4,r21
    store   r19,(r21)
    subq    #1,r25
    jump    ne,(r20)
    add     r12,r21                    ; ligne suivante (délai)
    jump    t,(r26)
    nop

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Sprites
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

gpu_sprites:
    ;; Effacement des sprites dessinés la dernière fois dans ces deux calques
    ;; (rectangles notés au dessin : bien moins d'écritures qu'un effacement
    ;; complet au blitter)
    movei   #snap_front,r0
    load    (r0),r1
    movei   #gs_logf,r29
    movei   #gpu_clear_rects,r2
    move    pc,r26
    jump    t,(r2)
    addq    #6,r26
    movei   #snap_behind,r0
    load    (r0),r1
    movei   #gs_logb,r29
    movei   #gpu_clear_rects,r2
    move    pc,r26
    jump    t,(r2)
    addq    #6,r26
    movei   #gpu_dbg,r1
    moveq   #3,r0
    store   r0,(r1)
    ;; Priorité NES entre sprites : un sprite « derrière » de plus petit indice
    ;; masque aussi les sprites « devant » (le décor opaque passe devant les
    ;; deux) -> ses pixels effacent le calque devant (écart gs_delta)
    movei   #snap_front,r0
    load    (r0),r1
    movei   #snap_behind,r0
    load    (r0),r2
    sub     r2,r1
    movei   #gs_delta,r0
    store   r1,(r0)
    ;; Paramètres
    movei   #snap_regs,r8
    movei   #SR_CTRL,r0
    add     r8,r0
    loadb   (r0),r7                    ; $2000
    ;; Banques CHR des sprites par bande (le jeu les change en cours d'image,
    ;; ex. intro : banque vide sous la ligne 172) : table (fin de bande,
    ;; pointeurs CHR de la bande) dans gs_bandtab
    movei   #snap_nbands,r0
    load    (r0),r1
    movei   #snap_bands,r2
    movei   #gs_bandtab,r3
    movei   #$FFFF,r4
    movei   #BAND_SIZE,r5
gsb_build:
    load    (r2),r0                    ; B_LINE0 << 16 | B_LINE1
    and     r4,r0
    subq    #1,r1
    jr      ne,gsb_notlast
    nop
    move    r4,r0                      ; dernière bande : jusqu'au bout
gsb_notlast:
    store   r0,(r3)
    addq    #4,r3
    move    r2,r0
    addq    #B_CHR,r0
    store   r0,(r3)
    addq    #4,r3
    cmpq    #0,r1
    jr      ne,gsb_build
    add     r5,r2                      ; (délai) bande suivante
    movei   #gpu_revnib,r9
    moveq   #$0F,r10
    movei   #$3FF,r13
    movei   #snap_oam+252,r4           ; sprite 63
    moveq   #0,r0
    bset    #6,r0                      ; 64 sprites
    move    r0,r5
gpu_spr_loop:
    load    (r4),r1                    ; y | tuile | attr | x
    move    r1,r11
    shrq    #8,r11
    movei   #$FF,r0
    and     r0,r11                     ; attributs
    move    r1,r2
    shrq    #24,r2                     ; y
    btst    #4,r11                     ; morceau au bord haut (Y négatif, rt_wr_4014)
    jr      ne,gpu_spr_yneg
    nop
    movei   #$EF,r0
    cmp     r0,r2
    movei   #gpu_spr_next,r0
    jump    cc,(r0)                    ; y >= $EF (pas de retenue : y - $EF >= 0)
    nop
    jr      t,gpu_spr_yok
    nop
gpu_spr_yneg:
    movei   #256,r0
    sub     r0,r2                      ; y - 256
gpu_spr_yok:
    move    r1,r3
    shrq    #16,r3
    movei   #$FF,r0
    and     r0,r3                      ; tuile
    and     r0,r1                      ; x
    btst    #3,r11                     ; morceau au bord gauche (X négatif)
    jr      eq,gpu_spr_xok
    nop
    movei   #256,r0
    sub     r0,r1                      ; x - 256
gpu_spr_xok:
    ;; Calque : bit 5 = derrière le décor
    movei   #snap_front,r0
    movei   #gs_logf,r29
    btst    #5,r11
    jr      eq,gpu_spr_lay
    nop
    movei   #snap_behind,r0
    movei   #gs_logb,r29
gpu_spr_lay:
    load    (r0),r14                   ; calque
    ;; Rectangle noté pour l'effacement : bit 31 = 8x16, ligne y+1, x
    ;; (ramenés à 0 pour les morceaux au bord : effacer plus large est sans effet)
    load    (r29),r30
    move    r2,r15
    addq    #1,r15
    jr      pl,gpu_spr_lg1
    nop
    moveq   #0,r15
gpu_spr_lg1:
    shlq    #16,r15
    move    r1,r0
    cmpq    #0,r0
    jr      pl,gpu_spr_lg2
    nop
    moveq   #0,r0
gpu_spr_lg2:
    or      r0,r15
    btst    #5,r7
    jr      eq,gpu_spr_log8
    nop
    bset    #31,r15
gpu_spr_log8:
    store   r15,(r30)
    addq    #4,r30
    store   r30,(r29)
    ;; r29 = écart vers le calque devant pour un sprite « derrière », 0 sinon
    moveq   #0,r29
    btst    #5,r11
    jr      eq,gpu_spr_front
    nop
    movei   #gs_delta,r29
    load    (r29),r29
gpu_spr_front:
    ;; Hauteur, table et première tuile
    moveq   #8,r12                     ; hauteur
    btst    #5,r7
    jr      eq,gpu_spr_8x8
    nop
    moveq   #16,r12
    moveq   #1,r15
    and     r3,r15
    shlq    #12,r15                    ; table = (tuile & 1) * $1000
    moveq   #1,r0
    not     r0
    and     r0,r3                      ; tuile paire
    jr      t,gpu_spr_tab
    nop
gpu_spr_8x8:
    moveq   #8,r15
    and     r7,r15
    shlq    #9,r15                     ; bit 3 de $2000 -> $1000
gpu_spr_tab:
    shlq    #4,r3
    add     r15,r3                     ; r3 = adresse CHR de la première tuile
    ;; Couleur de base : 16 + palette*4
    moveq   #3,r16
    and     r11,r16
    shlq    #2,r16
    addq    #16,r16
    ;; Ligne écran de départ : y + 1
    addq    #1,r2
    moveq   #0,r6                      ; rangée r dans le sprite
gpu_spr_row:
    ;; Ligne écran y+1+r : < 0 (morceau au bord haut) -> rangée suivante ; < 240
    move    r2,r17
    add     r6,r17
    movei   #gpu_spr_rownext,r0
    jump    mi,(r0)
    nop
    movei   #240,r0
    cmp     r0,r17
    movei   #gpu_spr_next,r0
    jump    cc,(r0)                    ; hors écran : sprite terminé
    nop
    ;; Rangée source : miroir vertical -> h-1-r
    move    r6,r18
    btst    #7,r11
    jr      eq,gpu_spr_nov
    nop
    move    r12,r18
    subq    #1,r18
    sub     r6,r18
gpu_spr_nov:
    ;; r8 = pointeurs CHR de la bande qui contient la ligne r17
    movei   #gs_bandtab,r19
gsb_find:
    load    (r19),r0
    cmp     r0,r17
    jr      cs,gsb_found               ; ligne < fin de bande
    nop
    jr      t,gsb_find
    addq    #8,r19                     ; (délai)
gsb_found:
    addq    #4,r19
    load    (r19),r8
    ;; adresse = base + (rangée>>3)*16 + (rangée&7)
    move    r18,r19
    shrq    #3,r19
    shlq    #4,r19
    moveq   #7,r0
    and     r0,r18
    add     r19,r18
    add     r3,r18
    move    r18,r19
    shrq    #10,r19
    shlq    #2,r19
    add     r8,r19
    load    (r19),r19
    and     r13,r18
    add     r19,r18
    loadb   (r18),r21                  ; plan 0
    addq    #8,r18
    loadb   (r18),r22                  ; plan 1
    move    r21,r0
    or      r22,r0
    movei   #gpu_spr_rownext,r19
    cmpq    #0,r0
    jump    eq,(r19)
    nop
    ;; Miroir horizontal : inversion des bits des deux plans
    btst    #6,r11
    jr      eq,gpu_spr_nohf
    nop
    move    r21,r0
    movei   #gpu_rev8,r19
    move    pc,r25
    jump    t,(r19)
    addq    #6,r25
    move    r0,r21
    move    r22,r0
    move    pc,r25
    jump    t,(r19)
    addq    #6,r25
    move    r0,r22
gpu_spr_nohf:
    ;; Destination : calque + ligne*256 + x
    move    r17,r23
    shlq    #8,r23
    add     r14,r23
    add     r1,r23
    move    r1,r24                     ; x courant
    moveq   #8,r25
    movei   #256,r27
    movei   #gpu_spr_px,r20
gpu_spr_px:
    move    r21,r0
    shrq    #7,r0
    moveq   #1,r19
    and     r19,r0
    move    r22,r19
    shrq    #6,r19
    moveq   #2,r15
    and     r15,r19
    or      r19,r0                     ; couleur 0-3
    shlq    #1,r21
    shlq    #1,r22
    cmpq    #0,r0
    jr      eq,gpu_spr_skip
    cmp     r27,r24                    ; (délai) x < 256 ?
    jr      cc,gpu_spr_skip
    add     r16,r0                     ; (délai)
    storeb  r0,(r23)
    cmpq    #0,r29
    jr      eq,gpu_spr_skip
    move    r23,r30                    ; (délai)
    add     r29,r30
    moveq   #0,r19
    storeb  r19,(r30)                  ; pixel transparent dans le calque devant
gpu_spr_skip:
    addq    #1,r23
    subq    #1,r25
    jump    ne,(r20)
    addq    #1,r24                     ; (délai)
gpu_spr_rownext:
    addq    #1,r6
    cmp     r12,r6
    movei   #gpu_spr_row,r0
    jump    ne,(r0)
    nop
gpu_spr_next:
    subq    #4,r4
    subq    #1,r5
    movei   #gpu_spr_loop,r0
    jump    ne,(r0)
    nop
    ;; Fin des listes de rectangles des deux calques
    movei   #gs_logf,r0
    load    (r0),r1
    addq    #4,r0
    load    (r0),r2
    store   r1,(r2)
    movei   #gs_logb,r0
    load    (r0),r1
    addq    #4,r0
    load    (r0),r2
    store   r1,(r2)
    jump    t,(r28)
    nop

;; Effacement des rectangles notés lors du dernier dessin dans le calque r1 ;
;; r29 = gs_logf / gs_logb (prépare la liste de ce calque pour le dessin).
;; Retour par r26.
gpu_clear_rects:
    moveq   #0,r2                      ; index du calque
    movei   #spr_front1,r0
    cmp     r0,r1
    jr      ne,gcr_i1
    nop
    moveq   #1,r2
gcr_i1:
    movei   #spr_behind0,r0
    cmp     r0,r1
    jr      ne,gcr_i2
    nop
    moveq   #2,r2
gcr_i2:
    movei   #spr_behind1,r0
    cmp     r0,r1
    jr      ne,gcr_i3
    nop
    moveq   #3,r2
gcr_i3:
    move    r2,r3
    shlq    #8,r3
    movei   #spr_lists,r0
    add     r0,r3                      ; r3 = début de la liste
    move    r2,r4
    shlq    #2,r4
    movei   #spr_end,r0
    add     r0,r4                      ; r4 = emplacement de sa fin
    store   r3,(r29)                   ; le dessin repart du début de la liste
    addq    #4,r29
    store   r4,(r29)
    load    (r4),r5                    ; fin de la liste du dernier dessin
    movei   #240,r6
    movei   #255,r7
    moveq   #0,r17
    movei   #256,r19
    movei   #gcr_entry,r8
    movei   #gcr_row,r9
gcr_entry:
    cmp     r5,r3
    jr      ne,gcr_e1
    nop
    jump    t,(r26)
    nop
gcr_e1:
    load    (r3),r10
    addq    #4,r3
    move    r10,r11
    shlq    #24,r11
    shrq    #24,r11                    ; x
    move    r10,r12
    shlq    #8,r12
    shrq    #24,r12                    ; première ligne
    moveq   #8,r13                     ; hauteur
    btst    #31,r10
    jr      eq,gcr_h8
    nop
    moveq   #16,r13
gcr_h8:
    ;; mots longs : (min(x+7, 255) >> 2) - (x >> 2) + 1
    move    r11,r14
    addq    #7,r14
    cmp     r7,r14
    jr      mi,gcr_w
    nop
    move    r7,r14
gcr_w:
    shrq    #2,r14
    move    r11,r15
    shrq    #2,r15
    sub     r15,r14
    addq    #1,r14
    ;; adresse : calque + ligne*256 + (x & ~3)
    move    r12,r16
    shlq    #8,r16
    add     r1,r16
    shlq    #2,r15
    add     r15,r16
gcr_row:
    cmp     r6,r12
    jump    cc,(r8)                    ; ligne >= 240 : entrée suivante
    nop
    move    r16,r18
    store   r17,(r18)
    addq    #4,r18
    store   r17,(r18)
    cmpq    #3,r14
    jr      ne,gcr_r2
    addq    #4,r18                     ; (délai)
    store   r17,(r18)
gcr_r2:
    add     r19,r16
    addq    #1,r12
    subq    #1,r13
    jump    ne,(r9)
    nop
    jump    t,(r8)
    nop

;; r0 = octet -> r0 = octet aux bits inversés (r9 = table des quartets inversés)
gpu_rev8:
    move    r0,r15
    and     r10,r15
    shlq    #2,r15
    add     r9,r15
    load    (r15),r15                  ; inverse du quartet bas -> quartet haut
    shlq    #4,r15
    shrq    #4,r0
    and     r10,r0
    shlq    #2,r0
    add     r9,r0
    load    (r0),r0
    or      r15,r0
    jump    t,(r25)
    nop

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Tables (RAM GPU)
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

    .long
;; Rectangles des sprites dessinés, par calque (devant 0/1, derrière 0/1)
gs_bandtab: dcb.l   2*MAX_BANDS,0      ; (fin de bande, pointeurs CHR) par bande
gs_delta:   dc.l    0                  ; calque devant - calque derrière
gs_logf:    dc.l    0                  ; prochaine entrée de la liste du calque devant
gs_endf:    dc.l    0                  ; emplacement de fin de cette liste (spr_end)
gs_logb:    dc.l    0
gs_endb:    dc.l    0
spr_end:    dc.l    spr_lists,spr_lists+256,spr_lists+512,spr_lists+768
;; Rendu du décor : par palette p (128 octets), quartet b3..b0 d'un plan
;; -> 4 pixels (b3 = pixel de gauche = octet fort) : plan 0 = 1 | p*4,
;; plan 1 = 2 | p*4 ; pixel = OU des deux (couleur 0 -> 0)
gpu_bgt:
    dc.l    $00000000,$00000001,$00000100,$00000101,$00010000,$00010001,$00010100,$00010101
    dc.l    $01000000,$01000001,$01000100,$01000101,$01010000,$01010001,$01010100,$01010101
    dc.l    $00000000,$00000002,$00000200,$00000202,$00020000,$00020002,$00020200,$00020202
    dc.l    $02000000,$02000002,$02000200,$02000202,$02020000,$02020002,$02020200,$02020202
    dc.l    $00000000,$00000005,$00000500,$00000505,$00050000,$00050005,$00050500,$00050505
    dc.l    $05000000,$05000005,$05000500,$05000505,$05050000,$05050005,$05050500,$05050505
    dc.l    $00000000,$00000006,$00000600,$00000606,$00060000,$00060006,$00060600,$00060606
    dc.l    $06000000,$06000006,$06000600,$06000606,$06060000,$06060006,$06060600,$06060606
    dc.l    $00000000,$00000009,$00000900,$00000909,$00090000,$00090009,$00090900,$00090909
    dc.l    $09000000,$09000009,$09000900,$09000909,$09090000,$09090009,$09090900,$09090909
    dc.l    $00000000,$0000000A,$00000A00,$00000A0A,$000A0000,$000A000A,$000A0A00,$000A0A0A
    dc.l    $0A000000,$0A00000A,$0A000A00,$0A000A0A,$0A0A0000,$0A0A000A,$0A0A0A00,$0A0A0A0A
    dc.l    $00000000,$0000000D,$00000D00,$00000D0D,$000D0000,$000D000D,$000D0D00,$000D0D0D
    dc.l    $0D000000,$0D00000D,$0D000D00,$0D000D0D,$0D0D0000,$0D0D000D,$0D0D0D00,$0D0D0D0D
    dc.l    $00000000,$0000000E,$00000E00,$00000E0E,$000E0000,$000E000E,$000E0E00,$000E0E0E
    dc.l    $0E000000,$0E00000E,$0E000E00,$0E000E0E,$0E0E0000,$0E0E000E,$0E0E0E00,$0E0E0E0E
;; Quartet aux bits inversés
gpu_revnib:
    dc.l    $0,$8,$4,$C,$2,$A,$6,$E,$1,$9,$5,$D,$3,$B,$7,$F
;; Variables du rendu du décor
gb_left:    dc.l    0                  ; bandes restantes
gb_band:    dc.l    0                  ; bande courante
gb_plane:   dc.l    0                  ; plan de la bande
gb_cache:   dc.l    0                  ; cache du plan
gb_row:     dc.l    0                  ; rangée logique courante (0-59)
gb_rows:    dc.l    0                  ; rangées restantes
gb_lx:      dc.l    0                  ; colonne logique de départ
gb_twocol:  dc.l    0                  ; dernière colonne visible (0-63 ; >= 32 : 2 nametables)
gb_c0:      dc.l    0                  ; première colonne visible
gb_ny:      dc.l    0                  ; rangée dans la nametable (0-29)
gb_ly:      dc.l    0                  ; rangée logique (0/1)
gb_rs:      dc.l    0                  ; (rangée & 2) << 1 : décalage des attributs
;; Partagé avec le 68000 (accès en move.l seulement) : 1 = rendu demandé /
;; en cours, remis à 0 par le GPU (lu en RAM locale par gpu_wait)
gpu_busy:   dc.l    0
    .if ^^defined PERFHUD
gpu_end_vc: dc.l    0                  ; VC à la fin du dernier rendu (HUD perfhud)
    .endif
gpu_end:
