# Crisis Force - Système de Scrolling

**Phase 2: Conception**  
**Date**: 2026-09-30  
**Version**: 1.0

---

## 1. Introduction

Le **scrolling** est une fonctionnalité essentielle des jeux de type shoot 'em up comme Crisis Force. Sur NES, le scrolling était géré matériellement par le PPU (Picture Processing Unit). Sur Atari Jaguar, nous devons implémenter le scrolling **logiciellement** en utilisant le GPU et le Blitter.

Ce document décrit le système de scrolling vertical utilisé dans Crisis Force, son implémentation sur Jaguar, et les optimisations possibles.

---

## 2. Analyse du Scrolling Original (NES)

### 2.1. Caractéristiques du Scrolling NES

- **Direction**: Vertical uniquement (pas de scrolling horizontal)
- **Vitesse**: Constante par niveau, peut varier entre les niveaux
- **Background**: Une seule couche (pas de parallax scrolling)
- **Taille**: 256×240 pixels
- **Pattern**: Le background se répète ou utilise des tiles spécifiques
- **Sprites**: Les sprites ennemis apparaissent depuis le haut de l'écran

### 2.2. Mécanisme sur NES

Le PPU de la NES gère le scrolling via:
1. **Registres de scrolling**: `$2005` (PPUSCROLL)
2. **Registres de position**: `$2000` (PPUCTRL) et `$2005`
3. **Tiling**: Le background est construit à partir de tiles 8×8
4. **Attribute tables**: Pour les couleurs et palettes

### 2.3. Vitesse de Scrolling par Niveau (Crisis Force)

| Niveau | Vitesse | Durée (estimée) | Distance |
|--------|---------|----------------|----------|
| 1 | Lente (1) | ~30 secondes | 5000 |
| 2 | Moyenne (2) | ~30 secondes | 6000 |
| 3 | Moyenne (2) | ~30 secondes | 7000 |
| 4 | Rapide (3) | ~30 secondes | 8000 |
| 5 | Rapide (3) | ~30 secondes | 9000 |
| 6 | Très rapide (4) | ~30 secondes | 10000 |
| 7 | Très rapide (4) | ~30 secondes | 11000 |
| 8 | Max (5) | ~45 secondes | 12000 |

*Note: Les vitesses sont en pixels/frame, et les distances en pixels totaux.*

---

## 3. Implémentation sur Atari Jaguar

### 3.1. Concept de Base

Sur Jaguar, nous devons:
1. **Stocker le background** en mémoire (RAM ou ROM)
2. **Calculer l'offset** basé sur la position de scrolling
3. **Copier les pixels** du background vers le framebuffer avec l'offset
4. **Gérer les bords** (quand le scrolling dépasse la taille du background)

### 3.2. Structure des Données

#### Background Data

Le background est stocké sous forme de **tilemap** ou de **bitmap** direct.

**Option 1: Tilemap (Recommandée)**
```
- Chaque tile: 8×8, 16×16, ou 32×32 pixels
- Avantages: Économique en mémoire, flexible
- Inconvénients: Plus complexe à implémenter
```

**Option 2: Bitmap Direct**
```
- Image complète en RGB16
- Avantages: Simple à copier avec le Blitter
- Inconvénients: Utilise beaucoup de mémoire
```

**Choix**: Option 1 (Tilemap) pour Crisis Force, car:
- Le jeu original utilise des tiles
- Économise de la mémoire
- Permet des backgrounds plus grands que l'écran

#### Tile Format

```assembly
; Chaque tile = 16×16 pixels, RGB16 (2 octets/pixel)
; Taille d'une tile: 16×16×2 = 512 octets

; Structure d'une tile
    rsreset
TILE_WIDTH           rs.w 1       ; Largeur (16)
TILE_HEIGHT          rs.w 1       ; Hauteur (16)
TILE_DATA            rs.b 512     ; Données RGB16
TILE_SIZE            rs.b 0
```

#### Tilemap Format

```assembly
; Tilemap: tableau 2D d'index de tiles
; Chaque entrée = index de la tile à afficher

; Exemple: Tilemap de 40×30 tiles (640×480 pixels)
Tilemap:
    dc.w    0, 0, 0, 0, ...     ; Ligne 0
    dc.w    0, 0, 0, 0, ...     ; Ligne 1
    ; ...
    dc.w    1, 1, 1, 1, ...     ; Ligne 29

; Taille: 40×30×2 = 2400 octets
```

