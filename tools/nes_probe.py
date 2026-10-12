#!/usr/bin/env python3
"""
Sonde d'exécution de la ROM NES Crisis Force.

Exécute le code 6502 (py65) avec juste assez de matériel émulé pour que le jeu
tourne : mapper VRC4e (mapper 23, sous-mapper 2), registres PPU (sans rendu
pixel), DMA OAM, manette, IRQ VRC4. On en tire des instantanés exacts :
OAM (sprites), palettes, banques CHR, nametables, ctrl PPU.

Usage :
    pip install py65 pillow
    python nes_probe.py <dossier_sortie> [nb_frames]

Produit pour chaque instantané : snap_XXXX.json + snap_XXXX.png (rendu approché
fond + sprites, x2) dans le dossier de sortie.
"""

import json
import os
import rom_patches
import rom_path
import sys

from py65.devices.mpu6502 import MPU
from PIL import Image

PROJECT_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ROM_PATH = rom_path.find_rom()       # CRISIS_FORCE_ROM, dossier du projet ou parent

CYCLES_PER_FRAME = 29781
CYCLES_PER_LINE = 113.667
VBLANK_START = int(241 * CYCLES_PER_LINE)
PRERENDER = int(261 * CYCLES_PER_LINE)

# Palette maître 2C02 (valeurs usuelles des émulateurs)
NES_RGB = [
    (84, 84, 84), (0, 30, 116), (8, 16, 144), (48, 0, 136), (68, 0, 100), (92, 0, 48), (84, 4, 0), (60, 24, 0),
    (32, 42, 0), (8, 58, 0), (0, 64, 0), (0, 60, 0), (0, 50, 60), (0, 0, 0), (0, 0, 0), (0, 0, 0),
    (152, 150, 152), (8, 76, 196), (48, 50, 236), (92, 30, 228), (136, 20, 176), (160, 20, 100), (152, 34, 32), (120, 60, 0),
    (84, 90, 0), (40, 114, 0), (8, 124, 0), (0, 118, 40), (0, 102, 120), (0, 0, 0), (0, 0, 0), (0, 0, 0),
    (236, 238, 236), (76, 154, 236), (120, 124, 236), (176, 98, 236), (228, 84, 236), (236, 88, 180), (236, 106, 100), (212, 136, 32),
    (160, 170, 0), (116, 196, 0), (76, 208, 32), (56, 204, 108), (56, 180, 204), (60, 60, 60), (0, 0, 0), (0, 0, 0),
    (236, 238, 236), (168, 204, 236), (188, 188, 236), (212, 178, 236), (236, 174, 236), (236, 174, 212), (236, 180, 176), (228, 196, 144),
    (204, 210, 120), (180, 222, 120), (168, 226, 144), (152, 226, 180), (160, 214, 228), (160, 162, 160), (0, 0, 0), (0, 0, 0),
]


class NES:
    """Bus mémoire + matériel minimal. Sert directement de mémoire à py65."""

    def __init__(self, rom):
        prg_size = rom[4] * 16384
        self.prg = bytes(rom_patches.apply(bytearray(rom[16:16 + prg_size])))   # ROM du portage
        self.chr = rom[16 + prg_size:16 + prg_size + rom[5] * 8192]
        self.prg_banks = prg_size // 8192
        self.ram = bytearray(0x800)
        self.wram = bytearray(0x2000)
        rom_patches.init_wram(self.wram)   # texte de la ligne KEY (options)
        # VRC4
        self.prg_reg = [0, 1]
        self.prg_swap = 0
        self.mirroring = 0        # VRC4 $9000 : 0 vertical, 1 horizontal, 2/3 écran unique
        self.chr_bank = [0] * 8
        self.irq_latch = 0
        self.irq_counter = 0
        self.irq_ctrl = 0
        self.irq_prescaler = 341
        self.irq_pending = False
        # PPU
        self.ppu_ctrl = 0
        self.ppu_mask = 0
        self.vblank = False
        self.sprite0 = False
        self.w = 0
        self.vaddr = 0
        self.scroll = [0, 0]
        self.vram = bytearray(0x4000)
        self.oam = bytearray(256)
        self.oam_addr = 0
        self.read_buffer = 0
        # Manette
        self.buttons = 0          # A B Select Start Up Down Left Right (bit 0 = A)
        self.shift = 0
        self.strobe = 0
        self.dma_cycles = 0
        self.apu_log = None       # liste (adresse, valeur) si la capture APU est active

    # --- PRG ---
    def prg_bank_for(self, slot):
        last = self.prg_banks - 1
        if slot == 3:
            return last
        if slot == 1:
            return self.prg_reg[1] % self.prg_banks
        if (slot == 0) != bool(self.prg_swap):
            return self.prg_reg[0] % self.prg_banks
        return last - 1

    # --- interface mémoire py65 ---
    def __len__(self):
        return 0x10000

    def __getitem__(self, addr):
        if addr < 0x2000:
            return self.ram[addr & 0x7FF]
        if addr < 0x4000:
            return self.ppu_read(addr & 7)
        if addr < 0x6000:
            if addr == 0x4016:
                bit = self.shift & 1
                self.shift = (self.shift >> 1) | 0x80
                return 0x40 | bit
            return 0x40
        if addr < 0x8000:
            return self.wram[addr - 0x6000]
        slot = (addr - 0x8000) >> 13
        return self.prg[self.prg_bank_for(slot) * 8192 + (addr & 0x1FFF)]

    def __setitem__(self, addr, val):
        val &= 0xFF
        if addr < 0x2000:
            self.ram[addr & 0x7FF] = val
        elif addr < 0x4000:
            self.ppu_write(addr & 7, val)
        elif 0x4000 <= addr <= 0x4013 or addr == 0x4015 or addr == 0x4017:
            # Registres APU : journalisés pour la capture du son (apu_capture.py)
            if self.apu_log is not None:
                self.apu_log.append((addr, val))
        elif addr == 0x4014:
            base = val << 8
            for i in range(256):
                self.oam[(self.oam_addr + i) & 0xFF] = self[base + i]
            self.dma_cycles += 513
        elif addr == 0x4016:
            if self.strobe and not (val & 1):
                self.shift = self.buttons
            self.strobe = val & 1
            if self.strobe:
                self.shift = self.buttons
        elif addr == rom_patches.KEY_REG:
            rom_patches.key_hook(self.wram, val)   # ligne KEY des options (ROM modifiée)
        elif 0x6000 <= addr < 0x8000:
            self.wram[addr - 0x6000] = val
        elif addr >= 0x8000:
            self.mapper_write(addr, val)

    # --- VRC4e (lignes A2/A3, on accepte aussi A0/A1) ---
    def mapper_write(self, addr, val):
        idx = ((addr >> 0) & 1 | (addr >> 2) & 1) | (((addr >> 1) & 1 | (addr >> 3) & 1) << 1)
        top = addr & 0xF000
        if top == 0x8000:
            self.prg_reg[0] = val & 0x1F
        elif top == 0x9000:
            if idx >= 2:
                self.prg_swap = (val >> 1) & 1
            else:
                self.mirroring = val & 3
        elif top == 0xA000:
            self.prg_reg[1] = val & 0x1F
        elif 0xB000 <= top <= 0xE000:
            bank = ((top - 0xB000) >> 12) * 2 + (idx >> 1)
            if idx & 1:
                self.chr_bank[bank] = (self.chr_bank[bank] & 0x0F) | ((val & 0x1F) << 4)
            else:
                self.chr_bank[bank] = (self.chr_bank[bank] & 0x1F0) | (val & 0x0F)
        elif top == 0xF000:
            if idx == 0:
                self.irq_latch = (self.irq_latch & 0xF0) | (val & 0x0F)
            elif idx == 1:
                self.irq_latch = (self.irq_latch & 0x0F) | ((val & 0x0F) << 4)
            elif idx == 2:
                self.irq_ctrl = val & 7
                self.irq_pending = False
                if val & 2:
                    self.irq_counter = self.irq_latch
                    self.irq_prescaler = 341
            else:
                self.irq_pending = False
                self.irq_ctrl = (self.irq_ctrl & ~2) | ((self.irq_ctrl & 1) << 1)

    def clock_irq(self, cycles):
        if not (self.irq_ctrl & 2):
            return
        for _ in range(cycles):
            if self.irq_ctrl & 4:
                tick = True
            else:
                self.irq_prescaler -= 3
                tick = self.irq_prescaler <= 0
                if tick:
                    self.irq_prescaler += 341
            if tick:
                if self.irq_counter == 0xFF:
                    self.irq_counter = self.irq_latch
                    self.irq_pending = True
                else:
                    self.irq_counter += 1

    # --- PPU (registres seulement) ---
    def ppu_read(self, reg):
        if reg == 2:
            v = (0x80 if self.vblank else 0) | (0x40 if self.sprite0 else 0)
            self.vblank = False
            self.w = 0
            return v
        if reg == 4:
            return self.oam[self.oam_addr]
        if reg == 7:
            a = self.vaddr & 0x3FFF
            v = self.read_buffer
            self.read_buffer = self.ppu_mem(a)
            self.vaddr += 32 if self.ppu_ctrl & 4 else 1
            return v
        return 0

    def nt_addr(self, a):
        """Adresse de nametable après application du miroir VRC4"""
        if a >= 0x3F00 or a < 0x2000:
            return a
        a = 0x2000 | (a & 0xFFF)
        if self.mirroring == 0:
            return a & ~0x800                    # vertical : $2000/$2400 distinctes
        if self.mirroring == 1:
            return a & ~0x400                    # horizontal : $2000/$2800 distinctes
        return (a & 0x23FF) | (0x400 if self.mirroring == 3 else 0)

    def ppu_mem(self, a):
        if a < 0x2000:
            return self.chr_byte(a)
        return self.vram[self.nt_addr(a)]

    def ppu_write(self, reg, val):
        if reg == 0:
            self.ppu_ctrl = val
        elif reg == 1:
            self.ppu_mask = val
        elif reg == 3:
            self.oam_addr = val
        elif reg == 4:
            self.oam[self.oam_addr] = val
            self.oam_addr = (self.oam_addr + 1) & 0xFF
        elif reg == 5:
            self.scroll[self.w] = val
            self.w ^= 1
        elif reg == 6:
            if self.w == 0:
                self.vaddr = (self.vaddr & 0xFF) | ((val & 0x3F) << 8)
            else:
                self.vaddr = (self.vaddr & 0xFF00) | val
            self.w ^= 1
        elif reg == 7:
            a = self.vaddr & 0x3FFF
            if a >= 0x3F00:
                a = 0x3F00 | (a & 0x1F)
                if a & 0x13 == 0x10:
                    a &= ~0x10
            if a >= 0x2000:
                self.vram[self.nt_addr(a)] = val
            self.vaddr += 32 if self.ppu_ctrl & 4 else 1

    def chr_byte(self, a):
        return self.chr[(self.chr_bank[a >> 10] * 1024 + (a & 0x3FF)) % len(self.chr)]

    def palette(self):
        return [self.vram[0x3F00 + i] & 0x3F for i in range(32)]

    # --- rendu approché pour identification ---
    def tile_pixels(self, addr):
        rows = []
        for y in range(8):
            p0 = self.chr_byte(addr + y)
            p1 = self.chr_byte(addr + 8 + y)
            rows.append([((p0 >> (7 - x)) & 1) | (((p1 >> (7 - x)) & 1) << 1) for x in range(8)])
        return rows

    def render(self, scale=2):
        img = Image.new('RGB', (256, 240), NES_RGB[self.vram[0x3F00] & 0x3F])
        px = img.load()
        pal = self.palette()
        # Fond : nametable sélectionnée par ctrl, sans défilement fin
        nt = 0x2000 + (self.ppu_ctrl & 3) * 0x400
        bg_table = 0x1000 if self.ppu_ctrl & 0x10 else 0
        for ty in range(30):
            for tx in range(32):
                tile = self.vram[self.nt_addr(nt + ty * 32 + tx)]
                attr = self.vram[self.nt_addr(nt + 0x3C0 + (ty // 4) * 8 + tx // 4)]
                shift = ((ty & 2) << 1) | (tx & 2)
                p = (attr >> shift) & 3
                for y, row in enumerate(self.tile_pixels(bg_table + tile * 16)):
                    for x, c in enumerate(row):
                        if c:
                            px[tx * 8 + x, ty * 8 + y] = NES_RGB[pal[p * 4 + c]]
        # Sprites
        tall = bool(self.ppu_ctrl & 0x20)
        for i in range(63, -1, -1):
            y, tile, attr, x = self.oam[i * 4:i * 4 + 4]
            if y >= 0xEF:
                continue
            for part, rows in enumerate(self.sprite_tiles(tile, tall)):
                if attr & 0x80:
                    rows = rows[::-1]
                for yy, row in enumerate(rows):
                    if attr & 0x40:
                        row = row[::-1]
                    for xx, c in enumerate(row):
                        sx, sy = x + xx, y + 1 + yy + 8 * (part if not attr & 0x80 else (1 - part if tall else 0))
                        if c and sx < 256 and sy < 240:
                            px[sx, sy] = NES_RGB[pal[16 + (attr & 3) * 4 + c]]
        return img.resize((256 * scale, 240 * scale), Image.NEAREST)

    def sprite_tiles(self, tile, tall):
        if tall:
            table = (tile & 1) * 0x1000
            t = tile & 0xFE
            return [self.tile_pixels(table + t * 16), self.tile_pixels(table + (t + 1) * 16)]
        table = 0x1000 if self.ppu_ctrl & 8 else 0
        return [self.tile_pixels(table + tile * 16)]

    def snapshot(self):
        return {
            'ppu_ctrl': self.ppu_ctrl,
            'sprite_8x16': bool(self.ppu_ctrl & 0x20),
            'chr_banks': list(self.chr_bank),
            'palette': self.palette(),
            'oam': [list(self.oam[i * 4:i * 4 + 4]) for i in range(64) if self.oam[i * 4] < 0xEF],
            'scroll': list(self.scroll),
        }


# Script de manette : (frame de début, frame de fin, boutons)
BTN_A, BTN_B, BTN_SELECT, BTN_START = 1, 2, 4, 8
BTN_UP, BTN_DOWN, BTN_LEFT, BTN_RIGHT = 16, 32, 64, 128


def buttons_at(frame):
    # Start pour passer l'intro (frame 0) puis valider "1 PLAYER" (frame 240).
    # Pas d'autre appui : Start met le jeu en pause.
    if frame < 400:
        return (BTN_START if frame < 4 else BTN_B) if frame % 120 < 4 and frame in range(0, 244) else 0   # B valide (menu modifié)
    b = BTN_B if frame % 8 < 4 else 0
    b |= BTN_LEFT if (frame // 90) % 2 else BTN_RIGHT
    return b


def boot():
    """Charge la ROM et renvoie (nes, cpu) prêts à exécuter le vecteur RESET"""
    nes = NES(open(ROM_PATH, 'rb').read())
    cpu = MPU(memory=nes)
    cpu.pc = nes[0xFFFC] | (nes[0xFFFD] << 8)
    return nes, cpu


def run_frames(nes, cpu, frames, buttons_fn=buttons_at, callback=None):
    """Exécute `frames` frames ; callback(frame) est appelé après chaque frame"""
    frame_cycle = 0
    for frame in range(frames):
        nes.buttons = buttons_fn(frame)
        in_vblank = False
        while frame_cycle < CYCLES_PER_FRAME:
            before = cpu.processorCycles
            cpu.step()
            spent = cpu.processorCycles - before + nes.dma_cycles
            nes.dma_cycles = 0
            nes.clock_irq(spent)
            frame_cycle += spent
            # Sprite 0 hit approché : quand on dépasse la ligne du sprite 0
            if not nes.sprite0 and nes.ppu_mask & 0x18 and frame_cycle >= (nes.oam[0] + 2) * CYCLES_PER_LINE \
                    and frame_cycle < VBLANK_START:
                nes.sprite0 = True
            if not in_vblank and frame_cycle >= VBLANK_START:
                in_vblank = True
                nes.vblank = True
                if nes.ppu_ctrl & 0x80:
                    cpu.nmi()
            if nes.irq_pending and not (cpu.p & cpu.INTERRUPT):
                cpu.irq()
        frame_cycle -= CYCLES_PER_FRAME
        nes.vblank = False
        nes.sprite0 = False
        if callback:
            callback(frame)


def main():
    out_dir = sys.argv[1] if len(sys.argv) > 1 else 'probe'
    frames = int(sys.argv[2]) if len(sys.argv) > 2 else 3000
    every = int(sys.argv[3]) if len(sys.argv) > 3 else 150
    os.makedirs(out_dir, exist_ok=True)

    nes, cpu = boot()

    def save(frame):
        if frame % every == every - 1:
            name = os.path.join(out_dir, f'snap_{frame + 1:05d}')
            with open(name + '.json', 'w') as f:
                json.dump(nes.snapshot(), f)
            nes.render().save(name + '.png')
            print(f'frame {frame + 1}: {len(nes.snapshot()["oam"])} sprites, pc=${cpu.pc:04X}', flush=True)

    run_frames(nes, cpu, frames, callback=save)


if __name__ == '__main__':
    main()
