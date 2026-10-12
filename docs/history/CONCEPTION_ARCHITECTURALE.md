# Crisis Force - Conception Architecturale Détaillée

**Phase 2: Conception**  
**Date**: 2026-09-30  
**Version**: 1.0

---

## 1. Introduction

Ce document décrit l'architecture détaillée du portage de **Crisis Force** (NES) vers **Atari Jaguar**. Il couvre la répartition des tâches entre les différents processeurs, les communications inter-processeurs, les structures de données, et les adaptations nécessaires pour passer de l'architecture NES (6502 + PPU + APU) à l'architecture Jaguar (M68000 + GPU + DSP + OP + Blitter).

---

## 2. Analyse du Jeu Original (NES)

### 2.1. Caractéristiques Techniques

| Aspect | NES | Jaguar | Adaptation |
|--------|-----|--------|------------|
| **CPU** | 6502 @ 1.79 MHz | M68000 @ 13.3 MHz | ×7.4 plus rapide |
| **Graphiques** | PPU (256×240, 25 couleurs/sprite) | GPU + OP + Blitter (640×480, 16-bit RGB) | Meilleure résolution, plus de couleurs |
| **Audio** | APU (5 canaux) | DSP (16-bit stereo) | Meilleure qualité |
| **Mémoire** | 2 KB RAM, 8 KB VRAM | 8 MB RAM adressable, 64 KB GPU RAM, 8 KB DSP RAM | Beaucoup plus de mémoire |
| **Sprites** | 64 sprites, 8×8 ou 8×16 | Illimité (limité par mémoire) | Pas de limite hardware |
| **Scrolling** | Matériel (PPU) | Logiciel (GPU) | À implémenter |
| **Mapper** | VRC2 (banking) | Pas de banking nécessaire | Tout en ROM |

### 2.2. Fonctionnalités du Jeu

- **Genre**: Shoot 'em up vertical
- **Résolution**: 256×240 (NTSC)
- **Niveaux**: 8 niveaux
- **Vaisseaux joueurs**: 1 (avec différents power-ups)
- **Types d'ennemis**: ~10 types différents
- **Boss**: 1 par niveau
- **Power-ups**: 6 types (Speed, Spread, Laser, Missile, Shield, 1UP)
- **Contrôles**: D-Pad (mouvement), A (tir), B (bombe)

### 2.3. Pattern de Scrolling

Crisis Force utilise un **scrolling vertical pur** avec:
- Vitesse de scrolling constante par niveau
- Pas de scrolling horizontal
- Background en une seule couche (pas de parallax)
- Les sprites ennemis apparaissent depuis le haut

### 2.4. Système de Vagues

- Les ennemis apparaissent en vagues prédéfinies
- Chaque vague a un type d'ennemi, un pattern de mouvement, et un timing
- Les vagues sont déclenchées par la position de scrolling

---

## 3. Architecture Jaguar

### 3.1. Répartition des Responsabilités

#### M68000 (Main CPU)

**Responsabilités**:
- Logique principale du jeu
- Gestion des états du jeu
- Contrôle du flux de jeu (menus, niveaux, game over)
- Gestion des entrées utilisateur
- Calcul des collisions
- Gestion de la logique des vagues d'ennemis
- Calcul des positions et mouvements
- Synchronisation entre processeurs

**Temps CPU disponible**:
- 60 Hz (VBLANK) = 16.67 ms/frame
- À 13.295 MHz, environ 220,000 cycles/frame
- Budget estimé: 50,000-100,000 cycles/frame pour la logique jeu

#### GPU (Tom)

**Responsabilités**:
- Rendu de tous les graphismes
- Gestion des sprites (joueur, ennemis, balles, power-ups)
- Rendu du background (avec scrolling)
- Rendu du HUD (score, vies, niveau)
- Gestion des animations
- Effets visuels (explosions, etc.)

**Temps GPU disponible**:
- 26.59 MHz, mais partagé avec l'accès mémoire
- Budget estimé: 1-2 ms/frame pour le rendu

#### DSP (Jerry)

**Responsabilités**:
- Génération et mixing de l'audio
- Lecture des effets sonores (SFX)
- Lecture de la musique
- Gestion du volume et du pan

**Temps DSP disponible**:
- 26.59 MHz
- Budget estimé: 0.5-1 ms/frame pour l'audio

#### OP (Object List Processor)

**Responsabilités**:
- Gestion de la liste des objets à afficher
- Tri des sprites par priorité
- Application des attributs (couleur, transparence, etc.)

#### Blitter

**Responsabilités**:
- Copie rapide de mémoire (sprites, backgrounds)
- Remplissage de zones
- Opérations logiques

---

## 4. Communication Inter-Processeur

### 4.1. Protocole de Communication

Pour synchroniser les différents processeurs, nous utilisons un système de **buffers partagés** et de **flags de synchronisation**.

#### Structure des Buffers Partagés

```
$800000-$800FFF : Buffer de commandes GPU (4 KB)
$801000-$801FFF : Buffer de commandes DSP (4 KB)
$802000-$802FFF : Buffer de retour GPU (4 KB)
$803000-$803FFF : Buffer de retour DSP (4 KB)
```

#### Structure d'une Commande

```assembly
; Structure d'une commande (16 octets)
    dc.l    CommandType       ; Type de commande (0 = vide, 1 = draw, 2 = play, etc.)
    dc.l    Parameter1        ; Paramètre 1
    dc.l    Parameter2        ; Paramètre 2
    dc.l    Parameter3        ; Paramètre 3
```

### 4.2. Synchronisation

#### Synchronisation M68000 → GPU

1. **M68000** écrit une commande dans le buffer GPU
2. **M68000** incrémente le flag `GPUCommandCount`
3. **GPU** vérifie `GPUCommandCount` à chaque frame
4. **GPU** exécute les nouvelles commandes
5. **GPU** écrit un accusé de réception dans le buffer de retour

