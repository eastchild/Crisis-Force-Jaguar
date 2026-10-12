# Crisis Force - Communication Inter-Processeurs

**Phase 2: Conception**  
**Date**: 2026-09-30  
**Version**: 1.0

---

## 1. Introduction

L'Atari Jaguar possède une architecture unique avec **5 processeurs indépendants** sans mémoire partagée. Cette conception nécessite un mécanisme de communication efficace entre les processeurs pour synchroniser les opérations et partager les données.

Ce document décrit le système de communication entre le **M68000** (logique principale), le **GPU (Tom)** (graphismes), et le **DSP (Jerry)** (audio) pour le portage de Crisis Force.

---

## 2. Architecture de Communication

### 2.1. Principe de Base

Les processeurs communiquent via:
1. **Mémoire partagée** (Main RAM) pour les données
2. **Registres hardware** pour la synchronisation
3. **Signaux d'interruption** pour la notification

### 2.2. Modèle de Communication

```
┌─────────────────────────────────────────────────────────────┐
│                         M68000 (Main)                           │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────────────┐ │
│  │  Logique     │  │ Commandes   │  │   Données Partagées  │ │
│  │  du Jeu     │  │  GPU/DSP     │  │   (Variables Globales) │ │
│  └──────┬──────┘  └──────┬──────┘  └──────────┬───────────┘ │
└─────────┼─────────────────┼──────────────────────┼────────────┘
          │                 │                      │
          ▼                 ▼                      ▼
┌─────────────────────┐ ┌─────────────┐ ┌─────────────────┐
│      Main RAM        │ │   GPU (Tom)  │ │     DSP (Jerry)   │
│  (8 MB adressable)   │ │  (64 KB RAM) │ │   (8 KB RAM)     │
│                     │ │              │ │                 │
│  - Buffers Commandes │ │  - Code      │ │  - Code          │
│  - Variables Globales │ │  - Données   │ │  - Données Audio │
│  - Données Partagées │ │  - Framebuffer│ │  - Buffers Audio │
└─────────┬───────────┘ └─────────────┘ └─────────────────┘
          │
          ▼
┌─────────────────────┐
│    Hardware Bus      │
│  (Arbitration)       │
└─────────────────────┘
```

### 2.3. Hiérarchie de Priorité du Bus

L'arbitration du bus Jaguar suit cette priorité:

```
Priority 1: GPU / OP / Blitter
Priority 2: 68000 (M68000)
Priority 3: DSP (Jerry)
```

**Impact**: Quand le GPU accède à la Main RAM, le 68000 est ralenti (~30% de perte).

**Solution**:
- Minimiser les accès du GPU à la Main RAM
- Cacher les données fréquemment utilisées dans la RAM locale du GPU
- Utiliser des mécanismes de synchronisation efficaces

---

## 3. Communication M68000 → GPU

### 3.1. Buffers de Communication

```
$800000-$800FFF : Buffer de commandes GPU (4 KB)
$801000-$801FFF : Buffer de retour GPU (4 KB)
```

### 3.2. Structure des Commandes GPU

```assembly
; Type de commandes GPU
GPU_CMD_NOOP          equ 0   ; Aucune opération
GPU_CMD_CLEAR         equ 1   ; Effacer l'écran
GPU_CMD_DRAW_SPRITE   equ 2   ; Dessiner un sprite
GPU_CMD_DRAW_BG       equ 3   ; Dessiner le background
GPU_CMD_DRAW_HUD      equ 4   ; Dessiner le HUD
GPU_CMD_SET_SCROLL    equ 5   ; Définir le scrolling
GPU_CMD_SET_PALETTE   equ 6   ; Définir la palette
GPU_CMD_SWAP_BUFFERS  equ 7   ; Basculer les framebuffers

; Structure d'une commande GPU (16 octets)
    rsreset
GPU_CMD_TYPE         rs.w 1       ; Type de commande
GPU_CMD_PARAM1       rs.l 1       ; Paramètre 1
GPU_CMD_PARAM2       rs.l 1       ; Paramètre 2
GPU_CMD_PARAM3       rs.l 1       ; Paramètre 3
GPU_CMD_SIZE          rs.b 0
```

