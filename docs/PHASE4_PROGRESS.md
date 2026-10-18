# Crisis Force - Portage Atari Jaguar - Avancement Phase 4

## État actuel (2026-10-04)

Phase 4 : intégration et tests. L'architecture est décrite dans `PHASE3_PROGRESS.md`.

### Cartouche

`python build.py` produit maintenant aussi **`output/CrisisForce.j64`**, une image de cartouche de 4 Mo pour BigPEmu et les cartouches flash :

| Adresse | Contenu |
|---|---|
| `$800000` | En-tête universel `Univ.bin` de JagStudio. |
| `$802000` | Amorçage (`source/boot.s`) : recopie le programme en `$4000` puis le lance. |
| `$802100` | Image du programme (texte + données, la même que `CrisisForce.bin`). |

Le build vérifie que `img_size` se trouve bien à la fin de `boot.bin`. L'édition des liens se fait **sans `-rq`** : le bourrage déplaçait `img_size`, qui restait à 0. La boucle de copie partait alors sur 4 Go et écrasait les registres matériels (MAME : « gpu: fatal endian setup »).

### Vérifications

- **MAME en mode cartouche** (`-cart`, vrai BIOS Jaguar, logo compris) :
  - le build normal joue l'introduction ;
  - le build `--autotest` joue une partie jusqu'au game over, sans erreur.
- **Son enregistré par MAME** (`-wavwrite`) :
  - niveau en partie : valeur efficace d'environ 1 800, proche de la référence (1 701 à 1 764) ;
  - plus aucun écrêtage ni retournement 16 bits.
- **Game over** : silence après le jingle, conforme à la ROM d'origine (toutes les voies à volume 0).
- **Virtual Jaguar et MAME** (`.abs`) : les 7 niveaux, voir la phase 3.

### Bugs corrigés