#### Synchronisation M68000 → DSP

1. **M68000** écrit une commande audio dans le buffer DSP
2. **M68000** active l'interruption DSP
3. **DSP** traite la commande dans son ISR
4. **DSP** écrit un accusé dans le buffer de retour

### 4.3. Variables Partagées

```
$800000 : GPUCommandCount      ; Compteur de commandes pour GPU
$800004 : DSPCommandCount      ; Compteur de commandes pour DSP
$800008 : FrameCounter         ; Compteur global de frames
$80000C : CurrentLevel         ; Niveau actuel
$800010 : GameState            ; État du jeu
$800014 : Joy1State            ; État du joystick 1
$800018 : Joy1Previous         ; État précédent
$80001C : ScrollX             ; Position de scrolling X
$800020 : ScrollY             ; Position de scrolling Y
$800024 : PlayerX             ; Position X du joueur
$800028 : PlayerY             ; Position Y du joueur
```

### 4.4. Mécanisme de Handshake

Pour éviter les problèmes de "torn reads" (68000 `move.l` = 2 Word Writes) :

```assembly
; Écriture par M68000 (utiliser move.w pour les 16-bit)
move.w  d0,ScrollX      ; Écriture atomique 16-bit

; Lecture par GPU (attendre que la valeur soit stable)
WaitStable:
    loadw   (ScrollX),r1
    loadw   (ScrollX),r2
    cmp     r1,r2
    bne     WaitStable
```

---

## 5. Structures de Données

### 5.1. Structure du Jeu

#### État du Jeu

```assembly
; GameState structure (4 octets)
GAME_STATE_TITLE       equ 0
GAME_STATE_PLAYING     equ 1
GAME_STATE_PAUSED      equ 2
GAME_STATE_GAMEOVER    equ 3
GAME_STATE_LEVELCLEAR  equ 4
```

#### Niveau

```assembly
; Level structure (64 octets)
    rsreset
LEVEL_SCROLL_SPEED    rs.w 1       ; Vitesse de scrolling
LEVEL_ENEMY_COUNT     rs.w 1       ; Nombre total d'ennemis
LEVEL_WAVE_POINTER    rs.l 1       ; Pointeur vers les données de vagues
LEVEL_BG_POINTER      rs.l 1       ; Pointeur vers le background
LEVEL_MUSIC_ID        rs.w 1       ; ID de la musique
LEVEL_SIZE            rs.b 0
```

### 5.2. Structure des Sprites

#### Sprite Générique

```assembly
; Sprite structure (32 octets)
    rsreset
SPRITE_ACTIVE         rs.w 1       ; 0 = inactif, 1 = actif
SPRITE_X              rs.w 1       ; Position X (16.8 fixe)
SPRITE_Y              rs.w 1       ; Position Y (16.8 fixe)
SPRITE_VX             rs.w 1       ; Vitesse X (16.8 fixe)
SPRITE_VY             rs.w 1       ; Vitesse Y (16.8 fixe)
SPRITE_WIDTH          rs.w 1       ; Largeur
SPRITE_HEIGHT         rs.w 1       ; Hauteur
SPRITE_GRAPHIC       rs.l 1       ; Pointeur vers les données graphiques
SPRITE_FRAME          rs.w 1       ; Frame actuel
SPRITE_FRAME_COUNT    rs.w 1       ; Nombre de frames
SPRITE_COLOR          rs.w 1       ; Couleur (RGB16)
SPRITE_FLAGS          rs.w 1       ; Flags (voir ci-dessous)
SPRITE_TYPE           rs.w 1       ; Type de sprite
SPRITE_HEALTH         rs.w 1       ; Points de vie (pour les ennemis)
SPRITE_TIMER          rs.w 1       ; Timer pour animations
SPRITE_SIZE           rs.b 0

; Sprite Flags
SPRITE_FLAG_FLIP_H     equ $0001    ; Retourner horizontalement
SPRITE_FLAG_FLIP_V     equ $0002    ; Retourner verticalement
SPRITE_FLAG_HIDDEN    equ $0004    ; Caché
SPRITE_FLAG_CULL      equ $0008    ; Hors écran (culling)
SPRITE_FLAG_COLLIDE   equ $0010    ; Peut collider
```

#### Types de Sprites

```assembly
SPRITE_TYPE_PLAYER     equ 0
SPRITE_TYPE_ENEMY     equ 1
SPRITE_TYPE_BULLET    equ 2
SPRITE_TYPE_POWERUP   equ 3
SPRITE_TYPE_EXPLOSION equ 4
SPRITE_TYPE_PARTICLE  equ 5
```

### 5.3. Structure des Ennemis

```assembly
; Enemy structure (64 octets)
    rsreset
ENEMY_BASE            rs.l 1       ; Pointeur vers la structure Sprite
ENEMY_TYPE            rs.w 1       ; Type d'ennemi
ENEMY_STATE           rs.w 1       ; État (0=inactif, 1=entrant, 2=actif, 3=sortant, 4=mourant)
ENEMY_PATTERN         rs.w 1       ; Pattern de mouvement
ENEMY_PATTERN_TIMER   rs.w 1       ; Timer pour le pattern
ENEMY_FIRE_TIMER      rs.w 1       ; Timer pour le tir
ENEMY_FIRE_DELAY      rs.w 1       ; Délai entre les tirs
ENEMY_BULLET_TYPE     rs.w 1       ; Type de balle
ENEMY_SCORE           rs.l 1       ; Score donné à la destruction
ENEMY_HEALTH          rs.w 1       ; Points de vie
ENEMY_DAMAGE          rs.w 1       ; Dégâts infligés
ENEMY_HITBOX_X        rs.w 1       ; Hitbox X offset
ENEMY_HITBOX_Y        rs.w 1       ; Hitbox Y offset
ENEMY_HITBOX_W        rs.w 1       ; Hitbox largeur
ENEMY_HITBOX_H        rs.w 1       ; Hitbox hauteur
ENEMY_SIZE           rs.b 0
```

