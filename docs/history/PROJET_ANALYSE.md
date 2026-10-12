# Crisis Force - Portage Atari Jaguar - Analyse Initiale

## Contexte
Portage du jeu NES "Crisis Force (Japan) (En)" vers Atari Jaguar en utilisant les compétences du répertoire `atari-jaguar-game-dev`.

## Structure de la ROM NES

### Informations de base
- **Fichier**: Crisis Force (Japan) (En).nes
- **Taille**: 262160 octets (256 KB)
- **Format**: iNES
- **Type**: Shoot 'em up vertical (Konami, 1991)

### Analyse à effectuer

1. **Header iNES** (16 octets)
   - Magic number: "NES^Z" (0x4E, 0x45, 0x53, 0x1A)
   - Nombre de ROM PRG de 16KB
   - Nombre de ROM CHR de 8KB
   - Flags: Mappers, mirrors, etc.

2. **Cartographie mémoire NES**
   - PRG-ROM: Code et données CPU (6502)
   - CHR-ROM: Données graphiques (PPU)
   - Mappers utilisés

3. **Fonctionnalités du jeu**
   - Scrolling vertical
   - Sprites ennemis
   - Système de power-ups
   - Boss de fin de niveau
   - Score et HUD

## Architecture Atari Jaguar

Basé sur le SKILL.md de atari-jaguar-game-dev:

### Processus
| Processus | Rôle | Fréquence | RAM Locale |
|-----------|------|-----------|------------|
| M68000 | Logique principale | 13.295 MHz | Aucune |
| GPU (Tom) | Graphismes | 26.59 MHz | 64 KB |
| DSP (Jerry) | Audio | 26.59 MHz | 8 KB |
| OP | Object List | - | Aucune |
| Blitter | Accélération mémoire | - | Aucune |

### Mémoire Recommandée
```
$000000-$0FFFFF : Header ROM + boot (64 KB)
$010000-$3FFFFF : Code et données du jeu
$800000-$803FFF : Stack et variables (16 KB)
$804000-$80FFFF : Code 68000 (60 KB)
$810000-$83FFFF : Données générales (192 KB)
$840000-$87FFFF : Framebuffer 0 (128 KB)
$880000-$8BFFFF : Framebuffer 1 (128 KB)
$F03000-$F03FFF : Code GPU (4 KB) + données
$F1B000-$F1BFFF : Code DSP (1 KB) + données
```

## Plan de Portage

### Phase 1: Analyse de la ROM NES
1. Extraire le header iNES
2. Identifier le mapper
3. Décompresser/découper la PRG-ROM et CHR-ROM
4. Analyser le code 6502
5. Extraire les assets graphiques et sonores

### Phase 2: Conception Jaguar
1. Adapter l'architecture au modèle multi-processeur
2. Répartir les tâches entre M68000, GPU, DSP
3. Concevoir la structure mémoire
4. Planifier les optimisations spécifiques

### Phase 3: Implémentation
1. Écrire le code de bootstrap
2. Porter la logique de jeu sur M68000
3. Implémenter le rendu graphique sur GPU
4. Adapter l'audio pour DSP
5. Gérer les entrées (joystick)

### Phase 4: Tests et Optimisation
1. Tester dans les émulateurs (MAME, Virtual Jaguar)
2. Profiler les performances
3. Optimiser les goulots d'étranglement
4. Corriger les bugs

## Outils Nécessaires

1. **JagStudio** (rmac, rln, jaguar.inc)
2. **Émulateurs**: MAME, Virtual Jaguar, BigPEmu
3. **Outils NES**: 
   - FCEUX (pour analyse)
   - NESticle (pour tests)
   - Tiled (pour extraction graphique)
   - Audacity (pour extraction audio)
4. **Python 3.10+** pour scripts de build

## Prochaines Étapes

1. [ ] Analyser le header iNES de Crisis Force
2. [ ] Identifier le mapper et les banques mémoire
3. [ ] Extraire les données PRG-ROM et CHR-ROM
4. [ ] Créer un script de build pour Jaguar
5. [ ] Écrire le code de base (bootstrap)
6. [ ] Implémenter le système graphique
7. [ ] Adapter la logique de jeu
8. [ ] Porter les assets
9. [ ] Tester et déboguer
