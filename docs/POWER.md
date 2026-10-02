# Power off

Every Tufty OS firmware (the arcade, the dual boot, the single-cart UF2s,
Genesis, the hello screen) turns the badge off the way the stock Badgeware
firmware does. The code is [src/power.zig](../src/power.zig), a port of
Pimoroni's `powman.c` (MIT).

* **Off:** hold **RESET** (the power button on the back). The badge
  restarts, and the four white LEDs on the back sweep on and then fade
  out. Keep holding until they are dark, about 2 s. Then let go; the
  badge is off.
* **Off, deepest ("shipping mode"):** hold **UP + DOWN** as well until the
  LEDs are dark. Only RESET wakes it.
* **On again:** press A, B, C, UP or DOWN (after a plain off), or tap
  RESET (always works).
* Let go of RESET before the LEDs are dark, and the badge just restarts.

Waking is a cold boot of the image at the start of flash. That is the
arcade, the single cart or Genesis for installs B and C, and Supabase's
MicroPython for the dual boot (install A). In the dual boot a RESET
press always restarts into MicroPython, which handles the hold itself.
So power off works the same from inside the arcade.

## How it works

The RESET button is wired to the chip's RUN pin and to GPIO 14. A press
resets the RP2350. GPIO 14 then reads low for as long as the button is
held. `power.boot_check()` runs first in `main()`, before the panel comes
up. If GPIO 14 is low, it plays the LED sweep (`src/power_sweep.zig`,
host-tested); if the button is still held at the end, it powers off:

1. It parks every GPIO the way the reference does: input buffers off,
   pulled down. The exceptions are the PSRAM CS (pulled up), the user
   buttons (their pull-ups stay) and RESET, HOME, GPIO 40-42 (floating).
   A floating GPIO 41 drops the switched rail (panel, backlight).
2. It resets USBCTRL and parks the USB PHY in low power.
3. It disarms any old POWMAN wake source. For a plain off it then arms
   wake channel 3 on a falling edge of GPIO 15, the buttons' shared
   interrupt line. First it waits up to 1 s for the line to be idle.
4. It asks POWMAN for state P1.7 (every domain but always-on off, SRAM
   powered back up by the hardware on wake, no boot vector) and sits in
   WFI. If POWMAN refuses, it reboots instead.

Unlike the reference, it skips the RTC alarm wake (nothing here sets
alarms), the double-tap flag, the POWMAN timer and the drop to 48 MHz
before the power-down (the switched core is about to lose power anyway).

Not yet measured on hardware: the off current, and whether the wake line
behaves as Pimoroni's header describes.