#### Types d'Ennemis (basés sur Crisis Force)

```assembly
ENEMY_TYPE_SMALL_FIGHTER   equ 0   ; Petit chasseur
ENEMY_TYPE_MEDIUM_FIGHTER  equ 1   ; Chasseur moyen
ENEMY_TYPE_LARGE_FIGHTER   equ 2   ; Gros chasseur
ENEMY_TYPE_KAMIKAZE        equ 3   ; Kamikaze (charge le joueur)
ENEMY_TYPE_TURRET          equ 4   ; Tourelle fixe
ENEMY_TYPE_MOVING_TURRET   equ 5   ; Tourelle mobile
ENEMY_TYPE_DODGER          equ 6   ; Évite les balles
ENEMY_TYPE_FORMATION_LEADER equ 7 ; Chef de formation
ENEMY_TYPE_BOSS           equ 8   ; Boss de fin de niveau
```

### 5.4. Structure des Balles

```assembly
; Bullet structure (32 octets)
    rsreset
BULLET_BASE           rs.l 1       ; Pointeur vers la structure Sprite
BULLET_TYPE           rs.w 1       ; Type de balle
BULLET_OWNER          rs.w 1       ; Propriétaire (0=joueur, 1=ennemi)
BULLET_DAMAGE         rs.w 1       ; Dégâts
BULLET_DISTANCE       rs.w 1       ; Distance parcourue (pour limite de portée)
BULLET_SIZE           rs.b 0

; Bullet Types
BULLET_TYPE_NORMAL    equ 0
BULLET_TYPE_WIDE      equ 1
BULLET_TYPE_LASER     equ 2
BULLET_TYPE_MISSILE   equ 3
BULLET_TYPE_ENEMY_A   equ 4
BULLET_TYPE_ENEMY_B   equ 5
BULLET_TYPE_BOSS      equ 6
```

### 5.5. Structure des Power-ups

```assembly
; PowerUp structure (16 octets)
    rsreset
POWERUP_BASE         rs.l 1       ; Pointeur vers la structure Sprite
POWERUP_TYPE         rs.w 1       ; Type de power-up
POWERUP_TIMER        rs.w 1       ; Timer avant disparition
POWERUP_SIZE         rs.b 0

; PowerUp Types
POWERUP_TYPE_SPEED    equ 0   ; Augmente la vitesse
POWERUP_TYPE_SPREAD   equ 1   ; Tirs en éventail
POWERUP_TYPE_LASER    equ 2   ; Tirs laser
POWERUP_TYPE_MISSILE  equ 3   ; Missiles
POWERUP_TYPE_SHIELD   equ 4   ; Bouclier
POWERUP_TYPE_1UP      equ 5   ; Vie supplémentaire
```

### 5.6. Structure des Particules

```assembly
; Particle structure (24 octets)
    rsreset
PARTICLE_BASE        rs.l 1       ; Pointeur vers la structure Sprite
PARTICLE_TYPE        rs.w 1       ; Type de particule
PARTICLE_LIFETIME    rs.w 1       ; Durée de vie
PARTICLE_VX          rs.w 1       ; Vitesse X
PARTICLE_VY          rs.w 1       ; Vitesse Y
PARTICLE_COLOR       rs.w 1       ; Couleur
PARTICLE_SIZE        rs.b 0

; Particle Types
PARTICLE_TYPE_EXPLOSION equ 0
PARTICLE_TYPE_SPARK     equ 1
PARTICLE_TYPE_SMOKE     equ 2
PARTICLE_TYPE_FIRE      equ 3
```

### 5.7. Structure des Vagues d'Ennemis

```assembly
; Wave structure (32 octets)
    rsreset
WAVE_TYPE            rs.w 1       ; Type de vague
WAVE_ENEMY_TYPE      rs.w 1       ; Type d'ennemi
WAVE_COUNT           rs.w 1       ; Nombre d'ennemis
WAVE_DELAY           rs.w 1       ; Délai avant l'apparition
WAVE_SPACING         rs.w 1       ; Espacement entre les ennemis
WAVE_X_START         rs.w 1       ; Position X de départ
WAVE_Y_START         rs.w 1       ; Position Y de départ
WAVE_X_SPEED         rs.w 1       ; Vitesse X
WAVE_Y_SPEED         rs.w 1       ; Vitesse Y
WAVE_PATTERN         rs.w 1       ; Pattern de mouvement
WAVE_POINTER         rs.l 1       ; Pointeur vers les données suivantes
WAVE_SIZE            rs.b 0

; Wave Types
WAVE_TYPE_LINEAR      equ 0   ; Apparition linéaire
WAVE_TYPE_SINE        equ 1   ; Pattern sinusoïdal
WAVE_TYPE_ZIGZAG      equ 2   ; Zigzag
WAVE_TYPE_CIRCLE      equ 3   ; Cercle
WAVE_TYPE_RANDOM      equ 4   ; Aléatoire
WAVE_TYPE_FORMATION   equ 5   ; Formation
```

---

## 6. Mémoire et Adressage

### 6.1. Carte Mémoire

