# Snouty Tufty: plan

Port the Snouty carts to the Supabase Select 2026 badge. That badge is a
Pimoroni Badgeware **Tufty 2350** (or a light derivative of it).

## The two badges

|                | SYCL Badge V2 (snouty-badge)          | Tufty 2350                                   |
|----------------|---------------------------------------|----------------------------------------------|
| MCU            | RP2354B, 2x Cortex-M33F, 150 MHz      | RP2350B, 2x Cortex-M33F, 250 MHz (stock clock) |
| RAM            | 520 KB SRAM (cart gets ~307 KB)       | 520 KB SRAM + 8 MB PSRAM (QMI CS1, GPIO8)   |
| Flash          | 2 MB internal + carts on FAT          | 16 MB QSPI (MicroPython + FAT filesystem)   |
| Screen         | 160x128 RGB565, SPI                   | 320x240 ST7789, 8-bit 8080 parallel (PIO)   |
| Input          | joystick (4 + click), A, B, start, select | A, B, C, UP, DOWN (front), HOME (= BOOT) |
| Extras         | 5 neopixels, buzzer, light sensor     | 4 white case LEDs, light sensor, RTC, Wi-Fi/BT (CYW43) |

The CPU is the same family, so the carts' Thumb-2 + FPU code runs as is.
The work is the platform layer: the screen, the input, and the OS side of
the cart ABI.

## Approach

`snouty-badge` is a git submodule (the monorepo, pinned). The cart sources
stay there. This repo adds a small **Tufty OS** written in Zig on microzig
0.17.7, the same HAL and pin the SYCL OS uses. It implements the
SYCL cart ABI (`sycl-badge/src/os/cart/os_abi.zig`):

* core 0: Tufty OS. It drives the panel through PIO + DMA, polls the
  buttons, and answers the cart's present handshake over the SIO FIFO.
* core 1: the cart, exactly as the SYCL OS runs it. The same RAM-mode cart
  build (load address 0x20035100, IPC block at 0x20020000, cart descriptor,
  `_start`) runs unchanged.
* Present: the cart's 160x128 column-major RGB565 framebuffer maps
  straight onto the panel. The GRAM is portrait, so a landscape column is
  one GRAM row. x scales by exactly 2. y uses one of these modes:
  * `fit`: 128 -> 240 nearest neighbour, no rows lost. This is the default.
  * `crop`: 2x with the top and bottom 4 rows dropped.
  * `native`: 1:1, centred.
  The OS never needs a 320x240 buffer. It converts one column into a line
  buffer while the previous one DMAs out, the same way Pimoroni's driver
  works.
* Input: a per-cart map from the five buttons to the SYCL `Controls` bits,
  with chords for the missing ones. HOME returns to the menu, and a long
  press of HOME reboots into BOOTSEL.
* Flash: the firmware UF2 must stay below **2 MB** (0x10000000..0x10200000).
  That is the stock MicroPython firmware slot, so the badge's ROMFS
  (0x10200000) and its FAT apps/files partition survive our flash.
  Restoring the original firmware brings the stock launcher back with its
  files.

Later, carts can opt in to a native 320x240 or 160x120 mode for more
resolution. That is a cart-side change behind a build option. It is not
needed for the first ports.

## Milestones

* **M0, bring-up (now).** Repo, build, docs/DEPLOY.md (backup, flash,
  restore). Deliverables:
  * `snouty-tufty-hello.uf2`: clocks at 250 MHz, power rail, ST7789 over
    PIO, a test pattern, live button boxes and an fps counter. HOME reboots
    to BOOTSEL.
  * A control UF2 built from Pimoroni's own badgeware-cpp demo. If ours
    fails and theirs works, the bug is ours.

  Gate: Adrian flashes both on the badge.
* **M1, cart host.** The OS linker layout leaves 0x20020000.. to the cart.
  Cart loader (embedded cart image -> RAM), core 1 launch, the IPC block,
  the present handshake, the fit/crop/native scaler, the controls map,
  vsync pacing. First cart: snouty-bugs, built from the submodule with no
  changes. Gate: it runs in a host test of the scaler/ABI plus, on
  hardware, Adrian plays it.
  Done with snouty-run (verified on the badge 2026-10-02), then demosnout.
