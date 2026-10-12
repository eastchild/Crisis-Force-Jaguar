;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Crisis Force - Code DSP (Jerry)
;; dsp.s - émulation de l'APU NES (son)
;;
;; Inclus par main.s en mode .dsp (assemblé pour D_RAM, copié par InitDSP).
;;
;; Le 68000 (rt_wr_apu, nes_runtime.s) dépose chaque écriture de registre
;; APU ($4000-$4017) dans l'anneau dsp_ring : long = (registre << 8) | valeur,
;; puis avance dsp_ring_wr. Le DSP :
;;   - boucle principale (banc 1) : applique les écritures (registres des
;;     voies, compteurs de durée, enveloppes, sweep, DMC), fait tourner le
;;     séquenceur de trame (240 Hz, quarts et demi-trames) et calcule les
;;     paramètres de synthèse dans dsp_params ;
;;   - interruption I2S (banc 0) : un échantillon à 25 971 Hz à partir de
;;     dsp_params : 2 carrés, triangle, bruit LFSR, DMC (DPCM décodé à la
;;     volée depuis la PRG-ROM), mixage, filtre anti-continu.
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

DSP_SCLK        equ 15                 ; 26 593 900 / (64 * 16) = 25 971 Hz
DSP_SMODE       equ $15
QF_SAMPLES      equ 108                ; échantillons par quart de trame (25971/240)

;; Mixage (approximation linéaire du mélangeur NES), sortie 16 bits signée
MIX_PULSE       equ 226
MIX_TRI         equ 255
MIX_NOISE       equ 148
MIX_DMC         equ 100
MIX_OFFSET      equ 12000

;; Paramètres de synthèse (dsp_params, longs) : index pour load (r14+n)
P_P1INC     equ 1
P_P1DUTY    equ 2
P_P1VOL     equ 3
P_P2INC     equ 4
P_P2DUTY    equ 5
P_P2VOL     equ 6
P_TRIINC    equ 7
P_NOISEINC  equ 8
P_NOISETAP  equ 9
P_NOISEVOL  equ 10
P_DMCTRIG   equ 11                     ; incrémenté : (re)lancer l'échantillon
P_DMCADDR   equ 12                     ; adresse hôte du premier octet
P_DMCLEN    equ 13                     ; octets
P_DMCINC    equ 14                     ; bits par échantillon (16.16)
P_DMCLOOP   equ 15
P_DMCLVTRIG equ 16                     ; incrémenté : niveau direct ($4011)
P_DMCLEVEL  equ 17
P_DMCSTOP   equ 18                     ; incrémenté : arrêt ($4015 bit 4 à 0)

;; État d'une voie carrée (longs, index pour load (r15+n))
C_DUTY      equ 1
C_CONST     equ 2
C_HALT      equ 3                      ; arrêt du compteur de durée / boucle d'enveloppe
C_VOL       equ 4
C_ESTART    equ 5
C_EDIV      equ 6
C_EDECAY    equ 7
C_TIMER     equ 8
C_LENGTH    equ 9
C_SWEN      equ 10
C_SWPER     equ 11
C_SWNEG     equ 12
C_SWSHIFT   equ 13
C_SWRELOAD  equ 14
C_SWDIV     equ 15
C_ENABLED   equ 16
C_ONES      equ 17                     ; 1 pour le carré 1 (complément à un du sweep)
C_LINRELOAD equ 18                     ; triangle : rechargement du compteur linéaire
C_LINEAR    equ 19
C_LINVAL    equ 20
C_MODE      equ 21                     ; bruit : mode court
C_PERIOD    equ 22                     ; bruit : index de période
CH_SIZE     equ 24                     ; longs par voie

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Vecteurs d'interruption (16 octets chacun à partir de D_RAM)
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

dsp_vector_cpu:
    movei   #dsp_start,r0
    jump    t,(r0)
    nop
    nop
    nop
    nop
dsp_vector_i2s:                        ; D_RAM + $10
    movei   #dsp_i2s_isr,r28
    jump    t,(r28)
    nop
    nop
    nop
    nop

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Démarrage (banc 0) : état du synthé, puis boucle principale en banc 1
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

