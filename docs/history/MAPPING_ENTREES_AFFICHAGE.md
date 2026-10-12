# Crisis Force - Mapping Entrées et Affichage

**Phase 2: Conception**  
**Date**: 2026-09-30  
**Version**: 1.0

---

## 1. Mapping des Entrées

### 1.1. Correspondance NES → Jaguar

Le jeu original Crisis Force sur NES utilise les contrôles suivants:

| Action | Bouton NES | Bouton Jaguar | Registre | Bit |
|--------|------------|----------------|----------|-----|
| Haut | D-Pad Up | D-Pad Up | JOY1DATA | 0 |
| Bas | D-Pad Down | D-Pad Down | JOY1DATA | 1 |
| Gauche | D-Pad Left | D-Pad Left | JOY1DATA | 2 |
| Droite | D-Pad Right | D-Pad Right | JOY1DATA | 3 |
| Tir normal | B | Bouton B | JOY1DATA | 5 |
| Bombe | A | Bouton A | JOY1DATA | 4 |
| Start | Start | Bouton C | JOY1DATA | 6 |
| Select | Select | Bouton Pause | JOY1DATA | 7 |

### 1.2. Définitions des Constantes

```assembly
; Dans game.inc

; Boutons du joystick (correspondance hardware)
JOY_UP                equ 0
JOY_DOWN              equ 1
JOY_LEFT              equ 2
JOY_RIGHT             equ 3
JOY_A                equ 4
JOY_B                equ 5
JOY_C                equ 6
JOY_PAUSE             equ 7

; Actions du jeu (abstraction logique)
ACTION_MOVE_UP        equ $0001
ACTION_MOVE_DOWN      equ $0002
ACTION_MOVE_LEFT      equ $0004
ACTION_MOVE_RIGHT     equ $0008
ACTION_FIRE_NORMAL     equ $0010
ACTION_FIRE_SPECIAL    equ $0020
ACTION_PAUSE          equ $0040
ACTION_START          equ $0080

; Combinaisons d'actions
ACTION_MOVE_UP_LEFT    equ ACTION_MOVE_UP | ACTION_MOVE_LEFT
ACTION_MOVE_UP_RIGHT   equ ACTION_MOVE_UP | ACTION_MOVE_RIGHT
ACTION_MOVE_DOWN_LEFT  equ ACTION_MOVE_DOWN | ACTION_MOVE_LEFT
ACTION_MOVE_DOWN_RIGHT equ ACTION_MOVE_DOWN | ACTION_MOVE_RIGHT
```

### 1.3. Code de Lecture des Entrées