### 3.3. Protocole de Communication

#### Écriture par M68000

```assembly
SendGPUCommand:
    ; Entrée: d0 = type, d1 = param1, d2 = param2, d3 = param3
    
    ; Attendre qu'il y ait de la place dans le buffer
WaitGPUSlot:
    move.l  GPUCommandCount,d4
    cmp.l   #MAX_GPU_COMMANDS,d4
    bge     WaitGPUSlot
    
    ; Calculer l'adresse
    move.l  #GPUCommandBuffer,a0
    move.l  d4,d5
    lsl.l   #4,d5               ; ×16 (taille d'une commande)
    add.l   d5,a0
    
    ; Écrire la commande
    move.w  d0,(a0)+            ; Type
    move.l  d1,(a0)+            ; Param1
    move.l  d2,(a0)+            ; Param2
    move.l  d3,(a0)+            ; Param3
    
    ; Incrémenter le compteur (de manière atomique)
    move.w  #$2700,SR           ; Désactiver les interruptions
    addq.l  #1,GPUCommandCount
    move.w  #$2000,SR           ; Réactiver les interruptions
    
    rts
```

#### Lecture par GPU

```assembly
; Dans gpu.s
ProcessGPUCommands:
    ; Lire le compteur
    movei   #GPUCommandCount,r1
    loadw   (r1),r2
    cmp     #0,r2
    beq     NoGPUCommands
    
ProcessCommandLoop:
    ; Décrémenter le compteur
    sub     #1,r2
    
    ; Calculer l'adresse
    movei   #GPUCommandBuffer,r3
    move    r2,r4
    shl     #4,r4               ; ×16
    add     r4,r3
    
    ; Lire la commande
    loadw   (r3),r5             ; Type
    load    2(r3),r6             ; Param1
    load    6(r3),r7             ; Param2
    load    10(r3),r8            ; Param3
    
    ; Traiter selon le type
    cmp     #GPU_CMD_CLEAR,r5
    beq     GPUCommandClear
    cmp     #GPU_CMD_DRAW_SPRITE,r5
    beq     GPUCommandDrawSprite
    cmp     #GPU_CMD_DRAW_BG,r5
    beq     GPUCommandDrawBG
    cmp     #GPU_CMD_DRAW_HUD,r5
    beq     GPUCommandDrawHUD
    cmp     #GPU_CMD_SET_SCROLL,r5
    beq     GPUCommandSetScroll
    cmp     #GPU_CMD_SWAP_BUFFERS,r5
    beq     GPUCommandSwapBuffers
    
    ; Commande inconnue
    bra     NextGPUCommand
    
GPUCommandClear:
    ; Effacer l'écran avec la couleur param1
    bsr     GPUClearScreen
    bra     NextGPUCommand
    
GPUCommandDrawSprite:
    ; r6 = pointeur vers le sprite
    bsr     GPUDrawSprite
    bra     NextGPUCommand
    
GPUCommandDrawBG:
    ; r6 = offset de scrolling Y
    bsr     GPURenderBackground
    bra     NextGPUCommand
    
GPUCommandDrawHUD:
    bsr     GPURenderHUD
    bra     NextGPUCommand
    
GPUCommandSetScroll:
    ; r6 = ScrollY
    move    r6,ScrollY
    bra     NextGPUCommand
    
GPUCommandSwapBuffers:
    bsr     SwapFrameBuffers
    
NextGPUCommand:
    ; Passer à la commande suivante
    sub     #1,r2
    bne     ProcessCommandLoop
    
    ; Sauvegarder le compteur mis à jour
    movei   #GPUCommandCount,r1
    storew  r2,(r1)
    
NoGPUCommands:
    rts
```