```
$000000-$0FFFFF : Header ROM + code de boot (64 KB)
  ├── $000000-$0000FF : Header ROM Jaguar
  └── $000100-$0FFFFF : Code de boot et initialisation

$010000-$3FFFFF : Code et données du jeu (512 KB)
  ├── $010000-$02FFFF : Code M68000 principal
  ├── $030000-$04FFFF : Données de niveaux
  ├── $050000-$0AFFFF : Graphismes (sprites, backgrounds)
  ├── $0B0000-$0BFFFF : Données audio (musique, SFX)
  └── $0C0000-$3FFFFF : Code et données supplémentaires

$800000-$803FFF : Stack et variables globales (16 KB)
  ├── $800000-$800FFF : Buffer de communication (4 KB)
  ├── $801000-$801FFF : Variables globales (4 KB)
  └── $802000-$803FFF : Stack (8 KB)

$804000-$80FFFF : Code 68000 exécutable (60 KB)

$810000-$83FFFF : Données générales (192 KB)
  ├── $810000-$813FFF : Pool de sprites (16 KB)
  ├── $814000-$817FFF : Pool d'ennemis (16 KB)
  ├── $818000-$81BFFF : Pool de balles (16 KB)
  ├── $81C000-$81FFFF : Pool de power-ups et particules (16 KB)
  └── $820000-$83FFFF : Données dynamiques (96 KB)

$840000-$87FFFF : Framebuffer 0 (128 KB) - 320×480×2 (RGB16)
$880000-$8BFFFF : Framebuffer 1 (128 KB) - Double buffering

$F00000-$F0FFFF : RAM GPU (64 KB)
  ├── $F03000-$F03FFF : Code GPU (4 KB)
  ├── $F04000-$F04FFF : Données GPU (4 KB)
  └── $F05000-$F0FFFF : Buffer de rendu (48 KB)

$F10000-$F13FFF : RAM DSP (8 KB)
  ├── $F1B000-$F1BFFF : Code DSP (1 KB)
  ├── $F1C000-$F1CFFF : Données audio (4 KB)
  └── $F1D000-$F13FFF : Buffer audio (3 KB)
```

### 6.2. Allocation Dynamique

Pour gérer les sprites, ennemis, balles, etc., nous utilisons un **pool d'objets** avec allocation par index.

```assembly
; Exemple: Pool de sprites (MAX_SPRITES = 64)
SpritePool:
    ds.b    MAX_SPRITES * SPRITE_SIZE

; Allocation d'un sprite
GetFreeSprite:
    move.l  #SpritePool,a0
    move.w  #MAX_SPRITES,d0
    move.l  #0,d1               ; Index
FindFreeSprite:
    tst.w   SPRITE_ACTIVE(a0,d1.w*SPRITE_SIZE)
    beq     FoundFreeSprite
    addq.w  #1,d1
    dbra    d0,FindFreeSprite
    ; Pas de sprite libre
    rts
FoundFreeSprite:
    ; Marquer comme actif
    move.w  #1,SPRITE_ACTIVE(a0,d1.w*SPRITE_SIZE)
    ; Retourner l'index dans d1
    rts
```

---

## 7. Adaptation des Entrées

### 7.1. Mapping NES → Jaguar

| Bouton NES | Bouton Jaguar | Registre | Bit |
|------------|----------------|----------|-----|
| D-Pad Up | D-Pad Up | JOY1DATA | Bit 0 |
| D-Pad Down | D-Pad Down | JOY1DATA | Bit 1 |
| D-Pad Left | D-Pad Left | JOY1DATA | Bit 2 |
| D-Pad Right | D-Pad Right | JOY1DATA | Bit 3 |
| A | Bouton A | JOY1DATA | Bit 4 |
| B | Bouton B | JOY1DATA | Bit 5 |
| Start | Bouton C | JOY1DATA | Bit 6 |
| Select | Bouton Pause | JOY1DATA | Bit 7 |

### 7.2. Gestion des Entrées

```assembly
; Dans main.s
ReadInput:
    move.l  JOY1DATA,d0           ; Lire le joystick
    move.l  d0,Joy1Current         ; Sauvegarder
    
    ; Calculer les changements
    move.l  Joy1Current,d0
    eor.l   Joy1Previous,d0
    move.l  d0,Joy1Changed         ; Changements
    move.l  Joy1Current,Joy1Previous ; Sauvegarder pour le prochain frame
    
    ; Tester les boutons
    btst    #0,d0                  ; Up pressé ?
    bne     UpPressed
    btst    #1,d0                  ; Down pressé ?
    bne     DownPressed
    ; ... etc
    
    rts

; Définitions des boutons
JOY_UP     equ 0
JOY_DOWN   equ 1
JOY_LEFT   equ 2
JOY_RIGHT  equ 3
JOY_A      equ 4
JOY_B      equ 5
JOY_C      equ 6
JOY_PAUSE  equ 7
```

### 7.3. Gestion des States

```assembly
; État du joueur
PLAYER_MOVING_UP      equ $0001
PLAYER_MOVING_DOWN    equ $0002
PLAYER_MOVING_LEFT    equ $0004
PLAYER_MOVING_RIGHT   equ $0008
PLAYER_FIRING         equ $0010
PLAYER_BOMBING        equ $0020
PLAYER_SHIELDING      equ $0040

PlayerState: ds.w 1
```

---

## 8. Système de Scrolling

### 8.1. Implémentation du Scrolling Vertical

Crisis Force utilise un scrolling vertical simple. Sur Jaguar, nous devons implémenter cela logiciellement.

#### Variables de Scrolling

```assembly
ScrollY:          ds.l 1       ; Position de scrolling (16.16 fixe)
ScrollSpeed:      ds.w 1       ; Vitesse de scrolling (par frame)
ScrollTarget:     ds.l 1       ; Position cible
ScrollMax:        ds.l 1       ; Position maximale (fin du niveau)
```

#### Mise à jour du Scrolling

```assembly
; Dans main.s
UpdateScrolling:
    ; Incrémenter ScrollY
    move.l  ScrollY,d0
    move.w  ScrollSpeed,d1
    ext.l   d1
    add.l   d1,d0
    move.l  d0,ScrollY
    
    ; Vérifier si on a atteint la fin
    cmp.l   ScrollMax,d0
    ble     ScrollOK
    move.l  ScrollMax,ScrollY
    ; Déclencher une nouvelle vague ou niveau terminé
    bsr     TriggerNextWave
ScrollOK:
    rts
```

### 8.2. Rendu du Background avec Scrolling

Le GPU doit rendre le background avec un offset basé sur ScrollY.