```assembly
; Dans main.s

; Variables pour les entrées
Joy1Current:       ds.l    1
Joy1Previous:      ds.l    1
Joy1Changed:       ds.l    1
PlayerActions:     ds.l    1       ; Actions actives
PlayerActionsNew:  ds.l    1       ; Nouvelles actions (appuyées ce frame)
PlayerActionsOld:  ds.l    1       ; Actions précédentes (relâchées ce frame)

ReadInput:
    ; Sauvegarder l'état précédent
    move.l  Joy1Current,Joy1Previous
    
    ; Lire le joystick 1 (32 bits)
    move.l  JOY1DATA,Joy1Current
    
    ; Calculer les changements (boutons pressés ce frame)
    move.l  Joy1Current,d0
    eor.l   Joy1Previous,d0
    move.l  d0,Joy1Changed
    
    ; Convertir les boutons hardware en actions logiques
    clr.l   d1                   ; PlayerActions
    clr.l   d2                   ; PlayerActionsNew
    
    ; Vérifier chaque bouton
    btst    #JOY_UP,Joy1Current
    beq     NoUp
    or.l    #ACTION_MOVE_UP,d1
    btst    #JOY_UP,Joy1Changed
    bne     UpNew
    or.l    #ACTION_MOVE_UP,d2
UpNew:
NoUp:
    
    btst    #JOY_DOWN,Joy1Current
    beq     NoDown
    or.l    #ACTION_MOVE_DOWN,d1
    btst    #JOY_DOWN,Joy1Changed
    bne     DownNew
    or.l    #ACTION_MOVE_DOWN,d2
DownNew:
NoDown:
    
    btst    #JOY_LEFT,Joy1Current
    beq     NoLeft
    or.l    #ACTION_MOVE_LEFT,d1
    btst    #JOY_LEFT,Joy1Changed
    bne     LeftNew
    or.l    #ACTION_MOVE_LEFT,d2
LeftNew:
NoLeft:
    
    btst    #JOY_RIGHT,Joy1Current
    beq     NoRight
    or.l    #ACTION_MOVE_RIGHT,d1
    btst    #JOY_RIGHT,Joy1Changed
    bne     RightNew
    or.l    #ACTION_MOVE_RIGHT,d2
RightNew:
NoRight:
    
    btst    #JOY_B,Joy1Current
    beq     NoFire
    or.l    #ACTION_FIRE_NORMAL,d1
    btst    #JOY_B,Joy1Changed
    bne     FireNew
    or.l    #ACTION_FIRE_NORMAL,d2
FireNew:
NoFire:
    
    btst    #JOY_A,Joy1Current
    beq     NoBomb
    or.l    #ACTION_FIRE_SPECIAL,d1
    btst    #JOY_A,Joy1Changed
    bne     BombNew
    or.l    #ACTION_FIRE_SPECIAL,d2
BombNew:
NoBomb:
    
    btst    #JOY_C,Joy1Current
    beq     NoStart
    or.l    #ACTION_START,d1
    btst    #JOY_C,Joy1Changed
    bne     StartNew
    or.l    #ACTION_START,d2
StartNew:
NoStart:
    
    btst    #JOY_PAUSE,Joy1Current
    beq     NoPause
    or.l    #ACTION_PAUSE,d1
    btst    #JOY_PAUSE,Joy1Changed
    bne     PauseNew
    or.l    #ACTION_PAUSE,d2
PauseNew:
NoPause:
    
    ; Sauvegarder les actions
    move.l  d1,PlayerActions
    move.l  d2,PlayerActionsNew
    
    ; Calculer les actions relâchées
    move.l  PlayerActions,d3
    eor.l   Joy1Previous,d3
    and.l   Joy1Previous,d3      ; Garder seulement les bits qui étaient à 1 avant
    move.l  d3,PlayerActionsOld
    
    rts
```

### 1.4. Gestion des Actions dans le Jeu

```assembly
; Dans UpdatePlayer (main.s)

UpdatePlayer:
    ; Vérifier les nouvelles actions
    move.l  PlayerActions,d0
    move.l  PlayerActionsNew,d1
    move.l  PlayerActionsOld,d2
    
    ; Mouvement
    btst    #ACTION_MOVE_UP,d0
    beq     NoMoveUp
    ; Déplacer vers le haut
    move.w  PlayerY,d3
    sub.w   #PLAYER_SPEED,d3
    cmp.w   #SCREEN_TOP,d3
    bge     SetPlayerY
    move.w  #SCREEN_TOP,d3
SetPlayerY:
    move.w  d3,PlayerY
NoMoveUp:
    
    btst    #ACTION_MOVE_DOWN,d0
    beq     NoMoveDown
    move.w  PlayerY,d3
    add.w   #PLAYER_SPEED,d3
    cmp.w   #SCREEN_BOTTOM,d3
    ble     SetPlayerY2
    move.w  #SCREEN_BOTTOM,d3
SetPlayerY2:
    move.w  d3,PlayerY
NoMoveDown:
    
    btst    #ACTION_MOVE_LEFT,d0
    beq     NoMoveLeft
    move.w  PlayerX,d3
    sub.w   #PLAYER_SPEED,d3
    cmp.w   #SCREEN_LEFT,d3
    bge     SetPlayerX
    move.w  #SCREEN_LEFT,d3
SetPlayerX:
    move.w  d3,PlayerX
NoMoveLeft:
    
    btst    #ACTION_MOVE_RIGHT,d0
    beq     NoMoveRight
    move.w  PlayerX,d3
    add.w   #PLAYER_SPEED,d3
    cmp.w   #SCREEN_RIGHT,d3
    ble     SetPlayerX2
    move.w  #SCREEN_RIGHT,d3
SetPlayerX2:
    move.w  d3,PlayerX
NoMoveRight:
    
    ; Tir
    btst    #ACTION_FIRE_NORMAL,d1
    beq     NoFireNormal
    ; Nouveau tir (appuyé ce frame)
    bsr     PlayerFireNormal
NoFireNormal:
    
    ; Tir spécial (bombe)
    btst    #ACTION_FIRE_SPECIAL,d1
    beq     NoFireSpecial
    ; Nouvelle bombe
    bsr     PlayerFireSpecial
NoFireSpecial:
    
    ; Pause
    btst    #ACTION_PAUSE,d1
    beq     NoPauseGame
    ; Basculer pause
    move.l  GameState,d3
    cmp.l   #GAME_STATE_PAUSED,d3
    beq     UnpauseGame
    move.l  #GAME_STATE_PAUSED,GameState
    bra     NoPauseGame
UnpauseGame:
    move.l  #GAME_STATE_PLAYING,GameState
NoPauseGame:
    
    rts
```