### 3.4. Variables Partagées M68000 → GPU

Les variables suivantes sont lues par le GPU depuis la Main RAM:

```
$800000 : GPUCommandCount      ; Compteur de commandes (32-bit)
$800400 : GPUCommandBuffer     ; Buffer des commandes (4 KB)
$801000 : ScrollY             ; Position de scrolling Y (32-bit)
$801004 : ScrollX             ; Position de scrolling X (32-bit)
$801008 : PlayerX             ; Position X du joueur (16-bit)
$80100A : PlayerY             ; Position Y du joueur (16-bit)
$80100C : CurrentLevel         ; Niveau actuel (16-bit)
$80100E : GameState            ; État du jeu (16-bit)
$801010 : FrameCounter         ; Compteur de frames (32-bit)
$801014 : Score               ; Score (32-bit)
$801018 : Lives               ; Vies restantes (16-bit)
```

### 3.5. Mécanisme de Synchronisation

Pour éviter les problèmes de "torn reads" (le 68000 écrit un long en 2 writes word) :

```assembly
; Écriture par M68000 (16-bit est atomique)
move.w  d0,ScrollY

; Lecture par GPU (attendre la stabilité)
WaitStableScrollY:
    loadw   (ScrollY),r1
    loadw   (ScrollY),r2
    cmp     r1,r2
    bne     WaitStableScrollY
    ; r1 contient la valeur stable
```

**Alternative**: Utiliser un flag de validation

```assembly
; Variables
ScrollY:         ds.w 1
ScrollYValid:    ds.w 1       ; 1 = valeur valide

; Écriture par M68000
move.w  d0,ScrollY
move.w  #0,ScrollYValid       ; Invalider
move.w  #1,ScrollYValid       ; Valider

; Lecture par GPU
WaitScrollYValid:
    loadw   (ScrollYValid),r1
    cmp     #1,r1
    bne     WaitScrollYValid
    loadw   (ScrollY),r2
    ; Utiliser r2
```

---

## 4. Communication M68000 → DSP

### 4.1. Buffers de Communication

```
$802000-$802FFF : Buffer de commandes DSP (4 KB)
$803000-$803FFF : Buffer de retour DSP (4 KB)
```

### 4.2. Structure des Commandes DSP

```assembly
; Type de commandes DSP
DSP_CMD_NOOP          equ 0   ; Aucune opération
DSP_CMD_PLAY_SFX      equ 1   ; Jouer un effet sonore
DSP_CMD_PLAY_MUSIC    equ 2   ; Jouer de la musique
DSP_CMD_STOP_SFX      equ 3   ; Arrêter un SFX
DSP_CMD_STOP_MUSIC    equ 4   ; Arrêter la musique
DSP_CMD_SET_VOLUME    equ 5   ; Régler le volume
DSP_CMD_SET_PAN       equ 6   ; Régler le pan
DSP_CMD_PAUSE         equ 7   ; Mettre en pause
DSP_CMD_RESUME        equ 8   ; Reprendre

; Structure d'une commande DSP (16 octets)
    rsreset
DSP_CMD_TYPE         rs.w 1       ; Type de commande
DSP_CMD_ID           rs.w 1       ; ID du SFX ou musique
DSP_CMD_VOLUME       rs.w 1       ; Volume (0-127)
DSP_CMD_PAN          rs.w 1       ; Pan (0-127, 64=centre)
DSP_CMD_SIZE          rs.b 0
```

### 4.3. Protocole de Communication

#### Écriture par M68000