```assembly
; Dans gpu.s
GPURenderBackground:
    ; Lire ScrollY (en utilisant move.w pour éviter les torn reads)
    movei   #ScrollY,r1
    loadw   (r1),r2              ; ScrollY (bas)
    loadw   2(r1),r3             ; ScrollY (haut)
    
    ; Calculer l'offset dans le background
    ; Background est 256 pixels de large × 512 pixels de haut (pour le scrolling)
    ; On affiche 256×240, avec un offset Y
    
    ; Calculer la ligne de départ dans le background
    move    r2,r4               ; Copier ScrollY (bas)
    shr     #4,r4               ; Diviser par 16 (pour l'offset en pixels)
    and     #$FFE0,r4           ; Aligner sur 32 pixels (optimisation)
    
    ; Adresse source = BG_DATA + (offset_y * 256 * 2)
    movei   #BG_DATA,r5
    move    r4,r6
    shl     #9,r6               ; × 256 (largeur)
    shl     #1,r6               ; × 2 (RGB16)
    add     r6,r5               ; Adresse source
    
    ; Adresse destination = FRAMEBUFFER
    movei   #CURRENT_FB,r7
    
    ; Copier une ligne (256×2 octets)
    movei   #256*2,r8           ; Taille de ligne
    
    ; Utiliser le Blitter pour copier
    move    r5,BLITSRC
    move    r7,BLITDST
    move    r8,BLITCOUNT
    movei   #$200000,r9         ; Commande: copie simple
    store   r9,BLITCTRL
    
    ; Répéter pour 240 lignes
    movei   #240,r10
BackgroundLoop:
    ; Attendre que le Blitter soit prêt
    load    (BLITSTAT),r11
    and     #$1,r11
    bne     BackgroundLoop
    
    ; Passer à la ligne suivante
    add     #256*2,r5           ; Source + 1 ligne
    add     #320*2,r7           ; Destination + 1 ligne (320 pixels de large)
    sub     #1,r10
    bne     BackgroundLoop
    
    rts
```

### 8.3. Optimisation du Scrolling

Pour améliorer les performances:

1. **Double Buffering**: Utiliser deux framebuffers pour éviter les déchirures
2. **Tile Caching**: Cacher les tiles du background dans la RAM GPU
3. **Dirty Rectangles**: Ne redessiner que les parties modifiées
4. **Blitter**: Utiliser le Blitter pour les copies rapides

---

## 9. Système de Rendu des Sprites

### 9.1. Organisation des Sprites

Les sprites sont organisés en **lists de sprites** pour chaque frame.

```assembly
; Liste des sprites à afficher (max 64)
SpriteList:
    dc.l    Sprite0_Pointer
    dc.l    Sprite1_Pointer
    ; ...
    dc.l    0                   ; Fin de liste
```

### 9.2. Rendu d'un Sprite

```assembly
; Dans gpu.s
GPUDrawSprite:
    ; Entrée: r10 = pointeur vers le sprite
    
    ; Charger les propriétés
    loadw   SPRITE_X(r10),r11    ; X (16.8 fixe)
    loadw   SPRITE_Y(r10),r12    ; Y (16.8 fixe)
    loadw   SPRITE_WIDTH(r10),r13
    loadw   SPRITE_HEIGHT(r10),r14
    load    SPRITE_GRAPHIC(r10),r15 ; Pointeur vers l'image
    loadw   SPRITE_FRAME(r10),r16
    loadw   SPRITE_COLOR(r10),r17
    loadw   SPRITE_FLAGS(r10),r18
    
    ; Calculer la position dans le framebuffer
    ; FB_Address = FRAMEBUFFER + (Y * 320 * 2) + (X * 2)
    move    r12,r19
    shr     #8,r19               ; Y entier
    shl     #9,r19               ; × 256
    shl     #2,r19               ; × 4 (× 256 * 4 = × 1024, mais on veut × 640)
    ; Correction: 320 * 2 = 640
    move    r12,r19
    movei   #640,r20
    mul     r19,r20              ; Y * 640
    
    move    r11,r21
    shr     #8,r21               ; X entier
    shl     #1,r21               ; X * 2 (pour RGB16)
    add     r21,r20              ; Adresse finale
    
    movei   #CURRENT_FB,r22
    add     r22,r20              ; Adresse absolue dans le framebuffer
    
    ; Appliquer le frame (pour les animations)
    ; Chaque frame = 16×16 pixels
    move    r16,r23
    movei   #16*16*2,r24        ; Taille d'un frame
    mul     r23,r24
    add     r24,r15              ; Adresse source + offset frame
    
    ; Vérifier les flags
    move    r18,r25
    and     #SPRITE_FLAG_FLIP_H,r25
    beq     NoFlipH
    ; Retourner horizontalement
    ; (implémentation à ajouter)
NoFlipH:
    
    ; Utiliser le Blitter pour copier le sprite
    move    r15,BLITSRC
    move    r20,BLITDST
    move    r13,r26
    shl     #1,r26               ; Largeur en octets
    mul     r14,r26              ; Largeur * Hauteur
    move    r26,BLITCOUNT
    movei   #$200000,r27         ; Copie simple
    store   r27,BLITCTRL
    
    rts
```

### 9.3. Gestion des Animations

