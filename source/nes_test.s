;; Programme de test du code recompilé (banc tools/recomp_test.py, Unicorn)
;; Lié à $4000 ; l'en-tête donne au banc les adresses utiles.
    .68000
RECOMP_TEST equ 1
    .text
test_header:
    dc.l    test_start, test_nmi, test_irq, test_reset
    dc.l    rt_vars, nes_ram, nes_wram, nes_vram
    dc.l    nes_oam, nes_palette, nes_apu, prg_rom
    dc.l    test_end, rt_halt, NES_NMI_ENTRY, NES_IRQ_ENTRY
    dc.l    nes_label_tab, test_nmi_ip, test_irq_ip

test_start:
    bsr     rt_init
    bra     test_end
;; Appel du NMI : registres 6502 chargés par le banc dans d0-d2/d6/a2 et le CCR
test_nmi:
    lea     nes_wram,a4
    lea     nes_ram+$80,a5
    lea     rt_vars,a6
    bsr     rt_nmi
    bra     test_end
test_irq:
    lea     nes_wram,a4
    lea     nes_ram+$80,a5
    lea     rt_vars,a6
    bsr     rt_run_irq
    bra     test_end
;; Variantes « tout interprété » (rt_forceip) : le gestionnaire 6502 est
;; exécuté par l'interpréteur de secours
test_nmi_ip:
    move.w  #$FFFA,d5
    bra.s   test_ip
test_irq_ip:
    move.w  #$FFFE,d5
test_ip:
    lea     nes_wram,a4
    lea     nes_ram+$80,a5
    lea     rt_vars,a6
    st      rt_forceip(a6)
    movem.l d0-d7/a0-a6,-(sp)
    move.w  sr,-(sp)
    move.b  rt_iflag(a6),-(sp)
    st      rt_iflag(a6)
    subq.w  #3,a2
    ;; vecteur : banque 15
    lea     prg_rom+(15*8192),a0
    andi.w  #$1FFF,d5
    move.b  1(a0,d5.w),d3
    lsl.w   #8,d3
    move.b  (a0,d5.w),d3
    move.w  sr,d4
    jsr     test_ip_call
    move.b  (sp)+,rt_iflag(a6)
    move.w  (sp)+,ccr
    movem.l (sp)+,d0-d7/a0-a6
    sf      rt_forceip(a6)
    bra     test_end
test_ip_call:
    jmp     rt_interp
test_reset:
    lea     nes_wram,a4
    lea     nes_ram+$80,a5
    lea     rt_vars,a6
    jmp     NES_RESET_ENTRY
test_end:
    nop
    illegal

    .include "nes_runtime.s"
    .include "nes_hle.s"
    .include "nes_interp.s"
    .include "nes_code.s"
