;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Crisis Force - Portage Atari Jaguar
;; nes_jag.inc - constantes de la machine NES côté Jaguar (main.s, gpu.s)
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

;; Vidéo : 320x240 RGB16 ; l'image NES (256x240, CLUT 8 bpp) est centrée
;; Pixel de 5 cycles d'horloge vidéo : 256 pixels NES x 5 = 1280 cycles, soit
;; exactement la largeur d'un écran Jaguar natif 320x240 (320 x 4 cycles) :
;; l'image NES occupe toute la largeur, sans mise à l'échelle
    .if ^^defined PILLARBOX
;; build --pillarbox : pixel de 4 cycles (mode 320 colonnes), image NES de
;; 256 pixels centrée avec des bordures
NES_VMODE           equ PWIDTH4|BGEN|CSYNC|(3<<1)|VIDEN     ; $06C7
NES_PIXCLK          equ 4
    .else
NES_VMODE           equ PWIDTH5|BGEN|CSYNC|(3<<1)|VIDEN     ; $08C7
NES_PIXCLK          equ 5              ; cycles d'horloge vidéo par pixel
    .endif
NES_HEIGHT          equ 240
;; (position horizontale : a_xpos, calculée par InitVideo selon NTSC / PAL)
NES_PITCH_PHRASES   equ 32             ; 256 octets par ligne (8 bpp)
NT_BYTES            equ 256*240        ; une nametable rendue

;; Liste d'objets : STOP de garde à un emplacement fixe
OL_STOP             equ 864         ; 16 + 16 + 12 bandes x 64 + 16 + 16 (+ 16 --diagol) + 8, multiple de 32

;; Bandes d'affichage (effets de trame : banques CHR / défilement changés par
;; l'IRQ en cours d'image). Une bande = lignes [B_LINE0, B_LINE1) de l'écran,
;; rendues avec leur propre état dans le plan B_PLANE.
MAX_BANDS           equ 12
BAND_SIZE           equ 48
B_LINE0             equ 0              ; .w
B_LINE1             equ 2              ; .w (exclusif)
B_X                 equ 4              ; .w origine X dans l'espace des 4 nametables (0-511)
B_Y                 equ 6              ; .w origine Y (0-479)
B_CTRL              equ 8              ; .b registre $2000
B_PLANE             equ 10             ; .w plan de rendu (0 - NUM_PLANES-1)
B_CHR               equ 12             ; 8 longs : banques CHR de 1 Ko (adresses)
NUM_PLANES          equ 4
PLANE_BYTES         equ 2*NT_BYTES     ; 2 nametables physiques
CACHE_BYTES         equ 2*960*4        ; clés des tuiles rendues d'un plan

;; Instantané des registres PPU pour le GPU (snap_regs / disp_regs)
SR_PAL              equ 0              ; 32 octets : palette $3F00-$3F1F
SR_CTRL             equ 32
SR_MASK             equ 33
SR_SCROLLX          equ 34
SR_SCROLLY          equ 35
SR_MIRROR           equ 36
SR_CHRPTR           equ 40             ; 8 longs : adresse des banques CHR de 1 Ko
SNAP_REGS_SIZE      equ 72

;; Boutons NES (registre de la manette, bit 0 lu en premier)
NES_A               equ $01
NES_B               equ $02
NES_SELECT          equ $04
NES_START           equ $08
NES_UP              equ $10
NES_DOWN            equ $20
NES_LEFT            equ $40
NES_RIGHT           equ $80

;; PIT de Tom : une période = une ligne NES (63,5 µs à 26,59 MHz)
PIT_LINE            equ 1688