```assembly
; Structure d'animation
Animation:
    dc.w    FrameCount       ; Nombre de frames
    dc.w    FrameDelay       ; Délai entre les frames
    dc.l    FramePointers    ; Pointeur vers la liste des frames
    dc.w    LoopFlag         ; 0 = une fois, 1 = boucle
    dc.w    CurrentFrame     ; Frame actuel
    dc.w    FrameTimer       ; Timer pour le frame courant

; Mise à jour de l'animation
UpdateAnimation:
    ; Entrée: a0 = pointeur vers le sprite
    move.l  a0,a1
    add.l   #SPRITE_ANIMATION,a1 ; Pointeur vers l'animation
    
    move.w  ANIM_FRAME_TIMER(a1),d0
    addq.w  #1,d0
    cmp.w   ANIM_FRAME_DELAY(a1),d0
    blt     UpdateAnimEnd
    
    ; Passer au frame suivant
    clr.w   ANIM_FRAME_TIMER(a1)
    move.w  ANIM_CURRENT_FRAME(a1),d0
    addq.w  #1,d0
    cmp.w   ANIM_FRAME_COUNT(a1),d0
    blt     UpdateAnimFrame
    
    ; Vérifier LoopFlag
    tst.w   ANIM_LOOP_FLAG(a1)
    bne     UpdateAnimLoop
    
    ; Animation terminée
    move.w  #0,SPRITE_ANIMATION(a0)
    rts
    
UpdateAnimLoop:
    clr.w   d0
UpdateAnimFrame:
    move.w  d0,ANIM_CURRENT_FRAME(a1)
    move.w  d0,SPRITE_FRAME(a0)
    
UpdateAnimEnd:
    rts
```

---

## 10. Système de Collision

### 10.1. Détection de Collision

Nous utilisons une **hitbox simplifiée** pour les collisions.

```assembly
; Structure de hitbox
    rsreset
HITBOX_X             rs.w 1
HITBOX_Y             rs.w 1
HITBOX_WIDTH         rs.w 1
HITBOX_HEIGHT        rs.w 1
HITBOX_SIZE          rs.b 0

; Fonction de collision AABB (Axis-Aligned Bounding Box)
CheckCollision:
    ; Entrée: a0 = pointeur vers sprite A, a1 = pointeur vers sprite B
    ; Sortie: d0 = 1 si collision, 0 sinon
    
    ; Charger les hitboxes
    move.w  SPRITE_HITBOX_X(a0),d0
    move.w  SPRITE_HITBOX_Y(a0),d1
    move.w  SPRITE_HITBOX_W(a0),d2
    move.w  SPRITE_HITBOX_H(a0),d3
    
    move.w  SPRITE_HITBOX_X(a1),d4
    move.w  SPRITE_HITBOX_Y(a1),d5
    move.w  SPRITE_HITBOX_W(a1),d6
    move.w  SPRITE_HITBOX_H(a1),d7
    
    ; Vérifier collision sur X
    move.w  d0,d8
    add.w   d2,d8               ; A.right = A.x + A.width
    cmp.w   d4,d8               ; A.right < B.x ?
    blt     NoCollision
    
    move.w  d4,d8
    add.w   d6,d8               ; B.right = B.x + B.width
    cmp.w   d0,d8               ; B.right < A.x ?
    blt     NoCollision
    
    ; Vérifier collision sur Y
    move.w  d1,d8
    add.w   d3,d8               ; A.bottom = A.y + A.height
    cmp.w   d5,d8               ; A.bottom < B.y ?
    blt     NoCollision
    
    move.w  d5,d8
    add.w   d7,d8               ; B.bottom = B.y + B.height
    cmp.w   d1,d8               ; B.bottom < A.y ?
    blt     NoCollision
    
    ; Collision !
    moveq   #1,d0
    rts
    
NoCollision:
    clr.l   d0
    rts
```

### 10.2. Gestion des Collisions

```assembly
; Dans main.s
CheckAllCollisions:
    ; Vérifier collisions joueur-ennemis
    bsr     CheckPlayerEnemyCollisions
    
    ; Vérifier collisions balles-ennemis
    bsr     CheckBulletEnemyCollisions
    
    ; Vérifier collisions joueur-powerups
    bsr     CheckPlayerPowerUpCollisions
    
    ; Vérifier collisions joueur-balles ennemies
    bsr     CheckPlayerEnemyBulletCollisions
    
    rts

CheckPlayerEnemyCollisions:
    ; Pour chaque ennemi actif
    move.l  #EnemyPool,a0
    move.w  #MAX_ENEMIES,d0
CheckEnemyLoop:
    tst.w   ENEMY_ACTIVE(a0)
    beq     NextEnemy
    
    ; Vérifier collision avec le joueur
    move.l  a0,a1               ; Ennemi
    move.l  #PlayerSprite,a2   ; Joueur
    bsr     CheckCollision
    tst.l   d0
    beq     NextEnemy
    
    ; Collision détectée !
    ; Réduire la vie du joueur ou déclencher l'explosion
    tst.w   PlayerShield
    bne     EnemyDiesOnly
    
    ; Joueur touché
    subq.w  #1,PlayerLives
    bsr     PlayerHit
    
EnemyDiesOnly:
    ; Ennemi meurt
    move.w  #ENEMY_STATE_DYING,ENEMY_STATE(a0)
    bsr     EnemyHit
    
NextEnemy:
    add.l   #ENEMY_SIZE,a0
    dbra    d0,CheckEnemyLoop
    rts
```

---

## 11. Système Audio

### 11.1. Organisation de l'Audio

Sur Jaguar, le DSP gère l'audio via l'interface I2S.

#### Canaux Audio

| Canal | Usage |
|-------|-------|
| 0 | Musique (background) |
| 1 | Effets sonores (SFX) |
| 2 | Voix/autres |
| 3 | Réservé |

### 11.2. Commandes Audio

```assembly
; Commandes envoyées au DSP
AUDIO_CMD_PLAY_SFX    equ 1
AUDIO_CMD_PLAY_MUSIC  equ 2
AUDIO_CMD_STOP_SFX    equ 3
AUDIO_CMD_STOP_MUSIC  equ 4
AUDIO_CMD_SET_VOLUME  equ 5
AUDIO_CMD_SET_PAN     equ 6
AUDIO_CMD_PAUSE       equ 7
AUDIO_CMD_RESUME      equ 8

; Structure d'une commande audio
    rsreset
AUDIO_CMD_TYPE       rs.w 1
AUDIO_CMD_ID         rs.w 1       ; ID du SFX ou musique
AUDIO_CMD_VOLUME     rs.w 1       ; Volume (0-127)
AUDIO_CMD_PAN        rs.w 1       ; Pan (0-127, 64=centre)
AUDIO_CMD_SIZE       rs.b 0
```