### 3.3. Variables de Scrolling

```assembly
; Dans game.inc

; Position de scrolling (16.16 fixe pour la précision)
ScrollX:           ds.l 1       ; Position X (non utilisé pour Crisis Force)
ScrollY:           ds.l 1       ; Position Y

; Vitesse de scrolling
ScrollSpeed:       ds.w 1       ; Vitesse actuelle (pixels/frame)
ScrollBaseSpeed:   ds.w 1       ; Vitesse de base pour le niveau

; Limites de scrolling
ScrollMin:         ds.l 1       ; Position minimale (0)
ScrollMax:         ds.l 1       ; Position maximale (fin du niveau)

; Tilemap
TilemapPointer:    ds.l 1       ; Pointeur vers le tilemap
TilemapWidth:     ds.w 1       ; Largeur du tilemap en tiles
TilemapHeight:     ds.w 1       ; Hauteur du tilemap en tiles
TileWidth:         ds.w 1       ; Largeur d'une tile en pixels
TileHeight:        ds.w 1       ; Hauteur d'une tile en pixels

; Tiles
TilesPointer:      ds.l 1       ; Pointeur vers les données des tiles
NumTiles:          ds.w 1       ; Nombre de tiles différentes
```

### 3.4. Initialisation du Scrolling

```assembly
; Dans main.s

InitScrolling:
    ; Réinitialiser ScrollY
    clr.l   ScrollY
    
    ; Définir ScrollMax (longueur du niveau)
    move.l  CurrentLevel,d0
    lsl.l   #2,d0               ; ×4 (taille d'un pointeur)
    move.l  LevelPointers(pc,d0.l),a0
    move.l  LEVEL_LENGTH(a0),ScrollMax
    
    ; Définir ScrollSpeed
    move.w  LEVEL_SCROLL_SPEED(a0),ScrollBaseSpeed
    move.w  ScrollBaseSpeed,ScrollSpeed
    
    ; Définir les pointeurs du tilemap
    move.l  LEVEL_BG_POINTER(a0),TilemapPointer
    
    ; Définir les dimensions du tilemap
    ; (À adapter selon le niveau)
    move.w  #40,TilemapWidth    ; 40 tiles de large
    move.w  #60,TilemapHeight   ; 60 tiles de haut
    move.w  #16,TileWidth       ; 16 pixels de large
    move.w  #16,TileHeight      ; 16 pixels de haut
    
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

## 4. Mise à jour du Scrolling

### 4.1. Logique de Scrolling

Le scrolling est mis à jour chaque frame:

```assembly
; Dans main.s

UpdateScrolling:
    ; Incrémenter ScrollY
    move.l  ScrollY,d0
    move.w  ScrollSpeed,d1
    ext.l   d1
    add.l   d1,d0
    move.l  d0,ScrollY
    
    ; Vérifier les limites
    cmp.l   ScrollMax,d0
    ble     ScrollOK
    
    ; Fin du niveau atteinte
    move.l  ScrollMax,ScrollY
    
    ; Déclencher la fin du niveau
    bsr     TriggerLevelClear
    
ScrollOK:
    ; Copier ScrollY vers la variable partagée pour le GPU
    ; (Utiliser move.w pour les 16 bits supérieurs)
    move.w  d0,SharedScrollY+2  ; Partie haute
    move.w  d0,SharedScrollY    ; Partie basse
    
    rts

TriggerLevelClear:
    ; Arrêter le scrolling
    clr.w   ScrollSpeed
    
    ; Changer l'état du jeu
    move.l  #GAME_STATE_LEVELCLEAR,GameState
    
    ; Jouer le son de fin de niveau
    move.l  #SFX_LEVEL_CLEAR,d0
    move.l  #SFX_VOLUME_DEFAULT,d1
    bsr     PlaySFX
    
    rts
```

### 4.2. Rendu du Background avec Scrolling

Le GPU est responsable du rendu du background avec le bon offset.

#### Algorithme de Rendu

```assembly
; Dans gpu.s