dsp_start:
    movei   #D_ENDRAM,r31
    moveq   #0,r1                      ; phases des carrés
    moveq   #0,r2
    moveq   #0,r3                      ; phase du triangle
    moveq   #0,r4                      ; accumulateur du bruit
    moveq   #1,r5                      ; LFSR
    moveq   #0,r6                      ; DMC : adresse de l'octet suivant
    moveq   #0,r7                      ; DMC : fraction de bit
    movei   #64,r8                     ; DMC : niveau
    moveq   #0,r9                      ; DMC : octets restants
    moveq   #0,r10                     ; DMC : dernier déclenchement vu
    moveq   #0,r11                     ; compteur d'échantillons
    movei   #-MIX_OFFSET,r12           ; filtre : x(n-1)
    moveq   #0,r13                     ; filtre : y(n-1)
    movei   #dsp_params,r14
    moveq   #0,r26                     ; DMC : registre à décalage
    moveq   #0,r27                     ; DMC : bits restants dans l'octet
    movei   #D_DIVCTRL,r15
    moveq   #0,r16
    store   r16,(r15)                  ; division entière (pas 16.16)
    movei   #SCLK,r15
    movei   #DSP_SCLK,r16
    store   r16,(r15)
    movei   #SMODE,r15
    movei   #DSP_SMODE,r16
    store   r16,(r15)
    movei   #D_FLAGS,r15
    movei   #D_I2SENA|REGPAGE,r16
    store   r16,(r15)
    nop
    nop

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Boucle principale (banc 1)
;; r14 = dsp_params  r20 = anneau  r21 = &index d'écriture  r22 = index de lecture
;; r23 = dsp_sample_count  r24 = échantillon du prochain quart de trame
;; r25 = pas du séquenceur (0-3)
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

    movei   #dsp_params,r14
    movei   #dsp_ring,r20
    movei   #dsp_ring_wr,r21
    moveq   #0,r22
    movei   #dsp_sample_count,r23
    movei   #QF_SAMPLES,r24
    moveq   #0,r25
    ;; Carré 1 : sweep en complément à un
    movei   #dsp_ch_p1,r15
    moveq   #1,r0
    store   r0,(r15+C_ONES)

dsp_main:
    ;; 1. écritures APU en attente
    load    (r21),r0
    cmp     r22,r0
    movei   #dsp_no_write,r1
    jump    eq,(r1)
    nop
    move    r22,r1
    shlq    #2,r1
    add     r20,r1
    load    (r1),r2                    ; (registre << 8) | valeur
    addq    #1,r22
    movei   #63,r1
    and     r1,r22
    move    r2,r3
    movei   #$FF,r1
    and     r1,r3                      ; r3 = valeur
    shrq    #8,r2
    moveq   #$1F,r1
    and     r1,r2                      ; r2 = registre (0-$17)
    ;; saut par table
    movei   #dsp_reg_table,r1
    shlq    #2,r2
    add     r2,r1
    load    (r1),r1
    movei   #dsp_after_write,r28       ; retour
    jump    t,(r1)
    nop
dsp_after_write:
    movei   #dsp_update,r1
    move    pc,r29
    jump    t,(r1)
    addqt   #6,r29
    movei   #dsp_main,r1
    jump    t,(r1)
    nop

dsp_no_write:
    ;; 2. séquenceur de trame : un quart toutes les QF_SAMPLES
    load    (r23),r0
    cmp     r24,r0                     ; r0 - r24
    movei   #dsp_main,r1
    jump    mi,(r1)                    ; pas encore
    nop
    movei   #QF_SAMPLES,r1
    add     r1,r24
    movei   #dsp_quarter,r1
    move    pc,r29
    jump    t,(r1)
    addqt   #6,r29
    ;; demi-trame aux pas 1 et 3
    btst    #0,r25
    movei   #dsp_no_half,r1
    jump    eq,(r1)
    nop
    movei   #dsp_half,r1
    move    pc,r29
    jump    t,(r1)
    addqt   #6,r29
dsp_no_half:
    addq    #1,r25
    moveq   #3,r1
    and     r1,r25
    movei   #dsp_update,r1
    move    pc,r29
    jump    t,(r1)
    addqt   #6,r29
    movei   #dsp_main,r1
    jump    t,(r1)
    nop

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Écritures de registres : r3 = valeur ; retour par (r28)
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

;; $4000 / $4004 / $400C : DDLC VVVV (rapport cyclique, arrêt, constant, volume)
dsp_w_p1_0:
    movei   #dsp_ch_p1,r15
    jr      t,dsp_w_env
    nop
dsp_w_p2_0:
    movei   #dsp_ch_p2,r15
    jr      t,dsp_w_env
    nop
dsp_w_n_0:
    movei   #dsp_ch_noise,r15
dsp_w_env:
    move    r3,r0
    shrq    #6,r0
    store   r0,(r15+C_DUTY)
    move    r3,r0
    shrq    #5,r0
    moveq   #1,r1
    and     r1,r0
    store   r0,(r15+C_HALT)
    move    r3,r0
    shrq    #4,r0
    and     r1,r0
    store   r0,(r15+C_CONST)
    moveq   #15,r0
    and     r3,r0
    store   r0,(r15+C_VOL)
    jump    t,(r28)
    nop

;; $4001 / $4005 : EPPP NSSS (sweep)
dsp_w_p1_1:
    movei   #dsp_ch_p1,r15
    jr      t,dsp_w_sweep
    nop
dsp_w_p2_1:
    movei   #dsp_ch_p2,r15