### 1.5. Configuration des Vitesses et Limites

```assembly
; Dans game.inc

; Vitesse du joueur (en pixels/frame)
PLAYER_SPEED          equ 4

; Limites de l'écran (pour le joueur)
SCREEN_LEFT           equ 16
SCREEN_RIGHT          equ 304      ; 320 - 16
SCREEN_TOP            equ 16
SCREEN_BOTTOM         equ 224      ; 240 - 16

; Taille du joueur
PLAYER_WIDTH          equ 16
PLAYER_HEIGHT         equ 16

; Délai entre les tirs (en frames)
PLAYER_FIRE_DELAY      equ 8
PLAYER_BOMB_DELAY      equ 60     ; 1 seconde à 60 fps

; Compteur de tir
PlayerFireTimer:      ds.w 1
PlayerBombTimer:      ds.w 1
```

### 1.6. Gestion du Tir

```assembly
; Dans main.s

PlayerFireNormal:
    ; Vérifier le délai de tir
    move.w  PlayerFireTimer,d0
    bne     FireOnCooldown
    
    ; Créer une nouvelle balle
    bsr     CreatePlayerBullet
    
    ; Réinitialiser le timer
    move.w  #PLAYER_FIRE_DELAY,PlayerFireTimer
    
FireOnCooldown:
    ; Décrémenter le timer
    subq.w  #1,PlayerFireTimer
    rts

PlayerFireSpecial:
    ; Vérifier le délai de bombe
    move.w  PlayerBombTimer,d0
    bne     BombOnCooldown
    
    ; Créer une explosion spéciale
    bsr     CreatePlayerBomb
    
    ; Réinitialiser le timer
    move.w  #PLAYER_BOMB_DELAY,PlayerBombTimer
    
BombOnCooldown:
    subq.w  #1,PlayerBombTimer
    rts
```

---

## 2. Mapping de l'Affichage

### 2.1. Résolution et Formats

| Aspect | NES | Jaguar | Adaptation |
|--------|-----|--------|------------|
| **Résolution** | 256×240 | 640×480 ou 320×240 | Mode 320×240 recommandé |
| **Format couleur** | Palette (25 couleurs/sprite) | RGB16 (5-6-5) | Conversion directe |
| **Profondeur** | 8 bits (indexé) | 16 bits (RGB) | Chaque pixel = 2 octets |
| **Sprites** | 8×8 ou 8×16 tiles | 16×16 ou 32×32 | Utiliser des sprites plus grands |
| **Background** | 256×240 | Jusqu'à 640×480 | Scaler ou adapter |

### 2.2. Configuration Vidéo

```assembly
; Dans jaguar.inc

; Modes vidéo
VMODE_320x240_RGB16    equ $00020001  ; 320×240, RGB 16-bit
VMODE_640x480_RGB16    equ $00020005  ; 640×480, RGB 16-bit

; Configuration recommandée pour Crisis Force
; On utilise 320×240 pour correspondre à la résolution NES originale

InitVideo:
    ; Mode vidéo: 320×240, RGB 16-bit
    move.l  #VMODE_320x240_RGB16,VMODE
    
    ; Début et fin de l'affichage horizontal
    move.l  #$00140001,HDB      ; Début à 20 (52 en décimal?)
    move.l  #$001E0001,HDE      ; Fin à 30 (78 en décimal?)
    
    ; Début et fin de l'affichage vertical
    move.l  #$00140001,VDB      ; Début à 20
    move.l  #$00FA0001,VDE      ; Fin à 250 (20+230)
    
    ; Couleur de fond (noir)
    move.l  #COLOR_BLACK,BG
    
    ; Configuration du framebuffer
    move.l  #FRAMEBUFFER_0,OLP
    
    rts
```

### 2.3. Conversion des Couleurs

#### Palette NES → RGB16

La NES utilise une palette fixe de 64 couleurs (54 couleurs réelles + 10 duplication).

**Format NES**:
- 6 bits par composante (R, G, B)
- Valeurs: 0x00 à 0x3F
- Emulation: 0x00=0, 0x01=85, 0x02=170, 0x03=255