GPURenderBackground:
    ; Lire ScrollY (16.16 fixe)
    movei   #SharedScrollY,r1
    loadw   (r1),r2               ; Partie basse (Y.fraction)
    loadw   2(r1),r3              ; Partie haute (Y.entier)
    
    ; Calculer l'offset en pixels
    ; ScrollY pixels = (ScrollY >> 16) + (ScrollY & $FFFF) / 65536
    ; Mais on peut simplifier: on utilise seulement la partie entière
    ; et on ignore la fraction pour le moment
    move    r3,r4                ; Y entier
    
    ; Calculer la ligne de départ dans le tilemap
    ; offset_tiles_y = Y / TileHeight
    move    r4,r5
    movei   #TileHeight,r6
    div     r6,r5                ; r5 = offset_tiles_y
    
    ; Calculer le reste (offset en pixels)
    move    r4,r7
    movei   #TileHeight,r8
    mod     r8,r7                ; r7 = offset_pixels
    
    ; Adresse source dans le framebuffer
    movei   #CURRENT_FB,r9
    
    ; Dessiner ligne par ligne
    movei   #SCREEN_HEIGHT,r10   ; 240 lignes
    movei   #0,r11               ; Compteur de lignes
    
RenderBGLoop:
    ; Calculer l'offset dans le tilemap pour cette ligne
    ; tile_y = offset_tiles_y + (r11 + offset_pixels) / TileHeight
    move    r11,r12
    add     r7,r12
    movei   #TileHeight,r13
    div     r13,r12             ; r12 = offset additionnel en tiles
    add     r5,r12              ; r12 = tile_y totale
    
    ; Vérifier si on dépasse le tilemap
    move    r12,r14
    cmp     TilemapHeight,r14
    bge     RenderBGEnd         ; Si oui, quitter
    
    ; Calculer l'adresse de la ligne dans le tilemap
    ; Pour chaque ligne de l'écran, on doit dessiner plusieurs tiles
    movei   #0,r15               ; Compteur de tiles en X
    
RenderBGRowLoop:
    ; Calculer l'index du tile
    ; tile_index = tile_y * TilemapWidth + tile_x
    move    r12,r16
    movei   #TilemapWidth,r17
    mul     r17,r16
    add     r15,r16             ; r16 = index du tile
    
    ; Lire l'index de la tile depuis le tilemap
    movei   #TilemapPointer,r18
    loadw   (r18,r16*2),r19      ; Index de la tile (16-bit)
    
    ; Calculer l'adresse de la tile
    movei   #TilesPointer,r20
    move    r19,r21
    movei   #TILE_SIZE,r22      ; 512 octets par tile
    mul     r22,r21
    add     r21,r20             ; r20 = adresse de la tile
    
    ; Calculer la ligne dans la tile
    ; line_in_tile = (r11 + offset_pixels) % TileHeight
    move    r11,r23
    add     r7,r23
    mod     r13,r23             ; r23 = ligne dans la tile
    
    ; Calculer l'adresse de la ligne dans la tile
    ; tile_line_address = tile_address + (line_in_tile * TileWidth * 2)
    move    r23,r24
    movei   #TileWidth,r25
    mul     r25,r24
    shl     #1,r24               ; ×2 pour RGB16
    add     r24,r20             ; r20 = adresse de la ligne dans la tile
    
    ; Calculer l'adresse de destination dans le framebuffer
    ; fb_address = FB + (r11 * SCREEN_WIDTH * 2) + (r15 * TileWidth * 2)
    move    r11,r26
    movei   #SCREEN_WIDTH,r27
    mul     r27,r26
    shl     #1,r26
    move    r15,r28
    movei   #TileWidth,r29
    mul     r29,r28
    shl     #1,r28
    add     r28,r26
    add     r9,r26              ; r26 = adresse destination
    
    ; Copier la ligne (TileWidth pixels = TileWidth * 2 octets)
    movei   #TileWidth*2,r30    ; Taille en octets
    
    ; Utiliser le Blitter pour copier
    move    r20,BLITSRC
    move    r26,BLITDST
    move    r30,BLITCOUNT
    movei   #$200000,r31        ; Commande: copie simple
    store   r31,BLITCTRL
    
    ; Attendre que le Blitter soit prêt
WaitBlitter:
    load    (BLITSTAT),r32
    and     #$1,r32
    bne     WaitBlitter
    
    ; Passer à la tile suivante
    add     #1,r15
    movei   #SCREEN_WIDTH,r33
    movei   #TileWidth,r34
    div     r34,r33             ; Nombre de tiles par ligne
    cmp     r33,r15
    blt     RenderBGRowLoop
    
    ; Passer à la ligne suivante
    add     #1,r11
    cmp     r10,r11
    blt     RenderBGLoop
    
