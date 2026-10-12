# Crisis Force - Portage Atari Jaguar - Avancement Phase 3

## État actuel (2026-10-04)

**Le jeu NES complet tourne sur Jaguar.** Le code 6502 de la ROM est **recompilé statiquement en 68000**. Toute la logique d'origine s'exécute donc telle quelle : les 7 niveaux, les vagues d'ennemis, les boss, les armes et formes du vaisseau, les power-ups, les bombes, les menus, l'introduction et la musique.

Côté Jaguar, chaque composant joue le rôle d'une partie de la NES :

| Composant | Rôle |
|---|---|
| **68000** | Exécute le code recompilé. |
| **GPU** | Dessine les nametables et les sprites de la PPU NES. |
| **DSP** | Émule l'APU (son). |
| **Object Processor** | Compose l'image : décor par bandes, sprites devant et derrière, palette NES en CLUT. |

Vérifié dans Virtual Jaguar et MAME :
- écran titre identique à la NES ;
- introduction avec ses effets de trame ;
- **les 7 niveaux** (MAME, build `--stage N`), avec ennemis, capsules, HUD et défilement, sans erreur ni recours à l'interpréteur ; niveau 1 à environ 59 images/s dans Virtual Jaguar ;
- musique jouée par le DSP.

```
python build.py               # -> output/CrisisForce.abs (+ .bin, + carte des symboles .map)
python build.py --autotest    # START automatique au titre, tir continu, déplacements
python build.py --stage N     # une nouvelle partie commence au niveau N (1-7)
python build.py --jagdebug    # diagnostic : couleur de fond = état GPU/DSP
```

Lancer : `virtualjaguar.exe output\CrisisForce.abs --alpine`.

Commandes NES sur les manettes Jaguar (ports 1 et 2 : manettes NES 1 et 2, mode 2 joueurs compris) :

| Jaguar | NES | Effet |
|---|---|---|
| **B** | B | tir |
| **A** | A | transformation du vaisseau |
| **C** | Select | bombe (ROM modifiée, voir PHASE4_PROGRESS.md) |
| **Pause** | Start | |
| **Option** | — | sans effet |
| **Haut / Bas** (menu principal) | Haut / Bas | déplacent le curseur du menu titre (menu réécrit, voir PHASE4_PROGRESS.md) ; **B** valide, Pause et Option y sont sans effet |

---

## Pourquoi ce changement d'approche

Les étapes précédentes (« Assets », « Décor », « Son », résumées plus bas) réimplémentaient le jeu en 68000 à partir de données extraites de la ROM. Pour terminer la phase 3 de cette façon, il aurait fallu réécrire à la main l'IA de chaque ennemi et de chaque boss des 7 niveaux, les armes, les power-ups et les menus, sans garantie de fidélité.

L'analyse de la ROM a montré deux choses :
- toute la logique tourne dans le NMI, la boucle principale ne faisant que tirer des nombres aléatoires ;
- elle consomme environ 22 000 cycles 6502 par frame.

C'est compatible avec une recompilation statique sur le 68000. Les sources de l'approche précédente sont conservées dans `backup_phase3_reimplementation/`.

---

## Architecture

### 1. Couverture du code : `tools/nes_trace.py`

Il exécute la ROM (émulateur Python `nes_probe.py`) dans plusieurs scénarios :
- écran titre et démos ;
- chaque niveau, avec le choix du niveau patché en `$CB14` et un joueur invincible (`$6658` maintenu) ;
- mort et continue ;
- partie complète, avec les ennemis ramenés à 1 point de vie.

Il relève les instructions exécutées par banque, les cibles des sauts indirects et les banques lues. Les traces sont dans `assets/trace/*.json`.

### 2. Recompilateur : `tools/recomp6502.py` → `source/nes_code.s`