**Format Jaguar RGB16**:
- R: 5 bits (0-31)
- G: 6 bits (0-63)
- B: 5 bits (0-31)
- Format: `0bRRRRRGGGGGGBBBBB`

#### Table de Conversion

```assembly
; Dans game.inc

; Macros pour créer une couleur RGB16
RGB16: MACRO
    dc.l    ((\3 & $1F) << 11) | ((\2 & $3F) << 5) | (\1 & $1F)
    ENDM

; Palette NES standard (approximée)
; Basée sur la palette du NES Classic
NES_PALETTE_00: equ RGB16(26,26,26)    ; Gris foncé
NES_PALETTE_01: equ RGB16(0,10,30)     ; Bleu foncé
NES_PALETTE_02: equ RGB16(20,4,36)     ; Violet
NES_PALETTE_03: equ RGB16(36,0,36)     ; Violet-rouge

NES_PALETTE_04: equ RGB16(36,18,8)     ; Rouge-brun
NES_PALETTE_05: equ RGB16(36,10,0)     ; Rouge
NES_PALETTE_06: equ RGB16(32,6,0)      ; Rouge foncé
NES_PALETTE_07: equ RGB16(0,0,0)       ; Noir

NES_PALETTE_08: equ RGB16(36,32,24)    ; Orange
NES_PALETTE_09: equ RGB16(36,28,12)    ; Orange-jaune
NES_PALETTE_0A: equ RGB16(36,28,0)     ; Jaune-rouge
NES_PALETTE_0B: equ RGB16(32,24,0)     ; Jaune-brun

NES_PALETTE_0C: equ RGB16(36,28,20)    ; Jaune-pâle
NES_PALETTE_0D: equ RGB16(28,28,0)     ; Jaune
NES_PALETTE_0E: equ RGB16(16,28,0)     ; Vert-jaune
NES_PALETTE_0F: equ RGB16(0,28,0)      ; Vert

; Etc...
```

### 2.4. Adaptation des Graphismes

#### Échelle des Sprites

Le jeu original utilise des sprites de 8×8 ou 16×16 pixels. Sur Jaguar, nous pouvons utiliser des sprites plus grands.

**Options**:
1. **1:1** - Conserver la taille originale (8×8, 16×16)
   - Avantages: Plus fidèle à l'original
   - Inconvénients: Sprites très petits sur l'écran
   
2. **2:1** - Doubler la taille (16×16, 32×32)
   - Avantages: Meilleure visibilité
   - Inconvénients: Moins fidèle, besoin de scaler les graphismes
   
3. **Personnalisé** - Utiliser des sprites de tailles variées
   - Avantages: Meilleure adaptation à l'écran
   - Inconvénients: Plus complexe à implémenter

**Choix**: Option 2 (2:1) recommandée pour Crisis Force

#### Conversion des Sprites

```python
# Dans extract_assets.py

def scale_sprite(sprite_img, scale=2):
    """Aggrandit un sprite par un facteur scale"""
    width, height = sprite_img.size
    scaled_img = sprite_img.resize((width * scale, height * scale), Image.NEAREST)
    return scaled_img
```

#### Format des Données Graphiques

Sur Jaguar, les graphismes sont stockés en **RGB16** (2 octets par pixel).

```assembly
; Exemple: Sprite du joueur (32×32, RGB16)
PlayerSprite:
    dc.w    $RRRRRGGGGGGBBBBB  ; Pixel (0,0)
    dc.w    $RRRRRGGGGGGBBBBB  ; Pixel (1,0)
    ; ... 32×32 = 1024 pixels
    dc.w    $RRRRRGGGGGGBBBBB  ; Pixel (31,31)
```

### 2.5. Organisation du Framebuffer

```
Framebuffer 320×240 RGB16:
- Largeur: 320 pixels
- Hauteur: 240 pixels
- Taille: 320 × 240 × 2 = 153,600 octets (~150 KB)
- Adresse: $840000 (Framebuffer 0) ou $880000 (Framebuffer 1)

Calcul de l'adresse d'un pixel:
FB_Address = Base + (Y × 320 × 2) + (X × 2)
           = Base + (Y × 640) + (X × 2)
```

### 2.6. Double Buffering

Pour éviter les déchirures, nous utilisons le **double buffering**.