1. **DSP, carré muet par sweep.** Quand la cible du sweep dépassait `$7FF`, la voie devait être muette. Mais `dsp_sweep_target` utilise `r2` comme temporaire, et la voie partait avec un volume parasite (jusqu'à 449 au lieu de 15). Résultat : un créneau pleine échelle de 25 Hz, des claquements forts lors de certains bruitages. Correctif : `r2 = 0` dans le créneau de délai du saut.
2. **DSP, écrêtage 16 bits de la sortie.** Par précaution, la sortie est écrêtée après le filtre anti-continu.
3. **Cartouche** : alignement de `img_size` (voir plus haut).

### Outils ajoutés

- **`tools/dsp_test.py --replay fichier t0 t1`** rejoue dans l'émulateur RISC des écritures APU relevées dans MAME. Les écritures sont relevées par un write tap Lua sur `dsp_ring` ; le script se trouve dans le scratchpad de la session, à recréer si besoin. Le test écrit `assets/sound_preview/dsp_replay.wav` et la valeur de chaque voie au moment du mixage dans `dsp_replay_channels.txt`.
- **`python build.py --stage N`** démarre une nouvelle partie au niveau N.

## Retour du test BigPEmu (manette réelle) et corrections

Premier test : écran titre correct, commandes correctes. Deux défauts signalés : la fenêtre de texte de l'introduction clignotait, et le jeu manquait de fluidité.

### Clignotement : bandes d'effets de trame déterministes

- **Cause** : la ligne où commence une bande était lue sur le compteur vidéo (VC) à la fin du gestionnaire d'IRQ. Celui-ci contient aussi le driver son, de durée variable. De plus, l'acquittement de l'IRQ relançait le PIT. Sous un émulateur au timing réaliste, la limite sautait d'une image à l'autre.
- **Correctif** : la ligne de chaque IRQ est calculée avec le modèle du compteur du VRC4 (`irq_nom`) :
  - écriture faite dans le NMI = ligne 242 ;
  - écriture faite dans une IRQ = ligne de cette IRQ ;
  - plus (256 − latch) lignes.

  Les lignes obtenues sont celles de la NES de référence : IRQ en 44/119 et 60/125/190/172, bandes en 45/119 et 173. L'acquittement (`$F00C`) ne relance plus le PIT.
- Les images non rendues oublient leurs bandes (plus de cumul), et les bandes doivent se suivre.

### Fluidité : profilage et optimisations

Outils : profileur statistique dans MAME (coroutine Lua, PC du 68000 et du GPU échantillonnés à environ 10 kHz) et compteurs `stat_lag` (VBL pendant le NMI) / `stat_gpubusy` (VBL pendant un rendu GPU, image sautée).

**68000** (temps libre en partie, niveau 1, dans MAME : 27 % → 38 %) :
- **Recompilateur, vivacité interprocédurale des drapeaux.** Un RTS ne garde que les drapeaux utilisés après les JSR qui y reviennent (810 RTS sur 823 résolus). Les conversions de retenue disparaissent, et CMP + BCS devient `cmp` + `bcc`.
- **INC/DEC mémoire** : une seule instruction `addq.b`/`subq.b`.
- **Écritures des banques CHR** décodées à la compilation (en ligne). `rt_wr_chr` traite les écritures indexées, et les autres registres du mapper appellent `rt_wr_mapper` directement.
- **Bandes** : `CaptureBand` seulement si l'état PPU a changé (`rt_pdirty`).
- **Palette** : la CLUT n'est rechargée que si la palette a changé.
- **Instantané GPU lancé en début de VBL** : la copie de la VRAM se fait pendant la construction de la liste d'objets.
- **hle_sprites** : position de l'objet en registres, et boucle serrée sur les cases d'objets vides.
- **DMA OAM** : copie déroulée.

**GPU** (images sautées sur environ 1 800, autotest dans MAME) :

| Niveau | 1 | 2 | 3 | 4 | 5 | 6 | 7 |
|---|---|---|---|---|---|---|---|
| Avant | 9 | 33 | 428 | 156 | 143 | 136 | 325 |
| Après | 1 | 1 | 1 | 7 | 22 | 1 | 1 |

- Les calques de sprites ne sont plus effacés en entier au blitter (2 × 61 Ko par image, 20 % du temps GPU). Seuls sont effacés les rectangles des sprites dessinés la dernière fois dans le même tampon, notés dans des listes en RAM GPU.
- Les tuiles du décor utilisent une table précalculée (`gpu_bgtab`, 4 Ko, remplie par `InitBgTab`). Elle donne 4 pixels finaux, palette comprise, par paire de quartets : environ 20 instructions par rangée au lieu de 50.

**Piège rencontré** : `RT_VARS_SIZE` passé à 98 désalignait `nes_vram`/`nes_oam`, que le GPU recopie par mots longs (bits bas de l'adresse ignorés). Résultat : tuiles et sprites faux. Ces zones sont maintenant explicitement alignées (`.phrase`).

### Builds à tester

- `dist/CrisisForce.j64` : version normale.
- `dist/CrisisForce_perfhud.j64` (`python build.py --perfhud`) : la couleur de fond, visible dans les bordures et le fond NES, devient **rouge** sur une image NES en retard (le 68000 n'a pas fini), **orange** sur une image sautée (le GPU n'a pas fini), et reste noire sinon.

## Deuxième retour : comparaison avec la Famicom

Référence : MAME, driver `nes`, liste logicielle `crisisf`. La carte exacte y est décrite (VRC4, broches PRG A3/A2). Les ROM `rc856j00p`/`rc856j00c` sont extraites du `.nes`. Avec `-cart fichier.nes`, MAME choisit la mauvaise variante VRC2/VRC4 et les graphismes sont faux.

### Intro

1. **Sprites visibles dans la bande « 199X TOKYO CITY ».**
   - À l'IRQ de la ligne 172, le jeu met les banques CHR des sprites sur une banque vide (`$43`), ce qui les masque sous la ligne.
   - Le GPU utilisait les banques du début d'image pour tous les sprites.
   - **Correctif** : les banques CHR des sprites sont prises par bande. Une table `gs_bandtab` (fin de bande, pointeurs CHR) est construite en RAM GPU, et une recherche est faite par ligne de sprite.
2. **Priorité NES entre sprites.** Un sprite « derrière » de plus petit indice masque aussi les sprites « devant » ; le décor opaque passe devant les deux. **Correctif** : ses pixels effacent le calque « devant » (écart `gs_delta`).
3. **Rangées parasites au bas des portraits et sous les avions.**
   - Le jeu reprogramme l'IRQ environ 1,2 ligne après son déclenchement, et change les banques CHR 2 à 4 lignes après. Le modèle supposait une écriture à la ligne même de l'IRQ ; l'erreur s'accumulait (IRQ en 101/115/169 au lieu de 102,5/117,9/173,3) et les bandes commençaient trop tôt.
   - **Correctif** (première version, remplacée au retour suivant par le comptage des cycles 6502, voir « Quatrième retour ») :
     - modèle en 1/16 de ligne, avec une écriture dans une IRQ à +1,2 ligne ;
     - la bande commençait à la dernière écriture PPU/CHR du gestionnaire, estimée par VC.

### Niveau en ville : bord droit pendant le défilement horizontal

- **Cause** : quand le défilement X n'est pas multiple de 8, le morceau de décor de droite est affiché par phrases de 8 pixels. Il dépasse de 1 à 7 pixels à droite de l'image NES et montre des colonnes que le jeu n'a pas encore mises à jour.
- **Vérification** : avec X = 5, le décor dépassait de 3 pixels. L'image composée par le nouveau compositeur de liste d'objets (`tools/jag_sim.py --gpu --ol`) s'arrêtait à 291 au lieu de 288.
- **Correctif** : un cache opaque de 8 pixels est placé sur le bord droit, en dernier dans la liste d'objets. Il a la couleur de fond (CLUT 255) et utilise une seule phrase répétée (DWIDTH = 0). Le build `--noedgemask` le désactive pour comparer.

### Outils

- `tools/jag_sim.py --gpu` exécute de nouveau le vrai `gpu.s` (émulateur RISC sur la mémoire du simulateur).
- `--ol` compose l'image réellement affichée à partir de la liste d'objets, de la CLUT et de la couleur de fond.
- Différence restante : la **palette RGB** du port est un peu plus sombre que celle de MAME (bleu du ciel, blanc du flash). Les indices de couleur NES sont identiques.

## Troisième retour : écran des options

Rappel : sur ce titre, c'est **SELECT (Option sur la manette Jaguar)** qui déplace le curseur, puis START (Pause) valide.

- **Symptôme** : en entrant dans OPTION MODE, le jeu s'arrêtait sur l'erreur 4 (instruction invalide dans l'interpréteur, PC en $0100).
- **Cause** : l'écran d'options n'était dans aucune trace. Son code ($BC5D, banque 7) passait donc par l'interpréteur de secours. Ce code appelle le répartiteur `$C75F`, qui jette son adresse de retour (`PLA PLA`) puis saute vers une cible dont le `RTS` revient à l'appelant d'origine. L'interpréteur :
  - appelait la version recompilée du répartiteur, qui lisait dans la pile 6502 une adresse jamais écrite ;
  - décidait du retour vers le code natif avec un compteur de profondeur, faussé par l'adresse jetée.
- Le banc différentiel ne l'avait pas vu : il ne rejoue que les NMI/IRQ, sans entrées sur l'écran d'options.

**Corrections** :
- **Interpréteur** (`tools/gen_interp.py`) :
  - le retour au code natif se décide sur le niveau de la pile 6502 à l'entrée (`ip_base`) ;
  - les routines qui jettent leur adresse de retour (`nes_droppers`, liste émise par le recompilateur) sont toujours interprétées.
- **Couverture** : nouveau scénario de trace `options` (toutes les rubriques, chaque musique du sound test, EXIT, puis départ d'une partie à 2 joueurs). Avec 24 920 instructions recompilées, l'écran d'options et le départ à 2 joueurs ne passent plus du tout par l'interpréteur.
- **Outils** :
  - `jag_sim.py` simule la matrice de la manette Jaguar (`sim.buttons`) ;
  - `recomp_test.py --options` rejoue ce scénario ;
  - l'écran OPTION MODE et sa navigation sont identiques à la référence NES.

## Affichage plein écran (résolution native Jaguar)

- **Avant** : en mode 320 colonnes (pixel de 4 cycles d'horloge vidéo), l'image NES de 256 pixels n'occupait que 80 % de la largeur, avec des bandes sur les côtés.
- **Maintenant** : pixel de 5 cycles (`PWIDTH5`). 256 pixels × 5 = 1 280 cycles, exactement la largeur d'un écran Jaguar natif 320×240 (320 × 4). L'image remplit toute la largeur, sans mise à l'échelle approximative : chaque pixel NES a la même largeur, 1,25 pixel Jaguar, proche du rapport de pixel 8:7 de la NES sur un téléviseur. Les 240 lignes NES correspondent aux 240 lignes natives.
- **Cadrage horizontal** : l'image commence à la première colonne visible des téléviseurs et de BigPEmu (horloge 176 en NTSC, 196 en PAL) et occupe les 1 280 horloges suivantes. `HDB` est placé 8 pixels plus tôt (`XMARGIN`) et `a_xpos` vaut 8 : les objets décalés par le défilement fin gardent un XPOS positif. L'ancien centrage, (largeur − 1 280) / 10, laissait une bande de fond d'environ 2 pixels à gauche dans BigPEmu.
- **Ancien affichage** : `python build.py --pillarbox` (image centrée avec bordures).

## Commandes

- **Commandes à 3 boutons** (`tools/rom_patches.py`) :
  - **B** tire, **A** transforme le vaisseau, **C** lance la bombe ;
  - A pendant le tir, ou A+B ensemble, ne lance plus de bombe : le vaisseau se transforme ;
  - **Option** n'a plus d'effet ;
  - à l'écran CONTINUE / END, **C** fait le choix, à la place de Select.
- **Mise en œuvre** :
  - **Manette** : `main.s` envoie C comme SELECT NES. La ROM d'origine n'utilise pas Select en jeu (deux parties identiques, l'une avec Select, donnent le même état).
  - **Entrées du joueur** (banque 0, `$8439`) : elles sautent vers une nouvelle routine dans l'espace libre de la banque fixe 14 (`$C000`). Un nouvel appui sur SELECT lance la bombe (code d'origine `$8468` → `$85FE`, stock en `$492`) ; la transformation n'est plus conditionnée au tir.
  - **Écran OPTION, ligne KEY** (banque 7) : choix parmi les **6 attributions** possibles des 3 fonctions (transformation, tir, bombe) aux boutons A, B, C. Il y a 3 × 2 × 1 = 6 permutations ; 9 supposerait qu'un bouton cumule deux fonctions.
    - Gauche/Droite sur la ligne KEY écrit les boutons dans un registre fictif `$5FFF`. Le runtime (`rt_wr_keycfg`, et `key_hook` dans la référence Python) fait tourner l'indice (WRAM `$7F00`, zone jamais utilisée par le jeu) et réécrit les 3 lettres du texte (WRAM `$7F10`). Les deux pointeurs de chaîne KEY visent ce texte.
    - `main.s` (`key_map`) convertit A/B/C selon l'indice.
    - Mise en page : KEY et « x CHANGE  y SHOT » en rangée 17, « z BOMB » en rangée 19. Les deux lignes sont dans le bloc d'attributs de KEY (rangées 16 à 19) et passent en blanc ensemble.
    - Le réglage dure jusqu'à l'extinction (WRAM non sauvegardée).
- **Menu principal réécrit dans la ROM** (`tools/rom_patches.py`). Les modifications sont appliquées par le recompilateur et par l'émulateur de référence `nes_probe.py`, pour que les tests comparent la même ROM.
  - L'ancienne gestion Select/Start ($BEF5, banque 9) saute vers une nouvelle boucle placée dans l'espace libre de la banque 9 ($BF51, jamais exécuté ni lu d'après les traces).
  - **Bas** : curseur `$29` + 1 ; **Haut** : − 1. Le curseur boucle, avec le son et l'appel `$C708` d'origine.
  - **B** valide (code de validation d'origine, `$BF14`).
  - **Select** (Option) et **Start** (Pause) sont sans effet dans ce menu. Pause fonctionne toujours en jeu et passe l'introduction.
- Outils mis à jour pour valider avec B : pilote automatique (`AutoPad`), `recomp_test.py`, `nes_trace.py`, `nes_probe.py`, `dsp_test.py`.

## Quatrième retour : bande à gauche, visages et avions de l'intro

### Bande transparente à gauche

Voir « Cadrage horizontal » ci-dessus. Piège rencontré : **rmac évalue les expressions de gauche à droite, sans priorité des opérateurs** (`176-XMARGIN*NES_PIXCLK` donnait (176 − 8) × 5). Toujours parenthéser.

### Effets de trame chronométrés comme sur NES

- **Problème** : le gestionnaire d'IRQ du jeu attend (boucles, routines appelées de plusieurs endroits) avant de changer banques CHR et défilement. Le 68000 exécute ce code bien plus vite, donc la ligne de chaque changement ne peut se déduire ni du temps réel ni d'un délai fixe par site. Une médiane par site s'écartait jusqu'à 2,3 lignes ; les avions avaient leurs banques une ligne trop tard.
- **Comptage des cycles 6502** :
  - `tools/ppu_timing.py` relève dans `assets/irq_code.json` les 194 instructions exécutées en IRQ avant une écriture chronométrée (PPU, CHR, registres d'IRQ) ;
  - le recompilateur ajoute à chacune `lea n(a3),a3` (cycles de base, +1 pour un branchement arrière), qui ne touche pas aux drapeaux ;
  - `rt_run_irq` met a3 à 7 ;
  - erreur mesurée contre py65 : 0,04 ligne au plus sur 89 058 écritures.
- **Bandes à la ligne exacte** : `rt_ppu_time`, appelé avant chaque écriture `$2000/$2005/$2006` ou de banque CHR, convertit a3 en 1/16 de ligne. Le défilement X compte +0,25 ligne, car il est recopié au cycle 257.
  - Les écritures qui prennent effet sur la même ligne forment un groupe.
  - Une écriture plus tardive ferme la bande du groupe (`jag_ppu_split`). Dans la scène des avions, le CHR change en ligne 45 et le défilement en 46, comme sur NES.
  - `MAX_BANDS` passe à 12 (`OL_STOP` 848).
- **Modèle du VRC4** : une écriture dans une IRQ est datée par a3, et non plus à +1,2 ligne. Les IRQ du modèle tombent en 44/101,9/158,4/176,8, comme sur NES.
- **Plans de rendu** : les bandes au même décor (mêmes banques CHR du fond) partagent un plan (`BandPlane`), et un plan par décor différent. Avant, les bandes au-delà de la 3ᵉ partageaient le plan 3 et s'écrasaient leurs tuiles.

### Chaîne d'IRQ et VBL

- **PIT programmé pour la ligne cible** (`PitAt`), et non pour un délai depuis l'écriture.
  - La ligne actuelle est comptée depuis la VBL (début de `jag_vbl` = ligne 241, `NesLine`), ce qui fonctionne quel que soit le placement de VC selon l'émulateur.
  - Une IRQ armée par le NMI attend au moins une demi-période, pour ne pas interrompre le début du NMI.
  - `jag_int` recharge la période à chaque interruption PIT, sinon une IRQ restée en attente revenait à chaque ligne.
- **VBL raccourcie** : le NMI commençait jusqu'à 66 lignes après la VBL, ce qui décalait toute la chaîne d'IRQ et parfois la faisait passer après la VBL suivante. La construction de la liste d'objets coûtait à elle seule environ 37 lignes.
  - La liste de l'image suivante est préparée après le NMI (`PrebuildOL`) dans un tampon maître (2 tampons).
  - À la VBL, elle est seulement recopiée dans `ObjectList`, car l'OP modifie les objets qu'il parcourt.
  - La VRAM et l'OAM sont copiées par le 68000 (movem), sans attente du GPU.
  - Le NMI commence maintenant environ 19 lignes après la VBL.
- **Auto-correction** : une IRQ dont la ligne du modèle ne suit pas la dernière bande ouvre une nouvelle image (journal repris).

### Résultat

- Visages : limites aux lignes 48/104/120/176 comme sur NES, stables d'une image à l'autre (VJ, MAME).
- Avions : complets (réservoir du jet bleu, bas du jet rouge, contours), bandes 45/46/103/160/161/178/179/180 identiques au NES, stables.
- Tests : `recomp_test` normal, `--options` et `--interp` sans échec ; niveaux 1 à 7 dans MAME sans erreur.

## Cinquième retour : tirs invisibles au premier boss

- **Symptôme** : au boss 1, après le retour du mode super au mode normal, les tirs et la bombe ne s'affichaient plus pendant un moment, tout en restant actifs.
- **Cause** :
  - au boss ($45 = 2, $1A = 1), la routine de sprites du jeu ne dessine les objets 2 à $1F (dont les tirs) qu'une image sur deux, selon la parité de l'objet et du compteur $23 ; c'est un clignotement qui contourne la limite NES de 8 sprites par ligne ;
  - le Jaguar, chargé dans cette scène, peut n'afficher qu'une image NES sur deux et tomber durablement sur la phase où les tirs sont absents.
- **Vérifications** :
  - la logique est identique à la référence (`recomp_test.py --state=... --poke=6536:1,6658:2`) ;
  - le GPU dessine bien les sprites de l'OAM (simulateur, état sauvé au boss).
- **Correctif** : le GPU n'a pas la limite de 8 sprites par ligne, donc ce clignotement n'a pas lieu d'être sur Jaguar.
  - `hle_sprites` dessine aussi les objets sautés dans `hle_xoam` (`.lextra`), un tampon d'affichage seulement. La page zéro est rétablie, et la mémoire du jeu reste celle de la routine d'origine.
  - `rt_wr_4014` (Jaguar seulement) place ces sprites dans les entrées cachées de l'OAM.
  - Les tirs sont maintenant présents à chaque image.
- **Outils ajoutés** :
  - `recomp_test.py --state=fichier [--poke=adr:val,...] [--lives]` : comparaison à partir d'un état sauvé de `nes_probe` ;
  - `jag_sim.Sim.save_state()` / `load_state()` : reprise d'une partie longue, par exemple au boss, sans repartir du début.

## Sixième retour : HUD devant les sprites

- Sur NES, l'ordre de l'OAM tourne à chaque image ($6740 += $44). Le HUD (vies, bombes), écrit en dernier par $AE35, passe donc tantôt devant, tantôt derrière les autres sprites.
- Sur Jaguar, le HUD est toujours devant :
  - `hle_sprites` note les entrées écrites par $AE35 (`hle_hud`) ;
  - `rt_wr_4014` les associe à la page copiée (`oam_hud`) ;
  - `HudFirst` (TakeSnapshot) les place en tête de l'OAM de l'instantané (affichage seulement, la mémoire du jeu ne change pas).
## Septième retour : sprites invisibles dans une zone en haut de l'écran (en jeu)

- **Symptôme** : le décor défile, mais les sprites disparaissent en haut (et à gauche) : ennemis qui « apparaissent », tirs qui disparaissent.
- **Cause probable** :
  - quand le NMI du jeu dure plus d'une image (environ 3 à 6 % des images en partie), la liste d'objets de l'image suivante n'est pas prête à la VBL ;
  - `jag_vbl` la construisait alors lui-même (environ 37 lignes) avant `RefreshOL` ;
  - le haut de l'image était donc affiché avec la liste précédente, déjà parcourue et modifiée par l'OP, et avec des tampons de sprites qui ne sont plus les bons ;
  - le décor, dont les plans ne sont pas doublés, restait correct.
- **Correctif** : la VBL ne construit plus la liste. Si elle n'est pas prête, l'image attend la VBL suivante, et la liste affichée est recopiée immédiatement.
- **Bogue corrigé au passage** : `PrebuildOL`, appelé après `rt_nmi` dans `jag_int`, écrasait d7 (drapeaux d'interruption) et le contexte 6502 (a2, a4, a5). Quand une VBL et une interruption PIT arrivaient ensemble, `rt_irq` pouvait être appelé à tort ou avec un contexte faux. `PrebuildOL` conserve maintenant tous les registres.
- **Vérifications** :
  - le GPU dessine tous les sprites de l'OAM (comparaison automatique `sprdiff`) ;
  - le jeu n'a qu'une bande en partie : la zone ne venait pas des effets de trame.

## Huitième retour : zone sans sprites en haut et à gauche (ville du niveau 1, niveau 2)

- **Non reproduit** : simulateur (vrai code GPU + compositeur de liste d'objets), MAME (NTSC) et VJ en NTSC et en PAL (`--pal`, réglages VJ sauvegardés puis restaurés) affichent tous les sprites dans la ville.
- **Vérifié** :
  - `recomp_test` sur 5000 images au niveau 1 (jusqu'à la ville) et 3000 au niveau 2 : la logique et l'OAM sont identiques à la référence ;
  - le GPU dessine tous les sprites de l'OAM (`sprdiff`), et ils sont tous visibles dans l'image composée (`olcheck`).
- **Piste** : en ville (X = 231, Y = 134), le décor est en 4 morceaux. Les zones décrites (haut, gauche ; haut seulement au niveau 2) correspondent aux morceaux qui précèdent le dernier dans la liste d'objets. C'est propre à BigPEmu (traitement réel de l'OP).
- **Cartouche de diagnostic** `dist/CrisisForce_diagol.j64` (`build.py --diagol`) : grille de points magenta en dernier objet de la liste. Si les points disparaissent dans la même zone que les sprites, l'OP n'a pas traité la fin de la liste sur ces lignes ou pixels ; sinon, le calque des sprites lui-même est en cause.
- Le pilote `--autotest` maintient les vies du joueur 1 ($68), pour atteindre la ville et les boss.
- Première cartouche de diagnostic fausse : la boucle de la grille écrivait 512 octets par ligne et débordait de 60 Ko (tables écrasées). Corrigée et vérifiée dans VJ (PAL, ville).

### Cause retenue : apparitions / disparitions au bord haut et gauche

- Une NES ne peut pas afficher un sprite partiellement au-dessus de l'écran ou à gauche, car ses coordonnées OAM ne sont pas signées. La routine du jeu écarte donc tout morceau dont le Y ou le X calculé est négatif.
- Les ennemis qui entrent par le haut (naissance à Y = 0, morceaux au-dessus) ou par la gauche apparaissent d'un coup. Les tirs, détruits à Y = −7, disparaissent avant le bord.
- Sur un téléviseur, le cadre masquait en partie ce défaut. La Jaguar affiche toute l'image.
- **Correctif (affichage seulement)** :
  - `hle_sprites` (`.ledge`) note les morceaux juste au-dessus (−16 ≤ Y < 0) ou juste à gauche (−8 ≤ X < 0) dans `hle_xedge`, avec les bits 4 (Y négatif) et 3 (X négatif) des attributs, que la NES n'utilise pas ;
  - `rt_wr_4014` efface ces bits dans l'OAM du jeu et place les morceaux dans les entrées cachées ;
  - le GPU les dessine découpés au bord : rangées de ligne négative sautées, pixels de X négatif ignorés, rectangle d'effacement ramené à 0 ;
  - les sprites entrent et sortent en glissant, comme en bas et à droite.
- **Bogue corrigé au passage** : `rt_wr_4014` quittait la fusion des objets clignotants par `rts` quand il n'en restait plus.
- **Coût** : environ 5 % de retard en plus au niveau 2 (A/B dans MAME).

## Neuvième retour : ralentissements et images sautées (objectif 60 / 50 images/s)

### Mesures (MAME, `--autotest`, 40 s ≈ 2360 VBL, vies maintenues)

| Niveau | NES d'origine (py65, NMI imbriqués) | Jaguar avant | Jaguar après | Images sautées GPU avant → après |
|---|---|---|---|---|
| 1 | 86 | 80 | 16 | 2 → 0 |
| 2 | 155 | ≈ 300 | 30 | 2 → 0 |
| 3 | – | – | 18 | 2 → 0 |
| 4 | – | – | 24-27 | 20 → 0 |
| 5 | 36 | 41 | 17 | ≈ 100 → 0 |
| 6 | – | – | 24 | 2 → 0 |
| 7 | – | – | 31 | 2 → 0 |

- La cartouche NES d'origine ralentit elle-même : son NMI dépasse une image sur 1,5 à 6,5 % des images (script `neslag.py`, même pilote automatique). Le portage fait maintenant moins d'images en retard que l'original (≈ 1 %).
- Le retard restant correspond aux images où le travail du jeu dépasse une image : il faudrait un 68000 nettement plus rapide que la NES sur ces pointes.
- En PAL, l'image dure 20 % de plus : le retard ne peut qu'y diminuer.

### 68000

- **Recompilateur** :
  - vivacité des drapeaux sensible au contexte des appels : résumé par routine `f(R) = A | (R & B)`. Un drapeau vivant au retour d'un seul appelant n'est plus préservé avant tous les autres appels ;
  - nombre de `move.w sr,-(sp)` : 1312 → 141 ; nombre de conversions par table : 576 → 191 ;
  - INC / DEC / INX… qui doivent garder la retenue (dans X) : table `rt_inc_tab` / `rt_dec_tab` (un `move` ne touche pas X) au lieu d'une sauvegarde du SR ;
  - BCC / BCS avec la retenue seulement dans C : branchement direct, retenue connue sur chaque chemin.
- **Runtime** :
  - `rt_dispatch_lookup` : cache direct de 256 entrées devant la recherche dichotomique ;
  - `rt_rd_ind` teste d'abord la ROM ;
  - `rt_wr_4014` : masque des attributs fait pendant la copie ; `hle_xoam` compté (`hle_xoam_n`, plus de remplissage de 256 octets à chaque image), une seule fusion des sprites supplémentaires.
- **HLE** : `hle_pads` remplace la lecture des manettes ($EC4C, 16 lectures de $4016/$4017).
- **VBL** :
  - `TakeSnapshot` ne copie que les blocs de VRAM écrits (`vram_dirty`, plus un bloc tournant) ;
  - `HudFirst` échange seulement les entrées du HUD ;
  - `RefreshOL` copie seulement la longueur utile de la liste.

### GPU

- **Images sautées aux niveaux 4 et 5** : le décor est animé par une banque CHR (eau…). Elle change toutes les 9 à 13 images, avec 16 configurations, et chaque changement redessinait tout l'écran (plus d'une image de GPU).
- **Colonnes** : seules les colonnes visibles de chaque rangée sont rendues (33 au lieu de 64 avec deux nametables).
- **Cache des tuiles converties** (`bg_ttag` / `bg_tdata`, 512 entrées de 64 octets) : une tuile (données CHR + palette) n'est convertie qu'une fois, puis recopiée.
- **Tables de conversion** en RAM GPU (`gpu_bgt`, 512 octets, une par plan et par palette) au lieu des 4 Ko en DRAM (`InitBgTab` supprimé).

### Vérifications

- `recomp_test` : normal (2400 images), `--options`, `--interp` à 0 échec. Les états sauvegardés avec `--lives` gardent les mêmes écarts qu'avant (artefacts du forçage des vies).
- MAME : niveaux 1 à 7 sans erreur ni exception.
- VJ : intro (effets de trame), niveaux 2 et 5 corrects.
- Les cartouches `dist/` (normale, perfhud, diagol) sont reconstruites.

## Dixième retour : conformité au skill atari-jaguar-game-dev (2026-10-09)

Audit du code par rapport au skill mis à jour (`D:\source_codes\atari-jaguar-game-dev\SKILL.md`), puis mise en conformité.

**Déjà conforme :**
- **Règle 1 :** le 68000 n'accède à la RAM et aux registres GPU/DSP qu'en `move.l`.
- **Règle 2 :** les `loadb`/`storeb` du GPU et du DSP visent tous la RAM principale ou la ROM.
- **Règle 3 :** aucun registre interdit n'est écrit, et VMODE ne vaut jamais 0.
- **Règles 4 et 5 :** compteurs partagés petits ; `$81xx` dans JOYSTICK.
- **Interruptions :** acquittement INT1/INT2.
- **DSP :** FLAGS lu à l'entrée de l'interruption, `nop` après D_FLAGS, aucun saut dans un créneau de délai.
- **Vidéo :** VDE = $FFFF, CONFIG sert pour NTSC/PAL.

**Corrigé :**
- **Démarrage (règle 6) :**
  - `boot.s` pointe OLP sur un STOP en $3FF8 avant de recopier le programme : l'OP suivait encore la liste du boot ROM, que la copie écrase ;
  - `Start` le refait (`BOOT_STOP`) avant d'effacer la BSS, et active le son (`move.w #$100,JOYSTICK`).
- **Liste d'objets :** la branche en +8 renvoie au STOP quand VC < `a_ypos` (disposition recommandée), au lieu d'une branche toujours prise vers +16.
- **Taille du code RISC vérifiée à l'assemblage :** `.if gpu_end > G_ENDRAM` et `.if dsp_end > (D_ENDRAM-256)` provoquent un `.error`.
- **Contrôle mécanique de la règle 1 :**
  - `tools/check_hw_rules.py` désassemble le code 68000 (capstone), hors blocs GPU/DSP et données, plus l'amorce ;
  - il signale tout accès absolu à $F02000-$F03FFF ou $F1A100-$F1DFFF qui n'est pas un `move.l` (ou qui est un `clr`) ;
  - `build.py` le lance et échoue en cas de faute. Essai négatif fait : un `move.w` et un `clr.l` volontaires sont détectés.
- **Moins d'accès externes du GPU :**
  - la copie du cache de tuiles se fait par phrases (8 `loadp`/`storep` au lieu de 16 `load` et 16 `store`), avec `bg_tdata` aligné sur une phrase ;
  - `gpu_busy` est passé en RAM GPU (la boucle d'attente ne lit plus la RAM principale), et le 68000 y accède en `move.l` ;
  - `tools/jrisc.py` émule LOADP, STOREP et G_HIDATA.
- **CLUT :** effacement sans `clr.w` (lecture-écriture) ; la couleur de fond est recalculée au lieu d'être relue dans la CLUT.

**Vérifications :**
- `recomp_test` à 0 échec (normal 2400 images, `--options`, `--interp`).
- `jag_sim --gpu --ol` (vrai code GPU avec `loadp`/`storep`) : eau du niveau 5 correcte.
- MAME, qui démarre par le BIOS et l'amorce : niveaux 1 à 7 sans erreur, retard de 16 à 31 et aucune image sautée, comme avant.
- VJ : démarrage du `.j64`, intro et niveau 2 corrects.
- `dist/` reconstruit.

**Rappel du skill :** MAME ne simule pas la contention du bus et compte environ 1 cycle par instruction RISC, donc ses mesures de performance sont optimistes. Seuls BigPEmu (perfhud) et la console font foi.

## Onzième retour : skill mis à jour le 2026-10-10 (règles, bogues GPU/DSP/blitter)

**Corrigé :**
- **Règle 4 :** `Start` n'écrit plus 0 dans G_CTRL/D_CTRL (arrêter un RISC depuis le 68000 n'est pas fiable) ; seul un RISC efface son propre GO. DMAEN, BUS_HOG et BUSHI restent à 0.
- **Règle 7 (OLP écrit par le GPU) :**
  - `boot.s` charge un petit programme GPU (`boot_olp`) qui pointe OLP sur le STOP de $3FF8 avant la copie du programme, puis s'arrête de lui-même ;
  - `Start` fait de même avec `GpuSetOlp`/`set_olp`, pour le STOP puis pour la liste. La liste est construite avant le chargement du programme GPU ; OLP ne change plus ensuite et la liste est mise à jour sur place.
  - Dans MAME (BIOS + cartouche), OLP passe à $3FF80000 puis à $E4E00007 (`ObjectList`).
- **Liste d'objets :**
  - bit RELEASE sur les objets 8 bpp ;
  - YPOS forcé pair. La CLUT n'est écrite qu'à la VBL, quand l'OP est déjà passé au STOP.
- **Bogues GPU/DSP corrigés dans `dsp.s` :**
  - stores indexés d'un résultat de load pas encore lu → `or rN,rN` avant (9 endroits, dont un en créneau de délai) ;
  - deux sélections de volume chargeaient deux fois r2 (le second load pouvait doubler le premier) → un seul load ;
  - store indexé derrière l'étiquette `dsp_q_linset` → `or r0,r0` dans le créneau de délai.
- **Blitter :** la routine GPU inutilisée `gpu_clear_layer`, qui n'écrivait pas A1_CLIP, est supprimée.
- **RISC :** code aligné avant et après (`.long`).
- **`tools/check_hw_rules.py` (lancé par `build.py`, échec si faute) :**
  - plages élargies à $F02000-$F07FFF et $F1A000-$F1FFFF ;
  - registres d'adresse suivis (accès `.w`/`.b`, `clr`, écritures en `-(an)`) ;
  - côté RISC : règle 2 (octet/mot sur la RAM locale), saut / `movei` / `move pc` dans un créneau de délai, store indexé non surveillé par le scoreboard, écritures seules qui doublent un load/div ou l'instruction précédente, div sur un quotient récent, 2 `nop` après FLAGS. L'analyse est linéaire ; les stores juste après une étiquette ont été relus à la main.

**Vérifié conforme sans changement :**
- le DSP n'écrit jamais en RAM principale (bogue des écritures externes du DSP) ;
- aucun `loadp` en interruption GPU (le GPU n'a pas d'interruptions) ;
- r30/r31 : seul le DSP prend des interruptions, et son programme principal tourne en banc 1 ;
- deux branches en tête de liste vers le STOP (bornes de l'image NES, plus strictes que VDB/VDE), objets bitmap alignés sur 16 octets ;
- aucune écriture dans $800000-$DFFFFF (contrôle MAME par un write tap, 2400 images) ;
- NTSC et PAL depuis la même cartouche (CONFIG).

**Standards Atari (Pause « PAUSED », * + #, Option) :** pas appliqués, à la demande de l'utilisateur.

**Vérifications :**
- `recomp_test` à 0 échec (normal, `--options`, `--interp`) ;
- `dsp_test` (vrai code DSP) produit le son ;
- MAME : niveaux 1 à 7 sans erreur, retard de 16 à 31 et aucune image sautée ;
- VJ : `.j64` en NTSC et en PAL (réglages VJ restaurés) ;
- `dist/` reconstruit.

## Douzième retour : skill du 2026-10-10 (règle 7 précisée)

- **OLP avant toute écriture en RAM :** la liste du boot ROM est en $1000. `Start` pointe maintenant OLP sur le STOP (via le GPU) avant d'installer les vecteurs d'exception ; l'amorce le faisait déjà avant la copie du programme.
- **Liste mise à jour sur place, valide à chaque étape :**
  - la copie complète de `RefreshOL` (liste neuve) écrit le STOP d'abord, puis les objets du dernier au premier (phrase 1 puis phrase 0, long haut d'abord), puis la branche +8, et la tête (+0) en dernier ;
  - la mise à jour partielle (phrase 0 des bitmaps, long haut d'abord) ne change aucun lien.
  - Contrôle MAME (`olcopy.lua`) : la liste affichée est identique à la liste maîtresse sur 2000 images de jeu.
- **Boucle d'attente du GPU :** le skill admet désormais une boucle d'une instruction ; la nôtre (sémaphore `gpu_busy` en RAM GPU) convient.
- **Écart conservé :** les objets commencent en +16, et non en +32 après une phrase de remplissage, et les deux branches utilisent les bornes de l'image NES. Les objets bitmap sont bien alignés sur 16 octets.
- **Vérifications :** `recomp_test` à 0 échec (normal, `--options`, `--interp`), MAME niveaux 1 à 7, `check_hw_rules` sans faute, `dist/` reconstruit.

## Treizième retour : skill du 2026-10-12 (performances sur console, pipeline GPU)

**Vérifié conforme :**
- **Étiquettes locales :** aucune des étiquettes interdites (`.l .w .s .b .x .p`).
- **Saturation audio :** enregistrement MAME de 40 s de jeu, crêtes à 12378 (38 % de la pleine échelle), aucun échantillon saturé. Les pics à -32768 sont dans les 50 premières ms, pendant le BIOS.
- **Taps MAME :** installés au premier `register_frame_done` (ceux d'avant étaient ignorés). `romw.lua` refait : aucune écriture en ROM, lectures de ROM bien vues.

**68000 :**
- **`hle_idle` ($EAE7) :** la boucle principale du jeu ne faisait qu'avancer le générateur pseudo-aléatoire en attendant le NMI, en lisant la RAM et la ROM sans arrêt. Elle fait maintenant un pas, puis `stop #$2000` jusqu'à l'interruption suivante : le bus reste au GPU et à l'OP. `jag_sim` traite le `stop` comme la fin de la tranche d'exécution.
- **`rt_rd_2002` (bogue réel) :** une VBL survenant entre la lecture et l'effacement du drapeau était perdue (lecture puis `andi`). C'est maintenant un `bclr` atomique. `jag_sim`, dont le minutage est fixe, restait bloqué dans l'attente de VBL de l'initialisation.

**Mesure sur console (builds de `dist/`) :**
- **`CrisisForce_perfhud.j64` :** en plus du fond coloré, HUD chiffré en haut à gauche (ligne 8), mis à jour chaque seconde :
  - **J** : images de jeu par seconde ;
  - **A** : images affichées par seconde ;
  - **R** : % du temps où le 68000 attend sur son `stop` ;
  - **G** : % du temps où le GPU dessine (fin du rendu relevée par le GPU dans VC).
- **`CrisisForce_nodraw.j64` (`--nodraw`) :** le GPU ne dessine rien, seul le HUD est affiché. Son J et son R donnent la vitesse brute du 68000. À comparer avec la cartouche normale : un écart montre ce que le rendu coûte au 68000 sur le bus.

**GPU (pipeline) :**
- **`tools/risc_cycles.py` :** exécute le vrai code GPU sur une partie simulée (`jrisc` + `jag_sim`), puis rejoue la trace avec les règles d'attente du skill (opérande, drapeaux, port d'écriture, store indexé, saut pris, load externe, bus) et donne les cycles par étiquette.
- **`tools/gpu_regress.py` :** empreinte des plans et calques après chaque rendu, comparée au bit près entre deux builds. Builds de référence : `--norowsig` (sans signature) et `--oldtile` (boucle des tuiles d'origine).
- **Signature de rangée (`bg_rowsig`, 64 octets par rangée de plan) :** octets de tuiles, attributs, 4 banques CHR du décor et colonnes rendues. Une rangée inchangée et déjà couverte n'est plus vérifiée tuile par tuile.
- **Comparaison de signature déroulée :** cumul des écarts par `xor` et `or`, deux jeux de registres en alternance, pas de saut par long.
- **Boucle des tuiles :** invariants de rangée sortis de la boucle, lectures externes lancées en premier.
- **RAM GPU :** `spr_lists` (journaux des rectangles de sprites) passé en RAM principale : 1 Ko libéré, il en reste 904 octets.
- **Résultat (estimation, niveau 5, 40 images) :** environ 80 000 cycles GPU par image avant, 20 000 après.
- **Vérification :** rendu identique au bit près à l'ancien code sur 583 rendus au niveau 1 et 583 au niveau 5.
- **Point chaud restant :** la copie des tuiles du cache (21 %), où `storep` attend son `loadp` (G_HIDATA unique).

**Vérifications :**
- `recomp_test` à 0 échec (normal, `--options`, `--interp`) ;
- MAME niveaux 1 à 7 sans erreur, retard de 16 à 31 et aucune image sautée ;
- VJ : intro (`.j64`) et niveau 2 corrects, HUD perfhud et nodraw lisibles ;
- `check_hw_rules` sans faute.

## Quatorzième retour : ralentissements au niveau 2 (BigPEmu)

- **MAME ne montre pas de régression** (niveau 2 : 29 à 34 images en retard sur 40 s, comme avant). MAME ne modélise pas la contention du bus. Sur console, le 68000 perd surtout du temps quand l'OP, le GPU ou le blitter passent avant lui. Les corrections visent donc le bus.
- **Priorité du 68000 pendant le travail du jeu :**
  - en interruption, le 68000 passe devant le GPU et le blitter tant qu'il n'a pas écrit INT2 ;
  - `jag_int` écrivait INT2 dès le début, si bien que tout le NMI, les IRQ et la préparation de la liste tournaient à la priorité la plus basse ;
  - INT2 n'est plus écrit qu'en sortie de l'interruption la plus externe (compteur `jag_depth`).
- **Lectures de l'OP :**
  - les deux calques de sprites (256 octets par ligne chacun) étaient affichés sur toute la hauteur, même vides ;
  - le GPU relève maintenant les lignes occupées par chaque calque d'après ses rectangles (`gpu_spr_ext` → `gs_extf` / `gs_extb`), et la liste d'objets n'affiche que celles-là (`SpriteLayer`), ou rien si le calque est vide ;
  - tant que le GPU n'a pas fini le rendu, le calque est affiché sur toute la hauteur.
  - Niveau 2 sous MAME : le calque « derrière » est vide sur 100 % des images, le calque « devant » occupe 185 lignes sur 240 en moyenne, soit environ 40 % de lectures de l'OP en moins par image.
- **`hle_sprites` :** le parcours des 58 cases d'objets saute 4 cases vides d'un coup (`tst.l`) ; 10,0 % → 9,7 % du temps du 68000.
- **Vérifications :**
  - `recomp_test` à 0 échec (normal, `--options`), états du boss inchangés (5 et 3, artefacts connus) ;
  - MAME niveaux 1 à 7 sans erreur ni image sautée ;
  - image composée par la liste d'objets (`jag_sim --gpu --ol`) et VJ corrects, y compris les sprites aux bords haut et bas ;
  - `check_hw_rules` sans faute.
- **À mesurer dans BigPEmu** avec `CrisisForce_perfhud.j64`, à l'endroit lent du niveau 2 :
  - J < 60 et R proche de 0 : le 68000 est la limite ;
  - A < J : c'est le GPU ;
  - `CrisisForce_nodraw.j64` montre la vitesse du 68000 sans rendu.

## Quinzième retour : J à 60 mais A entre 49 et 60 dans BigPEmu (niveau 2)

Le jeu suit (J = 60) ; des images affichées sont sautées. Deux causes possibles :
- **B** : le GPU n'a pas fini le rendu à la VBL ;
- **L** : la liste d'objets n'est pas prête, parce que le NMI s'est terminé trop près de la VBL suivante.

**Changements :**
- **HUD perfhud :** deux compteurs de plus par seconde, B et L, soit « Jnn Ann Rnn Gnn Bnn Lnn ».
- **Dessin des sprites (GPU) :**
  - **chemin rapide :** pour un sprite devant le décor entièrement à l'écran (0 ≤ x ≤ 248), les 8 pixels d'une rangée sont convertis par les tables du décor en RAM GPU, avec +16 sur les pixels non nuls via le masque `gpu_smask`, puis fusionnés au calque en 2 ou 3 longs (lecture, masque, écriture), au lieu de 8 `storeb` et d'environ 110 instructions ;
  - **recherche de bande :** elle repart de la bande de la rangée précédente.
  - **Vérification :** rendu identique au bit près (582 rendus aux niveaux 1 et 5, `gpu_regress --cmp` compare maintenant les suites sans les numéros d'image).
  - **Coût estimé au niveau 2 :** environ 76 000 cycles GPU par image (17 %).
- **Découpage des calques à l'échange d'image (`TrimSpriteLayers`) :**
  - la liste est construite avec des calques pleine hauteur ; à l'échange, le GPU a fini et les objets des calques sont ramenés aux lignes occupées ;
  - un calque vide devient un bitmap d'une ligne à un YPOS jamais atteint.
  - **Écueil :** deux branches « jamais prises » (CC 0, YPOS $7FF) donnaient un écran noir dans MAME et VJ, qui les prenaient.
- **Construire la liste avant le NMI :** essayé puis abandonné. Le NMI démarre environ 0,6 ms plus tard, et MAME passe de 30 à 71 images en retard au niveau 2 : les sauts d'affichage seraient devenus des ralentissements du jeu.
- **`--noint2prio` :** INT2 écrit dès l'entrée de l'interruption (comportement d'avant). Cartouche `dist/CrisisForce_perfhud_noint2prio.j64`, pour comparer dans BigPEmu.
- **Vérifications :**
  - MAME niveaux 1 à 7 sans erreur, retard comme avant (17 à 36 sur 40 s), captures non vides ;
  - VJ : jeu et HUD corrects ;
  - `check_hw_rules` sans faute.

**À relever dans BigPEmu** (endroit lent du niveau 2), avec `CrisisForce_perfhud.j64` puis `CrisisForce_perfhud_noint2prio.j64` : les six valeurs J, A, R, G, B, L.

## Seizième retour : skill du 2026-10-17, mesures dans JagMCP

JagMCP (cœur FPGA MiSTer porté en C++, fidèle au cycle : contention du bus, attentes de la DRAM et des RISC) est piloté par `tools/jagmcp_run.py`. L'outil démarre la cartouche par le BIOS, la fait tourner par tranches d'images et lit les compteurs du programme (`stat_nmi`, `stat_drawn`, `stat_lag`, `stat_gpubusy`, `stat_ldrop`, VBL). Avec `--profile=N` et `--gpuprofile=N`, il fait un profil par échantillonnage (`debug.trace`, cycle de début de chaque instruction).

**Niveau 2, partie chargée (pour 300 VBL), J = images de jeu, A = images affichées :**

| Version | J | A | B (GPU pas fini) | L (liste pas prête) |
|---|---|---|---|---|
| INT2 en fin d'interruption, liste après le NMI | 300 | 85 à 103 | ≈ 200 | 0 |
| INT2 tout de suite, liste après le NMI | 300 | ≈ 156 | 0 | ≈ 140 |
| INT2 tout de suite, liste avant le NMI | 300 | 300 | 0 | 0 |

**Conclusions :**
- **Garder la priorité du bus pendant le NMI** (qui dure presque une image au niveau 2 sur console) affamait le GPU. INT2 est de nouveau écrit dès l'acquittement, comme le veut le skill.
- **Construire la liste après le NMI** la rendait trop tardive une fois sur deux. Elle est maintenant construite avant le NMI. MAME montrait plus de « retard » dans ce cas, mais son compteur (`stat_lag`) compte les VBL tombées pendant un NMI, pas les images de jeu perdues : JagMCP montre que J reste à 60.
- **Le 68000 sur console** (profil JagMCP) : environ 43 % dans le code recompilé, 18 % en attente (`stop`), 10 % dans `hle_sprites`.

**Autres points du skill :**
- **Contrôle de taille RISC :** il compare maintenant à des littéraux (`$F04000`, `$F1CF00`), et non à `G_ENDRAM` ou `D_ENDRAM`, que rmac peut mal évaluer dans un `.if`.
- **Compteurs cumulés** dans toutes les versions, pour les mesures : `stat_drawn`, `stat_ldrop`, `stat_nmi`.
- **Options retirées :** `--noint2prio`, `--earlyol` et la cartouche `perfhud_noint2prio` (expériences conclues).
- **Non-régression MAME** (`tools/mame_stages.py`, 3000 images par niveau, BIOS compris) : les niveaux 1 à 7 n'ont ni erreur du runtime ni exception, ont 2351 ou 2352 images de jeu pour 2370 VBL, et 18 captures sur 18 non unies. Le `stat_lag` de MAME (16 à 70) n'est pas une mesure de vitesse ; la référence est JagMCP.

## Dix-septième retour : images sautées au niveau 5 (eau animée)

La Famicom affiche ce niveau sans perte : son PPU construit chaque pixel au balayage, et changer une banque CHR ne coûte qu'une écriture de registre. Ici, le GPU imite le PPU en dessinant le décor dans un bitmap. Il ne redessine que ce qui change (signatures de rangée, cache des tuiles converties). Mais toutes les 9 à 13 images, l'eau change une banque CHR, et toutes les tuiles visibles changent alors réellement : 992 tuiles (31 rangées × 32) sont recopiées dans le plan en une image.

**Mesures (`risc_cycles`, image lourde) :** environ 222 000 cycles GPU, contre 12 000 à 37 000 pour une image ordinaire. La copie des tuiles du cache vers le plan (`gpu_bg_copy`, 8 `loadp`/`storep` par tuile, chaque `storep` attend son `loadp`) en prend 48 %, et la boucle des tuiles 32 %.

**Piste 1, abandonnée : signature limitée aux banques utilisées par la rangée.** Si les tuiles et les attributs n'ont pas changé, on ne redessine la rangée que si l'une de ses tuiles est dans une banque changée (banque = tuile >> 6).
- **Analyse :** à l'endroit mesuré, toutes les rangées visibles contiennent de l'eau de la banque animée. Aucune rangée n'est épargnée, et le test coûte environ 300 cycles par rangée (222 000 → 233 000).
- **JagMCP :** 12 à 14 images sautées pour 300, contre 10 à 12 avant. Code retiré.

**Piste 2, retenue : copie des tuiles au blitter** (skill : « Clears and copies go to the Blitter… start a blit, compute on the GPU, wait for IDLE before the next one »).
- **`gpu_bg_blit` :** une tuile déjà convertie (présente dans `bg_tdata`) est copiée dans le plan par le blitter : rectangle de 8 × 8 pixels en mode phrase, A1 = plan (8 bpp, largeur 256), A2 = tuile (largeur 8), pas (-8, +1), commande `SRCEN|UPDA1|UPDA2|LFU_REPLACE`. Le GPU calcule la clé de la tuile suivante pendant la copie et attend le repos du blitter (bit 0 de B_CMD) avant d'en lancer une autre.
- **Registres constants** (A1/A2_FLAGS, A1/A2_STEP, A1_CLIP = 0) posés au début du décor (`gpu_bg`). Avant chaque copie : A1_BASE, A1_PIXEL, A1_FPIXEL, A2_BASE, A2_PIXEL, B_COUNT, puis B_CMD en dernier.
- **Ordre des accès :**
  - avant une conversion, le GPU attend le blitter, qui peut encore lire la même entrée du cache ;
  - en fin de rendu, il attend la dernière copie avant de remettre `gpu_busy` à 0.
- **Les tuiles converties dans l'image** restent copiées par le GPU (`gpu_bg_copy`).
- **`tools/jrisc.py` :** émule ce sous-ensemble du blitter (copie de rectangle en 8 bpp, immédiate, B_CMD lu au repos), pour `jag_sim --gpu` et `gpu_regress`.
- **Estimation GPU (`risc_cycles`, image lourde) :** 222 000 → 140 000 cycles. Le temps du blitter n'est pas compté ; il travaille en parallèle.

**Résultats (JagMCP, partie en eau du niveau 5, pour 300 VBL) :**

| Version | J | A | B (GPU pas fini) |
|---|---|---|---|
| Copie par le GPU | 298 à 300 | 287 à 291 | 10 à 12 |
| Signature limitée aux banques utilisées | 299 à 301 | 286 à 289 | 12 à 14 |
| Copie au blitter | 299 à 301 | 299 à 301 | 0 |

**Vérifications :**
- **Rendu identique au bit près** (`gpu_regress`) :
  - niveau 5 : 583 rendus contre l'ancien code (copie par le GPU, `--norowsig`) ;
  - niveau 1 : 583 rendus contre `--norowsig`.
- **MAME, niveaux 1 à 7 :** sans erreur, 18 captures sur 18 non unies ; capture du niveau 5 (eau) correcte.
- **JagMCP :** capture du niveau 5 correcte ; niveaux 2 et 7 (2400 images) à 60 images de jeu et 60 affichées par seconde, B = 0 et L = 0 en partie.
- **`check_hw_rules` :** sans faute. RAM GPU : `gpu_end` = $F03EF0 (272 octets libres).

## Reste à faire

1. **BigPEmu : confirmé le 2026-10-18** par l'utilisateur avec `CrisisForce_perfhud.j64` : J et A restent à 60 au niveau 2, comme JagMCP le prévoyait. BigPEmu ne peut être ni piloté ni capturé depuis un script : les essais suivants se font toujours à la main.
2. **Matériel réel** (cartouche flash ou Skunkboard).
3. **Mode 2 joueurs** avec deux manettes.
4. **Retard restant** (≈ 1 % des images) : pointes de travail du jeu lui-même ; pistes : `hle_sprites` (≈ 10 %), code recompilé.

*Document mis à jour : 2026-10-17*