```assembly
SendDSPCommand:
    ; Entrée: d0 = type, d1 = ID, d2 = volume, d3 = pan
    
    ; Attendre qu'il y ait de la place
WaitDSPSlot:
    move.l  DSPCommandCount,d4
    cmp.l   #MAX_DSP_COMMANDS,d4
    bge     WaitDSPSlot
    
    ; Calculer l'adresse
    move.l  #DSPCommandBuffer,a0
    move.l  d4,d5
    lsl.l   #4,d5               ; ×16
    add.l   d5,a0
    
    ; Écrire la commande
    move.w  d0,(a0)+            ; Type
    move.w  d1,(a0)+            ; ID
    move.w  d2,(a0)+            ; Volume
    move.w  d3,(a0)+            ; Pan
    
    ; Incrémenter le compteur
    move.w  #$2700,SR
    addq.l  #1,DSPCommandCount
    move.w  #$2000,SR
    
    ; Déclencher l'interruption DSP
    move.w  #1,DSPCTRL
    
    rts
```

#### Traitement par DSP

```assembly
; Dans dsp.s
DSPInterruptHandler:
    ; Sauvegarder l'état
    movem   r0-r7,(r15)
    
    ; Lire et traiter les commandes
    bsr     ProcessDSPCommands
    
    ; Restaurer l'état
    movem   (r15),r0-r7
    
    rti

ProcessDSPCommands:
    movei   #DSPCommandCount,r1
    loadw   (r1),r2
    cmp     #0,r2
    beq     NoDSPCommands
    
ProcessDSPLoop:
    ; Décrémenter le compteur
    sub     #1,r2
    
    ; Calculer l'adresse
    movei   #DSPCommandBuffer,r3
    move    r2,r4
    shl     #4,r4
    add     r4,r3
    
    ; Lire la commande
    loadw   (r3),r5             ; Type
    loadw   2(r3),r6             ; ID
    loadw   4(r3),r7             ; Volume
    loadw   6(r3),r8             ; Pan
    
    ; Traiter selon le type
    cmp     #DSP_CMD_PLAY_SFX,r5
    beq     PlaySFXCmd
    cmp     #DSP_CMD_PLAY_MUSIC,r5
    beq     PlayMusicCmd
    cmp     #DSP_CMD_STOP_SFX,r5
    beq     StopSFXCmd
    cmp     #DSP_CMD_STOP_MUSIC,r5
    beq     StopMusicCmd
    cmp     #DSP_CMD_SET_VOLUME,r5
    beq     SetVolumeCmd
    
    bra     NextDSPCommand
    
PlaySFXCmd:
    ; Jouer le SFX r6 avec volume r7 et pan r8
    bsr     PlaySFX
    bra     NextDSPCommand
    
PlayMusicCmd:
    ; Jouer la musique r6
    bsr     PlayMusic
    bra     NextDSPCommand
    
StopSFXCmd:
    ; Arrêter le SFX r6
    bsr     StopSFX
    bra     NextDSPCommand
    
StopMusicCmd:
    ; Arrêter la musique
    bsr     StopMusic
    bra     NextDSPCommand
    
SetVolumeCmd:
    ; Régler le volume r7
    bsr     SetVolume
    
NextDSPCommand:
    sub     #1,r2
    bne     ProcessDSPLoop
    
    ; Sauvegarder le compteur
    movei   #DSPCommandCount,r1
    storew  r2,(r1)
    
NoDSPCommands:
    rts
```

### 4.4. Communication via Interruptions

Le DSP peut utiliser les interruptions pour notifier le M68000:

```assembly
; Dans dsp.s, quand un SFX est terminé
SFXFinished:
    ; Envoyer une notification au M68000
    movei   #$1,r1
    store   r1,DSP_NOTIFY       ; Écrire dans un registre partagé
    
    ; Déclencher une interruption
    movei   #$1,r1
    store   r1,INT1             ; Générer une interruption
    
    rts
```

### 4.5. Variables Partagées M68000 ↔ DSP

```
$802000 : DSPCommandCount      ; Compteur de commandes (32-bit)
$802400 : DSPCommandBuffer     ; Buffer des commandes (4 KB)
$803000 : DSPNotify           ; Notification DSP → M68000 (32-bit)
$803004 : MasterVolume        ; Volume principal (16-bit)
$803006 : MusicPlaying         ; Musique en cours (16-bit: 0=non, 1=oui)
$803008 : CurrentSFX          ; SFX en cours (16-bit)
```