```assembly
; Variables de double buffering
CurrentFB:    ds.l 1   ; Framebuffer actuel (0 ou 1)
NextFB:       ds.l 1   ; Framebuffer suivant

; Adresses des framebuffers
FB0:          equ $840000
FB1:          equ $880000

; Initialisation
InitDoubleBuffering:
    clr.l   CurrentFB
    move.l  #1,NextFB
    move.l  #FB0,OLP      ; Pointer vers FB0
    rts

; Basculer les framebuffers
SwapBuffers:
    move.l  NextFB,d0
    eor.l   #1,d0        ; Basculer entre 0 et 1
    move.l  d0,NextFB
    
    ; Mettre à jour OLP pour pointer vers le nouveau framebuffer
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

## 3. Mapping des Ennemis

### 3.1. Types d'Ennemis Crisis Force

| ID | Nom | Description | Vitesse | Tir | Points |
|----|-----|-------------|--------|-----|--------|
| 0 | Small Fighter | Petit vaisseau rapide | Moyenne | Non | 100 |
| 1 | Medium Fighter | Vaisseau moyen | Moyenne | Oui | 200 |
| 2 | Large Fighter | Gros vaisseau lent | Lente | Oui | 500 |
| 3 | Kamikaze | Charge le joueur | Rapide | Non | 300 |
| 4 | Turret | Tourelle fixe | Aucune | Oui | 200 |
| 5 | Moving Turret | Tourelle mobile | Lente | Oui | 300 |
| 6 | Dodger | Évite les balles | Rapide | Oui | 400 |
| 7 | Formation Leader | Chef de formation | Moyenne | Oui | 500 |
| 8 | Boss 1 | Boss niveau 1 | Variable | Oui | 1000 |
| 9 | Boss 2 | Boss niveau 2 | Variable | Oui | 2000 |
| ... | ... | ... | ... | ... | ... |

### 3.2. Propriétés des Ennemis

```assembly
; Dans game.inc

; Vitesse des ennemis (en pixels/frame)
ENEMY_SPEED_SLOW      equ 1
ENEMY_SPEED_MEDIUM    equ 2
ENEMY_SPEED_FAST      equ 4
ENEMY_SPEED_VERY_FAST equ 8

; Délai de tir (en frames)
ENEMY_FIRE_DELAY_SLOW    equ 60    ; 1 seconde
ENEMY_FIRE_DELAY_MEDIUM  equ 30    ; 0.5 seconde
ENEMY_FIRE_DELAY_FAST    equ 15    ; 0.25 seconde

; Points par ennemi
ENEMY_SCORE_SMALL       equ 100
ENEMY_SCORE_MEDIUM      equ 200
ENEMY_SCORE_LARGE       equ 500
ENEMY_SCORE_BOSS        equ 1000

; Taille des hitboxes
ENEMY_HITBOX_SMALL      equ 8
ENEMY_HITBOX_MEDIUM     equ 16
ENEMY_HITBOX_LARGE      equ 24
ENEMY_HITBOX_BOSS       equ 32
```

### 3.3. Données des Ennemis

```assembly
; Tableau des propriétés des ennemis
EnemyProperties:
    ; Small Fighter
    dc.w    ENEMY_SPEED_MEDIUM
    dc.w    0                   ; Pas de tir
    dc.w    ENEMY_SCORE_SMALL
    dc.w    ENEMY_HITBOX_SMALL
    dc.w    1                   ; Vie
    
    ; Medium Fighter
    dc.w    ENEMY_SPEED_MEDIUM
    dc.w    ENEMY_FIRE_DELAY_MEDIUM
    dc.w    ENEMY_SCORE_MEDIUM
    dc.w    ENEMY_HITBOX_MEDIUM
    dc.w    2                   ; Vies
    
    ; Large Fighter
    dc.w    ENEMY_SPEED_SLOW
    dc.w    ENEMY_FIRE_DELAY_SLOW
    dc.w    ENEMY_SCORE_LARGE
    dc.w    ENEMY_HITBOX_LARGE
    dc.w    4                   ; Vies
    
    ; Kamikaze
    dc.w    ENEMY_SPEED_VERY_FAST
    dc.w    0                   ; Pas de tir
    dc.w    ENEMY_SCORE_MEDIUM
    dc.w    ENEMY_HITBOX_MEDIUM
    dc.w    1                   ; Vie
    
    ; ... etc
```

---

## 4. Mapping des Power-ups

### 4.1. Types de Power-ups

| ID | Nom | Description | Durée |
|----|-----|-------------|-------|
| 0 | Speed Up | Augmente la vitesse du joueur | Permanente |
| 1 | Spread Shot | Tirs en éventail (3 balles) | Permanente |
| 2 | Laser | Tir laser long | Permanente |
| 3 | Missile | Missiles guidés | Permanente |
| 4 | Shield | Bouclier temporaire | 10 secondes |
| 5 | 1UP | Vie supplémentaire | Permanente |

### 4.2. Effets des Power-ups

```assembly
; Dans game.inc