RenderBGEnd:
    rts
```

### 4.3. Optimisation du Rendu

Le code ci-dessus est fonctionnel mais peut être optimisé.

#### Optimisation 1: Cache des Tiles

Plutôt que de lire chaque tile depuis la Main RAM à chaque frame, nous pouvons les **cacher dans la RAM GPU**.

```assembly
; Dans InitGPU:
CacheBackgroundTiles:
    ; Copier les tiles du background dans la RAM GPU
    movei   #TilesPointer,r1
    movei   #$F05000,r2       ; Adresse de cache dans GPU RAM
    movei   #NumTiles,r3
    
CacheLoop:
    ; Copier une tile (512 octets)
    movei   #TILE_SIZE/4,r4   ; 128 longs
    
CopyTileLoop:
    load    (r1),r5
    store   r5,(r2)
    add     #4,r1
    add     #4,r2
    sub     #1,r4
    bne     CopyTileLoop
    
    sub     #1,r3
    bne     CacheLoop
    
    rts
```

#### Optimisation 2: Rendu par Bloc

Au lieu de copier tile par tile, copier des blocs plus grands:

```assembly
; Copier un bloc de 4 tiles (2×2) en une seule opération
; Cela réduit le nombre d'opérations Blitter

GPURenderBackgroundBlocks:
    ; Calculer le bloc de départ
    ; block_y = (ScrollY / TileHeight) / 2
    ; block_x = 0
    
    ; Pour chaque bloc visible à l'écran:
    ; - Calculer les tiles dans le bloc
    ; - Copier le bloc complet (4 tiles = 2048 octets)
    
    rts
```

#### Optimisation 3: Double Buffering

Utiliser deux framebuffers pour éviter les déchirures:

```assembly
; Basculer les framebuffers à la fin du rendu
SwapFrameBuffers:
    move.l  CurrentFB,d0
    eor.l   #1,d0
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

## 5. Gestion des Bords

### 5.1. Background Infini

Pour un scrolling continu sans fin, nous pouvons faire **défiler le background en boucle**.

```assembly
; Dans UpdateScrolling:
UpdateScrolling:
    move.l  ScrollY,d0
    add.l   ScrollSpeed,d0
    
    ; Si on dépasse ScrollMax, revenir au début
    cmp.l   ScrollMax,d0
    blt     NoScrollWrap
    sub.l   ScrollMax,d0
NoScrollWrap:
    
    ; Si on est en dessous de 0, remonter
    cmp.l   #0,d0
    bge     NoScrollWrap2
    add.l   ScrollMax,d0
NoScrollWrap2:
    
    move.l  d0,ScrollY
    rts
```

### 5.2. Background avec Fin

Pour Crisis Force, chaque niveau a une fin. Quand le scrolling atteint ScrollMax, le niveau est terminé.

```assembly
; Déjà implémenté dans UpdateScrolling (section 4.1)
```

---

## 6. Effets Spéciaux

### 6.1. Arrêt du Scrolling

Quand le joueur meurt ou que le jeu est en pause, le scrolling s'arrête.

```assembly
; Dans UpdateScrolling:
UpdateScrolling:
    ; Vérifier si le jeu est en pause
    move.l  GameState,d0
    cmp.l   #GAME_STATE_PAUSED,d0
    beq     NoScrollUpdate
    cmp.l   #GAME_STATE_GAMEOVER,d0
    beq     NoScrollUpdate
    
    ; Mettre à jour normalement
    bsr     UpdateScrollingNormal
    
NoScrollUpdate:
    rts
```

### 6.2. Ralentissement du Scrolling

Quand le joueur est en danger, on peut ralentir le scrolling pour donner plus de temps.

```assembly
; Dans UpdateScrolling:
UpdateScrolling:
    ; Vérifier si le joueur a un bouclier
    move.w  PlayerShieldTimer,d0
    cmp.w   #0,d0
    bne     NormalScrollSpeed
    
    ; Le joueur n'a pas de bouclier, ralentir
    move.w  ScrollBaseSpeed,d0
    lsr.w   #1,d0               ; Diviser par 2
    move.w  d0,ScrollSpeed
    bra     UpdateScroll
    
NormalScrollSpeed:
    move.w  ScrollBaseSpeed,ScrollSpeed
    
UpdateScroll:
    ; ... reste de la mise à jour
```