---

## 5. Communication GPU → M68000

### 5.1. Retours du GPU

Le GPU peut signaler des événements au M68000:

```assembly
; Variables de retour
$801000 : GPUReturnCount       ; Compteur de retours (32-bit)
$801400 : GPUReturnBuffer      ; Buffer des retours (4 KB)

; Types de retours
GPU_RETURN_FRAME_DONE    equ 1   ; Frame terminé
GPU_RETURN_OVERFLOW      equ 2   ; Buffer plein
GPU_RETURN_ERROR        equ 3   ; Erreur
```

### 5.2. Protocole de Retour

```assembly
; Dans gpu.s, pour signaler la fin d'un frame
SignalFrameDone:
    movei   #GPUReturnBuffer,r1
    movei   #GPUReturnCount,r2
    
    ; Attendre de la place
WaitReturnSlot:
    loadw   (r2),r3
    cmp     #MAX_GPU_RETURNS,r3
    bge     WaitReturnSlot
    
    ; Écrire le retour
    storew  r3,(r1,r3*8)
    movei   #GPU_RETURN_FRAME_DONE,r4
    storew  r4,2(r1,r3*8)
    
    ; Incrémenter
    add     #1,r3
    storew  r3,(r2)
    
    rts
```

### 5.3. Lecture par M68000

```assembly
CheckGPUReturns:
    move.l  GPUReturnCount,d0
    cmp.l   #0,d0
    beq     NoGPUReturns
    
    ; Lire le retour
    move.l  #GPUReturnBuffer,a0
    move.l  d0,d1
    lsl.l   #3,d1               ; ×8
    add.l   d1,a0
    
    move.w  (a0),d2             ; Type
    move.w  2(a0),d3            ; Donnée
    
    cmp.w   #GPU_RETURN_FRAME_DONE,d2
    beq     FrameDoneReturn
    
    ; Décrémenter le compteur
    subq.l  #1,GPUReturnCount
    
    bra     CheckGPUReturns
    
FrameDoneReturn:
    ; Frame terminé, on peut continuer
    ; Décrémenter le compteur
    subq.l  #1,GPUReturnCount
    
NoGPUReturns:
    rts
```

---

## 6. Synchronisation Globale

### 6.1. Synchronisation par Frame

Chaque frame, les processeurs se synchronisent sur le **VBLANK** (Vertical Blank):

```
┌─────────────────────────────────────────────────────────────┐
│                    Frame n                                    │
├─────────────────────┬─────────────────────┬─────────────────┤
│     M68000          │        GPU           │      DSP         │
├─────────────────────┼─────────────────────┼─────────────────┤
│ 1. Lire entrées     │                     │                 │
│ 2. Mettre à jour    │                     │                 │
│    logique          │                     │                 │
│ 3. Envoyer commandes│                     │                 │
├─────────────────────┼─────────────────────┼─────────────────┤
│ Attendre VBLANK     │ 1. Traiter commandes │ 1. Traiter      │
│                     │ 2. Rendre frame       │    commandes    │
├─────────────────────┼─────────────────────┼─────────────────┤
│ VBLANK →            │                     │                 │
├─────────────────────┼─────────────────────┼─────────────────┤
│ 4. Vérifier retours  │ 3. Signaler fin       │ 2. Générer audio │
└─────────────────────┴─────────────────────┴─────────────────┘
                           │
                           ▼
                    Frame n+1
```

### 6.2. Code de Synchronisation