dsp_w_sweep:
    move    r3,r0
    shrq    #7,r0
    store   r0,(r15+C_SWEN)
    move    r3,r0
    shrq    #4,r0
    moveq   #7,r1
    and     r1,r0
    store   r0,(r15+C_SWPER)
    move    r3,r0
    shrq    #3,r0
    moveq   #1,r2
    and     r2,r0
    store   r0,(r15+C_SWNEG)
    move    r3,r0
    and     r1,r0
    store   r0,(r15+C_SWSHIFT)
    moveq   #1,r0
    store   r0,(r15+C_SWRELOAD)
    jump    t,(r28)
    nop

;; $4002 / $4006 / $400A : période, bits 0-7
dsp_w_p1_2:
    movei   #dsp_ch_p1,r15
    jr      t,dsp_w_tlo
    nop
dsp_w_p2_2:
    movei   #dsp_ch_p2,r15
    jr      t,dsp_w_tlo
    nop
dsp_w_t_2:
    movei   #dsp_ch_tri,r15
dsp_w_tlo:
    load    (r15+C_TIMER),r0
    movei   #$700,r1
    and     r1,r0
    or      r3,r0
    store   r0,(r15+C_TIMER)
    jump    t,(r28)
    nop

;; $4003 / $4007 : LLLL LTTT (durée, période bits 8-10) + redémarrage enveloppe
dsp_w_p1_3:
    movei   #dsp_ch_p1,r15
    jr      t,dsp_w_thi
    nop
dsp_w_p2_3:
    movei   #dsp_ch_p2,r15
dsp_w_thi:
    moveq   #1,r0
    store   r0,(r15+C_ESTART)
dsp_w_thi2:
    load    (r15+C_TIMER),r0
    movei   #$FF,r1
    and     r1,r0
    moveq   #7,r1
    and     r3,r1
    shlq    #8,r1
    or      r1,r0
    store   r0,(r15+C_TIMER)
dsp_w_len:
    load    (r15+C_ENABLED),r0
    cmpq    #0,r0
    jr      eq,dsp_w_len0
    nop
    move    r3,r0
    shrq    #3,r0
    shlq    #2,r0
    movei   #dsp_length_table,r1
    add     r1,r0
    load    (r0),r0
    or      r0,r0                     ; résultat du load lu (bogue du scoreboard)
    store   r0,(r15+C_LENGTH)
dsp_w_len0:
    jump    t,(r28)
    nop

;; $4008 : CRRR RRRR (arrêt / contrôle, rechargement linéaire)
dsp_w_t_0:
    movei   #dsp_ch_tri,r15
    move    r3,r0
    shrq    #7,r0
    store   r0,(r15+C_HALT)
    movei   #$7F,r0
    and     r3,r0
    store   r0,(r15+C_LINVAL)
    jump    t,(r28)
    nop

;; $400B : durée, période bits 8-10, rechargement linéaire
dsp_w_t_3:
    movei   #dsp_ch_tri,r15
    moveq   #1,r0
    store   r0,(r15+C_LINRELOAD)
    movei   #dsp_w_thi2,r0
    jump    t,(r0)
    nop

;; $400E : L--- PPPP (mode, période)
dsp_w_n_2:
    movei   #dsp_ch_noise,r15
    move    r3,r0
    shrq    #7,r0
    store   r0,(r15+C_MODE)
    moveq   #15,r0
    and     r3,r0
    store   r0,(r15+C_PERIOD)
    jump    t,(r28)
    nop

;; $400F : durée + redémarrage enveloppe
dsp_w_n_3:
    movei   #dsp_ch_noise,r15
    moveq   #1,r0
    store   r0,(r15+C_ESTART)
    movei   #dsp_w_len,r0
    jump    t,(r0)
    nop

;; $4010 : IL-- RRRR (boucle, débit)
dsp_w_d_0:
    move    r3,r0
    shrq    #6,r0
    moveq   #1,r1
    and     r1,r0
    store   r0,(r14+P_DMCLOOP)
    moveq   #15,r0
    and     r3,r0
    shlq    #2,r0
    movei   #dsp_dmc_rate,r1
    add     r1,r0
    load    (r0),r0
    or      r0,r0                     ; résultat du load lu (bogue du scoreboard)
    store   r0,(r14+P_DMCINC)
    jump    t,(r28)
    nop

;; $4011 : niveau direct
dsp_w_d_1:
    movei   #$7F,r0
    and     r3,r0
    store   r0,(r14+P_DMCLEVEL)
    load    (r14+P_DMCLVTRIG),r0
    addq    #1,r0
    store   r0,(r14+P_DMCLVTRIG)
    jump    t,(r28)
    nop

;; $4012 : adresse = $C000 + A*64 (banques fixes 14/15 de la PRG-ROM)
dsp_w_d_2:
    move    r3,r0
    shlq    #6,r0
    movei   #prg_rom+(14*8192),r1
    add     r1,r0
    movei   #dsp_dmc_start,r1
    store   r0,(r1)
    jump    t,(r28)
    nop

;; $4013 : longueur = L*16 + 1
dsp_w_d_3:
    move    r3,r0
    shlq    #4,r0
    addq    #1,r0
    movei   #dsp_dmc_length,r1
    store   r0,(r1)
    jump    t,(r28)
    nop