### 11.3. Gestion Audio côté M68000

```assembly
; Dans main.s
PlaySFX:
    ; Entrée: d0 = ID du SFX, d1 = volume, d2 = pan
    move.l  #DSPCommandBuffer,a0
    move.l  #DSPCommandCount,a1
    
    ; Attendre qu'il y ait de la place
WaitAudioSlot:
    move.l  (a1),d3
    cmp.l   #MAX_DSP_COMMANDS,d3
    bge     WaitAudioSlot
    
    ; Écrire la commande
    move.w  #AUDIO_CMD_PLAY_SFX,(a0,d3.w*8)
    move.w  d0,2(a0,d3.w*8)        ; ID
    move.w  d1,4(a0,d3.w*8)        ; Volume
    move.w  d2,6(a0,d3.w*8)        ; Pan
    
    ; Incrémenter le compteur
    addq.l  #1,(a1)
    
    ; Déclencher l'interruption DSP
    move.w  #$1,DSPCTRL
    
    rts
```

### 11.4. Traitement Audio côté DSP

```assembly
; Dans dsp.s
DSPProcessCommands:
    movei   #DSPCommandBuffer,r1
    movei   #DSPCommandCount,r2
    
DSPCmdLoop:
    ; Lire le compteur
    load    (r2),r3
    cmp     #0,r3
    beq     DSPEnd
    
    ; Décrémenter
    sub     #1,r3
    store   r3,(r2)
    
    ; Lire la commande
    loadw   (r1,r3*8),r4        ; Type
    loadw   2(r1,r3*8),r5       ; ID
    loadw   4(r1,r3*8),r6       ; Volume
    loadw   6(r1,r3*8),r7       ; Pan
    
    ; Traiter selon le type
    cmp     #AUDIO_CMD_PLAY_SFX,r4
    beq     PlaySFXCmd
    cmp     #AUDIO_CMD_PLAY_MUSIC,r4
    beq     PlayMusicCmd
    ; ... autres commandes
    
    bra     DSPCmdLoop
    
PlaySFXCmd:
    ; Jouer le SFX
    bsr     DSPSFXPlay
    bra     DSPCmdLoop
    
DSPEnd:
    rts
```

---

## 12. Boucle Principale du Jeu

### 12.1. Flow du Jeu

```
[Start]
   │
   ▼
[Initialisation]
   │
   ▼
[Boucle Principale]
   ├── [Attendre VBLANK]
   ├── [Lire Entrées]
   ├── [Mettre à jour Logique]
   │     ├── [Mettre à jour Joueur]
   │     ├── [Mettre à jour Ennemis]
   │     ├── [Mettre à jour Balles]
   │     ├── [Mettre à jour Particules]
   │     ├── [Vérifier Collisions]
   │     ├── [Mettre à jour Scrolling]
   │     └── [Gérer Vagues]
   ├── [Envoyer Commandes GPU]
   ├── [Envoyer Commandes DSP]
   └── [Fin de Frame]
      │
      ▼
   [Rendu GPU (en parallèle)]
   [Audio DSP (en parallèle)]
```

### 12.2. Code de la Boucle Principale

```assembly
; Dans main.s
MainLoop:
    ; Attendre VBLANK
    bsr     WaitVBL
    
    ; Lire les entrées
    bsr     ReadInput
    
    ; Mettre à jour selon l'état
    move.l  GameState,d0
    cmp.l   #GAME_STATE_TITLE,d0
    beq     UpdateTitle
    cmp.l   #GAME_STATE_PLAYING,d0
    beq     UpdatePlaying
    cmp.l   #GAME_STATE_PAUSED,d0
    beq     UpdatePaused
    cmp.l   #GAME_STATE_GAMEOVER,d0
    beq     UpdateGameOver
    bra     MainLoop
    
UpdateTitle:
    bsr     UpdateTitleScreen
    bra     RenderFrame
    
UpdatePlaying:
    ; Mettre à jour la logique
    bsr     UpdatePlayer
    bsr     UpdateEnemies
    bsr     UpdateBullets
    bsr     UpdateParticles
    bsr     CheckAllCollisions
    bsr     UpdateScrolling
    bsr     UpdateWaves
    
    ; Envoyer des commandes
    bsr     SendGPUCommands
    bsr     SendDSPCommands
    
    ; Vérifier les conditions de fin
    bsr     CheckLevelClear
    bsr     CheckGameOver
    
    bra     RenderFrame
    
UpdatePaused:
    bsr     UpdatePauseScreen
    bra     RenderFrame
    
UpdateGameOver:
    bsr     UpdateGameOverScreen
    
RenderFrame:
    ; Incrémenter le compteur de frames
    addq.l  #1,FrameCounter
    
    bra     MainLoop
```

---

## 13. Optimisations

### 13.1. Optimisations M68000

1. **Utiliser les registres d'adresse**:
   ```assembly
   ; Mauvais
   move.l  #$800000,d0
   move.w  (d0),d1
   move.w  2(d0),d2
   
   ; Bon
   movea.l #$800000,a0
   move.w  (a0),d1
   move.w  2(a0),d2
   ```

2. **Utiliser `movem` pour sauvegarder/restaurer**:
   ```assembly
   movem.l d0-d7/a0-a6,-(a7)
   ; ... code
   movem.l (a7)+,d0-d7/a0-a6
   ```

3. **Éviter les labels `.s`, `.w`, `.l`, `.b`**: Ils conflictent avec les suffixes de taille.

4. **Attention à l'évaluation des expressions**: rmac évalue LEFT TO RIGHT, sans précédence.
   ```assembly
   ; Mauvais: 10+20*3 = 90, pas 70
   move.l  #10+20*3,d0
   
   ; Bon
   move.l  #10+(20*3),d0
   ```