```assembly
; Dans main.s
MainLoop:
    ; Attendre VBLANK
    bsr     WaitVBL
    
    ; Lire les entrées
    bsr     ReadInput
    
    ; Mettre à jour la logique
    bsr     UpdateGame
    
    ; Envoyer des commandes
    bsr     SendGPUCommands
    bsr     SendDSPCommands
    
    ; Vérifier les retours
    bsr     CheckGPUReturns
    bsr     CheckDSPReturns
    
    ; Incrémenter le frame counter
    addq.l  #1,FrameCounter
    
    bra     MainLoop

WaitVBL:
    move.l  #0,d0
WaitVBLLoop:
    btst    #0,VI               ; Tester si VBLANK est actif
    beq     WaitVBLLoop
    
    ; Attendre la fin du VBLANK
WaitVBLEnd:
    btst    #0,VI
    bne     WaitVBLEnd
    
    rts
```

### 6.3. Synchronisation par Interruptions

Le GPU et le DSP peuvent générer des interruptions:

```assembly
; Configuration des interruptions
InitInterrupts:
    ; Autoriser les interruptions
    move.w  #$200,INTCON
    
    ; Configurer les vecteurs d'interruption
    ; (Dépend de l'emplacement du code)
    
    rts

; Gestionnaire d'interruption principal
InterruptHandler:
    ; Sauvegarder l'état
    movem.l d0-d7/a0-a6,-(a7)
    
    ; Vérifier la source
    move.w  INT1,d0
    btst    #0,d0               ; Interruption GPU ?
    bne     GPUInterrupt
    btst    #1,d0               ; Interruption DSP ?
    bne     DSPInterrupt
    
    ; Inconnu
    bra     IntEnd
    
GPUInterrupt:
    ; Traiter l'interruption GPU
    bsr     HandleGPUInterrupt
    bra     IntEnd
    
DSPInterrupt:
    ; Traiter l'interruption DSP
    bsr     HandleDSPInterrupt
    
IntEnd:
    ; Restaurer l'état
    movem.l (a7)+,d0-d7/a0-a6
    rte
```

---

## 7. Gestion des Données Partagées

### 7.1. Variables Globales

Les variables globales accessibles par tous les processeurs:

```assembly
; Dans game.inc ou un fichier séparé

; État du jeu
GameState:         ds.l 1   ; État actuel
PreviousState:     ds.l 1   ; État précédent
CurrentLevel:      ds.l 1   ; Niveau actuel

; Score
Score:             ds.l 1   ; Score actuel
HighScore:         ds.l 1   ; Meilleur score

; Vie du joueur
Lives:             ds.w 1   ; Vies restantes
PlayerX:           ds.w 1   ; Position X
PlayerY:           ds.w 1   ; Position Y

; Scrolling
ScrollX:           ds.l 1   ; Position X (16.16 fixe)
ScrollY:           ds.l 1   ; Position Y (16.16 fixe)
ScrollSpeed:       ds.w 1   ; Vitesse de scrolling

; Timers
FrameCounter:      ds.l 1   ; Compteur de frames
RandomSeed:        ds.l 1   ; Graine aléatoire

; Power-ups
PlayerPowerups:    ds.w 1   ; Power-ups actifs
PlayerShieldTimer: ds.w 1   ; Timer du bouclier

; Audio
MasterVolume:      ds.w 1   ; Volume principal
MusicPlaying:      ds.w 1   ; Musique en cours
CurrentSFX:        ds.w 1   ; SFX en cours

; Buffers
GPUCommandBuffer:  ds.b MAX_GPU_COMMANDS * GPU_CMD_SIZE
GPUReturnBuffer:   ds.b MAX_GPU_RETURNS * 8
DSPCommandBuffer:  ds.b MAX_DSP_COMMANDS * DSP_CMD_SIZE
DSPReturnBuffer:   ds.b MAX_DSP_RETURNS * 8

; Compteurs
GPUCommandCount:   ds.l 1
GPUReturnCount:    ds.l 1
DSPCommandCount:   ds.l 1
DSPReturnCount:    ds.l 1
```

### 7.2. Accès aux Variables Partagées