;; $4015 : ---D NT21 (activation des voies ; DMC : lancement / arrêt)
dsp_w_status:
    movei   #dsp_w_enable,r4
    movei   #dsp_ch_p1,r15
    moveq   #1,r2
    move    pc,r29
    jump    t,(r4)
    addqt   #6,r29
    movei   #dsp_ch_p2,r15
    moveq   #2,r2
    move    pc,r29
    jump    t,(r4)
    addqt   #6,r29
    movei   #dsp_ch_tri,r15
    moveq   #4,r2
    move    pc,r29
    jump    t,(r4)
    addqt   #6,r29
    movei   #dsp_ch_noise,r15
    moveq   #8,r2
    move    pc,r29
    jump    t,(r4)
    addqt   #6,r29
    ;; DMC
    btst    #4,r3
    movei   #dsp_w_dmcstop,r1
    jump    eq,(r1)
    nop
    movei   #dsp_dmc_start,r1
    load    (r1),r0
    or      r0,r0                     ; résultat du load lu (bogue du scoreboard)
    store   r0,(r14+P_DMCADDR)
    movei   #dsp_dmc_length,r1
    load    (r1),r0
    or      r0,r0                     ; résultat du load lu (bogue du scoreboard)
    store   r0,(r14+P_DMCLEN)
    load    (r14+P_DMCTRIG),r0
    addq    #1,r0
    store   r0,(r14+P_DMCTRIG)
    jump    t,(r28)
    nop
dsp_w_dmcstop:
    load    (r14+P_DMCSTOP),r0
    addq    #1,r0
    store   r0,(r14+P_DMCSTOP)
    jump    t,(r28)
    nop
;; r15 = voie, r2 = bit ; retour par (r29)
dsp_w_enable:
    moveq   #0,r0
    and     r3,r2
    jr      eq,dsp_w_dis
    nop
    moveq   #1,r0
    jump    t,(r29)
    store   r0,(r15+C_ENABLED)
dsp_w_dis:
    store   r0,(r15+C_ENABLED)
    jump    t,(r29)
    store   r0,(r15+C_LENGTH)

;; $4017 : mode du séquenceur (bit 7 : 5 pas -> un quart + une demi tout de suite)
dsp_w_frame:
    btst    #7,r3
    jr      eq,dsp_w_none
    nop
    movei   #dsp_quarter,r1
    move    pc,r29
    jump    t,(r1)
    addqt   #6,r29
    movei   #dsp_half,r1
    move    pc,r29
    jump    t,(r1)
    addqt   #6,r29
dsp_w_none:
    jump    t,(r28)
    nop

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Séquenceur de trame ; retour par (r29)
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

;; Quart de trame : enveloppes (carrés, bruit) et compteur linéaire
dsp_quarter:
    move    r29,r27                    ; (r27 du banc 1 : libre)
    movei   #dsp_ch_p1,r15
    movei   #dsp_env_clock,r6
    move    pc,r26
    jump    t,(r6)
    addqt   #6,r26
    movei   #dsp_ch_p2,r15
    move    pc,r26
    jump    t,(r6)
    addqt   #6,r26
    movei   #dsp_ch_noise,r15
    move    pc,r26
    jump    t,(r6)
    addqt   #6,r26
    ;; triangle : compteur linéaire
    movei   #dsp_ch_tri,r15
    load    (r15+C_LINRELOAD),r0
    cmpq    #0,r0
    jr      eq,dsp_q_lindec
    nop
    load    (r15+C_LINVAL),r0
    jr      t,dsp_q_linset
    or      r0,r0                      ; (délai) lu avant le store indexé (scoreboard)
dsp_q_lindec:
    load    (r15+C_LINEAR),r0
    cmpq    #0,r0
    jr      eq,dsp_q_linset
    nop
    subq    #1,r0
dsp_q_linset:
    store   r0,(r15+C_LINEAR)
    load    (r15+C_HALT),r0            ; contrôle à 0 : fin du rechargement
    cmpq    #0,r0
    jr      ne,dsp_q_end
    nop
    store   r0,(r15+C_LINRELOAD)
dsp_q_end:
    jump    t,(r27)
    nop

;; Enveloppe de la voie r15 ; retour par (r26)
dsp_env_clock:
    load    (r15+C_ESTART),r0
    cmpq    #0,r0
    jr      eq,dsp_env_div
    nop
    moveq   #0,r0
    store   r0,(r15+C_ESTART)
    moveq   #15,r0
    store   r0,(r15+C_EDECAY)
    load    (r15+C_VOL),r0
    or      r0,r0                     ; résultat du load lu (bogue du scoreboard)
    jump    t,(r26)
    store   r0,(r15+C_EDIV)
dsp_env_div:
    load    (r15+C_EDIV),r0
    cmpq    #0,r0
    jr      eq,dsp_env_tick
    nop
    subq    #1,r0
    jump    t,(r26)
    store   r0,(r15+C_EDIV)
