# Crisis Force - Liste des Tâches

## Légende
- [x] = Terminé
- [ ] = À faire
- [-] = En cours
- [~] = Optionnel/Amélioration

---

## Phase 1: Préparation et Analyse  

### Infrastructure
- [x] Créer la structure de dossiers du projet
- [x] Analyser la ROM NES Crisis Force
- [x] Extraire PRG-ROM et CHR-ROM
- [x] Identifier le mapper (VRC2 - #23)
- [x] Créer le fichier jaguar.inc avec les définitions hardware
- [x] Créer le README.md du projet
- [x] Créer le script build.py
- [x] Configurer .gitignore
- [x] Créer la documentation initiale (PROJET_ANALYSE.md)

### Analyse de la ROM
- [x] Lire le header iNES
- [x] Identifier la taille PRG-ROM (128 KB)
- [x] Identifier la taille CHR-ROM (128 KB)
- [x] Déterminer le mapper (VRC2)
- [x] Déterminer le système TV (NTSC)
- [x] Déterminer le mirroring (Horizontal)
- [ ] Analyser le code 6502 de la PRG-ROM
- [ ] Identifier les banques de code
- [ ] Extraire les patterns des sprites (CHR-ROM)
- [ ] Extraire les palettes de couleurs
- [ ] Identifier les adresses des données de niveau
- [ ] Extraire les séquences musicales
- [ ] Extraire les effets sonores

---

## Phase 2: Conception  

### Architecture Système
- [x] Définir la répartition des tâches entre les processeurs
- [x] Concevoir la structure mémoire
- [ ] Détailler les communications inter-processeurs
- [ ] Concevoir le système de synchronisation

### Architecture Jeu
- [ ] Définir les structures de données pour:
  - [ ] Le joueur
  - [ ] Les ennemis
  - [ ] Les balles
  - [ ] Les power-ups
  - [ ] Les particules
- [ ] Concevoir le système de scrolling
- [ ] Concevoir le système de vagues d'ennemis
- [ ] Concevoir le système de power-ups
- [ ] Concevoir le système de scoring

### Mapping des Fonctionnalités
- [ ] Mapper les entrées NES -> Jaguar
- [ ] Mapper l'affichage NES -> Jaguar
- [ ] Mapper l'audio NES -> Jaguar
- [ ] Adapter la résolution (256x240 -> 320x240/640x480)
- [ ] Adapter le format couleur (NES palette -> RGB16)

---

## Phase 3: Implémentation  

Approche finale (2026-10-04) : **recompilation statique du code 6502 en 68000**.
Le jeu NES complet tourne. L'ancienne réimplémentation est dans `backup_phase3_reimplementation/`.
Détails : PHASE3_PROGRESS.md.

### Code 6502 -> 68000
- [x] Traçage de couverture : titre, démos, 7 niveaux, mort et continue, partie complète (tools/nes_trace.py)
- [x] Recompilateur : drapeaux avec analyse de vivacité, répartiteur $C75F, adresses de retour jetées (tools/recomp6502.py)
- [x] Runtime : mémoire, PPU (t/v/x fin), mapper VRC4, manettes, APU vers DSP, NMI/IRQ (nes_runtime.s)
- [x] Routine des sprites réécrite en 68000 natif (nes_hle.s) : de 240 000 à 168 000 cycles par frame
- [x] Interpréteur 6502 de secours pour le code non tracé (tools/gen_interp.py, nes_interp.s)
- [x] Banc différentiel Unicorn contre la ROM : natif et tout interprété (tools/recomp_test.py)
- [x] Tous les niveaux, ennemis, boss, armes, power-ups, bombes, menus, introduction : code d'origine

### Jaguar
- [x] VBL -> NMI, PIT de Tom -> IRQ VRC4 (driver son 4 fois par frame)
- [x] Liste d'objets : décor par bandes, sprites devant et derrière, CLUT = palette NES
- [x] Effets de trame : bandes en cours d'image, jusqu'à 8 bandes et 4 plans (introduction)
- [x] Manettes 1 et 2 (B = tir, A = transformation, C = bombe, Pause = Start)
- [x] Effacement de la BSS au démarrage (RAM non nulle sur Jaguar)
- [x] Enveloppes NMI/IRQ réentrantes (X/Y propres, P de l'interpréteur sauvé)
- [x] Pièges des exceptions 68000 et journal de l'interpréteur (diagnostic)

### Code GPU (Tom) : rendu PPU
- [x] Décor : cache de tuiles par plan, rangées visibles par bande, 8 bpp
- [x] Sprites 8x16 : miroirs, palettes, priorité derrière le décor, double tampon
- [x] Copie de la VRAM et de l'OAM par le GPU (soulage le 68000)
- [~] Limite de 8 sprites par ligne, priorité exacte sprite/décor de la NES

### Code DSP (Jerry) : APU
- [x] Anneau des écritures APU (68000 -> DSP), séquenceur de trame 240 Hz
- [x] Carrés (enveloppe, sweep, durée), triangle (compteur linéaire), bruit LFSR, DMC (DPCM à la volée)
- [x] Mixage linéaire et filtre anti-continu, I2S à 25 971 Hz
- [x] Test du code DSP dans l'émulateur RISC (tools/dsp_test.py -> assets/sound_preview/dsp_stage1.wav)
- [ ] Valider le rendu sonore à l'écoute (WAV, émulateur, matériel)
- [~] Mélangeur non linéaire de la NES

### Outils de test
- [x] Simulateur Jaguar léger (tools/jag_sim.py), émulateur RISC GPU/DSP (tools/jrisc.py)
- [x] Virtual Jaguar : titre, introduction, partie du niveau 1, musique
- [x] MAME (jaguar, chargement rapide .abs) : les 7 niveaux (build --stage N) ; vitesse de jeu comparable à la NES
- [x] Débogueur de MAME sans interface (points d'arrêt et surveillance mémoire en Lua)

---
## Phase 4: Intégration et Tests  

### Intégration
- [x] Intégrer les assets dans le projet (ROM NES incluse dans l'image)
- [x] Intégrer le code GPU avec le code 68000
- [x] Intégrer le code DSP avec le code 68000
- [x] Tester les communications inter-processeurs (anneau APU, instantané PPU, drapeaux GPU)
- [x] Image de cartouche .j64 (Univ.bin + amorçage source/boot.s), voir PHASE4_PROGRESS.md

### Tests
- [x] Tester dans MAME (logique ; affichage écrasé par l'émulation vidéo de MAME)
- [x] Tester la cartouche dans MAME (vrai BIOS)
- [x] Tester dans Virtual Jaguar
- [ ] Tester dans BigPEmu (à la main : capture automatique impossible)
- [ ] Tester sur le matériel
- [x] Vérifier l'affichage graphique (VJ, MAME : 7 niveaux)
- [x] Vérifier le son (enregistrement MAME : niveaux, plus d'écrêtage ; écoute à faire)
- [ ] Vérifier les entrées
- [ ] Vérifier les collisions
- [ ] Vérifier le scrolling

### Débogage
- [ ] Corriger les problèmes d'affichage
- [x] Corriger les problèmes audio (volume parasite du sweep, écrêtage)
- [ ] Corriger les problèmes de timing
- [ ] Corriger les problèmes de synchronisation
- [ ] Optimiser les performances

---

## Phase 5: Optimisation et Finalisation  

### Optimisation
- [ ] Optimiser le code 68000
- [ ] Optimiser le code GPU
- [ ] Optimiser le code DSP
- [ ] Optimiser l'utilisation de la mémoire
- [ ] Optimiser les communications inter-processeurs
- [ ] Minimiser les accès à la RAM principale

### Finalisation
- [ ] Finaliser tous les niveaux
- [ ] Finaliser tous les ennemis
- [ ] Finaliser tous les boss
- [ ] Finaliser tous les power-ups
- [ ] Ajouter les écrans de titre et de fin
- [ ] Ajouter les high scores
- [ ] Ajouter les crédits

### Documentation
- [ ] Documenter le code source
- [ ] Documenter l'architecture
- [ ] Documenter les optimisations
- [ ] Créer un guide de build
- [ ] Créer un guide de débogage

---

## Améliorations Futures (Optionnel)  

- [~] Ajouter des fonctionnalités supplémentaires
- [~] Améliorer les graphismes (plus de couleurs, meilleure résolution)
- [~] Améliorer le son (meilleure qualité, plus de canaux)
- [~] Ajouter des niveaux bonus
- [~] Ajouter un mode deux joueurs
- [~] Ajouter des options de configuration
- [~] Optimiser davantage les performances
- [~] Porter sur d'autres systèmes (si applicable)

---

## Priorités

### Haute Priorité (Critique)
1. Terminer l'analyse de la ROM NES
2. Implémenter le rendu graphique de base
3. Implémenter les entrées
4. Implémenter le scrolling
5. Implémenter la logique de jeu de base

### Moyenne Priorité (Important)
1. Extraire et convertir tous les assets
2. Implémenter l'audio
3. Implémenter toutes les mécaniques de jeu
4. Terminer tous les niveaux
5. Optimiser les performances

### Basse Priorité (Amélioration)
1. Ajouter des fonctionnalités supplémentaires
2. Améliorer la qualité graphique/sonore
3. Documenter complètement le code
4. Créer des outils supplémentaires

---

## Temps Estimé

| Phase | Temps Estimé |
|-------|---------------|
| Phase 1 | 2-4 heures |
| Phase 2 | 4-8 heures |
| Phase 3 | 20-40 heures |
| Phase 4 | 10-20 heures |
| Phase 5 | 10-15 heures |
| **Total** | **46-87 heures** |

---

## Notes

- Le portage complet peut prendre plusieurs semaines selon le temps disponible.
- Certaines parties peuvent être plus complexes que prévues (notamment l'audio DSP).
- Des compromis peuvent être nécessaires pour maintenir de bonnes performances.
- Le jeu original utilise le mapper VRC2, ce qui complexifie l'extraction du code 6502.
