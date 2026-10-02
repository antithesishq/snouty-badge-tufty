@ Snouty Arcade dual-boot launch stub (docs/DUALBOOT.md).
@
@ A tiny RAM image. The Supabase launcher app (supabase-app/snouty_arcade)
@ copies it from the launcher sector (0x1014F000) into SRAM, adds its load
@ address to vector words 1..3, and reboots with the bootrom's RAM_IMAGE
@ watchdog boot type. After that watchdog reset (a PSM sequence over
@ everything but the processor cold domain; SRAM keeps its contents, as for
@ the bootrom's own RAM UF2 downloads) the bootrom finds the
@ IMAGE_DEF below, sets MSP and VTOR from the vector table and enters
@ `reset` in a freshly reset chip, with ROSC clocks and the QSPI pads reset
@ but the flash untouched (RP2350 datasheet 5.2.2, table 462: RAM image boot
@ skips Check BOOTSEL, OTP boot and Try Flash Boot).
@
@ The stub then does what the bootrom's own flash boot does before it scans
@ (bootrom varm_flash_boot.c s_varm_crit_ram_trash_try_flash_boot): identity
@ address map, connect the QSPI pads to the QMI, issue the XIP exit sequence
@ (MicroPython leaves the flash in continuous-read mode), then try the same
@ 16 read mode / clock divisor pairs in the same order (datasheet table 463)
@ until the launcher sector's magic reads back. It flushes the XIP cache
@ (its state is undefined after reset, datasheet 4.4.1.2) and calls the
@ bootrom's chain_image() on the arcade window 0x10150000..0x10200000. The
@ bootrom verifies the arcade's IMAGE_DEF, maps the window to 0x10000000
@ with QMI ATRANS, and enters it through its vector table as a flash boot
@ would. chain_image() only returns on failure.
@
@ Any failure, or any fault, reboots into the normal boot path (MicroPython)
@ through the watchdog, and leaves a code in watchdog SCRATCH0/1 that the
@ launcher app shows next time:
@   SCRATCH0 = 0x534E0000 | code, SCRATCH1 = detail
@   1  a bootrom function is missing        detail: its 2-letter code
@   2  no read mode reads the launcher sector
@   3  chain_image() returned                detail: its error code
@   4  fault                                 detail: the faulting PC
@
@ No flash is written. Nothing here can be reached on a normal boot: the
@ bootrom only enters this code through a RAM_IMAGE reboot that the launcher
@ app requests.

    .syntax unified
    .cpu cortex-m33
    .thumb

    .equ SRAM_END,          0x20082000   @ stack top (SCRATCH_Y), outside main SRAM
    .equ WORKAREA,          0x20080000   @ chain_image work area (SCRATCH_X), 4 KB
    .equ WORKAREA_SIZE,     0x1000       @ the SDK asks for 3264 bytes
    .equ HDR_RAW,           0x1c14f000   @ launcher sector, uncached + untranslated XIP alias
    .equ WINDOW_BASE,       0x10150000   @ the arcade image window (physical flash address)
    .equ WINDOW_SIZE,       0x000b0000   @ up to 0x10200000, where the ROMFS starts

    @ Launcher sector magic (layout.zig): "SNOUTYDB" and its complement.
    .equ HDR_W0,            0x554f4e53
    .equ HDR_W1,            0x42445954
    .equ HDR_W2,            0xaab0b1ac
    .equ HDR_W3,            0xbdbba6ab

    .equ RESULT_MAGIC,      0x534e0000

    .equ WATCHDOG_BASE,     0x400d8000
    .equ PSM_BASE,          0x40018000
    .equ TICKS_BASE,        0x40108000
    .equ SYSCFG_SET,        0x4000a000   @ SYSCFG_BASE + 0x2000 (atomic set alias)

    .equ RT_FLAG_FUNC_ARM_SEC, 0x0004

    @ r0 = rom_table_lookup(code, RT_FLAG_FUNC_ARM_SEC), via r4; dst = r0.
    .macro rom_lookup c1, c2, dst
    movw r0, #(\c1 + (\c2 << 8))
    movs r1, #RT_FLAG_FUNC_ARM_SEC
    blx r4
    cmp r0, #0
    bne 1f
    movw r1, #(\c1 + (\c2 << 8))
    b fail_lookup
1:
    mov \dst, r0
    .endm

    .section .text.stub, "ax", %progbits
    .global stub_start
stub_start:
    @ Vector table. Words 1..3 are offsets with the Thumb bit; the launcher
    @ app adds the load address (256-byte aligned, so VTOR can point here).
    .word SRAM_END
    .word reset - stub_start + 1
    .word fault - stub_start + 1        @ NMI
    .word fault - stub_start + 1        @ HardFault

    @ IMAGE_DEF block (datasheet 5.9.1): a single block that is its own loop.
image_def_block:
    .word 0xffffded3                    @ PICOBIN_BLOCK_MARKER_START
    .word 0x10210142                    @ IMAGE_TYPE item: EXE, Secure, Arm, RP2350
    .word 0x000001ff                    @ LAST item: 1 word of items before it
    .word 0                             @ link to the next block: itself
    .word 0xab123579                    @ PICOBIN_BLOCK_MARKER_END

    @ PRIMASK is left as the bootrom set it, so the arcade starts with the
    @ same interrupt mask as after a normal flash boot (the same launch
    @ thunk, arm8_bootrom_rt0.S, enters both). After the reset no interrupt
    @ is enabled in the NVIC.
reset:
    movs r0, #0x16
    ldrh r4, [r0]                       @ rom_table_lookup (datasheet table 464)
    rom_lookup 'R', 'A', r5             @ flash_reset_address_trans
    rom_lookup 'I', 'F', r6             @ connect_internal_flash
    rom_lookup 'E', 'X', r7             @ flash_exit_xip
    rom_lookup 'X', 'M', r8             @ flash_select_xip_read_mode
    rom_lookup 'F', 'C', r9             @ flash_flush_cache
    rom_lookup 'C', 'I', r10            @ chain_image

    blx r5                              @ identity address map
    blx r6                              @ QSPI pads to the QMI
    blx r7                              @ flash out of continuous read, 03h serial XIP

    @ Read modes 3 (EBh quad) .. 0 (03h serial), at clock divisors 3, 6,
    @ 12, 24: the bootrom's flash scan order.
    movs r4, #3                         @ r4 = clkdiv
next_clkdiv:
    movs r0, #3
    mov r11, r0                         @ r11 = mode
next_mode:
    mov r0, r11
    mov r1, r4
    blx r8                              @ flash_select_xip_read_mode(mode, clkdiv)
    bl probe
    beq found
    mov r0, r11
    subs r0, #1
    mov r11, r0                         @ (mov to a high register keeps the flags)
    bpl next_mode
    lsls r4, r4, #1
    cmp r4, #24
    bls next_clkdiv
    movs r0, #2
    movs r1, #0
    b fail

found:
    blx r9                              @ flush the XIP cache before any cached read
    ldr r0, =WORKAREA
    ldr r1, =WORKAREA_SIZE
    ldr r2, =WINDOW_BASE
    ldr r3, =WINDOW_SIZE
    blx r10                             @ chain_image(): returns only on failure
    mov r1, r0
    movs r0, #3
    b fail

    @ Z set if the launcher sector magic reads back. Uses r0, r1, r3.
probe:
    ldr r3, =HDR_RAW
    ldr r0, [r3, #0]
    ldr r1, =HDR_W0
    cmp r0, r1
    bne 9f
    ldr r0, [r3, #4]
    ldr r1, =HDR_W1
    cmp r0, r1
    bne 9f
    ldr r0, [r3, #8]
    ldr r1, =HDR_W2
    cmp r0, r1
    bne 9f
    ldr r0, [r3, #12]
    ldr r1, =HDR_W3
    cmp r0, r1
9:
    bx lr

fail_lookup:
    movs r0, #1
    b fail

fault:
    ldr r1, [sp, #24]                   @ stacked PC
    movs r0, #4
    @ fall through

    @ r0 = code, r1 = detail. Record them and reboot into the normal boot
    @ path the way the bootrom's reboot() does (varm_apis.c
    @ s_varm_hx_reboot): watchdog off, WDSEL = all but PROC_COLD, SCRATCH4 =
    @ 0 (no vector), the watchdog tick running, POWMAN off clk_ref, then the
    @ watchdog counting down.
fail:
    cpsid i
    ldr r2, =WATCHDOG_BASE
    movs r3, #0
    str r3, [r2, #0x00]                 @ CTRL: disable while configuring
    ldr r3, =RESULT_MAGIC
    orrs r0, r3
    str r0, [r2, #0x0c]                 @ SCRATCH0 = 0x534E0000 | code
    str r1, [r2, #0x10]                 @ SCRATCH1 = detail
    movs r3, #0
    str r3, [r2, #0x1c]                 @ SCRATCH4 = 0: normal boot
    ldr r0, =PSM_BASE
    ldr r3, =0x01fffffe
    str r3, [r0, #0x08]                 @ PSM WDSEL: everything but PROC_COLD
    ldr r0, =TICKS_BASE
    ldr r3, [r0, #0x30]                 @ TICKS WATCHDOG_CTRL
    lsls r3, r3, #31
    bne 2f
    movs r3, #12
    str r3, [r0, #0x34]                 @ WATCHDOG_CYCLES = 12
    movs r3, #1
    str r3, [r0, #0x30]                 @ WATCHDOG_CTRL.ENABLE
2:
    ldr r3, =1000
    str r3, [r2, #0x04]                 @ LOAD: 1000 ticks
    ldr r0, =SYSCFG_SET
    movs r3, #1
    str r3, [r0, #0x14]                 @ AUXCTRL bit 0: POWMAN clock off clk_ref
    ldr r3, =0x40000000
    str r3, [r2, #0x00]                 @ CTRL.ENABLE: reset when LOAD runs out
3:
    b 3b

    .ltorg
    .global stub_end
stub_end:
