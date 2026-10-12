# Crisis Force - Atari Jaguar Port - Build Status

> **Mise à jour 2026-10-04** : le build fonctionne (`python build.py` → `output/CrisisForce.abs`) et le jeu tourne dans Virtual Jaguar. Les sections ci-dessous décrivent l'état au 2026-09-30 et sont conservées pour l'historique. Voir **PHASE3_PROGRESS.md** pour l'état actuel.
>
> - [x] All source files assemble without errors using rmac
> - [x] Linking completes successfully with rln
> - [x] Program file generated (`CrisisForce.abs`, chargé à $4000 ; la ROM cartouche est pour la phase 4)
> - [x] Loads and runs in Virtual Jaguar

## Current State (2026-09-30)

### Completed ✅

1. **Phase 1: Preparation**
   - Project structure created
   - Skills directory analyzed
   - ROM extracted and analyzed (PRG-ROM: 128KB, CHR-ROM: 128KB, VRC2 mapper #23)

2. **Phase 2: Design**
   - Architecture documentation complete
   - Communication protocols defined
   - Scrolling system designed
   - Display mapping system designed
   - All source files created (main.s, gpu.s, dsp.s, game.inc, jaguar.inc)

3. **Asset Extraction**
   - ✅ Pillow installed
   - ✅ python tools/extract_assets.py executed successfully
   - ✅ Assets extracted:
     - `assets/tiles/all_tiles.png` (102KB) - Atlas of all 8192 tiles
     - `assets/sprites/player.png` - Player sprite
     - `assets/sprites/enemy_0-4.png` - 5 enemy sprites
     - `assets/backgrounds/background_1.png` - Background image

4. **Build Environment Setup**
   - ✅ JagStudio located at `D:\source_codes\jagstudio`
   - ✅ build.py updated with correct JS_PATH
   - ✅ All build tools verified (rmac.exe, rln.exe)

### Current Issue ❌

**Build fails during assembly with rmac**

The assembly code contains syntax incompatible with the rmac assembler:

1. **Duplicate Symbol Definitions**
   - `game.inc` defines `JOY_UP`, `JOY_DOWN`, `JOY_LEFT`, `JOY_RIGHT` as 0-3
   - `JAGUAR.INC` already defines these as 20-23 (Jaguar hardware values)
   - Solution: Remove duplicate JOY_* definitions from game.inc or use different names

2. **Unsupported Assembler Directives**
   - `rsreset` - ASM6F directive for structure offset reset
   - `rs.b`, `rs.w`, `rs.l` - ASM6F directives for structure fields
   - Solution: Replace with rmac-compatible structure definitions

3. **Structure Definition Compatibility**
   - The code uses NES-style assembler directives (ASM6F)
   - rmac uses different syntax for structures
   - Solution: Convert all structure definitions to rmac format

4. **Path Handling Issue**
   - Fixed: Moved `game.inc` from `source/` to `include/` directory
   - Fixed: Updated build.py to use correct include paths

## Files Created/Modified

### Source Files
- `source/main.s` (44KB) - Main game logic for M68000
- `source/gpu.s` (16KB) - GPU rendering code
- `source/dsp.s` (11KB) - DSP audio code
- `include/game.inc` (21KB) - Game constants and structures
- `include/jaguar.inc` (8KB) - Jaguar hardware definitions

### Tools & Scripts
- `build.py` - Build script (updated with correct JagStudio path)
- `tools/analyze_rom.py` - ROM analysis tool (executed)
- `tools/extract_assets.py` - Asset extraction tool (executed)

### Extracted Data
- `rom_analysis/prg_rom.bin` (131KB) - Extracted PRG-ROM
- `rom_analysis/chr_rom.bin` (131KB) - Extracted CHR-ROM
- `assets/` - Extracted graphics (tiles, sprites, backgrounds)

### Documentation
- `README.md` - Project overview
- `docs/CONCEPTION_ARCHITECTURALE.md` - Architecture design
- `docs/COMMUNICATION_INTER_PROCESSEURS.md` - Inter-processor communication
- `docs/MAPPING_ENTREES_AFFICHAGE.md` - Display mapping
- `docs/SYSTEME_SCROLLING.md` - Scrolling system
- `docs/RAPPORT_PHASE2_FINAL.md` - Phase 2 report
- `ANALYSE_CRISIS_FORCE_JAGUAR.md` - Project analysis

## Next Steps

### Immediate Actions Required

1. **Fix game.inc for rmac compatibility**
   ```bash
   # Remove or comment out duplicate JOY_* definitions
   # Replace rsreset/rs.* directives with rmac-compatible syntax
   ```

2. **Fix main.s for rmac compatibility**
   - Check for `.org` directives that need `-fr` flag or section definitions
   - Verify all directives are rmac-compatible

3. **Test build with corrected files**
   ```bash
   cd Crisis-Force-Jaguar
   python build.py
   ```

### Recommended Fixes for game.inc

Replace:
```asm
rsreset
PLAYER_STRUCT:
    rs.l 1  ; x position
    rs.w 1  ; y position
```

With:
```asm
PLAYER_STRUCT equ 0
PLAYER_X equ PLAYER_STRUCT
PLAYER_Y equ PLAYER_STRUCT+4
PLAYER_SIZE equ PLAYER_STRUCT+6
```

Or use rmac's structure directives if available.

### Structure Definitions for rmac

If rmac supports RS/RSSET, use:
```asm
RSSET 0
PLAYER_STRUCT:
    RS.L 1
    RS.W 1
```

If not, define manually:
```asm
PLAYER_STRUCT equ 0
PLAYER_X equ PLAYER_STRUCT
PLAYER_Y equ PLAYER_STRUCT+4
PLAYER_VX equ PLAYER_STRUCT+6
```

## Known Issues

1. JOY_* button definitions conflict between game.inc and JAGUAR.INC
2. rsreset/rs.* directives not supported by rmac
3. .org directive requires -fr flag or section definition
4. Unknown op errors for custom macros/commands

## Build Command Reference

```bash
# Clean build
python build.py

# Manual assembly (for testing)
"D:\source_codes\jagstudio\buildfiles\bin\rmac.exe" \
  -i"D:/source_codes/jagstudio/buildfiles/include" \
  -i"./include" \
  -m68000 \
  source\main.s
```

## Success Criteria

- [ ] All source files assemble without errors using rmac
- [ ] Linking completes successfully with rln
- [ ] ROM file generated (CrisisForce.j64)
- [ ] ROM can be loaded in Virtual Jaguar or real hardware