; Types de power-ups
POWERUP_TYPE_SPEED     equ 0
POWERUP_TYPE_SPREAD    equ 1
POWERUP_TYPE_LASER     equ 2
POWERUP_TYPE_MISSILE   equ 3
POWERUP_TYPE_SHIELD    equ 4
POWERUP_TYPE_1UP       equ 5

; États du joueur (power-ups actifs)
PLAYER_HAS_SPEED_UP    equ $0001
PLAYER_HAS_SPREAD      equ $0002
PLAYER_HAS_LASER       equ $0004
PLAYER_HAS_MISSILE     equ $0008
PLAYER_HAS_SHIELD      equ $0010

PlayerPowerups: ds.w 1
PlayerShieldTimer: ds.w 1

; Vitesse avec Speed Up
PLAYER_SPEED_NORMAL    equ 4
PLAYER_SPEED_UPGRADED  equ 6

; Délai de tir avec différents power-ups
PLAYER_FIRE_DELAY_NORMAL    equ 8
PLAYER_FIRE_DELAY_SPREAD    equ 12
PLAYER_FIRE_DELAY_LASER     equ 20
PLAYER_FIRE_DELAY_MISSILE   equ 30
```

### 4.3. Application des Power-ups

```assembly
; Dans main.s

ApplyPowerUp:
    ; Entrée: d0 = type de power-up
    cmp.w   #POWERUP_TYPE_SPEED,d0
    beq     PowerUpSpeed
    cmp.w   #POWERUP_TYPE_SPREAD,d0
    beq     PowerUpSpread
    cmp.w   #POWERUP_TYPE_LASER,d0
    beq     PowerUpLaser
    cmp.w   #POWERUP_TYPE_MISSILE,d0
    beq     PowerUpMissile
    cmp.w   #POWERUP_TYPE_SHIELD,d0
    beq     PowerUpShield
    cmp.w   #POWERUP_TYPE_1UP,d0
    beq     PowerUp1UP
    rts

PowerUpSpeed:
    or.w    #PLAYER_HAS_SPEED_UP,PlayerPowerups
    move.w  #PLAYER_SPEED_UPGRADED,PLAYER_SPEED
    rts

PowerUpSpread:
    or.w    #PLAYER_HAS_SPREAD,PlayerPowerups
    move.w  #PLAYER_FIRE_DELAY_SPREAD,PLAYER_FIRE_DELAY
    rts

PowerUpLaser:
    or.w    #PLAYER_HAS_LASER,PlayerPowerups
    move.w  #PLAYER_FIRE_DELAY_LASER,PLAYER_FIRE_DELAY
    rts

PowerUpMissile:
    or.w    #PLAYER_HAS_MISSILE,PlayerPowerups
    move.w  #PLAYER_FIRE_DELAY_MISSILE,PLAYER_FIRE_DELAY
    rts

PowerUpShield:
    or.w    #PLAYER_HAS_SHIELD,PlayerPowerups
    move.w  #60*10,PlayerShieldTimer  ; 10 secondes à 60 fps
    rts

PowerUp1UP:
    addq.w  #1,Lives
    rts
```

### 4.4. Mise à jour des Power-ups

```assembly
UpdatePowerUps:
    ; Vérifier le bouclier
    tst.w   PlayerShieldTimer
    beq     NoShieldUpdate
    subq.w  #1,PlayerShieldTimer
    bne     NoShieldUpdate
    
    ; Bouclier expiré
    and.w   #~PLAYER_HAS_SHIELD,PlayerPowerups
    
NoShieldUpdate:
    rts
```

---

## 5. Mapping des Balles

### 5.1. Types de Balles

| ID | Nom | Propriétaire | Dégâts | Vitesse | Apparence |
|----|-----|--------------|--------|--------|-----------|
| 0 | Normal | Joueur | 1 | Rapide | Petit carré |
| 1 | Spread | Joueur | 1 | Rapide | Petit carré |
| 2 | Laser | Joueur | 1 | Très rapide | Ligne longue |
| 3 | Missile | Joueur | 2 | Moyenne | Missile |
| 4 | Enemy A | Ennemi | 1 | Moyenne | Petit carré |
| 5 | Enemy B | Ennemi | 2 | Rapide | Gros carré |
| 6 | Boss | Boss | 3 | Variable | Spécial |

### 5.2. Propriétés des Balles

```assembly
; Dans game.inc