* **M2, arcade.** `snouty-tufty-arcade.uf2`: every cart in build.zig's
  `carts` table in one UF2, behind a boot menu (UP/DOWN, C or A to play,
  HOME back to the menu, HOME held = BOOTSEL). The scale and map are chosen
  at run time, and the flash budget is checked at build time: everything
  below 0x101C0000, with 0x101C0000..0x10200000 kept for a future XIP cart.
  See [docs/ARCADE.md](docs/ARCADE.md). Gate: Adrian flashes it and
  switches carts back and forth.
* **M2.x, the four picks.** snouty-maze, snouty-bugs, snoutenstein,
  snouty-reflections join the arcade (one table row and one button map
  each). Perf: the badge-bench numbers are at 150 MHz; at 250 MHz
  everything has about 1.6x headroom. Reflections can use the full scene
  variant instead of cut20.
* **M2.g, the first XIP cart: snouty-genesis.** `snouty-tufty-snouty-genesis.uf2`
  is the Tufty OS plus the unmodified genesis XIP cart at 0x101C0000 and a
  FAT12 drive at 0x10080000 holding the ROM (`-Dgenesis_rom=`, default the
  open Miniplanets; the owner's Sonic 1 rip stays outside the repo). The OS
  checks both regions' CRC32s at boot and starts core 1 through the cart's
  vector table, as the SYCL OS does. Single-cart only: the arcade already
  reaches past 0x10080000. See [docs/ports/snouty-genesis.md](docs/ports/snouty-genesis.md).
  Gate: Adrian flashes it and plays Green Hill Zone.
* **M2.z, the arcade's XIP cart: snouty-zero.** The Mode 7 racer (XIP-only
  since its M5) is the last arcade entry, packed at 0x101C0000 beside the
  seven RAM carts, and builds alone as `snouty-tufty-snouty-zero.uf2`. C
  latches the throttle, A/B steer, UP Overclock, DOWN brake, A+B rewind,
  UP+DOWN pause (UP/DOWN 60 ms chord-delayed, a new per-binding
  `chord_ms`). One cart change on the `tufty` branch (ddd04fc): the title
  takes A and the cards say `PRESS C`. 4.52 ms worst at 150 MHz on the Tufty
  map, ~2.7 ms at 250, if XIP stalls hold. See
  [docs/ports/snouty-zero.md](docs/ports/snouty-zero.md). Gate: Adrian
  flashes the arcade and races.
* **M3, polish.** Per-cart scale mode, backlight from the light sensor,
  case LEDs, optional hi-res cart variants, and a MicroPython launcher
  stub, if one can chain-boot us.
  Done for the launcher as a dual boot (2026-10-02, host-tested, not yet
  on hardware): `snouty-tufty-arcade-supabase.uf2` lives in the flash gap
  beside MicroPython, a Badgeware app reboots into it through the bootrom's
  RAM_IMAGE boot and `chain_image()`, and a menu row reboots back. See
  [docs/DUALBOOT.md](docs/DUALBOOT.md).
  Power off (2026-10-02, host-tested, not yet on hardware): hold RESET
  for the rear-LED sweep and the badge goes to POWMAN P1.7; a button
  press wakes it, as the stock firmware. See [docs/POWER.md](docs/POWER.md).

## Open questions (defaulted)

* Is the Supabase badge a stock Tufty? **Answered 2026-10-02, yes.**
  `picotool info -a` on Adrian's badge reports:
  * MicroPython `bw-1.29.0`, `pico_board pimoroni_tufty2350`, SDK 2.3.0,
    RP2350 A4, QFN80, ARM Secure image.
  * The firmware occupies 0x10000000..0x1014e220.
  * ROMFS at 0x10200000..0x10300000 and the FAT drive at
    0x10300000..0x11000000.
  * There is no partition table, and absolute `rp2350-arm-s` UF2s are
    accepted.

  The frozen modules include `lsm6ds3` and `qwstpad`. That may mean an
  IMU on this build, which would give tilt controls. Probe I2C0 (GPIO4/5)
  for 0x6A/0x6B in M1.
* Button maps per cart. Default: UP/DOWN = up/down, A = left, C = right,
  B = the cart's A. Chords: A+C = start, B+UP = select.