#### Accès depuis M68000

```assembly
; Lecture
move.l  ScrollY,d0

; Écriture (16-bit pour éviter les torn reads)
move.w  #100,ScrollX
```

#### Accès depuis GPU

```assembly
; Lecture avec handshake
movei   #ScrollY,r1
loadw   (r1),r2
loadw   (r1),r3
cmp     r2,r3
bne     ReadScrollY      ; Relire si instable
; r2 contient la valeur

; Écriture dans le buffer de retour
movei   #GPUReturnBuffer,r1
movei   #GPUReturnCount,r2
loadw   (r2),r3
storew  r4,(r1,r3*8)     ; Écrire le type
storew  r5,2(r1,r3*8)    ; Écrire la donnée
add     #1,r3
storew  r3,(r2)
```

#### Accès depuis DSP

```assembly
; Lecture
movei   #MasterVolume,r1
loadw   (r1),r2

; Écriture dans le buffer de retour
movei   #DSPReturnBuffer,r1
movei   #DSPReturnCount,r2
loadw   (r2),r3
storew  r4,(r1,r3*8)
storew  r5,2(r1,r3*8)
add     #1,r3
storew  r3,(r2)
```

---

## 8. Optimisations des Communications

### 8.1. Batching des Commandes

Plutôt que d'envoyer une commande par objet, regrouper les commandes:

```assembly
; Mauvais: Une commande par sprite
; (100 sprites = 100 commandes)

; Bon: Une commande pour tous les sprites
SendAllSprites:
    move.l  #SpriteList,a0
    move.l  #SpriteCount,d0
    
    ; Envoyer une commande "DRAW_ALL_SPRITES"
    move.l  #GPU_CMD_DRAW_ALL_SPRITES,d1
    move.l  a0,d2               ; Pointeur vers la liste
    move.l  d0,d3               ; Nombre de sprites
    bsr     SendGPUCommand
    
    rts
```

### 8.2. Cache des Données

Le GPU cache les données fréquemment utilisées:

```
$F03000-$F03FFF : Code GPU
$F04000-$F04FFF : Cache des sprites (4 KB)
$F05000-$F05FFF : Cache du background (4 KB)
$F06000-$F06FFF : Palette de couleurs (4 KB)
```

### 8.3. Double Buffering

Utiliser le double buffering pour éviter les déchirures:

```assembly
; Framebuffer 0: $840000-$87FFFF
; Framebuffer 1: $880000-$8BFFFF

; Variables
CurrentFB:    ds.l 1   ; 0 ou 1
VisibleFB:    ds.l 1   ; Framebuffer visible

; Basculer les framebuffers
SwapBuffers:
    move.l  CurrentFB,d0
    eor.l   #1,d0        ; Basculer
    move.l  d0,CurrentFB
    
    ; Mettre à jour OLP
    cmp.l   #0,d0
    beq     SetFB0
    move.l  #FB1,OLP
    bra     SwapEnd
SetFB0:
    move.l  #FB0,OLP
SwapEnd:
    rts
```

---

## 9. Exemple Complet: Rendu d'un Frame

### 9.1. Côté M68000