; Types de balles
BULLET_TYPE_PLAYER_NORMAL   equ 0
BULLET_TYPE_PLAYER_SPREAD   equ 1
BULLET_TYPE_PLAYER_LASER    equ 2
BULLET_TYPE_PLAYER_MISSILE  equ 3
BULLET_TYPE_ENEMY_A         equ 4
BULLET_TYPE_ENEMY_B         equ 5
BULLET_TYPE_BOSS            equ 6

; Propriétés des balles
BULLET_DAMAGE_PLAYER        equ 1
BULLET_DAMAGE_ENEMY_A       equ 1
BULLET_DAMAGE_ENEMY_B       equ 2
BULLET_DAMAGE_BOSS          equ 3

; Vitesse des balles
BULLET_SPEED_PLAYER        equ 8
BULLET_SPEED_ENEMY_A       equ 4
BULLET_SPEED_ENEMY_B       equ 6
BULLET_SPEED_BOSS          equ 5

; Taille des balles
BULLET_SIZE_PLAYER         equ 4
BULLET_SIZE_ENEMY_A        equ 4
BULLET_SIZE_ENEMY_B        equ 6
BULLET_SIZE_BOSS           equ 8
```

### 5.3. Création de Balles

```assembly
; Dans main.s

CreatePlayerBullet:
    ; Trouver un slot de balle libre
    bsr     GetFreeBullet
    tst.w   d0
    bmi     NoFreeBulletSlot
    
    ; Initialiser la balle
    move.l  #BulletPool,a0
    lsl.w   #BULLET_SIZE_Shift,d0  ; Calculer l'offset
    add.l   d0,a0
    
    ; Type de balle (selon le power-up)
    move.l  PlayerPowerups,d1
    and.l   #PLAYER_HAS_SPREAD,d1
    bne     CreateSpreadBullet
    and.l   #PLAYER_HAS_LASER,d1
    bne     CreateLaserBullet
    and.l   #PLAYER_HAS_MISSILE,d1
    bne     CreateMissileBullet
    
    ; Balle normale
    move.w  #BULLET_TYPE_PLAYER_NORMAL,BULLET_TYPE(a0)
    move.w  #BULLET_DAMAGE_PLAYER,BULLET_DAMAGE(a0)
    move.w  #BULLET_SPEED_PLAYER,BULLET_VY(a0)
    move.w  #BULLET_SIZE_PLAYER,BULLET_SIZE(a0)
    bra     SetBulletPosition
    
CreateSpreadBullet:
    move.w  #BULLET_TYPE_PLAYER_SPREAD,BULLET_TYPE(a0)
    move.w  #BULLET_DAMAGE_PLAYER,BULLET_DAMAGE(a0)
    move.w  #BULLET_SPEED_PLAYER,BULLET_VY(a0)
    move.w  #BULLET_SIZE_PLAYER,BULLET_SIZE(a0)
    bra     SetBulletPosition
    
CreateLaserBullet:
    move.w  #BULLET_TYPE_PLAYER_LASER,BULLET_TYPE(a0)
    move.w  #BULLET_DAMAGE_PLAYER,BULLET_DAMAGE(a0)
    move.w  #BULLET_SPEED_PLAYER*2,BULLET_VY(a0)  ; Plus rapide
    move.w  #BULLET_SIZE_PLAYER*2,BULLET_SIZE(a0)  ; Plus long
    bra     SetBulletPosition
    
CreateMissileBullet:
    move.w  #BULLET_TYPE_PLAYER_MISSILE,BULLET_TYPE(a0)
    move.w  #BULLET_DAMAGE_PLAYER*2,BULLET_DAMAGE(a0)
    move.w  #BULLET_SPEED_PLAYER-2,BULLET_VY(a0)  ; Plus lent
    move.w  #BULLET_SIZE_PLAYER,BULLET_SIZE(a0)
    
SetBulletPosition:
    ; Position initiale (au-dessus du joueur)
    move.w  PlayerX,d1
    add.w   #PLAYER_WIDTH/2,d1
    sub.w   #BULLET_SIZE/2,d1
    move.w  d1,BULLET_X(a0)
    
    move.w  PlayerY,d1
    sub.w   #BULLET_SIZE,d1      ; Commencer au-dessus du joueur
    move.w  d1,BULLET_Y(a0)
    
    ; Activer la balle
    move.w  #1,BULLET_ACTIVE(a0)
    