### 13.2. Optimisations GPU

1. **Utiliser la RAM locale**: Minimiser les accès à la Main RAM.
2. **Batch les opérations**: Regrouper les opérations similaires.
3. **Éviter les branches conditionnelles**: Préférer les opérations arithmétiques.
4. **Utiliser le Blitter**: Pour les copies de mémoire.

### 13.3. Optimisations DSP

1. **Minimiser le code dans les ISR**: Garder les ISR courtes.
2. **Utiliser les bancs de registres**: Banc 0 pour les ISR, Banc 1 pour le code principal.
3. **Optimiser les algorithmes**: Utiliser des approximations pour les calculs complexes.

---

## 14. Gestion des Niveaux

### 14.1. Structure d'un Niveau

```assembly
; Level structure
    rsreset
LEVEL_SCROLL_SPEED    rs.w 1
LEVEL_LENGTH          rs.l 1       ; Longueur totale du niveau
LEVEL_BG_POINTER      rs.l 1       ; Pointeur vers le background
LEVEL_MUSIC_ID        rs.w 1
LEVEL_WAVE_COUNT       rs.w 1
LEVEL_WAVES_POINTER    rs.l 1       ; Pointeur vers les vagues
LEVEL_BONUS           rs.l 1       ; Score bonus pour fin de niveau
LEVEL_SIZE            rs.b 0
```

### 14.2. Données des Niveaux

```
Niveau 1:
- Vitesse de scrolling: lente
- Fond: espace étoile
- Musique: thème 1
- Vagues: 10 vagues de petits ennemis
- Boss: Boss 1

Niveau 2:
- Vitesse de scrolling: moyenne
- Fond: nébuleuse
- Musique: thème 2
- Vagues: ennemis variés
- Boss: Boss 2

; ... etc

Niveau 8:
- Vitesse de scrolling: très rapide
- Fond: station spatiale
- Musique: thème final
- Vagues: vagues intenses
- Boss: Boss final
```

### 14.3. Chargement d'un Niveau

```assembly
LoadLevel:
    ; Entrée: d0 = numéro du niveau
    
    ; Réinitialiser le jeu
    bsr     ResetPlayer
    bsr     ClearEnemies
    bsr     ClearBullets
    bsr     ClearParticles
    
    ; Charger les données du niveau
    move.w  d0,d1
    lsl.w   #2,d1               ; ×4 (taille d'un pointeur)
    move.l  LevelPointers(pc,d1.w),a0
    
    ; Initialiser les variables du niveau
    move.w  LEVEL_SCROLL_SPEED(a0),ScrollSpeed
    move.l  LEVEL_LENGTH(a0),ScrollMax
    move.l  LEVEL_BG_POINTER(a0),BackgroundPointer
    move.w  LEVEL_MUSIC_ID(a0),d1
    bsr     PlayMusic
    
    ; Initialiser les vagues
    move.l  LEVEL_WAVES_POINTER(a0),WavePointer
    move.w  LEVEL_WAVE_COUNT(a0),WaveCount
    clr.w   CurrentWave
    
    ; Réinitialiser le scrolling
    clr.l   ScrollY
    
    ; Changer l'état
    move.l  #GAME_STATE_PLAYING,GameState
    
    rts

LevelPointers:
    dc.l    Level1Data
    dc.l    Level2Data
    dc.l    Level3Data
    dc.l    Level4Data
    dc.l    Level5Data
    dc.l    Level6Data
    dc.l    Level7Data
    dc.l    Level8Data
```

---

## 15. Écrans Spéciaux

### 15.1. Écran Titre

```assembly
UpdateTitleScreen:
    ; Vérifier si Start est pressé
    btst    #JOY_START,Joy1Changed
    beq     TitleNoStart
    
    ; Démarrer le jeu
    clr.l   CurrentLevel
    bsr     LoadLevel
    
TitleNoStart:
    
    ; Animer le titre
    addq.w  #1,TitleAnimationTimer
    cmp.w   #60,TitleAnimationTimer
    blt     TitleAnimEnd
    clr.w   TitleAnimationTimer
    addq.w  #1,TitleFrame
    and.w   #7,TitleFrame       ; 0-7
    
TitleAnimEnd:
    rts
```

### 15.2. Écran Game Over

```assembly
UpdateGameOverScreen:
    ; Vérifier si Start est pressé
    btst    #JOY_START,Joy1Changed
    beq     GameOverNoStart
    
    ; Retour au titre
    move.l  #GAME_STATE_TITLE,GameState
    
GameOverNoStart:
    
    ; Animer le game over
    rts
```

### 15.3. Écran de Pause

```assembly
UpdatePauseScreen:
    ; Vérifier si Start est pressé
    btst    #JOY_START,Joy1Changed
    beq     PauseNoStart
    
    ; Reprendre le jeu
    move.l  #GAME_STATE_PLAYING,GameState
    
PauseNoStart:
    rts
```

---

## 16. Conclusion

Cette conception architecturale fournit une **base solide** pour le portage de Crisis Force vers Atari Jaguar. Elle couvre:

- ✅ Répartition des tâches entre les processeurs
- ✅ Structures de données complètes
- ✅ Communications inter-processeurs
- ✅ Système de scrolling
- ✅ Système de rendu
- ✅ Système de collision
- ✅ Système audio
- ✅ Gestion des niveaux
- ✅ Optimisations

### Prochaines Étapes

1. **Mettre à jour les fichiers source** avec les structures et fonctions définies
2. **Extraire les assets** de la ROM NES
3. **Implémenter le rendu de base** dans gpu.s
4. **Tester les communications** entre processeurs
5. **Implémenter la logique de jeu** progressive

---

**Document validé**: 2026-09-30  
**Prochaine révision**: Après implémentation de base