---

## 7. Système de Vagues et Scrolling

### 7.1. Déclenchement des Vagues

Les vagues d'ennemis sont déclenchées à des positions de scrolling spécifiques.

```assembly
; Structure d'une vague avec position de déclenchement
    rsreset
WAVE_TRIGGER_Y       rs.l 1       ; Position Y de déclenchement
WAVE_ENEMY_TYPE      rs.w 1       ; Type d'ennemi
WAVE_COUNT           rs.w 1       ; Nombre d'ennemis
WAVE_X_START         rs.w 1       ; Position X de départ
WAVE_X_SPEED         rs.w 1       ; Vitesse X
WAVE_Y_SPEED         rs.w 1       ; Vitesse Y
WAVE_DELAY           rs.w 1       ; Délai entre les ennemis
WAVE_SIZE            rs.b 0

; Dans UpdateScrolling:
CheckWaveTriggers:
    move.l  ScrollY,d0
    move.l  NextWaveTrigger,d1
    
    ; Vérifier si ScrollY >= NextWaveTrigger
    cmp.l   d0,d1
    bgt     NoWaveTrigger
    
    ; Déclencher la vague
    bsr     TriggerWave
    
    ; Passer au prochain déclencheur
    move.l  CurrentWave,d2
    addq.l  #1,d2
    move.l  d2,CurrentWave
    
    ; Charger le prochain déclencheur
    move.l  CurrentWave,d2
    lsl.l   #WAVE_SIZE_Shift,d2
    move.l  WavePointer,a0
    add.l   d2,a0
    move.l  WAVE_TRIGGER_Y(a0),NextWaveTrigger
    
NoWaveTrigger:
    rts

TriggerWave:
    ; Créer les ennemis de la vague
    ; ...
    rts
```

### 7.2. Vagues Spéciales

Certaines vagues peuvent avoir des comportements spéciaux:
- Vagues en formation
- Vagues qui apparaissent à des positions spécifiques
- Vagues qui déclenchent des événements (boss, etc.)

```assembly
; Exemple: Vague en formation
TriggerFormationWave:
    ; Créer un chef de formation
    bsr     CreateEnemy
    move.w  #ENEMY_TYPE_FORMATION_LEADER,ENEMY_TYPE(a0)
    move.w  #100,ENEMY_X(a0)
    move.w  #-32,ENEMY_Y(a0)     ; Commencer hors écran
    
    ; Créer les suiveurs
    move.w  #4,d0                ; 4 suiveurs
    
CreateFollowerLoop:
    bsr     CreateEnemy
    move.w  #ENEMY_TYPE_SMALL_FIGHTER,ENEMY_TYPE(a0)
    move.w  #100,ENEMY_X(a0)
    move.w  #-32,ENEMY_Y(a0)
    sub.w   #20,ENEMY_X(a0)     ; Espacer horizontalement
    
    dbra    d0,CreateFollowerLoop
    
    rts
```

---

## 8. Implémentation Alternative: Bitmap Direct

Si on décide d'utiliser un **bitmap direct** au lieu d'un tilemap:

### 8.1. Avantages
- Plus simple à implémenter
- Meilleure qualité visuelle
- Pas besoin de décompresser les tiles

### 8.2. Inconvénients
- Utilise beaucoup plus de mémoire
- Moins flexible

### 8.3. Implémentation

```assembly
; Background comme bitmap direct (320×512, RGB16)
; Taille: 320×512×2 = 327,680 octets (~320 KB)

BackgroundBitmap: ds.b 320*512*2

; Rendu
GPURenderBackgroundBitmap:
    ; Lire ScrollY
    movei   #SharedScrollY,r1
    loadw   2(r1),r2             ; Partie haute (Y entier)
    
    ; Calculer l'offset dans le bitmap
    ; offset = r2 * 320 * 2
    move    r2,r3
    movei   #320*2,r4
    mul     r4,r3               ; r3 = offset en octets
    
    ; Adresse source = BackgroundBitmap + offset
    movei   #BackgroundBitmap,r5
    add     r3,r5
    
    ; Adresse destination = Framebuffer
    movei   #CURRENT_FB,r6
    
    ; Copier 240 lignes (320×240)
    movei   #240,r7
    
CopyBitmapLoop:
    ; Copier une ligne (320×2 = 640 octets)
    movei   #640/4,r8           ; 160 longs
    
CopyLineLoop:
    load    (r5),r9
    store   r9,(r6)
    add     #4,r5
    add     #4,r6
    sub     #1,r8
    bne     CopyLineLoop
    
    ; Passer à la ligne suivante
    sub     #1,r7
    bne     CopyBitmapLoop
    
    rts
```