dsp_env_tick:
    load    (r15+C_VOL),r0
    or      r0,r0                     ; résultat du load lu (bogue du scoreboard)
    store   r0,(r15+C_EDIV)
    load    (r15+C_EDECAY),r0
    cmpq    #0,r0
    jr      eq,dsp_env_loop
    nop
    subq    #1,r0
    jump    t,(r26)
    store   r0,(r15+C_EDECAY)
dsp_env_loop:
    load    (r15+C_HALT),r1            ; boucle d'enveloppe
    cmpq    #0,r1
    jr      eq,dsp_env_end
    nop
    moveq   #15,r0
    store   r0,(r15+C_EDECAY)
dsp_env_end:
    jump    t,(r26)
    nop

;; Demi-trame : compteurs de durée et sweep
dsp_half:
    move    r29,r27
    movei   #dsp_len_clock,r6
    movei   #dsp_ch_p1,r15
    move    pc,r26
    jump    t,(r6)
    addqt   #6,r26
    movei   #dsp_ch_p2,r15
    move    pc,r26
    jump    t,(r6)
    addqt   #6,r26
    movei   #dsp_ch_tri,r15
    move    pc,r26
    jump    t,(r6)
    addqt   #6,r26
    movei   #dsp_ch_noise,r15
    move    pc,r26
    jump    t,(r6)
    addqt   #6,r26
    movei   #dsp_sweep_clock,r6
    movei   #dsp_ch_p1,r15
    move    pc,r26
    jump    t,(r6)
    addqt   #6,r26
    movei   #dsp_ch_p2,r15
    move    pc,r26
    jump    t,(r6)
    addqt   #6,r26
    jump    t,(r27)
    nop

;; Compteur de durée de la voie r15 (sauf arrêt) ; retour par (r26)
dsp_len_clock:
    load    (r15+C_HALT),r0
    cmpq    #0,r0
    jr      ne,dsp_len_end
    nop
    load    (r15+C_LENGTH),r0
    cmpq    #0,r0
    jr      eq,dsp_len_end
    nop
    subq    #1,r0
    store   r0,(r15+C_LENGTH)
dsp_len_end:
    jump    t,(r26)
    nop

;; Sweep de la voie carrée r15 ; retour par (r26)
dsp_sweep_clock:
    movei   #dsp_sw_reload,r5
    load    (r15+C_SWDIV),r0
    cmpq    #0,r0
    movei   #dsp_sw_div,r1
    jump    ne,(r1)
    nop
    ;; diviseur à 0 : ajuster la période si actif et sans débordement
    load    (r15+C_SWEN),r0
    cmpq    #0,r0
    jump    eq,(r5)
    nop
    load    (r15+C_SWSHIFT),r0
    cmpq    #0,r0
    jump    eq,(r5)
    nop
    load    (r15+C_TIMER),r2
    moveq   #8,r1
    cmp     r1,r2
    jump    mi,(r5)                    ; période < 8
    nop
    movei   #dsp_sweep_target,r1
    move    pc,r19
    jump    t,(r1)
    addqt   #6,r19
    movei   #$7FF,r1
    cmp     r1,r0                      ; cible > $7FF : pas d'ajustement
    jump    hi,(r5)
    nop
    cmpq    #0,r0
    jr      pl,dsp_sw_set
    nop
    moveq   #0,r0
dsp_sw_set:
    store   r0,(r15+C_TIMER)
dsp_sw_reload:
    load    (r15+C_SWPER),r0
    or      r0,r0                     ; résultat du load lu (bogue du scoreboard)
    store   r0,(r15+C_SWDIV)
    moveq   #0,r0
    jump    t,(r26)
    store   r0,(r15+C_SWRELOAD)
dsp_sw_div:
    load    (r15+C_SWRELOAD),r1
    cmpq    #0,r1
    jr      ne,dsp_sw_reload
    nop
    subq    #1,r0
    jump    t,(r26)
    store   r0,(r15+C_SWDIV)

;; r0 = période cible du sweep de la voie r15 ; retour par (r19). Écrase r1, r2.
dsp_sweep_target:
    load    (r15+C_TIMER),r0
    move    r0,r2
    load    (r15+C_SWSHIFT),r1
    sh      r1,r2                      ; changement = période >> décalage
    load    (r15+C_SWNEG),r1
    cmpq    #0,r1
    jr      eq,dsp_st_add
    nop
    sub     r2,r0
    load    (r15+C_ONES),r1
    jump    t,(r19)
    sub     r1,r0                      ; carré 1 : complément à un
dsp_st_add:
    jump    t,(r19)
    add     r2,r0

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Paramètres de synthèse depuis l'état des voies ; retour par (r29)
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