```assembly
UpdateFrame:
    ; 1. Lire les entrées
    bsr     ReadInput
    
    ; 2. Mettre à jour la logique
    bsr     UpdatePlayer
    bsr     UpdateEnemies
    bsr     UpdateBullets
    bsr     CheckCollisions
    bsr     UpdateScrolling
    
    ; 3. Mettre à jour les variables partagées
    move.w  PlayerX,SharedPlayerX
    move.w  PlayerY,SharedPlayerY
    move.l  ScrollY,SharedScrollY
    
    ; 4. Envoyer les commandes au GPU
    ; Effacer l'écran
    move.l  #GPU_CMD_CLEAR,d0
    move.l  #COLOR_BLACK,d1
    bsr     SendGPUCommand
    
    ; Dessiner le background
    move.l  #GPU_CMD_DRAW_BG,d0
    move.l  ScrollY,d1
    bsr     SendGPUCommand
    
    ; Dessiner tous les sprites
    move.l  #GPU_CMD_DRAW_ALL_SPRITES,d0
    move.l  #SpriteList,d1
    move.l  SpriteCount,d2
    bsr     SendGPUCommand
    
    ; Dessiner le HUD
    move.l  #GPU_CMD_DRAW_HUD,d0
    bsr     SendGPUCommand
    
    ; Basculer les framebuffers
    move.l  #GPU_CMD_SWAP_BUFFERS,d0
    bsr     SendGPUCommand
    
    ; 5. Envoyer les commandes au DSP
    ; (Si des SFX doivent être joués)
    
    ; 6. Incrémenter le frame counter
    addq.l  #1,FrameCounter
    
    rts
```

### 9.2. Côté GPU

```assembly
GPUMainLoop:
    ; Attendre VBLANK
WaitGPUVBL:
    load    (VI),r1
    and     #1,r1
    beq     WaitGPUVBL
    
    ; Attendre fin de VBLANK
WaitGPUVBLEnd:
    load    (VI),r1
    and     #1,r1
    bne     WaitGPUVBLEnd
    
    ; Traiter les commandes
    bsr     ProcessGPUCommands
    
    ; Signaler la fin du frame
    bsr     SignalFrameDone
    
    bra     GPUMainLoop
```

### 9.3. Côté DSP

```assembly
DSPMainLoop:
    ; Traiter les commandes
    bsr     ProcessDSPCommands
    
    ; Générer l'audio pour ce frame
    bsr     GenerateAudio
    
    ; Attendre la prochaine interruption
    ; (Le DSP est généralement piloté par interruptions)
    
    bra     DSPMainLoop
```

---

## 10. Problèmes Courants et Solutions

### 10.1. Problème: Torn Reads

**Cause**: Le 68000 écrit un long (32-bit) en 2 writes word (16-bit). Le GPU peut lire une valeur partiellement écrite.

**Solution 1**: Utiliser uniquement des accès 16-bit pour les variables partagées.

**Solution 2**: Implémenter un mécanisme de handshake avec un flag de validation.

**Solution 3**: Utiliser des verrous (locks) matériels si disponibles.

### 10.2. Problème: Bus Arbitration

**Cause**: Le GPU accédant à la Main RAM starve le 68000 (~30% de perte).

**Solution 1**: Minimiser les accès du GPU à la Main RAM.

**Solution 2**: Cacher les données fréquemment utilisées dans la RAM locale du GPU.

**Solution 3**: Utiliser le double buffering pour réduire le nombre d'accès.

### 10.3. Problème: Synchronisation

**Cause**: Les processeurs s'exécutent de manière asynchrone.

**Solution**: Utiliser le VBLANK comme point de synchronisation principal.

### 10.4. Problème: Latence

**Cause**: Le temps de traitement peut varier entre les frames.

**Solution**:
- Limiter le nombre de commandes par frame
- Utiliser des timers pour mesurer les performances
- Optimiser le code pour réduire la latence

---

## 11. Conclusion

Ce document définit un **système de communication robuste** entre les processeurs de l'Atari Jaguar pour le portage de Crisis Force. Il couvre:

- ✅ Architecture de communication globale
- ✅ Protocoles M68000 → GPU
- ✅ Protocoles M68000 → DSP
- ✅ Synchronisation inter-processeurs
- ✅ Gestion des données partagées
- ✅ Optimisations des performances
- ✅ Exemples complets

### Prochaines Étapes

1. **Implémenter les buffers de communication** dans le code
2. **Mettre à jour les fichiers source** avec les structures définies
3. **Tester la communication** dans l'émulateur
4. **Optimiser** selon les performances mesurées

---

**Document validé**: 2026-09-30  
**Prochaine révision**: Après tests initiaux