NoFreeBulletSlot:
    rts
```

---

## 6. Mapping des Sons

### 6.1. Liste des Effets Sonores

| ID | Nom | Description |
|----|-----|-------------|
| 0 | Player Fire | Tir normal du joueur |
| 1 | Player Bomb | Bombe spéciale |
| 2 | Enemy Fire | Tir ennemi |
| 3 | Explosion Small | Explosion petit ennemi |
| 4 | Explosion Medium | Explosion ennemi moyen |
| 5 | Explosion Large | Explosion gros ennemi |
| 6 | Player Hit | Joueur touché |
| 7 | Player Die | Joueur meurt |
| 8 | PowerUp | Power-up collecté |
| 9 | Boss Hit | Boss touché |
| 10 | Boss Die | Boss meurt |
| 11 | Level Start | Début de niveau |
| 12 | Level Clear | Niveau terminé |
| 13 | Game Over | Game over |
| 14 | Pause | Pause |
| 15 | Unpause | Reprise |

### 6.2. Définitions des Sons

```assembly
; Dans game.inc

; Types de SFX
SFX_PLAYER_FIRE      equ 0
SFX_PLAYER_BOMB      equ 1
SFX_ENEMY_FIRE      equ 2
SFX_EXPLOSION_SMALL equ 3
SFX_EXPLOSION_MEDIUM equ 4
SFX_EXPLOSION_LARGE equ 5
SFX_PLAYER_HIT      equ 6
SFX_PLAYER_DIE      equ 7
SFX_POWERUP         equ 8
SFX_BOSS_HIT        equ 9
SFX_BOSS_DIE        equ 10
SFX_LEVEL_START     equ 11
SFX_LEVEL_CLEAR     equ 12
SFX_GAME_OVER       equ 13
SFX_PAUSE           equ 14
SFX_UNPAUSE         equ 15

; Volumes des SFX
SFX_VOLUME_DEFAULT   equ 64
SFX_VOLUME_EXPLOSION equ 96
SFX_VOLUME_PLAYER    equ 80
SFX_VOLUME_BOSS      equ 112
```

### 6.3. Lecture des SFX

```assembly
; Dans main.s

PlaySFX:
    ; Entrée: d0 = ID du SFX, d1 = volume (optionnel)
    cmp.w   #SFX_PLAYER_FIRE,d0
    beq     PlayPlayerFire
    cmp.w   #SFX_PLAYER_BOMB,d0
    beq     PlayPlayerBomb
    ; ... autres SFX
    
    ; Volume par défaut
    move.w  #SFX_VOLUME_DEFAULT,d1
    
    ; Envoyer au DSP
    move.w  d0,d2               ; ID
    move.w  d1,d3               ; Volume
    move.w  #64,d4              ; Pan centre
    bsr     SendDSPCommand
    rts

PlayPlayerFire:
    move.w  #SFX_VOLUME_PLAYER,d1
    bra     PlaySFXGeneric

PlayPlayerBomb:
    move.w  #SFX_VOLUME_PLAYER,d1
    bra     PlaySFXGeneric

PlayExplosionSmall:
    move.w  #SFX_VOLUME_EXPLOSION,d1
    bra     PlaySFXGeneric

; ... etc

PlaySFXGeneric:
    move.w  d0,d2
    move.w  d1,d3
    move.w  #64,d4
    bsr     SendDSPCommand
    rts
```

---

## 7. Résumé

Ce document définit le **mapping complet** entre les fonctionnalités du jeu original Crisis Force (NES) et leur implémentation sur Atari Jaguar, incluant:

- ✅ **Entrées**: Mapping des boutons NES → Jaguar
- ✅ **Affichage**: Résolution, format couleur, framebuffer
- ✅ **Ennemis**: Types, propriétés, données
- ✅ **Power-ups**: Types, effets, durée
- ✅ **Balles**: Types, propriétés, création
- ✅ **Sons**: Liste des SFX, volumes

### Prochaines Étapes

1. **Mettre à jour `game.inc`** avec toutes les constantes définies
2. **Mettre à jour `main.s`** avec la gestion des entrées
3. **Mettre à jour `gpu.s`** avec le rendu des sprites
4. **Mettre à jour `dsp.s`** avec les SFX
5. **Extraire les assets** avec les bonnes tailles et couleurs

---

**Document validé**: 2026-09-30  
**Prochaine révision**: Après implémentation de base