dsp_update:
    move    r29,r27
    ;; Carrés
    movei   #dsp_ch_p1,r15
    moveq   #P_P1INC,r16
    movei   #dsp_upd_pulse,r6
    move    pc,r26
    jump    t,(r6)
    addqt   #6,r26
    movei   #dsp_ch_p2,r15
    moveq   #P_P2INC,r16
    move    pc,r26
    jump    t,(r6)
    addqt   #6,r26
    ;; Triangle : actif si durée et compteur linéaire, période >= 2
    movei   #dsp_ch_tri,r15
    movei   #dsp_u_tri,r5
    moveq   #0,r2
    load    (r15+C_ENABLED),r0
    cmpq    #0,r0
    jump    eq,(r5)
    nop
    load    (r15+C_LENGTH),r0
    cmpq    #0,r0
    jump    eq,(r5)
    nop
    load    (r15+C_LINEAR),r0
    cmpq    #0,r0
    jump    eq,(r5)
    nop
    load    (r15+C_TIMER),r1
    moveq   #2,r0
    cmp     r0,r1
    jump    mi,(r5)
    nop
    addq    #1,r1
    movei   #dsp_k_pulse,r0
    load    (r0),r2
    div     r1,r2
    shlq    #3,r2                      ; (K / (t+1)) * 16 / 2
dsp_u_tri:
    store   r2,(r14+P_TRIINC)
    ;; Bruit
    movei   #dsp_ch_noise,r15
    moveq   #0,r2
    load    (r15+C_ENABLED),r0
    cmpq    #0,r0
    jr      eq,dsp_u_nvol
    nop
    load    (r15+C_LENGTH),r0
    cmpq    #0,r0
    jr      eq,dsp_u_nvol
    nop
    ;; volume : constant ou enveloppe (un seul load dans r2, lu avant le
    ;; store indexé : bogues du scoreboard et des écritures seules)
    load    (r15+C_CONST),r0
    cmpq    #0,r0
    jr      eq,dsp_u_ndec
    nop
    jr      t,dsp_u_nsel
    load    (r15+C_VOL),r2             ; (délai) volume constant
dsp_u_ndec:
    load    (r15+C_EDECAY),r2
dsp_u_nsel:
    or      r2,r2
dsp_u_nvol:
    store   r2,(r14+P_NOISEVOL)
    load    (r15+C_PERIOD),r0
    shlq    #2,r0
    movei   #dsp_noise_rate,r1
    add     r1,r0
    load    (r0),r0
    or      r0,r0                     ; résultat du load lu (bogue du scoreboard)
    store   r0,(r14+P_NOISEINC)
    load    (r15+C_MODE),r0
    moveq   #1,r1
    cmpq    #0,r0
    jr      eq,dsp_u_tap
    nop
    moveq   #6,r1
dsp_u_tap:
    store   r1,(r14+P_NOISETAP)
    jump    t,(r27)
    nop

;; Voie carrée r15 -> dsp_params[r16..r16+2] (inc, rapport, volume) ; retour par (r26)
dsp_upd_pulse:
    moveq   #0,r2                      ; volume
    load    (r15+C_ENABLED),r0
    cmpq    #0,r0
    movei   #dsp_up_store,r1
    jump    eq,(r1)
    nop
    load    (r15+C_LENGTH),r0
    cmpq    #0,r0
    jump    eq,(r1)
    nop
    load    (r15+C_TIMER),r3
    moveq   #8,r0
    cmp     r0,r3
    jump    mi,(r1)                    ; période < 8 : muet
    nop
    ;; sweep montant qui déborde : muet
    load    (r15+C_SWNEG),r0
    cmpq    #0,r0
    movei   #dsp_up_ok,r5
    jump    ne,(r5)
    nop
    movei   #dsp_sweep_target,r0
    move    pc,r19
    jump    t,(r0)
    addqt   #6,r19
    movei   #$7FF,r1
    cmp     r1,r0
    movei   #dsp_up_store,r1
    jump    hi,(r1)
    moveq   #0,r2                      ; (délai) muet : dsp_sweep_target a utilisé r2
dsp_up_ok:
    ;; volume : constant ou enveloppe (un seul load dans r2)
    load    (r15+C_CONST),r0
    cmpq    #0,r0
    jr      eq,dsp_up_dec
    nop
    jr      t,dsp_up_store
    load    (r15+C_VOL),r2             ; (délai) volume constant
dsp_up_dec:
    load    (r15+C_EDECAY),r2
dsp_up_store:
    ;; incrément de phase = (K / (t+1)) * 16
    load    (r15+C_TIMER),r3
    addq    #1,r3
    movei   #dsp_k_pulse,r0
    load    (r0),r0
    div     r3,r0
    shlq    #4,r0
    move    r16,r1
    shlq    #2,r1
    add     r14,r1
    store   r0,(r1)                    ; INC
    load    (r15+C_DUTY),r0
    shlq    #2,r0
    movei   #dsp_duty_table,r3
    add     r3,r0
    load    (r0),r0
    addq    #4,r1
    store   r0,(r1)                    ; DUTY
    addq    #4,r1
    jump    t,(r26)
    store   r2,(r1)                    ; VOL

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Interruption I2S (banc 0) : un échantillon
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