---

## 9. Tests et Débogage

### 9.1. Vérification du Scrolling

Pour vérifier que le scrolling fonctionne correctement:

```assembly
; Dans main.s, pour le débogage:
DebugScrolling:
    ; Afficher ScrollY dans le HUD
    ; (À implémenter)
    
    ; Vérifier que ScrollY augmente
    move.l  ScrollY,d0
    cmp.l   LastScrollY,d0
    blt     ScrollingBackwards
    bgt     ScrollingForwards
    ; Pas de changement
    bra     ScrollEnd
    
ScrollingForwards:
    ; Scrolling avant
    move.l  d0,LastScrollY
    bra     ScrollEnd
    
ScrollingBackwards:
    ; Scrolling arrière (problème!)
    move.l  d0,LastScrollY
    ; Déclencher un error ou un debug break
    
ScrollEnd:
    rts

LastScrollY: ds.l 1
```

### 9.2. Commandes MAME pour le Débogage

```
; Afficher la position de scrolling
memory 0x801000,8  ; Afficher ScrollY

; Définir un breakpoint sur la mise à jour du scrolling
break 0x4000      ; Adresse de UpdateScrolling

; Tracer les appels
watch 0x801000    ; Surveiller ScrollY
```

---

## 10. Optimisations Avancées

### 10.1. Parallax Scrolling (Optionnel)

Bien que Crisis Force n'utilise pas de parallax scrolling, nous pouvons l'ajouter pour améliorer l'apparence:

```assembly
; Deux couches de background
; Couche 0: Lointain (scrolling lent)
; Couche 1: Proche (scrolling normal)

; Variables
ScrollY_Parallax0:   ds.l 1       ; 50% de la vitesse
ScrollY_Parallax1:   ds.l 1       ; 100% de la vitesse

; Mise à jour
UpdateParallaxScrolling:
    move.l  ScrollY,d0
    
    ; Couche 0: 50% de la vitesse
    lsr.l   #1,d0
    move.l  d0,ScrollY_Parallax0
    
    ; Couche 1: 100% de la vitesse
    move.l  ScrollY,ScrollY_Parallax1
    
    rts
```

### 10.2. Scrolling Non-Linéaire

Pour des effets spéciaux, on peut utiliser un scrolling non-linéaire:

```assembly
; Exemple: Scrolling sinusoïdal
UpdateSineScrolling:
    move.l  FrameCounter,d0
    and.l   #$FF,d0             ; Utiliser seulement les 8 bits inférieurs
    
    ; Calculer sin(d0) * amplitude
    ; (nécessite une table de sinus ou un calcul approché)
    
    ; Ajouter à ScrollY
    add.l   d1,ScrollY
    
    rts
```

---

## 11. Conclusion

Ce document fournit une **implémentation complète** du système de scrolling pour Crisis Force sur Atari Jaguar, incluant:

- ✅ Analyse du scrolling original NES
- ✅ Concept d'implémentation sur Jaguar
- ✅ Structures de données
- ✅ Algorithmes de rendu
- ✅ Gestion des bords
- ✅ Intégration avec les vagues d'ennemis
- ✅ Optimisations
- ✅ Tests et débogage

### Implémentation Recommandée

1. **Utiliser le tilemap** pour les backgrounds (économique en mémoire)
2. **Cacher les tiles** dans la RAM GPU pour les performances
3. **Utiliser le Blitter** pour les copies rapides
4. **Double buffering** pour éviter les déchirures
5. **Gérer les vagues** basées sur la position de scrolling

### Prochaines Étapes

1. **Implémenter le rendu de base** dans `gpu.s`
2. **Tester le scrolling** dans l'émulateur
3. **Optimiser** les performances
4. **Ajouter les effets spéciaux** (si temps disponible)

---

**Document validé**: 2026-09-30  
**Prochaine révision**: Après implémentation initiale