- 24 751 instructions 6502, dont 23 376 tracées (jusqu'au niveau 7 dans la trace `fullgame`), donnent environ 103 000 lignes de 68000. Le reste est découvert par descente récursive.
- **Registres** :
  - `d0`/`d1`/`d2` = A/X/Y (X et Y gardent le mot haut à 0 pour servir d'index) ;
  - `a2` = pointeur de pile 6502 (`PHA` = `move.b d0,-(a2)`) ;
  - `a4` = WRAM `$6000` ;
  - `a5` = RAM + `$80` (la page zéro tient dans un déplacement 8 bits) ;
  - `a6` = variables du runtime.
- **Drapeaux** :
  - N/Z sont dans le CCR, la retenue C dans le drapeau **X** du 68000, utilisé directement par `addx`/`subx`/`roxl`/`roxr`, et V dans `d6` ;
  - le générateur suit l'emplacement réel de chaque drapeau : retenue inversée après `CMP`/`SBC`, ou connue après `CLC`/`SEC` ;
  - une analyse de vivacité globale évite de recalculer les drapeaux inutiles.
- **Pile et appels** :
  - `JSR`/`RTS` utilisent la pile 68000, et S est ajusté de 2 ;
  - le répartiteur `$C75F` (table d'adresses qui suit le `JSR`) devient un saut indexé direct ;
  - les routines qui jettent leur adresse de retour (paire `PLA PLA`) sont détectées par une analyse de profondeur de pile.
- **Banques PRG** : `$C000`-`$FFFF` sont fixes. Les appels vers `$8000`-`$BFFF` passent par un cache des banques relevées, sinon par le répartiteur `rt_dispatch_*` (recherche dichotomique dans les tables par banque).

### 3. Runtime 68000 : `source/nes_runtime.s`

- **Mémoire** : RAM, WRAM, VRAM (miroir VRC4), palette, OAM, DMA OAM, accès génériques `rt_rd_ind`/`rt_wr_ind`.
- **PPU** : `$2000`-`$2007`, avec les registres internes t, v et x fin (défilement, y compris en cours d'image).
- **Mapper VRC4e** : banques PRG par table, banques CHR, IRQ.
- **Manettes** : `$4016`/`$4017` (les deux ports).
- **APU** : écritures transmises au DSP par un anneau.
- **Interruptions 6502** : NMI, IRQ masquée par I, `RTI`. Les enveloppes `rt_nmi`/`rt_run_irq` sont réentrantes : elles sauvent tout le contexte 68000 et le registre P de l'interpréteur. Elles remettent aussi à 0 l'octet haut de X/Y, car l'interruption peut tomber dans du code 68000 du runtime.
- **Diagnostic** :
  - `rt_error` contient le code d'erreur du code recompilé (écran jaune) ;
  - les exceptions 68000 (erreur d'adresse, instruction illégale…) sont relevées dans `exc_vec`/`exc_frame` (écran magenta) ;
  - `ip_log` garde les 16 dernières entrées dans l'interpréteur.

### 4. HLE : `source/nes_hle.s`

La routine `$8001` de la banque 4 (objets → OAM par métasprites) était la plus coûteuse. Elle est **réécrite en 68000 natif**, avec les mêmes effets mémoire, vérifiés par le banc différentiel. Le coût total passe d'environ 240 000 à 168 000 cycles par frame.

### 5. Interpréteur de secours : `tools/gen_interp.py` → `source/nes_interp.s`

C'est un interpréteur 6502 complet en 68000, pour le code non couvert par les traces : sortie d'un bloc, cible inconnue d'un saut dynamique, entrée de table absente. Il rend la main au code recompilé dès qu'un saut mène à une adresse connue. **Le jeu ne plante donc pas sur un chemin non tracé.**

### 6. Jaguar : `source/main.s`

- **VBL → NMI 6502.** La VBL affiche la dernière image rendue, charge la CLUT depuis la palette NES et lit les manettes. Elle prend aussi un instantané de l'état PPU : bandes, palette et banques CHR, tandis que le GPU recopie VRAM et OAM.
- **PIT de Tom → IRQ du VRC4.** Une IRQ toutes les (256 − latch) lignes ; elle fait tourner le driver son 4 fois par frame.
- **Effets de trame** :
  - après chaque IRQ, si l'état PPU a changé (banques CHR, défilement), une nouvelle **bande** commence à la ligne courante, lue sur le compteur vidéo VC ;
  - l'introduction s'en sert pour le ciel, les nuages et la ville ;
  - jusqu'à 8 bandes et 4 plans de rendu.
- **Liste d'objets** : sprites derrière, décor (jusqu'à 4 morceaux par bande selon le défilement et les miroirs), sprites devant.

### 7. GPU : `source/gpu.s` (rendu PPU)

- **Décor** :
  - pour chaque bande, seules les rangées de tuiles visibles sont traitées ;
  - chaque tuile est comparée à un cache (adresse des données CHR et palette) et redessinée seulement si elle a changé ;
  - l'image est en 8 bpp : couleur = palette × 4 + couleur de la tuile, 0 = transparent.
- **Sprites** : les deux calques sont effacés au blitter, puis les 64 sprites 8×16 sont dessinés avec miroirs et priorité derrière le décor.

### 8. DSP : `source/dsp.s` (APU)

- **Boucle principale** :
  - applique les écritures de registres ;
  - fait tourner le séquenceur de trame à 240 Hz : enveloppes, compteurs de durée, sweep, compteur linéaire ;
  - calcule les paramètres de synthèse.
- **Interruption I2S à 25 971 Hz** :
  - deux carrés, triangle, bruit LFSR ;
  - DMC décodé à la volée depuis la PRG-ROM ;
  - mixage, puis filtre anti-continu.

---

## Outils de test

| Outil | Rôle |
|---|---|
| `tools/recomp_test.py [frames] [--interp]` | Banc différentiel sous Unicorn (68000). Pour chaque NMI/IRQ de la ROM exécutée par py65, l'état d'entrée est chargé et le gestionnaire recompilé est exécuté. RAM, WRAM, VRAM, palette, OAM et registres sont ensuite comparés à la référence ; en cas d'écart, une comparaison instruction par instruction le localise. `--interp` exécute tout par l'interpréteur de secours. |
| `tools/jag_sim.py [frames] [png] [--gpu]` | Programme Jaguar complet sous Unicorn : interruptions VBL et PIT injectées, GPU simulé ou réel (`--gpu`, émulateur RISC avec contrôle des écritures hors zones). |
| `tools/jrisc.py` | Émulateur des processeurs RISC de Tom et Jerry (encodages vérifiés sur rmac). |
| `tools/gpu_test.py` | Exécute `gpu.s` sur l'état réel du programme et compose l'image (PNG). |
| `tools/dsp_test.py [secondes]` | Exécute `dsp.s` avec les écritures APU réelles du jeu et écrit `assets/sound_preview/dsp_stage1.wav`. |

`pip install py65 pillow unicorn capstone` est requis.

## Vérifications faites

- **Recompilation, en mode natif.** Sur 600 NMI d'affilée (titre, démo, niveau 1) et toutes les IRQ correspondantes, la mémoire est identique à la ROM. Les seuls écarts restants viennent du banc lui-même : quand un NMI déborde sur la frame suivante, la référence lit déjà les boutons de la frame suivante.
- **Version native de la routine des sprites.** Le même test ne montre aucun écart sur l'OAM ni sur les tableaux d'objets.
- **Interpréteur.** 391 NMI et 1 137 IRQ exécutés entièrement en mode interprété donnent le même état que la ROM.
- **GPU.** Exécuté dans l'émulateur RISC, il rend l'écran titre à l'identique et tourne 120 frames sans écriture hors zone.
- **DSP.** La musique du niveau 1 rendue par le code DSP émulé donne une crête de −7 876 / +10 225 et une valeur efficace de 1 701. C'est très proche du modèle Python de l'étape « Son » (−8 242 / +10 201, valeur efficace 1 764). Le fichier `assets/sound_preview/dsp_stage1.wav` est à écouter.
- **Virtual Jaguar.** Titre, introduction avec effets de trame et partie du niveau 1 fonctionnent. La musique y est active : le volume des voies varie dans le build `--jagdebug`.
- **MAME.**
  - Chaque niveau (`--stage 1` à `7`, pilote automatique) tourne jusqu'au game over sans erreur et sans entrer dans l'interpréteur. Le jeu avance de 52 à 60 frames pour 60 VBL, comme la NES d'origine (46 à 60).
  - Un plantage qui n'apparaissait qu'avec le vrai timing a été trouvé avec le débogueur de MAME et corrigé : un NMI interrompait l'enveloppe de l'IRQ et entrait avec un Y sale (`$FF00`), d'où un `JMP (table,Y)` vers `$008D`.
- **Coût 68000 estimé** : environ 168 000 cycles par frame en partie (niveau 1), pour environ 221 000 disponibles en NTSC.

## Limites connues et reste à faire

1. **Matériel réel et BigPEmu non testés.** La cadence du 68000 de Virtual Jaguar n'est pas fidèle : la marge de performance (~24 %) est une estimation. Les scènes lourdes, comme les boss chargés, pourraient ralentir, comme sur NES.
2. **Manette 2** : câblée (lecture des deux ports à la façon de JagStudio), mais le mode 2 joueurs n'a pas été joué sur émulateur, faute de seconde manette configurée.
3. **Effets de trame.** Le défilement fin horizontal (`FIRSTPIX`) et la priorité NES entre sprites et décor sont gérés de façon simplifiée. La limite de 8 sprites par ligne n'est pas reproduite (pas de scintillement). Les banques CHR des sprites sont celles du début d'image.
4. **Couverture.** Le code non tracé passe par l'interpréteur, environ 10 fois plus lent. La trace `fullgame` (90 000 frames) va jusqu'au niveau 7 mais pas jusqu'à la séquence de fin, qui passera peut-être en partie par l'interpréteur.
5. **Son.** Le mélangeur est linéaire, pas la courbe non linéaire de la NES. Le rendu réel reste à juger à l'oreille.
6. Phase 4 : ROM cartouche (`makearom`, Univ.bin), tests BigPEmu et matériel.

---

## Historique de la phase 3

1. **Reprise.** Le pipeline rmac/rln, la carte mémoire, l'affichage et le protocole 68000 ↔ GPU/DSP ont été corrigés.
2. **Assets.**
   - `nes_probe.py` exécute la ROM.
   - Sprites et écran titre extraits.
3. **Décor.**
   - Carte du niveau 1 capturée (`map_capture.py`).
   - Streaming par tuiles 8 bpp.
4. **Son.**
   - Driver de la ROM rétro-ingéniéré : PlaySound `$F114`, mise à jour `$F102` à 240 Hz.
   - Musique du niveau 1 et bruitages capturés.
   - Premier synthé APU sur le DSP.
5. **Recompilation (cette étape).** Le jeu complet tourne. Les outils des étapes 2 à 4 (`convert_assets.py`, `map_capture.py`, `sound_capture.py`) ne servent plus au build ; leurs sorties sont dans `backup_phase3_reimplementation/`.

---

## Pièges rmac / Jaguar à retenir

**rmac**
- **Pas de priorité des opérateurs** : `prg_rom+4*8192` vaut `(prg_rom+4)*8192`. Toujours parenthéser.
- **Étiquettes locales d'une lettre interdites** (`.b`, `.i`, `.l`, `.x`…), car prises pour des suffixes de taille ou des registres.
- `-o fichier` avec une espace ; `-i`/`-l` collés.

**Processeurs RISC**
- `load`/`store (Rn+k)` n'existent qu'avec **r14 et r15**.
- `jr` est limité à ±15 instructions.
- `move pc,Rn` donne l'adresse de l'instruction elle-même ; la suite `move pc / jump / addqt #6` est l'appel standard.
- **Interruption DSP** : il faut lire `FLAGS` *avant* toute instruction qui modifie les drapeaux, et le réécrire tel quel à la sortie. Sinon le code interrompu reçoit des Z/N/C faux.

**Jaguar et émulateurs**
- **La RAM n'est pas à zéro au démarrage** : la BSS est effacée explicitement (`bss_start`/`bss_end`).
- **Unicorn** (banc de test) : la lecture de SR dans un hook fausse les drapeaux ; `RTE` n'est pas émulé en 68000 ; un hook ajouté après coup ne s'applique pas aux blocs déjà traduits. Il ne reproduit pas le timing réel des interruptions : les bugs de réentrance ne se voient que dans MAME ou Virtual Jaguar.
- **Débogueur de MAME sans interface** : `-debug -debugger none -debuglog`, plus un script Lua (`-autoboot_script`) qui envoie les commandes au premier frame via `manager.machine.debugger:command("bpset …")`. `-debugscript` n'est pas exécuté avec `-debugger none`. Dans l'action d'un point d'arrêt, `history 0,200` écrit le chemin des PC dans `debug.log`.

*Document mis à jour : 2026-10-04*