dsp_i2s_isr:
    ;; FLAGS lu avant toute instruction qui modifie les drapeaux : le retour
    ;; rend ainsi au code interrompu ses Z/N/C (r29/r30 réservés à l'ISR)
    movei   #D_FLAGS,r30
    load    (r30),r29
    ;; Carré 1
    load    (r14+P_P1INC),r15
    add     r15,r1
    load    (r14+P_P1DUTY),r15
    moveq   #0,r16
    cmp     r15,r1
    jr      cc,dsp_p1_off
    nop
    load    (r14+P_P1VOL),r16
dsp_p1_off:
    ;; Carré 2
    load    (r14+P_P2INC),r15
    add     r15,r2
    load    (r14+P_P2DUTY),r15
    moveq   #0,r17
    cmp     r15,r2
    jr      cc,dsp_p2_off
    nop
    load    (r14+P_P2VOL),r17
dsp_p2_off:
    add     r17,r16
    ;; Triangle : 32 pas, 15 -> 0 -> 15
    load    (r14+P_TRIINC),r15
    add     r15,r3
    move    r3,r18
    shrq    #27,r18
    move    r18,r19
    subq    #16,r19
    jr      pl,dsp_tri_ok
    nop
    moveq   #15,r19
    sub     r18,r19
dsp_tri_ok:
    ;; Bruit : LFSR 15 bits, 4 horloges max par échantillon
    load    (r14+P_NOISEINC),r15
    add     r15,r4
    load    (r14+P_NOISETAP),r21
    moveq   #4,r22
    movei   #$10000,r24
    movei   #dsp_noise_done,r25
dsp_noise_loop:
    move    r4,r20
    shrq    #16,r20
    jump    eq,(r25)
    nop
    sub     r24,r4
    move    r5,r23
    sh      r21,r23
    xor     r5,r23
    moveq   #1,r20
    and     r20,r23
    shlq    #14,r23
    shrq    #1,r5
    or      r23,r5
    subq    #1,r22
    jr      ne,dsp_noise_loop
    nop
    shlq    #16,r4
    shrq    #16,r4
dsp_noise_done:
    moveq   #0,r23                     ; (r20/r21 sont l'état DMC : r23 = sortie bruit)
    btst    #0,r5
    jr      ne,dsp_noise_off
    nop
    load    (r14+P_NOISEVOL),r23
dsp_noise_off:
    ;; DMC : niveau direct ($4011) et arrêt ($4015 bit 4 à 0)
    movei   #dsp_dmc_seen,r24
    load    (r14+P_DMCLVTRIG),r15
    load    (r24),r22
    cmp     r15,r22
    jr      eq,dsp_dmc_nolv
    nop
    store   r15,(r24)
    load    (r14+P_DMCLEVEL),r8
dsp_dmc_nolv:
    addq    #4,r24
    load    (r14+P_DMCSTOP),r15
    load    (r24),r22
    cmp     r15,r22
    jr      eq,dsp_dmc_nostop
    nop
    store   r15,(r24)
    moveq   #0,r9
dsp_dmc_nostop:
    ;; (re)lancement
    load    (r14+P_DMCTRIG),r15
    cmp     r15,r10
    jr      eq,dsp_dmc_play
    nop
    move    r15,r10
    cmpq    #0,r9                      ; déjà en cours : on continue (comme l'APU)
    jr      ne,dsp_dmc_play
    nop
    load    (r14+P_DMCADDR),r6
    load    (r14+P_DMCLEN),r9
dsp_dmc_play:
    ;; bits à traiter pendant cet échantillon
    load    (r14+P_DMCINC),r15
    add     r15,r7
    movei   #dsp_dmc_done,r25
    movei   #dsp_dmc_shift,r24
dsp_dmc_bit:
    move    r7,r15
    shrq    #16,r15
    jump    eq,(r25)
    nop
    movei   #$10000,r15
    sub     r15,r7
    ;; octet suivant si le registre est vide
    cmpq    #0,r27
    jump    ne,(r24)
    nop
    cmpq    #0,r9
    jr      eq,dsp_dmc_bit             ; plus d'octets : silence (niveau figé)
    nop
    loadb   (r6),r26
    addq    #1,r6
    subq    #1,r9
    moveq   #8,r27
    cmpq    #0,r9
    jump    ne,(r24)
    nop
    load    (r14+P_DMCLOOP),r15        ; fin : boucle éventuelle
    cmpq    #0,r15
    jump    eq,(r24)
    nop
    load    (r14+P_DMCADDR),r6
    load    (r14+P_DMCLEN),r9
dsp_dmc_shift:
    btst    #0,r26
    jr      eq,dsp_dmc_down
    shrq    #1,r26                     ; (délai)
    movei   #125,r15
    cmp     r15,r8
    jr      hi,dsp_dmc_next
    nop
    addq    #2,r8
    jr      t,dsp_dmc_next
    nop
dsp_dmc_down:
    cmpq    #2,r8
    jr      mi,dsp_dmc_next
    nop
    subq    #2,r8
dsp_dmc_next:
    movei   #dsp_dmc_bit,r15
    jump    t,(r15)
    subq    #1,r27                     ; (délai)
dsp_dmc_done:
    ;; Mixage
    movei   #MIX_PULSE,r15
    mult    r15,r16
    movei   #MIX_TRI,r15
    mult    r15,r19
    add     r19,r16
    movei   #MIX_NOISE,r15
    mult    r15,r23
    add     r23,r16
    movei   #MIX_DMC,r15
    move    r8,r17
    mult    r15,r17
    add     r17,r16
    movei   #MIX_OFFSET,r15
    sub     r15,r16
    ;; Filtre anti-continu : y = x - x(n-1) + y(n-1) - y(n-1)/256
    move    r16,r15
    sub     r12,r15
    move    r16,r12
    move    r13,r16
    sharq   #8,r16
    sub     r16,r13
    add     r15,r13
    move    r13,r16
    ;; Écrêtage 16 bits (un saut brusque du DMC peut faire dépasser le
    ;; filtre ; sans écrêtage, la valeur s'enroule et claque)
    movei   #32767,r24
    cmp     r24,r16
    jr      mi,dsp_clip_nothi
    nop
    move    r24,r16
dsp_clip_nothi:
    movei   #-32768,r24
    cmp     r24,r16
    jr      pl,dsp_clip_notlo
    nop
    move    r24,r16
dsp_clip_notlo:
    movei   #L_I2S,r15
    store   r16,(r15)
    addq    #4,r15
    store   r16,(r15)
    ;; Compteur d'échantillons (séquenceur de trame de la boucle principale)
    addq    #1,r11
    movei   #dsp_sample_count,r15
    store   r11,(r15)
    ;; Retour d'interruption (r29 = FLAGS lu à l'entrée)
    bclr    #3,r29
    bset    #10,r29
    load    (r31),r28
    addq    #2,r28
    addq    #4,r31
    jump    t,(r28)
    store   r29,(r30)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Tables et variables (RAM DSP)
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

    .long
;; Registres $4000-$4017 -> routine d'écriture
dsp_reg_table:
    dc.l    dsp_w_p1_0,dsp_w_p1_1,dsp_w_p1_2,dsp_w_p1_3
    dc.l    dsp_w_p2_0,dsp_w_p2_1,dsp_w_p2_2,dsp_w_p2_3
    dc.l    dsp_w_t_0,dsp_w_none,dsp_w_t_2,dsp_w_t_3
    dc.l    dsp_w_n_0,dsp_w_none,dsp_w_n_2,dsp_w_n_3
    dc.l    dsp_w_d_0,dsp_w_d_1,dsp_w_d_2,dsp_w_d_3
    dc.l    dsp_w_none,dsp_w_status,dsp_w_none,dsp_w_frame
    dc.l    dsp_w_none,dsp_w_none,dsp_w_none,dsp_w_none
    dc.l    dsp_w_none,dsp_w_none,dsp_w_none,dsp_w_none

;; Durées (index = valeur >> 3)
dsp_length_table:
    dc.l    10,254,20,2,40,4,80,6,160,8,60,10,14,12,26,14
    dc.l    12,16,24,18,48,20,96,22,192,24,72,26,16,28,32,30
;; Seuils de rapport cyclique (phase 32 bits) : 12,5 %, 25 %, 50 %, 75 %
dsp_duty_table:
    dc.l    $20000000,$40000000,$80000000,$C0000000
;; K = 2^28 * 1789773 / (16 * 25971) ; incrément d'un carré = K / (t+1) * 16
dsp_k_pulse:
    dc.l    1156188524
;; Horloges LFSR par échantillon (16.16) : 1789773 / (période * 25971) * 65536
dsp_noise_rate:
    dc.l    1129106,564553,282276,141138,70569,47046,35284,28228
    dc.l    22357,17782,11885,8891,5927,4446,2220,1110
;; Bits DMC par échantillon (16.16) : 1789773 / (débit * 25971) * 65536
dsp_dmc_rate:
    dc.l    10553,11886,13284,14114,15792,17782,19985,21106
    dc.l    23772,28228,31805,35284,42608,53768,62727,83636

;; État des voies
dsp_ch_p1:      dcb.l   CH_SIZE,0
dsp_ch_p2:      dcb.l   CH_SIZE,0
dsp_ch_tri:     dcb.l   CH_SIZE,0
dsp_ch_noise:   dcb.l   CH_SIZE,0
dsp_dmc_seen:   dc.l    0,0            ; derniers niveau direct / arrêt vus par l'ISR
dsp_dmc_start:  dc.l    0
dsp_dmc_length: dc.l    1
dsp_sample_count: dc.l  0
;; Paramètres de synthèse (index 0 inutilisé)
dsp_params:     dcb.l   20,0
;; Anneau des écritures APU (68000 -> DSP)
dsp_ring_wr:    dc.l    0
dsp_ring:       dcb.l   64,0
dsp_end:
